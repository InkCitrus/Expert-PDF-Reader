import AppKit
import PDFKit
import SwiftUI

// MARK: - Left Panel (PanelViewsDockViewController)

/// The document navigation sidebar (thumbnails, outline and bookmarks).
public struct ReaderLeftSidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    var panelWidth: CGFloat = ReaderLeftSidebarView.width

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccentColor) private var accent
    @State private var outlineFilterText: String = ""
    @State private var isFilterExpanded: Bool = false
    @State private var hasOutlineNodes: Bool = false
    @FocusState private var isFilterFocused: Bool
    private var isDark: Bool { colorScheme == .dark }

    public static let width: CGFloat = 240

    private func collapseFilter() {
        isFilterFocused = false
        withAnimation(AppAnimation.snappy) {
            outlineFilterText = ""
            isFilterExpanded = false
        }
    }

    public var body: some View {
        documentSummary
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background(AppPalette.panelBackground(isDark), ignoresSafeAreaEdges: [])
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(tab.activeSidebarTab.title))
            .onChange(of: isFilterFocused) { _, focused in
                if !focused && outlineFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    withAnimation(AppAnimation.snappy) {
                        isFilterExpanded = false
                    }
                }
            }
            .onChange(of: tab.activeSidebarTab) { _, newTab in
                if newTab != .outline && outlineFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    isFilterExpanded = false
                }
            }
            .onChange(of: hasOutlineNodes) { _, available in
                if !available && isFilterExpanded {
                    collapseFilter()
                }
            }
    }

    private var documentSummary: some View {
        VStack(spacing: 0) {
            // Icon Segmented Header (Thumbnails / Outline / Bookmarks)
            PanelSegmentedControl(items: ReaderSidebarTab.allCases, selection: $tab.activeSidebarTab, isDark: isDark) { sTab, _ in
                Image(systemName: sTab.iconName)
                    .font(.system(size: 12.5, weight: .medium))
                    .help(sTab.title)
                    .accessibilityLabel(Text(sTab.title))
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Group {
                if tab.activeSidebarTab == .outline && isFilterExpanded {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppPalette.labelTertiary(isDark))

                        TextField(L10n.tr("筛选目录…", "Filter outline…"), text: $outlineFilterText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(AppPalette.labelPrimary(isDark))
                            .tint(accent)
                            .focused($isFilterFocused)
                            .onExitCommand { collapseFilter() }

                        Button {
                            collapseFilter()
                        } label: {
                            Image(systemName: outlineFilterText.isEmpty ? "xmark" : "xmark.circle.fill")
                                .font(.system(size: outlineFilterText.isEmpty ? 10 : 11, weight: .semibold))
                                .foregroundColor(AppPalette.labelTertiary(isDark))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("关闭", "Close"))
                        .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    HStack(spacing: 6) {
                        Text(tab.activeSidebarTab.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(AppPalette.labelPrimary(isDark))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 4)
                        headerAccessory
                    }
                    .padding(.horizontal, 14)
                    .transition(.opacity)
                }
            }
            .animation(AppAnimation.sidebarSwitch, value: tab.activeSidebarTab)
            .animation(AppAnimation.snappy, value: isFilterExpanded)
            .frame(height: 34)

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            // Active Panel Content
            ZStack {
                switch tab.activeSidebarTab {
                case .thumbnails:
                    PDFPageThumbnailsPanel(store: store, tab: tab, panelWidth: panelWidth, isDark: isDark)
                case .outline:
                    PDFOutlinePanel(
                        store: store,
                        tab: tab,
                        isDark: isDark,
                        filterText: $outlineFilterText,
                        hasOutlineNodes: $hasOutlineNodes
                    )
                case .bookmarks:
                    PDFBookmarksPanel(store: store, tab: tab, isDark: isDark)
                }
            }
            .id(tab.activeSidebarTab)
            .transition(
                AppAnimation.reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: 4))
            )
            .animation(AppAnimation.sidebarSwitch, value: tab.activeSidebarTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    @ViewBuilder
    private var headerAccessory: some View {
        switch tab.activeSidebarTab {
        case .thumbnails:
            let selectedCount = tab.selectedThumbnailPages(in: tab.activeThumbnailSource).count
            Text(selectedCount > 0
                 ? L10n.selectedPagesCount(selectedCount)
                 : L10n.pageCountText(tab.activeThumbnailSource.document.pageCount))
                .font(.system(size: 11))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(AppAnimation.micro, value: selectedCount)
                .foregroundColor(AppPalette.labelTertiary(isDark))
        case .outline:
            if hasOutlineNodes {
                PanelHeaderIconButton(
                    icon: "magnifyingglass",
                    tooltip: L10n.tr("筛选目录…", "Filter outline…"),
                    isDark: isDark
                ) {
                    withAnimation(AppAnimation.snappy) {
                        isFilterExpanded = true
                    }
                    DispatchQueue.main.async {
                        isFilterFocused = true
                    }
                }
            }
        case .bookmarks:
            PanelHeaderIconButton(
                icon: "plus",
                tooltip: L10n.tr("为当前页添加书签 (⌘D)", "Add Bookmark for Current Page (⌘D)"),
                isDark: isDark
            ) {
                let point = tab.currentBookmarkPoint(for: tab.currentPageIndex)
                if let existing = store.nearbyBookmark(pageIndex: tab.currentPageIndex, point: point, tolerance: 48, in: tab.documentID) {
                    tab.activeBookmarkID = existing.id
                    tab.pendingRenameBookmarkID = existing.id
                } else {
                    let title = tab.smartBookmarkTitle(at: tab.currentPageIndex, point: point)
                    let created = store.addBookmark(
                        pageIndex: tab.currentPageIndex,
                        title: title,
                        point: point,
                        in: tab.documentID,
                        undoManager: tab.undoManager
                    )
                    tab.activeBookmarkID = created.id
                    if let point {
                        tab.flashBookmarkIndicator(pageIndex: tab.currentPageIndex, point: point)
                    }
                }
            }
        }
    }
}

// MARK: - Panel Building Blocks

/// PDF Expert-style segmented control: grey track, white thumb under the selected segment.
struct PanelSegmentedControl<Item: Identifiable & Hashable, SegmentLabel: View>: View {
    let items: [Item]
    @Binding var selection: Item
    let isDark: Bool
    @ViewBuilder let label: (Item, Bool) -> SegmentLabel

    @Environment(\.appAccentColor) private var accent
    @Namespace private var thumbNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = (item == selection)
                Button {
                    withAnimation(AppAnimation.snappy) {
                        selection = item
                    }
                } label: {
                    label(item, isSelected)
                        .foregroundColor(isSelected ? accent : AppPalette.labelSecondary(isDark))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(AppPalette.segmentedThumb(isDark))
                                    .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.10), radius: 1.5, x: 0, y: 0.5)
                                    .matchedGeometryEffect(id: "segmentThumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppPalette.segmentedTrack(isDark))
        )
    }
}

