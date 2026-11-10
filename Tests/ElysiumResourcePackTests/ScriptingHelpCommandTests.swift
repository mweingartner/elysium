// ScriptingHelpCommandTests.swift — `/help` lists the scripting commands from their single Core
// owner (`ScriptingCommands.helpSummary`) and `/help script` prints the getting-started lines,
// driven through the real chat command path (`runCommand`).

import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class ScriptingHelpCommandTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    override func setUp() {
        super.setUp()
        chatLog.removeAll()
    }

    override func tearDown() {
        chatLog.removeAll()
        super.tearDown()
    }

    private func makeGame() throws -> GameCore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-help-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let game = GameCore(db: try SaveDB.open(
            databaseURL: root.appendingPathComponent("worlds.sqlite"), migrateLegacy: false
        ))
        game.createWorld(name: "Help", seedText: "1", mode: GameMode.creative, difficulty: 2)
        return game
    }

    func testHelpListsScriptingCommandsFromTheirSingleOwnerInShortLines() throws {
        let game = try makeGame()
        runCommand(game, "/help")
        let lines = chatLog.map(\.text)
        XCTAssertTrue(lines.contains("§7Scripting: \(ScriptingCommands.helpSummary()) — try /help script"), "\(lines)")
        let text = lines.joined(separator: " ")
        for command in ["script", "on", "unsubscribe", "events", "inspector", "tp", "heal"] {
            XCTAssertTrue(text.contains(command), "missing \(command)")
        }
        for line in lines { XCTAssertLessThanOrEqual(line.count, 102, line) }
    }

    func testHelpScriptPrintsTheGettingStartedLines() throws {
        let game = try makeGame()
        runCommand(game, "/help script")
        XCTAssertEqual(chatLog.map(\.text), ScriptingCommands.scriptHelpLines().map { "§7" + $0 })
    }
}
