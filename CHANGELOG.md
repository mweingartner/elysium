# Changelog

All notable changes to Elysium. Versions follow `MAJOR.MINOR.PATCH`; the
in-app version string comes from `ELYSIUM_VERSION` (ElysiumCore/Game/Saves.swift).

## Unreleased

- Rebuilt the native **Lua script editor as a language-aware authoring environment**. A shared
  `ScriptLanguageSchema` supplies the editor's engine bindings, handle members, attribute/event
  metadata, real callable parameters/returns/overloads, snippets, documentation, and tooling-only
  LuaCATS text; the runtime remains authoritative. The editor adds UTF-16-correct lexical/semantic
  ranges, receiver-aware completion after `.` or `:`, live applicability filtering for the current
  host target, handler/local-only `ev`, shallow local/table inference, advisory diagnostics and
  signature help, accessible completion documentation, line indent/outdent, native-undo external
  insertions, an event picker, a visible Unsaved marker, guarded navigation, and a synchronized line
  gutter. Check now recognizes a legal attached-script yield without scheduling work or contacting
  AI; immediate Run highlights engine `wait`/`ai.await` calls (while respecting local shadows) and
  directs the author to Save for yieldable execution. A searchable **World Objects** browser inserts only live canonical refs from the current
  target, cursor, and bounded nearby snapshot; stale pinned rows remain visible but noninsertable. Saves
  refuse stale world sessions, require snapshot-bound confirmation for external or rename collisions and hidden LAN
  source replacement, and preserve the enabled state plus existing handler filter/target/additional
  triggers when editing an existing host record. Optional Ollama inline completion is Manual by
  default (Option-Command-/), can be disabled or explicitly enabled On Idle, uses the exact selected
  local model, keeps FIM disabled, and runs through a bounded, no-tools, no-mutation proposal service;
  Escape cancels inline work and the panel can explicitly insert any reviewed reply. Model discovery
  is explicit and cancellable, Off performs no editor-AI network request, and the numeric-loopback
  transport disables system proxies and persistent URL state, rejects redirects, and byte-bounds
  replies before decoding. AI text remains untrusted, may invent invalid Lua despite its prompt, and
  still requires Check/Save validation.
  Corrected the legacy command-palette examples for callback arguments, `emit`, `attach`, block
  methods, timer/log semantics, and `objects.find`/`objects.block`. Regression tests compare the
  runtime binding tree, sandbox surface, attribute/event projections, LuaCATS prefix, and every
  palette snippet against the shipped validator while rejecting the historical invalid forms.

- Added **LAN guest scripting parity**: a host can now run `/script trust <peer>` (and
  `/script trust <peer> ai`) to let a connected guest author/attach/detach/run scripts, set/
  define/remove attributes, subscribe/unsubscribe, emit events, and (with the `ai` grant) use
  `/ai` — all validated and executed on the host through the exact same executors a host's own
  commands use, never on the guest's own machine. Guest `/script edit`/`/inspector` now read
  replicated script metadata (name/mode/enabled — never source) alongside the existing replicated
  attributes; Save/Run in the editor send the guest's work to the host instead of refusing
  outright. A connected guest's own `player:lan:<peerID>` object is now a live, scriptable object
  on the host (readable position/health, attrs/scripts persisted with the world and swept on world
  delete) instead of resolving unsupported. New protocol-5 `scriptIntent` message kind carries the
  guest → host requests, rate-limited and reach/dimension-checked like every other guest intent.
  Also: `SaveDB`'s save-database-open `fatalError` now names the failed stage/result instead of a
  bare "initialization failed".
