import AppKit
import PDFKit

/// PDFKit's extracted text ranges and drawing glyph indices are different coordinate systems.
/// Map visible glyphs through point selections; never index page.string with characterBounds indices.
@MainActor
final class NativePDFPageGeometry {
    struct Glyph {
        let bounds: CGRect
        let ranges: [NSRange]
    }
    struct Row {
        var bounds: CGRect
        var glyphs: [Glyph]
    }
    private static let cache = NSMapTable<PDFPage, NativePDFPageGeometry>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    let cropBox: CGRect
    let rows: [Row]
    let excludedIndices: IndexSet
    let needsDirectSelection: Bool

    static func geometry(for page: PDFPage) -> NativePDFPageGeometry {
        let box = page.bounds(for: .cropBox)
        if let saved = cache.object(forKey: page), saved.cropBox == box { return saved }
        let result = NativePDFPageGeometry(page: page)
        cache.setObject(result, forKey: page)
        return result
    }

    private init(page: PDFPage) {
        cropBox = page.bounds(for: .cropBox)
        let pageText = (page.string ?? "") as NSString
        let textLength = pageText.length

        struct CharInfo {
            let bounds: CGRect
            let isWhitespace: Bool
            let isNewline: Bool
            let isNonBase: Bool
            let isPunctuation: Bool
            let isExtensibleMath: Bool
            let isBracketDelim: Bool
        }
        struct Candidate {
            var bounds: CGRect
            let ranges: [NSRange]
            let nonWhitespaceLocs: [Int]
            let singleNonWhitespaceBounds: CGRect?
            let isExtensibleMath: Bool
            let isBracketDelim: Bool
            var isPureWhitespace: Bool { nonWhitespaceLocs.isEmpty }
        }

        let punctuation = CharacterSet.punctuationCharacters.union(.whitespaces)
        let bracketSet = CharacterSet(charactersIn: "()[]{}|‖⟨⟩⌈⌉⌊⌋")
        var charCache: [Int: CharInfo] = [:]
        func info(at loc: Int) -> CharInfo {
            if let cached = charCache[loc] { return cached }
            let unit = pageText.character(at: loc)
            let scalars: [UnicodeScalar]
            if let scalar = UnicodeScalar(unit) {
                scalars = [scalar]
            } else {
                let composed = pageText.rangeOfComposedCharacterSequence(at: loc)
                scalars = Array(pageText.substring(with: composed).unicodeScalars)
            }
            let isNewline = unit == 0x000A || unit == 0x000D || (!scalars.isEmpty && scalars.allSatisfy(CharacterSet.newlines.contains))
            let isWhitespace = !scalars.isEmpty && scalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
            let isNonBase = !scalars.isEmpty && scalars.allSatisfy(CharacterSet.nonBaseCharacters.contains)
            let isPunct = !scalars.isEmpty && scalars.allSatisfy(punctuation.contains)
            let isExtensible = !scalars.isEmpty && scalars.allSatisfy {
                (0x239B...0x23B3).contains($0.value)
                    || (0x2320...0x2321).contains($0.value)
                    || (0xF8E5...0xF8FE).contains($0.value)
            }
            let isBracket = !scalars.isEmpty && scalars.allSatisfy(bracketSet.contains)
            let bounds = isNewline ? .null : (page.selection(for: NSRange(location: loc, length: 1))?.bounds(for: page) ?? .null)
            let entry = CharInfo(bounds: bounds, isWhitespace: isWhitespace, isNewline: isNewline,
                                 isNonBase: isNonBase, isPunctuation: isPunct,
                                 isExtensibleMath: isExtensible, isBracketDelim: isBracket)
            charCache[loc] = entry
            return entry
        }

        var candidates: [Candidate] = []
        if textLength > 0 {
            for index in 0..<page.numberOfCharacters {
                let box = page.characterBounds(at: index)
                guard !box.isNull, !box.isInfinite, box.width > 0, box.height > 0,
                      box.intersects(cropBox),
                      let selection = page.selection(from: CGPoint(x: box.minX, y: box.midY),
                                                     to: CGPoint(x: box.maxX, y: box.midY)) else { continue }
                let rawRanges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
                    .filter { $0.location != NSNotFound && $0.length > 0 }
                var keptSet = IndexSet()
                var validatedBases: [(Int, CharInfo)] = []
                for range in rawRanges {
                    let lo = max(0, range.location), hi = min(textLength, NSMaxRange(range))
                    guard lo < hi else { continue }
                    for loc in lo..<hi {
                        let cInfo = info(at: loc)
                        guard !cInfo.isNewline, !cInfo.bounds.isNull, !cInfo.bounds.isInfinite,
                              cInfo.bounds.width > 0 || cInfo.bounds.height > 0,
                              cInfo.bounds.insetBy(dx: -0.5, dy: 0).intersects(box) else { continue }
                        if keptSet.insert(loc).inserted {
                            validatedBases.append((loc, cInfo))
                        }
                    }
                }
                // Point selections snap to caret stops. Preserve adjacent punctuation or combining
                // marks (e.g. U+0338 in ̸=) whose bounds belong to the same visible glyph.
                for (loc, baseInfo) in validatedBases {
                    for neighbor in max(0, loc - 1)...min(textLength - 1, loc + 1) where !keptSet.contains(neighbor) {
                        let nInfo = info(at: neighbor)
                        guard !nInfo.isNewline, !nInfo.bounds.isNull, !nInfo.bounds.isInfinite else { continue }
                        if nInfo.isNonBase {
                            let nearBase = nInfo.bounds.insetBy(dx: -1, dy: -1).intersects(baseInfo.bounds)
                            let nearGlyph = nInfo.bounds.insetBy(dx: -max(box.height * 2, 4), dy: -1).intersects(box)
                            if nearBase || nearGlyph { keptSet.insert(neighbor) }
                        } else if nInfo.isPunctuation && nInfo.bounds.intersects(box) {
                            keptSet.insert(neighbor)
                        }
                    }
                }
                guard !keptSet.isEmpty else { continue }
                let coalesced = keptSet.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
                let nonWS = keptSet.filter { !info(at: $0).isWhitespace }
                let singleBounds = nonWS.count == 1 ? info(at: nonWS[0]).bounds : nil
                let isExtensible = !nonWS.isEmpty && nonWS.allSatisfy { info(at: $0).isExtensibleMath }
                let isBracket = !nonWS.isEmpty && nonWS.allSatisfy { info(at: $0).isBracketDelim }
                candidates.append(Candidate(bounds: box, ranges: coalesced, nonWhitespaceLocs: nonWS,
                                            singleNonWhitespaceBounds: singleBounds,
                                            isExtensibleMath: isExtensible, isBracketDelim: isBracket))
            }
        }

        let nonWSHeights = candidates.filter { !$0.isPureWhitespace }.map { $0.bounds.height }.sorted()
        let fallbackHeights = candidates.map { $0.bounds.height }.sorted()
        let heights = nonWSHeights.isEmpty ? fallbackHeights : nonWSHeights
        let typicalHeight = heights.isEmpty ? 1 : heights[heights.count / 2]

        // Drop phantom wide/tall pure-whitespace boxes emitted around matrix gaps or line breaks.
        candidates.removeAll { candidate in
            candidate.isPureWhitespace && (candidate.bounds.width > max(candidate.bounds.height * 2, typicalHeight * 2)
                                           || candidate.bounds.height > typicalHeight * 2.5)
        }

        // Deduplicate glyphs claiming the exact same single non-whitespace native index,
        // keeping the one whose bounds match that character's single-character stop best.
        var bestBySingleLoc: [Int: Int] = [:]
        var droppedDuplicates = IndexSet()
        for (idx, candidate) in candidates.enumerated() where candidate.nonWhitespaceLocs.count == 1 {
            let loc = candidate.nonWhitespaceLocs[0]
            if let existing = bestBySingleLoc[loc], let cb = candidate.singleNonWhitespaceBounds {
                let old = candidates[existing]
                let oldScore = abs(old.bounds.minX - cb.minX) + abs(old.bounds.height - typicalHeight) * 2
                let newScore = abs(candidate.bounds.minX - cb.minX) + abs(candidate.bounds.height - typicalHeight) * 2
                if newScore < oldScore {
                    droppedDuplicates.insert(existing)
                    bestBySingleLoc[loc] = idx
                } else {
                    droppedDuplicates.insert(idx)
                }
            } else {
                bestBySingleLoc[loc] = idx
            }
        }

        var excluded = IndexSet()
        var glyphs: [Glyph] = []
        for (idx, candidate) in candidates.enumerated() where !droppedDuplicates.contains(idx) {
            let box = candidate.bounds
            var isTallIsolatedDelimiter = false
            if candidate.isBracketDelim && box.height > typicalHeight * 2.5 && box.width < box.height * 0.65 {
                let hasLargeNeighbor = candidates.indices.contains { otherIdx in
                    guard !droppedDuplicates.contains(otherIdx) else { return false }
                    let other = candidates[otherIdx]
                    guard !other.isPureWhitespace, !other.isExtensibleMath, !other.isBracketDelim else { return false }
                    let ob = other.bounds
                    guard ob.height >= box.height * 0.72,
                          min(ob.maxY, box.maxY) > max(ob.minY, box.minY) else { return false }
                    let hGap = max(0, max(ob.minX - box.maxX, box.minX - ob.maxX))
                    return hGap <= box.height * 1.5
                }
                isTallIsolatedDelimiter = !hasLargeNeighbor
            }
            if candidate.isExtensibleMath || isTallIsolatedDelimiter {
                if candidate.nonWhitespaceLocs.isEmpty {
                    for range in candidate.ranges { excluded.insert(integersIn: range.location..<NSMaxRange(range)) }
                } else {
                    for loc in candidate.nonWhitespaceLocs { excluded.insert(loc) }
                }
                continue
            }
            glyphs.append(Glyph(bounds: box, ranges: candidate.ranges))
        }

        var rows: [Row] = []
        // Tall delimiters belong to equations, not to the neighboring body-text baseline.
        for glyph in glyphs.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let row = rows.indices.last(where: {
                let rh = rows[$0].bounds.height, gh = glyph.bounds.height
                return abs(rows[$0].bounds.midY - glyph.bounds.midY) <= max(typicalHeight, min(rh, gh) * 0.6)
                    && (max(rh, gh) <= typicalHeight * 3 || max(rh, gh) <= min(rh, gh) * 2.2)
            }) {
                rows[row].glyphs.append(glyph)
                rows[row].bounds = rows[row].bounds.union(glyph.bounds)
            } else { rows.append(Row(bounds: glyph.bounds, glyphs: [glyph])) }
        }

