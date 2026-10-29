import AppKit
import SwiftUI

/// A public titlebar accessory keeps native controls and interactive tabs on the same row.
struct WindowChromeConfigurator: NSViewRepresentable {
    let windowTitle: String
    let representedURL: URL?
    let tabBar: AnyView
    let tabBarBackground: NSColor
    let onWindowAttached: ((NSWindow) -> Void)?
    let onWindowBecameActive: (() -> Void)?

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.windowTitle = windowTitle
        view.representedURL = representedURL
        view.setTabBar(tabBar)
        view.tabBarBackground = tabBarBackground
        view.onWindowAttached = onWindowAttached
        view.onWindowBecameActive = onWindowBecameActive
        view.syncWindowMetadata()
    }
}

final class WindowChromeView: NSView {
    /// Most recently focused reader window (as opposed to Settings, alerts or panels)
    static weak var readerWindow: NSWindow?
    private static let readerWindows = NSHashTable<NSWindow>.weakObjects()

    static func isReaderWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return readerWindow == nil }
        return readerWindows.contains(candidate)
    }


    var windowTitle = "Expert PDF Reader"
    var representedURL: URL?
    var tabBarBackground = NSColor.windowBackgroundColor
    var onWindowAttached: ((NSWindow) -> Void)?
    var onWindowBecameActive: (() -> Void)?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var titleObservation: NSKeyValueObservation?
    private var isSyncingMetadata = false
    private let accessory = NSTitlebarAccessoryViewController()
    private var tabHost: TabBarHostingView?

    func setTabBar(_ content: AnyView) {
        if let tabHost { tabHost.rootView = content }
        else {
            let host = TabBarHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 600, height: MainWindowView.tabStripHeight)
            host.sizingOptions = []
            tabHost = host
            accessory.view = host
            accessory.layoutAttribute = .top
        }
    }

    deinit {
        titleObservation?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        titleObservation?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard let window else { return }
        Self.readerWindow = window
        Self.readerWindows.add(window)

        window.styleMask.insert(.fullSizeContentView)
        // The compact toolbar provides the original 40pt row. A bare native titlebar clamps .top to 32pt.
        if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "ReaderTabs") }
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.isVisible = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.addTitlebarAccessoryViewController(accessory)
        onWindowAttached?(window)
        if window.isKeyWindow || window.isMainWindow { onWindowBecameActive?() }
        syncWindowMetadata()

        titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncWindowMetadata() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    Self.readerWindow = window
                    self.onWindowBecameActive?()
                }
            })
        }
    }

    func syncWindowMetadata() {
        guard !isSyncingMetadata, let window else { return }
        isSyncingMetadata = true
        defer { isSyncingMetadata = false }
        if window.representedURL != representedURL { window.representedURL = representedURL }
        if window.title != windowTitle { window.title = windowTitle }
        if window.backgroundColor != tabBarBackground { window.backgroundColor = tabBarBackground }
        NSApp.changeWindowsItem(window, title: windowTitle, filename: false)
    }

}

private final class TabBarHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}
