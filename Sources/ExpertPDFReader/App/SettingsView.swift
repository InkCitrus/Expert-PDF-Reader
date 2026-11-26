import AppKit
import SwiftUI

private enum SettingsTab: Int, CaseIterable, Identifiable {
    case general = 0
    case reading = 1
    case appearance = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("通用", "General")
        case .reading: return L10n.tr("阅读", "Reading")
        case .appearance: return L10n.tr("外观", "Appearance")
        }
    }

    func iconName(selected: Bool) -> String {
        switch self {
        case .general: return selected ? "gearshape.fill" : "gearshape"
        case .reading: return selected ? "book.pages.fill" : "book.pages"
        case .appearance: return selected ? "paintbrush.fill" : "paintbrush"
        }
    }
}

/// `Settings` scene (⌘,), also reachable from the Home sidebar's 设置 / Settings row via `SettingsLink`.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: SettingsTab
    @State private var hoveredTab: SettingsTab?
    @Namespace private var sidebarNamespace

    init(store: AppStore, initialTabIndex: Int = 0) {
        self.store = store
        self._selectedTab = State(initialValue: SettingsTab(rawValue: initialTabIndex) ?? .general)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var accent: Color { store.accentColor.color(isDark: isDark) }
    private var detailCanvasColor: Color { isDark ? Color(hex: 0x1D1D20) : Color(hex: 0xF5F5F7) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.09))
                .frame(width: 1)
                .ignoresSafeArea(.all, edges: .top)
            detailPane
        }
        .frame(minWidth: 660, idealWidth: 700, maxWidth: .infinity, minHeight: 420, idealHeight: 450, maxHeight: .infinity)
        .background(detailCanvasColor.ignoresSafeArea(.all, edges: .top))
        .background(SettingsWindowConfigurator())
        .environment(\.appAccentColor, accent)
        .onAppear { store.refreshDefaultPDFApp() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDefaultPDFApp()
        }
    }

    // MARK: - Translucent Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                let isHovered = hoveredTab == tab && !isSelected
                Button {
                    guard selectedTab != tab else { return }
                    withAnimation(AppAnimation.micro) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.iconName(selected: isSelected))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isSelected ? accent : AppPalette.labelSecondary(isDark))
                            .frame(width: 19)
                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.065))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.04),
                                            lineWidth: 0.5
                                        )
                                )
                                .matchedGeometryEffect(id: "settingsSidebarSelection", in: sidebarNamespace)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                }
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 1.5) {
                Text("Expert PDF Reader")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(AppPalette.labelTertiary(isDark))
                    .lineLimit(1)
                if let version = appVersionString {
                    Text("v\(version)")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AppPalette.labelQuaternary(isDark))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 50)
        .padding(.bottom, 14)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            SettingsSidebarMaterial()
                .ignoresSafeArea(.all, edges: .top)
        }
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        ZStack(alignment: .topLeading) {
            switch selectedTab {
            case .general:
                ScrollView(.vertical) {
                    generalPane
                        .frame(maxWidth: 680, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .transition(.opacity)
            case .reading:
                ScrollView(.vertical) {
                    readingPane
                        .frame(maxWidth: 680, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .transition(.opacity)
            case .appearance:
                ScrollView(.vertical) {
                    appearancePane
                        .frame(maxWidth: 680, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 463, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(detailCanvasColor.ignoresSafeArea(.all, edges: .top))
        .clipped()
        .id(store.appLanguage)
        .animation(AppAnimation.micro, value: selectedTab)
    }

    // MARK: - General

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle(L10n.tr("通用", "General"))

            SettingsCard(isDark: isDark) {
                defaultAppRow
                SettingsCardDivider(isDark: isDark, leadingInset: 48)
                languageRow

                if store.menuBarNeedsRestartForLanguage {
                    SettingsCardDivider(isDark: isDark, leadingInset: 48)
                    restartNoteRow
                }
            }

            SettingsCard(isDark: isDark) {
                SettingsSwitchRow(
                    icon: "macwindow.on.rectangle",
                    title: L10n.tr("启动时恢复标签页", "Restore Tabs on Launch"),
                    isOn: $store.restoreTabsOnLaunch,
                    isDark: isDark,
                    accent: accent
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 24)
    }

    private var defaultAppRow: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: "doc.richtext", isDark: isDark)
            VStack(alignment: .leading, spacing: 2.5) {
                Text(L10n.tr("默认 PDF 应用", "Default PDF App"))
                    .font(.system(size: 13))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if !store.isDefaultPDFApp, let appName = store.defaultPDFAppName {
                    Text(L10n.defaultPDFAppNote(appName))
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 14)
            if store.isDefaultPDFApp {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(accent)
                    Text("Expert PDF Reader")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppPalette.labelSecondary(isDark))
                }
            } else {
                SettingsActionButton(title: L10n.tr("设为默认", "Make Default"), isDark: isDark) {
                    store.makeDefaultPDFApp()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: "globe", isDark: isDark)
            Text(L10n.tr("语言", "Language"))
                .font(.system(size: 13))
                .foregroundColor(AppPalette.labelPrimary(isDark))
            Spacer(minLength: 14)
            Picker("", selection: $store.appLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.title).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .id("language.\(store.appLanguage.rawValue)")
            .accessibilityLabel(Text(L10n.tr("语言", "Language")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10.5)
    }

    private var restartNoteRow: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowIcon(icon: "arrow.clockwise.circle", isDark: isDark)
            Text(L10n.tr("重启后生效于菜单栏。", "Restart to update the menu bar."))
                .font(.system(size: 12))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            SettingsActionButton(title: L10n.tr("立即重新启动", "Restart Now"), isDark: isDark) {
                store.relaunchApp()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10.5)
    }

    private var appVersionString: String? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return nil }
        return version
    }

    // MARK: - Reading

    private var readingPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle(L10n.tr("阅读", "Reading"))

            SettingsCard(isDark: isDark) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("阅读主题", "Reading Theme"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppPalette.labelPrimary(isDark))

                    HStack(spacing: 10) {
                        ForEach(PDFReadingThemeMode.allCases) { mode in
                            ReadingThemeOptionCard(
                                mode: mode,
                                useSepiaInLight: store.useSepiaForLightSystemTheme,
                                isSelected: store.readingThemeMode == mode,
                                isDark: isDark,
                                accent: accent
                            ) {
                                withAnimation(AppAnimation.snappy) {
                                    store.readingThemeMode = mode
                                }
                            }
                        }
                    }
                    .id("theme.\(store.appLanguage.rawValue)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                SettingsCardDivider(isDark: isDark, leadingInset: 48)

                SettingsSwitchRow(
                    icon: "scroll",
                    title: L10n.tr("浅色模式改用纸质", "Use Sepia in Light Mode"),
                    isOn: $store.useSepiaForLightSystemTheme,
                    isDark: isDark,
                    accent: accent,
                    isDisabled: store.readingThemeMode != .system
                )
            }

            SettingsCard(isDark: isDark) {
                SettingsSwitchRow(
                    icon: "list.bullet.indent",
                    title: L10n.tr("自动识别目录", "Auto-Recognize Outline"),
                    subtitle: L10n.tr("文档缺少内嵌书签时自动生成目录", "Generate an outline when bookmarks are missing"),
                    isOn: $store.autoGenerateOutline,
                    isDark: isDark,
                    accent: accent
                )
                SettingsCardDivider(isDark: isDark, leadingInset: 48)
                SettingsSwitchRow(
                    icon: "number.square",
                    title: L10n.tr("始终显示页码浮窗", "Always Show Page Counter"),
                    isOn: $store.alwaysShowPageIndicator,
                    isDark: isDark,
                    accent: accent
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 24)
    }

    // MARK: - Appearance

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle(L10n.tr("外观", "Appearance"))

            SettingsCard(isDark: isDark) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("界面外观", "App Appearance"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppPalette.labelPrimary(isDark))

                    HStack(spacing: 12) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            AppearanceOptionCard(
                                mode: mode,
                                isSelected: store.appearanceMode == mode,
                                isDark: isDark,
                                accent: accent
                            ) {
                                withAnimation(AppAnimation.snappy) {
                                    store.appearanceMode = mode
                                }
                            }
                        }
                    }
                    .id("appearance.\(store.appLanguage.rawValue)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }

            SettingsCard(isDark: isDark) {
                AccentColorRow(store: store, isDark: isDark)
                    .id("accent.\(store.appLanguage.rawValue)")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }

            Text(L10n.tr(
                "外观控制窗口配色，主题控制页面配色。",
                "Appearance styles the window; theme styles PDF pages."
            ))
            .font(.system(size: 11.5))
            .foregroundColor(AppPalette.labelTertiary(isDark))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 24)
    }

    private func paneTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(AppPalette.labelPrimary(isDark))
            .padding(.horizontal, 2)
    }
}

