import AppKit
import SwiftUI

/// Metadata and focus registration only. The system owns the native titlebar; tabs live below it.
struct WindowChromeConfigurator: NSViewRepresentable {
    let windowTitle: String
    let representedURL: URL?
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
    var onWindowAttached: ((NSWindow) -> Void)?
    var onWindowBecameActive: (() -> Void)?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var titleObservation: NSKeyValueObservation?
    private var isSyncingMetadata = false

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

        // Interactive tabs must be in the content area, outside WindowServer's titlebar drag region.
        if window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.isMovableByWindowBackground = false
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
        NSApp.changeWindowsItem(window, title: windowTitle, filename: false)
    }
}
