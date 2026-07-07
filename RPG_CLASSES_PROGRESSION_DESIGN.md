---
type: design
title: RPG Classes, Skills, Progression, and Character Creation
description: Detailed Pebble design for class identity, attributes, skills, spells, progression, combat hooks, persistence, LAN authority, and UI.
updated: 2026-07-07
status: implemented
---

# RPG Classes, Skills, Progression, and Character Creation

This document records the RPG layer for Pebble. The intent is to add class identity, skills, attributes, spells, and progression while preserving Pebble's current sandbox survival loop, deterministic engine contract, save hardening, and host-authoritative LAN model.

The design uses the provided *The Fantasy Trip: Melee* and *The Fantasy Trip: Wizard* documents as criteria, not as a literal hex-board port. Pebble is a real-time first-person voxel game, so tactical tabletop concepts are translated into action-game mechanics only where they improve play.

## Implementation Record

The first implementation is complete in the current worktree with these concrete files and guardrails:

- Core model: `Sources/PebbleCore/Game/CharacterProgression.swift` defines six paths, 18 branches, 54 skills, 17 spells, five attributes, class XP/leveling, point spending, prepared skills/spells, fatigue, cooldowns, upkeep, save repair, and `GameCore.requestRPG...` routing.
- Action mechanics: `Sources/PebbleCore/Systems/RPGActions.swift` resolves spell casting through existing world/entity APIs for damage rays, fire/light placement, wards, healing, movement, summons, cooldowns, and upkeep. `Combat.swift` adds derived melee bonus, and `Living.swift` awards RPG XP on kills.
- UI/HUD: `Sources/Pebble/RPGScreensM.swift`, `UICanvas.swift`, `HudM.swift`, `main.swift`, and `GameCore.swift` provide creation, sheet tabs, skill/spell preparation, attribute spending, fatigue HUD, and `K`/`O`/`L` controls.
- Assets: `Sources/PebbleCore/Render/RPGAssetManifest.swift` generates deterministic procedural 16x16 icons for every path, branch, skill, spell, and RPG action. No new binary art, scraped web images, or license-bearing asset files are introduced.
- Persistence: `Player.swift` stores nested `rpg` state in player JSON and repairs it on load. `GameWorld.swift` and `GameCore.swift` default new worlds to the `rpgClasses` game rule.
- LAN: `LAN_MULTIPLAYER_PROTOCOL_VERSION` is now 4, and `LANWorldSummary.rpgClassesEnabled` advertises the host rule to transient clients. `LANRPGIntent` carries typed create/learn/prepare/spend/select/cast proposals. Full RPG state stays host-owned in `LANMultiplayerHostSession`/`LANPeerRecordSnapshot` and app-side `lan_players` JSON; normal periodic player snapshots are lean. Direct RPG-change/restore snapshots may carry full RPG state so the owning client can converge its sheet. Remote casts require an exact-next action sequence and run through `LANHostGhostRegistry` before the host broadcasts player/world/entity deltas.
- Tests: `RPGCharacterStateTests`, `RPGProgressionTests`, `RPGActionTests`, `RPGAssetManifestTests`, plus LAN protocol/replication additions cover save repair, progression rules, spell effects, generated asset coverage, frame round-trip, malformed nested RPG decode, host rejection of client-authored RPG snapshots, lean periodic peer states, restore/full RPG convergence, and ghost hydration with derived stats.

Deliberate implementation differences from the early plan: the code uses `pathID`, `xp`, and `level` names instead of the early `classID`, `classXP`, and `classLevel` sketch; the starting attribute budget is 42 across five attributes rather than TFT's three-attribute 32-point table; and the first LAN implementation does not add separate `LANRPGSummary`/visual-event arrays because the lean/full split above preserves frame budget and authority without adding a second replication channel.

## Source Register

This design references 23 source groups: 14 local Pebble/TFT source groups and 9 external research source groups.

