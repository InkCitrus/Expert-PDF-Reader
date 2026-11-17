import AppKit
import PDFKit

/// Screenshot pickers need the bounds of the visible ink, not PDFKit's font-run rectangles. Build a
/// small, stable tree for visible native-text pages; normal PDF links and scrollers remain available.
@MainActor
final class PDFContentAccessibility {
    private weak var pdfView: PDFView?
    private let pages = NSMapTable<PDFPage, GeometryElement>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    init(pdfView: PDFView) { self.pdfView = pdfView }

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

    func hitTest(_ point: NSPoint) -> Any? {
        guard let roots = children() else { return nil }
        func find(_ element: GeometryElement) -> GeometryElement? {
            guard element.accessibilityFrame().contains(point) else { return nil }
            for child in element.allChildren { if let found = find(child) { return found } }
            return element
        }
        return roots.compactMap { $0 as? GeometryElement }.compactMap(find).first
    }

    private func buildPage(_ page: PDFPage, geometry: NativePDFPageGeometry, in view: PDFView, index: Int) -> GeometryElement {
        let root = GeometryElement(page: page, rect: geometry.cropBox, view: view, role: .group, label: L10n.pageTitle(String(index + 1)))
        root.setAccessibilityParent(view)
        let heights = geometry.rows.map { $0.bounds.height }.sorted()
        let typical = heights.isEmpty ? 1 : heights[heights.count / 2]
        var blocks: [GeometryElement] = []
        for row in geometry.rows {
            let box = row.bounds
            let start = CGPoint(x: box.minX - 1, y: box.midY), end = CGPoint(x: box.maxX + 1, y: box.midY)
            let native = page.selection(from: start, to: end)
            let text = native.flatMap { original in
                NativePDFSelection.corrected(original, in: page.document!, from: page, at: start, to: page, at: end, force: true)?.text.string
            } ?? native?.string ?? ""
            let clean = PDFTextCleanup.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let line = GeometryElement(page: page, rect: box, view: view, role: .staticText, label: nil)
            line.setAccessibilityValue(clean)
            let block: GeometryElement
            if let previous = blocks.last, let lastLine = previous.allChildren.last,
               box.height <= typical * 3, lastLine.pageRect.height <= typical * 3,
               lastLine.pageRect.minY - box.maxY >= 0, lastLine.pageRect.minY - box.maxY <= typical * 1.5,
               lastLine.pageRect.intersection(CGRect(x: box.minX, y: lastLine.pageRect.minY, width: box.width, height: lastLine.pageRect.height)).width > 0 {
                block = previous
                block.pageRect = block.pageRect.union(box)
            } else {
                block = GeometryElement(page: page, rect: box, view: view, role: .group, label: nil)
                block.setAccessibilityParent(root)
                blocks.append(block)
            }
            line.setAccessibilityParent(block)
            block.allChildren.append(line)
            block.setAccessibilityChildren(block.allChildren)
        }
        for annotation in page.annotations where annotation.action != nil {
            let link = GeometryElement(page: page, rect: annotation.bounds, view: view, role: .link,
                label: annotation.contents ?? (annotation.action as? PDFActionURL)?.url?.absoluteString)
            link.annotation = annotation
            link.setAccessibilityParent(root)
            blocks.append(link)
        }
        root.allChildren = blocks
        root.setAccessibilityChildren(blocks)
        return root
    }

    final class GeometryElement: NSAccessibilityElement {
        weak var page: PDFPage?
        weak var view: PDFView?
        weak var annotation: PDFAnnotation?
        var pageRect: CGRect
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
                  page.document === view.document else { return .zero }
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
