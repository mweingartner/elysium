# Ray-traced worlds verification — September 24, 2026

## Ray scene streaming, budgets, and history — September 26, 2026

The user reported that the ray-casting budget was still being hit, that some areas
still flickered, and asked that the renderer follow the ray-tracing practice of top
games on Metal. Evidence used the optimized debug-control build on the 128 GB M5 Max
in the isolated profile's copy of the prehistoric New World (`wmuhh0wumk62d`), noon,
clear weather, 16-chunk distance.

- **Flight probe.** Three 40 s teleport-step flights at yaw 0, 1.57 and 3.14
  radians, 3 blocks per step, sampling every ~120 ms.
- **History probe.** 30 s standing still after a 20 s settle, sampling every 50 ms.

| Measure | Before (0458c45) | Streaming | Streaming + compaction |
|---|---:|---:|---:|
| Flight samples not ray traced | 138 / 767 (18.0%) | 0 / 768 | 0 / 774 |
| Fallback reason | triangle cap (8M) | none | none |
| Peak selected triangles | 9.83M | 9.30M | 9.67M |
| Flight FPS median / min | 67 / 31 | 71 / 54 | 74 / 57 |
| Whole-command GPU median / p95 | 9.56 / 14.99 ms | 9.11 / 13.68 ms | 8.72 / 13.54 ms |
| Resident RT geometry peak | 2.27 GiB | 2.21 GiB | 1.63 GiB |
| Standing-still history drops / 30 s | 124-190 | 0 | 0 |
| Standing-still history samples | 1-10 | 24 | 24 |

