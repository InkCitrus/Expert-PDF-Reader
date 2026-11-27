import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppStore (Root Domain Controller + Coordinator)

@MainActor
public final class AppStore: ObservableObject {
    // Global Reading Theme Mode (Follow System / Day / Sepia / Night)
    @Published public var readingThemeMode: PDFReadingThemeMode {
        didSet {
            UserDefaults.standard.set(readingThemeMode.rawValue, forKey: "expertPDFReader.readingThemeMode")
        }
    }

    /// When `readingThemeMode == .system`, optionally use `.sepia` instead of `.day` in Light mode.
    @Published public var useSepiaForLightSystemTheme: Bool {
        didSet {
            UserDefaults.standard.set(useSepiaForLightSystemTheme, forKey: "expertPDFReader.useSepiaForLightSystemTheme")
        }
    }

    @Published public var restoreTabsOnLaunch: Bool {
        didSet { UserDefaults.standard.set(restoreTabsOnLaunch, forKey: Keys.restoreTabsOnLaunch) }
    }

    @Published public var alwaysShowPageIndicator: Bool {
        didSet { UserDefaults.standard.set(alwaysShowPageIndicator, forKey: Keys.alwaysShowPageIndicator) }
    }

    @Published public var autoGenerateOutline: Bool {
        didSet { UserDefaults.standard.set(autoGenerateOutline, forKey: Keys.autoGenerateOutline) }
    }

    /// Resolves the concrete GPU `PDFViewTheme` (`day`, `sepia`, or `night`) for the given UI appearance.
    public func resolvedPDFTheme(isDark: Bool) -> PDFViewTheme {
        readingThemeMode.resolvedTheme(isDark: isDark, useSepiaInLight: useSepiaForLightSystemTheme)
    }

