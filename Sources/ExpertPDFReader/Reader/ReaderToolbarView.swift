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

    /// Narrower windows shorten search and compress the controls while preserving their actions.
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
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(AppPalette.toolbarBackground(isDark), ignoresSafeAreaEdges: [])
        .background(PanelCursorRect())
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
                              title: L10n.tr("布局", "Layout"),
                              isActive: tab.isPageOverviewVisible || tab.splitMode != .disabled,
                              activeTint: accent,
                              items: layoutMenuItems)

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
                        withAnimation(AppAnimation.micro) { store.readingThemeMode = mode }
                    }
                }

                ToolbarDivider(isDark: isDark)

                ToolbarIconButton(
                    icon: "crop",
                    tooltip: tab.isClearMarginsEnabled ? L10n.tr("恢复页面空白边 (⇧⌘M)", "Restore Page Margins (⇧⌘M)") : L10n.tr("清除空白边 (⇧⌘M)", "Clear Margins (⇧⌘M)"),
                    isActive: tab.isClearMarginsEnabled,
                    activeTint: accent,
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
                activeTint: accent,
                bouncesOnActiveChange: true,
                iconWidth: density.iconWidth,
                isDark: isDark
            ) {
                store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
            }

            searchField(showsShortcut: density == .regular)
                .frame(width: density == .regular ? 176 : (density == .compact ? 132 : 106))
                .padding(.leading, 6)
        }
        .padding(.horizontal, 8)
    }

    private func toolbarMenuButton(
        _ name: String, _ density: Density, icon: String, tooltip: String, title: String? = nil,
        isActive: Bool = false, activeTint: Color? = nil,
        items: @escaping () -> [NativeMenuItem]
    ) -> some View {
        let anchor = anchors.anchor(name, density)
        return ToolbarIconButton(icon: icon, tooltip: tooltip, title: density == .minimal ? nil : title,
                                 showsMenuIndicator: true, isActive: isActive, activeTint: activeTint,
                                 iconWidth: density.iconWidth, isDark: isDark) {
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
        let stepWidth: CGFloat = density == .minimal ? 24 : 30
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

            HStack(spacing: 0) {
                ZoomStepButton(icon: "minus", tooltip: L10n.tr("缩小 (⌘-)", "Zoom Out (⌘-)"), width: stepWidth, isDark: isDark) {
                    tab.triggerZoom(.zoomOut)
                }
                Rectangle()
                    .fill(AppPalette.toolbarIcon(isDark).opacity(0.18))
                    .frame(width: 1, height: 14)
                ZoomStepButton(icon: "plus", tooltip: L10n.tr("放大 (⌘+)", "Zoom In (⌘+)"), width: stepWidth, isDark: isDark) {
                    tab.triggerZoom(.zoomIn)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppPalette.toolbarControlFill(isDark))
            )
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

    private func searchField(showsShortcut: Bool) -> some View {
        let shortcutLabel = L10n.tr("搜索 (⌘F)", "Search (⌘F)")
        let searchLabel = L10n.tr("搜索", "Search")
        return HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(AppPalette.labelTertiary(isDark))

            TextField(showsShortcut ? shortcutLabel : searchLabel, text: $tab.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .focused($isSearchFieldFocused)
                .onSubmit { submitSearch() }
                .onExitCommand { endSearch() }
                .help(shortcutLabel)

            if !tab.searchQuery.isEmpty {
                Button {
                    endSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
                .buttonStyle(TactilePressButtonStyle())
                .help(L10n.tr("清除搜索", "Clear Search"))
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.micro, value: tab.searchQuery.isEmpty)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppPalette.toolbarControlFill(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(accent.opacity(isSearchFieldFocused ? 0.75 : 0), lineWidth: 1.5)
                .animation(AppAnimation.micro, value: isSearchFieldFocused)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(searchLabel))
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
    var bouncesOnActiveChange: Bool = false
    var iconWidth: CGFloat = 34
    var fillsRow = false
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                iconImage
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(labelForegroundColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if showsMenuIndicator {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(labelForegroundColor)
                }
            }
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
        .buttonStyle(TactilePressButtonStyle())
        .disabled(isDisabled)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var iconImage: some View {
        let base = Image(systemName: icon)
            .font(.system(size: 14.5, weight: .regular))
            .foregroundColor(iconForegroundColor)
        if bouncesOnActiveChange && !AppAnimation.reduceMotion {
            base.symbolEffect(.bounce, value: isActive)
        } else {
            base
        }
    }

    private var iconForegroundColor: Color {
        if isDisabled {
            return AppPalette.labelQuaternary(isDark)
        }
        if isActive, let tint = activeTint {
            return tint
        }
        return AppPalette.toolbarIcon(isDark)
    }

    private var labelForegroundColor: Color {
        isDisabled ? AppPalette.labelQuaternary(isDark) : AppPalette.toolbarIcon(isDark)
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
    let width: CGFloat
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppPalette.toolbarIcon(isDark))
                .frame(width: width, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppPalette.toolbarActive(isDark) : Color.clear)
                )
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(TactilePressButtonStyle())
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
