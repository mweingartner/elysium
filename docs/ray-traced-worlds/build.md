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
