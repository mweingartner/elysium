# Elysium 1.5.6 release record: creature animation

Version 1.5.6 animates the 24 land and 6 flying prehistoric species, as the owner asked on
2026-11-12: "Have them flap their wings and look around. Land creatures should have articulating
limbs and necks as well and be able to look around as part of their animation. Walking as well."
`CHANGELOG.md` has the player-visible summary, `docs/PREHISTORIC_WORLDS.md` the rigs and poses per
body plan, and `ARCHITECTURE.md` the decision record ("presentation state lives where it is used").

## What is in it

Three commits from `feature/creature-animation`, rebased onto 1.5.5:

- `24c847b` Animate the land and flying prehistoric creatures on jointed rigs. The models are
  chains of rigid parts (`ModelPart.parent`, `ModelPart.tip`); the app composes them on the CPU
  into the same 24 part matrices (`PrehistoricRig`, `PrehistoricPose`), so the shader, the uniform
  layout and the one-instance-per-part ray-tracing path are unchanged. The motion of each creature
  is kept by the renderer on its own forward-only clock (`PrehistoricMotionStore`).
- `6014b61` Draw a flyer that is off the ground as flying, whatever its action: one the
  controller holds in the air with nowhere to go beats its wings in place.
- `a46c7cf` Hold a flyer with no way on nose-up, legs under it: a body sinking in place does not
  point its nose down, its legs hang straight down, and "no way on" is an eased weight that holds
  its first-sight value until the creature's speed has been measured.

Nothing is saved, sent or read by the simulation, and no simulation random draw is made. A LAN
guest's mirrored creature animates from the replicated position, action and `onGround`, and is
drawn gliding between its 0.2 s snapshots instead of jumping. The five marine reptiles,
Deinosuchus and the ordinary mobs keep their animators. The Brachiosaurus's hind legs grow from 73%
to 93% of the hip height so that its hind feet reach the ground.

The animation was built and reviewed in its own session. That session stopped on a spend limit
with its last pose change uncommitted; both reviews of that change had reported. The change was
finished in the release session: its one remaining finding (a guest's mirror swung its legs half a
radian on every first sight while it waited for its first snapshot) is fixed, and the test that
had pinned it as an expected failure now passes.

## Gates before the pipeline

- `swift build -c release` in `~/dev/pebble`: complete, no warnings.
- `bash scripts/verify-elysium-storage-release-surface.sh`: verified with the pins below.
- `swift run -c release elysmoke`: 491 passed, 0 failed, no golden regenerated.
- `bash scripts/security-scan.sh`: passed. The boundary scan covers 312 production Swift files
  (three new: `PrehistoricRig.swift`, `PrehistoricMotion.swift`, `PrehistoricPose.swift`).
- On the rebased branch: the three animation classes, 67 tests (motion 23, pose 37, ray-traced
  dynamic scene 7), and the flyer and model classes, 60 tests (`PrehistoricBoxedInFlyerTests` 55,
  `PrehistoricModelTests` 5), no failure. The full suite runs in the pipeline
  (`scripts/test-impact.py` answers "full" for changes under `Sources/ElysiumCore/Render/`).
- Reviews by agents that did not write the code, in the animation session: a security and a test
  review of the whole change, of the hover change and of the pose change, each followed by a
  delta review of its fix. The security reviews found the renderer clock that wraps every 30
  minutes (it would have frozen every drawn creature) before the first commit; nothing since.

## Frame rate

Measured on November 13, 2026 with `scripts/frame-rate-probe.py` (still, 3 x 30 s per series) in
the debug profile's test world "Animation Perf" (`wmweinxo03qcl`): 48 creatures of every land and
flying species placed within about 50 blocks of the camera at 21.5, 83, 8.5 (yaw -1.5708, pitch
0.28), about 130 prehistoric creatures loaded in all.
Ray Traced, 2880 x 1620 drawable, 1920 x 1080 surfaces. The debug profile's save was restored from
the same copy before each series. Before is 1.5.5 (`f56809b`), after is the animation (`a46c7cf`);
the before build was run twice, before and after the animated one, to see the drift.

