import Foundation

public let RPG_STATE_CURRENT_VERSION = 2
public let RPG_CLASSES_GAME_RULE = "rpgClasses"
public let RPG_LEVEL_CAP = 20
public let RPG_MAX_PREPARED_SPELLS = 6
public let RPG_MAX_PREPARED_SKILLS = 4
public let RPG_ACTION_QUICK_SLOT_COUNT = 9
public let RPG_MAX_ID_UTF8_BYTES = 64
public let RPG_MAX_COOLDOWNS = 32
public let RPG_MAX_UPKEEPS = 16
public let RPG_MAX_XP_EVENT_KEYS = 64
public let RPG_MAX_RECIPE_MILESTONE_WORDS = 64
public let RPG_MAX_COUNTER = 1_000_000_000
/// The final revision is reserved for terminal upkeep cleanup. Ordinary
/// discrete mutations may publish at most this revision.
public let RPG_MAX_NORMAL_AUTHORITY_REVISION = RPG_MAX_COUNTER - 1
public let RPG_MAX_EFFECT_TICKS = 1_200_000
public let RPG_XP_WINDOW_TICKS = 1_200
public let RPG_STARTER_KIT_VERSION = 1
public let RPG_MAX_PERSISTED_PAYLOAD_BYTES = 64 * 1024

@inline(__always)
public func rpgSaturatedAdd(_ lhs: Int, _ rhs: Int, maximum: Int = RPG_MAX_COUNTER) -> Int {
    let boundedMaximum = max(0, maximum)
    guard boundedMaximum > 0 else { return 0 }
    guard rhs > 0 else { return max(0, min(boundedMaximum, lhs)) }
    let base = max(0, min(boundedMaximum, lhs))
    let (sum, overflow) = base.addingReportingOverflow(rhs)
    return overflow ? boundedMaximum : min(boundedMaximum, sum)
}

@inline(__always)
public func rpgIsBoundedID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= RPG_MAX_ID_UTF8_BYTES
}

public enum RPGAttributeID: String, Codable, CaseIterable, Hashable {
    case strength
    case dexterity
    case intelligence
    case endurance
    case luck
}

public struct RPGAttributes: Codable, Equatable {
    public var strength: Int
    public var dexterity: Int
    public var intelligence: Int
    public var endurance: Int
    public var luck: Int

    public init(strength: Int, dexterity: Int, intelligence: Int, endurance: Int, luck: Int) {
        self.strength = strength
        self.dexterity = dexterity
        self.intelligence = intelligence
        self.endurance = endurance
        self.luck = luck
    }

    public static let minimum = 6
    public static let maximumAtCreation = 14
    public static let maximumWithProgression = 18
    public static let creationBudget = 42
    public static let defaultCreation = RPGAttributes(strength: 9, dexterity: 9, intelligence: 9, endurance: 9, luck: 6)

    public var total: Int {
        strength + dexterity + intelligence + endurance + luck
    }

    public func value(_ id: RPGAttributeID) -> Int {
        switch id {
        case .strength: return strength
        case .dexterity: return dexterity
        case .intelligence: return intelligence
        case .endurance: return endurance
        case .luck: return luck
        }
    }

    public mutating func set(_ id: RPGAttributeID, _ value: Int) {
        switch id {
        case .strength: strength = value
        case .dexterity: dexterity = value
        case .intelligence: intelligence = value
        case .endurance: endurance = value
        case .luck: luck = value
        }
    }

    public func clamped(maximum: Int = RPGAttributes.maximumWithProgression) -> RPGAttributes {
        RPGAttributes(
            strength: clampAttribute(strength, maximum: maximum),
            dexterity: clampAttribute(dexterity, maximum: maximum),
            intelligence: clampAttribute(intelligence, maximum: maximum),
            endurance: clampAttribute(endurance, maximum: maximum),
            luck: clampAttribute(luck, maximum: maximum)
        )
    }
}

private func clampAttribute(_ value: Int, maximum: Int) -> Int {
    max(RPGAttributes.minimum, min(maximum, value))
}

public enum RPGActionKind: String, Codable, Equatable {
    case passive
    case active
}

/// Closed, compiler-checked identifiers for every shipped skill effect. Runtime
/// consumers switch on this type instead of comparing untrusted save strings.
public enum RPGSkillEffectID: String, Codable, CaseIterable, Hashable {
    case guardStance = "guard_stance"
    case interpose
    case anchorLine = "anchor_line"
    case heavyCut = "heavy_cut"
    case chargeBreak = "charge_break"
    case staggerChain = "stagger_chain"
    case shieldBind = "shield_bind"
    case plateTraining = "plate_training"
    case fortifyBlock = "fortify_block"
    case quickDraw = "quick_draw"
    case steadyAim = "steady_aim"
    case cripplingShot = "crippling_shot"
    case trailSense = "trail_sense"
    case softStep = "soft_step"
    case farSight = "far_sight"
    case campcraft
    case weatherEye = "weather_eye"
    case beastKinship = "beast_kinship"
    case veinReader = "vein_reader"
    case fastBore = "fast_bore"
    case deepReserves = "deep_reserves"
    case trapProbe = "trap_probe"
    case tripwireMind = "tripwire_mind"
    case deadfall
    case salvageEye = "salvage_eye"
    case lockTouch = "lock_touch"
    case fortuneRead = "fortune_read"
    case spellFormula = "spell_formula"
    case sparkWeave = "spark_weave"
    case stormFocus = "storm_focus"
    case minorGlamour = "minor_glamour"
    case falseStep = "false_step"
    case mirrorWork = "mirror_work"
    case ritualCircle = "ritual_circle"
    case boundServant = "bound_servant"
    case wardScribe = "ward_scribe"
    case fieldDressing = "field_dressing"
    case triage
    case secondBreath = "second_breath"
    case herbalLore = "herbal_lore"
    case cleanBrew = "clean_brew"
    case greenThumb = "green_thumb"
    case safeHaven = "safe_haven"
    case protectiveMark = "protective_mark"
    case sanctuaryBell = "sanctuary_bell"
    case circuitSense = "circuit_sense"
    case compactGate = "compact_gate"
    case remoteTrigger = "remote_trigger"
    case fieldMod = "field_mod"
    case quickRepair = "quick_repair"
    case toolTune = "tool_tune"
    case chargePack = "charge_pack"
    case blastShape = "blast_shape"
    case safeFuse = "safe_fuse"
}

public struct RPGSpellUnlock: Codable, Equatable, Hashable {
    public var spellID: String
    public var rank: Int

    public init(_ spellID: String, rank: Int) {
        self.spellID = spellID
        self.rank = max(1, min(3, rank))
    }
}

public struct RPGSkillEffectContract: Equatable {
    public var values: [Double]
    public var benefits: [String]
    public var spellUnlocks: [RPGSpellUnlock]

    public init(values: [Double], benefits: [String], spellUnlocks: [RPGSpellUnlock] = []) {
        precondition(values.count == 3 && benefits.count == 3, "RPG skills require exactly three rank effects")
        self.values = values
        self.benefits = benefits
        self.spellUnlocks = spellUnlocks
    }
}

/// The exhaustive rank-effect registry. Adding an enum case cannot compile
/// until its three values, three benefit strings, and spell unlock ranks exist.
public func rpgSkillEffectContract(_ id: RPGSkillEffectID) -> RPGSkillEffectContract {
    func c(_ values: [Double], _ benefits: [String], _ unlocks: [RPGSpellUnlock] = []) -> RPGSkillEffectContract {
        RPGSkillEffectContract(values: values, benefits: benefits, spellUnlocks: unlocks)
    }
    switch id {
    case .guardStance:
        return c([1, 2, 3], ["+1 maximum health", "+2 maximum health", "+3 maximum health"])
    case .interpose:
        return c([3, 4, 5], ["Grant 3 absorption", "Grant 4 absorption", "Grant 5 absorption"])
    case .anchorLine:
        return c([0.35, 0.50, 0.65], ["Brace and pull with light force", "Brace and pull with medium force", "Brace and pull with strong force"])
    case .heavyCut:
        return c([2, 4, 6], ["Weapon strike deals +2 damage", "Weapon strike deals +4 damage", "Weapon strike deals +6 damage"])
    case .chargeBreak:
        return c([4, 6, 8], ["Rush for 4 damage", "Rush for 6 damage", "Rush for 8 damage"])
    case .staggerChain:
        return c([40, 80, 120], ["Heavy Cut slow lasts +40 ticks", "Heavy Cut slow lasts +80 ticks", "Heavy Cut slow lasts +120 ticks"])
    case .shieldBind:
        return c([1, 2, 3], ["+1 maximum fatigue", "+2 maximum fatigue", "+3 maximum fatigue"])
    case .plateTraining:
        return c([0.002, 0.004, 0.006], ["+0.002 fatigue per tick", "+0.004 fatigue per tick", "+0.006 fatigue per tick"])
    case .fortifyBlock:
        return c([1, 2, 3], ["Block absorbs 1 explosion destruction", "Block absorbs 2 explosion destructions", "Block absorbs 3 explosion destructions"])
    case .quickDraw:
        return c([2, 4, 6], ["Bow reaches power 2 ticks sooner", "Bow reaches power 4 ticks sooner", "Bow reaches power 6 ticks sooner"])
    case .steadyAim:
        return c([0.15, 0.30, 0.45], ["Grounded bow spread -15%", "Grounded bow spread -30%", "Grounded bow spread -45%"])
    case .cripplingShot:
        return c([120, 180, 240], ["Slow target for 120 ticks", "Slow target for 180 ticks", "Slow target for 240 ticks"])
    case .trailSense:
        return c([8, 12, 16], ["Sneaking reveals hostiles within 8 blocks", "Sneaking reveals hostiles within 12 blocks", "Sneaking reveals hostiles within 16 blocks"])
    case .softStep:
        return c([0.05, 0.10, 0.15], ["Sneaking movement +5%", "Sneaking movement +10%", "Sneaking movement +15%"])
    case .farSight:
        return c([16, 24, 32], ["Reveal up to 8 hostiles within 16 blocks", "Reveal up to 8 hostiles within 24 blocks", "Reveal up to 8 hostiles within 32 blocks"])
    case .campcraft:
        return c([0.005, 0.010, 0.015], ["Safe rest regen +0.005 per tick", "Safe rest regen +0.010 per tick", "Safe rest regen +0.015 per tick"])
    case .weatherEye:
        return c([600, 200, 20], ["Weather HUD shows the next transition rounded up to 30 seconds", "Weather HUD shows the next transition rounded up to 10 seconds", "Weather HUD shows the next transition rounded up to 1 second"])
    case .beastKinship:
        return c([4, 7, 10], ["Animals ignore you within 4 blocks", "Animals ignore you within 7 blocks", "Animals ignore you within 10 blocks"])
    case .veinReader:
        return c([0.10, 0.20, 0.30], ["Stone and ore mining +10%", "Stone and ore mining +20%", "Stone and ore mining +30%"])
    case .fastBore:
        return c([1, 2, 3], ["Haste I mining burst", "Haste II mining burst", "Haste III mining burst"])
    case .deepReserves:
        return c([0.1, 0.2, 0.3], ["Deep hard blocks restore 0.1 fatigue", "Deep hard blocks restore 0.2 fatigue", "Deep hard blocks restore 0.3 fatigue"])
    case .trapProbe:
        return c([6, 8, 10], ["Reveal traps within 6 blocks", "Reveal traps within 8 blocks", "Reveal traps within 10 blocks"])
    case .tripwireMind:
        return c([0.15, 0.30, 0.45], ["Explosion and trap damage -15%", "Explosion and trap damage -30%", "Explosion and trap damage -45%"])
    case .deadfall:
        return c([80, 120, 160], ["Place an 80-tick gravel trap", "Place a 120-tick gravel trap", "Place a 160-tick gravel trap"])
    case .salvageEye:
        return c([12, 8, 5], ["Every 12th crafted-block break preserves durability", "Every 8th crafted-block break preserves durability", "Every 5th crafted-block break preserves durability"])
    case .lockTouch:
        return c([4, 8, 16], ["Inspect up to 4 occupied slots", "Inspect up to 8 occupied slots", "Inspect up to 16 occupied slots"])
    case .fortuneRead:
        return c([1, 2, 3], ["Reveal one item and coarse fill", "Reveal one item and medium fill", "Reveal one item and exact fill"])
    case .spellFormula:
        return c([0.5, 1.0, 1.5], ["Spell damage +0.5; unlock Ignite", "Spell damage +1.0; unlock Frost Ray", "Spell damage +1.5"], [RPGSpellUnlock("ignite", rank: 1), RPGSpellUnlock("frost_ray", rank: 2)])
    case .sparkWeave:
        return c([0.5, 1.0, 1.5], ["Elemental fatigue cost -0.5", "Elemental fatigue cost -1.0; unlock Shock", "Elemental fatigue cost -1.5"], [RPGSpellUnlock("shock", rank: 2)])
    case .stormFocus:
        return c([1.5, 2.0, 2.5], ["Storm Aura damage 1.5", "Storm Aura damage 2.0; unlock Storm Aura", "Storm Aura damage 2.5"], [RPGSpellUnlock("storm_aura", rank: 2)])
    case .minorGlamour:
        return c([1.10, 1.20, 1.30], ["Illusion duration x1.10; unlock Blur", "Illusion duration x1.20; unlock Decoy", "Illusion duration x1.30"], [RPGSpellUnlock("blur", rank: 1), RPGSpellUnlock("decoy", rank: 2)])
    case .falseStep:
        return c([1, 2, 3], ["Shadow Step range +1", "Shadow Step range +2; unlock Shadow Step", "Shadow Step range +3"], [RPGSpellUnlock("shadow_step", rank: 2)])
    case .mirrorWork:
        return c([2, 3, 4], ["Mirror Image grants 2 absorption", "Mirror Image grants 3 absorption; unlock Mirror Image", "Mirror Image grants 4 absorption"], [RPGSpellUnlock("mirror_image", rank: 2)])
    case .ritualCircle:
        return c([1.10, 1.25, 1.40], ["Ritual duration x1.10; unlock Mage Light", "Ritual duration x1.25; unlock Ward", "Ritual duration x1.40"], [RPGSpellUnlock("mage_light", rank: 1), RPGSpellUnlock("ward", rank: 2)])
    case .boundServant:
        return c([400, 600, 800], ["Servant lasts 400 ticks", "Servant lasts 600 ticks; unlock Summon Servant", "Servant lasts 800 ticks"], [RPGSpellUnlock("summon_servant", rank: 2)])
    case .wardScribe:
        return c([1, 2, 3], ["Wards absorb 1 explosion", "Wards absorb 2 explosions; unlock Stone Ward", "Wards absorb 3 explosions"], [RPGSpellUnlock("stone_ward", rank: 2)])
    case .fieldDressing:
        return c([1, 2, 3], ["Healing spells restore +1; unlock Mend Wounds", "Healing spells restore +2", "Healing spells restore +3"], [RPGSpellUnlock("mend_wounds", rank: 1)])
    case .triage:
        return c([0.10, 0.20, 0.30], ["Low-health healing +10%", "Low-health healing +20%; unlock Restore", "Low-health healing +30%"], [RPGSpellUnlock("restore", rank: 2)])
    case .secondBreath:
        return c([8, 11, 14], ["Emergency heal 8", "Emergency heal 11", "Emergency heal 14"])
    case .herbalLore:
        return c([0.5, 1.0, 1.5], ["Typed plant food restores 0.5 fatigue; unlock Purify", "Typed plant food restores 1.0 fatigue", "Typed plant food restores 1.5 fatigue"], [RPGSpellUnlock("purify", rank: 1)])
    case .cleanBrew:
        return c([1.10, 1.20, 1.30], ["Beneficial food and potion effects x1.10", "Beneficial food and potion effects x1.20", "Beneficial food and potion effects x1.30"])
    case .greenThumb:
        return c([0.1, 0.2, 0.3], ["Mature crops restore 0.1 fatigue", "Mature crops restore 0.2 fatigue", "Mature crops restore 0.3 fatigue"])
    case .safeHaven:
        return c([4, 6, 8], ["Restore 4 fatigue; unlock Ward", "Restore 6 fatigue", "Restore 8 fatigue"], [RPGSpellUnlock("ward", rank: 1)])
    case .protectiveMark:
        return c([2, 4, 6], ["Ward and Aegis absorption +2", "Ward and Aegis absorption +4; unlock Aegis", "Ward and Aegis absorption +6"], [RPGSpellUnlock("aegis", rank: 2)])
    case .sanctuaryBell:
        return c([6, 8, 10], ["Sanctuary radius 6", "Sanctuary radius 8; unlock Sanctuary", "Sanctuary radius 10"], [RPGSpellUnlock("sanctuary", rank: 2)])
    case .circuitSense:
        return c([4, 6, 8], ["Crosshair-inspect redstone signal within 4 blocks", "Crosshair-inspect signal and configured repeater delay within 6 blocks", "Crosshair-inspect signal, configured repeater delay, and nearest powered source direction within 8 blocks"])
    case .compactGate:
        return c([20, 40, 60], ["Remote Trigger recovery -20 ticks", "Remote Trigger recovery -40 ticks", "Remote Trigger recovery -60 ticks"])
    case .remoteTrigger:
        return c([6, 8, 10], ["Trigger a device within 6 blocks", "Trigger a device within 8 blocks", "Trigger a device within 10 blocks"])
    case .fieldMod:
        return c([1, 2, 3], ["Haste and tuning I", "Haste and tuning II", "Haste and tuning III"])
    case .quickRepair:
        return c([0.15, 0.25, 0.35], ["Repair 15% durability", "Repair 25% durability", "Repair 35% durability"])
    case .toolTune:
        return c([8, 6, 4], ["Every 8th tool durability event is preserved", "Every 6th tool durability event is preserved", "Every 4th tool durability event is preserved"])
    case .chargePack:
        return c([400, 600, 800], ["Controlled charge remains armed for 400 ticks", "Controlled charge remains armed for 600 ticks", "Controlled charge remains armed for 800 ticks"])
    case .blastShape:
        return c([0.15, 0.30, 0.45], ["Self-inflicted explosion damage -15%", "Self-inflicted explosion damage -30%", "Self-inflicted explosion damage -45%"])
    case .safeFuse:
        return c([4, 6, 8], ["Refund your charge within 4 blocks", "Refund your charge within 6 blocks", "Refund your charge within 8 blocks"])
    }
}

public enum RPGPreparedActionKind: String, Codable, Equatable {
    case skill
    case spell
}

public struct RPGPreparedAction: Equatable {
    public var kind: RPGPreparedActionKind
    public var id: String
    public var displayName: String
    public var iconAssetID: String
    public var fatigueCost: Double
    public var cooldownTicks: Int
    public var cooldownRemainingTicks: Int
    public var available: Bool
    public var statusText: String

    public var token: String { rpgPreparedActionToken(kind: kind, id: id) }
}

public func rpgPreparedActionToken(kind: RPGPreparedActionKind, id: String) -> String {
    "\(kind.rawValue):\(id)"
}

public func rpgParsePreparedActionToken(_ token: String?) -> (kind: RPGPreparedActionKind, id: String)? {
    guard let token else { return nil }
    let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let kind = RPGPreparedActionKind(rawValue: parts[0]),
          rpgIsBoundedID(parts[1]) else {
        return nil
    }
    return (kind, parts[1])
}

public enum RPGSpellTargetKind: String, Codable {
    case selfTarget
    case touch
    case ray
    case area
    case summon
    case placed
}

public enum RPGSpellCategory: String, Codable, Hashable {
    case damage
    case defense
    case movement
    case utility
    case illusion
    case creation
    case healing
    case control
}

public struct RPGAttributeRequirement: Codable, Equatable {
    public var attribute: RPGAttributeID
    public var minimum: Int

    public init(_ attribute: RPGAttributeID, _ minimum: Int) {
        self.attribute = attribute
        self.minimum = minimum
    }
}

public struct RPGPathDefinition: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var summary: String
    public var primaryAttributes: [RPGAttributeID]
    public var branchIDs: [String]
    public var starterSkillIDs: [String]
    public var starterSpellIDs: [String]

    public init(id: String, displayName: String, summary: String, primaryAttributes: [RPGAttributeID],
                branchIDs: [String], starterSkillIDs: [String], starterSpellIDs: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.primaryAttributes = primaryAttributes
        self.branchIDs = branchIDs
        self.starterSkillIDs = starterSkillIDs
        self.starterSpellIDs = starterSpellIDs
    }
}

public struct RPGBranchDefinition: Codable, Equatable {
    public var id: String
    public var pathID: String
    public var displayName: String
    public var summary: String
    public var skillIDs: [String]

    public init(id: String, pathID: String, displayName: String, summary: String, skillIDs: [String]) {
        self.id = id
        self.pathID = pathID
        self.displayName = displayName
        self.summary = summary
        self.skillIDs = skillIDs
    }
}

public struct RPGSkillDefinition: Codable, Equatable {
    public var id: String
    public var pathID: String
    public var branchID: String
    public var displayName: String
    public var kind: RPGActionKind
    public var requirements: [RPGAttributeRequirement]
    public var prerequisiteSkillIDs: [String]
    public var cooldownTicks: Int
    public var fatigueCost: Double
    public var effectID: RPGSkillEffectID
    /// Three canonical numeric values, indexed by learned rank minus one.
    public var rankValues: [Double]
    /// Three canonical player-facing benefits, indexed by learned rank minus one.
    public var rankBenefits: [String]
    public var spellUnlocks: [RPGSpellUnlock]

    /// Generated from the exhaustive typed rank contract so UI copy cannot
    /// drift from the values gameplay actually consumes.
    public var summary: String {
        rankBenefits.enumerated()
            .map { "Rank \($0.offset + 1): \($0.element)" }
            .joined(separator: " • ")
    }

