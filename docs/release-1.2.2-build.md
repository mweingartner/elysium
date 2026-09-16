# Elysium 1.2.2 release-pin receipt

Version 1.2.2 replaces selectable classes with usage-based Mining, Melee,
Ranged, and Crafting skill trees. It also adds the host-timed ordinary-bow LAN
intent needed to keep ranged use authoritative, so exact-version LAN
compatibility advances from 1.2.1 to 1.2.2.

The values below came from a warning-free `swift build -c release` on
September 16, 2026. Artifact values use the release-surface gate's
disposable-copy normalization (`strip -S -x`), rather than raw debug-symbol
bytes.

| Surface | SHA-256 |
| --- | --- |
| `Saves.swift` | `c9e0c55b400444f1262f3ff0c6f63fdcd4e5ff95e40e4d87f7dbee919c58a2b1` |
| `Saves.swift` compiler-AST inventory | `f3991fdefe51070cd883779520475f85abcb59b4d4cac094edf044e9cdc26525` |
| storage-capability manifest | `74174593860b79cca66bec942e05cfd707276281517d6739a8ce9db7221becd8` |
| `GameCore.swift` | `9aae5e19b00304145157b2a84ccd81dbf7dcb6effc0092d1c1e6952116a28f45` |
| `Player.swift` | `1f4dff72450f80e20d675bf645c01700ac6962375b331d0cd69d2764b50eaf08` |
| normalized `ElysiumCore.o` | `fe800a9ece392f1917ce9b3fcf749f8ccaa4f179a2ad954af4611ce9447c29e9` |
| normalized `Elysium` | `553559e3ab03ca61d4b2c16e05d909e5796cff2352c1679f8bb9a3a96dcd8758` |
| normalized `elysmoke` | `0a13660761c0e273359a089375ccff8bcba6589722a4af7cf79f3b937022e0cd` |

The reviewed storage engine/API, text-input source/object, and storage object
retain their prior pins. The compiler-AST inventory renews solely because
`Saves.swift` owns exact LAN-version compatibility. The release gate continues
to check the declarations, caller boundaries, and normalized artifacts
independently.
