import AppKit
import PDFKit
import Vision

/// Clipboard cleanup is deliberately limited to horizontal spacing between CJK glyphs. Paragraphs,
/// indentation, tabs and the spaces in Latin words keep their meaning.
enum PDFTextCleanup {
    private static let extraSpaces = try! NSRegularExpression(
        pattern: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}，。！？；：、（）「」『』《》〈〉【】“”‘’])[\p{Zs}]+(?=[\p{Han}\p{Hiragana}\p{Katakana}，。！？；：、（）「」『』《》〈〉【】“”‘’])"#
    )

    private static func compatibilityReplacements(in text: String) -> [(NSRange, String)] {
        text.indices.compactMap { index in
            let glyph = String(text[index])
            let isCJKCompatibility = glyph.unicodeScalars.allSatisfy {
                (0x2E80...0x2FD5).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                    || (0x2F800...0x2FA1F).contains($0.value)
            }
            let normalized = isCJKCompatibility ? glyph.precomposedStringWithCompatibilityMapping : glyph
            return glyph == normalized ? nil : (NSRange(index..<text.index(after: index), in: text), normalized)
        }
    }

    static func normalize(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for (range, glyph) in compatibilityReplacements(in: text).reversed() { result.replaceCharacters(in: range, with: glyph) }
        let normalized = result as String
        return extraSpaces.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "")
    }

    static func normalize(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        for (range, glyph) in compatibilityReplacements(in: text.string).reversed() { result.replaceCharacters(in: range, with: glyph) }
        for match in extraSpaces.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
            result.deleteCharacters(in: match.range)
        }
        return result
    }

    /// PDFKit publishes HTML, RTFD, RTF and two plain-text encodings. Clean every version so the receiving
    /// app cannot choose an uncorrected one, while retaining formatting and embedded attachments.
    static func normalize(_ pasteboard: NSPasteboard) {
        guard let items = pasteboard.pasteboardItems,
              items.contains(where: { item in item.string(forType: .string).map { normalize($0) != $0 } == true }) else { return }
        let copies = items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                let name = type.rawValue
                if type == .string || name == "NSStringPboardType", let text = item.string(forType: type) {
                    copy.setString(normalize(text), forType: type)
                } else if name == "public.utf16-external-plain-text" || name == "CorePasteboardFlavorType 0x75743136",
                          let text = String(data: data, encoding: .utf16) {
                    copy.setData(normalize(text).data(using: .utf16) ?? data, forType: type)
                } else if type == .rtf || name == "NeXT Rich Text Format v1.0 pasteboard type",
                          let text = NSAttributedString(rtf: data, documentAttributes: nil) {
                    let normalized = normalize(text)
                    copy.setData(normalized.rtf(from: NSRange(location: 0, length: normalized.length), documentAttributes: [:]) ?? data, forType: type)
                } else if type == .rtfd || name == "NeXT RTFD pasteboard type",
                          let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
                    let normalized = normalize(text)
                    copy.setData(normalized.rtfd(from: NSRange(location: 0, length: normalized.length), documentAttributes: [:]) ?? data, forType: type)
                } else if type == .html || name == "Apple HTML pasteboard type",
                          let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
                    let normalized = normalize(text)
                    copy.setData((try? normalized.data(from: NSRange(location: 0, length: normalized.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])) ?? data, forType: type)
                } else { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(copies)
    }

}

/// On-demand OCR of one private page copy. Never rewrites a PDF or scans a whole book on opening.
enum PageTextRecognition {
    enum Failure: LocalizedError {
        case unreadable, noText
        var errorDescription: String? {
            switch self {
            case .unreadable: return L10n.tr("无法读取此页。", "This page could not be read.")
            case .noText: return L10n.tr("此页没有识别出文字。", "No text was recognized on this page.")
            }
        }
    }

