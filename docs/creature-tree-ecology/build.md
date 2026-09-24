# Creature and tree ecology verification — September 24, 2026

## Scope and evidence

This change adds saved Daily/Alternate Days/Weekly dawn replenishment, a persisted
2:1 successful land-dinosaur birth sequence, and provenance-aware natural-tree
decay/seedling renewal. See the September 24 decision in `ARCHITECTURE.md` for
clock, habitat, backward compatibility, and Ancient Seas tradeoffs.

- Focused execution: **89 tests passed**, including 19 tree tests, production
  GameCore sleep/save/reload paths, ordinary and prehistoric spawn admission,
  refusal bounds, persisted diet sequence, Settings recovery, and Options UI.
- `swift build -c release`: warning-free. `swift run -c release elysmoke`:
  **491 passed, 0 failed** after the reviewed two-value golden change below.
- Real debug application: Options → World rendered the explanatory text and all
  three choices. Cycling worked; Alternate Days survived an application restart.
- Real isolated Lost World, seed `5366106`: a generated grove oak began with
  five logs and 57 leaves. Breaking its bottom log through production interaction
  started decay. Three actual bed sleeps (about 11,000 ecological ticks each)
  yielded respectively **1 log/30 leaves**, **0 logs/2 leaves**, then **0/0**.
  This demonstrates gradual removal across the expected ecological timescale;
  nearby hut blocks and grounded forest remained. Unit tests exercise the exact
  one-day deadline, seed drops,
  self-planting/growth, and preservation of player-placed wood independently.
- Native population observations mixed dawn refills with asynchronous initial
  chunk populations; they are not claimed as proof of the exact 2:1 sequence.
  That contract is established by deterministic production-spawner tests.

Focused logs were `/tmp/elysium-ecology-focused-final.log`,
`/tmp/elysium-tree-final-tests.log`, `/tmp/elysium-ecology-release-final.log`, and
`/tmp/elysium-ecology-smoke-final.log`. They are local execution artifacts, not
versioned build products. The automated release pipeline subsequently passed all
nine stages, including **2,577 actual XCTest cases**, **491 simulation checks**,
packaged native text entry, installation to `/Applications/Elysium.app`, and
strict signature/installed-identity verification. The pipeline's printed
`tests=6` is its last-target count, not the complete test total. The full log is
`/tmp/elysium-ecology-pipeline.log`. Installed executable SHA-256:
`24fe8c5221659bf4d987a48e0b3edef87527ea0b3a306e21d7231f56c9bf78e2`.
This receipt was updated after the pipeline with results and wording only; no
product code changed. The pre-push hook and remote parity remain separate
publication gates, not claims made in advance here.

## Intentional golden change

Only `goldens/entity-goldens.json` changes: `spawnCount` **19 → 0** and
`spawnH` **4268948809 → 2166136261** (the empty FNV hash). The existing fixture
invokes the old per-tick natural-spawn path at night (`dayTime = 13000`) without
an eligible dawn. Its 19 passive births are intentionally removed by scheduled
replenishment. Hostile spawn rules are unchanged. Required regold execution was
followed by a semantic comparison of every rewritten golden: no other values
changed. Unrelated serialization/order changes were restored before the final
491-check passing run.

## Reviewed release-surface renewal

`Saves.swift` adds bounded natural-tree chunk-tail codecs and optional dimension
ecology fields; `GameCore.swift` routes calendar/sleep/refill and save restoration.
Neither changes the StorageEngine SQL facade, approved capability owners,
checked-player getter/CAS spans, or storage public API. Renewing the Saves AST
binding reflects that reviewed domain-codec change, not expanded authority.

| Pin | Previous SHA-256 | New SHA-256 |
| --- | --- | --- |
| Saves source | `5efd5a22b43aeb04760462c8a3fd3dfae5c49ff61b7271cc30ec981b86b9786f` | `21c80f8babbb2423a2bd65a2f5a3ae097ae5b46f4f9612c167904c2b363a3822` |
| GameCore source | `2f5ad0d1f44691e61b0cd1d528d242fbb30f9a658d486ef5f1c5fabdd183a113` | `63ced7f24fe9998202f54ec1386da3bd7944f7a09fce38bb4be694750eedf79d` |
| Saves normalized AST | `02d792abb67d5d2aabc4072c8d8a27664d9ede83367c947862dbd94162d91500` | `e7b213f021d94bb72a353613c40768563dbb159e3391669ab605c795508e858e` |
| Core capability manifest | `2c14c21b1045d414dd7b4931c63db6074df16ffe0cdbf2f29b1c6cd5abcd169e` | `377ee1d5aced0ca72770b6e6e28647ab29397e5a9f56a0328068fecb62b5dffb` |
| ElysiumCore.o | `36c132d622886299acc1efb57bf1291c688042cf50a0c71989237f754e5b7fa6` | `6ac3ca7edcfe7cdf4ac0ed5a69e43f32221a27a8c37a1b19b71d422a6b086fbc` |
| Elysium | `c16333c4b11d8fd11a7f816c2ce0b48d0d12e3ed8d6318872440b8c1ab05c55f` | `db2d0e79e5e5a720920e92311b002aaa478c5f3f2ed32c62f4477a114693de03` |
| elysmoke | `90c0a7d6b001a1b3a1b505b2b6dc15f4ca20afee9a61ea92a4f3d0205d56793b` | `450f4f5d43c1ad67dca18615db8f2443670309b1ef6f7f917cffefe32c49d5b1` |

Artifact pins use copies from `.build/out/Products/Release`, normalized with
`xcrun strip -S -x`, then `shasum -a 256`; original build artifacts were not
stripped or modified. The existing release-surface verifier uses this same
normalization. StorageEngine, Player, text-input source/API pins are unchanged.
Normalized ElysiumStorage.o remains
`43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8`;
ElysiumTextInput.o remains
`0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3`.

Compatibility: old full saved chunks without natural-tree provenance are
protected. Their unmarked wood is not retroactively decayed; newly generated
chunks and newly grown trees participate. Creature scheduling does apply to
existing maps.
