import AppKit
import PDFKit
import SwiftUI

// MARK: - Top Reader Toolbar

/// PDF Expert 3 toolbar layout: dock toggles + zoom on the left, reading tools in the middle,
/// share / bookmark / search on the right. Colors follow the app appearance instead of PDF Expert's fixed graphite.
public struct ReaderToolbarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @State private var zoomAnchor = NSViewAnchor()
    @State private var shareAnchor = NSViewAnchor()
    @FocusState private var isSearchFieldFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public static let height: CGFloat = 40

    public var body: some View {
        HStack(spacing: 2) {
            // Left Group: Document Summary / Page Overview / View Settings + Zoom (PDFZoomToolbarItemView)
            ToolbarIconButton(
                icon: "sidebar.left",
                tooltip: L10n.tr("文档概要：缩略图、大纲与书签 (⌘B)", "Document Summary: Thumbnails, Outline & Bookmarks (⌘B)"),
                isActive: tab.isLeftSidebarVisible && tab.leftPanel == .documentSummary,
                isDark: isDark
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    tab.toggleLeftPanel(.documentSummary)
                }
            }

            ToolbarIconButton(
                icon: "square.grid.2x2",
                tooltip: L10n.tr("页面概览 (⌃⌘1)", "Page Overview (⌃⌘1)"),
                isActive: tab.isPageOverviewVisible,
                isDark: isDark
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    tab.isPageOverviewVisible.toggle()
                }
            }

            ToolbarIconButton(
                icon: "book",
                tooltip: L10n.tr("显示选项：页面布局、分屏与阅读主题", "View Settings: Page Layout, Split View & Reading Theme"),
                isActive: tab.isLeftSidebarVisible && tab.leftPanel == .viewSettings,
                isDark: isDark
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    tab.toggleLeftPanel(.viewSettings)
                }
            }

            zoomControls
                .padding(.leading, 8)

            Spacer(minLength: 16)

            // Center Group: Follow System / Day / Sepia / Night + Page Tools
            HStack(spacing: 2) {
                ForEach(PDFReadingThemeMode.allCases) { mode in
                    ToolbarIconButton(
                        icon: mode.toolbarIconName,
                        tooltip: "\(L10n.tr("阅读主题", "Reading Theme")): \(mode.title)",
                        isActive: store.readingThemeMode == mode,
                        activeTint: AppPalette.accentBlue,
                        isDark: isDark
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            store.readingThemeMode = mode
                        }
                    }
                }

                ToolbarDivider(isDark: isDark)

                ToolbarIconButton(
                    icon: "crop",
                    tooltip: tab.isClearMarginsEnabled ? L10n.tr("恢复页面空白边 (⇧⌘M)", "Restore Page Margins (⇧⌘M)") : L10n.tr("清除空白边 (⇧⌘M)", "Clear Margins (⇧⌘M)"),
                    isActive: tab.isClearMarginsEnabled,
                    isDark: isDark
                ) {
                    tab.isClearMarginsEnabled.toggle()
                    tab.applyClearMarginsIfNeeded()
                }

                ToolbarIconButton(
                    icon: "rotate.left",
                    tooltip: L10n.tr("向左旋转当前页面", "Rotate Current Page Left"),
                    isDark: isDark
                ) {
                    tab.rotateCurrentPage(clockwise: false)
                }
            }

            Spacer(minLength: 16)

            // Right Group: Share + Bookmark + Search Field (PDFSearchToolbarItemView)
            ToolbarIconButton(
                icon: "square.and.arrow.up",
                tooltip: L10n.tr("分享", "Share"),
                isDark: isDark
            ) {
                presentSharingPicker()
            }
            .background(ViewAnchorRepresentable(anchor: shareAnchor))

            let isBookmarked = store.isPageBookmarked(pageIndex: tab.currentPageIndex, in: tab.documentID)
            ToolbarIconButton(
                icon: isBookmarked ? "bookmark.fill" : "bookmark",
                tooltip: isBookmarked ? L10n.tr("移除当前页书签 (⌘D)", "Remove Bookmark for Current Page (⌘D)") : L10n.tr("为当前页添加书签 (⌘D)", "Add Bookmark for Current Page (⌘D)"),
                isActive: isBookmarked,
                activeTint: AppPalette.systemRed,
                isDark: isDark
            ) {
                store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
            }

            searchField
                .frame(width: 176)
                .padding(.leading, 6)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(AppPalette.toolbarBackground(isDark))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.chromeHairline(isDark))
                .frame(height: 1)
        }
        .onChange(of: tab.searchFocusToken) { _, _ in
            isSearchFieldFocused = true
        }
    }

    // MARK: Zoom (percentage pop-up + − / + stepper)

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                presentZoomMenu()
            } label: {
                HStack(spacing: 4) {
                    Text("\(Int((tab.zoomScale * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
                .foregroundColor(AppPalette.toolbarIcon(isDark))
                .frame(width: 72, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppPalette.toolbarControlFill(isDark))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ViewAnchorRepresentable(anchor: zoomAnchor))
            .help(L10n.tr("缩放比例", "Zoom Level"))
            .accessibilityLabel(Text("\(L10n.tr("缩放比例", "Zoom Level")) \(Int((tab.zoomScale * 100).rounded()))%"))

            HStack(spacing: 0) {
                ZoomStepButton(icon: "minus", tooltip: L10n.tr("缩小 (⌘-)", "Zoom Out (⌘-)"), isDark: isDark) {
                    tab.triggerZoom(.zoomOut)
                }
                Rectangle()
                    .fill(AppPalette.toolbarIcon(isDark).opacity(0.18))
                    .frame(width: 1, height: 14)
                ZoomStepButton(icon: "plus", tooltip: L10n.tr("放大 (⌘+)", "Zoom In (⌘+)"), isDark: isDark) {
                    tab.triggerZoom(.zoomIn)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppPalette.toolbarControlFill(isDark))
            )
        }
    }

    private func presentZoomMenu() {
        let currentPercent = Int((tab.zoomScale * 100).rounded())
        var items: [NativeMenuItem] = [
            .action(L10n.tr("缩放至适应宽度", "Zoom to Fit Width"), keyEquivalent: "8") { tab.triggerZoom(.fitWidth) },
            .action(L10n.tr("缩放至适应页面", "Zoom to Fit Page"), keyEquivalent: "9") { tab.triggerZoom(.fitPage) },
            .action(L10n.tr("实际大小", "Actual Size"), keyEquivalent: "0") { tab.triggerZoom(.actualSize) },
            .separator
        ]
        for percent in [50, 75, 100, 125, 150, 200, 300, 400] {
            items.append(.action("\(percent)%", isChecked: percent == currentPercent) {
                tab.triggerZoom(.scale(CGFloat(percent) / 100))
            })
        }
        NativeMenu.popUp(items, below: zoomAnchor.view)
    }

    private func presentSharingPicker() {
        guard let anchorView = shareAnchor.view else { return }
        let picker = NSSharingServicePicker(items: [tab.documentID.url])
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    // MARK: Search Field

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(AppPalette.labelTertiary(isDark))

            TextField(L10n.tr("搜索", "Search"), text: $tab.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .focused($isSearchFieldFocused)
                .onSubmit { submitSearch() }
                .onExitCommand { endSearch() }

            if !tab.searchQuery.isEmpty {
                Button {
                    endSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清除搜索", "Clear Search"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppPalette.toolbarControlFill(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppPalette.accentBlue.opacity(isSearchFieldFocused ? 0.75 : 0), lineWidth: 1.5)
        )
        .task(id: tab.searchQuery) {
            // Debounced live search while typing
            let trimmed = tab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != tab.lastSearchedQuery else { return }
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            tab.performSearch()
            if !trimmed.isEmpty {
                withAnimation(.easeInOut(duration: 0.18)) {
                    tab.isSearchVisible = true
                }
            }
        }
    }

    private func submitSearch() {
        let trimmed = tab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == tab.lastSearchedQuery && !tab.searchMatches.isEmpty {
            tab.selectNextSearchMatch()
        } else {
            tab.performSearch()
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            tab.isSearchVisible = true
        }
    }

    private func endSearch() {
        withAnimation(.easeInOut(duration: 0.18)) {
            tab.endSearch()
        }
        isSearchFieldFocused = false
    }
}

// MARK: - Toolbar Controls

struct ToolbarIconButton: View {
    let icon: String
    let tooltip: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    var activeTint: Color?
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14.5, weight: .regular))
                .foregroundColor(foregroundColor)
                .frame(width: 34, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return AppPalette.labelQuaternary(isDark)
        }
        if isActive, let tint = activeTint {
            return tint
        }
        return AppPalette.toolbarIcon(isDark)
    }

    private var backgroundColor: Color {
        if isActive {
            return AppPalette.toolbarActive(isDark)
        }
        if isHovered && !isDisabled {
            return AppPalette.toolbarHover(isDark)
        }
        return Color.clear
    }
}

