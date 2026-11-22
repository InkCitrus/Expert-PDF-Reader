import CoreGraphics
import PDFKit

/// Locate vector panels, paired vertical sidebars, ruled tables, and diagram figures.
@MainActor
enum PDFFramedRegions {
    struct Region {
        enum Kind {
            case panel
            case table
            case figure
        }

        let bounds: CGRect
        let kind: Kind
    }

    static func bounds(on page: PDFPage, geometry: NativePDFPageGeometry) -> [CGRect] {
        regions(on: page, geometry: geometry).map(\.bounds)
    }

    static func regions(on page: PDFPage, geometry: NativePDFPageGeometry) -> [Region] {
        guard let source = page.pageRef, !geometry.rows.isEmpty else { return [] }
        let crop = geometry.cropBox
        let heights = geometry.rows.map { $0.bounds.height }.sorted()
        let inkHeight = heights[heights.count / 2]
        let scan = PDFPanelScan.scan(on: source, clippedTo: crop)

        func rowCount(inside box: CGRect, limit: Int) -> Int {
            geometry.rows.lazy.filter { row in
                box.contains(row.bounds.center) || row.glyphs.contains { box.contains($0.bounds.center) }
            }.prefix(limit).count
        }
        func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
            let inter = a.intersection(b)
            guard !inter.isNull, !inter.isEmpty else { return false }
            let areaA = a.area, areaB = b.area
            return areaA > 0 && areaB > 0 && inter.area >= max(areaA, areaB) * 0.85
        }
        func isRedundant(_ candidate: CGRect, against existing: [Region]) -> Bool {
            existing.contains { region in
                roughlyEqual(region.bounds, candidate)
                    || (region.bounds.insetBy(dx: -2, dy: -2).contains(candidate)
                        && candidate.area > region.bounds.area * 0.75)
            }
        }

        // 1. Closed vector panels and attached heading ribbons.
        let panels = scan.drawings.filter { drawing in
            let box = drawing.bounds
            guard drawing.isPanel, box.width >= max(inkHeight * 6, crop.width * 0.16),
                  box.height >= inkHeight * 2, box.height < crop.height * 0.85 else { return false }
            return rowCount(inside: box, limit: 2) == 2
        }.sorted { $0.bounds.area > $1.bounds.area }

