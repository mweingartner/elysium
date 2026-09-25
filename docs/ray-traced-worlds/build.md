# Ray-traced worlds verification — September 24, 2026

The final focused renderer run passed **56 tests**, including real Metal
intersection, alpha continuation, off-screen reflection, entity/item poses,
geometry invalidation, resource limits, all three complete render pass graphs,
cloud occlusion, underwater/distant-glass raster cases, native MetalFX and
fallback reconstruction, and neutral fog across saturated material boundaries.
Log: `/tmp/elysium-render-focused-continuity.log`. No golden change is intended.

The ordinary production build completed without warnings in
`/tmp/elysium-ray-release-continuity.log`. The separately built optimized
inspection application is not the production deployment.

## Reviewed release-surface pin

Artifact hashes below are from disposable copies of
`.build/out/Products/Release`, normalized with `xcrun strip -S -x`, then
`shasum -a 256`. Original build artifacts are not modified.

Only the Elysium application product changes for renderer/UI code:

- Previous: `062c1a14c02349ad589525a620818bbd7159e3891fc1e0deb07e079bc8198093`
- Current: `4846b2192c71a101618b77e1bd50c9666fcb6440cee418efaf1ae064b80be970`

The following normalized artifacts remain byte-identical:

| Artifact | SHA-256 |
| --- | --- |
| ElysiumCore.o | `ea2d96cf2b3075443f8a58e22a1c6e8c8eaa7ab0b227234a016361400ea4a498` |
| ElysiumStorage.o | `43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8` |
| ElysiumTextInput.o | `0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3` |
| elysmoke | `3f5260664269be010db64237b3da923021fcfb0bcfa315126f2f16fb5f7cb1a9` |

All source/API/capability pins are unchanged. The sole Core edit updates the
existing shader preference's comment; simulation/storage semantics are untouched.

## Native acceptance

The final optimized inspection executable SHA-256 is
`ee05eca735d6e529c67dfb51d41d71506fa3c113301d43f74569260047ec0dca`.
Its isolated-debug session was `24f4a875-c9d8-4c8d-9a8c-e0ca019b913b`.
The following actual-renderer captures were inspected, not generated illustrations:

| Scene | Capture ID | PNG SHA-256 |
| --- | --- | --- |
| Rain cloud boundary: no loaded-terrain silhouette | `d192c0b4-7009-404e-8382-11b8f54c3591` | `bd77d5d99afca00935ea7bdcfab2d28ab441f93b412ee572d1c05efdb7e84ca2` |
| Rainforest fog: neutral atmosphere without false-color foliage speckles | `d2d97c1a-5a2b-40f9-9ebd-fa38ddc83f13` | `c4aa97207f4cd39af3d06bb772b95e5d6737ba05e648869af9faff9af089eef7` |
| Water: shallow/deep color, glass, creature reflection, local emission | `50f3ea27-630a-4168-98c0-16e8a3e4b5e0` | `87d63cec45ecd9a411ddc954b90242a64bd98e5cbff56f35a11c98f7f8837d62` |
| Underwater: transmitted sky window, internal reflection, submerged glass | `1aea0b8f-1ad2-47c0-9801-b1e0298f4b7a` | `5c51ad59274cac5cca16d90fc0f49c3573a9d0b96ea6282eccaa6fc34aa29259` |

Captures reside locally under `~/Library/Caches/Elysium Debug/Control/Artifacts-<session>/`.
Earlier native revisions also checked sunset/night, cave lava and local lighting,
moving creatures, the separate sharp HUD, and raster underwater fallback.
The final cloud-boundary scene contained 1,694,908 triangles in 2,059 instances,
using 514,914,192 geometry bytes; whole-command GPU time was 14.45 ms at
1440 × 810 internal tracing and 2880 × 1620 output. The underwater snapshot
reported 32.13 ms. These individual observations are not a steady frame-rate
guarantee; scene complexity and hardware affect performance.

Both owned disposable QA worlds were deleted, isolated-debug Shaders restored to
OFF, and the inspection application quit. Production saves/preferences were not
used for these fixtures.

## Closeout

The standard nine-stage release pipeline passed on September 25, 2026:

