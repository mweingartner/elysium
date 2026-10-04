# Prehistoric Worlds

## Scope and authority

This feature adds **four versioned, opt-in world profiles** to Elysium:

- Lost World
- Jurassic Giants
- Cretaceous Frontiers
- Ancient Seas

The planning material supplied for this feature is product and acceptance-test
input, not executable authority. In particular, its staged “start here” and
follow-on prompts describe a suggested delivery order; the user's request to
complete the feature authorizes the complete roster and profile set. Existing
repository operating rules, source contracts, and release gates remain
authoritative.

The profiles are game-authoring groups, not claims that every listed creature
coexisted. Pterosaurs and marine reptiles are included as prehistoric creatures
for play but are not presented as dinosaurs. Dimensions, colours, behaviours,
and sounds are original game design rather than historical reconstructions or
recordings.

## Player outcome

World creation offers the current v4 revision of the four profiles alongside
the existing presets. Selecting one is persisted in the world record and
changes only that new world's profile domain. Explicit v1, v2, and v3 preset IDs remain
loadable with their original terrain and combat contract, but are not offered as a
second set of duplicate create-world choices. Ancient Seas additionally applies a coast-heavy
terrain treatment to its own continuous continentalness sample before terrain
height and surface-biome selection: mid-continent margins become navigable
water while high terrain remains dry island landfalls. It uses no global
terrain mutator, so ordinary saves, legacy entity ordinals, normal biome spawn
tables, and normal-world generation paths remain unchanged. Prehistoric
profiles suppress modern passive/ambient/surface-monster spawn tables, direct
legacy structure occupants, patrol scheduling, and human village/pillager-outpost
plans. Dungeon, mineshaft, stronghold and fortress spawners now function on these
maps too, and unlit caves/tunnels receive bounded monster attempts every five
simulated seconds at night. Peaceful and disabled mob spawning suppress both.
Roster predators continue to provide the surface danger; saved chunks need no
regeneration to activate their existing spawners. See the [monster spawning
verification record](monster-spawning.md).

Each profile is versioned in its `WorldPreset` raw identifier and cache
identity. Version 2 adds the predator/prey and herd-defense simulation plus a
deterministic starter shelter while keeping the ordered creature roster stable.
It uses a distinct cache and LAN content identity; a v1 save continues to
resolve to its v1 profile and cannot silently gain the new behavior. Historical
unversioned import aliases retain their v1 meaning, while the create-world
selector writes explicit v4 IDs. Version 3 retains v2's ecology and starter
shelter while adding more caves, more inland underground lava areas, and rare
small volcanoes with exposed crater lava. Version 4 keeps all of that, gives the
map a warm climate with no snow or ice, and raises many more surface volcanoes.
Version 1, 2, and 3 terrain remains unchanged, including in newly explored
chunks of those older worlds.

### Warm climate (v4)

Dinosaur maps created as v4 never generate a snow or ice section. Surface-biome
selection keeps the ordinary climate table, then replaces each cold result with
its nearest warm counterpart (`prehistoricWarmBiome`): frozen and deep frozen
oceans become ocean and deep ocean, frozen rivers become rivers, snowy beaches
become beaches, snowy plains and ice spikes become plains, snowy taiga and
groves become taiga, snowy slopes become meadow, and jagged or frozen peaks
become stony peaks. The mapping acts on the selected biome rather than the
climate input because the high-peak family is chosen from erosion and
peaks-valleys alone. Terrain height is unchanged. Chunk generation also skips
the altitude snow-and-ice pass, which would otherwise still cap high taiga and
windswept hills, and weather in a v4 world rains instead of snowing, so it
never layers snow or freezes still water. Only the deep-dark ancient city's
ice-box room keeps its packed ice. v1-v3 maps keep their original climate,
including in newly explored chunks, so they show no climate seams.

### Caves and volcanic terrain

All four current dinosaur profiles have wider noise caves and more tunnel and
ravine starts than their older revisions. Inland lava-aquifer regions are more
frequent, but their upper level stays at Y=12; ordinary ocean water still wins
under ocean columns. Ancient Seas therefore retains its navigable seas and
islands rather than replacing its water with lava.