        var regions: [Region] = []
        var panelBodies: [CGRect] = []
        var panelPrimitives: [CGRect] = []
        for panel in panels {
            let body = panel.bounds
            // Keep nested panels only when noticeably smaller than the enclosing frame;
            // otherwise treat overpainted concentric borders as one frame.
            if panelBodies.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(body) && body.area > $0.area * 0.75 }) {
                panelPrimitives.append(body)
                continue
            }
            var box = body
            var attachedRibbons: [CGRect] = []
            for drawing in scan.drawings {
                let ribbon = drawing.bounds
                let overlap = min(ribbon.maxX, body.maxX) - max(ribbon.minX, body.minX)
                guard ribbon.height <= inkHeight * 3, ribbon.width <= body.width * 1.25,
                      overlap >= ribbon.width * 0.75, overlap >= body.width * 0.2,
                      ribbon.maxY > body.maxY + inkHeight * 0.3,
                      abs(ribbon.minY - body.maxY) <= inkHeight * 0.35 else { continue }
                // A neighboring rule is not a title. Require visible ink above the frame
                // inside the attached path, independent of what that title says.
                let title = geometry.rows.contains { row in
                    row.glyphs.contains { glyph in
                        let center = glyph.bounds.center
                        return center.y > body.maxY && ribbon.contains(center)
                    }
                }
                if title {
                    box = box.union(ribbon)
                    attachedRibbons.append(ribbon)
                }
            }
            panelPrimitives.append(body)
            panelPrimitives.append(contentsOf: attachedRibbons)
            if regions.contains(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(box) && box.area > $0.bounds.area * 0.75 }) {
                continue
            }
            panelBodies.append(body)
            regions.append(Region(bounds: box, kind: .panel))
        }

        // Mark inner panel fills and top header banners so figure clustering never treats them as figures.
        for drawing in scan.drawings {
            let box = drawing.bounds
            if panelBodies.contains(where: { outer in
                outer.insetBy(dx: -1.5, dy: -1.5).contains(box)
                    && (box.area > outer.area * 0.75
                        || (box.width >= outer.width * 0.75 && box.height <= inkHeight * 3
                            && abs(box.maxY - outer.maxY) <= inkHeight * 0.5))
            }) {
                panelPrimitives.append(box)
            }
        }

        // 2. Paired vertical sidebars (e.g. Solution blocks bordered on left and right margins).
        var usedVerticalIndices = Set<Int>()
        let vRules = scan.verticalRules
        let sidebarCandidates = vRules.indices.filter { idx in
            let rule = vRules[idx]
            guard rule.height >= inkHeight * 3, rule.height < crop.height * 0.85 else { return false }
            return !regions.contains { panel in
                let vOverlap = min(rule.maxY, panel.bounds.maxY) - max(rule.minY, panel.bounds.minY)
                guard vOverlap >= rule.height * 0.7 else { return false }
                let edgeTol = max(4, rule.width)
                return abs(rule.minX - panel.bounds.minX) <= edgeTol || abs(rule.maxX - panel.bounds.maxX) <= edgeTol
            }
        }.sorted { vRules[$0].minX < vRules[$1].minX }

        for aPos in sidebarCandidates.indices {
            let i = sidebarCandidates[aPos]
            guard !usedVerticalIndices.contains(i) else { continue }
            let left = vRules[i]
            for bPos in (aPos + 1)..<sidebarCandidates.count {
                let j = sidebarCandidates[bPos]
                guard !usedVerticalIndices.contains(j) else { continue }
                let right = vRules[j]
                let maxH = max(left.height, right.height)
                let vOverlap = min(left.maxY, right.maxY) - max(left.minY, right.minY)
                guard abs(left.minY - right.minY) <= inkHeight * 1.5,
                      abs(left.maxY - right.maxY) <= inkHeight * 1.5,
                      vOverlap >= maxH * 0.85 else { continue }
                let span = left.union(right)
                guard span.width >= max(inkHeight * 6, crop.width * 0.16),
                      span.height < crop.height * 0.85 else { continue }
                let hasDivider = vRules.contains { mid in
                    mid.minX > left.maxX + 2 && mid.maxX < right.minX - 2
                        && (min(mid.maxY, span.maxY) - max(mid.minY, span.minY)) >= maxH * 0.7
                }
                guard !hasDivider, rowCount(inside: span, limit: 2) == 2,
                      !isRedundant(span, against: regions) else { continue }
                usedVerticalIndices.insert(i)
                usedVerticalIndices.insert(j)
                regions.append(Region(bounds: span, kind: .panel))
                break
            }
        }

        // 3. Ruled grid tables (axis-aligned horizontal and vertical strokes touching within tolerance).
        let hRules = scan.horizontalRules
        var rulePrimitives: [(isHorizontal: Bool, index: Int, rect: CGRect)] = []
        for (i, r) in hRules.enumerated() { rulePrimitives.append((true, i, r)) }
        for (j, r) in vRules.enumerated() where !usedVerticalIndices.contains(j) {
            rulePrimitives.append((false, j, r))
        }
        let tableTol = max(4, inkHeight * 0.6)
        var visitedRules = Array(repeating: false, count: rulePrimitives.count)
        var usedHorizontalTableRules = Set<Int>()
        var usedVerticalTableRules = Set<Int>()
        var tables: [Region] = []
        for start in rulePrimitives.indices where !visitedRules[start] {
            var queue = [start]
            visitedRules[start] = true
            var component: [Int] = []
            var head = 0
            while head < queue.count {
                let cur = queue[head]
                head += 1
                component.append(cur)
                let expanded = rulePrimitives[cur].rect.insetBy(dx: -tableTol, dy: -tableTol)
                for next in rulePrimitives.indices where !visitedRules[next] {
                    if expanded.intersects(rulePrimitives[next].rect) {
                        visitedRules[next] = true
                        queue.append(next)
                    }
                }
            }
            let hs = component.filter { rulePrimitives[$0].isHorizontal }.map { rulePrimitives[$0].rect }
            let vs = component.filter { !rulePrimitives[$0].isHorizontal }.map { rulePrimitives[$0].rect }
            guard hs.count >= 2, vs.count >= 2 else { continue }
            func distinctCount(_ values: [CGFloat]) -> Int {
                var count = 0
                var last = -CGFloat.infinity
                for v in values.sorted() where v - last > 2 {
                    count += 1
                    last = v
                }
                return count
            }
            guard distinctCount(hs.map(\.midY)) >= 2, distinctCount(vs.map(\.midX)) >= 2 else { continue }
            let box = component.reduce(CGRect.null) { $0.union(rulePrimitives[$1].rect) }
            guard box.width >= inkHeight * 4, box.height >= inkHeight * 2,
                  box.height < crop.height * 0.85,
                  rowCount(inside: box, limit: 2) == 2,
                  !isRedundant(box, against: regions) else { continue }
            let region = Region(bounds: box, kind: .table)
            tables.append(region)
            regions.append(region)
            for idx in component {
                if rulePrimitives[idx].isHorizontal { usedHorizontalTableRules.insert(rulePrimitives[idx].index) }
                else { usedVerticalTableRules.insert(rulePrimitives[idx].index) }
            }
        }

        // 4. Connected vector figure clusters (seeded by non-panel shapes, attaching adjacent short rules).
        let candidateShapes = scan.shapes.filter { shape in
            guard !(shape.width > crop.width * 0.85 && shape.height > crop.height * 0.85) else { return false }
            if panelPrimitives.contains(where: { roughlyEqual($0, shape) }) { return false }
            if tables.contains(where: {
                let inter = $0.bounds.intersection(shape)
                return !inter.isNull && shape.area > 0 && inter.area >= shape.area * 0.75
            }) {
                return false
            }
            return true
        }
        var freeRules: [CGRect] = []
        let maxFigureRuleLength = crop.width * 0.55
        for (i, r) in hRules.enumerated() where !usedHorizontalTableRules.contains(i) && r.width < maxFigureRuleLength {
            freeRules.append(r)
        }
        for (j, r) in vRules.enumerated() where !usedVerticalIndices.contains(j) && !usedVerticalTableRules.contains(j) && r.height < maxFigureRuleLength {
            freeRules.append(r)
        }

        // Precompute short contiguous text label spans so diagram annotations (e.g. feed/X/Y/Z) attach to their figure
        // without swallowing multi-word captions or column-wide equations.
        let labelSpans: [CGRect] = geometry.rows.flatMap { row -> [CGRect] in
            var spans: [CGRect] = []
            var current = CGRect.null
            var prevMaxX: CGFloat?
            for glyph in row.glyphs {
                if let prev = prevMaxX, glyph.bounds.minX - prev > inkHeight * 2.5, !current.isNull {
                    spans.append(current)
                    current = glyph.bounds
                } else {
                    current = current.isNull ? glyph.bounds : current.union(glyph.bounds)
                }
                prevMaxX = glyph.bounds.maxX
            }
            if !current.isNull { spans.append(current) }
            return spans.filter { $0.width < max(inkHeight * 12, crop.width * 0.18) && $0.height <= inkHeight * 2.2 }
        }

        let figureTol = max(6, inkHeight * 0.8)
        var visitedShapes = Array(repeating: false, count: candidateShapes.count)
        var visitedFreeRules = Array(repeating: false, count: freeRules.count)
        for seed in candidateShapes.indices where !visitedShapes[seed] {
            visitedShapes[seed] = true
            var queue: [(isShape: Bool, index: Int)] = [(true, seed)]
            var clusterBox = candidateShapes[seed]
            var head = 0
            while head < queue.count {
                let cur = queue[head]
                head += 1
                let rect = cur.isShape ? candidateShapes[cur.index] : freeRules[cur.index]
                let expanded = rect.insetBy(dx: -figureTol, dy: -figureTol)
                for sIdx in candidateShapes.indices where !visitedShapes[sIdx] {
                    if expanded.intersects(candidateShapes[sIdx]) {
                        visitedShapes[sIdx] = true
                        clusterBox = clusterBox.union(candidateShapes[sIdx])
                        queue.append((true, sIdx))
                    }
                }
                for rIdx in freeRules.indices where !visitedFreeRules[rIdx] {
                    if expanded.intersects(freeRules[rIdx]) {
                        visitedFreeRules[rIdx] = true
                        clusterBox = clusterBox.union(freeRules[rIdx])
                        queue.append((false, rIdx))
                    }
                }
            }
            guard clusterBox.width >= max(inkHeight * 4, 36),
                  clusterBox.height >= max(inkHeight * 3, 28),
                  !(clusterBox.width > crop.width * 0.9 && clusterBox.height > crop.height * 0.85) else { continue }
            let coveredByTable = tables.contains { table in
                let inter = table.bounds.intersection(clusterBox)
                return !inter.isNull && clusterBox.area > 0 && inter.area >= clusterBox.area * 0.75
            }
            guard !coveredByTable else { continue }
            let wideProseRows = geometry.rows.lazy.filter { row in
                row.bounds.width > crop.width * 0.45 && clusterBox.contains(row.bounds.center)
            }.prefix(3).count
            guard wideProseRows < 3 else { continue }

            let labelReach = clusterBox.insetBy(dx: -inkHeight * 2.2, dy: -inkHeight * 0.6)
            var expandedBox = clusterBox
            for span in labelSpans where labelReach.intersects(span) {
                expandedBox = expandedBox.union(span)
            }
            guard !isRedundant(expandedBox, against: regions) else { continue }
            regions.append(Region(bounds: expandedBox, kind: .figure))
        }

        return regions
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { max(0, width) * max(0, height) }
}

