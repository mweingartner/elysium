# Pebble RPG Classes and Progression — v2 Implementation Contract

**Status:** approved contract; implementation and verification are in progress. This document does not claim that any item is complete until the corresponding source, semantic tests, installed-app proof, and LAN proof pass.

## Purpose and boundaries

This is the source of truth for Pebble's six-path RPG layer. It replaces the historical sketches that named different classes, point economies, or mechanics. The RPG layer adds identity and progression without preventing ordinary mining, crafting, building, combat, equipment use, or exploration.

The rules live in PebbleCore. The macOS target draws UI, routes configured input, and transports messages; it does not decide progression, authority, costs, targeting, or rewards. Static registration order is deterministic and ABI-sensitive. New items append after the frozen item range.

## Frozen registry

There are exactly six paths, eighteen branches, and fifty-four skills. In each branch the listed order is Foundation, Technique, Mastery. Every skill has exactly three ranks.

| Path (`id`) | Primary attributes | Branch (`id`) | Skills in registry order |
|---|---|---|---|
| Warden (`warden`) | STR, END | Guardian (`warden_guardian`) | `guard_stance`, `interpose`, `anchor_line` |
|  |  | Vanguard (`warden_vanguard`) | `heavy_cut`, `charge_break`, `stagger_chain` |
|  |  | Bulwark (`warden_bulwark`) | `shield_bind`, `plate_training`, `fortify_block` |
| Ranger (`ranger`) | DEX, LUCK | Marksman (`ranger_marksman`) | `quick_draw`, `steady_aim`, `crippling_shot` |
|  |  | Scout (`ranger_scout`) | `trail_sense`, `soft_step`, `far_sight` |
|  |  | Survivalist (`ranger_survivalist`) | `campcraft`, `weather_eye`, `beast_kinship` |
| Delver (`delver`) | STR, END | Miner (`delver_miner`) | `vein_reader`, `fast_bore`, `deep_reserves` |
|  |  | Trapper (`delver_trapper`) | `trap_probe`, `tripwire_mind`, `deadfall` |
|  |  | Treasure-Seeker (`delver_treasure`) | `salvage_eye`, `lock_touch`, `fortune_read` |
| Arcanist (`arcanist`) | INT, END | Elementalist (`arcanist_elementalist`) | `spell_formula`, `spark_weave`, `storm_focus` |
|  |  | Illusionist (`arcanist_illusionist`) | `minor_glamour`, `false_step`, `mirror_work` |
|  |  | Ritualist (`arcanist_ritualist`) | `ritual_circle`, `bound_servant`, `ward_scribe` |
| Mender (`mender`) | INT, LUCK | Physic (`mender_physic`) | `field_dressing`, `triage`, `second_breath` |
|  |  | Harvest (`mender_harvest`) | `herbal_lore`, `clean_brew`, `green_thumb` |
|  |  | Sanctuary (`mender_sanctuary`) | `safe_haven`, `protective_mark`, `sanctuary_bell` |
| Tinker (`tinker`) | INT, DEX | Redstone (`tinker_redstone`) | `circuit_sense`, `compact_gate`, `remote_trigger` |
|  |  | Artificer (`tinker_artificer`) | `field_mod`, `quick_repair`, `tool_tune` |
|  |  | Sapper (`tinker_sapper`) | `charge_pack`, `blast_shape`, `safe_fuse` |

There are exactly seventeen spells, in this registration order:

`ignite`, `frost_ray`, `shock`, `storm_aura`, `blur`, `decoy`, `shadow_step`, `mirror_image`, `mage_light`, `ward`, `summon_servant`, `stone_ward`, `mend_wounds`, `restore`, `purify`, `aegis`, `sanctuary`.

## v2 progression economy

- Character level is derived from bounded RPG XP and is always 1...20 after creation.
- Level 1 grants no spendable point. Each gained level grants one skill point, for exactly nineteen at level 20.
- Creation selects one specialization branch and exactly one Foundation skill in that branch. Its rank 1 is the only free rank.
- A rank purchase costs its target rank: rank 1 costs 1, rank 2 costs 2, rank 3 costs 3. Every cross-branch purchase costs one additional point.
- A player must buy ranks sequentially. A Technique requires its branch Foundation at rank 2. A Mastery requires its branch Technique at rank 2.
- `rpgAvailableSkillPoints` is the only affordability calculation. All additions and subtractions use checked or saturating arithmetic.

| Node | Selected-branch rank gates | Cross-branch rank gates | Selected costs | Cross costs |
|---|---|---|---|---|
| Foundation | 1 / 4 / 8 | 3 / 6 / 10 | free starter, then 2 / 3 | 2 / 3 / 4 |
| Technique | 5 / 10 / 14 | 7 / 12 / 16 | 1 / 2 / 3 | 2 / 3 / 4 |
| Mastery | 12 / 16 / 20 | 14 / 18 / 22 | 1 / 2 / 3 | 2 / 3 / 4 |

The cross-branch Mastery rank-3 gate at level 22 is intentionally unreachable at the level-20 cap. Banking between gates is expected and must be shown by the UI, not treated as an error.

Cap proof: after the free selected Foundation rank 1, ranks 2–3 of that Foundation cost 5; all three Technique ranks cost 6; all three Mastery ranks cost 6. A complete specialization therefore consumes 17 earned points. One cross-branch Foundation rank 1 costs 2. `17 + 2 = 19`, so a level-20 character can complete one branch and add one utility foundation with no stranded or negative points.

Attribute training remains bounded: one point at levels 4, 7, 10, 13, 16, and 19; creation values are 6...14, progression values cap at 18, and the creation total is exactly 42.

## Character creation and starter kits

| Path | STR | DEX | END | INT | LUCK | Atomic, one-time kit |
|---|---:|---:|---:|---:|---:|---|
| Warden | 11 | 7 | 10 | 7 | 7 | `stone_sword`, `shield`, 4 `bread` |
| Ranger | 7 | 11 | 8 | 7 | 9 | `bow`, 24 `arrow`, `stone_sword`, 4 `bread` |
| Delver | 10 | 8 | 10 | 7 | 7 | `stone_pickaxe`, 16 `torch`, 4 `bread` |
| Arcanist | 6 | 8 | 8 | 12 | 8 | `apprentice_focus`, 8 `torch`, 4 `bread` |
| Mender | 6 | 8 | 10 | 10 | 8 | `apprentice_focus`, two separate `potion` stacks with `data.potion = "healing"`, 4 `bread` |
| Tinker | 7 | 10 | 8 | 10 | 7 | `stone_pickaxe`, 12 `redstone`, 4 `torch`, 4 `bread` |

