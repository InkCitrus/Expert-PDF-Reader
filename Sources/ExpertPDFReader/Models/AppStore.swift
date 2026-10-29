import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - URL Symlink Normalization (from HomeTab/Utils/URL+SymlinkNormalized.swift)

extension URL {
    /// Returns `standardizedFileURL.resolvingSymlinksInPath()` so `/var/...` and `/private/var/...` converge.
    public var symlinkNormalizedURL: URL {
        self.standardizedFileURL.resolvingSymlinksInPath()
    }
}

// MARK: - DocumentID

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
    /// Optional so positions saved before these existed still decode
    public var pageDirection: PageDirection?
    /// The result of reading the book's printed page numbers, so it is done once per book
    public var bookPageScan: BookPageScan?
    public var readingSpot: DocumentTabState.ReadingSpot?
    public var updatedAt: Date
}

/// Which way two-page spreads and ← / → run: as detected, or as the reader chose for this book
public enum PageDirection: String, Codable, CaseIterable, Identifiable {
    case automatic
    case leftToRight
    case rightToLeft

    public var id: String { rawValue }

    /// "Automatic (Right to Left)": the automatic choice names the direction it settled on
    public func title(detectedRightToLeft: Bool) -> String {
        switch self {
        case .automatic:
            let detected = (detectedRightToLeft ? PageDirection.rightToLeft : .leftToRight).title(detectedRightToLeft: false)
            return L10n.parenthetical(L10n.tr("自动", "Automatic"), detected)
        case .leftToRight:
            return L10n.tr("从左往右", "Left to Right")
        case .rightToLeft:
            return L10n.tr("从右往左", "Right to Left")
        }
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
public enum ReaderLeftPanel: String, Codable {
    case documentSummary = "documentSummary"
    case viewSettings = "viewSettings"
}

public enum ReaderSidebarTab: String, CaseIterable, Identifiable, Codable {
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

/// The reading line of the primary pane (a quarter of the view below its top edge) in page space,
/// so the outline can tell which of several sections on the same page is being read.
@MainActor
public final class ReadingLocation: ObservableObject {
    @Published public private(set) var pageIndex: Int = -1
    /// PDF page coordinates (origin bottom-left); a heading above this line counts as reached
    @Published public private(set) var readingLineY: CGFloat = 0

    public func update(pageIndex: Int, readingLineY: CGFloat) {
        // Publishing every scroll step would redraw the outline continuously
        guard pageIndex != self.pageIndex || abs(readingLineY - self.readingLineY) > 12 else { return }
        self.pageIndex = pageIndex
        self.readingLineY = readingLineY
    }
}

extension PDFDocument {
    /// `/ViewerPreferences /Direction /R2L`: the PDF asks to be read right to left
    public var declaresRightToLeft: Bool {
        guard let catalog = documentRef?.catalog else { return false }
        var preferences: CGPDFDictionaryRef?
        var direction: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &preferences), let preferences,
              CGPDFDictionaryGetName(preferences, "Direction", &direction), let direction else { return false }
        return String(cString: direction) == "R2L"
    }
}

extension PDFPage {
    /// The number printed on the page per the PDF's page labels; scans often give their unnumbered
    /// front matter an empty label, which counts as none
    public var printedNumber: String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        return label
    }
}

/// Clear Margins for one document: the crop boxes it came with, the content boxes found for it, and the work
/// finding them on a private copy of the document off the main thread
@MainActor
final class ClearMarginsCropper {
    let document: PDFDocument
    var url: URL
    private let password: String?
    private var originalCropBoxes: [Int: CGRect] = [:]
    private var tightCropBoxes: [Int: CGRect] = [:]
    private var task: Task<Void, Never>?
    private var isEnabled = false
    /// Called before crop boxes found in the background change, and after any change
    var willChange: () -> Void = {}
    var didChange: () -> Void = {}

    init(document: PDFDocument, url: URL, password: String?) {
        self.document = document
        self.url = url
        self.password = password
        for index in 0..<document.pageCount {
            originalCropBoxes[index] = document.page(at: index)?.bounds(for: .cropBox)
        }
    }

    /// Sets the content boxes known so far (or puts the original ones back) and finds the others, pages around
    /// `focus` first
    func apply(enabled: Bool, around focus: Int) {
        task?.cancel()
        task = nil
        isEnabled = enabled
        var missing: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if enabled {
                if let tight = tightCropBoxes[index] {
                    page.setBounds(tight, for: .cropBox)
                } else {
                    missing.append(index)
                }
            } else if let original = originalCropBoxes[index] {
                page.setBounds(original, for: .cropBox)
            }
        }
        didChange()
        guard enabled, !missing.isEmpty else { return }

