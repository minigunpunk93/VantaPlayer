#include <metal_stdlib>
using namespace metal;

struct VisualizerUniforms {
    float time;
    float energy;
    float reducedMotion;
    float2 size;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vanta_vertex(uint vertexID [[vertex_id]]) {
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

float horizontalMotif(float2 uv, float time, float energy, float reducedMotion) {
    float speed = mix(0.5, 0.24, reducedMotion);
    float wave = sin((uv.x * 8.0) + (time * speed) + (uv.y * 4.5));
    float center = 0.56 + wave * (0.08 + energy * 0.16);
    float thickness = 0.01 + (1.0 - energy) * 0.004;
    return smoothstep(thickness, 0.0, abs(uv.y - center));
}

fragment float4 vanta_fragment(
    VertexOut in [[stage_in]],
    constant VisualizerUniforms& uniforms [[buffer(0)]]
) {
    float2 uv = in.uv;
    float energy = clamp(uniforms.energy, 0.0, 1.0);
    float reducedMotion = uniforms.reducedMotion;
    float time = uniforms.time;

    float drift = sin((time * 0.22) + (uv.x * 2.5)) * (0.02 - (reducedMotion * 0.01));
    float gradientProgress = smoothstep(0.0, 1.0, uv.y + drift);

    float3 lowColor = float3(0.02, 0.03, 0.06);
    float3 midColor = float3(0.06, 0.12, 0.19);
    float3 highColor = float3(0.09, 0.18, 0.27);

    float3 gradient = mix(lowColor, midColor, gradientProgress);
    gradient = mix(gradient, highColor, smoothstep(0.42, 1.0, uv.y));

    float stripeDensity = 22.0;
    float stripePhase = time * mix(0.48, 0.22, reducedMotion);
    float stripe = abs(fract((uv.x * stripeDensity) + stripePhase) - 0.5);
    float barMask = smoothstep(0.52, 0.08, uv.y);
    float bars = smoothstep(0.24, 0.0, stripe) * (0.09 + energy * 0.22) * barMask;

    float motif = horizontalMotif(uv, time, energy, reducedMotion) * (0.2 + energy * 0.45);
    float vignette = smoothstep(1.1, 0.3, distance(uv, float2(0.5, 0.52)));

    float3 color = gradient;
    color += float3(0.06, 0.11, 0.18) * bars;
    color += float3(0.10, 0.17, 0.24) * motif;
    color *= 0.82 + (0.18 * vignette);

    return float4(color, 1.0);
}
