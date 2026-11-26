import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Home tab content: large page title, dashed drop area and card sections
/// for reading themes, Recents and Favorites.
public struct HomeTabRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    var isStandaloneSplitPane: Bool = false
    var onSelectDocumentInSplitPane: ((URL) -> Void)?

    @State private var isDropTargeted = false
    @State private var librarySearchText: String = ""
    @State private var librarySortOrder: LibrarySortOrder = .recent
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private enum LibrarySortOrder: String, CaseIterable, Identifiable {
        case recent
        case name
        case pageCount

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recent:    return L10n.tr("按最近打开", "Recent")
            case .name:      return L10n.tr("按名称", "Name")
            case .pageCount: return L10n.tr("按页数", "Page Count")
            }
        }
    }

    public static let sidebarWidth: CGFloat = 216
    public static let maxColumnWidth: CGFloat = 880
    public static let minimumGutter: CGFloat = 40
    public static let cardMinWidth: CGFloat = 168
    public static let cardMaxWidth: CGFloat = 210
    /// Home shows two clean 4-card rows; "查看全部" opens the full searchable library page
    public static let homeSectionItemLimit = 8

    public init(
        store: AppStore,
        session: ReaderWindowSession? = nil,
        isStandaloneSplitPane: Bool = false,
        onSelectDocumentInSplitPane: ((URL) -> Void)? = nil
    ) {
        self.store = store
        self.session = session ?? store.primarySession
        self.isStandaloneSplitPane = isStandaloneSplitPane
        self.onSelectDocumentInSplitPane = onSelectDocumentInSplitPane
    }

    public var body: some View {
        let base = pageContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.homeContentBackground(isDark), ignoresSafeAreaEdges: [])
            .onAppear {
                store.pruneMissingDocuments()
            }
            .onChange(of: session.homeCurrentPage) { _, _ in
                librarySearchText = ""
                store.pruneMissingDocuments()
            }

        // Only the split-pane document picker handles drops locally; the Home tab delegates to MainWindowView
        // so Finder drops do not hit an inner duplicate _PlatformDraggingDestinationView.
        if isStandaloneSplitPane {
            base
                .overlay {
                    if isDropTargeted {
                        DropOverlayView(isDark: isDark)
                            .padding(14)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .animation(AppAnimation.snappy, value: isDropTargeted)
                .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
        } else {
            base
        }
    }

    private var pageContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 32) {
                switch isStandaloneSplitPane ? .home : session.homeCurrentPage {
                case .home:
                    homePageSections
                        .transition(.opacity.combined(with: .offset(y: 6)))
                case .recents:
                    recentsFullPage
                        .transition(.opacity.combined(with: .offset(y: 6)))
                case .favorites:
                    favoritesFullPage
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(AppAnimation.panel, value: session.homeCurrentPage)
            .frame(maxWidth: Self.maxColumnWidth, alignment: .leading)
            .padding(.horizontal, isStandaloneSplitPane ? 24 : Self.minimumGutter)
            .padding(.top, isStandaloneSplitPane ? 22 : 34)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Home Page Sections

    private var homePageSections: some View {
        VStack(alignment: .leading, spacing: 32) {
            pageTitle(
                isStandaloneSplitPane ? L10n.tr("选择对比文档", "Select Document to Compare") : L10n.tr("主页", "Home"),
                subtitle: isStandaloneSplitPane ? L10n.tr("点击任一文档，或将 PDF 拖放到下方，在分屏中打开", "Click any document or drag a PDF below to open in split view") : nil
            )

            // Drop Area Section (HomeSection.dropArea)
            HomeDropAreaCard(isDark: isDark, isCompact: isStandaloneSplitPane, onOpenFilePicker: openFilePicker)

            // Reading Themes card row
            if !isStandaloneSplitPane {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.tr("阅读主题", "Reading Theme"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppPalette.labelPrimary(isDark))
                    HStack(spacing: 12) {
                        ForEach(PDFReadingThemeMode.allCases) { mode in
                            HomeThemeModeCard(
                                mode: mode,
                                useSepiaInLight: store.useSepiaForLightSystemTheme,
                                isSelected: store.readingThemeMode == mode,
                                isDark: isDark
                            ) {
                                withAnimation(AppAnimation.snappy) {
                                    store.readingThemeMode = mode
                                }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(L10n.tr("阅读主题", "Reading Theme")))
            }

            // Recent Documents
            documentsSection(
                title: L10n.tr("最近打开", "Recents"),
                emptyIcon: "clock",
                items: store.recentDocuments,
                actions: isStandaloneSplitPane ? [] : (
                    [HomeSectionAction(title: L10n.tr("清除全部", "Clear All"), isDestructive: true) {
                        store.confirmClearRecents(in: session.id)
                    }]
                    + (store.recentDocuments.count > Self.homeSectionItemLimit ? [
                        HomeSectionAction(title: L10n.tr("查看全部", "See All"), trailingIcon: "chevron.right") {
                            withAnimation(AppAnimation.panel) {
                                session.homeCurrentPage = .recents
                            }
                        }
                    ] : [])
                ),
                allowsRemoval: true,
                emptyText: L10n.tr("打开过的 PDF 会显示在这里，方便随时继续阅读。", "Recently opened PDFs will appear here so you can pick up where you left off.")
            )

            // Favorites
            documentsSection(
                title: L10n.tr("收藏夹", "Favorites"),
                emptyIcon: "star",
                items: store.favoriteDocuments,
                actions: isStandaloneSplitPane || store.favoriteDocuments.count <= Self.homeSectionItemLimit ? [] : [
                    HomeSectionAction(title: L10n.tr("查看全部", "See All"), trailingIcon: "chevron.right") {
                        withAnimation(AppAnimation.panel) {
                            session.homeCurrentPage = .favorites
                        }
                    }
                ],
                allowsRemoval: false,
                emptyText: L10n.tr("将鼠标悬停在文档上并点按星标，即可加入收藏夹。", "Hover over a document and click the star to add it to Favorites.")
            )
        }
    }

    private func documentsSection(
        title: String,
        emptyIcon: String,
        items: [DocumentItem],
        actions: [HomeSectionAction],
        allowsRemoval: Bool,
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(
                title: title,
                count: items.count,
                actions: items.isEmpty ? [] : actions,
                isDark: isDark
            )

            if items.isEmpty {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppPalette.segmentedTrack(isDark))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: emptyIcon)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(AppPalette.labelTertiary(isDark))
                        )
                    Text(emptyText)
                        .font(.system(size: 12.5))
                        .foregroundColor(AppPalette.labelSecondary(isDark))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppPalette.homeCardBackground(isDark))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 0.5)
                )
            } else {
                documentsGrid(Array(items.prefix(Self.homeSectionItemLimit)), allowsRemoval: allowsRemoval)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    // MARK: - Recents Full Page

    private var recentsFullPage: some View {
        let filtered = filteredAndSortedDocuments(from: store.recentDocuments)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                pageTitle(L10n.tr("最近打开", "Recents"))
                Spacer()
                if !store.recentDocuments.isEmpty {
                    libraryToolbar(
                        destructiveTitle: L10n.tr("清除全部", "Clear All"),
                        onDestructive: { store.confirmClearRecents(in: session.id) }
                    )
                }
            }

            if store.recentDocuments.isEmpty {
                HomeEmptyStateView(
                    icon: "clock",
                    title: L10n.tr("暂无最近打开的 PDF 文档", "No Recent PDF Documents"),
                    subtitle: L10n.tr("打开过的文件会自动显示在这里，方便随时继续阅读。", "Opened files will appear here automatically so you can continue reading anytime."),
                    actionTitle: L10n.tr("打开文件", "Open File"),
                    isDark: isDark,
                    action: { store.openFilePicker(in: session.id) }
                )
            } else if filtered.isEmpty {
                noMatchesState
            } else {
                documentsGrid(filtered, allowsRemoval: true)
            }
        }
    }

    // MARK: - Favorites Full Page

    private var favoritesFullPage: some View {
        let filtered = filteredAndSortedDocuments(from: store.favoriteDocuments)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                pageTitle(L10n.tr("收藏夹", "Favorites"))
                Spacer()
                if !store.favoriteDocuments.isEmpty {
                    libraryToolbar(
                        destructiveTitle: L10n.tr("清空收藏夹", "Clear Favorites"),
                        onDestructive: { store.confirmClearFavorites(in: session.id) }
                    )
                }
            }

            if store.favoriteDocuments.isEmpty {
                HomeEmptyStateView(
                    icon: "star",
                    title: L10n.tr("收藏夹为空", "Favorites is Empty"),
                    subtitle: L10n.tr("将鼠标悬停在任意文档上并点按星标，即可将其加入收藏夹。", "Hover over any document and click the star to add it to Favorites."),
                    actionTitle: L10n.tr("返回主页", "Back to Home"),
                    isDark: isDark,
                    action: {
                        withAnimation(AppAnimation.panel) {
                            session.homeCurrentPage = .home
                        }
                    }
                )
            } else if filtered.isEmpty {
                noMatchesState
            } else {
                documentsGrid(filtered, allowsRemoval: false)
            }
        }
    }

    private func filteredAndSortedDocuments(from source: [DocumentItem]) -> [DocumentItem] {
        let query = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? source : source.filter { $0.title.localizedCaseInsensitiveContains(query) }
        switch librarySortOrder {
        case .recent:
            return filtered
        case .name:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .pageCount:
            return filtered.sorted {
                if $0.pageCount != $1.pageCount { return $0.pageCount > $1.pageCount }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    private func libraryToolbar(destructiveTitle: String, onDestructive: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                TextField(L10n.tr("搜索文档…", "Filter documents…"), text: $librarySearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if !librarySearchText.isEmpty {
                    Button {
                        librarySearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppPalette.labelQuaternary(isDark))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 200, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppPalette.homeCardBackground(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 0.5)
            )

            Menu {
                ForEach(LibrarySortOrder.allCases) { order in
                    Button {
                        librarySortOrder = order
                    } label: {
                        if librarySortOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(librarySortOrder.title)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppPalette.homeCardBackground(isDark))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            HomeSubtleActionButton(
                title: destructiveTitle,
                isDestructive: true,
                isDark: isDark,
                action: onDestructive
            )
        }
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(AppPalette.labelQuaternary(isDark))
            Text(L10n.tr("没有匹配结果", "No Matches Found"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(AppPalette.labelSecondary(isDark))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: - Shared Pieces

    private func pageTitle(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: isStandaloneSplitPane ? 22 : 28, weight: .bold))
                .foregroundColor(AppPalette.labelPrimary(isDark))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundColor(AppPalette.labelSecondary(isDark))
            }
        }
    }

    private func documentsGrid(_ items: [DocumentItem], allowsRemoval: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.cardMinWidth, maximum: Self.cardMaxWidth), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(items) { item in
                DocumentCardView(
                    item: item,
                    progressBadge: store.savedReadingPageLabel(for: item),
                    pdfTheme: store.resolvedPDFTheme(isDark: isDark),
                    isDark: isDark,
                    onOpen: { openURL(item.url) },
                    onToggleFavorite: { store.toggleFavorite(id: item.documentID) },
                    onShowInFinder: { store.showInFinder(id: item.documentID) },
                    onRemoveRecent: allowsRemoval ? { store.removeFromRecents(id: item.documentID) } : nil
                )
            }
        }
    }

    private func openFilePicker() {
        if let splitHandler = onSelectDocumentInSplitPane {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                splitHandler(url)
            }
        } else {
            store.openFilePicker(in: session.id)
        }
    }

    private func openURL(_ url: URL) {
        if let splitHandler = onSelectDocumentInSplitPane {
            splitHandler(url)
        } else {
            store.openDocument(at: url, in: session.id)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        PDFFileDrop.open(providers) { url in
            openURL(url)
        }
    }
}

// MARK: - PDFFileDrop (shared by the Home tab and the main window)

enum PDFFileDrop {
    static func resolvedPDFURL(from item: Any?) -> URL? {
        let rawURL: URL?
        if let url = item as? URL {
            rawURL = url
        } else if let data = item as? Data {
            rawURL = URL(dataRepresentation: data, relativeTo: nil)
                ?? String(data: data, encoding: .utf8)
                    .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else if let text = item as? String {
            rawURL = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            rawURL = nil
        }
        guard let rawURL, rawURL.isFileURL else { return nil }
        let url = ((rawURL as NSURL).filePathURL ?? rawURL).standardizedFileURL
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        return url
    }

    /// Hands every dropped PDF file URL or file-link URL to `open` on the main actor.
    static func open(_ providers: [NSItemProvider], with open: @escaping @MainActor (URL) -> Void) -> Bool {
        let supportedTypes = [UTType.fileURL.identifier, UTType.url.identifier]
        var handled = false
        for provider in providers {
            guard let matchedType = supportedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                continue
            }
            handled = true
            provider.loadItem(forTypeIdentifier: matchedType, options: nil) { item, _ in
                guard let url = resolvedPDFURL(from: item) else { return }
                Task { @MainActor in
                    open(url)
                }
            }
        }
        return handled
    }
}

// MARK: - HomeTabSidebarView

struct HomeTabSidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccentColor) private var accent
    @Namespace private var sidebarNamespace
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Navigation Pages (Home / Recents / Favorites)
            ForEach(HomeTabPage.allCases) { page in
                Button {
                    withAnimation(AppAnimation.snappy) {
                        session.homeCurrentPage = page
                    }
                } label: {
                    HomeSidebarRowLabel(
                        icon: "\(page.iconName).fill",
                        iconColor: session.homeCurrentPage == page ? accent : AppPalette.labelSecondary(isDark),
                        title: page.title,
                        badge: badge(for: page),
                        isSelected: session.homeCurrentPage == page,
                        selectionNamespace: sidebarNamespace,
                        isDark: isDark
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 16)

            // Footer actions (PDF Expert: Account Details / Settings / Get Support)
            Button {
                store.openFilePicker(in: session.id)
            } label: {
                HomeSidebarRowLabel(icon: "folder", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("打开文件…", "Open File…"), badge: "⌘O", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            Button {
                store.presentShortcutsSheet(in: session.id)
            } label: {
                HomeSidebarRowLabel(icon: "keyboard", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("快捷键与技巧", "Shortcuts & Tips"), badge: "⌘/", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            Button {
                store.openGettingStartedGuide(in: session.id)
            } label: {
                HomeSidebarRowLabel(icon: "questionmark.circle", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("阅读指南", "Reading Guide"), badge: "⌘?", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            SettingsLink {
                HomeSidebarRowLabel(icon: "gearshape", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("设置", "Settings"), badge: "⌘,", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(AppPalette.homeSidebarBackground(isDark), ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("主页导航栏", "Home Sidebar")))
    }

    private func badge(for page: HomeTabPage) -> String? {
        switch page {
        case .home:
            return nil
        case .recents:
            return store.recentDocuments.isEmpty ? nil : "\(store.recentDocuments.count)"
        case .favorites:
            return store.favoriteDocuments.isEmpty ? nil : "\(store.favoriteDocuments.count)"
        }
    }
}

struct HomeSidebarRowLabel: View {
    let icon: String
    let iconColor: Color
    let title: String
    var badge: String?
    var isSelected: Bool = false
    var isSecondary: Bool = false
    var selectionNamespace: Namespace.ID?
    let isDark: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: isSecondary ? 13 : 15, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 22)
            Text(title)
                .font(.system(size: isSecondary ? 13 : 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSecondary ? AppPalette.labelSecondary(isDark) : AppPalette.labelPrimary(isDark))
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(AppAnimation.micro, value: badge)
                    .foregroundColor(AppPalette.labelTertiary(isDark))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: isSecondary ? 34 : 38)
        .background {
            if isSelected, let selectionNamespace {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppPalette.homeSidebarSelection(isDark))
                    .matchedGeometryEffect(id: "homeSidebarSelection", in: selectionNamespace)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? AppPalette.homeSidebarSelection(isDark)
                            : (isHovered ? AppPalette.homeSidebarSelection(isDark).opacity(0.55) : Color.clear)
                    )
            }
        }
        .contentShape(Rectangle())
        .animation(AppAnimation.micro, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Section Header & Links

struct HomeSectionAction: Identifiable {
    let title: String
    var trailingIcon: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void
    var id: String { title }
}

struct HomeSectionHeader: View {
    let title: String
    var count: Int = 0
    var actions: [HomeSectionAction] = []
    let isDark: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(actions) { item in
                    HomeSubtleActionButton(
                        title: item.title,
                        trailingIcon: item.trailingIcon,
                        isDestructive: item.isDestructive,
                        isDark: isDark,
                        action: item.action
                    )
                }
            }
        }
    }
}

struct HomeSubtleActionButton: View {
    let title: String
    var trailingIcon: String? = nil
    var isDestructive: Bool = false
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 9.5, weight: .semibold))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(
                isHovered
                    ? (isDestructive ? AppPalette.systemRed : AppPalette.labelPrimary(isDark))
                    : AppPalette.labelSecondary(isDark)
            )
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? AppPalette.homeCardHover(isDark) : AppPalette.homeCardBackground(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(TactilePressButtonStyle())
        .onHover { isHovered = $0 }
    }
}

struct HomePrimaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(Capsule().fill(accent.opacity(isHovered ? 0.88 : 1)))
                .animation(AppAnimation.micro, value: isHovered)
                .contentShape(Capsule())
        }
        .buttonStyle(TactilePressButtonStyle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - HomeDropAreaCard

struct HomeDropAreaCard: View {
    let isDark: Bool
    var isCompact: Bool = false
    let onOpenFilePicker: () -> Void

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false

    private var cardBackground: some View {
        let fillOpacity: Double = isDark ? (isHovered ? 0.13 : 0.10) : (isHovered ? 0.07 : 0.05)
        let outerStrokeOpacity: Double = isDark ? 0.22 : 0.13
        let dashOpacity: Double = isHovered ? 0.75 : 0.42
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(accent.opacity(fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(outerStrokeOpacity), lineWidth: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        accent.opacity(dashOpacity),
                        style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
                    )
                    .padding(6)
            )
    }

    var body: some View {
        VStack(spacing: 12) {
            PDFStackIllustration(isDark: isDark)
                .frame(width: 104, height: 62)
                .scaleEffect(isHovered ? 1.04 : 1.0)
                .offset(y: isHovered ? -2 : 0)
                .accessibilityHidden(true)

            HomePrimaryButton(title: L10n.tr("打开文件", "Open File"), action: onOpenFilePicker)
                .accessibilityHidden(true)

            Text(L10n.tr("或将 PDF 文件拖放到此处", "or drag and drop PDF files here"))
                .font(.system(size: 12.5))
                .foregroundColor(accent.opacity(0.85))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? 176 : 196)
        .background(cardBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("打开文件", "Open File")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpenFilePicker)
        .animation(AppAnimation.snappy, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpenFilePicker)
    }
}

/// Three fanned pages with a "PDF" label, drawn with shapes.
struct PDFStackIllustration: View {
    let isDark: Bool

    @Environment(\.appAccentColor) private var accent

    var body: some View {
        ZStack {
            paper(showsLines: true)
                .rotationEffect(.degrees(-12))
                .offset(x: -24, y: 4)
            paper(showsLines: true)
                .rotationEffect(.degrees(12))
                .offset(x: 24, y: 4)
            paper(showsLines: false)
                .overlay(
                    Text("PDF")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(accent.opacity(0.75))
                        .offset(y: 9)
                )
        }
    }

    private func paper(showsLines: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isDark ? Color(hex: 0x2C2C30) : Color.white)
            .frame(width: 42, height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(accent.opacity(0.28), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if showsLines {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<4, id: \.self) { line in
                            Capsule()
                                .fill(accent.opacity(0.25))
                                .frame(width: line == 3 ? 14 : 24, height: 2)
                        }
                    }
                    .padding(8)
                }
            }
            .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.08), radius: 3, x: 0, y: 1)
    }
}

