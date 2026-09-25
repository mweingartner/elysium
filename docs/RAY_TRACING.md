# Ray-traced worlds, clouds, and water

Status: implementation and native-world visual acceptance complete. Production
release and publication results are tracked in the [verification record](ray-traced-worlds/build.md).

## Rendering contract

Video's existing Shaders button cycles Standard, Ultra, and Ray Traced. The
stored preference remains a string, so older preferences require no migration.
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
resolution preserves aspect ratio within 1440 × 900. Supported macOS 26+ devices
use same-resolution MetalFX temporal denoising with material, motion, normal,
roughness, and depth guides; other devices use an albedo-guided temporal/spatial
filter. Native denoising uses two paths per pixel; the compatible fallback uses
four. Primary water/glass Fresnel branches are both sampled each pixel. Geometry,
world, atlas, teleport, and lighting discontinuities invalidate affected history.
These are quality/performance tradeoffs, not claims of offline-render convergence.
Camera fog and finite primary cloud segments composite after reconstruction;
secondary-ray atmosphere and water absorption remain inside ray transport. This
keeps neutral atmospheric color separate from saturated material-albedo guides.
Primary air misses and fully distance-faded geometry resolve the same directional
atmosphere, while short-range blindness/lava/snow fog keeps its constant-color
visibility constraint. This avoids outlining loaded terrain against clouds.

Paths are bounded to seven surface events and two diffuse bounces. Emissive faces
use a bounded set of light proxies, with real visibility rays and a small existing
voxel-light contribution for stability. Metalness and dielectric properties are
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

Policy and lifetime decisions use three Apple references:
[recommended working set](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize),
[current allocations](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize),
and [acceleration-structure buffer ownership](https://developer.apple.com/documentation/metal/mtlaccelerationstructurecommandencoder/build(accelerationstructure:descriptor:scratchbuffer:scratchbufferoffset:)).

## Empirical checks

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
zero where the skylight cache is zero. Exposure is unchanged; enclosed caves are
not globally brightened. The foliage shadow transmission is deterministic, so it
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

The latest memory/canopy correction passes 75 focused renderer tests and its
production build is warning-free. Native still-frame and movement sampling at
16-chunk distance stays ray traced without fallback; daytime forest shade is
readable and night remains dark. See the verification record for sampling limits
and GPU cost. The original renderer's native captures also confirm shallow/deep water, underwater transmission,
weather clouds, and continuous rain fog without a loaded-world silhouette.
See the [verification record](ray-traced-worlds/build.md) for capture identities,
release pipeline, installed identity, and publication status. No golden change
is intended.