`apprentice_focus` is a non-stackable, append-only item ID and is required in either hand for spells. Edited creation attributes must still total 42 and satisfy the selected Foundation's requirement. The registry is authoritative for requirements, and every recommended preset satisfies all three of its path's Foundation choices.

Kits are preflighted and committed with character creation. New v2 characters persist `kitGrantVersion = 1` and a deterministic, at-most-64-byte `kitGrantID`; retrying creation cannot duplicate a kit. Migrated v1 characters receive no retroactive kit.

All attributes have runtime consumers:

- STR contributes to health, melee damage, and bounded bonus carry slots.
- DEX contributes to ranged accuracy and reduces active-action recovery time, with a floor of 80% of base cooldown.
- END contributes to health, maximum fatigue, and fatigue regeneration.
- INT contributes to spell damage/healing and focus efficiency; no spell can cost less than one fatigue.
- LUCK adds a capped deterministic bonus to explicitly tagged loot/durability/crafting procs. A stable hash is used; unordered iteration and ambient random APIs are forbidden.

## Typed skill-effect contract

Every rank owns one or more exhaustive `RPGSkillEffect` values: stat modifier, fatigue/cooldown modifier, weapon/tool modifier, harvest/loot modifier, action unlock, spell unlock, XP modifier, targeting modifier, or inventory/crafting modifier. Runtime systems consume those values; they do not switch on skill-ID strings. Registry validation fails if a displayed rank lacks an effect, an effect lacks a consumer, or its generated description differs from the effect.

Every active is defined by `RPGActionDefinition`: target kind, friendly/hostile policy, equipment/focus requirement, range, line of sight, PvP eligibility, world mutation, material transaction, fatigue, cooldown, duration, and rank scaling. Preflight validates every field before any spend or mutation.

The following summaries are the complete player-facing contract. Slash-separated values are ranks 1/2/3.

### Warden

| Skill | Kind | Exact observable rank effect |
|---|---|---|
| `guard_stance` | passive | Increase maximum health by 1 / 2 / 3. |
| `interpose` | active | Grant 3 / 4 / 5 absorption and brief resistance to self and up to three non-hostile allies. |
| `anchor_line` | active | Brace against knockback and pull one visible non-player ally toward the caster with 0.35 / 0.50 / 0.65 force. |
| `heavy_cut` | active | Requires a melee weapon; one visible hostile in melee range takes +2 / +4 / +6 damage. |
| `charge_break` | active | Rush and strike the first visible hostile for 4 / 6 / 8 damage. |
| `stagger_chain` | passive | Heavy Cut's slow lasts 40 / 80 / 120 additional ticks. It does not claim a separate combo subsystem. |
| `shield_bind` | passive | Increase maximum fatigue by 1 / 2 / 3. |
| `plate_training` | passive | Add 0.002 / 0.004 / 0.006 fatigue regeneration per tick. |
| `fortify_block` | active | Protect one targeted non-air block from 1 / 2 / 3 explosion destructions through the bounded transient registry. |

### Ranger

| Skill | Kind | Exact observable rank effect |
|---|---|---|
| `quick_draw` | passive | Bows reach the same power 2 / 4 / 6 charge ticks sooner. |
| `steady_aim` | passive | While grounded, reduce bow spread by 15% / 30% / 45%. |
| `crippling_shot` | active | Requires a bow and consumes one arrow; slow one visible hostile for 120 / 180 / 240 ticks. |
| `trail_sense` | passive | While sneaking, reveal nearby hostiles with Glowing in radius 8 / 12 / 16; refresh at most once per 20 ticks. |
| `soft_step` | passive | Increase sneaking movement by 5% / 10% / 15% without changing normal walking. |
| `far_sight` | active | Grant Night Vision and reveal up to eight hostiles in radius 16 / 24 / 32. It creates no map markers. |
| `campcraft` | passive | Safe grounded rest adds 0.005 / 0.010 / 0.015 fatigue regeneration per tick. |
| `weather_eye` | passive | The HUD reports current weather and rounds the transition timer to 30 / 10 / 1 seconds. |
| `beast_kinship` | passive | Passive-animal avoid goals ignore the Ranger within 4 / 7 / 10 blocks unless harmed. |

### Delver

| Skill | Kind | Exact observable rank effect |
|---|---|---|
| `vein_reader` | passive | Increase stone and ore mining speed by 10% / 20% / 30%. |
| `fast_bore` | active | Grant a Haste I / II / III mining burst. |
| `deep_reserves` | passive | Breaking hard stone below sea level restores 0.1 / 0.2 / 0.3 fatigue within a tick cap. |
| `trap_probe` | active | Reveal the nearest registered trap within 6 / 8 / 10 blocks. |
| `tripwire_mind` | passive | Reduce explosion and trap damage by 15% / 30% / 45%. |
| `deadfall` | active | Consume one carried `gravel` and place one valid temporary gravel trap for 80 / 120 / 160 ticks; Creative does not consume material. |
| `salvage_eye` | passive | Every 12th / 8th / 5th qualifying crafted-block break preserves one tool durability. It never duplicates placed blocks. |
| `lock_touch` | active | Inspect an authorized container and report up to 4 / 8 / 16 occupied slots. It opens no fictional locks. |
| `fortune_read` | active | Preview one item in stable slot order with coarse / medium / exact fill detail. It does not predict future loot. |

### Arcanist

