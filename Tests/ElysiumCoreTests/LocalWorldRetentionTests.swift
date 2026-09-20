import Foundation
import XCTest
@testable import ElysiumCore

@MainActor
final class LocalWorldRetentionTests: XCTestCase {
    private func makeSettingsStore() -> LocalSettingsStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "elysium-local-world-retention-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LocalSettingsStore(directoryURL: root)
    }

    private func makeGame(_ label: String) throws -> (GameCore, SaveDB) {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: label)
        return (GameCore(db: database, localSettingsStore: makeSettingsStore()), database)
    }

    private func localWorld(_ id: String) -> WorldRecord {
        WorldRecord(id: id, name: id, seed: 42,
                    gameMode: GameMode.survival, difficulty: 2)
    }

    private func guestRecord() -> [String: Any] {
        [
            "state": ["x": 12.5, "y": 64.0, "z": -3.0],
            "inventory": ["slots": [["id": "stone", "count": 32]]],
            "displayName": "Guest",
        ]
    }

    func testStartupDiscardClearsAllLocalWorldsButKeepsSettingsAndLANResume() throws {
        let settingsStore = makeSettingsStore()
        var settings = Settings()
        settings.resourcePacks = ["selected-pack.zip"]
        let persistedSettings = settingsStore.persistSettings(settings)
        guard case .success = persistedSettings else {
            return XCTFail("could not persist the test resource-pack preference: \(persistedSettings)")
        }
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "startup-discard")
        let game = GameCore(db: database, localSettingsStore: settingsStore)
        let first = localWorld("prior-one")
        let second = localWorld("prior-two")
        database.putWorld(first)
        database.putWorld(second)
        database.putLANPlayer(world: first.id, playerID: "guest-one", guestRecord())
        database.putLANPlayer(world: second.id, playerID: "guest-two", guestRecord())
        database.putLANPlayer(world: "retired-host", playerID: "stale-guest", guestRecord())
        database.putLANClientResume("remote-host#42", ["x": 17.0, "updated": 1.0])

        XCTAssertEqual(game.discardAllSavedLocalWorlds(), .discarded(2))
        XCTAssertTrue(game.listWorlds().isEmpty)
        XCTAssertTrue(database.listLANPlayers(world: first.id).isEmpty)
        XCTAssertTrue(database.listLANPlayers(world: second.id).isEmpty)
        XCTAssertTrue(database.listLANPlayers(world: "retired-host").isEmpty)
        XCTAssertNotNil(database.getLANClientResume("remote-host#42"))
        XCTAssertEqual(game.settings.resourcePacks, ["selected-pack.zip"])
        guard case let .success(reloadedSettings) = settingsStore.loadSettings() else {
            return XCTFail("resource-pack settings should remain readable")
        }
        XCTAssertEqual(reloadedSettings.resourcePacks, ["selected-pack.zip"])
    }

    func testStartupDiscardSweepsOrphanGuestsWhenThereAreNoSavedWorlds() throws {
        let (game, database) = try makeGame("empty-startup-discard")
        database.putLANPlayer(world: "retired-host", playerID: "stale-guest", guestRecord())
        database.putLANClientResume("remote-host#42", ["x": 17.0, "updated": 1.0])

        XCTAssertEqual(game.discardAllSavedLocalWorlds(), .noSavedWorlds)
        XCTAssertTrue(database.listLANPlayers(world: "retired-host").isEmpty)
        XCTAssertNotNil(database.getLANClientResume("remote-host#42"))
    }

    func testDiscardOnExitRemovesOnlyCurrentLocalWorldAndItsHostGuestRows() throws {
        let (game, database) = try makeGame("exit-discard")
        let current = localWorld("current")
        let other = localWorld("other")
        database.putWorld(current)
        database.putWorld(other)
        database.putLANPlayer(world: current.id, playerID: "guest-current", guestRecord())
        database.putLANPlayer(world: other.id, playerID: "guest-other", guestRecord())
        game.localWorldRetentionPolicy = .discardOnExit

        game.loadWorld(current.id)
        XCTAssertTrue(game.hasWorld())
        game.exitToTitle()

        XCTAssertNil(database.getWorld(current.id))
        XCTAssertNotNil(database.getWorld(other.id))
        XCTAssertTrue(database.listLANPlayers(world: current.id).isEmpty)
        XCTAssertEqual(database.listLANPlayers(world: other.id).map(\.playerID), ["guest-other"])
    }

    func testDiscardOnExitPreservesLANClientResume() throws {
        let (game, database) = try makeGame("lan-resume")
        let summary = LANWorldSummary(
            worldID: "remote host", worldName: "Remote Host", seed: 71,
            gameMode: GameMode.survival, difficulty: 2,
            dimension: Dim.overworld.rawValue, playerCount: 1)
        let resumeKey = try XCTUnwrap(lanClientResumeKey(for: summary))
        game.localWorldRetentionPolicy = .discardOnExit

        game.enterLANClientWorld(summary)
        game.player.setPos(33.25, 78.0, -9.5)
        game.saveAndFlush(synchronous: true)
        game.exitToTitle()

        XCTAssertFalse(game.hasWorld())
        XCTAssertTrue(game.listWorlds().isEmpty)
        XCTAssertNotNil(database.getLANClientResume(resumeKey))
    }

    func testDirectWorldDeletionSweepsCorruptGuestRowsAfterTheWorldIsGone() throws {
        let (game, database) = try makeGame("corrupt-guest-cleanup")
        let world = localWorld("retiring-host")
        database.putWorld(world)
        database.execRawLANPlayerInsertForTesting(
            world: world.id, playerID: "corrupt-guest", json: "{not valid json")

        game.deleteWorld(world.id)

        XCTAssertNil(database.getWorld(world.id))
        XCTAssertEqual(database.deleteOrphanedLANPlayers(), 0,
                       "post-delete cleanup must remove rows that cannot be decoded by listLANPlayers")
    }
}
