import AppKit
import PDFKit

/// Generates a publication-grade, localized 4-page Reading Guide PDF ("Expert PDF Reader - <Reading Guide>.pdf")
/// across all 12 supported languages. Uses a top-down flipped layout engine with dynamic text measurement
/// (`boundingRect`) so titles, cards, keycap tables, and diagrams never clip or overlap in any language.
public enum SamplePDFGenerator {
    public struct GuideContent {
        public let fileName: String
        public let headerTag: String
        public let swatchHeader: String
        public let swatchLabels: [String]
        public let themeCardTitles: [String]
        public let themeCardSubtitles: [String]
        public let diagramLabels: [String]
        public let shortcutsTitle: String
        public let shortcuts: [(label: String, keys: String)]
        public let navGridTitle: String
        public let navGridItems: [(label: String, keys: String)]
        public let chapterFormat: (Int, String) -> String
        public let pages: [(title: String, subtitle: String, sections: [(heading: String, body: String)])]
    }

    public static let guideDirectoryName = "Guides_v4"

    public static func supportDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ExpertPDFReader", isDirectory: true)
            .appendingPathComponent(guideDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func isSampleGuideURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.contains("/ExpertPDFReader/Guides") || path.contains("/OpenPDFExpert/")
    }

    public static func ensureSamplePDFExists(for language: AppLanguage = L10n.resolvedLanguage) -> URL {
        let resolved = language.resolved
        let guide = guideContent(for: resolved)
        let fileURL = supportDirectory().appendingPathComponent(guide.fileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            generateSamplePDF(at: fileURL, guide: guide)
        }
        return fileURL
    }

    // MARK: - Top-Down Vector PDF Layout Engine

    public static func generateSamplePDF(at url: URL, guide: GuideContent) {
        let pdfDocument = PDFDocument()
        let pageSize = CGSize(width: 612, height: 792) // US Letter (612 x 792 pt)
        let marginX: CGFloat = 58
        let contentW: CGFloat = pageSize.width - marginX * 2 // 496 pt

        let brandBlue = NSColor(srgbRed: 0.08, green: 0.45, blue: 0.98, alpha: 1.0)
        let softBlueFill = NSColor(srgbRed: 0.08, green: 0.45, blue: 0.98, alpha: 0.08)
        let inkPrimary = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        let inkSecondary = NSColor(srgbRed: 0.34, green: 0.35, blue: 0.40, alpha: 1.0)
        let inkTertiary = NSColor(srgbRed: 0.50, green: 0.51, blue: 0.56, alpha: 1.0)
        let cardFill = NSColor(srgbRed: 0.973, green: 0.976, blue: 0.984, alpha: 1.0)
        let cardStroke = NSColor(srgbRed: 0.89, green: 0.90, blue: 0.92, alpha: 1.0)
        let hairlineColor = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1.0)

        for (index, content) in guide.pages.enumerated() {
            let data = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                continue
            }

