import AppKit
import CoreGraphics
import PDFKit

// MARK: - Semantic Intra-Page PDF Region Model

enum PDFSemanticRegionKind: Equatable {
    /// Embedded raster image, vector diagram/chart, or scanned figure
    case figure
    /// Bordered card, callout box, framed code listing, or table
    case container
    /// Document title or section heading
    case heading
    /// Paragraph, code block, or structured text block
    case textBlock
}

struct PDFSemanticRegion: Equatable {
    let kind: PDFSemanticRegionKind
    /// Bounding box in `PDFPage` coordinate space (origin bottom-left)
    var pageBounds: CGRect
    /// Short text preview when available (used for accessibility labels)
    var previewText: String?
    /// Nested child regions strictly inside this container
    var children: [PDFSemanticRegion] = []
}

// MARK: - Per-Document Cache for Extracted Page Regions

@MainActor
final class PDFAccessibilityLayoutCache {
    static let shared = PDFAccessibilityLayoutCache()

    private struct PageKey: Hashable {
        let pageIndex: Int
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int
        let rotation: Int

        init(pageIndex: Int, box: CGRect, rotation: Int) {
            self.pageIndex = pageIndex
            self.minX = Int((box.minX * 2).rounded())
            self.minY = Int((box.minY * 2).rounded())
            self.width = Int((box.width * 2).rounded())
            self.height = Int((box.height * 2).rounded())
            self.rotation = rotation
        }
    }

    private final class DocumentCache {
        var pages: [PageKey: [PDFSemanticRegion]] = [:]
    }

    private let storage = NSMapTable<PDFDocument, DocumentCache>.weakToStrongObjects()

    func regions(for page: PDFPage, at pageIndex: Int, in document: PDFDocument, displayBox: PDFDisplayBox) -> [PDFSemanticRegion] {
        let box = page.bounds(for: displayBox)
        guard box.width > 20, box.height > 20 else { return [] }
        let key = PageKey(pageIndex: pageIndex, box: box, rotation: page.rotation)

        let docCache: DocumentCache
        if let existing = storage.object(forKey: document) {
            docCache = existing
        } else {
            let created = DocumentCache()
            storage.setObject(created, forKey: document)
            docCache = created
        }

        if let cached = docCache.pages[key] {
            return cached
        }

        // Keep per-document cache bounded if user flips through hundreds of pages with AX active
        if docCache.pages.count > 48 {
            docCache.pages.removeAll(keepingCapacity: true)
        }

        let extracted = PDFPageRegionExtractor.extractRegions(for: page, cropBox: box)
        docCache.pages[key] = extracted
        return extracted
    }
}

// MARK: - PDF Page Semantic Region Extractor

enum PDFPageRegionExtractor {
    static func extractRegions(for page: PDFPage, cropBox: CGRect) -> [PDFSemanticRegion] {
        let pageArea = cropBox.width * cropBox.height
        guard pageArea > 400 else { return [] }

        // 1. Extract embedded images, framed cards/code boxes, tables & vector diagrams from CGPDF stream
        let graphics = CGPDFGraphicScanner.scan(page: page, cropBox: cropBox)

        // 2. Extract headings, paragraphs & code blocks from PDFKit text layer
        let textRegions = extractTextRegions(for: page, cropBox: cropBox, containers: graphics.containers)

        // 3. Fallback for pure image-scanned pages (no selectable text and no sub-page graphic regions)
        if textRegions.isEmpty && graphics.containers.isEmpty && graphics.figures.isEmpty {
            let scannedRegions = extractScannedInkRegions(for: page, cropBox: cropBox)
            return buildHierarchy(
                containers: [],
                figures: scannedRegions.filter { $0.kind == .figure },
                textBlocks: scannedRegions.filter { $0.kind != .figure },
                cropBox: cropBox
            )
        }

        return buildHierarchy(
            containers: graphics.containers,
            figures: graphics.figures,
            textBlocks: textRegions,
            cropBox: cropBox
        )
    }

    // MARK: Text Layer Grouping (Headings, Paragraphs, Code Listings, Multi-Column Blocks)

    private struct LineItem {
        var bounds: CGRect
        var text: String
        var isStandaloneLineNumber: Bool
    }

