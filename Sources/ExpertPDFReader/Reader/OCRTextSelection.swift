import AppKit
import PDFKit

/// Character positions come from the recognizer's CTC alignment, not the PDF's existing text layer.
struct OCRPageText: Sendable {
    struct Glyph: Sendable {
        let range: NSRange
        let bounds: CGRect
        let line: Int
    }
    let text: String
    let glyphs: [Glyph]
    let isVertical: Bool

    init(lines: [RecognizedTextLine], vertical: Bool, imageSize: CGSize, cropBox: CGRect) {
        self.isVertical = vertical
        self.text = OCRTextLayout.text(from: lines, vertical: vertical, pageHeight: Int(imageSize.height))
        let plain = self.text as NSString
        var cursor = 0
        var glyphs: [Glyph] = []
        for (lineIndex, line) in OCRTextLayout.orderedLines(from: lines, vertical: vertical, pageHeight: Int(imageSize.height)).enumerated() {
            var lineText = PDFTextCleanup.normalize(line.text).trimmingCharacters(in: .whitespacesAndNewlines)
            var range = plain.range(of: lineText, range: NSRange(location: cursor, length: plain.length - cursor))
            if range.location == NSNotFound, lineText.hasSuffix("-") {
                lineText.removeLast()
                range = plain.range(of: lineText, range: NSRange(location: cursor, length: plain.length - cursor))
            }
            guard range.location != NSNotFound else { continue }
            let lineString = lineText as NSString
            var characterCursor = 0
            for character in line.characters ?? [] {
                let characterText = PDFTextCleanup.normalize(character.text)
                guard !characterText.isEmpty, character.width > 0, character.height > 0 else { continue }
                let found = lineString.range(of: characterText, range: NSRange(location: characterCursor, length: lineString.length - characterCursor))
                guard found.location != NSNotFound else { continue }
                let bounds = CGRect(x: cropBox.minX + character.x / imageSize.width * cropBox.width,
                                    y: cropBox.maxY - (character.y + character.height) / imageSize.height * cropBox.height,
                                    width: character.width / imageSize.width * cropBox.width,
                                    height: character.height / imageSize.height * cropBox.height)
                glyphs.append(Glyph(range: NSRange(location: range.location + found.location, length: found.length), bounds: bounds, line: lineIndex))
                characterCursor = NSMaxRange(found)
            }
            cursor = NSMaxRange(range)
        }
        self.glyphs = glyphs
    }

    func nearestGlyph(to point: CGPoint) -> Int? {
        glyphs.indices.min {
            let a = glyphs[$0].bounds, b = glyphs[$1].bounds
            let da = distance(point, from: a), db = distance(point, from: b)
            if abs(da - db) > 0.0001 { return da < db }
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        }
    }

    private func distance(_ point: CGPoint, from box: CGRect) -> CGFloat {
        let dx = max(0, max(box.minX - point.x, point.x - box.maxX))
        let dy = max(0, max(box.minY - point.y, point.y - box.maxY))
        return dx * dx + dy * dy
    }

    func selectedText(from anchor: Int, through extent: Int) -> String {
        guard glyphs.indices.contains(anchor), glyphs.indices.contains(extent) else { return "" }
        let first = glyphs[min(anchor, extent)].range
        let last = glyphs[max(anchor, extent)].range
        return (text as NSString).substring(with: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
    }

    func selectedBounds(from anchor: Int, through extent: Int) -> [CGRect] {
        guard glyphs.indices.contains(anchor), glyphs.indices.contains(extent) else { return [] }
        var bounds: [(line: Int, rect: CGRect)] = []
        for glyph in glyphs[min(anchor, extent)...max(anchor, extent)] {
            if bounds.last?.line == glyph.line { bounds[bounds.count - 1].rect = bounds.last!.rect.union(glyph.bounds) }
            else { bounds.append((glyph.line, glyph.bounds)) }
        }
        return bounds.map(\.rect)
    }
}

extension PageTextRecognition {
    static func selectableText(pageData: Data) throws -> OCRPageText {
        guard let document = PDFDocument(data: pageData), let page = document.page(at: 0), page.rotation % 360 == 0,
              let image = render(page), let lines = try NativeOCR.recognize(image, includingCharacters: true) else { throw Failure.unreadable }
        defer { withExtendedLifetime(document) {} }
        let vertical = BookPageScanner.writingDirection(in: image) == .vertical
        let result = OCRPageText(lines: lines, vertical: vertical, imageSize: CGSize(width: image.width, height: image.height), cropBox: page.bounds(for: .cropBox))
        guard !result.glyphs.isEmpty else { throw Failure.noText }
        return result
    }
}