        let order = missing.sorted { abs($0 - focus) < abs($1 - focus) }
        let url = self.url
        let password = self.password
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let copy = PDFDocumentLoader.openCopy(of: url, password: password) else {
                await self?.computeOnMainThread(order)
                return
            }
            var batch: [(Int, CGRect)] = []
            var lastFlush = Date()
            for index in order {
                if Task.isCancelled { return }
                guard let page = copy.page(at: index) else { continue }
                batch.append((index, DocumentTabState.computeTightCropBox(for: page)))
                if batch.count >= 24 || Date().timeIntervalSince(lastFlush) > 0.25 {
                    await self?.receive(batch)
                    batch.removeAll()
                    lastFlush = Date()
                }
            }
            await self?.receive(batch)
        }
    }

    private func receive(_ boxes: [(Int, CGRect)]) {
        guard !boxes.isEmpty else { return }
        for (index, box) in boxes {
            tightCropBoxes[index] = box
        }
        // Clear Margins may have been turned off while this batch was on its way
        guard isEnabled else { return }
        willChange()
        for (index, box) in boxes {
            document.page(at: index)?.setBounds(box, for: .cropBox)
        }
        didChange()
    }

    /// Fallback when the file cannot be reopened (e.g. it was moved after opening)
    private func computeOnMainThread(_ indices: [Int]) {
        receive(indices.compactMap { index in
            document.page(at: index).map { (index, DocumentTabState.computeTightCropBox(for: $0, within: originalCropBoxes[index])) }
        })
    }
}

@MainActor
public final class DocumentTabState: ObservableObject, Identifiable {
    public let id: UUID = UUID()
    @Published public private(set) var documentID: DocumentID
    public let pdfDocument: PDFDocument
    @Published public private(set) var title: String
    /// Password that unlocked an encrypted document; needed to read the file again off the main thread
    let password: String?
    var cancellables = Set<AnyCancellable>()

    @Published public var currentPageIndex: Int = 0
    @Published public var zoomScale: CGFloat = 1.0
    /// Mirrors `PDFView.autoScales` (fit width); when `false` the view keeps `zoomScale`
    @Published public var isAutoScaling: Bool = true
    @Published public var layoutMode: ReaderLayoutMode = .singlePage
    /// Books bound on the right (vertical Chinese and Japanese, manga): two-page layouts put the earlier page
    /// on the right and ← / → swap, like SumatraPDF's manga mode
    @Published public var pageDirection: PageDirection = .automatic
    /// What the book's pages show (printed page numbers, reading direction); `nil` until they have been read
    @Published public private(set) var pageScan: BookPageScan? {
        didSet { cachedPageIndicesByLabel = nil }
    }
    @Published public var isClearMarginsEnabled: Bool = false

    // Left Sidebar state
    @Published public var isLeftSidebarVisible: Bool = true
    @Published public var leftPanel: ReaderLeftPanel = .documentSummary
    @Published public var activeSidebarTab: ReaderSidebarTab = .thumbnails

    // Page Overview grid (toolbar "Page Management" button, read-only here)
    @Published public var isPageOverviewVisible: Bool = false

    // Split View state
    @Published public var splitMode: ReaderSplitMode = .disabled
    @Published public var isSplitSwapped: Bool = false
    @Published public var syncScrollAndZoom: Bool = false
    @Published public var secondaryDocumentURL: URL?
    @Published public var secondaryPDFDocument: PDFDocument?
    @Published public var secondaryPageIndex: Int = 0
    @Published public var secondaryZoomScale: CGFloat = 1.0
    @Published public var secondaryIsAutoScaling: Bool = true
    @Published public var showSplitDocumentPicker: Bool = false

    // Navigation History (Go Back / Go Forward)
    @Published public private(set) var backStack: [Int] = []
    @Published public private(set) var forwardStack: [Int] = []
    private var isNavigatingHistory: Bool = false

    // Search state; `isSearchVisible` drives the right results dock
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
    /// Bumped by Go › Go to Page… (⌥⌘G) to open the page counter's Go to Page popover
    @Published public var goToPageRequestToken: Int = 0
    /// Where in the current page the primary pane is scrolled to; kept apart from the tab's `@Published`
    /// state so scrolling only refreshes the outline, not the whole reader
    public let readingLocation = ReadingLocation()

