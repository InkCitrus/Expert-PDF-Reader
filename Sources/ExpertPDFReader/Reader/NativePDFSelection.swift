import AppKit
import PDFKit

/// A PDF's drawing order need not follow its visual reading order. Keep native selection unless
/// it includes physical lines outside the user's drag, then build ranges from page geometry.
@MainActor
enum NativePDFSelection {
    struct Result {
        let selection: PDFSelection
        let text: NSAttributedString
    }

    static func corrected(_ original: PDFSelection, in document: PDFDocument,
                          from startPage: PDFPage, at start: CGPoint,
                          to endPage: PDFPage, at end: CGPoint) -> Result? {
        var first = (page: startPage, point: start), last = (page: endPage, point: end)
        if document.index(for: first.page) > document.index(for: last.page)
            || (first.page === last.page && first.point.y < last.point.y) {
            swap(&first, &last)
        }
        let a = document.index(for: first.page), b = document.index(for: last.page)
        let originalLines = original.selectionsByLine()
        func lineBounds(on page: PDFPage, at point: CGPoint) -> CGRect? {
            if let line = page.selectionForLine(at: point) {
                let bounds = line.bounds(for: page)
                if !bounds.isEmpty && !bounds.isInfinite && !bounds.isNull { return bounds }
            }
            // A drag may end in the margin after the final character of a line.
            return originalLines.filter { $0.pages.contains { $0 === page } }.map { $0.bounds(for: page) }
                .filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }.min {
                func distance(_ box: CGRect) -> CGFloat {
                    let dx = max(0, max(box.minX - point.x, point.x - box.maxX))
                    let dy = max(0, max(box.minY - point.y, point.y - box.maxY))
                    return dx * dx + dy * dy
                }
                return distance($0) < distance($1)
            }
        }
        guard (0..<document.pageCount).contains(a), (a..<document.pageCount).contains(b),
              let firstLine = lineBounds(on: first.page, at: first.point),
              let lastLine = lineBounds(on: last.page, at: last.point) else { return nil }
        func verticalRange(on page: PDFPage) -> ClosedRange<CGFloat> {
            let box = page.bounds(for: .cropBox)
            let lower = page === last.page ? lastLine.minY : box.minY
            let upper = page === first.page ? firstLine.maxY : box.maxY
            // The nearest-line fallback can resolve a "first" line below the "last" line, inverting the
            // span; normalize so forming the closed range never traps.
            return min(lower, upper)...max(lower, upper)
        }
        let outside = originalLines.contains { line in
            line.pages.contains { page in
                let index = document.index(for: page)
                guard (a...b).contains(index) else { return true }
                let bounds = line.bounds(for: page), allowed = verticalRange(on: page)
                return !bounds.isEmpty && (bounds.maxY < allowed.lowerBound || bounds.minY > allowed.upperBound)
            }
        }
        guard outside else { return nil }
        let selection = PDFSelection(document: document)
        for index in a...b {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let top = page === first.page ? firstLine : CGRect(x: box.minX, y: box.maxY, width: box.width, height: 0)
            let bottom = page === last.page ? lastLine : CGRect(x: box.minX, y: box.minY, width: box.width, height: 0)
            var rects: [CGRect] = []
            if first.page === last.page && firstLine.minY <= lastLine.maxY && lastLine.minY <= firstLine.maxY {
                rects = [CGRect(x: min(start.x, end.x), y: min(firstLine.minY, lastLine.minY),
                                width: abs(start.x - end.x), height: max(firstLine.maxY, lastLine.maxY) - min(firstLine.minY, lastLine.minY))]
            } else {
                if page === first.page {
                    rects.append(CGRect(x: first.point.x, y: top.minY, width: box.maxX - first.point.x, height: top.height))
                }
                rects.append(CGRect(x: box.minX, y: bottom.maxY, width: box.width, height: max(0, top.minY - bottom.maxY)))
                if page === last.page {
                    rects.append(CGRect(x: box.minX, y: bottom.minY, width: last.point.x - box.minX, height: bottom.height))
                }
            }
            for rect in rects where rect.width > 0 && rect.height > 0 {
                if let part = page.selection(for: rect.intersection(box)) { selection.add(part) }
            }
        }
        guard selection.string?.isEmpty == false else { return nil }
        let text = NSMutableAttributedString(string: "")
        for index in a...b {
            guard let page = document.page(at: index) else { continue }
            let fragments = selection.selectionsByLine().filter { $0.pages.contains { $0 === page } }
                .sorted { $0.bounds(for: page).midY > $1.bounds(for: page).midY }
            var rows: [(bounds: CGRect, parts: [PDFSelection])] = []
            for fragment in fragments {
                let bounds = fragment.bounds(for: page)
                if let row = rows.indices.last, rows[row].bounds.minY <= bounds.midY,
                   rows[row].bounds.maxY >= bounds.midY, bounds.minY <= rows[row].bounds.midY,
                   bounds.maxY >= rows[row].bounds.midY {
                    rows[row].parts.append(fragment)
                    rows[row].bounds = rows[row].bounds.union(bounds)
                } else { rows.append((bounds, [fragment])) }
            }
            for row in rows {
                if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
                for fragment in row.parts.sorted(by: { $0.bounds(for: page).minX < $1.bounds(for: page).minX }) {
                    let raw = fragment.attributedString ?? NSAttributedString(string: fragment.string ?? "")
                    let trimmed = raw.string.trimmingCharacters(in: .newlines)
                    guard !trimmed.isEmpty else { continue }
                    let part = raw.attributedSubstring(from: (raw.string as NSString).range(of: trimmed))
                    if text.length > 0, let previous = text.string.last, !previous.isWhitespace,
                       let next = part.string.first, !next.isWhitespace { text.append(NSAttributedString(string: " ")) }
                    text.append(part)
                }
            }
        }
        return Result(selection: selection, text: PDFTextCleanup.normalize(text))
    }
}