    private static func extractTextRegions(
        for page: PDFPage,
        cropBox: CGRect,
        containers: [PDFSemanticRegion]
    ) -> [PDFSemanticRegion] {
        guard let fullSelection = page.selection(for: cropBox) else { return [] }
        let rawSelections = fullSelection.selectionsByLine()
        guard !rawSelections.isEmpty else { return [] }

        var rawLines: [LineItem] = []
        rawLines.reserveCapacity(rawSelections.count)

        for sel in rawSelections {
            guard let rawText = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawText.isEmpty else { continue }
            let clipped = sel.bounds(for: page).intersection(cropBox)
            guard !clipped.isNull, clipped.width >= 2, clipped.height >= 3 else { continue }
            let isLineNum = isCodeLineNumberToken(rawText, width: clipped.width)
            rawLines.append(LineItem(bounds: clipped, text: rawText, isStandaloneLineNumber: isLineNum))
        }

        guard !rawLines.isEmpty else { return [] }

        // Sort top-to-bottom (descending midY in bottom-left PDF space), then left-to-right (ascending minX)
        rawLines.sort { lhs, rhs in
            if abs(lhs.bounds.midY - rhs.bounds.midY) > 3.5 {
                return lhs.bounds.midY > rhs.bounds.midY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }

        // Step A: Merge same-baseline horizontal fragments (including left-gutter code line numbers + code lines)
        var mergedLines: [LineItem] = []
        for item in rawLines {
            if let lastIdx = mergedLines.indices.last {
                let prev = mergedLines[lastIdx]
                let minH = min(prev.bounds.height, item.bounds.height)
                let vOverlap = min(prev.bounds.maxY, item.bounds.maxY) - max(prev.bounds.minY, item.bounds.minY)
                let sameBaseline = vOverlap >= minH * 0.42 || abs(prev.bounds.midY - item.bounds.midY) <= 4.0

                if sameBaseline && item.bounds.minX >= prev.bounds.minX - 2 {
                    let hGap = item.bounds.minX - prev.bounds.maxX
                    let avgH = (prev.bounds.height + item.bounds.height) * 0.5
                    let sameEnclosingBox = enclosingContainerIndex(for: prev.bounds, in: containers) != nil
                        && enclosingContainerIndex(for: prev.bounds, in: containers) == enclosingContainerIndex(for: item.bounds, in: containers)
                    // Merge adjacent words on same line, or code gutter line-number with its code statement
                    let canMergeLineNum = prev.isStandaloneLineNumber
                        && !item.isStandaloneLineNumber
                        && hGap >= -2
                        && hGap <= min(160, cropBox.width * 0.30)
                    let canMergePhrase = !prev.isStandaloneLineNumber
                        && hGap >= -4
                        && hGap <= max(18, avgH * 1.9)
                    let canMergeSameBoxRow = sameEnclosingBox && hGap >= -4 && hGap <= 32

                    if canMergeLineNum || canMergePhrase || canMergeSameBoxRow {
                        mergedLines[lastIdx].bounds = prev.bounds.union(item.bounds)
                        mergedLines[lastIdx].text = prev.text + " " + item.text
                        mergedLines[lastIdx].isStandaloneLineNumber = false
                        continue
                    }
                }
            }
            mergedLines.append(item)
        }

        // Drop any orphaned tiny line numbers that had a blank code line (empty line with only a gutter number)
        // or fold them into adjacent code blocks below
        // Re-sort strictly top-to-bottom by column-aware order:
        // Detect if page has multi-column layout so left column lines stay together before right column lines
        let orderedLines = orderLinesByColumnAndVerticalFlow(mergedLines, cropBox: cropBox, containers: containers)

        // Step B: Group lines into semantic Heading / Paragraph / Code Block regions
        struct WorkingBlock {
            var bounds: CGRect
            var lastLineBounds: CGRect
            var lineHeights: [CGFloat]
            var lineCount: Int
            var previewText: String
            var containerIdx: Int?
            var looksLikeCode: Bool
        }

        var blocks: [WorkingBlock] = []
        let headerThresholdY = cropBox.maxY - cropBox.height * 0.085
        let footerThresholdY = cropBox.minY + cropBox.height * 0.085

        for line in orderedLines {
            let cIdx = enclosingContainerIndex(for: line.bounds, in: containers)
            let lineIsCode = looksLikeCodeLine(line.text) || line.isStandaloneLineNumber

            guard let lastIdx = blocks.indices.last else {
                blocks.append(
                    WorkingBlock(
                        bounds: line.bounds,
                        lastLineBounds: line.bounds,
                        lineHeights: [line.bounds.height],
                        lineCount: 1,
                        previewText: line.text,
                        containerIdx: cIdx,
                        looksLikeCode: lineIsCode
                    )
                )
                continue
            }

            let cur = blocks[lastIdx]
            let avgH = cur.lineHeights.reduce(0, +) / CGFloat(cur.lineHeights.count)
            let vGap = cur.lastLineBounds.minY - line.bounds.maxY

            // Never merge across different graphic containers (e.g. two separate cards or code boxes)
            let sameContainer = (cur.containerIdx == cIdx)

            // Keep outermost running header / footer separate from body paragraphs
            let curInOuterMargin = (cur.bounds.minY >= headerThresholdY && cur.lineCount == 1 && vGap > 8)
            let lineInFooterMargin = (line.bounds.maxY <= footerThresholdY && vGap > 8)

            // Height similarity: keep headings separate from body text
            let maxH = max(avgH, line.bounds.height)
            let minH = max(1, min(avgH, line.bounds.height))
            let heightRatio = maxH / minH

            let bothCodeContext = (cur.looksLikeCode || lineIsCode || (cIdx != nil && cur.looksLikeCode))
            let maxAllowedGap = bothCodeContext ? max(6.5, avgH * 0.78) : max(5.5, avgH * 0.60)
            let verticallyAdjacent = vGap >= -4.0 && vGap <= maxAllowedGap

            // Horizontal alignment check
            let hOverlap = min(cur.bounds.maxX, line.bounds.maxX) - max(cur.bounds.minX, line.bounds.minX)
            let leftDelta = abs(line.bounds.minX - cur.bounds.minX)
            let centeredTogether = abs(line.bounds.midX - cur.bounds.midX) <= 16
                && abs(cur.bounds.midX - cropBox.midX) <= cropBox.width * 0.18
            // Standard paragraph: aligned left edges, or 2em first-line indent (`leftDelta <= 34`), or code indentation
            let horizontallyCompatible: Bool = {
                if bothCodeContext {
                    // Code lines can indent freely within the same column / code box
                    let sameColumnSpan = line.bounds.minX < cur.bounds.maxX + 48
                        && cur.bounds.minX < line.bounds.maxX + 120
                    return sameColumnSpan
                }
                guard hOverlap > 4 else { return false }
                if leftDelta <= 34 || centeredTogether {
                    return true
                }
                return false
            }()

            // Prevent merging two separate columns that accidentally overlap slightly in Y
            let crossesColumnGutter = cur.bounds.width < cropBox.width * 0.52
                && line.bounds.width < cropBox.width * 0.52
                && (line.bounds.minX > cur.bounds.maxX + 14 || cur.bounds.minX > line.bounds.maxX + 14)

            // Cap unboxed code/TOC runs if there is a blank-line break, while keeping contiguous paragraphs whole
            let shouldMerge = sameContainer
                && !curInOuterMargin
                && !lineInFooterMargin
                && verticallyAdjacent
                && heightRatio <= (bothCodeContext ? 1.38 : 1.22)
                && horizontallyCompatible
                && !crossesColumnGutter

            if shouldMerge {
                blocks[lastIdx].bounds = cur.bounds.union(line.bounds)
                blocks[lastIdx].lastLineBounds = line.bounds
                blocks[lastIdx].lineHeights.append(line.bounds.height)
                blocks[lastIdx].lineCount += 1
                if blocks[lastIdx].previewText.count < 48 {
                    blocks[lastIdx].previewText += " " + line.text
                }
                if lineIsCode {
                    blocks[lastIdx].looksLikeCode = true
                }
            } else {
                blocks.append(
                    WorkingBlock(
                        bounds: line.bounds,
                        lastLineBounds: line.bounds,
                        lineHeights: [line.bounds.height],
                        lineCount: 1,
                        previewText: line.text,
                        containerIdx: cIdx,
                        looksLikeCode: lineIsCode
                    )
                )
            }
        }

        // Compute median body line height to classify headings vs body blocks
        let sortedHeights = mergedLines.map(\.bounds.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]

        return blocks.compactMap { block -> PDFSemanticRegion? in
            // Skip stray 1-2 character noise tokens unless they are a meaningful heading/label
            if block.bounds.width < 12 && block.bounds.height < 12 && block.lineCount == 1 {
                return nil
            }
            let avgH = block.lineHeights.reduce(0, +) / CGFloat(block.lineHeights.count)
            let isHeading = block.lineCount <= 3 && avgH >= max(14.5, medianHeight * 1.22)

            // Add crisp 3pt x 2pt screenshot breathing room, clamped to enclosing container & cropBox
            var padded = block.bounds.insetBy(dx: -3.0, dy: -2.0).intersection(cropBox)
            if let cIdx = block.containerIdx {
                let cBounds = containers[cIdx].pageBounds
                if cBounds.width > 12, cBounds.height > 12 {
                    let inner = padded.intersection(cBounds.insetBy(dx: 1.5, dy: 1.5))
                    if !inner.isNull, inner.width >= block.bounds.width * 0.85 {
                        padded = inner
                    }
                }
            }

            let preview = String(block.previewText.prefix(44))
            return PDFSemanticRegion(
                kind: isHeading ? .heading : .textBlock,
                pageBounds: padded,
                previewText: preview
            )
        }
    }

    private static func orderLinesByColumnAndVerticalFlow(
        _ lines: [LineItem],
        cropBox: CGRect,
        containers: [PDFSemanticRegion]
    ) -> [LineItem] {
        guard lines.count >= 6 else { return lines }
        let midX = cropBox.midX
        let gutterHalfWidth: CGFloat = 6.0

        var leftCol: [LineItem] = []
        var rightCol: [LineItem] = []
        var spanning: [LineItem] = []

        for line in lines {
            if line.bounds.maxX <= midX + gutterHalfWidth && line.bounds.width < cropBox.width * 0.49 {
                leftCol.append(line)
            } else if line.bounds.minX >= midX - gutterHalfWidth && line.bounds.width < cropBox.width * 0.49 {
                rightCol.append(line)
            } else {
                spanning.append(line)
            }
        }

        // Only treat as 2-column when both columns carry real vertical runs at overlapping Y ranges
        guard leftCol.count >= 4, rightCol.count >= 4 else {
            return lines
        }

        // Partition by spanning lines (like a full-width page title above a 2-column TOC/paper!)
        var result: [LineItem] = []
        result.reserveCapacity(lines.count)
        let sortedSpanning = spanning.sorted { $0.bounds.midY > $1.bounds.midY }
        var remainingLeft = leftCol.sorted { $0.bounds.midY > $1.bounds.midY }
        var remainingRight = rightCol.sorted { $0.bounds.midY > $1.bounds.midY }

        for span in sortedSpanning {
            let aboveLeft = remainingLeft.filter { $0.bounds.midY > span.bounds.midY }
            let aboveRight = remainingRight.filter { $0.bounds.midY > span.bounds.midY }
            result.append(contentsOf: aboveLeft)
            result.append(contentsOf: aboveRight)
            result.append(span)
            remainingLeft.removeAll { $0.bounds.midY > span.bounds.midY }
            remainingRight.removeAll { $0.bounds.midY > span.bounds.midY }
        }
        result.append(contentsOf: remainingLeft)
        result.append(contentsOf: remainingRight)
        return result
    }

    private static func enclosingContainerIndex(for rect: CGRect, in containers: [PDFSemanticRegion]) -> Int? {
        let area = rect.width * rect.height
        guard area > 0 else { return nil }
        var bestIdx: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (idx, container) in containers.enumerated() {
            let cRect = container.pageBounds
            let inter = rect.intersection(cRect)
            guard !inter.isNull else { continue }
            let covered = (inter.width * inter.height) / area
            let cArea = cRect.width * cRect.height
            if covered >= 0.80 && cArea < bestArea {
                bestArea = cArea
                bestIdx = idx
            }
        }
        return bestIdx
    }

    private static func isCodeLineNumberToken(_ text: String, width: CGFloat) -> Bool {
        guard width <= 30, (1...4).contains(text.count) else { return false }
        return text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func looksLikeCodeLine(_ text: String) -> Bool {
        if text.contains("{") || text.contains("}") || text.contains(";") || text.contains("//")
            || text.contains("#include") || text.contains("++") || text.contains("==")
            || text.contains("->") || text.contains("return ") || text.contains("int ")
            || text.contains("void ") || text.contains("for (") || text.contains("if (") {
            return true
        }
        return false
    }

    // MARK: Scanned / Image-Only Page Fallback (Fast Low-Res Morphological Block Detector)

    private static func extractScannedInkRegions(for page: PDFPage, cropBox: CGRect) -> [PDFSemanticRegion] {
        let gridW = 180
        let gridH = max(120, min(320, Int((CGFloat(gridW) * cropBox.height / max(1, cropBox.width)).rounded())))
        var pixels = [UInt8](repeating: 255, count: gridW * gridH)

        guard let ctx = CGContext(
            data: &pixels,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: gridW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: gridW, height: gridH))
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(gridW) / cropBox.width, y: CGFloat(gridH) / cropBox.height)
        ctx.translateBy(x: -cropBox.minX, y: -cropBox.minY)
        if let pageRef = page.pageRef {
            ctx.drawPDFPage(pageRef)
        } else {
            page.draw(with: .cropBox, to: ctx)
        }
        ctx.restoreGState()

        // Dilate dark ink (< 236) horizontally by 5px and vertically by 1px so words & lines in a paragraph merge
        var mask = [Bool](repeating: false, count: gridW * gridH)
        let margin = 2
        for y in margin..<(gridH - margin) {
            let row = y * gridW
            for x in margin..<(gridW - margin) where pixels[row + x] < 236 {
                let y0 = max(margin, y - 1)
                let y1 = min(gridH - margin - 1, y + 1)
                let x0 = max(margin, x - 5)
                let x1 = min(gridW - margin - 1, x + 5)
                for dy in y0...y1 {
                    let dRow = dy * gridW
                    for dx in x0...x1 {
                        mask[dRow + dx] = true
                    }
                }
            }
        }

        // Connected components BFS
        var visited = [Bool](repeating: false, count: gridW * gridH)
        var queue: [Int] = []
        queue.reserveCapacity(512)

        let scaleX = cropBox.width / CGFloat(gridW)
        let scaleY = cropBox.height / CGFloat(gridH)
        let pageArea = cropBox.width * cropBox.height
        var results: [PDFSemanticRegion] = []

        for startIdx in 0..<(gridW * gridH) where mask[startIdx] && !visited[startIdx] {
            visited[startIdx] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(startIdx)

            var minX = gridW, maxX = 0
            var minY = gridH, maxY = 0
            var head = 0

            while head < queue.count {
                let cur = queue[head]
                head += 1
                let cx = cur % gridW
                let cy = cur / gridW
                if cx < minX { minX = cx }
                if cx > maxX { maxX = cx }
                if cy < minY { minY = cy }
                if cy > maxY { maxY = cy }

                let neighbors = [
                    cx > 0 ? cur - 1 : -1,
                    cx + 1 < gridW ? cur + 1 : -1,
                    cy > 0 ? cur - gridW : -1,
                    cy + 1 < gridH ? cur + gridW : -1
                ]
                for nb in neighbors where nb >= 0 && mask[nb] && !visited[nb] {
                    visited[nb] = true
                    queue.append(nb)
                }
            }

            // Convert top-origin bitmap rows to bottom-origin PDF coordinates
            let pdfMinYRow = gridH - 1 - maxY
            let pdfMaxYRow = gridH - 1 - minY
            let rect = CGRect(
                x: cropBox.minX + CGFloat(minX) * scaleX,
                y: cropBox.minY + CGFloat(pdfMinYRow) * scaleY,
                width: CGFloat(maxX - minX + 1) * scaleX,
                height: CGFloat(pdfMaxYRow - pdfMinYRow + 1) * scaleY
            ).insetBy(dx: -2, dy: -2).intersection(cropBox)

            let rArea = rect.width * rect.height
            guard rect.width >= 32, rect.height >= 10, rArea < pageArea * 0.88 else { continue }
            let kind: PDFSemanticRegionKind = (rect.height > 72 && rect.width > 72 && Double(queue.count) > Double((maxX - minX + 1) * (maxY - minY + 1)) * 0.45)
                ? .figure
                : .textBlock
            results.append(PDFSemanticRegion(kind: kind, pageBounds: rect, previewText: nil))
        }

        results.sort { $0.pageBounds.maxY > $1.pageBounds.maxY }
        return results
    }

