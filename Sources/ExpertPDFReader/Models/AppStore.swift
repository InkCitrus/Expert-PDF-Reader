import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI

// MARK: - URL Symlink Normalization (from HomeTab/Utils/URL+SymlinkNormalized.swift)

extension URL {
    /// Returns `standardizedFileURL.resolvingSymlinksInPath()` so `/var/...` and `/private/var/...` converge.
    public var symlinkNormalizedURL: URL {
        self.standardizedFileURL.resolvingSymlinksInPath()
    }
}

// MARK: - DocumentID (from HomeTab ARCHITECTURE.md)

public struct DocumentID: Hashable, Codable, Identifiable {
    public let url: URL
    public let normalizedPath: String

    public var id: String { normalizedPath }

    public init(url: URL) {
        self.url = url
        self.normalizedPath = url.symlinkNormalizedURL.path
    }

    public static func == (lhs: DocumentID, rhs: DocumentID) -> Bool {
        lhs.normalizedPath == rhs.normalizedPath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedPath)
    }
}

// MARK: - DocumentItem & BookmarkItem

public struct DocumentItem: Identifiable, Equatable {
    public let documentID: DocumentID
    public let title: String
    public let fileSizeText: String
    public let pageCount: Int
    public let dateOpened: Date
    public var dateOpenedText: String
    public var isFavorite: Bool
    public var thumbnail: NSImage

    public var id: String { documentID.id }
    public var url: URL { documentID.url }

    public static func == (lhs: DocumentItem, rhs: DocumentItem) -> Bool {
        lhs.documentID == rhs.documentID &&
        lhs.dateOpened == rhs.dateOpened &&
        lhs.dateOpenedText == rhs.dateOpenedText &&
        lhs.isFavorite == rhs.isFavorite
    }
}

public struct BookmarkItem: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var pageIndex: Int
    public var title: String
    public var createdAt: Date = Date()

    public init(pageIndex: Int, title: String) {
        self.pageIndex = pageIndex
        self.title = title
    }
}

// MARK: - HomeTabPage & Reader Enums

public enum HomeTabPage: String, CaseIterable, Identifiable {
    case home = "home"
    case recents = "recents"
    case favorites = "favorites"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home:      return L10n.tr("主页", "Home")
        case .recents:   return L10n.tr("最近打开", "Recents")
        case .favorites: return L10n.tr("收藏夹", "Favorites")
        }
    }

    public var iconName: String {
        switch self {
        case .home:      return "house"
        case .recents:   return "clock"
        case .favorites: return "star"
        }
    }
}

public enum ReaderLayoutMode: String, CaseIterable, Identifiable, Codable {
    case singlePage = "single"
    case twoPages = "twoPages"
    case twoPagesCover = "twoPagesCover"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .singlePage:    return L10n.tr("单页", "Single Page")
        case .twoPages:      return L10n.tr("双页", "Two Pages")
        case .twoPagesCover: return L10n.tr("双页（首屏单页显示）", "Two Pages (Single Cover)")
        }
    }

    public var shortTitle: String {
        switch self {
        case .singlePage:    return L10n.tr("单页", "Single")
        case .twoPages:      return L10n.tr("双页", "Two Pages")
        case .twoPagesCover: return L10n.tr("双页封面", "Cover")
        }
    }

    public var iconName: String {
        switch self {
        case .singlePage:    return "doc.text"
        case .twoPages:      return "book"
        case .twoPagesCover: return "book.closed"
        }
    }
}

public enum ReaderSplitMode: String, CaseIterable, Identifiable, Codable {
    case disabled = "disabled"
    case vertical = "vertical"
    case horizontal = "horizontal"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled:   return L10n.tr("禁用分屏视图", "Disable Split View")
        case .vertical:   return L10n.tr("垂直分屏（左右）", "Vertical Split (Left/Right)")
        case .horizontal: return L10n.tr("水平分屏（上下）", "Horizontal Split (Top/Bottom)")
        }
    }

    public var shortTitle: String {
        switch self {
        case .disabled:   return L10n.tr("不分屏", "Off")
        case .vertical:   return L10n.tr("左右", "Vertical")
        case .horizontal: return L10n.tr("上下", "Horizontal")
        }
    }

    public var iconName: String {
        switch self {
        case .disabled:   return "rectangle"
        case .vertical:   return "rectangle.split.2x1"
        case .horizontal: return "rectangle.split.1x2"
        }
    }
}

