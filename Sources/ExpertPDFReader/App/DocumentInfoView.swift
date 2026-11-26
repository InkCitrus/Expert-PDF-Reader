import AppKit
import PDFKit
import SwiftUI

/// Snapshot of PDF document metadata and file specifications extracted for the inspector sheet (`⌘I`).
public struct DocumentMetadataSnapshot: Equatable {
    public struct Field: Identifiable, Equatable {
        public let id: String
        public let label: String
        public let value: String

        public init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    public let displayTitle: String
    public let fileName: String
    public let filePath: String
    public let pageCount: Int
    public let pageSizeText: String
    public let fileSizeText: String
    public let pdfVersion: String
    public let isEncrypted: Bool
    public let isLocked: Bool
    public let title: String?
    public let author: String?
    public let subject: String?
    public let keywords: String?
    public let creator: String?
    public let producer: String?
    public let creationDate: Date?
    public let modificationDate: Date?

    public var hasMetadata: Bool {
        [title, author, subject, keywords, creator, producer].contains { $0 != nil }
    }

    public static func extract(from document: PDFDocument, url: URL, pageIndex: Int = 0) -> DocumentMetadataSnapshot {
        let attrs = document.documentAttributes ?? [:]

        func cleanedString(_ key: PDFDocumentAttribute) -> String? {
            if let str = attrs[key] as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let array = attrs[key] as? [String] {
                let joined = array
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                return joined.isEmpty ? nil : joined
            }
            return nil
        }

        let fileName = url.lastPathComponent
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = cleanedString(.titleAttribute)
        let author = cleanedString(.authorAttribute)
        let subject = cleanedString(.subjectAttribute)
        let keywords = cleanedString(.keywordsAttribute)
        let creator = cleanedString(.creatorAttribute)
        let producer = cleanedString(.producerAttribute)
        let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        let modificationDate = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date

        let pdfVersion = "\(document.majorVersion).\(document.minorVersion)"
        let clampedPage = max(0, min(pageIndex, max(0, document.pageCount - 1)))
        let pageSizeText: String
        if let page = document.page(at: clampedPage) {
            let bounds = page.bounds(for: .cropBox)
            let isQuarterTurned = (page.rotation / 90) % 2 != 0
            let size = isQuarterTurned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            pageSizeText = formattedPageSize(points: size)
        } else {
            pageSizeText = "—"
        }

        let fileSizeText: String
        if let fileAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = fileAttrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
            formatter.countStyle = .file
            fileSizeText = formatter.string(fromByteCount: bytes)
        } else {
            fileSizeText = "—"
        }

        return DocumentMetadataSnapshot(
            displayTitle: title ?? fallbackTitle,
            fileName: fileName,
            filePath: url.path,
            pageCount: document.pageCount,
            pageSizeText: pageSizeText,
            fileSizeText: fileSizeText,
            pdfVersion: pdfVersion,
            isEncrypted: document.isEncrypted,
            isLocked: document.isLocked,
            title: title,
            author: author,
            subject: subject,
            keywords: keywords,
            creator: creator,
            producer: producer,
            creationDate: creationDate,
            modificationDate: modificationDate
        )
    }

    static func formattedPageSize(points: CGSize) -> String {
        guard points.width > 0 && points.height > 0 else { return "—" }
        let ptToMm = 25.4 / 72.0
        let widthMm = Int((points.width * ptToMm).rounded())
        let heightMm = Int((points.height * ptToMm).rounded())
        let base = "\(widthMm) × \(heightMm) mm"
        if let standard = detectStandardPaper(points: points) {
            return "\(base) (\(standard))"
        }
        return base
    }

    private static func detectStandardPaper(points: CGSize) -> String? {
        let minSide = min(points.width, points.height)
        let maxSide = max(points.width, points.height)
        let presets: [(name: String, width: CGFloat, height: CGFloat)] = [
            ("A3", 841.89, 1190.55),
            ("A4", 595.28, 841.89),
            ("A5", 419.53, 595.28),
            ("B5", 498.90, 708.66),
            ("US Letter", 612.0, 792.0),
            ("US Legal", 612.0, 1008.0),
            ("Tabloid", 792.0, 1224.0)
        ]
        for preset in presets {
            if abs(minSide - preset.width) <= 3.5 && abs(maxSide - preset.height) <= 3.5 {
                return preset.name
            }
        }
        return nil
    }
}

