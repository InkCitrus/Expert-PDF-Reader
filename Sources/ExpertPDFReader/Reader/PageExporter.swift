import AppKit
import PDFKit
import QuartzCore
import UniformTypeIdentifiers

/// Parses and formats human-readable page ranges (such as "1-5, 8, 12-15") using either
/// PDF positions or printed book page numbers.
enum PageRangeParser {
    private static let segmentSeparators = CharacterSet(charactersIn: ",，、;；")
    private static let rangeDashes = CharacterSet(charactersIn: "-–—~～−")

    static func parse(_ raw: String, pageCount: Int, resolvePage: (String) -> Int?) -> [Int]? {
        guard pageCount > 0 else { return nil }
        let normalized = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let segments = normalized.components(separatedBy: segmentSeparators)
        var result: [Int] = []
        var seen = Set<Int>()

        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { return nil }

            let bounds = segment.components(separatedBy: rangeDashes)
            if bounds.count == 1 {
                guard let idx = resolvePage(segment), (0..<pageCount).contains(idx) else { return nil }
                if seen.insert(idx).inserted {
                    result.append(idx)
                }
            } else if bounds.count == 2 {
                let startToken = bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let endToken = bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !startToken.isEmpty, !endToken.isEmpty,
                      let start = resolvePage(startToken),
                      let end = resolvePage(endToken),
                      (0..<pageCount).contains(start),
                      (0..<pageCount).contains(end),
                      start <= end else {
                    return nil
                }
                for idx in start...end where seen.insert(idx).inserted {
                    result.append(idx)
                }
            } else {
                return nil
            }
        }

        return result.isEmpty ? nil : result
    }

    static func format(
        _ indices: [Int],
        pageCount: Int,
        labelFor: (Int) -> String,
        usesBookNumbers: Bool,
        resolvePage: (String) -> Int?
    ) -> String {
        guard pageCount > 0 else { return "" }
        var seen = Set<Int>()
        var unique: [Int] = []
        for idx in indices where (0..<pageCount).contains(idx) {
            if seen.insert(idx).inserted {
                unique.append(idx)
            }
        }
        guard !unique.isEmpty else { return "" }

        func buildRangeString(label: (Int) -> String) -> String {
            var parts: [String] = []
            var runStart = unique[0]
            var runEnd = unique[0]
            for idx in unique.dropFirst() {
                if idx == runEnd + 1 {
                    runEnd = idx
                } else {
                    parts.append(runStart == runEnd ? label(runStart) : "\(label(runStart))-\(label(runEnd))")
                    runStart = idx
                    runEnd = idx
                }
            }
            parts.append(runStart == runEnd ? label(runStart) : "\(label(runStart))-\(label(runEnd))")
            return parts.joined(separator: ", ")
        }

        let displayCandidate = buildRangeString(label: labelFor)
        if parse(displayCandidate, pageCount: pageCount, resolvePage: resolvePage) == unique {
            return displayCandidate
        }

        let positionLabel: (Int) -> String = usesBookNumbers
            ? { "(\($0 + 1))" }
            : { "\($0 + 1)" }
        return buildRangeString(label: positionLabel)
    }
}

/// Exports single or multi-page PDF documents and PNG/JPEG page images using a unified save panel.
enum PageExporter {
    enum Format: Int, CaseIterable {
        case pdf = 0
        case png = 1
        case jpeg = 2

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }

        var contentType: UTType {
            switch self {
            case .pdf: return .pdf
            case .png: return .png
            case .jpeg: return .jpeg
            }
        }

        var displayName: String {
            switch self {
            case .pdf: return "PDF"
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            }
        }

