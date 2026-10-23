import AppKit
import PDFKit
import QuartzCore
import SwiftUI

/// Replicates `RDPDFDocumentView` from `RDPDFKit.framework`:
/// - Applies exact theme background color (`#DCDCDE`/`#131314` Day, `#E5DECF` Sepia, `#202223` Night) on the root `ThemedPDFView` layer.
/// - Attaches the GPU `CIFilter` (`sepiaTexturingModeFragmentShader` / `nightTexturingModeFragmentShader` color matrices)
///   to `PDFScrollView.layer` (**above** `NSClipView.layer`'s magnification transform) while keeping `PDFScrollView`'s
///   background transparent (`alpha = 0`). This guarantees that `PDFPageLayerTile` bitmaps (`contentsScale = backingScale * magnification`)
///   are never offscreen-downsampled before `NSClipView` magnification, completely eliminating PDF blurriness when switching themes or layouts.
/// - Supports Left (`←`) and Right (`→`) arrow key page navigation.
public struct RDPDFDocumentViewWrapper: NSViewRepresentable {
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
    public let onStepPage: ((Int) -> Void)?

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
        onStepPage: ((Int) -> Void)? = nil
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
        self.onStepPage = onStepPage
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> PDFView {
        let pdfView = ThemedPDFView()
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        pdfView.interpolationQuality = .high
        pdfView.backgroundColor = .clear
        pdfView.document = pdfDocument

        context.coordinator.setupNotifications(for: pdfView)
        applyConfiguration(to: pdfView, coordinator: context.coordinator)
        return pdfView
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
            let wasAutoScaling = pdfView.autoScales
            let savedPage = pdfView.currentPage
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
            if wasAutoScaling {
                pdfView.autoScales = true
            }
            if let savedPage, pdfView.currentPage !== savedPage {
                pdfView.go(to: savedPage)
            }
            pdfView.needsDisplay = true
            DispatchQueue.main.async {
                if abs(pdfView.scaleFactor - self.zoomScale) > 0.005 {
                    self.zoomScale = pdfView.scaleFactor
                }
            }
        }

        // 2. Theme Background & Viewport Shader Filtering
        if let themed = pdfView as? ThemedPDFView {
            themed.onStepPage = onStepPage
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
                        let pageBounds = page.bounds(for: pdfView.displayBox)
                        let viewBounds = pdfView.bounds.insetBy(dx: 24, dy: 24)
                        if pageBounds.width > 0 && pageBounds.height > 0 {
                            let scaleW = viewBounds.width / pageBounds.width
                            let scaleH = viewBounds.height / pageBounds.height
                            pdfView.scaleFactor = max(0.25, min(scaleW, scaleH))
                        }
                    }
                case .scale(let value):
                    pdfView.autoScales = false
                    pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, value))
                }
                DispatchQueue.main.async {
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
                    // Since scrollView.layer applies nightFilter (v = 0.75 - 0.25*(R+G+B)),
                    // a dark selection color inverts into a bright, crisp highlight on dark pages.
                    sel.color = (idx == selectedMatchIndex)
                        ? NSColor(calibratedWhite: 0.08, alpha: 0.65)
                        : NSColor(calibratedWhite: 0.22, alpha: 0.45)
                } else {
                    sel.color = (idx == selectedMatchIndex)
                        ? NSColor.systemOrange.withAlphaComponent(0.65)
                        : NSColor.systemYellow.withAlphaComponent(0.42)
                }
                return sel
            }
            pdfView.highlightedSelections = selections
            if selectedMatchIndex >= 0 && selectedMatchIndex < searchMatches.count {
                let activeSel = searchMatches[selectedMatchIndex].selection
                if coordinator.lastHighlightedMatchIndex != selectedMatchIndex {
                    coordinator.lastHighlightedMatchIndex = selectedMatchIndex
                    pdfView.go(to: activeSel)
                }
            }
        }
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject {
        var parent: RDPDFDocumentViewWrapper
        var lastPageJumpToken: Int = -1
        var lastZoomCommandToken: Int = -1
        var lastHighlightedMatchIndex: Int = -1
        private var observers: [NSObjectProtocol] = []
        nonisolated(unsafe) private var keyMonitor: Any?

        init(parent: RDPDFDocumentViewWrapper) {
            self.parent = parent
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        func setupNotifications(for pdfView: PDFView) {
            let nc = NotificationCenter.default

            let pageObs = nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView,
                      let doc = pdfView.document,
                      let page = pdfView.currentPage else { return }
                let idx = doc.index(for: page)
                if idx != self.parent.currentPageIndex {
                    self.parent.currentPageIndex = idx
                }
                (pdfView as? ThemedPDFView)?.applyThemeLayers()
            }

            let scaleObs = nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView else { return }
                if abs(pdfView.scaleFactor - self.parent.zoomScale) > 0.005 {
                    self.parent.zoomScale = pdfView.scaleFactor
                }
                (pdfView as? ThemedPDFView)?.applyThemeLayers()
            }

            observers.append(contentsOf: [pageObs, scaleObs])

            if let scrollView = pdfView.enclosingScrollView ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
                scrollView.contentView.postsBoundsChangedNotifications = true
                let scrollObs = nc.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak pdfView] _ in
                    (pdfView as? ThemedPDFView)?.applyThemeLayers()
                }
                observers.append(scrollObs)
            }

            // Local keyDown monitor for Left (←, 123) and Right (→, 124) arrow keys when onStepPage is provided
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak pdfView] event in
                guard let self = self,
                      let stepHandler = self.parent.onStepPage,
                      let pdfView = pdfView,
                      let window = pdfView.window,
                      event.window === window else {
                    return event
                }
                // Do not intercept arrow keys when typing inside any text field / search field
                if window.firstResponder is NSText {
                    return event
                }
                // Only handle unmodified Left / Right arrow keys (ignoring .numericPad / .function)
                let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
                    return event
                }
                switch event.keyCode {
                case 123: // Left Arrow (←) -> Previous Page
                    stepHandler(-1)
                    return nil
                case 124: // Right Arrow (→) -> Next Page
                    stepHandler(1)
                    return nil
                default:
                    return event
                }
            }
        }
    }
}

// MARK: - ThemedPDFView (Sharp Retina Viewport Shader Filtering + Arrow Key Navigation)

final class ThemedPDFView: PDFView {
    var currentTheme: PDFViewTheme = .day
    var isDarkUI: Bool = false
    var onStepPage: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        if event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           let onStepPage {
            if event.keyCode == 123 {
                onStepPage(-1)
                return
            } else if event.keyCode == 124 {
                onStepPage(1)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        applyThemeLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeLayers()
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
