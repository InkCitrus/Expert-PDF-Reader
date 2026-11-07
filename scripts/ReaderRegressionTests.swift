import AppKit
import Combine
import Foundation
import PDFKit

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
        if !failures.isEmpty {
            print("\(failures.count) regression checks failed")
            exit(1)
        }
        print("All regression checks passed")
    }
}
