import Foundation
import PDFKit

/// PDFKit asks for multiple tiles of the same scan. Decode/rasterize its large source image once per
/// display resolution rather than once per tile. Native PDFPage text, selections and links remain intact.
enum ScannedPageCache {
    private final class Delegate: NSObject, PDFDocumentDelegate {
        func classForPage() -> AnyClass { CachedScanPage.self }
    }
    private static let delegate = Delegate()
    static func install(on document: PDFDocument) {
        if document.delegate == nil { document.delegate = delegate }
    }
}

final class CachedScanPage: PDFPage {
    // PDFKit constructs delegate page classes through an internal Objective-C initializer, which does
    // not run Swift stored-property initializers. Keep Swift state outside the PDFPage subclass.
    private final class State {
        let id = UUID().uuidString
        let lock = NSLock()
        var isScan: Bool?
    }
    private static let states = NSMapTable<PDFPage, State>.weakToStrongObjects()
    private static let statesLock = NSLock()
    private var rasterState: State {
        Self.statesLock.lock()
        defer { Self.statesLock.unlock() }
        if let state = Self.states.object(forKey: self) { return state }
        let state = State()
        Self.states.setObject(state, forKey: self)
        return state
    }
    private final class Raster: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let cache: NSCache<NSString, Raster> = {
        let cache = NSCache<NSString, Raster>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let displayed = bounds(for: box)
        let transform = context.ctm
        let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        // Printing/exporting and very deep zoom retain the original vector/image drawing path.
        guard rotation == 0, scale.isFinite, scale > 0, scale <= 4,
              context.width > 0, context.height > 0, annotations.isEmpty else { super.draw(with: box, to: context); return }
        let resolution = max(1, ceil(scale * 2) / 2)
        let width = Int(ceil(displayed.width * resolution)), height = Int(ceil(displayed.height * resolution))
        guard width > 0, height > 0, width * height <= 12_000_000 else { super.draw(with: box, to: context); return }
        let state = rasterState
        let key = "\(state.id):\(box.rawValue):\(displayed):\(width)x\(height)" as NSString
        state.lock.lock()
        if state.isScan == nil { state.isScan = hasFullPageScanImage }
        guard state.isScan == true else { state.lock.unlock(); super.draw(with: box, to: context); return }
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
        guard let raster else { super.draw(with: box, to: context); return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(raster.image, in: CGRect(x: 0, y: 0, width: CGFloat(width) / resolution, height: CGFloat(height) / resolution))
        context.restoreGState()
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
