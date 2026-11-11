import XCTest
@testable import ElysiumCore

/// What a survival paste costs, block by block (`TemplateMaterials.swift`).
///
/// The rule under test: a paste charges the item that places a block and places the block the
/// way that item would, so breaking or using a pasted block gives nothing that placing the
/// paid item by hand would not give. The sweeps below go over every registered block and
/// every metadata value, so a block added later is checked without anyone remembering to.
final class TemplateMaterialCostTests: XCTestCase {
    override func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    // MARK: - Helpers

    private func cellValue(_ name: String, _ meta: Int = 0) -> Int { Int(cell(bid(name), meta)) }

    private func charge(_ name: String, _ meta: Int = 0) -> TemplateCellCharge {
        templateCellCharge(cellValue(name, meta))
    }

    private func item(_ name: String, _ count: Int = 1) -> TemplateCellCharge {
        .item(itemID: iid(name), count: count)
    }

    private func survivalMeta(_ name: String, _ meta: Int) -> Int {
        Int(templateSurvivalCell(cell(bid(name), meta)) & 15)
    }

    /// Every tool a block can be broken with, with the luckiest and unluckiest dice.
    private var dropContexts: [DropCtx] {
        var contexts: [DropCtx] = []
        let tools: [(ToolType, Bool)] = [(.none, false), (.pickaxe, false), (.axe, false), (.shovel, false),
                                         (.hoe, false), (.sword, false), (.shears, true)]
        for (tool, shears) in tools {
            for fortune in [0, 3] {
                for silk in [false, true] {
                    for dice in [0.0, 0.999] {
                        contexts.append(DropCtx(fortune: fortune, silkTouch: silk, toolType: tool, toolTier: 5,
                                                shears: shears, random: { dice }))
                    }
                }
            }
        }
        return contexts
    }

    /// The most of each item that breaking `cellValue` can give, over the three ways a block
    /// goes: broken by a player (Silk Touch gives the block's own item), popped by a neighbour
    /// update, or blown up. A chance drop counts as dropping.
    private func mostYield(of cellValue: Int) -> [Int: Int] {
        let id = cellValue >> 4
        let def = blockDefs[id]
        var most: [Int: Int] = [:]
        func note(_ drops: [Drop]) {
            var counts: [Int: Int] = [:]
            for drop in drops {
                guard let itemID = iidOpt(drop.item) else { continue }
                counts[itemID, default: 0] += drop.countMax
            }
            for (itemID, count) in counts { most[itemID] = max(most[itemID] ?? 0, count) }
        }
        if let rule = def.drops {
            for context in dropContexts { note(rule(cellValue & 15, context)) }
        } else if itemExists(def.name) {
            note([Drop(def.name)])
        }
        if blockToItem[id] >= 0 { note([Drop(itemDefs[Int(blockToItem[id])].name)]) }
        return most
    }

    // MARK: - Every block has a decision

