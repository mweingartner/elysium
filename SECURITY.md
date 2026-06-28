# Security Policy

## What Pebble is (and isn't)

Pebble is a local macOS game with player-started LAN multiplayer session support. Local-network multiplayer is deliberately scoped to Bonjour discovery, Direct Connect, bounded handshakes, peer status, LAN chat, host-authoritative replication batches, and host-authorized gameplay intents. Clients can request actions with typed intents, but they cannot send raw save data, arbitrary commands, or authoritative world state; the remote-player gameplay layer enforces permissions for build, container, crafting, template, command, AI, creative, dimension, respawn, death, and reconnect flows.

Current release properties:

- **No external service access.** The app has no telemetry, analytics, update checks, account service, NAT traversal, relay, or cloud multiplayer. The in-app network surfaces are player-started LAN multiplayer over Network.framework and the optional `/ai` command, which is hard-coded to local Ollama on `http://localhost:11434`; the `pebble update` shell command separately runs `git pull` on your own checkout.
- **No accounts, no credentials, no personal data.** Pebble stores worlds, settings, and keybinds under `~/Library/Application Support/Pebble/`.
- **No elevated privileges.** It's an ad-hoc-signed app running in a normal user session.

That makes the realistic threat model: **malicious files that you load into the game, malformed output from local tools you explicitly connect to, and malformed traffic from peers on a local network you choose to join or host.**

## Attack surface

If you're auditing Pebble, these are the interesting places — all of them parse untrusted input:

| Surface | Where | Notes |
|---|---|---|
| Texture zip (bundled Faithful) | `Sources/Pebble/ResourcePacks.swift` | custom zip central-directory parser + raw-deflate via Apple's Compression framework; PNG decode via CoreGraphics. Only the bundled archive is read, but the parser still treats it as untrusted input |
| Save database | `Sources/PebbleCore/Game/Saves.swift` | SQLite blobs in a `VCK1` container with a JSON tail; decode paths bounds-check lengths and clamp out-of-range block/item ids rather than trusting them |
| Object templates | `Sources/PebbleCore/Systems/Templates.swift`, `Sources/PebbleCore/Game/Saves.swift`, `Sources/Pebble/WorldRenderer.swift`, `Sources/Pebble/ScreensM.swift` | Local construction templates stored in SQLite; Command-C copy names plus command/AI names are normalized and capped before save, the copy target comes from a fresh center-crosshair raycast, and template block counts, dimensions, serialized size, block ids, and block-entity item stacks are validated before save/load/place. `/place "name"` and Command-V browser placement arm a placement session and commit only on click; interactive placement validates the bounded object volume and capped support-fill footprint before clearing obstructions or filling foundation gaps; Command-Z restores one in-memory pre-placement snapshot for the last successful object placement without parsing persisted undo data; 3D placement and `/listTemplates` previews derive capped shape-box geometry from validated templates and upload large wireframes through Metal buffers instead of inline vertex bytes; AI template edits and generated pirate-ship templates go through the same validation path and never accept raw model-supplied coordinate arrays; screenshot smoke hooks only allowlist named UI screens |
| Map overlay | `Sources/PebbleCore/Game/MapOverlay.swift`, `Sources/Pebble/MapOverlayM.swift`, `Sources/Pebble/HudM.swift`, `Sources/Pebble/ScreensM.swift` | Reads only loaded in-memory chunk height/top-block data; compact minimap size is limited to three fixed modes, maximum zoom-out is bounded to the currently loaded chunk extent, zoom-in bottoms out at about 100 blocks, and app-side drawing caps minimap/full-map sample resolution so a large loaded world cannot create unbounded UI work |
| Settings/keybinds | `Sources/PebbleCore/Game/Settings.swift` | plain JSON via `Codable`; loaded values are normalized back to the UI/runtime ranges before use |
| Local Ollama agent | `Sources/Pebble/OllamaAgent.swift`, `Sources/PebbleCore/Systems/AIAgent.swift` | loopback-only HTTP to `localhost:11434`; cloud-tagged Ollama models are filtered/rejected; model output is decoded as bounded JSON and can only select whitelisted symbolic actions against registered Pebble content: `say`, `give_item`, cursor `place_block`, bounded player-relative `fill_hole`, saved-template block replacement, or bounded generated-template creation |
| LAN multiplayer | `Sources/PebbleCore/Net/LANMultiplayer.swift`, `Sources/PebbleCore/Net/LANReplication.swift`, `Sources/PebbleCore/Net/LANGameplayOrchestration.swift`, `Sources/Pebble/LANTransport.swift`, `Sources/Pebble/LANLobbyScreen.swift` | Bonjour service `_pebble-lan._tcp` plus TCP Direct Connect through Network.framework; `Info.plist` declares `NSLocalNetworkUsageDescription` and `NSBonjourServices`; frames carry `PBLN` magic, protocol version, message type, sequence, and bounded payload length before JSON decode; player names, join codes, direct hosts, chat text, template names, entity types, replicated arrays, chunk sections, inventory slots, dimensions, death state, gameplay events, block cells, dropped-item payloads, and XP-orb amounts are normalized/capped or registry-validated; clients are accepted only after a join-code handshake; reconnect records are host-owned; remote players and mirrored world entities are transient runtime entities, not save entities; build/container/crafting/template/command/AI/creative/dimension/respawn actions are denied unless the host session grants the permission; clients may not send raw save data, arbitrary command execution, or authoritative world state |

