import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI

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
    public let activeSidebarTab: ReaderSidebarTab
    public var tabGroupID: UUID? = nil
    public var tabGroupName: String? = nil
    public var tabGroupColor: TabGroupColor? = nil
}

public struct ExportActivityState: Equatable {
    public enum Phase: Equatable {
        case exporting(completed: Int, total: Int, formatLabel: String)
        case completed(pageCount: Int, formatLabel: String, outputURL: URL, isFolder: Bool)
    }

    public let id: UUID
    public var phase: Phase
}

@MainActor
public final class ReaderWindowSession: ObservableObject, Identifiable {
    public let id: UUID
    public let isPrimary: Bool
    @Published public var tabs: [AppTab] {
        didSet {
            if let lastID = lastDocumentTabID,
               !tabs.contains(where: { $0.id == lastID && !$0.isHome }) {
                lastDocumentTabID = nil
            }
            if case .create(_, let tabID, _) = tabGroupNameEdit, !tabs.contains(where: { $0.id == tabID }) {
                tabGroupNameEdit = nil
            }
            pruneTabGroups()
            onTabsChanged?()
        }
    }
    @Published public var selectedTabID: UUID {
        didSet {
            if case .document = tabs.first(where: { $0.id == selectedTabID }) {
                lastDocumentTabID = selectedTabID
            }
            revealSelectedTabGroup()
            onTabsChanged?()
        }
    }
    public var lastDocumentTabID: UUID?
    @Published public var tabGroups: [ReaderTabGroup] = [] {
        didSet {
            if case .rename(let id) = tabGroupNameEdit, !tabGroups.contains(where: { $0.id == id }) {
                tabGroupNameEdit = nil
            }
            onTabsChanged?()
        }
    }
    @Published var tabGroupNameEdit: TabGroupNameEdit?
    var editingTabGroupID: UUID? { tabGroupNameEdit?.groupID }
    var onTabsChanged: (() -> Void)?
    weak var tabStripView: NSView?
    let tabViews = ReaderTabViewRegistry()
    let tabGroupViews = ReaderTabViewRegistry()
    weak var sidebarTabHoverView: SidebarTabHoverView?
    /// A drag changes the displayed order only; Escape and leaving the strip restore it immediately.
    @Published var tabDragPreview: TabStripDragPreview?
    @Published public var homeCurrentPage: HomeTabPage = .home
    @Published var isHomeSidebarVisible = true
    @Published public var isShortcutsSheetPresented: Bool = false
    @Published public var shortcutsInitialCategory: ShortcutGuideCategory = .all
    @Published public var exportActivity: ExportActivityState?
    private var activeExportID: UUID?
    private var exportTask: Task<Void, Never>?
    private var exportDelayTask: Task<Void, Never>?
    private var exportDismissTask: Task<Void, Never>?
    private var isExportToastHovered = false
    public weak var nsWindow: NSWindow?
    var cancellables = Set<AnyCancellable>()

    public init(id: UUID = UUID(), isPrimary: Bool, tabs: [AppTab], selectedTabID: UUID) {
        self.id = id
        self.isPrimary = isPrimary
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        if case .document = tabs.first(where: { $0.id == selectedTabID }) {
            self.lastDocumentTabID = selectedTabID
        }
    }

    public var returnableDocumentTabID: UUID? {
        if let lastDocumentTabID, tabs.contains(where: { $0.id == lastDocumentTabID && !$0.isHome }) {
            return lastDocumentTabID
        }
        return tabs.last(where: { !$0.isHome })?.id
    }