    /// A block with no item of its own is charged through the table, refused, or free. This
    /// pins all three lists, so a new block without an item fails here until someone decides.
    func testEveryBlockWithoutAnItemIsChargedRefusedOrFreeOnPurpose() {
        var chargedThroughTable: [String: String] = [:]
        var refusedBreakable: [String] = []
        var free: [String] = []
        for id in 1..<blockDefs.count {
            let def = blockDefs[id]
            switch templateCellCharge(Int(cell(UInt16(id), 0))) {
            case .item(let itemID, let count):
                XCTAssertEqual(count, 1, "\(def.name) at metadata 0 is one item")
                if blockToItem[id] < 0 { chargedThroughTable[def.name] = itemDefs[itemID].name }
                else { XCTAssertEqual(itemID, Int(blockToItem[id]), "\(def.name) costs its own item") }
            case .unplaceable:
                if def.hardness >= 0 && def.shape != .liquid { refusedBreakable.append(def.name) }
            case .free:
                free.append(def.name)
            }
        }
        var expectedTable = [
            "furnace_lit": "furnace", "blast_furnace_lit": "blast_furnace", "smoker_lit": "smoker",
            "repeater_on": "repeater", "comparator_on": "comparator", "redstone_lamp_on": "redstone_lamp",
            "redstone_torch_off": "redstone_torch", "daylight_detector_inverted": "daylight_detector",
            "kelp_plant": "kelp", "cave_vines_plant": "glow_berries", "bamboo_sapling": "bamboo",
            "big_dripleaf_stem": "big_dripleaf", "carrots": "carrot", "potatoes": "potato",
            "farmland": "dirt", "dirt_path": "dirt", "tall_seagrass": "seagrass",
        ]
        for id in 1..<blockDefs.count where blockDefs[id].name.hasSuffix("_wall_sign") {
            let name = blockDefs[id].name
            expectedTable[name] = String(name.dropLast("_wall_sign".count)) + "_sign"
        }
        XCTAssertEqual(chargedThroughTable, expectedTable)
        XCTAssertEqual(refusedBreakable.sorted(), [
            "fire", "frogspawn", "frosted_ice", "powder_snow", "soul_fire",
            "suspicious_gravel", "suspicious_sand",
        ])
        XCTAssertEqual(free.sorted(), ["cave_air", "piston_head", "void_air"])
    }

    func testFluidsUnbreakableBlocksAndAirAreNeverSold() {
        for name in ["water", "lava", "bedrock", "end_portal_frame", "nether_portal", "end_portal", "end_gateway"]
        where bidOpt(name) != nil {
            XCTAssertEqual(charge(name), .unplaceable, name)
        }
        XCTAssertEqual(templateCellCharge(0), .free, "air costs nothing")
        XCTAssertEqual(templateCellCharge(Int(cell(UInt16(blockDefs.count + 3), 0))), .unplaceable,
                       "a block id nobody registered")
        XCTAssertEqual(templateCellCharge(-16), .unplaceable)
    }

    func testAnOreCostsTheOreItselfSoItIsNoCheaperThanPlacingOne() {
        for name in ["diamond_ore", "deepslate_diamond_ore", "ancient_debris", "emerald_ore"] {
            XCTAssertEqual(charge(name), item(name), name)
            XCTAssertEqual(templateCellCharge(skillTreePlayerPlacedCell(cellValue(name))), item(name),
                           "\(name) carrying the player-placed mark")
        }
    }

    // MARK: - Two cells, one item; many items, one cell

    func testTheSecondHalfOfATwoCellBlockIsFreeAndTheFirstCostsTheItem() {
        XCTAssertEqual(charge("oak_door", 1), item("oak_door"))
        XCTAssertEqual(charge("oak_door", 8 | 1), .free)
        XCTAssertEqual(charge("red_bed", 2), item("red_bed"))
        XCTAssertEqual(charge("red_bed", 4 | 2), .free)
        XCTAssertEqual(charge("sunflower", 0), item("sunflower"))
        XCTAssertEqual(charge("sunflower", 1), .free)
        XCTAssertEqual(charge("tall_seagrass", 0), item("seagrass"))
        XCTAssertEqual(charge("tall_seagrass", 1), .free)
        for id in 1..<blockDefs.count {
            for meta in 0..<16 where twoCellHalf(of: Int(cell(UInt16(id), meta))) == .secondary {
                let charged = templateCellCharge(Int(cell(UInt16(id), meta)))
                XCTAssertTrue(charged == .free || charged == .unplaceable, "\(blockDefs[id].name) meta \(meta)")
            }
        }
    }

