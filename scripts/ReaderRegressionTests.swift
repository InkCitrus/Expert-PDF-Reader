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
        let mixed = PDFDocument(url: try fixture("MixedNumbers", mixedNumbers: true))!
        let numbers = BookPageScanner.scan(mixed).printedNumbers
        check(numbers?.label(at: 1) == "i" && numbers?.label(at: 4) == "iv"
              && numbers?.label(at: 5) == "1" && numbers?.label(at: 23) == "19"
              && numbers?.label(at: 0) == nil && numbers?.label(at: 24) == nil,
              "mixed Roman and Arabic page numbers preserve unnumbered covers")
        if !failures.isEmpty {
            print("\(failures.count) regression checks failed")
            exit(1)
        }
        print("All regression checks passed")
    }
}
