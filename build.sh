#!/bin/zsh
# Builds "build/Expert PDF Reader.app".
#
#   ARCHS="arm64 x86_64"   architectures to compile (default: this Mac's); more than one gives a universal binary
#   VERSION=1.2.3          CFBundleShortVersionString (default: the one in Support/Info.plist)
#   BUILD_NUMBER=42        CFBundleVersion
#   CODESIGN_IDENTITY=...  "Developer ID Application: …" for distribution (default: ad-hoc "-")
#   SDK_PATH=...           macOS SDK to build against (default: xcrun's; without Xcode, the newest one that works)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Expert PDF Reader"
EXECUTABLE="ExpertPDFReader"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
TARGET_ARCHS=(${=ARCHS:-$(uname -m)})
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SOURCES=(Sources/ExpertPDFReader/**/*.swift)

# From the macOS 27 SDK on, SwiftUI's @State is a macro of the SwiftUIMacros compiler plugin, which comes with Xcode
# but not with the Command Line Tools. True if SDK $1 doesn't need that plugin or swiftc can find it.
sdk_usable() {
    grep -qs 'module: "SwiftUIMacros", type: "StateMacro"' \
        "$1"/System/Library/Frameworks/SwiftUI*.framework/Modules/*.swiftmodule/*.swiftinterface(N) </dev/null || return 0
    # swiftc looks for lib<module>.dylib in the plugin folders it passes to the frontend
    local args=(${(Q)${(z)"$(swiftc -### -sdk "$1" -typecheck - </dev/null 2>/dev/null)"}}) i
    for ((i = 1; i < $#args; i++)); do
        [[ $args[i] == (-plugin-path|-external-plugin-path) && -e ${args[i+1]%%\#*}/libSwiftUIMacros.dylib ]] && return 0
    done
    return 1
}

if [[ -n "${SDK_PATH:-}" ]]; then
    SDK_CANDIDATES=("$SDK_PATH")
else
    # xcrun's SDK, then the other SDKs next to it, newest first
    DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    SDK_CANDIDATES=("$DEFAULT_SDK" "${DEFAULT_SDK:h}"/MacOSX*.sdk(N/nOn))
fi
SDK_PATH=""
for sdk in $SDK_CANDIDATES; do
    if sdk_usable "$sdk"; then
        SDK_PATH="$sdk"
        break
    fi
done
if [[ -z "$SDK_PATH" ]]; then
    echo "error: ${SDK_CANDIDATES[1]} needs the SwiftUIMacros compiler plugin, which comes with Xcode but not with the Command Line Tools." >&2
    echo "Install Xcode and select it with xcode-select -s, or set SDK_PATH to a macOS 26 or older SDK." >&2
    exit 1
elif [[ "$SDK_PATH" != "${SDK_CANDIDATES[1]}" ]]; then
    echo "note: ${SDK_CANDIDATES[1]} needs Xcode's SwiftUIMacros compiler plugin, building against $SDK_PATH instead"
fi

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
cp -R Sources/ExpertPDFReader/Resources/*.lproj "$APP_BUNDLE/Contents/Resources/"
# Original app icon (regenerate with: swift scripts/make_app_icon.swift)
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

SDK_PATH="$SDK_PATH" ARCHS="${TARGET_ARCHS[*]}" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" zsh scripts/build_ocr.sh

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