    func testACellThatHoldsSeveralOfItsItemCostsThatMany() {
        XCTAssertEqual(charge("oak_slab", 0), item("oak_slab"))
        XCTAssertEqual(charge("oak_slab", 1), item("oak_slab"))
        XCTAssertEqual(charge("oak_slab", 2), item("oak_slab", 2), "a double slab")
        XCTAssertEqual(charge("stone_brick_slab", 2), item("stone_brick_slab", 2))
        for count in 1...4 {
            XCTAssertEqual(charge("candle", count - 1), item("candle", count))
            XCTAssertEqual(charge("red_candle", count - 1), item("red_candle", count))
            XCTAssertEqual(charge("sea_pickle", count - 1), item("sea_pickle", count))
            XCTAssertEqual(charge("pink_petals", count - 1), item("pink_petals", count))
            XCTAssertEqual(charge("turtle_egg", count - 1), item("turtle_egg", count))
        }
        XCTAssertEqual(charge("turtle_egg", 3 | (2 << 2)), item("turtle_egg", 4), "hatching does not change the count")
    }

    // MARK: - As placed by hand

    func testASurvivalCellIsUngrownEmptyAndUncharged() {
        for name in ["wheat", "carrots", "potatoes"] {
            XCTAssertEqual(survivalMeta(name, 7), 0, name)
        }
        XCTAssertEqual(survivalMeta("beetroots", 3), 0)
        XCTAssertEqual(survivalMeta("nether_wart", 3), 0)
        XCTAssertEqual(survivalMeta("sweet_berry_bush", 3), 0)
        XCTAssertEqual(survivalMeta("torchflower_crop", 1), 0)
        XCTAssertEqual(survivalMeta("melon_stem", 7 | 8), 0)
        XCTAssertEqual(survivalMeta("pumpkin_stem", 5), 0)
        XCTAssertEqual(survivalMeta("composter", 8), 0)
        XCTAssertEqual(survivalMeta("cauldron", 3 | (1 << 2)), 0, "a cauldron of lava")
        XCTAssertEqual(survivalMeta("respawn_anchor", 4), 0)
        XCTAssertEqual(survivalMeta("cake", 5), 0)
        XCTAssertEqual(survivalMeta("cave_vines", 8), 0)
        XCTAssertEqual(survivalMeta("cave_vines_plant", 8), 0)
        XCTAssertEqual(survivalMeta("oak_sapling", 8), 0)
    }

    func testASurvivalCellKeepsFacingShapeAndCount() {
        XCTAssertEqual(survivalMeta("cocoa", 2 | (2 << 2)), 2, "facing kept, age reset")
        XCTAssertEqual(survivalMeta("turtle_egg", 3 | (2 << 2)), 3, "four eggs, not hatching")
        XCTAssertEqual(survivalMeta("candle", 3), 3)
        for (name, meta) in [("oak_stairs", 7), ("oak_door", 8 | 3), ("red_bed", 4 | 1), ("oak_slab", 2),
                             ("chest", 3), ("furnace", 2), ("oak_log", 2), ("lever", 13), ("repeater", 11)] {
            XCTAssertEqual(survivalMeta(name, meta), meta, name)
        }
        for id in 1..<blockDefs.count {
            for meta in 0..<16 {
                XCTAssertEqual(Int(templateSurvivalCell(cell(UInt16(id), meta)) >> 4), id,
                               "\(blockDefs[id].name): the block itself never changes")
            }
        }
        XCTAssertEqual(templateSurvivalCell(0), 0)
    }

    // MARK: - No profit, for every block and every metadata value

