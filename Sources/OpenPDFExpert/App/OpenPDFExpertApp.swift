import AppKit
import SwiftUI

public final class OpenPDFExpertAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Open any PDF file paths passed via command-line arguments
        let args = Array(CommandLine.arguments.dropFirst())
        for arg in args where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            if url.pathExtension.lowercased() == "pdf",
               FileManager.default.fileExists(atPath: url.path) {
                Task { @MainActor in
                    self.store?.openDocument(at: url)
                }
            }
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            self.store?.openDocuments(at: urls)
        }
    }
}

@main
public struct OpenPDFExpertApp: App {
    @NSApplicationDelegateAdaptor(OpenPDFExpertAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    public init() {}

    public var body: some Scene {
        WindowGroup("PDF Expert (Reader Edition)") {
            MainWindowView(store: store)
                .onAppear {
                    appDelegate.store = store
                    store.applyAppAppearance()
                }
                .onOpenURL { url in
                    store.openDocument(at: url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1180, height: 780)
        .commands {
            PDFExpertMenuCommands(store: store)
        }
    }
}

// MARK: - MainMenu Commands (Matching zh-Hans.lproj/MainMenu.strings from PDF Expert.app)

struct PDFExpertMenuCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        // File Menu Additions
        CommandGroup(replacing: .newItem) {
            Button("打开...") {
                store.openFilePicker()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("新建主页标签") {
                store.openNewHomeTab()
            }
            .keyboardShortcut("t", modifiers: [.command])

            Divider()

            Button("关闭标签") {
                store.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
        }

        // View Menu (显示) — Exact structure from MainMenu.strings
        CommandMenu("视图") {
            Button(store.activeDocumentTab?.isLeftSidebarVisible == true ? "隐藏左边面板" : "显示左边面板") {
                store.activeDocumentTab?.isLeftSidebarVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("缩略图") {
                store.activeDocumentTab?.isLeftSidebarVisible = true
                store.activeDocumentTab?.activeSidebarTab = .thumbnails
            }
            .keyboardShortcut("2", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Button("大纲") {
                store.activeDocumentTab?.isLeftSidebarVisible = true
                store.activeDocumentTab?.activeSidebarTab = .outline
            }
            .keyboardShortcut("3", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Button("书签") {
                store.activeDocumentTab?.isLeftSidebarVisible = true
                store.activeDocumentTab?.activeSidebarTab = .bookmarks
            }
            .keyboardShortcut("4", modifiers: [.control, .command])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Theme Submenu (主题 -> 日间 / 纸质 / 夜间)
            Menu("主题") {
                ForEach([PDFViewTheme.day, .sepia, .night]) { theme in
                    Button {
                        store.pdfTheme = theme
                    } label: {
                        HStack {
                            if store.pdfTheme == theme {
                                Image(systemName: "checkmark")
                            }
                            Text(theme.title)
                        }
                    }
                }
            }

            // App UI Appearance Submenu
            Menu("界面外观") {
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

            Divider()

            // Page Layout Modes
            Button("单页") {
                store.activeDocumentTab?.layoutMode = .singlePage
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("双页") {
                store.activeDocumentTab?.layoutMode = .twoPages
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("双页（首屏单页显示）") {
                store.activeDocumentTab?.layoutMode = .twoPagesCover
            }
            .keyboardShortcut("3", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button(store.activeDocumentTab?.isClearMarginsEnabled == true ? "恢复页面空白边" : "清除空白边") {
                guard let tab = store.activeDocumentTab else { return }
                tab.isClearMarginsEnabled.toggle()
                tab.applyClearMarginsIfNeeded()
            }
            .keyboardShortcut("m", modifiers: [.shift, .command])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Split View Submenu (分屏视图)
            Menu("分屏视图") {
                Button("禁用分屏视图") {
                    store.activeDocumentTab?.splitMode = .disabled
                }
                Button("垂直分屏（左右）") {
                    store.activeDocumentTab?.splitMode = .vertical
                }
                Button("水平分屏（上下）") {
                    store.activeDocumentTab?.splitMode = .horizontal
                }
                Divider()
                Button("对调位置") {
                    store.activeDocumentTab?.isSplitSwapped.toggle()
                }
                .disabled(store.activeDocumentTab?.splitMode == .disabled)
                Button(store.activeDocumentTab?.syncScrollAndZoom == true ? "取消同步滚动和缩放" : "同步滚动和缩放") {
                    store.activeDocumentTab?.syncScrollAndZoom.toggle()
                }
                .disabled(store.activeDocumentTab?.splitMode == .disabled)
            }
            .disabled(store.activeDocumentTab == nil)

            Divider()

            // Zoom Controls
            Button("放大") {
                store.activeDocumentTab?.triggerZoom(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("缩小") {
                store.activeDocumentTab?.triggerZoom(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("实际大小") {
                store.activeDocumentTab?.triggerZoom(.actualSize)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("缩放至适应宽度") {
                store.activeDocumentTab?.triggerZoom(.fitWidth)
            }
            .keyboardShortcut("8", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("缩放至适应页面") {
                store.activeDocumentTab?.triggerZoom(.fitPage)
            }
            .keyboardShortcut("9", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)
        }

        // Go Menu (前往)
        CommandMenu("前往") {
            Button("上一页") {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(tab.currentPageIndex - 1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .disabled(store.activeDocumentTab == nil)

            Button("下一页") {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(tab.currentPageIndex + 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.option])
            .disabled(store.activeDocumentTab == nil)

            Button("第一页") {
                store.activeDocumentTab?.navigateToPage(0)
            }
            .keyboardShortcut(.home, modifiers: [])
            .disabled(store.activeDocumentTab == nil)

            Button("最后一页") {
                guard let tab = store.activeDocumentTab else { return }
                tab.navigateToPage(max(0, tab.pageCount - 1))
            }
            .keyboardShortcut(.end, modifiers: [])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            Button("返回") {
                store.activeDocumentTab?.goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(store.activeDocumentTab?.canGoBack != true)

            Button("前进") {
                store.activeDocumentTab?.goForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(store.activeDocumentTab?.canGoForward != true)

            Divider()

            Button("为当前页添加/移除书签") {
                guard let tab = store.activeDocumentTab else { return }
                store.toggleBookmark(pageIndex: tab.currentPageIndex, in: tab.documentID)
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Divider()

            Button("全文查找...") {
                store.activeDocumentTab?.isSearchVisible = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(store.activeDocumentTab == nil)

            Button("查找下一个") {
                store.activeDocumentTab?.selectNextSearchMatch()
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(store.activeDocumentTab?.searchMatches.isEmpty != false)

            Button("查找上一个") {
                store.activeDocumentTab?.selectPreviousSearchMatch()
            }
            .keyboardShortcut("g", modifiers: [.shift, .command])
            .disabled(store.activeDocumentTab?.searchMatches.isEmpty != false)

            Divider()

            Button("显示下一标签") {
                store.selectNextTab()
            }
            .keyboardShortcut("}", modifiers: [.shift, .command])

            Button("显示上一标签") {
                store.selectPreviousTab()
            }
            .keyboardShortcut("{", modifiers: [.shift, .command])
        }
    }
}
