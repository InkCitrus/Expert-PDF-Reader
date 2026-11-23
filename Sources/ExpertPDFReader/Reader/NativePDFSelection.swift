import AppKit
import PDFKit

@MainActor
enum NativePDFSelection {
    struct Highlight {
        let page: PDFPage
        let rect: CGRect
    }
    struct Result {
        let selection: PDFSelection
        let text: NSAttributedString
        let highlights: [Highlight]
    }

    static func corrected(_ original: PDFSelection, in document: PDFDocument,
                          from startPage: PDFPage, at start: CGPoint,
                          to endPage: PDFPage, at end: CGPoint, force: Bool = false) -> Result? {
        var first = (page: startPage, point: start), last = (page: endPage, point: end)
        let startIndex = document.index(for: first.page), endIndex = document.index(for: last.page)
        guard (0..<document.pageCount).contains(startIndex), (0..<document.pageCount).contains(endIndex),
              first.page.rotation % 360 == 0, last.page.rotation % 360 == 0 else { return nil }
        if startIndex > endIndex || (startPage === endPage && start.y < end.y) { swap(&first, &last) }
        let firstGeometry = NativePDFPageGeometry.geometry(for: first.page)
        let lastGeometry = first.page === last.page ? firstGeometry : NativePDFPageGeometry.geometry(for: last.page)
        guard var firstRow = firstGeometry.nearestRow(to: first.point),
              var lastRow = lastGeometry.nearestRow(to: last.point) else { return nil }
        if first.page === last.page, firstRow > lastRow {
            swap(&first, &last)
            swap(&firstRow, &lastRow)
        }
        let selection = PDFSelection(document: document)
        let text = NSMutableAttributedString(string: "")
        var highlights: [Highlight] = []
        var outside = false
        var reordered = false
        var missingFromNative = false
        for index in document.index(for: first.page)...document.index(for: last.page) {
            guard let page = document.page(at: index) else { continue }
            let geometry = NativePDFPageGeometry.geometry(for: page)
            let lo = page === first.page ? firstRow : 0
            let hi = page === last.page ? lastRow : geometry.rows.count - 1
            guard lo <= hi, geometry.rows.indices.contains(lo), geometry.rows.indices.contains(hi) else { continue }
            let pageText = (page.string ?? "") as NSString
            var wanted = IndexSet()
            var wantedNonWS = IndexSet()
            var selectedLocations: [Int] = []
            for rowIndex in lo...hi {
                let row = geometry.rows[rowIndex]
                let sameRow = first.page === last.page && firstRow == lastRow
                let left = sameRow ? min(start.x, end.x) : (page === first.page && rowIndex == lo ? first.point.x : -CGFloat.infinity)
                let right = sameRow ? max(start.x, end.x) : (page === last.page && rowIndex == hi ? last.point.x : CGFloat.infinity)
                let glyphs = row.glyphs.filter { $0.bounds.midX >= left && $0.bounds.midX <= right }
                guard !glyphs.isEmpty else { continue }
                let rect = glyphs.dropFirst().reduce(glyphs[0].bounds) { $0.union($1.bounds) }
                highlights.append(Highlight(page: page, rect: rect))
                var rowRanges = IndexSet()
                for glyph in glyphs {
                    var firstNonWS: Int?
                    for range in glyph.ranges {
                        let rangeLo = max(0, range.location), rangeHi = min(pageText.length, NSMaxRange(range))
                        rowRanges.insert(integersIn: range.location..<NSMaxRange(range))
                        guard rangeLo < rangeHi else { continue }
                        for loc in rangeLo..<rangeHi {
                            let unit = pageText.character(at: loc)
                            if let scalar = UnicodeScalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                            wantedNonWS.insert(loc)
                            if firstNonWS == nil { firstNonWS = loc }
                        }
                    }
                    if let firstNonWS { selectedLocations.append(firstNonWS) }
                }
                wanted.formUnion(rowRanges)
                if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
                // Keep physical order even when native drawing commands interleave text runs.
                var seen = IndexSet(), runs: [(Range<Int>, CGRect)] = []
                for glyph in glyphs {
                    for nativeRange in glyph.ranges {
                        let fresh = IndexSet(integersIn: nativeRange.location..<NSMaxRange(nativeRange)).subtracting(seen)
                        for range in fresh.rangeView {
                            if let previous = runs.last, previous.0.upperBound == range.lowerBound {
                                runs[runs.count - 1] = (previous.0.lowerBound..<range.upperBound, previous.1.union(glyph.bounds))
                            } else { runs.append((range, glyph.bounds)) }
                        }
                        seen.formUnion(fresh)
                    }
                }
                var previousBounds: CGRect?
                for (range, runBounds) in runs {
                    if let part = page.selection(for: NSRange(location: range.lowerBound, length: range.count)) {
                        selection.add(part)
                        let raw = part.attributedString ?? NSAttributedString(string: part.string ?? "")
                        let trimmed = raw.string.trimmingCharacters(in: .newlines)
                        if !trimmed.isEmpty {
                            if let previous = text.string.last, !previous.isWhitespace,
                               let next = trimmed.first, !next.isWhitespace, let previousBounds,
                               runBounds.minX - previousBounds.maxX > min(runBounds.height, previousBounds.height) * 0.25 {
                                text.append(NSAttributedString(string: " "))
                            }
                            text.append(raw.attributedSubstring(from: (raw.string as NSString).range(of: trimmed)))
                        }
                        previousBounds = runBounds
                    }
                }
            }
            if zip(selectedLocations, selectedLocations.dropFirst()).contains(where: { $0 > $1 }) {
                reordered = true
            }
            var native = IndexSet()
            for rangeIndex in 0..<original.numberOfTextRanges(on: page) {
                let range = original.range(at: rangeIndex, on: page)
                if range.location != NSNotFound { native.insert(integersIn: range.location..<NSMaxRange(range)) }
            }
            if !native.intersection(geometry.excludedIndices).isEmpty { outside = true }
            if !wantedNonWS.subtracting(native).isEmpty { missingFromNative = true }
            for row in geometry.rows {
                for glyph in row.glyphs {
                    let indices = glyph.ranges.reduce(into: IndexSet()) { $0.insert(integersIn: $1.location..<NSMaxRange($1)) }
                    if !native.intersection(indices).isEmpty && wanted.intersection(indices).isEmpty { outside = true }
                }
            }
        }
        let tooTall = original.selectionsByLine().contains { line in
            line.pages.contains { page in
                let box = line.bounds(for: page)
                let candidates = highlights.filter { $0.page === page && $0.rect.intersects(box) }
                return !candidates.isEmpty && candidates.allSatisfy { box.height > $0.rect.height * 3 }
            }
        }
        guard force || outside || reordered || tooTall, selection.string?.isEmpty == false else { return nil }
        // When the ranges already follow the gesture in physical order, only their displayed height is wrong.
        // Keep the original extraction intact (including punctuation and ligatures) and replace its paint.
        if !outside && !reordered && !missingFromNative, original.string?.isEmpty == false {
            let originalText = original.attributedString ?? NSAttributedString(string: original.string ?? "")
            return Result(selection: original, text: PDFTextCleanup.normalize(originalText), highlights: highlights)
        }
        return Result(selection: selection, text: PDFTextCleanup.normalize(text), highlights: highlights)
    }
}

