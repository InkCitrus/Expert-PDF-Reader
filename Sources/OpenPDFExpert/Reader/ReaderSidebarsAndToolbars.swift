import AppKit
import PDFKit
import SwiftUI

// MARK: - Top Reader Toolbar (RDToolbarView / MainToolbarDelegateImplementation)

public struct ReaderToolbarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @State private var showDisplaySettingsPopover = false
    @State private var showGoToPagePopover = false
    @State private var goToPageInput: String = ""
    @State private var showSearchResultsPopover = false

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        HStack(spacing: 10) {
            // Left Group: Sidebar Toggle + History + Page Stepper + Rotate
            HStack(spacing: 6) {
                ToolbarIconButton(
                    icon: "sidebar.leading",
                    tooltip: tab.isLeftSidebarVisible ? "隐藏左边面板 (⌘B)" : "显示左边面板 (⌘B)",
                    isActive: tab.isLeftSidebarVisible,
                    isDark: isDark
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        tab.isLeftSidebarVisible.toggle()
                    }
                }

                Divider()
                    .frame(height: 18)

                // Back / Forward History
                ToolbarIconButton(
                    icon: "chevron.backward",
                    tooltip: "返回上一浏览位置 (⌘[)",
                    isDisabled: !tab.canGoBack,
                    isDark: isDark
                ) {
                    tab.goBack()
                }

                ToolbarIconButton(
                    icon: "chevron.forward",
                    tooltip: "前往下一浏览位置 (⌘])",
                    isDisabled: !tab.canGoForward,
                    isDark: isDark
                ) {
                    tab.goForward()
                }

                // Page Number Indicator & Jump Popover
                Button {
                    goToPageInput = "\(tab.currentPageIndex + 1)"
                    showGoToPagePopover = true
                } label: {
                    HStack(spacing: 4) {
                        Text("\(tab.currentPageIndex + 1)")
                            .fontWeight(.semibold)
                            .foregroundColor(RDColorPalette.labelPrimary(isDark))
                        Text("/")
                            .foregroundColor(RDColorPalette.labelTertiary(isDark))
                        Text("\(tab.pageCount)")
                            .foregroundColor(RDColorPalette.labelSecondary(isDark))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(RDColorPalette.tertiarySystemBackground(isDark))
                    )
                }
                .buttonStyle(.plain)
                .help("前往指定页码...")
                .popover(isPresented: $showGoToPagePopover, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        Text("前往页码:")
                            .font(.system(size: 12))
                        TextField("1-\(tab.pageCount)", text: $goToPageInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .onSubmit {
                                commitGoToPage()
                            }
                        Button("跳转") {
                            commitGoToPage()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RDColorPalette.primaryTint)
                        .controlSize(.small)
                    }
                    .padding(12)
                }

                // Rotate Current Page
                ToolbarIconButton(
                    icon: "rotate.left",
                    tooltip: "向左旋转当前页面",
                    isDark: isDark
                ) {
                    tab.rotateCurrentPage(clockwise: false)
                }
            }

            Spacer()

            // Center Group: Three-Mode Theme Switcher (Day / Sepia / Night) + Display Settings Popover
            HStack(spacing: 8) {
                // Direct Day / Sepia / Night Pill Switcher
                HStack(spacing: 2) {
                    ForEach([PDFViewTheme.day, .sepia, .night]) { theme in
                        let isSelected = store.pdfTheme == theme
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                store.pdfTheme = theme
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(theme.pagePaperColor)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle().stroke(Color.gray.opacity(0.5), lineWidth: 0.8)
                                    )
                                Text(theme.title)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? RDColorPalette.labelPrimary(isDark) : RDColorPalette.labelSecondary(isDark))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? RDColorPalette.primaryTint.opacity(isDark ? 0.25 : 0.16) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isSelected ? RDColorPalette.primaryTint : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RDColorPalette.tertiarySystemBackground(isDark))
                )

                // Layout Quick Buttons (Single / Two Pages / Clear Margins / Split View)
                HStack(spacing: 3) {
                    ForEach(ReaderLayoutMode.allCases) { mode in
                        ToolbarIconButton(
                            icon: mode.iconName,
                            tooltip: mode.title,
                            isActive: tab.layoutMode == mode,
                            isDark: isDark
                        ) {
                            tab.layoutMode = mode
                        }
                    }

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 2)

                    ToolbarIconButton(
                        icon: "crop",
                        tooltip: "清除空白边 (⇧⌘M)",
                        isActive: tab.isClearMarginsEnabled,
                        isDark: isDark
                    ) {
                        tab.isClearMarginsEnabled.toggle()
                        tab.applyClearMarginsIfNeeded()
                    }

                    ToolbarIconButton(
                        icon: tab.splitMode == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1",
                        tooltip: "分屏视图",
                        isActive: tab.splitMode != .disabled,
                        isDark: isDark
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            tab.splitMode = (tab.splitMode == .disabled) ? .vertical : .disabled
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RDColorPalette.tertiarySystemBackground(isDark))
                )

                // Full Display Settings Popover Button (DocumentDisplaySettingsPanelViewController)
                Button {
                    showDisplaySettingsPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                        Text("视图设置")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(showDisplaySettingsPopover ? RDColorPalette.primaryTint : RDColorPalette.labelPrimary(isDark))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(RDColorPalette.tertiarySystemBackground(isDark))
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDisplaySettingsPopover, arrowEdge: .bottom) {
                    DocumentDisplaySettingsPopover(store: store, tab: tab)
                }
            }

            Spacer()

            // Right Group: Zoom Controls + Bookmark + Search
            HStack(spacing: 6) {
                // Zoom Controls (PDFZoomToolbarItemView)
                HStack(spacing: 2) {
                    ToolbarIconButton(
                        icon: "minus.magnifyingglass",
                        tooltip: "缩小 (⌘-)",
                        isDark: isDark
                    ) {
                        tab.triggerZoom(.zoomOut)
                    }

                    Menu {
                        Button("缩放至适应宽度 (⌘8)") { tab.triggerZoom(.fitWidth) }
                        Button("缩放至适应页面 (⌘9)") { tab.triggerZoom(.fitPage) }
                        Button("实际大小 100% (⌘0)") { tab.triggerZoom(.actualSize) }
                    } label: {
                        Text("\(Int(round(tab.zoomScale * 100)))%")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .frame(minWidth: 44)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    ToolbarIconButton(
                        icon: "plus.magnifyingglass",
                        tooltip: "放大 (⌘+)",
                        isDark: isDark
                    ) {
                        tab.triggerZoom(.zoomIn)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(RDColorPalette.tertiarySystemBackground(isDark))
                )

                // Bookmark Current Page Button
                let isBookmarked = store.isPageBookmarked(pageIndex: tab.currentPageIndex, in: tab.documentID)
                ToolbarIconButton(
                    icon: isBookmarked ? "bookmark.fill" : "bookmark",
                    tooltip: isBookmarked ? "移除当前页书签 (⌘D)" : "添加书签到当前页 (⌘D)",
                    isActive: isBookmarked,
                    isDark: isDark
                ) {
                    store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
                }

                // Expandable Search Bar (PDFSearchToolbarItemView)
                if tab.isSearchVisible {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5))
                            .foregroundColor(RDColorPalette.labelTertiary(isDark))

                        TextField("查找文档内容...", text: $tab.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 135)
                            .onSubmit {
                                tab.performSearch()
                                if !tab.searchMatches.isEmpty {
                                    showSearchResultsPopover = true
                                }
                            }
                            .onChange(of: tab.searchQuery) { _, _ in
                                tab.performSearch()
                            }

                        if !tab.searchMatches.isEmpty {
                            Button {
                                showSearchResultsPopover.toggle()
                            } label: {
                                Text("\(tab.selectedMatchIndex + 1)/\(tab.searchMatches.count)")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(RDColorPalette.primaryTint)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showSearchResultsPopover, arrowEdge: .bottom) {
                                SearchResultsListPopover(tab: tab, isDark: isDark)
                            }

                            Button {
                                tab.selectPreviousSearchMatch()
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)

                            Button {
                                tab.selectNextSearchMatch()
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                tab.searchQuery = ""
                                tab.searchMatches = []
                                tab.isSearchVisible = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(RDColorPalette.labelTertiary(isDark))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(RDColorPalette.tertiarySystemBackground(isDark))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(RDColorPalette.primaryTint.opacity(0.6), lineWidth: 1)
                    )
                } else {
                    ToolbarIconButton(
                        icon: "magnifyingglass",
                        tooltip: "全文查找 (⌘F)",
                        isDark: isDark
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            tab.isSearchVisible = true
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RDColorPalette.secondarySystemBackground(isDark))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RDColorPalette.separator(isDark).opacity(0.55))
                .frame(height: 1)
        }
    }

    private func commitGoToPage() {
        if let num = Int(goToPageInput.trimmingCharacters(in: .whitespaces)),
           num >= 1 && num <= tab.pageCount {
            tab.navigateToPage(num - 1)
            showGoToPagePopover = false
        }
    }
}

