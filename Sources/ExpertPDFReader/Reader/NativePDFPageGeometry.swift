import AppKit
import PDFKit

/// PDFKit's extracted text ranges and drawing glyph indices are different coordinate systems.
/// Map visible glyphs through point selections; never index page.string with characterBounds indices.
@MainActor
final class NativePDFPageGeometry {
    struct Glyph {
        let bounds: CGRect
        let ranges: [NSRange]
        let isWhitespace: Bool
    }
    struct Row {
        var bounds: CGRect
        var glyphs: [Glyph]
    }
    private static let cache = NSMapTable<PDFPage, NativePDFPageGeometry>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    let cropBox: CGRect
    let rows: [Row]
    let verticalSpans: [CGRect]
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
            let isPurePunctuation: Bool
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
        var rawStructuralPieces: [CGRect] = []
        var unmappedPieces: [CGRect] = []
        var tallRejectedPieces: [CGRect] = []
        var coveredLocs = IndexSet()
        if textLength > 0 {
            for index in 0..<page.numberOfCharacters {
                let box = page.characterBounds(at: index).standardized
                guard !box.isNull, !box.isInfinite, box.height > 0, box.intersects(cropBox) else { continue }
                if box.width <= 0.4 {
                    if box.height >= 2.0 && box.height < cropBox.height * 0.55 {
                        rawStructuralPieces.append(CGRect(x: box.minX, y: box.minY,
                                                          width: max(box.width, 0.5), height: box.height))
                    }
                    if box.width <= 0 { continue }
                }
                guard let selection = page.selection(from: CGPoint(x: box.minX, y: box.midY),
                                                     to: CGPoint(x: box.maxX, y: box.midY)) else {
                    if box.height < cropBox.height * 0.55 && box.width <= cropBox.width * 0.15 {
                        unmappedPieces.append(box)
                    }
                    continue
                }
                let rawRanges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
                    .filter { $0.location != NSNotFound && $0.length > 0 }
                if rawRanges.isEmpty {
                    if box.height < cropBox.height * 0.55 && box.width <= cropBox.width * 0.15 {
                        unmappedPieces.append(box)
                    }
                    continue
                }
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
                guard !keptSet.isEmpty else {
                    let hasNonWhitespaceRaw = rawRanges.contains { range in
                        let lo = max(0, range.location), hi = min(textLength, NSMaxRange(range))
                        return lo < hi && (lo..<hi).contains { loc in
                            let cInfo = info(at: loc)
                            return !cInfo.isNewline && !cInfo.isWhitespace
                        }
                    }
                    if hasNonWhitespaceRaw && box.height < cropBox.height * 0.55 {
                        tallRejectedPieces.append(box)
                    }
                    continue
                }
                for loc in keptSet { coveredLocs.insert(loc) }
                let coalesced = keptSet.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
                let nonWS = keptSet.filter { !info(at: $0).isWhitespace }
                let singleBounds = nonWS.count == 1 ? info(at: nonWS[0]).bounds : nil
                let isExtensible = !nonWS.isEmpty && nonWS.allSatisfy { info(at: $0).isExtensibleMath }
                let isBracket = !nonWS.isEmpty && nonWS.allSatisfy { info(at: $0).isBracketDelim }
                let isPunct = !nonWS.isEmpty && nonWS.allSatisfy { info(at: $0).isPunctuation }
                candidates.append(Candidate(bounds: box, ranges: coalesced, nonWhitespaceLocs: nonWS,
                                            singleNonWhitespaceBounds: singleBounds,
                                            isExtensibleMath: isExtensible, isBracketDelim: isBracket,
                                            isPurePunctuation: isPunct))
            }
        }

