# Pebble — Architecture

This is the technical tour. The one-paragraph version: **PebbleCore** is a headless, deterministic game engine (no AppKit imports anywhere); **Pebble** is a thin-ish macOS shell that owns the window, the Metal renderer, the synthesized audio engine, and the UI stack; **pebsmoke** is the regression harness that pins the engine to golden files. The app talks to the engine exclusively through the `GameHost` protocol, and the engine never draws, plays, or reads input directly.

```
┌─────────────────────────── Pebble.app ───────────────────────────┐
│  main.swift        NSWindow + MTKView, NSEvent → DOM key codes,  │
│                    pointer capture, frame loop, HostBridge       │
│  WorldRenderer     Metal pipelines, mesh arena, atlas, shadows,  │
│                    sky/celestials/clouds, bloom, ultra, capture  │
│  UICanvas/UIManager/Screens/Menus/HUD   canvas-2D-style batcher, │
│                    screen stack, 16 gameplay screens, menus      │
│  Audio             AVAudioSourceNode synth, recipes, reverb      │
│  ResourcePacks (built-in Faithful loading)                       │
│  OllamaAgent       loopback-only /api/generate and /api/tags      │
└────────────────────────────┬─────────────────────────────────────┘
                   GameHost protocol (openScreen, playSound,
                   addParticles, mesh upload, chunk requests…)
┌────────────────────────────┴─────────────────────────────────────┐
│                         PebbleCore                               │
│  GameCore (20Hz tick orchestrator)  ·  GameWorld  ·  LightEngine │
│  Gen (terrain/biomes/features/structures)  ·  Entity (AI)        │
│  Items (recipes/enchants/loot)  ·  Systems (redstone/interact/…) │
│  Render (mesher + texture atlas — data only, no Metal)           │
│  Saves (SQLite)  ·  Core (fdlibm, RNG, noise)                    │
└──────────────────────────────────────────────────────────────────┘
```

## The determinism layer (Core/)

Pebble's engine is fully deterministic — identical seeds produce identical worlds on any machine, across releases — and everything downstream depends on this layer:

- **`DetMath.swift`** — fdlibm 5.3c `sin`/`cos`/`atan`/`atan2` implemented with only IEEE-754 primitive operations, so trig results never depend on the platform math library. Also `detRound` (well-defined `.5` boundary behavior) and hypot helpers.
- **`RandomX.swift`** — sfc32-style seeded RNG plus `hashString`, `mix32` (murmur3 finalizer), and `hash2`/`hash3` position hashes. All arithmetic uses explicit 32-bit wrapping, so hashes are identical everywhere. Position hashing is what makes features/structures reproducible per-coordinate rather than per-generation-order.
- **`Noise.swift`** — simplex 2D/3D with a seeded permutation shuffle, FBM stacks, spline interpolation.

Rules that keep determinism intact are listed in CONTRIBUTING — the short version is: sim code never touches `Double.random`, `Date`, or unordered collection iteration.

## World & simulation

- **`Chunk`** — 16×384×16 cells, one `UInt16` per cell packed as `(blockId << 4) | meta`. Separate sky/block light arrays, a heightmap, and biome data at 4×4×4 resolution. Dimensions: overworld y −64…320, nether 128, end 256.
- **`GameWorld`** — chunk map, block get/set with light + remesh propagation, scheduled ticks (binary heap with stable tie-break ordering), random ticks, block entities (insertion-ordered ticking), entity lists, raycasting. Behavior is attached via handler registries (`blockTickHandlers`, `randomTickHandlers`, `neighborHandlers`, `beTickHandlers`, `onPlacedHandlers`) that the Systems modules fill at startup.
- **`LightEngine`** — incremental flood-fill for sky and block light with cross-chunk seam stitching. Never propagates into missing chunks (frontier rule), heals dropped chunks once a second.
- **`GameCore`** — the orchestrator. Fixed 20 Hz tick (50 ms), with chunk generation on a concurrent queue (capped in-flight), meshing on its own queue, and saves on a serial queue. Chunks are generated off-main and only published to the world on the main thread (`adoptChunk`), which is the threading contract that keeps the engine lock-free. Autosave every 60 s; unloads batch their writes into one SQLite transaction per second.

