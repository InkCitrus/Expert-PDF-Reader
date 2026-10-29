import CoreGraphics
import Foundation
import PDFKit
import Vision

/// What a sample of a book's pages shows, read from the PDF's text layer when present or with on-device text
/// recognition for scans: the page numbers printed on them and the direction the book reads. Scans and many
/// digital books carry page labels numbered in file order, or none at all, and a book bound on the right
/// (vertical Chinese and Japanese) may be stored in reading order or, as the Internet Archive scans it, with
/// each spread's left page first.
public struct BookPageScan: Codable, Equatable {
    public static let currentVersion = 2

    public var version: Int? = Self.currentVersion
    public var printedNumbers: PrintedPageNumbers?
    /// Spreads read right to left: the earlier page belongs on the right. `nil` when the sample did not tell
    public var readsRightToLeft: Bool?

    public init(
        version: Int? = Self.currentVersion,
        printedNumbers: PrintedPageNumbers? = nil,
        readsRightToLeft: Bool? = nil
    ) {
        self.version = version
        self.printedNumbers = printedNumbers
        self.readsRightToLeft = readsRightToLeft
    }
}

public struct PrintedPageNumbers: Codable, Equatable {
    /// A run of pages numbered consecutively: printed number = page index + offset. Unnumbered inserts (plates,
    /// blank leaves) start a new run with a smaller offset
    public struct Run: Codable, Equatable {
        public var firstIndex: Int
        public var lastIndex: Int
        public var offset: Int
    }

    public var runs: [Run]
    /// Added to the offset on odd page indices: ±2 when every spread is stored left page first while the book
    /// reads right to left, so its pages alternate 7, 6, 9, 8…
    public var oddIndexShift: Int
    /// The PDF's own page labels disagree with what is printed (or are missing), so these numbers replace them
    public var replacesPageLabels: Bool
    /// Front-matter labels printed before the main Arabic numbering begins (e.g. "i", "ii" or "目录 - 1")
    public var frontMatterLabels: [Int: String]?

    public func number(at index: Int) -> Int? {
        guard let run = runs.first(where: { $0.firstIndex <= index && index <= $0.lastIndex }) else { return nil }
        let number = index + run.offset + (index % 2 == 1 ? oddIndexShift : 0)
        return number > 0 ? number : nil
    }

    public func label(at index: Int) -> String? {
        if let frontMatter = frontMatterLabels?[index] {
            return frontMatter
        }
        return number(at: index).map(String.init)
    }
}

public enum BookPageScanner {
    enum WritingDirection {
        case horizontal, vertical
    }

    struct Reading {
        let index: Int
        /// The printed page number and its horizontal centre, 0 (left edge) … 1 (right edge)
        let number: Int?
        let position: CGFloat
        let writing: WritingDirection?
        /// The PDF's page label for the page
        let label: String?
    }

    private struct PositionedText {
        let text: String
        /// Normalized horizontal centre across the page, 0 (left) … 1 (right)
        let midX: CGFloat
        /// Distance from the outer edge of the strip (0 = right at the bottom/top edge, 1 = inner edge of strip)
        let distanceFromOuterEdge: CGFloat
    }

    /// Pages read once each, as scanning goes back to narrow down where the numbering jumps
    final class PageReader {
        let document: PDFDocument
        let isDigitalTextDocument: Bool
        private(set) var readings: [Int: Reading] = [:]

        init(document: PDFDocument) {
            self.document = document
            self.isDigitalTextDocument = BookPageScanner.hasEmbeddedText(document)
        }

        func read(_ index: Int) -> Reading? {
            if let reading = readings[index] { return reading }
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return nil }

            // Digital PDFs already carry selectable text with exact character bounds: reading the header/footer
            // directly takes microseconds per page and avoids OCR errors on code listings or small fonts.
            if let textReading = readFromTextLayer(page: page, index: index) {
                readings[index] = textReading
                return textReading
            }

            // On a digital text PDF, a page without text is a cover, divider or blank leaf — skip slow OCR
            if isDigitalTextDocument {
                let empty = Reading(index: index, number: nil, position: 0.5, writing: nil, label: page.printedNumber)
                readings[index] = empty
                return empty
            }

