import AppKit
import SwiftUI

@MainActor
final class ReaderUpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let alert = NSAlert()
            do {
                switch try await ReaderReleaseService.check(currentVersion: currentVersion) {
                case .available(let version, let releaseURL):
                    alert.messageText = L10n.tr("发现新版本", "An Update Is Available")
                    alert.informativeText = "Expert PDF Reader \(version)\n"
                        + L10n.tr("当前版本：", "Installed version: ") + currentVersion + "\n\n"
                        + L10n.tr("前往发布页查看更新说明并下载安装。", "Visit the release page for details and to download the update.")
                    alert.addButton(withTitle: L10n.tr("查看更新", "View Update"))
                    alert.addButton(withTitle: L10n.tr("稍后", "Later"))
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releaseURL) }
                    return
                case .current:
                    alert.messageText = L10n.tr("暂无更新", "You're Up to Date")
                    alert.informativeText = L10n.tr("当前版本：", "Installed version: ") + currentVersion
                case .noRelease:
                    alert.messageText = L10n.tr("暂无正式发布版本", "No Release Is Available Yet")
                    alert.informativeText = L10n.tr("请稍后再检查更新。", "Please check again later.")
                }
            } catch {
                alert.alertStyle = .warning
                alert.messageText = L10n.tr("无法检查更新", "Unable to Check for Updates")
                if case ReaderUpdateError.rateLimited = error {
                    alert.informativeText = L10n.tr("检查过于频繁，请稍后重试。", "Too many update checks. Please try again later.")
                } else {
                    alert.informativeText = L10n.tr("请检查网络连接，稍后重试。", "Check your internet connection and try again later.")
                }
            }
            alert.addButton(withTitle: L10n.tr("好", "OK"))
            alert.runModal()
        }
    }
}

struct ReaderUpdateCommands: Commands {
    @ObservedObject var checker: ReaderUpdateChecker

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(checker.isChecking ? L10n.tr("正在检查更新…", "Checking for Updates…") : L10n.tr("检查更新…", "Check for Updates…")) {
                checker.checkForUpdates()
            }
            .disabled(checker.isChecking)
            Divider()
        }
    }
}