/// Content of the left dock: PDF Expert 3 swaps "Document Summary" and "Layout options" in the same panel.
public enum ReaderLeftPanel: String {
    case documentSummary = "documentSummary"
    case viewSettings = "viewSettings"
}

public enum ReaderSidebarTab: String, CaseIterable, Identifiable {
    case thumbnails = "thumbnails"
    case outline = "outline"
    case bookmarks = "bookmarks"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thumbnails: return L10n.tr("缩略图", "Thumbnails")
        case .outline:    return L10n.tr("大纲", "Outline")
        case .bookmarks:  return L10n.tr("书签", "Bookmarks")
        }
    }

    public var iconName: String {
        switch self {
        case .thumbnails: return "square.grid.2x2"
        case .outline:    return "list.bullet.indent"
        case .bookmarks:  return "bookmark"
        }
    }
}

public struct SearchMatchItem: Identifiable {
    public let id = UUID()
    public let pageIndex: Int
    public let snippet: String
    public let selection: PDFSelection
}

// MARK: - DocumentTabState (Per-Tab Reader State)

@MainActor
public final class DocumentTabState: ObservableObject, Identifiable {
    public let id: UUID = UUID()
    public let documentID: DocumentID
    public let pdfDocument: PDFDocument
    public let title: String

    @Published public var currentPageIndex: Int = 0
    @Published public var zoomScale: CGFloat = 1.0
    @Published public var layoutMode: ReaderLayoutMode = .singlePage
    @Published public var isClearMarginsEnabled: Bool = false

    // Left Sidebar state
    @Published public var isLeftSidebarVisible: Bool = true
    @Published public var leftPanel: ReaderLeftPanel = .documentSummary
    @Published public var activeSidebarTab: ReaderSidebarTab = .thumbnails

    // Page Overview grid (toolbar "Page Management" button, read-only here)
    @Published public var isPageOverviewVisible: Bool = false

    // Split View state (PDFDocumentsSplitViewController)
    @Published public var splitMode: ReaderSplitMode = .disabled
    @Published public var isSplitSwapped: Bool = false
    @Published public var syncScrollAndZoom: Bool = false
    @Published public var secondaryDocumentURL: URL?
    @Published public var secondaryPDFDocument: PDFDocument?
    @Published public var secondaryPageIndex: Int = 0
    @Published public var secondaryZoomScale: CGFloat = 1.0
    @Published public var showSplitDocumentPicker: Bool = false

    // Navigation History (Go Back / Go Forward)
    @Published public private(set) var backStack: [Int] = []
    @Published public private(set) var forwardStack: [Int] = []
    private var isNavigatingHistory: Bool = false

    // Search state (PDFTextSearchPanelViewController); `isSearchVisible` drives the right results dock
    @Published public var isSearchVisible: Bool = false
    @Published public var searchQuery: String = ""
    @Published public var searchMatches: [SearchMatchItem] = []
    @Published public var selectedMatchIndex: Int = 0
    @Published public private(set) var lastSearchedQuery: String = ""
    @Published public var searchFocusToken: Int = 0

    // Action triggers for PDFView imperative commands
    @Published public var zoomCommandToken: Int = 0
    @Published public var pendingZoomAction: ZoomAction?
    @Published public var pageJumpToken: Int = 0

    public enum ZoomAction {
        case zoomIn
        case zoomOut
        case actualSize
        case fitWidth
        case fitPage
        case scale(CGFloat)
    }

    // Cached original mediaBox and computed tight cropBox per page index
    private var originalCropBoxes: [Int: CGRect] = [:]
    private var computedTightCropBoxes: [Int: CGRect] = [:]

    public init(url: URL, pdfDocument: PDFDocument) {
        self.documentID = DocumentID(url: url)
        self.pdfDocument = pdfDocument
        self.title = url.deletingPathExtension().lastPathComponent
        // Default secondary pane to same document so split comparison works out-of-the-box
        self.secondaryDocumentURL = url
        self.secondaryPDFDocument = pdfDocument
    }

