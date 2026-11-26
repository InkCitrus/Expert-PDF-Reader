import AppKit
import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

@main
struct ReaderRegressionTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // This executable uses its own preferences domain, never the reader's application domain.
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() { print("PASS \(message)") }
            else { failures.append(message); print("FAIL \(message)") }
        }
        func freshStore() -> AppStore {
            defaults.removePersistentDomain(forName: domain)
            return AppStore()
        }
        func fixture(_ name: String, mixedNumbers: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(name).appendingPathExtension("pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = CGContext(url as CFURL, mediaBox: &box, nil)!
            for index in 0..<(mixedNumbers ? 25 : 4) {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
                ("A complete paragraph for regression testing, page \(index + 1)." as NSString)
                    .draw(at: CGPoint(x: 50, y: 500), withAttributes: attributes)
                let footer: String
                if mixedNumbers {
                    footer = index == 0 || index == 24 ? "" : (index < 5 ? ["i", "ii", "iii", "iv"][index - 1] : "\(index - 4)")
                } else { footer = "\(index + 1)" }
                (footer as NSString).draw(at: CGPoint(x: 295, y: 25), withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
            return url
        }

        let alpha = try fixture("Alpha"), beta = try fixture("Beta"), gamma = try fixture("Gamma")
        do {
            // A tall delimiter alongside ordinary text reproduces oversized PDFKit line metrics.
            let url = root.appendingPathComponent("MixedFontMetrics.pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = CGContext(url as CFURL, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("A short row, with punctuation." as NSString).draw(at: CGPoint(x: 50, y: 650),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            ("|" as NSString).draw(at: CGPoint(x: 350, y: 620), withAttributes: [.font: NSFont.systemFont(ofSize: 100)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(url: url)!, page = document.page(at: 0)!
            let a = CGPoint(x: 48, y: 655), b = CGPoint(x: 240, y: 655)
            let original = page.selection(from: a, to: b)!
            let result = NativePDFSelection.corrected(original, in: document, from: page, at: a, to: page, at: b, force: true)
            check(result?.text.string.trimmingCharacters(in: .whitespacesAndNewlines) == "A short row, with punctuation.",
                  "glyph-based selection preserves native punctuation beside tall equation delimiters")
            check(result?.highlights.isEmpty == false && result!.highlights.allSatisfy { $0.rect.height < 20 },
                  "mixed font metrics cannot inflate a short row's highlight into a neighboring equation")
            let reverse = NativePDFSelection.corrected(original, in: document, from: page, at: b, to: page, at: a, force: true)
            check(reverse?.text.string == result?.text.string,
                  "reversing a physical drag preserves the same ranges and punctuation")
        }
        do {
            let document = PDFDocument(url: alpha)!, page = document.page(at: 0)!
            let start = CGPoint(x: 50, y: 505), end = CGPoint(x: 500, y: 505)
            let normal = page.selection(from: start, to: end)!
            check(NativePDFSelection.corrected(normal, in: document, from: page, at: start, to: page, at: end) == nil,
                  "normal native text selection is left unchanged")
            let contaminated = normal.copy() as! PDFSelection
            contaminated.add(page.selection(for: CGRect(x: 285, y: 20, width: 40, height: 25))!)
            let corrected = NativePDFSelection.corrected(contaminated, in: document, from: page, at: start, to: page, at: end)
            if corrected?.text.string != normal.string?.trimmingCharacters(in: .newlines) {
                print("INFO corrected row expected=\(String(reflecting: normal.string)), actual=\(String(reflecting: corrected?.text.string)), ranges=\(corrected?.selection.selectionsByLine().map { $0.bounds(for: page) } ?? [])")
            }
            check(corrected?.text.string == normal.string?.trimmingCharacters(in: .newlines)
                  && corrected!.selection.selectionsByLine().allSatisfy { $0.bounds(for: page).minY > 450 },
                  "physical row correction excludes unrelated text even when the PDF ranges include it")
            let reverse = NativePDFSelection.corrected(contaminated, in: document, from: page, at: end, to: page, at: start)
            check(reverse?.text.string == corrected?.text.string,
                  "reverse dragging selects the same physical row in reading order")
        }
        do {
            // An outlined box in a transformed coordinate system with ordinary labels and no colored fill.
            let data = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(media)
            context.saveGState()
            context.translateBy(x: 82, y: 310)
            context.scaleBy(x: 1.5, y: 1.5)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(2)
            context.stroke(CGRect(x: 0, y: 0, width: 240, height: 90))
            context.restoreGState()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
            ("Outside context." as NSString).draw(at: CGPoint(x: 104, y: 475), withAttributes: text)
            ("Work shown here." as NSString).draw(at: CGPoint(x: 104, y: 412), withAttributes: text)
            ("A = B + C" as NSString).draw(at: CGPoint(x: 200, y: 350), withAttributes: text)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(data: data as Data)!
            let page = document.page(at: 0)!
            let regions = PDFFramedRegions.bounds(on: page, geometry: NativePDFPageGeometry.geometry(for: page))
            check(regions.count == 1 && regions.first.map {
                abs($0.minX - 80.5) < 1 && abs($0.minY - 308.5) < 1 &&
                abs($0.maxX - 443.5) < 1 && abs($0.maxY - 446.5) < 1
            } == true, "a stroked frame crops to its drawn extent after applying the PDF transform")
        }
        do {
            // Paired vertical sidebars enclosing solution rows form a single panel region.
            let data = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(media)
            context.setStrokeColor(red: 0, green: 0, blue: 0.6, alpha: 1)
            context.setLineWidth(2.8)
            context.move(to: CGPoint(x: 72, y: 180)); context.addLine(to: CGPoint(x: 72, y: 380)); context.strokePath()
            context.move(to: CGPoint(x: 540, y: 180)); context.addLine(to: CGPoint(x: 540, y: 380)); context.strokePath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
            ("Outside header line." as NSString).draw(at: CGPoint(x: 85, y: 420), withAttributes: attrs)
            ("Solution: First solution step." as NSString).draw(at: CGPoint(x: 90, y: 350), withAttributes: attrs)
            ("Second solution step." as NSString).draw(at: CGPoint(x: 90, y: 325), withAttributes: attrs)
            ("Final answer." as NSString).draw(at: CGPoint(x: 90, y: 300), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(data: data as Data)!
            let page = document.page(at: 0)!
            let regions = PDFFramedRegions.regions(on: page, geometry: NativePDFPageGeometry.geometry(for: page))
            check(regions.count == 1 && regions[0].kind == .panel
                  && abs(regions[0].bounds.minX - 70.6) < 1 && abs(regions[0].bounds.maxX - 541.4) < 1
                  && abs(regions[0].bounds.minY - 178.6) < 2 && abs(regions[0].bounds.maxY - 381.4) < 2,
                  "paired vertical sidebars enclose solution content as one framed panel")
        }
        do {
            // Outer framed box containing a vector diagram with short labels and a ruled 2x2 table.
            let data = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(media)
            context.setStrokeColor(gray: 0.2, alpha: 1)
            context.setLineWidth(1.5)
            context.stroke(CGRect(x: 70, y: 300, width: 470, height: 340))
            // Blue diagram block with feed arrow + diagonal arrowheads
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(0.6)
            context.addRect(CGRect(x: 280, y: 500, width: 32, height: 60))
            context.drawPath(using: .fillStroke)
            context.move(to: CGPoint(x: 245, y: 530)); context.addLine(to: CGPoint(x: 279, y: 530)); context.strokePath()
            context.move(to: CGPoint(x: 275, y: 533)); context.addLine(to: CGPoint(x: 279, y: 530)); context.addLine(to: CGPoint(x: 275, y: 527)); context.strokePath()
            context.move(to: CGPoint(x: 312, y: 530)); context.addLine(to: CGPoint(x: 346, y: 530)); context.strokePath()
            context.move(to: CGPoint(x: 342, y: 533)); context.addLine(to: CGPoint(x: 346, y: 530)); context.addLine(to: CGPoint(x: 342, y: 527)); context.strokePath()
            // Ruled 2x2 table
            for y in [340.0, 360.0, 380.0] {
                context.move(to: CGPoint(x: 220, y: y)); context.addLine(to: CGPoint(x: 380, y: y)); context.strokePath()
            }
            for x in [220.0, 300.0, 380.0] {
                context.move(to: CGPoint(x: x, y: 340)); context.addLine(to: CGPoint(x: x, y: 380)); context.strokePath()
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
            ("Exercise Heading inside outer box." as NSString).draw(at: CGPoint(x: 85, y: 605), withAttributes: attrs)
            ("feed" as NSString).draw(at: CGPoint(x: 215, y: 525), withAttributes: attrs)
            ("out" as NSString).draw(at: CGPoint(x: 350, y: 525), withAttributes: attrs)
            ("Col A" as NSString).draw(at: CGPoint(x: 235, y: 365), withAttributes: attrs)
            ("Col B" as NSString).draw(at: CGPoint(x: 315, y: 365), withAttributes: attrs)
            ("12" as NSString).draw(at: CGPoint(x: 245, y: 345), withAttributes: attrs)
            ("34" as NSString).draw(at: CGPoint(x: 325, y: 345), withAttributes: attrs)
            ("Concluding sentence inside outer box." as NSString).draw(at: CGPoint(x: 85, y: 312), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(data: data as Data)!
            let page = document.page(at: 0)!
            let regions = PDFFramedRegions.regions(on: page, geometry: NativePDFPageGeometry.geometry(for: page))
            let figure = regions.first(where: { $0.kind == .figure })
            let table = regions.first(where: { $0.kind == .table })
            let panel = regions.first(where: { $0.kind == .panel })
            check(panel != nil && figure != nil && table != nil,
                  "nested figure and ruled table remain distinct inside an enclosing framed panel")
            if let figure {
                check(figure.bounds.minX <= 220 && figure.bounds.maxX >= 360,
                      "vector figure region absorbs short adjacent diagram labels")
            }
        }
        do {
            // An open L-shaped orthogonal border around prose lines must not become a figure or panel.
            let data = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(media)
            context.setStrokeColor(gray: 0.2, alpha: 1)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 150, y: 500))
            context.addLine(to: CGPoint(x: 540, y: 500))
            context.addLine(to: CGPoint(x: 540, y: 420))
            context.strokePath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
            ("First prose sentence spanning across the page width cleanly." as NSString).draw(at: CGPoint(x: 80, y: 480), withAttributes: attrs)
            ("Second prose sentence spanning across the page width cleanly." as NSString).draw(at: CGPoint(x: 80, y: 460), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(data: data as Data)!
            let page = document.page(at: 0)!
            let regions = PDFFramedRegions.regions(on: page, geometry: NativePDFPageGeometry.geometry(for: page))
            check(regions.isEmpty, "open L-shaped rule borders do not produce false figure or table regions")
        }
        do {
            // Combining negation slash stays attached and tall isolated math delimiters stay out of body rows.
            let data = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(media)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("If det(A) =\u{0338} 0 then solve." as NSString).draw(
                at: CGPoint(x: 90, y: 500),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            ("(" as NSString).draw(
                at: CGPoint(x: 320, y: 488),
                withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(data: data as Data)!
            let page = document.page(at: 0)!
            let geometry = NativePDFPageGeometry.geometry(for: page)
            check(!geometry.excludedIndices.isEmpty && geometry.needsDirectSelection,
                  "tall isolated math delimiters are excluded from body rows and trigger direct selection")
            check(geometry.rows.contains { geometry.text(for: $0, on: page).contains("=\u{0338}") || geometry.text(for: $0, on: page).contains("\u{0338}=") || geometry.text(for: $0, on: page).contains("≠") },
                  "combining negation slash is preserved in row text")
        }
        do {
            @MainActor func buildAccessibilityRoot(for data: Data) -> (window: NSWindow, root: PDFContentAccessibility.GeometryElement?) {
                let document = PDFDocument(data: data)!
                let view = ThemedPDFView(frame: CGRect(x: 0, y: 0, width: 620, height: 820))
                view.document = document
                view.displayMode = .singlePage
                view.autoScales = true
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderBack(nil)
                view.go(to: document.page(at: 0)!)
                view.layoutDocumentView()
                let root = view.accessibilityChildren()?.first(where: { $0 is PDFContentAccessibility.GeometryElement })
                    as? PDFContentAccessibility.GeometryElement
                return (window, root)
            }
            @MainActor func makePDF(draw: (CGContext) -> Void) -> Data {
                let data = NSMutableData()
                var media = CGRect(x: 0, y: 0, width: 612, height: 792)
                let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media, nil)!
                context.beginPDFPage(nil)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(media)
                draw(context)
                context.endPDFPage()
                context.closePDF()
                return data as Data
            }

            // 1. First-line indented 1.5x-spaced paragraphs with a short descenderless ending ("one.")
            let indentPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
                ("First indented opening line across the width." as NSString).draw(at: CGPoint(x: 92, y: 650), withAttributes: attrs)
                ("Continuation line back at the left margin." as NSString).draw(at: CGPoint(x: 72, y: 630), withAttributes: attrs)
                ("one." as NSString).draw(at: CGPoint(x: 72, y: 610), withAttributes: attrs)
                ("Second indented paragraph directly below." as NSString).draw(at: CGPoint(x: 92, y: 590), withAttributes: attrs)
                ("Second paragraph continuation at margin." as NSString).draw(at: CGPoint(x: 72, y: 570), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            let (win1, root1) = buildAccessibilityRoot(for: indentPDF)
            defer { win1.orderOut(nil) }
            let groups1 = root1?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            check(groups1.count == 2 && groups1[0].allChildren.count == 3 && groups1[1].allChildren.count == 2,
                  "first-line indented 1.5x-spaced paragraphs with a short ending group into distinct paragraph blocks")

            // 2. Two-column staggered layout stays grouped independently per column
            let twoColPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
                ("Left column line one." as NSString).draw(at: CGPoint(x: 50, y: 600), withAttributes: attrs)
                ("Right column line one." as NSString).draw(at: CGPoint(x: 330, y: 591), withAttributes: attrs)
                ("Left column line two." as NSString).draw(at: CGPoint(x: 50, y: 582), withAttributes: attrs)
                ("Right column line two." as NSString).draw(at: CGPoint(x: 330, y: 573), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            let (win2, root2) = buildAccessibilityRoot(for: twoColPDF)
            defer { win2.orderOut(nil) }
            let groups2 = root2?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            check(groups2.count == 2 && groups2.allSatisfy { $0.allChildren.count == 2 },
                  "two-column staggered baselines partition into two separate column paragraphs")

            // 3. Paragraphs inside a framed panel and direct GeometryElement.accessibilityHitTest
            let framedParaPDF = makePDF { ctx in
                ctx.setStrokeColor(gray: 0.2, alpha: 1)
                ctx.setLineWidth(1.5)
                ctx.stroke(CGRect(x: 70, y: 400, width: 470, height: 210))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
                ("Panel Title" as NSString).draw(at: CGPoint(x: 85, y: 585), withAttributes: attrs)
                ("First body line inside framed panel." as NSString).draw(at: CGPoint(x: 85, y: 550), withAttributes: attrs)
                ("Second body line inside framed panel." as NSString).draw(at: CGPoint(x: 85, y: 534), withAttributes: attrs)
                ("Third body line inside framed panel." as NSString).draw(at: CGPoint(x: 85, y: 518), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            let (win3, root3) = buildAccessibilityRoot(for: framedParaPDF)
            defer { win3.orderOut(nil) }
            let panel3 = root3?.allChildren.first { $0.accessibilityRole() == .group }
            let innerPara = panel3?.allChildren.first { $0.accessibilityRole() == .group && $0.allChildren.count == 3 }
            check(panel3 != nil && panel3?.allChildren.count == 2 && innerPara != nil,
                  "framed panel preserves separate heading while grouping body lines into a child paragraph")
            if let root3, let innerPara, let l1 = innerPara.allChildren.first, let l2 = innerPara.allChildren.dropFirst().first {
                let f1 = l1.accessibilityFrame(), f2 = l2.accessibilityFrame()
                let gapPoint = CGPoint(x: f1.midX, y: (f1.minY + f2.maxY) / 2)
                check((root3.accessibilityHitTest(gapPoint) as AnyObject?) === innerPara,
                      "direct accessibilityHitTest in a panel paragraph gap hits the inner paragraph rather than the panel or page")
            } else {
                check(false, "direct accessibilityHitTest in a panel paragraph gap hits the inner paragraph rather than the panel or page")
            }

            // 4. Multi-step matrix derivation preserves delimiter bounds, protruding operators, and annotations
            let matrixPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
                let delimAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
                ("We apply row operations to obtain:" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: attrs)
                ("(" as NSString).draw(at: CGPoint(x: 135, y: 612), withAttributes: delimAttrs)
                ("1 2" as NSString).draw(at: CGPoint(x: 155, y: 644), withAttributes: attrs)
                ("3 4" as NSString).draw(at: CGPoint(x: 155, y: 629), withAttributes: attrs)
                ("5 6" as NSString).draw(at: CGPoint(x: 155, y: 614), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 185, y: 612), withAttributes: delimAttrs)
                ("~" as NSString).draw(at: CGPoint(x: 205, y: 629), withAttributes: attrs)
                ("(" as NSString).draw(at: CGPoint(x: 222, y: 612), withAttributes: delimAttrs)
                ("1 2" as NSString).draw(at: CGPoint(x: 242, y: 644), withAttributes: attrs)
                ("0 7" as NSString).draw(at: CGPoint(x: 242, y: 629), withAttributes: attrs)
                ("0 8" as NSString).draw(at: CGPoint(x: 242, y: 614), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 272, y: 612), withAttributes: delimAttrs)
                ("R2 = row2" as NSString).draw(at: CGPoint(x: 345, y: 629), withAttributes: attrs)
                ("R3 = row3" as NSString).draw(at: CGPoint(x: 345, y: 614), withAttributes: attrs)

                ("~" as NSString).draw(at: CGPoint(x: 205, y: 579), withAttributes: attrs)
                ("(" as NSString).draw(at: CGPoint(x: 222, y: 562), withAttributes: delimAttrs)
                ("1 2" as NSString).draw(at: CGPoint(x: 242, y: 594), withAttributes: attrs)
                ("0 7" as NSString).draw(at: CGPoint(x: 242, y: 579), withAttributes: attrs)
                ("0 1" as NSString).draw(at: CGPoint(x: 242, y: 564), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 272, y: 562), withAttributes: delimAttrs)
                ("R3 = diff" as NSString).draw(at: CGPoint(x: 345, y: 564), withAttributes: attrs)
                ("Translating back yields the solution." as NSString).draw(at: CGPoint(x: 72, y: 515), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            let (win4, root4) = buildAccessibilityRoot(for: matrixPDF)
            defer { win4.orderOut(nil) }
            let derivation = root4?.allChildren.first {
                $0.accessibilityRole() == .group && $0.allChildren.count == 2
            }
            let step1 = derivation?.allChildren.first
            let step2 = derivation?.allChildren.dropFirst().first
            let step2Matrix = step2?.allChildren.first { $0.accessibilityRole() == .group }
            let step1Text = step1?.accessibilityValue() as? String ?? ""
            let step2Text = step2?.accessibilityValue() as? String ?? ""
            let step2MatrixRect = step2Matrix?.pageRect ?? .zero
            let enclosesFullMatrixDelimiters = step2MatrixRect.minX <= 228 && step2MatrixRect.maxX >= 278
                && step2MatrixRect.minY <= 566 && step2MatrixRect.maxY >= 604
            check(derivation != nil
                  && step1Text.contains("R2 = row2") && step1Text.contains("R3 = row3")
                  && step2Text.contains("R3 = diff") && step2Text.contains("0 1") && step2Text.contains("1 2")
                  && (step2Matrix?.allChildren.count == 3)
                  && enclosesFullMatrixDelimiters,
                  "multi-step matrix derivation binds delimiters, protruding operators, and right annotations into complete nested groups")
            if let root4, let step1, let step2, let step2Matrix {
                let dFrame = step2Matrix.accessibilityFrame()
                let delimPoint = CGPoint(x: dFrame.minX + 2, y: dFrame.midY)
                let interStepPoint = CGPoint(x: step2.accessibilityFrame().midX,
                                             y: (step1.accessibilityFrame().minY + step2.accessibilityFrame().maxY) / 2)
                check((root4.accessibilityHitTest(delimPoint) as AnyObject?) === step2Matrix
                      && (root4.accessibilityHitTest(interStepPoint) as AnyObject?) === derivation,
                      "accessibilityHitTest hits matrix group on its delimiter and derivation group between steps")
            } else {
                check(false, "accessibilityHitTest hits matrix group on its delimiter and derivation group between steps")
            }

            // 5. Matrix in column 1 does not absorb column 2 prose across a vertical column gutter
            let colMatrixPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
                let delimAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]
                ("(" as NSString).draw(at: CGPoint(x: 90, y: 558), withAttributes: delimAttrs)
                ("1 0" as NSString).draw(at: CGPoint(x: 108, y: 582), withAttributes: attrs)
                ("0 1" as NSString).draw(at: CGPoint(x: 108, y: 564), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 135, y: 558), withAttributes: delimAttrs)

                ("Right column opening line." as NSString).draw(at: CGPoint(x: 320, y: 616), withAttributes: attrs)
                ("Right column beside matrix one." as NSString).draw(at: CGPoint(x: 320, y: 598), withAttributes: attrs)
                ("Right column beside matrix two." as NSString).draw(at: CGPoint(x: 320, y: 580), withAttributes: attrs)
                ("Right column closing line." as NSString).draw(at: CGPoint(x: 320, y: 562), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            let (win5, root5) = buildAccessibilityRoot(for: colMatrixPDF)
            defer { win5.orderOut(nil) }
            let colGroups = root5?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            let rightCol = colGroups.first { ($0.accessibilityValue() as? String)?.contains("Right column") == true }
            let leftMatrix = colGroups.first { ($0.accessibilityValue() as? String)?.contains("1 0") == true }
            check(colGroups.count == 2 && rightCol?.allChildren.count == 4 && leftMatrix?.allChildren.count == 2
                  && !((leftMatrix?.pageRect ?? .zero).intersects(rightCol?.pageRect ?? .zero)),
                  "two-column matrix does not absorb adjacent column prose")

            // 6. Numbered list with inline tall delimited expression stays grouped while display heading stays separate
            let inlineMathListPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let bodyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
                let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black]
                let inlineDelimAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black]

                ("Section 4.2 Augmented Matrix Procedure" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: headAttrs)
                ("We summarize the solving procedure with standard inline notation across the page width." as NSString).draw(at: CGPoint(x: 72, y: 672), withAttributes: bodyAttrs)
                ("Each elementary step preserves solutions while reducing the coefficient block to triangular form." as NSString).draw(at: CGPoint(x: 72, y: 656), withAttributes: bodyAttrs)

                ("1. Formulate the coefficient matrices A, x, and b from the system." as NSString).draw(at: CGPoint(x: 86, y: 620), withAttributes: bodyAttrs)
                ("2. Create the augmented matrix" as NSString).draw(at: CGPoint(x: 86, y: 600), withAttributes: bodyAttrs)
                ("(" as NSString).draw(at: CGPoint(x: 262, y: 597), withAttributes: inlineDelimAttrs)
                ("A  b" as NSString).draw(at: CGPoint(x: 270, y: 600), withAttributes: bodyAttrs)
                (")" as NSString).draw(at: CGPoint(x: 296, y: 597), withAttributes: inlineDelimAttrs)
                ("3. Apply elementary row operations to obtain upper-triangular form." as NSString).draw(at: CGPoint(x: 86, y: 580), withAttributes: bodyAttrs)
                ("4. Use back-substitution to solve cleanly for the remaining variables." as NSString).draw(at: CGPoint(x: 86, y: 562), withAttributes: bodyAttrs)
                NSGraphicsContext.restoreGraphicsState()

                ctx.setStrokeColor(gray: 0, alpha: 1)
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: 282, y: 596))
                ctx.addLine(to: CGPoint(x: 282, y: 614))
                ctx.strokePath()
            }
            let (win6, root6) = buildAccessibilityRoot(for: inlineMathListPDF)
            defer { win6.orderOut(nil) }
            let groups6 = root6?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            let bodyPara6 = groups6.first { ($0.accessibilityValue() as? String)?.contains("summarize") == true }
            let listGroup6 = groups6.first { ($0.accessibilityValue() as? String)?.contains("augmented matrix") == true }
            let headingMerged6 = groups6.contains { ($0.accessibilityValue() as? String)?.contains("Section 4.2") == true }
            check(!headingMerged6
                  && bodyPara6?.allChildren.count == 2
                  && listGroup6?.allChildren.count == 4,
                  "display heading stays separate while numbered list with taller inline delimited math stays grouped")

            // 7. Adjacent matrices with operators split free text cleanly and never merge across fractions
            let multiMatrixRowPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
                let delimAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
                ("Compare the adjacent matrices and the scaled matrix product displayed across each row:" as NSString).draw(
                    at: CGPoint(x: 72, y: 700), withAttributes: attrs)

                ("A =" as NSString).draw(at: CGPoint(x: 110, y: 634), withAttributes: attrs)
                ("(" as NSString).draw(at: CGPoint(x: 145, y: 611), withAttributes: delimAttrs)
                ("1 2" as NSString).draw(at: CGPoint(x: 162, y: 643), withAttributes: attrs)
                ("3 4" as NSString).draw(at: CGPoint(x: 162, y: 623), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 190, y: 611), withAttributes: delimAttrs)
                ("B =" as NSString).draw(at: CGPoint(x: 265, y: 634), withAttributes: attrs)
                ("(" as NSString).draw(at: CGPoint(x: 300, y: 611), withAttributes: delimAttrs)
                ("5 6" as NSString).draw(at: CGPoint(x: 317, y: 643), withAttributes: attrs)
                ("7 8" as NSString).draw(at: CGPoint(x: 317, y: 623), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 345, y: 611), withAttributes: delimAttrs)

                ("(" as NSString).draw(at: CGPoint(x: 145, y: 521), withAttributes: delimAttrs)
                ("1 0" as NSString).draw(at: CGPoint(x: 162, y: 553), withAttributes: attrs)
                ("0 1" as NSString).draw(at: CGPoint(x: 162, y: 533), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 190, y: 521), withAttributes: delimAttrs)
                ("1" as NSString).draw(at: CGPoint(x: 218, y: 552), withAttributes: attrs)
                ("2" as NSString).draw(at: CGPoint(x: 218, y: 531), withAttributes: attrs)
                ("(" as NSString).draw(at: CGPoint(x: 250, y: 521), withAttributes: delimAttrs)
                ("9 1" as NSString).draw(at: CGPoint(x: 267, y: 553), withAttributes: attrs)
                ("2 3" as NSString).draw(at: CGPoint(x: 267, y: 533), withAttributes: attrs)
                (")" as NSString).draw(at: CGPoint(x: 295, y: 521), withAttributes: delimAttrs)
                NSGraphicsContext.restoreGraphicsState()

                ctx.setStrokeColor(gray: 0, alpha: 1)
                ctx.setLineWidth(0.9)
                ctx.move(to: CGPoint(x: 212, y: 545))
                ctx.addLine(to: CGPoint(x: 232, y: 545))
                ctx.strokePath()
            }
            let (win7, root7) = buildAccessibilityRoot(for: multiMatrixRowPDF)
            defer { win7.orderOut(nil) }
            let rowA = root7?.allChildren.first {
                $0.accessibilityRole() == .group && (($0.accessibilityValue() as? String)?.contains("A =") == true)
            }
            let aLabel = rowA?.allChildren.first { $0.accessibilityRole() == .staticText && (($0.accessibilityValue() as? String)?.contains("A") == true) }
            let bLabel = rowA?.allChildren.first { $0.accessibilityRole() == .staticText && (($0.accessibilityValue() as? String)?.contains("B") == true) }
            let rowAMatrices = rowA?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            let noOperatorSpansMatrix1 = (aLabel != nil && bLabel != nil && rowAMatrices.count == 2)
                && !aLabel!.pageRect.intersects(rowAMatrices[0].pageRect)
                && !bLabel!.pageRect.intersects(rowAMatrices[0].pageRect)
                && !bLabel!.pageRect.intersects(rowAMatrices[1].pageRect)
            let rowB = root7?.allChildren.first {
                $0.accessibilityRole() == .group && (($0.accessibilityValue() as? String)?.contains("9 1") == true)
            }
            let rowBMatrices = rowB?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            let fracMatricesDisjoint = rowBMatrices.count == 2 && !rowBMatrices[0].pageRect.intersects(rowBMatrices[1].pageRect)
            check(noOperatorSpansMatrix1 && fracMatricesDisjoint,
                  "operator labels split around matrices and vertical fractions do not bridge separate matrices")

            // 8. Short indented continuation and centered equation sharing right edge do not merge via indent/flush-right rules
            let alignmentGuardPDF = makePDF { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
                ("This reference prose line spans all the way across the normal column right edge." as NSString).draw(
                    at: CGPoint(x: 72, y: 710), withAttributes: attrs)
                ("Another reference prose line establishing the normal right margin of this column." as NSString).draw(
                    at: CGPoint(x: 72, y: 694), withAttributes: attrs)

                ("Indented item continuation line that stops well short." as NSString).draw(
                    at: CGPoint(x: 105, y: 644), withAttributes: attrs)
                ("2. Wider next item starting back left and extending further right than above." as NSString).draw(
                    at: CGPoint(x: 86, y: 626), withAttributes: attrs)

                ("d = (1, m)" as NSString).draw(at: CGPoint(x: 270, y: 564), withAttributes: attrs)
                ("is parallel to the line (can you see why?)." as NSString).draw(at: CGPoint(x: 86, y: 546), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            let (win8, root8) = buildAccessibilityRoot(for: alignmentGuardPDF)
            defer { win8.orderOut(nil) }
            let groups8 = root8?.allChildren.filter { $0.accessibilityRole() == .group } ?? []
            let falseIndentMerge = groups8.contains { ($0.accessibilityValue() as? String)?.contains("2. Wider") == true }
            let falseFlushRightMerge = groups8.contains { ($0.accessibilityValue() as? String)?.contains("d = (1, m)") == true }
            check(!falseIndentMerge && !falseFlushRightMerge,
                  "narrow indented or centered lines do not falsely merge into wider left-margin prose lines")
        }
        do {
            // Two columns: a high left line and a low right line. A drag whose higher point sits in the
            // right column and lower point in the left column resolves the "first" line below the "last"
            // line, which used to invert verticalRange's closed range and trap.
            let url = root.appendingPathComponent("TwoColumns").appendingPathExtension("pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = CGContext(url as CFURL, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
            ("High left column line." as NSString).draw(at: CGPoint(x: 50, y: 500), withAttributes: attributes)
            ("Low right column line." as NSString).draw(at: CGPoint(x: 400, y: 100), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            let document = PDFDocument(url: url)!, page = document.page(at: 0)!
            let original = page.selection(for: CGRect(x: 0, y: 0, width: 600, height: 800))!
            let result = NativePDFSelection.corrected(original, in: document, from: page,
                                                      at: CGPoint(x: 500, y: 300), to: page, at: CGPoint(x: 50, y: 250))
            check(result == nil || result?.text.string.isEmpty == false,
                  "inverted first/last line bounds normalize instead of trapping")
        }
        do {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let evidence = ProcessInfo.processInfo.environment["COPY_PAGE_QA_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
            if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
            func saveImage(_ name: String) throws {
                if let evidence, let data = board.data(forType: .png) {
                    try data.write(to: evidence.appendingPathComponent(name).appendingPathExtension("png"))
                }
            }
            func hasInk(_ image: NSBitmapImageRep?) -> Bool {
                guard let image else { return false }
                for y in stride(from: 0, to: image.pixelsHigh, by: 8) {
                    for x in stride(from: 0, to: image.pixelsWide, by: 8) {
                        if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                           color.redComponent < 0.5 && color.greenComponent < 0.5 && color.blueComponent < 0.5 { return true }
                    }
                }
                return false
            }
            let document = PDFDocument(url: alpha)!
            let page = document.page(at: 0)!
            board.setString("Previous clipboard", forType: .string)
            let copied = try await PageImageClipboard.copy(page, to: board)
            let png = board.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
            let tiff = board.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0) }
            check(copied && png?.pixelsWide == 1800 && png?.pixelsHigh == 2400
                  && tiff?.pixelsWide == 1800 && tiff?.pixelsHigh == 2400
                  && board.string(forType: .string) == nil,
                  "page-image copy writes a complete 216-dpi page as PNG and TIFF, replacing stale text")
            check(hasInk(png), "page-image copy renders the actual document content")
            try saveImage("page")
            let paper = png?.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB)
            check(paper != nil && paper!.redComponent > 0.98 && paper!.alphaComponent > 0.98,
                  "copied page images use opaque original white paper")
            page.rotation = 90
            try await PageImageClipboard.copy(page, to: board)
            let rotated = board.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
            check(rotated?.pixelsWide == 2400 && rotated?.pixelsHigh == 1800,
                  "page-image copy respects page rotation without changing the source page")
            check(hasInk(rotated), "rotated page images retain the document content")
            try saveImage("rotated-page")
            check(page.rotation == 90 && page.bounds(for: .cropBox).size == CGSize(width: 600, height: 800),
                  "export leaves source rotation and crop bounds intact")
            page.rotation = 0
            page.setBounds(CGRect(x: 40, y: 300, width: 520, height: 300), for: .cropBox)
            try await PageImageClipboard.copy(page, to: board)
            let crop = board.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
            check(crop?.pixelsWide == 1560 && crop?.pixelsHigh == 900,
                  "copied images respect the page crop rather than the window viewport")
            check(hasInk(crop), "a nonzero crop origin is translated correctly into the copied image")
            try saveImage("cropped-page")

            let pending = Task { try await PageImageClipboard.copy(page, to: board) }
            // Let the copy snapshot its page and clipboard version before changing the clipboard.
            await Task.yield()
            board.clearContents()
            board.setString("Newer copy", forType: .string)
            let didReplace = try await pending.value
            check(!didReplace && board.string(forType: .string) == "Newer copy",
                  "an asynchronous page render does not replace a newer clipboard operation")
            let store = freshStore()
            let tab = store.openDocument(at: alpha, interactive: false)!
            tab.currentPageIndex = 2
            tab.splitMode = .vertical
            tab.setSecondaryDocument(url: beta)
            tab.secondaryPageIndex = 1
            tab.activatePane(isSecondary: true)
            check(tab.currentPageForCopying === tab.secondaryPDFDocument?.page(at: 1),
                  "copy-current-page targets the active comparison document and page")
            tab.activatePane(isSecondary: false)
            check(tab.currentPageForCopying === tab.pdfDocument.page(at: 2),
                  "copy-current-page returns to the primary document when that pane becomes active")
            check(!PageImageClipboard.canCopy(nil), "copy-current-page is unavailable without a document page")
            if let evidence {
                let guides = evidence.appendingPathComponent("guides")
                try FileManager.default.createDirectory(at: guides, withIntermediateDirectories: true)
                for language in AppLanguage.allCases where language != .system {
                    SamplePDFGenerator.generateSamplePDF(at: guides.appendingPathComponent(language.rawValue).appendingPathExtension("pdf"),
                                                        guide: SamplePDFGenerator.guideContent(for: language))
                }
            }
        }
        do {
            let store = freshStore()
            let a = store.openDocument(at: alpha, interactive: false)!
            let b = store.openDocument(at: beta, interactive: false)!
            let c = store.openDocument(at: gamma, interactive: false)!
            let session = store.primarySession
            let unnamed = store.createTabGroup(name: "  \n", containing: a.id)!
            check(session.tabGroups.first?.name == "" && session.tabGroups.first?.tabIDs == [a.id],
                  "blank group names create a color-only group with its document intact")
            check(session.tabGroupMenuTitle(session.tabGroups[0]) == "“\(a.title)”",
                  "unnamed single-tab group menu title shows its quoted tab name")
            check(session.destinationTabGroups(for: a.id).isEmpty,
                  "Add to Group excludes the tab's current group when no other group exists")
            check(session.destinationTabGroups(for: b.id).map(\.id) == [unnamed],
                  "Add to Group lists existing groups for ungrouped tabs")
            store.ungroupTabs(unnamed)
            let groupID = store.createTabGroup(name: " Lectures ", containing: a.id)!
            store.moveTab(c.id, intoGroup: groupID)
            check(session.tabGroups.count == 1 && session.tabGroups[0].name == "Lectures"
                  && session.tabs.filter { !$0.isHome }.map(\.id) == [a.id, c.id, b.id],
                  "adding a tab to a named group keeps its members together")
            session.selectedTabID = a.id
            session.toggleTabGroup(groupID)
            check(session.selectedTabScrollID == groupID && session.activeDocumentTab === a,
                  "collapsing the active group keeps the PDF open and scrolls to its header")
            store.saveSession()
            let restored = AppStore()
            let restoredGroup = restored.primarySession.tabGroups.first
            check(restoredGroup?.id == groupID && restoredGroup?.name == "Lectures"
                  && restoredGroup?.isCollapsed == true && restoredGroup?.tabIDs.count == 2
                  && restoredGroup?.color == session.tabGroups[0].color,
                  "session restoration preserves group names, members, color and collapsed state")
            restored.selectNextTab()
            check(restored.activeDocumentTab?.documentID == c.documentID
                  && restored.primarySession.tabGroups.first?.isCollapsed == false,
                  "keyboard switching automatically reveals a tab inside a collapsed group")
            store.moveTab(c.id, intoGroup: nil)
            check(session.tabGroup(containing: c.id) == nil && session.tabGroups[0].tabIDs == [a.id],
                  "removing a tab from a group preserves its remaining members")
            store.moveTab(c.id, intoGroup: groupID)
            let second = store.createTabGroup(name: "Notes", containing: c.id)!
            let colors = Dictionary(uniqueKeysWithValues: session.tabGroups.map { ($0.id, $0.color) })
            check(Set(colors.values).count == 2, "new groups receive distinct colors while palette colors are available")
            check(session.tabs.filter { !$0.isHome }.map(\.id) == [a.id, c.id, b.id]
                  && session.tabGroups.count == 2, "creating a group from a grouped tab does not split the old group's members")
            store.moveDocumentTab(id: b.id, toDocumentIndex: 1)
            check(session.tabGroup(containing: b.id)?.id == second, "drag-style reordering into a group updates membership")
            session.moveTabGroup(second, before: groupID)
            check(session.tabGroups.map(\.id) == [second, groupID]
                  && session.tabs.filter { !$0.isHome }.map(\.id) == [b.id, c.id, a.id],
                  "reordering a group moves its whole block in the shared tab order")
            session.moveTabGroup(groupID, before: second)
            check(session.tabGroups.map(\.id) == [groupID, second], "groups can move before another group without losing members")
            store.renameTabGroup(second, name: "Papers")
            check(session.tabGroups.allSatisfy { colors[$0.id] == $0.color }, "renaming and reordering preserve group colors")
            store.setTabGroupColor(second, color: .teal)
            check(session.tabGroups.first(where: { $0.id == second })?.color == .teal
                  && session.tabGroups.first(where: { $0.id == groupID })?.color == colors[groupID],
                  "choosing a group color updates only that group")
            store.renameTabGroup(second, name: " \n ")
            if let unnamedSecond = session.tabGroups.first(where: { $0.id == second }) {
                let expectedUnnamedTitle = session.tabs.compactMap {
                    if case .document(let t) = $0, unnamedSecond.tabIDs.contains(t.id) { return "“\(t.title)”" }
                    return nil
                }.joined(separator: ", ")
                check(session.tabGroupMenuTitle(unnamedSecond) == expectedUnnamedTitle,
                      "unnamed multi-tab group menu title lists its quoted member tab names in order")
            }
            if let namedGroup = session.tabGroups.first(where: { $0.id == groupID }) {
                check(session.tabGroupMenuTitle(namedGroup) == "Lectures",
                      "named group menu title keeps its custom name")
            }
            check(session.destinationTabGroups(for: a.id).map(\.id) == [second],
                  "Add to Group offers only other groups for a grouped tab")
            store.moveTab(a.id, intoGroup: second)
            if let threeTabUnnamed = session.tabGroups.first(where: { $0.id == second }) {
                let firstTwo = session.tabs.compactMap {
                    if case .document(let t) = $0, threeTabUnnamed.tabIDs.contains(t.id) { return "“\(t.title)”" }
                    return nil
                }.prefix(2).joined(separator: ", ")
                check(session.tabGroupMenuTitle(threeTabUnnamed) == "\(firstTwo) (+1)",
                      "unnamed group menu title summarizes more than two quoted member tabs")
            }
            store.createTabGroup(name: "Lectures", containing: a.id,
                                 draft: ReaderTabGroup(id: groupID, name: "Lectures", tabIDs: [a.id], color: colors[groupID]!))
            session.moveTabGroup(groupID, before: second)
            store.saveSession()
            let recolored = AppStore()
            let unnamedRestored = recolored.primarySession.tabGroups.first(where: { $0.id == second })
            check(unnamedRestored?.color == .teal && unnamedRestored?.name == "" && unnamedRestored?.tabIDs.count == 2,
                  "renaming a group to blank preserves its chosen color and members across session restoration")
            store.renameTabGroup(second, name: "Papers")
            let closedOrder = session.tabs.filter { session.tabGroup(containing: $0.id)?.id == second }.map { $0.title }
            store.closeTabGroup(second)
            check(session.tabGroups.count == 1 && session.tabs.filter { !$0.isHome }.count == 1,
                  "closing a group closes only its member tabs and removes the empty group")
            store.reopenClosedTab()
            store.reopenClosedTab()
            check(session.tabGroups.first(where: { $0.id == second })?.name == "Papers"
                  && session.tabGroups.first(where: { $0.id == second })?.tabIDs.count == 2
                  && session.tabGroups.first(where: { $0.id == second })?.color == .teal
                  && session.tabs.filter { session.tabGroup(containing: $0.id)?.id == second }.map { $0.title } == closedOrder,
                  "reopening closed grouped tabs restores their shared group, color and original order")
            store.ungroupTabs(groupID)
            store.ungroupTabs(second)
            check(session.tabGroups.isEmpty && session.tabs.filter { !$0.isHome }.count == 3,
                  "ungrouping leaves every PDF open")
            withExtendedLifetime((restored, recolored)) {}
        }
        do {
            let store = freshStore()
            let a = store.openDocument(at: alpha, interactive: false)!
            let b = store.openDocument(at: beta, interactive: false)!
            let legacy = [SavedTabGroup(id: UUID(), name: "First", paths: [a.documentID.normalizedPath], isCollapsed: false),
                          SavedTabGroup(id: UUID(), name: "Second", paths: [b.documentID.normalizedPath], isCollapsed: true)]
            defaults.set(try JSONEncoder().encode(legacy), forKey: "expertPDFReader.TabGroups")
            let restored = AppStore()
            check(restored.primarySession.tabGroups.count == 2
                  && Set(restored.primarySession.tabGroups.map(\.color)).count == 2,
                  "groups saved before colors were introduced restore with distinct colors")
            withExtendedLifetime(store) {}
        }
        do {
            let store = freshStore()
            let a = store.openDocument(at: alpha, interactive: false)!
            let b = store.openDocument(at: beta, interactive: false)!
            store.selectedTabID = a.id
            check(defaults.string(forKey: "expertPDFReader.SelectedTab") == a.documentID.normalizedPath,
                  "selection persists the newly selected tab")
            store.closeTab(id: b.id)
            check(defaults.stringArray(forKey: "expertPDFReader.OpenTabs") == [a.documentID.normalizedPath],
                  "closing a background tab removes it from saved session immediately")
            let c = store.openDocument(at: gamma, interactive: false)!
            store.moveDocumentTab(id: c.id, toDocumentIndex: 0)
            check(defaults.stringArray(forKey: "expertPDFReader.OpenTabs") == [c.documentID.normalizedPath, a.documentID.normalizedPath],
                  "reordered tabs persist in their final order")
            store.selectHomeTab()
            store.selectNextTab()
            check(store.activeDocumentTab === c, "next tab from Home selects the first document")
            store.selectPreviousTab()
            check(store.activeDocumentTab === a, "previous tab wraps between documents without visiting Home")
            a.currentPageIndex = 2
            a.readingSpot = .init(pageIndex: 2, point: CGPoint(x: 280, y: 420))
            a.zoomScale = 1.7
            a.isAutoScaling = false
            a.isLeftSidebarVisible = false
            store.closeTab(id: a.id)
            store.reopenClosedTab()
            let reopened = store.activeDocumentTab!
            check(reopened.documentID == a.documentID && reopened.currentPageIndex == 2
                  && abs(reopened.zoomScale - 1.7) < 0.01 && !reopened.isAutoScaling && !reopened.isLeftSidebarVisible,
                  "reopening restores page, zoom and sidebar state")
            check(reopened.readingSpot == a.readingSpot, "reopening restores the position inside the page")
            let roundTrip = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(reopened.readingPosition))
            check(roundTrip.readingSpot == a.readingSpot, "precise reading position survives preferences encoding")
            var menuInvalidations = 0
            let menuObservation = store.objectWillChange.sink { menuInvalidations += 1 }
            reopened.beginSearch()
            check(menuInvalidations > 0, "active document changes invalidate menu command state")
            withExtendedLifetime(menuObservation) {}
        }
        do {
            let store = freshStore()
            let tab = store.openDocument(at: alpha, interactive: false)!
            let session = store.primarySession
            store.tabsInSidebar = true
            store.toggleLeftPanel(in: session)
            check(!tab.isLeftSidebarVisible && store.tabsInSidebar && store.activeDocumentTab === tab,
                  "page navigation visibility stays independent of sidebar tabs")
            store.showSidebarTab(.outline)
            check(tab.isLeftSidebarVisible && tab.activeSidebarTab == .outline && store.tabsInSidebar,
                  "opening the outline never replaces the sidebar tab list")
            store.selectHomeTab(in: session.id)
            store.toggleLeftPanel(in: session)
            check(!session.isHomeSidebarVisible && tab.isLeftSidebarVisible && store.tabsInSidebar,
                  "Home navigation can be hidden without changing document navigation or sidebar tabs")
        }
        do {
            let store = freshStore()
            let a = store.openDocument(at: alpha, interactive: false)!
            let b = store.openDocument(at: beta, interactive: false)!
            let spot = DocumentTabState.ReadingSpot(pageIndex: 2, point: CGPoint(x: 280, y: 420))
            let scan = BookPageScan(readsRightToLeft: true)
            var position = a.readingPosition
            position.pageIndex = 2
            position.readingSpot = spot
            position.zoomScale = 1.7
            position.isAutoScaling = false
            position.layoutMode = .twoPagesCover
            position.pageDirection = .leftToRight
            position.bookPageScan = scan
            a.restore(position)
            b.currentPageIndex = 1
            store.selectedTabID = a.id
            store.saveSession()

            let restored = AppStore()
            let active = restored.activeDocumentTab!
            check(restored.restoreTabsOnLaunch && restored.allOpenDocumentTabs.map(\.documentID) == [a.documentID, b.documentID]
                  && active.documentID == a.documentID && active.currentPageIndex == 2 && active.readingSpot == spot,
                  "tab restoration is on by default and restores tab order, selection and reading positions")
            let savedPositions = defaults.data(forKey: "expertPDFReader.ReadingPositions")
            restored.restoreTabsOnLaunch = false
            check(restored.allOpenDocumentTabs.count == 2 && active.currentPageIndex == 2 && active.readingSpot == spot,
                  "disabling tab restoration leaves the current session open")
            check(defaults.data(forKey: "expertPDFReader.ReadingPositions") == savedPositions,
                  "disabling tab restoration never clears saved reading positions")
            restored.saveSession()

            let restarted = AppStore()
            check(!restarted.restoreTabsOnLaunch && restarted.allOpenDocumentTabs.isEmpty && restarted.activeDocumentTab == nil,
                  "launching with tab restoration off opens Home without reopening PDFs")
            let manual = restarted.openDocument(at: alpha, interactive: false)!
            check(manual.currentPageIndex == 2 && manual.readingSpot == spot && manual.zoomScale == 1.7
                  && !manual.isAutoScaling && manual.layoutMode == .twoPagesCover
                  && manual.pageDirection == .leftToRight && manual.pageScan == scan,
                  "manually opening a PDF still restores its page, scroll, zoom, layout and page scan")
            manual.currentPageIndex = 3
            let newSpot = DocumentTabState.ReadingSpot(pageIndex: 3, point: CGPoint(x: 200, y: 300))
            manual.readingSpot = newSpot
            restarted.saveSession()
            let home = AppStore()
            check(home.allOpenDocumentTabs.isEmpty, "tab restoration stays off after a session is saved")
            home.restoreTabsOnLaunch = true
            check(home.allOpenDocumentTabs.isEmpty, "enabling tab restoration takes effect on the next launch")
            let resumed = AppStore()
            check(resumed.restoreTabsOnLaunch && resumed.activeDocumentTab?.documentID == a.documentID
                  && resumed.activeDocumentTab?.currentPageIndex == 3 && resumed.activeDocumentTab?.readingSpot == newSpot,
                  "re-enabling tab restoration reopens the last session with reading progress saved while it was off")
        }
        do {
            let store = freshStore()
            check(!store.alwaysShowPageIndicator, "floating page counter defaults to auto-hide")
            store.alwaysShowPageIndicator = true
            check(AppStore().alwaysShowPageIndicator, "pinning the floating page counter persists across launches")
            store.alwaysShowPageIndicator = false
            check(!AppStore().alwaysShowPageIndicator, "unpinning the floating page counter persists across launches")

            let pill = NSColor(AppPalette.pageIndicatorBackground(pdfTheme: .night, isDarkUI: true, isHovered: false))
                .usingColorSpace(.sRGB)!
            let nightCanvas = PDFViewTheme.night.documentBackgroundNSColor(isDarkUI: true).usingColorSpace(.sRGB)!
            check(pill.redComponent > nightCanvas.redComponent + 0.05
                  && pill.greenComponent > nightCanvas.greenComponent + 0.05
                  && pill.blueComponent > nightCanvas.blueComponent + 0.05,
                  "night page indicator pill lifts distinctly above the dark canvas and black paper")
        }
        do {
            var hoveredStates: [Bool] = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = container
            let hoverView = SidebarTabHoverView(frame: CGRect(x: 0, y: 0, width: 220, height: 300))
            hoverView.onHover = { hoveredStates.append($0) }
            container.addSubview(hoverView)

            let inside = NSEvent.enterExitEvent(with: .mouseEntered,
                location: NSPoint(x: 80, y: 150), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            hoverView.mouseEntered(with: inside)
            check(hoveredStates == [true], "sidebar hover opens when pointer enters")

            hoverView.reconcileHover(at: NSPoint(x: 260, y: 150), immediate: true)
            check(hoveredStates == [true, false], "reconciling with an outside point collapses sidebar immediately")

            hoverView.mouseEntered(with: inside)
            hoverView.isMenuTracking = true
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            check(hoveredStates == [true, false, true],
                  "context menu tracking prevents premature resign-key collapse")

            hoverView.isMenuTracking = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            check(hoveredStates == [true, false, true, false],
                  "window resign-key collapses sidebar immediately once menu tracking finishes")

            hoverView.mouseEntered(with: inside)
            let edgeExit = NSEvent.enterExitEvent(with: .mouseExited,
                location: NSPoint(x: 220, y: 150), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            hoverView.mouseExited(with: edgeExit)
            try await Task.sleep(for: .milliseconds(160))
            check(hoveredStates.last == false,
                  "mouseExited on exact drawer boundary collapses sidebar even without follow-up moves")

            hoverView.removeFromSuperview()
            window.close()
        }
        do {
            let store = freshStore()
            let original = try fixture("ClosedBeforeRename")
            let tab = store.openDocument(at: original, interactive: false)!
            store.setFavorite(id: tab.documentID, isFavorite: true)
            store.toggleBookmark(pageIndex: 2, in: tab.documentID)
            tab.currentPageIndex = 2
            store.closeTab(id: tab.id)
            let renamed = root.appendingPathComponent("ClosedAfterRename.pdf")
            try FileManager.default.moveItem(at: original, to: renamed)
            store.pruneMissingDocuments()
            let id = DocumentID(url: renamed)
            check(store.closedTabs.last?.documentID == id, "renamed closed tab remains in reopen history")
            check(store.favoriteDocumentIDs.contains(id) && store.bookmarks(for: id).count == 1,
                  "favorites and bookmarks follow renamed files")
            if !store.closedTabs.isEmpty { store.reopenClosedTab() }
            check(store.activeDocumentTab?.documentID == id && store.activeDocumentTab?.currentPageIndex == 2,
                  "renamed closed tab reopens at its saved page")
        }
        do {
            let store = freshStore()
            let original = try fixture("OpenBeforeRename")
            let tab = store.openDocument(at: original, interactive: false)!
            tab.currentPageIndex = 2
            let renamed = root.appendingPathComponent("OpenAfterRename.pdf")
            try FileManager.default.moveItem(at: original, to: renamed)
            store.pruneMissingDocuments()
            check(tab.documentID == DocumentID(url: renamed) && tab.title == "OpenAfterRename",
                  "open tab path and title follow Finder rename")
            let existing = store.openDocument(at: renamed, interactive: false)
            check(existing === tab && store.allOpenDocumentTabs.count == 1,
                  "opening a renamed file focuses its existing tab")
            store.closeTab(id: tab.id)
            store.reopenClosedTab()
            check(store.activeDocumentTab?.currentPageIndex == 2, "closing a renamed open tab preserves latest position")
        }
        do {
            let store = freshStore()
            let original = try fixture("MovedWithFolder")
            let folder = root.appendingPathComponent("BeforeFolderRename")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let nested = folder.appendingPathComponent("BeforeFileRename.pdf")
            try FileManager.default.moveItem(at: original, to: nested)
            let tab = store.openDocument(at: nested, interactive: false)!
            store.setFavorite(id: tab.documentID, isFavorite: true)
            store.toggleBookmark(pageIndex: 2, in: tab.documentID)
            tab.currentPageIndex = 2
            tab.zoomScale = 1.7
            tab.isAutoScaling = false
            store.saveSession()
            let newFolder = root.appendingPathComponent("AfterFolderRename")
            try FileManager.default.moveItem(at: folder, to: newFolder)
            let renamed = newFolder.appendingPathComponent("AfterFileRename.pdf")
            try FileManager.default.moveItem(at: newFolder.appendingPathComponent(nested.lastPathComponent), to: renamed)
            store.pruneMissingDocuments()
            let newID = DocumentID(url: renamed)
            let oldID = DocumentID(url: nested)
            check(tab.documentID == newID && tab.title == "AfterFileRename",
                  "folder and file renames update the open tab path and title")
            check(store.recentDocumentIDs.filter { $0 == newID } == [newID]
                  && !store.recentDocumentIDs.contains(oldID) && store.favoriteDocumentIDs.contains(newID)
                  && !store.favoriteDocumentIDs.contains(oldID) && store.bookmarks(for: newID).count == 1,
                  "folder and file renames migrate recents, favorites and bookmarks without stale entries")
            store.closeTab(id: tab.id)
            store.reopenClosedTab()
            check(store.activeDocumentTab?.documentID == newID && store.activeDocumentTab?.currentPageIndex == 2
                  && store.activeDocumentTab?.zoomScale == 1.7 && store.activeDocumentTab?.isAutoScaling == false,
                  "moved and renamed file reopens at the same page and zoom")
        }
        do {
            func luminance(_ color: NSColor) -> CGFloat {
                let srgb = color.usingColorSpace(.sRGB)!
                return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
            }
            for preset in [AppAccentColor.green, .teal, .red, .purple, .graphite] {
                check(luminance(preset.nsColor(isDark: true)) > luminance(preset.nsColor(isDark: false)),
                      "dark accent preset \(preset.rawValue) brightens for dark chrome contrast")
            }
            for preset in AppAccentColor.allCases {
                let nightColor = preset.pdfSelectionNSColor(for: .night).usingColorSpace(.sRGB)!
                check(nightColor.alphaComponent >= 0.99
                      && nightColor.redComponent >= 0.55
                      && nightColor.greenComponent >= 0.55
                      && nightColor.blueComponent >= 0.55,
                      "night selection color for \(preset.rawValue) stays pastel before inversion")
            }
        }
        do {
            let store = freshStore()
            let original = try fixture("Deleted")
            let tab = store.openDocument(at: original, interactive: false)!
            store.setFavorite(id: tab.documentID, isFavorite: true)
            store.closeTab(id: tab.id)
            let trash = root.appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: original, to: trash.appendingPathComponent("Deleted.pdf"))
            store.pruneMissingDocuments()
            check(!store.recentDocumentIDs.contains(tab.documentID) && !store.favoriteDocumentIDs.contains(tab.documentID)
                  && store.closedTabs.isEmpty, "trashed files leave recents, favorites and reopen history")
        }
        do {
            let store = freshStore()
            let original = try fixture("RenamedWhileNotRunning")
            let tab = store.openDocument(at: original, interactive: false)!
            store.setFavorite(id: tab.documentID, isFavorite: true)
            store.closeTab(id: tab.id)
            let moved = root.appendingPathComponent("RenamedAtRelaunch.pdf")
            try FileManager.default.moveItem(at: original, to: moved)
            let restored = AppStore()
            let id = DocumentID(url: moved)
            check(restored.closedTabs.last?.documentID == id && restored.favoriteDocumentIDs.contains(id)
                  && restored.recentDocumentIDs.contains(id), "launch resolves one renamed file for every persisted consumer")
        }
        let coveredData = NSMutableData()
        var coveredBox = CGRect(x:0,y:0,width:600,height:800)
        let coveredContext = CGContext(consumer:CGDataConsumer(data:coveredData)!,mediaBox:&coveredBox,nil)!
        coveredContext.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:coveredContext,flipped:false)
        for y:CGFloat in [500,477] {
            ("A hidden explanation left behind in the original material." as NSString).draw(at:CGPoint(x:90,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:12)])
        }
        NSColor.white.setFill();CGRect(x:30,y:450,width:550,height:100).fill()
        for y:CGFloat in [499,476] {
            ("The visible replacement explanation." as NSString).draw(at:CGPoint(x:50,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:18)])
        }
        NSGraphicsContext.restoreGraphicsState()
        coveredContext.endPDFPage();coveredContext.closePDF()
        let coveredDocument = PDFDocument(data:coveredData as Data)!
        let coveredPage = coveredDocument.page(at:0)!
        let coveredSelection = coveredPage.selection(for:CGRect(x:30,y:450,width:550,height:100))!
        check(coveredSelection.string?.contains("hidden explanation") == true
              && PDFSelectionVisibility.requiresVisualSelection(on:coveredPage),
              "covered PDF text is excluded from native selection using the final rendered page")
        check(PDFSelectionVisibility.cachedDecision(for:coveredPage) == true,
              "page visibility is cached so repeated drags do not render the page again")
        let nativeDocument = PDFDocument(url: alpha)!
        check(!PDFSelectionVisibility.requiresVisualSelection(on:nativeDocument.page(at:0)!),
              "ordinary visible digital text keeps native selection and its original characters")
        let clippedData = NSMutableData()
        let clippedContext = CGContext(consumer:CGDataConsumer(data:clippedData)!,mediaBox:&coveredBox,nil)!
        clippedContext.beginPDFPage(nil)
        clippedContext.saveGState()
        clippedContext.clip(to:CGRect(x:0,y:0,width:600,height:100))
        clippedContext.drawPDFPage(nativeDocument.page(at:0)!.pageRef!)
        clippedContext.restoreGState()
        clippedContext.endPDFPage();clippedContext.closePDF()
        let clippedDocument = PDFDocument(data:clippedData as Data)!
        let clippedPage = clippedDocument.page(at:0)!
        check(clippedPage.string?.contains("complete paragraph") == true
              && PDFSelectionVisibility.requiresVisualSelection(on:clippedPage),
              "nested clipping excludes invisible text even without overlapping replacement lines")
        clippedPage.setBounds(CGRect(x:0,y:0,width:600,height:100),for:.cropBox)
        check(PDFSelectionVisibility.cachedDecision(for:clippedPage) == nil,
              "changing the page crop invalidates cached visibility geometry")

        let spreadTab = freshStore().openDocument(at: try fixture("SpreadNavigation"), interactive: false)!
        spreadTab.layoutMode = .twoPages
        spreadTab.stepPage(by: 1)
        check(spreadTab.currentPageIndex == 2, "one forward step skips to the next complete two-page spread")
        spreadTab.currentPageIndex = 3
        spreadTab.stepPage(by: -1)
        check(spreadTab.currentPageIndex == 0, "backward stepping works when PDFKit reports the second page of a spread")
        spreadTab.layoutMode = .twoPagesCover
        spreadTab.stepPage(by: 1)
        let firstSpread = spreadTab.currentPageIndex
        spreadTab.stepPage(by: 1)
        check(firstSpread == 1 && spreadTab.currentPageIndex == 3, "cover navigation steps from cover to pages 2-3 and then the final spread")
        let endToken = spreadTab.pageJumpToken
        spreadTab.stepPage(by: 1)
        check(spreadTab.currentPageIndex == 3 && spreadTab.pageJumpToken == endToken,
              "stepping past the final spread does not jump within it or add navigation history")
        spreadTab.stepPage(by: -1)
        spreadTab.stepPage(by: -1)
        check(spreadTab.currentPageIndex == 0, "backward cover navigation returns to the single cover")
        check(ReaderLayoutMode.singlePage.pageIndex(afterStepping:1,from:1,pageCount:4) == 2
              && ReaderLayoutMode.twoPages.pageIndex(afterStepping:1,from:1,pageCount:5) == 2
              && ReaderLayoutMode.twoPagesCover.pageIndex(afterStepping:-1,from:2,pageCount:6) == 0,
              "single pages, odd final spreads and the second cover-spread page have consistent boundaries")

        // Outline entries jump to a precise destination, including several sections on one page
        let outlineTab = freshStore().openDocument(at: try fixture("SpreadNavigation"), interactive: false)!
        outlineTab.navigateToPage(2)
        let tokenAfterPageJump = outlineTab.pageJumpToken
        check(outlineTab.currentPageIndex == 2 && outlineTab.pageJumpPoint == nil,
              "a plain page jump lands on the page top with no destination point")
        outlineTab.navigateToPage(2, point: CGPoint(x: 70, y: 200))
        check(outlineTab.pageJumpToken == tokenAfterPageJump + 1 && outlineTab.pageJumpPoint == CGPoint(x: 70, y: 200),
              "an outline entry on the current page scrolls to its destination instead of doing nothing")
        check(outlineTab.backStack.count == 1,
              "a same-page outline jump does not add a page to the back history")
        outlineTab.navigateToPage(3, point: CGPoint(x: 70, y: 400))
        check(outlineTab.currentPageIndex == 3 && outlineTab.backStack.count == 2,
              "a cross-page outline jump records the previous page once")
        let tokenBeforeNoop = outlineTab.pageJumpToken
        outlineTab.navigateToPage(3)
        check(outlineTab.pageJumpToken == tokenBeforeNoop,
              "a plain jump to the current page stays a no-op")
        outlineTab.goBack()
        check(outlineTab.currentPageIndex == 2 && outlineTab.pageJumpPoint == nil,
              "going back clears the outline destination point")

        // The active outline row must follow a single consistent reading position, not flip between
        // PDFKit's middle-of-view "current page" and the top-of-view reading line while scrolling.
        let chapter = PDFOutlineNode(title: "Matrices", pageIndex: 34, point: nil, children: [])
        let inner = PDFOutlineNode(title: "Inner", pageIndex: 50, point: CGPoint(x: 0, y: 600), children: [])
        let rotation = PDFOutlineNode(title: "Rotation", pageIndex: 52, point: CGPoint(x: 0, y: 700), children: [])
        let application = PDFOutlineNode(title: "Application", pageIndex: 54, point: CGPoint(x: 0, y: 700), children: [])
        let sections = [chapter, inner, rotation, application]
        func active(_ locationPage: Int, _ line: CGFloat, fallback: Int = 99) -> UUID? {
            PDFOutlinePanel.activeSection(in: sections, locationPage: locationPage, readingLineY: line, fallbackPage: fallback)
        }
        check(active(50, 500, fallback: 52) == inner.id,
              "a known reading line on the top-of-view page wins over a disagreeing current page")
        check(active(50, 700) == chapter.id && active(50, 600) == inner.id,
              "a same-page section becomes active once its heading reaches the reading line")
        check(active(52, 700) == rotation.id && active(54, 700) == application.id,
              "advancing the reading page advances the active section")
        check(active(-1, 0, fallback: 52) == rotation.id,
              "before the first reading report the current page selects the last section on it")
        let openTop = PDFOutlineNode(title: "Open", pageIndex: 52, point: nil, children: [])
        check(PDFOutlinePanel.activeSection(in: [inner, openTop], locationPage: 52, readingLineY: 900, fallbackPage: 52) == openTop.id,
              "a section with an unspecified destination height counts as reached on its page")
        let scroll: [(Int, CGFloat)] = [(50, 700), (50, 600), (50, 100), (52, 750), (52, 700), (52, 100), (54, 700)]
        var lastIndex = -1
        var monotonic = true
        for (page, line) in scroll {
            let id = PDFOutlinePanel.activeSection(in: sections, locationPage: page, readingLineY: line, fallbackPage: page)
            let index = sections.firstIndex { $0.id == id } ?? -1
            if index < lastIndex { monotonic = false }
            lastIndex = index
        }
        check(monotonic, "scrolling forward never makes the highlighted section jump backward")
        let pinned = PDFOutlinePanel.PinnedSelection(nodeID: inner.id, pageIndex: 50, settledLineY: nil)
        let settledPin = PDFOutlinePanel.reconciledPinnedSelection(pinned, locationPage: 50, readingLineY: 600, currentPage: 50)
        check(settledPin?.settledLineY == 600, "clicking a section pins it once the target reading line settles")
        check(PDFOutlinePanel.reconciledPinnedSelection(settledPin, locationPage: 50, readingLineY: 610, currentPage: 50)?.nodeID == inner.id,
              "small layout shifts after clicking keep the clicked section pinned")
        check(PDFOutlinePanel.reconciledPinnedSelection(settledPin, locationPage: 50, readingLineY: 560, currentPage: 50) == nil,
              "manual scrolling clears the pinned outline section")
        check(PDFOutlinePanel.reconciledPinnedSelection(settledPin, locationPage: 51, readingLineY: 700, currentPage: 51) == nil,
              "leaving the page clears the pinned outline section")
        let viewport = CGRect(x: 20, y: 40, width: 600, height: 800)
        check(PDFReaderCanvasView.Coordinator.readingLinePoint(in: viewport, isFlipped: true) == CGPoint(x: 320, y: 240)
              && PDFReaderCanvasView.Coordinator.readingLinePoint(in: viewport, isFlipped: false) == CGPoint(x: 320, y: 640),
              "the outline reading line is measured directly inside either viewport orientation")

        let mixed = PDFDocument(url: try fixture("MixedNumbers", mixedNumbers: true))!
        let numbers = BookPageScanner.scan(mixed).printedNumbers
        check(numbers?.label(at: 1) == nil && numbers?.label(at: 4) == nil
              && numbers?.label(at: 5) == "1" && numbers?.label(at: 23) == "19"
              && numbers?.label(at: 0) == nil && numbers?.label(at: 24) == nil,
              "front matter omits textual labels while Arabic book numbering preserves covers")
        do {
            let tab = DocumentTabState(url: mixed.documentURL!, pdfDocument: mixed)
            var position = tab.readingPosition
            position.bookPageScan = BookPageScan(printedNumbers: numbers)
            tab.restore(position)
            check(tab.displayPageNumber(at: 0) == "(1)" && tab.displayPageNumber(at: 1) == "(2)"
                  && tab.displayPageNumber(at: 4) == "(5)" && tab.displayPageNumber(at: 5) == "1"
                  && tab.displayPageNumber(at: 24) == "(25)",
                  "front matter and unnumbered back covers show parenthesized PDF positions")
            check(tab.pageIndex(forPageInput: "1") == 5 && tab.pageIndex(forPageInput: "19") == 23,
                  "bare numbers navigate by book page rather than PDF position")
            check(tab.pageIndex(forPageInput: "(1)") == 0 && tab.pageIndex(forPageInput: "(25)") == 24,
                  "parenthesized numbers can reach both unnumbered covers")
            check(tab.pageIndex(forPageInput: "（２）") == 1 && tab.pageIndex(forPageInput: "１") == 5
                  && tab.pageIndex(forPageInput: "  ( 2 ) \n") == 1,
                  "page entry accepts full-width digits, parentheses and surrounding whitespace")
            check(["", "0", "20", "(0)", "(26)", "-1", "iv", "目录 - 1", "((1))", "+1", "1x"].allSatisfy {
                tab.pageIndex(forPageInput: $0) == nil
            }, "invalid book entries do not silently fall back to PDF positions")
            let legacy = #"{"runs":[{"firstIndex":5,"lastIndex":23,"offset":-4}],"oddIndexShift":0,"replacesPageLabels":true,"frontMatterLabels":{"1":"目录 - 1","2":"ii"}}"#
            let restored = try JSONDecoder().decode(PrintedPageNumbers.self, from: Data(legacy.utf8))
            position.bookPageScan = BookPageScan(printedNumbers: restored)
            tab.restore(position)
            check(tab.displayPageNumber(at: 1) == "(2)" && tab.pageIndex(forPageInput: "1") == 5,
                  "saved numbering caches discard legacy front-matter titles without requiring a rescan")
            let plain = DocumentTabState(url: alpha, pdfDocument: PDFDocument(url: alpha)!)
            check(plain.pageIndex(forPageInput: "4") == 3 && plain.pageIndex(forPageInput: "(4)") == 3,
                  "documents without separate book numbering accept both input formats")
            position.bookPageScan = BookPageScan(printedNumbers: .init(runs: [.init(firstIndex: 3, lastIndex: 22, offset: -2)],
                oddIndexShift: 2, replacesPageLabels: true))
            tab.restore(position)
            check(tab.pageIndex(forPageInput: "2") == 4 && tab.pageIndex(forPageInput: "3") == 3
                  && tab.pageIndex(forPageInput: "21") == 21 && tab.pageIndex(forPageInput: "20") == 22,
                  "left-first scanned spreads navigate by printed numbers despite interleaved PDF order")
        }
        do {
            let url = root.appendingPathComponent("ScanCache.pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let image = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 2400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            image.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); image.fill(box)
            image.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); image.fill(CGRect(x: 300, y: 400, width: 300, height: 400))
            let context = CGContext(url as CFURL, mediaBox: &box, nil)!
            context.beginPDFPage(nil); context.draw(image.makeImage()!, in: box); context.endPDFPage(); context.closePDF()
            let native = PDFDocument(url: url)!, cached = PDFDocument(url: url)!
            ScannedPageCache.install(on: cached)
            let a = native.page(at: 0)!, b = cached.page(at: 0)!
            func tile(_ page: PDFPage, scale: CGFloat, at point: CGPoint) -> Data {
                let bitmap = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                bitmap.translateBy(x: -point.x * scale, y: -point.y * scale); bitmap.scaleBy(x: scale, y: scale)
                page.draw(with: .cropBox, to: bitmap)
                return Data(bytes: bitmap.data!, count: 64 * 256)
            }
            let locations = [CGPoint(x: 40, y: 50), CGPoint(x: 380, y: 500)]
            check(locations.allSatisfy { tile(a, scale: 4.5, at: $0) == tile(b, scale: 4.5, at: $0) },
                  "cold scan rasters above 200 percent retain native pixels in separate tiles")
            let crop = CGRect(x: 80, y: 90, width: 470, height: 610)
            a.setBounds(crop, for: .cropBox); b.setBounds(crop, for: .cropBox)
            check(tile(a, scale: 4.5, at: .init(x: 30, y: 40)) == tile(b, scale: 4.5, at: .init(x: 30, y: 40)),
                  "scan raster keys preserve nonzero crop origins")
            a.rotation = 90; b.rotation = 90
            check(tile(a, scale: 2, at: .zero) == tile(b, scale: 2, at: .zero),
                  "rotated scans retain native drawing")
            a.rotation = 0; b.rotation = 0
            let request = ScannedPageCache.PrefetchPage(index: 0, mediaBox: box, cropBox: crop, rotation: 0)
            await ScannedPageCache.prefetch(url: url, pages: [request], scale: 4.5).value
            check(tile(a, scale: 4.5, at: .init(x: 30, y: 40)) == tile(b, scale: 4.5, at: .init(x: 30, y: 40)),
                  "private prefetch copies share valid scan pixels with the visible document")
            // Live PDFView tiles render through layer contexts whose CGBitmapContext width is 0;
            // verify drawing through a layer-backed NSView/PDFView hits the cache without error.
            let scanWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            let scanPDFView = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
            scanPDFView.displayBox = .cropBox
            scanPDFView.document = cached
            scanWindow.contentView = scanPDFView
            scanWindow.layoutIfNeeded()
            scanPDFView.displayIfNeeded()
            check(scanPDFView.currentPage === b, "live PDFView renders cached scan page cleanly")
            let identity = ScannedPageCache.identity(of: cached)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
            let changed = PDFDocument(url: url)!
            ScannedPageCache.install(on: changed)
            check(ScannedPageCache.identity(of: changed) != identity,
                  "source file modification invalidates reusable scan document identities")
        }
        do {
            let url = root.appendingPathComponent("RunningHeaders.pdf")
            var media = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = CGContext(url as CFURL, mediaBox: &media, nil)!
            for index in 0..<80 {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
                ("Publisher edition 2012" as NSString).draw(at: CGPoint(x: 50, y: 770), withAttributes: attributes)
                ("A complete body paragraph for page-number regression testing." as NSString)
                    .draw(at: CGPoint(x: 50, y: 500), withAttributes: attributes)
                if index >= 5 {
                    let number = index - 4 - (index >= 40 ? 2 : 0)
                    let header = index % 2 == 0 ? "\(number) RUNNING TITLE" : "RUNNING TITLE \(number)"
                    (header as NSString).draw(at: CGPoint(x: index % 2 == 0 ? 45 : 390, y: 720), withAttributes: attributes)
                }
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
            let scan = BookPageScanner.scan(PDFDocument(url: url)!).printedNumbers
            check(scan?.number(at: 5) == 1 && scan?.number(at: 38) == 34 && scan?.number(at: 39) == 35
                  && scan?.number(at: 40) == 34 && scan?.number(at: 41) == 35 && scan?.number(at: 79) == 73,
                  "single-space running titles below publisher text recognize repeated inserted pages")
        }
        do {
            func article(_ name: String, range: String = "595–622", mismatchedSecondPage: Bool = false) -> PDFDocument {
                let url = root.appendingPathComponent(name).appendingPathExtension("pdf")
                var box = CGRect(x: 0, y: 0, width: 600, height: 800)
                let context = CGContext(url as CFURL, mediaBox: &box, nil)!
                for index in 0..<29 {
                    context.beginPDFPage(nil)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
                    let header = index == 0 ? "2023" : (index == 1 ? "2023, VOL. 20, NO. 2, \(range)"
                        : "\(594 + index + (mismatchedSecondPage && index == 3 ? 1 : 0)) JOURNAL AUTHOR")
                    (header as NSString).draw(at: CGPoint(x: 45, y: 750), withAttributes: attributes)
                    let body = index == 0 ? "Publisher download page. Cite this article: 595–622."
                        : "ABSTRACT and Introduction. A complete paragraph for article pagination."
                    (body as NSString).draw(at: CGPoint(x: 50, y: 500), withAttributes: attributes)
                    NSGraphicsContext.restoreGraphicsState()
                    context.endPDFPage()
                }
                context.closePDF()
                return PDFDocument(url: url)!
            }
            let document = article("JournalOpening")
            let scan = BookPageScanner.scan(document)
            check(scan.printedNumbers?.number(at: 0) == nil && scan.printedNumbers?.number(at: 1) == 595
                  && scan.printedNumbers?.number(at: 2) == 596 && scan.printedNumbers?.number(at: 28) == 622,
                  "a corroborated journal range includes the unnumbered article opening and excludes its publisher cover")
            let legacy = PrintedPageNumbers(runs: [.init(firstIndex: 2, lastIndex: 28, offset: 594)],
                                           oddIndexShift: 0, replacesPageLabels: true)
            let tab = DocumentTabState(url: document.documentURL!, pdfDocument: document)
            var position = tab.readingPosition
            position.bookPageScan = BookPageScan(printedNumbers: legacy)
            tab.restore(position)
            check(tab.displayPageNumber(at: 0) == "(1)" && tab.displayPageNumber(at: 1) == "595"
                  && tab.pageIndex(forPageInput: "595") == 1 && tab.pageIndex(forPageInput: "(1)") == 0,
                  "old journal caches are refined without changing numeric and PDF-position navigation")
            for (name, range) in [("UnrelatedYears", "2021–2023"), ("WrongFirstPage", "594–622"), ("WrongEndPage", "595–623")] {
                check(BookPageScanner.refiningArticleOpening(legacy, in: article(name, range: range)) == legacy,
                      "journal refinement ignores an uncorroborated range: \(name)")
            }
            check(BookPageScanner.refiningArticleOpening(legacy, in: article("WrongNeighbour", mismatchedSecondPage: true)) == legacy,
                  "journal refinement requires both following printed numbers to agree")
            let bookNumbers = PrintedPageNumbers(runs: [.init(firstIndex: 5, lastIndex: 23, offset: -4)],
                                                oddIndexShift: 0, replacesPageLabels: true)
            let bookDocument = PDFDocument(url: try fixture("NormalBook", mixedNumbers: true))!
            check(BookPageScanner.refiningArticleOpening(bookNumbers, in: bookDocument) == bookNumbers,
                  "ordinary book front matter and numbering caches remain unchanged")
        }
        do {
            func drawPDF(_ name: String, pages: Int, drawPage: (Int, CGContext) -> Void) -> PDFDocument {
                let url = root.appendingPathComponent("\(name).pdf")
                var box = CGRect(x: 0, y: 0, width: 600, height: 800)
                let context = CGContext(url as CFURL, mediaBox: &box, nil)!
                let bodyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
                for i in 0..<pages {
                    context.beginPDFPage(nil)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    ("Sample content on PDF page \(i + 1) with enough body text." as NSString)
                        .draw(at: CGPoint(x: 72, y: 500), withAttributes: bodyAttrs)
                    drawPage(i, context)
                    NSGraphicsContext.restoreGraphicsState()
                    context.endPDFPage()
                }
                context.closePDF()
                return PDFDocument(url: url)!
            }

            let compilation = drawPDF("MultiPaperCompilation", pages: 60) { i, _ in
                let footer = "\((i % 20) + 1)"
                (footer as NSString).draw(at: CGPoint(x: 295, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            }
            check(BookPageScanner.scan(compilation).printedNumbers == nil,
                  "multi-paper compilations that restart page 1 fall back to physical PDF numbering")

            let sparse = drawPDF("LowCoverageCompilation", pages: 50) { i, _ in
                if (18..<32).contains(i) {
                    ("\(i - 17)" as NSString).draw(at: CGPoint(x: 295, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
                }
            }
            check(BookPageScanner.scan(sparse).printedNumbers == nil,
                  "compilations with low printed-page coverage fall back to physical PDF numbering")

            let oneSidedFolios = drawPDF("OneSidedFolios", pages: 80) { i, _ in
                if i >= 17, i % 2 == 1 {
                    ("\(i - 15)" as NSString).draw(at: CGPoint(x: 510, y: 750),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
                }
            }
            let oneSidedNumbers = BookPageScanner.scan(oneSidedFolios).printedNumbers
            check(oneSidedNumbers?.number(at: 16) == 1 && oneSidedNumbers?.number(at: 17) == 2
                  && oneSidedNumbers?.number(at: 79) == 64,
                  "widely distributed folios on only one side still correct the whole book")

            let overlapBook = drawPDF("DuplicateSpreadBook", pages: 40) { i, _ in
                let num = i < 20 ? (i + 1) : (i - 1)
                ("\(num)" as NSString).draw(at: CGPoint(x: 295, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            }
            let overlapNumbers = BookPageScanner.scan(overlapBook).printedNumbers
            check(overlapNumbers?.replacesPageLabels == true
                  && overlapNumbers?.number(at: 0) == 1 && overlapNumbers?.number(at: 19) == 20
                  && overlapNumbers?.number(at: 20) == 19 && overlapNumbers?.number(at: 39) == 38,
                  "books with a small duplicate-scanned spread overlap still resolve printed numbering")

            let proceedings = drawPDF("FiveDigitProceedings", pages: 24) { i, _ in
                if i == 0 {
                    ("Proceedings pages 21457–21480" as NSString)
                        .draw(at: CGPoint(x: 72, y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
                } else {
                    ("\(21457 + i)" as NSString)
                        .draw(at: CGPoint(x: 295, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
                }
            }
            let proceedingsNumbers = BookPageScanner.scan(proceedings).printedNumbers
            check(proceedingsNumbers?.number(at: 0) == 21457 && proceedingsNumbers?.number(at: 23) == 21480,
                  "five-digit proceedings page numbers and opening range headers are recognized")

            let longBackMatter = drawPDF("LongBackMatter", pages: 44) { i, _ in
                if i < 30 {
                    ("\(i + 1)" as NSString).draw(at: CGPoint(x: 295, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
                }
            }
            let backNumbers = BookPageScanner.scan(longBackMatter).printedNumbers
            check(backNumbers?.number(at: 0) == 1 && backNumbers?.number(at: 29) == 30 && backNumbers?.number(at: 30) == nil,
                  "finding the end of printed numbering skips over unnumbered midpoints in back matter")

            let tab = DocumentTabState(url: compilation.documentURL!, pdfDocument: compilation)
            var stale = tab.readingPosition
            stale.bookPageScan = BookPageScan(printedNumbers: PrintedPageNumbers(
                runs: [.init(firstIndex: 0, lastIndex: 19, offset: 1), .init(firstIndex: 20, lastIndex: 39, offset: -19)],
                oddIndexShift: 0,
                replacesPageLabels: true
            ))
            tab.restore(stale)
            check(tab.pageScan?.printedNumbers == nil && tab.displayPageNumber(at: 20) == "21",
                  "restoring a stale multi-paper cached scan drops inconsistent printed numbering")
        }
        do {
            check(PageNumberLabel.canonical("1,210") == "1210" && PageNumberLabel.canonical("1.210") == "1210"
                  && PageNumberLabel.canonical("1\u{202F}210") == "1210" && PageNumberLabel.canonical("A-1,210") == "A-1,210",
                  "localized numeric PDF labels do not create duplicate book page indicators")
            check(PDFTextCleanup.normalize("再前方就是千反田的家，就在那\n里。这段路要沿着一条小河下坡。\n\n第二段。")
                  == "再前方就是千反田的家，就在那里。这段路要沿着一条小河下坡。\n\n第二段。",
                  "copied Chinese sentences join soft line wraps and retain paragraph breaks")
            func line(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RecognizedTextLine {
                .init(text: text, confidence: 0.99, x: x, y: y, width: width, height: height)
            }
            check(OCRTextLayout.text(from: [line("一段很长的中文句子", 0, 100, 300, 20),
                       line("继续到下一行。", 0, 140, 240, 20), line("新的段落。", 40, 180, 200, 20)], vertical: false)
                  == "一段很长的中文句子继续到下一行。\n\n新的段落。",
                  "OCR joins physical rows and uses indentation for actual paragraph boundaries")
            check(OCRTextLayout.text(from: [line("不要反转列。", 240, 100, 20, 500),
                       line("从右向左阅读，", 300, 100, 20, 500), line("这是新的一段。", 180, 140, 20, 450),
                       line("99", 300, 960, 20, 20)], vertical: true, pageHeight: 1000)
                  == "从右向左阅读，不要反转列。\n\n这是新的一段。",
                  "vertical OCR reads columns right to left and excludes the printed footer")
            check(OCRTextLayout.text(from: [line("A sentence,", 0, 100, 400, 20), line("with 3", 0, 150, 400, 20),
                       line("examples.", 0, 200, 400, 20)], vertical: false) == "A sentence, with 3 examples.",
                  "English OCR retains word spaces across physical line breaks after punctuation and digits")
            let text = "  中 文 ， 复 制。\n\n第 二 段\tPDF Reader 2026，版本 2.0"
            let expected = "  中文，复制。\n\n第二段\tPDF Reader 2026，版本 2.0"
            check(PDFTextCleanup.normalize(text) == expected,
                  "CJK cleanup preserves paragraphs, indentation, tabs, Latin words and numbers")
            check(PDFTextCleanup.normalize("中⽂ 复 制 x² ① ﬁ 한 글") == "中文复制 x² ① ﬁ 한 글",
                  "CJK compatibility glyphs normalize without changing math, Latin ligatures or Korean spacing")
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18)]
            let rich = NSAttributedString(string: text, attributes: attributes)
            let normalized = PDFTextCleanup.normalize(rich)
            check(normalized.string == expected && (normalized.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize == 18,
                  "CJK rich-text cleanup preserves formatting")
            let board = NSPasteboard.withUniqueName()
            board.setString(text, forType: .string)
            board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
            PDFTextCleanup.normalize(board)
            check(board.string(forType: .string) == expected
                  && board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string } == expected,
                  "both native clipboard text representations are cleaned")
            board.releaseGlobally()
        }
        do {
            func column(_ text: String, x: Double) -> RecognizedTextLine {
                let characters = text.enumerated().map { index, character in
                    RecognizedTextCharacter(text: String(character), confidence: 0.99, x: x, y: 40 + Double(index) * 16, width: 12, height: 36)
                }
                return RecognizedTextLine(text: text, confidence: 0.99, x: x, y: 40, width: 12,
                                          height: Double(characters.count - 1) * 16 + 36, characters: characters)
            }
            let right = "甲乙丙丁戊己庚辛壬癸子丑寅", left = "天地玄黃宇宙洪荒日月盈昃辰"
            let text = OCRPageText(lines: [column(left, x: 40), column(right, x: 100)], vertical: true,
                                   imageSize: CGSize(width: 200, height: 300), cropBox: CGRect(x: 20, y: 30, width: 200, height: 300))
            check(text.text == right + left && text.glyphs.count == 26, "OCR character geometry follows vertical reading order rather than input box order")
            check(text.selectedText(from: 11, through: 15) == "丑寅天地玄", "OCR selection joins column wraps without copying unrelated columns")
            check(text.selectedText(from: 15, through: 11) == "丑寅天地玄", "reverse OCR selection copies in reading order")
            check(text.selectedBounds(from: 11, through: 15).count == 2, "cross-column selection highlights each selected column separately")
            let target = text.glyphs[1].bounds
            check(text.nearestGlyph(to: CGPoint(x: target.midX, y: target.midY)) == 1, "overlapping character boxes choose the closest character center")
            check(abs(text.glyphs[0].bounds.minX - 120) < 0.001 && abs(text.glyphs[0].bounds.maxY - 290) < 0.001,
                  "OCR image coordinates preserve a nonzero PDF crop origin")
            let unicode = OCRPageText(lines: [column("甲😀乙丙丁戊己庚辛壬癸子丑", x: 100)], vertical: true,
                                      imageSize: CGSize(width: 200, height: 300), cropBox: CGRect(x: 0, y: 0, width: 200, height: 300))
            check(unicode.selectedText(from: 0, through: 2) == "甲😀乙", "OCR text ranges preserve Unicode surrogate pairs")
            check(text.selectedText(from: -1, through: 1).isEmpty, "invalid OCR selection indices return no text")
        }
        do {
            func row(_ text: String, x: Double, y: Double, width: Double) -> RecognizedTextLine {
                let step = width / Double(text.count)
                let characters = text.enumerated().map { index, character in
                    RecognizedTextCharacter(text: String(character), confidence: 0.99, x: x + Double(index) * step,
                        y: y, width: step, height: 20)
                }
                return .init(text: text, confidence: 0.99, x: x, y: y, width: width, height: 20, characters: characters)
            }
            let lines = [row("For a small number of rolls,", x: 100, y: 100, width: 270),
                         row("but for large numbers", x: 500, y: 110, width: 220),
                         row("the proportion may differ.", x: 100, y: 122, width: 260),
                         row("0.1", x: 30, y: 132, width: 25),
                         row("the proportion is close.", x: 500, y: 132, width: 230),
                         row("probability of 0.167", x: 100, y: 144, width: 200)]
            let text = OCRPageText(lines: lines, vertical: false, imageSize: CGSize(width: 800, height: 400),
                                   cropBox: CGRect(x: 0, y: 0, width: 800, height: 400))
            let start = text.nearestGlyph(to: CGPoint(x: 101, y: 290))!
            let end = text.nearestGlyph(to: CGPoint(x: 299, y: 246))!
            let expected = "For a small number of rolls, the proportion may differ. probability of 0.167"
            check(text.selectedText(from: start, through: end) == expected,
                  "selecting a diagram annotation excludes adjacent captions and axis labels")
            check(text.selectedText(from: end, through: start) == expected,
                  "reverse dragging preserves the same isolated annotation block")
            let bounds = text.selectedBounds(from: start, through: end)
            check(bounds.count == 3 && bounds.allSatisfy { $0.minX >= 100 && $0.maxX <= 370 },
                  "block selection highlights only the selected caption's lines")
        }
        do {
            let document = PDFDocument(url: alpha)!
            let originalMedia = (0..<document.pageCount).map { document.page(at: $0)!.bounds(for: .mediaBox) }
            let content = [CGRect(x: 0, y: 0, width: 600, height: 800),
                           CGRect(x: 8, y: 50, width: 300, height: 690),
                           CGRect(x: 50, y: 40, width: 410, height: 720),
                           CGRect(x: 270, y: 40, width: 325, height: 700)]
            for index in content.indices { document.page(at: index)!.setBounds(content[index], for: .cropBox) }
            for book in [false, true] {
                for rtl in [false, true] {
                    SpreadAlignment.apply(to: document, holdsContent: true, spread: .init(isBook: book, readsRightToLeft: rtl))
                    let boxes = content.indices.map { document.page(at: $0)!.bounds(for: .cropBox) }
                    let keepsSpine = content.indices.allSatisfy { index in
                        let left = (book ? index % 2 == 1 : index % 2 == 0) != rtl
                        return abs((left ? boxes[index].maxX : boxes[index].minX) - (left ? content[index].maxX : content[index].minX)) < 0.01
                    }
                    check(boxes.allSatisfy { abs($0.width - 600) < 0.01 } && keepsSpine,
                          "cropped spreads share column width and preserve the spine (cover=\(book), RTL=\(rtl))")
                    let topsAndPairs = content.indices.allSatisfy { index in
                        let partner = book ? (index == 0 ? -1 : (index % 2 == 1 ? index + 1 : index - 1)) : index ^ 1
                        return abs(boxes[index].maxY - content[index].maxY) < 0.01
                            && (!content.indices.contains(partner) || abs(boxes[index].height - boxes[partner].height) < 0.01)
                    }
                    check(topsAndPairs, "unequal-height cropped pages align at the top without removing content (cover=\(book), RTL=\(rtl))")
                    SpreadAlignment.apply(to: document, holdsContent: true, spread: nil)
                    check(content.indices.allSatisfy { document.page(at: $0)!.bounds(for: .cropBox) == content[$0]
                          && document.page(at: $0)!.bounds(for: .mediaBox) == originalMedia[$0] },
                          "leaving a spread restores crop and media boxes exactly")
                }
            }
        }
        do {
            let canvas = ThemedPDFView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            check(canvas.registeredDraggedTypes.isEmpty,
                  "PDF canvas unregisters default PDFView dragged types so window drops open tabs")
            check(PDFFileDrop.resolvedPDFURL(from: alpha) == alpha.standardizedFileURL,
                  "PDF drop accepts direct file URLs")
            check(PDFFileDrop.resolvedPDFURL(from: (alpha as NSURL).dataRepresentation) == alpha.standardizedFileURL,
                  "PDF drop accepts URL data representations")
            if let refData = ((alpha as NSURL).fileReferenceURL() as NSURL?)?.dataRepresentation {
                check(PDFFileDrop.resolvedPDFURL(from: refData) == alpha.standardizedFileURL,
                      "PDF drop resolves Finder file-reference URLs")
            }
            let nonPDF = root.appendingPathComponent("note.txt")
            check(PDFFileDrop.resolvedPDFURL(from: nonPDF) == nil,
                  "PDF drop ignores non-PDF file URLs")

            var openedFromProviders: [URL] = []
            if let fileURLProvider = NSItemProvider(contentsOf: alpha) {
                let acceptedFileDrop = PDFFileDrop.open([fileURLProvider]) { url in
                    openedFromProviders.append(url)
                }
                check(acceptedFileDrop, "PDFFileDrop.open accepts fileURL NSItemProvider")
            } else {
                check(false, "Failed to create fileURL NSItemProvider for PDF drop test")
            }

            let linkProvider = NSItemProvider()
            let linkData = alpha.absoluteString.data(using: .utf8)!
            linkProvider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
                completion(linkData, nil)
                return nil
            }
            let acceptedURLDrop = PDFFileDrop.open([linkProvider]) { url in
                openedFromProviders.append(url)
            }
            check(acceptedURLDrop, "PDFFileDrop.open accepts public.url NSItemProvider")

            let deadline = Date().addingTimeInterval(2.0)
            while openedFromProviders.count < 2 && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            check(openedFromProviders == [alpha.standardizedFileURL, alpha.standardizedFileURL],
                  "PDFFileDrop.open delivers resolved fileURL and public.url drops on MainActor (got \(openedFromProviders))")
        }
        do {
            let store = freshStore()
            let tabA = store.openDocument(at: alpha, interactive: false)!
            let tabB = store.openDocument(at: beta, interactive: false)!
            check(store.activeDocumentTab?.id == tabB.id, "opening a second document makes it active before Home toggle")
            store.toggleHomeTab()
            check(store.activeDocumentTab == nil && store.primarySession.returnableDocumentTabID == tabB.id,
                  "clicking Home leaves the document tab and remembers it")
            store.toggleHomeTab()
            check(store.activeDocumentTab?.id == tabB.id,
                  "clicking Home again returns to the previously active document tab")
            store.toggleHomeTab()
            store.closeTab(id: tabB.id)
            check(store.activeDocumentTab == nil && store.primarySession.returnableDocumentTabID == tabA.id,
                  "closing the last active document while on Home falls back to another open tab")
            store.toggleHomeTab()
            check(store.activeDocumentTab?.id == tabA.id,
                  "clicking Home returns to the remaining open document tab")
            store.toggleHomeTab()
            store.closeTab(id: tabA.id)
            store.toggleHomeTab()
            check(store.activeDocumentTab == nil && store.primarySession.returnableDocumentTabID == nil,
                  "clicking Home with no open document tabs stays on Home")

            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 120),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
            window.contentView = container
            let panelCursor = PanelCursorRect.View()
            panelCursor.frame = CGRect(x: 0, y: 0, width: 320, height: 40)
            panelCursor.priority = 1
            let textField = NSTextField(frame: CGRect(x: 180, y: 6, width: 120, height: 28))
            textField.isEditable = true
            let textChild = NSView(frame: textField.bounds)
            textField.addSubview(textChild)
            container.addSubview(panelCursor)
            container.addSubview(textField)
            check(ReaderCursorArbiter.shared.cursor(at: CGPoint(x: 40, y: 20), in: window) == .arrow,
                  "cursor arbiter enforces arrow cursor across registered toolbar/panel areas")
            check(ReaderCursorArbiter.shared.cursor(at: CGPoint(x: 220, y: 20), in: window) == nil,
                  "cursor arbiter defers to editable text fields and their inner subviews")
            panelCursor.removeFromSuperview()
            window.close()
        }
        do {
            // Unified multi-page export, thumbnail multi-selection, rotation/bookmark undo & redo, and localization
            let store = freshStore()
            let tab = store.openDocument(at: alpha, interactive: false)!
            tab.undoManager.groupsByEvent = false
            tab.currentPageIndex = 1
            tab.readingSpot = .init(pageIndex: 1, point: CGPoint(x: 120, y: 640))
            let initialJump = tab.pageJumpToken
            let initialLayout = tab.clearMarginsLayoutToken

            // 1. Rotate non-current thumbnail page without jumping away + Undo / Redo
            tab.undoManager.beginUndoGrouping()
            tab.rotatePage(at: 3, in: tab.pdfDocument, clockwise: true)
            tab.undoManager.endUndoGrouping()
            check(tab.pdfDocument.page(at: 3)?.rotation == 90
                  && tab.pdfDocument.page(at: 1)?.rotation == 0
                  && tab.currentPageIndex == 1
                  && tab.pageJumpToken == initialJump
                  && tab.clearMarginsLayoutToken == initialLayout + 1
                  && tab.readingSpotBeforeCropChange == tab.readingSpot
                  && tab.undoManager.canUndo,
                  "rotating a non-current thumbnail rotates only that page, keeps reading spot, and records undo")

            tab.undoManager.undo()
            check(tab.pdfDocument.page(at: 3)?.rotation == 0 && tab.undoManager.canRedo,
                  "undo restores single-page rotation and enables redo")
            tab.undoManager.redo()
            check(tab.pdfDocument.page(at: 3)?.rotation == 90,
                  "redo reapplies single-page rotation")

            // 2. Rotate primary current page & secondary pane current page
            tab.undoManager.beginUndoGrouping()
            tab.rotatePage(at: 1, in: tab.pdfDocument, clockwise: false)
            tab.undoManager.endUndoGrouping()
            check(tab.pdfDocument.page(at: 1)?.rotation == 270
                  && tab.pageJumpToken == initialJump + 1
                  && tab.readingSpotBeforeCropChange == nil,
                  "rotating the primary current page updates rotation and clears stale pre-rotation spot")

            tab.splitMode = .vertical
            tab.setSecondaryDocument(url: beta)
            tab.secondaryPageIndex = 2
            tab.secondaryReadingSpot = .init(pageIndex: 2, point: CGPoint(x: 80, y: 500))
            tab.activatePane(isSecondary: true)
            let secJumpBefore = tab.secondaryPageJumpToken
            let layoutBefore = tab.clearMarginsLayoutToken
            tab.undoManager.beginUndoGrouping()
            tab.rotateCurrentPage(clockwise: true)
            tab.undoManager.endUndoGrouping()
            check(tab.secondaryPDFDocument?.page(at: 2)?.rotation == 90
                  && tab.pdfDocument.page(at: 2)?.rotation == 0
                  && tab.secondaryPageJumpToken == secJumpBefore + 1
                  && tab.clearMarginsLayoutToken == layoutBefore + 1
                  && tab.secondaryReadingSpotBeforeCropChange == nil,
                  "rotateCurrentPage targets the active secondary pane when focused")

            // 3. Batch multi-page rotation undo/redo atomicity
            tab.undoManager.beginUndoGrouping()
            tab.rotatePages([0, 2], in: tab.pdfDocument, clockwise: true)
            tab.undoManager.endUndoGrouping()
            check(tab.pdfDocument.page(at: 0)?.rotation == 90 && tab.pdfDocument.page(at: 2)?.rotation == 90,
                  "batch rotatePages rotates all selected pages together")
            tab.undoManager.undo()
            check(tab.pdfDocument.page(at: 0)?.rotation == 0 && tab.pdfDocument.page(at: 2)?.rotation == 0,
                  "single undo restores all batch-rotated pages atomically")
            tab.undoManager.redo()
            check(tab.pdfDocument.page(at: 0)?.rotation == 90 && tab.pdfDocument.page(at: 2)?.rotation == 90,
                  "single redo reapplies all batch-rotated pages atomically")

            // 4. Split-view guard and opening specific page in split view
            let foreignSource = tab.activeThumbnailSource
            check(!tab.canOpenThumbnailInSplitView(source: foreignSource),
                  "foreign document active in secondary pane cannot reopen secondary-into-primary split view")

            tab.activatePane(isSecondary: false)
            tab.splitMode = .disabled
            tab.syncScrollAndZoom = true
            tab.isPageOverviewVisible = true
            let primarySource = tab.activeThumbnailSource
            check(tab.canOpenThumbnailInSplitView(source: primarySource),
                  "primary document thumbnail can open in split view")
            tab.openPageInSplitView(2, from: primarySource)
            check(tab.splitMode == .vertical
                  && tab.secondaryPDFDocument === tab.pdfDocument
                  && tab.secondaryPageIndex == 2
                  && tab.currentPageIndex == 1
                  && !tab.syncScrollAndZoom
                  && !tab.targetsSecondaryPane
                  && !tab.isPageOverviewVisible,
                  "opening a thumbnail in split view switches to vertical split on the requested page independently")

            tab.splitMode = .horizontal
            tab.openPageInSplitView(3, from: primarySource)
            check(tab.splitMode == .horizontal && tab.secondaryPageIndex == 3,
                  "opening another thumbnail in split view preserves horizontal split orientation")

            tab.setSecondaryDocument(from: tab)
            check(tab.targetsSecondaryPane && tab.canOpenThumbnailInSplitView(source: tab.activeThumbnailSource),
                  "same-document secondary pane stays eligible for opening counterpart pages in primary pane")
            tab.openPageInSplitView(0, from: tab.activeThumbnailSource)
            check(tab.currentPageIndex == 0 && tab.splitMode == .horizontal,
                  "opening a thumbnail in split view while secondary pane owns the same document navigates primary pane")

            // 5. Thumbnail multi-selection (Shift, Command, Command+Shift, clear, document isolation)
            tab.activatePane(isSecondary: false)
            let pSource = tab.activeThumbnailSource
            tab.clearThumbnailSelection(anchor: 0, in: pSource)
            tab.selectThumbnailRange(to: 2, in: pSource, extending: false)
            check(tab.selectedThumbnailPages(in: pSource) == [0, 1, 2],
                  "Shift-clicking selects inclusive range from anchor")
            tab.toggleThumbnailSelection(1, in: pSource)
            check(tab.selectedThumbnailPages(in: pSource) == [0, 2],
                  "Command-clicking deselects a single page from selection")
            tab.toggleThumbnailSelection(3, in: pSource)
            tab.selectThumbnailRange(to: 1, in: pSource, extending: true)
            check(tab.selectedThumbnailPages(in: pSource) == [0, 1, 2, 3],
                  "Command+Shift extends existing selection range")
            tab.setSecondaryDocument(url: beta)
            tab.activatePane(isSecondary: true)
            check(tab.selectedThumbnailPages.isEmpty,
                  "switching to a different document in secondary pane clears stale thumbnail selection")
            tab.activatePane(isSecondary: false)

            // 6. Bookmark undo & redo preserving title & ID
            let docID = tab.documentID
            tab.undoManager.beginUndoGrouping()
            store.toggleBookmark(pageIndex: 0, defaultTitle: "Custom Intro", in: docID, undoManager: tab.undoManager)
            tab.undoManager.endUndoGrouping()
            let addedBookmark = store.bookmarks(for: docID).first(where: { $0.pageIndex == 0 })
            check(addedBookmark?.title == "Custom Intro", "bookmark added with custom title")
            tab.undoManager.beginUndoGrouping()
            if let bmID = addedBookmark?.id {
                store.removeBookmark(id: bmID, in: docID, undoManager: tab.undoManager)
            }
            tab.undoManager.endUndoGrouping()
            check(!store.isPageBookmarked(pageIndex: 0, in: docID), "bookmark removed")
            tab.undoManager.undo()
            let restoredBookmark = store.bookmarks(for: docID).first(where: { $0.pageIndex == 0 })
            check(restoredBookmark?.id == addedBookmark?.id && restoredBookmark?.title == "Custom Intro",
                  "undoing bookmark deletion restores exact ID and title")
            tab.undoManager.undo()
            check(!store.isPageBookmarked(pageIndex: 0, in: docID),
                  "second undo removes originally added bookmark")
            tab.undoManager.redo()
            check(store.isPageBookmarked(pageIndex: 0, in: docID),
                  "redo restores bookmark back")

            tab.undoManager.beginUndoGrouping()
            store.setBookmarks(pageIndices: [1, 2], bookmarked: true, in: docID, undoManager: tab.undoManager)
            tab.undoManager.endUndoGrouping()
            check(store.isPageBookmarked(pageIndex: 1, in: docID) && store.isPageBookmarked(pageIndex: 2, in: docID),
                  "batch setBookmarks adds bookmarks for all selected pages")
            tab.undoManager.undo()
            check(!store.isPageBookmarked(pageIndex: 1, in: docID) && !store.isPageBookmarked(pageIndex: 2, in: docID)
                  && store.isPageBookmarked(pageIndex: 0, in: docID),
                  "undoing batch bookmark preserves unrelated bookmarks")

            // 7. PageRangeParser parse & format (mixed numbers, fullwidth, printed numbers)
            let identityResolve: (String) -> Int? = { Int($0).map { $0 - 1 } }
            check(PageRangeParser.parse("1-3, 2, 5～6，8", pageCount: 10, resolvePage: identityResolve) == [0, 1, 2, 4, 5, 7],
                  "PageRangeParser handles ranges, deduplication, and Chinese/fullwidth punctuation")
            check(PageRangeParser.parse("3-1", pageCount: 10, resolvePage: identityResolve) == nil
                  && PageRangeParser.parse("1-15", pageCount: 10, resolvePage: identityResolve) == nil
                  && PageRangeParser.parse("abc", pageCount: 10, resolvePage: identityResolve) == nil
                  && PageRangeParser.parse("1, ", pageCount: 10, resolvePage: identityResolve) == nil,
                  "PageRangeParser rejects reversed, out-of-bounds, and trailing/empty segments")

            let mixedURL = try fixture("MixedNums", mixedNumbers: true)
            let mixedTab = store.openDocument(at: mixedURL, interactive: false)!
            let mixedDoc = mixedTab.pdfDocument
            // Printed numbers: index 5 == "1", index 6 == "2", index 7 == "3"; index 0 == "(1)"
            let mixedResolve: (String) -> Int? = { mixedTab.pageIndex(forPageInput: $0) }
            if mixedTab.pageIndex(forPageInput: "1") == nil {
                // Ensure synchronous printed-number index check works cleanly with fixture PDF PageLabels / position fallback
            }
            let posParsed = PageRangeParser.parse("(1), (3)-(5)", pageCount: mixedDoc.pageCount, resolvePage: mixedResolve)
            check(posParsed == [0, 2, 3, 4],
                  "PageRangeParser supports parenthesized PDF position ranges")
            let formatted = PageRangeParser.format([0, 1, 2, 4, 6, 7], pageCount: 10,
                                                   labelFor: { "\($0 + 1)" },
                                                   usesBookNumbers: false,
                                                   resolvePage: identityResolve)
            check(formatted == "1-3, 5, 7-8",
                  "PageRangeParser formats contiguous runs into compact ranges")

            // 8. Multi-page PDF export, URL-based export, PNG export, and filename formatting
            let p1 = tab.pdfDocument.page(at: 1)!
            let p3 = tab.pdfDocument.page(at: 3)!
            p1.rotation = 180
            p1.setBounds(CGRect(x: 10, y: 20, width: 480, height: 700), for: .cropBox)
            p3.rotation = 90
            p3.setBounds(CGRect(x: 30, y: 80, width: 500, height: 640), for: .cropBox)

            let multiPDF = try PageExporter.pdfData(for: [p3, p1])
            let multiDoc = PDFDocument(data: multiPDF)
            check(multiDoc?.pageCount == 2
                  && multiDoc?.page(at: 0)?.rotation == 90
                  && multiDoc?.page(at: 0)?.bounds(for: .cropBox) == CGRect(x: 30, y: 80, width: 500, height: 640)
                  && multiDoc?.page(at: 1)?.rotation == 180
                  && multiDoc?.page(at: 1)?.bounds(for: .cropBox) == CGRect(x: 10, y: 20, width: 480, height: 700),
                  "multi-page PDF export preserves page order, individual rotations, and crop boxes")

            let specPDF = try PageExporter.pdfData(
                from: alpha,
                password: nil,
                specs: [
                    .init(index: 2, cropBox: CGRect(x: 20, y: 30, width: 400, height: 500), rotation: 90),
                    .init(index: 2, cropBox: CGRect(x: 20, y: 30, width: 400, height: 500), rotation: 270),
                ]
            )
            let specDoc = PDFDocument(data: specPDF)
            check(specDoc?.pageCount == 2
                  && specDoc?.page(at: 0)?.rotation == 90
                  && specDoc?.page(at: 1)?.rotation == 270,
                  "URL-based multi-page PDF export handles duplicate page indices independently")

            let pngBytes = try await PageExporter.pngData(for: p3)
            let exportedPNG = NSBitmapImageRep(data: pngBytes)
            check(exportedPNG != nil && exportedPNG!.pixelsWide > exportedPNG!.pixelsHigh,
                  "single-page PNG export renders rotated page dimensions")

            // JPEG export, DPI scaling, and quality comparison
            let p3Snapshot = try PageImageClipboard.snapshot(of: p3)
            let png144 = try PageExporter.renderImageData(for: p3Snapshot, resolution: .dpi144, format: .png)
            let png300 = try PageExporter.renderImageData(for: p3Snapshot, resolution: .dpi300, format: .png)
            let rep144 = NSBitmapImageRep(data: png144)
            let rep300 = NSBitmapImageRep(data: png300)
            check(rep144 != nil && rep300 != nil && rep300!.pixelsWide > rep144!.pixelsWide && rep300!.pixelsHigh > rep144!.pixelsHigh,
                  "300 DPI image export produces higher pixel dimensions than 144 DPI")

            let jpgLow = try PageExporter.renderImageData(for: p3Snapshot, resolution: .dpi216, format: .jpeg, jpegQuality: 0.45)
            let jpgHigh = try PageExporter.renderImageData(for: p3Snapshot, resolution: .dpi216, format: .jpeg, jpegQuality: 0.95)
            let jpgRep = NSBitmapImageRep(data: jpgHigh)
            check(jpgHigh.starts(with: [0xFF, 0xD8, 0xFF])
                  && jpgRep != nil
                  && jpgRep!.pixelsWide > jpgRep!.pixelsHigh
                  && jpgHigh.count > jpgLow.count,
                  "JPEG export produces valid JPEG bytes scaled by quality")

            // Odd / Even / Current / Range resolution
            check(PageExporter.resolvePageIndices(mode: .all, rangeText: "", pageCount: 5, currentPageIndex: 2, resolvePage: identityResolve) == [0, 1, 2, 3, 4]
                  && PageExporter.resolvePageIndices(mode: .current, rangeText: "", pageCount: 5, currentPageIndex: 2, resolvePage: identityResolve) == [2]
                  && PageExporter.resolvePageIndices(mode: .odd, rangeText: "", pageCount: 5, currentPageIndex: 2, resolvePage: identityResolve) == [0, 2, 4]
                  && PageExporter.resolvePageIndices(mode: .even, rangeText: "", pageCount: 5, currentPageIndex: 2, resolvePage: identityResolve) == [1, 3]
                  && PageExporter.resolvePageIndices(mode: .even, rangeText: "", pageCount: 1, currentPageIndex: 0, resolvePage: identityResolve) == nil,
                  "resolvePageIndices supports all, current, odd, even, and single-page even edge cases")

            // Multi-page image folder export, unique folder numbering, and Finder tags
            let p0 = tab.pdfDocument.page(at: 0)!
            let p2 = tab.pdfDocument.page(at: 2)!
            let multiItems = [
                PageExporter.ImageExportItem(pageIndex: 0, label: "1", snapshot: try PageImageClipboard.snapshot(of: p0)),
                PageExporter.ImageExportItem(pageIndex: 2, label: "3", snapshot: try PageImageClipboard.snapshot(of: p2)),
                PageExporter.ImageExportItem(pageIndex: 3, label: "4", snapshot: try PageImageClipboard.snapshot(of: p3)),
            ]
            let imgDest = root.appendingPathComponent("BatchOut.jpg")
            let folder1 = try await PageExporter.writeMultiPageImages(
                items: multiItems,
                destinationURL: imgDest,
                resolution: .dpi144,
                format: .jpeg,
                jpegQuality: 0.85,
                totalPages: 4,
                tagNames: ["MathNotes"]
            )
            let folder2 = try await PageExporter.writeMultiPageImages(
                items: multiItems,
                destinationURL: imgDest,
                resolution: .dpi144,
                format: .jpeg,
                jpegQuality: 0.85,
                totalPages: 4,
                tagNames: []
            )
            let folder1Files = (try? FileManager.default.contentsOfDirectory(atPath: folder1.path).sorted()) ?? []
            let folder1Tags = (try? folder1.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            check(folder1.lastPathComponent == "BatchOut"
                  && folder2.lastPathComponent == "BatchOut 2"
                  && folder1Files == ["BatchOut - 01.jpg", "BatchOut - 03.jpg", "BatchOut - 04.jpg"]
                  && folder1Tags.contains("MathNotes"),
                  "multi-page image export creates non-colliding ordered folders and applies Finder tags")

            let previousLanguage = L10n.currentLanguage
            defer { L10n.currentLanguage = previousLanguage }
            L10n.currentLanguage = .en
            let safeName = PageExporter.suggestedFilename(documentTitle: "CS/101: Notes v1.2 ", format: .pdf)
            check(safeName == "CS-101- Notes v1.2 - Export.pdf",
                  "the default name retains the document title and has a distinct export suffix")
            check(PageExporter.filename("My Notes v1.2", for: .png) == "My Notes v1.2.png"
                  && PageExporter.filename("My Notes v1.2.PDF", for: .png) == "My Notes v1.2.png"
                  && PageExporter.filename("My Notes v1.2.png", for: .pdf) == "My Notes v1.2.pdf"
                  && PageExporter.filename("My Notes v1.2.png", for: .jpeg) == "My Notes v1.2.jpg"
                  && PageExporter.filename("My Notes v1.2.jpeg", for: .pdf) == "My Notes v1.2.pdf",
                  "switching output formats replaces only a known export extension")

            // 9. Localization checks across all 10 non-zhHans/en catalog languages + dynamic helpers
            let catalogKeys: [(String, String, Set<String>)] = [
                ("在分屏中查看此页", "Open Page in Split View", []),
                ("复制此页为图片", "Copy Page as Image", []),
                ("无法导出此页。", "This page could not be exported.", []),
                ("导出…", "Export…", []),
                ("导出", "Export", []),
                ("导出为：", "Export As:", []),
                ("格式：", "Format:", ["de"]),
                ("页面：", "Pages:", []),
                ("全部页面", "All Pages", []),
                ("当前页", "Current Page", []),
                ("奇数页", "Odd Pages", []),
                ("偶数页", "Even Pages", []),
                ("指定页码", "Page Range", []),
                ("清晰度：", "Resolution:", []),
                ("质量：", "Quality:", []),
                ("144 DPI（标准）", "144 DPI (Standard)", ["fr", "de", "it"]),
                ("216 DPI（高清）", "216 DPI (High)", []),
                ("300 DPI（打印）", "300 DPI (Print)", []),
                ("在 Finder 中显示", "Show in Finder", []),
                ("关闭", "Close", []),
                ("请输入有效的页码范围", "Enter a valid page range", []),
                ("请输入有效页码", "Enter a valid page number", []),
                ("取消选择", "Deselect All", []),
                ("撤销", "Undo", []),
                ("重做", "Redo", []),
                ("正在识别目录…", "Recognizing outline…", []),
                ("阅读", "Reading", []),
                ("自动识别目录", "Auto-Recognize Outline", []),
                ("文档缺少内嵌书签时自动生成目录", "Generate an outline when bookmarks are missing", []),
                ("识别目录", "Recognize Outline", []),
                ("打印…", "Print…", []),
                ("搜索文档…", "Filter documents…", []),
                ("按最近打开", "Recent", []),
                ("按名称", "Name", []),
                ("按页数", "Page Count", []),
                ("筛选目录…", "Filter outline…", []),
                ("没有匹配的章节", "No Matching Sections", []),
                ("文档信息…", "Document Info…", []),
                ("文档信息", "Document Info", []),
                ("元数据", "Metadata", []),
                ("文件与规格", "File & Specifications", []),
                ("标题", "Title", []),
                ("作者", "Author", []),
                ("主题", "Subject", []),
                ("关键词", "Keywords", []),
                ("创建工具", "Creator", []),
                ("PDF 生成器", "PDF Producer", []),
                ("页数", "Pages", []),
                ("PDF 版本", "PDF Version", []),
                ("页面尺寸", "Page Size", []),
                ("文件大小", "File Size", []),
                ("创建时间", "Created", []),
                ("修改时间", "Modified", []),
                ("安全性", "Security", []),
                ("位置", "Where", []),
                ("复制路径", "Copy Path", []),
                ("已复制", "Copied", []),
                ("密码保护（已解锁）", "Password Protected (Unlocked)", []),
                ("标准（无加密）", "Standard (Unencrypted)", []),
                ("文库", "Library", []),
                ("网格视图", "Grid View", []),
                ("列表视图", "List View", []),
                ("展开全部", "Expand All", []),
                ("折叠全部", "Collapse All", []),
            ]
            for lang in AppLanguage.allCases where lang != .system && lang != .zhHans && lang != .en {
                L10n.currentLanguage = lang
                for (zh, en, englishCognateLocales) in catalogKeys {
                    let translated = L10n.tr(zh, en)
                    let allowsEnglishSpelling = englishCognateLocales.contains(lang.rawValue)
                    check(!translated.isEmpty && (allowsEnglishSpelling || translated != en),
                          "localization '\(en)' present for \(lang.rawValue)")
                }
                check(L10n.selectedPagesCount(3).contains("3")
                      && L10n.exportSelectedPages(3).contains("3")
                      && L10n.exportPageCountSummary(3).contains("3")
                      && L10n.backToPage("5").contains("5")
                      && !L10n.exportImageSummary(count: 1, formatName: "PNG", pixelSize: CGSize(width: 800, height: 1000)).isEmpty
                      && L10n.exportImageSummary(count: 3, formatName: "JPEG", pixelSize: nil).contains("3")
                      && L10n.exportingProgressText(completed: 2, total: 5, formatName: "PNG").contains("2")
                      && L10n.exportCompletedText(pageCount: 5, formatName: "JPEG", isFolder: true).contains("5")
                      && !L10n.undoMenuTitle("Test").isEmpty
                      && !L10n.redoMenuTitle("Test").isEmpty,
                      "dynamic export/undo localization helpers formatted for \(lang.rawValue)")
            }
        }
        do {
            func indexedRow(_ text: String, x: Double, y: Double) -> RecognizedTextLine {
                let characters = text.enumerated().map { offset, character in
                    RecognizedTextCharacter(text: String(character), confidence: 0.99,
                        x: x + Double(offset) * 18, y: y, width: 17, height: 24)
                }
                return .init(text: text, confidence: 0.99, x: x, y: y,
                             width: Double(text.count) * 18, height: 24, characters: characters)
            }
            let ocr = OCRPageText(lines: [
                indexedRow("扫描页面中的关键术语", x: 40, y: 80),
                indexedRow("再次出现的关键术语在下方", x: 40, y: 180)
            ], vertical: false,
                                  imageSize: CGSize(width: 600, height: 800),
                                  cropBox: CGRect(x: 0, y: 0, width: 600, height: 800))
            let matches = IndexedPageText(ocr).matches("关键术语", pageIndex: 2)
            check(matches.count == 2 && matches[0].pageIndex == 2 && matches[1].pageIndex == 2
                  && !matches[0].bounds.isEmpty && !matches[1].bounds.isEmpty
                  && matches[0].bounds[0].minY > matches[1].bounds[0].minY,
                  "OCR text index preserves repeated matches on a page in reading order with geometry")

            let englishTocURL = root.appendingPathComponent("EnglishContents.pdf")
            var engBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let engContext = CGContext(englishTocURL as CFURL, mediaBox: &engBox, nil)!
            let engPages = [
                ["Table of Contents",
                 "Chapter 1 Foundations ...... 1",
                 "1.1 Core Ideas ...... 2",
                 "Exercises 1.1 ...... 3",
                 "Language Focus: Dealing with Unexpected Outcomes or “Problems” ...... 4",
                 "Appendix A Notes ...... 4"],
                ["Chapter 1 Foundations"], ["1.1 Core Ideas"], ["Exercises"], ["Language Focus\nAppendix A Notes"]
            ]
            for lines in engPages {
                engContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: engContext, flipped: false)
                for (offset, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 50, y: 720 - offset * 38),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
                }
                NSGraphicsContext.restoreGraphicsState()
                engContext.endPDFPage()
            }
            engContext.closePDF()
            let engToc = AutomaticOutlineGenerator.generate(document: PDFDocument(url: englishTocURL)!,
                pageLabels: ["1": [1], "2": [2], "3": [3], "4": [4]])
            check(engToc.map(\.title) == ["Table of Contents", "Chapter 1 Foundations", "1.1 Core Ideas",
                                          "Language Focus: Dealing with Unexpected Outcomes or “Problems”", "Appendix A Notes"]
                  && engToc.map(\.pageIndex) == [0, 1, 2, 4, 4]
                  && engToc.map(\.level) == [0, 0, 1, 1, 0],
                  "English contents include Contents header, keep quoted Problems titles, and exclude exercises")

            let ieeeURL = root.appendingPathComponent("IEEEPaper.pdf")
            var ieeeBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let ieeeContext = CGContext(ieeeURL as CFURL, mediaBox: &ieeeBox, nil)!
            let ieeePages: [[(String, CGFloat, CGFloat)]] = [
                [("Unit One", 60, 720), ("An Approach to Academic Writing", 60, 682), ("Body prose explaining the unit.", 60, 644)],
                [("I. INTRODUCTION", 60, 720), ("2.56 GHz carrier frequency", 60, 682),
                 ("II. RELATED WORK", 60, 210), ("III. TERAHERTZ DEVICE TECHNOLOGIES", 330, 260),
                 ("A. Hardware Building Blocks", 330, 120), ("R. Elschner, A. Katsiotis, et al.", 330, 80)],
                [("REFERENCES", 60, 720), ("A. Should Be Ignored In References", 60, 682), ("B. Another Reference Entry", 60, 644)]
            ]
            for items in ieeePages {
                ieeeContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ieeeContext, flipped: false)
                for item in items {
                    (item.0 as NSString).draw(at: CGPoint(x: item.1, y: item.2),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
                }
                NSGraphicsContext.restoreGraphicsState()
                ieeeContext.endPDFPage()
            }
            ieeeContext.closePDF()
            let ieeeGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: ieeeURL)!, pageLabels: [:])
            let iiEntry = ieeeGenerated.first(where: { $0.title == "II. RELATED WORK" })
            let iiiEntry = ieeeGenerated.first(where: { $0.title == "III. TERAHERTZ DEVICE TECHNOLOGIES" })
            check(Set(ieeeGenerated.map(\.title)) == Set([
                "Unit One: An Approach to Academic Writing",
                "I. INTRODUCTION",
                "II. RELATED WORK",
                "III. TERAHERTZ DEVICE TECHNOLOGIES",
                "A. Hardware Building Blocks",
                "REFERENCES"
            ]) && ieeeGenerated.count == 6
              && ieeeGenerated.allSatisfy { $0.destinationPoint != nil }
              && iiEntry?.pageIndex == 1 && iiiEntry?.pageIndex == 1
              && (iiEntry?.destinationPoint?.y ?? 0) < (iiiEntry?.destinationPoint?.y ?? 0),
                  "two-column IEEE headings preserve exact destination points even when right column is higher than left")

            let leaderlessURL = root.appendingPathComponent("LeaderlessContents.pdf")
            var leaderlessBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let leaderlessContext = CGContext(leaderlessURL as CFURL, mediaBox: &leaderlessBox, nil)!
            let leaderlessPages = [
                ["Contents",
                 "vii Introduction to the Edition",
                 "Preface viii",
                 "UNIT THREE: Problem, Process, and Solution 2",
                 "The Structure of Problem-Solution Texts 3",
                 "第 10 章 提纲挈领…………4"],
                ["UNIT THREE"], ["Problem-Solution Texts"], ["第 10 章 提纲挈领"]
            ]
            for lines in leaderlessPages {
                leaderlessContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: leaderlessContext, flipped: false)
                for (offset, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 60, y: 720 - offset * 38),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                }
                NSGraphicsContext.restoreGraphicsState()
                leaderlessContext.endPDFPage()
            }
            leaderlessContext.closePDF()
            let leaderlessGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: leaderlessURL)!, pageLabels: [:])
            check(leaderlessGenerated.map(\.title) == [
                "Contents",
                "UNIT THREE: Problem, Process, and Solution",
                "The Structure of Problem-Solution Texts",
                "第 10 章提纲挈领"
            ] && leaderlessGenerated.map(\.pageIndex) == [0, 1, 2, 3]
              && leaderlessGenerated.map(\.level) == [0, 0, 1, 0],
                  "leaderless explicit contents preserve Contents header, Problem titles and spaced CJK chapter numbers")

            let romanURL = root.appendingPathComponent("RomanFrontMatter.pdf")
            var romanBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let romanContext = CGContext(romanURL as CFURL, mediaBox: &romanBox, nil)!
            let romanPages = [
                ["Cover"],
                ["Contents", "Introduction vii", "Chapter 1 Basics 1"],
                ["iv CONTENTS"],
                ["CONTENTS v"],
                ["Introduction prose"],
                ["viii INTRODUCTION"],
                ["ix INTRODUCTION"],
                ["Body Page 1"]
            ]
            for lines in romanPages {
                romanContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: romanContext, flipped: false)
                for (offset, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 60, y: 720 - offset * 38),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                }
                NSGraphicsContext.restoreGraphicsState()
                romanContext.endPDFPage()
            }
            romanContext.closePDF()
            let romanGenerated = AutomaticOutlineGenerator.generate(
                document: PDFDocument(url: romanURL)!,
                pageLabels: ["1": [7]]
            )
            check(romanGenerated.map(\.title) == ["Contents", "Introduction", "Chapter 1 Basics"]
                  && romanGenerated.map(\.pageIndex) == [1, 4, 7]
                  && romanGenerated.map(\.level) == [0, 0, 0],
                  "Roman front-matter TOC entries map via nearest front-matter Roman anchor")

            let geomTocURL = root.appendingPathComponent("GeometricContents.pdf")
            var geomBox = CGRect(x: 0, y: 0, width: 500, height: 700)
            let geomContext = CGContext(geomTocURL as CFURL, mediaBox: &geomBox, nil)!
            let geomPages: [[(String, CGFloat, CGFloat, CGFloat)]] = [
                // Page 0: TOC page without dot leaders, right-aligned at x=420 (margin shift on next page)
                [
                    ("Imprint metadata", 36, 660, 7),
                    ("Contents", 60, 610, 22),
                    ("Part I Foundations", 60, 560, 11),
                    ("Background Ideas", 76, 535, 11),
                    ("Further Remarks on Large", 76, 510, 11),
                    ("Software Systems", 90, 494, 11),
                    ("Part II Applications", 60, 462, 11),
                    ("Case Study", 76, 437, 11)
                ],
                // Body pages starting at PDF page index 1 == printed page 1
                [("Part I Foundations", 60, 620, 18), ("Opening prose.", 60, 580, 11)],
                [("Background Ideas", 60, 620, 14)],
                [("Further Remarks", 60, 620, 14)],
                [("Part II Applications", 60, 620, 18)],
                [("Case Study", 60, 620, 14)]
            ]
            for (pIdx, items) in geomPages.enumerated() {
                geomContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: geomContext, flipped: false)
                if pIdx == 0 {
                    // Draw TOC entries with right-aligned page numbers at x ≈ 420
                    let rightNumbers: [Int: String] = [2: "1", 3: "2", 4: "3", 6: "4", 7: "5"]
                    for (idx, item) in items.enumerated() {
                        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: item.3)]
                        (item.0 as NSString).draw(at: CGPoint(x: item.1, y: item.2), withAttributes: attrs)
                        if let num = rightNumbers[idx] {
                            let numWidth = (num as NSString).size(withAttributes: attrs).width
                            (num as NSString).draw(at: CGPoint(x: 420 - numWidth, y: item.2), withAttributes: attrs)
                        }
                    }
                } else {
                    for item in items {
                        (item.0 as NSString).draw(at: CGPoint(x: item.1, y: item.2),
                            withAttributes: [.font: NSFont.systemFont(ofSize: item.3)])
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                geomContext.endPDFPage()
            }
            geomContext.closePDF()
            let geomGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: geomTocURL)!, pageLabels: [:])
            check(geomGenerated.map(\.title) == [
                "Contents",
                "Part I Foundations",
                "Background Ideas",
                "Further Remarks on Large Software Systems",
                "Part II Applications",
                "Case Study"
            ] && geomGenerated.map(\.pageIndex) == [0, 1, 2, 3, 4, 5]
              && geomGenerated.map(\.level) == [0, 0, 1, 1, 0, 1],
                  "leaderless TOC recovers hierarchy and wrapped titles purely from 2D PDF geometry")

            // 2D vertical-column TOC with left-first spread order (oddIndexShift = 2):
            // PDF index 2 (logical 2) is the right TOC page; PDF index 1 (logical 3) is the left continuation page.
            let vtocURL = root.appendingPathComponent("VerticalColumnTOC.pdf")
            var vtocBox = CGRect(x: 0, y: 0, width: 600, height: 900)
            let vtocContext = CGContext(vtocURL as CFURL, mediaBox: &vtocBox, nil)!
            let vtocPages: [[(String, CGFloat, CGFloat)]] = [
                [("Cover", 60, 700)],
                // PDF index 1 (logical 3, left TOC continuation page)
                [("第三章", 460, 740), ("性與奴隸", 460, 620), ("94", 460, 100),
                 ("第四章", 340, 720), ("好奴隸是怎樣煉成的？", 340, 600), ("106", 340, 110),
                 ("結語", 220, 700), ("再會！", 220, 630), ("250", 220, 102),
                 ("深入閱讀", 100, 680), ("252", 100, 112)],
                // PDF index 2 (logical 2, right TOC opening page)
                [("目錄", 500, 480),
                 ("推薦序", 400, 740), ("翁嘉聲", 400, 640), ("6", 400, 100),
                 ("序文", 300, 750), ("我是主人", 300, 630), ("18", 300, 112),
                 ("第一章", 200, 720), ("如何購買奴隸", 200, 600), ("34", 200, 110),
                 ("第二章", 100, 700), ("如何使奴隸鞠躬盡瘁", 100, 580), ("60", 100, 102)]
            ]
            for pageIndex in 0..<260 {
                vtocContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: vtocContext, flipped: false)
                let vtocAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
                if pageIndex < vtocPages.count {
                    for item in vtocPages[pageIndex] {
                        let w = (item.0 as NSString).size(withAttributes: vtocAttrs).width
                        (item.0 as NSString).draw(at: CGPoint(x: item.1 - w / 2, y: item.2),
                            withAttributes: vtocAttrs)
                    }
                } else {
                    ("Page \(pageIndex + 1)" as NSString).draw(at: CGPoint(x: 60, y: 700),
                        withAttributes: vtocAttrs)
                }
                NSGraphicsContext.restoreGraphicsState()
                vtocContext.endPDFPage()
            }
            vtocContext.closePDF()
            let vtocGenerated = AutomaticOutlineGenerator.generate(
                document: PDFDocument(url: vtocURL)!,
                pageLabels: ["6": [10], "18": [22], "34": [38], "60": [64], "94": [98], "106": [110], "250": [254], "252": [256]],
                oddIndexShift: 2
            )
            check(vtocGenerated.first?.title == "目錄" && vtocGenerated.first?.pageIndex == 2
                  && vtocGenerated.contains(where: { $0.title == "推薦序 翁嘉聲" && $0.pageIndex == 10 })
                  && vtocGenerated.contains(where: { $0.title == "第一章 如何購買奴隸" && $0.pageIndex == 38 })
                  && vtocGenerated.contains(where: { $0.title == "結語 再會！" && $0.pageIndex == 254 && $0.level == 0 })
                  && vtocGenerated.contains(where: { $0.title == "深入閱讀" && $0.pageIndex == 256 && $0.level == 0 }),
                  "2D vertical-column TOC resolves right-bound spreads and preserves back-matter level 0")

            // Repeated running headers across pages (including Simplified/Traditional variants) must not duplicate chapters.
            let repeatHeaderURL = root.appendingPathComponent("RepeatedRunningHeaders.pdf")
            var rhBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let rhContext = CGContext(repeatHeaderURL as CFURL, mediaBox: &rhBox, nil)!
            let rhPages: [[(String, CGFloat, CGFloat)]] = [
                [("第一章 如何買奴隸", 60, 760), ("這裡是第一章第一頁正文内容，說明如何購買奴隸。", 60, 680)],
                [("第一章 如何買奴隸", 60, 760), ("這裡是第一章第二頁正文內容，繼續補充說明細節。", 60, 680)],
                [("第二章 如何使奴隸鞠躬盡瘁", 60, 760), ("這裡是第二章第一頁正文內容，說明訓練與管理方式。", 60, 680)],
                [("第二章 如何使奴隶鞠躬尽瘁", 60, 760), ("這裡是第二章第二頁正文內容，簡繁異體不應產生重複大綱。", 60, 680)]
            ]
            for items in rhPages {
                rhContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: rhContext, flipped: false)
                for item in items {
                    (item.0 as NSString).draw(at: CGPoint(x: item.1, y: item.2),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 15)])
                }
                NSGraphicsContext.restoreGraphicsState()
                rhContext.endPDFPage()
            }
            rhContext.closePDF()
            let rhGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: repeatHeaderURL)!, pageLabels: [:])
            check(rhGenerated.isEmpty, "repeated top-margin running headers (including script variants) never produce duplicate outline rows")

            let outlineURL = root.appendingPathComponent("GeneratedOutline.pdf")
            var outlineBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let outlineContext = CGContext(outlineURL as CFURL, mediaBox: &outlineBox, nil)!
            for heading in ["第一章 基础", "1.1 核心概念", "第二章 应用"] {
                outlineContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: outlineContext, flipped: false)
                (heading as NSString).draw(at: CGPoint(x: 60, y: 700),
                                           withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
                ("正文内容用于自动目录回归测试。" as NSString).draw(at: CGPoint(x: 60, y: 650),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
                NSGraphicsContext.restoreGraphicsState()
                outlineContext.endPDFPage()
            }
            outlineContext.closePDF()
            let generated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: outlineURL)!,
                                                                pageLabels: ["1": [0], "2": [1], "3": [2]])
            check(generated.map(\.pageIndex) == [0, 1, 2]
                  && generated.map(\.level) == [0, 1, 0],
                  "documents without embedded bookmarks derive a hierarchical outline from headings")

            let tocURL = root.appendingPathComponent("OCRStyleContents.pdf")
            outlineBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let tocContext = CGContext(tocURL as CFURL, mediaBox: &outlineBox, nil)!
            let tocPages = [
                ["目录", "高等数学(第三版)(上册)",
                 "第一章函数与极限…………(1)§1 实数…………(2)",
                 "1. 有理数与无理数…………(3)", "习题1.1…………(4)",
                 "第一章总练习题第二章微积分基础…………(10)",
                 "§2 连续函数", "1. 连续性的定义…………(11)"],
                ["扉页"], ["第一章函数与极限"], ["§1 实数"], ["1. 有理数与无理数"]
            ]
            for lines in tocPages {
                tocContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: tocContext, flipped: false)
                for (offset, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 60, y: 720 - offset * 38),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 17)])
                }
                NSGraphicsContext.restoreGraphicsState()
                tocContext.endPDFPage()
            }
            tocContext.closePDF()
            let toc = AutomaticOutlineGenerator.generate(document: PDFDocument(url: tocURL)!,
                pageLabels: ["1": [2], "2": [3], "3": [4], "4": [4], "10": [4], "11": [4]])
            check(toc.map(\.title) == ["目录", "第一章函数与极限", "§1 实数", "1. 有理数与无理数",
                                       "第二章微积分基础", "§2 连续函数", "1. 连续性的定义"]
                  && toc.map(\.pageIndex) == [0, 2, 3, 4, 4, 4, 4]
                  && toc.map(\.level) == [0, 0, 1, 2, 0, 1, 2],
                  "OCR-style contents split joined rows, discard noise, and use corrected page labels")

            // 1. LaTeX spaced dot-leader TOC (`1.1 Section . . . . . 4`)
            let spacedLeaderURL = root.appendingPathComponent("SpacedLeaderTOC.pdf")
            var slBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let slContext = CGContext(spacedLeaderURL as CFURL, mediaBox: &slBox, nil)!
            let slPages = [
                ["Contents",
                 "1 Graph Theory . . . . . . . . . . . . . . . 2",
                 "1.1 Topological Sort . . . . . . . . . . . . . 3",
                 "2 Dynamic Programming . . . . . . . . . . . . 4"],
                ["Graph Theory"],
                ["Topological Sort"],
                ["Dynamic Programming"]
            ]
            for lines in slPages {
                slContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: slContext, flipped: false)
                for (offset, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 60, y: 720 - offset * 32),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
                }
                NSGraphicsContext.restoreGraphicsState()
                slContext.endPDFPage()
            }
            slContext.closePDF()
            let slGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: spacedLeaderURL)!, pageLabels: [:])
            check(slGenerated.map(\.title) == ["Contents", "1 Graph Theory", "1.1 Topological Sort", "2 Dynamic Programming"]
                  && slGenerated.map(\.pageIndex) == [0, 1, 2, 3]
                  && slGenerated.map(\.level) == [0, 0, 1, 0],
                  "LaTeX spaced dot-leader TOC preserves parent chapters and nested subsections")

            // 2. Late appendix TOC on page 15 of a 20-page document must not hijack main body headings
            let lateTOCURL = root.appendingPathComponent("LateAppendixTOC.pdf")
            var lateBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let lateContext = CGContext(lateTOCURL as CFURL, mediaBox: &lateBox, nil)!
            for pIdx in 0..<20 {
                lateContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: lateContext, flipped: false)
                let bodyFont = NSFont.systemFont(ofSize: 10.5)
                let headingFont = NSFont.boldSystemFont(ofSize: 14)
                if pIdx == 0 {
                    ("1. Introduction" as NSString).draw(at: CGPoint(x: 60, y: 720), withAttributes: [.font: headingFont])
                    ("Main body starts here." as NSString).draw(at: CGPoint(x: 60, y: 690), withAttributes: [.font: bodyFont])
                } else if pIdx == 3 {
                    ("2. Method" as NSString).draw(at: CGPoint(x: 60, y: 720), withAttributes: [.font: headingFont])
                    ("Details of the method." as NSString).draw(at: CGPoint(x: 60, y: 690), withAttributes: [.font: bodyFont])
                } else if pIdx == 7 {
                    ("3. Results" as NSString).draw(at: CGPoint(x: 60, y: 720), withAttributes: [.font: headingFont])
                    ("Experimental evaluation." as NSString).draw(at: CGPoint(x: 60, y: 690), withAttributes: [.font: bodyFont])
                } else if pIdx == 15 {
                    ("Table of Contents" as NSString).draw(at: CGPoint(x: 60, y: 720), withAttributes: [.font: headingFont])
                    ("Appendix A Extra Details 17" as NSString).draw(at: CGPoint(x: 60, y: 685), withAttributes: [.font: bodyFont])
                    ("Appendix B Additional Proofs 19" as NSString).draw(at: CGPoint(x: 60, y: 660), withAttributes: [.font: bodyFont])
                } else {
                    ("Standard body prose paragraph on page \(pIdx + 1)." as NSString).draw(at: CGPoint(x: 60, y: 690), withAttributes: [.font: bodyFont])
                }
                NSGraphicsContext.restoreGraphicsState()
                lateContext.endPDFPage()
            }
            lateContext.closePDF()
            let lateGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: lateTOCURL)!, pageLabels: [:])
            check(lateGenerated.map(\.title) == ["1. Introduction", "2. Method", "3. Results"]
                  && lateGenerated.map(\.pageIndex) == [0, 3, 7],
                  "late appendix TOC in the second half does not suppress main document headings")

            // 3. Unnumbered typographic paper fallback + prose/caption/step rejection
            let typoURL = root.appendingPathComponent("TypographicPaper.pdf")
            var typoBox = CGRect(x: 0, y: 0, width: 600, height: 800)
            let typoContext = CGContext(typoURL as CFURL, mediaBox: &typoBox, nil)!
            let typoPages: [[(String, CGFloat, CGFloat)]] = [
                [
                    ("Repeated Journal Masthead", 740, 11.0),
                    ("Theoretical Framework", 690, 11.0),
                    ("This opening sentence introduces the methodology and references", 660, 10.0),
                    ("section C.4). For each direction, we validate robustness here.", 645, 10.0),
                    ("Empirical evidence demonstrates consistent performance gains across benchmarks.", 630, 10.0),
                    ("Research Site and Participants", 605, 10.5),
                    ("1. Collect the primary dataset across every experimental fold and validate;", 580, 10.0)
                ],
                [
                    ("Repeated Journal Masthead", 740, 11.0),
                    ("Materials and Methods", 690, 11.0),
                    ("Fig. 1 Overview of experimental workflow", 660, 11.0),
                    ("Detailed experimental configuration and validation narrative spans", 635, 10.0),
                    ("multiple longitudinal observations recorded throughout the study period.", 620, 10.0),
                    ("Data Collection Procedures", 595, 10.5),
                    ("Additional prose explaining data collection across sites.", 570, 10.0)
                ],
                [
                    ("Repeated Journal Masthead", 740, 11.0),
                    ("Results and Analysis", 690, 11.0),
                    ("Key findings observed during benchmark trials indicate substantial", 660, 10.0),
                    ("improvements over prior baselines under identical evaluation criteria.", 645, 10.0),
                    ("Primary Experimental Findings", 620, 10.5),
                    ("More body text continuing the results section cleanly.", 595, 10.0)
                ],
                [
                    ("Repeated Journal Masthead", 740, 11.0),
                    ("Discussion", 690, 11.0),
                    ("Final body text discussing broader implications and future work.", 660, 10.0),
                    ("These results establish a clear foundation for subsequent studies.", 645, 10.0)
                ]
            ]
            for items in typoPages {
                typoContext.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: typoContext, flipped: false)
                for item in items {
                    (item.0 as NSString).draw(at: CGPoint(x: 60, y: item.1),
                        withAttributes: [.font: NSFont.systemFont(ofSize: item.2)])
                }
                NSGraphicsContext.restoreGraphicsState()
                typoContext.endPDFPage()
            }
            typoContext.closePDF()
            let typoGenerated = AutomaticOutlineGenerator.generate(document: PDFDocument(url: typoURL)!, pageLabels: [:])
            check(typoGenerated.map(\.title) == [
                "Theoretical Framework",
                "Research Site and Participants",
                "Materials and Methods",
                "Data Collection Procedures",
                "Results and Analysis",
                "Primary Experimental Findings",
                "Discussion"
            ] && typoGenerated.map(\.level) == [0, 1, 0, 1, 0, 1, 0],
                  "typographic fallback recovers hierarchical unnumbered headings and rejects prose wraps, captions and steps")

            // 4. Auto-recognize outline setting defaults on and persists across stores
            let autoOutlineKey = "expertPDFReader.autoGenerateOutline"
            let savedAutoOutline = UserDefaults.standard.object(forKey: autoOutlineKey)
            defer {
                if let savedAutoOutline {
                    UserDefaults.standard.set(savedAutoOutline, forKey: autoOutlineKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: autoOutlineKey)
                }
            }
            UserDefaults.standard.removeObject(forKey: autoOutlineKey)
            let defaultStore = freshStore()
            check(defaultStore.autoGenerateOutline == true,
                  "autoGenerateOutline defaults to true when unset")
            defaultStore.autoGenerateOutline = false
            let reloadedOffStore = AppStore()
            check(reloadedOffStore.autoGenerateOutline == false,
                  "autoGenerateOutline=false persists via UserDefaults")
            reloadedOffStore.autoGenerateOutline = true
            let reloadedOnStore = AppStore()
            check(reloadedOnStore.autoGenerateOutline == true,
                  "autoGenerateOutline=true persists via UserDefaults")

            // 5. Native printing readiness & Home Recents/Favorites compact date and reading progress badge
            let homePrintStore = freshStore()
            let printTab = homePrintStore.openDocument(at: outlineURL, interactive: false)!
            check(printTab.canPrintActiveDocument,
                  "normal loaded PDF reports canPrintActiveDocument == true")
            if let printOp = printTab.makePrintOperation() {
                check(printOp.printInfo.horizontalPagination == .fit
                      && printOp.printInfo.verticalPagination == .fit
                      && printOp.jobTitle == printTab.title,
                      "makePrintOperation configures fit pagination and document job title")
            } else {
                check(false, "makePrintOperation returns non-nil NSPrintOperation for printable PDF")
            }

            let outlineDocID = printTab.documentID
            let recentDocItem = homePrintStore.documents.first(where: { $0.documentID == outlineDocID })
            check(recentDocItem?.dateOpenedText.contains(":") == false,
                  "dateOpenedText uses compact relative date without time-of-day truncation")

            printTab.currentPageIndex = 1
            let progressPageCount = printTab.pageCount
            homePrintStore.closeTab(id: printTab.id)
            if let docItemForProgress = homePrintStore.documents.first(where: { $0.documentID == outlineDocID }) {
                check(homePrintStore.savedReadingPageLabel(for: docItemForProgress) == "2 / \(progressPageCount)",
                      "savedReadingPageLabel formats active reading progress cleanly")
                if let inProgress = homePrintStore.inProgressReadingState(for: docItemForProgress) {
                    check(inProgress.label == "2 / \(progressPageCount)" && abs(inProgress.fraction - (2.0 / Double(progressPageCount))) < 0.001,
                          "inProgressReadingState returns label and fraction only when mid-document")
                } else {
                    check(false, "inProgressReadingState returns value when stopped mid-document")
                }
            } else {
                check(false, "document item available to check savedReadingPageLabel")
            }
            if let reopenEnd = homePrintStore.openDocument(at: outlineURL, interactive: false) {
                reopenEnd.currentPageIndex = progressPageCount - 1
                homePrintStore.closeTab(id: reopenEnd.id)
                if let finishedDoc = homePrintStore.documents.first(where: { $0.documentID == outlineDocID }) {
                    check(homePrintStore.inProgressReadingState(for: finishedDoc) == nil,
                          "inProgressReadingState hides overlay badge when finished on the last page")
                }
            }

            // 6. Outline filtering helper, internal link jump-back history, DocumentMetadataSnapshot, and page rotation persistence
            let childSection = PDFOutlineNode(title: "1.2 Methodology", pageIndex: 4, point: nil, children: [])
            let parentChapter = PDFOutlineNode(title: "1 Introduction", pageIndex: 1, point: nil, children: [childSection])
            let appendixChapter = PDFOutlineNode(title: "Appendix A", pageIndex: 12, point: nil, children: [])
            let sampleNodes = [parentChapter, appendixChapter]
            let filteredByChild = PDFOutlinePanel.filteredRows(
                nodes: sampleNodes,
                query: "method",
                expandedIDs: [],
                pageLabel: { "\($0 + 1)" }
            )
            check(filteredByChild.map(\.node.id) == [parentChapter.id, childSection.id]
                  && filteredByChild.map(\.level) == [0, 1],
                  "outline filter reveals collapsed parent chapters containing matching subsections")
            let filteredByPage = PDFOutlinePanel.filteredRows(
                nodes: sampleNodes,
                query: "13",
                expandedIDs: [],
                pageLabel: { "\($0 + 1)" }
            )
            check(filteredByPage.map(\.node.id) == [appendixChapter.id],
                  "outline filter matches display page numbers")
            check(PDFOutlinePanel.filteredRows(nodes: sampleNodes, query: "nonexistent", expandedIDs: [], pageLabel: { "\($0 + 1)" }).isEmpty,
                  "outline filter returns empty array when no sections match")

            let navURL = try fixture("NavHistory", mixedNumbers: true)
            let navStore = freshStore()
            let navTab = navStore.openDocument(at: navURL, interactive: false)!
            navTab.undoManager.groupsByEvent = false
            navTab.stepPage(by: 1)
            check(navTab.canGoBack && navTab.jumpBackDestination == nil,
                  "sequential page step records history without popping up the jump-back pill")
            navTab.navigateToPage(3)
            check(navTab.jumpBackDestination?.pageIndex == 1 && navTab.jumpBackDestination?.point == nil,
                  "multi-page direct jump surfaces the jump-back banner for the origin page")
            let originSpot = DocumentTabState.ReadingSpot(pageIndex: 2, point: CGPoint(x: 90, y: 540))
            let tokenBeforeLink = navTab.jumpBackToken
            navTab.recordInternalLinkJump(from: originSpot, to: 5)
            check(navTab.currentPageIndex == 5
                  && navTab.jumpBackDestination?.pageIndex == 2
                  && navTab.jumpBackDestination?.point == CGPoint(x: 90, y: 540)
                  && navTab.jumpBackToken == tokenBeforeLink + 1,
                  "internal link jump records exact pre-jump reading spot and triggers jump-back banner")
            navTab.goBack()
            check(navTab.currentPageIndex == 2
                  && navTab.pageJumpPoint == CGPoint(x: 90, y: 540)
                  && navTab.jumpBackDestination == nil
                  && navTab.canGoForward,
                  "going back after an internal link click restores exact page coordinates and clears jump-back pill")
            navTab.goForward()
            check(navTab.currentPageIndex == 5 && navTab.canGoBack,
                  "going forward after returning restores the link destination page")

            let metaURL = try fixture("InspectorMetadata")
            if let metaDoc = PDFDocument(url: metaURL) {
                metaDoc.documentAttributes = [
                    PDFDocumentAttribute.titleAttribute: "Spec Sheet",
                    PDFDocumentAttribute.authorAttribute: "Ada Lovelace",
                    PDFDocumentAttribute.keywordsAttribute: ["PDF", "macOS"]
                ]
                if let page0 = metaDoc.page(at: 0) {
                    let a4Rect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
                    page0.setBounds(a4Rect, for: .mediaBox)
                    page0.setBounds(a4Rect, for: .cropBox)
                }
                let snap = DocumentMetadataSnapshot.extract(from: metaDoc, url: metaURL, pageIndex: 0)
                check(snap.displayTitle == "Spec Sheet"
                      && snap.author == "Ada Lovelace"
                      && snap.keywords == "PDF, macOS"
                      && snap.hasMetadata
                      && snap.pageSizeText == "210 × 297 mm (A4)",
                      "DocumentMetadataSnapshot extracts document attributes and detects A4 paper size")
            } else {
                check(false, "created PDF document loads for metadata snapshot inspection")
            }

            let rotURL = try fixture("RotationPersistence")
            let rotStore = freshStore()
            let rotTab = rotStore.openDocument(at: rotURL, interactive: false)!
            rotTab.undoManager.groupsByEvent = false
            rotTab.undoManager.beginUndoGrouping()
            rotTab.rotatePage(at: 1, clockwise: true)
            rotTab.undoManager.endUndoGrouping()
            rotTab.undoManager.beginUndoGrouping()
            rotTab.rotatePage(at: 2, clockwise: false)
            rotTab.undoManager.endUndoGrouping()
            check(rotTab.customPageRotations == [1: 90, 2: 270],
                  "rotating pages tracks normalized custom page rotations")
            rotStore.closeTab(id: rotTab.id)

            let reloadedRotStore = AppStore()
            if let reopenedRot = reloadedRotStore.openDocument(at: rotURL, interactive: false) {
                check(reopenedRot.pdfDocument.page(at: 1)?.rotation == 90
                      && reopenedRot.pdfDocument.page(at: 2)?.rotation == 270
                      && reopenedRot.customPageRotations == [1: 90, 2: 270],
                      "saved page rotations persist across AppStore reloads")
                reopenedRot.undoManager.groupsByEvent = false
                reopenedRot.undoManager.beginUndoGrouping()
                reopenedRot.rotatePage(at: 1, clockwise: false)
                reopenedRot.undoManager.endUndoGrouping()
                check(reopenedRot.customPageRotations[1] == nil && reopenedRot.customPageRotations[2] == 270,
                      "rotating a page back to original angle removes its custom rotation override")
                reloadedRotStore.closeTab(id: reopenedRot.id)

                let renamedRotURL = root.appendingPathComponent("RotationRenamed.pdf")
                try FileManager.default.moveItem(at: rotURL, to: renamedRotURL)
                reloadedRotStore.pruneMissingDocuments()
                if let afterRename = reloadedRotStore.openDocument(at: renamedRotURL, interactive: false) {
                    check(afterRename.pdfDocument.page(at: 2)?.rotation == 270
                          && afterRename.pdfDocument.page(at: 1)?.rotation == 0,
                          "saved page rotations follow Finder file renames")
                } else {
                    check(false, "reopening renamed PDF preserves rotation state")
                }
            } else {
                check(false, "reopening rotated PDF restores saved page rotations")
            }
        }
        if !failures.isEmpty {
            print("\(failures.count) regression checks failed")
            exit(1)
        }
        print("All regression checks passed")
    }
}
