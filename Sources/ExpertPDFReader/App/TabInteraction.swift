import AppKit
import SwiftUI

/// A layout switch briefly mounts both titlebar and sidebar views. An outgoing view must not
/// overwrite the incoming view's hit region and then leave a nil weak reference behind.
@MainActor
final class ReaderTabViewRegistry {
    private final class Entry {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var entries: [UUID: [Entry]] = [:]

    func setObject(_ view: NSView, forKey key: NSUUID) {
        let id = key as UUID
        var candidates = entries[id, default: []].filter { $0.view != nil && $0.view !== view }
        candidates.append(Entry(view))
        entries[id] = candidates
    }

    func object(forKey key: NSUUID) -> NSView? {
        let candidates = entries[key as UUID, default: []].compactMap(\.view).reversed()
        let sidebar = UserDefaults.standard.bool(forKey: "expertPDFReader.tabsInSidebar")
        return candidates.first { ($0 as? TabInteractionView)?.isSidebar == sidebar && $0.window != nil }
            ?? candidates.first { $0.window != nil }
    }
}

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
    var isGroupHeader = false
    var isSidebar = false
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
        view.session = session
        view.tabID = tabID
        view.isGroupHeader = isGroupHeader
        view.isSidebar = isSidebar
        let views = isGroupHeader ? session.tabGroupViews : session.tabViews
        views.setObject(view, forKey: tabID as NSUUID)
    }
}

final class TabInteractionView: NSView {
    weak var session: ReaderWindowSession?
    var tabID: UUID?
    var isGroupHeader = false
    var isSidebar = false
    var excludedTrailingWidth: CGFloat = 0
    var onSelect: (() -> Void)?
    var onDragChanged: ((TabDragLocation) -> Void)?
    var onDragEnded: ((TabDragLocation?) -> Void)?

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerIfAttached() }
    override func layout() { super.layout(); registerIfAttached() }

    func registerIfAttached() {
        guard let session, let tabID else { return }
        let views = isGroupHeader ? session.tabGroupViews : session.tabViews
        if window != nil { views.setObject(self, forKey: tabID as NSUUID) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let contextClick = NSApp.currentEvent.map {
            $0.type == .rightMouseDown || ($0.type == .leftMouseDown && $0.modifierFlags.contains(.control))
        } ?? false
        guard contextClick || local.x < bounds.maxX - excludedTrailingWidth else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        guard let window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let frame = window.convertToScreen(convert(bounds, to: nil))
        let grabOffset = NSPoint(x: start.x - frame.minX, y: frame.maxY - start.y)
        // Keep the currently displayed comparison open until we know this is a click.
        let select = onSelect
        let changed = onDragChanged
        let ended = onDragEnded
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
                if isDragging {
                    ended?(location)
                } else if frame.contains(point) {
                    select?()
                }
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

enum ReaderTabDropTarget {
    case tabStrip(ReaderWindowSession)
    case comparison(DocumentTabState)
}

struct ComparisonDropArea: NSViewRepresentable {
    let tab: DocumentTabState

    func makeNSView(context: Context) -> ComparisonDropView {
        ComparisonDropView()
    }

    func updateNSView(_ view: ComparisonDropView, context: Context) {
        tab.comparisonDropView = view
    }
}

final class ComparisonDropView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return bounds.intersection(visibleRect).contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    func highlight(_ highlighted: Bool) {
        if highlighted { wantsLayer = true }
        layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor : nil
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = highlighted ? 2 : 0
    }
}

struct TabStripAnchor: NSViewRepresentable {
    let session: ReaderWindowSession
    let axis: Axis

    func makeNSView(context: Context) -> NSView {
        let view = TabStripAnchorView()
        view.session = session
        view.axis = axis
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class TabStripAnchorView: NSView {
    weak var session: ReaderWindowSession?
    var axis: Axis = .horizontal
    var insertionPosition: CGFloat? { didSet { needsDisplay = true } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            session?.tabStripView = self
        } else if session?.tabStripView === self {
            session?.tabStripView = nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let insertionPosition else { return }
        let caret: NSRect
        if axis == .vertical {
            caret = NSRect(x: 6, y: insertionPosition - 1.5, width: bounds.width - 12, height: 3)
        } else {
            caret = NSRect(x: insertionPosition - 1.5, y: 4, width: 3, height: bounds.height - 8)
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: caret, xRadius: 1.5, yRadius: 1.5).fill()
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
        var seenGroups = Set<UUID>()
        var frames: [(index: Int, frame: NSRect)] = []
        for (index, tab) in tabs.filter({ !$0.isHome }).enumerated() {
            if let group = tabGroup(containing: tab.id), seenGroups.insert(group.id).inserted,
               let view = tabGroupViews.object(forKey: group.id as NSUUID), let window = view.window {
                let visible = view.bounds.intersection(view.visibleRect)
                if !visible.isNull && !visible.isEmpty {
                    frames.append((index, window.convertToScreen(view.convert(visible, to: nil))))
                }
            }
            if tabGroup(containing: tab.id)?.isCollapsed == true { continue }
            guard let view = tabViews.object(forKey: tab.id as NSUUID), let window = view.window else { continue }
            // SwiftUI can report a visibleRect larger than this representable's bounds.
            let visible = view.bounds.intersection(view.visibleRect)
            guard !visible.isNull, !visible.isEmpty else { continue }
            frames.append((index, window.convertToScreen(view.convert(visible, to: nil))))
        }
        return frames
    }

    func tabGroup(at point: NSPoint) -> ReaderTabGroup? {
        if visibleScreenRect(ungroupedTabDropView)?.contains(point) == true { return nil }
        return tabGroups.first { groupScreenRect($0)?.contains(point) == true }
    }

    func isNewTabGroupDrop(at point: NSPoint) -> Bool {
        visibleScreenRect(newTabGroupDropView)?.contains(point) == true
    }

    private func visibleScreenRect(_ view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isNull && !visible.isEmpty else { return nil }
        return window.convertToScreen(view.convert(visible, to: nil))
    }

    private func groupScreenRect(_ group: ReaderTabGroup) -> NSRect? {
        var views = [tabGroupViews.object(forKey: group.id as NSUUID)]
        if !group.isCollapsed { views += group.tabIDs.map { tabViews.object(forKey: $0 as NSUUID) } }
        let frames = views.compactMap(visibleScreenRect)
        return frames.isEmpty ? nil : frames.reduce(NSRect.null) { $0.union($1) }
    }

    func groupInsertionTarget(at point: NSPoint) -> UUID? {
        tabGroups.first { group in
            guard let frame = groupScreenRect(group) else { return false }
            return (tabStripView as? TabStripAnchorView)?.axis == .vertical ? point.y > frame.midY : point.x < frame.midX
        }?.id
    }

    func showGroupInsertion(at point: NSPoint) {
        guard let strip = tabStripView as? TabStripAnchorView, let window = strip.window else { return }
        let next = groupInsertionTarget(at: point).flatMap { id in tabGroups.first { $0.id == id } }.flatMap(groupScreenRect)
        let last = tabGroups.last.flatMap(groupScreenRect)
        let screen = strip.axis == .vertical
            ? NSPoint(x: point.x, y: next?.maxY ?? last?.minY ?? point.y)
            : NSPoint(x: next?.minX ?? last?.maxX ?? point.x, y: point.y)
        let local = strip.convert(window.convertPoint(fromScreen: screen), from: nil)
        strip.insertionPosition = strip.axis == .vertical ? local.y : local.x
        strip.displayIfNeeded()
    }

    func nearestDocumentIndex(at point: NSPoint) -> Int? {
        if (tabStripView as? TabStripAnchorView)?.axis == .vertical {
            return documentTabFrames.min { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) }?.index
        }
        return documentTabFrames.min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }?.index
    }

    func documentInsertionIndex(at point: NSPoint) -> Int {
        let frames = documentTabFrames
        return frames.first { isBeforeTab($0.frame, at: point) }?.index
            ?? frames.last.map { last in
                let documents = tabs.filter { !$0.isHome }
                if let group = tabGroup(containing: documents[last.index].id), group.isCollapsed {
                    return documents.lastIndex(where: { group.tabIDs.contains($0.id) })! + 1
                }
                return last.index + 1
            } ?? tabs.filter { !$0.isHome }.count
    }

    private func isBeforeTab(_ frame: NSRect, at point: NSPoint) -> Bool {
        if (tabStripView as? TabStripAnchorView)?.axis == .vertical {
            return point.y > frame.midY
        }
        return point.x < frame.midX
    }

    func showTabInsertion(at point: NSPoint?) {
        guard let view = tabStripView as? TabStripAnchorView, let window = view.window else { return }
        guard var point else { view.insertionPosition = nil; view.displayIfNeeded(); return }
        let frames = documentTabFrames
        let next = frames.first { isBeforeTab($0.frame, at: point) }?.frame
        if view.axis == .vertical {
            point.y = next?.maxY ?? frames.last?.frame.minY ?? point.y
        } else {
            point.x = next?.minX ?? frames.last?.frame.maxX ?? point.x
        }
        let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
        view.insertionPosition = view.axis == .vertical ? local.y : local.x
        view.displayIfNeeded()
    }
}

struct TabDropZoneAnchor: NSViewRepresentable {
    let onAttach: (NSView) -> Void
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.onAttach = onAttach
        if view.window != nil { onAttach(view) }
    }
    final class AnchorView: NSView {
        var onAttach: ((NSView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttach?(self) }
        }
    }
}

