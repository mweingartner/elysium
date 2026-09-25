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
struct RTTextures { array<texture2d<float>,512> entities [[id(0)]]; };
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

static float rtCachedIllumination(float sky,float block,constant RTUniforms& u) {
    float localLevel=clamp(block,0.0,1.0);
    // Preserve the daylight/canopy baseline, but keep enclosed unlit caves above the
    // tone mapper's near-black toe. This is a bounded visibility floor, not another lamp.
    float caveFloor=mix(0.18,0.045,clamp(sky*2,0.0,1.0));
    float cached=max(caveFloor,elyNonSunLightOutput*localLevel/(4-3*localLevel));
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

static RTSurface rtIntersect(ray r, instance_acceleration_structure scene,
                            device const RTInstance* instances, constant RTTextures& textures,
                            texture2d_array<float> atlas,uint rayMask=0xff) {
    RTSurface result; result.hit=false;
    intersector<triangle_data,instancing> trace;
    trace.assume_geometry_type(geometry_type::triangle);
    trace.force_opacity(forced_opacity::opaque);
    constexpr sampler nearest(coord::normalized,address::repeat,filter::nearest);
    // A finite continuation budget bounds malicious/all-transparent resource-pack geometry.
    for (uint skip=0; skip<96; ++skip) {
        auto hit=trace.intersect(r,scene,rayMask);
        if(hit.type==intersection_type::none) return result;
        RTPrimitive p=*(const device RTPrimitive*)hit.primitive_data;
        RTInstance instance=instances[hit.instance_id];
        float2 bary=hit.triangle_barycentric_coord;
        float2 uv=p.uv01.xy*(1-bary.x-bary.y)+p.uv01.zw*bary.x+p.uv2Light.xy*bary.y;
        float4 tex=(p.material.z&8u)!=0
            ? textures.entities[min(instance.info.x,511u)].sample(nearest,uv)
            : atlas.sample(nearest,uv,p.material.y);
        float alpha=tex.a*instance.tint.a;
        float cutoff=(p.material.z&8u)!=0?0.1:0.35;
        // Skin alpha cuts holes; instance alpha is an independent whole-body death fade.
        float coverage=(p.material.z&8u)!=0?tex.a:alpha;
        if (((p.material.z&1u)!=0 && coverage<cutoff) || alpha<0.005) {
            r.min_distance=hit.distance+0.0002; continue;
        }
        result.hit=true;
        result.distance=hit.distance;
        result.position=r.origin+r.direction*hit.distance;
        result.normal=normalize((instance.normalTransform*float4(p.normalEmission.xyz,0)).xyz);
        float3 color=tex.rgb*rtTint(p.material.x)*instance.tint.rgb;
        color=mix(color,instance.overlay.rgb,instance.overlay.a);
        result.albedo=rtLinear(clamp(color,float3(0),float3(1)));
        result.alpha=alpha;
        result.emission=p.normalEmission.w;
        result.sky=p.uv2Light.z; result.block=p.uv2Light.w;
        result.flags=p.material.z;
        result.instance=hit.instance_id;
        return result;
    }
    // Conservatively occlude at the budget, never leak sunlight through a deep alpha stack.
    result.hit=true; result.distance=r.min_distance;
    result.position=r.origin+r.direction*r.min_distance;
    result.normal=-r.direction; result.albedo=float3(0); result.alpha=1;
    result.emission=0; result.sky=0; result.block=0; result.flags=0; result.instance=0;
    return result;
}

static float3 rtVisibility(float3 position,float3 normal,float3 direction,float distance,
                           instance_acceleration_structure scene,device const RTInstance* instances,
                           constant RTTextures& textures,texture2d_array<float> atlas) {
    ray r; r.origin=position+normal*0.003; r.direction=direction;
    r.min_distance=0.001; r.max_distance=max(0.002,distance-0.008);
    float3 transmission(1);
    intersector<triangle_data,instancing> trace;
    trace.assume_geometry_type(geometry_type::triangle);
    trace.force_opacity(forced_opacity::opaque);
    constexpr sampler nearest(coord::normalized,address::repeat,filter::nearest);
    for(uint layer=0;layer<8;++layer) {
        bool accepted=false;
        // Keep the same alpha/layer budgets as surface intersection, but visibility needs no
        // transformed normal, world position, emission, or diffuse albedo for foliage/stone.
        for(uint skip=0;skip<96;++skip) {
            auto hit=trace.intersect(r,scene,0xff);
            if(hit.type==intersection_type::none) return transmission;
            const device RTPrimitive& p=*(const device RTPrimitive*)hit.primitive_data;
            const device RTInstance& instance=instances[hit.instance_id];
            uint flags=p.material.z;
            float2 bary=hit.triangle_barycentric_coord;
            float2 uv=p.uv01.xy*(1-bary.x-bary.y)+p.uv01.zw*bary.x+p.uv2Light.xy*bary.y;
            float4 tex=(flags&8u)!=0
                ? textures.entities[min(instance.info.x,511u)].sample(nearest,uv)
                : atlas.sample(nearest,uv,p.material.y);
            float alpha=tex.a*instance.tint.a;
            float coverage=(flags&8u)!=0?tex.a:alpha;
            float cutoff=(flags&8u)!=0?0.1:0.35;
            if(((flags&1u)!=0 && coverage<cutoff) || alpha<0.005) {
                r.min_distance=hit.distance+0.0002; continue;
            }
            if((flags&32u)!=0) transmission*=0.62;
            else if((flags&2u)!=0) transmission*=float3(0.7,0.86,0.92);
            else if((flags&4u)!=0) {
                float3 color=tex.rgb*rtTint(p.material.x)*instance.tint.rgb;
                color=mix(color,instance.overlay.rgb,instance.overlay.a);
                transmission*=mix(float3(1),rtLinear(clamp(color,float3(0),float3(1))),0.35);
            } else return float3(0);
            r.min_distance=hit.distance+0.003;
            if(r.min_distance>=r.max_distance) return transmission;
            accepted=true; break;
        }
        if(!accepted) return float3(0);
    }
    return float3(0);
}

// Only the no-volume compatibility path (and moving emitters) use surface proxies. Evaluate
// stable strongest local sources without a global random lottery or biased inverse-PDF clamp.
static float3 rtLocalProxyIrradiance(float3 position,float3 normal,device const RTLight* lights,uint count,
                                    instance_acceleration_structure scene,device const RTInstance* instances,
                                    constant RTTextures& textures,texture2d_array<float> atlas) {
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
        float3 visible=rtVisibility(position,normal,delta/d,d,scene,instances,textures,atlas);
        irradiance+=light.colorPower.rgb*visible*weights[slot];
    }
    return irradiance;
}

