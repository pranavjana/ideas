#!/bin/bash
set -euo pipefail

# Build, sign, and publish a release to GitHub
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 0.1.0-alpha

VERSION="${1:?Usage: ./scripts/release.sh <version>}"
TAG="v${VERSION}"
REPO="pranavjana/ideas"

echo "==> Releasing ideas ${TAG}..."

# Step 1: Build DMG + ZIP
./scripts/build-dmg.sh "${VERSION}"

# Step 2: Sign the ZIP with Sparkle EdDSA key
echo "==> Signing ZIP with Sparkle..."
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle.framework/../bin/sign_update" -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -1)

if [ -n "$SIGN_TOOL" ]; then
    SIGNATURE=$("$SIGN_TOOL" "build/ideas-${VERSION}.zip" 2>&1)
    echo "    Signature: ${SIGNATURE}"
else
    echo "    Warning: sign_update not found, skipping signing"
    SIGNATURE=""
fi

# Step 3: Update appcast.xml
echo "==> Updating appcast.xml..."
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/ideas-${VERSION}.zip"
ZIP_SIZE=$(stat -f%z "build/ideas-${VERSION}.zip")
PUB_DATE=$(date -R)

# Extract edSignature if present
ED_SIG_ATTR=""
if [ -n "$SIGNATURE" ]; then
    ED_SIG=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' || true)
    if [ -n "$ED_SIG" ]; then
        ED_SIG_ATTR=" ${ED_SIG}"
    fi
fi

cat > appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>ideas</title>
        <description>ideas app updates</description>
        <language>en</language>
        <item>
            <title>v${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure url="${ZIP_URL}" length="${ZIP_SIZE}" type="application/octet-stream"${ED_SIG_ATTR} />
        </item>
    </channel>
</rss>
EOF

# Step 4: Commit appcast + tag + push
echo "==> Committing appcast and tagging ${TAG}..."
git add appcast.xml
git commit -m "Update appcast for ${TAG}" || true
git tag -f "${TAG}"
git push origin main
git push origin "${TAG}" --force

# Step 5: Create GitHub release with assets
echo "==> Creating GitHub release..."
gh release create "${TAG}" \
    "build/ideas-${VERSION}.dmg" \
    "build/ideas-${VERSION}.zip" \
    --repo "${REPO}" \
    --prerelease \
    --generate-notes \
    --title "ideas ${TAG} (alpha)" \
    --notes "## ideas ${TAG} (alpha)

> ⚠️ **First launch**: Right-click the app → Open (required once to bypass Gatekeeper)

### Install
1. Download \`ideas-${VERSION}.dmg\` below
2. Open the DMG and drag **ideas** to Applications
3. Right-click → Open on first launch

### Auto-updates
Already installed? The app will notify you of this update automatically."

echo ""
echo "==> Done! Release published at:"
echo "    https://github.com/${REPO}/releases/tag/${TAG}"