| Skill | Kind | Exact observable rank effect |
|---|---|---|
| `spell_formula` | unlock/passive | Spell damage gains +0.5 / +1.0 / +1.5; unlock Ignite at rank 1 and Frost Ray at rank 2. |
| `spark_weave` | unlock/passive | Elemental fatigue cost is reduced by 0.5 / 1 / 1.5, never below one; unlock Shock at rank 2. |
| `storm_focus` | unlock/passive | Storm Aura damage is 1.5 / 2.0 / 2.5; unlock it at rank 2. |
| `minor_glamour` | unlock/passive | Illusion duration is x1.10 / x1.20 / x1.30; unlock Blur at rank 1 and Decoy at rank 2. |
| `false_step` | unlock/passive | Shadow Step range gains +1 / +2 / +3 blocks; unlock it at rank 2. |
| `mirror_work` | unlock/passive | Mirror Image grants 2 / 3 / 4 absorption with visible image bursts; unlock it at rank 2. |
| `ritual_circle` | unlock/passive | Ritual duration is x1.10 / x1.25 / x1.40; unlock Mage Light at rank 1 and Ward at rank 2. |
| `bound_servant` | unlock/passive | The owned servant lasts 400 / 600 / 800 ticks; unlock Summon Servant at rank 2. |
| `ward_scribe` | unlock/passive | Wards absorb 1 / 2 / 3 explosion destructions; unlock Stone Ward at rank 2. |

### Mender

| Skill | Kind | Exact observable rank effect |
|---|---|---|
| `field_dressing` | unlock/passive | Rank 1 unlocks Mend Wounds; effective healing gains +1 / +2 / +3 health. |
| `triage` | unlock/passive | Healing a target below half health gains 10% / 20% / 30%; unlock Restore at rank 2. |
| `second_breath` | active | Spend fatigue to heal self for 8 / 11 / 14. |
| `herbal_lore` | unlock/passive | Plant foods restore 0.5 / 1.0 / 1.5 fatigue; unlock Purify at rank 1. |
| `clean_brew` | passive | Beneficial food and potion effect duration is x1.10 / x1.20 / x1.30. |
| `green_thumb` | passive | Mature-crop harvest restores 0.1 / 0.2 / 0.3 fatigue within a tick cap. |
| `safe_haven` | active/unlock | Restore 4 / 6 / 8 fatigue and place a short regeneration haven; unlock Ward at rank 1. |
| `protective_mark` | unlock/passive | Ward and Aegis absorption increases by +2 / +4 / +6; unlock Aegis at rank 2. |
| `sanctuary_bell` | unlock/passive | Sanctuary radius is 6 / 8 / 10; unlock it at rank 2. |

### Tinker

| Skill | Kind | Exact observable rank effect |
|---|---|---|
| `circuit_sense` | passive | Crosshair inspection within 4 / 6 / 8 blocks reports signal strength; rank 2 adds configured delay, rank 3 adds the nearest source direction. |
| `compact_gate` | passive | Remote Trigger range becomes 6 / 8 / 10 blocks and recovery shortens by rank. |
| `remote_trigger` | active | Activate one authorized visible lever/button/dispenser/dropper/repeater/comparator/detector within 6 / 8 / 10 blocks. |
| `field_mod` | active | A held tool gains a Haste/tuning burst at rank I / II / III. |
| `quick_repair` | active | Consume one matching repair material and repair the first damaged gear item in stable equipment/inventory order by 15% / 25% / 35% maximum durability. |
| `tool_tune` | passive | Every 8th / 6th / 4th durability event is preserved deterministically. |
| `charge_pack` | active | Consume one TNT and place one owned controlled charge. |
| `blast_shape` | passive | Reduce self-inflicted explosion damage by 15% / 30% / 45%. |
| `safe_fuse` | active | Remove one visible owned, undetonated charge within 4 / 6 / 8 blocks and atomically refund its TNT. |

## Spell semantics

All spells require a focus, sufficient INT, fatigue, a learned and prepared spell, and a legal target. A spell cooldown is at least ten ticks and defaults to `circle * 20`. Spell rays never damage players or LAN ghosts unless the existing PvP policy explicitly authorizes it. World-mutating spells require build permission.

| Spell | Circle / INT | Truthful effect |
|---|---|---|
| `ignite` | 1 / 9 | Range 12; deal 4 fire damage and 120 fire ticks to one legal hostile, or place fire on an authorized replaceable block face. Cost 2. |
| `frost_ray` | 1 / 9 | Range 14; deal 3 damage, Slowness I for 120 ticks, and 160 freeze ticks. Cost 3. |
| `shock` | 2 / 11 | Range 16; deal 5 damage; if wet, chain 3 damage to the nearest legal hostile within 4 blocks, stable distance/ID order. Cost 4. |
| `storm_aura` | 3 / 13 | For up to 300 ticks, damage legal hostiles in the skill-scaled radius for 2 each second. Cost 6 plus 1 fatigue/second. |
| `blur` | 1 / 9 | Apply Invisibility for the skill-scaled duration. Cost 2 plus 0.25 fatigue/second. It does not claim an unimplemented accuracy formula. |
| `decoy` | 1 / 9 | Place one owned radius-3 distraction cloud for 200 scaled ticks; legal hostiles inside receive Glowing and Slowness. Cost 3. It does not claim true aggro AI. |
| `shadow_step` | 2 / 11 | Cost 5 to move to a visible dark destination within skill-scaled range only when line of sight, solid floor, body/head room, and collision checks pass. |
| `mirror_image` | 3 / 13 | Apply the exact `mirror_work` Invisibility/Speed effects and image-burst particles. Cost 6 plus 0.5 fatigue/second. No image entities are claimed. |
| `mage_light` | 1 / 8 | Place one temporary owned light for 1,200 scaled ticks without consuming a torch; guarded cleanup restores only the cell it replaced. Cost 2. |
| `ward` | 1 / 8 | Protect one targeted block from explosion replacement for 600 scaled ticks. Cost 3. |
| `summon_servant` | 2 / 11 | Spawn at most one owned nonpersistent servant for the `bound_servant` duration; cleanup on every terminal transition. Cost 6 plus 0.5 fatigue/second. |
| `stone_ward` | 3 / 13 | Protect the bounded `ward_scribe` block pattern from explosions. Cost 7. |
| `mend_wounds` | 1 / 8 | Heal self or one touched legal non-player ally for 5 plus typed bonuses. Cost 3. |
| `restore` | 2 / 11 | Heal self or one touched legal non-player ally for 8 plus typed bonuses and remove the first present effect in stable order: poison, wither, weakness, slowness. Cost 5. |
| `purify` | 1 / 8 | Remove poison, hunger, and nausea from self or one touched legal non-player ally. Cost 2; it does not rewrite food items. |
| `aegis` | 2 / 11 | Give self or one touched legal non-player ally 4 plus typed bonus absorption and Resistance I for 240 ticks. Cost 5; it has no upkeep. |
| `sanctuary` | 3 / 13 | For 300 ticks, apply outward velocity and Weakness I once per second to legal hostile mobs in the skill-scaled radius. Cost 8. |

