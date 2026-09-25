# Ray-traced worlds, clouds, and water

Status: the outdoor material-minification correction passes 156 selected tests.
Matched native captures confirm reduced outdoor speckle with preserved nearby detail
and approximately 80 FPS in the tested scene. The production release passed all nine
pipeline stages and is installed. Release identity and separate Git publication
results are tracked in the [verification record](ray-traced-worlds/build.md).

## Rendering contract

Video's existing Shaders button cycles Standard, Ultra, and Ray Traced. The
stored preference remains a string, so older preferences require no migration.
New profiles default to Ray Traced. Loading an existing settings document preserves
its choice, including legacy Standard/OFF documents that omit the shader key.
Unsupported devices skip Ray Traced in the cycle; a stored request on an
unsupported device falls back to Ultra without silently changing the preference.
Preparing or over-budget scenes also use a visible Ultra fallback, never a
partially built ray scene with holes.

The ray renderer traces primary world visibility, sun/moon and local-light
visibility, diffuse indirect illumination, reflective surfaces, and dielectric
water/glass paths. Section acceleration structures use the original packed mesh,
including repeated Faithful UVs, cutout alpha, biome tint, and emissive metadata.
They are selected by world distance, not by the camera frustum. Animated models
share one immutable presentation snapshot with the raster renderer. First-person
body geometry is hidden from primary rays but remains available to secondary
rays and shadows. The hand/item view model, HUD, selection outlines, and transient
particle/beam effects remain separate presentation passes.

Geometry builds are incremental. Every submission retains its acceleration
structures, textures, and buffers through GPU completion. The RT resource budget
is one quarter of Metal's recommended working set, capped at 32 GiB, and each
allocation also respects current device-resource usage with a reserved margin.
This replaces the original fixed 1 GiB cap: the 128 GiB M5 Max's reported
107.52 GiB recommendation permits a 26.88 GiB RT budget before headroom limits.
Missing device advice uses a conservative physical-memory fallback. Scene limits
also bound triangles, instances, texture slots, and per-frame build work. Internal ray
surface resolution preserves aspect ratio within 1440 × 900. Supported macOS 26+
devices trace expensive transport within 640 × 400, denoise that working image
1:1 with MetalFX, then independently trace primary visibility and material color
at the full surface resolution. Nearby resolvable authored texels retain nearest
sampling; subpixel atlas detail uses the filtered footprint described below.
Only ordinary diffuse incident lighting is
reconstructed across compatible depth, normal, and material-class guides; primary
emission is restored exactly afterward. Metal, glass, water, fading bodies, and
submerged transport are not multiplied by a diffuse albedo. Missing special-material
donors use the same bounded transport integrator at the native sample. Stable
pixel centers keep leaf coverage out of temporal jitter. Other devices retain
the original 1:1 albedo-guided temporal/spatial filter. Native denoising uses two
paths per lighting pixel; the compatible fallback uses
four. Primary water/glass Fresnel branches are both sampled each pixel. Geometry,
world, atlas, teleport, and lighting discontinuities invalidate affected history.
These are quality/performance tradeoffs, not claims of offline-render convergence.
Camera fog and finite primary cloud segments composite after reconstruction;
secondary-ray atmosphere and water absorption remain inside ray transport. This
keeps neutral atmospheric color separate from saturated material-albedo guides.
Primary air misses and fully distance-faded geometry resolve the same directional
atmosphere, while short-range blindness/lava/snow fog keeps its constant-color
visibility constraint. This avoids outlining loaded terrain against clouds.

Paths are bounded to seven surface events and two diffuse bounces. Placed lamps
use a stable, occlusion-respecting render-only voxel irradiance field instead of
competing in a scene-wide random light lottery. Held and moving emitters retain
visibility rays, and emissive faces remain visible to secondary paths. Metalness and dielectric properties are
semantic material presets, not imported PBR maps. Water has normal-map waves and
absorption/refraction, not a fluid simulation, geometric waves, or caustics.

Both paths use world-anchored volumetric clouds. Raster clouds march at half
resolution and upsample with full-resolution depth rejection at silhouettes.
Raster water reads completed color/depth snapshots, with a separate water-depth
prepass retaining submerged translucent objects. It uses the sky for reflection
and visible scene for refraction; only Ray Traced follows secondary rays into
off-screen loaded geometry. Reduce Motion freezes cloud drift and water normals.

No world simulation, save/LAN schema, registry order, or deterministic random
stream changes. No network service or downloaded asset is required.

## Memory capacity and recovery

The September 25 correction follows an observed production failure with 8,277
loaded sections at a 16-chunk render distance. That warning came from Elysium's
fixed cap, not an operating-system out-of-memory report. Once triggered, the old
failure state prevented eviction and retry until the world was reopened.

The new policy retains complete geometry and falls back to Ultra only while it
cannot safely admit the scene. It retries automatically; completed GPU work,
distance changes, and dead-entity cleanup can make space without reopening.
Section acceleration structures outside the selected radius are released while
their compact packed source is retained for rebuilding on return. Position,
index, and material upload buffers live only until their build completes, because
Metal copies their contents into the acceleration structure. In-flight geometry,
build scratch, scene tables, and top-level acceleration structures remain charged
until command completion; render targets, textures, and denoising resources are
covered by the separate device-wide headroom check.

