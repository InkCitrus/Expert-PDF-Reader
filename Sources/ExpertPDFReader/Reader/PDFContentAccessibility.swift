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
            element.setAccessibilityChildren(element.allChildren.filter { !$0.accessibilityFrame().isEmpty })
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
        guard let page = roots.lazy.compactMap({ $0 as? GeometryElement })
            .first(where: { $0.accessibilityFrame().contains(point) }) else { return nil }
        // Links follow text in the accessibility tree. Prefer the link when its frame overlaps text.
        return page.allChildren.reversed().first { $0.accessibilityFrame().contains(point) } ?? page
    }

    private func buildPage(_ page: PDFPage, geometry: NativePDFPageGeometry, in view: PDFView, index: Int) -> GeometryElement {
        let root = GeometryElement(page: page, rect: geometry.cropBox, view: view, role: .group, label: L10n.pageTitle(String(index + 1)))
        root.setAccessibilityParent(view)
        // Each row is a separate candidate for element-based screenshot tools. Grouping adjacent
        // lines into a paragraph can offer a rectangle that includes the rows above and below it.
        var elements: [GeometryElement] = []
        for row in geometry.rows {
            let clean = geometry.text(for: row, on: page)
            guard !clean.isEmpty else { continue }
            let line = GeometryElement(page: page, rect: row.bounds, view: view, role: .staticText, label: nil)
            line.setAccessibilityValue(clean)
            line.setAccessibilityParent(root)
            elements.append(line)
        }
        for annotation in page.annotations where annotation.action != nil {
            let link = GeometryElement(page: page, rect: annotation.bounds, view: view, role: .link,
                label: annotation.contents ?? (annotation.action as? PDFActionURL)?.url?.absoluteString)
            link.annotation = annotation
            link.setAccessibilityParent(root)
            elements.append(link)
        }
        root.allChildren = elements
        return root
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