## XP events and anti-farm bounds

`RPGXPEvent` is the only RPG XP proposal and `rpgAwardXPEvent` is the bounded, saturating gate. RPG XP is distinct from vanilla enchantment XP. Kills must be causally attributed and only hostile, non-player entities qualify; passive animals, players, self-damage, rejected actions, ineffective healing, Creative actions, and rejected/stale transactions never award XP. The curve is `20 × (level - 1)² + 30 × (level - 1)`, so level 2 starts at 50 XP and level 20 is exactly 7,790 XP.

| Path | Event | Award and qualification |
|---|---|---|
| Warden | hostile melee defeat | 10, only when the Warden's legal melee damage is the causal defeat. |
| Warden | mitigation milestone | 2, when one bounded Interpose layer absorbs at least 2 damage from registered live hostile attackers. Up to eight owner/sequence layers are retained FIFO; unowned absorption is consumed first, nonhostile damage consumes without credit, and a full layer queue rejects the whole action before spend. |
| Ranger | hostile ranged defeat | 10, only for a causally owned arrow/projectile defeat. |
| Ranger | chunk discovery | 3, first qualifying dimension/chunk key only. |
| Delver | depth milestone | 3 once for first descent below each persisted threshold: Y 32, 16, 0, -16, -32, -48. |
| Delver | dungeon container | 12 once before rolling a generated container whose nonempty `lootTable` provenance came from world generation. Player-placed containers have no provenance and never qualify. |
| Delver | deep excavation | 4 for a legally harvestable hard-stone/ore block below Y 63 in the Overworld, keyed by exact dimension/position. |
| Arcanist | hostile spell defeat | 10, only for a causally owned spell defeat. |
| Arcanist | spell practice | 6 for the first successful effect-producing cast of each registered spell index in a 1,200-tick window. World-day changes do not reset the mask. |
| Mender | effective ally healing | `floor(causalHealthDelta / 2)`, capped at 8 and requiring at least 2 causal health. The ally must have an unexpired hostile-injury token; self, overheal, unrelated damage, and absorption-only hits award zero. |
| Mender | cleanse/rescue | 4 when a valid hostile-injury token exists and either a negative effect is actually removed or causal healing crosses from at/below 25% to above 25% health. Restore can award at most one combined cleanse/rescue bonus. |
| Mender | provision craft | 6 per actually completed output round for positive-food items whose optional effects are all explicitly beneficial. Harmful/unknown food effects fail closed. |
| Tinker | first recipe craft | 4 once per qualifying recipe key. |
| Tinker | mechanism construction | 2 once per dimension/position key when an authorized registered mechanism is placed into a powered circuit. Removal does not clear discovery. |
| Tinker | engineering craft | 6 per actually completed output round for registered circuit components or non-weapon tools. A fresh qualifying recipe batch can award one first-recipe event plus at most seven engineering events in the same window. |

Every one of the three starter choices in a path shares a verified level-1 progression loop; no starter is stranded behind a later unlock:

| Path | Clear first progression path to level 2 |
|---|---|
| Warden | Five causally owned hostile melee defeats (`5 × 10 = 50`), with mitigation milestones as an alternate combat source. |
| Ranger | Seventeen loaded-chunk discoveries across the bounded windows (`17 × 3 = 51`). |
| Delver | Thirteen legal deep excavations across the bounded windows (`13 × 4 = 52`). |
| Arcanist | Nine successful effect-producing practice casts across global windows (`9 × 6 = 54`); each starter begins with a usable spell and a focus. |
| Mender | Nine completed qualifying provision outputs (`9 × 6 = 54`), while causal healing/cleanse rewards provide the support-combat alternative. |
| Tinker | One new engineering recipe plus seven engineering outputs in the first window (`4 + 7 × 6 = 46`), then one engineering output after rollover (`+6 = 52`). |

Deduplication is persisted and exact: six Delver depth bits, a seventeen-bit per-window spell mask, a registry-indexed recipe bitset, and one stable 64-entry recent-event ring shared by all categories. Ranger discovery, generated dungeons, mechanisms, and excavation identities can become eligible again only after their exact key rolls out of that ring; progression never permanently stops at 64 discoveries. Saves from the earlier lifetime-key shape merge those keys deterministically into the recent ring on decode, while new saves no longer encode a lifetime store. Event keys are at most 64 UTF-8 bytes.

Each category has a 1,200-tick window and an event-count cap: combat 6, explore 8, depth/dungeon 8, cast 8, heal 8, engineer 8. These are event counts, not XP totals. Once a cap is consumed, a later discrete event is dropped in full; awards are never partially split. A forward window rollover resets only category counts and the distinct-spell mask while preserving the recent ring and persistent milestone/recipe bits. A backward or out-of-range tick/day rejects the entire proposed batch byte-for-byte; untrusted time is never clamped into eligibility and never resets history.

One monotonic `GameCore` RPG simulation tick is persisted in `WorldRecord`, copied to every loaded dimension, and advanced once per authoritative fixed step. Legacy saves derive it from the greatest bounded dimension time. It drives action staleness, cooldown/fatigue evolution, XP windows, pulses, expiry, and off-dimension cleanup. LAN clients do not speculatively advance it or consume authoritative RPG state; replication adopts only valid host ticks and cannot rewind the clock.

Mender hostile-injury provenance is session-only and belongs to a registered, live, non-player, nonhostile entity. It records only actual post-mitigation/post-absorption health loss from a registered live hostile, accumulates and refreshes for 1,200 ticks, and is capped by both maximum and missing health. Every effective heal reduces the outstanding hostile remainder before unrelated missing health can qualify. An XP-awarding support transaction prevalidates and clears the exact nonce before healing and publishes one RPG revision; capped/non-awarding healing receives no explicit XP clear but still reduces the remainder by the health actually restored. Natural healing that reaches zero clears the active nonce/expiry while retaining its monotonic generation, preventing stale prepared actions from aliasing later injuries.

## Persistence, migration, and repair

`RPGCharacterState` schema v2 persists `schemaVersion`, `specializationBranchID`, `starterSkillID`, kit markers, bounded XP dedup state, and an authority revision. Quick-slot preferences are local data and are not part of authoritative RPG state.