## Worldgen (Gen/)

Climate sampling (six FBM samplers seeded from the world seed) feeds spline lookups for base height, erosion flattening, and peak/valley amplitude; a 3D density lattice (sampled at fixed f32 precision for reproducibility, interpolated per-cell) carves cheese/spaghetti/noodle caves; worm carvers and ravines run after; aquifers place water/lava bodies; surface rules paint grass/dirt/sand/deepslate; ores follow the vanilla 1.20 attempt tables. Structures use a region grid (`spacing`/`separation`/`salt`) with a `check` predicate and a `plan` that emits **pieces** (AABB + build closure). Every chunk within `maxRadiusChunks` of an origin re-runs the plan and builds only the pieces that intersect it — which is why **piece RNG must be a pure function of (structure, piece), never of the target chunk**, and why every random draw happens *before* any chunk-relative `get()` check.

## Entities (Entity/)

`Entity` (AABB physics with auto-step, fluid state, fire, riding) → `LivingEntity` (health, effects with insertion-order semantics, equipment, per-entity seeded RNG) → `Mob` (goal selectors with stable priority sort, A* grid navigation up to 600 nodes) → 100 concrete types. The player is vanilla-1.20-exact: input ×0.98, ground accel `speed × 0.21600002 / slip³`, friction `slip × 0.91`, gravity `(vy − 0.08) × 0.98`, jump 0.42 + sprint boost, water/lava/elytra regimes, sneak edge-guard. Those constants are *derived* in the test suite, not just asserted.

## Rendering

Engine side (`Render/`): the **mesher** consumes a padded 18×18×18 snapshot and emits opaque/cutout/translucent vertex buffers — greedy quad merging for full cubes, per-vertex AO, smooth light, biome tint, and an animation channel (water/lava/portal/fire/sway). Vertex format is 28 bytes / 7 words. The **atlas substrate** generates all 757+ baseline tiles in code with integer-only color math (pinned byte-identical by `atlas-goldens.json`); the built-in Faithful art overlays it. Tiles that vanilla renders as block entities (beds, chests, the bell, the decorated pot) have no flat `block/` texture in the Java format — the loader composites them from the art's `entity/` unwraps, so every visible surface comes from the Faithful set (the only substrate tiles left at runtime are the three airs, a particle speck, and the end-portal effect, which vanilla also renders as a shader rather than a texture).

