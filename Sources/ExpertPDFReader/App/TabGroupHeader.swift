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

    var body: some View {
        Button {
            withAnimation(AppAnimation.sidebarReveal) { session.toggleTabGroup(group.id) }
        } label: {
            HStack(spacing: 6) {
                if !isCompact {
                    Text(group.name).font(.system(size: isSidebar ? 12 : 11, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if isSidebar { Spacer(minLength: 2) }
                }
                if isSidebar {
                    Image(systemName: group.isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(AppPalette.tabGroupLabel(group.color))
            .padding(.horizontal, isCompact ? 0 : 8)
            .frame(maxWidth: .infinity)
            .frame(height: isSidebar ? 28 : 20)
            .background(RoundedRectangle(cornerRadius: isSidebar ? 7 : 5)
                .fill(AppPalette.tabGroupFill(group.color, isDark)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, isSidebar ? 0 : 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !isSidebar && !group.isCollapsed {
                AppPalette.tabOutline(group.color, isDark).frame(height: 2).allowsHitTesting(false)
            }
        }
        .overlay {
            TabInteractionArea(session: session, tabID: group.id, toolTip: group.displayName,
                excludedTrailingWidth: 0, isGroupHeader: true, isSidebar: isSidebar,
                onSelect: { withAnimation(AppAnimation.sidebarReveal) { session.toggleTabGroup(group.id) } },
                onDragChanged: onDragChanged, onDragEnded: onDragEnded)
        }
        .help(group.displayName)
        .accessibilityLabel(Text(group.displayName))
        .accessibilityValue(Text(group.isCollapsed ? L10n.tr("已折叠", "Collapsed") : L10n.tr("已展开", "Expanded")))
        .contextMenu {
            Button(L10n.tr("重命名分组…", "Rename Group…")) { store.editTabGroup(group.id, in: session.id) }
            Menu(L10n.tr("颜色", "Color")) {
                Picker(L10n.tr("颜色", "Color"), selection: Binding(
                    get: { group.color },
                    set: { store.setTabGroupColor(group.id, color: $0, in: session.id) }
                )) {
                    ForEach(TabGroupColor.allCases, id: \.self) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(nsImage: swatch(color))
                        }
                        .tag(color)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
            Divider()
            Button(L10n.tr("取消分组", "Ungroup Tabs")) { store.ungroupTabs(group.id, in: session.id) }
            Button(L10n.tr("关闭分组", "Close Group")) { store.closeTabGroup(group.id, in: session.id) }
        }
    }

    private func swatch(_ color: TabGroupColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(AppPalette.tabGroupFill(color, isDark)).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 2, yRadius: 2).fill()
            return true
        }
    }
}
