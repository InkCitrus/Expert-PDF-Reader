import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("通用", "General")
        case .appearance: return L10n.tr("外观", "Appearance")
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        }
    }
}

/// `Settings` scene (⌘,), also reachable from the Home sidebar's 设置 / Settings row via `SettingsLink`.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: SettingsTab = .general
    @Namespace private var tabNamespace

    private var isDark: Bool { colorScheme == .dark }
    private var accent: Color { store.accentColor.color(isDark: isDark) }
    private var tabSwitchAnimation: Animation {
        AppAnimation.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.22, bounce: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            SettingsCardDivider(isDark: isDark)

            // Fixed-height clipped container prevents NSWindow resize bounce when switching tabs.
            ZStack(alignment: .top) {
                if selectedTab == .general {
                    generalTab
                        .transition(AppAnimation.reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -18)))
                } else {
                    appearanceTab
                        .transition(AppAnimation.reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 18)))
                }
            }
            .frame(width: 520, height: 424, alignment: .top)
            .clipped()
            .id(store.appLanguage)
        }
        .frame(width: 520)
        .background(AppPalette.panelBackground(isDark))
        .environment(\.appAccentColor, accent)
        .onAppear { store.refreshDefaultPDFApp() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDefaultPDFApp()
        }
    }

    private var headerBar: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        guard selectedTab != tab else { return }
                        withAnimation(tabSwitchAnimation) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(isSelected ? accent : AppPalette.labelSecondary(isDark))
                            Text(tab.title)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(AppPalette.segmentedThumb(isDark))
                                    .shadow(color: Color.black.opacity(isDark ? 0.30 : 0.08), radius: 1.5, x: 0, y: 0.5)
                                    .matchedGeometryEffect(id: "settingsTabThumb", in: tabNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppPalette.segmentedTrack(isDark))
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard(isDark: isDark) {
                defaultAppRow
                SettingsCardDivider(isDark: isDark, leadingInset: 50)
                languageRow

                if store.menuBarNeedsRestartForLanguage {
                    SettingsCardDivider(isDark: isDark, leadingInset: 50)
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
                SettingsCardDivider(isDark: isDark, leadingInset: 50)
                SettingsSwitchRow(
                    icon: "number.square",
                    title: L10n.tr("始终显示页码浮窗", "Always Show Page Counter"),
                    isOn: $store.alwaysShowPageIndicator,
                    isDark: isDark,
                    accent: accent
                )
            }

            Spacer(minLength: 12)

            Text(versionCaption)
                .font(.system(size: 11))
                .foregroundColor(AppPalette.labelQuaternary(isDark))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var defaultAppRow: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: "doc.richtext", isDark: isDark)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("默认 PDF 应用", "Default PDF App"))
                    .font(.system(size: 13))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                if !store.isDefaultPDFApp, let appName = store.defaultPDFAppName {
                    Text(L10n.defaultPDFAppNote(appName))
                        .font(.system(size: 11))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if store.isDefaultPDFApp {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                    Text("Expert PDF Reader")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppPalette.labelSecondary(isDark))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(AppPalette.segmentedTrack(isDark))
                )
            } else {
                SettingsActionButton(title: L10n.tr("设为默认", "Make Default"), isDark: isDark) {
                    store.makeDefaultPDFApp()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: "globe", isDark: isDark)
            Text(L10n.tr("语言", "Language"))
                .font(.system(size: 13))
                .foregroundColor(AppPalette.labelPrimary(isDark))
            Spacer(minLength: 12)
            Picker("", selection: $store.appLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.title).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170, alignment: .trailing)
            .id("language.\(store.appLanguage.rawValue)")
            .accessibilityLabel(Text(L10n.tr("语言", "Language")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var restartNoteRow: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsRowIcon(icon: "arrow.clockwise.circle", isDark: isDark)
            Text(L10n.tr("重启后生效于菜单栏。", "Restart to update the menu bar."))
                .font(.system(size: 12))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .lineLimit(1)
            Spacer(minLength: 8)
            SettingsActionButton(title: L10n.tr("立即重新启动", "Restart Now"), isDark: isDark) {
                store.relaunchApp()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var versionCaption: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return "Expert PDF Reader \(version)"
        }
        return "Expert PDF Reader"
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(isDark: isDark) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("界面外观", "App Appearance"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppPalette.labelPrimary(isDark))

                    HStack(spacing: 10) {
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
                .padding(.vertical, 11)

                SettingsCardDivider(isDark: isDark)

                AccentColorRow(store: store, isDark: isDark, accent: accent)
                    .id("accent.\(store.appLanguage.rawValue)")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }

            VStack(alignment: .leading, spacing: 6) {
                SettingsCard(isDark: isDark) {
                    VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.vertical, 11)

                    SettingsCardDivider(isDark: isDark, leadingInset: 50)

                    SettingsSwitchRow(
                        icon: "scroll",
                        title: L10n.tr("浅色模式改用纸质", "Use Sepia in Light Mode"),
                        isOn: $store.useSepiaForLightSystemTheme,
                        isDark: isDark,
                        accent: accent,
                        isDisabled: store.readingThemeMode != .system
                    )
                }

                Text(L10n.tr(
                    "外观控制窗口配色，主题控制页面配色。",
                    "Appearance styles the window; theme styles PDF pages."
                ))
                .font(.system(size: 11))
                .foregroundColor(AppPalette.labelTertiary(isDark))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                .fill(AppPalette.panelListBackground(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
        )
    }
}

private struct SettingsCardDivider: View {
    let isDark: Bool
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(AppPalette.panelSeparator(isDark))
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

private struct SettingsRowIcon: View {
    let icon: String
    let isDark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppPalette.segmentedTrack(isDark))
                .frame(width: 26, height: 26)
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(AppPalette.labelSecondary(isDark))
        }
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
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppPalette.toolbarHover(isDark) : AppPalette.toolbarControlFill(isDark))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(AppAnimation.micro, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SettingsSwitchRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    let isDark: Bool
    let accent: Color
    var isDisabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon, isDark: isDark)
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(AppPalette.labelPrimary(isDark))
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
                .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .opacity(isDisabled ? 0.48 : 1)
        .disabled(isDisabled)
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
            VStack(spacing: 5) {
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
                                    .fill(AppPalette.panelSeparator(isDark))
                                    .frame(width: 1)
                            }
                        }
                    }
                }
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? accent : AppPalette.panelSeparator(isDark),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .shadow(color: Color.black.opacity(isHovered ? (isDark ? 0.25 : 0.08) : 0), radius: 4, x: 0, y: 2)

                HStack(spacing: 4) {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .lineLimit(1)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(accent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
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
            HStack(spacing: 2.5) {
                Circle().fill(Color(hex: 0xFF5F57)).frame(width: 4.5, height: 4.5)
                Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 4.5, height: 4.5)
                Circle().fill(Color(hex: 0x28C840)).frame(width: 4.5, height: 4.5)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppPalette.tabSelectedBackground(darkAppearance))
                    .frame(width: 24, height: 6.5)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 12)
            .background(AppPalette.tabStripBackground(darkAppearance))

            Rectangle()
                .fill(AppPalette.chromeHairline(darkAppearance))
                .frame(height: 0.5)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2.5) {
                        Circle().fill(accent).frame(width: 3.5, height: 3.5)
                        Capsule().fill(AppPalette.labelSecondary(darkAppearance).opacity(0.65)).frame(width: 14, height: 2.5)
                    }
                    Capsule().fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45)).frame(width: 16, height: 2.5)
                    Capsule().fill(AppPalette.labelTertiary(darkAppearance).opacity(0.35)).frame(width: 12, height: 2.5)
                    Spacer(minLength: 0)
                }
                .padding(.top, 4.5)
                .padding(.horizontal, 5)
                .frame(width: 34)
                .frame(maxHeight: .infinity)
                .background(AppPalette.panelBackground(darkAppearance))

                Rectangle()
                    .fill(AppPalette.panelSeparator(darkAppearance))
                    .frame(width: 0.5)

                ZStack {
                    AppPalette.systemBackground(darkAppearance)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(darkAppearance ? Color(hex: 0x242428) : Color.white)
                        .frame(width: 46, height: 24)
                        .shadow(color: Color.black.opacity(darkAppearance ? 0.35 : 0.10), radius: 1, x: 0, y: 0.5)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 2.5) {
                                Capsule()
                                    .fill(AppPalette.labelPrimary(darkAppearance).opacity(0.5))
                                    .frame(width: 22, height: 2)
                                Capsule()
                                    .fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45))
                                    .frame(width: 30, height: 1.5)
                                Capsule()
                                    .fill(AppPalette.labelTertiary(darkAppearance).opacity(0.45))
                                    .frame(width: 26, height: 1.5)
                            }
                            .padding(4.5)
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
            VStack(spacing: 5) {
                ZStack {
                    if mode == .system {
                        HStack(spacing: 0) {
                            lightPreviewTheme.documentBackgroundColor(isDarkUI: false)
                            PDFViewTheme.night.documentBackgroundColor(isDarkUI: true)
                        }
                        SplitMiniPagePreview(leftTheme: lightPreviewTheme, rightTheme: .night)
                            .frame(width: 26, height: 34)
                    } else {
                        previewTheme.documentBackgroundColor(isDarkUI: isDark)
                        MiniPagePreview(theme: previewTheme)
                            .frame(width: 26, height: 34)
                    }
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? accent : AppPalette.panelSeparator(isDark),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .shadow(color: Color.black.opacity(isHovered ? (isDark ? 0.25 : 0.08) : 0), radius: 4, x: 0, y: 2)

                HStack(spacing: 4) {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? AppPalette.labelPrimary(isDark) : AppPalette.labelSecondary(isDark))
                        .lineLimit(1)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(accent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
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
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
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

/// One preset accent color in the Settings swatch row; a ring + checkmark marks the active choice.
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
                    .frame(width: 30, height: 30)
                    .opacity(isSelected ? 1 : 0)
                Circle()
                    .fill(swatchColor)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .frame(width: 20, height: 20)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.28), radius: 0.5, x: 0, y: 0.5)
                }
            }
            .frame(width: 30, height: 30)
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
