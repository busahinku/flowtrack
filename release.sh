#!/bin/bash
# FlowTrack Release Script
# Usage: ./release.sh [version] [--notes "release notes"]
# Example: ./release.sh 1.1 --notes "Fixed focus mode, improved onboarding"
# If version is omitted, uses current MARKETING_VERSION from project.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/FlowTrack.xcodeproj"
SCHEME="FlowTrack"
EXPORT_DIR="$SCRIPT_DIR/.release_build"
ARCHIVE_PATH="$EXPORT_DIR/FlowTrack.xcarchive"
APP_EXPORT_DIR="$EXPORT_DIR/export"
EXPORT_OPTIONS="$EXPORT_DIR/ExportOptions.plist"

# ── Parse args ───────────────────────────────────────────────────────────────

VERSION=""
NOTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        --notes=*) NOTES="${1#*=}"; shift ;;
        *) VERSION="$1"; shift ;;
    esac
done

# Fall back to project version
if [[ -z "$VERSION" ]]; then
    VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT/project.pbxproj" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
fi

if [[ -z "$NOTES" ]]; then
    NOTES="FlowTrack v$VERSION"
fi

TAG="v$VERSION"

echo "▶ Building FlowTrack $TAG for release..."

# ── Prep ─────────────────────────────────────────────────────────────────────

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# ExportOptions.plist — Direct Distribution (no App Store, no notarization required)
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

# ── Archive ───────────────────────────────────────────────────────────────────

echo "📦 Archiving..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    2>&1 | grep -E "error:|warning:|archive|ARCHIVE|BUILD" | grep -v appintents

echo "✅ Archive done"

# ── Export ────────────────────────────────────────────────────────────────────

echo "📤 Exporting .app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$APP_EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    2>&1 | grep -E "error:|Export|BUILD" | grep -v appintents

APP_PATH=$(find "$APP_EXPORT_DIR" -name "*.app" -maxdepth 2 | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "❌ Could not find exported .app — check build output"
    exit 1
fi
echo "✅ App exported: $APP_PATH"

# ── DMG ───────────────────────────────────────────────────────────────────────

DMG_NAME="FlowTrack-$TAG.dmg"
DMG_PATH="$EXPORT_DIR/$DMG_NAME"
DMG_STAGING="$EXPORT_DIR/dmg_staging"

echo "💿 Creating DMG..."

# Build a staging folder: app + symlink to /Applications (drag-to-install UX)
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create a writable DMG from the staging folder
TMP_DMG="$EXPORT_DIR/tmp.dmg"
hdiutil create \
    -volname "FlowTrack $TAG" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDRW \
    "$TMP_DMG" \
    > /dev/null

# Convert to compressed read-only DMG
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH" > /dev/null
rm "$TMP_DMG"

SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo "✅ $DMG_NAME ($SIZE)"

# ── GitHub Release ────────────────────────────────────────────────────────────

echo "🚀 Creating GitHub Release $TAG..."

# Check if tag already exists
if gh release view "$TAG" &>/dev/null 2>&1; then
    echo "⚠️  Release $TAG already exists. Uploading asset only..."
    gh release upload "$TAG" "$DMG_PATH" --clobber
else
    gh release create "$TAG" "$DMG_PATH" \
        --title "FlowTrack $TAG" \
        --notes "$NOTES" \
        --repo busahinku/flowtrack
fi

RELEASE_URL=$(gh release view "$TAG" --json url -q '.url' --repo busahinku/flowtrack)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅  Released: FlowTrack $TAG"
echo "🔗  $RELEASE_URL"
echo ""
echo "Share this download link with your friend:"
gh release view "$TAG" --json assets --repo busahinku/flowtrack \
    -q '.assets[] | select(.name | endswith(".dmg")) | .browserDownloadUrl'
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Cleanup ───────────────────────────────────────────────────────────────────

rm -rf "$EXPORT_DIR"
echo "🧹 Build artifacts cleaned up"