    // MARK: Hierarchical Nesting & Deduplication

    private static func buildHierarchy(
        containers: [PDFSemanticRegion],
        figures: [PDFSemanticRegion],
        textBlocks: [PDFSemanticRegion],
        cropBox: CGRect
    ) -> [PDFSemanticRegion] {
        let pageArea = cropBox.width * cropBox.height

        // 1. Filter valid bounds (< 88% of page area so no region duplicates the page paper itself)
        func isValidSubPageRect(_ r: CGRect) -> Bool {
            guard !r.isNull, !r.isEmpty, r.width >= 16, r.height >= 9 else { return false }
            let area = r.width * r.height
            return area < pageArea * 0.88
        }

        let cleanFigures = deduplicateRegions(figures.filter { isValidSubPageRect($0.pageBounds) }, iouThreshold: 0.82)
        var cleanContainers = deduplicateRegions(containers.filter { isValidSubPageRect($0.pageBounds) }, iouThreshold: 0.84)

        // Remove any container that strongly duplicates a figure
        cleanContainers.removeAll { c in
            cleanFigures.contains { intersectionOverUnion(c.pageBounds, $0.pageBounds) >= 0.82 }
        }

        // 2. Absorb tiny text micro-labels (like axis ticks or short diagram node labels) inside figures,
        //    and drop text blocks whose rect is nearly identical to a container or figure
        let cleanText = textBlocks.filter { tb in
            guard isValidSubPageRect(tb.pageBounds) else { return false }
            let tbArea = tb.pageBounds.width * tb.pageBounds.height
            for fig in cleanFigures {
                if intersectionOverUnion(tb.pageBounds, fig.pageBounds) >= 0.80 {
                    return false
                }
                let inter = tb.pageBounds.intersection(fig.pageBounds)
                if !inter.isNull, (inter.width * inter.height) / tbArea >= 0.85 {
                    // Inside a figure/diagram, absorb small labels so hovering the diagram snaps cleanly to the figure
                    if tb.pageBounds.width < 120 && tb.pageBounds.height < 28 {
                        return false
                    }
                }
            }
            for cont in cleanContainers {
                if intersectionOverUnion(tb.pageBounds, cont.pageBounds) >= 0.84 {
                    return false
                }
            }
            return true
        }

        // 3. Build up to 2 levels of container nesting (e.g. outer card -> inner sub-card/figure/paragraph)
        // Sort containers from smallest area to largest area so inner cards attach to outer cards cleanly
        cleanContainers.sort {
            ($0.pageBounds.width * $0.pageBounds.height) < ($1.pageBounds.width * $1.pageBounds.height)
        }

        // Attach leaf items (figures + textBlocks) to the tightest enclosing container
        var leafPool: [PDFSemanticRegion] = cleanFigures + cleanText
        var unparentedLeaves: [PDFSemanticRegion] = []

        for leaf in leafPool {
            let leafArea = leaf.pageBounds.width * leaf.pageBounds.height
            var attached = false
            for idx in cleanContainers.indices {
                let cRect = cleanContainers[idx].pageBounds
                let cArea = cRect.width * cRect.height
                guard cArea > leafArea * 1.12 else { continue }
                let inter = leaf.pageBounds.intersection(cRect)
                if !inter.isNull, (inter.width * inter.height) / leafArea >= 0.84 {
                    cleanContainers[idx].children.append(leaf)
                    attached = true
                    break
                }
            }
            if !attached {
                unparentedLeaves.append(leaf)
            }
        }
        leafPool.removeAll()

        // Nest smaller containers inside strictly larger enclosing containers
        var topContainers: [PDFSemanticRegion] = []
        var nestedFlags = [Bool](repeating: false, count: cleanContainers.count)
        for i in cleanContainers.indices {
            let inner = cleanContainers[i]
            let innerArea = inner.pageBounds.width * inner.pageBounds.height
            for j in (i + 1)..<cleanContainers.count {
                let outerRect = cleanContainers[j].pageBounds
                let outerArea = outerRect.width * outerRect.height
                guard outerArea > innerArea * 1.18 else { continue }
                let inter = inner.pageBounds.intersection(outerRect)
                if !inter.isNull, (inter.width * inter.height) / innerArea >= 0.86 {
                    cleanContainers[j].children.append(inner)
                    nestedFlags[i] = true
                    break
                }
            }
        }
        for i in cleanContainers.indices where !nestedFlags[i] {
            cleanContainers[i].children.sort { $0.pageBounds.maxY > $1.pageBounds.maxY }
            topContainers.append(cleanContainers[i])
        }

        var allTop = topContainers + unparentedLeaves
        allTop.sort { lhs, rhs in
            if abs(lhs.pageBounds.maxY - rhs.pageBounds.maxY) > 6 {
                return lhs.pageBounds.maxY > rhs.pageBounds.maxY
            }
            return lhs.pageBounds.minX < rhs.pageBounds.minX
        }
        return allTop
    }

