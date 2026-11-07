import AppKit
import SwiftUI

struct TabGroupHeader: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    let group: ReaderTabGroup
    let isSidebar: Bool
    let isCompact: Bool
    let isDark: Bool
    var onMenuActivityChanged: ((Bool) -> Void)?
    let onDragChanged: (TabDragLocation) -> Void
    let onDragEnded: (TabDragLocation?) -> Void

    @State private var isEditorPresented = false

    var body: some View {
        Button {
            withAnimation(AppAnimation.tab) { session.toggleTabGroup(group.id) }
        } label: {
            HStack(spacing: 6) {
                if !isCompact {
                    Text(group.name).font(.system(size: isSidebar ? 12 : 11, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                }
                Image(systemName: group.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(AppPalette.tabGroupLabel(group.color))
            .padding(.horizontal, isCompact ? 0 : 8)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(AppPalette.tabGroupFill(group.color, isDark)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, isSidebar ? 0 : 4)
        .frame(maxHeight: .infinity)
        .overlay {
            TabInteractionArea(session: session, tabID: group.id, toolTip: group.name,
                excludedTrailingWidth: 0, isGroupHeader: true, isSidebar: isSidebar,
                onContextMenu: {
                    onMenuActivityChanged?(true)
                    isEditorPresented = true
                },
                onSelect: { withAnimation(AppAnimation.tab) { session.toggleTabGroup(group.id) } },
                onDragChanged: onDragChanged, onDragEnded: onDragEnded)
        }
        .help(group.name)
        .accessibilityLabel(Text(group.name))
        .accessibilityValue(Text(group.isCollapsed ? L10n.tr("已折叠", "Collapsed") : L10n.tr("已展开", "Expanded")))
        .accessibilityAction(named: Text(L10n.tr("重命名分组…", "Rename Group…"))) {
            onMenuActivityChanged?(true)
            isEditorPresented = true
        }
        .popover(isPresented: $isEditorPresented, arrowEdge: isSidebar ? .trailing : .bottom) {
            TabGroupEditor(store: store, session: session, groupID: group.id) {
                isEditorPresented = false
            }
        }
        .onChange(of: isEditorPresented) { _, presented in
            onMenuActivityChanged?(presented)
        }
        .onDisappear {
            if isEditorPresented { onMenuActivityChanged?(false) }
        }
    }
}

/// Keep the name and palette together, so a group can be edited without another dialog.
private struct TabGroupEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    let groupID: UUID
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isNameFocused: Bool
    @State private var name = ""

    private var isDark: Bool { colorScheme == .dark }
    private var color: TabGroupColor { session.tabGroups.first { $0.id == groupID }?.color ?? .blue }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                TextField(L10n.tr("分组名称", "Group Name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppPalette.cardBackground(isDark)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AppPalette.tabGroupFill(color, isDark), lineWidth: isNameFocused ? 2 : 1))
                    .focused($isNameFocused)
                    .onSubmit { saveName(); dismiss() }
                    .accessibilityLabel(Text(L10n.tr("分组名称", "Group Name")))
                HStack(spacing: 2) {
                    ForEach(TabGroupColor.allCases, id: \.self) { option in
                        Button {
                            store.setTabGroupColor(groupID, color: option, in: session.id)
                        } label: {
                            Circle().fill(AppPalette.tabGroupFill(option, isDark))
                                .frame(width: 18, height: 18)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().inset(by: 1)
                                    .strokeBorder(AppPalette.tabGroupFill(option, isDark),
                                                  lineWidth: color == option ? 2 : 0))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                        .accessibilityLabel(Text(option.title))
                        .accessibilityAddTraits(color == option ? .isSelected : [])
                        .accessibilityIdentifier("tabGroupColor.\(option.rawValue)")
                    }
                }
            }
            .padding(14)
            Divider()
            VStack(spacing: 2) {
                action(L10n.tr("取消分组", "Ungroup Tabs"), icon: "rectangle.3.group") {
                    store.ungroupTabs(groupID, in: session.id)
                }
                action(L10n.tr("关闭分组", "Close Group"), icon: "xmark.rectangle") {
                    store.closeTabGroup(groupID, in: session.id)
                }
            }
            .padding(6)
        }
        .frame(width: 304)
        .foregroundStyle(AppPalette.labelPrimary(isDark))
        .onAppear {
            name = session.tabGroups.first { $0.id == groupID }?.name ?? ""
            isNameFocused = true
        }
        .onDisappear { saveName() }
        .onExitCommand { dismiss() }
    }

    private func saveName() { store.renameTabGroup(groupID, name: name, in: session.id) }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        GroupEditorAction(title: title, icon: icon, isDark: isDark) {
            saveName()
            dismiss()
            perform()
        }
    }
}

private struct GroupEditorAction: View {
    let title: String
    let icon: String
    let isDark: Bool
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? AppPalette.tabHoverBackground(isDark) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