- Missing schema is v1. A future schema fails the RPG portion to uncreated while preserving the base player/save.
- Migration chooses an explicitly inferable old starter when unique. Otherwise it chooses the branch with greatest valid spend, ties broken by path branch registration order.
- Repair deterministically replays known ranks in skill-registry then rank order, admitting only path-valid, gate-valid, attribute-valid, prerequisite-valid, affordable ranks. Invalid ranks are dropped/refunded; repair never converts them into different ranks.
- Level is derived from clamped XP. XP additions saturate and level advancement iterates at most nineteen times.
- Decode bounds apply before normal collection allocation where possible and after decode again: at most 54 known skill keys, 17 known spells, 4 unique prepared actives, 6 unique prepared spells, 32 unique cooldowns, 16 unique upkeeps, 9 local quick slots, and registry-bounded selected IDs. IDs are at most 64 UTF-8 bytes.
- Cooldowns/upkeeps are stable-deduplicated and their ticks/costs are finite and clamped. Attributes, fatigue, health, absorption, pose, and velocity reject nonfinite data.
- Action sequence, authority revision, and request counters are `0...1_000_000_000` and use checked increments. At exhaustion every mutation fails without state change and returns an authoritative terminal error; counters never wrap or roll over.

## Bounded transients and cleanup

Mage lights, deadfalls, wards, fortifications, decoys, havens, charges, and servants are world-owned transient records. The cap is two per type per owner and 32 total per world, including deferred restorations. Before creating one, expired records receive guarded cleanup; if capacity still cannot be retained, creation is rejected before materials or fatigue are spent. Records are never silently evicted.

Block cleanup stores prior and placed cells and restores only if the current cell still equals the placed cell. Entity cleanup uses owned stable IDs. Expiry, owner death, disconnect, dimension change, world-rule disable, save unload, and upkeep termination all trigger cleanup. Deferred cleanup remains counted until it succeeds or the world proves the target no longer needs restoration.

## LAN protocol v6 and authority

Protocol v6 appends typed RPG request/ack message kinds. Every RPG frame has a 64 KiB cap checked before JSON decode; the broader LAN frame cap does not weaken it. Variable collections and ID byte lengths are bounded in custom decoders.

Every create/learn/rank/attribute/prepare/unprepare/action request carries a bounded `requestID`, `expectedRevision`, and exact-next `sequence`. A client permits one pending mutation, performs no optimistic authoritative mutation, and ignores stale acknowledgements. The host retains a 32-entry per-peer request/ack replay cache, returning the prior ack for an exact duplicate without reapplying it.

An owner-only ack contains the complete repaired authoritative RPG state without quick slots, plus authoritative inventory, pose, velocity, health, absorption, and bounded status effects. The client merges its local quick-slot preferences after applying the ack. Every rejection carries the same owner resync. Ordinary peer snapshots remain lean.

The host accepts a mutation only for an accepted, alive, non-respawning peer in an RPG-enabled world. It checks dimension, loaded target, range, line of sight, equipment/focus, fatigue, cooldown, materials, build/container authorization, and existing PvP/PvE policy. Player and ghost damage is rejected unless that policy explicitly permits it. World mutation requires build permission; container inspection requires container permission.

Actions use preflight then one commit. `LANRPGActionOutcome` atomically includes RPG state, inventory/durability, health/status, pose/velocity, world deltas, and sequence. Ordinary guest melee outcomes also persist awarded RPG XP. Delayed entity-owned progression (including layered Warden mitigation) must flow back through the authoritative peer record/broadcast callback; a cached ghost mutation may never exist only in a detached actor or be overwritten by a later session snapshot. There is no ghost-only debit, free placement, lost refund, or client-authored effect.

One monotonic GameCore simulation tick advances cooldowns and fatigue for every accepted peer across dimensions. Gameplay upkeep runs only when the owner's ghost and same-dimension world are loaded; time-based expiry and cleanup do not freeze. Disconnect/dimension/death/rule transitions terminate owned upkeep/transients.

## Character sheet, controls, and accessibility

The UI Design Review conditions below are part of the implementation contract. They are not optional polish and may not be replaced by a flat list, implicit click behavior, color-only state, or screenshot-only verification.

### Pure screen model and canonical evaluation

`RPGScreenModel` is a pure PebbleCore projection. Drawing, focus movement, accessibility queries, and hover inspection never repair or mutate live gameplay state. The model receives a repaired authoritative state, client-local quick-slot preferences, the current pending-request presentation, viewport size, tab, selection, and scroll offsets; it produces bounded, deterministic rows and semantic elements.

`rpgEvaluateSkillPurchase` is the sole evaluator used by both `rpgLearnSkill` and the UI. For the exact next rank it returns at most one canonical failure in this order:

1. character not created;
2. unknown or cross-path skill;
3. authority revision exhausted;
4. already at maximum rank;
5. insufficient level;
6. first unmet attribute requirement in registry order;
7. missing immediately previous branch node at rank 2;
8. insufficient skill points.

A live created-character Skills projection contains exactly the current path's three branches, nine skills, and 27 rank cells. The selected specialization and the other two same-path branches remain visible; skills belonging to the other five paths do not enter the live drawing, focus, hit-test, keyboard/controller, or accessibility model. A rank cell below or equal to the current rank is `purchased`; a cell more than one rank ahead is `requires prior rank`; only the exact next cell uses the authoritative evaluator above. Each of the 27 live rank cells exposes exact rank delta text, point cost, selected- or cross-branch level gate, attribute gate, prerequisite, purchased/current state, and one canonical reason. Across six deterministic path fixtures, these projections cover all 162 registry rank cells exactly once under globally unique stable IDs. The UI must not discover legality by mutating a copy and comparing strings.

### Four-step character creation

Creation is one ordered four-step flow: **Path -> Branch -> Attributes -> Review**.

