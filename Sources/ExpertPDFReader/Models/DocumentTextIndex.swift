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

    func recognizedText(for page: PDFPage, pageIndex: Int) -> IndexedPageText? {
        if let cached = stored.pages[pageIndex] { return cached }
        guard !Task.isCancelled, let data = page.dataRepresentation else { return nil }
        let recognized: IndexedPageText?
        if let positioned = try? PageTextRecognition.selectableText(pageData: data) {
            recognized = IndexedPageText(positioned)
        } else if let plain = try? PageTextRecognition.recognize(pageData: data) {
            recognized = IndexedPageText(text: plain)
        } else {
            recognized = nil
        }
        if let recognized {
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
        return caches.appendingPathComponent("ExpertPDFReader/OCRText-v1", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16)).appendingPathExtension("json")
    }
}

enum HybridDocumentSearch {
    /// OCR only pages that are scans or have no meaningful text layer. Native PDFKit search remains the fast
    /// and precise path for ordinary PDFs.
    static func ocrMatches(query: String, document: PDFDocument) -> [OCRSearchMatch] {
        let session = DocumentTextIndexSession(documentURL: document.documentURL)
        var result: [OCRSearchMatch] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            let native = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let replacementCount = native.unicodeScalars.filter { $0.value == 0xFFFD }.count
            let badTextLayer = native.count < 8 || replacementCount * 8 > max(1, native.unicodeScalars.count)
            guard page.hasFullPageScanImage || badTextLayer else { continue }
            if let indexed = session.recognizedText(for: page, pageIndex: index) {
                result.append(contentsOf: indexed.matches(query, pageIndex: index))
            }
        }
        session.save()
        return result
    }
}

struct GeneratedOutlineEntry: Sendable, Equatable {
    let title: String
    let pageIndex: Int
    let level: Int
}

enum AutomaticOutlineGenerator {
    /// Not anchored: OCR frequently joins two printed TOC rows into one logical line. Iterating every match
    /// recovers both `…(73)第二章…(77)` entries instead of turning the whole line into a bogus title.
    private static let tocEntry = try! NSRegularExpression(
        pattern: #"(.{2,120}?)(?:[\.．·•_—\-]{2,}|…+)\s*[（(]?\s*([ivxlcdmIVXLCDM]+|\d{1,5})\s*[）)]?"#
    )
    private static let numberedHeading = try! NSRegularExpression(
        pattern: #"^\s*((?:\d+\.)*\d+)[、.．:\s]+(.{1,80})$"#
    )
    private static let chineseHeading = try! NSRegularExpression(
        pattern: #"^\s*(第[一二三四五六七八九十百千万零〇两0-9]+[章节篇部卷])(?:[、.．:\s]+)?(.{0,80})$"#
    )
    private static let chapterMarker = try! NSRegularExpression(
        pattern: #"第[一二三四五六七八九十百千万零〇两0-9]+章"#
    )
    private static let structuralMarker = try! NSRegularExpression(
        pattern: #"(?:\*?§\s*\d+|第[一二三四五六七八九十百千万零〇两0-9]+[章节篇部卷]|\d+[.、．]\s*\S)"#
    )

    static func generate(document: PDFDocument, pageLabels: [String: [Int]]) -> [GeneratedOutlineEntry] {
        let session = DocumentTextIndexSession(documentURL: document.documentURL)
        var pageTexts: [(index: Int, text: String)] = []
        pageTexts.reserveCapacity(document.pageCount)
        let contentsProbeEnd = min(50, document.pageCount)
        for index in 0..<contentsProbeEnd {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            if let text = pageText(page, index: index, session: session) { pageTexts.append((index, text)) }
        }
        guard !Task.isCancelled else { return [] }
        if let toc = outlineFromContentsPages(pageTexts, pageLabels: pageLabels, pageCount: document.pageCount),
           toc.count >= 3 {
            session.save()
            return toc
        }

        // Only books without a usable contents section need the more expensive whole-document heading pass.
        for index in contentsProbeEnd..<document.pageCount {
            guard !Task.isCancelled, let page = document.page(at: index) else { break }
            if let text = pageText(page, index: index, session: session) { pageTexts.append((index, text)) }
        }
        session.save()
        guard !Task.isCancelled else { return [] }
        return outlineFromHeadings(pageTexts)
    }

