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
TEST_SOURCE=scripts/ReaderRegressionTests.swift
TEST_BINARY=build/ReaderRegressionTests
if [[ "${1:-}" == "--ui" ]]; then
    TEST_SOURCE=scripts/TabDragQATests.swift
    TEST_APP="build/Tab Drag QA.app"
    TEST_BINARY="$TEST_APP/Contents/MacOS/TabDragQATests"
    mkdir -p "$TEST_APP/Contents/MacOS"
    cp Support/Info.plist "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.inkcitrus.expertpdfreader.selfdragqa' "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable TabDragQATests' "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tab Drag QA' "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tab Drag QA' "$TEST_APP/Contents/Info.plist"
fi
swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macos14.0" -module-cache-path build/ModuleCache -parse-as-library \
    "${SOURCES[@]}" "$TEST_SOURCE" -o "$TEST_BINARY"
"$TEST_BINARY"
