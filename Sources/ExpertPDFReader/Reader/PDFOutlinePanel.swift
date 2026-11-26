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
                let expandableIDs = allExpandableIDs
                let hasExpandableNodes = !expandableIDs.isEmpty
                let areAllExpanded = hasExpandableNodes && expandableIDs.isSubset(of: expandedIDs)
                VStack(spacing: 0) {
                    outlineFilterBar(
                        hasExpandableNodes: hasExpandableNodes,
                        areAllExpanded: areAllExpanded,
                        expandableIDs: expandableIDs
                    )
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
                                        PDFOutlineRowView(
                                            node: row.node,
                                            pageLabel: row.node.pageIndex.map { tab.displayPageNumber(at: $0) },
                                            level: row.level,
                                            isExpanded: expandedIDs.contains(row.node.id),
                                            isActive: row.node.id == activeID,
                                            hasExpandableNodes: hasExpandableNodes,
                                            showsChapterTopSpacing: row.level == 0 && index > 0,
                                            isDark: isDark,
                                            onToggle: { toggle(row.node) },
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

    private var allExpandableIDs: Set<UUID> {
        var ids = Set<UUID>()
        func collect(_ list: [PDFOutlineNode]) {
            for node in list where !node.children.isEmpty {
                ids.insert(node.id)
                collect(node.children)
            }
        }
        collect(nodes)
        return ids
    }

    private func outlineFilterBar(
        hasExpandableNodes: Bool,
        areAllExpanded: Bool,
        expandableIDs: Set<UUID>
    ) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppPalette.labelTertiary(isDark))

                TextField(L10n.tr("筛选目录…", "Filter outline…"), text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .tint(accent)

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
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07), lineWidth: 0.5)
            )

            if hasExpandableNodes && filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    withAnimation(AppAnimation.snappy) {
                        expandedIDs = areAllExpanded ? [] : expandableIDs
                    }
                } label: {
                    Image(systemName: areAllExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(AppPalette.labelSecondary(isDark))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07), lineWidth: 0.5)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(TactilePressButtonStyle())
                .help(areAllExpanded ? L10n.tr("折叠全部", "Collapse All") : L10n.tr("展开全部", "Expand All"))
                .accessibilityLabel(Text(areAllExpanded ? L10n.tr("折叠全部", "Collapse All") : L10n.tr("展开全部", "Expand All")))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var visibleRows: [OutlineRow] {
        Self.filteredRows(
            nodes: nodes,
            query: filterText,
            expandedIDs: expandedIDs,
            pageLabel: { tab.displayPageNumber(at: $0) }
        )
    }

    static func filteredRows(
        nodes: [PDFOutlineNode],
        query: String,
        expandedIDs: Set<UUID>,
        pageLabel: (Int) -> String
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

        func walkFiltered(_ list: [PDFOutlineNode], level: Int) -> [OutlineRow] {
            var matched: [OutlineRow] = []
            for node in list {
                let titleMatches = node.title.localizedCaseInsensitiveContains(trimmed)
                let pageMatches = node.pageIndex.map(pageLabel)?.localizedCaseInsensitiveContains(trimmed) ?? false
                let selfMatches = titleMatches || pageMatches
                let matchingChildren = walkFiltered(node.children, level: level + 1)
                if !matchingChildren.isEmpty {
                    matched.append(OutlineRow(node: node, level: level))
                    matched.append(contentsOf: matchingChildren)
                } else if selfMatches {
                    matched.append(OutlineRow(node: node, level: level))
                    if expandedIDs.contains(node.id) {
                        func appendExpanded(_ children: [PDFOutlineNode], depth: Int) {
                            for child in children {
                                matched.append(OutlineRow(node: child, level: depth))
                                if expandedIDs.contains(child.id) {
                                    appendExpanded(child.children, depth: depth + 1)
                                }
                            }
                        }
                        appendExpanded(node.children, depth: level + 1)
                    }
                }
            }
            return matched
        }
        return walkFiltered(nodes, level: 0)
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

    private func toggle(_ node: PDFOutlineNode) {
        withAnimation(AppAnimation.snappy) {
            if expandedIDs.contains(node.id) {
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 16, height: 16)
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
        .padding(.leading, (hasExpandableNodes ? 7 : 10) + CGFloat(level) * 13)
        .padding(.trailing, 9)
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
