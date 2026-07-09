import Foundation

public let RPG_STATE_CURRENT_VERSION = 1
public let RPG_CLASSES_GAME_RULE = "rpgClasses"
public let RPG_LEVEL_CAP = 20
public let RPG_MAX_PREPARED_SPELLS = 8
public let RPG_MAX_PREPARED_SKILLS = 10
public let RPG_ACTION_QUICK_SLOT_COUNT = 9

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

public enum RPGActionKind: String, Codable {
    case passive
    case active
    case spell
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
    guard parts.count == 2, let kind = RPGPreparedActionKind(rawValue: parts[0]), !parts[1].isEmpty else {
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
    public var summary: String
    public var kind: RPGActionKind
    public var maxRank: Int
    public var minimumLevel: Int
    public var requirements: [RPGAttributeRequirement]
    public var prerequisiteSkillIDs: [String]
    public var unlockSpellIDs: [String]
    public var cooldownTicks: Int
    public var fatigueCost: Double

    public init(id: String, pathID: String, branchID: String, displayName: String, summary: String,
                kind: RPGActionKind = .passive, maxRank: Int = 1, minimumLevel: Int = 1,
                requirements: [RPGAttributeRequirement] = [], prerequisiteSkillIDs: [String] = [],
                unlockSpellIDs: [String] = [], cooldownTicks: Int = 0, fatigueCost: Double = 0) {
        self.id = id
        self.pathID = pathID
        self.branchID = branchID
        self.displayName = displayName
        self.summary = summary
        self.kind = kind
        self.maxRank = max(1, maxRank)
        self.minimumLevel = max(1, minimumLevel)
        self.requirements = requirements
        self.prerequisiteSkillIDs = prerequisiteSkillIDs
        self.unlockSpellIDs = unlockSpellIDs
        self.cooldownTicks = max(0, cooldownTicks)
        self.fatigueCost = max(0, fatigueCost)
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
    public var id: String
    public var remainingTicks: Int

    public init(id: String, remainingTicks: Int) {
        self.id = id
        self.remainingTicks = max(0, remainingTicks)
    }
}

public struct RPGUpkeep: Codable, Equatable {
    public var spellID: String
    public var ownerSequence: Int
    public var remainingTicks: Int
    public var costPerSecond: Double

    public init(spellID: String, ownerSequence: Int, remainingTicks: Int, costPerSecond: Double) {
        self.spellID = spellID
        self.ownerSequence = max(0, ownerSequence)
        self.remainingTicks = max(0, remainingTicks)
        self.costPerSecond = max(0, costPerSecond)
    }
}

public struct RPGCharacterState: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case version
        case created
        case pathID
        case attributes
        case xp
        case level
        case skillRanks
        case preparedSkillIDs
        case knownSpellIDs
        case preparedSpellIDs
        case selectedPreparedSpellID
        case selectedPreparedActionID
        case actionQuickSlots
        case fatigue
        case actionSequence
        case activeCooldowns
        case activeUpkeeps
    }

    public var version: Int
    public var created: Bool
    public var pathID: String
    public var attributes: RPGAttributes
    public var xp: Int
    public var level: Int
    public var skillRanks: [String: Int]
    public var preparedSkillIDs: [String]
    public var knownSpellIDs: [String]
    public var preparedSpellIDs: [String]
    public var selectedPreparedSpellID: String?
    public var selectedPreparedActionID: String?
    public var actionQuickSlots: [String?]
    public var fatigue: Double
    public var actionSequence: Int
    public var activeCooldowns: [RPGCooldown]
    public var activeUpkeeps: [RPGUpkeep]

    public init(version: Int = RPG_STATE_CURRENT_VERSION,
                created: Bool,
                pathID: String,
                attributes: RPGAttributes,
                xp: Int,
                level: Int,
                skillRanks: [String: Int],
                preparedSkillIDs: [String],
                knownSpellIDs: [String],
                preparedSpellIDs: [String],
                selectedPreparedSpellID: String? = nil,
                selectedPreparedActionID: String? = nil,
                actionQuickSlots: [String?] = [],
                fatigue: Double,
                actionSequence: Int = 0,
                activeCooldowns: [RPGCooldown] = [],
                activeUpkeeps: [RPGUpkeep] = []) {
        self.version = version
        self.created = created
        self.pathID = pathID
        self.attributes = attributes
        self.xp = xp
        self.level = level
        self.skillRanks = skillRanks
        self.preparedSkillIDs = preparedSkillIDs
        self.knownSpellIDs = knownSpellIDs
        self.preparedSpellIDs = preparedSpellIDs
        self.selectedPreparedSpellID = selectedPreparedSpellID
        self.selectedPreparedActionID = selectedPreparedActionID
        self.actionQuickSlots = actionQuickSlots
        self.fatigue = fatigue
        self.actionSequence = actionSequence
        self.activeCooldowns = activeCooldowns
        self.activeUpkeeps = activeUpkeeps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try c.decodeIfPresent(Int.self, forKey: .version) ?? RPG_STATE_CURRENT_VERSION,
            created: try c.decodeIfPresent(Bool.self, forKey: .created) ?? false,
            pathID: try c.decodeIfPresent(String.self, forKey: .pathID) ?? "",
            attributes: try c.decodeIfPresent(RPGAttributes.self, forKey: .attributes) ?? .defaultCreation,
            xp: try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0,
            level: try c.decodeIfPresent(Int.self, forKey: .level) ?? 0,
            skillRanks: try c.decodeIfPresent([String: Int].self, forKey: .skillRanks) ?? [:],
            preparedSkillIDs: try c.decodeIfPresent([String].self, forKey: .preparedSkillIDs) ?? [],
            knownSpellIDs: try c.decodeIfPresent([String].self, forKey: .knownSpellIDs) ?? [],
            preparedSpellIDs: try c.decodeIfPresent([String].self, forKey: .preparedSpellIDs) ?? [],
            selectedPreparedSpellID: try c.decodeIfPresent(String.self, forKey: .selectedPreparedSpellID),
            selectedPreparedActionID: try c.decodeIfPresent(String.self, forKey: .selectedPreparedActionID),
            actionQuickSlots: try c.decodeIfPresent([String?].self, forKey: .actionQuickSlots) ?? [],
            fatigue: try c.decodeIfPresent(Double.self, forKey: .fatigue) ?? 0,
            actionSequence: try c.decodeIfPresent(Int.self, forKey: .actionSequence) ?? 0,
            activeCooldowns: try c.decodeIfPresent([RPGCooldown].self, forKey: .activeCooldowns) ?? [],
            activeUpkeeps: try c.decodeIfPresent([RPGUpkeep].self, forKey: .activeUpkeeps) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(created, forKey: .created)
        try c.encode(pathID, forKey: .pathID)
        try c.encode(attributes, forKey: .attributes)
        try c.encode(xp, forKey: .xp)
        try c.encode(level, forKey: .level)
        try c.encode(skillRanks, forKey: .skillRanks)
        try c.encode(preparedSkillIDs, forKey: .preparedSkillIDs)
        try c.encode(knownSpellIDs, forKey: .knownSpellIDs)
        try c.encode(preparedSpellIDs, forKey: .preparedSpellIDs)
        try c.encodeIfPresent(selectedPreparedSpellID, forKey: .selectedPreparedSpellID)
        try c.encodeIfPresent(selectedPreparedActionID, forKey: .selectedPreparedActionID)
        try c.encode(actionQuickSlots, forKey: .actionQuickSlots)
        try c.encode(fatigue, forKey: .fatigue)
        try c.encode(actionSequence, forKey: .actionSequence)
        try c.encode(activeCooldowns, forKey: .activeCooldowns)
        try c.encode(activeUpkeeps, forKey: .activeUpkeeps)
    }

