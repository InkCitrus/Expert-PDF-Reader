import AppKit
import SwiftUI

struct SidebarTabHoverArea: NSViewRepresentable {
    let session: ReaderWindowSession
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarTabHoverView { SidebarTabHoverView() }
    func updateNSView(_ view: SidebarTabHoverView, context: Context) {
        view.onHover = onHover
        session.sidebarTabHoverView = view
    }
}

/// One stable tracking area covers the rail and its expanding drawer, including empty space.
final class SidebarTabHoverView: NSView {
    var onHover: ((Bool) -> Void)?
    var isMenuTracking = false
    private lazy var hoverArea = NSTrackingArea(rect: .zero,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
        owner: self, userInfo: nil)
    private var pendingExit: Task<Void, Never>?
    private var isHovered = false
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // AppKit already follows the visible rect as the drawer animates. Recreating the area
        // here can enqueue exit and enter events even while the pointer is stationary.
        let area = hoverArea
        if !trackingAreas.contains(where: { $0 === area }) { addTrackingArea(area) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else {
            isMenuTracking = false
            setHovered(false, immediate: true)
            return
        }
        let center = NotificationCenter.default
        let dismissOnResign: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isMenuTracking else { return }
                self.setHovered(false, immediate: true)
            }
        }
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: dismissOnResign))
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignMainNotification, object: window, queue: .main, using: dismissOnResign))
        windowObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main, using: dismissOnResign))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(for: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(for: event) }
    override func mouseExited(with event: NSEvent) { setHovered(false, immediate: false) }

    func reconcileHover(at windowPoint: NSPoint? = nil, edgeTolerance: CGFloat = 0, immediate: Bool = false) {
        if let windowPoint {
            let point = convert(windowPoint, from: nil)
            setHovered(bounds.intersection(visibleRect).insetBy(dx: -edgeTolerance, dy: 0).contains(point),
                       immediate: immediate)
            return
        }
        guard let window, window.isVisible else {
            setHovered(false, immediate: true)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.intersection(visibleRect).insetBy(dx: -edgeTolerance, dy: 0).contains(point),
                   immediate: immediate)
    }

    private func updateHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(bounds.intersection(visibleRect).contains(point), immediate: false)
    }

    private func setHovered(_ hovered: Bool, immediate: Bool) {
        if hovered {
            pendingExit?.cancel()
            pendingExit = nil
            if !isHovered {
                isHovered = true
                installMonitors()
                onHover?(true)
            }
            return
        }
        if immediate {
            pendingExit?.cancel()
            pendingExit = nil
            removeMonitors()
            if isHovered {
                isHovered = false
                onHover?(false)
            }
            return
        }
        guard isHovered, pendingExit == nil else { return }
        // Give the pointer a moment to cross back over the floating edge before closing.
        pendingExit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.pendingExit = nil
            self.removeMonitors()
            if self.isHovered {
                self.isHovered = false
                self.onHover?(false)
            }
        }
    }

    private func installMonitors() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleLocalEvent(event)
                }
                return event
            }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleGlobalEvent(event)
                }
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) {
        guard isHovered, !isMenuTracking else { return }
        let isMouseDown = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        if event.window === self.window {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.intersection(visibleRect).contains(point) {
                pendingExit?.cancel()
                pendingExit = nil
            } else {
                setHovered(false, immediate: isMouseDown)
            }
        } else if event.window != nil {
            setHovered(false, immediate: isMouseDown)
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        guard isHovered, !isMenuTracking, NSApp.isActive, let window, window.isKeyWindow else { return }
        let visible = bounds.intersection(visibleRect)
        let screenRect = window.convertToScreen(convert(visible, to: nil))
        if !screenRect.contains(NSEvent.mouseLocation) {
            setHovered(false, immediate: event.type != .mouseMoved)
        }
    }
}
