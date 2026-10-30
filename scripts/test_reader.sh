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
if [[ "${1:-}" == "--ui" || "${1:-}" == "--scene" ]]; then
    TEST_SOURCE=scripts/TabDragQATests.swift
    TEST_APP="build/Tab Drag QA.app"
    TEST_BINARY="$TEST_APP/Contents/MacOS/TabDragQATests"
    mkdir -p "$TEST_APP/Contents/MacOS"
    cp Support/Info.plist "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.inkcitrus.expertpdfreader.selfdragqa' "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable TabDragQATests' "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tab Drag QA' "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tab Drag QA' "$TEST_APP/Contents/Info.plist"
    if [[ "${1:-}" == "--scene" ]]; then
        TEST_SOURCE=scripts/WindowSceneQATests.swift
        /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.inkcitrus.expertpdfreader.sceneqa' "$TEST_APP/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Set :CFBundleName Window Scene QA' "$TEST_APP/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Window Scene QA' "$TEST_APP/Contents/Info.plist"
    fi
fi
swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macos14.0" -module-cache-path build/ModuleCache -parse-as-library \
    "${SOURCES[@]}" "$TEST_SOURCE" -o "$TEST_BINARY"
"$TEST_BINARY"
if [[ "${1:-}" != "--ui" && "${1:-}" != "--scene" ]]; then
    swiftc -sdk "$SDK_PATH" -module-cache-path build/ModuleCache -parse-as-library \
        Sources/ExpertPDFReader/Models/ReaderRelease.swift scripts/UpdateCheckTests.swift -o build/UpdateCheckTests
    build/UpdateCheckTests
    SEARCH_TEST_APP="build/Menu Command Search QA.app"
    SEARCH_TEST_BINARY="$SEARCH_TEST_APP/Contents/MacOS/MenuCommandSearchTests"
    mkdir -p "$SEARCH_TEST_APP/Contents/MacOS"
    cp Support/Info.plist "$SEARCH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.inkcitrus.expertpdfreader.menusearchqa' "$SEARCH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable MenuCommandSearchTests' "$SEARCH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Menu Command Search QA' "$SEARCH_TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Menu Command Search QA' "$SEARCH_TEST_APP/Contents/Info.plist"
    swiftc -sdk "$SDK_PATH" -module-cache-path build/ModuleCache -parse-as-library \
        Sources/ExpertPDFReader/App/MenuCommandSearch.swift scripts/MenuCommandSearchTests.swift -o "$SEARCH_TEST_BINARY"
    "$SEARCH_TEST_BINARY"
fi
