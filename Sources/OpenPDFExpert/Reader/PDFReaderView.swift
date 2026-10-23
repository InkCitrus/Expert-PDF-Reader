import AppKit
import PDFKit
import SwiftUI

/// Replicates `PDFDocumentPresentationViewController` + `PDFDocumentsSplitViewController` from `PDFExpert`:
/// Combines top `ReaderToolbarView`, left `ReaderLeftSidebarView`, primary `RDPDFDocumentViewWrapper`,
/// and optional Split View comparison pane (vertical/horizontal, swap sides, sync scroll/zoom, and embedded HomeTab picker).
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

            // Main Workspace: Left Sidebar + Primary/Split PDF Canvas
            HStack(spacing: 0) {
                if tab.isLeftSidebarVisible {
                    ReaderLeftSidebarView(store: store, tab: tab)
                        .transition(.move(edge: .leading))
                }

                // Split or Single Canvas Area
                Group {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(store.pdfTheme.documentBackgroundColor(isDarkUI: isDark))
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
            // Secondary Split Pane Header Bar
            HStack(spacing: 8) {
                Image(systemName: tab.splitMode == .vertical ? "rectangle.split.2x1.fill" : "rectangle.split.1x2.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(RDColorPalette.primaryTint)

                Text(tab.secondaryDocumentURL?.deletingPathExtension().lastPathComponent ?? tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                    .lineLimit(1)

                if let secDoc = tab.secondaryPDFDocument, !tab.showSplitDocumentPicker {
                    Text("(\(tab.secondaryPageIndex + 1)/\(secDoc.pageCount))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(RDColorPalette.labelSecondary(isDark))
                }

                Spacer()

                Toggle("同步滚动", isOn: $tab.syncScrollAndZoom)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11))

                Button {
                    tab.showSplitDocumentPicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                        Text(tab.showSplitDocumentPicker ? "返回文档" : "选择对比文档")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(RDColorPalette.tertiarySystemBackground(isDark))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    tab.isSplitSwapped.toggle()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("对调分屏位置")

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        tab.splitMode = .disabled
                        tab.showSplitDocumentPicker = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("关闭分屏视图")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RDColorPalette.secondarySystemBackground(isDark))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RDColorPalette.separator(isDark).opacity(0.55))
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
