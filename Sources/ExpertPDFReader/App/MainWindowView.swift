import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Replicates `MainWindowController` + `TabsViewController` + `HomeTabButtonView` from `PDFExpert`:
/// one unified `40pt` title bar hosting the traffic lights, the pinned Home tab and the document tabs.
/// Unlike PDF Expert (always graphite), the strip follows the system / app appearance.
/// Enforces a minimum window width of `600pt` per `HomeTab.framework/ARCHITECTURE.md`.
public struct MainWindowView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var chromeMetrics = WindowChromeMetrics()
    @State private var isDropTargeted = false
    private var isDark: Bool { colorScheme == .dark }

    public static let tabStripHeight: CGFloat = 40

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Unified Title Bar: traffic lights + Home tab + document tabs (TabsViewController)
            TopTabBarView(store: store, metrics: chromeMetrics, isDark: isDark)
                .frame(height: Self.tabStripHeight)

            // Active Tab Content
            ZStack {
                if let activeTab = store.tabs.first(where: { $0.id == store.selectedTabID }) {
                    switch activeTab {
                    case .home:
                        HomeTabRootView(store: store)
                    case .document(let docState):
                        PDFReaderView(store: store, tab: docState)
                            .id(docState.id)
                    }
                } else {
                    HomeTabRootView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // PDFs dropped onto a document tab or the tab strip (the Home tab shows its own drop area)
                if isDropTargeted && store.activeDocumentTab != nil {
                    DropOverlayView(isDark: isDark)
                        .padding(14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            PDFFileDrop.open(providers) { url in
                store.openDocument(at: url)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .background(RDColorPalette.homeContentBackground(isDark))
        .background(WindowChromeConfigurator(titleBarHeight: Self.tabStripHeight, metrics: $chromeMetrics))
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - TopTabBarView (TabsViewController + HomeTabButtonView + TabView)

struct TopTabBarView: View {
    @ObservedObject var store: AppStore
    let metrics: WindowChromeMetrics
    let isDark: Bool

    @State private var hoveredTabID: UUID?
    @State private var isNewTabHovered = false

    private static let homeTabWidth: CGFloat = 46
    private static let newTabButtonWidth: CGFloat = 40
    private static let minimumTabWidth: CGFloat = 120
    private static let maximumTabWidth: CGFloat = 260
    /// Empty strip kept on the trailing side so the window can always be dragged
    private static let reservedDragWidth: CGFloat = 64

    var body: some View {
        GeometryReader { proxy in
            let documentTabs = store.tabs.compactMap { tab -> DocumentTabState? in
                if case .document(let state) = tab { return state }
                return nil
            }
            let leadingInset = metrics.isFullScreen ? 10 : metrics.trafficLightsInset
            let available = max(0, proxy.size.width - leadingInset - Self.homeTabWidth - Self.newTabButtonWidth - Self.reservedDragWidth)
            let fitWidth = documentTabs.isEmpty ? Self.maximumTabWidth : (available / CGFloat(documentTabs.count)).rounded(.down)
            let tabWidth = min(Self.maximumTabWidth, max(Self.minimumTabWidth, fitWidth))

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingInset)

                tabSeparator
                homeTabButton
                tabSeparator

                if fitWidth < Self.minimumTabWidth {
                    ScrollView(.horizontal, showsIndicators: false) {
                        documentTabsRow(documentTabs, tabWidth: tabWidth)
                    }
                    .frame(width: available)
                } else {
                    documentTabsRow(documentTabs, tabWidth: tabWidth)
                }

                newTabButton

                Spacer(minLength: 0)
            }
            .frame(height: proxy.size.height)
        }
        .background(WindowDragArea())
        .background(RDColorPalette.tabStripBackground(isDark))
    }

    private func documentTabsRow(_ documentTabs: [DocumentTabState], tabWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(documentTabs) { state in
                DocumentTabItemView(
                    store: store,
                    state: state,
                    isSelected: store.selectedTabID == state.id,
                    isHovered: hoveredTabID == state.id,
                    isDark: isDark
                )
                .frame(width: tabWidth)
                .onHover { hovering in
                    if hovering {
                        hoveredTabID = state.id
                    } else if hoveredTabID == state.id {
                        hoveredTabID = nil
                    }
                }

                tabSeparator
            }
        }
    }

    private var tabSeparator: some View {
        Rectangle()
            .fill(RDColorPalette.tabSeparator(isDark))
            .frame(width: 1)
    }

    // Fixed HomeTabButtonView (icon-only, always pinned on the left)
    private var homeTabButton: some View {
        let homeID = store.tabs.first(where: { $0.isHome })?.id
        let isHomeSelected = homeID != nil && store.selectedTabID == homeID
        let isHovered = hoveredTabID != nil && hoveredTabID == homeID
        return Button {
            store.selectHomeTab()
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isHomeSelected ? RDColorPalette.labelPrimary(isDark) : RDColorPalette.labelTertiary(isDark))
                .frame(width: Self.homeTabWidth)
                .frame(maxHeight: .infinity)
                .background(tabFill(isSelected: isHomeSelected, isHovered: isHovered))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("主页", "Home"))
        .accessibilityLabel(Text(L10n.tr("主页", "Home")))
        .accessibilityAddTraits(isHomeSelected ? .isSelected : [])
        .onHover { hovering in
            if hovering {
                hoveredTabID = homeID
            } else if hoveredTabID == homeID {
                hoveredTabID = nil
            }
        }
    }

    // "+" Button to Open Document
    private var newTabButton: some View {
        Button {
            store.openFilePicker()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(RDColorPalette.labelSecondary(isDark))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isNewTabHovered ? RDColorPalette.tabHoverBackground(isDark) : Color.clear)
                )
                .frame(width: Self.newTabButtonWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("打开 PDF 文档 (⌘O)", "Open PDF Document (⌘O)"))
        .accessibilityLabel(Text(L10n.tr("打开 PDF 文档", "Open PDF Document")))
        .onHover { isNewTabHovered = $0 }
    }

    private func tabFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return RDColorPalette.tabSelectedBackground(isDark)
        }
        return isHovered ? RDColorPalette.tabHoverBackground(isDark) : Color.clear
    }
}

