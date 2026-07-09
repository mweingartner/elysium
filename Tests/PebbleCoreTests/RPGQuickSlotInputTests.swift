import XCTest
@testable import PebbleCore

final class RPGQuickSlotInputTests: XCTestCase {
    func testShiftDigitUsesRPGQuickSlotWithoutChangingHotbarSelection() throws {
        let game = GameCore(db: try makeTempDB())
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "rpg-input-host",
            worldName: "RPG Input Host",
            seed: 9191,
            gameMode: GameMode.survival,
            difficulty: 2,
            dimension: Dim.overworld.rawValue,
            playerCount: 2,
            rpgClassesEnabled: true
        ))
        XCTAssertNil(game.player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist",
            attributes: .defaultCreation,
            starterSkillID: "spell_formula",
            starterSpellIDs: ["ignite"]
        )))
        game.player.selectedSlot = 4
        var captured: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { captured.append($0) }

        game.keyDown("ShiftLeft", now: 0)
        game.keyDown("Digit1", now: 10)
        game.keyUp("ShiftLeft")

        XCTAssertEqual(game.player.selectedSlot, 4)
        XCTAssertEqual(game.player.rpg.actionSequence, 0)
        XCTAssertEqual(game.player.rpg.selectedPreparedActionID, rpgPreparedActionToken(kind: .spell, id: "ignite"))
        XCTAssertEqual(captured, [
            LANRPGIntent(action: .castSpell, spellID: "ignite", actionSequence: 1)
        ])
    }

    func testDigitWithoutShiftStillSelectsNormalHotbarSlot() throws {
        let game = GameCore(db: try makeTempDB())
        game.createWorld(name: "RPG Normal Hotbar Input", seedText: "9192", mode: GameMode.survival, difficulty: 2)
        game.player.selectedSlot = 4

        game.keyDown("Digit2", now: 0)

        XCTAssertEqual(game.player.selectedSlot, 1)
    }

    private func makeTempDB(_ name: String = UUID().uuidString) throws -> SaveDB {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-rpg-input-tests-\(name)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SaveDB(databaseURL: dir.appendingPathComponent("pebble.db"), migrateLegacy: false)
    }
}
