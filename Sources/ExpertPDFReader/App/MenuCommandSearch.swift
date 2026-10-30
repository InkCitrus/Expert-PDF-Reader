import AppKit

/// Search the live menu tree, so results follow the app's language, state and available commands.
@MainActor
final class MenuCommandSearch: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = MenuCommandSearch()
    static var title: String { L10n.tr("搜索菜单命令…", "Search Menu Commands…") }

    private struct Command {
        let item: NSMenuItem
        let path: String
        let isEnabled: Bool
    }

    private let searchField = NSSearchField()
    private let table = MenuCommandResultsTable()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var commands: [Command] = []
    private var results: [Command] = []
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var isDismissing = false

    private lazy var panel: NSPanel = {
        let panel = MenuCommandSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }
        panel.setAccessibilityLabel(Self.title)

        let content = NSView()
        panel.contentView = content
        searchField.placeholderString = Self.title.replacingOccurrences(of: "…", with: "")
        searchField.setAccessibilityLabel(Self.title)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.font = .systemFont(ofSize: 16)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseCommand)
        table.onChoose = { [weak self] in self?.chooseCommand() }
        table.setAccessibilityLabel(L10n.tr("菜单命令", "Menu Commands"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        for view in [searchField, scroll, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        ])
        return panel
    }()

    func show() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
            return
        }
        sourceWindow = NSApp.keyWindow ?? NSApp.mainWindow
        sourceResponder = sourceWindow?.firstResponder
        commands = []
        if let menu = NSApp.mainMenu {
            prepareMenu(menu)
            collectCommands(in: menu, path: [])
        }
        searchField.stringValue = ""
        updateResults()
        if let window = sourceWindow {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func prepareMenu(_ menu: NSMenu) {
        guard menu !== NSApp.servicesMenu, menu !== NSApp.helpMenu else { return }
        // SwiftUI builds some command groups only when the menu asks its delegate for content.
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if let submenu = item.submenu { prepareMenu(submenu) }
        }
        menu.update()
    }

    private func collectCommands(in menu: NSMenu, path: [String], parentsEnabled: Bool = true) {
        guard menu !== NSApp.servicesMenu, menu !== NSApp.helpMenu else { return }
        for item in menu.items where !item.isHidden && !item.isSeparatorItem && !item.isAlternate {
            if let submenu = item.submenu {
                collectCommands(in: submenu, path: path + [item.title], parentsEnabled: parentsEnabled && item.isEnabled)
            } else if item.action != nil, item.title != Self.title {
                commands.append(Command(item: item, path: path.joined(separator: " › "), isEnabled: parentsEnabled && item.isEnabled))
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        updateResults()
    }

    private func updateResults() {
        let words = searchField.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
        results = words.isEmpty ? [] : commands.filter { command in
            words.allSatisfy { (command.path + " " + command.item.title).localizedStandardContains($0) }
        }
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        emptyLabel.stringValue = words.isEmpty
            ? L10n.tr("输入命令名称", "Type a command name")
            : L10n.tr("没有匹配的命令", "No matching commands")
        emptyLabel.isHidden = !results.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let command = results[row]
        let title = NSTextField(labelWithString: command.item.title)
        title.font = .systemFont(ofSize: 14)
        title.textColor = command.isEnabled ? .labelColor : .disabledControlTextColor
        title.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: command.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        return stack
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + step, 0), results.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)):
            chooseCommand()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(restoreFocus: true)
        default:
            return false
        }
        return true
    }

    @objc private func chooseCommand() {
        panel.makeFirstResponder(searchField)
        let row = table.selectedRow
        guard results.indices.contains(row), results[row].isEnabled,
              let action = results[row].item.action else { return }
        let item = results[row].item
        // Restore the original reader and selection before dispatching responder-chain commands like Copy.
        dismiss(restoreFocus: true)
        item.menu?.update()
        guard item.isEnabled else { return }
        var menu = item.menu
        while let parent = menu?.supermenu {
            guard parent.items.first(where: { $0.submenu === menu })?.isEnabled == true else { return }
            menu = parent
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func dismiss(restoreFocus: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        panel.orderOut(nil)
        if restoreFocus, let window = sourceWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            if let responder = sourceResponder { window.makeFirstResponder(responder) }
        }
        commands = []
        results = []
        table.reloadData()
        sourceWindow = nil
        sourceResponder = nil
        isDismissing = false
    }

    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }
    func windowWillClose(_ notification: Notification) { dismiss(restoreFocus: true) }
}

private final class MenuCommandSearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class MenuCommandResultsTable: NSTableView {
    var onChoose: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onChoose?()
        } else if event.keyCode == 53 {
            window?.cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
