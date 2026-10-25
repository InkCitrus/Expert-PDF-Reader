import AppKit
import PDFKit
import QuartzCore
import SwiftUI

/// The themed PDF canvas:
/// - Applies exact theme background color (`#DCDCDE`/`#131314` Day, `#E5DECF` Sepia, `#202223` Night) on the root `ThemedPDFView` layer.
/// - Attaches the GPU `CIFilter` (Sepia / Night color matrices, see `MetalShaderRenderer`)
///   to `PDFScrollView.layer` (**above** `NSClipView.layer`'s magnification transform) while keeping `PDFScrollView`'s
///   background transparent (`alpha = 0`). This guarantees that `PDFPageLayerTile` bitmaps (`contentsScale = backingScale * magnification`)
///   are never offscreen-downsampled before `NSClipView` magnification, completely eliminating PDF blurriness when switching themes or layouts.
/// - Supports Left (`←`) and Right (`→`) arrow key page navigation in the pane that has the keyboard focus.
/// - Opens at the tab's saved page and zoom (`currentPageIndex`, `zoomScale` / `isAutoScaling`).
public struct PDFReaderCanvasView: NSViewRepresentable {
    public let pdfDocument: PDFDocument
    @Binding public var currentPageIndex: Int
    @Binding public var zoomScale: CGFloat
    public let layoutMode: ReaderLayoutMode
    public let isClearMarginsEnabled: Bool
    public let pdfTheme: PDFViewTheme
    public let isDarkUI: Bool
    public let searchMatches: [SearchMatchItem]
    public let selectedMatchIndex: Int
    public let pageJumpToken: Int
    public let zoomCommandToken: Int
    public let pendingZoomAction: DocumentTabState.ZoomAction?
    /// Initial zoom mode: `false` opens at `zoomScale` instead of fitting the width
    public let isAutoScaling: Bool
    /// Changing it re-lays out pages whose crop boxes changed (Clear Margins computed in the background)
    public let layoutToken: Int
    /// The primary pane also turns pages when the keyboard focus is outside every PDF view
    public let handlesUnfocusedArrowKeys: Bool
    public let onAutoScalesChange: ((Bool) -> Void)?
    public let onStepPage: ((Int) -> Void)?
    /// Page index and reading line (page space) while scrolling; only the primary pane reports it
    public let onReadingLocationChange: ((Int, CGFloat) -> Void)?

    public init(
        pdfDocument: PDFDocument,
        currentPageIndex: Binding<Int>,
        zoomScale: Binding<CGFloat>,
        layoutMode: ReaderLayoutMode,
        isClearMarginsEnabled: Bool,
        pdfTheme: PDFViewTheme,
        isDarkUI: Bool,
        searchMatches: [SearchMatchItem] = [],
        selectedMatchIndex: Int = 0,
        pageJumpToken: Int = 0,
        zoomCommandToken: Int = 0,
        pendingZoomAction: DocumentTabState.ZoomAction? = nil,
        isAutoScaling: Bool = true,
        layoutToken: Int = 0,
        handlesUnfocusedArrowKeys: Bool = true,
        onAutoScalesChange: ((Bool) -> Void)? = nil,
        onStepPage: ((Int) -> Void)? = nil,
        onReadingLocationChange: ((Int, CGFloat) -> Void)? = nil
    ) {
        self.pdfDocument = pdfDocument
        self._currentPageIndex = currentPageIndex
        self._zoomScale = zoomScale
        self.layoutMode = layoutMode
        self.isClearMarginsEnabled = isClearMarginsEnabled
        self.pdfTheme = pdfTheme
        self.isDarkUI = isDarkUI
        self.searchMatches = searchMatches
        self.selectedMatchIndex = selectedMatchIndex
        self.pageJumpToken = pageJumpToken
        self.zoomCommandToken = zoomCommandToken
        self.pendingZoomAction = pendingZoomAction
        self.isAutoScaling = isAutoScaling
        self.layoutToken = layoutToken
        self.handlesUnfocusedArrowKeys = handlesUnfocusedArrowKeys
        self.onAutoScalesChange = onAutoScalesChange
        self.onStepPage = onStepPage
        self.onReadingLocationChange = onReadingLocationChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> PDFView {
        let pdfView = ThemedPDFView()
        pdfView.handlesUnfocusedArrowKeys = handlesUnfocusedArrowKeys
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        pdfView.interpolationQuality = .high
        pdfView.backgroundColor = .clear
        pdfView.document = pdfDocument

        // Reopen where the document was left (see `AppStore.openDocument` / `DocumentTabState.restore`).
        // The zoom is applied once the view has a size: before that PDFKit clamps it to its minimum.
        if !isAutoScaling {
            pdfView.autoScales = false
            pdfView.pendingInitialScale = max(0.1, min(10, zoomScale))
        }
        if currentPageIndex > 0, let page = pdfDocument.page(at: currentPageIndex) {
            pdfView.pendingInitialPage = page
        }

        context.coordinator.setupNotifications(for: pdfView)
        applyConfiguration(to: pdfView, coordinator: context.coordinator)
        return pdfView
    }

    public static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        // A view being torn down (switching tabs, closing Split View) reports a collapsing scale and
        // a different page; those must not overwrite the tab's saved zoom and page
        coordinator.stopObserving()
    }

