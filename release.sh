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

# Re-sign embedded frameworks and the app with the same ad-hoc identity
echo "🔏 Re-signing app bundle..."
find "$APP_PATH/Contents/Frameworks" -type d -name "*.framework" | while read fw; do
    codesign --force --deep --sign - "$fw" 2>/dev/null
done
codesign --force --deep --sign - "$APP_PATH"
echo "✅ App re-signed"

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

# ── Appcast (Sparkle auto-update feed) ────────────────────────────────────────

echo "📡 Updating appcast.xml..."

DMG_DOWNLOAD_URL=$(gh release view "$TAG" --json assets --repo busahinku/flowtrack \
    -q '.assets[] | select(.name | endswith(".dmg")) | .browserDownloadUrl')
DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat --format=%s "$DMG_PATH")
PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

# EdDSA signature (requires Sparkle's sign_update tool)
SPARKLE_SIGN=""
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN" ]]; then
    SIG=$("$SPARKLE_BIN" "$DMG_PATH" 2>/dev/null || true)
    if [[ -n "$SIG" ]]; then
        SPARKLE_SIGN="sparkle:edSignature=\"$(echo "$SIG" | grep -oE 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)\" length=\"$DMG_SIZE\""
        echo "✅ EdDSA signature generated"
    fi
elif command -v sign_update &>/dev/null; then
    SIG=$(sign_update "$DMG_PATH" 2>/dev/null || true)
    if [[ -n "$SIG" ]]; then
        SPARKLE_SIGN="sparkle:edSignature=\"$(echo "$SIG" | grep -oE 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)\" length=\"$DMG_SIZE\""
        echo "✅ EdDSA signature generated"
    fi
else
    echo "⚠️  sign_update not found — appcast will not include EdDSA signature."
    echo "   Run: ./sparkle-setup.sh to generate signing keys."
fi

# Build appcast.xml
APPCAST_FILE="$SCRIPT_DIR/appcast.xml"
cat > "$APPCAST_FILE" << APPCASTEOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>FlowTrack Updates</title>
    <link>https://raw.githubusercontent.com/busahinku/flowtrack/main/appcast.xml</link>
    <description>Updates for FlowTrack</description>
    <language>en</language>
    <item>
      <title>FlowTrack $VERSION</title>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.6</sparkle:minimumSystemVersion>
      <enclosure url="$DMG_DOWNLOAD_URL" type="application/octet-stream" $SPARKLE_SIGN length="$DMG_SIZE" />
    </item>
  </channel>
</rss>
APPCASTEOF

echo "✅ appcast.xml updated"

# Commit and push appcast.xml so raw.githubusercontent.com serves it
git add "$APPCAST_FILE"
git commit -m "Update appcast.xml for $TAG" --allow-empty 2>/dev/null || true
git push origin main 2>/dev/null || echo "⚠️  Could not push appcast.xml — push manually."

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
