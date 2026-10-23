import AppKit
import PDFKit

/// Generates a localized 4-page Reading Guide PDF ("Expert PDF Reader - <Reading Guide>.pdf")
/// for all 12 supported languages, complete with hierarchical `PDFOutline` (Table of Contents),
/// color swatches, and generous margins for testing Clear Margins, Split View, and GPU Shaders.
public enum SamplePDFGenerator {
    public struct GuideContent {
        public let fileName: String
        public let badgePrefix: String
        public let swatchHeader: String
        public let swatchLabels: [String]
        public let chapterFormat: (Int, String) -> String
        public let pages: [(title: String, subtitle: String, sections: [(heading: String, body: String)], drawColorSwatches: Bool)]
    }

    public static func supportDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ExpertPDFReader", isDirectory: true)
            .appendingPathComponent("Guides_v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func isSampleGuideURL(_ url: URL) -> Bool {
        let path = url.symlinkNormalizedURL.path
        return path.contains("/ExpertPDFReader/Guides_v2/") || path.contains("/OpenPDFExpert/")
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

    public static func generateSamplePDF(at url: URL, guide: GuideContent) {
        let pdfDocument = PDFDocument()
        let pageSize = CGSize(width: 612, height: 792) // US Letter

        for (index, content) in guide.pages.enumerated() {
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
            NSString(string: "\(guide.badgePrefix)  •  \(index + 1) / \(guide.pages.count)")
                .draw(at: CGPoint(x: marginX + 14, y: pageSize.height - 95), withAttributes: badgeAttrs)

            // Title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            NSString(string: content.title)
                .draw(at: CGPoint(x: marginX, y: pageSize.height - 155), withAttributes: titleAttrs)

            // Subtitle
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
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
            paragraphStyle.lineSpacing = 5.5
            paragraphStyle.paragraphSpacing = 9

            for section in content.sections {
                let hAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14.5, weight: .semibold),
                    .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1.0)
                ]
                NSString(string: section.heading)
                    .draw(at: CGPoint(x: marginX, y: cursorY), withAttributes: hAttrs)
                cursorY -= 20

                let bAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1.0),
                    .paragraphStyle: paragraphStyle
                ]
                let bStr = NSString(string: section.body)
                let rect = bStr.boundingRect(
                    with: CGSize(width: contentWidth, height: 420),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bAttrs
                )
                bStr.draw(
                    with: CGRect(x: marginX, y: cursorY - rect.height, width: contentWidth, height: rect.height + 10),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bAttrs
                )
                cursorY -= (rect.height + 30)
            }

            if content.drawColorSwatches {
                let boxY = max(105, cursorY - 92)
                let cardRect = CGRect(x: marginX, y: boxY, width: contentWidth, height: 86)
                NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8).fill()

                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1.0)
                ]
                NSString(string: guide.swatchHeader)
                    .draw(at: CGPoint(x: marginX + 14, y: boxY + 60), withAttributes: labelAttrs)

                let swatchColors: [NSColor] = [
                    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                    NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1),
                    NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                    NSColor(srgbRed: 0.184, green: 0.647, blue: 1.0, alpha: 1),
                    NSColor(srgbRed: 0.235, green: 0.784, blue: 0.235, alpha: 1),
                    NSColor(srgbRed: 1.0, green: 0.718, blue: 0.169, alpha: 1),
                    NSColor(srgbRed: 0.98, green: 0.275, blue: 0.333, alpha: 1)
                ]
                let swatchW: CGFloat = (contentWidth - 28 - CGFloat(swatchColors.count - 1) * 8) / CGFloat(swatchColors.count)
                for (sIdx, color) in swatchColors.enumerated() {
                    let sx = marginX + 14 + CGFloat(sIdx) * (swatchW + 8)
                    let sRect = CGRect(x: sx, y: boxY + 24, width: swatchW, height: 26)
                    color.setFill()
                    NSBezierPath(roundedRect: sRect, xRadius: 4, yRadius: 4).fill()
                    let sAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
                        .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1.0)
                    ]
                    let label = sIdx < guide.swatchLabels.count ? guide.swatchLabels[sIdx] : ""
                    NSString(string: label).draw(at: CGPoint(x: sx, y: boxY + 8), withAttributes: sAttrs)
                }
            }

            // Footer
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0)
            ]
            NSString(string: "Expert PDF Reader  •  \(index + 1) / \(guide.pages.count)")
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
        for (index, content) in guide.pages.enumerated() {
            guard let page = pdfDocument.page(at: index) else { continue }
            let chapterItem = PDFOutline()
            chapterItem.label = guide.chapterFormat(index + 1, content.title)
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

    // MARK: - Localized Guide Content for All 12 Languages

    public static func guideContent(for lang: AppLanguage) -> GuideContent {
        switch lang {
        case .zhHans:
            return GuideContent(
                fileName: "Expert PDF Reader - 阅读指南.pdf",
                badgePrefix: "EXPERT PDF READER  •  阅读指南",
                swatchHeader: "GPU 着色器测试色卡（切换 跟随系统 / 日间 / 纸质 / 夜间 观察色彩响应）",
                swatchLabels: ["墨黑 #000", "深灰 #333", "中灰 #808", "主蓝 #2FA5FF", "翠绿 #3CC83C", "琥珀 #FFB72B", "珊瑚 #FA4655"],
                chapterFormat: { idx, title in "第 \(idx) 章：\(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 阅读指南",
                        subtitle: "原生 macOS 高清 PDF 阅读器与 GPU 实时阅读主题",
                        sections: [
                            ("1. 欢迎使用 Expert PDF Reader", "本应用专注纯粹、丝滑的 macOS PDF 阅读体验，去除冗余批注与付费墙模块，完整保留多标签页、HomeTab 主页架构、RDDesignLibrary 语义色彩系统与原版 RDPDFShaders.metallib 的 GPU 页面着色器。"),
                            ("2. 阅读主题：跟随系统 / 日间 / 纸质 / 夜间", "点击顶部工具栏中央的主题图标或在「显示选项」中切换：\n• 跟随系统：浅色外观下默认使用日间（可开启“浅色时使用纸质替代日间”），深色外观下自动切换为夜间模式\n• 日间 (Day)：还原白纸黑字 (#FFFFFF 纸张)\n• 纸质 (Sepia)：暖羊皮纸底色 (#F5EFDC) 与深棕墨迹 (#3F2A18)\n• 夜间 (Night)：纯黑背景 (#000000) 与柔和浅灰文字 (#BFBFBF) 防眩光。")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "视图布局、分屏对比与去白边",
                        subtitle: "单页 / 双页 / 封面模式 / 垂直与水平分屏 / 智能清除空白边",
                        sections: [
                            ("1. 页面布局模式 (Single / Two Pages / Cover)", "支持单页连续滚动、双页并排滚动，以及适合书籍杂志的「双页（首屏单页封面显示）」模式，可通过快捷键 ⌘1 / ⌘2 / ⌘3 快速切换。"),
                            ("2. 分屏对比视图 (Split View)", "支持左右垂直分屏与上下水平分屏。可在左右两栏同时对比阅读同一文档的不同章节或另一份 PDF，并支持「同步滚动和缩放」与「对调位置」。"),
                            ("3. 智能清除空白边 (Clear Margins, ⇧⌘M)", "自动识别每页正文墨迹边界并裁切多余白边，显著放大论文与扫描版书籍的有效阅读区域。")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "侧边栏导航：缩略图、大纲与书签",
                        subtitle: "高效定位长篇 PDF 文档的每一处关键章节",
                        sections: [
                            ("1. 实时主题缩略图 (Thumbnails)", "左侧面板第一栏展示实时同步当前 GPU 阅读主题的页面缩略图，并以亮蓝色边框高亮当前阅读页。"),
                            ("2. 多级目录大纲 (Outline)", "左侧面板第二栏支持多级目录折叠与展开，并在滚动阅读时自动高亮当前所在章节。"),
                            ("3. 页面书签 (Bookmarks, ⌘D)", "按 ⌘D 或点击工具栏书签按钮即可标记当前页，支持右键跳转与管理。")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "全文搜索与键盘快捷键",
                        subtitle: "即时全文检索、左右方向键翻页与键盘流操作",
                        sections: [
                            ("1. 全文搜索 (⌘F)", "按 ⌘F 激活工具栏搜索框，输入关键词即可按页列出上下文摘要并高亮匹配文本，按 ⌘G / ⇧⌘G 快速跳转。"),
                            ("2. 常用快捷键一览", "• 上一页 / 下一页：← / →（或 ⌥↑ / ⌥↓）\n• 打开文件：⌘O      • 新建主页标签：⌘T      • 关闭标签：⌘W\n• 左侧面板：⌘B      • 页面概览：⌃⌘1         • 清除空白边：⇧⌘M\n• 单页 / 双页 / 封面：⌘1 / ⌘2 / ⌘3          • 放大 / 缩小 / 实际大小：⌘+ / ⌘- / ⌘0")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .zhHant:
            return GuideContent(
                fileName: "Expert PDF Reader - 閱讀指南.pdf",
                badgePrefix: "EXPERT PDF READER  •  閱讀指南",
                swatchHeader: "GPU 著色器測試色卡（切換 跟隨系統 / 日間 / 紙質 / 夜間 觀察色彩響應）",
                swatchLabels: ["墨黑 #000", "深灰 #333", "中灰 #808", "主藍 #2FA5FF", "翠綠 #3CC83C", "琥珀 #FFB72B", "珊瑚 #FA4655"],
                chapterFormat: { idx, title in "第 \(idx) 章：\(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 閱讀指南",
                        subtitle: "原生 macOS 高清 PDF 閱讀器與 GPU 即時閱讀主題",
                        sections: [
                            ("1. 歡迎使用 Expert PDF Reader", "本應用專注純粹、流暢的 macOS PDF 閱讀體驗，移除冗餘批註與付費牆模組，完整保留多分頁、HomeTab 首頁架構、RDDesignLibrary 語義色彩系統與原版 RDPDFShaders.metallib 的 GPU 頁面著色器。"),
                            ("2. 閱讀主題：跟隨系統 / 日間 / 紙質 / 夜間", "點按頂部工具列中央的主題圖示或在「顯示選項」中切換：\n• 跟隨系統：淺色外觀下預設使用日間（可開啟「淺色時使用紙質替代日間」），深色外觀下自動切換為夜間模式\n• 日間 (Day)：還原白紙黑字 (#FFFFFF 紙張)\n• 紙質 (Sepia)：暖羊皮紙底色 (#F5EFDC) 與深棕墨跡 (#3F2A18)\n• 夜間 (Night)：純黑背景 (#000000) 與柔和淺灰文字 (#BFBFBF) 防眩光。")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "視圖佈局、分割對比與去留白",
                        subtitle: "單頁 / 雙頁 / 封面模式 / 垂直與水平分割 / 智慧清除留白",
                        sections: [
                            ("1. 頁面佈局模式 (Single / Two Pages / Cover)", "支援單頁連續捲動、雙頁並排捲動，以及適合書籍雜誌的「雙頁（首屏單頁封面顯示）」模式，可透過快捷鍵 ⌘1 / ⌘2 / ⌘3 快速切換。"),
                            ("2. 分割對比視圖 (Split View)", "支援左右垂直分割與上下水平分割。可在兩欄同時對比閱讀同一文件的不同章節或另一份 PDF，並支援「同步捲動與縮放」與「對調位置」。"),
                            ("3. 智慧清除留白 (Clear Margins, ⇧⌘M)", "自動識別每頁正文邊界並裁切多餘留白，顯著放大論文與掃描版書籍的有效閱讀區域。")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "側邊欄導覽：縮圖、大綱與書籤",
                        subtitle: "高效定位長篇 PDF 文件的每一處關鍵章節",
                        sections: [
                            ("1. 即時主題縮圖 (Thumbnails)", "左側面板第一欄展示即時同步目前 GPU 閱讀主題的頁面縮圖，並以亮藍色邊框醒目顯示目前閱讀頁。"),
                            ("2. 多層級目錄大綱 (Outline)", "左側面板第二欄支援多層級目錄摺疊與展開，並在捲動閱讀時自動醒目顯示目前所在章節。"),
                            ("3. 頁面書籤 (Bookmarks, ⌘D)", "按 ⌘D 或點按工具列書籤按鈕即可標記目前頁面，支援右鍵跳轉與管理。")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "全文搜尋與鍵盤快捷鍵",
                        subtitle: "即時全文檢索、左右方向鍵翻頁與鍵盤流操作",
                        sections: [
                            ("1. 全文搜尋 (⌘F)", "按 ⌘F 啟用工具列搜尋框，輸入關鍵字即可按頁列出上下文摘要並醒目顯示符合文字，按 ⌘G / ⇧⌘G 快速跳轉。"),
                            ("2. 常用快捷鍵一覽", "• 上一頁 / 下一頁：← / →（或 ⌥↑ / ⌥↓）\n• 打開檔案：⌘O      • 新增首頁分頁：⌘T      • 關閉分頁：⌘W\n• 左側面板：⌘B      • 頁面概覽：⌃⌘1         • 清除留白：⇧⌘M\n• 單頁 / 雙頁 / 封面：⌘1 / ⌘2 / ⌘3          • 放大 / 縮小 / 實際大小：⌘+ / ⌘- / ⌘0")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .ja:
            return GuideContent(
                fileName: "Expert PDF Reader - 読書ガイド.pdf",
                badgePrefix: "EXPERT PDF READER  •  読書ガイド",
                swatchHeader: "GPU シェーダーテストカラー（自動 / 昼 / セピア / 夜 を切り替えて確認）",
                swatchLabels: ["黒 #000", "濃灰 #333", "中灰 #808", "青 #2FA5FF", "緑 #3CC83C", "黄 #FFB72B", "赤 #FA4655"],
                chapterFormat: { idx, title in "第\(idx)章：\(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 読書ガイド",
                        subtitle: "macOS ネイティブ PDF リーダー＆ GPU リアルタイム読書テーマ",
                        sections: [
                            ("1. Expert PDF Reader へようこそ", "不要な編集機能や課金ウォールを省き、快適で鮮明な PDF 読書体験に特化した macOS ネイティブアプリです。マルチタブ、HomeTab、RDDesignLibrary カラートークン、RDPDFShaders.metallib による GPU シェーダーを搭載しています。"),
                            ("2. 読書テーマ：システムに合わせる / 昼 / セピア / 夜", "ツールバー中央または「表示設定」から切り替え可能です：\n• システムに合わせる：ライト時は昼（または「ライト時にセピアを使用」オンでセピア）、ダーク時は夜に自動切替\n• 昼 (Day)：本来の白紙と黒文字 (#FFFFFF)\n• セピア (Sepia)：温かみのある羊皮紙色 (#F5EFDC) とエスプレッソインク (#3F2A18)\n• 夜 (Night)：純黒背景 (#000000) と目に優しいシルバーグレー文字 (#BFBFBF)。")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "ページレイアウト・分割表示・余白トリミング",
                        subtitle: "単一ページ / 見開き / 表紙モード / 左右・上下分割 / 余白をトリミング",
                        sections: [
                            ("1. ページレイアウト (⌘1 / ⌘2 / ⌘3)", "単一ページ、見開き（2ページ）、見開き（表紙を単独表示）をワンクリックまたはショートカットで切り替えられます。"),
                            ("2. 分割表示 (Split View)", "左右または上下に画面を分割し、同じ書類の別章や別の PDF 書類を並べて比較できます。同期スクロールや位置の入れ替えにも対応しています。"),
                            ("3. 余白をトリミング (⇧⌘M)", "学術論文やスキャン書籍の広い余白を自動検出し、本文領域に合わせてページ余白をトリミングします。")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "サイドバー：サムネイル・アウトライン・ブックマーク",
                        subtitle: "長文の PDF 書類でも素早く目的の章やページへ移動",
                        sections: [
                            ("1. テーマ対応サムネイル (Thumbnails)", "現在の GPU 読書テーマがリアルタイムに反映されるページサムネイルを表示します。"),
                            ("2. 階層アウトライン (Outline)", "目次ツリーを展開・折りたたみでき、読んでいるセクションが自動的にハイライトされます。"),
                            ("3. ブックマーク (Bookmarks, ⌘D)", "⌘D またはツールバーのブックマークアイコンで現在のページを保存し、いつでもジャンプできます。")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "全文検索とキーボードショートカット",
                        subtitle: "高速テキスト検索と ← / → キーによるページめくり",
                        sections: [
                            ("1. 全文検索 (⌘F)", "⌘F で検索欄にフォーカスし、キーワードを入力するとページ順で前後の文脈付き結果が表示されます。"),
                            ("2. 主なショートカット", "• 前のページ / 次のページ：← / →（または ⌥↑ / ⌥↓）\n• ファイルを開く：⌘O  • 新規ホームタブ：⌘T  • タブを閉じる：⌘W\n• 左パネル：⌘B        • ページ一覧：⌃⌘1     • 余白トリミング：⇧⌘M\n• 拡大 / 縮小 / 実際のサイズ：⌘+ / ⌘- / ⌘0")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .ko:
            return GuideContent(
                fileName: "Expert PDF Reader - 읽기 가이드.pdf",
                badgePrefix: "EXPERT PDF READER  •  읽기 가이드",
                swatchHeader: "GPU 셰이더 색상 테스트 (자동 / 주간 / 세피아 / 야간 전환 시 반응 확인)",
                swatchLabels: ["블랙 #000", "다크 #333", "그레이 #808", "블루 #2FA5FF", "그린 #3CC83C", "앰버 #FFB72B", "코랄 #FA4655"],
                chapterFormat: { idx, title in "제\(idx)장: \(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader 읽기 가이드",
                        subtitle: "macOS 네이티브 고화질 PDF 리더 및 실시간 GPU 읽기 테마",
                        sections: [
                            ("1. Expert PDF Reader에 오신 것을 환영합니다", "불필요한 편집 기능 없이 빠르고 선명한 PDF 읽기에 집중한 macOS 네이티브 앱입니다. 멀티 탭, HomeTab 아키텍처, RDDesignLibrary 색상 시스템 및 RDPDFShaders.metallib GPU 셰이더를 제공합니다."),
                            ("2. 읽기 테마: 시스템 설정 따르기 / 주간 / 세피아 / 야간", "도구 모음 중앙 또는 '보기 옵션'에서 전환할 수 있습니다:\n• 시스템 설정 따르기: 라이트 모드에서 주간('라이트 모드에서 세피아 사용' 켜기 시 세피아), 다크 모드에서 야간 테마로 자동 전환\n• 주간 (Day): 원본 흰 종이와 검은 텍스트 (#FFFFFF)\n• 세피아 (Sepia): 따뜻한 양피지 배경 (#F5EFDC)과 에스프레소 잉크 (#3F2A18)\n• 야간 (Night): 순수 블랙 배경 (#000000)과 눈부심을 줄인 실버 텍스트 (#BFBFBF).")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "페이지 레이아웃, 분할 보기 및 여백 제거",
                        subtitle: "단일 / 두 페이지 / 표지 모드 / 수직·수평 분할 / 여백 자동 제거",
                        sections: [
                            ("1. 페이지 레이아웃 (⌘1 / ⌘2 / ⌘3)", "단일 페이지, 두 페이지, 두 페이지(표지 단독 표시) 모드를 단축키로 즉시 전환할 수 있습니다."),
                            ("2. 분할 보기 (Split View)", "좌/우 수직 분할 또는 상/하 수평 분할로 같은 문서의 다른 장이나 다른 PDF 문서를 나란히 비교할 수 있습니다."),
                            ("3. 여백 제거 (⇧⌘M)", "논문이나 스캔 문서의 넓은 여백을 자동으로 감지하여 본문 영역에 맞게 여백을 제거합니다.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "사이드바 탐색: 축소판, 개요 및 책갈피",
                        subtitle: "긴 PDF 문서의 원하는 위치를 빠르게 탐색",
                        sections: [
                            ("1. 실시간 테마 축소판 (Thumbnails)", "현재 적용된 GPU 읽기 테마가 반영된 페이지 축소판을 표시합니다."),
                            ("2. 다단계 개요 (Outline)", "목차 트리를 접거나 펼칠 수 있으며 현재 읽고 있는 섹션이 자동으로 강조됩니다."),
                            ("3. 페이지 책갈피 (Bookmarks, ⌘D)", "⌘D를 눌러 현재 페이지를 책갈피에 추가하고 빠르게 이동할 수 있습니다.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "전체 텍스트 검색 및 단축키",
                        subtitle: "실시간 검색 결과 하이라이트 및 ← / → 페이지 이동",
                        sections: [
                            ("1. 전체 텍스트 검색 (⌘F)", "⌘F를 눌러 키워드를 입력하면 페이지별 문맥 요약과 함께 일치하는 텍스트가 강조 표시됩니다."),
                            ("2. 주요 키보드 단축키", "• 이전 / 다음 페이지: ← / → (또는 ⌥↑ / ⌥↓)\n• 파일 열기: ⌘O      • 새 홈 탭: ⌘T        • 탭 닫기: ⌘W\n• 왼쪽 패널: ⌘B      • 페이지 개요: ⌃⌘1     • 여백 제거: ⇧⌘M\n• 확대 / 축소 / 실제 크기: ⌘+ / ⌘- / ⌘0")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .fr:
            return GuideContent(
                fileName: "Expert PDF Reader - Guide de lecture.pdf",
                badgePrefix: "EXPERT PDF READER  •  GUIDE DE LECTURE",
                swatchHeader: "Nuancier de test des shaders GPU (Auto / Jour / Sépia / Nuit)",
                swatchLabels: ["Noir #000", "Gris #333", "Moyen #808", "Bleu #2FA5FF", "Vert #3CC83C", "Ambre #FFB72B", "Corail #FA4655"],
                chapterFormat: { idx, title in "Chapitre \(idx) : \(title)" },
                pages: [
                    (
                        title: "Guide de lecture Expert PDF Reader",
                        subtitle: "Lecteur PDF macOS natif avec thèmes GPU temps réel",
                        sections: [
                            ("1. Bienvenue dans Expert PDF Reader", "Conçu pour une lecture PDF fluide et nette sur macOS, avec onglets multiples, écran d’accueil HomeTab, palette RDDesignLibrary et shaders GPU RDPDFShaders.metallib."),
                            ("2. Thèmes de lecture : Suivre le système / Jour / Sépia / Nuit", "• Suivre le système : bascule automatiquement entre le mode clair (Jour ou Sépia) et le mode sombre (Nuit)\n• Jour : papier blanc (#FFFFFF) et texte net\n• Sépia : papier crème chaud (#F5EFDC) et encre expresso (#3F2A18)\n• Nuit : fond noir (#000000) et texte argenté doux (#BFBFBF) sans éblouissement.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Mise en page, Vue fractionnée et Marges",
                        subtitle: "Page simple / Deux pages / Couverture / Vue fractionnée / Rogner les marges",
                        sections: [
                            ("1. Modes de mise en page (⌘1 / ⌘2 / ⌘3)", "Passez instantanément entre Page simple, Deux pages et Deux pages avec couverture seule."),
                            ("2. Vue fractionnée (Split View)", "Comparez deux sections d’un même PDF ou deux documents côte à côte (vertical ou horizontal) avec défilement synchronisé."),
                            ("3. Rogner les marges (⇧⌘M)", "Détecte automatiquement les bordures du texte pour supprimer les marges blanches excessives.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Navigation : Vignettes, Plan et Signets",
                        subtitle: "Repérez rapidement chaque chapitre de vos documents",
                        sections: [
                            ("1. Vignettes thématiques (Thumbnails)", "Aperçus de pages rendus avec le thème GPU actif."),
                            ("2. Plan hiérarchique (Outline)", "Table des matières pliable mettant en évidence la section en cours de lecture."),
                            ("3. Signets de page (Bookmarks, ⌘D)", "Marquez n’importe quelle page avec ⌘D pour y revenir en un clic.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Recherche plein texte et Raccourcis",
                        subtitle: "Recherche instantanée et navigation ← / → entre les pages",
                        sections: [
                            ("1. Recherche plein texte (⌘F)", "Appuyez sur ⌘F pour rechercher un mot-clé et parcourir les extraits par page avec ⌘G / ⇧⌘G."),
                            ("2. Raccourcis clavier essentiels", "• Page précédente / suivante : ← / → (ou ⌥↑ / ⌥↓)\n• Ouvrir : ⌘O   • Nouvel onglet : ⌘T   • Fermer l’onglet : ⌘W\n• Panneau gauche : ⌘B   • Aperçu des pages : ⌃⌘1   • Marges : ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .de:
            return GuideContent(
                fileName: "Expert PDF Reader - Lesehandbuch.pdf",
                badgePrefix: "EXPERT PDF READER  •  LESEHANDBUCH",
                swatchHeader: "GPU-Shader-Farbtest (System / Tag / Sepia / Nacht umschalten)",
                swatchLabels: ["Schwarz #000", "Dunkel #333", "Grau #808", "Blau #2FA5FF", "Grün #3CC83C", "Bernstein #FFB72B", "Koralle #FA4655"],
                chapterFormat: { idx, title in "Kapitel \(idx): \(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader Lesehandbuch",
                        subtitle: "Nativer macOS-PDF-Reader mit Echtzeit-GPU-Lesethemen",
                        sections: [
                            ("1. Willkommen bei Expert PDF Reader", "Entwickelt für ein schnelles, gestochen scharfes PDF-Leseerlebnis unter macOS – mit Multi-Tab-Leiste, HomeTab, RDDesignLibrary-Farbsystem und RDPDFShaders.metallib GPU-Shadern."),
                            ("2. Lesethemen: System folgen / Tag / Sepia / Nacht", "• System folgen: Wechselt automatisch zwischen hellem Modus (Tag oder optional Sepia) und dunklem Modus (Nacht)\n• Tag: Klassisches weißes Papier (#FFFFFF)\n• Sepia: Warmes Pergamentpapier (#F5EFDC) mit Espresso-Tinte (#3F2A18)\n• Nacht: Tiefschwarzer Hintergrund (#000000) und blendfreier silbergrauer Text (#BFBFBF).")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Seitenlayout, Geteilte Ansicht & Seitenränder",
                        subtitle: "Einzelseite / Zwei Seiten / Deckblatt / Geteilte Ansicht / Ränder ausblenden",
                        sections: [
                            ("1. Seitenlayout (⌘1 / ⌘2 / ⌘3)", "Wechseln Sie nahtlos zwischen Einzelseite, Zwei Seiten und Zwei Seiten mit einzelnem Deckblatt."),
                            ("2. Geteilte Ansicht (Split View)", "Vergleichen Sie zwei Abschnitte oder zwei PDF-Dokumente nebeneinander (vertikal oder horizontal) inklusive synchronem Scrollen."),
                            ("3. Seitenränder ausblenden (⇧⌘M)", "Erkennt automatisch die Textgrenzen und schneidet breite weiße Ränder ab.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Seitenleiste: Miniaturen, Gliederung & Lesezeichen",
                        subtitle: "Schnelle Orientierung in umfangreichen PDF-Dokumenten",
                        sections: [
                            ("1. Miniaturen (Thumbnails)", "Seitenminiaturen werden live mit dem aktiven GPU-Lesethema gerendert."),
                            ("2. Gliederung (Outline)", "Ausklappbares Inhaltsverzeichnis mit automatischer Hervorhebung des aktuellen Kapitels."),
                            ("3. Lesezeichen (Bookmarks, ⌘D)", "Setzen Sie mit ⌘D Lesezeichen für wichtige Seiten.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Volltextsuche & Tastaturkurzbefehle",
                        subtitle: "Sofortsuche und Seitenwechsel mit den Pfeiltasten ← / →",
                        sections: [
                            ("1. Volltextsuche (⌘F)", "Drücken Sie ⌘F, um im gesamten Dokument nach Begriffen zu suchen und Treffer mit ⌘G / ⇧⌘G durchzugehen."),
                            ("2. Wichtige Kurzbefehle", "• Vorherige / Nächste Seite: ← / → (oder ⌥↑ / ⌥↓)\n• Öffnen: ⌘O   • Neuer Tab: ⌘T   • Tab schließen: ⌘W\n• Seitenleiste: ⌘B   • Seitenübersicht: ⌃⌘1   • Ränder: ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .es:
            return GuideContent(
                fileName: "Expert PDF Reader - Guía de lectura.pdf",
                badgePrefix: "EXPERT PDF READER  •  GUÍA DE LECTURA",
                swatchHeader: "Muestra de prueba de shaders GPU (Auto / Día / Sepia / Noche)",
                swatchLabels: ["Negro #000", "Oscuro #333", "Gris #808", "Azul #2FA5FF", "Verde #3CC83C", "Ámbar #FFB72B", "Coral #FA4655"],
                chapterFormat: { idx, title in "Capítulo \(idx): \(title)" },
                pages: [
                    (
                        title: "Guía de lectura de Expert PDF Reader",
                        subtitle: "Lector PDF nativo para macOS con temas GPU en tiempo real",
                        sections: [
                            ("1. Bienvenido a Expert PDF Reader", "Diseñado para ofrecer una lectura de PDF rápida y nítida en macOS, con pestañas múltiples, pantalla de inicio HomeTab y sombreadores GPU RDPDFShaders.metallib."),
                            ("2. Temas de lectura: Seguir al sistema / Día / Sepia / Noche", "• Seguir al sistema: cambia automáticamente entre el modo claro (Día o Sepia) y el modo oscuro (Noche)\n• Día: papel blanco original (#FFFFFF)\n• Sepia: papel crema cálido (#F5EFDC) y tinta expreso (#3F2A18)\n• Noche: fondo negro (#000000) y texto gris suave (#BFBFBF) sin deslumbramiento.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Diseño de página, Vista dividida y Márgenes",
                        subtitle: "Página individual / Dos páginas / Portada / Vista dividida / Recortar márgenes",
                        sections: [
                            ("1. Diseño de página (⌘1 / ⌘2 / ⌘3)", "Alterne entre Página individual, Dos páginas y Dos páginas con portada individual."),
                            ("2. Vista dividida (Split View)", "Compare dos secciones o dos documentos PDF en paralelo (vertical u horizontal) con desplazamiento sincronizado."),
                            ("3. Recortar márgenes (⇧⌘M)", "Detecta automáticamente los bordes del contenido y recorta los márgenes en blanco.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Barra lateral: Miniaturas, Esquema y Marcadores",
                        subtitle: "Navegue rápidamente por documentos PDF extensos",
                        sections: [
                            ("1. Miniaturas (Thumbnails)", "Miniaturas de página renderizadas con el tema GPU activo."),
                            ("2. Esquema (Outline)", "Tabla de contenido jerárquica que resalta el capítulo actual."),
                            ("3. Marcadores (Bookmarks, ⌘D)", "Marque cualquier página con ⌘D para volver a ella rápidamente.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Búsqueda de texto y Atajos de teclado",
                        subtitle: "Búsqueda instantánea y navegación con teclas ← / →",
                        sections: [
                            ("1. Búsqueda de texto completo (⌘F)", "Pulse ⌘F para buscar palabras clave por página con fragmentos resaltados."),
                            ("2. Atajos principales", "• Página anterior / siguiente: ← / → (o ⌥↑ / ⌥↓)\n• Abrir: ⌘O   • Nueva pestaña: ⌘T   • Cerrar pestaña: ⌘W\n• Panel izquierdo: ⌘B   • Vista general: ⌃⌘1   • Márgenes: ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .it:
            return GuideContent(
                fileName: "Expert PDF Reader - Guida alla lettura.pdf",
                badgePrefix: "EXPERT PDF READER  •  GUIDA ALLA LETTURA",
                swatchHeader: "Campioni di test shader GPU (Auto / Giorno / Seppia / Notte)",
                swatchLabels: ["Nero #000", "Scuro #333", "Grigio #808", "Blu #2FA5FF", "Verde #3CC83C", "Ambra #FFB72B", "Corallo #FA4655"],
                chapterFormat: { idx, title in "Capitolo \(idx): \(title)" },
                pages: [
                    (
                        title: "Guida alla lettura di Expert PDF Reader",
                        subtitle: "Lettore PDF nativo per macOS con temi GPU in tempo reale",
                        sections: [
                            ("1. Benvenuto in Expert PDF Reader", "Progettato per una lettura PDF fluida e nitida su macOS, con schede multiple, HomeTab e shader GPU RDPDFShaders.metallib."),
                            ("2. Temi di lettura: Segui il sistema / Giorno / Seppia / Notte", "• Segui il sistema: passa automaticamente tra modalità chiara (Giorno o Seppia) e modalità scura (Notte)\n• Giorno: carta bianca originale (#FFFFFF)\n• Seppia: carta crema calda (#F5EFDC) e inchiostro caffè (#3F2A18)\n• Notte: sfondo nero (#000000) e testo grigio argento (#BFBFBF) antiriflesso.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Layout pagina, Vista divisa e Margini",
                        subtitle: "Pagina singola / Due pagine / Copertina / Vista divisa / Ritaglia margini",
                        sections: [
                            ("1. Layout pagina (⌘1 / ⌘2 / ⌘3)", "Passa rapidamente tra Pagina singola, Due pagine e Due pagine con copertina singola."),
                            ("2. Vista divisa (Split View)", "Confronta due sezioni o due documenti PDF affiancati con scorrimento sincronizzato."),
                            ("3. Ritaglia margini (⇧⌘M)", "Rileva automaticamente i bordi del testo per ritagliare i margini bianchi.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Barra laterale: Miniature, Struttura e Segnalibri",
                        subtitle: "Esplora rapidamente documenti PDF lunghi",
                        sections: [
                            ("1. Miniature (Thumbnails)", "Miniature delle pagine sincronizzate con il tema GPU attivo."),
                            ("2. Struttura (Outline)", "Indice gerarchico con evidenziazione automatica del capitolo corrente."),
                            ("3. Segnalibri (Bookmarks, ⌘D)", "Aggiungi segnalibri alle pagine importanti con ⌘D.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Ricerca nel testo e Scorciatoie",
                        subtitle: "Ricerca istantanea e cambio pagina con i tasti ← / →",
                        sections: [
                            ("1. Ricerca nel testo (⌘F)", "Premi ⌘F per cercare parole chiave ed esplorare i risultati per pagina."),
                            ("2. Scorciatoie principali", "• Pagina precedente / successiva: ← / → (o ⌥↑ / ⌥↓)\n• Apri: ⌘O   • Nuova scheda: ⌘T   • Chiudi scheda: ⌘W\n• Pannello sinistro: ⌘B   • Panoramica pagine: ⌃⌘1   • Margini: ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .pt:
            return GuideContent(
                fileName: "Expert PDF Reader - Guia de leitura.pdf",
                badgePrefix: "EXPERT PDF READER  •  GUIA DE LEITURA",
                swatchHeader: "Amostras de teste de shaders GPU (Auto / Dia / Sépia / Noite)",
                swatchLabels: ["Preto #000", "Escuro #333", "Cinza #808", "Azul #2FA5FF", "Verde #3CC83C", "Âmbar #FFB72B", "Coral #FA4655"],
                chapterFormat: { idx, title in "Capítulo \(idx): \(title)" },
                pages: [
                    (
                        title: "Guia de leitura do Expert PDF Reader",
                        subtitle: "Leitor de PDF nativo para macOS com temas de GPU em tempo real",
                        sections: [
                            ("1. Bem-vindo ao Expert PDF Reader", "Criado para uma leitura de PDF rápida e nítida no macOS, com várias abas, tela inicial HomeTab e shaders de GPU RDPDFShaders.metallib."),
                            ("2. Temas de leitura: Seguir o sistema / Dia / Sépia / Noite", "• Seguir o sistema: alterna automaticamente entre o modo claro (Dia ou Sépia) e o modo escuro (Noite)\n• Dia: papel branco original (#FFFFFF)\n• Sépia: papel creme quente (#F5EFDC) e tinta expresso (#3F2A18)\n• Noite: fundo preto (#000000) e texto cinza suave (#BFBFBF) sem brilho excessivo.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Layout da página, Visualização dividida e Margens",
                        subtitle: "Página única / Duas páginas / Capa / Visualização dividida / Cortar margens",
                        sections: [
                            ("1. Layout da página (⌘1 / ⌘2 / ⌘3)", "Alterne entre Página única, Duas páginas e Duas páginas com capa única."),
                            ("2. Visualização dividida (Split View)", "Compare duas seções ou dois documentos PDF lado a lado com rolagem sincronizada."),
                            ("3. Cortar margens (⇧⌘M)", "Detecta automaticamente os limites do conteúdo e corta margens em branco.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Barra lateral: Miniaturas, Sumário e Marcadores",
                        subtitle: "Navegue rapidamente por documentos PDF longos",
                        sections: [
                            ("1. Miniaturas (Thumbnails)", "Miniaturas de página renderizadas com o tema de GPU ativo."),
                            ("2. Sumário (Outline)", "Sumário hierárquico que destaca automaticamente o capítulo atual."),
                            ("3. Marcadores (Bookmarks, ⌘D)", "Adicione marcadores a qualquer página pressionando ⌘D.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Pesquisa de texto e Atalhos de teclado",
                        subtitle: "Pesquisa instantânea e navegação com as setas ← / →",
                        sections: [
                            ("1. Pesquisa de texto completo (⌘F)", "Pressione ⌘F para pesquisar palavras-chave e navegar pelos resultados por página."),
                            ("2. Principais atalhos", "• Página anterior / seguinte: ← / → (ou ⌥↑ / ⌥↓)\n• Abrir: ⌘O   • Nova aba: ⌘T   • Fechar aba: ⌘W\n• Painel esquerdo: ⌘B   • Visão geral: ⌃⌘1   • Margens: ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .ru:
            return GuideContent(
                fileName: "Expert PDF Reader - Руководство по чтению.pdf",
                badgePrefix: "EXPERT PDF READER  •  РУКОВОДСТВО",
                swatchHeader: "Тестовая палитра GPU-шейдеров (Авто / День / Сепия / Ночь)",
                swatchLabels: ["Черный #000", "Темный #333", "Серый #808", "Синий #2FA5FF", "Зеленый #3CC83C", "Янтарь #FFB72B", "Коралл #FA4655"],
                chapterFormat: { idx, title in "Глава \(idx): \(title)" },
                pages: [
                    (
                        title: "Руководство по Expert PDF Reader",
                        subtitle: "Нативное приложение macOS для чтения PDF с GPU-темами",
                        sections: [
                            ("1. Добро пожаловать в Expert PDF Reader", "Быстрое и четкое чтение PDF на macOS: вкладки документов, главный экран HomeTab, цветовая палитра RDDesignLibrary и шейдеры RDPDFShaders.metallib."),
                            ("2. Темы чтения: Как в системе / День / Сепия / Ночь", "• Как в системе: автоматическое переключение между светлой темой (День или Сепия) и темной (Ночь)\n• День: классическая белая бумага (#FFFFFF)\n• Сепия: теплая кремовая бумага (#F5EFDC) и коричневые чернила (#3F2A18)\n• Ночь: черный фон (#000000) и мягкий серебристо-серый текст (#BFBFBF) без бликов.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Макет страницы, Разделенный вид и Поля",
                        subtitle: "Одна страница / Две страницы / Обложка / Разделенный вид / Скрыть поля",
                        sections: [
                            ("1. Макет страницы (⌘1 / ⌘2 / ⌘3)", "Переключайтесь между режимами «Одна страница», «Две страницы» и «Две страницы (обложка отдельно)»."),
                            ("2. Разделенный вид (Split View)", "Сравнивайте два раздела или два PDF-документа рядом (вертикально или горизонтально) с синхронной прокруткой."),
                            ("3. Скрыть поля (⇧⌘M)", "Автоматическое определение границ текста и обрезка пустых полей страницы.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Боковая панель: Миниатюры, Оглавление и Закладки",
                        subtitle: "Быстрая навигация по большим документам PDF",
                        sections: [
                            ("1. Миниатюры страниц (Thumbnails)", "Миниатюры отображаются в реальном времени с учетом выбранной GPU-темы."),
                            ("2. Оглавление (Outline)", "Древовидное оглавление с автоматической подсветкой текущего раздела."),
                            ("3. Закладки (Bookmarks, ⌘D)", "Добавляйте страницы в закладки нажатием ⌘D.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Полнотекстовый поиск и Быстрые клавиши",
                        subtitle: "Мгновенный поиск и переключение страниц клавишами ← / →",
                        sections: [
                            ("1. Полнотекстовый поиск (⌘F)", "Нажмите ⌘F для поиска ключевых слов по всему документу с подсветкой контекста."),
                            ("2. Основные клавиши", "• Предыдущая / следующая страница: ← / → (или ⌥↑ / ⌥↓)\n• Открыть: ⌘O   • Новая вкладка: ⌘T   • Закрыть вкладку: ⌘W\n• Левая панель: ⌘B   • Обзор страниц: ⌃⌘1   • Поля: ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        case .uk:
            return GuideContent(
                fileName: "Expert PDF Reader - Посібник із читання.pdf",
                badgePrefix: "EXPERT PDF READER  •  ПОСІБНИК",
                swatchHeader: "Тестова палітра GPU-шейдерів (Авто / День / Сепія / Ніч)",
                swatchLabels: ["Чорний #000", "Темний #333", "Сірий #808", "Синій #2FA5FF", "Зелений #3CC83C", "Бурштин #FFB72B", "Корал #FA4655"],
                chapterFormat: { idx, title in "Розділ \(idx): \(title)" },
                pages: [
                    (
                        title: "Посібник із читання Expert PDF Reader",
                        subtitle: "Нативний застосунок macOS для читання PDF із GPU-темами",
                        sections: [
                            ("1. Ласкаво просимо до Expert PDF Reader", "Швидке й чітке читання PDF на macOS: вкладки документів, головний екран HomeTab, палітра RDDesignLibrary та шейдери RDPDFShaders.metallib."),
                            ("2. Теми читання: Як у системі / День / Сепія / Ніч", "• Як у системі: автоматичне перемикання між світлою темою (День або Сепія) і темною (Ніч)\n• День: класичний білий папір (#FFFFFF)\n• Сепія: теплий кремовий папір (#F5EFDC) і коричневе чорнило (#3F2A18)\n• Ніч: чорне тло (#000000) і м’який сріблясто-сірий текст (#BFBFBF) без відблисків.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Макет сторінки, Розділений вигляд і Поля",
                        subtitle: "Одна сторінка / Дві сторінки / Обкладинка / Розділений вигляд / Приховати поля",
                        sections: [
                            ("1. Макет сторінки (⌘1 / ⌘2 / ⌘3)", "Перемикайтеся між режимами «Одна сторінка», «Дві сторінки» та «Дві сторінки (обкладинка окремо)»."),
                            ("2. Розділений вигляд (Split View)", "Порівнюйте два розділи або два PDF-документи поруч із синхронним прокручуванням."),
                            ("3. Приховати поля (⇧⌘M)", "Автоматичне визначення меж тексту й обрізання зайвих білих полів.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Бічна панель: Мініатюри, Зміст і Закладки",
                        subtitle: "Швидка навігація великими документами PDF",
                        sections: [
                            ("1. Мініатюри сторінок (Thumbnails)", "Мініатюри відображаються в реальному часі з активною GPU-темою."),
                            ("2. Зміст (Outline)", "Ієрархічний зміст із автоматичним підсвічуванням поточного розділу."),
                            ("3. Закладки (Bookmarks, ⌘D)", "Додавайте сторінки в закладки натисканням ⌘D.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Повнотекстовий пошук і Клавіші швидкого доступу",
                        subtitle: "Миттєвий пошук і перемикання сторінок клавішами ← / →",
                        sections: [
                            ("1. Повнотекстовий пошук (⌘F)", "Натисніть ⌘F для пошуку ключових слів у документі з підсвічуванням контексту."),
                            ("2. Основні клавіші", "• Попередня / наступна сторінка: ← / → (або ⌥↑ / ⌥↓)\n• Відкрити: ⌘O   • Нова вкладка: ⌘T   • Закрити вкладку: ⌘W\n• Ліва панель: ⌘B   • Огляд сторінок: ⌃⌘1   • Поля: ⇧⌘M")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )

        default:
            return GuideContent(
                fileName: "Expert PDF Reader - Reading Guide.pdf",
                badgePrefix: "EXPERT PDF READER  •  READING GUIDE",
                swatchHeader: "GPU Shader Test Swatches (Switch Auto / Day / Sepia / Night to observe filter response)",
                swatchLabels: ["Ink #000", "Dark #333", "Gray #808", "Blue #2FA5FF", "Green #3CC83C", "Amber #FFB72B", "Coral #FA4655"],
                chapterFormat: { idx, title in "Chapter \(idx): \(title)" },
                pages: [
                    (
                        title: "Expert PDF Reader Guide",
                        subtitle: "Native macOS PDF Reader with Real-Time GPU Reading Themes",
                        sections: [
                            ("1. Welcome to Expert PDF Reader", "Built for a fast, crystal-clear native macOS reading experience—featuring multi-tab navigation, the HomeTab architecture, RDDesignLibrary semantic color tokens, and GPU page shaders from RDPDFShaders.metallib."),
                            ("2. Reading Themes: Follow System / Day / Sepia / Night", "Switch themes anytime from the top toolbar or View Settings panel:\n• Follow System: Automatically uses Day (or Sepia when 'Use Sepia in Light Mode' is enabled) in Light appearance and switches to Night in Dark appearance\n• Day: Crisp original white paper (#FFFFFF)\n• Sepia: Warm cream paper (#F5EFDC) with deep espresso ink (#3F2A18)\n• Night: Pure black page (#000000) with soft silver-gray ink (#BFBFBF) to eliminate glare.")
                        ],
                        drawColorSwatches: true
                    ),
                    (
                        title: "Page Layout, Split View & Clear Margins",
                        subtitle: "Single Page / Two Pages / Cover Mode / Vertical & Horizontal Split / Clear Margins",
                        sections: [
                            ("1. Page Layout Modes (⌘1 / ⌘2 / ⌘3)", "Seamlessly switch between Single Page continuous scroll, Two Pages side-by-side, and Two Pages with Single Cover."),
                            ("2. Split View Comparison", "Open Vertical (Left/Right) or Horizontal (Top/Bottom) Split View to read two sections of the same document or compare two different PDFs with optional Sync Scroll & Zoom."),
                            ("3. Smart Clear Margins (⇧⌘M)", "Automatically detects ink bounding boxes on each page and crops wide white margins to maximize reading area.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Sidebar Navigation: Thumbnails, Outline & Bookmarks",
                        subtitle: "Jump to any chapter or bookmarked page effortlessly",
                        sections: [
                            ("1. Live GPU-Themed Thumbnails", "The first sidebar tab renders page thumbnails with the active Day, Sepia, or Night GPU shader and highlights the current page."),
                            ("2. Hierarchical Table of Contents (Outline)", "Expand or collapse nested chapters while the active section is highlighted automatically as you scroll."),
                            ("3. Page Bookmarks (⌘D)", "Press ⌘D or click the bookmark button in the toolbar to bookmark any page.")
                        ],
                        drawColorSwatches: false
                    ),
                    (
                        title: "Full-Text Search & Keyboard Shortcuts",
                        subtitle: "Instant search snippets and ← / → arrow key page navigation",
                        sections: [
                            ("1. Full-Text Search (⌘F)", "Press ⌘F to search keywords across the document, view matches grouped by page with context snippets, and step through matches with ⌘G / ⇧⌘G."),
                            ("2. Essential Keyboard Shortcuts", "• Previous / Next Page: ← / → (or ⌥↑ / ⌥↓)\n• Open File: ⌘O        • New Home Tab: ⌘T       • Close Tab: ⌘W\n• Left Panel: ⌘B       • Page Overview: ⌃⌘1     • Clear Margins: ⇧⌘M\n• Single / Two Pages / Cover: ⌘1 / ⌘2 / ⌘3     • Zoom In / Out / Actual: ⌘+ / ⌘- / ⌘0")
                        ],
                        drawColorSwatches: true
                    )
                ]
            )
        }
    }
}
