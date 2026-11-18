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
    func nativeTextFixture() -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        for (text, y): (String, CGFloat) in [("Above context.", 500), ("Selected middle row.", 482), ("Below context.", 464)] {
            (text as NSString).draw(at: CGPoint(x: 80, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 70),
                styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.center()
            let button = NSButton(title: "QA control", target: nil, action: nil)
            button.frame = CGRect(x: 30, y: 18, width: 100, height: 32)
            other.contentView?.addSubview(button)
            other.orderFront(nil)
            let buttonPoint = other.convertPoint(toScreen: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            let originalControlHit = other.accessibilityHitTest(buttonPoint) as AnyObject?
            other.orderOut(nil)

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
            let target = lines.first { ($0.accessibilityValue() as? String) == "entries, i.e.," }
            check(target != nil, "the actual page text is discoverable through accessibility")
            if let target {
                let frame = target.accessibilityFrame()
                let physical = view.convert(CGRect(x: 86, y: 654, width: 75, height: 15), from: page)
                let expected = self.window.convertToScreen(view.convert(physical, to: nil))
                check(frame.intersects(expected), "the text element's frame matches the actual row, not another line with an overlong label")
                check(!frame.isEmpty && frame.height / view.scaleFactor < 20,
                      "the short text row has glyph-sized bounds rather than the 107-point matrix rectangle")
                let hit = view.accessibilityHitTest(CGPoint(x: frame.midX, y: frame.midY)) as? NSAccessibilityElement
                check(hit === target, "an accessibility screen-point hit resolves to the same precise text element")
                let windowHit = self.window.accessibilityHitTest(CGPoint(x: frame.midX, y: frame.midY))
                let appHit = NSApp.accessibilityHitTest(CGPoint(x: frame.midX, y: frame.midY))
                check((windowHit as AnyObject?) === target, "a window-level hit reaches the same glyph-sized element")
                check((appHit as AnyObject?) === target, "an application-level hit reaches the same glyph-sized element")
                view.autoScales = false
                view.scaleFactor *= 1.15
                try? await Task.sleep(nanoseconds: 100_000_000)
                let zoomed = target.accessibilityFrame()
                check(abs(zoomed.height / frame.height - 1.15) < 0.03, "an existing accessibility element tracks zoom without stale coordinates")
            }
            let proofStart = lines.first { ($0.accessibilityValue() as? String)?.hasPrefix("Proof.") == true }
            let proofNext = lines.first { ($0.accessibilityValue() as? String)?.hasPrefix("prove without") == true }
            if let proofStart, let proofNext {
                let upper = proofStart.accessibilityFrame(), lower = proofNext.accessibilityFrame()
                check(!upper.isEmpty && !lower.isEmpty && !upper.intersects(lower),
                      "adjacent lines have disjoint screenshot frames")
            } else {
                check(false, "adjacent lines are exposed separately")
            }
            check(elements.filter { $0.accessibilityRole() == .group }.count == 1,
                  "the page exposes row candidates without a larger paragraph rectangle")
            let nativeLink = elements.first { $0.accessibilityRole() == .link && $0.accessibilityLabel() == "QA page link" }
            check(nativeLink != nil && nativeLink!.accessibilityPerformPress(), "native PDF link actions remain accessible")
            try? await Task.sleep(nanoseconds: 100_000_000)
            check(view.currentPage === document.page(at: index + 1), "pressing the accessible document link performs native PDF navigation")
            if let target { check(target.accessibilityFrame().isEmpty, "an offscreen page's old accessibility element has no selectable screenshot region") }
            view.document = nil
            if let target { check(target.accessibilityFrame().isEmpty, "closing the document invalidates its old screenshot regions") }

            let fixture = nativeTextFixture()
            view.document = fixture
            view.autoScales = true
            view.go(to: fixture.page(at: 0)!)
            try? await Task.sleep(nanoseconds: 100_000_000)
            let ordinaryPage = fixture.page(at: 0)!
            check(!NativePDFPageGeometry.geometry(for: ordinaryPage).needsDirectSelection,
                  "the input fixture exercises ordinary PDFKit tracking rather than the complex-text overlay")
            let middle = allElements(view).first { ($0.accessibilityValue() as? String) == "Selected middle row." }
            if let middle {
                let box = middle.accessibilityFrame()
                let hit = NSApp.accessibilityHitTest(CGPoint(x: box.midX, y: box.midY)) as? NSAccessibilityElement
                check(hit === middle && box.height / view.scaleFactor < 20,
                      "an ordinary page exposes only the pointed-at row through the application query")
            } else { check(false, "the ordinary fixture's middle row is exposed") }
            let location = view.convert(view.convert(CGPoint(x: 130, y: 489), from: ordinaryPage), to: view.superview)
            let nativeTarget = view.hitTest(location)
            check(nativeTarget != nil && nativeTarget !== view && nativeTarget!.isDescendant(of: view),
                  "ordinary pointer hit testing still reaches the native PDFKit view")
            other.orderFront(nil)
            check(originalControlHit != nil && (other.accessibilityHitTest(buttonPoint) as AnyObject?) === originalControlHit,
                  "non-reader windows retain their native accessibility hit testing")
            other.orderOut(nil)
            ordinaryPage.rotation = 90
            view.layoutDocumentView()
            try? await Task.sleep(nanoseconds: 100_000_000)
            let rotatedPoint = window.convertPoint(toScreen: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            check(!(NSApp.accessibilityHitTest(rotatedPoint) is PDFContentAccessibility.GeometryElement),
                  "rotated pages retain the native hit-testing path")
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
