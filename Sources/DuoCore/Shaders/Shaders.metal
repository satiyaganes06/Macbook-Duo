#include <metal_stdlib>
using namespace metal;

// Keep in sync with EffectUniforms in FoldRenderer.swift (eight 32-bit floats).
struct EffectUniforms {
    float tilt;          // Duo: radians, positive = top edge toward the viewer
    float viewDistance;  // Duo: in pane heights
    float viewerHeight;  // Duo: in pane heights
    float blurLevel;     // 0 = sharp source, up to 4 = coarsest pyramid level
    float brightness;    // 0 = black, 1 = untouched
    float progress;      // eased effect progress, 0 = at rest, 1 = closed
    float aspect;        // drawable width / height
    float pad0;
};

struct VOut {
    float4 position [[position]];
    float2 uv;           // (0,0) = top-left of the desktop image
};

// Every style must return exactly the desktop when progress == 0: the overlay
// appears over the live desktop and any difference would show as a pop.

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------
vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = float2((pos[vid].x + 1.0) * 0.5, 1.0 - (pos[vid].y + 1.0) * 0.5);
    return o;
}

// Samples the blur pyramid with a continuous level (mix between adjacent levels).
static float3 sampleDesktop(array<texture2d<float>, 5> levels, float2 uv, float blurLevel) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float b = clamp(blurLevel, 0.0, 4.0);
    uint i = uint(floor(b));
    float f = fract(b);
    float3 c = levels[i].sample(s, uv).rgb;
    if (f > 0.001 && i < 4) {
        c = mix(c, levels[i + 1].sample(s, uv).rgb, f);
    }
    return c;
}

// Bilinear 2x2 box downsample (the destination is half the source size).
fragment float4 downsampleFragment(VOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}