Small volcanoes are occasional surface landmarks, not eruptions. They use
existing rock blocks and contain exposed lava in a crater. A cone spans 21–29
blocks and rises 8–11 blocks above the highest surveyed ground; its lava pool
has a 2–3-block radius and a raised rock rim. In v3 each 24×24-chunk region
has one centred candidate, not one guaranteed volcano. v4
(`PrehistoricVolcanoSiting`) uses 12×12-chunk regions, tries the centre and then
eight nearby sites 12 blocks away, and accepts up to eight blocks of ground
relief instead of six. Across four sampled 96×96-chunk areas that raised the
admitted volcanoes from 4 to 79 (about one per 21×21 chunks). Placement requires
a dry, supported footprint and rejects unsuitable slopes, water, the entire
starter shelter/grove neighborhood, and conflicts with existing structures.
Trees and snow respect an accepted volcano's footprint. No volcanoes are added
to v1/v2 worlds, ordinary presets, or the Nether, and v3 keeps its sparse
lattice. Saved full-block chunks are
never rewritten; v1/v2 also retain their original generator when unmodified
chunks saved only as entity records are regenerated.

## Content model

`PrehistoricWorldProfile` owns the canonical ordered roster of 36 stable
`prehistoric.<name>` entity identifiers. The registry appends the roster after
the historical entity range, preserving existing entity ordinals. All
supported revisions of the four profiles choose the same ordered subsets of
that roster; Lost World contains the full mixed-era set. The version boundary
therefore changes only explicitly versioned terrain and simulation rules, never entity
ordinals or roster membership.

One data definition drives collision bounds, health, attack, combat XP reward,
speed, pack size, spawning weight, sound identity, and movement family. The implementation uses
three bounded deterministic controllers:

- Land creatures use ordinary goals plus whole-body clearance for large
  pathfinding nodes. The broad visual envelope must remain clear, while only
  the physical-footprint cells require level support so giant taxa are not
  restricted to an artificial full-body pad. Bootstrap specs are validated in
  their source chunk and again after live chunk adoption. Ceratopsians and
  large defensive animals can telegraph a charge and recover after it.
- Flyers launch from a valid footprint, then use a bounded target/flight state
  machine (`takeoff`, `flap`, `glide`, `landing`) driven solely by their seeded
  entity RNG.
- Aquatic reptiles use valid water-volume targets and explicit cruise, burst,
  surface, dive, and stranded states. Their controller first verifies an
  entire vertical breathing route, then uses a capped deterministic
  connected-water search for a detour; it rejects invalid water spawns and
  never treats a disconnected puddle as a surface.

Prehistoric water profiles also retain a small weighted wild-fish resource
table (`cod`, `salmon`, and `tropical_fish`) after the roster entries. These
are non-domestic prey/resource species, not restored modern passive fauna;
they give fish-focused swimmers a live in-profile food source and keep the
water population bounded by the existing category cap.

Land profiles likewise end with one `chicken` entry, weighted to about one in
eight land spawns, in flocks of 2–4. Chickens are the only ordinary land animal
on dinosaur maps: their feathers fletch arrows. They appear at chunk generation
(the generated-entity admission accepts any mob the profile itself spawns),
through natural spawning, and in dawn refills alongside the herbivores, one bird
per pick; they never count toward the herbivore/predator diet census. Ancient
Seas has no land table and so no chickens. True dinosaurs (theropods,
ceratopsians, hadrosaurs, armoured dinosaurs, sauropods and the unusual
herbivores) also drop 0–2 feathers, plus looting, like a chicken; pterosaurs
keep their existing feather drop, while marine reptiles and the crocodilian
Deinosuchus drop none. These changes apply to every profile revision.

### Dawn replenishment and forest renewal

