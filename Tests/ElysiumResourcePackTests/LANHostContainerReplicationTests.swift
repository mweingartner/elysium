import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// A hosting transport sends its guests the containers the host's own game rewrites: the
/// crafting pool and a survival paste's payment both write them through
/// `CraftingResourceOwner.markDirty`, which reaches the host session by
/// `WorldHooks.onContainerItemsChanged` and `GameCore.onWorldContainerItemsChanged`
/// (`LANMultiplayerManager.configureHostReplicationHooks`). The paste's side of that chain is
/// covered in `TemplatePasteCostTests`; this covers the transport's.
@MainActor
final class LANHostContainerReplicationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        registerAllSystems()
        registerAllRecipes()
    }

    func testAHostsNextDeltaCarriesTheChestItsCraftingPoolTookFrom() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-host-containers-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Host Storage", seedText: "20261111", mode: GameMode.survival, difficulty: 0)
        XCTAssertNil(game.onWorldContainerItemsChanged, "a single-player game tells no one")

        let manager = LANMultiplayerManager.shared
        manager.stop()
        defer { manager.stop() }
        manager.attachGame(game)
        try manager.startHost(game: game, requestedJoinCode: "CHST1", requestedPort: 57_131)

        // Two chests in a chunk of their own, away from anything the world generates.
        let world = game.world
        let chunk = Chunk(cx: 40, cz: 40, minY: world.info.minY, height: world.info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        let x = 40 * CHUNK_W + 4, y = 64, z = 40 * CHUNK_W + 4
        for (dx, item, count) in [(0, "oak_planks", 8), (2, "cobblestone", 64)] {
            world.setBlock(x + dx, y, z, Int(cell(B.chest)), SET_SILENT)
            let chest = makeContainerBE(x + dx, y, z, 27)
            chest.items?[0] = ItemStack(iid(item), count)
            world.setBlockEntity(chest)
        }
        XCTAssertEqual(try XCTUnwrap(manager.makeHostForegroundDeltaForTesting()).blockEntities, [],
                       "placing a container is not a rewrite of its items")

        var grid = [ItemStack?](repeating: nil, count: 9)
        var inventory = [ItemStack?](repeating: nil, count: 36)
        let resources = craftingResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                               centerX: x - 1, centerY: y, centerZ: z, radius: CRAFTING_CONTAINER_RADIUS)
        let table = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })
        XCTAssertTrue(populateCraftingGridFromNearbyContainers(
            table, grid: &grid, inventory: &inventory, world: world,
            centerX: x - 1, centerY: y, centerZ: z, radius: CRAFTING_CONTAINER_RADIUS))

        let delta = try XCTUnwrap(manager.makeHostForegroundDeltaForTesting())
        XCTAssertEqual(delta.blockEntities.map { [$0.x, $0.y, $0.z] }, [[x, y, z]], "only the chest that was written")
        let guest = LANMultiplayerClientSession()
        _ = guest.apply(delta)
        let mirrored = try XCTUnwrap(guest.blockEntities[
            LANBlockPosition(dimension: world.dim.rawValue, x: x, y: y, z: z)])
        XCTAssertEqual(mirrored.slots.map(\.itemID), [iid("oak_planks")])
        XCTAssertEqual(mirrored.slots.map(\.count), [4], "the guest sees what the craft left")
        XCTAssertEqual(try XCTUnwrap(manager.makeHostForegroundDeltaForTesting()).blockEntities, [],
                       "each write is sent once")

        manager.stop()
        XCTAssertNil(game.onWorldContainerItemsChanged, "the hook ends with the hosted session")
    }

    /// The transport's side of a large payment, and of containers that are gone by the time the
    /// delta is built: more rewritten containers than one batch carries go out over the next
    /// deltas, each once; a container broken, or whose chunk unloaded, after its write is left
    /// out and not retried.
    func testAHostsDeltasCarryEveryRewrittenContainerInTurnAndDropOnesThatAreGone() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-host-containers-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Host Storage Room", seedText: "20261112", mode: GameMode.survival, difficulty: 0)

        let manager = LANMultiplayerManager.shared
        manager.stop()
        defer { manager.stop() }
        manager.attachGame(game)
        try manager.startHost(game: game, requestedJoinCode: "CHST2", requestedPort: 57_132)

        // A storage room of 70 chests in two chunks of their own, away from anything generated.
        let world = game.world
        for cx in 40...41 {
            let chunk = Chunk(cx: cx, cz: 40, minY: world.info.minY, height: world.info.height)
            chunk.status = .lit
            world.setChunk(chunk)
        }
        let y = 64, z0 = 40 * CHUNK_W
        var chests: [BlockEntityData] = []
        for index in 0..<70 {
            let x = 40 * CHUNK_W + (index % 30), z = z0 + index / 30
            world.setBlock(x, y, z, Int(cell(B.chest)), SET_SILENT)
            let chest = makeContainerBE(x, y, z, 27)
            world.setBlockEntity(chest)
            chests.append(chest)
        }
        XCTAssertTrue(chests.contains { floorDiv($0.x, CHUNK_W) == 41 }, "some chests stand in the second chunk")
        XCTAssertEqual(try XCTUnwrap(manager.makeHostForegroundDeltaForTesting()).blockEntities, [])

        // The game writes every one through the funnel the paste and the crafting pool share.
        for (index, chest) in chests.enumerated() {
            let owner = CraftingResourceOwner.blockEntity(chest, 0)
            owner.set(ItemStack(iid("oak_planks"), index % 64 + 1))
            owner.markDirty(in: world)
        }
        var sent: [LANBlockEntitySnapshot] = []
        for _ in 0..<3 {
            let delta = try XCTUnwrap(manager.makeHostForegroundDeltaForTesting())
            XCTAssertLessThanOrEqual(delta.blockEntities.count, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES)
            sent.append(contentsOf: delta.blockEntities)
        }
        XCTAssertEqual(sent.map { [$0.x, $0.y, $0.z] }, chests.map { [$0.x, $0.y, $0.z] },
                       "every chest once, in the order written")
        XCTAssertEqual(sent.map { $0.slots.map(\.count) }, chests.indices.map { [$0 % 64 + 1] },
                       "each with what it holds")
        XCTAssertEqual(try XCTUnwrap(manager.makeHostForegroundDeltaForTesting()).blockEntities, [])

        // Written, then broken; written, then its chunk unloads; written and still standing.
        let broken = chests[0], unloaded = try XCTUnwrap(chests.first { floorDiv($0.x, CHUNK_W) == 41 }), kept = chests[1]
        for chest in [broken, unloaded, kept] {
            let owner = CraftingResourceOwner.blockEntity(chest, 1)
            owner.set(ItemStack(iid("cobblestone"), 3))
            owner.markDirty(in: world)
        }
        world.removeBlockEntity(broken.x, broken.y, broken.z)
        world.setBlock(broken.x, broken.y, broken.z, 0, SET_SILENT)
        world.removeChunk(41, 40)
        let delta = try XCTUnwrap(manager.makeHostForegroundDeltaForTesting())
        XCTAssertEqual(delta.blockEntities.map { [$0.x, $0.y, $0.z] }, [[kept.x, kept.y, kept.z]])
        XCTAssertEqual(try XCTUnwrap(manager.makeHostForegroundDeltaForTesting()).blockEntities, [],
                       "what is gone is not retried")

        // A write to a chest whose chunk is not loaded does not bring the chest back.
        let owner = CraftingResourceOwner.blockEntity(unloaded, 2)
        owner.set(ItemStack(iid("dirt"), 1))
        owner.markDirty(in: world)
        XCTAssertNil(world.getBlockEntity(unloaded.x, unloaded.y, unloaded.z))
        XCTAssertEqual(try XCTUnwrap(manager.makeHostForegroundDeltaForTesting()).blockEntities, [])
    }
}
