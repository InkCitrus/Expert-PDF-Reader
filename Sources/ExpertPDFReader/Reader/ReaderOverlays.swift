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
                withAnimation(AppAnimation.panel) {
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
                    withAnimation(AppAnimation.snappy) {
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

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            highlightedSnippet
                .font(.system(size: 12))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? AppPalette.sidebarRowSelected(isDark)
                                : (isHovered ? AppPalette.sidebarRowHover(isDark) : Color.clear)
                        )
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(AppPalette.sidebarRowSelectedBorder(isDark), lineWidth: 0.5)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isSelected)
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
            result = result + Text(snippet[range]).bold().foregroundColor(accent)
            cursor = range.upperBound
        }
        return result + Text(snippet[cursor...])
    }
}

// MARK: - PageIndicatorOverlay (bottom-right page counter)

/// Non-blocking tracking area in the canvas corner so hovering reveals faded canvas HUDs
/// without intercepting clicks, drags, or text selection on the PDF underneath.
struct PageIndicatorRevealArea: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PageIndicatorRevealView { PageIndicatorRevealView() }
    func updateNSView(_ view: PageIndicatorRevealView, context: Context) {
        view.onHover = onHover
    }
}

final class PageIndicatorRevealView: NSView {
    var onHover: ((Bool) -> Void)?
    // Omit .enabledDuringMouseDrag so dragging a text selection across the corner never pops the pill up.
    private lazy var hoverArea = NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
        owner: self,
        userInfo: nil
    )
    private var pendingExit: Task<Void, Never>?
    private var isHovered = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let area = hoverArea
        if !trackingAreas.contains(where: { $0 === area }) { addTrackingArea(area) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pendingExit?.cancel()
            pendingExit = nil
            if isHovered {
                isHovered = false
                onHover?(false)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(for: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(for: event) }
    override func mouseExited(with event: NSEvent) { updateHover(for: event) }

    private func updateHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.intersection(visibleRect).contains(point) {
            pendingExit?.cancel()
            pendingExit = nil
            if !isHovered {
                isHovered = true
                onHover?(true)
            }
        } else if isHovered && pendingExit == nil {
            pendingExit = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                pendingExit = nil
                isHovered = false
                onHover?(false)
            }
        }
    }
}

