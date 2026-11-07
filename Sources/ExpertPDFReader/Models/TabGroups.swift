import AppKit
import Foundation

public enum TabGroupColor: String, Codable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray

    var title: String {
        switch self {
        case .blue: L10n.tr("蓝色", "Blue")
        case .purple: L10n.tr("紫色", "Purple")
        case .pink: L10n.tr("粉色", "Pink")
        case .red: L10n.tr("红色", "Red")
        case .orange: L10n.tr("橙色", "Orange")
        case .yellow: L10n.tr("黄色", "Yellow")
        case .green: L10n.tr("绿色", "Green")
        case .teal: L10n.tr("青色", "Teal")
        case .gray: L10n.tr("灰色", "Gray")
        }
    }

    static func next(excluding colors: [TabGroupColor]) -> TabGroupColor {
        allCases.first { !colors.contains($0) } ?? allCases[colors.count % allCases.count]
    }
}

public struct ReaderTabGroup: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var tabIDs: Set<UUID>
    public var isCollapsed = false
    public var color: TabGroupColor = .blue
}

struct SavedTabGroup: Codable {
    let id: UUID
    let name: String
    let paths: [String]
    let isCollapsed: Bool
    var color: TabGroupColor? = nil
}

@MainActor
extension ReaderWindowSession {
    func tabGroup(containing tabID: UUID) -> ReaderTabGroup? {
        tabGroups.first { $0.tabIDs.contains(tabID) }
    }

    var selectedTabScrollID: UUID {
        guard let group = tabGroup(containing: selectedTabID), group.isCollapsed else { return selectedTabID }
        return group.id
    }

    func pruneTabGroups() {
        let openIDs = Set(tabs.filter { !$0.isHome }.map(\.id))
        let remaining = tabGroups.compactMap { group -> ReaderTabGroup? in
            var group = group
            group.tabIDs.formIntersection(openIDs)
            return group.tabIDs.isEmpty ? nil : group
        }
        if remaining != tabGroups { tabGroups = remaining }
    }

    func revealSelectedTabGroup() {
        guard let index = tabGroups.firstIndex(where: { $0.isCollapsed && $0.tabIDs.contains(selectedTabID) }) else { return }
        tabGroups[index].isCollapsed = false
    }

    func setTabGroup(_ tabID: UUID, to groupID: UUID?) {
        var groups = tabGroups
        for index in groups.indices {
            groups[index].tabIDs.remove(tabID)
            if groups[index].id == groupID { groups[index].tabIDs.insert(tabID) }
        }
        groups.removeAll { $0.tabIDs.isEmpty }
        if groups != tabGroups { tabGroups = groups }
    }

    func toggleTabGroup(_ id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        tabGroups[index].isCollapsed.toggle()
    }

    /// Both tab layouts use the same order: named groups, then ungrouped documents.
    func normalizeTabGroupOrder() {
        guard !tabGroups.isEmpty else { return }
        let assigned = Set(tabGroups.flatMap(\.tabIDs))
        let ordered = tabs.filter(\.isHome)
            + tabGroups.flatMap { group in tabs.filter { group.tabIDs.contains($0.id) } }
            + tabs.filter { !$0.isHome && !assigned.contains($0.id) }
        if ordered.map(\.id) != tabs.map(\.id) { tabs = ordered }
    }

    func moveTabGroup(_ id: UUID, before nextID: UUID?) {
        guard id != nextID, let from = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        var groups = tabGroups
        let group = groups.remove(at: from)
        let index = nextID.flatMap { next in groups.firstIndex { $0.id == next } } ?? groups.count
        groups.insert(group, at: index)
        tabGroups = groups
        normalizeTabGroupOrder()
    }
}

