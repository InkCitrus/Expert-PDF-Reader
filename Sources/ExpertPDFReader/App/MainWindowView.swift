import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window:
/// one unified `40pt` title bar hosting the traffic lights, the pinned Home tab and the document tabs.
/// Unlike PDF Expert (always graphite), the strip follows the system / app appearance.
/// Enforces a minimum window width of `600pt`.
public struct MainWindowView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var chromeMetrics = WindowChromeMetrics()
    @State private var isDropTargeted = false
    @State private var windowWidth: CGFloat = 1180
    @State private var tabHoverPreview: TabHoverPreview?
    private var isDark: Bool { colorScheme == .dark }

    public static let tabStripHeight: CGFloat = 40

    struct TabHoverPreview: Equatable {
        let tabID: UUID
        let anchorMidX: CGFloat
    }

    public init(store: AppStore, session: ReaderWindowSession? = nil) {
        self.store = store
        self.session = session ?? store.primarySession
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Unified Title Bar: traffic lights + Home tab + document tabs
            TopTabBarView(
                store: store,
                session: session,
                metrics: chromeMetrics,
                isDark: isDark,
                hoverPreview: $tabHoverPreview
            )
            .frame(height: Self.tabStripHeight)
            .zIndex(2)

            // Active Tab Content (disable spring overlap between heavyweight PDFView NSViews during rapid tab cycling)
            ZStack {
                if let activeTab = session.tabs.first(where: { $0.id == session.selectedTabID }) {
                    switch activeTab {
                    case .home:
                        HomeTabRootView(store: store, session: session)
                    case .document(let docState):
                        PDFReaderView(store: store, tab: docState)
                            .id(docState.id)
                    }
                } else {
                    HomeTabRootView(store: store, session: session)
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // PDFs dropped onto a document tab or the tab strip (the Home tab shows its own drop area)
                if isDropTargeted && session.activeDocumentTab != nil {
                    DropOverlayView(isDark: isDark)
                        .padding(14)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(AppAnimation.snappy, value: isDropTargeted)
        }
        .coordinateSpace(name: "mainWindow")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { windowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newW in windowWidth = newW }
            }
        )
        .overlay(alignment: .topLeading) {
            if let preview = tabHoverPreview,
               let tab = session.tabs.first(where: { $0.id == preview.tabID }),
               case .document(let docState) = tab {
                TabHoverCardView(state: docState, isDark: isDark)
                    .fixedSize()
                    .offset(
                        x: min(max(12, preview.anchorMidX - 140), max(12, windowWidth - 310)),
                        y: Self.tabStripHeight + 6
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    .zIndex(20)
            }
        }
        .animation(AppAnimation.micro, value: tabHoverPreview)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            PDFFileDrop.open(providers) { url in
                store.openDocument(at: url, in: session.id)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .sheet(isPresented: $session.isShortcutsSheetPresented) {
            ShortcutsAndTipsSheetView(store: store, session: session)
        }
        .background(AppPalette.homeContentBackground(isDark))
        .background(
            WindowChromeConfigurator(
                titleBarHeight: Self.tabStripHeight,
                windowTitle: store.windowTitle(for: session),
                representedURL: store.windowRepresentedURL(for: session),
                onWindowAttached: { window in
                    session.nsWindow = window
                },
                onWindowBecameActive: {
                    store.activateWindowSession(session.id)
                },
                metrics: $chromeMetrics
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - TopTabBarView

struct TopTabBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    let metrics: WindowChromeMetrics
    let isDark: Bool
    @Binding var hoverPreview: MainWindowView.TabHoverPreview?

    @Namespace private var tabBarNamespace
    @State private var hoveredTabID: UUID?
    @State private var hoveredTabMidX: CGFloat = 0
    @State private var hoverPreviewTask: Task<Void, Never>?
    @State private var isHomeHovered = false
    @State private var isNewTabHovered = false
    @State private var isAllTabsHovered = false
    @State private var isShortcutsHelpHovered = false
    @State private var allTabsAnchor = NSViewAnchor()

    // Live drag-to-reorder & tear-off-to-window state
    @State private var draggingTabID: UUID?
    @State private var dragGrabOffset: CGFloat = 0
    @State private var dragVisualOffset: CGFloat = 0
    @State private var isTearOffActive: Bool = false

    private static let tearOffVerticalThreshold: CGFloat = 42
    private static let homeTabWidth: CGFloat = 46
    private static let newTabButtonWidth: CGFloat = 36
    private static let allTabsButtonWidth: CGFloat = 30
    private static let shortcutsHelpButtonWidth: CGFloat = 34
    private static let minimumTabWidth: CGFloat = 168
    private static let maximumTabWidth: CGFloat = 340
    /// Empty strip kept on the trailing side so the window can always be dragged
    private static let reservedDragWidth: CGFloat = 48

    var body: some View {
        GeometryReader { proxy in
            let documentTabs = session.tabs.compactMap { tab -> DocumentTabState? in
                if case .document(let state) = tab { return state }
                return nil
            }
            let showsAllTabsMenu = documentTabs.count >= 2
            let trailingControlsWidth = Self.newTabButtonWidth
                + (showsAllTabsMenu ? Self.allTabsButtonWidth : 0)
                + Self.shortcutsHelpButtonWidth
            let leadingInset = metrics.isFullScreen ? 10 : metrics.trafficLightsInset
            let available = max(
                0,
                proxy.size.width - leadingInset - Self.homeTabWidth - trailingControlsWidth - Self.reservedDragWidth - 2
            )
            let fitWidth = documentTabs.isEmpty
                ? Self.maximumTabWidth
                : ((available - CGFloat(documentTabs.count)) / CGFloat(documentTabs.count)).rounded(.down)
            let tabWidth = min(Self.maximumTabWidth, max(Self.minimumTabWidth, fitWidth))

            HStack(spacing: 0) {
                WindowDragArea()
                    .frame(width: leadingInset, height: proxy.size.height)

                tabSeparator
                homeTabButton
                tabSeparator

                if fitWidth < Self.minimumTabWidth {
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            documentTabsRow(documentTabs, tabWidth: tabWidth)
                        }
                        .frame(width: available)
                        .onAppear {
                            scrollProxy.scrollTo(session.selectedTabID, anchor: .center)
                        }
                        .onChange(of: session.selectedTabID) { _, newID in
                            withAnimation(AppAnimation.tab) {
                                scrollProxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                } else {
                    documentTabsRow(documentTabs, tabWidth: tabWidth)
                        .animation(AppAnimation.tab, value: documentTabs.count)
                }

                newTabButton

                if showsAllTabsMenu {
                    allTabsButton(documentTabs: documentTabs)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                WindowDragArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                shortcutsHelpButton
            }
            .frame(height: proxy.size.height)
            .animation(AppAnimation.snappy, value: showsAllTabsMenu)
        }
        .background(AppPalette.tabStripBackground(isDark))
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
        .onChange(of: session.selectedTabID) { _, _ in
            dismissHoverPreview()
        }
        .onDisappear {
            if draggingTabID != nil {
                TabDragPreviewController.shared.hide()
            }
        }
    }

    private func documentTabsRow(_ documentTabs: [DocumentTabState], tabWidth: CGFloat) -> some View {
        let stride = tabWidth + 1
        return HStack(spacing: 0) {
            ForEach(documentTabs) { state in
                let isDragging = (draggingTabID == state.id)
                DocumentTabItemView(
                    store: store,
                    session: session,
                    state: state,
                    disambiguatedFolder: store.disambiguatedFolder(for: state),
                    documentTabCount: documentTabs.count,
                    isSelected: session.selectedTabID == state.id,
                    isHovered: hoveredTabID == state.id && draggingTabID == nil,
                    isDragging: isDragging,
                    isTearingOff: isDragging && isTearOffActive,
                    isDark: isDark,
                    tabBarNamespace: tabBarNamespace,
                    onHoverChanged: { hovering, frameInWindow in
                        handleTabHover(tabID: state.id, hovering: hovering, midX: frameInWindow.midX)
                    },
                    onDragChanged: { value, isOverCloseButton in
                        handleTabDragChanged(
                            state: state,
                            value: value,
                            isOverCloseButton: isOverCloseButton,
                            documentTabs: documentTabs,
                            tabWidth: tabWidth,
                            stride: stride
                        )
                    },
                    onDragEnded: {
                        handleTabDragEnded(tabID: state.id)
                    }
                )
                .frame(width: tabWidth)
                .offset(x: isDragging ? dragVisualOffset : 0)
                .zIndex(isDragging ? 10 : (session.selectedTabID == state.id ? 2 : 0))
                .id(state.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .leading)),
                    removal: .opacity.combined(with: .scale(scale: 0.92))
                ))

                tabSeparator
                    .opacity(isDragging ? 0 : 1)
            }
        }
        .coordinateSpace(name: "tabStripRow")
    }

    private func handleTabHover(tabID: UUID, hovering: Bool, midX: CGFloat) {
        if hovering && draggingTabID == nil {
            hoveredTabID = tabID
            hoveredTabMidX = midX
            scheduleHoverPreview(for: tabID, midX: midX)
        } else if !hovering && hoveredTabID == tabID {
            hoveredTabID = nil
            dismissHoverPreview()
        }
    }

    private func scheduleHoverPreview(for tabID: UUID, midX: CGFloat) {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, hoveredTabID == tabID, draggingTabID == nil else { return }
            hoverPreview = MainWindowView.TabHoverPreview(tabID: tabID, anchorMidX: midX)
        }
    }

    private func dismissHoverPreview() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        if hoverPreview != nil {
            hoverPreview = nil
        }
    }

    private func handleTabDragChanged(
        state: DocumentTabState,
        value: DragGesture.Value,
        isOverCloseButton: Bool,
        documentTabs: [DocumentTabState],
        tabWidth: CGFloat,
        stride: CGFloat
    ) {
        if draggingTabID != state.id {
            guard !isOverCloseButton,
                  let initialIdx = documentTabs.firstIndex(where: { $0.id == state.id }) else { return }
            dismissHoverPreview()
            store.activateWindowSession(session.id)
            if session.selectedTabID != state.id {
                session.selectedTabID = state.id
            }
            let initialLeftX = CGFloat(initialIdx) * stride
            dragGrabOffset = min(max(0, value.startLocation.x - initialLeftX), tabWidth)
            draggingTabID = state.id
            isTearOffActive = false
        }

        let verticalDelta = abs(value.location.y - MainWindowView.tabStripHeight * 0.5)
        let tornOff = verticalDelta > Self.tearOffVerticalThreshold

        if tornOff {
            if !isTearOffActive {
                withAnimation(AppAnimation.micro) {
                    isTearOffActive = true
                    dragVisualOffset = 0
                }
            }
            let screenPoint = NSEvent.mouseLocation
            let mergeTarget = store.dropTargetWindowAndIndex(atScreenPoint: screenPoint, excluding: session.id)
            if mergeTarget != nil {
                TabDragPreviewController.shared.update(
                    at: screenPoint,
                    title: state.title,
                    style: .mergeIntoWindow,
                    isDark: isDark
                )
            } else if store.canDetachTab(id: state.id, in: session.id) || !session.isPrimary {
                TabDragPreviewController.shared.update(
                    at: screenPoint,
                    title: state.title,
                    style: .detachToNewWindow,
                    isDark: isDark
                )
            } else {
                TabDragPreviewController.shared.hide()
            }
            return
        }

        if isTearOffActive {
            TabDragPreviewController.shared.hide()
            withAnimation(AppAnimation.micro) {
                isTearOffActive = false
            }
        }

        guard documentTabs.count > 1 else {
            dragVisualOffset = max(-24, min(24, (value.location.x - value.startLocation.x) * 0.35))
            return
        }

        guard let currentIdx = documentTabs.firstIndex(where: { $0.id == state.id }) else { return }
        let maxLeftX = CGFloat(max(0, documentTabs.count - 1)) * stride
        let clampedLeftX = min(max(0, value.location.x - dragGrabOffset), maxLeftX)
        let centerX = clampedLeftX + tabWidth * 0.5
        let targetIdx = min(max(0, Int((centerX / stride).rounded(.down))), documentTabs.count - 1)

        if targetIdx != currentIdx {
            withAnimation(AppAnimation.tab) {
                store.moveDocumentTab(id: state.id, toDocumentIndex: targetIdx, in: session.id)
                dragVisualOffset = clampedLeftX - CGFloat(targetIdx) * stride
            }
        } else {
            dragVisualOffset = clampedLeftX - CGFloat(currentIdx) * stride
        }
    }

    private func handleTabDragEnded(tabID: UUID) {
        guard draggingTabID == tabID else { return }
        let wasTearOff = isTearOffActive
        let screenPoint = NSEvent.mouseLocation
        TabDragPreviewController.shared.hide()

        withAnimation(AppAnimation.tab) {
            dragVisualOffset = 0
            draggingTabID = nil
            isTearOffActive = false
        }

        guard wasTearOff else { return }
        if let target = store.dropTargetWindowAndIndex(atScreenPoint: screenPoint, excluding: session.id) {
            store.moveTab(
                id: tabID,
                from: session.id,
                to: target.session.id,
                atDocumentIndex: target.documentIndex
            )
        } else if store.canDetachTab(id: tabID, in: session.id) {
            store.detachTabToNewWindow(
                id: tabID,
                from: session.id,
                screenDropPoint: screenPoint
            )
        } else if !session.isPrimary, session.tabs.count == 1, let win = session.nsWindow {
            let visibleFrame = (
                NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) }
                    ?? win.screen
                    ?? NSScreen.main
            )?.visibleFrame
            let size = win.frame.size
            var newOrigin = NSPoint(
                x: screenPoint.x - min(180, size.width * 0.25),
                y: screenPoint.y - size.height + MainWindowView.tabStripHeight * 0.5
            )
            if let vf = visibleFrame {
                newOrigin.x = min(max(vf.minX, newOrigin.x), vf.maxX - size.width)
                newOrigin.y = min(max(vf.minY, newOrigin.y), vf.maxY - size.height)
            }
            win.setFrameOrigin(newOrigin)
            win.makeKeyAndOrderFront(nil)
        }
    }

    private var tabSeparator: some View {
        Rectangle()
            .fill(AppPalette.tabSeparator(isDark))
            .frame(width: 1)
    }

    // Fixed HomeTabButtonView (icon-only, always pinned on the left)
    private var homeTabButton: some View {
        let homeID = session.tabs.first(where: { $0.isHome })?.id
        let isHomeSelected = homeID != nil && session.selectedTabID == homeID
        let isHovered = isHomeHovered && draggingTabID == nil
        return Button {
            store.activateWindowSession(session.id)
            store.selectHomeTab(in: session.id)
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isHomeSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelTertiary(isDark))
                .frame(width: Self.homeTabWidth)
                .frame(maxHeight: .infinity)
                .background(tabFill(isSelected: isHomeSelected, isHovered: isHovered))
                .overlay(alignment: .top) {
                    if isHomeSelected {
                        Rectangle()
                            .fill(AppPalette.accentBlue)
                            .frame(height: 2.5)
                            .matchedGeometryEffect(id: "activeTabAccent", in: tabBarNamespace)
                    }
                }
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(.plain)
        .help(L10n.tr("主页", "Home"))
        .accessibilityLabel(Text(L10n.tr("主页", "Home")))
        .accessibilityAddTraits(isHomeSelected ? .isSelected : [])
        .onHover { hovering in
            isHomeHovered = hovering
            if hovering {
                dismissHoverPreview()
            }
        }
    }

    // "+" Button to Open Document
    private var newTabButton: some View {
        Button {
            store.activateWindowSession(session.id)
            store.openFilePicker(in: session.id)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isNewTabHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear)
                )
                .frame(width: Self.newTabButtonWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isNewTabHovered)
        }
        .buttonStyle(.plain)
        .help(L10n.tr("打开 PDF 文档 (⌘O)", "Open PDF Document (⌘O)"))
        .accessibilityLabel(Text(L10n.tr("打开 PDF 文档", "Open PDF Document")))
        .onHover { hovering in
            isNewTabHovered = hovering
            if hovering { dismissHoverPreview() }
        }
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
            if hovering { dismissHoverPreview() }
        }
    }

    private var shortcutsHelpButton: some View {
        Button {
            dismissHoverPreview()
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
            if hovering { dismissHoverPreview() }
        }
    }

    private func presentAllTabsMenu() {
        dismissHoverPreview()
        var items: [NativeMenuItem] = []
        let total = session.tabs.count
        for (idx, tab) in session.tabs.enumerated() {
            let shortcutNum: String
            if idx < 8 {
                shortcutNum = "\(idx + 1)"
            } else if idx == total - 1 {
                shortcutNum = "9"
            } else {
                shortcutNum = ""
            }

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
                    keyEquivalent: shortcutNum,
                    keyModifiers: [.option, .command],
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

    private func tabFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return AppPalette.tabSelectedBackground(isDark)
        }
        return isHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear
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
    let isTearingOff: Bool
    let isDark: Bool
    let tabBarNamespace: Namespace.ID
    let onHoverChanged: (Bool, CGRect) -> Void
    let onDragChanged: (DragGesture.Value, Bool) -> Void
    let onDragEnded: () -> Void

    @State private var isCloseHovered = false
    @State private var windowFrame: CGRect = .zero

    private var showsCloseButton: Bool {
        isSelected || isHovered
    }

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Text(state.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                    .lineLimit(1)
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

            if showsCloseButton {
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
                .onHover { isCloseHovered = $0 }
                .transition(.opacity)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, showsCloseButton ? 8 : 12)
        .frame(maxHeight: .infinity)
        .background(
            isSelected
                ? AppPalette.tabSelectedBackground(isDark)
                : (isHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear)
        )
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(AppPalette.accentBlue)
                    .frame(height: 2.5)
                    .matchedGeometryEffect(id: "activeTabAccent", in: tabBarNamespace)
            }
        }
        .shadow(
            color: Color.black.opacity(isDragging && !isTearingOff ? (isDark ? 0.48 : 0.18) : 0),
            radius: isDragging && !isTearingOff ? 8 : 0,
            x: 0,
            y: isDragging && !isTearingOff ? 2 : 0
        )
        .opacity(isTearingOff ? 0.52 : 1.0)
        .scaleEffect(isTearingOff ? 0.96 : (isDragging ? 1.015 : 1.0))
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isDragging)
        .animation(AppAnimation.micro, value: isTearingOff)
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named("mainWindow"))
                Color.clear
                    .onAppear { windowFrame = frame }
                    .onChange(of: frame) { _, newFrame in windowFrame = newFrame }
            }
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(disambiguatedFolder.map { "\(state.title) — \($0)" } ?? state.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            store.activateWindowSession(session.id)
            if session.selectedTabID != state.id {
                withAnimation(AppAnimation.tab) {
                    session.selectedTabID = state.id
                }
            }
        }
        .onHover { hovering in
            if !hovering { isCloseHovered = false }
            onHoverChanged(hovering, windowFrame)
        }
        .onTapGesture {
            store.activateWindowSession(session.id)
            if session.selectedTabID != state.id {
                withAnimation(AppAnimation.tab) {
                    session.selectedTabID = state.id
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("tabStripRow"))
                .onChanged { value in
                    onDragChanged(value, isCloseHovered)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .contextMenu {
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
        }
    }
}

// MARK: - TabHoverCardView (Fast Untruncated Tab Preview)

private struct TabHoverCardView: View {
    @ObservedObject var state: DocumentTabState
    let isDark: Bool

    private var abbreviatedFolderPath: String {
        let dir = state.documentID.url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") {
            return "~" + String(dir.dropFirst(home.count))
        }
        return dir
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                Text(abbreviatedFolderPath)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 8)

                Text("\(state.displayPageNumber(at: state.currentPageIndex)) / \(state.pageCount)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(AppPalette.accentBlue)
            }
            .foregroundColor(AppPalette.labelTertiary(isDark))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minWidth: 220, maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppPalette.floatingTooltipBackground(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppPalette.floatingTooltipBorder(isDark), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.14), radius: 10, x: 0, y: 4)
    }
}
