import AppKit
import Combine
import CryptoKit
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
    /// `0` until read in the background (`DocumentDetailsLoader`)
    public var pageCount: Int
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
        lhs.isFavorite == rhs.isFavorite &&
        lhs.pageCount == rhs.pageCount &&
        lhs.thumbnail === rhs.thumbnail
    }
}

/// Where the reader left a document; restored the next time it is opened.
public struct ReadingPosition: Codable, Equatable {
    public var pageIndex: Int
    public var zoomScale: Double
    public var isAutoScaling: Bool
    public var layoutMode: ReaderLayoutMode
    public var updatedAt: Date
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

// MARK: - PDFTextSearcher (Full-Text Search off the main thread)

/// Steps through the matches of `query` in document order with PDFKit's own matching (case-insensitive,
/// across line breaks). Not bound to the main thread: run it on a private copy of the document.
struct PDFTextSearcher {
    /// Character ranges are the same in every `PDFDocument` instance of the file, so a match found in the
    /// copy maps back onto the tab's document.
    struct Match {
        let startPage: Int
        let startRange: NSRange
        let endPage: Int
        let endRange: NSRange
        let snippet: String
    }

    let query: String
    let document: PDFDocument
    private var cursor: PDFSelection?
    private var lastStart: (Int, Int)?
    private var cachedPageText: (index: Int, text: NSString)?

    init(query: String, document: PDFDocument) {
        self.query = query
        self.document = document
    }

    mutating func next() -> Match? {
        guard let found = document.findString(query, fromSelection: cursor, withOptions: [.caseInsensitive]),
              let firstPage = found.pages.first,
              let lastPage = found.pages.last else {
            return nil
        }
        let startPage = document.index(for: firstPage)
        let startRange = found.range(at: 0, on: firstPage)
        // `findString(_:fromSelection:)` may wrap around to the start of the document: stop there
        if let lastStart, (startPage, startRange.location) <= lastStart {
            return nil
        }
        lastStart = (startPage, startRange.location)
        cursor = found

        let endPage = document.index(for: lastPage)
        let endRange = found.range(at: max(0, found.numberOfTextRanges(on: lastPage) - 1), on: lastPage)
        return Match(
            startPage: startPage,
            startRange: startRange,
            endPage: endPage,
            endRange: endRange,
            snippet: snippet(around: startRange, on: firstPage, pageIndex: startPage, fallback: found.string ?? query)
        )
    }

    /// Text around this match's own range so repeated matches on a page get distinct context
    private mutating func snippet(around range: NSRange, on page: PDFPage, pageIndex: Int, fallback: String) -> String {
        let pageText: NSString
        if let cachedPageText, cachedPageText.index == pageIndex {
            pageText = cachedPageText.text
        } else {
            pageText = (page.string ?? "") as NSString
            cachedPageText = (pageIndex, pageText)
        }
        guard range.location != NSNotFound, NSMaxRange(range) <= pageText.length else { return fallback }
        let start = max(0, range.location - 26)
        let end = min(pageText.length, NSMaxRange(range) + 36)
        let contextRange = pageText.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let prefix = contextRange.location > 0 ? "…" : ""
        let suffix = NSMaxRange(contextRange) < pageText.length ? "…" : ""
        return prefix + pageText.substring(with: contextRange).replacingOccurrences(of: "\n", with: " ") + suffix
    }
}

// MARK: - PDFDocumentLoader (Open Errors + Password Prompt)

@MainActor
public enum PDFDocumentLoader {
    public struct Loaded {
        public let document: PDFDocument
        /// Set when the user unlocked an encrypted document
        public let password: String?
    }

    /// Opens `url`, asking for the password of an encrypted document and explaining why a file can't be
    /// opened. With `interactive: false` (restoring the last session) nothing is shown and locked files are skipped.
    public static func load(url: URL, interactive: Bool = true) -> Loaded? {
        guard let document = PDFDocument(url: url) else {
            if interactive {
                showOpenError(for: url)
            }
            return nil
        }
        guard document.isLocked else {
            return Loaded(document: document, password: nil)
        }
        guard interactive else { return nil }

        var isRetry = false
        while let password = askPassword(fileName: url.lastPathComponent, isRetry: isRetry) {
            if document.unlock(withPassword: password) {
                return Loaded(document: document, password: password)
            }
            isRetry = true
        }
        return nil
    }