| Series | Average | 1% low | Main thread (median) | of which drawing the world | GPU (median) | GPU p10 |
| --- | --- | --- | --- | --- | --- | --- |
| 1.5.5, first | 113.3 fps | 54.6 | 4.11 ms | 3.78 ms | 7.64 ms | 6.59 ms |
| animated | 109.9 fps | 54.6 | 4.38 ms | 4.06 ms | 7.92 ms | 6.99 ms |
| 1.5.5, second | 110.4 fps | 56.0 | 4.07 ms | 3.78 ms | 8.28 ms | 7.07 ms |

The animation costs about 0.3 ms of main thread per frame here (posing the rigs: drawing the world
3.78 ms before, 4.06 ms after, the same in all three runs of each series). The GPU time of the two
1.5.5 series differs more (7.64 and 8.28 ms) than either differs from the animated one, so a GPU
cost is not visible in this measurement, and neither is a change in the frame rate. The scene has
13,000 more triangles with the jointed models (6.51 million against 6.50).

Captures of the animated build in the same world (taken through the debug app's `render.capture`,
not kept in the repository) show the sauropods standing on jointed legs with their feet on the
ground, the Brachiosaurus's hind feet reaching it, necks and tails posed, and the flyers with
their wings spread in the air. Several views were blocked by trees; the motion itself was not
judged from single frames.

## Release pins

Values from the final warning-free `swift build -c release` in `~/dev/pebble` on November 13,
2026, using the gate's `strip -S -x` normalization.

| Surface | 1.5.5 pin | 1.5.6 pin |
| --- | --- | --- |
| `Saves.swift` | `cefdcfb4bed7a49cc4a3a567b0b3602fd289d91f11c9d51751f945cde73fc15b` | `f66a13a1e46910752fc753ca5df4d0b3e8f46627194cfed3183915d9cc9f933e` |
| `Saves.swift` compiler-AST inventory | `6d74972a93d5f47646107af289892ab7710e2b01bee68e2889c5f17c2f53449a` | `0b5f15e3a75fcf359f93ab09e78c0ec1f7bb30661df2bb892aa9619220b29204` |
| storage-capability manifest | `9bf3b61244c4e14b19594a8be944fb9075d0b0b1f9301bd7557718e8178e34bc` | `e3345651a700ba4dd931e209394ccc9e120bfb6b1c15a91dc5c0c60daf83905c` |
| normalized `ElysiumCore.o` | `56aa3f5ed7b1e69bcf50e283afa814fbd9d758dc858e6d2ea98cf5309aa7051c` | `3d2be4b2e41a57721edc8a009b69f8e55e1894124468c22f8032e51dd430b6ac` |
| normalized `Elysium` | `156f7f2cda70caf1ad8a166530bdbf1dc9e95525c69a475d7e541e6a88a13dff` | `a0d08b018c6080726b77e09cf3776f644e0e0d851afc4afc1464a5d30849bcf7` |
| normalized `elysmoke` | `bf73d15773cd85d83e7cfa715eba13e861bc8486bec8a951750a16a422918dc7` | `7b81c6d921db4d1a4d222304999f69cfef17bf9d89d5d5644733fedc34cab27d` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift`, `Player.swift`, the
storage source, API manifest and object, and the text-input source and object are byte-identical.
The Core object moves for the jointed models (`EntityModels.swift`, `PrehistoricModels.swift` and
the three `PrehistoricLowPoly*` model files) and the version literal. The `Elysium` product also
adds `PrehistoricRig.swift`, `PrehistoricMotion.swift` and `PrehistoricPose.swift` and changes
`EntityRendererM.swift` and `WorldRenderer.swift`; `elysmoke` only relinks Core. Atrium is still at
`19eb940`.

## Left open

- The look on a running LAN guest was not checked in two apps; the guest path is covered by the
  motion tests (a mirror's first sight, its glide between snapshots, a restart on a backward
  clock).
- Captures in the running app cover sauropods, theropods and flyers in single frames; the
  motion (gait, wing beat, looking around) was judged in tests and offline renders, not by
  watching it run.
- The marine reptiles, Deinosuchus and the ordinary mobs are not part of this; whether they
  should be is the owner's open question.
- Found outside the change and not fixed: `wrapAngleD` (`WorldRenderer.swift`) loops in steps of
  2 pi, and a LAN snapshot passes any finite yaw, so a host sending a yaw of 1e18 would hang a
  guest's renderer. Read from the code, not run.
