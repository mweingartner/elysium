import XCTest
@testable import ElysiumCore

final class BedPlacementTests: XCTestCase {
    private func makeFixture() -> (World, Player) {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        let world = World(dim: .overworld, seed: 0xBED)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        let player = Player(world: world)
        player.setPos(12.5, 64, 12.5)
        player.inventory[0] = stack("red_bed", 2)
        player.selectedSlot = 0
        return (world, player)
    }

    func testTwoClickSelectionOwnsHeadThenRequiresAdjacentFoot() {
        var selection = BedPlacementSelection()
        let head = BedPlacementPoint(x: 4, y: 64, z: 4)
        XCTAssertEqual(selection.select(head), .headSelected(head))
        XCTAssertEqual(selection.select(BedPlacementPoint(x: 5, y: 65, z: 4)),
                       .footMustBeAdjacent(head))
        XCTAssertEqual(selection.head, head, "an invalid second click must retain the chosen head")
        let foot = BedPlacementPoint(x: 5, y: 64, z: 4)
        XCTAssertEqual(selection.select(foot), .ready(head: head, foot: foot, facing: 2))
    }

    func testAdjacentHeadAndFootPlaceEveryFacingAndConsumeExactlyOneBed() throws {
        let cases: [(head: BedPlacementPoint, foot: BedPlacementPoint, facing: Int)] = [
            (.init(x: 4, y: 64, z: 3), .init(x: 4, y: 64, z: 4), 0),
            (.init(x: 6, y: 64, z: 7), .init(x: 6, y: 64, z: 6), 1),
            (.init(x: 8, y: 64, z: 8), .init(x: 9, y: 64, z: 8), 2),
            (.init(x: 11, y: 64, z: 10), .init(x: 10, y: 64, z: 10), 3),
        ]
        for row in cases {
            let (world, player) = makeFixture()
            let held = try XCTUnwrap(player.mainHand)
            XCTAssertEqual(placeBed(InteractCtx(world: world, player: player),
                                    head: row.head, foot: row.foot,
                                    blockId: Int(B.red_bed), held: held), .placed)
            XCTAssertEqual(world.getBlock(row.foot.x, row.foot.y, row.foot.z),
                           Int(cell(B.red_bed, row.facing)))
            XCTAssertEqual(world.getBlock(row.head.x, row.head.y, row.head.z),
                           Int(cell(B.red_bed, row.facing | 4)))
            XCTAssertEqual(player.mainHand?.count, 1)
            XCTAssertEqual(player.stats["blocksPlaced"], 1)
        }
    }

    func testBlockedHalfRejectsWithoutPartialPlacementOrConsumption() throws {
        let (world, player) = makeFixture()
        let head = BedPlacementPoint(x: 4, y: 64, z: 4)
        let foot = BedPlacementPoint(x: 5, y: 64, z: 4)
        world.setBlock(head.x, head.y, head.z, Int(cell(B.stone)))

        XCTAssertEqual(placeBed(InteractCtx(world: world, player: player),
                                head: head, foot: foot, blockId: Int(B.red_bed),
                                held: try XCTUnwrap(player.mainHand)), .blocked)
        XCTAssertEqual(world.getBlockId(head.x, head.y, head.z), Int(B.stone))
        XCTAssertEqual(world.getBlock(foot.x, foot.y, foot.z), 0)
        XCTAssertEqual(player.mainHand?.count, 2)
        XCTAssertNil(player.stats["blocksPlaced"])
    }

    func testPlacementPointUsesReplaceableCellOrClickedFaceNeighbor() {
        let (world, _) = makeFixture()
        world.setBlock(4, 63, 4, Int(cell(B.stone)))
        let solid = RaycastHit(x: 4, y: 63, z: 4, face: Dir.up,
                               cell: Int(cell(B.stone)), t: 1,
                               px: 4.5, py: 64, pz: 4.5)
        XCTAssertEqual(bedPlacementPoint(in: world, from: solid),
                       BedPlacementPoint(x: 4, y: 64, z: 4))

        world.setBlock(5, 64, 4, Int(cell(B.short_grass)))
        let replaceable = RaycastHit(x: 5, y: 64, z: 4, face: Dir.north,
                                     cell: Int(cell(B.short_grass)), t: 1,
                                     px: 5.5, py: 64.5, pz: 4)
        XCTAssertEqual(bedPlacementPoint(in: world, from: replaceable),
                       BedPlacementPoint(x: 5, y: 64, z: 4))
    }
}
