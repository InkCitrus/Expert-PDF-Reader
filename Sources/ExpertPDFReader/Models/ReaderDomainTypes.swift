import AppKit
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
    /// User-applied rotation overrides keyed by 0-based page index (`nil` when every page is at its PDF default)
    public var pageRotations: [Int: Int]? = nil
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

extension ReaderLayoutMode {
    /// The page or spread containing this index.
    func visiblePageIndices(at index: Int, pageCount: Int) -> [Int] {
        guard (0..<pageCount).contains(index) else { return [] }
        let partner: Int
        switch self {
        case .singlePage:
            return [index]
        case .twoPages:
            partner = index ^ 1
        case .twoPagesCover:
            // The first page stands alone, then (2, 3), (4, 5)…
            guard index != 0 else { return [index] }
            partner = index % 2 == 1 ? index + 1 : index - 1
        }
        guard (0..<pageCount).contains(partner) else { return [index] }
        return [min(index, partner), max(index, partner)]
    }

    /// Step between complete visible spreads, regardless of which page PDFKit reports as current.
    public func pageIndex(afterStepping direction: Int, from index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let index = max(0, min(index, pageCount - 1))
        guard direction != 0 else { return index }
        if self == .singlePage { return max(0, min(pageCount - 1, index + (direction > 0 ? 1 : -1))) }
        let start = self == .twoPages ? index - index % 2 : (index == 0 ? 0 : 1 + (index - 1) / 2 * 2)
        let target: Int
        if self == .twoPagesCover && start == 0 { target = direction > 0 ? 1 : -1 }
        else if self == .twoPagesCover && start == 1 && direction < 0 { target = 0 }
        else { target = start + (direction > 0 ? 2 : -2) }
        return (0..<pageCount).contains(target) ? target : index
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
    /// Native PDF text has a PDFKit selection; OCR-only pages instead carry page-space rectangles.
    public let selection: PDFSelection?
    public let ocrBounds: [CGRect]

    public init(pageIndex: Int, snippet: String, selection: PDFSelection? = nil, ocrBounds: [CGRect] = []) {
        self.pageIndex = pageIndex
        self.snippet = snippet
        self.selection = selection
        self.ocrBounds = ocrBounds
    }
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
        ScannedPageCache.install(on: document)
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