    public init(id: String, pathID: String, branchID: String, displayName: String,
                kind: RPGActionKind = .passive,
                requirements: [RPGAttributeRequirement] = [], prerequisiteSkillIDs: [String] = [],
                cooldownTicks: Int = 0, fatigueCost: Double = 0) {
        self.id = id
        self.pathID = pathID
        self.branchID = branchID
        self.displayName = displayName
        self.kind = kind
        guard let effectID = RPGSkillEffectID(rawValue: id) else {
            preconditionFailure("missing typed RPG skill effect for \(id)")
        }
        let contract = rpgSkillEffectContract(effectID)
        self.requirements = requirements
        self.prerequisiteSkillIDs = prerequisiteSkillIDs
        self.cooldownTicks = max(0, cooldownTicks)
        self.fatigueCost = max(0, fatigueCost)
        self.effectID = effectID
        self.rankValues = contract.values
        self.rankBenefits = contract.benefits
        self.spellUnlocks = contract.spellUnlocks
    }
}

public struct RPGSpellDefinition: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var summary: String
    public var circle: Int
    public var categories: [RPGSpellCategory]
    public var targetKind: RPGSpellTargetKind
    public var rangeBlocks: Double
    public var radiusBlocks: Double
    public var durationTicks: Int
    public var fatigueCost: Double
    public var upkeepCostPerSecond: Double
    public var minimumIntelligence: Int
    public var prerequisiteSkillIDs: [String]
    public var actionSequenceWindow: Int

    public init(id: String, displayName: String, summary: String, circle: Int,
                categories: [RPGSpellCategory], targetKind: RPGSpellTargetKind, rangeBlocks: Double,
                radiusBlocks: Double = 0, durationTicks: Int = 0, fatigueCost: Double,
                upkeepCostPerSecond: Double = 0, minimumIntelligence: Int,
                prerequisiteSkillIDs: [String], actionSequenceWindow: Int = 0) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.circle = max(1, circle)
        self.categories = categories
        self.targetKind = targetKind
        self.rangeBlocks = max(0, rangeBlocks)
        self.radiusBlocks = max(0, radiusBlocks)
        self.durationTicks = max(0, durationTicks)
        self.fatigueCost = max(0, fatigueCost)
        self.upkeepCostPerSecond = max(0, upkeepCostPerSecond)
        self.minimumIntelligence = minimumIntelligence
        self.prerequisiteSkillIDs = prerequisiteSkillIDs
        self.actionSequenceWindow = max(0, actionSequenceWindow)
    }
}

public struct RPGCooldown: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case id, remainingTicks }

    public var id: String
    public var remainingTicks: Int

    public init(id: String, remainingTicks: Int) {
        self.id = id
        self.remainingTicks = max(0, remainingTicks)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let ticks = try c.decode(Int.self, forKey: .remainingTicks)
        guard rpgIsBoundedID(id), ticks > 0, ticks <= RPG_MAX_EFFECT_TICKS else {
            throw DecodingError.dataCorruptedError(forKey: .remainingTicks, in: c,
                                                    debugDescription: "invalid RPG cooldown")
        }
        self.id = id
        remainingTicks = ticks
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rpgIsBoundedID(id) ? id : "", forKey: .id)
        try c.encode(max(0, min(RPG_MAX_EFFECT_TICKS, remainingTicks)), forKey: .remainingTicks)
    }
}

public struct RPGUpkeep: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case spellID, ownerSequence, remainingTicks, costPerSecond }

    public var spellID: String
    public var ownerSequence: Int
    public var remainingTicks: Int
    public var costPerSecond: Double

    public init(spellID: String, ownerSequence: Int, remainingTicks: Int, costPerSecond: Double) {
        self.spellID = spellID
        self.ownerSequence = max(0, min(RPG_MAX_COUNTER, ownerSequence))
        self.remainingTicks = max(0, min(RPG_MAX_EFFECT_TICKS, remainingTicks))
        self.costPerSecond = costPerSecond.isFinite ? max(0, min(100, costPerSecond)) : 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let spellID = try c.decode(String.self, forKey: .spellID)
        let ownerSequence = try c.decode(Int.self, forKey: .ownerSequence)
        let remainingTicks = try c.decode(Int.self, forKey: .remainingTicks)
        let cost = try c.decode(Double.self, forKey: .costPerSecond)
        guard rpgIsBoundedID(spellID), ownerSequence >= 0, ownerSequence <= RPG_MAX_COUNTER,
              remainingTicks > 0, remainingTicks <= RPG_MAX_EFFECT_TICKS,
              cost.isFinite, cost > 0, cost <= 100 else {
            throw DecodingError.dataCorruptedError(forKey: .spellID, in: c,
                                                    debugDescription: "invalid RPG upkeep")
        }
        self.spellID = spellID
        self.ownerSequence = ownerSequence
        self.remainingTicks = remainingTicks
        costPerSecond = cost
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rpgIsBoundedID(spellID) ? spellID : "", forKey: .spellID)
        try c.encode(max(0, min(RPG_MAX_COUNTER, ownerSequence)), forKey: .ownerSequence)
        try c.encode(max(0, min(RPG_MAX_EFFECT_TICKS, remainingTicks)), forKey: .remainingTicks)
        let cost = costPerSecond.isFinite ? max(0, min(100, costPerSecond)) : 0
        try c.encode(cost, forKey: .costPerSecond)
    }
}

public enum RPGXPEventCategory: String, Codable, CaseIterable {
    case combat
    case explore
    case depthDungeon = "depth_dungeon"
    case cast
    case heal
    case engineer

    public var windowLimit: Int {
        switch self {
        case .combat: return 6
        case .explore, .depthDungeon, .cast, .heal, .engineer: return 8
        }
    }
}

public enum RPGXPEventKind: String, Codable, CaseIterable {
    case wardenMeleeDefeat
    case wardenMitigation
    case rangerRangedDefeat
    case rangerFieldDiscovery
    case delverDepthMilestone
    case delverDungeonMilestone
    case delverExcavation
    case arcanistSpellDefeat
    case arcanistSpellPractice
    case menderEffectiveHealing
    case menderCleanseRescue
    case menderProvisionCraft
    case tinkerFirstRecipe
    case tinkerMechanismTransition
    case tinkerEngineeringCraft

    public var category: RPGXPEventCategory {
        switch self {
        case .wardenMeleeDefeat, .wardenMitigation, .rangerRangedDefeat, .arcanistSpellDefeat: return .combat
        case .rangerFieldDiscovery: return .explore
        case .delverDepthMilestone, .delverDungeonMilestone, .delverExcavation: return .depthDungeon
        case .arcanistSpellPractice: return .cast
        case .menderEffectiveHealing, .menderCleanseRescue, .menderProvisionCraft: return .heal
        case .tinkerFirstRecipe, .tinkerMechanismTransition, .tinkerEngineeringCraft: return .engineer
        }
    }
}

public enum RPGXPLifetimeKeyKind: String, Codable, CaseIterable, Hashable {
    case rangerFieldDiscovery
    case delverDungeon
    case tinkerMechanism
}

/// Decode-only identity retained for saves produced before discovery dedup was
/// converted to a rolling ring. New saves never encode lifetime admission state.
public struct RPGXPLifetimeKey: Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey { case kind, key }

    public var kind: RPGXPLifetimeKeyKind
    public var key: String

    public init(kind: RPGXPLifetimeKeyKind, key: String) {
        self.kind = kind
        self.key = rpgIsBoundedID(key) ? key : ""
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(RPGXPLifetimeKeyKind.self, forKey: .kind)
        let decodedKey = try c.decode(String.self, forKey: .key)
        guard rpgIsBoundedID(decodedKey) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c,
                                                    debugDescription: "unbounded RPG XP key")
        }
        key = decodedKey
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(rpgIsBoundedID(key) ? key : "", forKey: .key)
    }
}

/// Exact, registry-bounded XP proposal. `magnitude` is actual effective health
/// for healing; `registryIndex` identifies a finite spell/milestone/recipe bit.
public struct RPGXPEvent: Equatable {
    public var kind: RPGXPEventKind
    public var key: String
    public var magnitude: Int
    public var registryIndex: Int?

    public init(kind: RPGXPEventKind, key: String, magnitude: Int = 1, registryIndex: Int? = nil) {
        self.kind = kind
        self.key = rpgIsBoundedID(key) ? key : ""
        self.magnitude = magnitude
        self.registryIndex = registryIndex
    }
}

public struct RPGXPWindowCounts: Codable, Equatable {
    public var combat = 0
    public var explore = 0
    public var depthDungeon = 0
    public var cast = 0
    public var heal = 0
    public var engineer = 0

    public init() {}

    public func value(_ category: RPGXPEventCategory) -> Int {
        switch category {
        case .combat: return combat
        case .explore: return explore
        case .depthDungeon: return depthDungeon
        case .cast: return cast
        case .heal: return heal
        case .engineer: return engineer
        }
    }

    public mutating func increment(_ category: RPGXPEventCategory) {
        switch category {
        case .combat: combat = min(category.windowLimit, combat + 1)
        case .explore: explore = min(category.windowLimit, explore + 1)
        case .depthDungeon: depthDungeon = min(category.windowLimit, depthDungeon + 1)
        case .cast: cast = min(category.windowLimit, cast + 1)
        case .heal: heal = min(category.windowLimit, heal + 1)
        case .engineer: engineer = min(category.windowLimit, engineer + 1)
        }
    }

    public func repaired() -> RPGXPWindowCounts {
        var out = RPGXPWindowCounts()
        out.combat = max(0, min(RPGXPEventCategory.combat.windowLimit, combat))
        out.explore = max(0, min(RPGXPEventCategory.explore.windowLimit, explore))
        out.depthDungeon = max(0, min(RPGXPEventCategory.depthDungeon.windowLimit, depthDungeon))
        out.cast = max(0, min(RPGXPEventCategory.cast.windowLimit, cast))
        out.heal = max(0, min(RPGXPEventCategory.heal.windowLimit, heal))
        out.engineer = max(0, min(RPGXPEventCategory.engineer.windowLimit, engineer))
        return out
    }
}

public struct RPGXPLedger: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case windowStartTick, counts, recentKeys, lifetimeKeys, spellDay, distinctSpellMask
        case depthMilestoneMask, dungeonMilestoneMask, recipeMilestoneMask, recipeMilestoneWords
    }

    public var windowStartTick: Int
    public var counts: RPGXPWindowCounts
    public var recentKeys: [String]
    /// Legacy v2 field retained only for decode compatibility; spell practice
    /// now resets this mask on the global 1,200-tick XP window.
    public var spellDay: Int
    public var distinctSpellMask: UInt32
    public var depthMilestoneMask: UInt64
    public var dungeonMilestoneMask: UInt64
    public var recipeMilestoneWords: [UInt64]

    public init(windowStartTick: Int = 0,
                counts: RPGXPWindowCounts = RPGXPWindowCounts(),
                recentKeys: [String] = [],
                spellDay: Int = 0,
                distinctSpellMask: UInt32 = 0,
                depthMilestoneMask: UInt64 = 0,
                dungeonMilestoneMask: UInt64 = 0,
                recipeMilestoneWords: [UInt64] = []) {
        self.windowStartTick = windowStartTick
        self.counts = counts
        self.recentKeys = recentKeys
        self.spellDay = spellDay
        self.distinctSpellMask = distinctSpellMask
        self.depthMilestoneMask = depthMilestoneMask
        self.dungeonMilestoneMask = dungeonMilestoneMask
        self.recipeMilestoneWords = recipeMilestoneWords
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var keys: [String] = []
        if var u = try? c.nestedUnkeyedContainer(forKey: .recentKeys) {
            var rawCount = 0
            while !u.isAtEnd && rawCount < RPG_MAX_XP_EVENT_KEYS {
                rawCount += 1
                let key = try u.decode(String.self)
                guard rpgIsBoundedID(key) else {
                    throw DecodingError.dataCorruptedError(in: u,
                                                           debugDescription: "invalid RPG XP dedup key")
                }
                if !keys.contains(key) { keys.append(key) }
            }
        }
        var lifetime: [RPGXPLifetimeKey] = []
        if var u = try? c.nestedUnkeyedContainer(forKey: .lifetimeKeys) {
            var rawCount = 0
            while !u.isAtEnd && rawCount < RPG_MAX_XP_EVENT_KEYS {
                rawCount += 1
                let value = try u.decode(RPGXPLifetimeKey.self)
                guard rpgIsBoundedID(value.key) else {
                    throw DecodingError.dataCorruptedError(in: u,
                                                           debugDescription: "invalid RPG XP lifetime key")
                }
                if !lifetime.contains(value) { lifetime.append(value) }
            }
        }
        let historicalThenRecent = lifetime.map(\.key) + keys
        var seen = Set<String>()
        var newestFirst: [String] = []
        for key in historicalThenRecent.reversed() where seen.insert(key).inserted {
            newestFirst.append(key)
        }
        var mergedKeys = Array(newestFirst.reversed())
        if mergedKeys.count > RPG_MAX_XP_EVENT_KEYS {
            mergedKeys = Array(mergedKeys.suffix(RPG_MAX_XP_EVENT_KEYS))
        }
        self.init(
            windowStartTick: try c.decodeIfPresent(Int.self, forKey: .windowStartTick) ?? 0,
            counts: try c.decodeIfPresent(RPGXPWindowCounts.self, forKey: .counts) ?? RPGXPWindowCounts(),
            recentKeys: mergedKeys,
            spellDay: try c.decodeIfPresent(Int.self, forKey: .spellDay) ?? 0,
            distinctSpellMask: try c.decodeIfPresent(UInt32.self, forKey: .distinctSpellMask) ?? 0,
            depthMilestoneMask: try c.decodeIfPresent(UInt64.self, forKey: .depthMilestoneMask) ?? 0,
            dungeonMilestoneMask: try c.decodeIfPresent(UInt64.self, forKey: .dungeonMilestoneMask) ?? 0,
            recipeMilestoneWords: try decodeCappedArray(UInt64.self, from: c,
                                                        key: .recipeMilestoneWords,
                                                        limit: RPG_MAX_RECIPE_MILESTONE_WORDS)
        )
        if recipeMilestoneWords.isEmpty,
           let legacyWord = try c.decodeIfPresent(UInt64.self, forKey: .recipeMilestoneMask), legacyWord != 0 {
            recipeMilestoneWords = [legacyWord]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(max(0, min(RPG_MAX_COUNTER, windowStartTick)), forKey: .windowStartTick)
        try c.encode(counts.repaired(), forKey: .counts)
        try c.encode(Array(recentKeys.filter(rpgIsBoundedID).suffix(RPG_MAX_XP_EVENT_KEYS)), forKey: .recentKeys)
        try c.encode(max(0, min(RPG_MAX_COUNTER, spellDay)), forKey: .spellDay)
        let spellMask = RPG_SPELL_DEFINITIONS.count >= 32
            ? distinctSpellMask
            : distinctSpellMask & ((UInt32(1) << UInt32(RPG_SPELL_DEFINITIONS.count)) - 1)
        try c.encode(spellMask, forKey: .distinctSpellMask)
        try c.encode(depthMilestoneMask, forKey: .depthMilestoneMask)
        try c.encode(dungeonMilestoneMask, forKey: .dungeonMilestoneMask)
        try c.encode(Array(recipeMilestoneWords.prefix(RPG_MAX_RECIPE_MILESTONE_WORDS)), forKey: .recipeMilestoneWords)
    }
}

private struct RPGDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func decodeCappedArray<T: Decodable, K: CodingKey>(_ type: T.Type,
                                                            from c: KeyedDecodingContainer<K>,
                                                            key: K,
                                                            limit: Int) throws -> [T] {
    guard var u = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
    var out: [T] = []
    while !u.isAtEnd && out.count < limit {
        out.append(try u.decode(T.self))
    }
    return out
}

private func decodeCappedBoundedIDs<K: CodingKey>(from c: KeyedDecodingContainer<K>,
                                                   key: K,
                                                   limit: Int) -> [String] {
    guard var u = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
    var out: [String] = []
    var consumed = 0
    while !u.isAtEnd && consumed < max(0, limit) {
        consumed += 1
        guard let value = try? u.decode(String.self) else { break }
        if rpgIsBoundedID(value) { out.append(value) }
    }
    return out
}

private func decodeBoundedID<K: CodingKey>(from c: KeyedDecodingContainer<K>, key: K) -> String? {
    guard let value = try? c.decode(String.self, forKey: key),
          rpgIsBoundedID(value) else { return nil }
    return value
}

private func canonicalPreparedActionToken(_ token: String?) -> String? {
    guard let parsed = rpgParsePreparedActionToken(token) else { return nil }
    return rpgPreparedActionToken(kind: parsed.kind, id: parsed.id)
}

private func decodeCappedOptionalStrings<K: CodingKey>(from c: KeyedDecodingContainer<K>,
                                                        key: K,
                                                        limit: Int) -> [String?] {
    guard var u = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
    var out: [String?] = []
    while !u.isAtEnd && out.count < limit {
        if (try? u.decodeNil()) == true { out.append(nil); continue }
        guard let value = try? u.decode(String.self) else { break }
        out.append(canonicalPreparedActionToken(value))
    }
    return out
}

public struct RPGCharacterState: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case version
        case created
        case pathID
        case starterSkillID
        case specializationBranchID
        case attributes
        case xp
        case level
        case skillRanks
        case preparedSkillIDs
        case knownSpellIDs
        case preparedSpellIDs
        case selectedPreparedSpellID
        case selectedPreparedActionID
        case fatigue
        case actionSequence
        case activeCooldowns
        case activeUpkeeps
        case kitGrantVersion
        case kitGrantID
        case authorityRevision
        case xpLedger
    }

    public var version: Int
    public var created: Bool
    public var pathID: String
    public var starterSkillID: String
    public var specializationBranchID: String
    public var attributes: RPGAttributes
    public var xp: Int
    public var level: Int
    public var skillRanks: [String: Int]
    public var preparedSkillIDs: [String]
    public var knownSpellIDs: [String]
    public var preparedSpellIDs: [String]
    public var selectedPreparedSpellID: String?
    public var selectedPreparedActionID: String?
    public var fatigue: Double
    public var actionSequence: Int
    public var activeCooldowns: [RPGCooldown]
    public var activeUpkeeps: [RPGUpkeep]
    public var kitGrantVersion: Int
    public var kitGrantID: String?
    public var authorityRevision: Int
    public var xpLedger: RPGXPLedger

    public init(version: Int = RPG_STATE_CURRENT_VERSION,
                created: Bool,
                pathID: String,
                starterSkillID: String = "",
                specializationBranchID: String = "",
                attributes: RPGAttributes,
                xp: Int,
                level: Int,
                skillRanks: [String: Int],
                preparedSkillIDs: [String],
                knownSpellIDs: [String],
                preparedSpellIDs: [String],
                selectedPreparedSpellID: String? = nil,
                selectedPreparedActionID: String? = nil,
                fatigue: Double,
                actionSequence: Int = 0,
                activeCooldowns: [RPGCooldown] = [],
                activeUpkeeps: [RPGUpkeep] = [],
                kitGrantVersion: Int = 0,
                kitGrantID: String? = nil,
                authorityRevision: Int = 0,
                xpLedger: RPGXPLedger = RPGXPLedger()) {
        self.version = version
        self.created = created
        self.pathID = pathID
        self.starterSkillID = starterSkillID
        self.specializationBranchID = specializationBranchID
        self.attributes = attributes
        self.xp = xp
        self.level = level
        self.skillRanks = skillRanks
        self.preparedSkillIDs = preparedSkillIDs
        self.knownSpellIDs = knownSpellIDs
        self.preparedSpellIDs = preparedSpellIDs
        self.selectedPreparedSpellID = selectedPreparedSpellID
        self.selectedPreparedActionID = selectedPreparedActionID
        self.fatigue = fatigue
        self.actionSequence = actionSequence
        self.activeCooldowns = activeCooldowns
        self.activeUpkeeps = activeUpkeeps
        self.kitGrantVersion = kitGrantVersion
        self.kitGrantID = kitGrantID
        self.authorityRevision = authorityRevision
        self.xpLedger = xpLedger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedRanks: [String: Int] = [:]
        if let dynamic = try? c.nestedContainer(keyedBy: RPGDynamicCodingKey.self, forKey: .skillRanks) {
            for effectID in RPGSkillEffectID.allCases.prefix(54) {
                guard let key = RPGDynamicCodingKey(stringValue: effectID.rawValue), dynamic.contains(key) else { continue }
                if let rank = try? dynamic.decode(Int.self, forKey: key) { decodedRanks[effectID.rawValue] = rank }
            }
        }
        self.init(
            version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 0,
            created: try c.decodeIfPresent(Bool.self, forKey: .created) ?? false,
            pathID: decodeBoundedID(from: c, key: .pathID) ?? "",
            starterSkillID: decodeBoundedID(from: c, key: .starterSkillID) ?? "",
            specializationBranchID: decodeBoundedID(from: c, key: .specializationBranchID) ?? "",
            attributes: try c.decodeIfPresent(RPGAttributes.self, forKey: .attributes) ?? .defaultCreation,
            xp: try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0,
            level: try c.decodeIfPresent(Int.self, forKey: .level) ?? 0,
            skillRanks: decodedRanks,
            preparedSkillIDs: decodeCappedBoundedIDs(from: c, key: .preparedSkillIDs, limit: RPG_MAX_PREPARED_SKILLS),
            knownSpellIDs: decodeCappedBoundedIDs(from: c, key: .knownSpellIDs, limit: RPG_SPELL_DEFINITIONS.count),
            preparedSpellIDs: decodeCappedBoundedIDs(from: c, key: .preparedSpellIDs, limit: RPG_MAX_PREPARED_SPELLS),
            selectedPreparedSpellID: decodeBoundedID(from: c, key: .selectedPreparedSpellID),
            selectedPreparedActionID: (try? c.decodeIfPresent(String.self, forKey: .selectedPreparedActionID))
                .flatMap(canonicalPreparedActionToken),
            fatigue: try c.decodeIfPresent(Double.self, forKey: .fatigue) ?? 0,
            actionSequence: try c.decodeIfPresent(Int.self, forKey: .actionSequence) ?? 0,
            activeCooldowns: try decodeCappedArray(RPGCooldown.self, from: c,
                                                   key: .activeCooldowns,
                                                   limit: RPG_MAX_COOLDOWNS),
            activeUpkeeps: try decodeCappedArray(RPGUpkeep.self, from: c,
                                                 key: .activeUpkeeps,
                                                 limit: RPG_MAX_UPKEEPS),
            kitGrantVersion: try c.decodeIfPresent(Int.self, forKey: .kitGrantVersion) ?? 0,
            kitGrantID: decodeBoundedID(from: c, key: .kitGrantID),
            authorityRevision: try c.decodeIfPresent(Int.self, forKey: .authorityRevision) ?? 0,
            xpLedger: try c.decodeIfPresent(RPGXPLedger.self, forKey: .xpLedger) ?? RPGXPLedger()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(max(0, min(RPG_STATE_CURRENT_VERSION, version)), forKey: .version)
        try c.encode(created, forKey: .created)
        try c.encode(rpgIsBoundedID(pathID) ? pathID : "", forKey: .pathID)
        try c.encode(rpgIsBoundedID(starterSkillID) ? starterSkillID : "", forKey: .starterSkillID)
        try c.encode(rpgIsBoundedID(specializationBranchID) ? specializationBranchID : "", forKey: .specializationBranchID)
        try c.encode(attributes.clamped(), forKey: .attributes)
        try c.encode(max(0, min(rpgXPRequiredForLevel(RPG_LEVEL_CAP), xp)), forKey: .xp)
        try c.encode(max(0, min(RPG_LEVEL_CAP, level)), forKey: .level)
        var encodedRanks: [String: Int] = [:]
        for definition in RPG_SKILL_DEFINITIONS.prefix(RPGSkillEffectID.allCases.count) {
            if let rank = skillRanks[definition.id], rank > 0 {
                encodedRanks[definition.id] = min(3, rank)
            }
        }
        try c.encode(encodedRanks, forKey: .skillRanks)
        try c.encode(Array(preparedSkillIDs.filter(rpgIsBoundedID).prefix(RPG_MAX_PREPARED_SKILLS)), forKey: .preparedSkillIDs)
        try c.encode(Array(knownSpellIDs.filter(rpgIsBoundedID).prefix(RPG_SPELL_DEFINITIONS.count)), forKey: .knownSpellIDs)
        try c.encode(Array(preparedSpellIDs.filter(rpgIsBoundedID).prefix(RPG_MAX_PREPARED_SPELLS)), forKey: .preparedSpellIDs)
        try c.encodeIfPresent(selectedPreparedSpellID.flatMap { rpgIsBoundedID($0) ? $0 : nil },
                              forKey: .selectedPreparedSpellID)
        try c.encodeIfPresent(canonicalPreparedActionToken(selectedPreparedActionID), forKey: .selectedPreparedActionID)
        try c.encode(fatigue.isFinite ? max(0, fatigue) : 0, forKey: .fatigue)
        try c.encode(max(0, min(RPG_MAX_COUNTER, actionSequence)), forKey: .actionSequence)
        let cooldowns = activeCooldowns.filter {
            rpgIsBoundedID($0.id) && $0.remainingTicks > 0 && $0.remainingTicks <= RPG_MAX_EFFECT_TICKS
        }
        try c.encode(Array(cooldowns.prefix(RPG_MAX_COOLDOWNS)), forKey: .activeCooldowns)
        let upkeeps = activeUpkeeps.filter {
            rpgIsBoundedID($0.spellID) && $0.ownerSequence >= 0 && $0.ownerSequence <= RPG_MAX_COUNTER
                && $0.remainingTicks > 0 && $0.remainingTicks <= RPG_MAX_EFFECT_TICKS
                && $0.costPerSecond.isFinite && $0.costPerSecond > 0 && $0.costPerSecond <= 100
        }
        try c.encode(Array(upkeeps.prefix(RPG_MAX_UPKEEPS)), forKey: .activeUpkeeps)
        try c.encode(max(0, min(RPG_STARTER_KIT_VERSION, kitGrantVersion)), forKey: .kitGrantVersion)
        try c.encodeIfPresent(kitGrantID.flatMap { rpgIsBoundedID($0) ? $0 : nil }, forKey: .kitGrantID)
        try c.encode(max(0, min(RPG_MAX_COUNTER, authorityRevision)), forKey: .authorityRevision)
        try c.encode(xpLedger, forKey: .xpLedger)
    }

    public static func uncreated() -> RPGCharacterState {
        RPGCharacterState(created: false, pathID: "", starterSkillID: "", specializationBranchID: "",
                          attributes: .defaultCreation, xp: 0, level: 0,
                          skillRanks: [:], preparedSkillIDs: [], knownSpellIDs: [], preparedSpellIDs: [],
                          selectedPreparedSpellID: nil,
                          selectedPreparedActionID: nil,
                          fatigue: 0)
    }
}

