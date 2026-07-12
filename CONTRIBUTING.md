# Contributing to Pebble

**Contribution is incredibly welcome.** Pebble is the open-source alternative to Minecraft: Java Edition, it's a first public beta, and the bug list is unknown by definition — every issue filed and every PR opened genuinely moves the project. You don't need permission to start: pick something broken or missing and go. This file is short on ceremony and long on the things that will actually break the game if you don't know them.

## Filing a bug

Bug reports mean the world to us. [Open an issue](https://github.com/thebriangao/pebble/issues) and include the critical bits that let us reproduce it:

1. **macOS version + Mac model/chip** (e.g. "macOS 15.2, M2 MacBook Air")
2. **Pebble version** (bottom-left of the title screen)
3. **Steps**: what you did, what happened, what you expected
4. **World context** for in-world bugs: seed, dimension, coordinates (all on the F3 overlay)
5. **Settings**: render distance, ultra graphics on/off
6. **Evidence**: screenshots/video for visual bugs; `~/Library/Logs/DiagnosticReports` for crashes; the tail of `pebble test` if the engine seems wrong (expected: `457 passed, 0 failed`)

Even better than a report is a PR with the fix — the rest of this file tells you how to make one that lands.

## Setup

```bash
xcode-select --install        # Swift toolchain (Swift 6, macOS 14+ SDK)
git clone https://github.com/thebriangao/pebble.git && cd pebble
swift build                   # debug build, ~35s clean
swift test                    # focused unit/security regression tests
swift run -c release pebsmoke # the golden suite — must print "457 passed, 0 failed"
./pebble install              # optional: build + install the real app
```

There is no `.xcodeproj` and there never will be — the whole workflow is SwiftPM + the `./pebble` CLI. You can still open the folder in Xcode ("Open Package") if you want an IDE; just don't commit any generated project files.

## Before you open a PR

1. `swift build -c release` — clean, **zero warnings**. The codebase is warning-free and stays that way.
2. `swift test` — all focused unit/security regression tests pass.
3. `swift run -c release pebsmoke` (or `pebble test`) — **457/457**, from the repo root (goldens are found relative to cwd).
4. `swift scripts/sqlite-boundary-scan.swift --root "$PWD" --self-test` after any persistence, package, or source-inventory change. A manifest update requires a reviewed semantic API/capability diff; never regenerate it merely to turn the gate green.

The release preparation path runs a real AppKit text-entry stage after one warning-free release
build and before XCTest. It requires an unlocked interactive session and Accessibility/Input
Monitoring permission, but it performs zero clipboard/Paste operations. Run
`scripts/pipeline.sh --prepare-installed-signoff`; a correct install intentionally exits 75 with
`PENDING_INSTALLED_SIGNOFF`. The exact next steps are the TTY-only observer and finalizer documented
in README. Preserve clipboard contents before deliberately setting the fixed sentinel: the observer
never reads or restores clipboard bytes. Monotonic Keychain state—not its disposable JSON cache—binds
every committable repository file, real automated-gate logs/counts, frozen per-item screenshot/AX/
command evidence, release/package/install identity, distinct Designer attestation, and the exact
commit/push. There is no skip or noninteractive bypass.
5. For RPG/LAN-v6 storage changes, run `swift test --filter 'RPGLocalPreferenceStorageTests|RPGLocalPreferencesTests|LANV6ClientAuthorityCheckpointStorageTests|LANV6HostOwnerCheckpointStorageTests'` before the full suite. These named suites are the minimum persistence-contract gate, not a replacement for `swift test`.
6. For RPG UI/harness changes, run `swift test --filter 'RPGUIHarnessTests|RPGUIHarnessSourceTests|RPGScreenModelTests|RPGSemanticAccessibilityTests'`, then exercise the built executable with a semantic-summary case, a mixed-environment rejection, and an exclusive screenshot case. The harness must leave a fresh support home unchanged when `PEBBLE_SHOT` is absent.
7. If goldens changed, your PR description must justify **every** changed value (see below).
8. Keep diffs surgical. Match the style of the file you're in — this codebase has a consistent voice (compact, comment-where-it-matters), and drive-by reformatting makes review impossible.

Optional diagnostics: `./scripts/release-gate-adversarial-test.sh` may help investigate local
release-gate changes, but it is explicitly a `NON-AUTHORITATIVE DIAGNOSTIC`, not a prerequisite or
release gate. It is outside the authoritative sequence above and cannot replace the bounded security
scan, build, XCTest, 457-check smoke suite, installed human/VoiceOver/Designer proof, receipt,
pipeline, pre-push hook, or deployment verification.

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
- **Threading and persistence contract.** Chunks are built on the gen queue and published only via `adoptChunk` on main. AppKit/renderer state is main-thread-only. Saves go through the serial save queue. Persistence lock order is migration source 10 → save queue 11 → SaveDB/storage 12 → publication 20; never acquire downward or re-enter rank 12. SQLite, SQL, handles, and schema knowledge belong only to `PebbleStorage`; Core code uses the typed SaveDB adapter. Explicitly close owned databases after draining their save queues. The audio render thread owns the voice list; talk to it through the inbox. One-time registration uses `let`-initialized globals (dispatch_once), not boolean guards.
- **RPG preference persistence is CAS-only.** Local quick slots use the strict `PBLQS1` codec and an exact `WorldRecord.id`; callers must load the current revision/digest, submit a complete nine-slot replacement, and publish only the returned receipt. Never reuse the local façade for LAN identity or add a slot-only client-checkpoint write. The compiled client-checkpoint storage primitive has no Core adapter or production bootstrap until the reviewed Phase-2.5 canonical codecs and transition validator exist. Schema components are append-only legal prefixes; partial repair and blanket regolding are prohibited.
- **Player-row omission is full-row CAS-only.** Capture `getPlayerChecked`, submit the complete canonical candidate with `.absent` or the exact returned digest, and publish omission only from the committed receipt. Compatibility `putPlayer` remains serialized but is not evidence that a stale omission candidate committed.
- **GPU buffers the CPU rewrites per frame must be ring-buffered** (3 deep — see UICanvas, particles) or staged through blit encoders (see atlas animations). The renderer has no semaphore; it relies on the 3-drawable limit.
- **Version string** lives in one place: `PEBBLE_VERSION` (PebbleCore/Game/Saves.swift). Bump it there plus `packaging/Info.plist`.

## Testing tips

- `PEBBLE_AUTOLOAD=1 PEBBLE_NEWWORLD=12345 swift run -c release Pebble` — straight into a fresh world.
- `PEBBLE_CMD="/tp 0 120 0;/time set 1000" PEBBLE_SHOT="/tmp/shot.png@600"` — scripted screenshots.
- `PEBBLE_OPEN_SCREEN=templates PEBBLE_SHOT="/tmp/templates.png@240"` — open an allowlisted screen such as the template browser or creative inventory for UI smoke checks.
- `PEBBLE_RPG_UI_CASE=tab:warden:warden_guardian:skills PEBBLE_RPG_UI_SEMANTIC_SUMMARY=1` — run one isolated, no-world RPG UI fixture. Do not combine harness cases with ordinary `PEBBLE_` automation keys; the runtime rejects mixed mode.
- `PEBBLE_BOT=1` — runs the physics bot through the real input path and asserts walk/sprint/jump/fall-damage numbers.
- `PEBBLE_PHOTOBOOTH=1` (+ `PEBBLE_BOOTH_MOBS=cow,sheep` / `PEBBLE_BOOTH_BLOCKS=-`) — renders every mob/block to PNGs for visual review.
- `PEBBLE_PROF=1` — per-stage timings for load and tick.

## Scope & conduct

Pebble's approved in-app network surfaces are the loopback-only Ollama agent and the local-network LAN transport tracked in [LAN_MULTIPLAYER_PLAN.md](LAN_MULTIPLAYER_PLAN.md). LAN work must preserve the split where `PebbleCore/Net` owns bounded protocol models/validation and `Sources/Pebble/LANTransport.swift` owns Network.framework. New networking beyond that, including NAT traversal, relay servers, account systems, raw sockets, or cloud services, needs an issue and security plan first. Performance work is welcome but must keep goldens green and come with before/after numbers. Be a normal, decent person in issues and reviews; that's the whole code of conduct.

By contributing you agree your contributions are licensed under the repository's MIT license.

Pebble is an independent fan re-creation, not affiliated with Mojang Studios or Microsoft — see the README's [Disclaimer](README.md#disclaimer).
