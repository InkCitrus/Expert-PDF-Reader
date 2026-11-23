import AppKit
import PDFKit
import ObjectiveC

/// Screenshot pickers need the bounds of visible paragraphs, figures, tables, and lines rather than
/// PDFKit's font-run rectangles. Build a small, stable tree for visible native-text pages; normal
/// PDF links and scrollers remain available.
@MainActor
final class PDFContentAccessibility {
    private weak var pdfView: PDFView?
    private let pages = NSMapTable<PDFPage, GeometryElement>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    init(pdfView: PDFView) { self.pdfView = pdfView }

    private static let readerWindows = NSHashTable<NSWindow>.weakObjects()
    private static var routedWindowClasses: Set<ObjectIdentifier> = []

    static func routeHitTesting(in window: NSWindow) {
        readerWindows.add(window)
        let windowClass = type(of: window)
        let classID = ObjectIdentifier(windowClass)
        guard !routedWindowClasses.contains(classID) else { return }
        let selector = #selector(NSWindow.accessibilityHitTest(_:))
        guard let method = class_getInstanceMethod(windowClass, selector),
              let encoding = method_getTypeEncoding(method) else { return }
        typealias HitTest = @convention(c) (AnyObject, Selector, NSPoint) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: HitTest.self)
        // SwiftUI owns the primary NSWindow. Wrap its public AX method so AppKit can keep the
        // real PDFKit view under the pointer for every ordinary mouse event.
        let replacement: @convention(block) (NSWindow, NSPoint) -> AnyObject? = { window, point in
            let hit = original(window, selector, point)
            guard Thread.isMainThread else { return hit }
            return MainActor.assumeIsolated {
                guard readerWindows.contains(window) else { return hit }
                return preciseHit(from: hit, at: point) as AnyObject? ?? hit
            }
        }
        class_replaceMethod(windowClass, selector, imp_implementationWithBlock(replacement), encoding)
        routedWindowClasses.insert(classID)
    }

    /// PDFKit's document view can answer a window query before PDFView's override is consulted.
    /// Route only that public accessibility query; the actual view and responder hierarchy stay native.
    private static func preciseHit(from hit: AnyObject?, at point: NSPoint) -> Any? {
        var candidate = hit
        var visited = Set<ObjectIdentifier>()
        while let object = candidate, visited.insert(ObjectIdentifier(object)).inserted {
            if let element = object as? GeometryElement { return element.deepestHit(at: point) }
            if let view = object as? NSView {
                var ancestor: NSView? = view
                while let current = ancestor {
                    if current is NSScroller { return nil }
                    if let reader = current as? ThemedPDFView { return reader.preciseAccessibilityHit(at: point) }
                    ancestor = current.superview
                }
                return nil
            }
            let parent = #selector(NSView.accessibilityParent)
            guard let element = object as? NSObject, element.responds(to: parent) else { return nil }
            candidate = element.perform(parent)?.takeUnretainedValue()
        }
        return nil
    }

    func children() -> [Any]? {
        guard let view = pdfView, let document = view.document, !document.isLocked,
              !view.visiblePages.isEmpty else { return nil }
        var result: [Any] = []
        for page in view.visiblePages.sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
            guard page.rotation % 360 == 0, !PDFSelectionVisibility.requiresVisualSelection(on: page) else { continue }
            let geometry = NativePDFPageGeometry.geometry(for: page)
            guard !geometry.rows.isEmpty else { continue }
            let element: GeometryElement
            if let saved = pages.object(forKey: page), saved.pageRect == geometry.cropBox { element = saved }
            else {
                element = buildPage(page, geometry: geometry, in: view, index: document.index(for: page))
                pages.setObject(element, forKey: page)
            }
            result.append(element)
        }
        guard !result.isEmpty else { return nil }
        if let scroll = view.subviews.compactMap({ $0 as? NSScrollView }).first {
            result.append(contentsOf: [scroll.verticalScroller, scroll.horizontalScroller].compactMap { $0 }.filter { !$0.isHidden })
        }
        return result
    }

    func hitTest(_ point: NSPoint) -> GeometryElement? {
        guard let roots = children() else { return nil }
        return roots.lazy.compactMap { ($0 as? GeometryElement)?.deepestHit(at: point) }.first
    }

    nonisolated private static func glyphScale(for glyphs: [NativePDFPageGeometry.Glyph], fallback: CGFloat) -> CGFloat {
        let heights = glyphs.filter { !$0.isWhitespace }.map(\.bounds.height).sorted()
        guard !heights.isEmpty else { return fallback }
        return heights[Int(Double(heights.count - 1) * 0.75)]
    }

    private struct LineMetrics {
        let cropWidth: CGFloat
        let typicalHeight: CGFloat
        let typicalFontScale: CGFloat
        let typicalStep: CGFloat

        init(rows: [NativePDFPageGeometry.Row], cropBox: CGRect) {
            let cw = max(1, cropBox.width)
            let wideRows = rows.filter { $0.bounds.width >= cw * 0.35 }
            let substantiveRows = rows.filter { $0.bounds.width >= cw * 0.15 }
            let scaleBasis = wideRows.isEmpty ? (substantiveRows.isEmpty ? rows : substantiveRows) : wideRows
            let heights = scaleBasis.map(\.bounds.height).sorted()
            let th = heights.isEmpty ? 10 : max(1, heights[heights.count / 2])
            let fontScales = scaleBasis.map { PDFContentAccessibility.glyphScale(for: $0.glyphs, fallback: $0.bounds.height) }.sorted()
            let tfs = fontScales.isEmpty ? th : max(1, fontScales[fontScales.count / 2])

            let stepBasis = (substantiveRows.isEmpty ? rows : substantiveRows).map(\.bounds)
            let ordered = stepBasis.sorted { $0.midY > $1.midY }
            var steps: [CGFloat] = []
            for i in ordered.indices {
                let u = ordered[i]
                for j in (i + 1)..<ordered.count {
                    let l = ordered[j]
                    let dy = u.midY - l.midY
                    if dy > th * 2.8 { break }
                    guard dy >= th * 0.85,
                          max(u.minX, l.minX) < min(u.maxX, l.maxX) else { continue }
                    steps.append(dy)
                    break
                }
            }
            steps.sort()
            self.cropWidth = cw
            self.typicalHeight = th
            self.typicalFontScale = tfs
            self.typicalStep = steps.isEmpty
                ? th * 1.45
                : steps[Int(Double(steps.count - 1) * 0.4)]
        }
    }

    private struct RowSlice {
        let row: NativePDFPageGeometry.Row
        let bounds: CGRect
        let text: String
    }

    private struct PairedEnclosure {
        let bounds: CGRect
        let isMultiRow: Bool
    }

    private struct BlockItem {
        let element: GeometryElement
        let isCompound: Bool
        let fontScale: CGFloat
        var pageRect: CGRect { element.pageRect }
    }

    private func buildPage(_ page: PDFPage, geometry: NativePDFPageGeometry, in view: PDFView, index: Int) -> GeometryElement {
        let root = GeometryElement(page: page, rect: geometry.cropBox, view: view, role: .group, label: L10n.pageTitle(String(index + 1)))
        root.setAccessibilityParent(view)
        let metrics = LineMetrics(rows: geometry.rows, cropBox: geometry.cropBox)
        let layout = PDFFramedRegions.layout(on: page, geometry: geometry)
        let regions = layout.regions
        let vectorSpans = NativePDFPageGeometry.coalesceVerticalSpans(
            layout.freeVerticalRules,
            rowHeight: metrics.typicalHeight,
            cropBox: geometry.cropBox,
            rows: geometry.rows
        )
        func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        let parents: [Int?] = regions.indices.map { i in
            let inner = regions[i].bounds
            return regions.indices.filter { j in
                j != i && regions[j].kind != .figure && area(regions[j].bounds) > area(inner)
                    && regions[j].bounds.insetBy(dx: -1, dy: -1).contains(inner)
            }.min { area(regions[$0].bounds) < area(regions[$1].bounds) }
        }
        var regionRows = regions.map { _ in [RowSlice]() }
        var regionTableLines = regions.map { _ in [GeometryElement]() }
        var figureLabels = regions.map { _ in [String]() }
        var plainRows: [RowSlice] = []
        for row in geometry.rows {
            for (frame, subRow) in Self.split(row, across: regions.map(\.bounds)) {
                let clean = geometry.text(for: subRow, on: page)
                guard !clean.isEmpty else { continue }
                if let frame, regions[frame].kind == .figure {
                    figureLabels[frame].append(clean)
                    continue
                }
                let bounds = frame.map { subRow.bounds.intersection(regions[$0].bounds) } ?? subRow.bounds
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                if let frame {
                    if regions[frame].kind == .table {
                        let line = GeometryElement(page: page, rect: bounds, view: view, role: .staticText, label: nil)
                        line.setAccessibilityValue(clean)
                        regionTableLines[frame].append(line)
                    } else {
                        regionRows[frame].append(RowSlice(row: subRow, bounds: bounds, text: clean))
                    }
                } else {
                    plainRows.append(RowSlice(row: subRow, bounds: bounds, text: clean))
                }
            }
        }
        var childRegions = regions.map { _ in [GeometryElement]() }
        var topRegions: [GeometryElement] = []
        for i in regions.indices.sorted(by: { area(regions[$0].bounds) < area(regions[$1].bounds) }) {
            let item = regions[i]
            let built: GeometryElement?
            if item.kind == .figure {
                let label = figureLabels[i].isEmpty ? nil : figureLabels[i].joined(separator: " ")
                built = GeometryElement(page: page, rect: item.bounds, view: view, role: .image, label: label)
            } else if item.kind == .table {
                let children = (regionTableLines[i] + childRegions[i]).sorted {
                    if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                    return $0.pageRect.maxY > $1.pageRect.maxY
                }
                built = children.isEmpty ? nil : region(with: children, bounds: item.bounds, on: page, in: view,
                                                        roleDescription: L10n.tr("表格", "Table"))
            } else {
                let groupedLines = partitionBlocks(
                    for: regionRows[i],
                    in: item.bounds,
                    obstacles: childRegions[i].map(\.pageRect),
                    geometry: geometry,
                    vectorSpans: vectorSpans,
                    metrics: metrics,
                    on: page,
                    in: view
                )
                let children = (groupedLines + childRegions[i]).sorted {
                    if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                    return $0.pageRect.maxY > $1.pageRect.maxY
                }
                built = children.isEmpty ? nil : region(with: children, bounds: item.bounds, on: page, in: view,
                                                        roleDescription: L10n.tr("内容块", "Section"))
            }
            guard let built else { continue }
            if let parent = parents[i] { childRegions[parent].append(built) }
            else { topRegions.append(built) }
        }
        let groupedPlain = partitionBlocks(
            for: plainRows,
            in: geometry.cropBox,
            obstacles: topRegions.map(\.pageRect),
            geometry: geometry,
            vectorSpans: vectorSpans,
            metrics: metrics,
            on: page,
            in: view
        )
        var elements = groupedPlain + topRegions
        if !regions.isEmpty || groupedPlain.count > 1 {
            elements.sort {
                if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                return $0.pageRect.maxY > $1.pageRect.maxY
            }
        }
        for annotation in page.annotations where annotation.action != nil {
            let link = GeometryElement(page: page, rect: annotation.bounds, view: view, role: .link,
                label: annotation.contents ?? (annotation.action as? PDFActionURL)?.url?.absoluteString)
            link.annotation = annotation
            elements.append(link)
        }
        root.allChildren = elements
        for element in elements { element.setAccessibilityParent(root) }
        return root
    }

    /// A physical row can straddle a box edge, for example when a title shares a baseline
    /// with a margin note or sits inside a nested sub-region. Assign each glyph to its smallest enclosing box.
    private static func split(_ row: NativePDFPageGeometry.Row, across boxes: [CGRect])
        -> [(Int?, NativePDFPageGeometry.Row)] {
        guard !boxes.isEmpty else { return [(nil, row)] }
        func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        var runs: [(frame: Int?, glyphs: [NativePDFPageGeometry.Glyph])] = []
        for glyph in row.glyphs {
            let center = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
            let frame = boxes.indices
                .filter { boxes[$0].contains(center) }
                .min { area(boxes[$0]) < area(boxes[$1]) }
            if let last = runs.last, last.frame == frame {
                runs[runs.count - 1].glyphs.append(glyph)
            } else {
                runs.append((frame, [glyph]))
            }
        }
        if runs.count == 1, let run = runs.first { return [(run.frame, row)] }
        return runs.map { frame, glyphs in
            let bounds = glyphs.reduce(CGRect.null) { $0.union($1.bounds) }
            return (frame, .init(bounds: bounds, glyphs: glyphs))
        }
    }

    /// Split a free glyph run whenever adjacent glyphs are separated by a wide horizontal gap.
    private static func splitHorizontalGaps(_ row: NativePDFPageGeometry.Row, gapThreshold: CGFloat)
        -> [NativePDFPageGeometry.Row] {
        guard row.glyphs.count > 1 else { return [row] }
        let sorted = row.glyphs.sorted { $0.bounds.minX < $1.bounds.minX }
        var groups: [[NativePDFPageGeometry.Glyph]] = [[sorted[0]]]
        var curMaxX = sorted[0].bounds.maxX
        for glyph in sorted.dropFirst() {
            if glyph.bounds.minX - curMaxX > gapThreshold {
                groups.append([glyph])
            } else {
                groups[groups.count - 1].append(glyph)
            }
            curMaxX = max(curMaxX, glyph.bounds.maxX)
        }
        if groups.count == 1 { return [row] }
        return groups.map { glyphs in
            let bounds = glyphs.reduce(CGRect.null) { $0.union($1.bounds) }
            return .init(bounds: bounds, glyphs: glyphs)
        }
    }

    /// Split a free glyph run wherever an intervening vertically overlapping obstacle sits between
    /// adjacent glyphs, preventing operator text on either side of a matrix from spanning across it.
    private static func split(_ row: NativePDFPageGeometry.Row, around obstacles: [CGRect])
        -> [NativePDFPageGeometry.Row] {
        guard row.glyphs.count > 1, !obstacles.isEmpty else { return [row] }
        let blocking = obstacles.filter {
            min($0.maxY, row.bounds.maxY) > max($0.minY, row.bounds.minY)
                || (row.bounds.midY >= $0.minY && row.bounds.midY <= $0.maxY)
        }
        guard !blocking.isEmpty else { return [row] }
        let sorted = row.glyphs.sorted { $0.bounds.minX < $1.bounds.minX }
        var groups: [[NativePDFPageGeometry.Glyph]] = [[sorted[0]]]
        var curMaxX = sorted[0].bounds.maxX
        for glyph in sorted.dropFirst() {
            let crossesObstacle = blocking.contains { obs in
                obs.midX > curMaxX - 1 && obs.midX < glyph.bounds.minX + 1
            }
            if crossesObstacle {
                groups.append([glyph])
            } else {
                groups[groups.count - 1].append(glyph)
            }
            curMaxX = max(curMaxX, glyph.bounds.maxX)
        }
        if groups.count == 1 { return [row] }
        return groups.map { glyphs in
            let bounds = glyphs.reduce(CGRect.null) { $0.union($1.bounds) }
            return .init(bounds: bounds, glyphs: glyphs)
        }
    }

    private static func readingOrderSort(_ elements: [GeometryElement]) -> [GeometryElement] {
        guard elements.count > 1 else { return elements }
        let byTop = elements.sorted { $0.pageRect.maxY > $1.pageRect.maxY }
        var strips: [(minY: CGFloat, maxY: CGFloat, items: [GeometryElement])] = []
        for el in byTop {
            if var last = strips.last, el.pageRect.maxY > last.minY - 0.5 {
                last.minY = min(last.minY, el.pageRect.minY)
                last.maxY = max(last.maxY, el.pageRect.maxY)
                last.items.append(el)
                strips[strips.count - 1] = last
            } else {
                strips.append((el.pageRect.minY, el.pageRect.maxY, [el]))
            }
        }
        var result: [GeometryElement] = []
        for strip in strips {
            let byLeft = strip.items.sorted { $0.pageRect.minX < $1.pageRect.minX }
            var cols: [(maxX: CGFloat, items: [GeometryElement])] = []
            for el in byLeft {
                if var last = cols.last, el.pageRect.minX < last.maxX - 0.5 {
                    last.maxX = max(last.maxX, el.pageRect.maxX)
                    last.items.append(el)
                    cols[cols.count - 1] = last
                } else {
                    cols.append((el.pageRect.maxX, [el]))
                }
            }
            for col in cols {
                result.append(contentsOf: col.items.sorted {
                    if $0.pageRect.maxY != $1.pageRect.maxY { return $0.pageRect.maxY > $1.pageRect.maxY }
                    return $0.pageRect.minX < $1.pageRect.minX
                })
            }
        }
        return result
    }

    private func buildExpressionBlocks(
        for slices: [RowSlice],
        in containerBounds: CGRect,
        obstacles: [CGRect],
        geometry: NativePDFPageGeometry,
        vectorSpans: [CGRect],
        metrics: LineMetrics,
        on page: PDFPage,
        in view: PDFView
    ) -> [BlockItem] {
        guard !slices.isEmpty else { return [] }
        let th = metrics.typicalHeight
        let containerCheck = containerBounds.insetBy(dx: -1, dy: -1)
        func spanInContainer(_ rect: CGRect) -> Bool {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard containerCheck.contains(center) else { return false }
            return !obstacles.contains { $0.insetBy(dx: -1, dy: -1).contains(center) }
        }
        let scopedSpans: [(rect: CGRect, isGlyph: Bool)] =
            geometry.verticalSpans.filter(spanInContainer).map { ($0, true) }
            + vectorSpans.filter(spanInContainer).map { ($0, false) }

        // Stage 1A: Cluster vertical spans into horizontal bands and detect paired enclosures.
        var spanBands: [[Int]] = []
        for idx in scopedSpans.indices.sorted(by: { scopedSpans[$0].rect.maxY > scopedSpans[$1].rect.maxY }) {
            let b = scopedSpans[idx].rect
            if let match = spanBands.indices.first(where: { bandIdx in
                let ref = scopedSpans[spanBands[bandIdx][0]].rect
                let vOverlap = min(ref.maxY, b.maxY) - max(ref.minY, b.minY)
                return abs(ref.minY - b.minY) <= th * 0.75
                    && abs(ref.maxY - b.maxY) <= th * 0.75
                    && vOverlap >= max(ref.height, b.height) * 0.8
            }) {
                spanBands[match].append(idx)
            } else {
                spanBands.append([idx])
            }
        }

        var enclosures: [PairedEnclosure] = []
        var pairedSpanIndices = Set<Int>()
        for band in spanBands where band.count >= 2 {
            let sortedIndices = band.sorted { scopedSpans[$0].rect.minX < scopedSpans[$1].rect.minX }
            let bandMinY = sortedIndices.map { scopedSpans[$0].rect.minY }.min()!
            let bandMaxY = sortedIndices.map { scopedSpans[$0].rect.maxY }.max()!
            let bandHeight = bandMaxY - bandMinY
            let yLo = bandMinY - th * 0.25, yHi = bandMaxY + th * 0.25

            var validByPos: [Int: Set<Int>] = [:]
            for pos in 0..<(sortedIndices.count - 1) {
                let left = scopedSpans[sortedIndices[pos]].rect
                let right = scopedSpans[sortedIndices[pos + 1]].rect
                let xLo = left.maxX - 1, xHi = right.minX + 1
                guard xLo < xHi else { continue }
                var minGX = CGFloat.infinity, maxGX = -CGFloat.infinity
                var minGY = CGFloat.infinity, maxGY = -CGFloat.infinity
                var rowIndices = Set<Int>()
                for (rowIdx, slice) in slices.enumerated() {
                    guard slice.bounds.maxY >= yLo, slice.bounds.minY <= yHi else { continue }
                    for glyph in slice.row.glyphs {
                        guard !glyph.isWhitespace else { continue }
                        let gx = glyph.bounds.midX, gy = glyph.bounds.midY
                        guard gy >= yLo, gy <= yHi, gx > xLo, gx < xHi else { continue }
                        rowIndices.insert(rowIdx)
                        minGX = min(minGX, glyph.bounds.minX)
                        maxGX = max(maxGX, glyph.bounds.maxX)
                        minGY = min(minGY, glyph.bounds.minY)
                        maxGY = max(maxGY, glyph.bounds.maxY)
                    }
                }
                let isValid: Bool
                if bandHeight >= th * 2.0 {
                    isValid = rowIndices.count >= 2 && (maxGY - minGY) >= bandHeight * 0.65
                } else {
                    isValid = rowIndices.count >= 1
                        && (right.minX - left.maxX) <= th * 10
                        && (minGX - left.maxX) <= th * 2.0
                        && (right.minX - maxGX) <= th * 2.0
                }
                if isValid {
                    validByPos[pos] = rowIndices
                }
            }

            var pos = 0
            while pos < sortedIndices.count - 1 {
                guard var rowSet = validByPos[pos] else { pos += 1; continue }
                let startPos = pos
                var endPos = pos + 1
                while endPos < sortedIndices.count - 1, let nextRows = validByPos[endPos] {
                    let midSpan = scopedSpans[sortedIndices[endPos]]
                    let isThinDivider = !midSpan.isGlyph || midSpan.rect.width <= th * 0.35
                    let sharedRows = rowSet.intersection(nextRows).count
                    let sharesStructure = bandHeight >= th * 2.0
                        ? sharedRows >= 2
                        : (sharedRows >= 1
                            && (scopedSpans[sortedIndices[endPos + 1]].rect.minX - midSpan.rect.maxX) <= th * 6)
                    guard isThinDivider && sharesStructure else { break }
                    endPos += 1
                    rowSet.formUnion(nextRows)
                }
                var unionRect = CGRect.null
                for p in startPos...endPos {
                    let spanIdx = sortedIndices[p]
                    pairedSpanIndices.insert(spanIdx)
                    unionRect = unionRect.union(scopedSpans[spanIdx].rect)
                }
                if !unionRect.isNull {
                    enclosures.append(PairedEnclosure(bounds: unionRect, isMultiRow: rowSet.count >= 2))
                }
                pos = endPos + 1
            }
        }

        // Deduplicate strictly contained enclosures so row splitting assigns every glyph uniquely.
        let filteredEnclosures = enclosures.indices.filter { i in
            let a = enclosures[i].bounds
            let areaA = max(0, a.width) * max(0, a.height)
            return !enclosures.indices.contains { j in
                guard j != i else { return false }
                let b = enclosures[j].bounds
                let areaB = max(0, b.width) * max(0, b.height)
                return areaB > areaA && b.insetBy(dx: -1, dy: -1).contains(a)
            }
        }.map { enclosures[$0] }

        let multiEnclosures = filteredEnclosures.filter(\.isMultiRow)
        let singleEnclosures = filteredEnclosures.filter { !$0.isMultiRow }
        let unpairedGlyphSpans = scopedSpans.indices.compactMap { idx -> CGRect? in
            scopedSpans[idx].isGlyph && !pairedSpanIndices.contains(idx) ? scopedSpans[idx].rect : nil
        }

        // Stage 1B: Split rows across multi-row paired enclosures.
        let multiSplitBoxes = multiEnclosures.map { $0.bounds.insetBy(dx: 0, dy: -th * 0.25) }
        var enclosedLines = multiEnclosures.map { _ in [GeometryElement]() }
        var freeLines: [(element: GeometryElement, fontScale: CGFloat)] = []

        for slice in slices {
            let splitRuns = Self.split(slice.row, across: multiSplitBoxes)
            let overlappedEnclosure = splitRuns.contains { $0.0 != nil }
            for (encIdx, subRow) in splitRuns {
                if let encIdx {
                    let clean = geometry.text(for: subRow, on: page)
                    guard !clean.isEmpty else { continue }
                    let el = GeometryElement(page: page, rect: subRow.bounds, view: view, role: .staticText, label: nil)
                    el.setAccessibilityValue(clean)
                    enclosedLines[encIdx].append(el)
                } else {
                    let obstacleSplit = Self.split(subRow, around: multiSplitBoxes)
                    for piece in obstacleSplit {
                        let runs = (overlappedEnclosure || obstacleSplit.count > 1)
                            ? Self.splitHorizontalGaps(piece, gapThreshold: th * 3.0)
                            : [piece]
                        for run in runs {
                            let clean: String
                            let rect: CGRect
                            if runs.count == 1 && splitRuns.count == 1 && obstacleSplit.count == 1 {
                                clean = slice.text
                                rect = slice.bounds
                            } else {
                                clean = geometry.text(for: run, on: page)
                                rect = run.bounds.intersection(containerBounds)
                            }
                            guard !clean.isEmpty, !rect.isNull, !rect.isEmpty else { continue }
                            let lineFontScale = Self.glyphScale(for: run.glyphs, fallback: rect.height)
                            var finalRect = rect
                            for single in singleEnclosures {
                                let testBox = single.bounds.insetBy(dx: 0, dy: -th * 0.25)
                                if run.glyphs.contains(where: { testBox.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }) {
                                    finalRect = finalRect.union(single.bounds)
                                }
                            }
                            let el = GeometryElement(page: page, rect: finalRect, view: view, role: .staticText, label: nil)
                            el.setAccessibilityValue(clean)
                            freeLines.append((el, lineFontScale))
                        }
                    }
                }
            }
        }

        var multiGroups: [GeometryElement] = []
        for idx in multiEnclosures.indices {
            let lines = enclosedLines[idx].sorted {
                if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                return $0.pageRect.maxY > $1.pageRect.maxY
            }
            guard !lines.isEmpty else { continue }
            let box = lines.reduce(multiEnclosures[idx].bounds) { $0.union($1.pageRect) }
            let group = region(with: lines, bounds: box, on: page, in: view,
                               roleDescription: L10n.tr("内容块", "Section"))
            let joined = lines.compactMap { $0.accessibilityValue() as? String }.joined(separator: "\n")
            if !joined.isEmpty { group.setAccessibilityValue(joined) }
            multiGroups.append(group)
        }

        // Stage 1C: Horizontal Expression-Band Binding (column-gutter aware).
        let sliceRuns: [[NativePDFPageGeometry.Row]] = slices.map { slice in
            let nonWS = slice.row.glyphs.filter { !$0.isWhitespace }
            guard !nonWS.isEmpty else { return [] }
            let bounds = nonWS.dropFirst().reduce(nonWS[0].bounds) { $0.union($1.bounds) }
            return Self.splitHorizontalGaps(
                NativePDFPageGeometry.Row(bounds: bounds, glyphs: nonWS),
                gapThreshold: th * 2.5
            )
        }

        func separatesColumns(
            between a: CGRect,
            and b: CGRect,
            bandMinY: CGFloat,
            bandMaxY: CGFloat,
            bandYRanges: [(CGFloat, CGFloat)]
        ) -> Bool {
            let gapMinX = min(a.maxX, b.maxX), gapMaxX = max(a.minX, b.minX)
            let hGap = gapMaxX - gapMinX
            guard hGap > th * 1.5 else { return false }
            let yLo = bandMinY - th * 14, yHi = bandMaxY + th * 14
            let crossed = sliceRuns.contains { runs in
                runs.contains { run in
                    run.bounds.maxY >= yLo && run.bounds.minY <= yHi
                        && run.bounds.minX <= gapMinX + th * 0.5
                        && run.bounds.maxX >= gapMaxX - th * 0.5
                }
            }
            if crossed { return false }
            let bOnRight = b.midX > a.midX
            let sideExtendsOutside = sliceRuns.contains { runs in
                runs.contains { run in
                    let outsideY = !bandYRanges.contains { run.bounds.midY >= $0.0 && run.bounds.midY <= $0.1 }
                    guard outsideY, run.bounds.maxY >= yLo, run.bounds.minY <= yHi else { return false }
                    return bOnRight ? (run.bounds.minX >= gapMaxX - th * 0.5)
                                    : (run.bounds.maxX <= gapMinX + th * 0.5)
                }
            }
            return sideExtendsOutside || hGap > th * 8
        }

        func blockedByObstacle(between a: CGRect, and b: CGRect) -> Bool {
            let spanMinX = min(a.minX, b.minX), spanMaxX = max(a.maxX, b.maxX)
            let spanMinY = min(a.minY, b.minY), spanMaxY = max(a.maxY, b.maxY)
            return obstacles.contains { box in
                max(box.minX, spanMinX) < min(box.maxX, spanMaxX)
                    && max(box.minY, spanMinY) < min(box.maxY, spanMaxY)
            }
        }

        struct ExpressionBand {
            var children: [GeometryElement]
            var spans: [CGRect]
            var rect: CGRect
            let seedMinX: CGFloat
        }

        var bands: [ExpressionBand] = []
        for group in multiGroups.sorted(by: { $0.pageRect.minX < $1.pageRect.minX }) {
            let gr = group.pageRect
            if let match = bands.indices.first(where: { idx in
                let br = bands[idx].rect
                let vOverlap = min(br.maxY, gr.maxY) - max(br.minY, gr.minY)
                guard vOverlap >= min(br.height, gr.height) * 0.5 else { return false }
                let bMinY = min(br.minY, gr.minY), bMaxY = max(br.maxY, gr.maxY)
                return !separatesColumns(
                        between: br,
                        and: gr,
                        bandMinY: bMinY,
                        bandMaxY: bMaxY,
                        bandYRanges: [(bMinY - th * 0.5, bMaxY + th * 0.5)]
                    )
                    && !blockedByObstacle(between: br, and: gr)
            }) {
                bands[match].children.append(group)
                bands[match].rect = bands[match].rect.union(gr)
            } else {
                bands.append(ExpressionBand(children: [group], spans: [], rect: gr, seedMinX: gr.minX))
            }
        }

        for span in unpairedGlyphSpans {
            let overlappingBand = bands.indices.first { idx in
                let br = bands[idx].rect
                return min(br.maxY, span.maxY) - max(br.minY, span.minY) >= min(br.height, span.height) * 0.5
                    && max(br.minX, span.minX) <= min(br.maxX, span.maxX) + th * 4
            }
            if let overlappingBand {
                bands[overlappingBand].spans.append(span)
                bands[overlappingBand].rect = bands[overlappingBand].rect.union(span)
            } else {
                bands.append(ExpressionBand(children: [], spans: [span], rect: span, seedMinX: span.minX))
            }
        }

        let allBandYRanges = bands.map { ($0.rect.minY - th * 0.25, $0.rect.maxY + th * 0.25) }
        var unattachedLines: [(element: GeometryElement, fontScale: CGFloat)] = []
        for line in freeLines {
            let lr = line.element.pageRect
            let match = bands.indices.first { idx in
                let br = bands[idx].rect
                let vOverlap = min(br.maxY, lr.maxY) - max(br.minY, lr.minY)
                guard (lr.midY >= br.minY - th * 0.25 && lr.midY <= br.maxY + th * 0.25)
                        || vOverlap >= lr.height * 0.55 else { return false }
                // Guard left-margin prose lead-ins sitting well left and above the band's vertical center.
                if lr.maxX < bands[idx].seedMinX - th * 2.5 && lr.minY > br.midY + th * 0.25 {
                    return false
                }
                return !separatesColumns(
                        between: br,
                        and: lr,
                        bandMinY: br.minY,
                        bandMaxY: br.maxY,
                        bandYRanges: allBandYRanges
                    )
                    && !blockedByObstacle(between: br, and: lr)
            }
            if let match {
                bands[match].children.append(line.element)
                bands[match].rect = bands[match].rect.union(lr)
            } else {
                unattachedLines.append(line)
            }
        }

        var result: [BlockItem] = unattachedLines.map {
            BlockItem(element: $0.element, isCompound: false, fontScale: $0.fontScale)
        }
        for band in bands {
            guard !band.children.isEmpty else { continue }
            if band.children.count == 1 && band.spans.isEmpty && band.children[0].accessibilityRole() == .group {
                result.append(BlockItem(element: band.children[0], isCompound: true, fontScale: metrics.typicalFontScale))
                continue
            }
            let sortedChildren = Self.readingOrderSort(band.children)
            let box = band.spans.reduce(sortedChildren.reduce(CGRect.null) { $0.union($1.pageRect) }) { $0.union($1) }
            let group = region(with: sortedChildren, bounds: box, on: page, in: view,
                               roleDescription: L10n.tr("内容块", "Section"))
            let joined = sortedChildren.compactMap { $0.accessibilityValue() as? String }.joined(separator: "\n")
            if !joined.isEmpty { group.setAccessibilityValue(joined) }
            result.append(BlockItem(element: group, isCompound: true, fontScale: metrics.typicalFontScale))
        }
        return result
    }

    /// Partition lines in `containerBounds` into coherent 2D reading blocks (single- or multi-column
    /// paragraphs, indented blocks, and stacked equations) using purely geometric metrics and alignment.
    private func partitionBlocks(
        for slices: [RowSlice],
        in containerBounds: CGRect,
        obstacles: [CGRect],
        geometry: NativePDFPageGeometry,
        vectorSpans: [CGRect],
        metrics: LineMetrics,
        on page: PDFPage,
        in view: PDFView
    ) -> [GeometryElement] {
        let items = buildExpressionBlocks(
            for: slices,
            in: containerBounds,
            obstacles: obstacles,
            geometry: geometry,
            vectorSpans: vectorSpans,
            metrics: metrics,
            on: page,
            in: view
        )
        guard !items.isEmpty else { return [] }
        let ordered = items.sorted { a, b in
            if a.pageRect.midY != b.pageRect.midY { return a.pageRect.midY > b.pageRect.midY }
            return a.pageRect.minX < b.pageRect.minX
        }
        let th = metrics.typicalHeight
        let containerWidth = max(1, containerBounds.width)
        func isTinyFragment(_ item: BlockItem) -> Bool {
            !item.isCompound && item.pageRect.width <= th * 3.5 && item.pageRect.height <= th * 0.7
        }

        let wideRects = ordered.filter { !isTinyFragment($0) && $0.pageRect.width >= containerWidth * 0.35 }.map(\.pageRect)
        func localColumnRight(for upper: CGRect, _ lower: CGRect) -> CGFloat {
            let spanMinX = min(upper.minX, lower.minX), spanMaxX = max(upper.maxX, lower.maxX)
            let matching = wideRects.filter { rect in
                max(rect.minX, spanMinX) < min(rect.maxX, spanMaxX)
                    && abs(rect.minX - upper.minX) <= containerWidth * 0.25
            }
            if let maxR = matching.map(\.maxX).max() { return maxR }
            return wideRects.map(\.maxX).max() ?? containerBounds.maxX
        }

        var blocks: [[BlockItem]] = []
        var closedBlocks = Set<Int>()
        var pendingFragments: [BlockItem] = []

        func attachPendingFragments(to blockIndex: Int, targetRect: CGRect) {
            guard !pendingFragments.isEmpty else { return }
            var remaining: [BlockItem] = []
            for frag in pendingFragments {
                let fr = frag.pageRect
                let vGap = max(0, max(fr.minY - targetRect.maxY, targetRect.minY - fr.maxY))
                if vGap <= th * 0.25 && fr.midX >= targetRect.minX - th && fr.midX <= targetRect.maxX + th {
                    blocks[blockIndex].append(frag)
                } else {
                    remaining.append(frag)
                }
            }
            pendingFragments = remaining
        }

        for item in ordered {
            let rect = item.pageRect
            if isTinyFragment(item),
               let match = blocks.indices.reversed().first(where: { idx in
                   guard !closedBlocks.contains(idx),
                         let anchor = blocks[idx].last(where: { !isTinyFragment($0) })?.pageRect else { return false }
                   let vGap = max(0, max(rect.minY - anchor.maxY, anchor.minY - rect.maxY))
                   return vGap <= th * 0.25 && rect.midX >= anchor.minX - th && rect.midX <= anchor.maxX + th
               }) {
                blocks[match].append(item)
                continue
            }

            // Flush stale pending fragments before processing the next normal item.
            if !pendingFragments.isEmpty {
                var kept: [BlockItem] = []
                for frag in pendingFragments {
                    if frag.pageRect.minY - rect.maxY > th * 0.25 {
                        if let match = blocks.indices.reversed().first(where: { idx in
                            guard !closedBlocks.contains(idx) else { return false }
                            let colRight = blocks[idx].last.map { localColumnRight(for: $0.pageRect, frag.pageRect) } ?? containerBounds.maxX
                            return Self.canContinueBlock(
                                blocks[idx],
                                with: frag,
                                isFragment: isTinyFragment,
                                obstacles: obstacles,
                                containerWidth: containerWidth,
                                columnRight: colRight,
                                metrics: metrics
                            )
                        }) {
                            blocks[match].append(frag)
                        } else {
                            blocks.append([frag])
                            closedBlocks.insert(blocks.count - 1)
                        }
                    } else {
                        kept.append(frag)
                    }
                }
                pendingFragments = kept
            }

            if isTinyFragment(item) {
                pendingFragments.append(item)
                continue
            }

            if let match = blocks.indices.reversed().first(where: { idx in
                guard !closedBlocks.contains(idx) else { return false }
                let colRight = blocks[idx].last(where: { !isTinyFragment($0) }).map { localColumnRight(for: $0.pageRect, rect) } ?? containerBounds.maxX
                return Self.canContinueBlock(
                    blocks[idx],
                    with: item,
                    isFragment: isTinyFragment,
                    obstacles: obstacles,
                    containerWidth: containerWidth,
                    columnRight: colRight,
                    metrics: metrics
                )
            }) {
                attachPendingFragments(to: match, targetRect: rect)
                blocks[match].append(item)
            } else {
                for idx in blocks.indices where !closedBlocks.contains(idx) {
                    if let lastRect = blocks[idx].last(where: { !isTinyFragment($0) })?.pageRect,
                       max(lastRect.minX, rect.minX) < min(lastRect.maxX, rect.maxX) {
                        closedBlocks.insert(idx)
                    }
                }
                blocks.append([item])
                attachPendingFragments(to: blocks.count - 1, targetRect: rect)
            }
        }

        for frag in pendingFragments {
            if let match = blocks.indices.reversed().first(where: { idx in
                guard !closedBlocks.contains(idx) else { return false }
                let colRight = blocks[idx].last.map { localColumnRight(for: $0.pageRect, frag.pageRect) } ?? containerBounds.maxX
                return Self.canContinueBlock(
                    blocks[idx],
                    with: frag,
                    isFragment: isTinyFragment,
                    obstacles: obstacles,
                    containerWidth: containerWidth,
                    columnRight: colRight,
                    metrics: metrics
                )
            }) {
                blocks[match].append(frag)
            } else {
                blocks.append([frag])
            }
        }

        return blocks.map { members in
            let orderedMembers = members.map(\.element).sorted {
                if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                return $0.pageRect.maxY > $1.pageRect.maxY
            }
            guard orderedMembers.count > 1 else { return orderedMembers[0] }
            let bounds = orderedMembers.reduce(CGRect.null) { $0.union($1.pageRect) }
            let roleDesc = members.contains(where: \.isCompound)
                ? L10n.tr("内容块", "Section")
                : L10n.tr("段落", "Paragraph")
            let group = region(with: orderedMembers, bounds: bounds, on: page, in: view, roleDescription: roleDesc)
            let joined = orderedMembers.compactMap { $0.accessibilityValue() as? String }.joined(separator: "\n")
            if !joined.isEmpty { group.setAccessibilityValue(joined) }
            return group
        }
    }

    private func region(
        with lines: [GeometryElement],
        bounds: CGRect,
        on page: PDFPage,
        in view: PDFView,
        roleDescription: String? = nil
    ) -> GeometryElement {
        let group = GeometryElement(page: page, rect: bounds, view: view, role: .group, label: nil)
        if let roleDescription { group.setAccessibilityRoleDescription(roleDescription) }
        group.allChildren = lines
        for line in lines { line.setAccessibilityParent(group) }
        return group
    }

    /// Purely geometric block continuity test combining page-normalized vertical rhythm, obstacle clearance,
    /// typographic scale compatibility, and multi-style horizontal alignment (flush left/right, first-line indent,
    /// hanging indent, centered stacked blocks, and multi-row compound expression derivations).
    private static func canContinueBlock(
        _ block: [BlockItem],
        with lowerItem: BlockItem,
        isFragment: (BlockItem) -> Bool,
        obstacles: [CGRect],
        containerWidth: CGFloat,
        columnRight: CGFloat,
        metrics: LineMetrics
    ) -> Bool {
        let substantive = block.filter { !isFragment($0) }
        guard let upperItem = substantive.last ?? block.last else { return false }
        let upper = upperItem.pageRect
        let lower = lowerItem.pageRect
        let lineHeight = min(upper.height, lower.height)
        guard lineHeight > 0, lower.height > 0,
              max(upper.minX, lower.minX) < min(upper.maxX, lower.maxX) else { return false }

        let th = metrics.typicalHeight
        let step = metrics.typicalStep
        let dyMid = upper.midY - lower.midY
        let gap = upper.minY - lower.maxY
        let maxGap = max(th * 1.35, (step - th) * 1.65)
        guard gap >= -th * 0.35, gap <= maxGap else { return false }

        let spanMinX = min(upper.minX, lower.minX), spanMaxX = max(upper.maxX, lower.maxX)
        let blocked = obstacles.contains { box in
            ((box.maxY <= upper.minY + th * 0.25 && box.minY >= lower.maxY - th * 0.25)
                || (box.midY < upper.midY && box.midY > lower.midY))
                && max(box.minX, spanMinX) < min(box.maxX, spanMaxX)
        }
        guard !blocked else { return false }

        let alignTol = th * 0.75
        let hOverlap = min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX)

        if upperItem.isCompound || lowerItem.isCompound {
            if upperItem.isCompound && lowerItem.isCompound {
                return abs(lower.minX - upper.minX) <= alignTol
                    || abs(lower.maxX - upper.maxX) <= alignTol
                    || abs(upper.midX - lower.midX) <= th * 1.8
                    || hOverlap >= min(upper.width, lower.width) * 0.65
            }
            if abs(lower.minX - upper.minX) <= alignTol { return true }
            if gap <= th * 1.0 && upper.width < containerWidth * 0.7 && lower.width < containerWidth * 0.7
                && hOverlap >= min(upper.width, lower.width) * 0.72
                && abs(upper.midX - lower.midX) <= th * 1.6 {
                return true
            }
            if gap <= th * 1.0 && upper.width < containerWidth * 0.65 && lower.width < containerWidth * 0.65
                && abs(lower.maxX - upper.maxX) <= alignTol {
                return true
            }
            return false
        }

        let excessH = max(0, upper.height - th) * 0.5 + max(0, lower.height - th) * 0.5
        guard dyMid >= th * 0.45, dyMid <= step * 1.32 + excessH else { return false }

        // Prevent mixing display headings with body lines using typographic glyph scale (75th percentile
        // glyph height) rather than full line bounds, so inline math delimiters or sub/superscripts on
        // body lines never break paragraphs or lists.
        let fs = metrics.typicalFontScale
        let uScale = upperItem.fontScale, lScale = lowerItem.fontScale
        if (substantive.count == 1 && uScale > fs * 1.20 && uScale > lScale * 1.16)
            || (lScale > fs * 1.20 && lScale > uScale * 1.16) {
            return false
        }
        guard max(upper.height, lower.height) <= max(lineHeight * 2.4, th * 2.2) else { return false }

        let maxIndent = th * 3.5
        let substantiveRects = substantive.map(\.pageRect)
        let subCount = substantiveRects.count
        let bodyMinX = subCount >= 2 ? (substantiveRects.dropFirst().map(\.minX).min() ?? upper.minX) : upper.minX

        // 1. Flush left (or continuing the established body margin below an indented opening line).
        if abs(lower.minX - upper.minX) <= alignTol
            || (subCount >= 2 && abs(lower.minX - bodyMinX) <= alignTol) {
            return true
        }
        // 2. Flush right (justified prose or right-aligned equations).
        if abs(lower.maxX - upper.maxX) <= alignTol
            && (upper.maxX >= columnRight - maxIndent
                || lower.minX >= upper.minX - maxIndent) {
            return true
        }
        // 3. First-line paragraph indent returning to the body left margin.
        let leftDelta = upper.minX - lower.minX
        if subCount == 1 && leftDelta > alignTol && leftDelta <= maxIndent
            && (upper.maxX >= columnRight - maxIndent
                || (lower.maxX <= columnRight - maxIndent && upper.maxX >= lower.maxX - alignTol)) {
            return true
        }
        // 4. Hanging indent (first line wraps across to column right edge, continuation is indented).
        let hangingDelta = lower.minX - upper.minX
        if subCount == 1 && hangingDelta > alignTol && hangingDelta <= maxIndent
            && upper.maxX >= max(lower.maxX, columnRight) - maxIndent {
            return true
        }
        // 5. Centered stacked equation or multi-line formula block.
        if dyMid <= step * 1.18
            && upper.width < containerWidth * 0.7 && lower.width < containerWidth * 0.7
            && hOverlap >= min(upper.width, lower.width) * 0.72
            && abs(upper.midX - lower.midX) <= th * 1.6 {
            return true
        }
        return false
    }

    final class GeometryElement: NSAccessibilityElement {
        weak var page: PDFPage?
        weak var view: PDFView?
        weak var annotation: PDFAnnotation?
        let pageRect: CGRect
        var allChildren: [GeometryElement] = []
        init(page: PDFPage, rect: CGRect, view: PDFView, role: NSAccessibility.Role, label: String?) {
            self.page = page; self.pageRect = rect; self.view = view
            super.init()
            setAccessibilityRole(role)
            setAccessibilityLabel(label)
            setAccessibilityEnabled(true)
        }
        override func accessibilityChildren() -> [Any]? {
            let visible = allChildren.filter { !$0.accessibilityFrame().isEmpty }
            return visible.isEmpty ? nil : visible
        }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? {
            deepestHit(at: point) ?? super.accessibilityHitTest(point)
        }
        func deepestHit(at point: NSPoint) -> GeometryElement? {
            guard accessibilityFrame().contains(point) else { return nil }
            // Links come after text in the tree and keep their hit area when they overlap a line.
            var region: GeometryElement?
            for child in allChildren.reversed() {
                guard let hit = child.deepestHit(at: point) else { continue }
                if hit.allChildren.isEmpty { return hit }
                if region == nil { region = hit }
            }
            return region ?? self
        }
        override func accessibilityFrame() -> NSRect {
            guard let page, let view, let window = view.window,
                  page.document === view.document, view.visiblePages.contains(where: { $0 === page }) else { return .zero }
            let frame = view.convert(pageRect, from: page).intersection(view.visibleRect)
            guard !frame.isNull, !frame.isEmpty else { return .zero }
            return window.convertToScreen(view.convert(frame, to: nil))
        }
        override func accessibilityPerformPress() -> Bool {
            guard let view, let action = annotation?.action else { return false }
            view.perform(action)
            return true
        }
    }
}
