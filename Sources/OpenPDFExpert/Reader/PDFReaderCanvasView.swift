import AppKit
import PDFKit
import QuartzCore
import SwiftUI

/// Replicates `RDPDFDocumentView` from `RDPDFKit.framework`:
/// - Applies exact theme background color (`#DCDCDE`/`#131314` Day, `#E5DECF` Sepia, `#202223` Night).
/// - Attaches GPU `CIFilter` matching `sepiaTexturingModeFragmentShader` and `nightTexturingModeFragmentShader`
///   to each `PDFPageLayer`'s tile container (`sublayers[2].sublayers[0]`) and sets the paper layer (`sublayers[3]`)
///   to `#FFFFFF` / `#F5EFDC` / `#000000` while keeping drop shadows (`sublayers[0..1]`) and text selection (`sublayers[2].sublayers[1]`) untouched.
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
        pendingZoomAction: DocumentTabState.ZoomAction? = nil
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
        // 1. Display Layout Mode
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
        if pdfView.displayMode != targetDisplayMode {
            pdfView.displayMode = targetDisplayMode
        }
        if pdfView.displaysAsBook != targetDisplaysAsBook {
            pdfView.displaysAsBook = targetDisplaysAsBook
        }

        // 2. Display Box (Clear Margins)
        let targetBox: PDFDisplayBox = isClearMarginsEnabled ? .cropBox : .mediaBox
        if pdfView.displayBox != targetBox {
            pdfView.displayBox = targetBox
            pdfView.layoutDocumentView()
        }

        // 3. Theme Background & Page Layer Shaders
        let bgColor = pdfTheme.documentBackgroundNSColor(isDarkUI: isDarkUI)
        if pdfView.backgroundColor != bgColor {
            pdfView.backgroundColor = bgColor
        }
        if let themed = pdfView as? ThemedPDFView {
            themed.currentTheme = pdfTheme
            themed.applyThemeToPageLayers()
        }

        // 4. Page Navigation Jump
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

        // 5. Imperative Zoom Commands
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
                }
                DispatchQueue.main.async {
                    self.zoomScale = pdfView.scaleFactor
                }
            }
        }

        // 6. Search Highlighted Selections
        if searchMatches.isEmpty {
            if pdfView.highlightedSelections != nil {
                pdfView.highlightedSelections = nil
            }
        } else {
            let selections = searchMatches.enumerated().map { idx, item -> PDFSelection in
                let sel = item.selection.copy() as! PDFSelection
                sel.color = (idx == selectedMatchIndex)
                    ? NSColor.systemOrange.withAlphaComponent(0.65)
                    : NSColor.systemYellow.withAlphaComponent(0.42)
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

        init(parent: RDPDFDocumentViewWrapper) {
            self.parent = parent
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
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
                (pdfView as? ThemedPDFView)?.applyThemeToPageLayers()
            }

            let scaleObs = nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView else { return }
                if abs(pdfView.scaleFactor - self.parent.zoomScale) > 0.005 {
                    self.parent.zoomScale = pdfView.scaleFactor
                }
                (pdfView as? ThemedPDFView)?.applyThemeToPageLayers()
            }

            observers.append(contentsOf: [pageObs, scaleObs])

            if let scrollView = pdfView.enclosingScrollView ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
                scrollView.contentView.postsBoundsChangedNotifications = true
                let scrollObs = nc.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak pdfView] _ in
                    (pdfView as? ThemedPDFView)?.applyThemeToPageLayers()
                }
                observers.append(scrollObs)
            }
        }
    }
}

// MARK: - ThemedPDFView (Applies GPU Shaders to PDFPageLayer Tile & Paper Sublayers)

final class ThemedPDFView: PDFView {
    var currentTheme: PDFViewTheme = .day

    override func layout() {
        super.layout()
        applyThemeToPageLayers()
    }

    func applyThemeToPageLayers() {
        guard let docView = self.documentView else { return }
        docView.wantsLayer = true
        docView.layerUsesCoreImageFilters = true

        let filters = MetalShaderRenderer.shared.pageLayerFilters(for: currentTheme)
        let paperCGColor = currentTheme.pagePaperNSColor.cgColor

        for pageView in docView.subviews {
            pageView.wantsLayer = true
            pageView.layerUsesCoreImageFilters = true
            guard let pageLayer = pageView.layer else { continue }

            // Inspect PDFPageLayer structure discovered during reverse engineering:
            // sublayers[0..1] = drop shadows (shadowOpacity 0.04, 0.08) -> keep untouched!
            // sublayers[2] = content container (sublayers[0] = PDFPageLayerTile container, sublayers[1] = PDFPageLayerSelectionEffect)
            // sublayers[3] = page paper background layer (bounds = page rect)
            if let sublayers = pageLayer.sublayers, sublayers.count >= 4 {
                let contentContainer = sublayers[2]
                if let contentChildren = contentContainer.sublayers, !contentChildren.isEmpty {
                    let tilesContainer = contentChildren[0]
                    tilesContainer.filters = filters
                } else {
                    contentContainer.filters = filters
                }
                let paperLayer = sublayers[3]
                paperLayer.backgroundColor = paperCGColor
                pageLayer.filters = nil
            } else {
                // Fallback if PDFPageLayer sublayers haven't populated yet
                pageLayer.filters = filters
            }
        }
    }
}
