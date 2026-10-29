#!/bin/zsh
# Use SDK_PATH as with build.sh if the newest SDK needs Xcode's SwiftUI macro plugin.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
SOURCES=()
for source_file in Sources/ExpertPDFReader/**/*.swift; do
    [[ "$source_file" == Sources/ExpertPDFReader/App/ExpertPDFReaderApp.swift ]] || SOURCES+=("$source_file")
done
mkdir -p build/ModuleCache
swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macos14.0" -module-cache-path build/ModuleCache -parse-as-library \
    "${SOURCES[@]}" scripts/ReaderRegressionTests.swift -o build/ReaderRegressionTests
build/ReaderRegressionTests
