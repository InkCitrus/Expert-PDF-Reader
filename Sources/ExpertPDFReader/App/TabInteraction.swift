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
            // A preview may move this row into another SwiftUI section during the native sequence.
            let liveView = tabID.flatMap { session?.tabViews.object(forKey: $0 as NSUUID) } ?? self
            _ = liveView.autoscroll(with: next)
            changed?(location)
        }
        if isDragging { ended?(nil) }
    }

}

enum ReaderTabDropTarget {
    case tabStrip(ReaderWindowSession)
    case comparison(DocumentTabState)
}

/// A slot within one section, rather than a nearest tab whose two edges have ambiguous membership.
struct TabDropPlacement: Equatable {
    var beforeTabID: UUID?
    var groupID: UUID?
}

struct TabStripDragPreview {
    let tab: DocumentTabState
    let placement: TabDropPlacement
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
    var displayedTabGroups: [ReaderTabGroup] {
        guard let preview = tabDragPreview else { return tabGroups }
        return tabGroups.map { group in
            var group = group
            group.tabIDs.remove(preview.tab.id)
            if group.id == preview.placement.groupID {
                group.tabIDs.insert(preview.tab.id)
                group.isCollapsed = false
            }
            return group
        }
    }

    var displayedDocumentTabs: [DocumentTabState] {
        var documents = tabs.compactMap { tab -> DocumentTabState? in
            if case .document(let state) = tab { return state }
            return nil
        }
        guard let preview = tabDragPreview else { return documents }
        documents.removeAll { $0.id == preview.tab.id }
        let index = preview.placement.beforeTabID.flatMap { id in documents.firstIndex { $0.id == id } }
            ?? documents.count
        documents.insert(preview.tab, at: index)
        let groups = displayedTabGroups
        let groupedIDs = Set(groups.flatMap(\.tabIDs))
        return groups.flatMap { group in documents.filter { group.tabIDs.contains($0.id) } }
            + documents.filter { !groupedIDs.contains($0.id) }
    }

    func displayedTabGroup(containing tabID: UUID) -> ReaderTabGroup? {
        displayedTabGroups.first { $0.tabIDs.contains(tabID) }
    }

    func tabDropPlacement(at point: NSPoint, dragging tabID: UUID) -> TabDropPlacement {
        // The placeholder owns its slot while the pointer is inside it. Without this, moving the
        // neighboring rows can immediately reverse the last insertion and make a boundary flicker.
        if let preview = tabDragPreview, preview.tab.id == tabID,
           visibleScreenRect(tabViews.object(forKey: tabID as NSUUID))?.contains(point) == true {
            return preview.placement
        }
        let groups = displayedTabGroups
        let group = groups.first { groupScreenRect($0)?.contains(point) == true }
        let members = displayedDocumentTabs.filter {
            $0.id != tabID && displayedTabGroup(containing: $0.id)?.id == group?.id
        }
        // Dropping on the color block appends to that group, including a collapsed group.
        if let group, visibleScreenRect(tabGroupViews.object(forKey: group.id as NSUUID))?.contains(point) == true {
            return TabDropPlacement(beforeTabID: nil, groupID: group.id)
        }
        let visible = members.enumerated().compactMap { index, tab -> (index: Int, frame: NSRect)? in
            visibleScreenRect(tabViews.object(forKey: tab.id as NSUUID)).map { (index, $0) }
        }
        let originalOrder = tabs.filter { !$0.isHome }.map(\.id)
        let index = visible.first { item in
            let delta = (tabStripView as? TabStripAnchorView)?.axis == .vertical
                ? item.frame.midY - point.y : point.x - item.frame.midX
            // At the midpoint, exchange with the approached tab in the direction of travel.
            if abs(delta) <= 1, let source = originalOrder.firstIndex(of: tabID),
               let destination = originalOrder.firstIndex(of: members[item.index].id) {
                return source > destination
            }
            return delta < 0
        }?.index
            ?? visible.last.map { $0.index + 1 } ?? members.count
        return TabDropPlacement(beforeTabID: index < members.count ? members[index].id : nil, groupID: group?.id)
    }

    /// Converts the preview's section-relative slot into the model's final document index.
    func tabInsertionIndex(for placement: TabDropPlacement, excluding tabID: UUID) -> Int {
        let documents = tabs.filter { !$0.isHome && $0.id != tabID }
        if let before = placement.beforeTabID, let index = documents.firstIndex(where: { $0.id == before }) {
            return index
        }
        guard let groupID = placement.groupID, let groupIndex = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            return documents.count
        }
        let precedingIDs = Set(tabGroups.prefix(groupIndex + 1).flatMap(\.tabIDs))
        return documents.filter { precedingIDs.contains($0.id) }.count
    }

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

    func clearTabInsertion() {
        guard let view = tabStripView as? TabStripAnchorView else { return }
        view.insertionPosition = nil
        view.displayIfNeeded()
    }
}

/// Lightweight drag image and live placement preview, including when crossing window boundaries.
/// The panel ignores events and never becomes key, so the native mouse sequence stays with its source.
@MainActor final class TabDragFeedback {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var documentIcon: NSImageView?
    private var closeIcon: NSImageView?
    private weak var markedSession: ReaderWindowSession?
    private weak var markedComparison: ComparisonDropView?

