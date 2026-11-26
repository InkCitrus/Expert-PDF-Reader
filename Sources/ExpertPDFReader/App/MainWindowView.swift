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
    @AppStorage("expertPDFReader.sidebarTabsPopupWidth") private var sidebarPopupWidth: Double?
    @State private var sidebarResizeWidth: CGFloat?
    @State private var sidebarPopupResizeWidth: CGFloat?
    @State private var isSidebarHovered = false
    @State private var isSidebarDragging = false
    @State private var isSidebarResizing = false
    @State private var isSidebarMenuTracking = false
    @State private var isDropTargeted = false
    private var isDark: Bool { colorScheme == .dark }
    private var accent: Color { store.accentColor.color(isDark: isDark) }

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
            .overlay(alignment: .bottom) {
                if let activity = session.exportActivity {
                    ExportActivityToast(
                        state: activity,
                        pdfTheme: store.resolvedPDFTheme(isDark: isDark),
                        isDarkUI: isDark,
                        onCancel: { session.cancelActiveExport() },
                        onReveal: { session.revealExportedItemInFinder() },
                        onDismiss: { session.dismissExportToast() },
                        onHoverChanged: { session.setExportToastHovered($0) }
                    )
                    .padding(.bottom, exportToastBottomPadding)
                    .transition(
                        AppAnimation.reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95))
                    )
                }
            }
            .animation(AppAnimation.toast, value: session.exportActivity)
        }
        .background(AppPalette.homeContentBackground(isDark), ignoresSafeAreaEdges: [])
        .overlay {
            if isDropTargeted {
                DropOverlayView(isDark: isDark)
                    .padding(14)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(AppAnimation.snappy, value: isDropTargeted)
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
            PDFFileDrop.open(providers) { url in
                store.openDocument(at: url, in: session.id)
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            isSidebarMenuTracking = isSidebarHovered
            session.sidebarTabHoverView?.isMenuTracking = isSidebarMenuTracking
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isSidebarMenuTracking = false
            session.sidebarTabHoverView?.isMenuTracking = false
            session.sidebarTabHoverView?.reconcileHover()
        }
        .onChange(of: store.tabsInSidebar) { _, _ in
            session.tabGroupNameEdit = nil
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
                tabBar: AnyView(titlebarContent.environment(\.appAccentColor, accent)),
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
        .environment(\.appAccentColor, accent)
    }

    private var titlebarContent: some View {
        let homeTitle = session.activeDocumentTab == nil && session.returnableDocumentTabID != nil
            ? L10n.tr("返回之前的页面", "Return to Previous Page")
            : L10n.tr("主页", "Home")
        let sidebarVisible = store.isLeftPanelVisible(in: session)
        let sidebarTitle = sidebarVisible
            ? L10n.tr("隐藏左边面板", "Hide Left Panel") : L10n.tr("显示左边面板", "Show Left Panel")
        let controlsWidth: CGFloat = 88
        let trailingControlsWidth: CGFloat = 64
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                ToolbarIconButton(icon: "sidebar.left", tooltip: "\(sidebarTitle) (⌘B)",
                                  isActive: sidebarVisible, activeTint: accent, isDark: isDark) {
                    store.toggleLeftPanel(in: session)
                }
                ToolbarIconButton(icon: "house.fill", tooltip: homeTitle,
                                  isActive: session.activeDocumentTab == nil, activeTint: accent, isDark: isDark, action: goHome)
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
                    .padding(.trailing, max(0, controlsWidth - trailingControlsWidth))
                HStack(spacing: 0) {
                    TitlebarTabLayoutButton(tabsInSidebar: true, isDark: isDark, width: 30) {
                        withAnimation(AppAnimation.reduceMotion ? nil : AppAnimation.panel) {
                            store.tabsInSidebar = false
                        }
                    }
                    TitlebarShortcutsButton(isDark: isDark, width: 34) {
                        store.activateWindowSession(session.id)
                        store.presentShortcutsSheet(in: session.id)
                    }
                }
                .frame(width: trailingControlsWidth, alignment: .trailing)
            } else {
                TabBarView(store: store, session: session, isDark: isDark)
            }
        }
        .background(WindowDragArea())
        .background(AppPalette.tabStripBackground(isDark))
        .background(PanelCursorRect())
    }

    private var exportToastBottomPadding: CGFloat {
        if let tab = session.activeDocumentTab,
           tab.isPageOverviewVisible,
           !tab.selectedThumbnailPages(in: tab.activeThumbnailSource).isEmpty {
            return 76
        }
        return 22
    }

    private func goHome() {
        store.activateWindowSession(session.id)
        store.toggleHomeTab(in: session.id)
    }

    private func windowContent(windowWidth: CGFloat) -> some View {
        let showsNavigation = store.isLeftPanelVisible(in: session)
        let railWidth = store.tabsInSidebar ? SidebarTabMetrics.railWidth : 0
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
        let isCollapsed = !isSidebarHovered && !isSidebarDragging && !isSidebarMenuTracking && !isSidebarResizing
            && session.editingTabGroupID == nil
        let defaultPopupWidth = min(400, max(360, windowWidth * 0.37))
        let popupMin: CGFloat = 240
        // Even a minimum-size window must fit the default popup, or the list opens narrower than intended
        let popupMax = max(defaultPopupWidth, min(640, windowWidth - railWidth - 320))
        func boundedPopup(_ w: CGFloat) -> CGFloat { min(max(w, popupMin), popupMax) }
        let storedPopupWidth = sidebarPopupWidth.map { CGFloat($0) } ?? defaultPopupWidth
        let popupWidth = boundedPopup(sidebarPopupResizeWidth ?? storedPopupWidth)
        let visibleTabsWidth = isCollapsed ? railWidth : popupWidth

        return HStack(spacing: 0) {
            if store.tabsInSidebar { Color.clear.frame(width: railWidth) }
            if showsNavigation {
                navigationColumn(width: width)
                    .clipped()
                    .transition(
                        AppAnimation.reduceMotion
                            ? .opacity
                            : .move(edge: .leading).combined(with: .opacity)
                    )
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
        .animation(sidebarResizeWidth == nil ? AppAnimation.panel : nil, value: showsNavigation)
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
                .transition(.opacity)
                .onDisappear { sidebarResizeWidth = nil }
            }
        }
        .animation(sidebarResizeWidth == nil ? AppAnimation.panel : nil, value: showsNavigation)
        .overlay(alignment: .topLeading) {
            if store.tabsInSidebar {
                SidebarReveal(width: visibleTabsWidth) { drawerWidth in
                    // The clip and the row highlights use the same animated width. Titles keep
                    // their full layout until the edge reaches the rail.
                    let expandedLayout = !isCollapsed || drawerWidth > railWidth + 0.5
                    let reveal = min(1, max(0, (drawerWidth - railWidth) / (popupWidth - railWidth)))
                    sidebarTabsColumn(width: expandedLayout ? popupWidth : railWidth,
                                      visibleWidth: drawerWidth, isCollapsed: !expandedLayout,
                                      drawerReveal: reveal)
                    .frame(width: drawerWidth, alignment: .leading)
                    .background {
                        SidebarBackdropMaterial(isDark: isDark, reveal: reveal)
                            .allowsHitTesting(false)
                    }
                    .background(PanelCursorRect(priority: 2))
                    .clipped()
                    .contentShape(Rectangle())
                    .overlay(alignment: .trailing) {
                        AppPalette.panelHairline(isDark)
                            .opacity(isDark ? 0.95 : 0.85)
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .trailing) {
                        if !isCollapsed {
                            ReaderResizeHandle(axis: .horizontal, length: popupWidth, priority: 3) { newWidth, ended in
                                let bounded = boundedPopup(newWidth)
                                if ended {
                                    sidebarPopupWidth = Double(bounded)
                                    sidebarPopupResizeWidth = nil
                                    isSidebarResizing = false
                                    let releasePoint = NSApp.currentEvent?.window === session.nsWindow
                                        ? NSApp.currentEvent?.locationInWindow : nil
                                    DispatchQueue.main.async {
                                        session.sidebarTabHoverView?.reconcileHover(at: releasePoint, edgeTolerance: gripWidth)
                                    }
                                } else {
                                    isSidebarResizing = true
                                    sidebarPopupResizeWidth = bounded
                                }
                            }
                            .frame(width: gripWidth)
                            .padding(.bottom, TabBarView.sidebarFooterHeight)
                        }
                    }
                    .shadow(color: .black.opacity(reveal * (isDark ? 0.32 : 0.14)), radius: 16, x: 6, y: 0)
                    .shadow(color: .black.opacity(reveal * (isDark ? 0.16 : 0.06)), radius: 2, x: 1, y: 0)
                    .background(SidebarTabHoverArea(session: session) { isSidebarHovered = $0 })
                }
                .animation(AppAnimation.sidebarReveal, value: isCollapsed)
                .onChange(of: session.editingTabGroupID) { _, newValue in
                    if newValue == nil {
                        session.sidebarTabHoverView?.reconcileHover()
                    }
                }
                .onDisappear {
                    isSidebarHovered = false
                    isSidebarDragging = false
                    isSidebarMenuTracking = false
                    session.sidebarTabHoverView?.isMenuTracking = false
                    sidebarPopupResizeWidth = nil
                    isSidebarResizing = false
                }
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
        .background(PanelCursorRect())
    }

    private func sidebarTabsColumn(width: CGFloat, visibleWidth: CGFloat, isCollapsed: Bool,
                                   drawerReveal: CGFloat = 0) -> some View {
        TabBarView(store: store, session: session, isDark: isDark, isSidebar: true,
                   isCollapsed: isCollapsed, sidebarRowWidth: SidebarTabMetrics.rowWidth(in: visibleWidth),
                   drawerReveal: drawerReveal,
                   onDragActivityChanged: { isSidebarDragging = $0 })
        .frame(width: width, alignment: .leading)
    }

}

private struct SidebarReveal<Content: View>: View, Animatable {
    var width: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    var body: some View {
        content(width).transaction { $0.animation = nil }
    }
}

/// Window-level cursor arbitration. PDFKit sets its own cursor (pointingHand over image-only pages, iBeam
/// over text) from `-[PDFView mouseMoved:]` on every move, which beats passive cursor rects from views in
/// front of it — the sidebar popup floats over the page. `ThemedPDFView.mouseMoved` consults `cursor(at:in:)`
/// and, when a registered region covers the pointer, sets that cursor synchronously *instead of* letting
/// PDFKit set its own, so there is no per-frame flash. The deferred `schedule` path only re-asserts after a
/// relayout under a stationary pointer. Priorities: divider (1) > panel (0) > scanned-page OCR text (-1),
/// which returns nil off selectable glyphs so PDFKit keeps its native text cursor. A mid-drag region forces
/// its cursor even outside its bounds; an editable text view under the pointer (the sidebar search field,
/// inline tab rename) keeps its own iBeam.
final class ReaderCursorArbiter {
    static let shared = ReaderCursorArbiter()

    private final class Region {
        weak var view: NSView?
        let priority: Int
        let cursor: (NSView) -> NSCursor?
        let forced: () -> Bool
        init(view: NSView, priority: Int, cursor: @escaping (NSView) -> NSCursor?, forced: @escaping () -> Bool) {
            self.view = view
            self.priority = priority
            self.cursor = cursor
            self.forced = forced
        }
    }

    private var regions: [Region] = []
    private var pending = false

    func register(_ view: NSView, priority: Int, cursor: @escaping (NSView) -> NSCursor?, forced: @escaping () -> Bool = { false }) {
        regions.removeAll { $0.view === view }
        regions.append(Region(view: view, priority: priority, cursor: cursor, forced: forced))
    }

    func unregister(_ view: NSView) {
        regions.removeAll { $0.view === view }
    }

    /// Coalesce every region's request in one event cycle into a single deferred evaluation.
    func schedule(_ window: NSWindow?) {
        guard let window, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.pending = false
            guard let window else { return }
            self.evaluate(in: window)
        }
    }

    /// The cursor a registered region wants at this window point, or nil to leave PDFKit's cursor alone.
    /// Called synchronously from `ThemedPDFView.mouseMoved` so the region cursor replaces PDFKit's in the
    /// same event (no flash), and from the deferred relayout path.
    func cursor(at point: NSPoint, in window: NSWindow) -> NSCursor? {
        let live = regions.filter { $0.view?.window === window }.sorted { $0.priority > $1.priority }
        return resolve(point, live, window)
    }

    private func resolve(_ point: NSPoint, _ live: [Region], _ window: NSWindow) -> NSCursor? {
        if let forced = live.first(where: { $0.forced() }), let view = forced.view {
            return forced.cursor(view)
        }
        guard let region = live.first(where: { region in
            guard let view = region.view else { return false }
            return view.bounds.contains(view.convert(point, from: nil))
        }), let view = region.view else { return nil }
        let hitRoot = window.contentView?.superview ?? window.contentView
        if let hit = hitRoot?.hitTest(point), Self.isEditableTextView(hit) { return nil }
        return region.cursor(view)
    }

    private func evaluate(in window: NSWindow) {
        cursor(at: window.mouseLocationOutsideOfEventStream, in: window)?.set()
    }

    private static func isEditableTextView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if let field = candidate as? NSTextField { return field.isEditable }
            if let text = candidate as? NSTextView { return text.isEditable }
            current = candidate.superview
        }
        return false
    }
}

