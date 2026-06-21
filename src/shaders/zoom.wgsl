// Freeze-frame zoom: draws the screenshot through a 2D camera (center + scale),
// with an optional flashlight spotlight at the cursor. All pixel-space inputs are
// physical pixels, matching @builtin(position), so it's correct on Retina.

struct Uniforms {
    resolution : vec2<f32>,
    cursor     : vec2<f32>,
    center     : vec2<f32>,  // image UV mapped to screen center
    scale      : f32,
    radius     : f32,        // flashlight radius, px
    flashlight : f32,        // 0 = off, 1 = on
    shadow     : f32,        // darkness outside the spotlight (0..1)
    mirror     : f32,        // 0 = normal, 1 = horizontally flipped
};

@group(0) @binding(0) var          screen_tex : texture_2d<f32>;
@group(0) @binding(1) var          screen_smp : sampler;
@group(0) @binding(2) var<uniform> u          : Uniforms;

struct VsOut {
    @builtin(position) pos : vec4<f32>,
    @location(0)       uv  : vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vid : u32) -> VsOut {
    var out : VsOut;
    let uv = vec2<f32>(f32((vid << 1u) & 2u), f32(vid & 2u));
    out.uv  = uv;
    out.pos = vec4<f32>(uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let frag = in.pos.xy;

    var screen_uv = frag / u.resolution;
    if (u.mirror > 0.5) {
        screen_uv.x = 1.0 - screen_uv.x;
    }
    let img_uv = u.center + (screen_uv - vec2<f32>(0.5)) / u.scale;
    var color = textureSample(screen_tex, screen_smp, img_uv);

    // When zoomed out (scale < 1) the view extends past the screenshot; paint
    // those margins black instead of smearing the clamped edge pixels.
    if (img_uv.x < 0.0 || img_uv.x > 1.0 || img_uv.y < 0.0 || img_uv.y > 1.0) {
        color = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }

    if (u.flashlight > 0.5) {
        let dist = distance(frag, u.cursor);
        let spot = 1.0 - smoothstep(u.radius - 12.0, u.radius, dist);
        color = vec4<f32>(color.rgb * mix(1.0 - u.shadow, 1.0, spot), color.a);
    }

    return color;
}