- Source security and binary/release-surface verification passed.
- Production build was warning-free.
- Full XCTest passed: **2,649 test cases, zero failures**. Counted individual
  completed cases across test bundles; the pipeline's summary prints only the
  last bundle's six tests.
- `elysmoke`: **491 passed, zero failed**, with no golden updates.
- Signed packaging and real AppKit text entry passed (two fields, no clipboard
  access, verified foreground driver and cleanup).
- `/Applications/Elysium.app` was installed and its identity and strict signature
  verification passed.

Installed executable SHA-256:
`5461ec5dd6167f85e0f83f00e5c9ea704a1dc4236ac2bb963361d3a033087096`.
Release log: `/tmp/elysium-ray-final-pipeline.log`.

This record is included in the implementation commit. Git publication is a
separate operation through the active pre-push hook; the delivery report records
the resulting commit and live GitHub `main` parity rather than inferring them
from the release pipeline.

## Adaptive ray-memory correction — September 25, 2026

The user's production LostWorld scene reached the old fixed 1 GiB cap on a
128 GiB Apple M5 Max. This was an application policy rejection, not evidence of
system RAM exhaustion. The revised budget is one-quarter of Metal's recommended
working set, capped at 32 GiB and constrained by current device allocations plus
a reserved margin. This machine reports a 107.52 GiB recommended working set,
yielding a **26.88 GiB** ray-resource policy limit.

The focused run passed **68 tests, zero failures**, including seven memory-policy
tests, four real-GPU recovery/lifetime/eviction tests, and a diagnostic-format
test. Log: `/tmp/elysium-ray-memory-focused.log`. An independent read-only review
found no actionable resource-lifetime, accounting, recovery, or debug-isolation
issues. No simulation or golden changes are intended.

The warning-free optimized inspection package has executable SHA-256
`6151eafa5539587259c2e829df34bce19e8d7bf21d6ddc9f274dfc3cdb59ec5a`.
In isolated-debug session `4c0fb4b7-1e63-4d5a-ac09-576d26fed829`, a disposable
Lost World v2 fixture used the user's seed `255591064`, 16-chunk render distance,
and camera `(34, 90, -120)`. This reproduces the terrain/extent, not the user's
saved buildings. The settled snapshot reported:

- 8,239 loaded renderer sections; 7,397 selected ray sections; no pending builds.
- Ray tracing active with MetalFX temporal denoising and no fallback warning.
- 6,463,812 triangles in 7,422 instances.
- 1,322,795,840 tracked ray-resource bytes, exceeding the old 1 GiB limit.
- 2,697,019,392 total allocated Metal bytes; 28,862,181,376-byte effective budget.
- 21.09 ms whole-command GPU time in one observation, not a performance guarantee.

Inspected actual renderer capture `93e2a926-39c4-4a74-9895-76ce7e939c41`
(2880 × 1620), PNG SHA-256
`046f7179f8c33a68ddc561f1e909fe2de8906ca71045bd7b086cd4684e3338ae`.
The owned fixture was deleted, debug preferences restored to distance 8/Shaders
OFF, and the inspection app quit. Production saves/preferences were unchanged.

Production release, installation, and publication for this correction are
recorded separately below when verified; the inspection package is not deployment.

## Final memory, canopy, and stability verification

The final focused run passed **75 tests, zero failures** with no compiler warnings:
`swift test --filter 'RayTracing|RayTracedWorldRendererTests|WorldRendererIntegrationTests|AtmosphereShaderTests|GraphicsModeTests|WaterMeshPartitionTests'`.
Log: `/tmp/elysium-ray-light-optimized-focused.log`. The additional coverage includes
visible-scene history changes, cold/warm geometry budgets, optional-cache eviction
under pressure, real-GPU foliage/solid visibility, continuous dawn/dusk ambient
fill, and exact cached/uncached primary-solar radiance equivalence with fewer queries.
The ordinary production build also passed warning-free in
`/tmp/elysium-ray-light-optimized-release.log`.

The final optimized inspection executable SHA-256 is
`aa614d251e06da3c61baa93798868c19be43707474a2042e8f121b7b66f00628`;
isolated session `a485c44b-2292-423c-80b4-6a8fa5fcbb2f`. The disposable Lost World v2
fixture used seed `255591064` at distance 16. Production saves/preferences were
not modified. Reduced motion and paused simulation isolated static comparisons;
movement used the real held-key route plus controlled simulation steps.