        // Clamp stretched single-glyph advance boxes (e.g. a colon before a displayed equation)
        // toward whichever horizontal neighbor the visible glyph actually sits beside.
        let clampedRows: [Row] = rows.sorted { $0.bounds.midY > $1.bounds.midY }.map { row in
            var sorted = row.glyphs.sorted { $0.bounds.minX < $1.bounds.minX }
            for i in sorted.indices {
                let g = sorted[i]
                let nonWSCount = g.ranges.reduce(0) { acc, r in
                    acc + (r.location..<min(textLength, NSMaxRange(r))).filter { !info(at: $0).isWhitespace }.count
                }
                guard nonWSCount == 1, g.bounds.width > max(g.bounds.height * 4, typicalHeight * 4.5) else { continue }
                let clampedWidth = min(g.bounds.width, max(g.bounds.height, typicalHeight))
                let prevMaxX = sorted[..<i].reversed().first { prev in
                    prev.ranges.contains { r in (r.location..<min(textLength, NSMaxRange(r))).contains { !info(at: $0).isWhitespace } }
                }?.bounds.maxX
                let nextMinX = sorted[(i + 1)...].first { next in
                    next.ranges.contains { r in (r.location..<min(textLength, NSMaxRange(r))).contains { !info(at: $0).isWhitespace } }
                }?.bounds.minX
                let leftGap = prevMaxX.map { g.bounds.minX - $0 } ?? .infinity
                let rightGap = nextMinX.map { $0 - g.bounds.maxX } ?? .infinity
                let anchorRight = rightGap < typicalHeight * 2.5 && leftGap > rightGap * 2
                let clampedX = anchorRight ? (g.bounds.maxX - clampedWidth) : g.bounds.minX
                sorted[i] = Glyph(bounds: CGRect(x: clampedX, y: g.bounds.minY, width: clampedWidth, height: g.bounds.height),
                                  ranges: g.ranges)
            }
            let bounds = sorted.dropFirst().reduce(sorted[0].bounds) { $0.union($1.bounds) }
            return Row(bounds: bounds, glyphs: sorted)
        }

