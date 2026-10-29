import AppKit
import Foundation
import PDFKit
import SwiftUI

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
    func settle() async { try? await Task.sleep(nanoseconds: 650_000_000) }
    func drag(_ title: String, from session: ReaderWindowSession, to point: NSPoint) async {
        let sourceWindow = session.nsWindow!
        sourceWindow.makeKeyAndOrderFront(nil)
        let start = center(title, in: session)
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
        window = NSWindow(contentRect: NSRect(x: 60, y: 90, width: 1180, height: 780),
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
            await drag("Gamma", from: primary, to: center("Alpha", in: primary))
            check(names(primary) == ["Gamma", "Alpha", "Beta"], "drag last tab to first using AppKit mouse events")
            await drag("Gamma", from: primary, to: center("Beta", in: primary))
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
            await drag("Alpha", from: primary, to: outside)
            check(store.detachedSessions.count == 1 && names(primary) == ["Beta", "Gamma"],
                  "dragging below the strip opens an independent window")
            if let detached = store.detachedSessions.first {
                check(detached.activeDocumentTab === alpha && detached.nsWindow?.isVisible == true,
                      "detaching transfers the same state into a visible native window")
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
