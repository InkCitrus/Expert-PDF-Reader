import AppKit
import PDFKit
import SwiftUI

// MARK: - SearchResultsPanel (PDFTextSearchPanelViewController — right dock)

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
                .fill(RDColorPalette.panelSeparator(isDark))
                .frame(height: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(RDColorPalette.panelBackground(isDark))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(RDColorPalette.panelHairline(isDark))
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("搜索结果")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(RDColorPalette.labelPrimary(isDark))
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundColor(RDColorPalette.labelTertiary(isDark))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            PanelHeaderIconButton(icon: "chevron.up", tooltip: "查找上一个 (⇧⌘G)", isDisabled: tab.searchMatches.isEmpty, isDark: isDark) {
                tab.selectPreviousSearchMatch()
            }
            PanelHeaderIconButton(icon: "chevron.down", tooltip: "查找下一个 (⌘G)", isDisabled: tab.searchMatches.isEmpty, isDark: isDark) {
                tab.selectNextSearchMatch()
            }
            PanelHeaderIconButton(icon: "xmark", tooltip: "关闭搜索", isDark: isDark) {
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
            return "在文档中查找文字"
        }
        if tab.searchMatches.isEmpty {
            return "未找到“\(query)”"
        }
        return "第 \(tab.selectedMatchIndex + 1) 处，共 \(tab.searchMatches.count) 处匹配"
    }

    @ViewBuilder
    private var content: some View {
        if tab.lastSearchedQuery.isEmpty {
            PanelEmptyState(
                icon: "magnifyingglass",
                title: "全文搜索",
                subtitle: "在工具栏的搜索框中输入关键词，匹配结果会按页列在这里",
                isDark: isDark
            )
        } else if tab.searchMatches.isEmpty {
            PanelEmptyState(icon: "text.magnifyingglass", title: "没有匹配结果", subtitle: "请尝试其他关键词", isDark: isDark)
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
                                    .foregroundColor(RDColorPalette.labelTertiary(isDark))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .background(RDColorPalette.panelBackground(isDark))
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
        let label = tab.pdfDocument.page(at: pageIndex)?.label ?? "\(pageIndex + 1)"
        return "第 \(label) 页"
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
                .foregroundColor(RDColorPalette.labelPrimary(isDark))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected
                        ? RDColorPalette.accentBlue.opacity(isDark ? 0.22 : 0.12)
                        : (isHovered ? RDColorPalette.rowHover(isDark) : Color.clear)
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
            result = result + Text(snippet[range]).bold().foregroundColor(RDColorPalette.accentBlue)
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

    @State private var isVisible = true
    @State private var isHovered = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button {
            goToPageInput = "\(tab.currentPageIndex + 1)"
            showGoToPage = true
        } label: {
            VStack(spacing: 1) {
                Text(primaryLine)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if let secondaryLine {
                    Text(secondaryLine)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .opacity(0.75)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 64)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("前往页码…")
        .opacity(isVisible || isHovered || showGoToPage ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible || isHovered || showGoToPage)
        .onHover { isHovered = $0 }
        .onAppear(perform: flash)
        .onChange(of: tab.currentPageIndex) { _, _ in
            flash()
        }
        .onDisappear {
            hideTask?.cancel()
        }
        .popover(isPresented: $showGoToPage, arrowEdge: .top) {
            HStack(spacing: 8) {
                Text("前往页码")
                    .font(.system(size: 12))
                TextField("1–\(tab.pageCount)", text: $goToPageInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onSubmit(commitGoToPage)
                Button("前往", action: commitGoToPage)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var pageLabel: String? {
        tab.pdfDocument.page(at: tab.currentPageIndex)?.label
    }

    /// Page label when the PDF defines one (e.g. roman front matter), otherwise "n / total"
    private var primaryLine: String {
        if let label = pageLabel, label != "\(tab.currentPageIndex + 1)" {
            return label
        }
        return "\(tab.currentPageIndex + 1) / \(tab.pageCount)"
    }

    private var secondaryLine: String? {
        if let label = pageLabel, label != "\(tab.currentPageIndex + 1)" {
            return "\(tab.currentPageIndex + 1) / \(tab.pageCount)"
        }
        return nil
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

    private func commitGoToPage() {
        if let num = Int(goToPageInput.trimmingCharacters(in: .whitespaces)),
           num >= 1 && num <= tab.pageCount {
            tab.navigateToPage(num - 1)
            showGoToPage = false
        }
    }
}

// MARK: - PageOverviewGridView (toolbar "Page Management" grid, read-only)

struct PageOverviewGridView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)],
                    spacing: 26
                ) {
                    ForEach(0..<tab.pageCount, id: \.self) { pageIdx in
                        PageThumbnailCell(
                            store: store,
                            tab: tab,
                            pageIndex: pageIdx,
                            maxSize: CGSize(width: 160, height: 208),
                            isDark: isDark
                        ) {
                            tab.navigateToPage(pageIdx)
                            withAnimation(.easeInOut(duration: 0.18)) {
                                tab.isPageOverviewVisible = false
                            }
                        }
                        .id(pageIdx)
                    }
                }
                .padding(28)
            }
            .onAppear {
                proxy.scrollTo(tab.currentPageIndex, anchor: .center)
            }
        }
        .background(store.pdfTheme.documentBackgroundColor(isDarkUI: isDark))
    }
}
