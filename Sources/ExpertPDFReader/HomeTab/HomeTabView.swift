import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Home tab, laid out like PDF Expert 3's Home: opaque `216pt` sidebar, large page title, dashed drop
/// area and card sections (reading themes, Recents, Favorites).
public struct HomeTabRootView: View {
    @ObservedObject var store: AppStore
    var isStandaloneSplitPane: Bool = false
    var onSelectDocumentInSplitPane: ((URL) -> Void)?

    @State private var isDropTargeted = false
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public static let sidebarWidth: CGFloat = 216
    public static let maxColumnWidth: CGFloat = 880
    public static let minimumGutter: CGFloat = 40
    public static let cardMinWidth: CGFloat = 132
    public static let cardMaxWidth: CGFloat = 156
    /// Home shows one row's worth of documents; "查看全部" opens the full page
    public static let homeSectionItemLimit = 6

    public init(
        store: AppStore,
        isStandaloneSplitPane: Bool = false,
        onSelectDocumentInSplitPane: ((URL) -> Void)? = nil
    ) {
        self.store = store
        self.isStandaloneSplitPane = isStandaloneSplitPane
        self.onSelectDocumentInSplitPane = onSelectDocumentInSplitPane
    }

    public var body: some View {
        HStack(spacing: 0) {
            if !isStandaloneSplitPane {
                HomeTabSidebarView(store: store)
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity)
            }

            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppPalette.homeContentBackground(isDark))
        }
        .overlay {
            // Drag-and-Drop Overlay (DropOverlayView)
            if isDropTargeted {
                DropOverlayView(isDark: isDark)
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL, .pdf], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var pageContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 32) {
                switch isStandaloneSplitPane ? .home : store.homeCurrentPage {
                case .home:
                    homePageSections
                case .recents:
                    recentsFullPage
                case .favorites:
                    favoritesFullPage
                }
            }
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
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.tr("阅读主题", "Reading Theme"))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(AppPalette.labelPrimary(isDark))
                        Spacer()
                        Toggle(L10n.tr("浅色时使用纸质替代日间", "Use Sepia in Light Mode"), isOn: $store.useSepiaForLightSystemTheme)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 12))
                            .foregroundColor(AppPalette.labelSecondary(isDark))
                    }
                    HStack(spacing: 12) {
                        ForEach(PDFReadingThemeMode.allCases) { mode in
                            HomeThemeModeCard(
                                mode: mode,
                                useSepiaInLight: store.useSepiaForLightSystemTheme,
                                isSelected: store.readingThemeMode == mode,
                                isDark: isDark
                            ) {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.readingThemeMode = mode
                                }
                            }
                        }
                    }
                }
            }

            // Recent Documents
            documentsSection(
                title: L10n.tr("最近打开", "Recents"),
                items: store.recentDocuments,
                actions: isStandaloneSplitPane ? [] : [
                    HomeSectionAction(title: L10n.tr("清除全部", "Clear All")) { store.clearAllRecents() },
                    HomeSectionAction(title: L10n.tr("查看全部", "See All")) { store.homeCurrentPage = .recents }
                ],
                allowsRemoval: true,
                emptyText: L10n.tr("打开过的 PDF 会显示在这里，方便随时继续阅读。", "Recently opened PDFs will appear here so you can pick up where you left off.")
            )

            // Favorites
            documentsSection(
                title: L10n.tr("收藏夹", "Favorites"),
                items: store.favoriteDocuments,
                actions: isStandaloneSplitPane ? [] : [
                    HomeSectionAction(title: L10n.tr("查看全部", "See All")) { store.homeCurrentPage = .favorites }
                ],
                allowsRemoval: false,
                emptyText: L10n.tr("将鼠标悬停在文档上并点按星标，即可加入收藏夹。", "Hover over a document and click the star to add it to Favorites.")
            )
        }
    }

    private func documentsSection(
        title: String,
        items: [DocumentItem],
        actions: [HomeSectionAction],
        allowsRemoval: Bool,
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionHeader(title: title, actions: items.isEmpty ? [] : actions, isDark: isDark)

            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .padding(.vertical, 4)
            } else {
                documentsGrid(Array(items.prefix(Self.homeSectionItemLimit)), allowsRemoval: allowsRemoval)
            }
        }
    }

    // MARK: - Recents Full Page

    private var recentsFullPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                pageTitle(L10n.tr("最近打开", "Recents"))
                Spacer()
                if !store.recentDocuments.isEmpty {
                    HomeLinkButton(title: L10n.tr("清除全部", "Clear All")) {
                        store.clearAllRecents()
                    }
                }
            }

            if store.recentDocuments.isEmpty {
                HomeEmptyStateView(
                    icon: "clock",
                    title: L10n.tr("暂无最近打开的 PDF 文档", "No Recent PDF Documents"),
                    subtitle: L10n.tr("打开过的文件会自动显示在这里，方便随时继续阅读。", "Opened files will appear here automatically so you can continue reading anytime."),
                    actionTitle: L10n.tr("打开文件", "Open File"),
                    isDark: isDark,
                    action: { store.openFilePicker() }
                )
            } else {
                documentsGrid(store.recentDocuments, allowsRemoval: true)
            }
        }
    }

    // MARK: - Favorites Full Page

    private var favoritesFullPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                pageTitle(L10n.tr("收藏夹", "Favorites"))
                Spacer()
                if !store.favoriteDocuments.isEmpty {
                    HomeLinkButton(title: L10n.tr("清空收藏夹", "Clear Favorites")) {
                        store.clearAllFavorites()
                    }
                }
            }

            if store.favoriteDocuments.isEmpty {
                HomeEmptyStateView(
                    icon: "star",
                    title: L10n.tr("收藏夹为空", "Favorites is Empty"),
                    subtitle: L10n.tr("将鼠标悬停在任意文档上并点按星标，即可将其加入收藏夹。", "Hover over any document and click the star to add it to Favorites."),
                    actionTitle: L10n.tr("返回主页", "Back to Home"),
                    isDark: isDark,
                    action: { store.homeCurrentPage = .home }
                )
            } else {
                documentsGrid(store.favoriteDocuments, allowsRemoval: false)
            }
        }
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
            columns: [GridItem(.adaptive(minimum: Self.cardMinWidth, maximum: Self.cardMaxWidth), spacing: 14, alignment: .top)],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(items) { item in
                DocumentCardView(
                    item: item,
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
            store.openFilePicker()
        }
    }

    private func openURL(_ url: URL) {
        if let splitHandler = onSelectDocumentInSplitPane {
            splitHandler(url)
        } else {
            store.openDocument(at: url)
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
    /// Hands every dropped PDF file to `open` on the main actor; returns whether the drop carried file URLs.
    static func open(_ providers: [NSItemProvider], with open: @escaping @MainActor (URL) -> Void) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf" else {
                    return
                }
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
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Navigation Pages (Home / Recents / Favorites)
            ForEach(HomeTabPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.homeCurrentPage = page
                    }
                } label: {
                    HomeSidebarRowLabel(
                        icon: "\(page.iconName).fill",
                        iconColor: page == .home ? AppPalette.systemRed : AppPalette.labelPrimary(isDark),
                        title: page.title,
                        badge: badge(for: page),
                        isSelected: store.homeCurrentPage == page,
                        isDark: isDark
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 16)

            // Footer actions (PDF Expert: Account Details / Settings / Get Support)
            Button {
                store.openFilePicker()
            } label: {
                HomeSidebarRowLabel(icon: "folder", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("打开文件…", "Open File…"), badge: "⌘O", isSecondary: true, isDark: isDark)
            }
            .buttonStyle(.plain)

            Button {
                store.openGettingStartedGuide()
            } label: {
                HomeSidebarRowLabel(icon: "questionmark.circle", iconColor: AppPalette.labelSecondary(isDark), title: L10n.tr("阅读指南", "Reading Guide"), isSecondary: true, isDark: isDark)
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
        .background(AppPalette.homeSidebarBackground(isDark))
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
                    .foregroundColor(AppPalette.labelTertiary(isDark))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: isSecondary ? 34 : 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? AppPalette.homeSidebarSelection(isDark)
                        : (isHovered ? AppPalette.homeSidebarSelection(isDark).opacity(0.55) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Section Header & Links

struct HomeSectionAction: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}

struct HomeSectionHeader: View {
    let title: String
    var actions: [HomeSectionAction] = []
    let isDark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(AppPalette.labelPrimary(isDark))
            Spacer()
            ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                if idx > 0 {
                    Rectangle()
                        .fill(AppPalette.separator(isDark))
                        .frame(width: 1, height: 14)
                }
                HomeLinkButton(title: action.title, action: action.action)
            }
        }
    }
}

