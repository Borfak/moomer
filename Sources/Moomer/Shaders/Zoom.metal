#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 cursor;
    float2 center;
    float scale;
    float radius;
    float flashlight;
    float shadow;
    float mirror;
    float padding;
};

vertex float4 zoomVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1u) & 2u, id & 2u);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

fragment float4 zoomFragment(float4 position [[position]],
    texture2d<float> image [[texture(0)]], constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = position.xy / u.resolution;
    if (u.mirror > 0.5) uv.x = 1 - uv.x;
    float2 source = u.center + (uv - 0.5) / u.scale;
    float4 color = image.sample(linearSampler, source);
    if (any(source < 0) || any(source > 1)) color = float4(0, 0, 0, 1);
    if (u.flashlight > 0.5) {
        float spot = 1 - smoothstep(max(0.0f, u.radius - 12), u.radius, distance(position.xy, u.cursor));
        color.rgb *= mix(1 - u.shadow, 1.0f, spot);
    }
    return float4(color.rgb, 1);
}
