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

    /// Cached CoreImage layer filters for live `PDFPageLayer` tile containers
    private var layerFilters: [PDFViewTheme: CIFilter] = [:]

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

    private func setupLayerFilters() {
        // Sepia: same affine matrix as sepiaPageFragment
        // R' = 0.247 + 0.207*R + 0.407*G + 0.100*B
        // G' = 0.165 + 0.224*R + 0.441*G + 0.108*B
        // B' = 0.094 + 0.222*R + 0.438*G + 0.109*B
        if let sepiaFilter = CIFilter(name: "CIColorMatrix") {
            sepiaFilter.setDefaults()
            sepiaFilter.setValue(CIVector(x: 0.207, y: 0.407, z: 0.100, w: 0.0), forKey: "inputRVector")
            sepiaFilter.setValue(CIVector(x: 0.224, y: 0.441, z: 0.108, w: 0.0), forKey: "inputGVector")
            sepiaFilter.setValue(CIVector(x: 0.222, y: 0.438, z: 0.109, w: 0.0), forKey: "inputBVector")
            sepiaFilter.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0), forKey: "inputAVector")
            sepiaFilter.setValue(CIVector(x: 0.247, y: 0.165, z: 0.094, w: 0.0), forKey: "inputBiasVector")
            layerFilters[.sepia] = sepiaFilter
        }

        // Night: same affine matrix as nightPageFragment
        // v = 0.75 - dot(rgb, (0.25, 0.25, 0.25))
        if let nightFilter = CIFilter(name: "CIColorMatrix") {
            nightFilter.setDefaults()
            nightFilter.setValue(CIVector(x: -0.25, y: -0.25, z: -0.25, w: 0.0), forKey: "inputRVector")
            nightFilter.setValue(CIVector(x: -0.25, y: -0.25, z: -0.25, w: 0.0), forKey: "inputGVector")
            nightFilter.setValue(CIVector(x: -0.25, y: -0.25, z: -0.25, w: 0.0), forKey: "inputBVector")
            nightFilter.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0), forKey: "inputAVector")
            nightFilter.setValue(CIVector(x: 0.75, y: 0.75, z: 0.75, w: 0.0), forKey: "inputBiasVector")
            layerFilters[.night] = nightFilter
        }
    }

    /// Returns the `CIFilter` to attach to `PDFPageLayer`'s tile container layer for a given `PDFViewTheme`.
    public func pageLayerFilters(for theme: PDFViewTheme) -> [Any] {
        switch theme {
        case .day:
            return []
        case .sepia, .night:
            if let filter = layerFilters[theme] {
                return [filter]
            }
            return []
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
        float3 sepia;
        sepia.r = 0.247f + 0.207f * c.r + 0.407f * c.g + 0.100f * c.b;
        sepia.g = 0.165f + 0.224f * c.r + 0.441f * c.g + 0.108f * c.b;
        sepia.b = 0.094f + 0.222f * c.r + 0.438f * c.g + 0.109f * c.b;
        return float4(clamp(sepia, 0.0f, 1.0f), c.a * in.opacity);
    }
    fragment float4 nightPageFragment(
        TextureVertexOut in [[stage_in]],
        texture2d<half, access::sample> colorTexture [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float4 c = float4(colorTexture.sample(s, in.textureCoordinate));
        float v = 0.75f - dot(c.rgb, float3(0.25f, 0.25f, 0.25f));
        v = clamp(v, 0.0f, 1.0f);
        return float4(v, v, v, c.a * in.opacity);
    }
    """
}