    static func recognize(pageData: Data) throws -> String {
        guard let document = PDFDocument(data: pageData), let page = document.page(at: 0),
              let image = render(page) else { throw Failure.unreadable }
        defer { withExtendedLifetime(document) {} }
        let vertical = BookPageScanner.writingDirection(in: image) == .vertical
        let input = vertical ? reflowVerticalText(in: image) ?? image.cgImage : image.cgImage
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: input).perform([request])
        let lines = (request.results ?? []).sorted { left, right in
            if abs(left.boundingBox.midY - right.boundingBox.midY) > min(left.boundingBox.height, right.boundingBox.height) * 0.5 {
                return left.boundingBox.midY > right.boundingBox.midY
            }
            return left.boundingBox.minX < right.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first?.string }
        let text = PDFTextCleanup.normalize(lines.joined(separator: "\n"))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noText }
        return text
    }

    static func render(_ page: PDFPage) -> BookPageScanner.PageImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(3, 2200 / max(size.width, size.height))
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
            page.draw(with: .cropBox, to: context)
            return context.makeImage()
        }
        return image.map { .init(pixels: pixels, width: width, height: height, cgImage: $0) }
    }

    /// Vision recognizes horizontal Chinese. Segment upright vertical glyphs, then lay those same glyphs
    /// into horizontal rows, with columns taken from right to left. Rotating a whole page would turn the glyphs.
    static func reflowVerticalText(in image: BookPageScanner.PageImage) -> CGImage? {
        let w = image.width, h = image.height
        func runs(_ counts: [Int], threshold: Int, closing: Int) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var start: Int?, last = 0
            for (index, count) in counts.enumerated() where count > threshold {
                if let lower = start, index - last > closing + 1 {
                    ranges.append(lower..<(last + 1))
                    start = index
                } else if start == nil { start = index }
                last = index
            }
            if let start { ranges.append(start..<(last + 1)) }
            return ranges
        }
        var rows = [Int](repeating: 0, count: h)
        var columns = [Int](repeating: 0, count: w)
        for y in h / 50..<h * 49 / 50 {
            for x in w / 50..<w * 49 / 50 where image.pixels[y * w + x] < 160 {
                rows[y] += 1
                columns[x] += 1
            }
        }
        let columnRuns = runs(columns, threshold: max(2, h / 500), closing: max(1, w / 600))
            .filter { $0.count > w / 150 && $0.count < w / 5 }
        guard columnRuns.count >= 3 else { return nil }
        let characterWidth = columnRuns.map(\.count).sorted()[columnRuns.count / 2]
        // Large empty horizontal bands separate a title from its body; read each block top to bottom.
        let blocks = runs(rows, threshold: 1, closing: characterWidth * 2)
        var glyphLines: [[CGRect]] = []
        for block in blocks {
            var blockColumns = [Int](repeating: 0, count: w)
            for y in block {
                for x in w / 50..<w * 49 / 50 where image.pixels[y * w + x] < 160 { blockColumns[x] += 1 }
            }
            let blockRuns = runs(blockColumns, threshold: max(1, block.count / 500), closing: max(1, w / 600))
                .filter { $0.count > w / 150 && $0.count < w / 5 }
            for column in blockRuns.reversed() {
                var ink = [Int](repeating: 0, count: block.count)
                for y in block {
                    for x in column where image.pixels[y * w + x] < 160 { ink[y - block.lowerBound] += 1 }
                }
                let glyphs = runs(ink, threshold: 0, closing: max(1, characterWidth / 9)).map {
                    CGRect(x: column.lowerBound, y: $0.lowerBound + block.lowerBound, width: column.count, height: $0.count)
                }
                guard !glyphs.isEmpty else { continue }
                // Bound the image fed to Vision even on very tall pages.
                for offset in stride(from: 0, to: glyphs.count, by: 28) {
                    glyphLines.append(Array(glyphs[offset..<min(offset + 28, glyphs.count)]))
                }
            }
        }
        guard !glyphLines.isEmpty else { return nil }
        let cell = 48, rowHeight = 68, width = 28 * cell + 24, height = glyphLines.count * rowHeight + 24
        guard height < 16000, let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (row, glyphs) in glyphLines.enumerated() {
            for (column, rect) in glyphs.enumerated() {
                guard let glyph = image.cgImage.cropping(to: rect) else { continue }
                let scale = min(CGFloat(cell - 6) / rect.width, CGFloat(cell - 6) / rect.height)
                let size = CGSize(width: rect.width * scale, height: rect.height * scale)
                context.draw(glyph, in: CGRect(x: CGFloat(12 + column * cell) + (CGFloat(cell) - size.width) / 2,
                    y: CGFloat(height - 12 - (row + 1) * rowHeight) + (CGFloat(rowHeight) - size.height) / 2,
                    width: size.width, height: size.height))
            }
        }
        return context.makeImage()
    }
}