// MARK: - HomeThemeModeCard (Follow System / Day / Sepia / Night)

struct HomeThemeModeCard: View {
    let mode: PDFReadingThemeMode
    let useSepiaInLight: Bool
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false

    var body: some View {
        let previewTheme = mode.resolvedTheme(isDark: isDark, useSepiaInLight: useSepiaInLight)
        let lightPreviewTheme: PDFViewTheme = useSepiaInLight ? .sepia : .day

        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    if mode == .system {
                        HStack(spacing: 0) {
                            lightPreviewTheme.documentBackgroundColor(isDarkUI: false)
                            PDFViewTheme.night.documentBackgroundColor(isDarkUI: true)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        SplitMiniPagePreview(leftTheme: lightPreviewTheme, rightTheme: .night)
                            .frame(width: 36, height: 46)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(previewTheme.documentBackgroundColor(isDarkUI: isDark))
                        MiniPagePreview(theme: previewTheme)
                            .frame(width: 36, height: 46)
                    }
                }
                .frame(height: 66)

                HStack(spacing: 6) {
                    Image(systemName: mode.toolbarIconName)
                        .font(.system(size: 12, weight: .medium))
                    Text(mode.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(accent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .padding(.horizontal, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? AppPalette.homeCardHover(isDark) : AppPalette.homeCardBackground(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
            )
            .offset(y: isHovered ? -1.5 : 0)
            .shadow(color: Color.black.opacity(isHovered ? (isDark ? 0.30 : 0.08) : 0), radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
            .animation(AppAnimation.snappy, value: isHovered)
            .animation(AppAnimation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(mode.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .help("\(L10n.tr("阅读主题", "Reading Theme")): \(mode.title)")
        .onHover { isHovered = $0 }
    }
}

// MARK: - DocumentCardView (DocumentItemView)

struct DocumentCardView: View {
    let item: DocumentItem
    let progressBadge: String?
    let pdfTheme: PDFViewTheme
    let isDark: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onShowInFinder: () -> Void
    let onRemoveRecent: (() -> Void)?

    @State private var isHovered = false
    @State private var filenameAnchor = NSViewAnchor()
    @State private var filenamePreview = DocumentFilePreview()

    /// The page count is read in the background and stays `0` until then
    private var subtitleText: String {
        let parts = [item.pageCount > 0 ? L10n.pageCountText(item.pageCount) : "", item.dateOpenedText]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if isHovered || item.isFavorite {
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.bounce, value: item.isFavorite)
                    .foregroundColor(item.isFavorite ? AppPalette.systemYellow : AppPalette.labelSecondary(isDark))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.90))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? L10n.tr("取消收藏", "Remove from Favorites") : L10n.tr("添加到收藏", "Add to Favorites"))
            .padding(6)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private var coverThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.28) : Color(hex: 0xEAEAEF))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(isDark ? 0.22 : 0.04), lineWidth: 0.5)

            Image(nsImage: PDFThumbnailCache.shared.themedCover(for: item, theme: pdfTheme))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
                .frame(maxWidth: 98, maxHeight: 126)
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(isDark ? 0.35 : 0.12), lineWidth: 0.5)
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .shadow(
                    color: Color.black.opacity(isDark ? 0.45 : 0.14),
                    radius: isHovered ? 5 : 3,
                    x: 0,
                    y: isHovered ? 2.5 : 1.5
                )
        }
        .frame(height: 148)
        .overlay(alignment: .topTrailing) {
            favoriteBadge
        }
        .overlay(alignment: .bottomLeading) {
            if let progressBadge {
                Text(progressBadge)
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(isDark ? 0.58 : 0.55)))
                    .padding(6)
            }
        }
    }

    private var titleLabels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 32, alignment: .topLeading)

            Text(subtitleText)
                .font(.system(size: 11))
                .foregroundColor(AppPalette.labelTertiary(isDark))
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ViewAnchorRepresentable(anchor: filenameAnchor).allowsHitTesting(false))
        .onHover { hovering in
            if hovering { filenamePreview.show(item.url, near: filenameAnchor, isDark: isDark) }
            else { filenamePreview.hide() }
        }
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            coverThumbnail
            titleLabels
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? AppPalette.homeCardHover(isDark) : AppPalette.homeCardBackground(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .offset(y: isHovered ? -1.5 : 0)
        .shadow(
            color: Color.black.opacity(isHovered ? (isDark ? 0.28 : 0.07) : 0),
            radius: 6,
            x: 0,
            y: 3
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
        .animation(AppAnimation.snappy, value: isHovered)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .onHover { isHovered = $0 }
        .onDisappear { filenamePreview.hide() }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(L10n.tr("阅读文档", "Read Document")) { onOpen() }
            Button(item.isFavorite ? L10n.tr("取消收藏", "Remove from Favorites") : L10n.tr("添加到收藏", "Add to Favorites")) { onToggleFavorite() }
            Divider()
            Button(L10n.tr("在 Finder 中显示", "Show in Finder")) { onShowInFinder() }
            if let remove = onRemoveRecent {
                Divider()
                Button(L10n.tr("从最近打开中移除", "Remove from Recents"), role: .destructive) { remove() }
            }
        }
    }
}

// MARK: - HomeEmptyStateView & DropOverlayView

struct HomeEmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(AppPalette.labelQuaternary(isDark))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppPalette.labelPrimary(isDark))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HomePrimaryButton(title: actionTitle, action: action)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

struct DropOverlayView: View {
    let isDark: Bool

    @Environment(\.appAccentColor) private var accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accent.opacity(0.10))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundColor(accent)
                Text(L10n.tr("松开鼠标即可打开 PDF", "Release to open PDF"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}