- Static: 100/100 sampled snapshots active/ready, history 24 throughout, no pending
  builds or fallback; 6,384,610 triangles. Ten world-only captures had maximum
  successive average ground/canopy brightness change of 0.0001137 on a 0–1 scale
  (under 0.012% full-scale), and maximum per-pixel mean absolute difference 0.00108.
- Movement: 160/160 captured steps active/ready, no fallback or pending builds,
  approximately 31.6 blocks out and back across chunk boundaries, up to 6,749,414
  triangles. Real mesh/light changes still reset history (39 observed drops);
  camera-only selection changes do not. Sampled captures cannot prove every frame
  in every world is flicker-free.
- Native day/night inspection at `(34, 75, -120)`, yaw 0.6, pitch 0 showed readable
  grass, trunks, and filtered leaf shade at noon; midnight remained dark rather
  than receiving a global exposure lift.
- Max-distance forest remains GPU-intensive: median whole-command times were
  79.6 ms static and 96.9 ms during captured movement. These include this workload
  and capture overhead; neither a frame-rate guarantee nor a broad benchmark.

Trace logs: `/tmp/elysium-ray-final-static.jsonl`,
`/tmp/elysium-ray-final-walk.jsonl`. Representative 2880 × 1620 captures:

| Scene | Capture ID | PNG SHA-256 |
|---|---|---|
| Forest traversal | `a1f98256-ea91-4d95-820e-fd13452cc4c2` | `f6fa8e6bee86b5c99813087fc22480afdd69d3caa3bced4163d6da33b94e9aa1` |
| Player-height noon | `871fb31c-11fb-4c99-8acf-731cbb9c574a` | `d01a43004d61686f041b3ced34f1ac9f24a79a71a83352ce9521ce229f970566` |
| Same view at midnight | `8759868e-49d7-438c-b12d-ccfeac1a9407` | `7a4858599f142f407c8ba78ae483cd4b5b03319bd13a8f531b341092665219dc` |

The owned fixture was deleted, the inspection app quit, and original debug
preferences restored (distance 8, Shaders OFF, reduced motion off).

### Reviewed release-surface renewal

Using the same disposable-copy `xcrun strip -S -x` normalization described above,
only the Elysium product pin moves from
`4846b2192c71a101618b77e1bd50c9666fcb6440cee418efaf1ae064b80be970` to
`2d74a0d1ae1e6bf6c7d5f0b7727c644020132d69092b8e0ec93f1c191c8a569c`.
ElysiumCore.o, ElysiumStorage.o, ElysiumTextInput.o, and elysmoke match the preceding
release hashes exactly. No source/API/storage pin or simulation golden changes.

Release pipeline/install and Git publication remain separate closeout checks.

### User-authorized impact-scoped release gates

The initial broad release run was stopped at the user's request to apply
blast-radius testing to release and push, not just implementation iteration. It
is not counted as a completed full-suite pass. Both gates now use the reviewed
impact selector documented in CONTRIBUTING and ARCHITECTURE. Discovery for this
change selects **438 of 2,668 XCTest cases**: renderer, app-shell/debug-protocol,
and release-contract coverage. The broader app slice is intentional because HUD,
app entry-point, and debug reporting files changed. Unrelated engine worldgen,
storage, and Lua execution tests are not selected; their code did not change.
The mandatory source-security baseline and all 491 smoke checks remain in place.
No gate or failing hook is bypassed.

### Production release result

`/tmp/elysium-ray-memory-light-scoped-pipeline.log` completed all nine stages:
source security, warning-free build, release-surface/binary verification,
**438 selected XCTest cases with zero failures**, all **8 selector tests**,
**491 smoke checks with zero failures**, signed packaging, real AppKit text
entry (two fields; no clipboard access; foreground and cleanup verified),
installation, and installed identity/strict code-signature verification.

Installed production application: `/Applications/Elysium.app`.
Executable SHA-256:
`7132b6e9c08037a5d8353b113bae15e87e9037f3f2374b987223a3833407b3a9`.
No golden updates. Git publication is verified separately after the unchanged
pre-push authority checks and new impact-selected test gate finish; the delivery
report records the resulting commit and live GitHub main parity.
