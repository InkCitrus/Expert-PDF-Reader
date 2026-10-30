import AppKit
import SwiftUI

public enum ShortcutGuideCategory: String, CaseIterable, Identifiable {
    case all
    case tabs
    case navigation
    case viewAndZoom
    case searchAndBookmarks
    case tips

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:                return L10n.tr("全部", "All")
        case .tabs:               return L10n.tr("标签页", "Tabs")
        case .navigation:         return L10n.tr("阅读与导航", "Navigation")
        case .viewAndZoom:        return L10n.tr("视图与缩放", "View & Zoom")
        case .searchAndBookmarks: return L10n.tr("搜索与书签", "Search & Bookmarks")
        case .tips:               return L10n.tr("实用技巧", "Tips")
        }
    }

    public var iconName: String {
        switch self {
        case .all:                return "square.grid.2x2"
        case .tabs:               return "macwindow.on.rectangle"
        case .navigation:         return "arrow.left.arrow.right"
        case .viewAndZoom:        return "sidebar.left"
        case .searchAndBookmarks: return "magnifyingglass"
        case .tips:               return "sparkles"
        }
    }
}

// MARK: - Tactile macOS Keycap Components

public struct KeycapBadgeView: View {
    let key: String
    let isDark: Bool
    var compact: Bool = false

    public init(_ key: String, isDark: Bool, compact: Bool = false) {
        self.key = key
        self.isDark = isDark
        self.compact = compact
    }

    public var body: some View {
        Text(key)
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(AppPalette.labelPrimary(isDark))
            .padding(.horizontal, compact ? 5.5 : 7)
            .frame(minWidth: compact ? 20 : 24, minHeight: compact ? 19 : 22)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(AppPalette.keycapBackground(isDark))
                    .shadow(color: AppPalette.keycapShadow(isDark), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(AppPalette.keycapBorder(isDark), lineWidth: 1)
            )
    }
}