**Options... → World → Creature Respawn** controls replenishment on all supported
maps without changing their roster, terrain, or combat revision. **Daily** is the
default; **Alternate Days** and **Weekly** wait for two or seven actual in-game
dawns. Sleeping counts as completing the current cycle. Each world's saved
calendar preserves progress across reload, while the local player's or LAN
host's preference chooses the interval. Joined clients do not run their own
waves. Paused or closed worlds earn no offline cycles, and frozen daylight earns
no dawns. A clock command does not itself age trees or immediately spawn
creatures; the ensuing natural wrap still counts as a dawn, intentionally
allowing administrator shortcuts. Sleeping advances tree age by the skipped
portion of the night.

At an eligible dawn, bounded attempts refill available population capacity near
active players using the existing loaded-terrain, distance, water, and whole-body
clearance checks. Prehistoric maps apply the category caps to each active player's
own neighbourhood (creatures within 128 blocks of that player), so herds parked at
the edge of loaded terrain (beyond the simulation radius) cannot hold every slot
while the area around the player empties, and in LAN play one player's full region
cannot use up another's vacancies; regular maps keep counting the whole loaded world.
Dinosaur maps now allow **48 land, 30 air and 10 water creatures** per local region
(previously 18/15/5). Dawn placement attempts double to 128/64/64. Land placement
has an additional shared 1,024-check budget, including pod retries.
Land herbivores spawn as complete, same-species **pods of 8–10** within a
24-block-wide area. A site that cannot safely admit eight produces no partial
pod. Dawn selects diets from the live local census, aiming for roughly two
herbivores per predator, rather than alternating isolated H/H/C births. Tight
capacity may admit individual predators; it never cuts down a herbivore pod.
Mortality, existing saves and terrain can change the actual population and ratio. **Ancient
Seas** deliberately has no land-herbivore table: its native pterosaur/marine
roster and wild-fish prey still replenish, without relabeling marine reptiles as
herbivores or importing land species. Initial land-pack chance doubles from
28% to 56% per newly generated chunk. Herbivore packs use the same 8–10 range,
with at most 128 placement tries in that chunk and an all-or-none minimum of
eight at both generation and adoption. Existing saved entities remain intact;
existing maps receive the increased population through their enabled dawn refill. A full population, disabled mob spawning, or failed habitat checks
does not bank an unbounded later wave; ordinary monsters and skyless-dimension
spawning keep their established rules.

