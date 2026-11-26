import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI

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
    /// Only Arabic book page numbers are exposed. Front-matter titles and Roman labels use PDF positions.
    public var printedNumber: String? {
        label.flatMap(PageNumberLabel.positiveNumber).map(String.init)
    }
}

/// Clear Margins for one document: the crop boxes it came with, the content boxes found for it, and the work
/// finding them on a private copy of the document off the main thread
/// Restoring several scanned tabs must not run a Vision scan for each of them at the same time.
actor BookPageScanQueue {
    static let shared = BookPageScanQueue()
    func scan(url: URL, password: String?) -> BookPageScan? {
        guard !Task.isCancelled, let document = PDFDocumentLoader.openCopy(of: url, password: password) else { return nil }
        let scan = BookPageScanner.scan(document)
        return Task.isCancelled ? nil : scan
    }
}

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
    }

    deinit { task?.cancel() }

    /// Sets the content boxes known so far (or puts the original ones back) and finds the others, pages around
    /// `focus` first
    func apply(enabled: Bool, around focus: Int) {
        task?.cancel()
        task = nil
        isEnabled = enabled
        // Opening a document must not instantiate every PDFPage. Remember a page's original box only
        // when we are about to crop it; spread padding is removed by the alignment record.
        let missing = enabled ? (0..<document.pageCount).filter { tightCropBoxes[$0] == nil } : []
        let boxes = enabled ? tightCropBoxes : originalCropBoxes
        for (index, box) in boxes {
            guard let page = document.page(at: index) else { continue }
            if enabled, originalCropBoxes[index] == nil {
                originalCropBoxes[index] = SpreadAlignment.unalignedCropBox(for: page, at: index, in: document)
            }
            page.setBounds(box, for: .cropBox)
        }
        didChange()
        guard enabled, !missing.isEmpty else { return }

        let order = missing.sorted { abs($0 - focus) < abs($1 - focus) }
        let url = self.url
        let password = self.password
        task = Task.detached(priority: .utility) { [weak self] in
            guard let copy = PDFDocumentLoader.openCopy(of: url, password: password) else {
                await self?.computeOnMainThread(order)
                return
            }
            var batch: [(Int, CGRect)] = []
            var lastFlush = Date()
            for index in order {
                if Task.isCancelled { return }
                let box = autoreleasepool { copy.page(at: index).map { DocumentTabState.computeTightCropBox(for: $0) } }
                guard let box else { continue }
                batch.append((index, box))
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
            guard let page = document.page(at: index) else { continue }
            if originalCropBoxes[index] == nil {
                originalCropBoxes[index] = SpreadAlignment.unalignedCropBox(for: page, at: index, in: document)
            }
            page.setBounds(box, for: .cropBox)
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
        didSet {
            cachedPageIndicesByLabel = nil
            if cachedGeneratedOutline?.scan != pageScan {
                cachedGeneratedOutline = nil
            }
        }
    }
    var cachedGeneratedOutline: (scan: BookPageScan?, entries: [GeneratedOutlineEntry])?
    @Published public var isClearMarginsEnabled: Bool = false

    // Left Sidebar state
    @Published public var isLeftSidebarVisible: Bool = true
    @Published public var activeSidebarTab: ReaderSidebarTab = .thumbnails

    // Page Overview grid
    @Published public var isPageOverviewVisible: Bool = false

    // Split View state
    @Published public var splitMode: ReaderSplitMode = .disabled {
        didSet {
            if splitMode == .disabled {
                activatePane(isSecondary: false)
                if showSplitDocumentPicker { showSplitDocumentPicker = false }
            }
        }
    }
    @Published var splitDividerFractions: [ReaderSplitMode: CGFloat] = [:]
    weak var comparisonDropView: ComparisonDropView?
    @Published public var isSplitSwapped: Bool = false
    @Published public var syncScrollAndZoom: Bool = false
    @Published private var secondaryDocumentID: DocumentID?
    public var secondaryDocumentURL: URL? { secondaryDocumentID?.url }
    private var secondaryDocumentPassword: String?
    @Published public var secondaryPDFDocument: PDFDocument?
    @Published public var secondaryPageIndex: Int = 0
    @Published public var secondaryZoomScale: CGFloat = 1.0
    @Published public var secondaryIsAutoScaling: Bool = true
    @Published public var showSplitDocumentPicker: Bool = false
    @Published private var isSecondaryPaneActive = false

    private var hasSecondaryCanvas: Bool {
        splitMode != .disabled && !showSplitDocumentPicker && secondaryPDFDocument != nil
    }

    var targetsSecondaryPane: Bool { hasSecondaryCanvas && isSecondaryPaneActive }
    var activeZoomScale: CGFloat { targetsSecondaryPane ? secondaryZoomScale : zoomScale }
    var activePaneFitsWidth: Bool { targetsSecondaryPane ? secondaryIsAutoScaling : isAutoScaling }

    var currentPageForCopying: PDFPage? {
        let source = activeThumbnailSource
        return source.document.page(at: source.pageIndex)
    }

    func copyCurrentPageAsImage(in window: NSWindow?) {
        guard let page = currentPageForCopying, PageImageClipboard.canCopy(page) else { return }
        PageImageClipboard.beginCopy(page, in: window)
    }

    public var canPrintActiveDocument: Bool {
        let doc = activeThumbnailSource.document
        return doc.pageCount > 0 && doc.allowsPrinting
    }

    public func makePrintOperation() -> NSPrintOperation? {
        let doc = activeThumbnailSource.document
        guard doc.pageCount > 0, doc.allowsPrinting else { return nil }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        guard let operation = doc.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            return nil
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        let isSecondary = doc !== pdfDocument
        operation.jobTitle = isSecondary
            ? (secondaryDocumentURL?.deletingPathExtension().lastPathComponent ?? title)
            : title
        return operation
    }

    public func printActiveDocument(in window: NSWindow?) {
        guard let operation = makePrintOperation() else { return }
        if let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: targetWindow, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    var activeThumbnailSource: ReaderThumbnailSource {
        if targetsSecondaryPane, let document = secondaryPDFDocument, let id = secondaryDocumentID {
            let password = document === pdfDocument ? self.password : secondaryDocumentPassword
            return ReaderThumbnailSource(documentID: id, document: document, password: password,
                                         pageIndex: secondaryPageIndex)
        }
        return ReaderThumbnailSource(documentID: documentID, document: pdfDocument, password: password,
                                     pageIndex: currentPageIndex)
    }

    func thumbnailPageNumber(at index: Int, in document: PDFDocument) -> String {
        document === pdfDocument ? displayPageNumber(at: index) : "\(index + 1)"
    }

    func navigateToThumbnail(_ index: Int) {
        if targetsSecondaryPane {
            navigateSecondaryPane(to: index)
        } else {
            navigateToPage(index)
        }
    }

    func canOpenThumbnailInSplitView(source: ReaderThumbnailSource) -> Bool {
        !targetsSecondaryPane || source.document === pdfDocument
    }

    func openPageInSplitView(_ pageIndex: Int, from source: ReaderThumbnailSource) {
        guard canOpenThumbnailInSplitView(source: source), source.document.pageCount > 0 else { return }
        let clamped = max(0, min(source.document.pageCount - 1, pageIndex))
        syncScrollAndZoom = false
        if targetsSecondaryPane {
            withAnimation(AppAnimation.panel) {
                isPageOverviewVisible = false
            }
            navigateToPage(clamped)
            return
        }
        if secondaryPDFDocument !== pdfDocument {
            setSecondaryDocument(pdfDocument, id: documentID, password: password,
                                 pageIndex: clamped, activateSecondary: false)
        } else {
            showSplitDocumentPicker = false
            secondaryReadingSpot = nil
            secondaryPageIndex = clamped
            secondaryPageJumpToken &+= 1
        }
        if splitMode == .disabled {
            showSplitMode(.vertical)
        } else if isPageOverviewVisible {
            withAnimation(AppAnimation.panel) {
                isPageOverviewVisible = false
            }
        }
    }

    // Thumbnail Multi-Selection (per document currently shown in the thumbnail panel / overview)
    @Published public private(set) var selectedThumbnailPages: Set<Int> = []
    public private(set) var thumbnailSelectionAnchor: Int?
    private var thumbnailSelectionDocumentID: ObjectIdentifier?

    private func ensureThumbnailSelectionDocument(_ document: PDFDocument) {
        let docID = ObjectIdentifier(document)
        if thumbnailSelectionDocumentID != docID {
            selectedThumbnailPages.removeAll()
            thumbnailSelectionAnchor = nil
            thumbnailSelectionDocumentID = docID
        }
    }

    func selectedThumbnailPages(in source: ReaderThumbnailSource) -> Set<Int> {
        guard thumbnailSelectionDocumentID == ObjectIdentifier(source.document) else { return [] }
        return selectedThumbnailPages
    }

    func isThumbnailSelected(_ pageIndex: Int, in document: PDFDocument) -> Bool {
        thumbnailSelectionDocumentID == ObjectIdentifier(document) && selectedThumbnailPages.contains(pageIndex)
    }

    func toggleThumbnailSelection(_ pageIndex: Int, in source: ReaderThumbnailSource) {
        let count = source.document.pageCount
        guard (0..<count).contains(pageIndex) else { return }
        ensureThumbnailSelectionDocument(source.document)
        if selectedThumbnailPages.contains(pageIndex) {
            selectedThumbnailPages.remove(pageIndex)
            if thumbnailSelectionAnchor == pageIndex {
                thumbnailSelectionAnchor = selectedThumbnailPages.sorted().first
            }
        } else {
            selectedThumbnailPages.insert(pageIndex)
            thumbnailSelectionAnchor = pageIndex
        }
    }

    func selectThumbnailRange(to pageIndex: Int, in source: ReaderThumbnailSource, extending: Bool) {
        let count = source.document.pageCount
        guard (0..<count).contains(pageIndex) else { return }
        ensureThumbnailSelectionDocument(source.document)
        let anchor = thumbnailSelectionAnchor.flatMap { (0..<count).contains($0) ? $0 : nil }
            ?? ((0..<count).contains(source.pageIndex) ? source.pageIndex : pageIndex)
        let bounds = min(anchor, pageIndex)...max(anchor, pageIndex)
        if extending {
            selectedThumbnailPages.formUnion(bounds)
        } else {
            selectedThumbnailPages = Set(bounds)
        }
        if thumbnailSelectionAnchor == nil {
            thumbnailSelectionAnchor = anchor
        }
    }

    func clearThumbnailSelection(anchor: Int? = nil, in source: ReaderThumbnailSource? = nil) {
        if !selectedThumbnailPages.isEmpty {
            selectedThumbnailPages.removeAll()
        }
        if let anchor, let source, (0..<source.document.pageCount).contains(anchor) {
            thumbnailSelectionDocumentID = ObjectIdentifier(source.document)
            thumbnailSelectionAnchor = anchor
        } else if anchor == nil {
            thumbnailSelectionAnchor = nil
            if let source {
                thumbnailSelectionDocumentID = ObjectIdentifier(source.document)
            } else {
                thumbnailSelectionDocumentID = nil
            }
        }
    }

    func beginExportPanel(
        in window: NSWindow?,
        initialPages: [Int]? = nil,
        source: ReaderThumbnailSource? = nil,
        session: ReaderWindowSession? = nil
    ) {
        let targetSource = source ?? activeThumbnailSource
        let doc = targetSource.document
        guard doc.pageCount > 0 else { return }
        let isSecondary = doc !== pdfDocument
        let docTitle = isSecondary
            ? (secondaryDocumentURL?.deletingPathExtension().lastPathComponent ?? title)
            : title
        let usesBookNums = !isSecondary && !pageIndicesByLabel.isEmpty
        let context = PageExporter.ExportDocumentContext(
            document: doc,
            documentURL: targetSource.documentID.url,
            password: targetSource.password,
            documentTitle: docTitle,
            currentPageIndex: max(0, min(doc.pageCount - 1, targetSource.pageIndex)),
            usesBookNumbers: usesBookNums,
            labelForPage: { [weak self] idx in
                self?.thumbnailPageNumber(at: idx, in: doc) ?? "\(idx + 1)"
            },
            resolvePage: { [weak self] token in
                self?.pageIndex(forPageInput: token, inSecondaryPane: isSecondary)
            }
        )
        let pages: [Int]?
        if let initialPages, !initialPages.isEmpty {
            pages = initialPages
        } else {
            let selection = selectedThumbnailPages(in: targetSource)
            pages = selection.count > 1 ? selection.sorted() : nil
        }
        PageExporter.beginExportPanel(context: context, initialPages: pages, session: session, in: window)
    }

    public struct NavigationHistoryEntry: Equatable {
        public let pageIndex: Int
        public let point: CGPoint?

        public init(pageIndex: Int, point: CGPoint? = nil) {
            self.pageIndex = pageIndex
            self.point = point
        }
    }

    // Navigation History (Go Back / Go Forward)
    @Published private var backEntries: [NavigationHistoryEntry] = []
    private var forwardEntries: [NavigationHistoryEntry] = []
    public var backStack: [Int] { backEntries.map(\.pageIndex) }
    @Published public private(set) var jumpBackDestination: NavigationHistoryEntry?
    @Published public private(set) var jumpBackToken: Int = 0
    @Published public var isDocumentInfoPresented: Bool = false
    @Published public private(set) var customPageRotations: [Int: Int] = [:]
    private var originalPageRotations: [Int: Int] = [:]
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
    @Published private(set) var secondaryZoomCommandToken: Int = 0
    private(set) var pendingSecondaryZoomAction: ZoomAction?
    @Published public var pageJumpToken: Int = 0
    /// Page-space destination for the next jump (outline entries); `nil` lands on the page top.
    /// Components equal to kPDFDestinationUnspecifiedValue keep the current position on that axis.
    @Published public var pageJumpPoint: CGPoint?
    @Published private(set) var secondaryPageJumpToken: Int = 0
    /// Bumped when crop boxes change after layout (Clear Margins finishing in the background)
    @Published public var clearMarginsLayoutToken: Int = 0
    /// Bumped by Go › Go to Page… (⌥⌘G) to open the page counter's Go to Page popover
    @Published public var goToPageRequestToken: Int = 0
    /// Where in the current page the primary pane is scrolled to; kept apart from the tab's `@Published`
    /// state so scrolling only refreshes the outline, not the whole reader
    public let readingLocation = ReadingLocation()
    public let undoManager = UndoManager()

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
        ScannedPageCache.install(on: pdfDocument)
        let id = DocumentID(url: url)
        self.documentID = id
        self.pdfDocument = pdfDocument
        self.password = password
        self.title = url.deletingPathExtension().lastPathComponent
        // Default secondary pane to same document so split comparison works out-of-the-box
        self.secondaryDocumentID = id
        self.secondaryPDFDocument = pdfDocument
        self.declaresRightToLeft = pdfDocument.declaresRightToLeft
        // Takes the crop boxes before anything (two-page layouts, Clear Margins) changes them
        self.primaryCropper = makeCropper(for: pdfDocument, url: url, password: password)
    }

    deinit {
        searchTask?.cancel()
        pageScanTask?.cancel()
    }

    /// Follow a Finder rename without replacing the loaded document or losing its crop boxes and reading state.
    func relocate(to url: URL) {
        let previousID = documentID
        documentID = DocumentID(url: url)
        title = url.deletingPathExtension().lastPathComponent
        primaryCropper.url = url
        if secondaryDocumentID == previousID {
            secondaryDocumentID = documentID
        }
        pageScanTask?.cancel()
        pageScanTask = nil
        cachedGeneratedOutline = nil
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
        pageScanTask = Task.detached(priority: .utility) { [weak self] in
            // Let the visible page render first. Even text-layer detection belongs on this private copy;
            // querying sample pages in the live document used to stall opening image-heavy books.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let scan = await BookPageScanQueue.shared.scan(url: url, password: password) else { return }
            await self?.finishPageScan(scan)
        }
    }

    private func finishPageScan(_ scan: BookPageScan) {
        pageScanTask = nil
        pageScan = scan
    }

    func applyPageScanIfNeeded(_ scan: BookPageScan) {
        if pageScan == nil {
            pageScan = scan
        }
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
        layoutMode.visiblePageIndices(at: currentPageIndex, pageCount: pageCount)
    }

    public var pageCount: Int {
        pdfDocument.pageCount
    }

    /// Numeric book page numbers (a scanned book's "10" on its 31st page),
    /// label → page indices; empty when every label is just the page's position
    public var pageIndicesByLabel: [String: [Int]] {
        if let cached = cachedPageIndicesByLabel { return cached }
        var labels: CGPDFDictionaryRef?
        if pageScan?.printedNumbers?.replacesPageLabels != true,
           let catalog = pdfDocument.documentRef?.catalog,
           !CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels) {
            cachedPageIndicesByLabel = [:]
            return [:]
        }
        var map: [String: [Int]] = [:]
        var hasPrintedNumbers = pageScan?.printedNumbers?.replacesPageLabels == true
        for idx in 0..<pdfDocument.pageCount {
            guard let label = printedNumber(at: idx) else {
                hasPrintedNumbers = true
                continue
            }
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

    /// Page label without parenthetical wrapping for navigation HUDs ("Page 2" instead of "Page (2)").
    public func cleanPageLabel(at index: Int) -> String {
        printedNumber(at: index) ?? "\(index + 1)"
    }

    /// The page printed with this number; when numbering restarts per part, choose the nearest match.
    public func pageIndex(forLabel label: String, near pageIndex: Int? = nil) -> Int? {
        guard let number = PageNumberLabel.positiveNumber(label) else { return nil }
        let current = pageIndex ?? currentPageIndex
        return pageIndicesByLabel[String(number)]?.min { abs($0 - current) < abs($1 - current) }
    }

    /// Bare numbers address book pages when available. Parentheses always address positions in the PDF.
    public func pageIndex(forPageInput raw: String, inSecondaryPane: Bool = false) -> Int? {
        let count = inSecondaryPane ? secondaryPDFDocument?.pageCount ?? 0 : pageCount
        let input = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("("), input.hasSuffix(")"), input.count > 2 {
            guard let position = PageNumberLabel.positiveNumber(String(input.dropFirst().dropLast())),
                  position <= count else { return nil }
            return position - 1
        }
        if (!inSecondaryPane || secondaryPDFDocument === pdfDocument), !pageIndicesByLabel.isEmpty {
            return pageIndex(forLabel: input, near: inSecondaryPane ? secondaryPageIndex : currentPageIndex)
        }
        guard let number = PageNumberLabel.positiveNumber(input), number <= count else { return nil }
        return number - 1
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
            pageRotations: customPageRotations.isEmpty ? nil : customPageRotations,
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
        if var pageScan = position.bookPageScan, pageScan.version == BookPageScan.currentVersion {
            if let numbers = pageScan.printedNumbers {
                if numbers.isConsistentBookSequence(pageCount: pdfDocument.pageCount) {
                    pageScan.printedNumbers = BookPageScanner.refiningArticleOpening(numbers, in: pdfDocument)
                } else {
                    pageScan.printedNumbers = nil
                }
            }
            self.pageScan = pageScan
        }
        if let savedRotations = position.pageRotations, !savedRotations.isEmpty {
            for (idx, angle) in savedRotations where (0..<pageCount).contains(idx) {
                guard let page = pdfDocument.page(at: idx) else { continue }
                if originalPageRotations[idx] == nil {
                    originalPageRotations[idx] = page.rotation
                }
                let normalized = ((angle % 360) + 360) % 360
                if page.rotation != normalized {
                    page.rotation = normalized
                }
                if normalized != originalPageRotations[idx] {
                    customPageRotations[idx] = normalized
                }
            }
        }
    }

    /// Keeps `isAutoScaling` in sync with `PDFView.autoScales` (including native context-menu "Automatically Resize").
    public func updateAutoScalingFromView(_ autoScales: Bool) {
        if isAutoScaling != autoScales {
            isAutoScaling = autoScales
        }
    }

    public func stepPage(by direction: Int) {
        navigateToPage(layoutMode.pageIndex(afterStepping: direction, from: currentPageIndex, pageCount: pageCount))
    }

    func showReadingLayout(_ mode: ReaderLayoutMode) {
        isPageOverviewVisible = false
        layoutMode = mode
    }

    func showSplitMode(_ mode: ReaderSplitMode) {
        withAnimation(AppAnimation.panel) {
            isPageOverviewVisible = false
            splitMode = mode
        }
    }

    public func navigateToPage(
        _ index: Int,
        point: CGPoint? = nil,
        recordHistory: Bool = true
    ) {
        let clamped = max(0, min(max(0, pageCount - 1), index))
        // A precise point on the current page still scrolls; only a plain same-page jump is a no-op
        guard clamped != currentPageIndex || point != nil else { return }
        let previousPage = currentPageIndex
        readingSpot = nil
        if !isNavigatingHistory && clamped != previousPage {
            // Outline, thumbnail, bookmark, search, and Go to Page jumps never pop up the link-return banner.
            jumpBackDestination = nil
            if recordHistory {
                backEntries.append(NavigationHistoryEntry(pageIndex: previousPage, point: nil))
                if backEntries.count > 50 { backEntries.removeFirst() }
                forwardEntries.removeAll()
            }
        }
        currentPageIndex = clamped
        pageJumpPoint = point
        pageJumpToken &+= 1
        if syncScrollAndZoom && secondaryPDFDocument == pdfDocument {
            secondaryPageIndex = clamped
        }
    }

    /// Records an internal PDF link click in navigation history and surfaces the floating return pill.
    public func recordInternalLinkJump(from origin: ReadingSpot, to destinationPage: Int) {
        let clampedDest = max(0, min(max(0, pageCount - 1), destinationPage))
        let entry = NavigationHistoryEntry(pageIndex: origin.pageIndex, point: origin.point)
        backEntries.append(entry)
        if backEntries.count > 50 { backEntries.removeFirst() }
        forwardEntries.removeAll()
        if currentPageIndex != clampedDest {
            currentPageIndex = clampedDest
        }
        jumpBackDestination = entry
        jumpBackToken &+= 1
    }

    public func dismissJumpBackPrompt() {
        jumpBackDestination = nil
    }

    func navigateSecondaryPane(to index: Int) {
        guard let document = secondaryPDFDocument, (0..<document.pageCount).contains(index),
              index != secondaryPageIndex else { return }
        secondaryReadingSpot = nil
        secondaryPageIndex = index
        secondaryPageJumpToken &+= 1
        if syncScrollAndZoom && index < pageCount {
            navigateToPage(index, recordHistory: false)
        }
    }

    public var canGoBack: Bool { !backEntries.isEmpty }
    public var canGoForward: Bool { !forwardEntries.isEmpty }
    public var backDestinationPageIndex: Int? { backEntries.last?.pageIndex }
    public var forwardDestinationPageIndex: Int? { forwardEntries.last?.pageIndex }

    public func goBack() {
        guard let prev = backEntries.popLast() else { return }
        let currentSpotPoint = (readingSpot?.pageIndex == currentPageIndex) ? readingSpot?.point : nil
        readingSpot = nil
        jumpBackDestination = nil
        isNavigatingHistory = true
        forwardEntries.append(NavigationHistoryEntry(pageIndex: currentPageIndex, point: currentSpotPoint))
        currentPageIndex = prev.pageIndex
        pageJumpPoint = prev.point
        pageJumpToken &+= 1
        isNavigatingHistory = false
    }

    public func goForward() {
        guard let next = forwardEntries.popLast() else { return }
        let currentSpotPoint = (readingSpot?.pageIndex == currentPageIndex) ? readingSpot?.point : nil
        readingSpot = nil
        jumpBackDestination = nil
        isNavigatingHistory = true
        backEntries.append(NavigationHistoryEntry(pageIndex: currentPageIndex, point: currentSpotPoint))
        currentPageIndex = next.pageIndex
        pageJumpPoint = next.point
        pageJumpToken &+= 1
        isNavigatingHistory = false
    }

    func activatePane(isSecondary: Bool) {
        if isSecondaryPaneActive != isSecondary {
            isSecondaryPaneActive = isSecondary
            if thumbnailSelectionDocumentID != ObjectIdentifier(activeThumbnailSource.document) {
                clearThumbnailSelection()
            }
        }
    }

    public func triggerZoom(_ action: ZoomAction) {
        guard syncScrollAndZoom && hasSecondaryCanvas else {
            sendZoom(action, toSecondaryPane: targetsSecondaryPane)
            return
        }
        // A linked step starts from the active pane's zoom. Fit commands use each pane's own bounds.
        let linkedAction: ZoomAction
        switch action {
        case .zoomIn: linkedAction = .scale(activeZoomScale * 1.2)
        case .zoomOut: linkedAction = .scale(activeZoomScale / 1.2)
        default: linkedAction = action
        }
        sendZoom(linkedAction, toSecondaryPane: false)
        sendZoom(linkedAction, toSecondaryPane: true)
    }

    func syncManualZoom(_ scale: CGFloat, fromSecondaryPane: Bool) {
        guard syncScrollAndZoom, hasSecondaryCanvas, targetsSecondaryPane == fromSecondaryPane else { return }
        let otherScale = fromSecondaryPane ? zoomScale : secondaryZoomScale
        let otherFitsWidth = fromSecondaryPane ? isAutoScaling : secondaryIsAutoScaling
        if otherFitsWidth || abs(scale - otherScale) > 0.005 {
            sendZoom(.scale(scale), toSecondaryPane: !fromSecondaryPane)
        }
    }

    private func sendZoom(_ action: ZoomAction, toSecondaryPane: Bool) {
        let fitsWidth: Bool
        if case .fitWidth = action { fitsWidth = true } else { fitsWidth = false }
        if toSecondaryPane {
            secondaryIsAutoScaling = fitsWidth
            pendingSecondaryZoomAction = action
            secondaryZoomCommandToken &+= 1
        } else {
            isAutoScaling = fitsWidth
            pendingZoomAction = action
            zoomCommandToken &+= 1
        }
    }

    public func showSidebarTab(_ sidebarTab: ReaderSidebarTab) {
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

    public func rotatePages(_ pageIndices: [Int], in document: PDFDocument? = nil, clockwise: Bool) {
        let targetDoc = document ?? activeThumbnailSource.document
        var seen = Set<Int>()
        let valid = pageIndices.filter { (0..<targetDoc.pageCount).contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return }
        let delta = clockwise ? 90 : -90
        let rotations: [(Int, Int)] = valid.compactMap { idx in
            guard let page = targetDoc.page(at: idx) else { return nil }
            let next = ((page.rotation + delta) % 360 + 360) % 360
            return (idx, next)
        }
        guard !rotations.isEmpty else { return }
        let actionName = clockwise ? L10n.tr("向右旋转", "Rotate Right") : L10n.tr("向左旋转", "Rotate Left")
        applyPageRotations(rotations, in: targetDoc, actionName: actionName)
    }

    private func applyPageRotations(_ rotations: [(Int, Int)], in document: PDFDocument, actionName: String) {
        let previous: [(Int, Int)] = rotations.compactMap { idx, _ in
            guard let page = document.page(at: idx) else { return nil }
            if document === pdfDocument && originalPageRotations[idx] == nil {
                originalPageRotations[idx] = page.rotation
            }
            return (idx, page.rotation)
        }
        guard !previous.isEmpty else { return }
        for (idx, newRotation) in rotations {
            document.page(at: idx)?.rotation = newRotation
            if document === pdfDocument {
                let normalized = ((newRotation % 360) + 360) % 360
                if normalized == originalPageRotations[idx] {
                    customPageRotations.removeValue(forKey: idx)
                } else {
                    customPageRotations[idx] = normalized
                }
            }
        }
        rememberReadingSpots()
        let indexSet = Set(rotations.map(\.0))
        let affectsPrimaryCurrent = document === pdfDocument && indexSet.contains(currentPageIndex)
        let affectsSecondaryCurrent = document === secondaryPDFDocument && indexSet.contains(secondaryPageIndex)
        if affectsPrimaryCurrent {
            readingSpot = nil
            readingSpotBeforeCropChange = nil
            pageJumpPoint = nil
            pageJumpToken &+= 1
        }
        if affectsSecondaryCurrent {
            secondaryReadingSpot = nil
            secondaryReadingSpotBeforeCropChange = nil
            secondaryPageJumpToken &+= 1
        }
        clearMarginsLayoutToken &+= 1
        undoManager.registerUndo(withTarget: self) { [weak document] tab in
            MainActor.assumeIsolated {
                guard let document else { return }
                tab.applyPageRotations(previous, in: document, actionName: actionName)
            }
        }
        if !undoManager.isUndoing && !undoManager.isRedoing {
            undoManager.setActionName(actionName)
        }
    }

    public func rotatePage(at pageIndex: Int, in document: PDFDocument? = nil, clockwise: Bool) {
        rotatePages([pageIndex], in: document, clockwise: clockwise)
    }

    public func rotateCurrentPage(clockwise: Bool) {
        let source = activeThumbnailSource
        rotatePages([source.pageIndex], in: source.document, clockwise: clockwise)
    }

    public func setSecondaryDocument(url: URL) {
        guard let loaded = PDFDocumentLoader.load(url: url) else { return }
        setSecondaryDocument(loaded.document, id: DocumentID(url: url), password: loaded.password, pageIndex: 0)
    }

    func setSecondaryDocument(from source: DocumentTabState) {
        if secondaryDocumentID == source.documentID {
            showSplitDocumentPicker = false
            activatePane(isSecondary: true)
        } else if source === self {
            setSecondaryDocument(pdfDocument, id: documentID, password: password, pageIndex: currentPageIndex)
        } else if let document = PDFDocumentLoader.openCopy(of: source.documentID.url, password: source.password) {
            // Keep page rotations and crop boxes independent from the source tab.
            ScannedPageCache.install(on: document)
            setSecondaryDocument(document, id: source.documentID, password: source.password,
                                 pageIndex: source.currentPageIndex)
        } else {
            setSecondaryDocument(url: source.documentID.url)
        }
    }

    private func setSecondaryDocument(_ document: PDFDocument, id: DocumentID, password: String?, pageIndex: Int,
                                      activateSecondary: Bool = true) {
        secondaryDocumentPassword = password
        secondaryDocumentID = id
        secondaryPageIndex = max(0, min(pageIndex, document.pageCount - 1))
        secondaryReadingSpot = nil
        secondaryReadingSpotBeforeCropChange = nil
        secondaryIsAutoScaling = true
        secondaryPDFDocument = document
        showSplitDocumentPicker = false
        if activateSecondary {
            activatePane(isSecondary: true)
        }
        if thumbnailSelectionDocumentID != ObjectIdentifier(activeThumbnailSource.document) {
            clearThumbnailSelection()
        }
        secondaryPageJumpToken &+= 1
        secondaryCropper = document === pdfDocument ? nil : makeCropper(for: document, url: id.url, password: password)
        if isClearMarginsEnabled {
            secondaryCropper?.apply(enabled: true, around: secondaryPageIndex)
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
            if !Task.isCancelled {
                await HybridDocumentSearch.enumerateOCRMatches(query: trimmed, document: document) { batch in
                    await self?.receiveOCRSearchMatches(batch, generation: generation)
                }
            }
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

    private func receiveOCRSearchMatches(_ matches: [OCRSearchMatch], generation: Int) {
        guard generation == searchGeneration, !matches.isEmpty else { return }
        let wasEmpty = searchMatches.isEmpty
        let selectedID = searchMatches.indices.contains(selectedMatchIndex) ? searchMatches[selectedMatchIndex].id : nil
        let nativeKeys = Set(searchMatches.filter { $0.selection != nil }.map { "\($0.pageIndex):\($0.snippet.lowercased())" })
        var seenOCRKeys = Set(
            searchMatches
                .filter { $0.selection == nil }
                .map { "\($0.pageIndex):\($0.ocrBounds.map { "\($0.origin.x.rounded()),\($0.origin.y.rounded())" }.joined(separator: ";"))" }
        )
        let additions = matches.compactMap { match -> SearchMatchItem? in
            let nativeKey = "\(match.pageIndex):\(match.snippet.lowercased())"
            guard !nativeKeys.contains(nativeKey) else { return nil }
            let boundsKey = "\(match.pageIndex):\(match.bounds.map { "\($0.origin.x.rounded()),\($0.origin.y.rounded())" }.joined(separator: ";"))"
            guard seenOCRKeys.insert(boundsKey).inserted else { return nil }
            return SearchMatchItem(pageIndex: match.pageIndex, snippet: match.snippet,
                                   ocrBounds: match.bounds)
        }
        guard !additions.isEmpty else { return }
        searchMatches.append(contentsOf: additions)
        searchMatches.sort { $0.pageIndex < $1.pageIndex }
        if wasEmpty, let first = searchMatches.first {
            selectedMatchIndex = 0
            navigateToPage(
                first.pageIndex,
                point: first.ocrBounds.first.map { CGPoint(x: $0.minX, y: $0.maxY) },
                recordHistory: false
            )
        } else if let selectedID, let newIndex = searchMatches.firstIndex(where: { $0.id == selectedID }) {
            selectedMatchIndex = newIndex
        } else if selectedMatchIndex >= searchMatches.count {
            selectedMatchIndex = max(0, searchMatches.count - 1)
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
