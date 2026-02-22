#include <metal_stdlib>
using namespace metal;

struct VisualizerUniforms {
    float time;
    float energy;
    float reducedMotion;
    float isPlaying;
    float2 size;
    uint spectrumCount;
    uint padding;
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

float spectrumAt(constant float* spectrum, uint count, float x) {
    if (count == 0) {
        return 0.0;
    }

    float clampedX = clamp(x, 0.0, 1.0) * float(count - 1);
    uint lowIndex = uint(floor(clampedX));
    uint highIndex = min(lowIndex + 1, count - 1);
    float blend = fract(clampedX);
    return mix(spectrum[lowIndex], spectrum[highIndex], blend);
}

fragment float4 vanta_fragment(
    VertexOut in [[stage_in]],
    constant VisualizerUniforms& uniforms [[buffer(0)]],
    constant float* spectrum [[buffer(1)]]
) {
    float2 uv = in.uv;
    float energy = clamp(uniforms.energy, 0.0, 1.0);
    float reducedMotion = uniforms.reducedMotion;
    float isPlaying = uniforms.isPlaying;
    float motionScale = mix(1.0, 0.35, reducedMotion);
    float time = uniforms.time * mix(0.9, 0.55, reducedMotion);

    float drift = sin((time * 0.26) + (uv.x * 2.2)) * (0.015 * motionScale);
    float gradientProgress = smoothstep(0.0, 1.0, uv.y + drift);

    float3 lowColor = float3(0.015, 0.024, 0.042);
    float3 midColor = float3(0.042, 0.086, 0.145);
    float3 highColor = float3(0.075, 0.14, 0.205);

    float3 gradient = mix(lowColor, midColor, gradientProgress);
    gradient = mix(gradient, highColor, smoothstep(0.36, 1.0, uv.y));

    float bins = max(1.0, float(uniforms.spectrumCount));
    float snappedX = (floor(uv.x * bins) + 0.5) / bins;
    float amplitude = spectrumAt(spectrum, uniforms.spectrumCount, snappedX);
    float playbackScale = mix(0.42, 1.0, isPlaying);
    float barHeight = (0.05 + (amplitude * 0.72)) * playbackScale;

    float cell = abs(fract(uv.x * bins) - 0.5);
    float barWidthMask = smoothstep(0.5, 0.06, cell);
    float barTop = 0.08 + barHeight;
    float barSoftness = mix(0.018, 0.012, 1.0 - reducedMotion);
    float bars = barWidthMask * smoothstep(barTop, barTop - barSoftness, uv.y);

    float lineAmplitude = barHeight + (0.01 * motionScale * sin((uv.x * 18.0) + (time * 1.6)));
    float lineY = 0.1 + lineAmplitude;
    float line = smoothstep(0.02, 0.0, abs(uv.y - lineY));

    float ambiance = smoothstep(0.8, -0.1, distance(uv, float2(0.5, 0.35)));
    float vignette = smoothstep(1.05, 0.25, distance(uv, float2(0.5, 0.55)));

    float reactiveBoost = 0.2 + (energy * 0.6);
    float3 color = gradient;
    color += float3(0.03, 0.075, 0.135) * bars * reactiveBoost;
    color += float3(0.11, 0.18, 0.26) * line * (0.35 + (energy * 0.55));
    color += float3(0.02, 0.05, 0.09) * ambiance * (0.12 + energy * 0.2);
    color *= 0.82 + (0.18 * vignette);

    return float4(color, 1.0);
}
