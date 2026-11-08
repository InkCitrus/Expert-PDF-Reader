import AppKit
import Foundation
import PDFKit
import SwiftUI

final class DragQAWindow: NSWindow {
    var windowDragEvents: [NSEvent] = []
    override func performDrag(with event: NSEvent) { windowDragEvents.append(event) }
}

@MainActor
final class DragQARunner: NSObject, NSApplicationDelegate {
    var store: AppStore!
    var window: NSWindow!
    var fixtureDirectory: URL!
    var failures: [String] = []
    var checks: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        let passed = condition()
        print("\(passed ? "PASS" : "FAIL") \(message)")
        checks.append("\(passed ? "PASS" : "FAIL") \(message)")
        if !passed { failures.append(message) }
    }
    func names(_ session: ReaderWindowSession) -> [String] {
        session.tabs.compactMap { if case .document(let tab) = $0 { return tab.title }; return nil }
    }
    func tab(_ title: String, in session: ReaderWindowSession) -> DocumentTabState {
        session.tabs.compactMap { if case .document(let tab) = $0 { return tab }; return nil }.first { $0.title == title }!
    }
    func center(_ title: String, in session: ReaderWindowSession) -> NSPoint {
        let view = session.tabViews.object(forKey: tab(title, in: session).id as NSUUID)!
        return view.window!.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }
    func tabsAreInContent(_ session: ReaderWindowSession) -> Bool {
        guard let window = session.nsWindow, let strip = session.tabStripView else { return false }
        let rect = window.convertToScreen(strip.convert(strip.bounds, to: nil))
        return !window.titlebarAccessoryViewControllers.isEmpty && abs(rect.maxY - window.frame.maxY) < 2
            && abs(rect.height - MainWindowView.tabStripHeight) < 1
    }

    func tabsAreInSidebar(_ session: ReaderWindowSession) -> Bool {
        guard let window = session.nsWindow, let strip = session.tabStripView else { return false }
        let rect = window.convertToScreen(strip.convert(strip.bounds, to: nil))
        return abs(rect.minX - window.frame.minX) < 2 && rect.height > MainWindowView.tabStripHeight
            && rect.maxY <= window.frame.maxY - MainWindowView.tabStripHeight + 1
    }
    func settle() async { try? await Task.sleep(nanoseconds: 650_000_000) }

    func keepWindowOnScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = NSPoint(x: visible.minX, y: visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // Drive the public AppKit tracking callbacks inside this QA app, without moving the user's mouse.
    func hoverSidebar(_ entered: Bool, in session: ReaderWindowSession) async {
        guard let view = session.sidebarTabHoverView, let window = view.window else {
            check(false, "the sidebar has a native hover region")
            return
        }
        let local = NSPoint(x: entered ? view.bounds.midX : view.bounds.maxX + 40, y: view.bounds.midY)
        let event = NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited,
            location: view.convert(local, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        if entered { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
        await settle()
    }

    func checkSidebarExpansionStaysLevel(in session: ReaderWindowSession) async {
        await hoverSidebar(false, in: session)
        func frames() -> [UUID: NSRect] {
            var result: [UUID: NSRect] = [:]
            let rows = session.tabGroups.map { ($0.id, session.tabGroupViews.object(forKey: $0.id as NSUUID)) }
                + session.tabs.filter { !$0.isHome && session.tabGroup(containing: $0.id)?.isCollapsed != true }
                    .map { ($0.id, session.tabViews.object(forKey: $0.id as NSUUID)) }
            for (id, view) in rows {
                guard let view, let window = view.window else { continue }
                result[id] = window.convertToScreen(view.convert(view.bounds, to: nil))
            }
            return result
        }
        let before = frames()
        guard let hover = session.sidebarTabHoverView, let window = hover.window else {
            check(false, "the sidebar expansion has a native hover region")
            return
        }
        let event = NSEvent.enterExitEvent(with: .mouseEntered,
            location: hover.convert(NSPoint(x: hover.bounds.midX, y: hover.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        hover.mouseEntered(with: event)
        var staysLevel = !before.isEmpty
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 35_000_000)
            let current = frames()
            for (id, initial) in before {
                guard let frame = current[id] else { staysLevel = false; continue }
                staysLevel = staysLevel && abs(frame.minY - initial.minY) < 1 && abs(frame.maxY - initial.maxY) < 1
            }
        }
        await settle()
        check(staysLevel, "expanding the sidebar keeps group, grouped-tab and ungrouped-tab rows at the same vertical positions throughout the animation")
        let exit = NSEvent.enterExitEvent(with: .mouseExited,
            location: hover.convert(NSPoint(x: hover.bounds.maxX + 40, y: hover.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        hover.mouseExited(with: exit)
        try? await Task.sleep(nanoseconds: 60_000_000)
        check(session.tabStripView!.bounds.width > 48,
              "closing the drawer preserves the full text layout while its visible edge moves")
        await settle()
        if session.tabStripView!.bounds.width > 48 {
            print("INFO close widths strip=\(session.tabStripView!.bounds.width), hover=\(session.sidebarTabHoverView?.bounds.width ?? 0), preview=\(session.tabDragPreview != nil)")
        }
        check(session.tabStripView!.bounds.width <= 48,
              "the closed drawer returns to compact hit regions after the animation")
        await hoverSidebar(true, in: session)
    }

    func tabIsVisible(_ tab: DocumentTabState, in session: ReaderWindowSession) -> Bool {
        guard let view = session.tabViews.object(forKey: tab.id as NSUUID), view.window != nil else { return false }
        let visible = view.bounds.intersection(view.visibleRect)
        return !visible.isNull && visible.width >= view.bounds.width - 1 && visible.height >= view.bounds.height - 1
    }

    func checkPreviewThemes() {
        let feedback = TabDragFeedback()
        let savedAppearance = NSApp.appearance
        defer { feedback.end(); NSApp.appearance = savedAppearance }
        let location = TabDragLocation(screenPoint: NSPoint(x: 400, y: 500),
                                       grabOffset: NSPoint(x: 45, y: 13), tabSize: NSSize(width: 260, height: 40))
        var firstPanel: NSPanel?
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        for isDark in [true, false, true] {
            // The app and source tab may have different appearances. Reuse the same floating panel.
            NSApp.appearance = NSAppearance(named: isDark ? .aqua : .darkAqua)
            let focus = NSApp.keyWindow
            feedback.update(title: "F77YB – Foundations of Statistical Inference", isDark: isDark, at: location, target: nil)
            guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.ignoresMouseEvents && $0.isVisible }) as? NSPanel,
                  let view = panel.contentView, let background = view.layer?.backgroundColor,
                  let fill = NSColor(cgColor: background),
                  let label = view.subviews.compactMap({ $0 as? NSTextField }).first, let ink = label.textColor else {
                check(false, "drag preview appears with a readable title"); return
            }
            let lightness = luminance(fill)
            let contrast = (max(lightness, luminance(ink)) + 0.05) / (min(lightness, luminance(ink)) + 0.05)
            check(isDark ? lightness < 0.12 : lightness > 0.8,
                  "\(isDark ? "dark" : "light") drag preview follows the source theme despite the opposite app appearance")
            check(contrast >= 4.5, "drag title has at least 4.5:1 contrast against its background")
            check(NSApp.keyWindow === focus && !panel.isKeyWindow && panel.ignoresMouseEvents,
                  "themed preview preserves keyboard focus and ignores mouse events")
            if let firstPanel { check(panel === firstPanel, "the same preview updates when its theme changes") }
            else { firstPanel = panel }
            if let directory = ProcessInfo.processInfo.environment["TAB_DRAG_QA_EVIDENCE_DIR"],
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("tab-drag-preview-\(isDark ? "dark" : "light").png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            let sidebarLocation = TabDragLocation(screenPoint: location.screenPoint, grabOffset: location.grabOffset,
                                                   tabSize: NSSize(width: 260, height: 44))
            for (kind, title) in [("short", "Gamma"), ("long", "F77YB - Foundations of Statistical Inference - Chapter 5 - Drawing Conclusions from Data")] {
                feedback.update(title: title, isDark: isDark, at: sidebarLocation, target: nil,
                                tab: store.primarySession.activeDocumentTab, isSidebar: true)
                check(abs(label.frame.midY - view.bounds.midY) < 1 && (kind != "short" || label.frame.height == 18),
                      "\(isDark ? "dark" : "light") \(kind) drag title is vertically centered without an empty text line")
                if kind == "long" {
                    check(label.stringValue.contains("…") && label.stringValue.hasPrefix("F77YB") && label.stringValue.hasSuffix("Data"),
                          "long drag titles preserve their distinguishing ending in two lines")
                }
                if let directory = ProcessInfo.processInfo.environment["TAB_DRAG_QA_EVIDENCE_DIR"],
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("sidebar-drag-\(kind)-\(isDark ? "dark" : "light").png")
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    func drag(_ title: String, from session: ReaderWindowSession, to point: NSPoint,
              grabFraction: CGFloat = 0.5, onMove: ((TabDragLocation) -> Void)? = nil) async {
        let view = session.tabViews.object(forKey: tab(title, in: session).id as NSUUID)! as! TabInteractionView
        await dragView(title, view: view, from: session, to: point, grabFraction: grabFraction, onMove: onMove)
    }

    func dragView(_ title: String, view: TabInteractionView, from session: ReaderWindowSession, to point: NSPoint,
                  grabFraction: CGFloat = 0.5, stepDelay: Double = 0, cancel: Bool = false, holdAtEnd: Double = 0,
                  onMove: ((TabDragLocation) -> Void)? = nil) async {
        let sourceWindow = session.nsWindow!
        sourceWindow.makeKeyAndOrderFront(nil)
        let originalFrame = sourceWindow.frame
        let tabFrame = sourceWindow.convertToScreen(view.convert(view.bounds, to: nil))
        let start = NSPoint(x: tabFrame.minX + tabFrame.width * grabFraction, y: tabFrame.maxY - 13)
        let expectedOffset = NSPoint(x: start.x - tabFrame.minX, y: tabFrame.maxY - start.y)
        var previewChecks = 0
        var anchored = true
        // Install immediately before delivery: pending SwiftUI updates can replace the view's callbacks.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            let changed = view.onDragChanged
            view.onDragChanged = { location in
                changed?(location)
                onMove?(location)
                guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.ignoresMouseEvents && $0.isVisible }) else {
                    anchored = false
                    return
                }
                previewChecks += 1
                if view.isSidebar && ["Alpha", "Beta", "Gamma"].contains(title),
                   let content = panel.contentView,
                   let label = content.subviews.compactMap({ $0 as? NSTextField }).first, !label.isHidden {
                    anchored = anchored && label.frame.height <= 18
                        && abs(label.frame.midY - content.bounds.midY) < 1
                }
                // AppKit rounds top-level window origins to integral screen points.
                if session.tabDragPreview?.tab.id == view.tabID,
                   let row = view.tabID.flatMap({ session.tabViews.object(forKey: $0 as NSUUID) }), let window = row.window {
                    let frame = window.convertToScreen(row.convert(row.bounds, to: nil))
                    if view.isSidebar {
                        anchored = anchored && abs(panel.frame.minX - frame.minX) <= 1
                            && abs(panel.frame.width - frame.width) <= 1
                            && abs(panel.frame.maxY - location.screenPoint.y - expectedOffset.y) <= 1
                    } else {
                        anchored = anchored && abs(panel.frame.minY - frame.minY) <= 1
                            && abs(location.screenPoint.x - panel.frame.minX - expectedOffset.x) <= 1
                    }
                    anchored = anchored && panel.frame.height == tabFrame.height
                } else {
                    anchored = anchored && abs(location.screenPoint.x - panel.frame.minX - expectedOffset.x) <= 1
                        && abs(panel.frame.maxY - location.screenPoint.y - expectedOffset.y) <= 1
                        && panel.frame.size == tabFrame.size
                }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let timestamp = ProcessInfo.processInfo.systemUptime
        func post(_ type: NSEvent.EventType, _ globalPoint: NSPoint, _ delta: Double) {
            let event = NSEvent.mouseEvent(with: type, location: sourceWindow.convertPoint(fromScreen: globalPoint),
                modifierFlags: [], timestamp: timestamp + delta, windowNumber: sourceWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
        }
        post(.leftMouseDown, start, 0)
        for step in 1...20 {
            let t = CGFloat(step) / 20
            let position = NSPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
            if stepDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * stepDelay) {
                    post(.leftMouseDragged, position, Double(t) * 0.35)
                }
            } else { post(.leftMouseDragged, position, Double(t) * 0.35) }
        }
        func finish() {
            if cancel {
                NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: timestamp + 0.4, windowNumber: sourceWindow.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: false)
            } else { post(.leftMouseUp, point, 0.4) }
        }
        if stepDelay > 0 {
            if holdAtEnd > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 20 * stepDelay + 0.01) { print("INFO inspecting dragged tab") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 21 * stepDelay + holdAtEnd) { finish() }
            try? await Task.sleep(nanoseconds: UInt64((22 * stepDelay + holdAtEnd) * 1_000_000_000))
        } else { finish() }
        await settle()
        check(sourceWindow.frame == originalFrame, "dragging \(title) leaves the source window frame unchanged")
        check(previewChecks > 0 && anchored, "dragged tab preserves its grab point, stays aligned inside the strip and follows the pointer freely outside it")
    }

    func click(_ view: NSView, at localPoint: NSPoint? = nil) async {
        let window = view.window!
        let point = view.convert(localPoint ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
        }
        await settle()
    }

    func checkHomePanel(_ session: ReaderWindowSession) {
        let before = store.isLeftPanelVisible(in: session)
        store.toggleLeftPanel(in: session)
        check(store.isLeftPanelVisible(in: session) != before, "the sidebar switch also works on Home")
        store.toggleLeftPanel(in: session)
    }

    func homeDragView(in view: NSView) -> WindowDragView? {
        if let view = view as? WindowDragView, view.onClick != nil { return view }
        return view.subviews.lazy.compactMap { self.homeDragView(in: $0) }.first
    }

    func checkHomeDrag(_ home: NSView, in session: ReaderWindowSession) async {
        let window = home.window! as! DragQAWindow
        let selectedID = session.selectedTabID
        let tabOrder = session.tabs.map(\.id)
        let start = home.convert(NSPoint(x: home.bounds.midX, y: home.bounds.midY), to: nil)
        let drag = NSPoint(x: start.x + 50, y: start.y - 40)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, drag), (.leftMouseUp, drag)] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
        }
        await settle()
        check(window.windowDragEvents.count == 1 && window.windowDragEvents.first?.type == .leftMouseDown
              && window.windowDragEvents.first?.locationInWindow == start,
              "Home drag hands its original mouse-down event to native window dragging")
        check(session.selectedTabID == selectedID && session.tabs.map(\.id) == tabOrder,
              "Home drag neither selects Home nor reorders document tabs")
    }

    func checkSidebarTabs(_ primary: ReaderWindowSession) async {
        let originalOrder = names(primary)
        let originalTab = primary.activeDocumentTab
        store.tabsInSidebar = true
        await settle()
        check(tabsAreInSidebar(primary) && names(primary) == originalOrder && primary.activeDocumentTab === originalTab,
              "moving tabs into the sidebar preserves tab order and selection")
        check(abs((primary.tabStripView?.bounds.width ?? 0) - 48) < 1,
              "sidebar tabs start as a compact rail without a pin setting")
        await hoverSidebar(true, in: primary)
        check((primary.tabStripView?.bounds.width ?? 0) >= 360,
              "hovering the rail expands the floating document list")

        store.activateWindowSession(primary.id)
        store.toggleLeftPanel(in: primary)
        store.showSidebarTab(.outline)
        await settle()
        check(originalTab?.activeSidebarTab == .outline && store.isLeftPanelVisible(in: primary)
              && tabsAreInSidebar(primary),
              "opening the outline keeps the independent document tab rail visible")
        store.toggleLeftPanel(in: primary)
        await settle()
        check(!store.isLeftPanelVisible(in: primary) && tabsAreInSidebar(primary)
              && primary.activeDocumentTab === originalTab,
              "hiding page navigation leaves the document tabs and selected PDF intact")
        store.showSidebarTab(.outline)

        store.openNewHomeTab(in: primary.id)
        await settle()
        check(primary.activeDocumentTab == nil && tabsAreInSidebar(primary),
              "going Home leaves the independent sidebar tab list visible")
        if let originalTab { primary.selectedTabID = originalTab.id }
        await settle()

        await drag("Gamma", from: primary, to: center("Beta", in: primary))
        check(names(primary) == ["Gamma", "Beta", "Alpha"] && primary.activeDocumentTab?.title == "Gamma",
              "dragging vertically reorders and selects a sidebar tab")

        let gamma = tab("Gamma", in: primary)
        var outside = center("Gamma", in: primary)
        outside.x += 300
        await drag("Gamma", from: primary, to: outside)
        if let detached = store.detachedSessions.first {
            check(tabsAreInSidebar(detached) && detached.activeDocumentTab === gamma && names(primary) == ["Beta", "Alpha"],
                  "a sidebar tab tears off into a window with the same layout")
            window.setFrame(NSRect(x: 40, y: 350, width: 820, height: 600), display: true)
            detached.nsWindow?.setFrame(NSRect(x: 400, y: 80, width: 820, height: 600), display: true)
            await settle()
            var destination = center("Alpha", in: primary)
            destination.y += 8
            await drag("Gamma", from: detached, to: destination)
            check(store.detachedSessions.isEmpty && names(primary) == ["Beta", "Gamma", "Alpha"],
                  "cross-window sidebar drops insert before the correct row")
        } else {
            check(false, "a sidebar tab tears off into a window with the same layout")
        }

        let reordered = names(primary)
        if let originalTab { primary.selectedTabID = originalTab.id }
        await hoverSidebar(false, in: primary)
        check(abs((primary.tabStripView?.bounds.width ?? 0) - 48) < 1,
              "leaving the floating document list collapses it")
        store.tabsInSidebar = false
        await settle()
        check(tabsAreInContent(primary) && names(primary) == reordered && primary.activeDocumentTab === originalTab,
              "returning to the titlebar preserves the reordered tabs and reading state")
    }

    func checkManyTabs(_ primary: ReaderWindowSession) async {
        let originalTabs = primary.tabs
        let originalSelection = primary.selectedTabID
        let originalFrame = window.frame
        keepWindowOnScreen()
        var extra: [DocumentTabState] = []
        let source = tab("Alpha", in: primary).documentID.url
        let openedAt = ProcessInfo.processInfo.systemUptime
        for index in 1...57 {
            let folder = fixtureDirectory.appendingPathComponent("Collection \(index)")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let title = index <= 2 ? "Repeated document title" : String(format: "%02d", index)
                + " — Foundations of Statistical Inference — Long document title with 中文文件名 and a distinct ending \(index)"
            let url = folder.appendingPathComponent(title).appendingPathExtension("pdf")
            try! FileManager.default.copyItem(at: source, to: url)
            if let tab = store.openDocument(at: url, recordInRecents: false, interactive: false, in: primary.id) {
                extra.append(tab)
            }
        }
        await settle()
        print(String(format: "INFO opened 60 small PDFs and laid out the tabs in %.2fs",
                     ProcessInfo.processInfo.systemUptime - openedAt))
        check(names(primary).count == 60 && extra.count == 57, "60 independent document tabs open without dropping any files")
        check(extra.prefix(2).allSatisfy { store.disambiguatedFolder(for: $0) != nil },
              "identical filenames remain distinguishable by their parent folders")
        guard let first = primary.tabs.compactMap({ if case .document(let tab) = $0 { return tab }; return nil }).first,
              let last = extra.last else { return }
        for sidebar in [true, false] {
            store.tabsInSidebar = sidebar
            await settle()
            if sidebar { await hoverSidebar(true, in: primary) }
            for selected in [first, last, extra[27], first, last] {
                primary.selectedTabID = selected.id
                await settle()
                check(tabIsVisible(selected, in: primary),
                      "\(sidebar ? "sidebar" : "top") tabs scroll to selected document \(selected === first ? "at the start" : selected === last ? "at the end" : "in the middle")")
                if selected === extra[27], let strip = primary.tabStripView {
                    let documents = primary.tabs.filter { !$0.isHome }
                    let lastVisible = documents.indices.last { index in
                        guard let view = primary.tabViews.object(forKey: documents[index].id as NSUUID) else { return false }
                        let visible = view.bounds.intersection(view.visibleRect)
                        return !visible.isNull && !visible.isEmpty
                    }!
                    let frame = window.convertToScreen(strip.convert(strip.bounds, to: nil))
                    let edge = sidebar ? NSPoint(x: frame.midX, y: frame.minY + 0.1)
                                       : NSPoint(x: frame.maxX - 0.1, y: frame.midY)
                    let externalID = UUID()
                    let placement = primary.tabDropPlacement(at: edge, dragging: externalID)
                    check(lastVisible < 59 && primary.tabInsertionIndex(for: placement, excluding: externalID) == lastVisible + 1,
                          "\(sidebar ? "sidebar" : "top") dropping at the viewport edge inserts after the visible row rather than after all 60 tabs")
                }
            }
            let view = primary.tabViews.object(forKey: last.id as NSUUID)!
            check(view.toolTip == last.documentID.url.path,
                  "\(sidebar ? "sidebar" : "top") long filenames retain the complete path tooltip")
            store.selectNextTab(in: primary.id)
            await settle()
            check(primary.activeDocumentTab === first && tabIsVisible(first, in: primary),
                  "\(sidebar ? "sidebar" : "top") keyboard switching wraps from the last tab to the first")
            store.selectPreviousTab(in: primary.id)
            await settle()
            check(primary.activeDocumentTab === last && tabIsVisible(last, in: primary),
                  "\(sidebar ? "sidebar" : "top") keyboard switching wraps back to the last tab")
            if sidebar {
                let preceding = extra[55]
                await drag(last.title, from: primary, to: center(preceding.title, in: primary))
                check(names(primary).suffix(2) == [last.title, preceding.title],
                      "reordering near the end of a scrolled 60-tab sidebar targets the correct documents")
                store.moveDocumentTab(id: last.id, toDocumentIndex: 59, in: primary.id)
                await settle()
                await hoverSidebar(false, in: primary)
            }
        }
        store.tabsInSidebar = true
        await settle()
        await hoverSidebar(true, in: primary)
        primary.selectedTabID = first.id
        await settle()
        var openPanelAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let panel = NSApp.modalWindow as? NSOpenPanel {
                openPanelAppeared = true
                panel.cancel(nil)
            }
        }
        if let strip = primary.tabStripView {
            await click(strip, at: NSPoint(x: strip.bounds.maxX - 12, y: strip.bounds.minY + 28))
            await settle()
        }
        check(openPanelAppeared, "Open File remains visible and its full row is clickable with 60 tabs scrolled to the start")
        let groupA = store.createTabGroup(name: "Lectures", containing: first.id, in: primary.id)!
        for state in extra.prefix(19) { store.moveTab(state.id, intoGroup: groupA, in: primary.id) }
        let groupB = store.createTabGroup(name: "Papers", containing: extra[19].id, in: primary.id)!
        for state in extra[20..<39] { store.moveTab(state.id, intoGroup: groupB, in: primary.id) }
        let groupC = store.createTabGroup(name: "Books", containing: extra[39].id, in: primary.id)!
        for state in extra[40...] { store.moveTab(state.id, intoGroup: groupC, in: primary.id) }
        for id in [groupA, groupB, groupC] { primary.toggleTabGroup(id) }
        await settle()
        check(primary.tabGroups.map(\.tabIDs.count) == [20, 20, 18]
              && extra.allSatisfy { primary.tabViews.object(forKey: $0.id as NSUUID)?.window == nil },
              "60 open tabs collapse into three named groups without leaving hidden rows in the sidebar")
        store.tabsInSidebar = false
        await settle()
        check(primary.tabGroups.allSatisfy(\.isCollapsed)
              && primary.tabGroupViews.object(forKey: groupC as NSUUID)?.window != nil,
              "switching the grouped 60-tab session to the top bar preserves collapsed groups")
        store.tabsInSidebar = true
        await settle()
        await hoverSidebar(true, in: primary)
        primary.selectedTabID = first.id
        await settle()
        check(primary.tabGroup(containing: first.id)?.isCollapsed == false && tabIsVisible(first, in: primary),
              "selecting a member of the grouped 60-tab session reveals the correct group")
        for id in [groupA, groupB, groupC] { store.ungroupTabs(id, in: primary.id) }
        primary.selectedTabID = last.id
        await settle()
        store.closeTab(id: last.id, in: primary.id)
        await settle()
        check(names(primary).count == 59 && primary.activeDocumentTab != nil
              && tabIsVisible(primary.activeDocumentTab!, in: primary),
              "closing a selected tab at the end of a long sidebar leaves its replacement visible")
        store.reopenClosedTab(in: primary.id)
        await settle()
        check(names(primary).count == 60 && primary.activeDocumentTab?.documentID == last.documentID
              && tabIsVisible(primary.activeDocumentTab!, in: primary),
              "reopening the closed tab restores it visibly without losing the long list")
        window.setContentSize(NSSize(width: 600, height: 520))
        keepWindowOnScreen()
        await settle()
        await hoverSidebar(true, in: primary)
        if !tabIsVisible(primary.activeDocumentTab!, in: primary) || abs((primary.tabStripView?.bounds.width ?? 0) - 360) >= 1 {
            print("INFO resized strip \(primary.tabStripView?.bounds ?? .zero), selected visible \(tabIsVisible(primary.activeDocumentTab!, in: primary))")
        }
        check(abs((primary.tabStripView?.bounds.width ?? 0) - 360) < 1 && tabIsVisible(primary.activeDocumentTab!, in: primary),
              "the expanded tab list remains usable in a minimum-size window with 60 tabs")
        await hoverSidebar(false, in: primary)
        check(abs((primary.tabStripView?.bounds.width ?? 0) - 48) < 1,
              "the long tab list still collapses after resizing")
        for state in primary.tabs.compactMap({ if case .document(let tab) = $0 { return tab }; return nil })
            where !originalTabs.contains(where: { $0.id == state.id }) {
            store.closeTab(id: state.id, in: primary.id)
        }
        primary.selectedTabID = originalSelection
        store.tabsInSidebar = false
        window.setFrame(originalFrame, display: true)
        await settle()
        check(primary.tabs.map(\.id) == originalTabs.map(\.id), "closing the extra test tabs restores the original session")
    }

    func checkGroupBoundaryDrag(_ session: ReaderWindowSession, groupID: UUID, sidebar: Bool) async {
        let alpha = tab("Alpha", in: session), beta = tab("Beta", in: session), gamma = tab("Gamma", in: session)
        let layout = sidebar ? "sidebar" : "top"
        func frame(_ id: UUID) -> NSRect {
            let view = session.tabViews.object(forKey: id as NSUUID)!
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        let last = frame(gamma.id)
        let inside = sidebar ? NSPoint(x: last.midX, y: last.minY + 5)
                             : NSPoint(x: last.maxX - 5, y: last.midY)
        var previewedEnd = false
        var savedModelUntouched = true
        let originalTabs = session.tabs.map(\.id), originalGroups = session.tabGroups
        let betaView = session.tabViews.object(forKey: beta.id as NSUUID) as! TabInteractionView
        let hold = sidebar && ProcessInfo.processInfo.environment["TAB_DRAG_QA_INSPECT"] == "layout" ? 15.0 : 0
        await dragView("Beta", view: betaView, from: session, to: inside, stepDelay: 0.03, holdAtEnd: hold) { _ in
            savedModelUntouched = savedModelUntouched && session.tabs.map(\.id) == originalTabs && session.tabGroups == originalGroups
            if session.tabDragPreview?.placement == TabDropPlacement(beforeTabID: nil, groupID: groupID) {
                previewedEnd = session.displayedDocumentTabs.map(\.id) == [alpha.id, gamma.id, beta.id]
                    && session.displayedTabGroup(containing: beta.id)?.id == groupID
            }
        }
        check(previewedEnd && savedModelUntouched,
              "\(layout) dragging to a group's final edge previews the last member without saving an intermediate order")
        check(session.tabGroup(containing: beta.id)?.id == groupID && names(session) == ["Alpha", "Gamma", "Beta"],
              "\(layout) releasing at the inner end adds the tab last inside the group")
        let end = frame(beta.id)
        let outside = sidebar ? NSPoint(x: end.midX, y: end.minY - 12)
                              : NSPoint(x: end.maxX + 12, y: end.midY)
        var previewedOutside = false
        await dragView("Beta", view: session.tabViews.object(forKey: beta.id as NSUUID) as! TabInteractionView,
                       from: session, to: outside, stepDelay: 0.03, cancel: true) { _ in
            previewedOutside = previewedOutside || (session.tabDragPreview?.placement.groupID == nil
                && session.tabDragPreview != nil && session.displayedTabGroup(containing: beta.id) == nil)
        }
        check(previewedOutside && session.tabDragPreview == nil && session.tabGroup(containing: beta.id)?.id == groupID,
              "\(layout) crossing the group end previews an ungrouped slot and Escape restores membership")
        await dragView("Beta", view: session.tabViews.object(forKey: beta.id as NSUUID) as! TabInteractionView,
                       from: session, to: outside, stepDelay: 0.03)
        check(session.tabGroup(containing: beta.id) == nil && session.tabGroup(containing: gamma.id)?.id == groupID,
              "\(layout) releasing beyond the end removes only the dragged tab from its group")
        session.selectedTabID = alpha.id
        await settle()
    }

    func checkTabGroups(_ primary: ReaderWindowSession) async {
        let originalFrame = window.frame
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        window.setContentSize(NSSize(width: 1400, height: 780))
        keepWindowOnScreen()
        let alpha = tab("Alpha", in: primary), beta = tab("Beta", in: primary), gamma = tab("Gamma", in: primary)
        let groupID = store.createTabGroup(name: "Coursework", containing: alpha.id, in: primary.id)!
        store.moveTab(gamma.id, intoGroup: groupID, in: primary.id)
        primary.selectedTabID = alpha.id
        for sidebar in [true, false] {
            NSApp.appearance = NSAppearance(named: sidebar ? .aqua : .darkAqua)
            let papersID = store.createTabGroup(name: "Papers", containing: beta.id, in: primary.id)!
            store.tabsInSidebar = sidebar
            await settle()
            if sidebar { await hoverSidebar(true, in: primary) }
            store.renameTabGroup(papersID, name: " ")
            await settle()
            if let blankHeader = primary.tabGroupViews.object(forKey: papersID as NSUUID) {
                check(blankHeader.bounds.width >= 24 && blankHeader.toolTip == primary.tabGroups.first { $0.id == papersID }?.color.title,
                      "\(sidebar ? "sidebar" : "top") unnamed groups retain a clickable color block and a color-name tooltip")
                await click(blankHeader)
                check(primary.tabGroup(containing: beta.id)?.isCollapsed == true && primary.activeDocumentTab === alpha,
                      "\(sidebar ? "sidebar" : "top") unnamed groups can collapse without changing the active PDF")
                if let blankHeader = primary.tabGroupViews.object(forKey: papersID as NSUUID) { await click(blankHeader) }
                check(primary.tabGroup(containing: beta.id)?.isCollapsed == false && tabIsVisible(beta, in: primary),
                      "\(sidebar ? "sidebar" : "top") unnamed groups can expand again")
            } else { check(false, "an unnamed group retains its native hit region") }
            store.renameTabGroup(papersID, name: "Papers")
            await settle()
            if sidebar && ProcessInfo.processInfo.environment["TAB_DRAG_QA_INSPECT"] == "1" {
                print("INFO inspecting sidebar groups; strip=\(primary.tabStripView?.bounds ?? .zero), groups=\(primary.tabGroups.count)")
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
            if sidebar && ProcessInfo.processInfo.environment["TAB_DRAG_QA_INSPECT"] == "layout" {
                print("INFO inspecting expanded group gutter")
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await hoverSidebar(false, in: primary)
                print("INFO inspecting compact icon alignment")
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await hoverSidebar(true, in: primary)
            }
            guard let header = primary.tabGroupViews.object(forKey: groupID as NSUUID) else {
                print("INFO expected group \(groupID), model groups \(primary.tabGroups.map(\.id)), window visible \(window.isVisible), session window matches \(primary.nsWindow === window)")
                func describe(_ view: NSView) {
                    if let tab = view as? TabInteractionView {
                        print("INFO native row \(tab.isGroupHeader ? "GROUP" : "DOC") \(tab.tabID?.uuidString ?? "nil") bounds=\(tab.bounds) visible=\(tab.visibleRect) session matches \(tab.session === primary), window matches \(tab.window === window)")
                    }
                    if let scroll = view as? NSScrollView {
                        print("INFO scroll bounds=\(scroll.bounds) offset=\(scroll.contentView.bounds) document=\(scroll.documentView?.bounds ?? .zero)")
                    }
                    for child in view.subviews { describe(child) }
                }
                describe(window.contentView!)
                check(false, "group header appears in \(sidebar ? "sidebar" : "top") tabs"); continue
            }
            if let papers = primary.tabGroupViews.object(forKey: papersID as NSUUID) as? TabInteractionView {
                let before = window.convertPoint(toScreen: header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil))
                await dragView("Papers", view: papers, from: primary, to: before)
                check(primary.tabGroups.first?.id == papersID && primary.activeDocumentTab === alpha,
                      "\(sidebar ? "sidebar" : "top") dragging a group moves its entire document block without changing the PDF")
                let after = center("Gamma", in: primary)
                await dragView("Papers", view: primary.tabGroupViews.object(forKey: papersID as NSUUID)! as! TabInteractionView,
                               from: primary, to: after)
                check(primary.tabGroups.map(\.id) == [groupID, papersID],
                      "\(sidebar ? "sidebar" : "top") groups can also be reordered after another group")
            }
            await click(header)
            check(primary.tabGroup(containing: alpha.id)?.isCollapsed == true && primary.activeDocumentTab === alpha,
                  "\(sidebar ? "sidebar" : "top") group collapse keeps the currently displayed PDF")
            check(primary.tabViews.object(forKey: alpha.id as NSUUID)?.window == nil
                  && primary.tabViews.object(forKey: gamma.id as NSUUID)?.window == nil,
                  "\(sidebar ? "sidebar" : "top") collapsed groups hide all their document rows")
            store.selectNextTab(in: primary.id)
            await settle()
            check(primary.activeDocumentTab === gamma && primary.tabGroup(containing: gamma.id)?.isCollapsed == false
                  && tabIsVisible(gamma, in: primary),
                  "\(sidebar ? "sidebar" : "top") keyboard switching reveals a tab inside a collapsed group")
            let target = window.convertPoint(toScreen: header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil))
            await drag("Beta", from: primary, to: target)
            check(primary.tabGroups.count == 1 && primary.tabGroup(containing: beta.id)?.id == groupID
                  && primary.tabGroups[0].tabIDs.count == 3,
                  "\(sidebar ? "sidebar" : "top") dragging onto a group moves the tab into that group and removes an empty source group")
            store.moveTab(beta.id, intoGroup: nil, in: primary.id)
            primary.selectedTabID = alpha.id
            await settle()
            check(primary.tabGroup(containing: beta.id) == nil && primary.tabGroups[0].tabIDs.count == 2,
                  "\(sidebar ? "sidebar" : "top") removing a tab from a group keeps every document open")
            if sidebar { await checkSidebarExpansionStaysLevel(in: primary) }
            await checkGroupBoundaryDrag(primary, groupID: groupID, sidebar: sidebar)
            await drag("Gamma", from: primary, to: center("Beta", in: primary))
            check(primary.tabGroup(containing: gamma.id) == nil && primary.tabGroup(containing: alpha.id)?.id == groupID,
                  "\(sidebar ? "sidebar" : "top") dropping onto ungrouped documents removes group membership")
            store.moveTab(gamma.id, intoGroup: groupID, in: primary.id)
            primary.selectedTabID = alpha.id
            await settle()
            if sidebar, let strip = primary.tabStripView,
               let betaView = primary.tabViews.object(forKey: beta.id as NSUUID) as? TabInteractionView {
                // A few tabs put Open File immediately after the list. Its drag target occupies the same row.
                let last = primary.tabViews.object(forKey: beta.id as NSUUID)!
                let lastFrame = window.convertToScreen(last.convert(last.bounds, to: nil))
                let target = NSPoint(x: window.frame.minX + strip.bounds.width * 0.5, y: lastFrame.minY - 40)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let sheet = self.window.attachedSheet, let root = sheet.contentView else { return }
                    func fill(_ view: NSView) {
                        if let field = view as? NSTextField, field.isEditable { field.stringValue = "New from Drag" }
                        for child in view.subviews { fill(child) }
                    }
                    func confirm(_ view: NSView) -> NSButton? {
                        if let button = view as? NSButton, button.title == L10n.tr("创建分组", "Create Group") { return button }
                        return view.subviews.lazy.compactMap(confirm).first
                    }
                    fill(root)
                    confirm(root)?.performClick(nil)
                }
                await dragView("Beta", view: betaView, from: primary, to: target, stepDelay: 0.03)
                await settle()
                let created = primary.tabGroup(containing: beta.id)
                check(created?.name == "New from Drag", "the New Group drop target creates a named group from the dragged tab")
                if let created { store.ungroupTabs(created.id, in: primary.id) }
            }
            if sidebar { await hoverSidebar(false, in: primary) }
        }
        store.renameTabGroup(groupID, name: "Lectures", in: primary.id)
        check(primary.tabGroups.first?.name == "Lectures", "renaming a group updates the shared sidebar and top-tab model")
        store.ungroupTabs(groupID, in: primary.id)
        check(primary.tabGroups.isEmpty && names(primary).count == 3, "ungrouping preserves all three documents")
        store.tabsInSidebar = false
        window.setFrame(originalFrame, display: true)
        primary.selectedTabID = alpha.id
        await settle()
    }

    func finish(_ domain: String) {
        let log = checks.joined(separator: "\n") + "\n"
        try? log.write(toFile: CommandLine.arguments[0] + ".results", atomically: true, encoding: .utf8)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: fixtureDirectory)
        print(failures.isEmpty ? "All AppKit drag checks passed" : "AppKit drag checks failed")
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }

    func resizeHandle(in view: NSView, axis: Axis) -> ReaderResizeHandle.Handle? {
        if let handle = view as? ReaderResizeHandle.Handle, handle.axis == axis { return handle }
        return view.subviews.lazy.compactMap { self.resizeHandle(in: $0, axis: axis) }.first
    }

    func dragDivider(in view: ReaderResizeHandle.Handle, by offset: NSPoint, from point: NSPoint? = nil) async {
        let start = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + offset.x, y: start.y + offset.y)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
        }
        await settle()
    }

    func checkTopTabsSidebarResize(_ primary: ReaderWindowSession) async {
        let selectedID = primary.selectedTabID
        guard let handle = resizeHandle(in: window.contentView!, axis: .horizontal) else {
            check(false, "the document sidebar has a resize handle with tabs in the titlebar")
            return
        }
        let originalWidth = handle.length
        let documentSide = NSPoint(x: handle.bounds.midX + 2, y: handle.bounds.midY)
        await dragDivider(in: handle, by: NSPoint(x: 48, y: 0), from: documentSide)
        check(abs(handle.length - originalWidth - 48) < 1,
              "the titlebar-tab document sidebar resizes from the document side of the divider")

        store.selectHomeTab(in: primary.id)
        await settle()
        if let homeHandle = resizeHandle(in: window.contentView!, axis: .horizontal) {
            check(abs(homeHandle.length - originalWidth - 48) < 1, "Home shares the new sidebar width")
            await dragDivider(in: homeHandle, by: NSPoint(x: -48, y: 0))
            check(abs(homeHandle.length - originalWidth) < 1, "the Home sidebar can also be dragged")
        } else {
            check(false, "the Home sidebar has a resize handle with tabs in the titlebar")
        }
        primary.selectedTabID = selectedID
        await settle()
    }

    func checkSplitComparison(_ primary: ReaderWindowSession) async {
        let alpha = tab("Alpha", in: primary)
        let beta = tab("Beta", in: primary)
        window.setFrame(NSRect(x: 40, y: 75, width: 1100, height: 680), display: true)
        primary.selectedTabID = alpha.id
        beta.navigateToPage(2)
        alpha.splitMode = .vertical
        alpha.showSplitDocumentPicker = true
        await settle()
        guard let pane = alpha.comparisonDropView, let handle = resizeHandle(in: window.contentView!, axis: .horizontal) else {
            check(false, "the vertical split has a divider and a comparison drop target")
            return
        }
        let initialWidth = pane.bounds.width
        await dragDivider(in: handle, by: NSPoint(x: 105, y: 0))
        let comparisonWidth = pane.bounds.width
        check(comparisonWidth < initialWidth - 80, "dragging the vertical divider resizes the comparison pane")

        let order = names(primary)
        let dropPoint = window.convertPoint(toScreen: pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil))
        var keptPrimary = true
        var highlighted = false
        await drag("Beta", from: primary, to: dropPoint) { location in
            keptPrimary = keptPrimary && primary.activeDocumentTab === alpha
            if pane.containsScreenPoint(location.screenPoint), pane.layer?.borderWidth == 2 { highlighted = true }
        }
        check(keptPrimary && highlighted && primary.activeDocumentTab === alpha && names(primary) == order
              && store.detachedSessions.isEmpty && alpha.secondaryDocumentURL == beta.documentID.url
              && alpha.secondaryPageIndex == 2 && alpha.secondaryPDFDocument !== beta.pdfDocument,
              "dragging an inactive tab highlights and fills the comparison without selecting or moving the tab")
        check(alpha.comparisonDropView?.layer?.borderWidth != 2, "comparison drop feedback clears after release")
        alpha.activatePane(isSecondary: false)
        alpha.triggerZoom(.scale(1.35))
        alpha.activatePane(isSecondary: true)
        alpha.triggerZoom(.scale(0.9))
        await settle()
        let zooms = (alpha.zoomScale, alpha.secondaryZoomScale)
        let comparisonPage = alpha.secondaryPageIndex
        await click(primary.tabViews.object(forKey: beta.id as NSUUID)!)
        check(primary.activeDocumentTab === beta, "releasing a tab without dragging still selects it")
        await click(primary.tabViews.object(forKey: alpha.id as NSUUID)!)
        let restoredWidth = alpha.comparisonDropView?.bounds.width ?? 0
        check(primary.activeDocumentTab === alpha && abs(restoredWidth - comparisonWidth) <= 1,
              "returning to a tab restores its split divider (\(comparisonWidth) → \(restoredWidth))")
        check(abs(alpha.zoomScale - zooms.0) < 0.005 && abs(alpha.secondaryZoomScale - zooms.1) < 0.005
              && alpha.secondaryPageIndex == comparisonPage,
              "returning to a tab preserves its two zooms and comparison page")

        alpha.splitMode = .horizontal
        store.tabsInSidebar = true
        await settle()
        if let pane = alpha.comparisonDropView, let handle = resizeHandle(in: window.contentView!, axis: .vertical) {
            let initialHeight = pane.bounds.height
            await dragDivider(in: handle, by: NSPoint(x: 0, y: -70))
            let resizedPane = alpha.comparisonDropView ?? pane
            let newHeight = resizedPane.bounds.height
            check(newHeight < initialHeight - 55, "dragging the horizontal divider resizes the comparison pane (\(initialHeight) → \(newHeight))")
            let point = window.convertPoint(toScreen: resizedPane.convert(
                NSPoint(x: resizedPane.bounds.midX, y: resizedPane.bounds.midY), to: nil))
            await drag("Gamma", from: primary, to: point)
            check(primary.activeDocumentTab === alpha && names(primary) == order
                  && alpha.secondaryDocumentURL == tab("Gamma", in: primary).documentID.url,
                  "sidebar tabs can also be dropped onto an already loaded comparison")
        } else {
            check(false, "the horizontal split has a divider and a comparison drop target")
        }
        alpha.splitMode = .disabled
        store.tabsInSidebar = false
        await settle()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        store = AppStore()
        fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TabDragQA-\(UUID())")
        try! FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 600, height: 800), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            return true
        }
        for title in ["Alpha", "Beta", "Gamma"] {
            let url = fixtureDirectory.appendingPathComponent(title).appendingPathExtension("pdf")
            let document = PDFDocument()
            for index in 0..<4 { document.insert(PDFPage(image: image)!, at: index) }
            precondition(document.write(to: url), "Could not create QA fixture")
            store.openDocument(at: url, interactive: false)
        }
        window = DragQAWindow(contentRect: NSRect(x: 60, y: 90, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowView(store: store, session: store.primarySession))
        store.primarySession.nsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await settle()
            let primary = store.primarySession
            if ProcessInfo.processInfo.environment["TAB_DRAG_QA_FOCUS"] == "preview" {
                checkPreviewThemes()
                finish(domain)
                return
            }
            if ProcessInfo.processInfo.environment["TAB_DRAG_QA_FOCUS"] == "groups" {
                await checkTabGroups(primary)
                finish(domain)
                return
            }
            check(names(primary) == ["Alpha", "Beta", "Gamma"], "three real document tabs appear")
            check(tabsAreInContent(primary), "primary tabs use the unified native titlebar accessory")
            checkPreviewThemes()
            let home = window.titlebarAccessoryViewControllers.compactMap { homeDragView(in: $0.view) }.first!
            let beforeHomeClick = window.frame
            await click(home)
            check(primary.activeDocumentTab == nil && window.frame == beforeHomeClick,
                  "Home click selects Home without moving the window")
            checkHomePanel(primary)
            primary.selectedTabID = tab("Gamma", in: primary).id
            await settle()
            await checkHomeDrag(home, in: primary)
            let gammaView = primary.tabViews.object(forKey: tab("Gamma", in: primary).id as NSUUID)!
            await click(gammaView, at: NSPoint(x: gammaView.bounds.maxX - 17, y: gammaView.bounds.midY))
            check(names(primary) == ["Alpha", "Beta"], "full-width tab interaction still lets the close button receive clicks")
            store.reopenClosedTab(in: primary.id)
            await settle()
            await drag("Gamma", from: primary, to: center("Alpha", in: primary), grabFraction: 0.1)
            check(names(primary) == ["Gamma", "Alpha", "Beta"], "drag last tab to first using AppKit mouse events")
            await drag("Gamma", from: primary, to: center("Beta", in: primary), grabFraction: 0.8)
            check(names(primary) == ["Alpha", "Beta", "Gamma"], "drag first tab to last at the release position")
            await drag("Alpha", from: primary, to: center("Beta", in: primary))
            check(names(primary) == ["Beta", "Alpha", "Gamma"] && primary.activeDocumentTab?.title == "Alpha",
                  "dragging an unselected tab selects and reorders it")
            let alpha = tab("Alpha", in: primary)
            alpha.currentPageIndex = 2
            alpha.zoomScale = 1.3
            alpha.isAutoScaling = false
            alpha.readingSpot = .init(pageIndex: 2, point: CGPoint(x: 200, y: 400))
            var outside = center("Alpha", in: primary)
            outside.y -= 150
            let alphaView = primary.tabViews.object(forKey: alpha.id as NSUUID)!
            let grabOffset = NSPoint(x: alphaView.bounds.width * 0.5, y: 13)
            await drag("Alpha", from: primary, to: outside)
            check(store.detachedSessions.count == 1 && names(primary) == ["Beta", "Gamma"],
                  "dragging below the strip opens an independent window")
            if let detached = store.detachedSessions.first {
                check(tabsAreInContent(detached), "detached tabs use the unified native titlebar accessory")
                check(detached.activeDocumentTab === alpha && detached.nsWindow?.isVisible == true,
                      "detaching transfers the same state into a visible native window")
                let newView = detached.tabViews.object(forKey: alpha.id as NSUUID)!
                let newFrame = newView.window!.convertToScreen(newView.convert(newView.bounds, to: nil))
                check(abs(newFrame.minX + grabOffset.x - outside.x) <= 1
                      && abs(newFrame.maxY - grabOffset.y - outside.y) <= 1,
                      "released tab stays under its original grab point after detaching")
                window.setFrame(NSRect(x: 40, y: 350, width: 820, height: 600), display: true)
                detached.nsWindow?.setFrame(NSRect(x: 400, y: 80, width: 820, height: 600), display: true)
                await settle()
                var destination = center("Gamma", in: primary)
                destination.x -= 24
                await drag("Alpha", from: detached, to: destination)
                check(store.detachedSessions.isEmpty && names(primary) == ["Beta", "Alpha", "Gamma"],
                      "dragging back merges at the actual target tab and closes the empty window")
                check(primary.activeDocumentTab === alpha && alpha.currentPageIndex == 2 && store.closedTabs.isEmpty,
                      "cross-window dragging keeps reading state without creating a closed-tab record")
            }
            await checkSidebarTabs(primary)
            await checkTopTabsSidebarResize(primary)
            await checkSplitComparison(primary)
            await checkManyTabs(primary)
            await checkTabGroups(primary)
            let renamed = fixtureDirectory.appendingPathComponent("Alpha-renamed.pdf")
            let active = primary.activeDocumentTab!
            try! FileManager.default.moveItem(at: active.documentID.url, to: renamed)
            await settle()
            check(active.documentID == DocumentID(url: renamed), "file vnode notification follows a rename without polling")
            let removed = tab("Beta", in: primary).documentID
            store.setFavorite(id: removed, isFavorite: true)
            try! FileManager.default.removeItem(at: removed.url)
            await settle()
            check(!store.recentDocumentIDs.contains(removed) && !store.favoriteDocumentIDs.contains(removed),
                  "file vnode deletion removes recents and favorites automatically")
            check(primary.tabs.contains { if case .document(let tab) = $0 { return tab.documentID == removed }; return false }
                  && !store.documents.contains { $0.documentID == removed },
                  "deleting a source file retains its open tab but removes its Home entry")
            finish(domain)
        }
    }
}

@main
struct TabDragQATests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let runner = DragQARunner()
        app.delegate = runner
        app.run()
        withExtendedLifetime(runner) {}
    }
}