    public enum ZoomAction {
        case zoomIn
        case zoomOut
        case actualSize
        case fitWidth
        case fitPage
        case scale(CGFloat)
    }

    // Cached original mediaBox and computed tight cropBox per page index
    private var primaryCropper: ClearMarginsCropper!
    /// For a different document picked for Split View
    private var secondaryCropper: ClearMarginsCropper?

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var pageScanTask: Task<Void, Never>?
    private let declaresRightToLeft: Bool

    public init(url: URL, pdfDocument: PDFDocument, password: String? = nil) {
        self.documentID = DocumentID(url: url)
        self.pdfDocument = pdfDocument
        self.password = password
        self.title = url.deletingPathExtension().lastPathComponent
        // Default secondary pane to same document so split comparison works out-of-the-box
        self.secondaryDocumentURL = url
        self.secondaryPDFDocument = pdfDocument
        self.declaresRightToLeft = pdfDocument.declaresRightToLeft
        // Takes the crop boxes before anything (two-page layouts, Clear Margins) changes them
        self.primaryCropper = makeCropper(for: pdfDocument, url: url, password: password)
    }

    /// Follow a Finder rename without replacing the loaded document or losing its crop boxes and reading state.
    func relocate(to url: URL) {
        let previousID = documentID
        documentID = DocumentID(url: url)
        title = url.deletingPathExtension().lastPathComponent
        primaryCropper.url = url
        if secondaryDocumentURL.map(DocumentID.init(url:)) == previousID {
            secondaryDocumentURL = url
        }
        pageScanTask?.cancel()
        pageScanTask = nil
        scanPagesIfNeeded()
        if isSearching { performSearch() }
    }

    /// The direction the PDF declares, else the one read from its pages, unless chosen for this book
    public var readsRightToLeft: Bool {
        switch pageDirection {
        case .leftToRight: return false
        case .rightToLeft: return true
        case .automatic: return detectedRightToLeft
        }
    }

    public var detectedRightToLeft: Bool {
        declaresRightToLeft || pageScan?.readsRightToLeft == true
    }

    /// Reads the printed page numbers on a sample of pages in the background, once per book
    public func scanPagesIfNeeded() {
        guard pageScan == nil, pageScanTask == nil, pageCount >= 16 else { return }
        let url = documentID.url
        let password = self.password
        let isFastText = BookPageScanner.hasEmbeddedText(pdfDocument)
        pageScanTask = Task.detached(priority: .utility) { [weak self] in
            // Digital PDFs finish in milliseconds; image scans wait briefly so the first visible page renders first
            try? await Task.sleep(nanoseconds: isFastText ? 80_000_000 : 1_200_000_000)
            guard !Task.isCancelled, let document = PDFDocumentLoader.openCopy(of: url, password: password) else { return }
            let scan = BookPageScanner.scan(document)
            await self?.finishPageScan(scan)
        }
    }

    private func finishPageScan(_ scan: BookPageScan) {
        pageScanTask = nil
        pageScan = scan
    }

    /// The number printed on a page: read from the page itself where the PDF's labels are wrong or missing,
    /// else the PDF's page label
    public func printedNumber(at index: Int) -> String? {
        if let numbers = pageScan?.printedNumbers, numbers.replacesPageLabels {
            return numbers.label(at: index)
        }
        return pdfDocument.page(at: index)?.printedNumber
    }

    /// The pages shown side by side with the current one: its spread in two-page layouts
    public var visiblePageIndices: [Int] {
        let index = currentPageIndex
        let partner: Int?
        switch layoutMode {
        case .singlePage:
            partner = nil
        case .twoPages:
            partner = index ^ 1
        case .twoPagesCover:
            // The first page stands alone, then (2, 3), (4, 5)…
            partner = index == 0 ? nil : (index % 2 == 1 ? index + 1 : index - 1)
        }
        guard let partner, partner >= 0, partner < pageCount else { return [index] }
        return [min(index, partner), max(index, partner)]
    }

    public var pageCount: Int {
        pdfDocument.pageCount
    }

