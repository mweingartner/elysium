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
    /// site": every gated command with **no `scriptIntent` path** — reads
    /// (`inspect`/`objects`/`events recent`) and world-level `/script`
    /// settings (`journal`/`undo-ai`) — run through the real `runCommand`
    /// entry point on a LAN client world, leaves `chatLog` holding exactly
    /// the refusal line and nothing else, unchanged by lan-client-parity
    /// (change 4). The commands lan-client-parity *does* open a
    /// `scriptIntent` path for (`/attr set|define|remove`, `/script
    /// attach|detach|run`, `/on`, `/unsubscribe`, `/events emit`, `/ai`,
    /// `/agent`) are proved separately below
    /// (`testForwardableCommandsAttemptToRouteInsteadOfBeingRefusedLocally`)
    /// — this list intentionally excludes them.
    func testEveryScriptingAndAICommandWithNoIntentPathIsRefusedAtTheRealCallSite() throws {
        let game = try makeLANClientGame()
        XCTAssertTrue(game.isLANClientWorld)
        XCTAssertNotNil(game.player)

        let refusal = "This command runs on the LAN host only (guests get access in a later update)."
        let commands = [
            "/attr list self", "/inspect", "/objects near", "/events recent",
            "/script journal", "/script undo-ai",
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

    /// lan-client-parity (change 4), design.md §11 phase 4: `/ai`, `/agent`, `/on`,
    /// `/unsubscribe`, and every mutating `/attr`/`/script`/`events emit` subcommand no longer
    /// hit `ScriptingCommands.lanClientRefusal`'s blanket refusal at all — `CommandsM` instead
    /// attempts to forward them as a `scriptIntent`. This bare test `GameCore` has no live
    /// transport connection (`LANMultiplayerManager.shared.state != .connected`), so each one
    /// surfaces the "no active connection" line instead of either the old blanket refusal text
    /// or silence — proving the routing decision changed without needing a real socket. The
    /// host-side accept/refuse-by-`canScript` decision itself (the other half of "refused
    /// without the grant, intent-routed with it") is proved at the `LANMultiplayerHostSession`/
    /// `ScriptingCommandContext` level in `Tests/ElysiumCoreTests/LANScriptIntentHostTests.swift`
    /// — this file cannot reach those (see the header comment: no `ElysiumCore`-internal LAN
    /// session type is exercisable here without the app-layer transport it's testing).
    func testForwardableCommandsAttemptToRouteInsteadOfBeingRefusedLocally() throws {
        let game = try makeLANClientGame()
        XCTAssertEqual(LANMultiplayerManager.shared.state, .idle, "no test before this one may have left a stale connected state")

        let refusal = "This command runs on the LAN host only (guests get access in a later update)."
        let commands = [
            "/ai hello", "/agent hello", "/ai cancel",
            "/on self player.joined s.h", "/unsubscribe 1",
            "/attr set self mood happy", "/attr define self mood happy",
            "/attr remove self mood",
            "/script attach self greet module log(\"hi\")", "/script detach self greet",
            "/script run self log(\"hi\")", "/events emit self player.joined",
        ]
        for command in commands {
            chatLog.removeAll()
            runCommand(game, command)
            XCTAssertEqual(chatLog.count, 1, "command '\(command)' should push exactly one chat line")
            XCTAssertNotEqual(
                chatLog.first?.text, "§c" + refusal,
                "command '\(command)' has a scriptIntent path now — it must not hit the old blanket refusal"
            )
            XCTAssertEqual(
                chatLog.first?.text, "§cNo active LAN connection.",
                "command '\(command)' should report no connection rather than silently doing nothing"
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

    /// lan-client-parity (change 4): `/ai` now has a `scriptIntent` path (forwarded, gated on
    /// the host by `canUseAI`) — it no longer hits the old blanket "LAN host only" refusal.
    func testAiAttemptsToForwardRatherThanBeingBlanketRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/ai hello")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("LAN host only") == true)
        XCTAssertEqual(chatLog.first?.text, "§cNo active LAN connection.")
    }

    func testAgentAliasAttemptsToForwardRatherThanBeingBlanketRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/agent hello")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("LAN host only") == true)
        XCTAssertEqual(chatLog.first?.text, "§cNo active LAN connection.")
    }

    /// `/on` (subscribe) is in the design's `scriptIntent` verb list ("subscribe/unsubscribe").
    func testOnAttemptsToForwardRatherThanBeingBlanketRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/on self player.joined s.h")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("LAN host only") == true)
        XCTAssertEqual(chatLog.first?.text, "§cNo active LAN connection.")
    }

    func testUnsubscribeAttemptsToForwardRatherThanBeingBlanketRefused() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/unsubscribe 1")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("LAN host only") == true)
        XCTAssertEqual(chatLog.first?.text, "§cNo active LAN connection.")
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
    /// cancel a tool-loop request. lan-client-parity (change 4): still true
    /// (there is no `scriptIntent` verb for it), but it no longer hits the
    /// old blanket "LAN host only" text either — `cmd == "ai"` now routes
    /// through the forwarding branch first, which reports "no active
    /// connection" before ever reaching the cancel-specific message (this
    /// bare test `GameCore` has no live transport).
    func testAiCancelDoesNotHitTheOldBlanketRefusal() throws {
        let game = try makeLANClientGame()
        chatLog.removeAll()
        runCommand(game, "/ai cancel")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertFalse(chatLog.first?.text.contains("LAN host only") == true)
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

        // The write side of the exact same feature is never executed *locally* by the guest —
        // lan-client-parity (change 4) gives it a `scriptIntent` path instead of the old blanket
        // refusal (proved with a live host round trip in `LANScriptIntentHostTests`); this bare
        // `GameCore` has no live transport, so it reports that rather than either extreme.
        chatLog.removeAll()
        runCommand(game, "/attr set self mood happy")
        XCTAssertEqual(chatLog.count, 1)
        XCTAssertEqual(chatLog.first?.text, "§cNo active LAN connection.")
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
