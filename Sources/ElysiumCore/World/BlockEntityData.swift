// Block entity data layer — The baseline side is a
// discriminated union of plain objects; here it's one class with the union of
// fields (pragmatic, mutable in place, Codable for saves). Behavior lives in
// the systems layer, deterministically.

import Foundation

public final class BlockEntityData: Codable {
    public var type: String
    public var x: Int
    public var y: Int
    public var z: Int

    // container / hopper / furnace / brewing / shelf / campfire
    public var items: [ItemStack?]?
    public var lootTable: String?
    public var lootSeed: Int?
    /// Exact bounded provenance for a generated RPG dungeon-container award.
    /// Cleared atomically when the deferred loot is first materialized.
    public var rpgGeneratedContainerKey: String?
    public var name: String?
    public var cooldown: Int?
    // furnace
    public var kind: String?           // furnace | blast | smoker
    public var burnTime: Int?
    public var burnTotal: Int?
    public var cookTime: Int?
    public var cookTotal: Int?
    public var xpBank: Double?
    // brewing
    public var brewTime: Int?
    public var fuel: Int?
    // sign
    public var lines: [String]?
    public var glowing: Bool?
    public var color: String?
    // spawner
    public var mob: String?
    public var delay: Int?
    // jukebox
    public var disc: ItemStack?
    public var startedTick: Int?
    // beacon
    public var primary: String?
    public var secondary: String?
    public var levels: Int?
    // beehive
    public var bees: Int?
    public var honey: Int?
    // shelf
    public var lastSlot: Int?
    // pot
    public var sherds: [String?]?
    // campfire
    public var times: [Int]?
    // brushable
    public var item: ItemStack?
    public var dusted: Int?
    // comparator / note
    public var output: Int?
    public var note: Int?
    // piston
    public var movedCell: Int?
    public var facing: Int?
    public var extending: Bool?
    public var progress: Double?
    public var isSourceHead: Bool?
    // conduit
    public var active: Bool?
    public var eyeTarget: Int?
    // end gateway
    public var exitX: Int?
    public var exitY: Int?
    public var exitZ: Int?
    public var exactTeleport: Bool?
    // shrieker
    public var canSummon: Bool?
    public var viewers: Int?
    public var shrieking: Int?
    // potted plant (lectern slot reuse, like baseline)
    public var plant: String?

    public init(type: String, x: Int, y: Int, z: Int) {
        self.type = type
        self.x = x
        self.y = y
        self.z = z
    }
}

public func makeContainerBE(_ x: Int, _ y: Int, _ z: Int, _ size: Int) -> BlockEntityData {
    let be = BlockEntityData(type: "container", x: x, y: y, z: z)
    be.items = [ItemStack?](repeating: nil, count: size)
    return be
}
public func makeHopperBE(_ x: Int, _ y: Int, _ z: Int) -> BlockEntityData {
    let be = BlockEntityData(type: "hopper", x: x, y: y, z: z)
    be.items = [ItemStack?](repeating: nil, count: 5)
    be.cooldown = 0
    return be
}
public func makeFurnaceBE(_ x: Int, _ y: Int, _ z: Int, _ kind: String) -> BlockEntityData {
    let be = BlockEntityData(type: "furnace", x: x, y: y, z: z)
    be.kind = kind
    be.items = [nil, nil, nil]
    be.burnTime = 0
    be.burnTotal = 0
    be.cookTime = 0
    be.cookTotal = 200
    be.xpBank = 0
    return be
}
public func makeBrewingBE(_ x: Int, _ y: Int, _ z: Int) -> BlockEntityData {
    let be = BlockEntityData(type: "brewing", x: x, y: y, z: z)
    be.items = [nil, nil, nil, nil, nil]
    be.brewTime = 0
    be.fuel = 0
    return be
}
public func makeCraftingTableBE(_ x: Int, _ y: Int, _ z: Int) -> BlockEntityData {
    let be = BlockEntityData(type: "crafting", x: x, y: y, z: z)
    be.items = [ItemStack?](repeating: nil, count: 9)
    return be
}
public func makeSignBE(_ x: Int, _ y: Int, _ z: Int) -> BlockEntityData {
    let be = BlockEntityData(type: "sign", x: x, y: y, z: z)
    be.lines = ["", "", "", ""]
    be.glowing = false
    be.color = "black"
    return be
}
public func makeSpawnerBE(_ x: Int, _ y: Int, _ z: Int, _ mob: String) -> BlockEntityData {
    let be = BlockEntityData(type: "spawner", x: x, y: y, z: z)
    be.mob = mob
    be.delay = 200
    return be
}
public func makeBrushableBE(_ x: Int, _ y: Int, _ z: Int, _ lootTable: String, _ lootSeed: Int) -> BlockEntityData {
    let be = BlockEntityData(type: "brushable", x: x, y: y, z: z)
    be.lootTable = lootTable
    be.lootSeed = lootSeed
    be.dusted = 0
    return be
}
public func containerSizeFor(_ blockName: String) -> Int {
    if blockName.contains("shulker_box") { return 27 }
    if blockName == "chest" || blockName == "trapped_chest" || blockName == "barrel" { return 27 }
    if blockName == "dispenser" || blockName == "dropper" { return 9 }
    return 27
}