    /// Breaking a pasted cell gives, of every item, no more than breaking what the paid items
    /// place by hand. The reference is metadata 0 of the paid item's own block: a crop just
    /// planted, one slab, one candle.
    func testBreakingASurvivalCellNeverYieldsMoreThanPlacingWhatWasPaid() {
        var checked = 0
        for id in 1..<blockDefs.count {
            for meta in 0..<16 {
                let survival = Int(templateSurvivalCell(cell(UInt16(id), meta)))
                guard case .item(let itemID, let count) = templateCellCharge(survival) else { continue }
                let placedBlock = itemDefs[itemID].block.map(Int.init) ?? id
                let reference = mostYield(of: Int(cell(UInt16(placedBlock), 0)))
                for (dropped, most) in mostYield(of: survival) {
                    let allowed = dropped == itemID ? max(count, count * (reference[dropped] ?? 0))
                                                    : count * (reference[dropped] ?? 0)
                    XCTAssertLessThanOrEqual(
                        most, allowed,
                        "\(blockDefs[id].name) meta \(meta) pasted as meta \(survival & 15) for \(count) "
                            + "\(itemDefs[itemID].name) can drop \(most) \(itemDefs[dropped].name)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 5_000)
    }

    /// The same sweep without the reset must fail for a grown crop: this proves the sweep can
    /// see the difference it is there to see.
    func testTheNoProfitSweepSeesAGrownCrop() {
        let grown = mostYield(of: cellValue("wheat", 7))
        let planted = mostYield(of: cellValue("wheat", 0))
        XCTAssertGreaterThan(grown[iid("wheat")] ?? 0, planted[iid("wheat")] ?? 0)
        XCTAssertGreaterThan(mostYield(of: cellValue("sweet_berry_bush", 3))[iid("sweet_berries")] ?? 0,
                             mostYield(of: cellValue("sweet_berry_bush", 0))[iid("sweet_berries")] ?? 0)
        XCTAssertGreaterThan(mostYield(of: cellValue("oak_slab", 2))[iid("oak_slab")] ?? 0,
                             mostYield(of: cellValue("oak_slab", 0))[iid("oak_slab")] ?? 0)
    }

    /// A cell that costs nothing gives nothing, however it is broken. (An orphan second half
    /// gives nothing with Silk Touch either: `TwoCellBlockDropTests`.)
    func testAFreeCellHasNoDropOfItsOwn() {
        for id in 1..<blockDefs.count {
            for meta in 0..<16 {
                let value = Int(cell(UInt16(id), meta))
                guard templateCellCharge(value) == .free else { continue }
                let def = blockDefs[id]
                for context in dropContexts {
                    XCTAssertEqual(def.drops?(meta, context).map(\.item) ?? ["<its own item>"], [],
                                   "\(def.name) meta \(meta)")
                }
            }
        }
    }

    // MARK: - Using a pasted block

    private func makeUseWorld() -> (World, Player) {
        let world = World(dim: .overworld, seed: 0xC057)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        for x in 0..<16 { for z in 0..<16 { world.setBlock(x, 63, z, Int(cell(B.stone)), SET_SILENT) } }
        let player = Player(world: world)
        player.setPos(8.5, 64, 6.5)
        world.addEntity(player)
        return (world, player)
    }

    /// Every item the player holds or that lies in the world, by item id.
    private func wealth(_ world: World, _ player: Player) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for case let stack? in player.inventory { counts[stack.id, default: 0] += stack.count }
        for case let dropped as ItemEntity in world.entities { counts[dropped.stack.id, default: 0] += dropped.stack.count }
        return counts
    }

    /// What right-clicking `cellValue` with `held` in hand gains the player, item by item.
    private func gainFromUsing(_ cellValue: Int, held: String?, in world: World, _ player: Player) -> [Int: Int] {
        for entity in world.entities where !(entity is Player) { world.removeEntity(entity) }
        for index in player.inventory.indices { player.inventory[index] = nil }
        if let held { player.inventory[0] = stack(held, 1) }
        player.selectedSlot = 0
        let (x, y, z) = (8, 64, 8)
        world.removeBlockEntity(x, y, z)
        world.setBlock(x, y, z, cellValue, SET_SILENT)
        if let blockEntity = placementBlockEntity(cellValue >> 4, x, y, z) { world.setBlockEntity(blockEntity) }
        let before = wealth(world, player)
        let hit = RaycastHit(x: x, y: y, z: z, face: 1, cell: cellValue, t: 1, px: 8.5, py: 65, pz: 8.5)
        _ = useBlock(InteractCtx(world: world, player: player), hit)
        var gain: [Int: Int] = [:]
        for (itemID, count) in wealth(world, player) where count > (before[itemID] ?? 0) {
            gain[itemID] = count - (before[itemID] ?? 0)
        }
        world.removeBlockEntity(x, y, z)
        world.setBlock(x, y, z, 0, SET_SILENT)
        return gain
    }

    /// Right-clicking a pasted cell, with a bare hand or with the tools that harvest things,
    /// gains nothing that the same block at metadata 0 would not give. Berries, honey, bone
    /// meal, a bucket of lava: all of them sit in metadata this paste resets.
    func testUsingASurvivalCellGainsNothingItsFreshBlockWouldNot() {
        let (world, player) = makeUseWorld()
        let tools: [String?] = [nil, "bucket", "glass_bottle", "shears"]
        var checked = 0
        for id in 1..<blockDefs.count {
            guard case .item = templateCellCharge(Int(cell(UInt16(id), 0))) else { continue }
            for tool in tools {
                let fresh = gainFromUsing(Int(templateSurvivalCell(cell(UInt16(id), 0))), held: tool, in: world, player)
                for meta in 1..<16 {
                    let survival = Int(templateSurvivalCell(cell(UInt16(id), meta)))
                    guard survival & 15 != 0, case .item = templateCellCharge(survival) else { continue }
                    for (itemID, count) in gainFromUsing(survival, held: tool, in: world, player) {
                        XCTAssertLessThanOrEqual(
                            count, fresh[itemID] ?? 0,
                            "\(blockDefs[id].name) meta \(survival & 15) used with \(tool ?? "a bare hand") "
                                + "gives \(count) \(itemDefs[itemID].name)")
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// The use sweep sees what it is there to see: a full composter that was not reset hands
    /// out bone meal, and a cauldron of lava fills a bucket.
    func testTheUseSweepSeesAFullComposterAndACauldronOfLava() {
        let (world, player) = makeUseWorld()
        let full = gainFromUsing(cellValue("composter", 8), held: nil, in: world, player)
        XCTAssertGreaterThan(full[iid("bone_meal")] ?? 0, 0)
        XCTAssertEqual(gainFromUsing(cellValue("composter", 0), held: nil, in: world, player), [:])
        let lava = gainFromUsing(cellValue("cauldron", 3 | (1 << 2)), held: "bucket", in: world, player)
        XCTAssertGreaterThan(lava[iid("lava_bucket")] ?? 0, 0)
        XCTAssertEqual(gainFromUsing(cellValue("cauldron", 0), held: "bucket", in: world, player), [:])
    }

    // MARK: - The bill

    private func template(_ blocks: [(Int, Int, Int, Int)], blockEntities: [BlockEntityData] = []) -> ObjectTemplate {
        ObjectTemplate(name: "Bill", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 8, sizeY: 8, sizeZ: 8,
                       blocks: blocks.map { TemplateBlock(dx: $0.0, dy: $0.1, dz: $0.2, cell: UInt16($0.3)) },
                       blockEntities: blockEntities)
    }

    func testTheBillAddsUpEveryBlockAndListsItemsInItemOrder() throws {
        let bill = try templateMaterialBill(template([
            (0, 0, 0, cellValue("oak_planks")), (1, 0, 0, cellValue("oak_planks")), (2, 0, 0, cellValue("glass")),
            (0, 1, 0, cellValue("oak_door", 0)), (0, 2, 0, cellValue("oak_door", 8)),
            (3, 0, 0, cellValue("oak_slab", 2)), (4, 0, 0, cellValue("candle", 2)),
            (5, 0, 0, cellValue("furnace_lit", 3)), (6, 0, 0, cellValue("piston_head", 1)),
        ]))
        XCTAssertEqual(bill.count(of: iid("oak_planks")), 2)
        XCTAssertEqual(bill.count(of: iid("glass")), 1)
        XCTAssertEqual(bill.count(of: iid("oak_door")), 1)
        XCTAssertEqual(bill.count(of: iid("oak_slab")), 2)
        XCTAssertEqual(bill.count(of: iid("candle")), 3)
        XCTAssertEqual(bill.count(of: iid("furnace")), 1)
        XCTAssertEqual(bill.total, 10)
        XCTAssertEqual(bill.lines.map(\.itemID), bill.lines.map(\.itemID).sorted())
        XCTAssertFalse(bill.lines.contains { $0.count <= 0 })
        XCTAssertEqual(bill.adding(itemID: iid("dirt"), count: 5).count(of: iid("dirt")), 5)
        XCTAssertEqual(bill.adding(itemID: iid("dirt"), count: 0), bill)
        XCTAssertEqual(bill.adding(itemID: iid("glass"), count: 2).count(of: iid("glass")), 3)
    }

    func testAPottedPlantCostsThePotAndThePlant() throws {
        let pot = BlockEntityData(type: "lectern", x: 0, y: 0, z: 0)
        pot.plant = "poppy"
        let bill = try templateMaterialBill(template([(0, 0, 0, cellValue("flower_pot"))], blockEntities: [pot]))
        XCTAssertEqual(bill.count(of: iid("flower_pot")), 1)
        XCTAssertEqual(bill.count(of: iid("poppy")), 1)
        XCTAssertEqual(bill.total, 2)
    }

    func testTheBillRefusesAnObjectSurvivalCannotPlaceAndNamesTheBlock() {
        XCTAssertThrowsError(try templateMaterialBill(template([
            (0, 0, 0, cellValue("oak_planks")), (1, 0, 0, cellValue("water")),
        ]))) { error in
            XCTAssertEqual(error as? TemplateMaterialError, .notPlaceableInSurvival("Water"))
            XCTAssertEqual("\(error)", "Survival can't place Water. Switch to Creative to place this object.")
        }
        XCTAssertThrowsError(try templateMaterialBill(template([(0, 0, 0, cellValue("bedrock"))])))
        XCTAssertThrowsError(try templateMaterialBill(template([(0, 0, 0, cellValue("suspicious_sand"))])))
    }

    func testTheMaterialListNamesTheFirstKindsAndCountsTheRest() {
        let lines = ["oak_planks", "glass", "oak_door", "stone", "dirt", "torch"].enumerated().map {
            TemplateMaterialLine(itemID: iid($0.element), count: $0.offset + 1)
        }
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(1))), "1 Oak Planks")
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(2))), "1 Oak Planks and 2 Glass")
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(4))), "1 Oak Planks, 2 Glass, 3 Oak Door and 4 Stone")
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(5))),
                       "1 Oak Planks, 2 Glass, 3 Oak Door, 4 Stone and 1 more kind")
        XCTAssertEqual(templateMaterialListText(lines), "1 Oak Planks, 2 Glass, 3 Oak Door, 4 Stone and 2 more kinds")
        XCTAssertEqual(TemplateMaterialError.missing(Array(lines.prefix(1))).description,
                       "Missing 1 Oak Planks - nothing was placed.")
        XCTAssertEqual(TemplateMaterialError.noRoomForRefund(stacks: 1).description,
                       "Make room for 1 more stack to undo this object.")
        XCTAssertEqual(TemplateMaterialError.noRoomForRefund(stacks: 3).description,
                       "Make room for 3 more stacks to undo this object.")
    }

    // MARK: - The template a survival paste places

    func testASurvivalPasteCarriesNothingStoredGrownOrPlayed() throws {
        let chest = makeContainerBE(0, 0, 0, 27)
        chest.items?[0] = stack("diamond", 64)
        let jukebox = BlockEntityData(type: "jukebox", x: 1, y: 0, z: 0)
        jukebox.disc = stack("music_disc_wander", 1)
        let pot = BlockEntityData(type: "lectern", x: 2, y: 0, z: 0)
        pot.plant = "poppy"
        let fakePot = BlockEntityData(type: "lectern", x: 3, y: 0, z: 0)
        fakePot.plant = "diamond"
        let object = template([
            (0, 0, 0, cellValue("chest", 2)), (1, 0, 0, cellValue("jukebox")),
            (2, 0, 0, cellValue("flower_pot")), (3, 0, 0, cellValue("flower_pot")),
            (4, 0, 0, cellValue("wheat", 7)), (5, 0, 0, cellValue("furnace_lit", 3)),
            (6, 0, 0, cellValue("respawn_anchor", 4)), (7, 0, 0, cellValue("oak_stairs", 5)),
        ], blockEntities: [chest, jukebox, pot, fakePot])
        let survival = templateForSurvivalPaste(object)
        func block(_ dx: Int) -> Int { Int(survival.blocks.first { $0.dx == dx }!.cell) }
        func entity(_ dx: Int) -> BlockEntityData? { survival.blockEntities.first { $0.x == dx } }

        XCTAssertEqual(block(0), cellValue("chest", 2))
        XCTAssertEqual(entity(0)?.items?.compactMap { $0 }.count, 0, "the chest arrives empty")
        XCTAssertNil(entity(1)?.disc, "the jukebox arrives without its disc")
        XCTAssertEqual(entity(2)?.plant, "poppy")
        XCTAssertNil(entity(3), "a pot holding something that is not a plant arrives empty")
        XCTAssertEqual(block(4), cellValue("wheat", 0))
        XCTAssertEqual(block(5), cellValue("furnace", 3), "the furnace is out and keeps its facing")
        XCTAssertEqual(block(6), cellValue("respawn_anchor", 0))
        XCTAssertEqual(block(7), cellValue("oak_stairs", 5))
        XCTAssertEqual(survival.blocks.count, object.blocks.count)

        let bill = try templateMaterialBill(survival)
        XCTAssertEqual(bill.count(of: iid("poppy")), 1, "only the real potted plant is charged")
        XCTAssertEqual(bill.count(of: iid("diamond")), 0)
        XCTAssertEqual(bill.count(of: iid("wheat_seeds")), 1)
        XCTAssertEqual(bill.count(of: iid("furnace")), 1)
    }

    /// Whatever a template says a block holds, the survival paste gives the block exactly the
    /// entity placing it by hand creates: no items, no disc, no loot table.
    func testEveryBlockOfASurvivalPasteGetsTheBlockEntityOfAHandPlacedOne() {
        for id in 1..<blockDefs.count {
            let stuffed = BlockEntityData(type: "container", x: 0, y: 0, z: 0)
            stuffed.items = Array(repeating: stack("diamond", 64), count: 27)
            stuffed.disc = stack("music_disc_wander", 1)
            stuffed.item = stack("diamond", 1)
            stuffed.lootTable = "chests/simple_dungeon"
            let survival = templateForSurvivalPaste(template([(0, 0, 0, Int(cell(UInt16(id), 0)))],
                                                             blockEntities: [stuffed]))
            let placedID = Int(survival.blocks[0].cell >> 4)   // a lit furnace is placed as a furnace
            let fresh = placementBlockEntity(placedID, 0, 0, 0)
            XCTAssertEqual(survival.blockEntities.count, fresh == nil ? 0 : 1, blockDefs[id].name)
            guard let rebuilt = survival.blockEntities.first else { continue }
            XCTAssertEqual(rebuilt.type, fresh?.type, blockDefs[id].name)
            XCTAssertEqual(rebuilt.items?.compactMap { $0 }.count ?? 0, 0, "\(blockDefs[id].name) holds items")
            XCTAssertNil(rebuilt.disc, blockDefs[id].name)
            XCTAssertNil(rebuilt.item, blockDefs[id].name)
            XCTAssertNil(rebuilt.lootTable, blockDefs[id].name)
            XCTAssertNil(rebuilt.plant, blockDefs[id].name)
        }
    }
}