public struct RPGDerivedStats: Equatable {
    public var maxHealth: Double
    public var maxFatigue: Double
    public var fatigueRegenPerTick: Double
    public var meleeDamageBonus: Double
    public var actionAccuracyBonus: Double
    public var spellPotencyBonus: Double
    public var focusCostMultiplier: Double
    public var actionRecoveryMultiplier: Double
    public var exhaustionMultiplier: Double
    public var luckProcChance: Double

    public init(maxHealth: Double, maxFatigue: Double, fatigueRegenPerTick: Double,
                meleeDamageBonus: Double, actionAccuracyBonus: Double,
                spellPotencyBonus: Double, focusCostMultiplier: Double,
                actionRecoveryMultiplier: Double = 1,
                exhaustionMultiplier: Double = 1,
                luckProcChance: Double = 0) {
        self.maxHealth = maxHealth
        self.maxFatigue = maxFatigue
        self.fatigueRegenPerTick = fatigueRegenPerTick
        self.meleeDamageBonus = meleeDamageBonus
        self.actionAccuracyBonus = actionAccuracyBonus
        self.spellPotencyBonus = spellPotencyBonus
        self.focusCostMultiplier = focusCostMultiplier
        self.actionRecoveryMultiplier = actionRecoveryMultiplier
        self.exhaustionMultiplier = exhaustionMultiplier
        self.luckProcChance = luckProcChance
    }

    public static let vanilla = RPGDerivedStats(maxHealth: 20, maxFatigue: 0, fatigueRegenPerTick: 0,
                                                meleeDamageBonus: 0, actionAccuracyBonus: 0,
                                                spellPotencyBonus: 0, focusCostMultiplier: 1,
                                                actionRecoveryMultiplier: 1, exhaustionMultiplier: 1,
                                                luckProcChance: 0)
}

public struct RPGCreationDraft: Codable, Equatable {
    private enum CodingKeys: String, CodingKey { case pathID, attributes, starterSkillID, starterSpellIDs }

    public var pathID: String
    public var attributes: RPGAttributes
    public var starterSkillID: String?
    public var starterSpellIDs: [String]

    public init(pathID: String, attributes: RPGAttributes = .defaultCreation,
                starterSkillID: String? = nil, starterSpellIDs: [String] = []) {
        self.pathID = pathID
        self.attributes = attributes
        self.starterSkillID = starterSkillID
        self.starterSpellIDs = starterSpellIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pathID = decodeBoundedID(from: c, key: .pathID) ?? ""
        attributes = try c.decodeIfPresent(RPGAttributes.self, forKey: .attributes) ?? .defaultCreation
        starterSkillID = decodeBoundedID(from: c, key: .starterSkillID)
        starterSpellIDs = decodeCappedBoundedIDs(from: c, key: .starterSpellIDs,
                                                 limit: RPG_SPELL_DEFINITIONS.count)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rpgIsBoundedID(pathID) ? pathID : "", forKey: .pathID)
        try c.encode(attributes.clamped(maximum: RPGAttributes.maximumAtCreation), forKey: .attributes)
        try c.encodeIfPresent(starterSkillID.flatMap { rpgIsBoundedID($0) ? $0 : nil },
                              forKey: .starterSkillID)
        try c.encode(Array(starterSpellIDs.filter(rpgIsBoundedID).prefix(RPG_SPELL_DEFINITIONS.count)),
                     forKey: .starterSpellIDs)
    }
}

public extension GameCore {
    private var protocol5RPGSemanticDenial: String {
        "Character changes are unavailable in this LAN session"
    }

    @discardableResult
    func requestRPGCreateCharacter(_ draft: RPGCreationDraft) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if let error = player.createRPGCharacter(draft) {
            return error.description
        }
        materializeRPGPreferencesAfterCharacterCreationIfNeeded()
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .createCharacter, draft: draft, actionSequence: player.rpg.actionSequence))
        }
        return "Created \(rpgPathDefinition(player.rpg.pathID)?.displayName ?? "character")"
    }

    @discardableResult
    func requestRPGLearnSkill(_ skillID: String) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if let error = rpgLearnSkill(skillID, in: &player.rpg) {
            return error.description
        }
        player.applyRPGDerivedStats()
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .learnSkill, skillID: skillID, actionSequence: player.rpg.actionSequence))
        }
        return "Learned \(rpgSkillDefinition(skillID)?.displayName ?? skillID)"
    }

    @discardableResult
    func requestRPGTogglePreparedSkill(_ skillID: String) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if player.rpg.preparedSkillIDs.contains(skillID) {
            if let error = rpgUnprepareSkill(skillID, in: &player.rpg) {
                return error.description
            }
            if isLANClientWorld {
                lanRPGIntentHandler?(LANRPGIntent(action: .unprepareSkill, skillID: skillID, actionSequence: player.rpg.actionSequence))
            }
            return "Unprepared \(rpgSkillDefinition(skillID)?.displayName ?? skillID)"
        }
        if let error = rpgPrepareSkill(skillID, in: &player.rpg) {
            return error.description
        }
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .prepareSkill, skillID: skillID, actionSequence: player.rpg.actionSequence))
        }
        return "Prepared \(rpgSkillDefinition(skillID)?.displayName ?? skillID)"
    }

    @discardableResult
    func requestRPGTogglePreparedSpell(_ spellID: String) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if player.rpg.preparedSpellIDs.contains(spellID) {
            let endedUpkeeps = player.rpg.activeUpkeeps.filter { $0.spellID == spellID }
            if let error = rpgUnprepareSpell(spellID, in: &player.rpg) {
                return error.description
            }
            rpgCleanupEndedUpkeeps(player, endedUpkeeps)
            if isLANClientWorld {
                lanRPGIntentHandler?(LANRPGIntent(action: .unprepareSpell, spellID: spellID, actionSequence: player.rpg.actionSequence))
            }
            return "Unprepared \(rpgSpellDefinition(spellID)?.displayName ?? spellID)"
        }
        if let error = rpgPrepareSpell(spellID, in: &player.rpg) {
            return error.description
        }
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .prepareSpell, spellID: spellID, actionSequence: player.rpg.actionSequence))
        }
        return "Prepared \(rpgSpellDefinition(spellID)?.displayName ?? spellID)"
    }

    @discardableResult
    func requestRPGSelectPreparedSkill(_ skillID: String) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if let error = rpgSelectPreparedSkill(skillID, in: &player.rpg) {
            return error.description
        }
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .selectSkill, skillID: skillID, actionSequence: player.rpg.actionSequence))
        }
        return "Selected \(rpgSkillDefinition(skillID)?.displayName ?? skillID)"
    }

    @discardableResult
    func requestRPGSelectPreparedSpell(_ spellID: String) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if let error = rpgSelectPreparedSpell(spellID, in: &player.rpg) {
            return error.description
        }
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .selectSpell, spellID: spellID, actionSequence: player.rpg.actionSequence))
        }
        return "Selected \(rpgSpellDefinition(spellID)?.displayName ?? spellID)"
    }

    @discardableResult
    func requestRPGAssignPreparedActionToQuickSlot(kind: RPGPreparedActionKind, id: String, slot: Int) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        guard let preferences = rpgQuickSlotPreferences, rpgLocalPreferenceWritable else {
            return "RPG slots are unavailable"
        }
        let token = rpgPreparedActionToken(kind: kind, id: id)
        let candidate: RPGQuickSlotPreferences
        switch rpgAssignQuickSlot(token: token, slot: slot, preferences: preferences,
                                  state: repairRPGCharacterState(player.rpg)) {
        case .failure(let error): return rpgQuickSlotPreferenceErrorDescription(error)
        case .success(let value): candidate = value
        }
        guard persistRPGQuickSlotCandidate(candidate) else {
            return "Could not save RPG quick slots"
        }
        let name: String
        switch kind {
        case .skill: name = rpgSkillDefinition(id)?.displayName ?? id
        case .spell: name = rpgSpellDefinition(id)?.displayName ?? id
        }
        return "Saving slot \(slot + 1): \(name)"
    }

    @discardableResult
    func requestRPGClearActionQuickSlot(_ slot: Int) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        guard let preferences = rpgQuickSlotPreferences, rpgLocalPreferenceWritable else {
            return "RPG slots are unavailable"
        }
        let candidate: RPGQuickSlotPreferences
        switch rpgClearQuickSlot(slot, preferences: preferences,
                                 state: repairRPGCharacterState(player.rpg)) {
        case .failure(let error): return rpgQuickSlotPreferenceErrorDescription(error)
        case .success(let value): candidate = value
        }
        guard persistRPGQuickSlotCandidate(candidate) else {
            return "Could not save RPG quick slots"
        }
        return "Saving cleared slot \(slot + 1)"
    }

    @discardableResult
    func requestRPGMoveActionQuickSlot(from: Int, to: Int) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        guard let preferences = rpgQuickSlotPreferences, rpgLocalPreferenceWritable else {
            return "RPG slots are unavailable"
        }
        let candidate: RPGQuickSlotPreferences
        switch rpgMoveQuickSlot(from: from, to: to, preferences: preferences,
                                state: repairRPGCharacterState(player.rpg)) {
        case .failure(let error): return rpgQuickSlotPreferenceErrorDescription(error)
        case .success(let value): candidate = value
        }
        guard persistRPGQuickSlotCandidate(candidate) else {
            return "Could not save RPG quick slots"
        }
        return "Saving slot move"
    }

    @discardableResult
    func requestRPGSpendAttributePoint(_ attribute: RPGAttributeID) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        if let error = rpgSpendAttributePoint(attribute, in: &player.rpg) {
            return error.description
        }
        player.applyRPGDerivedStats()
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .spendAttribute, attribute: attribute, actionSequence: player.rpg.actionSequence))
        }
        return "+1 \(attribute.rawValue)"
    }

    @discardableResult
    func requestRPGCyclePreparedSpell(direction: Int = 1) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        let step = rpgNormalizedCycleDirection(direction)
        let spellID: String
        let changed: Bool
        switch rpgCyclePreparedSpell(player, direction: step) {
        case .noPreparedSpells: return "No prepared spells"
        case .authorityExhausted: return RPGProgressionError.authorityExhausted.description
        case .noOp(let id): spellID = id; changed = false
        case .selected(let id): spellID = id; changed = true
        }
        if isLANClientWorld, changed {
            lanRPGIntentHandler?(LANRPGIntent(action: .selectSpell, spellID: spellID, direction: step, actionSequence: player.rpg.actionSequence))
        }
        return "Selected \(rpgSpellDefinition(spellID)?.displayName ?? spellID)"
    }

    @discardableResult
    func requestRPGCyclePreparedAction(direction: Int = 1) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        let step = rpgNormalizedCycleDirection(direction)
        let action: RPGPreparedAction
        let changed: Bool
        switch rpgCyclePreparedAction(player, direction: step) {
        case .noPreparedActions: return "No prepared actions"
        case .authorityExhausted: return RPGProgressionError.authorityExhausted.description
        case .noOp(let value): action = value; changed = false
        case .selected(let value): action = value; changed = true
        }
        if isLANClientWorld, changed {
            switch action.kind {
            case .skill:
                lanRPGIntentHandler?(LANRPGIntent(action: .selectSkill, skillID: action.id, direction: step, actionSequence: player.rpg.actionSequence))
            case .spell:
                lanRPGIntentHandler?(LANRPGIntent(action: .selectSpell, spellID: action.id, direction: step, actionSequence: player.rpg.actionSequence))
            }
        }
        return "Selected \(action.displayName)"
    }

    @discardableResult
    func requestRPGCastSelectedSpell() -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        player.rpg = repairRPGCharacterState(player.rpg)
        guard let spellID = player.rpg.selectedPreparedSpellID ?? player.rpg.preparedSpellIDs.first else {
            return RPGActionFailure.spellNotPrepared("").description
        }
        if isLANClientWorld {
            guard player.rpg.created else { return RPGActionFailure.characterNotCreated.description }
            guard let spell = rpgSpellDefinition(spellID) else { return RPGActionFailure.unknownSpell(spellID).description }
            guard player.rpg.preparedSpellIDs.contains(spellID) else { return RPGActionFailure.spellNotPrepared(spellID).description }
            guard player.rpg.attributes.intelligence >= spell.minimumIntelligence else {
                return RPGActionFailure.insufficientIntelligence(required: spell.minimumIntelligence).description
            }
            guard !player.rpg.activeCooldowns.contains(where: { $0.id == spellID && $0.remainingTicks > 0 }) else {
                return RPGActionFailure.spellOnCooldown(spellID).description
            }
            guard player.rpg.fatigue >= spell.fatigueCost else {
                return RPGActionFailure.insufficientFatigue(required: spell.fatigueCost, available: player.rpg.fatigue).description
            }
            guard let nextSequence = rpgNextActionSequence(player.rpg) else { return "RPG action sequence is exhausted" }
            lanRPGIntentHandler?(LANRPGIntent(action: .castSpell, spellID: spellID, actionSequence: nextSequence))
            return "Casting \(spell.displayName)"
        }
        switch rpgCastPreparedSpell(player, spellID: spellID) {
        case .success(let result): return result.message
        case .failure(let error): return error.description
        }
    }

    @discardableResult
    func requestRPGUseSelectedAction() -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        player.rpg = repairRPGCharacterState(player.rpg)
        guard let action = rpgSelectedPreparedAction(player.rpg) else {
            return RPGActionFailure.actionNotPrepared.description
        }
        if isLANClientWorld {
            guard player.rpg.created else { return RPGActionFailure.characterNotCreated.description }
            guard action.available else {
                if action.cooldownRemainingTicks > 0 {
                    switch action.kind {
                    case .skill: return RPGActionFailure.skillOnCooldown(action.id).description
                    case .spell: return RPGActionFailure.spellOnCooldown(action.id).description
                    }
                }
                if action.kind == .spell,
                   let spell = rpgSpellDefinition(action.id),
                   player.rpg.attributes.intelligence < spell.minimumIntelligence {
                    return RPGActionFailure.insufficientIntelligence(required: spell.minimumIntelligence).description
                }
                return RPGActionFailure.insufficientFatigue(required: action.fatigueCost, available: player.rpg.fatigue).description
            }
            guard let nextSequence = rpgNextActionSequence(player.rpg) else { return "RPG action sequence is exhausted" }
            switch action.kind {
            case .skill:
                lanRPGIntentHandler?(LANRPGIntent(action: .useSkill, skillID: action.id, actionSequence: nextSequence))
            case .spell:
                lanRPGIntentHandler?(LANRPGIntent(action: .castSpell, spellID: action.id, actionSequence: nextSequence))
            }
            return "Using \(action.displayName)"
        }
        switch rpgUseSelectedPreparedAction(player) {
        case .success(let result): return result.message
        case .failure(let error): return error.description
        }
    }

    @discardableResult
    func requestRPGUseActionQuickSlot(_ slot: Int) -> String {
        guard !isLANClientWorld else { return protocol5RPGSemanticDenial }
        guard let player else { return "No player" }
        guard player.rpgClassesEnabled() else { return RPGActionFailure.classesDisabled.description }
        player.rpg = repairRPGCharacterState(player.rpg)
        guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else {
            return RPGActionFailure.actionNotPrepared.description
        }
        guard let preferences = rpgQuickSlotPreferences else { return "RPG slots are unavailable" }
        let actions = rpgActionQuickSlotActions(player.rpg, preferences: preferences)
        guard slot < actions.count, actions[slot] != nil else {
            return "RPG slot \(slot + 1) is empty"
        }
        switch rpgUseActionQuickSlot(player, slot: slot, preferences: preferences) {
        case .success(let result): return result.message
        case .failure(let error): return error.description
        }
    }

    func applyLANRPGState(_ state: RPGCharacterState?) {
        guard isLANClientWorld, let player, let state else { return }
        player.rpg = repairRPGCharacterState(state)
        player.applyRPGDerivedStats()
    }
}

private func rpgQuickSlotPreferenceErrorDescription(
    _ error: RPGQuickSlotPreferenceError
) -> String {
    switch error {
    case .characterNotCreated: return RPGActionFailure.characterNotCreated.description
    case .invalidSlot: return RPGActionFailure.actionNotPrepared.description
    case .actionNotPrepared(let token): return "Action is not prepared: \(token)"
    }
}

public enum RPGCreationError: Error, Equatable, CustomStringConvertible {
    case classesDisabled
    case unknownPath(String)
    case invalidAttributeBudget(total: Int, expected: Int)
    case invalidAttributeValue(RPGAttributeID, Int)
    case invalidStarterSkill(String)
    case invalidStarterSpell(String)
    case alreadyCreated
    case starterKitUnavailable(String)
    case insufficientInventoryForStarterKit

    public var description: String {
        switch self {
        case .classesDisabled: return RPGActionFailure.classesDisabled.description
        case .unknownPath(let id): return "Unknown path: \(id)"
        case .invalidAttributeBudget(let total, let expected): return "Attribute total \(total) does not match \(expected)"
        case .invalidAttributeValue(let id, let value): return "\(id.rawValue) value \(value) is out of creation range"
        case .invalidStarterSkill(let id): return "Invalid starter skill: \(id)"
        case .invalidStarterSpell(let id): return "Invalid starter spell: \(id)"
        case .alreadyCreated: return "Character has already been created"
        case .starterKitUnavailable(let id): return "Starter kit item is unavailable: \(id)"
        case .insufficientInventoryForStarterKit: return "Not enough inventory space for the starter kit"
        }
    }
}