/// SwiftUI views register no cursor rects, so AppKit's cursor resolution falls through to the page behind
/// a panel. This hit-test-transparent background participates in `ReaderCursorArbiter` so the panel actively
/// re-asserts the arrow cursor over the PDF's iBeam, while still deferring to its own editable text fields.
struct PanelCursorRect: NSViewRepresentable {
    var cursor: NSCursor = .arrow
    var priority: Int = 0

    func makeNSView(context: Context) -> View {
        let view = View()
        view.priority = priority
        return view
    }
    func updateNSView(_ view: View, context: Context) {
        view.cursor = cursor
        view.priority = priority
    }

    final class View: NSView {
        var cursor: NSCursor = .arrow
        var priority: Int = 0
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                ReaderCursorArbiter.shared.register(self, priority: priority) { [weak self] _ in self?.cursor ?? .arrow }
                ReaderCursorArbiter.shared.schedule(window)
            } else {
                ReaderCursorArbiter.shared.unregister(self)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking, trackingAreas.contains(tracking) { return }
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            if let window, let cursor = ReaderCursorArbiter.shared.cursor(at: event.locationInWindow, in: window) {
                cursor.set()
            }
            ReaderCursorArbiter.shared.schedule(window)
        }
        override func mouseEntered(with event: NSEvent) {
            if let window, let cursor = ReaderCursorArbiter.shared.cursor(at: event.locationInWindow, in: window) {
                cursor.set()
            }
            ReaderCursorArbiter.shared.schedule(window)
        }
        override func mouseExited(with event: NSEvent) { ReaderCursorArbiter.shared.schedule(window) }
        override func cursorUpdate(with event: NSEvent) {
            if let window, let cursor = ReaderCursorArbiter.shared.cursor(at: event.locationInWindow, in: window) {
                cursor.set()
            } else {
                super.cursorUpdate(with: event)
            }
        }
    }
}