    /// Printed page numbers from the PDF's page labels (a scanned book's "iv" or "10" on its 31st page),
    /// label → page indices; empty when every label is just the page's position
    public var pageIndicesByLabel: [String: [Int]] {
        if let cached = cachedPageIndicesByLabel { return cached }
        var map: [String: [Int]] = [:]
        var hasPrintedNumbers = false
        for idx in 0..<pdfDocument.pageCount {
            guard let label = printedNumber(at: idx) else { continue }
            map[label, default: []].append(idx)
            if label != "\(idx + 1)" { hasPrintedNumbers = true }
        }
        let index = hasPrintedNumbers ? map : [:]
        cachedPageIndicesByLabel = index
        return index
    }

    private var cachedPageIndicesByLabel: [String: [Int]]?

    /// A page's number as the reader shows it: the printed number, else its position — in parentheses when
    /// other pages do have printed numbers, so the cover's "(6)" can't be mistaken for the printed page 6
    public func displayPageNumber(at index: Int) -> String {
        if let printed = printedNumber(at: index) { return printed }
        return pageIndicesByLabel.isEmpty ? "\(index + 1)" : "(\(index + 1))"
    }

    /// The page printed with `label`, ignoring case only when nothing matches exactly (a book may letter its
    /// cover pages "A", "B"… and number the preface "i", "ii"…); when several pages share it (numbering
    /// restarts per part), the one nearest to the current page
    public func pageIndex(forLabel label: String) -> Int? {
        let candidates = pageIndicesByLabel[label]
            ?? pageIndicesByLabel.filter { $0.key.caseInsensitiveCompare(label) == .orderedSame }.flatMap(\.value)
        return candidates.min { abs($0 - currentPageIndex) < abs($1 - currentPageIndex) }
    }

    public var readingPosition: ReadingPosition {
        ReadingPosition(
            pageIndex: currentPageIndex,
            zoomScale: Double(zoomScale),
            isAutoScaling: isAutoScaling,
            layoutMode: layoutMode,
            pageDirection: pageDirection,
            bookPageScan: pageScan,
            readingSpot: readingSpot,
            updatedAt: Date()
        )
    }

    /// Applied before the reader view is created; `PDFReaderCanvasView` picks it up in `makeNSView`.
    public func restore(_ position: ReadingPosition) {
        currentPageIndex = max(0, min(position.pageIndex, pageCount - 1))
        zoomScale = CGFloat(position.zoomScale)
        isAutoScaling = position.isAutoScaling
        layoutMode = position.layoutMode
        readingSpot = position.readingSpot
        if let pageDirection = position.pageDirection {
            self.pageDirection = pageDirection
        }
        if let pageScan = position.bookPageScan, pageScan.version == BookPageScan.currentVersion {
            self.pageScan = pageScan
        }
    }

    /// Keeps `isAutoScaling` in sync with `PDFView.autoScales` (including native context-menu "Automatically Resize")
    /// and clears any stale `pendingZoomAction` when auto-scaling is active so switching tabs never replays an old zoom.
    public func updateAutoScalingFromView(_ autoScales: Bool) {
        if isAutoScaling != autoScales {
            isAutoScaling = autoScales
        }
        if autoScales {
            pendingZoomAction = nil
        }
    }