public struct RPGProgressionReport: Equatable {
    public var leveledUp: Bool
    public var previousLevel: Int
    public var newLevel: Int
    public var awardedXP: Int

    public init(leveledUp: Bool, previousLevel: Int, newLevel: Int, awardedXP: Int = 0) {
        self.leveledUp = leveledUp
        self.previousLevel = previousLevel
        self.newLevel = newLevel
        self.awardedXP = awardedXP
    }
}

public enum RPGProgressionError: Error, Equatable, CustomStringConvertible {
    case characterNotCreated
    case unknownSkill(String)
    case unknownSpell(String)
    case alreadyAtMaximumRank(String)
    case insufficientLevel(required: Int)
    case insufficientAttribute(RPGAttributeID, required: Int)
    case missingPrerequisite(String)
    case insufficientSkillPoints
    case insufficientAttributePoints
    case spellNotKnown(String)
    case skillNotKnown(String)
    case skillNotActive(String)
    case preparedSpellLimit
    case preparedSkillLimit
    case authorityExhausted

    public var description: String {
        switch self {
        case .characterNotCreated: return "Character has not been created"
        case .unknownSkill(let id): return "Unknown skill: \(id)"
        case .unknownSpell(let id): return "Unknown spell: \(id)"
        case .alreadyAtMaximumRank(let id): return "Skill is at maximum rank: \(id)"
        case .insufficientLevel(let level): return "Requires level \(level)"
        case .insufficientAttribute(let id, let value): return "Requires \(id.rawValue) \(value)"
        case .missingPrerequisite(let id): return "Missing prerequisite: \(id)"
        case .insufficientSkillPoints: return "Not enough skill points"
        case .insufficientAttributePoints: return "Not enough attribute points"
        case .spellNotKnown(let id): return "Spell is not known: \(id)"
        case .skillNotKnown(let id): return "Skill is not known: \(id)"
        case .skillNotActive(let id): return "Skill is passive and always active: \(id)"
        case .preparedSpellLimit: return "Prepared spell limit reached"
        case .preparedSkillLimit: return "Prepared skill limit reached"
        case .authorityExhausted: return "RPG authority revision is exhausted"
        }
    }
}

public let RPG_PATH_DEFINITIONS: [RPGPathDefinition] = [
    RPGPathDefinition(
        id: "warden",
        displayName: "Warden",
        summary: "Armor, shield timing, threat control, and short-range protection.",
        primaryAttributes: [.strength, .endurance],
        branchIDs: ["warden_guardian", "warden_vanguard", "warden_bulwark"],
        starterSkillIDs: ["guard_stance", "shield_bind", "heavy_cut"]
    ),
    RPGPathDefinition(
        id: "ranger",
        displayName: "Ranger",
        summary: "Bows, scouting, terrain movement, ambushes, and survival fieldcraft.",
        primaryAttributes: [.dexterity, .luck],
        branchIDs: ["ranger_marksman", "ranger_scout", "ranger_survivalist"],
        starterSkillIDs: ["quick_draw", "trail_sense", "campcraft"]
    ),
    RPGPathDefinition(
        id: "delver",
        displayName: "Delver",
        summary: "Mining, traps, underground navigation, lockwork, and risky treasure work.",
        primaryAttributes: [.strength, .endurance],
        branchIDs: ["delver_miner", "delver_trapper", "delver_treasure"],
        starterSkillIDs: ["vein_reader", "trap_probe", "salvage_eye"]
    ),
    RPGPathDefinition(
        id: "arcanist",
        displayName: "Arcanist",
        summary: "Fatigue-driven spellcasting, illusions, creations, wards, and rituals.",
        primaryAttributes: [.intelligence, .endurance],
        branchIDs: ["arcanist_elementalist", "arcanist_illusionist", "arcanist_ritualist"],
        starterSkillIDs: ["spell_formula", "minor_glamour", "ritual_circle"],
        starterSpellIDs: ["ignite", "blur", "mage_light"]
    ),
    RPGPathDefinition(
        id: "mender",
        displayName: "Mender",
        summary: "Healing, food efficiency, antidotes, protective rites, and rescue timing.",
        primaryAttributes: [.intelligence, .luck],
        branchIDs: ["mender_physic", "mender_harvest", "mender_sanctuary"],
        starterSkillIDs: ["field_dressing", "herbal_lore", "safe_haven"],
        starterSpellIDs: ["mend_wounds", "purify", "ward"]
    ),
    RPGPathDefinition(
        id: "tinker",
        displayName: "Tinker",
        summary: "Redstone devices, automation, gear mods, explosives, and compact tools.",
        primaryAttributes: [.intelligence, .dexterity],
        branchIDs: ["tinker_redstone", "tinker_artificer", "tinker_sapper"],
        starterSkillIDs: ["circuit_sense", "field_mod", "charge_pack"]
    ),
]

public let RPG_BRANCH_DEFINITIONS: [RPGBranchDefinition] = [
    RPGBranchDefinition(id: "warden_guardian", pathID: "warden", displayName: "Guardian",
                        summary: "Defend an area and keep allies standing.",
                        skillIDs: ["guard_stance", "interpose", "anchor_line"]),
    RPGBranchDefinition(id: "warden_vanguard", pathID: "warden", displayName: "Vanguard",
                        summary: "Close distance and punish exposed enemies.",
                        skillIDs: ["heavy_cut", "charge_break", "stagger_chain"]),
    RPGBranchDefinition(id: "warden_bulwark", pathID: "warden", displayName: "Bulwark",
                        summary: "Turn armor and blocks into durable defenses.",
                        skillIDs: ["shield_bind", "plate_training", "fortify_block"]),
    RPGBranchDefinition(id: "ranger_marksman", pathID: "ranger", displayName: "Marksman",
                        summary: "Accurate ranged attacks and quick target swapping.",
                        skillIDs: ["quick_draw", "steady_aim", "crippling_shot"]),
    RPGBranchDefinition(id: "ranger_scout", pathID: "ranger", displayName: "Scout",
                        summary: "Movement, stealth, map reading, and ambush setup.",
                        skillIDs: ["trail_sense", "soft_step", "far_sight"]),
    RPGBranchDefinition(id: "ranger_survivalist", pathID: "ranger", displayName: "Survivalist",
                        summary: "Forage, camp, weather, and animal handling.",
                        skillIDs: ["campcraft", "weather_eye", "beast_kinship"]),
    RPGBranchDefinition(id: "delver_miner", pathID: "delver", displayName: "Miner",
                        summary: "Ore discovery and efficient underground routes.",
                        skillIDs: ["vein_reader", "fast_bore", "deep_reserves"]),
    RPGBranchDefinition(id: "delver_trapper", pathID: "delver", displayName: "Trapper",
                        summary: "Detect, disarm, and build traps.",
                        skillIDs: ["trap_probe", "tripwire_mind", "deadfall"]),
    RPGBranchDefinition(id: "delver_treasure", pathID: "delver", displayName: "Treasure-Seeker",
                        summary: "Better salvage, locks, and risky loot handling.",
                        skillIDs: ["salvage_eye", "lock_touch", "fortune_read"]),
    RPGBranchDefinition(id: "arcanist_elementalist", pathID: "arcanist", displayName: "Elementalist",
                        summary: "Fire, frost, force, and light spells.",
                        skillIDs: ["spell_formula", "spark_weave", "storm_focus"]),
    RPGBranchDefinition(id: "arcanist_illusionist", pathID: "arcanist", displayName: "Illusionist",
                        summary: "Blur, decoys, invisibility, and misdirection.",
                        skillIDs: ["minor_glamour", "false_step", "mirror_work"]),
    RPGBranchDefinition(id: "arcanist_ritualist", pathID: "arcanist", displayName: "Ritualist",
                        summary: "Longer casts, wards, creations, and summons.",
                        skillIDs: ["ritual_circle", "bound_servant", "ward_scribe"]),
    RPGBranchDefinition(id: "mender_physic", pathID: "mender", displayName: "Physic",
                        summary: "Direct healing and emergency recovery.",
                        skillIDs: ["field_dressing", "triage", "second_breath"]),
    RPGBranchDefinition(id: "mender_harvest", pathID: "mender", displayName: "Harvest",
                        summary: "Food, herbs, medicine, and sustainable supplies.",
                        skillIDs: ["herbal_lore", "clean_brew", "green_thumb"]),
    RPGBranchDefinition(id: "mender_sanctuary", pathID: "mender", displayName: "Sanctuary",
                        summary: "Safe zones, wards, and rescue escapes.",
                        skillIDs: ["safe_haven", "protective_mark", "sanctuary_bell"]),
    RPGBranchDefinition(id: "tinker_redstone", pathID: "tinker", displayName: "Redstone",
                        summary: "Compact circuits and signal reading.",
                        skillIDs: ["circuit_sense", "compact_gate", "remote_trigger"]),
    RPGBranchDefinition(id: "tinker_artificer", pathID: "tinker", displayName: "Artificer",
                        summary: "Gear tuning and field repairs.",
                        skillIDs: ["field_mod", "quick_repair", "tool_tune"]),
    RPGBranchDefinition(id: "tinker_sapper", pathID: "tinker", displayName: "Sapper",
                        summary: "Controlled blasts and demolition timing.",
                        skillIDs: ["charge_pack", "blast_shape", "safe_fuse"]),
]

public let RPG_SKILL_DEFINITIONS: [RPGSkillDefinition] = [
    RPGSkillDefinition(id: "guard_stance", pathID: "warden", branchID: "warden_guardian", displayName: "Guard Stance",
                                              requirements: [RPGAttributeRequirement(.strength, 8)]),
    RPGSkillDefinition(id: "interpose", pathID: "warden", branchID: "warden_guardian", displayName: "Interpose",
                       kind: .active,                        requirements: [RPGAttributeRequirement(.endurance, 9)], prerequisiteSkillIDs: ["guard_stance"],
                       cooldownTicks: 100, fatigueCost: 3),
    RPGSkillDefinition(id: "anchor_line", pathID: "warden", branchID: "warden_guardian", displayName: "Anchor Line",
                       kind: .active,                        prerequisiteSkillIDs: ["interpose"], cooldownTicks: 180, fatigueCost: 4),
    RPGSkillDefinition(id: "heavy_cut", pathID: "warden", branchID: "warden_vanguard", displayName: "Heavy Cut",
                       kind: .active,                        requirements: [RPGAttributeRequirement(.strength, 9)], cooldownTicks: 60, fatigueCost: 2),
    RPGSkillDefinition(id: "charge_break", pathID: "warden", branchID: "warden_vanguard", displayName: "Charge Break",
                       kind: .active,                        prerequisiteSkillIDs: ["heavy_cut"], cooldownTicks: 140, fatigueCost: 4),
    RPGSkillDefinition(id: "stagger_chain", pathID: "warden", branchID: "warden_vanguard", displayName: "Stagger Chain",
                                              prerequisiteSkillIDs: ["charge_break"]),
    RPGSkillDefinition(id: "shield_bind", pathID: "warden", branchID: "warden_bulwark", displayName: "Shield Bind",
                                              requirements: [RPGAttributeRequirement(.endurance, 8)]),
    RPGSkillDefinition(id: "plate_training", pathID: "warden", branchID: "warden_bulwark", displayName: "Plate Training",
                                              prerequisiteSkillIDs: ["shield_bind"]),
    RPGSkillDefinition(id: "fortify_block", pathID: "warden", branchID: "warden_bulwark", displayName: "Fortify Block",
                       kind: .active,                        prerequisiteSkillIDs: ["plate_training"], cooldownTicks: 240, fatigueCost: 5),

    RPGSkillDefinition(id: "quick_draw", pathID: "ranger", branchID: "ranger_marksman", displayName: "Quick Draw",
                                              requirements: [RPGAttributeRequirement(.dexterity, 9)]),
    RPGSkillDefinition(id: "steady_aim", pathID: "ranger", branchID: "ranger_marksman", displayName: "Steady Aim",
                                              prerequisiteSkillIDs: ["quick_draw"]),
    RPGSkillDefinition(id: "crippling_shot", pathID: "ranger", branchID: "ranger_marksman", displayName: "Crippling Shot",
                       kind: .active,                        prerequisiteSkillIDs: ["steady_aim"], cooldownTicks: 160, fatigueCost: 4),
    RPGSkillDefinition(id: "trail_sense", pathID: "ranger", branchID: "ranger_scout", displayName: "Trail Sense",
                                              requirements: [RPGAttributeRequirement(.luck, 7)]),
    RPGSkillDefinition(id: "soft_step", pathID: "ranger", branchID: "ranger_scout", displayName: "Soft Step",
                                              prerequisiteSkillIDs: ["trail_sense"]),
    RPGSkillDefinition(id: "far_sight", pathID: "ranger", branchID: "ranger_scout", displayName: "Far Sight",
                       kind: .active,                        prerequisiteSkillIDs: ["soft_step"], cooldownTicks: 220, fatigueCost: 3),
    RPGSkillDefinition(id: "campcraft", pathID: "ranger", branchID: "ranger_survivalist", displayName: "Campcraft",
                                              requirements: [RPGAttributeRequirement(.endurance, 8)]),
    RPGSkillDefinition(id: "weather_eye", pathID: "ranger", branchID: "ranger_survivalist", displayName: "Weather Eye",
                                              prerequisiteSkillIDs: ["campcraft"]),
    RPGSkillDefinition(id: "beast_kinship", pathID: "ranger", branchID: "ranger_survivalist", displayName: "Beast Kinship",
                                              prerequisiteSkillIDs: ["weather_eye"]),

    RPGSkillDefinition(id: "vein_reader", pathID: "delver", branchID: "delver_miner", displayName: "Vein Reader",
                                              requirements: [RPGAttributeRequirement(.intelligence, 7)]),
    RPGSkillDefinition(id: "fast_bore", pathID: "delver", branchID: "delver_miner", displayName: "Fast Bore",
                       kind: .active,                        prerequisiteSkillIDs: ["vein_reader"], cooldownTicks: 120, fatigueCost: 3),
    RPGSkillDefinition(id: "deep_reserves", pathID: "delver", branchID: "delver_miner", displayName: "Deep Reserves",
                                              prerequisiteSkillIDs: ["fast_bore"]),
    RPGSkillDefinition(id: "trap_probe", pathID: "delver", branchID: "delver_trapper", displayName: "Trap Probe",
                       kind: .active,
                       requirements: [RPGAttributeRequirement(.dexterity, 8)], cooldownTicks: 80, fatigueCost: 2),
    RPGSkillDefinition(id: "tripwire_mind", pathID: "delver", branchID: "delver_trapper", displayName: "Tripwire Mind",
                                              prerequisiteSkillIDs: ["trap_probe"]),
    RPGSkillDefinition(id: "deadfall", pathID: "delver", branchID: "delver_trapper", displayName: "Deadfall",
                       kind: .active,                        prerequisiteSkillIDs: ["tripwire_mind"], cooldownTicks: 240, fatigueCost: 5),
    RPGSkillDefinition(id: "salvage_eye", pathID: "delver", branchID: "delver_treasure", displayName: "Salvage Eye",
                                              requirements: [RPGAttributeRequirement(.luck, 7)]),
    RPGSkillDefinition(id: "lock_touch", pathID: "delver", branchID: "delver_treasure", displayName: "Lock Touch",
                       kind: .active,                        prerequisiteSkillIDs: ["salvage_eye"], cooldownTicks: 200, fatigueCost: 4),
    RPGSkillDefinition(id: "fortune_read", pathID: "delver", branchID: "delver_treasure", displayName: "Fortune Read",
                       kind: .active,                        prerequisiteSkillIDs: ["lock_touch"], cooldownTicks: 400, fatigueCost: 6),

    RPGSkillDefinition(id: "spell_formula", pathID: "arcanist", branchID: "arcanist_elementalist", displayName: "Spell Formula",
                                              requirements: [RPGAttributeRequirement(.intelligence, 9)]),
    RPGSkillDefinition(id: "spark_weave", pathID: "arcanist", branchID: "arcanist_elementalist", displayName: "Spark Weave",
                                              prerequisiteSkillIDs: ["spell_formula"]),
    RPGSkillDefinition(id: "storm_focus", pathID: "arcanist", branchID: "arcanist_elementalist", displayName: "Storm Focus",
                                              prerequisiteSkillIDs: ["spark_weave"]),
    RPGSkillDefinition(id: "minor_glamour", pathID: "arcanist", branchID: "arcanist_illusionist", displayName: "Minor Glamour",
                                              requirements: [RPGAttributeRequirement(.intelligence, 9)]),
    RPGSkillDefinition(id: "false_step", pathID: "arcanist", branchID: "arcanist_illusionist", displayName: "False Step",
                                              prerequisiteSkillIDs: ["minor_glamour"]),
    RPGSkillDefinition(id: "mirror_work", pathID: "arcanist", branchID: "arcanist_illusionist", displayName: "Mirror Work",
                                              prerequisiteSkillIDs: ["false_step"]),
    RPGSkillDefinition(id: "ritual_circle", pathID: "arcanist", branchID: "arcanist_ritualist", displayName: "Ritual Circle",
                                              requirements: [RPGAttributeRequirement(.endurance, 8)]),
    RPGSkillDefinition(id: "bound_servant", pathID: "arcanist", branchID: "arcanist_ritualist", displayName: "Bound Servant",
                                              prerequisiteSkillIDs: ["ritual_circle"]),
    RPGSkillDefinition(id: "ward_scribe", pathID: "arcanist", branchID: "arcanist_ritualist", displayName: "Ward Scribe",
                                              prerequisiteSkillIDs: ["bound_servant"]),

    RPGSkillDefinition(id: "field_dressing", pathID: "mender", branchID: "mender_physic", displayName: "Field Dressing",
                                              requirements: [RPGAttributeRequirement(.intelligence, 8)]),
    RPGSkillDefinition(id: "triage", pathID: "mender", branchID: "mender_physic", displayName: "Triage",
                                              prerequisiteSkillIDs: ["field_dressing"]),
    RPGSkillDefinition(id: "second_breath", pathID: "mender", branchID: "mender_physic", displayName: "Second Breath",
                       kind: .active,                        prerequisiteSkillIDs: ["triage"], cooldownTicks: 600, fatigueCost: 6),
    RPGSkillDefinition(id: "herbal_lore", pathID: "mender", branchID: "mender_harvest", displayName: "Herbal Lore",
                                              requirements: [RPGAttributeRequirement(.luck, 7)]),
    RPGSkillDefinition(id: "clean_brew", pathID: "mender", branchID: "mender_harvest", displayName: "Clean Brew",
                                              prerequisiteSkillIDs: ["herbal_lore"]),
    RPGSkillDefinition(id: "green_thumb", pathID: "mender", branchID: "mender_harvest", displayName: "Green Thumb",
                                              prerequisiteSkillIDs: ["clean_brew"]),
    RPGSkillDefinition(id: "safe_haven", pathID: "mender", branchID: "mender_sanctuary", displayName: "Safe Haven",
                       kind: .active,
                       requirements: [RPGAttributeRequirement(.endurance, 8)],                        cooldownTicks: 400, fatigueCost: 0),
    RPGSkillDefinition(id: "protective_mark", pathID: "mender", branchID: "mender_sanctuary", displayName: "Protective Mark",
                                              prerequisiteSkillIDs: ["safe_haven"]),
    RPGSkillDefinition(id: "sanctuary_bell", pathID: "mender", branchID: "mender_sanctuary", displayName: "Sanctuary Bell",
                                              prerequisiteSkillIDs: ["protective_mark"]),

    RPGSkillDefinition(id: "circuit_sense", pathID: "tinker", branchID: "tinker_redstone", displayName: "Circuit Sense",
                                              requirements: [RPGAttributeRequirement(.intelligence, 8)]),
    RPGSkillDefinition(id: "compact_gate", pathID: "tinker", branchID: "tinker_redstone", displayName: "Compact Gate",
                                              prerequisiteSkillIDs: ["circuit_sense"]),
    RPGSkillDefinition(id: "remote_trigger", pathID: "tinker", branchID: "tinker_redstone", displayName: "Remote Trigger",
                       kind: .active,                        prerequisiteSkillIDs: ["compact_gate"], cooldownTicks: 180, fatigueCost: 3),
    RPGSkillDefinition(id: "field_mod", pathID: "tinker", branchID: "tinker_artificer", displayName: "Field Mod",
                       kind: .active,                        requirements: [RPGAttributeRequirement(.dexterity, 8)], cooldownTicks: 180, fatigueCost: 3),
    RPGSkillDefinition(id: "quick_repair", pathID: "tinker", branchID: "tinker_artificer", displayName: "Quick Repair",
                       kind: .active,                        prerequisiteSkillIDs: ["field_mod"], cooldownTicks: 220, fatigueCost: 4),
    RPGSkillDefinition(id: "tool_tune", pathID: "tinker", branchID: "tinker_artificer", displayName: "Tool Tune",
                                              prerequisiteSkillIDs: ["quick_repair"]),
    RPGSkillDefinition(id: "charge_pack", pathID: "tinker", branchID: "tinker_sapper", displayName: "Charge Pack",
                       kind: .active,
                       requirements: [RPGAttributeRequirement(.intelligence, 8)], cooldownTicks: 240, fatigueCost: 5),
    RPGSkillDefinition(id: "blast_shape", pathID: "tinker", branchID: "tinker_sapper", displayName: "Blast Shape",
                                              prerequisiteSkillIDs: ["charge_pack"]),
    RPGSkillDefinition(id: "safe_fuse", pathID: "tinker", branchID: "tinker_sapper", displayName: "Safe Fuse",
                       kind: .active,                        prerequisiteSkillIDs: ["blast_shape"], cooldownTicks: 120, fatigueCost: 2),
]

