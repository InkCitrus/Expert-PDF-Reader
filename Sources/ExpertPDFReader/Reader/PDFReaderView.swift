import AppKit
import PDFKit
import SwiftUI

/// The reader of one document tab:
/// `ReaderToolbarView` on top, the left dock (`ReaderLeftSidebarView`), the primary `PDFReaderCanvasView`
/// with its page indicator / page overview, the optional Split View comparison pane and the right search dock.
public struct PDFReaderView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public init(store: AppStore, tab: DocumentTabState) {
        self.store = store
        self.tab = tab
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Reader Toolbar
            ReaderToolbarView(store: store, tab: tab)

            // Main Workspace: Left Dock + Canvas (single / split / page overview) + Search Dock
            HStack(spacing: 0) {
                if tab.isLeftSidebarVisible {
                    ReaderLeftSidebarView(store: store, tab: tab)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    canvasArea
                        .accessibilityHidden(tab.isPageOverviewVisible)

                    if tab.isPageOverviewVisible {
                        PageOverviewGridView(store: store, tab: tab, isDark: isDark)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if tab.isSearchVisible {
                    SearchResultsPanel(tab: tab, isDark: isDark)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(AppAnimation.panel, value: tab.isLeftSidebarVisible)
            .animation(AppAnimation.panel, value: tab.isSearchVisible)
            .animation(AppAnimation.panel, value: tab.isPageOverviewVisible)
            .animation(AppAnimation.panel, value: tab.splitMode)
        }
        .background(store.resolvedPDFTheme(isDark: isDark).documentBackgroundColor(isDarkUI: isDark))
    }

    // MARK: - Split or Single Canvas Area

    @ViewBuilder
    private var canvasArea: some View {
        switch tab.splitMode {
        case .disabled:
            primaryCanvasPane
        case .vertical:
            HSplitView {
                if tab.isSplitSwapped {
                    secondarySplitPane
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    primaryCanvasPane
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    primaryCanvasPane
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    secondarySplitPane
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .horizontal:
            VSplitView {
                if tab.isSplitSwapped {
                    secondarySplitPane
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    primaryCanvasPane
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                } else {
                    primaryCanvasPane
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    secondarySplitPane
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Primary PDF Canvas Pane

    private var primaryCanvasPane: some View {
        PDFReaderCanvasView(
            pdfDocument: tab.pdfDocument,
            currentPageIndex: $tab.currentPageIndex,
            zoomScale: $tab.zoomScale,
            layoutMode: tab.layoutMode,
            readsRightToLeft: tab.readsRightToLeft,
            isClearMarginsEnabled: tab.isClearMarginsEnabled,
            pdfTheme: store.resolvedPDFTheme(isDark: isDark),
            isDarkUI: isDark,
            searchMatches: tab.searchMatches,
            selectedMatchIndex: tab.selectedMatchIndex,
            pageJumpToken: tab.pageJumpToken,
            zoomCommandToken: tab.zoomCommandToken,
            pendingZoomAction: tab.pendingZoomAction,
            isAutoScaling: tab.isAutoScaling,
            layoutToken: tab.clearMarginsLayoutToken,
            readingSpot: tab.readingSpotBeforeCropChange,
            onAutoScalesChange: { autoScales in
                tab.updateAutoScalingFromView(autoScales)
            },
            onStepPage: { delta in
                tab.navigateToPage(tab.currentPageIndex + delta)
            },
            onReadingLocationChange: { pageIndex, readingLineY in
                tab.readingLocation.update(pageIndex: pageIndex, readingLineY: readingLineY)
            },
            onReadingSpotChange: { spot in
                tab.readingSpot = spot
            },
            pageLabelProvider: { idx in
                tab.displayPageNumber(at: idx)
            }
        )
        .overlay(alignment: .bottomTrailing) {
            PageIndicatorOverlay(tab: tab)
                .padding(16)
        }
        .onChange(of: tab.currentPageIndex) { _, newPage in
            if tab.syncScrollAndZoom,
               let secDoc = tab.secondaryPDFDocument,
               newPage < secDoc.pageCount {
                tab.secondaryPageIndex = newPage
            }
        }
        .onChange(of: tab.zoomScale) { _, newScale in
            if tab.syncScrollAndZoom {
                tab.secondaryZoomScale = newScale
            }
        }
    }

    // MARK: - Secondary Split View Pane

    private var secondarySplitPane: some View {
        VStack(spacing: 0) {
            // Secondary Split Pane Header Bar (toolbar-styled)
            HStack(spacing: 6) {
                Image(systemName: tab.splitMode == .vertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(AppPalette.accentBlue)

                Text(tab.secondaryDocumentURL?.deletingPathExtension().lastPathComponent ?? tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let secDoc = tab.secondaryPDFDocument, !tab.showSplitDocumentPicker {
                    Text("\(tab.secondaryPageIndex + 1) / \(secDoc.pageCount)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(AppAnimation.micro, value: tab.secondaryPageIndex)
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }

                Spacer(minLength: 8)

                Toggle(L10n.tr("同步滚动", "Sync Scroll"), isOn: $tab.syncScrollAndZoom)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundColor(AppPalette.labelSecondary(isDark))

                ToolbarIconButton(
                    icon: tab.showSplitDocumentPicker ? "doc.text" : "folder",
                    tooltip: tab.showSplitDocumentPicker ? L10n.tr("返回对比文档", "Back to Document") : L10n.tr("选择对比文档", "Select Document"),
                    isActive: tab.showSplitDocumentPicker,
                    isDark: isDark
                ) {
                    withAnimation(AppAnimation.snappy) {
                        tab.showSplitDocumentPicker.toggle()
                    }
                }

                ToolbarIconButton(icon: "arrow.left.arrow.right", tooltip: L10n.tr("对调分屏位置", "Swap Split Position"), isDark: isDark) {
                    withAnimation(AppAnimation.snappy) {
                        tab.isSplitSwapped.toggle()
                    }
                }

                ToolbarIconButton(icon: "xmark", tooltip: L10n.tr("关闭分屏视图", "Close Split View"), isDark: isDark) {
                    withAnimation(AppAnimation.panel) {
                        tab.splitMode = .disabled
                        tab.showSplitDocumentPicker = false
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(AppPalette.toolbarBackground(isDark))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppPalette.chromeHairline(isDark))
                    .frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(L10n.tr("分屏视图", "Split View")))

            // Secondary Split Content: the Home tab as a document picker, or the secondary PDF view
            if tab.showSplitDocumentPicker {
                HomeTabRootView(store: store, isStandaloneSplitPane: true) { chosenURL in
                    tab.setSecondaryDocument(url: chosenURL)
                }
            } else if let secDoc = tab.secondaryPDFDocument {
                PDFReaderCanvasView(
                    pdfDocument: secDoc,
                    currentPageIndex: Binding(
                        get: { tab.secondaryPageIndex },
                        set: { newIdx in
                            tab.secondaryPageIndex = newIdx
                            if tab.syncScrollAndZoom && newIdx < tab.pageCount {
                                tab.currentPageIndex = newIdx
                            }
                        }
                    ),
                    zoomScale: Binding(
                        get: { tab.secondaryZoomScale },
                        set: { newScale in
                            tab.secondaryZoomScale = newScale
                            if tab.syncScrollAndZoom {
                                tab.zoomScale = newScale
                            }
                        }
                    ),
                    layoutMode: tab.layoutMode,
                    // The other document of a comparison keeps its own direction (left to right)
                    readsRightToLeft: secDoc === tab.pdfDocument && tab.readsRightToLeft,
                    isClearMarginsEnabled: tab.isClearMarginsEnabled,
                    pdfTheme: store.resolvedPDFTheme(isDark: isDark),
                    isDarkUI: isDark,
                    isAutoScaling: tab.secondaryIsAutoScaling,
                    layoutToken: tab.clearMarginsLayoutToken,
                    readingSpot: tab.secondaryReadingSpotBeforeCropChange,
                    handlesUnfocusedArrowKeys: false,
                    onAutoScalesChange: { autoScales in
                        if tab.secondaryIsAutoScaling != autoScales {
                            tab.secondaryIsAutoScaling = autoScales
                        }
                    },
                    onStepPage: { delta in
                        let clamped = max(0, min(max(0, secDoc.pageCount - 1), tab.secondaryPageIndex + delta))
                        tab.secondaryPageIndex = clamped
                        if tab.syncScrollAndZoom && clamped < tab.pageCount {
                            tab.currentPageIndex = clamped
                        }
                    },
                    onReadingSpotChange: { spot in
                        tab.secondaryReadingSpot = spot
                    },
                    pageLabelProvider: { idx in
                        if secDoc === tab.pdfDocument {
                            return tab.displayPageNumber(at: idx)
                        }
                        return secDoc.page(at: idx)?.printedNumber ?? "\(idx + 1)"
                    }
                )
            } else {
                HomeTabRootView(store: store, isStandaloneSplitPane: true) { chosenURL in
                    tab.setSecondaryDocument(url: chosenURL)
                }
            }
        }
    }
}
