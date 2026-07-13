// All MSL shader sources — + the sprite shader from
// the frozen baseline. Same lighting math, same packed vertex formats, same pass structure.

let GAME_MSL = """
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// uniforms (Swift structs mirror these layouts exactly)
// ---------------------------------------------------------------------------
struct ChunkU {
    float4x4 viewProj;
    float4x4 shadowMat;
    float4 origin;     // xyz = section origin (camera-relative), w = time
    float4 light;      // dayLight, gamma, ambient, shadowsOn
    float4 fog;        // start, end, alphaTest, globalAlpha
    float4 fogColor;
};
// split form: shared once per pass + a 16-byte per-draw origin — uniform
// copies per draw call dominated CPU encode time at thousands of sections
struct ChunkShared {
    float4x4 viewProj;
    float4x4 shadowMat;
    float4 light;      // dayLight, gamma, ambient, shadowsOn
    float4 fog;        // start, end, alphaTest, globalAlpha
    float4 fogColor;
    float4 misc;       // x = time
};
struct SkyU {
    float4x4 invViewProj;
    float4 zenith;
    float4 horizon;
    float4 horizonSun;  // rgb + sunGlow
    float4 sunDir;      // xyz + void
};
struct CelestialU {
    float4x4 viewProj;
    float4 center;      // xyz + size
    float4 right;
    float4 up;          // xyz + moonPhase (<0 = sun)
};
struct StarsU {
    float4x4 viewProj;
    float4 params;      // time, alpha
};
struct CloudU {
    float4x4 viewProj;
    float4 offset;      // xyz + scale
    float4 scroll;      // sx, sy, brightness, fogEnd
};
struct EntityU {
    float4x4 viewProj;
    float4x4 model;
    float4x4 parts[24];
    float4 light;       // sky, block, dayLight, gamma
    float4 misc;        // ambient, alpha, fogStart, fogEnd
    float4 overlay;     // hurt flash rgba
    float4 fogColor;
};
struct ParticleU {
    float4x4 viewProj;
    float4 right;
    float4 up;          // xyz + dayLight
};
struct LineU {
    float4x4 viewProj;
    float4 color;
};
struct SpriteU {
    float4x4 viewProj;
    float4 center;      // xyz + size
    float4 right;
    float4 uvRect;      // u0 v0 u1 v1
    float4 light;       // light, fogStart, fogEnd, _
    float4 fogColor;
};
struct CompositeU {
    float4 params;      // bloomAmt, warp, time, darkness
    float4 tint;
    float4 params2;     // ultraOn, aoStrength, volStrength, _
};
struct UltraU {
    float4x4 invViewProj;   // camera-relative clip → world
    float4x4 viewProj;
    float4x4 shadowMat;
    float4 sunDir;          // xyz + dayLight
    float4 params;          // time, far, shadowOK, underwater
    float4 fogColor;        // rgb + renderDistance(blocks)
    float4 texel;           // 1/w, 1/h of the ultra target
};
struct UIU {
    float4 screen;      // width, height
};

// ---------------------------------------------------------------------------
// chunk pass (opaque / cutout / translucent + shadow)
// ---------------------------------------------------------------------------
struct ChunkVIn {
    float3 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
    uint a [[attribute(2)]];
    uint b [[attribute(3)]];
};
struct ChunkVOut {
    float4 clip [[position]];
    float2 uv;
    float3 color;
    float fogDist;
    float4 shadowPos;
    float skyAmt;
    float3 worldPos;
    uint layer [[flat]];
    uint anim [[flat]];
};

constant float FACE_SHADE[6] = {0.55, 1.0, 0.8, 0.8, 0.62, 0.62};

// rotated per-pixel for soft ultra shadows
constant float2 POISSON12[12] = {
    float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696,  0.457),
    float2(-0.203,  0.621), float2( 0.962, -0.195), float2( 0.473, -0.480),
    float2( 0.519,  0.767), float2( 0.185, -0.893), float2( 0.507,  0.064),
    float2( 0.896,  0.412), float2(-0.322, -0.933), float2(-0.792, -0.598)
};

vertex ChunkVOut chunk_vs(ChunkVIn in [[stage_in]],
                          constant ChunkShared& u [[buffer(1)]],
                          constant float4& uOrigin [[buffer(2)]]) {
    uint layer = in.a & 4095u;
    uint normal = (in.a >> 12) & 7u;
    float ao = float((in.a >> 15) & 3u) / 3.0;
    float sky = float((in.a >> 17) & 15u) / 15.0;
    float blk = float((in.a >> 21) & 15u) / 15.0;
    float emissive = float((in.a >> 25) & 1u);
    float3 tint = float3(float((in.b >> 16) & 255u), float((in.b >> 8) & 255u), float(in.b & 255u)) / 255.0;
    uint anim = (in.b >> 24) & 7u;
    float time = u.misc.x;

    float3 pos = in.pos;
    float3 wpos = pos + uOrigin.xyz;
    if (anim == 5u || anim == 6u) {
        float amp = anim == 6u ? 0.06 : 0.025;
        float topFactor = anim == 6u ? clamp(1.0 - in.uv.y, 0.0, 1.0) : 1.0;
        float ph = dot(floor(wpos.xz + 0.5), float2(0.7, 1.3));
        pos.x += sin(time * 1.1 + ph) * amp * topFactor;
        pos.z += cos(time * 0.9 + ph * 1.7) * amp * topFactor;
    }
    if (anim == 1u) {
        pos.y += sin(time * 1.6 + (wpos.x + wpos.z) * 0.7) * 0.025 - 0.02;
    }

    float3 rel = pos + uOrigin.xyz;
    ChunkVOut out;
    out.clip = u.viewProj * float4(rel, 1.0);

    float dayLight = u.light.x;
    float gamma = u.light.y;
    float ambient0 = u.light.z;
    float skyBright = sky * dayLight;
    float ambient = max(ambient0, 0.03);
    float lightLevel = max(max(skyBright, blk), ambient);
    float l = lightLevel / (4.0 - 3.0 * lightLevel);
    l = mix(l, 1.0, gamma * 0.35);
    float3 skyCol = mix(float3(0.45, 0.55, 0.9), float3(1.0), clamp(dayLight, 0.0, 1.0));
    float3 blockCol = float3(1.0, 0.85, 0.62);
    float sb = skyBright, bb = blk;
    float3 lightColor = (sb + bb < 0.001) ? float3(1.0) : (skyCol * sb + blockCol * bb) / (sb + bb);
    float aoF = mix(0.42, 1.0, ao);
    out.color = tint * FACE_SHADE[normal] * aoF * max(l, emissive) * mix(lightColor, float3(1.0), emissive);
    out.skyAmt = sky * (1.0 - emissive);
    out.fogDist = length(rel.xz);
    out.uv = in.uv;
    out.layer = layer;
    out.anim = anim;
    out.worldPos = wpos;
    out.shadowPos = u.shadowMat * float4(rel, 1.0);
    return out;
}

fragment float4 chunk_fs(ChunkVOut in [[stage_in]],
                         constant ChunkShared& u [[buffer(1)]],
                         texture2d_array<float> atlas [[texture(0)]],
                         depth2d<float> shadowMap [[texture(1)]],
                         sampler atlasSmp [[sampler(0)]],
                         sampler shadowSmp [[sampler(1)]]) {
    float time = u.misc.x;
    // misc.y = 1 when a resource pack frame-animates the fluids; the procedural
    // UV scroll/warp would double-animate the art, so damp it out
    float procAnim = 1.0 - u.misc.y;
    float2 uv = in.uv;
    if (in.anim == 1u) { uv += float2(time * 0.02, time * 0.055) * procAnim; }
    else if (in.anim == 2u) {
        uv += float2(sin(time * 0.22 + in.worldPos.z * 0.5) * 0.3 + time * 0.01, time * 0.018) * procAnim;
    } else if (in.anim == 3u) {
        float a = time * 0.5 + in.worldPos.y * 0.8;
        uv += float2(sin(a) * 0.25, cos(a * 0.8) * 0.25 + time * 0.05);
    } else if (in.anim == 4u) {
        uv.y = fract(uv.y - time * 1.2 * procAnim);
    }
    float4 tex = atlas.sample(atlasSmp, uv, in.layer);
    float alphaTest = u.fog.z;
    if (alphaTest > 0.0 && tex.a < alphaTest) discard_fragment();

    float shadow = 1.0;
    float shadowsOn = u.light.w;
    float dayLight = u.light.x;
    float ultraOn = u.misc.z;
    if (shadowsOn > 0.5 && dayLight > 0.05) {
        float3 sp = in.shadowPos.xyz / in.shadowPos.w;
        // GL NDC→tex was *0.5+0.5 on xyz; Metal z is already 0..1
        float2 suv = sp.xy * 0.5 + 0.5;
        suv.y = 1.0 - suv.y;
        float inMap = (suv.x > 0.0 && suv.x < 1.0 && suv.y > 0.0 && suv.y < 1.0 && sp.z < 1.0) ? 1.0 : 0.0;
        float2 cuv = clamp(suv, float2(0.0), float2(1.0));
        float cz = clamp(sp.z, 0.0, 1.0) - 0.0012;
        float s = 0.0;
        float texel = u.misc.w > 0.0 ? u.misc.w : (1.0 / 2048.0);
        if (ultraOn > 0.5) {
            // 12-tap rotated Poisson disk — soft penumbra
            float ang = fract(sin(dot(in.clip.xy, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
            float ca = cos(ang), sa = sin(ang);
            float radius = texel * 2.2;
            for (int i = 0; i < 12; i++) {
                float2 o = POISSON12[i];
                float2 r = float2(o.x * ca - o.y * sa, o.x * sa + o.y * ca) * radius;
                s += shadowMap.sample_compare(shadowSmp, cuv + r, cz);
            }
            s /= 12.0;
        } else {
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    s += shadowMap.sample_compare(shadowSmp, cuv + float2(float(dx), float(dy)) * texel, cz);
                }
            }
            s /= 9.0;
        }
        shadow = mix(1.0, mix(0.55, 1.0, s), inMap * clamp(in.skyAmt, 0.0, 1.0) * dayLight);
    }

    float3 col = tex.rgb * in.color * shadow;
    float alpha = tex.a * u.fog.w;

    // ultra: specular sun glint + fresnel on water (anim 1)
    if (ultraOn > 0.5 && in.anim == 1u && dayLight > 0.02) {
        float2 wp = in.worldPos.xz;
        float t2 = time * 1.3;
        // two-octave procedural wave normal
        float h1 = sin(wp.x * 1.7 + t2) * cos(wp.y * 1.3 - t2 * 0.8);
        float h2 = sin(wp.x * 3.9 - t2 * 1.7 + wp.y * 2.7) * 0.45;
        float3 n = normalize(float3((h1 + h2) * 0.18, 1.0, (h1 - h2) * 0.18));
        // sun dir = shadow matrix z-row (light-space depth axis); worldPos is
        // camera-relative so the view vector is just -worldPos
        float3 sr = float3(u.shadowMat[0].z, u.shadowMat[1].z, u.shadowMat[2].z);
        float3 sunD = (u.light.w > 0.5 && dot(sr, sr) > 1e-6)
            ? normalize(sr) : normalize(float3(-0.45, 0.85, 0.18));
        if (sunD.y < 0.0) sunD = -sunD;
        float3 viewD = normalize(-in.worldPos);
        float3 hv = normalize(sunD + viewD);
        float spec = pow(max(dot(n, hv), 0.0), 90.0) * 1.6;
        float fres = pow(1.0 - clamp(viewD.y, 0.0, 1.0), 3.0);
        col += float3(1.0, 0.95, 0.82) * spec * dayLight * shadow;
        col += u.fogColor.rgb * fres * 0.18 * dayLight;
        alpha = clamp(alpha + spec * 0.5 + fres * 0.1, 0.0, 1.0);
    }

    float fogStart = u.fog.x, fogEnd = u.fog.y;
    float fog = clamp((in.fogDist - fogStart) / (fogEnd - fogStart), 0.0, 1.0);
    fog = fog * fog;
    col = mix(col, u.fogColor.rgb, fog);
    return float4(col, alpha);
}

vertex float4 shadow_vs(ChunkVIn in [[stage_in]],
                        constant ChunkShared& u [[buffer(1)]],
                        constant float4& uOrigin [[buffer(2)]]) {
    return u.shadowMat * float4(in.pos + uOrigin.xyz, 1.0);
}

// ---------------------------------------------------------------------------
// sky dome (fullscreen tri) + celestials + stars + clouds
// ---------------------------------------------------------------------------
struct SkyVOut {
    float4 clip [[position]];
    float3 dir;
};
vertex SkyVOut sky_vs(uint vid [[vertex_id]], constant SkyU& u [[buffer(1)]]) {
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    SkyVOut out;
    out.clip = float4(p, 0.99999, 1.0);
    float4 p0 = u.invViewProj * float4(p, 0.0, 1.0);
    float4 p1 = u.invViewProj * float4(p, 1.0, 1.0);
    out.dir = p1.xyz / p1.w - p0.xyz / p0.w;
    return out;
}
fragment float4 sky_fs(SkyVOut in [[stage_in]], constant SkyU& u [[buffer(1)]]) {
    float3 d = normalize(in.dir);
    float h = clamp(d.y, -1.0, 1.0);
    float t = pow(clamp(1.0 - h, 0.0, 1.0), 1.6);
    float3 col = mix(u.zenith.rgb, u.horizon.rgb, t * step(0.0, h) + step(h, 0.0));
    if (h < 0.0) col = mix(u.horizon.rgb, u.zenith.rgb * 0.35, clamp(-h * 2.2, 0.0, 1.0));
    float2 sd = u.sunDir.xz;
    float lsd = length(sd);
    float sunness = lsd < 1e-5 ? 0.0 : max(0.0, dot(normalize(d.xz), sd / lsd));
    float band = exp(-abs(h) * 5.0);
    col = mix(col, u.horizonSun.rgb, u.horizonSun.w * band * pow(sunness * 0.5 + 0.5, 3.0));
    if (u.sunDir.w > 0.5) {
        col = mix(float3(0.03, 0.025, 0.05), float3(0.09, 0.07, 0.12), clamp(h + 0.5, 0.0, 1.0));
    }
    return float4(col, 1.0);
}

struct CelVOut {
    float4 clip [[position]];
    float2 uv;
};
vertex CelVOut celestial_vs(uint vid [[vertex_id]], constant CelestialU& u [[buffer(1)]]) {
    float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1)};
    float2 a = corners[vid];
    float3 p = u.center.xyz + (a.x * u.right.xyz + a.y * u.up.xyz) * u.center.w;
    float4 cp = u.viewProj * float4(p, 1.0);
    CelVOut out;
    out.clip = float4(cp.xy, cp.w, cp.w);  // depth = far
    out.uv = a * 0.5 + 0.5;
    return out;
}
fragment float4 celestial_fs(CelVOut in [[stage_in]], constant CelestialU& u [[buffer(1)]],
                             texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    float2 d = in.uv - 0.5;
    float r = length(d) * 2.0;
    float moonPhase = u.up.w;
    float texMode = u.right.w;   // 0 = procedural; >=1 = pack art (moon: 1 + phase index)
    if (texMode > 0.5) {
        float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
        if (moonPhase >= -0.5) {
            int ph = clamp(int(texMode + 0.5) - 1, 0, 7);   // texMode = 1 + phase
            float2 cuv = uv * 0.98 + 0.01;                  // inset vs neighboring phase cells
            uv = float2((cuv.x + float(ph % 4)) / 4.0, (cuv.y + float(ph / 4)) / 2.0);
        }
        float4 t = tex.sample(smp, uv);
        return float4(t.rgb, t.a);
    }
    if (moonPhase < -0.5) {
        float disc = smoothstep(0.62, 0.55, r);
        // fade the halo to exactly zero before the quad edge — the residual
        // alpha was painting the whole billboard as a visible square
        float glow = exp(-r * 2.4) * 0.55 * smoothstep(1.0, 0.72, r);
        float3 col = float3(1.0, 0.97, 0.85) * disc + float3(1.0, 0.85, 0.6) * glow;
        return float4(col, max(disc, glow));
    } else {
        float disc = smoothstep(0.5, 0.46, r);
        float ph = moonPhase;
        float shift = (ph - 0.5) * 2.2;
        float shadow = smoothstep(0.42, 0.5, length(d * 2.0 + float2(shift, 0.0)));
        float3 col = float3(0.92, 0.94, 1.0) * disc * mix(0.12, 1.0, shadow);
        col *= 1.0 - 0.16 * smoothstep(0.2, 0.1, length(d - float2(0.1, 0.08)));
        col *= 1.0 - 0.12 * smoothstep(0.16, 0.07, length(d + float2(0.12, -0.05)));
        return float4(col, disc);
    }
}

struct StarVIn {
    float3 pos [[attribute(0)]];
    float mag [[attribute(1)]];
};
struct StarVOut {
    float4 clip [[position]];
    float size [[point_size]];
    float bright;
};
vertex StarVOut stars_vs(StarVIn in [[stage_in]], constant StarsU& u [[buffer(1)]]) {
    float4 cp = u.viewProj * float4(in.pos * 900.0, 1.0);
    StarVOut out;
    out.clip = float4(cp.xy, cp.w, cp.w);
    out.size = 1.0 + in.mag * 1.6;
    out.bright = 0.55 + 0.45 * sin(u.params.x * (1.0 + in.mag * 2.0) + in.pos.x * 50.0);
    return out;
}
fragment float4 stars_fs(StarVOut in [[stage_in]],
                         float2 pc [[point_coord]],
                         constant StarsU& u [[buffer(1)]]) {
    float2 d = pc - 0.5;
    float a = smoothstep(0.5, 0.1, length(d)) * in.bright * u.params.y;
    return float4(float3(0.95, 0.96, 1.0), a);
}

struct CloudVOut {
    float4 clip [[position]];
    float2 uv;
    float dist;
};
vertex CloudVOut cloud_vs(uint vid [[vertex_id]], constant CloudU& u [[buffer(1)]]) {
    float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1)};
    float2 a = corners[vid];
    float3 p = float3(a.x * u.offset.w, 0.0, a.y * u.offset.w) + u.offset.xyz;
    CloudVOut out;
    out.clip = u.viewProj * float4(p, 1.0);
    out.uv = a * 0.5 + 0.5;
    out.dist = length(p.xz);
    return out;
}
fragment float4 cloud_fs(CloudVOut in [[stage_in]],
                         constant CloudU& u [[buffer(1)]],
                         texture2d<float> cloudTex [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float c = cloudTex.sample(smp, in.uv * 12.0 + u.scroll.xy).r;
    if (c < 0.5) discard_fragment();
    float fogEnd = u.scroll.w;
    float fade = 1.0 - clamp((in.dist - fogEnd * 0.7) / (fogEnd * 0.6), 0.0, 1.0);
    return float4(float3(u.scroll.z), 0.72 * fade);
}

// ---------------------------------------------------------------------------
// entities (14 posed parts)
// ---------------------------------------------------------------------------
struct EntityVIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
    float part [[attribute(3)]];
};
struct EntityVOut {
    float4 clip [[position]];
    float2 uv;
    float light;
    float3 normal;
    float fogDist;
};
vertex EntityVOut entity_vs(EntityVIn in [[stage_in]], constant EntityU& u [[buffer(1)]]) {
    float4x4 part = u.parts[int(in.part + 0.5)];
    float4 wp = u.model * part * float4(in.pos, 1.0);
    EntityVOut out;
    out.clip = u.viewProj * wp;
    out.uv = in.uv;
    float sky = u.light.x / 15.0 * u.light.z;
    float lightLevel = max(max(sky, u.light.y / 15.0), max(u.misc.x, 0.03));
    float l = lightLevel / (4.0 - 3.0 * lightLevel);
    out.light = mix(l, 1.0, u.light.w * 0.35);
    float3x3 m3 = float3x3(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz);
    float3x3 p3 = float3x3(part[0].xyz, part[1].xyz, part[2].xyz);
    out.normal = m3 * p3 * in.normal;
    out.fogDist = length(wp.xz);
    return out;
}
fragment float4 entity_fs(EntityVOut in [[stage_in]],
                          constant EntityU& u [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    float4 t = tex.sample(smp, in.uv);
    if (t.a < 0.1) discard_fragment();
    float3 n = normalize(in.normal);
    float shade = 0.62 + 0.38 * clamp(n.y * 0.7 + 0.55, 0.0, 1.0);
    float3 col = t.rgb * in.light * shade;
    col = mix(col, u.overlay.rgb, u.overlay.a);
    float fog = clamp((in.fogDist - u.misc.z) / (u.misc.w - u.misc.z), 0.0, 1.0);
    col = mix(col, u.fogColor.rgb, fog * fog);
    return float4(col, t.a * u.misc.y);
}

// ---------------------------------------------------------------------------
// particles (instanced billboards)
// ---------------------------------------------------------------------------
struct ParticleVIn {
    float2 corner [[attribute(0)]];
    float3 pos [[attribute(1)]];
    float4 uvRect [[attribute(2)]];
    float layerSize [[attribute(3)]];
    float4 colorLight [[attribute(4)]];
};
struct ParticleVOut {
    float4 clip [[position]];
    float2 uv;
    float4 color;
    uint layer [[flat]];
};
vertex ParticleVOut particle_vs(ParticleVIn in [[stage_in]], constant ParticleU& u [[buffer(2)]]) {
    float layer = floor(in.layerSize / 256.0);
    float size = fmod(in.layerSize, 256.0) / 100.0;
    float3 p = in.pos + (in.corner.x * u.right.xyz + in.corner.y * u.up.xyz) * size;
    ParticleVOut out;
    out.clip = u.viewProj * float4(p, 1.0);
    out.uv = mix(in.uvRect.xy, in.uvRect.zw, in.corner * 0.5 + 0.5);
    float light = in.colorLight.a;
    float dayLight = u.up.w;
    float l = max(light * dayLight, 0.06);
    l = l / (4.0 - 3.0 * l);
    out.color = float4(in.colorLight.rgb * max(l, 0.25), 1.0);
    out.layer = uint(layer);
    return out;
}
fragment float4 particle_fs(ParticleVOut in [[stage_in]],
                            texture2d_array<float> atlas [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    float4 tex = atlas.sample(smp, in.uv, in.layer);
    if (tex.a < 0.3) discard_fragment();
    return float4(tex.rgb * in.color.rgb, tex.a);
}

// ---------------------------------------------------------------------------
// lines (selection outline, beams)
// ---------------------------------------------------------------------------
struct LineVOut { float4 clip [[position]]; };
vertex LineVOut line_vs(const device packed_float3* pts [[buffer(0)]],
                        uint vid [[vertex_id]],
                        constant LineU& u [[buffer(1)]]) {
    LineVOut out;
    out.clip = u.viewProj * float4(float3(pts[vid]), 1.0);
    return out;
}
fragment float4 line_fs(LineVOut in [[stage_in]], constant LineU& u [[buffer(1)]]) {
    return u.color;
}

// ---------------------------------------------------------------------------
// item sprites (billboarded item icons)
// ---------------------------------------------------------------------------
struct SpriteVOut {
    float4 clip [[position]];
    float2 uv;
    float dist;
};
vertex SpriteVOut sprite_vs(uint vid [[vertex_id]], constant SpriteU& u [[buffer(1)]]) {
    float2 corners[6] = {float2(-0.5, 0), float2(0.5, 0), float2(0.5, 1), float2(-0.5, 0), float2(0.5, 1), float2(-0.5, 1)};
    float2 a = corners[vid];
    float3 pos = u.center.xyz + u.right.xyz * a.x * u.center.w + float3(0.0, 1.0, 0.0) * a.y * u.center.w;
    SpriteVOut out;
    out.uv = float2(mix(u.uvRect.x, u.uvRect.z, a.x + 0.5), mix(u.uvRect.w, u.uvRect.y, a.y));
    out.dist = length(pos);
    out.clip = u.viewProj * float4(pos, 1.0);
    return out;
}
fragment float4 sprite_fs(SpriteVOut in [[stage_in]],
                          constant SpriteU& u [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    float4 c = tex.sample(smp, in.uv);
    if (c.a < 0.1) discard_fragment();
    float fog = clamp((in.dist - u.light.y) / max(u.light.z - u.light.y, 0.001), 0.0, 1.0);
    return float4(mix(c.rgb * u.light.x, u.fogColor.rgb, fog), c.a);
}

// ---------------------------------------------------------------------------
// composite: scene + bloom + warp + tint + darkness + tonemap
// ---------------------------------------------------------------------------
struct FSVOut {
    float4 clip [[position]];
    float2 uv;
};
vertex FSVOut fs_vs(uint vid [[vertex_id]]) {
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    FSVOut out;
    out.clip = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}
// title screen wordmark: positioned quad, straight-alpha blend
struct LogoU {
    float4 rect;   // x0,y0,x1,y1 in NDC
};
vertex FSVOut logo_vs(uint vid [[vertex_id]], constant LogoU& u [[buffer(1)]]) {
    float2 corners[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
    float2 c = corners[vid];
    FSVOut out;
    out.clip = float4(mix(u.rect.x, u.rect.z, c.x), mix(u.rect.y, u.rect.w, c.y), 0.0, 1.0);
    out.uv = float2(c.x, 1.0 - c.y);
    return out;
}
fragment float4 logo_fs(FSVOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}

// title screen: aspect-filled photo + vignette so menu text pops
fragment float4 title_fs(FSVOut in [[stage_in]],
                         constant float4& tu [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float2 uv = in.uv * tu.xy + tu.zw;
    float3 c = tex.sample(smp, uv).rgb;
    float2 d = in.uv - 0.5;
    float vig = 1.0 - dot(d, d) * 0.7;
    c *= vig * 0.9;
    return float4(c, 1.0);
}
fragment float4 bloom_extract_fs(FSVOut in [[stage_in]],
                                 texture2d<float> scene [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
    float3 c = scene.sample(smp, in.uv).rgb;
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    float k = smoothstep(0.62, 0.95, lum);
    return float4(c * k, 1.0);
}
fragment float4 blur_fs(FSVOut in [[stage_in]],
                        constant CompositeU& u [[buffer(1)]],
                        texture2d<float> tex [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    float2 dir = u.tint.xy;   // reuse tint.xy as blur dir
    float3 c = tex.sample(smp, in.uv).rgb * 0.227;
    c += tex.sample(smp, in.uv + dir * 1.384).rgb * 0.316;
    c += tex.sample(smp, in.uv - dir * 1.384).rgb * 0.316;
    c += tex.sample(smp, in.uv + dir * 3.230).rgb * 0.07;
    c += tex.sample(smp, in.uv - dir * 3.230).rgb * 0.07;
    return float4(c, 1.0);
}
// ---------------------------------------------------------------------------
// ultra pass: half-res SSAO (alpha) + shadow-marched volumetric light (rgb)
// ---------------------------------------------------------------------------
static float3 ultraWorldPos(float2 uv, float depth, constant UltraU& u) {
    float4 ndc = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    float4 p = u.invViewProj * ndc;
    return p.xyz / p.w;     // camera-relative world position
}

fragment float4 ultra_fs(FSVOut in [[stage_in]],
                         constant UltraU& u [[buffer(1)]],
                         depth2d<float> depthTex [[texture(0)]],
                         depth2d<float> shadowMap [[texture(1)]],
                         sampler dsmp [[sampler(0)]],
                         sampler shadowSmp [[sampler(1)]]) {
    float depth = depthTex.sample(dsmp, in.uv);
    float3 wpos = ultraWorldPos(in.uv, depth, u);
    float dist = length(wpos);
    float3 rayDir = wpos / max(dist, 1e-5);
    bool isSky = depth >= 0.99999;
    float dayLight = u.sunDir.w;
    float time = u.params.x;

    // --- SSAO: hemisphere of world-space offsets, depth-compared in screen space
    float ao = 1.0;
    if (!isSky && dist < 140.0) {
        // screen-space normal from depth derivatives (real target texel —
        // a hardcoded 960x540 was wrong at every other drawable size)
        float2 px = u.texel.xy;
        float3 pR = ultraWorldPos(in.uv + float2(px.x, 0.0), depthTex.sample(dsmp, in.uv + float2(px.x, 0.0)), u);
        float3 pD = ultraWorldPos(in.uv + float2(0.0, px.y), depthTex.sample(dsmp, in.uv + float2(0.0, px.y)), u);
        float3 nrm = normalize(cross(pD - wpos, pR - wpos));
        float ang0 = fract(sin(dot(in.uv * 961.0, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
        float occ = 0.0;
        const int TAPS = 8;
        for (int i = 0; i < TAPS; i++) {
            float a = ang0 + float(i) * 2.399963;           // golden-angle spiral
            float r = (float(i) + 0.7) / float(TAPS);
            float rad = 0.65 * r;
            float3 t = float3(cos(a), 0.0, sin(a));
            float3 tang = normalize(t - nrm * dot(t, nrm));
            float3 sp = wpos + (tang * rad + nrm * rad * 0.55);
            float4 cp = u.viewProj * float4(sp, 1.0);
            if (cp.w <= 0.0) continue;
            float2 suv = float2(cp.x / cp.w * 0.5 + 0.5, 0.5 - cp.y / cp.w * 0.5);
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;
            float sd = depthTex.sample(dsmp, suv);
            float3 spos = ultraWorldPos(suv, sd, u);
            float3 dvec = spos - wpos;
            float dlen = length(dvec);
            if (dlen < 0.001) continue;
            float occA = max(0.0, dot(nrm, dvec / dlen) - 0.08);
            float fall = 1.0 - clamp(dlen / 1.6, 0.0, 1.0);
            occ += occA * fall;
        }
        ao = clamp(1.0 - occ / float(TAPS) * 2.4, 0.0, 1.0);
        ao = mix(ao, 1.0, clamp(dist / 140.0, 0.0, 1.0));   // fade with distance
    }

    // --- volumetric light: march the camera ray, sample the shadow map
    float3 vol = float3(0.0);
    if (u.params.z > 0.5 && dayLight > 0.05) {
        float3 sr = float3(u.shadowMat[0].z, u.shadowMat[1].z, u.shadowMat[2].z);
        float3 sunD = normalize(dot(sr, sr) > 1e-6 ? sr : float3(0.0, 1.0, 0.0));
        if (sunD.y < 0.0) sunD = -sunD;
        float cosA = dot(rayDir, sunD);
        // Henyey-Greenstein-ish forward scattering
        float g = 0.62;
        float phase = (1.0 - g * g) / (4.0 * 3.14159 * pow(1.0 + g * g - 2.0 * g * cosA, 1.5));
        float marchEnd = min(isSky ? u.params.y : dist, 72.0);
        const int STEPS = 18;
        float dither = fract(sin(dot(in.uv * 917.0, float2(36.887, 19.781))) * 24634.6345);
        float lit = 0.0;
        for (int i = 0; i < STEPS; i++) {
            float f = (float(i) + dither) / float(STEPS);
            f = f * f;                                     // denser near camera
            float3 p = rayDir * (f * marchEnd);
            float4 sc = u.shadowMat * float4(p, 1.0);
            float3 sp = sc.xyz / sc.w;
            float2 suv = float2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
            if (suv.x <= 0.0 || suv.x >= 1.0 || suv.y <= 0.0 || suv.y >= 1.0 || sp.z >= 1.0) {
                lit += 0.6;        // outside the map: assume lit
                continue;
            }
            lit += shadowMap.sample_compare(shadowSmp, suv, clamp(sp.z, 0.0, 1.0) - 0.0015);
        }
        lit /= float(STEPS);
        float strength = 0.55 * dayLight * phase;
        vol = float3(1.0, 0.92, 0.74) * lit * strength;
    }
    return float4(vol, ao);
}

/// gaussian blur that PRESERVES alpha (the AO channel)
fragment float4 ultra_blur_fs(FSVOut in [[stage_in]],
                              constant CompositeU& u [[buffer(1)]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    float2 dir = u.tint.xy;
    float4 c = tex.sample(smp, in.uv) * 0.227;
    c += tex.sample(smp, in.uv + dir * 1.384) * 0.316;
    c += tex.sample(smp, in.uv - dir * 1.384) * 0.316;
    c += tex.sample(smp, in.uv + dir * 3.230) * 0.07;
    c += tex.sample(smp, in.uv - dir * 3.230) * 0.07;
    return c;
}

static float3 acesTonemap(float3 c) {
    c *= 0.92;
    return clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
}

fragment float4 composite_fs(FSVOut in [[stage_in]],
                             constant CompositeU& u [[buffer(1)]],
                             texture2d<float> scene [[texture(0)]],
                             texture2d<float> bloom [[texture(1)]],
                             texture2d<float> ultra [[texture(2)]],
                             sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float warp = u.params.y, time = u.params.z;
    if (warp > 0.001) {
        uv += float2(sin(uv.y * 14.0 + time * 2.2), cos(uv.x * 12.0 + time * 1.8)) * 0.012 * warp;
    }
    float3 c = scene.sample(smp, uv).rgb;
    float ultraOn = u.params2.x;
    if (ultraOn > 0.5) {
        float4 ul = ultra.sample(smp, uv);
        c *= mix(1.0, ul.a, u.params2.y);          // SSAO
        c += ul.rgb * u.params2.z;                 // volumetric light
    }
    c += bloom.sample(smp, uv).rgb * u.params.x;
    c = mix(c, u.tint.rgb, u.tint.a);
    float darkness = u.params.w;
    if (darkness > 0.001) {
        float d = distance(uv, float2(0.5));
        c *= mix(1.0, clamp(0.25 - d, 0.0, 0.25) * 4.0, darkness);
    }
    if (ultraOn > 0.5) {
        c = acesTonemap(c);
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(lum), c, 1.12);             // gentle saturation lift
    } else {
        c = c / (1.0 + c * 0.12);
    }
    return float4(c, 1.0);
}

// ---------------------------------------------------------------------------
// UI 2D: textured + vertex-colored quads in pixel space
// ---------------------------------------------------------------------------
struct UIVIn {
    float2 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
    float4 color [[attribute(2)]];
};
struct UIVOut {
    float4 clip [[position]];
    float2 uv;
    float4 color;
};
vertex UIVOut ui_vs(UIVIn in [[stage_in]], constant UIU& u [[buffer(1)]]) {
    UIVOut out;
    out.clip = float4(in.pos.x / u.screen.x * 2.0 - 1.0, 1.0 - in.pos.y / u.screen.y * 2.0, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}
fragment float4 ui_fs(UIVOut in [[stage_in]],
                      texture2d<float> tex [[texture(0)]],
                      sampler smp [[sampler(0)]]) {
    float4 t = tex.sample(smp, in.uv);
    return t * in.color;
}
"""