/// A draggable panel divider. Like native macOS split views it shows no grip widget — the resize
/// cursor appearing over the boundary is the affordance. The `Handle` keeps that cursor reliable.
struct ReaderResizeHandle: NSViewRepresentable {
    let axis: Axis
    let length: CGFloat
    var priority: Int = 1
    let onResize: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        handle.priority = priority
        return handle
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.axis = axis
        view.length = length
        view.priority = priority
        view.onResize = onResize
    }

    final class Handle: NSView {
        var priority: Int = 1
        var axis: Axis = .horizontal {
            didSet {
                if axis != oldValue {
                    window?.invalidateCursorRects(for: self)
                    ReaderCursorArbiter.shared.schedule(window)
                }
            }
        }
        var length: CGFloat = 0
        var onResize: ((CGFloat, Bool) -> Void)?
        private var dragStart: (position: CGFloat, length: CGFloat)?
        private var cursorTrackingArea: NSTrackingArea?
        private var resizeCursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override var frame: NSRect {
            didSet {
                // Moving the boundary under a stationary pointer must re-evaluate the cursor, or the old
                // cursor lingers until the mouse moves.
                if frame != oldValue {
                    window?.invalidateCursorRects(for: self)
                    ReaderCursorArbiter.shared.schedule(window)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                // The divider outranks its own panel's arrow where the band straddles the panel edge.
                ReaderCursorArbiter.shared.register(self, priority: priority,
                                                    cursor: { [weak self] _ in self?.resizeCursor },
                                                    forced: { [weak self] in self?.dragStart != nil })
                window.invalidateCursorRects(for: self)
                ReaderCursorArbiter.shared.schedule(window)
            } else {
                ReaderCursorArbiter.shared.unregister(self)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // Keep one stable area across layout passes. Removing an area the pointer is inside
            // synthesizes mouseExited without a matching mouseEntered, so recreating it on every SwiftUI
            // layout drops the cursor until the mouse next moves. .inVisibleRect tracks geometry changes.
            if let cursorTrackingArea, trackingAreas.contains(cursorTrackingArea) { return }
            if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            cursorTrackingArea = area
        }

        // No passive cursor rect: AppKit would re-assert resize even where a higher-priority region (the
        // floating popup) covers this divider, fighting the arbiter's arrow each frame. Resolve through the
        // arbiter synchronously instead, so the divider yields to whatever is visually on top.
        private func applyArbiterCursor(_ event: NSEvent) {
            guard let window else { return }
            let cursor = ReaderCursorArbiter.shared.cursor(at: event.locationInWindow, in: window)
            (cursor ?? resizeCursor).set()
        }

        override func mouseMoved(with event: NSEvent) { applyArbiterCursor(event) }
        override func mouseEntered(with event: NSEvent) { applyArbiterCursor(event) }
        override func cursorUpdate(with event: NSEvent) { applyArbiterCursor(event) }

        override func mouseExited(with event: NSEvent) {
            guard let window else { return }
            let cursor = ReaderCursorArbiter.shared.cursor(at: event.locationInWindow, in: window)
            (cursor ?? NSCursor.arrow).set()
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
            resizeCursor.set()
            onResize?(dragStart.length + position(event) - dragStart.position, false)
        }

        override func mouseUp(with event: NSEvent) {
            guard let dragStart else { return }
            self.dragStart = nil
            onResize?(dragStart.length + position(event) - dragStart.position, true)
            ReaderCursorArbiter.shared.schedule(window)
        }
    }
}

// MARK: - Tab Bar

private struct SidebarBackdropMaterial: NSViewRepresentable {
    let isDark: Bool
    let reveal: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassThroughVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        updateAppearanceAndState(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        updateAppearanceAndState(nsView)
    }

    private func updateAppearanceAndState(_ nsView: NSVisualEffectView) {
        let desiredName: NSAppearance.Name = isDark ? .darkAqua : .aqua
        if nsView.appearance?.name != desiredName {
            nsView.appearance = NSAppearance(named: desiredName)
        }
        let active = reveal > 0.001
        if nsView.isHidden != !active {
            nsView.isHidden = !active
        }
        nsView.alphaValue = reveal
        nsView.state = active ? .active : .inactive
    }

    private final class PassThroughVisualEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct TitlebarTabLayoutButton: View {
    let tabsInSidebar: Bool
    let isDark: Bool
    var width: CGFloat = 30
    let action: () -> Void

    @State private var isHovered = false

    private var iconName: String {
        tabsInSidebar ? "rectangle.topthird.inset.filled" : "sidebar.squares.leading"
    }

    private var tooltip: String {
        tabsInSidebar
            ? L10n.tr("在顶部显示标签栏", "Show Tabs in Titlebar")
            : L10n.tr("在侧边栏显示标签栏", "Show Tabs in Sidebar")
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear)
                )
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(TactilePressButtonStyle())
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
        .onHover { isHovered = $0 }
    }
}

struct TitlebarShortcutsButton: View {
    let isDark: Bool
    var width: CGFloat = 34
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isHovered ? AppPalette.labelPrimary(isDark) : AppPalette.labelTertiary(isDark))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppPalette.tabHoverBackground(isDark) : Color.clear)
                )
                .frame(width: max(26, width - 4))
                .padding(.trailing, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(TactilePressButtonStyle())
        .help(L10n.tr("快捷键与技巧 (⌘/)", "Shortcuts & Tips (⌘/)"))
        .accessibilityLabel(Text(L10n.tr("快捷键与技巧", "Shortcuts & Tips")))
        .onHover { isHovered = $0 }
    }
}
