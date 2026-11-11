import Foundation

// What a survival paste of an object template costs.
//
// A paste costs, for each block, the item that places that block by hand, and it places the
// block the way that item would: nothing grown, filled, charged or stored comes with it
// (`TemplateHandPlacement.swift`). So a paste never puts into the world more than the player
// paid for, and breaking a pasted block gives back at most what placing it by hand would.
// `TemplateMaterialCostTests` checks that for every registered block and every metadata value.

/// What one block of a template costs a survival player.
enum TemplateCellCharge: Equatable {
    /// `count` of the item that places this block.
    case item(itemID: Int, count: Int)
    /// Nothing: the second half of a two-cell block, or a part another block makes itself.
    case free
    /// No item places this block, so a survival paste that holds one is refused.
    case unplaceable
}

/// Blocks with no item of their own that are what another item makes when placed or used.
/// Every other block costs its own item (`blockToItem`). A wall sign costs its standing sign.
private let TEMPLATE_MATERIAL_FOR_BLOCK: [String: String] = [
    "furnace_lit": "furnace", "blast_furnace_lit": "blast_furnace", "smoker_lit": "smoker",
    "repeater_on": "repeater", "comparator_on": "comparator", "redstone_lamp_on": "redstone_lamp",
    "redstone_torch_off": "redstone_torch", "daylight_detector_inverted": "daylight_detector",
    "kelp_plant": "kelp", "cave_vines_plant": "glow_berries", "bamboo_sapling": "bamboo",
    "big_dripleaf_stem": "big_dripleaf", "carrots": "carrot", "potatoes": "potato",
    "farmland": "dirt", "dirt_path": "dirt", "tall_seagrass": "seagrass",
]

/// Blocks that cost nothing because another block makes them: a piston's extended head. A
/// survival paste never places one (`templateForSurvivalPaste`); this is what it would cost.
private let TEMPLATE_FREE_BLOCKS: Set<String> = ["piston_head", "cave_air", "void_air"]

/// Breakable blocks that no item places, or whose item is not the block (a bucket of water),
/// or that hold loot nobody put there. Unbreakable blocks and fluids are refused by rule.
private let TEMPLATE_UNPLACEABLE_BLOCKS: Set<String> = [
    "fire", "soul_fire", "powder_snow", "frogspawn", "frosted_ice",
    "suspicious_sand", "suspicious_gravel",
]

/// How the block `id` is charged, before its metadata is looked at.
private func templateBlockCharge(_ id: Int) -> TemplateCellCharge {
    guard id > 0, id < blockDefs.count else { return id == 0 ? .free : .unplaceable }
    let def = blockDefs[id]
    if TEMPLATE_FREE_BLOCKS.contains(def.name) { return .free }
    if def.hardness < 0 || def.shape == .liquid || TEMPLATE_UNPLACEABLE_BLOCKS.contains(def.name) {
        return .unplaceable
    }
    if id < blockToItem.count, blockToItem[id] >= 0 {
        return .item(itemID: Int(blockToItem[id]), count: 1)
    }
    let material = TEMPLATE_MATERIAL_FOR_BLOCK[def.name]
        ?? (def.name.hasSuffix("_wall_sign") ? String(def.name.dropLast("_wall_sign".count)) + "_sign" : nil)
    guard let material, let itemID = iidOpt(material) else { return .unplaceable }
    return .item(itemID: itemID, count: 1)
}

/// How many of its item one cell of the block `id` holds: both halves of a double slab, each
/// candle in a cluster, each layer of snow.
private func templateCellItemCount(_ id: Int, _ meta: Int) -> Int {
    let def = blockDefs[id]
    switch def.shape {
    case .slab:
        return meta & 3 == 2 ? 2 : 1
    case .candle, .seaPickle, .turtleEgg:
        return (meta & 3) + 1
    case .layer:
        return (meta & 7) + 1
    default:
        return def.name == "pink_petals" ? (meta & 3) + 1 : 1
    }
}

