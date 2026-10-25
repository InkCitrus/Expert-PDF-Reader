import CoreGraphics
import Foundation
import PDFKit
import Vision

/// What a sample of a book's pages shows, read with on-device text recognition: the page numbers printed on
/// them and the direction the book reads. Scans often carry page labels numbered in scan order, or none at all,
/// and a book bound on the right (vertical Chinese and Japanese) may be stored in reading order or, as the
/// Internet Archive scans it, with each spread's left page first.
public struct BookPageScan: Codable, Equatable {
    public var printedNumbers: PrintedPageNumbers?
    /// Spreads read right to left: the earlier page belongs on the right. `nil` when the sample did not tell
    public var readsRightToLeft: Bool?
}

public struct PrintedPageNumbers: Codable, Equatable {
    /// A run of pages numbered consecutively: printed number = page index + offset. Unnumbered inserts (plates,
    /// blank leaves) start a new run with a smaller offset
    public struct Run: Codable, Equatable {
        public var firstIndex: Int
        public var lastIndex: Int
        public var offset: Int
    }

    public var runs: [Run]
    /// Added to the offset on odd page indices: ±2 when every spread is stored left page first while the book
    /// reads right to left, so its pages alternate 7, 6, 9, 8…
    public var oddIndexShift: Int
    /// The PDF's own page labels disagree with what is printed (or are missing), so these numbers replace them
    public var replacesPageLabels: Bool

    public func number(at index: Int) -> Int? {
        guard let run = runs.first(where: { $0.firstIndex <= index && index <= $0.lastIndex }) else { return nil }
        let number = index + run.offset + (index % 2 == 1 ? oddIndexShift : 0)
        return number > 0 ? number : nil
    }
}

public enum BookPageScanner {
    enum WritingDirection {
        case horizontal, vertical
    }

    struct Reading {
        let index: Int
        /// The printed page number and its horizontal centre, 0 (left edge) … 1 (right edge)
        let number: Int?
        let position: CGFloat
        let writing: WritingDirection?
        /// The PDF's page label for the page
        let label: String?
    }

    /// Pages read once each, as scanning goes back to narrow down where the numbering jumps
    final class PageReader {
        let document: PDFDocument
        private(set) var readings: [Int: Reading] = [:]

        init(document: PDFDocument) {
            self.document = document
        }

        func read(_ index: Int) -> Reading? {
            if let reading = readings[index] { return reading }
            guard let page = document.page(at: index), let image = render(page) else { return nil }
            let found = readNumber(in: image)
            let reading = Reading(
                index: index,
                number: found?.number,
                position: found?.position ?? 0.5,
                writing: writingDirection(in: image),
                label: page.printedNumber
            )
            readings[index] = reading
            return reading
        }
    }

    /// Looks at pairs of neighbouring pages spread over the book, then at pages between two samples whose numbering
    /// disagrees. Takes a few seconds (longer for scans stored as JPEG 2000); call it off the main thread with a
    /// document of its own.
    public static func scan(_ document: PDFDocument, pairs: Int = 10) -> BookPageScan {
        let count = document.pageCount
        guard count >= 16 else { return BookPageScan() }
        let reader = PageReader(document: document)
        for index in sampleIndices(pageCount: count, pairs: pairs) {
            _ = reader.read(index)
        }
        let numbers = printedNumbers(using: reader, pageCount: count)
        return BookPageScan(printedNumbers: numbers, readsRightToLeft: readsRightToLeft(Array(reader.readings.values), numbers: numbers))
    }

    static func sampleIndices(pageCount: Int, pairs: Int) -> [Int] {
        (0..<pairs).flatMap { k -> [Int] in
            let first = (pageCount - 2) * (k + 1) / (pairs + 1)
            return [first, first + 1]
        }
    }

    // MARK: - Numbering