    public func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self

        if pdfView.document !== pdfDocument {
            pdfView.document = pdfDocument
            pdfView.autoScales = true
        }

        applyConfiguration(to: pdfView, coordinator: context.coordinator)
    }

    private func applyConfiguration(to pdfView: PDFView, coordinator: Coordinator) {
        // 1. Display Layout Mode & Display Box (Clear Margins)
        let targetDisplayMode: PDFDisplayMode
        let targetDisplaysAsBook: Bool
        switch layoutMode {
        case .singlePage:
            targetDisplayMode = .singlePageContinuous
            targetDisplaysAsBook = false
        case .twoPages:
            targetDisplayMode = .twoUpContinuous
            targetDisplaysAsBook = false
        case .twoPagesCover:
            targetDisplayMode = .twoUpContinuous
            targetDisplaysAsBook = true
        }
        let targetBox: PDFDisplayBox = isClearMarginsEnabled ? .cropBox : .mediaBox

        let layoutChanged = (pdfView.displayMode != targetDisplayMode)
            || (pdfView.displaysAsBook != targetDisplaysAsBook)
            || (pdfView.displayBox != targetBox)

        if layoutChanged {
            let isInitialLayout = !coordinator.hasAppliedLayout
            coordinator.hasAppliedLayout = true
            let wasAutoScaling = pdfView.autoScales
            let pageModeChanged = pdfView.displayMode != targetDisplayMode || pdfView.displaysAsBook != targetDisplaysAsBook
            // Captured before the change: after a display box change `pdfView.currentPage` still names the old
            // page while the same scroll offset already shows an earlier (taller) or later (shorter) one
            let savedDestination = isInitialLayout ? nil : pdfView.currentDestination
            if pdfView.displayMode != targetDisplayMode {
                pdfView.displayMode = targetDisplayMode
            }
            if pdfView.displaysAsBook != targetDisplaysAsBook {
                pdfView.displaysAsBook = targetDisplaysAsBook
            }
            if pdfView.displayBox != targetBox {
                pdfView.displayBox = targetBox
            }
            pdfView.layoutDocumentView()
            // Switching between single and two-page layouts refits the width so a spread is never cut off;
            // the first layout keeps the zoom a document reopens with
            let refitsWidth = pageModeChanged && !isInitialLayout
            if wasAutoScaling || refitsWidth {
                pdfView.autoScales = true
            }
            if let savedDestination {
                pdfView.go(to: savedDestination)
            }
            pdfView.needsDisplay = true
            DispatchQueue.main.async {
                // A view without a size yet (just created) has no meaningful zoom to report
                guard Coordinator.isLive(pdfView) else { return }
                // Auto scaling settles on the next pass; return to the same spot once more
                if let savedDestination {
                    pdfView.go(to: savedDestination)
                }
                if refitsWidth {
                    self.onAutoScalesChange?(true)
                }
                if abs(pdfView.scaleFactor - self.zoomScale) > 0.005 {
                    self.zoomScale = pdfView.scaleFactor
                }
            }
        }

        // Crop boxes changed after layout: re-lay out without moving away from what is being read
        if coordinator.lastLayoutToken != layoutToken {
            coordinator.lastLayoutToken = layoutToken
            let destination = pdfView.currentDestination
            pdfView.layoutDocumentView()
            if let destination {
                pdfView.go(to: destination)
            }
        }

        // 2. Theme Background & Viewport Shader Filtering
        if let themed = pdfView as? ThemedPDFView {
            themed.onStepPage = onStepPage
            themed.handlesUnfocusedArrowKeys = handlesUnfocusedArrowKeys
            themed.currentTheme = pdfTheme
            themed.isDarkUI = isDarkUI
            themed.applyThemeLayers()
        }

        // 3. Page Navigation Jump
        if coordinator.lastPageJumpToken != pageJumpToken {
            coordinator.lastPageJumpToken = pageJumpToken
            if let targetPage = pdfDocument.page(at: currentPageIndex),
               pdfView.currentPage !== targetPage {
                pdfView.go(to: targetPage)
            }
        } else if let current = pdfView.currentPage {
            let actualIdx = pdfDocument.index(for: current)
            if actualIdx != currentPageIndex && actualIdx >= 0 && actualIdx < pdfDocument.pageCount {
                if let targetPage = pdfDocument.page(at: currentPageIndex) {
                    pdfView.go(to: targetPage)
                }
            }
        }

        // 4. Imperative Zoom Commands
        if coordinator.lastZoomCommandToken != zoomCommandToken {
            coordinator.lastZoomCommandToken = zoomCommandToken
            if let action = pendingZoomAction {
                switch action {
                case .zoomIn:
                    pdfView.autoScales = false
                    pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * 1.2)
                case .zoomOut:
                    pdfView.autoScales = false
                    pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / 1.2)
                case .actualSize:
                    pdfView.autoScales = false
                    pdfView.scaleFactor = 1.0
                case .fitWidth:
                    pdfView.autoScales = true
                case .fitPage:
                    pdfView.autoScales = false
                    if let page = pdfView.currentPage {
                        let bounds = page.bounds(for: pdfView.displayBox)
                        let isQuarterTurned = (page.rotation / 90) % 2 != 0
                        let pageSize = isQuarterTurned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
                        let isSpread = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous
                        let contentWidth = isSpread ? pageSize.width * 2 + 12 : pageSize.width
                        let viewBounds = pdfView.bounds.insetBy(dx: 24, dy: 24)
                        if contentWidth > 0 && pageSize.height > 0 {
                            let scaleW = viewBounds.width / contentWidth
                            let scaleH = viewBounds.height / pageSize.height
                            pdfView.scaleFactor = max(pdfView.minScaleFactor, min(scaleW, scaleH))
                            // Show the whole page, not the bottom of the previous one and half of this one
                            pdfView.go(to: page)
                        }
                    }
                case .scale(let value):
                    pdfView.autoScales = false
                    pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, value))
                }
                DispatchQueue.main.async {
                    guard Coordinator.isLive(pdfView) else { return }
                    self.zoomScale = pdfView.scaleFactor
                }
            }
        }

        // 5. Search Highlighted Selections
        if searchMatches.isEmpty {
            if pdfView.highlightedSelections != nil {
                pdfView.highlightedSelections = nil
            }
        } else {
            let isNight = (pdfTheme == .night)
            let selections = searchMatches.enumerated().map { idx, item -> PDFSelection in
                let sel = item.selection.copy() as! PDFSelection
                if isNight {
                    // PDFKit multiplies highlights onto the page, so the text stays black underneath and the
                    // Night filter turns it into #BFBFBF ink. These warm colors become amber boxes there
                    // (#563D05 for the current match, #392905 for the others), keeping the found word readable
                    // (5:1 or more); dark colors would invert into light boxes behind light text.
                    sel.color = (idx == selectedMatchIndex)
                        ? NSColor(srgbRed: 0.81, green: 0.67, blue: 0.36, alpha: 1.0)
                        : NSColor(srgbRed: 0.87, green: 0.78, blue: 0.58, alpha: 1.0)
                } else {
                    sel.color = (idx == selectedMatchIndex)
                        ? NSColor.systemOrange.withAlphaComponent(0.65)
                        : NSColor.systemYellow.withAlphaComponent(0.42)
                }
                return sel
            }
            pdfView.highlightedSelections = selections
            if selectedMatchIndex >= 0 && selectedMatchIndex < searchMatches.count {
                let activeMatch = searchMatches[selectedMatchIndex]
                // Compare match IDs, not indices: a new search selects index 0 again
                if coordinator.lastHighlightedMatchID != activeMatch.id {
                    coordinator.lastHighlightedMatchID = activeMatch.id
                    pdfView.go(to: activeMatch.selection)
                }
            }
        }
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject {
        var parent: PDFReaderCanvasView
        var lastPageJumpToken: Int = -1
        var lastZoomCommandToken: Int = -1
        var lastLayoutToken: Int
        var lastHighlightedMatchID: UUID?
        var hasAppliedLayout = false
        private var observers: [NSObjectProtocol] = []
        nonisolated(unsafe) private var keyMonitor: Any?

        init(parent: PDFReaderCanvasView) {
            self.parent = parent
            self.lastLayoutToken = parent.layoutToken
        }

        deinit {
            stopObserving()
        }

        func stopObserving() {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
            observers.removeAll()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        /// Only a view on screen with a real size, done applying the zoom and page it opened with,
        /// reports its page and zoom back to the tab
        static func isLive(_ pdfView: PDFView) -> Bool {
            if let themed = pdfView as? ThemedPDFView, themed.isRestoringInitialState {
                return false
            }
            return pdfView.window != nil && pdfView.bounds.width > 1 && pdfView.bounds.height > 1
        }

        func setupNotifications(for pdfView: PDFView) {
            let nc = NotificationCenter.default

            let pageObs = nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView, Self.isLive(pdfView),
                      let doc = pdfView.document,
                      let page = pdfView.currentPage else { return }
                let idx = doc.index(for: page)
                if idx != self.parent.currentPageIndex {
                    self.parent.currentPageIndex = idx
                }
                (pdfView as? ThemedPDFView)?.applyThemeLayers()
            }

            let scaleObs = nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView, Self.isLive(pdfView) else { return }
                if abs(pdfView.scaleFactor - self.parent.zoomScale) > 0.005 {
                    self.parent.zoomScale = pdfView.scaleFactor
                }
                self.parent.onAutoScalesChange?(pdfView.autoScales)
                (pdfView as? ThemedPDFView)?.applyThemeLayers()
            }

            observers.append(contentsOf: [pageObs, scaleObs])

            if let scrollView = pdfView.enclosingScrollView ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
                scrollView.contentView.postsBoundsChangedNotifications = true
                let scrollObs = nc.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self, weak pdfView] _ in
                    guard let pdfView else { return }
                    (pdfView as? ThemedPDFView)?.applyThemeLayers()
                    self?.reportReadingLocation(of: pdfView)
                }
                observers.append(scrollObs)
            }

            reportReadingLocation(of: pdfView)

            // Local keyDown monitor so ←/→ turn pages even when a toolbar control has the focus;
            // `ThemedPDFView.pageStep(for:)` decides which pane (if any) handles the key.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak pdfView] event in
                guard let themed = pdfView as? ThemedPDFView,
                      let delta = themed.pageStep(for: event),
                      let stepHandler = themed.onStepPage else {
                    return event
                }
                stepHandler(delta)
                return nil
            }
        }

        /// The reading line sits a quarter of the view below the top edge, so a heading in the upper part
        /// of the view already counts as the section being read
        func reportReadingLocation(of pdfView: PDFView) {
            guard Self.isLive(pdfView),
                  let handler = parent.onReadingLocationChange,
                  let destination = pdfView.currentDestination,
                  let page = destination.page,
                  let document = pdfView.document else { return }
            let quarterView = pdfView.bounds.height / max(pdfView.scaleFactor, 0.01) / 4
            handler(document.index(for: page), destination.point.y - quarterView)
        }
    }
}

