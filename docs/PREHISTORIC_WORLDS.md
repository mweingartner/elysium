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

World creation now offers the four profiles alongside the existing presets.
Selecting one is persisted in the world record and changes only that new
world's profile domain. Ancient Seas additionally applies a coast-heavy
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
identity. A later content revision must add a new versioned preset rather than
silently reinterpret a saved prehistoric world.

## Content model

`PrehistoricWorldProfile` owns the canonical ordered roster of 36 stable
`prehistoric.<name>` entity identifiers. The registry appends the roster after
the historical entity range, preserving existing entity ordinals. The four
profiles choose ordered subsets of that roster; Lost World contains the full
mixed-era set.

One data definition drives collision bounds, health, speed, pack size,
spawning weight, sound identity, and movement family. The implementation uses
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

Action state is a closed, bounded field in `EntityData`; it is saved and
replicated by the host for renderer presentation. Each creature also persists
its private four-word deterministic controller stream, bounded ambient-audio
cooldown, and a stable spawn salt; constructing or loading it never consumes
the global gameplay RNG or injects an artificial ambient-audio controller draw
after reload. Non-persisted route waypoints deliberately recompute against
current terrain. None of this makes renderer frame rate, audio, or visual
randomness authoritative.

## Native assets and audio

The current Elysium renderer has a bounded 24-rigid-part native `MobModel`
contract; it does not have a safe generic skinned-mesh/GLB runtime importer.
Accordingly, this release ships original native procedural models and texture
painting for all 36 types rather than pretending a proposed weighted-skin asset
format exists. Every model is validated for finite geometry, in-skin UVs, and
the 24-part limit. The initial land, air, and water reference types carry
specific silhouette checks: Triceratops has a three-horned/frilled head,
Pteranodon has a toothless beak, crest, and paired membrane wings, and
Ichthyosaurus uses a vertical tail fluke with fins rather than a reused dolphin
model.

Creature voices are original runtime synthesis recipes with native accessibility
subtitles. They do not read a user script-WAV library, external URL, authoring
path, film/game recording, or network service. Cosmetic variation is generated
in the audio layer and never consumes simulation RNG.

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
entities. Unknown future prehistoric preset IDs fail closed at save and LAN
decode boundaries rather than being normalized to a normal world. LAN summaries
carry both the normalized profile preset and its versioned content identity, so
a joining guest constructs the same transient generation settings or receives
an explicit incompatibility rejection; entity snapshots carry only validated
presentation action/air fields. A mixed app version is also rejected by
Elysium's existing version gate rather than silently differing on models or
collision.

## Verification map

The source tests cover the ordered roster, normal-profile identity, profile
spawn-domain replacement, village/patrol-domain filtering, an exact normal
terrain-fill golden, Ancient Seas deep-water connectivity and retained island
landfalls, renderer model limits and landmarks, action/controller persistence,
global-RNG isolation, spawn and route clearance rejection, finite land/air/water
controllers, and LAN profile/content/action sanitization. Existing release gates cover the full
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
