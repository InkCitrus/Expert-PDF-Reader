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

    private struct LineMetrics {
        let cropWidth: CGFloat
        let typicalHeight: CGFloat
        let typicalStep: CGFloat

        init(rows: [NativePDFPageGeometry.Row], cropBox: CGRect) {
            let cw = max(1, cropBox.width)
            let rowRects = rows.map(\.bounds)
            let substantive = rowRects.filter { $0.width >= cw * 0.15 }
            let basis = substantive.isEmpty ? rowRects : substantive
            let heights = basis.map(\.height).sorted()
            let th = heights.isEmpty ? 10 : max(1, heights[heights.count / 2])

            let ordered = basis.sorted { $0.midY > $1.midY }
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
            self.typicalStep = steps.isEmpty
                ? th * 1.45
                : steps[Int(Double(steps.count - 1) * 0.4)]
        }
    }

    private func buildPage(_ page: PDFPage, geometry: NativePDFPageGeometry, in view: PDFView, index: Int) -> GeometryElement {
        let root = GeometryElement(page: page, rect: geometry.cropBox, view: view, role: .group, label: L10n.pageTitle(String(index + 1)))
        root.setAccessibilityParent(view)
        let metrics = LineMetrics(rows: geometry.rows, cropBox: geometry.cropBox)
        let regions = PDFFramedRegions.regions(on: page, geometry: geometry)
        func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        let parents: [Int?] = regions.indices.map { i in
            let inner = regions[i].bounds
            return regions.indices.filter { j in
                j != i && regions[j].kind != .figure && area(regions[j].bounds) > area(inner)
                    && regions[j].bounds.insetBy(dx: -1, dy: -1).contains(inner)
            }.min { area(regions[$0].bounds) < area(regions[$1].bounds) }
        }
        var regionLines = regions.map { _ in [GeometryElement]() }
        var figureLabels = regions.map { _ in [String]() }
        var plainLines: [GeometryElement] = []
        for row in geometry.rows {
            for (frame, row) in Self.split(row, across: regions) {
                let clean = geometry.text(for: row, on: page)
                guard !clean.isEmpty else { continue }
                if let frame, regions[frame].kind == .figure {
                    figureLabels[frame].append(clean)
                    continue
                }
                let bounds = frame.map { row.bounds.intersection(regions[$0].bounds) } ?? row.bounds
                let line = GeometryElement(page: page, rect: bounds, view: view, role: .staticText, label: nil)
                line.setAccessibilityValue(clean)
                if let frame { regionLines[frame].append(line) }
                else { plainLines.append(line) }
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
                let children = (regionLines[i] + childRegions[i]).sorted {
                    if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                    return $0.pageRect.maxY > $1.pageRect.maxY
                }
                built = children.isEmpty ? nil : region(with: children, bounds: item.bounds, on: page, in: view,
                                                        roleDescription: L10n.tr("表格", "Table"))
            } else {
                let groupedLines = partitionBlocks(
                    for: regionLines[i],
                    in: item.bounds,
                    obstacles: childRegions[i].map(\.pageRect),
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
            for: plainLines,
            in: geometry.cropBox,
            obstacles: topRegions.map(\.pageRect),
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
    /// with a margin note or sits inside a nested sub-region. Assign each glyph to its smallest enclosing region.
    private static func split(_ row: NativePDFPageGeometry.Row, across regions: [PDFFramedRegions.Region])
        -> [(Int?, NativePDFPageGeometry.Row)] {
        guard !regions.isEmpty else { return [(nil, row)] }
        func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        var runs: [(frame: Int?, glyphs: [NativePDFPageGeometry.Glyph])] = []
        for glyph in row.glyphs {
            let center = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
            let frame = regions.indices
                .filter { regions[$0].bounds.contains(center) }
                .min { area(regions[$0].bounds) < area(regions[$1].bounds) }
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

    /// Partition lines in `containerBounds` into coherent 2D reading blocks (single- or multi-column
    /// paragraphs, indented blocks, and stacked equations) using purely geometric metrics and alignment.
    private func partitionBlocks(
        for lines: [GeometryElement],
        in containerBounds: CGRect,
        obstacles: [CGRect],
        metrics: LineMetrics,
        on page: PDFPage,
        in view: PDFView
    ) -> [GeometryElement] {
        guard !lines.isEmpty else { return [] }
        let ordered = lines.sorted { a, b in
            if a.pageRect.midY != b.pageRect.midY { return a.pageRect.midY > b.pageRect.midY }
            return a.pageRect.minX < b.pageRect.minX
        }
        let th = metrics.typicalHeight
        let containerWidth = max(1, containerBounds.width)
        func isTinyFragment(_ rect: CGRect) -> Bool {
            rect.width <= th * 3.5 && rect.height <= th * 0.7
        }

        let wideRects = ordered.map(\.pageRect).filter { !isTinyFragment($0) && $0.width >= containerWidth * 0.35 }
        func localColumnRight(for upper: CGRect, _ lower: CGRect) -> CGFloat {
            let spanMinX = min(upper.minX, lower.minX), spanMaxX = max(upper.maxX, lower.maxX)
            let matching = wideRects.filter { rect in
                max(rect.minX, spanMinX) < min(rect.maxX, spanMaxX)
                    && abs(rect.minX - upper.minX) <= containerWidth * 0.25
            }
            if let maxR = matching.map(\.maxX).max() { return maxR }
            return wideRects.map(\.maxX).max() ?? containerBounds.maxX
        }

        var blocks: [[GeometryElement]] = []
        var closedBlocks = Set<Int>()
        var pendingFragments: [GeometryElement] = []

        func attachPendingFragments(to blockIndex: Int, targetRect: CGRect) {
            guard !pendingFragments.isEmpty else { return }
            var remaining: [GeometryElement] = []
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

        for line in ordered {
            let rect = line.pageRect
            if isTinyFragment(rect),
               let match = blocks.indices.reversed().first(where: { idx in
                   guard !closedBlocks.contains(idx),
                         let anchor = blocks[idx].last(where: { !isTinyFragment($0.pageRect) })?.pageRect else { return false }
                   let vGap = max(0, max(rect.minY - anchor.maxY, anchor.minY - rect.maxY))
                   return vGap <= th * 0.25 && rect.midX >= anchor.minX - th && rect.midX <= anchor.maxX + th
               }) {
                blocks[match].append(line)
                continue
            }

            // Flush stale pending fragments before processing the next normal line.
            if !pendingFragments.isEmpty {
                var kept: [GeometryElement] = []
                for frag in pendingFragments {
                    if frag.pageRect.minY - rect.maxY > th * 0.25 {
                        if let match = blocks.indices.reversed().first(where: { idx in
                            guard !closedBlocks.contains(idx) else { return false }
                            let colRight = blocks[idx].last.map { localColumnRight(for: $0.pageRect, frag.pageRect) } ?? containerBounds.maxX
                            return Self.canContinueBlock(
                                blocks[idx],
                                with: frag.pageRect,
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

            if isTinyFragment(rect) {
                pendingFragments.append(line)
                continue
            }

            if let match = blocks.indices.reversed().first(where: { idx in
                guard !closedBlocks.contains(idx) else { return false }
                let colRight = blocks[idx].last(where: { !isTinyFragment($0.pageRect) }).map { localColumnRight(for: $0.pageRect, rect) } ?? containerBounds.maxX
                return Self.canContinueBlock(
                    blocks[idx],
                    with: rect,
                    isFragment: isTinyFragment,
                    obstacles: obstacles,
                    containerWidth: containerWidth,
                    columnRight: colRight,
                    metrics: metrics
                )
            }) {
                attachPendingFragments(to: match, targetRect: rect)
                blocks[match].append(line)
            } else {
                for idx in blocks.indices where !closedBlocks.contains(idx) {
                    if let lastRect = blocks[idx].last(where: { !isTinyFragment($0.pageRect) })?.pageRect,
                       max(lastRect.minX, rect.minX) < min(lastRect.maxX, rect.maxX) {
                        closedBlocks.insert(idx)
                    }
                }
                blocks.append([line])
                attachPendingFragments(to: blocks.count - 1, targetRect: rect)
            }
        }

        for frag in pendingFragments {
            if let match = blocks.indices.reversed().first(where: { idx in
                guard !closedBlocks.contains(idx) else { return false }
                let colRight = blocks[idx].last.map { localColumnRight(for: $0.pageRect, frag.pageRect) } ?? containerBounds.maxX
                return Self.canContinueBlock(
                    blocks[idx],
                    with: frag.pageRect,
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
            let orderedMembers = members.sorted {
                if $0.pageRect.maxY == $1.pageRect.maxY { return $0.pageRect.minX < $1.pageRect.minX }
                return $0.pageRect.maxY > $1.pageRect.maxY
            }
            guard orderedMembers.count > 1 else { return orderedMembers[0] }
            let bounds = orderedMembers.reduce(CGRect.null) { $0.union($1.pageRect) }
            let group = region(with: orderedMembers, bounds: bounds, on: page, in: view,
                               roleDescription: L10n.tr("段落", "Paragraph"))
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
    /// hanging indent, and centered stacked blocks).
    private static func canContinueBlock(
        _ block: [GeometryElement],
        with lower: CGRect,
        isFragment: (CGRect) -> Bool,
        obstacles: [CGRect],
        containerWidth: CGFloat,
        columnRight: CGFloat,
        metrics: LineMetrics
    ) -> Bool {
        let substantive = block.map(\.pageRect).filter { !isFragment($0) }
        guard let upper = substantive.last ?? block.last?.pageRect else { return false }
        let lineHeight = min(upper.height, lower.height)
        guard lineHeight > 0, lower.height > 0,
              max(upper.minX, lower.minX) < min(upper.maxX, lower.maxX) else { return false }

        let th = metrics.typicalHeight
        let step = metrics.typicalStep
        let dyMid = upper.midY - lower.midY
        let gap = upper.minY - lower.maxY
        let maxGap = max(th * 1.35, (step - th) * 1.65)
        guard dyMid >= th * 0.45, dyMid <= step * 1.32,
              gap >= -th * 0.35, gap <= maxGap else { return false }

        // Prevent mixing display headings with body lines while permitting short descenderless endings
        // and inline math expressions within body height range.
        if (substantive.count == 1 && upper.height > th * 1.22 && upper.height > lower.height * 1.18)
            || (lower.height > th * 1.22 && lower.height > upper.height * 1.18) {
            return false
        }
        guard max(upper.height, lower.height) <= max(lineHeight * 2.15, th * 1.65) else { return false }

        let spanMinX = min(upper.minX, lower.minX), spanMaxX = max(upper.maxX, lower.maxX)
        let blocked = obstacles.contains { box in
            ((box.maxY <= upper.minY + th * 0.25 && box.minY >= lower.maxY - th * 0.25)
                || (box.midY < upper.midY && box.midY > lower.midY))
                && max(box.minX, spanMinX) < min(box.maxX, spanMaxX)
        }
        guard !blocked else { return false }

        let alignTol = th * 0.75
        let maxIndent = th * 3.5
        let subCount = substantive.count
        let bodyMinX = subCount >= 2 ? (substantive.dropFirst().map(\.minX).min() ?? upper.minX) : upper.minX

        // 1. Flush left (or continuing the established body margin below an indented opening line).
        if abs(lower.minX - upper.minX) <= alignTol
            || (subCount >= 2 && abs(lower.minX - bodyMinX) <= alignTol) {
            return true
        }
        // 2. Flush right (justified prose or right-aligned equations).
        if abs(lower.maxX - upper.maxX) <= alignTol {
            return true
        }
        // 3. First-line paragraph indent returning to the body left margin.
        let leftDelta = upper.minX - lower.minX
        if subCount == 1 && leftDelta > alignTol && leftDelta <= maxIndent
            && (upper.width >= containerWidth * 0.32 || upper.maxX >= lower.maxX - maxIndent) {
            return true
        }
        // 4. Hanging indent (first line wraps across to column right edge, continuation is indented).
        let hangingDelta = lower.minX - upper.minX
        if subCount == 1 && hangingDelta > alignTol && hangingDelta <= maxIndent
            && upper.maxX >= max(lower.maxX, columnRight) - maxIndent {
            return true
        }
        // 5. Centered stacked equation or multi-line formula block.
        let hOverlap = min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX)
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
