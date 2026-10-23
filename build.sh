#!/bin/zsh
# Builds "build/Expert PDF Reader.app".
#
#   ARCHS="arm64 x86_64"   architectures to compile (default: this Mac's); more than one gives a universal binary
#   VERSION=1.2.3          CFBundleShortVersionString (default: the one in Support/Info.plist)
#   BUILD_NUMBER=42        CFBundleVersion
#   CODESIGN_IDENTITY=...  "Developer ID Application: …" for distribution (default: ad-hoc "-")
#   SDK_PATH=...           macOS SDK to build against (default: xcrun's)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Expert PDF Reader"
EXECUTABLE="ExpertPDFReader"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
TARGET_ARCHS=(${=ARCHS:-$(uname -m)})
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SOURCES=(Sources/ExpertPDFReader/**/*.swift)

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$MODULE_CACHE"

PLIST="$APP_BUNDLE/Contents/Info.plist"
cp Support/Info.plist "$PLIST"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

# The page-theme Metal shaders are compiled at runtime from the source in MetalShaderRenderer.swift,
# so no .metallib is bundled.
cp -R Sources/ExpertPDFReader/Resources/en.lproj Sources/ExpertPDFReader/Resources/zh-Hans.lproj "$APP_BUNDLE/Contents/Resources/"
# Original app icon (regenerate with: swift scripts/make_app_icon.swift)
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

BINARIES=()
for arch in $TARGET_ARCHS; do
    echo "Compiling $APP_NAME for $arch using SDK: $SDK_PATH ..."
    mkdir -p "$BUILD_DIR/$arch"
    SDKROOT="$SDK_PATH" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc \
        -sdk "$SDK_PATH" \
        -target "$arch-apple-macos14.0" \
        -module-name "$EXECUTABLE" \
        -module-cache-path "$MODULE_CACHE" \
        -O \
        -parse-as-library \
        "${SOURCES[@]}" \
        -o "$BUILD_DIR/$arch/$EXECUTABLE"
    BINARIES+=("$BUILD_DIR/$arch/$EXECUTABLE")
done
lipo -create "${BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

# Extended attributes (Finder info, quarantine) make codesign refuse the bundle.
xattr -cr "$APP_BUNDLE"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_BUNDLE"
else
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
fi

echo "✅ Built $APP_BUNDLE ($(lipo -archs "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"))"