struct PanelHeaderIconButton: View {
    let icon: String
    let tooltip: String
    var isDisabled: Bool = false
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(
                    isDisabled
                        ? AppPalette.labelQuaternary(isDark)
                        : (isHovered ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered && !isDisabled ? AppPalette.sidebarRowHover(isDark) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .onHover { isHovered = $0 }
    }
}

struct PanelEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String?
    let isDark: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(AppPalette.labelQuaternary(isDark))
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(AppPalette.labelSecondary(isDark))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 1. PDFPageThumbnailsPanel (PDFPageThumbnailsViewController)

struct PDFPageThumbnailsPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let panelWidth: CGFloat
    let isDark: Bool
    @State private var lastScrolledPageIndex: Int = -1

    var body: some View {
        let source = tab.activeThumbnailSource
        let selectedPages = tab.selectedThumbnailPages(in: source)
        let scale = panelWidth / ReaderLeftSidebarView.width
        // Reuse nearby resolutions during a drag instead of rendering on every point of movement.
        let renderScale = (scale * 4).rounded(.up) / 4
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(0..<source.document.pageCount, id: \.self) { pageIdx in
                        PageThumbnailCell(
                            store: store,
                            tab: tab,
                            source: source,
                            pageIndex: pageIdx,
                            maxSize: CGSize(width: 148 * scale, height: 192 * scale),
                            renderSize: CGSize(width: 296 * renderScale, height: 384 * renderScale),
                            isDark: isDark
                        ) {
                            tab.navigateToThumbnail(pageIdx)
                        }
                        .id(pageIdx)
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                lastScrolledPageIndex = source.pageIndex
                proxy.scrollTo(source.pageIndex, anchor: .center)
            }
            .task(id: source.pageIndex) {
                let target = source.pageIndex
                guard target != lastScrolledPageIndex else { return }
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                let delta = abs(target - lastScrolledPageIndex)
                lastScrolledPageIndex = target
                if delta <= 3 {
                    withAnimation(AppAnimation.snappy) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .id(ObjectIdentifier(source.document))
        .onExitCommand {
            if !selectedPages.isEmpty {
                tab.clearThumbnailSelection()
            }
        }
    }
}

/// Page thumbnail rendered with the active GPU theme; shared by the left panel and the page overview grid.
struct PageThumbnailCell: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let source: ReaderThumbnailSource
    let pageIndex: Int
    let maxSize: CGSize
    var renderSize: CGSize? = nil
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @Environment(\.appAccentColor) private var accent

    private static func aspectRatio(of page: PDFPage) -> CGFloat {
        let size = page.bounds(for: .cropBox).size
        guard size.width > 0, size.height > 0 else { return 0.75 }
        return page.rotation % 180 == 0 ? size.width / size.height : size.height / size.width
    }

    var body: some View {
        let isCurrent = source.pageIndex == pageIndex
        let selectedPages = tab.selectedThumbnailPages(in: source)
        let isSelected = selectedPages.contains(pageIndex)
        let hasMultiSelection = !selectedPages.isEmpty
        let isEmphasized = hasMultiSelection ? isSelected : isCurrent
        let isBookmarked = store.isPageBookmarked(pageIndex: pageIndex, in: source.documentID)
        let page = source.document.page(at: pageIndex)
        let pageLabel = tab.thumbnailPageNumber(at: pageIndex, in: source.document)

        Button {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if flags.contains(.shift) {
                tab.selectThumbnailRange(to: pageIndex, in: source, extending: flags.contains(.command))
            } else if flags.contains(.command) {
                tab.toggleThumbnailSelection(pageIndex, in: source)
            } else {
                tab.clearThumbnailSelection(anchor: pageIndex, in: source)
                action()
            }
        } label: {
            VStack(spacing: 7) {
                if let page {
                    let request = PDFThumbnailCache.ThumbnailRequest(
                        source: source,
                        pageIndex: pageIndex,
                        rotation: page.rotation,
                        theme: store.resolvedPDFTheme(isDark: isDark),
                        size: renderSize ?? CGSize(width: maxSize.width * 2, height: maxSize.height * 2)
                    )
                    Group {
                        if let image = PDFThumbnailCache.shared.cachedThumbnail(for: request) ?? thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        } else {
                            // The page's shape until its thumbnail arrives
                            Rectangle()
                                .fill(Color.white.opacity(isDark ? 0.08 : 0.9))
                                .aspectRatio(Self.aspectRatio(of: page), contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: maxSize.width, maxHeight: maxSize.height)
                    .animation(AppAnimation.micro, value: thumbnail != nil)
                    .task(id: request) {
                        if let image = await PDFThumbnailCache.shared.thumbnail(for: request), !Task.isCancelled {
                            thumbnail = image
                        }
                    }
                        .overlay(
                            Rectangle()
                                .stroke(Color.black.opacity(isDark ? 0.4 : 0.12), lineWidth: 0.5)
                        )
                        .overlay(alignment: .topTrailing) {
                            ZStack(alignment: .topTrailing) {
                                if isBookmarked {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(accent)
                                        .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 0.5)
                                        .padding(.trailing, 8)
                                        .offset(y: -2)
                                        .transition(
                                            AppAnimation.reduceMotion
                                                ? .opacity
                                                : .scale(scale: 0.6, anchor: .top).combined(with: .opacity)
                                        )
                                }
                            }
                            .animation(AppAnimation.snappy, value: isBookmarked)
                        }
                        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.10), radius: 2.5, x: 0, y: 1)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? accent.opacity(isDark ? 0.14 : 0.08) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(
                                    isEmphasized
                                        ? accent
                                        : (hasMultiSelection && isCurrent
                                            ? AppPalette.labelQuaternary(isDark)
                                            : (isHovered ? accent.opacity(0.35) : Color.clear)),
                                    lineWidth: isEmphasized ? 2 : (hasMultiSelection && isCurrent ? 1.5 : 2)
                                )
                        )
                }

                Text(pageLabel)
                    .font(.system(size: 11, weight: isEmphasized ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundColor(
                        isEmphasized
                            ? .white
                            : (hasMultiSelection && isCurrent ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isEmphasized ? accent : (hasMultiSelection && isCurrent ? AppPalette.rowHover(isDark) : Color.clear))
                    )
            }
            .scaleEffect(isHovered && !AppAnimation.reduceMotion ? 1.012 : 1.0)
            .animation(AppAnimation.micro, value: isHovered)
            .animation(AppAnimation.snappy, value: isEmphasized)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.pageTitle(pageLabel)))
        .accessibilityAddTraits((isCurrent || isSelected) ? [.isButton, .isSelected] : [.isButton])
        .onHover { isHovered = $0 }
        .contextMenu {
            let selectedPages = tab.selectedThumbnailPages(in: source)
            let actsOnSelection = selectedPages.count > 1 && selectedPages.contains(pageIndex)
            let targetWindow = store.window(forTabID: tab.id)
            let canCopyPage = PageImageClipboard.canCopy(page)

            if actsOnSelection {
                let orderedSelection = selectedPages.sorted()
                let allBookmarked = orderedSelection.allSatisfy {
                    store.isPageBookmarked(pageIndex: $0, in: source.documentID)
                }

                Button(L10n.exportSelectedPages(orderedSelection.count)) {
                    tab.beginExportPanel(
                        in: targetWindow,
                        initialPages: orderedSelection,
                        source: source,
                        session: store.windowSession(forTabID: tab.id)
                    )
                }
                .disabled(!canCopyPage)

                Divider()

                Button(allBookmarked ? L10n.tr("移除书签", "Remove Bookmark") : L10n.tr("添加书签", "Add Bookmark")) {
                    store.setBookmarks(
                        pageIndices: orderedSelection,
                        bookmarked: !allBookmarked,
                        in: source.documentID,
                        undoManager: tab.undoManager
                    )
                }

                Divider()

                Button(L10n.tr("向左旋转", "Rotate Left")) {
                    tab.rotatePages(orderedSelection, in: source.document, clockwise: false)
                }

                Button(L10n.tr("向右旋转", "Rotate Right")) {
                    tab.rotatePages(orderedSelection, in: source.document, clockwise: true)
                }

                Divider()

                Button(L10n.tr("取消选择", "Deselect All")) {
                    tab.clearThumbnailSelection()
                }
            } else {
                if tab.canOpenThumbnailInSplitView(source: source) {
                    Button(L10n.tr("在分屏中查看此页", "Open Page in Split View")) {
                        tab.openPageInSplitView(pageIndex, from: source)
                    }

                    Divider()
                }

                Button(isBookmarked ? L10n.tr("移除书签", "Remove Bookmark") : L10n.tr("添加书签", "Add Bookmark")) {
                    store.toggleBookmark(
                        pageIndex: pageIndex,
                        in: source.documentID,
                        undoManager: tab.undoManager
                    )
                }

                Divider()

                Button(L10n.tr("向左旋转", "Rotate Left")) {
                    tab.rotatePage(at: pageIndex, in: source.document, clockwise: false)
                }
                .disabled(page == nil)

                Button(L10n.tr("向右旋转", "Rotate Right")) {
                    tab.rotatePage(at: pageIndex, in: source.document, clockwise: true)
                }
                .disabled(page == nil)

                Divider()

                Button(L10n.tr("复制此页为图片", "Copy Page as Image")) {
                    guard let page else { return }
                    PageImageClipboard.beginCopy(
                        page,
                        in: targetWindow,
                        title: L10n.tr("复制此页为图片", "Copy Page as Image")
                    )
                }
                .disabled(!canCopyPage)

                Button(L10n.tr("导出…", "Export…")) {
                    tab.beginExportPanel(
                        in: targetWindow,
                        initialPages: [pageIndex],
                        source: source,
                        session: store.windowSession(forTabID: tab.id)
                    )
                }
                .disabled(!canCopyPage)
            }
        }
    }
}

