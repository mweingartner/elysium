# Dinosaur population and branch reconciliation — September 27, 2026

## Decision and delivered behavior

The retired `codex/native-ray-detail` branch had no exclusive commits: its
`2459587` tip is an ancestor of main `64a854b`. Review used three repository
evidence sources: Git ancestry/diff, the accepted `48380d9` commit, and the
renderer verification record in `docs/ray-traced-worlds/build.md`. The accepted
renderer already solves the water/detail problem, and that record rejected
opacity-split geometry as slower. The remaining uncommitted experiment lacks
measured benefit against current main. Retire it, retain main's renderer, and
preserve a recovery patch outside the repository. No experimental renderer code
is included in this change.

All dinosaur-map revisions now use 56% initial land-pack probability (was 28%),
and local dawn caps of 48 land / 30 air / 10 water creatures (was 18/15/5).
Herbivore pods contain 8–10 same-species members. Bounded placement retries stage
a pod before publication; fewer than eight safe sites produce no pod. Generated
pods are checked again at chunk adoption. Ordinary maps retain their existing
spawn probabilities and caps. Existing entities and terrain remain authoritative;
existing dinosaur maps gain new populations through their enabled dawn refill.

Dawn uses the live local diet census to aim for about two herbivores per predator.
This replaces individual H/H/C alternation because it cannot form coherent pods.
The saved sequence remains decodable; it is no longer the diet-selection authority.
Every overlapping player neighbourhood reserves capacity during pod planning.

## Empirical evidence

- Warning-free optimized debug package and production release build passed.
- 46 focused XCTest cases passed, including all historical profile revisions,
  deterministic replay, no partial pods at capacity, refusal work bounds,
  normal-world isolation, and multiplayer local census coverage.
- A matched 49-chunk sample around the seed-12345 Lost World starter site
  replays the previous algorithm over identical generated terrain: **2 -> 18**
  initial creatures, in two complete herbivore pods. A preliminary sample at
  unrelated coordinates of seed 0xCA11 produced no pods; it was not counted as
  successful density evidence. This is sampled evidence, not a guarantee of a
  fixed creature count on every terrain seed.
- Native optimized app: created isolated `Dinosaur Pods QA Sep27` (seed 12345,
  Lost World v4). The first observed Dryosaurus pod contained nine creatures
  (IDs 2–10). A depleted local region crossing a real dawn produced a
  ten-member Pachycephalosaurus pod and a nine-member Dryosaurus pod, plus
  predators, flyers and swimmers: 37 prehistoric births in total.
- Visually inspected the hillside pod in the ray-traced rendered game. With
  simulation running, a 20-second sample measured **87–109 FPS**, mean 103.55,
  with ray tracing active. This is a local machine/scene observation, not a
  guarantee for all hardware, world sizes or camera positions.
- Save/reload restored all **37/37** sampled birth IDs with the same species.
  The first probe paused immediately after load and saw only nine chunks;
  resuming chunk streaming resolved the incomplete census (379 chunks at match).
- The debug app was quit and its task-owned `caffeinate` wrapper stopped.

## Limits and revisit conditions

Suitable habitat remains mandatory. Steep, wooded or water-covered terrain can
refuse pods; very large sauropods may require the wider live dawn placement area
rather than a single bootstrap chunk. Populations are caps/probabilities, not
forced materialization through solid terrain. Creatures can roam, die and split
up after spawning. Ancient Seas retains its marine/flying roster, not invented
land herbivores. More entities can cost simulation/render time; revisit on
measured frame-time regressions or sparse encounters across representative maps.

## Reviewed release pins

Only GameCore's generated-pod admission source, Core's normalized object and the
two linked products changed. The Storage and TextInput normalized objects remain
byte-identical. Hashes are measured on disposable `xcrun strip -S -x` copies;
source hashing uses the unmodified source bytes. Storage APIs/CAS callers did not
change. The security and release gates still enforce their existing boundaries.

| Pin | Previous SHA-256 | New SHA-256 |
| --- | --- | --- |
| CORE_OBJECT | `6250f2763c4dbaff39f579725b1f6b184ee8b84971d2c4145429a3dbb9434b2c` | `ebc0186e079acace627813835fee69135d310de9bd47bc50d1052fe0b06c6698` |
| ELYSIUM_PRODUCT | `8b02fa857626d8295b1e1368b65e5574a617a8f56dc610155ed87236f9a47dcd` | `912319da853bb83d1464acbce5b0b783f4d18a630a3f8a204566f57efea4bb3c` |
| SMOKE_PRODUCT | `34ccc6d8860774ef91903c409355466c9d4931ff888b940504f06db42d96d8ee` | `b0ae954aee93e6dc893fe8efeb52b710ecda4900eea7c9ac18f96e38925d6f86` |
| STORAGE_OBJECT | `43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8` | `43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8` |
| TEXT_INPUT_OBJECT | `0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3` | `0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3` |
| GAME_CORE_SOURCE | `f364c3adc7757a4ed725f0e5b85d5a6cbc330ab02d3bfbd5316e6761a8629eab` | `3262a3e6a8d751eb3163bec26f0e5ce0e2515428d0989e5330b9bb0c77ca7ca0` |

The unchanged deterministic golden contract passed: **491 checks, zero failures**.