// MARK: - Native Window & Sidebar Vibrancy Bridges

private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.configureWindowIfNeeded()
    }

    final class AnchorView: NSView {
        private var configuredWindowNumber: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfNeeded()
        }

        func configureWindowIfNeeded() {
            guard let window else { return }
            window.styleMask.formUnion([.resizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            window.contentMinSize = NSSize(width: 660, height: 420)
            guard configuredWindowNumber != window.windowNumber else { return }
            configuredWindowNumber = window.windowNumber
            let contentSize = window.contentLayoutRect.size
            if contentSize.width < 700 || contentSize.height < 450 {
                window.setContentSize(NSSize(width: max(700, contentSize.width), height: max(450, contentSize.height)))
            }
        }
    }
}

// MARK: - Settings Visual Primitives

private struct SettingsCard<Content: View>: View {
    let isDark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isDark ? Color(hex: 0x27272B) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(isDark ? 0 : 0.03), radius: 2, x: 0, y: 1)
    }
}

private struct SettingsCardDivider: View {
    let isDark: Bool
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}

private struct SettingsRowIcon: View {
    let icon: String
    let isDark: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(AppPalette.labelSecondary(isDark))
            .frame(width: 22)
    }
}

private struct SettingsActionButton: View {
    let title: String
    let isDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isHovered
                                ? (isDark ? Color(hex: 0x424249) : Color(hex: 0xF7F7FA))
                                : (isDark ? Color(hex: 0x36363C) : Color.white)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(isDark ? 0 : 0.05), radius: 1, x: 0, y: 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(TactilePressButtonStyle())
        .onHover { isHovered = $0 }
    }
}