// MARK: - 3. PDFBookmarksPanel (Minimalist Unified Flat List: Bookmarks + Highlights + Inline Notes)

struct PDFBookmarksPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    private enum FlatItem: Identifiable {
        case bookmark(BookmarkItem)
        case highlight(HighlightItem)

        var id: String {
            switch self {
            case .bookmark(let bm):  return "bm-\(bm.id.uuidString)"
            case .highlight(let hl): return "hl-\(hl.id.uuidString)"
            }
        }

        var pageIndex: Int {
            switch self {
            case .bookmark(let bm):  return bm.pageIndex
            case .highlight(let hl): return hl.pageIndex
            }
        }

        var sortY: Double {
            switch self {
            case .bookmark(let bm):  return bm.pageY ?? .infinity
            case .highlight(let hl): return hl.rects.first?.y ?? 0
            }
        }

        var createdAt: Date {
            switch self {
            case .bookmark(let bm):  return bm.createdAt
            case .highlight(let hl): return hl.createdAt
            }
        }
    }

    @State private var editingBookmarkID: UUID?
    @State private var editingHighlightNoteID: UUID?

    private func resolvedActiveBookmarkID(in items: [BookmarkItem]) -> UUID? {
        let samePage = items.filter { $0.pageIndex == tab.currentPageIndex }
        guard !samePage.isEmpty else { return nil }
        if samePage.count == 1 { return samePage[0].id }
        if let pinned = tab.activeBookmarkID, samePage.contains(where: { $0.id == pinned }) {
            return pinned
        }
        let lineY = Double(tab.readingLocation.readingLineY)
        return samePage.min(by: { lhs, rhs in
            abs((lhs.pageY ?? .infinity) - lineY) < abs((rhs.pageY ?? .infinity) - lineY)
        })?.id ?? samePage.first?.id
    }

    private func unifiedItems(bookmarks: [BookmarkItem], highlights: [HighlightItem]) -> [FlatItem] {
        var combined: [FlatItem] = bookmarks.map(FlatItem.bookmark)
        combined.append(contentsOf: highlights.map(FlatItem.highlight))
        combined.sort { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
            if abs(lhs.sortY - rhs.sortY) > 1 { return lhs.sortY > rhs.sortY }
            return lhs.createdAt < rhs.createdAt
        }
        return combined
    }

    var body: some View {
        let bookmarks = store.bookmarks(for: tab.documentID)
        let highlights = store.highlights(for: tab.documentID)
        let activeBookmarkID = resolvedActiveBookmarkID(in: bookmarks)
        let pageBookmarkCounts = Dictionary(grouping: bookmarks, by: \.pageIndex).mapValues(\.count)

        VStack(spacing: 0) {
            if bookmarks.isEmpty && highlights.isEmpty {
                PanelEmptyState(
                    icon: "bookmark",
                    title: L10n.tr("暂无书签或高亮", "No Bookmarks or Highlights"),
                    subtitle: L10n.tr("按 ⌘D 添加页面书签，或选中文字按 ⌃⌘H 标记重点句子", "Press ⌘D to bookmark a page, or select text and press ⌃⌘H to highlight"),
                    isDark: isDark
                )
                .frame(maxHeight: .infinity)
            } else {
                let items = unifiedItems(bookmarks: bookmarks, highlights: highlights)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { entry in
                            switch entry {
                            case .bookmark(let bm):
                                bookmarkRow(
                                    bm,
                                    isCurrent: bm.id == activeBookmarkID,
                                    showsRegionSubtitle: (pageBookmarkCounts[bm.pageIndex] ?? 0) > 1
                                )
                            case .highlight(let hl):
                                highlightRow(hl)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .onChange(of: tab.pendingRenameBookmarkID) { _, id in
            guard let id else { return }
            editingHighlightNoteID = nil
            editingBookmarkID = id
            tab.pendingRenameBookmarkID = nil
        }
    }

    private func bookmarkRow(_ bm: BookmarkItem, isCurrent: Bool, showsRegionSubtitle: Bool) -> some View {
        let regionLabel = (showsRegionSubtitle && bm.destinationPoint != nil) ? tab.bookmarkRegionLabel(for: bm) : nil
        return BookmarkRowView(
            bookmark: bm,
            pageLabel: tab.displayPageNumber(at: bm.pageIndex),
            regionLabel: regionLabel,
            isCurrent: isCurrent,
            isEditing: editingBookmarkID == bm.id,
            isDark: isDark,
            onSelect: { tab.navigateToBookmark(bm) },
            onBeginRename: {
                editingHighlightNoteID = nil
                editingBookmarkID = bm.id
            },
            onFinishRename: { newTitle in
                editingBookmarkID = nil
                if let newTitle {
                    store.renameBookmark(
                        id: bm.id,
                        newTitle: newTitle,
                        in: tab.documentID,
                        undoManager: tab.undoManager
                    )
                }
            },
            onDelete: {
                if editingBookmarkID == bm.id { editingBookmarkID = nil }
                store.removeBookmark(id: bm.id, in: tab.documentID, undoManager: tab.undoManager)
            }
        )
    }

    private func highlightRow(_ item: HighlightItem) -> some View {
        HighlightRowView(
            item: item,
            pageLabel: tab.displayPageNumber(at: item.pageIndex),
            isCurrent: item.id == tab.activeHighlightID && item.pageIndex == tab.currentPageIndex,
            isEditingNote: editingHighlightNoteID == item.id,
            isDark: isDark,
            onSelect: { tab.navigateToHighlight(item) },
            onCopyText: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            },
            onChangeColor: { color in
                store.updateHighlightColor(
                    id: item.id,
                    color: color,
                    in: tab.documentID,
                    undoManager: tab.undoManager
                )
            },
            onBeginEditNote: {
                editingBookmarkID = nil
                editingHighlightNoteID = item.id
            },
            onFinishEditNote: { newNote in
                editingHighlightNoteID = nil
                if let newNote {
                    store.updateHighlightNote(
                        id: item.id,
                        note: newNote,
                        in: tab.documentID,
                        undoManager: tab.undoManager
                    )
                }
            },
            onDeleteNote: {
                if editingHighlightNoteID == item.id { editingHighlightNoteID = nil }
                store.updateHighlightNote(
                    id: item.id,
                    note: nil,
                    in: tab.documentID,
                    undoManager: tab.undoManager
                )
            },
            onDelete: {
                if editingHighlightNoteID == item.id { editingHighlightNoteID = nil }
                store.removeHighlight(
                    id: item.id,
                    in: tab.documentID,
                    undoManager: tab.undoManager
                )
            }
        )
    }
}

struct BookmarkRowView: View {
    let bookmark: BookmarkItem
    let pageLabel: String
    let regionLabel: String?
    let isCurrent: Bool
    let isEditing: Bool
    let isDark: Bool
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onFinishRename: (String?) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isCurrent ? accent : AppPalette.labelTertiary(isDark))
                .frame(width: 12)

            if isEditing {
                BookmarkInlineRenameField(
                    initialText: bookmark.title,
                    placeholder: L10n.tr("书签名称", "Bookmark Name"),
                    textColor: AppPalette.labelPrimary(isDark),
                    accentColor: accent,
                    onFinish: onFinishRename
                )
                .frame(height: 22)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppPalette.toolbarControlFill(isDark))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(accent.opacity(0.75), lineWidth: 0.75)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    Text(bookmark.title)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let regionLabel {
                        Text("· \(regionLabel)")
                            .font(.system(size: 10.5))
                            .foregroundColor(AppPalette.labelQuaternary(isDark))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isEditing {
                ZStack(alignment: .trailing) {
                    if isHovered {
                        HStack(spacing: 2) {
                            SidebarHoverIconButton(
                                icon: "pencil",
                                tooltip: L10n.tr("重命名书签", "Rename Bookmark"),
                                isDark: isDark,
                                action: onBeginRename
                            )
                            SidebarHoverIconButton(
                                icon: "xmark",
                                tooltip: L10n.tr("删除书签", "Delete Bookmark"),
                                isDark: isDark,
                                action: onDelete
                            )
                        }
                        .transition(.opacity)
                    } else {
                        Text(pageLabel)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundColor(isCurrent ? AppPalette.labelSecondary(isDark) : AppPalette.labelTertiary(isDark))
                            .transition(.opacity)
                    }
                }
                .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isCurrent
                        ? AppPalette.sidebarRowSelected(isDark)
                        : (isHovered ? AppPalette.sidebarRowHover(isDark) : Color.clear)
                )
        )
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(AppPalette.sidebarRowSelectedBorder(isDark), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bookmark.title), \(L10n.pageTitle(pageLabel))"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onSelect)
        .onTapGesture {
            if !isEditing {
                onSelect()
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L10n.jumpToPage(pageLabel), action: onSelect)
            Button(L10n.tr("重命名书签", "Rename Bookmark"), action: onBeginRename)
            Divider()
            Button(L10n.tr("删除书签", "Delete Bookmark"), role: .destructive, action: onDelete)
        }
    }
}

