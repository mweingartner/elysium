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
        // Deinonychus (3.5 m) may hunt both prey below under the 1.5x size
        // ratio (a 2 m Velociraptor may no longer take the 4.5 m animal).
        let predator = try makeCreature(world, "prehistoric.deinonychus", 24.5, 8.5)
        // Add the larger ID first so this verifies the target choice does not
        // inherit `World.entities` insertion order for a symmetric pair.
        let lowID = PrehistoricCreature(world: world, definition: try definition("prehistoric.pachycephalosaurus"))
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

    // MARK: - predation policy

    func testLandPredatorOnlyHuntsPreyWithinItsSizeRatio() throws {
        let world = makeLandWorld(.prehistoricLostWorldV3)
        let raptor = try makeCreature(world, "prehistoric.velociraptor", 24.5, 8.5)
        // Gallimimus (6 m) is nearer but beyond 1.5 x the 2 m raptor; the
        // 3 m Dryosaurus is exactly at the limit and stays admissible.
        let tooLarge = try makeCreature(world, "prehistoric.gallimimus", 22.5, 8.5)
        let admissible = try makeCreature(world, "prehistoric.dryosaurus", 29.5, 8.5)
        XCTAssertFalse(PrehistoricPredationPolicy.landPredator(raptor.definition, mayHunt: tooLarge.definition))
        XCTAssertTrue(PrehistoricPredationPolicy.landPredator(raptor.definition, mayHunt: admissible.definition))

        let phase = (abs(raptor.id) % 40) * 2
        raptor.age = phase == 0 ? 79 : phase - 1
        raptor.tick()
        XCTAssertTrue(raptor.target === admissible, "the nearer but oversized herbivore is not prey")

        // A Compsognathus is too small to hunt any herd herbivore in the roster.
        let compsognathus = try definition("prehistoric.compsognathus")
        for prey in PrehistoricCreatureDefinition.all where prey.isLandHerdHerbivore {
            XCTAssertFalse(PrehistoricPredationPolicy.landPredator(compsognathus, mayHunt: prey), prey.id)
        }
        // Size gating is a hunting rule only: herbivores and non-land creatures never qualify as hunters.
        XCTAssertFalse(PrehistoricPredationPolicy.landPredator(try definition("prehistoric.triceratops"),
                                                               mayHunt: try definition("prehistoric.dryosaurus")))
        XCTAssertFalse(PrehistoricPredationPolicy.landPredator(try definition("prehistoric.mosasaurus"),
                                                               mayHunt: try definition("prehistoric.dryosaurus")))
    }

    func testPredatorIsSatiatedAfterAKillAndHuntsAgainAfterTheWindow() throws {
        let world = makeLandWorld(.prehistoricLostWorldV3)
        let predator = try makeCreature(world, "prehistoric.deinonychus", 24.5, 8.5)
        let first = try makeCreature(world, "prehistoric.dryosaurus", 27.5, 8.5)
        XCTAssertFalse(predator.isSatiatedAfterKill)

        first.health = 1
        predator.doMeleeAttack(first)
        XCTAssertGreaterThan(first.deathTime, 0)
        XCTAssertTrue(predator.isSatiatedAfterKill)
        XCTAssertEqual(predator.action, .eat)
        world.removeEntity(first)

        let next = try makeCreature(world, "prehistoric.dryosaurus", 28.5, 8.5)
        let phase = (abs(predator.id) % 40) * 2
        let killAge = predator.age
        // One acquisition phase inside the window: no new hunt starts.
        predator.age = killAge + 80 + phase - 1 - (killAge % 80)
        predator.tick()
        XCTAssertNil(predator.target, "a satiated predator ignores prey in range")

        // The first acquisition phase at or after the window hunts again.
        var resumeAge = killAge + PrehistoricPredationPolicy.satiationTicks
        while resumeAge % 80 != phase { resumeAge += 1 }
        predator.age = resumeAge - 1
        predator.tick()
        XCTAssertFalse(predator.isSatiatedAfterKill)
        XCTAssertTrue(predator.target === next)
    }

    func testFailedAttackDoesNotSatiateAPredator() throws {
        let world = makeLandWorld(.prehistoricLostWorldV3)
        let predator = try makeCreature(world, "prehistoric.deinonychus", 24.5, 8.5)
        let prey = try makeCreature(world, "prehistoric.pachycephalosaurus", 27.5, 8.5)
        predator.doMeleeAttack(prey)
        XCTAssertGreaterThan(prey.health, 0)
        XCTAssertFalse(predator.isSatiatedAfterKill, "only a genuine kill feeds the predator")
    }

    /// Losing a target because it escapes (or is otherwise removed) without a
    /// kill must never satiate the predator: `satiatedUntilAge` is written
    /// only from `doMeleeAttack`'s post-kill branch, never from
    /// `canContinue` dropping a stale target for any other reason.
    func testLosingATargetWithoutAKillDoesNotSatiateThePredator() throws {
        let world = makeLandWorld(.prehistoricLostWorldV3)
        let predator = try makeCreature(world, "prehistoric.deinonychus", 24.5, 8.5)
        let prey = try makeCreature(world, "prehistoric.dryosaurus", 27.5, 8.5)
        let phase = (abs(predator.id) % 40) * 2
        predator.age = phase == 0 ? 79 : phase - 1
        predator.tick()
        XCTAssertTrue(predator.target === prey, "the predator acquires the nearby prey")
        XCTAssertFalse(predator.isSatiatedAfterKill)

        // The prey escapes unharmed, well outside the goal's continuation
        // range (`range * 1.5` = 24 blocks for this family).
        prey.setPos(0.5, 64, -15.5)
        predator.tick()
        XCTAssertNil(predator.target, "an escaped, unharmed prey is dropped as a target")
        XCTAssertFalse(predator.isSatiatedAfterKill, "losing a target without a kill must not satiate the predator")

        // A fresh prey back in range is hunted again on the very next
        // acquisition phase: no satiation window was ever opened.
        let next = try makeCreature(world, "prehistoric.dryosaurus", 27.5, 8.5)
        var age = predator.age + 1
        while age % 80 != phase { age += 1 }
        predator.age = age - 1
        predator.tick()
        XCTAssertTrue(predator.target === next, "the predator re-hunts immediately since it was never satiated")
    }

    // MARK: - closed-population attrition

    /// One recorded death in a closed land-population run.
    private struct AttritionDeath: Equatable {
        let tick: Int
        let victimID: Int
        let victimType: String
        let cause: String
        let attackerID: Int?
    }

    /// Outcome of one closed V3 land population run: no dawn refill, no player,
    /// only the herd/predator ecology acting on a fixed roster.
    private struct LandAttritionRun: Equatable {
        var samples: [Int] = []
        var deaths: [AttritionDeath] = []
        var typesByID: [Int: String] = [:]
        var finalHerbivores = 0
        var finalPredators = 0
    }

    /// A flat, fully loaded 12×12-chunk grass plain holding twelve isolated
    /// herbivores (40 blocks apart, beyond the 18-block herd rally) and a
    /// mixed six-predator guild. Global entity ids and `gameRng` are reset so
    /// hunt phases (derived from ids) and every draw replay identically.
    /// `World.tick` is omitted: this flat, entity-only fixture has nothing
    /// for random ticks to change, and the entity loop dominates the cost.
    private func runClosedLandAttrition(ticks: Int, sampleEvery: Int = 1_200) throws -> LandAttritionRun {
        resetGameRng(hashString("prehistoric-attrition"))
        resetEntityIds(1)
        let world = World(dim: .overworld, seed: 0xA771_0003,
                          generationSettings: .init(preset: .prehistoricLostWorldV3))
        world.dayTime = 1_000
        for cz in -6..<6 {
            for cx in -6..<6 {
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
        var run = LandAttritionRun()
        world.hooks.raiseScriptEvent = { kind, subject, payload, _, subjectType in
            guard kind == .entityDied, case .entity(let victimID) = subject else { return }
            var cause = "?"
            if case .string(let value)? = payload["cause"] { cause = value }
            var attackerID: Int?
            if case .ref(let canonical)? = payload["attacker"], canonical.hasPrefix("entity:") {
                attackerID = Int(canonical.dropFirst("entity:".count))
            }
            run.deaths.append(AttritionDeath(tick: world.time, victimID: victimID,
                                             victimType: subjectType ?? "?", cause: cause,
                                             attackerID: attackerID))
        }
        let prey = ["prehistoric.dryosaurus", "prehistoric.gallimimus", "prehistoric.parasaurolophus",
                    "prehistoric.pachycephalosaurus", "prehistoric.iguanodon", "prehistoric.dryosaurus"]
        var roster: [(String, Double, Double)] = []
        for index in 0..<12 {
            let column = index % 4, row = index / 4
            let x = Double(column * 40 - 60) + 0.5
            let z = Double(row * 40 - 40) + 0.5
            roster.append((prey[index % prey.count], x, z))
        }
        roster += [
            ("prehistoric.tyrannosaurus", 0.5, 0.5), ("prehistoric.allosaurus", -20.5, 20.5),
            ("prehistoric.velociraptor", 20.5, -20.5), ("prehistoric.velociraptor", 22.5, -20.5),
            ("prehistoric.deinonychus", -20.5, -20.5), ("prehistoric.coelophysis", 20.5, 20.5),
        ]
        for (index, spec) in roster.enumerated() {
            let mob = try XCTUnwrap(spawnMob(world, spec.0, spec.1, 64, spec.2,
                                             SpawnOpts(prehistoricSeedSalt: UInt32(index + 1))))
            run.typesByID[mob.id] = mob.type
        }
        func census() -> (herbivores: Int, predators: Int) {
            var herbivores = 0, predators = 0
            for case let creature as PrehistoricCreature in world.entities where !creature.dead {
                if creature.definition.isLandHerdHerbivore { herbivores += 1 }
                if creature.definition.isLandPredator { predators += 1 }
            }
            return (herbivores, predators)
        }
        for tick in 1...ticks {
            world.time += 1
            for case let entity as Entity in Array(world.entities) where !entity.dead {
                entity.tick()
            }
            for entity in Array(world.entities) where entity.dead {
                world.removeEntity(entity)
            }
            if tick % sampleEvery == 0 {
                let now = census()
                run.samples.append(now.herbivores + now.predators)
            }
        }
        let final = census()
        run.finalHerbivores = final.herbivores
        run.finalPredators = final.predators
        return run
    }

    func testV3ClosedLandPopulationSurvivesADayOfBoundedPredation() throws {
        let run = try runClosedLandAttrition(ticks: 24_000)
        print("[prehistoric-attrition] samples=\(run.samples) herbivores=\(run.finalHerbivores) predators=\(run.finalPredators) deaths=\(run.deaths.map { "\($0.tick):\($0.victimType):\($0.cause)" })")

        XCTAssertEqual(run.samples.count, 20)
        XCTAssertFalse(run.samples.contains(0), "the land population never collapses to zero")
        XCTAssertGreaterThan(run.finalHerbivores, 0)
        // Without the predation policy this exact fixture loses its whole
        // predator guild to herd rallies by tick 4508 (population 18 -> 10);
        // bounded hunting keeps a predator alive through the day.
        XCTAssertGreaterThan(run.finalPredators, 0, "the predator trophic level survives a day")
        XCTAssertFalse(run.deaths.isEmpty, "the ecology still kills: deaths continue to occur")

        // Every herbivore a land predator killed honours the size ratio, and no
        // predator kills twice inside its satiation window.
        var lastKillByPredator: [Int: Int] = [:]
        var predatorKills = 0
        for death in run.deaths {
            guard let victim = PrehistoricCreatureDefinition.named(death.victimType),
                  victim.isLandHerdHerbivore,
                  let attackerID = death.attackerID,
                  let attackerType = run.typesByID[attackerID],
                  let attacker = PrehistoricCreatureDefinition.named(attackerType),
                  attacker.isLandPredator
            else { continue }
            predatorKills += 1
            XCTAssertTrue(PrehistoricPredationPolicy.landPredator(attacker, mayHunt: victim),
                          "\(attacker.id) killed oversized \(victim.id)")
            if let previous = lastKillByPredator[attackerID] {
                XCTAssertGreaterThanOrEqual(death.tick - previous, PrehistoricPredationPolicy.satiationTicks,
                                            "\(attacker.id) #\(attackerID) killed again while satiated")
            }
            lastKillByPredator[attackerID] = death.tick
        }
        XCTAssertGreaterThan(predatorKills, 0, "predators still take herd prey")
    }

    func testClosedLandAttritionReplaysIdentically() throws {
        let first = try runClosedLandAttrition(ticks: 4_000, sampleEvery: 500)
        let second = try runClosedLandAttrition(ticks: 4_000, sampleEvery: 500)
        XCTAssertFalse(first.deaths.isEmpty)
        XCTAssertEqual(first, second)
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