Hardening that already exists: chunk-blob decoding validates section lengths and clamps corrupted block ids to air; LAN replication keeps clients intent-only, caps every replicated collection, drops malformed section payloads, registry-invalid cells, unknown entity types, invalid dropped-item ids/counts, and invalid XP-orb amounts, applies host world mutations only on the main game thread, clamps client-sent player state through host permissions, preserves reconnect state in host-owned peer records, removes dead/disconnected/different-dimension remote player entities, opens accepted title-screen clients into transient LAN worlds, refuses to save those transient client worlds as local singleplayer worlds, never persists remote runtime player entities or mirrored world entities as chunk entities, and skips normal physics/AI/pickup ticks for mirrored world entities; template cloning and placement cap volume/span/JSON size, preflight all destination cells before mutation, cap prepared-placement support fill depth, snapshot placement undo state only from validated in-memory mutations, and bound both `/place` wireframe preview work and `/listTemplates` preview work by box count after template validation; AI terrain-leveling fills never accept model coordinates, require a dirt-like rim in front of the player, write only registered blocks into loaded chunks, and cap search distance, horizontal radius, depth, and total block count; AI template edits resolve source and destination blocks through the registered block registry, reset changed-cell metadata, drop block entities attached to changed cells, and re-encode templates before saving; the live map overlay bounds zoom/pan math to finite loaded chunk extents and caps per-frame UI sampling; crafting-table access to nearby storage is radius-bound and still withdraws concrete recipe ingredients before normal grid consumption; player-data loading repairs array sizes and drops out-of-range item ids; SQLite errors are surfaced and failed writes retried rather than ignored; the zip reader never writes outside its own buffers (it extracts to memory, not to disk paths from the archive), caps archive/file sizes, rejects path-traversal entries, and skips symlinked folder-pack files.

Local verification scripts:

- `./scripts/security-scan.sh` checks source for unapproved network/process/dynamic-loading APIs and obvious secret material. Network APIs are allowed only in the loopback Ollama client and the LAN transport adapter.
- `./scripts/verify-pack-assets.sh` verifies the bundled Faithful archive, including the `assets/minecraft/textures/` namespace Pebble uses for its default graphics.
- `./scripts/security-check-binary.sh /Applications/Pebble.app` verifies the app signature, bundle metadata, linked library paths, and network-related binary symbols/strings. It allows only the local Ollama URL, requires LAN privacy/Bonjour declarations before accepting Network.framework symbols, and rejects other URL literals.
- `./scripts/pipeline.sh` runs the full architecture, security, asset-verification, build, binary-security, test, deploy, and installed-app verification pipeline.

## Reporting a vulnerability

If you find a way for a crafted save file or texture archive to do anything beyond crashing the game (memory corruption, code execution, file writes outside the support directory), please report it privately:

- **Email:** briangaoo2@gmail.com — subject line starting with `[pebble security]`
- Include: macOS version, a minimal reproducing file if possible, and what you observed.

Plain crashes / hangs from malformed files are ordinary bugs — file those as [regular GitHub issues](https://github.com/thebriangao/pebble/issues) with the offending file attached (the README lists what else to include). This is a beta; reports of every kind are incredibly welcome.

You can expect an acknowledgment within a few days. There's no bug bounty; you'll get credit in the changelog and my genuine thanks.

## Supported versions

Only the latest release is supported. There's no backporting; the fix ships in the next version.
