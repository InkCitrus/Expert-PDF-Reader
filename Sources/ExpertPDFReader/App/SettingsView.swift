import SwiftUI

/// `Settings` scene (⌘,), also reachable from the Home sidebar's 设置 / Settings row via `SettingsLink`.
struct SettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("语言", "Language"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }

                Picker(L10n.tr("界面外观", "App Appearance"), selection: $store.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Picker(L10n.tr("阅读主题", "Reading Theme"), selection: $store.readingThemeMode) {
                    ForEach(PDFReadingThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle(L10n.tr("浅色时使用纸质替代日间", "Use Sepia Instead of Day in Light Mode"), isOn: $store.useSepiaForLightSystemTheme)
            } footer: {
                Text(L10n.tr(
                    "界面外观决定标签栏、工具栏与面板的配色；阅读主题通过 GPU 着色器作用于 PDF 页面本身。当阅读主题设为“跟随系统”时，浅色模式默认使用日间主题（或开启上方选项后使用纸质主题），深色模式自动切换为夜间主题。",
                    "App Appearance controls the tab bar, toolbar, and sidebar colors; Reading Theme applies GPU shaders to the PDF page itself. When Reading Theme is set to Follow System, Light mode uses Day (or Sepia when enabled above) and Dark mode automatically switches to Night."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
