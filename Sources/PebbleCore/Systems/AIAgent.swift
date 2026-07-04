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

    public init(action: String, item: String? = nil, block: String? = nil, count: Int? = nil,
                target: String? = nil, message: String? = nil, template: String? = nil,
                name: String? = nil, fromBlock: String? = nil, toBlock: String? = nil,
                kind: String? = nil, length: Int? = nil, style: String? = nil,
                entity: String? = nil, value: String? = nil, time: String? = nil,
                weather: String? = nil, ticks: Int? = nil) {
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
    }

    enum CodingKeys: String, CodingKey {
        case action, item, block, count, target, message, template, name, kind, length, style
        case entity, value, time, weather, ticks
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

public enum AIAgentError: Error, Equatable, CustomStringConvertible {
    case emptyResponse
    case responseTooLarge
    case malformedJSON
    case unsupportedAction(String)
    case missingItem
    case unknownItem(String)
    case itemNotPlaceable(String)
    case missingCursorTarget
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
    if let action = inferDirectAIAgentTimeAction(from: normalized) { return action }
    if let action = inferDirectAIAgentWeatherAction(from: normalized) { return action }
    if let action = inferDirectAIAgentSpawnEntityAction(from: normalized) { return action }
    return nil
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
                                 cursor: RaycastHit?) throws -> AIAgentExecutionResult {
    let kind = normalizeAIAgentName(action.action)
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

        let ok = placeBlock(InteractCtx(world: world, player: player), cursor, Int(blockId), temp)
        guard ok else { throw AIAgentError.placementFailed(blockDefs[Int(blockId)].name) }
        let fallback = "Placed \(blockDefs[Int(blockId)].displayName) at \(target.x) \(target.y) \(target.z)"
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: true)

    case "fill_hole", "fill_hole_in_front":
        guard let rawBlock = action.block ?? action.item else { throw AIAgentError.missingItem }
        guard let blockId = resolveAIAgentBlockID(rawBlock), blockId != 0 else {
            throw AIAgentError.itemNotPlaceable(rawBlock)
        }
        let result = try fillAIAgentHoleInFront(world: world, player: player, cursor: cursor, blockId: blockId)
        let fallback = "Filled \(result.filledBlocks) blocks with \(blockDefs[Int(blockId)].displayName)."
        return AIAgentExecutionResult(message: sanitizeAIAgentChatMessage(action.message, fallback: fallback),
                                      changedWorld: result.filledBlocks > 0)

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
                                 savedTemplates: [ObjectTemplate] = []) -> String {
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

    let templateLines = savedTemplates.prefix(32).compactMap { template -> String? in
        guard let summary = try? summarizeObjectTemplate(template) else { return nil }
        let palette = (try? objectTemplateBlockPalette(template, limit: 10)) ?? []
        let paletteText = palette.map { "\($0.blockName)x\($0.count)" }.joined(separator: ", ")
        return "template=\"\(summary.name)\" size=\(summary.sizeX)x\(summary.sizeY)x\(summary.sizeZ) blocks=\(summary.blockCount) blockEntities=\(summary.blockEntityCount) palette=\(paletteText.isEmpty ? "none" : paletteText)"
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
                               savedTemplates: [ObjectTemplate] = []) -> String {
    let snapshot = buildAIAgentSnapshot(world: world, player: player, cursor: cursor,
                                        savedTemplates: savedTemplates)
    let prompt = """
You are Pebble's local in-game AI agent. Inspect the state below and return exactly one JSON object. Do not use markdown.

Allowed actions:
{"action":"say","message":"short answer"}
{"action":"give_item","item":"registered_item_id_or_display_name","count":1,"message":"short answer"}
{"action":"place_block","item":"registered_block_item_or_block_id","target":"cursor","message":"short answer"}
{"action":"fill_hole","block":"registered_solid_block_id_or_display_name","target":"front","message":"short answer"}
{"action":"set_time","value":"day|noon|sunset|night|midnight|sunrise|ticks","message":"short answer"}
{"action":"set_weather","weather":"clear|rain|thunder","message":"short answer"}
{"action":"spawn_entity","entity":"registered_spawnable_entity_name","count":1,"target":"cursor","message":"short answer"}
{"action":"replace_template_blocks","template":"saved_template_name","from_block":"wood blocks","to_block":"bamboo","message":"short answer"}
{"action":"create_template","template":"new_template_name","kind":"pirate_ship","length":50,"style":"short style description","message":"short answer"}

Rules:
- Use only registered item or block names shown in the state.
- To place at the current cursor location, use action "place_block" and target "cursor".
- To fill a hole in front of the player, use action "fill_hole" and target "front"; the engine will find the bounded connected empty cavity below the local ground plane.
- To change time of day, use action "set_time"; ticks are normalized to one day and presets are day, noon, sunset, night, midnight, or sunrise.
- To change weather, use action "set_weather"; only clear, rain, and thunder are allowed.
- To spawn an animal or monster at the current cursor location, use action "spawn_entity", target "cursor", and one of the registered spawnable entity names. Keep count small.
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

private func squaredDistance(_ ax: Double, _ ay: Double, _ az: Double,
                             _ bx: Double, _ by: Double, _ bz: Double) -> Double {
    let dx = ax - bx, dy = ay - by, dz = az - bz
    return dx * dx + dy * dy + dz * dz
}
