import AppKit
import PDFKit
import SwiftUI

// MARK: - Top Reader Toolbar

/// PDF Expert 3 toolbar layout: dock toggles + zoom on the left, reading tools in the middle,
/// share / bookmark / search on the right. Colors follow the app appearance instead of PDF Expert's fixed graphite.
public struct ReaderToolbarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @State private var anchors = ToolbarAnchors()
    @FocusState private var isSearchFieldFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccentColor) private var accent
    private var isDark: Bool { colorScheme == .dark }

    public static let height: CGFloat = 40

    /// Narrower windows shorten search, then collapse menu labels and the zoom stepper.
    enum Density: String {
        case regular, compact, minimal

        var iconWidth: CGFloat { self == .minimal ? 28 : 34 }
    }

    public var body: some View {
        // The first layout that fits wins, so nothing is clipped down to the window's minimum width
        ViewThatFits(in: .horizontal) {
            toolbarContent(.regular)
            toolbarContent(.compact)
            toolbarContent(.minimal)
        }
        .frame(height: Self.height)
        .background(AppPalette.toolbarBackground(isDark), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.chromeHairline(isDark))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("阅读工具栏", "Reader Toolbar")))
        .onChange(of: tab.searchFocusToken) { _, _ in
            isSearchFieldFocused = true
        }
    }

    private func toolbarContent(_ density: Density) -> some View {
        HStack(spacing: 2) {
            zoomControls(density)

            ToolbarDivider(isDark: isDark)
            let layoutIcon = tab.isPageOverviewVisible ? "square.grid.2x2"
                : (tab.splitMode == .disabled ? tab.layoutMode.iconName : tab.splitMode.iconName)
            toolbarMenuButton("layout", density, icon: layoutIcon,
                              tooltip: L10n.tr("页面布局", "Page Layout"),
                              title: L10n.tr("布局", "Layout"), items: layoutMenuItems)

            Spacer(minLength: density == .minimal ? 6 : 16)

            // Reading theme and page tools
            HStack(spacing: 2) {
                ForEach(PDFReadingThemeMode.allCases) { mode in
                    ToolbarIconButton(
                        icon: mode.toolbarIconName,
                        tooltip: "\(L10n.tr("阅读主题", "Reading Theme")): \(mode.title)",
                        isActive: store.readingThemeMode == mode,
                        activeTint: accent,
                        iconWidth: density.iconWidth,
                        isDark: isDark
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) { store.readingThemeMode = mode }
                    }
                }

                ToolbarDivider(isDark: isDark)

                ToolbarIconButton(
                    icon: "crop",
                    tooltip: tab.isClearMarginsEnabled ? L10n.tr("恢复页面空白边 (⇧⌘M)", "Restore Page Margins (⇧⌘M)") : L10n.tr("清除空白边 (⇧⌘M)", "Clear Margins (⇧⌘M)"),
                    isActive: tab.isClearMarginsEnabled,
                    iconWidth: density.iconWidth,
                    isDark: isDark
                ) {
                    tab.isClearMarginsEnabled.toggle()
                    tab.applyClearMarginsIfNeeded()
                }

                ToolbarIconButton(
                    icon: "rotate.left",
                    tooltip: L10n.tr("向左旋转", "Rotate Left"),
                    iconWidth: density.iconWidth,
                    isDark: isDark
                ) {
                    tab.rotateCurrentPage(clockwise: false)
                }
                ToolbarIconButton(
                    icon: "rotate.right",
                    tooltip: L10n.tr("向右旋转", "Rotate Right"),
                    iconWidth: density.iconWidth,
                    isDark: isDark
                ) {
                    tab.rotateCurrentPage(clockwise: true)
                }
            }

            Spacer(minLength: density == .minimal ? 6 : 16)

            // Right Group: Share + Bookmark + Search Field (PDFSearchToolbarItemView)
            let shareAnchor = anchors.anchor("share", density)
            ToolbarIconButton(
                icon: "square.and.arrow.up",
                tooltip: L10n.tr("分享", "Share"),
                iconWidth: density.iconWidth,
                isDark: isDark
            ) {
                presentSharingPicker(from: shareAnchor)
            }
            .background(ViewAnchorRepresentable(anchor: shareAnchor).allowsHitTesting(false))

            let isBookmarked = store.isPageBookmarked(pageIndex: tab.currentPageIndex, in: tab.documentID)
            ToolbarIconButton(
                icon: isBookmarked ? "bookmark.fill" : "bookmark",
                tooltip: isBookmarked ? L10n.tr("移除当前页书签 (⌘D)", "Remove Bookmark for Current Page (⌘D)") : L10n.tr("为当前页添加书签 (⌘D)", "Add Bookmark for Current Page (⌘D)"),
                isActive: isBookmarked,
                activeTint: AppPalette.systemRed,
                iconWidth: density.iconWidth,
                isDark: isDark
            ) {
                store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
            }

            searchField
                .frame(width: density == .regular ? 176 : (density == .compact ? 132 : 90))
                .padding(.leading, 6)
        }
        .padding(.horizontal, 8)
    }

    private func toolbarMenuButton(
        _ name: String, _ density: Density, icon: String, tooltip: String, title: String? = nil,
        items: @escaping () -> [NativeMenuItem]
    ) -> some View {
        let anchor = anchors.anchor(name, density)
        return ToolbarIconButton(icon: icon, tooltip: tooltip, title: density == .minimal ? nil : title,
                                 showsMenuIndicator: true, iconWidth: density.iconWidth, isDark: isDark) {
            NativeMenu.popUp(items(), below: anchor.view)
        }
        .background(ViewAnchorRepresentable(anchor: anchor).allowsHitTesting(false))
    }

    private func layoutMenuItems() -> [NativeMenuItem] {
        var items = ReaderLayoutMode.allCases.enumerated().map { index, mode in
            NativeMenuItem.action(mode.title, keyEquivalent: String(index + 1),
                                  isChecked: !tab.isPageOverviewVisible && tab.layoutMode == mode) {
                tab.showReadingLayout(mode)
            }
        }
        items += [
            .action(L10n.tr("页面概览", "Page Overview"), keyEquivalent: "1", keyModifiers: [.control, .command],
                    isChecked: tab.isPageOverviewVisible) {
                withAnimation(AppAnimation.panel) { tab.isPageOverviewVisible.toggle() }
            },
            .separator
        ]
        let splitModes = ReaderSplitMode.allCases.filter { $0 != .disabled || tab.splitMode != .disabled }
        items += splitModes.map { mode in
            NativeMenuItem.action(mode.title,
                                  isChecked: !tab.isPageOverviewVisible && mode != .disabled && tab.splitMode == mode) {
                tab.showSplitMode(mode)
            }
        }
        if tab.splitMode != .disabled {
            items += [
                .separator,
                .action(L10n.tr("对比文档…", "Compare…")) {
                    withAnimation(AppAnimation.snappy) {
                        tab.isPageOverviewVisible = false
                        tab.showSplitDocumentPicker = true
                    }
                }
            ]
        }
        return items
    }

    // MARK: Zoom (percentage pop-up + − / + stepper)

    private func zoomControls(_ density: Density) -> some View {
        let zoomAnchor = anchors.anchor("zoom", density)
        let roundedPercent = Int((tab.activeZoomScale * 100).rounded())
        return HStack(spacing: 6) {
            Button {
                presentZoomMenu(below: zoomAnchor)
            } label: {
                HStack(spacing: 4) {
                    Text("\(roundedPercent)%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(AppAnimation.micro, value: roundedPercent)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
                .foregroundColor(AppPalette.toolbarIcon(isDark))
                .frame(width: density == .minimal ? 62 : 72, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppPalette.toolbarControlFill(isDark))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ViewAnchorRepresentable(anchor: zoomAnchor).allowsHitTesting(false))
            .help(L10n.tr("缩放比例 (⌘8 适应宽度 · ⌘0 实际大小)", "Zoom Level (⌘8 Fit Width · ⌘0 Actual Size)"))
            .accessibilityLabel(Text("\(L10n.tr("缩放比例", "Zoom Level")) \(roundedPercent)%"))

            if density != .minimal {
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
    }

    private func presentZoomMenu(below zoomAnchor: NSViewAnchor) {
        let currentPercent = Int((tab.activeZoomScale * 100).rounded())
        var items: [NativeMenuItem] = [
            .action(L10n.tr("缩放至适应宽度", "Zoom to Fit Width"), keyEquivalent: "8", isChecked: tab.activePaneFitsWidth) { tab.triggerZoom(.fitWidth) },
            .action(L10n.tr("缩放至适应页面", "Zoom to Fit Page"), keyEquivalent: "9") { tab.triggerZoom(.fitPage) },
            .action(L10n.tr("实际大小", "Actual Size"), keyEquivalent: "0") { tab.triggerZoom(.actualSize) },
            .separator
        ]
        for percent in [50, 75, 100, 125, 150, 200, 300, 400] {
            items.append(.action("\(percent)%", isChecked: !tab.activePaneFitsWidth && percent == currentPercent) {
                tab.triggerZoom(.scale(CGFloat(percent) / 100))
            })
        }
        NativeMenu.popUp(items, below: zoomAnchor.view)
    }

    private func presentSharingPicker(from shareAnchor: NSViewAnchor) {
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

            TextField(L10n.tr("搜索 (⌘F)", "Search (⌘F)"), text: $tab.searchQuery)
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
                .stroke(accent.opacity(isSearchFieldFocused ? 0.75 : 0), lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("搜索", "Search")))
        .task(id: tab.searchQuery) {
            // Debounced live search while typing
            let trimmed = tab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != tab.lastSearchedQuery else { return }
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            tab.performSearch()
            if !trimmed.isEmpty {
                withAnimation(AppAnimation.panel) {
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
        withAnimation(AppAnimation.panel) {
            tab.isSearchVisible = true
        }
    }

    private func endSearch() {
        withAnimation(AppAnimation.panel) {
            tab.endSearch()
        }
        isSearchFieldFocused = false
    }
}

// MARK: - Toolbar Controls

struct ToolbarIconButton: View {
    let icon: String
    let tooltip: String
    var title: String? = nil
    var showsMenuIndicator = false
    var isActive: Bool = false
    var isDisabled: Bool = false
    var activeTint: Color?
    var iconWidth: CGFloat = 34
    var fillsRow = false
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14.5, weight: .regular))
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if showsMenuIndicator {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
                .foregroundColor(foregroundColor)
                .padding(.horizontal, fillsRow ? 14 : (title == nil ? 0 : 8))
                .frame(width: title == nil ? iconWidth + (showsMenuIndicator ? 6 : 0) : nil, height: fillsRow ? 40 : 28)
                .frame(maxWidth: fillsRow ? .infinity : nil, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isHovered)
                .animation(AppAnimation.micro, value: isActive)
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

/// One anchor per control and toolbar density: `ViewThatFits` may build the layouts it doesn't show,
/// which must not take over the anchor of the visible one.
final class ToolbarAnchors {
    private var anchors: [String: NSViewAnchor] = [:]

    func anchor(_ name: String, _ density: ReaderToolbarView.Density) -> NSViewAnchor {
        let key = "\(name).\(density.rawValue)"
        if let existing = anchors[key] {
            return existing
        }
        let created = NSViewAnchor()
        anchors[key] = created
        return created
    }
}

private final class AnchorPassthroughNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

struct ViewAnchorRepresentable: NSViewRepresentable {
    let anchor: NSViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorPassthroughNSView()
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
    var keyModifiers: NSEvent.ModifierFlags = [.command]
    var isChecked: Bool = false
    var isEnabled: Bool = true
    var isSeparator: Bool = false
    var action: (() -> Void)?

    static var separator: NativeMenuItem {
        NativeMenuItem(isSeparator: true)
    }

    static func action(
        _ title: String,
        keyEquivalent: String = "",
        keyModifiers: NSEvent.ModifierFlags = [.command],
        isChecked: Bool = false,
        isEnabled: Bool = true,
        _ action: @escaping () -> Void
    ) -> NativeMenuItem {
        NativeMenuItem(
            title: title,
            keyEquivalent: keyEquivalent,
            keyModifiers: keyModifiers,
            isChecked: isChecked,
            isEnabled: isEnabled,
            action: action
        )
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
            menuItem.keyEquivalentModifierMask = item.keyEquivalent.isEmpty ? [] : item.keyModifiers
            menuItem.state = item.isChecked ? .on : .off
            menuItem.isEnabled = item.isEnabled
            menu.addItem(menuItem)
        }
        let origin = NSPoint(x: 0, y: anchorView.isFlipped ? anchorView.bounds.height + 5 : -5)
        menu.popUp(positioning: nil, at: origin, in: anchorView)
    }
}

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
            .padding(.horizontal, 14)
            .frame(height: 34)

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            // Active Panel Content
            Group {
                switch tab.activeSidebarTab {
                case .thumbnails:
                    PDFPageThumbnailsPanel(store: store, tab: tab, panelWidth: panelWidth, isDark: isDark)
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
            Text(L10n.pageCountText(tab.activeThumbnailSource.document.pageCount))
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
                        .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
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

    var body: some View {
        let source = tab.activeThumbnailSource
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
                proxy.scrollTo(source.pageIndex, anchor: .center)
            }
            .onChange(of: source.pageIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
        .id(ObjectIdentifier(source.document))
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
        let isBookmarked = store.isPageBookmarked(pageIndex: pageIndex, in: source.documentID)
        let page = source.document.page(at: pageIndex)
        let pageLabel = tab.thumbnailPageNumber(at: pageIndex, in: source.document)

        Button(action: action) {
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
                                        ? accent
                                        : (isHovered ? accent.opacity(0.35) : Color.clear),
                                    lineWidth: 2
                                )
                        )
                }

                Text(pageLabel)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundColor(isCurrent ? .white : AppPalette.labelSecondary(isDark))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isCurrent ? accent : Color.clear)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.pageTitle(pageLabel)))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(isBookmarked ? L10n.tr("移除书签", "Remove Bookmark") : L10n.tr("添加书签", "Add Bookmark")) {
                store.toggleBookmark(pageIndex: pageIndex, in: source.documentID)
            }
        }
    }
}