        var isImage: Bool {
            self != .pdf
        }
    }

    enum ImageResolution: Int, CaseIterable {
        case dpi144 = 0
        case dpi216 = 1
        case dpi300 = 2

        var dpi: Int {
            switch self {
            case .dpi144: return 144
            case .dpi216: return 216
            case .dpi300: return 300
            }
        }

        var scale: CGFloat {
            CGFloat(dpi) / 72.0
        }

        var maxEdgePixels: CGFloat {
            switch self {
            case .dpi144: return 3200
            case .dpi216: return 4200
            case .dpi300: return 5600
            }
        }

        var title: String {
            switch self {
            case .dpi144: return L10n.tr("144 DPI（标准）", "144 DPI (Standard)")
            case .dpi216: return L10n.tr("216 DPI（高清）", "216 DPI (High)")
            case .dpi300: return L10n.tr("300 DPI（打印）", "300 DPI (Print)")
            }
        }

        func pixelSize(for cropBox: CGRect, rotation: Int) -> CGSize? {
            guard cropBox.width.isFinite, cropBox.height.isFinite,
                  cropBox.width > 0, cropBox.height > 0 else { return nil }
            let rotated = rotation % 180 != 0
            let size = rotated ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
            let effectiveScale = min(scale, maxEdgePixels / max(size.width, size.height))
            return CGSize(
                width: max(1, Int(ceil(size.width * effectiveScale))),
                height: max(1, Int(ceil(size.height * effectiveScale)))
            )
        }
    }

    enum PageSelectionMode: Int, CaseIterable {
        case all = 0
        case current = 1
        case odd = 2
        case even = 3
        case range = 4
    }

    enum ExportError: LocalizedError {
        case unavailable
        case invalidPageRange

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return L10n.tr("无法导出此页。", "This page could not be exported.")
            case .invalidPageRange:
                return L10n.tr("请输入有效的页码范围", "Enter a valid page range")
            }
        }
    }

    struct ExportDocumentContext {
        let document: PDFDocument
        let documentURL: URL?
        let password: String?
        let documentTitle: String
        let currentPageIndex: Int
        let usesBookNumbers: Bool
        let labelForPage: (Int) -> String
        let resolvePage: (String) -> Int?
    }

    struct PageSpec: Sendable {
        let index: Int
        let cropBox: CGRect
        let rotation: Int
    }

    struct ImageExportItem: Sendable {
        let pageIndex: Int
        let label: String
        let snapshot: PageImageClipboard.PageSnapshot
    }

    static func sanitizeFilenameComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func suggestedFilename(documentTitle: String, format: Format) -> String {
        let cleanedTitle = sanitizeFilenameComponent(documentTitle)
        let safeTitle = cleanedTitle.isEmpty ? "Document" : cleanedTitle
        return "\(safeTitle) - \(L10n.tr("导出", "Export")).\(format.fileExtension)"
    }

    static func filename(_ name: String, for format: Format) -> String {
        let path = name as NSString
        switch path.pathExtension.lowercased() {
        case "pdf", "png", "jpg", "jpeg":
            let stem = path.deletingPathExtension
            let safeStem = stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Document" : stem
            return "\(safeStem).\(format.fileExtension)"
        default:
            return "\(name).\(format.fileExtension)"
        }
    }

    static func resolvePageIndices(
        mode: PageSelectionMode,
        rangeText: String,
        pageCount: Int,
        currentPageIndex: Int,
        resolvePage: (String) -> Int?
    ) -> [Int]? {
        guard pageCount > 0 else { return nil }
        switch mode {
        case .all:
            return Array(0..<pageCount)
        case .current:
            let clamped = max(0, min(pageCount - 1, currentPageIndex))
            return [clamped]
        case .odd:
            return Array(0..<pageCount).filter { $0 % 2 == 0 }
        case .even:
            let pages = Array(0..<pageCount).filter { $0 % 2 == 1 }
            return pages.isEmpty ? nil : pages
        case .range:
            return PageRangeParser.parse(rangeText, pageCount: pageCount, resolvePage: resolvePage)
        }
    }

    nonisolated static func uniqueExportFolderURL(for destinationURL: URL, fileManager: FileManager = .default) -> URL {
        let rawBase = destinationURL.deletingPathExtension()
        let parent = rawBase.deletingLastPathComponent()
        let baseName = rawBase.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Export"
            : rawBase.lastPathComponent
        let initial = parent.appendingPathComponent(baseName, isDirectory: true)
        if !fileManager.fileExists(atPath: initial.path) {
            return initial
        }
        var suffix = 2
        while true {
            let candidate = parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    static func multiPageImageFilename(
        stem: String,
        orderIndex: Int,
        pageIndex: Int,
        pageLabel: String,
        totalSelected: Int,
        totalPages: Int,
        isMonotonic: Bool,
        format: Format
    ) -> String {
        let cleanStem = sanitizeFilenameComponent(stem)
        let safeStem = cleanStem.isEmpty ? "Export" : cleanStem
        let cleanLabel = sanitizeFilenameComponent(pageLabel)

        if isMonotonic {
            let width = max(2, String(max(1, totalPages)).count)
            let paddedPosition = String(format: "%0*d", width, pageIndex + 1)
            let pdfPositionString = "\(pageIndex + 1)"
            if !cleanLabel.isEmpty && cleanLabel != pdfPositionString {
                return "\(safeStem) - \(paddedPosition) (\(cleanLabel)).\(format.fileExtension)"
            }
            return "\(safeStem) - \(paddedPosition).\(format.fileExtension)"
        }

        let orderWidth = max(2, String(max(1, totalSelected)).count)
        let orderPrefix = String(format: "%0*d", orderWidth, orderIndex + 1)
        let pageSuffix = cleanLabel.isEmpty ? "\(pageIndex + 1)" : cleanLabel
        return "\(safeStem) - \(orderPrefix) (p\(pageSuffix)).\(format.fileExtension)"
    }

    nonisolated static func applyFinderTags(_ tagNames: [String], to url: URL) {
        let cleaned = tagNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        try? (url as NSURL).setResourceValue(cleaned, forKey: .tagNamesKey)
    }

    nonisolated static func renderImageData(
        for snapshot: PageImageClipboard.PageSnapshot,
        resolution: ImageResolution,
        format: Format,
        jpegQuality: Double = 0.85
    ) throws -> Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let document = PDFDocument(data: snapshot.data),
                  let page = document.page(at: 0),
                  let pixelSize = resolution.pixelSize(for: snapshot.cropBox, rotation: snapshot.rotation) else {
                throw ExportError.unavailable
            }
            defer { withExtendedLifetime(document) {} }
            page.rotation = snapshot.rotation
            page.setBounds(snapshot.cropBox, for: .cropBox)

            let rotated = page.rotation % 180 != 0
            let pageSize = rotated
                ? CGSize(width: snapshot.cropBox.height, height: snapshot.cropBox.width)
                : snapshot.cropBox.size
            let scale = min(resolution.scale, resolution.maxEdgePixels / max(pageSize.width, pageSize.height))
            let width = Int(pixelSize.width)
            let height = Int(pixelSize.height)

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ExportError.unavailable
            }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            try Task.checkCancellation()

            guard let cgImage = context.makeImage() else {
                throw ExportError.unavailable
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            switch format {
            case .jpeg:
                let clamped = min(1.0, max(0.4, jpegQuality))
                guard let data = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: NSNumber(value: clamped)]
                ) else {
                    throw ExportError.unavailable
                }
                return data
            case .png, .pdf:
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw ExportError.unavailable
                }
                return data
            }
        }
    }

    static func writeMultiPageImages(
        items: [ImageExportItem],
        destinationURL: URL,
        resolution: ImageResolution,
        format: Format,
        jpegQuality: Double,
        totalPages: Int,
        tagNames: [String] = [],
        onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> URL {
        guard !items.isEmpty, format.isImage else { throw ExportError.unavailable }
        let indices = items.map(\.pageIndex)
        let isMonotonic = zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 }
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        let fileNames = items.enumerated().map { orderIndex, item in
            multiPageImageFilename(
                stem: stem,
                orderIndex: orderIndex,
                pageIndex: item.pageIndex,
                pageLabel: item.label,
                totalSelected: items.count,
                totalPages: totalPages,
                isMonotonic: isMonotonic,
                format: format
            )
        }

        let folderURL = try await Task.detached(priority: .userInitiated) { () -> URL in
            let fm = FileManager.default
            let folder = PageExporter.uniqueExportFolderURL(for: destinationURL, fileManager: fm)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    let data = try PageExporter.renderImageData(
                        for: item.snapshot,
                        resolution: resolution,
                        format: format,
                        jpegQuality: jpegQuality
                    )
                    try Task.checkCancellation()
                    let fileURL = folder.appendingPathComponent(fileNames[index])
                    try data.write(to: fileURL, options: .atomic)
                    PageExporter.applyFinderTags(tagNames, to: fileURL)
                    await MainActor.run {
                        onProgress(index + 1, items.count)
                    }
                }
                PageExporter.applyFinderTags(tagNames, to: folder)
                return folder
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
        }.value

        return folderURL
    }

    nonisolated static func pdfData(from snapshots: [PageImageClipboard.PageSnapshot]) throws -> Data {
        guard !snapshots.isEmpty else { throw ExportError.unavailable }
        let output = PDFDocument()
        for (outIndex, snapshot) in snapshots.enumerated() {
            try Task.checkCancellation()
            guard snapshot.cropBox.width.isFinite, snapshot.cropBox.height.isFinite,
                  snapshot.cropBox.width > 0, snapshot.cropBox.height > 0,
                  let singleDoc = PDFDocument(data: snapshot.data),
                  let page = singleDoc.page(at: 0) else {
                throw ExportError.unavailable
            }
            page.rotation = snapshot.rotation
            page.setBounds(snapshot.cropBox, for: .cropBox)
            output.insert(page, at: outIndex)
        }
        try Task.checkCancellation()
        guard output.pageCount == snapshots.count, let data = output.dataRepresentation() else {
            throw ExportError.unavailable
        }
        return data
    }

    nonisolated static func pdfData(from url: URL, password: String?, specs: [PageSpec]) throws -> Data {
        guard !specs.isEmpty,
              let source = PDFDocumentLoader.openCopy(of: url, password: password) else {
            throw ExportError.unavailable
        }
        let output = PDFDocument()
        var usedIndices = Set<Int>()
        for (outIndex, spec) in specs.enumerated() {
            try Task.checkCancellation()
            guard spec.cropBox.width.isFinite, spec.cropBox.height.isFinite,
                  spec.cropBox.width > 0, spec.cropBox.height > 0,
                  let original = source.page(at: spec.index) else {
                throw ExportError.unavailable
            }
            let page: PDFPage
            if usedIndices.insert(spec.index).inserted {
                page = original
            } else if let copied = original.copy() as? PDFPage {
                page = copied
            } else {
                page = original
            }
            page.rotation = spec.rotation
            page.setBounds(spec.cropBox, for: .cropBox)
            output.insert(page, at: outIndex)
        }
        try Task.checkCancellation()
        guard output.pageCount == specs.count, let data = output.dataRepresentation() else {
            throw ExportError.unavailable
        }
        return data
    }

    @MainActor static func pdfData(for pages: [PDFPage]) throws -> Data {
        guard !pages.isEmpty else { throw ExportError.unavailable }
        let snapshots: [PageImageClipboard.PageSnapshot]
        do {
            snapshots = try pages.map { try PageImageClipboard.snapshot(of: $0) }
        } catch {
            throw ExportError.unavailable
        }
        return try pdfData(from: snapshots)
    }

    @MainActor static func pdfData(for page: PDFPage) throws -> Data {
        try pdfData(for: [page])
    }

    @MainActor static func pngData(for page: PDFPage) async throws -> Data {
        let snapshot: PageImageClipboard.PageSnapshot
        do {
            snapshot = try PageImageClipboard.snapshot(of: page)
        } catch {
            throw ExportError.unavailable
        }
        return try await Task.detached(priority: .userInitiated) {
            try renderImageData(for: snapshot, resolution: .dpi216, format: .png)
        }.value
    }

    @MainActor static func beginExportPanel(
        context: ExportDocumentContext,
        initialPages: [Int]? = nil,
        session: ReaderWindowSession? = nil,
        in window: NSWindow?
    ) {
        let controller = PageExportPanelController(
            context: context,
            initialPages: initialPages,
            session: session,
            window: window
        )
        controller.present()
    }

    @MainActor static func presentError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("导出", "Export")
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
final class PageExportPanelController: NSObject, NSOpenSavePanelDelegate, NSTextFieldDelegate {
    private static var activeController: PageExportPanelController?

