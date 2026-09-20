import Foundation
import XCTest
@testable import ElysiumCore

/// Focused V2 ecosystem contracts. The fixture keeps enough loaded, dry land
/// for body-aware goal navigation without depending on world generation.
final class PrehistoricEcosystemTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerBlockEntityHandlers()
    }

    private func makeLandWorld(_ preset: WorldPreset) -> World {
        let world = World(dim: .overworld, seed: 0xEC05_0002,
                          generationSettings: .init(preset: preset))
        for cz in -1...1 {
            for cx in 0...2 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        chunk.set(x, 62, z, cell(B.stone))
                        chunk.set(x, 63, z, cell(B.grass_block))
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    private func definition(_ id: String) throws -> PrehistoricCreatureDefinition {
        try XCTUnwrap(PrehistoricCreatureDefinition.named(id))
    }

    private func makeCreature(_ world: World, _ id: String, _ x: Double, _ z: Double) throws -> PrehistoricCreature {
        let creature = PrehistoricCreature(world: world, definition: try definition(id))
        creature.setPos(x, 64, z)
        world.addEntity(creature)
        return creature
    }

    func testV1RetainsLegacyHerbivoreCombatWhileV2ScalesDefenseAndXP() throws {
        let stegosaurus = try definition("prehistoric.stegosaurus")
        let v1 = PrehistoricCreature(
            world: makeLandWorld(.prehistoricLostWorld), definition: stegosaurus
        )
        let v2 = PrehistoricCreature(
            world: makeLandWorld(.prehistoricLostWorldV2), definition: stegosaurus
        )

        XCTAssertFalse(WorldPreset.prehistoricLostWorld.supportsPredatorHerdCombat)
        XCTAssertTrue(WorldPreset.prehistoricLostWorldV2.supportsPredatorHerdCombat)
        XCTAssertEqual(v1.attackDamage, stegosaurus.attackDamage)
        XCTAssertEqual(v1.kbResist, 0)
        XCTAssertEqual(v1.xpReward, stegosaurus.combatXPReward)
        XCTAssertEqual(v2.attackDamage, stegosaurus.herdDefenseDamage)
        XCTAssertEqual(v2.kbResist, stegosaurus.herdKnockbackResistance)
        XCTAssertEqual(v2.xpReward, stegosaurus.combatXPReward(ecosystemCombat: true))
        XCTAssertGreaterThan(v2.xpReward, v1.xpReward)
    }

    func testV2LandPredatorTargetsNearestHerdHerbivoreWithStableIDTieBreak() throws {
        let world = makeLandWorld(.prehistoricLostWorldV2)
        let predator = try makeCreature(world, "prehistoric.velociraptor", 24.5, 8.5)
        // Add the larger ID first so this verifies the target choice does not
        // inherit `World.entities` insertion order for a symmetric pair.
        let lowID = PrehistoricCreature(world: world, definition: try definition("prehistoric.gallimimus"))
        lowID.setPos(20.5, 64, 8.5)
        let highID = PrehistoricCreature(world: world, definition: try definition("prehistoric.dryosaurus"))
        highID.setPos(28.5, 64, 8.5)
        world.addEntity(highID)
        world.addEntity(lowID)
        XCTAssertLessThan(lowID.id, highID.id)

        let phase = (abs(predator.id) % 40) * 2
        predator.age = phase == 0 ? 79 : phase - 1
        predator.tick()

        XCTAssertTrue(predator.target === lowID)
        XCTAssertEqual(predator.action, .alert)
    }

    func testV2HerdRalliesAcrossSpeciesAndPredatorFeedsOnlyAfterKill() throws {
        let world = makeLandWorld(.prehistoricLostWorldV2)
        let predator = try makeCreature(world, "prehistoric.velociraptor", 24.5, 8.5)
        let wounded = try makeCreature(world, "prehistoric.dryosaurus", 27.5, 8.5)
        let defender = try makeCreature(world, "prehistoric.stegosaurus", 30.5, 8.5)

        predator.doMeleeAttack(wounded)
        XCTAssertGreaterThan(wounded.hurtTime, 0)
        XCTAssertTrue(wounded.lastAttacker === predator)
        defender.age = 1
        defender.tick()
        XCTAssertTrue(defender.target === predator,
                      "a different herbivore species must rally against the same predator")

        wounded.invulnTicks = 0
        wounded.health = 1
        predator.doMeleeAttack(wounded)
        XCTAssertGreaterThan(wounded.deathTime, 0)
        XCTAssertEqual(predator.action, .eat)
        XCTAssertNil(predator.target)
    }

    func testV2HerbivoreResistanceAppliesOnlyToPrehistoricLandPredators() throws {
        let world = makeLandWorld(.prehistoricLostWorldV2)
        let predator = try makeCreature(world, "prehistoric.velociraptor", 24.5, 8.5)
        let herbivore = try makeCreature(world, "prehistoric.ankylosaurus", 27.5, 8.5)
        let definition = herbivore.definition

        let beforePredatorHit = herbivore.health
        XCTAssertTrue(herbivore.hurt(10, "mob", predator))
        XCTAssertEqual(herbivore.health, beforePredatorHit - 10 * definition.herdPredatorDamageMultiplier,
                       accuracy: 0.000_001)

        herbivore.invulnTicks = 0
        let player = Player(world: world)
        let beforePlayerHit = herbivore.health
        XCTAssertTrue(herbivore.hurt(10, "player", player))
        XCTAssertEqual(herbivore.health, beforePlayerHit - 10, accuracy: 0.000_001)
    }
}