// MARK: - ThemedPDFView (Sharp Retina Viewport Shader Filtering + Arrow Key Navigation)

final class ThemedPDFView: PDFView {
    var currentTheme: PDFViewTheme = .day
    var isDarkUI: Bool = false
    var onStepPage: ((Int) -> Void)?
    var handlesUnfocusedArrowKeys = true

    /// Page and zoom to show once the view has a size: `go(to:)` and `scaleFactor` before the first layout are lost.
    var pendingInitialPage: PDFPage?
    var pendingInitialScale: CGFloat?
    private var isShowingInitialPage = false

    /// Until the saved page and zoom are shown, PDFKit reports page 1 and a clamped zoom of the fresh layout
    var isRestoringInitialState: Bool {
        pendingInitialPage != nil || pendingInitialScale != nil
    }

    override func keyDown(with event: NSEvent) {
        if let delta = pageStep(for: event), let onStepPage {
            onStepPage(delta)
            return
        }
        super.keyDown(with: event)
    }

    /// `-1` / `1` when an unmodified ←/→ should turn the page in this view, `nil` to leave the key alone:
    /// text fields and sidebar lists use the arrows themselves, a zoomed page wider than the view keeps them
    /// for horizontal scrolling, and in Split View only the pane with the keyboard focus turns the page.
    func pageStep(for event: NSEvent) -> Int? {
        guard onStepPage != nil, event.keyCode == 123 || event.keyCode == 124 else { return nil }
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
              let window, event.window === window,
              !canScrollHorizontally else {
            return nil
        }
        let responder = window.firstResponder
        if responder is NSText || responder is NSTableView {
            return nil
        }
        if let focusedView = responder as? NSView, let focusedPDFView = Self.enclosingPDFView(of: focusedView) {
            guard focusedPDFView === self else { return nil }
        } else if !handlesUnfocusedArrowKeys {
            return nil
        }
        return event.keyCode == 123 ? -1 : 1
    }

