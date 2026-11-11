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
        XCTAssertEqual(survivalMeta("piston", 5 | 8), 5, "a piston is placed retracted, facing kept")
        XCTAssertEqual(survivalMeta("sticky_piston", 1 | 8), 1)
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

    // MARK: - Parts that cannot stand alone

    private func cells(of object: ObjectTemplate) -> [String: Int] {
        var out: [String: Int] = [:]
        for block in object.blocks { out["\(block.dx),\(block.dy),\(block.dz)"] = Int(block.cell) }
        return out
    }

    /// The second half of a door, a bed or a tall plant comes with its first half, and a piston
    /// makes its own head. Placing items by hand cannot put one down alone, so a survival paste
    /// does not either. Left in, it would be free, and it would still be a bed or a door.
    func testASurvivalPasteLeavesOutASecondHalfWithoutItsFirstAndEveryPistonHead() throws {
        let object = template([
            (0, 0, 0, cellValue("oak_door", 1)), (0, 1, 0, cellValue("oak_door", 8)),        // a whole door
            (2, 1, 0, cellValue("oak_door", 8)),                                             // a door top alone
            (3, 0, 1, cellValue("red_bed", 0)), (3, 0, 0, cellValue("red_bed", 4)),          // a whole bed, facing north
            (5, 0, 0, cellValue("red_bed", 4 | 1)),                                          // a bed head alone
            (6, 0, 0, cellValue("sunflower", 0)), (6, 1, 0, cellValue("sunflower", 1)),      // a whole sunflower
            (7, 1, 0, cellValue("sunflower", 1)),                                            // its top alone
            (0, 0, 4, cellValue("piston", 5 | 8)), (1, 0, 4, cellValue("piston_head", 5)),   // an extended piston
            (4, 0, 4, cellValue("piston_head", 1)),                                          // a head alone
        ])
        let placed = cells(of: templateForSurvivalPaste(object))
        XCTAssertEqual(placed, [
            "0,0,0": cellValue("oak_door", 1), "0,1,0": cellValue("oak_door", 8),
            "3,0,1": cellValue("red_bed", 0), "3,0,0": cellValue("red_bed", 4),
            "6,0,0": cellValue("sunflower", 0), "6,1,0": cellValue("sunflower", 1),
            "0,0,4": cellValue("piston", 5),
        ])
        let bill = try templateMaterialBill(templateForSurvivalPaste(object))
        XCTAssertEqual(bill.total, 4, "one door, one bed, one sunflower, one piston")
        for name in ["oak_door", "red_bed", "sunflower", "piston"] { XCTAssertEqual(bill.count(of: iid(name)), 1, name) }
    }

    func testAHalfBesideTheWrongPartnerIsStillALoneHalf() {
        let object = template([
            (0, 0, 0, cellValue("oak_door", 0)), (0, 1, 0, cellValue("spruce_door", 8)),     // another door's top
            (2, 0, 1, cellValue("red_bed", 0)), (2, 0, 0, cellValue("red_bed", 4 | 2)),      // a head facing west
            (4, 0, 1, cellValue("red_bed", 0)), (4, 0, 0, cellValue("blue_bed", 4)),         // another bed's head
            (6, 0, 0, cellValue("oak_door", 8)), (6, 1, 0, cellValue("oak_door", 8)),        // two tops
        ])
        XCTAssertEqual(cells(of: templateForSurvivalPaste(object)), [
            "0,0,0": cellValue("oak_door", 0), "2,0,1": cellValue("red_bed", 0), "4,0,1": cellValue("red_bed", 0),
        ], "the first halves stay: each is the item, and worth one")
    }

    func testAnObjectOfLooseHalvesOnlyCannotBePlacedInSurvival() {
        let halves = template([(0, 0, 0, cellValue("red_bed", 4)), (1, 0, 0, cellValue("oak_door", 8)),
                               (2, 0, 0, cellValue("piston_head", 0))])
        XCTAssertTrue(templateForSurvivalPaste(halves).blocks.isEmpty)
        XCTAssertThrowsError(try templateMaterialBill(templateForSurvivalPaste(halves))) { error in
            XCTAssertEqual(error as? TemplateMaterialError, .nothingToPlace)
            XCTAssertEqual("\(error)", "Survival can't place this object: it holds only parts of blocks. "
                + "Switch to Creative to place it.")
        }
    }

    /// A block entity belongs to its block: when a part is left out, nothing of it stays behind.
    func testNoBlockEntityStaysForAPartThatIsLeftOut() {
        let stray = BlockEntityData(type: "container", x: 0, y: 0, z: 0)
        stray.items = [stack("diamond", 64)]
        let object = template([(0, 0, 0, cellValue("piston_head", 0)), (1, 0, 0, cellValue("oak_planks"))],
                              blockEntities: [stray])
        let survival = templateForSurvivalPaste(object)
        XCTAssertEqual(survival.blocks.count, 1)
        XCTAssertTrue(survival.blockEntities.isEmpty)
    }

    /// A template keeps its blocks' facing when it is turned, except for a bed: its two halves
    /// find each other through their facing, so a turned bed must stay one bed.
    func testABedStaysOneBedWhenItsTemplateIsTurned() throws {
        let object = ObjectTemplate(name: "Bedroom", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 3, sizeY: 1, sizeZ: 2, blocks: [
            TemplateBlock(dx: 0, dy: 0, dz: 1, cell: UInt16(cellValue("red_bed", 0))),
            TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cellValue("red_bed", 4))),
            TemplateBlock(dx: 2, dy: 0, dz: 0, cell: UInt16(cellValue("oak_stairs", 3))),
        ])
        for steps in 0..<4 {
            let turned = try rotatedObjectTemplate(object, rotationSteps: steps)
            var at: [TemplatePos: Int] = [:]
            for block in turned.blocks { at[templatePos(block)] = Int(block.cell) }
            let head = try XCTUnwrap(turned.blocks.first { twoCellHalf(of: Int($0.cell)) == .secondary })
            XCTAssertNotNil(twoCellPartnerCell(of: Int(head.cell), head.dx, head.dy, head.dz) {
                at[TemplatePos(x: $0, y: $1, z: $2)] ?? 0
            }, "turned \(steps) quarter turns, the head has lost its foot")
            XCTAssertEqual(templateForSurvivalPaste(turned).blocks.count, 3, "turned \(steps): nothing is left out")
            XCTAssertEqual(try templateMaterialBill(templateForSurvivalPaste(turned)).count(of: iid("red_bed")), 1)
            XCTAssertTrue(turned.blocks.contains { Int($0.cell) == cellValue("oak_stairs", 3) }, "other blocks keep their facing")
        }
        for facing in 0..<4 {
            var value = UInt16(cellValue("red_bed", 4 | facing))
            for _ in 0..<4 { value = rotatedTemplateCell(value, rotationSteps: 1) }
            XCTAssertEqual(Int(value), cellValue("red_bed", 4 | facing), "four quarter turns are a full turn")
            XCTAssertEqual(rotatedTemplateCell(UInt16(cellValue("red_bed", facing)), rotationSteps: -1),
                           rotatedTemplateCell(UInt16(cellValue("red_bed", facing)), rotationSteps: 3))
        }
    }

    /// Each named reset, over all sixteen metadata values. A case whose name stops matching a
    /// registered block would reset nothing, so every name is looked up first.
    func testEveryNamedResetLeavesTheBlockAsPlantedAndKeepsTheOtherBits() throws {
        let resets: [(name: String, placed: (Int) -> Int)] = [
            ("wheat", { $0 & ~7 }), ("carrots", { $0 & ~7 }), ("potatoes", { $0 & ~7 }),
            ("beetroots", { $0 & ~3 }), ("nether_wart", { $0 & ~3 }), ("sweet_berry_bush", { $0 & ~3 }),
            ("sniffer_egg", { $0 & ~3 }), ("torchflower_crop", { $0 & ~1 }),
            ("melon_stem", { _ in 0 }), ("pumpkin_stem", { _ in 0 }), ("pitcher_crop", { _ in 0 }),
            ("composter", { _ in 0 }), ("cauldron", { _ in 0 }), ("cake", { _ in 0 }),
            ("chorus_flower", { _ in 0 }), ("kelp", { _ in 0 }),
            ("cocoa", { $0 & 3 }), ("turtle_egg", { $0 & 3 }),
            ("cave_vines", { $0 & ~8 }), ("cave_vines_plant", { $0 & ~8 }), ("mangrove_propagule", { $0 & ~8 }),
            ("respawn_anchor", { $0 & ~7 }),
            ("piston", { $0 & 7 }), ("sticky_piston", { $0 & 7 }),
        ]
        for (name, placed) in resets {
            XCTAssertNotNil(bidOpt(name), "\(name) is not a registered block, so its reset is dead")
            guard bidOpt(name) != nil else { continue }
            for meta in 0..<16 {
                XCTAssertEqual(survivalMeta(name, meta), placed(meta), "\(name) meta \(meta)")
            }
            XCTAssertTrue((0..<16).contains { survivalMeta(name, $0) != $0 }, "\(name) has a reset that does something")
        }
        var saplings = 0
        for id in 1..<blockDefs.count where blockDefs[id].name.hasSuffix("_sapling") {
            for meta in 0..<16 {
                XCTAssertEqual(survivalMeta(blockDefs[id].name, meta), meta & ~8, "\(blockDefs[id].name) meta \(meta)")
            }
            saplings += 1
        }
        XCTAssertGreaterThanOrEqual(saplings, 6, "every wood's sapling is checked")

        // Every other block keeps its metadata: a reset nobody named is a change of rule.
        let named = Set(resets.map(\.name))
        for id in 1..<blockDefs.count where !named.contains(blockDefs[id].name) && !blockDefs[id].name.hasSuffix("_sapling") {
            for meta in 0..<16 {
                XCTAssertEqual(survivalMeta(blockDefs[id].name, meta), meta, "\(blockDefs[id].name) meta \(meta)")
            }
        }
    }

    func testALayerOfSnowCostsOneSnowItemForEachLayer() {
        let snow = templateCellCharge(cellValue("snow", 0))
        guard case .item(let itemID, _) = snow else { return XCTFail("\(snow)") }
        for layers in 1...8 {
            XCTAssertEqual(charge("snow", layers - 1), .item(itemID: itemID, count: layers), "\(layers) layers")
            XCTAssertEqual(charge("snow", (layers - 1) | 8), .item(itemID: itemID, count: layers),
                           "the high bit is not a layer")
        }
        XCTAssertEqual(charge("oak_slab", 3), item("oak_slab"), "a slab's third shape is one slab")
        XCTAssertEqual(charge("oak_slab", 2 | 4), item("oak_slab", 2), "a waterlogged double slab is still two")
    }

    // MARK: - What stands in one cell

    func testStandingMaterialsAreWhatTheCellWouldHaveBeenCharged() {
        let world = World(dim: .overworld, seed: 0x57A1)
        let info = dimInfo(.overworld)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height))
        world.setBlock(1, 70, 1, cellValue("flower_pot"), SET_SILENT)
        let pot = BlockEntityData(type: "lectern", x: 1, y: 70, z: 1)
        pot.plant = "poppy"
        world.setBlockEntity(pot)
        world.setBlock(2, 70, 1, cellValue("flower_pot"), SET_SILENT)
        world.setBlock(3, 70, 1, cellValue("oak_door", 8), SET_SILENT)
        world.setBlock(4, 70, 1, cellValue("water"), SET_SILENT)
        world.setBlock(5, 70, 1, cellValue("candle", 3), SET_SILENT)
        world.setBlock(6, 70, 1, cellValue("redstone_torch_off"), SET_SILENT)

        XCTAssertEqual(templateStandingMaterials(in: world, 1, 70, 1),
                       [TemplateMaterialLine(itemID: iid("flower_pot"), count: 1),
                        TemplateMaterialLine(itemID: iid("poppy"), count: 1)])
        XCTAssertEqual(templateStandingMaterials(in: world, 2, 70, 1),
                       [TemplateMaterialLine(itemID: iid("flower_pot"), count: 1)], "an empty pot")
        XCTAssertEqual(templateStandingMaterials(in: world, 3, 70, 1), [], "a door's upper half was free")
        XCTAssertEqual(templateStandingMaterials(in: world, 4, 70, 1), [], "nobody paid for water")
        XCTAssertEqual(templateStandingMaterials(in: world, 5, 70, 1), [TemplateMaterialLine(itemID: iid("candle"), count: 4)])
        XCTAssertEqual(templateStandingMaterials(in: world, 6, 70, 1),
                       [TemplateMaterialLine(itemID: iid("redstone_torch"), count: 1)])
        XCTAssertEqual(templateStandingMaterials(in: world, 7, 70, 1), [], "air")
        XCTAssertEqual(templateStandingMaterials(in: world, 40, 70, 1), [], "a chunk that is not loaded")
    }

    // MARK: - Seeded: what the browser quotes is what the click charges

    /// The browser quotes the template as saved; the click charges it as rotated. For seeded
    /// objects of real blocks and every rotation, the bill is the same, so the quote never
    /// promises a price the click does not keep. The bill is also the same however often it is
    /// worked out, and preparing an already prepared template changes nothing.
    func testTheBillIsTheSameForEveryRotationAndPreparingTwiceChangesNothingForSeededObjects() throws {
        var state: UInt64 = 0xB111_0F00
        func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(max(1, bound)))
        }
        let buyable = (1..<blockDefs.count).filter { id in
            if case .item = templateCellCharge(Int(cell(UInt16(id), 0))) { return true }
            return false
        }
        var compared = 0
        for round in 0..<200 {
            var blocks: [(Int, Int, Int, Int)] = []
            var potted: [BlockEntityData] = []
            for dx in 0..<4 { for dy in 0..<2 { for dz in 0..<3 where next(2) == 0 {
                let id = buyable[next(buyable.count)]
                blocks.append((dx, dy, dz, Int(cell(UInt16(id), next(16)))))
                if id == Int(B.flower_pot) {
                    let pot = BlockEntityData(type: "lectern", x: dx, y: dy, z: dz)
                    pot.plant = ["poppy", "dandelion", "diamond", "oak_sapling"][next(4)]
                    potted.append(pot)
                }
            } } }
            if blocks.isEmpty { continue }
            let object = template(blocks, blockEntities: potted)
            let survival = templateForSurvivalPaste(object)
            XCTAssertEqual(templateForSurvivalPaste(survival).blocks, survival.blocks, "round \(round)")
            let base: TemplateMaterialBill
            do { base = try templateMaterialBill(survival) } catch { continue }
            XCTAssertEqual(try templateMaterialBill(survival), base, "round \(round)")
            for rotation in 1..<4 {
                let rotated = try rotatedObjectTemplate(object, rotationSteps: rotation)
                XCTAssertEqual(try templateMaterialBill(templateForSurvivalPaste(rotated)), base,
                               "round \(round) rotation \(rotation)")
            }
            compared += 1
        }
        XCTAssertGreaterThan(compared, 100, "most seeded objects must be buyable, or this checks nothing")
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
        // The largest counts first, then by name, whatever order the lines come in.
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(1))), "1 Oak Planks")
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(2))), "2 Glass and 1 Oak Planks")
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(4))), "4 Stone, 3 Oak Door, 2 Glass and 1 Oak Planks")
        XCTAssertEqual(templateMaterialListText(Array(lines.prefix(5))),
                       "5 Dirt, 4 Stone, 3 Oak Door, 2 Glass and 1 more kind")
        XCTAssertEqual(templateMaterialListText(lines), "6 Torch, 5 Dirt, 4 Stone, 3 Oak Door and 2 more kinds")
        XCTAssertEqual(templateMaterialListText(lines.reversed()), templateMaterialListText(lines))
        let ties = ["torch", "glass", "oak_planks"].map { TemplateMaterialLine(itemID: iid($0), count: 2) }
        XCTAssertEqual(templateMaterialListText(ties), "2 Glass, 2 Oak Planks and 2 Torch")
        XCTAssertEqual(templateRefusalActionBarText("Missing 12 Oak Planks and 2 Glass - nothing was placed."),
                       "Missing materials - nothing was placed")
        XCTAssertEqual(templateRefusalActionBarText("Survival can't place Water. Switch to Creative to place this object."),
                       "Survival can't place Water")
        XCTAssertEqual(templateRefusalActionBarText(LANTemplateRefusal.outOfReach), LANTemplateRefusal.outOfReach)
        XCTAssertEqual(TemplateError.materials("Missing 1 Dirt - nothing was placed.").actionBarText,
                       "Missing materials - nothing was placed")
        XCTAssertEqual(TemplateError.missingTarget.actionBarText, TemplateError.missingTarget.description)
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

    // MARK: - Deeper: turning beds, pistons, plant halves

    /// A bed's head lies one cell from its foot in the direction it faces. For every bed colour,
    /// every facing and every number of quarter turns, the turned template still has the head
    /// in front of the foot, both halves face the same way, and that way is the old facing turned
    /// as the positions were: north, east, south, west, north. The geometry is the oracle, not
    /// the turning table.
    func testEveryBedOfEveryFacingTurnsWithItsTemplateAndKeepsItsHeadInFront() throws {
        let headOffset = [(0, -1), (0, 1), (-1, 0), (1, 0)]       // facing 0...3: north, south, west, east
        let clockwise = [0: 3, 3: 1, 1: 2, 2: 0]                    // north to east to south to west
        var beds = 0
        for id in 1..<blockDefs.count where blockDefs[id].shape == .bed {
            for facing in 0..<4 {
                let foot = (1 - min(0, headOffset[facing].0), 0, 1 - min(0, headOffset[facing].1))
                let head = (foot.0 + headOffset[facing].0, 0, foot.2 + headOffset[facing].1)
                let object = template([(foot.0, foot.1, foot.2, Int(cell(UInt16(id), facing))),
                                       (head.0, head.1, head.2, Int(cell(UInt16(id), 4 | facing)))])
                var expected = facing
                for steps in 0..<4 {
                    let turned = rotatedValidatedObjectTemplate(object, rotationSteps: steps)
                    let which = "\(blockDefs[id].name) facing \(facing) turned \(steps)"
                    let turnedFoot = try XCTUnwrap(turned.blocks.first { twoCellHalf(of: Int($0.cell)) == .primary }, which)
                    let turnedHead = try XCTUnwrap(turned.blocks.first { twoCellHalf(of: Int($0.cell)) == .secondary }, which)
                    XCTAssertEqual(Int(turnedFoot.cell) & 3, expected, which)
                    XCTAssertEqual(Int(turnedHead.cell) & 3, expected, which)
                    XCTAssertEqual(Int(turnedFoot.cell) >> 4, id, which)
                    XCTAssertEqual([turnedHead.dx - turnedFoot.dx, turnedHead.dy - turnedFoot.dy, turnedHead.dz - turnedFoot.dz],
                                   [headOffset[expected].0, 0, headOffset[expected].1], "\(which): the head is in front of the foot")
                    XCTAssertEqual(templateForSurvivalPaste(turned).blocks.count, 2, which)
                    expected = clockwise[expected]!
                }
            }
            beds += 1
        }
        XCTAssertGreaterThanOrEqual(beds, 16)
    }

    /// Turning changes a bed's two facing bits and nothing else, and no other block at all, for
    /// every block, every metadata value and any number of quarter turns, negative or past a
    /// full turn. Turning n times is turning once n times (metamorphic).
    func testTurningChangesOnlyTheFacingOfABed() {
        for id in 1..<blockDefs.count {
            for meta in 0..<16 {
                let value = cell(UInt16(id), meta)
                var once = value
                for steps in 0...9 {
                    let turned = rotatedTemplateCell(value, rotationSteps: steps)
                    let which = "\(blockDefs[id].name) metadata \(meta) turned \(steps)"
                    if blockDefs[id].shape == .bed {
                        XCTAssertEqual(turned & ~3, value & ~3, which)
                        XCTAssertEqual(turned == value, steps % 4 == 0, "\(which): a bed's facing turns with each quarter turn")
                    } else {
                        XCTAssertEqual(turned, value, which)
                    }
                    XCTAssertEqual(turned, once, "\(which): n turns are n single turns")
                    XCTAssertEqual(rotatedTemplateCell(value, rotationSteps: steps - 8), turned, "\(which): two full turns back")
                    once = rotatedTemplateCell(once, rotationSteps: 1)
                }
            }
        }
        XCTAssertEqual(rotatedTemplateCell(0, rotationSteps: 1), 0, "air")
        XCTAssertEqual(rotatedTemplateCell(cell(UInt16(blockDefs.count + 2), 3), rotationSteps: 1),
                       cell(UInt16(blockDefs.count + 2), 3), "a block id nobody registered")
    }

    /// Two beds that touch end to end, foot to head and head to head, are two beds in every
    /// turn: each head still finds its own foot (not the other bed's), nothing is left out, and
    /// they cost two beds.
    func testTwoBedsTouchingEndToEndStayTwoBedsInEveryTurn() throws {
        let layouts: [(String, [(Int, Int, Int, Int)])] = [
            ("foot to head", [(1, 0, 3, cellValue("red_bed", 0)), (1, 0, 2, cellValue("red_bed", 4)),
                              (1, 0, 1, cellValue("red_bed", 0)), (1, 0, 0, cellValue("red_bed", 4))]),
            ("head to head", [(1, 0, 0, cellValue("red_bed", 1)), (1, 0, 1, cellValue("red_bed", 4 | 1)),
                              (1, 0, 3, cellValue("red_bed", 0)), (1, 0, 2, cellValue("red_bed", 4))]),
            ("side by side, opposite ways", [(0, 0, 0, cellValue("red_bed", 1)), (0, 0, 1, cellValue("red_bed", 4 | 1)),
                                             (1, 0, 1, cellValue("blue_bed", 0)), (1, 0, 0, cellValue("blue_bed", 4))]),
        ]
        for (name, blocks) in layouts {
            let object = ObjectTemplate(name: name, anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 4,
                                        blocks: blocks.map { TemplateBlock(dx: $0.0, dy: $0.1, dz: $0.2, cell: UInt16($0.3)) })
            for steps in 0..<4 {
                let turned = templateForSurvivalPaste(rotatedValidatedObjectTemplate(object, rotationSteps: steps))
                XCTAssertEqual(turned.blocks.count, 4, "\(name) turned \(steps)")
                var at: [TemplatePos: Int] = [:]
                for block in turned.blocks { at[templatePos(block)] = Int(block.cell) }
                // Where each original foot went: its head must be found exactly there.
                for pair in stride(from: 0, to: 4, by: 2) {
                    let foot = blocks[pair]
                    let p = rotatedTemplateCoordinate(x: foot.0, y: foot.1, z: foot.2, sizeX: 2, sizeZ: 4, rotationSteps: steps)
                    let head = blocks[pair + 1]
                    let h = rotatedTemplateCoordinate(x: head.0, y: head.1, z: head.2, sizeX: 2, sizeZ: 4, rotationSteps: steps)
                    let headCell = try XCTUnwrap(at[TemplatePos(x: h.x, y: h.y, z: h.z)])
                    let partner = twoCellPartnerPosition(of: headCell, h.x, h.y, h.z)
                    XCTAssertEqual(partner.map { [$0.x, $0.y, $0.z] }, [p.x, p.y, p.z], "\(name) turned \(steps) pair \(pair / 2)")
                }
                let bill = try templateMaterialBill(turned)
                XCTAssertEqual(bill.total, 2, "\(name) turned \(steps)")
            }
        }
    }

    /// An extended piston or sticky piston of every facing, real or not, is pasted retracted
    /// with its facing kept, and its head never comes along, sticky or not, beside its piston or
    /// not. The bill is one piston.
    func testAnExtendedPistonOfEveryFacingIsPastedRetractedWithoutItsHead() throws {
        for piston in ["piston", "sticky_piston"] {
            for facing in 0..<8 {
                let sticky = piston == "sticky_piston" ? 8 : 0
                let object = template([(1, 1, 1, cellValue(piston, facing | 8)),
                                       (1 + min(1, max(-1, DIR_X[min(facing, 5)])), 1 + DIR_Y[min(facing, 5)],
                                        1 + DIR_Z[min(facing, 5)], cellValue("piston_head", facing | sticky)),
                                       (4, 0, 0, cellValue("piston_head", facing))])
                let survival = templateForSurvivalPaste(object)
                let which = "\(piston) facing \(facing)"
                XCTAssertEqual(survival.blocks.map { Int($0.cell) }, [cellValue(piston, facing)], which)
                let bill = try templateMaterialBill(survival)
                XCTAssertEqual(bill.total, 1, which)
                XCTAssertEqual(bill.count(of: iid(piston)), 1, which)
            }
        }
    }

    /// The plant halves follow the door's rule: a top comes along only with its own base under
    /// it. A small dripleaf top alone or over a dripleaf base of other bits, a lilac top over a
    /// sunflower, a tall seagrass top over seagrass of its own.
    func testATallPlantOrSmallDripleafTopComesAlongOnlyWithItsOwnBase() {
        let object = template([
            (0, 0, 0, cellValue("small_dripleaf", 0)), (0, 1, 0, cellValue("small_dripleaf", 1 | 4)),   // whole, other bits
            (1, 1, 0, cellValue("small_dripleaf", 1)),                                                  // a top alone
            (2, 0, 0, cellValue("sunflower", 0)), (2, 1, 0, cellValue("lilac", 1)),                     // another plant's top
            (3, 0, 0, cellValue("tall_seagrass", 0)), (3, 1, 0, cellValue("tall_seagrass", 1)),         // whole
            (4, 0, 0, cellValue("small_dripleaf", 1)), (4, 1, 0, cellValue("small_dripleaf", 1)),       // two tops stacked
        ])
        XCTAssertEqual(cells(of: templateForSurvivalPaste(object)), [
            "0,0,0": cellValue("small_dripleaf", 0), "0,1,0": cellValue("small_dripleaf", 1 | 4),
            "2,0,0": cellValue("sunflower", 0),
            "3,0,0": cellValue("tall_seagrass", 0), "3,1,0": cellValue("tall_seagrass", 1),
        ])
    }

    // MARK: - Seeded: what a survival paste leaves out

    /// Seeded objects of every two-cell block at every metadata value, as pairs and as loose
    /// halves, of pistons at every metadata value with and without heads, and of planks, with
    /// block entities on some cells. For every object:
    /// - no first half and no other block is ever left out, only second halves and heads;
    /// - every second half that stays has its own first half beside it in the result;
    /// - no piston head stays and every piston is retracted;
    /// - a block entity stays only on a block that stays;
    /// - preparing twice changes nothing;
    /// - turning then preparing (the single-player order) places what preparing then turning
    ///   (the LAN host's order) places, cell for cell, in every turn (metamorphic).
    func testWhatASurvivalPasteLeavesOutHoldsForSeededObjectsInEveryTurn() throws {
        var state: UInt64 = 0x7C0_BED5
        func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(max(1, bound)))
        }
        let twoCell = (1..<blockDefs.count).filter { twoCellHalf(of: Int(cell(UInt16($0), 0))) != nil }
        let pistons = [Int(B.piston), Int(B.sticky_piston)]
        let (sizeX, sizeY, sizeZ) = (5, 3, 4)
        func sorted(_ blocks: [TemplateBlock]) -> [[Int]] {
            blocks.map { [$0.dx, $0.dy, $0.dz, Int($0.cell)] }.sorted { $0.lexicographicallyPrecedes($1) }
        }
        var pairsKept = 0, halvesDropped = 0
        for round in 0..<400 {
            var at: [TemplatePos: Int] = [:]
            for _ in 0..<(2 + next(10)) {
                let p = TemplatePos(x: next(sizeX), y: next(sizeY), z: next(sizeZ))
                switch next(5) {
                case 0, 1:
                    // A first half, and most of the time its own second half where it belongs.
                    let id = twoCell[next(twoCell.count)]
                    let meta = next(16)
                    let primary = Int(cell(UInt16(id), meta)) & ~(blockDefs[id].shape == .door ? 8
                        : blockDefs[id].shape == .bed ? 4 : 1)
                    at[p] = primary
                    if next(4) > 0, let q = twoCellPartnerPosition(of: primary, p.x, p.y, p.z),
                       (0..<sizeX).contains(q.x), (0..<sizeY).contains(q.y), (0..<sizeZ).contains(q.z) {
                        let half = blockDefs[id].shape == .door ? 8 : blockDefs[id].shape == .bed ? 4 : 1
                        // The second half keeps a bed's facing; its other bits are anything.
                        let bits = blockDefs[id].shape == .bed ? (primary & 3) | (next(2) << 3) : next(16)
                        at[TemplatePos(x: q.x, y: q.y, z: q.z)] = Int(cell(UInt16(id), bits | half))
                    }
                case 2:
                    at[p] = Int(cell(UInt16(twoCell[next(twoCell.count)]), next(16)))   // any half, any bits
                case 3:
                    at[p] = Int(cell(UInt16(pistons[next(2)]), next(16)))
                    if next(2) == 0 {
                        let step = dirStep(next(8))
                        at[TemplatePos(x: p.x + step.x, y: p.y + step.y, z: p.z + step.z)] = Int(cell(B.piston_head, next(16)))
                    }
                default:
                    at[p] = cellValue("oak_planks")
                }
            }
            let positions = at.keys.filter {
                (0..<sizeX).contains($0.x) && (0..<sizeY).contains($0.y) && (0..<sizeZ).contains($0.z)
            }.sorted()
            let blocks = positions.map { TemplateBlock(dx: $0.x, dy: $0.y, dz: $0.z, cell: UInt16(at[$0]!)) }
            let entities = positions.filter { _ in next(4) == 0 }.map { BlockEntityData(type: "container", x: $0.x, y: $0.y, z: $0.z) }
            let object = ObjectTemplate(name: "Seeded", anchorX: 0, anchorY: 0, anchorZ: 0,
                                        sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ, blocks: blocks, blockEntities: entities)
            let survival = templateForSurvivalPaste(object)
            let which = "seed 0x7C0BED5 round \(round)"

            var kept: [TemplatePos: Int] = [:]
            for block in survival.blocks { kept[templatePos(block)] = Int(block.cell) }
            for block in object.blocks {
                let id = Int(block.cell >> 4)
                let leftOut = kept[templatePos(block)] == nil
                if blockDefs[id].shape == .pistonHead {
                    XCTAssertTrue(leftOut, "\(which): a piston head stayed")
                } else if twoCellHalf(of: Int(block.cell)) == .secondary {
                    if leftOut { halvesDropped += 1 }
                } else {
                    XCTAssertFalse(leftOut, "\(which): \(blockDefs[id].name) \(block.cell & 15) was left out")
                }
            }
            for block in survival.blocks {
                let value = Int(block.cell)
                if twoCellHalf(of: value) == .secondary {
                    XCTAssertNotNil(twoCellPartnerCell(of: value, block.dx, block.dy, block.dz) { kept[TemplatePos(x: $0, y: $1, z: $2)] ?? 0 },
                                    "\(which): \(blockDefs[value >> 4].name) \(value & 15) stayed without its first half")
                    pairsKept += 1
                }
                if pistons.contains(value >> 4) { XCTAssertEqual(value & 8, 0, "\(which): an extended piston") }
            }
            XCTAssertTrue(survival.blockEntities.allSatisfy { kept[templatePos($0)] != nil }, which)
            XCTAssertEqual(templateForSurvivalPaste(survival).blocks, survival.blocks, "\(which): prepared twice")
            for steps in 1..<4 {
                let turnedFirst = templateForSurvivalPaste(rotatedValidatedObjectTemplate(object, rotationSteps: steps))
                let preparedFirst = rotatedValidatedObjectTemplate(survival, rotationSteps: steps)
                XCTAssertEqual(sorted(turnedFirst.blocks), sorted(preparedFirst.blocks), "\(which) turned \(steps)")
                XCTAssertEqual(turnedFirst.blockEntities.map { [$0.x, $0.y, $0.z] }.sorted { $0.lexicographicallyPrecedes($1) },
                               preparedFirst.blockEntities.map { [$0.x, $0.y, $0.z] }.sorted { $0.lexicographicallyPrecedes($1) },
                               "\(which) turned \(steps): block entities")
            }
        }
        XCTAssertGreaterThan(pairsKept, 200, "the generator must make real pairs, or this checks little")
        XCTAssertGreaterThan(halvesDropped, 100, "and loose halves")
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
            guard let placed = survival.blocks.first else {
                XCTAssertEqual(blockDefs[id].shape, .pistonHead, "\(blockDefs[id].name) was left out of the paste")
                XCTAssertTrue(survival.blockEntities.isEmpty)
                continue
            }
            let placedID = Int(placed.cell >> 4)   // a lit furnace is placed as a furnace
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
