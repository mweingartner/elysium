# Changelog

All notable changes to Elysium. Versions follow `MAJOR.MINOR.PATCH`; the
in-app version string comes from `ELYSIUM_VERSION` (ElysiumCore/Game/Saves.swift).

## Unreleased

- The RPG character system is simplified. Attributes (Strength/Dexterity/Intelligence/Endurance/Luck) are
  retired: health and fatigue now grow automatically with level at a fixed per-path rate (for example,
  Warden 26 Health +2/level, 10 Fatigue +1/level), shown on the Character tab as base plus per-level
  ("Health 38 (26 + 2 per level)"). Skills now have 5 ranks instead of 3, each with its own benefit and
  level requirement; skills in your chosen sub-class cost 1 skill point per rank, skills from the path's
  other two sub-classes cost 2; you still earn a skill point per level after level 1, plus a bonus skill
  point at levels 4, 7, 10, 13, 16, and 19. Character creation is redesigned as four single-click steps —
  Path → Sub-class → Starting Skills → Review — replacing the old attribute-spending carousel: choose a
  path, choose one of its three sub-classes, then pick exactly 3 starting skills at rank 1 from a 5-skill
  pool (your sub-class's 3 plus the signature skill of each other sub-class); the three signature skills
  are preselected by default, reproducing each path's classic starting skills and starter spells. Escape (or
  controller B) steps back through creation with your draft intact, closing only
  from the first step. Existing
  characters migrate automatically the first time they load: path, sub-class, level, and skill ranks are
  preserved, health/fatigue are recalculated from the new growth table, any points freed by the attribute
  retirement become available to spend, and you see a one-time notice explaining the change. Weather Eye
  also gains two new top ranks: rank 4 names the incoming weather instead of just counting down to it, and
  rank 5 lets it work in the Nether and the End.
- Survival crafting now pools ingredients from **every nearby container within 50
  blocks of you** — for both the inventory's 2×2 grid and a crafting table's 3×3
  grid (previously only the table pooled, and only from containers within 25
  blocks of the table). Chests, barrels, foundries (furnace family), hoppers,
  brewing stands, dispensers/droppers, shulker boxes, and chest boats and
  chest/hopper minecarts all contribute, and crafting withdraws from them
  automatically. Leftover ingredients returning to storage go only to general
  containers, never into a foundry/brewing slot. Pooling runs in single-player
  and for a LAN host; a LAN client crafts from its carried inventory only (this
  also fixes a latent item-duplication path for LAN guests). The container scan
  is bounded to the chunks within range, keeping it well within frame budget.
- The Create New World screen now has a **Character Classes** toggle (On by
  default). Turn it Off to play a classless world with the RPG progression
  system disabled — the choice is stored per world (the existing `rpgClasses`
  game rule) and survives save/reload, and it propagates to LAN guests. With it
  On, the character sheet is reachable from the Character button in the
  inventory as before.
- The custom world type "Moderate Hills - Resource Rich" is now simply
  **"Rich Resources"** in the Create New World screen. Only the display label
  changed; the on-disk/wire preset id is unchanged, so existing worlds are
  unaffected.
- Entering a world no longer force-opens the RPG character sheet as an overlay
  that could only be dismissed with Escape. You now land directly in the world;
  when classes are enabled and you have not yet chosen one, a quiet one-line
  chat hint points you to the Character button instead.
- Holding a movement (or any) key in-world no longer triggers a stream of macOS
  system beeps. Held-key OS repeats are now consumed in-world instead of
  falling through to AppKit as unhandled key events.
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