1. **Path** shows all six paths with icon, role summary, primary attributes, and recommended preset. First selection of a path applies `rpgCreationPreset`; returning to a path restores that path's local draft rather than discarding edits.
2. **Branch** shows the path's three registered branches. The free starter is always that branch's Foundation (`branch.skillIDs[0]`), validated as a member of `path.starterSkillIDs`; code must not zip the two arrays because their orders are not universally identical. Each card shows Foundation rank-1 effect, passive/active kind, and automatically unlocked starter spells.
3. **Attributes** permits values `6...14`, requires an exact total of 42, shows remaining pool, offers Reset to Preset, and highlights the selected Foundation's first unmet requirement. Next remains disabled with the canonical reason until both budget and starter requirement are valid.
4. **Review** shows path, specialization, free Foundation rank, the exact one-time kit entries, automatically known/prepared spells, focus requirement where applicable, the class's truthful first-XP loop, keyboard chords, controller summary, and inventory-capacity/server-authority caveat. The UI sends an empty starter-spell list so creation derives the complete legal set from the selected Foundation; it does not expose a redundant spell multiselect.

The large layout (`520x330` and above) uses a three-by-two path grid, three branch columns, and a two-pane Attributes/Review composition when space permits. The compact layout below `520` uses two path columns, three full-width branch cards, and one vertically virtualized content pane. At `360x224`, header, step/tabs, status, and Back/Next/Create/Close controls remain fixed and fully visible; only the content pane scrolls. At `700x420`, content may expand but never changes semantics or focus order.

### Five-tab character shell

After creation the stable tab order is **Character, Skills, Actives, Spells, Progression**.

- **Character** shows path, specialization, level/XP, fatigue, attributes, derived stats, available skill/attribute points, next actionable milestone, and the first-XP guidance until level 2.
- **Skills** presents exactly the current path's three registered branch columns in registry order: nine skills and 27 rank cells. Foundation, Technique, and Mastery cards remain visible as distinct nodes; selecting a node only opens its inspector. `Rank Up` is a separate, labeled action. Other paths are excluded rather than presented as permanently invalid choices.
- **Actives** shows only active skills belonging to the character's path. It exposes separate `Prepare`, `Unprepare`, `Select`, and `Assign Slot` actions. An unknown active links back to its Skills node and cannot be ranked from this tab.
- **Spells** shows only spells reachable from the character's path skill registry. Every row names the exact unlocking skill/rank and shows circle, INT, fatigue, target/range, known/prepared/selected/slotted state. Non-casters receive a truthful empty state rather than all seventeen spells.
- **Progression** presents levels 1 through 20, absolute XP thresholds, earned SP/AP, banked points, specialization purchases, attribute milestones, actual completion, and build divergence warnings.

The specialization roadmap is guidance, not a hidden restriction. Its full-branch purchases are Foundation II at level 4, Technique I at 5, Foundation III at 8, Technique II at 10, Mastery I at 12, Technique III at 14, Mastery II at 16, and Mastery III at 20. The free Foundation I plus those ranks costs 17 earned points. Level 20 provides 19 earned points, leaving exactly 2 for one cross-branch Foundation I. Cross-branch rank gates remain two levels later and costs remain one point higher; cross-branch Mastery III remains truthfully shown as unreachable at level 22. Before any legal cross-branch purchase, the inspector reports whether the remaining points earnable through level 20 can still finish the selected specialization; it warns but does not invent a restriction or respec.

Rows/cards select only. No click, focus change, hover, tab change, or slot destination selection implicitly ranks, prepares, unprepares, selects, assigns, or uses an action. Gameplay mutation requires the explicit labeled control associated with the current inspector.

### Local quick slots and LAN pending/error states

The nine quick slots are local preference, never host authority. Assigning, moving, or clearing a slot does not change `selectedPreparedActionID`, `selectedPreparedSpellID`, `authorityRevision`, `actionSequence`, or any owner/inventory revision, and it sends no LAN request. Explicit `Select` is the only character-sheet selection mutation. Owner acknowledgements exclude quick slots; client application preserves local slots and removes only tokens that no longer name acknowledged prepared actions.

Only one authoritative LAN mutation may be pending. The screen presents the following exhaustive state matrix:

| State | Authoritative controls | Local slot controls | Presentation and transition |
|---|---|---|---|
| Single-player/host commit accepted | Re-enable after synchronous commit | Enabled | Apply repaired result, announce bounded success, rebuild model, preserve semantic selection, clamp scroll. |
| Local semantic rejection | Enabled | Enabled | Leave authoritative state byte-for-byte unchanged and show the canonical reason beside the attempted control. |
| LAN request awaiting disposition | Disabled, including Create/Rank/Prepare/Unprepare/Select/Attribute | Enabled | Show `Awaiting host` plus bounded operation label; never predict success or mutate authority. Closing the screen does not discard durable pending work. |
| Accepted owner ack | Disabled until the complete owner checkpoint commits | Enabled | Atomically apply owner state, then announce success, clear pending, rebuild, preserve valid local slots, and clamp/focus the acknowledged item. |
| Rejected owner ack | Disabled until the complete owner resync commits | Enabled | Apply the same complete owner resync, clear pending, retain the local draft/selection where still valid, and show the host reason. |
| Disconnect/incomplete bundle | Disabled | Enabled | Retain durable pending state and show reconnect/retry status; never enqueue a duplicate from drawing or reopening. |
| Disposition-only or outcome-evicted delivery | Disabled until durable checkpoint/notice commit | Enabled | Do not install the disposition owner payload; render the one durable terminal notice exactly once. |
| Authority exhausted | Disabled permanently for that owner | Enabled only for already valid local tokens | Show the terminal exhaustion reason; never wrap, retry as a new ID, or imply recovery. |
| `rpgClasses` disabled while open | None | None | Dismiss the sheet after synchronous cleanup and show `RPG classes are disabled in this world`. |

Status copy is bounded and persistent until replaced by the next attempted operation or acknowledgement. Success, pending, rejection, cooldown, fatigue, missing focus/equipment, and permission failure use distinct icon/text treatments and do not rely on color.

### Scrolling, virtualization, and semantic focus

The required layout probes are exactly `360x224`, `520x330`, and `700x420` GUI units. Creation panes, branch columns, Actives, Spells, Progression, and the expanded Controls list use bounded virtualization: model rows exist in stable registry order, drawing visits only rows intersecting the viewport, and hit testing/semantic activation use the same geometry. No partially clipped control is actionable.

Every offset is clamped to `0...max(0, contentHeight - viewportHeight)` after open, resize, GUI-scale change, step/tab change, filter/content change, selected-item expansion, rank/prepare mutation, owner acknowledgement/resync, tutorial transition, and focus-driven reveal. Empty/short content forces zero. Scrollbars report the same content/viewport/offset values used by drawing and hit testing.