    private let context: PageExporter.ExportDocumentContext
    private weak var hostWindow: NSWindow?
    private weak var session: ReaderWindowSession?
    let panel = NSSavePanel()

    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pagesModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rangeField = NSTextField(string: "")
    private let resolutionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 0.85, minValue: 0.4, maxValue: 1.0, target: nil, action: nil)
    private let qualityValueLabel = NSTextField(labelWithString: "85%")
    private let statusLabel = NSTextField(labelWithString: "")

    private let formatRow = NSView()
    private let pagesRow = NSView()
    private let rangeRow = NSView()
    private let resolutionRow = NSView()
    private let qualityRow = NSView()
    private let statusRow = NSView()
    private var accessoryView: PageExportAccessoryView?

    private var selectedFormat: PageExporter.Format = .pdf
    private var selectedMode: PageExporter.PageSelectionMode
    private var selectedResolution: PageExporter.ImageResolution = .dpi216
    private var jpegQuality: Double = 0.85

    init(
        context: PageExporter.ExportDocumentContext,
        initialPages: [Int]?,
        session: ReaderWindowSession?,
        window: NSWindow?
    ) {
        self.context = context
        self.session = session
        self.hostWindow = window
        let pageCount = context.document.pageCount
        let sanitizedPages = (initialPages ?? []).filter { (0..<pageCount).contains($0) }
        self.selectedMode = sanitizedPages.isEmpty ? .all : .range
        super.init()

        let initialRangePages = sanitizedPages.isEmpty ? [context.currentPageIndex] : sanitizedPages
        rangeField.stringValue = PageRangeParser.format(
            initialRangePages,
            pageCount: pageCount,
            labelFor: context.labelForPage,
            usesBookNumbers: context.usesBookNumbers,
            resolvePage: context.resolvePage
        )
        configurePanel()
        refreshControlStates(animated: false)
    }

    private func configurePanel() {
        panel.nameFieldLabel = L10n.tr("导出为：", "Export As:")
        panel.prompt = L10n.tr("导出", "Export")
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.canCreateDirectories = true
        panel.showsTagField = true
        panel.isExtensionHidden = false
        panel.delegate = self

        let defaultFilename = PageExporter.suggestedFilename(documentTitle: context.documentTitle, format: .pdf)
        let usesSystemFormatRow: Bool
        if #available(macOS 15.0, *) {
            panel.showsContentTypes = true
            panel.nameFieldStringValue = defaultFilename
            usesSystemFormatRow = true
        } else {
            panel.isExtensionHidden = true
            panel.nameFieldStringValue = (defaultFilename as NSString).deletingPathExtension
            usesSystemFormatRow = false
            formatPopUp.addItems(withTitles: PageExporter.Format.allCases.map(\.displayName))
            formatPopUp.selectItem(at: selectedFormat.rawValue)
            formatPopUp.setAccessibilityLabel(L10n.tr("格式：", "Format:"))
            formatPopUp.target = self
            formatPopUp.action = #selector(legacyFormatChanged(_:))
        }

        let currentLabel = context.labelForPage(context.currentPageIndex)
        pagesModePopUp.autoenablesItems = false
        pagesModePopUp.addItems(withTitles: [
            L10n.tr("全部页面", "All Pages"),
            L10n.parenthetical(L10n.tr("当前页", "Current Page"), currentLabel),
            L10n.tr("奇数页", "Odd Pages"),
            L10n.tr("偶数页", "Even Pages"),
            L10n.tr("指定页码", "Page Range")
        ])
        if let evenItem = pagesModePopUp.item(at: PageExporter.PageSelectionMode.even.rawValue) {
            evenItem.isEnabled = context.document.pageCount >= 2
        }
        pagesModePopUp.selectItem(at: selectedMode.rawValue)
        pagesModePopUp.setAccessibilityLabel(L10n.tr("页面：", "Pages:"))
        pagesModePopUp.target = self
        pagesModePopUp.action = #selector(pagesModeChanged)

        rangeField.placeholderString = "1–5, 8, 12–15"
        rangeField.setAccessibilityLabel(L10n.tr("指定页码", "Page Range"))
        rangeField.font = .systemFont(ofSize: 13)
        rangeField.delegate = self

        resolutionPopUp.addItems(withTitles: PageExporter.ImageResolution.allCases.map(\.title))
        resolutionPopUp.selectItem(at: selectedResolution.rawValue)
        resolutionPopUp.setAccessibilityLabel(L10n.tr("清晰度：", "Resolution:"))
        resolutionPopUp.target = self
        resolutionPopUp.action = #selector(resolutionChanged)

        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.setAccessibilityLabel(L10n.tr("质量：", "Quality:"))

        qualityValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityValueLabel.textColor = .secondaryLabelColor
        qualityValueLabel.alignment = .right
        qualityValueLabel.stringValue = "\(Int((jpegQuality * 100).rounded()))%"

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail

        let accessory = buildAccessoryView(includeFormatRow: !usesSystemFormatRow)
        accessoryView = accessory
        panel.accessoryView = accessory
    }

    private func buildAccessoryView(includeFormatRow: Bool) -> PageExportAccessoryView {
        // Match the native Save Panel compact form geometry (390pt total on macOS 15+,
        // 380pt on macOS 14; 230pt control column with 40.5pt right margin and 8pt label gap).
        let formWidth: CGFloat = includeFormatRow ? 380 : 390
        let fieldWidth: CGFloat = 230
        let trailingInset: CGFloat = 40.5
        let labelGap: CGFloat = 8
        let verticalInset: CGFloat = 14

        var rows: [NSView] = []
        if includeFormatRow {
            configureLabeledRow(formatRow, title: L10n.tr("格式：", "Format:"), control: formatPopUp, fieldWidth: fieldWidth, gap: labelGap)
            rows.append(formatRow)
        }

        configureLabeledRow(pagesRow, title: L10n.tr("页面：", "Pages:"), control: pagesModePopUp, fieldWidth: fieldWidth, gap: labelGap)
        rows.append(pagesRow)

        configureControlOnlyRow(rangeRow, control: rangeField, fieldWidth: fieldWidth)
        rows.append(rangeRow)

        configureLabeledRow(resolutionRow, title: L10n.tr("清晰度：", "Resolution:"), control: resolutionPopUp, fieldWidth: fieldWidth, gap: labelGap)
        rows.append(resolutionRow)

        let qualityControl = NSStackView(views: [qualitySlider, qualityValueLabel])
        qualityControl.orientation = .horizontal
        qualityControl.alignment = .centerY
        qualityControl.spacing = 8
        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityValueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        configureLabeledRow(qualityRow, title: L10n.tr("质量：", "Quality:"), control: qualityControl, fieldWidth: fieldWidth, gap: labelGap)
        rows.append(qualityRow)

        configureControlOnlyRow(statusRow, control: statusLabel, fieldWidth: fieldWidth)
        rows.append(statusRow)

        return PageExportAccessoryView(
            panel: panel,
            rows: rows,
            rangeRow: rangeRow,
            resolutionRow: resolutionRow,
            qualityRow: qualityRow,
            formWidth: formWidth,
            fieldWidth: fieldWidth,
            compactOffset: (formWidth - fieldWidth) / 2 - trailingInset,
            verticalInset: verticalInset
        )
    }

    private func configureLabeledRow(
        _ row: NSView,
        title: String,
        control: NSView,
        fieldWidth: CGFloat,
        gap: CGFloat
    ) {
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.init(200), for: .horizontal)

        row.addSubview(label)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: fieldWidth),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            label.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -gap),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor)
        ])
    }

    private func configureControlOnlyRow(_ row: NSView, control: NSView, fieldWidth: CGFloat) {
        row.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.init(200), for: .horizontal)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            control.widthAnchor.constraint(equalToConstant: fieldWidth),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
    }

    func present() {
        Self.activeController = self
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer {
                if Self.activeController === self {
                    Self.activeController = nil
                }
            }
            guard response == .OK, let destinationURL = self.panel.url else { return }
            let tags = self.panel.tagNames?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
            self.startExport(to: destinationURL, tagNames: tags)
        }
        if let hostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, displayNameFor type: UTType) -> String? {
        switch type {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        default: return nil
        }
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, didSelect type: UTType?) {
        switch type {
        case .png: selectFormat(.png)
        case .jpeg: selectFormat(.jpeg)
        default: selectFormat(.pdf)
        }
    }

    @objc private func legacyFormatChanged(_ sender: NSPopUpButton) {
        let format = PageExporter.Format(rawValue: sender.indexOfSelectedItem) ?? .pdf
        selectFormat(format)
        let currentName = panel.nameFieldStringValue
        if !currentName.isEmpty {
            panel.nameFieldStringValue = PageExporter.filename(currentName, for: format)
        }
    }

    private func selectFormat(_ format: PageExporter.Format) {
        guard selectedFormat != format else { return }
        selectedFormat = format
        refreshControlStates(animated: true)
    }

    @objc private func pagesModeChanged() {
        selectedMode = PageExporter.PageSelectionMode(rawValue: pagesModePopUp.indexOfSelectedItem) ?? .all
        refreshControlStates(animated: true)
        if selectedMode == .range {
            panel.makeFirstResponder(rangeField)
        }
    }

    @objc private func resolutionChanged() {
        selectedResolution = PageExporter.ImageResolution(rawValue: resolutionPopUp.indexOfSelectedItem) ?? .dpi216
        updateStatus()
    }

    @objc private func qualityChanged() {
        jpegQuality = qualitySlider.doubleValue
        qualityValueLabel.stringValue = "\(Int((jpegQuality * 100).rounded()))%"
    }

    func controlTextDidChange(_ notification: Notification) {
        updateStatus()
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed: Bool) -> String? {
        guard confirmed, !filename.isEmpty else { return filename }
        return PageExporter.filename(filename, for: selectedFormat)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard let indices = resolvedPageIndices(), let firstPage = indices.first else {
            panel.makeFirstResponder(rangeField)
            shakeRangeField()
            throw PageExporter.ExportError.invalidPageRange
        }
        guard PageImageClipboard.canCopy(context.document.page(at: firstPage)) else {
            throw PageExporter.ExportError.unavailable
        }
        if !url.pathExtension.lowercased().isEmpty,
           url.pathExtension.lowercased() != selectedFormat.fileExtension,
           !(selectedFormat == .jpeg && url.pathExtension.lowercased() == "jpeg") {
            throw PageExporter.ExportError.unavailable
        }
    }

    func resolvedPageIndices() -> [Int]? {
        PageExporter.resolvePageIndices(
            mode: selectedMode,
            rangeText: rangeField.stringValue,
            pageCount: context.document.pageCount,
            currentPageIndex: context.currentPageIndex,
            resolvePage: context.resolvePage
        )
    }

    private func refreshControlStates(animated: Bool) {
        let showRange = selectedMode == .range
        let showResolution = selectedFormat.isImage
        let showQuality = selectedFormat == .jpeg
        updateStatus()
        accessoryView?.setRowVisibility(
            rangeVisible: showRange,
            resolutionVisible: showResolution,
            qualityVisible: showQuality,
            animated: animated
        )
    }

    private func updateStatus() {
        guard let indices = resolvedPageIndices(), !indices.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = PageExporter.ExportError.invalidPageRange.localizedDescription
            return
        }
        statusLabel.textColor = .secondaryLabelColor
        if !selectedFormat.isImage {
            statusLabel.stringValue = L10n.exportPageCountSummary(indices.count)
            return
        }
        let pixelSize: CGSize?
        if indices.count == 1, let page = context.document.page(at: indices[0]) {
            let cropBox = SpreadAlignment.unalignedCropBox(for: page, at: indices[0], in: context.document)
            pixelSize = selectedResolution.pixelSize(for: cropBox, rotation: page.rotation)
        } else {
            pixelSize = nil
        }
        statusLabel.stringValue = L10n.exportImageSummary(
            count: indices.count,
            formatName: selectedFormat.displayName,
            pixelSize: pixelSize
        )
    }

    private func shakeRangeField() {
        guard !AppAnimation.reduceMotion else { return }
        rangeField.wantsLayer = true
        guard let layer = rangeField.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.duration = 0.28
        animation.values = [0, -6, 6, -4, 4, -2, 2, 0]
        layer.add(animation, forKey: "invalidRangeShake")
    }

    private func startExport(to destinationURL: URL, tagNames: [String]) {
        guard let indices = resolvedPageIndices(), !indices.isEmpty else {
            PageExporter.presentError(PageExporter.ExportError.invalidPageRange, in: hostWindow)
            return
        }

        let pages = indices.compactMap { context.document.page(at: $0) }
        guard pages.count == indices.count, pages.allSatisfy({ PageImageClipboard.canCopy($0) }) else {
            PageExporter.presentError(PageExporter.ExportError.unavailable, in: hostWindow)
            return
        }

        let exportID = UUID()
        let format = selectedFormat
        let resolution = selectedResolution
        let quality = jpegQuality
        let totalPages = context.document.pageCount
        let labels = indices.map { context.labelForPage($0) }
        let session = self.session
        let window = self.hostWindow

        switch format {
        case .png, .jpeg:
            let items: [PageExporter.ImageExportItem]
            do {
                items = try zip(zip(indices, labels), pages).map { pair, page in
                    let (index, label) = pair
                    return PageExporter.ImageExportItem(
                        pageIndex: index,
                        label: label,
                        snapshot: try PageImageClipboard.snapshot(of: page)
                    )
                }
            } catch {
                PageExporter.presentError(PageExporter.ExportError.unavailable, in: hostWindow)
                return
            }

            if items.count == 1 {
                let singleSnapshot = items[0].snapshot
                let task = Task(priority: .userInitiated) { [weak window, weak session] in
                    do {
                        let data = try await Task.detached(priority: .userInitiated) {
                            try PageExporter.renderImageData(
                                for: singleSnapshot,
                                resolution: resolution,
                                format: format,
                                jpegQuality: quality
                            )
                        }.value
                        try Task.checkCancellation()
                        try data.write(to: destinationURL, options: .atomic)
                        PageExporter.applyFinderTags(tagNames, to: destinationURL)
                        session?.completeExportActivity(
                            id: exportID,
                            pageCount: 1,
                            formatLabel: format.displayName,
                            outputURL: destinationURL,
                            isFolder: false
                        )
                    } catch is CancellationError {
                        session?.failOrCancelExportActivity(id: exportID)
                    } catch {
                        session?.failOrCancelExportActivity(id: exportID)
                        PageExporter.presentError(error, in: window)
                    }
                }
                session?.startExportActivity(
                    id: exportID,
                    total: 1,
                    formatLabel: format.displayName,
                    task: task
                )
            } else {
                let task = Task(priority: .userInitiated) { [weak window, weak session] in
                    do {
                        let folderURL = try await PageExporter.writeMultiPageImages(
                            items: items,
                            destinationURL: destinationURL,
                            resolution: resolution,
                            format: format,
                            jpegQuality: quality,
                            totalPages: totalPages,
                            tagNames: tagNames
                        ) { completed, total in
                            session?.updateExportProgress(
                                id: exportID,
                                completed: completed,
                                total: total,
                                formatLabel: format.displayName
                            )
                        }
                        session?.completeExportActivity(
                            id: exportID,
                            pageCount: items.count,
                            formatLabel: format.displayName,
                            outputURL: folderURL,
                            isFolder: true
                        )
                    } catch is CancellationError {
                        session?.failOrCancelExportActivity(id: exportID)
                    } catch {
                        session?.failOrCancelExportActivity(id: exportID)
                        PageExporter.presentError(error, in: window)
                    }
                }
                session?.startExportActivity(
                    id: exportID,
                    total: items.count,
                    formatLabel: format.displayName,
                    task: task
                )
            }

        case .pdf:
            let specs: [PageExporter.PageSpec] = zip(indices, pages).map { index, page in
                let cropBox = SpreadAlignment.unalignedCropBox(for: page, at: index, in: context.document)
                return PageExporter.PageSpec(index: index, cropBox: cropBox, rotation: page.rotation)
            }
            let docURL = context.documentURL
            let password = context.password
            let canReadURL = docURL.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
            let fallbackSnapshots: [PageImageClipboard.PageSnapshot]? = canReadURL
                ? nil
                : (try? pages.map { try PageImageClipboard.snapshot(of: $0) })

            let task = Task(priority: .userInitiated) { [weak window, weak session] in
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        if let docURL, canReadURL {
                            return try PageExporter.pdfData(from: docURL, password: password, specs: specs)
                        }
                        if let fallbackSnapshots {
                            return try PageExporter.pdfData(from: fallbackSnapshots)
                        }
                        throw PageExporter.ExportError.unavailable
                    }.value
                    try Task.checkCancellation()
                    try data.write(to: destinationURL, options: .atomic)
                    PageExporter.applyFinderTags(tagNames, to: destinationURL)
                    session?.completeExportActivity(
                        id: exportID,
                        pageCount: specs.count,
                        formatLabel: format.displayName,
                        outputURL: destinationURL,
                        isFolder: false
                    )
                } catch is CancellationError {
                    session?.failOrCancelExportActivity(id: exportID)
                } catch {
                    session?.failOrCancelExportActivity(id: exportID)
                    PageExporter.presentError(error, in: window)
                }
            }
            session?.startExportActivity(
                id: exportID,
                total: specs.count,
                formatLabel: format.displayName,
                task: task
            )
        }
    }
}