/// Page counter shown over the bottom-right canvas ("55 / 56 of 135"); it fades out after
/// page changes unless pinned, reappears when hovering the corner, and opens Go to Page when clicked.
struct PageIndicatorOverlay: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    var isSecondaryPane = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccentColor) private var accent
    @State private var isVisible = true
    @State private var isHovered = false
    @State private var isInRevealZone = false
    @State private var showGoToPage = false
    @State private var goToPageInput = ""
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let isDark = colorScheme == .dark
        let pdfTheme = store.resolvedPDFTheme(isDark: isDark)
        let shown = store.alwaysShowPageIndicator || tab.splitMode != .disabled || isVisible || isHovered || isInRevealZone || showGoToPage

        ZStack(alignment: .bottomTrailing) {
            PageIndicatorRevealArea { isInRevealZone = $0 }
                .frame(width: 148, height: 76)

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
                            .opacity(0.78)
                    }
                }
                .animation(AppAnimation.micro, value: primaryLine)
                .foregroundColor(AppPalette.pageIndicatorForeground(pdfTheme: pdfTheme, isDarkUI: isDark))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 64)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppPalette.pageIndicatorBackground(pdfTheme: pdfTheme, isDarkUI: isDark, isHovered: isHovered))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(AppPalette.pageIndicatorBorder(pdfTheme: pdfTheme, isDarkUI: isDark, isHovered: isHovered), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(pdfTheme == .night || isDark ? 0.45 : 0.18), radius: 6, x: 0, y: 2)
                )
                .animation(AppAnimation.micro, value: pdfTheme)
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
            .contextMenu {
                Button {
                    store.alwaysShowPageIndicator.toggle()
                } label: {
                    if store.alwaysShowPageIndicator {
                        Label(L10n.tr("始终显示页码浮窗", "Always Show Page Counter"), systemImage: "checkmark")
                    } else {
                        Text(L10n.tr("始终显示页码浮窗", "Always Show Page Counter"))
                    }
                }
            }
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
                            .tint(accent)
                            .frame(width: 84)
                            .accessibilityLabel(Text(L10n.tr("页码", "Page")))
                            .onSubmit(commitGoToPage)
                        Button(L10n.tr("前往", "Go"), action: commitGoToPage)
                            .keyboardShortcut(.defaultAction)
                            .tint(accent)
                            .controlSize(.small)
                    }
                    if usesBookNumbers && !tab.pageIndicesByLabel.isEmpty {
                        Text(L10n.tr("输入书籍页码，或输入 (n) 跳至第 n 页", "Enter Book Page, or (n) for PDF Page n"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .padding(16)
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
        let shift = tab.pageScan?.printedNumbers?.oddIndexShift ?? 0
        let orderedPages = shift == 0 ? pages : pages.sorted {
            ($0 + ($0 % 2 == 1 ? shift : 0)) < ($1 + ($1 % 2 == 1 ? shift : 0))
        }
        let printed = orderedPages.compactMap { tab.printedNumber(at: $0) }
        if !printed.isEmpty, printed != orderedPages.map({ "\($0 + 1)" }) {
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

// MARK: - JumpBackBanner (bottom-left navigation history HUD)

/// Floating navigation history HUD in the bottom-left corner matching `PageIndicatorOverlay` 1:1.
/// Flashes briefly after internal link or multi-page jumps and reveals on corner hover whenever back/forward history exists.
struct JumpBackBanner: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    var forceVisible: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false
    @State private var isHovered = false
    @State private var isInRevealZone = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let isDark = colorScheme == .dark
        let pdfTheme = store.resolvedPDFTheme(isDark: isDark)
        let foreground = AppPalette.pageIndicatorForeground(pdfTheme: pdfTheme, isDarkUI: isDark)
        let hasHistory = tab.canGoBack || tab.canGoForward
        let shown = forceVisible || (hasHistory && ((isVisible && tab.canGoBack && tab.jumpBackDestination != nil) || isHovered || isInRevealZone))

        ZStack(alignment: .bottomLeading) {
            PageIndicatorRevealArea { isInRevealZone = $0 }
                .frame(width: 148, height: 76)

            Group {
                if hasHistory {
                    HStack(spacing: 0) {
                        if let backIdx = tab.jumpBackDestination?.pageIndex ?? tab.backDestinationPageIndex, tab.canGoBack {
                            let showsForwardSegment = tab.canGoForward && (isHovered || isInRevealZone || forceVisible)
                            Button {
                                hideTask?.cancel()
                                isVisible = false
                                tab.goBack()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.backward")
                                        .font(.system(size: 11, weight: .semibold))
                                        .opacity(0.82)
                                    Text(L10n.backToPage(tab.cleanPageLabel(at: backIdx)))
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                                .padding(.leading, 11)
                                .padding(.trailing, showsForwardSegment ? 9 : 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.parenthetical(L10n.tr("返回", "Back"), "⌘["))
                            .accessibilityLabel(Text(L10n.backToPage(tab.cleanPageLabel(at: backIdx))))

                            if showsForwardSegment {
                                Rectangle()
                                    .fill(foreground.opacity(0.22))
                                    .frame(width: 1, height: 13)

                                Button {
                                    hideTask?.cancel()
                                    isVisible = false
                                    tab.goForward()
                                } label: {
                                    Image(systemName: "chevron.forward")
                                        .font(.system(size: 11, weight: .semibold))
                                        .opacity(0.85)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.parenthetical(L10n.tr("前进", "Forward"), "⌘]"))
                                .accessibilityLabel(Text(L10n.tr("前进", "Forward")))
                            }
                        } else if let fwdIdx = tab.forwardDestinationPageIndex, tab.canGoForward {
                            Button {
                                hideTask?.cancel()
                                isVisible = false
                                tab.goForward()
                            } label: {
                                HStack(spacing: 5) {
                                    Text(L10n.jumpToPage(tab.cleanPageLabel(at: fwdIdx)))
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                    Image(systemName: "chevron.forward")
                                        .font(.system(size: 11, weight: .semibold))
                                        .opacity(0.82)
                                }
                                .padding(.leading, 12)
                                .padding(.trailing, 11)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.parenthetical(L10n.tr("前进", "Forward"), "⌘]"))
                            .accessibilityLabel(Text(L10n.jumpToPage(tab.cleanPageLabel(at: fwdIdx))))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(foreground)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(AppPalette.pageIndicatorBackground(pdfTheme: pdfTheme, isDarkUI: isDark, isHovered: isHovered))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(AppPalette.pageIndicatorBorder(pdfTheme: pdfTheme, isDarkUI: isDark, isHovered: isHovered), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(pdfTheme == .night || isDark ? 0.45 : 0.18), radius: 6, x: 0, y: 2)
                    )
                    .animation(AppAnimation.micro, value: pdfTheme)
                    .onHover { hovering in
                        isHovered = hovering
                        if hovering {
                            hideTask?.cancel()
                        } else if isVisible {
                            flash()
                        }
                    }
                }
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .scaleEffect(shown ? 1.0 : 0.96)
            .offset(y: shown ? 0 : 4)
            .animation(AppAnimation.snappy, value: shown)
            .animation(AppAnimation.micro, value: isHovered)
            .padding(16)
        }
        .onChange(of: tab.jumpBackToken) { _, _ in
            guard tab.canGoBack, tab.jumpBackDestination != nil else { return }
            flash()
        }
        .onChange(of: hasHistory) { _, available in
            if !available {
                hideTask?.cancel()
                isVisible = false
            }
        }
        .onDisappear {
            hideTask?.cancel()
        }
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
}

// MARK: - PageOverviewGridView (toolbar "Page Management" grid, read-only)

struct PageOverviewGridView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    let isDark: Bool

    var body: some View {
        let source = tab.activeThumbnailSource
        let pdfTheme = store.resolvedPDFTheme(isDark: isDark)
        let selectedPages = tab.selectedThumbnailPages(in: source)
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
                            withAnimation(AppAnimation.panel) {
                                tab.isPageOverviewVisible = false
                            }
                        }
                        .id(pageIdx)
                    }
                }
                .padding(.top, 28)
                .padding(.horizontal, 28)
                .padding(.bottom, selectedPages.isEmpty ? 28 : 80)
            }
            .task {
                // Scrolling from onAppear runs before the lazy grid has a layout and is lost
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                proxy.scrollTo(source.pageIndex, anchor: .center)
            }
        }
        .id(ObjectIdentifier(source.document))
        .background(pdfTheme.documentBackgroundColor(isDarkUI: isDark))
        .overlay(alignment: .bottom) {
            if !selectedPages.isEmpty {
                let ordered = selectedPages.sorted()
                let canExport = PageImageClipboard.canCopy(source.document.page(at: ordered[0]))
                let targetWindow = store.window(forTabID: tab.id)
                let foreground = AppPalette.pageIndicatorForeground(pdfTheme: pdfTheme, isDarkUI: isDark)
                HStack(spacing: 10) {
                    Text(L10n.selectedPagesCount(ordered.count))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(AppAnimation.micro, value: ordered.count)
                        .foregroundColor(foreground)

                    Rectangle()
                        .fill(foreground.opacity(0.22))
                        .frame(width: 1, height: 14)

                    Button {
                        tab.rotatePages(ordered, in: source.document, clockwise: false)
                    } label: {
                        Image(systemName: "rotate.left")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(TactilePressButtonStyle())
                    .foregroundColor(foreground.opacity(0.88))
                    .help(L10n.tr("向左旋转", "Rotate Left"))
                    .accessibilityLabel(Text(L10n.tr("向左旋转", "Rotate Left")))

                    Button {
                        tab.rotatePages(ordered, in: source.document, clockwise: true)
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(TactilePressButtonStyle())
                    .foregroundColor(foreground.opacity(0.88))
                    .help(L10n.tr("向右旋转", "Rotate Right"))
                    .accessibilityLabel(Text(L10n.tr("向右旋转", "Rotate Right")))

                    Rectangle()
                        .fill(foreground.opacity(0.22))
                        .frame(width: 1, height: 14)

                    Button(L10n.tr("导出…", "Export…")) {
                        tab.beginExportPanel(
                            in: targetWindow,
                            initialPages: ordered,
                            source: source,
                            session: store.windowSession(forTabID: tab.id)
                        )
                    }
                    .buttonStyle(TactilePressButtonStyle())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(canExport ? foreground : foreground.opacity(0.38))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
                    .disabled(!canExport)

                    Button {
                        tab.clearThumbnailSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(foreground.opacity(0.75))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(TactilePressButtonStyle())
                    .help(L10n.tr("取消选择", "Deselect All"))
                    .accessibilityLabel(Text(L10n.tr("取消选择", "Deselect All")))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppPalette.pageIndicatorBackground(pdfTheme: pdfTheme, isDarkUI: isDark, isHovered: false))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(AppPalette.pageIndicatorBorder(pdfTheme: pdfTheme, isDarkUI: isDark, isHovered: false), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(pdfTheme == .night || isDark ? 0.45 : 0.18), radius: 6, x: 0, y: 2)
                )
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.snappy, value: selectedPages.isEmpty)
        .onExitCommand {
            if !selectedPages.isEmpty {
                tab.clearThumbnailSelection()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("页面概览", "Page Overview")))
    }
}

// MARK: - ExportActivityToast

/// Floating bottom HUD pill showing background export progress (with Cancel) and completion (with Show in Finder).
struct ExportActivityToast: View {
    let state: ExportActivityState
    let pdfTheme: PDFViewTheme
    let isDarkUI: Bool
    let onCancel: () -> Void
    let onReveal: () -> Void
    let onDismiss: () -> Void
    let onHoverChanged: (Bool) -> Void

    @Environment(\.appAccentColor) private var accent
    @State private var isHovered = false

    var body: some View {
        let foreground = AppPalette.pageIndicatorForeground(pdfTheme: pdfTheme, isDarkUI: isDarkUI)
        HStack(spacing: 10) {
            switch state.phase {
            case .exporting(let completed, let total, let formatLabel):
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)

                Text(L10n.exportingProgressText(completed: completed, total: total, formatName: formatLabel))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundColor(foreground)

                if total > 1 {
                    let fraction = max(0, min(1, CGFloat(completed) / CGFloat(total)))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(accent)
                            .frame(width: 56 * fraction)
                    }
                    .frame(width: 56, height: 3.5)
                    .animation(AppAnimation.micro, value: completed)
                }

                Rectangle()
                    .fill(foreground.opacity(0.22))
                    .frame(width: 1, height: 14)

                Button(L10n.tr("取消", "Cancel"), action: onCancel)
                    .buttonStyle(TactilePressButtonStyle())
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(foreground.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )

            case .completed(let pageCount, let formatLabel, _, let isFolder):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AppPalette.systemGreen)
                    .symbolEffect(.bounce, value: state.id)

                Text(L10n.exportCompletedText(pageCount: pageCount, formatName: formatLabel, isFolder: isFolder))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(foreground)

                Rectangle()
                    .fill(foreground.opacity(0.22))
                    .frame(width: 1, height: 14)

                Button(L10n.tr("在 Finder 中显示", "Show in Finder"), action: onReveal)
                    .buttonStyle(TactilePressButtonStyle())
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(foreground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accent.opacity(0.85))
                    )

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(foreground.opacity(0.75))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(TactilePressButtonStyle())
                .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppPalette.pageIndicatorBackground(pdfTheme: pdfTheme, isDarkUI: isDarkUI, isHovered: isHovered))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(AppPalette.pageIndicatorBorder(pdfTheme: pdfTheme, isDarkUI: isDarkUI, isHovered: isHovered), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(pdfTheme == .night || isDarkUI ? 0.45 : 0.18), radius: 6, x: 0, y: 2)
        )
        .animation(AppAnimation.micro, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
    }
}
