#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ ! -d "$SDK_PATH" ]]; then
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

MODULE_CACHE="/tmp/open_pdf_expert_module_cache"
mkdir -p "$MODULE_CACHE"
mkdir -p OpenPDFExpert.app/Contents/MacOS OpenPDFExpert.app/Contents/Resources

cp Sources/OpenPDFExpert/Resources/RDPDFShaders.metallib OpenPDFExpert.app/Contents/Resources/RDPDFShaders.metallib
# Original app icon (regenerate with: swift scripts/make_app_icon.swift)
cp Assets/AppIcon.icns OpenPDFExpert.app/Contents/Resources/AppIcon.icns

echo "Compiling OpenPDFExpert.app using SDK: $SDK_PATH ..."
SDKROOT="$SDK_PATH" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macos14.0 \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -parse-as-library \
    Sources/OpenPDFExpert/DesignLibrary/RDDesignLibrary.swift \
    Sources/OpenPDFExpert/Shaders/MetalShaderRenderer.swift \
    Sources/OpenPDFExpert/Models/SamplePDFGenerator.swift \
    Sources/OpenPDFExpert/Models/AppStore.swift \
    Sources/OpenPDFExpert/HomeTab/HomeTabView.swift \
    Sources/OpenPDFExpert/Reader/PDFReaderCanvasView.swift \
    Sources/OpenPDFExpert/Reader/ReaderSidebarsAndToolbars.swift \
    Sources/OpenPDFExpert/Reader/ReaderOverlays.swift \
    Sources/OpenPDFExpert/Reader/PDFReaderView.swift \
    Sources/OpenPDFExpert/App/WindowChrome.swift \
    Sources/OpenPDFExpert/App/MainWindowView.swift \
    Sources/OpenPDFExpert/App/SettingsView.swift \
    Sources/OpenPDFExpert/App/OpenPDFExpertApp.swift \
    -o OpenPDFExpert.app/Contents/MacOS/OpenPDFExpert

codesign --force --deep --sign - OpenPDFExpert.app 2>/dev/null || true
echo "✅ Built OpenPDFExpert.app successfully!"