/// Quartz supplies parsed PDF operands for panels, open orthogonal rules, and vector figures.
private final class PDFPanelScan {
    struct Drawing {
        let bounds: CGRect
        let isPanel: Bool
    }

    struct ScanResult {
        let drawings: [Drawing]
        let horizontalRules: [CGRect]
        let verticalRules: [CGRect]
        let shapes: [CGRect]
    }

    struct GraphicsState {
        var transform = CGAffineTransform.identity
        var clip: CGRect
        var lineWidth: CGFloat = 1
        var whiteFill = false
        var whiteStroke = false
    }

    private var state: GraphicsState
    private var savedStates: [GraphicsState] = []
    private var path = CGMutablePath()
    private var subpathStart: CGPoint?
    private var closed = false
    private var updatesClip = false
    private var drawings: [Drawing] = []
    private var horizontalRules: [CGRect] = []
    private var verticalRules: [CGRect] = []
    private var shapes: [CGRect] = []

    private init(crop: CGRect) {
        state = GraphicsState(clip: crop)
    }

    static func scan(on page: CGPDFPage, clippedTo crop: CGRect) -> ScanResult {
        guard let table = CGPDFOperatorTableCreate() else {
            return ScanResult(drawings: [], horizontalRules: [], verticalRules: [], shapes: [])
        }
        defer { CGPDFOperatorTableRelease(table) }
        let callbacks: [(String, CGPDFOperatorCallback)] = [
            ("q", { _, info in PDFPanelScan.instance(info)?.save() }),
            ("Q", { _, info in PDFPanelScan.instance(info)?.restore() }),
            ("cm", { scanner, info in PDFPanelScan.instance(info)?.concatenate(scanner) }),
            ("w", { scanner, info in PDFPanelScan.instance(info)?.setLineWidth(scanner) }),
            ("g", { scanner, info in PDFPanelScan.instance(info)?.setFill(scanner, components: 1) }),
            ("rg", { scanner, info in PDFPanelScan.instance(info)?.setFill(scanner, components: 3) }),
            ("k", { scanner, info in PDFPanelScan.instance(info)?.setFill(scanner, components: 4) }),
            ("G", { scanner, info in PDFPanelScan.instance(info)?.setStroke(scanner, components: 1) }),
            ("RG", { scanner, info in PDFPanelScan.instance(info)?.setStroke(scanner, components: 3) }),
            ("K", { scanner, info in PDFPanelScan.instance(info)?.setStroke(scanner, components: 4) }),
            ("m", { scanner, info in PDFPanelScan.instance(info)?.move(scanner) }),
            ("l", { scanner, info in PDFPanelScan.instance(info)?.line(scanner) }),
            ("c", { scanner, info in PDFPanelScan.instance(info)?.curve(scanner) }),
            ("v", { scanner, info in PDFPanelScan.instance(info)?.curve(scanner, firstAtCurrentPoint: true) }),
            ("y", { scanner, info in PDFPanelScan.instance(info)?.curve(scanner, secondAtEnd: true) }),
            ("h", { _, info in PDFPanelScan.instance(info)?.close() }),
            ("re", { scanner, info in PDFPanelScan.instance(info)?.rectangle(scanner) }),
            ("W", { _, info in PDFPanelScan.instance(info)?.updatesClip = true }),
            ("W*", { _, info in PDFPanelScan.instance(info)?.updatesClip = true }),
            ("n", { _, info in PDFPanelScan.instance(info)?.finish() }),
            ("f", { _, info in PDFPanelScan.instance(info)?.finish(fill: true) }),
            ("F", { _, info in PDFPanelScan.instance(info)?.finish(fill: true) }),
            ("f*", { _, info in PDFPanelScan.instance(info)?.finish(fill: true, evenOdd: true) }),
            ("S", { _, info in PDFPanelScan.instance(info)?.finish(stroke: true) }),
            ("s", { _, info in PDFPanelScan.instance(info)?.finish(stroke: true, close: true) }),
            ("B", { _, info in PDFPanelScan.instance(info)?.finish(fill: true, stroke: true) }),
            ("B*", { _, info in PDFPanelScan.instance(info)?.finish(fill: true, stroke: true, evenOdd: true) }),
            ("b", { _, info in PDFPanelScan.instance(info)?.finish(fill: true, stroke: true, close: true) }),
            ("b*", { _, info in PDFPanelScan.instance(info)?.finish(fill: true, stroke: true, evenOdd: true, close: true) })
        ]
        for (name, callback) in callbacks {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }

        let scan = PDFPanelScan(crop: crop)
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(scan).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        guard CGPDFScannerScan(scanner) else {
            return ScanResult(drawings: [], horizontalRules: [], verticalRules: [], shapes: [])
        }
        return ScanResult(drawings: scan.drawings, horizontalRules: scan.horizontalRules,
                          verticalRules: scan.verticalRules, shapes: scan.shapes)
    }