    public var pageCount: Int {
        pdfDocument.pageCount
    }

    public func navigateToPage(_ index: Int, recordHistory: Bool = true) {
        let clamped = max(0, min(max(0, pageCount - 1), index))
        guard clamped != currentPageIndex else { return }
        if recordHistory && !isNavigatingHistory {
            backStack.append(currentPageIndex)
            if backStack.count > 50 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        currentPageIndex = clamped
        pageJumpToken &+= 1
        if syncScrollAndZoom && secondaryPDFDocument == pdfDocument {
            secondaryPageIndex = clamped
        }
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func goBack() {
        guard let prev = backStack.popLast() else { return }
        isNavigatingHistory = true
        forwardStack.append(currentPageIndex)
        currentPageIndex = prev
        pageJumpToken &+= 1
        isNavigatingHistory = false
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        isNavigatingHistory = true
        backStack.append(currentPageIndex)
        currentPageIndex = next
        pageJumpToken &+= 1
        isNavigatingHistory = false
    }

    public func triggerZoom(_ action: ZoomAction) {
        pendingZoomAction = action
        zoomCommandToken &+= 1
    }

    /// Toolbar toggles behave like PDF Expert's: clicking the active panel's button closes the dock.
    public func toggleLeftPanel(_ panel: ReaderLeftPanel) {
        if isLeftSidebarVisible && leftPanel == panel {
            isLeftSidebarVisible = false
        } else {
            leftPanel = panel
            isLeftSidebarVisible = true
        }
    }

    public func showSidebarTab(_ sidebarTab: ReaderSidebarTab) {
        leftPanel = .documentSummary
        activeSidebarTab = sidebarTab
        isLeftSidebarVisible = true
    }

    /// ⌘F: opens the results dock and focuses the toolbar search field.
    public func beginSearch() {
        isSearchVisible = true
        searchFocusToken &+= 1
    }

    public func endSearch() {
        searchQuery = ""
        searchMatches = []
        selectedMatchIndex = 0
        lastSearchedQuery = ""
        isSearchVisible = false
    }

    public func rotateCurrentPage(clockwise: Bool) {
        guard let page = pdfDocument.page(at: currentPageIndex) else { return }
        let delta = clockwise ? 90 : -90
        let newRotation = ((page.rotation + delta) % 360 + 360) % 360
        page.rotation = newRotation
        pageJumpToken &+= 1
    }

    public func setSecondaryDocument(url: URL) {
        if let doc = PDFDocument(url: url) {
            self.secondaryDocumentURL = url
            self.secondaryPDFDocument = doc
            self.secondaryPageIndex = 0
            self.showSplitDocumentPicker = false
        }
    }

    // MARK: - Clear Margins (智能去白边)

    public func applyClearMarginsIfNeeded() {
        for idx in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: idx) else { continue }
            if originalCropBoxes[idx] == nil {
                originalCropBoxes[idx] = page.bounds(for: .cropBox)
            }
            if isClearMarginsEnabled {
                let tight = computedTightCropBoxes[idx] ?? computeTightCropBox(for: page)
                computedTightCropBoxes[idx] = tight
                page.setBounds(tight, for: .cropBox)
            } else if let orig = originalCropBoxes[idx] {
                page.setBounds(orig, for: .cropBox)
            }
        }
    }

    private func computeTightCropBox(for page: PDFPage) -> CGRect {
        let mediaBounds = page.bounds(for: .mediaBox)
        guard mediaBounds.width > 40, mediaBounds.height > 40 else { return mediaBounds }

        // Render low-res bitmap (150 x 200) to detect non-white ink bounding box (works for both text & scans)
        let sampleW = 150
        let sampleH = 200
        var pixels = [UInt8](repeating: 255, count: sampleW * sampleH)
        let graySpace = CGColorSpaceCreateDeviceGray()

        guard let ctx = CGContext(
            data: &pixels,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return mediaBounds.insetBy(dx: mediaBounds.width * 0.08, dy: mediaBounds.height * 0.08)
        }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(sampleW) / mediaBounds.width, y: CGFloat(sampleH) / mediaBounds.height)
        ctx.translateBy(x: -mediaBounds.minX, y: -mediaBounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        var minX = sampleW
        var maxX = 0
        var minY = sampleH
        var maxY = 0
        let threshold: UInt8 = 246

        for y in 0..<sampleH {
            for x in 0..<sampleW {
                // Note: CGContext row 0 in memory is top row
                let val = pixels[y * sampleW + x]
                if val < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    // Convert top-origin row y to bottom-origin PDF y
                    let pdfRow = sampleH - 1 - y
                    if pdfRow < minY { minY = pdfRow }
                    if pdfRow > maxY { maxY = pdfRow }
                }
            }
        }

