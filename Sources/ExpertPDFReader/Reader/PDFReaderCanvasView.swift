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
/// - Supports Left (`←`) and Right (`→`) arrow key page navigation in the pane that has the keyboard focus
///   (swapped for right-to-left books).
/// - Opens at the tab's saved page and zoom (`currentPageIndex`, `zoomScale` / `isAutoScaling`).
public struct PDFReaderCanvasView: NSViewRepresentable {
    public let pdfDocument: PDFDocument
    @Binding public var currentPageIndex: Int
    @Binding public var zoomScale: CGFloat
    public let layoutMode: ReaderLayoutMode
    /// Right-bound books: spreads show the earlier page on the right and ← / → swap
    public let readsRightToLeft: Bool
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
    /// Where to return to after that; only the primary pane knows
    public let readingSpot: DocumentTabState.ReadingSpot?
    public let initialReadingSpot: DocumentTabState.ReadingSpot?
    /// The primary pane also turns pages when the keyboard focus is outside every PDF view
    public let handlesUnfocusedArrowKeys: Bool
    public let onAutoScalesChange: ((Bool) -> Void)?
    public let onStepPage: ((Int) -> Void)?
    /// Page index and reading line (page space) while scrolling; only the primary pane reports it
    public let onReadingLocationChange: ((Int, CGFloat) -> Void)?
    /// The text at the top of the view while scrolling, to return to after the crop boxes change
    public let onReadingSpotChange: ((DocumentTabState.ReadingSpot) -> Void)?

    public init(
        pdfDocument: PDFDocument,
        currentPageIndex: Binding<Int>,
        zoomScale: Binding<CGFloat>,
        layoutMode: ReaderLayoutMode,
        readsRightToLeft: Bool = false,
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
        readingSpot: DocumentTabState.ReadingSpot? = nil,
        initialReadingSpot: DocumentTabState.ReadingSpot? = nil,
        handlesUnfocusedArrowKeys: Bool = true,
        onAutoScalesChange: ((Bool) -> Void)? = nil,
        onStepPage: ((Int) -> Void)? = nil,
        onReadingLocationChange: ((Int, CGFloat) -> Void)? = nil,
        onReadingSpotChange: ((DocumentTabState.ReadingSpot) -> Void)? = nil
    ) {
        self.pdfDocument = pdfDocument
        self._currentPageIndex = currentPageIndex
        self._zoomScale = zoomScale
        self.layoutMode = layoutMode
        self.readsRightToLeft = readsRightToLeft
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
        self.readingSpot = readingSpot
        self.initialReadingSpot = initialReadingSpot
        self.handlesUnfocusedArrowKeys = handlesUnfocusedArrowKeys
        self.onAutoScalesChange = onAutoScalesChange
        self.onStepPage = onStepPage
        self.onReadingLocationChange = onReadingLocationChange
        self.onReadingSpotChange = onReadingSpotChange
    }

    private static let pageBreakMargins = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    private static let spreadPageBreakMargins = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

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
        pdfView.pageBreakMargins = Self.pageBreakMargins
        pdfView.interpolationQuality = .high
        pdfView.backgroundColor = .clear
        pdfView.document = pdfDocument

        // Reopen where the document was left (see `AppStore.openDocument` / `DocumentTabState.restore`).
        // The zoom is applied once the view has a size: before that PDFKit clamps it to its minimum.
        pdfView.wantsAutoScales = isAutoScaling
        pdfView.pendingInitialSpot = initialReadingSpot
        if !isAutoScaling {
            pdfView.isApplyingConfiguration = true
            pdfView.autoScales = false
            pdfView.isApplyingConfiguration = false
            pdfView.pendingInitialScale = max(0.1, min(10, zoomScale))
        }
        if currentPageIndex > 0, let page = pdfDocument.page(at: currentPageIndex) {
            pdfView.pendingInitialPage = page
        }