            ctx.beginPDFPage(nil)
            // Flip coordinate system so (0, 0) is top-left and y grows downward
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)

            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            // 1. Page Paper Background
            NSColor.white.setFill()
            NSBezierPath(rect: mediaBox).fill()

            var y: CGFloat = 54

            // 2. Top Eyebrow Row: Pill Badge on Left + Wordmark on Right
            let chapterBadgeText = String(format: "%@  •  0%d / 0%d", guide.headerTag, index + 1, guide.pages.count)
            let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: brandBlue,
                .kern: 0.6
            ]
            let badgeSize = (chapterBadgeText as NSString).size(withAttributes: badgeAttrs)
            let badgeRect = CGRect(x: marginX, y: y, width: badgeSize.width + 20, height: 22)
            softBlueFill.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
            (chapterBadgeText as NSString).draw(
                at: CGPoint(x: badgeRect.minX + 10, y: badgeRect.minY + (22 - badgeSize.height) / 2),
                withAttributes: badgeAttrs
            )

            let rightMark = "EXPERT PDF READER"
            let markAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: inkTertiary,
                .kern: 0.8
            ]
            let markSize = (rightMark as NSString).size(withAttributes: markAttrs)
            (rightMark as NSString).draw(
                at: CGPoint(x: marginX + contentW - markSize.width, y: y + (22 - markSize.height) / 2),
                withAttributes: markAttrs
            )

            y += 32

            // 3. Multi-line Auto-Wrapping Page Title (Never clips!)
            let titlePara = NSMutableParagraphStyle()
            titlePara.lineSpacing = 2
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20.5, weight: .bold),
                .foregroundColor: inkPrimary,
                .paragraphStyle: titlePara
            ]
            let titleH = drawWrappedText(content.title, x: marginX, y: y, width: contentW, attributes: titleAttrs)
            y += titleH + 6

            // 4. Multi-line Auto-Wrapping Subtitle
            let subPara = NSMutableParagraphStyle()
            subPara.lineSpacing = 2
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: inkSecondary,
                .paragraphStyle: subPara
            ]
            let subH = drawWrappedText(content.subtitle, x: marginX, y: y, width: contentW, attributes: subAttrs)
            y += subH + 14

            // 5. Two-tone Accent Divider
            hairlineColor.setFill()
            NSBezierPath(rect: CGRect(x: marginX, y: y, width: contentW, height: 1)).fill()
            brandBlue.setFill()
            NSBezierPath(rect: CGRect(x: marginX, y: y - 0.5, width: 44, height: 2)).fill()
            y += 16

            // 6. Numbered Section Cards
            let headingPara = NSMutableParagraphStyle()
            headingPara.lineSpacing = 2
            let headingAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: inkPrimary,
                .paragraphStyle: headingPara
            ]

            let bodyPara = NSMutableParagraphStyle()
            bodyPara.lineSpacing = 4
            bodyPara.paragraphSpacing = 3
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.2, weight: .regular),
                .foregroundColor: inkSecondary,
                .paragraphStyle: bodyPara
            ]

            for (secIdx, section) in content.sections.enumerated() {
                let innerPadX: CGFloat = 16
                let innerPadY: CGFloat = 12
                let badgeW: CGFloat = 24
                let textX = marginX + innerPadX + badgeW + 10
                let textW = contentW - innerPadX * 2 - badgeW - 10

                let hHeight = measureTextHeight(section.heading, width: textW, attributes: headingAttrs)
                let bHeight = measureTextHeight(section.body, width: textW, attributes: bodyAttrs)
                let cardH = innerPadY + hHeight + 5 + bHeight + innerPadY

                let cardRect = CGRect(x: marginX, y: y, width: contentW, height: cardH)
                cardFill.setFill()
                let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9)
                cardPath.fill()
                cardStroke.setStroke()
                cardPath.lineWidth = 1.0
                cardPath.stroke()

                // Number badge circle
                let numCircleRect = CGRect(x: marginX + innerPadX, y: y + innerPadY, width: 22, height: 22)
                softBlueFill.setFill()
                NSBezierPath(roundedRect: numCircleRect, xRadius: 6, yRadius: 6).fill()
                let numStr = String(format: "%02d", secIdx + 1)
                let numAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                    .foregroundColor: brandBlue
                ]
                let numSize = (numStr as NSString).size(withAttributes: numAttrs)
                (numStr as NSString).draw(
                    at: CGPoint(x: numCircleRect.minX + (22 - numSize.width) / 2, y: numCircleRect.minY + (22 - numSize.height) / 2),
                    withAttributes: numAttrs
                )

                // Section Heading & Body
                _ = drawWrappedText(section.heading, x: textX, y: y + innerPadY + 2, width: textW, attributes: headingAttrs)
                _ = drawWrappedText(section.body, x: textX, y: y + innerPadY + hHeight + 6, width: textW, attributes: bodyAttrs)

                y += cardH + 10
            }

            // 7. Page-Specific Visual Component at Bottom
            y += 2
            if index == 0 {
                // Page 1: 3 Theme Cards (Day / Sepia / Night) + GPU Swatch Bar
                y = drawThemeShowcaseRow(guide: guide, x: marginX, y: y, width: contentW, brandBlue: brandBlue, inkPrimary: inkPrimary, inkSecondary: inkSecondary, cardStroke: cardStroke)
                y += 10
                _ = drawColorSwatchCard(guide: guide, x: marginX, y: y, width: contentW, inkSecondary: inkSecondary, cardFill: cardFill, cardStroke: cardStroke)
            } else if index == 1 {
                // Page 2: Visual Layout & Clear Margins Diagram Card
                _ = drawLayoutDiagramCard(guide: guide, x: marginX, y: y, width: contentW, brandBlue: brandBlue, inkPrimary: inkPrimary, inkSecondary: inkSecondary, cardFill: cardFill, cardStroke: cardStroke)
            } else if index == 2 {
                // Page 3: Sidebar & Navigation Quick-Access Keycap Grid
                _ = drawShortcutGridCard(title: guide.navGridTitle, items: guide.navGridItems, x: marginX, y: y, width: contentW, brandBlue: brandBlue, inkPrimary: inkPrimary, inkSecondary: inkSecondary, cardFill: cardFill, cardStroke: cardStroke)
            } else if index == 3 {
                // Page 4: Essential Keyboard Shortcuts 2-Column Keycap Table
                _ = drawShortcutGridCard(title: guide.shortcutsTitle, items: guide.shortcuts, x: marginX, y: y, width: contentW, brandBlue: brandBlue, inkPrimary: inkPrimary, inkSecondary: inkSecondary, cardFill: cardFill, cardStroke: cardStroke)
            }

            // 8. Editorial Footer
            let footerY: CGFloat = 732
            hairlineColor.setFill()
            NSBezierPath(rect: CGRect(x: marginX, y: footerY - 10, width: contentW, height: 0.8)).fill()

            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: inkTertiary
            ]
            ("Expert PDF Reader  •  macOS Native PDF Reader" as NSString)
                .draw(at: CGPoint(x: marginX, y: footerY), withAttributes: footerAttrs)

            let pageNumStr = String(format: "%02d / %02d", index + 1, guide.pages.count)
            let pageNumSize = (pageNumStr as NSString).size(withAttributes: footerAttrs)
            (pageNumStr as NSString).draw(
                at: CGPoint(x: marginX + contentW - pageNumSize.width, y: footerY),
                withAttributes: footerAttrs
            )

            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
            ctx.closePDF()

            if let singleDoc = PDFDocument(data: data as Data),
               let pdfPage = singleDoc.page(at: 0) {
                pdfDocument.insert(pdfPage, at: pdfDocument.pageCount)
            }
        }

        // Build hierarchical PDFOutline (Table of Contents)
        let rootOutline = PDFOutline()
        for (index, content) in guide.pages.enumerated() {
            guard let page = pdfDocument.page(at: index) else { continue }
            let chapterItem = PDFOutline()
            chapterItem.label = guide.chapterFormat(index + 1, content.title)
            chapterItem.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageSize.height))

            for (secIdx, sec) in content.sections.enumerated() {
                let secItem = PDFOutline()
                secItem.label = "\(secIdx + 1). \(sec.heading)"
                let targetY = pageSize.height - CGFloat(180 + secIdx * 120)
                secItem.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: max(100, targetY)))
                chapterItem.insertChild(secItem, at: chapterItem.numberOfChildren)
            }
            rootOutline.insertChild(chapterItem, at: rootOutline.numberOfChildren)
        }
        pdfDocument.outlineRoot = rootOutline
        pdfDocument.write(to: url)
    }

    // MARK: - Drawing Helpers (Flipped Top-Down Coordinates)

    private static func measureTextHeight(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(rect.height)
    }

    @discardableResult
    private static func drawWrappedText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let h = measureTextHeight(text, width: width, attributes: attributes)
        (text as NSString).draw(
            with: CGRect(x: x, y: y, width: width, height: h + 4),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return h
    }

    private static func drawThemeShowcaseRow(
        guide: GuideContent,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        brandBlue: NSColor,
        inkPrimary: NSColor,
        inkSecondary: NSColor,
        cardStroke: NSColor
    ) -> CGFloat {
        let gap: CGFloat = 10
        let cardW = (width - gap * 2) / 3.0
        let cardH: CGFloat = 68

        let themes: [(bg: NSColor, paper: NSColor, ink: NSColor, border: NSColor)] = [
            (
                NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1),
                NSColor.white,
                NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1),
                cardStroke
            ),
            (
                NSColor(srgbRed: 0.90, green: 0.87, blue: 0.81, alpha: 1),
                NSColor(srgbRed: 0.961, green: 0.938, blue: 0.863, alpha: 1),
                NSColor(srgbRed: 0.247, green: 0.165, blue: 0.094, alpha: 1),
                NSColor(srgbRed: 0.80, green: 0.75, blue: 0.66, alpha: 1)
            ),
            (
                NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1),
                NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1),
                NSColor(srgbRed: 0.78, green: 0.78, blue: 0.80, alpha: 1),
                NSColor(srgbRed: 0.26, green: 0.27, blue: 0.30, alpha: 1)
            )
        ]

        for i in 0..<3 {
            let cx = x + CGFloat(i) * (cardW + gap)
            let rect = CGRect(x: cx, y: y, width: cardW, height: cardH)
            let spec = themes[i]
            spec.bg.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.fill()
            spec.border.setStroke()
            path.lineWidth = 1
            path.stroke()

            // Mini page icon inside card
            let pageRect = CGRect(x: cx + 10, y: y + 11, width: 32, height: 46)
            spec.paper.setFill()
            NSBezierPath(roundedRect: pageRect, xRadius: 3, yRadius: 3).fill()
            for lineIdx in 0..<4 {
                let lw: CGFloat = lineIdx == 0 ? 18 : (lineIdx == 3 ? 14 : 22)
                let lRect = CGRect(x: pageRect.minX + 5, y: pageRect.minY + 8 + CGFloat(lineIdx) * 8, width: lw, height: lineIdx == 0 ? 3 : 2)
                spec.ink.withAlphaComponent(lineIdx == 0 ? 0.9 : 0.55).setFill()
                NSBezierPath(roundedRect: lRect, xRadius: 1, yRadius: 1).fill()
            }

            let tTitle = i < guide.themeCardTitles.count ? guide.themeCardTitles[i] : ""
            let tSub = i < guide.themeCardSubtitles.count ? guide.themeCardSubtitles[i] : ""
            let titleColor = i == 2 ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1) : spec.ink
            let subColor = i == 2 ? NSColor(srgbRed: 0.68, green: 0.69, blue: 0.72, alpha: 1) : spec.ink.withAlphaComponent(0.75)

            let tAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: titleColor
            ]
            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.2, weight: .medium),
                .foregroundColor: subColor
            ]
            _ = drawWrappedText(tTitle, x: cx + 50, y: y + 15, width: cardW - 56, attributes: tAttrs)
            _ = drawWrappedText(tSub, x: cx + 50, y: y + 34, width: cardW - 56, attributes: sAttrs)
        }

        return y + cardH
    }

    private static func drawColorSwatchCard(
        guide: GuideContent,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        inkSecondary: NSColor,
        cardFill: NSColor,
        cardStroke: NSColor
    ) -> CGFloat {
        let cardH: CGFloat = 70
        let cardRect = CGRect(x: x, y: y, width: width, height: cardH)
        cardFill.setFill()
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9)
        path.fill()
        cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: inkSecondary
        ]
        _ = drawWrappedText(guide.swatchHeader, x: x + 14, y: y + 9, width: width - 28, attributes: labelAttrs)

        let swatchColors: [NSColor] = [
            NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1),
            NSColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.52, green: 0.53, blue: 0.57, alpha: 1),
            NSColor(srgbRed: 0.184, green: 0.647, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.235, green: 0.784, blue: 0.235, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.718, blue: 0.169, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.275, blue: 0.333, alpha: 1)
        ]
        let swatchW: CGFloat = (width - 28 - CGFloat(swatchColors.count - 1) * 8) / CGFloat(swatchColors.count)
        for (sIdx, color) in swatchColors.enumerated() {
            let sx = x + 14 + CGFloat(sIdx) * (swatchW + 8)
            let sRect = CGRect(x: sx, y: y + 28, width: swatchW, height: 20)
            color.setFill()
            NSBezierPath(roundedRect: sRect, xRadius: 4, yRadius: 4).fill()

            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8.2, weight: .medium),
                .foregroundColor: inkSecondary
            ]
            let label = sIdx < guide.swatchLabels.count ? guide.swatchLabels[sIdx] : ""
            (label as NSString).draw(
                with: CGRect(x: sx, y: y + 51, width: swatchW + 4, height: 14),
                options: [.usesLineFragmentOrigin],
                attributes: sAttrs
            )
        }
        return y + cardH
    }

    private static func drawLayoutDiagramCard(
        guide: GuideContent,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        brandBlue: NSColor,
        inkPrimary: NSColor,
        inkSecondary: NSColor,
        cardFill: NSColor,
        cardStroke: NSColor
    ) -> CGFloat {
        let gap: CGFloat = 10
        let tileW = (width - gap * 2) / 3.0
        let tileH: CGFloat = 92

        for i in 0..<3 {
            let tx = x + CGFloat(i) * (tileW + gap)
            let rect = CGRect(x: tx, y: y, width: tileW, height: tileH)
            cardFill.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            path.fill()
            cardStroke.setStroke()
            path.lineWidth = 1
            path.stroke()

            let centerX = tx + tileW / 2
            let previewY = y + 12

            if i == 0 {
                // Single Page illustration
                let pRect = CGRect(x: centerX - 18, y: previewY, width: 36, height: 46)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: pRect, xRadius: 3, yRadius: 3).fill()
                brandBlue.withAlphaComponent(0.45).setStroke()
                NSBezierPath(roundedRect: pRect, xRadius: 3, yRadius: 3).stroke()
                for l in 0..<4 {
                    let lr = CGRect(x: pRect.minX + 6, y: pRect.minY + 9 + CGFloat(l) * 8, width: l == 3 ? 15 : 24, height: 2.2)
                    brandBlue.withAlphaComponent(0.55).setFill()
                    NSBezierPath(roundedRect: lr, xRadius: 1, yRadius: 1).fill()
                }
            } else if i == 1 {
                // Two Pages Spread illustration
                for p in 0..<2 {
                    let px = centerX - 35 + CGFloat(p) * 37
                    let pRect = CGRect(x: px, y: previewY, width: 33, height: 46)
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: pRect, xRadius: 3, yRadius: 3).fill()
                    brandBlue.withAlphaComponent(0.45).setStroke()
                    NSBezierPath(roundedRect: pRect, xRadius: 3, yRadius: 3).stroke()
                    for l in 0..<4 {
                        let lr = CGRect(x: pRect.minX + 5, y: pRect.minY + 9 + CGFloat(l) * 8, width: l == 3 ? 13 : 22, height: 2.2)
                        brandBlue.withAlphaComponent(0.55).setFill()
                        NSBezierPath(roundedRect: lr, xRadius: 1, yRadius: 1).fill()
                    }
                }
            } else {
                // Clear Margins CropBox illustration
                let outerRect = CGRect(x: centerX - 22, y: previewY, width: 44, height: 46)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: outerRect, xRadius: 3, yRadius: 3).fill()
                cardStroke.setStroke()
                NSBezierPath(roundedRect: outerRect, xRadius: 3, yRadius: 3).stroke()

                let cropRect = outerRect.insetBy(dx: 7, dy: 6)
                let dashed = NSBezierPath(roundedRect: cropRect, xRadius: 2, yRadius: 2)
                let pattern: [CGFloat] = [3, 2]
                dashed.setLineDash(pattern, count: 2, phase: 0)
                brandBlue.setStroke()
                dashed.lineWidth = 1.2
                dashed.stroke()

                for l in 0..<3 {
                    let lr = CGRect(x: cropRect.minX + 4, y: cropRect.minY + 6 + CGFloat(l) * 8, width: l == 2 ? 14 : 22, height: 2.2)
                    brandBlue.withAlphaComponent(0.65).setFill()
                    NSBezierPath(roundedRect: lr, xRadius: 1, yRadius: 1).fill()
                }
            }

            let label = i < guide.diagramLabels.count ? guide.diagramLabels[i] : ""
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let lAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: inkPrimary,
                .paragraphStyle: para
            ]
            _ = drawWrappedText(label, x: tx + 6, y: y + 66, width: tileW - 12, attributes: lAttrs)
        }

        return y + tileH
    }

    @discardableResult
    private static func drawShortcutGridCard(
        title: String,
        items: [(label: String, keys: String)],
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        brandBlue: NSColor,
        inkPrimary: NSColor,
        inkSecondary: NSColor,
        cardFill: NSColor,
        cardStroke: NSColor
    ) -> CGFloat {
        let rows = (items.count + 1) / 2
        let rowH: CGFloat = 24
        let cardH: CGFloat = 34 + CGFloat(rows) * rowH + 10

        let cardRect = CGRect(x: x, y: y, width: width, height: cardH)
        cardFill.setFill()
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9)
        path.fill()
        cardStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: brandBlue
        ]
        _ = drawWrappedText(title, x: x + 16, y: y + 11, width: width - 32, attributes: headerAttrs)

        let colW = (width - 44) / 2.0
        for (idx, item) in items.enumerated() {
            let col = idx % 2
            let row = idx / 2
            let cellX = x + 16 + CGFloat(col) * (colW + 12)
            let cellY = y + 32 + CGFloat(row) * rowH

            // Keycap pill on the right of the column
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: inkPrimary
            ]
            let keySize = (item.keys as NSString).size(withAttributes: keyAttrs)
            let pillW = max(36, keySize.width + 12)
            let pillRect = CGRect(x: cellX + colW - pillW, y: cellY + 2, width: pillW, height: 18)
            NSColor.white.setFill()
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            pillPath.fill()
            cardStroke.setStroke()
            pillPath.lineWidth = 1
            pillPath.stroke()
            (item.keys as NSString).draw(
                at: CGPoint(x: pillRect.minX + (pillW - keySize.width) / 2, y: pillRect.minY + (18 - keySize.height) / 2),
                withAttributes: keyAttrs
            )

            // Action label on the left of the column
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: inkSecondary
            ]
            let maxLabelW = colW - pillW - 8
            (item.label as NSString).draw(
                with: CGRect(x: cellX, y: cellY + 4, width: maxLabelW, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: labelAttrs
            )
        }

        return y + cardH
    }

    // MARK: - Localized Guide Content for All 12 Languages

    public static func guideContent(for lang: AppLanguage) -> GuideContent {
        switch lang {
        case .zhHans:
            return GuideContent(
                fileName: "Expert PDF Reader - 阅读指南.pdf",
                headerTag: "阅读指南",
                swatchHeader: "GPU 着色器测试色卡（切换 跟随系统 / 日间 / 纸质 / 夜间 观察滤镜响应）",
                swatchLabels: ["墨黑 #000", "深灰 #333", "中灰 #808", "主蓝 #2FA5FF", "翠绿 #3CC83C", "琥珀 #FFB72B", "珊瑚 #FA4655"],
                themeCardTitles: ["日间 Day", "纸质 Sepia", "夜间 Night"],
                themeCardSubtitles: ["白纸 #FFFFFF", "暖黄 #F5EFDC", "护眼 #000000"],
                diagramLabels: ["单页模式 ⌘1", "双页并排 ⌘2", "智能去白边 ⇧⌘M"],
                shortcutsTitle: "常用键盘快捷键速查",
                shortcuts: [
                    ("上一页 / 下一页", "← / →"),
                    ("打开 PDF 文件", "⌘O"),
                    ("新建主页标签", "⌘T"),
                    ("关闭当前标签", "⌘W"),
                    ("切换左侧面板", "⌘B"),
                    ("页面概览网格", "⌃⌘1"),
                    ("清除页面空白边", "⇧⌘M"),
                    ("放大 / 缩小 / 实际大小", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "侧边栏与书签快捷导航",
                navGridItems: [
                    ("显示/隐藏左侧面板", "⌘B"),
                    ("打开页面概览网格", "⌃⌘1"),
                    ("切换到缩略图面板", "⌃⌘2"),
                    ("切换到目录大纲", "⌃⌘3"),
                    ("切换到书签面板", "⌃⌘4"),
                    ("为当前页添加书签", "⌘D")
                ],
                chapterFormat: { idx, title in "第 \(idx) 章：\(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 阅读指南",
                        subtitle: "原生 macOS 高清 PDF 阅读器与 GPU 实时阅读主题",
                        sections: [
                            ("欢迎使用 Expert PDF Reader", "专注纯粹、丝滑的 macOS 原生 PDF 阅读体验。支持多标签页管理、HomeTab 响应式主页、RDDesignLibrary 语义色彩系统，以及原版 RDPDFShaders.metallib 的 GPU 页面滤镜着色器。"),
                            ("四种阅读主题模式：跟随系统 / 日间 / 纸质 / 夜间", "点击顶部工具栏中央的主题按钮或在左侧「显示选项」面板中自由切换。当设为「跟随系统」时，浅色外观默认使用日间主题（可开启“浅色时使用纸质替代日间”），深色外观下自动切换为夜间护眼模式。")
                        ]
                    ),
                    (
                        title: "视图布局、分屏对比与智能去白边",
                        subtitle: "单页 / 双页 / 封面模式 / 垂直与水平分屏 / 智能清除空白边",
                        sections: [
                            ("页面布局模式 (Single / Two Pages / Cover)", "支持单页连续滚动、双页并排连续滚动，以及适合书籍与期刊阅读的「双页（首屏单页封面显示）」模式，可通过 ⌘1 / ⌘2 / ⌘3 一键切换。"),
                            ("分屏对比视图 (Split View)", "支持左右垂直分屏与上下水平分屏。可在两栏同时对比阅读同一文档的不同章节（如左栏看正文、右栏看图表或参考文献），或打开另一份 PDF 对比，并支持同步滚动。"),
                            ("智能清除空白边 (Clear Margins)", "针对页边距过宽的学术论文或扫描版书籍，开启「清除空白边」(⇧⌘M) 后会自动识别每页墨迹边界框并裁切多余白边，最大化有效阅读视野。")
                        ]
                    ),
                    (
                        title: "侧边栏导航：缩略图、目录大纲与书签",
                        subtitle: "高效定位长篇 PDF 文档的每一处关键章节",
                        sections: [
                            ("实时 GPU 主题缩略图 (Thumbnails)", "左侧面板第一栏展示实时同步当前日间 / 纸质 / 夜间 GPU 着色器的页面缩略图，并以亮蓝色高亮当前阅读页。"),
                            ("多级目录大纲 (Outline)", "左侧面板第二栏支持多级章节折叠与展开，显示对应页码，并在滚动阅读时自动高亮当前所在章节。"),
                            ("页面书签管理 (Bookmarks)", "点击工具栏书签图标或按 ⌘D 即可标记当前页。所有书签按文档路径自动持久化保存，支持一键跳转。")
                        ]
                    ),
                    (
                        title: "全文搜索与键盘流操作",
                        subtitle: "即时全文检索、上下文摘要高亮与方向键翻页",
                        sections: [
                            ("全文检索与上下文高亮 (Full-Text Search)", "按 ⌘F 激活右上角搜索框，输入关键词即可在右侧面板按页列出所有匹配结果与上下文摘要，并在 PDF 页面上高亮标记匹配文本，支持 ⌘G / ⇧⌘G 快速跳转上下处匹配。"),
                            ("左右方向键快速翻页", "阅读时直接按键盘 ← 或 → 方向键即可快速切换到上一页或下一页；点击右下角页码浮窗可直接输入页码跳转。")
                        ]
                    )
                ]
            )

        case .zhHant:
            return GuideContent(
                fileName: "Expert PDF Reader - 閱讀指南.pdf",
                headerTag: "閱讀指南",
                swatchHeader: "GPU 著色器測試色卡（切換 跟隨系統 / 日間 / 紙質 / 夜間 觀察濾鏡響應）",
                swatchLabels: ["墨黑 #000", "深灰 #333", "中灰 #808", "主藍 #2FA5FF", "翠綠 #3CC83C", "琥珀 #FFB72B", "珊瑚 #FA4655"],
                themeCardTitles: ["日間 Day", "紙質 Sepia", "夜間 Night"],
                themeCardSubtitles: ["白紙 #FFFFFF", "暖黃 #F5EFDC", "護眼 #000000"],
                diagramLabels: ["單頁模式 ⌘1", "雙頁並排 ⌘2", "智慧去留白 ⇧⌘M"],
                shortcutsTitle: "常用鍵盤快捷鍵速查",
                shortcuts: [
                    ("上一頁 / 下一頁", "← / →"),
                    ("打開 PDF 檔案", "⌘O"),
                    ("新增首頁分頁", "⌘T"),
                    ("關閉目前分頁", "⌘W"),
                    ("切換左側面板", "⌘B"),
                    ("頁面概覽網格", "⌃⌘1"),
                    ("清除頁面留白", "⇧⌘M"),
                    ("放大 / 縮小 / 實際大小", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "側邊欄與書籤快捷導覽",
                navGridItems: [
                    ("顯示/隱藏左側面板", "⌘B"),
                    ("打開頁面概覽網格", "⌃⌘1"),
                    ("切換到縮圖面板", "⌃⌘2"),
                    ("切換到目錄大綱", "⌃⌘3"),
                    ("切換到書籤面板", "⌃⌘4"),
                    ("為目前頁面加入書籤", "⌘D")
                ],
                chapterFormat: { idx, title in "第 \(idx) 章：\(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 閱讀指南",
                        subtitle: "原生 macOS 高清 PDF 閱讀器與 GPU 即時閱讀主題",
                        sections: [
                            ("歡迎使用 Expert PDF Reader", "專注純粹、流暢的 macOS 原生 PDF 閱讀體驗。支援多分頁管理、HomeTab 響應式首頁、RDDesignLibrary 語義色彩系統，以及原版 RDPDFShaders.metallib 的 GPU 頁面濾鏡著色器。"),
                            ("四種閱讀主題模式：跟隨系統 / 日間 / 紙質 / 夜間", "點按頂部工具列中央的主題按鈕或在左側「顯示選項」面板中自由切換。當設為「跟隨系統」時，淺色外觀預設使用日間主題（可開啟「淺色時使用紙質替代日間」），深色外觀下自動切換為夜間護眼模式。")
                        ]
                    ),
                    (
                        title: "視圖佈局、分割對比與智慧去留白",
                        subtitle: "單頁 / 雙頁 / 封面模式 / 垂直與水平分割 / 智慧清除留白",
                        sections: [
                            ("頁面佈局模式 (Single / Two Pages / Cover)", "支援單頁連續捲動、雙頁並排連續捲動，以及適合書籍與期刊閱讀的「雙頁（首屏單頁封面顯示）」模式，可透過 ⌘1 / ⌘2 / ⌘3 一鍵切換。"),
                            ("分割對比視圖 (Split View)", "支援左右垂直分割與上下水平分割。可在兩欄同時對比閱讀同一文件的不同章節，或打開另一份 PDF 對比，並支援同步捲動。"),
                            ("智慧清除留白 (Clear Margins)", "針對頁邊距過寬的學術論文或掃描版書籍，開啟「清除留白」(⇧⌘M) 後會自動識別每頁墨跡邊界並裁切多餘留白，最大化有效閱讀視野。")
                        ]
                    ),
                    (
                        title: "側邊欄導覽：縮圖、目錄大綱與書籤",
                        subtitle: "高效定位長篇 PDF 文件的每一處關鍵章節",
                        sections: [
                            ("即時 GPU 主題縮圖 (Thumbnails)", "左側面板第一欄展示即時同步目前日間 / 紙質 / 夜間 GPU 著色器的頁面縮圖，並以亮藍色醒目顯示目前閱讀頁。"),
                            ("多層級目錄大綱 (Outline)", "左側面板第二欄支援多層級章節摺疊與展開，顯示對應頁碼，並在捲動閱讀時自動醒目顯示目前所在章節。"),
                            ("頁面書籤管理 (Bookmarks)", "點按工具列書籤圖示或按 ⌘D 即可標記目前頁面。所有書籤自動持久化儲存，支援一鍵跳轉。")
                        ]
                    ),
                    (
                        title: "全文搜尋與鍵盤流操作",
                        subtitle: "即時全文檢索、上下文摘要醒目顯示與方向鍵翻頁",
                        sections: [
                            ("全文檢索與上下文醒目顯示 (Full-Text Search)", "按 ⌘F 啟用右上角搜尋框，輸入關鍵字即可在右側面板按頁列出所有符合結果與上下文摘要，並在 PDF 頁面上標記符合文字，支援 ⌘G / ⇧⌘G 快速跳轉。"),
                            ("左右方向鍵快速翻頁", "閱讀時直接按鍵盤 ← 或 → 方向鍵即可快速切換到上一頁或下一頁；點按右下角頁碼浮窗可直接輸入頁碼跳轉。")
                        ]
                    )
                ]
            )

        case .ja:
            return GuideContent(
                fileName: "Expert PDF Reader - 読書ガイド.pdf",
                headerTag: "読書ガイド",
                swatchHeader: "GPU シェーダーテストカラー（自動 / 昼 / セピア / 夜 を切り替えて確認）",
                swatchLabels: ["黒 #000", "濃灰 #333", "中灰 #808", "青 #2FA5FF", "緑 #3CC83C", "黄 #FFB72B", "赤 #FA4655"],
                themeCardTitles: ["昼 Day", "セピア Sepia", "夜 Night"],
                themeCardSubtitles: ["白紙 #FFFFFF", "暖色 #F5EFDC", "暗色 #000000"],
                diagramLabels: ["単一ページ ⌘1", "見開き表示 ⌘2", "余白トリミング ⇧⌘M"],
                shortcutsTitle: "主なキーボードショートカット",
                shortcuts: [
                    ("前のページ / 次のページ", "← / →"),
                    ("ファイルを開く", "⌘O"),
                    ("新規ホームタブ", "⌘T"),
                    ("タブを閉じる", "⌘W"),
                    ("左パネルの表示切替", "⌘B"),
                    ("ページ一覧グリッド", "⌃⌘1"),
                    ("余白をトリミング", "⇧⌘M"),
                    ("拡大 / 縮小 / 実際のサイズ", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "サイドバー＆ブックマーク操作",
                navGridItems: [
                    ("左パネルを表示/隠す", "⌘B"),
                    ("ページ一覧を開く", "⌃⌘1"),
                    ("サムネイルを表示", "⌃⌘2"),
                    ("アウトラインを表示", "⌃⌘3"),
                    ("ブックマークを表示", "⌃⌘4"),
                    ("ページをブックマーク", "⌘D")
                ],
                chapterFormat: { idx, title in "第\(idx)章：\(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 読書ガイド",
                        subtitle: "macOS ネイティブ PDF リーダー＆ GPU リアルタイム読書テーマ",
                        sections: [
                            ("Expert PDF Reader へようこそ", "不要な編集機能や課金ウォールを省き、快適で鮮明な PDF 読書体験に特化した macOS ネイティブアプリです。マルチタブ、HomeTab、RDDesignLibrary カラートークン、GPU シェーダーを搭載しています。"),
                            ("4つの読書テーマモード：システム連動 / 昼 / セピア / 夜", "ツールバー中央または左パネルの「表示設定」から切り替え可能です。「システムに合わせる」を選択すると、ライト時は昼（設定オン時はセピア）、ダーク時は夜モードに自動切り替えされます。")
                        ]
                    ),
                    (
                        title: "ページレイアウト・分割表示・余白トリミング",
                        subtitle: "単一ページ / 見開き / 表紙モード / 左右・上下分割 / 余白をトリミング",
                        sections: [
                            ("ページレイアウトモード (⌘1 / ⌘2 / ⌘3)", "単一ページ連続スクロール、見開き2ページ、見開き（表紙を単独表示）をワンクリックで切り替えられます。"),
                            ("分割表示での比較閲覧 (Split View)", "画面を左右または上下に分割し、同じ書類の別章や別の PDF 書類を並べて比較できます。同期スクロールにも対応しています。"),
                            ("スマート余白トリミング (⇧⌘M)", "論文やスキャン書籍の広い余白を自動検出し、本文領域に合わせてページの余白をトリミングして大きく表示します。")
                        ]
                    ),
                    (
                        title: "サイドバー：サムネイル・アウトライン・ブックマーク",
                        subtitle: "長文の PDF 書類でも素早く目的の章やページへ移動",
                        sections: [
                            ("リアルタイム GPU テーマ対応サムネイル", "現在の昼・セピア・夜テーマがリアルタイムに反映されるページサムネイルを表示し、現在ページを青枠で強調します。"),
                            ("階層アウトライン（目次）", "多階層の見出しツリーを展開・折りたたみでき、スクロールに合わせて読んでいる章が自動ハイライトされます。"),
                            ("ページブックマーク (⌘D)", "⌘D またはツールバーのアイコンで現在のページをブックマークに登録し、いつでも素早く移動できます。")
                        ]
                    ),
                    (
                        title: "全文検索とキーボード操作",
                        subtitle: "高速テキスト検索と ← / → 矢印キーによるページめくり",
                        sections: [
                            ("全文検索と文脈スニペット (⌘F)", "⌘F で検索欄にフォーカスし、キーワードを入力すると右パネルにページ順で文脈付きの一致箇所が一覧表示されます。⌘G / ⇧⌘G で次・前の一致箇所へ移動できます。"),
                            ("左右の矢印キーで素早くページ移動", "読書中に ← / → キーを押すだけで前後のページへ移動できます。右下のページ番号をクリックすると指定ページへ直接ジャンプできます。")
                        ]
                    )
                ]
            )

        case .ko:
            return GuideContent(
                fileName: "Expert PDF Reader - 읽기 가이드.pdf",
                headerTag: "읽기 가이드",
                swatchHeader: "GPU 셰이더 색상 테스트 (자동 / 주간 / 세피아 / 야간 전환 시 반응 확인)",
                swatchLabels: ["블랙 #000", "다크 #333", "그레이 #808", "블루 #2FA5FF", "그린 #3CC83C", "앰버 #FFB72B", "코랄 #FA4655"],
                themeCardTitles: ["주간 Day", "세피아 Sepia", "야간 Night"],
                themeCardSubtitles: ["화이트 #FFFFFF", "양피지 #F5EFDC", "다크 #000000"],
                diagramLabels: ["단일 페이지 ⌘1", "두 페이지 ⌘2", "여백 제거 ⇧⌘M"],
                shortcutsTitle: "주요 키보드 단축키 안내",
                shortcuts: [
                    ("이전 / 다음 페이지", "← / →"),
                    ("PDF 파일 열기", "⌘O"),
                    ("새 홈 탭 열기", "⌘T"),
                    ("현재 탭 닫기", "⌘W"),
                    ("왼쪽 패널 전환", "⌘B"),
                    ("페이지 개요 그리드", "⌃⌘1"),
                    ("페이지 여백 제거", "⇧⌘M"),
                    ("확대 / 축소 / 실제 크기", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "사이드바 및 책갈피 단축키",
                navGridItems: [
                    ("왼쪽 패널 표시/가리기", "⌘B"),
                    ("페이지 개요 열기", "⌃⌘1"),
                    ("축소판 탭 열기", "⌃⌘2"),
                    ("개요(목차) 탭 열기", "⌃⌘3"),
                    ("책갈피 탭 열기", "⌃⌘4"),
                    ("현재 페이지 책갈피", "⌘D")
                ],
                chapterFormat: { idx, title in "제\(idx)장: \(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 읽기 가이드",
                        subtitle: "macOS 네이티브 고화질 PDF 리더 및 실시간 GPU 읽기 테마",
                        sections: [
                            ("Expert PDF Reader에 오신 것을 환영합니다", "불필요한 편집 기능 없이 빠르고 선명한 PDF 읽기에 집중한 macOS 네이티브 앱입니다. 멀티 탭, HomeTab 아키텍처, RDDesignLibrary 색상 시스템 및 GPU 페이지 셰이더를 제공합니다."),
                            ("네 가지 읽기 테마: 시스템 설정 따르기 / 주간 / 세피아 / 야간", "도구 모음 중앙 또는 왼쪽 '보기 옵션'에서 전환할 수 있습니다. '시스템 설정 따르기'를 선택하면 라이트 모드에서는 주간(또는 옵션 활성화 시 세피아), 다크 모드에서는 야간 테마로 자동 전환됩니다.")
                        ]
                    ),
                    (
                        title: "페이지 레이아웃, 분할 보기 및 여백 제거",
                        subtitle: "단일 / 두 페이지 / 표지 모드 / 수직·수평 분할 / 스마트 여백 제거",
                        sections: [
                            ("페이지 레이아웃 모드 (⌘1 / ⌘2 / ⌘3)", "단일 페이지 연속 스크롤, 두 페이지 나란히 보기, 두 페이지(표지 단독 표시) 모드를 단축키로 즉시 전환할 수 있습니다."),
                            ("분할 보기 비교 (Split View)", "좌/우 수직 분할 또는 상/하 수평 분할로 같은 문서의 다른 장이나 다른 PDF 문서를 나란히 비교하며 동기화 스크롤을 사용할 수 있습니다."),
                            ("스마트 여백 제거 (⇧⌘M)", "논문이나 스캔 문서의 넓은 흰 여백을 자동으로 감지하여 본문 경계에 맞게 여백을 깔끔하게 잘라냅니다.")
                        ]
                    ),
                    (
                        title: "사이드바 탐색: 축소판, 개요 및 책갈피",
                        subtitle: "긴 PDF 문서의 원하는 장과 페이지를 빠르게 탐색",
                        sections: [
                            ("실시간 GPU 테마 축소판 (Thumbnails)", "현재 적용된 주간 / 세피아 / 야간 GPU 테마가 반영된 페이지 축소판을 표시하고 현재 페이지를 강조합니다."),
                            ("다단계 목차 개요 (Outline)", "계층형 목차 트리를 접거나 펼칠 수 있으며 스크롤할 때 현재 읽고 있는 섹션이 자동으로 강조됩니다."),
                            ("페이지 책갈피 관리 (Bookmarks)", "⌘D를 누르거나 도구 모음의 책갈피 아이콘을 클릭하여 중요한 페이지를 저장하고 빠르게 이동할 수 있습니다.")
                        ]
                    ),
                    (
                        title: "전체 텍스트 검색 및 키보드 탐색",
                        subtitle: "실시간 문맥 요약 하이라이트 및 ← / → 방향키 페이지 이동",
                        sections: [
                            ("전체 텍스트 검색 (⌘F)", "⌘F를 눌러 키워드를 입력하면 오른쪽 패널에 페이지별 문맥 요약이 표시되고 본문에서 일치하는 단어가 강조됩니다. ⌘G / ⇧⌘G로 다음/이전 결과를 탐색하세요."),
                            ("좌우 방향키로 빠른 페이지 이동", "읽는 도중 키보드의 ← 또는 → 방향키를 눌러 이전/다음 페이지로 즉시 이동할 수 있습니다.")
                        ]
                    )
                ]
            )

        case .fr:
            return GuideContent(
                fileName: "Expert PDF Reader - Guide de lecture.pdf",
                headerTag: "GUIDE DE LECTURE",
                swatchHeader: "Nuancier de test des shaders GPU (Auto / Jour / Sépia / Nuit)",
                swatchLabels: ["Noir #000", "Gris #333", "Moyen #808", "Bleu #2FA5FF", "Vert #3CC83C", "Ambre #FFB72B", "Corail #FA4655"],
                themeCardTitles: ["Jour Day", "Sépia Sepia", "Nuit Night"],
                themeCardSubtitles: ["Papier #FFFFFF", "Crème #F5EFDC", "Sombre #000000"],
                diagramLabels: ["Page simple ⌘1", "Deux pages ⌘2", "Rogner marges ⇧⌘M"],
                shortcutsTitle: "Raccourcis clavier essentiels",
                shortcuts: [
                    ("Page précédente / suivante", "← / →"),
                    ("Ouvrir un fichier PDF", "⌘O"),
                    ("Nouvel onglet Accueil", "⌘T"),
                    ("Fermer l’onglet actif", "⌘W"),
                    ("Afficher/masquer panneau", "⌘B"),
                    ("Aperçu des pages", "⌃⌘1"),
                    ("Rogner les marges", "⇧⌘M"),
                    ("Zoom + / - / Taille réelle", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Navigation latérale et signets",
                navGridItems: [
                    ("Panneau latéral gauche", "⌘B"),
                    ("Grille d’aperçu des pages", "⌃⌘1"),
                    ("Onglet Vignettes", "⌃⌘2"),
                    ("Onglet Plan (Sommaire)", "⌃⌘3"),
                    ("Onglet Signets", "⌃⌘4"),
                    ("Ajouter/retirer un signet", "⌘D")
                ],
                chapterFormat: { idx, title in "Chapitre \(idx) : \(title)" },
                pages: [
                    (
                        title: "Guide de lecture Expert PDF Reader",
                        subtitle: "Lecteur PDF macOS natif avec thèmes GPU en temps réel",
                        sections: [
                            ("Bienvenue dans Expert PDF Reader", "Conçu pour une lecture PDF fluide et parfaitement nette sur macOS, avec gestion multi-onglets, écran d’accueil HomeTab, palette RDDesignLibrary et shaders GPU RDPDFShaders.metallib."),
                            ("Thèmes de lecture : Suivre le système, Jour, Sépia et Nuit", "En mode « Suivre le système », le mode clair utilise Jour (ou Sépia si l’option est activée) et le mode sombre bascule automatiquement sur Nuit avec une netteté Retina maximale.")
                        ]
                    ),
                    (
                        title: "Mise en page, Vue fractionnée et Marges",
                        subtitle: "Page simple, Deux pages, Couverture, Vue fractionnée et Rognage des marges",
                        sections: [
                            ("Modes de mise en page (⌘1 / ⌘2 / ⌘3)", "Passez instantanément entre Page simple, Deux pages côte à côte et Deux pages avec couverture seule."),
                            ("Comparaison en vue fractionnée (Split View)", "Comparez deux chapitres d’un même document ou deux fichiers PDF différents en affichage vertical ou horizontal avec défilement synchronisé."),
                            ("Rognage intelligent des marges (⇧⌘M)", "Détecte automatiquement les bordures d’encre de chaque page pour masquer les marges blanches superflues.")
                        ]
                    ),
                    (
                        title: "Barre latérale : Vignettes, Plan et Signets",
                        subtitle: "Repérez et rejoignez chaque section en un instant",
                        sections: [
                            ("Vignettes thématiques en direct", "Les vignettes de pages reflètent en temps réel le thème GPU actif (Jour, Sépia ou Nuit) et encadrent la page actuelle."),
                            ("Plan hiérarchique du document", "Dépliez la table des matières multi-niveaux tandis que le chapitre en cours de lecture est automatiquement mis en évidence."),
                            ("Signets de page (⌘D)", "Ajoutez un signet sur n’importe quelle page avec ⌘D pour la retrouver immédiatement.")
                        ]
                    ),
                    (
                        title: "Recherche plein texte et Navigation clavier",
                        subtitle: "Extraits contextuels mis en évidence et touches fléchées ← / →",
                        sections: [
                            ("Recherche plein texte instantanée (⌘F)", "Appuyez sur ⌘F pour rechercher un terme dans tout le document, afficher les extraits par page et naviguer entre les résultats avec ⌘G / ⇧⌘G."),
                            ("Changement de page avec les flèches ← / →", "Utilisez directement les touches fléchées gauche (←) et droite (→) pour passer à la page précédente ou suivante.")
                        ]
                    )
                ]
            )

        case .de:
            return GuideContent(
                fileName: "Expert PDF Reader - Lesehandbuch.pdf",
                headerTag: "LESEHANDBUCH",
                swatchHeader: "GPU-Shader-Farbtest (System / Tag / Sepia / Nacht umschalten)",
                swatchLabels: ["Schwarz #000", "Dunkel #333", "Grau #808", "Blau #2FA5FF", "Grün #3CC83C", "Bernstein #FFB72B", "Koralle #FA4655"],
                themeCardTitles: ["Tag Day", "Sepia", "Nacht Night"],
                themeCardSubtitles: ["Papier #FFFFFF", "Warm #F5EFDC", "Dunkel #000000"],
                diagramLabels: ["Einzelseite ⌘1", "Zwei Seiten ⌘2", "Ränder ⇧⌘M"],
                shortcutsTitle: "Wichtige Tastaturkurzbefehle",
                shortcuts: [
                    ("Vorherige / Nächste Seite", "← / →"),
                    ("PDF-Datei öffnen", "⌘O"),
                    ("Neuer Start-Tab", "⌘T"),
                    ("Aktuellen Tab schließen", "⌘W"),
                    ("Seitenleiste ein/aus", "⌘B"),
                    ("Seitenübersicht", "⌃⌘1"),
                    ("Seitenränder ausblenden", "⇧⌘M"),
                    ("Zoom + / - / Originalgröße", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Seitenleiste & Lesezeichen",
                navGridItems: [
                    ("Linke Seitenleiste", "⌘B"),
                    ("Seitenübersicht öffnen", "⌃⌘1"),
                    ("Miniaturen anzeigen", "⌃⌘2"),
                    ("Gliederung anzeigen", "⌃⌘3"),
                    ("Lesezeichen anzeigen", "⌃⌘4"),
                    ("Lesezeichen umschalten", "⌘D")
                ],
                chapterFormat: { idx, title in "Kapitel \(idx): \(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader Lesehandbuch",
                        subtitle: "Nativer macOS-PDF-Reader mit Echtzeit-GPU-Lesethemen",
                        sections: [
                            ("Willkommen bei Expert PDF Reader", "Entwickelt für ein schnelles, gestochen scharfes PDF-Leseerlebnis unter macOS – mit Multi-Tab-Leiste, HomeTab, RDDesignLibrary-Farbsystem und originalen RDPDFShaders.metallib GPU-Shadern."),
                            ("Lesethemen: System folgen, Tag, Sepia und Nacht", "Im Modus „System folgen“ nutzt das helle Erscheinungsbild automatisch Tag (oder optional Sepia) und das dunkle Erscheinungsbild blendfreies Nacht-Rendering bei voller Retina-Schärfe.")
                        ]
                    ),
                    (
                        title: "Seitenlayout, Geteilte Ansicht & Seitenränder",
                        subtitle: "Einzelseite, Zwei Seiten, Deckblatt, Geteilte Ansicht und Ränder ausblenden",
                        sections: [
                            ("Seitenlayout-Modi (⌘1 / ⌘2 / ⌘3)", "Wechseln Sie jederzeit zwischen Einzelseite, Zwei Seiten nebeneinander und Zwei Seiten mit einzelnem Deckblatt."),
                            ("Geteilte Ansicht zum Vergleichen (Split View)", "Öffnen Sie eine vertikale oder horizontale geteilte Ansicht, um zwei Kapitel oder zwei PDF-Dateien synchron nebeneinander zu lesen."),
                            ("Intelligentes Ausblenden von Seitenrändern (⇧⌘M)", "Erkennt automatisch den bedruckten Bereich jeder Seite und schneidet breite weiße Ränder für maximale Lesefläche ab.")
                        ]
                    ),
                    (
                        title: "Seitenleiste: Miniaturen, Gliederung & Lesezeichen",
                        subtitle: "Schnelle Orientierung in umfangreichen PDF-Dokumenten",
                        sections: [
                            ("Live-Miniaturen mit GPU-Thema", "Die Seitenminiaturen werden in Echtzeit mit dem aktiven Tag-, Sepia- oder Nacht-Shader dargestellt."),
                            ("Hierarchische Gliederung (Inhaltsverzeichnis)", "Klappen Sie Kapitelebenen auf oder zu, während der aktuell gelesene Abschnitt beim Scrollen automatisch hervorgehoben wird."),
                            ("Seitenlesezeichen (⌘D)", "Markieren Sie wichtige Seiten per Klick oder mit ⌘D für den schnellen Direktzugriff.")
                        ]
                    ),
                    (
                        title: "Volltextsuche & Tastaturnavigation",
                        subtitle: "Kontexttreffer nach Seiten und Blättern mit den Pfeiltasten ← / →",
                        sections: [
                            ("Schnelle Volltextsuche (⌘F)", "Drücken Sie ⌘F, um das gesamte Dokument zu durchsuchen, Treffer mit Textausschnitten nach Seiten aufzulisten und mit ⌘G / ⇧⌘G durchzuspringen."),
                            ("Seitenwechsel mit den Pfeiltasten ← / →", "Mit den Pfeiltasten Links (←) und Rechts (→) blättern Sie direkt zur vorherigen oder nächsten Seite.")
                        ]
                    )
                ]
            )

        case .es:
            return GuideContent(
                fileName: "Expert PDF Reader - Guía de lectura.pdf",
                headerTag: "GUÍA DE LECTURA",
                swatchHeader: "Muestra de prueba de shaders GPU (Auto / Día / Sepia / Noche)",
                swatchLabels: ["Negro #000", "Oscuro #333", "Gris #808", "Azul #2FA5FF", "Verde #3CC83C", "Ámbar #FFB72B", "Coral #FA4655"],
                themeCardTitles: ["Día Day", "Sepia", "Noche Night"],
                themeCardSubtitles: ["Papel #FFFFFF", "Crema #F5EFDC", "Oscuro #000000"],
                diagramLabels: ["Individual ⌘1", "Dos páginas ⌘2", "Recortar ⇧⌘M"],
                shortcutsTitle: "Atajos de teclado esenciales",
                shortcuts: [
                    ("Página anterior / siguiente", "← / →"),
                    ("Abrir archivo PDF", "⌘O"),
                    ("Nueva pestaña de inicio", "⌘T"),
                    ("Cerrar pestaña actual", "⌘W"),
                    ("Mostrar/ocultar panel", "⌘B"),
                    ("Vista general de páginas", "⌃⌘1"),
                    ("Recortar márgenes", "⇧⌘M"),
                    ("Zoom + / - / Tamaño real", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Navegación lateral y marcadores",
                navGridItems: [
                    ("Panel lateral izquierdo", "⌘B"),
                    ("Cuadrícula de páginas", "⌃⌘1"),
                    ("Pestaña Miniaturas", "⌃⌘2"),
                    ("Pestaña Esquema", "⌃⌘3"),
                    ("Pestaña Marcadores", "⌃⌘4"),
                    ("Alternar marcador", "⌘D")
                ],
                chapterFormat: { idx, title in "Capítulo \(idx): \(title)" },
                pages: [
                    (
                        title: "Guía de lectura de Expert PDF Reader",
                        subtitle: "Lector PDF nativo para macOS con temas GPU en tiempo real",
                        sections: [
                            ("Bienvenido a Expert PDF Reader", "Diseñado para una lectura de PDF rápida y nítida en macOS, con múltiples pestañas, pantalla de inicio HomeTab, paleta RDDesignLibrary y sombreadores GPU RDPDFShaders.metallib."),
                            ("Temas de lectura: Seguir al sistema, Día, Sepia y Noche", "Al elegir «Seguir al sistema», el modo claro utiliza Día (o Sepia si está activado) y el modo oscuro cambia automáticamente a Noche manteniendo total nitidez Retina.")
                        ]
                    ),
                    (
                        title: "Diseño de página, Vista dividida y Márgenes",
                        subtitle: "Página individual, Dos páginas, Portada, Vista dividida y Recortar márgenes",
                        sections: [
                            ("Modos de diseño de página (⌘1 / ⌘2 / ⌘3)", "Alterne al instante entre Página individual, Dos páginas y Dos páginas con portada individual."),
                            ("Comparación en vista dividida (Split View)", "Compare dos secciones del mismo documento o dos archivos PDF en paralelo (vertical u horizontal) con desplazamiento sincronizado."),
                            ("Recorte inteligente de márgenes (⇧⌘M)", "Detecta automáticamente los bordes del contenido y recorta los márgenes blancos para aprovechar toda la pantalla.")
                        ]
                    ),
                    (
                        title: "Barra lateral: Miniaturas, Esquema y Marcadores",
                        subtitle: "Explore y localice cualquier capítulo con rapidez",
                        sections: [
                            ("Miniaturas con tema GPU en vivo", "Las miniaturas de página se renderizan en tiempo real con el tema Día, Sepia o Noche activo."),
                            ("Esquema jerárquico (Tabla de contenido)", "Expanda o contraiga capítulos anidados mientras la sección actual se resalta automáticamente al desplazarse."),
                            ("Marcadores de página (⌘D)", "Guarde cualquier página con ⌘D para volver a ella con un solo clic.")
                        ]
                    ),
                    (
                        title: "Búsqueda de texto y Navegación con teclado",
                        subtitle: "Fragmentos resaltados por página y cambio de página con ← / →",
                        sections: [
                            ("Búsqueda de texto completo (⌘F)", "Pulse ⌘F para buscar palabras clave, ver coincidencias agrupadas por página con contexto y saltar entre ellas con ⌘G / ⇧⌘G."),
                            ("Navegación rápida con teclas ← / →", "Pulse las flechas izquierda (←) y derecha (→) para pasar directamente a la página anterior o siguiente.")
                        ]
                    )
                ]
            )

        case .it:
            return GuideContent(
                fileName: "Expert PDF Reader - Guida alla lettura.pdf",
                headerTag: "GUIDA ALLA LETTURA",
                swatchHeader: "Campioni di test shader GPU (Auto / Giorno / Seppia / Notte)",
                swatchLabels: ["Nero #000", "Scuro #333", "Grigio #808", "Blu #2FA5FF", "Verde #3CC83C", "Ambra #FFB72B", "Corallo #FA4655"],
                themeCardTitles: ["Giorno Day", "Seppia Sepia", "Notte Night"],
                themeCardSubtitles: ["Carta #FFFFFF", "Crema #F5EFDC", "Scuro #000000"],
                diagramLabels: ["Pagina singola ⌘1", "Due pagine ⌘2", "Ritaglia margini ⇧⌘M"],
                shortcutsTitle: "Scorciatoie da tastiera principali",
                shortcuts: [
                    ("Pagina precedente / successiva", "← / →"),
                    ("Apri file PDF", "⌘O"),
                    ("Nuova scheda Home", "⌘T"),
                    ("Chiudi scheda corrente", "⌘W"),
                    ("Mostra/nascondi pannello", "⌘B"),
                    ("Panoramica pagine", "⌃⌘1"),
                    ("Ritaglia margini pagina", "⇧⌘M"),
                    ("Zoom + / - / Dimensioni reali", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Barra laterale e segnalibri",
                navGridItems: [
                    ("Pannello laterale sinistro", "⌘B"),
                    ("Griglia panoramica pagine", "⌃⌘1"),
                    ("Scheda Miniature", "⌃⌘2"),
                    ("Scheda Struttura (Indice)", "⌃⌘3"),
                    ("Scheda Segnalibri", "⌃⌘4"),
                    ("Aggiungi/rimuovi segnalibro", "⌘D")
                ],
                chapterFormat: { idx, title in "Capitolo \(idx): \(title)" },
                pages: [
                    (
                        title: "Guida alla lettura di Expert PDF Reader",
                        subtitle: "Lettore PDF nativo per macOS con temi GPU in tempo reale",
                        sections: [
                            ("Benvenuto in Expert PDF Reader", "Progettato per una lettura PDF fluida e nitida su macOS, con schede multiple, schermata HomeTab, palette RDDesignLibrary e shader GPU RDPDFShaders.metallib."),
                            ("Temi di lettura: Segui il sistema, Giorno, Seppia e Notte", "Con «Segui il sistema», la modalità chiara utilizza Giorno (o Seppia se abilitato) e la modalità scura passa automaticamente a Notte mantenendo la massima nitidezza Retina.")
                        ]
                    ),
                    (
                        title: "Layout pagina, Vista divisa e Margini",
                        subtitle: "Pagina singola, Due pagine, Copertina, Vista divisa e Ritaglia margini",
                        sections: [
                            ("Modalità layout pagina (⌘1 / ⌘2 / ⌘3)", "Passa rapidamente tra Pagina singola, Due pagine affiancate e Due pagine con copertina singola."),
                            ("Confronto in vista divisa (Split View)", "Confronta due sezioni dello stesso documento o due PDF diversi in verticale o orizzontale con scorrimento sincronizzato."),
                            ("Ritaglio intelligente dei margini (⇧⌘M)", "Rileva automaticamente i bordi del testo e ritaglia i margini bianchi superflui per massimizzare l’area di lettura.")
                        ]
                    ),
                    (
                        title: "Barra laterale: Miniature, Struttura e Segnalibri",
                        subtitle: "Raggiungi qualsiasi capitolo o pagina in un attimo",
                        sections: [
                            ("Miniature con tema GPU in tempo reale", "Le miniature delle pagine riflettono dal vivo il tema Giorno, Seppia o Notte attivo."),
                            ("Struttura gerarchica (Indice)", "Espandi o comprimi i capitoli dell’indice mentre la sezione corrente viene evidenziata automaticamente."),
                            ("Segnalibri di pagina (⌘D)", "Premi ⌘D per aggiungere un segnalibro alla pagina corrente e tornarci subito.")
                        ]
                    ),
                    (
                        title: "Ricerca nel testo e Navigazione da tastiera",
                        subtitle: "Risultati contestuali per pagina e frecce ← / → per sfogliare",
                        sections: [
                            ("Ricerca nel testo completo (⌘F)", "Premi ⌘F per cercare parole chiave nel documento, visualizzare gli estratti per pagina e scorrere i risultati con ⌘G / ⇧⌘G."),
                            ("Cambio pagina rapido con i tasti ← / →", "Usa i tasti freccia sinistra (←) e destra (→) per passare immediatamente alla pagina precedente o successiva.")
                        ]
                    )
                ]
            )

        case .pt:
            return GuideContent(
                fileName: "Expert PDF Reader - Guia de leitura.pdf",
                headerTag: "GUIA DE LEITURA",
                swatchHeader: "Amostras de teste de shaders GPU (Auto / Dia / Sépia / Noite)",
                swatchLabels: ["Preto #000", "Escuro #333", "Cinza #808", "Azul #2FA5FF", "Verde #3CC83C", "Âmbar #FFB72B", "Coral #FA4655"],
                themeCardTitles: ["Dia Day", "Sépia Sepia", "Noite Night"],
                themeCardSubtitles: ["Papel #FFFFFF", "Creme #F5EFDC", "Escuro #000000"],
                diagramLabels: ["Página única ⌘1", "Duas páginas ⌘2", "Cortar margens ⇧⌘M"],
                shortcutsTitle: "Atalhos de teclado essenciais",
                shortcuts: [
                    ("Página anterior / próxima", "← / →"),
                    ("Abrir arquivo PDF", "⌘O"),
                    ("Nova aba Início", "⌘T"),
                    ("Fechar aba atual", "⌘W"),
                    ("Mostrar/ocultar painel", "⌘B"),
                    ("Visão geral das páginas", "⌃⌘1"),
                    ("Cortar margens da página", "⇧⌘M"),
                    ("Zoom + / - / Tamanho real", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Barra lateral e marcadores",
                navGridItems: [
                    ("Painel lateral esquerdo", "⌘B"),
                    ("Grade de visão geral", "⌃⌘1"),
                    ("Aba Miniaturas", "⌃⌘2"),
                    ("Aba Sumário", "⌃⌘3"),
                    ("Aba Marcadores", "⌃⌘4"),
                    ("Alternar marcador", "⌘D")
                ],
                chapterFormat: { idx, title in "Capítulo \(idx): \(title)" },
                pages: [
                    (
                        title: "Guia de leitura do Expert PDF Reader",
                        subtitle: "Leitor de PDF nativo para macOS com temas de GPU em tempo real",
                        sections: [
                            ("Bem-vindo ao Expert PDF Reader", "Criado para uma leitura de PDF rápida e nítida no macOS, com várias abas, tela inicial HomeTab, paleta RDDesignLibrary e shaders de GPU RDPDFShaders.metallib."),
                            ("Temas de leitura: Seguir o sistema, Dia, Sépia e Noite", "Em «Seguir o sistema», o modo claro usa Dia (ou Sépia quando ativado) e o modo escuro alterna automaticamente para Noite preservando toda a nitidez Retina.")
                        ]
                    ),
                    (
                        title: "Layout da página, Visualização dividida e Margens",
                        subtitle: "Página única, Duas páginas, Capa, Visualização dividida e Cortar margens",
                        sections: [
                            ("Modos de layout da página (⌘1 / ⌘2 / ⌘3)", "Alterne rapidamente entre Página única, Duas páginas lado a lado e Duas páginas com capa única."),
                            ("Comparação em visualização dividida (Split View)", "Compare duas seções do mesmo documento ou dois arquivos PDF lado a lado com rolagem sincronizada."),
                            ("Corte inteligente de margens (⇧⌘M)", "Detecta automaticamente os limites do texto e corta margens brancas excessivas para ampliar a área útil de leitura.")
                        ]
                    ),
                    (
                        title: "Barra lateral: Miniaturas, Sumário e Marcadores",
                        subtitle: "Navegue rapidamente por documentos PDF extensos",
                        sections: [
                            ("Miniaturas com tema de GPU ao vivo", "As miniaturas de página são renderizadas em tempo real com o tema Dia, Sépia ou Noite ativo."),
                            ("Sumário hierárquico (Outline)", "Expanda ou recolha capítulos enquanto a seção atual é destacada automaticamente durante a rolagem."),
                            ("Marcadores de página (⌘D)", "Adicione marcadores a qualquer página pressionando ⌘D para acesso rápido.")
                        ]
                    ),
                    (
                        title: "Pesquisa de texto e Navegação por teclado",
                        subtitle: "Trechos destacados por página e navegação com as setas ← / →",
                        sections: [
                            ("Pesquisa de texto completo (⌘F)", "Pressione ⌘F para pesquisar palavras-chave no documento, ver ocorrências agrupadas por página e navegar com ⌘G / ⇧⌘G."),
                            ("Mudança rápida de página com ← / →", "Use as teclas de seta para a esquerda (←) e direita (→) para ir diretamente para a página anterior ou seguinte.")
                        ]
                    )
                ]
            )

        case .ru:
            return GuideContent(
                fileName: "Expert PDF Reader - Руководство по чтению.pdf",
                headerTag: "РУКОВОДСТВО",
                swatchHeader: "Тестовая палитра GPU-шейдеров (Авто / День / Сепия / Ночь)",
                swatchLabels: ["Черный #000", "Темный #333", "Серый #808", "Синий #2FA5FF", "Зеленый #3CC83C", "Янтарь #FFB72B", "Коралл #FA4655"],
                themeCardTitles: ["День Day", "Сепия Sepia", "Ночь Night"],
                themeCardSubtitles: ["Бумага #FFFFFF", "Крем #F5EFDC", "Темная #000000"],
                diagramLabels: ["Одна стр. ⌘1", "Две стр. ⌘2", "Скрыть поля ⇧⌘M"],
                shortcutsTitle: "Основные сочетания клавиш",
                shortcuts: [
                    ("Предыдущая / следующая стр.", "← / →"),
                    ("Открыть файл PDF", "⌘O"),
                    ("Новая вкладка «Главная»", "⌘T"),
                    ("Закрыть текущую вкладку", "⌘W"),
                    ("Показать/скрыть панель", "⌘B"),
                    ("Сетка обзора страниц", "⌃⌘1"),
                    ("Скрыть поля страниц", "⇧⌘M"),
                    ("Масштаб + / - / 100%", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Навигация и закладки",
                navGridItems: [
                    ("Левая боковая панель", "⌘B"),
                    ("Обзор всех страниц", "⌃⌘1"),
                    ("Вкладка «Миниатюры»", "⌃⌘2"),
                    ("Вкладка «Оглавление»", "⌃⌘3"),
                    ("Вкладка «Закладки»", "⌃⌘4"),
                    ("Добавить/удалить закладку", "⌘D")
                ],
                chapterFormat: { idx, title in "Глава \(idx): \(title)" },
                pages: [
                    (
                        title: "Руководство по Expert PDF Reader",
                        subtitle: "Нативное приложение macOS для чтения PDF с GPU-темами",
                        sections: [
                            ("Добро пожаловать в Expert PDF Reader", "Быстрое и четкое чтение PDF на macOS: вкладки документов, главный экран HomeTab, цветовая палитра RDDesignLibrary и GPU-шейдеры RDPDFShaders.metallib."),
                            ("Темы чтения: Как в системе, День, Сепия и Ночь", "В режиме «Как в системе» светлая тема автоматически использует «День» (или «Сепия», если включено), а темная переключается на «Ночь» без потери Retina-четкости.")
                        ]
                    ),
                    (
                        title: "Макет страницы, Разделенный вид и Поля",
                        subtitle: "Одна страница, Две страницы, Обложка, Разделенный вид и Скрытие полей",
                        sections: [
                            ("Режимы макета страницы (⌘1 / ⌘2 / ⌘3)", "Мгновенно переключайтесь между режимами «Одна страница», «Две страницы» и «Две страницы (обложка отдельно)»."),
                            ("Сравнение в разделенном виде (Split View)", "Открывайте вертикальное или горизонтальное разделение экрана для параллельного чтения двух глав или двух разных PDF с синхронной прокруткой."),
                            ("Умное скрытие полей (⇧⌘M)", "Автоматически определяет границы текста на каждой странице и обрезает широкие белые поля.")
                        ]
                    ),
                    (
                        title: "Боковая панель: Миниатюры, Оглавление и Закладки",
                        subtitle: "Быстрый переход к любой главе или отмеченной странице",
                        sections: [
                            ("Миниатюры с активной GPU-темой", "Миниатюры страниц отображаются в реальном времени с выбранным шейдером День, Сепия или Ночь."),
                            ("Иерархическое оглавление (Outline)", "Разворачивайте вложенные разделы оглавления с автоматической подсветкой текущей главы при чтении."),
                            ("Закладки страниц (⌘D)", "Отмечайте важные страницы нажатием ⌘D для быстрого возврата к ним.")
                        ]
                    ),
                    (
                        title: "Полнотекстовый поиск и Навигация с клавиатуры",
                        subtitle: "Контекстные фрагменты по страницам и клавиши со стрелками ← / →",
                        sections: [
                            ("Полнотекстовый поиск (⌘F)", "Нажмите ⌘F для поиска слов по документу, просмотра совпадений с контекстом по страницам и перехода между ними с помощью ⌘G / ⇧⌘G."),
                            ("Переключение страниц стрелками ← / →", "Нажимайте клавиши со стрелками влево (←) и вправо (→) для быстрого перехода к предыдущей или следующей странице.")
                        ]
                    )
                ]
            )

        case .uk:
            return GuideContent(
                fileName: "Expert PDF Reader - Посібник із читання.pdf",
                headerTag: "ПОСІБНИК",
                swatchHeader: "Тестова палітра GPU-шейдерів (Авто / День / Сепія / Ніч)",
                swatchLabels: ["Чорний #000", "Темний #333", "Сірий #808", "Синій #2FA5FF", "Зелений #3CC83C", "Бурштин #FFB72B", "Корал #FA4655"],
                themeCardTitles: ["День Day", "Сепія Sepia", "Ніч Night"],
                themeCardSubtitles: ["Папір #FFFFFF", "Крем #F5EFDC", "Темна #000000"],
                diagramLabels: ["Одна стор. ⌘1", "Дві стор. ⌘2", "Приховати поля ⇧⌘M"],
                shortcutsTitle: "Основні клавіші швидкого доступу",
                shortcuts: [
                    ("Попередня / наступна стор.", "← / →"),
                    ("Відкрити файл PDF", "⌘O"),
                    ("Нова вкладка «Головна»", "⌘T"),
                    ("Закрити поточну вкладку", "⌘W"),
                    ("Показати/приховати панель", "⌘B"),
                    ("Сітка огляду сторінок", "⌃⌘1"),
                    ("Приховати поля сторінок", "⇧⌘M"),
                    ("Масштаб + / - / 100%", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Навігація та закладки",
                navGridItems: [
                    ("Ліва бічна панель", "⌘B"),
                    ("Огляд усіх сторінок", "⌃⌘1"),
                    ("Вкладка «Мініатюри»", "⌃⌘2"),
                    ("Вкладка «Зміст»", "⌃⌘3"),
                    ("Вкладка «Закладки»", "⌃⌘4"),
                    ("Додати/видалити закладку", "⌘D")
                ],
                chapterFormat: { idx, title in "Розділ \(idx): \(title)" },
                pages: [
                    (
                        title: "Посібник із читання Expert PDF Reader",
                        subtitle: "Нативний застосунок macOS для читання PDF із GPU-темами",
                        sections: [
                            ("Ласкаво просимо до Expert PDF Reader", "Швидке й чітке читання PDF на macOS: вкладки документів, головний екран HomeTab, палітра RDDesignLibrary та GPU-шейдери RDPDFShaders.metallib."),
                            ("Теми читання: Як у системі, День, Сепія та Ніч", "У режимі «Як у системі» світла тема автоматично використовує «День» (або «Сепія», якщо ввімкнено), а темна перемикається на «Ніч» зі збереженням повної чіткості Retina.")
                        ]
                    ),
                    (
                        title: "Макет сторінки, Розділений вигляд і Поля",
                        subtitle: "Одна сторінка, Дві сторінки, Обкладинка, Розділений вигляд і Приховування полів",
                        sections: [
                            ("Режими макета сторінки (⌘1 / ⌘2 / ⌘3)", "Миттєво перемикайтеся між режимами «Одна сторінка», «Дві сторінки» та «Дві сторінки (обкладинка окремо)»."),
                            ("Порівняння в розділеному вигляді (Split View)", "Відкривайте вертикальне або горизонтальне розділення екрана для паралельного читання двох розділів або двох PDF із синхронним прокручуванням."),
                            ("Розумне приховування полів (⇧⌘M)", "Автоматично визначає межі тексту на кожній сторінці й обрізає широкі білі поля.")
                        ]
                    ),
                    (
                        title: "Бічна панель: Мініатюри, Зміст і Закладки",
                        subtitle: "Швидкий перехід до будь-якого розділу або закладки",
                        sections: [
                            ("Мініатюри з активною GPU-темою", "Мініатюри сторінок відображаються в реальному часі з вибраним шейдером День, Сепія або Ніч."),
                            ("Ієрархічний зміст (Outline)", "Розгортайте вкладені розділи змісту з автоматичним підсвічуванням поточного розділу під час читання."),
                            ("Закладки сторінок (⌘D)", "Позначайте важливі сторінки натисканням ⌘D для швидкого повернення до них.")
                        ]
                    ),
                    (
                        title: "Повнотекстовий пошук і Навігація з клавіатури",
                        subtitle: "Контекстні фрагменти за сторінками та клавіші зі стрілками ← / →",
                        sections: [
                            ("Повнотекстовий пошук (⌘F)", "Натисніть ⌘F для пошуку слів у документі, перегляду збігів із контекстом за сторінками та переходу між ними за допомогою ⌘G / ⇧⌘G."),
                            ("Перемикання сторінок стрілками ← / →", "Натискайте клавіші зі стрілками ліворуч (←) і праворуч (→) для швидкого переходу до попередньої або наступної сторінки.")
                        ]
                    )
                ]
            )

        default:
            return GuideContent(
                fileName: "Expert PDF Reader - Reading Guide.pdf",
                headerTag: "READING GUIDE",
                swatchHeader: "GPU Shader Test Swatches (Switch Auto / Day / Sepia / Night to observe filter response)",
                swatchLabels: ["Ink #000", "Dark #333", "Gray #808", "Blue #2FA5FF", "Green #3CC83C", "Amber #FFB72B", "Coral #FA4655"],
                themeCardTitles: ["Day Mode", "Sepia Mode", "Night Mode"],
                themeCardSubtitles: ["Paper #FFFFFF", "Cream #F5EFDC", "Dark #000000"],
                diagramLabels: ["Single Page ⌘1", "Two Pages ⌘2", "Clear Margins ⇧⌘M"],
                shortcutsTitle: "Essential Keyboard Shortcuts",
                shortcuts: [
                    ("Previous / Next Page", "← / →"),
                    ("Open PDF File", "⌘O"),
                    ("New Home Tab", "⌘T"),
                    ("Close Active Tab", "⌘W"),
                    ("Toggle Left Sidebar", "⌘B"),
                    ("Page Overview Grid", "⌃⌘1"),
                    ("Clear Page Margins", "⇧⌘M"),
                    ("Zoom In / Out / Actual", "⌘+ / ⌘- / ⌘0")
                ],
                navGridTitle: "Sidebar & Bookmark Shortcuts",
                navGridItems: [
                    ("Show / Hide Left Panel", "⌘B"),
                    ("Open Page Overview Grid", "⌃⌘1"),
                    ("Switch to Thumbnails", "⌃⌘2"),
                    ("Switch to Outline (TOC)", "⌃⌘3"),
                    ("Switch to Bookmarks", "⌃⌘4"),
                    ("Bookmark Current Page", "⌘D")
                ],
                chapterFormat: { idx, title in "Chapter \(idx): \(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader Guide",
                        subtitle: "Native macOS PDF Reader with Real-Time GPU Reading Themes",
                        sections: [
                            ("Welcome to Expert PDF Reader", "Built for a fast, crystal-clear native macOS reading experience—featuring multi-tab navigation, the HomeTab architecture, RDDesignLibrary semantic color tokens, and GPU page shaders from RDPDFShaders.metallib."),
                            ("Four Reading Theme Modes: Follow System, Day, Sepia & Night", "Switch themes anytime from the top toolbar or View Settings panel. When set to Follow System, Light appearance uses Day (or Sepia when 'Use Sepia in Light Mode' is enabled) and Dark appearance automatically switches to Night with full Retina sharpness.")
                        ]
                    ),
                    (
                        title: "Page Layout, Split View & Clear Margins",
                        subtitle: "Single Page, Two Pages, Cover Mode, Split View & Smart Margin Cropping",
                        sections: [
                            ("Page Layout Modes (⌘1 / ⌘2 / ⌘3)", "Seamlessly switch between Single Page continuous scroll, Two Pages side-by-side, and Two Pages with Single Cover for books and magazines."),
                            ("Split View Comparison", "Open Vertical (Left/Right) or Horizontal (Top/Bottom) Split View to read two sections of the same document or compare two different PDFs with optional Sync Scroll & Zoom."),
                            ("Smart Clear Margins (⇧⌘M)", "Automatically detects ink bounding boxes on each page and crops wide white margins to maximize your effective reading area.")
                        ]
                    ),
                    (
                        title: "Sidebar Navigation: Thumbnails, Outline & Bookmarks",
                        subtitle: "Jump to any chapter or bookmarked page effortlessly",
                        sections: [
                            ("Live GPU-Themed Page Thumbnails", "The first sidebar tab renders page thumbnails live with the active Day, Sepia, or Night GPU shader and highlights the current page in signature blue."),
                            ("Hierarchical Table of Contents (Outline)", "Expand or collapse nested chapters while the active section is highlighted automatically as you scroll through the document."),
                            ("Page Bookmarks (⌘D)", "Press ⌘D or click the bookmark button in the toolbar to bookmark any page for instant one-click access.")
                        ]
                    ),
                    (
                        title: "Full-Text Search & Keyboard Navigation",
                        subtitle: "Instant search snippets by page and ← / → arrow key page turning",
                        sections: [
                            ("Instant Full-Text Search (⌘F)", "Press ⌘F to search keywords across the document, view matches grouped by page with highlighted context snippets in the right dock, and step through matches with ⌘G / ⇧⌘G."),
                            ("Left / Right Arrow Key Page Turning", "Press the Left (←) or Right (→) arrow key at any time while reading to step directly to the previous or next page, or click the bottom-right page pill to jump to a specific page number.")
                        ]
                    )
                ]
            )
        }
    }
}
