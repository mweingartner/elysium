<p align="center">
  <img src="packaging/title-bg.png" alt="Elysium title over a twilight voxel landscape with mountains, forest, water, and a glowing gateway" width="960">
</p>

# Elysium

Elysium is a native macOS voxel survival game built with Swift, Metal, AppKit, and Apple system frameworks. It combines deterministic world simulation with survival progression, construction, optional RPG character development, local-network multiplayer, and a bounded local AI assistant. Elysium is currently beta software.

> **Project origin:** Elysium began with [Brian Gao's open-source Pebble project (`thebriangao/pebble`)](https://github.com/thebriangao/pebble) as its starting point. The codebase has since been renamed and substantially extended as Elysium. We gratefully acknowledge Brian Gao and Pebble's contributors for the foundation they created.

## What is in Elysium

- **Native engine and renderer** — the headless-testable Swift engine drives a hand-written Metal renderer, AppKit interface, runtime texture atlas, lighting, particles, weather, and optional enhanced effects such as SSAO, volumetric light, soft shadows, and ACES tonemapping.
- **Survival across three dimensions** — procedural overworld, nether, and end terrain; caves and structures; mining, farming, crafting, smelting, brewing, enchanting, combat, hunger, experience, sleep, death, respawn, bosses, and advancements.
- **Living worlds** — animals, monsters, villagers, projectiles, vehicles, dropped items, raids, pathfinding, fluids, portals, redstone, block entities, containers, and host-owned simulation state. Hostile monsters react consistently to direct daylight: ordinary monsters ignite, while creepers latch a short fuse and stop chasing.
- **Villager trading** — profession-specific villagers and wandering traders advertise the resources they want, expose their complete ordered offer catalog, and show both costs, stock, level locks, restock state, and affordability before an atomic trade. The trade sheet supports pointer, keyboard, controller, and macOS Accessibility navigation.
- **World creation choices** — Default, Superflat, Large Biomes, Amplified, Single Biome, Debug, and Elysium's Rich Resources preset, plus configurable dungeon density and an optional Character Classes rule.
- **Playable structure sites** — new village plans are moved to validated dry, supported terrain or omitted; ordinary dungeons stay dry, cave-connected, and wholly inside their origin chunk, while a region-budgeted minority may generate as intentionally sealed underwater rooms. Existing saved/modified chunks are never migrated or rewritten; mixed old/new generation seams are supported.
- **RPG progression** — six character paths with attributes, levels, prepared passive and active skills, spells, fatigue, cooldowns, and a second quick-slot bar activated with Shift+1 through Shift+9. Character progression is optional per world; some character operations remain local-world-only while LAN authority continues to be hardened.
- **Object templates** — copy connected builds with Command-C, browse and preview saved templates with Command-V, rotate and place them, and undo the most recent placement with Command-Z. Template parsing and placement are bounded and validated before world mutation.
- **Local-network multiplayer** — host, discover, join, or directly connect to LAN worlds with join codes and host-authoritative replication. Elysium has no public matchmaking, cloud relay, or built-in NAT traversal; a join code is an access gate, not protection from an already hostile local network.
- **Optional local AI assistant** — `/ai <request>` sends context to a configured Ollama endpoint at `http://localhost:11434`. Model output is treated as untrusted and reduced to registered, validated, count- and distance-bounded game actions. Elysium does not control what an independently configured Ollama installation or model provider does beyond that interface.
- **Maps and controls** — compact and expanded live maps, configurable controls, keyboard and controller input, text-entry accessibility, fullscreen support, and debug/automation surfaces used by the verification suite.
- **Synthesized audio** — music and sound effects are produced at runtime rather than shipped as conventional audio recordings.
- **Resource-pack support** — Java Edition-style resource packs are read through Elysium's bounded archive and metadata loaders. The bundled default visual layer is Faithful 32x, credited under [Credits and licenses](#credits-and-licenses).

For the subsystem boundaries and determinism rules, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Install and run

Requirements:

- macOS 14 or later
- Xcode command-line tools (`xcode-select --install`)
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

All gameplay bindings can be changed in Options → Controls.

| Input | Default action |
|---|---|
| W A S D | Move |
| Mouse | Look; attack/break; use/place |
| Space | Jump |
| Shift | Sneak |
| Control or double-tap forward | Sprint |
| E | Inventory |
| T | Chat and commands |
| M | Expand or collapse the map |
| `-` / `=` | Change compact map size |
| `,` / `.` | Change map zoom |
| Command-C / Command-V / Command-Z | Copy, place, or undo an object template |
| Shift+1 … Shift+9 | Use a prepared RPG action |
| F1 / F3 / F11 | Toggle HUD, debug overlay, or fullscreen |
| Escape | Pause or close the current screen |

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

Elysium stores worlds, player state, settings, key bindings, and templates under:

```text
~/Library/Application Support/Elysium/
```

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

`elysmoke` is the deterministic golden contract and is expected to report 457 passing checks unless a reviewed behavior change deliberately updates that contract.

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
5. The 457-check `elysmoke` golden suite.
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
Sources/Elysium/           AppKit and Metal application, UI, renderer, audio, input, and transport
Sources/ElysiumStorage/    Typed SQLite persistence boundary
Sources/ElysiumTextInput/  Shared text-ingress validation
Sources/ElysiumAppSupport/ Shared AppKit support kernels
Sources/elysmoke/          Golden-contract executable
Tests/                     Unit, integration, boundary, property, and regression tests
goldens/                   Frozen deterministic baselines
packaging/                 App metadata, branding, icons, and licensed texture assets
scripts/                   Build, scan, package, test, install, and automated release gates
```

## Contributing and reporting problems

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing implementation code. It documents deterministic registration order, RNG rules, test expectations, golden updates, and the Model-Paired Development gates used by this repository.

Use [GitHub issues](https://github.com/mweingartner/elysium/issues) for reproducible gameplay and development bugs. Before sharing crash logs, screenshots, saves, or world databases publicly, inspect them for usernames, filesystem paths, world names, chat, or other personal content.

Report suspected security vulnerabilities privately using [SECURITY.md](SECURITY.md). Elysium processes untrusted saves, archives, LAN messages, and model output, so crashes or boundary escapes in those surfaces deserve careful handling.

## Credits and licenses

- **Starting point:** Elysium began from [thebriangao/pebble](https://github.com/thebriangao/pebble), created by Brian Gao. Its open-source Swift and Metal codebase provided the foundation from which Elysium evolved. The inherited MIT copyright and permission notice are preserved in [LICENSE](LICENSE).
- **Textures:** the bundled [Faithful 32x](https://faithfulpack.net/) texture set is the work of the Faithful team and its contributors. It is distributed under the separate [Faithful License](packaging/FAITHFUL-LICENSE.txt) and is not covered by Elysium's MIT license.
- **Deterministic math:** the fdlibm-derived math implementation retains its upstream notice in source.
- **Elysium hero artwork:** `packaging/title-bg.png` was newly generated for Elysium and serves as both this README's hero and the in-game title-menu background. It is not derived from Pebble's README artwork or an in-game Faithful texture capture.

Except for separately identified third-party material, source code is available under the [MIT License](LICENSE).

## Independence statement

Elysium is an independent fan project inspired by publicly observable mechanics from Minecraft: Java Edition. It is not an official Minecraft product and is not affiliated with, endorsed by, sponsored by, or connected to Mojang Studios, Microsoft Corporation, or their subsidiaries. “Minecraft” is a trademark of its respective owner. No Mojang or Microsoft source code or extracted asset files are included in this repository.

Elysium is provided as-is, without warranty, under the terms in [LICENSE](LICENSE).
