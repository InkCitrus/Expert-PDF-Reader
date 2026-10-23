import AppKit
import PDFKit
import SwiftUI

/// Replicates `PDFDocumentPresentationViewController` + `PDFDocumentsSplitViewController` from `PDFExpert`:
/// `ReaderToolbarView` on top, the left dock (`ReaderLeftSidebarView`), the primary `RDPDFDocumentViewWrapper`
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

                    if tab.isPageOverviewVisible {
                        PageOverviewGridView(store: store, tab: tab, isDark: isDark)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if tab.isSearchVisible {
                    SearchResultsPanel(tab: tab, isDark: isDark)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(store.pdfTheme.documentBackgroundColor(isDarkUI: isDark))
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
        RDPDFDocumentViewWrapper(
            pdfDocument: tab.pdfDocument,
            currentPageIndex: $tab.currentPageIndex,
            zoomScale: $tab.zoomScale,
            layoutMode: tab.layoutMode,
            isClearMarginsEnabled: tab.isClearMarginsEnabled,
            pdfTheme: store.pdfTheme,
            isDarkUI: isDark,
            searchMatches: tab.searchMatches,
            selectedMatchIndex: tab.selectedMatchIndex,
            pageJumpToken: tab.pageJumpToken,
            zoomCommandToken: tab.zoomCommandToken,
            pendingZoomAction: tab.pendingZoomAction
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

    // MARK: - Secondary Split View Pane (PDFDocumentsSplitViewController)

    private var secondarySplitPane: some View {
        VStack(spacing: 0) {
            // Secondary Split Pane Header Bar (toolbar-styled)
            HStack(spacing: 6) {
                Image(systemName: tab.splitMode == .vertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(RDColorPalette.accentBlue)

                Text(tab.secondaryDocumentURL?.deletingPathExtension().lastPathComponent ?? tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let secDoc = tab.secondaryPDFDocument, !tab.showSplitDocumentPicker {
                    Text("\(tab.secondaryPageIndex + 1) / \(secDoc.pageCount)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(RDColorPalette.labelTertiary(isDark))
                }

                Spacer(minLength: 8)

                Toggle("同步滚动", isOn: $tab.syncScrollAndZoom)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))

                ToolbarIconButton(
                    icon: tab.showSplitDocumentPicker ? "doc.text" : "folder",
                    tooltip: tab.showSplitDocumentPicker ? "返回对比文档" : "选择对比文档",
                    isActive: tab.showSplitDocumentPicker,
                    isDark: isDark
                ) {
                    tab.showSplitDocumentPicker.toggle()
                }

                ToolbarIconButton(icon: "arrow.left.arrow.right", tooltip: "对调分屏位置", isDark: isDark) {
                    tab.isSplitSwapped.toggle()
                }

                ToolbarIconButton(icon: "xmark", tooltip: "关闭分屏视图", isDark: isDark) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        tab.splitMode = .disabled
                        tab.showSplitDocumentPicker = false
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(RDColorPalette.toolbarBackground(isDark))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RDColorPalette.chromeHairline(isDark))
                    .frame(height: 1)
            }

            // Secondary Split Content: Either HomeTabViewFactory.makeSplitScreenHomeTabView or Secondary PDFView
            if tab.showSplitDocumentPicker {
                HomeTabRootView(store: store, isStandaloneSplitPane: true) { chosenURL in
                    tab.setSecondaryDocument(url: chosenURL)
                }
            } else if let secDoc = tab.secondaryPDFDocument {
                RDPDFDocumentViewWrapper(
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
                    isClearMarginsEnabled: tab.isClearMarginsEnabled,
                    pdfTheme: store.pdfTheme,
                    isDarkUI: isDark
                )
            } else {
                HomeTabRootView(store: store, isStandaloneSplitPane: true) { chosenURL in
                    tab.setSecondaryDocument(url: chosenURL)
                }
            }
        }
    }
}