        context.coordinator.setupNotifications(for: pdfView)
        applyConfiguration(to: pdfView, coordinator: context.coordinator)
        pdfView.installOCRSelection()
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
            let themed = pdfView as? ThemedPDFView
            themed?.ocrSelectionOverlay.clear(documentChanged: true)
            themed?.isApplyingConfiguration = true
            pdfView.document = pdfDocument
            themed?.wantsAutoScales = isAutoScaling
            pdfView.autoScales = isAutoScaling
            if !isAutoScaling {
                pdfView.scaleFactor = max(0.1, min(10, zoomScale))
            }
            themed?.isApplyingConfiguration = false
        }

        applyConfiguration(to: pdfView, coordinator: context.coordinator)
    }

    private func applyConfiguration(to pdfView: PDFView, coordinator: Coordinator) {
        let themedView = pdfView as? ThemedPDFView
        themedView?.isApplyingConfiguration = true
        defer { themedView?.isApplyingConfiguration = false }

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
        // The crop box, like other readers: a print proof's marks and slug outside it stay hidden.
        // Clear Margins narrows the crop boxes themselves
        let targetBox: PDFDisplayBox = .cropBox

        let layoutChanged = (pdfView.displayMode != targetDisplayMode)
            || (pdfView.displaysAsBook != targetDisplaysAsBook)
            || (pdfView.displaysRTL != readsRightToLeft)
            || (pdfView.displayBox != targetBox)

        if layoutChanged {
            let isInitialLayout = !coordinator.hasAppliedLayout
            coordinator.hasAppliedLayout = true
            let wasAutoScaling = isInitialLayout ? isAutoScaling : pdfView.autoScales
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
            if pdfView.displaysRTL != readsRightToLeft {
                pdfView.displaysRTL = readsRightToLeft
            }
            if pdfView.displayBox != targetBox {
                pdfView.displayBox = targetBox
            }
            // The two pages of a spread meet at the spine, like the open book
            let spread = targetDisplayMode == .twoUpContinuous
                ? SpreadAlignment.Spread(isBook: targetDisplaysAsBook, readsRightToLeft: readsRightToLeft)
                : nil
            pdfView.pageBreakMargins = spread == nil ? Self.pageBreakMargins : Self.spreadPageBreakMargins
            SpreadAlignment.apply(to: pdfDocument, holdsContent: isClearMarginsEnabled, spread: spread)
            coordinator.spread = spread
            pdfView.layoutDocumentView()
            // Switching between single and two-page layouts refits the width so a spread is never cut off;
            // the first layout keeps the zoom a document reopens with
            let refitsWidth = pageModeChanged && !isInitialLayout
            if wasAutoScaling || refitsWidth {
                themedView?.wantsAutoScales = true
                pdfView.autoScales = true
            }
            if let savedDestination {
                pdfView.go(to: savedDestination)
            }
            pdfView.needsDisplay = true
            DispatchQueue.main.async {
                // A view without a size yet (just created) has no meaningful zoom to report
                guard Coordinator.isLive(pdfView) else { return }
                // A pane just opened has not scrolled yet: note where it is
                coordinator.reportReadingLocation(of: pdfView)
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
            // Where the reader was before the boxes changed: the view's own idea of it already mixes the old
            // layout with the new page sizes
            let destination = readingSpot == nil ? (coordinator.lastDestination ?? pdfView.currentDestination) : nil
            SpreadAlignment.apply(to: pdfDocument, holdsContent: isClearMarginsEnabled, spread: coordinator.spread)
            pdfView.layoutDocumentView()
            if let readingSpot {
                Coordinator.scroll(pdfView, toTop: readingSpot)
            } else if let destination {
                pdfView.go(to: destination)
            }
            // Fitting the width settles a moment later and zooms around the middle of the view:
            // return to the spot once the new zoom is in
            coordinator.pendingReadingSpot = readingSpot
            coordinator.pendingDestination = destination
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak coordinator] in
                coordinator?.pendingReadingSpot = nil
                coordinator?.pendingDestination = nil
            }
        }

        // 2. Theme Background & Viewport Shader Filtering
        if let themed = pdfView as? ThemedPDFView {
            themed.onStepPage = onStepPage
            themed.handlesUnfocusedArrowKeys = handlesUnfocusedArrowKeys
            themed.readsRightToLeft = readsRightToLeft
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
        } else if let current = pdfView.currentPage, Coordinator.isLive(pdfView) {
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
                    themedView?.wantsAutoScales = false
                    pdfView.autoScales = false
                    pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * 1.2)
                case .zoomOut:
                    themedView?.wantsAutoScales = false
                    pdfView.autoScales = false
                    pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor / 1.2)
                case .actualSize:
                    themedView?.wantsAutoScales = false
                    pdfView.autoScales = false
                    pdfView.scaleFactor = 1.0
                case .fitWidth:
                    themedView?.wantsAutoScales = true
                    pdfView.autoScales = true
                case .fitPage:
                    themedView?.wantsAutoScales = false
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
                    themedView?.wantsAutoScales = false
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
        var lastPageJumpToken: Int
        var lastZoomCommandToken: Int
        var lastLayoutToken: Int
        /// The spread layout last applied, so pages whose boxes change later (Clear Margins) are aligned too
        var spread: SpreadAlignment.Spread?
        var lastHighlightedMatchID: UUID?
        /// The spot being read, kept up to date while scrolling
        var lastDestination: PDFDestination?
        /// Where to stay while the zoom settles after the crop boxes changed
        var pendingDestination: PDFDestination?
        var pendingReadingSpot: DocumentTabState.ReadingSpot?
        var hasAppliedLayout = false
        private var observers: [NSObjectProtocol] = []
        nonisolated(unsafe) private var keyMonitor: Any?

        init(parent: PDFReaderCanvasView) {
            self.parent = parent
            self.lastPageJumpToken = parent.pageJumpToken
            self.lastZoomCommandToken = parent.zoomCommandToken
            self.lastLayoutToken = parent.layoutToken
        }

        deinit {
            stopObserving()
        }

        func stopObserving() {
            scanPrefetchTask?.cancel()
            scanPrefetchTask = nil
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

        private var scanPrefetchTask: Task<Void, Never>?
        private var lastPrefetchKey: String?
        private var lastPrefetchPage = 0

        private func prefetchAdjacentPages(in pdfView: PDFView) {
            guard Self.isLive(pdfView), let document = pdfView.document, !document.isEncrypted,
                  let url = document.documentURL, let page = pdfView.currentPage, page.hasFullPageScanImage else { return }
            let index = document.index(for: page)
            let scale = pdfView.scaleFactor * (pdfView.window?.backingScaleFactor ?? 2)
            let key = "\(ObjectIdentifier(document)):\(index):\(scale):\(parent.layoutToken):\(pdfView.displayMode.rawValue)"
            guard key != lastPrefetchKey else { return }
            let direction = index < lastPrefetchPage ? -1 : 1
            lastPrefetchKey = key
            lastPrefetchPage = index
            scanPrefetchTask?.cancel()
            let count = pdfView.displayMode == .twoUpContinuous ? 2 : 1
            let pages = (0...count).compactMap { offset -> ScannedPageCache.PrefetchPage? in
                let next = index + direction * offset
                guard (0..<document.pageCount).contains(next), let page = document.page(at: next) else { return nil }
                return .init(index: next, mediaBox: page.bounds(for: .mediaBox), cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            }
            scanPrefetchTask = ScannedPageCache.prefetch(url: url, pages: pages, scale: scale)
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
                self.prefetchAdjacentPages(in: pdfView)
            }

            let scaleObs = nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView, Self.isLive(pdfView) else { return }
                if abs(pdfView.scaleFactor - self.parent.zoomScale) > 0.005 {
                    self.parent.zoomScale = pdfView.scaleFactor
                }
                self.parent.onAutoScalesChange?(pdfView.autoScales)
                (pdfView as? ThemedPDFView)?.applyThemeLayers()
                self.prefetchAdjacentPages(in: pdfView)
                if let spot = self.pendingReadingSpot {
                    Self.scroll(pdfView, toTop: spot)
                } else if let pending = self.pendingDestination {
                    pdfView.go(to: pending)
                }
            }

            observers.append(contentsOf: [pageObs, scaleObs])

            if let themed = pdfView as? ThemedPDFView {
                themed.onAutoScalesDidChange = { [weak self, weak pdfView] autoScales in
                    guard let self, let pdfView, Self.isLive(pdfView) else { return }
                    self.parent.onAutoScalesChange?(autoScales)
                    if abs(pdfView.scaleFactor - self.parent.zoomScale) > 0.005 {
                        self.parent.zoomScale = pdfView.scaleFactor
                    }
                }
                themed.onDidSettleLiveLayout = { [weak self, weak pdfView] in
                    guard let self, let pdfView, Self.isLive(pdfView) else { return }
                    if abs(pdfView.scaleFactor - self.parent.zoomScale) > 0.005 {
                        self.parent.zoomScale = pdfView.scaleFactor
                    }
                    self.parent.onAutoScalesChange?(pdfView.autoScales)
                    self.reportReadingLocation(of: pdfView)
                    self.prefetchAdjacentPages(in: pdfView)
                    (pdfView as? ThemedPDFView)?.applyThemeLayers()
                }
            }

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
                    if Self.isLive(pdfView) {
                        self?.lastDestination = pdfView.currentDestination
                    }
                }
                let magnifyObs = nc.addObserver(
                    forName: NSScrollView.willStartLiveMagnifyNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self, weak pdfView] _ in
                    guard let self, let pdfView, Self.isLive(pdfView) else { return }
                    if pdfView.autoScales {
                        let themed = pdfView as? ThemedPDFView
                        themed?.wantsAutoScales = false
                        themed?.isApplyingConfiguration = true
                        pdfView.autoScales = false
                        themed?.isApplyingConfiguration = false
                        self.parent.onAutoScalesChange?(false)
                    }
                }
                observers.append(contentsOf: [scrollObs, magnifyObs])
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
            guard Self.isLive(pdfView), let document = pdfView.document else { return }
            if let handler = parent.onReadingLocationChange,
               let destination = pdfView.currentDestination,
               let page = destination.page {
                let quarterView = pdfView.bounds.height / max(pdfView.scaleFactor, 0.01) / 4
                handler(document.index(for: page), destination.point.y - quarterView)
            }
            if let handler = parent.onReadingSpotChange {
                let top = Self.topEdge(of: pdfView)
                if let page = pdfView.page(for: top, nearest: true) {
                    handler(DocumentTabState.ReadingSpot(pageIndex: document.index(for: page), point: pdfView.convert(top, to: page)))
                }
            }
        }

        /// The middle of the view's top edge, in the view's coordinates
        static func topEdge(of pdfView: PDFView) -> CGPoint {
            let bounds = pdfView.bounds
            return CGPoint(x: bounds.midX, y: pdfView.isFlipped ? bounds.minY : bounds.maxY)
        }

        /// Scrolls vertically so `spot` is at the top of the view again; a spot in a margin the crop boxes now
        /// leave out moves to the edge of what is shown
        static func scroll(_ pdfView: PDFView, toTop spot: DocumentTabState.ReadingSpot) {
            guard let document = pdfView.document, let page = document.page(at: spot.pageIndex),
                  let scrollView = pdfView.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let documentView = scrollView.documentView else { return }
            let shown = page.bounds(for: pdfView.displayBox)
            let point = CGPoint(x: spot.point.x, y: min(max(spot.point.y, shown.minY), shown.maxY))
            let target = documentView.convert(pdfView.convert(point, from: page), from: pdfView)
            let top = documentView.convert(topEdge(of: pdfView), from: pdfView)
            let clipView = scrollView.contentView
            var origin = clipView.bounds.origin
            origin.y += target.y - top.y
            clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

// MARK: - ThemedPDFView (Sharp Retina Viewport Shader Filtering + Arrow Key Navigation)

final class ThemedPDFView: PDFView {
    lazy var ocrSelectionOverlay = OCRTextSelectionOverlay(pdfView: self)

    func installOCRSelection() {
        if ocrSelectionOverlay.superview == nil { addSubview(ocrSelectionOverlay, positioned: .above, relativeTo: nil) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if ocrSelectionOverlay.superview != nil,
           let target = ocrSelectionOverlay.hitTest(convert(point, from: superview)) { return target }
        if NSApp.currentEvent?.type == .leftMouseDown, bounds.contains(convert(point, from: superview)) {
            ocrSelectionOverlay.clear()
            if window?.firstResponder === ocrSelectionOverlay { window?.makeFirstResponder(self) }
        }
        return super.hitTest(point)
    }
    var currentTheme: PDFViewTheme = .day
    var isDarkUI: Bool = false
    var onStepPage: ((Int) -> Void)?
    var handlesUnfocusedArrowKeys = true
    var readsRightToLeft = false
    var wantsAutoScales = true
    var isApplyingConfiguration = false
    var onAutoScalesDidChange: ((Bool) -> Void)?
    var onDidSettleLiveLayout: (() -> Void)?

    /// Page and zoom to show once the view has a size: `go(to:)` and `scaleFactor` before the first layout are lost.
    var pendingInitialPage: PDFPage?
    var pendingInitialScale: CGFloat?
    var pendingInitialSpot: DocumentTabState.ReadingSpot?
    private var isShowingInitialPage = false
    private var hasSettledLiveLayout = false
    private var lastSettledSize: CGSize = .zero

    /// Until the saved page and zoom are shown, PDFKit reports page 1 and a clamped zoom of the fresh layout
    var isRestoringInitialState: Bool {
        pendingInitialPage != nil || pendingInitialScale != nil || pendingInitialSpot != nil
    }

    private var textRecognitionTask: Task<Void, Never>?

    override func copy(_ sender: Any?) {
        if ocrSelectionOverlay.copySelectionIfPresent() { return }
        if let selection = currentSelection, selection.pages.count == 1,
           let page = selection.pages.first, page.rotation == 0,
           (page.hasFullPageScanImage || PDFSelectionVisibility.hasOverlappingText(selection, on: page)),
           document?.allowsCopying == true {
            recognizeText(on: page, selectionBounds: selection.bounds(for: page))
            return
        }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        super.copy(sender)
        if pasteboard.changeCount != before { PDFTextCleanup.normalize(pasteboard) }
    }

    private func recognizeText(on page: PDFPage, selectionBounds: CGRect) {
        guard textRecognitionTask == nil else { return }
        guard let data = page.dataRepresentation else { return }
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        let status = NSStackView(views: [progress, NSTextField(labelWithString: L10n.tr("正在识别文字…", "Recognizing text…"))])
        status.translatesAutoresizingMaskIntoConstraints = false
        status.spacing = 8
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(status)
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44),
            status.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
            status.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -8)
        ])
        let originalDocument = document
        textRecognitionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try PageTextRecognition.recognize(pageData: data, selectionBounds: selectionBounds) } }.value
            backdrop.removeFromSuperview()
            guard let self else { return }
            self.textRecognitionTask = nil
            guard self.document === originalDocument else { return }
            switch result {
            case .success(let text):
                self.copyRecognizedText(text)
            case .failure(let error):
                guard let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = L10n.tr("复制", "Copy")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private func copyRecognizedText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSAccessibility.post(element: self, notification: .announcementRequested,
            userInfo: [.announcement: L10n.tr("已复制", "Copied"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func focused(in window: NSWindow?) -> ThemedPDFView? {
        if let view = window?.firstResponder as? NSView, let pdf = enclosingPDFView(of: view) as? ThemedPDFView { return pdf }
        func find(_ view: NSView) -> ThemedPDFView? {
            if let pdf = view as? ThemedPDFView { return pdf }
            return view.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    override var autoScales: Bool {
        didSet {
            guard autoScales != oldValue, !isApplyingConfiguration else { return }
            wantsAutoScales = autoScales
            let newValue = autoScales
            DispatchQueue.main.async { [weak self] in
                guard let self, PDFReaderCanvasView.Coordinator.isLive(self) else { return }
                self.onAutoScalesDidChange?(newValue)
            }
        }
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
    /// Reading right to left, ← is the next page, as it lies on the left of a right-bound book's spread.
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
        let towardLeft = event.keyCode == 123
        return towardLeft != readsRightToLeft ? -1 : 1
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
        settleLiveStateIfNeeded()
        applyThemeLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settleLiveStateIfNeeded()
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

    /// Synchronizes initial page/zoom and fit-width scaling once `PDFView` has both a non-zero frame and a window
    /// (macOS `NSHostingView` sizes `PDFView` before attaching it to `window`, so early `ScaleChanged` events fire
    /// while `window == nil` and would otherwise leave `zoomScale` out of sync).
    private func settleLiveStateIfNeeded() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }

        if isRestoringInitialState {
            guard !isShowingInitialPage else { return }
            isShowingInitialPage = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.window != nil, self.bounds.width > 1, self.bounds.height > 1 else {
                    self.isShowingInitialPage = false
                    return
                }
                self.isApplyingConfiguration = true
                if let scale = self.pendingInitialScale {
                    self.wantsAutoScales = false
                    self.autoScales = false
                    self.scaleFactor = scale
                } else if self.wantsAutoScales {
                    self.autoScales = true
                }
                if let page = self.pendingInitialPage {
                    self.go(to: page)
                    if self.wantsAutoScales {
                        self.autoScales = true
                    }
                }
                if let spot = self.pendingInitialSpot {
                    PDFReaderCanvasView.Coordinator.scroll(self, toTop: spot)
                }
                self.pendingInitialScale = nil
                self.pendingInitialPage = nil
                self.pendingInitialSpot = nil
                self.isShowingInitialPage = false
                self.hasSettledLiveLayout = true
                self.lastSettledSize = self.bounds.size
                self.isApplyingConfiguration = false
                self.onDidSettleLiveLayout?()
            }
        } else if !hasSettledLiveLayout {
            hasSettledLiveLayout = true
            lastSettledSize = bounds.size
            if wantsAutoScales && !autoScales {
                isApplyingConfiguration = true
                autoScales = true
                isApplyingConfiguration = false
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.window != nil, self.bounds.width > 1, self.bounds.height > 1 else {
                    self.hasSettledLiveLayout = false
                    return
                }
                if self.wantsAutoScales && !self.autoScales {
                    self.isApplyingConfiguration = true
                    self.autoScales = true
                    self.isApplyingConfiguration = false
                }
                self.lastSettledSize = self.bounds.size
                self.onDidSettleLiveLayout?()
            }
        } else if abs(bounds.width - lastSettledSize.width) > 0.5 || abs(bounds.height - lastSettledSize.height) > 0.5 {
            lastSettledSize = bounds.size
            if autoScales {
                isApplyingConfiguration = true
                autoScales = true
                isApplyingConfiguration = false
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, PDFReaderCanvasView.Coordinator.isLive(self) else { return }
                self.onDidSettleLiveLayout?()
            }
        }
    }

    private var appliedTheme: PDFViewTheme?
    private var appliedDarkUI: Bool?
    private var appliedBackingScale: CGFloat = 0
    private weak var filteredScrollLayer: CALayer?

    func applyThemeLayers() {
        let changed = appliedTheme != currentTheme || appliedDarkUI != isDarkUI
        if !wantsLayer { wantsLayer = true }
        if !layerUsesCoreImageFilters { layerUsesCoreImageFilters = true }
        if backgroundColor != .clear { backgroundColor = .clear }
        if changed {
            layer?.backgroundColor = currentTheme.documentBackgroundNSColor(isDarkUI: isDarkUI).cgColor
            // Public PDFKit API; no per-page private layer traversal on every layout/scroll.
            pageShadowsEnabled = currentTheme != .night
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let scroll = subviews.compactMap({ $0 as? NSScrollView }).first {
            if !scroll.wantsLayer { scroll.wantsLayer = true }
            if scroll.drawsBackground { scroll.drawsBackground = false }
            if changed || filteredScrollLayer !== scroll.layer || appliedBackingScale != scale {
                scroll.layerUsesCoreImageFilters = currentTheme != .day
                scroll.layer?.contentsScale = scale
                scroll.layer?.rasterizationScale = scale
                scroll.layer?.backgroundColor = NSColor.clear.cgColor
                // Reassigning these filters on each PDFKit layout invalidated the entire scan viewport.
                scroll.layer?.filters = MetalShaderRenderer.shared.pageLayerFilters(for: currentTheme)
                filteredScrollLayer = scroll.layer
            }
        }
        appliedTheme = currentTheme
        appliedDarkUI = isDarkUI
        appliedBackingScale = scale
    }

    // Keep PDFKit's native accessibility tree: it exposes full text, links and tables.
}

// MARK: - SpreadAlignment (two-page layouts meet at the spine)

/// PDFKit sizes each column of a two-page layout to the widest page of the whole document and centres the
/// narrower ones in it, so a scan whose covers are a little wider than its text pages shows a gap at the spine
/// of every spread. In spreads each page is brought to the common width instead: a slightly wider page (a cover)
/// loses a sliver on both sides, a narrower one gains paper on its outer edge. Only the displayed box changes,
/// only in memory, and leaving the spread layout puts the original boxes back.
enum SpreadAlignment {
    struct Spread: Equatable {
        var isBook: Bool
        var readsRightToLeft: Bool
    }

    private struct Adjustment {
        let box: PDFDisplayBox
        let original: CGRect
        let applied: CGRect
    }

    private final class Adjustments {
        /// In the order they were made, per page
        var byPage: [Int: [Adjustment]] = [:]
    }

    private static let adjustments = NSMapTable<PDFDocument, Adjustments>.weakToStrongObjects()

    /// The crop box before spread padding, including when a cropper first visits a page in two-page mode.
    static func unalignedCropBox(for page: PDFPage, at index: Int, in document: PDFDocument) -> CGRect {
        adjustments.object(forKey: document)?.byPage[index]?.first(where: { $0.box == .cropBox })?.original
            ?? page.bounds(for: .cropBox)
    }

    /// Pages further than this from the common width (fold-outs, inserts) are left as they are
    private static let tolerance: CGFloat = 0.15

    /// Aligns the crop boxes the view shows. `holdsContent`: Clear Margins set them to the content, which is never
    /// cut; otherwise they are the paper, which a slightly oversized cover can lose a sliver of.
    static func apply(to document: PDFDocument, holdsContent: Bool, spread: Spread?) {
        let record = adjustments.object(forKey: document) ?? {
            let record = Adjustments()
            adjustments.setObject(record, forKey: document)
            return record
        }()
        // Undo the previous alignment, except where the box has been set since (Clear Margins)
        for (index, pageAdjustments) in record.byPage {
            guard let page = document.page(at: index) else { continue }
            for adjustment in pageAdjustments.reversed()
            where page.bounds(for: adjustment.box).isAlmostEqual(to: adjustment.applied) {
                page.setBounds(adjustment.original, for: adjustment.box)
            }
        }
        record.byPage.removeAll()
        guard let spread else { return }

        var widths: [Int: CGFloat] = [:]
        for index in 0..<document.pageCount {
            // A quarter-turned page shows its height across the spread; leave it be
            guard let page = document.page(at: index), page.rotation % 180 == 0 else { continue }
            widths[index] = page.bounds(for: .cropBox).width
        }
        guard let target = holdsContent ? widths.values.max() : commonWidth(of: Array(widths.values)) else { return }

        for (index, width) in widths {
            guard let page = document.page(at: index) else { continue }
            let original = page.bounds(for: .cropBox)
            var aligned = original
            let upsideDown = page.rotation % 360 != 0
            if abs(width - target) > 0.5 && (holdsContent || abs(width - target) <= target * tolerance) {
                if width > target {
                    if !holdsContent { aligned = original.insetBy(dx: (width - target) / 2, dy: 0) }
                } else {
                    if isInLeftColumn(index, spread: spread) != upsideDown { aligned.origin.x -= target - width }
                    aligned.size.width = target
                }
            }
            // PDFKit centres unequal-height pages in their row. Add blank paper BELOW the shorter
            // page so both paper edges and the top of the cropped content start at the same height.
            let partner = spread.isBook ? (index == 0 ? -1 : (index % 2 == 1 ? index + 1 : index - 1)) : index ^ 1
            if widths[partner] != nil, let other = document.page(at: partner) {
                let height = max(original.height, other.bounds(for: .cropBox).height)
                if height - original.height > 0.5 {
                    if !upsideDown { aligned.origin.y -= height - original.height }
                    aligned.size.height = height
                }
            }
            guard !original.isAlmostEqual(to: aligned) else { continue }
            var pageAdjustments: [Adjustment] = []
            let paper = page.bounds(for: .mediaBox)
            if !paper.contains(aligned) {
                let extended = paper.union(aligned)
                page.setBounds(extended, for: .mediaBox)
                pageAdjustments.append(Adjustment(box: .mediaBox, original: paper, applied: page.bounds(for: .mediaBox)))
            }
            page.setBounds(aligned, for: .cropBox)
            pageAdjustments.append(Adjustment(box: .cropBox, original: original, applied: page.bounds(for: .cropBox)))
            record.byPage[index] = pageAdjustments
        }
    }

    /// The paper size most pages share. Clear Margins uses the widest content box so it never cuts ink.
    private static func commonWidth(of widths: [CGFloat]) -> CGFloat? {
        guard !widths.isEmpty else { return nil }
        let median = widths.sorted()[widths.count / 2]
        let counts = Dictionary(grouping: widths, by: { $0.rounded() }).mapValues(\.count)
        if let (width, count) = counts.max(by: { $0.value < $1.value }), count > 1 { return width }
        return median
    }

    /// A book layout shows the first page alone, then pairs (2, 3), (4, 5)…; a plain one pairs (1, 2), (3, 4)…
    private static func isInLeftColumn(_ index: Int, spread: Spread) -> Bool {
        let leftReadingLeftToRight = spread.isBook ? index % 2 == 1 : index % 2 == 0
        return leftReadingLeftToRight != spread.readsRightToLeft
    }
}

private extension CGRect {
    func isAlmostEqual(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.01 && abs(minY - other.minY) < 0.01
            && abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }
}
