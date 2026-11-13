# Elysium 1.5.4 release record: the engine noise

Version 1.5.4 answers the report "something in range of the player is making a terrible engine
like noise". The source was a flying dinosaur with nowhere to fly. `CHANGELOG.md` has the
player-visible summary and `docs/PREHISTORIC_WORLDS.md` the controller rule; this file holds how
it was found, what was measured, and the release pins.

## What made the noise

In the player's "JurassicWorld" (preset `elysium:prehistoric_jurassic_giants_v4`), dimorphodons
stood on the forest floor in gaps of the canopy. A take-off needs a 3x3 column of free cells, and
the leaves of the neighbouring trees close it two to four blocks above the ground, so
`makeFlightTarget` found no route and `findLandingTarget` no perch. The flight controller then
set the action to `takeoff`, fell back to `idle` in the same tick, and did so again on the next
tick. `setAction` plays a cue for every change of action, so each such flyer played its "takes
off" and "settles" cues twenty times a second each. Dinosaur voices carry 40 blocks whatever lies
between, so the player heard them in a cave under the forest.

The flyers were alive for about 60,000 ticks and stood at exact block centres on cells that pass
the spawn path's body clearance and fail the controller's landing clearance: they were placed
there, not flown there.

## How it was found, and the measurement

The save database was copied while the game ran (an APFS clone of the database and its
write-ahead log, taken inside a read transaction, so the live file was only read). A throwaway
test loaded the copy without graphics through `GameCore`, ran the simulation and recorded every
sound the game asked its host to play, with its place. It is not in the tree; the method is
enough to repeat it.

Player at -7.5, 54, -62.9, 600 ticks (30 seconds) after 100 warm-up ticks:

| | 1.5.3 | 1.5.4 |
| --- | --- | --- |
| Sounds the host was asked to play | 3,813 | 249 |
| Dimorphodon `takeoff` and `idle` cues within earshot (40 blocks) | 2,400 | 0 |
| Flyers repeating a cue tick after tick, of those loaded | 3 of 24 | 0 of 24 |
| Dimorphodon calls within earshot | (not played while stuck) | 7 |

The two flyers within earshot stood at 3.5, 68, -76.5 and -14.5, 74, -30.5, about 22 and 39
blocks from the player.

## The change

All in the flying-creature controller of `PrehistoricCreatures.swift` (26 lines added, 8
removed):

- `takeOff(ticks:)` asks `makeFlightTarget()` first and enters `takeoff` only when it returned a
  target. The three places that set `takeoff` unconditionally call it. No random draw moves.
- An idle flyer with action ticks left that stands on dry solid ground, out of lava, rests for
  the interval before it searches again, as a flyer on a validated perch already did. In water,
  in lava or in the air it searches on every tick as before.
- In the no-target fallback, a landing target equal to the flyer's own position starts no
  landing. It used to play "lands" and "settles" every rest interval without a movement.

Saved and replicated state keeps its closed set of actions and no field is added. LAN guests do
not run the controller.

## Gates before the pipeline

- `swift build -c release` in `~/dev/pebble`: complete, no warnings.
- `bash scripts/verify-elysium-storage-release-surface.sh`: verified with the pins below.
- `swift run -c release elysmoke`: 491 passed, 0 failed, no golden regenerated.
- `bash scripts/security-scan.sh`: passed. The boundary scan covers 308 production Swift files
  (none new).
- Affected suites: 80 tests, no failure (`PrehistoricBoxedInFlyerTests` 20,
  `PrehistoricWorldsTests` 27, `AIAgentCreatureSpawningTests` 24,
  `PrehistoricFeathersAndChickensTests` 6, `PrehistoricModelTests` 3). The seven tests written
  with the fix fail on the 1.5.3 controller (400 cues in 200 ticks for every flying species).
- Two reviews by agents that did not write the code. Security: pass; its one low finding (the new
  rest kept a perched flyer in lava that reached it) is fixed in the change and was re-checked.
  Test: 13 tests added and three strengthened; 19 of the 25 tests it ran fail on the old
  controller, and removing any one of the three conditions of the new rest (dry, out of lava,
  on solid ground) fails at least one test.

## Release pins

Values from the final warning-free `swift build -c release` in `~/dev/pebble` on November 12,
2026, using the gate's `strip -S -x` normalization.

| Surface | 1.5.3 pin | 1.5.4 pin |
| --- | --- | --- |
| `Saves.swift` | `15ba0f0f32c3352369627d4ea7082e024d514cd3789bb410dbb43c001561b328` | `9a59bc5d4d2cc81313584cc5fee3b90ddcbf85edfeb9350f2d79a7ab837cbd06` |
| `Saves.swift` compiler-AST inventory | `fadcfa6496a2375c4c49397481ab72cab6217d48f6c4aefcbab41c093b4d7580` | `88b87ff09ff99dcaa5f6fb30cce53b345f2aa5cb76d17036d103604fa0500bec` |
| storage-capability manifest | `5b9fd9b16ce9c7d1f40c7a07cdea00464068f8e57ee2de3f1e69a42eba63c8b6` | `799c5e9af82514bc011203fe4dedda11f10e6f2d5f703a2c7056e07364bf5f76` |
| normalized `ElysiumCore.o` | `10569fc33fc719c54c1584fd4c4795ee7b0f9127b32ca3c0083fca377d532a9b` | `1bd330f9c37b040f9e8aa0553f571e63a788a677aadf93b5174702a5be89e598` |
| normalized `Elysium` | `6b859a7a8381282f0d86263eba423e2e89b373cf783fe4e9500aa70bc76ffb4d` | `37941d2e6762c9e152a92139447edb7fb6757dc22512041716ba5bd07f90107c` |
| normalized `elysmoke` | `5c11aac9ac5705b33172f7b082215edd895ea0cb0cc2896b4fdc8be2c4d2c4c2` | `46377142460162b910a02dba95ea3a9d5c21e06d34958a370c6ee79bbf0c9923` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift`, `Player.swift`, the
storage source, API manifest and object, and the text-input source and object are byte-identical
(the normalized `ElysiumStorage.o` and `ElysiumTextInput.o` hashes reproduce their pins). The Core
object moves for the controller change above and the version literal; both products only relink
Core. Atrium is still at `19eb940`.

## Left open

- Flyers already boxed in stay where they are, quietly, until a way opens. The spawn path admits
  a flyer by body clearance alone (`prehistoricHasClearance`), the controller demands more
  (`hasFlyerLandingClearance`), so a flyer can still be placed where it cannot take off.
- The test review pinned five older defects of the flight controller with failing tests that are
  kept out of the tree until they are decided: a flyer is charged fall damage for its own
  descent; a landing never completes on level ground, because the approach turns into a take-off
  below `surface + 0.8`; under a closed roof the vertical-lift fallback of `makeFlightTarget`
  skips the route check and the flyer stays in `takeoff` against the ceiling; at the edge of the
  loaded chunks a grounded flyer can play a landing and a take-off cue on one tick for a few
  ticks; and `onGround` stays set over a floor that was dug away. None of them repeats a cue
  without end. They have not been checked by a second reviewer.