/// Observes normal PDFKit mouse tracking rather than replacing its click, word-selection or link handling.
@MainActor
final class NativePDFSelectionTracker {
    private weak var pdfView: PDFView?
    private struct Gesture {
        let id = UUID()
        let document: PDFDocument
        let page: PDFPage
        let point: CGPoint
        var endPage: PDFPage
        var endPoint: CGPoint
    }
    private var gesture: Gesture?
    private var lastMouseDown: TimeInterval?
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var isRepairing = false
    private var repairedSelection: PDFSelection?
    private var repairedText: NSAttributedString?
    private var nativeText: String?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        observer = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.track(event) }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func begin(_ event: NSEvent) {
        guard lastMouseDown != event.timestamp else { return }
        lastMouseDown = event.timestamp
        gesture = nil
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .control, .command, .option]).isEmpty,
              let pdfView, let document = pdfView.document else { return }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: false), page.rotation % 360 == 0 else { return }
        let location = pdfView.convert(point, to: page)
        gesture = Gesture(document: document, page: page, point: location, endPage: page, endPoint: location)
    }

    private func track(_ event: NSEvent) {
        guard let pdfView, let current = gesture, event.windowNumber == pdfView.window?.windowNumber,
              pdfView.document === current.document else { return }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        if let page = pdfView.page(for: point, nearest: true) {
            gesture?.endPage = page
            gesture?.endPoint = pdfView.convert(point, to: page)
        }
        if event.type == .leftMouseUp {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.gesture?.id == current.id else { return }
                self.repair()
                self.gesture = nil
            }
        }
    }

    private func selectionChanged() {
        guard !isRepairing, let pdfView else { return }
        if repairedSelection === pdfView.currentSelection, nativeText == pdfView.currentSelection?.string { return }
        repairedText = nil
        repairedSelection = nil
        repair()
    }

    private func repair() {
        guard !isRepairing, let pdfView, let gesture, let original = pdfView.currentSelection,
              let result = NativePDFSelection.corrected(original, in: gesture.document, from: gesture.page,
                  at: gesture.point, to: gesture.endPage, at: gesture.endPoint) else { return }
        isRepairing = true
        pdfView.setCurrentSelection(result.selection, animate: false)
        repairedSelection = pdfView.currentSelection
        nativeText = pdfView.currentSelection?.string
        repairedText = result.text
        isRepairing = false
    }

    func copyIfCorrected(to pasteboard: NSPasteboard) -> Bool {
        guard let text = repairedText, repairedSelection === pdfView?.currentSelection,
              nativeText == pdfView?.currentSelection?.string, pdfView?.document?.allowsCopying == true else { return false }
        let item = NSPasteboardItem()
        item.setString(text.string, forType: .string)
        if let rtf = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) { item.setData(rtf, forType: .rtf) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return true
    }
}
