import XCTest
@testable import ElysiumCore

final class TreeEcologyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        registerAllBlocks(); registerAllItems(); registerAllEntities(); registerFarmingHandlers()
    }

    private func world(seed: UInt32 = 42, radius: Int = 1) -> World {
        let world = World(dim: .overworld, seed: seed)
        world.randomTickSpeed = 0
        world.gameRules["doWeatherCycle"] = 0
        let info = world.info
        for cz in -radius...radius { for cx in -radius...radius {
            let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
            for z in 0..<16 { for x in 0..<16 { chunk.set(x, 63, z, cell(B.dirt)) } }
            chunk.buildHeightmap(); chunk.status = .generated
            world.setChunk(chunk)
        } }
        return world
    }

    private func advance(_ world: World, _ ticks: Int) {
        world.ecologyCalendar.advance(ticks: ticks)
        world.treeEcology.tick(in: world)
    }

    @discardableResult
    private func growOak(_ world: World) -> Chunk {
        world.setBlock(8, 64, 8, Int(cell(B.oak_sapling)))
        XCTAssertTrue(growTreeAt(world, 8, 64, 8, Int(B.oak_sapling)))
        let chunk = world.getChunk(0, 0)!
        XCTAssertGreaterThan(chunk.naturalTreeCells.count, 20)
        advance(world, 1)
        return chunk
    }

    private func natural(_ world: World, _ x: Int, _ y: Int, _ z: Int,
                         _ value: UInt16, origin: NaturalTreeOrigin) {
        world.setBlock(x, y, z, Int(value))
        let chunk = world.getChunkAt(x, z)!
        chunk.naturalTreeCells[chunk.index(posMod(x, 16), y, posMod(z, 16))] =
            NaturalTreeCell(origin: origin, expected: value)
    }

    func testSeveredNaturalTreeProgressivelyDecaysWithinOneEcologicalDay() {
        let world = world()
        let chunk = growOak(world)
        let initial = chunk.naturalTreeCells.count
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick == nil })
        world.setBlock(8, 64, 8, 0)
        advance(world, 1)
        XCTAssertEqual(chunk.naturalTreeCells.count, initial - 1)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick != nil })
        advance(world, DAY_LENGTH / 2)
        XCTAssertGreaterThan(chunk.naturalTreeCells.count, 0)
        XCTAssertLessThan(chunk.naturalTreeCells.count, initial - 1)
        advance(world, DAY_LENGTH / 2)
        XCTAssertTrue(chunk.naturalTreeCells.isEmpty)
    }

    func testPlacedAndLegacyWoodNeverAcquireDecayProvenance() {
        let world = world()
        let chunk = growOak(world)
        world.setBlock(13, 68, 8, Int(cell(B.oak_log)))
        world.setBlock(14, 68, 8, Int(cell(B.oak_leaves, 8)))
        world.setBlock(8, 64, 8, 0)
        advance(world, 1); advance(world, DAY_LENGTH)
        XCTAssertTrue(chunk.naturalTreeCells.isEmpty)
        XCTAssertEqual(world.getBlock(13, 68, 8), Int(cell(B.oak_log)))
        XCTAssertEqual(world.getBlock(14, 68, 8), Int(cell(B.oak_leaves, 8)))
    }

    func testPlayerCanReconnectNaturalTrunkWithoutMakingRepairLogNatural() {
        let world = world()
        let chunk = growOak(world)
        world.setBlock(8, 64, 8, 0); advance(world, 1)
        world.setBlock(8, 64, 8, Int(cell(B.oak_log))); advance(world, 1)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick == nil })
        XCTAssertNil(chunk.naturalTreeCells[chunk.index(8, 64, 8)])
        advance(world, DAY_LENGTH)
        XCTAssertGreaterThan(chunk.naturalTreeCells.count, 20)
    }

    func testDiagonalBranchesStaySupported() {
        let world = world()
        let origin = NaturalTreeOrigin(x: 8, y: 64, z: 8)
        natural(world, 8, 64, 8, cell(B.cherry_log), origin: origin)
        natural(world, 9, 65, 9, cell(B.cherry_log), origin: origin)
        natural(world, 10, 66, 10, cell(B.cherry_log), origin: origin)
        natural(world, 11, 67, 10, cell(B.cherry_leaves, 4), origin: origin)
        let chunk = world.getChunk(0, 0)!
        world.treeEcology.adopt(chunk: chunk, in: world)
        advance(world, 1); advance(world, DAY_LENGTH)
        XCTAssertEqual(chunk.naturalTreeCells.count, 4)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick == nil })
    }

    func testUnloadedBoundaryDefersRatherThanTreatingMissingChunkAsAir() {
        let world = world()
        let chunk = growOak(world)
        world.removeChunk(-1, -1)
        world.setBlock(8, 64, 8, 0)
        advance(world, 1); advance(world, DAY_LENGTH)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick == nil })
        XCTAssertGreaterThan(chunk.naturalTreeCells.count, 20)
    }

    func testDeferredOriginsDoNotStarveLoadedTree() {
        let world = world()
        for cx in -12 ... -3 {
            let chunk = Chunk(cx: cx, cz: 0, minY: world.info.minY, height: world.info.height)
            world.setChunk(chunk)
            let origin = NaturalTreeOrigin(x: cx * 16 + 8, y: 64, z: 8)
            natural(world, origin.x, 65, 8, cell(B.oak_log), origin: origin)
            world.treeEcology.adopt(chunk: chunk, in: world)
        }
        let origin = NaturalTreeOrigin(x: 8, y: 64, z: 8)
        natural(world, 8, 65, 8, cell(B.oak_log), origin: origin)
        let chunk = world.getChunk(0, 0)!
        world.treeEcology.adopt(chunk: chunk, in: world)
        for _ in 0..<5 { advance(world, 1) }
        XCTAssertNotNil(chunk.naturalTreeCells[chunk.index(8, 65, 8)]?.decayStartTick)
    }

    func testGrowthCannotOverwriteRoofOrContainerAndLeavesSaplingIntact() {
        let world = world()
        world.setBlock(8, 64, 8, Int(cell(B.oak_sapling)))
        world.setBlock(8, 66, 8, Int(cell(B.chest)))
        let before = world.getChunk(0, 0)!.blocks
        XCTAssertFalse(growTreeAt(world, 8, 64, 8, Int(B.oak_sapling)))
        XCTAssertEqual(world.getChunk(0, 0)!.blocks, before)
        XCTAssertTrue(world.getChunk(0, 0)!.naturalTreeCells.isEmpty)
    }

    func testGrowthAtUnloadedEdgeDoesNotPartiallyReplaceSapling() {
        let world = world(radius: 0)
        world.setBlock(15, 64, 15, Int(cell(B.oak_sapling)))
        let before = world.getChunk(0, 0)!.blocks
        XCTAssertFalse(growTreeAt(world, 15, 64, 15, Int(B.oak_sapling)))
        XCTAssertEqual(world.getChunk(0, 0)!.blocks, before)
    }

    func testMangroveAndAzaleaSaplingsUseSafeGrowthAndNaturalProvenance() {
        for sapling in [B.mangrove_propagule, B.azalea, B.flowering_azalea] {
            let world = world()
            world.setBlock(8, 64, 8, Int(cell(sapling)))
            XCTAssertTrue(growTreeAt(world, 8, 64, 8, Int(sapling)), blockDefs[Int(sapling)].name)
            let chunk = world.getChunk(0, 0)!
            XCTAssertGreaterThan(chunk.naturalTreeCells.count, 10)
            advance(world, 1)
            let unsupported = chunk.naturalTreeCells.filter { $0.value.decayStartTick != nil }.map {
                "\(chunk.idxToWorld($0.key)): \(blockDefs[Int($0.value.expected >> 4)].name)"
            }.sorted()
            XCTAssertTrue(unsupported.isEmpty, "\(blockDefs[Int(sapling)].name): \(unsupported)")
        }
    }

    func testSeedlingPlantingRequiresClearSoilAndSpacing() {
        let world = world()
        XCTAssertTrue(TreeEcologyRuntime.plantSeedling(B.oak_sapling, x: 8, startY: 72, z: 8, in: world))
        XCTAssertEqual(world.getBlockId(8, 64, 8), Int(B.oak_sapling))
        XCTAssertFalse(TreeEcologyRuntime.plantSeedling(B.oak_sapling, x: 9, startY: 72, z: 8, in: world))
        world.setBlock(3, 64, 3, Int(cell(B.water)))
        XCTAssertFalse(TreeEcologyRuntime.plantSeedling(B.oak_sapling, x: 3, startY: 72, z: 3, in: world))
    }

    func testMangroveRootsAttachedBelowSoilDecayOnlyAfterAttachmentIsRemoved() {
        let world = world()
        let origin = NaturalTreeOrigin(x: 8, y: 64, z: 8)
        natural(world, 8, 61, 8, cell(B.mangrove_roots), origin: origin)
        natural(world, 8, 62, 8, cell(B.mangrove_roots), origin: origin)
        let chunk = world.getChunk(0, 0)!
        world.treeEcology.adopt(chunk: chunk, in: world)
        advance(world, 1)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick == nil })
        world.setBlock(8, 63, 8, 0); advance(world, 1)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick != nil })
        advance(world, DAY_LENGTH)
        XCTAssertTrue(chunk.naturalTreeCells.isEmpty)
    }

    func testTransientClientCannotGrowPlantOrDecayTrees() {
        let world = world()
        let chunk = growOak(world)
        world.isTransientLANClient = true
        world.setBlock(8, 64, 8, 0)
        let count = chunk.naturalTreeCells.count
        advance(world, DAY_LENGTH)
        XCTAssertEqual(chunk.naturalTreeCells.count, count)
        world.setBlock(3, 64, 3, Int(cell(B.oak_sapling)))
        XCTAssertFalse(growTreeAt(world, 3, 64, 3, Int(B.oak_sapling)))
        XCTAssertFalse(TreeEcologyRuntime.plantSeedling(B.oak_sapling, x: 4, startY: 72, z: 4, in: world))
    }

    func testCodecRejectsHostileExtremeCoordinatesAndDuplicateIndexes() throws {
        let origin = NaturalTreeOrigin(x: Int.min, y: 64, z: 0)
        let records = [1: NaturalTreeCell(origin: origin, expected: cell(B.oak_log))]
        let text = try XCTUnwrap(NaturalTreePersistence.encode(records))
        XCTAssertTrue(NaturalTreePersistence.decode(text, height: 384).isEmpty)
        let duplicate = "[{\"index\":1,\"record\":{\"origin\":{\"x\":0,\"y\":64,\"z\":0},\"expected\":\(cell(B.oak_log))}},{\"index\":1,\"record\":{\"origin\":{\"x\":0,\"y\":64,\"z\":0},\"expected\":\(cell(B.oak_log))}}]"
        XCTAssertTrue(NaturalTreePersistence.decode(duplicate, height: 384).isEmpty)
    }

    func testRemovingSoilUnderMultiLogRepairInvalidatesNaturalCrown() {
        let world = world()
        let origin = NaturalTreeOrigin(x: 8, y: 64, z: 8)
        for y in 64...68 { world.setBlock(8, y, 8, Int(cell(B.oak_log))) }
        natural(world, 8, 69, 8, cell(B.oak_log), origin: origin)
        natural(world, 8, 70, 8, cell(B.oak_leaves, 4), origin: origin)
        let chunk = world.getChunk(0, 0)!
        world.treeEcology.adopt(chunk: chunk, in: world)
        advance(world, 1)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick == nil })
        world.setBlock(8, 63, 8, 0); advance(world, 1)
        XCTAssertTrue(chunk.naturalTreeCells.values.allSatisfy { $0.decayStartTick != nil })
        advance(world, DAY_LENGTH)
        XCTAssertTrue(chunk.naturalTreeCells.isEmpty)
        XCTAssertEqual(world.getBlockId(8, 68, 8), Int(B.oak_log))
    }

    func testTopBuildHeightMutationDoesNotCreateInvalidSupportRange() {
        let world = world()
        let top = world.info.minY + world.info.height - 1
        world.setBlock(8, top, 8, Int(cell(B.oak_log)))
        world.setBlock(8, top, 8, 0)
        XCTAssertEqual(world.getBlock(8, top, 8), 0)
    }

    func testLeafDecayDropsCollectibleSeedsAndGrowsSomeSelfPlantedTrees() throws {
        let world = world(seed: 43)
        let origin = NaturalTreeOrigin(x: 8, y: 64, z: 8)
        for z in 0..<16 { for x in 0..<16 {
            natural(world, x, 70, z, cell(B.oak_leaves, 4), origin: origin)
        } }
        world.treeEcology.adopt(chunk: world.getChunk(0, 0)!, in: world)
        advance(world, 1); advance(world, DAY_LENGTH)
        let drops = world.entities.compactMap { $0 as? ItemEntity }
        XCTAssertGreaterThan(drops.count, 0)
        XCTAssertTrue(drops.allSatisfy { $0.stack.id == iid("oak_sapling") && $0.stack.count == 1 })
        var planted: [(Int, Int)] = []
        for z in -3...18 { for x in -3...18 {
            if world.getBlockId(x, 64, z) == Int(B.oak_sapling) { planted.append((x, z)) }
        } }
        XCTAssertGreaterThan(planted.count, 0, "fixture must exercise actual self-seeding, not just its helper")
        let seedling = try XCTUnwrap(planted.first)
        XCTAssertTrue(growTreeAt(world, seedling.0, 64, seedling.1, Int(B.oak_sapling)))
        XCTAssertEqual(world.getBlockId(seedling.0, 64, seedling.1), Int(B.oak_log))
        XCTAssertTrue(world.getChunkAt(seedling.0, seedling.1)!.naturalTreeCells.values.contains {
            $0.origin == NaturalTreeOrigin(x: seedling.0, y: 64, z: seedling.1)
        })
    }

    func testDoTileDropsDisablesBothCollectibleAndSelfPlantedSeeds() {
        let world = world(seed: 43)
        world.gameRules["doTileDrops"] = 0
        let origin = NaturalTreeOrigin(x: 8, y: 64, z: 8)
        for z in 0..<16 { for x in 0..<16 { natural(world, x, 70, z, cell(B.oak_leaves, 4), origin: origin) } }
        world.treeEcology.adopt(chunk: world.getChunk(0, 0)!, in: world)
        advance(world, 1); advance(world, DAY_LENGTH)
        XCTAssertFalse(world.entities.contains { $0 is ItemEntity })
        for chunk in world.chunks.values { XCTAssertFalse(chunk.blocks.contains { $0 >> 4 == B.oak_sapling }) }
    }

    func testPersistedDecayContinuesFromOriginalDeadlineAfterReload() throws {
        let a = world(seed: 123)
        let original = growOak(a)
        a.setBlock(8, 64, 8, 0); advance(a, 1); advance(a, DAY_LENGTH / 2)
        XCTAssertFalse(original.naturalTreeCells.isEmpty)
        let b = world(seed: 123)
        b.ecologyCalendar = a.ecologyCalendar
        for key in a.chunks.keys.sorted() {
            let ac = a.chunks[key]!, bc = b.chunks[key]!
            bc.blocks = ac.blocks
            if let encoded = NaturalTreePersistence.encode(ac.naturalTreeCells) {
                bc.naturalTreeCells = NaturalTreePersistence.decode(encoded, height: bc.height)
            }
        }
        for key in b.chunks.keys.sorted() { b.treeEcology.adopt(chunk: b.chunks[key]!, in: b) }
        advance(b, 1)
        let expectedStarts = Set(original.naturalTreeCells.values.compactMap(\.decayStartTick))
        XCTAssertEqual(Set(b.getChunk(0, 0)!.naturalTreeCells.values.compactMap(\.decayStartTick)), expectedStarts)
        advance(a, DAY_LENGTH / 2)
        advance(b, DAY_LENGTH / 2 - 1)
        XCTAssertTrue(a.getChunk(0, 0)!.naturalTreeCells.isEmpty)
        XCTAssertTrue(b.getChunk(0, 0)!.naturalTreeCells.isEmpty)
        XCTAssertEqual(a.getChunk(0, 0)!.blocks, b.getChunk(0, 0)!.blocks)
    }

    func testMegaSpruceRecordsNaturalCellsWithoutChangingBlocksOrRandomStream() {
        final class PlainSink: ChunkSink {
            let base: ArraySink
            init(_ base: ArraySink) { self.base = base }
            var cx: Int { base.cx }; var cz: Int { base.cz }
            var minY: Int { base.minY }; var maxY: Int { base.maxY }
            func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) { base.set(x, y, z, c) }
            func get(_ x: Int, _ y: Int, _ z: Int) -> Int { base.get(x, y, z) }
            func topY(_ x: Int, _ z: Int) -> Int { base.topY(x, z) }
            func addBlockEntity(_ spec: BESpec) {}; func addEntity(_ spec: EntitySpec) {}
        }
        for pine in [false, true] {
            let a = ArraySink(cx: 0, cz: 0, blocks: Array(repeating: 0, count: 16 * 16 * 384), minY: -64, maxY: 320, heightFallback: { _, _ in 64 })
            let b = ArraySink(cx: 0, cz: 0, blocks: a.blocks, minY: -64, maxY: 320, heightFallback: { _, _ in 64 })
            var ar = RandomX(124), br = RandomX(124)
            genMegaSpruce(a, &ar, 8, 64, 8, pine: pine)
            genMegaSpruce(PlainSink(b), &br, 8, 64, 8, pine: pine)
            XCTAssertEqual(a.blocks, b.blocks)
            XCTAssertEqual(ar.nextInt(1_000_000), br.nextInt(1_000_000))
            XCTAssertGreaterThan(a.naturalTreeCells.count, 50)
            XCTAssertTrue(b.naturalTreeCells.isEmpty)
        }
    }
}