private struct SidebarHoverIconButton: View {
    let icon: String
    let tooltip: String
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? AppPalette.labelPrimary(isDark) : AppPalette.labelTertiary(isDark))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(isHovered ? AppPalette.toolbarControlFill(isDark) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .onHover { isHovered = $0 }
    }
}

/// AppKit inline text field for bookmark renaming so any click outside the field
/// (including empty sidebar area, other rows, or the canvas) commits and exits edit mode immediately.
private struct BookmarkInlineRenameField: NSViewRepresentable {
    let initialText: String
    let placeholder: String
    let textColor: Color
    let accentColor: Color
    let onFinish: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeNSView(context: Context) -> FocusTextField {
        let field = FocusTextField(string: initialText)
        field.font = .systemFont(ofSize: 12.5, weight: .medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = NSColor(textColor)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        context.coordinator.watchForClicks(outside: field)
        return field
    }

    func updateNSView(_ field: FocusTextField, context: Context) {
        field.textColor = NSColor(textColor)
        field.accentSelectionColor = NSColor(accentColor).withAlphaComponent(0.26)
        context.coordinator.onFinish = onFinish
    }

    static func dismantleNSView(_ field: FocusTextField, coordinator: Coordinator) {
        coordinator.stop()
        field.delegate = nil
        if let window = field.window, let editor = field.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
    }

    final class FocusTextField: NSTextField {
        var accentSelectionColor = NSColor.selectedTextBackgroundColor

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.selectText(nil)
                if let editor = self.currentEditor() as? NSTextView, let ink = self.textColor {
                    (self.delegate as? Coordinator)?.style(editor, ink: ink, fill: self.accentSelectionColor)
                }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var onFinish: (String?) -> Void
        nonisolated(unsafe) private var clickMonitor: Any?
        private var didFinish = false
        private weak var styledEditor: NSTextView?
        private var previousCaretColor: NSColor?
        private var previousSelection: [NSAttributedString.Key: Any]?

        init(onFinish: @escaping (String?) -> Void) {
            self.onFinish = onFinish
        }

        deinit {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
            }
        }

        func style(_ editor: NSTextView, ink: NSColor, fill: NSColor) {
            guard styledEditor !== editor else { return }
            styledEditor = editor
            previousCaretColor = editor.insertionPointColor
            previousSelection = editor.selectedTextAttributes
            editor.insertionPointColor = ink
            editor.selectedTextAttributes = [.foregroundColor: ink, .backgroundColor: fill]
        }

        func watchForClicks(outside field: NSTextField) {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak field] event in
                MainActor.assumeIsolated {
                    guard let self, let field, let window = field.window else { return }
                    let local = field.convert(event.locationInWindow, from: nil)
                    if event.window !== window || !field.bounds.contains(local) {
                        let currentString = field.currentEditor()?.string ?? field.stringValue
                        self.finish(currentString)
                    }
                }
                return event
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(textView.string)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field.stringValue)
        }

        func stop() {
            didFinish = true
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
            }
            clickMonitor = nil
            if let previousCaretColor { styledEditor?.insertionPointColor = previousCaretColor }
            if let previousSelection { styledEditor?.selectedTextAttributes = previousSelection }
            styledEditor = nil
        }

        private func finish(_ title: String?) {
            guard !didFinish else { return }
            stop()
            onFinish(title)
        }
    }
}

