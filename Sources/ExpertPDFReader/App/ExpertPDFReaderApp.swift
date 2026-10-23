import AppKit
import SwiftUI

public final class ExpertPDFReaderAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore? {
        didSet { openPendingURLs() }
    }

    /// Files handed to the app before the window has set `store` (e.g. double-clicking a PDF in Finder
    /// while the app is not running); opened as soon as `store` is available.
    private var pendingURLs: [URL] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Open any PDF file paths passed via command-line arguments
        let args = Array(CommandLine.arguments.dropFirst())
        for arg in args where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            if url.pathExtension.lowercased() == "pdf",
               FileManager.default.fileExists(atPath: url.path) {
                pendingURLs.append(url)
            }
        }
        openPendingURLs()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        openPendingURLs()
    }

    private func openPendingURLs() {
        guard let store, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        Task { @MainActor in
            store.openDocuments(at: urls)
        }
    }
}

@main
public struct ExpertPDFReaderApp: App {
    @NSApplicationDelegateAdaptor(ExpertPDFReaderAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    public init() {}

    public var body: some Scene {
        WindowGroup("Expert PDF Reader") {
            MainWindowView(store: store)
                .onAppear {
                    appDelegate.store = store
                    store.applyAppAppearance()
                }
                .onOpenURL { url in
                    store.openDocument(at: url)
                }
        }
        // Title bar is drawn by MainWindowView's unified tab strip (WindowChromeConfigurator)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            PDFExpertMenuCommands(store: store)
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

// MARK: - MainMenu Commands (Localized zh-Hans / en)

struct PDFExpertMenuCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        // File Menu Additions
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("打开...", "Open...")) {
                store.openFilePicker()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button(L10n.tr("新建主页标签", "New Home Tab")) {
                store.openNewHomeTab()
            }
            .keyboardShortcut("t", modifiers: [.command])

            Divider()

            Button(L10n.tr("关闭标签", "Close Tab")) {
                store.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
        }

        // View Menu (视图 / View)
        CommandMenu(L10n.tr("视图", "View")) {
            Button(store.activeDocumentTab?.isLeftSidebarVisible == true ? L10n.tr("隐藏左边面板", "Hide Left Panel") : L10n.tr("显示左边面板", "Show Left Panel")) {
                guard let tab = store.activeDocumentTab else { return }
                if tab.isLeftSidebarVisible {
                    tab.isLeftSidebarVisible = false
                } else {
                    tab.toggleLeftPanel(.documentSummary)
                }
            }
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(store.activeDocumentTab?.isPageOverviewVisible == true ? L10n.tr("关闭页面概览", "Close Page Overview") : L10n.tr("页面概览", "Page Overview")) {
                store.activeDocumentTab?.isPageOverviewVisible.toggle()
            }
            .keyboardShortcut("1", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("缩略图", "Thumbnails")) {
                store.activeDocumentTab?.showSidebarTab(.thumbnails)
            }
            .keyboardShortcut("2", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("大纲", "Outline")) {
                store.activeDocumentTab?.showSidebarTab(.outline)
            }
            .keyboardShortcut("3", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("书签", "Bookmarks")) {
                store.activeDocumentTab?.showSidebarTab(.bookmarks)
            }
            .keyboardShortcut("4", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("显示选项", "View Settings")) {
                store.activeDocumentTab?.toggleLeftPanel(.viewSettings)
            }
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Theme Submenu (主题 -> 跟随系统 / 日间 / 纸质 / 夜间 + 浅色时使用纸质替代日间)
            Menu(L10n.tr("主题", "Theme")) {
                ForEach(PDFReadingThemeMode.allCases) { mode in
                    Button {
                        store.readingThemeMode = mode
                    } label: {
                        HStack {
                            if store.readingThemeMode == mode {
                                Image(systemName: "checkmark")
                            }
                            Text(mode.title)
                        }
                    }
                }

                Divider()

                Toggle(L10n.tr("浅色时使用纸质替代日间", "Use Sepia in Light Mode"), isOn: $store.useSepiaForLightSystemTheme)
            }

            // App UI Appearance Submenu
            Menu(L10n.tr("界面外观", "Appearance")) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Button {
                        store.appearanceMode = mode
                    } label: {
                        HStack {
                            if store.appearanceMode == mode {
                                Image(systemName: "checkmark")
                            }
                            Text(mode.title)
                        }
                    }
                }
            }

            // Language Submenu
            Menu(L10n.tr("语言", "Language")) {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        store.appLanguage = lang
                    } label: {
                        HStack {
                            if store.appLanguage == lang {
                                Image(systemName: "checkmark")
                            }
                            Text(lang.title)
                        }
                    }
                }
            }

            Divider()

            // Page Layout Modes
            Button(L10n.tr("单页", "Single Page")) {
                store.activeDocumentTab?.layoutMode = .singlePage
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("双页", "Two Pages")) {
                store.activeDocumentTab?.layoutMode = .twoPages
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("双页（首屏单页显示）", "Two Pages (Single Cover)")) {
                store.activeDocumentTab?.layoutMode = .twoPagesCover
            }
            .keyboardShortcut("3", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(store.activeDocumentTab?.isClearMarginsEnabled == true ? L10n.tr("恢复页面空白边", "Restore Page Margins") : L10n.tr("清除空白边", "Clear Margins")) {
                guard let tab = store.activeDocumentTab else { return }
                tab.isClearMarginsEnabled.toggle()
                tab.applyClearMarginsIfNeeded()
            }
            .keyboardShortcut("m", modifiers: [.shift, .command])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Split View Submenu (分屏视图 / Split View)
            Menu(L10n.tr("分屏视图", "Split View")) {
                Button(L10n.tr("禁用分屏视图", "Disable Split View")) {
                    store.activeDocumentTab?.splitMode = .disabled
                }
                Button(L10n.tr("垂直分屏（左右）", "Vertical Split (Left/Right)")) {
                    store.activeDocumentTab?.splitMode = .vertical
                }
                Button(L10n.tr("水平分屏（上下）", "Horizontal Split (Top/Bottom)")) {
                    store.activeDocumentTab?.splitMode = .horizontal
                }
                Divider()
                Button(L10n.tr("对调位置", "Swap Panes")) {
                    store.activeDocumentTab?.isSplitSwapped.toggle()
                }
                .disabled(store.activeDocumentTab?.splitMode == .disabled)
                Button(store.activeDocumentTab?.syncScrollAndZoom == true ? L10n.tr("取消同步滚动和缩放", "Disable Sync Scroll & Zoom") : L10n.tr("同步滚动和缩放", "Sync Scroll & Zoom")) {
                    store.activeDocumentTab?.syncScrollAndZoom.toggle()
                }
                .disabled(store.activeDocumentTab?.splitMode == .disabled)
            }
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Zoom Controls
            Button(L10n.tr("放大", "Zoom In")) {
                store.activeDocumentTab?.triggerZoom(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("缩小", "Zoom Out")) {
                store.activeDocumentTab?.triggerZoom(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("实际大小", "Actual Size")) {
                store.activeDocumentTab?.triggerZoom(.actualSize)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("缩放至适应宽度", "Zoom to Fit Width")) {
                store.activeDocumentTab?.triggerZoom(.fitWidth)
            }
            .keyboardShortcut("8", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("缩放至适应页面", "Zoom to Fit Page")) {
                store.activeDocumentTab?.triggerZoom(.fitPage)
            }
            .keyboardShortcut("9", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)
        }

        // Go Menu (前往 / Go)
        CommandMenu(L10n.tr("前往", "Go")) {
            Button(L10n.tr("上一页 (←)", "Previous Page (←)")) {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(tab.currentPageIndex - 1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("下一页 (→)", "Next Page (→)")) {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(tab.currentPageIndex + 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.option])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("第一页", "First Page")) {
                store.activeDocumentTab?.navigateToPage(0)
            }
            .keyboardShortcut(.home, modifiers: [])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("最后一页", "Last Page")) {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(max(0, tab.pageCount - 1))
            }
            .keyboardShortcut(.end, modifiers: [])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            Button(L10n.tr("返回", "Back")) {
                store.activeDocumentTab?.goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(store.activeDocumentTab?.canGoBack != true)

            Button(L10n.tr("前进", "Forward")) {
                store.activeDocumentTab?.goForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(store.activeDocumentTab?.canGoForward != true)

            Divider()

            Button(L10n.tr("为当前页添加/移除书签", "Toggle Bookmark for Current Page")) {
                guard let tab = store.activeDocumentTab else { return }
                store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            Button(L10n.tr("全文查找...", "Find in Document...")) {
                store.activeDocumentTab?.beginSearch()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("查找下一个", "Find Next")) {
                store.activeDocumentTab?.selectNextSearchMatch()
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(store.activeDocumentTab?.searchMatches.isEmpty != false)

            Button(L10n.tr("查找上一个", "Find Previous")) {
                store.activeDocumentTab?.selectPreviousSearchMatch()
            }
            .keyboardShortcut("g", modifiers: [.shift, .command])
            .disabled(store.activeDocumentTab?.searchMatches.isEmpty != false)

            Divider()

            Button(L10n.tr("显示下一标签", "Show Next Tab")) {
                store.selectNextTab()
            }
            .keyboardShortcut("}", modifiers: [.shift, .command])

            Button(L10n.tr("显示上一标签", "Show Previous Tab")) {
                store.selectPreviousTab()
            }
            .keyboardShortcut("{", modifiers: [.shift, .command])
        }
    }
}
