import XCTest
@testable import ElysiumCore

@MainActor
final class RPGQuickSlotInputTests: XCTestCase {
    func testRawGameCoreShiftDigitHasNoRPGFanoutOrIntent() throws {
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
            branchID: "arcanist_elementalist",
            startingSkillIDs: rpgDefaultStartingSkillIDs(pathID: "arcanist")
        )))
        game.player.selectedSlot = 4
        var captured: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { captured.append($0) }
        let before = game.player.rpg

        game.keyDown("ShiftLeft", now: 0)
        game.keyDown("Digit1", now: 10)
        game.keyUp("ShiftLeft")

        XCTAssertEqual(game.player.selectedSlot, 0,
                       "raw GameCore input is now ordinary hotbar input; AppInputRouter owns chords")
        XCTAssertEqual(game.player.rpg, before)
        XCTAssertTrue(captured.isEmpty)
    }

    func testDigitWithoutShiftStillSelectsNormalHotbarSlot() throws {
        let game = GameCore(db: try makeTempDB())
        game.createWorld(name: "RPG Normal Hotbar Input", seedText: "9192", mode: GameMode.survival, difficulty: 2)
        game.player.selectedSlot = 4

        game.keyDown("Digit2", now: 0)

        XCTAssertEqual(game.player.selectedSlot, 1)
    }

    private func makeTempDB(_ name: String = UUID().uuidString) throws -> SaveDB {
        try PersistenceTestSupport.makeDatabase(owner: self, label: "rpg-input-\(name)")
    }
}