// MARK: - 2. PDFOutlinePanel (PDFOutlinePanelViewController)

struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    /// Destination point in page space (origin bottom-left); `nil` means the top of the page.
    /// A component of kPDFDestinationUnspecifiedValue keeps the current position on that axis.
    let point: CGPoint?
    let children: [PDFOutlineNode]
    /// Destination's y; `nil` when unspecified (the position on the page is left open)
    var top: CGFloat? { point.flatMap { $0.y < 1_000_000 ? $0.y : nil } }
}

struct PDFOutlinePanel: View {
    @ObservedObject var tab: DocumentTabState
    @ObservedObject private var location: ReadingLocation
    let isDark: Bool

    init(tab: DocumentTabState, isDark: Bool) {
        self._tab = ObservedObject(wrappedValue: tab)
        self._location = ObservedObject(wrappedValue: tab.readingLocation)
        self.isDark = isDark
    }

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
                                pageLabel: row.node.pageIndex.map { tab.displayPageNumber(at: $0) },
                                level: row.level,
                                isExpanded: expandedIDs.contains(row.node.id),
                                isActive: row.node.id == activeID,
                                isDark: isDark,
                                onToggle: { toggle(row.node) },
                                onSelect: {
                                    if let pIdx = row.node.pageIndex {
                                        tab.navigateToPage(pIdx, point: row.node.point)
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

    /// The section being read: the last visible row starting before the current page, or on it above the
    /// reading line, so the right one of several sections on the same page is highlighted.
    /// The page and the reading line both come from `location` (the top-of-view destination), published
    /// together. Mixing in `tab.currentPageIndex` — which PDFKit derives from the middle of the view and
    /// updates on a different cadence — made the highlight flip back and forth while scrolling.
    private func activeNodeID(in rows: [OutlineRow]) -> UUID? {
        Self.activeSection(in: rows.map(\.node), locationPage: location.pageIndex,
                           readingLineY: location.readingLineY, fallbackPage: tab.currentPageIndex)
    }

    static func activeSection(in nodes: [PDFOutlineNode], locationPage: Int,
                              readingLineY: CGFloat, fallbackPage: Int) -> UUID? {
        let page = locationPage >= 0 ? locationPage : fallbackPage
        return nodes.last(where: { node in
            guard let nodePage = node.pageIndex, nodePage <= page else { return false }
            guard nodePage == page, let top = node.top else { return true }
            return top >= readingLineY
        })?.id
    }

    private func toggle(_ node: PDFOutlineNode) {
        withAnimation(AppAnimation.snappy) {
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
            var point: CGPoint?
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            if let page = destination?.page {
                let idx = tab.pdfDocument.index(for: page)
                if idx >= 0 && idx < tab.pageCount {
                    pageIdx = idx
                    point = destination?.point
                }
            }
            result.append(
                PDFOutlineNode(
                    title: child.label ?? L10n.tr("未命名章节", "Untitled Section"),
                    pageIndex: pageIdx,
                    point: point,
                    children: buildOutlineNodes(from: child)
                )
            )
        }
        return result
    }
}

struct PDFOutlineRowView: View {
    let node: PDFOutlineNode
    let pageLabel: String?
    let level: Int
    let isExpanded: Bool
    let isActive: Bool
    let isDark: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.appAccentColor) private var accent

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
                .foregroundColor(isActive ? accent : AppPalette.labelPrimary(isDark))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)
                .accessibilityHidden(true)

            if let label = pageLabel {
                Text(label)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(isActive ? accent : AppPalette.labelTertiary(isDark))
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 8 + CGFloat(level) * 14)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(
            isActive
                ? accent.opacity(isDark ? 0.20 : 0.10)
                : (isHovered ? AppPalette.rowHover(isDark) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)
                .padding(.leading, 30 + CGFloat(level) * 14)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(pageLabel.map { "\(node.title), \(L10n.pageTitle($0))" } ?? node.title))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onSelect)
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
                            pageLabel: tab.displayPageNumber(at: bm.pageIndex),
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
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundColor(AppPalette.systemRed)

            Text(bookmark.title)
                .font(.system(size: 12.5, weight: isCurrent ? .medium : .regular))
                .foregroundColor(isCurrent ? accent : AppPalette.labelPrimary(isDark))
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
                ? accent.opacity(isDark ? 0.20 : 0.10)
                : (isHovered ? AppPalette.rowHover(isDark) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)
                .padding(.leading, 33)
        }
        .contentShape(Rectangle())
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
