import XCTest
@testable import PebbleCore

final class AIAgentTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        registerAllSystems()
    }

    private func makeWorldAndPlayer() -> (World, Player, RaycastHit) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 777)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.set(0, 63, 0, cell(B.stone))
        chunk.buildHeightmap()
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)

        let player = Player(world: world)
        player.setPos(4.5, 64, 4.5)
        player.selectedSlot = 0
        world.addEntity(player)
        let hit = RaycastHit(x: 0, y: 63, z: 0, face: Dir.up, cell: Int(cell(B.stone)),
                             t: 1, px: 0.5, py: 64, pz: 0.5)
        return (world, player, hit)
    }

    func testParseExtractsFirstJSONActionFromModelText() throws {
        let action = try parseAIAgentAction(from: "```json\n{\"action\":\"place_block\",\"item\":\"crafting station\",\"target\":\"cursor\"}\n```")

        XCTAssertEqual(action.action, "place_block")
        XCTAssertEqual(action.item, "crafting station")
        XCTAssertEqual(action.target, "cursor")
    }

    func testParseRejectsNonJSONModelText() {
        XCTAssertThrowsError(try parseAIAgentAction(from: "place a crafting table now")) { error in
            XCTAssertEqual(error as? AIAgentError, .malformedJSON)
        }
    }

    func testNaturalNamesResolveThroughAliasesAndDisplayNames() {
        registerCoreIfNeeded()

        XCTAssertEqual(resolveAIAgentItemID("roasted chicken"), iid("cooked_chicken"))
        XCTAssertEqual(resolveAIAgentItemID("a stack of coal"), iid("coal"))
        XCTAssertEqual(resolveAIAgentItemID("10 diamonds"), iid("diamond"))
        XCTAssertEqual(resolveAIAgentBlockID("crafting station"), B.crafting_table)
        XCTAssertEqual(resolveAIAgentBlockID("Crafting Table"), B.crafting_table)
    }

    func testGiveItemCreatesRegisteredInventoryItem() throws {
        let (world, player, _) = makeWorldAndPlayer()

        let result = try executeAIAgentAction(
            AIAgentAction(action: "give_item", item: "roasted chicken", count: 3),
            world: world,
            player: player,
            cursor: nil)

        XCTAssertFalse(result.changedWorld)
        XCTAssertEqual(player.countItem(iid("cooked_chicken")), 3)
    }

    func testDirectInventoryRequestAddsAStackOfCoal() throws {
        let (world, player, _) = makeWorldAndPlayer()
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "add a stack of coal to my inventory"))

        let result = try executeAIAgentAction(action, world: world, player: player, cursor: nil)

        XCTAssertFalse(result.changedWorld)
        XCTAssertEqual(action.action, "give_item")
        XCTAssertEqual(action.item, "coal")
        XCTAssertEqual(action.count, 64)
        XCTAssertEqual(player.countItem(iid("coal")), 64)
    }

    func testDirectInventoryRequestUsesItemMaxStackSize() throws {
        registerCoreIfNeeded()
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "give me a stack of ender pearls"))

        XCTAssertEqual(action.item, "ender_pearl")
        XCTAssertEqual(action.count, itemDef(iid("ender_pearl")).maxStack)
    }

    func testDirectInventoryRequestSupportsNumericCountsAndPlurals() throws {
        registerCoreIfNeeded()
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "give me 10 diamonds"))

        XCTAssertEqual(action.item, "diamond")
        XCTAssertEqual(action.count, 10)
    }

    func testDirectInventoryRequestDoesNotOvermatchPlacementText() {
        registerCoreIfNeeded()
        XCTAssertNil(inferDirectAIAgentAction(from: "place a stack of coal at the cursor"))
        XCTAssertNil(inferDirectAIAgentAction(from: "what can I craft with coal"))
    }

    func testPlaceBlockAtCursorUsesPlacementPathAndPreservesHotbar() throws {
        let (world, player, hit) = makeWorldAndPlayer()
        player.inventory[0] = stack("dirt", 5)

        let result = try executeAIAgentAction(
            AIAgentAction(action: "place_block", item: "crafting station", target: "cursor"),
            world: world,
            player: player,
            cursor: hit)

        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(world.getBlock(0, 64, 0) >> 4, Int(B.crafting_table))
        XCTAssertEqual(player.inventory[0]?.id, iid("dirt"))
        XCTAssertEqual(player.inventory[0]?.count, 5)
    }

    func testPlaceBlockRequiresCursorHit() {
        let (world, player, _) = makeWorldAndPlayer()

        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "place_block", item: "crafting station", target: "cursor"),
            world: world,
            player: player,
            cursor: nil)) { error in
                XCTAssertEqual(error as? AIAgentError, .missingCursorTarget)
            }
    }

    func testSnapshotIncludesNearbyDroppedItems() {
        let (world, player, hit) = makeWorldAndPlayer()
        let item = ItemEntity(world: world)
        item.stack = stack("diamond", 2)
        item.setPos(player.x + 1, player.y, player.z)
        world.addEntity(item)

        let snapshot = buildAIAgentSnapshot(world: world, player: player, cursor: hit)

        XCTAssertTrue(snapshot.contains("diamondx2"), snapshot)
        XCTAssertTrue(snapshot.contains("Cursor: block=stone"), snapshot)
        XCTAssertTrue(snapshot.contains("Available items:"), snapshot)
    }
}
