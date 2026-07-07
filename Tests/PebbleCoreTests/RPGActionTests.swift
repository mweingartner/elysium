import XCTest
@testable import PebbleCore

final class RPGActionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
    }

    func testPreparedDamageSpellConsumesFatigueAddsCooldownAndHurtsTarget() {
        let world = makeWorld(seed: 1)
        let player = makeArcanist(in: world, starterSpells: ["ignite"])
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 5)
        world.addEntity(player)
        world.addEntity(zombie)
        let fatigueBefore = player.rpg.fatigue

        let result = rpgCastPreparedSpell(player, spellID: "ignite")

        guard case .success(let action) = result else {
            return XCTFail("expected spell to cast")
        }
        XCTAssertEqual(action.actionID, "ignite")
        XCTAssertEqual(action.sequence, 1)
        XCTAssertEqual(action.targetEntityID, zombie.id)
        XCTAssertLessThan(zombie.health, zombie.maxHealth)
        XCTAssertGreaterThan(zombie.fireTicks, 0)
        XCTAssertEqual(player.rpg.fatigue, fatigueBefore - 2, accuracy: 0.0001)
        XCTAssertTrue(player.rpg.activeCooldowns.contains { $0.id == "ignite" && $0.remainingTicks > 0 })
    }

    func testSpellRejectsInsufficientFatigueWithoutMutatingSequence() {
        let world = makeWorld(seed: 2)
        let player = makeArcanist(in: world, starterSpells: ["ignite"])
        player.rpg.fatigue = 1

        let result = rpgCastPreparedSpell(player, spellID: "ignite")

        XCTAssertEqual(result.failure, .insufficientFatigue(required: 2, available: 1))
        XCTAssertEqual(player.rpg.actionSequence, 0)
        XCTAssertTrue(player.rpg.activeCooldowns.isEmpty)
    }

    func testMageLightPlacesTorchOnHitFace() {
        let world = makeWorld(seed: 3)
        let player = makeArcanist(in: world, starterSpells: ["mage_light"])
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        world.setBlock(0, 65, 4, Int(cell(B.stone)))

        let result = rpgCastPreparedSpell(player, spellID: "mage_light")

        guard case .success(let action) = result else {
            return XCTFail("expected mage light to cast, got \(String(describing: result.failure))")
        }
        XCTAssertEqual(action.blockPosition, RPGBlockPosition(0, 65, 3))
        XCTAssertEqual(world.getBlock(0, 65, 3) >> 4, Int(B.torch))
    }

    func testPreparedSpellCyclingUpdatesSelectedSpell() {
        let world = makeWorld(seed: 4)
        let player = makeArcanist(in: world, starterSpells: ["ignite", "mage_light"])

        XCTAssertEqual(player.rpg.selectedPreparedSpellID, "ignite")
        XCTAssertEqual(rpgCyclePreparedSpell(player), "mage_light")
        XCTAssertEqual(player.rpg.selectedPreparedSpellID, "mage_light")
        XCTAssertEqual(rpgCyclePreparedSpell(player), "ignite")
    }

    private func makeArcanist(in world: World, starterSpells: [String]) -> Player {
        let player = Player(world: world)
        let error = player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist",
            attributes: .defaultCreation,
            starterSkillID: "spell_formula",
            starterSpellIDs: starterSpells
        ))
        XCTAssertNil(error)
        return player
    }

    private func makeWorld(seed: UInt32) -> World {
        let world = World(dim: .overworld, seed: seed)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        world.setChunk(chunk)
        return world
    }
}

private extension Result where Failure == RPGActionFailure {
    var failure: RPGActionFailure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