kernel void rt_pathtrace(instance_acceleration_structure scene [[buffer(0)]],
                         device const RTInstance* instances [[buffer(1)]],
                         constant RTUniforms& u [[buffer(2)]],
                         device const RTLight* lights [[buffer(3)]],
                         constant RTTextures& textures [[buffer(4)]],
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
    // Pixel centers preserve the authored pixel art; secondary paths supply stochastic samples.
    float2 uv=(float2(pixel)+0.5)/float2(u.counts.zw);
    float4 farPoint=u.inverseViewProjection*float4(uv.x*2-1,1-uv.y*2,1,1);
    float3 accumulated(0);
    float guideDepth=1; float4 guideNormal(0),guideMotion(0),guideDiffuse(1,1,1,1),guideSpecular(0);
    bool primarySolarValid=false;
    uint primarySolarInstance=0,primarySolarFlags=0;
    float3 primarySolarPosition(0),primarySolarNormal(0),primarySolarIrradiance(0);
    uint sampleCount=clamp(uint(u.quality.x),2u,4u);
    for(uint sample=0;sample<sampleCount;++sample) {
    uint seed=rtHash(pixel.x+pixel.y*u.counts.z)^rtHash(u.counts.x*4u+sample+0x9e3779b9u);
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
        RTSurface s=rtIntersect(r,scene,instances,textures,atlas,primaryPending?0x01:0xff);
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
        if(primaryPending) {
            primaryPending=false;
            float4 clip=u.viewProjection*float4(s.position,1);
            primaryDepth=clamp(clip.z/clip.w,0.0,1.0);
            primaryNormal=float4(s.normal,length(s.position));
            bool dielectric=(s.flags&6u)!=0,metal=(s.flags&16u)!=0;
            primaryDiffuse=float4(dielectric || metal?float3(0):s.albedo,dielectric?0.06:(metal?0.16:0.85));
            primarySpecular=float4(metal?s.albedo:float3(dielectric?0.02:0.04),0);
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
        radiance+=throughput*s.albedo*s.emission;
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
                primarySpecular=float4(float3(max(0.02,fresnel)),0);
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
                        ?rtVisibility(s.position,faceNormal,lightDirection,u.params.x,scene,instances,textures,atlas):float3(1);
                    float clouds=elyCloudSunTransmittanceAir(worldPosition,u.atmosphere);
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
                float3 vis=rtVisibility(s.position,faceNormal,delta/d,d,scene,instances,textures,atlas);
                radiance+=throughput*s.albedo*u.heldLight.rgb*vis*(fall*max(0.0,dot(faceNormal,delta/d))*2.5);
            }
        }
        // The immutable propagated volume is deterministic and already respects solid voxel
        // occlusion. It provides local diffuse illumination without competition from remote
        // lava. Static proxy lights are not submitted when the volume is available.
        float4 local=sampleRenderLocalLight(s.position,faceNormal,u.localLight,localLightTexture);
        float cachedBlock=clamp(s.block,0.0,1.0);
        float3 localIrradiance=local.rgb;
        if(u.localLight.params.x>0.5) {
            // Outside the bounded volume retain the original world light cache; interpolation
            // is only a coverage blend, never filtering bright voxels through a solid wall.
            float cachedRadiance=elyNonSunLightOutput*cachedBlock/(4-3*cachedBlock);
            localIrradiance=mix(float3(cachedRadiance),local.rgb,local.a);
        }
        radiance+=throughput*s.albedo*localIrradiance;
        if(u.counts.y>0) {
            radiance+=throughput*s.albedo*rtLocalProxyIrradiance(s.position,faceNormal,lights,u.counts.y,
                scene,instances,textures,atlas);
        }
        // Bounded neutral cache fill supports readable canopy shade without global exposure.
        float cached=rtCachedIllumination(s.sky,u.localLight.params.x>0.5?0.0:s.block,u);
        radiance+=throughput*s.albedo*cached;
        if(diffuseBounces++>=2) break;
        throughput*=s.albedo;
        if(max(throughput.x,max(throughput.y,throughput.z))<0.008) break;
        r.origin=s.position+faceNormal*0.004;
        r.direction=rtCosine(faceNormal,seed); r.min_distance=0.001;
    }
    radiance*=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    radiance=all(isfinite(radiance))?clamp(radiance,float3(0),float3(32)):float3(0);
    accumulated+=radiance;
    if(sample==0) { guideDepth=primaryDepth; guideNormal=primaryNormal; guideMotion=previous;
                   guideDiffuse=primaryDiffuse; guideSpecular=primarySpecular; }
    }
    // Reconstruct surface radiance against its matching material guides. Camera-space fog
    // and clouds are added afterward: neutral fog is not a green leaf's diffuse reflectance.
    output.write(float4(accumulated/float(sampleCount),1),pixel);
    depth.write(float4(guideDepth),pixel);
    normals.write(guideNormal,pixel);
    motion.write(guideMotion,pixel);
    diffuseAlbedo.write(guideDiffuse,pixel); specularAlbedo.write(guideSpecular,pixel);
}