    private var canScrollHorizontally: Bool {
        guard let scrollView = subviews.compactMap({ $0 as? NSScrollView }).first,
              let documentView = scrollView.documentView else {
            return false
        }
        return documentView.frame.width > scrollView.contentView.bounds.width + 1
    }

    private static func enclosingPDFView(of view: NSView) -> PDFView? {
        var current: NSView? = view
        while let candidate = current {
            if let pdfView = candidate as? PDFView {
                return pdfView
            }
            current = candidate.superview
        }
        return nil
    }

    override func layout() {
        super.layout()
        if isRestoringInitialState, !isShowingInitialPage, bounds.width > 0, bounds.height > 0 {
            isShowingInitialPage = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let scale = self.pendingInitialScale {
                    self.autoScales = false
                    self.scaleFactor = scale
                }
                if let page = self.pendingInitialPage {
                    self.go(to: page)
                }
                self.pendingInitialScale = nil
                self.pendingInitialPage = nil
                self.isShowingInitialPage = false
                // Scale changes were ignored while restoring: report the zoom the view settled on
                // (e.g. fit width), so the toolbar's percentage matches the page
                NotificationCenter.default.post(name: .PDFViewScaleChanged, object: self)
            }
        }
        applyThemeLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeLayers()
        // A newly shown document (opened, or its tab selected) takes the keyboard so ←/→ turn pages right away;
        // otherwise AppKit hands it to the toolbar's search field and the arrows move its caret. Only the
        // primary pane does this, and only while nothing else holds the focus.
        guard handlesUnfocusedArrowKeys, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            let responder = window.firstResponder
            if responder == nil || responder === window || responder is NSText {
                window.makeFirstResponder(self)
            }
        }
    }

    func applyThemeLayers() {
        self.wantsLayer = true
        self.layerUsesCoreImageFilters = true

        // 1. Paint the exact canvas background on ThemedPDFView's own backing layer (outside PDFScrollView)
        if self.backgroundColor != .clear {
            self.backgroundColor = .clear
        }
        let bgCGColor = currentTheme.documentBackgroundNSColor(isDarkUI: isDarkUI).cgColor
        self.layer?.backgroundColor = bgCGColor

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let filters = MetalShaderRenderer.shared.pageLayerFilters(for: currentTheme)

        // 2. Attach the theme CIFilter to PDFScrollView's layer (which sits ABOVE NSClipView's magnification
        //    transform). Because PDFScrollView has identity transform and full Retina contentsScale,
        //    CoreAnimation composites all PDFPageLayerTile IOSurfaces at 100% native zoomed resolution
        //    before running the shader on the viewport — zero intermediate 1x downsampling or blur!
        if let scrollView = self.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.wantsLayer = true
            scrollView.layerUsesCoreImageFilters = true
            if scrollView.drawsBackground {
                scrollView.drawsBackground = false
            }
            for sub in scrollView.subviews where String(describing: type(of: sub)).contains("Background") {
                if !sub.isHidden {
                    sub.isHidden = true
                }
            }
            if let svLayer = scrollView.layer {
                svLayer.contentsScale = backingScale
                svLayer.rasterizationScale = backingScale
                svLayer.backgroundColor = NSColor.clear.cgColor
                let hadFilters = !(svLayer.filters?.isEmpty ?? true)
                let wantsFilters = !filters.isEmpty
                if wantsFilters || hadFilters {
                    svLayer.filters = filters
                }
            }
        }

        // 3. Ensure PDFPageLayer sublayers have no sub-clipView filters (which would force 1x rasterization)
        //    and hide drop shadows in Night mode so they aren't inverted into a light halo.
        guard let docView = self.documentView else { return }
        let isNight = (currentTheme == .night)
        for pageView in docView.subviews {
            guard let pageLayer = pageView.layer else { continue }
            if pageLayer.filters != nil {
                pageLayer.filters = nil
            }
            if let sublayers = pageLayer.sublayers, sublayers.count >= 4 {
                if sublayers[0].isHidden != isNight {
                    sublayers[0].isHidden = isNight
                }
                if sublayers[1].isHidden != isNight {
                    sublayers[1].isHidden = isNight
                }
                let contentContainer = sublayers[2]
                if contentContainer.filters != nil {
                    contentContainer.filters = nil
                }
                if let tilesContainer = contentContainer.sublayers?.first,
                   tilesContainer.filters != nil {
                    tilesContainer.filters = nil
                }
                let paperLayer = sublayers[3]
                paperLayer.backgroundColor = NSColor.white.cgColor
            }
        }
    }
}
