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
    private var isDark: Bool { colorScheme == .dark }

    public static let width: CGFloat = 240

    public var body: some View {
        documentSummary
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background(AppPalette.panelBackground(isDark), ignoresSafeAreaEdges: [])
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(tab.activeSidebarTab.title))
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

            HStack(spacing: 6) {
                Text(tab.activeSidebarTab.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                Spacer()
                headerAccessory
            }
            .animation(AppAnimation.sidebarSwitch, value: tab.activeSidebarTab)
            .padding(.horizontal, 14)
            .frame(height: tab.activeSidebarTab == .outline ? 30 : 34)

            if tab.activeSidebarTab != .outline {
                Rectangle()
                    .fill(AppPalette.panelSeparator(isDark))
                    .frame(height: 1)
            }

            // Active Panel Content
            ZStack {
                switch tab.activeSidebarTab {
                case .thumbnails:
                    PDFPageThumbnailsPanel(store: store, tab: tab, panelWidth: panelWidth, isDark: isDark)
                case .outline:
                    PDFOutlinePanel(store: store, tab: tab, isDark: isDark)
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
            EmptyView()
        case .bookmarks:
            let count = store.bookmarks(for: tab.documentID).count
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(AppPalette.labelTertiary(isDark))
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isDisabled ? AppPalette.labelQuaternary(isDark) : AppPalette.labelSecondary(isDark))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isHovered && !isDisabled ? AppPalette.toolbarActive(isDark) : AppPalette.segmentedTrack(isDark))
                )
                .contentShape(Circle())
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

// MARK: - 3. PDFBookmarksPanel (PDFBookmarksPanelViewController)

struct PDFBookmarksPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    var body: some View {
        let items = store.bookmarks(for: tab.documentID)

        if items.isEmpty {
            PanelEmptyState(
                icon: "bookmark",
                title: L10n.tr("暂无页面书签", "No Page Bookmarks"),
                subtitle: L10n.tr("按 ⌘D 或点击工具栏中的书签图标标记当前页", "Press ⌘D or click the bookmark button in the toolbar to bookmark this page"),
                isDark: isDark
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { bm in
                        BookmarkRowView(
                            bookmark: bm,
                            pageLabel: tab.displayPageNumber(at: bm.pageIndex),
                            isCurrent: bm.pageIndex == tab.currentPageIndex,
                            isDark: isDark,
                            onSelect: { tab.navigateToPage(bm.pageIndex) },
                            onDelete: { store.removeBookmark(id: bm.id, in: tab.documentID) }
                        )
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct BookmarkRowView: View {
    let bookmark: BookmarkItem
    let pageLabel: String
    let isCurrent: Bool
    let isDark: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundColor(isCurrent ? accent : accent.opacity(0.82))

            Text(bookmark.title)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                .foregroundColor(isCurrent ? accent : AppPalette.labelPrimary(isDark))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(pageLabel)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundColor(isCurrent ? accent : AppPalette.labelTertiary(isDark))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isCurrent
                        ? AppPalette.sidebarRowActive(accent, isDark)
                        : (isHovered ? AppPalette.sidebarRowHover(isDark) : Color.clear)
                )
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule(style: .continuous)
                    .fill(accent)
                    .frame(width: 2.5, height: 14)
                    .padding(.leading, 2.5)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bookmark.title), \(L10n.pageTitle(pageLabel))"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onSelect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L10n.jumpToPage(pageLabel), action: onSelect)
            Divider()
            Button(L10n.tr("删除书签", "Delete Bookmark"), role: .destructive, action: onDelete)
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
