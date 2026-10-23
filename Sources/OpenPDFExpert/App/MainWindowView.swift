import AppKit
import SwiftUI

/// Replicates `MainWindowController` + `TabsViewController` + `HomeTabButtonView` from `PDFExpert`.
/// Enforces a minimum window width of `600pt` per `HomeTab.framework/ARCHITECTURE.md`.
public struct MainWindowView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Multi-Tab Bar (TabsViewController)
            TopTabBarView(store: store, isDark: isDark)

            // Active Tab Content
            ZStack {
                if let activeTab = store.tabs.first(where: { $0.id == store.selectedTabID }) {
                    switch activeTab {
                    case .home:
                        HomeTabRootView(store: store)
                    case .document(let docState):
                        PDFReaderView(store: store, tab: docState)
                            .id(docState.id)
                    }
                } else {
                    HomeTabRootView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 520)
        .background(RDColorPalette.systemBackground(isDark))
    }
}

// MARK: - TopTabBarView (TabsViewController + HomeTabButtonView + TabView)

struct TopTabBarView: View {
    @ObservedObject var store: AppStore
    let isDark: Bool

    @State private var hoveredTabID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            // Fixed HomeTabButtonView (always accessible on the left)
            if let homeTab = store.tabs.first(where: { $0.isHome }) {
                let isHomeSelected = (store.selectedTabID == homeTab.id)
                Button {
                    store.selectedTabID = homeTab.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isHomeSelected ? "house.fill" : "house")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(isHomeSelected ? RDColorPalette.primaryTint : RDColorPalette.labelSecondary(isDark))
                        Text("主页")
                            .font(.system(size: 12.5, weight: isHomeSelected ? .semibold : .medium))
                            .foregroundColor(isHomeSelected ? RDColorPalette.labelPrimary(isDark) : RDColorPalette.labelSecondary(isDark))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHomeSelected ? RDColorPalette.tertiarySystemBackground(isDark) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isHomeSelected ? RDColorPalette.separator(isDark).opacity(0.65) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            // Scrollable Document Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs.filter { !$0.isHome }) { tab in
                        let isSelected = (store.selectedTabID == tab.id)
                        let isHovered = (hoveredTabID == tab.id)

                        HStack(spacing: 7) {
                            Image(systemName: "doc.richtext.fill")
                                .font(.system(size: 11.5))
                                .foregroundColor(isSelected ? RDColorPalette.systemRed : RDColorPalette.labelTertiary(isDark))

                            Text(tab.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? RDColorPalette.labelPrimary(isDark) : RDColorPalette.labelSecondary(isDark))
                                .lineLimit(1)
                                .frame(maxWidth: 170, alignment: .leading)

                            Button {
                                store.closeTab(id: tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(RDColorPalette.labelSecondary(isDark))
                                    .frame(width: 16, height: 16)
                                    .background(
                                        Circle()
                                            .fill(isHovered ? RDColorPalette.separator(isDark).opacity(0.6) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .opacity((isSelected || isHovered) ? 1.0 : 0.45)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    isSelected
                                        ? RDColorPalette.tertiarySystemBackground(isDark)
                                        : (isHovered ? RDColorPalette.tertiarySystemBackground(isDark).opacity(0.5) : Color.clear)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isSelected ? RDColorPalette.separator(isDark).opacity(0.65) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedTabID = tab.id
                        }
                        .onHover { hovering in
                            hoveredTabID = hovering ? tab.id : nil
                        }
                    }

                    // "+" Button to Open Document
                    Button {
                        store.openFilePicker()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(RDColorPalette.labelSecondary(isDark))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(RDColorPalette.tertiarySystemBackground(isDark).opacity(0.6))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("打开新 PDF 文档 (⌘O)")
                }
            }

            Spacer()

            // Global Appearance Mode Pill (System / Light / Dark) in Tab Bar
            HStack(spacing: 3) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    let isSelected = (store.appearanceMode == mode)
                    Button {
                        store.appearanceMode = mode
                    } label: {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? RDColorPalette.primaryTint : RDColorPalette.labelSecondary(isDark))
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isSelected ? RDColorPalette.primaryTint.opacity(isDark ? 0.22 : 0.14) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("界面外观：\(mode.title)")
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(RDColorPalette.tertiarySystemBackground(isDark))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RDColorPalette.systemBackground(isDark))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RDColorPalette.separator(isDark).opacity(0.6))
                .frame(height: 1)
        }
    }
}