`RPGUIElementID` is stable and semantic: creation step/path/branch/attribute/review IDs, tab IDs, `skill:<id>:rank:<1...3>`, action/spell IDs, slot `0...8`, and explicit operation IDs. Tab/Shift-Tab traverses enabled and informational semantic elements in stable order; arrows move spatially within grids/columns; Enter/Space activates the explicit focused control; Escape backs one creation/tutorial step before closing. Focus never disappears after mutation: retain the same ID when legal, otherwise choose the nearest preceding legal element and reveal it.

### AppKit accessibility substrate

The custom Metal canvas must expose a real AppKit accessibility tree. `Screen` supplies bounded semantic descriptors and activation by `RPGUIElementID`; `UIManager` owns the current semantic revision; `GameView` publishes main-thread `NSAccessibilityElement` children. Elements expose role, label, value/rank, selected/prepared/slotted state, enabled/locked state, canonical reason/help, frame, and press action. Tabs are a tab group; the creation wizard and each branch are groups; virtualized lists are scroll areas.

All 27 rank cells belonging to the live character's path remain discoverable to accessibility even when offscreen. The Skills accessibility root identifies the current path and reports its three-branch, nine-skill, 27-rank scope. The other 135 registry rank cells are not attached to the live accessibility tree. Focusing or pressing an offscreen path-valid element first scrolls it into view through the same clamp function. Accessibility nodes are rebuilt only when semantic revision, layout, or viewport changes, never every rendered frame. The app posts focused-element, value-changed, and layout-changed notifications only after the corresponding committed state transition. The visible focus ring is shared by keyboard, controller, and VoiceOver focus. High Contrast changes borders/fills in addition to color; Reduce Motion removes tutorial/selection animation without removing state feedback.

### Configurable keyboard chords and Controls layout

The existing persisted keybinding map gains these exact actions and defaults:

| Action key | Default chord |
|---|---|
| `rpgCharacter` | `KeyK` |
| `rpgCycleAction` | `KeyO` |
| `rpgUseAction` | `KeyL` |
| `rpgQuickSlot1` ... `rpgQuickSlot9` | `Shift+Digit1` ... `Shift+Digit9` |

A persisted chord is one internal key code optionally preceded by unique modifiers in canonical `Command+Control+Option+Shift+Key` order. Existing one-key values remain valid. Unknown keys, repeated modifiers, modifier-only values, strings over 64 UTF-8 bytes, or malformed separators fall back only that action to its default. Capture shows the complete chord, Escape cancels capture, and Reset restores the one default. Conflicts are displayed beside both actions and require an explicit second activation to accept; they are never silently rebound.

The Controls tab becomes a clamped virtualized list so all existing and RPG bindings are reachable at `360x224`. Character, cycle, use, and all nine slot chords are configurable. Matching uses the saved chord rather than fixed K/O/L/digit comparisons. Unmodified digits continue to select the normal hotbar; only the configured full chord invokes an RPG slot. The `rpgClasses` rule gates the sheet, HUD row, keyboard/controller routes, local action paths, and LAN requests in Survival and Creative.

### RPG-scoped GameController contract

GameController support in this feature is explicitly RPG-scoped; documentation and UI must not claim general controller movement/gameplay support. Controller input is converted to the same bounded semantic commands as keyboard input and never calls progression/network mutators directly.

- In the sheet, D-pad/left-stick moves focus, A activates, B backs/closes, left/right shoulder changes tab, and right-stick vertical input scrolls with hysteresis and bounded repeat.
- In world mode, Options opens Character, left shoulder cycles the prepared action, and right shoulder uses the selected prepared action.
- Holding left trigger maps slots 1...4 to D-pad Up/Right/Down/Left, slots 5...8 to face buttons Y/B/A/X in spatial clockwise order, and slot 9 to right-stick click.
- Connect, disconnect, focus loss, and screen transition clear held/repeat state. Inputs already held at connection or context change do not fire. Analog trigger/stick thresholds use enter/exit hysteresis; one physical edge yields at most one mutation request.

Controller glyph/help copy switches only after a real controller input and keyboard help remains available. Synthetic mapping tests are necessary but cannot replace installed proof with a physical compatible controller when controller support is claimed verified.

### Tutorial persistence and installed design coverage

Tutorial state is local UI preference, not authoritative RPG/player/LAN state. `RPG_TUTORIAL_VERSION = 1`; an optional `rpgTutorialVersion` setting decodes missing/invalid values as zero. The first accepted character-sheet entry with a lower seen version opens four pages: rank branch skills; prepare and explicitly select actions; choose and assign a local slot; close the sheet and use configured keyboard/controller chords. Back/Next/Finish/Skip are keyboard-, controller-, and accessibility-operable. Only Finish or explicit Skip persists the current version; merely opening or crashing does not. Raising the version re-presents revised guidance. First-XP-loop guidance remains on Character through level 1 regardless of tutorial status.

Design Sign-off uses the fresh installed `/Applications/Pebble.app`, not source inspection alone. The installed harness builds six deterministic path fixtures. Each fixture must enumerate exactly three branches, nine skill nodes, and 27 rank cells; their aggregate must enumerate exactly six paths, eighteen branches, fifty-four skill nodes, and 162 rank cells, with every global semantic ID unique and every registry rank represented exactly once. This aggregate is sign-off data and must not be published as one live accessibility tree. Designer inspection covers all six creation Review states, all eighteen specialization branch/roadmap states, every one of the fifty-four node inspectors and their three rank cells, caster and non-caster Actives/Spells empty and populated states, tutorial, local-slot independence, accepted/pending/rejected/error states, High Contrast and Reduce Motion, and each required viewport. Automated screenshots/semantic dumps support this inspection but do not replace physical keyboard navigation, VoiceOver press/focus proof, or physical controller proof.

## Required implementation and verification order

