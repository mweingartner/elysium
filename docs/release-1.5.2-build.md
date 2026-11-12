# Elysium 1.5.2 release record: frame rate

Version 1.5.2 answers the report "the frame rate is pretty bad". The cause was a simulation tick
of about 30 ms in a populated world, not the graphics: every loaded monster spawner walked every
entity each tick. `ARCHITECTURE.md` ("Frame rate: per-tick entity walks and main-thread frame
work") has the decision; `CHANGELOG.md` the player-visible summary. This file holds the
measurements, how to repeat them, and the release pins.

## Measurements

Machine and settings: MacBook Pro, Apple M5 Max (18 CPU cores, 40 GPU cores, 128 GB), built-in
120 Hz display, window with a 2880 x 1620 drawable. The player's own settings: Ray Traced
(surfaces 1920 x 1080, lighting 640 x 360), render distance 16, frame cap 120, clouds, shadows,
bloom and minimap on, Faithful 64x. Worlds: APFS clones of the player's two most recent saves in
a scratch profile, at the spot and heading where the player last stood, time of day and weather
frozen. Each figure is the median of three 30-second runs (flights: of the undisturbed runs), read
from the `frameTiming` snapshot. "1% low" is the frame rate of the slowest 1% of frames.

| Scene | 1.4.6 | 1.5.0 | 1.5.2 |
| --- | --- | --- | --- |
| Rich Resources "New World", standing (inside a house, dusk) | 47 fps, 1% low 21 | 46 fps, 1% low 21 | 120 fps, 1% low 92 |
| "JurassicWorld" (prehistoric, rain), standing | 77 fps, 1% low 30 | 64 fps, 1% low 27 | 119 fps, 1% low 67 |
| Rich Resources, flying 30 s at +25 blocks | not measured | 21 fps, 1% low 10 | 88 fps, 1% low 42 |
| JurassicWorld, flying 30 s at +25 blocks | not measured | 20 fps, 1% low 8 | 93 fps, 1% low 42 |
| Rich Resources, walking 30 s | not measured | not measured | 120 fps, 1% low 85 |
| JurassicWorld, walking 30 s | not measured | not measured | 117 fps, 1% low 64 |

Where a frame's time went, standing in the Rich Resources world (medians, milliseconds):

| | 1.5.0 | 1.5.2 |
| --- | --- | --- |
| Simulation on a frame that runs a tick | 30 | 2.8 |
| World drawing (`WorldRenderer.render`, main thread) | 3.6 | 2.8 |
| First-person view, HUD and screen | 0.55 | 0.10 |
| GPU, whole frame | 5.9 | 5.7 |

The 1.4.6 and 1.5.0 columns were taken while other sessions were building and testing on the same
machine (load average 5 to 7); they are so far from the 1.5.2 figures that this does not change
the reading. 1.4.6 and 1.5.0 agree in the Rich Resources world. In the Jurassic world the two
standing figures differ (77 and 64) with the same 21 ms tick in both; that difference was not
investigated further and is within what the other sessions' load did to single series that day.

Background load matters more for the 1.5.2 figures, which are near the display's 120 Hz: a run is
left out when the app lost focus, a screen opened, the frame stream had a gap, or another process
was using the GPU (an Ollama model was, at times). The two standing rows are three runs each of
the released code on a quiet machine (load average 3 to 4); their 1% lows ranged from 82 to 94 and
from 59 to 76. The Mac's screen locked during the final flight series, so the flying and walking
rows come from the build just before the changes the reviews asked for (two or three undisturbed
runs each); one undisturbed flight of the released code over the Rich Resources world gave 88 fps
with a 1% low of 42. Those later changes do not touch the frame path.

Flight is limited by the GPU. From altitude a frame needs 8.7 to 10.1 ms of GPU (median; path
3.4 to 3.8, full-resolution surfaces 2.4 to 3.3, cloud and fog composition 0.75 to 1.05, the TLAS
build 0.6, denoising 0.6) against the 8.3 ms a 120 Hz frame allows, the main thread 5.2 ms, and
5 to 7% of frames took longer than 16.7 ms.

The picture: captures of the same frozen scene on 1.5.0 and 1.5.2 (simulation paused straight
after loading, same time of day) differ by a mean of 0.06 to 0.26 of 255 per channel, and 0.002%
of pixels differ by more than 8 of 255. That is path-tracing noise.

## Repeating the measurement

```bash
bash scripts/package-debug-app.sh
python3 scripts/frame-rate-probe.py --list
python3 scripts/frame-rate-probe.py --world <id> --mode still --time 12703
python3 scripts/frame-rate-probe.py --world <id> --mode fly --time 12703
```

The probe's header comment says what disturbs a run. The numbers above came from a scratch copy of
the debug build under its own profile name with clones of the player's saves, as that comment
describes; the production profile was only read (`cp -c` of `elysium.db` while the game was not
running). F3 in the installed game shows the same ten-second figures on its `Frames:` line.

## Gates before the pipeline

- `swift build -c release`: complete, no warnings.
- `swift run -c release elysmoke`: 491 passed, 0 failed, no golden regenerated.
- `bash scripts/security-scan.sh`: passed. The boundary scan covers 308 production Swift files
  (four new: `WorldEntityIndex.swift`, `FrameTimingRecorder.swift`,
  `FrameTimingDebugSnapshot.swift`, `AtlasAnimationStager.swift`).
- Impacted suites after the review-driven changes: 93 simulation and 85 renderer and app tests,
  no failures. The test review ran 361 simulation and 99 renderer tests on the code before them.
- Two reviews by sessions that did not write the code. Security: no finding of medium severity
  or higher; it confirmed that the index readers keep the old results, order and random draws,
  that the cached lists cannot go stale, and that staged atlas buffers are immutable and checked
  against the live atlas. Test: no production defect of medium severity or higher; it added
  oracle tests for every "same answer as before" claim and reported two low faults in the new
  frame timing (a pause recorded as one frame; a slow-frame threshold with no room for vsync
  jitter) and the radius test written twice. All three are fixed in this release.

## Release pins

Values from the final warning-free `swift build -c release` in `~/dev/pebble` on November 11,
2026, using the gate's `strip -S -x` normalization.

| Surface | 1.5.1 pin | 1.5.2 pin |
| --- | --- | --- |
| `Saves.swift` | `ad5b30230fc26f5ce560d6f4f19b194af653b333c9a7d196f0f2c1ad1f4a3c8b` | `d57fe19db18af945117e6d930b536bbc99685d410af2a21824d530d19101631e` |
| `Saves.swift` compiler-AST inventory | `b21dcba96962f92c679a160658b4fdd12ec8d36ee3c5cab250e3d38a0bdf8980` | `0797dd697de373176015707004896e53323c8a5acf5003f84e1263a6bcf84d58` |
| storage-capability manifest | `d7460949f9196af124019393d8e659f6e1cf4d542f27e1f8ae86cd0627a30848` | `91e68257872e272379e73546d4135b2b06003f9b2d15789001e2bb80f424d5ef` |
| normalized `ElysiumCore.o` | `71f838aa12382af6e221157f1db1adc18602f939ba688233891c840dc6f0ce26` | `fb78dfd681a47a6dea407497a6fb2270202478eb2a3707cd20c3f083e0d16917` |
| normalized `Elysium` | `1204aac25fa10e5c4124da7deeb15a8fbd5b8cad57989ef515251785874b9845` | `93151337a9dd55527ba0aa86362f830c4b3d85059ad60a03d5f6c0135b19fab6` |
| normalized `elysmoke` | `57df2019305dfc044293edf0f88606e7895714c334e66a60dc414c92b2ff83e2` | `8802e8102430d8e432617909f0684f49b115549937e21960104af17125bb34b9` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift`, `Player.swift`, the
storage source, API manifest and object, and the text-input source and object are byte-identical
(the normalized `ElysiumStorage.o` and `ElysiumTextInput.o` hashes reproduce their 1.5.1 pins).

The Core object moves for the world's entity index (`WorldEntityIndex.swift`, new), the `didSet`
on `World.entities`, `getEntitiesNear` calling the shared radius predicate, the fourteen
players-near call sites (`AI.swift`, `Animals.swift`, `Bosses.swift`, `Monsters.swift`,
`Projectiles.swift`, `BlockEntities.swift`, `Raids.swift`, `Redstone.swift`), the monster despawn
loop, `pushEntities` and the spawner's wake test. No save format, wire shape or storage call
changes. The `Elysium` product also changes the draw loop and F3 (`main.swift`, `HudM.swift`,
`FrameTimingRecorder.swift`), the renderers (`WorldRenderer.swift`, `AtlasAnimationStager.swift`,
`RayTracedWorldRenderer.swift`, `RayTracingGPUProfiler.swift`, `RayTracingTypes.swift`) and the
HUD canvas (`UICanvas.swift`, `MapOverlayM.swift`); `elysmoke` only relinks Core. Atrium is still
at `19eb940`.