    /// Convenience accessor / setter for concrete `PDFViewTheme`
    public var pdfTheme: PDFViewTheme {
        get {
            let isDark = (NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return resolvedPDFTheme(isDark: isDark)
        }
        set {
            switch newValue {
            case .day:   readingThemeMode = .day
            case .sepia: readingThemeMode = .sepia
            case .night: readingThemeMode = .night
            }
        }
    }

    @Published public var appearanceMode: AppAppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "expertPDFReader.appearanceMode")
            applyAppAppearance()
        }
    }

    @Published public var accentColor: AppAccentColor {
        didSet {
            UserDefaults.standard.set(accentColor.rawValue, forKey: "expertPDFReader.accentColor")
            AppPalette.accent = accentColor
        }
    }

    @Published public var tabsInSidebar: Bool {
        didSet { UserDefaults.standard.set(tabsInSidebar, forKey: "expertPDFReader.tabsInSidebar") }
    }

    @Published public var appLanguage: AppLanguage {
        didSet {
            L10n.currentLanguage = appLanguage
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "expertPDFReader.appLanguage")
            Self.applyMenuBarLanguage(appLanguage)
            handleLocaleChange()
        }
    }

    /// macOS localizes its own menus (File, Edit, Window…) once, at launch, from the app's
    /// `AppleLanguages`; the app's own strings switch live.
    public var menuBarNeedsRestartForLanguage: Bool {
        guard let launchLanguage = Bundle.main.preferredLocalizations.first else { return false }
        return launchLanguage != appLanguage.resolved.rawValue
    }

    /// Makes the next launch use the chosen language for macOS's menus too ("Follow System" removes the override).
    private static func applyMenuBarLanguage(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Quits and reopens the app; the session (tabs, pages) is saved on quit and restored on launch.
    public func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this process to exit so `open` starts a new instance instead of activating this one
        process.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Default PDF App

    /// Whether double-clicking a PDF in Finder opens this app, and otherwise the name of the app that does
    @Published public private(set) var isDefaultPDFApp = false
    @Published public private(set) var defaultPDFAppName: String?

    /// Re-read from Launch Services: the default can also be changed in Finder (Get Info › Open with)
    public func refreshDefaultPDFApp() {
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: .pdf)
        // Compared by bundle ID: a development build and the installed copy are the same app to Launch Services
        isDefaultPDFApp = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        defaultPDFAppName = appURL.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }

    public func makeDefaultPDFApp() {
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                // Declined in the system's confirmation
            } catch {
                NSApp.presentError(error)
            }
            refreshDefaultPDFApp()
        }
    }

    // Multi-Window Sessions (Primary window + browser-style detached windows)
    public let primarySession: ReaderWindowSession
    @Published public private(set) var detachedSessions: [ReaderWindowSession] = []
    @Published public var activeWindowSessionID: UUID {
        didSet { saveOpenTabs() }
    }
    private var detachedWindowControllers: [UUID: DetachedReaderWindowController] = [:]
    private var isTerminating = false

    public var allWindowSessions: [ReaderWindowSession] {
        [primarySession] + detachedSessions
    }

    public var activeSession: ReaderWindowSession {
        allWindowSessions.first(where: { $0.id == activeWindowSessionID }) ?? primarySession
    }

    func isLeftPanelVisible(in session: ReaderWindowSession) -> Bool {
        return session.activeDocumentTab?.isLeftSidebarVisible ?? session.isHomeSidebarVisible
    }

    func toggleLeftPanel(in session: ReaderWindowSession) {
        withAnimation(AppAnimation.panel) {
            if let tab = session.activeDocumentTab {
                tab.isLeftSidebarVisible.toggle()
            } else {
                session.isHomeSidebarVisible.toggle()
            }
        }
    }

    func showSidebarTab(_ sidebarTab: ReaderSidebarTab) {
        activeSession.activeDocumentTab?.showSidebarTab(sidebarTab)
    }

    public func session(withID id: UUID?) -> ReaderWindowSession {
        guard let id else { return activeSession }
        return allWindowSessions.first(where: { $0.id == id }) ?? activeSession
    }

    public func windowSession(for window: NSWindow?) -> ReaderWindowSession? {
        guard let window else { return nil }
        return allWindowSessions.first {
            $0.nsWindow === window || $0.nsWindow === window.sheetParent
        }
    }

    public func activateWindowSession(_ sessionID: UUID) {
        if activeWindowSessionID != sessionID,
           allWindowSessions.contains(where: { $0.id == sessionID }) {
            activeWindowSessionID = sessionID
        }
    }

    /// SwiftUI hook injected from `ExpertPDFReaderApp` so the primary `"main"` window scene can be reopened if closed.
    public var openPrimaryWindowHandler: (() -> Void)?

    public func ensureSessionWindowVisible(_ targetSession: ReaderWindowSession) {
        if let win = targetSession.nsWindow {
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            if !win.isVisible && targetSession.isPrimary {
                openPrimaryWindowHandler?()
            }
            win.makeKeyAndOrderFront(nil)
        } else if targetSession.isPrimary {
            openPrimaryWindowHandler?()
        }
    }

    // Active window convenience bindings
    public var homeCurrentPage: HomeTabPage {
        get { activeSession.homeCurrentPage }
        set { activeSession.homeCurrentPage = newValue }
    }

    // DocumentsStore (Recents + Favorites + Bookmarks)
    @Published public private(set) var documents: [DocumentItem] = []
    @Published public private(set) var recentDocumentIDs: [DocumentID] = []
    @Published public private(set) var favoriteDocumentIDs: Set<DocumentID> = []
    @Published public private(set) var bookmarksByDocument: [String: [BookmarkItem]] = [:]
    @Published public private(set) var highlightsByDocument: [String: [HighlightItem]] = [:]
    @Published public var defaultHighlightColor: HighlightColor = .yellow {
        didSet {
            UserDefaults.standard.set(defaultHighlightColor.rawValue, forKey: Keys.defaultHighlightColor)
        }
    }

    // Active window tabs
    public var tabs: [AppTab] {
        get { activeSession.tabs }
        set { activeSession.tabs = newValue }
    }
    public var selectedTabID: UUID {
        get { activeSession.selectedTabID }
        set { activeSession.selectedTabID = newValue }
    }
    /// Closed document tabs (most recent last) with their original tab bar slot and panel state
    @Published public private(set) var closedTabs: [ClosedTabRecord] = []

    /// Interactive Keyboard Shortcuts & Tips cheat sheet (⌘/) on the active window
    public var isShortcutsSheetPresented: Bool {
        get { activeSession.isShortcutsSheetPresented }
        set { activeSession.isShortcutsSheetPresented = newValue }
    }
    public var shortcutsInitialCategory: ShortcutGuideCategory {
        get { activeSession.shortcutsInitialCategory }
        set { activeSession.shortcutsInitialCategory = newValue }
    }

    public func presentShortcutsSheet(category: ShortcutGuideCategory = .all, in sessionID: UUID? = nil) {
        let target = session(withID: sessionID)
        target.shortcutsInitialCategory = category
        target.isShortcutsSheetPresented = true
    }

    public func toggleShortcutsSheet(in sessionID: UUID? = nil) {
        let target = session(withID: sessionID)
        if target.isShortcutsSheetPresented {
            target.isShortcutsSheetPresented = false
        } else {
            target.shortcutsInitialCategory = .all
            target.isShortcutsSheetPresented = true
        }
    }

    public var closedDocumentURLs: [URL] {
        closedTabs.map(\.documentID.url)
    }

    @Published public private(set) var undoMenuToken: Int = 0
    private var dateFormatter: DateFormatter
    nonisolated(unsafe) private var localeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var appDidBecomeActiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var undoObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pruneDebounceTask: Task<Void, Never>?

    /// Keyed by `DocumentID.normalizedPath`
    private var readingPositions: [String: ReadingPosition] = [:]
    /// File bookmarks of remembered documents (keyed by `DocumentID.normalizedPath`) so Recents, Favorites,
    /// bookmarks and reading positions follow a file that was moved or renamed.
    private var fileBookmarks: [String: Data] = [:]
    private var isRestoringSession = false

    private static let maxRecentDocuments = 50
    private static let maxReadingPositions = 300
    private static let maxClosedTabs = 25

    private enum Keys {
        static let recents = "expertPDFReader.Recents"
        static let favorites = "expertPDFReader.Favorites"
        static let bookmarks = "expertPDFReader.Bookmarks"
        static let highlights = "expertPDFReader.highlights"
        static let defaultHighlightColor = "expertPDFReader.defaultHighlightColor"
        static let restoreTabsOnLaunch = "expertPDFReader.restoreTabsOnLaunch"
        static let alwaysShowPageIndicator = "expertPDFReader.alwaysShowPageIndicator"
        static let autoGenerateOutline = "expertPDFReader.autoGenerateOutline"
        static let readingPositions = "expertPDFReader.ReadingPositions"
        static let fileBookmarks = "expertPDFReader.FileBookmarks"
        static let openTabs = "expertPDFReader.OpenTabs"
        static let selectedTab = "expertPDFReader.SelectedTab"
        static let tabGroups = "expertPDFReader.TabGroups"
        static let closedTabs = "expertPDFReader.ClosedTabs"
    }

    private struct PersistedRecentEntry: Codable {
        let path: String
        let dateOpened: Date
        /// Saved so launching doesn't have to open every recent PDF (absent in older data)
        var pageCount: Int?
    }

    /// Blank page shown until a cover thumbnail has been read in the background
    private static let placeholderThumbnail = NSImage(
        size: DocumentDetailsLoader.thumbnailSize,
        flipped: false
    ) { rect in
        NSColor.white.setFill()
        rect.fill()
        return true
    }

    public init() {
        let defaults = UserDefaults.standard

        let savedLangRaw = defaults.string(forKey: "expertPDFReader.appLanguage")
            ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: savedLangRaw) ?? .system
        self.appLanguage = lang
        L10n.currentLanguage = lang
        // Languages chosen before the menu bar followed them take effect from the next launch
        Self.applyMenuBarLanguage(lang)

        let savedModeRaw = defaults.string(forKey: "expertPDFReader.readingThemeMode") ?? ""
        self.readingThemeMode = PDFReadingThemeMode(rawValue: savedModeRaw) ?? .system

        self.useSepiaForLightSystemTheme = defaults.bool(forKey: "expertPDFReader.useSepiaForLightSystemTheme")
        self.restoreTabsOnLaunch = defaults.object(forKey: Keys.restoreTabsOnLaunch) as? Bool ?? true
        self.alwaysShowPageIndicator = defaults.bool(forKey: Keys.alwaysShowPageIndicator)
        self.autoGenerateOutline = defaults.object(forKey: Keys.autoGenerateOutline) as? Bool ?? true

        let savedAppRaw = defaults.string(forKey: "expertPDFReader.appearanceMode")
            ?? AppAppearanceMode.system.rawValue
        self.appearanceMode = AppAppearanceMode(rawValue: savedAppRaw) ?? .system
        let savedAccentRaw = defaults.string(forKey: "expertPDFReader.accentColor") ?? AppAccentColor.blue.rawValue
        let resolvedAccent = AppAccentColor(rawValue: savedAccentRaw) ?? .blue
        self.accentColor = resolvedAccent
        AppPalette.accent = resolvedAccent
        let savedHighlightColorRaw = defaults.string(forKey: Keys.defaultHighlightColor) ?? HighlightColor.yellow.rawValue
        self.defaultHighlightColor = HighlightColor(rawValue: savedHighlightColorRaw) ?? .yellow
        self.tabsInSidebar = defaults.bool(forKey: "expertPDFReader.tabsInSidebar")

        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        self.dateFormatter = formatter

        let homeTabID = UUID()
        let initialPrimary = ReaderWindowSession(
            isPrimary: true,
            tabs: [.home(homeTabID)],
            selectedTabID: homeTabID
        )
        self.primarySession = initialPrimary
        self.activeWindowSessionID = initialPrimary.id
        observeWindowSession(initialPrimary)

        loadPersistedState()
        restoreOpenTabs()
        ensureSampleDocumentInRecents()
        applyAppAppearance()
        rebuildFileWatchers()

        // Observe locale changes to re-format DocumentItem.dateOpenedText
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLocaleChange()
            }
        }

        // Re-check remembered files whenever the user switches back from Finder / Terminal
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneMissingDocuments()
            }
        }

        let undoNotificationNames: [Notification.Name] = [
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification,
            NSText.didChangeNotification,
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        undoObservers = undoNotificationNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.undoMenuToken &+= 1
                }
            }
        }
    }

    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        if let appDidBecomeActiveObserver { NotificationCenter.default.removeObserver(appDidBecomeActiveObserver) }
        for obs in undoObservers { NotificationCenter.default.removeObserver(obs) }
        for source in fileWatchers.values { source.cancel() }
        pruneDebounceTask?.cancel()
    }

    public func applyAppAppearance() {
        switch appearanceMode {
        case .system:
            NSApp?.appearance = nil
        case .light:
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func handleLocaleChange() {
        let newFormatter = DateFormatter()
        newFormatter.locale = appLanguage.locale
        newFormatter.dateStyle = .short
        newFormatter.timeStyle = .none
        newFormatter.doesRelativeDateFormatting = true
        self.dateFormatter = newFormatter

        for idx in documents.indices {
            documents[idx].dateOpenedText = newFormatter.string(from: documents[idx].dateOpened)
        }
        refreshLocalizedSampleGuide()
    }

    // MARK: - Computed Document Collections

    public var recentDocuments: [DocumentItem] {
        recentDocumentIDs.compactMap { id in
            documents.first(where: { $0.documentID == id })
        }
    }

    public var favoriteDocuments: [DocumentItem] {
        documents.filter { favoriteDocumentIDs.contains($0.documentID) }
    }

    public func savedReadingPageLabel(for item: DocumentItem) -> String? {
        guard let pos = readingPositions[item.documentID.normalizedPath],
              pos.pageIndex > 0,
              item.pageCount > 1,
              pos.pageIndex < item.pageCount else { return nil }
        return "\(pos.pageIndex + 1) / \(item.pageCount)"
    }

    /// Returns a progress label + fraction only while genuinely mid-document (never on page 1 or the final page).
    public func inProgressReadingState(for item: DocumentItem) -> (label: String, fraction: Double)? {
        guard let pos = readingPositions[item.documentID.normalizedPath],
              pos.pageIndex > 0,
              item.pageCount > 2,
              pos.pageIndex < item.pageCount - 1 else { return nil }
        let label = "\(pos.pageIndex + 1) / \(item.pageCount)"
        let fraction = min(1.0, max(0.0, Double(pos.pageIndex + 1) / Double(item.pageCount)))
        return (label, fraction)
    }

    public var allOpenDocumentTabs: [DocumentTabState] {
        allWindowSessions.flatMap { session in
            session.tabs.compactMap { tab -> DocumentTabState? in
                guard case .document(let state) = tab else { return nil }
                return state
            }
        }
    }

    public var openedDocumentItems: [DocumentItem] {
        allOpenDocumentTabs.compactMap { state in
            documents.first(where: { $0.documentID == state.documentID })
        }
    }

    public var activeDocumentTab: DocumentTabState? {
        activeSession.activeDocumentTab
    }

    /// Window title surfaced to macOS Mission Control, App Exposé, Stage Manager, Dock and Accessibility.
    /// Displays the currently viewed PDF file name (disambiguated by parent folder when needed),
    /// or the app name when on a Home tab.
    public var activeWindowTitle: String {
        windowTitle(for: activeSession)
    }

    public var activeWindowRepresentedURL: URL? {
        windowRepresentedURL(for: activeSession)
    }

    public func windowTitle(for session: ReaderWindowSession) -> String {
        guard let docTab = session.activeDocumentTab else {
            return "Expert PDF Reader"
        }
        return windowTitle(for: docTab)
    }

    public func windowRepresentedURL(for session: ReaderWindowSession) -> URL? {
        guard let docTab = session.activeDocumentTab else { return nil }
        if docTab.splitMode != .disabled,
           docTab.isSplitSwapped,
           let secondaryURL = docTab.secondaryDocumentURL {
            return secondaryURL
        }
        return docTab.documentID.url
    }

    public func windowTitle(for state: DocumentTabState) -> String {
        let rawFileName = state.documentID.url.lastPathComponent
        let baseName = rawFileName.isEmpty ? state.title : rawFileName
        let primaryTitle: String
        if let folder = disambiguatedFolder(for: state) {
            primaryTitle = "\(baseName) — \(folder)"
        } else {
            primaryTitle = baseName
        }

        if state.splitMode != .disabled,
           let secondaryURL = state.secondaryDocumentURL,
           secondaryURL.standardizedFileURL != state.documentID.url.standardizedFileURL {
            let secondaryName = secondaryURL.lastPathComponent
            if !secondaryName.isEmpty {
                return state.isSplitSwapped
                    ? "\(secondaryName) · \(primaryTitle)"
                    : "\(primaryTitle) · \(secondaryName)"
            }
        }
        return primaryTitle
    }

    // MARK: - Tab & Document Actions

    private func observeWindowSession(_ session: ReaderWindowSession) {
        session.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &session.cancellables)

        // @Published sends in willSet; persist in didSet so a close/reorder/selection saves the new state.
        session.onTabsChanged = { [weak self] in self?.saveOpenTabs() }
    }

    private func performAnimated(_ animation: Animation, _ body: () -> Void) {
        if isRestoringSession {
            body()
        } else {
            withAnimation(animation, body)
        }
    }

    public func selectHomeTab(in sessionID: UUID? = nil) {
        pruneMissingDocuments()
        let targetSession = session(withID: sessionID)
        performAnimated(AppAnimation.tab) {
            if let existing = targetSession.tabs.first(where: { $0.isHome }) {
                targetSession.selectedTabID = existing.id
            } else {
                let newID = UUID()
                targetSession.tabs.insert(.home(newID), at: 0)
                targetSession.selectedTabID = newID
            }
        }
    }

    public func toggleHomeTab(in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        if targetSession.activeDocumentTab == nil {
            if let returnID = targetSession.returnableDocumentTabID {
                performAnimated(AppAnimation.tab) {
                    targetSession.selectedTabID = returnID
                }
            } else if targetSession.homeCurrentPage != .home {
                performAnimated(AppAnimation.tab) {
                    targetSession.homeCurrentPage = .home
                }
            }
            return
        }
        selectHomeTab(in: targetSession.id)
    }

    public func openNewHomeTab(in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        selectHomeTab(in: targetSession.id)
        targetSession.homeCurrentPage = .home
    }

    public func openFilePicker(in sessionID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("打开 PDF 文档", "Open PDF Document")
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            openDocuments(at: panel.urls, in: sessionID)
        }
    }

    public func openDocuments(at urls: [URL], in sessionID: UUID? = nil) {
        for url in urls {
            openDocument(at: url, in: sessionID)
        }
    }

    /// Opens `url` in a new tab (or switches to the window & tab already showing it) at the page, zoom and layout
    /// it was last read with. `interactive: false` skips password prompts and error alerts.
    @discardableResult
    public func openDocument(
        at url: URL,
        recordInRecents: Bool = true,
        interactive: Bool = true,
        insertAt insertionIndex: Int? = nil,
        in targetSessionID: UUID? = nil
    ) -> DocumentTabState? {
        var targetURL = url
        let initialID = DocumentID(url: url)

        if !Self.isUsableDocumentFile(at: targetURL) {
            if let movedURL = resolveFileURL(path: initialID.normalizedPath) {
                targetURL = movedURL
                pruneMissingDocuments()
            } else {
                pruneMissingDocuments()
                if Self.isFileInTrash(targetURL) {
                    if interactive { NSSound.beep() }
                    return nil
                }
            }
        }

        let docID = DocumentID(url: targetURL)

        // If already open in any reader window, focus that window and switch to its tab
        for existingSession in allWindowSessions {
            if let existingTab = existingSession.tabs.first(where: {
                if case .document(let state) = $0 {
                    return state.documentID == docID
                }
                return false
            }), case .document(let existingState) = existingTab {
                performAnimated(AppAnimation.tab) {
                    existingSession.selectedTabID = existingTab.id
                    activeWindowSessionID = existingSession.id
                }
                if !isRestoringSession {
                    ensureSessionWindowVisible(existingSession)
                }
                removeClosedTabEntries(for: docID)
                if recordInRecents {
                    recordDocumentOpen(url: targetURL, pdfDocument: existingState.pdfDocument)
                }
                return existingState
            }
        }

        guard let loaded = PDFDocumentLoader.load(url: targetURL, interactive: interactive) else {
            return nil
        }

        let destinationSession = session(withID: targetSessionID)
        removeClosedTabEntries(for: docID)
        if recordInRecents {
            recordDocumentOpen(url: targetURL, pdfDocument: loaded.document)
        }
        let tabState = DocumentTabState(url: targetURL, pdfDocument: loaded.document, password: loaded.password)
        if let position = readingPositions[docID.normalizedPath] {
            tabState.restore(position)
        }
        observeReadingPosition(of: tabState)
        let newTab = AppTab.document(tabState)
        performAnimated(AppAnimation.tab) {
            if let insertionIndex {
                let homeCount = destinationSession.tabs.prefix(while: \.isHome).count
                let clamped = max(homeCount, min(insertionIndex, destinationSession.tabs.count))
                destinationSession.tabs.insert(newTab, at: clamped)
            } else {
                destinationSession.tabs.append(newTab)
            }
            destinationSession.selectedTabID = newTab.id
            activeWindowSessionID = destinationSession.id
        }
        if !isRestoringSession {
            ensureSessionWindowVisible(destinationSession)
        }
        return tabState
    }

    public func closeTab(id: UUID, in sessionID: UUID? = nil) {
        let candidateSessions = sessionID.map { [session(withID: $0)] + allWindowSessions } ?? allWindowSessions
        guard let targetSession = candidateSessions.first(where: { s in s.tabs.contains(where: { $0.id == id }) }),
              let idx = targetSession.tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        if !targetSession.isPrimary && targetSession.tabs.count <= 1 {
            closeDetachedWindow(sessionID: targetSession.id, recordClosedTabs: true)
            return
        }

        if targetSession.tabs[idx].isHome && targetSession.tabs.count == 1 {
            return
        }

        if case .document(let state) = targetSession.tabs[idx] {
            rememberReadingPositions(of: [state])
            rememberClosedTabs([(index: idx, state: state)])
        }
        let wasSelected = (targetSession.selectedTabID == id)
        performAnimated(AppAnimation.tab) {
            targetSession.tabs.remove(at: idx)
            if targetSession.tabs.isEmpty {
                let homeID = UUID()
                targetSession.tabs = [.home(homeID)]
                targetSession.selectedTabID = homeID
            } else if wasSelected {
                let nextIdx = max(0, min(idx, targetSession.tabs.count - 1))
                targetSession.selectedTabID = targetSession.tabs[nextIdx].id
            }
        }
    }

    public func closeCurrentTab() {
        closeTab(id: activeSession.selectedTabID, in: activeSession.id)
    }

    public func closeCurrentTabOrWindow(for window: NSWindow) {
        guard let targetSession = windowSession(for: window) else {
            window.performClose(nil)
            return
        }
        if targetSession.activeDocumentTab != nil {
            if !targetSession.isPrimary && targetSession.tabs.count <= 1 {
                window.performClose(nil)
            } else {
                closeTab(id: targetSession.selectedTabID, in: targetSession.id)
            }
        } else {
            window.performClose(nil)
        }
    }

    public func closeOtherTabs(keeping id: UUID, in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        let closingPairs: [(index: Int, state: DocumentTabState)] = targetSession.tabs.enumerated().compactMap { idx, tab in
            guard case .document(let state) = tab, state.id != id else { return nil }
            return (index: idx, state: state)
        }
        rememberReadingPositions(of: closingPairs.map(\.state))
        rememberClosedTabs(closingPairs)
        performAnimated(AppAnimation.tab) {
            targetSession.tabs.removeAll(where: { !$0.isHome && $0.id != id })
            if !targetSession.tabs.contains(where: { $0.id == targetSession.selectedTabID }) {
                targetSession.selectedTabID = id
            }
        }
    }

    // MARK: - Browser-Style Tab Detaching, New Windows & Cross-Window Merging

    /// Opens a brand-new independent reader window on the Home tab (or reopens the primary window when no
    /// reader window is currently open/miniaturized and the primary session has no open documents).
    @discardableResult
    public func openNewWindow() -> ReaderWindowSession {
        pruneMissingDocuments()

        let isPrimaryPresent = primarySession.nsWindow.map { $0.isVisible || $0.isMiniaturized } ?? false
        let primaryHasDocs = primarySession.tabs.contains { !$0.isHome }
        if !isPrimaryPresent && detachedSessions.isEmpty && !primaryHasDocs, openPrimaryWindowHandler != nil {
            openNewHomeTab(in: primarySession.id)
            activeWindowSessionID = primarySession.id
            ensureSessionWindowVisible(primarySession)
            return primarySession
        }

        let anchorWindow = activeSession.nsWindow
            ?? allWindowSessions.compactMap(\.nsWindow).first(where: \.isVisible)
            ?? primarySession.nsWindow

        let homeID = UUID()
        let newSession = ReaderWindowSession(
            isPrimary: false,
            tabs: [.home(homeID)],
            selectedTabID: homeID
        )
        observeWindowSession(newSession)
        detachedSessions.append(newSession)
        activeWindowSessionID = newSession.id

        let controller = DetachedReaderWindowController(
            store: self,
            session: newSession,
            sourceWindow: anchorWindow,
            screenDropPoint: nil
        )
        detachedWindowControllers[newSession.id] = controller
        controller.showWindow()
        return newSession
    }

    public func canDetachTab(id: UUID, in sessionID: UUID) -> Bool {
        let targetSession = session(withID: sessionID)
        guard targetSession.tabs.count > 1,
              let tab = targetSession.tabs.first(where: { $0.id == id }),
              case .document = tab else {
            return false
        }
        return true
    }

    @discardableResult
    public func detachTabToNewWindow(
        id: UUID,
        from sourceSessionID: UUID,
        screenDropPoint: NSPoint? = nil,
        tabGrabOffset: NSPoint? = nil
    ) -> ReaderWindowSession? {
        let sourceSession = session(withID: sourceSessionID)
        guard sourceSession.tabs.count > 1,
              let idx = sourceSession.tabs.firstIndex(where: { $0.id == id }),
              case .document(let docState) = sourceSession.tabs[idx] else {
            return nil
        }

        let wasSelected = (sourceSession.selectedTabID == id)
        performAnimated(AppAnimation.tab) {
            sourceSession.tabs.remove(at: idx)
            if sourceSession.tabs.isEmpty {
                let homeID = UUID()
                sourceSession.tabs = [.home(homeID)]
                sourceSession.selectedTabID = homeID
            } else if wasSelected {
                let nextIdx = max(0, min(idx, sourceSession.tabs.count - 1))
                sourceSession.selectedTabID = sourceSession.tabs[nextIdx].id
            }
        }

        let newSession = ReaderWindowSession(
            isPrimary: false,
            tabs: [.document(docState)],
            selectedTabID: docState.id
        )
        observeWindowSession(newSession)
        detachedSessions.append(newSession)
        activeWindowSessionID = newSession.id

        let controller = DetachedReaderWindowController(
            store: self,
            session: newSession,
            sourceWindow: sourceSession.nsWindow,
            screenDropPoint: screenDropPoint,
            tabGrabOffset: tabGrabOffset
        )
        detachedWindowControllers[newSession.id] = controller
        controller.showWindow()
        saveOpenTabs()
        return newSession
    }

    public func moveTab(
        id: UUID,
        from sourceSessionID: UUID,
        to targetSessionID: UUID,
        atDocumentIndex: Int? = nil,
        intoGroup groupID: UUID? = nil
    ) {
        guard sourceSessionID != targetSessionID else { return }
        let sourceSession = session(withID: sourceSessionID)
        let targetSession = session(withID: targetSessionID)
        guard let idx = sourceSession.tabs.firstIndex(where: { $0.id == id }),
              case .document(let docState) = sourceSession.tabs[idx] else {
            return
        }

        let wasSelected = (sourceSession.selectedTabID == id)
        let shouldCloseSourceDetached: Bool
        if !sourceSession.isPrimary && sourceSession.tabs.count <= 1 {
            shouldCloseSourceDetached = true
        } else {
            shouldCloseSourceDetached = false
            performAnimated(AppAnimation.tab) {
                sourceSession.tabs.remove(at: idx)
                if sourceSession.tabs.isEmpty {
                    let homeID = UUID()
                    sourceSession.tabs = [.home(homeID)]
                    sourceSession.selectedTabID = homeID
                } else if wasSelected {
                    let nextIdx = max(0, min(idx, sourceSession.tabs.count - 1))
                    sourceSession.selectedTabID = sourceSession.tabs[nextIdx].id
                }
            }
        }

        let newTab = AppTab.document(docState)
        performAnimated(AppAnimation.tab) {
            let homeCount = targetSession.tabs.prefix(while: \.isHome).count
            if let atDocumentIndex {
                let clamped = max(homeCount, min(homeCount + max(0, atDocumentIndex), targetSession.tabs.count))
                targetSession.tabs.insert(newTab, at: clamped)
            } else {
                targetSession.tabs.append(newTab)
            }
            targetSession.setTabGroup(id, to: groupID)
            targetSession.normalizeTabGroupOrder()
            targetSession.selectedTabID = newTab.id
            activeWindowSessionID = targetSession.id
        }

        if shouldCloseSourceDetached {
            sourceSession.tabs.removeAll { $0.id == id }
            closeDetachedWindow(sessionID: sourceSession.id, recordClosedTabs: false)
        }

        ensureSessionWindowVisible(targetSession)
        saveOpenTabs()
    }

    public func mergeAllWindows() {
        guard !detachedSessions.isEmpty else { return }
        let previouslyActiveDocID = activeDocumentTab?.id
        let sessionsToMerge = detachedSessions

        performAnimated(AppAnimation.tab) {
            for detached in sessionsToMerge {
                let groups = detached.tabGroups
                for tab in detached.tabs {
                    if case .document(let docState) = tab {
                        primarySession.tabs.append(.document(docState))
                    }
                }
                primarySession.tabGroups.append(contentsOf: groups)
                detached.tabs.removeAll()
            }
            if let previouslyActiveDocID,
               primarySession.tabs.contains(where: { $0.id == previouslyActiveDocID }) {
                primarySession.selectedTabID = previouslyActiveDocID
            } else if let lastTab = primarySession.tabs.last {
                primarySession.selectedTabID = lastTab.id
            }
            activeWindowSessionID = primarySession.id
            primarySession.normalizeTabGroupOrder()
        }

        for detached in sessionsToMerge {
            closeDetachedWindow(sessionID: detached.id, recordClosedTabs: false)
        }
        ensureSessionWindowVisible(primarySession)
        saveOpenTabs()
    }

    func tabDropTarget(at point: NSPoint) -> ReaderTabDropTarget? {
        let sessions = allWindowSessions
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized {
            guard let session = sessions.first(where: { $0.nsWindow === window }) else { continue }
            if session.containsTabStrip(point) { return .tabStrip(session) }
            guard window.frame.contains(point) else { continue }
            if let tab = session.activeDocumentTab, tab.splitMode != .disabled, !tab.isPageOverviewVisible,
               let pane = tab.comparisonDropView, pane.window === window, pane.containsScreenPoint(point) {
                return .comparison(tab)
            }
            // Don't drop through a reader window into one behind it.
            break
        }
        return nil
    }

    private func closeDetachedWindow(sessionID: UUID, recordClosedTabs: Bool) {
        if let controller = detachedWindowControllers[sessionID] {
            if recordClosedTabs {
                controller.window.close()
            } else {
                controller.closeProgrammatically()
            }
        } else {
            handleDetachedWindowWillClose(sessionID: sessionID, recordClosedTabs: recordClosedTabs)
        }
    }

    func handleDetachedWindowWillClose(sessionID: UUID, recordClosedTabs: Bool) {
        guard let idx = detachedSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let closingSession = detachedSessions[idx]

        let docPairs: [(index: Int, state: DocumentTabState)] = closingSession.tabs.enumerated().compactMap { i, tab in
            guard case .document(let state) = tab else { return nil }
            return (index: i, state: state)
        }
        rememberReadingPositions(of: docPairs.map(\.state))
        if recordClosedTabs && !isTerminating {
            rememberClosedTabs(docPairs)
        }

        detachedSessions.remove(at: idx)
        detachedWindowControllers.removeValue(forKey: sessionID)

        if activeWindowSessionID == sessionID {
            activeWindowSessionID = detachedSessions.last?.id ?? primarySession.id
        }
        if !isTerminating {
            saveOpenTabs()
        }
    }

    public func beginTermination() {
        isTerminating = true
    }

    private func rememberClosedTabs(_ items: [(index: Int, state: DocumentTabState)]) {
        guard !items.isEmpty else { return }
        for item in items {
            let state = item.state
            let group = allWindowSessions.compactMap { $0.tabGroup(containing: state.id) }.first
            closedTabs.removeAll { $0.documentID == state.documentID }
            closedTabs.append(
                ClosedTabRecord(
                    documentID: state.documentID,
                    tabIndex: item.index,
                    isClearMarginsEnabled: state.isClearMarginsEnabled,
                    isLeftSidebarVisible: state.isLeftSidebarVisible,
                    activeSidebarTab: state.activeSidebarTab,
                    tabGroupID: group?.id,
                    tabGroupName: group?.name,
                    tabGroupColor: group?.color
                )
            )
        }
        if closedTabs.count > Self.maxClosedTabs {
            closedTabs.removeFirst(closedTabs.count - Self.maxClosedTabs)
        }
        saveClosedTabs()
        savePersistedState()
    }

    private func removeClosedTabEntries(for docID: DocumentID) {
        let before = closedTabs.count
        closedTabs.removeAll { $0.documentID == docID }
        if closedTabs.count != before {
            saveClosedTabs()
        }
    }

    private func saveClosedTabs() {
        if let data = try? JSONEncoder().encode(closedTabs) {
            UserDefaults.standard.set(data, forKey: Keys.closedTabs)
        }
    }

    /// Opens the most recently closed document again at its original tab slot, reading position and panel state
    public func reopenClosedTab(in sessionID: UUID? = nil) {
        while let record = closedTabs.popLast() {
            saveClosedTabs()
            let alreadyOpen = allOpenDocumentTabs.contains { $0.documentID == record.documentID }
            if alreadyOpen { continue }
            guard let url = resolveFileURL(path: record.documentID.normalizedPath) else { continue }
            guard let state = openDocument(at: url, insertAt: record.tabIndex, in: sessionID) else {
                // Cancelling a password prompt must not discard this tab and open an unrelated older one.
                closedTabs.append(record)
                saveClosedTabs()
                return
            }
            state.isClearMarginsEnabled = record.isClearMarginsEnabled
            state.isLeftSidebarVisible = record.isLeftSidebarVisible
            state.activeSidebarTab = record.activeSidebarTab
            if let groupID = record.tabGroupID, let name = record.tabGroupName {
                let target = session(withID: sessionID)
                if !target.tabGroups.contains(where: { $0.id == groupID }) {
                    target.tabGroups.append(ReaderTabGroup(id: groupID, name: name, tabIDs: [state.id],
                        color: record.tabGroupColor ?? .next(excluding: target.tabGroups.map(\.color))))
                } else {
                    let members = target.tabs.indices.filter { target.tabGroup(containing: target.tabs[$0].id)?.id == groupID }
                    let inserted = target.tabs.firstIndex { $0.id == state.id }!
                    if let first = members.first, let last = members.last,
                       (first - 1...last + 1).contains(inserted) {
                        target.setTabGroup(state.id, to: groupID)
                    } else {
                        moveTab(state.id, intoGroup: groupID, in: target.id)
                    }
                }
                target.revealSelectedTabGroup()
                target.normalizeTabGroupOrder()
            }
            if record.isClearMarginsEnabled {
                state.applyClearMarginsIfNeeded()
            }
            return
        }
        NSSound.beep()
    }

    public var canSelectAdjacentDocumentTab: Bool {
        let documents = activeSession.tabs.filter { !$0.isHome }
        return documents.count > 1 || (!documents.isEmpty && activeSession.activeDocumentTab == nil)
    }

    public func selectNextTab(in sessionID: UUID? = nil) { selectAdjacentDocumentTab(1, in: sessionID) }
    public func selectPreviousTab(in sessionID: UUID? = nil) { selectAdjacentDocumentTab(-1, in: sessionID) }

    /// Home is a launcher, so cycling while reading stays among PDFs.
    private func selectAdjacentDocumentTab(_ step: Int, in sessionID: UUID?) {
        let target = session(withID: sessionID)
        let documents = target.tabs.filter { !$0.isHome }
        guard !documents.isEmpty else { return }
        let index = documents.firstIndex { $0.id == target.selectedTabID }
        let next = index.map { ($0 + step + documents.count) % documents.count } ?? (step > 0 ? 0 : documents.count - 1)
        target.selectedTabID = documents[next].id
    }

    /// Moves a document tab to `toDocumentIndex` among the open document tabs (keeping Home pinned at the start).
    public func moveDocumentTab(id: UUID, toDocumentIndex: Int, in sessionID: UUID? = nil) {
        let target = session(withID: sessionID)
        let documents = target.tabs.filter { !$0.isHome }
        let index = max(0, min(documents.count - 1, toDocumentIndex))
        let groupID = documents.indices.contains(index) ? target.tabGroup(containing: documents[index].id)?.id : nil
        moveDocumentTab(id: id, toDocumentIndex: toDocumentIndex, intoGroup: groupID, in: sessionID)
    }

    func moveDocumentTab(id: UUID, toDocumentIndex: Int, intoGroup groupID: UUID?, in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        let homeCount = targetSession.tabs.prefix(while: \.isHome).count
        let docCount = targetSession.tabs.count - homeCount
        guard docCount > 0,
              let fromTabIndex = targetSession.tabs.firstIndex(where: { $0.id == id }),
              fromTabIndex >= homeCount else { return }
        let targetDocIndex = max(0, min(docCount - 1, toDocumentIndex))
        let toTabIndex = homeCount + targetDocIndex
        var reordered = targetSession.tabs
        let moved = reordered.remove(at: fromTabIndex)
        reordered.insert(moved, at: toTabIndex)
        targetSession.setTabGroup(id, to: groupID)
        targetSession.tabs = reordered
        targetSession.normalizeTabGroupOrder()
    }

    /// When two or more open document tabs (across any reader window) have the same title, returns the nearest
    /// differing ancestor folder so duplicate filenames across directories are immediately distinguishable.
    public func disambiguatedFolder(for state: DocumentTabState) -> String? {
        let sameTitleStates: [DocumentTabState] = allOpenDocumentTabs.filter { other in
            other.id != state.id && other.title.caseInsensitiveCompare(state.title) == .orderedSame
        }
        guard !sameTitleStates.isEmpty else { return nil }

        let myAncestors = Array(state.documentID.url.deletingLastPathComponent().pathComponents.reversed())
        let otherAncestorsList = sameTitleStates.map {
            Array($0.documentID.url.deletingLastPathComponent().pathComponents.reversed())
        }

        for depth in 0..<myAncestors.count {
            let candidate = myAncestors[depth]
            guard candidate != "/" && !candidate.isEmpty else { continue }
            let differsFromAll = otherAncestorsList.allSatisfy { others in
                depth >= others.count || others[depth] != candidate
            }
            if differsFromAll {
                return depth == 0 ? candidate : "\(candidate)/…"
            }
        }
        return myAncestors.first { $0 != "/" && !$0.isEmpty }
    }

    // MARK: - Recents & Favorites Management

    public func setFavorite(id: DocumentID, isFavorite: Bool) {
        performAnimated(AppAnimation.snappy) {
            if isFavorite {
                favoriteDocumentIDs.insert(id)
            } else {
                favoriteDocumentIDs.remove(id)
            }
            if let idx = documents.firstIndex(where: { $0.documentID == id }) {
                documents[idx].isFavorite = isFavorite
            }
        }
        savePersistedState()
    }

    public func toggleFavorite(id: DocumentID) {
        let current = favoriteDocumentIDs.contains(id)
        setFavorite(id: id, isFavorite: !current)
    }

    public func removeFromRecents(id: DocumentID) {
        performAnimated(AppAnimation.snappy) {
            recentDocumentIDs.removeAll(where: { $0 == id })
            if !favoriteDocumentIDs.contains(id) {
                documents.removeAll(where: { $0.documentID == id })
            }
        }
        savePersistedState()
        rebuildFileWatchers()
    }

    func confirmClearRecents(in sessionID: UUID? = nil) {
        guard !recentDocumentIDs.isEmpty else { return }
        confirmClearing(title: L10n.tr("清空最近打开记录？", "Clear Recent Documents?"), in: sessionID) { [weak self] in
            self?.clearAllRecents()
        }
    }

    func confirmClearFavorites(in sessionID: UUID? = nil) {
        guard !favoriteDocumentIDs.isEmpty else { return }
        confirmClearing(title: L10n.tr("清空收藏夹？", "Clear Favorites?"), in: sessionID) { [weak self] in
            self?.clearAllFavorites()
        }
    }

    private func clearAllRecents() {
        performAnimated(AppAnimation.snappy) {
            recentDocumentIDs.removeAll()
            documents.removeAll(where: { !favoriteDocumentIDs.contains($0.documentID) })
        }
        savePersistedState()
        rebuildFileWatchers()
    }

    private func clearAllFavorites() {
        performAnimated(AppAnimation.snappy) {
            favoriteDocumentIDs.removeAll()
            for idx in documents.indices {
                documents[idx].isFavorite = false
            }
            documents.removeAll(where: { !recentDocumentIDs.contains($0.documentID) })
        }
        savePersistedState()
        rebuildFileWatchers()
    }

    private func confirmClearing(title: String, in sessionID: UUID?, clear: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L10n.tr("PDF 文件会保留在原来的位置。", "Your PDF files will stay where they are.")
        let cancel = alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        let confirm = alert.addButton(withTitle: L10n.tr("清除全部", "Clear All"))
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        alert.layout()
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        cancel.keyEquivalent = "\u{1b}"
        if let window = session(withID: sessionID).nsWindow {
            guard window.attachedSheet == nil else { return }
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn { clear() }
            }
        } else if alert.runModal() == .alertSecondButtonReturn {
            clear()
        }
    }

    /// Removes remembered documents whose original files were deleted or moved to Trash, and updates
    /// paths/titles in-place when files were moved or renamed in Finder.
    public func pruneMissingDocuments() {
        var idMapping: [DocumentID: DocumentID] = [:]
        var removedIDs = Set<DocumentID>()

        // Resolve each remembered identity once. Resolving a bookmark migrates saved state, so resolving
        // the old path again for a closed tab could otherwise erase that tab immediately after a rename.
        let knownIDs = Set(documents.map(\.documentID)
            + closedTabs.map(\.documentID) + allOpenDocumentTabs.map(\.documentID))
        for oldID in knownIDs {
            if let resolvedURL = resolveFileURL(path: oldID.normalizedPath) {
                let newID = DocumentID(url: resolvedURL)
                if newID != oldID {
                    idMapping[oldID] = newID
                }
            } else {
                removedIDs.insert(oldID)
            }
        }

        guard !removedIDs.isEmpty || !idMapping.isEmpty else { return }

        performAnimated(AppAnimation.snappy) {
            closedTabs = closedTabs.compactMap { record in
                guard !removedIDs.contains(record.documentID) else { return nil }
                return ClosedTabRecord(
                    documentID: idMapping[record.documentID] ?? record.documentID,
                    tabIndex: record.tabIndex,
                    isClearMarginsEnabled: record.isClearMarginsEnabled,
                    isLeftSidebarVisible: record.isLeftSidebarVisible,
                    activeSidebarTab: record.activeSidebarTab,
                    tabGroupID: record.tabGroupID,
                    tabGroupName: record.tabGroupName,
                    tabGroupColor: record.tabGroupColor
                )
            }
            for tab in allOpenDocumentTabs {
                if let newID = idMapping[tab.documentID] {
                    tab.relocate(to: newID.url)
                }
            }
            // Update Recent IDs (preserving order and deduplicating)
            var seenRecent = Set<DocumentID>()
            var updatedRecents: [DocumentID] = []
            for id in recentDocumentIDs where !removedIDs.contains(id) {
                let mapped = idMapping[id] ?? id
                if seenRecent.insert(mapped).inserted {
                    updatedRecents.append(mapped)
                }
            }
            recentDocumentIDs = updatedRecents

            // Update Favorite IDs
            var updatedFavorites = Set<DocumentID>()
            for id in favoriteDocumentIDs where !removedIDs.contains(id) {
                updatedFavorites.insert(idMapping[id] ?? id)
            }
            favoriteDocumentIDs = updatedFavorites

            // Update DocumentItems
            var seenDocs = Set<DocumentID>()
            var updatedDocs: [DocumentItem] = []
            for var item in documents where !removedIDs.contains(item.documentID) {
                if let newID = idMapping[item.documentID] {
                    var renamed = makeDocumentItem(for: newID, dateOpened: item.dateOpened, pageCount: item.pageCount)
                    renamed.thumbnail = item.thumbnail
                    item = renamed
                } else {
                    item.isFavorite = updatedFavorites.contains(item.documentID)
                }
                if seenDocs.insert(item.documentID).inserted {
                    updatedDocs.append(item)
                }
            }
            documents = updatedDocs
        }

        saveClosedTabs()
        saveOpenTabs()
        savePersistedState()
        saveReadingPositions()
        rebuildFileWatchers()
    }

    public func showInFinder(id: DocumentID) {
        NSWorkspace.shared.activateFileViewerSelecting([id.url])
    }

    // MARK: - Bookmarks Management

    public func bookmarks(for documentID: DocumentID) -> [BookmarkItem] {
        bookmarksByDocument[documentID.normalizedPath] ?? []
    }

    public func isPageBookmarked(pageIndex: Int, in documentID: DocumentID) -> Bool {
        bookmarks(for: documentID).contains(where: { $0.pageIndex == pageIndex })
    }

    func windowSession(forTabID tabID: UUID) -> ReaderWindowSession {
        allWindowSessions.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })
            ?? activeSession
    }

    func window(forTabID tabID: UUID) -> NSWindow? {
        windowSession(forTabID: tabID).nsWindow
    }

    public func undoManager(for documentID: DocumentID) -> UndoManager? {
        if let active = activeDocumentTab,
           active.documentID == documentID || active.secondaryDocumentURL.map({ DocumentID(url: $0) }) == documentID {
            return active.undoManager
        }
        for session in allWindowSessions {
            for tab in session.tabs {
                if case .document(let state) = tab,
                   state.documentID == documentID || state.secondaryDocumentURL.map({ DocumentID(url: $0) }) == documentID {
                    return state.undoManager
                }
            }
        }
        return nil
    }

    private func applyBookmarks(
        _ newList: [BookmarkItem],
        for documentID: DocumentID,
        actionName: String,
        undoManager: UndoManager?
    ) {
        let previousList = bookmarksByDocument[documentID.normalizedPath] ?? []
        guard newList != previousList else { return }
        bookmarksByDocument[documentID.normalizedPath] = newList
        savePersistedState()
        let targetUndo = undoManager ?? self.undoManager(for: documentID)
        if let targetUndo {
            targetUndo.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    store.applyBookmarks(previousList, for: documentID, actionName: actionName, undoManager: targetUndo)
                }
            }
            if !targetUndo.isUndoing && !targetUndo.isRedoing {
                targetUndo.setActionName(actionName)
            }
        }
    }

    func isBookmarkActive(in tab: DocumentTabState) -> Bool {
        let source = tab.activeThumbnailSource
        let selection = tab.selectedThumbnailPages(in: source)
        let pages = selection.isEmpty ? [source.pageIndex] : Array(selection)
        return !pages.isEmpty && pages.allSatisfy { isPageBookmarked(pageIndex: $0, in: source.documentID) }
    }

    private static func sortBookmarks(_ list: inout [BookmarkItem]) {
        list.sort { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
            let ly = lhs.pageY ?? .infinity
            let ry = rhs.pageY ?? .infinity
            if abs(ly - ry) > 0.5 { return ly > ry }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public func nearbyBookmark(
        pageIndex: Int,
        point: CGPoint?,
        tolerance: CGFloat = 48,
        in documentID: DocumentID
    ) -> BookmarkItem? {
        let list = bookmarks(for: documentID)
        return list.first { item in
            guard item.pageIndex == pageIndex else { return false }
            if let point {
                guard let existingY = item.pageY else { return false }
                return abs(existingY - Double(point.y)) <= Double(tolerance)
            } else {
                return item.pageY == nil
            }
        }
    }

    @discardableResult
    public func addBookmark(
        pageIndex: Int,
        title: String? = nil,
        point: CGPoint? = nil,
        in documentID: DocumentID,
        undoManager: UndoManager? = nil
    ) -> BookmarkItem {
        if let existing = nearbyBookmark(pageIndex: pageIndex, point: point, tolerance: 48, in: documentID) {
            return existing
        }
        var list = bookmarksByDocument[documentID.normalizedPath] ?? []
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (cleaned?.isEmpty == false ? cleaned! : L10n.defaultBookmarkTitle(pageNumber: pageIndex + 1))
        let item = BookmarkItem(pageIndex: pageIndex, title: label, point: point)
        list.append(item)
        Self.sortBookmarks(&list)
        applyBookmarks(list, for: documentID, actionName: L10n.tr("添加书签", "Add Bookmark"), undoManager: undoManager)
        return item
    }

    func toggleActiveBookmark(in tab: DocumentTabState, undoManager: UndoManager? = nil) {
        let source = tab.activeThumbnailSource
        let selection = tab.selectedThumbnailPages(in: source)
        if selection.count > 1 {
            let ordered = selection.sorted()
            let shouldBookmark = !ordered.allSatisfy { isPageBookmarked(pageIndex: $0, in: source.documentID) }
            setBookmarks(pageIndices: ordered, bookmarked: shouldBookmark, in: source.documentID, undoManager: undoManager)
        } else {
            let pageIndex = selection.first ?? source.pageIndex
            let isPrimary = (source.documentID == tab.documentID)
            let point = (isPrimary && selection.isEmpty) ? tab.currentBookmarkPoint(for: pageIndex) : nil
            let title = (isPrimary && selection.isEmpty) ? tab.smartBookmarkTitle(at: pageIndex, point: point) : nil
            toggleBookmark(pageIndex: pageIndex, point: point, defaultTitle: title, in: source.documentID, undoManager: undoManager)
        }
    }

    public func toggleBookmark(
        pageIndex: Int,
        point: CGPoint? = nil,
        defaultTitle: String? = nil,
        in documentID: DocumentID,
        undoManager: UndoManager? = nil
    ) {
        var list = bookmarksByDocument[documentID.normalizedPath] ?? []
        let actionName: String
        if list.contains(where: { $0.pageIndex == pageIndex }) {
            list.removeAll { $0.pageIndex == pageIndex }
            actionName = L10n.tr("移除书签", "Remove Bookmark")
        } else {
            let label = defaultTitle ?? L10n.defaultBookmarkTitle(pageNumber: pageIndex + 1)
            list.append(BookmarkItem(pageIndex: pageIndex, title: label, point: point))
            Self.sortBookmarks(&list)
            actionName = L10n.tr("添加书签", "Add Bookmark")
        }
        applyBookmarks(list, for: documentID, actionName: actionName, undoManager: undoManager)
    }

    public func setBookmarks(
        pageIndices: [Int],
        bookmarked: Bool,
        in documentID: DocumentID,
        undoManager: UndoManager? = nil
    ) {
        var seen = Set<Int>()
        let unique = pageIndices.filter { $0 >= 0 && seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        var list = bookmarksByDocument[documentID.normalizedPath] ?? []
        let actionName: String
        if bookmarked {
            let existing = Set(list.map(\.pageIndex))
            for idx in unique where !existing.contains(idx) {
                list.append(BookmarkItem(pageIndex: idx, title: L10n.defaultBookmarkTitle(pageNumber: idx + 1)))
            }
            Self.sortBookmarks(&list)
            actionName = L10n.tr("添加书签", "Add Bookmark")
        } else {
            let removals = Set(unique)
            list.removeAll(where: { removals.contains($0.pageIndex) })
            actionName = L10n.tr("移除书签", "Remove Bookmark")
        }
        applyBookmarks(list, for: documentID, actionName: actionName, undoManager: undoManager)
    }

    public func removeBookmark(id: UUID, in documentID: DocumentID, undoManager: UndoManager? = nil) {
        guard var list = bookmarksByDocument[documentID.normalizedPath],
              list.contains(where: { $0.id == id }) else { return }
        list.removeAll(where: { $0.id == id })
        applyBookmarks(list, for: documentID, actionName: L10n.tr("删除书签", "Delete Bookmark"), undoManager: undoManager)
    }

    public func renameBookmark(id: UUID, newTitle: String, in documentID: DocumentID, undoManager: UndoManager? = nil) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var list = bookmarksByDocument[documentID.normalizedPath],
              let idx = list.firstIndex(where: { $0.id == id }),
              list[idx].title != trimmed else { return }
        list[idx].title = trimmed
        applyBookmarks(list, for: documentID, actionName: L10n.tr("重命名书签", "Rename Bookmark"), undoManager: undoManager)
    }

    // MARK: - Highlights Management

    public func highlights(for documentID: DocumentID) -> [HighlightItem] {
        highlightsByDocument[documentID.normalizedPath] ?? []
    }

    private func applyHighlights(
        _ newList: [HighlightItem],
        for documentID: DocumentID,
        actionName: String,
        undoManager: UndoManager?
    ) {
        let previousList = highlightsByDocument[documentID.normalizedPath] ?? []
        guard newList != previousList else { return }
        highlightsByDocument[documentID.normalizedPath] = newList
        savePersistedState()
        let targetUndo = undoManager ?? self.undoManager(for: documentID)
        if let targetUndo {
            targetUndo.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    store.applyHighlights(previousList, for: documentID, actionName: actionName, undoManager: targetUndo)
                }
            }
            if !targetUndo.isUndoing && !targetUndo.isRedoing {
                targetUndo.setActionName(actionName)
            }
        }
    }

    private static func sortHighlights(_ list: inout [HighlightItem]) {
        list.sort { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
            let ly = lhs.rects.first?.y ?? lhs.pageY ?? 0
            let ry = rhs.rects.first?.y ?? rhs.pageY ?? 0
            if abs(ly - ry) > 1 { return ly > ry }
            let lx = lhs.rects.first?.x ?? lhs.pageX ?? 0
            let rx = rhs.rects.first?.x ?? rhs.pageX ?? 0
            if abs(lx - rx) > 1 { return lx < rx }
            return lhs.createdAt < rhs.createdAt
        }
    }

    @discardableResult
    public func addHighlights(
        drafts: [(pageIndex: Int, text: String, rects: [CGRect])],
        color: HighlightColor? = nil,
        note: String? = nil,
        in documentID: DocumentID,
        undoManager: UndoManager? = nil
    ) -> [HighlightItem] {
        let chosenColor = color ?? defaultHighlightColor
        if color != nil && defaultHighlightColor != chosenColor {
            defaultHighlightColor = chosenColor
        }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNote: String? = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
        var list = highlightsByDocument[documentID.normalizedPath] ?? []
        var createdOrUpdated: [HighlightItem] = []

        for draft in drafts {
            let validRects = draft.rects.filter { !$0.isNull && !$0.isInfinite && $0.width > 0.5 && $0.height > 0.5 }
            guard !validRects.isEmpty else { continue }
            let normalizedText = PDFTextCleanup.normalize(draft.text)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else { continue }

            let firstRect = validRects[0]
            if let existingIdx = list.firstIndex(where: { existing in
                existing.pageIndex == draft.pageIndex
                    && existing.text == normalizedText
                    && (existing.rects.first?.cgRect.intersects(firstRect.insetBy(dx: -2, dy: -2)) ?? false)
            }) {
                list[existingIdx].color = chosenColor
                if let normalizedNote {
                    list[existingIdx].note = normalizedNote
                }
                createdOrUpdated.append(list[existingIdx])
            } else {
                let item = HighlightItem(
                    pageIndex: draft.pageIndex,
                    text: normalizedText,
                    color: chosenColor,
                    rects: validRects,
                    note: normalizedNote
                )
                list.append(item)
                createdOrUpdated.append(item)
            }
        }

        guard !createdOrUpdated.isEmpty else { return [] }
        Self.sortHighlights(&list)
        applyHighlights(list, for: documentID, actionName: L10n.tr("添加高亮", "Add Highlight"), undoManager: undoManager)
        return createdOrUpdated
    }

    @discardableResult
    public func addPageNote(
        pageIndex: Int,
        pageX: Double? = nil,
        pageY: Double? = nil,
        note: String = "",
        color: HighlightColor? = nil,
        in documentID: DocumentID,
        undoManager: UndoManager? = nil
    ) -> HighlightItem {
        let chosenColor = color ?? defaultHighlightColor
        if color != nil && defaultHighlightColor != chosenColor {
            defaultHighlightColor = chosenColor
        }
        var list = highlightsByDocument[documentID.normalizedPath] ?? []
        let item = HighlightItem(
            pageIndex: pageIndex,
            text: "",
            color: chosenColor,
            rects: [],
            note: note,
            pageX: pageX,
            pageY: pageY
        )
        list.append(item)
        Self.sortHighlights(&list)
        applyHighlights(list, for: documentID, actionName: L10n.tr("添加页面笔记", "Add Page Note"), undoManager: undoManager)
        return item
    }

    public func updateHighlightNote(id: UUID, note: String?, in documentID: DocumentID, undoManager: UndoManager? = nil) {
        guard var list = highlightsByDocument[documentID.normalizedPath],
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = (trimmed?.isEmpty == false) ? trimmed : nil
        if list[idx].isStandaloneNote && normalized == nil {
            list.remove(at: idx)
            applyHighlights(list, for: documentID, actionName: L10n.tr("删除笔记", "Delete Note"), undoManager: undoManager)
            return
        }
        guard list[idx].note != normalized else { return }
        let actionName: String
        if normalized == nil {
            actionName = L10n.tr("删除笔记", "Delete Note")
        } else if list[idx].note == nil {
            actionName = L10n.tr("添加笔记", "Add Note")
        } else {
            actionName = L10n.tr("编辑笔记", "Edit Note")
        }
        list[idx].note = normalized
        applyHighlights(list, for: documentID, actionName: actionName, undoManager: undoManager)
    }

    public func updateHighlightColor(id: UUID, color: HighlightColor, in documentID: DocumentID, undoManager: UndoManager? = nil) {
        guard var list = highlightsByDocument[documentID.normalizedPath],
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        if defaultHighlightColor != color {
            defaultHighlightColor = color
        }
        guard list[idx].color != color else { return }
        list[idx].color = color
        applyHighlights(list, for: documentID, actionName: L10n.tr("更改高亮颜色", "Change Highlight Color"), undoManager: undoManager)
    }

    public func removeHighlight(id: UUID, in documentID: DocumentID, undoManager: UndoManager? = nil) {
        guard var list = highlightsByDocument[documentID.normalizedPath],
              list.contains(where: { $0.id == id }) else { return }
        list.removeAll(where: { $0.id == id })
        applyHighlights(list, for: documentID, actionName: L10n.tr("移除高亮", "Remove Highlight"), undoManager: undoManager)
    }

    // MARK: - Persistence & Sample Initialization

    private func ensureSampleDocumentInRecents() {
        refreshLocalizedSampleGuide(ensurePresentIfMissing: true)
    }

    private func refreshLocalizedSampleGuide(ensurePresentIfMissing: Bool = false) {
        let sampleURL = SamplePDFGenerator.ensureSamplePDFExists(for: appLanguage)
        let sampleID = DocumentID(url: sampleURL)
        guard let pdfDoc = PDFDocument(url: sampleURL) else { return }

        // Check if any existing sample guide (in another language or legacy folder) was in recents/favorites
        let existingGuideIDs = documents
            .map(\.documentID)
            .filter { SamplePDFGenerator.isSampleGuideURL($0.url) && $0 != sampleID }

        let replacesRecentGuide = existingGuideIDs.contains(where: { recentDocumentIDs.contains($0) })
        let replacesFavoriteGuide = existingGuideIDs.contains(where: { favoriteDocumentIDs.contains($0) })
        // Only (re)record when the guide is missing or replaces another language's copy, so it doesn't
        // jump to the top of Recents on every launch
        let addsMissingGuide = ensurePresentIfMissing
            && existingGuideIDs.isEmpty
            && !documents.contains(where: { $0.documentID == sampleID })

        for oldID in existingGuideIDs {
            recentDocumentIDs.removeAll(where: { $0 == oldID })
            favoriteDocumentIDs.remove(oldID)
            documents.removeAll(where: { $0.documentID == oldID })
        }

        if addsMissingGuide || replacesRecentGuide || replacesFavoriteGuide {
            recordDocumentOpen(url: sampleURL, pdfDocument: pdfDoc)
            if addsMissingGuide || replacesFavoriteGuide {
                setFavorite(id: sampleID, isFavorite: true)
            }
        }

        // Also update any currently open Reading Guide tab in-place so switching language immediately updates the open guide
        for windowSession in allWindowSessions {
            for idx in windowSession.tabs.indices {
                guard case .document(let oldState) = windowSession.tabs[idx],
                      SamplePDFGenerator.isSampleGuideURL(oldState.documentID.url),
                      oldState.documentID != sampleID else {
                    continue
                }
                let wasSelected = (windowSession.selectedTabID == oldState.id)
                let newState = DocumentTabState(url: sampleURL, pdfDocument: pdfDoc)
                newState.currentPageIndex = min(oldState.currentPageIndex, max(0, pdfDoc.pageCount - 1))
                newState.zoomScale = oldState.zoomScale
                newState.isAutoScaling = oldState.isAutoScaling
                newState.layoutMode = oldState.layoutMode
                newState.isClearMarginsEnabled = oldState.isClearMarginsEnabled
                newState.isLeftSidebarVisible = oldState.isLeftSidebarVisible
                newState.activeSidebarTab = oldState.activeSidebarTab
                if newState.isClearMarginsEnabled {
                    newState.applyClearMarginsIfNeeded()
                }
                observeReadingPosition(of: newState)
                let newTab = AppTab.document(newState)
                windowSession.tabs[idx] = newTab
                if wasSelected {
                    windowSession.selectedTabID = newTab.id
                }
            }
        }
    }

    public func openGettingStartedGuide(in sessionID: UUID? = nil) {
        let sampleURL = SamplePDFGenerator.ensureSamplePDFExists(for: appLanguage)
        openDocument(at: sampleURL, in: sessionID)
    }

    private func recordDocumentOpen(url: URL, pdfDocument: PDFDocument) {
        let docID = DocumentID(url: url)
        var item = makeDocumentItem(for: docID, dateOpened: Date(), pageCount: pdfDocument.pageCount)

        if let idx = documents.firstIndex(where: { $0.documentID == docID }) {
            item.thumbnail = documents[idx].thumbnail
            documents[idx] = item
        } else {
            documents.insert(item, at: 0)
        }

        recentDocumentIDs.removeAll(where: { $0 == docID })
        recentDocumentIDs.insert(docID, at: 0)
        trimRecents()
        rememberFileBookmark(for: url)
        savePersistedState()
        rebuildFileWatchers()
        loadDocumentDetailsInBackground([(id: docID, needsPageCount: false)])
    }

    private func makeDocumentItem(for docID: DocumentID, dateOpened: Date, pageCount: Int) -> DocumentItem {
        DocumentItem(
            documentID: docID,
            title: docID.url.deletingPathExtension().lastPathComponent,
            fileSizeText: formattedFileSize(for: docID.url),
            pageCount: pageCount,
            dateOpened: dateOpened,
            dateOpenedText: dateFormatter.string(from: dateOpened),
            isFavorite: favoriteDocumentIDs.contains(docID),
            thumbnail: Self.placeholderThumbnail
        )
    }

    /// Keeps Recents bounded so the Home tab and launch stay fast; favorites keep their `DocumentItem`.
    private func trimRecents() {
        guard recentDocumentIDs.count > Self.maxRecentDocuments else { return }
        let dropped = Set(recentDocumentIDs.dropFirst(Self.maxRecentDocuments))
        recentDocumentIDs.removeLast(recentDocumentIDs.count - Self.maxRecentDocuments)
        documents.removeAll { dropped.contains($0.documentID) && !favoriteDocumentIDs.contains($0.documentID) }
    }

    /// Page counts and cover thumbnails are read off the main thread so the Home tab appears immediately.
    private func loadDocumentDetailsInBackground(_ requests: [(id: DocumentID, needsPageCount: Bool)]) {
        guard !requests.isEmpty else { return }
        let work = requests.map { (path: $0.id.normalizedPath, url: $0.id.url, needsPageCount: $0.needsPageCount) }
        Task.detached(priority: .utility) { [weak self] in
            for request in work {
                guard let details = DocumentDetailsLoader.load(url: request.url, includePageCount: request.needsPageCount) else {
                    continue
                }
                await self?.applyDocumentDetails(details, documentPath: request.path)
            }
        }
    }

    private func applyDocumentDetails(_ details: DocumentDetailsLoader.Details, documentPath: String) {
        guard let idx = documents.firstIndex(where: { $0.documentID.normalizedPath == documentPath }) else { return }
        if let pageCount = details.pageCount, pageCount != documents[idx].pageCount {
            documents[idx].pageCount = pageCount
        }
        if let thumbnail = details.thumbnail {
            documents[idx].thumbnail = thumbnail
        }
    }

    private func formattedFileSize(for url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else {
            return ""
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Launch only reads saved data: page counts come from Recents, thumbnails load in the background.
    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: Keys.fileBookmarks),
           let decoded = try? decoder.decode([String: Data].self, from: data) {
            fileBookmarks = decoded
        }
        if let data = defaults.data(forKey: Keys.readingPositions),
           let decoded = try? decoder.decode([String: ReadingPosition].self, from: data) {
            readingPositions = decoded
        }
        if let data = defaults.data(forKey: Keys.bookmarks),
           let decoded = try? decoder.decode([String: [BookmarkItem]].self, from: data) {
            bookmarksByDocument = decoded
        }
        if let data = defaults.data(forKey: Keys.highlights),
           let decoded = try? decoder.decode([String: [HighlightItem]].self, from: data) {
            highlightsByDocument = decoded
        }
        if let data = defaults.data(forKey: Keys.closedTabs),
           let decoded = try? decoder.decode([ClosedTabRecord].self, from: data) {
            closedTabs = decoded.compactMap { record in
                guard let url = resolveFileURL(path: record.documentID.normalizedPath) else { return nil }
                return ClosedTabRecord(
                    documentID: DocumentID(url: url),
                    tabIndex: record.tabIndex,
                    isClearMarginsEnabled: record.isClearMarginsEnabled,
                    isLeftSidebarVisible: record.isLeftSidebarVisible,
                    activeSidebarTab: record.activeSidebarTab,
                    tabGroupID: record.tabGroupID,
                    tabGroupName: record.tabGroupName,
                    tabGroupColor: record.tabGroupColor
                )
            }
        }

        if let favPaths = defaults.stringArray(forKey: Keys.favorites) {
            for path in favPaths {
                if let url = resolveFileURL(path: path) {
                    favoriteDocumentIDs.insert(DocumentID(url: url))
                }
            }
        }

        var detailRequests: [(id: DocumentID, needsPageCount: Bool)] = []
        if let data = defaults.data(forKey: Keys.recents),
           let entries = try? decoder.decode([PersistedRecentEntry].self, from: data) {
            for entry in entries {
                guard recentDocumentIDs.count < Self.maxRecentDocuments,
                      let url = resolveFileURL(path: entry.path) else { continue }
                let docID = DocumentID(url: url)
                guard !documents.contains(where: { $0.documentID == docID }) else { continue }
                documents.append(makeDocumentItem(for: docID, dateOpened: entry.dateOpened, pageCount: entry.pageCount ?? 0))
                recentDocumentIDs.append(docID)
                detailRequests.append((id: docID, needsPageCount: entry.pageCount == nil))
            }
        }

        // Also ensure any favorite not in recents is loaded
        for favID in favoriteDocumentIDs where !documents.contains(where: { $0.documentID == favID }) {
            documents.append(makeDocumentItem(for: favID, dateOpened: Date(), pageCount: 0))
            detailRequests.append((id: favID, needsPageCount: true))
        }

        loadDocumentDetailsInBackground(detailRequests)
        // Persist paths updated by `resolveFileURL` for moved files
        savePersistedState()
        saveReadingPositions()
    }

    private func savePersistedState() {
        let defaults = UserDefaults.standard
        let favPaths = favoriteDocumentIDs.map { $0.normalizedPath }
        defaults.set(favPaths, forKey: Keys.favorites)

        let entries: [PersistedRecentEntry] = recentDocumentIDs.compactMap { id in
            guard let item = documents.first(where: { $0.documentID == id }) else { return nil }
            return PersistedRecentEntry(
                path: id.normalizedPath,
                dateOpened: item.dateOpened,
                pageCount: item.pageCount > 0 ? item.pageCount : nil
            )
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Keys.recents)
        }

        if let bmData = try? JSONEncoder().encode(bookmarksByDocument) {
            defaults.set(bmData, forKey: Keys.bookmarks)
        }
        if let hlData = try? JSONEncoder().encode(highlightsByDocument) {
            defaults.set(hlData, forKey: Keys.highlights)
        }

        // Only keep file bookmarks of documents that are still remembered somewhere
        var remembered = Set(favPaths)
        remembered.formUnion(recentDocumentIDs.map(\.normalizedPath))
        remembered.formUnion(closedTabs.map(\.documentID.normalizedPath))
        remembered.formUnion(defaults.stringArray(forKey: Keys.openTabs) ?? [])
        remembered.formUnion(highlightsByDocument.keys)
        fileBookmarks = fileBookmarks.filter { remembered.contains($0.key) }
        if let data = try? JSONEncoder().encode(fileBookmarks) {
            defaults.set(data, forKey: Keys.fileBookmarks)
        }
    }

    // MARK: - Session (Open Tabs + Reading Positions)

    /// Saves where each open document is being read and which tabs are open; called when the app quits.
    public func saveSession() {
        rememberReadingPositions(of: allOpenDocumentTabs)
        saveOpenTabs()
    }

    private func observeReadingPosition(of tab: DocumentTabState) {
        tab.$currentPageIndex
            .combineLatest(tab.$zoomScale, tab.$isAutoScaling, tab.$layoutMode)
            .combineLatest(tab.$pageDirection, tab.$pageScan)
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.rememberReadingPositions(of: [tab])
                }
            }
            .store(in: &tab.cancellables)

        tab.$customPageRotations
            .dropFirst()
            .sink { [weak self, weak tab] _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.rememberReadingPositions(of: [tab])
                }
            }
            .store(in: &tab.cancellables)

        // Menus observe the store, while search results, history and panel state live on the tab.
        // Forward active-document changes so enabled states and checkmarks update immediately.
        tab.objectWillChange
            .sink { [weak self, weak tab] _ in
                MainActor.assumeIsolated {
                    guard let self, let tab,
                          self.allWindowSessions.contains(where: { $0.selectedTabID == tab.id }) else { return }
                    self.objectWillChange.send()
                }
            }
            .store(in: &tab.cancellables)
    }

    private func rememberReadingPositions(of tabs: [DocumentTabState]) {
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            readingPositions[tab.documentID.normalizedPath] = tab.readingPosition
        }
        if readingPositions.count > Self.maxReadingPositions {
            let oldest = readingPositions
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(readingPositions.count - Self.maxReadingPositions)
            for (path, _) in oldest {
                readingPositions.removeValue(forKey: path)
            }
        }
        saveReadingPositions()
    }

    private func saveReadingPositions() {
        if let data = try? JSONEncoder().encode(readingPositions) {
            UserDefaults.standard.set(data, forKey: Keys.readingPositions)
        }
    }

    private func saveOpenTabs() {
        guard !isRestoringSession else { return }
        let paths = allOpenDocumentTabs.map(\.documentID.normalizedPath)
        let defaults = UserDefaults.standard
        defaults.set(paths, forKey: Keys.openTabs)
        defaults.set(activeDocumentTab?.documentID.normalizedPath, forKey: Keys.selectedTab)
        let groups = allWindowSessions.flatMap { session in
            session.tabGroups.map { group in
                SavedTabGroup(id: group.id, name: group.name,
                    paths: session.tabs.compactMap { tab in
                        guard case .document(let state) = tab, group.tabIDs.contains(tab.id) else { return nil }
                        return state.documentID.normalizedPath
                    }, isCollapsed: group.isCollapsed, color: group.color)
            }
        }
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: Keys.tabGroups) }
    }

    /// Reopens the last session's tabs, skipping files that are gone or need a password.
    private func restoreOpenTabs() {
        guard restoreTabsOnLaunch else { return }
        let defaults = UserDefaults.standard
        guard let paths = defaults.stringArray(forKey: Keys.openTabs), !paths.isEmpty else { return }
        let selectedPath = defaults.string(forKey: Keys.selectedTab)

        isRestoringSession = true
        var selectedID: UUID?
        for path in paths {
            guard let url = resolveFileURL(path: path),
                  let state = openDocument(at: url, recordInRecents: false, interactive: false) else {
                continue
            }
            if path == selectedPath {
                selectedID = state.id
            }
        }
        if let selectedID {
            selectedTabID = selectedID
        } else {
            selectHomeTab()
        }
        if let data = defaults.data(forKey: Keys.tabGroups),
           let groups = try? JSONDecoder().decode([SavedTabGroup].self, from: data) {
            var restoredColors: [TabGroupColor] = []
            primarySession.tabGroups = groups.compactMap { group in
                let ids = Set(group.paths.compactMap { path -> UUID? in
                    let resolved = resolveFileURL(path: path).map { DocumentID(url: $0).normalizedPath } ?? path
                    return allOpenDocumentTabs.first { $0.documentID.normalizedPath == resolved }?.id
                })
                guard !ids.isEmpty else { return nil }
                let color = group.color ?? .next(excluding: restoredColors)
                restoredColors.append(color)
                return ReaderTabGroup(id: group.id, name: group.name, tabIDs: ids, isCollapsed: group.isCollapsed, color: color)
            }
        }
        primarySession.normalizeTabGroupOrder()
        isRestoringSession = false
        saveOpenTabs()
    }

    // MARK: - Moved / Renamed / Deleted Files

    nonisolated static func isFileInTrash(_ url: URL) -> Bool {
        let normalized = url.symlinkNormalizedURL.path
        if normalized.contains("/.Trash/") || normalized.hasSuffix("/.Trash")
            || normalized.contains("/.Trashes/") || normalized.hasSuffix("/.Trashes") {
            return true
        }
        var relationship: FileManager.URLRelationship = .other
        if (try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: [], toItemAt: url)) != nil,
           relationship == .contains || relationship == .same {
            return true
        }
        return false
    }

    nonisolated static func isUsableDocumentFile(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return !isFileInTrash(url)
    }

    /// Where a remembered file is now: its saved path, or wherever its bookmark points after a move or
    /// rename (not the Trash). Bookmarks and the reading position saved for the old path move with it.
    private func resolveFileURL(path: String) -> URL? {
        let directURL = URL(fileURLWithPath: path)
        if Self.isUsableDocumentFile(at: directURL) {
            return directURL
        }
        let oldKey = DocumentID(url: directURL).normalizedPath
        guard let data = fileBookmarks[oldKey] ?? fileBookmarks[path] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ),
            Self.isUsableDocumentFile(at: url) else {
            return nil
        }

        let newKey = DocumentID(url: url).normalizedPath
        if newKey != oldKey {
            moveSavedState(from: oldKey, to: newKey)
        }
        if isStale || newKey != oldKey {
            rememberFileBookmark(for: url)
        }
        return url
    }

    /// Watch the remembered PDF vnodes, not entire folders or the protected system Trash. Opening the
    /// Trash with O_EVTONLY can wait for macOS privacy authorization before the first window even appears.
    /// A file's rename/delete events already cover moving it to the Trash or another folder.
    private func rebuildFileWatchers() {
        let wanted = Set(documents.prefix(64).map { $0.documentID.normalizedPath })
        for (path, source) in fileWatchers where !wanted.contains(path) {
            source.cancel()
            fileWatchers.removeValue(forKey: path)
        }
        for path in wanted where fileWatchers[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedulePruneMissingDocuments() }
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            fileWatchers[path] = source
        }
    }

    private func schedulePruneMissingDocuments() {
        pruneDebounceTask?.cancel()
        pruneDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.pruneMissingDocuments()
        }
    }

    private func moveSavedState(from oldKey: String, to newKey: String) {
        if let bookmarks = bookmarksByDocument.removeValue(forKey: oldKey) {
            bookmarksByDocument[newKey] = bookmarks
        }
        if let highlights = highlightsByDocument.removeValue(forKey: oldKey) {
            highlightsByDocument[newKey] = highlights
        }
        if let position = readingPositions.removeValue(forKey: oldKey) {
            readingPositions[newKey] = position
        }
        // Keep the old bookmark until every saved consumer (closed tabs, favorites, recents, open tabs)
        // has resolved the rename. savePersistedState removes aliases no longer referenced anywhere.
        if let data = fileBookmarks[oldKey] {
            fileBookmarks[newKey] = data
        }
    }

    private func rememberFileBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        fileBookmarks[DocumentID(url: url).normalizedPath] = data
    }
}
