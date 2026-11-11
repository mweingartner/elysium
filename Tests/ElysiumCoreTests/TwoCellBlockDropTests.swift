import XCTest
@testable import ElysiumCore

/// A door, a bed and a tall plant are one item on two cells. Only the primary half (the door's
/// lower half, the bed's foot, the plant's base) carries the drop, on every way a block can go.
final class TwoCellBlockDropTests: XCTestCase {
    private func makeFixture() -> (World, Player) {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        let world = World(dim: .overworld, seed: 0xBED2)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        let player = Player(world: world)
        player.setPos(12.5, 64, 12.5)
        return (world, player)
    }

    private func droppedCount(_ world: World, _ itemName: String) -> Int {
        let id = iid(itemName)
        return world.entities.compactMap { $0 as? ItemEntity }
            .filter { $0.stack.id == id }
            .reduce(0) { $0 + $1.stack.count }
    }

    private func breakByHand(_ world: World, _ player: Player, _ x: Int, _ y: Int, _ z: Int) {
        finishBreaking(InteractCtx(world: world, player: player), x, y, z)
    }

    private func giveSilkTouchPickaxe(_ player: Player) {
        player.inventory[0] = ItemStack(iid("diamond_pickaxe"), 1, ench: [EnchInstance("silk_touch", 1)])
        player.selectedSlot = 0
    }

    private let plainContext = DropCtx(fortune: 0, silkTouch: false, toolType: .none, toolTier: 0,
                                       shears: false, random: { 0 })

    // MARK: Classification

    func testEveryTwoCellShapeNamesItsHalves() {
        registerAllBlocks()
        var doors = 0, beds = 0, plants = 0
        for id in 1..<blockDefs.count {
            for meta in 0..<16 {
                let cellValue = Int(cell(UInt16(id), meta))
                switch blockDefs[id].shape {
                case .door:
                    XCTAssertEqual(twoCellHalf(of: cellValue), meta & 8 != 0 ? .secondary : .primary)
                    doors += 1
                case .bed:
                    XCTAssertEqual(twoCellHalf(of: cellValue), meta & 4 != 0 ? .secondary : .primary)
                    beds += 1
                case .tallCross, .smallDripleafShape:
                    XCTAssertEqual(twoCellHalf(of: cellValue), meta & 1 != 0 ? .secondary : .primary)
                    plants += 1
                default:
                    XCTAssertNil(twoCellHalf(of: cellValue), blockDefs[id].name)
                }
            }
        }
        XCTAssertGreaterThan(doors, 0)
        XCTAssertGreaterThan(beds, 0)
        XCTAssertGreaterThan(plants, 0)
        XCTAssertNil(twoCellHalf(of: 0))
        XCTAssertNil(twoCellHalf(of: Int(cell(UInt16(blockDefs.count + 5), 0))), "an unknown block id")
    }

