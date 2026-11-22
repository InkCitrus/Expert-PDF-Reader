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
        var glyphs: [Glyph] = []
        for index in 0..<page.numberOfCharacters {
            let box = page.characterBounds(at: index)
            guard !box.isNull, !box.isInfinite, box.width > 0, box.height > 0,
                  box.intersects(cropBox),
                  let selection = page.selection(from: CGPoint(x: box.minX, y: box.midY),
                                                 to: CGPoint(x: box.maxX, y: box.midY)) else { continue }
            var ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
                .filter { $0.location != NSNotFound && $0.length > 0 }
            // Point selections snap to caret stops. Preserve adjacent punctuation whose advance
            // overlaps the same visible glyph, rather than silently dropping commas or ligatures.
            let punctuation = CharacterSet.punctuationCharacters.union(.whitespaces)
            for range in ranges {
                for index in max(0, range.location - 1)...min(page.numberOfCharacters - 1, NSMaxRange(range)) {
                    guard let neighbor = page.selection(for: NSRange(location: index, length: 1)),
                          let text = neighbor.string, !text.isEmpty,
                          text.unicodeScalars.allSatisfy(punctuation.contains),
                          neighbor.bounds(for: page).intersects(box) else { continue }
                    ranges.append(NSRange(location: index, length: 1))
                }
            }
            if !ranges.isEmpty { glyphs.append(Glyph(bounds: box, ranges: ranges)) }
        }
        let heights = glyphs.map { $0.bounds.height }.sorted()
        let typicalHeight = heights.isEmpty ? 1 : heights[heights.count / 2]
        var rows: [Row] = []
        // Tall delimiters belong to equations, not to the neighboring body-text baseline.
        for glyph in glyphs.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let row = rows.indices.last(where: {
                abs(rows[$0].bounds.midY - glyph.bounds.midY) <= typicalHeight
                    && max(rows[$0].bounds.height, glyph.bounds.height) <= typicalHeight * 3
            }) {
                rows[row].glyphs.append(glyph)
                rows[row].bounds = rows[row].bounds.union(glyph.bounds)
            } else { rows.append(Row(bounds: glyph.bounds, glyphs: [glyph])) }
        }
        let nativeLines = page.selection(for: cropBox)?.selectionsByLine() ?? []
        let oversized = nativeLines.contains { $0.bounds(for: page).height > typicalHeight * 4 }
        let interleaved = rows.contains { row in
            let order = row.glyphs.sorted { $0.bounds.minX < $1.bounds.minX }.compactMap { $0.ranges.first?.location }
            return zip(order, order.dropFirst()).contains { $0 > $1 }
        }
        self.needsDirectSelection = oversized || interleaved
        self.rows = rows.sorted { $0.bounds.midY > $1.bounds.midY }.map {
            Row(bounds: $0.bounds, glyphs: $0.glyphs.sorted { $0.bounds.minX < $1.bounds.minX })
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
