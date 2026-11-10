# Elysium 1.4.5 release-pin receipt

Version 1.4.5 fixes two faults in object templates. The ground filled in under a pasted object is
now always plain natural ground and never a copy of the block beside the gap, and template undo
gives back only what the placement itself removed. `CHANGELOG.md` has the player-visible summary
and `ARCHITECTURE.md` records the decision ("support fill is plain ground, and undo returns what
the paste removed").

Values from the final warning-free `swift build -c release` on November 10, 2026 (Swift 6.4.2,
swiftlang-6.4.2.1.9), using the gate's `strip -S -x` normalization.

| Surface | 1.4.4 pin | 1.4.5 pin |
| --- | --- | --- |
| `Saves.swift` | `5af166872a3cbcff3fd104df1fd676e04196eba9776794960426c9f14df0eea6` | `6c92e7d66ea3f889f5b708a4afb65a0ca53145de3099104a3609e768ab24e7b9` |
| `Saves.swift` compiler-AST inventory | `e3628e0a75528d947bfe9cdb7ab13690798b07402c3ed03c7e3775cd8344066a` | `49638c93ad8be505ee72de0d8bca03306f2d686ab073bda462f8e54e7ec86d42` |
| storage-capability manifest | `3e53ff8a0b05c23c138f3e0be361719e6fb2bab683e97d78a543ee7185acf87e` | `b54aca56ef277bab6db086db2e46dcc591726d227fe6ff27baaad61cea2a72a0` |
| normalized `ElysiumCore.o` | `4d8f9e57132ed68773a3df5c872c7d1b7ce10596b7a614415108f2bf67d0dbc0` | `244f6a529f5d647d71ece10d845164c2f9e3d9f729e791420a3f685a541f354e` |
| normalized `Elysium` | `9baa8ad25a46aeb6b37549962407e2b9166a83277b6bb4dfcfeecd22778f47da` | `1741e80cb4adb92e75d932f56a078a0a8d659f5597b60a3bfbd458c48c66e290` |
| normalized `elysmoke` | `9e6bedc4c96c0a0d64c3b1524a3f8e9ea6427bfebba86b0d3c84ecc8fc6ccda4` | `9c32bd123cee470e86cc8723973877dff4f244f39e080616efb8956a76841618` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift`, `Player.swift`, the
storage source, API manifest and object, and the text-input source and object are unchanged. The
Core object moves for `TemplateSupportFill.swift`, `TemplateUndoLedger.swift` and the single
placement implementation in `Templates.swift`; both products only relink it. The boundary scan
now covers 292 production Swift files (two new). elysmoke stays at 491 passing checks with no
golden regenerated; it does not exercise templates.
