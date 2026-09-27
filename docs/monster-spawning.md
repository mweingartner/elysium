# Dungeon and nighttime cave spawning — September 27, 2026

## Outcome and decision

Dungeon spawners and periodic nighttime cave monsters now work on ordinary and
prehistoric maps. The user explicitly confirmed the dinosaur-map scope.
Three primary repository evidence sources informed the repair: the old
`BlockEntities.swift` handler, `EntityRegistry.swift` natural sampler, and
`GameCore.swift` host simulation dispatch. The spawner's prehistoric guard made
those blocks inert; ordinary attempts checked only the foot cell and often
sampled above/below the floor; the natural cave sampler picked arbitrary Y
positions under a whole-loaded-world monster cap.

Keep the existing surface/skyless natural sampler unchanged. Reuse block-entity
ticking, entity factories, gameplay light and collision geometry for the
spawner repair, and add a bounded underground pass beside natural spawning on
the authoritative simulation tick. This avoids changing unrelated natural-spawn
goldens or the dinosaur dawn scheduler. Existing saved spawners activate without
terrain regeneration; save formats and registration order do not change.

## Behavior and limits

- Spawners require a living player within 16 blocks, non-Peaceful difficulty,
  enabled `doMobSpawning`, and an authoritative world. Up to 32 candidate columns
  find supported floors at the spawner's height or one block above/below. Real
  body geometry must clear blocks, fluids, entities, map bounds and unloaded
  edges. At most six nearby monsters of the configured type; successful waves
  retain a 200–799-tick cooldown. Failed placement/light waves retry in 20 ticks
  and do not play a false spawn-success sound.
- Ordinary spawner birth sites require zero propagated block light; blaze
  spawners allow up to 11. Dungeon spawners can operate during daytime too.
- At night (`13000..<23000`), every 100 ticks (five simulated seconds), the cave
  pass checks at most 16 columns and 33 nearby heights per column, making at most
  four births. Sites are 24–64 horizontal blocks from a selected player and
  within 16 blocks vertically. They need a roof, zero sky/block light, valid
  biome roster, dry floor and full-body clearance, and must be at least 24 blocks
  from every active player. Each overlapping player neighbourhood is capped at
  16 monsters within 80 horizontal / 24 vertical blocks. Distant loaded monsters
  cannot starve a local cave. Host-owned LAN player proxies participate; clients
  do not spawn independently.
- Actual encounter rate depends on available dark habitat. Surface dinosaur
  rosters, ordinary surface spawning and skyless-dimension natural spawning
  remain separate. Newly created monsters may move, die or despawn normally.
  Torch protection follows gameplay light, not the renderer's cave visibility
  floor. More active entities may cost frame time; revisit on measured density
  or performance regressions.

## Verification

Ten dedicated tests cover a real generated/restored dungeon on normal, classic
and current dinosaur maps; six configured spawner species; six-monster cap;
Peaceful/rule/client/distance gates; successive-night cave refill; narrow tunnels;
actual torch removal; overlapping players; body/fluid/unloaded-edge refusal;
bounded work; deterministic positions/types; and distant-population isolation.
The focused run passed **75 tests, zero failures**. A warning-free production
build and the unchanged **491 golden checks** passed. The impact selector requires
the full regression suite; installation/publication use the normal release
pipeline and active pre-push hook.

Native optimized app (SHA-256
`757c756090e61ccf5b5c96648d8b6738ab88e89adf03f35e2dea16e686b32e3f`):

- An actual seed-12345 generated dungeon at (-246, 11, -1126) produced a live
  spider. The initial probe was outside activation range because initial world
  streaming moved the player to the surface; re-entering the loaded room resolved
  it. This was a probe-position error, not evidence of failed spawning.
- Copying that generated room through the production template path into a new
  Lost World v4 QA save produced **four spiders** from its real spawner.
- In an isolated five-block-wide tunnel, daytime produced no monsters. With
  torches every ten blocks, 600 nighttime ticks produced **zero tunnel births**.
  Removing torches and advancing 1,200 ticks produced a **zombie**. On another
  night after clearing the QA population, 1,800 ticks produced a **skeleton and
  zombie**. These are sampled encounter counts, not a guaranteed per-pass count.
- Saving/reloading restored **2/2** sampled second-night IDs/types. The live
  dungeon and tunnel monster were visually inspected; light was added only after
  dark-birth proof to make the screenshot readable. No performance benchmark or
  end-to-end multi-machine LAN playtest is claimed; caps/authority are tested.
- Only newly-created isolated debug-profile worlds were edited. The debug app
  exited through its authenticated `app.quit` operation after verification.

## Reviewed release pins

GameCore adds only the host cave-spawn call; its checked storage surface is unchanged.
The warning-free release build and SQLite boundary scan passed. Only the changed
GameCore source, Core object and linked products are renewed. Storage and TextInput
objects remain byte-identical. Normalized artifacts use disposable `strip -S -x` copies
from the original checkout.

| Pin | Previous SHA-256 | New SHA-256 |
| --- | --- | --- |
| CORE_OBJECT | `ebc0186e079acace627813835fee69135d310de9bd47bc50d1052fe0b06c6698` | `2f7ebaebc957252ceb8bd76b40fb91fb792b1d19e49b8baa18a66a12215fbd7f` |
| ELYSIUM_PRODUCT | `912319da853bb83d1464acbce5b0b783f4d18a630a3f8a204566f57efea4bb3c` | `83443cfc377e72ddfcabeeae49e799898ffd36b7f61db2e6c3af7e109dfea2d4` |
| SMOKE_PRODUCT | `b0ae954aee93e6dc893fe8efeb52b710ecda4900eea7c9ac18f96e38925d6f86` | `0d2616fb1923166dc1e0494eaeee30b779f2221eb3b188be6fbfe6b2155d778e` |
| STORAGE_OBJECT | `43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8` | `43ea474d75be3fc2311f1a95295c94d23329249f505ed0c14878f7318e14b3a8` |
| TEXT_INPUT_OBJECT | `0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3` | `0fcd8840b58e2db50fc3556144417b4615d99f1e7bb75344dd259149dd705bf3` |
| GAME_CORE_SOURCE | `3262a3e6a8d751eb3163bec26f0e5ce0e2515428d0989e5330b9bb0c77ca7ca0` | `c697261db513b3652729face7a5ba4f2eb531b1b27417816176bdd0aaa7801ed` |
