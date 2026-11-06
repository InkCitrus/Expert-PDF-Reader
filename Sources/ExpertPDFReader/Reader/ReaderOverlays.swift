import AppKit
import PDFKit
import SwiftUI

// MARK: - SearchResultsPanel (right dock)

/// PDF Expert 3 lists full-text results in a dock beside the page; matches are grouped by page
/// and the query is highlighted inside each snippet.
struct SearchResultsPanel: View {
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    static let width: CGFloat = 280

    private struct Entry: Identifiable {
        let index: Int
        let item: SearchMatchItem
        var id: UUID { item.id }
    }

    private struct PageGroup: Identifiable {
        let pageIndex: Int
        let entries: [Entry]
        var id: Int { pageIndex }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(AppPalette.panelBackground(isDark))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppPalette.panelHairline(isDark))
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("搜索结果", "Search Results")))
    }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("搜索结果", "Search Results"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            PanelHeaderIconButton(icon: "chevron.up", tooltip: L10n.tr("查找上一个 (⇧⌘G)", "Find Previous (⇧⌘G)"), isDisabled: tab.searchMatches.isEmpty, isDark: isDark) {
                tab.selectPreviousSearchMatch()
            }
            PanelHeaderIconButton(icon: "chevron.down", tooltip: L10n.tr("查找下一个 (⌘G)", "Find Next (⌘G)"), isDisabled: tab.searchMatches.isEmpty, isDark: isDark) {
                tab.selectNextSearchMatch()
            }
            PanelHeaderIconButton(icon: "xmark", tooltip: L10n.tr("关闭搜索", "Close Search"), isDark: isDark) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    tab.endSearch()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var summaryText: String {
        let query = tab.lastSearchedQuery
        if query.isEmpty {
            return L10n.tr("在文档中查找文字", "Find text in document")
        }
        if tab.searchMatches.isEmpty {
            return tab.isSearching ? L10n.tr("正在搜索…", "Searching…") : L10n.searchNotFound(query)
        }
        return L10n.searchMatchSummary(current: tab.selectedMatchIndex + 1, total: tab.searchMatches.count)
    }

    @ViewBuilder
    private var content: some View {
        if tab.lastSearchedQuery.isEmpty {
            PanelEmptyState(
                icon: "magnifyingglass",
                title: L10n.tr("全文搜索", "Full-Text Search"),
                subtitle: L10n.tr("在工具栏的搜索框中输入关键词，匹配结果会按页列在这里", "Type keywords in the toolbar search box to list matches by page"),
                isDark: isDark
            )
        } else if tab.searchMatches.isEmpty && tab.isSearching {
            ProgressView()
                .controlSize(.small)
        } else if tab.searchMatches.isEmpty {
            PanelEmptyState(
                icon: "text.magnifyingglass",
                title: L10n.tr("没有匹配结果", "No Matches Found"),
                subtitle: L10n.tr("请尝试其他关键词", "Try another keyword"),
                isDark: isDark
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(pageGroups) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    SearchResultRow(
                                        item: entry.item,
                                        query: tab.lastSearchedQuery,
                                        isSelected: entry.index == tab.selectedMatchIndex,
                                        isDark: isDark
                                    ) {
                                        tab.selectedMatchIndex = entry.index
                                        tab.navigateToPage(entry.item.pageIndex, recordHistory: false)
                                    }
                                    .id(entry.id)
                                }
                            } header: {
                                Text(pageTitle(for: group.pageIndex))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(AppPalette.labelTertiary(isDark))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .background(AppPalette.panelBackground(isDark))
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: tab.selectedMatchIndex) { _, newIdx in
                    guard newIdx >= 0 && newIdx < tab.searchMatches.count else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(tab.searchMatches[newIdx].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var pageGroups: [PageGroup] {
        var groups: [PageGroup] = []
        var entries: [Entry] = []
        var currentPage: Int?
        for (idx, item) in tab.searchMatches.enumerated() {
            if let page = currentPage, page != item.pageIndex {
                groups.append(PageGroup(pageIndex: page, entries: entries))
                entries = []
            }
            currentPage = item.pageIndex
            entries.append(Entry(index: idx, item: item))
        }
        if let page = currentPage {
            groups.append(PageGroup(pageIndex: page, entries: entries))
        }
        return groups
    }

    private func pageTitle(for pageIndex: Int) -> String {
        L10n.pageTitle(tab.displayPageNumber(at: pageIndex))
    }
}

struct SearchResultRow: View {
    let item: SearchMatchItem
    let query: String
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            highlightedSnippet
                .font(.system(size: 12))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected
                        ? AppPalette.accentBlue.opacity(isDark ? 0.22 : 0.12)
                        : (isHovered ? AppPalette.rowHover(isDark) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// Snippet with every occurrence of the query emphasised in the accent color
    private var highlightedSnippet: Text {
        let snippet = item.snippet
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Text(snippet) }

        var result = Text("")
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex,
              let range = snippet.range(of: needle, options: .caseInsensitive, range: cursor..<snippet.endIndex) {
            result = result + Text(snippet[cursor..<range.lowerBound])
            result = result + Text(snippet[range]).bold().foregroundColor(AppPalette.accentBlue)
            cursor = range.upperBound
        }
        return result + Text(snippet[cursor...])
    }
}

// MARK: - PageIndicatorOverlay (bottom-right page counter)

/// Dark page counter PDF Expert shows over the canvas ("55 / 56 of 135"); it fades out a moment after
/// the page changes, reappears on hover and opens Go to Page when clicked.
struct PageIndicatorOverlay: View {
    @ObservedObject var tab: DocumentTabState
    var isSecondaryPane = false

    @State private var isVisible = true
    @State private var isHovered = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let shown = tab.splitMode != .disabled || isVisible || isHovered || showGoToPage
        Button {
            presentGoToPage()
        } label: {
            VStack(spacing: 1) {
                Text(primaryLine)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let secondaryLine {
                    Text(secondaryLine)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .opacity(0.75)
                }
            }
            .animation(AppAnimation.micro, value: primaryLine)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 64)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.86 : 0.78))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("前往页码… (⌥⌘G)", "Go to Page… (⌥⌘G)"))
        .accessibilityLabel(Text("\(L10n.tr("页码", "Page")) \(primaryLine)"))
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .scaleEffect(shown ? 1.0 : 0.96)
        .offset(y: shown ? 0 : 4)
        .animation(AppAnimation.snappy, value: shown)
        .animation(AppAnimation.micro, value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear(perform: flash)
        .onChange(of: pageIndex) { _, _ in
            flash()
        }
        .onChange(of: tab.goToPageRequestToken) { _, _ in
            if tab.targetsSecondaryPane == isSecondaryPane { presentGoToPage() }
        }
        .onChange(of: showGoToPage) { _, isShown in
            if !isShown {
                flash()
            }
        }
        .onDisappear {
            hideTask?.cancel()
        }
        .popover(isPresented: $showGoToPage, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(L10n.tr("前往页码", "Go to Page"))
                        .font(.system(size: 12))
                    TextField(goToPagePlaceholder, text: $goToPageInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        .accessibilityLabel(Text(L10n.tr("页码", "Page")))
                        .onSubmit(commitGoToPage)
                    Button(L10n.tr("前往", "Go"), action: commitGoToPage)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                }
            }
            .padding(12)
        }
    }

    private var pageIndex: Int { isSecondaryPane ? tab.secondaryPageIndex : tab.currentPageIndex }
    private var pageCount: Int { isSecondaryPane ? tab.secondaryPDFDocument?.pageCount ?? 0 : tab.pageCount }
    private var usesBookNumbers: Bool { !isSecondaryPane || tab.secondaryPDFDocument === tab.pdfDocument }
    private var pages: [Int] {
        isSecondaryPane ? tab.layoutMode.visiblePageIndices(at: pageIndex, pageCount: pageCount) : tab.visiblePageIndices
    }

    private var currentPageInput: String {
        usesBookNumbers ? tab.displayPageNumber(at: pageIndex) : "\(pageIndex + 1)"
    }

    private var goToPagePlaceholder: String {
        let numbers = usesBookNumbers ? tab.pageIndicesByLabel.keys.compactMap(Int.init) : []
        guard let first = numbers.min(), let last = numbers.max() else {
            return "1–\(pageCount)"
        }
        return "\(first)–\(last)"
    }

    /// Show book numbers above PDF positions only when they differ; front matter uses "n / total".
    private var primaryLine: String {
        guard usesBookNumbers else { return positionLine }
        let printed = pages.compactMap { tab.printedNumber(at: $0) }
        if !printed.isEmpty, printed != pages.map({ "\($0 + 1)" }) {
            return printed.joined(separator: ", ")
        }
        return positionLine
    }

    private var secondaryLine: String? {
        primaryLine == positionLine ? nil : positionLine
    }

    private var positionLine: String {
        "\(pages.map { "\($0 + 1)" }.joined(separator: ", ")) / \(pageCount)"
    }

    private func flash() {
        isVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }

    private func presentGoToPage() {
        tab.activatePane(isSecondary: isSecondaryPane)
        goToPageInput = currentPageInput
        // A popover can't be anchored to the faded-out counter: show the counter first (⌥⌘G, Go › Go to Page…)
        isVisible = true
        hideTask?.cancel()
        DispatchQueue.main.async {
            showGoToPage = true
        }
    }

    private func commitGoToPage() {
        guard let target = tab.pageIndex(forPageInput: goToPageInput, inSecondaryPane: isSecondaryPane) else {
            NSSound.beep()
            return
        }
        // Close the popover first: navigating re-renders the canvas it is anchored to
        showGoToPage = false
        DispatchQueue.main.async {
            if isSecondaryPane {
                tab.navigateSecondaryPane(to: target)
            } else {
                tab.navigateToPage(target)
            }
        }
    }
}

// MARK: - PageOverviewGridView (toolbar "Page Management" grid, read-only)

struct PageOverviewGridView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    var body: some View {
        let source = tab.activeThumbnailSource
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)],
                    spacing: 26
                ) {
                    ForEach(0..<source.document.pageCount, id: \.self) { pageIdx in
                        PageThumbnailCell(
                            store: store,
                            tab: tab,
                            source: source,
                            pageIndex: pageIdx,
                            maxSize: CGSize(width: 160, height: 208),
                            isDark: isDark
                        ) {
                            tab.navigateToThumbnail(pageIdx)
                            withAnimation(.easeInOut(duration: 0.18)) {
                                tab.isPageOverviewVisible = false
                            }
                        }
                        .id(pageIdx)
                    }
                }
                .padding(28)
            }
            .task {
                // Scrolling from onAppear runs before the lazy grid has a layout and is lost
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                proxy.scrollTo(source.pageIndex, anchor: .center)
            }
        }
        .id(ObjectIdentifier(source.document))
        .background(store.resolvedPDFTheme(isDark: isDark).documentBackgroundColor(isDarkUI: isDark))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("页面概览", "Page Overview")))
    }
}
