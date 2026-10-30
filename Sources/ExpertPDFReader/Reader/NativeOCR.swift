import AppKit
import Darwin

struct RecognizedTextLine: Decodable {
    let text: String
    let confidence: Double
    let x, y, width, height: Double
    let characters: [RecognizedTextCharacter]?
    var maxY: Double { y + height }

    init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double,
         characters: [RecognizedTextCharacter]? = nil) {
        self.text = text; self.confidence = confidence
        self.x = x; self.y = y; self.width = width; self.height = height
        self.characters = characters
    }
}

struct RecognizedTextCharacter: Decodable {
    let text: String
    let confidence: Double
    let x, y, width, height: Double
}

/// A CPU-only native PP-OCRv6 model, loaded once on demand. No Python process or network is used at runtime.
enum NativeOCR {
    private typealias Recognize = @convention(c) (UnsafePointer<CChar>, UnsafePointer<UInt8>, Int32, Int32) -> UnsafeMutablePointer<CChar>?
    private typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
    private struct Response: Decodable { let lines: [RecognizedTextLine]?; let error: String? }
    private static let library: UnsafeMutableRawPointer? = {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("libReaderOCR.dylib") else { return nil }
        return dlopen(url.path, RTLD_NOW | RTLD_LOCAL)
    }()

    static func recognize(_ image: BookPageScanner.PageImage, includingCharacters: Bool = false) throws -> [RecognizedTextLine]? {
        guard let library, let symbol = dlsym(library, includingCharacters ? "reader_ocr_characters" : "reader_ocr"), let freeSymbol = dlsym(library, "reader_ocr_free"),
              let models = Bundle.main.resourceURL?.appendingPathComponent("OCR") else { return nil }
        let recognize = unsafeBitCast(symbol, to: Recognize.self)
        let release = unsafeBitCast(freeSymbol, to: Release.self)
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for (index, gray) in image.pixels.enumerated() {
            rgb[index * 3] = gray; rgb[index * 3 + 1] = gray; rgb[index * 3 + 2] = gray
        }
        let pointer = rgb.withUnsafeBufferPointer { buffer in
            models.path.withCString { recognize($0, buffer.baseAddress!, Int32(image.width), Int32(image.height)) }
        }
        guard let pointer else { throw PageTextRecognition.Failure.noText }
        defer { release(pointer) }
        let response = try JSONDecoder().decode(Response.self, from: Data(bytes: pointer, count: strlen(pointer)))
        if let error = response.error { throw NSError(domain: "ReaderOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        return response.lines
    }
}

/// Preserve paragraph gaps and indents, but join physical line/column wraps in a sentence.
enum OCRTextLayout {
    private static func blocks(from recognized: [RecognizedTextLine], vertical: Bool, pageHeight: Int?) -> ([[RecognizedTextLine]], Double) {
        let lines = recognized.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let pageNumber = pageHeight.map { height in line.y > Double(height) * 0.93 && text.count <= 5 && text.allSatisfy(\.isNumber) } ?? false
            let ornament = line.width > line.height * 15 && text.count <= 4 && text.allSatisfy { $0.isPunctuation || $0.isNumber || $0.isSymbol }
            let rule = text == "—" || text == "——" || (line.confidence < 0.8 && text.hasPrefix("—") && text.count <= 3)
            return line.confidence >= 0.35 && !text.isEmpty && !pageNumber && !ornament && !rule
        }
        guard !lines.isEmpty else { return ([], 1) }
        let sizes = lines.map { vertical ? $0.width : $0.height }.sorted()
        let glyph = sizes[sizes.count / 2]
        var blocks: [[RecognizedTextLine]] = []
        for line in lines.sorted(by: { $0.y < $1.y }) {
            if let last = blocks.last, line.y <= (last.map(\.maxY).max() ?? 0) + glyph * 2 {
                blocks[blocks.count - 1].append(line)
            } else { blocks.append([line]) }
        }
        return (blocks.map { block in
            block.sorted { a, b in
                if vertical {
                    if abs(a.x - b.x) > glyph * 0.5 { return a.x > b.x }
                    return a.y < b.y
                }
                if abs(a.y - b.y) > glyph * 0.5 { return a.y < b.y }
                return a.x < b.x
            }
        }, glyph)
    }

    static func orderedLines(from recognized: [RecognizedTextLine], vertical: Bool, pageHeight: Int? = nil) -> [RecognizedTextLine] {
        blocks(from: recognized, vertical: vertical, pageHeight: pageHeight).0.flatMap { $0 }
    }

    static func text(from recognized: [RecognizedTextLine], vertical: Bool, pageHeight: Int? = nil) -> String {
        let (blocks, glyph) = Self.blocks(from: recognized, vertical: vertical, pageHeight: pageHeight)
        return blocks.map { sorted in
            let block = sorted
            let start = block.map { vertical ? $0.y : $0.x }.min() ?? 0
            let pitches = zip(sorted, sorted.dropFirst()).map { $1.y - $0.y }.filter { $0 > glyph * 0.5 }.sorted()
            let pitch = pitches.isEmpty ? glyph * 2 : pitches[pitches.count / 2]
            let shortHeading = block.count <= 4 && (vertical
                ? (block.map(\.height).max() ?? 0) < glyph * 12
                : (block.map(\.width).max() ?? 0) < glyph * 8)
            var result = ""
            var previous: RecognizedTextLine?
            for line in sorted {
                let text = PDFTextCleanup.normalize(line.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if let previous {
                    let indent = (vertical ? line.y : line.x) - start > glyph * 1.2
                    let gap = !vertical && line.y - previous.y > pitch * 1.45
                    let heading = !vertical && (line.height > glyph * 1.7 || previous.height > glyph * 1.7)
                    if shortHeading { result += "\n" }
                    else if indent || gap || heading { result += "\n\n" }
                    else if result.hasSuffix("-"), text.first?.isLowercase == true { result.removeLast() }
                    else if let last = result.last, let first = text.first,
                            last.isASCII && first.isASCII,
                            last.isLetter || last.isNumber || ",.;:!?)]}\"'".contains(last),
                            first.isLetter || first.isNumber || "(\"'".contains(first) { result += " " }
                }
                result += text
                previous = line
            }
            return result
        }.joined(separator: "\n\n")
    }
}
