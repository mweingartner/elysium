// AI agent bridge core — snapshot construction, model-output decoding,
// name resolution, and whitelisted world mutations. This file deliberately
// contains no networking; the app target owns the Ollama transport.

import Foundation

public let AIAgentNearbyRadius = 12.0
public let AIAgentMaxGiveCount = 640
public let AIAgentMaxSpawnCount = 16
public let AIAgentMaxModelJSONBytes = 16 * 1024
public let AIAgentMaxPromptCharacters = 24_000
public let AIAgentWeatherDurationTicks = 12_000
public let AIAgentHoleFillSearchDistance = 32
public let AIAgentHoleFillLateralSearch = 3
public let AIAgentHoleFillMaxDepth = 64
public let AIAgentHoleFillMaxHorizontalRadius = 24
public let AIAgentHoleFillMaxBlocks = 8_192
public let AIAgentBiomeReworkRadius = 28
public let AIAgentBiomeReworkMaxColumns = 2_048
public let AIAgentBiomeReworkMaxTerrainWrites = 32_768
public let AIAgentBiomeReworkMaxOreWrites = 4_096
public let AIAgentMaxFillRegionRadius = 6
public let AIAgentMaxFillRegionBlocks = 4_096
public let AIAgentMaxEntityRemovalRadius = 48
public let AIAgentMaxEntityRemoveCount = 128
public let AIAgentMaxDamageAmount = 2_048
public let AIAgentMaxEffectDurationSeconds = 3_600
public let AIAgentMaxEffectAmplifier = 4
public let AIAgentMaxXPAmount = 100_000

public struct AIAgentSkillParameter: Equatable {
    public let name: String
    public let type: String
    public let summary: String
    public let enumValues: [String]?
    public let minimum: Int?
    public let maximum: Int?

