import AppKit
import PDFKit
import SwiftUI

/// The workspace of one document tab:
/// the primary `PDFReaderCanvasView` with its page indicator / page overview,
/// the optional Split View comparison pane and the right search dock.
public struct PDFReaderView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @Environment(\.colorScheme) private var colorScheme
    @State private var draggedPaneLength: CGFloat?
    private var isDark: Bool { colorScheme == .dark }

    public init(store: AppStore, tab: DocumentTabState) {
        self.store = store
        self.tab = tab
    }

    public var body: some View {
        HStack(spacing: 0) {
            canvasArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(tab.isPageOverviewVisible)
                .allowsHitTesting(!tab.isPageOverviewVisible)
                // Overlay the live split so opening the grid never re-lays out its panes.
                .overlay {
                    if tab.isPageOverviewVisible {
                        PageOverviewGridView(store: store, tab: tab, isDark: isDark)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .clipped()

            if tab.isSearchVisible {
                SearchResultsPanel(tab: tab, isDark: isDark)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.panel, value: tab.isSearchVisible)
        .animation(AppAnimation.panel, value: tab.isPageOverviewVisible)
        .animation(AppAnimation.panel, value: tab.splitMode)
        .background(store.resolvedPDFTheme(isDark: isDark).documentBackgroundColor(isDarkUI: isDark))
        .task(id: tab.documentID) {
            // Restoring background tabs must not compete with the first visible scan for CPU and OCR.
            tab.scanPagesIfNeeded()
        }
    }

    // MARK: - Split or Single Canvas Area

    @ViewBuilder
    private var canvasArea: some View {
        if tab.splitMode == .disabled {
            primaryCanvasPane
        } else {
            GeometryReader { geometry in
                splitCanvas(size: geometry.size)
            }
            .onChange(of: tab.splitMode) { _, _ in draggedPaneLength = nil }
        }
    }

    private enum SplitPart: Hashable { case primary, divider, comparison }

    private func splitCanvas(size: CGSize) -> some View {
        let mode = tab.splitMode
        let sideBySide = mode == .vertical
        let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let extent = sideBySide ? size.width : size.height
        let grip = min(8, extent)
        let usable = extent - grip
        let minimum = min(170, usable / 2)
        func bounded(_ length: CGFloat) -> CGFloat {
            min(max(length, minimum), usable - minimum)
        }
        let saved = bounded(usable * (tab.splitDividerFractions[mode] ?? 0.5))
        let first = bounded(draggedPaneLength ?? saved)
        let parts: [SplitPart] = tab.isSplitSwapped ? [.comparison, .divider, .primary] : [.primary, .divider, .comparison]

        return layout {
            ForEach(parts, id: \.self) { part in
                let length = part == .divider ? grip : (part == parts.first ? first : usable - first)
                Group {
                    switch part {
                    case .primary:
                        primaryCanvasPane
                    case .comparison:
                        secondarySplitPane(width: sideBySide ? length : size.width)
                    case .divider:
                        ReaderResizeHandle(axis: sideBySide ? .horizontal : .vertical, length: first) { length, ended in
                            if ended {
                                let newLength = bounded(length)
                                if usable > 0, abs(newLength - saved) > 0.5 {
                                    tab.splitDividerFractions[mode] = newLength / usable
                                }
                                draggedPaneLength = nil
                            } else {
                                draggedPaneLength = bounded(length)
                            }
                        }
                        .background(AppPalette.panelBackground(isDark))
                        .overlay {
                            Rectangle()
                                .fill(AppPalette.panelHairline(isDark))
                                .frame(width: sideBySide ? 1 : nil, height: sideBySide ? nil : 1)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: sideBySide ? length : size.width, height: sideBySide ? size.height : length)
                .clipped()
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
            initialReadingSpot: tab.readingSpot,
            isInteractive: tab.splitMode == .disabled || !tab.isPageOverviewVisible,
            onPaneActivation: tab.splitMode == .disabled ? nil : { tab.activatePane(isSecondary: false) },
            onManualZoom: { tab.syncManualZoom($0, fromSecondaryPane: false) },
            onAutoScalesChange: { autoScales in
                tab.updateAutoScalingFromView(autoScales)
            },
            onStepPage: { delta in
                tab.stepPage(by: delta)
            },
            onReadingLocationChange: { pageIndex, readingLineY in
                tab.readingLocation.update(pageIndex: pageIndex, readingLineY: readingLineY)
            },
            onReadingSpotChange: { spot in
                tab.readingSpot = spot
            }
        )
        .overlay(alignment: .bottomTrailing) {
            PageIndicatorOverlay(tab: tab)
                .padding(16)
        }
        .overlay { paneFocusIndicator(isSecondary: false) }
        .onChange(of: tab.currentPageIndex) { _, newPage in
            if tab.syncScrollAndZoom,
               let secDoc = tab.secondaryPDFDocument,
               newPage < secDoc.pageCount {
                tab.secondaryPageIndex = newPage
            }
        }
    }

    // MARK: - Secondary Split View Pane

    private func secondarySplitPane(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            secondaryPaneHeader(showsTitle: width >= 220)

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
                    zoomScale: $tab.secondaryZoomScale,
                    layoutMode: tab.layoutMode,
                    // The other document of a comparison keeps its own direction (left to right)
                    readsRightToLeft: secDoc === tab.pdfDocument && tab.readsRightToLeft,
                    isClearMarginsEnabled: tab.isClearMarginsEnabled,
                    pdfTheme: store.resolvedPDFTheme(isDark: isDark),
                    isDarkUI: isDark,
                    pageJumpToken: tab.secondaryPageJumpToken,
                    zoomCommandToken: tab.secondaryZoomCommandToken,
                    pendingZoomAction: tab.pendingSecondaryZoomAction,
                    isAutoScaling: tab.secondaryIsAutoScaling,
                    layoutToken: tab.clearMarginsLayoutToken,
                    readingSpot: tab.secondaryReadingSpotBeforeCropChange,
                    initialReadingSpot: tab.secondaryReadingSpot,
                    handlesUnfocusedArrowKeys: false,
                    isInteractive: !tab.isPageOverviewVisible,
                    onPaneActivation: { tab.activatePane(isSecondary: true) },
                    onManualZoom: { tab.syncManualZoom($0, fromSecondaryPane: true) },
                    onAutoScalesChange: { autoScales in
                        if tab.secondaryIsAutoScaling != autoScales {
                            tab.secondaryIsAutoScaling = autoScales
                        }
                    },
                    onStepPage: { delta in
                        let target = tab.layoutMode.pageIndex(afterStepping: delta, from: tab.secondaryPageIndex,
                                                             pageCount: secDoc.pageCount)
                        tab.navigateSecondaryPane(to: target)
                    },
                    onReadingSpotChange: { spot in
                        tab.secondaryReadingSpot = spot
                    }
                )
                .id(ObjectIdentifier(secDoc))
                .overlay(alignment: .bottomTrailing) {
                    PageIndicatorOverlay(tab: tab, isSecondaryPane: true)
                        .padding(16)
                }
            } else {
                HomeTabRootView(store: store, isStandaloneSplitPane: true) { chosenURL in
                    tab.setSecondaryDocument(url: chosenURL)
                }
            }
        }
        .overlay { paneFocusIndicator(isSecondary: true) }
        .overlay { ComparisonDropArea(tab: tab).allowsHitTesting(false).accessibilityHidden(true) }
    }

    @ViewBuilder
    private func paneFocusIndicator(isSecondary: Bool) -> some View {
        if tab.splitMode != .disabled && !tab.isPageOverviewVisible && tab.targetsSecondaryPane == isSecondary {
            Rectangle()
                .strokeBorder(AppPalette.accentBlue.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func secondaryPaneHeader(showsTitle: Bool) -> some View {
        let syncLabel = L10n.tr("同步滚动和缩放", "Sync Scroll & Zoom")
        let sync = Toggle(L10n.tr("同步", "Sync"), isOn: $tab.syncScrollAndZoom)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .foregroundColor(AppPalette.labelSecondary(isDark))
            .help(syncLabel)
            .accessibilityLabel(Text(syncLabel))
            .fixedSize()
        let actions = HStack(spacing: 2) {
            ToolbarIconButton(
                icon: tab.showSplitDocumentPicker ? "doc.text" : "folder",
                tooltip: tab.showSplitDocumentPicker ? L10n.tr("返回对比文档", "Back to Document") : L10n.tr("选择对比文档", "Select Document"),
                isActive: tab.showSplitDocumentPicker,
                iconWidth: 26,
                isDark: isDark
            ) {
                withAnimation(AppAnimation.snappy) {
                    tab.showSplitDocumentPicker.toggle()
                }
            }

            ToolbarIconButton(icon: "arrow.left.arrow.right", tooltip: L10n.tr("对调分屏位置", "Swap Split Position"),
                              iconWidth: 26, isDark: isDark) {
                withAnimation(AppAnimation.snappy) {
                    tab.isSplitSwapped.toggle()
                }
            }

            ToolbarIconButton(icon: "xmark", tooltip: L10n.tr("关闭分屏视图", "Close Split View"),
                              iconWidth: 26, isDark: isDark) {
                withAnimation(AppAnimation.panel) {
                    tab.splitMode = .disabled
                }
            }
        }
        .fixedSize()
        return Group {
            if showsTitle {
                HStack(spacing: 8) {
                    Text(tab.secondaryDocumentURL?.deletingPathExtension().lastPathComponent ?? tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppPalette.labelPrimary(isDark))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sync
                    actions
                }
                .padding(.leading, 6)
                .frame(height: 34)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { sync; actions }
                        .frame(height: 34)
                    VStack(spacing: 2) { sync; actions }
                        .padding(.vertical, 3)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(AppPalette.toolbarBackground(isDark))
        .overlay(alignment: .bottom) {
            AppPalette.chromeHairline(isDark).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("分屏视图", "Split View")))
    }
}