private struct SettingsSwitchRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    let isDark: Bool
    let accent: Color
    var isDisabled: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon, isDark: isDark)
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 14)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
                .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 11 : 11.5)
        .background(isHovered && !isDisabled ? (isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)) : Color.clear)
        .animation(AppAnimation.micro, value: isHovered)
        .opacity(isDisabled ? 0.48 : 1)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Appearance & Theme Visual Option Cards

private struct AppearanceOptionCard: View {
    let mode: AppAppearanceMode
    let isSelected: Bool
    let isDark: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    switch mode {
                    case .light:
                        windowMockup(darkAppearance: false)
                    case .dark:
                        windowMockup(darkAppearance: true)
                    case .system:
                        GeometryReader { geo in
                            ZStack {
                                windowMockup(darkAppearance: false)
                                    .mask(alignment: .leading) {
                                        Rectangle().frame(width: geo.size.width / 2)
                                    }
                                windowMockup(darkAppearance: true)
                                    .mask(alignment: .trailing) {
                                        Rectangle().frame(width: geo.size.width / 2)
                                    }
                                Rectangle()
                                    .fill(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12))
                                    .frame(width: 0.75)
                            }
                        }
                    }
                }
                .frame(height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.11), lineWidth: 0.5)
                )
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                        .strokeBorder(accent, lineWidth: isSelected ? 2 : 0)
                        .opacity(isSelected ? 1 : 0)
                )
                .scaleEffect(isHovered ? 1.015 : 1.0)

                Text(mode.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(AppAnimation.snappy, value: isHovered)
            .animation(AppAnimation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(mode.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .onHover { isHovered = $0 }
    }

    private func windowMockup(darkAppearance: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 5, height: 5)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 5, height: 5)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppPalette.tabSelectedBackground(darkAppearance))
                    .frame(width: 28, height: 7.5)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 15)
            .background(AppPalette.tabStripBackground(darkAppearance))

            Rectangle()
                .fill(AppPalette.chromeHairline(darkAppearance))
                .frame(height: 0.5)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3.5) {
                    HStack(spacing: 3) {
                        Circle().fill(accent).frame(width: 4, height: 4)
                        Capsule().fill(AppPalette.labelSecondary(darkAppearance).opacity(0.65)).frame(width: 17, height: 2.5)
                    }
                    Capsule().fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45)).frame(width: 19, height: 2.5)
                    Capsule().fill(AppPalette.labelTertiary(darkAppearance).opacity(0.35)).frame(width: 14, height: 2.5)
                    Spacer(minLength: 0)
                }
                .padding(.top, 6)
                .padding(.horizontal, 6)
                .frame(width: 40)
                .frame(maxHeight: .infinity)
                .background(AppPalette.panelBackground(darkAppearance))

                Rectangle()
                    .fill(AppPalette.panelSeparator(darkAppearance))
                    .frame(width: 0.5)

                ZStack {
                    AppPalette.systemBackground(darkAppearance)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(darkAppearance ? Color(hex: 0x242428) : Color.white)
                        .frame(width: 56, height: 34)
                        .shadow(color: Color.black.opacity(darkAppearance ? 0.35 : 0.10), radius: 1.5, x: 0, y: 0.5)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Capsule()
                                    .fill(AppPalette.labelPrimary(darkAppearance).opacity(0.5))
                                    .frame(width: 28, height: 2)
                                Capsule()
                                    .fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45))
                                    .frame(width: 38, height: 1.8)
                                Capsule()
                                    .fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45))
                                    .frame(width: 31, height: 1.8)
                                Capsule()
                                    .fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45))
                                    .frame(width: 35, height: 1.8)
                            }
                            .padding(5.5)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ReadingThemeOptionCard: View {
    let mode: PDFReadingThemeMode
    let useSepiaInLight: Bool
    let isSelected: Bool
    let isDark: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let previewTheme = mode.resolvedTheme(isDark: isDark, useSepiaInLight: useSepiaInLight)
        let lightPreviewTheme: PDFViewTheme = useSepiaInLight ? .sepia : .day

        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if mode == .system {
                        HStack(spacing: 0) {
                            lightPreviewTheme.documentBackgroundColor(isDarkUI: false)
                            PDFViewTheme.night.documentBackgroundColor(isDarkUI: true)
                        }
                        SplitMiniPagePreview(leftTheme: lightPreviewTheme, rightTheme: .night)
                            .frame(width: 30, height: 40)
                    } else {
                        previewTheme.documentBackgroundColor(isDarkUI: isDark)
                        MiniPagePreview(theme: previewTheme)
                            .frame(width: 30, height: 40)
                    }
                }
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.11), lineWidth: 0.5)
                )
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                        .strokeBorder(accent, lineWidth: isSelected ? 2 : 0)
                        .opacity(isSelected ? 1 : 0)
                )
                .scaleEffect(isHovered ? 1.015 : 1.0)

                Text(mode.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(AppAnimation.snappy, value: isHovered)
            .animation(AppAnimation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(mode.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .onHover { isHovered = $0 }
    }
}

/// Accent color picker: the selected name sits beside the label and the swatches spread evenly across
/// the full row width, instead of being crammed into the trailing edge of a labeled row.
private struct AccentColorRow: View {
    @ObservedObject var store: AppStore
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(L10n.tr("强调色", "Accent Color"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                Spacer(minLength: 0)
                Text(store.accentColor.title)
                    .font(.system(size: 12))
                    .foregroundColor(AppPalette.labelSecondary(isDark))
            }
            HStack(spacing: 0) {
                ForEach(AppAccentColor.allCases) { preset in
                    AccentSwatchButton(preset: preset, isSelected: store.accentColor == preset) {
                        store.accentColor = preset
                    }
                    if preset != AppAccentColor.allCases.last {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// One preset accent color in the Settings swatch row; a gapped ring + checkmark marks the active choice.
private struct AccentSwatchButton: View {
    let preset: AppAccentColor
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let swatchColor = preset.color(isDark: colorScheme == .dark)
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(swatchColor, lineWidth: 1.5)
                    .frame(width: 28, height: 28)
                    .opacity(isSelected ? 1 : 0)
                Circle()
                    .fill(swatchColor)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.25), lineWidth: 0.5)
                    )
                    .frame(width: 19, height: 19)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.28), radius: 0.5, x: 0, y: 0.5)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
        .help(preset.title)
        .accessibilityLabel(Text(preset.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .onHover { isHovered = $0 }
        .animation(AppAnimation.micro, value: isHovered)
        .animation(AppAnimation.micro, value: isSelected)
    }
}
