import AppKit
import SwiftUI

/// A native mouse sequence survives SwiftUI moving/rebuilding the tab while it is being dragged.
struct TabInteractionArea: NSViewRepresentable {
    let session: ReaderWindowSession
    let tabID: UUID
    let toolTip: String
    let onSelect: () -> Void
    let onDragChanged: (NSPoint) -> Void
    let onDragEnded: (NSPoint?) -> Void

    func makeNSView(context: Context) -> TabInteractionView {
        let view = TabInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TabInteractionView, context: Context) {
        view.onSelect = onSelect
        view.toolTip = toolTip
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        session.tabViews.setObject(view, forKey: tabID as NSUUID)
    }
}

final class TabInteractionView: NSView {
    var onSelect: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint?) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        // Keep callbacks alive even if SwiftUI replaces this view after selection or reordering.
        let changed = onDragChanged
        let ended = onDragEnded
        onSelect?()
        var isDragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 {
                    if isDragging { ended?(nil) }
                    return
                }
                continue
            }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .leftMouseUp {
                if isDragging { ended?(point) }
                return
            }
            if !isDragging && hypot(point.x - start.x, point.y - start.y) < 5 { continue }
            isDragging = true
            _ = autoscroll(with: next)
            changed?(point)
        }
        if isDragging { ended?(nil) }
    }
}

struct TabStripAnchor: NSViewRepresentable {
    let session: ReaderWindowSession

    func makeNSView(context: Context) -> NSView {
        let view = TabStripAnchorView()
        session.tabStripView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        session.tabStripView = view
    }
}

private final class TabStripAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

extension ReaderWindowSession {
    func containsTabStrip(_ point: NSPoint) -> Bool {
        guard let view = tabStripView, let window = view.window else { return false }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return rect.insetBy(dx: -12, dy: -16).contains(point)
    }

    private var documentTabFrames: [(index: Int, frame: NSRect)] {
        tabs.filter { !$0.isHome }.enumerated().compactMap { index, tab in
            guard let view = tabViews.object(forKey: tab.id as NSUUID), let window = view.window,
                  !view.visibleRect.isEmpty else { return nil }
            return (index, window.convertToScreen(view.convert(view.visibleRect, to: nil)))
        }
    }

    func nearestDocumentIndex(at point: NSPoint) -> Int? {
        documentTabFrames.min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }?.index
    }

    func documentInsertionIndex(at point: NSPoint) -> Int {
        documentTabFrames.first { point.x < $0.frame.midX }?.index ?? tabs.filter { !$0.isHome }.count
    }
}
