# Elysium 1.5.1 release-pin receipt

Version 1.5.1 keeps the LAN host's copy of a guest's inventory exact when messages cross. The
copy is the guest's latest snapshot plus every grant that snapshot does not include; grants
follow stacks and no longer write slots; a container edit the host refuses is handed back; and a
guest's chest screen no longer has honest moves refused. `CHANGELOG.md` has the player-visible
summary and `ARCHITECTURE.md` records the decision ("the host's copy of a guest's inventory
follows every grant") with what four reviews found.

Values from the final warning-free `swift build -c release` on November 11, 2026 (Swift 6.4.2,
swiftlang-6.4.2.1.9), using the gate's `strip -S -x` normalization.

| Surface | 1.5.0 pin | 1.5.1 pin |
| --- | --- | --- |
| `Saves.swift` | `5efb59a68a9e3272f07d2f55cd74a206790418884b0976399e08c13446589f0a` | `ad5b30230fc26f5ce560d6f4f19b194af653b333c9a7d196f0f2c1ad1f4a3c8b` |
| `Saves.swift` compiler-AST inventory | `41e4f20892bdead4a6516063a8ae11b85b7c9b0573b33ea07725c57c5d57e9ed` | `b21dcba96962f92c679a160658b4fdd12ec8d36ee3c5cab250e3d38a0bdf8980` |
| storage-capability manifest | `a2ada9b26583ce9e779d7474ae28967838c8d178ee109e90615287fd31637e21` | `d7460949f9196af124019393d8e659f6e1cf4d542f27e1f8ae86cd0627a30848` |
| `GameCore.swift` | `cd7c28d5708ae39d826c7ee6e87923c9fe3d2e15a74f148d70565d4aa7f30bdb` | `26842de4ba112155857c4581680002d97e6634b33acce82681c314f91c5c9952` |
| normalized `ElysiumCore.o` | `89c980f228a61f51c6fec5f9d754cb0aaef333da2fa05719c6dfc8509f02e073` | `71f838aa12382af6e221157f1db1adc18602f939ba688233891c840dc6f0ce26` |
| normalized `Elysium` | `2497582c4b572f414da1ce017d26c47a254f999b6df324a2b9712658b7f5d737` | `1204aac25fa10e5c4124da7deeb15a8fbd5b8cad57989ef515251785874b9845` |
| normalized `elysmoke` | `a106464b5597d6e24e59cdaf8526cebeb00e41bfcc7df98a3974f661ed3450d7` | `57df2019305dfc044293edf0f88606e7895714c334e66a60dc414c92b2ff83e2` |

`Saves.swift` changes only the `ELYSIUM_VERSION` literal. `GameCore.swift` loses 37 lines (28
added, 65 removed), all on the LAN guest's side: `applyLANGrant` has an open screen hand back its
stacks before the grant counts as applied and applies the grant with `lanApply`,
`captureLANContainerEdit` names the last grant applied, the client publishes before a mirrored
container opens and not while one is open, `applyLANHostReplicationBatch` leaves a change the
guest has not sent yet alone and moves the container revision only when a host snapshot of the
open container was applied, and `performLANClientToss` only asks the host. `GameHost` gains
`returnStacksHeldByScreens`. The bodies are in the new `LANClientContainers.swift` and
`LANGuestInventoryCopy.swift`. The checked-player getter and compare-and-swap callers, their
counts and their spans are unchanged. `Player.swift`, the storage source, API manifest and object,
and the text-input source and object are byte-identical.

The Core object moves for two new files (`LANGuestInventoryCopy.swift`,
`LANClientContainers.swift`), the snapshot helper and the peer's kept grants in
`LANReplication.swift` (`enqueueGrant` and the pickup moved out of it, 142 lines fewer),
payment and refund by grant alone (`LANTemplatePayment.swift`, `LANHostTemplateJobs.swift`) and
two wire shapes in `LANMultiplayer.swift`: an inventory grant carries stack changes
(`changes`) and no longer `slots` or `clearedSlots`, and a container edit carries the last grant
the guest applied (`appliedGrantID`). Each new field decodes to a safe default when absent, and
the exact-version handshake keeps a 1.5.0 binary out in any case. The `Elysium` product also
changes `LANTransport.swift` (ghost changes go out as grants; a refused or dropped container edit
is answered with the containers and the way back; a publish dropped during catch-up is noted),
`ScreensM.swift` (no edit while a stack is on the cursor) and `main.swift` (a screen hands back
what it holds); `elysmoke` only relinks Core. Atrium is still at `19eb940`. The boundary scan
covers 304 production Swift files (two new). elysmoke stays at 491 passing checks with no golden
regenerated; it does not exercise the LAN transport.

Evidence beyond the gates: a host and a guest ran as two processes on one Mac on the final
code. The guest took stacks out of a chest and put them in with the cursor (six edits, all
accepted), had one deposit refused by the host (its planks were back in its inventory and its
chest showed what the host held), placed a block, threw an item, and rejoined holding slot for
slot what it held. Four reviews by sessions that did not write the code ran before this release;
`ARCHITECTURE.md` lists what they found.
