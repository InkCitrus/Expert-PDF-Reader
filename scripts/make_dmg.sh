#!/bin/zsh
# Packages "build/Expert PDF Reader.app" (run ./build.sh first) into build/Expert-PDF-Reader-<version>.dmg
# with the usual drag-to-Applications layout.
#
#   CODESIGN_IDENTITY=...                       also sign the .dmg ("Developer ID Application: …")
#   NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD
#                                               when all set, notarize the .dmg and staple the ticket
#                                               (NOTARY_PASSWORD is an app-specific password)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Expert PDF Reader"
APP_BUNDLE="build/$APP_NAME.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: $APP_BUNDLE not found, run ./build.sh first" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
DMG="build/Expert-PDF-Reader-$VERSION.dmg"
STAGING="build/dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP_BUNDLE" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# hdiutil intermittently fails with "Resource busy" on CI machines; retry a few times.
for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"; then
        break
    fi
    if [[ $attempt == 3 ]]; then
        exit 1
    fi
    sleep 5
done
rm -rf "$STAGING"

if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$DMG" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait
    xcrun stapler staple "$DMG"
fi

echo "✅ Created $DMG"
