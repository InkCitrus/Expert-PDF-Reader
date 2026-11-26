import AppKit
import PDFKit
import SwiftUI

// MARK: - 2. PDFOutlinePanel (PDFOutlinePanelViewController)

struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    /// Destination point in page space (origin bottom-left); `nil` means the top of the page.
    /// A component of kPDFDestinationUnspecifiedValue keeps the current position on that axis.
    let point: CGPoint?
    let children: [PDFOutlineNode]
    /// Destination's y; `nil` when unspecified (the position on the page is left open)
    var top: CGFloat? { point.flatMap { $0.y < 1_000_000 ? $0.y : nil } }
}

struct PDFOutlinePanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState
    @ObservedObject private var location: ReadingLocation
    let isDark: Bool
    @Environment(\.appAccentColor) private var accent

    init(store: AppStore, tab: DocumentTabState, isDark: Bool) {
        self._store = ObservedObject(wrappedValue: store)
        self._tab = ObservedObject(wrappedValue: tab)
        self._location = ObservedObject(wrappedValue: tab.readingLocation)
        self.isDark = isDark
    }

    struct PinnedSelection: Equatable {
        let nodeID: UUID
        let pageIndex: Int
        var settledLineY: CGFloat?
    }

    @State private var nodes: [PDFOutlineNode] = []
    @State private var expandedIDs: Set<UUID> = []
    @State private var hasLoaded = false
    @State private var isGenerating = false
    @State private var isGeneratedOutline = false
    @State private var generationTask: Task<Void, Never>?
    @State private var pinnedSelection: PinnedSelection?
    @State private var filterText: String = ""
    @State private var filterExpandedIDs: Set<UUID> = []
    @State private var filterCollapsedIDs: Set<UUID> = []
    @State private var userSelectedNodeID: UUID?

    struct OutlineRow: Identifiable, Equatable {
        let node: PDFOutlineNode
        let level: Int
        var id: UUID { node.id }

        static func == (lhs: OutlineRow, rhs: OutlineRow) -> Bool {
            lhs.node.id == rhs.node.id && lhs.level == rhs.level
        }
    }

    var body: some View {
        Group {
            if isGenerating {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AppPalette.panelSeparator(isDark))
                        .frame(height: 1)
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在识别目录…", "Recognizing outline…"))
                            .font(.system(size: 12))
                            .foregroundColor(AppPalette.labelTertiary(isDark))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if hasLoaded && nodes.isEmpty {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(AppPalette.panelSeparator(isDark))
                        .frame(height: 1)
                    if !store.autoGenerateOutline && tab.pdfDocument.outlineRoot == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "list.bullet.indent")
                                .font(.system(size: 26, weight: .light))
                                .foregroundColor(AppPalette.labelQuaternary(isDark))
                            Text(L10n.tr("此文档不包含目录大纲", "This document has no outline"))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(AppPalette.labelSecondary(isDark))
                            Button {
                                hasLoaded = false
                                loadIfNeeded(forceGenerate: true)
                            } label: {
                                Text(L10n.tr("识别目录", "Recognize Outline"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(AppPalette.labelPrimary(isDark))
                                    .padding(.horizontal, 12)
                                    .frame(height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(AppPalette.toolbarControlFill(isDark))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(TactilePressButtonStyle())
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PanelEmptyState(icon: "list.bullet.indent", title: L10n.tr("此文档不包含目录大纲", "This document has no outline"), subtitle: nil, isDark: isDark)
                    }
                }
            } else {
                let rows = visibleRows
                let activeID = activeNodeID(in: rows)
                let hasExpandable = hasExpandableNodes
                let isFiltering = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                VStack(spacing: 0) {
                    outlineFilterBar
                    Rectangle()
                        .fill(AppPalette.panelSeparator(isDark))
                        .frame(height: 1)

                    if rows.isEmpty {
                        PanelEmptyState(
                            icon: "magnifyingglass",
                            title: L10n.tr("没有匹配的章节", "No Matching Sections"),
                            subtitle: nil,
                            isDark: isDark
                        )
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                        let isShowingChildren = index + 1 < rows.count && rows[index + 1].level > row.level
                                        let isRowExpanded = isFiltering ? isShowingChildren : expandedIDs.contains(row.node.id)
                                        PDFOutlineRowView(
                                            node: row.node,
                                            pageLabel: row.node.pageIndex.map { tab.displayPageNumber(at: $0) },
                                            level: row.level,
                                            isExpanded: isRowExpanded,
                                            isActive: row.node.id == activeID,
                                            hasExpandableNodes: hasExpandable,
                                            showsChapterTopSpacing: row.level == 0 && index > 0,
                                            isDark: isDark,
                                            onToggle: { toggle(row.node, isFiltering: isFiltering, isShowingChildren: isShowingChildren) },
                                            onSelect: {
                                                if let pIdx = row.node.pageIndex {
                                                    userSelectedNodeID = row.node.id
                                                    pinnedSelection = PinnedSelection(nodeID: row.node.id, pageIndex: pIdx, settledLineY: nil)
                                                    tab.navigateToPage(pIdx, point: row.node.point)
                                                }
                                            }
                                        )
                                        .id(row.id)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .onAppear {
                                if let activeID {
                                    proxy.scrollTo(activeID, anchor: .center)
                                }
                            }
                            .onChange(of: activeID) { _, newID in
                                guard let newID,
                                      filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                    return
                                }
                                if userSelectedNodeID == newID {
                                    userSelectedNodeID = nil
                                    return
                                }
                                withAnimation(AppAnimation.snappy) {
                                    proxy.scrollTo(newID)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(AppPalette.panelBackground(isDark))
        .onAppear { loadIfNeeded() }
        .onDisappear {
            generationTask?.cancel()
            generationTask = nil
            if !hasLoaded { isGenerating = false }
        }
        .onChange(of: filterText) { _, _ in
            filterExpandedIDs.removeAll()
            filterCollapsedIDs.removeAll()
        }
        .onChange(of: location.pageIndex) { _, _ in
            updatePinnedSelection()
        }
        .onChange(of: location.readingLineY) { _, _ in
            updatePinnedSelection()
        }
        .onChange(of: tab.currentPageIndex) { _, newPage in
            updatePinnedSelection()
            revealCurrentSectionAncestorsIfNeeded(for: newPage)
        }
        .onChange(of: tab.pageScan) { _, _ in
            if (store.autoGenerateOutline || isGeneratedOutline)
                && (nodes.isEmpty || isGeneratedOutline)
                && !isGenerating
                && tab.pdfDocument.outlineRoot == nil {
                hasLoaded = false
                loadIfNeeded(forceGenerate: isGeneratedOutline)
            }
        }
        .onChange(of: store.autoGenerateOutline) { _, enabled in
            if !enabled {
                if isGenerating || isGeneratedOutline {
                    generationTask?.cancel()
                    generationTask = nil
                    isGenerating = false
                    nodes = []
                    isGeneratedOutline = false
                    hasLoaded = true
                }
            } else if nodes.isEmpty && tab.pdfDocument.outlineRoot == nil && !isGenerating {
                hasLoaded = false
                loadIfNeeded()
            }
        }
    }

    private var hasExpandableNodes: Bool {
        nodes.contains { !$0.children.isEmpty }
    }

    private var outlineFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppPalette.labelTertiary(isDark))

            TextField(L10n.tr("筛选目录…", "Filter outline…"), text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .tint(accent)
                .onExitCommand {
                    filterText = ""
                }

            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var visibleRows: [OutlineRow] {
        Self.filteredRows(
            nodes: nodes,
            query: filterText,
            expandedIDs: expandedIDs,
            manuallyExpandedInFilter: filterExpandedIDs,
            manuallyCollapsedInFilter: filterCollapsedIDs
        )
    }

    static func filteredRows(
        nodes: [PDFOutlineNode],
        query: String,
        expandedIDs: Set<UUID>,
        manuallyExpandedInFilter: Set<UUID> = [],
        manuallyCollapsedInFilter: Set<UUID> = []
    ) -> [OutlineRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var rows: [OutlineRow] = []
            func walk(_ list: [PDFOutlineNode], level: Int) {
                for node in list {
                    rows.append(OutlineRow(node: node, level: level))
                    if expandedIDs.contains(node.id) {
                        walk(node.children, level: level + 1)
                    }
                }
            }
            walk(nodes, level: 0)
            return rows
        }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        func appendExpandedSubset(_ children: [PDFOutlineNode], depth: Int, into rows: inout [OutlineRow]) {
            for child in children {
                rows.append(OutlineRow(node: child, level: depth))
                if manuallyExpandedInFilter.contains(child.id) && !manuallyCollapsedInFilter.contains(child.id) {
                    appendExpandedSubset(child.children, depth: depth + 1, into: &rows)
                }
            }
        }

        func walkFiltered(_ list: [PDFOutlineNode], level: Int, ancestorTitles: [String]) -> [OutlineRow] {
            var matched: [OutlineRow] = []
            for node in list {
                let pathTitles = ancestorTitles + [node.title]
                let selfMatches = tokens.allSatisfy { token in
                    pathTitles.contains(where: { tokenMatches(token, in: $0) })
                } && tokens.contains(where: { tokenMatches($0, in: node.title) })

                let matchingChildren = walkFiltered(node.children, level: level + 1, ancestorTitles: pathTitles)
                if !matchingChildren.isEmpty {
                    matched.append(OutlineRow(node: node, level: level))
                    if !manuallyCollapsedInFilter.contains(node.id) {
                        matched.append(contentsOf: matchingChildren)
                    }
                } else if selfMatches {
                    matched.append(OutlineRow(node: node, level: level))
                    if manuallyExpandedInFilter.contains(node.id) && !manuallyCollapsedInFilter.contains(node.id) {
                        appendExpandedSubset(node.children, depth: level + 1, into: &matched)
                    }
                }
            }
            return matched
        }
        return walkFiltered(nodes, level: 0, ancestorTitles: [])
    }

    static func tokenMatches(_ token: String, in title: String) -> Bool {
        let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let foldedToken = token.folding(options: foldOptions, locale: .current)
        let foldedTitle = title.folding(options: foldOptions, locale: .current)
        guard !foldedToken.isEmpty else { return false }

        // Non-ASCII / CJK tokens match as standard folded substrings.
        if foldedToken.unicodeScalars.contains(where: { $0.value > 0x024F }) {
            return foldedTitle.contains(foldedToken)
        }

        let core = foldedToken.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        guard !core.isEmpty else {
            return foldedTitle.contains(foldedToken)
        }

        // Numeric section references (e.g. "4", "4.1") respect numeric and dot boundaries so
        // "4" matches "4 Intro" or "4.1 Setup" without catching "14", "24", or "1.4".
        if core.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || $0 == "." }) {
            var searchStart = foldedTitle.startIndex
            while let range = foldedTitle.range(of: foldedToken, range: searchStart..<foldedTitle.endIndex) {
                let leftOK: Bool
                if range.lowerBound == foldedTitle.startIndex {
                    leftOK = true
                } else {
                    let prevChar = foldedTitle[foldedTitle.index(before: range.lowerBound)]
                    leftOK = !prevChar.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) || $0 == "." })
                }
                let rightOK: Bool
                if foldedToken.last?.isNumber == true, range.upperBound < foldedTitle.endIndex {
                    rightOK = !foldedTitle[range.upperBound].isNumber
                } else {
                    rightOK = true
                }
                if leftOK && rightOK {
                    return true
                }
                searchStart = range.upperBound
            }
            return false
        }

        let romans: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]
        let trailingPunct: Character? = (foldedToken.last == "." || foldedToken.last == ":") ? foldedToken.last : nil
        let segments = alphanumericWordRanges(in: foldedTitle)

        // Roman numeral tokens match Roman section numbers strictly by equality ("II" != "III"/"VII")
        // while still allowing word-prefix matches like "vi" -> "Virtual" when no punctuation suffix is given.
        if romans.contains(core) {
            for seg in segments {
                let word = String(foldedTitle[seg])
                let hasExpectedPunct = trailingPunct.map { punct in
                    seg.upperBound < foldedTitle.endIndex && foldedTitle[seg.upperBound] == punct
                } ?? true
                if romans.contains(word) {
                    if word == core && hasExpectedPunct {
                        return true
                    }
                } else if trailingPunct == nil && word.hasPrefix(core) {
                    return true
                }
            }
            return false
        }

        // Single ASCII letter tokens match word prefixes (or exact letter+punct like "A.").
        if core.count == 1 {
            for seg in segments {
                let word = String(foldedTitle[seg])
                if let punct = trailingPunct {
                    if word == core && seg.upperBound < foldedTitle.endIndex && foldedTitle[seg.upperBound] == punct {
                        return true
                    }
                } else if word.hasPrefix(core) {
                    return true
                }
            }
            return false
        }

        return foldedTitle.contains(foldedToken)
    }

    private static func alphanumericWordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var currentStart: String.Index?
        for idx in text.indices {
            let isWordChar = text[idx].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if isWordChar {
                if currentStart == nil { currentStart = idx }
            } else if let start = currentStart {
                ranges.append(start..<idx)
                currentStart = nil
            }
        }
        if let start = currentStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    private func revealCurrentSectionAncestorsIfNeeded(for page: Int) {
        guard filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nodes.isEmpty else { return }
        if userSelectedNodeID != nil {
            userSelectedNodeID = nil
            return
        }
        let ancestors = ancestorIDs(ofPage: page)
        guard !ancestors.isEmpty, !Set(ancestors).isSubset(of: expandedIDs) else { return }
        withAnimation(AppAnimation.snappy) {
            expandedIDs.formUnion(ancestors)
        }
    }

    /// The section being read: the last visible row starting before the current page, or on it above the
    /// reading line, so the right one of several sections on the same page is highlighted.
    /// The page and the reading line both come from `location` (the top-of-view destination), published
    /// together. Mixing in `tab.currentPageIndex` — which PDFKit derives from the middle of the view and
    /// updates on a different cadence — made the highlight flip back and forth while scrolling.
    private func activeNodeID(in rows: [OutlineRow]) -> UUID? {
        if let pinned = pinnedSelection,
           (location.pageIndex == pinned.pageIndex || tab.currentPageIndex == pinned.pageIndex),
           rows.contains(where: { $0.node.id == pinned.nodeID }) {
            return pinned.nodeID
        }
        return Self.activeSection(in: rows.map(\.node), locationPage: location.pageIndex,
                                  readingLineY: location.readingLineY, fallbackPage: tab.currentPageIndex)
    }

    private func updatePinnedSelection() {
        pinnedSelection = Self.reconciledPinnedSelection(
            pinnedSelection,
            locationPage: location.pageIndex,
            readingLineY: location.readingLineY,
            currentPage: tab.currentPageIndex
        )
    }

    static func reconciledPinnedSelection(
        _ pinned: PinnedSelection?,
        locationPage: Int,
        readingLineY: CGFloat,
        currentPage: Int
    ) -> PinnedSelection? {
        guard var pinned else { return nil }
        if locationPage == pinned.pageIndex {
            if pinned.settledLineY == nil {
                pinned.settledLineY = readingLineY
                return pinned
            } else if abs(readingLineY - pinned.settledLineY!) > 18 {
                return nil
            }
            return pinned
        }
        if locationPage >= 0 && currentPage != pinned.pageIndex {
            return nil
        }
        return pinned
    }

    static func activeSection(in nodes: [PDFOutlineNode], locationPage: Int,
                              readingLineY: CGFloat, fallbackPage: Int) -> UUID? {
        let page = locationPage >= 0 ? locationPage : fallbackPage
        return nodes.last(where: { node in
            guard let nodePage = node.pageIndex, nodePage <= page else { return false }
            guard nodePage == page, let top = node.top else { return true }
            return top >= readingLineY
        })?.id
    }

    private func toggle(_ node: PDFOutlineNode, isFiltering: Bool = false, isShowingChildren: Bool = false) {
        withAnimation(AppAnimation.snappy) {
            if isFiltering {
                if isShowingChildren {
                    filterCollapsedIDs.insert(node.id)
                    filterExpandedIDs.remove(node.id)
                } else {
                    filterCollapsedIDs.remove(node.id)
                    filterExpandedIDs.insert(node.id)
                }
            } else if expandedIDs.contains(node.id) {
                expandedIDs.remove(node.id)
            } else {
                expandedIDs.insert(node.id)
            }
        }
    }

    private func loadIfNeeded(forceGenerate: Bool = false) {
        guard !hasLoaded, !isGenerating else { return }
        if let root = tab.pdfDocument.outlineRoot {
            let embedded = buildOutlineNodes(from: root)
            if !embedded.isEmpty {
                nodes = embedded
                isGeneratedOutline = false
                hasLoaded = true
                configureExpansion()
                return
            }
        }

        if !forceGenerate && !store.autoGenerateOutline {
            nodes = []
            isGeneratedOutline = false
            hasLoaded = true
            return
        }

        if let cached = tab.cachedGeneratedOutline, cached.scan == tab.pageScan {
            nodes = buildGeneratedNodes(cached.entries)
            isGeneratedOutline = true
            hasLoaded = true
            configureExpansion()
            return
        }

        isGenerating = true
        let url = tab.documentID.url
        let password = tab.password
        let needsScan = tab.pageScan == nil && tab.pageCount >= 16
        generationTask = Task {
            if needsScan {
                let scanWorker = Task.detached(priority: .utility) {
                    await BookPageScanQueue.shared.scan(url: url, password: password)
                }
                let scan = await withTaskCancellationHandler {
                    await scanWorker.value
                } onCancel: {
                    scanWorker.cancel()
                }
                if !Task.isCancelled, let scan {
                    tab.applyPageScanIfNeeded(scan)
                }
            }
            guard !Task.isCancelled else {
                isGenerating = false
                generationTask = nil
                return
            }
            let scanSnapshot = tab.pageScan
            let oddIndexShift = scanSnapshot?.printedNumbers?.oddIndexShift ?? 0
            var labels = tab.pageIndicesByLabel
            for (label, indices) in tab.pageIndicesByLabel {
                let lower = label.lowercased()
                if labels[lower] == nil { labels[lower] = indices }
            }
            let worker = Task.detached(priority: .utility) {
                guard let document = PDFDocumentLoader.openCopy(of: url, password: password) else {
                    return [GeneratedOutlineEntry]()
                }
                return AutomaticOutlineGenerator.generate(document: document, pageLabels: labels, oddIndexShift: oddIndexShift)
            }
            let generated = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            isGenerating = false
            generationTask = nil
            guard !Task.isCancelled else { return }
            tab.cachedGeneratedOutline = (scan: scanSnapshot, entries: generated)
            nodes = buildGeneratedNodes(generated)
            isGeneratedOutline = true
            hasLoaded = true
            configureExpansion()
        }
    }

    private func configureExpansion() {
        // Short outlines open fully; long ones only reveal the branch holding the current page
        var parentIDs: [UUID] = []
        var nodeCount = 0
        func collect(_ list: [PDFOutlineNode]) {
            for node in list {
                nodeCount += 1
                if !node.children.isEmpty {
                    parentIDs.append(node.id)
                    collect(node.children)
                }
            }
        }
        collect(nodes)
        expandedIDs = nodeCount <= 30 ? Set(parentIDs) : Set(ancestorIDs(ofPage: tab.currentPageIndex))
    }

    private func buildGeneratedNodes(_ entries: [GeneratedOutlineEntry]) -> [PDFOutlineNode] {
        final class Builder {
            let entry: GeneratedOutlineEntry
            var children: [Builder] = []
            init(_ entry: GeneratedOutlineEntry) { self.entry = entry }
        }
        var roots: [Builder] = []
        var stack: [(level: Int, node: Builder)] = []
        for entry in entries {
            let level = max(0, entry.level)
            while stack.last.map({ $0.level >= level }) == true { stack.removeLast() }
            let node = Builder(entry)
            if let parent = stack.last?.node { parent.children.append(node) }
            else { roots.append(node) }
            stack.append((level, node))
        }
        func freeze(_ builders: [Builder]) -> [PDFOutlineNode] {
            builders.map {
                PDFOutlineNode(title: $0.entry.title, pageIndex: $0.entry.pageIndex,
                               point: $0.entry.destinationPoint, children: freeze($0.children))
            }
        }
        return freeze(roots)
    }

    private func ancestorIDs(ofPage page: Int) -> [UUID] {
        var best: [UUID] = []
        func walk(_ list: [PDFOutlineNode], path: [UUID]) {
            for node in list {
                if let pIdx = node.pageIndex, pIdx <= page {
                    best = path
                }
                walk(node.children, path: path + [node.id])
            }
        }
        walk(nodes, path: [])
        return best
    }

    private func buildOutlineNodes(from parent: PDFOutline) -> [PDFOutlineNode] {
        var result: [PDFOutlineNode] = []
        for i in 0..<parent.numberOfChildren {
            guard let child = parent.child(at: i) else { continue }
            var pageIdx: Int?
            var point: CGPoint?
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            if let page = destination?.page {
                let idx = tab.pdfDocument.index(for: page)
                if idx >= 0 && idx < tab.pageCount {
                    pageIdx = idx
                    point = destination?.point
                }
            }
            result.append(
                PDFOutlineNode(
                    title: child.label ?? L10n.tr("未命名章节", "Untitled Section"),
                    pageIndex: pageIdx,
                    point: point,
                    children: buildOutlineNodes(from: child)
                )
            )
        }
        return result
    }
}

