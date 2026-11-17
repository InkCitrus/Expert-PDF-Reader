import AppKit
import PDFKit

@MainActor
final class SelectionGeometryQARunner: NSObject, NSApplicationDelegate {
    struct Case: Decodable {
        let name: String
        let page: Int
        let from: [Double]
        let to: [Double]
        let expected: String
        let maximumHighlightHeight: Double?
    }
    var window: NSWindow!
    var failures = 0
    func check(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL") \(message)")
        if !passed { failures += 1 }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let document = PDFDocument(url: URL(fileURLWithPath: env["SELECTION_QA_DOCUMENT"]!))!
            let cases = try! JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: env["SELECTION_QA_CASES_FILE"]!)))
            let view = ThemedPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 1000))
            view.document = document
            view.displayMode = .singlePage
            view.autoScales = true
            view.installOCRSelection()
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.title = "Selection Geometry QA"
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let board = NSPasteboard.general
            func snapshot() -> [NSPasteboardItem] {
                board.pasteboardItems?.map { item -> NSPasteboardItem in
                    let saved = NSPasteboardItem()
                    for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
                    return saved
                } ?? []
            }
            var previous = snapshot()
            var observedChange = board.changeCount
            var ownChange: Int?
            for item in cases {
                let page = document.page(at: item.page - 1)!
                view.clearSelection()
                view.go(to: page)
                try? await Task.sleep(nanoseconds: 100_000_000)
                let a = CGPoint(x: item.from[0], y: item.from[1]), b = CGPoint(x: item.to[0], y: item.to[1])
                let start = view.convert(view.convert(a, from: page), to: nil)
                let end = view.convert(view.convert(b, from: page), to: nil)
                let stamp = ProcessInfo.processInfo.systemUptime
                @MainActor func post(_ type: NSEvent.EventType, _ point: CGPoint, _ delta: Double) {
                    NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: stamp + delta,
                        windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
                }
                post(.leftMouseDown, start, 0)
                for step in 1...20 {
                    let t = CGFloat(step) / 20
                    let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.01) { post(.leftMouseDragged, point, Double(t) * 0.2) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { post(.leftMouseUp, end, 0.23) }
                try? await Task.sleep(nanoseconds: 450_000_000)
                let before = board.changeCount
                if before != observedChange { previous = snapshot() }
                view.copy(nil)
                if board.changeCount != before { ownChange = board.changeCount }
                observedChange = board.changeCount
                func compact(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                let actual = board.string(forType: .string) ?? ""
                check(board.changeCount != before && compact(actual) == compact(item.expected), "\(item.name): mouse gesture copies the independently supplied expected text")
                if compact(actual) != compact(item.expected) { print("ACTUAL \(String(reflecting: actual))") }
                if let maximum = item.maximumHighlightHeight, let original = page.selection(from: a, to: b),
                   let result = NativePDFSelection.corrected(original, in: document, from: page, at: a, to: page, at: b, force: true) {
                    check(!result.highlights.isEmpty && result.highlights.allSatisfy { $0.rect.height <= maximum },
                          "\(item.name): highlight stays inside the physical text row")
                }
                if let directory = env["CLIPBOARD_QA_EVIDENCE_DIR"],
                   let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(item.name + ".png"))
                }
            }
            if let ownChange, board.changeCount == ownChange { board.clearContents(); board.writeObjects(previous) }
            window.orderOut(nil)
            print(failures == 0 ? "All selection geometry UI checks passed" : "Selection geometry UI checks failed: \(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}

@main struct SelectionGeometryQATests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let runner = SelectionGeometryQARunner()
        app.delegate = runner
        app.run()
    }
}
