#include <metal_stdlib>
using namespace metal;

// Reconstructed from /Applications/PDF Expert.app/Contents/Frameworks/RDPDFKit.framework/Resources/RDPDFShaders.metallib
// Functions:
// - singleColorModeVertexShader
// - multipleColorsModeVertexShader
// - texturingModeVertexShader
// - colorModeFragmentShader
// - normalTexturingModeFragmentShader
// - sepiaTexturingModeFragmentShader
// - nightTexturingModeFragmentShader

struct ColorVertexOut {
    float4 position [[position]];
    float4 color;
};

struct TextureVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float opacity;
};

vertex ColorVertexOut singleColorModeVertexShader(
    uint vertexID [[vertex_id]],
    constant float2 *vertexArray [[buffer(0)]],
    constant float4 *colorPtr [[buffer(1)]],
    constant float2 *viewportSizePtr [[buffer(2)]]
) {
    ColorVertexOut out;
    float2 pixelPos = vertexArray[vertexID];
    float2 vp = *viewportSizePtr;
    float2 ndc = (pixelPos / (vp * 0.5)) - float2(1.0, 1.0);
    ndc.y = -ndc.y;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = *colorPtr;
    return out;
}

vertex ColorVertexOut multipleColorsModeVertexShader(
    uint vertexID [[vertex_id]],
    constant float2 *vertexArray [[buffer(0)]],
    constant float4 *colorArray [[buffer(1)]],
    constant float2 *viewportSizePtr [[buffer(2)]]
) {
    ColorVertexOut out;
    float2 pixelPos = vertexArray[vertexID];
    float2 vp = *viewportSizePtr;
    float2 ndc = (pixelPos / (vp * 0.5)) - float2(1.0, 1.0);
    ndc.y = -ndc.y;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = colorArray[vertexID];
    return out;
}

vertex TextureVertexOut texturingModeVertexShader(
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

fragment float4 colorModeFragmentShader(ColorVertexOut in [[stage_in]]) {
    return in.color;
}

fragment float4 normalTexturingModeFragmentShader(
    TextureVertexOut in [[stage_in]],
    texture2d<half, access::sample> colorTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 sampleColor = float4(colorTexture.sample(textureSampler, in.textureCoordinate));
    return float4(sampleColor.rgb, sampleColor.a * in.opacity);
}

// Exact Sepia affine transformation probed from RDPDFShaders.metallib:
// White (1,1,1) -> (0.961, 0.938, 0.863) #F5EFDC
// Black (0,0,0) -> (0.247, 0.165, 0.094) #3F2A18
fragment float4 sepiaTexturingModeFragmentShader(
    TextureVertexOut in [[stage_in]],
    texture2d<half, access::sample> colorTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 c = float4(colorTexture.sample(textureSampler, in.textureCoordinate));
    float3 sepia;
    sepia.r = 0.247f + 0.207f * c.r + 0.407f * c.g + 0.100f * c.b;
    sepia.g = 0.165f + 0.224f * c.r + 0.441f * c.g + 0.108f * c.b;
    sepia.b = 0.094f + 0.222f * c.r + 0.438f * c.g + 0.109f * c.b;
    return float4(clamp(sepia, 0.0f, 1.0f), c.a * in.opacity);
}

// Exact Night transformation probed from RDPDFShaders.metallib:
// White (1,1,1) -> (0.000, 0.000, 0.000) #000000
// Black (0,0,0) -> (0.750, 0.750, 0.750) #BFBFBF
// Uses air.dot.v3f32: v = 0.75 - dot(c.rgb, float3(0.25, 0.25, 0.25))
fragment float4 nightTexturingModeFragmentShader(
    TextureVertexOut in [[stage_in]],
    texture2d<half, access::sample> colorTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 c = float4(colorTexture.sample(textureSampler, in.textureCoordinate));
    float v = 0.75f - dot(c.rgb, float3(0.25f, 0.25f, 0.25f));
    v = clamp(v, 0.0f, 1.0f);
    return float4(v, v, v, c.a * in.opacity);
}
