import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Exports an individual PDF page as a standalone single-page PDF or PNG image.
enum PageExporter {
    enum Format {
        case pdf
        case png

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

    enum ExportError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            L10n.tr("无法导出此页。", "This page could not be exported.")
        }
    }

    static func suggestedFilename(documentTitle: String, pageLabel: String, format: Format) -> String {
        let sanitize: (String) -> String = { raw in
            raw.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleanedTitle = sanitize(documentTitle)
        let safeTitle = cleanedTitle.isEmpty ? "Document" : cleanedTitle
        let cleanedLabel = sanitize(pageLabel)
        let safeLabel = cleanedLabel.isEmpty ? "1" : cleanedLabel
        return "\(safeTitle) - \(L10n.pageTitle(safeLabel)).\(format.fileExtension)"
    }

    nonisolated static func pdfData(from snapshot: PageImageClipboard.PageSnapshot) throws -> Data {
        guard let document = PDFDocument(data: snapshot.data), let page = document.page(at: 0),
              snapshot.cropBox.width.isFinite, snapshot.cropBox.height.isFinite,
              snapshot.cropBox.width > 0, snapshot.cropBox.height > 0 else {
            throw ExportError.unavailable
        }
        page.rotation = snapshot.rotation
        page.setBounds(snapshot.cropBox, for: .cropBox)
        guard let output = document.dataRepresentation() else {
            throw ExportError.unavailable
        }
        return output
    }

    @MainActor static func pdfData(for page: PDFPage) throws -> Data {
        let snapshot: PageImageClipboard.PageSnapshot
        do {
            snapshot = try PageImageClipboard.snapshot(of: page)
        } catch {
            throw ExportError.unavailable
        }
        return try pdfData(from: snapshot)
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

    @MainActor static func beginExport(
        _ page: PDFPage,
        format: Format,
        suggestedName: String,
        in window: NSWindow?
    ) {
        guard let snapshot = try? PageImageClipboard.snapshot(of: page) else {
            presentError(ExportError.unavailable, in: window)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak window] response in
            guard response == .OK, let url = panel.url else { return }
            Task(priority: .userInitiated) {
                do {
                    let data: Data
                    switch format {
                    case .pdf:
                        data = try await Task.detached(priority: .userInitiated) {
                            try pdfData(from: snapshot)
                        }.value
                    case .png:
                        data = try await PageImageClipboard.renderImageData(for: snapshot).png
                    }
                    try data.write(to: url, options: .atomic)
                } catch {
                    presentError(error, in: window)
                }
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
        }
    }

    @MainActor private static func presentError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("导出此页", "Export Page")
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
