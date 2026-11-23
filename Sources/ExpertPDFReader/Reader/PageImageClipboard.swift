import AppKit
import PDFKit

/// Exports document pixels, independent of the reader's zoom, overlays and reading theme.
enum PageImageClipboard {
    enum CopyError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            L10n.tr("无法将此页复制为图片。", "This page could not be copied as an image.")
        }
    }

    struct ImageData: Sendable {
        let png: Data
        let tiff: Data
    }

    struct PageSnapshot: Sendable {
        let data: Data
        let cropBox: CGRect
        let rotation: Int
    }

    private actor Renderer {
        static let shared = Renderer()

        func render(_ data: Data, cropBox: CGRect, rotation: Int) throws -> ImageData {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let document = PDFDocument(data: data), let page = document.page(at: 0),
                      cropBox.width.isFinite, cropBox.height.isFinite,
                      cropBox.width > 0, cropBox.height > 0 else { throw CopyError.unavailable }
                defer { withExtendedLifetime(document) {} }
                page.rotation = rotation
                page.setBounds(cropBox, for: .cropBox)
                let rotated = page.rotation % 180 != 0
                let size = rotated ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
                // 216 dpi for normal pages; cap oversized sheets to keep clipboard memory bounded.
                let scale = min(3, 3200 / max(size.width, size.height))
                let width = max(1, Int(ceil(size.width * scale)))
                let height = max(1, Int(ceil(size.height * scale)))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CopyError.unavailable }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .cropBox, to: context)
                try Task.checkCancellation()
                guard let image = context.makeImage() else { throw CopyError.unavailable }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]),
                      let tiff = bitmap.tiffRepresentation else { throw CopyError.unavailable }
                return ImageData(png: png, tiff: tiff)
            }
        }
    }

    @MainActor private static var pendingCopy: Task<Void, Never>?

    @MainActor static func canCopy(_ page: PDFPage?) -> Bool {
        guard let page else { return false }
        return page.document.map { !$0.isLocked && $0.allowsCopying } ?? true
    }

    @MainActor static func snapshot(of page: PDFPage) throws -> PageSnapshot {
        guard canCopy(page), let data = page.dataRepresentation else { throw CopyError.unavailable }
        let cropBox = page.document.map {
            SpreadAlignment.unalignedCropBox(for: page, at: $0.index(for: page), in: $0)
        } ?? page.bounds(for: .cropBox)
        return PageSnapshot(data: data, cropBox: cropBox, rotation: page.rotation)
    }

    static func renderImageData(for snapshot: PageSnapshot) async throws -> ImageData {
        try await Renderer.shared.render(snapshot.data, cropBox: snapshot.cropBox, rotation: snapshot.rotation)
    }

    /// Snapshot only the requested page on the main thread; PDFKit renders a private copy off-thread.
    /// A later copy, even in another application, takes precedence over this asynchronous operation.
    @MainActor @discardableResult
    static func copy(_ page: PDFPage, to pasteboard: NSPasteboard = .general) async throws -> Bool {
        let snapshot = try snapshot(of: page)
        let changeCount = pasteboard.changeCount
        let image = try await renderImageData(for: snapshot)
        try Task.checkCancellation()
        guard pasteboard.changeCount == changeCount else { return false }
        let item = NSPasteboardItem()
        item.setData(image.png, forType: .png)
        item.setData(image.tiff, forType: .tiff)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    @MainActor static func beginCopy(
        _ page: PDFPage,
        in window: NSWindow?,
        title: String = L10n.tr("复制当前页为图片", "Copy Current Page as Image")
    ) {
        pendingCopy?.cancel()
        pendingCopy = Task(priority: .userInitiated) { [weak window] in
            do {
                if try await copy(page), let window {
                    NSAccessibility.post(element: window, notification: .announcementRequested,
                        userInfo: [.announcement: L10n.tr("已复制", "Copied"),
                                   .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            } catch {
                guard !Task.isCancelled, let window else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