    func update(title: String, isDark: Bool, at location: TabDragLocation, target: ReaderTabDropTarget?,
                tab: DocumentTabState? = nil, isSidebar: Bool = false) {
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
            let documentIcon = NSImageView()
            documentIcon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            view.addSubview(documentIcon)
            let closeIcon = NSImageView()
            closeIcon.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            view.addSubview(closeIcon)
            panel.contentView = view
            self.panel = panel
            self.label = label
            self.documentIcon = documentIcon
            self.closeIcon = closeIcon
        }
        // A detached panel does not inherit the source window's appearance. Use the same explicit
        // palette as its tab strip instead of resolving a dynamic NSColor into a light CGColor.
        panel?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel?.contentView?.layer?.backgroundColor = NSColor(AppPalette.tabSelectedBackground(isDark)).cgColor
        panel?.contentView?.layer?.borderColor = NSColor(AppPalette.tabSeparator(isDark)).cgColor
        label?.textColor = NSColor(AppPalette.labelPrimary(isDark))
        label?.stringValue = title
        let session: ReaderWindowSession?
        let comparison: ComparisonDropView?
        switch target {
        case .tabStrip(let targetSession): (session, comparison) = (targetSession, nil)
        case .comparison(let tab): (session, comparison) = (nil, tab.comparisonDropView)
        case nil: (session, comparison) = (nil, nil)
        }
        if markedSession !== session {
            markedSession?.tabDragPreview = nil
            markedSession?.clearTabInsertion()
        }
        if markedComparison !== comparison {
            markedComparison?.highlight(false)
            comparison?.highlight(true)
        }
        markedSession = session
        markedComparison = comparison
        if let session, let tab {
            let placement = session.tabDropPlacement(at: location.screenPoint, dragging: tab.id)
            if session.tabDragPreview?.tab.id != tab.id || session.tabDragPreview?.placement != placement {
                session.tabDragPreview = TabStripDragPreview(tab: tab, placement: placement)
            }
            session.clearTabInsertion()
        }
        var frame = location.previewFrame
        let slidesInStrip = session?.tabs.contains { $0.id == tab?.id } == true
        if slidesInStrip, let session, let tab,
           let row = session.tabViews.object(forKey: tab.id as NSUUID), let window = row.window {
            let rowFrame = window.convertToScreen(row.convert(row.bounds, to: nil))
            if isSidebar { frame.origin.x = rowFrame.minX; frame.size.width = rowFrame.width }
            else { frame.origin.y = rowFrame.minY }
        }
        panel?.hasShadow = !slidesInStrip
        panel?.contentView?.layer?.borderWidth = slidesInStrip ? 0 : 0.5
        panel?.contentView?.layer?.cornerRadius = 6
        panel?.setFrame(frame, display: true)
        let hasDocumentIcon = tab != nil && isSidebar
        let isCompact = isSidebar && frame.width < 80
        let grouped = tab.flatMap { session?.displayedTabGroup(containing: $0.id) } != nil
        let iconLeading: CGFloat = grouped ? 2 : 10
        let leading: CGFloat = hasDocumentIcon ? iconLeading + 22 : 12
        let trailing: CGFloat = tab != nil ? 30 : 12
        let labelWidth = max(0, frame.width - leading - trailing)
        func textHeight(_ text: String) -> CGFloat {
            // Reserve the text field cell's horizontal insets before measuring wrapped text.
            ceil((text as NSString).boundingRect(with: NSSize(width: max(1, labelWidth - 8), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).height)
        }
        var displayedTitle = title
        if isSidebar && !isCompact && textHeight(title) > 32 {
            // AppKit clips wrapped labels at two lines. Fit a middle ellipsis explicitly so the
            // distinguishing filename ending remains visible while the original row is moving.
            let characters = Array(title)
            func shortened(_ count: Int) -> String {
                String(characters.prefix((count + 1) / 2)) + "…" + String(characters.suffix(count / 2))
            }
            var lower = 0, upper = characters.count - 1
            while lower < upper {
                let middle = (lower + upper + 1) / 2
                if textHeight(shortened(middle)) <= 32 { lower = middle }
                else { upper = middle - 1 }
            }
            displayedTitle = shortened(lower)
        }
        label?.stringValue = displayedTitle
        let labelHeight: CGFloat = isSidebar ? max(18, min(32, textHeight(displayedTitle))) : 18
        label?.frame = NSRect(x: leading, y: (frame.height - labelHeight) / 2, width: labelWidth, height: labelHeight)
        label?.isHidden = isCompact
        label?.maximumNumberOfLines = isSidebar ? 2 : 1
        (label?.cell as? NSTextFieldCell)?.wraps = isSidebar
        documentIcon?.isHidden = !hasDocumentIcon
        documentIcon?.contentTintColor = NSColor(AppPalette.accentBlue)
        documentIcon?.frame = NSRect(x: isCompact ? (frame.width - 17) / 2 : iconLeading,
                                    y: (frame.height - 22) / 2, width: 17, height: 22)
        closeIcon?.isHidden = tab == nil || isCompact
        closeIcon?.contentTintColor = NSColor(AppPalette.labelSecondary(isDark))
        closeIcon?.frame = NSRect(x: frame.width - 26, y: (frame.height - 18) / 2, width: 18, height: 18)
        panel?.orderFront(nil)
    }

    func end() {
        markedSession?.tabDragPreview = nil
        markedSession?.clearTabInsertion()
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