    /// The secondary half's own drop rule yields nothing for every two-cell block, whatever
    /// the tool: this is the rule an explosion and a popped block go by.
    func testNoSecondaryHalfHasADropOfItsOwn() {
        registerAllBlocks()
        registerAllItems()
        let contexts = [
            plainContext,
            DropCtx(fortune: 3, silkTouch: false, toolType: .axe, toolTier: 4, shears: false, random: { 0.999 }),
            DropCtx(fortune: 0, silkTouch: false, toolType: .shears, toolTier: 0, shears: true, random: { 0 }),
        ]
        var checked = 0
        for id in 1..<blockDefs.count {
            for meta in 0..<16 where twoCellHalf(of: Int(cell(UInt16(id), meta))) == .secondary {
                let def = blockDefs[id]
                let rule = def.drops
                XCTAssertNotNil(rule, "\(def.name) must have a drop rule, or its secondary half drops the item")
                for context in contexts {
                    XCTAssertEqual(rule?(meta, context).map(\.item) ?? ["<default>"], [],
                                   "\(def.name) meta \(meta)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    func testTheFootOfEveryBedCarriesItsDrop() throws {
        registerAllBlocks()
        registerAllItems()
        var checked = 0
        for id in 1..<blockDefs.count where blockDefs[id].shape == .bed {
            let def = blockDefs[id]
            let drops = try XCTUnwrap(def.drops)
            for facing in 0..<4 {
                XCTAssertEqual(drops(facing, plainContext).map(\.item), [def.name], "\(def.name) facing \(facing)")
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 16, "every bed colour is checked")
    }

    // MARK: Beds

    /// Foot at (6, 64, 6), head one block north of it (facing 0).
    private func placeBed(in world: World) -> (foot: (Int, Int, Int), head: (Int, Int, Int)) {
        world.setBlock(6, 64, 6, Int(cell(B.red_bed, 0)))
        world.setBlock(6, 64, 5, Int(cell(B.red_bed, 4)))
        return ((6, 64, 6), (6, 64, 5))
    }

    func testBreakingEitherHalfOfABedByHandDropsOneBedAndRemovesBoth() {
        for breakHead in [false, true] {
            let (world, player) = makeFixture()
            let bed = placeBed(in: world)
            let target = breakHead ? bed.head : bed.foot
            breakByHand(world, player, target.0, target.1, target.2)
            XCTAssertEqual(droppedCount(world, "red_bed"), 1, breakHead ? "head" : "foot")
            XCTAssertEqual(world.getBlock(bed.foot.0, bed.foot.1, bed.foot.2), 0)
            XCTAssertEqual(world.getBlock(bed.head.0, bed.head.1, bed.head.2), 0)
        }
    }

    func testABedHeadWithoutItsFootDropsNothingEvenWithSilkTouch() {
        for silk in [false, true] {
            let (world, player) = makeFixture()
            if silk { giveSilkTouchPickaxe(player) }
            world.setBlock(6, 64, 5, Int(cell(B.red_bed, 4)))
            breakByHand(world, player, 6, 64, 5)
            XCTAssertEqual(droppedCount(world, "red_bed"), 0, silk ? "silk touch" : "bare hand")
            XCTAssertEqual(world.getBlock(6, 64, 5), 0)
        }
    }

    func testABedFootWithoutItsHeadStillDropsItsBed() {
        let (world, player) = makeFixture()
        world.setBlock(6, 64, 6, Int(cell(B.red_bed, 0)))
        breakByHand(world, player, 6, 64, 6)
        XCTAssertEqual(droppedCount(world, "red_bed"), 1)
    }

    /// The head of one bed lying where another bed's head would be is not that bed's partner.
    func testABedOnlyTakesItsOwnOtherHalfWithIt() {
        let (world, player) = makeFixture()
        world.setBlock(6, 64, 6, Int(cell(B.red_bed, 0)))            // foot, facing north
        world.setBlock(6, 64, 5, Int(cell(B.blue_bed, 4)))           // another bed's head
        world.setBlock(8, 64, 6, Int(cell(B.red_bed, 0)))            // foot, facing north
        world.setBlock(8, 64, 5, Int(cell(B.red_bed, 4 | 2)))        // a head facing west
        breakByHand(world, player, 6, 64, 6)
        breakByHand(world, player, 8, 64, 6)
        XCTAssertEqual(world.getBlock(6, 64, 5), Int(cell(B.blue_bed, 4)), "another colour stays")
        XCTAssertEqual(world.getBlock(8, 64, 5), Int(cell(B.red_bed, 4 | 2)), "another facing stays")
        XCTAssertEqual(droppedCount(world, "red_bed"), 2)
    }

    /// Power 1 drops every destroyed block (the chance is 1 / power), so the count is exact.
    func testAnExplosionThatDestroysBothHalvesOfABedDropsOneBed() {
        let (world, _) = makeFixture()
        let bed = placeBed(in: world)
        explode(world, 6.5, 64.5, 6.0, 1, false, nil)
        XCTAssertEqual(world.getBlock(bed.foot.0, bed.foot.1, bed.foot.2), 0, "the blast reaches the foot")
        XCTAssertEqual(world.getBlock(bed.head.0, bed.head.1, bed.head.2), 0, "the blast reaches the head")
        XCTAssertEqual(droppedCount(world, "red_bed"), 1)
    }

    // MARK: Doors

    func testBreakingEitherHalfOfADoorByHandDropsOneDoorAndRemovesBoth() {
        for breakUpper in [false, true] {
            let (world, player) = makeFixture()
            world.setBlock(6, 63, 6, Int(cell(B.stone)))
            world.setBlock(6, 64, 6, Int(cell(B.oak_door, 1)))
            world.setBlock(6, 65, 6, Int(cell(B.oak_door, 8)))
            breakByHand(world, player, 6, breakUpper ? 65 : 64, 6)
            XCTAssertEqual(droppedCount(world, "oak_door"), 1, breakUpper ? "upper half" : "lower half")
            XCTAssertEqual(world.getBlock(6, 64, 6), 0)
            XCTAssertEqual(world.getBlock(6, 65, 6), 0)
        }
    }

    func testADoorHalfWithoutItsPartnerLeavesTheNeighbouringBlockAlone() {
        for silk in [false, true] {
            let (world, player) = makeFixture()
            if silk { giveSilkTouchPickaxe(player) }
            // An upper half standing on a chest, and a lower half under a glass block.
            world.setBlock(6, 64, 6, Int(cell(B.chest)))
            world.setBlock(6, 65, 6, Int(cell(B.oak_door, 8)))
            world.setBlock(9, 63, 6, Int(cell(B.stone)))
            world.setBlock(9, 64, 6, Int(cell(B.oak_door, 0)))
            world.setBlock(9, 65, 6, Int(cell(B.glass)))
            breakByHand(world, player, 6, 65, 6)
            XCTAssertEqual(droppedCount(world, "oak_door"), 0, "an upper half alone is worth nothing")
            XCTAssertEqual(world.getBlockId(6, 64, 6), Int(B.chest), "the block under it stays")
            breakByHand(world, player, 9, 64, 6)
            XCTAssertEqual(droppedCount(world, "oak_door"), 1, "a lower half alone is the door")
            XCTAssertEqual(world.getBlockId(9, 65, 6), Int(B.glass), "the block over it stays")
        }
    }

    // MARK: Tall plants

    func testBreakingEitherHalfOfATallFlowerByHandDropsOneFlowerAndRemovesBoth() {
        for breakUpper in [false, true] {
            let (world, player) = makeFixture()
            world.setBlock(6, 63, 6, Int(cell(B.grass_block)))
            world.setBlock(6, 64, 6, Int(cell(B.sunflower, 0)), SET_NO_NEIGHBORS)
            world.setBlock(6, 65, 6, Int(cell(B.sunflower, 1)), SET_NO_NEIGHBORS)
            breakByHand(world, player, 6, breakUpper ? 65 : 64, 6)
            XCTAssertEqual(droppedCount(world, "sunflower"), 1, breakUpper ? "upper half" : "lower half")
            XCTAssertEqual(world.getBlock(6, 64, 6), 0)
            XCTAssertEqual(world.getBlock(6, 65, 6), 0)
        }
    }

    func testTheTopOfATallFlowerWithoutItsBaseDropsNothingEvenWithSilkTouch() {
        for silk in [false, true] {
            let (world, player) = makeFixture()
            if silk { giveSilkTouchPickaxe(player) }
            world.setBlock(6, 64, 6, Int(cell(B.stone)))
            world.setBlock(6, 65, 6, Int(cell(B.sunflower, 1)), SET_NO_NEIGHBORS)
            breakByHand(world, player, 6, 65, 6)
            XCTAssertEqual(droppedCount(world, "sunflower"), 0, silk ? "silk touch" : "bare hand")
            XCTAssertEqual(world.getBlockId(6, 64, 6), Int(B.stone))
        }
    }

    func testTheTopOfASmallDripleafDropsNothingEvenWithSilkTouch() {
        let (world, player) = makeFixture()
        giveSilkTouchPickaxe(player)
        world.setBlock(6, 63, 6, Int(cell(B.clay)))
        world.setBlock(6, 64, 6, Int(cell(B.small_dripleaf, 0)), SET_NO_NEIGHBORS)
        world.setBlock(6, 65, 6, Int(cell(B.small_dripleaf, 1)), SET_NO_NEIGHBORS)
        breakByHand(world, player, 6, 65, 6)
        XCTAssertEqual(droppedCount(world, "small_dripleaf"), 0)
    }
}
