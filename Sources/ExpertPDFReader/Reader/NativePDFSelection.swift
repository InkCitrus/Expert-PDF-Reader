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
                abs(rows[$0].bounds.midY - glyph.bounds.midY) <= typicalHeight * 0.7
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
}

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
        for index in document.index(for: first.page)...document.index(for: last.page) {
            guard let page = document.page(at: index) else { continue }
            let geometry = NativePDFPageGeometry.geometry(for: page)
            let lo = page === first.page ? firstRow : 0
            let hi = page === last.page ? lastRow : geometry.rows.count - 1
            guard lo <= hi, geometry.rows.indices.contains(lo), geometry.rows.indices.contains(hi) else { continue }
            var wanted = IndexSet()
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
                for glyph in glyphs { for range in glyph.ranges { rowRanges.insert(integersIn: range.location..<NSMaxRange(range)) } }
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
            var native = IndexSet()
            for rangeIndex in 0..<original.numberOfTextRanges(on: page) {
                let range = original.range(at: rangeIndex, on: page)
                if range.location != NSNotFound { native.insert(integersIn: range.location..<NSMaxRange(range)) }
            }
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
        guard force || outside || tooTall, selection.string?.isEmpty == false else { return nil }
        // When the ranges already follow the gesture, only their displayed height is wrong. Keep
        // the original extraction intact (including punctuation and ligatures) and replace its paint.
        if !outside, original.string?.isEmpty == false {
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
        if event.clickCount >= 2, let word = page.selectionForWord(at: location) {
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
        override func mouseDown(with event: NSEvent) { owner?.startDirect(event) }
        // Local monitoring handles drag/up before these callbacks, and keeps the native responder chain.
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
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
                let shown = convert(view.convert(highlight.rect, from: highlight.page), from: view).intersection(bounds)
                if !shown.isNull && !shown.isEmpty { NSBezierPath(rect: shown).fill() }
            }
        }
    }
}