    public static func uncreated() -> RPGCharacterState {
        RPGCharacterState(created: false, pathID: "", attributes: .defaultCreation, xp: 0, level: 0,
                          skillRanks: [:], preparedSkillIDs: [], knownSpellIDs: [], preparedSpellIDs: [],
                          selectedPreparedSpellID: nil,
                          selectedPreparedActionID: nil,
                          actionQuickSlots: Array(repeating: nil, count: RPG_ACTION_QUICK_SLOT_COUNT),
                          fatigue: 0)
    }
}

public struct RPGDerivedStats: Equatable {
    public var maxHealth: Double
    public var maxFatigue: Double
    public var fatigueRegenPerTick: Double
    public var meleeDamageBonus: Double
    public var actionAccuracyBonus: Double
    public var spellFailureMitigation: Double
    public var carryBonusSlots: Int

    public init(maxHealth: Double, maxFatigue: Double, fatigueRegenPerTick: Double,
                meleeDamageBonus: Double, actionAccuracyBonus: Double,
                spellFailureMitigation: Double, carryBonusSlots: Int) {
        self.maxHealth = maxHealth
        self.maxFatigue = maxFatigue
        self.fatigueRegenPerTick = fatigueRegenPerTick
        self.meleeDamageBonus = meleeDamageBonus
        self.actionAccuracyBonus = actionAccuracyBonus
        self.spellFailureMitigation = spellFailureMitigation
        self.carryBonusSlots = carryBonusSlots
    }

    public static let vanilla = RPGDerivedStats(maxHealth: 20, maxFatigue: 0, fatigueRegenPerTick: 0,
                                                meleeDamageBonus: 0, actionAccuracyBonus: 0,
                                                spellFailureMitigation: 0, carryBonusSlots: 0)
}

public struct RPGCreationDraft: Codable, Equatable {
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
}