        // Recover text characters missed when PDFKit's drawing glyph table terminates early.
        if textLength > 0 {
            var loc = 0
            while loc < textLength {
                guard !coveredLocs.contains(loc) else { loc += 1; continue }
                let cInfo = info(at: loc)
                guard !cInfo.isNewline, !cInfo.isWhitespace,
                      !cInfo.bounds.isNull, !cInfo.bounds.isInfinite,
                      cInfo.bounds.width > 0, cInfo.bounds.height > 0,
                      cInfo.bounds.intersects(cropBox),
                      cInfo.bounds.height < cropBox.height * 0.55 else {
                    loc += 1
                    continue
                }
                let midPt = CGPoint(x: cInfo.bounds.midX, y: cInfo.bounds.midY)
                let coveredByExisting = candidates.contains {
                    !$0.isPureWhitespace
                        && $0.bounds.insetBy(dx: -1, dy: -1).contains(midPt)
                        && min($0.bounds.maxY, cInfo.bounds.maxY) > max($0.bounds.minY, cInfo.bounds.minY)
                }
                guard !coveredByExisting else {
                    loc += 1
                    continue
                }
                var endLoc = loc + 1
                var locs = [loc]
                while endLoc < textLength && !coveredLocs.contains(endLoc) {
                    let nInfo = info(at: endLoc)
                    guard !nInfo.isNewline, !nInfo.isWhitespace, nInfo.bounds == cInfo.bounds else { break }
                    locs.append(endLoc)
                    endLoc += 1
                }
                let isExtensible = locs.allSatisfy { info(at: $0).isExtensibleMath }
                let isBracket = locs.allSatisfy { info(at: $0).isBracketDelim }
                let isPunct = locs.allSatisfy { info(at: $0).isPunctuation }
                candidates.append(Candidate(
                    bounds: cInfo.bounds,
                    ranges: [NSRange(location: loc, length: endLoc - loc)],
                    nonWhitespaceLocs: locs,
                    singleNonWhitespaceBounds: locs.count == 1 ? cInfo.bounds : nil,
                    isExtensibleMath: isExtensible,
                    isBracketDelim: isBracket,
                    isPurePunctuation: isPunct
                ))
                loc = endLoc
            }
        }

        let contentHeights = candidates.filter { !$0.isPureWhitespace && !$0.isPurePunctuation }.map { $0.bounds.height }.sorted()
        let nonWSHeights = candidates.filter { !$0.isPureWhitespace }.map { $0.bounds.height }.sorted()
        let fallbackHeights = candidates.map { $0.bounds.height }.sorted()
        let heights = contentHeights.isEmpty ? (nonWSHeights.isEmpty ? fallbackHeights : nonWSHeights) : contentHeights
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

        // Also drop tall mis-attributed delimiter glyphs (e.g. a matrix right parenthesis that picked up
        // trailing punctuation or a phrase word already claimed by normal-height glyphs).
        var coveredByNormal = IndexSet()
        for (idx, candidate) in candidates.enumerated()
        where !droppedDuplicates.contains(idx) && !candidate.isPureWhitespace
           && !candidate.isExtensibleMath && !candidate.isBracketDelim
           && candidate.bounds.height <= typicalHeight * 2.0 {
            for loc in candidate.nonWhitespaceLocs { coveredByNormal.insert(loc) }
        }
        for (idx, candidate) in candidates.enumerated()
        where !droppedDuplicates.contains(idx) && !candidate.isPureWhitespace
           && !candidate.isExtensibleMath && !candidate.isBracketDelim
           && !candidate.nonWhitespaceLocs.isEmpty
           && candidate.bounds.height > typicalHeight * 2.5
           && (candidate.nonWhitespaceLocs.allSatisfy({ coveredByNormal.contains($0) })
               || (candidate.bounds.width > max(candidate.bounds.height * 1.2, typicalHeight * 4.5)
                   && candidate.nonWhitespaceLocs.contains(where: { coveredByNormal.contains($0) }))) {
            droppedDuplicates.insert(idx)
        }

