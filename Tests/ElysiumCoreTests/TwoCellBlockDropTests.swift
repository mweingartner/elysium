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

    /// A bed's head lies one cell from its foot in the direction it faces. For each facing,
    /// breaking either half finds the other, removes it and drops one bed.
    func testABedOfEveryFacingBreaksAsOneFromEitherHalf() {
        let headOffset = [(0, -1), (0, 1), (-1, 0), (1, 0)]   // facing 0...3: north, south, west, east
        for facing in 0..<4 {
            for breakHead in [false, true] {
                let (world, player) = makeFixture()
                let foot = (6, 64, 6)
                let head = (6 + headOffset[facing].0, 64, 6 + headOffset[facing].1)
                world.setBlock(foot.0, foot.1, foot.2, Int(cell(B.red_bed, facing)))
                world.setBlock(head.0, head.1, head.2, Int(cell(B.red_bed, 4 | facing)))
                let footPartner = twoCellPartnerPosition(of: Int(cell(B.red_bed, facing)), foot.0, foot.1, foot.2)
                XCTAssertEqual(footPartner.map { [$0.x, $0.y, $0.z] }, [head.0, head.1, head.2], "facing \(facing)")
                let target = breakHead ? head : foot
                breakByHand(world, player, target.0, target.1, target.2)
                let which = "facing \(facing), \(breakHead ? "head" : "foot")"
                XCTAssertEqual(droppedCount(world, "red_bed"), 1, which)
                XCTAssertEqual(world.getBlock(foot.0, foot.1, foot.2), 0, which)
                XCTAssertEqual(world.getBlock(head.0, head.1, head.2), 0, which)
            }
        }
    }

    /// The cell where a partner would be holds the same block, but the same half: two feet end
    /// to end, two door bottoms stacked, two sunflower bases stacked. Neither is the other's
    /// partner, so breaking one leaves the other standing, and each pays out as itself.
    func testTheSameHalfOfTheSameBlockIsNeverTakenForThePartner() {
        let (world, player) = makeFixture()
        world.setBlock(6, 64, 6, Int(cell(B.red_bed, 0)))             // foot facing north
        world.setBlock(6, 64, 5, Int(cell(B.red_bed, 0)))             // another foot where its head would be
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.red_bed, 0)), 6, 64, 6))
        breakByHand(world, player, 6, 64, 6)
        XCTAssertEqual(world.getBlock(6, 64, 5), Int(cell(B.red_bed, 0)), "the other foot stays")
        XCTAssertEqual(droppedCount(world, "red_bed"), 1)

        // Stacked halves lose their support when the lower one goes, so these are asked of the
        // partner rule itself rather than of what stands after a break.
        world.setBlock(10, 64, 6, Int(cell(B.oak_door, 1)), SET_NO_NEIGHBORS)
        world.setBlock(10, 65, 6, Int(cell(B.oak_door, 1)), SET_NO_NEIGHBORS)   // a second lower half
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.oak_door, 1)), 10, 64, 6))
        world.setBlock(10, 66, 6, Int(cell(B.oak_door, 8)), SET_NO_NEIGHBORS)
        world.setBlock(10, 67, 6, Int(cell(B.oak_door, 8)), SET_NO_NEIGHBORS)   // two upper halves
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.oak_door, 8)), 10, 67, 6))
        XCTAssertEqual(twoCellPartnerCell(in: world, of: Int(cell(B.oak_door, 8)), 10, 66, 6), Int(cell(B.oak_door, 1)),
                       "a lower half under an upper half is its partner")

        world.setBlock(3, 64, 3, Int(cell(B.sunflower, 0)), SET_NO_NEIGHBORS)
        world.setBlock(3, 65, 3, Int(cell(B.sunflower, 0)), SET_NO_NEIGHBORS)   // a second base
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.sunflower, 0)), 3, 64, 3))
        world.setBlock(3, 66, 3, Int(cell(B.sunflower, 1)), SET_NO_NEIGHBORS)
        XCTAssertEqual(twoCellPartnerCell(in: world, of: Int(cell(B.sunflower, 0)), 3, 65, 3), Int(cell(B.sunflower, 1)))
    }

    /// The upper half of a different door, or the top of a different tall plant, over a lower
    /// half is not its partner: breaking the lower half leaves it, and breaking it alone gives
    /// nothing.
    func testADifferentBlocksUpperHalfIsNotThePartner() {
        let (world, player) = makeFixture()
        world.setBlock(6, 63, 6, Int(cell(B.stone)))
        world.setBlock(6, 64, 6, Int(cell(B.oak_door, 1)), SET_NO_NEIGHBORS)
        world.setBlock(6, 65, 6, Int(cell(B.birch_door, 8)), SET_NO_NEIGHBORS)
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.oak_door, 1)), 6, 64, 6))
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.birch_door, 8)), 6, 65, 6))
        breakByHand(world, player, 6, 65, 6)
        XCTAssertEqual(droppedCount(world, "birch_door"), 0, "an upper half without its own lower half")

        world.setBlock(9, 63, 6, Int(cell(B.grass_block)))
        world.setBlock(9, 64, 6, Int(cell(B.sunflower, 0)), SET_NO_NEIGHBORS)
        world.setBlock(9, 65, 6, Int(cell(B.lilac, 1)), SET_NO_NEIGHBORS)
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.sunflower, 0)), 9, 64, 6))
        breakByHand(world, player, 9, 65, 6)
        XCTAssertEqual(droppedCount(world, "lilac"), 0, "a lilac top over a sunflower is worth nothing")
        XCTAssertEqual(droppedCount(world, "sunflower"), 0, "and it is not the sunflower's top either")
        XCTAssertEqual(world.getBlockId(9, 64, 6), Int(B.sunflower), "the sunflower is not taken with it")
    }

    func testAPartnerIsOnlyLookedForAroundATwoCellBlock() {
        let (world, _) = makeFixture()
        XCTAssertNil(twoCellPartnerPosition(of: Int(cell(B.stone)), 1, 64, 1))
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.stone)), 1, 64, 1))
        XCTAssertNil(twoCellPartnerCell(in: world, of: 0, 1, 64, 1))
        let up = twoCellPartnerPosition(of: Int(cell(B.oak_door, 0)), 1, 64, 1)
        XCTAssertEqual(up.map { [$0.x, $0.y, $0.z] }, [1, 65, 1])
        let down = twoCellPartnerPosition(of: Int(cell(B.oak_door, 8)), 1, 64, 1)
        XCTAssertEqual(down.map { [$0.x, $0.y, $0.z] }, [1, 63, 1])
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

    // MARK: A half is not the block

    private func use(_ world: World, _ player: Player, _ x: Int, _ y: Int, _ z: Int) -> Bool {
        let hit = RaycastHit(x: x, y: y, z: z, face: 1, cell: world.getBlock(x, y, z), t: 1,
                             px: Double(x) + 0.5, py: Double(y) + 1, pz: Double(z) + 0.5)
        return useBlock(InteractCtx(world: world, player: player), hit)
    }

    /// Opening a door writes the open state into its lower half. A top half without a door under
    /// it used to write that into whatever stood there, and turned dirt into a door.
    func testADoorHalfWithoutItsPartnerCannotBeOpenedAndChangesNothing() {
        let (world, player) = makeFixture()
        world.setBlock(6, 64, 6, Int(cell(B.dirt)))
        world.setBlock(6, 65, 6, Int(cell(B.oak_door, 8)))
        world.setBlock(9, 63, 6, Int(cell(B.stone)))
        world.setBlock(9, 64, 6, Int(cell(B.oak_door, 0)))
        world.setBlock(9, 65, 6, Int(cell(B.stone)))
        XCTAssertFalse(use(world, player, 6, 65, 6))
        XCTAssertEqual(world.getBlock(6, 64, 6), Int(cell(B.dirt)), "the dirt under a loose door top stays dirt")
        XCTAssertFalse(use(world, player, 9, 64, 6))
        XCTAssertEqual(world.getBlock(9, 64, 6), Int(cell(B.oak_door, 0)))
        XCTAssertEqual(world.getBlock(9, 65, 6), Int(cell(B.stone)))
    }

    /// A door that loses the block under it breaks, and its upper half goes with it. The lower
    /// half of a door that has no upper half used to take whatever stood above it instead: any
    /// block, with no drop.
    func testADoorThatLosesItsSupportTakesOnlyItsOwnUpperHalf() {
        let (world, _) = makeFixture()
        registerAllSystems()                                // the door's neighbour handler
        let door = Int(B.oak_door)
        // A lone lower half under a chest, standing on nothing solid.
        world.setBlock(6, 64, 6, Int(cell(B.oak_door, 0)), SET_NO_NEIGHBORS)
        world.setBlock(6, 65, 6, Int(cell(B.chest, 2)), SET_NO_NEIGHBORS)
        neighborHandlers[door]?(world, 6, 64, 6, world.getBlock(6, 64, 6), 6, 63, 6)
        XCTAssertEqual(world.getBlock(6, 64, 6), 0, "the unsupported half breaks")
        XCTAssertEqual(world.getBlock(6, 65, 6), Int(cell(B.chest, 2)), "the chest above it is not the door's")
        // A whole door on nothing solid: both halves go.
        world.setBlock(9, 64, 6, Int(cell(B.oak_door, 0)), SET_NO_NEIGHBORS)
        world.setBlock(9, 65, 6, Int(cell(B.oak_door, 8)), SET_NO_NEIGHBORS)
        neighborHandlers[door]?(world, 9, 64, 6, world.getBlock(9, 64, 6), 9, 63, 6)
        XCTAssertEqual(world.getBlock(9, 64, 6), 0)
        XCTAssertEqual(world.getBlock(9, 65, 6), 0)
    }

    func testAWholeDoorStillOpensFromEitherHalf() {
        let (world, player) = makeFixture()
        world.setBlock(6, 63, 6, Int(cell(B.stone)))
        world.setBlock(6, 64, 6, Int(cell(B.oak_door, 1)))
        world.setBlock(6, 65, 6, Int(cell(B.oak_door, 8)))
        XCTAssertTrue(use(world, player, 6, 65, 6))
        XCTAssertEqual(world.getBlock(6, 64, 6), Int(cell(B.oak_door, 1 ^ 4)))
        XCTAssertTrue(use(world, player, 6, 64, 6))
        XCTAssertEqual(world.getBlock(6, 64, 6), Int(cell(B.oak_door, 1)))
    }

    /// Half a bed gives no spawn point and, where beds explode, no explosion.
    func testHalfABedIsNoBed() {
        for head in [true, false] {
            let (world, player) = makeFixture()
            let before = player.spawnPoint.map { [$0.0, $0.1, $0.2] }
            world.setBlock(6, 64, 6, Int(cell(B.red_bed, head ? 4 : 0)))
            XCTAssertFalse(use(world, player, 6, 64, 6), head ? "head" : "foot")
            XCTAssertEqual(player.spawnPoint.map { [$0.0, $0.1, $0.2] }, before)
            XCTAssertEqual(world.getBlockId(6, 64, 6), Int(B.red_bed))
        }
        let nether = World(dim: .nether, seed: 0xBED3)
        let info = dimInfo(.nether)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.buildHeightmap()
        nether.setChunk(chunk)
        nether.light.initChunkLight(chunk)
        let visitor = Player(world: nether)
        visitor.setPos(12.5, 64, 12.5)
        nether.setBlock(6, 64, 6, Int(cell(B.red_bed, 4)))
        nether.setBlock(6, 64, 8, Int(cell(B.glass)))
        XCTAssertFalse(use(nether, visitor, 6, 64, 6))
        XCTAssertEqual(nether.getBlockId(6, 64, 6), Int(B.red_bed), "a loose head does not explode")
        XCTAssertEqual(nether.getBlockId(6, 64, 8), Int(B.glass))
    }

    func testAWholeBedSetsTheSpawnPointFromEitherHalf() {
        for useHead in [true, false] {
            let (world, player) = makeFixture()
            let bed = placeBed(in: world)
            let target = useHead ? bed.head : bed.foot
            XCTAssertTrue(use(world, player, target.0, target.1, target.2))
            XCTAssertEqual(player.spawnPoint.map { [$0.0, $0.1, $0.2] }, [target.0, target.1, target.2])
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

    // MARK: Deeper: halves that disagree, and halves of other blocks

    /// A door's upper half carries bits of its own (the hinge, in vanilla) that need not agree
    /// with the lower half's facing and open bits. They are still one door: using either half
    /// flips the open bit of the lower half and nothing else, for every pair of metadata values.
    func testEveryDoorOpensFromEitherHalfWhateverItsUpperHalfCarries() {
        let (world, player) = makeFixture()
        world.setBlock(6, 63, 6, Int(cell(B.stone)))
        for upperMeta in 8..<16 {
            for lowerMeta in 0..<8 {
                for useUpper in [false, true] {
                    world.setBlock(6, 64, 6, Int(cell(B.oak_door, lowerMeta)), SET_NO_NEIGHBORS)
                    world.setBlock(6, 65, 6, Int(cell(B.oak_door, upperMeta)), SET_NO_NEIGHBORS)
                    let which = "lower \(lowerMeta), upper \(upperMeta), \(useUpper ? "upper" : "lower") used"
                    XCTAssertTrue(use(world, player, 6, useUpper ? 65 : 64, 6), which)
                    XCTAssertEqual(world.getBlock(6, 64, 6), Int(cell(B.oak_door, lowerMeta ^ 4)), which)
                    XCTAssertEqual(world.getBlock(6, 65, 6), Int(cell(B.oak_door, upperMeta)), which)
                    XCTAssertEqual(world.getBlock(6, 63, 6), Int(cell(B.stone)), which)
                }
            }
        }
    }

    /// Opening writes the door's own id into the lower half. Before a half without its partner
    /// was refused, a birch top over an oak bottom turned the oak door into a birch one.
    func testADoorHalfOverAnotherDoorsHalfCannotBeOpenedAndNeitherDoorChanges() {
        let (world, player) = makeFixture()
        world.setBlock(6, 63, 6, Int(cell(B.stone)))
        world.setBlock(6, 64, 6, Int(cell(B.oak_door, 1)), SET_NO_NEIGHBORS)
        world.setBlock(6, 65, 6, Int(cell(B.birch_door, 8)), SET_NO_NEIGHBORS)
        XCTAssertFalse(use(world, player, 6, 65, 6), "a birch top over an oak bottom")
        XCTAssertFalse(use(world, player, 6, 64, 6), "an oak bottom under a birch top")
        XCTAssertEqual(world.getBlock(6, 64, 6), Int(cell(B.oak_door, 1)), "the oak door stays oak and closed")
        XCTAssertEqual(world.getBlock(6, 65, 6), Int(cell(B.birch_door, 8)))
    }

    /// Every door a hand can open, with a lone top of every metadata value over a block that is
    /// not a door: the block under it is never written.
    func testALoneTopOfEveryWoodenDoorLeavesTheBlockUnderItAlone() {
        let (world, player) = makeFixture()
        var doors = 0
        for id in 1..<blockDefs.count where blockDefs[id].shape == .door && id != Int(B.iron_door) {
            for upperMeta in 8..<16 {
                world.setBlock(6, 64, 6, Int(cell(B.dirt)), SET_NO_NEIGHBORS)
                world.setBlock(6, 65, 6, Int(cell(UInt16(id), upperMeta)), SET_NO_NEIGHBORS)
                XCTAssertFalse(use(world, player, 6, 65, 6), "\(blockDefs[id].name) \(upperMeta)")
                XCTAssertEqual(world.getBlock(6, 64, 6), Int(cell(B.dirt)), "\(blockDefs[id].name) \(upperMeta)")
                XCTAssertEqual(world.getBlock(6, 65, 6), Int(cell(UInt16(id), upperMeta)))
            }
            doors += 1
        }
        XCTAssertGreaterThan(doors, 8, "every wood's door is checked")
    }

    /// A bed of every facing works from either half; a foot or a head of every facing alone does
    /// not; and a head lying where its foot's head belongs but facing another way, or of another
    /// colour, is not that bed's head, so neither half is a bed.
    func testABedIsABedOnlyWithItsOwnOtherHalfInEveryFacing() {
        let headOffset = [(0, -1), (0, 1), (-1, 0), (1, 0)]
        for facing in 0..<4 {
            let foot = (6, 64, 6)
            let head = (6 + headOffset[facing].0, 64, 6 + headOffset[facing].1)
            for useHead in [false, true] {
                let target = useHead ? head : foot
                let which = "facing \(facing), \(useHead ? "head" : "foot")"

                let (world, player) = makeFixture()
                world.setBlock(foot.0, foot.1, foot.2, Int(cell(B.red_bed, facing)))
                world.setBlock(head.0, head.1, head.2, Int(cell(B.red_bed, 4 | facing)))
                XCTAssertTrue(use(world, player, target.0, target.1, target.2), "whole, \(which)")
                XCTAssertEqual(player.spawnPoint.map { [$0.0, $0.1, $0.2] }, [target.0, target.1, target.2], which)

                for half in ["alone", "turned", "recoloured"] {
                    let (world, player) = makeFixture()
                    let before = player.spawnPoint.map { [$0.0, $0.1, $0.2] }
                    let otherHalf = useHead ? foot : head
                    let ownCell = Int(cell(B.red_bed, (useHead ? 4 : 0) | facing))
                    world.setBlock(target.0, target.1, target.2, ownCell)
                    switch half {
                    case "turned":
                        world.setBlock(otherHalf.0, otherHalf.1, otherHalf.2,
                                       Int(cell(B.red_bed, (useHead ? 0 : 4) | ((facing + 1) % 4))))
                    case "recoloured":
                        world.setBlock(otherHalf.0, otherHalf.1, otherHalf.2,
                                       Int(cell(B.blue_bed, (useHead ? 0 : 4) | facing)))
                    default:
                        break
                    }
                    XCTAssertFalse(use(world, player, target.0, target.1, target.2), "\(half), \(which)")
                    XCTAssertEqual(player.spawnPoint.map { [$0.0, $0.1, $0.2] }, before, "\(half), \(which)")
                    XCTAssertEqual(world.getBlock(target.0, target.1, target.2), ownCell, "\(half), \(which)")
                }
            }
        }
    }

    /// Two beds laid foot to head, and two laid head to head. Each half partners only its own
    /// bed's other half, so breaking one bed leaves the other whole and working.
    func testTwoBedsTouchingEndToEndAreTwoBeds() {
        // Foot to head, both facing north: A's foot at z 9, head at z 8; B's foot at z 7, head at z 6.
        // Head to head: C faces south (foot z 2, head z 3); D faces north (foot z 5, head z 4).
        let layouts: [(name: String, cells: [((Int, Int, Int), Int)], broken: (Int, Int, Int),
                       survivor: [(Int, Int, Int)])] = [
            ("foot to head", [((6, 64, 9), 0), ((6, 64, 8), 4), ((6, 64, 7), 0), ((6, 64, 6), 4)],
             (6, 64, 8), [(6, 64, 7), (6, 64, 6)]),
            ("head to head", [((6, 64, 2), 1), ((6, 64, 3), 4 | 1), ((6, 64, 5), 0), ((6, 64, 4), 4)],
             (6, 64, 3), [(6, 64, 5), (6, 64, 4)]),
        ]
        for layout in layouts {
            let (world, player) = makeFixture()
            for (at, meta) in layout.cells { world.setBlock(at.0, at.1, at.2, Int(cell(B.red_bed, meta))) }
            // Each half's partner is the next cell of its own pair, never the neighbouring bed.
            for pair in stride(from: 0, to: 4, by: 2) {
                let a = layout.cells[pair], b = layout.cells[pair + 1]
                XCTAssertEqual(twoCellPartnerCell(in: world, of: world.getBlock(a.0.0, a.0.1, a.0.2), a.0.0, a.0.1, a.0.2),
                               Int(cell(B.red_bed, b.1)), "\(layout.name): pair \(pair / 2)")
                XCTAssertEqual(twoCellPartnerCell(in: world, of: world.getBlock(b.0.0, b.0.1, b.0.2), b.0.0, b.0.1, b.0.2),
                               Int(cell(B.red_bed, a.1)), "\(layout.name): pair \(pair / 2)")
            }
            breakByHand(world, player, layout.broken.0, layout.broken.1, layout.broken.2)
            XCTAssertEqual(droppedCount(world, "red_bed"), 1, layout.name)
            for at in layout.survivor {
                XCTAssertEqual(world.getBlockId(at.0, at.1, at.2), Int(B.red_bed), "\(layout.name): the other bed stays")
            }
            let rest = layout.survivor[0]
            XCTAssertTrue(use(world, player, rest.0, rest.1, rest.2), "\(layout.name): and is still a bed")
        }
    }

    /// The partner rule for the plant halves: only the same block's other half above or below,
    /// whatever other bits the halves carry. A small dripleaf under a sunflower top, or a lilac
    /// top over a sunflower base, stands alone.
    func testAPlantHalfPartnersOnlyItsOwnBlocksOtherHalfWhateverItsOtherBits() {
        let (world, player) = makeFixture()
        for plant in [B.small_dripleaf, B.sunflower, B.tall_seagrass] {
            for baseMeta in stride(from: 0, to: 16, by: 2) {
                for topMeta in stride(from: 1, to: 16, by: 2) {
                    world.setBlock(3, 64, 3, Int(cell(plant, baseMeta)), SET_NO_NEIGHBORS)
                    world.setBlock(3, 65, 3, Int(cell(plant, topMeta)), SET_NO_NEIGHBORS)
                    let which = "\(blockDefs[Int(plant)].name) base \(baseMeta) top \(topMeta)"
                    XCTAssertEqual(twoCellPartnerCell(in: world, of: Int(cell(plant, baseMeta)), 3, 64, 3),
                                   Int(cell(plant, topMeta)), which)
                    XCTAssertEqual(twoCellPartnerCell(in: world, of: Int(cell(plant, topMeta)), 3, 65, 3),
                                   Int(cell(plant, baseMeta)), which)
                }
            }
        }
        world.setBlock(9, 63, 6, Int(cell(B.clay)))
        world.setBlock(9, 64, 6, Int(cell(B.small_dripleaf, 0)), SET_NO_NEIGHBORS)
        world.setBlock(9, 65, 6, Int(cell(B.sunflower, 1)), SET_NO_NEIGHBORS)
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.small_dripleaf, 0)), 9, 64, 6))
        XCTAssertNil(twoCellPartnerCell(in: world, of: Int(cell(B.sunflower, 1)), 9, 65, 6))
        breakByHand(world, player, 9, 65, 6)
        XCTAssertEqual(droppedCount(world, "sunflower"), 0, "a sunflower top over a dripleaf is worth nothing")
        XCTAssertEqual(world.getBlock(9, 64, 6), Int(cell(B.small_dripleaf, 0)), "and takes nothing with it")
    }
}