// MARK: - DocumentTabItemView (TabView)

struct DocumentTabItemView: View {
    @ObservedObject var store: AppStore
    let state: DocumentTabState
    let isSelected: Bool
    let isHovered: Bool
    let isDark: Bool

    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(state.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? RDColorPalette.labelPrimary(isDark) : RDColorPalette.labelSecondary(isDark))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.closeTab(id: state.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(RDColorPalette.labelSecondary(isDark))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isCloseHovered ? RDColorPalette.toolbarHover(isDark) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("关闭标签 (⌘W)", "Close Tab (⌘W)"))
            .accessibilityLabel(Text("\(L10n.tr("关闭标签", "Close Tab")) \(state.title)"))
            .onHover { isCloseHovered = $0 }
            .opacity(isSelected || isHovered ? 1 : 0)
            .allowsHitTesting(isSelected || isHovered)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(
            isSelected
                ? RDColorPalette.tabSelectedBackground(isDark)
                : (isHovered ? RDColorPalette.tabHoverBackground(isDark) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedTabID = state.id
        }
        .help(state.documentID.url.path)
        .contextMenu {
            Button(L10n.tr("关闭标签", "Close Tab")) { store.closeTab(id: state.id) }
            Button(L10n.tr("关闭其他标签", "Close Other Tabs")) { store.closeOtherTabs(keeping: state.id) }
            Divider()
            Button(L10n.tr("在 Finder 中显示", "Show in Finder")) { store.showInFinder(id: state.documentID) }
        }
    }
}
