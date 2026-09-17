import Foundation
import XCTest
@testable import ElysiumCore

/// Contract tests for the opt-in Prehistoric Worlds feature. They deliberately
/// exercise source-owned profiles, entity persistence, native renderer model
/// registration, clearance, and LAN sanitization without assuming a resource
/// pack or an external asset pipeline exists.
final class PrehistoricWorldsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerBlockEntityHandlers()
    }

    private func makeWorld(_ preset: WorldPreset = .prehistoricLostWorld) -> World {
        let world = World(dim: .overworld, seed: 0xC0DE, generationSettings: .init(preset: preset))
        // Keep a dry, multi-chunk runway for large land/flying bodies while
        // preserving a deep central pool for the air-breathing marine tests.
        // Full prehistoric clearance deliberately refuses an unloaded edge.
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
                if cx == 0, cz == 0 {
                    // A deep, connected pool gives aquatic creature tests genuine volume
                    // rather than treating an isolated surface layer as a sea.
                    for z in 2...13 {
                        for x in 2...13 {
                            for y in 64...78 { chunk.set(x, y, z, cell(B.water)) }
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

    private func makeDeepAquaticWorld() -> World {
        let world = makeWorld()
        for z in 2...13 {
            for x in 2...13 {
                for y in 79...132 {
                    world.setBlock(x, y, z, Int(cell(B.water)))
                }
            }
        }
        return world
    }

    private func makeBlockedAquaticWorld() -> World {
        let world = World(
            dim: .overworld, seed: 0xB10C,
            generationSettings: .init(preset: .prehistoricAncientSeas)
        )
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .lit
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, 62, z, cell(B.stone))
                chunk.set(x, 63, z, cell(B.grass_block))
            }
        }
        // The left column is deliberately sealed. The nearby right pool has
        // a real open surface but cannot be reached through the solid divider.
        for z in 4...12 {
            for x in 2...4 {
                for y in 64...132 { chunk.set(x, y, z, cell(B.water)) }
                chunk.set(x, 133, z, cell(B.stone))
            }
            for x in 6...13 {
                for y in 64...78 { chunk.set(x, y, z, cell(B.water)) }
            }
        }
        for z in 0..<CHUNK_W {
            for y in 64...140 { chunk.set(5, y, z, cell(B.stone)) }
        }
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return world
    }

    private func makeLateralBreathingExitWorld() -> World {
        let world = World(
            dim: .overworld, seed: 0x1A7E,
            generationSettings: .init(preset: .prehistoricAncientSeas)
        )
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .lit
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, 62, z, cell(B.stone))
            }
        }
        // The current column is roofed, so it has no vertical breathing
        // route. A three-wide, two-block-deep lateral tunnel reaches an open
        // water exit. At its final upper-water voxel an ichthyosaur has water
        // around its lower body and air at its head—the exact legal terminal
        // pose that must not be mistaken for an intermediate water-only node.
        for z in 6...10 {
            for x in 2...13 {
                chunk.set(x, 63, z, cell(B.water))
                chunk.set(x, 64, z, cell(B.water))
                if x <= 5 { chunk.set(x, 65, z, cell(B.stone)) }
            }
        }
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return world
    }

    func testVersionedProfilesCoverTheCanonicalRosterWithoutChangingNormalPreset() {
        XCTAssertEqual(PrehistoricCreatureDefinition.allIDs, PrehistoricWorldProfile.allCreatureIDs)
        XCTAssertEqual(PrehistoricCreatureDefinition.all.count, 36)
        XCTAssertEqual(Set(PrehistoricCreatureDefinition.allIDs).count, 36)
        XCTAssertEqual(PrehistoricWorldProfile.lostWorld.creatureIDs, PrehistoricWorldProfile.allCreatureIDs)
        for profile in PrehistoricWorldProfile.allCases {
            XCTAssertEqual(profile.preset.prehistoricProfile, profile)
            XCTAssertTrue(profile.contentIdentity.hasSuffix(".v1"))
            XCTAssertFalse(profile.creatureIDs.isEmpty)
            XCTAssertTrue(profile.creatureIDs.allSatisfy { PrehistoricCreatureDefinition.named($0) != nil })
        }
        XCTAssertFalse(WorldPreset.normal.isPrehistoric)
        XCTAssertEqual(WorldGenerationSettings.normal.cacheIdentity,
                       "minecraft:normal|plains|dungeons:2|villages:3")
        XCTAssertEqual(normalizedWorldPreset("Lost World"), .prehistoricLostWorld)
        XCTAssertEqual(normalizedWorldPreset("elysium:prehistoric_ancient_seas_v1"), .prehistoricAncientSeas)
        XCTAssertTrue(WorldPreset.normalCycle.contains(.prehistoricLostWorld))
    }

    func testPrehistoricProfileReplacesOnlyPassiveSpawnTablesAndDisablesVillagePlans() {
        let lostLand = prehistoricSpawnEntries(profile: .lostWorld, category: "creature")
        let lostAir = prehistoricSpawnEntries(profile: .lostWorld, category: "ambient")
        let lostWater = prehistoricSpawnEntries(profile: .lostWorld, category: "water")
        XCTAssertEqual(lostLand.map(\.mob), PrehistoricWorldProfile.landCreatureIDs)
        XCTAssertEqual(lostAir.map(\.mob), PrehistoricWorldProfile.airCreatureIDs)
        XCTAssertEqual(Array(lostWater.prefix(PrehistoricWorldProfile.aquaticCreatureIDs.count).map(\.mob)),
                       PrehistoricWorldProfile.aquaticCreatureIDs)
        XCTAssertEqual(lostWater.suffix(3).map(\.mob), ["cod", "salmon", "tropical_fish"])
        XCTAssertTrue(prehistoricSpawnEntries(profile: .ancientSeas, category: "creature").isEmpty)
        XCTAssertTrue(prehistoricSpawnEntries(profile: .lostWorld, category: "monster").isEmpty)
        XCTAssertTrue(WorldPreset.prehistoricLostWorld.supportsDungeonDensity)
        XCTAssertFalse(WorldPreset.prehistoricLostWorld.supportsVillageDensity)
        XCTAssertFalse(structureDefinitionsForGeneration(
            dim: .overworld, settings: .init(preset: .prehistoricLostWorld)
        ).contains { $0.id == "village" })
        XCTAssertTrue(structureDefinitionsForGeneration(
            dim: .overworld, settings: .normal
        ).contains { $0.id == "village" })
    }

    func testPrehistoricProfilesSuppressModernPatrolSchedulingOnly() {
        let normal = World(dim: .overworld, seed: 1, generationSettings: .normal)
        let prehistoric = World(
            dim: .overworld, seed: 1,
            generationSettings: .init(preset: .prehistoricLostWorld)
        )
        normal.time = 1_200
        prehistoric.time = 1_200

        XCTAssertTrue(GameCore.shouldTryPatrolSpawn(in: normal, dimension: .overworld))
        XCTAssertFalse(GameCore.shouldTryPatrolSpawn(in: prehistoric, dimension: .overworld))
        XCTAssertTrue(GameCore.shouldRunRaidEvents(in: normal))
        XCTAssertFalse(GameCore.shouldRunRaidEvents(in: prehistoric))
        normal.time = 1_199
        XCTAssertFalse(GameCore.shouldTryPatrolSpawn(in: normal, dimension: .overworld))
    }

    func testPrehistoricProfilesDefensivelyRejectDirectModernRaidAndPatrolCalls() {
        let world = makeWorld(.prehistoricLostWorld)
        world.time = 12_000
        world.difficulty = 2
        let player = Player(world: world)
        player.setPos(24.5, 64, 8.5)
        player.addEffect("bad_omen", 1_200)
        world.addEntity(player)
        let villager = Villager(world: world)
        villager.setPos(25.5, 64, 8.5)
        world.addEntity(villager)

        let manager = RaidManager()
        let importedRaid = Raid(world: world, cx: 24, cy: 64, cz: 8, totalWaves: 3)
        importedRaid.cooldown = 0
        manager.raids = [importedRaid]
        manager.tryStartRaid(world, player)
        manager.tick(world)
        XCTAssertEqual(manager.raids.count, 1)
        XCTAssertEqual(importedRaid.wave, 0)
        XCTAssertEqual(importedRaid.cooldown, 0)
        XCTAssertTrue(player.hasEffect("bad_omen"), "profile guard must run before Bad Omen is consumed")

        var patrolRNG = RandomX(0x51A7)
        let patrolState = patrolRNG.stateWords
        tryPatrolSpawn(world, [player], &patrolRNG)
        XCTAssertEqual(patrolRNG.stateWords.0, patrolState.0)
        XCTAssertEqual(patrolRNG.stateWords.1, patrolState.1)
        XCTAssertEqual(patrolRNG.stateWords.2, patrolState.2)
        XCTAssertEqual(patrolRNG.stateWords.3, patrolState.3)
    }

    func testPrehistoricProfilesBlockLegacyStructureOccupantsAndSpawnersBeforeSideEffects() throws {
        let prehistoric = makeWorld(.prehistoricLostWorld)
        let normal = makeWorld(.normal)
        for mob in ["zombie_villager", "witch", "drowned", "elder_guardian", "vindicator", "cat"] {
            let spec = EntitySpec(mob: mob, x: 24.5, y: 64, z: 8.5)
            XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(spec, in: prehistoric),
                           "a prehistoric profile must reject the legacy structure occupant \(mob)")
            XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(spec, in: normal),
                          "the profile boundary must not alter normal-world landmark occupants")
        }
        let curated = EntitySpec(mob: "prehistoric.triceratops", x: 24.5, y: 64, z: 8.5)
        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(curated, in: prehistoric))

        prehistoric.difficulty = 2
        let player = Player(world: prehistoric)
        player.setPos(24.5, 64, 8.5)
        prehistoric.addEntity(player)
        let tickSpawner = try XCTUnwrap(beTickHandlers["spawner"])
        defer { resetGameRng(0x6A57) }
        for mob in ["zombie", "cave_spider", "silverfish", "blaze"] {
            let spawner = makeSpawnerBE(24, 64, 8, mob)
            spawner.delay = 0
            resetGameRng(0x51A7_E100)
            let rngBefore = gameRng.stateWords

            tickSpawner(prehistoric, spawner)

            XCTAssertEqual(spawner.delay, 0,
                           "the prehistoric boundary must run before a \(mob) spawner mutates its timer")
            XCTAssertEqual(gameRng.stateWords.0, rngBefore.0)
            XCTAssertEqual(gameRng.stateWords.1, rngBefore.1)
            XCTAssertEqual(gameRng.stateWords.2, rngBefore.2)
            XCTAssertEqual(gameRng.stateWords.3, rngBefore.3)
            XCTAssertFalse(prehistoric.entities.contains { ($0 as? Entity)?.type == mob },
                           "the prehistoric boundary must reject the legacy \(mob) spawner")
        }
    }

    func testEveryCreatureRegistersAnOriginalNativeModelWithinRendererBudget() {
        XCTAssertEqual(Array(entityTypes().suffix(36)), PrehistoricCreatureDefinition.allIDs)
        XCTAssertEqual(prehistoricModelIDs, PrehistoricCreatureDefinition.allIDs)
        XCTAssertTrue(prehistoricModelValidationErrors().isEmpty,
                      prehistoricModelValidationErrors().joined(separator: "; "))
        let triceratops = getModel("prehistoric.triceratops")
        let pteranodon = getModel("prehistoric.pteranodon")
        let ichthyosaurus = getModel("prehistoric.ichthyosaurus")
        XCTAssertGreaterThanOrEqual(triceratops.parts.first { $0.name == "head" }?.boxes.count ?? 0, 4)
        XCTAssertTrue(triceratops.parts.contains { $0.name == "frill" })
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "crest" })
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "wingR" })
        XCTAssertTrue(pteranodon.parts.contains { $0.name == "wingL" })
        XCTAssertTrue(ichthyosaurus.parts.contains { $0.name == "tail" })
        XCTAssertTrue(ichthyosaurus.parts.contains { $0.name == "dorsalFin" })
        XCTAssertTrue(ichthyosaurus.parts.first { $0.name == "tail" }?.boxes.contains { $0.h > $0.d } ?? false,
                      "the native ichthyosaur must not silently reuse the dolphin rig")
    }

    func testCreatureActionPersistenceAndBoundedBodyClearance() throws {
        let world = makeWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.triceratops"))
        let creature = PrehistoricCreature(world: world, definition: definition)
        creature.setPos(24.5, 64, 8.5)
        creature.data.prehistoricAction = PrehistoricAction.charge.rawValue
        creature.data.prehistoricActionTicks = 91
        let encoded = creature.save()
        let restored = try XCTUnwrap(loadEntity(world, encoded) as? PrehistoricCreature)
        XCTAssertEqual(restored.type, creature.type)
        XCTAssertEqual(restored.data.prehistoricAction, PrehistoricAction.charge.rawValue)
        XCTAssertEqual(restored.data.prehistoricActionTicks, 91)
        XCTAssertTrue(prehistoricHasClearance(world, definition: definition, x: 24, y: 64, z: 8, requireGround: true))
        world.setBlock(24, 65, 8, Int(cell(B.stone)))
        XCTAssertFalse(restored.hasPathClearance(atX: 24, y: 64, z: 8),
                       "a large herbivore must reject a low body-volume node")
    }

    func testGeneratedPrehistoricSpecsRequireFullLoadedWorldClearance() throws {
        let world = makeWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.triceratops"))
        let admitted = EntitySpec(mob: definition.id, x: 24.5, y: 64, z: 8.5)
        let unloadedEdge = EntitySpec(mob: definition.id, x: 1.5, y: 64, z: 1.5)

        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(admitted, in: world))
        XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(unloadedEdge, in: world),
                       "a bootstrap spec must not phase a large creature across an unloaded chunk edge")
    }

    func testAquaticNaturalSpawnRequiresConnectedOpenWaterBeyondOneBodyPuddle() throws {
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.ichthyosaurus"))
        let openWater = makeWorld()
        XCTAssertTrue(prehistoricAquaticNaturalSpawnHasOpenWaterAdmission(
            openWater, definition: definition, x: 8, y: 69, z: 8
        ))
        var openWaterRNG = RandomX(9)
        XCTAssertTrue(canSpawnAt(openWater, definition.id, "water", 8, 69, 8, &openWaterRNG))

        let isolatedPuddle = makeWorld()
        for z in 7...9 {
            for x in 24...26 {
                for y in 64...66 {
                    isolatedPuddle.setBlock(x, y, z, Int(cell(B.water)))
                }
            }
        }
        XCTAssertFalse(prehistoricAquaticNaturalSpawnHasOpenWaterAdmission(
            isolatedPuddle, definition: definition, x: 25, y: 64, z: 8
        ))
        var puddleRNG = RandomX(9)
        XCTAssertFalse(canSpawnAt(isolatedPuddle, definition.id, "water", 25, 64, 8, &puddleRNG),
                       "a body-clear but isolated puddle is not natural-spawn habitat")
    }

    func testPrehistoricConstructionAndLoadDoNotAdvanceSharedGameplayRNG() throws {
        let world = makeWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.triceratops"))
        defer { resetGameRng(0x6A57) }

        resetGameRng(0x51A7_E001)
        let stateBeforeConstruction = gameRng.stateWords
        var constructionReference = RandomX(stateWords: stateBeforeConstruction)
        let expectedAfterConstruction = constructionReference.next()
        let creature = PrehistoricCreature(world: world, definition: definition)
        XCTAssertEqual(gameRng.stateWords.0, stateBeforeConstruction.0)
        XCTAssertEqual(gameRng.stateWords.1, stateBeforeConstruction.1)
        XCTAssertEqual(gameRng.stateWords.2, stateBeforeConstruction.2)
        XCTAssertEqual(gameRng.stateWords.3, stateBeforeConstruction.3)
        XCTAssertEqual(gameRng.next(), expectedAfterConstruction)

        let saved = creature.save()
        resetGameRng(0x51A7_E002)
        let stateBeforeLoad = gameRng.stateWords
        var loadReference = RandomX(stateWords: stateBeforeLoad)
        let expectedAfterLoad = loadReference.next()
        _ = try XCTUnwrap(loadEntity(world, saved) as? PrehistoricCreature)
        XCTAssertEqual(gameRng.stateWords.0, stateBeforeLoad.0)
        XCTAssertEqual(gameRng.stateWords.1, stateBeforeLoad.1)
        XCTAssertEqual(gameRng.stateWords.2, stateBeforeLoad.2)
        XCTAssertEqual(gameRng.stateWords.3, stateBeforeLoad.3)
        XCTAssertEqual(gameRng.next(), expectedAfterLoad)
    }

    func testPrehistoricReloadPreservesAmbientCooldownAndControllerState() throws {
        let cases: [(String, Double, Double, Double)] = [
            ("prehistoric.triceratops", 24.5, 64, 8.5),
            ("prehistoric.pteranodon", 24.5, 65, 8.5),
            ("prehistoric.ichthyosaurus", 8.5, 69, 8.5),
        ]
        for (id, x, y, z) in cases {
            let world = makeWorld()
            let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named(id))
            let source = PrehistoricCreature(world: world, definition: definition)
            source.setPos(x, y, z)
            source.rng = RandomX(0xA11D_5100)
            source.ambientSoundTimer = 37
            // Tick once so this is a normal in-flight save: the old code
            // persisted the controller words at tick exit but not this timer.
            source.tick()

            let restored = try XCTUnwrap(loadEntity(world, source.save()) as? PrehistoricCreature)
            XCTAssertEqual(restored.ambientSoundTimer, source.ambientSoundTimer, id)
            XCTAssertEqual(restored.data.prehistoricAmbientSoundTimer, source.ambientSoundTimer, id)
            XCTAssertEqual(restored.rng.stateWords.0, source.rng.stateWords.0, id)
            XCTAssertEqual(restored.rng.stateWords.1, source.rng.stateWords.1, id)
            XCTAssertEqual(restored.rng.stateWords.2, source.rng.stateWords.2, id)
            XCTAssertEqual(restored.rng.stateWords.3, source.rng.stateWords.3, id)
        }

        // The one-tick boundary consumes the two normal ambient draws on land
        // creatures. Save its post-event state exactly, then prove corrupted
        // cooldowns cannot create unbounded delayed-audio state on load.
        let world = makeWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.triceratops"))
        let source = PrehistoricCreature(world: world, definition: definition)
        source.setPos(24.5, 64, 8.5)
        source.rng = RandomX(0xA11D_5101)
        source.ambientSoundTimer = 1
        source.tick()
        XCTAssertTrue((80...239).contains(source.ambientSoundTimer))
        let saved = source.save()
        let restored = try XCTUnwrap(loadEntity(world, saved) as? PrehistoricCreature)
        XCTAssertEqual(restored.ambientSoundTimer, source.ambientSoundTimer)
        XCTAssertEqual(restored.rng.stateWords.0, source.rng.stateWords.0)
        XCTAssertEqual(restored.rng.stateWords.1, source.rng.stateWords.1)
        XCTAssertEqual(restored.rng.stateWords.2, source.rng.stateWords.2)
        XCTAssertEqual(restored.rng.stateWords.3, source.rng.stateWords.3)

        var tooHigh = saved
        var highData = try XCTUnwrap(tooHigh["data"] as? [String: Any])
        highData["prehistoricAmbientSoundTimer"] = 99_999
        tooHigh["data"] = highData
        let highRestored = try XCTUnwrap(loadEntity(world, tooHigh) as? PrehistoricCreature)
        XCTAssertEqual(highRestored.ambientSoundTimer, 300)

        var negative = saved
        var negativeData = try XCTUnwrap(negative["data"] as? [String: Any])
        negativeData["prehistoricAmbientSoundTimer"] = -1
        negative["data"] = negativeData
        let negativeRestored = try XCTUnwrap(loadEntity(world, negative) as? PrehistoricCreature)
        XCTAssertEqual(negativeRestored.ambientSoundTimer, 0)
    }

    func testLandFlightAndAquaticFamiliesStayFiniteAndUseClosedActions() throws {
        let world = makeWorld()
        let cases: [(String, Double, Double, Double)] = [
            ("prehistoric.triceratops", 24.5, 64, 8.5),
            ("prehistoric.pteranodon", 24.5, 65, 8.5),
            ("prehistoric.ichthyosaurus", 8.5, 69, 8.5),
        ]
        for (id, x, y, z) in cases {
            let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named(id))
            let creature = PrehistoricCreature(world: world, definition: definition)
            creature.setPos(x, y, z)
            creature.rng = RandomX(42)
            creature.persistent = true
            for _ in 0..<80 { creature.tick() }
            XCTAssertTrue(creature.x.isFinite && creature.y.isFinite && creature.z.isFinite, id)
            XCTAssertNotNil(PrehistoricAction(rawValue: creature.data.prehistoricAction ?? ""), id)
            if definition.medium == .aquatic {
                XCTAssertTrue(creature.inWater || creature.data.prehistoricAction == PrehistoricAction.stranded.rawValue, id)
            }
        }
    }

    func testAquaticReptileUsesAReachableAirSurfaceAndPersistsItsReserve() throws {
        let world = makeWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.ichthyosaurus"))
        let swimmer = PrehistoricCreature(world: world, definition: definition)
        swimmer.setPos(8.5, 69, 8.5)
        swimmer.rng = RandomX(17)
        swimmer.airSupply = 120
        XCTAssertFalse(swimmer.breathesWater)
        XCTAssertFalse(swimmer.breathesWaterOnly)

        var sawSurface = false
        var sawDive = false
        for _ in 0..<360 {
            swimmer.tick()
            sawSurface = sawSurface || swimmer.action == .surface
            sawDive = sawDive || swimmer.action == .dive
        }
        XCTAssertTrue(sawSurface, "the swimmer must target an actual air surface before its reserve is exhausted")
        XCTAssertTrue(sawDive, "a completed surface breath must return the swimmer to depth")
        XCTAssertGreaterThan(swimmer.airSupply, 120, "surface breathing must replenish the ordinary air reserve")
        XCTAssertEqual(swimmer.data.prehistoricAirSupply, swimmer.airSupply)

        let restored = try XCTUnwrap(loadEntity(world, swimmer.save()) as? PrehistoricCreature)
        XCTAssertEqual(restored.airSupply, swimmer.airSupply)
        XCTAssertEqual(restored.data.prehistoricAirSupply, swimmer.airSupply)
    }

    func testDeepConnectedWaterColumnStartsEarlyAndBreathesWithoutDrowning() throws {
        let world = makeDeepAquaticWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.ichthyosaurus"))
        let swimmer = PrehistoricCreature(world: world, definition: definition)
        swimmer.setPos(8.5, 68, 8.5)
        swimmer.rng = RandomX(29)
        swimmer.airSupply = 300

        var sawSurface = false
        var sawDive = false
        var sawSurfaceAfterDive = false
        var rediveStartY: Double?
        var lowestRediveY = Double.greatestFiniteMagnitude
        var underwaterTicksAfterRedive = 0
        for _ in 0..<1_400 {
            swimmer.tick()
            if swimmer.action == .surface {
                if sawDive { sawSurfaceAfterDive = true; break }
                sawSurface = true
            }
            if sawSurface, swimmer.action == .dive, !sawDive {
                sawDive = true
                rediveStartY = swimmer.y
            }
            if sawDive, swimmer.underwater {
                underwaterTicksAfterRedive += 1
                lowestRediveY = min(lowestRediveY, swimmer.y)
            }
        }

        XCTAssertTrue(sawSurface, "a 64-block connected column must trigger a proactive surface route")
        XCTAssertTrue(sawDive, "the swimmer must reach open air, replenish ordinary air, and return to depth")
        XCTAssertTrue(sawSurfaceAfterDive,
                      "a deep swimmer must retain enough ordinary air to surface again after re-diving")
        XCTAssertGreaterThan(underwaterTicksAfterRedive, 8,
                             "re-dive must spend real time underwater, not immediately reuse a stale route reserve")
        XCTAssertGreaterThan((rediveStartY ?? swimmer.y) - lowestRediveY, 0.5,
                             "re-dive must make material downward progress before its next breathing route")
        XCTAssertEqual(swimmer.health, swimmer.maxHealth, "a reachable deep surface must not cause drowning")
    }

    func testDisconnectedSurfaceBehindSolidDividerIsNeverUsedAsBreathingRoute() throws {
        let world = makeBlockedAquaticWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.ichthyosaurus"))
        let swimmer = PrehistoricCreature(world: world, definition: definition)
        swimmer.setPos(3.5, 70, 8.5)
        swimmer.rng = RandomX(31)
        swimmer.airSupply = 120

        var sawSurface = false
        for _ in 0..<120 {
            swimmer.tick()
            sawSurface = sawSurface || swimmer.action == .surface
        }

        XCTAssertFalse(sawSurface, "a disconnected pool behind a solid divider is not a legal breath target")
        XCTAssertLessThan(swimmer.x, 5, "the controller must not phase through the divider to that surface")
    }

    func testLateralOpenWaterExitAdmitsBreathingEndpointBeforeWaterOnlyNodes() throws {
        let world = makeLateralBreathingExitWorld()
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.ichthyosaurus"))

        XCTAssertTrue(prehistoricAquaticNaturalSpawnHasOpenWaterAdmission(
            world, definition: definition, x: 3, y: 63, z: 8
        ), "the connected lateral exit is open-water habitat, even though its terminal head is in air")
        var spawnRNG = RandomX(0x1A7E)
        XCTAssertTrue(canSpawnAt(world, definition.id, "water", 3, 63, 8, &spawnRNG),
                      "natural spawn admission must share the controller's endpoint definition")

        let swimmer = PrehistoricCreature(world: world, definition: definition)
        swimmer.setPos(3.5, 63, 8.5)
        swimmer.rng = RandomX(0x1A7E)
        swimmer.airSupply = 120

        var reachedAir = false
        for _ in 0..<240 {
            swimmer.tick()
            if swimmer.action == .surface, !swimmer.underwater, swimmer.x >= 6.5 {
                reachedAir = true
                break
            }
        }
        XCTAssertTrue(reachedAir,
                      "the swimmer must use the connected lateral exit instead of treating the head-air terminal as blocked")
        XCTAssertFalse(swimmer.dead)
        XCTAssertGreaterThanOrEqual(swimmer.x, 6.5)
    }

    func testLanPreservesProfileAndSanitizesPrehistoricActionState() {
        let summary = LANWorldSummary(
            worldID: "lost-world", worldName: "Lost World", seed: 1, gameMode: GameMode.survival,
            difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 1,
            worldPreset: "Lost World"
        )
        XCTAssertEqual(summary.worldPreset, WorldPreset.prehistoricLostWorld.rawValue)
        XCTAssertEqual(summary.prehistoricContentIdentity, PrehistoricWorldProfile.lostWorld.contentIdentity)
        XCTAssertEqual(summary.compatibleWorldPreset, .prehistoricLostWorld)
        XCTAssertEqual(lanClientResumeKey(for: summary),
                       "lost-world#1#\(PrehistoricWorldProfile.lostWorld.contentIdentity)")
        let encodedSummary = try? JSONEncoder().encode(summary)
        let decodedSummary = encodedSummary.flatMap { try? JSONDecoder().decode(LANWorldSummary.self, from: $0) }
        XCTAssertEqual(decodedSummary?.worldPreset, WorldPreset.prehistoricLostWorld.rawValue)
        XCTAssertEqual(decodedSummary?.prehistoricContentIdentity,
                       PrehistoricWorldProfile.lostWorld.contentIdentity)

        let hostile = LANEntitySnapshot(
            entityID: 77, type: "prehistoric.ichthyosaurus", x: 8.5, y: 64, z: 8.5,
            yaw: 0, pitch: 0, health: 20, dead: false,
            prehistoricAction: "not-a-real-action", prehistoricActionTicks: 99_999,
            prehistoricAirSupply: 99_999
        )
        XCTAssertEqual(hostile.type, "prehistoric.ichthyosaurus")
        XCTAssertEqual(hostile.prehistoricAction, PrehistoricAction.idle.rawValue)
        XCTAssertEqual(hostile.prehistoricActionTicks, 1_200)
        XCTAssertEqual(hostile.prehistoricAirSupply, 300)

        let host = makeWorld()
        let source = PrehistoricCreature(world: host, definition: PrehistoricCreatureDefinition.named("prehistoric.pteranodon")!)
        source.setPos(6.5, 68, 6.5)
        source.data.prehistoricAction = PrehistoricAction.takeoff.rawValue
        source.data.prehistoricActionTicks = 37
        host.addEntity(source)
        let snapshot = try! XCTUnwrap(makeLANEntitySnapshots(in: host).first { $0.entityID == source.id })
        let client = makeWorld()
        let report = applyLANEntitySnapshots([snapshot], to: client)
        XCTAssertEqual(report.appliedEntitySnapshots, 1)
        let mirrored = try! XCTUnwrap(client.entities.compactMap { $0 as? PrehistoricCreature }.first)
        XCTAssertEqual(mirrored.type, source.type)
        XCTAssertEqual(mirrored.data.prehistoricAction, PrehistoricAction.takeoff.rawValue)
        XCTAssertEqual(mirrored.data.prehistoricActionTicks, 37)

        let aquaticSource = PrehistoricCreature(world: host, definition: PrehistoricCreatureDefinition.named("prehistoric.ichthyosaurus")!)
        aquaticSource.setPos(8.5, 69, 8.5)
        aquaticSource.data.prehistoricAction = PrehistoricAction.surface.rawValue
        aquaticSource.data.prehistoricActionTicks = 81
        aquaticSource.data.prehistoricAirSupply = 119
        host.addEntity(aquaticSource)
        let aquaticSnapshot = try! XCTUnwrap(makeLANEntitySnapshots(in: host).first { $0.entityID == aquaticSource.id })
        XCTAssertEqual(aquaticSnapshot.prehistoricAirSupply, 119)
        _ = applyLANEntitySnapshots([aquaticSnapshot], to: client)
        let aquaticMirror = try! XCTUnwrap(client.entities.compactMap { $0 as? PrehistoricCreature }
            .first { $0.type == aquaticSource.type })
        XCTAssertEqual(aquaticMirror.data.prehistoricAirSupply, 119)
        XCTAssertEqual(aquaticMirror.airSupply, 119)
    }

    @MainActor
    func testSaveAndLANRejectUnknownOrMismatchedPrehistoricContent() throws {
        let record = WorldRecord(
            id: "future-profile", name: "Future Profile", seed: 7,
            gameMode: GameMode.survival, difficulty: 2,
            worldPreset: .prehistoricLostWorld
        )
        var futureSave = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(record)) as? [String: Any])
        futureSave["worldPreset"] = "elysium:prehistoric_lost_world_v2"
        let futureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: futureSaveData))
        futureSave["worldPreset"] = "other:prehistoric_lost_world_v2"
        let foreignFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: foreignFutureSaveData),
                             "a foreign namespace must not launder a future prehistoric profile into normal")
        futureSave["worldPreset"] = "other:prehistoric lost world v2"
        let whitespaceFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: whitespaceFutureSaveData),
                             "whitespace aliases must not launder a future prehistoric profile into normal")
        futureSave["worldPreset"] = "other:prehistoric.lost_world_v2"
        let punctuationFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: punctuationFutureSaveData),
                             "punctuation aliases must not launder a future prehistoric profile into normal")
        futureSave["worldPreset"] = "elysium:lost.world.v2"
        let aliasedElysiumFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: aliasedElysiumFutureSaveData))
        futureSave["worldPreset"] = "other:prehistoricLostWorldV2"
        let camelCaseFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: camelCaseFutureSaveData),
                             "a camel-cased future prehistoric profile must not fall back to normal")
        futureSave["worldPreset"] = "elysium:lostWorldV2"
        let camelCaseElysiumFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: camelCaseElysiumFutureSaveData))
        futureSave["worldPreset"] = "other:pre.historic_lost_world_v2"
        let splitMarkerFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: splitMarkerFutureSaveData),
                             "a split future prehistoric marker must not fall back to normal")

        let summary = LANWorldSummary(
            worldID: "future-profile", worldName: "Future Profile", seed: 7,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 1, worldPreset: WorldPreset.prehistoricLostWorld.rawValue
        )
        let directFutureSummary = LANWorldSummary(
            worldID: "future-profile", worldName: "Future Profile", seed: 7,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 1, worldPreset: "elysium:prehistoric_lost_world_v2"
        )
        XCTAssertEqual(directFutureSummary.worldPreset, "elysium:prehistoric_lost_world_v2")
        XCTAssertNil(directFutureSummary.compatibleWorldPreset)
        let directForeignFutureSummary = LANWorldSummary(
            worldID: "future-profile", worldName: "Future Profile", seed: 7,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 1, worldPreset: "other:prehistoric_lost_world_v2"
        )
        XCTAssertEqual(directForeignFutureSummary.worldPreset, "other:prehistoric_lost_world_v2")
        XCTAssertNil(directForeignFutureSummary.compatibleWorldPreset)
        let encodedSummary = try JSONEncoder().encode(summary)
        var mismatchedSummary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedSummary) as? [String: Any])
        mismatchedSummary["prehistoricContentIdentity"] = "elysium.prehistoric.lostWorld.v999"
        let mismatchedSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: mismatchedSummaryData))

        mismatchedSummary["worldPreset"] = "elysium:prehistoric_lost_world_v2"
        mismatchedSummary["prehistoricContentIdentity"] = "elysium.prehistoric.lostWorld.v2"
        let unknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: unknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:prehistoric_lost_world_v2"
        let foreignUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: foreignUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:prehistoric lost world v2"
        let whitespaceUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: whitespaceUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other/prehistoric/lost_world_v2"
        let punctuationUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: punctuationUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "foreign:elysium:prehistoric_lost_world_v2"
        let nestedUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: nestedUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:prehistoricLostWorldV2"
        let camelCaseUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: camelCaseUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "elysium:lostWorldV2"
        let camelCaseElysiumUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: camelCaseElysiumUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:pre.historic_lost_world_v2"
        let splitMarkerUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: splitMarkerUnknownSummaryData))

        var inProcessMismatch = summary
        inProcessMismatch.prehistoricContentIdentity = "elysium.prehistoric.lostWorld.v999"
        XCTAssertNil(inProcessMismatch.compatibleWorldPreset)
        let session = LANMultiplayerClientSession()
        let report = session.apply(LANReplicationBatch(
            tick: 1, fullSnapshot: true, world: inProcessMismatch
        ))
        XCTAssertEqual(report.ignoredInvalidWorldSummary, 1)
        XCTAssertNil(session.worldSummary)

        let game = PersistenceTestSupport.makeGame(owner: self, label: "invalid-prehistoric-lan")
        game.enterLANClientWorld(inProcessMismatch)
        XCTAssertFalse(game.hasWorld())
    }

    func testLegacyNormalWorldsKeepNormalFallbackAndResumeKey() throws {
        let legacyPayload = """
        {"worldID":"normal-host","worldName":"Normal Host","seed":9,"gameMode":0,"difficulty":2,"dimension":0,"playerCount":1}
        """.data(using: .utf8)!
        let normal = try JSONDecoder().decode(LANWorldSummary.self, from: legacyPayload)

        XCTAssertEqual(normal.worldPreset, WorldPreset.normal.rawValue)
        XCTAssertNil(normal.prehistoricContentIdentity)
        XCTAssertEqual(normal.compatibleWorldPreset, .normal)
        XCTAssertEqual(lanClientResumeKey(for: normal), "normal-host#9")
    }
}
