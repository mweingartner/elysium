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
        XCTAssertEqual(PrehistoricWorldProfile.lostWorldV1.creatureIDs,
                       PrehistoricWorldProfile.allCreatureIDs)
        XCTAssertEqual(PrehistoricWorldProfile.lostWorldV2.creatureIDs,
                       PrehistoricWorldProfile.allCreatureIDs)
        XCTAssertEqual(PrehistoricWorldProfile.lostWorld.creatureIDs, PrehistoricWorldProfile.allCreatureIDs)
        XCTAssertEqual(PrehistoricWorldProfile.currentContentVersion, 3)
        for profile in PrehistoricWorldProfile.allCases {
            XCTAssertEqual(profile.preset.prehistoricProfile, profile)
            XCTAssertTrue(profile.contentIdentity.hasSuffix(".v\(profile.contentVersion)"))
            XCTAssertEqual(profile.supportsPredatorHerdCombat,
                           profile.contentVersion >= 2)
            XCTAssertEqual(profile.supportsStarterShelter,
                           profile.contentVersion >= 2)
            XCTAssertEqual(profile.supportsVolcanicTerrain, profile.contentVersion == 3)
            XCTAssertFalse(profile.creatureIDs.isEmpty)
            XCTAssertTrue(profile.creatureIDs.allSatisfy { PrehistoricCreatureDefinition.named($0) != nil })
        }
        XCTAssertEqual(PrehistoricWorldProfile.lostWorldV1.contentIdentity,
                       "elysium.prehistoric.lostWorld.v1")
        XCTAssertEqual(PrehistoricWorldProfile.lostWorldV2.contentIdentity,
                       "elysium.prehistoric.lostWorld.v2")
        XCTAssertEqual(PrehistoricWorldProfile.lostWorld.contentIdentity,
                       "elysium.prehistoric.lostWorld.v3")
        XCTAssertEqual(PrehistoricWorldProfile.lostWorldV1.creatureIDs,
                       PrehistoricWorldProfile.lostWorld.creatureIDs,
                       "the version bump must not reorder or alter the roster")
        XCTAssertFalse(WorldPreset.normal.isPrehistoric)
        XCTAssertEqual(WorldGenerationSettings.normal.cacheIdentity,
                       "minecraft:normal|plains|dungeons:2|villages:3")
        XCTAssertEqual(normalizedWorldPreset("Lost World"), .prehistoricLostWorld)
        XCTAssertEqual(normalizedWorldPreset("elysium:prehistoric_ancient_seas_v1"), .prehistoricAncientSeas)
        XCTAssertEqual(normalizedWorldPreset("elysium:prehistoric_lost_world_v2"),
                       .prehistoricLostWorldV2)
        XCTAssertEqual(normalizedWorldPreset("elysium:prehistoric_lost_world_v3"),
                       .prehistoricLostWorldV3)
        XCTAssertNotEqual(WorldGenerationSettings(preset: .prehistoricLostWorld).cacheIdentity,
                          WorldGenerationSettings(preset: .prehistoricLostWorldV2).cacheIdentity)
        XCTAssertFalse(WorldPreset.prehistoricLostWorld.supportsPredatorHerdCombat)
        XCTAssertTrue(WorldPreset.prehistoricLostWorldV2.supportsPredatorHerdCombat)
        XCTAssertFalse(WorldPreset.prehistoricLostWorld.supportsStarterShelter)
        XCTAssertTrue(WorldPreset.prehistoricLostWorldV2.supportsStarterShelter)
        XCTAssertTrue(WorldPreset.prehistoricLostWorldV3.supportsPredatorHerdCombat)
        XCTAssertTrue(WorldPreset.prehistoricLostWorldV3.supportsStarterShelter)
        XCTAssertNotEqual(WorldGenerationSettings(preset: .prehistoricLostWorldV2).cacheIdentity,
                          WorldGenerationSettings(preset: .prehistoricLostWorldV3).cacheIdentity)
        XCTAssertEqual(WorldPreset.normalCycle.filter { $0.isPrehistoric }, [
            .prehistoricLostWorldV3,
            .prehistoricJurassicGiantsV3,
            .prehistoricCretaceousFrontiersV3,
            .prehistoricAncientSeasV3,
        ])
        XCTAssertFalse(WorldPreset.normalCycle.contains(.prehistoricLostWorld))
        XCTAssertFalse(WorldPreset.normalCycle.contains(.prehistoricLostWorldV2))
        let visiblePrehistoricNames = WorldPreset.normalCycle.filter(\.isPrehistoric).map(\.displayName)
        XCTAssertEqual(Set(visiblePrehistoricNames).count, visiblePrehistoricNames.count,
                       "the current create-world cycle must not show duplicate legacy/current labels")
    }

    func testPrehistoricSoundCatalogAndCombatXPRewardsAreDistinct() throws {
        let roster = PrehistoricCreatureDefinition.all
        let expectedCueCount = PrehistoricSoundCue.allCases.count
        XCTAssertEqual(expectedCueCount, 23)

        let names = roster.flatMap(\.soundNames)
        let signatures = roster.flatMap { definition in
            PrehistoricSoundCue.allCases.map { definition.soundSignature(for: $0) }
        }
        XCTAssertEqual(names.count, roster.count * expectedCueCount)
        XCTAssertEqual(Set(names).count, names.count,
                       "every creature/cue pair needs an explicit sound name")
        XCTAssertEqual(Set(signatures).count, signatures.count,
                       "every creature/cue pair needs a distinct acoustic motif")
        XCTAssertEqual(Set(roster.map(\.soundProfile.formantFrequency)).count, roster.count,
                       "same-sized species must not share a synthesized voice formant")

        func definition(_ id: String) throws -> PrehistoricCreatureDefinition {
            try XCTUnwrap(PrehistoricCreatureDefinition.named(id))
        }

        let dimorphodon = try definition("prehistoric.dimorphodon")
        let compsognathus = try definition("prehistoric.compsognathus")
        let triceratops = try definition("prehistoric.triceratops")
        let allosaurus = try definition("prehistoric.allosaurus")
        let tyrannosaurus = try definition("prehistoric.tyrannosaurus")
        let spinosaurus = try definition("prehistoric.spinosaurus")
        let diplodocus = try definition("prehistoric.diplodocus")
        let brachiosaurus = try definition("prehistoric.brachiosaurus")
        let mosasaurus = try definition("prehistoric.mosasaurus")
        let liopleurodon = try definition("prehistoric.liopleurodon")

        XCTAssertEqual(dimorphodon.combatXPReward, 2)
        XCTAssertEqual(compsognathus.combatXPReward, 5)
        XCTAssertEqual(triceratops.combatXPReward, 10)
        XCTAssertEqual(allosaurus.combatXPReward, 14)
        XCTAssertEqual(tyrannosaurus.combatXPReward, 17)
        XCTAssertEqual(spinosaurus.combatXPReward, 19)
        XCTAssertTrue(roster.allSatisfy { (2...24).contains($0.combatXPReward) })
        XCTAssertGreaterThan(spinosaurus.combatXPReward, tyrannosaurus.combatXPReward)
        XCTAssertGreaterThan(tyrannosaurus.combatXPReward, allosaurus.combatXPReward)
        XCTAssertGreaterThan(allosaurus.combatXPReward, compsognathus.combatXPReward)
        XCTAssertGreaterThan(mosasaurus.combatXPReward, liopleurodon.combatXPReward)
        XCTAssertGreaterThan(diplodocus.combatXPReward, brachiosaurus.combatXPReward)

        let world = makeWorld()
        let creature = PrehistoricCreature(world: world, definition: triceratops)
        XCTAssertEqual(creature.xpReward, triceratops.combatXPReward)
    }

    func testEveryPrehistoricActionTransitionUsesOneSpeciesCue() throws {
        let world = makeWorld()
        let definition = try XCTUnwrap(
            PrehistoricCreatureDefinition.named("prehistoric.pteranodon")
        )
        let creature = PrehistoricCreature(world: world, definition: definition)
        creature.setPos(24.5, 66, 8.5)
        var sounds: [String] = []
        world.hooks.playSound = { name, _, _, _, _, _ in sounds.append(name) }

        for action in PrehistoricAction.allCases where action != .idle {
            sounds.removeAll()
            creature.setAction(action, ticks: 12)
            XCTAssertEqual(sounds, [definition.soundName(for: action.soundCue)],
                           "\(action.rawValue) must emit exactly its species cue")

            sounds.removeAll()
            creature.setAction(action, ticks: 20)
            XCTAssertTrue(sounds.isEmpty,
                          "refreshing \(action.rawValue) must not replay a transition cue")
        }

        sounds.removeAll()
        creature.setAction(.idle, ticks: 1)
        XCTAssertEqual(sounds, [definition.soundName(for: .idle)])

        sounds.removeAll()
        creature.setAction(.browse, ticks: 1)
        sounds.removeAll()
        creature.consumeActionTick()
        XCTAssertEqual(creature.action, .idle)
        XCTAssertTrue(sounds.isEmpty,
                      "timer expiry must stay silent until a controller selects a real next action")
    }

    func testPrehistoricCombatAndPlayerKillsUseSpeciesSoundsAndDifficultyXP() throws {
        let world = makeWorld()
        let velociraptor = try XCTUnwrap(
            PrehistoricCreatureDefinition.named("prehistoric.velociraptor")
        )
        let attacker = PrehistoricCreature(world: world, definition: velociraptor)
        attacker.setPos(24.5, 64, 8.5)
        let target = Player(world: world)
        target.setPos(25.5, 64, 8.5)
        var sounds: [String] = []
        world.hooks.playSound = { name, _, _, _, _, _ in sounds.append(name) }

        attacker.doMeleeAttack(target)

        XCTAssertEqual(sounds.last, velociraptor.soundName(for: .attack))
        XCTAssertFalse(sounds.contains("entity.player.attack.strong"),
                       "prehistoric attacks must not use the generic player strike")

        let triceratops = try XCTUnwrap(
            PrehistoricCreatureDefinition.named("prehistoric.triceratops")
        )
        let charging = PrehistoricCreature(world: world, definition: triceratops)
        charging.setPos(24.5, 64, 8.5)
        charging.data.prehistoricAction = PrehistoricAction.charge.rawValue
        sounds.removeAll()
        charging.doMeleeAttack(target)
        XCTAssertTrue(sounds.contains(triceratops.soundName(for: .attack)))
        XCTAssertFalse(sounds.contains(triceratops.soundName(for: .ambient)),
                       "a charge impact must not replay the creature's ambient call")
        XCTAssertTrue(sounds.contains(triceratops.soundName(for: .recover)),
                      "the charge recovery transition needs its own semantic cue")

        func playerKillXP(_ definition: PrehistoricCreatureDefinition) throws -> Int {
            let killWorld = makeWorld()
            let creature = PrehistoricCreature(world: killWorld, definition: definition)
            creature.setPos(24.5, 64, 8.5)
            creature.persistent = true
            killWorld.addEntity(creature)
            let player = Player(world: killWorld)
            player.setPos(40.5, 64, 8.5)
            killWorld.addEntity(player)

            XCTAssertTrue(creature.hurt(creature.maxHealth, "test", player))
            // `deathTime` starts at one. The nineteenth entity tick reaches
            // the shared death animation's one XP-orb spawn point exactly.
            for _ in 0..<19 { creature.tick() }
            return killWorld.entities.compactMap { ($0 as? XPOrb)?.amount }.reduce(0, +)
        }

        let low = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.compsognathus"))
        let high = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.spinosaurus"))
        XCTAssertEqual(try playerKillXP(low), low.combatXPReward)
        XCTAssertEqual(try playerKillXP(high), high.combatXPReward)
        XCTAssertGreaterThan(high.combatXPReward, low.combatXPReward)
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

    func testEveryCreatureRegistersAnOriginalNativeMeshWithinRendererBudget() {
        XCTAssertEqual(Array(entityTypes().suffix(36)), PrehistoricCreatureDefinition.allIDs)
        XCTAssertEqual(prehistoricModelIDs, PrehistoricCreatureDefinition.allIDs)
        XCTAssertTrue(prehistoricModelValidationErrors().isEmpty,
                      prehistoricModelValidationErrors().joined(separator: "; "))

        func meshBacked(_ model: MobModel, _ partName: String) -> Bool {
            model.parts.first { $0.name == partName }.map { !$0.meshes.isEmpty } ?? false
        }

        func hasVerticalTailFluke(_ model: MobModel) -> Bool {
            guard let tail = model.parts.first(where: { $0.name == "tail" }) else { return false }
            return tail.meshes.flatMap(\.faces).contains { face in
                guard face.vertices.count >= 3 else { return false }
                let ys = face.vertices.map(\.y)
                let zs = face.vertices.map(\.z)
                guard let minY = ys.min(), let maxY = ys.max(),
                      let minZ = zs.min(), let maxZ = zs.max() else { return false }
                return maxY - minY > maxZ - minZ && maxY - minY > 0.5
            }
        }

        for id in PrehistoricCreatureDefinition.allIDs {
            let model = getModel(id)
            XCTAssertFalse(model.parts.flatMap(\.meshes).isEmpty,
                           "\(id) must use source-owned rigid mesh geometry")
            XCTAssertTrue(meshBacked(model, "body"), "\(id) must have a mesh-backed body")
            XCTAssertTrue(meshBacked(model, "head"), "\(id) must have a mesh-backed head")
            let geometry = buildEntityGeometry(id)
            XCTAssertLessThanOrEqual(geometry.vertexCount / 3, 4_096,
                                     "\(id) exceeds the bounded native renderer budget")
        }

        let triceratops = getModel("prehistoric.triceratops")
        let pteranodon = getModel("prehistoric.pteranodon")
        let ichthyosaurus = getModel("prehistoric.ichthyosaurus")
        XCTAssertGreaterThanOrEqual(triceratops.parts.first { $0.name == "head" }?.meshes.count ?? 0, 5)
        XCTAssertGreaterThanOrEqual(pteranodon.parts.first { $0.name == "head" }?.meshes.count ?? 0, 3)
        XCTAssertFalse(pteranodon.parts.contains { ["beak", "crest", "skullCrest", "crown"].contains($0.name) })
        XCTAssertTrue(meshBacked(pteranodon, "wingR"))
        XCTAssertTrue(meshBacked(pteranodon, "wingL"))
        XCTAssertGreaterThanOrEqual(pteranodon.parts.first { $0.name == "wingR" }?.meshes.count ?? 0, 2)
        XCTAssertGreaterThanOrEqual(pteranodon.parts.first { $0.name == "wingL" }?.meshes.count ?? 0, 2)
        XCTAssertTrue(meshBacked(ichthyosaurus, "tail"))
        XCTAssertTrue(meshBacked(ichthyosaurus, "dorsalFin"))
        XCTAssertTrue(meshBacked(ichthyosaurus, "flipperR"))
        XCTAssertTrue(meshBacked(ichthyosaurus, "flipperL"))
        XCTAssertTrue(hasVerticalTailFluke(ichthyosaurus),
                      "the native ichthyosaur must not silently reuse a dolphin-like horizontal tail")
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
        let legacySummary = LANWorldSummary(
            worldID: "lost-world", worldName: "Lost World", seed: 1, gameMode: GameMode.survival,
            difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 1,
            worldPreset: "Lost World"
        )
        XCTAssertEqual(legacySummary.worldPreset, WorldPreset.prehistoricLostWorld.rawValue)
        XCTAssertEqual(legacySummary.prehistoricContentIdentity,
                       PrehistoricWorldProfile.lostWorldV1.contentIdentity)
        XCTAssertEqual(legacySummary.compatibleWorldPreset, .prehistoricLostWorld)
        XCTAssertEqual(lanClientResumeKey(for: legacySummary),
                       "lost-world#1#\(PrehistoricWorldProfile.lostWorldV1.contentIdentity)")
        let encodedSummary = try? JSONEncoder().encode(legacySummary)
        let decodedSummary = encodedSummary.flatMap { try? JSONDecoder().decode(LANWorldSummary.self, from: $0) }
        XCTAssertEqual(decodedSummary?.worldPreset, WorldPreset.prehistoricLostWorld.rawValue)
        XCTAssertEqual(decodedSummary?.prehistoricContentIdentity,
                       PrehistoricWorldProfile.lostWorldV1.contentIdentity)

        let v2Summary = LANWorldSummary(
            worldID: "lost-world", worldName: "Lost World", seed: 1, gameMode: GameMode.survival,
            difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 1,
            worldPreset: WorldPreset.prehistoricLostWorldV2.rawValue
        )
        XCTAssertEqual(v2Summary.worldPreset, WorldPreset.prehistoricLostWorldV2.rawValue)
        XCTAssertEqual(v2Summary.prehistoricContentIdentity,
                       PrehistoricWorldProfile.lostWorldV2.contentIdentity)
        XCTAssertEqual(v2Summary.compatibleWorldPreset, .prehistoricLostWorldV2)
        XCTAssertEqual(lanClientResumeKey(for: v2Summary),
                       "lost-world#1#\(PrehistoricWorldProfile.lostWorldV2.contentIdentity)")

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

    func testEveryPrehistoricRevisionRoundTripsSaveAndLANWithoutUpgrading() throws {
        for profile in PrehistoricWorldProfile.allCases {
            let preset = profile.preset
            let record = WorldRecord(
                id: "versioned-profile", name: preset.displayName, seed: 7,
                gameMode: GameMode.survival, difficulty: 2, worldPreset: preset,
                dungeonDensity: .more, villageDensity: .max
            )
            let decodedRecord = try JSONDecoder().decode(
                WorldRecord.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(decodedRecord.worldPreset, preset.rawValue)
            XCTAssertEqual(decodedRecord.generationSettings.preset.prehistoricProfile, profile)
            XCTAssertEqual(decodedRecord.generationSettings.cacheIdentity,
                           record.generationSettings.cacheIdentity)
            XCTAssertEqual(decodedRecord.generationSettings.dungeonDensity, .more)
            XCTAssertEqual(decodedRecord.generationSettings.villageDensity, .normal)

            let summary = LANWorldSummary(
                worldID: record.id, worldName: record.name, seed: Int64(record.seed),
                gameMode: record.gameMode, difficulty: record.difficulty,
                dimension: Dim.overworld.rawValue, playerCount: 1,
                worldPreset: preset.rawValue
            )
            let decodedSummary = try JSONDecoder().decode(
                LANWorldSummary.self, from: JSONEncoder().encode(summary))
            XCTAssertEqual(decodedSummary.worldPreset, preset.rawValue)
            XCTAssertEqual(decodedSummary.prehistoricContentIdentity, profile.contentIdentity)
            XCTAssertEqual(decodedSummary.compatibleWorldPreset, preset)
            XCTAssertEqual(lanClientResumeKey(for: decodedSummary),
                           "versioned-profile#7#\(profile.contentIdentity)")
        }
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
        futureSave["worldPreset"] = "elysium:prehistoric_lost_world_v4"
        let futureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: futureSaveData))
        futureSave["worldPreset"] = "other:prehistoric_lost_world_v4"
        let foreignFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: foreignFutureSaveData),
                             "a foreign namespace must not launder a future prehistoric profile into normal")
        futureSave["worldPreset"] = "other:prehistoric lost world v4"
        let whitespaceFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: whitespaceFutureSaveData),
                             "whitespace aliases must not launder a future prehistoric profile into normal")
        futureSave["worldPreset"] = "other:prehistoric.lost_world_v4"
        let punctuationFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: punctuationFutureSaveData),
                             "punctuation aliases must not launder a future prehistoric profile into normal")
        futureSave["worldPreset"] = "elysium:lost.world.v4"
        let aliasedElysiumFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: aliasedElysiumFutureSaveData))
        futureSave["worldPreset"] = "other:prehistoricLostWorldV4"
        let camelCaseFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: camelCaseFutureSaveData),
                             "a camel-cased future prehistoric profile must not fall back to normal")
        futureSave["worldPreset"] = "elysium:lostWorldV4"
        let camelCaseElysiumFutureSaveData = try JSONSerialization.data(withJSONObject: futureSave)
        XCTAssertThrowsError(try JSONDecoder().decode(WorldRecord.self, from: camelCaseElysiumFutureSaveData))
        futureSave["worldPreset"] = "other:pre.historic_lost_world_v4"
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
            playerCount: 1, worldPreset: "elysium:prehistoric_lost_world_v4"
        )
        XCTAssertEqual(directFutureSummary.worldPreset, "elysium:prehistoric_lost_world_v4")
        XCTAssertNil(directFutureSummary.compatibleWorldPreset)
        let directForeignFutureSummary = LANWorldSummary(
            worldID: "future-profile", worldName: "Future Profile", seed: 7,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 1, worldPreset: "other:prehistoric_lost_world_v4"
        )
        XCTAssertEqual(directForeignFutureSummary.worldPreset, "other:prehistoric_lost_world_v4")
        XCTAssertNil(directForeignFutureSummary.compatibleWorldPreset)
        let encodedSummary = try JSONEncoder().encode(summary)
        var mismatchedSummary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedSummary) as? [String: Any])
        mismatchedSummary["prehistoricContentIdentity"] = "elysium.prehistoric.lostWorld.v999"
        let mismatchedSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: mismatchedSummaryData))

        mismatchedSummary["worldPreset"] = "elysium:prehistoric_lost_world_v4"
        mismatchedSummary["prehistoricContentIdentity"] = "elysium.prehistoric.lostWorld.v4"
        let unknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: unknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:prehistoric_lost_world_v4"
        let foreignUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: foreignUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:prehistoric lost world v4"
        let whitespaceUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: whitespaceUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other/prehistoric/lost_world_v4"
        let punctuationUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: punctuationUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "foreign:elysium:prehistoric_lost_world_v4"
        let nestedUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: nestedUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:prehistoricLostWorldV4"
        let camelCaseUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: camelCaseUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "elysium:lostWorldV4"
        let camelCaseElysiumUnknownSummaryData = try JSONSerialization.data(withJSONObject: mismatchedSummary)
        XCTAssertThrowsError(try JSONDecoder().decode(LANWorldSummary.self, from: camelCaseElysiumUnknownSummaryData))

        mismatchedSummary["worldPreset"] = "other:pre.historic_lost_world_v4"
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
