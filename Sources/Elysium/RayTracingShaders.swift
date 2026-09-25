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

// Pure alpha rejection lets hardware continue traversal after transparent texels.
// No payload writes, random draws or transmission accumulation: candidate calls
// may repeat or arrive out of depth order. Shade only the final nearest hit.
[[intersection(triangle,triangle_data,instancing)]]
bool rt_alpha_accept(float2 bary [[barycentric_coord]],uint instanceID [[instance_id]],
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
    return !(((p.material.z&1u)!=0 && coverage<cutoff) || alpha<0.005);
}

static RTFilteredHit rtFilteredIntersection(ray r,instance_acceleration_structure scene,
                            device const RTInstance* instances,constant RTTextures& textures,
                            texture2d_array<float> atlas,
                            intersection_function_table<triangle_data,instancing> functions,uint rayMask,
                            bool sampleSurfaceColor=true,float3 pixelRayX=float3(0),float3 pixelRayY=float3(0)) {
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
    // Camera-ray differentials intersect the accepted hit's plane analytically: no
    // extra scene rays. Filter only subpixel material detail, after exact alpha traversal.
    // The inverse-transpose also transforms UV covectors under scaled instances.
    if((p.material.z&8u)==0 && atlas.get_num_mip_levels()>1 && any(pixelRayX!=float3(0))) {
        float3 normal=normalize((instance.normalTransform*float4(p.normalEmission.xyz,0)).xyz);
        float3 position=r.origin+r.direction*hit.distance;
        float plane=dot(normal,position), dx=dot(normal,pixelRayX), dy=dot(normal,pixelRayY);
        if(abs(dx)>1e-6 && abs(dy)>1e-6) {
            float3 dpdx=pixelRayX*(plane/dx)-position, dpdy=pixelRayY*(plane/dy)-position;
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
                            float3 pixelRayX=float3(0),float3 pixelRayY=float3(0)) {
    RTSurface result; result.hit=false;
    RTFilteredHit hit=rtFilteredIntersection(r,scene,instances,textures,atlas,functions,rayMask,true,pixelRayX,pixelRayY);
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
                           intersection_function_table<triangle_data,instancing> functions) {
    ray r; r.origin=position+normal*0.003; r.direction=direction;
    r.min_distance=0.001; r.max_distance=max(0.002,distance-0.008);
    float3 transmission(1);
    for(uint layer=0;layer<8;++layer) {
        RTFilteredHit hit=rtFilteredIntersection(r,scene,instances,textures,atlas,functions,0xff,false);
        if(!hit.hit) return transmission;
        const device RTPrimitive& p=*hit.primitive;
        const device RTInstance& instance=instances[hit.instance];
        uint flags=p.material.z;
        if((flags&32u)!=0) transmission*=0.62;
        else if((flags&2u)!=0) transmission*=float3(0.7,0.86,0.92);
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
                         device const RTLight* lights,constant RTTextures& textures,
                         intersection_function_table<triangle_data,instancing> functions,
                         texture2d_array<float> atlas,
                         texture3d<float,access::sample> localLightTexture,bool allowFactor) {
    float4 farPoint=u.inverseViewProjection*float4(uv.x*2-1,1-uv.y*2,1,1);
    float2 pixelStep=2.0/float2(noiseWidth,float(noiseWidth)*float(u.counts.w)/float(u.counts.z));
    float4 farX=farPoint+u.inverseViewProjection*float4(pixelStep.x,0,0,0);
    float4 farY=farPoint+u.inverseViewProjection*float4(0,-pixelStep.y,0,0);
    float3 pixelRayX=farX.xyz/farX.w,pixelRayY=farY.xyz/farY.w;
    float3 accumulated(0);
    float guideDepth=1; float4 guideNormal(0),guideMotion(0),guideDiffuse(1,1,1,1),guideSpecular(0);
    bool primarySolarValid=false;
    uint primarySolarInstance=0,primarySolarFlags=0;
    float3 primarySolarPosition(0),primarySolarNormal(0),primarySolarIrradiance(0);
    RTSurface primarySurface;
    bool factorPixel=allowFactor && u.quality.w>0.5 && u.atmosphere.weather.w<0.5;
    uint sampleCount=clamp(uint(u.quality.x),2u,4u);
    for(uint sample=0;sample<sampleCount;++sample) {
    uint seed=rtHash(pixel.x+pixel.y*noiseWidth)^rtHash(u.counts.x*4u+sample+0x9e3779b9u);
    seed=rtHash(seed);
    ray r; r.origin=float3(0); r.direction=normalize(farPoint.xyz/farPoint.w);
    r.min_distance=0.005; r.max_distance=u.params.x;
    float3 throughput(1), radiance(0), waterTint(0.2,0.45,0.65);
    bool insideWater=u.atmosphere.weather.w>0.5;
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
        if(insideWater) {
            float3 trans=elyWaterTransmittance(segment,waterTint);
            radiance+=throughput*elyWaterScattering(trans,waterTint,u.atmosphere.sunDaylight.w);
            throughput*=trans;
        }
        if(!s.hit) {
            // The initial air background is deterministic, not Monte Carlo radiance. Resolve
            // it with camera media after denoising so sky and fully faded terrain share the
            // exact same atmospheric boundary. Underwater and secondary paths stay here.
            if(primaryPending && !insideWater) break;
            float3 absoluteOrigin=r.origin+u.atmosphere.cameraTime.xyz;
            float3 environment=insideWater
                ? elyAtmosphereRadiance(absoluteOrigin,r.direction,u.atmosphere,true)
                : elyAtmosphereRadianceAir(absoluteOrigin,r.direction,u.atmosphere,true);
            radiance+=throughput*environment;
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
        if(!factorPrimary) radiance+=throughput*s.albedo*s.emission;
        bool water=(s.flags&2u)!=0, glass=(s.flags&4u)!=0;
        if(water || glass) {
            float waveTime=u.atmosphere.options.y>0.5?0.0:u.atmosphere.cameraTime.w;
            float3 n=water?elyWaterNormal(worldPosition,faceNormal,waveTime,u.atmosphere.weather.x):faceNormal;
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
                primaryNormal.xyz=n;
                // The reconstruction guide reflects the actual view-dependent dielectric
                // response, not a constant normal-incidence value at grazing water angles.
                primarySpecular.rgb=float3(max(0.02,fresnel));
            }
            r.direction=reflected?reflect(r.direction,n):normalize(refracted);
            if(!reflected) {
                if(water) { insideWater=!insideWater; waterTint=pow(s.albedo,float3(1.0/2.2)); }
                else throughput*=mix(float3(1),s.albedo,0.22);
            }
            r.origin=s.position+r.direction*0.006;
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
                        ?rtVisibility(s.position,faceNormal,lightDirection,u.params.x,scene,instances,textures,atlas,functions):float3(1);
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
                radiance+=throughput*s.albedo*solarIrradiance;
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
        r.direction=rtCosine(faceNormal,seed); r.min_distance=0.001;
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
                         uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=u.counts.z || pixel.y>=u.counts.w) return;
    float2 uv=(float2(pixel)+0.5)/float2(u.counts.zw);
    RTPathResult result=rtTracePixel(uv,pixel,u.counts.z,scene,instances,u,lights,textures,functions,atlas,localLightTexture,true);
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
                                     texture3d<float,access::sample> localLightTexture) {
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
            ?rtVisibility(s.position,normal,direction,u.params.x,scene,instances,textures,atlas,functions):float3(1);
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
        if((surface.flags&2u)!=0) {
            float waveTime=u.atmosphere.options.y>0.5?0.0:u.atmosphere.cameraTime.w;
            matchNormal=elyWaterNormal(surface.position+u.atmosphere.cameraTime.xyz,faceNormal,waveTime,u.atmosphere.weather.x);
            if(dot(matchNormal,faceNormal)<0) matchNormal=-matchNormal;
            if(dot(matchNormal,primary.direction)>-0.001) matchNormal=faceNormal;
        }
        normalDistance.xyz=matchNormal;
        uint2 lowSize(lowDepth.get_width(),lowDepth.get_height());
        float2 lowPosition=uv*float2(lowSize)-0.5;
        int2 center=int2(floor(lowPosition+0.5));
        float3 sum(0); float total=0;
        float planeTolerance=max(0.025,length(surface.position)*0.001);
        for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
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
            float planeError=abs(dot(samplePosition.xyz/samplePosition.w-surface.position,surface.normal));
            if(planeError>=planeTolerance) continue;
            float2 offset=float2(q)-lowPosition;
            float weight=exp(-dot(offset,offset)*0.65)*pow(max(alignment,0.0),8.0)*(1-planeError/planeTolerance);
            float3 value=lowDenoised.sample(nearest,sampleUV).rgb;
            if(!all(isfinite(value))) continue;
            sum+=value*weight; total+=weight;
        }
        if(demodulated) {
            // Smooth donor confidence prevents a hard lighting jump when one small surface
            // crosses the sampling grid. Most interiors take only reconstructed irradiance.
            float confidence=smoothstep(0.02,0.20,total);
            float3 irradiance=total>0.00001?sum/total:float3(0);
            if(confidence<1) {
                float3 fallback=rtNativeDiffuseIrradiance(surface,primary.direction,scene,instances,u,lights,
                    textures,functions,atlas,localLightTexture);
                irradiance=mix(fallback,irradiance,confidence);
            }
            float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
            radiance=surface.albedo*(irradiance+surface.emission*exposure);
        } else if(total>0.00001 && !encounteredFade) radiance=sum/total;
        else radiance=rtTracePixel(uv,pixel,fullSize.x,scene,instances,u,lights,textures,functions,atlas,localLightTexture,false).radiance;
    } else if(!air || encounteredFade) {
        // Air sky is deterministic and resolved in rt_media. Preserve existing submerged
        // transport and stochastic-body samples rather than inventing a nearest donor.
        radiance=rtTracePixel(uv,pixel,fullSize.x,scene,instances,u,lights,textures,functions,atlas,localLightTexture,false).radiance;
    }
    radiance=all(isfinite(radiance))?clamp(radiance,float3(0),float3(32)):float3(0);
    fullRadiance.write(float4(radiance,1),pixel);
    fullDepth.write(float4(depthValue),pixel);
    fullNormalDistance.write(normalDistance,pixel);
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
