# Security Policy

## What Pebble is (and isn't)

Pebble is a local, singleplayer macOS game:

- **No external network access.** The app has no telemetry, analytics, update checks, multiplayer, or remote service calls. The only in-app network surface is the optional `/ai` command, which is hard-coded to local Ollama on `http://localhost:11434`; the `pebble update` shell command separately runs `git pull` on your own checkout.
- **No accounts, no credentials, no personal data.** Pebble stores worlds, settings, and keybinds under `~/Library/Application Support/Pebble/`.
- **No elevated privileges.** It's an ad-hoc-signed app running in a normal user session.

That makes the realistic threat model: **malicious files that you load into the game and malformed output from local tools you explicitly connect to.**

## Attack surface

If you're auditing Pebble, these are the interesting places — all of them parse untrusted input:

| Surface | Where | Notes |
|---|---|---|
| Texture zip (bundled Faithful) | `Sources/Pebble/ResourcePacks.swift` | custom zip central-directory parser + raw-deflate via Apple's Compression framework; PNG decode via CoreGraphics. Only the bundled archive is read, but the parser still treats it as untrusted input |
| Save database | `Sources/PebbleCore/Game/Saves.swift` | SQLite blobs in a `VCK1` container with a JSON tail; decode paths bounds-check lengths and clamp out-of-range block/item ids rather than trusting them |
| Object templates | `Sources/PebbleCore/Systems/Templates.swift`, `Sources/PebbleCore/Game/Saves.swift`, `Sources/Pebble/ScreensM.swift` | Local construction templates stored in SQLite; template names, block counts, dimensions, serialized size, block ids, and block-entity item stacks are validated before save/load/place. The `/listTemplates` browser is read-only and caps preview drawing work for large templates; screenshot smoke hooks only allowlist named UI screens |
| Settings/keybinds | `Sources/PebbleCore/Game/Settings.swift` | plain JSON via `Codable`; loaded values are normalized back to the UI/runtime ranges before use |
| Local Ollama agent | `Sources/Pebble/OllamaAgent.swift`, `Sources/PebbleCore/Systems/AIAgent.swift` | loopback-only HTTP to `localhost:11434`; cloud-tagged Ollama models are filtered/rejected; model output is decoded as bounded JSON and can only select whitelisted `say`, `give_item`, or cursor `place_block` actions against registered Pebble content |

Hardening that already exists: chunk-blob decoding validates section lengths and clamps corrupted block ids to air; template cloning and placement cap volume/span/JSON size, preflight all destination cells before mutation, and bound `/listTemplates` preview work; crafting-table access to nearby storage is radius-bound and still withdraws concrete recipe ingredients before normal grid consumption; player-data loading repairs array sizes and drops out-of-range item ids; SQLite errors are surfaced and failed writes retried rather than ignored; the zip reader never writes outside its own buffers (it extracts to memory, not to disk paths from the archive), caps archive/file sizes, rejects path-traversal entries, and skips symlinked folder-pack files.

Local verification scripts:

- `./scripts/security-scan.sh` checks source for unapproved network/process/dynamic-loading APIs and obvious secret material. Network APIs are allowed only in the loopback Ollama client.
- `./scripts/verify-pack-assets.sh` verifies the bundled Faithful archive, including the `assets/minecraft/textures/` namespace Pebble uses for its default graphics.
- `./scripts/security-check-binary.sh ~/Applications/Pebble.app` verifies the app signature, bundle metadata, linked library paths, and network-related binary symbols/strings. It allows only the local Ollama URL and rejects other URL literals.
- `./scripts/pipeline.sh` runs the full architecture, security, asset-verification, build, binary-security, test, deploy, and installed-app verification pipeline.

## Reporting a vulnerability

If you find a way for a crafted save file or texture archive to do anything beyond crashing the game (memory corruption, code execution, file writes outside the support directory), please report it privately:

- **Email:** briangaoo2@gmail.com — subject line starting with `[pebble security]`
- Include: macOS version, a minimal reproducing file if possible, and what you observed.

Plain crashes / hangs from malformed files are ordinary bugs — file those as [regular GitHub issues](https://github.com/thebriangao/pebble/issues) with the offending file attached (the README lists what else to include). This is a beta; reports of every kind are incredibly welcome.

You can expect an acknowledgment within a few days. There's no bug bounty; you'll get credit in the changelog and my genuine thanks.

## Supported versions

Only the latest release is supported. There's no backporting; the fix ships in the next version.
