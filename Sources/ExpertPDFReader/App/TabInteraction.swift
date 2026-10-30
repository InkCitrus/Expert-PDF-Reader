import AppKit
import SwiftUI

struct TabDragLocation {
    let screenPoint: NSPoint
    /// Distance from the tab's top-left corner, in screen points.
    let grabOffset: NSPoint
    let tabSize: NSSize

    var previewFrame: NSRect {
        NSRect(x: screenPoint.x - grabOffset.x,
               y: screenPoint.y + grabOffset.y - tabSize.height,
               width: tabSize.width, height: tabSize.height)
    }
}

/// A native mouse sequence survives SwiftUI moving/rebuilding the tab while it is being dragged.
struct TabInteractionArea: NSViewRepresentable {
    let session: ReaderWindowSession
    let tabID: UUID
    let toolTip: String
    let excludedTrailingWidth: CGFloat
    let onSelect: () -> Void
    let onDragChanged: (TabDragLocation) -> Void
    let onDragEnded: (TabDragLocation?) -> Void

    func makeNSView(context: Context) -> TabInteractionView {
        let view = TabInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TabInteractionView, context: Context) {
        view.onSelect = onSelect
        view.toolTip = toolTip
        view.excludedTrailingWidth = excludedTrailingWidth
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        session.tabViews.setObject(view, forKey: tabID as NSUUID)
    }
}

final class TabInteractionView: NSView {
    var excludedTrailingWidth: CGFloat = 0
    var onSelect: (() -> Void)?
    var onDragChanged: ((TabDragLocation) -> Void)?
    var onDragEnded: ((TabDragLocation?) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.x < bounds.maxX - excludedTrailingWidth else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let frame = window.convertToScreen(convert(bounds, to: nil))
        let grabOffset = NSPoint(x: start.x - frame.minX, y: frame.maxY - start.y)
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
            let location = TabDragLocation(screenPoint: point, grabOffset: grabOffset, tabSize: frame.size)
            if next.type == .leftMouseUp {
                if isDragging { ended?(location) }
                return
            }
            if !isDragging && hypot(point.x - start.x, point.y - start.y) < 5 { continue }
            isDragging = true
            _ = autoscroll(with: next)
            changed?(location)
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
    var insertionX: CGFloat? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let insertionX else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: insertionX - 1.5, y: 4, width: 3, height: bounds.height - 8),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

extension ReaderWindowSession {
    /// Align the released tab with the same grab point after a tear-off, including its new width.
    func positionWindowForTabDrop(tabID: UUID, grabOffset: NSPoint, at point: NSPoint) {
        guard let view = tabViews.object(forKey: tabID as NSUUID), let window = view.window else { return }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let anchor = NSPoint(x: frame.minX + min(grabOffset.x, frame.width),
                             y: frame.maxY - grabOffset.y)
        // Keep the titlebar under the pointer even when the window's bottom/right extends off screen,
        // just as it can during a normal window drag. Fitting the entire window would make the tab jump.
        let origin = NSPoint(x: window.frame.minX + point.x - anchor.x,
                             y: window.frame.minY + point.y - anchor.y)
        window.setFrameOrigin(origin)
    }

    func containsTabStrip(_ point: NSPoint) -> Bool {
        guard let view = tabStripView, let window = view.window else { return false }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return rect.insetBy(dx: -12, dy: -16).contains(point)
    }

    private var documentTabFrames: [(index: Int, frame: NSRect)] {
        tabs.filter { !$0.isHome }.enumerated().compactMap { index, tab in
            guard let view = tabViews.object(forKey: tab.id as NSUUID), let window = view.window else { return nil }
            // SwiftUI can report a visibleRect larger than this representable's bounds.
            let visible = view.bounds.intersection(view.visibleRect)
            guard !visible.isNull, !visible.isEmpty else { return nil }
            return (index, window.convertToScreen(view.convert(visible, to: nil)))
        }
    }

    func nearestDocumentIndex(at point: NSPoint) -> Int? {
        documentTabFrames.min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }?.index
    }

    func documentInsertionIndex(at point: NSPoint) -> Int {
        documentTabFrames.first { point.x < $0.frame.midX }?.index ?? tabs.filter { !$0.isHome }.count
    }

    func showTabInsertion(at point: NSPoint?) {
        guard let view = tabStripView as? TabStripAnchorView, let window = view.window else { return }
        guard let point else { view.insertionX = nil; view.displayIfNeeded(); return }
        let frames = documentTabFrames
        let x = frames.first { point.x < $0.frame.midX }?.frame.minX ?? frames.last?.frame.maxX ?? point.x
        view.insertionX = view.convert(window.convertPoint(fromScreen: NSPoint(x: x, y: point.y)), from: nil).x
        view.displayIfNeeded()
    }
}

/// Lightweight drag image and insertion caret, including when crossing window boundaries.
/// The panel ignores events and never becomes key, so the native mouse sequence stays with its source.
@MainActor final class TabDragFeedback {
    private var panel: NSPanel?
    private var label: NSTextField?
    private weak var markedSession: ReaderWindowSession?

    func update(title: String, at location: TabDragLocation, target: ReaderWindowSession?) {
        if panel == nil {
            let panel = NSPanel(contentRect: location.previewFrame,
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            let view = NSView(frame: panel.contentView!.bounds)
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 12, y: (location.tabSize.height - 18) * 0.5,
                                 width: location.tabSize.width - 24, height: 18)
            label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingMiddle
            view.addSubview(label)
            panel.contentView = view
            self.panel = panel
            self.label = label
        }
        label?.stringValue = title
        panel?.setFrame(location.previewFrame, display: true)
        panel?.orderFront(nil)
        if markedSession !== target { markedSession?.showTabInsertion(at: nil) }
        markedSession = target
        target?.showTabInsertion(at: location.screenPoint)
    }

    func end() {
        markedSession?.showTabInsertion(at: nil)
        markedSession = nil
        panel?.orderOut(nil)
    }
}

struct WindowDragArea: NSViewRepresentable {
    var onClick: (() -> Void)? = nil
    func makeNSView(context: Context) -> NSView {
        let view = WindowDragView()
        view.onClick = onClick
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? WindowDragView)?.onClick = onClick }
}

final class WindowDragView: NSView {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { onClick == nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard let onClick else { window.performDrag(with: event); return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { onClick() }
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 5 {
                window.performDrag(with: event)
                return
            }
        }
    }
}
