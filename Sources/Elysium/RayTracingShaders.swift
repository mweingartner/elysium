// Genuine geometry rays; no screen-space reflection/occlusion approximation.
let RAY_TRACING_MSL = renderLocalLightingShaderSource + "\n" + """
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

struct RTPrimitive {
    float4 uv01;
    float4 uv2Light;
    float4 normalEmission;
    uint4 material;
    float4 textureGradientU;
    float4 textureGradientV;
};
struct RTInstance {
    float4x4 transform;
    float4x4 normalTransform;
    float4x4 previousFromCurrent;
    float4 tint;
    float4 overlay;
    uint4 info;
};
struct RTLight { float4 positionRadius; float4 colorPower; };
struct RTUniforms {
    float4x4 inverseViewProjection;
    float4x4 viewProjection;
    float4x4 previousViewProjection;
    float4 cameraDelta;
    float4 params;
    float4 heldLight;
    RenderLocalLightUniforms localLight;
    float4 fogParameters;
    float4 quality;
    uint4 counts;
    ElyAtmosphereU atmosphere;
};
struct RTTextures {
    array<texture2d<float>,512> entities [[id(0)]];
    texture2d_array<float> atlas [[id(512)]];
};
struct RTSurface {
    float distance;
    float3 position;
    float3 normal;
    float3 albedo;
    float alpha;
    float emission;
    float sky;
    float block;
    uint flags;
    uint instance;
    bool hit;
};
static uint rtRandom(thread uint& state) {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state;
}
static uint rtHash(uint value) {
    value^=value>>16; value*=0x7feb352du; value^=value>>15; value*=0x846ca68bu;
    return (value^(value>>16))|1u;
}
static float rtUnit(thread uint& state) { return float(rtRandom(state) >> 8) * (1.0/16777216.0); }
static float3 rtCosine(float3 normal, thread uint& state) {
    float angle=6.28318530718*rtUnit(state), r=sqrt(rtUnit(state));
    float3 tangent=normalize(cross(abs(normal.y)<0.98?float3(0,1,0):float3(1,0,0),normal));
    return normalize(tangent*(cos(angle)*r)+cross(normal,tangent)*(sin(angle)*r)+normal*sqrt(max(0.0,1.0-r*r)));
}
static float3 rtTint(uint c) { return float3((c>>16)&255,(c>>8)&255,c&255)/255.0; }
static float3 rtLinear(float3 c) { return pow(max(c,float3(0)),float3(2.2)); }
static float rtLuminance(float3 c) { return dot(c,float3(0.2126,0.7152,0.0722)); }
// Luminance-preserving cap for indirect contributions: rare saturated fireflies lose energy
// without the hue shift of a per-channel clamp. Primary emission and direct light are exempt.
static float3 rtClampLuminance(float3 c,float limit) {
    float l=rtLuminance(c);
    return l>limit?c*(limit/l):c;
}
// R2 rank-1 lattice in 32-bit fixed point with a per-pixel rotation: a pixel's samples and
// consecutive frames stratify the first diffuse bounce without extra rays or RNG draws.
static float2 rtR2(uint index,float2 rotation) {
    float2 lattice=float2(float(index*3242174889u),float(index*2447445414u))*2.3283064365386963e-10;
    return fract(rotation+lattice);
}
static float3 rtCosineFrom(float3 normal,float2 xi) {
    float angle=6.28318530718*xi.x, r=sqrt(xi.y);
    float3 tangent=normalize(cross(abs(normal.y)<0.98?float3(0,1,0):float3(1,0,0),normal));
    return normalize(tangent*(cos(angle)*r)+cross(normal,tangent)*(sin(angle)*r)+normal*sqrt(max(0.0,1.0-r*r)));
}
// Continuation rays leave a surface along its plane normal by a distance-scaled epsilon:
// a fixed step along the ray direction is too small at grazing angles 300+ blocks away.
static float rtSurfaceOffset(float3 position) { return 0.002+2e-5*length(position); }
// Keep a reflected direction slightly above its geometric plane. Wave normals can tilt a mirror
// ray below the water at grazing angles, where it would hit the seabed shaded as if in air.
// The ramp is continuous, so there is no band where the correction switches on.
static float3 rtAboveHorizon(float3 direction,float3 planeNormal) {
    float t=dot(direction,planeNormal);
    if(t>=0.05) return direction;
    float target=t>0?mix(0.02,0.05,t/0.05):0.02;
    return normalize(direction+planeNormal*(target-t));
}
// Camera-centred equirectangular sky and cloud radiance without the sun or moon discs, rebuilt
// every frame. It replaces redundant per-ray cloud marches after a diffuse bounce (the sun was
// already counted by next-event estimation) and lights native water reflections.
static float2 rtSkyCoordinate(float3 d) {
    d=normalize(d);
    return float2(atan2(d.z,d.x)*0.15915494309+0.5,acos(clamp(d.y,-1.0,1.0))*0.31830988618);
}
static float3 rtSkyDirection(float2 uv) {
    float phi=(uv.x-0.5)*6.28318530718, theta=uv.y*3.14159265359, s=sin(theta);
    return float3(s*cos(phi),cos(theta),s*sin(phi));
}
static float3 rtSkyRadiance(texture2d<float,access::sample> sky,float3 direction) {
    constexpr sampler skySampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
    float3 value=sky.sample(skySampler,rtSkyCoordinate(direction),level(0)).rgb;
    return all(isfinite(value))?max(value,float3(0)):float3(0);
}

// Render-only canopy art direction: two solid leaf faces transmit 0.62^2 = 38.44%.
// A neutral deterministic factor avoids noisy alpha roulette and saturated green speckles.
static float rtDirectLightCosine(float3 normal,float3 lightDirection,uint flags) {
    float cosine=dot(normal,lightDirection);
    return max(cosine,0.0)+((flags&32u)!=0?0.30*max(-cosine,0.0):0.0);
}

// Art-directed conversion from the game's local irradiance scale to diffuse radiance.
// The old unit response washed out nearby stone after correct display encoding.
constant float rtLocalDiffuseResponse=0.40;

static float rtCachedIllumination(float sky,float block,constant RTUniforms& u) {
    float localLevel=clamp(block,0.0,1.0);
    // Display encoding now preserves shadow detail. A small neutral floor keeps caves
    // readable without the former enclosed-room glow; daylight/canopy fill is unchanged.
    float caveFloor=0.045;
    float cached=max(caveFloor,rtLocalDiffuseResponse*elyNonSunLightOutput*localLevel/(4-3*localLevel));
    if(u.atmosphere.options.x>0.5) cached=max(cached,0.045);
    cached=max(cached,clamp(u.fogParameters.z,0.0,1.0)*0.55);
    if(u.atmosphere.options.x<0.5) {
        // The existing voxel skylight already propagates leaf opacity and solid-roof blocking.
        // A small neutral fill stabilizes two-bounce canopy GI without lifting sealed caves or
        // bypassing the actual direct-shadow ray. Nighttime remains deliberately subdued.
        // Sky daylight is continuous through the horizon (roughly 0.5 there). Switching on
        // the sign of sun height caused an abrupt seven-percent lighting jump at sunset.
        float daylight=clamp(u.atmosphere.sunDaylight.w,0.04,1.0);
        float skylight=clamp(sky,0.0,1.0);
        cached+=0.14*skylight*skylight*daylight;
    }
    return cached;
}

static float3 rtCachedDiffuseIrradiance(RTSurface surface,float3 normal,constant RTUniforms& u,
                                       texture3d<float,access::sample> localLightTexture) {
    float4 local=sampleRenderLocalLight(surface.position,normal,u.localLight,localLightTexture);
    float block=clamp(surface.block,0.0,1.0);
    float3 irradiance=local.rgb;
    if(u.localLight.params.x>0.5) {
        float cached=elyNonSunLightOutput*block/(4-3*block);
        irradiance=mix(float3(cached),local.rgb,local.a);
    }
    return irradiance*rtLocalDiffuseResponse
        +rtCachedIllumination(surface.sky,u.localLight.params.x>0.5?0.0:surface.block,u);
}

struct RTFilteredHit {
    bool hit;
    float distance;
    uint instance;
    const device RTPrimitive* primitive;
    float4 texel;
};

// Hemispherical sky irradiance proxy from the per-frame sky radiance, for deterministic
// secondary shading that has no bounce ray (reflected terrain, fallback seabed).
static float3 rtSkyAmbient(texture2d<float,access::sample> sky) {
    return rtSkyRadiance(sky,float3(0,1,0))*0.28
        +(rtSkyRadiance(sky,normalize(float3(1,0.6,0)))+rtSkyRadiance(sky,normalize(float3(-1,0.6,0)))
         +rtSkyRadiance(sky,normalize(float3(0,0.6,1)))+rtSkyRadiance(sky,normalize(float3(0,0.6,-1))))*0.18;
}

// Deterministic stand-in for the bounce light the low-resolution path gives directly viewed
// surfaces, for native shading with no bounce ray (low-confidence terrain, reflections, seabeds).
// Cosine-weighted sky for the upward hemisphere, sunlit ground bounce for the downward one, both
// occluded by the voxel skylight at the face. Without it, thin distant risers with no compatible
// donor fell back to direct+cache only and read as dark dashes against their lit terrace tops.
static float3 rtFallbackIndirect(RTSurface s,float3 normal,float3 skyAmbient,constant RTUniforms& u) {
    if(u.atmosphere.options.x>0.5) return float3(0);
    float3 sun=normalize(u.atmosphere.sunDaylight.xyz);
    float daylight=clamp(u.atmosphere.sunDaylight.w,0.0,1.0);
    float sunOnGround=sun.y>0?daylight*2.5*smoothstep(0.0,0.04,sun.y)*sun.y:0.0;
    float3 ground=0.3*(float3(sunOnGround)+skyAmbient);
    float up=clamp(0.5+0.5*normal.y,0.0,1.0);
    float sky=clamp(s.sky,0.0,1.0);
    float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    return (skyAmbient*up+ground*(1.0-up))*(sky*sky*exposure);
}

// Pure alpha rejection lets hardware continue traversal after transparent texels.
// No payload writes, random draws or transmission accumulation: candidate calls
// may repeat or arrive out of depth order. Shade only the final nearest hit.
[[intersection(triangle,triangle_data,instancing)]]
bool rt_alpha_accept(float2 bary [[barycentric_coord]],uint instanceID [[instance_id]],
                     float3 origin [[origin]],float3 direction [[direction]],
                     float candidateDistance [[distance]],
                     const device RTPrimitive* primitive [[primitive_data]],
                     device const RTInstance* instances [[buffer(0)]],
                     constant RTTextures& textures [[buffer(1)]]) {
    const device RTPrimitive& p=*primitive;
    const device RTInstance& instance=instances[instanceID];
    float2 uv=p.uv01.xy*(1-bary.x-bary.y)+p.uv01.zw*bary.x+p.uv2Light.xy*bary.y;
    constexpr sampler nearest(coord::normalized,address::repeat,filter::nearest);
    float texAlpha=(p.material.z&8u)!=0
        ? textures.entities[min(instance.info.x,511u)].sample(nearest,uv).a
        : textures.atlas.sample(nearest,uv,p.material.y).a;
    float alpha=texAlpha*instance.tint.a;
    float coverage=(p.material.z&8u)!=0?texAlpha:alpha;
    float cutoff=(p.material.z&8u)!=0?0.1:0.35;
    bool accepted=!(((p.material.z&1u)!=0 && coverage<cutoff) || alpha<0.005);
    // Leaf holes smaller than the camera pixel footprint are aliasing, not detail: they flicker
    // as single sky-coloured pixels. The mip level matching that footprint may ADD acceptance
    // but never removes it, so exact nearby holes and every mip-zero texel of a sparse plant
    // survive while distant canopies stop sparkling. The same test serves every ray type, so
    // shadows, primary visibility and both resolutions agree. A zero scale keeps exact holes.
    float footprintScale=as_type<float>(instance.info.w);
    if(!accepted && (p.material.z&9u)==1u && footprintScale>0 && instance.tint.a>=1.0) {
        float3 hit=(instance.transform*float4(origin+direction*candidateDistance,1)).xyz;
        float cosine=max(abs(dot(normalize(direction),p.normalEmission.xyz)),0.2);
        float texels=length(p.textureGradientU.xyz)*float(textures.atlas.get_width());
        float footprint=length(hit)*footprintScale*texels/cosine;
        if(footprint>1.5) {
            constexpr sampler mipped(coord::normalized,address::repeat,min_filter::linear,
                                     mag_filter::linear,mip_filter::linear);
            accepted=textures.atlas.sample(mipped,uv,p.material.y,level(log2(footprint))).a>=cutoff;
        }
    }
    return accepted;
}

static RTFilteredHit rtFilteredIntersection(ray r,instance_acceleration_structure scene,
                            device const RTInstance* instances,constant RTTextures& textures,
                            texture2d_array<float> atlas,
                            intersection_function_table<triangle_data,instancing> functions,uint rayMask,
                            bool sampleSurfaceColor=true,float3 pixelRayX=float3(0),float3 pixelRayY=float3(0),
                            float3 rayOriginX=float3(0),float3 rayOriginY=float3(0)) {
    RTFilteredHit result; result.hit=false;
    intersector<triangle_data,instancing> trace;
    trace.assume_geometry_type(geometry_type::triangle);
    // Overrides both geometry and instance flags, preserving alpha-zero holes
    // even in nominally opaque textures supplied by a custom resource pack.
    trace.force_opacity(forced_opacity::non_opaque);
    auto hit=trace.intersect(r,scene,rayMask,functions);
    if(hit.type==intersection_type::none) return result;
    result.hit=true;result.distance=hit.distance;result.instance=hit.instance_id;
    result.primitive=(const device RTPrimitive*)hit.primitive_data;
    const device RTPrimitive& p=*result.primitive;
    // Alpha acceptance already happened inside traversal. Visibility needs accepted-hit
    // color only for tinted glass; solid blockers, neutral leaves and water use constants.
    // Keep full sampling for ordinary surface rays and preserve glass precedence exactly.
    if(!sampleSurfaceColor && ((p.material.z&4u)==0 || (p.material.z&34u)!=0)) {
        result.texel=float4(1);
        return result;
    }
    const device RTInstance& instance=instances[hit.instance_id];
    float2 bary=hit.triangle_barycentric_coord;
    float2 uv=p.uv01.xy*(1-bary.x-bary.y)+p.uv01.zw*bary.x+p.uv2Light.xy*bary.y;
    constexpr sampler nearest(coord::normalized,address::repeat,filter::nearest);
    result.texel=(p.material.z&8u)!=0
        ? textures.entities[min(instance.info.x,511u)].sample(nearest,uv)
        : atlas.sample(nearest,uv,p.material.y);
    if((p.material.z&9u)==1u && result.texel.a<0.35) {
        // Accepted only through distance coverage in rt_alpha_accept: use that mip level's
        // alpha-weighted material colour instead of an undefined transparent texel.
        float3 position=r.origin+r.direction*hit.distance;
        float cosine=max(abs(dot(r.direction,p.normalEmission.xyz)),0.2);
        float texels=length(p.textureGradientU.xyz)*float(atlas.get_width());
        float lod=log2(max(1.0,length(position)*as_type<float>(instance.info.w)*texels/cosine));
        constexpr sampler mipped(coord::normalized,address::repeat,min_filter::linear,
                                 mag_filter::linear,mip_filter::linear);
        float4 filtered=atlas.sample(mipped,uv,p.material.y,level(lod));
        result.texel=float4(filtered.rgb,max(filtered.a,0.35));
    }
    // Camera-ray differentials intersect the accepted hit's plane analytically: no
    // extra scene rays. Filter only subpixel material detail, after exact alpha traversal.
    // The inverse-transpose also transforms UV covectors under scaled instances.
    if((p.material.z&8u)==0 && atlas.get_num_mip_levels()>1 && any(pixelRayX!=float3(0))) {
        float3 normal=normalize((instance.normalTransform*float4(p.normalEmission.xyz,0)).xyz);
        float3 position=r.origin+r.direction*hit.distance;
        float plane=dot(normal,position), dx=dot(normal,pixelRayX), dy=dot(normal,pixelRayY);
        if(abs(dx)>1e-6 && abs(dy)>1e-6) {
            // Differential rays may start away from the camera (mirrored or refracted views).
            float3 dpdx=rayOriginX+pixelRayX*((plane-dot(normal,rayOriginX))/dx)-position;
            float3 dpdy=rayOriginY+pixelRayY*((plane-dot(normal,rayOriginY))/dy)-position;
            float3 gu=(instance.normalTransform*p.textureGradientU).xyz;
            float3 gv=(instance.normalTransform*p.textureGradientV).xyz;
            float2 duvdx(dot(gu,dpdx),dot(gv,dpdx)), duvdy(dot(gu,dpdy),dot(gv,dpdy));
            float2 size(atlas.get_width(),atlas.get_height());
            float footprint=max(length(duvdx*size),length(duvdy*size));
            if(isfinite(footprint) && footprint>1) {
                constexpr sampler minified(coord::normalized,address::repeat,
                    min_filter::linear,mag_filter::nearest,mip_filter::linear,max_anisotropy(4));
                float3 filtered=atlas.sample(minified,uv,p.material.y,gradient2d(duvdx,duvdy)).rgb;
                result.texel.rgb=mix(result.texel.rgb,filtered,smoothstep(1.0,2.0,footprint));
            }
        }
    }
    return result;
}

static RTSurface rtIntersect(ray r, instance_acceleration_structure scene,
                            device const RTInstance* instances, constant RTTextures& textures,
                            texture2d_array<float> atlas,
                            intersection_function_table<triangle_data,instancing> functions,uint rayMask=0xff,
                            float3 pixelRayX=float3(0),float3 pixelRayY=float3(0),
                            float3 rayOriginX=float3(0),float3 rayOriginY=float3(0)) {
    RTSurface result; result.hit=false;
    RTFilteredHit hit=rtFilteredIntersection(r,scene,instances,textures,atlas,functions,rayMask,true,
                                             pixelRayX,pixelRayY,rayOriginX,rayOriginY);
    if(!hit.hit) return result;
    const device RTPrimitive& p=*hit.primitive;
    const device RTInstance& instance=instances[hit.instance];
    result.hit=true;
    result.distance=hit.distance;
    result.position=r.origin+r.direction*hit.distance;
    result.normal=normalize((instance.normalTransform*float4(p.normalEmission.xyz,0)).xyz);
    float3 color=hit.texel.rgb*rtTint(p.material.x)*instance.tint.rgb;
    color=mix(color,instance.overlay.rgb,instance.overlay.a);
    result.albedo=rtLinear(clamp(color,float3(0),float3(1)));
    result.alpha=hit.texel.a*instance.tint.a;
    result.emission=p.normalEmission.w;
    result.sky=p.uv2Light.z; result.block=p.uv2Light.w;
    result.flags=p.material.z;
    result.instance=hit.instance;
    return result;
}

static float3 rtVisibility(float3 position,float3 normal,float3 direction,float distance,
                           instance_acceleration_structure scene,device const RTInstance* instances,
                           constant RTTextures& textures,texture2d_array<float> atlas,
                           intersection_function_table<triangle_data,instancing> functions,
                           bool startsInWater=false,float3 waterTint=float3(0.2,0.45,0.65),bool collimated=false) {
    ray r; r.origin=position+normal*0.003; r.direction=direction;
    r.min_distance=0.001; r.max_distance=max(0.002,distance-0.008);
    float3 transmission(1);
    for(uint layer=0;layer<8;++layer) {
        RTFilteredHit hit=rtFilteredIntersection(r,scene,instances,textures,atlas,functions,0xff,false);
        if(!hit.hit) return transmission;
        const device RTPrimitive& p=*hit.primitive;
        const device RTInstance& instance=instances[hit.instance];
        uint flags=p.material.z;
        // Leaves transmit diffuse, art-directed canopy light; a collimated sunbeam (specular
        // glint) passes only through their actual alpha holes, which traversal already skipped.
        if((flags&32u)!=0) { if(collimated) return float3(0); transmission*=0.62; }
        else if((flags&2u)!=0) {
            // From a submerged point, light crossed the actual water above it; the old constant
            // over-lit deep seabeds. Coplanar top/underside quads share one crossing (min_distance).
            transmission*=startsInWater?elyWaterTransmittance(hit.distance,waterTint)*0.97:float3(0.7,0.86,0.92);
            startsInWater=false;
        }
        else if((flags&4u)!=0) {
            float3 color=hit.texel.rgb*rtTint(p.material.x)*instance.tint.rgb;
            color=mix(color,instance.overlay.rgb,instance.overlay.a);
            transmission*=mix(float3(1),rtLinear(clamp(color,float3(0),float3(1))),0.35);
        } else return float3(0);
        r.min_distance=hit.distance+0.003;
        if(r.min_distance>=r.max_distance) return transmission;
    }
    return float3(0);
}

// Only the no-volume compatibility path (and moving emitters) use surface proxies. Evaluate
// stable strongest local sources without a global random lottery or biased inverse-PDF clamp.
static float3 rtLocalProxyIrradiance(float3 position,float3 normal,device const RTLight* lights,uint count,
                                    instance_acceleration_structure scene,device const RTInstance* instances,
                                    constant RTTextures& textures,texture2d_array<float> atlas,
                                    intersection_function_table<triangle_data,instancing> functions) {
    uint indices[4]={0,0,0,0}; float weights[4]={0,0,0,0};
    for(uint index=0;index<count;++index) {
        RTLight light=lights[index]; float3 delta=light.positionRadius.xyz-position;
        float d=length(delta),radius=light.positionRadius.w;
        if(d<=0.05 || d>=radius) continue;
        float cosine=max(0.0,dot(normal,delta/d));
        float edge=1-d/radius;
        float weight=light.colorPower.w*cosine*edge*edge/(1+d*d);
        if(weight<=weights[3]) continue;
        for(uint slot=0;slot<4;++slot) {
            if(weight>weights[slot]) {
                for(uint tail=3;tail>slot;--tail) { indices[tail]=indices[tail-1]; weights[tail]=weights[tail-1]; }
                indices[slot]=index; weights[slot]=weight; break;
            }
        }
    }
    float3 irradiance(0);
    for(uint slot=0;slot<4;++slot) {
        if(weights[slot]<=0) continue;
        RTLight light=lights[indices[slot]]; float3 delta=light.positionRadius.xyz-position;
        float d=length(delta);
        float3 visible=rtVisibility(position,normal,delta/d,d,scene,instances,textures,atlas,functions);
        irradiance+=light.colorPower.rgb*visible*weights[slot];
    }
    return irradiance;
}

struct RTPathResult {
    float3 radiance;
    float depth;
    float4 normalDistance;
    float4 motion;
    float4 diffuse;
    float4 specular;
};

static float rtRadianceBasis(uint flags) {
    // Distinct unfactored classes prevent coplanar water and glass from sharing
    // radiance merely because both use the same low material roughness.
    return (flags&2u)!=0?-2.0:((flags&4u)!=0?-3.0:((flags&16u)!=0?-1.0:((flags&32u)!=0?-5.0:-4.0)));
}

// One bounded transport implementation serves the low-rate lighting pass and exact
// native fallback. The caller supplies resolution-independent ray UV and RNG identity.
static RTPathResult rtTracePixel(float2 uv,uint2 pixel,uint noiseWidth,
                         instance_acceleration_structure scene,
                         device const RTInstance* instances,constant RTUniforms& u,
                         device const RTLight* lights,texture2d<float,access::sample> skyRadiance,
                         constant RTTextures& textures,
                         intersection_function_table<triangle_data,instancing> functions,
                         texture2d_array<float> atlas,
                         texture3d<float,access::sample> localLightTexture,bool allowFactor) {
    float4 farPoint=u.inverseViewProjection*float4(uv.x*2-1,1-uv.y*2,1,1);
    float2 pixelStep=2.0/float2(noiseWidth,float(noiseWidth)*float(u.counts.w)/float(u.counts.z));
    float4 farX=farPoint+u.inverseViewProjection*float4(pixelStep.x,0,0,0);
    float4 farY=farPoint+u.inverseViewProjection*float4(0,-pixelStep.y,0,0);
    float3 pixelRayX=farX.xyz/farX.w,pixelRayY=farY.xyz/farY.w;
    // Angle per lighting pixel, for band-limiting wave normals at this resolution.
    float lightingPixelAngle=max(length(normalize(pixelRayX)-normalize(farPoint.xyz/farPoint.w)),1e-5);
    float3 accumulated(0);
    float guideDepth=1; float4 guideNormal(0),guideMotion(0),guideDiffuse(1,1,1,1),guideSpecular(0);
    bool primarySolarValid=false;
    uint primarySolarInstance=0,primarySolarFlags=0;
    float3 primarySolarPosition(0),primarySolarNormal(0),primarySolarIrradiance(0);
    RTSurface primarySurface;
    bool factorPixel=allowFactor && u.quality.w>0.5 && u.atmosphere.weather.w<0.5;
    uint sampleCount=clamp(uint(u.quality.x),2u,4u);
    uint rotationSeed=rtHash(pixel.x*73856093u^pixel.y*19349663u^0x5bd1e995u);
    float2 r2Rotation=float2(float(rotationSeed>>8),float(rtHash(rotationSeed)>>8))*(1.0/16777216.0);
    for(uint sample=0;sample<sampleCount;++sample) {
    uint seed=rtHash(pixel.x+pixel.y*noiseWidth)^rtHash(u.counts.x*4u+sample+0x9e3779b9u);
    seed=rtHash(seed);
    ray r; r.origin=float3(0); r.direction=normalize(farPoint.xyz/farPoint.w);
    r.min_distance=0.005; r.max_distance=u.params.x;
    float3 throughput(1), radiance(0), waterTint(0.2,0.45,0.65);
    bool insideWater=u.atmosphere.weather.w>0.5;
    // Seabed-irradiance mode for top water seen from air (see the water branch below).
    bool floorPending=false, skipMediumSegment=false;
    bool primaryPending=true;
    uint diffuseBounces=0;
    float primaryDepth=1; float4 primaryNormal(0,0,0,u.params.x);
    float4 primaryDiffuse(1,1,1,1),primarySpecular(0);
    float4 skyClip=u.previousViewProjection*float4(r.direction,0);
    float4 previous=float4(skyClip.xy/skyClip.w*float2(0.5,-0.5)+0.5,1,skyClip.w>0?1:0);
    for(uint bounce=0;bounce<7;++bounce) {
        // Every sample in this frame starts with the exact same primary ray. Cache only its raw
        // first hit: entity fade decisions and all continuation rays remain per sample,
        // as do the separate reflection/refraction lobes of primary water and glass.
        RTSurface s;
        if(bounce==0 && sample>0) s=primarySurface;
        else {
            s=rtIntersect(r,scene,instances,textures,atlas,functions,primaryPending?0x01:0xff,
                          bounce==0?pixelRayX:float3(0),bounce==0?pixelRayY:float3(0));
            if(bounce==0) primarySurface=s;
        }
        // All samples must share one material basis. A stochastic foreground body can
        // reveal a different material per sample, so preserve ordinary radiance for it.
        if(bounce==0 && s.hit && (s.flags&8u)!=0 && instances[s.instance].tint.a<1.0)
            factorPixel=false;
        float segment=s.hit?s.distance:min(u.params.x,96.0);
        if(insideWater && !skipMediumSegment) {
            float3 trans=elyWaterTransmittance(segment,waterTint);
            radiance+=throughput*elyWaterScattering(trans,waterTint,u.atmosphere.sunDaylight.w);
            throughput*=trans;
        }
        // The native resolve applies the camera-to-seabed medium at full resolution.
        skipMediumSegment=false;
        if(!s.hit) {
            // The initial air background is deterministic, not Monte Carlo radiance. Resolve
            // it with camera media after denoising so sky and fully faded terrain share the
            // exact same atmospheric boundary. Underwater and secondary paths stay here.
            if(primaryPending && !insideWater) break;
            if(floorPending) { floorPending=false; primarySpecular.a=-6.0; }
            float3 absoluteOrigin=r.origin+u.atmosphere.cameraTime.xyz;
            // After a diffuse bounce, next-event estimation already counted the sun and moon;
            // hitting their discs again produced fireflies. The per-frame sky radiance also
            // replaces a redundant cloud march per bounce ray. Specular chains keep exact sky.
            bool afterDiffuse=diffuseBounces>0;
            float3 environment=insideWater
                ? elyAtmosphereRadiance(absoluteOrigin,r.direction,u.atmosphere,!afterDiffuse)
                : (afterDiffuse?rtSkyRadiance(skyRadiance,r.direction)
                    :elyAtmosphereRadianceAir(absoluteOrigin,r.direction,u.atmosphere,true));
            radiance+=afterDiffuse?rtClampLuminance(throughput*environment,6.0):throughput*environment;
            break;
        }
        if((s.flags&8u)!=0 && instances[s.instance].tint.a<1.0
            && rtUnit(seed)>instances[s.instance].tint.a) {
            r.origin=s.position+r.direction*0.004; r.min_distance=0.001; continue;
        }
        bool firstSurface=primaryPending;
        // Surface/lighting split: whiten only the primary ordinary diffuse
        // response BEFORE transport. This carries irradiance without dividing dark texels;
        // the native-resolution resolve restores the exact authored primary albedo.
        // Secondary materials, water/glass, metals and submerged transport remain unchanged.
        bool factorPrimary=factorPixel && firstSurface && (s.flags&22u)==0;
        if(factorPrimary) s.albedo=float3(1);
        // First diffuse event under top water: carry its irradiance only (native restores albedo).
        bool factorFloor=false;
        if(floorPending) {
            floorPending=false;
            factorFloor=(s.flags&22u)==0 && !((s.flags&8u)!=0 && instances[s.instance].tint.a<1.0);
            if(factorFloor) s.albedo=float3(1);
            else primarySpecular.a=-6.0;
        }
        if(primaryPending) {
            primaryPending=false;
            float4 clip=u.viewProjection*float4(s.position,1);
            primaryDepth=clamp(clip.z/clip.w,0.0,1.0);
            primaryNormal=float4(s.normal,length(s.position));
            bool dielectric=(s.flags&6u)!=0,metal=(s.flags&16u)!=0;
            primaryDiffuse=float4(dielectric || metal?float3(0):s.albedo,dielectric?0.06:(metal?0.16:0.85));
            primarySpecular=float4(metal?s.albedo:float3(dielectric?0.02:0.04),0);
            // Alpha is unused by the neural specular guide. The native resolve uses it
            // as explicit basis metadata: ordinary diffuse=1, foliage=2, negative
            // values distinguish unfactored water/glass/metal and other radiance.
            if(factorPrimary) primarySpecular.a=(s.flags&32u)!=0?2.0:1.0;
            else if(u.quality.w>0.5) primarySpecular.a=rtRadianceBasis(s.flags);
            RTInstance instance=instances[s.instance];
            float3 prevPosition=instance.info.y!=0
                ? (instance.previousFromCurrent*float4(s.position,1)).xyz
                : s.position+u.cameraDelta.xyz;
            float4 prevClip=u.previousViewProjection*float4(prevPosition,1);
            float historyTag=(s.flags&6u)!=0?2.0:1.0;
            previous=float4(prevClip.xy/prevClip.w*float2(0.5,-0.5)+0.5,
                            prevClip.z/prevClip.w,prevClip.w>0 && instance.info.z!=0?historyTag:0);
        }
        float3 faceNormal=dot(s.normal,r.direction)<0?s.normal:-s.normal;
        float3 worldPosition=s.position+u.atmosphere.cameraTime.xyz;
        // Visible primary emission is restored exactly at native resolution, never
        // blurred into neighboring irradiance or confused with a different material.
        if(!factorPrimary && !factorFloor) {
            float3 emitted=throughput*s.albedo*s.emission;
            radiance+=diffuseBounces>0?rtClampLuminance(emitted,6.0):emitted;
        }
        bool water=(s.flags&2u)!=0, glass=(s.flags&4u)!=0;
        if(firstSurface && factorPixel && water && faceNormal.y>0.65 && !insideWater) {
            // Top water seen from air: rt_surface_resolve shades the interface, the reflection,
            // the medium and the seabed texture at native resolution. This path carries only the
            // seabed irradiance (bounce light included), so the shore and seabed stay consistent.
            floorPending=true; skipMediumSegment=true;
            insideWater=true; waterTint=pow(s.albedo,float3(1.0/2.2));
            primaryNormal.xyz=faceNormal;
            primaryDiffuse=float4(1,1,1,0.85); primarySpecular=float4(0.04,0.04,0.04,3.0);
            if(previous.w>0) previous.w=1.0;
            r.direction=normalize(refract(r.direction,faceNormal,1.0/1.333));
            r.origin=s.position-faceNormal*rtSurfaceOffset(s.position); r.min_distance=0.001;
            continue;
        }
        if(glass && s.alpha>0.02) {
            // Translucent blocks carry authored coverage (raster alpha-blends their texels). Light
            // that coverage as a diffuse layer and transmit only the rest, so ice reads as pale
            // translucent ice rather than clear glass over dark deep water, and glass frames stay
            // visible while clear panes remain clear. Deterministic: one light ray, no RNG.
            float coverage=clamp(s.alpha,0.0,1.0);
            float3 layerSun=normalize(u.atmosphere.sunDaylight.xyz);
            bool layerDay=layerSun.y>0;
            float3 layerDirection=layerDay?layerSun:-layerSun;
            float3 layerLight=rtCachedDiffuseIrradiance(s,faceNormal,u,localLightTexture)
                +rtFallbackIndirect(s,faceNormal,rtSkyAmbient(skyRadiance),u)/exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
            float layerCosine=max(dot(faceNormal,layerDirection),0.0);
            if(u.atmosphere.options.x<0.5 && layerCosine>0) {
                float layerStrength=layerDay?u.atmosphere.sunDaylight.w*2.5*smoothstep(0.0,0.04,layerSun.y):0.085*elyNonSunLightOutput;
                float3 layerColor=layerDay?mix(float3(1,0.53,0.24),float3(1,0.96,0.88),smoothstep(0.03,0.5,layerSun.y)):float3(0.40,0.55,0.9);
                float3 layerVisible=u.params.w>0.5
                    ?rtVisibility(s.position,faceNormal,layerDirection,u.params.x,scene,instances,textures,atlas,functions,
                                  insideWater,waterTint):float3(1);
                if(any(layerVisible>float3(0)))
                    layerLight+=layerColor*layerVisible*(layerCosine*layerStrength
                        *elyCloudSunTransmittanceAir(s.position+u.atmosphere.cameraTime.xyz,u.atmosphere));
            }
            float3 layered=throughput*coverage*s.albedo*layerLight;
            radiance+=diffuseBounces>0?rtClampLuminance(layered,6.0):layered;
            throughput*=1.0-coverage;
        }
        if(water || glass) {
            float waveTime=u.atmosphere.options.y>0.5?0.0:u.atmosphere.cameraTime.w;
            float waveFootprint=length(s.position)*lightingPixelAngle/max(abs(dot(r.direction,faceNormal)),0.03);
            float3 n=water?elyWaterSurface(worldPosition,faceNormal,waveTime,u.atmosphere.weather.x,waveFootprint).normal
                          :faceNormal;
            if(dot(n,faceNormal)<0) n=-n;
            if(dot(n,r.direction)>-0.001) n=faceNormal;
            bool entering=dot(s.normal,r.direction)<0;
            float etaI=water?(insideWater?1.333:1.0):(entering?1.0:1.5);
            float etaT=water?(insideWater?1.0:1.333):(entering?1.5:1.0);
            float fresnel=elyDielectricFresnel(clamp(-dot(n,r.direction),0.0,1.0),etaI,etaT);
            float3 refracted=refract(r.direction,n,etaI/etaT);
            bool totalReflection=dot(refracted,refracted)<0.001;
            bool reflected=totalReflection || (firstSurface?(sample&1u)==0:rtUnit(seed)<fresnel);
            // Both primary dielectric lobes are evaluated every pixel: tiny Fresnel weights
            // no longer turn into rare white pixels. Subsequent interfaces remain stochastic.
            if(firstSurface && !totalReflection) throughput*=reflected?2*fresnel:2*(1-fresnel);
            if(firstSurface) {
                // Guides and native donor matching use the flat interface: animated ripple
                // normals differ between resolutions and rejected most water donors.
                primaryNormal.xyz=faceNormal;
                // The reconstruction guide reflects the actual view-dependent dielectric
                // response, not a constant normal-incidence value at grazing water angles.
                primarySpecular.rgb=float3(max(0.02,fresnel));
            }
            r.direction=reflected?rtAboveHorizon(reflect(r.direction,n),faceNormal):normalize(refracted);
            if(!reflected) {
                if(water) { insideWater=!insideWater; waterTint=pow(s.albedo,float3(1.0/2.2)); }
                else throughput*=mix(float3(1),s.albedo,0.22);
            }
            r.origin=s.position+(reflected?faceNormal:-faceNormal)*rtSurfaceOffset(s.position);
            r.min_distance=0.001;
            continue;
        }
        // Metallic blocks retain their Faithful color and reflect the actual scene. Rough
        // dielectric blocks keep continuous direct shading, not a noisy full-sky lobe roulette.
        bool metal=(s.flags&16u)!=0;
        if(metal) {
            float3 perfect=reflect(r.direction,faceNormal);
            float roughness=0.16;
            r.direction=normalize(mix(perfect,rtCosine(faceNormal,seed),roughness*roughness));
            r.origin=s.position+faceNormal*0.004;
            throughput*=max(s.albedo,float3(0.15));
            continue;
        }
        float3 sun=normalize(u.atmosphere.sunDaylight.xyz);
        float daylight=u.atmosphere.sunDaylight.w;
        bool sunlight=sun.y>0;
        float3 lightDirection=sunlight?sun:-sun;
        float lightStrength=sunlight?daylight*2.5*smoothstep(0.0,0.04,sun.y):0.085*elyNonSunLightOutput;
        float3 lightColor=sunlight?mix(float3(1,0.53,0.24),float3(1,0.96,0.88),smoothstep(0.03,0.5,sun.y)):float3(0.40,0.55,0.9);
        if(u.atmosphere.options.x<0.5) {
            float cosine=rtDirectLightCosine(faceNormal,lightDirection,s.flags);
            if(cosine>0) {
                // Pixel-centered primary rays revisit the same diffuse surface in each path.
                // Reuse only deterministic irradiance, not material albedo or random bounces.
                // Exact keys also reject changed first hits behind stochastic entity fades.
                bool reusePrimarySolar = firstSurface && primarySolarValid
                    && s.instance==primarySolarInstance && s.flags==primarySolarFlags
                    && all(s.position==primarySolarPosition) && all(faceNormal==primarySolarNormal);
                float3 solarIrradiance;
                if(reusePrimarySolar) solarIrradiance=primarySolarIrradiance;
                else {
                    float3 visibility=u.params.w>0.5
                        ?rtVisibility(s.position,faceNormal,lightDirection,u.params.x,scene,instances,textures,atlas,functions,
                                      insideWater,waterTint):float3(1);
                    // A fully blocked solar ray contributes exactly zero regardless of
                    // clouds; do not march their density again behind an opaque surface.
                    float clouds=1;
                    if(any(visibility>float3(0))) clouds=elyCloudSunTransmittanceAir(worldPosition,u.atmosphere);
                    solarIrradiance=lightColor*visibility*(cosine*lightStrength*clouds);
                    if(firstSurface) {
                        primarySolarValid=true; primarySolarInstance=s.instance; primarySolarFlags=s.flags;
                        primarySolarPosition=s.position; primarySolarNormal=faceNormal;
                        primarySolarIrradiance=solarIrradiance;
                    }
                }
                float3 solarContribution=throughput*s.albedo*solarIrradiance;
                radiance+=diffuseBounces>0?rtClampLuminance(solarContribution,6.0):solarContribution;
            }
        }
        // Held torch is a physical local light with ray-occluded visibility, not a screen wash.
        if(u.heldLight.w>0) {
            float3 delta=float3(0.30,-0.30,0.25)-s.position; float d=length(delta);
            if(d<u.heldLight.w && d>0.001) {
                float fall=pow(clamp(1-d/u.heldLight.w,0.0,1.0),2.0);
                float3 vis=rtVisibility(s.position,faceNormal,delta/d,d,scene,instances,textures,atlas,functions);
                radiance+=throughput*s.albedo*u.heldLight.rgb*vis*(fall*max(0.0,dot(faceNormal,delta/d))*2.5*rtLocalDiffuseResponse);
            }
        }
        // The immutable propagated volume is deterministic and already respects solid voxel
        // occlusion. It provides local diffuse illumination without competition from remote
        // lava. Static proxy lights are not submitted when the volume is available.
        // These caches already approximate indirect diffuse transport. Reapplying them on
        // secondary diffuse hits compounds the same illumination in enclosed rooms. Use the
        // first DIFFUSE hit, including surfaces viewed through glass/water or in a mirror.
        if(diffuseBounces==0) {
            radiance+=throughput*s.albedo*rtCachedDiffuseIrradiance(s,faceNormal,u,localLightTexture);
        }
        if(u.counts.y>0) {
            radiance+=throughput*s.albedo*rtLocalDiffuseResponse*rtLocalProxyIrradiance(s.position,faceNormal,lights,u.counts.y,
                scene,instances,textures,atlas,functions);
        }
        if(diffuseBounces++>=2) break;
        throughput*=s.albedo;
        if(max(throughput.x,max(throughput.y,throughput.z))<0.008) break;
        r.origin=s.position+faceNormal*0.004;
        float3 bounceDirection=rtCosine(faceNormal,seed);
        // The first diffuse bounce uses the stratified pair; rtCosine still consumes its two
        // draws so every later random decision in the path is unchanged.
        if(diffuseBounces==1) bounceDirection=rtCosineFrom(faceNormal,rtR2(u.counts.x*sampleCount+sample,r2Rotation));
        r.direction=bounceDirection; r.min_distance=0.001;
    }
    radiance*=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    float bound=primarySpecular.a>0.5?4096.0:32.0;
    radiance=all(isfinite(radiance))?clamp(radiance,float3(0),float3(bound)):float3(0);
    accumulated+=radiance;
    if(sample==0) { guideDepth=primaryDepth; guideNormal=primaryNormal; guideMotion=previous;
                   guideDiffuse=primaryDiffuse; guideSpecular=primarySpecular; }
    }
    RTPathResult result;
    result.radiance=accumulated/float(sampleCount); result.depth=guideDepth;
    result.normalDistance=guideNormal; result.motion=guideMotion;
    result.diffuse=guideDiffuse; result.specular=guideSpecular;
    return result;
}

kernel void rt_pathtrace(instance_acceleration_structure scene [[buffer(0)]],
                         device const RTInstance* instances [[buffer(1)]],
                         constant RTUniforms& u [[buffer(2)]],
                         device const RTLight* lights [[buffer(3)]],
                         constant RTTextures& textures [[buffer(4)]],
                         intersection_function_table<triangle_data,instancing> functions [[buffer(5)]],
                         texture2d_array<float> atlas [[texture(0)]],
                         texture2d<float,access::write> output [[texture(1)]],
                         texture2d<float,access::write> depth [[texture(2)]],
                         texture2d<float,access::write> normals [[texture(3)]],
                         texture2d<float,access::write> motion [[texture(4)]],
                         texture2d<float,access::write> diffuseAlbedo [[texture(5)]],
                         texture2d<float,access::write> specularAlbedo [[texture(6)]],
                         texture3d<float,access::sample> localLightTexture [[texture(7)]],
                         texture2d<float,access::sample> skyRadiance [[texture(8)]],
                         uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=u.counts.z || pixel.y>=u.counts.w) return;
    float2 uv=(float2(pixel)+0.5)/float2(u.counts.zw);
    RTPathResult result=rtTracePixel(uv,pixel,u.counts.z,scene,instances,u,lights,skyRadiance,textures,functions,atlas,localLightTexture,true);
    output.write(float4(result.radiance,1),pixel);
    depth.write(float4(result.depth),pixel);
    normals.write(result.normalDistance,pixel);
    motion.write(result.motion,pixel);
    diffuseAlbedo.write(result.diffuse,pixel); specularAlbedo.write(result.specular,pixel);
}

// Deterministic fallback for native diffuse surfaces too small to receive a compatible
// low-resolution lighting sample. It preserves physical direct visibility and the same
// propagated-light/cave policy, without making a missing low-res donor a black hole.
static float3 rtNativeDiffuseIrradiance(RTSurface s,float3 rayDirection,
                                     instance_acceleration_structure scene,
                                     device const RTInstance* instances,constant RTUniforms& u,
                                     device const RTLight* lights,constant RTTextures& textures,
                                     intersection_function_table<triangle_data,instancing> functions,
                                     texture2d_array<float> atlas,
                                     texture3d<float,access::sample> localLightTexture,
                                     bool submerged=false,float3 waterTint=float3(0.2,0.45,0.65)) {
    float3 normal=dot(s.normal,rayDirection)<0?s.normal:-s.normal;
    float3 irradiance=rtCachedDiffuseIrradiance(s,normal,u,localLightTexture);
    float3 sun=normalize(u.atmosphere.sunDaylight.xyz);
    bool sunlight=sun.y>0;
    float3 direction=sunlight?sun:-sun;
    float cosine=rtDirectLightCosine(normal,direction,s.flags);
    if(u.atmosphere.options.x<0.5 && cosine>0) {
        float strength=sunlight?u.atmosphere.sunDaylight.w*2.5*smoothstep(0.0,0.04,sun.y):0.085*elyNonSunLightOutput;
        float3 color=sunlight?mix(float3(1,0.53,0.24),float3(1,0.96,0.88),smoothstep(0.03,0.5,sun.y)):float3(0.40,0.55,0.9);
        float3 visibility=u.params.w>0.5
            ?rtVisibility(s.position,normal,direction,u.params.x,scene,instances,textures,atlas,functions,
                          submerged,waterTint):float3(1);
        if(any(visibility>float3(0)))
            irradiance+=color*visibility*(cosine*strength*elyCloudSunTransmittanceAir(s.position+u.atmosphere.cameraTime.xyz,u.atmosphere));
    }
    if(u.heldLight.w>0) {
        float3 delta=float3(0.30,-0.30,0.25)-s.position;
        float distance=length(delta);
        if(distance>0.001 && distance<u.heldLight.w) {
            float fall=pow(clamp(1-distance/u.heldLight.w,0.0,1.0),2.0);
            float facing=max(0.0,dot(normal,delta/distance));
            if(facing>0) irradiance+=u.heldLight.rgb
                *rtVisibility(s.position,normal,delta/distance,distance,scene,instances,textures,atlas,functions)
                *(fall*facing*2.5*rtLocalDiffuseResponse);
        }
    }
    if(u.counts.y>0) irradiance+=rtLocalDiffuseResponse
        *rtLocalProxyIrradiance(s.position,normal,lights,u.counts.y,scene,instances,textures,atlas,functions);
    float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    return irradiance*exposure;
}

struct RTDonors { float3 sum; float total; };

// Joint-bilateral donors from the low-resolution lighting image around a native pixel.
// ring 1 is the original 3x3 neighbourhood; ring 2 adds only the outer 5x5 texels.
static RTDonors rtGatherDonors(float2 uv,float3 position,float3 planeNormal,float3 matchNormal,
                               float materialType,float basis,float planeTolerance,int ring,
                               texture2d<float,access::sample> lowDenoised,texture2d<float,access::read> lowDepth,
                               texture2d<float,access::read> lowNormalDistance,texture2d<float,access::read> lowDiffuse,
                               texture2d<float,access::read> lowSpecular,constant RTUniforms& u) {
    constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
    RTDonors result; result.sum=float3(0); result.total=0;
    uint2 lowSize(lowDepth.get_width(),lowDepth.get_height());
    float2 lowPosition=uv*float2(lowSize)-0.5;
    int2 center=int2(floor(lowPosition+0.5));
    for(int y=-ring;y<=ring;++y) for(int x=-ring;x<=ring;++x) {
        if(ring>1 && abs(x)<=1 && abs(y)<=1) continue;
        int2 q=center+int2(x,y);
        if(any(q<0) || any(q>=int2(lowSize))) continue;
        float d=lowDepth.read(uint2(q)).x;
        float4 n=lowNormalDistance.read(uint2(q));
        float type=lowDiffuse.read(uint2(q)).a;
        float lowBasis=lowSpecular.read(uint2(q)).a;
        if(d>=0.999999 || !isfinite(d) || !all(isfinite(n))
           || abs(type-materialType)>0.05 || abs(lowBasis-basis)>0.1) continue;
        float alignment=dot(n.xyz,matchNormal);
        if(alignment<0.94) continue;
        float2 sampleUV=(float2(q)+0.5)/float2(lowSize);
        float4 samplePosition=u.inverseViewProjection*float4(sampleUV.x*2-1,1-sampleUV.y*2,d,1);
        if(!all(isfinite(samplePosition)) || abs(samplePosition.w)<0.000001) continue;
        float planeError=abs(dot(samplePosition.xyz/samplePosition.w-position,planeNormal));
        if(planeError>=planeTolerance) continue;
        float2 offset=float2(q)-lowPosition;
        float weight=exp(-dot(offset,offset)*0.65)*pow(max(alignment,0.0),8.0)*(1-planeError/planeTolerance);
        float3 value=lowDenoised.sample(nearest,sampleUV).rgb;
        if(!all(isfinite(value))) continue;
        result.sum+=value*weight; result.total+=weight;
    }
    return result;
}

// Sky visibility for a deterministic indirect estimate: one ray along the normal bent toward the
// zenith, through leaves, glass and water with their usual transmission. Voxel skylight alone
// barely registers a canopy overhead, so shaded seabeds under trees glowed with open-sky light.
static float rtSkyOcclusion(float3 position,float3 normal,bool submerged,float3 waterTint,
                            instance_acceleration_structure scene,device const RTInstance* instances,
                            constant RTTextures& textures,texture2d_array<float> atlas,
                            intersection_function_table<triangle_data,instancing> functions) {
    float3 direction=normalize(normal+float3(0,1,0)*1.2);
    if(dot(direction,normal)<0.05) direction=normal;
    return rtLuminance(rtVisibility(position,normal,direction,48.0,scene,instances,textures,atlas,functions,
                                    submerged,waterTint));
}

// Deterministic irradiance for a native pixel with too few compatible low-resolution donors.
// Out of line for the same compiler-service limit as rtNativeWater.
__attribute__((noinline)) static float3 rtNativeFallbackIrradiance(RTSurface s,float3 direction,
        instance_acceleration_structure scene,device const RTInstance* instances,constant RTUniforms& u,
        device const RTLight* lights,texture2d<float,access::sample> skyRadiance,constant RTTextures& textures,
        intersection_function_table<triangle_data,instancing> functions,texture2d_array<float> atlas,
        texture3d<float,access::sample> localLightTexture) {
    float3 normal=dot(s.normal,direction)<0?s.normal:-s.normal;
    return rtNativeDiffuseIrradiance(s,direction,scene,instances,u,lights,textures,functions,atlas,localLightTexture)
        +rtFallbackIndirect(s,normal,rtSkyAmbient(skyRadiance),u)
         *rtSkyOcclusion(s.position,normal,false,float3(0.2,0.45,0.65),scene,instances,textures,atlas,functions);
}

// Deterministic shading for a surface seen in a native water reflection: authored albedo, direct
// light with a real shadow ray, the cached local/sky terms, and a sky-ambient stand-in for the
// bounce light the low-resolution image gives directly viewed terrain. Exposed radiance.
static float3 rtNativeReflectedShade(RTSurface s,float3 direction,float3 skyAmbient,float weight,
                                     instance_acceleration_structure scene,device const RTInstance* instances,
                                     constant RTUniforms& u,device const RTLight* lights,
                                     texture2d<float,access::sample> skyRadiance,constant RTTextures& textures,
                                     intersection_function_table<triangle_data,instancing> functions,
                                     texture2d_array<float> atlas,texture3d<float,access::sample> localLightTexture) {
    float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    float3 normal=dot(s.normal,direction)<0?s.normal:-s.normal;
    if((s.flags&2u)!=0) {
        // Distant water seen in water: a sky-tinted sheen, not an opaque texel.
        return rtSkyRadiance(skyRadiance,reflect(direction,normal))*exposure*0.6;
    }
    if(weight<0.1) {
        // A reflection weighted below 10% (most water seen from above) does not merit two shadow
        // rays and a cloud march: cached light, skylight-occluded sun and sky, no extra rays.
        float3 sun=normalize(u.atmosphere.sunDaylight.xyz);
        bool day=sun.y>0;
        float3 toLight=day?sun:-sun;
        float strength=day?u.atmosphere.sunDaylight.w*2.5*smoothstep(0.0,0.04,sun.y):0.085*elyNonSunLightOutput;
        float3 color=day?mix(float3(1,0.53,0.24),float3(1,0.96,0.88),smoothstep(0.03,0.5,sun.y)):float3(0.40,0.55,0.9);
        float sky=clamp(s.sky,0.0,1.0);
        float3 irradiance=rtCachedDiffuseIrradiance(s,normal,u,localLightTexture)*exposure
            +(u.atmosphere.options.x<0.5?color*(strength*rtDirectLightCosine(normal,toLight,s.flags)*sky*sky)*exposure:float3(0))
            +rtFallbackIndirect(s,normal,skyAmbient,u);
        return s.albedo*(irradiance+s.emission*exposure);
    }
    float3 irradiance=rtNativeDiffuseIrradiance(s,direction,scene,instances,u,lights,textures,functions,
                                                atlas,localLightTexture)
        +rtFallbackIndirect(s,normal,skyAmbient,u)
         *rtSkyOcclusion(s.position,normal,false,float3(0.2,0.45,0.65),scene,instances,textures,atlas,functions);
    return s.albedo*(irradiance+s.emission*exposure);
}

// Top water seen from air at native resolution: band-limited waves, exact Fresnel, a real mirror
// ray, a real refracted ray to the seabed (native texture, low-resolution irradiance with bounce
// light), Beer-Lambert medium over the actual depth, wave-focused caustics, an analytic sun or
// moon glint and shoreline foam. Deterministic, so nothing here needs temporal accumulation.
// Kept out of line: fully inlined into rt_surface_resolve (with its transport fallbacks), the
// Apple GPU compiler service crashed (XPC_ERROR_CONNECTION_INTERRUPTED) building the pipeline.
__attribute__((noinline)) static float3 rtNativeWater(RTSurface surface,float3 viewDirection,float2 uv,float3 pixelRayX,float3 pixelRayY,
                            instance_acceleration_structure scene,device const RTInstance* instances,
                            constant RTUniforms& u,device const RTLight* lights,
                            texture2d<float,access::sample> skyRadiance,constant RTTextures& textures,
                            intersection_function_table<triangle_data,instancing> functions,
                            texture2d_array<float> atlas,texture3d<float,access::sample> localLightTexture,
                            texture2d<float,access::sample> lowDenoised,texture2d<float,access::read> lowDepth,
                            texture2d<float,access::read> lowNormalDistance,texture2d<float,access::read> lowDiffuse,
                            texture2d<float,access::read> lowSpecular,thread float3& guideNormal) {
    float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    float3 up=surface.normal.y>=0?surface.normal:-surface.normal;
    float3 worldPosition=surface.position+u.atmosphere.cameraTime.xyz;
    float waveTime=u.atmosphere.options.y>0.5?0.0:u.atmosphere.cameraTime.w;
    float rain=u.atmosphere.weather.x;
    float distance=length(surface.position);
    float pixelAngle=max(length(normalize(pixelRayX)-viewDirection),1e-5);
    float footprint=distance*pixelAngle/max(abs(dot(viewDirection,up)),0.03);
    ElyWaterSurface wave=elyWaterSurface(worldPosition,up,waveTime,rain,footprint);
    float3 n=wave.normal;
    if(dot(n,viewDirection)>-0.001) n=up;
    guideNormal=n;
    float fresnel=elyDielectricFresnel(clamp(-dot(n,viewDirection),0.0,1.0),1.0,1.333);
    float offset=rtSurfaceOffset(surface.position);
    float3 waterTint=pow(surface.albedo,float3(1.0/2.2));
    float daylight=u.atmosphere.sunDaylight.w;
    float3 sun=normalize(u.atmosphere.sunDaylight.xyz);
    bool sunlight=sun.y>0;
    float3 lightDirection=sunlight?sun:-sun;
    float lightStrength=sunlight?daylight*2.5*smoothstep(0.0,0.04,sun.y):0.085*elyNonSunLightOutput;
    float3 lightColor=sunlight?mix(float3(1,0.53,0.24),float3(1,0.96,0.88),smoothstep(0.03,0.5,sun.y)):float3(0.40,0.55,0.9);
    float3 skyAmbient=rtSkyAmbient(skyRadiance);
    float plane=dot(up,surface.position);

    // Reflection. A planar mirror images the camera across the water plane, which gives exact
    // texture differentials for the reflected surface (wave tilt only bends the central ray).
    float3 reflectedDirection=rtAboveHorizon(reflect(viewDirection,n),up);
    ray mirror; mirror.origin=surface.position+up*offset; mirror.direction=reflectedDirection;
    mirror.min_distance=0.001; mirror.max_distance=u.params.x;
    float3 mirroredCamera=up*(2.0*plane);
    RTSurface reflected=rtIntersect(mirror,scene,instances,textures,atlas,functions,0xff,
        reflect(pixelRayX,up),reflect(pixelRayY,up),mirroredCamera,mirroredCamera);
    float3 reflectedRadiance=reflected.hit
        ? rtNativeReflectedShade(reflected,reflectedDirection,skyAmbient,fresnel,scene,instances,u,lights,skyRadiance,
                                 textures,functions,atlas,localLightTexture)
        : rtSkyRadiance(skyRadiance,reflectedDirection)*exposure;
    if(reflected.hit && u.fogParameters.y>=64) {
        // Distance fog belongs to the whole light path. Terrain that is fully fogged when seen
        // directly was reflected unfogged, and ripples broke it into dark dashes on distant
        // water. rt_media fogs this pixel by its own distance; add only the reflected segment's
        // share so the reflection reaches the sky exactly where camera+mirror path would.
        float span=max(0.01,u.fogParameters.y-u.fogParameters.x);
        float direct=clamp((distance-u.fogParameters.x)/span,0.0,1.0);
        float total=clamp((distance+reflected.distance-u.fogParameters.x)/span,0.0,1.0);
        float extra=clamp((total*total-direct*direct)/max(1e-4,1.0-direct*direct),0.0,1.0);
        reflectedRadiance=mix(reflectedRadiance,rtSkyRadiance(skyRadiance,reflectedDirection)*exposure,extra);
    }

    // Refraction to the seabed with bent pixel differentials (flat-plane approximation).
    float3 refractedDirection=normalize(refract(viewDirection,n,1.0/1.333));
    ray below; below.origin=surface.position-up*offset; below.direction=refractedDirection;
    below.min_distance=0.001; below.max_distance=u.params.x;
    float3 originX(0),originY(0),bentX(0),bentY(0);
    float denominatorX=dot(up,pixelRayX), denominatorY=dot(up,pixelRayY);
    if(abs(denominatorX)>1e-4 && abs(denominatorY)>1e-4) {
        originX=pixelRayX*(plane/denominatorX); originY=pixelRayY*(plane/denominatorY);
        bentX=refract(normalize(pixelRayX),up,1.0/1.333); bentY=refract(normalize(pixelRayY),up,1.0/1.333);
    }
    RTSurface seabed=rtIntersect(below,scene,instances,textures,atlas,functions,0xff,bentX,bentY,originX,originY);
    float pathInWater=seabed.hit?seabed.distance:96.0;
    float verticalDepth=pathInWater*abs(dot(refractedDirection,up));
    float3 transmittance=elyWaterTransmittance(pathInWater,waterTint);
    float3 transmitted=elyWaterScattering(transmittance,waterTint,daylight)*exposure;
    if(seabed.hit) {
        RTDonors donors=rtGatherDonors(uv,surface.position,up,up,0.85,3.0,max(0.025,distance*0.001),1,
                                       lowDenoised,lowDepth,lowNormalDistance,lowDiffuse,lowSpecular,u);
        float confidence=smoothstep(0.02,0.20,donors.total);
        float3 irradiance=donors.total>0.00001?donors.sum/donors.total:float3(0);
        if(confidence<1) {
            float3 seabedNormal=dot(seabed.normal,refractedDirection)<0?seabed.normal:-seabed.normal;
            float3 fallback=rtNativeDiffuseIrradiance(seabed,refractedDirection,scene,instances,u,lights,textures,
                functions,atlas,localLightTexture,true,waterTint)
                +rtFallbackIndirect(seabed,seabedNormal,skyAmbient,u)
                 *rtSkyOcclusion(seabed.position,seabedNormal,true,waterTint,scene,instances,textures,atlas,functions);
            irradiance=mix(fallback,irradiance,confidence);
        }
        if(sunlight && lightStrength>0) {
            // Caustics: a convex (crest) surface above focuses sunlight on the seabed. The same
            // band-limited waves at the sun's entry point give a zero-mean focus term that fades
            // with depth and with the seabed pixel footprint, so distant seabeds do not shimmer.
            float3 sunInWater=-refract(-lightDirection,up,1.0/1.333);
            float3 entry=seabed.position+sunInWater*(verticalDepth/max(sunInWater.y,0.2));
            float seabedFootprint=(distance+pathInWater)*pixelAngle;
            ElyWaterSurface above=elyWaterSurface(entry+u.atmosphere.cameraTime.xyz,up,waveTime,rain,seabedFootprint);
            float focus=-above.laplacian*verticalDepth*1.1*exp(-verticalDepth/7.0);
            float strength=smoothstep(0.0,0.2,lightDirection.y)*clamp(daylight,0.0,1.0);
            irradiance*=clamp(1.0+focus*strength,0.35,2.2);
        }
        transmitted+=transmittance*seabed.albedo*(irradiance+seabed.emission*exposure);
    }

    float3 color=fresnel*reflectedRadiance+(1-fresnel)*transmitted;

    // Sun or moon glint: GGX with roughness from the waves the footprint removed, so distant water
    // becomes a broad sheen instead of sparkle. One shadow ray only where the lobe matters.
    float nl=dot(n,lightDirection);
    if(nl>0 && lightStrength>0) {
        float alpha2=0.0009+2.0*wave.variance+0.004*clamp(rain,0.0,1.0);
        float3 h=normalize(lightDirection-viewDirection);
        float nh=max(dot(n,h),0.0), nv=max(-dot(n,viewDirection),0.001);
        float d=nh*nh*(alpha2-1.0)+1.0;
        float distribution=alpha2/(3.14159265359*d*d);
        float fh=elyDielectricFresnel(max(dot(-viewDirection,h),0.0),1.0,1.333);
        float gv=nl*sqrt(nv*nv*(1-alpha2)+alpha2), gl=nv*sqrt(nl*nl*(1-alpha2)+alpha2);
        float lobe=distribution*fh*(0.5/max(gv+gl,1e-4))*nl;
        if(lobe*lightStrength>0.002) {
            float3 visible=u.params.w>0.5
                ?rtVisibility(surface.position,up,lightDirection,u.params.x,scene,instances,textures,atlas,functions,
                              false,float3(0.2,0.45,0.65),true):float3(1);
            float clouds=sunlight && any(visible>float3(0))?elyCloudSunTransmittanceAir(worldPosition,u.atmosphere):1.0;
            color+=lightColor*visible*(lightStrength*lobe*clouds*exposure);
        }
    }
    if(seabed.hit) {
        float foam=elyWaterFoam(verticalDepth,worldPosition,waveTime,rain);
        color=mix(color,float3(0.74,0.82,0.83)*max(0.12,daylight)*exposure,foam);
    }
    return color;
}

// Native primary visibility and authored materials are never inferred from an upscaled
// RGB image. Only eligible diffuse irradiance is reconstructed across a bounded 3x3
// neighborhood. Camera fog/clouds consume these native primary guides in the next pass.
kernel void rt_surface_resolve(instance_acceleration_structure scene [[buffer(0)]],
                         device const RTInstance* instances [[buffer(1)]],
                         constant RTUniforms& u [[buffer(2)]],
                         device const RTLight* lights [[buffer(3)]],
                         constant RTTextures& textures [[buffer(4)]],
                         intersection_function_table<triangle_data,instancing> functions [[buffer(5)]],
                         texture2d_array<float> atlas [[texture(0)]],
                         texture2d<float,access::sample> lowDenoised [[texture(1)]],
                         texture2d<float,access::read> lowDepth [[texture(2)]],
                         texture2d<float,access::read> lowNormalDistance [[texture(3)]],
                         texture2d<float,access::read> lowDiffuse [[texture(4)]],
                         texture2d<float,access::write> fullRadiance [[texture(5)]],
                         texture2d<float,access::write> fullDepth [[texture(6)]],
                         texture2d<float,access::write> fullNormalDistance [[texture(7)]],
                         texture3d<float,access::sample> localLightTexture [[texture(8)]],
                         texture2d<float,access::read> lowSpecular [[texture(9)]],
                         texture2d<float,access::sample> skyRadiance [[texture(10)]],
                         uint2 pixel [[thread_position_in_grid]]) {
    uint2 fullSize(fullRadiance.get_width(),fullRadiance.get_height());
    if(any(pixel>=fullSize)) return;
    float2 uv=(float2(pixel)+0.5)/float2(fullSize);
    float4 farPoint=u.inverseViewProjection*float4(uv.x*2-1,1-uv.y*2,1,1);
    float4 farX=farPoint+u.inverseViewProjection*float4(2.0/float(fullSize.x),0,0,0);
    float4 farY=farPoint+u.inverseViewProjection*float4(0,-2.0/float(fullSize.y),0,0);
    float3 pixelRayX=farX.xyz/farX.w,pixelRayY=farY.xyz/farY.w;
    ray primary; primary.origin=float3(0); primary.direction=normalize(farPoint.xyz/farPoint.w);
    primary.min_distance=0.005; primary.max_distance=u.params.x;
    uint seed=rtHash(rtHash(pixel.x+pixel.y*fullSize.x)^rtHash(u.counts.x*4u+0x9e3779b9u));
    RTSurface surface; surface.hit=false;
    bool encounteredFade=false;
    for(uint event=0;event<7;++event) {
        RTSurface candidate=rtIntersect(primary,scene,instances,textures,atlas,functions,0x01,pixelRayX,pixelRayY);
        if(!candidate.hit) break;
        if((candidate.flags&8u)!=0 && instances[candidate.instance].tint.a<1.0) {
            encounteredFade=true;
            if(rtUnit(seed)>instances[candidate.instance].tint.a) {
                primary.origin=candidate.position+primary.direction*0.004;
                primary.min_distance=0.001;
                continue;
            }
        }
        surface=candidate; break;
    }
    constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
    bool air=u.atmosphere.weather.w<0.5;
    float3 radiance(0);
    float depthValue=1;
    float4 normalDistance(0,0,0,u.params.x);
    if(surface.hit) {
        float4 clip=u.viewProjection*float4(surface.position,1);
        depthValue=clamp(clip.z/clip.w,0.0,1.0);
        normalDistance=float4(surface.normal,length(surface.position));
        bool dielectric=(surface.flags&6u)!=0,metal=(surface.flags&16u)!=0;
        bool demodulated=u.quality.w>0.5 && air && !dielectric && !metal && !encounteredFade;
        float basis=demodulated?((surface.flags&32u)!=0?2.0:1.0):rtRadianceBasis(surface.flags);
        float materialType=dielectric?0.06:(metal?0.16:0.85);
        float3 faceNormal=dot(surface.normal,primary.direction)<0?surface.normal:-surface.normal;
        float3 matchNormal=dielectric?faceNormal:surface.normal;
        normalDistance.xyz=matchNormal;
        bool nativeWater=u.quality.w>0.5 && air && !encounteredFade && (surface.flags&2u)!=0 && faceNormal.y>0.65;
        if(nativeWater) {
            float3 guide=matchNormal;
            radiance=rtNativeWater(surface,primary.direction,uv,pixelRayX,pixelRayY,scene,instances,u,lights,
                skyRadiance,textures,functions,atlas,localLightTexture,
                lowDenoised,lowDepth,lowNormalDistance,lowDiffuse,lowSpecular,guide);
            normalDistance.xyz=guide;
        } else {
        float planeTolerance=max(0.025,length(surface.position)*0.001);
        RTDonors donors=rtGatherDonors(uv,surface.position,surface.normal,matchNormal,materialType,basis,planeTolerance,1,
                                       lowDenoised,lowDepth,lowNormalDistance,lowDiffuse,lowSpecular,u);
        float3 sum=donors.sum; float total=donors.total;
        if(demodulated) {
            // Smooth donor confidence prevents a hard lighting jump when one small surface
            // crosses the sampling grid. Most interiors take only reconstructed irradiance.
            float confidence=smoothstep(0.02,0.20,total);
            if(confidence<1) {
                // Widen before substituting deterministic light: a distant or thin surface usually
                // has compatible donors one texel further out. Beyond 48 blocks, sub-texel height
                // steps between terraces are tolerated, removing salt-and-pepper grain at range.
                float range=length(surface.position);
                RTDonors outer=rtGatherDonors(uv,surface.position,surface.normal,matchNormal,materialType,basis,
                    range>48?max(planeTolerance,range*0.03):planeTolerance,2,
                    lowDenoised,lowDepth,lowNormalDistance,lowDiffuse,lowSpecular,u);
                sum+=outer.sum; total+=outer.total;
                confidence=smoothstep(0.02,0.20,total);
            }
            float3 irradiance=total>0.00001?sum/total:float3(0);
            if(confidence<1) {
                float3 fallback=rtNativeFallbackIrradiance(surface,primary.direction,scene,instances,u,lights,
                    skyRadiance,textures,functions,atlas,localLightTexture);
                irradiance=mix(fallback,irradiance,confidence);
            }
            float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
            radiance=surface.albedo*(irradiance+surface.emission*exposure);
        } else if(total>0.00001 && !encounteredFade) radiance=sum/total;
        else radiance=rtTracePixel(uv,pixel,fullSize.x,scene,instances,u,lights,skyRadiance,textures,functions,atlas,localLightTexture,false).radiance;
        }
    } else if(!air || encounteredFade) {
        // Air sky is deterministic and resolved in rt_media. Preserve existing submerged
        // transport and stochastic-body samples rather than inventing a nearest donor.
        radiance=rtTracePixel(uv,pixel,fullSize.x,scene,instances,u,lights,skyRadiance,textures,functions,atlas,localLightTexture,false).radiance;
    }
    radiance=all(isfinite(radiance))?clamp(radiance,float3(0),float3(32)):float3(0);
    fullRadiance.write(float4(radiance,1),pixel);
    fullDepth.write(float4(depthValue),pixel);
    fullNormalDistance.write(normalDistance,pixel);
}

kernel void rt_sky_radiance(texture2d<float,access::write> output [[texture(0)]],
                            constant RTUniforms& u [[buffer(0)]],uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=output.get_width() || pixel.y>=output.get_height()) return;
    float2 uv=(float2(pixel)+0.5)/float2(output.get_width(),output.get_height());
    float3 value=elyAtmosphereRadianceAir(u.atmosphere.cameraTime.xyz,rtSkyDirection(uv),u.atmosphere,false);
    output.write(float4(all(isfinite(value))?clamp(value,float3(0),float3(64)):float3(0),1),pixel);
}

kernel void rt_media(texture2d<float,access::sample> reconstructed [[texture(0)]],
                     texture2d<float,access::read> depth [[texture(1)]],
                     texture2d<float,access::read> normalDistance [[texture(2)]],
                     texture2d<float,access::write> output [[texture(3)]],
                     constant RTUniforms& u [[buffer(0)]],uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=output.get_width() || pixel.y>=output.get_height()) return;
    float2 uv=(float2(pixel)+0.5)/float2(output.get_width(),output.get_height());
    constexpr sampler linearClamp(coord::normalized,address::clamp_to_edge,filter::linear);
    float3 color=reconstructed.sample(linearClamp,uv).rgb;
    color=all(isfinite(color))?max(color,float3(0)):float3(0);
    uint2 guideSize(depth.get_width(),depth.get_height());
    uint2 guidePixel=min(uint2(uv*float2(guideSize)),guideSize-1);
    float primaryDepth=depth.read(guidePixel).x;
    float primaryDistance=normalDistance.read(guidePixel).w;
    float fog=clamp((primaryDistance-u.fogParameters.x)/max(0.01,u.fogParameters.y-u.fogParameters.x),0.0,1.0);
    bool gameplayFog=u.fogParameters.y<64;
    bool surface=primaryDepth<0.999999, air=u.atmosphere.weather.w<0.5;
    float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    if(air) {
        float4 farPoint=u.inverseViewProjection*float4(uv.x*2-1,1-uv.y*2,1,1);
        float3 direction=normalize(farPoint.xyz/farPoint.w);
        // Clouds in front of a visible surface are a finite segment, not a second full sky.
        // At complete distance fade, only the shared full atmosphere is needed, avoiding two
        // cloud marches. Secondary sky and water-medium transport remain in the path tracer.
        if(surface && (gameplayFog || fog<1.0)) {
            float4 cloud=elyCloudLayerForRay(u.atmosphere.cameraTime.xyz,direction,u.atmosphere,primaryDistance,true);
            color=cloud.rgb*exposure+color*cloud.a;
        }
        if(!surface || (!gameplayFog && fog>0)) {
            float3 background=clamp(elyAtmosphereRadianceAir(u.atmosphere.cameraTime.xyz,direction,u.atmosphere,true)
                                    *exposure,float3(0),float3(32));
            // Loaded geometry fades into this SAME direction-dependent atmosphere as an
            // adjacent ray miss. Constant gray fog exposes the outline of loaded terrain
            // against clouds, even when the foreground cloud composition order is correct.
            color=surface?mix(color,background,fog*fog):background;
        }
    } else if(!gameplayFog && surface) {
        // Preserve submerged primary transport rather than replacing it with an air sky.
        color=mix(color,rtLinear(u.atmosphere.fogColor.rgb),fog*fog);
    }
    // Short-range blindness/lava/snow is a true foreground visibility constraint. Apply it
    // last to geometry and sky alike, so visible clouds cannot defeat the gameplay effect.
    if(gameplayFog)
        color=mix(color,rtLinear(u.atmosphere.fogColor.rgb),fog*fog);
    output.write(float4(color,1),pixel);
}

kernel void rt_temporal(texture2d<float,access::read> current [[texture(0)]],
                        texture2d<float,access::read> depth [[texture(1)]],
                        texture2d<float,access::read> normal [[texture(2)]],
                        texture2d<float,access::read> motion [[texture(3)]],
                        texture2d<float,access::sample> previousColor [[texture(4)]],
                        texture2d<float,access::sample> previousDepth [[texture(5)]],
                        texture2d<float,access::sample> previousNormal [[texture(6)]],
                        texture2d<float,access::write> result [[texture(7)]],
                        constant RTUniforms& u [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=current.get_width() || p.y>=current.get_height()) return;
    float4 c=current.read(p), n=normal.read(p), motionData=motion.read(p);
    if(u.params.z<0.5) { result.write(float4(c.rgb,1),p); return; }
    float d=depth.read(p).x;
    constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
    bool valid=u.params.z>0.5 && motionData.w>0.5 && all(motionData.xy>0) && all(motionData.xy<1);
    float4 old=previousColor.sample(nearest,motionData.xy);
    float4 oldNormal=previousNormal.sample(nearest,motionData.xy);
    float oldDepth=previousDepth.sample(nearest,motionData.xy).x;
    valid=valid && abs(oldDepth-motionData.z)<max(0.00005,(1.0-d)*0.035)
        && (d>=0.999999 || dot(n.xyz,oldNormal.xyz)>0.93);
    // Sky/water are animated media: shorter history prevents trailing cloud edges/ripples.
    float maxHistory=d>=0.999999?4.0:(motionData.w>1.5?12.0:32.0);
    float weight=valid?min(old.a,maxHistory):0.0;
    float3 low=c.rgb, high=c.rgb;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        uint2 q=uint2(clamp(int2(p)+int2(x,y),int2(0),int2(current.get_width()-1,current.get_height()-1)));
        float3 value=current.read(q).rgb; low=min(low,value); high=max(high,value);
    }
    if(!valid || !all(isfinite(old))) { result.write(float4(c.rgb,1),p); return; }
    old.rgb=clamp(old.rgb,low-float3(0.06),high+float3(0.06));
    result.write(float4((c.rgb+old.rgb*weight)/(weight+1),min(maxHistory,weight+1)),p);
}

kernel void rt_filter(texture2d<float,access::read> input [[texture(0)]],
                      texture2d<float,access::read> depth [[texture(1)]],
                      texture2d<float,access::read> normals [[texture(2)]],
                      texture2d<float,access::write> output [[texture(3)]],
                      texture2d<float,access::read> albedo [[texture(4)]],
                      uint2 p [[thread_position_in_grid]]) {
    if(p.x>=input.get_width() || p.y>=input.get_height()) return;
    float4 center=input.read(p), n=normals.read(p),material=albedo.read(p);
    bool diffuse=material.a>0.5;
    float3 modulation=diffuse?max(material.rgb,float3(0.04)):float3(1);
    float3 centerLight=center.rgb/modulation;
    float3 sum=centerLight; float total=1;
    // Filter illumination, not authored color. The Faithful texels are multiplied back exactly
    // after a bounded 5x5 geometry-aware kernel removes Monte Carlo variance.
    for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) {
        if(x==0 && y==0) continue;
        uint2 q=uint2(clamp(int2(p)+int2(x,y),int2(0),int2(input.get_width()-1,input.get_height()-1)));
        float4 otherN=normals.read(q), other=input.read(q),otherMaterial=albedo.read(q);
        float normalWeight=dot(n.xyz,otherN.xyz)>0.97?1:0;
        if(n.w>500 && otherN.w>500) normalWeight=1;
        float distanceWeight=exp(-abs(n.w-otherN.w)/max(0.12,n.w*0.025));
        float3 otherModulation=diffuse?max(otherMaterial.rgb,float3(0.04)):float3(1);
        float3 illumination=other.rgb/otherModulation;
        float colorWeight=exp(-length(centerLight-illumination)*0.8);
        float typeWeight=abs(material.a-otherMaterial.a)<0.15?1:0;
        float weight=normalWeight*distanceWeight*colorWeight*typeWeight*exp(-float(x*x+y*y)*0.22);
        sum+=illumination*weight; total+=weight;
    }
    output.write(float4(sum/total*modulation,1),p);
}

// Native fixture kernel uses the identical alpha/material intersection routine as the game.
kernel void rt_probe(instance_acceleration_structure scene [[buffer(0)]],
                     device const RTInstance* instances [[buffer(1)]],
                     constant RTTextures& textures [[buffer(2)]],
                     device const float4* directions [[buffer(3)]],
                     device float4* results [[buffer(4)]],
                     intersection_function_table<triangle_data,instancing> functions [[buffer(5)]],
                     texture2d_array<float> atlas [[texture(0)]],
                     uint id [[thread_position_in_grid]]) {
    ray r; r.origin=float3(0); r.direction=normalize(directions[id].xyz);
    r.min_distance=0.001; r.max_distance=100;
    RTSurface s=rtIntersect(r,scene,instances,textures,atlas,functions);
    results[id]=float4(s.hit?s.distance:-1,s.hit?s.albedo:float3(0));
}
"""