struct ZoomStepButton: View {
    let icon: String
    let tooltip: String
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppPalette.toolbarIcon(isDark))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppPalette.toolbarActive(isDark) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .onHover { isHovered = $0 }
    }
}

struct ToolbarDivider: View {
    let isDark: Bool

    var body: some View {
        Rectangle()
            .fill(AppPalette.toolbarIcon(isDark).opacity(0.16))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 6)
    }
}

// MARK: - AppKit Bridges (anchors for NSMenu / NSSharingServicePicker)

/// Weak handle to an AppKit view inside the SwiftUI hierarchy.
final class NSViewAnchor {
    weak var view: NSView?
}

struct ViewAnchorRepresentable: NSViewRepresentable {
    let anchor: NSViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

struct NativeMenuItem {
    var title: String = ""
    var keyEquivalent: String = ""
    var isChecked: Bool = false
    var isSeparator: Bool = false
    var action: (() -> Void)?

    static var separator: NativeMenuItem {
        NativeMenuItem(isSeparator: true)
    }

    static func action(_ title: String, keyEquivalent: String = "", isChecked: Bool = false, _ action: @escaping () -> Void) -> NativeMenuItem {
        NativeMenuItem(title: title, keyEquivalent: keyEquivalent, isChecked: isChecked, action: action)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performHandler), keyEquivalent: keyEquivalent)
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performHandler() {
        handler()
    }
}

