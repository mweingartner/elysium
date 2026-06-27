// AI agent bridge core — snapshot construction, model-output decoding,
// name resolution, and whitelisted world mutations. This file deliberately
// contains no networking; the app target owns the Ollama transport.

import Foundation

public let AIAgentNearbyRadius = 12.0
public let AIAgentMaxGiveCount = 640
public let AIAgentMaxModelJSONBytes = 16 * 1024
public let AIAgentMaxPromptCharacters = 24_000

public struct AIAgentAction: Codable, Equatable {
    public var action: String
    public var item: String?
    public var block: String?
    public var count: Int?
    public var target: String?
    public var message: String?

    public init(action: String, item: String? = nil, block: String? = nil, count: Int? = nil,
                target: String? = nil, message: String? = nil) {
        self.action = action
        self.item = item
        self.block = block
        self.count = count
        self.target = target
        self.message = message
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

public enum AIAgentError: Error, Equatable, CustomStringConvertible {
    case emptyResponse
    case responseTooLarge
    case malformedJSON
    case unsupportedAction(String)
    case missingItem
    case unknownItem(String)
    case itemNotPlaceable(String)
    case missingCursorTarget
    case unloadedTarget(Int, Int, Int)
    case targetOutOfWorld(Int, Int, Int)
    case placementFailed(String)
    case inventoryFull(String)

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
        case .unloadedTarget(let x, let y, let z): return "Target chunk is not loaded at \(x) \(y) \(z)"
        case .targetOutOfWorld(let x, let y, let z): return "Target is outside world height at \(x) \(y) \(z)"
        case .placementFailed(let item): return "Could not place \(item) at the cursor"
        case .inventoryFull(let item): return "Inventory is full; could not give \(item)"
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

public func inferDirectAIAgentAction(from userRequest: String) -> AIAgentAction? {
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

public func buildAIAgentSnapshot(world: World, player: Player, cursor: RaycastHit?,
                                 nearbyRadius: Double = AIAgentNearbyRadius) -> String {
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

    lines.append("Available items: " + itemDefs.map(\.name).sorted().joined(separator: ", "))
    lines.append("Placeable block items: " + itemDefs.filter { $0.block != nil }.map(\.name).sorted().joined(separator: ", "))
    return lines.joined(separator: "\n")
}

public func buildAIAgentPrompt(userRequest: String, world: World, player: Player,
                               cursor: RaycastHit?) -> String {
    let snapshot = buildAIAgentSnapshot(world: world, player: player, cursor: cursor)
    let prompt = """
You are Pebble's local in-game AI agent. Inspect the state below and return exactly one JSON object. Do not use markdown.

Allowed actions:
{"action":"say","message":"short answer"}
{"action":"give_item","item":"registered_item_id_or_display_name","count":1,"message":"short answer"}
{"action":"place_block","item":"registered_block_item_or_block_id","target":"cursor","message":"short answer"}

Rules:
- Use only registered item or block names shown in the state.
- To place at the current cursor location, use action "place_block" and target "cursor".
- To create a non-placeable item, use action "give_item".
- A request for "a stack" means the item's maximum stack size, usually 64.
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