    /// An independent instance of the file for background work (search, Clear Margins): a `PDFDocument`
    /// that the main thread renders must not be used from another thread.
    nonisolated static func openCopy(of url: URL, password: String?) -> PDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else { return nil }
        }
        return document
    }

    private static func askPassword(fileName: String, isRetry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.passwordPromptTitle(fileName)
        alert.informativeText = isRetry
            ? L10n.tr("密码不正确，请重试。", "The password is incorrect. Try again.")
            : L10n.tr("请输入密码以打开此文档。", "Enter the password to open this document.")
        alert.addButton(withTitle: L10n.tr("打开", "Open"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func showOpenError(for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.openFailedTitle(url.lastPathComponent)
        alert.informativeText = FileManager.default.fileExists(atPath: url.path)
            ? L10n.tr("文件可能已损坏，或不是 PDF 文档。", "The file may be damaged or isn't a PDF document.")
            : L10n.tr("找不到该文件，它可能已被移动或删除。", "The file can't be found. It may have been moved or deleted.")
        alert.runModal()
    }
}

// MARK: - DocumentDetailsLoader (Home Tab Page Counts + Cover Thumbnails off the main thread)

enum DocumentDetailsLoader {
    struct Details {
        let pageCount: Int?
        let thumbnail: NSImage?
    }

    static let thumbnailSize = CGSize(width: 280, height: 368)

    /// Reads the cover thumbnail (from the on-disk cache while the file is unchanged) and, when asked, the
    /// page count. Password-protected documents are never rendered or cached.
    static func load(url: URL, includePageCount: Bool) -> Details? {
        let cacheURL = thumbnailCacheURL(for: url)
        if !includePageCount, let cacheURL, let cached = loadCachedImage(at: cacheURL) {
            return Details(pageCount: nil, thumbnail: cached)
        }
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isEncrypted {
            return Details(pageCount: document.isLocked ? nil : document.pageCount, thumbnail: nil)
        }
        if let cacheURL, let cached = loadCachedImage(at: cacheURL) {
            return Details(pageCount: document.pageCount, thumbnail: cached)
        }
        guard let page = document.page(at: 0) else {
            return Details(pageCount: document.pageCount, thumbnail: nil)
        }
        let thumbnail = page.thumbnail(of: thumbnailSize, for: .mediaBox)
        if let cacheURL {
            writePNG(thumbnail, to: cacheURL)
        }
        return Details(pageCount: document.pageCount, thumbnail: thumbnail)
    }

    /// Keyed by path, modification date and size so an edited file gets a new thumbnail
    private static func thumbnailCacheURL(for url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let key = "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ExpertPDFReader", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(digest).png")
    }

    private static func loadCachedImage(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url),
              let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            return nil
        }
        // The PNG is stored at pixel size; show it at the thumbnail's point size
        let scale = min(thumbnailSize.width / CGFloat(rep.pixelsWide), thumbnailSize.height / CGFloat(rep.pixelsHigh))
        image.size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
        return image
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)
    }
}

// MARK: - DocumentTabState (Per-Tab Reader State)

@MainActor
public final class DocumentTabState: ObservableObject, Identifiable {
    public let id: UUID = UUID()
    public let documentID: DocumentID
    public let pdfDocument: PDFDocument
    public let title: String
    /// Password that unlocked an encrypted document; needed to read the file again off the main thread
    let password: String?
    var cancellables = Set<AnyCancellable>()

    @Published public var currentPageIndex: Int = 0
    @Published public var zoomScale: CGFloat = 1.0
    /// Mirrors `PDFView.autoScales` (fit width); when `false` the view keeps `zoomScale`
    @Published public var isAutoScaling: Bool = true
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
    @Published public private(set) var isSearching: Bool = false
    @Published public var searchFocusToken: Int = 0

    // Action triggers for PDFView imperative commands
    @Published public var zoomCommandToken: Int = 0
    @Published public var pendingZoomAction: ZoomAction?
    @Published public var pageJumpToken: Int = 0
    /// Bumped when crop boxes change after layout (Clear Margins finishing in the background)
    @Published public var clearMarginsLayoutToken: Int = 0

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
    private var clearMarginsTask: Task<Void, Never>?

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    public init(url: URL, pdfDocument: PDFDocument, password: String? = nil) {
        self.documentID = DocumentID(url: url)
        self.pdfDocument = pdfDocument
        self.password = password
        self.title = url.deletingPathExtension().lastPathComponent
        // Default secondary pane to same document so split comparison works out-of-the-box
        self.secondaryDocumentURL = url
        self.secondaryPDFDocument = pdfDocument
    }

