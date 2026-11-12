# Elysium 1.5.3 release-pin receipt

Version 1.5.3 carries two changes that were finished in their own sessions while 1.5.1 and 1.5.2
were on their way. Both are stacked, unchanged, on the 1.5.2 release commit.

- **Containers the host's own game changes reach LAN guests** (`79adac1`). The crafting pool and
  a survival paste (its payment, its completion refund and its undo refund) write a container
  back through one call, `CraftingResourceOwner.markDirty`. That call now also raises
  `WorldHooks.onContainerItemsChanged`; `GameCore` forwards it on a host and never in a guest's
  mirror, and the transport records the position as a dirty block entity for the next delta. One
  payment can write more containers than a batch carries, so a delta now takes one batch's worth
  of dirty block entities and leaves the rest queued. `CHANGELOG.md` has the player-visible
  summary and `ARCHITECTURE.md` the mechanism (LAN transport section).
- **One owner for four rules** (`a262e87`, `943d9ad`, `89a86b1`, `7f972c7`; tests in `45a6762`):
  what the plant in a flower pot costs (`templateBlockEntityCharge`), whether a facing names a
  direction (`isDir`), where a bed's head lies from its foot (`FACE_DX` and `FACE_DZ`, with a
  bed's turn derived from the turn of the template's cells), and how a door opens (`toggleDoor`,
  for the player at the keyboard and for a LAN guest). No behaviour change.

Versions 1.5.2 and 1.5.3 went out together, through one pipeline run at the 1.5.3 commit. The
1.5.2 release commit (`041bc30`) is an ancestor of it and was never pushed or installed by
itself, so the installed app went from 1.5.1 to 1.5.3. `docs/release-1.5.2-build.md` remains the
record of the frame-rate work and of that commit's pins.

## Gates before the pipeline

- `swift build -c release` in `~/dev/pebble`: complete, no warnings.
- `bash scripts/verify-elysium-storage-release-surface.sh`: verified with the pins below.
- `swift run -c release elysmoke`: 491 passed, 0 failed, no golden regenerated.
- `bash scripts/security-scan.sh`: passed. The boundary scan covers 308 production Swift files
  (none new).
- Tests of the stacked code, before the version bump: 1,017 tests in the LAN, template, crafting,
  door, bed, redstone, interaction, block-entity and entity-index suites with no failure (on the
  frame-rate commit `2599985`), then 148 tests of the suites the two changes and the entity index
  touch on the final stack, no failure. The full suite runs once, in the pipeline.
- Both branches merged onto the frame-rate work and onto each other without a conflict.
- Reviews by sessions that did not write the code, each on its own branch. Container change:
  security review passed with notes only; the tester added a model test of the dirty queue, the
  70-chest cases and a transport test of containers that are gone when the delta is built.
  One-owner change: the test review compared each new owner with the 1.5.0 code it replaced
  (every facing value, all 65,536 bed cell values, 101,376 door neighbourhoods by hand and for a
  LAN guest) and found no difference in behaviour.

## Release pins

Values from the final warning-free `swift build -c release` in `~/dev/pebble` on November 12,
2026, using the gate's `strip -S -x` normalization.

| Surface | 1.5.2 pin | 1.5.3 pin |
| --- | --- | --- |
| `Saves.swift` | `d57fe19db18af945117e6d930b536bbc99685d410af2a21824d530d19101631e` | `15ba0f0f32c3352369627d4ea7082e024d514cd3789bb410dbb43c001561b328` |
| `Saves.swift` compiler-AST inventory | `0797dd697de373176015707004896e53323c8a5acf5003f84e1263a6bcf84d58` | `fadcfa6496a2375c4c49397481ab72cab6217d48f6c4aefcbab41c093b4d7580` |
| storage-capability manifest | `91e68257872e272379e73546d4135b2b06003f9b2d15789001e2bb80f424d5ef` | `5b9fd9b16ce9c7d1f40c7a07cdea00464068f8e57ee2de3f1e69a42eba63c8b6` |
| `GameCore.swift` | `26842de4ba112155857c4581680002d97e6634b33acce82681c314f91c5c9952` | `cc9d46a31f4b7f6deebdcbfb3ea0536ba34ec2c258fa2175e63660fc854d2b86` |
| normalized `ElysiumCore.o` | `fb78dfd681a47a6dea407497a6fb2270202478eb2a3707cd20c3f083e0d16917` | `10569fc33fc719c54c1584fd4c4795ee7b0f9127b32ca3c0083fca377d532a9b` |
| normalized `Elysium` | `93151337a9dd55527ba0aa86362f830c4b3d85059ad60a03d5f6c0135b19fab6` | `6b859a7a8381282f0d86263eba423e2e89b373cf783fe4e9500aa70bc76ffb4d` |
| normalized `elysmoke` | `8802e8102430d8e432617909f0684f49b115549937e21960104af17125bb34b9` | `5c11aac9ac5705b33172f7b082215edd895ea0cb0cc2896b4fdc8be2c4d2c4c2` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift` gains 7 lines and
loses none: the `onWorldContainerItemsChanged` callback, and in `hookWorld` the forwarding of
`WorldHooks.onContainerItemsChanged` to it unless the world is a LAN client's mirror. The
checked-player getter and compare-and-swap callers, their counts and their spans are unchanged.
`Player.swift`, the storage source, API manifest and object, and the text-input source and object
are byte-identical (the normalized `ElysiumStorage.o` and `ElysiumTextInput.o` hashes reproduce
their pins).

The Core object moves for the new world hook (`GameWorld.swift`) and its call from
`CraftingResourceOwner.markDirty` (`Crafting.swift`), the `GameCore` forwarding above, the bounded
drain of dirty block entities and `drainDirtyBlockEntitySnapshots` (`LANReplication.swift`),
`isDir` and the six facing guards that ask it (`Dirs.swift`, `BlockEntities.swift`,
`Redstone.swift`), `templateBlockEntityCharge` and its three callers (`TemplateMaterials.swift`,
`TemplateMaterialLedger.swift`), the bed compass and `toggleDoor` (`TwoCellBlocks.swift`) with its
two callers (`Interact.swift`, `LANReplication.swift`), and the version literal. No save format,
wire shape or storage call changes; the exact-version handshake still asks both sides of a LAN
game for the same version. The `Elysium` product also changes `LANTransport.swift` (the host
marks a container the game rewrote, a delta takes its dirty block entities from the session's
bounded drain, and the hook is cleared for a client and on reset); `elysmoke` only relinks Core.
Atrium is still at `19eb940`.

## Left open

- The host's own chest screen does not mark a chest dirty for guests; a guest sees such a change
  with the regular refresh of the eight nearest containers. Recorded with 1.5.1.
- A chest boat or a chest minecart is an entity without a block entity. LAN does not send what
  it holds, so the crafting pool taking from one tells guests nothing.
- A sixth one-owner commit (`55851cb` on `claude/stoic-jang-feb7ec-turned-survival-owner`) is not
  in this release. It changes which block a LAN host names when it refuses a turned paste, which
  is a decision for the owner.
