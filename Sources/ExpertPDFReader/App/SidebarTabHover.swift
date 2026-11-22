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
    private lazy var hoverArea = NSTrackingArea(rect: .zero,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
        owner: self, userInfo: nil)
    private var pendingExit: Task<Void, Never>?
    private var isHovered = false

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
        if window == nil {
            pendingExit?.cancel()
            pendingExit = nil
            isHovered = false
        }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(for: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(for: event) }
    override func mouseExited(with event: NSEvent) { updateHover(for: event) }

    private func updateHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.intersection(visibleRect).contains(point) {
            pendingExit?.cancel()
            pendingExit = nil
            if !isHovered {
                isHovered = true
                onHover?(true)
            }
        } else if isHovered && pendingExit == nil {
            // Give the pointer a moment to cross back over the floating edge before closing.
            pendingExit = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                pendingExit = nil
                isHovered = false
                onHover?(false)
            }
        }
    }
}