/// Native macOS Inspector Sheet (`⌘I`) displaying PDF metadata, specs, and file path actions.
public struct DocumentInfoSheetView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tab: DocumentTabState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccentColor) private var accent
    @State private var copiedPath = false
    @State private var copiedResetTask: Task<Void, Never>?

    private var isDark: Bool { colorScheme == .dark }

    private var snapshot: DocumentMetadataSnapshot {
        DocumentMetadataSnapshot.extract(
            from: tab.pdfDocument,
            url: tab.documentID.url,
            pageIndex: tab.currentPageIndex
        )
    }

    private var metadataDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = store.appLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private var coverThumbnail: NSImage? {
        guard let page = tab.pdfDocument.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 96, height: 128), for: .cropBox)
    }

    public var body: some View {
        let info = snapshot
        VStack(spacing: 0) {
            header(info: info)

            Rectangle()
                .fill(AppPalette.panelSeparator(isDark))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if info.hasMetadata {
                        sectionCard(title: L10n.tr("元数据", "Metadata")) {
                            let rows = metadataRows(info: info)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                infoRow(label: row.label, value: row.value)
                                if index < rows.count - 1 {
                                    rowDivider
                                }
                            }
                        }
                    }

                    sectionCard(title: L10n.tr("文件与规格", "File & Specifications")) {
                        let rows = specRows(info: info)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            infoRow(label: row.label, value: row.value)
                            rowDivider
                        }
                        pathRow(path: info.filePath)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480)
        .frame(minHeight: 380, maxHeight: 560)
        .background(AppPalette.systemBackground(isDark))
        .onDisappear {
            copiedResetTask?.cancel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("文档信息", "Document Info")))
    }

    private func header(info: DocumentMetadataSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let image = coverThumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(AppPalette.labelTertiary(isDark))
                }
            }
            .frame(width: 46, height: 60)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.10), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(info.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .lineLimit(2)

                Text("\(L10n.pageCountText(info.pageCount)) · \(info.fileSizeText) · PDF \(info.pdfVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(AppPalette.labelSecondary(isDark))
                    .lineLimit(1)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([tab.documentID.url])
                } label: {
                    Label(L10n.tr("在 Finder 中显示", "Show in Finder"), systemImage: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppPalette.labelSecondary(isDark))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(AppPalette.segmentedTrack(isDark)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.tr("关闭", "Close"))
            .accessibilityLabel(Text(L10n.tr("关闭", "Close")))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AppPalette.panelBackground(isDark))
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(AppPalette.labelTertiary(isDark))
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppPalette.panelBackground(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppPalette.panelSeparator(isDark), lineWidth: 1)
            )
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(AppPalette.panelSeparator(isDark))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .frame(width: 110, alignment: .leading)

            Text(value)
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.labelPrimary(isDark))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func pathRow(path: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.tr("位置", "Where"))
                .font(.system(size: 12.5))
                .foregroundColor(AppPalette.labelSecondary(isDark))
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(path)
                    .font(.system(size: 12))
                    .foregroundColor(AppPalette.labelPrimary(isDark))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    copiedPath = true
                    copiedResetTask?.cancel()
                    copiedResetTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        copiedPath = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(copiedPath ? L10n.tr("已复制", "Copied") : L10n.tr("复制路径", "Copy Path"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(copiedPath ? .green : accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(AppPalette.toolbarControlFill(isDark))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func metadataRows(info: DocumentMetadataSnapshot) -> [DocumentMetadataSnapshot.Field] {
        var rows: [DocumentMetadataSnapshot.Field] = []
        if let title = info.title {
            rows.append(.init(id: "title", label: L10n.tr("标题", "Title"), value: title))
        }
        if let author = info.author {
            rows.append(.init(id: "author", label: L10n.tr("作者", "Author"), value: author))
        }
        if let subject = info.subject {
            rows.append(.init(id: "subject", label: L10n.tr("主题", "Subject"), value: subject))
        }
        if let keywords = info.keywords {
            rows.append(.init(id: "keywords", label: L10n.tr("关键词", "Keywords"), value: keywords))
        }
        if let creator = info.creator {
            rows.append(.init(id: "creator", label: L10n.tr("创建工具", "Creator"), value: creator))
        }
        if let producer = info.producer {
            rows.append(.init(id: "producer", label: L10n.tr("PDF 生成器", "PDF Producer"), value: producer))
        }
        return rows
    }

    private func specRows(info: DocumentMetadataSnapshot) -> [DocumentMetadataSnapshot.Field] {
        var rows: [DocumentMetadataSnapshot.Field] = [
            .init(id: "pages", label: L10n.tr("页数", "Pages"), value: "\(info.pageCount)"),
            .init(id: "pageSize", label: L10n.tr("页面尺寸", "Page Size"), value: info.pageSizeText),
            .init(id: "fileSize", label: L10n.tr("文件大小", "File Size"), value: info.fileSizeText),
            .init(id: "pdfVersion", label: L10n.tr("PDF 版本", "PDF Version"), value: info.pdfVersion),
            .init(
                id: "security",
                label: L10n.tr("安全性", "Security"),
                value: info.isEncrypted
                    ? L10n.tr("密码保护（已解锁）", "Password Protected (Unlocked)")
                    : L10n.tr("标准（无加密）", "Standard (Unencrypted)")
            )
        ]
        if let created = info.creationDate {
            rows.append(.init(id: "created", label: L10n.tr("创建时间", "Created"), value: metadataDateFormatter.string(from: created)))
        }
        if let modified = info.modificationDate {
            rows.append(.init(id: "modified", label: L10n.tr("修改时间", "Modified"), value: metadataDateFormatter.string(from: modified)))
        }
        return rows
    }
}