/// What the cell `cellValue` costs a survival player to paste.
func templateCellCharge(_ cellValue: Int) -> TemplateCellCharge {
    let id = cellValue >> 4
    guard case .item(let itemID, _) = templateBlockCharge(id) else { return templateBlockCharge(id) }
    if twoCellHalf(of: cellValue) == .secondary { return .free }
    return .item(itemID: itemID, count: templateCellItemCount(id, cellValue & 15))
}

/// The cell as placing its item by hand leaves it: a crop just planted, vines without
/// berries, a composter, cauldron and respawn anchor empty, a cake uneaten, eggs not yet
/// cracking. Facing, shape and how many candles or eggs share the cell are kept. The block
/// itself never changes here.
func templateSurvivalCell(_ cellValue: UInt16) -> UInt16 {
    let id = Int(cellValue >> 4)
    let meta = Int(cellValue & 15)
    guard id > 0, id < blockDefs.count else { return cellValue }
    let name = blockDefs[id].name
    let placed: Int
    switch name {
    case "wheat", "carrots", "potatoes":
        placed = meta & ~7
    case "beetroots", "nether_wart", "sweet_berry_bush", "sniffer_egg":
        placed = meta & ~3
    case "torchflower_crop":
        placed = meta & ~1
    case "melon_stem", "pumpkin_stem", "pitcher_crop", "composter", "cauldron", "cake",
         "chorus_flower", "kelp":
        placed = 0
    case "cocoa", "turtle_egg":
        placed = meta & 3
    case "piston", "sticky_piston":
        placed = meta & 7              // retracted; its head is left out (`templateForSurvivalPaste`)
    case "cave_vines", "cave_vines_plant", "mangrove_propagule":
        placed = meta & ~8
    case "respawn_anchor":
        placed = meta & ~7
    default:
        placed = name.hasSuffix("_sapling") ? meta & ~8 : meta
    }
    return cell(UInt16(id), placed)
}

/// One line of a bill, a receipt or a refund: so many of one item.
public struct TemplateMaterialLine: Equatable {
    public var itemID: Int
    public var count: Int

    public init(itemID: Int, count: Int) {
        self.itemID = itemID
        self.count = count
    }
}

/// What a survival paste costs: one line for each item, ascending by item id, none empty.
public struct TemplateMaterialBill: Equatable {
    public private(set) var lines: [TemplateMaterialLine]

    public init(_ counts: [Int: Int] = [:]) {
        lines = counts.keys.sorted().compactMap { itemID in
            let count = counts[itemID] ?? 0
            return count > 0 ? TemplateMaterialLine(itemID: itemID, count: count) : nil
        }
    }

    /// How many items the bill asks for in all.
    public var total: Int { lines.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { lines.isEmpty }

    public func count(of itemID: Int) -> Int {
        lines.first { $0.itemID == itemID }?.count ?? 0
    }

    /// The bill with `count` more of `itemID`.
    public func adding(itemID: Int, count: Int) -> TemplateMaterialBill {
        guard count > 0 else { return self }
        var counts: [Int: Int] = [:]
        for line in lines { counts[line.itemID] = line.count }
        counts[itemID, default: 0] += count
        return TemplateMaterialBill(counts)
    }
}

/// Why a survival paste, or the undo of one, cannot go ahead.
public enum TemplateMaterialError: Error, Equatable, CustomStringConvertible {
    /// The object holds a block no item places; the name is the block's display name.
    case notPlaceableInSurvival(String)
    /// The player does not have these materials.
    case missing([TemplateMaterialLine])
    /// An undo's refund needs this many more free slots.
    case noRoomForRefund(stacks: Int)
    /// The object holds only parts that cannot be placed by themselves.
    case nothingToPlace

