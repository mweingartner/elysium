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
structures, textures, and buffers through GPU completion. Geometry allocation has
a 1 GiB safety budget including retired in-flight geometry; scene limits also
bound triangles, instances, texture slots, and per-frame build work. Internal ray
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

## Empirical checks

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

The final 56 focused renderer tests pass and the production build is warning-free.
Final native captures confirm shallow/deep water, underwater transmission,
weather clouds, and continuous rain fog without a loaded-world silhouette.
See the [verification record](ray-traced-worlds/build.md) for capture identities,
release pipeline, installed identity, and publication status. No golden change
is intended.