During the streaming flights at most 28 sections were deferred and 7 were
presented from their previous revision in any sample; no section was truncated.
Before the change, cumulative reset causes over the history probe were
"section edit" 1,132 and "local light" 69; afterward, only the one-time load causes
remain (world/atlas/dimension/clock/sun and the field's first appearance).

Decoder: a verbatim copy of the former string-matching decoder is kept in
`RayTracingDecoderEquivalenceTests` and must match the table decoder byte for byte
for every registered tile in every layer and for a real mesher section of every
block; a standalone benchmark measured 117 ns per triangle before and 29 ns after.
Compaction: the real-GPU fixture compacts an 8k-triangle section BLAS by more than
10% with an identical hit; the flight peak fell by 26%.

## Clean distance, native water and CPU frame time — September 25, 2026

The user reported that ray casting was not clean, distance detail was too grainy and
water was not realistic, and asked that frame rate stay high. Native evidence used
the optimized debug-control build (`scripts/package-debug-app.sh`) on the 128 GB
M5 Max, 2880 × 1620 drawable, 16-chunk distance, simulation paused after streaming,
with three fixed cameras in the isolated debug profile's copies of the user's worlds:
the user's New World shoreline (339.758, 75, 129.523; yaw 4.2504, pitch 0.3118), the
LostWorld valley and forest cameras recorded above. Both executables ran the same
fixed pose and `/time set` before sampling (baseline built unmodified from `2459587`
in a separate worktree); FPS/GPU values are medians of 15 one-second `state.snapshot`
samples after the scene was ready with no pending sections. Two alternating noon passes
agreed within 1 FPS.

| Scene (time) | Baseline FPS min / median | Final FPS min / median | Final whole-command GPU |
|---|---:|---:|---:|
| New World shoreline (noon) | 68 / 80 | 85-87 / 100 | 10.7-11.0 ms |
| LostWorld valley (noon) | 68-71 / 80 | 94-97 / 113-114 | 8.0-8.8 ms |
| LostWorld forest (noon) | 67-70 / 80 | 83-84 / 99-100 | 10.0-11.0 ms |
| New World shoreline (sunset, glint) | 67 / 79 | 76 / 87 | 12.3 ms |

Earlier development probes did not set the time (a missing command slash sent it
as chat), so their absolute FPS varied with sun position; only the fixed-time A/B
above is used for conclusions. Stage figures below are from those development probes.

Baseline surfaces were 1440 × 810 and lighting 640 × 360; final surfaces are
1920 × 1080 with the same lighting extent. `sample` of the baseline main thread
showed it about 100% busy (54% renderer encoding, of which 13% sorting sections;
30% HUD, almost all minimap string matching), so the frame was CPU-bound with GPU
headroom. After the CPU changes alone, at 1440 × 810, the shoreline measured 99-110
and the valley 115-120 FPS, and `nextDrawable` waits appeared on the main thread.

Stage evidence and decisions:

| Probe | Shoreline path / surface | Forest path | Decision |
|---|---|---|---|
| CPU changes only (1440) | 4.40 / 1.27 ms | 5.49 ms | kept |
| Opaque-tile BLAS split | 5.36 / 1.38 ms | 7.21 ms | rejected (slower) |
| Same split, both groups non-opaque | 4.45 / 1.35 ms | 6.42 ms | not needed |
| Native water + sky radiance (1440) | 4.27 / 1.68 ms | 5.17 ms | kept |
| 1920-wide surfaces (final) | 4.68 / 3.02 ms | 5.52 ms | kept |
| 2160-wide surfaces | 4.99 / 3.80 ms | 5.25 ms | rejected (81 FPS) |

Native captures located every symptom before it was changed. Debug-only views
(removed before release) showed the dark dashes across distant water were ice
blocks rendered as clear glass over deep water (98% of the dark pixels carried the
glass flag); a later white patch under the canopy was the sun glint passing the art-
directed 0.62 leaf transmission. Final captures show a sharp seabed and reflected
trees, a pale frozen sea, solid distant canopies without sky speckle, a correct low
sun glint and pink cloud reflections at sunset, and moonlit shallows at midnight.

| Capture (fixed time) | Baseline SHA-256 prefix | Final SHA-256 prefix |
|---|---|---|
| New World shoreline, noon | `74ac889da360caf8` | `28b33c1fd0bd5119` |
| LostWorld valley, noon | `edbef2eb33e1a6aa` | `c8d6c33f92df5720` |
| LostWorld forest, noon | `b9a1ea2dbafe8d28` | `97798d31f60aab6b` |
| New World shoreline, sunset | `6152dabb24c38668` | `c2aecd61d44075a2` |

Baseline debug executable `0e15411c387f6eb6811f9921dc13538e2dedf43c67a346a0125f0922eb229167`;
final debug executable `413e992d4296f00145c8d6a4907bb0977f4ef908dba5d42ebee393505802f9e6`.
Probe earlier rejected: the reload probe initially appeared to lose all geometry on
a second world load; the cause was the debug manual clock remaining paused across
`world.load`, not a product defect. Probes also require a visible window; macOS
stops drawing a fully covered MTKView.

### Production release result

Fresh-context reviews: the security review found no defect with a reachable trigger
(GPU indexing, NaN/Inf propagation, loop bounds, the `info.w` float reinterpretation,
sky-texture lifetime, cache growth, main-thread confinement). The test review added
13 real-Metal tests (band-limited waves and the seamless 1800 s wrap, reflection
horizon guard, luminance cap, R2 range, sky coordinate round trip, native top-water
radiance with a sharp seabed edge, selection-cache refresh) and ran the full suite:
2721 tests, 0 failures.

Release-surface object pins reproduce only in the original `~/dev/pebble` checkout;
identical source built elsewhere drifts. The product pin was renewed there from
`af471e5e86293490b3804826f42dd8df176d9be83ce0eb17b2f8018de1dd65c5` to `c0e54413f6c934b6493115610ac6315218e747b06c0f296149d5ac339fea370f`;
Core, Storage, TextInput and elysmoke are unchanged. `scripts/pipeline.sh` passed all
nine stages: source security, warning-free release build, release surface and binary,
2721 XCTest cases, 491 smoke checks with zero failures, signed packaging, AppKit text
entry (two fields, no clipboard access), installation and installed identity/codesign.

Installed production application: `/Applications/Elysium.app`, executable SHA-256
`2a746007822d8a7c0a28cbb249e0f33ea42f4c1cf7920a5cbcafc8cea3fff8d5`.

## Forest performance, blur, and foliage shimmer — September 25, 2026

The final renderer separates expensive lighting from full-resolution authored
surfaces. Hardware-oriented alpha callbacks preserve exact leaf holes without
restarting a closest-hit query for each transparent texel. MetalFX denoises
640 × 360 lighting for a 1440 × 810 surface image; primary material color, depth,
and emission are resolved independently at that full surface resolution. There
is no projection jitter. Fog/cloud composition remains after reconstruction.
The general caps are aspect-preserving 640 × 400 lighting and 1440 × 900 surfaces.
Unsupported native MetalFX retains the original full-resolution four-sample path.

Acceptance used an isolated copy of LostWorld on the 128 GB M5 Max, on AC power:
16-chunk distance, 2880 × 1620 drawable, Faithful atlas 128, about 7.13 million
triangles, 7,492 selected sections, 8,239 loaded sections, and two lighting samples.
The fixed camera was (7.6728, 79.2713, -106.9822), yaw 0.35263838,
pitch 0.60300367, clear daylight tick 1421. Builds and GPU tests were not running
during accepted performance measurements.

| Measurement | Original | Final |
| --- | --- | --- |
| Fixed forest FPS | 19–22, median 20 (20 seconds) | 63–79, median 76 (30 seconds) |
| Live simulation and camera sweep | Not sampled | 69–78, median 72 (20 seconds) |
| Median path pass | 46.22 ms | 7.34 ms |
| Median lighting denoise | 2.52 ms | 0.84 ms |
| Median full-resolution surface resolve | Not applicable | 1.42 ms |

Final stationary logs: `/tmp/elysium-rt-final640-clean-forest.jsonl`; motion:
`/tmp/elysium-rt-final640-motion.jsonl`. All samples were RT active/ready with
zero pending sections; GPU sample indices advanced by 2,280 and 1,380 frames,
respectively. The camera sweep advanced simulation by 380 ticks. The earlier
final-resolution run included synchronous PNG captures and briefly measured
57 FPS; it is retained as `/tmp/elysium-rt-final640-forest.jsonl`, but is not an
uninterrupted rendering benchmark. These results establish the tested scene on
this device, not a universal minimum frame rate or a long-duration soak result.

Rejected probes are preserved rather than presented as successful acceptance:
inline intersection queries regressed to 13 FPS; whole-image 960 × 540 and
800 × 450 reconstruction remained blurry; jittered reconstruction failed the
fine-detail contrast threshold (0.349 versus >0.45) and changed treetop holes
between native captures. A native-surface/720 × 405-lighting probe was sharp,
but its motion sample dipped to 55 FPS. The final lower lighting extent leaves
authored surface detail unchanged.

Native executable SHA-256:
`6253c69477d8a309e29fd70fb66ff1db19c11f6c2debd08a38b99a21892924ff`.
Final capture session `a8612b28-180d-42fb-b2b7-f2b02de2e820`:

- Fixed detail view: `1d691931-26da-4f65-aeaa-082b3a9514ca`, SHA-256
  `830638e70fdfa5362108873fcf4eba30f9066b764bf80e125ccb9e41071eb066`.
- Consecutive horizon/canopy views: `33123646-7e5e-4f62-a066-1613c3cffa16`
  and `a36aa9bf-e5b2-4140-8dfb-42da6edde5dd`; visible leaf openings remain
  aligned, without the prior jitter-driven crawling. Lighting remains temporally
  reconstructed; this does not claim every pixel is identical or eliminate
  ordinary subpixel aliasing during camera movement.

The final focused GPU suite passes **35 tests**, including actual authored
three-pixel texture/black-texel fidelity, stationary cutout depth identity,
emission-boundary isolation, water/glass front/back donor reuse, canopy visibility,
ordered transparency, cache contribution bounds, profiler calibration, and
completion-owned resource lifetime. Log: `/tmp/elysium-rt-final-focused-tests.log`.
Tests caught two donor fallback bugs before release: Fresnel guide updates must
retain dielectric material tags, and glass backface normals must agree between
lighting and native resolve. No simulation, save, registry, or LAN schema changed.
The original debug profile was restored byte-for-byte; the benchmark database
was retained separately, including its additional saved world, rather than deleted.

The warning-free production build completed in 174.95 seconds:
`/tmp/elysium-rt-final-release.log`. Disposable-copy `strip -S -x` normalization
renews only the Elysium product pin to
`d9cc426343e015f427bcceab1f84cbc2624c13fe2e8d7697a0f39e9e20b5634e`.
Core, Storage, TextInput, and elysmoke remain byte-identical to the previous
release; protected source/API/capability pins are unchanged. The normal production
build also passed in 169.72 seconds with the same normalized product fingerprint
(`/tmp/elysium-rt-final-production-build.log`). The first pipeline stopped on an
Apple documentation URL in a source comment; moving the citation into the rendering
documentation resolved that scanner finding without changing runtime behavior or
bypassing the gate.

The complete nine-stage pipeline passed: source/binary security, warning-free
build, **463 impact-scoped tests**, **491 golden checks**, signed packaging,
real AppKit keyboard/clipboard checks, installation to `/Applications/Elysium.app`,
and installed identity/codesign verification. Log:
`/tmp/elysium-rt-final-pipeline2.log`. Installed executable SHA-256:
`f1876dab5a2bbc6bd4818bba1714f8d8bf7bfec430a0d0b2ad683c7f2a84d3e0`.
Git publication is verified separately after the unchanged pre-push gate.

## Close-range underground correction — September 25, 2026

The user's actual furnished room remained too bright after the earlier long-range
probe. The prior captures below are historical evidence, not acceptance of this
close-range case. Source inspection found two artificial gains: the normal
furnace's entire facade self-emitted, and the propagated diffuse solution plus
visibility floor were added at each of three diffuse encounters. The correction
removes facade emission (retaining animated fire and level-13 source metadata),
uses the caches only at the first diffuse encounter, and lowers the enclosed
visibility floor from 0.18 to 0.045. A first native comparison still showed washed
out nearby walls despite corrected furnace stone. The final candidate also uses
a 0.40 RT diffuse response for propagated/cache illumination and held/proxy lamps.
Source power/range, visible flame emission, sunlight, gamma, and display encoding
are unchanged.

The final reviewed renderer/release-workflow scope passes **102 tests** in
`/tmp/elysium-cave-final-tests.log`, including actual GPU open-wall versus enclosed
white-room bounds and actual furnace meshes in all four orientations. The
enclosure test requires one cache contribution, rejecting the former three-copy
gain. Material tests retain torch/glowstone emission and furnace room-light data.

The first candidate's native captures are intentionally not final acceptance.
The renewed ray-traced comparison below supersedes the initial raster setup
captures and the bright unit-response candidate.

Final optimized native executable:
`3ed02aa1914c3645989b146443256eacab8ca00cf3fdc51ab5e6a2ef2097ee99`.
The 9×5×9 interior was inspected with the furnace about four blocks from the
camera, then with an adjacent torch. Normal furnace stone retained gray detail,
the mouth/flame remained bright, and the surrounding room was visibly dimmer
than the washed-out candidate. Unlit furnishings and wall texture remained
discernible. All four captures reported Ray Traced active/ready, 24 history
samples, and zero pending sections. Session: `8ec618d6-7248-4c59-bf21-6af6fb9e6900`.

- Unlit: `bb9ac5bd-425d-4ad1-99ce-043f940a4945`.
- Furnace: `bc1ee9ad-31da-4af3-a181-d38caaa15971`.
- Furnace and torch: `dc67ca15-867f-48f3-b82a-beedc9f369b7`.
- Wall facing away from the lights: `81699ecc-b1c5-420d-aabd-8cb8ea5c51f9`.

Paths and PNG hashes: `/tmp/elysium-close-room-final-native.jsonl`. The owned
fixture was removed after inspection; no production-world blocks were changed.
These captures demonstrate nearby-light appearance, not a long-duration flicker
or performance study. Existing canopy/GPU continuity checks remain in scope.

Final warning-free production build: 49.80 seconds,
`/tmp/elysium-cave-final-release.log`. Disposable-copy `strip -S -x`
normalization renews only Elysium to
`4f41853e8f2644502368709ce898d129f2ee947cb5cd654c2204f3cfdd2a0d94`;
Core, Storage, TextInput, and elysmoke remain byte-identical to the preceding
release. Protected source/API/capability pins are unchanged.

The nine-stage production pipeline passed with **102 scoped tests** and **491
golden checks**, warning-free build, source/binary security, packaged AppKit
keyboard/clipboard checks, installation, and installed identity/signature checks.
Log: `/tmp/elysium-cave-final-pipeline.log`. Installed executable SHA-256:
`418f978de948913318387b087b324f1db454dc5d4592fba890271aff1a95f410`.
Git publication is checked separately after the unchanged pre-push gate.

## Underground emissive correction — September 25, 2026

### User-tuned release candidate

The final policy is 1.7× original non-sun light output (15% below the initial
2× candidate), retaining doubled finite reach. New profiles request Ray Traced;
existing persisted Standard/OFF, Ultra, Ray Traced, and custom-pack choices remain
unchanged. Unsupported hardware retains the existing Ultra fallback.

The tuned production build completed warning-free in 187.67 seconds:
`/tmp/elysium-underground-tuned-release.log`. Disposable-copy normalization
(`xcrun strip -S -x`) produced Elysium
`10b192924179b948fd5117308506ccf65eca7574912ce318cb4c0829c32e4f7b`,
ElysiumCore.o `8c7f8cfeca0f904a51dabb2e6c341c784e5a26f67be3ed725d7894aa3c37417c`,
and elysmoke `85f96e0560205a6d1fce44f252162bd0b21eede6cad8f16fd4532c38b7e91f7a`.
Storage/TextInput objects and protected source/API/capability pins are unchanged.
The impact-selector harness passes ten tests; release validation includes the
reviewed renderer, mesher, settings-persistence and release-workflow closure.

The complete nine-stage production pipeline passed, including **186 impact-scoped
tests**, all **491 golden checks**, source/binary security, warning-free build,
signed packaging, real AppKit text entry, installation, and installed signature/
identity verification. Log: `/tmp/elysium-underground-pipeline.log`.
Installed `/Applications/Elysium.app/Contents/MacOS/Elysium` SHA-256:
`7960b8092beed00a5486568ea71ea628eb5a04a713d7ceee92cf737d6e92c09f`.

The tuned optimized native inspection build
`ee573704b9c8f3fad5cefb8d5bd69de2749347c1881ffa32504a842821c2697b`
renewed actual underground and outdoor checks in session
`80f6fe14-9bdd-406e-ac74-ca94985c12e6`. Capture IDs:

- Dim, readable unlit room: `fe7b26f6-fd8f-47da-b2f9-51c42ecc0a43`.
- Warm furnace illumination at 18 blocks: `a6ca2efd-b72d-4685-890e-d293b542b1e6`.
- Solid divider blocks light: `3d477bbd-956b-4634-aa8f-a7325619cacd`.
- Doorway admits light: `744306b9-181b-4e33-9978-ae4f50f60688`.
- Outdoor daylight retains visible texture: `17b05cbe-d447-4b29-a35e-a787f72cd81f`.
- Ultra torch/doorway comparison: `da78345b-3922-443e-a808-abd6b86d4a3a`.

The first startup probe was discarded because the manually paused fixture had
not yet adopted its initial chunks. After normal streaming, all five scene
captures were renewed; they are the IDs above, not the incomplete startup images.
Capture metadata/hashes are recorded in
`/tmp/elysium-underground-tuned-native-verified.jsonl` (Ultra PNG SHA-256
`a615cbd29c24ff7aaf714537ae6b13450b96eec1e2cbf0da453c14b2eadfd1fa`).
The renewed fixed-camera sequence remained ray-traced/ready for 100/100 snapshots,
with no history drops or pending sections. History settled from 9 to 24 samples;
the largest consecutive floor-patch mean-luminance change was 0.000680 on a 0–1
scale. Median GPU time was 12.17 ms while release compilation ran concurrently;
this is a small-room stability observation, not a general performance guarantee.
The owned fixture was deleted and debug preferences restored after inspection.
Git publication is verified separately after the unmodified pre-push hook.

### Initial implementation

The current change adds colored, render-only doubled-range lamp propagation,
stable ray lighting, increased held/dynamic emission, and an underground visibility
floor. Native inspection also found missing linear-to-display conversion after
ray tone mapping. That conversion is now explicit on the BGRA8Unorm drawable;
legacy raster, HUD, and first-person display paths are unchanged.

The warning-free release build is recorded in `/tmp/elysium-underground-release-build.log`.
The final focused integration run passed 46 tests in
`/tmp/elysium-underground-integration.log`; the nine new source/field tests also
passed, including actual GPU sampling, opaque-wall rejection, doubled reach,
source removal, world clearing, and asynchronous recentering. The reviewed scope
adds mesher fixtures and shared renderer consumers without selecting unrelated
simulation/world-generation suites. The nine selector tests passed. Release and
push gates will re-execute the complete selected closure and all 491 goldens.

### Initial 2× candidate native evidence

The captures and binary renewal below precede the user's requested 15% brightness
reduction and new-profile Ray Traced default. They establish the lighting approach;
the tuned 1.7× output candidate's renewed proof is recorded above.

Final optimized inspection executable SHA-256:
`fb78c2708e8194c957de2e7532c36996c35b7f035114e1b9d505bba493621cda`.
Isolated session: `9dd6c304-9050-4661-b9fe-62526f246383`. A disposable 32×8×14
stone room was observed from 18 blocks away from its source, beyond the old
furnace/torch reach. These are real renderer captures, not generated art:

| Scene | Capture ID | PNG SHA-256 |
|---|---|---|
| Unlit room, readable neutral floor | `999779e8-4bc9-4e97-941c-afb5dee6f227` | `38acbb3d866f0725b577305468299a3fcedeb8a0ca0ef557b6ec526b5e06e8ad` |
| Lit furnace, warm surrounding floor/walls | `9f75d67b-cff7-445e-a0ec-63922225564a` | `a5aaeb8e68238c82fef51f99e926ef064d21929eab96a02f40f6e1a4a22424b6` |
| Solid divider blocks lamp contribution | `8c7fd3df-7f11-44fc-bee8-746e16ae5bab` | `bda8ae2172224100a3880ac76309cd262c139b065d38494ae345e41fd5195a56` |
| Doorway admits warm light | `dc0e24c6-035e-426c-8778-6da7d6f99f42` | `33001f20b89cdcd75148a9c9ba77b99c8071369ace465d032ca0a395d7fa3d55` |
| Ultra raster torch/doorway comparison | `97d8f1ec-faf5-4eb6-a188-0c10e80cab4a` | `ac94f7738160d7582815becf1638dec1ebbdc1a1427bdc5795b4e2ed81ac1d4c` |

The lit-furnace state was set directly in the isolated fixture; this proves
emissive rendering, not a new furnace ignition/smelting mechanic. Existing
smelting behavior was not changed.

The fixed-camera torch sequence sampled 100 renderer states and ten images:
all remained ray-traced/ready, history stayed at 24, no pending sections, median
GPU time 7.43 ms (maximum 10.56 ms). The central floor patch's largest consecutive
mean-luminance change was 0.0000181 on a 0–1 scale. A separate 20-frame traverse
crossed the 16-block cache boundary in 0.05-block steps with no mode fallback or
history reset; median GPU time 8.36 ms. These simple-room measurements are not
performance guarantees for complex worlds. Logs:
`/tmp/elysium-underground-static.jsonl` and `/tmp/elysium-underground-recenter.jsonl`.

### Reviewed binary renewal

Disposable copies normalized with `xcrun strip -S -x` produced:

| Artifact | New SHA-256 |
|---|---|
| Elysium | `34a2c0f85a1bbbb3025a2b9bba767699ac65c07059f278243957db4670683874` |
| ElysiumCore.o | `77a2a57db4903647c865f23661f77ab0fa26ac20e45a174e1a05e5d0a6b294bb` |
| elysmoke | `195dc960552f8035aa03892c30925413093c79eea80fe27f67c05a1aa7016302` |

Core's render-only mesh sidecar changes its object and linked products, but not
the packed mesh or simulation goldens. ElysiumStorage.o and ElysiumTextInput.o
remain byte-identical to the preceding release, as do all protected source,
API, and capability-manifest pins. Installation and GitHub parity are separate
closeout results, reported after their gates finish.

---

## Original renderer release

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


## Outdoor material grain correction — September 25, 2026

The user rejected the running valley scene as grainy. The same native camera
revealed high-frequency grass/dirt aliasing: accepted materials always sampled
nearest mip zero, and the surface resolve restored that aliasing after lighting
reconstruction. Primary rays and the two transport samples were unchanged.
Three primary research sources and the selected footprint/mipmap design are
recorded in [ARCHITECTURE](../../ARCHITECTURE.md#outdoor-material-minification--september-25-2026).

The optimized inspection build uses the same LostWorld save copied into the
isolated debug profile, camera (44.653763, 87.65, -89.115717), yaw -0.504176,
pitch 0.455396, clear day tick 3007, distance 16, 2880 × 1620 drawable,
1440 × 810 surfaces and 640 × 360 two-sample lighting. Approximately 6.72 million
triangles participate in both runs. World simulation is paused for comparison;
small creature/mesh differences accumulated during initial streaming, so these
are scene-matched samples rather than bit-identical simulation frames.

| Warmed 20-second sample | Before | Filtered |
|---|---:|---:|
| FPS minimum / median / maximum | 71 / 78 / 81 | 79 / 80 / 82 |
| Median whole-command GPU duration | 7.50 ms | 7.66 ms |
| Median native surface pass | 0.80 ms | 0.87 ms |
| Ray active, ready, no pending sections | Every sample | Every sample |

A 20-second camera sweep retained 80–81 FPS (median 80), with fresh GPU
samples and ray tracing active/ready throughout. Simulation stayed paused
during this sweep to isolate camera motion. A further 20-second sample with
simulation and animation running measured 80–83 FPS (median 80);
ray tracing remained active/ready in every sample.

The small FPS difference is timing variation, not a claimed speedup. Image quality
improves substantially at similar throughput; hardware counters show the small
additional surface cost. The matched captures visibly remove distant grass/dirt
speckle while keeping block contours, water transport and visible foliage holes.
A nearby hut/forest capture confirms sharp wood, stone, dirt and leaf texture.
Thin alpha silhouettes and secondary-reflection aliasing remain outside this fix.

| Inspection artifact | Identity |
|---|---|
| Before executable SHA-256 | `6253c69477d8a309e29fd70fb66ff1db19c11f6c2debd08a38b99a21892924ff` |
| Filtered executable SHA-256 | `eb9cb0cb6e89671ccde5d4a419718a0fba75c752cc7d835aeddb8bb051402c49` |
| Before capture | `e7f7c12f-ecff-481a-ab87-ebd7b740a334`, SHA-256 `4da1374504ec8e23247de250864bd812e42598c0c4f35a2cf319217223a53a40` |
| Filtered capture | `0ba1b504-13ff-4ebe-b5d8-701e9e58ae31`, SHA-256 `77d77b345f97a6bc5f61f6a236410ccc037c2a6922b38a6123515f581f2dc0db` |
| Nearby detail capture | `619cb393-033a-41f4-a064-978f8104cff1`, SHA-256 `2c5dbbd492ce0bf1c4329401a3d62623ed6eab1f919ea24a392a9ad28f65617a` |

`/tmp/elysium-grain-release.log` is warning-free. The reviewed impact map selects
156 tests; `/tmp/elysium-grain-impact-tests-final.log` passes all 156, including
native subpixel averaging, camera motion, oblique UV density, sharp nearby/black
texels with a mip-capable atlas, exact alpha continuation, shader ray counts,
linear-light mip generation and GPU-ordered animated updates. The first broad
run exposed an obsolete test instrumentation string after the call gained
footprint arguments; its anchor was repaired without changing the ray-count
expectations, then the entire selected scope passed.

Only the stripped Elysium product release pin changes to
`af471e5e86293490b3804826f42dd8df176d9be83ce0eb17b2f8018de1dd65c5`.
ElysiumCore.o, ElysiumStorage.o, ElysiumTextInput.o, elysmoke and all source/API
pins remain identical. The release-surface verifier passes.

### Production release result

`/tmp/elysium-grain-pipeline.log` completed all nine stages: source security,
warning-free release build, release-surface/binary verification, **156 selected
XCTest cases with zero failures**, all **10 selector tests**, **491 smoke checks
with zero failures**, signed packaging, real AppKit text entry (two fields;
no clipboard access; foreground and cleanup verified), installation, and
installed identity/strict code-signature verification. No goldens changed.

Installed production application: `/Applications/Elysium.app`.
Executable SHA-256:
`ebc1a774d01e29f04abf0b2f1466022ed964ffd75ae2bea4f389ca22a6029396`.
Git publication is verified separately after the active pre-push gates; the
delivery report records the resulting commit and live GitHub main parity.
