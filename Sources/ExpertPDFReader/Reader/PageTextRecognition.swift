import AppKit
import PDFKit
import Vision

/// PDFKit can select text outside a nested form's clip or underneath later drawing commands.
/// Validate the page's native character geometry against its rendered pixels before starting selection.
@MainActor
enum PDFSelectionVisibility {
    private final class Decision {
        let box: CGRect
        let requiresRecognition: Bool
        init(box: CGRect, requiresRecognition: Bool) {
            self.box = box; self.requiresRecognition = requiresRecognition
        }
    }
    // Weak keys do not keep closed documents alive. A margin change invalidates the saved geometry.
    private static let decisions = NSMapTable<PDFPage, Decision>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func cachedDecision(for page: PDFPage) -> Bool? {
        guard let decision = decisions.object(forKey: page), decision.box == page.bounds(for: .cropBox) else { return nil }
        return decision.requiresRecognition
    }

    static func requiresVisualSelection(on page: PDFPage) -> Bool {
        if let decision = cachedDecision(for: page) { return decision }
        let required = page.hasFullPageScanImage || hasInvisibleCharacters(on: page)
        decisions.setObject(Decision(box: page.bounds(for: .cropBox), requiresRecognition: required), forKey: page)
        return required
    }

    private static func hasInvisibleCharacters(on page: PDFPage) -> Bool {
        let text = (page.string ?? "") as NSString
        guard page.rotation % 360 == 0, text.length >= 6,
              let image = PageTextRecognition.render(page, maximumDimension: 1600) else { return false }
        let box = page.bounds(for: .cropBox)
        let scaleX = CGFloat(image.width) / box.width, scaleY = CGFloat(image.height) / box.height
        func isBlank(_ rect: CGRect) -> Bool {
            let left = max(0, Int(floor((rect.minX - box.minX) * scaleX)) - 1)
            let right = min(image.width, Int(ceil((rect.maxX - box.minX) * scaleX)) + 1)
            let top = max(0, Int(floor((box.maxY - rect.maxY) * scaleY)) - 1)
            let bottom = min(image.height, Int(ceil((box.maxY - rect.minY) * scaleY)) + 1)
            guard left < right, top < bottom else { return false }
            var low = UInt8.max, high = UInt8.min
            for row in top..<bottom {
                for column in left..<right {
                    let pixel = image.pixels[row * image.width + column]
                    low = min(low, pixel); high = max(high, pixel)
                    if Int(high) - Int(low) > 3 { return false }
                }
            }
            return true
        }
        var missing = 0
        for index in 0..<min(page.numberOfCharacters, text.length) {
            guard let scalar = Unicode.Scalar(text.character(at: index)), CharacterSet.letters.contains(scalar) else { continue }
            let rect = page.characterBounds(at: index).intersection(box)
            guard !rect.isNull, !rect.isInfinite, rect.width > 0.5, rect.height > 1,
                  rect.width * scaleX >= 1.5, rect.height * scaleY >= 4 else { continue }
            if isBlank(rect) {
                missing += 1
                // Require several absent letters, ignoring spaces, control characters and tiny fragments.
                if missing >= 6 { return true }
            }
        }
        return false
    }
}

/// Remove PDF glyph spacing and soft Chinese wraps. Keep paragraph breaks, indentation and Latin spacing.
enum PDFTextCleanup {
    private static let extraSpaces = try! NSRegularExpression(
        pattern: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}，。！？；：、（）「」『』《》〈〉【】“”‘’])[\p{Zs}]+(?=[\p{Han}\p{Hiragana}\p{Katakana}，。！？；：、（）「」『』《》〈〉【】“”‘’])"#
    )

    // A single line break inside a Chinese sentence is page wrapping. Keep blank lines, indentation,
    // and sentence-ending paragraph boundaries; Latin code and lists are left alone.
    private static let wrappedChineseLine = try! NSRegularExpression(
        pattern: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}，、：])\r?\n(?=[\p{Han}\p{Hiragana}\p{Katakana}])"#
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
        let compact = extraSpaces.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "")
        return wrappedChineseLine.stringByReplacingMatches(in: compact, range: NSRange(compact.startIndex..., in: compact), withTemplate: "")
    }

    static func normalize(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        for (range, glyph) in compatibilityReplacements(in: text.string).reversed() { result.replaceCharacters(in: range, with: glyph) }
        for match in extraSpaces.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
            result.deleteCharacters(in: match.range)
        }
        for match in wrappedChineseLine.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
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

    static func recognize(pageData: Data, selectionBounds: CGRect? = nil) throws -> String {
        guard let document = PDFDocument(data: pageData), let page = document.page(at: 0),
              var image = render(page) else { throw Failure.unreadable }
        defer { withExtendedLifetime(document) {} }
        let vertical = BookPageScanner.writingDirection(in: image) == .vertical
        if let selectionBounds, page.rotation == 0 {
            let box = page.bounds(for: .cropBox)
            let selected = selectionBounds.intersection(box)
            let scaleX = CGFloat(image.width) / box.width, scaleY = CGFloat(image.height) / box.height
            let rect = CGRect(x: (selected.minX - box.minX) * scaleX, y: (box.maxY - selected.maxY) * scaleY,
                              width: selected.width * scaleX, height: selected.height * scaleY)
                .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !rect.isEmpty, let cropped = image.cgImage.cropping(to: rect) else { throw Failure.noText }
            var pixels: [UInt8] = []
            pixels.reserveCapacity(Int(rect.width * rect.height))
            for row in Int(rect.minY)..<Int(rect.maxY) {
                pixels.append(contentsOf: image.pixels[(row * image.width + Int(rect.minX))..<(row * image.width + Int(rect.maxX))])
            }
            image = .init(pixels: pixels, width: Int(rect.width), height: Int(rect.height), cgImage: cropped)
        }
        if let lines = try NativeOCR.recognize(image) {
            let text = OCRTextLayout.text(from: lines, vertical: vertical, pageHeight: selectionBounds == nil ? image.height : nil)
            guard !text.isEmpty else { throw Failure.noText }
            return text
        }
        let input = image.cgImage
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

    static func render(_ page: PDFPage, maximumDimension: CGFloat = 2200) -> BookPageScanner.PageImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(3, maximumDimension / max(size.width, size.height))
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

}
