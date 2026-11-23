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

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .png: return "png"
            }
        }
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

    static func suggestedFilename(documentTitle: String, format: Format) -> String {
        let cleanedTitle = sanitizeFilenameComponent(documentTitle)
        let safeTitle = cleanedTitle.isEmpty ? "Document" : cleanedTitle
        return "\(safeTitle) - \(L10n.tr("导出", "Export")).\(format.fileExtension)"
    }

    static func filename(_ name: String, for format: Format) -> String {
        let path = name as NSString
        switch path.pathExtension.lowercased() {
        case "pdf", "png":
            return "\(path.deletingPathExtension).\(format.fileExtension)"
        default:
            return "\(name).\(format.fileExtension)"
        }
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
        initialPages: [Int]? = nil,
        in window: NSWindow?
    ) {
        let controller = PageExportPanelController(
            context: context,
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
    private enum PageSelectionMode: Int {
        case all
        case range
    }

    private let context: PageExporter.ExportDocumentContext
    private weak var hostWindow: NSWindow?
    private let panel = NSSavePanel()

    private let pagesModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rangeField = NSTextField(string: "")
    private let pngPageField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var selectedFormat: PageExporter.Format = .pdf
    private var selectedMode: PageSelectionMode
    private var initializedPNGPage = false

    init(
        context: PageExporter.ExportDocumentContext,
        initialPages: [Int]?,
        window: NSWindow?
    ) {
        self.context = context
        self.hostWindow = window
        let pages = (initialPages ?? []).filter { (0..<context.document.pageCount).contains($0) }
        self.selectedMode = pages.isEmpty ? .all : .range
        super.init()

        rangeField.stringValue = pageRangeText(for: pages.isEmpty ? [context.currentPageIndex] : pages)
        configurePanel()
        refreshPageControls()
    }

    private func configurePanel() {
        panel.nameFieldLabel = L10n.tr("导出为：", "Export As:")
        panel.prompt = L10n.tr("导出", "Export")
        panel.allowedContentTypes = [.pdf, .png]
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        panel.delegate = self

        let defaultFilename = PageExporter.suggestedFilename(documentTitle: context.documentTitle, format: .pdf)
        let legacyFormat: NSPopUpButton?
        if #available(macOS 15.0, *) {
            panel.showsContentTypes = true
            panel.nameFieldStringValue = defaultFilename
            legacyFormat = nil
        } else {
            panel.isExtensionHidden = true
            panel.nameFieldStringValue = (defaultFilename as NSString).deletingPathExtension
            let format = NSPopUpButton(frame: .zero, pullsDown: false)
            format.addItems(withTitles: ["PDF", "PNG"])
            format.setAccessibilityLabel(L10n.tr("格式：", "Format:"))
            format.target = self
            format.action = #selector(legacyFormatChanged(_:))
            legacyFormat = format
        }

        let pagesTitle = L10n.tr("页面：", "Pages:")
        pagesModePopUp.addItems(withTitles: [
            L10n.tr("全部页面", "All Pages"),
            L10n.tr("指定页码", "Page Range")
        ])
        pagesModePopUp.selectItem(at: selectedMode.rawValue)
        pagesModePopUp.setAccessibilityLabel(pagesTitle)
        pagesModePopUp.target = self
        pagesModePopUp.action = #selector(pagesModeChanged)

        rangeField.placeholderString = "1–5, 8, 12–15"
        rangeField.setAccessibilityLabel(L10n.tr("指定页码", "Page Range"))
        pngPageField.placeholderString = pageRangeText(for: [context.currentPageIndex])
        pngPageField.setAccessibilityLabel(pagesTitle)
        for field in [rangeField, pngPageField] {
            field.delegate = self
        }

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        updateStatus()
        panel.accessoryView = makeAccessoryView(pagesTitle: pagesTitle, legacyFormat: legacyFormat)
    }

    private func makeAccessoryView(pagesTitle: String, legacyFormat: NSPopUpButton?) -> NSView {
        // Match the built-in compact form's field width and outer margin.
        let formWidth: CGFloat = legacyFormat == nil ? 390 : 380
        let fieldWidth: CGFloat = 230
        let trailingInset: CGFloat = 40.5
        let labelGap: CGFloat = 8
        let verticalInset: CGFloat = 14

        let pageControl = NSView()
        pageControl.heightAnchor.constraint(equalToConstant: max(
            pagesModePopUp.fittingSize.height, pngPageField.fittingSize.height
        )).isActive = true
        for control in [pagesModePopUp, pngPageField] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            pageControl.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: pageControl.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: pageControl.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: pageControl.centerYAnchor)
            ])
        }

        var controls = [pageControl, rangeField, statusLabel]
        if let legacyFormat { controls.insert(legacyFormat, at: 0) }
        let column = NSStackView(views: controls)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        for control in controls {
            control.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        }

        // Size the accessory once using the range layout, then keep the top row fixed.
        let accessory = PageExportAccessoryView(
            panel: panel,
            column: column,
            frame: CGRect(x: 0, y: 0, width: formWidth, height: ceil(column.fittingSize.height) + 2 * verticalInset),
            compactOffset: (formWidth - fieldWidth) / 2 - trailingInset,
            topInset: verticalInset
        )
        addFormLabel(pagesTitle, for: pageControl, in: accessory, gap: labelGap)
        if let legacyFormat {
            addFormLabel(L10n.tr("格式：", "Format:"), for: legacyFormat, in: accessory, gap: labelGap)
        }
        return accessory
    }

    private func addFormLabel(_ title: String, for control: NSView, in accessory: NSView, gap: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: accessory.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -gap),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor)
        ])
    }

    func present() {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destinationURL = self.panel.url else { return }
            self.startExport(to: destinationURL)
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
        default: return nil
        }
    }

    @available(macOS 15.0, *)
    func panel(_ sender: Any, didSelect type: UTType?) {
        selectFormat(type == .png ? .png : .pdf)
    }

    @objc private func legacyFormatChanged(_ sender: NSPopUpButton) {
        selectFormat(PageExporter.Format(rawValue: sender.indexOfSelectedItem) ?? .pdf)
    }

    private func selectFormat(_ format: PageExporter.Format) {
        guard selectedFormat != format else { return }
        if format == .png, !initializedPNGPage {
            let rangePage = selectedMode == .range ? parsedRange()?.first : nil
            pngPageField.stringValue = pageRangeText(for: [rangePage ?? context.currentPageIndex])
            initializedPNGPage = true
        }
        selectedFormat = format
        refreshPageControls()
    }

    @objc private func pagesModeChanged() {
        selectedMode = PageSelectionMode(rawValue: pagesModePopUp.indexOfSelectedItem) ?? .all
        refreshPageControls()
        if selectedMode == .range {
            panel.makeFirstResponder(rangeField)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        updateStatus()
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed: Bool) -> String? {
        guard confirmed, !filename.isEmpty else { return filename }
        return PageExporter.filename(filename, for: selectedFormat)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard let firstPage = resolvedPageIndices()?.first else {
            panel.makeFirstResponder(selectedFormat == .png ? pngPageField : rangeField)
            throw invalidSelection
        }
        guard url.pathExtension.lowercased() == selectedFormat.fileExtension,
              PageImageClipboard.canCopy(context.document.page(at: firstPage)) else {
            throw PageExporter.ExportError.unavailable
        }
    }

    private var invalidSelection: PageExporter.ExportError {
        selectedFormat == .png ? .invalidPageNumber : .invalidPageRange
    }

    private func pageRangeText(for pages: [Int]) -> String {
        PageRangeParser.format(
            pages,
            pageCount: context.document.pageCount,
            labelFor: context.labelForPage,
            usesBookNumbers: context.usesBookNumbers,
            resolvePage: context.resolvePage
        )
    }

    private func parsedRange() -> [Int]? {
        PageRangeParser.parse(rangeField.stringValue, pageCount: context.document.pageCount, resolvePage: context.resolvePage)
    }

    private func resolvedPageIndices() -> [Int]? {
        let pageCount = context.document.pageCount
        guard pageCount > 0 else { return nil }
        if selectedFormat == .png {
            guard let page = context.resolvePage(pngPageField.stringValue), (0..<pageCount).contains(page) else { return nil }
            return [page]
        }
        switch selectedMode {
        case .all: return Array(0..<pageCount)
        case .range: return parsedRange()
        }
    }

    private func refreshPageControls() {
        let isPDF = selectedFormat == .pdf
        pagesModePopUp.isHidden = !isPDF
        rangeField.isHidden = !isPDF || selectedMode != .range
        pngPageField.isHidden = isPDF
        updateStatus()
    }

    private func updateStatus() {
        if let count = resolvedPageIndices()?.count {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = L10n.exportPageCountSummary(count)
        } else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = invalidSelection.localizedDescription
        }
    }

    private func startExport(to destinationURL: URL) {
        guard let indices = resolvedPageIndices(), !indices.isEmpty else {
            PageExporter.presentError(
                invalidSelection, in: hostWindow
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

@MainActor
private final class PageExportAccessoryView: NSView {
    private weak var panel: NSSavePanel?
    private let compactOffset: CGFloat
    private var columnCenter: NSLayoutConstraint?

    init(panel: NSSavePanel, column: NSView, frame: NSRect, compactOffset: CGFloat, topInset: CGFloat) {
        self.panel = panel
        self.compactOffset = compactOffset
        super.init(frame: frame)
        addSubview(column)
        let center = column.centerXAnchor.constraint(equalTo: centerXAnchor, constant: compactOffset)
        columnCenter = center
        NSLayoutConstraint.activate([
            center,
            column.topAnchor.constraint(equalTo: topAnchor, constant: topInset)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsUpdateConstraints = true
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsUpdateConstraints = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsUpdateConstraints = true
    }

    override func updateConstraints() {
        // The expanded save sheet centers its fields in the file browser column.
        columnCenter?.constant = panel?.isExpanded == true ? 0 : compactOffset
        super.updateConstraints()
    }
}