1. Keep this contract current.
2. Implement v2 core, migration/repair, attributes, kits, typed effects, and XP.
3. Implement every skill/spell semantic and bounded transient.
4. Implement protocol-v6 authority, peer ticking, atomic outcomes, ack/resync, and quick-slot separation.
5. Implement the pure screen model, four-step creation, five-tab shell, configurable chords, semantic focus, RPG-scoped controller adapter, AppKit accessibility bridge, tutorial, and HUD feedback.
6. Run the independent Security code review against the actual UI/input/accessibility diff and fix findings; material fixes repeat this gate.
7. Install the reviewed candidate and obtain Design Sign-off across all required states/viewports with physical keyboard, VoiceOver, and compatible-controller proof. Unseen or unavailable surfaces remain unsigned.
8. Run the independent Tester/regression pass, then `bash scripts/security-scan.sh`, warning-free `swift build -c release`, `swift test`, `swift run -c release pebsmoke`, and `bash scripts/pipeline.sh`. Any golden movement must be individually reviewed; the prior 457-check count is not changed merely to hide failure.
9. Verify the final fresh `/Applications/Pebble.app`, then run `scripts/live-lan-test.sh --deploy --timeout 90` against Neo with probes for cooldown/fatigue/upkeep advancement, XP/inventory persistence, rejection resync, permission denial, replay, disconnect cleanup, owner-state convergence, pending UI convergence, and local-slot preservation. Any later runtime-path change invalidates and repeats affected Security, Design Sign-off, Test, deploy, and LAN evidence.
10. Commit logical changes with specific staging and co-author tags. Do not push without separate authorization.

## Conditions for Builder

- Across the six installed path fixtures, every one of the 162 registry skill ranks has an observable typed effect and semantic test; each live fixture contains exactly its path-valid 27 rank cells. All seventeen spells have semantic tests.
- The pure `RPGScreenModel` and canonical `rpgEvaluateSkillPurchase` are implemented before UI mutation wiring; drawing, focus, hover, and accessibility queries are side-effect free, and evaluator/mutator parity is exhaustive.
- Each live path fixture contains exactly its three branches, nine nodes, and 27 rank cells under stable semantic IDs, with no cross-path cells. The six-fixture aggregate contains all six paths, eighteen branches, fifty-four nodes, and 162 globally unique rank-cell IDs exactly once. Spell projection is class-accessible only and names every exact unlock skill/rank.
- Every path has its truthful viable level-1 loop and every specialization has meaningful reachable milestones at levels 4, 5, 8, 10, 12, 14, 16, and 20.
- Level 20 permits exactly one complete specialization for 17 earned points plus one cross-branch Foundation I for 2, with no excess or negative points. The UI shows the selected/cross gates and warns truthfully when optional spend makes capstone completion impossible without blocking legal spend.
- Character creation is exactly Path -> Branch -> Attributes -> Review, uses the path preset without discarding restored drafts, derives the free Foundation from the chosen branch, shows the exact kit/focus/first loop, and does not expose manual starter-spell selection.
- The post-creation shell is exactly Character, Skills, Actives, Spells, Progression. Rows select only; Rank Up, Prepare, Unprepare, Select, Assign Slot, and Clear Slot remain separate semantic operations.
- Local quick-slot assign/move/clear changes no authoritative selection, action sequence, authority/owner/inventory revision, or LAN state. Explicit Select is authoritative, and complete owner acknowledgements preserve only still-valid local tokens.
- A LAN client allows one durable pending authoritative mutation, performs no optimistic authority mutation, and implements every accepted/rejected/disconnected/disposition-only/evicted/exhausted transition in the pending/error matrix before re-enabling controls.
- The `360x224`, `520x330`, and `700x420` probes have no clipped actionable controls, stale hit boxes, lost focus, or out-of-range scroll. Every resize/content/ack/tutorial transition reclamps through the one shared function.
- K/O/L and Shift+1...Shift+9 are persisted configurable chords with legacy one-key compatibility; Controls remains fully reachable at the minimum viewport and unmodified digits keep normal hotbar semantics.
- Keyboard, RPG-scoped controller, and AppKit accessibility invoke the same semantic commands. Accessibility exposes role/label/value/state/reason/action for all content, and controller support is never described as general gameplay controller support.
- Tutorial version is local, backward-compatible, written only by Finish/Skip, and independent of authoritative player or LAN data.
- XP, decoders, collections, arithmetic, transients, entity ownership, and frames are bounded and deterministic.
- Host state is authoritative. Rejections converge the owner; inventory, RPG, pose, health, effects, durability, and world mutation commit atomically.
- Registration order and saved IDs remain compatible; `apprentice_focus` is append-only.
- Design Mock and Design Review PASS before UI build. Security code review PASS precedes installed Design Sign-off; unseen or source-only UI cannot pass.
- Installed Design Sign-off proves the per-path counts of 3/9/27 and the six-fixture aggregate counts of 6/18/54/162, including global ID uniqueness and exact registry coverage. It physically proves representative mouse, keyboard, VoiceOver, and compatible-controller actions across the three required viewports. Any unavailable physical surface is reported unverified, not inferred from synthetic tests.
- Existing non-RPG gameplay, old saves/settings/keybinds, LAN behavior, security scans, tests, smoke goldens, installed play, and Neo proof remain green. Any post-install runtime-path change invalidates and repeats affected sign-off, pipeline, deploy, and LAN evidence.
- Documentation and UI copy describe only behavior proven by the implementation.

## Historical inspiration and primary local references

The Fantasy Trip documents were design inspiration for meaningful attributes, fatigue, and readable choices, not a claim that Pebble implements TFT rules: [Melee rules](/Users/mweingar/Downloads/_Documents/The%20Fantasy%20Trip%20Melee%20Rules.md) and [Wizard rules](/Users/mweingar/Downloads/_Documents/The%20Fantasy%20Trip%20Wizard%20Rules.md).

Implementation sources of record are [CharacterProgression.swift](/Users/mweingar/dev/pebble/Sources/PebbleCore/Game/CharacterProgression.swift), [RPGActions.swift](/Users/mweingar/dev/pebble/Sources/PebbleCore/Systems/RPGActions.swift), [LANMultiplayer.swift](/Users/mweingar/dev/pebble/Sources/PebbleCore/Net/LANMultiplayer.swift), [LANTransport.swift](/Users/mweingar/dev/pebble/Sources/Pebble/LANTransport.swift), [RPGScreensM.swift](/Users/mweingar/dev/pebble/Sources/Pebble/RPGScreensM.swift), [ARCHITECTURE.md](/Users/mweingar/dev/pebble/ARCHITECTURE.md), [SECURITY.md](/Users/mweingar/dev/pebble/SECURITY.md), and [AGENTS.md](/Users/mweingar/dev/pebble/AGENTS.md).
