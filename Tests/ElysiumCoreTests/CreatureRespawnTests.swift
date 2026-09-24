import Foundation
import XCTest
@testable import ElysiumCore

final class CreatureRespawnTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
    }

    /// Full dawn sampling radius, with immutable terrain filled directly so
    /// the fixture does not benchmark lighting or world-generation setup.
    private func fixture(_ preset: WorldPreset = .normal, unsupported: Bool = false,
                         waterDepth: Int = 0) -> (World, Player) {
        let world = World(dim: .overworld, seed: 0xD_AA7, generationSettings: .init(preset: preset))
        world.dayTime = 0
        world.difficulty = 0
        for cz in -7...6 {
            for cx in -7...6 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                chunk.biomes = Array(repeating: UInt8(Biome.plains.rawValue), count: chunk.biomes.count)
                for z in 0..<16 {
                    for x in 0..<16 {
                        if !unsupported || (x + z) % 2 == 0 {
                            chunk.set(x, 63, z, cell(B.grass_block))
                            chunk.heightmap[z * 16 + x] = 63
                        }
                        if waterDepth > 0 {
                            for y in 64..<(64 + waterDepth) { chunk.set(x, y, z, cell(B.water)) }
                        }
                        chunk.setSky(x, 64, z, 15)
                    }
                }
                world.setChunk(chunk)
            }
        }
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        world.addEntity(player)
        return (world, player)
    }

    private func state(_ rng: RandomX) -> [UInt32] {
        let s = rng.stateWords
        return [s.0, s.1, s.2, s.3]
    }

    func testOrdinaryRuntimeNoLongerReplenishesSkyWildlifeBetweenDawns() {
        let world = World(dim: .overworld, seed: 4)
        world.difficulty = 0
        let player = Player(world: world)
        world.addEntity(player)
        var rng = RandomX(91)
        let before = state(rng)
        for dayTime in [0, 1_000, 6_000, 13_000, 23_999] {
            world.dayTime = dayTime
            world.time = 400
            naturalSpawnTick(world, [player], &rng)
        }
        XCTAssertEqual(world.entities.count, 1)
        XCTAssertEqual(state(rng), before, "suppressed passive attempts consume no spawn RNG")
    }

    func testNoSkyRuntimeRetainsPassiveCadence() {
        let world = World(dim: .nether, seed: 4)
        world.difficulty = 0
        world.time = 400
        let player = Player(world: world)
        world.addEntity(player)
        var rng = RandomX(91)
        let before = state(rng)
        naturalSpawnTick(world, [player], &rng)
        XCTAssertNotEqual(state(rng), before, "Nether still attempts its existing passive populations")
    }

    func testOrdinaryHostileRuntimeRemainsActiveOutsideDawn() {
        let world = World(dim: .overworld, seed: 4)
        world.difficulty = 2
        world.time = 1
        world.dayTime = 13_000
        let player = Player(world: world)
        var rng = RandomX(91)
        let before = state(rng)
        naturalSpawnTick(world, [player], &rng)
        XCTAssertNotEqual(state(rng), before, "the ordinary monster attempt is still live every tick")
    }

    func testDawnBoundaryRefusesNightClientNoSkyDisabledAndInvalidPlayersWithoutRNG() {
        let world = World(dim: .overworld, seed: 4)
        let player = Player(world: world)
        world.addEntity(player)
        var rng = RandomX(91)
        let before = state(rng)
        for dayTime in [-1, 1_000, 6_000, 13_000, 23_999] {
            world.dayTime = dayTime
            XCTAssertEqual(replenishCreaturesAtDawn(world, [player], &rng).candidateAttempts, 0)
        }
        world.dayTime = 0
        world.isTransientLANClient = true
        XCTAssertEqual(replenishCreaturesAtDawn(world, [player], &rng).candidateAttempts, 0)
        world.isTransientLANClient = false
        world.gameRules["doMobSpawning"] = 0
        XCTAssertEqual(replenishCreaturesAtDawn(world, [player], &rng).candidateAttempts, 0)
        world.gameRules["doMobSpawning"] = 1
        XCTAssertEqual(replenishCreaturesAtDawn(world, [], &rng).candidateAttempts, 0)
        player.dead = true
        XCTAssertEqual(replenishCreaturesAtDawn(world, [player], &rng).candidateAttempts, 0)
        player.dead = false
        player.setPos(.infinity, 64, 0)
        XCTAssertEqual(replenishCreaturesAtDawn(world, [player], &rng).candidateAttempts, 0)
        let nether = World(dim: .nether, seed: 4)
        nether.dayTime = 0
        let netherPlayer = Player(world: nether)
        XCTAssertEqual(replenishCreaturesAtDawn(nether, [netherPlayer], &rng).candidateAttempts, 0)
        XCTAssertEqual(state(rng), before)
    }

    func testDawnRefillsOrdinaryAnimalsWithoutDinosaursAndHonorsCaps() {
        let (world, player) = fixture()
        var rng = RandomX(0xD00D)
        let report = replenishCreaturesAtDawn(world, [player], &rng)
        XCTAssertEqual(report.creaturesSpawned, 18)
        XCTAssertLessThanOrEqual(report.ambientSpawned, 15)
        XCTAssertLessThanOrEqual(report.waterSpawned, 5)
        XCTAssertLessThanOrEqual(report.candidateAttempts, 128)
        XCTAssertFalse(world.entities.contains { $0 is PrehistoricCreature })
        for entity in world.entities where entity !== player {
            let dx = entity.x - player.x, dy = entity.y - player.y, dz = entity.z - player.z
            XCTAssertGreaterThanOrEqual(dx * dx + dy * dy + dz * dz, 24 * 24)
            XCTAssertNotNil(world.dryGroundY(ifloor(entity.x), ifloor(entity.z)))
        }
        let next = replenishCreaturesAtDawn(world, [player], &rng)
        XCTAssertEqual(next.creaturesSpawned, 0, "a subsequent eligible wave adds only vacancies")
        XCTAssertEqual(world.entities.compactMap { $0 as? Mob }.filter { $0.category == "creature" }.count, 18)
    }

    func testSuccessfulLandBirthsFollowHerbivoreHerbivoreCarnivoreAcrossWaves() throws {
        let (world, player) = fixture(.prehistoricLostWorldV2)
        var residents: [Entity] = []
        for _ in 0..<17 { residents.append(try XCTUnwrap(spawnMob(world, "cow", 0, 64, 0))) }
        var rng = RandomX(0xCA11)
        let first = replenishCreaturesAtDawn(world, [player], &rng)
        XCTAssertEqual(first.creaturesSpawned, 1)
        let firstBirth = try XCTUnwrap(world.entities.compactMap { $0 as? PrehistoricCreature }.first { $0.definition.medium == .land })
        XCTAssertTrue(firstBirth.definition.isLandHerdHerbivore)
        XCTAssertEqual(world.creatureRespawnSequence, 1)

        // Two vacancies continue the saved sequence rather than starting a
        // fresh H,H,C wave and starving carnivores whenever capacity is tight.
        world.removeEntity(residents.removeLast())
        world.removeEntity(residents.removeLast())
        let oldIDs = Set(world.entities.compactMap { ($0 as? Entity)?.id })
        let second = replenishCreaturesAtDawn(world, [player], &rng)
        XCTAssertEqual(second.creaturesSpawned, 2)
        let births = world.entities.compactMap { $0 as? PrehistoricCreature }
            .filter { $0.definition.medium == .land && !oldIDs.contains($0.id) }
        XCTAssertEqual(births.count, 2)
        if births.count == 2 {
            XCTAssertTrue(births[0].definition.isLandHerdHerbivore)
            XCTAssertTrue(births[1].definition.isLandPredator)
        }
        XCTAssertEqual(world.creatureRespawnSequence, 0)
    }

    func testPrehistoricDietFilterDoesNotMisclassifySeaOrAirCreatures() {
        for profile in PrehistoricWorldProfile.allCases {
            for sequence in 0...2 {
                let entries = prehistoricDawnLandEntries(profile: profile, sequence: sequence)
                if profile.isAncientSeas {
                    XCTAssertTrue(entries.isEmpty)
                } else {
                    XCTAssertFalse(entries.isEmpty)
                }
                for entry in entries {
                    let definition = PrehistoricCreatureDefinition.named(entry.mob)!
                    XCTAssertEqual(definition.medium, .land)
                    XCTAssertEqual(sequence == 2 ? definition.isLandPredator : definition.isLandHerdHerbivore, true)
                }
            }
        }
    }

    func testAncientSeasKeepsAirRosterWithoutInventingLandHerbivores() {
        let (world, player) = fixture(.prehistoricAncientSeasV2)
        var rng = RandomX(0xAC1D)
        let report = replenishCreaturesAtDawn(world, [player], &rng)
        XCTAssertEqual(report.creaturesSpawned, 0)
        XCTAssertGreaterThan(report.ambientSpawned, 0)
        XCTAssertEqual(world.creatureRespawnSequence, 0)
        XCTAssertLessThanOrEqual(report.candidateAttempts, 64, "empty land roster spends no attempts")
        XCTAssertTrue(world.entities.compactMap { $0 as? PrehistoricCreature }.allSatisfy {
            PrehistoricWorldProfile.ancientSeas.creatureIDs.contains($0.type) && $0.definition.medium != .land
        })
    }

    func testAquaticDawnUsesWaterAdmissionAndDoesNotSpawnLandCreaturesInTheSea() {
        let (world, player) = fixture(.prehistoricAncientSeasV2, waterDepth: 16)
        player.setPos(0.5, 80, 0.5)
        var rng = RandomX(0x5EA)
        let report = replenishCreaturesAtDawn(world, [player], &rng)
        XCTAssertEqual(report.waterSpawned, 5)
        XCTAssertEqual(report.creaturesSpawned, 0)
        XCTAssertEqual(report.ambientSpawned, 0)
        let allowed = prehistoricSpawnEntries(profile: .ancientSeas, category: "water").map(\.mob)
        for mob in world.entities.compactMap({ $0 as? Mob }) {
            XCTAssertEqual(mob.category, "water")
            XCTAssertTrue(allowed.contains(mob.type))
            XCTAssertEqual(world.getBlock(ifloor(mob.x), ifloor(mob.y), ifloor(mob.z)) >> 4, Int(B.water))
        }
    }

    func testDawnSitesAvoidEveryAuthoritativePlayerAndRespectMapEdges() {
        let (world, player) = fixture()
        let guest = Player(world: world)
        guest.setPos(48.5, 64, 0.5)
        world.addEntity(guest)
        world.playableMinX = -64; world.playableMaxX = 64
        world.playableMinZ = -64; world.playableMaxZ = 64
        var rng = RandomX(0xA11)
        let report = replenishCreaturesAtDawn(world, [player, guest], &rng)
        XCTAssertGreaterThan(report.creaturesSpawned, 0)
        for mob in world.entities.compactMap({ $0 as? Mob }) {
            XCTAssertTrue((-64...64).contains(ifloor(mob.x)))
            XCTAssertTrue((-64...64).contains(ifloor(mob.z)))
            for active in [player, guest] {
                let dx = mob.x - active.x, dy = mob.y - active.y, dz = mob.z - active.z
                XCTAssertGreaterThanOrEqual(dx * dx + dy * dy + dz * dz, 24 * 24)
            }
        }
    }

    func testRefusalHeavyClearanceWaveIsBoundedAndDoesNotAdvanceRatio() throws {
        let (world, player) = fixture(.prehistoricLostWorldV2, unsupported: true)
        let giant = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.brachiosaurus"))
        XCTAssertFalse(prehistoricHasClearance(world, definition: giant, x: 32, y: 64, z: 32, requireGround: true),
                       "a clear-looking centre is not whole-body ground support")
        world.creatureRespawnSequence = 1
        var rng = RandomX(0xF411)
        let start = ContinuousClock.now
        let report = replenishCreaturesAtDawn(world, [player], &rng)
        let duration = start.duration(to: .now)
        print("[creature-respawn] refusal-heavy dawn: \(report.candidateAttempts) candidates, \(report.siteAdmissionChecks) admission checks, \(duration)")
        XCTAssertEqual(report.candidateAttempts, 128)
        XCTAssertGreaterThan(report.siteAdmissionChecks, 32)
        XCTAssertEqual(report.totalSpawned, 0)
        XCTAssertEqual(world.creatureRespawnSequence, 1)
    }

    func testDawnSamplingAndSpeciesPicksAreDeterministic() {
        func run() -> ([String], [UInt32], CreatureRespawnReport) {
            let (world, player) = fixture(.prehistoricJurassicGiantsV2)
            var rng = RandomX(777)
            let report = replenishCreaturesAtDawn(world, [player], &rng)
            let population = world.entities.compactMap { $0 as? Mob }.map {
                "\($0.type)|\($0.x)|\($0.y)|\($0.z)"
            }
            return (population, state(rng), report)
        }
        let first = run(), second = run()
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(first.2, second.2)
    }
}
