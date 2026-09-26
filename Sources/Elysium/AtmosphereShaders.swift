import simd

/// Shared raster/path-tracing environment. Positions passed to the shader helpers are absolute
/// world positions, even when the geometry buffers themselves are camera-relative. Eight float4s
/// deliberately keep the Swift/MSL ABI simple; no simulation state or RNG is consumed here.
struct AtmosphereUniforms {
    var cameraTime = SIMD4<Float>(0, 0, 0, 0)
    var sunDaylight = SIMD4<Float>(0, 1, 0, 1)
    var zenith = SIMD4<Float>(0.45, 0.65, 1, 0)
    var horizon = SIMD4<Float>(0.74, 0.84, 1, 0)
    var fogColor = SIMD4<Float>(0.74, 0.84, 1, 0)
    var weather = SIMD4<Float>(0, 0, 1, 0) // rain, thunder, clouds enabled, underwater
    var clouds = SIMD4<Float>(192, 304, 8192, 16) // bottom, top, far distance, march steps
    var options = SIMD4<Float>(0, 0, 1, 0) // dimension (0/1/2), reduce motion, sun disc, reserved
}

/// Physical optics and a bounded atmospheric layer shared by primary/secondary ray misses and
/// raster water/clouds. The cloud result is premultiplied radiance plus remaining transmittance,
/// not ordinary alpha: composite with `layer.rgb + background * layer.a`.
let ELYSIUM_ENVIRONMENT_MSL = """
#include <metal_stdlib>
using namespace metal;

struct ElyAtmosphereU {
    float4 cameraTime;
    float4 sunDaylight;
    float4 zenith;
    float4 horizon;
    float4 fogColor;
    float4 weather;
    float4 clouds;
    float4 options;
};

static float3 elySafeDirection(float3 v, float3 fallback) {
    float l2 = dot(v, v);
    return l2 > 1e-12 ? v * rsqrt(l2) : fallback;
}

static uint elyAtmosphereHash(uint3 p) {
    uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u ^ p.z * 0xcb1ab31fu;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu;
    return h ^ (h >> 16);
}

static float elyAtmosphereHashValue(int3 p) {
    return float(elyAtmosphereHash(as_type<uint3>(p)) & 0x00ffffffu) / 16777215.0;
}

static float elyCloudNoise(float3 p) {
    int3 cell = int3(floor(p));
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(elyAtmosphereHashValue(cell), elyAtmosphereHashValue(cell + int3(1,0,0)), f.x);
    float b = mix(elyAtmosphereHashValue(cell + int3(0,1,0)), elyAtmosphereHashValue(cell + int3(1,1,0)), f.x);
    float c = mix(elyAtmosphereHashValue(cell + int3(0,0,1)), elyAtmosphereHashValue(cell + int3(1,0,1)), f.x);
    float d = mix(elyAtmosphereHashValue(cell + int3(0,1,1)), elyAtmosphereHashValue(cell + int3(1,1,1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

static bool elyCloudsEnabledForRay(constant ElyAtmosphereU& e, bool rayInAir) {
    return e.options.x < 0.5 && e.weather.z > 0.5 && (rayInAir || e.weather.w < 0.5)
        && e.clouds.y > e.clouds.x && e.clouds.z > 0.0;
}

static float elyCloudDensity(float3 worldPosition, constant ElyAtmosphereU& e) {
    float height = (worldPosition.y - e.clouds.x) / max(e.clouds.y - e.clouds.x, 1.0);
    if (height <= 0.0 || height >= 1.0) return 0.0;
    // A slow prevailing wind, not camera translation, transports the field. Coordinates are
    // continuous across chunks and across zero/negative world coordinates.
    float time = e.options.y > 0.5 ? 0.0 : e.cameraTime.w;
    float3 p = worldPosition + float3(time * 0.42, 0.0, time * 0.13);
    float broad = elyCloudNoise(float3(p.x * 0.004, 0.71, p.z * 0.004));
    float billow = elyCloudNoise(p * 0.014 + float3(17.1, 3.8, 9.3));
    float erosion = elyCloudNoise(p * 0.042 + float3(2.4, 17.2, 31.8));
    float rain = clamp(e.weather.x, 0.0, 1.0);
    // The large field locates separated weather cells; isotropic 3D noise supplies the actual
    // rounded billows. A rising threshold rounds off each varying-height top instead of slicing
    // a mostly two-dimensional mask into identical, thin horizontal pancakes.
    float coverage = mix(0.50, 0.29, rain);
    float shape = broad * 0.30 + billow * 0.70
        - smoothstep(0.28, 1.0, height) * 0.24 - (1.0 - erosion) * 0.065;
    float body = smoothstep(coverage, coverage + 0.12, shape);
    float envelope = smoothstep(0.0, 0.07, height) * (1.0 - smoothstep(0.85, 1.0, height));
    return body * envelope * mix(0.062, 0.083, rain);
}

static bool elyCloudInterval(float3 origin, float3 direction, constant ElyAtmosphereU& e,
                             float maximumDistance, thread float& nearT, thread float& farT) {
    float limit = min(max(maximumDistance, 0.0), clamp(e.clouds.z, 0.0, 16384.0));
    if (abs(direction.y) < 1e-5) {
        if (origin.y <= e.clouds.x || origin.y >= e.clouds.y) return false;
        nearT = 0.0; farT = min(limit, 2048.0);
    } else {
        float a = (e.clouds.x - origin.y) / direction.y;
        float b = (e.clouds.y - origin.y) / direction.y;
        nearT = max(0.0, min(a, b)); farT = min(limit, max(a, b));
    }
    return farT > nearT;
}

// Six samples of the same density field attenuate sunlight both on world surfaces and within
// clouds. A bounded path prevents grazing sun directions from exploding GPU work.
static float elyCloudSunTransmittanceForRay(float3 worldPosition, constant ElyAtmosphereU& e,
                                           bool rayInAir, int sampleCount = 6) {
    if (!elyCloudsEnabledForRay(e, rayInAir)) return 1.0;
    float3 sun = elySafeDirection(e.sunDaylight.xyz, float3(0,1,0));
    if (sun.y <= 0.001) return 1.0;
    float a, b;
    if (!elyCloudInterval(worldPosition, sun, e, e.clouds.z, a, b)) return 1.0;
    b = min(b, a + 1800.0);
    float step = (b - a) / float(sampleCount);
    float opticalDepth = 0.0;
    for (int i = 0; i < 6; ++i) {
        if (i >= sampleCount) break;
        opticalDepth += elyCloudDensity(worldPosition + sun * (a + (float(i) + 0.5) * step), e) * step;
    }
    return exp(-min(opticalDepth, 24.0));
}

float elyCloudSunTransmittance(float3 worldPosition, constant ElyAtmosphereU& e) {
    return elyCloudSunTransmittanceForRay(worldPosition, e, false);
}

float elyCloudSunTransmittanceAir(float3 worldPosition, constant ElyAtmosphereU& e) {
    return elyCloudSunTransmittanceForRay(worldPosition, e, true);
}

static float3 elySunRadiance(constant ElyAtmosphereU& e) {
    float3 sun = elySafeDirection(e.sunDaylight.xyz, float3(0,1,0));
    return mix(float3(1.0, 0.45, 0.19), float3(1.0, 0.96, 0.86), smoothstep(0.0, 0.35, sun.y));
}

static float4 elyCloudLayerForRay(float3 worldOrigin, float3 rayDirection, constant ElyAtmosphereU& e,
                                float maximumDistance, bool rayInAir) {
    if (!elyCloudsEnabledForRay(e, rayInAir)) return float4(0,0,0,1);
    float3 direction = elySafeDirection(rayDirection, float3(0,1,0));
    float a, b;
    if (!elyCloudInterval(worldOrigin, direction, e, maximumDistance, a, b)) return float4(0,0,0,1);
    // Stop at the actual density fade boundary. Spreading sixteen samples across an 8 km
    // grazing slab while only its first 2 km are visible undersamples it into horizontal bands.
    float visibleDistance = min(2200.0, max(1600.0, e.clouds.z));
    b = min(b, visibleDistance);
    if (b <= a) return float4(0,0,0,1);
    int steps = clamp(max(int(e.clouds.w), int(ceil((b - a) / 22.0))), 8, 32);
    float step = (b - a) / float(steps);
    float3 sun = elySafeDirection(e.sunDaylight.xyz, float3(0,1,0));
    float daylight = clamp(e.sunDaylight.w, 0.0, 1.5);
    float sunVisible = smoothstep(-0.03, 0.10, sun.y) * daylight;
    float rain = clamp(e.weather.x, 0.0, 1.0);
    float thunder = clamp(e.weather.y, 0.0, 1.0);
    float cosine = clamp(dot(direction, sun), -1.0, 1.0);
    // Bounded forward lobe supplies silver linings without unbounded highlights/fireflies.
    float phase = 0.82 + 0.36 * pow(max(cosine, 0.0), 8.0);
    // Water droplets scatter light repeatedly. A white, daylight-driven fill prevents the
    // unlit side of a fair-weather cloud becoming a dark blue storm cloud at midday.
    float3 ambient = (e.zenith.rgb * 0.13 + e.horizon.rgb * 0.12
        + float3(0.30,0.31,0.33) * daylight + float3(0.006,0.008,0.013))
        * mix(1.0, 0.58, thunder);
    float3 radiance = float3(0);
    float transmittance = 1.0;
    // Stable angular jitter removes coherent slab-sampling bands at grazing angles. It consumes
    // no frame RNG and therefore does not flicker while the camera is stationary.
    float jitter = elyAtmosphereHashValue(int3(floor(direction * 2048.0)));
    for (int i = 0; i < 32; ++i) {
        if (i >= steps || transmittance < 0.008) break;
        float t = a + (float(i) + jitter) * step;
        float3 position = worldOrigin + direction * t;
        float density = elyCloudDensity(position, e);
        // Unresolved, kilometre-distant cloud detail dissolves into the atmospheric horizon,
        // rather than creating repeated sharp stripes from a very long, shallow slab crossing.
        density *= 1.0 - smoothstep(750.0, visibleDistance, t);
        if (density < 0.0001) continue;
        float stepTransmission = exp(-min(density * step, 20.0));
        // Three broad samples suffice for the soft internal illumination; terrain shadows use
        // the full six-sample helper. This bounds the cost of the secondary march per view step.
        float sunTransmission = elyCloudSunTransmittanceForRay(position, e, rayInAir, 3);
        float3 light = ambient + elySunRadiance(e)
            * (sunVisible * (0.24 + 0.90 * sqrt(sunTransmission)) * phase);
        light *= mix(1.0, 0.53, rain);
        float aerial = smoothstep(1200.0, max(1600.0, e.clouds.z), t);
        light = mix(light, e.horizon.rgb, aerial * 0.80);
        radiance += transmittance * (1.0 - stepTransmission) * light;
        transmittance *= stepTransmission;
    }
    return float4(max(radiance, float3(0)), clamp(transmittance, 0.0, 1.0));
}

float4 elyCloudLayer(float3 worldOrigin, float3 rayDirection, constant ElyAtmosphereU& e,
                     float maximumDistance) {
    return elyCloudLayerForRay(worldOrigin, rayDirection, e, maximumDistance, false);
}

static float3 elyAtmosphereRadianceForRay(float3 worldOrigin, float3 rayDirection,
                                         constant ElyAtmosphereU& e, bool includeSun, bool rayInAir) {
    float3 d = elySafeDirection(rayDirection, float3(0,1,0));
    if (e.options.x > 0.5) {
        return mix(e.horizon.rgb, e.zenith.rgb, clamp(d.y * 0.5 + 0.5, 0.0, 1.0));
    }
    if (!rayInAir && e.weather.w > 0.5) return max(e.fogColor.rgb * 0.65, float3(0.003));
    float horizonWeight = pow(1.0 - clamp(d.y, 0.0, 1.0), 1.6);
    float3 sky = mix(e.zenith.rgb, e.horizon.rgb, horizonWeight);
    if (d.y < 0.0) sky *= mix(1.0, 0.38, smoothstep(0.0, 0.75, -d.y));
    float3 sun = elySafeDirection(e.sunDaylight.xyz, float3(0,1,0));
    float daylight = clamp(e.sunDaylight.w, 0.0, 1.5);
    float rain = clamp(e.weather.x, 0.0, 1.0);
    float dusk = (1.0 - smoothstep(0.02, 0.34, abs(sun.y))) * (1.0 - rain);
    float solarDirection = max(dot(d, sun), 0.0);
    sky += elySunRadiance(e) * (dusk * pow(solarDirection, 12.0) * exp(-abs(d.y) * 5.0) * 0.40);
    if (includeSun && e.options.z > 0.5) {
        float sunVisible = smoothstep(-0.02, 0.06, sun.y);
        float disc = smoothstep(cos(0.010), cos(0.006), dot(d, sun));
        sky += elySunRadiance(e) * (disc * 10.0 * sunVisible * (1.0 - rain * 0.96));
        float moon = smoothstep(cos(0.012), cos(0.009), dot(d, -sun));
        sky += float3(0.51, 0.578, 0.714) * moon * smoothstep(-0.02, 0.06, -sun.y) * (1.0 - rain);
        float3 stars = d * 580.0;
        float starHash = elyAtmosphereHashValue(int3(floor(stars)));
        float star = step(0.998, starHash) * (1.0 - smoothstep(0.07, 0.22, length(fract(stars) - 0.5)));
        sky += float3(0.60, 0.67, 0.80) * star * (1.0 - clamp(daylight * 2.0, 0.0, 1.0)) * (1.0 - rain);
    }
    float4 cloud = elyCloudLayerForRay(worldOrigin, d, e, e.clouds.z, rayInAir);
    return max(cloud.rgb + sky * cloud.a, float3(0));
}

float3 elyAtmosphereRadiance(float3 worldOrigin, float3 rayDirection,
                            constant ElyAtmosphereU& e, bool includeSun) {
    return elyAtmosphereRadianceForRay(worldOrigin, rayDirection, e, includeSun, false);
}

// A secondary ray can exit water while the camera remains submerged. Its medium, not the
// camera's UI/fog flag, then selects atmospheric sky/clouds. No constant-uniform copy is needed.
float3 elyAtmosphereRadianceAir(float3 worldOrigin, float3 rayDirection,
                               constant ElyAtmosphereU& e, bool includeSun) {
    return elyAtmosphereRadianceForRay(worldOrigin, rayDirection, e, includeSun, true);
}

// Band-limited water surface shared by raster and ray tracing. Eight directional waves span
// 9 to 0.5 blocks; phase speed follows deep-water dispersion (omega = sqrt(g k), scaled for
// block-sized ponds) and every frequency is an exact multiple of 2*pi/1800 s, so the render
// clock's 30-minute wrap is seamless. A wave shorter than twice the pixel footprint fades out;
// its slope variance becomes roughness instead of aliasing into sparkle at distance.
// The caller supplies the real face normal: waterfall sides and the underside must not be
// shaded as upward-facing ocean surfaces. A sloped (flowing) top advects along its downhill.
struct ElyWaterSurface {
    float3 normal;
    float variance;
    float laplacian;
};

constant float4 elyWaterWaves[8] = {
    // wavelength (blocks), slope amplitude, direction offset (radians), phase
    float4(9.00, 0.034,  0.00, 0.0),
    float4(5.90, 0.030,  0.85, 1.7),
    float4(3.90, 0.027, -0.70, 3.1),
    float4(2.60, 0.023,  1.55, 4.4),
    float4(1.70, 0.019, -1.35, 0.9),
    float4(1.13, 0.015,  0.35, 2.6),
    float4(0.75, 0.011, -2.20, 5.3),
    float4(0.49, 0.008,  2.60, 3.8)
};

static float elyWaterWaveWeight(float wavelength, float footprint) {
    return footprint > 0.0 ? clamp(wavelength / (2.0 * footprint) - 0.5, 0.0, 1.0) : 1.0;
}

static float3 elyWaterWaveField(float2 p, float time, float footprint, float strength) {
    // x,y: slope; z: height Laplacian. Accumulated variance is returned separately by the caller.
    float2 slope = float2(0.0);
    float laplacian = 0.0;
    const float wind = 0.38;
    for (int i = 0; i < 8; ++i) {
        float4 w = elyWaterWaves[i];
        float weight = elyWaterWaveWeight(w.x, footprint);
        if (weight <= 0.0) continue;
        float k = 6.28318530718 / w.x;
        float omega = rint(sqrt(3.2 * k) * 1800.0 / 6.28318530718) * (6.28318530718 / 1800.0);
        float angle = wind + w.z;
        float2 direction = float2(cos(angle), sin(angle));
        float phase = dot(p, direction) * k - omega * time + w.w;
        float amplitude = w.y * strength * weight;
        slope += direction * (cos(phase) * amplitude);
        laplacian -= sin(phase) * amplitude * k;
    }
    return float3(slope, laplacian);
}

static float elyWaterRemovedVariance(float footprint, float strength) {
    float variance = 0.0;
    for (int i = 0; i < 8; ++i) {
        float weight = elyWaterWaveWeight(elyWaterWaves[i].x, footprint);
        float amplitude = elyWaterWaves[i].y * strength;
        variance += (1.0 - weight * weight) * amplitude * amplitude * 0.5;
    }
    return variance;
}

ElyWaterSurface elyWaterSurface(float3 worldPosition, float3 geometricNormal, float time, float rain,
                                float footprint) {
    ElyWaterSurface result;
    float3 n = elySafeDirection(geometricNormal, float3(0,1,0));
    float strength = mix(1.0, 1.65, clamp(rain, 0.0, 1.0));
    if (abs(n.y) > 0.65) {
        float orientation = n.y >= 0.0 ? 1.0 : -1.0;
        float2 downhill = -n.xz * orientation;
        float3 field;
        if (dot(downhill, downhill) > 0.0004) {
            // Two half-period-offset advected copies cross-fade, so flow never jumps.
            float2 flow = normalize(downhill) * 1.1;
            float cycle = 2.0;
            float phase0 = fract(time / cycle), phase1 = fract(time / cycle + 0.5);
            float blend = abs(2.0 * phase0 - 1.0);
            float3 a = elyWaterWaveField(worldPosition.xz - flow * (phase0 * cycle), time, footprint, strength);
            float3 b = elyWaterWaveField(worldPosition.xz - flow * (phase1 * cycle), time, footprint, strength);
            field = mix(a, b, blend);
        } else {
            field = elyWaterWaveField(worldPosition.xz, time, footprint, strength);
        }
        result.normal = normalize(n + float3(-field.x, 0.0, -field.y) * orientation);
        result.laplacian = field.z;
        result.variance = elyWaterRemovedVariance(footprint, strength);
        return result;
    }
    float3 tangent = elySafeDirection(cross(float3(0,1,0), n), float3(1,0,0));
    float verticalWeight = elyWaterWaveWeight(1.1, footprint);
    float verticalFlow = sin(worldPosition.y * 5.7 + time * 5.2 + dot(worldPosition, tangent) * 1.8);
    result.normal = normalize(n + tangent * (verticalFlow * 0.065 * strength * verticalWeight));
    result.laplacian = 0.0;
    result.variance = (1.0 - verticalWeight * verticalWeight) * 0.065 * 0.065 * strength * strength * 0.5;
    return result;
}

float3 elyWaterNormal(float3 worldPosition, float3 geometricNormal, float time, float rain) {
    return elyWaterSurface(worldPosition, geometricNormal, time, rain, 0.0).normal;
}

// Exact unpolarized dielectric reflectance, including total internal reflection on water exit.
float elyDielectricFresnel(float cosineIncident, float etaIncident, float etaTransmitted) {
    float c = clamp(abs(cosineIncident), 0.0, 1.0);
    float etaI = max(etaIncident, 0.001), etaT = max(etaTransmitted, 0.001);
    if (abs(etaI - etaT) < 1e-6) return 0.0;
    float ratio = etaI / etaT;
    float sinT2 = ratio * ratio * max(0.0, 1.0 - c * c);
    if (sinT2 >= 1.0) return 1.0;
    float ct = sqrt(max(0.0, 1.0 - sinT2));
    float rs = (etaI * c - etaT * ct) / max(etaI * c + etaT * ct, 1e-6);
    float rp = (etaT * c - etaI * ct) / max(etaT * c + etaI * ct, 1e-6);
    return clamp(0.5 * (rs * rs + rp * rp), 0.0, 1.0);
}

float3 elyWaterTransmittance(float distanceInWater, float3 biomeTint) {
    float3 tint = clamp(biomeTint, float3(0), float3(1));
    // Near pure-water absorption per block (red is absorbed first) plus biome turbidity.
    float3 absorption = float3(0.24, 0.052, 0.020) + (1.0 - tint) * 0.045;
    return exp(-absorption * clamp(distanceInWater, 0.0, 256.0));
}

float3 elyWaterScattering(float3 transmittance, float3 biomeTint, float daylight) {
    float3 tint = clamp(biomeTint, float3(0), float3(1));
    float3 deepColor = mix(float3(0.045, 0.13, 0.18), tint * 0.22, 0.32);
    return (1.0 - clamp(transmittance, float3(0), float3(1))) * deepColor
        * (0.10 + 0.90 * clamp(daylight, 0.0, 1.0));
}

float elyWaterFoam(float depth, float3 worldPosition, float time, float rain) {
    float shore = 1.0 - smoothstep(0.08, 0.65, max(depth, 0.0));
    float ripple = 0.5 + 0.5 * sin(worldPosition.x * 3.1 + worldPosition.z * 2.7 - time * 1.8);
    return shore * smoothstep(0.62, 0.95, ripple) * mix(0.11, 0.17, clamp(rain, 0.0, 1.0));
}
""" + "\n"
