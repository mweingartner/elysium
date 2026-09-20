# Local-world retention and fence-gate release build

The native app now discards local worlds through the checked saved-world
authority at launch and session end. LAN stops synchronously at the retiring
world boundary, and a captured host-world ID prevents guest records from
being persisted to a replacement world. Historical host-guest records with no
parent world are removed only after the checked world snapshot succeeds. The
cleanup first caps the complete host-peer collection at 256 rows and refuses a
larger collection atomically, so the one-session launch path never performs an
unbounded scan or partial deletion. Fence gates use the canonical eight-piece
model for every facing, open state, and wall state.

## Release evidence

- Warning-free build: `scripts/prepush-release-build.sh` on 2026-09-20.
- Artifact normalization: disposable copies from
  `.build/out/Products/Release`, processed with `strip -S -x` before SHA-256.
- Focused verification: `FenceGateRenderingTests` (6), `LANReplicationTests`
  (111), `LocalWorldRetentionTests` (5), `SaveDBTests` (16),
  `SavedWorldBatchDeleteTests` (29), `LANWorldSessionLifecycleTests` (4),
  and the SQLite boundary self-test.

## Renewed release-surface pins

| Pin | Previous | Renewed | Reason |
| --- | --- | --- | --- |
| `EXPECTED_STORAGE_SOURCE_SHA256` | `c6203f8337d1c88b986ec82b65968908566a5ad51e32f76a34c4404a31801b11` | `d67282f8ca7d5a9f5f3530803ee2170f67ba6e9868ccd64e1f8c26ae52337eee` | Bounded orphan cleanup preflight and all-or-nothing sentinel. |
| `EXPECTED_STORAGE_API_SHA256` | `ab2b529d974b8eef055d62e8f764447b15f2852eb1106b193c446e4145468545` | `26c1e555f400d21e23a45945a472a201a89282cd2247c0221c7a2c46092fe98f` | Freezes the reviewed public cleanup declaration and its documentation. |
| `EXPECTED_STORAGE_OBJECT_SHA256` | `138836203a79d064a792d877e32feb79557b6b4562e735897970b1e0f4c9c691` | `39306a13a5dc57f1e30b9b909e412ee64d917f6772e5e64bf28133b9f95b365b` | Storage implementation relink. |
| `EXPECTED_SAVES_SOURCE_SHA256` | `5efd5a22b43aeb04760462c8a3fd3dfae5c49ff61b7271cc30ec981b86b9786f` | `26b1d02152bcad3cf9dfa8fd601d2afb52551d8f7a3bae77b79e6151235a2104` | Narrow Core adapter for the cleanup API. |
| `EXPECTED_CORE_CAPABILITY_SHA256` | `2c14c21b1045d414dd7b4931c63db6074df16ffe0cdbf2f29b1c6cd5abcd169e` | `2650fd395216d9bdcb42c7003801b17556aa8a49f2b8fa3a828c9e7cdb31e033` | Reviewed `Saves.swift` AST inventory. |
| `EXPECTED_GAME_CORE_SOURCE_SHA256` | `faf9fdafdc7beb41304f40406aaaa1413b112d3cf313acd019784c80e8da3610` | `ce596f0286a01150e6f30f53026453398f3f41968d294dc3748e91f9b393d1e7` | Checked snapshot and bounded cleanup ordering. |
| `EXPECTED_CORE_OBJECT_SHA256` | `e4b98637401a72eac6019c44a93cbcefc0991c444f3508d8688dc095908eee82` | `5b22e34820bd29e68c9560362aab9d9e3c4e67c652c1a529f5c05da8f7aca7a8` | Core gate, retention, storage, and LAN changes. |
| `EXPECTED_ELYSIUM_PRODUCT_SHA256` | `e011a9494cc59946c3927a9475c1b1cc7cd754e02df1b44d8f0c37429e6c5e53` | `3694f9e0828ebc6455cb864ffe14a15bb2170b6f0813ddcd8afa76e91ff7eca5` | Linked native app changes. |
| `EXPECTED_SMOKE_PRODUCT_SHA256` | `eeba66c7c71ee631e0b69a6a019f8f7480035fb0229643214efad20298fcfdf9` | `2c37a8725e9b76bdf3a05d171ca89d2e1c8ab3bb0dc12df354d24023852d2fdd` | Linked Core change. |

Player and text-input release surfaces remain byte-identical.