// MARK: - DocumentDisplaySettingsPopover (DocumentDisplaySettingsPanelViewController)

struct DocumentDisplaySettingsPopover: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. Page Reading Theme (Day / Sepia / Night)
            VStack(alignment: .leading, spacing: 8) {
                Text("页面阅读主题 (RDPDFShaders)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))

                HStack(spacing: 10) {
                    ForEach([PDFViewTheme.day, .sepia, .night]) { theme in
                        let isSelected = store.pdfTheme == theme
                        Button {
                            store.pdfTheme = theme
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(theme.pagePaperColor)
                                        .frame(width: 78, height: 50)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(isSelected ? RDColorPalette.primaryTint : Color.gray.opacity(0.35), lineWidth: isSelected ? 2 : 1)
                                        )
                                    VStack(alignment: .leading, spacing: 4) {
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(theme.pageInkColor)
                                            .frame(width: 44, height: 4)
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(theme.pageInkColor.opacity(0.75))
                                            .frame(width: 52, height: 3)
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(theme.pageInkColor.opacity(0.55))
                                            .frame(width: 36, height: 3)
                                    }
                                }
                                Text(theme.title)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? RDColorPalette.primaryTint : RDColorPalette.labelPrimary(isDark))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // 2. App UI Appearance (System / Light / Dark)
            VStack(alignment: .leading, spacing: 8) {
                Text("应用界面外观")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))

                Picker("", selection: $store.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.iconName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            // 3. Page Layout Mode (Single / Two Pages / Cover)
            VStack(alignment: .leading, spacing: 8) {
                Text("页面排列方式")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))

                ForEach(ReaderLayoutMode.allCases) { mode in
                    Button {
                        tab.layoutMode = mode
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: mode.iconName)
                                .frame(width: 18)
                                .foregroundColor(tab.layoutMode == mode ? RDColorPalette.primaryTint : RDColorPalette.labelSecondary(isDark))
                            Text(mode.title)
                                .font(.system(size: 12.5, weight: tab.layoutMode == mode ? .semibold : .regular))
                            Spacer()
                            if tab.layoutMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(RDColorPalette.primaryTint)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Toggle(isOn: Binding(
                    get: { tab.isClearMarginsEnabled },
                    set: { newValue in
                        tab.isClearMarginsEnabled = newValue
                        tab.applyClearMarginsIfNeeded()
                    }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: "crop")
                        Text("清除空白边 (智能识别页面内容边界)")
                            .font(.system(size: 12.5))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 4)
            }

            Divider()

            // 4. Split View Mode (PDFDocumentsSplitViewController)
            VStack(alignment: .leading, spacing: 8) {
                Text("分屏对比视图")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))

                Picker("", selection: $tab.splitMode) {
                    Text("关闭").tag(ReaderSplitMode.disabled)
                    Text("左右垂直").tag(ReaderSplitMode.vertical)
                    Text("上下水平").tag(ReaderSplitMode.horizontal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if tab.splitMode != .disabled {
                    HStack(spacing: 10) {
                        Toggle("同步滚动和缩放", isOn: $tab.syncScrollAndZoom)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))

                        Spacer()

                        Button("对调位置") {
                            tab.isSplitSwapped.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("切换对比文档...") {
                            tab.showSplitDocumentPicker = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(width: 296)
    }
}

// MARK: - SearchResultsListPopover

struct SearchResultsListPopover: View {
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("共找到 \(tab.searchMatches.count) 处匹配")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RDColorPalette.secondarySystemBackground(isDark))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tab.searchMatches.enumerated()), id: \.element.id) { idx, item in
                        let isSelected = (idx == tab.selectedMatchIndex)
                        Button {
                            tab.selectedMatchIndex = idx
                            tab.navigateToPage(item.pageIndex, recordHistory: false)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("P.\(item.pageIndex + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(isSelected ? .white : RDColorPalette.primaryTint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(isSelected ? RDColorPalette.primaryTint : RDColorPalette.primaryTint.opacity(0.14))
                                    )

                                Text(item.snippet)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? RDColorPalette.primaryTint.opacity(0.15) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(width: 320, height: 280)
        }
    }
}

