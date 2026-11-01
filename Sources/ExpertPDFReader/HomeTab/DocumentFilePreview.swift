import AppKit
import SwiftUI

/// A tooltip-sized, nonactivating window: showing a filename must not consume the click that opens it.
final class DocumentFilePreview {
    private var timer: Timer?
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    deinit { hide() }

    func show(_ url: URL, near anchor: NSViewAnchor, isDark: Bool) {
        hide()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak anchor] _ in
            guard let view = anchor?.view, let window = view.window,
                  NSApp.isActive, window.isVisible, !view.visibleRect.isEmpty else { return }
            self?.present(url, near: view, in: window, isDark: isDark)
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
    }

    private func present(_ url: URL, near view: NSView, in window: NSWindow, isDark: Bool) {
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width = min(360, screen.width - 24)
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(url.deletingLastPathComponent().path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .preferredColorScheme(isDark ? .dark : .light)
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let below = anchor.minY - size.height - 8
        let y = below >= screen.minY + 8 ? below : anchor.maxY + 8
        let origin = NSPoint(x: min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8),
                             y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8))
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = hosting
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.hide() }
    }
}
