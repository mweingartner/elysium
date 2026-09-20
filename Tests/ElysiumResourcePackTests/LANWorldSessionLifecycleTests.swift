import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class LANWorldSessionLifecycleTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    func testEndingHostedWorldCannotCarryGuestStateIntoNextHost() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-session-end-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Retiring LAN world", seedText: "20260920",
                         mode: GameMode.creative, difficulty: 2)
        let retiringWorldID = try XCTUnwrap(game.worldRec?.id)
        game.localWorldRetentionPolicy = .discardOnExit

        let manager = LANMultiplayerManager.shared
        manager.stop()
        defer { manager.stop() }
        manager.attachGame(game)
        try manager.startHost(game: game, requestedJoinCode: "END1", requestedPort: 57_123)
        XCTAssertEqual(manager.state, .hosting)
        manager.seedHostPeerRecordForTesting(LANPeerRecordSnapshot(
            playerID: "retiring-guest", displayName: "Retiring Guest", lifecycle: .connected,
            permissions: LANPeerPermissions(), playerState: nil, inventory: nil,
            lastAckTick: 0, lastSeenTick: 0, disconnectedTick: nil
        ))

        game.exitToTitle()

        XCTAssertEqual(manager.state, .idle,
                       "the retiring world must tear down LAN before a new session can attach")
        XCTAssertNil(game.db.getWorld(retiringWorldID),
                     "the checked local-world cleanup must run after LAN teardown")
        XCTAssertTrue(game.db.listLANPlayers(world: retiringWorldID).isEmpty,
                      "checked cleanup must remove the retiring host's guest rows")

        game.createWorld(name: "Replacement LAN world", seedText: "20260921",
                         mode: GameMode.creative, difficulty: 2)
        let replacementWorldID = try XCTUnwrap(game.worldRec?.id)
        try manager.startHost(game: game, requestedJoinCode: "END2", requestedPort: 57_124)
        XCTAssertTrue(game.db.listLANPlayers(world: replacementWorldID).isEmpty,
                      "a next host must not inherit peer rows from the retired world")
    }

    func testEndingHostedWorldSettlesGuestJobsBeforeClearingTransportHooks() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-host-settle-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Host Template Save", seedText: "20260920",
                         mode: GameMode.creative, difficulty: 2)

        let manager = LANMultiplayerManager.shared
        manager.stop()
        defer { manager.stop() }
        manager.attachGame(game)
        try manager.startHost(game: game, requestedJoinCode: "SAVE1", requestedPort: 57_125)
        var settled = false
        game.lanSettleTemplateJobsHandler = { settled = true }

        game.exitToTitle()

        XCTAssertTrue(settled,
                      "world-session transport teardown must settle jobs before clearing its hook")
        XCTAssertEqual(manager.state, .idle)
    }

    func testEndingJoinedWorldRetainsTheFinalLANResumeSnapshot() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-client-session-end-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        let summary = LANWorldSummary(
            worldID: "remote-host-world", worldName: "Remote Host", seed: 71,
            gameMode: GameMode.survival, difficulty: 2,
            dimension: Dim.overworld.rawValue, playerCount: 1)
        let resumeKey = try XCTUnwrap(lanClientResumeKey(for: summary))

        let manager = LANMultiplayerManager.shared
        manager.stop()
        defer { manager.stop() }
        manager.attachGame(game)
        game.enterLANClientWorld(summary)
        game.player.setPos(33.25, 78.0, -9.5)

        game.exitToTitle()

        XCTAssertFalse(game.lanConnectionLost,
                       "a player-requested session end is not a transport failure")
        XCTAssertNotNil(game.db.getLANClientResume(resumeKey),
                        "the last accepted client state must be retained for a later reconnect")
        XCTAssertEqual(manager.state, .idle)
    }

    func testJoiningLANRefusesToAbandonAnActiveLocalWorld() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-local-join-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Active Local World", seedText: "20260920",
                         mode: GameMode.creative, difficulty: 2)

        let manager = LANMultiplayerManager.shared
        manager.stop()
        defer { manager.stop() }
        XCTAssertThrowsError(try manager.directConnect(
            host: "127.0.0.1", port: "57126", joinCode: "JOIN", playerName: "Player", game: game
        )) { error in
            XCTAssertEqual((error as? LANTransportError)?.description,
                           LANTransportError.endLocalWorldBeforeJoining.description)
        }
        XCTAssertTrue(game.hasWorld())
    }
}
