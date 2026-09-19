# Prehistoric model gallery release-surface renewal

The prehistoric model gallery replaces the generic cuboid creature path with
validated source-authored faceted meshes and adds profile-safe pose routing for
prehistoric quadrupeds and pterosaurs. It changes only renderer and
presentation-model sources in `ElysiumCore` plus the AppKit renderer and photo
booth. It does not change persistence, SaveDB, storage API/capability manifests,
`GameCore`, `Player`, or text-input.

The warning-free release build was normalized using the verifier's disposable
copy `strip -S -x` procedure. The source security scan and SQLite boundary
scanner passed before these pins were renewed.

| Pin | Previous | Renewed |
| --- | --- | --- |
| `EXPECTED_CORE_OBJECT_SHA256` | `2e0921f07e97e975947c768267205b8bffe004feca7f5b467012da258028fc94` | `1a6059d09b63788ffe8bb955cc509115524ad0a2a9206ebac87cd355c7af6a67` |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `a9eb3393c93a97f26d59ea239349f7a5407e71422d32f80b6e5b442262916af1` | `1f9ba7793cba112026ff7c004fc11337996ae323cfbf17d0cc3b8de14bcea388` |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `fe5561b89197d0175ef53f27126169db3e928b9f3f9061bc8d9973cc89738f97` | `b77090afb36bbab576f0e87cc30360d480204c1374d2e4ccbba3b9b1b7138db7` |

The pre-existing reviewed storage, persistence, game-authority, capability, and
text-input pins are deliberately unchanged. The final release pipeline reruns
the release-surface verifier, full XCTest, the 491-check smoke suite, package,
installed-app identity, and code-signature checks after this renewal.