enum NativeMenu {
    /// Pops up a native menu right below `anchorView` (e.g. the zoom percentage pop-up).
    @MainActor
    static func popUp(_ items: [NativeMenuItem], below anchorView: NSView?) {
        guard let anchorView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = ClosureMenuItem(title: item.title, keyEquivalent: item.keyEquivalent, handler: item.action ?? {})
            menuItem.keyEquivalentModifierMask = item.keyEquivalent.isEmpty ? [] : [.command]
            menuItem.state = item.isChecked ? .on : .off
            menu.addItem(menuItem)
        }
        let origin = NSPoint(x: 0, y: anchorView.isFlipped ? anchorView.bounds.height + 5 : -5)
        menu.popUp(positioning: nil, at: origin, in: anchorView)
    }
}

// MARK: - Left Panel (PanelViewsDockViewController)

/// `240pt` left dock hosting either the Document Summary (thumbnails / outline / bookmarks) or the
/// View Settings panel — PDF Expert 3's two left toolbar toggles share this dock.
public struct ReaderLeftSidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public static let width: CGFloat = 240

    public var body: some View {
        Group {
            switch tab.leftPanel {
            case .documentSummary:
                documentSummary
            case .viewSettings:
                DocumentViewSettingsPanel(store: store, tab: tab, isDark: isDark)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(AppPalette.panelBackground(isDark))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppPalette.panelHairline(isDark))
                .frame(width: 1)
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

            HStack(spacing: 6) {
                Text(tab.activeSidebarTab.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                Spacer()
                headerAccessory
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            // Active Panel Content
            Group {
                switch tab.activeSidebarTab {
                case .thumbnails:
                    PDFPageThumbnailsPanel(store: store, tab: tab, isDark: isDark)
                case .outline:
                    PDFOutlinePanel(tab: tab, isDark: isDark)
                case .bookmarks:
                    PDFBookmarksPanel(store: store, tab: tab, isDark: isDark)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var headerAccessory: some View {
        switch tab.activeSidebarTab {
        case .thumbnails:
            Text(L10n.pageCountText(tab.pageCount))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(AppPalette.labelTertiary(isDark))
        case .outline:
            EmptyView()
        case .bookmarks:
            let isCurrentBookmarked = store.isPageBookmarked(pageIndex: tab.currentPageIndex, in: tab.documentID)
            PanelHeaderIconButton(
                icon: "plus",
                tooltip: L10n.tr("为当前页添加书签 (⌘D)", "Add Bookmark for Current Page (⌘D)"),
                isDisabled: isCurrentBookmarked,
                isDark: isDark
            ) {
                store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = (item == selection)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = item
                    }
                } label: {
                    label(item, isSelected)
                        .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? AppPalette.segmentedThumb(isDark) : Color.clear)
                                .shadow(color: Color.black.opacity(isSelected ? (isDark ? 0.35 : 0.10) : 0), radius: 1.5, x: 0, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

struct PanelTextButton: View {
    let title: String
    let icon: String
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(AppPalette.labelPrimary(isDark))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? AppPalette.rowHover(isDark) : AppPalette.panelListBackground(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppPalette.panelSeparator(isDark), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    let isDark: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(0..<tab.pageCount, id: \.self) { pageIdx in
                        PageThumbnailCell(
                            store: store,
                            tab: tab,
                            pageIndex: pageIdx,
                            maxSize: CGSize(width: 148, height: 192),
                            isDark: isDark
                        ) {
                            tab.navigateToPage(pageIdx)
                        }
                        .id(pageIdx)
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                proxy.scrollTo(tab.currentPageIndex, anchor: .center)
            }
            .onChange(of: tab.currentPageIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }
}

/// Page thumbnail rendered with the active GPU theme; shared by the left panel and the page overview grid.
struct PageThumbnailCell: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let pageIndex: Int
    let maxSize: CGSize
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isCurrent = (tab.currentPageIndex == pageIndex)
        let isBookmarked = store.isPageBookmarked(pageIndex: pageIndex, in: tab.documentID)
        let page = tab.pdfDocument.page(at: pageIndex)

        Button(action: action) {
            VStack(spacing: 7) {
                if let page {
                    let thumb = PDFThumbnailCache.shared.thumbnail(
                        for: page,
                        documentID: tab.documentID.id,
                        pageIndex: pageIndex,
                        theme: store.resolvedPDFTheme(isDark: isDark),
                        size: CGSize(width: maxSize.width * 2, height: maxSize.height * 2)
                    )
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxSize.width, maxHeight: maxSize.height)
                        .overlay(
                            Rectangle()
                                .stroke(Color.black.opacity(isDark ? 0.4 : 0.12), lineWidth: 0.5)
                        )
                        .overlay(alignment: .topTrailing) {
                            if isBookmarked {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppPalette.systemRed)
                                    .shadow(color: Color.black.opacity(0.2), radius: 1, x: 0, y: 0.5)
                                    .padding(.trailing, 8)
                                    .offset(y: -2)
                            }
                        }
                        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.10), radius: 2.5, x: 0, y: 1)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(
                                    isCurrent
                                        ? AppPalette.accentBlue
                                        : (isHovered ? AppPalette.accentBlue.opacity(0.35) : Color.clear),
                                    lineWidth: 2
                                )
                        )
                }

                Text(page?.label ?? "\(pageIndex + 1)")
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundColor(isCurrent ? .white : AppPalette.labelSecondary(isDark))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isCurrent ? AppPalette.accentBlue : Color.clear)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(isBookmarked ? L10n.tr("移除书签", "Remove Bookmark") : L10n.tr("添加书签", "Add Bookmark")) {
                store.toggleBookmark(pageIndex: pageIndex, in: tab.documentID)
            }
        }
    }
}

// MARK: - 2. PDFOutlinePanel (PDFOutlinePanelViewController)

struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let pageLabel: String?
    let children: [PDFOutlineNode]
}

struct PDFOutlinePanel: View {
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    @State private var nodes: [PDFOutlineNode] = []
    @State private var expandedIDs: Set<UUID> = []
    @State private var hasLoaded = false

    private struct OutlineRow: Identifiable {
        let node: PDFOutlineNode
        let level: Int
        var id: UUID { node.id }
    }

    var body: some View {
        Group {
            if hasLoaded && nodes.isEmpty {
                PanelEmptyState(icon: "list.bullet.indent", title: L10n.tr("此文档不包含目录大纲", "This document has no outline"), subtitle: nil, isDark: isDark)
            } else {
                let rows = visibleRows
                let activeID = activeNodeID(in: rows)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            PDFOutlineRowView(
                                node: row.node,
                                level: row.level,
                                isExpanded: expandedIDs.contains(row.node.id),
                                isActive: row.node.id == activeID,
                                isDark: isDark,
                                onToggle: { toggle(row.node) },
                                onSelect: {
                                    if let pIdx = row.node.pageIndex {
                                        tab.navigateToPage(pIdx)
                                    }
                                }
                            )
                        }
                    }
                    .background(AppPalette.panelListBackground(isDark))
                }
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private var visibleRows: [OutlineRow] {
        var rows: [OutlineRow] = []
        func walk(_ list: [PDFOutlineNode], level: Int) {
            for node in list {
                rows.append(OutlineRow(node: node, level: level))
                if expandedIDs.contains(node.id) {
                    walk(node.children, level: level + 1)
                }
            }
        }
        walk(nodes, level: 0)
        return rows
    }

    /// The section containing the current page: last visible row starting at or before it.
    private func activeNodeID(in rows: [OutlineRow]) -> UUID? {
        rows.last(where: { ($0.node.pageIndex ?? Int.max) <= tab.currentPageIndex })?.node.id
    }

    private func toggle(_ node: PDFOutlineNode) {
        withAnimation(.easeInOut(duration: 0.14)) {
            if expandedIDs.contains(node.id) {
                expandedIDs.remove(node.id)
            } else {
                expandedIDs.insert(node.id)
            }
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let root = tab.pdfDocument.outlineRoot else { return }
        nodes = buildOutlineNodes(from: root)

        // Short outlines open fully; long ones only reveal the branch holding the current page
        var parentIDs: [UUID] = []
        var nodeCount = 0
        func collect(_ list: [PDFOutlineNode]) {
            for node in list {
                nodeCount += 1
                if !node.children.isEmpty {
                    parentIDs.append(node.id)
                    collect(node.children)
                }
            }
        }
        collect(nodes)
        expandedIDs = nodeCount <= 30 ? Set(parentIDs) : Set(ancestorIDs(ofPage: tab.currentPageIndex))
    }

    private func ancestorIDs(ofPage page: Int) -> [UUID] {
        var best: [UUID] = []
        func walk(_ list: [PDFOutlineNode], path: [UUID]) {
            for node in list {
                if let pIdx = node.pageIndex, pIdx <= page {
                    best = path
                }
                walk(node.children, path: path + [node.id])
            }
        }
        walk(nodes, path: [])
        return best
    }

    private func buildOutlineNodes(from parent: PDFOutline) -> [PDFOutlineNode] {
        var result: [PDFOutlineNode] = []
        for i in 0..<parent.numberOfChildren {
            guard let child = parent.child(at: i) else { continue }
            var pageIdx: Int?
            var pageLabel: String?
            if let page = child.destination?.page ?? child.action?.PerformPage(in: tab.pdfDocument) {
                let idx = tab.pdfDocument.index(for: page)
                if idx >= 0 && idx < tab.pageCount {
                    pageIdx = idx
                    pageLabel = page.label ?? "\(idx + 1)"
                }
            }
            result.append(
                PDFOutlineNode(
                    title: child.label ?? L10n.tr("未命名章节", "Untitled Section"),
                    pageIndex: pageIdx,
                    pageLabel: pageLabel,
                    children: buildOutlineNodes(from: child)
                )
            )
        }
        return result
    }
}

extension PDFAction {
    fileprivate func PerformPage(in doc: PDFDocument) -> PDFPage? {
        if let goTo = self as? PDFActionGoTo {
            return goTo.destination.page
        }
        return nil
    }
}

struct PDFOutlineRowView: View {
    let node: PDFOutlineNode
    let level: Int
    let isExpanded: Bool
    let isActive: Bool
    let isDark: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Group {
                if node.children.isEmpty {
                    Color.clear
                } else {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(AppPalette.labelTertiary(isDark))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 18, height: 18)

            Text(node.title)
                .font(.system(size: 12.5, weight: level == 0 ? .medium : .regular))
                .foregroundColor(isActive ? AppPalette.accentBlue : AppPalette.labelPrimary(isDark))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)

            if let label = node.pageLabel {
                Text(label)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(isActive ? AppPalette.accentBlue : AppPalette.labelTertiary(isDark))
                    .padding(.top, 2)
            }
        }
        .padding(.leading, 8 + CGFloat(level) * 14)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(
            isActive
                ? AppPalette.accentBlue.opacity(isDark ? 0.20 : 0.10)
                : (isHovered ? AppPalette.rowHover(isDark) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)
                .padding(.leading, 30 + CGFloat(level) * 14)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
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
                subtitle: L10n.tr("按 ⌘D 或点击右上角的 + 标记当前页", "Press ⌘D or click + in the top right to bookmark this page"),
                isDark: isDark
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { bm in
                        BookmarkRowView(
                            bookmark: bm,
                            pageLabel: tab.pdfDocument.page(at: bm.pageIndex)?.label ?? "\(bm.pageIndex + 1)",
                            isCurrent: bm.pageIndex == tab.currentPageIndex,
                            isDark: isDark,
                            onSelect: { tab.navigateToPage(bm.pageIndex) },
                            onDelete: { store.removeBookmark(id: bm.id, in: tab.documentID) }
                        )
                    }
                }
                .background(AppPalette.panelListBackground(isDark))
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundColor(AppPalette.systemRed)

            Text(bookmark.title)
                .font(.system(size: 12.5, weight: isCurrent ? .medium : .regular))
                .foregroundColor(isCurrent ? AppPalette.accentBlue : AppPalette.labelPrimary(isDark))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(pageLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(AppPalette.labelTertiary(isDark))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            isCurrent
                ? AppPalette.accentBlue.opacity(isDark ? 0.20 : 0.10)
                : (isHovered ? AppPalette.rowHover(isDark) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)
                .padding(.leading, 33)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L10n.jumpToPage(pageLabel), action: onSelect)
            Divider()
            Button(L10n.tr("删除书签", "Delete Bookmark"), role: .destructive, action: onDelete)
        }
    }
}