    public func navigateToPage(_ index: Int, recordHistory: Bool = true) {
        let clamped = max(0, min(max(0, pageCount - 1), index))
        guard clamped != currentPageIndex else { return }
        readingSpot = nil
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
        readingSpot = nil
        isNavigatingHistory = true
        forwardStack.append(currentPageIndex)
        currentPageIndex = prev
        pageJumpToken &+= 1
        isNavigatingHistory = false
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        readingSpot = nil
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
            self.secondaryIsAutoScaling = true
            self.showSplitDocumentPicker = false
            secondaryCropper = makeCropper(for: loaded.document, url: url, password: loaded.password)
            if isClearMarginsEnabled {
                secondaryCropper?.apply(enabled: true, around: 0)
            }
        }
    }

    // MARK: - Clear Margins (智能去白边)

    /// Applies the crop boxes already known right away; the others are computed off the main thread (pages
    /// around the current one first) and applied in batches. The Split View's other document is cropped too.
    public func applyClearMarginsIfNeeded() {
        // Once for both documents: after the first one changes, its pane's spot no longer holds
        rememberReadingSpots()
        primaryCropper.apply(enabled: isClearMarginsEnabled, around: currentPageIndex)
        secondaryCropper?.apply(enabled: isClearMarginsEnabled, around: secondaryPageIndex)
    }

    private func makeCropper(for document: PDFDocument, url: URL, password: String?) -> ClearMarginsCropper {
        let cropper = ClearMarginsCropper(document: document, url: url, password: password)
        cropper.willChange = { [weak self] in self?.rememberReadingSpots() }
        // Pages showing the crop boxes just set (or put back) need laying out again
        cropper.didChange = { [weak self] in self?.clearMarginsLayoutToken &+= 1 }
        return cropper
    }

    /// The point of the page at the top of a pane
    public struct ReadingSpot: Codable, Equatable {
        public let pageIndex: Int
        public let point: CGPoint

        public init(pageIndex: Int, point: CGPoint) {
            self.pageIndex = pageIndex
            self.point = point
        }
    }

    /// Kept up to date by the panes while scrolling
    public var readingSpot: ReadingSpot?
    public var secondaryReadingSpot: ReadingSpot?
    /// Taken before the crop boxes change: once they do, the views lay the pages out anew and their own idea of
    /// the scroll position no longer points at the same text
    public private(set) var readingSpotBeforeCropChange: ReadingSpot?
    public private(set) var secondaryReadingSpotBeforeCropChange: ReadingSpot?

    private func rememberReadingSpots() {
        readingSpotBeforeCropChange = readingSpot
        secondaryReadingSpotBeforeCropChange = secondaryReadingSpot
    }

    /// The bounding box of the page's ink within `region` (its own crop box by default, so a print proof's crop
    /// marks and slug outside the trim are not content), with a little margin. The page is drawn unrotated:
    /// crop boxes live in that space whatever way the page is turned.
    nonisolated static func computeTightCropBox(for page: PDFPage, within region: CGRect? = nil) -> CGRect {
        let mediaBounds = page.bounds(for: .mediaBox)
        let area = (region ?? page.bounds(for: .cropBox)).intersection(mediaBounds)
        guard !area.isNull, area.width > 40, area.height > 40 else { return region ?? mediaBounds }

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
            return area.insetBy(dx: area.width * 0.08, dy: area.height * 0.08)
        }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(sampleW) / area.width, y: CGFloat(sampleH) / area.height)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        if let pageRef = page.pageRef {
            // The page's content in its own space: `PDFPage.draw(with:to:)` would apply its rotation
            ctx.drawPDFPage(pageRef)
        } else {
            page.draw(with: .mediaBox, to: ctx)
        }
        ctx.restoreGState()

        var minX = sampleW
        var maxX = 0
        var minY = sampleH
        var maxY = 0
        let threshold: UInt8 = 246
        // Ink right at the edge is a scanner's shadow or a trim line, not content
        let edge = 2

        for y in edge..<(sampleH - edge) {
            for x in edge..<(sampleW - edge) {
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
            return area
        }

        let scaleX = area.width / CGFloat(sampleW)
        let scaleY = area.height / CGFloat(sampleH)
        let pad: CGFloat = 14.0

        let rx = max(area.minX, area.minX + CGFloat(minX) * scaleX - pad)
        let ry = max(area.minY, area.minY + CGFloat(minY) * scaleY - pad)
        let rMaxX = min(area.maxX, area.minX + CGFloat(maxX + 1) * scaleX + pad)
        let rMaxY = min(area.maxY, area.minY + CGFloat(maxY + 1) * scaleY + pad)

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

    @MainActor public var title: String {
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

public struct ClosedTabRecord: Codable, Equatable {
    public let documentID: DocumentID
    public let tabIndex: Int
    public let isClearMarginsEnabled: Bool
    public let isLeftSidebarVisible: Bool
    public let leftPanel: ReaderLeftPanel
    public let activeSidebarTab: ReaderSidebarTab
}

@MainActor
public final class ReaderWindowSession: ObservableObject, Identifiable {
    public let id: UUID
    public let isPrimary: Bool
    @Published public var tabs: [AppTab] {
        didSet { onTabsChanged?() }
    }
    @Published public var selectedTabID: UUID {
        didSet { onTabsChanged?() }
    }
    var onTabsChanged: (() -> Void)?
    weak var tabStripView: NSView?
    let tabViews = NSMapTable<NSUUID, NSView>.strongToWeakObjects()
    @Published public var homeCurrentPage: HomeTabPage = .home
    @Published public var isShortcutsSheetPresented: Bool = false
    @Published public var shortcutsInitialCategory: ShortcutGuideCategory = .all
    public weak var nsWindow: NSWindow?
    var cancellables = Set<AnyCancellable>()

    public init(id: UUID = UUID(), isPrimary: Bool, tabs: [AppTab], selectedTabID: UUID) {
        self.id = id
        self.isPrimary = isPrimary
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }

    public var activeDocumentTab: DocumentTabState? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }),
              case .document(let state) = tab else {
            return nil
        }
        return state
    }
}

