# Contributing to Pebble

**Contribution is incredibly welcome.** Pebble is the open-source alternative to Minecraft: Java Edition, it's a first public beta, and the bug list is unknown by definition — every issue filed and every PR opened genuinely moves the project. You don't need permission to start: pick something broken or missing and go. This file is short on ceremony and long on the things that will actually break the game if you don't know them.

## Filing a bug

Bug reports mean the world to us. [Open an issue](https://github.com/thebriangao/pebble/issues) and include the critical bits that let us reproduce it:

1. **macOS version + Mac model/chip** (e.g. "macOS 15.2, M2 MacBook Air")
2. **Pebble version** (bottom-left of the title screen)
3. **Steps**: what you did, what happened, what you expected
4. **World context** for in-world bugs: seed, dimension, coordinates (all on the F3 overlay)
5. **Settings**: render distance, ultra graphics on/off
6. **Evidence**: screenshots/video for visual bugs; `~/Library/Logs/DiagnosticReports` for crashes; the tail of `pebble test` if the engine seems wrong (expected: `456 passed, 0 failed`)

Even better than a report is a PR with the fix — the rest of this file tells you how to make one that lands.

## Setup

```bash
xcode-select --install        # Swift toolchain (Swift 6, macOS 14+ SDK)
git clone https://github.com/thebriangao/pebble.git && cd pebble
swift build                   # debug build, ~35s clean
swift test                    # focused unit/security regression tests
swift run -c release pebsmoke # the golden suite — must print "456 passed, 0 failed"
./pebble install              # optional: build + install the real app
```

There is no `.xcodeproj` and there never will be — the whole workflow is SwiftPM + the `./pebble` CLI. You can still open the folder in Xcode ("Open Package") if you want an IDE; just don't commit any generated project files.

## Before you open a PR

1. `swift build -c release` — clean, **zero warnings**. The codebase is warning-free and stays that way.
2. `swift test` — all focused unit/security regression tests pass.
3. `swift run -c release pebsmoke` (or `pebble test`) — **456/456**, from the repo root (goldens are found relative to cwd).
4. If goldens changed, your PR description must justify **every** changed value (see below).
5. Keep diffs surgical. Match the style of the file you're in — this codebase has a consistent voice (compact, comment-where-it-matters), and drive-by reformatting makes review impossible.

For the full local pipeline, run `./scripts/pipeline.sh`. It performs architecture checks, source security scans, bundled Faithful asset verification, a warning-free release build, binary security checks, XCTest, the golden suite, deploy, and final installed-app verification.

## The golden workflow (read this twice)

`goldens/*.json` pin the engine's behavior. Two categories:

- **Frozen reference goldens** — `atlas`, `fmath`, `items`. These are immutable reference baselines with no generator — they can **never** be regenerated. If your change breaks one, your change is wrong.
- **Native baselines** — `biome`, `terrain`, `feature`, `mesh`, `worldsim`, `entity`, `systems`. Regenerable with `PEBBLE_REGOLD=1 swift run -c release pebsmoke`, but only for *deliberate* behavior changes.

The required procedure for a behavior change:

1. Make the change. Run the suite. **Read every failure.**
2. For each failing check, explain to yourself (and in the PR) why your change moved that value. "Terrain hashes pass but feature hashes changed, consistent with my flower fix" — that level.
3. Only then regold, and re-run to confirm green.
4. Sanity-check the regold: `PEBBLE_REGOLD` rewrites whole files, and JSON key order shuffles, so byte diffs lie. Compare semantically (e.g. `python3 -c 'import json; print(json.load(open("a"))==json.load(open("b")))'`) and confirm that only the files you expected actually changed values.

Never blanket-regold to make red go green. The suite caught real bugs precisely because nobody did that.

## Conventions that are load-bearing

These are not style preferences. Violating them corrupts worlds or breaks determinism in ways the test suite will catch days later:

- **Registration order is ABI.** Blocks, items, biomes, and enchantments get their numeric ids from registration order, and those ids are in every saved world. Never insert, remove, or reorder registrations. New items/blocks are **appended at the end**, after the frozen baseline range, and baseline checks cover only that prefix (`BASE_ITEM_COUNT` in pebsmoke).
- **Sim code uses the deterministic layer only.** `detSin/detCos/detAtan2` (never `Foundation.sin` in sim paths), `RandomX`/`hash2`/`hash3` (never `Double.random` in anything that affects world state — cosmetic-only draws such as sound pitch or particle scatter, routed through host hooks, are permitted core-side too, not just in app-side rendering/audio), `detRound` for half-step rounding.
- **No unordered iteration in sim decisions.** Swift `Dictionary`/`Set` iteration order is hash-seeded per process. If iteration order can affect world state, use an insertion-ordered array (see `tickingBEList`) or `.sorted()`.
- **Structure-piece RNG: draw, then check.** Builder RNG must be a pure function of (structure, piece). Draw every random value *before* any chunk-relative `b.get()` test — short-circuiting a draw on local chunk contents desyncs the stream across the chunks that rebuild the same piece. Also: `b.get()` returns **−1 outside the building chunk**; guard before casting.
- **Threading contract.** Chunks are built on the gen queue and published only via `adoptChunk` on main. AppKit/renderer state is main-thread-only. Saves go through the serial save queue. The audio render thread owns the voice list; talk to it through the inbox. One-time registration uses `let`-initialized globals (dispatch_once), not boolean guards.
- **GPU buffers the CPU rewrites per frame must be ring-buffered** (3 deep — see UICanvas, particles) or staged through blit encoders (see atlas animations). The renderer has no semaphore; it relies on the 3-drawable limit.
- **Version string** lives in one place: `PEBBLE_VERSION` (PebbleCore/Game/Saves.swift). Bump it there plus `packaging/Info.plist`.

## Testing tips

- `PEBBLE_AUTOLOAD=1 PEBBLE_NEWWORLD=12345 swift run -c release Pebble` — straight into a fresh world.
- `PEBBLE_CMD="/tp 0 120 0;/time set 1000" PEBBLE_SHOT="/tmp/shot.png@600"` — scripted screenshots.
- `PEBBLE_OPEN_SCREEN=templates PEBBLE_SHOT="/tmp/templates.png@240"` — open an allowlisted screen such as the template browser or creative inventory for UI smoke checks.
- `PEBBLE_BOT=1` — runs the physics bot through the real input path and asserts walk/sprint/jump/fall-damage numbers.
- `PEBBLE_PHOTOBOOTH=1` (+ `PEBBLE_BOOTH_MOBS=cow,sheep` / `PEBBLE_BOOTH_BLOCKS=-`) — renders every mob/block to PNGs for visual review.
- `PEBBLE_PROF=1` — per-stage timings for load and tick.

## Scope & conduct

Pebble's approved in-app network surfaces are the loopback-only Ollama agent and the local-network LAN transport tracked in [LAN_MULTIPLAYER_PLAN.md](LAN_MULTIPLAYER_PLAN.md). LAN work must preserve the split where `PebbleCore/Net` owns bounded protocol models/validation and `Sources/Pebble/LANTransport.swift` owns Network.framework. New networking beyond that, including NAT traversal, relay servers, account systems, raw sockets, or cloud services, needs an issue and security plan first. Performance work is welcome but must keep goldens green and come with before/after numbers. Be a normal, decent person in issues and reviews; that's the whole code of conduct.

By contributing you agree your contributions are licensed under the repository's MIT license.

Pebble is an independent fan re-creation, not affiliated with Mojang Studios or Microsoft — see the README's [Disclaimer](README.md#disclaimer).
