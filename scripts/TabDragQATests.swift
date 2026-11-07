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
            && rect.maxY < window.frame.maxY - MainWindowView.tabStripHeight
    }
    func settle() async { try? await Task.sleep(nanoseconds: 650_000_000) }

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
        }
    }

    func drag(_ title: String, from session: ReaderWindowSession, to point: NSPoint,
              grabFraction: CGFloat = 0.5, onMove: ((TabDragLocation) -> Void)? = nil) async {
        let sourceWindow = session.nsWindow!
        sourceWindow.makeKeyAndOrderFront(nil)
        let originalFrame = sourceWindow.frame
        let view = session.tabViews.object(forKey: tab(title, in: session).id as NSUUID)! as! TabInteractionView
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
                // AppKit rounds top-level window origins to integral screen points.
                anchored = anchored && abs(location.screenPoint.x - panel.frame.minX - expectedOffset.x) <= 1
                    && abs(panel.frame.maxY - location.screenPoint.y - expectedOffset.y) <= 1
                    && panel.frame.size == tabFrame.size
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
            post(.leftMouseDragged, NSPoint(x: start.x + (point.x - start.x) * t,
                 y: start.y + (point.y - start.y) * t), Double(t) * 0.35)
        }
        post(.leftMouseUp, point, 0.4)
        await settle()
        check(sourceWindow.frame == originalFrame, "dragging \(title) leaves the source window frame unchanged")
        check(previewChecks > 0 && anchored, "drag preview preserves the \(Int(grabFraction * 100))% grab point and full tab size")
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
        UserDefaults.standard.set(true, forKey: "expertPDFReader.sidebarTabsPinned")
        store.tabsInSidebar = true
        await settle()
        check(tabsAreInSidebar(primary) && names(primary) == originalOrder && primary.activeDocumentTab === originalTab,
              "moving tabs into the sidebar preserves tab order and selection")
        check((primary.tabStripView?.bounds.width ?? 0) >= 180,
              "pinning the sidebar keeps the document titles expanded")

        store.activateWindowSession(primary.id)
        primary.toggleSidebarVisibility()
        store.showSidebarTab(.outline)
        await settle()
        check(primary.sidebarPanel == .navigation
              && originalTab?.activeSidebarTab == .outline && !tabsAreInSidebar(primary),
              "opening the outline from a hidden sidebar replaces the document list")

        primary.sidebarPanel = .openDocuments
        await settle()
        check(tabsAreInSidebar(primary) && primary.activeDocumentTab === originalTab,
              "returning to open documents keeps the selected PDF")

        store.openNewHomeTab(in: primary.id)
        await settle()
        check(primary.activeDocumentTab == nil && primary.sidebarPanel == .openDocuments && tabsAreInSidebar(primary),
              "going Home leaves the sidebar tab list visible")
        primary.sidebarPanel = .openDocuments
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
        store.tabsInSidebar = false
        await settle()
        check(tabsAreInContent(primary) && names(primary) == reordered && primary.activeDocumentTab === originalTab,
              "returning to the titlebar preserves the reordered tabs and reading state")
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
        primary.sidebarPanel = .openDocuments
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
            let log = checks.joined(separator: "\n") + "\n"
            try? log.write(toFile: CommandLine.arguments[0] + ".results", atomically: true, encoding: .utf8)
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: fixtureDirectory)
            print(failures.isEmpty ? "All AppKit drag checks passed" : "AppKit drag checks failed")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
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
