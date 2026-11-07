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
    private var hoverArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseMoved(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) {
        // Resizing the drawer replaces tracking rectangles; an old exit must not collapse it under the pointer.
        let point = convert(event.locationInWindow, from: nil)
        onHover?(bounds.intersection(visibleRect).contains(point))
    }
}
