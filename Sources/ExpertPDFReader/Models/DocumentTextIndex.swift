import AppKit
import AppKit
import Foundation
import PDFKit

/// Searchable text recovered from a scanned page. Geometry is kept in PDF page coordinates so OCR
/// matches can be highlighted even though PDFKit has no selectable text for them.
struct IndexedPageText: Codable, Sendable {
    struct Glyph: Codable, Sendable {
        let location: Int
        let length: Int
        let bounds: CGRect
        let line: Int

        var range: NSRange { NSRange(location: location, length: length) }
    }

    let text: String
    let glyphs: [Glyph]

    init(_ page: OCRPageText) {
        text = page.text
        glyphs = page.glyphs.map {
            Glyph(location: $0.range.location, length: $0.range.length, bounds: $0.bounds, line: $0.line)
        }
    }

    init(text: String) {
        self.text = text
        glyphs = []
    }

    func matches(_ query: String, pageIndex: Int) -> [OCRSearchMatch] {
        let needle = PDFTextCleanup.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let source = text as NSString
        var cursor = 0
        var result: [OCRSearchMatch] = []
        while cursor < source.length {
            let found = source.range(of: needle, options: [.caseInsensitive, .widthInsensitive],
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { break }
            let surrounding = NSRange(location: max(0, found.location - 26),
                                      length: min(source.length, NSMaxRange(found) + 36) - max(0, found.location - 26))
            let context = source.rangeOfComposedCharacterSequences(for: surrounding)
            let snippet = (context.location > 0 ? "…" : "")
                + source.substring(with: context).replacingOccurrences(of: "\n", with: " ")
                + (NSMaxRange(context) < source.length ? "…" : "")
            let matchingGlyphs = glyphs.filter { NSIntersectionRange($0.range, found).length > 0 }
            var lineBounds: [(Int, CGRect)] = []
            for glyph in matchingGlyphs {
                if lineBounds.last?.0 == glyph.line {
                    lineBounds[lineBounds.count - 1].1 = lineBounds.last!.1.union(glyph.bounds)
                } else {
                    lineBounds.append((glyph.line, glyph.bounds))
                }
            }
            result.append(OCRSearchMatch(pageIndex: pageIndex, snippet: snippet,
                                         bounds: lineBounds.map(\.1)))
            cursor = max(NSMaxRange(found), found.location + 1)
        }
        return result
    }
}

struct OCRSearchMatch: Sendable {
    let pageIndex: Int
    let snippet: String
    let bounds: [CGRect]
}

/// A versioned on-disk OCR cache. The identity includes path, modification date and file size, so replacing
/// a PDF never reuses text from its previous contents.
final class DocumentTextIndexSession {
    private struct StoredIndex: Codable {
        var pages: [Int: IndexedPageText] = [:]
    }

    private static let diskLock = NSLock()
    private let cacheURL: URL?
    private var stored: StoredIndex
    private var changed = false

    init(documentURL: URL?) {
        cacheURL = documentURL.flatMap(Self.cacheURL(for:))
        if let cacheURL {
            Self.diskLock.lock()
            let data = try? Data(contentsOf: cacheURL)
            Self.diskLock.unlock()
            stored = data.flatMap { try? JSONDecoder().decode(StoredIndex.self, from: $0) } ?? StoredIndex()
        } else {
            stored = StoredIndex()
        }
    }

    func cachedText(forPageIndex pageIndex: Int) -> IndexedPageText? {
        stored.pages[pageIndex]
    }

    func recognizedText(for page: PDFPage, pageIndex: Int, maximumDimension: CGFloat = 2200) -> IndexedPageText? {
        if let cached = stored.pages[pageIndex] { return cached }
        guard !Task.isCancelled, let data = page.dataRepresentation else { return nil }
        let recognized: IndexedPageText?
        if let positioned = try? PageTextRecognition.selectableText(pageData: data, maximumDimension: maximumDimension) {
            recognized = IndexedPageText(positioned)
        } else if let plain = try? PageTextRecognition.recognize(pageData: data) {
            recognized = IndexedPageText(text: plain)
        } else {
            recognized = nil
        }
        // Only persist glyph-aligned NativeOCR entries so unbundled fallback runs never poison the cache.
        if let recognized, !recognized.glyphs.isEmpty {
            stored.pages[pageIndex] = recognized
            changed = true
        }
        return recognized
    }

    func save() {
        guard changed, let cacheURL, let data = try? JSONEncoder().encode(stored) else { return }
        Self.diskLock.lock()
        defer { Self.diskLock.unlock() }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        changed = false
    }

    private static func cacheURL(for url: URL) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        let identity = "\(url.standardizedFileURL.path):\(modified.timeIntervalSince1970):\(size)"
        var hash: UInt64 = 1469598103934665603
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return caches.appendingPathComponent("ExpertPDFReader/OCRText-v2", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16)).appendingPathExtension("json")
    }
}

enum HybridDocumentSearch {
    /// OCR only pages that are scans or have no meaningful text layer. Native PDFKit search remains the fast
    /// and precise path for ordinary PDFs.
    static func ocrMatches(query: String, document: PDFDocument) -> [OCRSearchMatch] {
        let session = DocumentTextIndexSession(documentURL: document.documentURL)
        defer { session.save() }
        var result: [OCRSearchMatch] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            if let matches = matchesOnPageIfNeeded(page, pageIndex: index, query: query, session: session) {
                result.append(contentsOf: matches)
            }
        }
        return result
    }

    static func enumerateOCRMatches(
        query: String,
        document: PDFDocument,
        onBatch: ([OCRSearchMatch]) async -> Void
    ) async {
        let session = DocumentTextIndexSession(documentURL: document.documentURL)
        defer { session.save() }
        var batch: [OCRSearchMatch] = []
        var lastFlush = Date()
        for index in 0..<document.pageCount {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            if let matches = matchesOnPageIfNeeded(page, pageIndex: index, query: query, session: session),
               !matches.isEmpty {
                batch.append(contentsOf: matches)
                if batch.count >= 20 || Date().timeIntervalSince(lastFlush) > 0.2 {
                    await onBatch(batch)
                    batch.removeAll()
                    lastFlush = Date()
                }
            }
        }
        if !Task.isCancelled && !batch.isEmpty {
            await onBatch(batch)
        }
    }

    private static func matchesOnPageIfNeeded(
        _ page: PDFPage,
        pageIndex: Int,
        query: String,
        session: DocumentTextIndexSession
    ) -> [OCRSearchMatch]? {
        let native = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementCount = native.unicodeScalars.filter { $0.value == 0xFFFD }.count
        let badTextLayer = native.count < 8 || replacementCount * 8 > max(1, native.unicodeScalars.count)
        guard page.hasFullPageScanImage || badTextLayer else { return nil }
        return session.recognizedText(for: page, pageIndex: pageIndex)?.matches(query, pageIndex: pageIndex)
    }
}

struct GeneratedOutlineEntry: Sendable, Equatable {
    let title: String
    let pageIndex: Int
    let level: Int
    let destinationPoint: CGPoint?

    init(title: String, pageIndex: Int, level: Int, destinationPoint: CGPoint? = nil) {
        self.title = title
        self.pageIndex = pageIndex
        self.level = level
        self.destinationPoint = destinationPoint
    }
}

enum AutomaticOutlineGenerator {
    private struct PageLine {
        var text: String
        var bounds: CGRect
        var fontSize: CGFloat
        var endFontSize: CGFloat
        var isBold: Bool
        var isEndBold: Bool
        var isSmallCaps: Bool

        var hasGeometry: Bool { bounds.width > 0 && bounds.height > 0 }
    }

    private struct ExtractedPage {
        let index: Int
        let cropBox: CGRect
        var lines: [PageLine]
        let rawText: String
    }

    /// Logical reading sequence when spreads are stored left-page-first (`oddIndexShift != 0`).
    static func logicalPageOrder(_ index: Int, oddIndexShift: Int) -> Int {
        index + (index % 2 == 1 ? oddIndexShift : 0)
    }

    /// Not anchored: OCR frequently joins two printed TOC rows into one logical line. Iterating every match
    /// recovers both `…(73)第二章…(77)` entries instead of turning the whole line into a bogus title.
    private static let tocEntry = try! NSRegularExpression(
        pattern: #"(.{2,120}?)(?:((?:[\.．·•]\s*){4,}|[\.．·•_—\-]{2,}|…+))\s*[（(]?\s*([ivxlcdmIVXLCDM]+|\d{1,5})\s*[）)]?"#
    )
    private static let leaderOnlyLine = try! NSRegularExpression(
        pattern: #"^[\.．·•_—\-…\s]{3,}[（(]?\s*([ivxlcdmIVXLCDM]+|\d{1,5})\s*[）)]?$"#
    )
    private static let leaderlessTOCEntry = try! NSRegularExpression(
        pattern: #"^(.{2,95}?)\s+([ivxlcdmIVXLCDM]{1,6}|\d{1,5})$"#
    )
    private static let numberedHeading = try! NSRegularExpression(
        pattern: #"^\s*((?:\d+\.)*\d+)[、.．:\s]+(.{1,80})$"#
    )
    private static let strictNumberedHeading = try! NSRegularExpression(
        pattern: #"^\s*([1-9]\d*(?:\.\d+)+[、.．\s]+|[1-9]\d?[、.．]\s+)([\p{L}\p{N}].{1,75})$"#
    )
    private static let chineseHeading = try! NSRegularExpression(
        pattern: #"^\s*(第\s*[一二三四五六七八九十百千万零〇兩两0-9]+\s*[章节節篇部卷])(?:[、.．:\s]+)?(.{0,80})$"#
    )
    private static let englishHeading = try! NSRegularExpression(
        pattern: #"^\s*((?:chapter|part|unit|section|appendix)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[ivxlcdm]+|\d+|[a-z]))(?:[.:：\-\s]+(.{0,80}))?$"#,
        options: [.caseInsensitive]
    )
    private static let romanSectionHeading = try! NSRegularExpression(
        pattern: #"^\s*([IVX]{1,5})\.\s+([A-Z\p{Lu}][^\n]{1,75})$"#
    )
    private static let letteredSubHeading = try! NSRegularExpression(
        pattern: #"^\s*([A-HJ-UWYZ])\.\s+([A-Z][^\n]{1,75})$"#
    )
    private static let chapterMarker = try! NSRegularExpression(
        pattern: #"第\s*[一二三四五六七八九十百千万零〇兩两0-9]+\s*章|(?:chapter|part|unit)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[ivxlcdm]+|\d+)\b"#,
        options: [.caseInsensitive]
    )
    private static let structuralMarker = try! NSRegularExpression(
        pattern: #"(?:\*?§\s*\d+|第\s*[一二三四五六七八九十百千万零〇兩两0-9]+\s*[章节節篇部卷]|(?:chapter|part|unit|section|appendix)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[ivxlcdm]+|\d+|[a-z])\b|\d+[.、．]\s*\S)"#,
        options: [.caseInsensitive]
    )
    private static let explicitContentsRegex = try! NSRegularExpression(
        pattern: #"^(?:[ivxlcdm\d]+\s+)?(目\s*[录錄]|(?:table of )?contents)(?:\s*[（(][^)）]{1,30}[)）])?(?:\s+[ivxlcdm\d]+)?$"#,
        options: [.caseInsensitive]
    )
    private static let standaloneHeadings: Set<String> = [
        "前言", "序言", "绪论", "引言", "结语", "结论", "参考文献", "附录", "索引",
        "推薦序", "推荐序", "序", "自序", "譯序", "译序", "導讀", "导读",
        "後記", "后记", "結語", "結論", "參考文獻", "附錄",
        "abstract", "preface", "foreword", "introduction", "conclusion", "conclusions",
        "references", "bibliography", "acknowledgments", "acknowledgements",
        "appendix", "index"
    ]

