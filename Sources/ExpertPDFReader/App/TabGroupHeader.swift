import AppKit
import SwiftUI

struct TabGroupHeader: View {
    @ObservedObject var store: AppStore
    @ObservedObject var session: ReaderWindowSession
    let group: ReaderTabGroup
    let isSidebar: Bool
    let isCompact: Bool
    let isDark: Bool
    let onDragChanged: (TabDragLocation) -> Void
    let onDragEnded: (TabDragLocation?) -> Void

    private var containsSelection: Bool { group.tabIDs.contains(session.selectedTabID) }

    var body: some View {
        Button {
            withAnimation(AppAnimation.tab) { session.toggleTabGroup(group.id) }
        } label: {
            HStack(spacing: 6) {
                if isCompact {
                    Text(String(group.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(AppPalette.accentBlue.opacity(0.12)))
                } else {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text(group.name).font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if isSidebar { Spacer(minLength: 2) }
                    Text("\(group.tabIDs.count)")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(AppPalette.labelSecondary(isDark))
                }
            }
            .foregroundStyle(containsSelection ? AppPalette.accentBlue : AppPalette.labelPrimary(isDark))
            .padding(.horizontal, isCompact ? 0 : 8)
            .frame(maxWidth: .infinity, maxHeight: isSidebar ? .infinity : 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(containsSelection ? AppPalette.accentBlue.opacity(0.1) : AppPalette.tabHoverBackground(isDark)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, isSidebar ? 0 : 4)
        .frame(maxHeight: .infinity)
        .overlay {
            TabInteractionArea(session: session, tabID: group.id, toolTip: "\(group.name) (\(group.tabIDs.count))",
                excludedTrailingWidth: 0, isGroupHeader: true, isSidebar: isSidebar,
                onSelect: { withAnimation(AppAnimation.tab) { session.toggleTabGroup(group.id) } },
                onDragChanged: onDragChanged, onDragEnded: onDragEnded)
        }
        .help("\(group.name) (\(group.tabIDs.count))")
        .accessibilityLabel(Text("\(group.name) (\(group.tabIDs.count))"))
        .accessibilityValue(Text(group.isCollapsed ? L10n.tr("已折叠", "Collapsed") : L10n.tr("已展开", "Expanded")))
        .contextMenu {
            Button(L10n.tr("重命名分组…", "Rename Group…")) { store.editTabGroup(group.id, in: session.id) }
            Button(L10n.tr("取消分组", "Ungroup Tabs")) { store.ungroupTabs(group.id, in: session.id) }
            Divider()
            Button(L10n.tr("关闭分组", "Close Group")) { store.closeTabGroup(group.id, in: session.id) }
        }
    }
}
