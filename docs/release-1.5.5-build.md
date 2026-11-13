# Elysium 1.5.5 release record: flyers that fly, land and rest

Version 1.5.5 fixes the flight of the flying prehistoric creatures and the canopy trap that 1.5.4
left open. `docs/release-1.5.4-build.md` listed five defects of the flight controller that its
test review had pinned, and the placement rule that put flyers where they could not take off.
The owner's decision on all of it: "Yes, fix them". `CHANGELOG.md` has the player-visible summary
and `docs/PREHISTORIC_WORLDS.md` the controller rules; this file holds what was wrong, what was
measured, what the reviews found, and the release pins.

## What was wrong, and what changed

| Was | Now |
| --- | --- |
| A flyer was charged fall damage for its own descent: `Entity.move` counts every downward step, and the next ground contact through `move` charged all of it. On flat ground all six species "fell" by tick 271 and five died within 2,400 ticks. | `fallDamageMultiplier` is 0 for medium `.air`. |
| No landing completed on level ground: `tickFlightToward` turned an approach below `surface + 0.8` into a take-off, and the settle needs to be within 0.35 of the perch. | Being low is a reason to take off only outside a landing. |
| A flyer placed in a one-column gap of a canopy stood there for life (1.5.4 made it quiet). | A climb straight up is made with folded wings: `flyerLift` looks up to 16 cells above its first choice for the height where the wings fit and asks only that the body fits on the way. |
| The vertical-lift fallback took its height from `surfaceY` (the top of a roof) and was not checked against the roof, so a flyer under a roof hung in `takeoff` against the ceiling, searching on every tick. | The lift needs the body to fit all the way up; under a roof there is none and the flyer rests on the floor. |
| Spawn paths admitted a flyer by body clearance (two cells high for the small ones); the controller needs five. | `prehistoricHasClearance` asks `flyerCanLaunch` when a flyer is placed: a perch the controller could land on, and a lift from it into the open sky (heightmap). |
| At the edge of the loaded chunks a grounded flyer could play a landing and a take-off cue on one tick. | Gone with the landing fix. |
| `onGround` stayed true while a flyer hung over a dug-out floor; the rest gate let a flyer "rest" in the air, in water or in lava whenever its column had a perch somewhere above. | Resting needs dry solid ground under the feet. The no-route fallback reports what is under the feet. |

The geometry moved from private methods of `PrehistoricCreature` into
`Sources/ElysiumCore/Entity/PrehistoricFlightSpace.swift`, one owner that the controller and the
spawn paths both ask. `PrehistoricCreatures.swift` is 2 lines shorter (78 added, 80 removed).

Found by the reviews of this change and fixed in it:

- A flyer far above the world (a script or an edited save can put one at any finite height) made
  the new climb check walk every cell between it and the ceiling on every tick. The check is now
  clamped to the world's height.
- A flyer in water under a roof stood on the pool floor and drowned at tick 319, where the old
  lift had carried it up to the roof. With nowhere to go a flyer now rises out of water or lava
  until it is out or a block stops it.
- A flyer held in the air with nowhere to go hovered for good and searched on every tick. It now
  comes down to whatever is under it and rests there; over water, lava or a column with no floor
  it hovers as before.
- While still low, a take-off drew a new random heading twice per tick; under some canopy holes
  the zig-zag put the body over a leaf column and the flyer landed back on its perch for ever. A
  take-off under way keeps its target (`climbAway`).
- `flyerCanLaunch` refuses coordinates past 30,000,000 and heights outside the world; the AI
  companion's placement budget is charged an upper bound for the launch check.

## Measured in the owner's world

A read-only copy of the save (APFS clone inside a read transaction; the game was not running),
loaded without graphics through `GameCore`, 2,400 ticks after 100 warm-up ticks, player at
-7, 56, -78. The run was made on the code before the last two hardening lines of the review. 27 flyers are loaded; those farther than about 95 blocks from the player are not
ticked, which leaves four or five active ones.

| | 1.5.4 | 1.5.5 |
| --- | --- | --- |
| The two dimorphodons boxed in near the player (ids 12313 and 12310) | on the forest floor, at rest | climbed out of their gaps during the warm-up; 4 and 1 take-offs, 4 of 4 and 1 of 3 landings settled |
| Flyers hurt or dead | not measured | 0 of 27 |
| Landings settled, of those begun | not measured | 10 of 13 |
| Action changes on consecutive ticks | none | none |
| Flyer sounds in two minutes | not measured | 167 (glide 62, call 45, wingbeat 25, landing 13, take-off 12, settle 10) |

The 1.5.4 column was not re-run for this table; what is in it comes from the probes recorded in
`docs/release-1.5.4-build.md`. The defects themselves were shown on the 1.5.4 controller by the
five pinned tests, all of which failed there (25 assertion failures).

## Gates before the pipeline