    static func generate(
        document: PDFDocument,
        pageLabels: [String: [Int]],
        oddIndexShift: Int = 0
    ) -> [GeneratedOutlineEntry] {
        let session = DocumentTextIndexSession(documentURL: document.documentURL)
        defer { session.save() }
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(document.pageCount)
        let contentsProbeEnd = min(50, max(min(document.pageCount, 12), Int(Double(document.pageCount) * 0.40)))
        let ocrProbeLimit = min(18, contentsProbeEnd)
        let probeIndices = (0..<contentsProbeEnd).sorted {
            logicalPageOrder($0, oddIndexShift: oddIndexShift) < logicalPageOrder($1, oddIndexShift: oddIndexShift)
        }

        var sawProbeTOCPage = false
        var consecutiveNonTOC = 0
        var allowColdOCR = true
        for (probePos, index) in probeIndices.enumerated() {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            if let extracted = extractPage(page, index: index, session: session,
                                           allowOCR: allowColdOCR && probePos < ocrProbeLimit,
                                           includeLineBounds: true,
                                           ocrMaxDimension: 1600) {
                pages.append(extracted)
                if isLikelyTOCProbePage(extracted, pageCount: document.pageCount) {
                    sawProbeTOCPage = true
                    consecutiveNonTOC = 0
                } else if sawProbeTOCPage {
                    consecutiveNonTOC += 1
                    if consecutiveNonTOC >= 2 {
                        allowColdOCR = false
                    }
                }
            } else if sawProbeTOCPage {
                consecutiveNonTOC += 1
                if consecutiveNonTOC >= 2 {
                    allowColdOCR = false
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        if let toc = outlineFromContentsPages(pages, document: document, pageLabels: pageLabels, oddIndexShift: oddIndexShift) {
            return toc
        }

        // Unindexed image-only scans without a detectable TOC should not emit spurious partial headers.
        if document.pageCount >= 16 {
            let step = max(1, document.pageCount / 8)
            var sampled = 0
            var readableCount = 0
            for idx in stride(from: 0, to: document.pageCount, by: step).prefix(8) {
                guard let page = document.page(at: idx) else { continue }
                sampled += 1
                if coherentNativeText(for: page) != nil {
                    readableCount += 1
                }
            }
            if sampled > 0 && readableCount * 4 < sampled {
                return []
            }
        }

        // Only books without a usable contents section need the whole-document heading pass.
        // Avoid launching hundreds of cold OCR jobs on large unindexed scans during outline discovery;
        // reuse already-cached OCR pages and clean native text layers instead.
        let eagerBoundsAfterProbe = document.pageCount <= 80
        for index in contentsProbeEnd..<document.pageCount {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            if let extracted = extractPage(page, index: index, session: session,
                                           allowOCR: false, includeLineBounds: eagerBoundsAfterProbe) {
                pages.append(extracted)
            }
        }
        guard !Task.isCancelled else { return [] }
        pages.sort { logicalPageOrder($0.index, oddIndexShift: oddIndexShift) < logicalPageOrder($1.index, oddIndexShift: oddIndexShift) }
        return outlineFromHeadings(pages)
    }

    private static func coherentNativeText(for page: PDFPage) -> String? {
        let rawPageString = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNative = (page.string ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { PDFTextCleanup.normalize($0) }
            .joined(separator: "\n")
        let native = rawNative.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementCount = native.unicodeScalars.filter { $0.value == 0xFFFD }.count
        let readable = native.count >= 8 && replacementCount * 8 <= max(1, native.unicodeScalars.count)
        guard readable, (!page.hasFullPageScanImage || isCoherentScanTextLayer(rawPageString)) else { return nil }
        return native
    }

    private static func isLikelyTOCProbePage(_ page: ExtractedPage, pageCount: Int) -> Bool {
        if explicitContentsHeader(in: page.lines, cropBox: page.cropBox) != nil { return true }
        var tocLike = 0
        for line in page.lines {
            let ns = line.text as NSString
            let range = NSRange(location: 0, length: ns.length)
            if tocEntry.firstMatch(in: line.text, range: range) != nil
                || leaderlessTOCEntry.firstMatch(in: line.text, range: range) != nil {
                tocLike += 1
            }
        }
        if tocLike >= 3 { return true }
        return !parseVerticalColumnTOC(lines: page.lines, pageCount: pageCount, hasExplicitHeader: true, sawContentsRun: true).isEmpty
    }

    private static func isBoldFont(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName.lowercased()
        return name.contains("bold") || name.contains("demi") || name.contains("heavy")
            || name.contains("black") || name.contains("semibold")
    }

    private static func extractPage(_ page: PDFPage, index: Int,
                                    session: DocumentTextIndexSession,
                                    allowOCR: Bool,
                                    includeLineBounds: Bool,
                                    ocrMaxDimension: CGFloat = 2200) -> ExtractedPage? {
        let cropBox = page.bounds(for: .cropBox)
        if let native = coherentNativeText(for: page) {
            var lines: [PageLine] = []
            if let attr = page.attributedString, attr.length > 0 {
                let ns = attr.string as NSString
                let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))
                var pos = 0
                while pos < ns.length {
                    let rawRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                    pos = NSMaxRange(rawRange)
                    var start = rawRange.location
                    var end = NSMaxRange(rawRange)
                    while start < end, let scalar = UnicodeScalar(ns.character(at: start)), trimSet.contains(scalar) {
                        start += 1
                    }
                    while end > start, let scalar = UnicodeScalar(ns.character(at: end - 1)), trimSet.contains(scalar) {
                        end -= 1
                    }
                    guard end > start else { continue }
                    let trimmedRange = NSRange(location: start, length: end - start)
                    let text = PDFTextCleanup.normalize(ns.substring(with: trimmedRange))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let bounds = includeLineBounds ? (page.selection(for: trimmedRange)?.bounds(for: page) ?? .zero) : .zero
                    let startFont = attr.attribute(.font, at: trimmedRange.location, effectiveRange: nil) as? NSFont
                    let endFont = attr.attribute(.font, at: max(trimmedRange.location, NSMaxRange(trimmedRange) - 1), effectiveRange: nil) as? NSFont
                    let fontSize = startFont?.pointSize ?? 0
                    let endFontSize = endFont?.pointSize ?? fontSize
                    let smallCaps = fontSize > 0 && endFontSize > 0 && (fontSize - endFontSize) >= 1.2
                    let candidate = PageLine(
                        text: text,
                        bounds: bounds,
                        fontSize: fontSize,
                        endFontSize: endFontSize,
                        isBold: isBoldFont(startFont),
                        isEndBold: isBoldFont(endFont),
                        isSmallCaps: smallCaps
                    )
                    if let prev = lines.last,
                       prev.hasGeometry, candidate.hasGeometry,
                       abs(prev.bounds.midY - candidate.bounds.midY) <= min(prev.bounds.height, candidate.bounds.height) * 0.45,
                       candidate.bounds.minX >= prev.bounds.maxX - 6 {
                        let startsWithLeader = candidate.text.first.map { ".．·•…_—-".contains($0) } ?? false
                        let joined = startsWithLeader ? (prev.text + candidate.text) : (prev.text + " " + candidate.text)
                        lines[lines.count - 1].text = joined
                        lines[lines.count - 1].bounds = prev.bounds.union(candidate.bounds)
                        lines[lines.count - 1].endFontSize = candidate.endFontSize
                        lines[lines.count - 1].isEndBold = candidate.isEndBold
                    } else {
                        lines.append(candidate)
                    }
                }
            }
            if lines.isEmpty {
                lines = native.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { PageLine(text: $0, bounds: .zero, fontSize: 0, endFontSize: 0, isBold: false, isEndBold: false, isSmallCaps: false) }
            }
            return ExtractedPage(index: index, cropBox: cropBox, lines: lines, rawText: native)
        }

        let indexed: IndexedPageText?
        if let cached = session.cachedText(forPageIndex: index) {
            indexed = cached
        } else if allowOCR {
            indexed = session.recognizedText(for: page, pageIndex: index, maximumDimension: ocrMaxDimension)
        } else {
            indexed = nil
        }
        guard let indexed else { return nil }
        let trimmedText = indexed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        var lines: [PageLine] = []
        if !indexed.glyphs.isEmpty {
            let ns = indexed.text as NSString
            var currentLineID: Int?
            var firstLoc = 0
            var lastEnd = 0
            var lineBounds = CGRect.zero
            func flushGlyphGroup() {
                guard currentLineID != nil, ns.length > 0 else { return }
                let clampedStart = max(0, min(firstLoc, ns.length))
                let clampedEnd = max(clampedStart, min(lastEnd, ns.length))
                guard clampedEnd > clampedStart else { return }
                let rawSlice = ns.substring(with: NSRange(location: clampedStart, length: clampedEnd - clampedStart))
                let cleaned = PDFTextCleanup.normalize(rawSlice).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                lines.append(PageLine(text: cleaned, bounds: lineBounds, fontSize: 0, endFontSize: 0, isBold: false, isEndBold: false, isSmallCaps: false))
            }
            for glyph in indexed.glyphs {
                if currentLineID == glyph.line {
                    firstLoc = min(firstLoc, glyph.location)
                    lastEnd = max(lastEnd, glyph.location + glyph.length)
                    lineBounds = lineBounds.union(glyph.bounds)
                } else {
                    flushGlyphGroup()
                    currentLineID = glyph.line
                    firstLoc = glyph.location
                    lastEnd = glyph.location + glyph.length
                    lineBounds = glyph.bounds
                }
            }
            flushGlyphGroup()
        }
        if lines.isEmpty {
            lines = trimmedText.components(separatedBy: .newlines)
                .map { PDFTextCleanup.normalize($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { PageLine(text: $0, bounds: .zero, fontSize: 0, endFontSize: 0, isBold: false, isEndBold: false, isSmallCaps: false) }
        }
        return ExtractedPage(index: index, cropBox: cropBox, lines: lines, rawText: trimmedText)
    }

    private static func isCoherentScanTextLayer(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return false }
        let singleCharTokens = tokens.filter { $0.count == 1 }.count
        // Broken vertical-CJK scan layers emit isolated single characters separated by spaces (`各 息 长 弱`).
        return singleCharTokens * 10 <= tokens.count * 4
    }

    private static func explicitContentsHeader(in lines: [PageLine], cropBox: CGRect) -> (title: String, point: CGPoint?)? {
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = explicitContentsRegex.firstMatch(in: trimmed, range: range),
                  let capture = Range(match.range(at: 1), in: trimmed) else { continue }
            let captured = String(trimmed[capture])
            let normalizedTitle: String
            if captured.contains("目") {
                normalizedTitle = captured.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            } else if captured.lowercased() == "table of contents" {
                normalizedTitle = "Table of Contents"
            } else {
                normalizedTitle = "Contents"
            }
            let point = line.hasGeometry
                ? CGPoint(x: line.bounds.minX, y: min(cropBox.maxY, line.bounds.maxY + 8))
                : nil
            return (normalizedTitle, point)
        }
        return nil
    }

    private static func isExplicitContentsHeaderLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return explicitContentsRegex.firstMatch(in: trimmed, range: range) != nil
    }

    private static func romanNumeralValue(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—()[].,")))
        let s = trimmed.lowercased()
        guard !s.isEmpty, s.count <= 6, s.unicodeScalars.allSatisfy({ "ivxl".unicodeScalars.contains($0) }) else {
            return nil
        }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50]
        var total = 0
        var prev = 0
        for ch in s.reversed() {
            guard let v = values[ch] else { return nil }
            if v < prev { total -= v } else { total += v; prev = v }
        }
        guard (1...50).contains(total) else { return nil }
        // Verify canonical Roman spelling so random consonant strings never match
        let ones = ["", "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix"]
        let tens = ["", "x", "xx", "xxx", "xl", "l"]
        let canonical = tens[total / 10] + ones[total % 10]
        return s == canonical ? total : nil
    }