    private static func deduplicateRegions(_ items: [PDFSemanticRegion], iouThreshold: CGFloat) -> [PDFSemanticRegion] {
        var kept: [PDFSemanticRegion] = []
        for item in items {
            if let matchIdx = kept.firstIndex(where: { intersectionOverUnion($0.pageBounds, item.pageBounds) >= iouThreshold }) {
                kept[matchIdx].pageBounds = kept[matchIdx].pageBounds.union(item.pageBounds)
                if kept[matchIdx].previewText == nil {
                    kept[matchIdx].previewText = item.previewText
                }
            } else {
                kept.append(item)
            }
        }
        return kept
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}

// MARK: - CGPDF Content Stream Scanner (Images, Form XObjects, Framed Boxes, Tables & Vector Diagrams)

private enum CGPDFGraphicScanner {
    struct ScanOutput {
        var containers: [PDFSemanticRegion] = []
        var figures: [PDFSemanticRegion] = []
    }

    private final class State {
        struct GState {
            var ctm: CGAffineTransform
            var clipBox: CGRect
        }

        let cropBox: CGRect
        let pageArea: CGFloat
        var contentStream: CGPDFContentStreamRef
        let operatorTable: CGPDFOperatorTableRef
        let depth: Int

        var gStack: [GState] = []
        var ctm: CGAffineTransform
        var clipBox: CGRect

