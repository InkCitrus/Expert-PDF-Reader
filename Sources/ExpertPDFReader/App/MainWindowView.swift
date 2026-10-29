import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Main window:
/// A unified native titlebar contains window controls, Home and document tabs.
/// Unlike PDF Expert (always graphite), the strip follows the system / app appearance.
/// Enforces a minimum window width of `600pt`.
public struct MainWindowView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false
    private var isDark: Bool { colorScheme == .dark }

    public static let tabStripHeight: CGFloat = 40

    public init(store: AppStore, session: ReaderWindowSession? = nil) {
        self.store = store
        self.session = session ?? store.primarySession
    }

    public var body: some View {
        VStack(spacing: 0) {
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
            .background(AppPalette.homeContentBackground(isDark), ignoresSafeAreaEdges: [])
            .clipped()
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            PDFFileDrop.open(providers) { url in
                store.openDocument(at: url, in: session.id)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .toolbar {
            // Keep the compact native toolbar alive: SwiftUI removes an empty one and shrinks tabs to 32pt.
            // The titlebar accessory supplies all visible controls in this 40pt row.
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
                tabBar: AnyView(TopTabBarView(store: store, session: session, isDark: isDark)),
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
}

// MARK: - TopTabBarView

struct TopTabBarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    let isDark: Bool

    @Namespace private var tabBarNamespace
    @State private var hoveredTabID: UUID?
    @State private var isHomeHovered = false
    @State private var isNewTabHovered = false
    @State private var isAllTabsHovered = false
    @State private var isShortcutsHelpHovered = false
    @State private var allTabsAnchor = NSViewAnchor()

    @State private var draggingTabID: UUID?
    @State private var dragFeedback = TabDragFeedback()

    private static let homeTabWidth: CGFloat = 46
    private static let newTabButtonWidth: CGFloat = 36
    private static let allTabsButtonWidth: CGFloat = 30
    private static let shortcutsHelpButtonWidth: CGFloat = 34
    private static let minimumTabWidth: CGFloat = 168
    private static let maximumTabWidth: CGFloat = 340
    /// Leave room between the last tab and the help button.
    private static let reservedTrailingWidth: CGFloat = 48

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
            let leadingInset: CGFloat = 8
            let available = max(
                0,
                proxy.size.width - leadingInset - Self.homeTabWidth - trailingControlsWidth - Self.reservedTrailingWidth - 2
            )
            let fitWidth = documentTabs.isEmpty
                ? Self.maximumTabWidth
                : ((available - CGFloat(documentTabs.count)) / CGFloat(documentTabs.count)).rounded(.down)
            let tabWidth = min(Self.maximumTabWidth, max(Self.minimumTabWidth, fitWidth))

            HStack(spacing: 0) {
                Color.clear.frame(width: leadingInset)

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

                Spacer(minLength: Self.reservedTrailingWidth)
                    .background(WindowDragArea())

                shortcutsHelpButton
            }
            .frame(height: proxy.size.height)
            .animation(AppAnimation.snappy, value: showsAllTabsMenu)
        }
        .background(TabStripAnchor(session: session))
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
    }

    private func documentTabsRow(_ documentTabs: [DocumentTabState], tabWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(documentTabs) { state in
                DocumentTabItemView(
                    store: store,
                    session: session,
                    state: state,
                    disambiguatedFolder: store.disambiguatedFolder(for: state),
                    documentTabCount: documentTabs.count,
                    isSelected: session.selectedTabID == state.id,
                    isHovered: hoveredTabID == state.id,
                    isDragging: draggingTabID == state.id,
                    isDark: isDark,
                    tabBarNamespace: tabBarNamespace,
                    onHoverChanged: { hovering in
                        hoveredTabID = hovering ? state.id : (hoveredTabID == state.id ? nil : hoveredTabID)
                    },
                    onDragChanged: { point in
                        draggingTabID = state.id
                        let target = store.dropTargetWindowAndIndex(atScreenPoint: point, excluding: session.id)?.session
                            ?? (session.containsTabStrip(point) ? session : nil)
                        dragFeedback.update(title: state.title, at: point, target: target)
                    },
                    onDragEnded: { point in
                        draggingTabID = nil
                        dragFeedback.end()
                        guard let point else { return }
                        if let target = store.dropTargetWindowAndIndex(atScreenPoint: point, excluding: session.id) {
                            store.moveTab(id: state.id, from: session.id, to: target.session.id,
                                          atDocumentIndex: target.documentIndex)
                        } else if session.containsTabStrip(point) {
                            if let index = session.nearestDocumentIndex(at: point) {
                                store.moveDocumentTab(id: state.id, toDocumentIndex: index, in: session.id)
                            }
                        } else {
                            if store.canDetachTab(id: state.id, in: session.id) {
                                store.detachTabToNewWindow(id: state.id, from: session.id, screenDropPoint: point)
                            } else if !session.isPrimary, let window = session.nsWindow {
                                window.setFrameTopLeftPoint(NSPoint(x: point.x - 100, y: point.y + 20 + window.frame.height - window.contentLayoutRect.height))
                            }
                        }
                    }
                )
                .frame(width: tabWidth)
                .id(state.id)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                tabSeparator
            }
        }
        .animation(AppAnimation.tab, value: documentTabs.map(\.id))
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
    let isDark: Bool
    let tabBarNamespace: Namespace.ID
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: (NSPoint) -> Void
    let onDragEnded: (NSPoint?) -> Void

    @State private var isCloseHovered = false

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
        .opacity(isDragging ? 0.3 : 1)
        .overlay {
            TabInteractionArea(session: session, tabID: state.id, toolTip: state.documentID.url.path, onSelect: selectTab,
                               onDragChanged: onDragChanged, onDragEnded: onDragEnded)
                .padding(.trailing, showsCloseButton ? 30 : 0)
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

    private func selectTab() {
        store.activateWindowSession(session.id)
        session.selectedTabID = state.id
    }

}
