# Changelog

All notable changes to Elysium. Versions follow `MAJOR.MINOR.PATCH`; the
in-app version string comes from `ELYSIUM_VERSION` (ElysiumCore/Game/Saves.swift).

## Unreleased

- Fixed mobs dropping multiple loot/XP sets and slimes/creepers/zombies
  misbehaving when damaged during the death animation. A dying entity can no
  longer be re-hurt or re-killed, which also stops the lava/fire re-kill loop
  and the XP-credit decay-to-zero bug.
- Fixed sculk catalysts not blooming on normal kills.
- Template undo now refuses cross-dimension/cross-world and unloaded-region
  restores instead of silently corrupting the wrong world or consuming the
  snapshot with no effect.
- LAN guest deaths honor `keepInventory` and no longer lose inventory to a
  publish race between the host's death-drop capture and the client's next
  inventory snapshot.
- Template clone reports a clear error for oversized/unloaded captures instead
  of a generic "corrupt" message or a silently truncated object.
- Added up/down quantity arrows beside the personal and crafting-table output
  slots. Survival crafting clamps the selected batch size to available
  resources, including nearby crafting-table containers, while creative clamps
  to the receiving inventory capacity, large output batches split across legal
  item stacks, and the compact stepper controls use matching pixel-drawn arrows.
- Quitting or Save-and-Quit while a large object-template placement is still
  filling in now finishes placing the object before saving, instead of
  persisting a permanently half-placed object with no undo.
- Fixed: LAN template placement and undo no longer stall the host. A
  permission-gated guest placing or undoing a template at the 524,288-block
  cap previously froze host rendering and replication for several seconds;
  both now run through the same tick-sliced job path as local play, with
  per-peer job state, deterministic per-tick budgets, accept-then-complete
  guest events, and busy rejection for a second in-flight request. A graceful
  host quit settles every guest's in-flight template job before saving, the
  same way a local in-flight placement is settled. Template capture (clone)
  remains synchronous. A token-bucket rate limit for repeated template
  intents remains a tracked follow-up; busy rejection is sufficient
  back-pressure for now.

## 1.1.0 — 2026-06-27 — gameplay systems update

- Added survival and creative-mode gameplay improvements developed after the
  first beta, including creative crafting, creative flight, copied-object
  placement workflows, minimap controls, command-line AI actions, and live
  3D fixture rendering for torches and lanterns.
- Added player-started LAN multiplayer session support: Multiplayer and Open to
  LAN screens, Bonjour browse/advertise for `_elysium-lan._tcp`, Direct Connect
  by host/port/join-code, `/lan ...` command-line controls, join-code
  handshakes, bounded protocol frames, peer status, and LAN chat.
- Added the first host-authoritative LAN replication layer: capped replication
  batches now carry player state, chunk-section snapshots, block deltas, entity
  snapshots, and inventory snapshots, with client mirrors and host-validated
  block intents covered by XCTest.
- Added the LAN remote-player gameplay orchestration layer: transient remote
  player entities, dimension/death-aware player state, reconnect-preserved peer
  records, gameplay events, permission gates for build/container/crafting/
  template/command/AI/creative/dimension/respawn flows, and host-authoritative
  object-template copy/place/undo intents covered by XCTest.
- Updated the security gates for the new local-network surface: Network.framework
  use is isolated to the LAN transport, app bundles must declare local-network
  privacy and Bonjour services, and low-level socket APIs remain rejected.
- Expanded the local XCTest harness around these behaviors while preserving
  the 456-check golden `elysmoke` contract.

## 1.0.0 — 2026-06-11 — first public beta

**This is a beta.** The engine is pinned by 456 golden checks, but a game of
this scope certainly has bugs we haven't found yet. Reports and fix PRs are
incredibly welcome: https://github.com/mweingartner/elysium/issues (the README
lists what to include).

The initial release. What ships:

- **A complete, native block-survival game for macOS** — ~45,000 lines of
  Swift + Metal, zero external dependencies, no game engine, no .xcodeproj.
- **Content**: 879 blocks, 1,188 items, 63 biomes, 100 entity types (55+ mobs
  with goal-based AI and A* pathfinding), 19 structure types (30+ variants), 39 enchantments,
  full brewing/enchanting/smithing/stonecutting/archaeology systems,
  advancements, raids, and villager trading.
- **Three dimensions** with working portals and full progression: overworld →
  nether (fortresses, bastions) → end (dragon fight, end cities, gateways),
  plus the Wither and the Warden.
- **Worldgen**: multi-noise climate sampling, spline terrain, 3D density caves,
  ravines, aquifers, vanilla-1.20 ore tables, snow lines, cave biomes
  including the deep dark.
- **Redstone**: wire networks, repeaters, comparators with container reading,
  pistons with quasi-connectivity, observers, hoppers, rails, sculk sensors.
- **Vanilla-exact player physics**, verified by independent derivations in the
  test suite (walk 4.317 b/s, sprint 5.612 b/s, jump apex 1.2522 blocks).
- **Synthesized audio**: every sound and all music generated in real time
  from oscillator recipes — zero audio files.
- **Faithful 32x textures built in** (self-restoring, credited, license
  included) — atlas art, `.mcmeta` animations, GUIs, fonts, entity skins,
  and sun/moon, loaded through Elysium's own zip reader. **Ultra graphics**:
  a built-in enhanced pipeline (SSAO, volumetric light, soft shadows, ACES).
- **Persistence**: single SQLite database (WAL) holding worlds, chunks
  (compact binary records), players, and advancements.
- **Quality**: 456 golden regression checks, all green; the engine is fully
  deterministic — identical seeds produce identical worlds on any machine,
  across releases; the build is warning-free; 200+ fps at full fancy settings
  on an Apple-silicon MacBook Air, ~2–4 s world loads.

### Known limitations

- Singleplayer only, for now — there is no networking code in 1.0.0.
- Elytra flight omits vanilla's dive-redirect term (look-pitch speed transfer);
  flight feel is otherwise vanilla-derived.
- Armor trims show in tooltips but not yet on worn armor.
- No resource-pack or shader-pack loading — the Faithful art and the ultra
  pipeline are built in; user-supplied packs are not a feature.