        var currentPoint: CGPoint = .zero
        var pathBounds: CGRect = .null
        var pathHasRectOp = false
        var pathSegmentCount = 0
        var pendingClip = false
        var opCount = 0

        var figures: [CGRect] = []
        var boxRects: [CGRect] = []
        var horizontalRules: [CGRect] = []
        var verticalRules: [CGRect] = []
        var vectorPrimitives: [CGRect] = []

        init(
            cropBox: CGRect,
            contentStream: CGPDFContentStreamRef,
            operatorTable: CGPDFOperatorTableRef,
            initialCTM: CGAffineTransform = .identity,
            initialClip: CGRect? = nil,
            depth: Int = 0
        ) {
            self.cropBox = cropBox
            self.pageArea = cropBox.width * cropBox.height
            self.contentStream = contentStream
            self.operatorTable = operatorTable
            self.ctm = initialCTM
            self.clipBox = initialClip ?? cropBox
            self.depth = depth
        }

        func includePagePoint(_ pt: CGPoint) {
            let p = pt.applying(ctm)
            let tiny = CGRect(x: p.x, y: p.y, width: 0, height: 0)
            pathBounds = pathBounds.isNull ? tiny : pathBounds.union(tiny)
        }

        func includeLocalRect(_ r: CGRect) {
            let p1 = CGPoint(x: r.minX, y: r.minY).applying(ctm)
            let p2 = CGPoint(x: r.maxX, y: r.minY).applying(ctm)
            let p3 = CGPoint(x: r.minX, y: r.maxY).applying(ctm)
            let p4 = CGPoint(x: r.maxX, y: r.maxY).applying(ctm)
            let minX = min(min(p1.x, p2.x), min(p3.x, p4.x))
            let maxX = max(max(p1.x, p2.x), max(p3.x, p4.x))
            let minY = min(min(p1.y, p2.y), min(p3.y, p4.y))
            let maxY = max(max(p1.y, p2.y), max(p3.y, p4.y))
            let transformed = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            pathBounds = pathBounds.isNull ? transformed : pathBounds.union(transformed)
        }

        func resetPath() {
            pathBounds = .null
            pathHasRectOp = false
            pathSegmentCount = 0
            pendingClip = false
        }

        func finishPaintedPath() {
            guard opCount < 8000 else {
                resetPath()
                return
            }
            opCount += 1
            if pendingClip, !pathBounds.isNull {
                let clipped = clipBox.intersection(pathBounds)
                if !clipped.isNull {
                    clipBox = clipped
                }
            }

            defer { resetPath() }
            guard !pathBounds.isNull else { return }
            let visible = pathBounds.intersection(clipBox).intersection(cropBox)
            guard !visible.isNull else { return }

            let w = visible.width
            let h = visible.height
            let area = w * h
            guard area < pageArea * 0.86 else { return }

            // 1. Horizontal or vertical rules (table lines / dividers)
            if h <= 3.6 && w >= 54 {
                horizontalRules.append(visible)
                return
            }
            if w <= 3.6 && h >= 18 {
                verticalRules.append(visible)
                return
            }

            // Ignore tiny glyph/bullet decorations
            guard w >= 8 || h >= 8 else { return }

            // 2. Framed / filled rectangular or rounded-rect cards, callouts, code boxes
            // Rounded rects in AppKit/CoreGraphics emit ~8-12 segments (4 lines + 4 curves)
            let isBoxShape = pathHasRectOp || (pathSegmentCount >= 4 && pathSegmentCount <= 16)
            if isBoxShape && w >= 46 && h >= 20 {
                boxRects.append(visible)
                return
            }

            // 3. Vector primitive belonging to a diagram / chart / illustration
            if w < cropBox.width * 0.84 && h < cropBox.height * 0.75 {
                vectorPrimitives.append(visible)
            }
        }
    }