    private static func instance(_ info: UnsafeMutableRawPointer?) -> PDFPanelScan? {
        info.map { Unmanaged<PDFPanelScan>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func numbers(_ count: Int, in scanner: CGPDFScannerRef?) -> [CGFloat]? {
        guard let scanner else { return nil }
        var result = [CGFloat](repeating: 0, count: count)
        for index in result.indices.reversed() {
            guard CGPDFScannerPopNumber(scanner, &result[index]), result[index].isFinite else { return nil }
        }
        return result
    }

    private func save() { savedStates.append(state) }

    private func restore() {
        if let saved = savedStates.popLast() { state = saved }
    }

    private func concatenate(_ scanner: CGPDFScannerRef?) {
        guard let v = Self.numbers(6, in: scanner) else { return }
        let transform = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        state.transform = transform.concatenating(state.transform)
    }

    private func setLineWidth(_ scanner: CGPDFScannerRef?) {
        if let width = Self.numbers(1, in: scanner)?.first { state.lineWidth = max(0, width) }
    }

    private static func isWhite(_ scanner: CGPDFScannerRef?, components: Int) -> Bool? {
        guard let values = numbers(components, in: scanner) else { return nil }
        return components == 4 ? values.allSatisfy { $0 < 0.005 } : values.allSatisfy { $0 > 0.995 }
    }

    private func setFill(_ scanner: CGPDFScannerRef?, components: Int) {
        if let white = Self.isWhite(scanner, components: components) { state.whiteFill = white }
    }

    private func setStroke(_ scanner: CGPDFScannerRef?, components: Int) {
        if let white = Self.isWhite(scanner, components: components) { state.whiteStroke = white }
    }

    private func point(_ values: [CGFloat], at index: Int) -> CGPoint {
        CGPoint(x: values[index], y: values[index + 1]).applying(state.transform)
    }

    private func move(_ scanner: CGPDFScannerRef?) {
        guard let v = Self.numbers(2, in: scanner) else { return }
        let start = point(v, at: 0)
        path.move(to: start)
        subpathStart = start
        closed = false
    }

    private func line(_ scanner: CGPDFScannerRef?) {
        guard let v = Self.numbers(2, in: scanner), subpathStart != nil else { return }
        path.addLine(to: point(v, at: 0))
    }

    private func curve(_ scanner: CGPDFScannerRef?, firstAtCurrentPoint: Bool = false, secondAtEnd: Bool = false) {
        let count = firstAtCurrentPoint || secondAtEnd ? 4 : 6
        guard let v = Self.numbers(count, in: scanner), !path.isEmpty else { return }
        let end = point(v, at: v.count - 2)
        let first = firstAtCurrentPoint ? path.currentPoint : point(v, at: 0)
        let second = secondAtEnd ? end : point(v, at: v.count - 4)
        path.addCurve(to: end, control1: first, control2: second)
    }

    private func close() {
        path.closeSubpath()
        closed = true
    }

    private func rectangle(_ scanner: CGPDFScannerRef?) {
        guard let v = Self.numbers(4, in: scanner) else { return }
        path.addRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), transform: state.transform)
        subpathStart = path.currentPoint
        closed = true
    }

