#!/usr/bin/env python3
"""Fetch immutable build inputs; extract the ONNX character dictionary without ONNX/Python runtime dependencies."""
import hashlib
import pathlib
import shutil
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/OCRCache"
MODELS = CACHE / "models"
REVISION = "4b6ea0935158aef0af911500f18058f1c87e96b2"
SOURCE = CACHE / ("RapidOCRLite-" + REVISION)


def fetch(url, target, digest):
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".download")
    print("Downloading " + target.name, flush=True)
    urllib.request.urlretrieve(url, temporary)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
        temporary.unlink()
        raise RuntimeError("Checksum mismatch: " + target.name)
    temporary.replace(target)


def fields(data):
    def varint(position):
        value, shift = 0, 0
        while True:
            byte = data[position]
            position += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, position
            shift += 7
    position = 0
    while position < len(data):
        tag, position = varint(position)
        wire = tag & 7
        if wire == 0:
            value, position = varint(position)
        elif wire == 2:
            length, position = varint(position)
            value = data[position:position + length]
            position += length
        elif wire in (1, 5):
            position += 8 if wire == 1 else 4
            continue
        else:
            raise RuntimeError("Unsupported ONNX protobuf wire type")
        yield tag >> 3, value


def main():
    archive = CACHE / "source.tar.gz"
    fetch("https://codeload.github.com/RapidAI/RapidOCRLite/tar.gz/" + REVISION, archive,
          "366f12b05fca98987bc6f76be23217d609e4b0e592049f04ab2f618e875e6938")
    if not SOURCE.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                path = (CACHE / member.name).resolve()
                if CACHE.resolve() not in path.parents or member.issym() or member.islnk():
                    raise RuntimeError("Unexpected archive path")
            tar.extractall(CACHE)
    for kind, digest in [
        ("det", "090f04abcd9d9a7498bc4ebf677e4cb9bdce1fe4197ddb7e529f1ef44e1ff94f"),
        ("rec", "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884")
    ]:
        name = "PP-OCRv6_" + kind + "_small.onnx"
        fetch("https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/" + kind + "/" + name,
              MODELS / name, digest)
    for number, metadata in fields((MODELS / "PP-OCRv6_rec_small.onnx").read_bytes()):
        if number == 14:
            entry = dict(fields(metadata))
            if entry.get(1) == b"character":
                (MODELS / "characters.txt").write_bytes(entry[2])
                break
    else:
        raise RuntimeError("Missing model character dictionary")
    shutil.copyfile(SOURCE / "LICENSE", MODELS / "Apache-2.0.txt")
    shutil.copyfile(SOURCE / "third_party/x86-simd-sort/LICENSE.md", MODELS / "x86-simd-sort-LICENSE.txt")
    shutil.copyfile(ROOT / "Support/OCR/NOTICE.txt", MODELS / "NOTICE.txt")


if __name__ == "__main__":
    main()
