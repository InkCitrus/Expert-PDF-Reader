import AppKit
import CoreImage
import Metal
import QuartzCore

/// Day / Sepia / Night page theme renderer. Provides both:
/// 1. Direct GPU Metal rendering (shaders compiled at runtime from `metalShaderSource`) for thumbnails/bitmaps.
/// 2. Pre-built `CIFilter`s (`CIColorMatrix`) for 120Hz live `PDFPageLayer` filtering.
public final class MetalShaderRenderer {
    public static let shared = MetalShaderRenderer()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineStates: [PDFViewTheme: MTLRenderPipelineState] = [:]

    /// Cached CoreImage layer filter chains for live `PDFPageLayer` tile containers
    private var layerFilters: [PDFViewTheme: [CIFilter]] = [:]

    private init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        setupPipelines()
        setupLayerFilters()
    }

    private func setupPipelines() {
        guard let device = self.device else { return }

        // Compiled from source at runtime, so the Command Line Tools (without the Metal toolchain) can build the app
        guard let lib = try? device.makeLibrary(source: Self.metalShaderSource, options: nil),
              let vtxFn = lib.makeFunction(name: "pageVertex") else {
            return
        }

        let mapping: [(PDFViewTheme, String)] = [
            (.day, "dayPageFragment"),
            (.sepia, "sepiaPageFragment"),
            (.night, "nightPageFragment")
        ]

        for (theme, fragName) in mapping {
            guard let fragFn = lib.makeFunction(name: fragName) else { continue }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtxFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            if let state = try? device.makeRenderPipelineState(descriptor: desc) {
                pipelineStates[theme] = state
            }
        }
    }

    // Both themes map grays exactly as before (white → paper, black → ink) and keep part of each color's
    // chroma, so colored figures, links and highlights stay tellable apart instead of turning one gray or brown.
    //
    // Sepia: luminance L = 0.29 R + 0.57 G + 0.14 B goes from ink #3F2A18 (L = 0) to paper #F5EFDC (L = 1),
    // plus 55% of the color's chroma:
    //   out = ink + (paper - ink) * L + 0.55 * (rgb - L)
    // Night: lightness is inverted (L' = 0.75 * (1 - L), L = 0.299 R + 0.587 G + 0.114 B), keeping 70% of
    // the chroma; for grays this is the previous v = 0.75 - 0.25 * (R + G + B):
    //   out = L' + 0.70 * (rgb - L)
    // Both are affine, so each fits one CIColorMatrix (live pages) and matches the Metal fragments (thumbnails).
    //
    // Core Animation runs layer filters on linear-light values while the Metal fragments see sRGB-encoded
    // ones; the matrix is therefore wrapped in sRGB tone curves so live pages get the same colors as the
    // thumbnails (Night ink #BFBFBF instead of a glaring near-white, Sepia ink #3F2A18 instead of a light brown).

    private func setupLayerFilters() {
        if let sepiaFilter = CIFilter(name: "CIColorMatrix") {
            sepiaFilter.setDefaults()
            sepiaFilter.setValue(CIVector(x: 0.598, y: 0.093, z: 0.023, w: 0.0), forKey: "inputRVector")
            sepiaFilter.setValue(CIVector(x: 0.065, y: 0.677, z: 0.031, w: 0.0), forKey: "inputGVector")
            sepiaFilter.setValue(CIVector(x: 0.064, y: 0.125, z: 0.581, w: 0.0), forKey: "inputBVector")
            sepiaFilter.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0), forKey: "inputAVector")
            sepiaFilter.setValue(CIVector(x: 0.247, y: 0.165, z: 0.094, w: 0.0), forKey: "inputBiasVector")
            layerFilters[.sepia] = Self.inSRGB(sepiaFilter)
        }

        if let nightFilter = CIFilter(name: "CIColorMatrix") {
            nightFilter.setDefaults()
            nightFilter.setValue(CIVector(x: 0.26645, y: -0.85115, z: -0.1653, w: 0.0), forKey: "inputRVector")
            nightFilter.setValue(CIVector(x: -0.43355, y: -0.15115, z: -0.1653, w: 0.0), forKey: "inputGVector")
            nightFilter.setValue(CIVector(x: -0.43355, y: -0.85115, z: 0.5347, w: 0.0), forKey: "inputBVector")
            nightFilter.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0), forKey: "inputAVector")
            nightFilter.setValue(CIVector(x: 0.75, y: 0.75, z: 0.75, w: 0.0), forKey: "inputBiasVector")
            layerFilters[.night] = Self.inSRGB(nightFilter)
        }
    }

    /// Runs `filter` on sRGB-encoded values inside Core Animation's linear working space
    private static func inSRGB(_ filter: CIFilter) -> [CIFilter] {
        guard let toSRGB = CIFilter(name: "CILinearToSRGBToneCurve"),
              let toLinear = CIFilter(name: "CISRGBToneCurveToLinear") else {
            return [filter]
        }
        return [toSRGB, filter, toLinear]
    }

    /// Returns the `CIFilter` to attach to `PDFPageLayer`'s tile container layer for a given `PDFViewTheme`.
    public func pageLayerFilters(for theme: PDFViewTheme) -> [Any] {
        switch theme {
        case .day:
            return []
        case .sepia, .night:
            return layerFilters[theme] ?? []
        }
    }

    /// Applies `sepiaPageFragment` or `nightPageFragment`
    /// directly on the GPU to a `CGImage` (e.g. for themed thumbnails).
    public func applyShader(to cgImage: CGImage, theme: PDFViewTheme) -> CGImage? {
        if theme == .day { return cgImage }
        guard let device = self.device,
              let queue = self.commandQueue,
              let state = self.pipelineStates[theme] else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead, .renderTarget]
        guard let inTex = device.makeTexture(descriptor: texDesc),
              let outTex = device.makeTexture(descriptor: texDesc),
              let cmd = queue.makeCommandBuffer() else {
            return nil
        }

        inTex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: rawData,
            bytesPerRow: bytesPerRow
        )

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = outTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(state)

        let w = Float(width)
        let h = Float(height)
        let verts: [Float] = [0, 0,  0, h,  w, 0,  w, h]
        let uvs: [Float]   = [0, 0,  0, 1,  1, 0,  1, 1]
        var opacity: Float = 1.0
        var vp: [Float] = [w, h]

        enc.setVertexBytes(verts, length: verts.count * 4, index: 0)
        enc.setVertexBytes(uvs, length: uvs.count * 4, index: 1)
        enc.setVertexBytes(&opacity, length: 4, index: 2)
        enc.setVertexBytes(&vp, length: 8, index: 3)
        enc.setFragmentTexture(inTex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()

        outTex.getBytes(
            &rawData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        guard let outContext = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return outContext.makeImage()
    }

    private static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct TextureVertexOut {
        float4 position [[position]];
        float2 textureCoordinate;
        float opacity;
    };
    vertex TextureVertexOut pageVertex(
        uint vertexID [[vertex_id]],
        constant float2 *vertexArray [[buffer(0)]],
        constant float2 *textureCoordinatesArray [[buffer(1)]],
        constant float *opacityPtr [[buffer(2)]],
        constant float2 *viewportSizePtr [[buffer(3)]]
    ) {
        TextureVertexOut out;
        float2 pixelPos = vertexArray[vertexID];
        float2 vp = *viewportSizePtr;
        float2 ndc = (pixelPos / (vp * 0.5)) - float2(1.0, 1.0);
        ndc.y = -ndc.y;
        out.position = float4(ndc, 0.0, 1.0);
        out.textureCoordinate = textureCoordinatesArray[vertexID];
        out.opacity = *opacityPtr;
        return out;
    }
    fragment float4 dayPageFragment(
        TextureVertexOut in [[stage_in]],
        texture2d<half, access::sample> colorTexture [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float4 c = float4(colorTexture.sample(s, in.textureCoordinate));
        return float4(c.rgb, c.a * in.opacity);
    }
    fragment float4 sepiaPageFragment(
        TextureVertexOut in [[stage_in]],
        texture2d<half, access::sample> colorTexture [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float4 c = float4(colorTexture.sample(s, in.textureCoordinate));
        float3 ink = float3(0.247f, 0.165f, 0.094f);
        float3 paper = float3(0.961f, 0.938f, 0.863f);
        float l = dot(c.rgb, float3(0.29f, 0.57f, 0.14f));
        float3 sepia = ink + (paper - ink) * l + 0.55f * (c.rgb - l);
        return float4(clamp(sepia, 0.0f, 1.0f), c.a * in.opacity);
    }
    fragment float4 nightPageFragment(
        TextureVertexOut in [[stage_in]],
        texture2d<half, access::sample> colorTexture [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float4 c = float4(colorTexture.sample(s, in.textureCoordinate));
        float l = dot(c.rgb, float3(0.299f, 0.587f, 0.114f));
        float3 night = 0.75f * (1.0f - l) + 0.70f * (c.rgb - l);
        return float4(clamp(night, 0.0f, 1.0f), c.a * in.opacity);
    }
    """
}