/// Lightweight drag image and insertion caret, including when crossing window boundaries.
/// The panel ignores events and never becomes key, so the native mouse sequence stays with its source.
@MainActor final class TabDragFeedback {
    private var panel: NSPanel?
    private var label: NSTextField?
    private weak var markedSession: ReaderWindowSession?
    private weak var markedComparison: ComparisonDropView?

    func update(title: String, isDark: Bool, at location: TabDragLocation, target: ReaderTabDropTarget?) {
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
            view.layer?.masksToBounds = true
            view.layer?.borderWidth = 0.5
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
        // A detached panel does not inherit the source window's appearance. Use the same explicit
        // palette as its tab strip instead of resolving a dynamic NSColor into a light CGColor.
        panel?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel?.contentView?.layer?.backgroundColor = NSColor(AppPalette.tabSelectedBackground(isDark)).cgColor
        panel?.contentView?.layer?.borderColor = NSColor(AppPalette.tabSeparator(isDark)).cgColor
        label?.textColor = NSColor(AppPalette.labelPrimary(isDark))
        label?.stringValue = title
        panel?.setFrame(location.previewFrame, display: true)
        panel?.orderFront(nil)
        let session: ReaderWindowSession?
        let comparison: ComparisonDropView?
        switch target {
        case .tabStrip(let targetSession): (session, comparison) = (targetSession, nil)
        case .comparison(let tab): (session, comparison) = (nil, tab.comparisonDropView)
        case nil: (session, comparison) = (nil, nil)
        }
        if markedSession !== session { markedSession?.showTabInsertion(at: nil) }
        if markedComparison !== comparison {
            markedComparison?.highlight(false)
            comparison?.highlight(true)
        }
        markedSession = session
        markedComparison = comparison
        session?.showTabInsertion(at: location.screenPoint)
    }

    func end() {
        markedSession?.showTabInsertion(at: nil)
        markedSession = nil
        markedComparison?.highlight(false)
        markedComparison = nil
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
