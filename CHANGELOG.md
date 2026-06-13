# Changelog

All notable changes to Pebble. Versions follow `MAJOR.MINOR.PATCH`; the
in-app version string comes from `PEBBLE_VERSION` (PebbleCore/Game/Saves.swift).

## 1.0.1 — 2026-06-13 — minor bug fixes

- **Fixed a build failure on newer toolchains.** A literal-arithmetic
  expression in `Mesher.swift` overran the Swift type-checker's budget on some
  toolchains (e.g. Swift 6.2.3 / Xcode 26.3, M-series), making `./pebble
  install` fail to compile. The expressions are now hoisted into typed locals;
  worldgen/mesh output is byte-identical.
- **Fixed entity facing.** Mobs and the third-person player were rendered
  rotated by `-yaw` instead of the Minecraft `180° - yaw` convention, so they
  faced (and appeared to walk) backward. Render-side only.

## 1.0.0 — 2026-06-11 — first public beta

**This is a beta.** The engine is pinned by 456 golden checks, but a game of
this scope certainly has bugs we haven't found yet. Reports and fix PRs are
incredibly welcome: https://github.com/thebriangao/pebble/issues (the README
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
  and sun/moon, loaded through Pebble's own zip reader. **Ultra graphics**:
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
