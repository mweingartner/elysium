# Elysium 1.4.6 release-pin receipt

Version 1.4.6 does two things for LAN play. A host no longer crashes when a guest joins (the join
handshake read the script-sound catalog off the main thread; broken since 1.3.0). And a guest can
place and undo object templates in the host's world: the guest sends its own template with the
place intent, and the host builds every block entity itself. `CHANGELOG.md` has the player-visible
summary and `ARCHITECTURE.md` records the decision ("a guest's paste carries its own template").

Values from the final warning-free `swift build -c release` on November 10, 2026 (Swift 6.4.2,
swiftlang-6.4.2.1.9), using the gate's `strip -S -x` normalization.

| Surface | 1.4.5 pin | 1.4.6 pin |
| --- | --- | --- |
| `Saves.swift` | `6c92e7d66ea3f889f5b708a4afb65a0ca53145de3099104a3609e768ab24e7b9` | `267afa1690f7387c38184e8afeee40f296d2286f28429afa23988e7d762edc0a` |
| `Saves.swift` compiler-AST inventory | `49638c93ad8be505ee72de0d8bca03306f2d686ab073bda462f8e54e7ec86d42` | `996d346490d1456cd4beda4256b172f03b0b4576cd39a54d8685822a0a7f36e9` |
| storage-capability manifest | `b54aca56ef277bab6db086db2e46dcc591726d227fe6ff27baaad61cea2a72a0` | `ca9c270932ba8854d9fc6ac652a5fe3ce616b30086cfb4cb3efb27f6e761be20` |
| `GameCore.swift` | `a3df1d3ae3f1039361b3b59205ec7a6cb16832dc1d916b4002b305ae14b58d6d` | `8c3a62b5c489da76703cb96638885b32c4d68f55a7b44cd1711f434cc2ed9ae5` |
| normalized `ElysiumCore.o` | `244f6a529f5d647d71ece10d845164c2f9e3d9f729e791420a3f685a541f354e` | `4ffe638b66f0758b34bec0d48ae3ef700345465c35f853a04a44d5e67fcf8e71` |
| normalized `Elysium` | `1741e80cb4adb92e75d932f56a078a0a8d659f5597b60a3bfbd458c48c66e290` | `fa83db5f9b0ae7366a18ea6fb6c61670b9e2c3d29cf0ebdcabf31c32e1872d26` |
| normalized `elysmoke` | `9c32bd123cee470e86cc8723973877dff4f244f39e080616efb8956a76841618` | `d034d52fca345886ad2b0cbf613e92ece0a90c2bcd559d5ebbde87c88553923c` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift` changes for the guest's
side of a paste: on a LAN-client world `beginTemplatePlacement`, `commitTemplatePlacement` and
`undoLastTemplatePlacement` hand over to `LANClientTemplates.swift`, the client tick counts down an
unanswered request, and the local placement, progress and undo texts come from the functions the
host's messages to a guest use. The checked-player getter and compare-and-swap callers, their
counts and their spans are unchanged. `Player.swift`, the storage source, API manifest and object,
and the text-input source and object are byte-identical.

The Core object moves for `LANTemplateTransfer.swift`, `LANClientTemplates.swift`,
`applyTemplateIntent` and its progress reports in `LANReplication.swift`, the event kinds and
rate-limit category in `LANMultiplayer.swift`, `placementBlockEntity` in `Interact.swift`, the
helpers opened to the module in `Templates.swift`, and the version literal. The `Elysium` product
also changes `LANTransport.swift` (the join fix, the guest's intent handler and event routing, the
host's answers) and the debug-only `template.arm` and `template.undo_last` operations, which are
compiled out of the release binary; `elysmoke` only relinks Core. Atrium is still at `19eb940`.
The boundary scan covers 294 production Swift files (two new). elysmoke stays at 491 passing
checks with no golden regenerated; it does not exercise templates or the LAN transport.