kernel void rt_media(texture2d<float,access::read> reconstructed [[texture(0)]],
                     texture2d<float,access::read> depth [[texture(1)]],
                     texture2d<float,access::read> normalDistance [[texture(2)]],
                     texture2d<float,access::write> output [[texture(3)]],
                     constant RTUniforms& u [[buffer(0)]],uint2 pixel [[thread_position_in_grid]]) {
    if(pixel.x>=output.get_width() || pixel.y>=output.get_height()) return;
    float3 color=reconstructed.read(pixel).rgb;
    color=all(isfinite(color))?max(color,float3(0)):float3(0);
    float primaryDepth=depth.read(pixel).x;
    float primaryDistance=normalDistance.read(pixel).w;
    float fog=clamp((primaryDistance-u.fogParameters.x)/max(0.01,u.fogParameters.y-u.fogParameters.x),0.0,1.0);
    bool gameplayFog=u.fogParameters.y<64;
    bool surface=primaryDepth<0.999999, air=u.atmosphere.weather.w<0.5;
    float exposure=exp2((clamp(u.params.y,0.0,1.0)-0.5)*1.2);
    if(air) {
        float2 uv=(float2(pixel)+0.5)/float2(output.get_width(),output.get_height());
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
                     texture2d_array<float> atlas [[texture(0)]],
                     uint id [[thread_position_in_grid]]) {
    ray r; r.origin=float3(0); r.direction=normalize(directions[id].xyz);
    r.min_distance=0.001; r.max_distance=100;
    RTSurface s=rtIntersect(r,scene,instances,textures,atlas);
    results[id]=float4(s.hit?s.distance:-1,s.hit?s.albedo:float3(0));
}
"""