    private static func pageText(_ page: PDFPage, index: Int,
                                 session: DocumentTextIndexSession) -> String? {
        let native = PDFTextCleanup.normalize(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if native.count >= 8 && !page.hasFullPageScanImage { return native }
        return session.recognizedText(for: page, pageIndex: index)?.text
    }

    private static func outlineFromContentsPages(
        _ pages: [(index: Int, text: String)], pageLabels: [String: [Int]], pageCount: Int
    ) -> [GeneratedOutlineEntry]? {
        var parsedPages: [(index: Int, entries: [GeneratedOutlineEntry])] = []
        for page in pages.prefix(min(50, pages.count)) {
            var entries: [GeneratedOutlineEntry] = []
            var pendingSection: String?
            for rawLine in page.text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(line.startIndex..., in: line)
                var lineEntries: [GeneratedOutlineEntry] = []
                for match in tocEntry.matches(in: line, range: range) {
                    guard let titleRange = Range(match.range(at: 1), in: line),
                          let labelRange = Range(match.range(at: 2), in: line),
                          let title = cleanedTOCTitle(String(line[titleRange])) else { continue }
                    let label = String(line[labelRange]).lowercased()
                    let candidates = pageLabels[label] ?? pageLabels[label.uppercased()] ?? []
                    let direct = candidates.first(where: { $0 > page.index })
                    let physical = Int(label).map { $0 - 1 }.flatMap {
                        $0 > page.index && $0 < pageCount ? $0 : nil
                    }
                    guard let target = direct ?? physical else { continue }
                    lineEntries.append(GeneratedOutlineEntry(title: title, pageIndex: target,
                                                             level: inferredLevel(for: title)))
                }
                if let pendingSection, let first = lineEntries.first, first.level == 2 {
                    entries.append(GeneratedOutlineEntry(title: pendingSection, pageIndex: first.pageIndex,
                                                         level: inferredLevel(for: pendingSection)))
                }
                if pendingSection != nil, !lineEntries.isEmpty { pendingSection = nil }
                entries.append(contentsOf: lineEntries)
                if lineEntries.isEmpty, let structural = cleanedTOCTitle(line), inferredLevel(for: structural) <= 1 {
                    pendingSection = structural
                }
            }
            let monotonic = zip(entries, entries.dropFirst()).filter { $0.pageIndex <= $1.pageIndex }.count
            if entries.count >= 3, monotonic >= entries.count - 2 {
                parsedPages.append((page.index, entries))
            }
        }
        guard !parsedPages.isEmpty else { return nil }

        // A real contents section normally spans consecutive pages. Keep the longest such run instead of
        // mixing an isolated list/table elsewhere in the book into the outline.
        var runs: [[(index: Int, entries: [GeneratedOutlineEntry])]] = []
        for parsed in parsedPages {
            if let last = runs.last?.last, parsed.index == last.index + 1 {
                runs[runs.count - 1].append(parsed)
            } else {
                runs.append([parsed])
            }
        }
        let best = runs.max { left, right in
            left.reduce(0) { $0 + $1.entries.count } < right.reduce(0) { $0 + $1.entries.count }
        } ?? []
        return deduplicated(best.flatMap(\.entries))
    }

