#!/bin/bash
# Sparkle EdDSA Key Setup — run once to generate signing keys for auto-updates.
# The private key is stored in your macOS Keychain.
# The public key is written to FlowTrack/Info.plist (SUPublicEDKey).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFO_PLIST="$SCRIPT_DIR/FlowTrack/Info.plist"

echo "🔑 Sparkle EdDSA Key Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Find sign_update / generate_keys from Sparkle's SPM build artifacts
SPARKLE_BIN_DIR=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin" -type d 2>/dev/null | head -1)

if [[ -z "$SPARKLE_BIN_DIR" ]]; then
    echo "❌ Sparkle tools not found."
    echo "   Build the project in Xcode first (Cmd+B) so SPM downloads Sparkle,"
    echo "   then re-run this script."
    exit 1
fi

GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "❌ generate_keys not found at $SPARKLE_BIN_DIR"
    exit 1
fi

echo "Found Sparkle tools: $SPARKLE_BIN_DIR"
echo ""

# Generate keys (or print existing public key)
OUTPUT=$("$GENERATE_KEYS" 2>&1)
echo "$OUTPUT"

# Extract the public key
PUB_KEY=$(echo "$OUTPUT" | grep -oE '[A-Za-z0-9+/=]{40,}' | head -1)

if [[ -z "$PUB_KEY" ]]; then
    echo ""
    echo "⚠️  Could not auto-extract public key from output."
    echo "   Copy the public key from above and paste it into:"
    echo "   $INFO_PLIST → SUPublicEDKey"
    exit 0
fi

# Write public key to Info.plist
if [[ -f "$INFO_PLIST" ]]; then
    # Replace the empty SUPublicEDKey value
    if grep -q '<key>SUPublicEDKey</key>' "$INFO_PLIST"; then
        sed -i '' "s|<key>SUPublicEDKey</key>.*<string>.*</string>|<key>SUPublicEDKey</key>\n\t<string>$PUB_KEY</string>|" "$INFO_PLIST"
        echo ""
        echo "✅ Public key written to $INFO_PLIST"
    else
        echo "⚠️  SUPublicEDKey not found in $INFO_PLIST — add it manually."
    fi
else
    echo "⚠️  $INFO_PLIST not found. Create it with SUPublicEDKey = $PUB_KEY"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Setup complete!"
echo "   Private key → macOS Keychain (managed by Sparkle)"
echo "   Public key  → $INFO_PLIST"
echo ""
echo "Next: Build & release with ./release.sh"
