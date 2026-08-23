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
        let commands = ["/attr list self", "/inspect", "/objects near", "/ai hello", "/agent hello"]

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