public let RPG_SPELL_DEFINITIONS: [RPGSpellDefinition] = [
    RPGSpellDefinition(id: "ignite", displayName: "Ignite",
                       summary: "Deal 4 + INT potency + Spell Formula damage and 120 fire ticks to one visible hostile, or place fire on an authorized replaceable face within 12 blocks.",
                       circle: 1, categories: [.damage, .utility], targetKind: .ray, rangeBlocks: 12,
                       fatigueCost: 2, minimumIntelligence: 9, prerequisiteSkillIDs: ["spell_formula"],
                       actionSequenceWindow: 12),
    RPGSpellDefinition(id: "frost_ray", displayName: "Frost Ray",
                       summary: "Deal 3 + INT potency + Spell Formula damage, Slowness II for 120 ticks, and 160 freeze ticks to one visible hostile within 14 blocks.",
                       circle: 1, categories: [.damage, .control], targetKind: .ray, rangeBlocks: 14,
                       durationTicks: 80, fatigueCost: 3, minimumIntelligence: 9,
                       prerequisiteSkillIDs: ["spell_formula"], actionSequenceWindow: 12),
    RPGSpellDefinition(id: "shock", displayName: "Shock",
                       summary: "Deal 5 + INT potency + Spell Formula damage to one visible hostile within 16 blocks; if it is wet, the nearest wet hostile within 4 blocks takes 3 + INT potency damage.",
                       circle: 2, categories: [.damage], targetKind: .ray, rangeBlocks: 16,
                       fatigueCost: 4, minimumIntelligence: 11, prerequisiteSkillIDs: ["spark_weave"],
                       actionSequenceWindow: 10),
    RPGSpellDefinition(id: "storm_aura", displayName: "Storm Aura",
                       summary: "For 300 ticks, spend 1 fatigue per second to damage up to 32 legal hostiles within 4 blocks once per second for 1.5 / 2.0 / 2.5 Storm Focus damage.",
                       circle: 3, categories: [.damage, .control], targetKind: .selfTarget, rangeBlocks: 0,
                       radiusBlocks: 4, durationTicks: 300, fatigueCost: 6, upkeepCostPerSecond: 1,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["storm_focus"]),
    RPGSpellDefinition(id: "blur", displayName: "Blur",
                       summary: "Maintain invisibility for 240 ticks, extended by Minor Glamour, at 0.25 fatigue per second.",
                       circle: 1, categories: [.defense, .illusion], targetKind: .selfTarget, rangeBlocks: 0,
                       durationTicks: 240, fatigueCost: 2, upkeepCostPerSecond: 0.25,
                       minimumIntelligence: 9, prerequisiteSkillIDs: ["minor_glamour"]),
    RPGSpellDefinition(id: "decoy", displayName: "Decoy",
                       summary: "Create one bounded radius-3 illusion at the targeted point within 8 blocks for 200 ticks, extended by Minor Glamour; each pulse gives legal hostiles Glowing and Slowness I for 40 ticks.",
                       circle: 1, categories: [.illusion, .control], targetKind: .placed, rangeBlocks: 8,
                       durationTicks: 200, fatigueCost: 3, minimumIntelligence: 9,
                       prerequisiteSkillIDs: ["minor_glamour"]),
    RPGSpellDefinition(id: "shadow_step", displayName: "Shadow Step",
                       summary: "Teleport to a visible dark destination with solid footing and clear headroom within 10 + 1 / 2 / 3 False Step blocks.",
                       circle: 2, categories: [.movement, .illusion], targetKind: .ray, rangeBlocks: 10,
                       fatigueCost: 5, minimumIntelligence: 11, prerequisiteSkillIDs: ["false_step"],
                       actionSequenceWindow: 8),
    RPGSpellDefinition(id: "mirror_image", displayName: "Mirror Image",
                       summary: "Maintain invisibility and Speed I and raise absorption to at least 2 / 3 / 4 for 260 ticks, extended by Minor Glamour, at 0.5 fatigue per second.",
                       circle: 3, categories: [.illusion, .defense], targetKind: .selfTarget, rangeBlocks: 0,
                       radiusBlocks: 3, durationTicks: 260, fatigueCost: 6, upkeepCostPerSecond: 0.5,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["mirror_work"]),
    RPGSpellDefinition(id: "mage_light", displayName: "Mage Light",
                       summary: "Place one guarded temporary torch on a valid full-cube face within 12 blocks for 1,200 ticks, extended by Ritual Circle; it restores the prior cell on cleanup.",
                       circle: 1, categories: [.utility, .creation], targetKind: .placed, rangeBlocks: 12,
                       durationTicks: 1200, fatigueCost: 2, minimumIntelligence: 8,
                       prerequisiteSkillIDs: ["ritual_circle"]),
    RPGSpellDefinition(id: "ward", displayName: "Ward",
                       summary: "Place one bounded radius-1 ward on a visible solid block within 6 blocks for 600 ticks, extended by Ritual Circle, with 1 / 2 / 3 Ward Scribe explosion-protection charges.",
                       circle: 1, categories: [.defense], targetKind: .placed, rangeBlocks: 6,
                       durationTicks: 600, fatigueCost: 3, minimumIntelligence: 8,
                       prerequisiteSkillIDs: ["ritual_circle"]),
    RPGSpellDefinition(id: "summon_servant", displayName: "Summon Servant",
                       summary: "Summon one nonpersistent Allay in free space ahead for 400 / 600 / 800 ticks at 0.5 fatigue per second; terminal or upkeep cleanup removes that exact servant.",
                       circle: 2, categories: [.creation, .utility], targetKind: .summon, rangeBlocks: 4,
                       durationTicks: 600, fatigueCost: 6, upkeepCostPerSecond: 0.5,
                       minimumIntelligence: 11, prerequisiteSkillIDs: ["bound_servant"],
                       actionSequenceWindow: 20),
    RPGSpellDefinition(id: "stone_ward", displayName: "Stone Ward",
                       summary: "Place one bounded radius-2 ward on a visible solid block within 8 blocks for 1,200 ticks, extended by Ritual Circle, with 1 / 2 / 3 Ward Scribe explosion-protection charges.",
                       circle: 3, categories: [.defense, .creation], targetKind: .area, rangeBlocks: 8,
                       radiusBlocks: 2, durationTicks: 1200, fatigueCost: 7,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["ward_scribe"]),
    RPGSpellDefinition(id: "mend_wounds", displayName: "Mend Wounds",
                       summary: "Heal self or one visible touched non-player ally for 5 + Field Dressing + INT potency, increased by Triage below half health; a no-effect cast is rejected.",
                       circle: 1, categories: [.healing], targetKind: .touch, rangeBlocks: 2,
                       fatigueCost: 3, minimumIntelligence: 8, prerequisiteSkillIDs: ["field_dressing"]),
    RPGSpellDefinition(id: "restore", displayName: "Restore",
                       summary: "Heal self or one visible touched non-player ally for 8 + Field Dressing + INT potency, increased by Triage below half health, and remove the first poison, wither, weakness, or slowness effect.",
                       circle: 2, categories: [.healing], targetKind: .touch, rangeBlocks: 2,
                       fatigueCost: 5, minimumIntelligence: 11, prerequisiteSkillIDs: ["triage"]),
    RPGSpellDefinition(id: "purify", displayName: "Purify",
                       summary: "Remove every poison, hunger, and nausea effect from self or one visible touched non-player ally; a no-effect cast is rejected.",
                       circle: 1, categories: [.healing, .utility], targetKind: .touch, rangeBlocks: 2,
                       fatigueCost: 2, minimumIntelligence: 8, prerequisiteSkillIDs: ["herbal_lore"]),
    RPGSpellDefinition(id: "aegis", displayName: "Aegis",
                       summary: "One-shot cast: raise self or one visible touched non-player ally to at least 4 + Protective Mark absorption and grant Resistance I for 240 ticks; there is no upkeep.",
                       circle: 2, categories: [.defense, .healing], targetKind: .touch, rangeBlocks: 2,
                       durationTicks: 240, fatigueCost: 5, upkeepCostPerSecond: 0,
                       minimumIntelligence: 11, prerequisiteSkillIDs: ["protective_mark"]),
    RPGSpellDefinition(id: "sanctuary", displayName: "Sanctuary",
                       summary: "Create one bounded sanctuary centered on the caster for 300 ticks; each pulse gives legal hostiles within 6 / 8 / 10 blocks Weakness I for 40 ticks and adds 0.35 outward velocity.",
                       circle: 3, categories: [.defense, .control], targetKind: .area, rangeBlocks: 0,
                       radiusBlocks: 8, durationTicks: 300, fatigueCost: 8,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["sanctuary_bell"]),
]

private let RPG_PATH_BY_ID = Dictionary(uniqueKeysWithValues: RPG_PATH_DEFINITIONS.map { ($0.id, $0) })
private let RPG_BRANCH_BY_ID = Dictionary(uniqueKeysWithValues: RPG_BRANCH_DEFINITIONS.map { ($0.id, $0) })
private let RPG_SKILL_BY_ID = Dictionary(uniqueKeysWithValues: RPG_SKILL_DEFINITIONS.map { ($0.id, $0) })
private let RPG_SPELL_BY_ID = Dictionary(uniqueKeysWithValues: RPG_SPELL_DEFINITIONS.map { ($0.id, $0) })
private let RPG_SKILL_ORDER = Dictionary(uniqueKeysWithValues: RPG_SKILL_DEFINITIONS.enumerated().map { ($0.element.id, $0.offset) })
private let RPG_SPELL_ORDER = Dictionary(uniqueKeysWithValues: RPG_SPELL_DEFINITIONS.enumerated().map { ($0.element.id, $0.offset) })

public func rpgPathDefinition(_ id: String) -> RPGPathDefinition? { RPG_PATH_BY_ID[id] }
public func rpgBranchDefinition(_ id: String) -> RPGBranchDefinition? { RPG_BRANCH_BY_ID[id] }
public func rpgSkillDefinition(_ id: String) -> RPGSkillDefinition? { RPG_SKILL_BY_ID[id] }
public func rpgSpellDefinition(_ id: String) -> RPGSpellDefinition? { RPG_SPELL_BY_ID[id] }

public func rpgCreationPreset(pathID: String) -> RPGAttributes? {
    switch pathID {
    case "warden": return RPGAttributes(strength: 11, dexterity: 7, intelligence: 7, endurance: 10, luck: 7)
    case "ranger": return RPGAttributes(strength: 7, dexterity: 11, intelligence: 7, endurance: 8, luck: 9)
    case "delver": return RPGAttributes(strength: 10, dexterity: 8, intelligence: 7, endurance: 10, luck: 7)
    case "arcanist": return RPGAttributes(strength: 6, dexterity: 8, intelligence: 12, endurance: 8, luck: 8)
    case "mender": return RPGAttributes(strength: 6, dexterity: 8, intelligence: 10, endurance: 10, luck: 8)
    case "tinker": return RPGAttributes(strength: 7, dexterity: 10, intelligence: 10, endurance: 8, luck: 7)
    default: return nil
    }
}

public func rpgSkillRank(_ effectID: RPGSkillEffectID, in state: RPGCharacterState) -> Int {
    max(0, min(3, state.skillRanks[effectID.rawValue] ?? 0))
}

public func rpgSkillEffectValue(_ effectID: RPGSkillEffectID, in state: RPGCharacterState) -> Double {
    let rank = rpgSkillRank(effectID, in: state)
    guard rank > 0 else { return 0 }
    return rpgSkillEffectContract(effectID).values[rank - 1]
}

public func rpgSkillRankBenefit(_ skillID: String, rank: Int) -> String? {
    guard let def = rpgSkillDefinition(skillID), rank >= 1, rank <= 3 else { return nil }
    return def.rankBenefits[rank - 1]
}

public func rpgSpellUnlockRank(_ spellID: String, from skillID: String) -> Int? {
    rpgSkillDefinition(skillID)?.spellUnlocks.first(where: { $0.spellID == spellID })?.rank
}

public func rpgUnlockedSpellIDs(for ranks: [String: Int]) -> [String] {
    var unlocked = Set<String>()
    for def in RPG_SKILL_DEFINITIONS {
        let rank = max(0, min(3, ranks[def.id] ?? 0))
        for unlock in def.spellUnlocks where rank >= unlock.rank {
            if RPG_SPELL_BY_ID[unlock.spellID] != nil { unlocked.insert(unlock.spellID) }
        }
    }
    return RPG_SPELL_DEFINITIONS.compactMap { unlocked.contains($0.id) ? $0.id : nil }
}

public func rpgXPRequiredForLevel(_ level: Int) -> Int {
    let clamped = max(1, min(RPG_LEVEL_CAP, level))
    if clamped <= 1 { return 0 }
    let n = clamped - 1
    return 20 * n * n + 30 * n
}

public func rpgLevel(forXP xp: Int) -> Int {
    let clampedXP = max(0, xp)
    var level = 1
    for candidate in 2...RPG_LEVEL_CAP {
        if clampedXP >= rpgXPRequiredForLevel(candidate) { level = candidate }
        else { break }
    }
    return level
}

public func rpgEarnedSkillPoints(level: Int) -> Int {
    let boundedLevel = max(0, min(RPG_LEVEL_CAP, level))
    return boundedLevel > 0 ? boundedLevel - 1 : 0
}

public func rpgEarnedAttributePoints(level: Int) -> Int {
    let level = max(0, min(RPG_LEVEL_CAP, level))
    return [4, 7, 10, 13, 16, 19].filter { $0 <= level }.count
}

public func rpgSkillNodeIndex(_ skillID: String) -> Int? {
    guard let def = rpgSkillDefinition(skillID), let branch = rpgBranchDefinition(def.branchID) else { return nil }
    return branch.skillIDs.firstIndex(of: skillID)
}

public func rpgMinimumLevel(for skillID: String, targetRank: Int, specializationBranchID: String) -> Int? {
    guard let def = rpgSkillDefinition(skillID), let node = rpgSkillNodeIndex(skillID),
          targetRank >= 1, targetRank <= 3 else { return nil }
    let selectedGates = [
        [1, 4, 8],
        [5, 10, 14],
        [12, 16, 20],
    ]
    let surcharge = def.branchID == specializationBranchID ? 0 : 2
    return selectedGates[node][targetRank - 1] + surcharge
}

public func rpgSkillPointCost(_ skillID: String, targetRank: Int, in state: RPGCharacterState) -> Int? {
    guard state.created, let def = rpgSkillDefinition(skillID), def.pathID == state.pathID,
          targetRank >= 1, targetRank <= 3 else { return nil }
    if skillID == state.starterSkillID && targetRank == 1 { return 0 }
    return targetRank + (def.branchID == state.specializationBranchID ? 0 : 1)
}

public func rpgSpentSkillPoints(_ state: RPGCharacterState) -> Int {
    guard state.created else { return 0 }
    var spent = 0
    for def in RPG_SKILL_DEFINITIONS where def.pathID == state.pathID {
        let rank = max(0, min(3, state.skillRanks[def.id] ?? 0))
        guard rank > 0 else { continue }
        for targetRank in 1...rank {
            spent += rpgSkillPointCost(def.id, targetRank: targetRank, in: state) ?? 0
        }
    }
    return spent
}

public func rpgAvailableSkillPoints(_ state: RPGCharacterState) -> Int {
    guard state.created else { return 0 }
    return max(0, rpgEarnedSkillPoints(level: state.level) - rpgSpentSkillPoints(state))
}

public func rpgSpentAttributePoints(_ state: RPGCharacterState) -> Int {
    guard state.created else { return 0 }
    let base = RPGAttributes.creationBudget
    return max(0, state.attributes.clamped().total - base)
}

public func rpgAvailableAttributePoints(_ state: RPGCharacterState) -> Int {
    guard state.created else { return 0 }
    return max(0, rpgEarnedAttributePoints(level: state.level) - rpgSpentAttributePoints(state))
}

public func rpgDerivedStats(_ state: RPGCharacterState) -> RPGDerivedStats {
    guard state.created else { return .vanilla }
    let attr = state.attributes.clamped()
    let guardHealth = rpgSkillEffectValue(.guardStance, in: state)
    let shieldFatigue = rpgSkillEffectValue(.shieldBind, in: state)
    let plateRegen = rpgSkillEffectValue(.plateTraining, in: state)
    let dexteritySteps = max(0, attr.dexterity - 6)
    let strengthSteps = max(0, attr.strength - 6)
    let intelligenceSteps = max(0, attr.intelligence - 6)
    let luckSteps = max(0, attr.luck - 6)
    return RPGDerivedStats(
        maxHealth: Double(12 + attr.strength + attr.endurance / 2) + guardHealth,
        maxFatigue: Double(attr.strength + attr.endurance + max(0, attr.intelligence - 8)) + shieldFatigue,
        fatigueRegenPerTick: 0.010 + Double(attr.endurance) * 0.0015 + plateRegen,
        meleeDamageBonus: Double(max(0, attr.strength - 10)) * 0.15,
        actionAccuracyBonus: Double(dexteritySteps) * 0.01,
        spellPotencyBonus: Double(max(0, attr.intelligence - 10)) * 0.25,
        focusCostMultiplier: max(0.65, 1 - Double(intelligenceSteps) * 0.025),
        actionRecoveryMultiplier: max(0.80, 1 - Double(dexteritySteps) * 0.015),
        exhaustionMultiplier: max(0.85, 1 - Double(strengthSteps) * 0.01),
        luckProcChance: min(0.12, Double(luckSteps) * 0.01)
    )
}

private func stableUniqueSkillIDs(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for def in RPG_SKILL_DEFINITIONS {
        if ids.contains(def.id), !seen.contains(def.id) {
            seen.insert(def.id)
            out.append(def.id)
        }
    }
    return out
}

private func stableUniqueSpellIDs(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for def in RPG_SPELL_DEFINITIONS {
        if ids.contains(def.id), !seen.contains(def.id) {
            seen.insert(def.id)
            out.append(def.id)
        }
    }
    return out
}

private func sortSkillIDs(_ ids: [String]) -> [String] {
    ids.sorted {
        let left = RPG_SKILL_ORDER[$0] ?? Int.max
        let right = RPG_SKILL_ORDER[$1] ?? Int.max
        if left != right { return left < right }
        return $0 < $1
    }
}

private func sortSpellIDs(_ ids: [String]) -> [String] {
    ids.sorted {
        let left = RPG_SPELL_ORDER[$0] ?? Int.max
        let right = RPG_SPELL_ORDER[$1] ?? Int.max
        if left != right { return left < right }
        return $0 < $1
    }
}

public func rpgPreparedActions(_ state: RPGCharacterState) -> [RPGPreparedAction] {
    guard state.created else { return [] }
    var out: [RPGPreparedAction] = []
    for skillID in state.preparedSkillIDs {
        guard let skill = rpgSkillDefinition(skillID), skill.kind == .active,
              (state.skillRanks[skillID] ?? 0) > 0 else { continue }
        let cooldown = state.activeCooldowns.first { $0.id == skillID && $0.remainingTicks > 0 }?.remainingTicks ?? 0
        let hasFatigue = state.fatigue >= skill.fatigueCost
        out.append(RPGPreparedAction(
            kind: .skill,
            id: skillID,
            displayName: skill.displayName,
            iconAssetID: rpgAssetIDForSkill(skillID),
            fatigueCost: skill.fatigueCost,
            cooldownTicks: skill.cooldownTicks,
            cooldownRemainingTicks: cooldown,
            available: cooldown <= 0 && hasFatigue,
            statusText: cooldown > 0 ? "\(max(1, Int((Double(cooldown) / 20.0).rounded(.up))))s" : hasFatigue ? "Ready" : "Fatigue"
        ))
    }
    for spellID in state.preparedSpellIDs {
        guard let spell = rpgSpellDefinition(spellID), state.knownSpellIDs.contains(spellID) else { continue }
        let cooldown = state.activeCooldowns.first { $0.id == spellID && $0.remainingTicks > 0 }?.remainingTicks ?? 0
        let hasFatigue = state.fatigue >= spell.fatigueCost
        let smartEnough = state.attributes.intelligence >= spell.minimumIntelligence
        out.append(RPGPreparedAction(
            kind: .spell,
            id: spellID,
            displayName: spell.displayName,
            iconAssetID: rpgAssetIDForSpell(spellID),
            fatigueCost: spell.fatigueCost,
            cooldownTicks: max(10, spell.circle * 20),
            cooldownRemainingTicks: cooldown,
            available: cooldown <= 0 && hasFatigue && smartEnough,
            statusText: cooldown > 0 ? "\(max(1, Int((Double(cooldown) / 20.0).rounded(.up))))s" : !smartEnough ? "IQ \(spell.minimumIntelligence)" : hasFatigue ? "Ready" : "Fatigue"
        ))
    }
    return out
}

private func rpgPreparedAction(withToken token: String?, in actions: [RPGPreparedAction]) -> RPGPreparedAction? {
    guard let token,
          let parsed = rpgParsePreparedActionToken(token) else { return nil }
    return actions.first { $0.kind == parsed.kind && $0.id == parsed.id }
}

public func rpgActionQuickSlotActions(
    _ state: RPGCharacterState, preferences: RPGQuickSlotPreferences
) -> [RPGPreparedAction?] {
    rpgQuickSlotActions(state: state, preferences: preferences)
}

public func rpgActionQuickSlotIndex(
    for token: String, in state: RPGCharacterState, preferences: RPGQuickSlotPreferences
) -> Int? {
    rpgNormalizeQuickSlotPreferences(preferences, against: state).tokens.firstIndex { $0 == token }
}

public func rpgSelectedPreparedAction(_ state: RPGCharacterState) -> RPGPreparedAction? {
    let actions = rpgPreparedActions(state)
    if let selected = state.selectedPreparedActionID,
       let found = actions.first(where: { $0.token == selected }) {
        return found
    }
    if let selectedSpell = state.selectedPreparedSpellID,
       let found = actions.first(where: { $0.kind == .spell && $0.id == selectedSpell }) {
        return found
    }
    return actions.first
}

private func normalizeSelectedPreparedAction(_ state: inout RPGCharacterState) {
    let actions = rpgPreparedActions(state)
    if actions.isEmpty {
        state.selectedPreparedActionID = nil
        return
    }
    if let selected = state.selectedPreparedActionID,
       let parsed = rpgParsePreparedActionToken(selected),
       actions.contains(where: { $0.kind == parsed.kind && $0.id == parsed.id }) {
        return
    }
    state.selectedPreparedActionID = nil
}