public struct ShortcutChordsView: View {
    let chords: [[String]]
    let isDark: Bool
    var compact: Bool = false

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chords.enumerated()), id: \.offset) { chordIdx, chord in
                if chordIdx > 0 {
                    Text("/")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppPalette.labelQuaternary(isDark))
                }
                HStack(spacing: 3) {
                    ForEach(Array(chord.enumerated()), id: \.offset) { _, token in
                        KeycapBadgeView(token, isDark: isDark, compact: compact)
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts & Tips Cheat Sheet (⌘/)

public struct ShortcutsAndTipsSheetView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    @State private var selectedCategory: ShortcutGuideCategory = .all
    @State private var filterText: String = ""
    @Namespace private var categoryNamespace

    struct ShortcutEntry: Identifiable {
        let id: String
        let category: ShortcutGuideCategory
        let icon: String
        let title: String
        let subtitle: String?
        let chords: [[String]]
    }

    public init(store: AppStore, session: ReaderWindowSession? = nil) {
        self.store = store
        self.session = session ?? store.activeSession
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            categoryStrip

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            entriesScrollArea

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            footerBar
        }
        .frame(width: 720, height: 556)
        .background(AppPalette.homeContentBackground(isDark))
        .onAppear {
            selectedCategory = session.shortcutsInitialCategory
        }
        .onExitCommand {
            if !filterText.isEmpty {
                filterText = ""
            } else {
                dismiss()
            }
        }
    }

    // MARK: Header & Search

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppPalette.accentBlue.opacity(isDark ? 0.20 : 0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppPalette.accentBlue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("快捷键与技巧", "Shortcuts & Tips"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                Text(L10n.tr("随时按 ⌘/ 打开此面板", "Press ⌘/ anytime to open this guide"))
                    .font(.system(size: 11.5))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
            }

            Spacer(minLength: 12)

            // Instant filter box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(AppPalette.labelTertiary(isDark))

                TextField(L10n.tr("筛选快捷键或功能…", "Filter shortcuts or features…"), text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(AppPalette.labelPrimary(isDark))

                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(AppPalette.labelTertiary(isDark))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 220, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppPalette.homeCardBackground(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Category Strip

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ShortcutGuideCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        withAnimation(AppAnimation.snappy) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category.iconName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(category.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundColor(isSelected ? .white : AppPalette.labelSecondary(isDark))
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(AppPalette.accentBlue)
                                    .matchedGeometryEffect(id: "shortcutCategoryPill", in: categoryNamespace)
                            } else {
                                Capsule()
                                    .fill(AppPalette.homeCardBackground(isDark))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
        .background(AppPalette.panelBackground(isDark).opacity(isDark ? 0.55 : 0.65))
    }

    // MARK: Entries List

    private var entriesScrollArea: some View {
        let groups = filteredGroups
        return ScrollView(.vertical, showsIndicators: true) {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(AppPalette.labelQuaternary(isDark))
                    Text(L10n.tr("没有匹配结果", "No Matches Found"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppPalette.labelSecondary(isDark))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.category.id) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: group.category.iconName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(AppPalette.accentBlue)
                                Text(group.category.title)
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundColor(AppPalette.labelSecondary(isDark))
                            }
                            .padding(.horizontal, 2)

                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, entry in
                                    ShortcutEntryRow(entry: entry, isDark: isDark)
                                    if idx < group.items.count - 1 {
                                        Rectangle()
                                            .fill(AppPalette.panelSeparator(isDark))
                                            .frame(height: 1)
                                            .padding(.leading, 38)
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppPalette.homeCardBackground(isDark))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(Text(group.category.title))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack {
            Button {
                let targetSessionID = session.id
                dismiss()
                DispatchQueue.main.async {
                    store.openGettingStartedGuide(in: targetSessionID)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.tr("阅读指南", "Reading Guide"))
                        .font(.system(size: 12.5, weight: .medium))
                    KeycapBadgeView("⌘?", isDark: isDark, compact: true)
                }
                .foregroundColor(AppPalette.accentBlue)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text(L10n.tr("完成", "Done"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 28)
                    .background(Capsule().fill(AppPalette.accentBlue))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(AppPalette.panelBackground(isDark).opacity(isDark ? 0.45 : 0.55))
    }

    // MARK: Catalog Data

    private var filteredGroups: [(category: ShortcutGuideCategory, items: [ShortcutEntry])] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeCategories: [ShortcutGuideCategory] = selectedCategory == .all
            ? [.tabs, .navigation, .viewAndZoom, .searchAndBookmarks, .tips]
            : [selectedCategory]

        return activeCategories.compactMap { cat in
            let items = allEntries.filter { entry in
                guard entry.category == cat else { return false }
                guard !needle.isEmpty else { return true }
                let chordString = entry.chords.map { $0.joined() }.joined(separator: " ")
                return entry.title.localizedCaseInsensitiveContains(needle)
                    || (entry.subtitle?.localizedCaseInsensitiveContains(needle) ?? false)
                    || chordString.localizedCaseInsensitiveContains(needle)
            }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    private var allEntries: [ShortcutEntry] {
        [
            // Tabs & Window
            ShortcutEntry(
                id: "new_window",
                category: .tabs,
                icon: "macwindow.badge.plus",
                title: L10n.tr("新建窗口", "New Window"),
                subtitle: nil,
                chords: [["⌘", "N"]]
            ),
            ShortcutEntry(
                id: "open",
                category: .tabs,
                icon: "folder",
                title: L10n.tr("打开 PDF 文档", "Open PDF Document"),
                subtitle: nil,
                chords: [["⌘", "O"]]
            ),
            ShortcutEntry(
                id: "new_home",
                category: .tabs,
                icon: "house",
                title: L10n.tr("新建主页标签", "New Home Tab"),
                subtitle: nil,
                chords: [["⌘", "T"]]
            ),
            ShortcutEntry(
                id: "reopen_closed",
                category: .tabs,
                icon: "arrow.uturn.backward.square",
                title: L10n.tr("重新打开关闭的标签", "Reopen Closed Tab"),
                subtitle: nil,
                chords: [["⇧", "⌘", "T"]]
            ),
            ShortcutEntry(
                id: "next_tab",
                category: .tabs,
                icon: "arrow.right.square",
                title: L10n.tr("显示下一标签", "Show Next Tab"),
                subtitle: nil,
                chords: [["⌃", "⇥"]]
            ),
            ShortcutEntry(
                id: "prev_tab",
                category: .tabs,
                icon: "arrow.left.square",
                title: L10n.tr("显示上一标签", "Show Previous Tab"),
                subtitle: nil,
                chords: [["⌃", "⇧", "⇥"]]
            ),
            ShortcutEntry(
                id: "close_tab",
                category: .tabs,
                icon: "xmark.square",
                title: "\(L10n.tr("关闭标签", "Close Tab")) / \(L10n.tr("关闭窗口", "Close Window"))",
                subtitle: nil,
                chords: [["⌘", "W"], ["⇧", "⌘", "W"]]
            ),

            // Reading & Navigation
            ShortcutEntry(
                id: "turn_page",
                category: .navigation,
                icon: "book",
                title: "\(L10n.tr("上一页", "Previous Page")) / \(L10n.tr("下一页", "Next Page"))",
                subtitle: nil,
                chords: [["←", "→"], ["⌥", "↑", "↓"], ["Space"]]
            ),
            ShortcutEntry(
                id: "first_last_page",
                category: .navigation,
                icon: "arrow.up.to.line",
                title: "\(L10n.tr("第一页", "First Page")) / \(L10n.tr("最后一页", "Last Page"))",
                subtitle: nil,
                chords: [["Home"], ["End"]]
            ),
            ShortcutEntry(
                id: "go_to_page",
                category: .navigation,
                icon: "character.textbox",
                title: L10n.tr("前往页码…", "Go to Page…"),
                subtitle: L10n.tr("输入书籍页码，或输入 (n) 跳至第 n 页", "Enter Book Page, or (n) for PDF Page n"),
                chords: [["⌥", "⌘", "G"]]
            ),
            ShortcutEntry(
                id: "history_back_forward",
                category: .navigation,
                icon: "chevron.left.forwardslash.chevron.right",
                title: "\(L10n.tr("返回", "Back")) / \(L10n.tr("前进", "Forward"))",
                subtitle: nil,
                chords: [["⌘", "["], ["⌘", "]"]]
            ),

            // View & Zoom
            ShortcutEntry(
                id: "toggle_sidebar",
                category: .viewAndZoom,
                icon: "sidebar.left",
                title: L10n.tr("显示左边面板", "Show Left Panel"),
                subtitle: nil,
                chords: [["⌘", "B"]]
            ),
            ShortcutEntry(
                id: "page_overview",
                category: .viewAndZoom,
                icon: "square.grid.2x2",
                title: L10n.tr("页面概览", "Page Overview"),
                subtitle: nil,
                chords: [["⌃", "⌘", "1"]]
            ),
            ShortcutEntry(
                id: "sidebar_tabs",
                category: .viewAndZoom,
                icon: "list.bullet.indent",
                title: "\(L10n.tr("缩略图", "Thumbnails")) / \(L10n.tr("大纲", "Outline")) / \(L10n.tr("书签", "Bookmarks"))",
                subtitle: nil,
                chords: [["⌃", "⌘", "2"], ["⌃", "⌘", "3"], ["⌃", "⌘", "4"]]
            ),
            ShortcutEntry(
                id: "page_layouts",
                category: .viewAndZoom,
                icon: "rectangle.split.2x1",
                title: "\(L10n.tr("单页", "Single Page")) / \(L10n.tr("双页", "Two Pages")) / \(L10n.tr("双页封面", "Cover"))",
                subtitle: nil,
                chords: [["⌘", "1"], ["⌘", "2"], ["⌘", "3"]]
            ),
            ShortcutEntry(
                id: "clear_margins",
                category: .viewAndZoom,
                icon: "crop",
                title: L10n.tr("清除空白边", "Clear Margins"),
                subtitle: nil,
                chords: [["⇧", "⌘", "M"]]
            ),
            ShortcutEntry(
                id: "zoom_in_out_actual",
                category: .viewAndZoom,
                icon: "plus.magnifyingglass",
                title: "\(L10n.tr("放大", "Zoom In")) / \(L10n.tr("缩小", "Zoom Out")) / \(L10n.tr("实际大小", "Actual Size"))",
                subtitle: nil,
                chords: [["⌘", "+"], ["⌘", "-"], ["⌘", "0"]]
            ),
            ShortcutEntry(
                id: "zoom_fit",
                category: .viewAndZoom,
                icon: "arrow.up.left.and.arrow.down.right",
                title: "\(L10n.tr("缩放至适应宽度", "Zoom to Fit Width")) / \(L10n.tr("缩放至适应页面", "Zoom to Fit Page"))",
                subtitle: nil,
                chords: [["⌘", "8"], ["⌘", "9"]]
            ),

            // Search & Bookmarks
            ShortcutEntry(
                id: "find",
                category: .searchAndBookmarks,
                icon: "magnifyingglass",
                title: L10n.tr("全文查找...", "Find in Document..."),
                subtitle: nil,
                chords: [["⌘", "F"]]
            ),
            ShortcutEntry(
                id: "find_next_prev",
                category: .searchAndBookmarks,
                icon: "chevron.up.chevron.down",
                title: "\(L10n.tr("查找下一个", "Find Next")) / \(L10n.tr("查找上一个", "Find Previous"))",
                subtitle: nil,
                chords: [["⌘", "G"], ["⇧", "⌘", "G"]]
            ),
            ShortcutEntry(
                id: "bookmark_page",
                category: .searchAndBookmarks,
                icon: "bookmark",
                title: L10n.tr("为当前页添加/移除书签", "Toggle Bookmark for Current Page"),
                subtitle: nil,
                chords: [["⌘", "D"]]
            ),
            ShortcutEntry(
                id: "open_shortcuts",
                category: .searchAndBookmarks,
                icon: "keyboard",
                title: L10n.tr("快捷键与技巧", "Shortcuts & Tips"),
                subtitle: nil,
                chords: [["⌘", "/"]]
            ),

            // Tips & Gestures
            ShortcutEntry(
                id: "tip_drag_tab",
                category: .tips,
                icon: "hand.draw",
                title: L10n.tr("左右拖拽标签页调整顺序", "Drag Tabs Left or Right to Reorder"),
                subtitle: nil,
                chords: [["Drag"]]
            ),
            ShortcutEntry(
                id: "tip_detach_tab",
                category: .tips,
                icon: "macwindow.badge.plus",
                title: L10n.tr(
                    "向下拖出标签页分离为独立窗口，拖回标签栏即可合并",
                    "Drag a tab out of the tab bar into a new window, or drag back to merge"
                ),
                subtitle: nil,
                chords: [["Drag"]]
            ),
            ShortcutEntry(
                id: "tip_printed_pages",
                category: .tips,
                icon: "text.book.closed",
                title: L10n.tr("输入书籍页码，或输入 (n) 跳至第 n 页", "Enter Book Page, or (n) for PDF Page n"),
                subtitle: nil,
                chords: [["⌥", "⌘", "G"]]
            ),
            ShortcutEntry(
                id: "tip_auto_resize",
                category: .tips,
                icon: "cursorarrow.click.2",
                title: L10n.tr("在页面上右键切换自动适应缩放", "Right-Click Page to Toggle Auto-Resize"),
                subtitle: nil,
                chords: [["⌘", "8"]]
            )
        ]
    }
}

private struct ShortcutEntryRow: View {
    let entry: ShortcutsAndTipsSheetView.ShortcutEntry
    let isDark: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppPalette.accentBlue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
            }

            Spacer(minLength: 12)

            ShortcutChordsView(chords: entry.chords, isDark: isDark)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHovered ? AppPalette.homeCardHover(isDark) : Color.clear)
        .accessibilityElement(children: .combine)
        .animation(AppAnimation.micro, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