// MARK: - Left Sidebar Panel (PanelViewsDockViewController)

public struct ReaderLeftSidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        VStack(spacing: 0) {
            // Segmented Header (Thumbnails / Outline / Bookmarks)
            HStack(spacing: 4) {
                ForEach(ReaderSidebarTab.allCases) { sTab in
                    let isSelected = tab.activeSidebarTab == sTab
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            tab.activeSidebarTab = sTab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: sTab.iconName)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(sTab.title)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundColor(isSelected ? RDColorPalette.primaryTint : RDColorPalette.labelSecondary(isDark))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? RDColorPalette.primaryTint.opacity(isDark ? 0.22 : 0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(RDColorPalette.secondarySystemBackground(isDark))

            Divider()

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
            .background(RDColorPalette.secondarySystemBackground(isDark))
        }
        .frame(width: 228)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RDColorPalette.separator(isDark).opacity(0.55))
                .frame(width: 1)
        }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                    ForEach(0..<tab.pageCount, id: \.self) { pageIdx in
                        let isCurrent = (tab.currentPageIndex == pageIdx)
                        let isBookmarked = store.isPageBookmarked(pageIndex: pageIdx, in: tab.documentID)
                        Button {
                            tab.navigateToPage(pageIdx)
                        } label: {
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    if let page = tab.pdfDocument.page(at: pageIdx) {
                                        let thumb = PDFThumbnailCache.shared.thumbnail(
                                            for: page,
                                            documentID: tab.documentID.id,
                                            pageIndex: pageIdx,
                                            theme: store.pdfTheme
                                        )
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: 148)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.15), radius: 3, x: 0, y: 1)
                                            .padding(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(isCurrent ? RDColorPalette.primaryTint : Color.clear, lineWidth: 2.2)
                                            )
                                    }

                                    if isBookmarked {
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(RDColorPalette.systemRed)
                                            .padding(8)
                                    }
                                }

                                Text("\(pageIdx + 1)")
                                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium, design: .monospaced))
                                    .foregroundColor(isCurrent ? .white : RDColorPalette.labelSecondary(isDark))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(isCurrent ? RDColorPalette.primaryTint : Color.clear)
                                    )
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .id(pageIdx)
                        .contextMenu {
                            Button(isBookmarked ? "移除书签" : "添加书签") {
                                store.toggleBookmark(pageIndex: pageIdx, in: tab.documentID)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: tab.currentPageIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }
}

