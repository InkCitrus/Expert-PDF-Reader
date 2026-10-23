import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Replicates `HomeTabRootView`, `HomeTabPageView`, `HomeTabSidebarView`, `HorizontalItemsRow`,
/// and `DocumentsCollectionView` from `HomeTab.framework/Resources/ARCHITECTURE.md`.
public struct HomeTabRootView: View {
    @ObservedObject var store: AppStore
    var isStandaloneSplitPane: Bool = false
    var onSelectDocumentInSplitPane: ((URL) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public static let sidebarWidth: CGFloat = 216
    public static let maxColumnWidth: CGFloat = 880
    public static let minimumGutter: CGFloat = 32
    public static let cardWidth: CGFloat = 144
    public static let cardHeight: CGFloat = 214

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
        ZStack(alignment: .leading) {
            // Page Container (full width, inset by sidebarWidth when not standalone)
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RDColorPalette.secondarySystemBackground(isDark))

            // Leading .thinMaterial Sidebar (216pt) pinned to leading edge
            if !isStandaloneSplitPane {
                HomeTabSidebarView(store: store)
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(.thinMaterial)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(RDColorPalette.separator(isDark).opacity(0.45))
                            .frame(width: 1)
                    }
            }

            // Drag-and-Drop Overlay (DropOverlayView)
            if store.isDraggingOverHome {
                DropOverlayView(isDark: isDark)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL, .pdf], isTargeted: $store.isDraggingOverHome) { providers in
            handleDrop(providers: providers)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .center, spacing: 28) {
                switch isStandaloneSplitPane ? .home : store.homeCurrentPage {
                case .home:
                    homePageSections
                case .recents:
                    recentsFullPage
                case .favorites:
                    favoritesFullPage
                }
            }
            .padding(.leading, isStandaloneSplitPane ? 0 : Self.sidebarWidth)
            .padding(.horizontal, Self.minimumGutter)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Home Page Sections

    private var homePageSections: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Top Header + Quick Theme Switcher
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isStandaloneSplitPane ? "选择分屏对比文档" : "欢迎使用 PDF Expert 阅读版")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(RDColorPalette.labelPrimary(isDark))
                        .lineLimit(1)
                    Text(isStandaloneSplitPane ? "点击任一文档或在下方拖入 PDF 以在分屏视图中打开" : "纯粹阅读体验 • GPU 原生着色器支持日间 / 纸质 / 夜间三色切换")
                        .font(.system(size: 12.5))
                        .foregroundColor(RDColorPalette.labelSecondary(isDark))
                        .lineLimit(1)
                }
                Spacer()
                if !isStandaloneSplitPane {
                    HomeThemeQuickPicker(store: store)
                }
            }
            .pageSection()

            // Drop Area Section (HomeSection.dropArea)
            HomeDropAreaCard(
                isDark: isDark,
                onOpenFilePicker: {
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
                },
                onOpenGuide: {
                    let url = SamplePDFGenerator.ensureSamplePDFExists()
                    openURL(url)
                }
            )
            .pageSection()

            // Opened Files Section (when any document tab is open)
            if !store.openedDocumentItems.isEmpty && !isStandaloneSplitPane {
                HomeDocumentsHorizontalSection(
                    title: "已打开的文档",
                    icon: "doc.on.doc.fill",
                    items: store.openedDocumentItems,
                    pdfTheme: store.pdfTheme,
                    isDark: isDark,
                    viewAllAction: nil,
                    onOpen: { openURL($0.url) },
                    onToggleFavorite: { store.toggleFavorite(id: $0.documentID) },
                    onShowInFinder: { store.showInFinder(id: $0.documentID) },
                    onRemoveRecent: nil
                )
                .pageSection()
            }

            // Recent Documents Horizontal Row
            HomeDocumentsHorizontalSection(
                title: "最近打开",
                icon: "clock.fill",
                items: store.recentDocuments,
                pdfTheme: store.pdfTheme,
                isDark: isDark,
                viewAllAction: isStandaloneSplitPane ? nil : { store.homeCurrentPage = .recents },
                onOpen: { openURL($0.url) },
                onToggleFavorite: { store.toggleFavorite(id: $0.documentID) },
                onShowInFinder: { store.showInFinder(id: $0.documentID) },
                onRemoveRecent: { store.removeFromRecents(id: $0.documentID) }
            )
            .pageSection()

            // Favorites Horizontal Row
            HomeDocumentsHorizontalSection(
                title: "收藏夹",
                icon: "star.fill",
                items: store.favoriteDocuments,
                pdfTheme: store.pdfTheme,
                isDark: isDark,
                viewAllAction: isStandaloneSplitPane ? nil : { store.homeCurrentPage = .favorites },
                onOpen: { openURL($0.url) },
                onToggleFavorite: { store.toggleFavorite(id: $0.documentID) },
                onShowInFinder: { store.showInFinder(id: $0.documentID) },
                onRemoveRecent: nil
            )
            .pageSection()
        }
    }

    // MARK: - Recents Full Page

    private var recentsFullPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("最近打开", systemImage: "clock.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                Spacer()
                if !store.recentDocuments.isEmpty {
                    Button("清除全部最近记录") {
                        store.clearAllRecents()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .pageSection()

            if store.recentDocuments.isEmpty {
                HomeEmptyStateView(
                    icon: "clock.badge.questionmark",
                    title: "暂无最近打开的 PDF 文档",
                    subtitle: "打开过的文件会自动显示在这里，方便随时继续阅读。",
                    actionTitle: "打开 PDF 文件...",
                    isDark: isDark,
                    action: { store.openFilePicker() }
                )
                .pageSection()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.cardWidth, maximum: 168), spacing: 18)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(store.recentDocuments) { item in
                        DocumentCardView(
                            item: item,
                            pdfTheme: store.pdfTheme,
                            isDark: isDark,
                            onOpen: { openURL(item.url) },
                            onToggleFavorite: { store.toggleFavorite(id: item.documentID) },
                            onShowInFinder: { store.showInFinder(id: item.documentID) },
                            onRemoveRecent: { store.removeFromRecents(id: item.documentID) }
                        )
                    }
                }
                .pageSection()
            }
        }
    }

    // MARK: - Favorites Full Page

    private var favoritesFullPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("收藏夹", systemImage: "star.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                Spacer()
                if !store.favoriteDocuments.isEmpty {
                    Button("清空收藏夹") {
                        store.clearAllFavorites()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .pageSection()

            if store.favoriteDocuments.isEmpty {
                HomeEmptyStateView(
                    icon: "star.slash",
                    title: "收藏夹为空",
                    subtitle: "将鼠标悬停在任意文档卡片右上角点击星标，即可将其加入收藏夹。",
                    actionTitle: "返回主页",
                    isDark: isDark,
                    action: { store.homeCurrentPage = .home }
                )
                .pageSection()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.cardWidth, maximum: 168), spacing: 18)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(store.favoriteDocuments) { item in
                        DocumentCardView(
                            item: item,
                            pdfTheme: store.pdfTheme,
                            isDark: isDark,
                            onOpen: { openURL(item.url) },
                            onToggleFavorite: { store.toggleFavorite(id: item.documentID) },
                            onShowInFinder: { store.showInFinder(id: item.documentID) },
                            onRemoveRecent: nil
                        )
                    }
                }
                .pageSection()
            }
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
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension.lowercased() == "pdf" else {
                        return
                    }
                    Task { @MainActor in
                        openURL(url)
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - View.pageSection() Modifier (from HomeTabPageView.swift)

extension View {
    func pageSection() -> some View {
        ZStack {
            self
        }
        .frame(maxWidth: HomeTabRootView.maxColumnWidth, alignment: .leading)
    }
}

// MARK: - HomeTabSidebarView

struct HomeTabSidebarView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // App Identity Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [RDColorPalette.primaryTint, RDColorPalette.systemDarkBlue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("PDF Expert")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(RDColorPalette.labelPrimary(isDark))
                    Text("Reader Edition")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(RDColorPalette.labelTertiary(isDark))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Navigation Pages (Home / Recents / Favorites)
            ForEach(HomeTabPage.allCases) { page in
                let isSelected = store.homeCurrentPage == page
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.homeCurrentPage = page
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "\(page.iconName).fill" : page.iconName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                            .foregroundColor(isSelected ? RDColorPalette.primaryTint : RDColorPalette.labelSecondary(isDark))
                        Text(page.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? RDColorPalette.labelPrimary(isDark) : RDColorPalette.labelSecondary(isDark))
                        Spacer()
                        if page == .recents && !store.recentDocuments.isEmpty {
                            Text("\(store.recentDocuments.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(RDColorPalette.labelTertiary(isDark))
                        } else if page == .favorites && !store.favoriteDocuments.isEmpty {
                            Text("\(store.favoriteDocuments.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(RDColorPalette.labelTertiary(isDark))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? RDColorPalette.primaryTint.opacity(isDark ? 0.20 : 0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            Spacer()

            Divider()
                .padding(.horizontal, 14)

            // Appearance & Theme Quick Panel in Sidebar Footer
            VStack(alignment: .leading, spacing: 8) {
                Text("界面外观")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelTertiary(isDark))

                Picker("", selection: $store.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title.replacingOccurrences(of: "外观", with: "")).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            // Open File Button
            Button {
                store.openFilePicker()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text("打开 PDF 文件...")
                        .fontWeight(.medium)
                    Spacer()
                    Text("⌘O")
                        .font(.system(size: 11))
                        .opacity(0.75)
                }
                .font(.system(size: 12.5))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RDColorPalette.primaryTint)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - HomeThemeQuickPicker

struct HomeThemeQuickPicker: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 4) {
            ForEach([PDFViewTheme.day, .sepia, .night]) { theme in
                let isSelected = store.pdfTheme == theme
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.pdfTheme = theme
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(theme.pagePaperColor)
                            .frame(width: 11, height: 11)
                            .overlay(
                                Circle().stroke(Color.gray.opacity(0.45), lineWidth: 0.8)
                            )
                        Text(theme.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? RDColorPalette.primaryTint.opacity(0.18) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? RDColorPalette.primaryTint : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RDColorPalette.tertiarySystemBackground(isDark))
        )
    }
}

// MARK: - HomeDropAreaCard

struct HomeDropAreaCard: View {
    let isDark: Bool
    let onOpenFilePicker: () -> Void
    let onOpenGuide: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(RDColorPalette.primaryTint.opacity(isDark ? 0.18 : 0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(RDColorPalette.primaryTint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("将 PDF 拖拽至此处阅读，或点击选择本地文件")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                Text("支持多标签页阅读、日间/纸质/夜间着色器滤镜、单双页与分屏视图、自动去白边及目录大纲检索")
                    .font(.system(size: 12))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))
                    .lineLimit(1)
            }

            Spacer()

            Button("阅读指南 PDF") {
                onOpenGuide()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button("选择文件...") {
                onOpenFilePicker()
            }
            .buttonStyle(.borderedProminent)
            .tint(RDColorPalette.primaryTint)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RDColorPalette.tertiarySystemBackground(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                )
                .foregroundColor(isHovered ? RDColorPalette.primaryTint : RDColorPalette.separator(isDark))
        )
        .onHover { isHovered = $0 }
        .onTapGesture { onOpenFilePicker() }
    }
}

// MARK: - HomeDocumentsHorizontalSection (HorizontalItemsRow)

struct HomeDocumentsHorizontalSection: View {
    let title: String
    let icon: String
    let items: [DocumentItem]
    let pdfTheme: PDFViewTheme
    let isDark: Bool
    let viewAllAction: (() -> Void)?
    let onOpen: (DocumentItem) -> Void
    let onToggleFavorite: (DocumentItem) -> Void
    let onShowInFinder: (DocumentItem) -> Void
    let onRemoveRecent: ((DocumentItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                Text("(\(items.count))")
                    .font(.system(size: 12.5))
                    .foregroundColor(RDColorPalette.labelTertiary(isDark))
                Spacer()
                if let viewAll = viewAllAction, !items.isEmpty {
                    Button {
                        viewAll()
                    } label: {
                        HStack(spacing: 3) {
                            Text("查看全部")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(RDColorPalette.primaryTint)
                    }
                    .buttonStyle(.plain)
                }
            }

            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray")
                        .foregroundColor(RDColorPalette.labelTertiary(isDark))
                    Text("暂无\(title)内容")
                        .font(.system(size: 12.5))
                        .foregroundColor(RDColorPalette.labelTertiary(isDark))
                }
                .frame(maxWidth: .infinity, minHeight: 84)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RDColorPalette.tertiarySystemBackground(isDark).opacity(0.6))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            DocumentCardView(
                                item: item,
                                pdfTheme: pdfTheme,
                                isDark: isDark,
                                onOpen: { onOpen(item) },
                                onToggleFavorite: { onToggleFavorite(item) },
                                onShowInFinder: { onShowInFinder(item) },
                                onRemoveRecent: onRemoveRecent.map { fn in { fn(item) } }
                            )
                            .frame(width: HomeTabRootView.cardWidth)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail Preview Container
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RDColorPalette.tertiarySystemBackground(isDark))

                    Image(nsImage: themedThumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.14), radius: 5, x: 0, y: 2)
                        .padding(10)
                        .id("\(colorScheme)-\(pdfTheme.rawValue)")
                }
                .frame(height: 158)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isHovered ? RDColorPalette.primaryTint : RDColorPalette.separator(isDark).opacity(0.45), lineWidth: isHovered ? 1.5 : 0.8)
                )

                // Page count badge (bottom-left) + Favorite Star (top-right)
                if isHovered || item.isFavorite {
                    Button {
                        onToggleFavorite()
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(item.isFavorite ? RDColorPalette.systemYellow : .white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text("\(item.pageCount) 页")
                    if !item.dateOpenedText.isEmpty {
                        Text("•")
                        Text(item.dateOpenedText)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(RDColorPalette.labelTertiary(isDark))
                .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button("阅读文档") { onOpen() }
            Button(item.isFavorite ? "取消收藏" : "添加到收藏") { onToggleFavorite() }
            Divider()
            Button("在 Finder 中显示") { onShowInFinder() }
            if let remove = onRemoveRecent {
                Divider()
                Button("从最近打开中移除", role: .destructive) { remove() }
            }
        }
    }

    private var themedThumbnail: NSImage {
        if pdfTheme == .day {
            return item.thumbnail
        }
        if let cg = item.thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let outCG = MetalShaderRenderer.shared.applyShader(to: cg, theme: pdfTheme) {
            return NSImage(cgImage: outCG, size: item.thumbnail.size)
        }
        return item.thumbnail
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
                .font(.system(size: 38, weight: .light))
                .foregroundColor(RDColorPalette.labelTertiary(isDark))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(RDColorPalette.labelPrimary(isDark))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(RDColorPalette.labelSecondary(isDark))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(actionTitle) {
                action()
            }
            .buttonStyle(.borderedProminent)
            .tint(RDColorPalette.primaryTint)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RDColorPalette.tertiarySystemBackground(isDark).opacity(0.6))
        )
    }
}

struct DropOverlayView: View {
    let isDark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RDColorPalette.primaryTint.opacity(0.12))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(RDColorPalette.primaryTint, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 42))
                    .foregroundColor(RDColorPalette.primaryTint)
                Text("松开以在 Open PDF Expert 中打开阅读")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