public extension GameCore {
    @discardableResult
    func requestRPGCreateCharacter(_ draft: RPGCreationDraft) -> String {
        guard let player else { return "No player" }
        if let error = player.createRPGCharacter(draft) {
            return error.description
        }
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .createCharacter, draft: draft, actionSequence: player.rpg.actionSequence))
        }
        return "Created \(rpgPathDefinition(player.rpg.pathID)?.displayName ?? "character")"
    }

    @discardableResult
    func requestRPGLearnSkill(_ skillID: String) -> String {
        guard let player else { return "No player" }
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
        guard let player else { return "No player" }
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
        guard let player else { return "No player" }
        if player.rpg.preparedSpellIDs.contains(spellID) {
            if let error = rpgUnprepareSpell(spellID, in: &player.rpg) {
                return error.description
            }
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
        guard let player else { return "No player" }
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
        guard let player else { return "No player" }
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
        guard let player else { return "No player" }
        if let error = rpgAssignPreparedActionToQuickSlot(kind: kind, id: id, slot: slot, in: &player.rpg) {
            return error.description
        }
        let name: String
        switch kind {
        case .skill: name = rpgSkillDefinition(id)?.displayName ?? id
        case .spell: name = rpgSpellDefinition(id)?.displayName ?? id
        }
        return "Slot \(slot + 1): \(name)"
    }

    @discardableResult
    func requestRPGClearActionQuickSlot(_ slot: Int) -> String {
        guard let player else { return "No player" }
        rpgClearActionQuickSlot(slot, in: &player.rpg)
        return "Cleared slot \(slot + 1)"
    }

    @discardableResult
    func requestRPGSpendAttributePoint(_ attribute: RPGAttributeID) -> String {
        guard let player else { return "No player" }
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
        guard let player else { return "No player" }
        guard let spellID = rpgCyclePreparedSpell(player, direction: direction) else {
            return "No prepared spells"
        }
        if isLANClientWorld {
            lanRPGIntentHandler?(LANRPGIntent(action: .selectSpell, spellID: spellID, direction: direction, actionSequence: player.rpg.actionSequence))
        }
        return "Selected \(rpgSpellDefinition(spellID)?.displayName ?? spellID)"
    }

    @discardableResult
    func requestRPGCyclePreparedAction(direction: Int = 1) -> String {
        guard let player else { return "No player" }
        guard let action = rpgCyclePreparedAction(player, direction: direction) else {
            return "No prepared actions"
        }
        if isLANClientWorld {
            switch action.kind {
            case .skill:
                lanRPGIntentHandler?(LANRPGIntent(action: .selectSkill, skillID: action.id, direction: direction, actionSequence: player.rpg.actionSequence))
            case .spell:
                lanRPGIntentHandler?(LANRPGIntent(action: .selectSpell, spellID: action.id, direction: direction, actionSequence: player.rpg.actionSequence))
            }
        }
        return "Selected \(action.displayName)"
    }

    @discardableResult
    func requestRPGCastSelectedSpell() -> String {
        guard let player else { return "No player" }
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
            lanRPGIntentHandler?(LANRPGIntent(action: .castSpell, spellID: spellID, actionSequence: player.rpg.actionSequence + 1))
            return "Casting \(spell.displayName)"
        }
        switch rpgCastPreparedSpell(player, spellID: spellID) {
        case .success(let result): return result.message
        case .failure(let error): return error.description
        }
    }

    @discardableResult
    func requestRPGUseSelectedAction() -> String {
        guard let player else { return "No player" }
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
            switch action.kind {
            case .skill:
                lanRPGIntentHandler?(LANRPGIntent(action: .useSkill, skillID: action.id, actionSequence: player.rpg.actionSequence + 1))
            case .spell:
                lanRPGIntentHandler?(LANRPGIntent(action: .castSpell, spellID: action.id, actionSequence: player.rpg.actionSequence + 1))
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
        guard let player else { return "No player" }
        player.rpg = repairRPGCharacterState(player.rpg)
        guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else {
            return RPGActionFailure.actionNotPrepared.description
        }
        let actions = rpgActionQuickSlotActions(player.rpg)
        guard slot < actions.count, let action = actions[slot] else {
            return "RPG slot \(slot + 1) is empty"
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
            player.rpg.selectedPreparedActionID = action.token
            if action.kind == .spell {
                player.rpg.selectedPreparedSpellID = action.id
            }
            switch action.kind {
            case .skill:
                lanRPGIntentHandler?(LANRPGIntent(action: .useSkill, skillID: action.id, actionSequence: player.rpg.actionSequence + 1))
            case .spell:
                lanRPGIntentHandler?(LANRPGIntent(action: .castSpell, spellID: action.id, actionSequence: player.rpg.actionSequence + 1))
            }
            return "Using slot \(slot + 1): \(action.displayName)"
        }
        switch rpgUseActionQuickSlot(player, slot: slot) {
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

public enum RPGCreationError: Error, Equatable, CustomStringConvertible {
    case unknownPath(String)
    case invalidAttributeBudget(total: Int, expected: Int)
    case invalidAttributeValue(RPGAttributeID, Int)
    case invalidStarterSkill(String)
    case invalidStarterSpell(String)

    public var description: String {
        switch self {
        case .unknownPath(let id): return "Unknown path: \(id)"
        case .invalidAttributeBudget(let total, let expected): return "Attribute total \(total) does not match \(expected)"
        case .invalidAttributeValue(let id, let value): return "\(id.rawValue) value \(value) is out of creation range"
        case .invalidStarterSkill(let id): return "Invalid starter skill: \(id)"
        case .invalidStarterSpell(let id): return "Invalid starter spell: \(id)"
        }
    }
}

public struct RPGProgressionReport: Equatable {
    public var leveledUp: Bool
    public var previousLevel: Int
    public var newLevel: Int

    public init(leveledUp: Bool, previousLevel: Int, newLevel: Int) {
        self.leveledUp = leveledUp
        self.previousLevel = previousLevel
        self.newLevel = newLevel
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
    case preparedSpellLimit
    case preparedSkillLimit

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
        case .preparedSpellLimit: return "Prepared spell limit reached"
        case .preparedSkillLimit: return "Prepared skill limit reached"
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
        primaryAttributes: [.dexterity, .intelligence],
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
                       summary: "Gain extra guard while standing still with a shield.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.strength, 8)]),
    RPGSkillDefinition(id: "interpose", pathID: "warden", branchID: "warden_guardian", displayName: "Interpose",
                       summary: "Spend fatigue to reduce nearby ally damage.", kind: .active, maxRank: 2, minimumLevel: 3,
                       requirements: [RPGAttributeRequirement(.endurance, 9)], prerequisiteSkillIDs: ["guard_stance"],
                       cooldownTicks: 100, fatigueCost: 3),
    RPGSkillDefinition(id: "anchor_line", pathID: "warden", branchID: "warden_guardian", displayName: "Anchor Line",
                       summary: "Resist knockback and pull an ally toward cover.", kind: .active, minimumLevel: 6,
                       prerequisiteSkillIDs: ["interpose"], cooldownTicks: 180, fatigueCost: 4),
    RPGSkillDefinition(id: "heavy_cut", pathID: "warden", branchID: "warden_vanguard", displayName: "Heavy Cut",
                       summary: "A slower melee strike with a strength-scaled damage bonus.", kind: .active, maxRank: 3,
                       requirements: [RPGAttributeRequirement(.strength, 9)], cooldownTicks: 60, fatigueCost: 2),
    RPGSkillDefinition(id: "charge_break", pathID: "warden", branchID: "warden_vanguard", displayName: "Charge Break",
                       summary: "Short rush that interrupts unshielded enemies.", kind: .active, minimumLevel: 4,
                       prerequisiteSkillIDs: ["heavy_cut"], cooldownTicks: 140, fatigueCost: 4),
    RPGSkillDefinition(id: "stagger_chain", pathID: "warden", branchID: "warden_vanguard", displayName: "Stagger Chain",
                       summary: "Repeated heavy hits extend stagger windows.", maxRank: 2, minimumLevel: 8,
                       prerequisiteSkillIDs: ["charge_break"]),
    RPGSkillDefinition(id: "shield_bind", pathID: "warden", branchID: "warden_bulwark", displayName: "Shield Bind",
                       summary: "Shield blocks convert a little damage into fatigue.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.endurance, 8)]),
    RPGSkillDefinition(id: "plate_training", pathID: "warden", branchID: "warden_bulwark", displayName: "Plate Training",
                       summary: "Reduce armor fatigue penalties.", maxRank: 3, minimumLevel: 3,
                       prerequisiteSkillIDs: ["shield_bind"]),
    RPGSkillDefinition(id: "fortify_block", pathID: "warden", branchID: "warden_bulwark", displayName: "Fortify Block",
                       summary: "Temporarily harden a placed block against explosions.", kind: .active, minimumLevel: 7,
                       prerequisiteSkillIDs: ["plate_training"], cooldownTicks: 240, fatigueCost: 5),

    RPGSkillDefinition(id: "quick_draw", pathID: "ranger", branchID: "ranger_marksman", displayName: "Quick Draw",
                       summary: "Faster bow readiness after weapon swap.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.dexterity, 9)]),
    RPGSkillDefinition(id: "steady_aim", pathID: "ranger", branchID: "ranger_marksman", displayName: "Steady Aim",
                       summary: "Standing still narrows ranged spread.", maxRank: 3, minimumLevel: 3,
                       prerequisiteSkillIDs: ["quick_draw"]),
    RPGSkillDefinition(id: "crippling_shot", pathID: "ranger", branchID: "ranger_marksman", displayName: "Crippling Shot",
                       summary: "Spend fatigue to slow a damaged target.", kind: .active, minimumLevel: 6,
                       prerequisiteSkillIDs: ["steady_aim"], cooldownTicks: 160, fatigueCost: 4),
    RPGSkillDefinition(id: "trail_sense", pathID: "ranger", branchID: "ranger_scout", displayName: "Trail Sense",
                       summary: "Read recent hostile movement in a small radius.", maxRank: 2,
                       requirements: [RPGAttributeRequirement(.luck, 7)]),
    RPGSkillDefinition(id: "soft_step", pathID: "ranger", branchID: "ranger_scout", displayName: "Soft Step",
                       summary: "Sneaking and landing make less noise.", maxRank: 3, minimumLevel: 3,
                       prerequisiteSkillIDs: ["trail_sense"]),
    RPGSkillDefinition(id: "far_sight", pathID: "ranger", branchID: "ranger_scout", displayName: "Far Sight",
                       summary: "Mark distant features on the map overlay.", kind: .active, minimumLevel: 7,
                       prerequisiteSkillIDs: ["soft_step"], cooldownTicks: 220, fatigueCost: 3),
    RPGSkillDefinition(id: "campcraft", pathID: "ranger", branchID: "ranger_survivalist", displayName: "Campcraft",
                       summary: "Resting outdoors recovers fatigue faster.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.endurance, 8)]),
    RPGSkillDefinition(id: "weather_eye", pathID: "ranger", branchID: "ranger_survivalist", displayName: "Weather Eye",
                       summary: "Predict rain and storms from the HUD.", minimumLevel: 3,
                       prerequisiteSkillIDs: ["campcraft"]),
    RPGSkillDefinition(id: "beast_kinship", pathID: "ranger", branchID: "ranger_survivalist", displayName: "Beast Kinship",
                       summary: "Animals panic less often around you.", maxRank: 2, minimumLevel: 6,
                       prerequisiteSkillIDs: ["weather_eye"]),

    RPGSkillDefinition(id: "vein_reader", pathID: "delver", branchID: "delver_miner", displayName: "Vein Reader",
                       summary: "Ore-bearing stone occasionally gives a directional hint.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.intelligence, 8)]),
    RPGSkillDefinition(id: "fast_bore", pathID: "delver", branchID: "delver_miner", displayName: "Fast Bore",
                       summary: "Spend fatigue for a short mining speed burst.", kind: .active, maxRank: 3, minimumLevel: 3,
                       prerequisiteSkillIDs: ["vein_reader"], cooldownTicks: 120, fatigueCost: 3),
    RPGSkillDefinition(id: "deep_reserves", pathID: "delver", branchID: "delver_miner", displayName: "Deep Reserves",
                       summary: "Recover fatigue from breaking hard stone below sea level.", minimumLevel: 8,
                       prerequisiteSkillIDs: ["fast_bore"]),
    RPGSkillDefinition(id: "trap_probe", pathID: "delver", branchID: "delver_trapper", displayName: "Trap Probe",
                       summary: "Detect nearby tripwires, pressure plates, and dispensers.", kind: .active,
                       requirements: [RPGAttributeRequirement(.dexterity, 8)], cooldownTicks: 80, fatigueCost: 2),
    RPGSkillDefinition(id: "tripwire_mind", pathID: "delver", branchID: "delver_trapper", displayName: "Tripwire Mind",
                       summary: "Disarming redstone traps is safer and quieter.", maxRank: 2, minimumLevel: 3,
                       prerequisiteSkillIDs: ["trap_probe"]),
    RPGSkillDefinition(id: "deadfall", pathID: "delver", branchID: "delver_trapper", displayName: "Deadfall",
                       summary: "Build a temporary block trap from carried materials.", kind: .active, minimumLevel: 7,
                       prerequisiteSkillIDs: ["tripwire_mind"], cooldownTicks: 240, fatigueCost: 5),
    RPGSkillDefinition(id: "salvage_eye", pathID: "delver", branchID: "delver_treasure", displayName: "Salvage Eye",
                       summary: "Recover extra materials from broken crafted blocks.", maxRank: 2,
                       requirements: [RPGAttributeRequirement(.luck, 7)]),
    RPGSkillDefinition(id: "lock_touch", pathID: "delver", branchID: "delver_treasure", displayName: "Lock Touch",
                       summary: "Open sealed dungeon containers after a timed check.", kind: .active, minimumLevel: 4,
                       prerequisiteSkillIDs: ["salvage_eye"], cooldownTicks: 200, fatigueCost: 4),
    RPGSkillDefinition(id: "fortune_read", pathID: "delver", branchID: "delver_treasure", displayName: "Fortune Read",
                       summary: "A luck-weighted preview of a risky container.", kind: .active, minimumLevel: 8,
                       prerequisiteSkillIDs: ["lock_touch"], cooldownTicks: 400, fatigueCost: 6),

    RPGSkillDefinition(id: "spell_formula", pathID: "arcanist", branchID: "arcanist_elementalist", displayName: "Spell Formula",
                       summary: "Prepare and cast circle-one elemental spells.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.intelligence, 9)], unlockSpellIDs: ["ignite", "frost_ray"]),
    RPGSkillDefinition(id: "spark_weave", pathID: "arcanist", branchID: "arcanist_elementalist", displayName: "Spark Weave",
                       summary: "Elemental damage spells cost less fatigue.", maxRank: 2, minimumLevel: 4,
                       prerequisiteSkillIDs: ["spell_formula"], unlockSpellIDs: ["shock"]),
    RPGSkillDefinition(id: "storm_focus", pathID: "arcanist", branchID: "arcanist_elementalist", displayName: "Storm Focus",
                       summary: "Maintain a short-range storm aura.", kind: .spell, minimumLevel: 8,
                       prerequisiteSkillIDs: ["spark_weave"], unlockSpellIDs: ["storm_aura"]),
    RPGSkillDefinition(id: "minor_glamour", pathID: "arcanist", branchID: "arcanist_illusionist", displayName: "Minor Glamour",
                       summary: "Prepare and cast blur and decoy illusions.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.intelligence, 9)], unlockSpellIDs: ["blur", "decoy"]),
    RPGSkillDefinition(id: "false_step", pathID: "arcanist", branchID: "arcanist_illusionist", displayName: "False Step",
                       summary: "Illusions last longer when cast while sneaking.", maxRank: 2, minimumLevel: 4,
                       prerequisiteSkillIDs: ["minor_glamour"], unlockSpellIDs: ["shadow_step"]),
    RPGSkillDefinition(id: "mirror_work", pathID: "arcanist", branchID: "arcanist_illusionist", displayName: "Mirror Work",
                       summary: "Create multiple fragile images.", kind: .spell, minimumLevel: 8,
                       prerequisiteSkillIDs: ["false_step"], unlockSpellIDs: ["mirror_image"]),
    RPGSkillDefinition(id: "ritual_circle", pathID: "arcanist", branchID: "arcanist_ritualist", displayName: "Ritual Circle",
                       summary: "Prepare utility rituals and longer upkeep spells.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.endurance, 8)], unlockSpellIDs: ["mage_light", "ward"]),
    RPGSkillDefinition(id: "bound_servant", pathID: "arcanist", branchID: "arcanist_ritualist", displayName: "Bound Servant",
                       summary: "Summon a short-lived helper entity.", kind: .spell, minimumLevel: 5,
                       prerequisiteSkillIDs: ["ritual_circle"], unlockSpellIDs: ["summon_servant"]),
    RPGSkillDefinition(id: "ward_scribe", pathID: "arcanist", branchID: "arcanist_ritualist", displayName: "Ward Scribe",
                       summary: "Place persistent but bounded ward marks.", kind: .spell, minimumLevel: 8,
                       prerequisiteSkillIDs: ["bound_servant"], unlockSpellIDs: ["stone_ward"]),

    RPGSkillDefinition(id: "field_dressing", pathID: "mender", branchID: "mender_physic", displayName: "Field Dressing",
                       summary: "Bandage recent damage and stabilize allies.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.intelligence, 8)], unlockSpellIDs: ["mend_wounds"]),
    RPGSkillDefinition(id: "triage", pathID: "mender", branchID: "mender_physic", displayName: "Triage",
                       summary: "Healing is stronger on low-health targets.", maxRank: 2, minimumLevel: 4,
                       prerequisiteSkillIDs: ["field_dressing"], unlockSpellIDs: ["restore"]),
    RPGSkillDefinition(id: "second_breath", pathID: "mender", branchID: "mender_physic", displayName: "Second Breath",
                       summary: "Convert fatigue into emergency health once per cooldown.", kind: .active, minimumLevel: 8,
                       prerequisiteSkillIDs: ["triage"], cooldownTicks: 600, fatigueCost: 6),
    RPGSkillDefinition(id: "herbal_lore", pathID: "mender", branchID: "mender_harvest", displayName: "Herbal Lore",
                       summary: "Gather extra medicine from selected plants.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.luck, 7)], unlockSpellIDs: ["purify"]),
    RPGSkillDefinition(id: "clean_brew", pathID: "mender", branchID: "mender_harvest", displayName: "Clean Brew",
                       summary: "Potion and food effects are more reliable.", maxRank: 2, minimumLevel: 4,
                       prerequisiteSkillIDs: ["herbal_lore"]),
    RPGSkillDefinition(id: "green_thumb", pathID: "mender", branchID: "mender_harvest", displayName: "Green Thumb",
                       summary: "Nearby crops recover from bad weather faster.", minimumLevel: 7,
                       prerequisiteSkillIDs: ["clean_brew"]),
    RPGSkillDefinition(id: "safe_haven", pathID: "mender", branchID: "mender_sanctuary", displayName: "Safe Haven",
                       summary: "Create a short rest point that accelerates fatigue recovery.", kind: .active,
                       requirements: [RPGAttributeRequirement(.endurance, 8)], unlockSpellIDs: ["ward"],
                       cooldownTicks: 400, fatigueCost: 4),
    RPGSkillDefinition(id: "protective_mark", pathID: "mender", branchID: "mender_sanctuary", displayName: "Protective Mark",
                       summary: "Wards absorb a small fixed amount of incoming damage.", maxRank: 2, minimumLevel: 5,
                       prerequisiteSkillIDs: ["safe_haven"], unlockSpellIDs: ["aegis"]),
    RPGSkillDefinition(id: "sanctuary_bell", pathID: "mender", branchID: "mender_sanctuary", displayName: "Sanctuary Bell",
                       summary: "Briefly repel hostile mobs from a prepared place.", kind: .spell, minimumLevel: 9,
                       prerequisiteSkillIDs: ["protective_mark"], unlockSpellIDs: ["sanctuary"]),

    RPGSkillDefinition(id: "circuit_sense", pathID: "tinker", branchID: "tinker_redstone", displayName: "Circuit Sense",
                       summary: "Inspect redstone strength and timing at a glance.", maxRank: 3,
                       requirements: [RPGAttributeRequirement(.intelligence, 8)]),
    RPGSkillDefinition(id: "compact_gate", pathID: "tinker", branchID: "tinker_redstone", displayName: "Compact Gate",
                       summary: "Build small logic devices with fewer materials.", maxRank: 2, minimumLevel: 4,
                       prerequisiteSkillIDs: ["circuit_sense"]),
    RPGSkillDefinition(id: "remote_trigger", pathID: "tinker", branchID: "tinker_redstone", displayName: "Remote Trigger",
                       summary: "Trigger a bound redstone device from short range.", kind: .active, minimumLevel: 8,
                       prerequisiteSkillIDs: ["compact_gate"], cooldownTicks: 180, fatigueCost: 3),
    RPGSkillDefinition(id: "field_mod", pathID: "tinker", branchID: "tinker_artificer", displayName: "Field Mod",
                       summary: "Temporarily tune held tools for a focused task.", kind: .active, maxRank: 3,
                       requirements: [RPGAttributeRequirement(.dexterity, 8)], cooldownTicks: 180, fatigueCost: 3),
    RPGSkillDefinition(id: "quick_repair", pathID: "tinker", branchID: "tinker_artificer", displayName: "Quick Repair",
                       summary: "Repair gear with carried materials outside an anvil.", kind: .active, minimumLevel: 4,
                       prerequisiteSkillIDs: ["field_mod"], cooldownTicks: 220, fatigueCost: 4),
    RPGSkillDefinition(id: "tool_tune", pathID: "tinker", branchID: "tinker_artificer", displayName: "Tool Tune",
                       summary: "A prepared tool keeps a small efficiency bonus.", maxRank: 2, minimumLevel: 7,
                       prerequisiteSkillIDs: ["quick_repair"]),
    RPGSkillDefinition(id: "charge_pack", pathID: "tinker", branchID: "tinker_sapper", displayName: "Charge Pack",
                       summary: "Create controlled demolition charges from TNT.", kind: .active,
                       requirements: [RPGAttributeRequirement(.intelligence, 8)], cooldownTicks: 240, fatigueCost: 5),
    RPGSkillDefinition(id: "blast_shape", pathID: "tinker", branchID: "tinker_sapper", displayName: "Blast Shape",
                       summary: "Reduce collateral block damage from controlled blasts.", maxRank: 2, minimumLevel: 5,
                       prerequisiteSkillIDs: ["charge_pack"]),
    RPGSkillDefinition(id: "safe_fuse", pathID: "tinker", branchID: "tinker_sapper", displayName: "Safe Fuse",
                       summary: "Cancel a placed charge before detonation.", kind: .active, minimumLevel: 7,
                       prerequisiteSkillIDs: ["blast_shape"], cooldownTicks: 120, fatigueCost: 2),
]

public let RPG_SPELL_DEFINITIONS: [RPGSpellDefinition] = [
    RPGSpellDefinition(id: "ignite", displayName: "Ignite",
                       summary: "Set a target block face or hostile mob alight.",
                       circle: 1, categories: [.damage, .utility], targetKind: .ray, rangeBlocks: 12,
                       fatigueCost: 2, minimumIntelligence: 9, prerequisiteSkillIDs: ["spell_formula"],
                       actionSequenceWindow: 12),
    RPGSpellDefinition(id: "frost_ray", displayName: "Frost Ray",
                       summary: "Deal light damage and briefly slow a target.",
                       circle: 1, categories: [.damage, .control], targetKind: .ray, rangeBlocks: 14,
                       durationTicks: 80, fatigueCost: 3, minimumIntelligence: 9,
                       prerequisiteSkillIDs: ["spell_formula"], actionSequenceWindow: 12),
    RPGSpellDefinition(id: "shock", displayName: "Shock",
                       summary: "A fast bolt that chains once through wet targets.",
                       circle: 2, categories: [.damage], targetKind: .ray, rangeBlocks: 16,
                       fatigueCost: 4, minimumIntelligence: 11, prerequisiteSkillIDs: ["spark_weave"],
                       actionSequenceWindow: 10),
    RPGSpellDefinition(id: "storm_aura", displayName: "Storm Aura",
                       summary: "Maintain a short-range damage aura at high fatigue cost.",
                       circle: 3, categories: [.damage, .control], targetKind: .selfTarget, rangeBlocks: 0,
                       radiusBlocks: 4, durationTicks: 300, fatigueCost: 6, upkeepCostPerSecond: 1,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["storm_focus"]),
    RPGSpellDefinition(id: "blur", displayName: "Blur",
                       summary: "Reduce incoming ranged accuracy for a short time.",
                       circle: 1, categories: [.defense, .illusion], targetKind: .selfTarget, rangeBlocks: 0,
                       durationTicks: 240, fatigueCost: 2, upkeepCostPerSecond: 0.25,
                       minimumIntelligence: 9, prerequisiteSkillIDs: ["minor_glamour"]),
    RPGSpellDefinition(id: "decoy", displayName: "Decoy",
                       summary: "Create a fragile illusion that draws hostile attention.",
                       circle: 1, categories: [.illusion, .control], targetKind: .placed, rangeBlocks: 8,
                       durationTicks: 200, fatigueCost: 3, minimumIntelligence: 9,
                       prerequisiteSkillIDs: ["minor_glamour"]),
    RPGSpellDefinition(id: "shadow_step", displayName: "Shadow Step",
                       summary: "Short teleport to a visible dark block.",
                       circle: 2, categories: [.movement, .illusion], targetKind: .ray, rangeBlocks: 10,
                       fatigueCost: 5, minimumIntelligence: 11, prerequisiteSkillIDs: ["false_step"],
                       actionSequenceWindow: 8),
    RPGSpellDefinition(id: "mirror_image", displayName: "Mirror Image",
                       summary: "Create several weak images around the caster.",
                       circle: 3, categories: [.illusion, .defense], targetKind: .selfTarget, rangeBlocks: 0,
                       radiusBlocks: 3, durationTicks: 260, fatigueCost: 6, upkeepCostPerSecond: 0.5,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["mirror_work"]),
    RPGSpellDefinition(id: "mage_light", displayName: "Mage Light",
                       summary: "Place temporary light without consuming torches.",
                       circle: 1, categories: [.utility, .creation], targetKind: .placed, rangeBlocks: 12,
                       durationTicks: 1200, fatigueCost: 2, minimumIntelligence: 8,
                       prerequisiteSkillIDs: ["ritual_circle"]),
    RPGSpellDefinition(id: "ward", displayName: "Ward",
                       summary: "A small protective mark that absorbs one hit.",
                       circle: 1, categories: [.defense], targetKind: .placed, rangeBlocks: 6,
                       durationTicks: 600, fatigueCost: 3, minimumIntelligence: 8,
                       prerequisiteSkillIDs: ["ritual_circle"]),
    RPGSpellDefinition(id: "summon_servant", displayName: "Summon Servant",
                       summary: "Create a bounded helper for hauling or distraction.",
                       circle: 2, categories: [.creation, .utility], targetKind: .summon, rangeBlocks: 4,
                       durationTicks: 600, fatigueCost: 6, upkeepCostPerSecond: 0.5,
                       minimumIntelligence: 11, prerequisiteSkillIDs: ["bound_servant"],
                       actionSequenceWindow: 20),
    RPGSpellDefinition(id: "stone_ward", displayName: "Stone Ward",
                       summary: "Temporarily strengthen a small block area.",
                       circle: 3, categories: [.defense, .creation], targetKind: .area, rangeBlocks: 8,
                       radiusBlocks: 2, durationTicks: 1200, fatigueCost: 7,
                       minimumIntelligence: 13, prerequisiteSkillIDs: ["ward_scribe"]),
    RPGSpellDefinition(id: "mend_wounds", displayName: "Mend Wounds",
                       summary: "Restore a small amount of health to self or touched ally.",
                       circle: 1, categories: [.healing], targetKind: .touch, rangeBlocks: 2,
                       fatigueCost: 3, minimumIntelligence: 8, prerequisiteSkillIDs: ["field_dressing"]),
    RPGSpellDefinition(id: "restore", displayName: "Restore",
                       summary: "Heal and clear one minor negative effect.",
                       circle: 2, categories: [.healing], targetKind: .touch, rangeBlocks: 2,
                       fatigueCost: 5, minimumIntelligence: 11, prerequisiteSkillIDs: ["triage"]),
    RPGSpellDefinition(id: "purify", displayName: "Purify",
                       summary: "Clean poison and make suspect food safe.",
                       circle: 1, categories: [.healing, .utility], targetKind: .touch, rangeBlocks: 2,
                       fatigueCost: 2, minimumIntelligence: 8, prerequisiteSkillIDs: ["herbal_lore"]),
    RPGSpellDefinition(id: "aegis", displayName: "Aegis",
                       summary: "Give a touched target a brief protective barrier.",
                       circle: 2, categories: [.defense, .healing], targetKind: .touch, rangeBlocks: 2,
                       durationTicks: 240, fatigueCost: 5, upkeepCostPerSecond: 0.25,
                       minimumIntelligence: 11, prerequisiteSkillIDs: ["protective_mark"]),
    RPGSpellDefinition(id: "sanctuary", displayName: "Sanctuary",
                       summary: "Repel hostile mobs from a prepared haven for a short time.",
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

public func rpgXPRequiredForLevel(_ level: Int) -> Int {
    let clamped = max(1, min(RPG_LEVEL_CAP, level))
    if clamped <= 1 { return 0 }
    let n = clamped - 1
    return 100 * n * n + 50 * n
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
    max(0, min(RPG_LEVEL_CAP, level) - 1) * 2
}

public func rpgEarnedAttributePoints(level: Int) -> Int {
    max(0, (min(RPG_LEVEL_CAP, level) - 1) / 3)
}

public func rpgSpentSkillPoints(_ state: RPGCharacterState) -> Int {
    guard state.created else { return 0 }
    return rpgSpentSkillPoints(pathID: state.pathID, ranks: state.skillRanks)
}

private func rpgSpentSkillPoints(pathID: String, ranks: [String: Int]) -> Int {
    var spent = 0
    for def in RPG_SKILL_DEFINITIONS {
        if let rank = ranks[def.id], rank > 0 {
            let freeRank = rpgPathDefinition(pathID)?.starterSkillIDs.contains(def.id) == true ? 1 : 0
            spent += max(0, rank - freeRank)
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
    return max(0, state.attributes.total - base)
}

public func rpgAvailableAttributePoints(_ state: RPGCharacterState) -> Int {
    guard state.created else { return 0 }
    return max(0, rpgEarnedAttributePoints(level: state.level) - rpgSpentAttributePoints(state))
}

public func rpgDerivedStats(_ state: RPGCharacterState) -> RPGDerivedStats {
    guard state.created else { return .vanilla }
    let attr = state.attributes.clamped()
    let guardRank = state.skillRanks["guard_stance"] ?? 0
    let plateRank = state.skillRanks["plate_training"] ?? 0
    let formulaRank = state.skillRanks["spell_formula"] ?? 0
    return RPGDerivedStats(
        maxHealth: Double(12 + attr.strength + attr.endurance / 2 + guardRank),
        maxFatigue: Double(attr.strength + attr.endurance + max(0, attr.intelligence - 8) + formulaRank * 2),
        fatigueRegenPerTick: 0.010 + Double(attr.endurance) * 0.0015 + Double(plateRank) * 0.002,
        meleeDamageBonus: Double(max(0, attr.strength - 10)) * 0.15,
        actionAccuracyBonus: Double(max(0, attr.dexterity - 10)) * 0.015,
        spellFailureMitigation: Double(max(0, attr.intelligence - 10)) * 0.02 + Double(formulaRank) * 0.03,
        carryBonusSlots: max(0, (attr.strength - 10) / 2)
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

private func normalizedRPGActionQuickSlots(_ rawSlots: [String?], actions: [RPGPreparedAction]) -> [String?] {
    var out = Array(repeating: Optional<String>.none, count: RPG_ACTION_QUICK_SLOT_COUNT)
    var used = Set<String>()
    for index in 0..<min(rawSlots.count, RPG_ACTION_QUICK_SLOT_COUNT) {
        guard let action = rpgPreparedAction(withToken: rawSlots[index], in: actions),
              !used.contains(action.token) else { continue }
        out[index] = action.token
        used.insert(action.token)
    }
    if rawSlots.isEmpty {
        for action in actions where !used.contains(action.token) {
            guard let empty = out.firstIndex(where: { $0 == nil }) else { break }
            out[empty] = action.token
            used.insert(action.token)
        }
    }
    return out
}

public func rpgActionQuickSlotActions(_ state: RPGCharacterState) -> [RPGPreparedAction?] {
    let actions = rpgPreparedActions(state)
    let tokens = normalizedRPGActionQuickSlots(state.actionQuickSlots, actions: actions)
    return tokens.map { rpgPreparedAction(withToken: $0, in: actions) }
}

public func rpgActionQuickSlotIndex(for token: String, in state: RPGCharacterState) -> Int? {
    normalizedRPGActionQuickSlots(state.actionQuickSlots, actions: rpgPreparedActions(state))
        .firstIndex { $0 == token }
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
        state.actionQuickSlots = Array(repeating: nil, count: RPG_ACTION_QUICK_SLOT_COUNT)
        return
    }
    state.actionQuickSlots = normalizedRPGActionQuickSlots(state.actionQuickSlots, actions: actions)
    if let selected = state.selectedPreparedActionID,
       let parsed = rpgParsePreparedActionToken(selected),
       actions.contains(where: { $0.kind == parsed.kind && $0.id == parsed.id }) {
        if parsed.kind == .spell { state.selectedPreparedSpellID = parsed.id }
        return
    }
    if let selectedSpell = state.selectedPreparedSpellID,
       actions.contains(where: { $0.kind == .spell && $0.id == selectedSpell }) {
        state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: selectedSpell)
        return
    }
    let selected = actions[0]
    state.selectedPreparedActionID = selected.token
    if selected.kind == .spell { state.selectedPreparedSpellID = selected.id }
}

public func rpgAssignPreparedActionToQuickSlot(kind: RPGPreparedActionKind,
                                               id: String,
                                               slot: Int,
                                               in state: inout RPGCharacterState) -> RPGActionFailure? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else { return .actionNotPrepared }
    let actions = rpgPreparedActions(state)
    guard let action = actions.first(where: { $0.kind == kind && $0.id == id }) else {
        switch kind {
        case .skill:
            guard let skill = rpgSkillDefinition(id) else { return .unknownSkill(id) }
            return skill.kind == .active ? .skillNotPrepared(id) : .skillNotActive(id)
        case .spell:
            return rpgSpellDefinition(id) == nil ? .unknownSpell(id) : .spellNotPrepared(id)
        }
    }
    var slots = normalizedRPGActionQuickSlots(state.actionQuickSlots, actions: actions)
    for i in slots.indices where slots[i] == action.token {
        slots[i] = nil
    }
    slots[slot] = action.token
    state.actionQuickSlots = slots
    state.selectedPreparedActionID = action.token
    if action.kind == .spell {
        state.selectedPreparedSpellID = action.id
    }
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgClearActionQuickSlot(_ slot: Int, in state: inout RPGCharacterState) {
    state = repairRPGCharacterState(state)
    guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else { return }
    var slots = normalizedRPGActionQuickSlots(state.actionQuickSlots, actions: rpgPreparedActions(state))
    slots[slot] = nil
    state.actionQuickSlots = slots
    state = repairRPGCharacterState(state)
}

private func starterSpellIDs(for path: RPGPathDefinition, requested: [String]) -> [String] {
    let allowed = Set(path.starterSpellIDs)
    let chosen = requested.isEmpty ? path.starterSpellIDs : requested
    return stableUniqueSpellIDs(chosen.filter { allowed.contains($0) })
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

private func trimRPGSkillRanksToEarnedBudget(_ ranks: [String: Int], path: RPGPathDefinition, level: Int) -> [String: Int] {
    var out = ranks
    let earned = rpgEarnedSkillPoints(level: level)
    while rpgSpentSkillPoints(pathID: path.id, ranks: out) > earned {
        var trimmed = false
        for def in RPG_SKILL_DEFINITIONS.reversed() where def.pathID == path.id {
            let freeRank = path.starterSkillIDs.contains(def.id) ? 1 : 0
            guard let rank = out[def.id], rank > freeRank else { continue }
            let next = rank - 1
            if next <= 0 {
                out.removeValue(forKey: def.id)
            } else {
                out[def.id] = next
            }
            trimmed = true
            break
        }
        if !trimmed { break }
    }
    return out
}

public func rpgCreateCharacter(_ draft: RPGCreationDraft) -> Result<RPGCharacterState, RPGCreationError> {
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
    for spellID in draft.starterSpellIDs where !path.starterSpellIDs.contains(spellID) {
        return .failure(.invalidStarterSpell(spellID))
    }

    var ranks: [String: Int] = [:]
    ranks[skillID] = 1
    let spells = starterSpellIDs(for: path, requested: draft.starterSpellIDs)
    var state = RPGCharacterState(
        created: true,
        pathID: path.id,
        attributes: attrs,
        xp: 0,
        level: 1,
        skillRanks: ranks,
        preparedSkillIDs: [skillID],
        knownSpellIDs: spells,
        preparedSpellIDs: Array(spells.prefix(RPG_MAX_PREPARED_SPELLS)),
        selectedPreparedSpellID: spells.first,
        selectedPreparedActionID: nil,
        fatigue: 0
    )
    state.fatigue = rpgDerivedStats(state).maxFatigue
    return .success(repairRPGCharacterState(state))
}

public func repairRPGCharacterState(_ raw: RPGCharacterState) -> RPGCharacterState {
    if !raw.created { return .uncreated() }
    guard let path = rpgPathDefinition(raw.pathID) else { return .uncreated() }

    var state = raw
    state.version = RPG_STATE_CURRENT_VERSION
    state.created = true
    state.pathID = path.id
    state.xp = max(0, state.xp)
    state.level = rpgLevel(forXP: state.xp)
    state.attributes = state.attributes.clamped()
    if state.attributes.total < RPGAttributes.creationBudget {
        state.attributes = RPGAttributes.defaultCreation
    }
    state.attributes = trimRPGAttributesToEarnedBudget(state.attributes, level: state.level)

    var repairedRanks: [String: Int] = [:]
    for def in RPG_SKILL_DEFINITIONS where def.pathID == path.id {
        let requested = state.skillRanks[def.id] ?? 0
        if requested > 0 {
            repairedRanks[def.id] = min(def.maxRank, max(1, requested))
        }
    }
    for starter in path.starterSkillIDs where repairedRanks[starter] == nil {
        if starter == path.starterSkillIDs.first {
            repairedRanks[starter] = 1
        }
    }
    repairedRanks = trimRPGSkillRanksToEarnedBudget(repairedRanks, path: path, level: state.level)
    state.skillRanks = repairedRanks

    let knownSkills = sortSkillIDs(repairedRanks.compactMap { $0.value > 0 ? $0.key : nil })
    state.preparedSkillIDs = stableUniqueSkillIDs(state.preparedSkillIDs)
        .filter { knownSkills.contains($0) }
    if state.preparedSkillIDs.count > RPG_MAX_PREPARED_SKILLS {
        state.preparedSkillIDs = Array(state.preparedSkillIDs.prefix(RPG_MAX_PREPARED_SKILLS))
    }

    var spellIDs = Set<String>()
    for spellID in state.knownSpellIDs where rpgSpellDefinition(spellID) != nil {
        let spell = rpgSpellDefinition(spellID)!
        if path.starterSpellIDs.contains(spellID)
            || spell.prerequisiteSkillIDs.allSatisfy({ (state.skillRanks[$0] ?? 0) > 0 }) {
            spellIDs.insert(spellID)
        }
    }
    if spellIDs.isEmpty, let firstStarter = path.starterSpellIDs.first {
        spellIDs.insert(firstStarter)
    }
    for def in RPG_SKILL_DEFINITIONS where (state.skillRanks[def.id] ?? 0) > 0 {
        for spellID in def.unlockSpellIDs { spellIDs.insert(spellID) }
    }
    state.knownSpellIDs = sortSpellIDs(Array(spellIDs))
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
    state.actionSequence = max(0, state.actionSequence)
    state.activeCooldowns = state.activeCooldowns.compactMap { cooldown in
        guard cooldown.remainingTicks > 0 else { return nil }
        if rpgSkillDefinition(cooldown.id) == nil && rpgSpellDefinition(cooldown.id) == nil { return nil }
        return RPGCooldown(id: cooldown.id, remainingTicks: cooldown.remainingTicks)
    }
    state.activeUpkeeps = state.activeUpkeeps.compactMap { upkeep in
        guard upkeep.remainingTicks > 0, state.preparedSpellIDs.contains(upkeep.spellID),
              let spell = rpgSpellDefinition(upkeep.spellID), spell.upkeepCostPerSecond > 0 else { return nil }
        return RPGUpkeep(spellID: upkeep.spellID, ownerSequence: upkeep.ownerSequence,
                         remainingTicks: upkeep.remainingTicks, costPerSecond: spell.upkeepCostPerSecond)
    }
    return state
}

public func rpgAddXP(_ amount: Int, to state: inout RPGCharacterState) -> RPGProgressionReport {
    state = repairRPGCharacterState(state)
    guard state.created, amount > 0 else {
        return RPGProgressionReport(leveledUp: false, previousLevel: state.level, newLevel: state.level)
    }
    let previous = state.level
    let capXP = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
    state.xp = min(capXP, max(0, state.xp + amount))
    state.level = rpgLevel(forXP: state.xp)
    if state.level > previous {
        let maxFatigue = rpgDerivedStats(state).maxFatigue
        state.fatigue = min(maxFatigue, state.fatigue + Double(state.level - previous) * 2)
    }
    return RPGProgressionReport(leveledUp: state.level > previous, previousLevel: previous, newLevel: state.level)
}

public func rpgLearnSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard let def = rpgSkillDefinition(skillID), def.pathID == state.pathID else { return .unknownSkill(skillID) }
    let current = state.skillRanks[skillID] ?? 0
    guard current < def.maxRank else { return .alreadyAtMaximumRank(skillID) }
    guard state.level >= def.minimumLevel else { return .insufficientLevel(required: def.minimumLevel) }
    for req in def.requirements {
        guard state.attributes.value(req.attribute) >= req.minimum else {
            return .insufficientAttribute(req.attribute, required: req.minimum)
        }
    }
    for pre in def.prerequisiteSkillIDs where (state.skillRanks[pre] ?? 0) <= 0 {
        return .missingPrerequisite(pre)
    }
    guard rpgAvailableSkillPoints(state) > 0 else { return .insufficientSkillPoints }

    state.skillRanks[skillID] = current + 1
    for spellID in def.unlockSpellIDs where rpgSpellDefinition(spellID) != nil && !state.knownSpellIDs.contains(spellID) {
        state.knownSpellIDs.append(spellID)
    }
    state.knownSpellIDs = sortSpellIDs(state.knownSpellIDs)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgSpendAttributePoint(_ attribute: RPGAttributeID, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgAvailableAttributePoints(state) > 0 else { return .insufficientAttributePoints }
    let current = state.attributes.value(attribute)
    guard current < RPGAttributes.maximumWithProgression else {
        return .insufficientAttribute(attribute, required: current + 1)
    }
    state.attributes.set(attribute, current + 1)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgPrepareSpell(_ spellID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSpellDefinition(spellID) != nil else { return .unknownSpell(spellID) }
    guard state.knownSpellIDs.contains(spellID) else { return .spellNotKnown(spellID) }
    if state.preparedSpellIDs.contains(spellID) {
        state.selectedPreparedSpellID = spellID
        state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: spellID)
        return nil
    }
    guard state.preparedSpellIDs.count < RPG_MAX_PREPARED_SPELLS else { return .preparedSpellLimit }
    state.preparedSpellIDs.append(spellID)
    state.preparedSpellIDs = sortSpellIDs(state.preparedSpellIDs)
    if state.selectedPreparedSpellID == nil { state.selectedPreparedSpellID = spellID }
    if state.selectedPreparedActionID == nil { state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: spellID) }
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgUnprepareSpell(_ spellID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSpellDefinition(spellID) != nil else { return .unknownSpell(spellID) }
    state.preparedSpellIDs.removeAll { $0 == spellID }
    if state.selectedPreparedSpellID == spellID { state.selectedPreparedSpellID = state.preparedSpellIDs.first }
    if state.selectedPreparedActionID == rpgPreparedActionToken(kind: .spell, id: spellID) {
        state.selectedPreparedActionID = nil
    }
    state.activeUpkeeps.removeAll { $0.spellID == spellID }
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgSelectPreparedSpell(_ spellID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSpellDefinition(spellID) != nil else { return .unknownSpell(spellID) }
    guard state.preparedSpellIDs.contains(spellID) else { return .spellNotKnown(spellID) }
    state.selectedPreparedSpellID = spellID
    state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: spellID)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgPrepareSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSkillDefinition(skillID) != nil else { return .unknownSkill(skillID) }
    guard (state.skillRanks[skillID] ?? 0) > 0 else { return .skillNotKnown(skillID) }
    if state.preparedSkillIDs.contains(skillID) { return nil }
    guard state.preparedSkillIDs.count < RPG_MAX_PREPARED_SKILLS else { return .preparedSkillLimit }
    state.preparedSkillIDs.append(skillID)
    state.preparedSkillIDs = sortSkillIDs(state.preparedSkillIDs)
    if let def = rpgSkillDefinition(skillID), def.kind == .active, state.selectedPreparedActionID == nil {
        state.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: skillID)
    }
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgUnprepareSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard rpgSkillDefinition(skillID) != nil else { return .unknownSkill(skillID) }
    state.preparedSkillIDs.removeAll { $0 == skillID }
    if state.selectedPreparedActionID == rpgPreparedActionToken(kind: .skill, id: skillID) {
        state.selectedPreparedActionID = nil
    }
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgSelectPreparedSkill(_ skillID: String, in state: inout RPGCharacterState) -> RPGProgressionError? {
    state = repairRPGCharacterState(state)
    guard state.created else { return .characterNotCreated }
    guard let def = rpgSkillDefinition(skillID) else { return .unknownSkill(skillID) }
    guard def.kind == .active, (state.skillRanks[skillID] ?? 0) > 0 else { return .skillNotKnown(skillID) }
    guard state.preparedSkillIDs.contains(skillID) else { return .skillNotKnown(skillID) }
    state.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: skillID)
    state = repairRPGCharacterState(state)
    return nil
}

public func rpgTickState(_ state: inout RPGCharacterState) {
    state = repairRPGCharacterState(state)
    guard state.created else { return }
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
}

public extension Player {
    func rpgClassesEnabled() -> Bool {
        world.rule(RPG_CLASSES_GAME_RULE)
    }

    func applyRPGDerivedStats() {
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

    func tickRPGState() {
        guard rpgClassesEnabled() else {
            if maxHealth != 20 {
                maxHealth = 20
                health = min(health, maxHealth)
            }
            return
        }
        rpgTickState(&rpg)
        rpgTickPlayerUpkeepEffects(self)
        applyRPGDerivedStats()
    }

    @discardableResult
    func createRPGCharacter(_ draft: RPGCreationDraft) -> RPGCreationError? {
        switch rpgCreateCharacter(draft) {
        case .success(let state):
            rpg = state
            applyRPGDerivedStats()
            health = maxHealth
            return nil
        case .failure(let error):
            return error
        }
    }

    @discardableResult
    func awardRPGXP(_ amount: Int) -> RPGProgressionReport {
        let report = rpgAddXP(amount, to: &rpg)
        applyRPGDerivedStats()
        return report
    }
}
