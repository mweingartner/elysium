// All MSL shader sources — + the sprite shader from
// the frozen baseline. Same lighting math, same packed vertex formats, same pass structure.

let GAME_MSL = ELYSIUM_ENVIRONMENT_MSL + """
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
    float4 heldLight;  // rgb = torch color * intensity, w = radius in blocks (w<=0 disables)
    float4 worldOrigin; // camera world position; w = Reduce Motion
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
struct EnvironmentRenderUniforms {
    float4x4 inverseViewProjection;
    ElyAtmosphereU atmosphere;
    float4 viewport; // width, height, reciprocal width, reciprocal height
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
    float4 params2;     // ultraOn, aoStrength, volStrength, ray-traced HDR tone mapping
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
    float3 faceNormal [[flat]];
    float3 materialTint;
    uint layer [[flat]];
    uint anim [[flat]];
};

constant float FACE_SHADE[6] = {0.55, 1.0, 0.8, 0.8, 0.62, 0.62};
constant float3 FACE_NORMAL[6] = {
    float3(0,-1,0), float3(0,1,0), float3(0,0,-1),
    float3(0,0,1), float3(-1,0,0), float3(1,0,0)
};

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
    float3 absolutePos = wpos + u.worldOrigin.xyz;
    if (anim == 5u || anim == 6u) {
        float amp = anim == 6u ? 0.06 : 0.025;
        float topFactor = anim == 6u ? clamp(1.0 - in.uv.y, 0.0, 1.0) : 1.0;
        float ph = dot(floor(absolutePos.xz + 0.5), float2(0.7, 1.3));
        pos.x += sin(time * 1.1 + ph) * amp * topFactor;
        pos.z += cos(time * 0.9 + ph * 1.7) * amp * topFactor;
    }
    // Water's shared mesher corner heights are authoritative. Animate optical
    // normals rather than independently displacing top/side faces into gaps.

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
    out.faceNormal = FACE_NORMAL[min(normal, 5u)];
    out.materialTint = tint;
    out.shadowPos = u.shadowMat * float4(rel, 1.0);
    return out;
}

static float4 shadeChunk(ChunkVOut in, constant ChunkShared& u,
                         texture2d_array<float> atlas, depth2d<float> shadowMap,
                         sampler atlasSmp, sampler shadowSmp) {
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

    // Held torch: a moving point light at the player. Rendering is camera-relative so the
    // player sits at the origin and in.worldPos is already the offset from the eye — the
    // torch is just a smooth radial falloff of distance, added like a warm block light. No
    // voxel-light re-propagation. A gentle flicker keeps the flame alive.
    if (u.heldLight.w > 0.0) {
        float d = length(in.worldPos);
        float t = clamp(1.0 - d / u.heldLight.w, 0.0, 1.0);
        t *= t;
        float flicker = 0.9 + 0.1 * sin(u.misc.x * 11.0) * sin(u.misc.x * 4.3 + 1.7);
        col += tex.rgb * u.heldLight.rgb * (t * flicker);
    }

    float alpha = tex.a * u.fog.w;

    float fogStart = u.fog.x, fogEnd = u.fog.y;
    float fog = clamp((in.fogDist - fogStart) / (fogEnd - fogStart), 0.0, 1.0);
    fog = fog * fog;
    col = mix(col, u.fogColor.rgb, fog);
    return float4(col, alpha);
}

fragment float4 chunk_fs(ChunkVOut in [[stage_in]],
                         constant ChunkShared& u [[buffer(1)]],
                         texture2d_array<float> atlas [[texture(0)]],
                         depth2d<float> shadowMap [[texture(1)]],
                         sampler atlasSmp [[sampler(0)]],
                         sampler shadowSmp [[sampler(1)]]) {
    return shadeChunk(in, u, atlas, shadowMap, atlasSmp, shadowSmp);
}

// Color behind the nearest water interface belongs in its refraction snapshot. Front-facing
// glass remains for the ordinary later translucent pass, so it is neither hidden nor doubled.
fragment float4 translucent_refraction_fs(ChunkVOut in [[stage_in]],
                         constant ChunkShared& u [[buffer(1)]],
                         texture2d_array<float> atlas [[texture(0)]],
                         depth2d<float> shadowMap [[texture(1)]],
                         depth2d<float> waterSurfaceDepth [[texture(4)]],
                         sampler atlasSmp [[sampler(0)]],
                         sampler shadowSmp [[sampler(1)]]) {
    constexpr sampler depthSmp(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 viewport = float2(waterSurfaceDepth.get_width(), waterSurfaceDepth.get_height());
    float waterDepth = waterSurfaceDepth.sample(depthSmp, in.clip.xy / viewport);
    // About two depth32 ULPs near the far plane: a 1e-5 bias swallowed whole submerged
    // blocks at distance, after which the later water depth test also hid their glass.
    if (waterDepth >= 0.99999 || in.clip.z <= waterDepth + 1.2e-7) discard_fragment();
    return shadeChunk(in, u, atlas, shadowMap, atlasSmp, shadowSmp);
}

static float3 environmentWorldPosition(float2 uv, float depth,
                                        constant EnvironmentRenderUniforms& e) {
    float4 clip = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    float4 position = e.inverseViewProjection * clip;
    return position.xyz / max(abs(position.w), 1e-7) * (position.w < 0.0 ? -1.0 : 1.0);
}

// Dedicated resolved water pass. The opaque color/depth pair is a completed, separate target;
// neither shader samples the color/depth attachments to which this pass is currently writing.
fragment float4 water_fs(ChunkVOut in [[stage_in]],
                         constant ChunkShared& u [[buffer(1)]],
                         constant EnvironmentRenderUniforms& e [[buffer(3)]],
                         texture2d_array<float> atlas [[texture(0)]],
                         depth2d<float> shadowMap [[texture(1)]],
                         texture2d<float> opaqueColor [[texture(2)]],
                         depth2d<float> opaqueDepth [[texture(3)]],
                         sampler atlasSmp [[sampler(0)]],
                         sampler shadowSmp [[sampler(1)]]) {
    constexpr sampler colorSmp(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler depthSmp(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 screenUV = in.clip.xy * e.viewport.zw;
    float3 worldPosition = in.worldPos + u.worldOrigin.xyz;
    float time = e.atmosphere.options.y > 0.5 ? 0.0 : e.atmosphere.cameraTime.w;
    float3 view = elySafeDirection(-in.worldPos, float3(0,1,0));
    float3 normal = elyWaterNormal(worldPosition, in.faceNormal, time, e.atmosphere.weather.x);
    if (dot(normal, view) < 0.0) normal = -normal;
    bool underwater = e.atmosphere.weather.w > 0.5;
    float etaI = underwater ? 1.333 : 1.0, etaT = underwater ? 1.0 : 1.333;
    float fresnel = elyDielectricFresnel(dot(normal, view), etaI, etaT);
    float sceneDepth = opaqueDepth.sample(depthSmp, screenUV);
    float transmittedDepth = sceneDepth;
    float3 scenePosition = environmentWorldPosition(screenUV, sceneDepth, e);
    float thickness = sceneDepth < 0.99999 ? length(scenePosition - in.worldPos) : 32.0;
    thickness = clamp(thickness, 0.0, 128.0);

    float3 refractedRay = refract(-view, normal, etaI / etaT);
    float4 refractedClip = u.viewProj * float4(in.worldPos + refractedRay * min(thickness, 8.0), 1.0);
    float2 refractedUV = screenUV;
    if (refractedClip.w > 0.001 && dot(refractedRay, refractedRay) > 0.01) {
        float2 projected = float2(refractedClip.x / refractedClip.w * 0.5 + 0.5,
                                 0.5 - refractedClip.y / refractedClip.w * 0.5);
        refractedUV += clamp(projected - screenUV, float2(-0.015), float2(0.015));
        float candidateDepth = opaqueDepth.sample(depthSmp, refractedUV);
        // Never pull the bank/foreground object across the water's silhouette. This also avoids
        // sampling an offscreen clamped edge as though it were a real transmitted ray hit.
        if (candidateDepth <= in.clip.z + 1.2e-7 || any(refractedUV <= 0.0) || any(refractedUV >= 1.0)) {
            refractedUV = screenUV;
        } else {
            transmittedDepth = candidateDepth;
            if (candidateDepth < 0.99999) {
                scenePosition = environmentWorldPosition(refractedUV, candidateDepth, e);
                thickness = clamp(length(scenePosition - in.worldPos), 0.0, 128.0);
            }
        }
    }
    float3 background = opaqueColor.sample(colorSmp, refractedUV).rgb;
    if (underwater && transmittedDepth >= 0.99999 && dot(refractedRay, refractedRay) > 0.01) {
        // The submerged raster camera suppresses its sky pass. A ray leaving the water must
        // nevertheless see the air-side sky through Snell's window, not the fog-clear color.
        background = elyAtmosphereRadianceAir(worldPosition + refractedRay * 0.02,
                                              refractedRay, e.atmosphere, true);
    }
    float travelInWater = underwater ? length(in.worldPos) : thickness;
    float3 transmission = elyWaterTransmittance(travelInWater, in.materialTint);
    float3 transmitted = background * transmission
        + elyWaterScattering(transmission, in.materialTint, e.atmosphere.sunDaylight.w);

    // Keep the resource-pack ripple detail as a restrained modulation, not a solid blue overlay
    // which would hide the actual refracted Faithful terrain under a shallow stream.
    float2 atlasUV = in.uv + float2(time * 0.02, time * 0.055) * (1.0 - u.misc.y);
    float4 art = atlas.sample(atlasSmp, atlasUV, in.layer);
    float textureDetail = dot(art.rgb, float3(0.299, 0.587, 0.114));
    transmitted *= mix(0.92, 1.08, textureDetail);
    float3 reflected = elyAtmosphereRadiance(worldPosition + normal * 0.02,
                                            reflect(-view, normal), e.atmosphere, true);
    if (underwater) reflected *= transmission;
    float3 color = mix(transmitted, reflected, fresnel);

    float shadow = 1.0;
    if (u.light.w > 0.5) {
        float3 sp = in.shadowPos.xyz / max(in.shadowPos.w, 0.001);
        float2 uv = float2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
        if (all(uv > 0.0) && all(uv < 1.0) && sp.z > 0.0 && sp.z < 1.0) {
            shadow = shadowMap.sample_compare(shadowSmp, uv, sp.z - 0.0012);
        }
    }
    float3 sun = elySafeDirection(e.atmosphere.sunDaylight.xyz, float3(0,1,0));
    float3 halfVector = elySafeDirection(view + sun, normal);
    float specular = pow(max(dot(normal, halfVector), 0.0), 180.0)
        * smoothstep(0.0, 0.12, sun.y) * e.atmosphere.sunDaylight.w * shadow;
    color += elySunRadiance(e.atmosphere) * specular * 0.35
        * elyCloudSunTransmittance(worldPosition, e.atmosphere);
    if (!underwater && in.faceNormal.y > 0.65) {
        float verticalDepth = max(0.0, in.worldPos.y - scenePosition.y);
        float foam = sceneDepth < 0.99999 ? elyWaterFoam(verticalDepth, worldPosition, time, e.atmosphere.weather.x) : 0.0;
        color = mix(color, float3(0.74,0.82,0.83) * max(0.12, e.atmosphere.sunDaylight.w), foam);
    }
    float fog = clamp((in.fogDist - u.fog.x) / max(u.fog.y - u.fog.x, 0.001), 0.0, 1.0);
    return float4(mix(max(color, float3(0)), u.fogColor.rgb, fog * fog), 1.0);
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

fragment float4 cloud_volume_fs(FSVOut in [[stage_in]],
                                constant EnvironmentRenderUniforms& e [[buffer(3)]],
                                depth2d<float> sceneDepth [[texture(0)]]) {
    constexpr sampler depthSmp(coord::normalized, address::clamp_to_edge, filter::nearest);
    float depth = sceneDepth.sample(depthSmp, in.uv);
    float3 rayEnd = environmentWorldPosition(in.uv, depth, e);
    float3 direction = elySafeDirection(rayEnd, float3(0,1,0));
    float maximumDistance = depth >= 0.99999 ? e.atmosphere.clouds.z : length(rayEnd);
    float4 cloud = elyCloudLayer(e.atmosphere.cameraTime.xyz, direction, e.atmosphere, maximumDistance);
    return float4(cloud.rgb, 1.0 - cloud.a);
}

// Upsample only compatible cloud samples. Full-resolution geometry decides whether there is any
// cloud in front of the pixel; a half-resolution neighbor must not paint a halo over a roof/tree.
fragment float4 cloud_composite_fs(FSVOut in [[stage_in]],
                                   constant EnvironmentRenderUniforms& e [[buffer(3)]],
                                   texture2d<float> cloudLayer [[texture(0)]],
                                   depth2d<float> sceneDepth [[texture(1)]]) {
    constexpr sampler nearestSmp(coord::normalized, address::clamp_to_edge, filter::nearest);
    if (!elyCloudsEnabledForRay(e.atmosphere, false)) return float4(0);
    float depth = sceneDepth.sample(nearestSmp, in.uv);
    bool isSky = depth >= 0.99999;
    float3 rayEnd = environmentWorldPosition(in.uv, depth, e);
    float3 direction = elySafeDirection(rayEnd, float3(0,1,0));
    float distance = length(rayEnd);
    float maximumDistance = isSky ? e.atmosphere.clouds.z : distance;
    float nearT, farT;
    if (!elyCloudInterval(e.atmosphere.cameraTime.xyz, direction, e.atmosphere,
                          maximumDistance, nearT, farT)) return float4(0);

    int2 size = int2(cloudLayer.get_width(), cloudLayer.get_height());
    float2 grid = in.uv * float2(size) - 0.5;
    int2 base = int2(floor(grid));
    float2 fraction = fract(grid);
    float4 accumulated = float4(0);
    float totalWeight = 0.0;
    for (int y = 0; y < 2; ++y) {
        for (int x = 0; x < 2; ++x) {
            int2 pixel = clamp(base + int2(x,y), int2(0), size - 1);
            float2 sampleUV = (float2(pixel) + 0.5) / float2(size);
            float neighborDepth = sceneDepth.sample(nearestSmp, sampleUV);
            bool neighborIsSky = neighborDepth >= 0.99999;
            if (neighborIsSky != isSky) continue;
            if (!isSky) {
                float neighborDistance = length(environmentWorldPosition(sampleUV, neighborDepth, e));
                if (abs(neighborDistance - distance) > max(2.0, distance * 0.025)) continue;
            }
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                         * (y == 0 ? 1.0 - fraction.y : fraction.y);
            accumulated += cloudLayer.read(uint2(pixel)) * weight;
            totalWeight += weight;
        }
    }
    if (totalWeight > 0.0001) return accumulated / totalWeight;
    // A subpixel gap may have no compatible low-resolution neighbor. Shade that rare boundary
    // directly instead of smearing an occluded neighbor into it or leaving a dark cloud hole.
    float4 exact = elyCloudLayer(e.atmosphere.cameraTime.xyz, direction, e.atmosphere, maximumDistance);
    return float4(exact.rgb, 1.0 - exact.a);
}

struct RayResolvedOutput {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};
fragment RayResolvedOutput ray_resolve_fs(FSVOut in [[stage_in]],
                                         texture2d<float> radiance [[texture(0)]],
                                         texture2d<float> rayDepth [[texture(1)]]) {
    constexpr sampler linearSmp(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestSmp(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 color = radiance.sample(linearSmp, in.uv).rgb;
    float depth = rayDepth.sample(nearestSmp, in.uv).r;
    RayResolvedOutput out;
    out.color = float4(all(isfinite(color)) ? max(color, float3(0)) : float3(0), 1);
    out.depth = isfinite(depth) ? clamp(depth, 0.0, 1.0) : 1.0;
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
    if (ultraOn > 0.5 || u.params2.w > 0.5) {
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