// MARK: - 2. PDFOutlinePanel (PDFOutlinePanelViewController)

struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let children: [PDFOutlineNode]
}

struct PDFOutlinePanel: View {
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    private var nodes: [PDFOutlineNode] {
        guard let root = tab.pdfDocument.outlineRoot else { return [] }
        return buildOutlineNodes(from: root)
    }

    var body: some View {
        if nodes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(RDColorPalette.labelTertiary(isDark))
                Text("此文档不包含目录大纲")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        PDFOutlineRowView(node: node, level: 0, tab: tab, isDark: isDark)
                    }
                }
                .padding(8)
            }
        }
    }

    private func buildOutlineNodes(from parent: PDFOutline) -> [PDFOutlineNode] {
        var result: [PDFOutlineNode] = []
        for i in 0..<parent.numberOfChildren {
            guard let child = parent.child(at: i) else { continue }
            let pageIdx: Int?
            if let page = child.destination?.page ?? child.action?.PerformPage(in: tab.pdfDocument) {
                let idx = tab.pdfDocument.index(for: page)
                pageIdx = (idx >= 0 && idx < tab.pageCount) ? idx : nil
            } else {
                pageIdx = nil
            }
            let subNodes = buildOutlineNodes(from: child)
            result.append(
                PDFOutlineNode(
                    title: child.label ?? "未命名章节",
                    pageIndex: pageIdx,
                    children: subNodes
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
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let isCurrent = (node.pageIndex == tab.currentPageIndex)
            HStack(spacing: 4) {
                if !node.children.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(RDColorPalette.labelTertiary(isDark))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }

                Button {
                    if let pIdx = node.pageIndex {
                        tab.navigateToPage(pIdx)
                    }
                } label: {
                    HStack {
                        Text(node.title)
                            .font(.system(size: 12, weight: level == 0 ? .semibold : .regular))
                            .foregroundColor(isCurrent ? RDColorPalette.primaryTint : RDColorPalette.labelPrimary(isDark))
                            .lineLimit(1)
                        Spacer()
                        if let pIdx = node.pageIndex {
                            Text("\(pIdx + 1)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(isCurrent ? RDColorPalette.primaryTint : RDColorPalette.labelTertiary(isDark))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(level) * 12)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? RDColorPalette.primaryTint.opacity(isDark ? 0.18 : 0.12) : Color.clear)
            )

            if isExpanded {
                ForEach(node.children) { child in
                    PDFOutlineRowView(node: child, level: level + 1, tab: tab, isDark: isDark)
                }
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
        let isCurrentBookmarked = store.isPageBookmarked(pageIndex: tab.currentPageIndex, in: tab.documentID)

        VStack(spacing: 0) {
            // Quick Add/Toggle Bookmark Bar
            HStack {
                Button {
                    store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCurrentBookmarked ? "bookmark.slash" : "bookmark.fill")
                        Text(isCurrentBookmarked ? "移除当前页书签 (P.\(tab.currentPageIndex + 1))" : "添加当前页到书签 (P.\(tab.currentPageIndex + 1))")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(RDColorPalette.primaryTint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(RDColorPalette.primaryTint.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(8)

            Divider()

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(RDColorPalette.labelTertiary(isDark))
                    Text("暂无页面书签")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(RDColorPalette.labelSecondary(isDark))
                    Text("按 ⌘D 或点击上方按钮标记重要页面")
                        .font(.system(size: 11))
                        .foregroundColor(RDColorPalette.labelTertiary(isDark))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { bm in
                            let isCurrent = (bm.pageIndex == tab.currentPageIndex)
                            HStack(spacing: 8) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(RDColorPalette.systemRed)

                                Button {
                                    tab.navigateToPage(bm.pageIndex)
                                } label: {
                                    HStack {
                                        Text(bm.title)
                                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                            .foregroundColor(isCurrent ? RDColorPalette.primaryTint : RDColorPalette.labelPrimary(isDark))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("P.\(bm.pageIndex + 1)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(RDColorPalette.labelTertiary(isDark))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isCurrent ? RDColorPalette.primaryTint.opacity(0.14) : Color.clear)
                            )
                            .contextMenu {
                                Button("跳转到第 \(bm.pageIndex + 1) 页") {
                                    tab.navigateToPage(bm.pageIndex)
                                }
                                Divider()
                                Button("删除书签", role: .destructive) {
                                    store.removeBookmark(id: bm.id, in: tab.documentID)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

// MARK: - ToolbarIconButton Helper

struct ToolbarIconButton: View {
    let icon: String
    let tooltip: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(foregroundColor)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(tooltip)
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return RDColorPalette.labelQuaternary(isDark)
        }
        if isActive {
            return RDColorPalette.primaryTint
        }
        return RDColorPalette.labelPrimary(isDark)
    }

    private var backgroundColor: Color {
        if isActive {
            return RDColorPalette.primaryTint.opacity(isDark ? 0.22 : 0.14)
        }
        if isHovered && !isDisabled {
            return RDColorPalette.tertiarySystemBackground(isDark)
        }
        return Color.clear
    }
}
