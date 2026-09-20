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

World creation offers the current v2 revision of the four profiles alongside
the existing presets. Selecting one is persisted in the world record and
changes only that new world's profile domain. Explicit v1 preset IDs remain
loadable with their original simulation contract, but are not offered as a
second set of duplicate create-world choices. Ancient Seas additionally applies a coast-heavy
terrain treatment to its own continuous continentalness sample before terrain
height and surface-biome selection: mid-continent margins become navigable
water while high terrain remains dry island landfalls. It uses no global
terrain mutator, so ordinary saves, legacy entity ordinals, normal biome spawn
tables, and normal-world generation paths remain unchanged. Prehistoric
profiles suppress modern passive/ambient/monster spawn tables, legacy
structure-spawner ticks and direct legacy structure occupants, patrol
scheduling, and human village/pillager-outpost plans; roster predators provide
their own host-authoritative danger while the rest of the Overworld structure
domain remains available.

Each profile is versioned in its `WorldPreset` raw identifier and cache
identity. Version 2 adds the predator/prey and herd-defense simulation plus a
deterministic starter shelter while keeping the ordered creature roster stable.
It uses a distinct cache and LAN content identity; a v1 save continues to
resolve to its v1 profile and cannot silently gain the new behavior. Historical
unversioned import aliases retain their v1 meaning, while the create-world
selector writes explicit v2 IDs.

## Content model

`PrehistoricWorldProfile` owns the canonical ordered roster of 36 stable
`prehistoric.<name>` entity identifiers. The registry appends the roster after
the historical entity range, preserving existing entity ordinals. Both
supported revisions of the four profiles choose the same ordered subsets of
that roster; Lost World contains the full mixed-era set. The version boundary
therefore changes only explicitly versioned simulation rules, never entity
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

### Version-two land ecology and first-night shelter

Only current v2 profiles opt into the land ecology. A land predator performs a
bounded deterministic prey scan on a fixed cadence, selects a visible nearby
land herd herbivore by distance then stable entity id, and keeps the normal
player-target fallback at lower priority. It eats only after it has actually
killed that herbivore; there is no hidden hunger meter, corpse ledger, or
chunk-order-dependent ecosystem state. Pterosaurs and marine reptiles retain
their specialized air/water controllers rather than receiving a nonsensical
land hunt rule.

Land herd herbivores rally across compatible species when a nearby ally was
recently struck by a living prehistoric land predator. Their v2-only defensive
attack, knockback resistance, and predator-only damage reduction make the
response credible without changing player or environmental damage. Defensive
creature XP uses the same bounded combat-difficulty policy, so a difficult
defender remains worth more ordinary XP than a low-threat animal. Version-one
profiles retain their original values and goal order.

Every new v2 prehistoric world derives one bounded spawn site from its seed
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

Creature voices are original runtime synthesis recipes with native accessibility
subtitles. They do not read a user script-WAV library, external URL, authoring
path, film/game recording, or network service. New action and locomotion cue
variation is generated in the audio layer without consuming simulation RNG.

Every roster member has a direct synthesized cue for ambient, injury, death,
attack, every closed controller action, and its applicable movement rhythm
(step, wingbeat, or swim stroke). Action cues emit only when the semantic state
actually changes; motion cues are rate-limited from already-simulated age and
movement, never by a new random stream. Each species carries a stable,
source-authored acoustic signature and formant, so matching size/family alone
cannot make two species share a voice. This preserves the no-external-audio
constraint while making a nearby creature's action and identity distinguishable.

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
entities. Explicit v1 identifiers and identities remain accepted for existing
worlds; v2 identifiers select the current simulation contract. Unknown future
prehistoric preset IDs fail closed at save and LAN decode boundaries rather
than being normalized to a normal world. LAN summaries carry both the
normalized profile preset and its versioned content identity, so a joining
guest constructs the same transient generation settings or receives an
explicit incompatibility rejection; a v1 peer can never join a v2 profile
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

## Revisit conditions

Revisit this design if a model exceeds the rigid-part budget, body-aware
clearance blocks a normal playable route, a profile perturbs normal-world
goldens, host/client profile identity diverges, or visual review finds a
silhouette/action that the existing renderer cannot present cleanly. Do not
paper over those failures by changing legacy renderer contracts or broadening
the asset loader without a focused design decision.
