#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/prepare_ocr.py
OCR_CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [[ -z "$OCR_CMAKE" ]]; then
    # Build tool only. The resulting application contains no Python environment.
    [[ -x build/OCRTools/bin/cmake ]] || {
        python3 -m venv build/OCRTools
        build/OCRTools/bin/python -m pip install --disable-pip-version-check 'cmake==4.4.4'
    }
    OCR_CMAKE="$PWD/build/OCRTools/bin/cmake"
fi
OCR_SOURCE="$PWD/build/OCRCache/RapidOCRLite-4b6ea0935158aef0af911500f18058f1c87e96b2"
OCR_BINARIES=()
for arch in ${=ARCHS:-$(uname -m)}; do
    directory="$PWD/build/OCR-$arch"
    "$OCR_CMAKE" -S Support/OCR -B "$directory" -G 'Unix Makefiles' \
        -DRAPIDOCR_SOURCE="$OCR_SOURCE" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$arch" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++
    "$OCR_CMAKE" --build "$directory" --target ReaderOCR -j4
    OCR_BINARIES+=("$directory/libReaderOCR.dylib")
done
mkdir -p 'build/Expert PDF Reader.app/Contents/Frameworks' 'build/Expert PDF Reader.app/Contents/Resources/OCR'
lipo -create $OCR_BINARIES -output 'build/Expert PDF Reader.app/Contents/Frameworks/libReaderOCR.dylib'
cp build/OCRCache/models/* 'build/Expert PDF Reader.app/Contents/Resources/OCR/'
codesign --force --sign "${CODESIGN_IDENTITY:--}" 'build/Expert PDF Reader.app/Contents/Frameworks/libReaderOCR.dylib'