        guard minX <= maxX, minY <= maxY else {
            return mediaBounds
        }

        let scaleX = mediaBounds.width / CGFloat(sampleW)
        let scaleY = mediaBounds.height / CGFloat(sampleH)
        let pad: CGFloat = 14.0

        let rx = max(mediaBounds.minX, mediaBounds.minX + CGFloat(minX) * scaleX - pad)
        let ry = max(mediaBounds.minY, mediaBounds.minY + CGFloat(minY) * scaleY - pad)
        let rMaxX = min(mediaBounds.maxX, mediaBounds.minX + CGFloat(maxX + 1) * scaleX + pad)
        let rMaxY = min(mediaBounds.maxY, mediaBounds.minY + CGFloat(maxY + 1) * scaleY + pad)

        return CGRect(x: rx, y: ry, width: max(40, rMaxX - rx), height: max(40, rMaxY - ry))
    }

    // MARK: - Full-Text Search

    public func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSearchedQuery = trimmed
        guard !trimmed.isEmpty else {
            searchMatches = []
            selectedMatchIndex = 0
            return
        }

        let selections = pdfDocument.findString(trimmed, withOptions: [.caseInsensitive])
        var results: [SearchMatchItem] = []

        for sel in selections {
            guard let page = sel.pages.first else { continue }
            let pageIdx = pdfDocument.index(for: page)
            let pageText = (page.string ?? "") as NSString
            var snippet = sel.string ?? trimmed
            // Use this selection's own character range so repeated matches on a page get distinct context
            let matchRange = sel.range(at: 0, on: page)
            if matchRange.location != NSNotFound, NSMaxRange(matchRange) <= pageText.length {
                let start = max(0, matchRange.location - 26)
                let end = min(pageText.length, NSMaxRange(matchRange) + 36)
                let contextRange = pageText.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                let prefix = contextRange.location > 0 ? "…" : ""
                let suffix = NSMaxRange(contextRange) < pageText.length ? "…" : ""
                snippet = prefix + pageText.substring(with: contextRange).replacingOccurrences(of: "\n", with: " ") + suffix
            }
            results.append(SearchMatchItem(pageIndex: pageIdx, snippet: snippet, selection: sel))
        }

        searchMatches = results
        selectedMatchIndex = 0
        if let first = results.first {
            navigateToPage(first.pageIndex, recordHistory: false)
        }
    }

    public func selectNextSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex + 1) % searchMatches.count
        let match = searchMatches[selectedMatchIndex]
        navigateToPage(match.pageIndex, recordHistory: false)
    }

    public func selectPreviousSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex - 1 + searchMatches.count) % searchMatches.count
        let match = searchMatches[selectedMatchIndex]
        navigateToPage(match.pageIndex, recordHistory: false)
    }
}

// MARK: - AppTab (Window Tab Item)

public enum AppTab: Identifiable, Equatable {
    case home(UUID)
    case document(DocumentTabState)

    public var id: UUID {
        switch self {
        case .home(let uuid):      return uuid
        case .document(let state): return state.id
        }
    }

    public var title: String {
        switch self {
        case .home:                return L10n.tr("主页", "Home")
        case .document(let state): return state.title
        }
    }

    public var isHome: Bool {
        if case .home = self { return true }
        return false
    }

