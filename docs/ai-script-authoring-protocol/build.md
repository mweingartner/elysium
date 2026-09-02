# AI script-authoring protocol release-pin receipt

This receipt records the narrow Elysium application-product pin renewal for the built-in `/ai`
Lua creation protocol and the proposal-only Script AI prompt hardening. The changed production
sources are all under `Sources/Elysium/`; no ElysiumCore, storage, save, player, text-input, or
capability-manifest source changed.

The candidate came from one warning-free `swift build -c release` on 2026-09-02. The product was
copied to a disposable directory, made writable, normalized with the `xcrun --find strip` result
using `strip -S -x`, then hashed with `shasum -a 256`, exactly as
`scripts/verify-elysium-storage-release-surface.sh` does. Before renewal, that verifier passed every
unchanged source/object check and stopped at the expected Elysium product-hash boundary.

| Pin | Old SHA-256 | New SHA-256 | Reviewed reason |
| --- | --- | --- | --- |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `3d12ad0a93d87227e7585c0a40c82d3aea55dde09a07f3894ebf11c92f4ee7ad` | `1e75abe9fa1e3e959b6ca2c31e5a45cccea458aabf1f8288f89af233f7a898e5` | The Elysium app now supplies exact Module/Handler `attach_script` shapes and an inspect-before-mutate workflow, nonce-fences world/editor data, refuses partial-context selection replacement, prioritizes current-target members, limits furnace facts to live furnace-family blocks, expands editor context to 16K, and labels the panel's single-turn behavior. |

The following reviewed pins passed before the expected product-only failure and were deliberately
not renewed:

- `EXPECTED_STORAGE_SOURCE_SHA256`
- `EXPECTED_STORAGE_API_SHA256`
- `EXPECTED_STORAGE_OBJECT_SHA256`
- `EXPECTED_SAVES_SOURCE_SHA256`
- `EXPECTED_GAME_CORE_SOURCE_SHA256`
- `EXPECTED_PLAYER_SOURCE_SHA256`
- `EXPECTED_CORE_CAPABILITY_SHA256`
- `EXPECTED_TEXT_INPUT_SOURCE_SHA256`
- `EXPECTED_TEXT_INPUT_OBJECT_SHA256`
- `EXPECTED_CORE_OBJECT_SHA256`
- `EXPECTED_SMOKE_PRODUCT_SHA256`

Focused pre-renewal evidence was `bash scripts/security-scan.sh` plus 40 selected editor/AI tests,
all passing. The first full pipeline then exposed a reserved source-token spelling in two prompt
section delimiters. After renaming only that delimiter, all 199 `ElysiumScriptTests` and both
tool-loop prompt tests passed, and a second warning-free release build produced the final hash above.
The full nine-stage production pipeline is rerun from the beginning after this reviewed renewal; its
package, install, executable-identity, and code-signature checks remain authoritative.