- `swift build -c release` in `~/dev/pebble`: complete, no warnings.
- `bash scripts/verify-elysium-storage-release-surface.sh`: verified with the pins below.
- `swift run -c release elysmoke`: 491 passed, 0 failed, no golden regenerated.
- `bash scripts/security-scan.sh`: passed. The boundary scan covers 309 production Swift files
  (one new: `PrehistoricFlightSpace.swift`).
- Affected suites on the final code: 177 tests, no failure (`PrehistoricBoxedInFlyerTests` 55,
  `PrehistoricWorldsTests` 27, `PrehistoricEcosystemTests` 24, `AIAgentCreatureSpawningTests` 24,
  `CreatureRespawnTests` 20, `SpawnPlacementValidationTests` 19, `AIAgentAreaSpawnTerrainTests`
  8). The wider run before the last hardening lines, which adds the ecology, monster-spawning,
  persistence, audio and AI-agent suites: 204 tests, no failure.
- Reviews by agents that did not write the code.
  - Security: no critical or high finding. Three medium findings in the first version; two
    skeptics each tried to refute them. The unbounded climb check survived and is fixed. The
    drowning under a roof was confirmed by one skeptic and by a failing test of the test review
    and is fixed. The every-tick search of a flyer held in the air was refuted as a regression by
    both (the old controller did the same work under a roof) and is resolved anyway by letting
    such a flyer come down. The re-check of the fixes passed; its two one-line points (do not
    come down over a column with no floor; count a water-filled block as fluid below) are in.
  - Test: 23 tests added in `PrehistoricFlyerFlightSpaceTests.swift`, among them the folded climb
    against the real collision box for gaps of four sizes, landing cycles of 6,000 ticks for
    every species, per-tick flags, save and reload in a climb and in a landing, and placement as
    a property over 30 generated places. Nine single-line mutations of the new code are each
    caught by at least one test. Its four tests that pinned three bugs of the first version all
    pass on the final code.

## Release pins

Values from the final warning-free `swift build -c release` in `~/dev/pebble` on November 13,
2026, using the gate's `strip -S -x` normalization.

| Surface | 1.5.4 pin | 1.5.5 pin |
| --- | --- | --- |
| `Saves.swift` | `9a59bc5d4d2cc81313584cc5fee3b90ddcbf85edfeb9350f2d79a7ab837cbd06` | `cefdcfb4bed7a49cc4a3a567b0b3602fd289d91f11c9d51751f945cde73fc15b` |
| `Saves.swift` compiler-AST inventory | `88b87ff09ff99dcaa5f6fb30cce53b345f2aa5cb76d17036d103604fa0500bec` | `6d74972a93d5f47646107af289892ab7710e2b01bee68e2889c5f17c2f53449a` |
| storage-capability manifest | `799c5e9af82514bc011203fe4dedda11f10e6f2d5f703a2c7056e07364bf5f76` | `9bf3b61244c4e14b19594a8be944fb9075d0b0b1f9301bd7557718e8178e34bc` |
| normalized `ElysiumCore.o` | `1bd330f9c37b040f9e8aa0553f571e63a788a677aadf93b5174702a5be89e598` | `56aa3f5ed7b1e69bcf50e283afa814fbd9d758dc858e6d2ea98cf5309aa7051c` |
| normalized `Elysium` | `37941d2e6762c9e152a92139447edb7fb6757dc22512041716ba5bd07f90107c` | `156f7f2cda70caf1ad8a166530bdbf1dc9e95525c69a475d7e541e6a88a13dff` |
| normalized `elysmoke` | `46377142460162b910a02dba95ea3a9d5c21e06d34958a370c6ee79bbf0c9923` | `bf73d15773cd85d83e7cfa715eba13e861bc8486bec8a951750a16a422918dc7` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift`, `Player.swift`, the
storage source, API manifest and object, and the text-input source and object are byte-identical
(the normalized `ElysiumStorage.o` and `ElysiumTextInput.o` hashes reproduce their pins). The Core
object moves for the new flight-space file, the controller, the placement rule, the AI companion's
budget and the version literal; both products only relink Core. Atrium is still at `19eb940`.

## Left open

- Fewer flyers appear in forests: a generated or respawned flyer whose site is not a launch site
  is not placed, and nothing looks for a better site nearby.
- The open-sky test reads the heightmap, so a flyer can still be placed under a roof that lets
  light through (glass). It then rests there.
- A flyer with a body wider than the gap it stands in, or under a closed canopy or a roof, still
  cannot leave. It rests quietly and looks for a way out about once a second.
- A flyer hovering over water, lava or a column with no floor searches on every tick.
- Not confirmed against the game: the reviewer's question whether a flyer that comes down onto
  fire, a campfire, magma or a cactus takes contact damage it would not have taken hovering.
- `prehistoricHasClearance` refuses a water-filled plant where the flight rules accept one, and
  "solid ground under the feet" is still written in three places.
- A flyer reloaded in the middle of a climb takes a different path from the one it was on,
  because its flight target is not saved. That is older than this release.
- The creature animation on `feature/creature-animation` is not part of this release.