`F3` distinguishes tracked RT usage, its current effective budget, temporary
resources, and all Metal-resource allocations. These are not total process RAM
or an assertion of currently free system memory. The debug renderer snapshot
exposes the corresponding byte counts.

Optional sparse GPU counters expose acceleration, path, denoise, native-surface,
and media timings. Each sample owns its counter buffer through completion and
uses Apple's [CPU/GPU timestamp calibration](https://developer.apple.com/documentation/metal/converting-gpu-timestamps-into-cpu-time).
The sample frame index distinguishes fresh measurements from stale background
diagnostics. Whole-command timing includes other passes and queue overlap; it
is not a substitute for measured foreground frame rate.

Policy and lifetime decisions use three Apple references:
[recommended working set](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize),
[current allocations](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize),
and [acceleration-structure buffer ownership](https://developer.apple.com/documentation/metal/mtlaccelerationstructurecommandencoder/build(accelerationstructure:descriptor:scratchbuffer:scratchbufferoffset:)).

## Empirical checks

### Outdoor material detail and grain

The September 25 grain report exposed a separate problem from stochastic lighting:
the native surface pass sampled nearest atlas mip zero and restored that color
after lighting denoising. The atlas had no coarser levels. When several authored
texels fit inside one output pixel, point sampling creates speckle and motion
shimmer. Increasing transport samples repeats the same primary material lookup,
and stronger lighting denoising does not change color restored afterward.

Primary atlas sampling now computes its pixel footprint from decoded triangle UV
gradients and analytic intersections of neighboring camera rays with the accepted
surface plane. This adds no scene intersections and respects arbitrary UV density
and oblique views. It blends into mip filtering with up to 4x anisotropy only for
subpixel texels; resolvable nearby pixels and true black channels remain exact.
Distance-only LOD misses UV-density differences, while an isotropic footprint can
overblur grazing ground. Existing ray counts, lighting resolution, MetalFX
reconstruction, and raster samplers remain unchanged.

Atlas mip zero retains the original bytes. Coarser levels average linear-light
color with alpha coverage, preventing transparent black from darkening their
material color. Area weighting handles odd texture dimensions. Changed animation
slices rebuild their own complete chains and use immutable, ordered GPU uploads;
the whole atlas is not regenerated each tick. Mips add approximately one third to
atlas texture storage. UV gradients add 32 bytes per primitive, bringing its GPU
payload to 96 bytes; existing stride-based allocation admission and Metal's actual
allocation sizes include that cost.

Three primary sources inform this choice: [PBRT's texture sampling and ray
differentials](https://www.pbr-book.org/4ed/Textures_and_Materials/Texture_Sampling_and_Antialiasing),
[JCGT's Improved Shader and Texture Level of Detail Using Ray
Cones](https://www.jcgt.org/published/0010/01/01/paper-lowres.pdf), and
[Apple's mipmap sampler guidance](https://developer.apple.com/documentation/metal/adding-mipmap-filtering-to-samplers).
The JCGT study demonstrates mip-zero aliasing in a ray-traced voxel game;
its measured speedups do not predict Elysium's performance.

The final reviewed scope passes 156 tests, including native GPU
first-frame subpixel-checkerboard averaging, subpixel camera movement, oblique
unequal UV density, three-output-pixel authored detail, black texels, exact cutout
coverage, and complete animated mip uploads. Native scene-matched still/movement and
frame-time measurements also passed and are recorded in the verification record.
Alpha acceptance and silhouettes, entity textures, and secondary-ray
material lookups remain nearest sampled. This correction does not establish
general geometry antialiasing or eliminate all transport noise; residual shimmer,
grazing-angle blur, or performance/memory regressions warrant further investigation.

### Underground and artificial light

Torches, lit furnaces, lanterns, lava, and other emitting block states now use
1.7× the original light output and twice the reach. Output was reduced 15% from
the initial doubled-brightness candidate. The effect applies to Standard,
Ultra, and Ray Traced modes without changing monster spawning, save data, or
the day/night clock. Soul lights remain blue; ordinary flames are warm.
Holding an emitting block uses the same 1.7× output and doubled reach.
Moonlight is brighter, but sunlight is not boosted.

The shared field spreads through loaded air and openings, while solid blocks
stop it. It covers a 128-block cube around the player, blends to the existing
lower-detail lighting near its boundary, and rebuilds off the main thread when
sources or walls change. Fully dark rooms retain a subtle visibility floor;
placing a real light still makes a substantial difference. This bounded voxel
lighting is an intentional real-time approximation, not offline global illumination.
Ray-traced tone-mapped color is now correctly encoded for the display. The missing
conversion previously crushed dim linear illumination toward black; correcting it
does not increase the sun's emitted light. HUD, hand rendering, and the legacy
raster color path remain outside that conversion.

Close-range cave tuning keeps the neutral visibility floor at 0.045 linear (down
from 0.18 after correcting display encoding). The propagated light and ambient
cache are applied only at the first diffuse surface, including one seen through
glass or a reflection; adding them again at each bounce made enclosed rooms too
bright. The normal furnace's stone casing does not emit: its animated flame still
glows and its level-13 source still illuminates the room. A 0.40 ray-traced local
diffuse response tempers the propagated field, its legacy-cache fallback, and
shadowed held/proxy lamps consistently. This is an art-directed response to the
game's irradiance scale, not a measured material model. Source power and visible
flame emission retain their 1.7× policy; lamp reach, sunlight, and player exposure
settings are unchanged.

### Forest lighting and update stability

Leaves use a separate render-only foliage classification, not the generic cutout
classification used by fences, plants, or entity skins. Solid leaf texels remain
visible to the camera but transmit 62% of direct light per crossed surface;
paired faces transmit about **38%**, with additional layers reducing transmission
multiplicatively. Texture holes still pass light freely, while stone, wood, and
solid roofs block it. This is a voxel-art readability choice, not a measured
biophysical model. A restrained leaf-only backlighting term makes leaf undersides
readable without making opaque building materials translucent.

A small, neutral ambient contribution uses the existing propagated skylight,
scaled down at night and absent in dimensions without an ordinary sky. It is
zero where the skylight cache is zero. Exposure is unchanged; a separate modest
dark-adaptation floor keeps an unlit cave navigable. The foliage shadow transmission is deterministic, so it
does not create random bright pixels from frame to frame.

Routine terrain updates use a larger but bounded acceleration-structure catch-up
budget once a complete ray scene has rendered. A retention margin avoids repeated
eviction/rebuilding on small range-boundary reversals. Distant or empty mesh churn
does not discard the current scene's denoising history; participating geometry
changes still invalidate it. These measures reduce avoidable renderer switching
and unconverged frames without presenting missing or stale geometry. Startup,
large teleports, and actual resource failures can still require Ultra while a
complete ray scene is prepared.

Shadow visibility decodes only the material data it needs. Identical primary
surface hits reuse their deterministic solar irradiance across the pixel's paths;
material color and stochastic secondary transport are never cached this way.
This reduces repeated canopy traversal without changing leaf transmission or
solid-block occlusion. Optional boundary caches are discarded first under memory
pressure and remain charged while an in-flight GPU submission still owns them.

The material distinction follows the separation of reflection and transmission
in [PBRT's material model](https://www.pbr-book.org/4ed/Textures_and_Materials/Material_Interface_and_Implementations).
The stability check is temporal, not just a still-image check; compare successive
frames and mode/history telemetry during movement as well as standing still.

The development machine is an Apple M5 Max with 40 GPU cores and 128 GB memory.
Metal reports supported ray tracing. An actual triangle-acceleration-structure
probe hit at distance 3 and missed the control ray; this proves API execution,
not game performance.

Real-GPU XCTest fixtures cover production shader compilation, primary depth,
alpha continuation, off-screen metallic reflections, dynamic pose changes,
first-person visibility masks, geometry edits, incremental preparation, resize,
world/resource-pack invalidation, water optics, clouds, and HDR tone mapping.
Unsupported GPU hosts explicitly skip hardware-dependent tests. They do not
turn CPU/source assertions into rendering evidence.

The performance regression fixtures also verify three-output-pixel authored
texels (including black channels), stationary alpha silhouettes across frames,
and a coplanar emissive/non-emissive boundary. A prior RGB-upscaling experiment
was rejected for blur; adding jitter improved sampling but introduced visible
treetop shimmer and still failed the fine-detail contrast test. Neither approach
is part of the shipping surface path. Sparse optional GPU counters distinguish
transport, reconstruction, native surfaces, media, and acceleration preparation;
their sampled frame index lets diagnostics reject stale/background measurements.

Initial isolated full-screen cloud measurements reached approximately 22 ms at
4K in rain. This prompted the half-resolution, depth-aware cloud path before
native-world acceptance. The isolated benchmark is not an in-game frame-rate
claim. The native check includes rain, movement, shallow/deep water,
underwater transitions, cutout foliage, creatures, local emissives, nighttime,
resize, and fallback. F3/debug telemetry reports whole-command-buffer GPU time,
not just the ray-tracing kernel.

Native inspection rejected the first one-sample waterfront render as too noisy.
Paired primary Fresnel paths, decorrelated samples, and material-aware denoising
replaced that candidate. A later exact-camera Ultra comparison exposed
false-color speckles in fogged foliage; moving primary atmospheric composition
after reconstruction addressed the inconsistent material guides. These are
observed image-driven revisions, not conclusions drawn from passing unit tests.

## Release closeout

The preceding memory/canopy correction passed 75 focused renderer tests and its
production build was warning-free. Native still-frame and movement sampling at
16-chunk distance stayed ray traced without fallback; daytime forest shade was
readable and night remained dark. See the verification record for sampling limits
and GPU cost. The original renderer's native captures also confirm shallow/deep water, underwater transmission,
weather clouds, and continuous rain fog without a loaded-world silhouette.
See the [verification record](ray-traced-worlds/build.md) for capture identities,
release pipeline, installed identity, and publication status. No golden change
is intended.