        let nativeLines = page.selection(for: cropBox)?.selectionsByLine() ?? []
        let oversized = nativeLines.contains { $0.bounds(for: page).height > typicalHeight * 4 }
        let interleaved = clampedRows.contains { row in
            let order = row.glyphs.sorted { $0.bounds.minX < $1.bounds.minX }.compactMap { $0.ranges.first?.location }
            return zip(order, order.dropFirst()).contains { $0 > $1 }
        }
        self.excludedIndices = excluded
        self.needsDirectSelection = oversized || interleaved || !excluded.isEmpty
        self.rows = clampedRows
    }

    func nearestRow(to point: CGPoint) -> Int? {
        rows.indices.min {
            func distance(_ box: CGRect) -> CGFloat {
                let dy = max(0, max(box.minY - point.y, point.y - box.maxY))
                let dx = max(0, max(box.minX - point.x, point.x - box.maxX))
                return dy * dy + dx * dx
            }
            return distance(rows[$0].bounds) < distance(rows[$1].bounds)
        }
    }

    /// Row labels must come from the mapped native ranges. Selecting the row by its two endpoints
    /// can jump to another baseline at whitespace and reintroduce unrelated text into accessibility.
    func text(for row: Row, on page: PDFPage) -> String {
        var seen = IndexSet(), runs: [(Range<Int>, CGRect)] = []
        for glyph in row.glyphs {
            for range in glyph.ranges {
                let fresh = IndexSet(integersIn: range.location..<NSMaxRange(range)).subtracting(seen)
                for part in fresh.rangeView {
                    if let previous = runs.last, previous.0.upperBound == part.lowerBound {
                        runs[runs.count - 1] = (previous.0.lowerBound..<part.upperBound, previous.1.union(glyph.bounds))
                    } else { runs.append((part, glyph.bounds)) }
                }
                seen.formUnion(fresh)
            }
        }
        var result = "", previous: CGRect?
        for (range, bounds) in runs {
            guard let text = page.selection(for: NSRange(location: range.lowerBound, length: range.count))?.string else { continue }
            let clean = text.trimmingCharacters(in: .newlines)
            if let previous, let last = result.last, !last.isWhitespace,
               let first = clean.first, !first.isWhitespace,
               bounds.minX - previous.maxX > min(bounds.height, previous.height) * 0.25 { result += " " }
            result += clean
            previous = bounds
        }
        return PDFTextCleanup.normalize(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
