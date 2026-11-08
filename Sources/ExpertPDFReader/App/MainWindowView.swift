import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window:
/// Document tabs live in the titlebar or an independent floating sidebar.
/// Enforces a minimum window width of `600pt`.
public struct MainWindowView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("expertPDFReader.sidebarTabsWidth") private var sidebarWidth: Double?
    @State private var sidebarResizeWidth: CGFloat?
    @State private var isSidebarHovered = false
    @State private var isSidebarDragging = false
    @State private var isSidebarMenuTracking = false
    @State private var sidebarExpandedContent = false
    @State private var isDropTargeted = false
    private var isDark: Bool { colorScheme == .dark }

    public static let tabStripHeight: CGFloat = 40

    public init(store: AppStore, session: ReaderWindowSession? = nil) {
        self.store = store
        self.session = session ?? store.primarySession
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let tab = session.activeDocumentTab {
                ReaderToolbarView(store: store, tab: tab)
                    .id(tab.id)
                    .transaction { $0.animation = nil }
            }
            GeometryReader { geometry in
                windowContent(windowWidth: geometry.size.width)
            }
        }
        .background(AppPalette.homeContentBackground(isDark), ignoresSafeAreaEdges: [])
        .overlay {
            if isDropTargeted && session.activeDocumentTab != nil {
                DropOverlayView(isDark: isDark)
                    .padding(14)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(AppAnimation.snappy, value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            PDFFileDrop.open(providers) { url in
                store.openDocument(at: url, in: session.id)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            isSidebarMenuTracking = isSidebarHovered
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isSidebarMenuTracking = false
        }
        .toolbar {
            // Keep the compact native toolbar alive: SwiftUI removes an empty one and shrinks tabs to 32pt.
            // The titlebar accessory supplies the content of this 40pt row.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
        }
        .sheet(isPresented: $session.isShortcutsSheetPresented) {
            ShortcutsAndTipsSheetView(store: store, session: session)
        }
        // Full-size content extends under the native traffic lights. Its backdrop must match the accessory.
        .background(AppPalette.tabStripBackground(isDark))
        .background(
            WindowChromeConfigurator(
                windowTitle: store.windowTitle(for: session),
                representedURL: store.windowRepresentedURL(for: session),
                tabBar: AnyView(titlebarContent),
                tabBarBackground: NSColor(AppPalette.tabStripBackground(isDark)),
                onWindowAttached: { window in
                    session.nsWindow = window
                },
                onWindowBecameActive: {
                    store.activateWindowSession(session.id)
                }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    private var titlebarContent: some View {
        let homeTitle = L10n.tr("主页", "Home")
        let sidebarVisible = store.isLeftPanelVisible(in: session)
        let sidebarTitle = sidebarVisible
            ? L10n.tr("隐藏左边面板", "Hide Left Panel") : L10n.tr("显示左边面板", "Show Left Panel")
        let controlsWidth: CGFloat = 88
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                ToolbarIconButton(icon: "sidebar.left", tooltip: "\(sidebarTitle) (⌘B)",
                                  isActive: sidebarVisible, isDark: isDark) {
                    store.toggleLeftPanel(in: session)
                }
                ToolbarIconButton(icon: "house.fill", tooltip: homeTitle,
                                  isActive: session.activeDocumentTab == nil, isDark: isDark, action: goHome)
                    .overlay { WindowDragArea(onClick: goHome) }
            }
            .frame(width: controlsWidth)
            if store.tabsInSidebar {
                Text(store.windowTitle(for: session))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppPalette.labelPrimary(isDark))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, controlsWidth)
            } else {
                TabBarView(store: store, session: session, isDark: isDark)
            }
        }
        .background(WindowDragArea())
        .background(AppPalette.tabStripBackground(isDark))
    }

    private func goHome() {
        store.activateWindowSession(session.id)
        store.selectHomeTab(in: session.id)
    }

    private func windowContent(windowWidth: CGFloat) -> some View {
        let showsNavigation = store.isLeftPanelVisible(in: session)
        let railWidth: CGFloat = store.tabsInSidebar ? 48 : 0
        let defaultWidth = session.activeDocumentTab == nil
            ? HomeTabRootView.sidebarWidth : ReaderLeftSidebarView.width
        let preferredWidth = sidebarWidth.map { CGFloat($0) } ?? defaultWidth
        let minimumWidth: CGFloat = 180
        let maximumWidth = max(minimumWidth, min(480, windowWidth - railWidth - 360))
        let gripWidth: CGFloat = 12
        func boundedWidth(_ width: CGFloat) -> CGFloat {
            min(max(width, minimumWidth), maximumWidth)
        }
        let width = boundedWidth(sidebarResizeWidth ?? preferredWidth)
        let isCollapsed = !isSidebarHovered && !isSidebarDragging && !isSidebarMenuTracking
        let popupWidth = min(520, max(360, windowWidth * 0.45))
        let expandedLayout = !isCollapsed || sidebarExpandedContent

        return HStack(spacing: 0) {
            if store.tabsInSidebar { Color.clear.frame(width: railWidth) }
            if showsNavigation {
                navigationColumn(width: width)
            }
            ZStack {
                if let tab = session.activeDocumentTab {
                    PDFReaderView(store: store, tab: tab).id(tab.id)
                } else {
                    HomeTabRootView(store: store, session: session)
                }
            }
            // Keep heavyweight PDFViews from overlapping during rapid tab switching.
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .overlay(alignment: .leading) {
            if showsNavigation {
                ReaderResizeHandle(axis: .horizontal, length: width) { newWidth, ended in
                    let bounded = boundedWidth(newWidth)
                    if ended {
                        if bounded != boundedWidth(preferredWidth) {
                            sidebarWidth = Double(bounded)
                        }
                        sidebarResizeWidth = nil
                    } else {
                        sidebarResizeWidth = bounded
                    }
                }
                .frame(width: gripWidth)
                .overlay {
                    AppPalette.panelHairline(isDark)
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
                .offset(x: railWidth + width - gripWidth / 2)
                .onDisappear { sidebarResizeWidth = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if store.tabsInSidebar {
                sidebarTabsColumn(width: expandedLayout ? popupWidth : railWidth, isCollapsed: !expandedLayout)
                    .transaction { $0.animation = nil }
                    .frame(width: isCollapsed ? railWidth : popupWidth, alignment: .leading)
                    .clipped()
                    .contentShape(Rectangle())
                    .overlay(alignment: .trailing) {
                        AppPalette.panelHairline(isDark).frame(width: 1).allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(isCollapsed ? 0 : (isDark ? 0.28 : 0.12)), radius: 10, x: 4, y: 0)
                    .background(SidebarTabHoverArea(session: session) { isSidebarHovered = $0 })
                    .animation(AppAnimation.sidebarReveal, value: isCollapsed)
                    .task(id: isCollapsed) {
                        if !isCollapsed { sidebarExpandedContent = true; return }
                        do {
                            try await Task.sleep(nanoseconds: UInt64(AppAnimation.sidebarRevealDuration * 1_000_000_000))
                        } catch { return }
                        sidebarExpandedContent = false
                    }
                    .onDisappear { sidebarExpandedContent = false }
            }
        }
    }

    private func navigationColumn(width: CGFloat) -> some View {
        Group {
            if let tab = session.activeDocumentTab {
                ReaderLeftSidebarView(store: store, tab: tab, panelWidth: width)
                    .id(tab.id)
            } else {
                HomeTabSidebarView(store: store, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width)
        .background(AppPalette.panelBackground(isDark), ignoresSafeAreaEdges: [])
    }

    private func sidebarTabsColumn(width: CGFloat, isCollapsed: Bool) -> some View {
        TabBarView(store: store, session: session, isDark: isDark, isSidebar: true,
                   isCollapsed: isCollapsed, onDragActivityChanged: { isSidebarDragging = $0 })
        .frame(width: width, alignment: .leading)
        .background(AppPalette.panelBackground(isDark), ignoresSafeAreaEdges: [])
    }

}

struct ReaderResizeHandle: NSViewRepresentable {
    let axis: Axis
    let length: CGFloat
    let onResize: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ view: Handle, context: Context) {
        view.axis = axis
        view.length = length
        view.onResize = onResize
    }

    final class Handle: NSView {
        var axis: Axis = .horizontal {
            didSet {
                if axis != oldValue { window?.invalidateCursorRects(for: self) }
            }
        }
        var length: CGFloat = 0
        var onResize: ((CGFloat, Bool) -> Void)?
        private var dragStart: (position: CGFloat, length: CGFloat)?
        private var cursorTrackingArea: NSTrackingArea?
        private var resizeCursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: resizeCursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            cursorTrackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            resizeCursor.set()
        }

        private func position(_ event: NSEvent) -> CGFloat {
            axis == .horizontal ? event.locationInWindow.x : -event.locationInWindow.y
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = (position(event), length)
            resizeCursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            onResize?(dragStart.length + position(event) - dragStart.position, false)
        }

        override func mouseUp(with event: NSEvent) {
            guard let dragStart else { return }
            self.dragStart = nil
            onResize?(dragStart.length + position(event) - dragStart.position, true)
        }
    }
}

// MARK: - Tab Bar

struct TabBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    let isDark: Bool
    var isSidebar = false
    var isCollapsed = false
    var onDragActivityChanged: ((Bool) -> Void)?

    @State private var hoveredTabID: UUID?
    @State private var isAllTabsHovered = false
    @State private var isOpenFileHovered = false
    @State private var isShortcutsHelpHovered = false
    @State private var allTabsAnchor = NSViewAnchor()

    @State private var draggingTabID: UUID?
    @State private var draggingGroupID: UUID?
    @State private var dragFeedback = TabDragFeedback()

    private static let allTabsButtonWidth: CGFloat = 30
    private static let shortcutsHelpButtonWidth: CGFloat = 34
    private static let minimumTabWidth: CGFloat = 168
    private static let maximumTabWidth: CGFloat = 340
    private static let sidebarRowHeight: CGFloat = 44
    /// Leave room between the last tab and the help button.
    private static let reservedTrailingWidth: CGFloat = 48

    var body: some View {
        tabStrip
    }

    private var tabStrip: some View {
        Group {
            if isSidebar { sidebarTabs }
            else { topTabs }
        }
        .background(TabStripAnchor(session: session, axis: isSidebar ? .vertical : .horizontal))
        .background(isSidebar ? AppPalette.panelBackground(isDark) : AppPalette.tabStripBackground(isDark),
                    ignoresSafeAreaEdges: [])
        .animation(AppAnimation.tab, value: session.tabDragPreview?.placement)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("标签栏", "Tab Bar")))
        .contextMenu {
            Button(L10n.tr("新建窗口", "New Window")) {
                _ = store.openNewWindow()
            }
            Button(L10n.tr("打开...", "Open...")) {
                store.openFilePicker(in: session.id)
            }
            Button(L10n.tr("新建主页标签", "New Home Tab")) {
                store.openNewHomeTab(in: session.id)
            }
            Divider()
            Button(L10n.tr("重新打开关闭的标签", "Reopen Closed Tab")) {
                store.reopenClosedTab(in: session.id)
            }
            .disabled(store.closedTabs.isEmpty)
            if !store.detachedSessions.isEmpty {
                Divider()
                Button(L10n.tr("合并所有窗口", "Merge All Windows")) {
                    store.mergeAllWindows()
                }
            }
            Divider()
            Button(L10n.tr("快捷键与技巧", "Shortcuts & Tips")) {
                store.presentShortcutsSheet(in: session.id)
            }
        }
    }

    private var documentTabs: [DocumentTabState] {
        session.displayedDocumentTabs
    }

    private enum Entry: Identifiable {
        case document(DocumentTabState)
        case group(ReaderTabGroup)
        var id: UUID {
            switch self { case .document(let tab): tab.id; case .group(let group): group.id }
        }
    }

    private var entries: [Entry] {
        var result: [Entry] = []
        for group in session.displayedTabGroups {
            result.append(.group(group))
            if !group.isCollapsed {
                result.append(contentsOf: documentTabs.filter { group.tabIDs.contains($0.id) }.map(Entry.document))
            }
        }
        result.append(contentsOf: documentTabs.filter { session.displayedTabGroup(containing: $0.id) == nil }.map(Entry.document))
        return result
    }

    private func groupWidth(_ group: ReaderTabGroup) -> CGFloat {
        if group.name.isEmpty { return 32 }
        let label = group.name as NSString
        return min(180, max(52, ceil(label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width) + 24))
    }

    private func groupHeader(_ group: ReaderTabGroup) -> some View {
        TabGroupHeader(store: store, session: session, group: group,
                       isSidebar: isSidebar, isCompact: isCollapsed, isDark: isDark,
                       onDragChanged: { location in
                           if draggingGroupID == nil { onDragActivityChanged?(true) }
                           draggingGroupID = group.id
                           dragFeedback.update(title: group.displayName, isDark: isDark,
                                               at: location, target: nil)
                           if session.containsTabStrip(location.screenPoint) {
                               session.showGroupInsertion(at: location.screenPoint)
                           } else { session.clearTabInsertion() }
                       }, onDragEnded: { location in
                           draggingGroupID = nil
                           onDragActivityChanged?(false)
                           dragFeedback.end()
                           session.clearTabInsertion()
                           if let location, session.containsTabStrip(location.screenPoint) {
                               session.moveTabGroup(group.id, before: session.groupInsertionTarget(at: location.screenPoint))
                           }
                       })
            .opacity(draggingGroupID == group.id ? 0.35 : 1)
    }

    private var ungroupedTabs: [DocumentTabState] {
        documentTabs.filter { session.displayedTabGroup(containing: $0.id) == nil }
    }

    private var showsUngroupedSection: Bool { !ungroupedTabs.isEmpty }

    private var sidebarList: some View {
        VStack(spacing: 6) {
            ForEach(session.displayedTabGroups) { group in
                VStack(spacing: 2) {
                    groupHeader(group).frame(height: Self.sidebarRowHeight).id(group.id)
                    if !group.isCollapsed && !group.tabIDs.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(documentTabs.filter { group.tabIDs.contains($0.id) }) { state in
                                tabItem(state, count: documentTabs.count).frame(height: Self.sidebarRowHeight).id(state.id)
                            }
                        }
                    }
                }
                .padding(.leading, 6)
                .background(alignment: .leading) {
                    if !group.isCollapsed && !group.tabIDs.isEmpty {
                        Capsule().fill(AppPalette.tabOutline(group.color, isDark))
                            .frame(width: 2)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(2)
            }
            if showsUngroupedSection {
                VStack(spacing: 2) {
                    ForEach(ungroupedTabs) { state in
                        tabItem(state, count: documentTabs.count).frame(height: Self.sidebarRowHeight).id(state.id)
                    }
                }
                .padding(.leading, isCollapsed ? 8 : 0)
                .padding(.trailing, isCollapsed ? 2 : 0)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .animation(AppAnimation.tab, value: session.tabDragPreview?.placement)
        .animation(AppAnimation.sidebarReveal, value: entries.map(\.id))
    }

    private var sidebarTabs: some View {
        let groupHeight = session.displayedTabGroups.reduce(CGFloat.zero) { height, group in
            let rows = group.isCollapsed ? 0 : group.tabIDs.count
            return height + Self.sidebarRowHeight + CGFloat(rows) * (Self.sidebarRowHeight + 2) + 4
        }
        let count = ungroupedTabs.count
        let rowsHeight = CGFloat(count) * Self.sidebarRowHeight + CGFloat(max(0, count - 1)) * 2
        let ungroupedHeight = rowsHeight
        let sections = session.displayedTabGroups.count + (showsUngroupedSection ? 1 : 0)
        let naturalHeight = groupHeight + ungroupedHeight + CGFloat(max(0, sections - 1)) * 6 + 8
        return GeometryReader { geometry in
            let listHeight = min(naturalHeight, max(0, geometry.size.height - 50))
            VStack(spacing: 0) {
                scrollingTabs(.vertical) { sidebarList }
                .frame(height: listHeight)
                openFileButton
                    .padding(.leading, isCollapsed ? 8 : 0)
                    .padding(.trailing, isCollapsed ? 2 : 0)
                    .frame(height: Self.sidebarRowHeight)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                Spacer(minLength: 0)
            }
        }
    }

    private var topTabs: some View {
        GeometryReader { proxy in
            let documentTabs = self.documentTabs
            let entries = self.entries
            let visibleCount = entries.filter { if case .document = $0 { return true }; return false }.count
            let headersWidth = entries.reduce(CGFloat.zero) { width, entry in
                if case .group(let group) = entry { return width + groupWidth(group) }
                return width
            }
            let showsAllTabsMenu = documentTabs.count >= 2
            let openWidth = min(156, ceil((openFileTitle as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
            ).width) + 50)
            let trailingControlsWidth = openWidth
                + (showsAllTabsMenu ? Self.allTabsButtonWidth : 0)
                + Self.shortcutsHelpButtonWidth
            let available = max(
                0,
                proxy.size.width - trailingControlsWidth - Self.reservedTrailingWidth - 1
            )
            let fitWidth = visibleCount == 0
                ? Self.maximumTabWidth
                : ((available - headersWidth - CGFloat(visibleCount)) / CGFloat(visibleCount)).rounded(.down)
            let tabWidth = min(Self.maximumTabWidth, max(Self.minimumTabWidth, fitWidth))

            HStack(spacing: 0) {
                tabSeparator

                if fitWidth < Self.minimumTabWidth || headersWidth > available {
                    scrollingTabs(.horizontal) {
                        documentTabsRow(documentTabs, tabWidth: tabWidth)
                    }
                    .frame(width: available)
                } else {
                    documentTabsRow(documentTabs, tabWidth: tabWidth)
                        .animation(AppAnimation.tab, value: documentTabs.count)
                }

                openFileButton.frame(width: openWidth)

                if showsAllTabsMenu {
                    allTabsButton(documentTabs: documentTabs)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Spacer(minLength: Self.reservedTrailingWidth)
                    .background(WindowDragArea())

                shortcutsHelpButton
            }
            .frame(height: proxy.size.height)
            .animation(AppAnimation.snappy, value: showsAllTabsMenu)
        }
    }

    private func scrollingTabs<Content: View>(_ axis: Axis.Set, @ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollViewReader { scrollProxy in
            let anchor: UnitPoint? = axis == .horizontal ? .center : nil
            GeometryReader { geometry in
                ScrollView(axis, showsIndicators: axis == .vertical, content: content)
                    .onAppear {
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(session.selectedTabScrollID, anchor: anchor)
                        }
                    }
                    .onChange(of: session.selectedTabScrollID) { _, newID in
                        withAnimation(AppAnimation.tab) {
                            scrollProxy.scrollTo(newID, anchor: anchor)
                        }
                    }
                    .onChange(of: axis == .vertical ? geometry.size.height : geometry.size.width) { _, _ in
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(session.selectedTabScrollID, anchor: anchor)
                        }
                    }
                    .onChange(of: entries.map(\.id)) { _, _ in
                        guard draggingTabID == nil, session.tabDragPreview == nil else { return }
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo(session.selectedTabScrollID, anchor: anchor)
                        }
                    }
            }
        }
    }

    private func documentTabsRow(_ documentTabs: [DocumentTabState], tabWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .document(let state):
                    HStack(spacing: 0) {
                        tabItem(state, count: documentTabs.count).frame(width: tabWidth)
                        tabSeparator.opacity(session.selectedTabID == state.id ? 0 : 1)
                    }
                    .overlay(alignment: .bottom) {
                        if let color = session.displayedTabGroup(containing: state.id)?.color {
                            if session.selectedTabID == state.id && session.tabDragPreview == nil {
                                TabContour()
                                    .stroke(AppPalette.tabOutline(color, isDark),
                                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .allowsHitTesting(false)
                            } else {
                                AppPalette.tabOutline(color, isDark).frame(height: 2).allowsHitTesting(false)
                            }
                        }
                    }
                    .id(state.id)
                    .transition(.opacity)
                case .group(let group):
                    groupHeader(group).frame(width: groupWidth(group)).id(group.id)
                }
            }
        }
        .animation(AppAnimation.tab, value: entries.map(\.id))
    }

    private func tabItem(_ state: DocumentTabState, count: Int) -> some View {
        DocumentTabItemView(
            store: store,
            session: session,
            state: state,
            disambiguatedFolder: store.disambiguatedFolder(for: state),
            documentTabCount: count,
            isSelected: session.selectedTabID == state.id && (session.tabDragPreview == nil || session.tabDragPreview?.tab.id == state.id),
            isHovered: hoveredTabID == state.id,
            isDragging: draggingTabID == state.id || session.tabDragPreview?.tab.id == state.id
                || session.tabGroup(containing: state.id)?.id == draggingGroupID && draggingGroupID != nil,
            isDark: isDark,
            isSidebar: isSidebar,
            isCollapsed: isCollapsed,
            onHoverChanged: { hovering in
                hoveredTabID = hovering ? state.id : (hoveredTabID == state.id ? nil : hoveredTabID)
            },
            onDragChanged: { location in
                if draggingTabID == nil { onDragActivityChanged?(true) }
                draggingTabID = state.id
                let target = store.tabDropTarget(at: location.screenPoint)
                dragFeedback.update(title: state.title, isDark: isDark, at: location,
                                    target: target, tab: state, isSidebar: isSidebar)
            },
            onDragEnded: { location in
                let target = location.flatMap { store.tabDropTarget(at: $0.screenPoint) }
                let placement: TabDropPlacement?
                if case .tabStrip(let targetSession) = target, let location {
                    placement = targetSession.tabDropPlacement(at: location.screenPoint, dragging: state.id)
                } else { placement = nil }
                draggingTabID = nil
                onDragActivityChanged?(false)
                dragFeedback.end()
                guard let location else { return }
                let point = location.screenPoint
                switch target {
                case .tabStrip(let target):
                    guard let placement else { return }
                    let index = target.tabInsertionIndex(for: placement, excluding: state.id)
                    if target === session {
                        store.moveDocumentTab(id: state.id, toDocumentIndex: index,
                                              intoGroup: placement.groupID, in: session.id)
                        session.selectedTabID = state.id
                    } else {
                        store.moveTab(id: state.id, from: session.id, to: target.id,
                                      atDocumentIndex: index, intoGroup: placement.groupID)
                    }
                case .comparison(let tab):
                    tab.setSecondaryDocument(from: state)
                case nil:
                    if store.canDetachTab(id: state.id, in: session.id) {
                        store.detachTabToNewWindow(id: state.id, from: session.id,
                                                   screenDropPoint: point, tabGrabOffset: location.grabOffset)
                    } else if !session.isPrimary, let window = session.nsWindow {
                        window.contentView?.layoutSubtreeIfNeeded()
                        session.positionWindowForTabDrop(tabID: state.id, grabOffset: location.grabOffset, at: point)
                    }
                }
            }
        )
    }

    private var tabSeparator: some View {
        Rectangle()
            .fill(AppPalette.tabSeparator(isDark))
            .frame(width: 1)
    }

    private var openFileTitle: String { L10n.tr("打开文件…", "Open File…") }

    private var openFileButton: some View {
        Button {
            store.activateWindowSession(session.id)
            store.openFilePicker(in: session.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: isSidebar ? 17 : 14))
                if !isCollapsed { Text(openFileTitle).font(.system(size: 12)) }
            }
            .foregroundStyle(AppPalette.labelSecondary(isDark))
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .padding(.leading, isCollapsed ? 0 : 12)
            .padding(.trailing, isCollapsed ? 0 : 8)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isOpenFileHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("打开 PDF 文档 (⌘O)", "Open PDF Document (⌘O)"))
        .accessibilityLabel(Text(L10n.tr("打开 PDF 文档 (⌘O)", "Open PDF Document (⌘O)")))
        .onHover { isOpenFileHovered = $0 }
    }

    // "All Tabs" menu button to view & switch among many or similarly named open tabs
    private func allTabsButton(documentTabs: [DocumentTabState]) -> some View {
        Button {
            presentAllTabsMenu()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .frame(width: 24, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isAllTabsHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear)
                )
                .frame(width: Self.allTabsButtonWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isAllTabsHovered)
        }
        .buttonStyle(.plain)
        .background(ViewAnchorRepresentable(anchor: allTabsAnchor).allowsHitTesting(false))
        .help(L10n.tr("所有标签页 (⌃⇥ 切换)", "All Tabs (⌃⇥ to Switch)"))
        .accessibilityLabel(Text(L10n.tr("所有标签页", "All Tabs")))
        .onHover { hovering in
            isAllTabsHovered = hovering
        }
    }

    private var shortcutsHelpButton: some View {
        Button {
            store.activateWindowSession(session.id)
            store.presentShortcutsSheet(in: session.id)
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(isShortcutsHelpHovered ? AppPalette.labelPrimary(isDark) : AppPalette.labelTertiary(isDark))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isShortcutsHelpHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear)
                )
                .frame(width: Self.shortcutsHelpButtonWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isShortcutsHelpHovered)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help(L10n.tr("快捷键与技巧 (⌘/)", "Shortcuts & Tips (⌘/)"))
        .accessibilityLabel(Text(L10n.tr("快捷键与技巧", "Shortcuts & Tips")))
        .onHover { hovering in
            isShortcutsHelpHovered = hovering
        }
    }

    private func presentAllTabsMenu() {
        var items: [NativeMenuItem] = []
        for tab in session.tabs {
            let label: String
            switch tab {
            case .home:
                label = L10n.tr("主页", "Home")
            case .document(let state):
                let folderSuffix = store.disambiguatedFolder(for: state).map { " — \($0)" } ?? ""
                let pageLabel = "\(state.displayPageNumber(at: state.currentPageIndex)) / \(state.pageCount)"
                label = "\(state.title)\(folderSuffix)  (\(pageLabel))"
            }

            items.append(
                .action(
                    label,
                    isChecked: session.selectedTabID == tab.id
                ) {
                    store.activateWindowSession(session.id)
                    withAnimation(AppAnimation.tab) {
                        session.selectedTabID = tab.id
                    }
                }
            )
        }

        items.append(.separator)
        items.append(
            .action(
                L10n.tr("重新打开关闭的标签", "Reopen Closed Tab"),
                keyEquivalent: "t",
                keyModifiers: [.shift, .command],
                isEnabled: !store.closedTabs.isEmpty
            ) {
                store.reopenClosedTab(in: session.id)
            }
        )
        NativeMenu.popUp(items, below: allTabsAnchor.view)
    }

}

