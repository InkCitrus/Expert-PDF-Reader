import AppKit
import SwiftUI

/// `Settings` scene (⌘,), also reachable from the Home sidebar's 设置 / Settings row via `SettingsLink`.
struct SettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.tr("默认 PDF 应用", "Default PDF App")) {
                    if store.isDefaultPDFApp {
                        Label("Expert PDF Reader", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(L10n.tr("设为默认", "Make Default")) {
                            store.makeDefaultPDFApp()
                        }
                    }
                }

                Picker(L10n.tr("语言", "Language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                .id("language.\(store.appLanguage.rawValue)")

                if store.menuBarNeedsRestartForLanguage {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(L10n.tr("重新启动后，由 macOS 提供的菜单（文件、编辑、窗口等）也会切换到所选语言。", "Menus provided by macOS (File, Edit, Window…) switch to this language after a restart."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L10n.tr("立即重新启动", "Restart Now")) {
                            store.relaunchApp()
                        }
                    }
                }

                Toggle(L10n.tr("启动时恢复标签页", "Restore Tabs on Launch"), isOn: $store.restoreTabsOnLaunch)
            } header: {
                Text(L10n.tr("通用", "General"))
            } footer: {
                Group {
                    if store.isDefaultPDFApp {
                        Text(L10n.tr("在 Finder 中双击 PDF 文件会用 Expert PDF Reader 打开。", "Double-clicking a PDF in Finder opens it in Expert PDF Reader."))
                    } else if let appName = store.defaultPDFAppName {
                        Text(L10n.defaultPDFAppNote(appName))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                Picker(L10n.tr("界面外观", "App Appearance"), selection: $store.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .id("appearance.\(store.appLanguage.rawValue)")

                AccentColorRow(store: store)
                    .id("accent.\(store.appLanguage.rawValue)")

                Picker(L10n.tr("阅读主题", "Reading Theme"), selection: $store.readingThemeMode) {
                    ForEach(PDFReadingThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .id("theme.\(store.appLanguage.rawValue)")

                Toggle(L10n.tr("浅色时使用纸质替代日间", "Use Sepia Instead of Day in Light Mode"), isOn: $store.useSepiaForLightSystemTheme)
                    .disabled(store.readingThemeMode != .system)
            } header: {
                Text(L10n.tr("外观", "Appearance"))
            } footer: {
                Text(L10n.tr(
                    "界面外观决定标签栏、工具栏与面板的配色；阅读主题通过 GPU 着色器作用于 PDF 页面本身。“跟随系统”会在浅色模式使用日间（或纸质）主题，深色模式自动切换为夜间主题。",
                    "App Appearance colors the tab bar, toolbar, and panels; Reading Theme applies GPU shaders to the PDF page itself. Follow System uses Day (or Sepia) in Light mode and switches to Night in Dark mode."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Sized to its content instead of a tall window with empty space below the form
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 480)
        .onAppear { store.refreshDefaultPDFApp() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDefaultPDFApp()
        }
    }
}

/// Accent color picker: the selected name sits beside the label and the swatches spread evenly across
/// the full row width, instead of being crammed into the trailing edge of a labeled row.
private struct AccentColorRow: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.tr("强调色", "Accent Color"))
                Spacer(minLength: 0)
                Text(store.accentColor.title)
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
    }
}

/// One preset accent color in the Settings swatch row; a ring + checkmark marks the active choice.
private struct AccentSwatchButton: View {
    let preset: AppAccentColor
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(preset.color, lineWidth: 1.5)
                    .frame(width: 28, height: 28)
                    .opacity(isSelected ? 1 : 0)
                Circle()
                    .fill(preset.color)
                    .frame(width: 18, height: 18)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
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
