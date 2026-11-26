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

    @AppStorage("expertPDFReader.libraryViewMode") private var libraryViewModeRaw: String = LibraryViewMode.grid.rawValue
    @State private var isDropTargeted = false
    @State private var librarySearchText: String = ""
    @State private var librarySortOrder: LibrarySortOrder = .recent
    @State private var sortAnchor = NSViewAnchor()
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private enum LibraryViewMode: String, CaseIterable, Identifiable {
        case grid
        case list

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }

        var tooltip: String {
            switch self {
            case .grid: return L10n.tr("网格视图", "Grid View")
            case .list: return L10n.tr("列表视图", "List View")
            }
        }
    }

    private var libraryViewMode: LibraryViewMode {
        LibraryViewMode(rawValue: libraryViewModeRaw) ?? .grid
    }

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
    public static let cardMinWidth: CGFloat = 158
    public static let cardMaxWidth: CGFloat = 196
    /// Home shows two clean rows; "See All" opens the full searchable library page
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
        VStack(alignment: .leading, spacing: 30) {
            pageTitle(
                isStandaloneSplitPane ? L10n.tr("选择对比文档", "Select Document to Compare") : L10n.tr("主页", "Home"),
                subtitle: isStandaloneSplitPane ? L10n.tr("点击任一文档，或将 PDF 拖放到下方，在分屏中打开", "Click any document or drag a PDF below to open in split view") : nil
            )

            // Drop Area Section (HomeSection.dropArea)
            HomeDropAreaCard(isDark: isDark, isCompact: isStandaloneSplitPane, onOpenFilePicker: openFilePicker)

            // Recent Documents
            documentsSection(
                title: L10n.tr("最近打开", "Recents"),
                emptyIcon: "clock",
                items: store.recentDocuments,
                actions: isStandaloneSplitPane ? [] : [
                    HomeSectionAction(title: L10n.tr("查看全部", "See All"), trailingIcon: "chevron.right") {
                        withAnimation(AppAnimation.panel) {
                            session.homeCurrentPage = .recents
                        }
                    }
                ],
                allowsRemoval: true,
                emptyText: L10n.tr("打开过的 PDF 会显示在这里，方便随时继续阅读。", "Recently opened PDFs will appear here so you can pick up where you left off.")
            )

            // Favorites
            documentsSection(
                title: L10n.tr("收藏夹", "Favorites"),
                emptyIcon: "star",
                items: store.favoriteDocuments,
                actions: isStandaloneSplitPane ? [] : [
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
                        .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
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
                        .fill(isDark ? Color(hex: 0x1D1E22) : Color(hex: 0xF7F8FA))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.055), lineWidth: 0.75)
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
        return VStack(alignment: .leading, spacing: 22) {
            libraryHeaderRow(
                title: L10n.tr("最近打开", "Recents"),
                count: store.recentDocuments.count,
                showsControls: !store.recentDocuments.isEmpty,
                destructiveTitle: L10n.tr("清除全部", "Clear All"),
                onDestructive: { store.confirmClearRecents(in: session.id) }
            )

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
            } else if libraryViewMode == .list {
                documentsList(filtered, allowsRemoval: true)
            } else {
                documentsGrid(filtered, allowsRemoval: true)
            }
        }
    }

    // MARK: - Favorites Full Page

    private var favoritesFullPage: some View {
        let filtered = filteredAndSortedDocuments(from: store.favoriteDocuments)
        return VStack(alignment: .leading, spacing: 22) {
            libraryHeaderRow(
                title: L10n.tr("收藏夹", "Favorites"),
                count: store.favoriteDocuments.count,
                showsControls: !store.favoriteDocuments.isEmpty,
                destructiveTitle: L10n.tr("清空收藏夹", "Clear Favorites"),
                onDestructive: { store.confirmClearFavorites(in: session.id) }
            )

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
            } else if libraryViewMode == .list {
                documentsList(filtered, allowsRemoval: false)
            } else {
                documentsGrid(filtered, allowsRemoval: false)
            }
        }
    }

    private func libraryHeaderRow(
        title: String,
        count: Int,
        showsControls: Bool,
        destructiveTitle: String,
        onDestructive: @escaping () -> Void
    ) -> some View {
        let titleBadge = HStack(alignment: .firstTextBaseline, spacing: 9) {
            pageTitle(title)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.055))
                    )
            }
        }
        .fixedSize(horizontal: true, vertical: false)

        return Group {
            if showsControls {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        titleBadge
                        Spacer(minLength: 12)
                        libraryToolbar(destructiveTitle: destructiveTitle, onDestructive: onDestructive)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        titleBadge
                        libraryToolbar(destructiveTitle: destructiveTitle, onDestructive: onDestructive)
                    }
                }
            } else {
                titleBadge
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

    private var controlSurfaceFill: Color {
        isDark ? Color(hex: 0x222327) : Color(hex: 0xF4F5F7)
    }

    private var controlSurfaceBorder: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    private func libraryToolbar(destructiveTitle: String, onDestructive: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
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
            .frame(minWidth: 140, idealWidth: 180, maxWidth: 204, minHeight: 30, maxHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(controlSurfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(controlSurfaceBorder, lineWidth: 1)
            )

            // View Mode Switch (Grid / List)
            HStack(spacing: 2) {
                ForEach(LibraryViewMode.allCases) { mode in
                    let isSelected = (libraryViewMode == mode)
                    Button {
                        withAnimation(AppAnimation.snappy) {
                            libraryViewModeRaw = mode.rawValue
                        }
                    } label: {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelTertiary(isDark))
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? AppPalette.segmentedThumb(isDark) : Color.clear)
                                    .shadow(
                                        color: isSelected ? Color.black.opacity(isDark ? 0.30 : 0.08) : .clear,
                                        radius: 1.5,
                                        x: 0,
                                        y: 0.5
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(mode.tooltip)
                    .accessibilityLabel(Text(mode.tooltip))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2.5)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(controlSurfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(controlSurfaceBorder, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)

            // Sort Pop-Up Button
            Button {
                let items = LibrarySortOrder.allCases.map { order in
                    NativeMenuItem.action(order.title, isChecked: librarySortOrder == order) {
                        withAnimation(AppAnimation.snappy) {
                            librarySortOrder = order
                        }
                    }
                }
                NativeMenu.popUp(items, below: sortAnchor.view)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                    Text(librarySortOrder.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(controlSurfaceFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(controlSurfaceBorder, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(TactilePressButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .background(ViewAnchorRepresentable(anchor: sortAnchor).allowsHitTesting(false))

            HomeSubtleActionButton(
                title: destructiveTitle,
                leadingIcon: "trash",
                isDestructive: true,
                height: 30,
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
            columns: [GridItem(.adaptive(minimum: Self.cardMinWidth, maximum: Self.cardMaxWidth), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(items) { item in
                let readingProgress = store.inProgressReadingState(for: item)
                DocumentCardView(
                    item: item,
                    progressLabel: readingProgress?.label,
                    progressFraction: readingProgress?.fraction,
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

    private func documentsList(_ items: [DocumentItem], allowsRemoval: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let readingProgress = store.inProgressReadingState(for: item)
                DocumentListRowView(
                    item: item,
                    progressLabel: readingProgress?.label,
                    pdfTheme: store.resolvedPDFTheme(isDark: isDark),
                    isDark: isDark,
                    onOpen: { openURL(item.url) },
                    onToggleFavorite: { store.toggleFavorite(id: item.documentID) },
                    onShowInFinder: { store.showInFinder(id: item.documentID) },
                    onRemoveRecent: allowsRemoval ? { store.removeFromRecents(id: item.documentID) } : nil
                )
                if index < items.count - 1 {
                    Rectangle()
                        .fill(AppPalette.panelSeparator(isDark))
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDark ? Color(hex: 0x1D1E22) : Color(hex: 0xFAFBFD))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.065), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text(L10n.tr("文库", "Library"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppPalette.labelTertiary(isDark))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            // Navigation Pages (Home / Recents / Favorites)
            ForEach(HomeTabPage.allCases) { page in
                let isSelected = (session.homeCurrentPage == page)
                Button {
                    withAnimation(AppAnimation.snappy) {
                        session.homeCurrentPage = page
                    }
                } label: {
                    HomeSidebarRowLabel(
                        icon: isSelected ? "\(page.iconName).fill" : page.iconName,
                        iconColor: isSelected ? accent : AppPalette.labelSecondary(isDark),
                        title: page.title,
                        badge: badge(for: page),
                        isSelected: isSelected,
                        selectionNamespace: sidebarNamespace,
                        isDark: isDark
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 16)

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark).opacity(0.8))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            // Footer actions
            Button {
                store.openFilePicker(in: session.id)
            } label: {
                HomeSidebarRowLabel(icon: "folder", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("打开文件…", "Open File…"), keycapBadge: "⌘O", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            Button {
                store.presentShortcutsSheet(in: session.id)
            } label: {
                HomeSidebarRowLabel(icon: "keyboard", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("快捷键与技巧", "Shortcuts & Tips"), keycapBadge: "⌘/", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            Button {
                store.openGettingStartedGuide(in: session.id)
            } label: {
                HomeSidebarRowLabel(icon: "questionmark.circle", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("阅读指南", "Reading Guide"), keycapBadge: "⌘?", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            SettingsLink {
                HomeSidebarRowLabel(icon: "gearshape", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("设置", "Settings"), keycapBadge: "⌘,", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
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
    var badge: String? = nil
    var keycapBadge: String? = nil
    var isSelected: Bool = false
    var isSecondary: Bool = false
    var selectionNamespace: Namespace.ID?
    let isDark: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSecondary ? AppPalette.labelSecondary(isDark) : AppPalette.labelPrimary(isDark))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(AppAnimation.micro, value: badge)
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    )
            } else if let keycapBadge {
                Text(keycapBadge)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppPalette.keycapBackground(isDark).opacity(isDark ? 0.65 : 0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(AppPalette.keycapBorder(isDark).opacity(0.6), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background {
            if isSelected, let selectionNamespace {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppPalette.homeSidebarSelection(isDark))
                    .matchedGeometryEffect(id: "homeSidebarSelection", in: selectionNamespace)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
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
    var leadingIcon: String? = nil
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
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.055))
                        )
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(actions) { item in
                    HomeSubtleActionButton(
                        title: item.title,
                        leadingIcon: item.leadingIcon,
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
    var leadingIcon: String? = nil
    var trailingIcon: String? = nil
    var isDestructive: Bool = false
    var height: CGFloat = 26
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var fillColor: Color {
        if isHovered && isDestructive {
            return AppPalette.systemRed.opacity(isDark ? 0.14 : 0.08)
        }
        if isHovered {
            return isDark ? Color(hex: 0x2B2C32) : Color(hex: 0xECEEF2)
        }
        return isDark ? Color(hex: 0x222327) : Color(hex: 0xF4F5F7)
    }

    private var borderColor: Color {
        if isHovered && isDestructive {
            return AppPalette.systemRed.opacity(isDark ? 0.40 : 0.25)
        }
        return isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 10.5, weight: .medium))
                }
                Text(title)
                    .lineLimit(1)
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
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: height >= 28 ? 8 : 7, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: height >= 28 ? 8 : 7, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: height >= 28 ? 8 : 7, style: .continuous))
            .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(TactilePressButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
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
        .fixedSize(horizontal: true, vertical: false)
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
        let surface = isDark
            ? Color.white.opacity(isHovered ? 0.055 : 0.03)
            : Color(hex: isHovered ? 0xEEF2FA : 0xF5F7FA)
        let strokeColor = isHovered
            ? accent.opacity(0.65)
            : (isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12))
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                    )
            )
    }

    var body: some View {
        VStack(spacing: 11) {
            PDFStackIllustration(isDark: isDark)
                .frame(width: 100, height: 58)
                .scaleEffect(isHovered ? 1.04 : 1.0)
                .offset(y: isHovered ? -2 : 0)
                .accessibilityHidden(true)

            HomePrimaryButton(title: L10n.tr("打开文件", "Open File"), action: onOpenFilePicker)
                .accessibilityHidden(true)

            Text(L10n.tr("或将 PDF 文件拖放到此处", "or drag and drop PDF files here"))
                .font(.system(size: 12))
                .foregroundColor(isHovered ? accent : AppPalette.labelSecondary(isDark))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? 160 : 176)
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
                        .foregroundColor(accent.opacity(0.8))
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

// MARK: - DocumentCardView (Single-Pedestal Apple Books Style)

struct DocumentCardView: View {
    let item: DocumentItem
    let progressLabel: String?
    let progressFraction: Double?
    let pdfTheme: PDFViewTheme
    let isDark: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onShowInFinder: () -> Void
    let onRemoveRecent: (() -> Void)?

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false
    @State private var filenameAnchor = NSViewAnchor()
    @State private var filenamePreview = DocumentFilePreview()

    /// The page count is read in the background and stays `0` until then.
    private var subtitleText: String {
        let countOrProgress = progressLabel ?? (item.pageCount > 0 ? L10n.pageCountText(item.pageCount) : "")
        let parts = [countOrProgress, item.dateOpenedText]
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
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(isDark ? Color(hex: 0x2C2D33, alpha: 0.90) : Color.white.opacity(0.92))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.30 : 0.08), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? L10n.tr("取消收藏", "Remove from Favorites") : L10n.tr("添加到收藏", "Add to Favorites"))
            .padding(8)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private var coverPedestal: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDark
                      ? Color(hex: isHovered ? 0x26272C : 0x1F2024)
                      : Color(hex: isHovered ? 0xECEEF3 : 0xF3F4F7))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDark
                        ? Color.white.opacity(isHovered ? 0.12 : 0.07)
                        : Color.black.opacity(isHovered ? 0.09 : 0.05),
                    lineWidth: 1
                )

            Image(nsImage: PDFThumbnailCache.shared.themedCover(for: item, theme: pdfTheme))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
                .frame(maxWidth: 108, maxHeight: 140)
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(isDark ? 0.40 : 0.10), lineWidth: 0.5)
                )
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(isDark ? 0.10 : 0.45))
                        .frame(width: 1.5)
                }
                .scaleEffect(isHovered ? 1.025 : 1.0)
                .offset(y: isHovered ? -2 : 0)
                .shadow(
                    color: Color.black.opacity(isDark ? 0.50 : (isHovered ? 0.16 : 0.11)),
                    radius: isHovered ? 9 : 5,
                    x: 0,
                    y: isHovered ? 5 : 2.5
                )
        }
        .frame(height: 166)
        .overlay(alignment: .topTrailing) {
            favoriteBadge
        }
        .overlay(alignment: .bottomLeading) {
            if let fraction = progressFraction, fraction > 0 && fraction < 1 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                        Rectangle()
                            .fill(accent)
                            .frame(width: max(6, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleLabels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Text(subtitleText)
                .font(.system(size: 11.5))
                .monospacedDigit()
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
        VStack(alignment: .leading, spacing: 8) {
            coverPedestal
            titleLabels
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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

// MARK: - DocumentListRowView (List Mode Row)

struct DocumentListRowView: View {
    let item: DocumentItem
    let progressLabel: String?
    let pdfTheme: PDFViewTheme
    let isDark: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onShowInFinder: () -> Void
    let onRemoveRecent: (() -> Void)?

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false

    private var metaText: String {
        let countText = item.pageCount > 0 ? L10n.pageCountText(item.pageCount) : ""
        return [countText, item.fileSizeText].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: PDFThumbnailCache.shared.themedCover(for: item, theme: pdfTheme))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 40)
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(isDark ? 0.35 : 0.10), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.08), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !metaText.isEmpty {
                    Text(metaText)
                        .font(.system(size: 11.5))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let progressLabel {
                Text(progressLabel)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(accent.opacity(isDark ? 0.16 : 0.10))
                    )
            }

            if !item.dateOpenedText.isEmpty {
                Text(item.dateOpenedText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(AppPalette.labelTertiary(isDark))
            }

            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .medium))
                    .symbolEffect(.bounce, value: item.isFavorite)
                    .foregroundColor(item.isFavorite ? AppPalette.systemYellow : AppPalette.labelQuaternary(isDark))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(item.isFavorite || isHovered ? 1 : 0.45)
            .help(item.isFavorite ? L10n.tr("取消收藏", "Remove from Favorites") : L10n.tr("添加到收藏", "Add to Favorites"))
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(isHovered ? AppPalette.rowHover(isDark) : Color.clear)
        .contentShape(Rectangle())
        .animation(AppAnimation.micro, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
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
        .padding(.vertical, 56)
    }
}

struct DropOverlayView: View {
    let isDark: Bool
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.84))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(accent)
                Text(L10n.tr("松开鼠标即可打开 PDF", "Release to open PDF"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
            }
        }
    }
}