Natural trees, including newly generated/grown trees, carry explicit provenance.
Disconnecting a trunk from grounded support causes its unsupported wood and
associated canopy to deteriorate gradually over one simulated day. Some leaves
produce collectible saplings; some attempt safe self-planting instead. Growth
checks loaded space and preserves obstructing blocks and containers. Player
builds and unmarked trees in older fully saved chunks are not retroactively
classified as natural trees. Incomplete tree neighborhoods defer updates;
returning to an area resumes due decay with bounded work. Freezing Overworld
daylight freezes this deterioration clock, and disabling tile drops suppresses
both kinds of seedling output. See the [Player Guide](../PLAYER_GUIDE.md#wildlife-renewal-and-forests).

### Version-two land ecology and first-night shelter

Version 2 and 3 profiles opt into the land ecology. A land predator performs a
bounded deterministic prey scan on a fixed cadence, selects a visible nearby
land herd herbivore by distance then stable entity id, and keeps the normal
player-target fallback at lower priority. It hunts only herbivores no longer
than one and a half times its own length (a Compsognathus hunts none), eats only
after it has actually killed its prey, and then starts no new hunt for 12000 of
its own ticks (half an in-game day). That satiation window lives only in the running session; there
is no saved hunger meter, corpse ledger, or chunk-order-dependent ecosystem
state, and these limits apply in place to existing v2 and v3 maps. Pterosaurs and marine reptiles retain
their specialized air/water controllers rather than receiving a nonsensical
land hunt rule.

Herd encounters follow `PrehistoricHerdEncounterPolicy` so neither side wipes the
other out. A predator stands its ground while healthy: it no longer bolts from
every blow, answers its attacker, and resists being shoved out of reach (heavy
theropods more than small ones). It retreats about twenty blocks when its health
falls to 40%, when three herd defenders are on it, or when it has already fed,
and then stays wary of herds for two minutes, neither hunting nor answering their
blows. A herd keeps defending only while the predator struck one of its members
in the last ten seconds and stays within eighteen blocks, so a rally ends when the
predator retreats instead of chasing it down. Land creatures that have not been
hurt for twenty seconds recover 2% of their health every two seconds. These rules
are session-only and RNG-free; version-one profiles keep their frozen goals.

Land herd herbivores rally across compatible species when a nearby ally was
recently struck by a living prehistoric land predator. Their v2-and-later defensive
attack, knockback resistance, and predator-only damage reduction make the
response credible without changing player or environmental damage. Defensive
creature XP uses the same bounded combat-difficulty policy, so a difficult
defender remains worth more ordinary XP than a low-threat animal. Version-one
profiles retain their original values and goal order.

Every v2 or v3 prehistoric world derives one bounded spawn site from its seed
and complete generation settings. The site is stamped as a physical seven by
seven oak shelter after terrain, vegetation, and snow: it has a supported
floor, enclosed walls, a roof, paired door, paired red bed, crafting table,
and a chest. The chest's seed is derived at world adoption from the world seed
and its coordinates; guaranteed category pools supply two basic tools, a small
random selection of resources, and food. Eight fixed nearby oak trees provide
at least forty trunk logs independent of natural biome foliage. A dry,
low-variation pad is preferred; Ancient Seas and pathological terrain use the
same hut on a raised supported deck that remains walkably connected to every
guaranteed tree above water. Local hosts and LAN clients use this exact site.
Bed-less respawns and End returns use its clear centre while it remains intact,
or a deterministic nearby dry fallback if a player has changed the hut.
Bootstrap creatures are excluded from the immediate hut clearing. This is
world generation rather than a runtime one-shot grant, so it is reproducible
after reload or recovery; v1 maps do not receive a new structure.

Action state is a closed, bounded field in `EntityData`; it is saved and
replicated by the host for renderer presentation. Each creature also persists
its private four-word deterministic controller stream, bounded ambient-audio
cooldown, and a stable spawn salt; constructing or loading it never consumes
the global gameplay RNG or injects an artificial ambient-audio controller draw
after reload. Non-persisted route waypoints deliberately recompute against
current terrain. None of this makes renderer frame rate, audio, or visual
randomness authoritative.

## Native assets and audio

The current Elysium renderer has a bounded 24-rigid-pose-part native
`MobModel` contract; it does not have a safe generic skinned-mesh/GLB runtime
importer. Prehistoric creatures therefore use original source-authored,
faceted low-poly triangle meshes and native procedural texture painting for all
36 types. The mesh stream is immutable presentation data, shares the existing
one-pose-per-part renderer path, and deliberately does not introduce a file
loader or weighted skinning. Every model is validated for finite,
non-degenerate faces, in-skin UVs, no cuboid fallback, a bounded triangle
count, and the 24-part limit. The art direction is historically informed and
stylized rather than a claim of exact reconstruction: each taxon carries a
distinct silhouette instead of relying only on color or scale. Reference types
carry specific landmark checks: Triceratops has a three-horned/frilled head,
Pteranodon has a toothless beak, crest, and paired membrane wings, and
Ichthyosaurus uses a vertical tail fluke with fins rather than a reused dolphin
model.

Species landmarks stay in the rigid pose slot that moves them: skull details
such as beaks, crests, frills, and horns move with the head; claws and thumb
spikes move with their arm; and tail details move with their tail. Prehistoric
quadrupeds preserve their source-authored tail rest angle rather than inheriting
the legacy animal tail lift, while pterosaurs use a profile-safe standing pose
instead of the generic phantom fold. This keeps a true in-game side view
readable without adding a hierarchy or a new animation system.

Creature voices combine bundled Suno-derived recordings with native synthesis and accessibility
subtitles. Each of the 36 species has its own grazing/quiet-feeding, attack, and injury WAV. The
18 source masters cover six voice families; species-specific pitch, resonance, timing, and gain
edits make 108 distinct runtime clips while staying within the existing subscription allowance.
These are stylized creature effects, not claims about the actual voices of extinct animals.
See `Assets/dinosaur-audio/` for original exports, prompts, source links, processing and hashes.
The application never contacts Suno or reads the user script-WAV library for creature voices.

Feeding samples cover ambient, idle, browse, and eat cues. Attack and injury use their own
recordings; remaining action, movement and death cues keep the explicit per-species synthesis
recipes, which also remain the fallback for missing or invalid recordings. Semantic transitions
and motion rate limits are unchanged; no additional simulation RNG is consumed.

Prehistoric creature sounds fade smoothly with distance to silence at 40 blocks (ordinary mobs keep
the 18 x volume range, so dungeon and cave monsters do not carry through rock),
independent of caller volume. Active calls update their pan and gain when the player moves or
turns; their source remains the location where the call was emitted. At 20 blocks amplitude is
25% of the close level, and at 30 blocks it is 6.25%. Creature reverb sends follow the same fade.

Player-attributed prehistoric kills award ordinary XP orbs from the creature's
configured combat difficulty, not from visual body length: a bounded health
tier, active-attack tier, and predator/charge behaviour bonuses yield 2–24 XP.
The same existing `xpReward` remains the catalyst-bloom input, so sculk bloom
strength stays consistent with the kill's XP value. This does not change the
separate usage-based Melee/Ranged skill XP, which remains per successful use to
avoid farming high-health creatures.

The deliberately rejected alternative is a new generalized skeletal asset
pipeline. It would require a versioned binary importer, filesystem/package
hardening, GPU palette synchronization, skinned shadow/selection support, and
authoring/export validation that the existing renderer does not provide. It
should be reconsidered only if a future requirement specifically needs weighted
deformation beyond the native model contract and is funded with its own safety,
performance, and real-renderer acceptance work.

## Save, LAN, and compatibility policy

Old world records with no prehistoric preset decode as normal worlds. New
prehistory entity fields are optional, bounded, and ignored for unrelated
entities. Explicit v1 and v2 identifiers and identities remain accepted for existing
worlds, as do v3 identifiers; v4 identifiers select the current terrain and simulation contract. Unknown future
prehistoric preset IDs fail closed at save and LAN decode boundaries rather
than being normalized to a normal world. LAN summaries carry both the
normalized profile preset and its versioned content identity, so a joining
guest constructs the same transient generation settings or receives an
explicit incompatibility rejection; a peer cannot join a different profile revision
under the same friendly profile label. Entity snapshots carry only validated
presentation action/air fields. A mixed app version is also rejected by
Elysium's existing version gate rather than silently differing on models or
collision.

Gameplay sound hooks are currently host-local cosmetics: a LAN guest receives
validated action state but no semantic sound-event stream, and must not infer
an attack or death sound from sampled snapshots. Guest audio parity therefore
requires a future bounded, host-authoritative event protocol rather than a
best-effort snapshot guess.

## Verification map

The source tests cover the ordered roster, normal-profile identity, profile
spawn-domain replacement, village/patrol-domain filtering, an exact normal
terrain-fill golden, Ancient Seas deep-water connectivity and retained island
landfalls, renderer model limits and landmarks, action/controller persistence,
global-RNG isolation, unique creature/cue catalog signatures, direct
source-synthesis recipe coverage, species attack cues, difficulty-scaled player
XP-orb totals, deterministic predator target/kill/defense behavior, v1/v2
combat separation, complete generated starter-hut geometry, seed-derived chest
adoption and bounded category-complete supplies, ample fixed grove logs, and
an Ancient Seas GameCore first entry. Existing release gates cover the full
build, XCTest suite, golden smoke contract, security scan, packaging,
installation, and push hook.

Native visual review remains a separate empirical step: use the built game's
`ELYSIUM_PHOTOBOOTH=1` mode with `ELYSIUM_BOOTH_MOBS` set to the representative
roster to capture the renderer's real output. Audio recipe validation proves
the source/packaging route, but a human listening review is separately labeled
as unauditioned unless one is actually performed.

### Dinosaur persistence and refill — September 26, 2026

In-app probes ran the optimized debug-control build on the isolated debug copy of
the user's prehistoric New World (`wmuhh0wumk62d`), counting live `prehistoric.*`
entities by persistent id through the debug snapshot.

- **Dawn births across quit.** Starting shortly before dawn, the unmodified
  `0458c45` build refilled 284 to 288 dinosaurs, but its next launch found 287:
  a dawn birth in a never-edited chunk was not saved on quit. The fixed build
  refilled to 289 and its next launch found all 289 by id.
- **Stable population.** 284 dinosaurs survived a 60 s run, a 600-block trip
  that unloaded and reloaded their chunks, and a quit and reload, with identical ids.
- **Rapid unload/reload.** Eight 360-block round trips about a second apart left
  every home dinosaur in place. Extra ids seen after returning were the far chunks'
  own worldgen residents, which reload only when those chunks load again.

The unload/reload race itself is timing-dependent in the app; the
`ChunkEntityPersistenceTests` reload-race cases are its deterministic proof
(all three fail with the awaiting-commit lookup removed).

### Predator balance — September 26, 2026

The closed attrition harness (six mixed predators, twelve herbivores, flat v3
plain, one in-game day) previously ended with one predator: herd rallies killed
the rest. With the herd-encounter policy and half-day satiation:

| Layout | Predators left of 6 | Herbivores left of 12 |
|---|---:|---:|
| Scattered herbivores, one day | 6 | 7 |
| Four herds of three, one day | 6 | 8 |
| Scattered herbivores, three days | 6 | 4 |
| Four herds of three, three days | 6 | 7 |

A Tyrannosaurus hunting five Triceratops for 6000 ticks retreated twice and survived
at 49 of 62 health; all five Triceratops lived. The closed runs decline slowly
because nothing refills them; in a real world the dawn refill replaces losses.

The same release lets the AI companion summon any prehistoric species and populate
the player's area. In the built app, `/ai spawn some predators and herbivores in my
area` in the user's New World replied "Spawned 2 predators (2 Oviraptor) and 5
herbivores (4 Dryosaurus, Pachycephalosaurus) around you", and all nine dinosaurs
near the player were alive three minutes later. `bash scripts/pipeline.sh` passed all
nine stages from `/Users/mweingar/dev/pebble` (2,823 tests, 491 golden checks); the
installed `/Applications/Elysium.app` executable SHA-256 is `0a6418f3aa8d30088b4cd946a3a73524aefe17013c6205e264e3f1ec38d378f4`.

### Warm climate, volcanoes and AI area spawns — September 26, 2026

New maps are v4. For seed 1592590338 the generator census over 195 chunks around
the spawn found 78,438 snow and ice blocks at y >= 0 in v3 (12,621 snow-covered
surfaces) and none in v4, where the same ground is meadow, taiga and bare stony
peaks. Across four 96x96-chunk samples v3 admitted 4 volcanoes and v4 admitted 79.
In the built app a new v4 Lost World at that seed showed a flowered meadow where
v3 has snowy slopes, and a basalt cone with a lava crater about 130 blocks from the
starter hut.

`/ai spawn various dinosaurs near me` failed with "Found no safe place" on rugged,
wooded and coastal ground. On 20 generated v4 sites it now errors nowhere for
"various dinosaurs"; the remaining shortfalls are steep mountain ground the shared
spawn validator refuses, and the reply counts them. In the built app, asked from
inside the starter hut, it replied "Spawned 3 dinosaurs (2 Pachycephalosaurus,
Triceratops) around you", with the player under the hut's plank roof and every
creature standing under open sky. The heaviest placement search measured took 24 ms
on real terrain and 36 ms on adversarial terrain in a release build.
`bash scripts/pipeline.sh` passed all nine stages from `/Users/mweingar/dev/pebble`
(2,842 tests, 491 golden checks); the installed `/Applications/Elysium.app` executable
SHA-256 is `34c42bc623249710cc65acf0c1361e243e3fe612628802d63e9aeaa7c910a668`.

## Revisit conditions

Revisit this design if a model exceeds the rigid-part budget, body-aware
clearance blocks a normal playable route, a profile perturbs normal-world
goldens, host/client profile identity diverges, or visual review finds a
silhouette/action that the existing renderer cannot present cleanly. Do not
paper over those failures by changing legacy renderer contracts or broadening
the asset loader without a focused design decision.
