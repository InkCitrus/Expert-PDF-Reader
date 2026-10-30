import AppKit
import Combine
import Foundation
import PDFKit

@main
struct ReaderRegressionTests {
    @MainActor static func main() throws {
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
              && PDFSelectionVisibility.hasOverlappingText(coveredSelection,on:coveredPage),
              "covered PDF text is recognized as overlapping layers rather than copied as visible prose")

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
        check(numbers?.label(at: 1) == "i" && numbers?.label(at: 4) == "iv"
              && numbers?.label(at: 5) == "1" && numbers?.label(at: 23) == "19"
              && numbers?.label(at: 0) == nil && numbers?.label(at: 24) == nil,
              "mixed Roman and Arabic page numbers preserve unnumbered covers")
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
