import AppKit
import PDFKit

@MainActor
final class ClipboardQARunner: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var failures: [String] = []

    func check(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL") \(message)")
        if !passed { failures.append(message) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let environment = ProcessInfo.processInfo.environment
            func point(_ key: String) -> CGPoint {
                let values = environment[key]!.split(separator: ",").map { Double($0)! }
                return CGPoint(x: values[0], y: values[1])
            }
            let document = PDFDocument(url: URL(fileURLWithPath: environment["SELECTION_QA_DOCUMENT"]!))!
            let source = document.page(at: Int(environment["SELECTION_QA_PAGE"]!)! - 1)!
            let page = source
            let from = point("SELECTION_QA_FROM"), to = point("SELECTION_QA_TO")
            let original = page.selection(from: from, to: to)!
            let reference = NativePDFSelection.corrected(original, in: document, from: page, at: from, to: page, at: to)
            check(reference != nil, "the supplied real-page gesture reproduces disordered native ranges")
            if let reference { print("REFERENCE \(reference.text.string)") }

            let view = ThemedPDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760))
            view.document = document
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.installOCRSelection()
            print("INFO visual selection required: \(PDFSelectionVisibility.requiresVisualSelection(on: page))")
            window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Clipboard QA"
            window.contentView = view
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            view.go(to: page)
            try? await Task.sleep(nanoseconds: 300_000_000)

            let board = NSPasteboard.general
            let previous = board.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            } ?? []
            var lastChange: Int?
            let start = view.convert(view.convert(from, from: page), to: nil)
            let end = view.convert(view.convert(to, from: page), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            @MainActor func post(_ type: NSEvent.EventType, _ point: CGPoint, _ delta: Double) {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: timestamp + delta, windowNumber: self.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
            }
            post(.leftMouseDown, start, 0)
            for index in 1...20 {
                let t = CGFloat(index) / 20
                let position = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.015) { post(.leftMouseDragged, position, Double(t) * 0.3) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { post(.leftMouseUp, end, 0.33) }
            try? await Task.sleep(nanoseconds: 900_000_000)
            let allowed = reference?.selection.bounds(for: page) ?? .zero
            let lines = view.currentSelection?.selectionsByLine() ?? []
            check(!lines.isEmpty && lines.allSatisfy { line in
                let bounds = line.bounds(for: page)
                return bounds.minY >= allowed.minY && bounds.maxY <= allowed.maxY
            }, "AppKit mouse dragging highlights only the requested physical row")
            let beforeTextCopy = board.changeCount
            view.copy(nil)
            if board.changeCount != beforeTextCopy { lastChange = board.changeCount }
            let copied = board.string(forType: .string)
            check(copied == reference?.text.string && board.data(forType: .rtf) != nil,
                  "the normal Copy action writes the corrected sentence in plain text and RTF")
            print("COPIED \(copied ?? "nil")")

            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: start, modifierFlags: [],
                timestamp: timestamp + 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = view.menu(for: event)!
            let viewActions: Set<Selector> = [#selector(PDFView.zoomIn(_:)), #selector(PDFView.zoomOut(_:)),
                                             #selector(PDFView.goToNextPage(_:)), #selector(PDFView.goToPreviousPage(_:))]
            check(!menu.items.contains { $0.action.map { viewActions.contains($0) } == true },
                  "the text context menu excludes independent PDFKit view controls")
            if let index = menu.items.firstIndex(where: { $0.action == NSSelectorFromString("copyPageAsImage:") }) {
                let before = board.changeCount
                menu.performActionForItem(at: index)
                for _ in 0..<100 {
                    if board.changeCount != before { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                let image = board.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
                let size = page.bounds(for: .cropBox).size
                let scale = min(3, 3200 / max(size.width, size.height))
                let imageCopied = board.changeCount != before && image?.pixelsWide == Int(ceil(size.width * scale))
                    && image?.pixelsHigh == Int(ceil(size.height * scale)) && board.data(forType: .tiff) != nil
                if imageCopied { lastChange = board.changeCount }
                check(imageCopied,
                      "the actual image-copy menu action writes a complete page as PNG and TIFF")
                if imageCopied, let directory = environment["CLIPBOARD_QA_EVIDENCE_DIR"], let data = board.data(forType: .png) {
                    try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("context-menu-page.png"))
                }
            } else { check(false, "the context menu provides Copy Current Page as Image") }
            window.orderOut(nil)
            print(failures.isEmpty ? "All clipboard UI checks passed" : "Clipboard UI checks failed")
            fflush(stdout)
            if let lastChange, board.changeCount == lastChange { board.clearContents(); board.writeObjects(previous) }
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}

@main
struct ClipboardQATests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let runner = ClipboardQARunner()
        app.delegate = runner
        app.run()
    }
}
