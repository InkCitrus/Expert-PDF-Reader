import Foundation
import PDFKit

/// PDFKit asks for multiple tiles of the same scan. Decode/rasterize its large source image once per
/// display resolution rather than once per tile. Native PDFPage text, selections and links remain intact.
enum ScannedPageCache {
    private final class Delegate: NSObject, PDFDocumentDelegate {
        func classForPage() -> AnyClass { CachedScanPage.self }
    }
    private static let delegate = Delegate()
    private static let identities = NSMapTable<PDFDocument, NSString>.weakToStrongObjects()
    private static let identitiesLock = NSLock()

    static func install(on document: PDFDocument) {
        if document.delegate == nil { document.delegate = delegate }
        _ = identity(of: document)
    }

    static func identity(of document: PDFDocument) -> String {
        identitiesLock.lock()
        defer { identitiesLock.unlock() }
        if let identity = identities.object(forKey: document) { return identity as String }
        let identity: String
        if let url = document.documentURL,
           let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            identity = "\(url.standardizedFileURL.path):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
        } else {
            identity = UUID().uuidString
        }
        identities.setObject(identity as NSString, forKey: document)
        return identity
    }

    struct PrefetchPage: Sendable {
        let index: Int
        let mediaBox: CGRect
        let cropBox: CGRect
        let rotation: Int
    }

    /// Only a few adjacent pages, on an independent document, serialized across reader windows.
    static func prefetch(url: URL, pages: [PrefetchPage], scale: CGFloat) -> Task<Void, Never> {
        Task.detached(priority: .utility) { await PrefetchQueue.shared.prepare(url: url, pages: pages, scale: scale) }
    }

    private actor PrefetchQueue {
        static let shared = PrefetchQueue()
        private var document: PDFDocument?
        private var identity: String?

        func prepare(url: URL, pages: [PrefetchPage], scale: CGFloat) {
            guard !Task.isCancelled else { return }
            guard let copy = PDFDocument(url: url), !copy.isLocked else { return }
            ScannedPageCache.install(on: copy)
            let copyIdentity = ScannedPageCache.identity(of: copy)
            if identity != copyIdentity { document = copy; identity = copyIdentity }
            guard let document else { return }
            for request in pages {
                guard !Task.isCancelled else { return }
                autoreleasepool {
                    guard let page = document.page(at: request.index) as? CachedScanPage else { return }
                    page.setBounds(request.mediaBox, for: .mediaBox)
                    page.setBounds(request.cropBox, for: .cropBox)
                    page.rotation = request.rotation
                    page.warmRaster(with: .cropBox, scale: scale)
                }
            }
        }
    }
}