    private static let operatorTable: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }

        // Graphics state stack
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            s.gStack.append(State.GState(ctm: s.ctm, clipBox: s.clipBox))
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            if let prev = s.gStack.popLast() {
                s.ctm = prev.ctm
                s.clipBox = prev.clipBox
            }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let info else { return }
            var ty: CGPDFReal = 0, tx: CGPDFReal = 0
            var d: CGPDFReal = 0, c: CGPDFReal = 0, b: CGPDFReal = 0, a: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &ty),
                  CGPDFScannerPopNumber(scanner, &tx),
                  CGPDFScannerPopNumber(scanner, &d),
                  CGPDFScannerPopNumber(scanner, &c),
                  CGPDFScannerPopNumber(scanner, &b),
                  CGPDFScannerPopNumber(scanner, &a) else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            let m = CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
            s.ctm = m.concatenating(s.ctm)
        }

        // Path construction
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let info else { return }
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            let pt = CGPoint(x: x, y: y)
            s.currentPoint = pt
            s.includePagePoint(pt)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let info else { return }
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            let pt = CGPoint(x: x, y: y)
            s.includePagePoint(s.currentPoint)
            s.includePagePoint(pt)
            s.currentPoint = pt
            s.pathSegmentCount += 1
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let info else { return }
            var y3: CGPDFReal = 0, x3: CGPDFReal = 0
            var y2: CGPDFReal = 0, x2: CGPDFReal = 0
            var y1: CGPDFReal = 0, x1: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y3), CGPDFScannerPopNumber(scanner, &x3),
                  CGPDFScannerPopNumber(scanner, &y2), CGPDFScannerPopNumber(scanner, &x2),
                  CGPDFScannerPopNumber(scanner, &y1), CGPDFScannerPopNumber(scanner, &x1) else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            s.includePagePoint(s.currentPoint)
            s.includePagePoint(CGPoint(x: x1, y: y1))
            s.includePagePoint(CGPoint(x: x2, y: y2))
            let endPt = CGPoint(x: x3, y: y3)
            s.includePagePoint(endPt)
            s.currentPoint = endPt
            s.pathSegmentCount += 1
        }
        for curveOp in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, curveOp) { scanner, info in
                guard let info else { return }
                var y3: CGPDFReal = 0, x3: CGPDFReal = 0
                var y2: CGPDFReal = 0, x2: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &y3), CGPDFScannerPopNumber(scanner, &x3),
                      CGPDFScannerPopNumber(scanner, &y2), CGPDFScannerPopNumber(scanner, &x2) else { return }
                let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
                s.includePagePoint(s.currentPoint)
                s.includePagePoint(CGPoint(x: x2, y: y2))
                let endPt = CGPoint(x: x3, y: y3)
                s.includePagePoint(endPt)
                s.currentPoint = endPt
                s.pathSegmentCount += 1
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let info else { return }
            var h: CGPDFReal = 0, w: CGPDFReal = 0, y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &h), CGPDFScannerPopNumber(scanner, &w),
                  CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            s.includeLocalRect(CGRect(x: x, y: y, width: w, height: h))
            s.currentPoint = CGPoint(x: x, y: y)
            s.pathHasRectOp = true
            s.pathSegmentCount += 4
        }

        // Clipping
        for clipOp in ["W", "W*"] {
            CGPDFOperatorTableSetCallback(table, clipOp) { _, info in
                guard let info else { return }
                let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
                s.pendingClip = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            guard let info else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            if s.pendingClip, !s.pathBounds.isNull {
                let clipped = s.clipBox.intersection(s.pathBounds)
                if !clipped.isNull {
                    s.clipBox = clipped
                }
            }
            s.resetPath()
        }

        // Painting operators
        for paintOp in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, paintOp) { _, info in
                guard let info else { return }
                let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
                s.finishPaintedPath()
            }
        }

        // XObjects (Images & Vector Form XObjects)
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            var namePtr: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
            let s = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            guard let xObj = CGPDFContentStreamGetResource(s.contentStream, "XObject", namePtr) else { return }
            var streamRef: CGPDFStreamRef?
            guard CGPDFObjectGetValue(xObj, .stream, &streamRef), let streamRef,
                  let dict = CGPDFStreamGetDictionary(streamRef) else { return }
            var subtypePtr: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr), let subtypePtr else { return }
            let subtype = String(cString: subtypePtr)

            if subtype == "Image" {
                let rect = transformRect(CGRect(x: 0, y: 0, width: 1, height: 1), by: s.ctm)
                    .intersection(s.clipBox)
                    .intersection(s.cropBox)
                if !rect.isNull, rect.width >= 20, rect.height >= 18, rect.width * rect.height < s.pageArea * 0.88 {
                    s.figures.append(rect)
                }
            } else if subtype == "Form" {
                guard let bbox = readRectArray(from: dict, key: "BBox") else { return }
                let formMatrix = readTransformArray(from: dict, key: "Matrix") ?? .identity
                let combinedCTM = formMatrix.concatenating(s.ctm)
                let rect = transformRect(bbox, by: combinedCTM)
                    .intersection(s.clipBox)
                    .intersection(s.cropBox)
                guard !rect.isNull, rect.width >= 20, rect.height >= 18 else { return }

                let area = rect.width * rect.height
                if area >= s.pageArea * 0.45 && s.depth < 2 {
                    // Page/column wrapper Form XObject: recurse inside to find individual cards/figures
                    let childCS = CGPDFContentStreamCreateWithStream(streamRef, dict, s.contentStream)
                    defer { CGPDFContentStreamRelease(childCS) }
                    let childState = State(
                        cropBox: s.cropBox,
                        contentStream: childCS,
                        operatorTable: s.operatorTable,
                        initialCTM: combinedCTM,
                        initialClip: rect,
                        depth: s.depth + 1
                    )
                    let unmanaged = Unmanaged.passUnretained(childState)
                    let childScanner = CGPDFScannerCreate(childCS, s.operatorTable, unmanaged.toOpaque())
                    CGPDFScannerScan(childScanner)
                    CGPDFScannerRelease(childScanner)
                    s.figures.append(contentsOf: childState.figures)
                    s.boxRects.append(contentsOf: childState.boxRects)
                    s.horizontalRules.append(contentsOf: childState.horizontalRules)
                    s.verticalRules.append(contentsOf: childState.verticalRules)
                    s.vectorPrimitives.append(contentsOf: childState.vectorPrimitives)
                } else if area < s.pageArea * 0.88 {
                    s.figures.append(rect)
                }
            }
        }

        return table
    }()

    static func scan(page: PDFPage, cropBox: CGRect) -> ScanOutput {
        guard let cgPage = page.pageRef, let table = operatorTable else {
            return ScanOutput()
        }
        let cs = CGPDFContentStreamCreateWithPage(cgPage)
        defer { CGPDFContentStreamRelease(cs) }

        let state = State(cropBox: cropBox, contentStream: cs, operatorTable: table)
        let unmanaged = Unmanaged.passUnretained(state)
        let scanner = CGPDFScannerCreate(cs, table, unmanaged.toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)

        var output = ScanOutput()

        // 1. Embedded images & Form XObject figures (cluster adjacent tiled image strips if needed)
        let mergedImageRects = clusterAdjacentRects(state.figures, gapX: 3, gapY: 3)
        output.figures.append(contentsOf: mergedImageRects.map {
            PDFSemanticRegion(kind: .figure, pageBounds: $0, previewText: nil)
        })

        // 2. Framed/filled boxes (cards, code listing backgrounds, callouts)
        var containerRects = state.boxRects

        // 3. Assemble LaTeX / booktabs / grid tables from aligned horizontal & vertical rules
        containerRects.append(contentsOf: assembleTableRects(
            horizontalRules: state.horizontalRules,
            verticalRules: state.verticalRules,
            cropBox: cropBox
        ))

        output.containers = containerRects.map {
            PDFSemanticRegion(kind: .container, pageBounds: $0, previewText: nil)
        }

        // 4. Cluster standalone vector primitives (outside or inside boxes) into diagram/illustration figures
        let diagramRects = assembleVectorDiagrams(
            primitives: state.vectorPrimitives,
            existingContainers: containerRects,
            cropBox: cropBox
        )
        output.figures.append(contentsOf: diagramRects.map {
            PDFSemanticRegion(kind: .figure, pageBounds: $0, previewText: nil)
        })

        return output
    }

    private static func assembleTableRects(
        horizontalRules: [CGRect],
        verticalRules: [CGRect],
        cropBox: CGRect
    ) -> [CGRect] {
        guard horizontalRules.count >= 2 else { return [] }
        let sortedH = horizontalRules.sorted { $0.midY > $1.midY }
        var used = [Bool](repeating: false, count: sortedH.count)
        var tables: [CGRect] = []

        for i in sortedH.indices where !used[i] {
            let base = sortedH[i]
            guard base.width >= 80 else { continue }
            var group: [CGRect] = [base]
            used[i] = true

            for j in (i + 1)..<sortedH.count where !used[j] {
                let cand = sortedH[j]
                let aligned = abs(cand.minX - base.minX) <= 10 && abs(cand.maxX - base.maxX) <= 10
                let prevY = group.last!.minY
                let vDist = prevY - cand.maxY
                if aligned && vDist >= -2 && vDist <= 180 {
                    group.append(cand)
                    used[j] = true
                }
            }

            let unionRect = group.reduce(group[0]) { $0.union($1) }
            guard unionRect.height >= 24, unionRect.width * unionRect.height < cropBox.width * cropBox.height * 0.85 else {
                continue
            }

            // Require >= 3 horizontal rules (\toprule + \midrule + \bottomrule) OR bridging vertical rules,
            // so a lone header hairline + footer hairline on opposite ends of the page is never mistaken for a table
            let bridgingVerticals = verticalRules.filter { v in
                let inter = v.intersection(unionRect.insetBy(dx: -6, dy: -6))
                return !inter.isNull && inter.height >= 14
            }
            if group.count >= 3 || bridgingVerticals.count >= 2 {
                tables.append(unionRect.insetBy(dx: -2, dy: -2).intersection(cropBox))
            }
        }
        return tables
    }

    private static func assembleVectorDiagrams(
        primitives: [CGRect],
        existingContainers: [CGRect],
        cropBox: CGRect
    ) -> [CGRect] {
        guard primitives.count >= 3 else { return [] }
        // Exclude primitives that already match an existing card/box container border
        let filtered = primitives.filter { prim in
            !existingContainers.contains { PDFPageRegionExtractor.intersectionOverUnion(prim, $0) >= 0.82 }
        }
        guard filtered.count >= 3 else { return [] }

        // Cluster nearby primitives (within 14pt) and require >= 3 primitives forming a meaningful diagram
        var visited = [Bool](repeating: false, count: filtered.count)
        var diagrams: [CGRect] = []
        let pageArea = cropBox.width * cropBox.height

        for i in filtered.indices where !visited[i] {
            visited[i] = true
            var clusterBounds = filtered[i]
            var count = 1
            var changed = true
            while changed {
                changed = false
                let expanded = clusterBounds.insetBy(dx: -14, dy: -12)
                for j in filtered.indices where !visited[j] {
                    if expanded.intersects(filtered[j]) {
                        visited[j] = true
                        clusterBounds = clusterBounds.union(filtered[j])
                        count += 1
                        changed = true
                    }
                }
            }
            let padded = clusterBounds.insetBy(dx: -3, dy: -3).intersection(cropBox)
            let area = padded.width * padded.height
            if count >= 3 && padded.width >= 44 && padded.height >= 28 && area < pageArea * 0.78 {
                diagrams.append(padded)
            }
        }
        return diagrams
    }

    private static func clusterAdjacentRects(_ rects: [CGRect], gapX: CGFloat, gapY: CGFloat) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        var visited = [Bool](repeating: false, count: rects.count)
        var result: [CGRect] = []
        for i in rects.indices where !visited[i] {
            visited[i] = true
            var acc = rects[i]
            var changed = true
            while changed {
                changed = false
                let expanded = acc.insetBy(dx: -gapX, dy: -gapY)
                for j in rects.indices where !visited[j] && expanded.intersects(rects[j]) {
                    visited[j] = true
                    acc = acc.union(rects[j])
                    changed = true
                }
            }
            result.append(acc)
        }
        return result
    }

    private static func transformRect(_ r: CGRect, by m: CGAffineTransform) -> CGRect {
        let p1 = CGPoint(x: r.minX, y: r.minY).applying(m)
        let p2 = CGPoint(x: r.maxX, y: r.minY).applying(m)
        let p3 = CGPoint(x: r.minX, y: r.maxY).applying(m)
        let p4 = CGPoint(x: r.maxX, y: r.maxY).applying(m)
        let minX = min(min(p1.x, p2.x), min(p3.x, p4.x))
        let maxX = max(max(p1.x, p2.x), max(p3.x, p4.x))
        let minY = min(min(p1.y, p2.y), min(p3.y, p4.y))
        let maxY = max(max(p1.y, p2.y), max(p3.y, p4.y))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func readRectArray(from dict: CGPDFDictionaryRef, key: String) -> CGRect? {
        var arr: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &arr), let arr, CGPDFArrayGetCount(arr) >= 4 else { return nil }
        var x0: CGPDFReal = 0, y0: CGPDFReal = 0, x1: CGPDFReal = 0, y1: CGPDFReal = 0
        guard CGPDFArrayGetNumber(arr, 0, &x0),
              CGPDFArrayGetNumber(arr, 1, &y0),
              CGPDFArrayGetNumber(arr, 2, &x1),
              CGPDFArrayGetNumber(arr, 3, &y1) else { return nil }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    private static func readTransformArray(from dict: CGPDFDictionaryRef, key: String) -> CGAffineTransform? {
        var arr: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &arr), let arr, CGPDFArrayGetCount(arr) >= 6 else { return nil }
        var a: CGPDFReal = 0, b: CGPDFReal = 0, c: CGPDFReal = 0
        var d: CGPDFReal = 0, tx: CGPDFReal = 0, ty: CGPDFReal = 0
        guard CGPDFArrayGetNumber(arr, 0, &a),
              CGPDFArrayGetNumber(arr, 1, &b),
              CGPDFArrayGetNumber(arr, 2, &c),
              CGPDFArrayGetNumber(arr, 3, &d),
              CGPDFArrayGetNumber(arr, 4, &tx),
              CGPDFArrayGetNumber(arr, 5, &ty) else { return nil }
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

// MARK: - AppKit Accessibility Elements for Visible PDF Pages & Intra-Page Regions

final class PDFAccessibilityRegionElement: NSAccessibilityElement {
    private(set) var childElements: [PDFAccessibilityRegionElement] = []

    init(
        region: PDFSemanticRegion,
        screenFrame: NSRect,
        parent: Any,
        viewportScreenRect: NSRect,
        convertPageRect: (CGRect) -> NSRect
    ) {
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityFrame(screenFrame)

        switch region.kind {
        case .figure:
            setAccessibilityRole(.image)
            setAccessibilityLabel(L10n.tr("图表", "Figure"))
        case .container:
            setAccessibilityRole(.group)
            let label = region.previewText ?? L10n.tr("内容区块", "Content Block")
            setAccessibilityLabel(label)
        case .heading:
            setAccessibilityRole(.staticText)
            let label = region.previewText ?? L10n.tr("文本段落", "Text Block")
            setAccessibilityLabel(label)
        case .textBlock:
            setAccessibilityRole(.group)
            let label = region.previewText ?? L10n.tr("文本段落", "Text Block")
            setAccessibilityLabel(label)
        }

        if !region.children.isEmpty {
            let builtChildren: [PDFAccessibilityRegionElement] = region.children.compactMap { child in
                let raw = convertPageRect(child.pageBounds)
                let visible = raw.intersection(viewportScreenRect).intersection(screenFrame)
                guard !visible.isNull, visible.width >= 6, visible.height >= 6 else { return nil }
                // Skip child if after viewport clipping it has virtually the same rect as parent
                if PDFPageRegionExtractor.intersectionOverUnion(visible, screenFrame) >= 0.90 {
                    return nil
                }
                return PDFAccessibilityRegionElement(
                    region: child,
                    screenFrame: visible,
                    parent: self,
                    viewportScreenRect: viewportScreenRect,
                    convertPageRect: convertPageRect
                )
            }
            self.childElements = builtChildren
            setAccessibilityChildren(builtChildren)
        }
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard accessibilityFrame().contains(point) else { return nil }
        if !childElements.isEmpty {
            let matching = childElements.filter { $0.accessibilityFrame().contains(point) }
            if let tightest = matching.min(by: {
                ($0.accessibilityFrame().width * $0.accessibilityFrame().height)
                    < ($1.accessibilityFrame().width * $1.accessibilityFrame().height)
            }) {
                return tightest.accessibilityHitTest(point) ?? tightest
            }
        }
        return self
    }
}

final class PDFAccessibilityPageElement: NSAccessibilityElement {
    private(set) var regionElements: [PDFAccessibilityRegionElement] = []

    init(
        pageIndex: Int,
        pageLabel: String,
        screenFrame: NSRect,
        regions: [PDFSemanticRegion],
        parent: Any,
        viewportScreenRect: NSRect,
        convertPageRect: (CGRect) -> NSRect
    ) {
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.pageTitle(pageLabel))
        setAccessibilityFrame(screenFrame)

        let builtRegions: [PDFAccessibilityRegionElement] = regions.compactMap { region in
            let raw = convertPageRect(region.pageBounds)
            let visible = raw.intersection(viewportScreenRect).intersection(screenFrame)
            guard !visible.isNull, visible.width >= 8, visible.height >= 6 else { return nil }
            if PDFPageRegionExtractor.intersectionOverUnion(visible, screenFrame) >= 0.90 {
                return nil
            }
            return PDFAccessibilityRegionElement(
                region: region,
                screenFrame: visible,
                parent: self,
                viewportScreenRect: viewportScreenRect,
                convertPageRect: convertPageRect
            )
        }
        self.regionElements = builtRegions
        setAccessibilityChildren(builtRegions)
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard accessibilityFrame().contains(point) else { return nil }
        let matching = regionElements.filter { $0.accessibilityFrame().contains(point) }
        if let tightest = matching.min(by: {
            ($0.accessibilityFrame().width * $0.accessibilityFrame().height)
                < ($1.accessibilityFrame().width * $1.accessibilityFrame().height)
        }) {
            return tightest.accessibilityHitTest(point) ?? tightest
        }
        return self
    }
}