/// Ordinary pages keep PDFKit tracking. Complex pages use the same native text ranges, with a
/// transparent overlay for live glyph highlights, so oversized font metrics cannot select a matrix.
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
    private var observers: [NSObjectProtocol] = []
    private var isRepairing = false
    private var repairedSelection: PDFSelection?
    private var repairedText: NSAttributedString?
    private var nativeText: String?
    private var directlyTracking = false
    private lazy var overlay = HighlightView(owner: self)

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        })
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, NSView.boundsDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: name == NSView.boundsDidChangeNotification ? nil : pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.overlay.needsDisplay = true }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.track(event) }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func hitTest(_ point: CGPoint, event: NSEvent) -> NSView? {
        guard let pdfView, event.type == .leftMouseDown,
              event.modifierFlags.intersection([.option, .control, .command, .shift]).isEmpty,
              pdfView.document?.allowsCopying == true,
              let page = pdfView.page(for: point, nearest: false), page.rotation % 360 == 0,
              !PDFSelectionVisibility.requiresVisualSelection(on: page),
              NativePDFPageGeometry.geometry(for: page).needsDirectSelection else { return nil }
        let location = pdfView.convert(point, to: page)
        if let annotation = page.annotation(at: location), annotation.action != nil || annotation.type == PDFAnnotationSubtype.widget.rawValue { return nil }
        if overlay.superview == nil {
            overlay.frame = pdfView.bounds
            overlay.autoresizingMask = [.width, .height]
            pdfView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        return overlay
    }

    func begin(_ event: NSEvent) {
        guard lastMouseDown != event.timestamp else { return }
        lastMouseDown = event.timestamp
        gesture = nil
        directlyTracking = false
        overlay.highlights = []
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .control, .command, .option]).isEmpty,
              let pdfView, let document = pdfView.document else { return }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: false), page.rotation % 360 == 0 else { return }
        let location = pdfView.convert(point, to: page)
        gesture = Gesture(document: document, page: page, point: location, endPage: page, endPoint: location)
    }

    private func startDirect(_ event: NSEvent) {
        begin(event)
        guard let pdfView, let document = pdfView.document else { return }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: point, nearest: false) else { return }
        let location = pdfView.convert(point, to: page)
        gesture = Gesture(document: document, page: page, point: location, endPage: page, endPoint: location)
        directlyTracking = true
        pdfView.clearSelection()
        pdfView.window?.makeFirstResponder(overlay)
        if event.clickCount >= 3 {
            let geometry = NativePDFPageGeometry.geometry(for: page)
            if let rowIndex = geometry.nearestRow(to: location) {
                let rowBox = geometry.rows[rowIndex].bounds
                if let result = NativePDFSelection.corrected(PDFSelection(document: document), in: document, from: page,
                    at: CGPoint(x: rowBox.minX - 1, y: rowBox.midY), to: page, at: CGPoint(x: rowBox.maxX + 1, y: rowBox.midY), force: true) {
                    apply(result)
                }
            }
            gesture = nil
            directlyTracking = false
        } else if event.clickCount >= 2, let word = page.selectionForWord(at: location) {
            let box = word.bounds(for: page)
            if let result = NativePDFSelection.corrected(word, in: document, from: page,
                at: CGPoint(x: box.minX, y: location.y), to: page, at: CGPoint(x: box.maxX, y: location.y), force: true) {
                apply(result)
            }
            gesture = nil
            directlyTracking = false
        }
    }

    private func track(_ event: NSEvent) {
        guard let pdfView, let current = gesture, event.windowNumber == pdfView.window?.windowNumber,
              pdfView.document === current.document else { return }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        if let page = pdfView.page(for: point, nearest: true) {
            gesture?.endPage = page
            gesture?.endPoint = pdfView.convert(point, to: page)
        }
        if directlyTracking { repair(force: true, finalize: event.type == .leftMouseUp) }
        if event.type == .leftMouseUp {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.gesture?.id == current.id else { return }
                if !self.directlyTracking { self.repair() }
                self.gesture = nil
                self.directlyTracking = false
            }
        }
    }

    private func selectionChanged() {
        guard !isRepairing, let pdfView else { return }
        if repairedSelection === pdfView.currentSelection, nativeText == pdfView.currentSelection?.string { return }
        repairedText = nil
        repairedSelection = nil
        overlay.highlights = []
        // Do not replace the native selection inside PDFKit's mouse tracking loop: it resets its anchor.
    }

    private func repair(force: Bool = false, finalize: Bool = true) {
        guard !isRepairing, let pdfView, let gesture else { return }
        let original: PDFSelection
        if force, gesture.page === gesture.endPage {
            original = gesture.page.selection(from: gesture.point, to: gesture.endPoint) ?? PDFSelection(document: gesture.document)
        } else { original = pdfView.currentSelection ?? PDFSelection(document: gesture.document) }
        guard let result = NativePDFSelection.corrected(original, in: gesture.document, from: gesture.page,
            at: gesture.point, to: gesture.endPage, at: gesture.endPoint, force: force) else {
            if force {
                overlay.highlights = []
                if finalize { pdfView.clearSelection() }
            }
            return
        }
        if finalize { apply(result) }
        else { overlay.highlights = result.highlights }
    }

    private func apply(_ result: NativePDFSelection.Result) {
        guard let pdfView else { return }
        isRepairing = true
        result.selection.color = .clear
        pdfView.setCurrentSelection(result.selection, animate: false)
        repairedSelection = pdfView.currentSelection
        nativeText = pdfView.currentSelection?.string
        repairedText = result.text
        overlay.highlights = result.highlights
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

    private final class HighlightView: NSView {
        weak var owner: NativePDFSelectionTracker?
        private var scrollTimer: Timer?
        private var scrollEvent: NSEvent?
        var highlights: [NativePDFSelection.Highlight] = [] { didSet { needsDisplay = true } }
        init(owner: NativePDFSelectionTracker) {
            self.owner = owner
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseDown(with event: NSEvent) {
            stopScrolling()
            owner?.startDirect(event)
        }
        // Local monitoring handles drag/up before these callbacks, and keeps the native responder chain.
        override func mouseDragged(with event: NSEvent) {
            scrollEvent = event
            guard owner?.pdfView?.documentView?.autoscroll(with: event) == true else { stopScrolling(); return }
            if scrollTimer == nil {
                let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard self.window != nil, let event = self.scrollEvent,
                              self.owner?.pdfView?.documentView?.autoscroll(with: event) == true else { self.stopScrolling(); return }
                        self.owner?.track(event)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                scrollTimer = timer
            }
        }
        override func mouseUp(with event: NSEvent) {
            stopScrolling()
        }
        private func stopScrolling() {
            scrollTimer?.invalidate()
            scrollTimer = nil
            scrollEvent = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopScrolling() }
        }
        deinit { scrollTimer?.invalidate() }
        @objc func copy(_ sender: Any?) { owner?.pdfView?.copy(sender) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { owner?.pdfView?.clearSelection() }
            else { super.keyDown(with: event) }
        }
        override func menu(for event: NSEvent) -> NSMenu? { owner?.pdfView?.menu(for: event) }
        override func draw(_ dirtyRect: NSRect) {
            guard let view = owner?.pdfView else { return }
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.32).setFill()
            for highlight in highlights {
                guard highlight.page.document === view.document else { continue }
                let shown = convert(view.convert(highlight.rect, from: highlight.page), from: view).intersection(bounds)
                if !shown.isNull && !shown.isEmpty { NSBezierPath(rect: shown).fill() }
            }
        }
    }
}