// MARK: - Thumbnail Cache

@MainActor
public final class PDFThumbnailCache: ObservableObject {
    public static let shared = PDFThumbnailCache()

    // Bounded by bytes so long documents scrolled in the thumbnail panel / page overview don't grow memory forever
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    public struct ThumbnailRequest: Hashable, Sendable {
        public let documentID: String
        public let documentURL: URL
        public let password: String?
        public let pageIndex: Int
        public let rotation: Int
        public let theme: PDFViewTheme
        public let size: CGSize

        @MainActor
        public init(tab: DocumentTabState, pageIndex: Int, theme: PDFViewTheme, size: CGSize) {
            documentID = tab.documentID.id
            documentURL = tab.documentID.url
            password = tab.password
            self.pageIndex = pageIndex
            rotation = tab.pdfDocument.page(at: pageIndex)?.rotation ?? 0
            self.theme = theme
            self.size = size
        }

        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
        public func hash(into hasher: inout Hasher) { hasher.combine(key) }

        var key: String {
            "\(documentID)#\(pageIndex)#\(theme.rawValue)#\(Int(size.width))x\(Int(size.height))#\(rotation)"
        }
    }

    /// A thumbnail already rendered, to draw without waiting
    public func cachedThumbnail(for request: ThumbnailRequest) -> NSImage? {
        cache.object(forKey: request.key as NSString)
    }