private func trimRPGAttributesToEarnedBudget(_ attributes: RPGAttributes, level: Int) -> RPGAttributes {
    var out = attributes.clamped()
    let maximumTotal = RPGAttributes.creationBudget + rpgEarnedAttributePoints(level: level)
    while out.total > maximumTotal {
        let attr = RPGAttributeID.allCases
            .filter { out.value($0) > RPGAttributes.minimum }
            .max { lhs, rhs in
                let lv = out.value(lhs)
                let rv = out.value(rhs)
                if lv != rv { return lv < rv }
                return RPGAttributeID.allCases.firstIndex(of: lhs)! > RPGAttributeID.allCases.firstIndex(of: rhs)!
            }
        guard let attr else { break }
        out.set(attr, out.value(attr) - 1)
    }
    return out
}

private func skillRequirementsMet(_ def: RPGSkillDefinition, attributes: RPGAttributes) -> Bool {
    def.requirements.allSatisfy { attributes.value($0.attribute) >= $0.minimum }
}

private func replayLegalSkillRanks(_ requested: [String: Int],
                                   base: RPGCharacterState,
                                   grandfatherStarterFoundation: Bool = false) -> [String: Int] {
    var state = base
    state.skillRanks = [state.starterSkillID: 1]
    for def in RPG_SKILL_DEFINITIONS where def.pathID == state.pathID {
        let desired = max(def.id == state.starterSkillID ? 1 : 0, min(3, requested[def.id] ?? 0))
        while (state.skillRanks[def.id] ?? 0) < desired {
            let current = state.skillRanks[def.id] ?? 0
            let targetRank = current + 1
            guard let gate = rpgMinimumLevel(for: def.id, targetRank: targetRank,
                                             specializationBranchID: state.specializationBranchID),
                  state.level >= gate else { break }
            let grandfatheredRankOne = grandfatherStarterFoundation
                && def.id == state.starterSkillID && targetRank == 1
            guard grandfatheredRankOne || skillRequirementsMet(def, attributes: state.attributes) else { break }
            if let node = rpgSkillNodeIndex(def.id), node > 0 {
                guard let branch = rpgBranchDefinition(def.branchID) else { break }
                let prerequisite = branch.skillIDs[node - 1]
                guard (state.skillRanks[prerequisite] ?? 0) >= 2 else { break }
            }
            let cost = rpgSkillPointCost(def.id, targetRank: targetRank, in: state) ?? Int.max
            guard cost <= rpgAvailableSkillPoints(state) else { break }
            state.skillRanks[def.id] = targetRank
        }
    }
    return state.skillRanks
}

private func inferredStarterSkillID(path: RPGPathDefinition,
                                    requestedRanks: [String: Int],
                                    base: RPGCharacterState) -> String {
    // Legacy inference follows the frozen gameplay registry: path branch order,
    // then each branch's Foundation node. `starterSkillIDs` is UI/preset order
    // and historically differs for Warden Vanguard and Bulwark.
    let foundations = path.branchIDs.compactMap { branchID in
        rpgBranchDefinition(branchID)?.skillIDs.first
    }
    let positiveFoundations = foundations.filter { (requestedRanks[$0] ?? 0) > 0 }
    if positiveFoundations.count == 1 { return positiveFoundations[0] }

    guard var best = foundations.first else { return path.starterSkillIDs.first ?? "" }
    var bestScore = -1
    for starter in foundations {
        guard let definition = rpgSkillDefinition(starter) else { continue }
        var candidate = base
        candidate.starterSkillID = starter
        candidate.specializationBranchID = definition.branchID
        let replayed = replayLegalSkillRanks(requestedRanks, base: candidate,
                                             grandfatherStarterFoundation: true)
        var score = 0
        for skill in RPG_SKILL_DEFINITIONS where skill.pathID == path.id {
            score += min(max(0, requestedRanks[skill.id] ?? 0), replayed[skill.id] ?? 0)
        }
        // Iteration is frozen registry order; retain the first candidate on ties.
        if score > bestScore {
            best = starter
            bestScore = score
        }
    }
    return best
}

private func legacyRPGXPRequiredForLevel(_ level: Int) -> Int {
    let bounded = max(1, min(RPG_LEVEL_CAP, level))
    if bounded <= 1 { return 0 }
    let n = bounded - 1
    return 100 * n * n + 50 * n
}

private func migratedV1XP(_ rawXP: Int) -> Int {
    let oldCap = legacyRPGXPRequiredForLevel(RPG_LEVEL_CAP)
    let oldXP = max(0, min(oldCap, rawXP))
    if oldXP >= oldCap { return rpgXPRequiredForLevel(RPG_LEVEL_CAP) }
    var level = 1
    for candidate in 2...RPG_LEVEL_CAP {
        if oldXP >= legacyRPGXPRequiredForLevel(candidate) { level = candidate }
        else { break }
    }
    let oldFloor = legacyRPGXPRequiredForLevel(level)
    let oldCeiling = legacyRPGXPRequiredForLevel(level + 1)
    let newFloor = rpgXPRequiredForLevel(level)
    let newCeiling = rpgXPRequiredForLevel(level + 1)
    let oldSpan = max(1, oldCeiling - oldFloor)
    let newSpan = max(0, newCeiling - newFloor)
    return newFloor + (oldXP - oldFloor) * newSpan / oldSpan
}

/// Registration-aware recipe milestone normalization. Before the append-only
/// registry is complete, retain the bounded persisted words verbatim; once the
/// exact count is known, resize and clear only bits that cannot name a recipe.
public func rpgRepairRecipeMilestoneWords(_ raw: [UInt64],
                                          registeredRecipeCount: Int?) -> [UInt64] {
    let bounded = Array(raw.prefix(RPG_MAX_RECIPE_MILESTONE_WORDS))
    guard let registeredRecipeCount else { return bounded }
    let exactCount = max(0, min(RPG_MAX_RECIPE_MILESTONE_WORDS * 64, registeredRecipeCount))
    let wordCount = (exactCount + 63) / 64
    var out = Array(bounded.prefix(wordCount))
    while out.count < wordCount { out.append(0) }
    if wordCount > 0, exactCount % 64 != 0 {
        let usedBits = exactCount % 64
        out[wordCount - 1] &= (UInt64(1) << UInt64(usedBits)) - 1
    }
    return out
}

private func repairedXPLedger(_ raw: RPGXPLedger) -> RPGXPLedger {
    var out = raw
    out.windowStartTick = max(0, min(RPG_MAX_COUNTER, out.windowStartTick))
    out.counts = out.counts.repaired()
    var seen = Set<String>()
    out.recentKeys = out.recentKeys.filter {
        rpgIsBoundedID($0) && seen.insert($0).inserted
    }
    if out.recentKeys.count > RPG_MAX_XP_EVENT_KEYS {
        out.recentKeys = Array(out.recentKeys.suffix(RPG_MAX_XP_EVENT_KEYS))
    }
    out.spellDay = max(0, min(RPG_MAX_COUNTER, out.spellDay))
    out.distinctSpellMask &= (UInt32(1) << UInt32(RPG_SPELL_DEFINITIONS.count)) - 1
    out.recipeMilestoneWords = rpgRepairRecipeMilestoneWords(
        out.recipeMilestoneWords,
        registeredRecipeCount: registeredCraftingRecipeCount
    )
    return out
}

public func rpgCreateCharacter(_ draft: RPGCreationDraft) -> Result<RPGCharacterState, RPGCreationError> {
    guard rpgIsBoundedID(draft.pathID) else { return .failure(.unknownPath(draft.pathID)) }
    if let starter = draft.starterSkillID, !rpgIsBoundedID(starter) {
        return .failure(.invalidStarterSkill(starter))
    }
    guard draft.starterSpellIDs.count <= RPG_SPELL_DEFINITIONS.count else {
        return .failure(.invalidStarterSpell("too_many"))
    }
    for spellID in draft.starterSpellIDs where !rpgIsBoundedID(spellID) {
        return .failure(.invalidStarterSpell(spellID))
    }
    guard let path = rpgPathDefinition(draft.pathID) else { return .failure(.unknownPath(draft.pathID)) }
    let attrs = draft.attributes
    for id in RPGAttributeID.allCases {
        let value = attrs.value(id)
        if value < RPGAttributes.minimum || value > RPGAttributes.maximumAtCreation {
            return .failure(.invalidAttributeValue(id, value))
        }
    }
    guard attrs.total == RPGAttributes.creationBudget else {
        return .failure(.invalidAttributeBudget(total: attrs.total, expected: RPGAttributes.creationBudget))
    }

    let starterSkill = draft.starterSkillID ?? path.starterSkillIDs.first
    guard let skillID = starterSkill, path.starterSkillIDs.contains(skillID) else {
        return .failure(.invalidStarterSkill(starterSkill ?? ""))
    }
    guard let starterDefinition = rpgSkillDefinition(skillID), skillRequirementsMet(starterDefinition, attributes: attrs) else {
        return .failure(.invalidStarterSkill(skillID))
    }

    let branchID = starterDefinition.branchID
    let ranks = [skillID: 1]
    let unlocked = rpgUnlockedSpellIDs(for: ranks)
    for spellID in draft.starterSpellIDs where !unlocked.contains(spellID) {
        return .failure(.invalidStarterSpell(spellID))
    }

    let spells = draft.starterSpellIDs.isEmpty ? unlocked : stableUniqueSpellIDs(draft.starterSpellIDs)
    let preparedSkills = starterDefinition.kind == .active ? [skillID] : []
    var state = RPGCharacterState(
        created: true,
        pathID: path.id,
        starterSkillID: skillID,
        specializationBranchID: branchID,
        attributes: attrs,
        xp: 0,
        level: 1,
        skillRanks: ranks,
        preparedSkillIDs: preparedSkills,
        knownSpellIDs: spells,
        preparedSpellIDs: Array(spells.prefix(RPG_MAX_PREPARED_SPELLS)),
        selectedPreparedSpellID: spells.first,
        selectedPreparedActionID: nil,
        fatigue: 0,
        authorityRevision: 1
    )
    state.fatigue = rpgDerivedStats(state).maxFatigue
    return .success(repairRPGCharacterState(state))
}

public func repairRPGCharacterState(_ raw: RPGCharacterState) -> RPGCharacterState {
    if !raw.created { return .uncreated() }
    if raw.version < 0 || raw.version > RPG_STATE_CURRENT_VERSION { return .uncreated() }
    guard let path = rpgPathDefinition(raw.pathID) else { return .uncreated() }

    var state = raw
    let isLegacy = raw.version == 0 || raw.version == 1
    state.version = RPG_STATE_CURRENT_VERSION
    state.created = true
    state.pathID = path.id
    state.xp = isLegacy
        ? migratedV1XP(state.xp)
        : max(0, min(rpgXPRequiredForLevel(RPG_LEVEL_CAP), state.xp))
    state.level = rpgLevel(forXP: state.xp)
    state.attributes = state.attributes.clamped()
    if state.attributes.total < RPGAttributes.creationBudget {
        guard isLegacy else { return .uncreated() }
        state.attributes = rpgCreationPreset(pathID: path.id) ?? RPGAttributes.defaultCreation
    }
    state.attributes = trimRPGAttributesToEarnedBudget(state.attributes, level: state.level)

    let starter: String
    if isLegacy {
        starter = inferredStarterSkillID(path: path, requestedRanks: state.skillRanks, base: state)
    } else {
        starter = state.starterSkillID
    }
    guard let starterDef = rpgSkillDefinition(starter), path.starterSkillIDs.contains(starter) else {
        return .uncreated()
    }
    if !isLegacy {
        guard state.specializationBranchID == starterDef.branchID,
              (state.skillRanks[starter] ?? 0) >= 1,
              skillRequirementsMet(starterDef, attributes: state.attributes) else {
            return .uncreated()
        }
    }
    state.starterSkillID = starter
    state.specializationBranchID = starterDef.branchID
    state.skillRanks = replayLegalSkillRanks(state.skillRanks, base: state,
                                              grandfatherStarterFoundation: isLegacy)

    let knownSkills = sortSkillIDs(state.skillRanks.compactMap { $0.value > 0 ? $0.key : nil })
    state.preparedSkillIDs = stableUniqueSkillIDs(state.preparedSkillIDs)
        .filter { knownSkills.contains($0) && rpgSkillDefinition($0)?.kind == .active }
    if state.preparedSkillIDs.count > RPG_MAX_PREPARED_SKILLS {
        state.preparedSkillIDs = Array(state.preparedSkillIDs.prefix(RPG_MAX_PREPARED_SKILLS))
    }

    state.knownSpellIDs = rpgUnlockedSpellIDs(for: state.skillRanks)
    state.preparedSpellIDs = stableUniqueSpellIDs(state.preparedSpellIDs)
        .filter { state.knownSpellIDs.contains($0) }
    if state.preparedSpellIDs.count > RPG_MAX_PREPARED_SPELLS {
        state.preparedSpellIDs = Array(state.preparedSpellIDs.prefix(RPG_MAX_PREPARED_SPELLS))
    }
    if let selected = state.selectedPreparedSpellID, state.preparedSpellIDs.contains(selected) {
        state.selectedPreparedSpellID = selected
    } else {
        state.selectedPreparedSpellID = state.preparedSpellIDs.first
    }
    normalizeSelectedPreparedAction(&state)

    let derived = rpgDerivedStats(state)
    state.fatigue = max(0, min(derived.maxFatigue, state.fatigue.isFinite ? state.fatigue : derived.maxFatigue))
    state.actionSequence = max(0, min(RPG_MAX_COUNTER, state.actionSequence))
    state.authorityRevision = max(0, min(RPG_MAX_COUNTER, state.authorityRevision))
    var cooldownIDs = Set<String>()
    state.activeCooldowns = state.activeCooldowns.compactMap { cooldown in
        guard cooldown.remainingTicks > 0 else { return nil }
        guard rpgIsBoundedID(cooldown.id), cooldownIDs.insert(cooldown.id).inserted,
              rpgSkillDefinition(cooldown.id) != nil || rpgSpellDefinition(cooldown.id) != nil else { return nil }
        return RPGCooldown(id: cooldown.id, remainingTicks: min(RPG_MAX_EFFECT_TICKS, cooldown.remainingTicks))
    }
    if state.activeCooldowns.count > RPG_MAX_COOLDOWNS { state.activeCooldowns = Array(state.activeCooldowns.prefix(RPG_MAX_COOLDOWNS)) }
    var upkeepIDs = Set<String>()
    state.activeUpkeeps = state.activeUpkeeps.compactMap { upkeep in
        guard upkeep.remainingTicks > 0, state.preparedSpellIDs.contains(upkeep.spellID),
              rpgIsBoundedID(upkeep.spellID), upkeepIDs.insert(upkeep.spellID).inserted,
              let spell = rpgSpellDefinition(upkeep.spellID), spell.upkeepCostPerSecond > 0 else { return nil }
        return RPGUpkeep(spellID: upkeep.spellID, ownerSequence: min(RPG_MAX_COUNTER, upkeep.ownerSequence),
                         remainingTicks: min(RPG_MAX_EFFECT_TICKS, upkeep.remainingTicks),
                         costPerSecond: min(100, spell.upkeepCostPerSecond))
    }
    if state.activeUpkeeps.count > RPG_MAX_UPKEEPS { state.activeUpkeeps = Array(state.activeUpkeeps.prefix(RPG_MAX_UPKEEPS)) }
    if state.authorityRevision == RPG_MAX_COUNTER {
        state.activeUpkeeps.removeAll(keepingCapacity: false)
    }
    if isLegacy {
        state.kitGrantVersion = 0
        state.kitGrantID = nil
    } else if state.kitGrantVersion == RPG_STARTER_KIT_VERSION,
              state.kitGrantID == rpgStarterKitGrantID(pathID: path.id, starterSkillID: state.starterSkillID) {
        state.kitGrantVersion = RPG_STARTER_KIT_VERSION
        state.kitGrantID = rpgStarterKitGrantID(pathID: path.id, starterSkillID: state.starterSkillID)
    } else {
        state.kitGrantVersion = 0
        state.kitGrantID = nil
    }
    state.xpLedger = repairedXPLedger(state.xpLedger)
    return state
}

@discardableResult
public func rpgIncrementAuthorityRevision(_ state: inout RPGCharacterState) -> Bool {
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return false }
    state.authorityRevision += 1
    return true
}

/// Terminal cleanup is the only mutation allowed to consume the reserved final
/// revision. Empty cleanup is a strict no-op, making repeated save/death/dimension
/// boundaries idempotent.
@discardableResult
public func rpgClearTerminalUpkeeps(_ state: inout RPGCharacterState) -> Bool {
    guard state.authorityRevision < RPG_MAX_COUNTER, !state.activeUpkeeps.isEmpty else { return false }
    state.activeUpkeeps.removeAll(keepingCapacity: false)
    state.authorityRevision += 1
    return true
}

public func rpgNextActionSequence(_ state: RPGCharacterState) -> Int? {
    if state.actionSequence < RPG_MAX_COUNTER { return state.actionSequence + 1 }
    return nil
}

/// Checked low-level XP application used by the bounded event gate and white-box
/// progression simulations. Gameplay code must call `rpgAwardXPEvent`.
func rpgAddXP(_ amount: Int, to state: inout RPGCharacterState) -> RPGProgressionReport {
    state = repairRPGCharacterState(state)
    guard state.created, amount > 0 else {
        return RPGProgressionReport(leveledUp: false, previousLevel: state.level, newLevel: state.level)
    }
    let previous = state.level
    let capXP = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
    let beforeXP = state.xp
    state.xp = rpgSaturatedAdd(state.xp, amount, maximum: capXP)
    state.level = rpgLevel(forXP: state.xp)
    if state.level > previous {
        let maxFatigue = rpgDerivedStats(state).maxFatigue
        state.fatigue = min(maxFatigue, state.fatigue + Double(state.level - previous) * 2)
    }
    return RPGProgressionReport(leveledUp: state.level > previous, previousLevel: previous,
                                newLevel: state.level, awardedXP: state.xp - beforeXP)
}

private func rpgXPEventAward(_ event: RPGXPEvent, state: RPGCharacterState) -> Int? {
    guard event.magnitude > 0 else { return nil }
    switch event.kind {
    case .wardenMeleeDefeat:
        return state.pathID == "warden" ? 10 : nil
    case .wardenMitigation:
        return state.pathID == "warden" ? 2 : nil
    case .rangerRangedDefeat:
        return state.pathID == "ranger" ? 10 : nil
    case .rangerFieldDiscovery:
        return state.pathID == "ranger" ? 3 : nil
    case .delverDepthMilestone:
        return state.pathID == "delver" ? 3 : nil
    case .delverDungeonMilestone:
        return state.pathID == "delver" ? 12 : nil
    case .delverExcavation:
        return state.pathID == "delver" ? 4 : nil
    case .arcanistSpellDefeat:
        return state.pathID == "arcanist" ? 10 : nil
    case .arcanistSpellPractice:
        return state.pathID == "arcanist" ? 6 : nil
    case .menderEffectiveHealing:
        guard state.pathID == "mender" else { return nil }
        let award = min(8, event.magnitude / 2)
        return award > 0 ? award : nil
    case .menderCleanseRescue:
        return state.pathID == "mender" ? 4 : nil
    case .menderProvisionCraft:
        return state.pathID == "mender" ? 6 : nil
    case .tinkerFirstRecipe:
        return state.pathID == "tinker" ? 4 : nil
    case .tinkerMechanismTransition:
        return state.pathID == "tinker" ? 2 : nil
    case .tinkerEngineeringCraft:
        return state.pathID == "tinker" ? 6 : nil
    }
}

private func rpgEventMaskBit(_ index: Int?, upperBound: Int) -> UInt64? {
    guard let index, index >= 0, index < min(64, upperBound) else { return nil }
    return UInt64(1) << UInt64(index)
}

/// Applies one event's exact deduplication state to a private candidate. The
/// caller commits the candidate only after XP was actually added.
private func rpgPrepareXPEvent(_ event: RPGXPEvent,
                               simulationTick rawTick: Int,
                               worldDay rawDay: Int,
                               in state: inout RPGCharacterState) -> Int? {
    guard rpgIsBoundedID(event.key), let award = rpgXPEventAward(event, state: state), award > 0 else {
        return nil
    }
    guard (0...RPG_MAX_COUNTER).contains(rawTick),
          (0...RPG_MAX_COUNTER).contains(rawDay),
          rawTick >= state.xpLedger.windowStartTick else { return nil }
    let tick = rawTick
    _ = rawDay // retained in the public signature for schema/API compatibility
    let emptyWindow = state.xpLedger.recentKeys.isEmpty
        && RPGXPEventCategory.allCases.allSatisfy { state.xpLedger.counts.value($0) == 0 }
    if emptyWindow {
        state.xpLedger.windowStartTick = tick
    } else if tick - state.xpLedger.windowStartTick >= RPG_XP_WINDOW_TICKS {
        state.xpLedger.windowStartTick = tick
        state.xpLedger.counts = RPGXPWindowCounts()
        state.xpLedger.distinctSpellMask = 0
    }

    let category = event.kind.category
    guard state.xpLedger.counts.value(category) < category.windowLimit,
          !state.xpLedger.recentKeys.contains(event.key) else { return nil }

    switch event.kind {
    case .arcanistSpellPractice:
        guard let bit64 = rpgEventMaskBit(event.registryIndex, upperBound: RPG_SPELL_DEFINITIONS.count) else { return nil }
        let bit = UInt32(bit64)
        guard state.xpLedger.distinctSpellMask & bit == 0 else { return nil }
        state.xpLedger.distinctSpellMask |= bit
    case .delverDepthMilestone:
        guard let bit = rpgEventMaskBit(event.registryIndex, upperBound: 6),
              state.xpLedger.depthMilestoneMask & bit == 0 else { return nil }
        state.xpLedger.depthMilestoneMask |= bit
    case .tinkerFirstRecipe:
        guard let index = event.registryIndex, index >= 0, index < craftingRecipes.count,
              index / 64 < RPG_MAX_RECIPE_MILESTONE_WORDS else { return nil }
        let word = index / 64
        let bit = UInt64(1) << UInt64(index % 64)
        while state.xpLedger.recipeMilestoneWords.count <= word {
            state.xpLedger.recipeMilestoneWords.append(0)
        }
        guard state.xpLedger.recipeMilestoneWords[word] & bit == 0 else { return nil }
        state.xpLedger.recipeMilestoneWords[word] |= bit
    default:
        break
    }

    state.xpLedger.counts.increment(category)
    state.xpLedger.recentKeys.append(event.key)
    if state.xpLedger.recentKeys.count > RPG_MAX_XP_EVENT_KEYS {
        state.xpLedger.recentKeys.removeFirst(state.xpLedger.recentKeys.count - RPG_MAX_XP_EVENT_KEYS)
    }
    return award
}

