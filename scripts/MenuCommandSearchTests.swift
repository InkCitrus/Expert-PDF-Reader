import AppKit

// This focused AppKit harness does not load application preferences or reader documents.
enum L10n { static func tr(_ chinese: String, _ english: String) -> String { english } }

@main struct MenuCommandSearchTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MenuSearchQA()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class MenuSearchQA: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var failures = 0
    private var checks = 0
    private var actions = 0
    private var savedClipboard: [NSPasteboardItem] = []
    private var window: NSWindow!
    private var text: NSTextView!
    private let edit = NSMenu(title: "Edit")
    private let lazyMenu = NSMenu(title: "Tools")
    private var disabled: NSMenuItem!
    private let marker = "Original document selection — not the search query."

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Menu Search QA"
        text = NSTextView(frame: NSRect(x: 20, y: 20, width: 650, height: 450))
        text.string = marker
        window.contentView?.addSubview(text)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: (marker as NSString).length))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        edit.autoenablesItems = true
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(command("Recognize and Copy Page Text"))
        disabled = command("Disabled Command")
        disabled.isEnabled = false
        edit.addItem(disabled)
        let hidden = command("Hidden Command")
        hidden.isHidden = true
        edit.addItem(hidden)
        let alternate = command("Alternate Command")
        alternate.isAlternate = true
        edit.addItem(alternate)
        let view = NSMenu(title: "View")
        view.autoenablesItems = false
        view.addItem(command("Zoom In"))
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        menu.addItem(viewItem)
        let toolsItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        toolsItem.submenu = lazyMenu
        lazyMenu.delegate = self
        menu.addItem(toolsItem)
        let services = NSMenu(title: "Services")
        services.addItem(command("External Service Command"))
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.mainMenu = menu
        NSApp.servicesMenu = services
        NSApp.helpMenu = NSMenu()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await runChecks()
        }
    }

    private func command(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(record(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func record(_ sender: Any?) { actions += 1 }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item !== disabled }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === lazyMenu, menu.items.isEmpty { menu.addItem(command("Delayed Command")) }
    }

    private func check(_ passed: Bool, _ message: String) {
        checks += 1
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(message)")
    }

    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }

    private func openSearch() async -> (NSPanel, NSSearchField, NSTableView) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        try? await Task.sleep(nanoseconds: 150_000_000)
        MenuCommandSearch.shared.show()
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.contentView.map { !descendants($0, NSSearchField.self).isEmpty } == true }) as? NSPanel,
              let content = panel.contentView,
              let field = descendants(content, NSSearchField.self).first,
              let table = descendants(content, NSTableView.self).first else {
            print("FAIL no search panel; windows: \(NSApp.windows.map { (String(describing: type(of: $0)), $0.isVisible, $0.isKeyWindow) })")
            check(false, "search panel could not be opened")
            finish()
        }
        return (panel, field, table)
    }

    private func query(_ string: String, field: NSSearchField) {
        field.stringValue = string
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func key(_ code: UInt16, _ characters: String, in panel: NSPanel) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        panel.sendEvent(event)
    }

    private func runChecks() async {
        let board = NSPasteboard.general
        savedClipboard = (board.pasteboardItems ?? []).map { original -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let (panel, field, table) = await openSearch()
        check(panel.isKeyWindow && field.currentEditor() != nil, "search opens with keyboard focus")
        edit.update()
        query("COPY", field: field)
        check(table.numberOfRows == 2, "case-insensitive copy query finds only two app commands")
        key(125, "\u{f701}", in: panel)
        check(panel.isVisible && table.selectedRow == 1, "Down selects next result without closing search")
        key(126, "\u{f700}", in: panel)
        check(table.selectedRow == 0, "Up selects previous result")
        key(36, "\r", in: panel)
        check(!panel.isVisible && window.isKeyWindow && window.firstResponder === text, "Return restores original window and responder")
        check(board.string(forType: .string) == marker, "Copy dispatches to document selection rather than search text")

        let (_, blank, blankTable) = await openSearch()
        key(36, "\r", in: panel)
        check(blankTable.numberOfRows == 0 && panel.isVisible && actions == 0, "blank Return executes nothing")
        query("no_such_command", field: blank)
        key(36, "\r", in: panel)
        check(blankTable.numberOfRows == 0 && panel.isVisible, "unmatched query executes nothing")
        key(53, "\u{1b}", in: panel)
        check(!panel.isVisible && window.isKeyWindow, "Escape closes search and returns to document")

        let (_, disabledField, disabledTable) = await openSearch()
        query("Disabled", field: disabledField)
        key(36, "\r", in: panel)
        check(disabledTable.numberOfRows == 1 && actions == 0 && panel.isVisible, "disabled command is searchable but cannot execute")
        key(53, "\u{1b}", in: panel)

        let (_, nestedField, nestedTable) = await openSearch()
        query("view zoom", field: nestedField)
        check(nestedTable.numberOfRows == 1, "query can match both menu path and command title")
        panel.makeFirstResponder(nestedTable)
        key(36, "\r", in: panel)
        check(actions == 1 && !panel.isVisible && window.firstResponder === text, "Return from result table executes once in original context")

        let (_, hiddenField, hiddenTable) = await openSearch()
        for term in ["Hidden", "Alternate", "External Service"] {
            query(term, field: hiddenField)
            check(hiddenTable.numberOfRows == 0, "excludes \(term) commands")
        }
        panel.makeFirstResponder(hiddenTable)
        key(53, "\u{1b}", in: panel)
        check(!panel.isVisible, "Escape also works with table focus")

        edit.addItem(command("Fresh Command"))
        let (_, freshField, freshTable) = await openSearch()
        query("Fresh", field: freshField)
        check(freshTable.numberOfRows == 1, "reopening reads newly available menu commands")
        query("Delayed", field: freshField)
        check(freshTable.numberOfRows == 1, "commands generated lazily by menu delegates are included")
        panel.resignKey()
        check(!panel.isVisible, "losing window focus dismisses search")

        finish()
    }

    private func finish() -> Never {
        let board = NSPasteboard.general
        board.clearContents()
        if !savedClipboard.isEmpty { board.writeObjects(savedClipboard) }
        print("\(checks) checks, \(failures) failures")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