@MainActor
private final class PageExportAccessoryView: NSView {
    private weak var panel: NSSavePanel?
    private let rowsStack = NSStackView()
    private let rangeRow: NSView
    private let resolutionRow: NSView
    private let qualityRow: NSView
    private let formWidth: CGFloat
    private let fieldWidth: CGFloat
    private let compactOffset: CGFloat
    private let verticalInset: CGFloat

    private var stackCenter: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var hasMountedInWindow = false
    private var lastExpandedState: Bool?

    init(
        panel: NSSavePanel,
        rows: [NSView],
        rangeRow: NSView,
        resolutionRow: NSView,
        qualityRow: NSView,
        formWidth: CGFloat,
        fieldWidth: CGFloat,
        compactOffset: CGFloat,
        verticalInset: CGFloat
    ) {
        self.panel = panel
        self.rangeRow = rangeRow
        self.resolutionRow = resolutionRow
        self.qualityRow = qualityRow
        self.formWidth = formWidth
        self.fieldWidth = fieldWidth
        self.compactOffset = compactOffset
        self.verticalInset = verticalInset

        super.init(frame: CGRect(x: 0, y: 0, width: formWidth, height: 80))

        rowsStack.orientation = .vertical
        rowsStack.alignment = .trailing
        rowsStack.spacing = 8
        rowsStack.detachesHiddenViews = true
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(lessThanOrEqualToConstant: formWidth - 24).isActive = true
        }
        addSubview(rowsStack)

