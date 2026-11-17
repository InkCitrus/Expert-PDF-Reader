import AppKit
import PDFKit

@MainActor final class AccessibilityGeometryQARunner: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var failures = 0
    func check(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL") \(message)")
        if !passed { failures += 1 }
    }
    func allElements(_ view: PDFView) -> [NSAccessibilityElement] {
        func visit(_ objects: [Any]) -> [NSAccessibilityElement] {
            objects.flatMap { object -> [NSAccessibilityElement] in
                guard let element = object as? NSAccessibilityElement else { return [] }
                return [element] + visit(element.accessibilityChildren() ?? [])
            }
        }
        return visit(view.accessibilityChildren() ?? [])
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let document = PDFDocument(url: URL(fileURLWithPath: env["SELECTION_QA_DOCUMENT"]!))!
            let index = Int(env["SELECTION_QA_PAGE"]!)! - 1
            let page = document.page(at: index)!
            let link = PDFAnnotation(bounds: CGRect(x: 20, y: 320, width: 20, height: 15), forType: .link, withProperties: nil)
            link.action = PDFActionGoTo(destination: PDFDestination(page: document.page(at: index + 1)!, at: CGPoint(x: 0, y: 792)))
            link.contents = "QA page link"
            page.addAnnotation(link) // Only this disposable in-memory document; never write the source file.
            let view = ThemedPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 1000))
            view.document = document
            view.displayMode = .singlePage
            view.autoScales = true
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.title = "Accessibility Geometry QA"
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            view.go(to: page)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let elements = allElements(view)
            let lines = elements.filter { $0.accessibilityRole() == .staticText }
            check(!lines.isEmpty && elements.count < 200, "the reader exposes a bounded tree for visible pages")
            let target = lines.first { ($0.accessibilityValue() as? String)?.contains("entries") == true }
            check(target != nil, "the actual page text is discoverable through accessibility")
            if let target {
                let frame = target.accessibilityFrame()
                check(!frame.isEmpty && frame.height / view.scaleFactor < 20,
                      "the short text row has glyph-sized bounds rather than the 107-point matrix rectangle")
                let hit = view.accessibilityHitTest(CGPoint(x: frame.midX, y: frame.midY)) as? NSAccessibilityElement
                check(hit === target, "an accessibility screen-point hit resolves to the same precise text element")
                view.autoScales = false
                view.scaleFactor *= 1.15
                try? await Task.sleep(nanoseconds: 100_000_000)
                let zoomed = target.accessibilityFrame()
                check(abs(zoomed.height / frame.height - 1.15) < 0.03, "an existing accessibility element tracks zoom without stale coordinates")
            }
            let paragraph = elements.first { element in
                guard element.accessibilityRole() == .group else { return false }
                let text = (element.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityValue() as? String }.joined(separator: " ")
                return text.hasPrefix("Proof.") && text.contains("prove without")
            }
            check(paragraph != nil, "neighboring prose lines expose a whole-paragraph screenshot region")
            let nativeLink = elements.first { $0.accessibilityRole() == .link && $0.accessibilityLabel() == "QA page link" }
            check(nativeLink != nil && nativeLink!.accessibilityPerformPress(), "native PDF link actions remain accessible")
            try? await Task.sleep(nanoseconds: 100_000_000)
            check(view.currentPage === document.page(at: index + 1), "pressing the accessible document link performs native PDF navigation")
            if let target { check(target.accessibilityFrame().isEmpty, "an offscreen page's old accessibility element has no selectable screenshot region") }
            view.document = nil
            if let target { check(target.accessibilityFrame().isEmpty, "closing the document invalidates its old screenshot regions") }
            window.orderOut(nil)
            print(failures == 0 ? "All accessibility geometry checks passed" : "Accessibility geometry checks failed: \(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
@main struct AccessibilityGeometryQATests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let runner = AccessibilityGeometryQARunner()
        app.delegate = runner
        app.run()
    }
}
