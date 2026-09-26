// SpawnPlacementValidationTests.swift — the shared, RNG-free spawn-placement
// rule: only aquatic creatures are put into water. Covers the validator
// itself, the water-filled-flora hole in natural spawning and prehistoric
// clearance, raid waves and patrols beside a lake, and the AI companion's
// summon.

import XCTest
@testable import ElysiumCore

final class SpawnPlacementValidationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerAllSystems()
    }

    // MARK: - fixtures

    /// Sand seabed at y=57 under still water from y=58 through y=63 (a
    /// six-deep lake), except columns where `dry` holds, which are grass
    /// ground topped at y=63. Every chunk in -radius..<radius is loaded and lit.
    private func makeLakeWorld(seed: UInt32 = 0x1A4E, radius: Int = 2,
                               dry: (Int, Int) -> Bool = { _, _ in false }) -> World {
        let world = World(dim: .overworld, seed: seed)
        world.dayTime = 1_000
        world.difficulty = 2
        for cz in -radius..<radius {
            for cx in -radius..<radius {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        let wx = cx * CHUNK_W + x, wz = cz * CHUNK_W + z
                        chunk.set(x, 56, z, cell(B.stone))
                        chunk.set(x, 57, z, cell(B.sand))
                        if dry(wx, wz) {
                            for y in 58..<63 { chunk.set(x, y, z, cell(B.dirt)) }
                            chunk.set(x, 63, z, cell(B.grass_block))
                        } else {
                            for y in 58...63 { chunk.set(x, y, z, cell(B.water)) }
                        }
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    /// True when a spawned body's feet, head, or the cell it stands on is water.
    private func isInOrOnWater(_ world: World, _ entity: Entity) -> Bool {
        let x = ifloor(entity.x), y = ifloor(entity.y), z = ifloor(entity.z)
        return [y - 1, y, y + 1].contains { spawnPlacementCellIsWater(world, x, $0, z) }
    }

    // MARK: - the shared validator

    func testMediumClassification() {
        for aquatic in ["squid", "glow_squid", "cod", "salmon", "tropical_fish", "pufferfish",
                        "dolphin", "axolotl", "guardian", "elder_guardian", "tadpole",
                        "prehistoric.ichthyosaurus", "prehistoric.mosasaurus"] {
            XCTAssertEqual(spawnPlacementMedium(forMob: aquatic), .water, aquatic)
        }
        for land in ["cow", "zombie", "pillager", "villager", "prehistoric.dryosaurus",
                     "prehistoric.tyrannosaurus", "prehistoric.pteranodon"] {
            XCTAssertEqual(spawnPlacementMedium(forMob: land), .land, land)
        }
        for amphibian in ["drowned", "turtle", "frog"] {
            XCTAssertEqual(spawnPlacementMedium(forMob: amphibian), .amphibious, amphibian)
        }
        XCTAssertEqual(spawnPlacementMedium(forMob: "boat"), .object)
    }

    func testLandMobIsRejectedInWaterWhileAquaticMobIsAdmitted() {
        let world = makeLakeWorld { x, _ in x < 0 }
        // Lake column (x >= 0): the surface-scan position is on the seabed, in water.
        let lakeY = world.surfaceY(4, 4)
        XCTAssertEqual(lakeY, 58)
        for land in ["cow", "zombie", "pillager", "vindicator", "villager"] {
            XCTAssertFalse(spawnPlacementIsValid(world, land, 4, lakeY, 4), land)
        }
        for aquatic in ["cod", "squid", "dolphin", "guardian"] {
            XCTAssertTrue(spawnPlacementIsValid(world, aquatic, 4, lakeY, 4), aquatic)
        }
        // A land body right above the surface would drop straight into the lake.
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", 4, 64, 4))
        // Dry ground (x < 0) admits land mobs and refuses fish.
        let dryY = world.surfaceY(-4, 4)
        XCTAssertEqual(dryY, 64)
        XCTAssertTrue(spawnPlacementIsValid(world, "cow", -4, dryY, 4))
        XCTAssertTrue(spawnPlacementIsValid(world, "pillager", -4, dryY, 4))
        XCTAssertFalse(spawnPlacementIsValid(world, "cod", -4, dryY, 4))
        // Amphibians and boats are at home in the lake; lava is refused to all.
        XCTAssertTrue(spawnPlacementIsValid(world, "drowned", 4, lakeY, 4))
        XCTAssertTrue(spawnPlacementIsValid(world, "boat", 4, 63, 4))
        world.setBlock(-4, dryY, 4, Int(cell(B.lava)))
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", -4, dryY, 4))
        XCTAssertFalse(spawnPlacementIsValid(world, "drowned", -4, dryY, 4))
        // Unloaded columns are never valid.
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", 400, 64, 400))
    }

    func testDryLandPlacementOnlyRefusesSolidBodyCells() {
        let world = makeLakeWorld { _, _ in true }
        let poppy = Int(cell(bid("poppy")))
        XCTAssertFalse(blockDefs[poppy >> 4].replaceable, "flowers are not replaceable")
        world.setBlock(2, 64, 2, poppy)
        XCTAssertTrue(spawnPlacementIsValid(world, "pillager", 2, 64, 2),
                      "a raider may stand in a flower meadow")
        world.setBlock(3, 64, 3, Int(cell(B.stone)))
        XCTAssertFalse(spawnPlacementIsValid(world, "pillager", 3, 64, 3), "never inside a solid block")
        world.setBlock(4, 65, 4, Int(cell(B.stone)))
        XCTAssertFalse(spawnPlacementIsValid(world, "pillager", 4, 64, 4), "never with its head in one")
    }

    func testPrehistoricMediumDecidesWaterAdmission() throws {
        let world = makeLakeWorld(radius: 3) { x, _ in x < 0 }
        XCTAssertFalse(spawnPlacementIsValid(world, "prehistoric.dryosaurus", 12, 58, 12),
                       "a land dinosaur is never placed in the lake")
        XCTAssertTrue(spawnPlacementIsValid(world, "prehistoric.ichthyosaurus", 12, 59, 12),
                      "an aquatic reptile goes into open water")
        XCTAssertFalse(spawnPlacementIsValid(world, "prehistoric.ichthyosaurus", -12, 64, 12),
                       "an aquatic reptile is never placed on land")
        XCTAssertTrue(spawnPlacementIsValid(world, "prehistoric.dryosaurus", -12, 64, 12))
    }

    func testSpawnPlacementRejectsWorldMinAndMaxHeightBoundaries() {
        let world = makeLakeWorld { _, _ in true }
        let minY = world.info.minY
        let maxY = minY + world.info.height
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", 2, minY, 2), "exactly at minY")
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", 2, minY - 1, 2), "below minY")
        XCTAssertTrue(spawnPlacementIsValid(world, "cow", 2, minY + 1, 2), "just above minY, open air")
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", 2, maxY - 1, 2),
                       "the head cell would be at or beyond the top of the world")
        XCTAssertTrue(spawnPlacementIsValid(world, "cow", 2, maxY - 2, 2),
                      "the head cell just fits under the top of the world")
    }

    // MARK: - water-filled flora

    /// One column: sand floor, tall seagrass (bottom, top) in a two-deep
    /// pool, open sky above — the shape natural spawning used to accept.
    private func makeTallSeagrassPool() -> (World, Int) {
        let world = makeLakeWorld { _, _ in true }
        let y = 64
        for (dx, dz) in [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1)] {
            world.setBlock(2 + dx, y - 1, 2 + dz, Int(cell(B.sand)))
        }
        world.setBlock(2, y, 2, Int(cell(bid("tall_seagrass"), 0)))
        world.setBlock(2, y + 1, 2, Int(cell(bid("tall_seagrass"), 1)))
        if let chunk = world.getChunkAt(2, 2) {
            chunk.setSky(2, y, 2, 15)
            chunk.setSky(2, y + 1, 2, 15)
        }
        return (world, y)
    }

    func testNaturalSpawningRejectsLandMobsInsideWaterFilledFlora() {
        let (world, y) = makeTallSeagrassPool()
        XCTAssertTrue(isWaterlogged(UInt16(world.getBlock(2, y, 2))))
        XCTAssertTrue(blockDefs[world.getBlock(2, y, 2) >> 4].replaceable,
                      "seagrass is replaceable, which is how it slipped through")
        var rng = RandomX(7)
        XCTAssertFalse(canSpawnAt(world, "cow", "creature", 2, y, 2, &rng))
        XCTAssertFalse(spawnPlacementIsValid(world, "cow", 2, y, 2))
        // The same dry cell without the seagrass still admits the animal.
        world.setBlock(2, y, 2, 0)
        world.setBlock(2, y + 1, 2, 0)
        XCTAssertTrue(canSpawnAt(world, "cow", "creature", 2, y, 2, &rng))
    }

    func testPrehistoricLandClearanceRejectsWaterFilledFlora() throws {
        let (world, y) = makeTallSeagrassPool()
        let dryosaurus = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.dryosaurus"))
        XCTAssertFalse(prehistoricHasClearance(world, definition: dryosaurus, x: 2, y: y, z: 2,
                                               requireGround: true))
        world.setBlock(2, y, 2, 0)
        world.setBlock(2, y + 1, 2, 0)
        XCTAssertTrue(prehistoricHasClearance(world, definition: dryosaurus, x: 2, y: y, z: 2,
                                              requireGround: true))
    }

    // MARK: - dolphins

    func testDolphinsCountAgainstTheWaterCap() {
        let world = World(dim: .overworld, seed: 4)
        XCTAssertEqual(Dolphin(world: world).category, "water")
        XCTAssertEqual(Squid(world: world).category, "water")
        XCTAssertEqual(Cow(world: world).category, "creature")
    }

    // MARK: - raids and patrols

    /// Dry 3×3 pads every 8 blocks across an otherwise flooded plain: any
    /// sampled column reaches a pad within the 4-block placement search.
    private func padded(_ x: Int, _ z: Int) -> Bool {
        posMod(x, 8) < 3 && posMod(z, 8) < 3
    }

    func testRaidWaveNextToALakeNeverPlacesARaiderInWater() {
        let world = makeLakeWorld(radius: 5, dry: padded)
        let manager = RaidManager()
        let raid = Raid(world: world, cx: 1, cy: 64, cz: 1, totalWaves: 5)
        raid.cooldown = 0
        manager.raids.append(raid)
        manager.tick(world)

        XCTAssertEqual(raid.wave, 1)
        XCTAssertEqual(raid.raiders.count, 5, "every wave-1 member finds a dry pad nearby")
        for id in raid.raiders {
            guard let raider = world.entityById[id] as? Entity else { return XCTFail("raider \(id) missing") }
            XCTAssertFalse(isInOrOnWater(world, raider), "\(raider.type) placed in water at \(raider.x),\(raider.y),\(raider.z)")
            XCTAssertTrue(padded(ifloor(raider.x), ifloor(raider.z)))
        }
    }

    func testRaidWaveOverOpenWaterIsRerolledThenMovesOn() {
        let world = makeLakeWorld(radius: 5)
        let manager = RaidManager()
        let raid = Raid(world: world, cx: 1, cy: 64, cz: 1, totalWaves: 5)
        raid.cooldown = 0
        manager.raids.append(raid)
        for attempt in 1...RAID_WAVE_PLACEMENT_REROLLS {
            manager.tick(world)
            XCTAssertEqual(raid.wave, 0, "a wave with no dry placement is not consumed")
            XCTAssertEqual(raid.wavePlacementRerolls, attempt)
            XCTAssertTrue(raid.raiders.isEmpty)
            raid.cooldown = 0
        }
        manager.tick(world)
        XCTAssertEqual(raid.wave, 1, "after bounded re-rolls the raid moves on")
        XCTAssertEqual(raid.wavePlacementRerolls, 0)
        XCTAssertFalse(world.entities.contains { ($0 as? Entity)?.type == "pillager" },
                       "nothing was ever placed into the lake")
    }

    /// `wavePlacementRerolls` resets to zero for every new wave (it is not a
    /// running total across the whole raid), and a raid that is entirely
    /// surrounded by open water still ends rather than stalling forever. It ends
    /// without victory: a raid nobody fought grants no Hero of the Village.
    func testRaidWaveRerollCounterResetsPerWaveAndAnUnreachableRaidEndsWithoutReward() {
        let world = makeLakeWorld(radius: 5)
        let manager = RaidManager()
        let totalWaves = 2
        let raid = Raid(world: world, cx: 1, cy: 64, cz: 1, totalWaves: totalWaves)
        raid.cooldown = 0
        manager.raids.append(raid)
        let player = Player(world: world)
        player.setPos(1.5, 70, 1.5)
        world.addEntity(player)

        for wave in 1...totalWaves {
            for attempt in 1...RAID_WAVE_PLACEMENT_REROLLS {
                manager.tick(world)
                XCTAssertEqual(raid.wave, wave - 1, "wave \(wave) is not consumed while re-rolling")
                XCTAssertEqual(raid.wavePlacementRerolls, attempt,
                               "wave \(wave)'s own reroll count, independent of any earlier wave")
                XCTAssertTrue(raid.raiders.isEmpty)
                raid.cooldown = 0
            }
            manager.tick(world) // exhausts this wave's budget; it is consumed with zero raiders
            XCTAssertEqual(raid.wave, wave)
            XCTAssertEqual(raid.wavePlacementRerolls, 0, "reset before the next wave's own attempts")
            XCTAssertTrue(raid.raiders.isEmpty)
            raid.cooldown = 0
        }
        manager.tick(world) // alive == 0 and wave >= totalWaves
        XCTAssertFalse(raid.active, "the unreachable raid ends")
        XCTAssertFalse(raid.victory, "no raider was ever fought, so there is no victory")
        XCTAssertFalse(raid.defeat)
        XCTAssertFalse(player.hasEffect("hero_of_the_village"), "no reward for a raid nobody fought")
        XCTAssertFalse(world.entities.contains { ($0 as? Entity)?.type == "pillager" },
                       "no raider was ever placed into the lake across the whole raid")
    }

    func testRaidThatFoughtAWaveStillReachesVictoryWhenALaterWaveIsUnreachable() {
        let world = makeLakeWorld(radius: 5)
        let manager = RaidManager()
        let raid = Raid(world: world, cx: 1, cy: 64, cz: 1, totalWaves: 1)
        raid.cooldown = 0
        raid.raidersSpawned = 3 // an earlier wave was placed and fought
        manager.raids.append(raid)
        let player = Player(world: world)
        player.setPos(1.5, 70, 1.5)
        world.addEntity(player)
        for _ in 0...RAID_WAVE_PLACEMENT_REROLLS { manager.tick(world); raid.cooldown = 0 }
        manager.tick(world)
        XCTAssertTrue(raid.victory)
        XCTAssertTrue(player.hasEffect("hero_of_the_village"))
    }

    func testUnreachableRaidDoesNotBlockANewRaidAtTheVillage() {
        let world = makeLakeWorld(radius: 5)
        let manager = RaidManager()
        let ended = Raid(world: world, cx: 1, cy: 64, cz: 1, totalWaves: 1)
        ended.active = false // ended without victory or defeat
        manager.raids.append(ended)
        let player = Player(world: world)
        player.setPos(1.5, 70, 1.5)
        world.addEntity(player)
        XCTAssertNil(manager.activeRaidNear(world, 1.5, 1.5))
        guard let villager = spawnMob(world, "villager", 2.5, 64, 2.5) else {
            return XCTFail("fixture needs a villager to start a raid")
        }
        XCTAssertFalse(villager.dead)
        player.addEffect("bad_omen", 1200, 0)
        manager.tryStartRaid(world, player)
        XCTAssertEqual(manager.raids.filter { $0.active }.count, 1,
                       "an ended, rewardless raid must not block the village's next raid")
    }

    func testRaidPlacementKeepsASampledDryPositionExactly() {
        let world = makeLakeWorld { _, _ in true }
        let placement = raidSpawnPlacement(world, "pillager", x: 3.25, z: -5.75,
                                           preferredY: world.surfaceY(3, -6))
        XCTAssertEqual(placement?.x, 3.25)
        XCTAssertEqual(placement?.y, 64)
        XCTAssertEqual(placement?.z, -5.75)
        let flooded = makeLakeWorld()
        XCTAssertNil(raidSpawnPlacement(flooded, "pillager", x: 3.25, z: -5.75,
                                        preferredY: flooded.surfaceY(3, -6)))
    }

    func testPatrolNextToALakeNeverPlacesAPillagerInWater() throws {
        // First patrol-roll seed that passes the 20% gate.
        var seed: UInt32 = 1
        while true {
            var probe = RandomX(seed)
            if probe.nextFloat() <= 0.2 { break }
            seed += 1
        }
        let world = makeLakeWorld(radius: 5, dry: padded)
        world.time = 12_000
        let player = Player(world: world)
        player.setPos(1.5, 64, 1.5)
        world.addEntity(player)
        var rng = RandomX(seed)
        tryPatrolSpawn(world, [player], &rng)
        let pillagers = world.entities.compactMap { $0 as? Pillager }
        XCTAssertFalse(pillagers.isEmpty, "the patrol still spawns beside the lake")
        XCTAssertEqual(pillagers.filter(\.isCaptain).count, 1)
        for pillager in pillagers {
            XCTAssertFalse(isInOrOnWater(world, pillager), "pillager in water at \(pillager.x),\(pillager.y),\(pillager.z)")
        }
    }

    func testPatrolOverOpenWaterSpawnsNothingButKeepsItsDrawCount() {
        var seed: UInt32 = 1
        while true {
            var probe = RandomX(seed)
            if probe.nextFloat() <= 0.2 { break }
            seed += 1
        }
        func run(_ world: World) -> [UInt32] {
            world.time = 12_000
            let player = Player(world: world)
            player.setPos(1.5, 64, 1.5)
            world.addEntity(player)
            var rng = RandomX(seed)
            tryPatrolSpawn(world, [player], &rng)
            let s = rng.stateWords
            return [s.0, s.1, s.2, s.3]
        }
        let flooded = makeLakeWorld(radius: 5)
        let dry = makeLakeWorld(radius: 5) { _, _ in true }
        let floodedState = run(flooded)
        XCTAssertFalse(flooded.entities.contains { $0 is Pillager })
        XCTAssertEqual(floodedState, run(dry), "skipped members consume exactly the same patrol draws")
        XCTAssertTrue(dry.entities.contains { $0 is Pillager })
    }

    // MARK: - generated structure occupants

    func testGeneratedLandOccupantIsNotMaterializedInWater() {
        let world = makeLakeWorld { x, _ in x < 0 }
        let wet = EntitySpec(mob: "villager", x: 4.5, y: 58, z: 4.5)
        let dry = EntitySpec(mob: "villager", x: -4.5, y: 64, z: 4.5)
        XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(wet, in: world))
        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(dry, in: world))
        // A villager authored on a non-replaceable cell (a door, a bed) keeps it.
        world.setBlock(-4, 64, 4, Int(cell(B.stone)))
        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(dry, in: world))
        // Aquatic and amphibious occupants (monument guardians) are unaffected.
        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(
            EntitySpec(mob: "elder_guardian", x: 4.5, y: 58, z: 4.5), in: world))
        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(
            EntitySpec(mob: "drowned", x: 4.5, y: 58, z: 4.5), in: world))
    }

    // MARK: - AI companion summon

    func testAISummonOverWaterRejectsLandMobsAndAdmitsAquaticOnes() throws {
        let world = makeLakeWorld(radius: 1)
        let player = Player(world: world)
        player.setPos(4.5, 70, 4.5)
        world.addEntity(player)
        // The cursor rests on the seabed; the placement cell above it is water.
        let hit = RaycastHit(x: 3, y: 57, z: 3, face: Dir.up, cell: Int(cell(B.sand)),
                             t: 1, px: 3.5, py: 58, pz: 3.5)
        for land in ["cow", "zombie"] {
            XCTAssertThrowsError(try executeAIAgentAction(
                AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: land),
                world: world, player: player, cursor: hit)) { error in
                    XCTAssertEqual(error as? AIAgentError, .entitySpawnFailed(land))
                }
        }
        XCTAssertFalse(world.entities.contains { ($0 as? Entity)?.type == "cow" || ($0 as? Entity)?.type == "zombie" })
        let result = try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 2, target: "cursor", entity: "cod"),
            world: world, player: player, cursor: hit)
        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(world.entities.compactMap { $0 as? Entity }.filter { $0.type == "cod" }.count, 2)
    }

    /// The updated doc comment on `canAIAgentSpawnEntity` claims "fish, squid
    /// and the aquatic dinosaurs still go into it": a prehistoric aquatic
    /// creature must be admitted over water and rejected on dry land, exactly
    /// like the ordinary aquatic mobs above.
    func testAISummonAdmitsAnAquaticMobIntoWaterButRejectsItOnLand() throws {
        let flooded = makeLakeWorld(radius: 1)
        let waterPlayer = Player(world: flooded)
        waterPlayer.setPos(4.5, 70, 4.5)
        flooded.addEntity(waterPlayer)
        let waterHit = RaycastHit(x: 3, y: 57, z: 3, face: Dir.up, cell: Int(cell(B.sand)),
                                  t: 1, px: 3.5, py: 58, pz: 3.5)
        let result = try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "squid"),
            world: flooded, player: waterPlayer, cursor: waterHit)
        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(flooded.entities.compactMap { $0 as? Entity }.filter { $0.type == "squid" }.count, 1)

        let dryWorld = makeLakeWorld(radius: 1) { _, _ in true }
        let landPlayer = Player(world: dryWorld)
        landPlayer.setPos(4.5, 70, 4.5)
        dryWorld.addEntity(landPlayer)
        let landHit = RaycastHit(x: 3, y: 63, z: 3, face: Dir.up, cell: Int(cell(B.grass_block)),
                                 t: 1, px: 3.5, py: 64, pz: 3.5)
        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "squid"),
            world: dryWorld, player: landPlayer, cursor: landHit)) { error in
                XCTAssertEqual(error as? AIAgentError, .entitySpawnFailed("squid"))
            }
        XCTAssertFalse(dryWorld.entities.contains { ($0 as? Entity)?.type == "squid" },
                       "an aquatic mob is never summoned onto dry land")

        // The companion now names prehistoric species too, under the same placement rule.
        XCTAssertEqual(resolveAIAgentEntityName("prehistoric.ichthyosaurus"), "prehistoric.ichthyosaurus")
        let deepWater = makeLakeWorld(radius: 2)
        let swimmerPlayer = Player(world: deepWater)
        swimmerPlayer.setPos(4.5, 70, 4.5)
        deepWater.addEntity(swimmerPlayer)
        _ = try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "ichthyosaur"),
            world: deepWater, player: swimmerPlayer, cursor: waterHit)
        XCTAssertEqual(deepWater.entities.compactMap { $0 as? Entity }.filter { $0.type == "prehistoric.ichthyosaurus" }.count, 1)
        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "ichthyosaurus"),
            world: dryWorld, player: landPlayer, cursor: landHit)) { error in
                XCTAssertEqual(error as? AIAgentError, .entitySpawnFailed("Ichthyosaurus"))
            }
        XCTAssertFalse(dryWorld.entities.contains { ($0 as? Entity)?.type == "prehistoric.ichthyosaurus" })
    }
}
