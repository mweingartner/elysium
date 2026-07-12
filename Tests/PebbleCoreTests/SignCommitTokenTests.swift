import XCTest
@testable import PebbleCore
import PebbleTextInput

@MainActor
final class SignCommitTokenTests: XCTestCase {
    private func makeGame(_ label: String) throws -> GameCore {
        registerAllBlocks(); registerAllItems(); registerAllEntities()
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self,
                                                                        label: "sign-\(label)"))
        game.createWorld(name: label, seedText: "41", mode: GameMode.creative, difficulty: 2)
        return game
    }

    private func safeLines(_ first: String) -> PebbleFourSignLines {
        pebbleRepairSignLines([first, "", "", ""], makeWidthStep: {
            var width = 0
            return { _ in width += 6; return width }
        }).lines
    }

    private func placeSign(_ game: GameCore, entity: BlockEntityData? = nil)
        -> (x: Int, y: Int, z: Int) {
        let x = Int(game.player.x), z = Int(game.player.z), y = Int(game.player.y) + 2
        game.world.setBlock(x, y, z, Int(cell(bid("oak_sign"))))
        if let entity { game.world.setBlockEntity(entity) }
        return (x, y, z)
    }

    func testCommitAcceptsExactNilEntityIdentityAndRejectsNilABA() throws {
        let game = try makeGame("nil")
        let p = placeSign(game)
        let token = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: nil))
        let replacement = makeSignBE(p.x, p.y, p.z)
        game.world.setBlockEntity(replacement)
        XCTAssertFalse(game.commitSignEdit(token: token, lines: safeLines("stale")))
        XCTAssertEqual(replacement.lines, ["", "", "", ""])
    }

    func testCommitRejectsEntityBlockAndWorldReplacement() throws {
        let game = try makeGame("replace")
        let p = placeSign(game)
        let original = makeSignBE(p.x, p.y, p.z)
        game.world.setBlockEntity(original)
        let entityToken = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: original))
        game.world.setBlockEntity(makeSignBE(p.x, p.y, p.z))
        XCTAssertFalse(game.commitSignEdit(token: entityToken, lines: safeLines("entity")))

        game.world.setBlockEntity(original)
        let blockToken = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: original))
        game.world.setBlock(p.x, p.y, p.z, Int(cell(bid("stone"))))
        XCTAssertFalse(game.commitSignEdit(token: blockToken, lines: safeLines("block")))

        game.world.setBlock(p.x, p.y, p.z, Int(cell(bid("oak_sign"))))
        game.world.setBlockEntity(original)
        let worldToken = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: original))
        game.createWorld(name: "replacement", seedText: "42",
                         mode: GameMode.creative, difficulty: 2)
        XCTAssertFalse(game.commitSignEdit(token: worldToken, lines: safeLines("world")))
    }

    func testCommitWritesExactlyFourBoundedLinesForExactToken() throws {
        let game = try makeGame("commit")
        let p = placeSign(game)
        let token = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: nil))
        XCTAssertTrue(game.commitSignEdit(token: token, lines: safeLines("saved")))
        XCTAssertEqual(game.world.getBlockEntity(p.x, p.y, p.z)?.lines,
                       ["saved", "", "", ""])
        XCTAssertFalse(game.commitSignEdit(token: token, lines: safeLines("replay")))
    }

    func testExistingEntityTokenIsOneShotAndFailedValidationRemainsRetryable() throws {
        let game = try makeGame("existing-one-shot")
        let p = placeSign(game)
        let entity = makeSignBE(p.x, p.y, p.z)
        game.world.setBlockEntity(entity)
        let token = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: entity))

        game.world.setBlock(p.x, p.y, p.z, Int(cell(bid("stone"))))
        XCTAssertFalse(game.commitSignEdit(token: token, lines: safeLines("blocked")))
        XCTAssertEqual(entity.lines, ["", "", "", ""])

        game.world.setBlock(p.x, p.y, p.z, Int(cell(bid("oak_sign"))))
        game.world.setBlockEntity(entity)
        XCTAssertTrue(game.commitSignEdit(token: token, lines: safeLines("saved")))
        XCTAssertEqual(entity.lines, ["saved", "", "", ""])
        XCTAssertFalse(game.commitSignEdit(token: token, lines: safeLines("replay")))
        XCTAssertEqual(entity.lines, ["saved", "", "", ""])
    }

    func testConcurrentCommitAttemptsAreMainActorSerializedAndConsumeOnce() async throws {
        let game = try makeGame("concurrent")
        let p = placeSign(game)
        let entity = makeSignBE(p.x, p.y, p.z)
        game.world.setBlockEntity(entity)
        let token = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: entity))

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<32 {
                group.addTask { @MainActor in
                    game.commitSignEdit(token: token, lines: self.safeLines("value-\(index)"))
                }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(entity.lines?.first?.hasPrefix("value-") == true)
    }

    func testQueuedWorldReplacementCannotCommitStaleTokenIntoReplacement() async throws {
        let game = try makeGame("world-race")
        let p = placeSign(game)
        let token = try XCTUnwrap(game.captureSignCommitToken(
            x: p.x, y: p.y, z: p.z, expectedEntity: nil))

        await Task.yield()
        game.createWorld(name: "world-race-replacement", seedText: "99",
                         mode: GameMode.creative, difficulty: 2)
        XCTAssertFalse(game.commitSignEdit(token: token, lines: safeLines("stale")))
        XCTAssertNil(game.world.getBlockEntity(p.x, p.y, p.z))
    }
}