struct PDFOutlineRowView: View {
    let node: PDFOutlineNode
    let pageLabel: String?
    let level: Int
    let isExpanded: Bool
    let isActive: Bool
    let hasExpandableNodes: Bool
    let showsChapterTopSpacing: Bool
    let isDark: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.appAccentColor) private var accent

    private var titleFont: Font {
        if level == 0 {
            return .system(size: 12.5, weight: .semibold)
        } else if level == 1 {
            return .system(size: 12, weight: isActive ? .semibold : .regular)
        } else {
            return .system(size: 11.5, weight: isActive ? .semibold : .regular)
        }
    }

    private var titleColor: Color {
        if isActive || level == 0 || isHovered { return AppPalette.labelPrimary(isDark) }
        return AppPalette.labelSecondary(isDark)
    }

    private var pillBackground: Color {
        if isActive {
            return AppPalette.sidebarRowSelected(isDark)
        }
        if isHovered {
            return AppPalette.sidebarRowHover(isDark)
        }
        return .clear
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if hasExpandableNodes {
                Group {
                    if node.children.isEmpty {
                        Color.clear
                    } else {
                        Button(action: onToggle) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(isActive ? AppPalette.labelSecondary(isDark) : AppPalette.labelTertiary(isDark))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .animation(AppAnimation.snappy, value: isExpanded)
                                .frame(width: 13, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 13, height: 14)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3.5 }
            }

            Text(node.title)
                .font(titleFont)
                .foregroundColor(titleColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

            if let label = pageLabel {
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundColor(isActive ? AppPalette.labelSecondary(isDark) : AppPalette.labelTertiary(isDark))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, (hasExpandableNodes ? 6 : 8) + CGFloat(level) * 13)
        .padding(.trailing, 8)
        .padding(.vertical, level == 0 ? 6 : 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(pillBackground)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(AppPalette.sidebarRowSelectedBorder(isDark), lineWidth: 0.5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, showsChapterTopSpacing ? 6 : 1)
        .padding(.bottom, 1)
        .contentShape(Rectangle())
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isActive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(pageLabel.map { "\(node.title), \(L10n.pageTitle($0))" } ?? node.title))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onSelect)
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
