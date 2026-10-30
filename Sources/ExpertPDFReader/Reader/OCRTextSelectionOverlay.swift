import AppKit
import NaturalLanguage
import PDFKit

/// Scanned pages keep their original pixels. Only selection uses the recognized character geometry.
final class OCRTextSelectionOverlay: NSView, NSMenuItemValidation {
    private final class CachedText: NSObject {
        let value: OCRPageText
        init(_ value: OCRPageText) { self.value = value }
    }
    private weak var pdfView: PDFView?
    private let cache = NSCache<PDFPage, CachedText>()
    private var observations: [NSObjectProtocol] = []
    private var recognition: Task<Void, Never>?
    private var requestID = UUID()
    private weak var selectedPage: PDFPage?
    private weak var extentPage: PDFPage?
    private var selectionTexts: [ObjectIdentifier: OCRPageText] = [:]
    private var anchor: CGPoint = .zero
    private var extent: CGPoint = .zero
    private var mouseAnchor: CGPoint = .zero
    private var selectsText = false
    private var selectsWord = false
    private var isTracking = false
    private var copyWhenReady: Int?
    private var autoscrollTimer: Timer?
    private var dragEvent: NSEvent?
    private let status = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { pdfView?.isFlipped ?? false }

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        cache.countLimit = 8
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        NSLayoutConstraint.activate([
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44)
        ])
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observations.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            })
        }
        if let scroll = pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
            scroll.contentView.postsBoundsChangedNotifications = true
            observations.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        recognition?.cancel()
        autoscrollTimer?.invalidate()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func clear(documentChanged: Bool = false) {
        selectsText = false
        isTracking = false
        copyWhenReady = nil
        selectedPage = nil
        extentPage = nil
        selectionTexts.removeAll()
        status.isHidden = true
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        dragEvent = nil
        requestID = UUID()
        recognition?.cancel()
        recognition = nil
        if documentChanged {
            cache.removeAllObjects()
        }
        needsDisplay = true
    }

    private func page(at point: CGPoint) -> PDFPage? {
        guard let pdfView, pdfView.document?.allowsCopying == true,
              let page = pdfView.page(for: convert(point, to: pdfView), nearest: false),
              page.rotation % 360 == 0, page.hasFullPageScanImage else { return nil }
        let pagePoint = pdfView.convert(convert(point, to: pdfView), to: page)
        if let annotation = page.annotation(at: pagePoint), annotation.action != nil || annotation.type == PDFAnnotationSubtype.widget.rawValue { return nil }
        return page
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if isTracking, event.type == .leftMouseDragged || event.type == .leftMouseUp { return self }
        guard event.type == .leftMouseDown || (event.type == .rightMouseDown && selectsText),
              event.modifierFlags.intersection([.option, .control]).isEmpty, page(at: local) != nil else { return nil }
        return self
    }

    override func resetCursorRects() {
        guard let pdfView else { return }
        for page in pdfView.visiblePages where page.rotation % 360 == 0 && page.hasFullPageScanImage {
            let rect = convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let vertical = cache.object(forKey: page)?.value.isVertical ?? ((pdfView as? ThemedPDFView)?.readsRightToLeft == true)
            addCursorRect(rect, cursor: vertical ? .iBeamCursorForVerticalLayout : .iBeam)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pdfView, let page = page(at: point) else { return }
        clear()
        selectedPage = page
        extentPage = page
        pdfView.clearSelection()
        window?.makeFirstResponder(self)
        mouseAnchor = point
        anchor = pdfView.convert(convert(point, to: pdfView), to: page)
        extent = anchor
        selectsWord = event.clickCount >= 2
        selectsText = selectsWord
        isTracking = true
        copyWhenReady = nil
        if selectsText { prepareSelectionTexts() }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pdfView, selectedPage != nil else { return }
        dragEvent = event
        if pdfView.documentView?.autoscroll(with: event) == true, autoscrollTimer == nil {
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollSelection() }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoscrollTimer = timer
        }
        let point = convert(event.locationInWindow, from: nil)
        updateExtent(at: point)
        if hypot(point.x - mouseAnchor.x, point.y - mouseAnchor.y) > 3 {
            selectsText = true
            selectsWord = false
            prepareSelectionTexts()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if selectsText { mouseDragged(with: event) }
        isTracking = false
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        dragEvent = nil
        needsDisplay = true
    }

    private func autoscrollSelection() {
        guard isTracking, let event = dragEvent, let pdfView, selectedPage != nil,
              pdfView.documentView?.autoscroll(with: event) == true else {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        updateExtent(at: point)
        prepareSelectionTexts()
        needsDisplay = true
    }

    private func updateExtent(at point: CGPoint) {
        guard let pdfView, let anchorPage = selectedPage else { return }
        let location = convert(point, to: pdfView)
        let page = pdfView.page(for: location, nearest: true) ?? extentPage ?? anchorPage
        guard page.rotation % 360 == 0 else { return }
        extentPage = page
        extent = pdfView.convert(location, to: page)
    }

    private var selectedPages: [PDFPage] {
        guard let pdfView, let document = pdfView.document, let first = selectedPage,
              let last = extentPage else { return [] }
        let a = document.index(for: first), b = document.index(for: last)
        guard (0..<document.pageCount).contains(a), (0..<document.pageCount).contains(b) else { return [] }
        var pages = (min(a, b)...max(a, b)).compactMap { document.page(at: $0) }
        if pages.count == 2, pdfView.displayMode == .twoUpContinuous {
            let r1 = pdfView.convert(first.bounds(for: .cropBox), from: first)
            let r2 = pdfView.convert(last.bounds(for: .cropBox), from: last)
            if abs(r1.midY - r2.midY) < min(r1.height, r2.height) * 0.5 {
                pages.sort {
                    let x1 = pdfView.convert($0.bounds(for: .cropBox), from: $0).midX
                    let x2 = pdfView.convert($1.bounds(for: .cropBox), from: $1).midX
                    return pdfView.displaysRTL ? x1 > x2 : x1 < x2
                }
            }
        }
        return pages
    }

    private func text(for page: PDFPage) -> OCRPageText? {
        selectionTexts[ObjectIdentifier(page)] ?? cache.object(forKey: page)?.value
    }

    private func prepareSelectionTexts() {
        let pages = selectedPages
        for page in pages where text(for: page) == nil {
            prepareText(for: page)
            return
        }
        status.isHidden = true
        if let count = copyWhenReady, count == NSPasteboard.general.changeCount { _ = copySelectionIfPresent() }
        copyWhenReady = nil
    }

    private func prepareText(for page: PDFPage) {
        guard cache.object(forKey: page) == nil, recognition == nil, let data = page.dataRepresentation else { return }
        let identifier = UUID()
        requestID = identifier
        let document = pdfView?.document
        status.stringValue = L10n.tr("正在识别文字…", "Recognizing text…")
        status.isHidden = false
        recognition = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try PageTextRecognition.selectableText(pageData: data) } }.value
            guard let self, self.requestID == identifier, self.pdfView?.document === document else { return }
            self.recognition = nil
            self.status.isHidden = true
            switch result {
            case .success(let text):
                self.cache.setObject(CachedText(text), forKey: page)
                self.selectionTexts[ObjectIdentifier(page)] = text
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
                self.prepareSelectionTexts()
            case .failure(let error):
                if self.selectedPage === page && self.selectsText {
                    self.status.stringValue = error.localizedDescription
                    self.status.isHidden = false
                }
            }
        }
    }

    private func selectedRange(in text: OCRPageText, on page: PDFPage) -> (Int, Int)? {
        guard selectsText, !text.glyphs.isEmpty else { return nil }
        if selectedPage !== extentPage {
            let pages = selectedPages
            let start = page === pages.first ? text.nearestGlyph(to: page === selectedPage ? anchor : extent) : 0
            let end = page === pages.last ? text.nearestGlyph(to: page === extentPage ? extent : anchor) : text.glyphs.count - 1
            if let start, let end { return (start, end) }
            return nil
        }
        guard let start = text.nearestGlyph(to: anchor), let end = text.nearestGlyph(to: extent) else { return nil }
        guard selectsWord else { return (start, end) }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text.text
        let character = String.Index(utf16Offset: text.glyphs[start].range.location, in: text.text)
        let range = NSRange(tokenizer.tokenRange(at: character), in: text.text)
        let matches = text.glyphs.indices.filter { NSIntersectionRange(text.glyphs[$0].range, range).length > 0 }
        return (matches.first ?? start, matches.last ?? start)
    }

    @discardableResult func copySelectionIfPresent() -> Bool {
        guard selectsText, selectedPage != nil, pdfView?.document?.allowsCopying == true else { return false }
        let pages = selectedPages
        guard !pages.isEmpty else { return false }
        guard pages.allSatisfy({ self.text(for: $0) != nil }) else {
            copyWhenReady = NSPasteboard.general.changeCount
            prepareSelectionTexts()
            return true
        }
        let text = pages.compactMap { page -> String? in
            guard let layout = self.text(for: page), let (start, end) = selectedRange(in: layout, on: page) else { return nil }
            return layout.selectedText(from: start, through: end)
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    @objc func copy(_ sender: Any?) {
        if !copySelectionIfPresent() { pdfView?.copy(sender) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(copy(_:)) || selectsText || pdfView?.currentSelection != nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { clear() }
        else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L10n.tr("复制", "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selectsText, let pdfView else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.32).setFill()
        for page in selectedPages {
            let rects: [CGRect]
            if let text = self.text(for: page), let (start, end) = selectedRange(in: text, on: page) {
                rects = text.selectedBounds(from: start, through: end)
            } else if selectedPage === extentPage {
                rects = [CGRect(x: min(anchor.x, extent.x), y: min(anchor.y, extent.y), width: abs(anchor.x - extent.x), height: abs(anchor.y - extent.y))]
            } else { rects = [] }
            for rect in rects {
                let shown = convert(pdfView.convert(rect, from: page), from: pdfView).intersection(bounds)
                guard !shown.isNull, !shown.isEmpty else { continue }
                NSBezierPath(rect: shown).fill()
            }
        }
    }
}
