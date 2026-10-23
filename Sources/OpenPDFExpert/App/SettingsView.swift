import SwiftUI

/// `Settings` scene (⌘,), also reachable from the Home sidebar's 设置 row via `SettingsLink`.
struct SettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Picker("界面外观", selection: $store.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Picker("阅读主题", selection: $store.pdfTheme) {
                    ForEach([PDFViewTheme.day, .sepia, .night]) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            } footer: {
                Text("界面外观决定标签栏、工具栏与面板的配色；阅读主题通过 GPU 着色器作用于 PDF 页面本身。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
