<p align="center">
  <img src="packaging/title-bg.png" alt="Elysium title over a twilight voxel landscape with mountains, forest, water, and a glowing gateway" width="960">
</p>

# Elysium

Elysium is a native macOS voxel survival game built with Swift, Metal, AppKit, and Apple system frameworks. It combines deterministic world simulation with survival progression, construction, optional RPG character development, local-network multiplayer, and a bounded local AI assistant. Elysium is currently beta software.

> **Project origin:** Elysium began with [Brian Gao's open-source Pebble project (`thebriangao/pebble`)](https://github.com/thebriangao/pebble) as its starting point. The codebase has since been renamed and substantially extended as Elysium. We gratefully acknowledge Brian Gao and Pebble's contributors for the foundation they created.

> **New to Elysium?** The [Player Guide](PLAYER_GUIDE.md) walks through a first world, complete controls,
> progression, classes, trading, saves, LAN play, accessibility, and the current beta limits.

## What is in Elysium

- **Native engine and renderer** — the headless-testable Swift engine drives a hand-written Metal renderer, AppKit interface, runtime texture atlas, lighting, particles, weather, and optional enhanced effects such as SSAO, volumetric light, soft shadows, and ACES tonemapping.
- **Survival across three dimensions** — procedural overworld, nether, and end terrain; caves and structures; mining, farming, crafting, smelting, brewing, enchanting, combat, hunger, experience, sleep, death, respawn, bosses, and advancements.
- **Living worlds** — animals, monsters, villagers, projectiles, vehicles, dropped items, raids, pathfinding, fluids, portals, redstone, block entities, containers, and host-owned simulation state. Hostile monsters react consistently to direct daylight: ordinary monsters ignite, while creepers latch a short fuse and stop chasing.
- **Villager trading** — profession-specific villagers and wandering traders advertise the resources they want, expose their complete ordered offer catalog, and show both costs, stock, level locks, restock state, and affordability before an atomic trade. The trade sheet supports pointer, keyboard, controller, and macOS Accessibility navigation.
- **World creation choices** — Default, Superflat, Large Biomes, Amplified, Single Biome, Debug, Elysium's Rich Resources preset, and **Nether World**, plus **Reality Derived** maps built from a player-selected real-world area through the bundled Arnis generator. Nether World begins in a safe active-portal chamber with two iron pickaxes, an iron sword, an iron shovel, and 64 oak logs; active gateways recur throughout its Nether. Every type offers Small (1 km), Medium (4 km), Large (8 km), Extra-Large (12 km), and Max (15.811 km) playable widths with lazy terrain generation; Reality Derived Max reaches the local Arnis 250 km² envelope. Procedural worlds also offer configurable dungeon density; every world can enable or disable Character Classes.
- **Playable structure sites** — new village plans are moved to validated dry, supported terrain or omitted; ordinary dungeons stay dry, cave-connected, and wholly inside their origin chunk, while a region-budgeted minority may generate as intentionally sealed underwater rooms. Existing saved/modified chunks are never migrated or rewritten; mixed old/new generation seams are supported.
- **RPG progression** — six character paths, each with three sub-classes, levels, five-rank skills with a skill-point economy, always-on passive skills, prepared active skills and spells, fatigue, cooldowns, and a second quick-slot bar activated with Shift+1 through Shift+9. Character progression is optional per world; some character operations remain local-world-only while LAN authority continues to be hardened.
- **Object templates** — copy connected builds with Command-C, browse and preview saved templates with Command-V, steer the wireframe with the arrow keys (Left/Right rotate, Up/Down push/pull) or scroll wheel, place them, and undo the most recent placement with Command-Z. Template parsing and placement are bounded and validated before world mutation.
- **Local-network multiplayer** — host, discover, join, or directly connect to LAN worlds with join codes and host-authoritative replication. Elysium has no public matchmaking, cloud relay, or built-in NAT traversal; a join code is an access gate, not protection from an already hostile local network.
- **Optional local AI assistant** — `/ai <request>` sends context to a configured Ollama endpoint at `http://127.0.0.1:11434`. Model output is treated as untrusted and reduced to registered, validated, count- and distance-bounded game actions. Elysium does not control what an independently configured Ollama installation or model provider does beyond that interface.
- **Maps and controls** — compact and expanded live maps, including player-level cavern mapping in the Nether, configurable controls, keyboard and controller input, text-entry accessibility, fullscreen support, and debug/automation surfaces used by the verification suite. The compact minimap is shown by default and can be hidden under **Options... → Video → Show Minimap** without disabling the `M` expanded map.
- **Audio and script sounds** — Elysium's existing game music and effects remain synthesized at runtime. Scripts may additionally play a named imported WAV or a standard macOS system/ToneLibrary sound at the owning object's position. **Options... → Audio → Script Sounds...** imports, previews, and deletes the managed WAV library.
- **Resource-pack support** — Java Edition-style resource packs are read through Elysium's bounded archive and metadata loaders. The pinned default is [Faithful 64x](https://faithfulpack.net/faithful64x) Release 12; **Options... → Video → Resource Packs...** offers the reviewed Ore Borders 64x and Static Lanterns add-ons independently, both off by default.
- **Scripting, extensible events, and the AI object graph** — every block, entity, player, dimension, and world can carry typed custom attributes, object-scoped custom event declarations, event handlers, and up to 8 attached Lua scripts on a sandboxed, deterministic, budgeted Lua 5.4.8 interpreter (`CLua` + `ElysiumScript`). Scripts can observe another live object directly (`target:on(...)`, `target:onAttribute(...)`), publish a discoverable payload contract (`target:declareEvent(...)`), and emit either declared or open custom events. A broad built-in catalog covers attribute/lifecycle, block, entity, player, dimension, world, and furnace interaction; `block.toolStrike` describes a real first tool strike, while `furnace.smeltCompleted` reports each completed smelt. A furnace's own attached script may use `self:setFurnaceOutput("iron_ingot")` to replace its existing and future recipe output only while that trusted script remains live. Built-in events are engine-produced facts and cannot be emitted manually. Players can inspect, define, remove, and emit custom events through `/events`, or use the native editor's target-aware event picker, payload-field completion, validated snippets, diagnostics, and nearby World Objects browser. Deterministic completion never needs AI; editor Ollama suggestions remain a separate, optional manual action by default. The embedded-AI world tool loop receives a compact Lua authoring contract whose built-in event catalog and payloads come from the live canonical registry, and can inspect or manage declarations, scripts, attributes, subscriptions, and events through the same validated, budgeted, journaled path, undoable where supported with `/script undo-ai`. Execution remains host-only, gated by per-world trust and the `doScripts` kill switch; authorized LAN guests receive source-free event metadata for accurate authoring and send mutations to the host for validation. See [docs/SCRIPTING_GUIDE.md](docs/SCRIPTING_GUIDE.md) for the command/Lua API and [docs/LUA_EDITOR.md](docs/LUA_EDITOR.md) for editor behavior and controls.

For the subsystem boundaries and determinism rules, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Scripting quick start

Open the Lua editor with Command-E (or `/script edit looking ore_reaction`), target an object, and
choose **Module** when the source should register one or more callbacks. This complete example gives
the targeted block a persistent custom attribute, observes the engine-produced first-tool-strike
event, and publishes a typed custom event after the third strike:

```lua
if self:get("strike_count") == nil then
  self:define("strike_count", 0)
end
self:declareEvent("ore.awakened", {
  count = "integer",
  player = "object",
}, "This ore was struck three times")

self:on("block.toolStrike", function(ev)
  local count = (self:get("strike_count") or 0) + 1
  self:set("strike_count", count)
  if count == 3 then
    self:emit("ore.awakened", {count = count, player = ev.by})
  end
end)
```

Secondary use is an event in its own right, not merely a report that built-in gameplay changed
something. A valid use target emits `entity.interacted` for the foremost entity under the crosshair,
or `block.used` for the block when no entity is foremost, even when that entity or block has no
native use action. Scripts attached to inert terrain, decorations, and otherwise non-interactive
entities can therefore react to the ordinary use control. The event's held-item payload is captured
before native interaction code can consume or replace the stack. On LAN, the client names its
observed target; the host validates current identity, reach, dimension, lifecycle, permission, and
selected slot before raising a replay-safe event without duplicating native-use events. Protocol 5
does not independently reconstruct the guest's ray or verify occlusion, so it remains a trusted-LAN
facility rather than a hostile-network authority boundary.

Scripts can play audio by live catalog name with `sound(name[, volume])`, where `volume` is from 0
through 1 and the boolean result reports whether playback started. Matching is case-insensitive and
playback is positioned at the script-owning object. The catalog combines imported WAV filenames
with the standard names discovered from `/System/Library/Sounds` and macOS ToneLibrary; imported
names are offered first by completion but cannot shadow a built-in name. Manage imported files at
**Options... → Audio → Script Sounds...**.

Every handle—world, dimension, block, entity, or player—supports custom attributes and object-scoped
event declarations. A script can observe a different live object directly:

```lua
local gate = objects.get("block:overworld:10,64,3")
gate:onAttribute("open", function(ev)
  say("Gate changed from " .. tostring(ev.old) .. " to " .. tostring(ev.new))
end)
```

Typing `gate:` opens the target-aware member flyout; Handler mode similarly offers only compatible
produced events plus that target's declarations, and `ev.` completes the selected event's payload.
The nearby **World Objects** browser inserts canonical references so they do not need to be guessed.
Deterministic completion and diagnostics are always local. Ollama completion is separate and Manual
by default. Opening the native editor in Manual or On Idle mode warms the exact local model selected
in Options—even when the Script AI panel is closed—using an empty request with no source, world
context, or tools. Before warmup or source-bearing generation, a source-free `/api/show` preflight
requires Ollama to identify that selection as local rather than a remote-backed alias. An explicit
request waits for the shared warmup and retries a failed warmup in the same interaction; Off performs
no model discovery, warmup, or generation. Toolbar/menu/hotkey and On
Idle proposals remain ghost text that Tab accepts and Escape dismisses. The Script AI panel has
explicit **Write Code** and **Ask** intents: Ask is always transcript-only, while Write Code may
replace the captured selection with safe, mode-correct Lua as one Command-Z-undoable draft edit.
The editor sends a nonce-fenced JSON request in which only the explicit instruction is intent;
surrounding Lua, object metadata, event summaries, and diagnostics remain untrusted data even if a
comment or string resembles a prompt. Module requests ask for one complete chunk with callbacks and
no top-level `ev`; Handler requests ask only for the selected event body with implicit `ev`. A
selection is never partly shown and wholly replaced: requests larger than 4,096 selected characters
are refused before model warmup or generation, leaving the draft unchanged. The 16K model context
provides headroom for the separately bounded schema, target contract, diagnostics, nearby-object
facts, and complete accepted selection.
Before insertion, Elysium revalidates the captured document, selection, model, mode, event, and
authoring context, then applies its compiler, diagnostics, conservative lexical
unresolved-global/call-target/callback checks, dynamic-`_ENV` rejection, and mutation-free
validation. Module receives module/callback source; Handler receives only the
selected event's body with implicit `ev`. LAN guests and editors without a local authoritative
runtime keep generated code in the transcript for manual review. Write Code may omit only clearly
explanatory, non-Lua text outside a complete fence or at the end of an unfenced reply; the full reply
stays visible and the omission is reported. Prose-only, code-like exterior or suffix, unsafe, or
invalid output leaves the draft unchanged with a refusal. No AI response saves, runs, trusts,
enables, or directly mutates the world. See the
[Scripting Guide](docs/SCRIPTING_GUIDE.md) for the
complete attribute, handler, declaration, payload, command, limits, persistence, and LAN contracts,
and the [Lua Editor reference](docs/LUA_EDITOR.md) for editor controls and privacy behavior.

The separate built-in `/ai` scripting lane can install code when the request says to create, add,
install, fix, or replace a script. Its app-owned system protocol first requires the model to resolve
an observed exact object reference, inspect that object and any existing named script, query the
target-compatible event/payload and attributes, and resolve every new registry id. It must then
choose exactly one shape: a Module is a complete top-level chunk and omits `triggers`; a Handler is
only an implicit-`ev` callback body and passes `triggers` as the tool's JSON-string argument. The
model must call the validated `attach_script` tool for an installation request instead of merely
printing code, read the complete result, and surface every warning or refusal. A result marked
`loaded:"pending"` means stored for the next script phase—not proof that the script is running or
that its event fired—and world trust plus `doScripts` remain authoritative. World snapshots, tool
results, object names, attributes, existing source, event summaries, and errors are nonce-fenced
untrusted data; the runtime compiler, lint, reference checks, dry run, and mutation gates remain the
real authority rather than the prompt.

### Character paths and sub-classes

When the Character Classes rule is on, the inventory's **Character** button or `K` opens a
resizable native macOS window. Creation runs **Path → Sub-class → Starting Skills → Review** in a
four-step sidebar: select a card, inspect its details, then use **Continue**. Closing after changing the
draft asks before discarding it. The final review is consequential: the chosen path, sub-class, and three
starting skills are permanent for that character.

A **path** is the top-level gameplay role; each path has exactly three **sub-classes**, each with its own
three-skill purpose. You choose exactly 3 rank-1 starting skills from a pool of 5: the selected
sub-class's 3 skills plus the signature skill of each sibling sub-class. Every skill has 5 ranks, and
Arcanist and Mender grant starter spells through first-rank skill unlocks. There are no attributes —
health and fatigue grow automatically with level at a fixed per-path rate.

| Path | Growth | Purpose and play loop | Sub-classes |
|---|---|---|---|
| **Warden** | Health 26 +2/lvl · Fatigue 10 +1/lvl | Front-line protector: hold dangerous ground, blunt hostile pressure, and turn close combat or timely defense into safety. | **Guardian** (defend an area, keep allies up) · **Vanguard** (close distance, punish exposed foes) · **Bulwark** (turn armor and blocks into durable defense) |
| **Ranger** | Health 20 +1/lvl · Fatigue 14 +2/lvl | Mobile ranged scout: explore ahead, establish safe sightlines, and stop threats before they close. | **Marksman** (accurate ranged, fast target-swap) · **Scout** (sneaking mobility, hostile detection) · **Survivalist** (forage, camp, weather, animals) |
| **Delver** | Health 24 +2/lvl · Fatigue 12 +1/lvl | Underground specialist: read terrain, manage hazards, extract resources, and recover guarded treasure. | **Miner** (faster excavation, mining bursts, deep-fatigue recovery) · **Trapper** (detect traps, resist blasts, place deadfalls) · **Treasure-Seeker** (salvage, locks, risky loot) |
| **Arcanist** | Health 16 +1/lvl · Fatigue 20 +3/lvl | Fatigue-driven spellcaster: prepare a compact spell kit and reshape encounters with damage, deception, wards, or summons. | **Elementalist** (fire, frost, lightning, storms) · **Illusionist** (blur, decoys, invisibility) · **Ritualist** (long casts, wards, summons) |
| **Mender** | Health 18 +1/lvl · Fatigue 18 +2/lvl | Support specialist: answer hostile injuries, cleanse danger, establish safe zones, and turn food into expedition strength. | **Physic** (direct and emergency healing) · **Harvest** (food, herbs, medicine) · **Sanctuary** (safe zones, wards, rescues) |
| **Tinker** | Health 20 +1/lvl · Fatigue 16 +2/lvl | Engineering specialist: learn recipes, build powered mechanisms, maintain gear, and trade setup time for repeatable advantage. | **Redstone** (compact circuits, signals) · **Artificer** (gear tuning, field repairs) · **Sapper** (controlled blasts, demolition) |

Class XP comes only from each path's registered gameplay events; cosmetic or repeated no-op actions do
not count. Per-category 1,200-simulation-tick admission caps and separate rolling or lifetime duplicate
guards limit farming. The native **Progress** page shows registry-backed criteria alongside the canonical
path ownership and reward rules consumed by the authoritative award gate; focused contracts keep that
copy aligned with the qualifying gameplay call sites. The [Player Guide](PLAYER_GUIDE.md#exact-class-xp-rules)
lists every source, reward, shared window, and duplicate rule.

## Install and run

Requirements:

- macOS 14 or later
- Xcode command-line tools (`xcode-select --install`)
- Rust and Cargo (only when building Elysium from source; the installed app bundles its pinned Arnis helper)
- Apple silicon recommended

```bash
git clone https://github.com/mweingartner/elysium.git
cd elysium
./elysium install
```

`./elysium install` builds the release executable, verifies packaged assets, assembles an ad-hoc-signed app, installs it at `/Applications/Elysium.app`, and attempts to link the `elysium` command into a writable Homebrew or local binary directory. Writing to `/Applications` may require local administrator authority depending on the Mac's permissions.

```text
elysium run       Launch the installed app
elysium update    Fast-forward the checkout, rebuild, and replace the installed app
elysium test      Run XCTest and the golden smoke suite
```

Run directly from a checkout with:

```bash
swift run -c release Elysium
```

## Essential controls

For the complete gameplay reference and troubleshooting help, see the [Player Guide](PLAYER_GUIDE.md).

All gameplay bindings can be changed in Options → Controls.

| Input | Default action |
|---|---|
| W A S D | Move |
| Mouse | Look; attack/break; use/place. With a bed held, left-click its head position, then an adjacent foot position. |
| Space | Jump |
| Shift | Sneak |
| Control or double-tap forward | Sprint |
| E | Inventory |
| G / H | Toggle a torch or shield into the off (left) hand |
| Command-S | Sort the open player inventory or local/host chest A-Z |
| T | Chat and commands |
| M | Expand or collapse the map |
| `-` / `=` | Change compact map size |
| `,` / `.` | Change map zoom |
| Command-C / Command-V / Command-Z | Copy, place, or undo an object template |
| Shift+1 … Shift+9 | Use a prepared RPG action |
| F1 / F3 / F11 | Toggle HUD, debug overlay, or fullscreen |
| Escape | Pause or close the current screen |

The compact lower-right minimap follows the open cavern around you in the Nether instead of the
sealed ceiling. To reclaim that HUD space, turn off **Options... → Video → Show Minimap**; the
expanded map opened with `M` remains available.

An empty selected slot leaves the first-person view completely clear. Selected pickaxes use
material-correct three-quarter Blender renders of a pinned CC0 voxel mesh, held at a readable
scale without deforming the image during a strike. Other tools now stand upright in the fist —
their reviewed Faithful art rotated so the handle meets the hand instead of floating past it, with
the painted haft removed from the arm so the fingers grip the tool's own handle. Blocks retain
their three-dimensional voxel preview, while foods and other objects retain high-resolution
Faithful item art. Attack/use poses provide clear feedback for swings and tool actions: the
stroke runs on the wall clock at frame rate, cycles continuously while the mouse button is held,
completes its arc after release instead of snapping home, and plays a shorter stroke for each
use gesture. Both hands sway with the walk cycle alongside the camera. Changing what a hand holds
lowers the outgoing item out of view and raises the incoming one; food is nibbled on the rhythm
of the eating sound. Bows, shields, and torches render in the left (off) hand. **G** and **H** toggle a torch
or a shield from the inventory into the off hand and back, so you can carry a pickaxe and a torch
to mine with light, or a sword and a shield to fight defensively; a held torch in either hand casts
a soft, flickering warm light on the world around you. Holding use with a bow raises it, brings the
right hand to the string, advances through the charge frames, and fires on release using the same
charge duration that determines arrow power; after the shot both hands relax back along the draw
path. Holding use with a shield in the off hand and a sword,
mace, or empty main hand raises the shield to guard over the same quarter second the block takes
to become active (and eases it back down on release), and while raised it stops a frontal melee or
projectile hit — damage and knockback both — leaving flanking and environmental damage to land.
Inventory and chest
screens include a **Sort A-Z** button; sorting orders complete stacks by item
name and type without merging them or moving equipment, crafting, cursor, or
other non-storage slots. Chest sorting is disabled for LAN clients until the
host-authoritative container protocol carries the item metadata required to
produce the same deterministic order.

### Trading with NPCs

Use the normal **use/place** action on an adult professioned villager or a
wandering trader while playing locally or as the LAN host. The trade sheet lists
the resource types that the merchant wants, every ordered offer, required counts,
current holdings, result count, stock, level locks, and workstation/restock state.
Select an offer with the pointer, Up/Down, Page Up/Page Down, Home/End, or the
equivalent controller commands; scroll the offer list to reach later tiers, then
activate **Trade**. A disabled Trade button remains focusable and explains the
blocking reason, such as missing resources, level, stock, range, line of sight,
or inventory capacity. Payment and output commit together or not at all.

LAN clients cannot trade yet because Elysium has no host-authoritative remote
barter protocol; the interaction fails closed instead of approximating merchant
state on the client.

## Local data

Elysium stores worlds, player state, settings, key bindings, templates, and imported script sounds under:

```text
~/Library/Application Support/Elysium/
```

Validated script WAV files are copied into the managed `Sounds/` subdirectory. Lua receives only
catalog names and never a filesystem path.

On first use after the rename, the app can migrate supported legacy Pebble data into the Elysium application-support location. Back up world data before manual deletion or migration.

### Selecting and deleting saved worlds

The saved-world browser supports conventional macOS multi-selection. Click a row to select it;
Command-click or click its checkbox to toggle it; Shift-click selects an anchored range; and
Command-Shift-click adds a range. Select All/Clear All and Command-A, while the saved-world list has
keyboard focus, operate on the complete checked list. Keyboard users can move focus with the Arrow keys,
extend selection with Shift-Arrow, or move focus without changing selection with Command-Arrow, then
toggle the focused row with Space. Delete and Backspace do not delete worlds.

Play Selected or Host Selected requires exactly one selected world. To delete one or more worlds, use
the Delete button and then confirm the permanent operation in the separate dialog; Cancel has initial
focus. Elysium removes the selected worlds and their chunks, player data, advancements, and RPG data as
one atomic local transaction. If the saved-world list changes, Elysium asks you to review the selection.
If the result cannot be proven, the browser locks to Reload Saved Worlds and performs read-only recovery
instead of repeating deletion. Saved-world deletion is local-only and never deletes data from a LAN host.

To uninstall the application, remove `/Applications/Elysium.app`. Remove the application-support directory only if you also intend to permanently delete local worlds and settings. The CLI symlink, when created, is normally `/opt/homebrew/bin/elysium` or `/usr/local/bin/elysium`.

## Build and verify

The ordinary development gate is:

```bash
swift build -c release
swift test
swift run -c release elysmoke
```

`elysmoke` is the deterministic golden contract and is expected to report 491 passing checks unless a reviewed behavior change deliberately updates that contract.

Security-sensitive changes also run:

```bash
bash scripts/security-scan.sh
```

The release pipeline is a zero-argument command:

```bash
bash scripts/pipeline.sh
```

It runs these nine automated stages, in order, and stops at the first failure:

1. Source security scan.
2. Warning-free release build.
3. Release-surface and binary security checks.
4. Full XCTest.
5. The 491-check `elysmoke` golden suite.
6. Application packaging.
7. Packaged AppKit keyboard and Accessibility integration.
8. Installation at `/Applications/Elysium.app`.
9. Installed-app identity and code-signature verification against the packaged candidate.

`PASS proves this checkout produced and installed the verified local /Applications/Elysium.app; it does not mean committed, pushed, CI-green, published, or subjectively visually approved.`

Release evidence has deliberately separate meanings:

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Commit succeeds | The staged change passed the fast pre-commit policy and secret checks. | Push, full pipeline, installation, or publication. |
| Push succeeds | The outgoing commit passed the pre-push source scan, release build, binary checks, AppKit integration, XCTest, and `elysmoke`. | Installation, publication, CI success, or visual quality. |
| `bash scripts/pipeline.sh` passes | The exact local candidate passed all nine stages, including package/install identity and code-signature verification. | GitHub publication, CI success, or subjective visual quality. |
| CI passes | GitHub's configured checks passed for the identified commit. | Local installation or subjective visual quality. |
| Commit is visible on GitHub `main` | The identified commit was published to the repository's public default branch. | CI success, local installation, or subjective visual quality. |
| Human visual review passes | A person judged the reviewed screens and interactions acceptable. | Reproducible build, automated correctness, installation identity, or code-signature validity. |

The pre-commit hook is intentionally fast: it checks only staged policy and secret safety. The
pre-push hook is the heavier source/build/test regression gate. Neither substitutes for the
zero-argument pipeline's package, real-install, and installed-signature stages. Activate both hooks
after cloning:

```bash
git config core.hooksPath .githooks
```

## Project layout

```text
Sources/ElysiumCore/       Deterministic engine, world, entities, systems, saves, and LAN model
Sources/ElysiumCore/Scripting/  Object graph, canonical AttrValue JSON, persisted attribute
                            bags/scripts/custom-event declarations, the indexed event bus, the sandboxed Lua script
                            runtime, the AI object-graph tool loop, and the /attr /inspect
                            /objects /on /unsubscribe /events /script /ai command layer
Sources/ElysiumScript/     The embedded Lua 5.4.8 runtime's Swift-facing API (LuaState,
                            handles, sandboxed environments) over the vendored CLua/Lua C core
Sources/Elysium/           AppKit and Metal application, UI/native Lua editor, renderer, audio,
                            input, LAN transport, and loopback Ollama client
Sources/ElysiumStorage/    Typed SQLite persistence boundary
Sources/ElysiumTextInput/  Shared text-ingress validation
Sources/ElysiumAppSupport/ Shared AppKit support kernels
Sources/elysmoke/          Golden-contract executable
Vendor/Arnis/              Pinned Apache-2.0 Arnis source and map-selection assets
Tests/                     Unit, integration, boundary, property, and regression tests
goldens/                   Frozen deterministic baselines
packaging/                 App metadata, branding, icons, and licensed texture assets
scripts/                   Build, scan, package, test, install, and automated release gates
```

## Contributing and reporting problems

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing implementation code. It documents deterministic registration order, RNG rules, test expectations, golden updates, and the direct build/test/release checks used by this repository.

Use [GitHub issues](https://github.com/mweingartner/elysium/issues) for reproducible gameplay and development bugs. Before sharing crash logs, screenshots, saves, or world databases publicly, inspect them for usernames, filesystem paths, world names, chat, or other personal content.

Report suspected security vulnerabilities privately using [SECURITY.md](SECURITY.md). Elysium processes untrusted saves, archives, LAN messages, and model output, so crashes or boundary escapes in those surfaces deserve careful handling.

## Credits and licenses

- **Starting point:** Elysium began from [thebriangao/pebble](https://github.com/thebriangao/pebble), created by Brian Gao. Its open-source Swift and Metal codebase provided the foundation from which Elysium evolved. The inherited MIT copyright and permission notice are preserved in [LICENSE](LICENSE).
- **Textures:** the bundled [Faithful 64x](https://faithfulpack.net/faithful64x) texture set is the work of the Faithful team and its contributors. The reviewed [Ore Borders 64x](https://faithfulpack.net/addons/OreBorders64x) and [Static Lanterns](https://faithfulpack.net/addons/ClearerLanterns) add-ons remain separate, optional layers. They are distributed under the separate [Faithful License](packaging/FAITHFUL-LICENSE.txt), with archive hashes and exact add-on attribution in [FAITHFUL-ADDONS-CREDITS.txt](packaging/FAITHFUL-ADDONS-CREDITS.txt), and are not covered by Elysium's MIT license.
- **Held pickaxe geometry:** the model-rendered pickaxe family derives from [tfwa.games Voxel Tools](https://tfwagames.itch.io/voxel-tools), distributed under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). Elysium pins the source geometry and every generated render by SHA-256; details and reproducible commands are in [Assets/Elysium/HeldPickaxe3D/README.md](Assets/Elysium/HeldPickaxe3D/README.md).
- **Deterministic math:** the fdlibm-derived math implementation retains its upstream notice in source.
- **Elysium hero artwork:** `packaging/title-bg.png` was newly generated for Elysium and serves as both this README's hero and the in-game title-menu background. It is not derived from Pebble's README artwork or an in-game Faithful texture capture.
- **Reality Derived maps:** the bundled [Arnis](https://github.com/louis-e/arnis) generator is by Louis Eriguchi and contributors and is redistributed under its [Apache-2.0 license](Vendor/Arnis/LICENSE). It uses OpenStreetMap and elevation/land-cover sources identified in the Arnis interface; map attribution remains visible in that interface.

Except for separately identified third-party material, source code is available under the [MIT License](LICENSE).

## Independence statement

Elysium is an independent fan project inspired by publicly observable mechanics from Minecraft: Java Edition. It is not an official Minecraft product and is not affiliated with, endorsed by, sponsored by, or connected to Mojang Studios, Microsoft Corporation, or their subsidiaries. “Minecraft” is a trademark of its respective owner. No Mojang or Microsoft source code or extracted asset files are included in this repository.

Elysium is provided as-is, without warranty, under the terms in [LICENSE](LICENSE).
