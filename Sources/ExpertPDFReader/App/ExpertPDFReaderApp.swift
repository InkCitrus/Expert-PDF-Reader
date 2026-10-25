import AppKit
import SwiftUI

public final class ExpertPDFReaderAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore? {
        didSet { openPendingURLs() }
    }

    /// Files handed to the app before the window has set `store` (e.g. double-clicking a PDF in Finder
    /// while the app is not running); opened as soon as `store` is available.
    private var pendingURLs: [URL] = []
    private var keyMonitor: Any?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // The app draws its own tab strip; macOS window tabs would add a second tab bar and
        // duplicate Show Next / Previous Tab, Merge All Windows, … in the View and Window menus
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let store = self?.store else { return false }
                // ⌘= zooms in like the menu's ⌘+, which needs Shift on many keyboard layouts
                if modifiers == .command, event.charactersIgnoringModifiers == "=" {
                    guard let tab = store.activeDocumentTab else { return false }
                    tab.triggerZoom(.zoomIn)
                    return true
                }
                // ⌃⇥ / ⌃⇧⇥ switch tabs as in Safari and Finder (the Go menu shows ⇧⌘] / ⇧⌘[)
                if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] {
                    if modifiers.contains(.shift) {
                        store.selectPreviousTab()
                    } else {
                        store.selectNextTab()
                    }
                    return true
                }
                return false
            }
            return handled ? nil : event
        }

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

    /// Stays open without a window like Preview (a single `Window` scene would quit when it closes);
    /// opening a PDF or clicking the Dock icon brings the window back.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.saveSession()
        }
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
        // A single window: a `WindowGroup` opened (and restored on launch) one more window, mirroring the
        // same tabs, for every PDF opened from Finder while the app was running
        Window("Expert PDF Reader", id: "main") {
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
            ReaderMenuCommands(store: store)
        }

        Settings {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Main Menu Commands (localized through L10n)

struct ReaderMenuCommands: Commands {
    @ObservedObject var store: AppStore

    private static let projectURL = URL(string: "https://github.com/InkCitrus/Expert-PDF-Reader")!

    var body: some Commands {
        // File Menu
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("打开...", "Open...")) {
                store.openFilePicker()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Menu(L10n.tr("打开最近使用", "Open Recent")) {
                ForEach(store.recentDocuments.prefix(10)) { item in
                    Button(item.title) {
                        store.openDocument(at: item.url)
                    }
                }
                if !store.recentDocuments.isEmpty {
                    Divider()
                }
                Button(L10n.tr("清除菜单", "Clear Menu")) {
                    store.clearAllRecents()
                }
                .disabled(store.recentDocuments.isEmpty)
            }

            Button(L10n.tr("新建主页标签", "New Home Tab")) {
                store.openNewHomeTab()
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button(L10n.tr("重新打开关闭的标签", "Reopen Closed Tab")) {
                store.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(store.closedDocumentURLs.isEmpty)
        }

        // Replaces File › Close / Close All, whose ⌘W clashed with Close Tab
        CommandGroup(replacing: .saveItem) {
            Button(L10n.tr("关闭标签", "Close Tab")) {
                closeTabOrWindow()
            }
            .keyboardShortcut("w", modifiers: [.command])

            Button(L10n.tr("关闭窗口", "Close Window")) {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // View Menu: the reader's commands join the system View menu (above Enter Full Screen)
        // instead of a second menu titled View
        CommandGroup(before: .toolbar) {
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

            // Pickers render as submenus with a checkmark on the current choice. Their items keep the old
            // language after a live switch unless rebuilt, hence an id that changes with the language.
            Picker(L10n.tr("主题", "Theme"), selection: $store.readingThemeMode) {
                ForEach(PDFReadingThemeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .id("theme.\(store.appLanguage.rawValue)")

            Toggle(L10n.tr("浅色时使用纸质替代日间", "Use Sepia Instead of Day in Light Mode"), isOn: $store.useSepiaForLightSystemTheme)

            Picker(L10n.tr("界面外观", "App Appearance"), selection: $store.appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .id("appearance.\(store.appLanguage.rawValue)")

            Picker(L10n.tr("语言", "Language"), selection: $store.appLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.title).tag(lang)
                }
            }
            .id("language.\(store.appLanguage.rawValue)")

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

            // Detected from the PDF or its printed page numbers; chosen here only when that gets a book wrong
            Picker(L10n.tr("翻页方向", "Page Direction"), selection: Binding(
                get: { store.activeDocumentTab?.pageDirection ?? .automatic },
                set: { store.activeDocumentTab?.pageDirection = $0 }
            )) {
                ForEach(PageDirection.allCases) { direction in
                    Text(direction.title(detectedRightToLeft: store.activeDocumentTab?.detectedRightToLeft ?? false))
                        .tag(direction)
                }
            }
            .id("pageDirection.\(store.appLanguage.rawValue)")
            .disabled(store.activeDocumentTab == nil)

            Button(store.activeDocumentTab?.isClearMarginsEnabled == true ? L10n.tr("恢复页面空白边", "Restore Page Margins") : L10n.tr("清除空白边", "Clear Margins")) {
                guard let tab = store.activeDocumentTab else { return }
                tab.isClearMarginsEnabled.toggle()
                tab.applyClearMarginsIfNeeded()
            }
            .keyboardShortcut("m", modifiers: [.shift, .command])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Split View Submenu
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

            Divider()
        }

        // Go Menu
        CommandMenu(L10n.tr("前往", "Go")) {
            // ←/→ also turn pages (handled by the reader so text fields keep the arrow keys); the menu shows ⌥↑ / ⌥↓
            Button(L10n.tr("上一页", "Previous Page")) {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(tab.currentPageIndex - 1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .disabled(store.activeDocumentTab == nil)

            Button(L10n.tr("下一页", "Next Page")) {
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

            Button(L10n.tr("前往页码…", "Go to Page…")) {
                store.activeDocumentTab?.goToPageRequestToken &+= 1
            }
            .keyboardShortcut("g", modifiers: [.option, .command])
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

        // Help Menu: the built-in Reading Guide instead of "Help isn't available"
        CommandGroup(replacing: .help) {
            Button(L10n.tr("阅读指南", "Reading Guide")) {
                store.openGettingStartedGuide()
            }
            .keyboardShortcut("?", modifiers: [.command])

            Button(L10n.tr("在 GitHub 上查看 Expert PDF Reader", "Expert PDF Reader on GitHub")) {
                NSWorkspace.shared.open(Self.projectURL)
            }
        }
    }

    /// ⌘W closes the selected document tab; on the Home tab, and in other windows such as Settings,
    /// it closes the window, like closing the last tab in Safari
    private func closeTabOrWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if window === WindowChromeView.readerWindow, store.activeDocumentTab != nil {
            store.closeCurrentTab()
        } else {
            window.performClose(nil)
        }
    }
}
