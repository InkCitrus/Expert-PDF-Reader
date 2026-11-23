import AppKit
import PDFKit
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

/// Exports single or multi-page PDF documents and PNG page images using a unified save panel.
enum PageExporter {
    enum Format: Int {
        case pdf = 0
        case png = 1

        var contentType: UTType {
            switch self {
            case .pdf: return .pdf
            case .png: return .png
            }
        }

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .png: return "png"
            }
        }
    }

    enum PageSelectionMode: Int {
        case all = 0
        case current = 1
        case range = 2
    }

    enum ExportError: LocalizedError {
        case unavailable
        case invalidPageRange
        case invalidPageNumber

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return L10n.tr("无法导出此页。", "This page could not be exported.")
            case .invalidPageRange:
                return L10n.tr("请输入有效的页码范围", "Enter a valid page range")
            case .invalidPageNumber:
                return L10n.tr("请输入有效页码", "Enter a valid page number")
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

    private static func sanitizeFilenameComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func suggestedFilename(documentTitle: String, pageLabel: String, format: Format) -> String {
        let cleanedTitle = sanitizeFilenameComponent(documentTitle)
        let safeTitle = cleanedTitle.isEmpty ? "Document" : cleanedTitle
        let cleanedLabel = sanitizeFilenameComponent(pageLabel)
        let safeLabel = cleanedLabel.isEmpty ? "1" : cleanedLabel
        return "\(safeTitle) - \(L10n.pageTitle(safeLabel)).\(format.fileExtension)"
    }

    static func suggestedFilename(
        documentTitle: String,
        rangeText: String?,
        pageCount: Int,
        isAllPages: Bool,
        format: Format
    ) -> String {
        let cleanedTitle = sanitizeFilenameComponent(documentTitle)
        let safeTitle = cleanedTitle.isEmpty ? "Document" : cleanedTitle
        if isAllPages {
            return "\(safeTitle).\(format.fileExtension)"
        }
        let cleanedRange = rangeText.map(sanitizeFilenameComponent) ?? ""
        if pageCount == 1 {
            let safeLabel = cleanedRange.isEmpty ? "1" : cleanedRange
            return "\(safeTitle) - \(L10n.pageTitle(safeLabel)).\(format.fileExtension)"
        }
        if !cleanedRange.isEmpty && cleanedRange.count <= 24 {
            return "\(safeTitle) - \(cleanedRange).\(format.fileExtension)"
        }
        return "\(safeTitle) - \(L10n.pageCountText(pageCount)).\(format.fileExtension)"
    }

    nonisolated static func pdfData(from snapshots: [PageImageClipboard.PageSnapshot]) throws -> Data {
        guard !snapshots.isEmpty else { throw ExportError.unavailable }
        let output = PDFDocument()
        for (outIndex, snapshot) in snapshots.enumerated() {
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
        return try await PageImageClipboard.renderImageData(for: snapshot).png
    }

    @MainActor static func beginExportPanel(
        context: ExportDocumentContext,
        initialMode: PageSelectionMode = .all,
        initialPages: [Int]? = nil,
        in window: NSWindow?
    ) {
        let controller = PageExportPanelController(
            context: context,
            initialMode: initialMode,
            initialPages: initialPages,
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
private final class PageExportPanelController: NSObject, NSOpenSavePanelDelegate, NSTextFieldDelegate {
    private static var activeController: PageExportPanelController?

    private let context: PageExporter.ExportDocumentContext
    private weak var hostWindow: NSWindow?
    private let panel = NSSavePanel()

    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pagesModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rangeField = NSTextField(string: "")
    private let pngPageField = NSTextField(string: "")
    private let pagesControlContainer = NSView()
    private let rangeStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var compactBottomConstraint: NSLayoutConstraint?
    private var expandedBottomConstraint: NSLayoutConstraint?

    private var lastAutoFilename = ""
    private var selectedFormat: PageExporter.Format = .pdf
    private var selectedMode: PageExporter.PageSelectionMode

    init(
        context: PageExporter.ExportDocumentContext,
        initialMode: PageExporter.PageSelectionMode,
        initialPages: [Int]?,
        window: NSWindow?
    ) {
        self.context = context
        self.hostWindow = window
        let pageCount = context.document.pageCount
        let sanitizedPages = (initialPages ?? []).filter { (0..<pageCount).contains($0) }
        if !sanitizedPages.isEmpty {
            self.selectedMode = .range
        } else {
            self.selectedMode = initialMode
        }
        super.init()

        configureControls(initialPages: sanitizedPages)
        configurePanel()
    }

    private func configureControls(initialPages: [Int]) {
        formatPopUp.addItems(withTitles: ["PDF", "PNG"])
        formatPopUp.selectItem(at: PageExporter.Format.pdf.rawValue)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)

        let pageCount = context.document.pageCount
        pagesModePopUp.addItems(withTitles: [
            L10n.parenthetical(L10n.tr("全部页面", "All Pages"), L10n.pageCountText(pageCount)),
            L10n.parenthetical(L10n.tr("当前页", "Current Page"), context.labelForPage(context.currentPageIndex)),
            L10n.tr("指定页码", "Page Range")
        ])
        pagesModePopUp.selectItem(at: selectedMode.rawValue)
        pagesModePopUp.target = self
        pagesModePopUp.action = #selector(pagesModeChanged)

        if !initialPages.isEmpty {
            rangeField.stringValue = PageRangeParser.format(
                initialPages,
                pageCount: pageCount,
                labelFor: context.labelForPage,
                usesBookNumbers: context.usesBookNumbers,
                resolvePage: context.resolvePage
            )
            pngPageField.stringValue = context.labelForPage(initialPages[0])
        } else {
            let currentLabel = context.labelForPage(context.currentPageIndex)
            rangeField.stringValue = currentLabel
            pngPageField.stringValue = currentLabel
        }

        rangeField.placeholderString = "1-5, 8, 12-15"
        rangeField.delegate = self
        rangeField.font = NSFont.systemFont(ofSize: 13)

        pngPageField.placeholderString = context.labelForPage(context.currentPageIndex)
        pngPageField.delegate = self
        pngPageField.font = NSFont.systemFont(ofSize: 13)

        pagesModePopUp.translatesAutoresizingMaskIntoConstraints = false
        pngPageField.translatesAutoresizingMaskIntoConstraints = false
        pagesControlContainer.translatesAutoresizingMaskIntoConstraints = false
        pagesControlContainer.addSubview(pagesModePopUp)
        pagesControlContainer.addSubview(pngPageField)
        NSLayoutConstraint.activate([
            pagesModePopUp.leadingAnchor.constraint(equalTo: pagesControlContainer.leadingAnchor),
            pagesModePopUp.trailingAnchor.constraint(equalTo: pagesControlContainer.trailingAnchor),
            pagesModePopUp.topAnchor.constraint(equalTo: pagesControlContainer.topAnchor),
            pagesModePopUp.bottomAnchor.constraint(equalTo: pagesControlContainer.bottomAnchor),

            pngPageField.leadingAnchor.constraint(equalTo: pagesControlContainer.leadingAnchor),
            pngPageField.trailingAnchor.constraint(equalTo: pagesControlContainer.trailingAnchor),
            pngPageField.topAnchor.constraint(equalTo: pagesControlContainer.topAnchor),
            pngPageField.bottomAnchor.constraint(equalTo: pagesControlContainer.bottomAnchor)
        ])

        formatPopUp.translatesAutoresizingMaskIntoConstraints = false
        rangeField.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        for control in [formatPopUp, pagesModePopUp, pngPageField, rangeField] as [NSView] {
            control.setContentHuggingPriority(.init(200), for: .horizontal)
        }

        rangeStack.addArrangedSubview(rangeField)
        rangeStack.addArrangedSubview(statusLabel)
        rangeStack.translatesAutoresizingMaskIntoConstraints = false
        rangeStack.orientation = .vertical
        rangeStack.alignment = .leading
        rangeStack.spacing = 4

        let formatLabel = NSTextField(labelWithString: L10n.tr("格式：", "Format:"))
        formatLabel.font = NSFont.systemFont(ofSize: 13)
        formatLabel.textColor = .secondaryLabelColor
        formatLabel.alignment = .right
        formatLabel.translatesAutoresizingMaskIntoConstraints = false

        let pagesLabel = NSTextField(labelWithString: L10n.tr("页面：", "Pages:"))
        pagesLabel.font = NSFont.systemFont(ofSize: 13)
        pagesLabel.textColor = .secondaryLabelColor
        pagesLabel.alignment = .right
        pagesLabel.translatesAutoresizingMaskIntoConstraints = false

        // Match macOS Save Panel's 380pt top form directly: labels right-aligned at x=101.5,
        // 9pt column gap, and 230pt controls spanning x=110.5..340.5.
        let labelTrailing: CGFloat = 101.5
        let controlLeading: CGFloat = 110.5
        let controlTrailing: CGFloat = 340.5

        let formContainer = NSView()
        formContainer.translatesAutoresizingMaskIntoConstraints = false
        for subview in [formatLabel, formatPopUp, pagesLabel, pagesControlContainer, rangeStack] as [NSView] {
            formContainer.addSubview(subview)
        }

        let compactBottom = pagesControlContainer.bottomAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: -14)
        let expandedBottom = rangeStack.bottomAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: -14)
        compactBottomConstraint = compactBottom
        expandedBottomConstraint = expandedBottom

        let accessoryContainer = NSView()
        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(formContainer)
        let minWidth = accessoryContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)
        minWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            minWidth,
            formContainer.widthAnchor.constraint(equalToConstant: 380),
            formContainer.centerXAnchor.constraint(equalTo: accessoryContainer.centerXAnchor),
            formContainer.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            formContainer.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),

            formatLabel.leadingAnchor.constraint(greaterThanOrEqualTo: formContainer.leadingAnchor, constant: 12),
            formatLabel.trailingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: labelTrailing),
            formatLabel.centerYAnchor.constraint(equalTo: formatPopUp.centerYAnchor),

            formatPopUp.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: controlLeading),
            formatPopUp.trailingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: controlTrailing),
            formatPopUp.topAnchor.constraint(equalTo: formContainer.topAnchor, constant: 14),

            pagesLabel.leadingAnchor.constraint(greaterThanOrEqualTo: formContainer.leadingAnchor, constant: 12),
            pagesLabel.trailingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: labelTrailing),
            pagesLabel.centerYAnchor.constraint(equalTo: pagesControlContainer.centerYAnchor),

            pagesControlContainer.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: controlLeading),
            pagesControlContainer.trailingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: controlTrailing),
            pagesControlContainer.topAnchor.constraint(equalTo: formatPopUp.bottomAnchor, constant: 10),

            rangeStack.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: controlLeading),
            rangeStack.trailingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: controlTrailing),
            rangeStack.topAnchor.constraint(equalTo: pagesControlContainer.bottomAnchor, constant: 10),
            rangeField.widthAnchor.constraint(equalTo: rangeStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: rangeStack.widthAnchor)
        ])

        panel.accessoryView = accessoryContainer
    }

    private func configurePanel() {
        panel.nameFieldLabel = L10n.tr("导出为：", "Export As:")
        panel.title = L10n.tr("导出", "Export")
        panel.allowedContentTypes = [selectedFormat.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.delegate = self

        syncControlVisibility()
        syncSuggestedFilename(force: true)
        updateStatusLabel()
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
            self.startExport(to: destinationURL)
        }
        if let hostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @objc private func formatChanged() {
        let newFormat = PageExporter.Format(rawValue: formatPopUp.indexOfSelectedItem) ?? .pdf
        guard newFormat != selectedFormat else { return }
        if newFormat == .png {
            if let resolved = resolvedPDFPageIndices(), let first = resolved.first {
                pngPageField.stringValue = context.labelForPage(first)
            } else {
                pngPageField.stringValue = context.labelForPage(context.currentPageIndex)
            }
        }
        selectedFormat = newFormat
        panel.allowedContentTypes = [newFormat.contentType]
        syncControlVisibility()
        updateFilenameExtensionOrSuggestion()
        updateStatusLabel()
    }

    @objc private func pagesModeChanged() {
        selectedMode = PageExporter.PageSelectionMode(rawValue: pagesModePopUp.indexOfSelectedItem) ?? .all
        syncControlVisibility()
        syncSuggestedFilename(force: false)
        updateStatusLabel()
        if selectedMode == .range {
            panel.makeFirstResponder(rangeField)
        }
    }

    nonisolated func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated {
            syncSuggestedFilename(force: false)
            updateStatusLabel()
        }
    }

    nonisolated func panel(_ sender: Any, validate url: URL) throws {
        try MainActor.assumeIsolated {
            guard let indices = resolvedPageIndices(), !indices.isEmpty else {
                updateStatusLabel(forceError: true)
                let targetField = selectedFormat == .png ? pngPageField : rangeField
                panel.makeFirstResponder(targetField)
                throw selectedFormat == .png ? PageExporter.ExportError.invalidPageNumber : PageExporter.ExportError.invalidPageRange
            }
            if selectedFormat == .png, let page = context.document.page(at: indices[0]), !PageImageClipboard.canCopy(page) {
                throw PageExporter.ExportError.unavailable
            }
            if let firstPage = context.document.page(at: indices[0]), !PageImageClipboard.canCopy(firstPage) {
                throw PageExporter.ExportError.unavailable
            }
        }
    }

    private func applyRow3Visibility(showRow3: Bool, showRangeField: Bool) {
        rangeField.isHidden = !showRangeField
        statusLabel.isHidden = !showRow3
        rangeStack.isHidden = !showRow3
        if showRow3 {
            compactBottomConstraint?.isActive = false
            expandedBottomConstraint?.isActive = true
        } else {
            expandedBottomConstraint?.isActive = false
            compactBottomConstraint?.isActive = true
        }
        panel.accessoryView?.layoutSubtreeIfNeeded()
    }

    private func syncControlVisibility() {
        let isPDF = selectedFormat == .pdf
        pagesModePopUp.isHidden = !isPDF
        pngPageField.isHidden = isPDF
        if isPDF {
            let isRange = selectedMode == .range
            applyRow3Visibility(showRow3: isRange, showRangeField: isRange)
        } else {
            let isInvalidPNG = resolvedPNGPageIndex() == nil && !pngPageField.stringValue.isEmpty
            applyRow3Visibility(showRow3: isInvalidPNG, showRangeField: false)
        }
    }

    private func resolvedPDFPageIndices() -> [Int]? {
        let pageCount = context.document.pageCount
        guard pageCount > 0 else { return nil }
        switch selectedMode {
        case .all:
            return Array(0..<pageCount)
        case .current:
            let idx = max(0, min(pageCount - 1, context.currentPageIndex))
            return [idx]
        case .range:
            return PageRangeParser.parse(rangeField.stringValue, pageCount: pageCount, resolvePage: context.resolvePage)
        }
    }

    private func resolvedPNGPageIndex() -> Int? {
        let pageCount = context.document.pageCount
        guard pageCount > 0 else { return nil }
        let raw = (pngPageField.stringValue.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? pngPageField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let idx = context.resolvePage(raw), (0..<pageCount).contains(idx) else {
            return nil
        }
        return idx
    }

    private func resolvedPageIndices() -> [Int]? {
        switch selectedFormat {
        case .pdf: return resolvedPDFPageIndices()
        case .png: return resolvedPNGPageIndex().map { [$0] }
        }
    }

    private func defaultFilenameForCurrentSelection() -> String {
        switch selectedFormat {
        case .pdf:
            let indices = resolvedPDFPageIndices() ?? []
            let count = indices.count
            switch selectedMode {
            case .all:
                return PageExporter.suggestedFilename(
                    documentTitle: context.documentTitle,
                    rangeText: nil,
                    pageCount: context.document.pageCount,
                    isAllPages: true,
                    format: .pdf
                )
            case .current:
                return PageExporter.suggestedFilename(
                    documentTitle: context.documentTitle,
                    pageLabel: context.labelForPage(context.currentPageIndex),
                    format: .pdf
                )
            case .range:
                let rangeText = count == 1 ? context.labelForPage(indices[0]) : rangeField.stringValue
                return PageExporter.suggestedFilename(
                    documentTitle: context.documentTitle,
                    rangeText: rangeText,
                    pageCount: max(1, count),
                    isAllPages: false,
                    format: .pdf
                )
            }
        case .png:
            let pageIdx = resolvedPNGPageIndex() ?? context.currentPageIndex
            return PageExporter.suggestedFilename(
                documentTitle: context.documentTitle,
                pageLabel: context.labelForPage(pageIdx),
                format: .png
            )
        }
    }

    private func syncSuggestedFilename(force: Bool) {
        let suggestion = defaultFilenameForCurrentSelection()
        if force || panel.nameFieldStringValue == lastAutoFilename || panel.nameFieldStringValue.isEmpty {
            panel.nameFieldStringValue = suggestion
            lastAutoFilename = suggestion
        }
    }

    private func updateFilenameExtensionOrSuggestion() {
        let current = panel.nameFieldStringValue
        if current == lastAutoFilename || current.isEmpty {
            syncSuggestedFilename(force: true)
            return
        }
        let stem = (current as NSString).deletingPathExtension
        let safeStem = stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Document" : stem
        panel.nameFieldStringValue = "\(safeStem).\(selectedFormat.fileExtension)"
    }

    private func updateStatusLabel(forceError: Bool = false) {
        switch selectedFormat {
        case .pdf:
            guard selectedMode == .range else {
                statusLabel.stringValue = ""
                applyRow3Visibility(showRow3: false, showRangeField: false)
                return
            }
            if let indices = resolvedPDFPageIndices(), !indices.isEmpty {
                statusLabel.textColor = .secondaryLabelColor
                statusLabel.stringValue = L10n.exportPageCountSummary(indices.count)
            } else {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = L10n.tr("请输入有效的页码范围", "Enter a valid page range")
            }
            applyRow3Visibility(showRow3: true, showRangeField: true)
        case .png:
            if resolvedPNGPageIndex() != nil {
                statusLabel.stringValue = ""
                applyRow3Visibility(showRow3: false, showRangeField: false)
            } else if forceError || !pngPageField.stringValue.isEmpty {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = L10n.tr("请输入有效页码", "Enter a valid page number")
                applyRow3Visibility(showRow3: true, showRangeField: false)
            } else {
                statusLabel.stringValue = ""
                applyRow3Visibility(showRow3: false, showRangeField: false)
            }
        }
    }

    private func startExport(to destinationURL: URL) {
        guard let indices = resolvedPageIndices(), !indices.isEmpty else {
            PageExporter.presentError(
                selectedFormat == .png ? PageExporter.ExportError.invalidPageNumber : PageExporter.ExportError.invalidPageRange,
                in: hostWindow
            )
            return
        }

        let pages = indices.compactMap { context.document.page(at: $0) }
        guard pages.count == indices.count, pages.allSatisfy({ PageImageClipboard.canCopy($0) }) else {
            PageExporter.presentError(PageExporter.ExportError.unavailable, in: hostWindow)
            return
        }

        switch selectedFormat {
        case .png:
            guard let snapshot = try? PageImageClipboard.snapshot(of: pages[0]) else {
                PageExporter.presentError(PageExporter.ExportError.unavailable, in: hostWindow)
                return
            }
            let window = hostWindow
            Task(priority: .userInitiated) { [weak window] in
                do {
                    let data = try await PageImageClipboard.renderImageData(for: snapshot).png
                    try data.write(to: destinationURL, options: .atomic)
                } catch {
                    PageExporter.presentError(error, in: window)
                }
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
            let window = hostWindow
            Task(priority: .userInitiated) { [weak window] in
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
                    try data.write(to: destinationURL, options: .atomic)
                } catch {
                    PageExporter.presentError(error, in: window)
                }
            }
        }
    }
}
