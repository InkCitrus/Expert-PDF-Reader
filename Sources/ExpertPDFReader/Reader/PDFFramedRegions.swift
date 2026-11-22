import CoreGraphics
import PDFKit

/// Locate vector panels that enclose text, including attached heading ribbons.
@MainActor
enum PDFFramedRegions {
    static func bounds(on page: PDFPage, geometry: NativePDFPageGeometry) -> [CGRect] {
        guard let source = page.pageRef, !geometry.rows.isEmpty else { return [] }
        let crop = geometry.cropBox
        let heights = geometry.rows.map { $0.bounds.height }.sorted()
        let inkHeight = heights[heights.count / 2]
        let drawings = PDFPanelScan.drawings(on: source, clippedTo: crop)
        let panels = drawings.filter { drawing in
            let box = drawing.bounds
            guard drawing.isPanel, box.width >= max(inkHeight * 6, crop.width * 0.16),
                  box.height >= inkHeight * 2, box.height < crop.height * 0.85 else { return false }
            return geometry.rows.lazy.filter { row in
                box.contains(row.bounds.center) || row.glyphs.contains { box.contains($0.bounds.center) }
            }.prefix(2).count == 2
        }.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }

        var result: [CGRect] = []
        for panel in panels {
            let body = panel.bounds
            // A frame is often several overpainted rectangles. Keep the outside border.
            guard !result.contains(where: { $0.contains(body) }) else { continue }
            var box = body
            for drawing in drawings {
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
                if title { box = box.union(ribbon) }
            }
            result.append(box)
        }
        return result
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Quartz supplies parsed PDF operands. Only collect the paths used to paint panel shapes.
private final class PDFPanelScan {
    struct Drawing {
        let bounds: CGRect
        let isPanel: Bool
    }

    struct GraphicsState {
        var transform = CGAffineTransform.identity
        var clip: CGRect
        var lineWidth: CGFloat = 1
        var whiteFill = false
    }

    private var state: GraphicsState
    private var savedStates: [GraphicsState] = []
    private var path = CGMutablePath()
    private var subpathStart: CGPoint?
    private var closed = false
    private var updatesClip = false
    private var drawings: [Drawing] = []

    private init(crop: CGRect) {
        state = GraphicsState(clip: crop)
    }

    static func drawings(on page: CGPDFPage, clippedTo crop: CGRect) -> [Drawing] {
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        defer { CGPDFOperatorTableRelease(table) }
        let callbacks: [(String, CGPDFOperatorCallback)] = [
            ("q", { _, info in PDFPanelScan.instance(info)?.save() }),
            ("Q", { _, info in PDFPanelScan.instance(info)?.restore() }),
            ("cm", { scanner, info in PDFPanelScan.instance(info)?.concatenate(scanner) }),
            ("w", { scanner, info in PDFPanelScan.instance(info)?.setLineWidth(scanner) }),
            ("g", { scanner, info in PDFPanelScan.instance(info)?.setFill(scanner, components: 1) }),
            ("rg", { scanner, info in PDFPanelScan.instance(info)?.setFill(scanner, components: 3) }),
            ("k", { scanner, info in PDFPanelScan.instance(info)?.setFill(scanner, components: 4) }),
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
        return CGPDFScannerScan(scanner) ? scan.drawings : []
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

    private func setFill(_ scanner: CGPDFScannerRef?, components: Int) {
        guard let values = Self.numbers(components, in: scanner) else { return }
        state.whiteFill = components == 4
            ? values.allSatisfy { $0 < 0.005 }
            : values.allSatisfy { $0 > 0.995 }
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
        if !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
           (fill && !state.whiteFill || stroke && (closed || subpathStart == path.currentPoint)) {
            let scale = max(hypot(state.transform.a, state.transform.b), hypot(state.transform.c, state.transform.d))
            let padding = stroke ? state.lineWidth * scale / 2 : 0
            let visible = bounds.insetBy(dx: -padding, dy: -padding).intersection(state.clip)
            if !visible.isNull, visible.width >= state.clip.width * 0.08, visible.height >= 2 {
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
        }
        if updatesClip { state.clip = state.clip.intersection(bounds) }
    }
}