// MARK: - 4. DocumentViewSettingsPanel ("Layout options")

struct DocumentViewSettingsPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.tr("显示选项", "View Settings"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))

                // 1. Page Layout Mode (Single / Two Pages / Cover)
                settingsSection(L10n.tr("页面布局", "Page Layout")) {
                    HStack(spacing: 6) {
                        ForEach(ReaderLayoutMode.allCases) { mode in
                            OptionTile(icon: mode.iconName, title: mode.shortTitle, isSelected: tab.layoutMode == mode, isDark: isDark) {
                                tab.layoutMode = mode
                            }
                        }
                    }
                }

                // 2. Split View Mode
                settingsSection(L10n.tr("分屏视图", "Split View")) {
                    HStack(spacing: 6) {
                        ForEach(ReaderSplitMode.allCases) { mode in
                            OptionTile(icon: mode.iconName, title: mode.shortTitle, isSelected: tab.splitMode == mode, isDark: isDark) {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    tab.splitMode = mode
                                }
                            }
                        }
                    }

                    if tab.splitMode != .disabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(L10n.tr("同步滚动和缩放", "Sync Scroll & Zoom"), isOn: $tab.syncScrollAndZoom)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .font(.system(size: 12))
                                .foregroundColor(AppPalette.labelPrimary(isDark))

                            HStack(spacing: 6) {
                                PanelTextButton(title: L10n.tr("对调位置", "Swap Panes"), icon: "arrow.left.arrow.right", isDark: isDark) {
                                    tab.isSplitSwapped.toggle()
                                }
                                PanelTextButton(title: L10n.tr("对比文档…", "Compare…"), icon: "doc.on.doc", isDark: isDark) {
                                    tab.showSplitDocumentPicker = true
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                // 3. Page Reading Theme (Follow System / Day / Sepia / Night + Light Sepia option)
                settingsSection(L10n.tr("阅读主题", "Reading Theme")) {
                    HStack(spacing: 6) {
                        ForEach(PDFReadingThemeMode.allCases) { mode in
                            ThemeModePreviewTile(
                                mode: mode,
                                useSepiaInLight: store.useSepiaForLightSystemTheme,
                                isSelected: store.readingThemeMode == mode,
                                isDark: isDark
                            ) {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    store.readingThemeMode = mode
                                }
                            }
                        }
                    }

                    Toggle(isOn: $store.useSepiaForLightSystemTheme) {
                        Text(L10n.tr("浅色时使用纸质替代日间", "Use Sepia in Light Mode"))
                            .font(.system(size: 11.5))
                            .foregroundColor(AppPalette.labelPrimary(isDark))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.top, 2)
                }

                // 4. Page Tools (Clear Margins + Rotation)
                settingsSection(L10n.tr("页面", "Page")) {
                    Toggle(isOn: Binding(
                        get: { tab.isClearMarginsEnabled },
                        set: { newValue in
                            tab.isClearMarginsEnabled = newValue
                            tab.applyClearMarginsIfNeeded()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("清除空白边", "Clear Margins"))
                                .font(.system(size: 12.5))
                                .foregroundColor(AppPalette.labelPrimary(isDark))
                            Text(L10n.tr("识别内容边界并裁切页边距", "Detect content bounds and crop page margins"))
                                .font(.system(size: 10.5))
                                .foregroundColor(AppPalette.labelTertiary(isDark))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    HStack(spacing: 6) {
                        PanelTextButton(title: L10n.tr("向左旋转", "Rotate Left"), icon: "rotate.left", isDark: isDark) {
                            tab.rotateCurrentPage(clockwise: false)
                        }
                        PanelTextButton(title: L10n.tr("向右旋转", "Rotate Right"), icon: "rotate.right", isDark: isDark) {
                            tab.rotateCurrentPage(clockwise: true)
                        }
                    }
                }

                // 5. App UI Appearance (System / Light / Dark)
                settingsSection(L10n.tr("界面外观", "App Appearance")) {
                    PanelSegmentedControl(items: AppAppearanceMode.allCases, selection: $store.appearanceMode, isDark: isDark) { mode, _ in
                        Text(mode.shortTitle)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }

                // 6. Language (Follow System + 12 Languages)
                settingsSection(L10n.tr("语言", "Language")) {
                    Menu {
                        ForEach(AppLanguage.allCases) { lang in
                            Button {
                                store.appLanguage = lang
                            } label: {
                                HStack {
                                    Text(lang.title)
                                    if store.appLanguage == lang {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(AppPalette.labelSecondary(isDark))
                            Text(store.appLanguage.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppPalette.labelPrimary(isDark))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(AppPalette.labelTertiary(isDark))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppPalette.panelListBackground(isDark))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(AppPalette.panelSeparator(isDark), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .padding(14)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(AppPalette.labelTertiary(isDark))
            content()
        }
    }
}

struct OptionTile: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(isSelected ? AppPalette.accentBlue : AppPalette.labelSecondary(isDark))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppPalette.panelListBackground(isDark) : (isHovered ? AppPalette.rowHover(isDark) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppPalette.accentBlue.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ThemeModePreviewTile: View {
    let mode: PDFReadingThemeMode
    let useSepiaInLight: Bool
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        let previewTheme = mode.resolvedTheme(isDark: isDark, useSepiaInLight: useSepiaInLight)
        let lightPreviewTheme: PDFViewTheme = useSepiaInLight ? .sepia : .day

        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if mode == .system {
                        HStack(spacing: 0) {
                            lightPreviewTheme.documentBackgroundColor(isDarkUI: false)
                            PDFViewTheme.night.documentBackgroundColor(isDarkUI: true)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        SplitMiniPagePreview(leftTheme: lightPreviewTheme, rightTheme: .night)
                            .frame(width: 24, height: 32)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(previewTheme.documentBackgroundColor(isDarkUI: isDark))
                        MiniPagePreview(theme: previewTheme)
                            .frame(width: 24, height: 32)
                    }
                }
                .frame(height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? AppPalette.accentBlue : AppPalette.panelSeparator(isDark), lineWidth: isSelected ? 2 : 1)
                )

                Text(mode.shortTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundColor(isSelected ? AppPalette.accentBlue : AppPalette.labelSecondary(isDark))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(L10n.tr("阅读主题", "Reading Theme")): \(mode.title)")
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