    static func printedNumbers(using reader: PageReader, pageCount: Int) -> PrintedPageNumbers? {
        let numbered = reader.readings.values.filter { $0.number != nil }.sorted { $0.index < $1.index }

        // Neighbouring pages tell whether odd pages run 2 ahead or behind (each spread stored left page first)
        var shifts: [Int: Int] = [:]
        for reading in numbered {
            guard let next = reader.readings[reading.index + 1], let nextNumber = next.number else { continue }
            let difference = (nextNumber - next.index) - (reading.number! - reading.index)
            // Measured from an even page to the odd one after it, or backwards
            let shift = reading.index % 2 == 0 ? difference : -difference
            if [0, 2, -2].contains(shift) { shifts[shift, default: 0] += 1 }
        }
        guard let (oddIndexShift, votes) = shifts.max(by: { $0.value < $1.value }),
              votes * 10 >= shifts.values.reduce(0, +) * 7, votes >= 3 else { return nil }

        func offset(of reading: Reading) -> Int {
            reading.number! - reading.index - (reading.index % 2 == 1 ? oddIndexShift : 0)
        }

        // Runs of samples sharing an offset; a lone sample that disagrees with both neighbours is a stray digit
        var points = numbered.map { (index: $0.index, offset: offset(of: $0)) }
        points = points.enumerated().filter { position, point in
            guard position > 0, position < points.count - 1 else { return true }
            let before = points[position - 1].offset, after = points[position + 1].offset
            return !(before == after && point.offset != before)
        }.map(\.element)
        var runs: [PrintedPageNumbers.Run] = []
        for point in points {
            if let last = runs.last, last.offset == point.offset {
                runs[runs.count - 1].lastIndex = point.index
            } else {
                runs.append(.init(firstIndex: point.index, lastIndex: point.index, offset: point.offset))
            }
        }
        // A run seen on a single page is a misreading unless it is confirmed while narrowing down the jumps
        guard !runs.isEmpty else { return nil }

        // Narrow down each jump between runs by reading the pages in between
        for position in runs.indices.dropLast() {
            var low = runs[position].lastIndex, high = runs[position + 1].firstIndex
            let lowOffset = runs[position].offset, highOffset = runs[position + 1].offset
            var probes = 0
            while high - low > 1, probes < 10 {
                probes += 1
                let middle = (low + high) / 2
                // An unnumbered page (a chapter opening) tells nothing; try its neighbours
                guard let reading = [middle, middle + 1, middle - 1].lazy
                    .filter({ $0 > low && $0 < high })
                    .compactMap({ reader.read($0) })
                    .first(where: { $0.number != nil }) else { break }
                let found = offset(of: reading)
                if found == lowOffset {
                    low = reading.index
                } else if found == highOffset {
                    high = reading.index
                } else {
                    break
                }
            }
            runs[position].lastIndex = low
            runs[position + 1].firstIndex = high
        }
        // Single-page runs that never got confirmed by a neighbour are dropped
        runs = runs.filter { $0.lastIndex > $0.firstIndex || runs.count == 1 }
        guard !runs.isEmpty else { return nil }
        runs[0].firstIndex = 0
        runs[runs.count - 1].lastIndex = pageCount - 1

        let model = PrintedPageNumbers(runs: runs, oddIndexShift: oddIndexShift, replacesPageLabels: false)
        let checked = numbered.filter { model.number(at: $0.index) == $0.number }
        guard checked.count * 10 >= numbered.count * 7 else { return nil }
        let labelsMatch = checked.filter { $0.label == String($0.number!) }.count
        var result = model
        result.replacesPageLabels = labelsMatch * 10 < checked.count * 8
        return result
    }

    // MARK: - Direction