    private static func outlineFromHeadings(_ pages: [(index: Int, text: String)]) -> [GeneratedOutlineEntry] {
        var result: [GeneratedOutlineEntry] = []
        let standalone = Set(["前言", "序言", "绪论", "引言", "结语", "结论", "参考文献", "附录"])
        for page in pages {
            let pageLines = page.text.components(separatedBy: .newlines)
            let leaderCount = page.text.filter { $0 == "…" }.count
            guard !pageLines.prefix(4).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("目录") }),
                  leaderCount < 3 else { continue }
            for rawLine in pageLines.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).prefix(8) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...90).contains(line.count), !line.contains("…"), !line.contains("……") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if let match = chineseHeading.firstMatch(in: line, range: range) {
                    let prefix = Range(match.range(at: 1), in: line).map { String(line[$0]) } ?? line
                    let level = prefix.contains("节") ? 1 : 0
                    result.append(GeneratedOutlineEntry(title: line, pageIndex: page.index, level: level))
                } else if let match = numberedHeading.firstMatch(in: line, range: range),
                          let numberRange = Range(match.range(at: 1), in: line) {
                    let number = String(line[numberRange])
                    result.append(GeneratedOutlineEntry(title: line, pageIndex: page.index,
                                                        level: max(0, number.filter { $0 == "." }.count)))
                } else if standalone.contains(line) || (line.hasPrefix("附录") && line.count <= 20) {
                    result.append(GeneratedOutlineEntry(title: line, pageIndex: page.index, level: 0))
                }
            }
        }
        return deduplicated(result)
    }

    private static func inferredLevel(for title: String) -> Int {
        let plain = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.range(of: #"^\*?§\s*\d+"#, options: .regularExpression) != nil { return 1 }
        if plain.range(of: #"^\d+[.、．]\s*\S"#, options: .regularExpression) != nil { return 2 }
        let range = NSRange(title.startIndex..., in: title)
        if let match = numberedHeading.firstMatch(in: title, range: range),
           let numberRange = Range(match.range(at: 1), in: title) {
            return max(0, title[numberRange].filter { $0 == "." }.count)
        }
        if title.range(of: #"第.+节"#, options: .regularExpression) != nil { return 1 }
        return 0
    }

    /// Only structural TOC rows are accepted. Dropping a doubtful line is preferable to showing OCR noise,
    /// running headers, exercises, leader dots or two merged titles in the navigation sidebar.
    private static func cleanedTOCTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: #"^目录\s*\d*\s*"#, with: "", options: .regularExpression)
        // Recover the later chapter when OCR joins `第一章总练习题` and `第二章`; reject ordinary exercises
        // before stripping a running-header prefix, otherwise `习题1.1` would become a false `1.1` heading.
        var fullRange = NSRange(title.startIndex..., in: title)
        let joinedChapters = chapterMarker.matches(in: title, range: fullRange)
        if title.contains("总练习题"), let last = joinedChapters.last, last.range.location > 0 {
            title = (title as NSString).substring(from: last.range.location)
        } else if title.contains("习题") {
            return nil
        }
        let structuralRange = NSRange(title.startIndex..., in: title)
        if let marker = structuralMarker.firstMatch(in: title, range: structuralRange), marker.range.location > 0 {
            title = (title as NSString).substring(from: marker.range.location)
        }
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .．·•…_—-"))

        fullRange = NSRange(title.startIndex..., in: title)
        guard (2...70).contains(title.count),
              !title.contains("习题"), !title.contains("�"),
              title.range(of: #"[A-Za-z][“”\"]"#, options: .regularExpression) == nil else { return nil }

        let chapterCount = chapterMarker.numberOfMatches(in: title, range: fullRange)
        guard chapterCount <= 1 else { return nil }
        let structural = title.range(of: #"^\*?§\s*\d+"#, options: .regularExpression) != nil
            || title.range(of: #"^第[一二三四五六七八九十百千万零〇两0-9]+[章节篇部卷]"#,
                           options: .regularExpression) != nil
            || title.range(of: #"^\d+[.、．]\s*\S"#, options: .regularExpression) != nil
            || ["绪论", "前言", "序言", "引言", "结语", "结论", "参考文献", "附录"].contains(title)
        return structural ? title : nil
    }

    private static func deduplicated(_ entries: [GeneratedOutlineEntry]) -> [GeneratedOutlineEntry] {
        var seen = Set<String>()
        return entries.filter {
            let key = "\($0.pageIndex):\($0.title.lowercased())"
            return seen.insert(key).inserted
        }
    }
}