        var excluded = IndexSet()
        var glyphs: [Glyph] = []
        for (idx, candidate) in candidates.enumerated() {
            let box = candidate.bounds
            if droppedDuplicates.contains(idx) {
                if !candidate.isPureWhitespace
                    && (candidate.isExtensibleMath || box.height > typicalHeight * 2.5)
                    && box.height < cropBox.height * 0.55 {
                    rawStructuralPieces.append(box)
                }
                continue
            }
            var isTallIsolatedDelimiter = false
            let narrowBracket = box.width < box.height * 0.65
                || (candidate.nonWhitespaceLocs.count == 1
                    && (candidate.singleNonWhitespaceBounds?.width ?? box.width) < box.height * 0.65)
            if candidate.isBracketDelim && box.height > typicalHeight * 2.5 && narrowBracket {
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
                if box.height < cropBox.height * 0.55 {
                    rawStructuralPieces.append(box)
                }
                if candidate.nonWhitespaceLocs.isEmpty {
                    for range in candidate.ranges { excluded.insert(integersIn: range.location..<NSMaxRange(range)) }
                } else {
                    for loc in candidate.nonWhitespaceLocs { excluded.insert(loc) }
                }
                continue
            }
            glyphs.append(Glyph(bounds: box, ranges: candidate.ranges, isWhitespace: candidate.isPureWhitespace))
        }