// MARK: - DocumentTabItemView (TabView)

struct DocumentTabItemView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @ObservedObject var state: DocumentTabState
    let disambiguatedFolder: String?
    let documentTabCount: Int
    let isSelected: Bool
    let isHovered: Bool
    let isDragging: Bool
    let isDark: Bool
    let isSidebar: Bool
    var isCollapsed = false
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: (TabDragLocation) -> Void
    let onDragEnded: (TabDragLocation?) -> Void

    @State private var isCloseHovered = false

    private var showsCloseButton: Bool {
        !isCollapsed && (isSelected || isHovered)
    }

    var body: some View {
        HStack(spacing: 5) {
            if isCollapsed {
                Image(systemName: "doc.text")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? AppPalette.accentBlue : AppPalette.labelSecondary(isDark))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            } else {
                if isSidebar {
                    Image(systemName: "doc.text")
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? AppPalette.accentBlue : AppPalette.labelSecondary(isDark))
                        .accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    Text(state.title)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .lineLimit(isSidebar ? 2 : 1)
                        .truncationMode(.middle)

                    if let disambiguatedFolder {
                        Text(disambiguatedFolder)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundColor(AppPalette.labelTertiary(isDark))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(AppPalette.segmentedTrack(isDark).opacity(isSelected ? 0.9 : 0.6))
                            )
                            .layoutPriority(-1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            }

            if showsCloseButton || (isSidebar && !isCollapsed) {
                Button {
                    store.closeTab(id: state.id, in: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isCloseHovered ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isCloseHovered ? AppPalette.toolbarHover(isDark) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("关闭标签 (⌘W · ⇧⌘T 恢复)", "Close Tab (⌘W · ⇧⌘T to Reopen)"))
                .accessibilityLabel(Text("\(L10n.tr("关闭标签", "Close Tab")) \(state.title)"))
                .opacity(showsCloseButton ? 1 : 0)
                .allowsHitTesting(showsCloseButton)
                .accessibilityHidden(!showsCloseButton)
                .onHover { isCloseHovered = $0 }
                .transition(.opacity)
            }
        }
        .padding(.leading, isCollapsed ? 0 : (isSidebar ? (session.displayedTabGroup(containing: state.id) != nil ? 2 : 10) : 12))
        .padding(.trailing, isCollapsed ? 0 : ((isSidebar || showsCloseButton) ? 8 : 12))
        .frame(maxHeight: .infinity)
        .background {
            if isSidebar {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AppPalette.tabSelectedBackground(isDark)
                        : (isHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear))
            } else if isSelected || isHovered {
                if session.displayedTabGroup(containing: state.id) != nil {
                    TabContour().fill(isSelected ? AppPalette.tabSelectedBackground(isDark)
                                      : AppPalette.tabHoverBackground(isDark))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? AppPalette.tabSelectedBackground(isDark)
                              : AppPalette.tabHoverBackground(isDark))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
            }
        }
        .background {
            if isSidebar && session.displayedTabGroup(containing: state.id) != nil {
                AppPalette.accentBlue.opacity(isDark ? 0.06 : 0.04)
            }
        }
        .opacity(isDragging ? (session.tabDragPreview?.tab.id == state.id ? 0 : 0.3) : 1)
        .overlay {
            TabInteractionArea(session: session, tabID: state.id, toolTip: state.documentID.url.path,
                               excludedTrailingWidth: showsCloseButton ? 30 : 0, isSidebar: isSidebar,
                               onSelect: selectTab,
                               onDragChanged: onDragChanged, onDragEnded: onDragEnded)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(disambiguatedFolder.map { "\(state.title) — \($0)" } ?? state.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { selectTab() }
        .onHover { hovering in
            if !hovering { isCloseHovered = false }
            onHoverChanged(hovering)
        }
        .contextMenu {
            Menu(L10n.tr("添加到分组", "Add to Group")) {
                Button(L10n.tr("新建分组…", "New Group…")) {
                    store.editTabGroup(containing: state.id, in: session.id)
                }
                if !session.tabGroups.isEmpty {
                    Divider()
                    ForEach(session.tabGroups) { group in
                        Button {
                            store.moveTab(state.id, intoGroup: group.id, in: session.id)
                        } label: {
                            if group.tabIDs.contains(state.id) { Label(group.displayName, systemImage: "checkmark") }
                            else { Text(group.displayName) }
                        }
                    }
                }
            }
            if session.tabGroup(containing: state.id) != nil {
                Button(L10n.tr("移出分组", "Remove from Group")) {
                    store.moveTab(state.id, intoGroup: nil, in: session.id)
                }
            }
            Divider()
            Button(L10n.tr("将标签移至新窗口", "Move Tab to New Window")) {
                store.detachTabToNewWindow(id: state.id, from: session.id)
            }
            .disabled(!store.canDetachTab(id: state.id, in: session.id))

            if !session.isPrimary {
                Button(L10n.tr("移回主窗口", "Move Tab to Main Window")) {
                    store.moveTab(id: state.id, from: session.id, to: store.primarySession.id)
                }
            }

            Divider()

            Button(L10n.tr("重新打开关闭的标签", "Reopen Closed Tab")) {
                store.reopenClosedTab(in: session.id)
            }
            .disabled(store.closedTabs.isEmpty)

            Divider()

            Button(L10n.tr("关闭标签", "Close Tab")) {
                store.closeTab(id: state.id, in: session.id)
            }
            Button(L10n.tr("关闭其他标签", "Close Other Tabs")) {
                store.closeOtherTabs(keeping: state.id, in: session.id)
            }
            .disabled(documentTabCount <= 1)

            Divider()

            Button(L10n.tr("在 Finder 中显示", "Show in Finder")) {
                store.showInFinder(id: state.documentID)
            }
            Button(L10n.tr("复制为路径名", "Copy as Pathname")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.documentID.url.path, forType: .string)
            }
        }
    }

    private func selectTab() {
        store.activateWindowSession(session.id)
        session.selectedTabID = state.id
    }

}
