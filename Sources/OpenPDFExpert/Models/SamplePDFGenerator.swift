import AppKit
import PDFKit

/// Generates a rich multi-page sample PDF ("Getting Started - Open PDF Expert 入门指南.pdf")
/// complete with hierarchical `PDFOutline` (Table of Contents), vector diagrams, color swatches,
/// academic two-column layout, and wide margins for testing Clear Margins, Split View, and Shaders.
public enum SamplePDFGenerator {
    public static func ensureSamplePDFExists() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenPDFExpert", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        let fileURL = supportDir.appendingPathComponent("PDF Expert 阅读指南 (Getting Started).pdf")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        generateSamplePDF(at: fileURL)
        return fileURL
    }

    public static func generateSamplePDF(at url: URL) {
        let pdfDocument = PDFDocument()
        let pageSize = CGSize(width: 612, height: 792) // US Letter

        let pagesContent: [(title: String, subtitle: String, sections: [(heading: String, body: String)], drawColorSwatches: Bool)] = [
            (
                title: "Open PDF Expert 阅读指南",
                subtitle: "基于 morluto/rea 逆向工程还原的 macOS 原生 PDF 阅读器",
                sections: [
                    (
                        heading: "1. 欢迎使用 Open PDF Expert（纯粹阅读版）",
                        body: "本应用基于 Readdle PDF Expert (v3.13.4) 逆向分析构建，移除了复杂的批注、签名与付费墙模块，完整保留了原版丝滑的 PDF 阅读体验、HomeTab 响应式架构、RDDesignLibrary 语义色彩系统，以及原版 RDPDFShaders.metallib 的 GPU 页面滤镜着色器。"
                    ),
                    (
                        heading: "2. 三种阅读主题：日间 (Day) / 纸质 (Sepia) / 夜间 (Night)",
                        body: "点击顶部工具栏中央的「日间 / 纸质 / 夜间」切换器，即可通过 GPU 实时着色器切换页面色彩：\n• 日间模式 (Day)：还原原始白纸黑字 (#FFFFFF 纸张，#DCDCDE / #131314 画布背景)\n• 纸质模式 (Sepia)：源自 sepiaTexturingModeFragmentShader，纸张呈温和暖羊皮纸色 (#F5EFDC)，墨迹呈深棕褐色 (#3F2A18)，画布背景为 #E5DECF\n• 夜间模式 (Night)：源自 nightTexturingModeFragmentShader，采用护眼点积反色算法 v = 0.75 - 0.25*(R+G+B)，纸张为纯黑 (#000000)，文字为柔和浅灰 (#BFBFBF) 避免刺眼眩光，画布背景为 #202223。"
                    )
                ],
                drawColorSwatches: true
            ),
            (
                title: "视图布局与分屏对比",
                subtitle: "单页 / 双页 / 封面模式 / 垂直与水平分屏 / 智能去白边",
                sections: [
                    (
                        heading: "1. 页面显示模式 (Single / Two Pages / Cover)",
                        body: "支持单页连续滚动 (Single Page)、双页并排连续滚动 (Two Pages)，以及适合书籍杂志阅读的「双页（首屏单页封面显示）」模式。可通过顶部「视图设置」弹窗或菜单栏快捷键 (⌘1 / ⌘2 / ⌘3) 一键切换。"
                    ),
                    (
                        heading: "2. 分屏对比视图 (Split View)",
                        body: "参考 PDFDocumentsSplitViewController 设计，支持「左右垂直分屏」与「上下水平分屏」。分屏模式下，你可以在左右两栏同时阅读同一份长文档的不同章节（例如左栏看正文、右栏看参考文献），也可以开启「同步滚动和缩放」或点击「对调位置」。"
                    ),
                    (
                        heading: "3. 清除空白边 (Clear Margins)",
                        body: "针对白边过宽的学术论文（如 LaTeX 默认排版）或扫描版书籍，开启「清除空白边」(⇧⌘M) 后会自动检测每页有效内容的紧致边界框 (CropBox)，最大化有效阅读视野。"
                    )
                ],
                drawColorSwatches: false
            ),
            (
                title: "侧边栏导航：缩略图、目录大纲与书签",
                subtitle: "高效定位长篇 PDF 文档的每一处关键章节",
                sections: [
                    (
                        heading: "1. 实时主题缩略图面板 (Thumbnails)",
                        body: "左侧面板第一栏为「缩略图」，所有页面缩略图均通过 Metal 着色器实时同步当前的日间 / 纸质 / 夜间主题，并以 PDF Expert 标志性的亮蓝色 (#2FA5FF) 描边高亮当前所在页。"
                    ),
                    (
                        heading: "2. 多级目录大纲 (Outline / Table of Contents)",
                        body: "左侧面板第二栏为「大纲」，支持多级章节折叠与展开，显示对应的页码标签，并在滚动阅读时自动高亮当前阅读章节。"
                    ),
                    (
                        heading: "3. 页面书签管理 (Bookmarks)",
                        body: "点击工具栏右侧的书签图标（或按 ⌘D），即可将当前页加入书签。所有书签按规范化文档路径 (symlinkNormalizedURL) 自动持久化保存，支持自定义书签备注名称与快速跳转。"
                    )
                ],
                drawColorSwatches: false
            ),
            (
                title: "全文搜索与快捷键指南",
                subtitle: "即时全文检索、上下文摘要高亮与键盘流操作",
                sections: [
                    (
                        heading: "1. 全文检索 (Full-Text Search)",
                        body: "按下 ⌘F 激活右上角搜索框，输入关键词（例如搜索“着色器”、“Sepia”或“分屏”）即可实时列出所有匹配页面及上下文摘要，并在页面上高亮标记匹配文本，支持 ⌘G / ⇧⌘G 快速跳转上下处匹配。"
                    ),
                    (
                        heading: "2. 常用键盘快捷键一览",
                        body: "• 打开文档：⌘O          • 新建标签页（主页）：⌘T\n• 关闭当前标签页：⌘W    • 切换左侧边栏：⌘B\n• 日间模式：⌃⌘1          • 纸质模式：⌃⌘2          • 夜间模式：⌃⌘3\n• 单页视图：⌘1           • 双页视图：⌘2           • 双页封面：⌘3\n• 清除空白边：⇧⌘M        • 添加/取消书签：⌘D      • 全文查找：⌘F\n• 放大 / 缩小 / 实际大小：⌘+ / ⌘- / ⌘0"
                    )
                ],
                drawColorSwatches: true
            )
        ]

        for (index, content) in pagesContent.enumerated() {
            let data = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                continue
            }

            ctx.beginPDFPage(nil)
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            // White page background
            NSColor.white.setFill()
            NSBezierPath(rect: mediaBox).fill()

            // Header bar accent (with generous outer margin so Clear Margins is clearly visible)
            let marginX: CGFloat = 72
            let contentWidth = pageSize.width - marginX * 2

            let headerRect = CGRect(x: marginX, y: pageSize.height - 110, width: contentWidth, height: 42)
            NSColor(srgbRed: 0.184, green: 0.647, blue: 1.0, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: headerRect, xRadius: 8, yRadius: 8).fill()

            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor(srgbRed: 0.05, green: 0.45, blue: 1.0, alpha: 1.0)
            ]
            NSString(string: "OPEN PDF EXPERT  •  PAGE \(index + 1) OF \(pagesContent.count)")
                .draw(at: CGPoint(x: marginX + 14, y: pageSize.height - 95), withAttributes: badgeAttrs)

            // Title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            NSString(string: content.title)
                .draw(at: CGPoint(x: marginX, y: pageSize.height - 155), withAttributes: titleAttrs)

            // Subtitle
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1.0)
            ]
            NSString(string: content.subtitle)
                .draw(at: CGPoint(x: marginX, y: pageSize.height - 180), withAttributes: subAttrs)

            // Divider line
            NSColor(calibratedWhite: 0.85, alpha: 1.0).setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: marginX, y: pageSize.height - 195))
            line.line(to: CGPoint(x: pageSize.width - marginX, y: pageSize.height - 195))
            line.lineWidth = 1.0
            line.stroke()

            var cursorY: CGFloat = pageSize.height - 230
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 6
            paragraphStyle.paragraphSpacing = 10

            for section in content.sections {
                let hAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1.0)
                ]
                NSString(string: section.heading)
                    .draw(at: CGPoint(x: marginX, y: cursorY), withAttributes: hAttrs)
                cursorY -= 22

                let bAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1.0),
                    .paragraphStyle: paragraphStyle
                ]
                let bStr = NSString(string: section.body)
                let rect = bStr.boundingRect(
                    with: CGSize(width: contentWidth, height: 400),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bAttrs
                )
                bStr.draw(
                    with: CGRect(x: marginX, y: cursorY - rect.height, width: contentWidth, height: rect.height + 10),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bAttrs
                )
                cursorY -= (rect.height + 34)
            }

            if content.drawColorSwatches {
                let boxY = max(110, cursorY - 95)
                let cardRect = CGRect(x: marginX, y: boxY, width: contentWidth, height: 86)
                NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8).fill()

                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1.0)
                ]
                NSString(string: "色彩与灰度着色器测试色卡 (切换日间 / 纸质 / 夜间观察滤镜响应)")
                    .draw(at: CGPoint(x: marginX + 14, y: boxY + 60), withAttributes: labelAttrs)

                let swatches: [(String, NSColor)] = [
                    ("墨黑 #000", NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
                    ("深灰 #333", NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)),
                    ("中灰 #808", NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
                    ("主蓝 #2FA5FF", NSColor(srgbRed: 0.184, green: 0.647, blue: 1.0, alpha: 1)),
                    ("翠绿 #3CC83C", NSColor(srgbRed: 0.235, green: 0.784, blue: 0.235, alpha: 1)),
                    ("琥珀 #FFB72B", NSColor(srgbRed: 1.0, green: 0.718, blue: 0.169, alpha: 1)),
                    ("珊瑚 #FA4655", NSColor(srgbRed: 0.98, green: 0.275, blue: 0.333, alpha: 1))
                ]
                let swatchW: CGFloat = (contentWidth - 28 - CGFloat(swatches.count - 1) * 8) / CGFloat(swatches.count)
                for (sIdx, sw) in swatches.enumerated() {
                    let sx = marginX + 14 + CGFloat(sIdx) * (swatchW + 8)
                    let sRect = CGRect(x: sx, y: boxY + 24, width: swatchW, height: 26)
                    sw.1.setFill()
                    NSBezierPath(roundedRect: sRect, xRadius: 4, yRadius: 4).fill()
                    let sAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
                        .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1.0)
                    ]
                    NSString(string: sw.0).draw(at: CGPoint(x: sx, y: boxY + 8), withAttributes: sAttrs)
                }
            }

            // Footer
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0)
            ]
            NSString(string: "Open PDF Expert • Clean-Room Reader Implementation • Page \(index + 1)")
                .draw(at: CGPoint(x: marginX, y: 68), withAttributes: footerAttrs)

            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()

            if let singleDoc = PDFDocument(data: data as Data),
               let pdfPage = singleDoc.page(at: 0) {
                pdfDocument.insert(pdfPage, at: pdfDocument.pageCount)
            }
        }

        // Build hierarchical PDFOutline (Table of Contents)
        let rootOutline = PDFOutline()
        for (index, content) in pagesContent.enumerated() {
            guard let page = pdfDocument.page(at: index) else { continue }
            let chapterItem = PDFOutline()
            chapterItem.label = "第 \(index + 1) 章：\(content.title)"
            chapterItem.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: pageSize.height))

            for (secIdx, sec) in content.sections.enumerated() {
                let secItem = PDFOutline()
                secItem.label = sec.heading
                let targetY = pageSize.height - CGFloat(220 + secIdx * 140)
                secItem.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: max(100, targetY)))
                chapterItem.insertChild(secItem, at: chapterItem.numberOfChildren)
            }
            rootOutline.insertChild(chapterItem, at: rootOutline.numberOfChildren)
        }
        pdfDocument.outlineRoot = rootOutline
        pdfDocument.write(to: url)
    }
}
