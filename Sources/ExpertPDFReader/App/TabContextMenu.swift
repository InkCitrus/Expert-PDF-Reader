import AppKit
import SwiftUI

/// Shared metrics and interaction for document and group context panels.
struct TabContextMenuStyle: ViewModifier {
    let isDark: Bool
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(width: 304)
            .font(.system(size: 13))
            .foregroundStyle(AppPalette.labelPrimary(isDark))
            .onExitCommand { dismiss() }
    }
}

struct TabContextMenuRow: View {
    let title: String
    let icon: String
    let isDark: Bool
    var isEnabled = true
    var isChecked = false
    var hasSubmenu = false
    var iconColor: Color?
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(iconColor ?? foreground)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if isChecked || hasSubmenu {
                    Image(systemName: isChecked ? "checkmark" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isHovered && isEnabled ? AppPalette.tabHoverBackground(isDark) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        isEnabled ? AppPalette.labelPrimary(isDark) : AppPalette.labelTertiary(isDark)
    }
}

struct DocumentTabContextMenu: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    @ObservedObject var tab: DocumentTabState
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isChoosingGroup = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            if isChoosingGroup { groupPicker }
            else { actions }
        }
        .modifier(TabContextMenuStyle(isDark: isDark, dismiss: dismiss))
    }

    private var actions: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                TabContextMenuRow(title: L10n.tr("添加到分组", "Add to Group"), icon: "rectangle.3.group",
                                  isDark: isDark, hasSubmenu: true) { isChoosingGroup = true }
                if session.tabGroup(containing: tab.id) != nil {
                    action(L10n.tr("移出分组", "Remove from Group"), icon: "rectangle.badge.minus") {
                        store.moveTab(tab.id, intoGroup: nil, in: session.id)
                    }
                }
            }.padding(6)
            Divider()
            VStack(spacing: 2) {
                action(L10n.tr("将标签移至新窗口", "Move Tab to New Window"), icon: "macwindow.badge.plus",
                       isEnabled: store.canDetachTab(id: tab.id, in: session.id)) {
                    store.detachTabToNewWindow(id: tab.id, from: session.id)
                }
                if !session.isPrimary {
                    action(L10n.tr("移回主窗口", "Move Tab to Main Window"), icon: "arrow.uturn.backward") {
                        store.moveTab(id: tab.id, from: session.id, to: store.primarySession.id)
                    }
                }
            }.padding(6)
            Divider()
            VStack(spacing: 2) {
                action(L10n.tr("重新打开关闭的标签", "Reopen Closed Tab"), icon: "arrow.uturn.backward",
                       isEnabled: !store.closedTabs.isEmpty) { store.reopenClosedTab(in: session.id) }
                action(L10n.tr("关闭标签", "Close Tab"), icon: "xmark") { store.closeTab(id: tab.id, in: session.id) }
                action(L10n.tr("关闭其他标签", "Close Other Tabs"), icon: "rectangle.on.rectangle",
                       isEnabled: session.tabs.filter { !$0.isHome }.count > 1) {
                    store.closeOtherTabs(keeping: tab.id, in: session.id)
                }
            }.padding(6)
            Divider()
            VStack(spacing: 2) {
                action(L10n.tr("在 Finder 中显示", "Show in Finder"), icon: "folder") {
                    store.showInFinder(id: tab.documentID)
                }
                action(L10n.tr("复制为路径名", "Copy as Pathname"), icon: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.documentID.url.path, forType: .string)
                }
            }.padding(6)
        }
    }

    private var groupPicker: some View {
        VStack(spacing: 0) {
            TabContextMenuRow(title: L10n.tr("添加到分组", "Add to Group"), icon: "chevron.left", isDark: isDark) {
                isChoosingGroup = false
            }.padding(6)
            Divider()
            action(L10n.tr("新建分组…", "New Group…"), icon: "plus") {
                store.editTabGroup(containing: tab.id, in: session.id)
            }.padding(6)
            if !session.tabGroups.isEmpty {
                Divider()
                if session.tabGroups.count > 8 {
                    ScrollView { groupRows }.frame(height: 8 * 38 + 12)
                } else { groupRows }
            }
        }
    }

    private var groupRows: some View {
        VStack(spacing: 2) {
            ForEach(session.tabGroups) { group in
                TabContextMenuRow(title: group.name, icon: "rectangle.fill", isDark: isDark,
                                  isChecked: group.tabIDs.contains(tab.id),
                                  iconColor: AppPalette.tabGroupFill(group.color, isDark)) {
                    dismiss()
                    store.moveTab(tab.id, intoGroup: group.id, in: session.id)
                }
                .help(group.name)
            }
        }.padding(6)
    }

    private func action(_ title: String, icon: String, isEnabled: Bool = true,
                        perform: @escaping () -> Void) -> some View {
        TabContextMenuRow(title: title, icon: icon, isDark: isDark, isEnabled: isEnabled) {
            dismiss()
            perform()
        }
    }
}
