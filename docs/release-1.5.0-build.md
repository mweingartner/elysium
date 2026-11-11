# Elysium 1.5.0 release-pin receipt

Version 1.5.0 makes a survival paste of an object template cost the items that place its blocks.
The player at the keyboard pays from the inventory and then from the containers crafting already
pools within 50 blocks; a LAN guest pays from what it carries, charged by the host. Undo pays back
what still stands. Along the way it fixes faults the work and its reviews found in older code:
doors, beds and tall plants are handled as one block on two cells everywhere, and a block whose
metadata names a face that does not exist no longer ends the game. `CHANGELOG.md` has the
player-visible summary and `ARCHITECTURE.md` records the decision ("a survival paste costs the
items that place its blocks").

Values from the final warning-free `swift build -c release` on November 10, 2026 (Swift 6.4.2,
swiftlang-6.4.2.1.9), using the gate's `strip -S -x` normalization.

| Surface | 1.4.6 pin | 1.5.0 pin |
| --- | --- | --- |
| `Saves.swift` | `267afa1690f7387c38184e8afeee40f296d2286f28429afa23988e7d762edc0a` | `5efb59a68a9e3272f07d2f55cd74a206790418884b0976399e08c13446589f0a` |
| `Saves.swift` compiler-AST inventory | `996d346490d1456cd4beda4256b172f03b0b4576cd39a54d8685822a0a7f36e9` | `41e4f20892bdead4a6516063a8ae11b85b7c9b0573b33ea07725c57c5d57e9ed` |
| storage-capability manifest | `ca9c270932ba8854d9fc6ac652a5fe3ce616b30086cfb4cb3efb27f6e761be20` | `a2ada9b26583ce9e779d7474ae28967838c8d178ee109e90615287fd31637e21` |
| `GameCore.swift` | `8c3a62b5c489da76703cb96638885b32c4d68f55a7b44cd1711f434cc2ed9ae5` | `cd7c28d5708ae39d826c7ee6e87923c9fe3d2e15a74f148d70565d4aa7f30bdb` |
| normalized `ElysiumCore.o` | `4ffe638b66f0758b34bec0d48ae3ef700345465c35f853a04a44d5e67fcf8e71` | `89c980f228a61f51c6fec5f9d754cb0aaef333da2fa05719c6dfc8509f02e073` |
| normalized `Elysium` | `fa83db5f9b0ae7366a18ea6fb6c61670b9e2c3d29cf0ebdcabf31c32e1872d26` | `2497582c4b572f414da1ce017d26c47a254f999b6df324a2b9712658b7f5d737` |
| normalized `elysmoke` | `d034d52fca345886ad2b0cbf613e92ece0a90c2bcd559d5ebbde87c88553923c` | `a106464b5597d6e24e59cdaf8526cebeb00e41bfcc7df98a3974f661ed3450d7` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift` gains 10 lines (16
added, 6 removed): `beginTemplatePlacement` checks the cost when the preview is armed,
`commitTemplatePlacement` builds the job from the survival form of the template and charges it
before installing it, `finishTemplatePlacementJob` settles and reports the materials, and
`undoLastTemplatePlacement` asks for the refund before it restores. For a LAN guest,
`applyLANGrant` removes what a grant's `take` names and lets the next tick publish,
`publishLANInventoryNow` publishes before a template request, and `lanLocalInventoryRevision` and
`lanLastAppliedGrantID` can be read outside the type. The bodies are in the new
`GameCore+TemplateMaterials.swift`. The checked-player getter and compare-and-swap callers, their
counts and their spans are unchanged. `Player.swift`, the storage source, API manifest and object,
and the text-input source and object are byte-identical.

The Core object moves for seven new files (`TemplateMaterials.swift`, `TemplateHandPlacement.swift`,
`TemplateMaterialLedger.swift`, `TwoCellBlocks.swift`, `GameCore+TemplateMaterials.swift`,
`LANHostTemplateJobs.swift`, which is the host's template jobs moved out of `LANReplication.swift`,
and `LANTemplatePayment.swift`), the callers of the two-cell rules in `Interact.swift`,
`Templates.swift`, `Redstone.swift` and `BlockRegistry.swift`, the bounded facing in `Dirs.swift`,
`BlockEntities.swift` and `Redstone.swift`, the job's receipt, unplaced lists, dirt fill and
written-block count, the crafting pool opened to the module, and three wire shapes: the take in an
inventory grant, the grant id in an inventory update, and the grant id and inventory revision in a
template intent. Each new field decodes to a safe default when absent, and the exact-version
handshake keeps a 1.4.6 binary out in any case. The `Elysium` product also adds
`TemplateMaterialsPanel.swift` and its hook in `ScreensM.swift`, and changes `LANTransport.swift`
(the payment grant goes out ahead of the accepted event; an inventory publish carries the last
grant applied); `elysmoke` only relinks Core. Atrium is still at `19eb940`. The boundary scan
covers 302 production Swift files (eight new). elysmoke stays at 491 passing checks with no golden
regenerated; it does not exercise templates or the LAN transport.

Evidence beyond the gates: the paste, a shortage, an unplaceable object and undo were run in the
debug app in a survival world with materials split between the inventory and a chest 20 blocks
away. A host and a guest ran as two processes on one Mac: the guest mined its materials, was
refused by the host for dirt it did not carry, pasted, rejoined holding what the host's copy said
it should, and was paid back by undo. Two independent reviews of the feature and one of the fixes
ran before this release; `ARCHITECTURE.md` lists what they found.