final class CachedScanPage: PDFPage {
    // PDFKit constructs delegate page classes through an internal Objective-C initializer, which does
    // not run Swift stored-property initializers. Keep Swift state outside the PDFPage subclass.
    private final class State {
        let id: String
        let lock = NSLock()
        var isScan: Bool?
        init(id: String) { self.id = id }
    }
    private static let states = NSMapTable<PDFPage, State>.weakToStrongObjects()
    private static let sharedStates: NSCache<NSString, State> = {
        let cache = NSCache<NSString, State>()
        cache.countLimit = 128
        return cache
    }()
    private static let statesLock = NSLock()
    private var rasterState: State {
        Self.statesLock.lock()
        defer { Self.statesLock.unlock() }
        if let state = Self.states.object(forKey: self) { return state }
        let id = document.map { "\(ScannedPageCache.identity(of: $0)):\($0.index(for: self))" } ?? UUID().uuidString
        let state = Self.sharedStates.object(forKey: id as NSString) ?? State(id: id)
        Self.sharedStates.setObject(state, forKey: id as NSString)
        Self.states.setObject(state, forKey: self)
        return state
    }
    private final class Raster: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    /// NSCache may evict the just-visible page while its neighbour is being prepared. A bounded LRU
    /// preserves the current working set across tab switches and still yields on memory pressure.
    private final class RasterCache {
        private struct Entry { let raster: Raster; let cost: Int; var use: UInt64 }
        private let lock = NSLock()
        private var entries: [NSString: Entry] = [:]
        private var totalCost = 0
        private var use: UInt64 = 0
        private let limit = 192 * 1024 * 1024
        private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))

        init() {
            pressure.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.entries.removeAll()
                self.totalCost = 0
                self.lock.unlock()
            }
            pressure.resume()
        }

        func object(forKey key: NSString) -> Raster? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[key] else { return nil }
            use &+= 1
            entries[key]?.use = use
            return entry.raster
        }

        func setObject(_ raster: Raster, forKey key: NSString, cost: Int) {
            lock.lock(); defer { lock.unlock() }
            if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
            while totalCost + cost > limit, let oldest = entries.min(by: { $0.value.use < $1.value.use }) {
                totalCost -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
            use &+= 1
            entries[key] = Entry(raster: raster, cost: cost, use: use)
            totalCost += cost
        }
    }
    private static let cache = RasterCache()

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let transform = context.ctm
        let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        // Printing/exporting and very deep zoom retain the original vector/image drawing path.
        guard context.width > 0, context.height > 0,
              let raster = raster(with: box, scale: scale, onlyCached: scale > 4) else { super.draw(with: box, to: context); return }
        let resolution = max(1, ceil(scale * 2) / 2)
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(raster.image, in: CGRect(x: 0, y: 0, width: CGFloat(raster.image.width) / resolution,
                                             height: CGFloat(raster.image.height) / resolution))
        context.restoreGState()
    }

    fileprivate func warmRaster(with box: PDFDisplayBox, scale: CGFloat) { _ = raster(with: box, scale: scale, waits: true) }

    private func raster(with box: PDFDisplayBox, scale: CGFloat, onlyCached: Bool = false, waits: Bool = false) -> Raster? {
        guard rotation == 0, scale.isFinite, scale > 0, scale <= 8, annotations.isEmpty else { return nil }
        let displayed = bounds(for: box)
        let resolution = max(1, ceil(scale * 2) / 2)
        let width = Int(ceil(displayed.width * resolution)), height = Int(ceil(displayed.height * resolution))
        guard width > 0, height > 0, width * height <= 24_000_000 else { return nil }
        let state = rasterState
        let key = "\(state.id):\(box.rawValue):\(displayed):\(bounds(for: .mediaBox)):\(width)x\(height)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard !onlyCached else { return nil }
        // A visible tile never waits for an adjacent-page worker. Keep drawing natively until it is ready.
        if waits { state.lock.lock() }
        else if !state.lock.try() { return nil }
        if state.isScan == nil { state.isScan = hasFullPageScanImage }
        guard state.isScan == true else { state.lock.unlock(); return nil }
        var raster = Self.cache.object(forKey: key)
        if raster == nil, let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.scaleBy(x: resolution, y: resolution)
            super.draw(with: box, to: bitmap)
            if let image = bitmap.makeImage() {
                raster = Raster(image)
                Self.cache.setObject(raster!, forKey: key, cost: width * height * 4)
            }
        }
        state.lock.unlock()
        return raster
    }

}

extension PDFPage {
    var hasFullPageScanImage: Bool {
        let media = bounds(for: .mediaBox)
        guard media.height > 0 else { return false }
        guard let dictionary = pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        let probe = ImageProbe(aspect: media.width / media.height)
        CGPDFDictionaryApplyFunction(objects, { _, object, info in
            guard let info else { return }
            let probe = Unmanaged<ImageProbe>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var width = 0, height = 0
            if CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
               width > 300, height > 300, abs(CGFloat(width) / CGFloat(height) / probe.aspect - 1) < 0.25 {
                probe.found = true
            }
        }, Unmanaged.passUnretained(probe).toOpaque())
        return probe.found
    }
    private final class ImageProbe {
        let aspect: CGFloat
        var found = false
        init(aspect: CGFloat) { self.aspect = aspect }
    }
}
