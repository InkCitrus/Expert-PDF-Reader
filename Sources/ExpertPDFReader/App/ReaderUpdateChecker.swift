import AppKit
import SwiftUI

@MainActor
final class ReaderUpdateChecker: NSObject, ObservableObject {
    @Published private(set) var isChecking = false
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let session: URLSession
    private var checkTask: Task<Void, Never>?
    private var progressAlert: NSAlert?
    private var generation = 0

    init(session: URLSession = .shared) {
        self.session = session
        super.init()
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        generation += 1
        let requestGeneration = generation
        let progress = NSAlert()
        progress.icon = NSApp.applicationIconImage
        progress.messageText = L10n.tr("正在检查更新…", "Checking for Updates…")
        progress.window.title = L10n.tr("更新 Expert PDF Reader", "Updating Expert PDF Reader")
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 12))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        progress.accessoryView = indicator
        let cancel = progress.addButton(withTitle: L10n.tr("取消", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelCheck)
        progress.layout()
        progressAlert = progress
        progress.window.center()
        progress.window.makeKeyAndOrderFront(nil)
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ReaderReleaseService.check(currentVersion: currentVersion, session: session)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                finishChecking()
                let alert = NSAlert()
                alert.icon = NSApp.applicationIconImage
                switch result {
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
                    alert.informativeText = String(format: L10n.tr("Expert PDF Reader %@ 已是最新版本。", "Expert PDF Reader %@ is currently the newest version available."), currentVersion)
                case .noRelease:
                    alert.messageText = L10n.tr("暂无正式发布版本", "No Release Is Available Yet")
                    alert.informativeText = L10n.tr("请稍后再检查更新。", "Please check again later.")
                }
                alert.addButton(withTitle: L10n.tr("好", "OK"))
                alert.runModal()
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                finishChecking()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.tr("无法检查更新", "Unable to Check for Updates")
                if case ReaderUpdateError.rateLimited = error {
                    alert.informativeText = L10n.tr("检查过于频繁，请稍后重试。", "Too many update checks. Please try again later.")
                } else {
                    alert.informativeText = L10n.tr("请检查网络连接，稍后重试。", "Check your internet connection and try again later.")
                }
                alert.addButton(withTitle: L10n.tr("好", "OK"))
                alert.runModal()
            }
        }
    }

    @objc func cancelCheck() {
        generation += 1
        checkTask?.cancel()
        finishChecking()
    }

    private func finishChecking() {
        progressAlert?.window.close()
        progressAlert = nil
        checkTask = nil
        isChecking = false
    }
}

struct ReaderUpdateCommands: Commands {
    @ObservedObject var checker: ReaderUpdateChecker

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.tr("关于 Expert PDF Reader", "About Expert PDF Reader")) {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let credits = NSMutableAttributedString(string: L10n.tr("原生 macOS PDF 阅读器", "A native PDF reader for macOS.") + "\n\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style])
                credits.append(NSAttributedString(string: "github.com/InkCitrus/Expert-PDF-Reader",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .link: ReaderReleaseService.projectURL, .paragraphStyle: style]))
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
        }
        CommandGroup(after: .appInfo) {
            Button(checker.isChecking ? L10n.tr("正在检查更新…", "Checking for Updates…") : L10n.tr("检查更新…", "Check for Updates…")) {
                checker.checkForUpdates()
            }
            .disabled(checker.isChecking)
            Divider()
        }
    }
}