/// Transaction-safe event batch. Action preparation uses `incrementRevision:
/// false` and publishes exactly one checked revision with the rest of the action.
@discardableResult
func rpgAwardXPEvents(_ events: [RPGXPEvent],
                      simulationTick: Int,
                      worldDay: Int,
                      incrementRevision: Bool,
                      to state: inout RPGCharacterState) -> RPGProgressionReport {
    let original = state
    let initialLevel = original.level
    var working = repairRPGCharacterState(original)
    let empty = RPGProgressionReport(leveledUp: false, previousLevel: initialLevel,
                                     newLevel: initialLevel)
    guard working.created, working.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION,
          working.xp < rpgXPRequiredForLevel(RPG_LEVEL_CAP) else { return empty }

    var totalAwarded = 0
    let previousLevel = working.level
    for event in events {
        guard working.xp < rpgXPRequiredForLevel(RPG_LEVEL_CAP) else { break }
        var candidate = working
        guard let award = rpgPrepareXPEvent(event, simulationTick: simulationTick,
                                            worldDay: worldDay, in: &candidate) else { continue }
        let report = rpgAddXP(award, to: &candidate)
        guard report.awardedXP > 0 else { continue }
        totalAwarded = rpgSaturatedAdd(totalAwarded, report.awardedXP,
                                       maximum: rpgXPRequiredForLevel(RPG_LEVEL_CAP))
        working = candidate
    }
    guard totalAwarded > 0 else { return empty }
    if incrementRevision {
        guard rpgIncrementAuthorityRevision(&working) else { return empty }
    }
    state = working
    return RPGProgressionReport(leveledUp: working.level > previousLevel,
                                previousLevel: previousLevel, newLevel: working.level,
                                awardedXP: totalAwarded)
}

/// Authoritative, bounded class-XP gate. Rejected and max-level events leave
/// the entire input state byte-for-byte unchanged and reserve no dedup key.
@discardableResult
public func rpgAwardXPEvent(_ event: RPGXPEvent,
                            simulationTick: Int,
                            worldDay: Int,
                            to state: inout RPGCharacterState) -> RPGProgressionReport {
    rpgAwardXPEvents([event], simulationTick: simulationTick, worldDay: worldDay,
                     incrementRevision: true, to: &state)
}

