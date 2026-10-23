import AppKit
import SwiftUI

/// Metrics published by `WindowChromeConfigurator` so the tab strip can make room for the traffic lights.
public struct WindowChromeMetrics: Equatable {
    public var trafficLightsInset: CGFloat = 80
    public var isFullScreen: Bool = false
}

/// Replicates the unified title bar of `MainWindowController`: the native title is hidden, content runs
/// under the transparent title bar and the traffic lights are re-centered on the `40pt` tab strip.
/// Mounted as a zero-size background of `MainWindowView`.
struct WindowChromeConfigurator: NSViewRepresentable {
    let titleBarHeight: CGFloat
    @Binding var metrics: WindowChromeMetrics

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.titleBarHeight = titleBarHeight
        view.onMetricsChange = metricsHandler()
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.titleBarHeight = titleBarHeight
        nsView.onMetricsChange = metricsHandler()
        nsView.layoutTrafficLights()
    }

    private func metricsHandler() -> (WindowChromeMetrics) -> Void {
        let binding = $metrics
        return { newMetrics in
            DispatchQueue.main.async {
                if binding.wrappedValue != newMetrics {
                    binding.wrappedValue = newMetrics
                }
            }
        }
    }
}

final class WindowChromeView: NSView {
    var titleBarHeight: CGFloat = 40
    var onMetricsChange: ((WindowChromeMetrics) -> Void)?

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var isLayingOut = false
    private var isFullScreen = false

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        isFullScreen = window.styleMask.contains(.fullScreen)

        let relayoutNotifications: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didExitFullScreenNotification
        ]
        for name in relayoutNotifications {
            observe(name, object: window) { $0.layoutTrafficLights() }
        }
        observe(NSWindow.willEnterFullScreenNotification, object: window) { $0.setFullScreen(true) }
        observe(NSWindow.willExitFullScreenNotification, object: window) { $0.setFullScreen(false) }

        // AppKit re-lays out the title bar buttons on its own schedule (appearance, key state, title changes…)
        for button in trafficLightButtons(in: window) {
            button.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, object: button) { $0.layoutTrafficLights() }
        }
        layoutTrafficLights()
    }

    func layoutTrafficLights() {
        guard !isLayingOut, let window else { return }
        let buttons = trafficLightButtons(in: window)
        guard let titleBarView = buttons.first?.superview else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        if !isFullScreen {
            // Put the buttons' centers on the strip's midline, staying inside the native title bar view.
            let barHeight = titleBarView.bounds.height
            for button in buttons {
                let buttonHeight = button.frame.height
                let centeredY = titleBarView.isFlipped
                    ? (titleBarHeight - buttonHeight) / 2
                    : barHeight - (titleBarHeight + buttonHeight) / 2
                let targetY = min(max(0, centeredY.rounded()), max(0, barHeight - buttonHeight))
                if abs(button.frame.origin.y - targetY) > 0.5 {
                    button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
                }
            }
        }

        let trailingEdge = buttons.map { $0.frame.maxX }.max() ?? 66
        onMetricsChange?(WindowChromeMetrics(trafficLightsInset: (trailingEdge + 14).rounded(), isFullScreen: isFullScreen))
    }

    private func setFullScreen(_ value: Bool) {
        isFullScreen = value
        layoutTrafficLights()
    }

    private func trafficLightButtons(in window: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    private func observe(_ name: Notification.Name, object: AnyObject, handler: @escaping (WindowChromeView) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(token)
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

// MARK: - WindowDragArea (empty tab-strip space behaves like a native title bar)

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            // Honour System Settings › Desktop & Dock › "Double-click a window's title bar to"
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}
