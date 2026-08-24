// LANScriptIntentAppLayerTests.swift — lan-client-parity (change 4). The app-layer (`Elysium`
// target) pieces `Tests/ElysiumCoreTests/LANScriptIntentHostTests.swift` cannot reach: the
// `lan_players` JSON bridging round trip (`lanPeerRecordJSON`/`lanPeerRecordSnapshot
// (fromStoredJSON:)`, both free functions in `LANTransport.swift`), the `/script trust <peer>`
// command surface's "not hosting" refusal, and `OllamaAgentService.runToolLoop`'s `reportLine`
// redirection (the seam guest `/ai` forwarding relies on to relay status/result lines to the
// sending peer instead of the host's own local chat). A live listener/socket is out of scope
// here (see `docs/LAN_TEST_LAB.md` and this change's own report) — `grantPeerScript`'s
// exactly-one-connected-peer-matched path is proved instead at the
// `LANMultiplayerHostSession.setCanScript`/`.setCanUseAI` level in `LANScriptIntentHostTests`.

import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class LANScriptIntentAppLayerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    // MARK: - lan_players objectRecordText bridging round trip

    func testLanPeerRecordJSONRoundTripsObjectRecordText() {
        var record = ObjectRecord()
        record.entries["mood"] = .value(.string("happy"), readonly: false, provenance: Provenance(createdBy: .lan(peer: "guest1"), createdTick: 5))
        let encoded = ObjectRecordCodec.encode(record)

        let snapshot = LANPeerRecordSnapshot(
            playerID: "guest1", displayName: "Guest One", lifecycle: .connected,
            permissions: LANPeerPermissions(canScript: true),
            playerState: LANPlayerState(
                playerID: "guest1", displayName: "Guest One", x: 1, y: 65, z: 1,
                yaw: 0, pitch: 0, health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
            ),
            inventory: nil, lastAckTick: 0, lastSeenTick: 0, disconnectedTick: nil
        )

        let json = lanPeerRecordJSON(snapshot, objectRecordText: encoded)
        XCTAssertEqual(json["attrs"] as? String, encoded)

        let decoded = lanPeerRecordSnapshot(fromStoredJSON: json, playerID: "guest1")
        XCTAssertEqual(decoded?.objectRecordText, encoded)

        let roundTrippedRecord: ObjectRecord? = decoded?.objectRecordText.flatMap {
            ObjectRecordCodec.decode($0, caps: .defaults)
        }
        guard case .value(let value, _, let provenance)? = roundTrippedRecord?.entries["mood"] else {
            return XCTFail("expected the 'mood' entry to survive the round trip")
        }
        XCTAssertEqual(value, AttrValue.string("happy"))
        guard case .lan(let peer) = provenance.createdBy else {
            return XCTFail("expected .lan(peer:) provenance to survive the round trip")
        }
        XCTAssertEqual(peer, "guest1")
    }

    func testLanPeerRecordJSONOmitsAttrsKeyWhenNotPassed() {
        let record = LANPeerRecordSnapshot(
            playerID: "guest1", displayName: "Guest One", lifecycle: .connected,
            permissions: LANPeerPermissions(),
            playerState: LANPlayerState(
                playerID: "guest1", displayName: "Guest One", x: 0, y: 65, z: 0,
                yaw: 0, pitch: 0, health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
            ),
            inventory: nil, lastAckTick: 0, lastSeenTick: 0, disconnectedTick: nil
        )
        // Every call site before this change never passed `objectRecordText` — must keep writing
        // no "attrs" key at all, exactly as before.
        let json = lanPeerRecordJSON(record)
        XCTAssertNil(json["attrs"])
    }

    // MARK: - `/script trust <peer>` command surface

    func testScriptTrustWithPeerArgumentRefusesWhenNotHosting() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-script-trust-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        game.createWorld(name: "Trust Test", seedText: "1", mode: GameMode.survival, difficulty: 2)
        XCTAssertFalse(game.isLANClientWorld)

        chatLog.removeAll()
        runCommand(game, "/script trust someGuest")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("not hosting") == true, "got: \(String(describing: chatLog.first?.text))")
    }

    /// Bare `/script trust` (no peer argument) is the pre-existing world-level trust gate —
    /// unaffected by lan-client-parity's per-peer grant, and must not be intercepted by it.
    func testBareScriptTrustStillHitsTheWorldTrustGateNotThePeerGrantPath() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-script-trust-world-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        game.createWorld(name: "Trust World Test", seedText: "1", mode: GameMode.survival, difficulty: 2)

        chatLog.removeAll()
        runCommand(game, "/script trust")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("not hosting") == true)
        XCTAssertTrue(chatLog.first?.text.contains("trusted") == true, "got: \(String(describing: chatLog.first?.text))")
    }

    // MARK: - OllamaAgentService.runToolLoop reportLine redirection

    /// design.md §11 phase 4 "responses replicated back — bounded": `applyHostScriptIntent`
    /// relays every line `runToolLoop` would otherwise `pushChat` locally to the forwarding
    /// guest instead, via `reportLine`. No live Ollama server (or even a world) is required for
    /// this: `runToolLoop`'s first real guard, "the AI agent needs an active world," refuses
    /// synchronously before ever touching `Settings`/the network — deterministic regardless of
    /// this machine's own persisted Ollama model preference (unlike a "no model configured"
    /// fixture would be, since `Settings` loads a real local preference file, not a fresh
    /// default, once a world is entered) — exactly the seam that proves the redirection itself
    /// works, and that it does NOT also leak into the host's own local chat.
    func testRunToolLoopRedirectsReportLinesInsteadOfLocalChatWhenGiven() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-ai-forward-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        XCTAssertFalse(game.hasWorld(), "precondition: no world entered")

        let service = OllamaAgentService()
        var relayed: [String] = []
        chatLog.removeAll()
        service.runToolLoop(prompt: "hello", game: game) { line in relayed.append(line) }

        XCTAssertTrue(chatLog.isEmpty, "no local chat line for a forwarded request")
        XCTAssertEqual(relayed.count, 1)
        XCTAssertTrue(relayed.first?.contains("active world") == true, "got: \(relayed)")
    }

    /// The default (`reportLine: nil`) path — every pre-existing call site — is unchanged: it
    /// still pushes to the host's own local chat.
    func testRunToolLoopPushesLocalChatWhenNoReportLineGiven() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-ai-local-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        XCTAssertFalse(game.hasWorld())

        let service = OllamaAgentService()
        chatLog.removeAll()
        service.runToolLoop(prompt: "hello", game: game)

        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("active world") == true)
    }
}
