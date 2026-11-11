import Foundation
import Metal
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// A LAN guest's container screen tells the host about an edit while the screen is still open.
/// The edit must add up for the host: what left the container is in the inventory and the
/// other way round. A stack held on the mouse cursor is in neither.
final class LANContainerScreenEditTests: XCTestCase {
    /// The guest picks two coal out of a chest and holds them on the cursor for longer than the
    /// screen waits between edits. Until 1.5.0 the screen sent the edit at that moment: a chest
    /// without the coal and an inventory without it. The host refused it, and every later edit
    /// of that screen with it. The edit is now sent once the coal has been put down, and the
    /// host accepts it.
    @MainActor
    func testAnEditIsSentOnceTheCursorIsEmptyAndThenAddsUpForTheHost() throws {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllSystems()
        let coal = try XCTUnwrap(iidOpt("coal"))

        // The host: a chest with two coal and a guest standing beside it.
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W { for x in 0..<CHUNK_W { chunk.set(x, 63, z, cell(B.dirt, 0)) } }
        chunk.status = .generated
        world.setChunk(chunk)
        world.setBlock(2, 64, 2, Int(cell(B.chest)), SET_SILENT)
        let hostChest = makeContainerBE(2, 64, 2, 27)
        hostChest.items?[0] = ItemStack(coal, 2)
        world.setBlockEntity(hostChest)
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(playerID: "guest", displayName: "Alex", x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
                                                 health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival))

        // The guest: its own view of that chest, open in a chest screen.
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-chest-edit-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        game.enterLANClientWorld(LANWorldSummary(worldID: "edit-host", worldName: "Edit Host", seed: 42,
                                                 gameMode: GameMode.survival, difficulty: 2,
                                                 dimension: Dim.overworld.rawValue, playerCount: 2))
        var results: [LANContainerEditResult] = []
        game.lanContainerEditHandler = { results.append(session.applyContainerEditIntent($0, from: "guest", to: world)) }
        let chest = makeContainerBE(2, 64, 2, 27)
        chest.items?[0] = ItemStack(coal, 2)
        let screen = ChestScreen(chest, "Chest")
        ui.open(screen, game)
        func frame() {
            ui.beginFrame()
            screen.draw(ui, game, 0)
            ui.endFrame()
        }
        frame()
        let opened = results.count                              // whatever the first frame sends

        ui.cursorStack = chest.items?[0]                        // picked up
        chest.items?[0] = nil
        Thread.sleep(forTimeInterval: 0.25)                     // longer than the screen waits between edits
        frame()
        XCTAssertEqual(results.count, opened, "nothing is sent while the coal is on the cursor")

        game.player.inventory[4] = ui.cursorStack               // put down
        ui.cursorStack = nil
        frame()
        XCTAssertEqual(results.count, opened + 1)
        guard case .applied = results.last else { return XCTFail("the host refused the edit: \(String(describing: results.last))") }
        XCTAssertNil(hostChest.items?[0], "the coal left the host's chest")
        XCTAssertEqual(session.peerRecord(playerID: "guest")?.inventory?.slots,
                       [LANInventorySlotSnapshot(slot: 4, itemID: coal, count: 2)], "and is in the host's copy of the guest's inventory")
    }
}