| Source | Type | Used for | Risk note |
|---|---|---|---|
| [AGENTS.md](/Users/mweingar/dev/pebble/AGENTS.md) | Local project rule | Required model-paired process and verification gates | Current repo source |
| [README.md](/Users/mweingar/dev/pebble/README.md) | Local project doc | Current survival loop, XP, crafting, AI, LAN, verification, counts | Current repo source, counts may drift |
| [ARCHITECTURE.md](/Users/mweingar/dev/pebble/ARCHITECTURE.md) | Local project doc | Engine/app split, persistence, test harness, LAN architecture | Current repo source |
| [SECURITY.md](/Users/mweingar/dev/pebble/SECURITY.md) | Local project doc | Untrusted saves, LAN validation, AI boundaries, fail-closed patterns | Current repo source |
| [LAN_MULTIPLAYER_PLAN.md](/Users/mweingar/dev/pebble/LAN_MULTIPLAYER_PLAN.md) | Local project doc | Current LAN protocol, host-authoritative constraints, live Neo probe expectations | Current repo source |
| [Package.swift, pipeline, and asset verification](/Users/mweingar/dev/pebble/Package.swift) | Local project files | SwiftPM split, no Xcode project, built-in asset verification | Current repo source |
| [Player.swift](/Users/mweingar/dev/pebble/Sources/PebbleCore/Entity/Player.swift) | Local code | Health, hunger, XP, inventory, save/load, attack cooldown, movement | Current code; dirty tree not modified here |
| [Living.swift](/Users/mweingar/dev/pebble/Sources/PebbleCore/Entity/Living.swift) | Local code | Health/effects/equipment/armor/damage/death model | Current code |
| [Combat.swift](/Users/mweingar/dev/pebble/Sources/PebbleCore/Systems/Combat.swift) | Local code | Existing melee, bow, trident, mining speed hooks | Current code |
| [Saves.swift and LAN models](/Users/mweingar/dev/pebble/Sources/PebbleCore/Game/Saves.swift) | Local code | JSON player snapshot, `lan_players` rows, LAN protocol caps, replication batch limits | Current code |
| [LAN transport, orchestration, and ghosts](/Users/mweingar/dev/pebble/Sources/Pebble/LANTransport.swift) | Local code | App/core boundary for Network.framework, peer record bridging, ghost-hosted intent execution | Current code |
| [Render/Icon/ResourcePack pipeline](/Users/mweingar/dev/pebble/Sources/PebbleCore/Render/Icons.swift) | Local code | Pack-art preference, deterministic icon fallbacks, particles, HUD rendering, visual test hooks | Current code |
| [The Fantasy Trip Melee Rules.md](/Users/mweingar/Downloads/_Documents/The%20Fantasy%20Trip%20Melee%20Rules.md) | User-provided design criterion | ST/DX, weapon ST thresholds, adjDX, armor, shields, options, force retreat, injury, XP | Local user document |
| [The Fantasy Trip Wizard Rules.md](/Users/mweingar/Downloads/_Documents/The%20Fantasy%20Trip%20Wizard%20Rules.md) | User-provided design criterion | ST/DX/IQ, IQ spell gating, spell fatigue/upkeep, casting checks, spell categories, staff/armor constraints | Local user document |
| [Vintage Story Class wiki](https://wiki.vintagestory.at/Class) | External | Character creation with six classes, buffs/debuffs, beginner-vs-expert framing | Wiki source; likely official/community maintained |
| [Wynncraft class API docs](https://docs.wynncraft.com/modules/classes/get-class) | External | Fixed classes with archetype ratings and role summaries | Primary API docs |
| [Wynncraft ability tree API docs](https://docs.wynncraft.com/modules/ability-aspect/get-ability-tree) | External | Ability trees, requirements, links, locks, pages | Primary API docs |
| [Minecraft Dungeons FAQ](https://www.minecraft.net/pt-pt/article/minecraft-dungeons-launching-may-26) | External | Explicit "no classes" design and gear-defined identity | Official source |
| [Minecraft Dungeons dev blog](https://www.minecraft.net/en-us/article/dungeons-september-dev-blog) | External | Gear-supported archetypes such as Acrobat, Summoner, Soul | Official source |
| [Official Terraria class setups](https://terraria.wiki.gg/wiki/Guide:Class_setups) | External | Gear-defined class paths without formal class locks | wiki.gg blocked terminal fetch but search/open metadata confirmed URL |
| [Portal Knights class wiki](https://portalknights.fandom.com/wiki/Class) | External | Class-linked attributes, weapons, armor, talents | Lower confidence than primary site; official-wiki label but hosted on Fandom |
| [Trove official site](https://trovegame.com/) | External | Voxel MMO class identity and starter class examples | Official source |
| [Cube World overview](https://en.wikipedia.org/wiki/Cube_World) | External | Voxel RPG character creation, classes, specializations, item progression | Secondary source; use only for pattern, not exact mechanics |

## Research Findings

Comparable sandbox or voxel RPGs disagree on whether class should be hard identity, gear expression, or a hybrid:

| Game/system | Observed pattern | Design lesson for Pebble |
|---|---|---|
| Vintage Story | Class is chosen during character creation, with buffs and debuffs. The Commoner all-rounder is safer for beginners. | Pebble should present a neutral all-rounder and be honest about class complexity. |
| Wynncraft | Five Minecraft-server classes, each with archetypes and ability trees. API data exposes class difficulty and archetype axes such as damage, defense, range, and speed. | Pebble can use classes plus trees, but should keep ability data structured and inspectable. |
| Minecraft Dungeons | Official FAQ says there are no classes; identity comes from equipped items. Dev blog still uses internal "archetypes" to support playstyles with gear/artifacts. | Pebble should not hard-lock ordinary sandbox tools. Gear and skills should express a class, not trap the player. |
| Terraria | Classes are largely gear progression tracks rather than formal character choices. | Pebble can let players drift toward a build through equipment and skills after creation. |
| Portal Knights | Classes have primary attributes, weapon families, and talent choices at level milestones. | Attribute and weapon affinity are useful, but overlocking gear risks undermining sandbox freedom. |
| Trove | Voxel MMO with clear class fantasies and starter classes. | Strong class presentation helps identity, especially for multiplayer roles. |
| Cube World | Voxel RPG uses character creation, fixed classes, unique armor/weapons/abilities, and specializations. | Specializations are a good mid-game layer, but region/gear dependency is a known risk to avoid. |

First-principles conclusion: Pebble should use **soft permanent paths**. A player chooses a class/path at character creation for identity, starting kit, default attributes, and cheaper skill access. However, all core survival actions remain available to all players, with penalties or higher unlock costs instead of hard locks. This preserves Minecraft-style sandbox agency while adding RPG depth.

## TFT Criteria Translated to Pebble

The following criteria are load-bearing for the design.

| TFT criterion | Pebble design translation |
|---|---|
| Figures begin with fixed base attributes plus extra points. | Pebble characters start at ST 8, DX 8, IQ 8 plus 8 assignable points for a 32-point starting total. Class presets allocate those points but the player may adjust before confirming. |
| ST is health and weapon/spell power. | ST controls max health bonus, fatigue capacity, heavy weapon readiness, shield-rush strength checks, and spell overexertion tolerance. |
| DX controls action order, hit/cast success, and mishap avoidance. | DX controls cast reliability, bow spread recovery, dodge/defend checks, fumble resistance, and special combat effects. It does not randomly nullify a clean normal melee hit by default. |
| IQ controls known spells and resistance to illusions/control. | IQ gates spell tiers, number of known spells, crafting/lore skills, disbelieve/reveal checks, and resistance to charm/fear/illusion effects. |
| adjDX changes with armor, wounds, range, facing, and posture. | Pebble computes `adjustedDexterity` for spells and special actions from DX plus class/skill bonuses minus armor, wounds, fatigue, movement, range, and target-facing penalties. |
| Armor stops hits but penalizes DX and movement. | Existing armor mitigation remains. The RPG layer adds armor casting/skill penalties and fatigue regen penalties. Heavy armor does not globally slow vanilla walking unless a feature explicitly opts in. |
| Weapons have ST thresholds. | Weapon families have recommended ST for full damage/speed/special effects. Under-ST use is allowed but loses special effects and may suffer cooldown or durability penalties. |
| One option per turn. | Pebble maps this to short action-lock categories: attack, cast, defend, dodge, ready/use, and movement commitment. The player remains in real-time control, but high-impact RPG actions commit the player for a bounded window. |
| Charge, defend, dodge, polearm brace, shield rush, force retreat. | Add sprint-charge, brace, guard, dodge-step, shield-bash, and "force retreat" knockback/stagger windows. |
| Injury creates DX penalties and knockdown. | Add short `staggered` and `winded` status effects after large damage bursts. Avoid long hard crowd control for normal survival mobs. |
| Spell ST costs and continuing upkeep. | Add `fatigue` as spell/body-energy spend. Continuing spells reserve or drain fatigue. Health is not the normal mana bar; overcasting is rare and explicitly opt-in. |
| Missile, thrown, creation, and special spells. | Spell registry has those four categories with different range, line-of-sight, cost, persistence, and LAN validation rules. |
| Wizard staff and armor/weapon restrictions. | Staffs are spell foci. Non-staff weapons, ready shields, and heavy armor apply casting penalties unless skills reduce them. |
| Experience can improve attributes, within limits. | Class progression grants skill points every class level and attribute training points at bounded milestones. Attribute increases are capped and persisted. |

## Architect Plan

### Scope

Build a first RPG layer around the local player and LAN peers:

1. Character creation on new world entry and first entry into old worlds without RPG state.
2. Class/path identity with class-specific starting kits and defaults.
3. ST/DX/IQ attributes, derived health/fatigue/spell slots/weapon readiness.
4. Skill trees and spell learning.
5. Class XP and progression independent from vanilla enchantment XP.
6. Spell and combat-option mechanics that use existing Pebble systems.
7. Save/load, LAN persistence, host-authoritative action validation, and screenshot/test hooks.
8. Complete UI/icon/particle/audio asset coverage through explicit manifest entries and tests.

### Non-goals

- No account-wide characters.
- No public internet matchmaking or cloud sync.
- No mod-loaded class/spell scripts in the first version.
- No hard lock that prevents a non-class player from mining, crafting, building, eating, wearing armor, or using ordinary tools.
- No replacement of existing vanilla XP/enchanting economy.
- No random baseline misses for normal crosshair melee hits.

### Dependency Order

1. Core model: class registry, attributes, skill tree, spell registry, XP curve, validation.
2. Asset manifest: class badges, spell icons, item icons, particle cues, synthesized sound cue names, and UI fallback rules.
3. Persistence: encode/decode `RPGCharacterState` in player JSON and LAN guest records.
4. UI: creation flow, character/progression screen, HUD additions.
5. Passive mechanics: derived max health, fatigue regen, armor/casting penalties, weapon readiness.
6. Progression events: class XP awards from bounded milestones and normal play hooks.
7. Active mechanics: dodge, defend, shield bash, brace, charge, spells.
8. LAN: summaries, intents, host validation, visual events, reconnect tests.
9. Docs, tests, goldens, install proof.

### Conditions for Builder

- Class and skill state must live in PebbleCore and be testable without AppKit.
- The macOS app may draw and route input, but it must not own RPG rules.
- All class, skill, spell, and attribute IDs are static registry strings with deterministic registration order.
- Old saves without RPG data load as "uncreated"; they never crash or invent invalid state.
- Unknown/corrupt class, skill, spell, or attribute values decode fail-closed to bounded defaults.
- Existing XP (`player.xp`, `xpLevel`, `xpProgress`) remains the enchanting/currency XP. RPG progression uses separate `RPGCharacterState.xp` and `RPGCharacterState.level`.
- LAN clients never author raw character state or spell effects. They send typed intents; the host validates class, skill, fatigue, target, reach, cooldown, permission, and world readiness.
- Full RPG state must not be embedded in high-frequency `LANPlayerState`. Full state lives in local/host-owned saves and host peer records; periodic replication carries lean player states, while direct RPG-change/restore states may carry full repaired RPG state to converge the owning client.
- Any new LAN message kind or replication-batch field must append wire IDs, bump `LAN_MULTIPLAYER_PROTOCOL_VERSION`, and add old-version rejection plus worst-case frame-size tests under the 1 MiB cap.
- LAN RPG intents must include a bounded per-peer action sequence. The host accepts only the exact next sequence, rejects duplicates/replays, and asks the client to resync after a jump.
- New item IDs, if any, must be appended after current late-added items and protected by item-prefix smoke tests.
- Every class, skill, spell, focus item, action badge, particle cue, and sound cue must be present in an RPG asset manifest with a concrete source: bundled pack lookup, deterministic procedural generation, existing synthesized audio/particle recipe, or explicitly licensed packaged art.
- Do not add unlicensed downloaded art. Any new binary asset must include license/provenance, be included in packaging, and be covered by `scripts/verify-pack-assets.sh`.
- No unordered collection iteration may affect skill resolution, XP awards, spell target selection, or summon behavior.
- New UI screenshot hooks must be allowlisted and non-mutating unless the hook name explicitly creates a test world.

## Contrary Architect Review

The first draft was directionally sound but under-specified in several places that would break under real multiplayer, packaging, or verification pressure. These findings modify the plan below.

| Finding | Risk | Required design correction |
|---|---|---|
| Full RPG state was easy to accidentally place in high-frequency `LANPlayerState`. | High-frequency batches would grow, leak authority, and make remote clients believe they can repair state locally. | Keep full state in saves and host peer records; keep periodic player states lean; use direct RPG-change/restore states for owning-client convergence. |
| The LAN design did not explicitly handle wire compatibility. | Adding messages without a protocol bump would create decode ambiguity against strict protocol v3 peers. | Append message IDs, bump protocol version, and test old-version rejection and payload type mismatch. |
| Spell/action intents lacked replay protection. | A resent or duplicated frame could double-spend fatigue, double-cast, or double-grant XP. | Add per-peer exact-next `actionSequence` and host-side duplicate/jump rejection. |
| Character creation on LAN was treated like UI state instead of an authority transition. | A guest could spoof attributes, starter kit, or skill points if the client result is trusted. | Guest creation sends a proposed `LANRPGCreateIntent`; host validates, persists, then returns an accepted summary/restore. |
| Visual spell effects were not separated from gameplay effects. | Clients could see damage, summons, or particles before host authority confirms the result. | Host emits cosmetic `LANRPGVisualEvent` only after validation; gameplay state still arrives via normal snapshots/deltas. |
| Art assets were implicit. | Classes/spells could ship with missing icons, fallback boxes, or unlicensed images. | Add an RPG asset manifest, procedural icon path, license gate, pack verification, and screenshot/icon tests. |
| The test plan named useful tests but not enough gate criteria. | Networking, frame size, asset resolution, old saves, corrupt LAN rows, and installed-app proof could remain untested. | Expand unit, fuzz/property, packet-budget, UI screenshot, asset, full pipeline, and two-Mac RPG LAN proof gates. |
| World enablement was left as an open question. | Hosts and clients could disagree about whether RPG creation is required. | Make `rpgClasses` an explicit world rule stored in existing world metadata/game rules and advertised in LAN world summary after the protocol bump. |

## Core Character Model

### Data Types

Early sketch, superseded by the implementation record above. The shipped core file is `Sources/PebbleCore/Game/CharacterProgression.swift` and uses `pathID`, `xp`, and `level`.

```swift
public struct RPGCharacterState: Codable, Equatable {
    public var version: Int
    public var revision: Int
    public var created: Bool
    public var classID: String
    public var attributes: RPGAttributes
    public var attributeIncreases: RPGAttributes
    public var classXP: Int
    public var classLevel: Int
    public var unspentSkillPoints: Int
    public var spentSkillPoints: [String: Int]
    public var knownSpells: [String]
    public var preparedSpells: [String]
    public var selectedSpell: String?
    public var fatigue: Double
    public var cooldowns: [String: Int]
}

public struct RPGAttributes: Codable, Equatable {
    public var st: Int
    public var dx: Int
    public var iq: Int
}
```

Validation clamps:

- `version`: known range only; future versions decode conservatively.
- `revision`: 0...1,000,000,000; host increments on accepted creation, skill unlocks, class XP/level changes, prepared spell changes, and fatigue/cooldown changes that need network presentation.
- `classID`: unknown becomes `adventurer`.
- `attributes`: each 8...24, starting sum must be 32 plus earned increases.
- `attributeIncreases`: each 0...8, total 0...8 for the first release.
- `classXP`: 0...1,000,000,000.
- `classLevel`: derived from XP on load, not trusted.
- `spentSkillPoints`: known skill IDs only, rank 0...maxRank, total cannot exceed earned points.
- `knownSpells`: known spell IDs only, count cannot exceed IQ plus explicit perks.
- `preparedSpells`: subset of known spells, capped by prepared slots.
- `fatigue`: finite, 0...fatigueMax.
- `cooldowns`: known action IDs only, bounded tick counts.

World enablement:

- Add `rpgClasses` as a world rule stored in existing world metadata/game-rule style storage instead of a new SQLite table.
- New Survival worlds default `rpgClasses = 1`.
- New Creative worlds may default to `rpgClasses = 0` unless the user explicitly opens Character creation.
- Existing worlds with no rule are treated as enabled on first load so the feature is visible, but the creation screen offers a local "Classic survival for this world" opt-out before committing.
- LAN world summaries must advertise whether `rpgClasses` is required after the protocol bump, so guests do not enter gameplay with mismatched assumptions.

### Derived Stats

| Derived value | Formula or rule |
|---|---|
| Max health | `20 + max(0, ST - 8)` for the first release. ST 8 preserves current 20 health; ST 13 gives 25. |
| Fatigue max | `ST + floor((IQ - 8) / 2) + class/perk bonuses`, minimum 8. |
| Fatigue regen | Base 0.10/sec while hunger > 6. +0.10/sec while standing still and not in combat. Saturation and sleep can grant short regen boosts. |
| Known spell cap | `IQ`, matching TFT. Non-Arcanists need skill unlocks for higher-tier spells but still obey cap. |
| Prepared spell slots | 3 base, +1 at IQ 11, +1 at IQ 14, +1 from Arcanist tree. |
| Weapon readiness | Full effectiveness when ST meets family threshold; under-ST use still works but loses RPG special effects and may slow cooldown. |
| adjustedDexterity | `DX + skill + focus/item + tacticalBonus - armorPenalty - rangePenalty - woundPenalty - fatiguePenalty - movementPenalty`. |

### Class XP Curve

Class XP is separate from vanilla XP to avoid damaging enchanting balance.

Initial cap: class level 20.

| Level band | XP to next | Intent |
|---|---:|---|
| 1-5 | `75 + level * 25` | Fast early identity |
| 6-10 | `175 + level * 50` | Mid-game specialization |
| 11-15 | `450 + level * 90` | Dungeon/boss progression |
| 16-20 | `900 + level * 150` | Long-term mastery |

Awards should prefer bounded, meaningful events:

- First kill of a mob type per day/world period: small class XP.
- Dungeon room cleared or spawner-like encounter resolved: medium class XP.
- Boss and raid milestones: large class XP.
- First craft/use of a class-relevant station or item: small one-time XP.
- Mining/crafting/farming repeat actions: low XP with per-tick/per-minute caps.
- Death: no class XP loss in the first release. This avoids punishing exploration and LAN desync bugs.

Skill points:

- +1 skill point per class level.
- +1 attribute training point at levels 4, 8, 12, 16, and 20.
- Additional attribute points can be milestone rewards later, but the first release keeps total earned attribute increases at 8 to match TFT's limit.

## Classes

Classes are called **Paths** in UI copy. "Class" can remain an internal domain term.

All paths start at ST/DX/IQ total 32. The player can press "Reset to Path Default" or manually redistribute points while preserving the 8 minimum.

| Path | Default ST/DX/IQ | Starting kit | Affinity | Tradeoff |
|---|---:|---|---|---|
| Adventurer | 11/11/10 | Stone tools, bread, torch bundle | Cheap general skills, no penalties | No exclusive cost discounts |
| Vanguard | 13/10/9 | Stone sword, shield, leather chest | Melee, shield, armor, charge, brace | Higher spell and delicate-craft costs |
| Ranger | 9/14/9 | Bow, arrows, leather boots, food | Bows, stealth, dodge, animals, travel | Lower heavy weapon readiness and armor casting |
| Arcanist | 9/10/13 | Staff, 2 known spells, cloth robe item if added | Spells, staff, illusions, wards | Non-staff weapons and shield use penalize casting |
| Artificer | 10/9/13 | Copper/iron-adjacent tool kit, redstone starter, template marker | Redstone, traps, repairs, template handling, constructs | Lower dodge and direct-combat discounts |
| Wildspeaker | 10/12/10 | Seeds, food, simple bow, animal lure | Summons, animals, brewing, healing, foraging | Lower burst damage and heavy armor affinity |

### Path Skill Trees

Each path has three branches. A player can buy out-of-path skills at +1 point cost unless the skill is explicitly path-locked for balance. Path locks should be rare.

#### Adventurer

- **Survivalist**: hunger efficiency, faster recovery after sleep, lower fall stagger.
- **Scavenger**: better low-tier loot rolls, faster tool swap, improved torch/food utility.
- **Generalist**: reduced out-of-path surcharge, one extra prepared spell or combat stance.

#### Vanguard

- **Guardian**: defend, shield bash, armor penalty reduction, front-arc protection.
- **Berserker**: charge attacks, low-health stagger resistance, sweeping weapon bonuses.
- **Sentinel**: polearm brace, force-retreat reliability, protect nearby LAN allies.

#### Ranger

- **Marksman**: bow spread recovery, longbow readiness, weak-point shots, prone/kneeling analogue via crouch-aim.
- **Skirmisher**: dodge-step, sprint-shot penalties reduced, disengage from mobs.
- **Beastwise**: animal handling, pet commands, tracking particles, safer night travel.

#### Arcanist

- **Elementalist**: missile spells, fire/lightning/frost, staff crits on low 3d6 rolls.
- **Illusionist**: blur, dazzle, image decoys, invisibility, disbelieve/reveal contests.
- **Warder**: stone/iron flesh analogues, anti-projectile wards, dispel, staff defense.

#### Artificer

- **Machinist**: redstone diagnostics, trap placement, repeater/comparator helper overlays.
- **Tinker**: repair efficiency, durability saves, tool readiness with lower ST.
- **Architect**: template placement previews, support-fill hints, construct summons as bounded temporary entities.

#### Wildspeaker

- **Herbalist**: food/brewing improvements, healing poultices, antidotes.
- **Summoner**: wolf/bee/golem-like temporary allies, upkeep fatigue, bounded caps.
- **Warden of Paths**: terrain traversal, nature wards, animal calm/fear resistance.

## Skills

Skill registry should be data-like Swift definitions, not external scripts, for the first release.

```swift
public struct RPGSkillDef {
    public let id: String
    public let displayName: String
    public let path: String
    public let branch: String
    public let maxRank: Int
    public let prerequisites: [String]
    public let cost: Int
}
```

Skill effects are code-owned switch cases or typed effect structs, for example:

- `adjustedDXBonus(action:context:)`
- `fatigueCostMultiplier(spell:context:)`
- `weaponReadinessBonus(family:)`
- `unlockSpellCategory(category:)`
- `grantAction(actionID:)`
- `modifyXP(event:)`

Avoid arbitrary closures in serializable data. Runtime closures are acceptable only in static code, never decoded from saves or network.

## Spell System

### Spell Categories

| Category | TFT root | Pebble behavior |
|---|---|---|
| Missile | Magic Fist, Fireball, Lightning | Aimed projectile or ray. Range penalty affects cast roll. Cost is declared before cast; miss still spends more fatigue than thrown spells. |
| Thrown | Blur, Freeze, Dazzle, Trip, Control | Direct target or small area under crosshair. Range penalty is per block band. Failure costs 1 fatigue unless spell says otherwise. |
| Creation | Fire, Wall, Shadow, Image, Illusion, Summon | Temporary block/entity/visual creation with short range, no range penalty inside valid radius, bounded counts and durations. |
| Special | Staff, Flight, Dispel, Mage Sight | Unique interactions with existing systems such as Flying Wand, effects, mobs, blocks, and UI overlays. |

### Spell Definition

```swift
public struct RPGSpellDef {
    public let id: String
    public let displayName: String
    public let category: RPGSpellCategory
    public let iqRequired: Int
    public let fatigueCost: Int
    public let upkeepCost: Int
    public let rangeBlocks: Double
    public let cooldownTicks: Int
    public let targetKind: RPGSpellTargetKind
    public let tags: Set<String>
}
```

Initial spell list:

| Spell | Category | IQ | Cost | Effect |
|---|---|---:|---:|---|
| Staff Spark | Missile | 8 | 1 | Low damage ranged bolt; tutorial spell. |
| Dazzle | Thrown | 8 | 2 | Short blind/accuracy penalty on mob or player. |
| Trip | Thrown | 8 | 2 | Stagger/slow target if DX/IQ resistance fails. |
| Blur | Thrown/self | 9 | 2 + upkeep | Incoming projectiles/spells suffer an adjustedDX penalty. |
| Fire | Creation | 9 | 2 | Places temporary magical fire on valid loaded cells. |
| Stone Flesh | Special | 10 | 3 + upkeep | Temporary damage absorption; armor-like hit stop. |
| Wolf Image | Creation | 10 | 2 + upkeep | Decoy that vanishes on hit/touch and deals no damage. |
| Wolf Illusion | Creation | 11 | 3 + upkeep | Belief-dependent decoy that can damage until disbelieved. |
| Magic Fist | Missile | 11 | variable | Projectile; fatigue spent scales damage. |
| Freeze | Thrown | 12 | 3 | Short slow/root with resistance check. |
| Reveal | Special | 12 | 2 | Attempts to disbelieve/reveal illusions in a cone. |
| Lightning | Missile | 13 | variable | Line ray; strong damage; strict range/armor penalties. |
| Dispel | Special | 13 | 3 | Ends compatible magical effects and creations. |
| Flight Step | Special | 14 | 4 + upkeep | Short controlled hover; intentionally weaker than Flying Wand. |
| Summon Wolf | Creation | 14 | 4 + upkeep | Real temporary ally with hit points and host-owned AI. |

### Casting Check

For spells requiring a check:

```text
roll = deterministic 3d6
success if roll <= adjustedDexterity
3 = critical success
4 = strong success
16 = automatic failure
17 = fumble
18 = severe fumble
```

Pebble-specific fumble mapping:

- `16`: failure, normal failure cost.
- `17`: failure, full fatigue cost, action cooldown.
- `18`: failure, full fatigue cost, short `staggered`, and staff/focus durability damage if any.

This preserves TFT's risk curve without making players drop or break important items constantly in a survival sandbox.

### Illusions and Disbelief

Illusions are a core differentiator and should be implemented as explicit transient entities:

- `Image`: visible decoy, no damage, vanishes when touched/hit.
- `Illusion`: can deal reduced real damage until the target succeeds at a Reveal/Disbelieve IQ check or it is killed.
- Mobs use AI heuristics and IQ-like resistance from mob category.
- Players use manual Reveal or direct attack. LAN host validates outcomes.
- Illusions are never persisted as chunk entities and are removed on save/reload.

## Combat Additions

### Action-Lock Model

Add small, explicit action locks:

| Lock | Duration | Blocks |
|---|---:|---|
| `attackCommitted` | existing attack cooldown window | Repeated full-power attack |
| `castCommitted` | spell windup/cooldown | Other casts and heavy attacks |
| `guarding` | while held, drains fatigue on block | Sprint and casting |
| `dodging` | 8-12 ticks | Attack/cast, except class perks |
| `winded` | 20-60 ticks | Sprint, full-power cast, special action |

### Combat Options

| Option | Input proposal | Rule |
|---|---|---|
| Charge attack | Sprint for at least 0.8 sec, then melee | Bonus knockback. Polearms/spears/tridents get extra damage if path is straight enough. |
| Brace | Hold sneak + right-click with spear/trident/staff | If a charging enemy enters reach, make a host-authoritative counter hit before normal contact. |
| Defend | Hold right-click with shield/staff/guard-capable weapon | Reduces or checks incoming non-missile attacks. Uses fatigue and adjustedDX. |
| Dodge | Double-tap strafe or bound key | Short lateral movement and projectile/spell defense. Higher DX improves recovery. |
| Shield bash | Attack while guarding with shield | Low damage, ST vs target check, applies stagger/knockback. |
| Force retreat | Automatic after clean melee hit with no recent damage taken | Applies modest knockback/stagger if target has space and resistance fails. |
| Disengage | Back/strafe while guarding or dodge from engaged mob | Reduces mob follow-up chance; player agency replacement for one-hex option. |

### Facing and Engagement in First Person

Pebble should not add hex facing. Instead:

- Front arc: target within +/-70 degrees of entity facing.
- Side arc: 70-135 degrees, eligible for +DX/sneak bonuses.
- Rear arc: >135 degrees, eligible for backstab/ambush bonuses.
- Engagement: a hostile entity in melee reach and front arc can suppress sprint-start, long casts, and bow full accuracy unless the player has a skirmisher/disengage skill.

### Injury

Map large-hit thresholds to action-game states:

- `staggered`: from taking >=25% max health in 1.5 sec; -2 adjustedDX and partial movement hitch for 20 ticks.
- `winded`: from fatigue reaching 0 or failed heavy action; slower regen and no sprint for 40 ticks.
- `knockedDown`: reserved for shield-rush, boss hits, or explicit spells. Avoid frequent hard knockdown in normal play.

## Weapons and Armor

### Weapon Families

| Family | Examples | Full-effect ST | DX/IQ notes |
|---|---|---:|---|
| Dagger | Dagger/main-gauche if added | 8 | Fast, low damage, rear/HTH bonuses. |
| Sword | Existing swords | 9 | Baseline melee, sweeping skills. |
| Axe | Existing axes | 10 | Higher stagger/armor pressure. |
| Hammer/mace | New later | 12 | High stagger, slow cooldown. |
| Spear/polearm | Trident/spear | 10 | Brace, reach, charge. |
| Bow | Existing bow | 9 | DX affects spread/recovery. |
| Longbow | New or high-tier bow | 11 | Range damage, slower draw. |
| Crossbow | Existing crossbow | 12 | Ready/reload skills; prone/crouch bonus analogue. |
| Staff | New focus item | 8 | Armed for engagement; spell focus; weak physical attack. |
| Wand/focus | New later | 8 | Faster casting, weaker defense. |

Under-ST use:

- Normal vanilla use still works.
- RPG special effects do not trigger.
- Heavy family cooldown is 10-25% slower.
- Fumble chance increases only for RPG special actions, not ordinary block breaking.

### Armor Penalties

Existing armor defense remains unchanged. RPG penalties apply to adjustedDX and fatigue:

| Armor class | Casting/skill penalty | Fatigue regen | Notes |
|---|---:|---:|---|
| No armor/cloth | 0 to -1 | 100% | Arcanist-friendly. |
| Leather/gold | -1 to -2 | 95% | Ranger-friendly. |
| Chain/iron | -3 | 85% | Vanguard can reduce. |
| Diamond/netherite | -4 to -5 | 75% | Strong protection, strong casting penalty. |
| Shield ready | -1 cast penalty; blocks some spells unless trained | 90% while guarding | Mirrors TFT staff/shield tension. |

Do not globally reduce normal movement speed from armor in the first release. Pebble's movement is golden-tested and player expectations are Minecraft-like.

## Character Creation UI

### Entry Points

1. **New World**: `WorldCreateScreen` adds "Character..." after world type/dungeons. `Create World` is disabled until a character is confirmed when RPG mode is on.
2. **Existing world without RPG state**: first load opens `CharacterCreateScreen` before pointer capture. The player cannot move until confirming or choosing Adventurer defaults.
3. **LAN guest**: first accepted guest without host-side RPG record opens the same creation flow. The host persists the result in `lan_players`.
4. **Creative worlds**: default to Adventurer and allow "Skip RPG" if world rule `rpgClasses` is false.

### World Create Layout

Current world creation is compact and button-stacked. Add one row:

```text
World Name
[ text field ]
Seed
[ text field ]
[ Game Mode: Survival ]
[ Difficulty: Normal ]
[ World Type: Default ]
[ Dungeons: Normal ]
[ Character: Adventurer  ST 11 DX 11 IQ 10 ]
[ Create World ] [ Cancel ]
```

Clicking Character opens the full creation screen. The row label updates after confirmation.

### Character Create Screen

Use the existing dirt background and immediate-mode UI style.

Desktop layout:

```text
Create Character

[Path list 96w] [center preview/summary 132w] [attributes/derived 156w]

Path list:
> Adventurer
  Vanguard
  Ranger
  Arcanist
  Artificer
  Wildspeaker

Center:
Path name
Short role line
Starting kit icons/list
Complexity: Beginner/Medium/Advanced

Right:
ST [-] 11 [+]   Health 23   Fatigue 12
DX [-] 11 [+]   Cast/check 11
IQ [-] 10 [+]   Spells known 10
Unassigned: 0

[Starter Skill: Survivalist I]
[Known Spells...] (enabled mainly for Arcanist)

[Reset to Path Default] [Confirm] [Back]
```

Small-height layout:

- Collapse center preview into a two-line summary.
- Path list becomes a cycling button: `Path: Adventurer`.
- Attributes remain visible because they are the decision core.

### Creation Rules

- Minimum 8 in each attribute.
- Total must equal 32 at creation.
- Confirm shows a one-line warning if the chosen path is advanced.
- Adventurer is recommended and first in the list.
- Known spells cannot exceed IQ.
- Arcanist starts with 2 prepared spells; other paths start with no spells unless they spend starter choice on Hedge Magic.
- Starting gear is regular item stacks, validated through item registry.

### Character Screen In Game

Keybind: `K` opens `CharacterScreen` by default, rebindable in Options -> Controls.

Tabs:

1. **Overview**: path, level, class XP, ST/DX/IQ, derived health/fatigue, current penalties.
2. **Skills**: tree by branch. Nodes show rank, cost, prerequisites, and whether out-of-path surcharge applies.
3. **Spells**: known/prepared spells. Drag/click into prepared slots; select current staff spell.
4. **Stats**: class XP history, combat/magic/action stats, relevant advancement links.

HUD:

- Fatigue bar above or below the existing XP bar, visually distinct from XP.
- Small class badge near the level number when GUI is visible.
- Selected prepared spell icon/text near hotbar when holding a staff/focus.
- Action bar messages for failed conditions: "Too exhausted", "Need IQ 12", "Shield blocks this spell", "Target out of range".

## Art and Asset Plan

The feature must ship with complete visible/audio coverage. "Fallback later" is not acceptable because class choice, spells, and progression are player-facing identity systems.

### Asset Source Rules

Use this priority order:

1. Existing Pebble/Faithful pack art when the existing item/entity/block already maps cleanly.
2. Deterministic procedural 16x16 icon generation in `PebbleCore/Render/Icons.swift`.
3. Existing `UICanvas` geometry/text for UI badges, panels, progress bars, and tree nodes.
4. Existing particle tile recipes in `ParticlesM.swift` with color/size/life variations.
5. Existing synthesized audio recipes in `Audio.swift` with new cue names if needed.
6. New packaged binary art only with explicit license/provenance and `scripts/verify-pack-assets.sh` coverage.

Do not use scraped web images, unlicensed RPG icon packs, generative output without a license decision, or Mojang/Microsoft assets. The first implementation slice should need no new binary art.

### Asset Manifest

Add a static manifest, likely `Sources/PebbleCore/Game/RPGAssetManifest.swift`, that every RPG definition references by ID:

```swift
public struct RPGAssetManifestEntry: Equatable {
    public var id: String
    public var iconKind: RPGIconKind
    public var particleCue: String?
    public var soundCue: String?
    public var fallbackLabel: String
}
```

Required manifest entries:

| Surface | Entries | Source |
|---|---|---|
| Path badges | Adventurer, Vanguard, Ranger, Arcanist, Artificer, Wildspeaker | UICanvas shield/bow/star/gear/leaf glyphs plus deterministic colors. |
| Skill branches | 18 branch icons | UICanvas glyphs; no PNG dependency. |
| Spells | Every spell in the initial spell list | Procedural icon pixels with stable palette, shape, and symbol. |
| Staff/focus items | Staff first; wand/focus later | Prefer existing stick/blaze-rod-like pack art if registered, otherwise procedural staff icon. |
| Fatigue HUD | bar, empty/full colors, exhaustion flash | UICanvas only. |
| Spell particles | spark, dazzle, trip, blur, fire, stone, reveal, lightning, summon | Existing particle tiles plus deterministic color/life recipes. |
| Spell sounds | cast, fizzle, crit, ward, reveal, summon | Existing synthesized audio engine; no sample files. |
| Summons/illusions | Wolf image, wolf illusion, temporary ally overlays | Existing wolf/player/entity models plus tint/particle overlays; no new model in first slice. |

### Asset Gate

- Add `RPGAssetManifestTests` to prove every class, branch, skill, spell, action, and item references a manifest entry.
- Extend `IconTests` for every new item icon and all spell icons; tests should verify 16x16 RGBA size, non-empty alpha, deterministic output, and distinct silhouettes for major spell categories.
- If a new packaged file is added, update `scripts/verify-pack-assets.sh` with required entries and license file checks.
- Add a screenshot smoke for Character creation, Character sheet, Spellbook, and in-world HUD so missing icon/text layout issues are visible before closeout.
- Do not let a missing pack entry silently produce a blank icon; procedural fallback must be explicit and tested.

## Persistence

Store `RPGCharacterState` inside the existing player JSON:

```swift
d["rpg"] = enc(rpgState)
```

Load behavior:

- Missing `rpg`: `created = false`, pending creation UI.
- Corrupt `rpg`: log warning, reset to uncreated Adventurer pending state, preserve all vanilla player data.
- Unknown IDs: drop unknown skills/spells; unknown class becomes Adventurer.
- Over-budget points: trim in deterministic registry order and refund valid unspent points if possible.
- Invalid finite numbers: clamp or zero, never crash.
- Level/point mismatch: recompute derived level/points from `RPGCharacterState.xp`, clamp spending, and save only the repaired bounded state.
- World rule mismatch: if `rpgClasses == 0`, keep decoded RPG state but do not force creation or apply RPG mechanics.

No schema migration is required for the first version because player JSON already supports extension fields.

LAN guest persistence:

- Extend `LANPeerRecordSnapshot` with optional `rpg: RPGCharacterState?`.
- Extend the app-side `LANTransport.swift` JSON bridge to store/read an `"rpg"` object inside `lan_players` rows.
- Decode failures for the `"rpg"` subobject drop only RPG state and request recreation; they must not drop the whole peer record if player state/inventory are otherwise valid.
- Host records remain authoritative on reconnect. Client-local cached RPG presentation is discarded when a host restore or direct RPG-change snapshot arrives.
- `LANHostGhostRegistry` must hydrate ghost players with host-owned RPG state before resolving RPG combat/spell intents, while keeping ghosts nonpersistent and outside `world.entities`.

## LAN Design

Implementation note: this section preserves the more elaborate contrary-architect sketch. The current implementation uses protocol v4 `LANRPGIntent` instead of separate create/spell/action intent structs, stores full state in host peer records, keeps periodic player snapshots lean, and sends full repaired RPG state only in direct RPG-change/restore `LANPlayerState` snapshots for owning-client convergence. Separate `LANRPGSummary` and `LANRPGVisualEvent` arrays remain a future optimization, not a shipped requirement.

### Ownership

- Singleplayer: local `Player.rpg` is authoritative.
- Host player: local host `Player.rpg` is authoritative and saved in `player(world,json)`.
- LAN guest: host stores guest RPG state in `lan_players(world, playerID, json)`. Client local resume may cache presentation, but host record wins.
- Remote player proxies: carry only enough RPG summary for rendering, not full authority.

### Protocol Additions

Current LAN frames are strict, versioned, type-tagged JSON payloads with a 1 MiB cap. RPG networking must follow the existing pattern: append message IDs, bump protocol version, and keep protocol models in `PebbleCore/Net`.

The sketch below proposed separate bounded Codable payloads. The implemented v4 payload is the consolidated `LANRPGIntent`; full RPG state is not present in normal high-frequency `LANPlayerState`.

```swift
public struct LANRPGSummary: Codable, Equatable {
    public var playerID: String
    public var classID: String
    public var classLevel: Int
    public var revision: Int
    public var fatigueRatio: Double
    public var selectedSpell: String?
    public var actionState: String?
}

public struct LANRPGCreateIntent: Codable, Equatable {
    public var actionSequence: Int
    public var classID: String
    public var attributes: RPGAttributes
    public var starterSkillID: String?
    public var starterSpellIDs: [String]
}

public struct LANSpellIntent: Codable, Equatable {
    public var actionSequence: Int
    public var spellID: String
    public var selectedHotbarSlot: Int
    public var target: LANTargetReference
}

public struct LANRPGActionIntent: Codable, Equatable {
    public var actionSequence: Int
    public var actionID: String
    public var selectedHotbarSlot: Int
    public var target: LANTargetReference?
}

public struct LANRPGVisualEvent: Codable, Equatable {
    public var eventID: Int
    public var casterPlayerID: String
    public var assetCueID: String
    public var source: LANTargetReference
    public var target: LANTargetReference?
    public var tick: Int
}
```

`LANTargetReference` should be typed and bounded:

- entity id
- block coordinate from current crosshair
- direction ray with bounded max distance
- self

Never accept raw arbitrary effect scripts, arrays of coordinates, or client-supplied damage values.

Protocol rules:

- Append new `LANMultiplayerMessageKind` cases after the current maximum. Do not reuse or reorder existing raw values.
- Bump `LAN_MULTIPLAYER_PROTOCOL_VERSION` because strict peers reject unsupported versions rather than negotiate optional fields.
- Add `rpgSummaries` and `rpgVisualEvents` to `LANReplicationBatch`, capped to `LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS` and a new small visual-event cap.
- `LANRPGSummary.playerID` is the sanitized peer ID; `classID`, `selectedSpell`, `actionState`, and `assetCueID` are registry IDs capped by bytes and validated against static registries.
- `LANRPGSummary` is sent only when changed, on reconnect/restore, and at a low background cadence. It is not a per-frame dump.
- `LANRPGVisualEvent` is cosmetic only. Clients may spawn particles/play sounds from the asset manifest, but must not apply damage, fatigue, XP, block changes, or entity spawns from it.
- Worst-case encoded replication batches with max chunk sections, inventories, RPG summaries, and visual events must stay below `LAN_MULTIPLAYER_MAX_FRAME_BYTES`.

### Creation Handshake

RPG creation is an authority transition, not a local menu result:

1. Host advertises `rpgClasses` in `LANWorldSummary`.
2. Guest without host RPG state is accepted into a blocked pre-game creation state.
3. Guest submits `LANRPGCreateIntent` with class, attributes, starter skill, and starter spells.
4. Host validates totals, known IDs, IQ spell caps, starter-kit availability, and world rule.
5. Host persists the resulting `RPGCharacterState` into the peer record and sends an accepted summary/restore.
6. Guest enters gameplay only after the host acknowledgement.

If validation fails, the guest stays on the creation screen with a sanitized reason. The client never creates items, skill points, or spells directly.

### Host Validation

For every RPG intent:

1. Peer is accepted, alive, same dimension, and not disconnected.
2. Host has an RPG record for the peer.
3. Peer has permission for combat/template/AI/creative as relevant.
4. `actionSequence` is exactly one greater than the last accepted sequence; duplicates and jumps request resync and do not mutate state.
5. Action/spell exists and is unlocked.
6. Cooldown and fatigue pass.
7. Held item and selected slot match required focus/weapon using the host-owned inventory snapshot or ghost hydration.
8. Target is loaded, in range, same dimension, and line-of-sight/reach valid.
9. Creation/summon caps pass for caster, world, spell, and loaded area.
10. Effect is applied only through host-owned world mutation APIs.
11. Host increments RPG revision when state changes and emits bounded summary/visual events to clients.
12. Host rejects duplicate, stale, or future-skipping sequences without state mutation.

### Packet and Cadence Budget

- RPG summaries are tiny: one per visible player, capped to accepted peers plus host.
- RPG visual events are transient and drop-oldest when capped; state correctness must not depend on delivery.
- Active spell creation must prefer normal block/entity/chunk replication for durable world state. Do not embed block arrays or entity definitions in visual events.
- Background RPG summary cadence should start at 1.0 seconds, matching existing low-frequency world/player background replication. Immediate summaries are sent only on creation, level up, selected spell change, start/stop action state, and fatigue threshold crossings such as full/empty.
- The host should avoid echoing every fatigue tick; send ratios when crossing coarse bands or when a local HUD owner needs authoritative correction.

### LAN Reconnect

- Host `lan_players` record includes `rpg`.
- Guest class creation is not repeated unless host record is missing or admin command allows reset.
- Skill unlocks and class XP are part of host-owned guest persistence.
- Reconnect restore includes `LANRPGSummary` and the current host revision.
- If a guest reconnects with stale local cached RPG UI, the host summary wins and the client refreshes the Character screen/spellbook.
- If a peer record has valid position/inventory but corrupt RPG data, reconnect succeeds into the blocked creation state instead of rejecting the whole peer.

## Security Review of Plan

Status: CONDITIONAL PASS after the contrary-architect revisions above. Implementation must run Full tier because this touches persistence, network behavior, and untrusted structured input.

Findings:

- [HIGH] LAN spell/action intents can become remote world mutation if they carry raw coordinates or effect definitions. Exact fix: typed target references only; host derives actual effect cells/entities.
- [HIGH] Duplicated LAN spell/action intents can double-apply state. Exact fix: bounded exact-next per-peer action sequences, duplicate rejection, and no mutation on stale/future-skipping requests.
- [HIGH] LAN character creation can become client-authoritative progression. Exact fix: creation intents are proposals only; host validates, persists, grants starter items, and acknowledges before gameplay.
- [HIGH] Full RPG state in high-frequency player replication can bloat frames and leak authority. Exact fix: full state stays in saves/peer records; batches carry capped revisioned summaries.
- [HIGH] Save decode can become an unchecked registry index if skill/spell/class IDs are trusted. Exact fix: registry lookup returns optional and unknown IDs are dropped before hot paths.
- [HIGH] Summons/creation spells can create unbounded entities/blocks. Exact fix: per-caster, per-world, per-spell caps plus loaded-area checks and nonpersistent transient entities by default.
- [MEDIUM] New message kinds without a protocol bump can confuse strict LAN peers. Exact fix: append IDs, bump protocol version, and test old-version rejection and payload-type mismatch.
- [MEDIUM] Cosmetic spell events can accidentally become gameplay authority. Exact fix: `LANRPGVisualEvent` only references asset cues and targets; gameplay arrives through normal host snapshots/deltas.
- [MEDIUM] Missing or unlicensed RPG icons can ship unnoticed. Exact fix: manifest-backed asset coverage, no unlicensed art, `IconTests`, screenshot smoke, and asset-verification script updates for any binary files.
- [MEDIUM] Class XP can be farmed by AFK loops. Exact fix: per-event caps, diminishing repeat awards, milestone-heavy curve.
- [MEDIUM] Random casting checks can break determinism if they use `Double.random` or unordered iteration. Exact fix: use deterministic RNG seeded from world/player/action sequence and stable target ordering.
- [MEDIUM] Heavy armor penalties could silently move vanilla gameplay. Exact fix: apply penalties only to RPG checks/fatigue at first, not core movement.
- [LOW] UI can overflow on small windows. Exact fix: compact layout and screenshot hooks at small and normal sizes.

Not reviewed yet:

- Exact line-level code because no implementation exists.
- Balance numbers in real combat.
- Actual packet sizes and latency until the implementation adds concrete payloads and runs frame-budget tests.

## Tester Plan

### Focused Unit Tests

Add tests under `Tests/PebbleCoreTests/`:

- `RPGCharacterStateTests`
  - missing RPG state requests creation
  - corrupt/unknown IDs clamp and drop safely
  - over-budget skill/attribute points are repaired deterministically
  - old player saves still load
  - `revision` clamps and increments only through accepted state changes
  - `rpgClasses = 0` preserves state but disables prompts/mechanics
- `RPGProgressionTests`
  - XP curve exact level thresholds
  - skill point totals
  - attribute increase cap
  - repeated event cap
  - XP awards are deterministic when several events land in one tick
- `RPGSpellTests`
  - adjustedDX armor/range/fatigue/wound math
  - deterministic 3d6 rolls
  - critical/fumble mapping
  - IQ known-spell cap
  - upkeep drains/reserves fatigue
  - spell creation/summon caps reject overflow without partial effects
- `RPGCombatOptionTests`
  - charge path threshold
  - brace ordering
  - shield-bash ST check
  - force-retreat only after clean physical hit
- `RPGSaveLANTests`
  - player JSON stores and repairs `rpg`
  - `lan_players` stores and repairs nested `rpg`
  - corrupt nested RPG data does not discard valid peer position/inventory
  - guest reconnect preserves host-owned RPG state
- `RPGLANProtocolTests`
  - new message kinds append raw IDs and protocol version is bumped
  - codec rejects old/unknown versions and payload type mismatches
  - worst-case replication batches with max chunk sections plus RPG summaries/events stay under the 1 MiB frame cap
  - `LANRPGSummary` strings clamp by bytes and reject unknown registry IDs
- `RPGLANHostValidationTests`
  - creation intent rejects invalid class, bad attribute sum, excessive spells, unknown starter choices
  - duplicate/stale/future-skipping action sequences do not mutate state and request resync when needed
  - spell intents reject unknown spells, locked spells, out-of-range target, unloaded target, wrong dimension, wrong focus, wrong slot, insufficient fatigue, dead peer
  - visual events are emitted only after accepted host mutation/check resolution
- `RPGAssetManifestTests`
  - every path, branch, skill, spell, action, focus item, particle cue, and sound cue has a manifest entry
  - every icon resolves to pack art or deterministic procedural pixels
  - every procedural icon is 16x16 RGBA, non-blank, deterministic, and distinct for major spell categories
- `RPGUIModelTests`
  - attribute allocation cannot go below 8 or above total 32 at creation
  - compact layout keeps path selector, ST/DX/IQ, unassigned count, and Confirm visible
  - spellbook prepared slots enforce known/prepared caps

### UI Smoke Hooks

Add allowlisted screen hooks:

- `PEBBLE_OPEN_SCREEN=characterCreate`
- `PEBBLE_OPEN_SCREEN=characterSheet`
- `PEBBLE_OPEN_SCREEN=spellbook`
- `PEBBLE_OPEN_SCREEN=rpgHud`

Required screenshots:

- 480x270 compact create screen
- 854x480 normal create screen
- 480x270 compact character sheet
- 854x480 spellbook
- in-world HUD with fatigue bar and selected spell
- LAN remote-caster visual event if active spells are included

Screenshots must be captured from the installed app for final closeout, not only `swift run`.

### Fuzz, Property, and Budget Tests

- Seeded decode fuzz for `RPGCharacterState`, `LANRPGCreateIntent`, `LANSpellIntent`, `LANRPGActionIntent`, and `LANRPGSummary`.
- Property checks for attribute budget repair, skill-point repair, known/prepared spell subset repair, and deterministic target ordering.
- Packet-budget samples for idle max-client replication, active max-client casting, and reconnect restore. Report sample count and max encoded byte size.
- Performance sample for opening Character creation and Spellbook with all classes/spells registered; report at least 5 samples or state if only smoke-tested.

### Live LAN RPG Probe

Extend `scripts/live-lan-test.sh` or add an RPG-specific mode. The final implementation must prove on `/Applications/Pebble.app` and Neo:

- Host advertises `rpgClasses`.
- Neo first-join opens character creation or accepts a scripted test character through the same host-validated creation intent.
- Host persists guest RPG state in `lan_players`.
- Guest casts one basic staff spell; host accepts the intent and emits visual proof.
- Host and guest both observe the visual event, while durable state arrives through normal replication.
- Neo reconnects and receives the same host-owned class, level, fatigue, selected spell, and position/inventory.
- Duplicate/replayed spell intent is rejected in logs or probe output.

### Full Verification Gate

For implementation, minimum closeout:

```bash
swift build -c release
swift test
swift run -c release pebsmoke
bash scripts/security-scan.sh
bash scripts/verify-pack-assets.sh
```

Because this will touch persistence and LAN, final closeout should also run:

```bash
bash scripts/pipeline.sh
scripts/live-lan-test.sh --deploy --timeout 90
```

Installed-app proof should include:

- create a new Survival world
- verify `rpgClasses` world rule in saved metadata
- complete character creation
- verify ST/DX/IQ shown in character screen
- earn class XP
- learn/unlock a skill
- cast a basic spell with a staff
- verify every new visible icon/particle cue appears or has an explicit procedural fallback
- save and reload
- LAN guest first-join creation and reconnect preservation
- encoded LAN packet-size evidence for the new RPG message/batch shapes

## Implementation Files

Likely files to add:

- `Sources/PebbleCore/Game/CharacterProgression.swift`
- `Sources/PebbleCore/Game/RPGAssetManifest.swift`
- `Sources/PebbleCore/Systems/Spells.swift`
- `Sources/PebbleCore/Net/LANRPG.swift` if the payloads are kept separate from `LANMultiplayer.swift`.
- `Tests/PebbleCoreTests/RPGCharacterStateTests.swift`
- `Tests/PebbleCoreTests/RPGProgressionTests.swift`
- `Tests/PebbleCoreTests/RPGSpellTests.swift`
- `Tests/PebbleCoreTests/RPGCombatOptionTests.swift`
- `Tests/PebbleCoreTests/RPGSaveLANTests.swift`
- `Tests/PebbleCoreTests/RPGLANProtocolTests.swift`
- `Tests/PebbleCoreTests/RPGLANHostValidationTests.swift`
- `Tests/PebbleCoreTests/RPGAssetManifestTests.swift`
- `Tests/PebbleCoreTests/RPGUIModelTests.swift`

Likely files to edit:

- `Sources/PebbleCore/Entity/Player.swift`: add `rpg`, save/load, derived stats hooks.
- `Sources/PebbleCore/Entity/Living.swift`: add or reuse short effects for stagger/winded if not modeled as status effects.
- `Sources/PebbleCore/Systems/Combat.swift`: combat option helpers and weapon readiness hooks.
- `Sources/PebbleCore/Game/GameCore.swift`: input routing, XP events, action execution, world entry creation gate.
- `Sources/PebbleCore/Game/Saves.swift`: store/read world `rpgClasses` rule and player `rpg`; add save validation tests.
- `Sources/PebbleCore/Net/LANMultiplayer.swift`: append bounded RPG summary/intent/visual payloads, new message kinds, and protocol version bump.
- `Sources/PebbleCore/Net/LANReplication.swift`: host validation, summary/event replication, duplicate sequence rejection, reconnect summary application.
- `Sources/PebbleCore/Net/LANGameplayOrchestration.swift`: extend peer record snapshots with optional RPG state and testable result types.
- `Sources/PebbleCore/Net/LANGhostActor.swift`: hydrate host ghosts with RPG state for authoritative remote intent execution.
- `Sources/Pebble/LANTransport.swift`: bridge nested `rpg` in `lan_players` JSON and route create/action/spell intents without owning rules.
- `Sources/Pebble/MenusM.swift`: world creation row and character creation screen entry.
- `Sources/Pebble/ScreensM.swift`: character screen/spellbook if kept with gameplay screens.
- `Sources/Pebble/HudM.swift`: fatigue bar, class badge, selected spell display.
- `Sources/PebbleCore/Render/Icons.swift`: deterministic path/spell/focus icons and tests.
- `Sources/Pebble/ParticlesM.swift`: RPG particle cues using existing particle tiles.
- `Sources/Pebble/Audio.swift`: synthesized RPG cue names if needed.
- `Sources/Pebble/main.swift`: allowlisted screenshot hooks for RPG screens.
- `Sources/Pebble/CommandsM.swift`: optional debug/admin commands such as `/rpg status`, `/rpg resetCharacter` gated to local/host permissions.
- `scripts/verify-pack-assets.sh`: required only if new packaged art/license files are added.
- `scripts/live-lan-test.sh`: RPG creation/cast/reconnect probe mode.
- `README.md`, `ARCHITECTURE.md`, `SECURITY.md`, `CONTRIBUTING.md`: update only once implementation behavior exists.

## Open Questions

1. Should character choice be one-time per world, or should a rare craftable "Respec Tome" allow changing path while preserving earned XP?
2. Should spells be enabled in Peaceful/Creative by default, or should Creative bypass fatigue and skill locks for testing?
3. Should LAN hosts be able to force Adventurer/default characters for all guests?
4. Should class XP be awarded for building/templates, and if so how do we prevent large-template placement from farming XP?
5. Should the first active spell slice include hostile player-vs-player effects, or should LAN spells initially target only mobs/self/blocks until PvP balance is proven?

## Recommended First Implementation Slice

Start with a low-risk vertical slice:

1. Add `RPGCharacterState`, class registry, attribute validation, XP curve, and tests.
2. Add `RPGAssetManifest`, deterministic path/spell/focus icons, and asset tests.
3. Persist state inside `Player.save/load` and persist `rpgClasses` world rule.
4. Add character creation UI with paths and ST/DX/IQ allocation.
5. Add in-game character overview screen.
6. Add fatigue bar but no active spells yet.
7. Prove old saves load, new saves reload, icons resolve, and screenshots are non-overlapping.

Do not begin spells or LAN active intents until the passive character model is tested, save-compatible, asset-complete, and screenshot-verified. Spells and LAN intents are the highest-risk part of the design and should be a second slice with protocol-version, packet-budget, replay, and live Neo proof gates.