@MainActor
extension AppStore {
    @discardableResult
    func createTabGroup(name: String, containing tabID: UUID, in sessionID: UUID? = nil) -> UUID? {
        let session = session(withID: sessionID)
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, session.tabs.contains(where: { !$0.isHome && $0.id == tabID }) else { return nil }
        moveTab(tabID, intoGroup: nil, in: session.id)
        let group = ReaderTabGroup(id: UUID(), name: name, tabIDs: [tabID],
                                   color: .next(excluding: session.tabGroups.map(\.color)))
        session.tabGroups.append(group)
        session.normalizeTabGroupOrder()
        return group.id
    }

    func renameTabGroup(_ id: UUID, name: String, in sessionID: UUID? = nil) {
        let session = session(withID: sessionID)
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, let index = session.tabGroups.firstIndex(where: { $0.id == id }) else { return }
        session.tabGroups[index].name = name
    }

    func setTabGroupColor(_ id: UUID, color: TabGroupColor, in sessionID: UUID? = nil) {
        let session = session(withID: sessionID)
        guard let index = session.tabGroups.firstIndex(where: { $0.id == id }) else { return }
        session.tabGroups[index].color = color
    }

    func moveTab(_ tabID: UUID, intoGroup groupID: UUID?, in sessionID: UUID? = nil) {
        let session = session(withID: sessionID)
        guard session.tabs.contains(where: { !$0.isHome && $0.id == tabID }),
              groupID == nil || session.tabGroups.contains(where: { $0.id == groupID }) else { return }
        let oldGroup = session.tabGroup(containing: tabID)
        guard oldGroup?.id != groupID else { return }
        let neighbors = (groupID.flatMap { id in session.tabGroups.first { $0.id == id } } ?? oldGroup)?.tabIDs ?? []
        var tabs = session.tabs
        let originalIndex = tabs.firstIndex { $0.id == tabID }!
        let moved = tabs.remove(at: originalIndex)
        let insertion = tabs.lastIndex(where: { neighbors.contains($0.id) }).map { $0 + 1 } ?? originalIndex
        tabs.insert(moved, at: min(insertion, tabs.count))
        session.setTabGroup(tabID, to: groupID)
        session.tabs = tabs
        if let groupID, let index = session.tabGroups.firstIndex(where: { $0.id == groupID }) {
            session.tabGroups[index].isCollapsed = false
        }
        session.normalizeTabGroupOrder()
    }

    func ungroupTabs(_ groupID: UUID, in sessionID: UUID? = nil) {
        let session = session(withID: sessionID)
        session.tabGroups.removeAll { $0.id == groupID }
        session.normalizeTabGroupOrder()
    }

    func closeTabGroup(_ groupID: UUID, in sessionID: UUID? = nil) {
        let session = session(withID: sessionID)
        let ids = session.tabs.filter { session.tabGroup(containing: $0.id)?.id == groupID }.map(\.id)
        for id in ids { closeTab(id: id, in: session.id) }
    }

    func editTabGroup(_ groupID: UUID? = nil, containing tabID: UUID? = nil, in sessionID: UUID? = nil) {
        let session = session(withID: sessionID)
        let group = session.tabGroups.first { $0.id == groupID }
        let alert = NSAlert()
        alert.messageText = group == nil ? L10n.tr("新建分组…", "New Group…") : L10n.tr("重命名分组…", "Rename Group…")
        let field = NSTextField(string: group?.name ?? "")
        field.placeholderString = L10n.tr("分组名称", "Group Name")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: group == nil ? L10n.tr("创建分组", "Create Group") : L10n.tr("保存", "Save"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        let save: (NSApplication.ModalResponse) -> Void = { [weak self, weak session] response in
            guard response == .alertFirstButtonReturn, let self, let session else { return }
            if let group { self.renameTabGroup(group.id, name: field.stringValue, in: session.id) }
            else if let tabID { self.createTabGroup(name: field.stringValue, containing: tabID, in: session.id) }
        }
        if let window = session.nsWindow {
            guard window.attachedSheet == nil else { return }
            alert.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(alert.runModal())
        }
    }
}
