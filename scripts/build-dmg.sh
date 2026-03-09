#!/bin/bash
set -euo pipefail

# Build ideas.app and package it into a DMG + ZIP (for Sparkle updates)
# Usage: ./scripts/build-dmg.sh [version]
# Example: ./scripts/build-dmg.sh 0.1.0

VERSION="${1:-dev}"
SCHEME="ideas"
APP_NAME="ideas"
BUILD_DIR="build"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

echo "==> Building ${APP_NAME} v${VERSION}..."

# Clean build directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Archive
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination "generic/platform=macOS" \
    -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
    -configuration Release \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d)" \
    | tail -5

# Export the .app from the archive
echo "==> Exporting app..."
APP_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found"
    exit 1
fi

# Create DMG (for manual download)
echo "==> Creating DMG..."
DMG_TEMP="${BUILD_DIR}/dmg-staging"
mkdir -p "${DMG_TEMP}"
cp -R "${APP_PATH}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov \
    -format UDZO \
    "${BUILD_DIR}/${DMG_NAME}"

rm -rf "${DMG_TEMP}"

# Create ZIP (for Sparkle auto-updates)
echo "==> Creating ZIP for Sparkle..."
cd "${BUILD_DIR}"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app" "${ZIP_NAME}"
cd ..

echo ""
echo "==> Done!"
echo "    DMG: ${BUILD_DIR}/${DMG_NAME} ($(du -h "${BUILD_DIR}/${DMG_NAME}" | cut -f1))"
echo "    ZIP: ${BUILD_DIR}/${ZIP_NAME} ($(du -h "${BUILD_DIR}/${ZIP_NAME}" | cut -f1))"