// MARK: - HighlightRowView (Minimalist Dot-Accented Highlight + Inline Note)

struct HighlightRowView: View {
    let item: HighlightItem
    let pageLabel: String
    let isCurrent: Bool
    let isEditingNote: Bool
    let isDark: Bool
    let onSelect: () -> Void
    let onCopyText: () -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onBeginEditNote: () -> Void
    let onFinishEditNote: (String?) -> Void
    let onDeleteNote: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.color.color(isDark: isDark))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.text)
                        .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                        .foregroundColor(isCurrent ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !isEditingNote {
                        ZStack(alignment: .trailing) {
                            if isHovered {
                                HStack(spacing: 2) {
                                    SidebarHoverIconButton(
                                        icon: item.note != nil ? "pencil" : "text.bubble",
                                        tooltip: item.note != nil ? L10n.tr("编辑笔记", "Edit Note") : L10n.tr("添加笔记", "Add Note"),
                                        isDark: isDark,
                                        action: onBeginEditNote
                                    )
                                    SidebarHoverIconButton(
                                        icon: "xmark",
                                        tooltip: L10n.tr("移除高亮", "Remove Highlight"),
                                        isDark: isDark,
                                        action: onDelete
                                    )
                                }
                                .transition(.opacity)
                            } else {
                                Text(pageLabel)
                                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundColor(isCurrent ? AppPalette.labelSecondary(isDark) : AppPalette.labelTertiary(isDark))
                                    .transition(.opacity)
                            }
                        }
                        .frame(minWidth: 28, alignment: .trailing)
                    }
                }

                if isEditingNote {
                    BookmarkInlineRenameField(
                        initialText: item.note ?? "",
                        placeholder: L10n.tr("写下笔记…", "Write a note…"),
                        textColor: AppPalette.labelPrimary(isDark),
                        accentColor: accent,
                        onFinish: onFinishEditNote
                    )
                    .frame(height: 20)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(AppPalette.toolbarControlFill(isDark))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(accent.opacity(0.75), lineWidth: 0.75)
                    )
                } else if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(perform: onBeginEditNote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isCurrent
                        ? AppPalette.sidebarRowSelected(isDark)
                        : (isHovered ? AppPalette.sidebarRowHover(isDark) : Color.clear)
                )
        )
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(AppPalette.sidebarRowSelectedBorder(isDark), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.text), \(L10n.pageTitle(pageLabel))"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onSelect)
        .onTapGesture {
            if !isEditingNote {
                onSelect()
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L10n.jumpToPage(pageLabel), action: onSelect)
            Button(
                item.note != nil ? L10n.tr("编辑笔记", "Edit Note") : L10n.tr("添加笔记", "Add Note"),
                action: onBeginEditNote
            )
            if item.note != nil {
                Button(L10n.tr("删除笔记", "Delete Note"), action: onDeleteNote)
            }
            Button(L10n.tr("复制高亮文字", "Copy Highlighted Text"), action: onCopyText)
            Menu(L10n.tr("高亮颜色", "Highlight Color")) {
                ForEach(HighlightColor.allCases) { color in
                    Button {
                        onChangeColor(color)
                    } label: {
                        if item.color == color {
                            Label(color.title, systemImage: "checkmark")
                        } else {
                            Text(color.title)
                        }
                    }
                }
            }
            Divider()
            Button(L10n.tr("移除高亮", "Remove Highlight"), role: .destructive, action: onDelete)
        }
    }
}

struct SplitMiniPagePreview: View {
    let leftTheme: PDFViewTheme
    let rightTheme: PDFViewTheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MiniPagePreview(theme: leftTheme)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: geo.size.width / 2)
                    }
                MiniPagePreview(theme: rightTheme)
                    .mask(alignment: .trailing) {
                        Rectangle()
                            .frame(width: geo.size.width / 2)
                    }
            }
        }
    }
}

/// Miniature page drawn with the theme's paper + ink colors (shader white/black outputs).
struct MiniPagePreview: View {
    let theme: PDFViewTheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.pagePaperColor)
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)

                VStack(alignment: .leading, spacing: max(2, w * 0.08)) {
                    Capsule()
                        .fill(theme.pageInkColor)
                        .frame(width: w * 0.55, height: max(1.5, w * 0.07))
                    ForEach(0..<4, id: \.self) { line in
                        Capsule()
                            .fill(theme.pageInkColor.opacity(0.55))
                            .frame(width: w * (line == 3 ? 0.42 : 0.7), height: max(1, w * 0.045))
                    }
                }
                .padding(w * 0.15)
            }
        }
    }
}