    public static func == (lhs: AppTab, rhs: AppTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ThumbnailGenerator & Cache (HomeTabThumbnailGenerator)

@MainActor
public final class PDFThumbnailCache: ObservableObject {
    public static let shared = PDFThumbnailCache()

    // Bounded by bytes so long documents scrolled in the thumbnail panel / page overview don't grow memory forever
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    public func thumbnail(for page: PDFPage, documentID: String, pageIndex: Int, theme: PDFViewTheme, size: CGSize = CGSize(width: 160, height: 210)) -> NSImage {
        let key = "\(documentID)#\(pageIndex)#\(theme.rawValue)#\(Int(size.width))x\(Int(size.height))#\(page.rotation)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let themedImg = themedImage(page.thumbnail(of: size, for: .mediaBox), theme: theme)
        cache.setObject(themedImg, forKey: key, cost: Self.byteCost(of: themedImg))
        return themedImg
    }

    /// HomeTab cover thumbnails: shader output cached per document + theme so hover redraws stay cheap.
    public func themedCover(for item: DocumentItem, theme: PDFViewTheme) -> NSImage {
        guard theme != .day else { return item.thumbnail }
        let key = "cover#\(item.id)#\(item.dateOpened.timeIntervalSince1970)#\(theme.rawValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let themedImg = themedImage(item.thumbnail, theme: theme)
        cache.setObject(themedImg, forKey: key, cost: Self.byteCost(of: themedImg))
        return themedImg
    }

    /// RGBA bytes of the largest bitmap representation (thumbnails may be backed at Retina scale)
    private static func byteCost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(pixels, Int(image.size.width * image.size.height)) * 4
    }

    private func themedImage(_ baseImg: NSImage, theme: PDFViewTheme) -> NSImage {
        guard theme != .day,
              let cgImg = baseImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filteredCG = MetalShaderRenderer.shared.applyShader(to: cgImg, theme: theme) else {
            return baseImg
        }
        return NSImage(cgImage: filteredCG, size: baseImg.size)
    }
}

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
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "openPDFExpert.appearanceMode")
            applyAppAppearance()
        }
    }

    @Published public var appLanguage: AppLanguage {
        didSet {
            L10n.currentLanguage = appLanguage
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "expertPDFReader.appLanguage")
            handleLocaleChange()
        }
    }

    // HomeTab Navigation State (HomeTabNavigationStateContainer)
    @Published public var homeCurrentPage: HomeTabPage = .home

    // DocumentsStore (Recents + Favorites + Bookmarks)
    @Published public private(set) var documents: [DocumentItem] = []
    @Published public private(set) var recentDocumentIDs: [DocumentID] = []
    @Published public private(set) var favoriteDocumentIDs: Set<DocumentID> = []
    @Published public private(set) var bookmarksByDocument: [String: [BookmarkItem]] = [:]

    // TabsViewController State
    @Published public var tabs: [AppTab] = []
    @Published public var selectedTabID: UUID

    private var dateFormatter: DateFormatter
    private var localeObserver: NSObjectProtocol?

    private struct PersistedRecentEntry: Codable {
        let path: String
        let dateOpened: Date
    }

    public init() {
        let defaults = UserDefaults.standard

        let savedLangRaw = defaults.string(forKey: "expertPDFReader.appLanguage")
            ?? defaults.string(forKey: "openPDFExpert.appLanguage")
            ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: savedLangRaw) ?? .system
        self.appLanguage = lang
        L10n.currentLanguage = lang

        if let savedModeRaw = defaults.string(forKey: "expertPDFReader.readingThemeMode"),
           let mode = PDFReadingThemeMode(rawValue: savedModeRaw) {
            self.readingThemeMode = mode
        } else if defaults.object(forKey: "openPDFExpert.pdfTheme") != nil {
            let legacyRaw = defaults.integer(forKey: "openPDFExpert.pdfTheme")
            switch PDFViewTheme(rawValue: legacyRaw) ?? .day {
            case .day:   self.readingThemeMode = .day
            case .sepia: self.readingThemeMode = .sepia
            case .night: self.readingThemeMode = .night
            }
        } else {
            self.readingThemeMode = .system
        }

        self.useSepiaForLightSystemTheme = defaults.bool(forKey: "expertPDFReader.useSepiaForLightSystemTheme")

        let savedAppRaw = defaults.string(forKey: "expertPDFReader.appearanceMode")
            ?? defaults.string(forKey: "openPDFExpert.appearanceMode")
            ?? AppAppearanceMode.system.rawValue
        self.appearanceMode = AppAppearanceMode(rawValue: savedAppRaw) ?? .system

        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        self.dateFormatter = formatter

        let homeTabID = UUID()
        self.tabs = [.home(homeTabID)]
        self.selectedTabID = homeTabID

        loadPersistedState()
        ensureSampleDocumentInRecents()
        applyAppAppearance()

        // Observe locale changes to re-format DocumentItem.dateOpenedText (from ARCHITECTURE.md PEM-10270)
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLocaleChange()
            }
        }
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
        newFormatter.timeStyle = .short
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

    public var openedDocumentItems: [DocumentItem] {
        tabs.compactMap { tab in
            guard case .document(let state) = tab else { return nil }
            return documents.first(where: { $0.documentID == state.documentID })
        }
    }

    public var activeDocumentTab: DocumentTabState? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }),
              case .document(let state) = tab else {
            return nil
        }
        return state
    }

    // MARK: - Tab & Document Actions

    public func selectHomeTab() {
        if let existing = tabs.first(where: { $0.isHome }) {
            selectedTabID = existing.id
        } else {
            let newID = UUID()
            tabs.insert(.home(newID), at: 0)
            selectedTabID = newID
        }
    }

    public func openNewHomeTab() {
        selectHomeTab()
        homeCurrentPage = .home
    }

    public func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("打开 PDF 文档", "Open PDF Document")
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            openDocuments(at: panel.urls)
        }
    }

    public func openDocuments(at urls: [URL]) {
        for url in urls {
            openDocument(at: url)
        }
    }

    @discardableResult
    public func openDocument(at url: URL) -> DocumentTabState? {
        let docID = DocumentID(url: url)

        // If already open in a tab, switch to it
        if let existingTab = tabs.first(where: {
            if case .document(let state) = $0 {
                return state.documentID == docID
            }
            return false
        }), case .document(let existingState) = existingTab {
            selectedTabID = existingTab.id
            recordDocumentOpen(url: url, pdfDocument: existingState.pdfDocument)
            return existingState
        }

        guard let pdfDoc = PDFDocument(url: url) else {
            return nil
        }

        recordDocumentOpen(url: url, pdfDocument: pdfDoc)
        let tabState = DocumentTabState(url: url, pdfDocument: pdfDoc)
        let newTab = AppTab.document(tabState)
        tabs.append(newTab)
        selectedTabID = newTab.id
        return tabState
    }

    public func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[idx].isHome && tabs.count == 1 {
            return
        }
        let wasSelected = (selectedTabID == id)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let homeID = UUID()
            tabs = [.home(homeID)]
            selectedTabID = homeID
        } else if wasSelected {
            let nextIdx = max(0, min(idx, tabs.count - 1))
            selectedTabID = tabs[nextIdx].id
        }
    }

    public func closeCurrentTab() {
        closeTab(id: selectedTabID)
    }

    public func closeOtherTabs(keeping id: UUID) {
        tabs.removeAll(where: { !$0.isHome && $0.id != id })
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = id
        }
    }

    public func selectNextTab() {
        guard tabs.count > 1,
              let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
    }

    public func selectPreviousTab() {
        guard tabs.count > 1,
              let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    // MARK: - Recents & Favorites Management

    public func setFavorite(id: DocumentID, isFavorite: Bool) {
        if isFavorite {
            favoriteDocumentIDs.insert(id)
        } else {
            favoriteDocumentIDs.remove(id)
        }
        if let idx = documents.firstIndex(where: { $0.documentID == id }) {
            documents[idx].isFavorite = isFavorite
        }
        savePersistedState()
    }

    public func toggleFavorite(id: DocumentID) {
        let current = favoriteDocumentIDs.contains(id)
        setFavorite(id: id, isFavorite: !current)
    }

    public func removeFromRecents(id: DocumentID) {
        recentDocumentIDs.removeAll(where: { $0 == id })
        if !favoriteDocumentIDs.contains(id) {
            documents.removeAll(where: { $0.documentID == id })
        }
        savePersistedState()
    }

    public func clearAllRecents() {
        recentDocumentIDs.removeAll()
        documents.removeAll(where: { !favoriteDocumentIDs.contains($0.documentID) })
        savePersistedState()
    }

    public func clearAllFavorites() {
        favoriteDocumentIDs.removeAll()
        for idx in documents.indices {
            documents[idx].isFavorite = false
        }
        savePersistedState()
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

    public func toggleBookmark(pageIndex: Int, defaultTitle: String? = nil, in documentID: DocumentID) {
        var list = bookmarksByDocument[documentID.normalizedPath] ?? []
        if let existingIdx = list.firstIndex(where: { $0.pageIndex == pageIndex }) {
            list.remove(at: existingIdx)
        } else {
            let label = defaultTitle ?? L10n.defaultBookmarkTitle(pageNumber: pageIndex + 1)
            list.append(BookmarkItem(pageIndex: pageIndex, title: label))
            list.sort(by: { $0.pageIndex < $1.pageIndex })
        }
        bookmarksByDocument[documentID.normalizedPath] = list
        savePersistedState()
    }

    public func removeBookmark(id: UUID, in documentID: DocumentID) {
        guard var list = bookmarksByDocument[documentID.normalizedPath] else { return }
        list.removeAll(where: { $0.id == id })
        bookmarksByDocument[documentID.normalizedPath] = list
        savePersistedState()
    }

    public func renameBookmark(id: UUID, newTitle: String, in documentID: DocumentID) {
        guard var list = bookmarksByDocument[documentID.normalizedPath],
              let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].title = newTitle
        bookmarksByDocument[documentID.normalizedPath] = list
        savePersistedState()
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

        let hadGuideInRecents = existingGuideIDs.contains(where: { recentDocumentIDs.contains($0) })
            || recentDocumentIDs.contains(sampleID)
        let hadGuideInFavorites = existingGuideIDs.contains(where: { favoriteDocumentIDs.contains($0) })
            || favoriteDocumentIDs.contains(sampleID)

        for oldID in existingGuideIDs {
            recentDocumentIDs.removeAll(where: { $0 == oldID })
            favoriteDocumentIDs.remove(oldID)
            documents.removeAll(where: { $0.documentID == oldID })
        }

        if ensurePresentIfMissing || hadGuideInRecents || hadGuideInFavorites {
            recordDocumentOpen(url: sampleURL, pdfDocument: pdfDoc)
            if ensurePresentIfMissing || hadGuideInFavorites {
                setFavorite(id: sampleID, isFavorite: true)
            }
        }

        // Also update any currently open Reading Guide tab in-place so switching language immediately updates the open guide
        for idx in tabs.indices {
            guard case .document(let oldState) = tabs[idx],
                  SamplePDFGenerator.isSampleGuideURL(oldState.documentID.url),
                  oldState.documentID != sampleID else {
                continue
            }
            let wasSelected = (selectedTabID == oldState.id)
            let newState = DocumentTabState(url: sampleURL, pdfDocument: pdfDoc)
            newState.currentPageIndex = min(oldState.currentPageIndex, max(0, pdfDoc.pageCount - 1))
            newState.zoomScale = oldState.zoomScale
            newState.layoutMode = oldState.layoutMode
            newState.isClearMarginsEnabled = oldState.isClearMarginsEnabled
            newState.isLeftSidebarVisible = oldState.isLeftSidebarVisible
            newState.leftPanel = oldState.leftPanel
            newState.activeSidebarTab = oldState.activeSidebarTab
            if newState.isClearMarginsEnabled {
                newState.applyClearMarginsIfNeeded()
            }
            let newTab = AppTab.document(newState)
            tabs[idx] = newTab
            if wasSelected {
                selectedTabID = newTab.id
            }
        }
    }

    public func openGettingStartedGuide() {
        let sampleURL = SamplePDFGenerator.ensureSamplePDFExists(for: appLanguage)
        openDocument(at: sampleURL)
    }

    private func recordDocumentOpen(url: URL, pdfDocument: PDFDocument) {
        let docID = DocumentID(url: url)
        let now = Date()
        let dateText = dateFormatter.string(from: now)
        let isFav = favoriteDocumentIDs.contains(docID)
        let coverThumb = generateCoverThumbnail(for: pdfDocument, documentID: docID.id)
        let sizeText = formattedFileSize(for: url)

        let item = DocumentItem(
            documentID: docID,
            title: url.deletingPathExtension().lastPathComponent,
            fileSizeText: sizeText,
            pageCount: pdfDocument.pageCount,
            dateOpened: now,
            dateOpenedText: dateText,
            isFavorite: isFav,
            thumbnail: coverThumb
        )

        if let idx = documents.firstIndex(where: { $0.documentID == docID }) {
            documents[idx] = item
        } else {
            documents.insert(item, at: 0)
        }

        recentDocumentIDs.removeAll(where: { $0 == docID })
        recentDocumentIDs.insert(docID, at: 0)
        savePersistedState()
    }

    private func generateCoverThumbnail(for pdfDocument: PDFDocument, documentID: String) -> NSImage {
        guard let firstPage = pdfDocument.page(at: 0) else {
            return NSImage(size: NSSize(width: 140, height: 184))
        }
        return firstPage.thumbnail(of: CGSize(width: 280, height: 368), for: .mediaBox)
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

    private func loadPersistedState() {
        let defaults = UserDefaults.standard

        if let favPaths = defaults.stringArray(forKey: "openPDFExpert.Favorites") {
            for p in favPaths where FileManager.default.fileExists(atPath: p) {
                favoriteDocumentIDs.insert(DocumentID(url: URL(fileURLWithPath: p)))
            }
        }

        if let recentsData = defaults.data(forKey: "openPDFExpert.Recents"),
           let entries = try? JSONDecoder().decode([PersistedRecentEntry].self, from: recentsData) {
            for entry in entries where FileManager.default.fileExists(atPath: entry.path) {
                let url = URL(fileURLWithPath: entry.path)
                guard let pdfDoc = PDFDocument(url: url) else { continue }
                let docID = DocumentID(url: url)
                let item = DocumentItem(
                    documentID: docID,
                    title: url.deletingPathExtension().lastPathComponent,
                    fileSizeText: formattedFileSize(for: url),
                    pageCount: pdfDoc.pageCount,
                    dateOpened: entry.dateOpened,
                    dateOpenedText: dateFormatter.string(from: entry.dateOpened),
                    isFavorite: favoriteDocumentIDs.contains(docID),
                    thumbnail: generateCoverThumbnail(for: pdfDoc, documentID: docID.id)
                )
                if !documents.contains(where: { $0.documentID == docID }) {
                    documents.append(item)
                }
                if !recentDocumentIDs.contains(docID) {
                    recentDocumentIDs.append(docID)
                }
            }
        }

        // Also ensure any favorite not in recents is loaded
        for favID in favoriteDocumentIDs {
            if !documents.contains(where: { $0.documentID == favID }),
               FileManager.default.fileExists(atPath: favID.url.path),
               let pdfDoc = PDFDocument(url: favID.url) {
                let now = Date()
                let item = DocumentItem(
                    documentID: favID,
                    title: favID.url.deletingPathExtension().lastPathComponent,
                    fileSizeText: formattedFileSize(for: favID.url),
                    pageCount: pdfDoc.pageCount,
                    dateOpened: now,
                    dateOpenedText: dateFormatter.string(from: now),
                    isFavorite: true,
                    thumbnail: generateCoverThumbnail(for: pdfDoc, documentID: favID.id)
                )
                documents.append(item)
            }
        }

        if let bmData = defaults.data(forKey: "openPDFExpert.Bookmarks"),
           let decoded = try? JSONDecoder().decode([String: [BookmarkItem]].self, from: bmData) {
            bookmarksByDocument = decoded
        }
    }

    private func savePersistedState() {
        let defaults = UserDefaults.standard
        let favPaths = favoriteDocumentIDs.map { $0.normalizedPath }
        defaults.set(favPaths, forKey: "openPDFExpert.Favorites")

        let entries: [PersistedRecentEntry] = recentDocumentIDs.compactMap { id in
            guard let item = documents.first(where: { $0.documentID == id }) else { return nil }
            return PersistedRecentEntry(path: id.url.path, dateOpened: item.dateOpened)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: "openPDFExpert.Recents")
        }

        if let bmData = try? JSONEncoder().encode(bookmarksByDocument) {
            defaults.set(bmData, forKey: "openPDFExpert.Bookmarks")
        }
    }
}