App side (`WorldRenderer`): runtime-compiled MSL (no `.metal` files — SPM doesn't build them), a **mesh arena** of 32 MB shared `MTLBuffer` pages with a first-fit free list and 3-frame deferred frees so all section draws bind one buffer at different offsets. Pass order: shadow (PCF/Poisson, snapped texel grid) → sky gradient → stars → celestials (Faithful sun/moon drawn additively) → clouds → opaque → cutout (back-culled) → translucent → entities (pose animator, Faithful skins) → particles (instanced, triple-buffered) → ultra (half-res SSAO + shadow-marched volumetrics) → bloom → composite (ACES) → UI. The UI is a single draw call: `UICanvas` mimics Canvas2D (fillRect, gradients, transforms, text via a built-in 5×7 font or the Faithful font sheets) into one vertex stream with a texture-segmented batch.

Chat and command-line rendering stays in the app shell (`ScreensM.swift` + `UICanvas`), but its wrapping and item-completion rules live in `PebbleCore/Game/CommandLineSupport.swift` so XCTest can prove those behaviors against the real registered item list.

Crafting recipe planning stays in `PebbleCore/Systems/Crafting.swift`. The survival inventory uses only the player's carried inventory plus the local 2x2 grid. Crafting-table screens carry their block coordinates from `Interact.swift` through `ScreenData`, then build recipe plans from the player's inventory, the current 3x3 grid, and loaded block/entity containers within a 25-block radius. Selecting a recipe withdraws concrete ingredients into the grid through the same recipe planner, consumes player inventory first, marks mutated block-entity containers dirty through `World.setBlockEntity`, and still lets the normal output-slot path consume the staged grid. Recipe-popup typeahead is split the same way: normalized search matching and the query/highlight/scroll state machine are core-tested in `Crafting.swift`, while `ScreensM.swift` owns drawing, mouse hit testing, and routing keyboard events into that state.

CPU/GPU synchronization leans on `CAMetalLayer`'s default 3-drawable back-pressure: the mesh arena defers frees 3 frames, and UI/particle instance buffers are 3-deep rings. Atlas animation updates are staged into buffers and blitted at frame start so in-flight frames never see a half-written texture.

## Object templates

`Sources/PebbleCore/Systems/Templates.swift` implements command-driven construction cloning. A clone starts from the targeted block, flood-fills connected non-terrain blocks in deterministic neighbor order, excludes air/liquids/terrain substrate, stores block cells relative to the discovered bounds, and deep-copies block entities through `Codable` after sanitizing item stacks. Placement anchors the original targeted block to the new cursor face, using the live raycast or the last cached cursor hit from before chat opened, preflights every destination cell, then writes blocks through `World.setBlock` and reattaches cloned block entities. The `/listTemplates` browser reads the same SQLite-backed template store, summarizes each validated template in core, and draws a bounded rotatable voxel preview in `ScreensM.swift` through `UICanvas` filled quads. The feature deliberately has fixed caps on block count, template span, encoded JSON size, and preview block count so a bad target or edited database cannot create unbounded work.

## Audio

No samples. `Audio.swift` is a synthesizer: each sound effect is a recipe that spawns voices (oscillator or filtered noise) with envelopes, pitch sweeps, and vibrato, mixed in an `AVAudioSourceNode` render callback at 48 kHz. Effects: RBJ biquad filters, positional stereo panning, underwater lowpass, and a cave reverb built from two coprime-length feedback delay lines. Music (ambient + jukebox discs) is generated on the fly from scale/tempo configs. The render thread owns the voice list; the main thread communicates through a locked inbox.

## Local AI agent

The in-game `/ai` command is split across the app and core boundary on purpose. `Sources/Pebble/OllamaAgent.swift` is the only network surface: it talks to the standard local Ollama port (`http://localhost:11434`) for model discovery and one-shot structured generation. `Sources/PebbleCore/Systems/AIAgent.swift` contains the deterministic, testable side: snapshot construction, natural-name resolution against the registered item/block registries, JSON action parsing, and whitelisted execution. Model output is treated as untrusted data; it can only choose `say`, `give_item`, or `place_block` at the current cursor, and the final world mutation runs through the normal block placement path on the main thread.

## Persistence

One SQLite database (WAL, FULLMUTEX, serial save queue): `worlds(id, json, lastPlayed)`, `chunks(world, dim, cx, cz, data)`, `player(world, json)`, `advancements(world, json)`, and `templates(name, json, created)`. Chunk blobs are a small binary container (`VCK1`: flags, u16 block array, biome array, JSON tail for block entities + entities). Object templates are versioned bounded JSON records with relative block coordinates and relative block-entity coordinates. Unmodified chunks save as entity-only stubs and regenerate from seed; once a chunk has block data on disk, every rewrite keeps it (tracked via `savedFullKeys`). Failed batches log and re-mark chunks dirty for retry. Corrupt blobs and corrupt templates are rejected or clamped before hot paths can index unchecked registries.

## The test harness (pebsmoke)

456 checks across 16 suites, run with `pebble test`:

random/noise/math → block & item registries (counts + id spot checks) → biomes (all 63 defs + 2,000 biome selections) → terrain (full pipeline hashes on 2 seeds) → features (whole-chunk generation across all three dimensions) → atlas (pixel-identical tiles) → mesher (vertex/index hashes) → world sim (light, fluids over hundreds of ticks, RNG lockstep) → items (recipes/enchants/potions/loot rolls) → fdlibm (911 probes) → entities (55-mob zoo × 200 ticks, combat, scripted player physics, trades, pathfinding, spawning) → systems (crafting probes, BE timelines, a full redstone contraption, explosion crater, interactions, portals) → and a final suite that *independently derives* vanilla physics constants instead of trusting goldens.

Golden discipline: reference goldens are frozen (they have no generator); behavior-change goldens (`PEBBLE_REGOLD=1`) are regenerated only deliberately, with each diff justified. Content added after the baseline was frozen (e.g. two appended items) is excluded from reference hashes via fixed prefix ranges, never by regenerating reference baselines.