            guard let image = render(page) else { return nil }
            let found = readNumber(in: image)
            let reading = Reading(
                index: index,
                number: found?.number,
                position: found?.position ?? 0.5,
                writing: writingDirection(in: image),
                label: page.printedNumber
            )
            readings[index] = reading
            return reading
        }

        private func readFromTextLayer(page: PDFPage, index: Int) -> Reading? {
            guard let fullText = page.string,
                  fullText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else {
                return nil
            }
            let box = page.bounds(for: .cropBox)
            guard box.width > 40, box.height > 40, page.rotation % 360 == 0 else { return nil }

            let stripHeight = box.height / 8
            let bottomRect = CGRect(x: box.minX, y: box.minY, width: box.width, height: stripHeight)
            let topRect = CGRect(x: box.minX, y: box.maxY - stripHeight, width: box.width, height: stripHeight)

            let found = extractStripNumber(in: bottomRect, on: page, box: box, isBottom: true)
                ?? extractStripNumber(in: topRect, on: page, box: box, isBottom: false)

            return Reading(
                index: index,
                number: found?.number,
                position: found?.position ?? 0.5,
                writing: textLayerWritingDirection(on: page, box: box),
                label: page.printedNumber
            )
        }

        fileprivate func readRawFrontMatterLabel(at index: Int) -> String? {
            guard index >= 0, index < document.pageCount,
                  let page = document.page(at: index),
                  let fullText = page.string,
                  !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let box = page.bounds(for: .cropBox)
            guard box.width > 40, box.height > 40, page.rotation % 360 == 0 else { return nil }
            let stripHeight = box.height / 8
            let bottomRect = CGRect(x: box.minX, y: box.minY, width: box.width, height: stripHeight)
            let topRect = CGRect(x: box.minX, y: box.maxY - stripHeight, width: box.width, height: stripHeight)
            return outermostLineText(in: bottomRect, on: page, box: box, isBottom: true)
                ?? outermostLineText(in: topRect, on: page, box: box, isBottom: false)
        }

        private func outermostLineText(in rect: CGRect, on page: PDFPage, box: CGRect, isBottom: Bool) -> String? {
            let items = positionedLines(in: rect, on: page, box: box, isBottom: isBottom)
            guard let minDist = items.map(\.distanceFromOuterEdge).min() else { return nil }
            let tolerance: CGFloat = 0.08 // 1% of page height
            let baseline = items.filter { $0.distanceFromOuterEdge <= minDist + tolerance }
            guard baseline.count == 1 else { return nil }
            return baseline[0].text
        }

        private func extractStripNumber(
            in rect: CGRect,
            on page: PDFPage,
            box: CGRect,
            isBottom: Bool
        ) -> (number: Int, position: CGFloat)? {
            let items = positionedLines(in: rect, on: page, box: box, isBottom: isBottom)
            return pickPageNumber(from: items)
        }

        private func positionedLines(in rect: CGRect, on page: PDFPage, box: CGRect, isBottom: Bool) -> [PositionedText] {
            guard let selection = page.selection(for: rect) else { return [] }
            let stripHeight = max(1, rect.height)
            return selection.selectionsByLine().compactMap { line -> PositionedText? in
                guard let raw = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                let b = line.bounds(for: page)
                guard b.width > 0, b.height > 0 else { return nil }
                // Exclude lines whose vertical centre actually lies outside the strip
                guard rect.contains(CGPoint(x: b.midX, y: b.midY)) else { return nil }
                let dist = isBottom
                    ? max(0, (b.minY - box.minY) / stripHeight)
                    : max(0, (box.maxY - b.maxY) / stripHeight)
                let midX = min(max(0, (b.midX - box.minX) / box.width), 1)
                return PositionedText(text: raw, midX: midX, distanceFromOuterEdge: dist)
            }
        }