    private static func collectRomanFrontMatterAnchors(
        from pages: [ExtractedPage],
        upperBoundPage: Int
    ) -> [(pageIndex: Int, roman: Int)] {
        let probeEnd = min(upperBoundPage, 30)
        var anchors: [(pageIndex: Int, roman: Int)] = []
        for page in pages where page.index < probeEnd {
            guard explicitContentsHeader(in: page.lines, cropBox: page.cropBox) == nil else { continue }
            let texts = page.lines.map(\.text)
            let boundaryLines = Array(texts.prefix(6)) + Array(texts.suffix(2))
            var pageRoman: Int?
            for line in boundaryLines {
                guard !line.contains("…"), !line.contains("...") else { continue }
                // Normalize decorated folios like `- i -` or `(iv)` before splitting tokens
                let normalizedFolio = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—")))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let standalone = romanNumeralValue(normalizedFolio) {
                    pageRoman = standalone
                    break
                }
                let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if words.count >= 2 {
                    if let first = romanNumeralValue(words.first!),
                       words.dropFirst().contains(where: { $0.rangeOfCharacter(from: .letters) != nil }) {
                        pageRoman = first
                        break
                    }
                    if let last = romanNumeralValue(words.last!),
                       words.dropLast().contains(where: { $0.rangeOfCharacter(from: .letters) != nil }) {
                        pageRoman = last
                        break
                    }
                }
            }
            if let pageRoman, (-10...20).contains(page.index - pageRoman) {
                anchors.append((pageIndex: page.index, roman: pageRoman))
            }
        }
        return anchors
    }

    private static func inferUncalibratedBodyOffset(
        rawEntries: [(tocPage: Int, title: String, label: String)],
        document: PDFDocument
    ) -> Int {
        var offsetCounts: [Int: Int] = [:]
        var sampled = 0
        for row in rawEntries {
            guard let num = Int(row.label), (1..<document.pageCount).contains(num) else { continue }
            sampled += 1
            if sampled > 12 { break }
            let needle = String(row.title.prefix(24))
            let start = row.tocPage + 1
            let end = min(document.pageCount, start + num + 40)
            guard start < end else { continue }
            for idx in start..<end {
                guard let text = document.page(at: idx)?.string,
                      text.localizedCaseInsensitiveContains(needle) else { continue }
                let offset = idx - (num - 1)
                if (0...60).contains(offset) {
                    offsetCounts[offset, default: 0] += 1
                    break
                }
            }
        }
        if let (best, votes) = offsetCounts.max(by: { $0.value < $1.value }), votes >= 2 {
            return best
        }
        return 0
    }

    private static func resolveTOCPageTarget(
        label rawLabel: String,
        after pageIndex: Int,
        oddIndexShift: Int,
        pageLabels: [String: [Int]],
        pageCount: Int,
        bodyOffset: Int,
        romanAnchors: [(pageIndex: Int, roman: Int)],
        firstBodyPage: Int
    ) -> Int? {
        let label = rawLabel.lowercased()
        let afterLogical = logicalPageOrder(pageIndex, oddIndexShift: oddIndexShift)
        let candidates = pageLabels[label] ?? pageLabels[label.uppercased()] ?? []
        if let direct = candidates.first(where: { logicalPageOrder($0, oddIndexShift: oddIndexShift) > afterLogical }) {
            return direct
        }
        if let num = Int(label) {
            let physical = num - 1 + bodyOffset
            if logicalPageOrder(physical, oddIndexShift: oddIndexShift) > afterLogical && physical < pageCount {
                return physical
            }
            return nil
        }
        if let roman = romanNumeralValue(label) {
            if !romanAnchors.isEmpty {
                let nearest = romanAnchors.min { lhs, rhs in
                    let dl = abs(lhs.roman - roman)
                    let dr = abs(rhs.roman - roman)
                    if dl != dr { return dl < dr }
                    let lAfter = lhs.pageIndex > pageIndex ? 0 : 1
                    let rAfter = rhs.pageIndex > pageIndex ? 0 : 1
                    if lAfter != rAfter { return lAfter < rAfter }
                    return lhs.pageIndex < rhs.pageIndex
                }
                if let nearest {
                    let target = nearest.pageIndex + (roman - nearest.roman)
                    if target >= 0 && target < firstBodyPage && target != pageIndex {
                        return target
                    }
                }
            } else if roman - 1 > pageIndex && roman - 1 < firstBodyPage {
                return roman - 1
            }
        }
        return nil
    }

    private static func modalValue(of values: [CGFloat], step: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        var counts: [CGFloat: Int] = [:]
        for v in values where v > 0 {
            let bucket = (v / step).rounded() * step
            counts[bucket, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 0
    }

    private static func detectTOCRightColumnX(lines: [PageLine]) -> CGFloat? {
        var candidates: [CGFloat] = []
        var minLeftX = CGFloat.greatestFiniteMagnitude
        for line in lines where line.hasGeometry && line.bounds.width >= 60 {
            let ns = line.text as NSString
            let range = NSRange(location: 0, length: ns.length)
            if leaderlessTOCEntry.firstMatch(in: line.text, range: range) != nil
                || tocEntry.firstMatch(in: line.text, range: range) != nil {
                candidates.append(line.bounds.maxX)
                minLeftX = min(minLeftX, line.bounds.minX)
            }
        }
        guard candidates.count >= 4 else { return nil }
        var bestCluster: [CGFloat] = []
        for anchor in candidates {
            let cluster = candidates.filter { abs($0 - anchor) <= 8.0 }
            if cluster.count > bestCluster.count {
                bestCluster = cluster
            }
        }
        guard bestCluster.count >= 4 else { return nil }
        let sorted = bestCluster.sorted()
        let rightX = sorted[sorted.count / 2]
        guard rightX - minLeftX >= 100 else { return nil }
        return rightX
    }

    private struct RawParsedTOCLine {
        var title: String
        let label: String
        var minX: CGFloat
        var rightColumnX: CGFloat?
        var anchorMinY: CGFloat
        var lineHeight: CGFloat
        var continuationMinY: CGFloat
        var isVerticalColumn: Bool = false
    }

    private static func parseVerticalColumnTOC(
        lines: [PageLine],
        pageCount: Int,
        hasExplicitHeader: Bool,
        sawContentsRun: Bool
    ) -> [RawParsedTOCLine] {
        struct FolioCandidate {
            let lineIndex: Int
            let line: PageLine
            let label: String
            let numericValue: Int
        }

        let trimDecor = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—()[].,"))
        let folios: [FolioCandidate] = lines.enumerated().compactMap { index, line in
            guard line.hasGeometry, line.bounds.width <= 70, line.bounds.height <= 45 else { return nil }
            let trimmed = line.text.trimmingCharacters(in: trimDecor)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
               let n = Int(trimmed), n > 0, n <= pageCount + 40 {
                return FolioCandidate(lineIndex: index, line: line, label: trimmed, numericValue: n)
            }
            if let roman = romanNumeralValue(trimmed) {
                return FolioCandidate(lineIndex: index, line: line, label: trimmed.lowercased(), numericValue: -100 + roman)
            }
            return nil
        }
        guard folios.count >= 4 else { return [] }

        var bestCluster: [FolioCandidate] = []
        for anchor in folios {
            let cluster = folios.filter { abs($0.line.bounds.midY - anchor.line.bounds.midY) <= 18.0 }
            if cluster.count > bestCluster.count {
                bestCluster = cluster
            }
        }
        guard bestCluster.count >= 4 else { return [] }
        let minMidX = bestCluster.map(\.line.bounds.midX).min() ?? 0
        let maxMidX = bestCluster.map(\.line.bounds.midX).max() ?? 0
        guard maxMidX - minMidX >= 100,
              hasExplicitHeader || sawContentsRun || bestCluster.count >= 6 else {
            return []
        }

        let ascending = bestCluster.sorted { $0.line.bounds.midX < $1.line.bounds.midX }
        let gaps = zip(ascending, ascending.dropFirst())
            .map { $1.line.bounds.midX - $0.line.bounds.midX }
            .filter { $0 > 8 }
            .sorted()
        guard !gaps.isEmpty else { return [] }
        let colStep = gaps[gaps.count / 2]
        let colTolerance = min(26.0, max(12.0, colStep * 0.42))

        let rtlCols = bestCluster.sorted { $0.line.bounds.midX > $1.line.bounds.midX }
        let ltrCols = ascending
        let rtlScore = zip(rtlCols, rtlCols.dropFirst()).filter { $0.numericValue <= $1.numericValue }.count
        let ltrScore = zip(ltrCols, ltrCols.dropFirst()).filter { $0.numericValue <= $1.numericValue }.count
        let hasCJK = lines.contains { $0.text.range(of: #"\p{Han}"#, options: .regularExpression) != nil }
        let orderedCols = (rtlScore > ltrScore || (rtlScore == ltrScore && hasCJK)) ? rtlCols : ltrCols

        let folioIndices = Set(bestCluster.map(\.lineIndex))
        let folioMinY = (bestCluster.map(\.line.bounds.minY).min() ?? 0) - 8.0
        let folioMaxY = (bestCluster.map(\.line.bounds.maxY).max() ?? 0) + 8.0

        var linesByCol: [Int: [PageLine]] = [:]
        for (idx, line) in lines.enumerated() where !folioIndices.contains(idx) && line.hasGeometry {
            if line.bounds.midY >= folioMinY && line.bounds.midY <= folioMaxY { continue }
            guard let nearest = orderedCols.indices.min(by: {
                abs(line.bounds.midX - orderedCols[$0].line.bounds.midX)
                    < abs(line.bounds.midX - orderedCols[$1].line.bounds.midX)
            }) else { continue }
            let dist = abs(line.bounds.midX - orderedCols[nearest].line.bounds.midX)
            guard dist <= colTolerance else { continue }
            linesByCol[nearest, default: []].append(line)
        }

        let segmentTrim = CharacterSet(charactersIn: " .．·•…_—-：:")
        var parsed: [RawParsedTOCLine] = []
        for colIndex in orderedCols.indices {
            let folio = orderedCols[colIndex]
            let colLines = (linesByCol[colIndex] ?? []).sorted { $0.bounds.maxY > $1.bounds.maxY }
            let colItems: [(line: PageLine, text: String)] = colLines.compactMap { line in
                let cleaned = line.text.trimmingCharacters(in: segmentTrim)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : (line, cleaned)
            }
            guard !colItems.isEmpty else { continue }

            var joined = ""
            var inLatinRun = false
            var previousLine: PageLine?
            for item in colItems {
                let seg = item.text
                let isLatin = seg.range(of: #"\p{Han}"#, options: .regularExpression) == nil
                    && seg.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
                if joined.isEmpty {
                    joined = seg
                    inLatinRun = isLatin
                } else if isLatin && !inLatinRun {
                    joined += " — " + seg
                    inLatinRun = true
                } else if isLatin && inLatinRun {
                    joined += " " + seg
                } else {
                    let verticalGap = previousLine.map { $0.bounds.minY - item.line.bounds.maxY } ?? 0
                    let charSize = previousLine.map {
                        min(min($0.bounds.width, $0.bounds.height), min(item.line.bounds.width, item.line.bounds.height))
                    } ?? min(item.line.bounds.width, item.line.bounds.height)
                    let hasVerticalGap = verticalGap >= max(6.0, charSize * 0.45)
                    let prevEndsASCII = joined.last?.isASCII == true
                    let curStartsASCII = seg.first?.isASCII == true
                    joined += (hasVerticalGap || prevEndsASCII || curStartsASCII) ? (" " + seg) : seg
                    inLatinRun = false
                }
                previousLine = item.line
            }
            guard let title = cleanedTOCTitle(joined, allowUnnumbered: true) else { continue }
            let topLine = colItems.first?.line ?? folio.line
            parsed.append(RawParsedTOCLine(
                title: title,
                label: folio.label,
                minX: folio.line.bounds.minX,
                rightColumnX: nil,
                anchorMinY: topLine.bounds.maxY,
                lineHeight: folio.line.bounds.height,
                continuationMinY: folio.line.bounds.minY,
                isVerticalColumn: true
            ))
        }
        return parsed
    }

    private static func headingDestinationPoint(title: String, on page: PDFPage, cropBox: CGRect) -> CGPoint? {
        guard !page.hasFullPageScanImage, let attr = page.attributedString, attr.length > 0 else { return nil }
        let normalizedTarget = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTarget.isEmpty else { return nil }
        let shortTarget = String(normalizedTarget.prefix(36))
        let ns = attr.string as NSString
        var pos = 0
        var bestFallback: CGPoint?
        while pos < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(lineRange)
            let lineText = PDFTextCleanup.normalize(ns.substring(with: lineRange))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty, (2...120).contains(lineText.count) else { continue }
            if lineText.localizedCaseInsensitiveCompare(normalizedTarget) == .orderedSame
                || lineText.localizedCaseInsensitiveContains(shortTarget)
                || (lineText.count >= 6 && normalizedTarget.localizedCaseInsensitiveContains(lineText)) {
                if let bounds = page.selection(for: lineRange)?.bounds(for: page),
                   bounds.width > 0, bounds.height > 0 {
                    let pt = CGPoint(x: bounds.minX, y: min(cropBox.maxY, bounds.maxY + 8))
                    if lineText.localizedCaseInsensitiveCompare(normalizedTarget) == .orderedSame {
                        return pt
                    }
                    if bestFallback == nil { bestFallback = pt }
                }
            }
        }
        return bestFallback
    }

    private static func outlineFromContentsPages(
        _ pages: [ExtractedPage],
        document: PDFDocument,
        pageLabels: [String: [Int]],
        oddIndexShift: Int = 0
    ) -> [GeneratedOutlineEntry]? {
        let pageCount = document.pageCount
        struct RawPage {
            let index: Int
            let lines: [RawParsedTOCLine]
            let hasExplicitHeader: Bool
            let explicitHeaderTitle: String?
            let explicitHeaderPoint: CGPoint?
            let rightColumnX: CGFloat?
        }

        var rawPages: [RawPage] = []
        var sawContentsRun = false

        for page in pages.prefix(min(50, pages.count)) {
            let headerInfo = explicitContentsHeader(in: page.lines, cropBox: page.cropBox)
            let hasExplicitHeader = headerInfo != nil
            let modalFontSize = modalValue(
                of: page.lines.filter { $0.text.rangeOfCharacter(from: .letters) != nil }.map(\.fontSize),
                step: 0.5
            )
            let modalLineHeight = modalValue(
                of: page.lines.filter { $0.hasGeometry }.map { $0.bounds.height },
                step: 0.5
            )
            let activeLines = page.lines.filter { line in
                if isExplicitContentsHeaderLine(line.text) { return false }
                if modalFontSize > 0 && line.fontSize > 0 && line.fontSize <= modalFontSize - 2.5 { return false }
                return true
            }
            let rightColumnX = detectTOCRightColumnX(lines: activeLines)

            var parsedLines: [RawParsedTOCLine] = []
            var pendingSection: String?
            var previousUnmatched: PageLine?
            var previousWasStandalone = false

            for line in activeLines {
                let text = line.text
                guard !text.isEmpty else { continue }
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)

                // Wrapped dot-leader + page number line following a bare multi-word title on the previous row.
                if let prevLine = previousUnmatched,
                   let leaderMatch = leaderOnlyLine.firstMatch(in: text, range: range),
                   let labelRange = Range(leaderMatch.range(at: 1), in: text),
                   !isExplicitContentsHeaderLine(prevLine.text),
                   let title = cleanedTOCTitle(prevLine.text, allowUnnumbered: true) {
                    let row = RawParsedTOCLine(
                        title: title,
                        label: String(text[labelRange]),
                        minX: prevLine.hasGeometry ? prevLine.bounds.minX : line.bounds.minX,
                        rightColumnX: rightColumnX,
                        anchorMinY: line.bounds.minY,
                        lineHeight: line.hasGeometry ? line.bounds.height : 12,
                        continuationMinY: line.bounds.minY
                    )
                    parsedLines.append(row)
                    previousUnmatched = nil
                    pendingSection = nil
                    previousWasStandalone = false
                    continue
                }

                var lineEntries: [RawParsedTOCLine] = []
                let tocMatches = tocEntry.matches(in: text, range: range)
                var matchedTOCPattern = !tocMatches.isEmpty
                for match in tocMatches {
                    guard let titleRange = Range(match.range(at: 1), in: text),
                          let leaderRange = Range(match.range(at: 2), in: text),
                          let labelRange = Range(match.range(at: 3), in: text) else { continue }
                    let leaderCount = text[leaderRange].count
                    var rawTitle = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    var effectiveMinX = line.bounds.minX
                    let allowUnnumbered = (leaderCount >= 5 || rightColumnX != nil)
                        && (hasExplicitHeader || sawContentsRun || !parsedLines.isEmpty || previousUnmatched != nil)

                    // Wrapped two-line title where the second line carries the leader dots + page number
                    if let prevLine = previousUnmatched,
                       !isExplicitContentsHeaderLine(prevLine.text),
                       !isStructuralHeadingLine(rawTitle),
                       (!prevLine.hasGeometry || !line.hasGeometry || (
                           prevLine.bounds.minY > line.bounds.minY
                           && prevLine.bounds.minY - line.bounds.minY <= max(line.bounds.height, 10) * 2.4
                           && abs(prevLine.bounds.minX - line.bounds.minX) <= 16
                       )) {
                        let sep = (prevLine.text.last?.isASCII == true && rawTitle.first?.isASCII == true) ? " " : ""
                        rawTitle = prevLine.text + sep + rawTitle
                        if prevLine.hasGeometry {
                            effectiveMinX = min(effectiveMinX, prevLine.bounds.minX)
                        }
                    }

                    guard let title = cleanedTOCTitle(rawTitle, allowUnnumbered: allowUnnumbered) else { continue }
                    lineEntries.append(RawParsedTOCLine(
                        title: title,
                        label: String(text[labelRange]),
                        minX: effectiveMinX,
                        rightColumnX: rightColumnX,
                        anchorMinY: line.bounds.minY,
                        lineHeight: line.hasGeometry ? line.bounds.height : 12,
                        continuationMinY: line.bounds.minY
                    ))
                }

                if lineEntries.isEmpty && tocMatches.isEmpty,
                   let match = leaderlessTOCEntry.firstMatch(in: text, range: range),
                   let titleRange = Range(match.range(at: 1), in: text),
                   let labelRange = Range(match.range(at: 2), in: text) {
                    let rawTitle = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawLabel = String(text[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let isAlignedRight = rightColumnX != nil
                        && line.hasGeometry
                        && abs(line.bounds.maxX - rightColumnX!) <= 8.0
                        && (rightColumnX! - line.bounds.minX) >= 80.0
                    let isMergedMultiRowBlock = line.hasGeometry && modalLineHeight > 0
                        && line.bounds.height > modalLineHeight * 2.6 && rawTitle.count > 95
                    let lowered = rawTitle.lowercased()
                    let looksLikeMetadata = lowered.contains("http") || lowered.contains("isbn")
                        || rawTitle.hasSuffix(".") || rawTitle.hasSuffix(",")
                        || rawTitle.range(of: #",\s*(?:19|20)\d\d$"#, options: .regularExpression) != nil
                    let validRomanOrArabic = Int(rawLabel) != nil || romanNumeralValue(rawLabel) != nil

                    if validRomanOrArabic && (hasExplicitHeader || (isAlignedRight && sawContentsRun))
                        && !isMergedMultiRowBlock && !looksLikeMetadata {
                        matchedTOCPattern = true
                        if let title = cleanedTOCTitle(rawTitle, allowUnnumbered: true) {
                            lineEntries.append(RawParsedTOCLine(
                                title: title,
                                label: rawLabel,
                                minX: line.bounds.minX,
                                rightColumnX: rightColumnX,
                                anchorMinY: line.bounds.minY,
                                lineHeight: line.hasGeometry ? line.bounds.height : 12,
                                continuationMinY: line.bounds.minY
                            ))
                        }
                    }
                }

                if lineEntries.isEmpty {
                    if matchedTOCPattern {
                        previousUnmatched = nil
                        previousWasStandalone = false
                        continue
                    }

                    // Ignore isolated page-number fragments in the right column so wrapped titles stay attached.
                    if text.allSatisfy({ $0.isNumber || $0.isWhitespace })
                        && (rightColumnX == nil || !line.hasGeometry || line.bounds.minX > rightColumnX! - 45) {
                        continue
                    }

                    // Purely geometric wrapped continuation below the previous right-aligned TOC entry.
                    if let rightX = rightColumnX,
                       !parsedLines.isEmpty,
                       line.hasGeometry,
                       line.bounds.maxX < rightX - 24,
                       parsedLines[parsedLines.count - 1].continuationMinY - line.bounds.minY > 0,
                       parsedLines[parsedLines.count - 1].continuationMinY - line.bounds.minY <= max(parsedLines[parsedLines.count - 1].lineHeight, 10) * 2.2,
                       line.bounds.minX >= parsedLines[parsedLines.count - 1].minX - 2,
                       line.bounds.minX <= parsedLines[parsedLines.count - 1].minX + 36,
                       (2...60).contains(text.count),
                       !isStructuralHeadingLine(text),
                       romanNumeralValue(text) == nil {
                        let sep = (parsedLines[parsedLines.count - 1].title.last?.isASCII == true && text.first?.isASCII == true) ? " " : ""
                        parsedLines[parsedLines.count - 1].title += sep + text
                        parsedLines[parsedLines.count - 1].continuationMinY = line.bounds.minY
                        previousUnmatched = nil
                        continue
                    }

                    previousUnmatched = romanNumeralValue(text) == nil ? line : nil
                    previousWasStandalone = false
                    if let structural = cleanedTOCTitle(text),
                       structuralLevel(for: structural) <= 1 {
                        pendingSection = structural
                        previousWasStandalone = true
                    }
                    continue
                }

                if let pendingSection, previousWasStandalone,
                   let first = lineEntries.first,
                   structuralLevel(for: first.title) >= 2 {
                    parsedLines.append(RawParsedTOCLine(
                        title: pendingSection,
                        label: first.label,
                        minX: first.minX,
                        rightColumnX: rightColumnX,
                        anchorMinY: first.anchorMinY,
                        lineHeight: first.lineHeight,
                        continuationMinY: first.continuationMinY
                    ))
                }
                pendingSection = nil
                previousUnmatched = nil
                previousWasStandalone = false
                parsedLines.append(contentsOf: lineEntries)
            }

            let minimumLines = hasExplicitHeader ? 2 : 3
            if parsedLines.count < minimumLines {
                let verticalLines = parseVerticalColumnTOC(
                    lines: activeLines,
                    pageCount: pageCount,
                    hasExplicitHeader: hasExplicitHeader,
                    sawContentsRun: sawContentsRun
                )
                if verticalLines.count >= minimumLines {
                    parsedLines = verticalLines
                }
            }

            if parsedLines.count >= minimumLines {
                sawContentsRun = true
                rawPages.append(RawPage(
                    index: page.index,
                    lines: parsedLines,
                    hasExplicitHeader: hasExplicitHeader,
                    explicitHeaderTitle: headerInfo?.title,
                    explicitHeaderPoint: headerInfo?.point,
                    rightColumnX: rightColumnX
                ))
            } else {
                sawContentsRun = false
            }
        }
        guard !rawPages.isEmpty else { return nil }

        let allRawEntries = rawPages.flatMap { p in p.lines.map { (tocPage: p.index, title: $0.title, label: $0.label) } }
        let bodyOffset = pageLabels.isEmpty
            ? inferUncalibratedBodyOffset(rawEntries: allRawEntries, document: document)
            : 0
        let firstBodyPage = pageLabels["1"]?.first
            ?? (allRawEntries.compactMap { row -> Int? in
                guard let n = Int(row.label), n >= 1 else { return nil }
                return n - 1 + bodyOffset
            }.min() ?? min(pageCount, 30))
        let romanAnchors = collectRomanFrontMatterAnchors(from: pages, upperBoundPage: firstBodyPage)

        // Discover geometric indentation levels from rightColumnX - minX (recto/verso margin invariant).
        var spanWidths: [CGFloat] = []
        for rawPage in rawPages {
            for item in rawPage.lines {
                if let rightX = item.rightColumnX, item.minX > 0, rightX - item.minX >= 80 {
                    spanWidths.append(rightX - item.minX)
                }
            }
        }
        let sortedSpans = spanWidths.sorted(by: >)
        var spanBuckets: [CGFloat] = []
        for w in sortedSpans {
            if let last = spanBuckets.last {
                if last - w >= 7.0 { spanBuckets.append(w) }
            } else {
                spanBuckets.append(w)
            }
        }
        let useGeometricHierarchy = spanBuckets.count >= 2

        func geometricLevel(for item: RawParsedTOCLine) -> Int? {
            guard useGeometricHierarchy, let rightX = item.rightColumnX, item.minX > 0 else { return nil }
            let span = rightX - item.minX
            guard let best = spanBuckets.enumerated().min(by: { abs($0.element - span) < abs($1.element - span) }) else {
                return nil
            }
            return min(3, best.offset)
        }

        struct ResolvedPage {
            let index: Int
            let hasExplicitHeader: Bool
            let explicitHeaderTitle: String?
            let explicitHeaderPoint: CGPoint?
            let entries: [GeneratedOutlineEntry]
        }
        var parsedPages: [ResolvedPage] = []
        var sawChapterLikeStructural = false
        for rawPage in rawPages {
            var entries: [GeneratedOutlineEntry] = []
            for item in rawPage.lines {
                guard let target = resolveTOCPageTarget(
                    label: item.label,
                    after: rawPage.index,
                    oddIndexShift: oddIndexShift,
                    pageLabels: pageLabels,
                    pageCount: pageCount,
                    bodyOffset: bodyOffset,
                    romanAnchors: romanAnchors,
                    firstBodyPage: firstBodyPage
                ) else { continue }
                let level: Int
                if item.isVerticalColumn {
                    level = item.title.range(of: #"第\s*.+[节節]"#, options: .regularExpression) != nil ? 1 : 0
                } else if let geom = geometricLevel(for: item) {
                    level = geom
                } else {
                    let sLevel = structuralLevel(for: item.title, sawPriorChapter: sawChapterLikeStructural)
                    if sLevel == 0 { sawChapterLikeStructural = true }
                    level = sLevel
                }
                entries.append(GeneratedOutlineEntry(title: item.title, pageIndex: target, level: level))
            }
            let minEntries = rawPage.hasExplicitHeader ? 2 : 3
            let monotonic = zip(entries, entries.dropFirst()).filter {
                logicalPageOrder($0.pageIndex, oddIndexShift: oddIndexShift)
                    <= logicalPageOrder($1.pageIndex, oddIndexShift: oddIndexShift)
            }.count
            if entries.count >= minEntries, monotonic >= max(0, entries.count - 2) {
                // Smooth single adjacent 2D-layout inversions (e.g. wrapped two-row TOC labels swapped by PDFKit).
                var sorted = entries
                var i = 0
                while i + 1 < sorted.count {
                    if logicalPageOrder(sorted[i].pageIndex, oddIndexShift: oddIndexShift)
                        > logicalPageOrder(sorted[i + 1].pageIndex, oddIndexShift: oddIndexShift)
                        && sorted[i].level == sorted[i + 1].level {
                        sorted.swapAt(i, i + 1)
                    }
                    i += 1
                }
                parsedPages.append(ResolvedPage(
                    index: rawPage.index,
                    hasExplicitHeader: rawPage.hasExplicitHeader,
                    explicitHeaderTitle: rawPage.explicitHeaderTitle,
                    explicitHeaderPoint: rawPage.explicitHeaderPoint,
                    entries: sorted
                ))
            }
        }
        guard !parsedPages.isEmpty else { return nil }
        parsedPages.sort { logicalPageOrder($0.index, oddIndexShift: oddIndexShift) < logicalPageOrder($1.index, oddIndexShift: oddIndexShift) }

        // A real contents section normally spans consecutive pages. Keep the longest such run instead of
        // mixing an isolated list/table elsewhere in the book into the outline.
        var runs: [[ResolvedPage]] = []
        for parsed in parsedPages {
            if let last = runs.last?.last,
               logicalPageOrder(parsed.index, oddIndexShift: oddIndexShift)
                == logicalPageOrder(last.index, oddIndexShift: oddIndexShift) + 1 {
                runs[runs.count - 1].append(parsed)
            } else {
                runs.append([parsed])
            }
        }
        let best = runs.max { left, right in
            left.reduce(0) { $0 + $1.entries.count } < right.reduce(0) { $0 + $1.entries.count }
        } ?? []
        if let firstTOC = best.first, pageCount >= 16, firstTOC.index * 2 > pageCount {
            return nil
        }
        var combined = deduplicated(best.flatMap(\.entries))
        let hasExplicitRun = best.contains(where: \.hasExplicitHeader)
        let threshold = hasExplicitRun ? 2 : 3
        guard combined.count >= threshold else { return nil }

        // Populate same-page destinations for native PDFs so outline selection highlights the active row.
        var countsByPage: [Int: Int] = [:]
        for entry in combined { countsByPage[entry.pageIndex, default: 0] += 1 }
        combined = combined.map { entry in
            guard countsByPage[entry.pageIndex, default: 0] >= 2,
                  let targetPage = document.page(at: entry.pageIndex),
                  let point = headingDestinationPoint(title: entry.title, on: targetPage, cropBox: targetPage.bounds(for: .cropBox)) else {
                return entry
            }
            return GeneratedOutlineEntry(title: entry.title, pageIndex: entry.pageIndex, level: entry.level, destinationPoint: point)
        }

        if let firstPage = best.first,
           let headerTitle = firstPage.explicitHeaderTitle,
           combined.first?.pageIndex != firstPage.index {
            combined.insert(
                GeneratedOutlineEntry(
                    title: headerTitle,
                    pageIndex: firstPage.index,
                    level: 0,
                    destinationPoint: firstPage.explicitHeaderPoint
                ),
                at: 0
            )
        }
        return combined
    }

    private static func canonicalTitleKey(_ text: String) -> String {
        let simplified = (text as NSString).applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        let scalars = simplified.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func repeatedMarginKeys(in pages: [ExtractedPage]) -> Set<String> {
        var pageHits: [String: Set<Int>] = [:]
        for page in pages where page.cropBox.height > 0 {
            let topCutoff = page.cropBox.maxY - page.cropBox.height * 0.085
            let bottomCutoff = page.cropBox.minY + page.cropBox.height * 0.085
            for line in page.lines where line.hasGeometry {
                let inMargin = line.bounds.minY >= topCutoff || line.bounds.maxY <= bottomCutoff
                guard inMargin else { continue }
                let trimmed = line.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.decimalDigits))
                let key = canonicalTitleKey(trimmed)
                guard key.count >= 2 else { continue }
                pageHits[key, default: []].insert(page.index)
            }
        }
        return Set(pageHits.compactMap { $0.value.count >= 2 ? $0.key : nil })
    }

    private static func isMidParagraphLine(
        at idx: Int,
        lines: [PageLine],
        bodyFontSize: CGFloat,
        bodyColumnWidth: CGFloat,
        bodyLineStep: CGFloat
    ) -> Bool {
        guard idx > 0, bodyColumnWidth > 0, bodyLineStep > 0 else { return false }
        let line = lines[idx]
        let prev = lines[idx - 1]
        guard line.hasGeometry, prev.hasGeometry else { return false }
        let prevLast = prev.text.trimmingCharacters(in: .whitespaces).unicodeScalars.last
        let endsSentence = prevLast == "." || prevLast == "。" || prevLast == "!" || prevLast == "！"
            || prevLast == "?" || prevLast == "？" || prevLast == ":" || prevLast == "："
        let dy = prev.bounds.minY - line.bounds.minY
        return !endsSentence
            && abs(prev.bounds.minX - line.bounds.minX) <= 20
            && abs(prev.fontSize - bodyFontSize) <= 0.6
            && prev.bounds.width >= bodyColumnWidth * 0.85
            && dy > 0 && dy <= bodyLineStep * 1.35
            && !line.isBold && !line.isSmallCaps && abs(line.fontSize - bodyFontSize) <= 0.6
    }

    private static func outlineFromHeadings(_ pages: [ExtractedPage]) -> [GeneratedOutlineEntry] {
        // Compute modal body font size (weighted by character count) and prose column width across sampled lines.
        var bodySizeChars: [CGFloat: Int] = [:]
        for page in pages {
            for line in page.lines where line.text.count >= 20 && line.fontSize > 0 {
                let bucket = (line.fontSize / 0.5).rounded() * 0.5
                bodySizeChars[bucket, default: 0] += line.text.count
            }
        }
        let bodyFontSize = bodySizeChars.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key ?? 0

        var columnWidthCandidates: [CGFloat] = []
        if bodyFontSize > 0 {
            for page in pages {
                for line in page.lines where line.hasGeometry && line.text.count >= 25
                    && abs(line.fontSize - bodyFontSize) <= 0.6 && line.bounds.width > 120 {
                    columnWidthCandidates.append(line.bounds.width)
                }
            }
        }
        let bodyColumnWidth: CGFloat
        if columnWidthCandidates.count >= 10 {
            let sortedWidths = columnWidthCandidates.sorted()
            bodyColumnWidth = sortedWidths[min(sortedWidths.count - 1, (sortedWidths.count * 85) / 100)]
        } else {
            bodyColumnWidth = 0
        }

        var lineSteps: [CGFloat] = []
        for page in pages {
            for i in 1..<page.lines.count {
                let prev = page.lines[i - 1], cur = page.lines[i]
                if prev.hasGeometry, cur.hasGeometry,
                   abs(prev.bounds.minX - cur.bounds.minX) <= 16,
                   abs(prev.fontSize - bodyFontSize) <= 0.6,
                   abs(cur.fontSize - bodyFontSize) <= 0.6 {
                    let dy = prev.bounds.minY - cur.bounds.minY
                    if dy > 4 && dy < 40 { lineSteps.append(dy) }
                }
            }
        }
        let sortedSteps = lineSteps.sorted()
        let bodyLineStep = sortedSteps.isEmpty ? 0 : sortedSteps[sortedSteps.count / 2]

        let marginKeys = repeatedMarginKeys(in: pages)
        var result: [GeneratedOutlineEntry] = []
        var seenLevel0CanonicalTitles: Set<String> = []
        var seenLevel0Ordinals: Set<String> = []
        var seenChildTitlesInCurrentSection: Set<String> = []
        var sawRomanSections = false
        var inReferences = false

        func appendHeading(title: String, page: ExtractedPage, line: PageLine, level: Int, ordinalKey: String? = nil) -> Bool {
            let titleKey = canonicalTitleKey(title)
            guard !titleKey.isEmpty else { return false }
            if level == 0 {
                if !seenLevel0CanonicalTitles.insert(titleKey).inserted { return false }
                if let ordinalKey, !seenLevel0Ordinals.insert(ordinalKey).inserted { return false }
                seenChildTitlesInCurrentSection.removeAll()
            } else {
                if !seenChildTitlesInCurrentSection.insert(titleKey).inserted { return false }
            }
            let point = line.hasGeometry
                ? CGPoint(x: line.bounds.minX, y: min(page.cropBox.maxY, line.bounds.maxY + 8))
                : nil
            result.append(GeneratedOutlineEntry(title: title, pageIndex: page.index, level: level, destinationPoint: point))
            return true
        }

        for page in pages {
            let leaderCount = page.rawText.filter { $0 == "…" }.count
            guard explicitContentsHeader(in: page.lines, cropBox: page.cropBox) == nil, leaderCount < 3 else { continue }
            let lines = page.lines
            var idx = 0
            while idx < lines.count {
                let line = lines[idx]
                let text = line.text
                defer { idx += 1 }

                guard (2...85).contains(text.count),
                      !text.contains("…"), !text.contains("……"),
                      text.range(of: #"[“”\"]"#, options: .regularExpression) == nil else { continue }

                let lineKey = canonicalTitleKey(text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.decimalDigits)))
                if marginKeys.contains(lineKey) { continue }

                if bodyFontSize > 0 && line.fontSize > 0 && line.fontSize < bodyFontSize - 0.5 {
                    continue
                }

                let midParagraph = isMidParagraphLine(
                    at: idx,
                    lines: lines,
                    bodyFontSize: bodyFontSize,
                    bodyColumnWidth: bodyColumnWidth,
                    bodyLineStep: bodyLineStep
                )

                let range = NSRange(text.startIndex..., in: text)
                let nextLine = idx + 1 < lines.count ? lines[idx + 1] : nil

                if let match = chineseHeading.firstMatch(in: text, range: range) {
                    let prefix = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? text
                    let tail = Range(match.range(at: 2), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
                    guard !midParagraph, !tail.contains("。"), tail.count <= 60,
                          !(tail.last.map { "，；。、-,;".contains($0) } ?? false) else { continue }
                    let level = (prefix.contains("节") || prefix.contains("節")) ? 1 : 0
                    let joined = joinedSubtitleIfBare(line: line, tailEmpty: tail.isEmpty, nextLine: nextLine,
                                                      separator: " ", bodyFontSize: bodyFontSize, bodyColumnWidth: bodyColumnWidth)
                    let ordinal = level == 0 ? canonicalTitleKey(prefix) : nil
                    if appendHeading(title: joined.title, page: page, line: line, level: level, ordinalKey: ordinal),
                       joined.consumedNext {
                        idx += 1
                    }
                } else if let match = englishHeading.firstMatch(in: text, range: range) {
                    let prefix = Range(match.range(at: 1), in: text).map { String(text[$0]).lowercased() } ?? ""
                    let tail = Range(match.range(at: 2), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
                    guard !midParagraph, text.first?.isUppercase == true, !text.contains(")."),
                          tail.count <= 65, !(tail.last.map { ",;-".contains($0) } ?? false) else { continue }
                    let level = prefix.hasPrefix("section") ? 1 : 0
                    let joined = joinedSubtitleIfBare(line: line, tailEmpty: tail.isEmpty, nextLine: nextLine,
                                                      separator: ": ", bodyFontSize: bodyFontSize, bodyColumnWidth: bodyColumnWidth)
                    let ordinal = level == 0 ? canonicalTitleKey(prefix) : nil
                    if appendHeading(title: joined.title, page: page, line: line, level: level, ordinalKey: ordinal),
                       joined.consumedNext {
                        idx += 1
                    }
                } else if !inReferences, let match = romanSectionHeading.firstMatch(in: text, range: range) {
                    let isUpperOrStyled = line.isSmallCaps || line.isBold
                        || (bodyFontSize > 0 && line.fontSize > bodyFontSize + 0.5)
                        || text == text.uppercased()
                    guard isUpperOrStyled, !midParagraph else { continue }
                    sawRomanSections = true
                    var fullTitle = text
                    var consumedWrapped = false
                    if let wrapped = wrappedHeadingContinuation(line: line, nextLine: nextLine, bodyColumnWidth: bodyColumnWidth) {
                        fullTitle = wrapped
                        consumedWrapped = true
                    }
                    let romanToken = Range(match.range(at: 1), in: text).map { String(text[$0]).uppercased() } ?? ""
                    if appendHeading(title: fullTitle, page: page, line: line, level: 0, ordinalKey: "roman:\(romanToken)"),
                       consumedWrapped {
                        idx += 1
                    }
                } else if sawRomanSections && !inReferences && !midParagraph,
                          letteredSubHeading.firstMatch(in: text, range: range) != nil,
                          text.range(of: #"\b[A-Z]\.\s*[A-Z]\."#, options: .regularExpression) == nil {
                    var fullTitle = text
                    var consumedWrapped = false
                    if let wrapped = wrappedHeadingContinuation(line: line, nextLine: nextLine, bodyColumnWidth: bodyColumnWidth) {
                        fullTitle = wrapped
                        consumedWrapped = true
                    } else if fullTitle.hasSuffix(".") {
                        continue
                    }
                    if appendHeading(title: fullTitle, page: page, line: line, level: 1),
                       consumedWrapped {
                        idx += 1
                    }
                } else if !sawRomanSections && !inReferences && !midParagraph,
                          let match = strictNumberedHeading.firstMatch(in: text, range: range),
                          let numberRange = Range(match.range(at: 1), in: text),
                          let titleRange = Range(match.range(at: 2), in: text) {
                    let number = String(text[numberRange]).trimmingCharacters(in: CharacterSet(charactersIn: " .．、"))
                    let components = number.split(separator: ".").compactMap { Int($0) }
                    guard !components.isEmpty, components.allSatisfy({ (1...30).contains($0) }) else { continue }
                    let titlePart = String(text[titleRange]).trimmingCharacters(in: .whitespaces)
                    let lastScalar = titlePart.unicodeScalars.last
                    let endsLikeProseWrap = lastScalar == "," || lastScalar == ";" || lastScalar == "-" || lastScalar == ":" || lastScalar == "?" || lastScalar == "？" || lastScalar == "。" || lastScalar == "，" || lastScalar == "；"
                    let hasSentenceBreak = titlePart.contains("?") || titlePart.contains("？") || titlePart.hasSuffix(".") || titlePart.contains("=")
                        || titlePart.contains("。") || titlePart.contains("；")
                        || (titlePart.contains("，") && titlePart.count > 22)
                        || (titlePart.contains(", ") && titlePart.count > 42)
                    let hasAlphaOrHan = titlePart.range(of: #"[A-Za-z\p{Han}]"#, options: .regularExpression) != nil
                    let firstChar = String(titlePart.prefix(1))
                    let startsWithNumericOrMath = titlePart.first?.isNumber == true
                        || ["≥", "≤", "=", "<", ">", "+", "-", "/", "×"].contains(firstChar)
                    guard titlePart.count <= 60, hasAlphaOrHan, !startsWithNumericOrMath,
                          !endsLikeProseWrap, !hasSentenceBreak else { continue }
                    let isMultiLevel = number.contains(".")
                    let hasFontInfo = bodyFontSize > 0 && line.fontSize > 0
                    let isWholeLineBold = line.isBold && line.isEndBold
                    let isTypographicallyProminent = hasFontInfo && (isWholeLineBold || line.fontSize >= bodyFontSize + 0.8)
                    let isShortStandaloneLine = line.hasGeometry && bodyColumnWidth > 0
                        && line.bounds.width < bodyColumnWidth * 0.55
                        && titlePart.count <= 42
                    let isSingleNumberHeading = !hasFontInfo || isTypographicallyProminent || isShortStandaloneLine
                    guard isMultiLevel || isSingleNumberHeading else { continue }
                    let level = min(3, max(0, number.filter { $0 == "." }.count))
                    let ordinal = level == 0 ? "num:\(number)" : nil
                    _ = appendHeading(title: text, page: page, line: line, level: level, ordinalKey: ordinal)
                } else if standaloneHeadings.contains(text.lowercased())
                            || ((text.hasPrefix("附录") || text.hasPrefix("附錄")) && text.count <= 20) {
                    if ["references", "bibliography", "参考文献", "參考文獻"].contains(text.lowercased()) {
                        inReferences = true
                    }
                    _ = appendHeading(title: text, page: page, line: line, level: 0)
                }
            }
        }
        if bodyFontSize > 0, !sawRomanSections, result.count < max(4, pages.count / 10) {
            let typographic = outlineFromTypographicHeadings(
                pages: pages,
                bodyFontSize: bodyFontSize,
                bodyColumnWidth: bodyColumnWidth,
                bodyLineStep: bodyLineStep,
                marginKeys: marginKeys
            )
            if typographic.count > result.count {
                return deduplicated(mergeHeadingOutlines(structural: result, typographic: typographic))
            }
        }
        return deduplicated(result)
    }

    private static func outlineFromTypographicHeadings(
        pages: [ExtractedPage],
        bodyFontSize: CGFloat,
        bodyColumnWidth: CGFloat,
        bodyLineStep: CGFloat,
        marginKeys: Set<String>
    ) -> [GeneratedOutlineEntry] {
        struct Candidate {
            let pageIndex: Int
            let title: String
            let titleKey: String
            let sizeBucket: CGFloat
            let point: CGPoint?
            let isStandalone: Bool
        }

        let captionOrMetaPattern = #"^(?:fig(?:ure)?\.?|table|tab\.?|algorithm|listing|eq(?:uation)?\.?|box|scheme|chart|panel|page|vol\.?|no\.?|©)\b|^[图圖表]\s*\d"#
        var candidates: [Candidate] = []
        var pageOccurrences: [String: Set<Int>] = [:]
        var inReferences = false

        for page in pages {
            let leaderCount = page.rawText.filter { $0 == "…" }.count
            guard explicitContentsHeader(in: page.lines, cropBox: page.cropBox) == nil, leaderCount < 3 else { continue }
            let lines = page.lines
            for idx in lines.indices {
                let line = lines[idx]
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (3...85).contains(text.count) else { continue }

                let lowered = text.lowercased()
                let isStandalone = standaloneHeadings.contains(lowered)
                    || ((text.hasPrefix("附录") || text.hasPrefix("附錄")) && text.count <= 20)
                if ["references", "bibliography", "参考文献", "參考文獻"].contains(lowered) {
                    inReferences = true
                    continue
                } else if lowered.hasPrefix("appendix") || text.hasPrefix("附录") || text.hasPrefix("附錄") {
                    inReferences = false
                }
                if inReferences && !isStandalone { continue }

                let lineKey = canonicalTitleKey(text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.decimalDigits)))
                guard !lineKey.isEmpty, !marginKeys.contains(lineKey) else { continue }

                guard !isMidParagraphLine(
                    at: idx,
                    lines: lines,
                    bodyFontSize: bodyFontSize,
                    bodyColumnWidth: bodyColumnWidth,
                    bodyLineStep: bodyLineStep
                ) else { continue }

                guard line.fontSize >= bodyFontSize + 0.45,
                      abs(line.fontSize - line.endFontSize) <= 0.35,
                      line.isBold == line.isEndBold else { continue }

                let alphaOrHanCount = text.unicodeScalars.filter { scalar in
                    ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || (0x4E00...0x9FFF).contains(scalar.value)
                }.count
                guard alphaOrHanCount >= 2 else { continue }

                guard !text.contains("…"),
                      !text.contains("\""), !text.contains("“"), !text.contains("”"),
                      !text.contains("|"), !text.contains("@"),
                      !lowered.contains("http"), !lowered.contains("doi:"),
                      text.first?.isLowercase != true,
                      !(text.last.map { ".,;。，；-=:".contains($0) } ?? false),
                      text.range(of: captionOrMetaPattern, options: [.regularExpression, .caseInsensitive]) == nil else { continue }

                let titleKey = canonicalTitleKey(text)
                guard !titleKey.isEmpty else { continue }
                pageOccurrences[titleKey, default: []].insert(page.index)
                let sizeBucket = (line.fontSize * 2.0).rounded() / 2.0
                let point = line.hasGeometry
                    ? CGPoint(x: line.bounds.minX, y: min(page.cropBox.maxY, line.bounds.maxY + 8))
                    : nil
                candidates.append(Candidate(
                    pageIndex: page.index,
                    title: text,
                    titleKey: titleKey,
                    sizeBucket: sizeBucket,
                    point: point,
                    isStandalone: isStandalone
                ))
            }
        }

        var seenStandalone: Set<String> = []
        let filtered = candidates.filter { candidate in
            let occ = pageOccurrences[candidate.titleKey]?.count ?? 0
            if candidate.isStandalone {
                return seenStandalone.insert(candidate.titleKey).inserted
            }
            return occ < 3
        }
        guard !filtered.isEmpty else { return [] }

        var bucketCounts: [CGFloat: Int] = [:]
        for candidate in filtered {
            bucketCounts[candidate.sizeBucket, default: 0] += 1
        }
        let maxAllowedPerBucket = max(140, pages.count * 2)
        let eligibleTiers = bucketCounts
            .filter { $0.value >= 3 && $0.value <= maxAllowedPerBucket }
            .keys
            .sorted(by: >)
        let selectedTiers = Array(eligibleTiers.prefix(2))
        guard !selectedTiers.isEmpty else { return [] }

        let chosen = filtered.compactMap { candidate -> GeneratedOutlineEntry? in
            guard let tierIndex = selectedTiers.firstIndex(of: candidate.sizeBucket) else { return nil }
            return GeneratedOutlineEntry(
                title: candidate.title,
                pageIndex: candidate.pageIndex,
                level: tierIndex,
                destinationPoint: candidate.point
            )
        }
        let maxTotal = max(150, pages.count * 2)
        guard (3...maxTotal).contains(chosen.count) else { return [] }
        return chosen
    }

    private static func mergeHeadingOutlines(
        structural: [GeneratedOutlineEntry],
        typographic: [GeneratedOutlineEntry]
    ) -> [GeneratedOutlineEntry] {
        var merged = typographic
        var existing = Set(typographic.map { "\($0.pageIndex):\(canonicalTitleKey($0.title))" })
        for entry in structural {
            let key = "\(entry.pageIndex):\(canonicalTitleKey(entry.title))"
            if existing.insert(key).inserted {
                merged.append(entry)
            }
        }
        return merged.enumerated().sorted { lhs, rhs in
            if lhs.element.pageIndex != rhs.element.pageIndex {
                return lhs.element.pageIndex < rhs.element.pageIndex
            }
            let ly = lhs.element.destinationPoint?.y ?? 0
            let ry = rhs.element.destinationPoint?.y ?? 0
            if ly != ry { return ly > ry }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func joinedSubtitleIfBare(
        line: PageLine,
        tailEmpty: Bool,
        nextLine: PageLine?,
        separator: String,
        bodyFontSize: CGFloat,
        bodyColumnWidth: CGFloat
    ) -> (title: String, consumedNext: Bool) {
        guard tailEmpty, let next = nextLine,
              (2...65).contains(next.text.count),
              !next.text.hasSuffix("."), !next.text.hasSuffix("。"),
              !next.text.hasSuffix("?"), !next.text.hasSuffix("？"),
              next.text.range(of: #"[「」『』“”]"#, options: .regularExpression) == nil,
              !isStructuralHeadingLine(next.text),
              (!next.hasGeometry || bodyColumnWidth == 0 || next.fontSize >= bodyFontSize + 1.0
                || next.isBold || next.bounds.width < bodyColumnWidth * 0.80) else {
            return (line.text, false)
        }
        if line.hasGeometry && next.hasGeometry {
            let dy = line.bounds.minY - next.bounds.minY
            guard dy >= -4, dy <= max(line.bounds.height, 12) * 3.5,
                  abs(line.bounds.minX - next.bounds.minX) <= 120 else {
                return (line.text, false)
            }
        }
        return ("\(line.text)\(separator)\(next.text)", true)
    }

    private static func wrappedHeadingContinuation(
        line: PageLine,
        nextLine: PageLine?,
        bodyColumnWidth: CGFloat
    ) -> String? {
        guard let next = nextLine, line.hasGeometry, next.hasGeometry else { return nil }
        let dy = line.bounds.minY - next.bounds.minY
        guard dy > 0, dy <= max(line.bounds.height, 10) * 2.0,
              abs(line.fontSize - next.fontSize) <= 0.5,
              line.isSmallCaps == next.isSmallCaps,
              line.isBold == next.isBold,
              !isStructuralHeadingLine(next.text),
              !next.text.hasSuffix("."), !next.text.hasSuffix("。") else { return nil }
        let centered = abs(line.bounds.midX - next.bounds.midX) <= 6.0
            && (bodyColumnWidth == 0 || next.bounds.width < bodyColumnWidth * 0.80
                || (next.bounds.minX > line.bounds.minX + 8 && next.bounds.maxX < line.bounds.maxX - 8))
        let flushWrap = bodyColumnWidth > 0
            && line.bounds.width >= bodyColumnWidth * 0.88
            && abs(line.bounds.minX - next.bounds.minX) <= 2.5
            && next.bounds.width <= bodyColumnWidth * 0.75
        guard centered || flushWrap else { return nil }
        return "\(line.text) \(next.text)"
    }

    private static func isStructuralHeadingLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return chineseHeading.firstMatch(in: line, range: range) != nil
            || englishHeading.firstMatch(in: line, range: range) != nil
            || romanSectionHeading.firstMatch(in: line, range: range) != nil
            || numberedHeading.firstMatch(in: line, range: range) != nil
            || standaloneHeadings.contains(line.lowercased())
    }

    private static func structuralLevel(for title: String, sawPriorChapter: Bool = false) -> Int {
        let plain = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.range(of: #"^\*?§\s*\d+"#, options: .regularExpression) != nil { return 1 }
        if plain.range(of: #"^(?:chapter|part|unit|appendix(?:es)?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return 0 }
        if plain.range(of: #"^section\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return 1 }
        let range = NSRange(plain.startIndex..., in: plain)
        if let match = numberedHeading.firstMatch(in: plain, range: range),
           let numberRange = Range(match.range(at: 1), in: plain) {
            let dots = plain[numberRange].filter { $0 == "." }.count
            if dots > 0 { return min(3, dots) }
        }
        if plain.range(of: #"^\d+[.、．]\s*\S"#, options: .regularExpression) != nil { return 2 }
        if plain.range(of: #"^\d+\s+\p{L}"#, options: .regularExpression) != nil { return 0 }
        if title.range(of: #"^第\s*[一二三四五六七八九十百千万零〇兩两0-9]+\s*[章篇部卷]"#, options: .regularExpression) != nil { return 0 }
        if title.range(of: #"第\s*.+[节節]"#, options: .regularExpression) != nil { return 1 }
        if standaloneHeadings.contains(plain.lowercased()) { return 0 }
        return sawPriorChapter ? 1 : 0
    }

    /// Only structural TOC rows are accepted. Dropping a doubtful line is preferable to showing OCR noise,
    /// running headers, exercises, leader dots or two merged titles in the navigation sidebar.
    private static func cleanedTOCTitle(_ raw: String, allowUnnumbered: Bool = false) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(
            of: #"^(?:目录|目錄|table of contents|contents)\s*\d*\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let standaloneExercisePattern = #"^(?:(?:chapter|unit|section|\d+(?:\.\d+)*)[.、．:\s]+)?(?:exercises?|problems|problem sets?|review exercises?|practice problems?)(?:\s+[\d.]+)?$"#
        // Recover the later chapter when OCR joins `第一章总练习题` and `第二章`; reject ordinary exercises
        // before stripping a running-header prefix, otherwise `习题1.1` would become a false `1.1` heading.
        var fullRange = NSRange(title.startIndex..., in: title)
        let joinedChapters = chapterMarker.matches(in: title, range: fullRange)
        if (title.contains("总练习题") || title.contains("總練習題")), let last = joinedChapters.last, last.range.location > 0 {
            title = (title as NSString).substring(from: last.range.location)
        } else if title.contains("习题") || title.contains("習題")
                    || title.range(of: standaloneExercisePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        let structuralRange = NSRange(title.startIndex..., in: title)
        let startsCleanly = title.range(of: #"^[\p{Han}A-Za-z]"#, options: .regularExpression) != nil
        if (!allowUnnumbered || !startsCleanly),
           let marker = structuralMarker.firstMatch(in: title, range: structuralRange),
           marker.range.location > 0 {
            title = (title as NSString).substring(from: marker.range.location)
        }
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .．·•…_—-"))

        fullRange = NSRange(title.startIndex..., in: title)
        guard (2...120).contains(title.count),
              !title.contains("习题"), !title.contains("\u{FFFD}"),
              !title.contains("習題"),
              title.range(of: standaloneExercisePattern, options: [.regularExpression, .caseInsensitive]) == nil,
              title.range(of: #"[A-Za-z][“][A-Za-z]"#, options: .regularExpression) == nil else { return nil }

        let chapterCount = chapterMarker.numberOfMatches(in: title, range: fullRange)
        guard chapterCount <= 1 else { return nil }
        let structural = title.range(of: #"^\*?§\s*\d+"#, options: .regularExpression) != nil
            || title.range(of: #"^第\s*[一二三四五六七八九十百千万零〇兩两0-9]+\s*[章节節篇部卷]"#,
                           options: .regularExpression) != nil
            || title.range(of: #"^(?:chapter|part|unit|section|appendix)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[ivxlcdm]+|\d+|[a-z])\b"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
            || title.range(of: #"^\d+(?:\.\d+)*[.、．]\s*\S"#, options: .regularExpression) != nil
            || title.range(of: #"^\d+(?:\.\d+)*\s+\p{L}"#, options: .regularExpression) != nil
            || standaloneHeadings.contains(title.lowercased())
            || (allowUnnumbered && title.first?.isNumber == false && title.range(of: #"^[\p{Han}A-Za-z]"#, options: .regularExpression) != nil)
        return structural ? title : nil
    }

    private static func deduplicated(_ entries: [GeneratedOutlineEntry]) -> [GeneratedOutlineEntry] {
        var seen = Set<String>()
        return entries.filter {
            let key = "\($0.pageIndex):\(canonicalTitleKey($0.title))"
            return seen.insert(key).inserted
        }
    }
}