    public var description: String {
        switch self {
        case .notPlaceableInSurvival(let block):
            return "Survival can't place \(block). Switch to Creative to place this object."
        case .missing(let lines):
            return "Missing \(templateMaterialListText(lines)) - nothing was placed."
        case .noRoomForRefund(let stacks):
            return "Make room for \(stacks) more \(stacks == 1 ? "stack" : "stacks") to undo this object."
        case .nothingToPlace:
            return "Survival can't place this object: it holds only parts of blocks. Switch to Creative to place it."
        }
    }
}

/// "12 Oak Planks, 2 Glass Panes and 3 more kinds": the largest counts first, then by name, so
/// the same materials read the same wherever they are listed; the first `limit` kinds, then
/// how many are left out. The text has to fit a chat line and a LAN event.
public func templateMaterialListText(_ unordered: [TemplateMaterialLine], limit: Int = 4) -> String {
    func name(_ line: TemplateMaterialLine) -> String {
        line.itemID >= 0 && line.itemID < itemDefs.count ? itemDefs[line.itemID].displayName : "items"
    }
    let lines = unordered.sorted { a, b in
        a.count != b.count ? a.count > b.count : (name(a) != name(b) ? name(a) < name(b) : a.itemID < b.itemID)
    }
    let shown = lines.prefix(max(1, limit)).map { line in
        "\(line.count) \(name(line))"
    }
    let rest = lines.count - shown.count
    guard rest > 0 else {
        return shown.count > 1 ? shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
                               : shown.joined()
    }
    return shown.joined(separator: ", ") + " and \(rest) more \(rest == 1 ? "kind" : "kinds")"
}

/// A refusal for the action bar, which holds one short line: a list of missing materials does
/// not fit there and is in chat. Any other sentence is shown as it is.
public func templateRefusalActionBarText(_ sentence: String) -> String {
    if sentence.hasPrefix("Missing ") { return "Missing materials - nothing was placed" }
    if sentence.hasPrefix("Survival can't place ") { return String(sentence.prefix { $0 != "." }) }
    return sentence
}

extension TemplateError {
    /// The error as the action bar shows it.
    public var actionBarText: String { templateRefusalActionBarText(description) }
}

/// What the blocks of `template` cost, including the plant in each flower pot. `template` is
/// one a survival paste places (`templateForSurvivalPaste`). Throws
/// `TemplateMaterialError.notPlaceableInSurvival` for the first block no item places.
func templateMaterialBill(_ template: ObjectTemplate) throws -> TemplateMaterialBill {
    guard !template.blocks.isEmpty else { throw TemplateMaterialError.nothingToPlace }
    var counts: [Int: Int] = [:]
    for block in template.blocks {
        switch templateCellCharge(Int(block.cell)) {
        case .item(let itemID, let count):
            counts[itemID, default: 0] += count
        case .free:
            break
        case .unplaceable:
            let id = Int(block.cell >> 4)
            throw TemplateMaterialError.notPlaceableInSurvival(
                id > 0 && id < blockDefs.count ? blockDefs[id].displayName : "an unknown block")
        }
    }
    for blockEntity in template.blockEntities {
        if let plant = blockEntity.plant, let itemID = iidOpt(plant) { counts[itemID, default: 0] += 1 }
    }
    return TemplateMaterialBill(counts)
}

/// What stands at `x, y, z` now, as the items a survival paste would have been charged for it.
/// Undo pays back from this, so a block that was mined or replaced is not paid back.
func templateStandingMaterials(in world: World, _ x: Int, _ y: Int, _ z: Int) -> [TemplateMaterialLine] {
    let cellValue = world.getBlock(x, y, z)
    guard case .item(let itemID, let count) = templateCellCharge(cellValue) else { return [] }
    var lines = [TemplateMaterialLine(itemID: itemID, count: count)]
    if cellValue >> 4 == Int(B.flower_pot), let plant = world.getBlockEntity(x, y, z)?.plant,
       let plantID = iidOpt(plant) {
        lines.append(TemplateMaterialLine(itemID: plantID, count: 1))
    }
    return lines
}