        var rows: [Row] = []
        var rowMaxGlyphHeight: [CGFloat] = []
        // Tall delimiters belong to equations, not to the neighboring body-text baseline.
        for glyph in glyphs.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let row = rows.indices.last(where: {
                let rh = rows[$0].bounds.height, gh = glyph.bounds.height, mg = rowMaxGlyphHeight[$0]
                return abs(rows[$0].bounds.midY - glyph.bounds.midY) <= max(typicalHeight, min(rh, gh) * 0.6)
                    && (max(mg, gh) <= typicalHeight * 3 || max(mg, gh) <= min(mg, gh) * 2.2)
            }) {
                rows[row].glyphs.append(glyph)
                rows[row].bounds = rows[row].bounds.union(glyph.bounds)
                rowMaxGlyphHeight[row] = max(rowMaxGlyphHeight[row], glyph.bounds.height)
            } else {
                rows.append(Row(bounds: glyph.bounds, glyphs: [glyph]))
                rowMaxGlyphHeight.append(glyph.bounds.height)
            }
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
                                  ranges: g.ranges, isWhitespace: g.isWhitespace)
            }
            let bounds = sorted.dropFirst().reduce(sorted[0].bounds) { $0.union($1.bounds) }
            return Row(bounds: bounds, glyphs: sorted)
        }

        let pageCropWidth = cropBox.width
        let substantiveRowHeights = clampedRows.filter { $0.bounds.width >= pageCropWidth * 0.15 }.map { $0.bounds.height }.sorted()
        let fallbackRowHeights = clampedRows.map { $0.bounds.height }.sorted()
        let rowHeightBasis = substantiveRowHeights.isEmpty ? fallbackRowHeights : substantiveRowHeights
        let rowHeight = rowHeightBasis.isEmpty ? max(1, typicalHeight * 1.5) : max(1, rowHeightBasis[rowHeightBasis.count / 2])

        for piece in unmappedPieces where piece.width <= rowHeight * 1.5 {
            rawStructuralPieces.append(piece)
        }
        for piece in tallRejectedPieces where piece.height >= rowHeight * 1.55 && piece.height < cropBox.height * 0.55 {
            rawStructuralPieces.append(piece)
        }

        // Clamp horizontally stretched tall delimiter boxes toward whichever neighbor glyph holds their visible edge.
        let nonWhitespaceGlyphs = clampedRows.flatMap { row in
            row.glyphs.filter { g in
                g.ranges.contains { r in
                    (r.location..<min(textLength, NSMaxRange(r))).contains { !info(at: $0).isWhitespace }
                }
            }
        }
        var clampedPieces: [CGRect] = []
        for piece in rawStructuralPieces {
            guard piece.width > max(rowHeight * 1.5, piece.height * 0.45) && piece.height >= rowHeight * 1.55 else {
                clampedPieces.append(piece)
                continue
            }
            let overlapping = nonWhitespaceGlyphs.filter {
                min($0.bounds.maxY, piece.maxY) > max($0.bounds.minY, piece.minY)
            }
            let clampedW = min(piece.width, rowHeight * 0.85)
            let inside = overlapping.filter {
                max($0.bounds.minX, piece.minX) < min($0.bounds.maxX, piece.maxX)
            }
            let anchorRight: Bool
            if !inside.isEmpty {
                let leftMargin = (inside.map(\.bounds.minX).min() ?? piece.minX) - piece.minX
                let rightMargin = piece.maxX - (inside.map(\.bounds.maxX).max() ?? piece.maxX)
                anchorRight = rightMargin < leftMargin
            } else {
                let leftMaxX = overlapping.filter { $0.bounds.maxX <= piece.minX + 1 }.map(\.bounds.maxX).max()
                let rightMinX = overlapping.filter { $0.bounds.minX >= piece.maxX - 1 }.map(\.bounds.minX).min()
                let leftGap = leftMaxX.map { piece.minX - $0 } ?? .infinity
                let rightGap = rightMinX.map { $0 - piece.maxX } ?? .infinity
                guard min(leftGap, rightGap) <= rowHeight * 4 else { continue }
                anchorRight = rightGap < leftGap
            }
            let clampedX = anchorRight ? (piece.maxX - clampedW) : piece.minX
            clampedPieces.append(CGRect(x: clampedX, y: piece.minY, width: clampedW, height: piece.height))
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
        self.verticalSpans = Self.coalesceVerticalSpans(clampedPieces, rowHeight: rowHeight, cropBox: cropBox, rows: clampedRows)
    }

    /// Coalesce vertically stacked delimiter or rule fragments into continuous vertical spans.
    static func coalesceVerticalSpans(
        _ pieces: [CGRect],
        rowHeight: CGFloat,
        cropBox: CGRect,
        rows: [Row]
    ) -> [CGRect] {
        guard !pieces.isEmpty else { return [] }
        func canMerge(_ a: CGRect, _ b: CGRect) -> Bool {
            let vGap = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
            let maxVGap = min(a.height, b.height) >= rowHeight * 2.2 ? rowHeight * 0.12 : rowHeight * 0.45
            guard vGap <= maxVGap else { return false }
            let hGap = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
            guard hGap <= rowHeight * 0.35 else { return false }
            let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            let sideBySide = (b.minX >= a.maxX - 0.5 || a.minX >= b.maxX - 0.5)
                && vOverlap >= min(a.height, b.height) * 0.5
            let u = a.union(b)
            return !sideBySide
                && abs(a.midX - b.midX) <= rowHeight * 0.75
                && u.width <= max(rowHeight * 1.5, u.height * 0.45)
        }
        var spans = pieces
        var merged = true
        while merged {
            merged = false
            spans.sort { a, b in
                if a.maxY != b.maxY { return a.maxY > b.maxY }
                return a.minX < b.minX
            }
            var next: [CGRect] = []
            var used = Array(repeating: false, count: spans.count)
            for i in spans.indices where !used[i] {
                var current = spans[i]
                used[i] = true
                var grew = true
                while grew {
                    grew = false
                    for j in spans.indices where !used[j] && canMerge(current, spans[j]) {
                        current = current.union(spans[j])
                        used[j] = true
                        grew = true
                        merged = true
                    }
                }
                next.append(current)
            }
            spans = next
        }
        return spans.filter { span in
            guard span.height >= rowHeight * 1.55,
                  span.height < cropBox.height * 0.55,
                  span.width <= max(rowHeight * 1.5, span.height * 0.45) else { return false }
            let vLo = span.minY - rowHeight * 0.25, vHi = span.maxY + rowHeight * 0.25
            return rows.contains { row in
                row.glyphs.contains { g in
                    g.bounds.maxY >= vLo && g.bounds.minY <= vHi
                        && max(0, max(g.bounds.minX - span.maxX, span.minX - g.bounds.maxX)) <= rowHeight * 4
                }
            }
        }
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