    public var pageCount: Int {
        pdfDocument.pageCount
    }

    public var readingPosition: ReadingPosition {
        ReadingPosition(
            pageIndex: currentPageIndex,
            zoomScale: Double(zoomScale),
            isAutoScaling: isAutoScaling,
            layoutMode: layoutMode,
            updatedAt: Date()
        )
    }

    /// Applied before the reader view is created; `RDPDFDocumentViewWrapper` picks it up in `makeNSView`.
    public func restore(_ position: ReadingPosition) {
        currentPageIndex = max(0, min(position.pageIndex, pageCount - 1))
        zoomScale = CGFloat(position.zoomScale)
        isAutoScaling = position.isAutoScaling
        layoutMode = position.layoutMode
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
        if case .fitWidth = action {
            isAutoScaling = true
        } else {
            isAutoScaling = false
        }
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
        cancelSearch()
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
        if let loaded = PDFDocumentLoader.load(url: url) {
            self.secondaryDocumentURL = url
            self.secondaryPDFDocument = loaded.document
            self.secondaryPageIndex = 0
            self.showSplitDocumentPicker = false
        }
    }

    // MARK: - Clear Margins (智能去白边)

    /// Applies the crop boxes already known right away; the others are computed on a private copy of the
    /// document off the main thread (pages around the current one first) and applied in batches.
    public func applyClearMarginsIfNeeded() {
        clearMarginsTask?.cancel()
        clearMarginsTask = nil

        var missing: [Int] = []
        for idx in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: idx) else { continue }
            if originalCropBoxes[idx] == nil {
                originalCropBoxes[idx] = page.bounds(for: .cropBox)
            }
            if isClearMarginsEnabled {
                if let tight = computedTightCropBoxes[idx] {
                    page.setBounds(tight, for: .cropBox)
                } else {
                    missing.append(idx)
                }
            } else if let orig = originalCropBoxes[idx] {
                page.setBounds(orig, for: .cropBox)
            }
        }
        guard isClearMarginsEnabled, !missing.isEmpty else { return }

        let current = currentPageIndex
        let order = missing.sorted { abs($0 - current) < abs($1 - current) }
        let url = documentID.url
        let password = self.password
        clearMarginsTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let document = PDFDocumentLoader.openCopy(of: url, password: password) else {
                await self?.computeTightCropBoxesOnMainThread(order)
                return
            }
            var batch: [(Int, CGRect)] = []
            var lastFlush = Date()
            for idx in order {
                if Task.isCancelled { return }
                guard let page = document.page(at: idx) else { continue }
                batch.append((idx, DocumentTabState.computeTightCropBox(for: page)))
                if batch.count >= 24 || Date().timeIntervalSince(lastFlush) > 0.25 {
                    await self?.applyTightCropBoxes(batch)
                    batch.removeAll()
                    lastFlush = Date()
                }
            }
            await self?.applyTightCropBoxes(batch)
        }
    }

    private func applyTightCropBoxes(_ boxes: [(Int, CGRect)]) {
        guard !boxes.isEmpty else { return }
        for (idx, box) in boxes {
            computedTightCropBoxes[idx] = box
        }
        // Clear Margins may have been turned off while this batch was on its way
        guard isClearMarginsEnabled else { return }
        for (idx, box) in boxes {
            pdfDocument.page(at: idx)?.setBounds(box, for: .cropBox)
        }
        clearMarginsLayoutToken &+= 1
    }

    /// Fallback when the file cannot be reopened (e.g. it was moved after opening)
    private func computeTightCropBoxesOnMainThread(_ indices: [Int]) {
        let boxes = indices.compactMap { idx in
            pdfDocument.page(at: idx).map { (idx, Self.computeTightCropBox(for: $0)) }
        }
        applyTightCropBoxes(boxes)
    }

    nonisolated static func computeTightCropBox(for page: PDFPage) -> CGRect {
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

    /// Searches a private copy of the document off the main thread so typing stays responsive on long
    /// documents; matches arrive in document order and are listed as they are found.
    public func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()
        lastSearchedQuery = trimmed
        searchMatches = []
        selectedMatchIndex = 0
        guard !trimmed.isEmpty else { return }

        isSearching = true
        let generation = searchGeneration
        let url = documentID.url
        let password = self.password
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let document = PDFDocumentLoader.openCopy(of: url, password: password) else {
                await self?.searchOnMainThread(trimmed, generation: generation)
                return
            }
            var searcher = PDFTextSearcher(query: trimmed, document: document)
            var batch: [PDFTextSearcher.Match] = []
            var lastFlush = Date()
            while !Task.isCancelled, let match = searcher.next() {
                batch.append(match)
                if batch.count >= 40 || Date().timeIntervalSince(lastFlush) > 0.15 {
                    await self?.receiveSearchMatches(batch, generation: generation)
                    batch.removeAll()
                    lastFlush = Date()
                }
            }
            await self?.receiveSearchMatches(batch, generation: generation)
            await self?.finishSearch(generation: generation)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isSearching = false
    }

    private func receiveSearchMatches(_ matches: [PDFTextSearcher.Match], generation: Int) {
        guard generation == searchGeneration, !matches.isEmpty else { return }
        let items = matches.compactMap { match -> SearchMatchItem? in
            guard let selection = tabSelection(for: match) else { return nil }
            return SearchMatchItem(pageIndex: match.startPage, snippet: match.snippet, selection: selection)
        }
        let isFirstBatch = searchMatches.isEmpty
        searchMatches.append(contentsOf: items)
        if isFirstBatch, let first = searchMatches.first {
            selectedMatchIndex = 0
            navigateToPage(first.pageIndex, recordHistory: false)
        }
    }

    private func finishSearch(generation: Int) {
        guard generation == searchGeneration else { return }
        isSearching = false
        searchTask = nil
    }

    /// Fallback when the file cannot be reopened (e.g. it was moved after opening)
    private func searchOnMainThread(_ query: String, generation: Int) {
        guard generation == searchGeneration else { return }
        var searcher = PDFTextSearcher(query: query, document: pdfDocument)
        var matches: [PDFTextSearcher.Match] = []
        while let match = searcher.next() {
            matches.append(match)
        }
        receiveSearchMatches(matches, generation: generation)
        finishSearch(generation: generation)
    }

    /// Maps a match found in the private copy back onto this tab's document (same file, same text indices).
    private func tabSelection(for match: PDFTextSearcher.Match) -> PDFSelection? {
        guard let startPage = pdfDocument.page(at: match.startPage),
              let selection = startPage.selection(for: match.startRange) else {
            return nil
        }
        if match.endPage != match.startPage,
           let endPage = pdfDocument.page(at: match.endPage),
           let tail = endPage.selection(for: match.endRange) {
            selection.add(tail)
        }
        return selection
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
        let key = "cover#\(item.id)#\(ObjectIdentifier(item.thumbnail).hashValue)#\(theme.rawValue)" as NSString
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
    @Published public var tabs: [AppTab] = [] {
        didSet { saveOpenTabs() }
    }
    @Published public var selectedTabID: UUID {
        didSet { saveOpenTabs() }
    }

    private var dateFormatter: DateFormatter
    private var localeObserver: NSObjectProtocol?

    /// Keyed by `DocumentID.normalizedPath`
    private var readingPositions: [String: ReadingPosition] = [:]
    /// File bookmarks of remembered documents (keyed by `DocumentID.normalizedPath`) so Recents, Favorites,
    /// bookmarks and reading positions follow a file that was moved or renamed.
    private var fileBookmarks: [String: Data] = [:]
    private var isRestoringSession = false

    private static let maxRecentDocuments = 50
    private static let maxReadingPositions = 300

    private enum Keys {
        static let recents = "openPDFExpert.Recents"
        static let favorites = "openPDFExpert.Favorites"
        static let bookmarks = "openPDFExpert.Bookmarks"
        static let readingPositions = "expertPDFReader.ReadingPositions"
        static let fileBookmarks = "expertPDFReader.FileBookmarks"
        static let openTabs = "expertPDFReader.OpenTabs"
        static let selectedTab = "expertPDFReader.SelectedTab"
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
        restoreOpenTabs()
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

    /// Opens `url` in a new tab (or switches to the tab already showing it) at the page, zoom and layout
    /// it was last read with. `interactive: false` skips password prompts and error alerts.
    @discardableResult
    public func openDocument(at url: URL, recordInRecents: Bool = true, interactive: Bool = true) -> DocumentTabState? {
        let docID = DocumentID(url: url)

        // If already open in a tab, switch to it
        if let existingTab = tabs.first(where: {
            if case .document(let state) = $0 {
                return state.documentID == docID
            }
            return false
        }), case .document(let existingState) = existingTab {
            selectedTabID = existingTab.id
            if recordInRecents {
                recordDocumentOpen(url: url, pdfDocument: existingState.pdfDocument)
            }
            return existingState
        }

        guard let loaded = PDFDocumentLoader.load(url: url, interactive: interactive) else {
            return nil
        }

        if recordInRecents {
            recordDocumentOpen(url: url, pdfDocument: loaded.document)
        }
        let tabState = DocumentTabState(url: url, pdfDocument: loaded.document, password: loaded.password)
        if let position = readingPositions[docID.normalizedPath] {
            tabState.restore(position)
        }
        observeReadingPosition(of: tabState)
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
        if case .document(let state) = tabs[idx] {
            rememberReadingPositions(of: [state])
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
        rememberReadingPositions(of: tabs.compactMap { tab in
            guard case .document(let state) = tab, state.id != id else { return nil }
            return state
        })
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
            newState.isAutoScaling = oldState.isAutoScaling
            newState.layoutMode = oldState.layoutMode
            newState.isClearMarginsEnabled = oldState.isClearMarginsEnabled
            newState.isLeftSidebarVisible = oldState.isLeftSidebarVisible
            newState.leftPanel = oldState.leftPanel
            newState.activeSidebarTab = oldState.activeSidebarTab
            if newState.isClearMarginsEnabled {
                newState.applyClearMarginsIfNeeded()
            }
            observeReadingPosition(of: newState)
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

        // Only keep file bookmarks of documents that are still remembered somewhere
        var remembered = Set(favPaths)
        remembered.formUnion(recentDocumentIDs.map(\.normalizedPath))
        remembered.formUnion(defaults.stringArray(forKey: Keys.openTabs) ?? [])
        fileBookmarks = fileBookmarks.filter { remembered.contains($0.key) }
        if let data = try? JSONEncoder().encode(fileBookmarks) {
            defaults.set(data, forKey: Keys.fileBookmarks)
        }
    }

    // MARK: - Session (Open Tabs + Reading Positions)

    /// Saves where each open document is being read and which tabs are open; called when the app quits.
    public func saveSession() {
        rememberReadingPositions(of: tabs.compactMap { tab in
            guard case .document(let state) = tab else { return nil }
            return state
        })
        saveOpenTabs()
    }

    private func observeReadingPosition(of tab: DocumentTabState) {
        tab.$currentPageIndex
            .combineLatest(tab.$zoomScale, tab.$isAutoScaling, tab.$layoutMode)
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.rememberReadingPositions(of: [tab])
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
        let paths = tabs.compactMap { tab -> String? in
            guard case .document(let state) = tab else { return nil }
            return state.documentID.normalizedPath
        }
        let defaults = UserDefaults.standard
        defaults.set(paths, forKey: Keys.openTabs)
        defaults.set(activeDocumentTab?.documentID.normalizedPath, forKey: Keys.selectedTab)
    }

    /// Reopens the last session's tabs, skipping files that are gone or need a password.
    private func restoreOpenTabs() {
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
        isRestoringSession = false

        if let selectedID {
            selectedTabID = selectedID
        } else {
            selectHomeTab()
        }
        saveOpenTabs()
    }

    // MARK: - Moved / Renamed Files

    /// Where a remembered file is now: its saved path, or wherever its bookmark points after a move or
    /// rename (not the Trash). Bookmarks and the reading position saved for the old path move with it.
    private func resolveFileURL(path: String) -> URL? {
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let oldKey = DocumentID(url: URL(fileURLWithPath: path)).normalizedPath
        guard let data = fileBookmarks[oldKey] ?? fileBookmarks[path] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ),
            !url.path.contains("/.Trash/"),
            FileManager.default.fileExists(atPath: url.path) else {
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

    private func moveSavedState(from oldKey: String, to newKey: String) {
        if let bookmarks = bookmarksByDocument.removeValue(forKey: oldKey) {
            bookmarksByDocument[newKey] = bookmarks
        }
        if let position = readingPositions.removeValue(forKey: oldKey) {
            readingPositions[newKey] = position
        }
        if let data = fileBookmarks.removeValue(forKey: oldKey) {
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