- Added the **full in-game script editor, Object Inspector, F3 script summary, LAN attribute
  replication, debug-control `script.*` ops, and the remaining fdlibm math ports**:
  `/script edit` now opens a real multi-line editor (type or paste, Enter/Backspace/arrow keys,
  Lua syntax colouring, a module/handler mode toggle with an Event field, up to 16 KiB) instead of
  the previous paste-only field; Save and Run both validate first and highlight the offending
  line on a compile/syntax error rather than silently failing. New `/inspector` command opens the
  Object Inspector — attributes, attached scripts, and event subscriptions of whatever you're
  looking at (or `self`/`player`/`world`), with jump-to-editor for a selected script; unlike the
  pre-existing `/inspect` text command it is not refused on a joined LAN world, since it only
  reads. F3's debug overlay gains one line (live script count, waiting/timers, pending/faulted
  events) whenever a world has any scripts. LAN hosts now replicate script- and AI-set custom
  attributes to connected guests (`LANReplicationBatch.objectAttributes`, capped at 64 objects and
  4 KiB per object, on the existing ~1s world-state cadence) into a read-only guest-side mirror —
  visible through `/inspector`/F3, never through `AttributeStore`, and every mutation path stays
  refused exactly as before. `math.tan`/`asin`/`acos` (removed since the scripting runtime first
  landed) are restored, and `math.log2`/`math.log10` are new — all five now route through the
  fdlibm ports already vendored for `math.sin`/`cos`/`exp`/`log`; `math.log(x, b)` itself is
  unchanged for every base. Debug-control (opt-in `elydebug`/`ElysiumDebug.app` builds only)
  gains `script.list|show|attach|run|journal` ops, routed through the exact same `/script`
  executors. `elysmoke` gains three new fdlibm probe checks (tan/asin+acos/log2+log10 against an
  independently rebuilt reference), 491 checks total, up from 488.