    /// Bound on the right: the text is set vertically, and where the page numbers sit at the corners, the even
    /// ones are on the right. Guidebooks that print them by the spine, or mix in vertical text, stay left to right
    static func readsRightToLeft(_ readings: [Reading], numbers: PrintedPageNumbers?) -> Bool? {
        let vertical = readings.filter { $0.writing == .vertical }.count
        let horizontal = readings.filter { $0.writing == .horizontal }.count
        let isVertical = vertical >= 4 && vertical >= horizontal * 3

        let fitting = readings.filter { reading in
            guard let number = reading.number else { return false }
            return numbers?.number(at: reading.index) == number
        }
        let sided = fitting.filter { $0.position < 0.35 || $0.position > 0.65 }
        let evenOnRight = sided.filter { ($0.number! % 2 == 0) == ($0.position > 0.5) }.count
        let cornersSayRight = sided.count >= 4 && evenOnRight * 10 >= sided.count * 8
        let cornersSayLeft = sided.count >= 4 && (sided.count - evenOnRight) * 10 >= sided.count * 8

        if isVertical && !cornersSayLeft {
            // A spread stored left page first already shows a right-bound book correctly from left to right;
            // without page numbers to tell, assume reading order
            let inReadingOrder = (numbers?.oddIndexShift ?? 0) == 0
            return inReadingOrder
        }
        if horizontal >= 4 || cornersSayLeft {
            return false
        }
        return nil
    }

    // MARK: - Page image

    struct PageImage {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let cgImage: CGImage
    }

    /// The page in grey, 700 px wide: drawn once, since a scanned page's image is slow to decode
    static func render(_ page: PDFPage) -> PageImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0 else { return nil }
        let width = 700
        let height = Int(CGFloat(width) * box.height / box.width)
        guard height > 100, height < 4000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            return context.makeImage()
        }
        return image.map { PageImage(pixels: pixels, width: width, height: height, cgImage: $0) }
    }

    /// The page number in the bottom (else top) eighth of the page: digits only, the one nearest a corner
    static func readNumber(in image: PageImage) -> (number: Int, position: CGFloat)? {
        let stripHeight = image.height / 8
        // Image rows run from the top
        for rect in [CGRect(x: 0, y: image.height - stripHeight, width: image.width, height: stripHeight),
                     CGRect(x: 0, y: 0, width: image.width, height: stripHeight)] {
            guard let strip = image.cgImage.cropping(to: rect) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Digits only: the Latin model is a hundred times faster than detecting the page's language
            request.recognitionLanguages = ["en-US"]
            try? VNImageRequestHandler(cgImage: strip).perform([request])
            var best: (number: Int, position: CGFloat)?
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      (1...4).contains(text.count), text.allSatisfy(\.isASCII), let number = Int(text), number > 0 else { continue }
                let position = observation.boundingBox.midX
                if best.map({ abs(position - 0.5) > abs($0.position - 0.5) }) ?? true {
                    best = (number, position)
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// Lines of text leave blank rows between them, columns of vertical text blank columns
    static func writingDirection(in image: PageImage) -> WritingDirection? {
        let x0 = image.width / 10, x1 = image.width * 9 / 10
        let y0 = image.height / 8, y1 = image.height * 7 / 8
        var rowInk = [Int](repeating: 0, count: y1 - y0)
        var columnInk = [Int](repeating: 0, count: x1 - x0)
        var total = 0
        for y in y0..<y1 {
            let row = y * image.width
            for x in x0..<x1 where image.pixels[row + x] < 128 {
                rowInk[y - y0] += 1
                columnInk[x - x0] += 1
                total += 1
            }
        }
        let area = (x1 - x0) * (y1 - y0)
        guard total * 100 > area else { return nil }
        let rowLimit = max(1, (x1 - x0) / 250)
        let columnLimit = max(1, (y1 - y0) / 250)
        let blankRows = Double(rowInk.filter { $0 <= rowLimit }.count) / Double(rowInk.count)
        let blankColumns = Double(columnInk.filter { $0 <= columnLimit }.count) / Double(columnInk.count)
        if blankRows - blankColumns > 0.12 { return .horizontal }
        if blankColumns - blankRows > 0.12 { return .vertical }
        return nil
    }
}