public func rpgLearnSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    let evaluation = rpgEvaluateSkillPurchase(skillID, in: state)
    if let failure = evaluation.failure {
        switch failure {
        case .characterNotCreated: return .characterNotCreated
        case .unknownOrCrossPathSkill(let id): return .unknownSkill(id)
        case .authorityRevisionExhausted: return .authorityExhausted
        case .alreadyAtMaximumRank(let id): return .alreadyAtMaximumRank(id)
        case .insufficientLevel(let required): return .insufficientLevel(required: required)
        case .insufficientAttribute(let attribute, let required):
            return .insufficientAttribute(attribute, required: required)
        case .missingPrerequisite(let id): return .missingPrerequisite(id)
        case .insufficientSkillPoints: return .insufficientSkillPoints
        }
    }

    state.skillRanks[skillID] = evaluation.targetRank
    state.knownSpellIDs = rpgUnlockedSpellIDs(for: state.skillRanks)
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgSpendAttributePoint(_ attribute: RPGAttributeID, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    guard rpgAvailableAttributePoints(state) > 0 else { return .insufficientAttributePoints }
    let current = state.attributes.value(attribute)
    guard current < RPGAttributes.maximumWithProgression else {
        return .insufficientAttribute(attribute, required: current + 1)
    }
    state.attributes.set(attribute, current + 1)
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgPrepareSpell(_ spellID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSpellDefinition(spellID) != nil else { return .unknownSpell(spellID) }
    guard state.knownSpellIDs.contains(spellID) else { return .spellNotKnown(spellID) }
    if state.preparedSpellIDs.contains(spellID) { return nil }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    guard state.preparedSpellIDs.count < RPG_MAX_PREPARED_SPELLS else { return .preparedSpellLimit }
    state.preparedSpellIDs.append(spellID)
    state.preparedSpellIDs = sortSpellIDs(state.preparedSpellIDs)
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgUnprepareSpell(_ spellID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSpellDefinition(spellID) != nil else { return .unknownSpell(spellID) }
    let wasPrepared = state.preparedSpellIDs.contains(spellID)
    guard wasPrepared else { return nil }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    state.preparedSpellIDs.removeAll { $0 == spellID }
    if state.selectedPreparedSpellID == spellID { state.selectedPreparedSpellID = state.preparedSpellIDs.first }
    if state.selectedPreparedActionID == rpgPreparedActionToken(kind: .spell, id: spellID) {
        state.selectedPreparedActionID = nil
    }
    state.activeUpkeeps.removeAll { $0.spellID == spellID }
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgSelectPreparedSpell(_ spellID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSpellDefinition(spellID) != nil else { return .unknownSpell(spellID) }
    guard state.preparedSpellIDs.contains(spellID) else { return .spellNotKnown(spellID) }
    let token = rpgPreparedActionToken(kind: .spell, id: spellID)
    if state.selectedPreparedSpellID == spellID, state.selectedPreparedActionID == token { return nil }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    state.selectedPreparedSpellID = spellID
    state.selectedPreparedActionID = token
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgPrepareSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard let def = rpgSkillDefinition(skillID) else { return .unknownSkill(skillID) }
    guard (state.skillRanks[skillID] ?? 0) > 0 else { return .skillNotKnown(skillID) }
    guard def.kind == .active else { return .skillNotActive(skillID) }
    if state.preparedSkillIDs.contains(skillID) { return nil }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    guard state.preparedSkillIDs.count < RPG_MAX_PREPARED_SKILLS else { return .preparedSkillLimit }
    state.preparedSkillIDs.append(skillID)
    state.preparedSkillIDs = sortSkillIDs(state.preparedSkillIDs)
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgUnprepareSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSkillDefinition(skillID) != nil else { return .unknownSkill(skillID) }
    let wasPrepared = state.preparedSkillIDs.contains(skillID)
    guard wasPrepared else { return nil }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    state.preparedSkillIDs.removeAll { $0 == skillID }
    if state.selectedPreparedActionID == rpgPreparedActionToken(kind: .skill, id: skillID) {
        state.selectedPreparedActionID = nil
    }
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgSelectPreparedSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard let def = rpgSkillDefinition(skillID) else { return .unknownSkill(skillID) }
    guard def.kind == .active, (state.skillRanks[skillID] ?? 0) > 0 else { return .skillNotKnown(skillID) }
    guard state.preparedSkillIDs.contains(skillID) else { return .skillNotKnown(skillID) }
    let token = rpgPreparedActionToken(kind: .skill, id: skillID)
    if state.selectedPreparedActionID == token { return nil }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION else { return .authorityExhausted }
    state.selectedPreparedActionID = token
    _ = rpgIncrementAuthorityRevision(&state)
    state = repairRPGCharacterState(state)
    return nil
}

/// Advances continuous RPG resources. This deterministic per-tick evolution is
/// intentionally revision-free; authority revisions are reserved for discrete
/// player requests and terminal cleanup boundaries.
@discardableResult
public func rpgTickState(_ state: inout RPGCharacterState) -> [RPGUpkeep] {
    state = repairRPGCharacterState(state)
    guard state.created else { return [] }
    let previousUpkeeps = state.activeUpkeeps
    let derived = rpgDerivedStats(state)
    if state.fatigue < derived.maxFatigue {
        state.fatigue = min(derived.maxFatigue, state.fatigue + derived.fatigueRegenPerTick)
    }
    state.activeCooldowns = state.activeCooldowns.compactMap {
        let remaining = $0.remainingTicks - 1
        return remaining > 0 ? RPGCooldown(id: $0.id, remainingTicks: remaining) : nil
    }
    var upkeepCost = 0.0
    state.activeUpkeeps = state.activeUpkeeps.compactMap { upkeep in
        let remaining = upkeep.remainingTicks - 1
        if remaining <= 0 { return nil }
        upkeepCost += upkeep.costPerSecond / 20.0
        return RPGUpkeep(spellID: upkeep.spellID, ownerSequence: upkeep.ownerSequence,
                         remainingTicks: remaining, costPerSecond: upkeep.costPerSecond)
    }
    if upkeepCost > 0 {
        state.fatigue = max(0, state.fatigue - upkeepCost)
        if state.fatigue <= 0 { state.activeUpkeeps.removeAll() }
    }
    let remainingKeys = Set(state.activeUpkeeps.map {
        RPGUpkeepIdentity(spellID: $0.spellID, ownerSequence: $0.ownerSequence)
    })
    return previousUpkeeps.filter {
        !remainingKeys.contains(RPGUpkeepIdentity(spellID: $0.spellID,
                                                  ownerSequence: $0.ownerSequence))
    }
}

private struct RPGUpkeepIdentity: Hashable {
    var spellID: String
    var ownerSequence: Int
}

public func rpgIncomingDamageMultiplier(_ player: Player, source: String, attacker: Entity?) -> Double {
    guard player.rpgClassesEnabled(), player.rpg.created else { return 1 }
    var multiplier = 1.0
    if source == "explosion" || source == "trap" || source == "anvil" {
        multiplier *= 1 - rpgSkillEffectValue(.tripwireMind, in: player.rpg)
    }
    let ownedControlledCharge = (attacker as? TNTEntity).map {
        $0.rpgControlledChargeOwnerEntityID == player.id
            && $0.rpgControlledChargeOwnerAuthorityID == player.effectiveRPGAuthorityID
    } ?? false
    if source == "explosion", attacker === player || ownedControlledCharge {
        multiplier *= 1 - rpgSkillEffectValue(.blastShape, in: player.rpg)
    }
    return max(0.1, multiplier)
}

private let RPG_HARD_STONE_BLOCK_NAMES: Set<String> = [
    "stone", "deepslate", "granite", "diorite", "andesite", "tuff", "calcite",
    "dripstone_block", "blackstone", "basalt", "smooth_basalt", "end_stone",
]

public func rpgIsHardStoneOrOreBlock(_ blockID: Int) -> Bool {
    guard blockID > 0, blockID < blockDefs.count else { return false }
    let name = blockDefs[blockID].name
    return RPG_HARD_STONE_BLOCK_NAMES.contains(name)
        || name.hasSuffix("_ore")
        || name == "ancient_debris"
}

public func rpgCanHarvestHardStoneOrOre(_ player: Player, cell: Int) -> Bool {
    let blockID = cell >> 4
    guard rpgIsHardStoneOrOreBlock(blockID),
          let tool = player.mainHand.flatMap({ itemDef($0.id).tool }),
          tool.type == "pickaxe" else { return false }
    return canHarvest(player, cell)
}

public func rpgMiningSpeedMultiplier(_ player: Player, blockID: Int) -> Double {
    guard player.rpgClassesEnabled(), player.rpg.created,
          rpgIsHardStoneOrOreBlock(blockID) else { return 1 }
    return 1 + rpgSkillEffectValue(.veinReader, in: player.rpg)
}

public func rpgBowEffectiveChargeTicks(_ player: Player, rawTicks: Int) -> Int {
    guard player.rpgClassesEnabled(), player.rpg.created else { return max(0, rawTicks) }
    return rpgSaturatedAdd(max(0, rawTicks), Int(rpgSkillEffectValue(.quickDraw, in: player.rpg)), maximum: 20)
}

public func rpgSneakingMovementMultiplier(_ player: Player, swiftSneakLevel: Int) -> Double {
    let enchantmentBonus = 0.15 * Double(max(0, swiftSneakLevel))
    let softStep = player.rpgClassesEnabled() && player.rpg.created
        ? rpgSkillEffectValue(.softStep, in: player.rpg) : 0
    return clampD((0.3 + enchantmentBonus) * (1 + softStep), 0, 1)
}

public enum RPGWeatherEyeStatus: Equatable {
    case active(currentWeather: String, roundedTransitionTicks: Int,
                roundedTransitionSeconds: Int)
    case cycleLocked(currentWeather: String)
    case unavailable(dimensionName: String)
}

public func rpgWeatherEyeStatus(_ player: Player) -> RPGWeatherEyeStatus? {
    guard player.rpgClassesEnabled(), player.rpg.created else { return nil }
    let quantum = Int(rpgSkillEffectValue(.weatherEye, in: player.rpg))
    guard quantum > 0 else { return nil }
    guard player.world.dim == .overworld else {
        let name = player.world.dim == .nether ? "Nether" : "End"
        return .unavailable(dimensionName: name)
    }
    let weather = player.world.thundering ? "thunder" : player.world.raining ? "rain" : "clear"
    guard player.world.rule("doWeatherCycle") else {
        return .cycleLocked(currentWeather: weather)
    }
    let remaining = max(0, min(RPG_MAX_COUNTER, player.world.weatherTimer))
    let rounded = remaining == 0 ? 0
        : min(RPG_MAX_COUNTER, ((remaining - 1) / quantum + 1) * quantum)
    return .active(currentWeather: weather, roundedTransitionTicks: rounded,
                   roundedTransitionSeconds: rounded / 20)
}

private let RPG_PLANT_FOOD_ITEM_NAMES: Set<String> = [
    "apple", "golden_apple", "enchanted_golden_apple", "bread", "cookie", "melon_slice",
    "dried_kelp", "carrot", "golden_carrot", "potato", "baked_potato", "beetroot",
    "beetroot_soup", "mushroom_stew", "suspicious_stew", "pumpkin_pie", "chorus_fruit",
    "honey_bottle", "glow_berries", "sweet_berries",
]

public func rpgIsPlantFoodItem(_ itemID: Int) -> Bool {
    guard itemID >= 0, itemID < itemDefs.count, itemDef(itemID).food != nil else { return false }
    return RPG_PLANT_FOOD_ITEM_NAMES.contains(itemDef(itemID).name)
}

@discardableResult
public func rpgRestoreHerbalLoreFatigue(_ player: Player, consumedItemID: Int) -> Double {
    guard player.rpgClassesEnabled(), player.rpg.created,
          rpgIsPlantFoodItem(consumedItemID) else { return 0 }
    let amount = rpgSkillEffectValue(.herbalLore, in: player.rpg)
    guard amount > 0 else { return 0 }
    let before = player.rpg.fatigue
    player.restoreRPGFatigue(amount, source: .herbalLore, perTickCap: 1.5)
    return max(0, player.rpg.fatigue - before)
}

public struct RPGCircuitSenseInspection: Equatable {
    public var position: RPGBlockPosition
    public var blockID: Int
    public var range: Int
    public var powerLevel: Int
    public var configuredDelayTicks: Int?
    public var powerSourceDirection: String?

    public var powered: Bool { powerLevel > 0 }
}

public func rpgIsCircuitComponentBlock(_ blockID: Int) -> Bool {
    guard blockID > 0, blockID < blockDefs.count else { return false }
    switch Shape(rawValue: SHAPE_OF[blockID]) ?? .cube {
    case .redstoneWire, .repeater, .comparator, .piston, .daylightSensor,
         .lever, .button, .pressurePlate, .tripwireHook:
        return true
    default:
        return blockID == Int(B.redstone_torch) || blockID == Int(B.redstone_torch_off)
            || blockID == Int(B.redstone_block) || blockID == Int(B.observer)
            || blockID == Int(B.detector_rail) || blockID == Int(B.target)
            || blockID == Int(B.sculk_sensor) || blockID == Int(B.calibrated_sculk_sensor)
            || blockID == Int(B.lightning_rod) || blockID == Int(B.trapped_chest)
            || blockID == Int(B.redstone_lamp) || blockID == Int(B.redstone_lamp_on)
            || blockID == Int(B.dispenser) || blockID == Int(B.dropper)
            || blockID == Int(B.note_block) || blockID == Int(B.tnt)
    }
}

public func rpgCircuitSenseInspection(_ player: Player) -> RPGCircuitSenseInspection? {
    guard player.rpgClassesEnabled(), player.rpg.created else { return nil }
    let rank = rpgSkillRank(.circuitSense, in: player.rpg)
    let range = Int(rpgSkillEffectValue(.circuitSense, in: player.rpg))
    guard rank > 0, range > 0 else { return nil }
    let dx = -detSin(player.yaw) * detCos(player.pitch)
    let dy = -detSin(player.pitch)
    let dz = detCos(player.yaw) * detCos(player.pitch)
    guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, dx, dy, dz,
                                         Double(range)),
          player.world.isLoadedAt(hit.x, hit.z) else { return nil }
    let blockID = hit.cell >> 4
    guard rpgIsCircuitComponentBlock(blockID) else { return nil }

    var selfPower = 0
    for direction in 0..<6 {
        selfPower = max(selfPower, emittedPower(player.world, hit.x, hit.y, hit.z, direction))
    }
    let power = max(selfPower, powerAt(player.world, hit.x, hit.y, hit.z))
    let repeater = blockID == Int(B.repeater) || blockID == Int(B.repeater_on)
    let delay = rank >= 2 && repeater ? (((hit.cell & 15) >> 2) & 3) * 2 + 2 : nil
    let sourceDirection = rank >= 3
        ? rpgNearestPoweredRedstoneSource(player.world, x: hit.x, y: hit.y, z: hit.z)?.direction
        : nil
    return RPGCircuitSenseInspection(position: RPGBlockPosition(hit.x, hit.y, hit.z),
                                     blockID: blockID, range: range, powerLevel: power,
                                     configuredDelayTicks: delay,
                                     powerSourceDirection: sourceDirection)
}

public func rpgHUDVisible(_ player: Player) -> Bool {
    player.rpgClassesEnabled() && player.rpg.created
}

public struct RPGHUDInsightLayout: Equatable {
    public var x: Double
    public var y: Double
    public var maximumWidth: Int
}

public struct RPGHUDDrawPlan: Equatable {
    public var showInsights: Bool
    public var showQuickSlots: Bool
    public var liftSurvivalHUD: Bool
}

public struct RPGHUDInsightCacheKey: Equatable {
    public var simulationTick: Int
    public var worldIdentity: ObjectIdentifier
    public var playerIdentity: ObjectIdentifier
}

public struct RPGHUDInsightCache {
    private var key: RPGHUDInsightCacheKey?
    private var cachedLines: [String] = []

    public init() {}

    public mutating func resolve(key nextKey: RPGHUDInsightCacheKey?,
                                 compute: () -> [String]) -> [String] {
        guard let nextKey else {
            key = nil
            cachedLines = []
            return []
        }
        if key != nextKey {
            cachedLines = compute()
            key = nextKey
        }
        return cachedLines
    }
}

public func rpgHUDDrawPlan(_ player: Player, screenOpen: Bool) -> RPGHUDDrawPlan {
    let visible = rpgHUDVisible(player)
    return RPGHUDDrawPlan(showInsights: visible && !screenOpen,
                          showQuickSlots: visible,
                          liftSurvivalHUD: visible && player.gameMode != GameMode.creative)
}

public func rpgHUDInsightCacheKey(_ player: Player,
                                  screenOpen: Bool) -> RPGHUDInsightCacheKey? {
    guard rpgHUDDrawPlan(player, screenOpen: screenOpen).showInsights else { return nil }
    return RPGHUDInsightCacheKey(simulationTick: player.world.rpgSimulationTick,
                                 worldIdentity: ObjectIdentifier(player.world),
                                 playerIdentity: ObjectIdentifier(player))
}

/// Keeps insight text inside the viewport and outside the crosshair exclusion
/// zone. The renderer still performs pixel-font clipping within maximumWidth.
public func rpgHUDInsightLayout(viewWidth: Double,
                                viewHeight: Double) -> RPGHUDInsightLayout {
    let width = max(0, viewWidth)
    let height = max(0, viewHeight)
    let centerX = (width / 2).rounded(.down)
    let margin = 6.0
    let crosshairGap = 14.0
    let rightX = centerX + crosshairGap
    let rightWidth = max(0, Int((width - rightX - margin).rounded(.down)))
    let leftWidth = max(0, Int((centerX - crosshairGap - margin).rounded(.down)))
    if rightWidth >= 96 || rightWidth >= leftWidth {
        return RPGHUDInsightLayout(x: rightX, y: height / 2 + 10,
                                   maximumWidth: rightWidth)
    }
    return RPGHUDInsightLayout(x: margin, y: height / 2 + 10,
                               maximumWidth: leftWidth)
}

public func rpgHUDInsightLines(_ player: Player) -> [String] {
    guard rpgHUDVisible(player) else { return [] }
    var lines: [String] = []
    if let weather = rpgWeatherEyeStatus(player) {
        switch weather {
        case .active(let current, _, let seconds):
            lines.append("Weather \(current) · change ~\(seconds)s")
        case .cycleLocked(let current):
            lines.append("Weather \(current) · cycle locked")
        case .unavailable(let dimensionName):
            lines.append("Weather unavailable in \(dimensionName)")
        }
    }
    if let circuit = rpgCircuitSenseInspection(player) {
        var parts = ["Signal \(circuit.powerLevel)"]
        if let delay = circuit.configuredDelayTicks { parts.append("Delay \(delay)t") }
        if let source = circuit.powerSourceDirection { parts.append("Source \(source)") }
        lines.append(parts.joined(separator: " · "))
    }
    return Array(lines.prefix(2))
}

public func rpgCleanupEndedUpkeeps(_ player: Player, _ endedUpkeeps: [RPGUpkeep]) {
    for upkeep in endedUpkeeps where upkeep.spellID == RPGSpellEffectID.summonServant.rawValue {
        let key = RPGTemporaryEffectKey(ownerAuthorityID: player.effectiveRPGAuthorityID,
                                        ownerSequence: upkeep.ownerSequence,
                                        kind: .servant)
        _ = player.world.removeRPGTemporaryEffect(key, restoreGuardedBlock: true)
    }
}

public func rpgBowInaccuracy(_ player: Player) -> Double {
    guard player.rpgClassesEnabled(), player.rpg.created else { return 1 }
    let dexterityBonus = rpgDerivedStats(player.rpg).actionAccuracyBonus
    let steadyBonus = player.onGround ? rpgSkillEffectValue(.steadyAim, in: player.rpg) : 0
    return max(0.1, 1 - dexterityBonus - steadyBonus)
}

public func rpgPlayerHasSpellFocus(_ player: Player) -> Bool {
    guard let focusID = iidOpt("apprentice_focus") else { return false }
    return player.mainHand?.id == focusID || player.offHand?.id == focusID
}

public func rpgCleanBrewDuration(_ player: Player, effectID: String, baseDuration: Int) -> Int {
    guard baseDuration > 0, player.rpgClassesEnabled(), player.rpg.created,
          let definition = EFFECT_BY_ID[effectID], definition.beneficial, !definition.instant else {
        return baseDuration
    }
    let multiplier = rpgSkillEffectValue(.cleanBrew, in: player.rpg)
    guard multiplier > 1, multiplier.isFinite else { return baseDuration }
    let extended = (Double(baseDuration) * multiplier).rounded(.down)
    guard extended.isFinite else { return RPG_MAX_EFFECT_TICKS }
    return max(1, min(RPG_MAX_EFFECT_TICKS, Int(min(Double(RPG_MAX_EFFECT_TICKS), extended))))
}

public func rpgCampcraftSafeRest(_ player: Player) -> Bool {
    guard player.onGround, !player.sprinting, player.hurtTime <= 0,
          player.fireTicks <= 0, !player.inLava, !player.inPowderSnow, !player.underwater,
          abs(player.moveForward) < 0.001, abs(player.moveStrafe) < 0.001,
          abs(player.vx) < 0.01, abs(player.vz) < 0.01 else { return false }
    let feetID = player.world.getBlock(ifloor(player.x), ifloor(player.y + 0.1), ifloor(player.z)) >> 4
    let belowID = player.world.getBlock(ifloor(player.x), ifloor(player.y - 0.1), ifloor(player.z)) >> 4
    let hazards: Set<Int> = [Int(B.fire), Int(B.soul_fire), Int(B.cactus), Int(B.magma_block),
                             Int(B.campfire), Int(B.soul_campfire), Int(B.sweet_berry_bush)]
    guard !hazards.contains(feetID), !hazards.contains(belowID) else { return false }
    return !player.world.getEntitiesNear(player.x, player.y + player.height * 0.5, player.z, 8)
        .contains { entity in
            guard let living = entity as? LivingEntity, living !== player, !living.dead else { return false }
            return rpgIsHostileTarget(living)
        }
}

private func rpgApplyTrailSense(_ player: Player) {
    guard player.sneaking, player.world.rpgSimulationTick % 20 == 0 else { return }
    let radius = rpgSkillEffectValue(.trailSense, in: player.rpg)
    guard radius > 0 else { return }
    let targets = player.world.getEntitiesNear(player.x, player.y + player.height * 0.5,
                                                player.z, radius)
        .compactMap { $0 as? LivingEntity }
        .filter { $0 !== player && !$0.dead && rpgIsHostileTarget($0) }
        .sorted {
            let left = player.distanceToSq($0), right = player.distanceToSq($1)
            return left == right ? $0.id < $1.id : left < right
        }
    for target in targets.prefix(32) { target.addEffect("glowing", 25, 0) }
}

public func rpgHandleBlockBreak(_ player: Player, cell: Int,
                                x: Int = 0, y: Int, z: Int = 0) {
    guard player.rpgClassesEnabled(), player.rpg.created, player.gameMode != GameMode.creative else { return }
    let blockID = cell >> 4
    guard blockID >= 0, blockID < blockDefs.count else { return }
    if player.rpg.pathID == "delver", player.world.dim == .overworld, y < 63,
       rpgCanHarvestHardStoneOrOre(player, cell: cell) {
        let key = "excavate:\(player.world.dim.rawValue):\(x):\(y):\(z)"
        _ = player.awardRPGXP(RPGXPEvent(kind: .delverExcavation, key: key))
    }
    if y < 63, rpgCanHarvestHardStoneOrOre(player, cell: cell) {
        player.restoreRPGFatigue(rpgSkillEffectValue(.deepReserves, in: player.rpg),
                                 source: .harvest, perTickCap: 1)
    }
    let meta = cell & 15
    let mature = blockID == Int(B.wheat) || blockID == Int(B.carrots) || blockID == Int(B.potatoes)
        ? meta >= 7
        : blockID == Int(B.beetroots) || blockID == Int(B.nether_wart) ? meta >= 3 : false
    if mature {
        player.restoreRPGFatigue(rpgSkillEffectValue(.greenThumb, in: player.rpg),
                                 source: .harvest, perTickCap: 1)
    }
}

private let RPG_DELVER_DEPTH_THRESHOLDS = [32, 16, 0, -16, -32, -48]

public func rpgAwardReachedDepthMilestones(_ player: Player) {
    guard player.rpgClassesEnabled(), player.rpg.created, player.rpg.pathID == "delver",
          player.world.dim == .overworld else { return }
    let blockY = ifloor(player.y)
    for (index, threshold) in RPG_DELVER_DEPTH_THRESHOLDS.enumerated() where blockY <= threshold {
        _ = player.awardRPGXP(RPGXPEvent(kind: .delverDepthMilestone,
                                         key: "depth:\(index)", registryIndex: index))
    }
}

public func rpgAwardCurrentChunkDiscovery(_ player: Player) {
    guard player.rpgClassesEnabled(), player.rpg.created, player.rpg.pathID == "ranger" else { return }
    let bx = ifloor(player.x), bz = ifloor(player.z)
    guard player.world.isLoadedAt(bx, bz) else { return }
    let cx = floorDiv(bx, CHUNK_W), cz = floorDiv(bz, CHUNK_W)
    let key = "field:\(player.world.dim.rawValue):\(cx):\(cz)"
    guard rpgIsBoundedID(key) else { return }
    _ = player.awardRPGXP(RPGXPEvent(kind: .rangerFieldDiscovery, key: key))
}

private let RPG_PROVISION_BENEFICIAL_EFFECT_IDS: Set<String> = [
    "speed", "haste", "strength", "instant_health", "jump_boost", "regeneration",
    "resistance", "fire_resistance", "water_breathing", "invisibility", "night_vision",
    "health_boost", "absorption", "saturation", "slow_falling", "conduit_power",
    "dolphins_grace", "hero_of_the_village",
]

public func rpgIsProvisionFoodItem(_ itemID: Int) -> Bool {
    guard itemID >= 0, itemID < itemDefs.count,
          let food = itemDef(itemID).food, food.hunger > 0 else { return false }
    return food.effects.allSatisfy { effect in
        RPG_PROVISION_BENEFICIAL_EFFECT_IDS.contains(effect.effect)
            && EFFECT_BY_ID[effect.effect]?.beneficial == true
    }
}

private let RPG_WEAPON_TOOL_TYPES: Set<String> = ["sword", "bow", "crossbow", "trident"]

public func rpgIsEngineeringItem(_ itemID: Int) -> Bool {
    guard itemID >= 0, itemID < itemDefs.count else { return false }
    let definition = itemDef(itemID)
    if let block = definition.block, rpgIsCircuitComponentBlock(Int(block)) { return true }
    guard let tool = definition.tool else { return false }
    return !RPG_WEAPON_TOOL_TYPES.contains(tool.type)
}

private func rpgRecipeMilestoneWasAwarded(_ state: RPGCharacterState,
                                           recipeIndex: Int) -> Bool {
    guard recipeIndex >= 0, recipeIndex / 64 < state.xpLedger.recipeMilestoneWords.count else {
        return false
    }
    return state.xpLedger.recipeMilestoneWords[recipeIndex / 64]
        & (UInt64(1) << UInt64(recipeIndex % 64)) != 0
}

private func rpgRemainingXPEvents(_ category: RPGXPEventCategory,
                                  state: RPGCharacterState,
                                  simulationTick: Int) -> Int {
    guard (0...RPG_MAX_COUNTER).contains(simulationTick),
          simulationTick >= state.xpLedger.windowStartTick else { return 0 }
    if simulationTick - state.xpLedger.windowStartTick >= RPG_XP_WINDOW_TICKS {
        return category.windowLimit
    }
    return max(0, category.windowLimit - state.xpLedger.counts.value(category))
}

@discardableResult
public func rpgAwardCraftedRecipe(_ player: Player, recipeIndex: Int,
                                  completedRounds: Int = 1) -> RPGProgressionReport {
    let empty = RPGProgressionReport(leveledUp: false, previousLevel: player.rpg.level,
                                     newLevel: player.rpg.level)
    guard player.rpgClassesEnabled(), player.rpg.created,
          player.gameMode != GameMode.creative,
          recipeIndex >= 0, recipeIndex < craftingRecipes.count,
          completedRounds > 0 else { return empty }
    let state = repairRPGCharacterState(player.rpg)
    let tick = player.world.rpgSimulationTick
    var events: [RPGXPEvent] = []
    switch state.pathID {
    case "mender":
        guard rpgIsProvisionFoodItem(craftingRecipeOutput(craftingRecipes[recipeIndex]).id) else {
            return empty
        }
        let available = rpgRemainingXPEvents(.heal, state: state, simulationTick: tick)
        for round in 0..<min(completedRounds, available) {
            events.append(RPGXPEvent(kind: .menderProvisionCraft,
                                     key: "provision:\(recipeIndex):\(tick):\(state.authorityRevision):\(round)"))
        }
    case "tinker":
        var available = rpgRemainingXPEvents(.engineer, state: state, simulationTick: tick)
        let firstKey = "recipe:\(recipeIndex)"
        let firstWillAward = available > 0
            && !rpgRecipeMilestoneWasAwarded(state, recipeIndex: recipeIndex)
            && !state.xpLedger.recentKeys.contains(firstKey)
        if firstWillAward {
            events.append(RPGXPEvent(kind: .tinkerFirstRecipe, key: firstKey,
                                     registryIndex: recipeIndex))
            available -= 1
        }
        if rpgIsEngineeringItem(craftingRecipeOutput(craftingRecipes[recipeIndex]).id) {
            for round in 0..<min(completedRounds, available) {
                events.append(RPGXPEvent(kind: .tinkerEngineeringCraft,
                                         key: "engineer:\(recipeIndex):\(tick):\(state.authorityRevision):\(round)"))
            }
        }
    default:
        return empty
    }
    guard !events.isEmpty else { return empty }
    let report = rpgAwardXPEvents(events, simulationTick: tick,
                                  worldDay: max(0, tick / DAY_LENGTH),
                                  incrementRevision: true, to: &player.rpg)
    if report.awardedXP > 0 { player.applyRPGDerivedStats() }
    return report
}

public struct RPGStarterKitEntry: Equatable {
    public var itemID: String
    public var count: Int
    public var potionID: String?

    public init(_ itemID: String, _ count: Int = 1, potionID: String? = nil) {
        self.itemID = itemID
        self.count = max(1, count)
        self.potionID = potionID
    }
}

public func rpgStarterKitGrantID(pathID: String, starterSkillID: String) -> String {
    "v\(RPG_STARTER_KIT_VERSION):\(pathID):\(starterSkillID)"
}

public func rpgStarterKit(pathID: String) -> [RPGStarterKitEntry]? {
    switch pathID {
    case "warden":
        return [RPGStarterKitEntry("stone_sword"), RPGStarterKitEntry("shield"), RPGStarterKitEntry("bread", 4)]
    case "ranger":
        return [RPGStarterKitEntry("bow"), RPGStarterKitEntry("arrow", 24),
                RPGStarterKitEntry("stone_sword"), RPGStarterKitEntry("bread", 4)]
    case "delver":
        return [RPGStarterKitEntry("stone_pickaxe"), RPGStarterKitEntry("torch", 16), RPGStarterKitEntry("bread", 4)]
    case "arcanist":
        return [RPGStarterKitEntry("apprentice_focus"), RPGStarterKitEntry("torch", 8), RPGStarterKitEntry("bread", 4)]
    case "mender":
        return [RPGStarterKitEntry("apprentice_focus"),
                RPGStarterKitEntry("potion", potionID: "healing"),
                RPGStarterKitEntry("potion", potionID: "healing"),
                RPGStarterKitEntry("bread", 4)]
    case "tinker":
        return [RPGStarterKitEntry("stone_pickaxe"), RPGStarterKitEntry("redstone", 12),
                RPGStarterKitEntry("torch", 4), RPGStarterKitEntry("bread", 4)]
    default:
        return nil
    }
}

public func rpgStarterKitStacks(pathID: String) -> Result<[ItemStack], RPGCreationError> {
    guard let kit = rpgStarterKit(pathID: pathID) else { return .failure(.unknownPath(pathID)) }
    var stacks: [ItemStack] = []
    for entry in kit {
        guard let itemID = iidOpt(entry.itemID) else { return .failure(.starterKitUnavailable(entry.itemID)) }
        var data = StackData()
        data.potion = entry.potionID
        stacks.append(ItemStack(itemID, entry.count, data: data))
    }
    return .success(stacks)
}

private func inventoryByAdding(_ additions: [ItemStack], to inventory: [ItemStack?]) -> [ItemStack?]? {
    var result = inventory.map(copyStack)
    for addition in additions {
        let remaining = addition.copy()
        for index in result.indices where remaining.count > 0 {
            guard let existing = result[index], canMerge(existing, remaining) else { continue }
            let take = min(max(0, maxStackOf(existing) - existing.count), remaining.count)
            existing.count += take
            remaining.count -= take
        }
        while remaining.count > 0 {
            guard let empty = result.firstIndex(where: { $0 == nil }) else { return nil }
            let placed = remaining.copy()
            placed.count = min(maxStackOf(placed), remaining.count)
            remaining.count -= placed.count
            result[empty] = placed
        }
    }
    return result
}

public func rpgStarterKitFitsInInventory(pathID: String,
                                         inventory: [ItemStack?]) -> Bool {
    guard case .success(let stacks) = rpgStarterKitStacks(pathID: pathID) else { return false }
    return inventoryByAdding(stacks, to: inventory) != nil
}

public enum RPGFatigueRestorationSource: String, CaseIterable {
    case harvest
    case herbalLore = "herbal_lore"
}

public extension Player {
    func clearRPGTerminalUpkeeps() {
        _ = rpgClearTerminalUpkeeps(&rpg)
    }

    func rpgClassesEnabled() -> Bool {
        world.rule(RPG_CLASSES_GAME_RULE)
    }

    func restoreRPGFatigue(_ amount: Double, source: RPGFatigueRestorationSource,
                           perTickCap: Double) {
        guard amount > 0, amount.isFinite, perTickCap > 0, perTickCap.isFinite,
              rpgClassesEnabled(), rpg.created else { return }
        let tickKey = "rpg.fatigueRestoreTick.\(source.rawValue)"
        let amountKey = "rpg.fatigueRestoredThisTick.\(source.rawValue)"
        let storedTick = stats[tickKey]
        if storedTick == nil || !storedTick!.isFinite || storedTick! != Double(world.rpgSimulationTick) {
            stats[tickKey] = Double(world.rpgSimulationTick)
            stats[amountKey] = 0
        }
        let rawUsed = stats[amountKey] ?? 0
        let used = rawUsed.isFinite ? max(0, min(perTickCap, rawUsed)) : 0
        let granted = min(amount, max(0, perTickCap - used))
        guard granted > 0 else { return }
        stats[amountKey] = used + granted
        rpg.fatigue = min(rpgDerivedStats(rpg).maxFatigue, rpg.fatigue + granted)
    }

    private func advanceRPGDurabilityCounter(_ key: String) -> Int? {
        let raw = stats[key] ?? 0
        let current: Int
        if raw.isFinite, raw >= 0 {
            current = Int(min(Double(RPG_MAX_COUNTER), raw.rounded(.towardZero)))
        } else {
            current = 0
        }
        guard current < RPG_MAX_COUNTER else { return nil }
        let next = current + 1
        stats[key] = Double(next)
        return next
    }

    private func deterministicRPGLuckProc(tag: String, counter: Int) -> Bool {
        let chance = rpgDerivedStats(rpg).luckProcChance
        let counterBits = UInt32(truncatingIfNeeded: max(0, min(RPG_MAX_COUNTER, counter)))
        let mixed = mix32(world.seed ^ hashString(tag) ^ (counterBits &* 0x9e37_79b9))
        let roll = Double(mixed) / 4_294_967_296.0
        return roll < chance
    }

    func shouldPreserveRPGToolDurability() -> Bool {
        guard rpgClassesEnabled(), rpg.created else { return false }
        let interval = Int(rpgSkillEffectValue(.toolTune, in: rpg))
        guard let counter = advanceRPGDurabilityCounter("rpg.toolTuneCounter") else { return false }
        let cadenceHit = interval > 0 && counter % interval == 0
        let luckHit = deterministicRPGLuckProc(tag: "rpg.tool_tune", counter: counter)
        return cadenceHit || luckHit
    }

    func shouldPreserveRPGSalvageDurability() -> Bool {
        guard rpgClassesEnabled(), rpg.created else { return false }
        let interval = Int(rpgSkillEffectValue(.salvageEye, in: rpg))
        guard let counter = advanceRPGDurabilityCounter("rpg.salvageCounter") else { return false }
        let cadenceHit = interval > 0 && counter % interval == 0
        let luckHit = deterministicRPGLuckProc(tag: "rpg.salvage_eye", counter: counter)
        return cadenceHit || luckHit
    }

    func applyRPGDerivedStats() {
        guard rpgClassesEnabled() else {
            let oldMax = maxHealth
            maxHealth = RPGDerivedStats.vanilla.maxHealth
            if oldMax > 0, health > 0, health == oldMax {
                health = maxHealth
            } else {
                health = max(0, min(maxHealth, health))
            }
            return
        }
        rpg = repairRPGCharacterState(rpg)
        let derived = rpgDerivedStats(rpg)
        let oldMax = maxHealth
        maxHealth = derived.maxHealth
        if oldMax > 0, health > 0, health == oldMax {
            health = maxHealth
        } else {
            health = max(0, min(maxHealth, health))
        }
    }

    /// Advances only the clock-driven portion of RPG state. GameCore calls
    /// this exactly once per authoritative simulation step, even when normal
    /// player physics is temporarily skipped (chunk holds, template jobs, or
    /// death). LAN clients never call it speculatively.
    func tickRPGContinuousState() {
        guard rpgClassesEnabled() else {
            if maxHealth != 20 {
                maxHealth = 20
                health = min(health, maxHealth)
            }
            return
        }
        let endedUpkeeps = rpgTickState(&rpg)
        rpgCleanupEndedUpkeeps(self, endedUpkeeps)
        applyRPGDerivedStats()
    }

    /// Applies position/world-dependent RPG passives. This remains coupled to
    /// a real player tick so a held or dead player cannot discover chunks,
    /// trigger trails, or receive camp benefits from a clock-only step.
    func tickRPGGameplayState() {
        guard rpgClassesEnabled(), rpg.created else { return }
        rpgAwardReachedDepthMilestones(self)
        rpgAwardCurrentChunkDiscovery(self)
        rpgApplyTrailSense(self)
        if rpgSkillRank(.campcraft, in: rpg) > 0, rpgCampcraftSafeRest(self) {
            let maxFatigue = rpgDerivedStats(rpg).maxFatigue
            rpg.fatigue = min(maxFatigue, rpg.fatigue + rpgSkillEffectValue(.campcraft, in: rpg))
        }
        rpgTickPlayerUpkeepEffects(self)
        applyRPGDerivedStats()
    }

    func tickRPGState() {
        tickRPGContinuousState()
        tickRPGGameplayState()
    }

    @discardableResult
    func createRPGCharacter(_ draft: RPGCreationDraft) -> RPGCreationError? {
        guard rpgClassesEnabled() else { return .classesDisabled }
        rpg = repairRPGCharacterState(rpg)
        guard !rpg.created else { return .alreadyCreated }
        switch rpgCreateCharacter(draft) {
        case .success(var state):
            let stacks: [ItemStack]
            switch rpgStarterKitStacks(pathID: state.pathID) {
            case .success(let built): stacks = built
            case .failure(let error): return error
            }
            guard let grantedInventory = inventoryByAdding(stacks, to: inventory) else {
                return .insufficientInventoryForStarterKit
            }
            state.kitGrantVersion = RPG_STARTER_KIT_VERSION
            state.kitGrantID = rpgStarterKitGrantID(pathID: state.pathID, starterSkillID: state.starterSkillID)
            state = repairRPGCharacterState(state)
            inventory = grantedInventory
            rpg = state
            applyRPGDerivedStats()
            health = maxHealth
            return nil
        case .failure(let error):
            return error
        }
    }

    @discardableResult
    func awardRPGXP(_ event: RPGXPEvent) -> RPGProgressionReport {
        guard rpgClassesEnabled(), gameMode != GameMode.creative else {
            return RPGProgressionReport(leveledUp: false, previousLevel: rpg.level,
                                        newLevel: rpg.level)
        }
        let report = rpgAwardXPEvent(event, simulationTick: world.rpgSimulationTick,
                                     worldDay: max(0, world.rpgSimulationTick / 24_000), to: &rpg)
        if report.awardedXP > 0 { applyRPGDerivedStats() }
        return report
    }

}