- Added the **AI object graph tool loop**: `/ai` now recognizes a scripting-flavored request (attach
  a script, set an attribute, subscribe to an event, and the like) and hands it to a bounded tool
  loop instead of the single-action path — up to 8 turns, up to 4 mutations per request, with 10
  read-only query tools (list/inspect objects, attributes, scripts, subscriptions, recent events,
  search the block/item/entity/effect registries, check a script's validity, see who would receive
  an event) and 10 mutation tools (set/define/remove an attribute; attach/detach/enable a script;
  subscribe/unsubscribe; emit a custom event; run a one-off script) that all go through the exact
  same validated `/attr`/`/script`/`/on` executors a player's own commands use, refused outright on a
  joined LAN world. Every AI-authored script attach compiles, lints, checks its event-name literals,
  and is tried out on a scratch copy before it's saved for real — a failure there is a warning, not a
  refusal. Every successful AI mutation is journaled with the model's name and can be undone:
  `/script journal` lists what the AI has changed, `/script undo-ai [n]` reverts the most recent `n`
  requests (refusing, never overwriting, if you've since edited a script the AI touched). A script's
  `ai.ask`/`ai.await` now reach a real local Ollama model asynchronously — the tick never waits on
  the network — capped at 2 requests in flight and 30/minute per world. New command: `/ai cancel`.
- Added the **script runtime application layer**: objects can now carry up to 8 attached Lua
  scripts each (module-mode, running at load and registering their own handlers, or handler-mode,
  where the script body *is* the handler for its declared triggers), persisted alongside
  attributes and loaded/run/unloaded at a fixed point of every tick. The full Lua API v1 from the
  scripting design lands: `self`/`world`/`player`/`dim(name)`, `objects.get`/`find`/`block`,
  `on`/`subscribe`/`emit`/`wait`/`tick`/`rng`/`say`, durable named timers (`after`/`every` with a
  name — survive unload, reload, and a restart) alongside live closure timers, `h:get`/`h:set`/
  `h.attrs`/`h:define`/`h:attach`/`h:detach`/`h:scripts`, and `ai.ask`/`ai.await` served by a
  stub responder ahead of the real AI tool loop (a later change). Scripts can attach scripts to
  other objects, with the same caps/validation/provenance as a player or the (future) AI. Two
  independent switches gate every script, checked fresh every tick: the trust gate
  (`WorldRecord.scriptsEnabled`, already shipped — untrusted for every imported/migrated world
  until `/script trust`) and a `doScripts` game-rule kill switch (`/script off`\|`on`, instant).
  New commands: `/script list|show|attach|detach|run|trust|off|on`, all host-only, plus
  `/script edit` opening a minimal paste-only in-game script editor. `elysmoke` gains a
  `scripting` golden section that runs the scripting design document's four Appendix A example
  scripts headlessly end to end — a health-reactive beacon lamp (both handler- and module-mode),
  an AI-gatekeeper mob using `ai.await`, world-wide event counting, and scripts equipping nearby
  blocks with scripts — plus the kill switch, trust gate, and fault isolation (488 checks total,
  up from 478).

- Added the **event bus** underneath the object graph and script runtime: a typed, ordered event
  catalog (`attribute.changed`, `block.placed/broken/replaced/changed/used/neighborChanged`,
  entity/player lifecycle and combat events, `explosion`, world/dimension changes, plus
  script/player-defined custom events) raised from the real engine call sites — block writes,
  entity hurt/die/heal, AI target changes, combat, placement/breaking, world/dimension travel,
  advancements, explosions — and delivered in deterministic `seq` order with coalescing
  (`attribute.changed`/`block.changed` collapse to one delivery per subject), bounded queues, an
  8-level cascade-depth cap, and a 256-event-per-handler budget, each capped excess dropped
  deterministically with exactly one `script.overBudget` diagnostic. Two new commands, `/on
  <target> <event> [attr] <script.handler>` and `/unsubscribe <id>`, register and remove persisted
  subscriptions (saved in the world record, surviving save/load); `/events recent|emit` shows
  recent activity or raises a custom event by hand. Every command is host-only, matching `/attr`'s
  own LAN gate. This still lands no script *execution*: subscriptions are stored and matched, but
  the handler function they name doesn't run yet — that arrives with the script runtime's in-game
  API. `elysmoke` gains an event-bus golden section (478 checks total, up from 469).

- Added an **object graph and attribute system** on top of the embedded script runtime: three new chat commands, `/attr` (`set`/`get`/`list`/`define`/`remove`), `/inspect`, and `/objects near`, let a player read and set small, named attributes on a block or entity, backed by a canonical JSON codec (`AttrValue = ScriptValue`), a persisted per-record revision counter, and durable entity uid reservation so a crash between minting an id and saving can never reuse one. Every command is host-only — a LAN client is refused outright, including through `/ai` and its `/agent` alias. Scripted attribute writes never bypass the engine's own rules for a block: a door's `open` field can be set directly, but the same redstone/support logic that governs it during normal play still applies afterward. This still lands no script-execution surface: there is no in-game scripting language yet, and nothing in the shipped game creates a `LuaState`.

- Added an embedded, deterministic **Lua 5.4.8** script runtime (`CLua` + `ElysiumScript`): a
  vendored, SHA-256-pinned interpreter with a checked-in determinism patch (fixed hash seed,
  ordinal key iteration, locale/decimal-point pin, FP-contraction off), a per-environment stdlib
  sandbox with frozen API proxies, and exact instruction/allocation-rate/memory budgets that fault
  a script — never the engine — on exhaustion. `DetMath` gains `detExp`/`detLog`/`detPow` fdlibm
  ports pinned against an independently rebuilt reference golden, and `elysmoke` gains a
  script-runtime golden section (469 checks total, up from 457). This lands only the runtime and
  its gates: no gameplay, save, LAN, or UI change, and nothing in the shipped game creates a
  script yet.

- Nether maps now draw the traversable cavern around the player's current height instead of the
  sealed bedrock ceiling, with distinct colors for major Nether materials. A default-on **Show
  Minimap** Video preference can hide the compact gameplay map while leaving the `M` expanded map
  available.

- Fixed missing geometry for Soul Sand and every other visible cube whose gameplay `fullCube`
  property is false, eliminating transparent holes through Nether terrain. Rebuilt the first-person
  hand composition with an edge-connected sleeve and forearm, a visible grip over the held item's
  handle, a substantially larger tool/weapon sprite, and bounded attack/use motion beside the minimap.

- Added **Nether World** creation with Nether-first spawn and fallback respawn, the full existing world
  option set, a one-time iron-tool and oak-log starter kit, direct selected-size Nether bounds with
  portal-compatible Overworld reach, and deterministic active gateways throughout the Nether.

- New World now includes **Reality Derived**. It opens the bundled, pinned Arnis map interface for
  place search and bounded rectangle selection, offers an **Include buildings** checkbox, and generates real terrain in a signed
  Rust helper, validates the complete versioned exchange, and atomically saves the imported chunks as
  a normal Elysium world. A bounded 64-block seeded-terrain transition replaces abrupt walls at the
  selected boundary. Cancellation and failures leave no partially listed world; generated files,
  block palettes, properties, coordinates, counts, and sizes are all bounded before persistence.
  The Arnis adapter now emits one canonical chunk stream and Elysium translates it directly into
  compact section-compressed chunks inside an atomic streaming SQLite import, removing the former
  per-file and whole-world memory ceilings. All world types now share Small, Medium, Large,
  Extra-Large, and Max playable extents; Max is 15,811 blocks per side and Reality Derived supports
  the local Arnis limit of 250 km² subject to scale/projected-column capacity. Terrain remains lazy,
  legacy worlds retain the largest extent, and map edges use an invisible travel boundary rather
  than generated walls.
- The first-person arm now remains visible with an empty hand and uses clearer,
  distinct attack and use motion. Player inventory and chest screens add a
  **Sort A-Z** action with `Command-S`: complete stacks sort deterministically
  by name and type without merging or disturbing equipment, crafting, cursor,
  or the player rows beneath a chest. Large chests sort across both halves;
  LAN-client chest sorting stays disabled until remote item metadata is complete.
- Paired chests now meet at one continuous visual seam and retain the complete
  left/right Faithful texture crops instead of losing the seam column.
- Beds can now be positioned explicitly: while holding a bed, left-click its
  head location and then an adjacent foot location. Both halves are validated
  before either is placed, and one bed item is consumed only on success.
- Pack-backed world textures now preserve the atlas's top-origin row order, so
  vegetation, block faces, and shaped objects render upright instead of being
  vertically inverted. Multipart door, bed, and chest subregions stay aligned.
- Faithful 64x fonts, HUD images, buttons, and container panels now retain their
  native 4x raster detail instead of being reduced to 2x and enlarged again on
  Retina displays. Their logical layout and glyph spacing are unchanged.
- Faithful graphics now use one upright PNG convention across world and UI
  consumers, with facing-aware upper/lower door art, head/foot bed art, and
  coherent left/right double-chest fronts. First-person play shows the selected
  item with a lower-right arm, and earned XP reveals a fixed seven-color rainbow
  from left to right while keeping the dark track, fill length, and level number.
  Saved-template deletion now requires an exact-name, Cancel-first confirmation;
  storage failures retain the row and show only bounded player-facing feedback.
- The pinned bundled graphics layer is upgraded from Faithful 32x to hash-pinned Faithful 64x
  Release 12. Video options now has a Resource Packs child screen for the separately bundled Ore
  Borders 64x and Static Lanterns add-ons; both are independently selectable and off by default.
  Packaging, runtime self-healing, attribution, and release checks cover all three exact archives.
- Template placement (`Command-V`) wireframes can now be steered with the arrow
  keys before clicking to place: Left/Right rotate the wireframe (same as the
  scroll wheel), Up pushes it away from you, and Down pulls it closer, with the
  distance clamped to a sane range around the size-based default. Holding Up or
  Down glides the distance continuously; rotation steps once per press. The
  placement hint text and Player Guide document the new controls.
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