        private func textLayerWritingDirection(on page: PDFPage, box: CGRect) -> WritingDirection? {
            let bodyRect = box.insetBy(dx: box.width * 0.1, dy: box.height * 0.14)
            guard let sel = page.selection(for: bodyRect) else { return nil }
            var horizontal = 0
            var vertical = 0
            for line in sel.selectionsByLine().prefix(40) {
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      text.count >= 4 else { continue }
                let b = line.bounds(for: page)
                if b.width > b.height * 1.6 {
                    horizontal += 1
                } else if b.height > b.width * 1.6 {
                    vertical += 1
                }
            }
            if horizontal >= 3 && horizontal >= vertical * 2 { return .horizontal }
            if vertical >= 3 && vertical >= horizontal * 2 { return .vertical }
            return nil
        }
    }

    /// True if `document` has selectable text on sample pages, so scanning finishes in milliseconds without OCR.
    public static func hasEmbeddedText(_ document: PDFDocument) -> Bool {
        let count = document.pageCount
        guard count > 0 else { return false }
        let probes = [count / 4, count / 2, count * 3 / 4]
        var withText = 0
        for idx in probes where idx >= 0 && idx < count {
            if let text = document.page(at: idx)?.string,
               text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16 {
                withText += 1
            }
        }
        return withText >= 2
    }

    /// Looks at pairs of neighbouring pages spread over the book, then at pages between two samples whose numbering
    /// disagrees. Instant on digital PDFs; takes a few seconds on image-only scans. Call off the main thread with a
    /// private copy of the document.
    public static func scan(_ document: PDFDocument, pairs: Int = 10) -> BookPageScan {
        let count = document.pageCount
        guard count >= 16 else { return BookPageScan() }
        let reader = PageReader(document: document)
        for index in sampleIndices(pageCount: count, pairs: pairs) {
            _ = reader.read(index)
        }
        let numbers = printedNumbers(using: reader, pageCount: count)
        return BookPageScan(
            printedNumbers: numbers,
            readsRightToLeft: readsRightToLeft(Array(reader.readings.values), numbers: numbers)
        )
    }

    static func sampleIndices(pageCount: Int, pairs: Int) -> [Int] {
        (0..<pairs).flatMap { k -> [Int] in
            let first = (pageCount - 2) * (k + 1) / (pairs + 1)
            return [first, first + 1]
        }
    }

    // MARK: - Numbering

    static func printedNumbers(using reader: PageReader, pageCount: Int) -> PrintedPageNumbers? {
        let numbered = reader.readings.values.filter { $0.number != nil }.sorted { $0.index < $1.index }

        // Neighbouring pages tell whether odd pages run 2 ahead or behind (each spread stored left page first)
        var shifts: [Int: Int] = [:]
        for reading in numbered {
            guard let next = reader.readings[reading.index + 1], let nextNumber = next.number else { continue }
            let difference = (nextNumber - next.index) - (reading.number! - reading.index)
            // Measured from an even page to the odd one after it, or backwards
            let shift = reading.index % 2 == 0 ? difference : -difference
            if [0, 2, -2].contains(shift) { shifts[shift, default: 0] += 1 }
        }
        guard let (oddIndexShift, votes) = shifts.max(by: { $0.value < $1.value }),
              votes * 10 >= shifts.values.reduce(0, +) * 7, votes >= 3 else { return nil }

        func offset(of reading: Reading) -> Int {
            reading.number! - reading.index - (reading.index % 2 == 1 ? oddIndexShift : 0)
        }

        // Runs of samples sharing an offset; a lone sample that disagrees with both neighbours is a stray digit
        var points = numbered.map { (index: $0.index, offset: offset(of: $0)) }
        points = points.enumerated().filter { position, point in
            guard position > 0, position < points.count - 1 else { return true }
            let before = points[position - 1].offset, after = points[position + 1].offset
            return !(before == after && point.offset != before)
        }.map(\.element)
        var runs: [PrintedPageNumbers.Run] = []
        for point in points {
            if let last = runs.last, last.offset == point.offset {
                runs[runs.count - 1].lastIndex = point.index
            } else {
                runs.append(.init(firstIndex: point.index, lastIndex: point.index, offset: point.offset))
            }
        }
        guard !runs.isEmpty else { return nil }

        // Narrow down each jump between runs by reading the pages in between
        for position in runs.indices.dropLast() {
            var low = runs[position].lastIndex, high = runs[position + 1].firstIndex
            let lowOffset = runs[position].offset, highOffset = runs[position + 1].offset
            var probes = 0
            while high - low > 1, probes < 10 {
                probes += 1
                let middle = (low + high) / 2
                // An unnumbered page (a chapter opening) tells nothing; try its neighbours
                guard let reading = [middle, middle + 1, middle - 1].lazy
                    .filter({ $0 > low && $0 < high })
                    .compactMap({ reader.read($0) })
                    .first(where: { $0.number != nil }) else { break }
                let found = offset(of: reading)
                if found == lowOffset {
                    low = reading.index
                } else if found == highOffset {
                    high = reading.index
                } else {
                    break
                }
            }
            runs[position].lastIndex = low
            runs[position + 1].firstIndex = high
        }
        // Single-page runs that never got confirmed by a neighbour are dropped
        runs = runs.filter { $0.lastIndex > $0.firstIndex || runs.count == 1 }
        guard !runs.isEmpty else { return nil }

        // Narrow where the first run actually starts so front matter (cover, Roman preface, TOC) is not overwritten
        runs[0].firstIndex = findFirstRunStart(
            firstSampleIndex: runs[0].firstIndex,
            runOffset: runs[0].offset,
            oddIndexShift: oddIndexShift,
            reader: reader,
            offsetOf: offset
        )

        // Narrow where the last run ends so unnumbered back covers / flyleaves at the end are left unnumbered
        runs[runs.count - 1].lastIndex = findLastRunEnd(
            lastSampleIndex: runs[runs.count - 1].lastIndex,
            runOffset: runs[runs.count - 1].offset,
            pageCount: pageCount,
            reader: reader,
            offsetOf: offset
        )

        let frontMatter = detectFrontMatterLabels(before: runs[0].firstIndex, reader: reader)

        let model = PrintedPageNumbers(
            runs: runs,
            oddIndexShift: oddIndexShift,
            replacesPageLabels: false,
            frontMatterLabels: frontMatter.isEmpty ? nil : frontMatter
        )
        let checked = numbered.filter { model.number(at: $0.index) == $0.number }
        guard checked.count * 10 >= numbered.count * 7 else { return nil }
        let labelsMatch = checked.filter { $0.label == String($0.number!) }.count
        var result = model
        result.replacesPageLabels = labelsMatch * 10 < checked.count * 8 || !frontMatter.isEmpty
        return result
    }

    private static func findFirstRunStart(
        firstSampleIndex: Int,
        runOffset: Int,
        oddIndexShift: Int,
        reader: PageReader,
        offsetOf: (Reading) -> Int
    ) -> Int {
        // Earliest index whose computed Arabic page number is >= 1
        var earliest = 0
        while earliest < firstSampleIndex {
            let num = earliest + runOffset + (earliest % 2 == 1 ? oddIndexShift : 0)
            if num >= 1 { break }
            earliest += 1
        }
        guard earliest < firstSampleIndex else { return firstSampleIndex }

        // Check `earliest` (or the next 1-2 pages when Page 1 is an unnumbered title/chapter opening)
        for probe in earliest...min(earliest + 2, firstSampleIndex) {
            if let r = reader.read(probe), r.number != nil {
                if offsetOf(r) == runOffset {
                    return earliest
                }
                break
            }
        }

        // Binary-narrow between `earliest` and `firstSampleIndex` when front matter used positive indices
        var low = earliest
        var high = firstSampleIndex
        var probes = 0
        while high - low > 1, probes < 8 {
            probes += 1
            let mid = (low + high) / 2
            guard let reading = [mid, mid + 1, mid - 1].lazy
                .filter({ $0 > low && $0 < high })
                .compactMap({ reader.read($0) })
                .first(where: { $0.number != nil }) else { break }
            if offsetOf(reading) == runOffset {
                high = reading.index
            } else {
                low = reading.index
            }
        }
        // Include an unnumbered chapter-opening page right before `high` if its implied number is >= 1
        if high > earliest, let prev = reader.read(high - 1), prev.number == nil {
            let implied = (high - 1) + runOffset + ((high - 1) % 2 == 1 ? oddIndexShift : 0)
            if implied == 1 {
                return high - 1
            }
        }
        return high
    }

    private static func findLastRunEnd(
        lastSampleIndex: Int,
        runOffset: Int,
        pageCount: Int,
        reader: PageReader,
        offsetOf: (Reading) -> Int
    ) -> Int {
        let lastPage = pageCount - 1
        guard lastSampleIndex < lastPage else { return lastPage }

        // Check the last few pages (back cover, colophon, blank flyleaves) from the very end inwards
        let tailWindow = min(6, lastPage - lastSampleIndex)
        for idx in stride(from: lastPage, through: lastPage - tailWindow + 1, by: -1) {
            if let r = reader.read(idx), r.number != nil, offsetOf(r) == runOffset {
                return idx
            }
        }

        // Binary-narrow if more than `tailWindow` pages at the end are unnumbered (e.g. index plates / appendices)
        var low = lastSampleIndex
        var high = lastPage - tailWindow + 1
        var probes = 0
        while high - low > 1, probes < 8 {
            probes += 1
            let mid = (low + high) / 2
            guard let reading = [mid, mid - 1, mid + 1].lazy
                .filter({ $0 > low && $0 < high })
                .compactMap({ reader.read($0) })
                .first(where: { $0.number != nil }) else { break }
            if offsetOf(reading) == runOffset {
                low = reading.index
            } else {
                high = reading.index
            }
        }
        return low
    }

    /// Detects sequential Roman numerals ("i", "ii"…) or prefixed section numbers ("目录 - 1", "目录 - 2"…)
    /// on front-matter pages before `bodyStartIndex`.
    private static func detectFrontMatterLabels(before bodyStartIndex: Int, reader: PageReader) -> [Int: String] {
        guard bodyStartIndex >= 2, bodyStartIndex <= 32 else { return [:] }
        var rawByIndex: [Int: String] = [:]
        for idx in 0..<bodyStartIndex {
            if let raw = reader.readRawFrontMatterLabel(at: idx) {
                rawByIndex[idx] = raw
            }
        }
        guard rawByIndex.count >= 2 else { return [:] }

        var accepted: [Int: String] = [:]

        // 1. Sequential Roman numerals (e.g. i, ii, iii, iv or I, II, III, IV)
        var romanOffsets: [Int: Int] = [:]
        var romanValues: [Int: (value: Int, text: String)] = [:]
        for (idx, text) in rawByIndex {
            let trimmed = stripPageDecorations(text)
            if let val = parseRomanNumeral(trimmed) {
                romanValues[idx] = (val, trimmed)
                romanOffsets[val - idx, default: 0] += 1
            }
        }
        if let (bestOffset, count) = romanOffsets.max(by: { $0.value < $1.value }), count >= 2 {
            for (idx, entry) in romanValues where entry.value - idx == bestOffset {
                accepted[idx] = entry.text
            }
        }

        // 2. Prefixed sequential front-matter labels (e.g. "目录 - 1" .. "目录 - 5", "TOC 1" .. "TOC 4")
        var byPrefix: [String: [(idx: Int, number: Int, fullText: String)]] = [:]
        for (idx, text) in rawByIndex where accepted[idx] == nil {
            if let parsed = parsePrefixedPageLabel(text) {
                byPrefix[parsed.prefix, default: []].append((idx, parsed.number, parsed.fullText))
            }
        }
        for (_, group) in byPrefix where group.count >= 2 {
            var offsets: [Int: Int] = [:]
            for entry in group {
                offsets[entry.number - entry.idx, default: 0] += 1
            }
            if let (bestOffset, count) = offsets.max(by: { $0.value < $1.value }), count >= 2 {
                for entry in group where entry.number - entry.idx == bestOffset {
                    accepted[entry.idx] = entry.fullText
                }
            }
        }

        return accepted
    }

    // MARK: - Candidate Selection & Parsing

    /// Picks the page number from items in a top/bottom margin strip by looking ONLY at the outermost occupied
    /// baseline (closest to the bottom or top edge of the page), preventing code listing line numbers or body
    /// text digits further inside the page from masquerading as page numbers.
    private static func pickPageNumber(from items: [PositionedText]) -> (number: Int, position: CGFloat)? {
        guard let minDist = items.map(\.distanceFromOuterEdge).min() else { return nil }
        // 0.08 of the 1/8 strip = 1% of page height (~8pt on A4), keeping items on the same footer/header baseline
        let baselineTolerance: CGFloat = 0.08
        let outermost = items.filter { $0.distanceFromOuterEdge <= minDist + baselineTolerance }

        var candidates: [(number: Int, position: CGFloat)] = []
        for item in outermost {
            if let number = parseStandalonePageNumber(item.text) {
                candidates.append((number, item.midX))
            } else if outermost.count == 1, let edgeHit = parseRunningHeaderFooterLine(item.text, lineMidX: item.midX) {
                candidates.append(edgeHit)
            }
        }

        // If several tokens sit on the outermost baseline (e.g. chapter title + corner page number), prefer the
        // one nearest an outer corner; if there is just one standalone number (including centered at 0.50), return it.
        return candidates.max { abs($0.position - 0.5) < abs($1.position - 0.5) }
    }

    private static func stripPageDecorations(_ text: String) -> String {
        let decoration = CharacterSet(charactersIn: "-–—―·•[]()（） \t")
        return text.trimmingCharacters(in: decoration)
    }

    private static func parseStandalonePageNumber(_ raw: String) -> Int? {
        let cleaned = stripPageDecorations(raw)
        guard (1...4).contains(cleaned.count), cleaned.allSatisfy(\.isASCII), let n = Int(cleaned), n > 0 else {
            return nil
        }
        return n
    }

    /// Handles a combined single-line running header/footer like `"12   第一章 基础算法"` or `"Chapter 3   45"`
    /// where PDFKit grouped title and outer-corner page number into one line, while rejecting TOC lines (`... 57`),
    /// code statements (`return 0;`), and hyphenated section labels (`目录 - 1`).
    private static func parseRunningHeaderFooterLine(_ raw: String, lineMidX: CGFloat) -> (number: Int, position: CGFloat)? {
        guard !raw.contains(".."), !raw.contains("…"), !raw.contains(";"), !raw.contains("{"), !raw.contains("}") else {
            return nil
        }
        // Require wide whitespace separation (at least 3 spaces or a tab) between running title and page number
        if let tabRange = raw.range(of: "\t") {
            let left = String(raw[..<tabRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(raw[tabRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let n = parseStandalonePageNumber(left), parseStandalonePageNumber(right) == nil {
                return (n, min(0.15, lineMidX))
            }
            if let n = parseStandalonePageNumber(right), parseStandalonePageNumber(left) == nil {
                return (n, max(0.85, lineMidX))
            }
        }
        if let gapRange = raw.range(of: "   ") {
            let left = String(raw[..<gapRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(raw[gapRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let n = parseStandalonePageNumber(left), parseStandalonePageNumber(right) == nil {
                return (n, min(0.15, lineMidX))
            }
            if let n = parseStandalonePageNumber(right), parseStandalonePageNumber(left) == nil {
                return (n, max(0.85, lineMidX))
            }
        }
        return nil
    }

    private static func parseRomanNumeral(_ text: String) -> Int? {
        guard (1...8).contains(text.count) else { return nil }
        let upper = text.uppercased()
        guard text == upper || text == text.lowercased() else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        let chars = Array(upper)
        guard chars.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        for i in chars.indices {
            let curr = values[chars[i]]!
            let next = (i + 1 < chars.count) ? values[chars[i + 1]]! : 0
            total += curr < next ? -curr : curr
        }
        return (1...60).contains(total) ? total : nil
    }

    private static func parsePrefixedPageLabel(_ raw: String) -> (prefix: String, number: Int, fullText: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 20, !trimmed.contains(".."), !trimmed.contains(";") else { return nil }
        var digitStart = trimmed.endIndex
        while digitStart > trimmed.startIndex {
            let prev = trimmed.index(before: digitStart)
            if trimmed[prev].isASCII && trimmed[prev].isNumber {
                digitStart = prev
            } else {
                break
            }
        }
        let digits = String(trimmed[digitStart...])
        let prefix = String(trimmed[..<digitStart]).trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty, (1...3).contains(digits.count), let num = Int(digits), num > 0 else {
            return nil
        }
        return (prefix: prefix, number: num, fullText: trimmed)
    }

    // MARK: - Direction

    /// Bound on the right: the text is set vertically, and where the page numbers sit at the corners, the even
    /// ones are on the right. Guidebooks that print them by the spine, or mix in vertical text, stay left to right
    static func readsRightToLeft(_ readings: [Reading], numbers: PrintedPageNumbers?) -> Bool? {
        let vertical = readings.filter { $0.writing == .vertical }.count
        let horizontal = readings.filter { $0.writing == .horizontal }.count
        let isVertical = vertical >= 4 && vertical >= horizontal * 3

        let fitting = readings.filter { reading in
            guard let number = reading.number else { return false }
            return numbers?.number(at: reading.index) == number
        }
        let sided = fitting.filter { $0.position < 0.35 || $0.position > 0.65 }
        let evenOnRight = sided.filter { ($0.number! % 2 == 0) == ($0.position > 0.5) }.count
        let cornersSayLeft = sided.count >= 4 && (sided.count - evenOnRight) * 10 >= sided.count * 8

        if isVertical && !cornersSayLeft {
            // A spread stored left page first already shows a right-bound book correctly from left to right;
            // without page numbers to tell, assume reading order
            let inReadingOrder = (numbers?.oddIndexShift ?? 0) == 0
            return inReadingOrder
        }
        if horizontal >= 4 || cornersSayLeft {
            return false
        }
        return nil
    }

    // MARK: - Page image (OCR fallback for scanned pages without selectable text)

    struct PageImage {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let cgImage: CGImage
    }

    /// The page in grey, 700 px wide: drawn once, since a scanned page's image is slow to decode
    static func render(_ page: PDFPage) -> PageImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0 else { return nil }
        let width = 700
        let height = Int(CGFloat(width) * box.height / box.width)
        guard height > 100, height < 4000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            return context.makeImage()
        }
        return image.map { PageImage(pixels: pixels, width: width, height: height, cgImage: $0) }
    }

    /// The page number in the bottom (else top) eighth of a scanned page: outermost baseline only
    static func readNumber(in image: PageImage) -> (number: Int, position: CGFloat)? {
        let stripHeight = image.height / 8
        let strips: [(rect: CGRect, isBottom: Bool)] = [
            (CGRect(x: 0, y: image.height - stripHeight, width: image.width, height: stripHeight), true),
            (CGRect(x: 0, y: 0, width: image.width, height: stripHeight), false)
        ]
        // Image rows run from the top; Vision's normalized boundingBox has origin at bottom-left
        for (rect, isBottom) in strips {
            guard let strip = image.cgImage.cropping(to: rect) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Digits only: the Latin model is a hundred times faster than detecting the page's language
            request.recognitionLanguages = ["en-US"]
            try? VNImageRequestHandler(cgImage: strip).perform([request])
            let items: [PositionedText] = (request.results ?? []).compactMap { obs in
                guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      !text.isEmpty else { return nil }
                let b = obs.boundingBox
                let dist = isBottom ? max(0, b.minY) : max(0, 1 - b.maxY)
                return PositionedText(text: text, midX: b.midX, distanceFromOuterEdge: dist)
            }
            if let best = pickPageNumber(from: items) {
                return best
            }
        }
        return nil
    }

    /// Lines of text leave blank rows between them, columns of vertical text blank columns
    static func writingDirection(in image: PageImage) -> WritingDirection? {
        let x0 = image.width / 10, x1 = image.width * 9 / 10
        let y0 = image.height / 8, y1 = image.height * 7 / 8
        var rowInk = [Int](repeating: 0, count: y1 - y0)
        var columnInk = [Int](repeating: 0, count: x1 - x0)
        var total = 0
        for y in y0..<y1 {
            let row = y * image.width
            for x in x0..<x1 where image.pixels[row + x] < 128 {
                rowInk[y - y0] += 1
                columnInk[x - x0] += 1
                total += 1
            }
        }
        let area = (x1 - x0) * (y1 - y0)
        guard total * 100 > area else { return nil }
        let rowLimit = max(1, (x1 - x0) / 250)
        let columnLimit = max(1, (y1 - y0) / 250)
        let blankRows = Double(rowInk.filter { $0 <= rowLimit }.count) / Double(rowInk.count)
        let blankColumns = Double(columnInk.filter { $0 <= columnLimit }.count) / Double(columnInk.count)
        if blankRows - blankColumns > 0.12 { return .horizontal }
        if blankColumns - blankRows > 0.12 { return .vertical }
        return nil
    }
}