    /// Renders off the main thread, one page at a time, from a private copy of the document: the pages of a large
    /// scanned guidebook each take a moment to decode, which stalled the thumbnail panel and the page overview.
    /// Requests whose thumbnail scrolled away before its turn are skipped.
    public func thumbnail(for request: ThumbnailRequest) async -> NSImage? {
        if let cached = cachedThumbnail(for: request) {
            return cached
        }
        let cancellation = RenderCancellation()
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.renderQueue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: Self.render(request))
                }
            }
        } onCancel: {
            cancellation.isCancelled = true
        }
        if let image {
            cache.setObject(image, forKey: request.key as NSString, cost: Self.byteCost(of: image))
        }
        return image
    }

    private final class RenderCancellation: @unchecked Sendable {
        var isCancelled = false
    }

    private nonisolated static let renderQueue = DispatchQueue(label: "io.github.inkcitrus.expertpdfreader.thumbnails", qos: .userInitiated)
    /// Document copies for rendering, used only on `renderQueue`
    private nonisolated(unsafe) static var renderDocuments: [String: PDFDocument] = [:]

    private nonisolated static func render(_ request: ThumbnailRequest) -> NSImage? {
        let document: PDFDocument
        if let open = renderDocuments[request.documentID] {
            document = open
        } else {
            guard let copy = PDFDocumentLoader.openCopy(of: request.documentURL, password: request.password) else { return nil }
            if renderDocuments.count >= 6 {
                renderDocuments.removeAll()
            }
            renderDocuments[request.documentID] = copy
            document = copy
        }
        guard let page = document.page(at: request.pageIndex) else { return nil }
        page.rotation = request.rotation
        return themedImage(page.thumbnail(of: request.size, for: .cropBox), theme: request.theme)
    }

    /// HomeTab cover thumbnails: shader output cached per document + theme so hover redraws stay cheap.
    public func themedCover(for item: DocumentItem, theme: PDFViewTheme) -> NSImage {
        guard theme != .day else { return item.thumbnail }
        let key = "cover#\(item.id)#\(ObjectIdentifier(item.thumbnail).hashValue)#\(theme.rawValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let themedImg = Self.themedImage(item.thumbnail, theme: theme)
        cache.setObject(themedImg, forKey: key, cost: Self.byteCost(of: themedImg))
        return themedImg
    }

    /// RGBA bytes of the largest bitmap representation (thumbnails may be backed at Retina scale)
    private nonisolated static func byteCost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(pixels, Int(image.size.width * image.size.height)) * 4
    }

    private nonisolated static func themedImage(_ baseImg: NSImage, theme: PDFViewTheme) -> NSImage {
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
            applyAppAppearance()
        }
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

    private var dateFormatter: DateFormatter
    nonisolated(unsafe) private var localeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var appDidBecomeActiveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var directoryWatchers: [String: (fd: Int32, source: DispatchSourceFileSystemObject)] = [:]
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
        static let readingPositions = "expertPDFReader.ReadingPositions"
        static let fileBookmarks = "expertPDFReader.FileBookmarks"
        static let openTabs = "expertPDFReader.OpenTabs"
        static let selectedTab = "expertPDFReader.SelectedTab"
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

        let savedAppRaw = defaults.string(forKey: "expertPDFReader.appearanceMode")
            ?? AppAppearanceMode.system.rawValue
        self.appearanceMode = AppAppearanceMode(rawValue: savedAppRaw) ?? .system

        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
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
        rebuildDirectoryWatchers()

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
    }

    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        if let appDidBecomeActiveObserver { NotificationCenter.default.removeObserver(appDidBecomeActiveObserver) }
        for entry in directoryWatchers.values { entry.source.cancel() }
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
        tabState.scanPagesIfNeeded()
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
        screenDropPoint: NSPoint? = nil
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
            screenDropPoint: screenDropPoint
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
        atDocumentIndex: Int? = nil
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
                for tab in detached.tabs {
                    if case .document(let docState) = tab {
                        primarySession.tabs.append(.document(docState))
                    }
                }
                detached.tabs.removeAll()
            }
            if let previouslyActiveDocID,
               primarySession.tabs.contains(where: { $0.id == previouslyActiveDocID }) {
                primarySession.selectedTabID = previouslyActiveDocID
            } else if let lastTab = primarySession.tabs.last {
                primarySession.selectedTabID = lastTab.id
            }
            activeWindowSessionID = primarySession.id
        }

        for detached in sessionsToMerge {
            closeDetachedWindow(sessionID: detached.id, recordClosedTabs: false)
        }
        ensureSessionWindowVisible(primarySession)
        saveOpenTabs()
    }

    /// Finds another open reader window whose tab bar / top toolbar band contains `screenPoint`, in Z-order.
    public func dropTargetWindowAndIndex(
        atScreenPoint screenPoint: NSPoint,
        excluding sourceSessionID: UUID
    ) -> (session: ReaderWindowSession, documentIndex: Int)? {
        let orderedWindows = NSApp?.orderedWindows ?? []
        let candidateSessions = allWindowSessions.filter {
            $0.id != sourceSessionID && ($0.nsWindow?.isVisible == true)
        }
        let sortedSessions = candidateSessions.sorted { a, b in
            let ia = orderedWindows.firstIndex(where: { $0 === a.nsWindow }) ?? Int.max
            let ib = orderedWindows.firstIndex(where: { $0 === b.nsWindow }) ?? Int.max
            return ia < ib
        }

        for candidate in sortedSessions {
            guard let win = candidate.nsWindow else { continue }
            guard !win.isMiniaturized, candidate.containsTabStrip(screenPoint) else { continue }
            return (candidate, candidate.documentInsertionIndex(at: screenPoint))
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
            closedTabs.removeAll { $0.documentID == state.documentID }
            closedTabs.append(
                ClosedTabRecord(
                    documentID: state.documentID,
                    tabIndex: item.index,
                    isClearMarginsEnabled: state.isClearMarginsEnabled,
                    isLeftSidebarVisible: state.isLeftSidebarVisible,
                    leftPanel: state.leftPanel,
                    activeSidebarTab: state.activeSidebarTab
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
            state.leftPanel = record.leftPanel
            state.activeSidebarTab = record.activeSidebarTab
            if record.isClearMarginsEnabled {
                state.applyClearMarginsIfNeeded()
            }
            return
        }
        NSSound.beep()
    }

    public func selectNextTab(in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        guard targetSession.tabs.count > 1,
              let idx = targetSession.tabs.firstIndex(where: { $0.id == targetSession.selectedTabID }) else { return }
        performAnimated(AppAnimation.tab) {
            targetSession.selectedTabID = targetSession.tabs[(idx + 1) % targetSession.tabs.count].id
        }
    }

    public func selectPreviousTab(in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        guard targetSession.tabs.count > 1,
              let idx = targetSession.tabs.firstIndex(where: { $0.id == targetSession.selectedTabID }) else { return }
        performAnimated(AppAnimation.tab) {
            targetSession.selectedTabID = targetSession.tabs[(idx - 1 + targetSession.tabs.count) % targetSession.tabs.count].id
        }
    }

    /// Selects tab 1…8 directly, or the last tab when `number == 9` (like Safari / Chrome).
    @discardableResult
    public func selectTab(atShortcutNumber number: Int, in sessionID: UUID? = nil) -> Bool {
        let targetSession = session(withID: sessionID)
        guard !targetSession.tabs.isEmpty, (1...9).contains(number) else { return false }
        let targetIndex: Int
        if number == 9 {
            targetIndex = targetSession.tabs.count - 1
        } else {
            guard number - 1 < targetSession.tabs.count else { return false }
            targetIndex = number - 1
        }
        let targetID = targetSession.tabs[targetIndex].id
        if targetSession.selectedTabID != targetID {
            performAnimated(AppAnimation.tab) {
                targetSession.selectedTabID = targetID
            }
        }
        return true
    }

    /// Moves a document tab to `toDocumentIndex` among the open document tabs (keeping Home pinned at the start).
    public func moveDocumentTab(id: UUID, toDocumentIndex: Int, in sessionID: UUID? = nil) {
        let targetSession = session(withID: sessionID)
        let homeCount = targetSession.tabs.prefix(while: \.isHome).count
        let docCount = targetSession.tabs.count - homeCount
        guard docCount > 1,
              let fromTabIndex = targetSession.tabs.firstIndex(where: { $0.id == id }),
              fromTabIndex >= homeCount else { return }
        let targetDocIndex = max(0, min(docCount - 1, toDocumentIndex))
        let toTabIndex = homeCount + targetDocIndex
        guard fromTabIndex != toTabIndex else { return }
        let moved = targetSession.tabs.remove(at: fromTabIndex)
        targetSession.tabs.insert(moved, at: toTabIndex)
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
        rebuildDirectoryWatchers()
    }

    public func clearAllRecents() {
        performAnimated(AppAnimation.snappy) {
            recentDocumentIDs.removeAll()
            documents.removeAll(where: { !favoriteDocumentIDs.contains($0.documentID) })
        }
        savePersistedState()
        rebuildDirectoryWatchers()
    }

    public func clearAllFavorites() {
        performAnimated(AppAnimation.snappy) {
            favoriteDocumentIDs.removeAll()
            for idx in documents.indices {
                documents[idx].isFavorite = false
            }
            documents.removeAll(where: { !recentDocumentIDs.contains($0.documentID) })
        }
        savePersistedState()
        rebuildDirectoryWatchers()
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
                    leftPanel: record.leftPanel,
                    activeSidebarTab: record.activeSidebarTab
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
        rebuildDirectoryWatchers()
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
                newState.leftPanel = oldState.leftPanel
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
        rebuildDirectoryWatchers()
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
        if let data = defaults.data(forKey: Keys.closedTabs),
           let decoded = try? decoder.decode([ClosedTabRecord].self, from: data) {
            closedTabs = decoded.compactMap { record in
                guard let url = resolveFileURL(path: record.documentID.normalizedPath) else { return nil }
                return ClosedTabRecord(
                    documentID: DocumentID(url: url),
                    tabIndex: record.tabIndex,
                    isClearMarginsEnabled: record.isClearMarginsEnabled,
                    isLeftSidebarVisible: record.isLeftSidebarVisible,
                    leftPanel: record.leftPanel,
                    activeSidebarTab: record.activeSidebarTab
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

        // Only keep file bookmarks of documents that are still remembered somewhere
        var remembered = Set(favPaths)
        remembered.formUnion(recentDocumentIDs.map(\.normalizedPath))
        remembered.formUnion(closedTabs.map(\.documentID.normalizedPath))
        remembered.formUnion(defaults.stringArray(forKey: Keys.openTabs) ?? [])
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

    private func rebuildDirectoryWatchers() {
        var wanted = Set<String>()
        for doc in documents {
            let parent = doc.documentID.url.deletingLastPathComponent().symlinkNormalizedURL.path
            if !parent.isEmpty {
                wanted.insert(parent)
            }
            if wanted.count >= 32 { break }
        }
        if let trashPath = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.symlinkNormalizedURL.path,
           FileManager.default.fileExists(atPath: trashPath) {
            wanted.insert(trashPath)
        }

        for (dir, entry) in Array(directoryWatchers) where !wanted.contains(dir) {
            entry.source.cancel()
            directoryWatchers.removeValue(forKey: dir)
        }

        for dir in wanted where directoryWatchers[dir] == nil {
            let fd = Darwin.open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.schedulePruneMissingDocuments()
                }
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.resume()
            directoryWatchers[dir] = (fd: fd, source: source)
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