    public var activeDocumentTab: DocumentTabState? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }),
              case .document(let state) = tab else {
            return nil
        }
        return state
    }

    @MainActor
    func startExportActivity(id: UUID, total: Int, formatLabel: String, task: Task<Void, Never>) {
        exportDelayTask?.cancel()
        exportDismissTask?.cancel()
        exportTask?.cancel()
        activeExportID = id
        exportTask = task
        exportDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.activeExportID == id else { return }
            withAnimation(AppAnimation.toast) {
                self.exportActivity = ExportActivityState(
                    id: id,
                    phase: .exporting(completed: 0, total: total, formatLabel: formatLabel)
                )
            }
        }
    }

    @MainActor
    func updateExportProgress(id: UUID, completed: Int, total: Int, formatLabel: String) {
        guard activeExportID == id else { return }
        if completed > 0, exportDelayTask != nil {
            exportDelayTask?.cancel()
            exportDelayTask = nil
        }
        guard exportActivity?.id == id || completed > 0 else { return }
        let update = ExportActivityState(
            id: id,
            phase: .exporting(completed: completed, total: total, formatLabel: formatLabel)
        )
        if exportActivity?.id == id {
            exportActivity = update
        } else {
            withAnimation(AppAnimation.toast) {
                exportActivity = update
            }
        }
    }

    @MainActor
    func completeExportActivity(
        id: UUID,
        pageCount: Int,
        formatLabel: String,
        outputURL: URL,
        isFolder: Bool
    ) {
        guard activeExportID == id else { return }
        exportDelayTask?.cancel()
        exportDelayTask = nil
        exportDismissTask?.cancel()
        exportTask = nil
        withAnimation(AppAnimation.toast) {
            exportActivity = ExportActivityState(
                id: id,
                phase: .completed(
                    pageCount: pageCount,
                    formatLabel: formatLabel,
                    outputURL: outputURL,
                    isFolder: isFolder
                )
            )
        }
        scheduleExportDismiss(for: id)
    }

    @MainActor
    func failOrCancelExportActivity(id: UUID) {
        guard activeExportID == id else { return }
        exportDelayTask?.cancel()
        exportDelayTask = nil
        exportDismissTask?.cancel()
        exportTask = nil
        activeExportID = nil
        if exportActivity?.id == id {
            withAnimation(AppAnimation.toast) {
                exportActivity = nil
            }
        }
    }

    @MainActor
    func cancelActiveExport() {
        exportDelayTask?.cancel()
        exportDelayTask = nil
        exportDismissTask?.cancel()
        exportTask?.cancel()
        exportTask = nil
        activeExportID = nil
        if exportActivity != nil {
            withAnimation(AppAnimation.toast) {
                exportActivity = nil
            }
        }
    }

    @MainActor
    func dismissExportToast() {
        exportDismissTask?.cancel()
        exportDismissTask = nil
        isExportToastHovered = false
        if exportActivity != nil {
            withAnimation(AppAnimation.toast) {
                exportActivity = nil
            }
        }
    }

    @MainActor
    func setExportToastHovered(_ hovered: Bool) {
        isExportToastHovered = hovered
        if hovered {
            exportDismissTask?.cancel()
            exportDismissTask = nil
        } else if case .completed = exportActivity?.phase, let id = exportActivity?.id {
            scheduleExportDismiss(for: id)
        }
    }

    @MainActor
    func revealExportedItemInFinder() {
        guard case .completed(_, _, let outputURL, _) = exportActivity?.phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        dismissExportToast()
    }

    @MainActor
    private func scheduleExportDismiss(for id: UUID) {
        exportDismissTask?.cancel()
        guard !isExportToastHovered else { return }
        exportDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(4500))
            guard !Task.isCancelled, let self, !self.isExportToastHovered,
                  self.exportActivity?.id == id else { return }
            withAnimation(AppAnimation.toast) {
                self.exportActivity = nil
            }
            if self.activeExportID == id {
                self.activeExportID = nil
            }
        }
    }
}

// MARK: - Thumbnail Cache

struct ReaderThumbnailSource {
    let documentID: DocumentID
    let document: PDFDocument
    let password: String?
    let pageIndex: Int
}

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

        init(source: ReaderThumbnailSource, pageIndex: Int, rotation: Int, theme: PDFViewTheme, size: CGSize) {
            documentID = source.documentID.id
            documentURL = source.documentID.url
            password = source.password
            self.pageIndex = pageIndex
            self.rotation = rotation
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
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            get { lock.withLock { cancelled } }
            set { lock.withLock { cancelled = newValue } }
        }
    }

    private nonisolated static let renderQueue = DispatchQueue(label: "io.github.inkcitrus.expertpdfreader.thumbnails", qos: .utility)
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