    private func finish(fill: Bool = false, stroke: Bool = false, evenOdd: Bool = false, close: Bool = false) {
        defer {
            path = CGMutablePath()
            subpathStart = nil
            closed = false
            updatesClip = false
        }
        if close { self.close() }
        let bounds = path.boundingBoxOfPath
        let visibleFill = fill && !state.whiteFill
        let visibleStroke = stroke && !state.whiteStroke
        if !bounds.isNull, !bounds.isInfinite, (bounds.width > 0 || bounds.height > 0),
           bounds.width.isFinite, bounds.height.isFinite,
           (visibleFill || visibleStroke) {
            let scale = max(hypot(state.transform.a, state.transform.b), hypot(state.transform.c, state.transform.d))
            let padding = stroke ? state.lineWidth * scale / 2 : 0
            let visible = bounds.insetBy(dx: -padding, dy: -padding).intersection(state.clip)

            let isClosedOrLoop = closed || subpathStart == path.currentPoint
            if visibleFill || (visibleStroke && isClosedOrLoop),
               !visible.isNull, visible.width >= state.clip.width * 0.08, visible.height >= 2 {
                let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
                // A rounded box still covers a grid inset from its corners, while a triangle
                // or illustration usually does not. Keep thin ribbon shapes for attachment too.
                let isPanel = [0.1, 0.5, 0.9].allSatisfy { x in
                    [0.1, 0.5, 0.9].allSatisfy { y in
                        path.contains(CGPoint(x: bounds.minX + bounds.width * x,
                                              y: bounds.minY + bounds.height * y), using: rule)
                    }
                }
                drawings.append(Drawing(bounds: visible, isPanel: isPanel))
            }

            var current = CGPoint.zero
            var startPt: CGPoint?
            var orthoSegments: [(CGPoint, CGPoint)] = []
            var hasCurves = false
            var hasDiagonal = false
            var hasCloseOp = false
            path.applyWithBlock { elementPtr in
                let element = elementPtr.pointee
                switch element.type {
                case .moveToPoint:
                    let pt = element.points[0]
                    current = pt
                    startPt = pt
                case .addLineToPoint:
                    let pt = element.points[0]
                    let dx = abs(pt.x - current.x), dy = abs(pt.y - current.y)
                    if dx > 0.5 && dy > 0.5 { hasDiagonal = true }
                    else if dx > 0.5 || dy > 0.5 { orthoSegments.append((current, pt)) }
                    current = pt
                case .addQuadCurveToPoint:
                    hasCurves = true
                    current = element.points[1]
                case .addCurveToPoint:
                    hasCurves = true
                    current = element.points[2]
                case .closeSubpath:
                    hasCloseOp = true
                    if let s = startPt {
                        let dx = abs(s.x - current.x), dy = abs(s.y - current.y)
                        if dx > 0.5 && dy > 0.5 { hasDiagonal = true }
                        current = s
                    }
                @unknown default:
                    break
                }
            }

            if visibleStroke && !visibleFill && !hasCloseOp && !isClosedOrLoop && !hasCurves && !hasDiagonal {
                let rulePad = max(padding, 0.25)
                for (a, b) in orthoSegments {
                    let seg = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                     width: abs(b.x - a.x), height: abs(b.y - a.y))
                        .insetBy(dx: -rulePad, dy: -rulePad)
                        .intersection(state.clip)
                    guard !seg.isNull else { continue }
                    if abs(b.y - a.y) <= 0.5 && abs(b.x - a.x) > 0.5 {
                        horizontalRules.append(seg)
                    } else if abs(b.x - a.x) <= 0.5 && abs(b.y - a.y) > 0.5 {
                        verticalRules.append(seg)
                    }
                }
            } else if !visible.isNull && (visible.width >= 1 || visible.height >= 1) {
                shapes.append(visible)
            }
        }
        if updatesClip { state.clip = state.clip.intersection(bounds) }
    }
}
