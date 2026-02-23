#include <metal_stdlib>
using namespace metal;

struct RibbonUniforms {
    float time;
    float energy;
    float reducedMotion;
    float isPlaying;
    float2 size;
    uint spectrumCount;
    float debugFPS;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

VertexOut makeRibbonVertex(uint vertexID) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2(1.0, -1.0),
        float2(-1.0, 1.0),
        float2(1.0, 1.0)
    };

    float2 uvs[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

vertex VertexOut ribbon_vertex(uint vertexID [[vertex_id]]) {
    return makeRibbonVertex(vertexID);
}

float spectrumAt(constant float* spectrum, uint count, float x) {
    if (count == 0) {
        return 0.0;
    }

    float scaled = clamp(x, 0.0, 1.0) * float(count - 1);
    uint lowerIndex = uint(floor(scaled));
    uint upperIndex = min(lowerIndex + 1, count - 1);
    float blend = fract(scaled);
    return mix(spectrum[lowerIndex], spectrum[upperIndex], blend);
}

float4 renderRibbon(
    VertexOut in,
    constant RibbonUniforms& uniforms,
    constant float* spectrum
) {
    float2 uv = in.uv;
    float energy = clamp(uniforms.energy, 0.0, 1.0);
    float reducedMotion = clamp(uniforms.reducedMotion, 0.0, 1.0);
    float isPlaying = clamp(uniforms.isPlaying, 0.0, 1.0);

    float motionScale = mix(1.0, 0.35, reducedMotion);
    float time = uniforms.time * mix(0.95, 0.58, reducedMotion);

    float bins = max(1.0, float(uniforms.spectrumCount));
    float halfStep = 0.5 / bins;

    float center = spectrumAt(spectrum, uniforms.spectrumCount, uv.x);
    float previous = spectrumAt(spectrum, uniforms.spectrumCount, uv.x - halfStep);
    float next = spectrumAt(spectrum, uniforms.spectrumCount, uv.x + halfStep);
    float amplitude = clamp((center * 0.62) + (previous * 0.19) + (next * 0.19), 0.0, 1.0);

    float idleWeight = clamp((1.0 - isPlaying) + (0.18 - energy) * 2.8, 0.0, 1.0);
    float idleFlow = idleWeight * (
        (0.015 * sin((uv.x * 7.4) + (time * 0.36 * motionScale))) +
        (0.006 * sin((uv.x * 3.1) - (time * 0.17 * motionScale)))
    );

    float bandHeight = 0.2 + (amplitude * (0.44 + (energy * 0.2)));
    float centerY = bandHeight + idleFlow;

    float thickness = 0.055 + (amplitude * 0.12) + (energy * 0.06) + (idleWeight * 0.012);
    float softness = mix(0.016, 0.024, reducedMotion);

    float distanceToCenter = abs(uv.y - centerY);
    float ribbonMask = 1.0 - smoothstep(thickness, thickness + softness, distanceToCenter);

    float ridgeY = centerY + (thickness * 0.78);
    float ridgeMask = smoothstep(0.012, 0.0, abs(uv.y - ridgeY));

    float glowMask = 1.0 - smoothstep(thickness * 2.2, thickness * 4.6, distanceToCenter);
    float trailingFade = smoothstep(0.0, 0.42, uv.y);

    float backgroundDrift = 0.012 * sin((uv.x * 2.4) + (time * 0.21 * motionScale));
    float gradientProgress = smoothstep(0.0, 1.0, uv.y + backgroundDrift);

    float3 lowColor = float3(0.013, 0.018, 0.03);
    float3 midColor = float3(0.027, 0.056, 0.09);
    float3 highColor = float3(0.038, 0.084, 0.13);
    float3 background = mix(lowColor, midColor, gradientProgress);
    background = mix(background, highColor, smoothstep(0.33, 1.0, uv.y));

    float3 ribbonCore = mix(float3(0.11, 0.24, 0.42), float3(0.19, 0.43, 0.7), amplitude);
    float3 ribbonHighlight = mix(float3(0.35, 0.58, 0.8), float3(0.74, 0.89, 0.98), 0.45 + (energy * 0.35));

    float bodyIntensity = ribbonMask * (0.4 + (amplitude * 0.9));
    float glowIntensity = glowMask * trailingFade * (0.08 + (energy * 0.35));
    float ridgeIntensity = ridgeMask * (0.18 + (energy * 0.42));

    float3 color = background;
    color += ribbonCore * bodyIntensity;
    color += float3(0.1, 0.23, 0.38) * glowIntensity;
    color += ribbonHighlight * ridgeIntensity;

    float ambientPulse = 0.94 + (0.06 * sin((time * 0.24) + (uv.x * 1.1)) * motionScale);
    color *= ambientPulse;

    float vignette = smoothstep(1.14, 0.34, distance(uv, float2(0.5, 0.52)));
    color *= 0.82 + (0.18 * vignette);

    return float4(color, 1.0);
}

fragment float4 ribbon_fragment(
    VertexOut in [[stage_in]],
    constant RibbonUniforms& uniforms [[buffer(0)]],
    constant float* spectrum [[buffer(1)]]
) {
    return renderRibbon(in, uniforms, spectrum);
}
