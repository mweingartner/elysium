# Script AI model-readiness release-pin receipt

## Current product contract

Opening the native Script Editor in Manual or On Idle mode warms the exact persisted local model
through Ollama's empty, non-streaming `/api/generate` operation even when the Script AI panel is
closed. The request carries no script source, authoring prompt, world data, or generation tools. An
editor generation request waits for the shared warmup and retries failed readiness in that same
explicit interaction; Off remains a no-discovery, no-warmup, no-generation boundary.

Toolbar/menu/hotkey and On Idle results remain ghost text requiring acceptance. The panel separates
**Ask**, which is always transcript-only, from **Write Code**, which may replace only the captured
selection as one normal undoable edit. Any draft, selection, mode, event, model, or authoring-context
change makes the response stale. Write Code requires a local authoritative runtime and accepts only
safe, mode-correct Lua through the compiler, blocking diagnostics, conservative lexical
unresolved-global/call-target/callback and dynamic-`_ENV` checks, and mutation-free validation.
Module output is module/callback source; Handler
output is only the selected event body using implicit `ev`. A complete fenced response, or a
complete unfenced response followed only by clearly explanatory non-Lua text, may insert the
validated code while retaining the full reply and reporting omitted text. Prose-only, code-like
exterior or suffix text, unsafe text, and invalid output remain transcript/refusal state, and no
proposal path saves, attaches, runs, trusts, enables scripts, or mutates the world. Warmup and
generation both request a 30-minute keep-alive; source-bearing
generation uses a 90-second request deadline and 120-second resource cap. A required source-free
`/api/show` preflight rejects remote-backed aliases before script text is sent. Dry-run validation
does not consume the live scheduler/RNG ordinal.

## Current editor-open readiness and insertion renewal (2026-09-01)

The reviewed release pins were renewed only after the editor-open readiness, first-request retry,
explicit Ask/Write routing, mode-aware insertion, local-model provenance, generated-Lua validation,
and mutation-free dry-run changes were complete. The same source snapshot passed:

- 59 focused Script AI, editor lifecycle, authoring-model, dry-run RNG, settings, and
  test-profile-isolation tests;
- `bash scripts/security-scan.sh`, including 10,000 coordinator mutations and inspection of all
  242 production Swift files;
- a warning-free `swift build -c release` in 152.75 seconds;
- the complete `swift test` matrix: 2,221 tests across six XCTest products, zero failures; and
- `swift run -c release elysmoke`: 491 checks passed, zero failed.

The artifact changes were normalized with the same `strip -S -x` procedure used by the release
surface verifier. The immediate pre-renewal to reviewed-pin transitions were:

- `EXPECTED_CORE_OBJECT_SHA256`:
  `426fc12b74e7cf55ac23c7f85adfff6094d7d97955f5139cb5b0b1c07224ea3a` to
  `450a1c3cf1602cdbb793ecd48d1e56722539508ac3f626f566c7971a18528a36`;
- `EXPECTED_ELYSIUM_PRODUCT_SHA256`:
  `8c94c8eaf361a1a1e07a4dde7acdc53de6485a25574a741a69ec6a3db6e23a3e` to
  `3d12ad0a93d87227e7585c0a40c82d3aea55dde09a07f3894ebf11c92f4ee7ad`; and
- `EXPECTED_SMOKE_PRODUCT_SHA256`:
  `53c8155cf583e877ecb1d9df8794fe900d3e0b7e0958685772c939926189f9d3` to
  `61edb5e5e7a935375307277ad71b6b0f10358021389fc6daef0eff883193ffe2`.

The full nine-stage release pipeline remains the authority for packaging, replacement of
`/Applications/Elysium.app`, installed executable identity, resources, and codesign. It takes its
own immutable source snapshot after this receipt.

The authoring-model XCTest fixture also uses a unique `/private/tmp` settings store. Its regression
reloads the persisted fixture model from that store, preventing release and pre-push tests from
replacing the user's selected Ollama model.

## Historical panel-visible preload renewal (2026-08-28)

The original change modified only the Elysium application target. Showing the Script AI panel
refreshed the installed local-model list and preloaded the exact persisted local model through the
same empty request. The release evidence below records that historical panel-visible preload; it is
not by itself release evidence for the later editor-open readiness and automatic-draft-insertion
follow-up.

The release pipeline passed source security and its warning-free optimized build on 2026-08-28,
then stopped at the expected Elysium product-hash boundary. The pin was renewed narrowly:

- `EXPECTED_ELYSIUM_PRODUCT_SHA256`
  - old: `78a1d49fc33e00b0382f42ba9b837e04134f66cb2bdc11c5850ce9b810565de5`
  - new: `5fece49d480bd5e9b6b84ef5a37ba1ea8fa60d20760ff9297e37854986e7d075`

The candidate hashes came from the same warning-free release artifacts. Each was copied to a
disposable directory, made writable, normalized with the `xcrun --find strip` result using
`strip -S -x`, and hashed with `shasum -a 256`, exactly as
`scripts/verify-elysium-storage-release-surface.sh` does.

The following reviewed artifact pins were recomputed and remained byte-identical:

- `EXPECTED_STORAGE_OBJECT_SHA256`:
  `33fb1578d8262a4044ba42ccb1fc7b67e8dfac2589133ab2ff415b5a5d71326b`
- `EXPECTED_CORE_OBJECT_SHA256`:
  `6f2c08d5d9f5b1371fcaa08eaa588b18bb7c311e7943f66f31e57753bf4eb809`
- `EXPECTED_TEXT_INPUT_OBJECT_SHA256`:
  `ca500f11c671c45b6a0648962bed37881a9adff2a6491632e7d655a50ed80efc`
- `EXPECTED_SMOKE_PRODUCT_SHA256`:
  `71680aec7314a60713b192f253b3e7cf6b379f265221826a6838354a6e88f3e8`

All reviewed storage/Core/text-input source and capability-manifest pins also remain untouched.
Focused final-tree verification before renewal was four `ScriptEditorAIPanelTests`, all passing.