        // Position `rowsStack`'s right edge so its 230pt control column shares the exact horizontal
        // center (`centerX + compactOffset`) of the built-in Save Panel controls.
        let halfControlWidth = fieldWidth / 2
        let trailingCenter = rowsStack.trailingAnchor.constraint(
            equalTo: centerXAnchor,
            constant: compactOffset + halfControlWidth
        )
        stackCenter = trailingCenter

        let widthMin = widthAnchor.constraint(greaterThanOrEqualToConstant: formWidth)
        widthMin.priority = .defaultHigh
        let height = heightAnchor.constraint(equalToConstant: 80)
        height.priority = NSLayoutConstraint.Priority(999)
        heightConstraint = height

        NSLayoutConstraint.activate([
            widthMin,
            height,
            trailingCenter,
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setRowVisibility(
        rangeVisible: Bool,
        resolutionVisible: Bool,
        qualityVisible: Bool,
        animated: Bool
    ) {
        let shouldAnimate = animated && hasMountedInWindow && !AppAnimation.reduceMotion
        let updates: () -> Void = {
            self.applyVisibility(rangeVisible: rangeVisible, resolutionVisible: resolutionVisible, qualityVisible: qualityVisible)
        }
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = AppAnimation.sheetMorphDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)
                ctx.allowsImplicitAnimation = true
                updates()
                self.window?.layoutIfNeeded()
            }
        } else {
            updates()
            self.window?.layoutIfNeeded()
        }
    }

    private func applyVisibility(rangeVisible: Bool, resolutionVisible: Bool, qualityVisible: Bool) {
        let pairs: [(NSView, Bool)] = [
            (rangeRow, rangeVisible),
            (resolutionRow, resolutionVisible),
            (qualityRow, qualityVisible)
        ]
        for (row, visible) in pairs where row.superview === rowsStack {
            row.isHidden = !visible
            row.alphaValue = visible ? 1 : 0
        }
        rowsStack.layoutSubtreeIfNeeded()
        let contentHeight = ceil(rowsStack.fittingSize.height)
        let targetHeight = max(44, contentHeight + 2 * verticalInset)
        heightConstraint?.constant = targetHeight
        if frame.size.height != targetHeight {
            setFrameSize(NSSize(width: max(formWidth, frame.size.width), height: targetHeight))
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let h = heightConstraint?.constant ?? frame.height
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let expanded = panel?.isExpanded == true
        lastExpandedState = expanded
        updateColumnOffset(expanded: expanded, animated: false)
        hasMountedInWindow = window != nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsUpdateConstraints = true
    }

    override func updateConstraints() {
        let expanded = panel?.isExpanded == true
        if expanded != lastExpandedState {
            let shouldAnimate = hasMountedInWindow && lastExpandedState != nil && !AppAnimation.reduceMotion
            lastExpandedState = expanded
            updateColumnOffset(expanded: expanded, animated: shouldAnimate)
        }
        super.updateConstraints()
    }

    private func updateColumnOffset(expanded: Bool, animated: Bool) {
        let halfControlWidth = fieldWidth / 2
        let targetConstant = (expanded ? 0 : compactOffset) + halfControlWidth
        guard let stackCenter else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = AppAnimation.sheetMorphDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)
                stackCenter.animator().constant = targetConstant
            }
        } else {
            stackCenter.constant = targetConstant
        }
    }
}
