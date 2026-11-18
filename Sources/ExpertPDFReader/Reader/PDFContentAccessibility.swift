import AppKit
import PDFKit
import ObjectiveC

/// Screenshot pickers need the bounds of the visible ink, not PDFKit's font-run rectangles. Build a
/// small, stable tree for visible native-text pages; normal PDF links and scrollers remain available.
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
            if object is GeometryElement { return nil }
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
              !view.visiblePages.isEmpty,
              view.visiblePages.allSatisfy({ $0.rotation % 360 == 0 && !PDFSelectionVisibility.requiresVisualSelection(on: $0) }) else { return nil }
        var result: [Any] = []
        for page in view.visiblePages.sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
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

    private func buildPage(_ page: PDFPage, geometry: NativePDFPageGeometry, in view: PDFView, index: Int) -> GeometryElement {
        let root = GeometryElement(page: page, rect: geometry.cropBox, view: view, role: .group, label: L10n.pageTitle(String(index + 1)))
        root.setAccessibilityParent(view)
        let frames = PDFFramedRegions.bounds(on: page, geometry: geometry)
        var framedLines = frames.map { _ in [GeometryElement]() }
        var plainLines: [GeometryElement] = []
        for row in geometry.rows {
            for (frame, row) in Self.split(row, across: frames) {
                let clean = geometry.text(for: row, on: page)
                guard !clean.isEmpty else { continue }
                let bounds = frame.map { row.bounds.intersection(frames[$0]) } ?? row.bounds
                let line = GeometryElement(page: page, rect: bounds, view: view, role: .staticText, label: nil)
                line.setAccessibilityValue(clean)
                if let frame { framedLines[frame].append(line) }
                else { plainLines.append(line) }
            }
        }
        var elements = paragraphRegions(for: plainLines, on: page, in: view)
        for (frame, lines) in zip(frames, framedLines) where !lines.isEmpty {
            elements.append(region(with: lines, bounds: frame, on: page, in: view))
        }
        if !frames.isEmpty {
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
    /// with a margin note. Give each region only the ink inside its own border.
    private static func split(_ row: NativePDFPageGeometry.Row, across frames: [CGRect])
        -> [(Int?, NativePDFPageGeometry.Row)] {
        guard !frames.isEmpty else { return [(nil, row)] }
        var runs: [(frame: Int?, glyphs: [NativePDFPageGeometry.Glyph])] = []
        for glyph in row.glyphs {
            let center = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
            let frame = frames.firstIndex { $0.contains(center) }
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

    private func paragraphRegions(for lines: [GeometryElement], on page: PDFPage, in view: PDFView) -> [GeometryElement] {
        var paragraphs: [[GeometryElement]] = []
        for line in lines {
            if let previous = paragraphs.last?.last, Self.canShareRegion(previous.pageRect, line.pageRect) {
                paragraphs[paragraphs.count - 1].append(line)
            } else {
                paragraphs.append([line])
            }
        }
        return paragraphs.map { lines in
            guard lines.count > 1 else { return lines[0] }
            let bounds = lines.reduce(CGRect.null) { $0.union($1.pageRect) }
            return region(with: lines, bounds: bounds, on: page, in: view)
        }
    }

    private func region(with lines: [GeometryElement], bounds: CGRect, on page: PDFPage, in view: PDFView) -> GeometryElement {
        let group = GeometryElement(page: page, rect: bounds, view: view, role: .group, label: nil)
        group.allChildren = lines
        for line in lines { line.setAccessibilityParent(group) }
        return group
    }

    /// Compare neighboring ink boxes. Leading may be as tall as the visible ink on an ordinary
    /// line. A shared edge and similar ink heights help distinguish a paragraph from a new block.
    private static func canShareRegion(_ upper: CGRect, _ lower: CGRect) -> Bool {
        let lineHeight = min(upper.height, lower.height)
        let gap = upper.minY - lower.maxY
        guard lineHeight > 0, max(upper.height, lower.height) <= lineHeight * 1.35,
              gap >= -lineHeight * 0.2, gap <= lineHeight * 1.15,
              max(upper.minX, lower.minX) < min(upper.maxX, lower.maxX) else { return false }
        let edgeDistance = min(abs(upper.minX - lower.minX), abs(upper.maxX - lower.maxX))
        return edgeDistance <= lineHeight * 0.6
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
            allChildren.isEmpty ? nil : allChildren.filter { !$0.accessibilityFrame().isEmpty }
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