    public init(name: String, type: String, summary: String,
                enumValues: [String]? = nil, minimum: Int? = nil, maximum: Int? = nil) {
        self.name = name
        self.type = type
        self.summary = summary
        self.enumValues = enumValues
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct AIAgentSkillDefinition: Equatable {
    public let name: String
    public let summary: String
    public let required: [String]
    public let parameters: [AIAgentSkillParameter]

    public init(name: String, summary: String, required: [String] = [],
                parameters: [AIAgentSkillParameter] = []) {
        self.name = name
        self.summary = summary
        self.required = required
        self.parameters = parameters
    }
}

public let allAIAgentSkills: [AIAgentSkillDefinition] = [
    AIAgentSkillDefinition(
        name: "say",
        summary: "Reply without mutating world or player state.",
        required: ["message"],
        parameters: [
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "give_item",
        summary: "Give a registered item to the local player inventory.",
        required: ["item"],
        parameters: [
            AIAgentSkillParameter(name: "item", type: "string", summary: "Registered item id or display name."),
            AIAgentSkillParameter(name: "count", type: "integer", summary: "Item count.", minimum: 1, maximum: AIAgentMaxGiveCount),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "place_block",
        summary: "Place a registered block item at the cursor through normal placement rules.",
        required: ["item", "target"],
        parameters: [
            AIAgentSkillParameter(name: "item", type: "string", summary: "Registered block item id or display name."),
            AIAgentSkillParameter(name: "target", type: "string", summary: "Placement target.", enumValues: ["cursor"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_block_at_cursor",
        summary: "Replace the block under the cursor with a registered block or air.",
        required: ["block", "target"],
        parameters: [
            AIAgentSkillParameter(name: "block", type: "string", summary: "Registered block id/display name, or air."),
            AIAgentSkillParameter(name: "target", type: "string", summary: "Mutation target.", enumValues: ["cursor"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "break_block",
        summary: "Break the block under the cursor through the normal break/drop path.",
        required: ["target"],
        parameters: [
            AIAgentSkillParameter(name: "target", type: "string", summary: "Break target.", enumValues: ["cursor"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "use_block",
        summary: "Use or toggle the block under the cursor through normal right-click behavior.",
        required: ["target"],
        parameters: [
            AIAgentSkillParameter(name: "target", type: "string", summary: "Use target.", enumValues: ["cursor"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "fill_hole",
        summary: "Fill a bounded dirt-rimmed hole in front of the player.",
        required: ["block", "target"],
        parameters: [
            AIAgentSkillParameter(name: "block", type: "string", summary: "Registered solid block id or display name."),
            AIAgentSkillParameter(name: "target", type: "string", summary: "Hole search target.", enumValues: ["front"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "fill_region",
        summary: "Fill a bounded cube around the cursor placement cell with a registered block or air.",
        required: ["block", "target"],
        parameters: [
            AIAgentSkillParameter(name: "block", type: "string", summary: "Registered block id/display name, or air."),
            AIAgentSkillParameter(name: "target", type: "string", summary: "Region center.", enumValues: ["cursor"]),
            AIAgentSkillParameter(name: "radius", type: "integer", summary: "Cube radius around the cursor.", minimum: 0, maximum: AIAgentMaxFillRegionRadius),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "rework_biome",
        summary: "Rework the currently loaded biome patch into the fixed rolling resource-rich profile.",
        required: ["target", "profile"],
        parameters: [
            AIAgentSkillParameter(name: "target", type: "string", summary: "Biome target.", enumValues: ["current_biome"]),
            AIAgentSkillParameter(name: "profile", type: "string", summary: "Supported biome profile.", enumValues: ["rolling_hills_resource_rich"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_time",
        summary: "Set normalized world day time.",
        parameters: [
            AIAgentSkillParameter(name: "value", type: "string", summary: "day, noon, sunset, night, midnight, sunrise, or ticks."),
            AIAgentSkillParameter(name: "ticks", type: "integer", summary: "Day time ticks.", minimum: 0, maximum: DAY_LENGTH - 1),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_weather",
        summary: "Set clear, rain, or thunder weather.",
        required: ["weather"],
        parameters: [
            AIAgentSkillParameter(name: "weather", type: "string", summary: "Weather state.", enumValues: ["clear", "rain", "thunder"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "spawn_entity",
        summary: "Spawn registered mobs at the cursor placement cell.",
        required: ["entity", "target"],
        parameters: [
            AIAgentSkillParameter(name: "entity", type: "string", summary: "Registered spawnable entity name."),
            AIAgentSkillParameter(name: "count", type: "integer", summary: "Spawn count.", minimum: 1, maximum: AIAgentMaxSpawnCount),
            AIAgentSkillParameter(name: "target", type: "string", summary: "Spawn target.", enumValues: ["cursor"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "remove_entities_nearby",
        summary: "Remove non-player nearby entities, optionally limited to a registered entity name.",
        parameters: [
            AIAgentSkillParameter(name: "entity", type: "string", summary: "Registered spawnable entity name or all."),
            AIAgentSkillParameter(name: "radius", type: "integer", summary: "Search radius around the player.", minimum: 1, maximum: AIAgentMaxEntityRemovalRadius),
            AIAgentSkillParameter(name: "count", type: "integer", summary: "Maximum removals.", minimum: 1, maximum: AIAgentMaxEntityRemoveCount),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "eat_selected_food",
        summary: "Eat one selected hotbar food item if normal food-use rules allow it.",
        parameters: [
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_gamemode",
        summary: "Set the local player game mode.",
        required: ["mode"],
        parameters: [
            AIAgentSkillParameter(name: "mode", type: "string", summary: "Game mode.", enumValues: ["survival", "creative"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "heal_player",
        summary: "Restore the local player's health, hunger, and saturation.",
        parameters: [
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "damage_player",
        summary: "Damage the local player by a bounded amount.",
        required: ["amount"],
        parameters: [
            AIAgentSkillParameter(name: "amount", type: "integer", summary: "Damage amount.", minimum: 1, maximum: AIAgentMaxDamageAmount),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "apply_effect",
        summary: "Apply or clear registered player status effects.",
        required: ["effect"],
        parameters: [
            AIAgentSkillParameter(name: "effect", type: "string", summary: "Registered effect id, or clear."),
            AIAgentSkillParameter(name: "duration", type: "integer", summary: "Duration in seconds.", minimum: 1, maximum: AIAgentMaxEffectDurationSeconds),
            AIAgentSkillParameter(name: "amplifier", type: "integer", summary: "Zero-based amplifier.", minimum: 0, maximum: AIAgentMaxEffectAmplifier),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "clear_inventory",
        summary: "Clear the local player's carried inventory, armor, and offhand.",
        parameters: [
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "add_xp",
        summary: "Add bounded XP points or levels to the local player.",
        required: ["amount"],
        parameters: [
            AIAgentSkillParameter(name: "amount", type: "integer", summary: "XP amount.", minimum: 1, maximum: AIAgentMaxXPAmount),
            AIAgentSkillParameter(name: "levels", type: "boolean", summary: "True to add levels instead of points."),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_spawnpoint",
        summary: "Set the local player's spawn point to the current position and dimension.",
        parameters: [
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_difficulty",
        summary: "Set world difficulty through the app-provided world-global callback.",
        required: ["value"],
        parameters: [
            AIAgentSkillParameter(name: "value", type: "string", summary: "Difficulty.", enumValues: ["peaceful", "easy", "normal", "hard"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "set_gamerule",
        summary: "Set an existing game rule through the app-provided world-global callback.",
        required: ["rule"],
        parameters: [
            AIAgentSkillParameter(name: "rule", type: "string", summary: "Existing game rule name."),
            AIAgentSkillParameter(name: "enabled", type: "boolean", summary: "Boolean game rule value."),
            AIAgentSkillParameter(name: "value", type: "string", summary: "Numeric or boolean game rule value."),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "teleport_player",
        summary: "Teleport the local player to a safe player-relative destination.",
        required: ["target"],
        parameters: [
            AIAgentSkillParameter(name: "target", type: "string", summary: "Teleport target.", enumValues: ["surface"]),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "replace_template_blocks",
        summary: "Replace registered block families/types inside a saved object template.",
        required: ["template", "from_block", "to_block"],
        parameters: [
            AIAgentSkillParameter(name: "template", type: "string", summary: "Saved template name."),
            AIAgentSkillParameter(name: "from_block", type: "string", summary: "Source registered block or family."),
            AIAgentSkillParameter(name: "to_block", type: "string", summary: "Replacement registered block."),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
    AIAgentSkillDefinition(
        name: "create_template",
        summary: "Create a bounded generated object template.",
        required: ["template", "kind"],
        parameters: [
            AIAgentSkillParameter(name: "template", type: "string", summary: "New template name."),
            AIAgentSkillParameter(name: "kind", type: "string", summary: "Generated object kind.", enumValues: ["pirate_ship", "ship", "boat"]),
            AIAgentSkillParameter(name: "length", type: "integer", summary: "Requested object length.", minimum: 16, maximum: OBJECT_TEMPLATE_MAX_SPAN),
            AIAgentSkillParameter(name: "style", type: "string", summary: "Short style description."),
            AIAgentSkillParameter(name: "message", type: "string", summary: "Short chat response."),
        ]),
]

public let aiAgentSkillActionNames: [String] = allAIAgentSkills.map(\.name)

public struct AIAgentAction: Codable, Equatable {
    public var action: String
    public var item: String?
    public var block: String?
    public var count: Int?
    public var target: String?
    public var message: String?
    public var template: String?
    public var name: String?
    public var fromBlock: String?
    public var toBlock: String?
    public var kind: String?
    public var length: Int?
    public var style: String?
    public var entity: String?
    public var value: String?
    public var time: String?
    public var weather: String?
    public var ticks: Int?
    public var profile: String?
    public var radius: Int?
    public var amount: Int?
    public var mode: String?
    public var effect: String?
    public var duration: Int?
    public var amplifier: Int?
    public var rule: String?
    public var enabled: Bool?
    public var levels: Bool?

    public init(action: String, item: String? = nil, block: String? = nil, count: Int? = nil,
                target: String? = nil, message: String? = nil, template: String? = nil,
                name: String? = nil, fromBlock: String? = nil, toBlock: String? = nil,
                kind: String? = nil, length: Int? = nil, style: String? = nil,
                entity: String? = nil, value: String? = nil, time: String? = nil,
                weather: String? = nil, ticks: Int? = nil, profile: String? = nil,
                radius: Int? = nil, amount: Int? = nil, mode: String? = nil,
                effect: String? = nil, duration: Int? = nil, amplifier: Int? = nil,
                rule: String? = nil, enabled: Bool? = nil, levels: Bool? = nil) {
        self.action = action
        self.item = item
        self.block = block
        self.count = count
        self.target = target
        self.message = message
        self.template = template
        self.name = name
        self.fromBlock = fromBlock
        self.toBlock = toBlock
        self.kind = kind
        self.length = length
        self.style = style
        self.entity = entity
        self.value = value
        self.time = time
        self.weather = weather
        self.ticks = ticks
        self.profile = profile
        self.radius = radius
        self.amount = amount
        self.mode = mode
        self.effect = effect
        self.duration = duration
        self.amplifier = amplifier
        self.rule = rule
        self.enabled = enabled
        self.levels = levels
    }

    enum CodingKeys: String, CodingKey {
        case action, item, block, count, target, message, template, name, kind, length, style
        case entity, value, time, weather, ticks, profile, radius, amount, mode, effect, duration
        case amplifier, rule, enabled, levels
        case fromBlock = "from_block"
        case toBlock = "to_block"
    }
}

public struct AIAgentExecutionResult: Equatable {
    public let message: String
    public let changedWorld: Bool

    public init(message: String, changedWorld: Bool) {
        self.message = message
        self.changedWorld = changedWorld
    }
}

public struct AIAgentHoleFillResult: Equatable {
    public let seedX: Int
    public let seedY: Int
    public let seedZ: Int
    public let blockId: UInt16
    public let filledBlocks: Int

    public init(seedX: Int, seedY: Int, seedZ: Int, blockId: UInt16, filledBlocks: Int) {
        self.seedX = seedX
        self.seedY = seedY
        self.seedZ = seedZ
        self.blockId = blockId
        self.filledBlocks = filledBlocks
    }
}

public struct AIAgentBiomeReworkResult: Equatable {
    public let sourceBiome: Biome
    public let targetBiome: Biome
    public let columns: Int
    public let terrainBlocks: Int
    public let resourceBlocks: Int
    public let biomeCells: Int

    public init(sourceBiome: Biome, targetBiome: Biome, columns: Int,
                terrainBlocks: Int, resourceBlocks: Int, biomeCells: Int) {
        self.sourceBiome = sourceBiome
        self.targetBiome = targetBiome
        self.columns = columns
        self.terrainBlocks = terrainBlocks
        self.resourceBlocks = resourceBlocks
        self.biomeCells = biomeCells
    }
}

public enum AIAgentBiomeReworkProfile: Equatable {
    case rollingHillsResourceRich

    var displayName: String {
        switch self {
        case .rollingHillsResourceRich: return "Rolling Hills - Resource Rich"
        }
    }

    var targetBiome: Biome {
        switch self {
        case .rollingHillsResourceRich: return .meadow
        }
    }
}

public enum AIAgentError: Error, Equatable, CustomStringConvertible {
    case emptyResponse
    case responseTooLarge
    case malformedJSON
    case unsupportedAction(String)
    case missingItem
    case unknownItem(String)
    case itemNotPlaceable(String)
    case missingCursorTarget
    case invalidTarget(String)
    case missingHoleTarget
    case holeFillTooLarge(Int, Int)
    case unloadedTarget(Int, Int, Int)
    case targetOutOfWorld(Int, Int, Int)
    case placementFailed(String)
    case inventoryFull(String)
    case missingTimeValue
    case invalidTimeValue(String)
    case missingWeatherValue
    case invalidWeather(String)
    case missingEntity
    case unknownEntity(String)
    case entitySpawnFailed(String)
    case blockBreakFailed(String)
    case blockUseFailed(String)
    case regionFillTooLarge(Int, Int)
    case missingMode
    case invalidMode(String)
    case missingAmount
    case invalidAmount(Int)
    case missingEffect
    case unknownEffect(String)
    case missingDifficulty
    case invalidDifficulty(String)
    case missingGameRule
    case unknownGameRule(String)
    case invalidGameRuleValue(String)
    case invalidTeleportTarget(String)
    case missingBiomeReworkTarget
    case unsupportedBiomeRework(String)
    case missingTemplateName
    case unknownTemplate(String)
    case missingBlockReplacement
    case unknownBlock(String)
    case templateWriteFailed(String)
    case unsupportedTemplateAction(String)

    public var description: String {
        switch self {
        case .emptyResponse: return "AI returned an empty response"
        case .responseTooLarge: return "AI response was too large"
        case .malformedJSON: return "AI response was not valid action JSON"
        case .unsupportedAction(let action): return "AI action is not allowed: \(action)"
        case .missingItem: return "AI action did not name an item or block"
        case .unknownItem(let item): return "Unknown item or block: \(item)"
        case .itemNotPlaceable(let item): return "\(item) is not placeable as a block"
        case .missingCursorTarget: return "No block is under the cursor"
        case .invalidTarget(let value): return "Unsupported target: \(value)"
        case .missingHoleTarget: return "No fillable hole was found in front of the player"
        case .holeFillTooLarge(let count, let max): return "Hole fill is too large: \(count) blocks exceeds \(max)"
        case .unloadedTarget(let x, let y, let z): return "Target chunk is not loaded at \(x) \(y) \(z)"
        case .targetOutOfWorld(let x, let y, let z): return "Target is outside world height at \(x) \(y) \(z)"
        case .placementFailed(let item): return "Could not place \(item) at the cursor"
        case .inventoryFull(let item): return "Inventory is full; could not give \(item)"
        case .missingTimeValue: return "AI action did not name a time preset or tick value"
        case .invalidTimeValue(let value): return "Unknown time value: \(value)"
        case .missingWeatherValue: return "AI action did not name a weather state"
        case .invalidWeather(let value): return "Unknown weather state: \(value)"
        case .missingEntity: return "AI action did not name a spawnable entity"
        case .unknownEntity(let value): return "Unknown spawnable entity: \(value)"
        case .entitySpawnFailed(let value): return "Could not spawn \(value) at the cursor"
        case .blockBreakFailed(let value): return "Could not break block: \(value)"
        case .blockUseFailed(let value): return "Could not use block: \(value)"
        case .regionFillTooLarge(let count, let max): return "Region fill is too large: \(count) blocks exceeds \(max)"
        case .missingMode: return "AI action did not name a game mode"
        case .invalidMode(let value): return "Unknown game mode: \(value)"
        case .missingAmount: return "AI action did not name an amount"
        case .invalidAmount(let value): return "Invalid amount: \(value)"
        case .missingEffect: return "AI action did not name an effect"
        case .unknownEffect(let value): return "Unknown effect: \(value)"
        case .missingDifficulty: return "AI action did not name a difficulty"
        case .invalidDifficulty(let value): return "Unknown difficulty: \(value)"
        case .missingGameRule: return "AI action did not name a game rule"
        case .unknownGameRule(let value): return "Unknown game rule: \(value)"
        case .invalidGameRuleValue(let value): return "Invalid game rule value: \(value)"
        case .invalidTeleportTarget(let value): return "Unsupported teleport target: \(value)"
        case .missingBiomeReworkTarget: return "No loaded current biome area was found around the player"
        case .unsupportedBiomeRework(let value): return "Unsupported biome rework: \(value)"
        case .missingTemplateName: return "AI action did not name an object template"
        case .unknownTemplate(let name): return "Unknown object template: \(name)"
        case .missingBlockReplacement: return "AI action did not name both source and replacement blocks"
        case .unknownBlock(let block): return "Unknown block type: \(block)"
        case .templateWriteFailed(let name): return "Template store write failed for \(name)"
        case .unsupportedTemplateAction(let action): return "AI template action is not allowed: \(action)"
        }
    }
}

public func normalizeAIAgentName(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("minecraft:") {
        s.removeFirst("minecraft:".count)
    }
    s = s.replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: ".", with: "_")
    while s.contains("__") {
        s = s.replacingOccurrences(of: "__", with: "_")
    }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

private let aiAgentAliases: [String: String] = [
    "crafting_station": "crafting_table",
    "crafting_bench": "crafting_table",
    "workbench": "crafting_table",
    "crafting_workbench": "crafting_table",
    "roasted_chicken": "cooked_chicken",
    "cooked_pork": "cooked_porkchop",
    "pork": "porkchop",
    "wooden_plank": "oak_planks",
    "wooden_planks": "oak_planks",
]

private let aiAgentEntityAliases: [String: String] = [
    "dragon": "ender_dragon",
    "zombie_pigman": "zombified_piglin",
    "pigman": "zombified_piglin",
    "mooshroom_cow": "mooshroom",
    "snowman": "snow_golem",
]

private let aiAgentTimePresets: [String: Int] = [
    "day": 1_000,
    "morning": 1_000,
    "noon": 6_000,
    "sunset": 12_000,
    "dusk": 12_000,
    "night": 13_000,
    "midnight": 18_000,
    "sunrise": 23_000,
    "dawn": 23_000,
]

private func canonicalAIAgentName(_ raw: String) -> String {
    let normalized = normalizeAIAgentName(raw)
    return aiAgentAliases[normalized] ?? normalized
}

public func resolveAIAgentItemID(_ raw: String) -> Int? {
    for name in aiAgentNameCandidates(raw) {
        if let id = iidOpt(name) { return id }
        if let item = itemDefs.first(where: { normalizeAIAgentName($0.displayName) == name }) {
            return item.id
        }
    }
    return nil
}

public func resolveAIAgentBlockID(_ raw: String) -> UInt16? {
    for name in aiAgentNameCandidates(raw) {
        if let itemId = iidOpt(name), let block = itemDef(itemId).block {
            return block
        }
        if let item = itemDefs.first(where: { normalizeAIAgentName($0.displayName) == name }), let block = item.block {
            return block
        }
        if let block = bidOpt(name) {
            return block
        }
        if let block = blockDefs.first(where: { normalizeAIAgentName($0.displayName) == name }) {
            return UInt16(block.id)
        }
    }
    return nil
}

public func resolveAIAgentEntityName(_ raw: String) -> String? {
    let spawnable = Set(spawnableMobs())
    for baseCandidate in aiAgentNameCandidates(raw) {
        var candidates = [baseCandidate]
        if let alias = aiAgentEntityAliases[baseCandidate] {
            candidates.append(alias)
        }
        for suffix in ["_mob", "_mobs", "_animal", "_animals", "_monster", "_monsters"] {
            if baseCandidate.hasSuffix(suffix) {
                candidates.append(String(baseCandidate.dropLast(suffix.count)))
            }
        }
        for candidate in candidates {
            if spawnable.contains(candidate) {
                return candidate
            }
        }
    }
    return nil
}

public func resolveAIAgentDayTime(value rawValue: String?, ticks: Int? = nil) -> Int? {
    if let ticks {
        return normalizedAIAgentDayTime(ticks)
    }
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = normalizeAIAgentName(trimmed)
    if let preset = aiAgentTimePresets[normalized] {
        return preset
    }
    if let ticks = Int(trimmed) ?? Int(normalized) {
        return normalizedAIAgentDayTime(ticks)
    }
    return nil
}

private func normalizedAIAgentDayTime(_ ticks: Int) -> Int {
    ((ticks % DAY_LENGTH) + DAY_LENGTH) % DAY_LENGTH
}

public func resolveAIAgentWeather(_ raw: String?) -> (name: String, raining: Bool, thundering: Bool)? {
    guard let raw else { return nil }
    switch normalizeAIAgentName(raw) {
    case "clear", "sun", "sunny", "fair", "none", "stop_rain", "stop_raining", "clear_weather":
        return ("clear", false, false)
    case "rain", "raining", "rainy":
        return ("rain", true, false)
    case "thunder", "storm", "thunderstorm", "thunder_storm", "lightning":
        return ("thunder", true, true)
    default:
        return nil
    }
}

public func resolveAIAgentGameMode(_ raw: String?) -> (name: String, value: Int)? {
    guard let raw else { return nil }
    switch normalizeAIAgentName(raw) {
    case "survival", "0", "s": return ("Survival", GameMode.survival)
    case "creative", "1", "c": return ("Creative", GameMode.creative)
    default: return nil
    }
}

public func resolveAIAgentDifficulty(_ raw: String?) -> (name: String, value: Int)? {
    guard let raw else { return nil }
    switch normalizeAIAgentName(raw) {
    case "peaceful", "0": return ("Peaceful", 0)
    case "easy", "1": return ("Easy", 1)
    case "normal", "2": return ("Normal", 2)
    case "hard", "3": return ("Hard", 3)
    default: return nil
    }
}

public func resolveAIAgentGameRuleValue(enabled: Bool?, value raw: String?) -> Double? {
    if let enabled { return enabled ? 1 : 0 }
    guard let raw else { return nil }
    switch normalizeAIAgentName(raw) {
    case "true", "yes", "on", "enabled", "enable": return 1
    case "false", "no", "off", "disabled", "disable": return 0
    default:
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private func resolveAIAgentBlockOrAir(_ raw: String) -> UInt16? {
    if normalizeAIAgentName(raw) == "air" { return 0 }
    return resolveAIAgentBlockID(raw)
}

public func resolveAIAgentBiomeReworkProfile(_ raw: String?) -> AIAgentBiomeReworkProfile? {
    let normalized = normalizeAIAgentName(raw ?? "rolling_hills_resource_rich")
    switch normalized {
    case "", "rolling_hills", "rolling_hills_resource_rich", "moderate_hills_resource_rich",
         "resource_rich", "rich_resources", "rich_resource", "hilly_resources",
         "hills_with_rich_resources", "rolling_hills_with_rich_resources":
        return .rollingHillsResourceRich
    default:
        return nil
    }
}

private func aiAgentNameCandidates(_ raw: String) -> [String] {
    let canonical = canonicalAIAgentName(raw)
    var candidates: [String] = []
    func add(_ name: String) {
        let canonicalName = canonicalAIAgentName(name)
        if !canonicalName.isEmpty && !candidates.contains(canonicalName) {
            candidates.append(canonicalName)
        }
    }
    add(canonical)
    let noise = Set([
        "a", "an", "the", "some", "of", "item", "items", "stack", "stacks",
        "full", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten",
    ])
    let filtered = canonical
        .split(separator: "_")
        .map(String.init)
        .filter { token in
            !noise.contains(token) && Int(token) == nil
        }
        .joined(separator: "_")
    if !filtered.isEmpty && filtered != canonical {
        add(filtered)
        if filtered.hasSuffix("s") {
            add(String(filtered.dropLast()))
        }
    }
    if canonical.hasSuffix("s") {
        add(String(canonical.dropLast()))
    }
    return candidates
}

public func isAIAgentTemplateAction(_ action: AIAgentAction) -> Bool {
    switch normalizeAIAgentName(action.action) {
    case "replace_template_blocks", "change_template_blocks", "edit_template_blocks",
         "create_template", "create_object_template":
        return true
    default:
        return false
    }
}

public func inferDirectAIAgentTemplateAction(from userRequest: String) -> AIAgentAction? {
    if let action = inferDirectAIAgentTemplateReplacementAction(from: userRequest) { return action }
    if let action = inferDirectAIAgentTemplateCreationAction(from: userRequest) { return action }
    return nil
}

private func firstQuotedSegment(in raw: String) -> (value: String, range: Range<String.Index>)? {
    var quote: Character?
    var start: String.Index?
    for idx in raw.indices {
        let ch = raw[idx]
        if quote == nil, ch == "\"" || ch == "'" {
            quote = ch
            start = raw.index(after: idx)
            continue
        }
        if let q = quote, ch == q, let start {
            return (String(raw[start..<idx]), start..<idx)
        }
    }
    return nil
}

private func cleanedAIAgentBlockPhrase(_ raw: String) -> String {
    var words = normalizeAIAgentRequestText(raw).split(separator: " ").map(String.init)
    let leadingNoise = Set(["the", "type", "of", "block", "blocks"])
    while let first = words.first, leadingNoise.contains(first) {
        words.removeFirst()
    }
    while let last = words.last, last == "block" || last == "blocks" || last == "type" {
        words.removeLast()
    }
    return words.joined(separator: " ")
}

private func inferDirectAIAgentTemplateReplacementAction(from raw: String) -> AIAgentAction? {
    let lower = raw.lowercased()
    guard ["change", "replace", "convert"].contains(where: { lower.contains($0) }),
          let quoted = firstQuotedSegment(in: raw) else { return nil }

    let beforeTemplate = String(raw[..<quoted.range.lowerBound])
    let afterTemplate = String(raw[quoted.range.upperBound...])
    let beforeLower = beforeTemplate.lowercased()
    guard let allRange = beforeLower.range(of: "all ", options: .backwards),
          let inRange = beforeLower.range(of: " in", options: .backwards),
          allRange.upperBound < inRange.lowerBound else { return nil }
    let sourceRaw = String(beforeLower[allRange.upperBound..<inRange.lowerBound])
    let afterLower = afterTemplate.lowercased()
    guard let toRange = afterLower.range(of: " to ") else { return nil }
    let destinationRaw = String(afterLower[toRange.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".;:!?")))

    let source = cleanedAIAgentBlockPhrase(sourceRaw)
    let destination = cleanedAIAgentBlockPhrase(destinationRaw)
    guard !source.isEmpty, !destination.isEmpty else { return nil }
    return AIAgentAction(
        action: "replace_template_blocks",
        template: quoted.value,
        fromBlock: source,
        toBlock: destination)
}

private func inferDirectAIAgentTemplateCreationAction(from raw: String) -> AIAgentAction? {
    let normalized = normalizeAIAgentRequestText(raw)
    let padded = " \(normalized) "
    guard padded.contains(" create ") || padded.contains(" build ") || padded.contains(" generate ") else { return nil }
    guard padded.contains(" object ") || padded.contains(" template ") else { return nil }
    guard let name = inferGeneratedTemplateName(from: raw) else { return nil }
    let kind = inferGeneratedTemplateKind(from: normalized)
    guard !kind.isEmpty else { return nil }
    return AIAgentAction(
        action: "create_template",
        template: name,
        kind: kind,
        length: inferGeneratedTemplateLength(from: normalized),
        style: raw)
}

private func inferGeneratedTemplateName(from raw: String) -> String? {
    let lower = raw.lowercased()
    let markers = [
        "name the object ", "name the template ", "name it ",
        "called ", "named ",
    ]
    for marker in markers {
        guard let range = lower.range(of: marker, options: .backwards) else { continue }
        let tail = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let quoted = firstQuotedSegment(in: tail) {
            return quoted.value
        }
        let token = tail.split { ch in
            ch.isWhitespace || ch == "." || ch == "," || ch == ";" || ch == ":" || ch == "!" || ch == "?"
        }.first.map(String.init)
        if let token, !token.isEmpty { return token }
    }
    return nil
}

private func inferGeneratedTemplateKind(from normalizedRequest: String) -> String {
    if normalizedRequest.contains("pirate ship") { return "pirate_ship" }
    if normalizedRequest.contains("ship") { return "ship" }
    if normalizedRequest.contains("boat") { return "boat" }
    return ""
}

private func inferGeneratedTemplateLength(from normalizedRequest: String) -> Int? {
    let words = normalizedRequest.split(separator: " ").map(String.init)
    for (idx, word) in words.enumerated() {
        guard word == "long" || word == "length" else { continue }
        let searchStart = max(0, idx - 4)
        for candidate in words[searchStart..<idx].reversed() {
            if let value = Int(candidate) { return value }
        }
    }
    for (idx, word) in words.enumerated() where word == "blocks" && idx > 0 {
        if let value = Int(words[idx - 1]) { return value }
    }
    return nil
}

public func inferDirectAIAgentAction(from userRequest: String) -> AIAgentAction? {
    if let templateAction = inferDirectAIAgentTemplateAction(from: userRequest) {
        return templateAction
    }
    if let holeAction = inferDirectAIAgentHoleFillAction(from: userRequest) {
        return holeAction
    }
    if let worldAction = inferDirectAIAgentWorldMutationAction(from: userRequest) {
        return worldAction
    }
    let normalized = normalizeAIAgentRequestText(userRequest)
    guard hasInventoryGiveIntent(normalized) else { return nil }

    let words = normalized.split(separator: " ").map(String.init)
    guard let phraseStart = firstGiveItemPhraseIndex(words) else { return nil }
    let phraseEnd = words.firstIndex { word in
        ["to", "into", "in"].contains(word)
    } ?? words.count
    guard phraseStart < phraseEnd else { return nil }

    let itemWords = Array(words[phraseStart..<phraseEnd])
    let itemPhrase = itemWords.joined(separator: " ")
    guard let itemId = resolveAIAgentItemID(itemPhrase) else { return nil }
    let count = inferDirectAIAgentCount(from: itemWords, itemId: itemId)
    return AIAgentAction(
        action: "give_item",
        item: itemDef(itemId).name,
        count: min(AIAgentMaxGiveCount, max(1, count)),
        message: "Gave \(min(AIAgentMaxGiveCount, max(1, count))) \(itemDef(itemId).displayName)")
}

private func inferDirectAIAgentHoleFillAction(from userRequest: String) -> AIAgentAction? {
    let normalized = normalizeAIAgentRequestText(userRequest)
    let padded = " \(normalized) "
    guard padded.contains(" fill "), padded.contains(" hole ") else { return nil }

    let words = normalized.split(separator: " ").map(String.init)
    guard let withIndex = words.lastIndex(of: "with"), withIndex + 1 < words.count else { return nil }
    let stopWords = Set(["at", "in", "on", "near", "around", "where", "please", "now"])
    var blockWords: [String] = []
    for word in words[(withIndex + 1)..<words.count] {
        if !blockWords.isEmpty && stopWords.contains(word) { break }
        blockWords.append(word)
    }
    let blockPhrase = cleanedAIAgentBlockPhrase(blockWords.joined(separator: " "))
    guard !blockPhrase.isEmpty,
          let blockId = resolveAIAgentBlockID(blockPhrase),
          blockId != 0,
          blockDefs[Int(blockId)].solid else { return nil }
    let blockName = blockDefs[Int(blockId)].name
    return AIAgentAction(
        action: "fill_hole",
        block: blockName,
        target: "front")
}

private func inferDirectAIAgentWorldMutationAction(from userRequest: String) -> AIAgentAction? {
    let normalized = normalizeAIAgentRequestText(userRequest)
    if let action = inferDirectAIAgentBiomeReworkAction(from: normalized) { return action }
    if let action = inferDirectAIAgentTimeAction(from: normalized) { return action }
    if let action = inferDirectAIAgentWeatherAction(from: normalized) { return action }
    if let action = inferDirectAIAgentSpawnEntityAction(from: normalized) { return action }
    if let action = inferDirectAIAgentGameModeAction(from: normalized) { return action }
    if let action = inferDirectAIAgentHealAction(from: normalized) { return action }
    if let action = inferDirectAIAgentEatAction(from: normalized) { return action }
    if let action = inferDirectAIAgentBlockUseAction(from: normalized) { return action }
    if let action = inferDirectAIAgentBlockBreakAction(from: normalized) { return action }
    if let action = inferDirectAIAgentSurfaceTeleportAction(from: normalized) { return action }
    if let action = inferDirectAIAgentClearInventoryAction(from: normalized) { return action }
    if let action = inferDirectAIAgentDifficultyAction(from: normalized) { return action }
    return nil
}

private func inferDirectAIAgentBiomeReworkAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    let hasChangeIntent = [
        " change ", " convert ", " transform ", " rework ", " terraform ",
        " reshape ", " remake ", " make ",
    ].contains { padded.contains($0) }
    let hasTerrainTarget = padded.contains(" biome ")
        || padded.contains(" terrain ")
        || padded.contains(" map ")
        || padded.contains(" landscape ")
    let hasCurrentTarget = padded.contains(" current ")
        || padded.contains(" around me ")
        || padded.contains(" where i am ")
        || padded.contains(" where im ")
        || padded.contains(" nearby ")
        || padded.contains(" this ")
    let wantsRollingHills = padded.contains(" rolling hill ")
        || padded.contains(" rolling hills ")
        || padded.contains(" moderate hill ")
        || padded.contains(" moderate hills ")
        || padded.contains(" hilly ")
        || padded.contains(" hills ")
    let wantsRichResources = padded.contains(" rich resources ")
        || padded.contains(" resource rich ")
        || padded.contains(" rich resource ")
        || padded.contains(" more ores ")
        || padded.contains(" more ore ")
        || padded.contains(" lots of ores ")
        || padded.contains(" lots of ore ")

    guard hasChangeIntent, hasTerrainTarget, hasCurrentTarget,
          wantsRollingHills || wantsRichResources else { return nil }
    return AIAgentAction(
        action: "rework_biome",
        target: "current_biome",
        kind: "rolling_hills_resource_rich",
        profile: "rolling_hills_resource_rich")
}

private func inferDirectAIAgentTimeAction(from normalized: String) -> AIAgentAction? {
    let words = normalized.split(separator: " ").map(String.init)
    guard !words.isEmpty else { return nil }
    let padded = " \(normalized) "
    let hasTimeIntent = padded.contains(" time ")
        || padded.contains(" make it ")
        || padded.contains(" make the world ")
        || padded.contains(" set it ")
    guard hasTimeIntent,
          [" set ", " make ", " change "].contains(where: { padded.contains($0) }) else { return nil }

    if let timeIndex = words.firstIndex(of: "time") {
        let searchEnd = min(words.count, timeIndex + 6)
        for word in words[(timeIndex + 1)..<searchEnd] {
            if resolveAIAgentDayTime(value: word) != nil {
                return AIAgentAction(action: "set_time", value: word)
            }
        }
    }

    for word in words {
        if aiAgentTimePresets[word] != nil {
            return AIAgentAction(action: "set_time", value: word)
        }
        if Int(word) != nil, padded.contains(" time ") {
            return AIAgentAction(action: "set_time", value: word)
        }
    }
    return nil
}

private func inferDirectAIAgentWeatherAction(from normalized: String) -> AIAgentAction? {
    let words = normalized.split(separator: " ").map(String.init)
    guard !words.isEmpty else { return nil }
    let padded = " \(normalized) "
    let hasWeatherWord = padded.contains(" weather ")
        || padded.contains(" rain ")
        || padded.contains(" raining ")
        || padded.contains(" thunder ")
        || padded.contains(" thunderstorm ")
        || padded.contains(" storm ")
    guard hasWeatherWord,
          [" set ", " make ", " change ", " start ", " stop ", " clear "].contains(where: { padded.contains($0) }) else {
        return nil
    }

    if padded.contains(" clear ") || padded.contains(" stop rain ") || padded.contains(" stop raining ") {
        return AIAgentAction(action: "set_weather", weather: "clear")
    }
    for word in words {
        if let weather = resolveAIAgentWeather(word) {
            return AIAgentAction(action: "set_weather", weather: weather.name)
        }
    }
    return nil
}

private func inferDirectAIAgentSpawnEntityAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    let hasSpawnVerb = [" spawn ", " summon ", " place "].contains { padded.contains($0) }
    let hasCursorTarget = padded.contains(" at cursor ")
        || padded.contains(" at the cursor ")
        || padded.contains(" on cursor ")
        || padded.contains(" on the cursor ")
        || padded.contains(" at crosshair ")
        || padded.contains(" at the crosshair ")
        || padded.contains(" where i am looking ")
        || padded.contains(" where im looking ")
        || padded.contains(" where i m looking ")
    guard hasSpawnVerb, hasCursorTarget else { return nil }

    let words = normalized.split(separator: " ").map(String.init)
    guard let verbIndex = words.firstIndex(where: { ["spawn", "summon", "place"].contains($0) }) else { return nil }
    var entityWords: [String] = []
    let stopWords = Set(["at", "on", "where", "near", "by", "to", "cursor", "crosshair", "there"])
    for word in words[(verbIndex + 1)..<words.count] {
        if !entityWords.isEmpty && stopWords.contains(word) { break }
        entityWords.append(word)
    }
    let noise = Set([
        "a", "an", "the", "some", "mob", "mobs", "animal", "animals",
        "monster", "monsters", "hostile", "friendly",
    ])
    let filtered = entityWords.filter { word in
        !noise.contains(word) && spelledAIAgentNumber(word) == nil && Int(word) == nil
    }
    guard !filtered.isEmpty else { return nil }
    let phrase = filtered.joined(separator: " ")
    guard let entity = resolveAIAgentEntityName(phrase) else { return nil }
    let count = min(AIAgentMaxSpawnCount, max(1, inferDirectAIAgentCount(from: entityWords)))
    return AIAgentAction(action: "spawn_entity", count: count, target: "cursor", entity: entity)
}

private func inferDirectAIAgentGameModeAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    guard padded.contains(" game mode ") || padded.contains(" gamemode ") else { return nil }
    guard [" set ", " change ", " switch ", " make "].contains(where: { padded.contains($0) }) else {
        return nil
    }
    for word in normalized.split(separator: " ").map(String.init) {
        if let resolved = resolveAIAgentGameMode(word) {
            return AIAgentAction(action: "set_gamemode", mode: resolved.value == GameMode.creative ? "creative" : "survival")
        }
    }
    return nil
}

private func inferDirectAIAgentHealAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    guard padded.contains(" heal me ") || padded.contains(" heal player ")
        || padded.contains(" restore my health ") || padded.contains(" restore health ") else { return nil }
    return AIAgentAction(action: "heal_player")
}

private func inferDirectAIAgentEatAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    guard padded.contains(" eat ") || padded.contains(" use food ") || padded.contains(" consume food ") else { return nil }
    guard padded.contains(" selected ") || padded.contains(" held ") || padded.contains(" current ") else { return nil }
    return AIAgentAction(action: "eat_selected_food")
}

private func inferDirectAIAgentBlockUseAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    let hasCursor = padded.contains(" cursor ") || padded.contains(" crosshair ")
        || padded.contains(" looking at ") || padded.contains(" look at ")
    guard hasCursor else { return nil }
    guard [" use ", " toggle ", " open ", " close ", " activate "].contains(where: { padded.contains($0) }) else {
        return nil
    }
    return AIAgentAction(action: "use_block", target: "cursor")
}

private func inferDirectAIAgentBlockBreakAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    let hasCursor = padded.contains(" cursor ") || padded.contains(" crosshair ")
        || padded.contains(" looking at ") || padded.contains(" look at ")
    guard hasCursor else { return nil }
    guard [" break ", " mine ", " destroy ", " remove "].contains(where: { padded.contains($0) }) else {
        return nil
    }
    return AIAgentAction(action: "break_block", target: "cursor")
}

private func inferDirectAIAgentSurfaceTeleportAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    guard padded.contains(" surface ") || padded.contains(" top ") else { return nil }
    guard [" bring ", " teleport ", " move ", " tp "].contains(where: { padded.contains($0) }) else {
        return nil
    }
    return AIAgentAction(action: "teleport_player", target: "surface")
}

private func inferDirectAIAgentClearInventoryAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    guard padded.contains(" inventory ") else { return nil }
    guard padded.contains(" clear ") || padded.contains(" empty ") else { return nil }
    return AIAgentAction(action: "clear_inventory")
}

private func inferDirectAIAgentDifficultyAction(from normalized: String) -> AIAgentAction? {
    let padded = " \(normalized) "
    guard padded.contains(" difficulty ") else { return nil }
    guard [" set ", " change ", " make "].contains(where: { padded.contains($0) }) else { return nil }
    for word in normalized.split(separator: " ").map(String.init) {
        if let resolved = resolveAIAgentDifficulty(word) {
            return AIAgentAction(action: "set_difficulty", value: resolved.name.lowercased())
        }
    }
    return nil
}

private func normalizeAIAgentRequestText(_ raw: String) -> String {
    var out = ""
    for scalar in raw.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == ":" {
            out.unicodeScalars.append(scalar)
        } else {
            out.append(" ")
        }
    }
    return out.split(separator: " ").joined(separator: " ")
}

private func hasInventoryGiveIntent(_ text: String) -> Bool {
    let padded = " \(text) "
    let hasGiveVerb = [" add ", " give ", " create ", " put ", " spawn "].contains { padded.contains($0) }
    let hasInventoryTarget = padded.contains(" inventory ") || padded.contains(" to me ") || padded.contains(" me ")
    return hasGiveVerb && hasInventoryTarget
}

private func firstGiveItemPhraseIndex(_ words: [String]) -> Int? {
    for (i, word) in words.enumerated() {
        if ["add", "give", "create", "spawn"].contains(word) {
            var j = i + 1
            if j < words.count, words[j] == "me" { j += 1 }
            return j < words.count ? j : nil
        }
        if word == "put" {
            return i + 1 < words.count ? i + 1 : nil
        }
    }
    return nil
}

private func inferDirectAIAgentCount(from itemWords: [String], itemId: Int) -> Int {
    var multiplier = 1
    if let first = itemWords.first {
        multiplier = spelledAIAgentNumber(first) ?? Int(first) ?? 1
    }
    if itemWords.contains("stack") || itemWords.contains("stacks") {
        return multiplier * itemDef(itemId).maxStack
    }
    return multiplier
}

private func inferDirectAIAgentCount(from words: [String]) -> Int {
    guard let first = words.first else { return 1 }
    return spelledAIAgentNumber(first) ?? Int(first) ?? 1
}

private func spelledAIAgentNumber(_ word: String) -> Int? {
    [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ][word]
}

public func parseAIAgentAction(from raw: String) throws -> AIAgentAction {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIAgentError.emptyResponse }
    guard let json = extractFirstJSONObject(trimmed) else { throw AIAgentError.malformedJSON }
    guard let data = json.data(using: .utf8) else { throw AIAgentError.malformedJSON }
    guard data.count <= AIAgentMaxModelJSONBytes else { throw AIAgentError.responseTooLarge }
    do {
        return try JSONDecoder().decode(AIAgentAction.self, from: data)
    } catch {
        throw AIAgentError.malformedJSON
    }
}

public func aiAgentActionName(fromToolName raw: String) -> String? {
    let normalized = normalizeAIAgentName(raw)
    var candidates = [normalized]
    if normalized.hasPrefix("pebble_") {
        candidates.append(String(normalized.dropFirst("pebble_".count)))
    }
    if let last = raw.split(separator: ".").last {
        let lastName = normalizeAIAgentName(String(last))
        candidates.append(lastName)
        if lastName.hasPrefix("pebble_") {
            candidates.append(String(lastName.dropFirst("pebble_".count)))
        }
    }
    for candidate in candidates where aiAgentSkillActionNames.contains(candidate) {
        return candidate
    }
    return nil
}

public func parseAIAgentAction(fromToolCallName name: String, argumentsJSONData data: Data) throws -> AIAgentAction {
    guard data.count <= AIAgentMaxModelJSONBytes else { throw AIAgentError.responseTooLarge }
    guard let actionName = aiAgentActionName(fromToolName: name) else {
        throw AIAgentError.unsupportedAction(name)
    }
    do {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAgentError.malformedJSON
        }
        if object["action"] == nil {
            object["action"] = actionName
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              encoded.count <= AIAgentMaxModelJSONBytes else {
            throw AIAgentError.responseTooLarge
        }
        return try JSONDecoder().decode(AIAgentAction.self, from: encoded)
    } catch let error as AIAgentError {
        throw error
    } catch {
        throw AIAgentError.malformedJSON
    }
}

private func extractFirstJSONObject(_ text: String) -> String? {
    var start: String.Index?
    var depth = 0
    var inString = false
    var escaped = false

    for i in text.indices {
        let ch = text[i]
        if inString {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString = false
            }
            continue
        }
        if ch == "\"" {
            inString = true
        } else if ch == "{" {
            if depth == 0 { start = i }
            depth += 1
        } else if ch == "}" {
            guard depth > 0 else { return nil }
            depth -= 1
            if depth == 0, let start {
                return String(text[start...i])
            }
        }
    }
    return nil
}

public func sanitizeAIAgentChatMessage(_ raw: String?, fallback: String) -> String {
    let source = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text = source.isEmpty ? fallback : source
    var out = ""
    for scalar in text.unicodeScalars {
        if scalar.value >= 32 && scalar.value != 127 && scalar.value != 0x00A7 {
            out.unicodeScalars.append(scalar)
        } else if scalar.value == 10 || scalar.value == 13 || scalar.value == 9 {
            out.append(" ")
        }
        if out.count >= 240 { break }
    }
    return out.isEmpty ? fallback : out
}

public func aiCursorPlacementPosition(_ hit: RaycastHit, in world: World) -> (x: Int, y: Int, z: Int) {
    var x = hit.x
    var y = hit.y
    var z = hit.z
    if REPLACEABLE[hit.cell >> 4] == 0 {
        x += DIR_X[hit.face]
        y += DIR_Y[hit.face]
        z += DIR_Z[hit.face]
    }
    return (x, y, z)
}

private struct AIAgentHolePos: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

private struct AIAgentHoleSeed {
    let x: Int
    let y: Int
    let z: Int
    let topY: Int
}

public func fillAIAgentHoleInFront(world: World, player: Player, cursor: RaycastHit?,
                                   blockId: UInt16) throws -> AIAgentHoleFillResult {
    guard blockId != 0, blockDefs[Int(blockId)].solid else {
        let name = blockId == 0 ? "air" : blockDefs[Int(blockId)].name
        throw AIAgentError.itemNotPlaceable(name)
    }
    guard let seed = findAIAgentHoleSeed(world: world, player: player, cursor: cursor) else {
        throw AIAgentError.missingHoleTarget
    }
    let cells = try collectAIAgentHoleCells(world: world, seed: seed)
    guard !cells.isEmpty else { throw AIAgentError.missingHoleTarget }
    let fillCell = Int(cell(blockId, 0))
    for p in cells.sorted(by: {
        if $0.y != $1.y { return $0.y < $1.y }
        if $0.z != $1.z { return $0.z < $1.z }
        return $0.x < $1.x
    }) {
        world.setBlock(p.x, p.y, p.z, fillCell)
    }
    return AIAgentHoleFillResult(
        seedX: seed.x,
        seedY: seed.y,
        seedZ: seed.z,
        blockId: blockId,
        filledBlocks: cells.count)
}

private func findAIAgentHoleSeed(world: World, player: Player, cursor: RaycastHit?) -> AIAgentHoleSeed? {
    let groundY = aiAgentPlayerGroundY(world: world, player: player)
    if let cursor {
        let placement = aiCursorPlacementPosition(cursor, in: world)
        let candidates = [(placement.x, placement.z), (cursor.x, cursor.z)]
        for (x, z) in candidates {
            for y in aiAgentHoleTopCandidates(around: groundY, in: world) {
                if isAIAgentHoleFillCandidate(world: world, x: x, y: y, z: z, topY: y) {
                    return AIAgentHoleSeed(x: x, y: y, z: z, topY: y)
                }
            }
        }
    }

    let fx = -detSin(player.yaw)
    let fz = detCos(player.yaw)
    let lx = -fz
    let lz = fx
    var checked = Set<AIAgentHolePos>()
    let offsets = aiAgentLateralSearchOffsets(AIAgentHoleFillLateralSearch)
    for distance in 1...AIAgentHoleFillSearchDistance {
        for offset in offsets {
            let x = ifloor(player.x + fx * Double(distance) + lx * Double(offset))
            let z = ifloor(player.z + fz * Double(distance) + lz * Double(offset))
            for y in aiAgentHoleTopCandidates(around: groundY, in: world) {
                let pos = AIAgentHolePos(x: x, y: y, z: z)
                guard checked.insert(pos).inserted else { continue }
                if isAIAgentHoleFillCandidate(world: world, x: x, y: y, z: z, topY: y) {
                    return AIAgentHoleSeed(x: x, y: y, z: z, topY: y)
                }
            }
        }
    }
    return nil
}

private func aiAgentPlayerGroundY(world: World, player: Player) -> Int {
    let x = ifloor(player.x)
    let z = ifloor(player.z)
    let feetY = ifloor(player.y)
    let minY = max(world.info.minY, feetY - 6)
    for y in stride(from: feetY, through: minY, by: -1) {
        let id = world.getBlockId(x, y, z)
        if id != 0 && blockDefs[id].solid {
            return y
        }
    }
    return max(world.info.minY, feetY - 1)
}

private func aiAgentHoleTopCandidates(around groundY: Int, in world: World) -> [Int] {
    var result: [Int] = []
    for dy in [0, -1, 1, -2, 2] {
        let y = groundY + dy
        guard y >= world.info.minY, y < world.info.minY + world.info.height else { continue }
        if !result.contains(y) { result.append(y) }
    }
    return result
}

private func aiAgentLateralSearchOffsets(_ radius: Int) -> [Int] {
    var offsets = [0]
    guard radius > 0 else { return offsets }
    for i in 1...radius {
        offsets.append(-i)
        offsets.append(i)
    }
    return offsets
}

private func isAIAgentHoleFillCandidate(world: World, x: Int, y: Int, z: Int, topY: Int) -> Bool {
    guard y == topY,
          y >= world.info.minY,
          y < world.info.minY + world.info.height,
          world.isLoadedAt(x, z),
          isAIAgentHoleFillCell(world.getBlock(x, y, z)),
          hasAIAgentLevelingRim(world: world, x: x, y: topY, z: z) else { return false }
    let minY = max(world.info.minY, topY - AIAgentHoleFillMaxDepth + 1)
    var currentY = topY
    while currentY >= minY {
        let cell = world.getBlock(x, currentY, z)
        if !isAIAgentHoleFillCell(cell) {
            return blockDefs[cell >> 4].solid
        }
        currentY -= 1
    }
    return false
}

private func collectAIAgentHoleCells(world: World, seed: AIAgentHoleSeed) throws -> [AIAgentHolePos] {
    let minY = max(world.info.minY, seed.topY - AIAgentHoleFillMaxDepth + 1)
    let maxRadius2 = AIAgentHoleFillMaxHorizontalRadius * AIAgentHoleFillMaxHorizontalRadius
    var seen = Set<AIAgentHolePos>()
    var queue = [AIAgentHolePos(x: seed.x, y: seed.y, z: seed.z)]
    var cursor = 0
    var topOpening: [AIAgentHolePos] = []
    seen.insert(queue[0])

    while cursor < queue.count {
        let p = queue[cursor]
        cursor += 1
        guard p.y == seed.topY else { continue }
        let dx = p.x - seed.x
        let dz = p.z - seed.z
        guard dx * dx + dz * dz <= maxRadius2,
              world.isLoadedAt(p.x, p.z),
              isAIAgentHoleFillCell(world.getBlock(p.x, p.y, p.z)) else { continue }
        topOpening.append(p)
        if topOpening.count > AIAgentHoleFillMaxBlocks {
            throw AIAgentError.holeFillTooLarge(topOpening.count, AIAgentHoleFillMaxBlocks)
        }
        for dir in HORIZONTALS {
            let next = AIAgentHolePos(
                x: p.x + DIR_X[dir],
                y: p.y,
                z: p.z + DIR_Z[dir])
            if !seen.contains(next) {
                seen.insert(next)
                queue.append(next)
            }
        }
    }

    var cells: [AIAgentHolePos] = []
    for top in topOpening.sorted(by: {
        if $0.z != $1.z { return $0.z < $1.z }
        return $0.x < $1.x
    }) {
        var column: [AIAgentHolePos] = []
        var y = seed.topY
        var hasSolidFloor = false
        while y >= minY {
            let cell = world.getBlock(top.x, y, top.z)
            if !isAIAgentHoleFillCell(cell) {
                hasSolidFloor = blockDefs[cell >> 4].solid
                break
            }
            column.append(AIAgentHolePos(x: top.x, y: y, z: top.z))
            y -= 1
        }
        guard hasSolidFloor else { continue }
        if cells.count + column.count > AIAgentHoleFillMaxBlocks {
            throw AIAgentError.holeFillTooLarge(cells.count + column.count, AIAgentHoleFillMaxBlocks)
        }
        cells.append(contentsOf: column)
    }
    return cells
}

private func isAIAgentHoleFillCell(_ cell: Int) -> Bool {
    let id = cell >> 4
    if id == 0 { return true }
    if id == Int(B.water) || id == Int(B.lava) { return false }
    return REPLACEABLE[id] != 0
}

private func hasAIAgentLevelingRim(world: World, x: Int, y: Int, z: Int) -> Bool {
    for dir in HORIZONTALS {
        if isAIAgentLevelingRimBlock(world.getBlockId(x + DIR_X[dir], y, z + DIR_Z[dir])) {
            return true
        }
    }
    return false
}

private func isAIAgentLevelingRimBlock(_ id: Int) -> Bool {
    guard id > 0 && id < blockDefs.count else { return false }
    let name = blockDefs[id].name
    return name == "dirt"
        || name == "grass_block"
        || name == "coarse_dirt"
        || name == "rooted_dirt"
        || name == "podzol"
        || name == "mycelium"
        || name == "farmland"
        || name == "mud"
        || name == "muddy_mangrove_roots"
}

private struct AIAgentBiomeColumn: Hashable {
    let x: Int
    let z: Int
}

private struct AIAgentBiomeChunkCoord: Hashable {
    let cx: Int
    let cz: Int
}

private let aiAgentBiomeReworkNaturalBlocks = Set([
    "stone", "deepslate", "granite", "diorite", "andesite", "tuff", "calcite",
    "dripstone_block", "grass_block", "dirt", "coarse_dirt", "rooted_dirt",
    "podzol", "mycelium", "mud", "muddy_mangrove_roots", "clay", "gravel",
    "sand", "red_sand", "sandstone", "red_sandstone", "snow", "snow_block",
    "ice", "packed_ice", "blue_ice", "water", "lava",
])

public func reworkAIAgentCurrentBiome(world: World, player: Player,
                                      profile: AIAgentBiomeReworkProfile) throws -> AIAgentBiomeReworkResult {
    guard world.dim == .overworld else {
        throw AIAgentError.unsupportedBiomeRework("Only Overworld terrain can be reworked")
    }
    let px = ifloor(player.x)
    let pz = ifloor(player.z)
    let sampleY = aiAgentBiomeReworkSampleY(world: world, player: player)
    guard world.isLoadedAt(px, pz) else {
        throw AIAgentError.unloadedTarget(px, sampleY, pz)
    }
    guard let sourceBiome = Biome(rawValue: world.biomeAt(px, sampleY, pz)) else {
        throw AIAgentError.missingBiomeReworkTarget
    }
    let columns = collectAIAgentBiomeReworkColumns(
        world: world,
        centerX: px,
        centerZ: pz,
        sampleY: sampleY,
        sourceBiome: sourceBiome.rawValue)
    guard !columns.isEmpty else { throw AIAgentError.missingBiomeReworkTarget }

    let centerSurface = aiAgentNaturalSurfaceY(world: world, x: px, z: pz)
        ?? max(world.info.seaLevel + 1, world.surfaceY(px, pz) - 1)
    let targetBiome = profile.targetBiome
    let biomeCells = setAIAgentBiomeColumns(world: world, columns: columns, biome: targetBiome)
    var terrainWrites = 0
    var oreWrites = 0

    for column in columns.sorted(by: {
        if $0.z != $1.z { return $0.z < $1.z }
        return $0.x < $1.x
    }) {
        if terrainWrites < AIAgentBiomeReworkMaxTerrainWrites {
            let remaining = AIAgentBiomeReworkMaxTerrainWrites - terrainWrites
            terrainWrites += reworkAIAgentBiomeColumn(
                world: world,
                x: column.x,
                z: column.z,
                centerX: px,
                centerZ: pz,
                centerSurface: centerSurface,
                maxWrites: remaining)
        }
        if oreWrites < AIAgentBiomeReworkMaxOreWrites {
            let remaining = AIAgentBiomeReworkMaxOreWrites - oreWrites
            oreWrites += enrichAIAgentBiomeColumnResources(
                world: world,
                x: column.x,
                z: column.z,
                maxWrites: remaining)
        }
        if terrainWrites >= AIAgentBiomeReworkMaxTerrainWrites,
           oreWrites >= AIAgentBiomeReworkMaxOreWrites {
            break
        }
    }

    let playerSurface = world.surfaceY(px, pz)
    if Double(playerSurface) + 0.05 > player.y {
        player.setPos(player.x, Double(playerSurface) + 0.05, player.z)
    }
    return AIAgentBiomeReworkResult(
        sourceBiome: sourceBiome,
        targetBiome: targetBiome,
        columns: columns.count,
        terrainBlocks: terrainWrites,
        resourceBlocks: oreWrites,
        biomeCells: biomeCells)
}

private func aiAgentBiomeReworkSampleY(world: World, player: Player) -> Int {
    let y = ifloor(player.y)
    return max(world.info.minY, min(world.info.minY + world.info.height - 1, y))
}

private func collectAIAgentBiomeReworkColumns(world: World, centerX: Int, centerZ: Int,
                                              sampleY: Int, sourceBiome: Int) -> [AIAgentBiomeColumn] {
    let radius2 = AIAgentBiomeReworkRadius * AIAgentBiomeReworkRadius
    var seen = Set<AIAgentBiomeColumn>()
    var queue = [AIAgentBiomeColumn(x: centerX, z: centerZ)]
    var result: [AIAgentBiomeColumn] = []
    var cursor = 0
    seen.insert(queue[0])

    while cursor < queue.count, result.count < AIAgentBiomeReworkMaxColumns {
        let column = queue[cursor]
        cursor += 1
        let dx = column.x - centerX
        let dz = column.z - centerZ
        guard dx * dx + dz * dz <= radius2,
              world.isLoadedAt(column.x, column.z),
              world.biomeAt(column.x, sampleY, column.z) == sourceBiome else { continue }
        result.append(column)
        for dir in HORIZONTALS {
            let next = AIAgentBiomeColumn(
                x: column.x + DIR_X[dir],
                z: column.z + DIR_Z[dir])
            if seen.insert(next).inserted {
                queue.append(next)
            }
        }
    }
    return result
}

private func setAIAgentBiomeColumns(world: World, columns: [AIAgentBiomeColumn], biome: Biome) -> Int {
    var changedCells = 0
    var touchedChunks = Set<AIAgentBiomeChunkCoord>()
    var touchedQuartColumns = Set<String>()
    for column in columns {
        let cx = floorDiv(column.x, CHUNK_W)
        let cz = floorDiv(column.z, CHUNK_W)
        let qx = posMod(column.x, CHUNK_W) >> 2
        let qz = posMod(column.z, CHUNK_W) >> 2
        let key = "\(cx),\(cz),\(qx),\(qz)"
        guard touchedQuartColumns.insert(key).inserted,
              let chunk = world.getChunk(cx, cz) else { continue }
        let qyCount = chunk.biomes.count / 16
        for qy in 0..<qyCount {
            let idx = (qy * 4 + qz) * 4 + qx
            if Int(chunk.biomes[idx]) != biome.rawValue {
                chunk.setBiome(qx, qy, qz, biome.rawValue)
                changedCells += 1
            }
        }
        touchedChunks.insert(AIAgentBiomeChunkCoord(cx: cx, cz: cz))
    }
    for coord in touchedChunks.sorted(by: {
        if $0.cx != $1.cx { return $0.cx < $1.cx }
        return $0.cz < $1.cz
    }) {
        guard let chunk = world.getChunk(coord.cx, coord.cz) else { continue }
        chunk.modified = true
        chunk.markAllDirty()
        for sy in 0..<chunk.sections {
            world.hooks.onSectionDirty(coord.cx, coord.cz, sy)
        }
    }
    return changedCells
}

private func reworkAIAgentBiomeColumn(world: World, x: Int, z: Int, centerX: Int, centerZ: Int,
                                      centerSurface: Int, maxWrites: Int) -> Int {
    guard maxWrites > 0,
          let oldSurface = aiAgentNaturalSurfaceY(world: world, x: x, z: z) else { return 0 }
    let targetY = aiAgentRollingHillTargetY(
        world: world,
        x: x,
        z: z,
        centerX: centerX,
        centerZ: centerZ,
        centerSurface: centerSurface,
        oldSurface: oldSurface)
    guard !aiAgentColumnHasProtectedBlocks(
        world: world,
        x: x,
        z: z,
        y0: min(oldSurface, targetY) - 2,
        y1: max(oldSurface, targetY) + 8) else { return 0 }

    var writes = 0
    func setIfAllowed(_ y: Int, _ block: UInt16) {
        guard writes < maxWrites,
              y >= world.info.minY,
              y < world.info.minY + world.info.height,
              canAIAgentRewriteTerrainBlock(world: world, x: x, y: y, z: z),
              world.getBlock(x, y, z) != Int(cell(block)) else { return }
        world.setBlock(x, y, z, Int(cell(block)))
        writes += 1
    }
    func clearIfAllowed(_ y: Int) {
        guard writes < maxWrites,
              y >= world.info.minY,
              y < world.info.minY + world.info.height,
              canAIAgentRewriteTerrainBlock(world: world, x: x, y: y, z: z),
              world.getBlock(x, y, z) != 0 else { return }
        world.setBlock(x, y, z, 0)
        writes += 1
    }

    if targetY < oldSurface {
        let topClear = min(world.info.minY + world.info.height - 1, oldSurface + 4)
        if targetY + 1 <= topClear {
            for y in (targetY + 1)...topClear { clearIfAllowed(y) }
        }
    } else if targetY > oldSurface {
        for y in (oldSurface + 1)...targetY {
            let block = aiAgentBiomeHillBlock(forY: y, surfaceY: targetY)
            setIfAllowed(y, block)
        }
    }

    let capBase = max(world.info.minY, targetY - 4)
    if capBase <= targetY {
        for y in capBase...targetY {
            setIfAllowed(y, aiAgentBiomeHillBlock(forY: y, surfaceY: targetY))
        }
    }
    let decorTop = min(world.info.minY + world.info.height - 1, targetY + 2)
    if targetY + 1 <= decorTop {
        for y in (targetY + 1)...decorTop {
            let id = world.getBlockId(x, y, z)
            if isAIAgentBiomeReworkNaturalDecoration(id) {
                clearIfAllowed(y)
            }
        }
    }
    if world.getBlockId(x, targetY + 1, z) == 0,
       hashFloat2(world.seed, x, z, 0xB10B_10E5) < 0.18 {
        setIfAllowed(targetY + 1, B.short_grass)
    }
    return writes
}

private func enrichAIAgentBiomeColumnResources(world: World, x: Int, z: Int, maxWrites: Int) -> Int {
    guard maxWrites > 0,
          let surface = aiAgentNaturalSurfaceY(world: world, x: x, z: z) else { return 0 }
    let maxY = min(surface - 6, 160, world.info.minY + world.info.height - 1)
    let minY = max(world.info.minY + 4, -64)
    guard minY <= maxY else { return 0 }
    var writes = 0
    var y = minY + posMod(x &+ z, 4)
    while y <= maxY, writes < maxWrites {
        let id = world.getBlockId(x, y, z)
        if let ore = aiAgentRichResourceOreCell(world: world, x: x, y: y, z: z, baseBlockId: id),
           world.getBlockEntity(x, y, z) == nil {
            world.setBlock(x, y, z, Int(ore))
            writes += 1
        }
        y += 4
    }
    return writes
}

private func aiAgentNaturalSurfaceY(world: World, x: Int, z: Int) -> Int? {
    guard world.isLoadedAt(x, z) else { return nil }
    let top = world.info.minY + world.info.height - 1
    let start = min(top, max(world.heightAt(x, z) + 8, world.info.seaLevel + 32))
    for y in stride(from: start, through: world.info.minY, by: -1) {
        let id = world.getBlockId(x, y, z)
        if isAIAgentBiomeReworkNaturalSolid(id) {
            return y
        }
    }
    return nil
}

private func aiAgentRollingHillTargetY(world: World, x: Int, z: Int, centerX: Int, centerZ: Int,
                                       centerSurface: Int, oldSurface: Int) -> Int {
    let dx = Double(x - centerX)
    let dz = Double(z - centerZ)
    let distance = (dx * dx + dz * dz).squareRoot()
    let edgeBlend = clampD((Double(AIAgentBiomeReworkRadius) - distance) / 8.0, 0, 1)
    let broad = aiAgentSmoothHash2(world.seed, x, z, cellSize: 24, salt: 0xA1A1_4001) - 0.5
    let small = aiAgentSmoothHash2(world.seed, x, z, cellSize: 10, salt: 0xA1A1_4002) - 0.5
    let radialLift = max(0, 1 - distance / Double(AIAgentBiomeReworkRadius)) * 2.5
    let rolling = broad * 16.0 + small * 7.0 + radialLift
    let profileTarget = Double(centerSurface) + rolling
    let blended = Double(oldSurface) * (1 - edgeBlend) + profileTarget * edgeBlend
    let lower = max(world.info.minY + 8, centerSurface - 10, world.info.seaLevel - 6)
    let upper = min(world.info.minY + world.info.height - 8, centerSurface + 24, world.info.seaLevel + 34)
    return aiAgentClampInt(Int(detRound(blended)), lower, upper)
}

private func aiAgentSmoothHash2(_ seed: UInt32, _ x: Int, _ z: Int, cellSize: Int, salt: UInt32) -> Double {
    let gx = floorDiv(x, cellSize)
    let gz = floorDiv(z, cellSize)
    let tx = Double(posMod(x, cellSize)) / Double(cellSize)
    let tz = Double(posMod(z, cellSize)) / Double(cellSize)
    let sx = tx * tx * (3 - 2 * tx)
    let sz = tz * tz * (3 - 2 * tz)
    let a = hashFloat2(seed, gx, gz, salt)
    let b = hashFloat2(seed, gx + 1, gz, salt)
    let c = hashFloat2(seed, gx, gz + 1, salt)
    let d = hashFloat2(seed, gx + 1, gz + 1, salt)
    let ab = a + (b - a) * sx
    let cd = c + (d - c) * sx
    return ab + (cd - ab) * sz
}

private func aiAgentBiomeHillBlock(forY y: Int, surfaceY: Int) -> UInt16 {
    if y == surfaceY { return B.grass_block }
    if y >= surfaceY - 3 { return B.dirt }
    return y < 0 ? B.deepslate : B.stone
}

private func aiAgentColumnHasProtectedBlocks(world: World, x: Int, z: Int, y0: Int, y1: Int) -> Bool {
    let lo = max(world.info.minY, y0)
    let hi = min(world.info.minY + world.info.height - 1, y1)
    guard lo <= hi else { return false }
    for y in lo...hi {
        if world.getBlockEntity(x, y, z) != nil { return true }
        let id = world.getBlockId(x, y, z)
        if id == 0 || isAIAgentBiomeReworkNaturalSolid(id) || isAIAgentBiomeReworkNaturalDecoration(id) {
            continue
        }
        return true
    }
    return false
}

private func canAIAgentRewriteTerrainBlock(world: World, x: Int, y: Int, z: Int) -> Bool {
    if world.getBlockEntity(x, y, z) != nil { return false }
    let id = world.getBlockId(x, y, z)
    return id == 0 || isAIAgentBiomeReworkNaturalSolid(id) || isAIAgentBiomeReworkNaturalDecoration(id)
}

private func isAIAgentBiomeReworkNaturalSolid(_ id: Int) -> Bool {
    guard id > 0 && id < blockDefs.count else { return false }
    let name = blockDefs[id].name
    return aiAgentBiomeReworkNaturalBlocks.contains(name)
        || name.hasSuffix("_ore")
}

private func isAIAgentBiomeReworkNaturalDecoration(_ id: Int) -> Bool {
    guard id > 0 && id < blockDefs.count else { return false }
    let def = blockDefs[id]
    if def.replaceable { return true }
    switch def.name {
    case "short_grass", "fern", "tall_grass", "large_fern",
         "dandelion", "poppy", "azure_bluet", "oxeye_daisy", "cornflower", "allium",
         "red_tulip", "orange_tulip", "white_tulip", "pink_tulip":
        return true
    default:
        return false
    }
}

private func aiAgentRichResourceOreCell(world: World, x: Int, y: Int, z: Int,
                                        baseBlockId: Int) -> UInt16? {
    guard baseBlockId == Int(B.stone) || baseBlockId == Int(B.deepslate)
            || baseBlockId == Int(B.tuff) || baseBlockId == Int(B.andesite)
            || baseBlockId == Int(B.granite) || baseBlockId == Int(B.diorite) else {
        return nil
    }
    let r = hashFloat3(world.seed, x, y, z, 0xA17E_0E55)
    let deep = baseBlockId == Int(B.deepslate) || y < 0
    func ore(_ stone: UInt16, _ deepslate: UInt16) -> UInt16 {
        cell(deep ? deepslate : stone)
    }
    if y <= 16 && r < 0.012 { return ore(B.diamond_ore, B.deepslate_diamond_ore) }
    if y >= -16 && y <= 160 && r < 0.024 { return ore(B.emerald_ore, B.deepslate_emerald_ore) }
    if y <= 15 && r < 0.040 { return ore(B.redstone_ore, B.deepslate_redstone_ore) }
    if y <= 64 && r < 0.055 { return ore(B.lapis_ore, B.deepslate_lapis_ore) }
    if y <= 80 && r < 0.075 { return ore(B.gold_ore, B.deepslate_gold_ore) }
    if y >= -16 && y <= 112 && r < 0.115 { return ore(B.copper_ore, B.deepslate_copper_ore) }
    if y <= 160 && r < 0.155 { return ore(B.iron_ore, B.deepslate_iron_ore) }
    if y <= 192 && r < 0.195 { return ore(B.coal_ore, B.deepslate_coal_ore) }
    return nil
}

private func aiAgentClampInt(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
    min(max(value, lo), hi)
}

public func resolveAIAgentTemplateBlockSelector(_ raw: String) -> TemplateBlockSelector? {
    let normalized = normalizeAIAgentName(cleanedAIAgentBlockPhrase(raw))
    if ["wood", "wooden", "wood_blocks", "wooden_blocks", "woods"].contains(normalized) {
        return .woodFamily
    }
    guard let block = resolveAIAgentBlockID(raw), block != 0 else { return nil }
    return .exact(block)
}

public func executeAIAgentTemplateAction(_ action: AIAgentAction,
                                         loadTemplate: (String) throws -> ObjectTemplate?,
                                         saveTemplate: (ObjectTemplate) throws -> Bool) throws -> AIAgentExecutionResult {
    let kind = normalizeAIAgentName(action.action)
    switch kind {
    case "replace_template_blocks", "change_template_blocks", "edit_template_blocks":
        guard let templateName = action.template ?? action.name else { throw AIAgentError.missingTemplateName }
        guard let sourceRaw = action.fromBlock ?? action.block,
              let replacementRaw = action.toBlock ?? action.item else {
            throw AIAgentError.missingBlockReplacement
        }
        guard let selector = resolveAIAgentTemplateBlockSelector(sourceRaw) else {
            throw AIAgentError.unknownBlock(sourceRaw)
        }
        guard let replacement = resolveAIAgentBlockID(replacementRaw), replacement != 0 else {
            throw AIAgentError.unknownBlock(replacementRaw)
        }
        guard let template = try loadTemplate(templateName) else {
            throw AIAgentError.unknownTemplate(templateName)
        }
        let result = try replacingObjectTemplateBlocks(template, matching: selector, with: replacement)
        if result.replacedBlocks > 0 {
            guard try saveTemplate(result.template) else {
                throw AIAgentError.templateWriteFailed(result.template.name)
            }
        }
        let fallback = result.replacedBlocks == 0
            ? "No matching \(result.fromDescription) found in \"\(result.template.name)\"."
            : "Updated \"\(result.template.name)\": replaced \(result.replacedBlocks) \(result.fromDescription) with \(result.toBlockName)."
        return AIAgentExecutionResult(
            message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
            changedWorld: result.replacedBlocks > 0)

    case "create_template", "create_object_template":
        guard let templateName = action.template ?? action.name else { throw AIAgentError.missingTemplateName }
        let generated = try generatedObjectTemplate(
            named: templateName,
            kind: action.kind ?? "object",
            requestedLength: action.length,
            style: action.style ?? action.message ?? "")
        guard try saveTemplate(generated) else {
            throw AIAgentError.templateWriteFailed(generated.name)
        }
        let fallback = "Created object template \"\(generated.name)\" — \(generated.blocks.count) blocks, \(generated.sizeX)x\(generated.sizeY)x\(generated.sizeZ)."
        return AIAgentExecutionResult(
            message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
            changedWorld: true)

    default:
        throw AIAgentError.unsupportedTemplateAction(action.action)
    }
}

public func executeAIAgentAction(_ action: AIAgentAction, world: World, player: Player,
                                 cursor: RaycastHit?,
                                 openScreen: @escaping (String, ScreenData?) -> Void = { _, _ in },
                                 advance: @escaping (String) -> Void = { _ in },
                                 persistPlayerState: @escaping () -> Void = {},
                                 setDifficulty: ((Int) -> Void)? = nil,
                                 setGameRule: ((String, Double) -> Void)? = nil) throws -> AIAgentExecutionResult {
    let kind = normalizeAIAgentName(action.action)
    let interactCtx = InteractCtx(
        world: world,
        player: player,
        openScreen: openScreen,
        advance: advance,
        persistPlayerState: persistPlayerState)
    switch kind {
    case "say", "reply", "none":
        let message = sanitizeAIAgentChatMessage(action.message, fallback: "I inspected the current game state.")
        return AIAgentExecutionResult(message: message, changedWorld: false)

    case "give_item", "give":
        guard let rawItem = action.item ?? action.block else { throw AIAgentError.missingItem }
        guard let itemId = resolveAIAgentItemID(rawItem) else { throw AIAgentError.unknownItem(rawItem) }
        let count = min(AIAgentMaxGiveCount, max(1, action.count ?? 1))
        var remaining = count
        var given = 0
        while remaining > 0 {
            let take = min(remaining, itemDef(itemId).maxStack)
            let stack = ItemStack(itemId, take)
            if !player.give(stack) { break }
            let accepted = take - stack.count
            given += accepted
            remaining -= accepted
            if accepted <= 0 { break }
        }
        guard given > 0 else { throw AIAgentError.inventoryFull(itemDef(itemId).name) }
        let fallback = "Gave \(given) \(itemDef(itemId).displayName)"
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "place_block", "place":
        try requireAIAgentTarget(action, expected: "cursor")
        guard let rawBlock = action.block ?? action.item else { throw AIAgentError.missingItem }
        guard let blockId = resolveAIAgentBlockID(rawBlock), blockId != 0 else {
            throw AIAgentError.itemNotPlaceable(rawBlock)
        }
        guard let cursor else { throw AIAgentError.missingCursorTarget }
        let target = aiCursorPlacementPosition(cursor, in: world)
        guard target.y >= world.info.minY && target.y < world.info.minY + world.info.height else {
            throw AIAgentError.targetOutOfWorld(target.x, target.y, target.z)
        }
        guard world.isLoadedAt(target.x, target.z) else {
            throw AIAgentError.unloadedTarget(target.x, target.y, target.z)
        }
        let itemId = placeableItemID(for: blockId) ?? resolveAIAgentItemID(rawBlock)
        guard let itemId else { throw AIAgentError.itemNotPlaceable(rawBlock) }
        let slot = player.selectedSlot
        let original = player.inventory[slot]?.copy()
        let temp = ItemStack(itemId, 1)
        player.inventory[slot] = temp
        defer { player.inventory[slot] = original }

        let ok = placeBlock(interactCtx, cursor, Int(blockId), temp)
        guard ok else { throw AIAgentError.placementFailed(blockDefs[Int(blockId)].name) }
        let fallback = "Placed \(blockDefs[Int(blockId)].displayName) at \(target.x) \(target.y) \(target.z)"
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "set_block_at_cursor", "setblock_cursor", "replace_block_at_cursor":
        try requireAIAgentTarget(action, expected: "cursor")
        guard let rawBlock = action.block ?? action.item else { throw AIAgentError.missingItem }
        guard let blockId = resolveAIAgentBlockOrAir(rawBlock) else { throw AIAgentError.unknownBlock(rawBlock) }
        guard let cursor else { throw AIAgentError.missingCursorTarget }
        try validateAIAgentBlockTarget(world: world, player: player, x: cursor.x, y: cursor.y, z: cursor.z)
        let newCell = blockId == 0 ? 0 : Int(cell(blockId, 0))
        let old = world.setBlock(cursor.x, cursor.y, cursor.z, newCell)
        let changed = old != newCell
        let blockName = blockId == 0 ? "Air" : blockDefs[Int(blockId)].displayName
        let fallback = "Set cursor block to \(blockName) at \(cursor.x) \(cursor.y) \(cursor.z)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: changed)

    case "break_block", "mine_block", "destroy_block":
        try requireAIAgentTarget(action, expected: "cursor")
        guard let cursor else { throw AIAgentError.missingCursorTarget }
        try validateAIAgentBlockTarget(world: world, player: player, x: cursor.x, y: cursor.y, z: cursor.z)
        let id = world.getBlockId(cursor.x, cursor.y, cursor.z)
        guard id != 0 else { throw AIAgentError.blockBreakFailed("air") }
        let blockName = blockDefs[id].displayName
        finishBreaking(interactCtx, cursor.x, cursor.y, cursor.z)
        let fallback = "Broke \(blockName) at \(cursor.x) \(cursor.y) \(cursor.z)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "use_block", "toggle_block", "open_block", "activate_block":
        try requireAIAgentTarget(action, expected: "cursor")
        guard let cursor else { throw AIAgentError.missingCursorTarget }
        guard world.isLoadedAt(cursor.x, cursor.z) else {
            throw AIAgentError.unloadedTarget(cursor.x, cursor.y, cursor.z)
        }
        guard cursor.y >= world.info.minY && cursor.y < world.info.minY + world.info.height else {
            throw AIAgentError.targetOutOfWorld(cursor.x, cursor.y, cursor.z)
        }
        guard useBlock(interactCtx, cursor) else {
            throw AIAgentError.blockUseFailed(blockName(cursor.cell >> 4))
        }
        let fallback = "Used \(blockName(cursor.cell >> 4)) at \(cursor.x) \(cursor.y) \(cursor.z)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "fill_hole", "fill_hole_in_front":
        try requireAIAgentTarget(action, expected: "front")
        guard let rawBlock = action.block ?? action.item else { throw AIAgentError.missingItem }
        guard let blockId = resolveAIAgentBlockID(rawBlock), blockId != 0 else {
            throw AIAgentError.itemNotPlaceable(rawBlock)
        }
        let result = try fillAIAgentHoleInFront(world: world, player: player, cursor: cursor, blockId: blockId)
        let fallback = "Filled \(result.filledBlocks) blocks with \(blockDefs[Int(blockId)].displayName)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: result.filledBlocks > 0)

    case "fill_region", "fill_box", "fill_cube":
        try requireAIAgentTarget(action, expected: "cursor")
        guard let rawBlock = action.block ?? action.item else { throw AIAgentError.missingItem }
        guard let blockId = resolveAIAgentBlockOrAir(rawBlock) else { throw AIAgentError.unknownBlock(rawBlock) }
        guard let cursor else { throw AIAgentError.missingCursorTarget }
        let target = aiCursorPlacementPosition(cursor, in: world)
        let result = try fillAIAgentRegion(world: world, player: player, center: target,
                                           radius: action.radius ?? action.count ?? 0,
                                           blockId: blockId)
        let blockName = blockId == 0 ? "Air" : blockDefs[Int(blockId)].displayName
        let fallback = "Filled \(result) blocks with \(blockName)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: result > 0)

    case "rework_biome", "change_biome", "terraform_biome", "reshape_biome":
        let rawProfile = action.profile ?? action.kind ?? action.value ?? action.style
        guard let profile = resolveAIAgentBiomeReworkProfile(rawProfile) else {
            throw AIAgentError.unsupportedBiomeRework(rawProfile ?? "")
        }
        let result = try reworkAIAgentCurrentBiome(world: world, player: player, profile: profile)
        let fallback = "Reworked \(singleBiomeDisplayName(result.sourceBiome)) into \(profile.displayName): \(result.columns) columns, \(result.terrainBlocks) terrain blocks, \(result.resourceBlocks) resource blocks."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: result.terrainBlocks > 0 || result.resourceBlocks > 0 || result.biomeCells > 0)

    case "set_time", "time", "set_day_time":
        let rawValue = action.value ?? action.time
        guard rawValue != nil || action.ticks != nil else { throw AIAgentError.missingTimeValue }
        guard let dayTime = resolveAIAgentDayTime(value: rawValue, ticks: action.ticks) else {
            throw AIAgentError.invalidTimeValue(rawValue ?? "\(action.ticks ?? 0)")
        }
        world.dayTime = dayTime
        let fallback = "Set time to \(dayTime)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "set_weather", "weather":
        guard let rawWeather = action.weather ?? action.value ?? action.kind else {
            throw AIAgentError.missingWeatherValue
        }
        guard let weather = resolveAIAgentWeather(rawWeather) else {
            throw AIAgentError.invalidWeather(rawWeather)
        }
        world.raining = weather.raining
        world.thundering = weather.thundering
        world.rainLevel = weather.raining ? 1 : 0
        world.thunderLevel = weather.thundering ? 1 : 0
        world.weatherTimer = AIAgentWeatherDurationTicks
        let fallback = "Weather set to \(weather.name)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "spawn_entity", "spawn_mob", "summon":
        try requireAIAgentTarget(action, expected: "cursor")
        guard let rawEntity = action.entity ?? action.name ?? action.kind else { throw AIAgentError.missingEntity }
        guard let entityName = resolveAIAgentEntityName(rawEntity) else { throw AIAgentError.unknownEntity(rawEntity) }
        guard let cursor else { throw AIAgentError.missingCursorTarget }
        let target = aiCursorPlacementPosition(cursor, in: world)
        guard target.y >= world.info.minY && target.y < world.info.minY + world.info.height else {
            throw AIAgentError.targetOutOfWorld(target.x, target.y, target.z)
        }
        guard target.y + 1 < world.info.minY + world.info.height else {
            throw AIAgentError.targetOutOfWorld(target.x, target.y + 1, target.z)
        }
        guard world.isLoadedAt(target.x, target.z) else {
            throw AIAgentError.unloadedTarget(target.x, target.y, target.z)
        }
        guard canAIAgentSpawnEntity(at: target, in: world) else {
            throw AIAgentError.entitySpawnFailed(entityName)
        }
        let count = min(AIAgentMaxSpawnCount, max(1, action.count ?? 1))
        var spawned = 0
        for _ in 0..<count {
            if spawnMob(
                world,
                entityName,
                Double(target.x) + 0.5,
                Double(target.y),
                Double(target.z) + 0.5,
                SpawnOpts(persistent: true)) != nil {
                spawned += 1
            }
        }
        guard spawned > 0 else { throw AIAgentError.entitySpawnFailed(entityName) }
        let fallback = "Spawned \(spawned) \(entityName) at \(target.x) \(target.y) \(target.z)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "remove_entities_nearby", "kill_entities_nearby", "clear_entities_nearby":
        let result = try removeAIAgentNearbyEntities(world: world, player: player, rawEntity: action.entity ?? action.kind ?? action.name,
                                                     radius: action.radius, count: action.count)
        let fallback = "Removed \(result) nearby non-player entit\(result == 1 ? "y" : "ies")."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: result > 0)

    case "eat_selected_food", "eat_food", "consume_selected_food":
        guard consumeSelectedFoodNow(interactCtx) else {
            throw AIAgentError.blockUseFailed("selected food")
        }
        let fallback = "Ate the selected food."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "set_gamemode", "gamemode":
        guard let rawMode = action.mode ?? action.value ?? action.kind else { throw AIAgentError.missingMode }
        guard let resolved = resolveAIAgentGameMode(rawMode) else { throw AIAgentError.invalidMode(rawMode) }
        player.setGameMode(resolved.value)
        player.flying = player.flying && player.gameMode == GameMode.creative
        let fallback = "Game mode set to \(resolved.name)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "heal_player", "heal":
        player.health = player.maxHealth
        player.hunger = 20
        player.saturation = 20
        let fallback = "Healed the player."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "damage_player", "hurt_player":
        let amount = action.amount ?? action.count ?? action.ticks ?? 0
        guard amount > 0 else { throw AIAgentError.missingAmount }
        guard amount <= AIAgentMaxDamageAmount else { throw AIAgentError.invalidAmount(amount) }
        _ = player.hurt(Double(amount), "magic")
        let fallback = "Damaged the player by \(amount)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "apply_effect", "effect":
        guard let rawEffect = action.effect ?? action.value ?? action.kind else { throw AIAgentError.missingEffect }
        let effectName = normalizeAIAgentName(rawEffect)
        if effectName == "clear" || effectName == "none" {
            player.clearEffects()
            let fallback = "Cleared player effects."
            return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                          changedWorld: false)
        }
        guard EFFECT_BY_ID[effectName] != nil else { throw AIAgentError.unknownEffect(rawEffect) }
        let durationSeconds = min(AIAgentMaxEffectDurationSeconds, max(1, action.duration ?? action.ticks ?? 30))
        let amplifier = min(AIAgentMaxEffectAmplifier, max(0, action.amplifier ?? action.count ?? 0))
        player.addEffect(effectName, durationSeconds * 20, amplifier)
        let fallback = "Applied \(effectName) \(amplifier + 1) for \(durationSeconds)s."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "clear_inventory", "clear_player_inventory":
        for i in 0..<player.inventory.count { player.inventory[i] = nil }
        for i in 0..<player.armor.count { player.armor[i] = nil }
        player.offHand = nil
        let fallback = "Cleared the player inventory."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "add_xp", "add_experience":
        let amount = action.amount ?? action.count ?? 0
        guard amount > 0 else { throw AIAgentError.missingAmount }
        guard amount <= AIAgentMaxXPAmount else { throw AIAgentError.invalidAmount(amount) }
        if action.levels == true || normalizeAIAgentName(action.kind ?? action.value ?? "") == "levels" {
            player.xpLevel += amount
            let fallback = "Added \(amount) XP level\(amount == 1 ? "" : "s")."
            return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                          changedWorld: false)
        }
        player.addXP(amount)
        let fallback = "Added \(amount) XP."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "set_spawnpoint", "spawnpoint":
        player.spawnPoint = (ifloor(player.x), ifloor(player.y), ifloor(player.z))
        player.spawnDim = world.dim.rawValue
        persistPlayerState()
        let fallback = "Spawn point set at \(player.spawnPoint!.0) \(player.spawnPoint!.1) \(player.spawnPoint!.2)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    case "set_difficulty", "difficulty":
        let raw = action.value ?? action.kind ?? action.mode
        guard raw != nil else { throw AIAgentError.missingDifficulty }
        guard let resolved = resolveAIAgentDifficulty(raw) else { throw AIAgentError.invalidDifficulty(raw ?? "") }
        if let setDifficulty {
            setDifficulty(resolved.value)
        } else {
            world.difficulty = resolved.value
        }
        let fallback = "Difficulty set to \(resolved.name)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "set_gamerule", "gamerule":
        guard let rawRule = action.rule ?? action.name ?? action.kind else { throw AIAgentError.missingGameRule }
        guard let rule = world.gameRules.keys.first(where: { normalizeAIAgentName($0) == normalizeAIAgentName(rawRule) }) else {
            throw AIAgentError.unknownGameRule(rawRule)
        }
        guard let value = resolveAIAgentGameRuleValue(enabled: action.enabled, value: action.value) else {
            throw AIAgentError.invalidGameRuleValue(action.value ?? "")
        }
        if let setGameRule {
            setGameRule(rule, value)
        } else {
            world.gameRules[rule] = value
        }
        let fallback = "\(rule) = \(value)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "teleport_player", "teleport":
        let target = normalizeAIAgentName(action.target ?? action.value ?? "")
        guard target == "surface" || target == "top" else {
            throw AIAgentError.invalidTeleportTarget(action.target ?? action.value ?? "")
        }
        let sx = ifloor(player.x)
        let sz = ifloor(player.z)
        guard world.isLoadedAt(sx, sz) else {
            throw AIAgentError.unloadedTarget(sx, ifloor(player.y), sz)
        }
        let sy = world.surfaceY(sx, sz)
        player.setPos(player.x, Double(sy), player.z)
        player.vx = 0
        player.vy = 0
        player.vz = 0
        player.fallDistance = 0
        let fallback = "Teleported player to the surface at y=\(sy)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: false)

    default:
        throw AIAgentError.unsupportedAction(action.action)
    }
}

private func placeableItemID(for blockId: UInt16) -> Int? {
    let idx = Int(blockId)
    guard idx >= 0 && idx < blockToItem.count else { return nil }
    let itemId = blockToItem[idx]
    return itemId >= 0 ? Int(itemId) : nil
}

private func requireAIAgentTarget(_ action: AIAgentAction, expected: String) throws {
    guard let raw = action.target else { return }
    guard normalizeAIAgentName(raw) == expected else {
        throw AIAgentError.invalidTarget(raw)
    }
}

private func validateAIAgentBlockTarget(world: World, player: Player, x: Int, y: Int, z: Int) throws {
    guard y >= world.info.minY && y < world.info.minY + world.info.height else {
        throw AIAgentError.targetOutOfWorld(x, y, z)
    }
    guard world.isLoadedAt(x, z) else {
        throw AIAgentError.unloadedTarget(x, y, z)
    }
    let id = world.getBlockId(x, y, z)
    if id > 0 && blockDefs[id].hardness < 0 && player.gameMode != GameMode.creative {
        throw AIAgentError.blockBreakFailed(blockDefs[id].name)
    }
}

private func fillAIAgentRegion(world: World, player: Player, center: (x: Int, y: Int, z: Int),
                               radius rawRadius: Int, blockId: UInt16) throws -> Int {
    let radius = rawRadius
    guard radius >= 0 else { throw AIAgentError.invalidAmount(radius) }
    let side = radius * 2 + 1
    let volume = side * side * side
    guard radius <= AIAgentMaxFillRegionRadius, volume <= AIAgentMaxFillRegionBlocks else {
        throw AIAgentError.regionFillTooLarge(volume, AIAgentMaxFillRegionBlocks)
    }
    let newCell = blockId == 0 ? 0 : Int(cell(blockId, 0))
    var targets: [(x: Int, y: Int, z: Int)] = []
    for y in (center.y - radius)...(center.y + radius) {
        for z in (center.z - radius)...(center.z + radius) {
            for x in (center.x - radius)...(center.x + radius) {
                try validateAIAgentBlockTarget(world: world, player: player, x: x, y: y, z: z)
                targets.append((x, y, z))
            }
        }
    }
    var changed = 0
    for target in targets.sorted(by: {
        if $0.y != $1.y { return $0.y < $1.y }
        if $0.z != $1.z { return $0.z < $1.z }
        return $0.x < $1.x
    }) {
        let old = world.setBlock(target.x, target.y, target.z, newCell)
        if old != newCell { changed += 1 }
    }
    return changed
}

private func removeAIAgentNearbyEntities(world: World, player: Player, rawEntity: String?,
                                         radius rawRadius: Int?, count rawCount: Int?) throws -> Int {
    let radius = min(AIAgentMaxEntityRemovalRadius, max(1, rawRadius ?? 16))
    let limit = min(AIAgentMaxEntityRemoveCount, max(1, rawCount ?? AIAgentMaxEntityRemoveCount))
    let filterName: String?
    if let rawEntity, !rawEntity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let normalized = normalizeAIAgentName(rawEntity)
        if normalized == "all" || normalized == "entities" || normalized == "entity" {
            filterName = nil
        } else if normalized == "item" || normalized == "items" || normalized == "dropped_item" || normalized == "dropped_items" {
            filterName = "item"
        } else if normalized == "xp" || normalized == "xp_orb" || normalized == "experience_orb" {
            filterName = "xp_orb"
        } else if let resolved = resolveAIAgentEntityName(rawEntity) {
            filterName = resolved
        } else {
            throw AIAgentError.unknownEntity(rawEntity)
        }
    } else {
        filterName = nil
    }

    let candidates = world.getEntitiesNear(player.x, player.y, player.z, Double(radius)) { ref in
        guard let entity = ref as? Entity, !entity.isPlayer else { return false }
        if let filterName { return entity.type == filterName }
        return true
    }.compactMap { $0 as? Entity }
        .sorted {
            let da = squaredDistance($0.x, $0.y, $0.z, player.x, player.y, player.z)
            let db = squaredDistance($1.x, $1.y, $1.z, player.x, player.y, player.z)
            if da != db { return da < db }
            return $0.id < $1.id
        }
        .prefix(limit)

    var removed = 0
    for entity in candidates {
        entity.remove()
        world.removeEntity(entity)
        removed += 1
    }
    return removed
}

private func canAIAgentSpawnEntity(at target: (x: Int, y: Int, z: Int), in world: World) -> Bool {
    let footId = world.getBlockId(target.x, target.y, target.z)
    if footId != 0 && !blockDefs[footId].replaceable {
        return false
    }
    let headId = world.getBlockId(target.x, target.y + 1, target.z)
    return headId == 0 || !blockDefs[headId].solid
}

public func buildAIAgentSnapshot(world: World, player: Player, cursor: RaycastHit?,
                                 nearbyRadius: Double = AIAgentNearbyRadius,
                                 savedTemplates: [ObjectTemplate] = [],
                                 savedTemplateSummaries: [ObjectTemplateSummary] = []) -> String {
    var lines: [String] = []
    let dimName: String
    switch world.dim {
    case .overworld: dimName = "overworld"
    case .nether: dimName = "nether"
    case .end: dimName = "end"
    }
    lines.append("World: dimension=\(dimName) seed=\(world.seed) time=\(world.time) dayTime=\(world.dayTime) raining=\(world.raining) thundering=\(world.thundering) difficulty=\(world.difficulty)")
    lines.append(String(format: "Player: x=%.2f y=%.2f z=%.2f yaw=%.2f pitch=%.2f health=%.1f hunger=%d saturation=%.1f gamemode=%@ selectedSlot=%d",
                        player.x, player.y, player.z, player.yaw, player.pitch, player.health,
                        player.hunger, player.saturation,
                        player.gameMode == GameMode.creative ? "creative" : "survival", player.selectedSlot))
    if let cursor {
        let target = aiCursorPlacementPosition(cursor, in: world)
        lines.append("Cursor: block=\(blockName(cursor.cell >> 4)) at=\(cursor.x),\(cursor.y),\(cursor.z) face=\(cursor.face) placement=\(target.x),\(target.y),\(target.z)")
    } else {
        lines.append("Cursor: none")
    }
    let inventory = player.inventory.enumerated().compactMap { idx, stack -> String? in
        guard let stack else { return nil }
        return "\(idx):\(itemDef(stack.id).name)x\(stack.count)"
    }.prefix(80).joined(separator: ", ")
    lines.append("Inventory: \(inventory.isEmpty ? "empty" : inventory)")

    var templateLines = savedTemplateSummaries.prefix(32).map { summary in
        "template=\"\(summary.name)\" size=\(summary.sizeX)x\(summary.sizeY)x\(summary.sizeZ) blocks=\(summary.blockCount) blockEntities=\(summary.blockEntityCount) palette=dominant:\(summary.dominantBlockName)"
    }
    if templateLines.count < 32 {
        let known = Set(savedTemplateSummaries.map(\.name))
        templateLines.append(contentsOf: savedTemplates.filter { !known.contains($0.name) }.prefix(32 - templateLines.count).compactMap { template -> String? in
            guard let summary = try? summarizeObjectTemplate(template) else { return nil }
            let palette = (try? objectTemplateBlockPalette(template, limit: 10)) ?? []
            let paletteText = palette.map { "\($0.blockName)x\($0.count)" }.joined(separator: ", ")
            return "template=\"\(summary.name)\" size=\(summary.sizeX)x\(summary.sizeY)x\(summary.sizeZ) blocks=\(summary.blockCount) blockEntities=\(summary.blockEntityCount) palette=\(paletteText.isEmpty ? "none" : paletteText)"
        })
    }
    lines.append("Saved object templates: \(templateLines.isEmpty ? "none" : templateLines.joined(separator: "; "))")

    let dropped = world.getEntitiesNear(player.x, player.y, player.z, nearbyRadius) { entity in
        (entity as? ItemEntity) != nil
    }.compactMap { $0 as? ItemEntity }
        .sorted {
            let da = squaredDistance($0.x, $0.y, $0.z, player.x, player.y, player.z)
            let db = squaredDistance($1.x, $1.y, $1.z, player.x, player.y, player.z)
            if da != db { return da < db }
            return $0.id < $1.id
        }
        .prefix(64)
        .map { item in
            String(format: "%@x%d at %.1f,%.1f,%.1f",
                   itemDef(item.stack.id).name, item.stack.count, item.x, item.y, item.z)
        }.joined(separator: "; ")
    lines.append("Nearby dropped items radius \(Int(nearbyRadius)): \(dropped.isEmpty ? "none" : dropped)")

    let px = ifloor(player.x), py = ifloor(player.y), pz = ifloor(player.z)
    var nearbyBlocks: [String] = []
    for y in max(world.info.minY, py - 2)...min(world.info.minY + world.info.height - 1, py + 4) {
        for z in (pz - 4)...(pz + 4) {
            for x in (px - 4)...(px + 4) {
                let id = world.getBlockId(x, y, z)
                if id != 0 {
                    nearbyBlocks.append("\(blockName(id))@\(x),\(y),\(z)")
                    if nearbyBlocks.count >= 160 { break }
                }
            }
            if nearbyBlocks.count >= 160 { break }
        }
        if nearbyBlocks.count >= 160 { break }
    }
    lines.append("Nearby non-air blocks: \(nearbyBlocks.isEmpty ? "none" : nearbyBlocks.joined(separator: "; "))")

    let chunks = world.chunks.values.sorted {
        if $0.cx != $1.cx { return $0.cx < $1.cx }
        return $0.cz < $1.cz
    }.prefix(64).map { chunk -> String in
        let status: String
        switch chunk.status {
        case .empty: status = "empty"
        case .generated: status = "generated"
        case .lit: status = "lit"
        }
        return "(\(chunk.cx),\(chunk.cz),\(status),modified=\(chunk.modified))"
    }.joined(separator: ", ")
    lines.append("Loaded chunks sample: \(chunks.isEmpty ? "none" : chunks)")

    lines.append("Available spawnable entities: " + spawnableMobs().sorted().joined(separator: ", "))
    lines.append("Available items: " + itemDefs.map(\.name).sorted().joined(separator: ", "))
    lines.append("Placeable block items: " + itemDefs.filter { $0.block != nil }.map(\.name).sorted().joined(separator: ", "))
    return lines.joined(separator: "\n")
}

public func buildAIAgentPrompt(userRequest: String, world: World, player: Player,
                               cursor: RaycastHit?,
                               savedTemplates: [ObjectTemplate] = [],
                               savedTemplateSummaries: [ObjectTemplateSummary] = []) -> String {
    let snapshot = buildAIAgentSnapshot(world: world, player: player, cursor: cursor,
                                        savedTemplates: savedTemplates,
                                        savedTemplateSummaries: savedTemplateSummaries)
    let allowedActions = allAIAgentSkills.map(aiAgentPromptLine).joined(separator: "\n")
    let prompt = """
You are Elysium's local in-game AI agent. Inspect the state below and return exactly one JSON object. Do not use markdown.

Allowed actions:
\(allowedActions)

Rules:
- Use only registered item or block names shown in the state.
- Use cursor/front/current_biome/surface targets only where the selected action explicitly allows them. Do not invent coordinates.
- To place at the current cursor location, use action "place_block" and target "cursor". To replace the targeted block directly, use "set_block_at_cursor".
- To break or use/toggle a targeted block, use "break_block" or "use_block" with target "cursor".
- To fill a hole in front of the player, use action "fill_hole" and target "front"; the engine will find the bounded connected empty cavity below the local ground plane.
- To fill a region, use "fill_region", target "cursor", and radius \(AIAgentMaxFillRegionRadius) or lower; the engine preflights loaded chunks and world height.
- To change time of day, use action "set_time"; ticks are normalized to one day and presets are day, noon, sunset, night, midnight, or sunrise.
- To change weather, use action "set_weather"; only clear, rain, and thunder are allowed.
- To spawn an animal or monster at the current cursor location, use action "spawn_entity", target "cursor", and one of the registered spawnable entity names. Keep count small.
- To remove nearby entities, use "remove_entities_nearby"; players are never removed by this action.
- To rework the terrain/biome the player is standing in, use action "rework_biome", target "current_biome", and profile "rolling_hills_resource_rich". The engine chooses the loaded current biome patch; do not provide coordinates.
- For player state, use "set_gamemode", "heal_player", "damage_player", "apply_effect", "clear_inventory", "add_xp", "set_spawnpoint", "eat_selected_food", or "teleport_player" with target "surface".
- For global world settings, use "set_difficulty" or "set_gamerule"; only existing gamerule names are accepted.
- To create a non-placeable item, use action "give_item".
- A request for "a stack" means the item's maximum stack size, usually 64.
- To edit a saved object template, use "replace_template_blocks"; "wood blocks" means every registered wood-family block in that template.
- To create a saved composite object template, use "create_template". The engine currently supports bounded generated pirate_ship templates and stores them with copied templates.
- Return one object only. Do not include commands, code, or extra prose.

Player request:
\(userRequest)

Game state:
\(snapshot)
"""
    if prompt.count <= AIAgentMaxPromptCharacters { return prompt }
    return String(prompt.prefix(AIAgentMaxPromptCharacters))
}

private func aiAgentPromptLine(_ skill: AIAgentSkillDefinition) -> String {
    let fields = skill.parameters.map { parameter -> String in
        var pieces = ["\"\(parameter.name)\":\(parameter.type)"]
        if let enumValues = parameter.enumValues {
            pieces.append("enum=\(enumValues.joined(separator: "|"))")
        }
        if let minimum = parameter.minimum {
            pieces.append("min=\(minimum)")
        }
        if let maximum = parameter.maximum {
            pieces.append("max=\(maximum)")
        }
        return pieces.joined(separator: " ")
    }.joined(separator: ", ")
    let required = skill.required.isEmpty ? "" : " required=\(skill.required.joined(separator: ","))"
    return "- {\"action\":\"\(skill.name)\"}\(required): \(skill.summary) \(fields)"
}

private func squaredDistance(_ ax: Double, _ ay: Double, _ az: Double,
                             _ bx: Double, _ by: Double, _ bz: Double) -> Double {
    let dx = ax - bx, dy = ay - by, dz = az - bz
    return dx * dx + dy * dy + dz * dz
}