// Separable 9-tap Gaussian using the linear-sampling trick (5 fetches).
fragment float4 blurFragment(VOut in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             constant float2 &direction [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    float2 d = direction * texel;
    float4 c = src.sample(s, in.uv) * 0.2270270270;
    c += src.sample(s, in.uv + d * 1.3846153846) * 0.3162162162;
    c += src.sample(s, in.uv - d * 1.3846153846) * 0.3162162162;
    c += src.sample(s, in.uv + d * 3.2307692308) * 0.0702702703;
    c += src.sample(s, in.uv - d * 3.2307692308) * 0.0702702703;
    return c;
}

// Reduce Motion / Fade style: a plain black veil (premultiplied alpha).
fragment float4 fadeFragment(VOut in [[stage_in]],
                             constant float &opacity [[buffer(0)]]) {
    return float4(0.0, 0.0, 0.0, clamp(opacity, 0.0, 1.0));
}

// ---------------------------------------------------------------------------
// Duo: a rigid pane rotating about its bottom edge (the hinge), seen by a
// stationary viewer and projected back onto the physical screen plane.
// Mirrors FoldGeometry.swift; that file carries the derivation and the tests.
// ---------------------------------------------------------------------------
vertex VOut foldVertex(uint vid [[vertex_id]],
                       constant EffectUniforms &u [[buffer(0)]]) {
    // Triangle strip: bottom-left, bottom-right, top-left, top-right.
    float2 corners[4] = { float2(-1.0, 0.0), float2(1.0, 0.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    float2 c = corners[vid];

    float ct = cos(u.tilt);
    float st = sin(u.tilt);
    float y3 = c.y * ct;                    // height after rotation
    float z3 = c.y * st;                    // depth toward the viewer
    float w = max(1.0 - z3 / u.viewDistance, 1e-3);

    // Projected NDC (before the divide): x' = x / w, y' = vh + (y3 - vh) / w.
    // Emitting clip = (ndc * w, 0, w) keeps perspective-correct interpolation.
    float clipX = c.x;
    float clipY = (u.viewerHeight * w + (y3 - u.viewerHeight)) * 2.0 - w;

    VOut o;
    o.position = float4(clipX, clipY, 0.0, w);
    o.uv = float2((c.x + 1.0) * 0.5, 1.0 - c.y);
    return o;
}

fragment float4 foldFragment(VOut in [[stage_in]],
                             array<texture2d<float>, 5> levels [[texture(0)]],
                             constant EffectUniforms &u [[buffer(0)]]) {
    float3 c = sampleDesktop(levels, in.uv, u.blurLevel);
    return float4(c * u.brightness, 1.0);
}

// ---------------------------------------------------------------------------
// Shutter: six rigid horizontal panels. Closing pushes each panel down behind
// the one beneath it until the stack sits on the hinge. The front panel's top
// edge casts a soft contact shadow onto the panel sliding in behind it.
// ---------------------------------------------------------------------------
fragment float4 shutterFragment(VOut in [[stage_in]],
                                array<texture2d<float>, 5> levels [[texture(0)]],
                                constant EffectUniforms &u [[buffer(0)]]) {
    const int N = 6;
    float p = clamp(u.progress, 0.0, 1.0);
    float y = 1.0 - in.uv.y;                // pane coords, hinge at 0
    float h = 1.0 / float(N);
    int panel = -1;
    for (int i = 0; i < N; i++) {           // lowest panel is frontmost
        float bottom = float(i) * h * (1.0 - p);
        if (y >= bottom && y < bottom + h) { panel = i; break; }
    }
    if (panel < 0) {
        return float4(0.0, 0.0, 0.0, 1.0);  // wall behind the stack
    }
    float yOrig = y + p * float(panel) * h;
    float3 c = sampleDesktop(levels, float2(in.uv.x, 1.0 - yOrig), u.blurLevel);
    if (panel > 0) {
        float frontTop = float(panel - 1) * h * (1.0 - p) + h;
        float d = y - frontTop;             // distance above the front panel's edge
        float strength = min(1.0, p * 4.0);
        float shadow = (1.0 - smoothstep(0.0, 0.045, d)) * 0.5 * strength;
        float edge = (1.0 - smoothstep(0.0, 0.0035, d)) * 0.4 * strength;
        c *= (1.0 - shadow) * (1.0 - edge);
    }
    return float4(c * u.brightness, 1.0);
}

// ---------------------------------------------------------------------------
// Iris: eight dark blades, each a half-plane tangent to a shrinking aperture,
// rotating a restrained 35° as they close. Blades have a bevelled lit edge,
// seams where they overlap, and cast a contact shadow onto the desktop.
// ---------------------------------------------------------------------------
fragment float4 irisFragment(VOut in [[stage_in]],
                             array<texture2d<float>, 5> levels [[texture(0)]],
                             constant EffectUniforms &u [[buffer(0)]]) {
    const int K = 8;
    float p = clamp(u.progress, 0.0, 1.0);
    float2 c = float2((in.uv.x - 0.5) * u.aspect, 0.5 - in.uv.y);
    float halfDiagonal = length(float2(u.aspect * 0.5, 0.5));
    float r = halfDiagonal * 1.03 * (1.0 - min(1.0, p / 0.94));   // fully shut by 94%
    float twist = p * 0.6;

    float m1 = -1e9, m2 = -1e9;             // largest and second-largest blade reach
    for (int k = 0; k < K; k++) {
        float a = 6.28318530718 * float(k) / float(K) + twist;
        float d = dot(c, float2(cos(a), sin(a)));
        if (d > m1) { m2 = m1; m1 = d; } else if (d > m2) { m2 = d; }
    }
    float strength = min(1.0, p * 6.0);
    float inside = r - m1;                  // > 0 inside the aperture
    float bladeMix = 1.0 - smoothstep(-0.0015, 0.0015, inside);

    float3 desk = sampleDesktop(levels, in.uv, u.blurLevel);
    desk *= 1.0 - (1.0 - smoothstep(0.0, 0.07, inside)) * 0.55 * strength;

    float over = m1 - r;
    float3 blade = float3(0.075) + float3(0.06) * (1.0 - smoothstep(0.0, 0.25, over));
    blade += float3(0.16) * (1.0 - smoothstep(0.0, 0.004, over));   // lit bevel
    float seam = m1 - m2;
    blade *= 1.0 - 0.6 * (1.0 - smoothstep(0.0, 0.012, seam));       // overlap seam

    float3 col = mix(desk, blade, bladeMix);
    return float4(col * u.brightness, 1.0);
}

// ---------------------------------------------------------------------------
// Roll: a roller rises out of the hinge and the desktop winds down onto it like
// a retracting projector screen. The wrapped part is shaded as a cylinder lit
// from the top-front; the flat sheet gets a contact shadow above the roller.
// ---------------------------------------------------------------------------
fragment float4 rollFragment(VOut in [[stage_in]],
                             array<texture2d<float>, 5> levels [[texture(0)]],
                             constant EffectUniforms &u [[buffer(0)]]) {
    float p = clamp(u.progress, 0.0, 1.0);
    float y = 1.0 - in.uv.y;
    float R = 0.07 + 0.05 * p;              // the roll thickens as it winds
    float rise = smoothstep(0.0, 0.1, p);   // roller emerges during the first 10%
    float yTop = 2.0 * R * rise;
    float yC = yTop - R;
    float w = max(0.0, (p - 0.1) / 0.9);
    float wound = w * w * (3.0 - 2.0 * w) * (1.05 + 2.0 * R);

    float3 col;
    if (y >= yTop) {
        float yOrig = y + wound;
        if (yOrig > 1.0) {
            col = float3(0.0);              // sheet already wound past here
        } else {
            col = sampleDesktop(levels, float2(in.uv.x, 1.0 - yOrig), u.blurLevel);
            float d = y - yTop;
            col *= 1.0 - (1.0 - smoothstep(0.0, 0.05, d)) * 0.45 * rise;
        }
    } else {
        float cosA = clamp((y - yC) / R, -1.0, 1.0);
        float a = acos(cosA);               // angle from the top of the roller
        float yOrig = yTop + wound - R * a; // arc length along the wrapped sheet
        float shade = 0.12 + 0.88 * max(0.0, 0.55 * cosA + 0.83 * sin(a));
        float3 base = (yOrig >= 0.0 && yOrig <= 1.0)
            ? sampleDesktop(levels, float2(in.uv.x, 1.0 - yOrig), u.blurLevel)
            : float3(0.16, 0.16, 0.17);     // bare roller
        col = base * shade;
    }
    return float4(col * u.brightness, 1.0);
}

// ---------------------------------------------------------------------------
// Accordion: five horizontal pleats fold like a paper map and collapse toward
// the hinge. Faces alternate toward/away from the light, creases darken, and
// a mild foreshortening sells the tilt of each pleat.
// ---------------------------------------------------------------------------
fragment float4 accordionFragment(VOut in [[stage_in]],
                                  array<texture2d<float>, 5> levels [[texture(0)]],
                                  constant EffectUniforms &u [[buffer(0)]]) {
    const int N = 5;
    float p = clamp(u.progress, 0.0, 1.0);
    float theta = p * 1.5;                  // fold angle, up to ~86°
    float H = cos(theta);                   // collapsed stack height
    float y = 1.0 - in.uv.y;
    if (y >= H) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float st = sin(theta);
    float f = y / H * float(N);
    int k = int(floor(f));
    float t = fract(f);
    float dir = (k % 2 == 0) ? 1.0 : -1.0;
    float tp = clamp(t + dir * 0.35 * st * t * (1.0 - t), 0.0, 1.0);
    float yOrig = (float(k) + tp) / float(N);
    float3 col = sampleDesktop(levels, float2(in.uv.x, 1.0 - yOrig), u.blurLevel);
    float face = (dir > 0.0) ? 1.0 + 0.12 * st : 1.0 - 0.42 * st;
    float edge = min(t, 1.0 - t);
    float crease = 1.0 - 0.4 * st * (1.0 - smoothstep(0.0, 0.2, edge));
    col *= face * crease;
    return float4(col * u.brightness, 1.0);
}
