// LANGuestCommandGateTests.swift — object-graph-attributes (change 1a).
// Security (plan) Condition 23 (closing finding A2): proves the actual
// `CommandsM.runCommand` call site — not only the pure
// `ScriptingCommands.lanClientRefusal(command:)` decision function — refuses
// every scripting command and `ai`/`agent` on a transient LAN client world,
// before `ScriptingCommands.run`/`AttributeStore`/`ObjectGraph` or
// `elysiumOllamaAgent.run` ever execute. `ElysiumCoreTests` cannot see this:
// it depends only on `ElysiumCore`/`ElysiumStorage`/`ElysiumTextInput`
// (Package.swift), never `Elysium` — the app-layer executable target where
// the enforcement point actually lives.

import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class LANGuestCommandGateTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeLANClientGame() throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-guest-gate-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "guest-gate-host", worldName: "Guest Gate Host", seed: 4242,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2
        ))
        return game
    }

    /// Spec `scripting-commands` "Refusal is enforced at the CommandsM call
    /// site": every gated command, run through the real `runCommand` entry
    /// point on a LAN client world, leaves `chatLog` holding exactly the
    /// refusal line and nothing else.
    func testEveryScriptingAndAICommandIsRefusedAtTheRealCallSite() throws {
        let game = try makeLANClientGame()
        XCTAssertTrue(game.isLANClientWorld)
        XCTAssertNotNil(game.player)

        let refusal = "This command runs on the LAN host only (guests get access in a later update)."
        // event-bus (change 1b): `/on`, `/unsubscribe`, `/events` join the
        // same host-only gate `/attr`/`/inspect`/`/objects`/`/ai`/`/agent`
        // proved in 1a.
        let commands = [
            "/attr list self", "/inspect", "/objects near", "/ai hello", "/agent hello",
            "/on self player.joined s.h", "/unsubscribe 1", "/events recent",
            // ai-object-graph (change 2): the AI tool loop's own `/script`
            // subcommands (journal/undo-ai) and `/ai cancel` join the exact
            // same gate — nothing about the loop weakens it.
            "/script journal", "/script undo-ai", "/ai cancel",
        ]

        for command in commands {
            chatLog.removeAll()
            runCommand(game, command)
            XCTAssertEqual(chatLog.count, 1, "command '\(command)' should push exactly one chat line")
            XCTAssertEqual(
                chatLog.first?.text, "§c" + refusal,
                "command '\(command)' should push exactly the refusal line"
            )
        }
    }

    /// The same assertion again, isolated per command, so a failure names
    /// the specific command that regressed (the loop above already covers
    /// every command; this is redundant on purpose — one broken `case` in a
    /// large flat `switch` is exactly the failure mode Condition 23 exists to
    /// catch, and per-command tests localize it precisely).
    func testAttrIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/attr list self")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.hasPrefix("§c") == true)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testInspectIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/inspect")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testObjectsIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/objects near")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testAiIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/ai hello")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testAgentAliasIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/agent hello")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testOnIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/on self player.joined s.h")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testUnsubscribeIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/unsubscribe 1")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testEventsIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/events recent")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    /// ai-object-graph (change 2): `/script journal`/`/script undo-ai` (the
    /// AI provenance/undo surface) are refused at the same real call site as
    /// every other scripting command, not only via `ScriptingCommands`'s own
    /// pure decision function.
    func testScriptJournalIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/script journal")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    func testScriptUndoAiIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/script undo-ai")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    /// `/ai cancel` is intercepted by `CommandsM` before it ever reaches
    /// `OllamaAgentService.cancelToolLoop` — a guest can neither start nor
    /// cancel a tool-loop request.
    func testAiCancelIsRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/ai cancel")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    /// scripting-ui-and-replication (change 3), design.md §11/§12: `/inspector` (distinct from
    /// `/inspect`) opens the Object Inspector screen for a guest too, and that screen's
    /// attribute section reads only the replicated mirror
    /// (`LANMultiplayerManager.shared.mirroredAttributes(for:)`) — never `AttributeStore`. This
    /// proves a guest CAN read a replicated attribute end to end (host mirror populated ->
    /// `inspectorRows` surfaces it) while every mutation path stays refused exactly as the rest
    /// of this file proves: `/attr set` (and every other scripting command) still hits the same
    /// real `CommandsM.runCommand` refusal, and there is no write method on the mirror at all —
    /// `LANMultiplayerClientSession.objectAttributes` is `private(set)`, and
    /// `LANMultiplayerManager.mirroredAttributes(for:)` is a read accessor with no counterpart.
    func testInspectorScreenReadsReplicatedAttributesOnAGuestWhileWritesStayRefused() throws {
        let game = try makeLANClientGame()
        XCTAssertTrue(game.isLANClientWorld)

        // Simulate what a real host->guest replication batch delivers: populate the guest's own
        // mirror the same way `LANMultiplayerClientSession.apply(_:)` does (the actual transport
        // plumbing — `LANMultiplayerManager`'s socket/queue machinery — is exercised by the LAN
        // test lab probe, not by this headless unit test).
        let ref = ObjectRef.player
        let manager = LANMultiplayerManager.shared
        manager.attachGame(game)
        _ = manager.applyReplicationBatchForTesting(LANReplicationBatch(
            tick: 1, fullSnapshot: false,
            objectAttributes: [LANObjectAttributeSnapshot(
                ref: ref.canonical, revision: 1,
                attrsJSON: AttrValueCodec.encode(.map(["mood": .string("curious")]))
            )]
        ))

        let mirrored = manager.mirroredAttributes(for: ref)
        XCTAssertEqual(mirrored?["mood"], .string("curious"), "the mirror itself must hold what was replicated")

        let rows = inspectorRows(target: ref, game: game)
        XCTAssertTrue(rows.contains { $0.contains("mood = \"curious\"") && $0.contains("replicated, read-only") },
                      "Inspector's attribute section must surface the mirrored value as read-only; got: \(rows)")

        // The write side of the exact same feature stays refused at the real call site, same as
        // every other command this file proves.
        chatLog.removeAll()
        runCommand(game, "/attr set self mood happy")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertTrue(chatLog.first?.text.contains("LAN host only") == true)
    }

    /// A host (non-LAN-client) world is unaffected by the gate — `/attr`
    /// reaches `ScriptingCommands.run` and produces its own (non-refusal)
    /// output.
    func testHostWorldIsNotGated() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-guest-gate-host-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        game.createWorld(name: "Guest Gate Host World", seedText: "4242", mode: GameMode.survival, difficulty: 2)
        XCTAssertFalse(game.isLANClientWorld)
        chatLog.removeAll()
        runCommand(game, "/attr list self")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("LAN host only") ?? true)
    }
}
