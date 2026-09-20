# Prehistoric audio and XP release-surface renewal

This change adds source-authored, species-specific procedural sounds for every
prehistoric lifecycle, combat, controller-action, and movement cue. It also
maps prehistoric player-kill XP orbs to configured combat difficulty rather
than visual body length. The Core changes are confined to prehistoric entity
presentation routing and the generic attack-sound seam; application changes
are confined to the existing procedural audio registry.

The warning-free release build was normalized with the release verifier's
disposable-copy `strip -S -x` procedure. Only `ElysiumCore.o` and the products
that link it require renewal. Storage, persistence, GameCore, Player,
capability, and text-input source/object pins remain unchanged.

| Pin | Previous | Renewed |
| --- | --- | --- |
| `EXPECTED_CORE_OBJECT_SHA256` | `1a6059d09b63788ffe8bb955cc509115524ad0a2a9206ebac87cd355c7af6a67` | `e850076161f23403841dab86775c803ab77a1d2e0cfdee3394dcab49c72ce9b7` |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `1f9ba7793cba112026ff7c004fc11337996ae323cfbf17d0cc3b8de14bcea388` | `67bcc242494b2bbaf1a9758bb28a72f456f121c874214b65721f32c9c14b63f3` |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `b77090afb36bbab576f0e87cc30360d480204c1374d2e4ccbba3b9b1b7138db7` | `efff5b717b6430021f0b02b175b5a085d11061eba737ab44b83b31927fe77361` |

The final release pipeline reruns source-security, warning-free production
build, storage-surface and binary checks, full XCTest, the 491-check smoke
suite, packaging, installed-app identity, and code-signature verification.