struct HomeLinkButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundColor(AppPalette.accentBlue.opacity(isHovered ? 0.75 : 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct HomePrimaryButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(Capsule().fill(AppPalette.accentBlue.opacity(isHovered ? 0.88 : 1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - HomeDropAreaCard

struct HomeDropAreaCard: View {
    let isDark: Bool
    var isCompact: Bool = false
    let onOpenFilePicker: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 12) {
            PDFStackIllustration(isDark: isDark)
                .frame(width: 104, height: 62)

            HomePrimaryButton(title: L10n.tr("打开文件", "Open File"), action: onOpenFilePicker)

            Text(L10n.tr("或将 PDF 文件拖放到此处", "or drag and drop PDF files here"))
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.accentBlue.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? 176 : 196)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppPalette.accentBlue.opacity(isDark ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppPalette.accentBlue.opacity(isDark ? 0.22 : 0.13), lineWidth: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    AppPalette.accentBlue.opacity(isHovered ? 0.75 : 0.42),
                    style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])
                )
                .padding(6)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpenFilePicker)
    }
}

/// Three fanned pages with a "PDF" label, drawn with shapes.
struct PDFStackIllustration: View {
    let isDark: Bool

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
                        .foregroundColor(AppPalette.accentBlue.opacity(0.75))
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
                    .stroke(AppPalette.accentBlue.opacity(0.28), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if showsLines {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<4, id: \.self) { line in
                            Capsule()
                                .fill(AppPalette.accentBlue.opacity(0.25))
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
                            .foregroundColor(AppPalette.accentBlue)
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
                    .stroke(isSelected ? AppPalette.accentBlue : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(L10n.tr("阅读主题", "Reading Theme")): \(mode.title)")
        .onHover { isHovered = $0 }
    }
}

// MARK: - DocumentCardView (DocumentItemView)

struct DocumentCardView: View {
    let item: DocumentItem
    let pdfTheme: PDFViewTheme
    let isDark: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onShowInFinder: () -> Void
    let onRemoveRecent: (() -> Void)?

    @State private var isHovered = false

    /// The page count is read in the background and stays `0` until then
    private var subtitleText: String {
        let parts = [item.pageCount > 0 ? L10n.pageCountText(item.pageCount) : "", item.dateOpenedText]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: PDFThumbnailCache.shared.themedCover(for: item, theme: pdfTheme))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 112, maxHeight: 142)
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(isDark ? 0.35 : 0.10), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    // Favorite Star (on hover, or always when favorited)
                    if isHovered || item.isFavorite {
                        Button(action: onToggleFavorite) {
                            Image(systemName: item.isFavorite ? "star.fill" : "star")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(item.isFavorite ? AppPalette.systemYellow : .white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .help(item.isFavorite ? L10n.tr("取消收藏", "Remove from Favorites") : L10n.tr("添加到收藏", "Add to Favorites"))
                        .padding(5)
                    }
                }
                .shadow(color: Color.black.opacity(isDark ? 0.5 : 0.16), radius: isHovered ? 6 : 3.5, x: 0, y: isHovered ? 3 : 1.5)
                .frame(height: 150)

            VStack(spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)

                Text(subtitleText)
                    .font(.system(size: 10.5))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? AppPalette.homeCardHover(isDark) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .help(item.url.path)
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppPalette.accentBlue.opacity(0.10))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppPalette.accentBlue, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundColor(AppPalette.accentBlue)
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
