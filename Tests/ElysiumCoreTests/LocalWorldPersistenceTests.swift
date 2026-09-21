import Foundation
import XCTest
@testable import ElysiumCore

@MainActor
final class LocalWorldPersistenceTests: XCTestCase {
    private func makeSettingsStore() -> LocalSettingsStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "elysium-local-world-persistence-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LocalSettingsStore(directoryURL: root)
    }

    func testSaveAndQuitRetainsCurrentAndOtherLocalWorlds() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "save-and-quit")
        let game = GameCore(db: database, localSettingsStore: makeSettingsStore())
        let other = WorldRecord(id: "other", name: "Other World", seed: 7,
                                gameMode: GameMode.survival, difficulty: 2)
        database.putWorld(other)

        game.createWorld(name: "Persistent World", seedText: "20260920",
                         mode: GameMode.survival, difficulty: 2)
        let currentID = try XCTUnwrap(game.worldRec?.id)
        game.player.setPos(33.25, 78.0, -9.5)

        game.exitToTitle()

        XCTAssertFalse(game.hasWorld())
        XCTAssertNotNil(database.getWorld(currentID),
                        "Save & Quit must leave the current local world in saved-world storage")
        XCTAssertNotNil(database.getPlayer(currentID),
                        "Save & Quit must flush the current player snapshot")
        XCTAssertNotNil(database.getWorld(other.id),
                        "quitting one world must never delete another saved world")

        game.loadWorld(currentID)
        XCTAssertTrue(game.hasWorld())
        XCTAssertEqual(game.worldRec?.id, currentID)
        XCTAssertEqual(game.player.x, 33.25, accuracy: 0.0001)
        XCTAssertEqual(game.player.y, 78.0, accuracy: 0.0001)
        XCTAssertEqual(game.player.z, -9.5, accuracy: 0.0001)
    }
}
