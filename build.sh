#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ ! -d "$SDK_PATH" ]]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

APP_BUNDLE="Expert PDF Reader.app"
MODULE_CACHE="/tmp/expert_pdf_reader_module_cache"
mkdir -p "$MODULE_CACHE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

rm -f "$APP_BUNDLE/Contents/MacOS/OpenPDFExpert"
cp Sources/ExpertPDFReader/Resources/RDPDFShaders.metallib "$APP_BUNDLE/Contents/Resources/RDPDFShaders.metallib"
cp -R Sources/ExpertPDFReader/Resources/en.lproj "$APP_BUNDLE/Contents/Resources/"
cp -R Sources/ExpertPDFReader/Resources/zh-Hans.lproj "$APP_BUNDLE/Contents/Resources/"
# Original app icon (regenerate with: swift scripts/make_app_icon.swift)
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "Compiling $APP_BUNDLE using SDK: $SDK_PATH ..."
SDKROOT="$SDK_PATH" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macos14.0 \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -parse-as-library \
    Sources/ExpertPDFReader/Localization/L10n.swift \
    Sources/ExpertPDFReader/DesignLibrary/RDDesignLibrary.swift \
    Sources/ExpertPDFReader/Shaders/MetalShaderRenderer.swift \
    Sources/ExpertPDFReader/Models/SamplePDFGenerator.swift \
    Sources/ExpertPDFReader/Models/AppStore.swift \
    Sources/ExpertPDFReader/HomeTab/HomeTabView.swift \
    Sources/ExpertPDFReader/Reader/PDFReaderCanvasView.swift \
    Sources/ExpertPDFReader/Reader/ReaderSidebarsAndToolbars.swift \
    Sources/ExpertPDFReader/Reader/ReaderOverlays.swift \
    Sources/ExpertPDFReader/Reader/PDFReaderView.swift \
    Sources/ExpertPDFReader/App/WindowChrome.swift \
    Sources/ExpertPDFReader/App/MainWindowView.swift \
    Sources/ExpertPDFReader/App/SettingsView.swift \
    Sources/ExpertPDFReader/App/ExpertPDFReaderApp.swift \
    -o "$APP_BUNDLE/Contents/MacOS/ExpertPDFReader"

codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
echo "✅ Built $APP_BUNDLE successfully!"
