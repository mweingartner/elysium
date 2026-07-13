import XCTest
@testable import ElysiumCore

@MainActor
final class RPGSecurityRegressionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllRecipes()
        registerAllLootTables()
        registerAllSystems()
    }

    func testGameCoreOrdinarySaveUsesOverlayAndFinalizingSaveCleansDurably() throws {
        let db = try makeTempDB()
        let game = GameCore(db: db)
        game.createWorld(name: "RPG Transient Save", seedText: "50101",
                         mode: GameMode.survival, difficulty: 2)
        let worldID = try XCTUnwrap(game.listWorlds().first?.id)
        let oldWorld = game.world
        let world = makeWorld(seed: oldWorld.seed)
        world.hooks = oldWorld.hooks
        world.gameRules = oldWorld.gameRules
        world.difficulty = oldWorld.difficulty
        oldWorld.removeEntity(game.player)
        game.player.world = world
        game.player.setPos(0.5, 64, 0.5)
        world.addEntity(game.player)
        game.worlds[game.dim] = world
        world.rpgSimulationTick = 777
        configureRitualist(game.player, preparedSpell: "summon_servant")
        game.player.rpg.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 4,
                                                   remainingTicks: 100, costPerSecond: 0.5)]
        game.player.rpg.activeCooldowns = [RPGCooldown(id: "summon_servant", remainingTicks: 80)]

        let position = RPGBlockPosition(1, 64, 1)
        world.setBlock(position.x, position.y, position.z, Int(cell(B.torch)))
        let light = RPGTemporaryEffectDraft(
            kind: .mageLight, ownerAuthorityID: game.player.effectiveRPGAuthorityID,
            ownerEntityID: game.player.id, ownerSequence: 1, center: position,
            durationTicks: 200,
            guardedBlock: RPGGuardedTemporaryBlock(position: position, originalCell: 0,
                                                   temporaryCell: Int(cell(B.torch))))
        XCTAssertTrue(world.registerRPGTemporaryEffect(light))
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .ward, ownerAuthorityID: game.player.effectiveRPGAuthorityID,
            ownerEntityID: game.player.id, ownerSequence: 2, center: RPGBlockPosition(2, 64, 2),
            durationTicks: 200, remainingCharges: 1)))
        let servant = Allay(world: world)
        servant.setPos(3.5, 64, 3.5)
        world.addEntity(servant)
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .servant, ownerAuthorityID: game.player.effectiveRPGAuthorityID,
            ownerEntityID: game.player.id, ownerSequence: 3, center: RPGBlockPosition(3, 64, 3),
            durationTicks: 200), entityID: servant.id))

        game.saveAndFlush(synchronous: true)

        XCTAssertEqual(db.getWorld(worldID)?.rpgSimulationTick, 777)

        XCTAssertEqual(world.rpgTemporaryEffects.count, 3)
        XCTAssertEqual(world.getBlock(1, 64, 1), Int(cell(B.torch)))
        XCTAssertNotNil(world.entityById[servant.id])
        XCTAssertEqual(game.player.rpg.activeUpkeeps.count, 1)
        XCTAssertEqual(game.player.rpg.activeCooldowns.count, 1)
        let ordinaryPlayerRecord = try XCTUnwrap(db.getPlayer(worldID))
        let ordinaryPlayerData = try XCTUnwrap(ordinaryPlayerRecord["data"] as? [String: Any])
        let ordinaryRPGData = try XCTUnwrap(ordinaryPlayerData["rpg"] as? [String: Any])
        XCTAssertEqual((ordinaryRPGData["activeCooldowns"] as? [Any])?.count, 1)
        let ordinaryRPGBytes = try JSONSerialization.data(withJSONObject: ordinaryRPGData)
        let ordinaryDecodedRPG = try JSONDecoder().decode(RPGCharacterState.self, from: ordinaryRPGBytes)
        XCTAssertEqual(ordinaryDecodedRPG.activeCooldowns.count, 1)
        let reloadedOrdinary = GameCore(db: db)
        reloadedOrdinary.loadWorld(worldID)
        XCTAssertEqual(reloadedOrdinary.rpgSimulationTick, 777)
        XCTAssertTrue(reloadedOrdinary.worlds.values.allSatisfy { $0.rpgSimulationTick == 777 })
        XCTAssertEqual(reloadedOrdinary.world.getBlock(1, 64, 1), 0)
        XCTAssertFalse(reloadedOrdinary.world.entities.contains { $0 is Allay })
        assertPersistedRitualist(reloadedOrdinary.player.rpg)
        XCTAssertTrue(reloadedOrdinary.player.rpg.activeUpkeeps.isEmpty)
        XCTAssertEqual(reloadedOrdinary.player.rpg.activeCooldowns,
                       [RPGCooldown(id: "summon_servant", remainingTicks: 80)])

        game.finalizeAndSave(synchronous: true)
        XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        XCTAssertEqual(world.getBlock(1, 64, 1), 0)
        XCTAssertNil(world.entityById[servant.id])
        XCTAssertTrue(game.player.rpg.activeUpkeeps.isEmpty)
        XCTAssertEqual(game.player.rpg.activeCooldowns.count, 1)
        let finalPlayerRecord = try XCTUnwrap(db.getPlayer(worldID))
        let finalPlayerData = try XCTUnwrap(finalPlayerRecord["data"] as? [String: Any])
        let finalRPGData = try XCTUnwrap(finalPlayerData["rpg"] as? [String: Any])
        XCTAssertEqual((finalRPGData["activeCooldowns"] as? [Any])?.count, 1)
        let reloadedFinal = GameCore(db: db)
        reloadedFinal.loadWorld(worldID)
        XCTAssertEqual(reloadedFinal.world.getBlock(1, 64, 1), 0)
        XCTAssertFalse(reloadedFinal.world.entities.contains { $0 is Allay })
        assertPersistedRitualist(reloadedFinal.player.rpg)
        XCTAssertTrue(reloadedFinal.player.rpg.activeUpkeeps.isEmpty)
        XCTAssertEqual(reloadedFinal.player.rpg.activeCooldowns,
                       [RPGCooldown(id: "summon_servant", remainingTicks: 80)])
    }

    func testPersistenceOverlayPreservesLiveEffectsAndFinalizationCleansThem() throws {
        let world = makeWorld(seed: 501)
        let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                        preparedSpell: "summon_servant")
        player.rpg.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 9,
                                              remainingTicks: 100, costPerSecond: 0.5)]
        player.rpg.activeCooldowns = [RPGCooldown(id: "summon_servant", remainingTicks: 80)]

        let lightPosition = RPGBlockPosition(1, 64, 1)
        world.setBlock(lightPosition.x, lightPosition.y, lightPosition.z, Int(cell(B.torch)))
        let lightDraft = RPGTemporaryEffectDraft(
            kind: .mageLight, ownerAuthorityID: player.effectiveRPGAuthorityID,
            ownerEntityID: player.id, ownerSequence: 1, center: lightPosition,
            durationTicks: 200,
            guardedBlock: RPGGuardedTemporaryBlock(position: lightPosition, originalCell: 0,
                                                   temporaryCell: Int(cell(B.torch))))
        XCTAssertTrue(world.registerRPGTemporaryEffect(lightDraft))
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .ward, ownerAuthorityID: player.effectiveRPGAuthorityID,
            ownerEntityID: player.id, ownerSequence: 2, center: RPGBlockPosition(2, 64, 2),
            durationTicks: 200, remainingCharges: 1)))
        let servant = Allay(world: world)
        servant.setPos(3.5, 64, 3.5)
        world.addEntity(servant)
        let servantDraft = RPGTemporaryEffectDraft(
            kind: .servant, ownerAuthorityID: player.effectiveRPGAuthorityID,
            ownerEntityID: player.id, ownerSequence: 3, center: RPGBlockPosition(3, 64, 3),
            durationTicks: 200)
        XCTAssertTrue(world.registerRPGTemporaryEffect(servantDraft, entityID: servant.id))

        let chunk = try XCTUnwrap(world.getChunk(0, 0))
        let liveBlocks = chunk.blocks
        let liveEffects = world.rpgTemporaryEffects
        let persisted = world.rpgBlocksForPersistence(in: chunk)
        let index = chunk.index(1, 64, 1)
        XCTAssertEqual(persisted[index], 0)
        XCTAssertEqual(chunk.blocks, liveBlocks)
        XCTAssertEqual(world.rpgTemporaryEffects, liveEffects)
        XCTAssertEqual(world.getBlock(1, 64, 1), Int(cell(B.torch)))
        XCTAssertTrue(world.entityById[servant.id] != nil)
        XCTAssertEqual(world.rpgTemporaryEntityIDsForPersistence(), [servant.id])
        XCTAssertEqual(player.rpg.activeUpkeeps.count, 1)

        let savedPlayer = player.save()
        let reloaded = Player(world: world)
        reloaded.load(savedPlayer)
        XCTAssertTrue(reloaded.rpg.activeUpkeeps.isEmpty)
        XCTAssertEqual(reloaded.rpg.activeCooldowns,
                       [RPGCooldown(id: "summon_servant", remainingTicks: 80)])

        world.finalizeRPGTransientState()
        world.finalizeRPGTransientState() // idempotent terminal path
        XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        XCTAssertEqual(world.getBlock(1, 64, 1), 0)
        XCTAssertNil(world.entityById[servant.id])
        XCTAssertTrue(player.rpg.activeUpkeeps.isEmpty)
        XCTAssertEqual(player.rpg.activeCooldowns,
                       [RPGCooldown(id: "summon_servant", remainingTicks: 80)])
    }

    func testForgedOwnerAndEntityAuthorizationsRejectBeforeAnyMutation() {
        do {
            let world = makeWorld(seed: 502)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                            preparedSpell: "mage_light")
            placeRayBlock(world, B.stone)
            assertAuthorizationRejectedWithoutMutation(player,
                RPGActionAuthorization(ownerAuthorityID: "forged-owner",
                                       worldOwnerEntityID: player.id,
                                       canBuild: true, canUseContainers: true),
                kind: .spell, id: "mage_light")
        }
        do {
            let world = makeWorld(seed: 503)
            let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "charge_pack",
                                            preparedSkill: "safe_fuse")
            registerControlledCharge(world, player: player, position: RPGBlockPosition(0, 65, 4), sequence: 8)
            assertAuthorizationRejectedWithoutMutation(player,
                RPGActionAuthorization(ownerAuthorityID: player.effectiveRPGAuthorityID,
                                       worldOwnerEntityID: player.id + 1,
                                       canBuild: true, canUseContainers: true),
                kind: .skill, id: "safe_fuse")
        }
        do {
            let world = makeWorld(seed: 504)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                            preparedSpell: "summon_servant")
            assertAuthorizationRejectedWithoutMutation(player,
                RPGActionAuthorization(ownerAuthorityID: "forged-servant",
                                       worldOwnerEntityID: player.id + 1,
                                       canBuild: true, canUseContainers: true),
                kind: .spell, id: "summon_servant")
        }
    }

    func testReservationRejectsDuplicateCumulativeOverflowAndInvalidCellsAtomically() throws {
        do {
            let world = makeWorld(seed: 5041)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                            preparedSpell: "mage_light")
            placeRayBlock(world, B.stone)
            guard case .success(let prepared) = rpgPrepareAction(
                player, kind: .spell, id: "mage_light", authorization: .local(for: player)
            ) else {
                return XCTFail("mage light should prepare before the reservation race")
            }
            let draft = try XCTUnwrap(prepared.operations.compactMap { operation -> RPGTemporaryEffectDraft? in
                if case .registerTemporary(let value) = operation { return value }
                return nil
            }.first)
            let placement = try XCTUnwrap(prepared.operations.compactMap { operation -> RPGBlockMutation? in
                if case .setBlock(let value) = operation { return value }
                return nil
            }.first)
            let rpgBefore = player.rpg
            let itemsBefore = RPGPlayerItemsSnapshot.capture(player)
            let blockBefore = world.getBlock(placement.position.x, placement.position.y, placement.position.z)

            XCTAssertTrue(world.registerRPGTemporaryEffect(draft))
            let effectsAfterRace = world.rpgTemporaryEffects
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failureValue, .staleMutation)
            XCTAssertEqual(player.rpg, rpgBefore)
            XCTAssertEqual(RPGPlayerItemsSnapshot.capture(player), itemsBefore)
            XCTAssertEqual(world.getBlock(placement.position.x, placement.position.y, placement.position.z), blockBefore)
            XCTAssertEqual(world.rpgTemporaryEffects, effectsAfterRace)
        }

        do {
            let world = makeWorld(seed: 505)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                            preparedSpell: "mage_light")
            let collisionPosition = RPGBlockPosition(2, 64, 2)
            world.setBlock(2, 64, 2, Int(cell(B.torch)))
            let sequence = try XCTUnwrap(rpgNextActionSequence(player.rpg))
            let colliding = RPGTemporaryEffectDraft(
                kind: .mageLight, ownerAuthorityID: player.effectiveRPGAuthorityID,
                ownerEntityID: player.id, ownerSequence: sequence, center: collisionPosition,
                durationTicks: 200,
                guardedBlock: RPGGuardedTemporaryBlock(position: collisionPosition, originalCell: 0,
                                                       temporaryCell: Int(cell(B.torch))))
            XCTAssertTrue(world.registerRPGTemporaryEffect(colliding))
            placeRayBlock(world, B.stone)
            let before = player.rpg
            XCTAssertEqual(rpgPrepareAction(player, kind: .spell, id: "mage_light",
                                            authorization: .local(for: player)).failureValue,
                           .temporaryLimit)
            XCTAssertEqual(player.rpg, before)
            XCTAssertEqual(world.rpgTemporaryEffects, [world.rpgTemporaryEffect(for: colliding.key)!])
        }

        do {
            let world = makeWorld(seed: 506)
            for index in 0..<(RPG_MAX_TEMPORARY_EFFECTS_PER_WORLD - 1) {
                XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
                    kind: .decoy, ownerAuthorityID: "owner-\(index)", ownerEntityID: nil,
                    ownerSequence: 1, center: RPGBlockPosition(index % 16, 64, index / 16),
                    durationTicks: 200)))
            }
            let additions = [0, 1].map {
                RPGTemporaryEffectDraft(kind: .ward, ownerAuthorityID: "new-\($0)", ownerEntityID: nil,
                                        ownerSequence: 1, center: RPGBlockPosition(10 + $0, 64, 10),
                                        durationTicks: 200)
            }
            let before = world.rpgTemporaryEffects
            XCTAssertFalse(world.canReserveRPGTemporaryEffects(additions))
            XCTAssertFalse(world.reserveRPGTemporaryEffects(additions))
            XCTAssertEqual(world.rpgTemporaryEffects, before)

            let bad = RPGTemporaryEffectDraft(
                kind: .mageLight, ownerAuthorityID: "bad-cell", ownerEntityID: nil,
                ownerSequence: 1, center: RPGBlockPosition(1, 64, 1), durationTicks: 200,
                guardedBlock: RPGGuardedTemporaryBlock(position: RPGBlockPosition(1, 64, 1),
                                                       originalCell: -1, temporaryCell: 70_000))
            XCTAssertFalse(world.canReserveRPGTemporaryEffects([bad]))
            XCTAssertEqual(world.rpgTemporaryEffects, before)
        }

        do {
            let world = makeWorld(seed: 507)
            let draft = RPGTemporaryEffectDraft(kind: .ward, ownerAuthorityID: "rollback",
                                                ownerEntityID: nil, ownerSequence: 1,
                                                center: RPGBlockPosition(1, 64, 1), durationTicks: 200)
            XCTAssertTrue(world.reserveRPGTemporaryEffects([draft]))
            world.rollbackRPGTemporaryReservations([draft.key])
            XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        }
    }

    func testSuccessfulServantIsPaidOnlyWithAttachedReservation() {
        let world = makeWorld(seed: 508)
        let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                        preparedSpell: "summon_servant")
        let beforeFatigue = player.rpg.fatigue
        guard case .success(let result) = rpgCastPreparedSpell(player, spellID: "summon_servant") else {
            return XCTFail("servant should commit")
        }
        let record = world.rpgTemporaryEffects.first { $0.draft.kind == .servant }
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.entityID, result.targetEntityID)
        XCTAssertNotNil(result.targetEntityID.flatMap { world.entityById[$0] })
        XCTAssertLessThan(player.rpg.fatigue, beforeFatigue)
    }

    func testLootMaterializationPreservesOccupiedSlotsAndSpillsOverflowDeterministically() {
        let world = makeWorld(seed: 509)
        let be = makeContainerBE(1, 64, 1, 27)
        for index in 0..<26 { be.items![index] = ItemStack(iid("cobblestone"), index + 1) }
        let occupiedBefore = be.items!.map { $0?.copy() }
        be.lootTable = "dungeon"
        be.lootSeed = 73
        be.rpgGeneratedContainerKey = "generated:0:1:64:1"
        world.setBlockEntity(be)
        var expectedRNG = RandomX(73)
        let expectedLoot = rollLoot("dungeon", &expectedRNG)

        let result = resolveLoot(world, be)

        XCTAssertEqual(result?.insertedCount, min(1, expectedLoot.count))
        XCTAssertEqual(result?.spilledCount, max(0, expectedLoot.count - 1))
        for index in 0..<26 { XCTAssertEqual(be.items![index], occupiedBefore[index]) }
        let spilled = world.entities.compactMap { $0 as? ItemEntity }
        XCTAssertEqual(spilled.count, max(0, expectedLoot.count - 1))
        XCTAssertTrue(spilled.allSatisfy {
            $0.x == 1.5 && $0.y == 64.5 && $0.z == 1.5
                && $0.vx == 0 && $0.vy == 0.2 && $0.vz == 0
        })
    }

    func testBrushableAndMalformedContainersCannotEarnGeneratedLootXP() {
        for (offset, block, table) in [
            (0, B.suspicious_sand, "desert_well_archaeology"),
            (1, B.suspicious_gravel, "trail_ruins_archaeology"),
        ] {
            let world = makeWorld(seed: UInt32(510 + offset))
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye",
                                            preparedSkill: "lock_touch", belowCap: true)
            world.setBlock(0, 65, 4, Int(cell(block)))
            let brushable = makeBrushableBE(0, 65, 4, table, 12 + offset)
            brushable.rpgGeneratedContainerKey = "generated:0:0:65:4"
            world.setBlockEntity(brushable)

            // A fresh archaeology block entity is not a container and must retain
            // its table until the brush interaction owns materialization.
            XCTAssertNil(resolveLoot(world, brushable, discoveredBy: player))
            XCTAssertEqual(brushable.lootTable, table)
            XCTAssertEqual(brushable.rpgGeneratedContainerKey, "generated:0:0:65:4")
            let beforeXP = player.rpg.xp

            finishBreaking(InteractCtx(world: world, player: player), 0, 65, 4)

            XCTAssertEqual(world.getBlock(0, 65, 4), 0)
            XCTAssertNil(world.getBlockEntity(0, 65, 4))
            XCTAssertTrue(world.entities.compactMap { $0 as? ItemEntity }.isEmpty)
            XCTAssertEqual(player.rpg.xp, beforeXP)
        }

        do {
            let world = makeWorld(seed: 511)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye",
                                            preparedSkill: "lock_touch", belowCap: true)
            placeRayBlock(world, B.chest)
            let be = makeContainerBE(0, 65, 4, 27)
            be.rpgGeneratedContainerKey = "generated:0:0:65:4"
            world.setBlockEntity(be)
            let beforeXP = player.rpg.xp
            guard case .success = rpgUsePreparedSkill(player, skillID: "lock_touch") else {
                return XCTFail("nil-table container read should remain usable")
            }
            XCTAssertEqual(player.rpg.xp, beforeXP)
            XCTAssertEqual(be.rpgGeneratedContainerKey, "generated:0:0:65:4")
        }

        do {
            let world = makeWorld(seed: 512)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye",
                                            preparedSkill: "lock_touch", belowCap: true)
            placeRayBlock(world, B.chest)
            let be = makeContainerBE(0, 65, 4, 27)
            be.lootTable = "dungeon"
            be.lootSeed = 14
            be.rpgGeneratedContainerKey = String(repeating: "x", count: RPG_MAX_ID_UTF8_BYTES + 1)
            world.setBlockEntity(be)
            let beforeXP = player.rpg.xp
            guard case .success = rpgUsePreparedSkill(player, skillID: "lock_touch") else {
                return XCTFail("malformed provenance must not block ordinary loot materialization")
            }
            XCTAssertEqual(player.rpg.xp, beforeXP)
            XCTAssertNil(be.lootTable)
            XCTAssertNil(be.rpgGeneratedContainerKey)
        }
    }

    private func assertAuthorizationRejectedWithoutMutation(_ player: Player,
                                                            _ authorization: RPGActionAuthorization,
                                                            kind: RPGPreparedActionKind,
                                                            id: String) {
        let rpgBefore = player.rpg
        let itemsBefore = RPGPlayerItemsSnapshot.capture(player)
        let effectsBefore = player.world.rpgTemporaryEffects
        let entitiesBefore = player.world.entities.map(\.id)
        let chunksBefore = player.world.chunks.mapValues { $0.blocks }
        XCTAssertEqual(rpgPrepareAction(player, kind: kind, id: id,
                                        authorization: authorization).failureValue,
                       .authorizationMismatch)
        XCTAssertEqual(player.rpg, rpgBefore)
        XCTAssertEqual(RPGPlayerItemsSnapshot.capture(player), itemsBefore)
        XCTAssertEqual(player.world.rpgTemporaryEffects, effectsBefore)
        XCTAssertEqual(player.world.entities.map(\.id), entitiesBefore)
        XCTAssertEqual(player.world.chunks.mapValues { $0.blocks }, chunksBefore)
    }

    private func makeWorld(seed: UInt32) -> World {
        let world = World(dim: .overworld, seed: seed)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height))
        return world
    }

    private func makeTempDB() throws -> SaveDB {
        try PersistenceTestSupport.makeDatabase(owner: self, label: "rpg-security")
    }

    private func configureRitualist(_ player: Player, preparedSpell: String) {
        XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist", attributes: rpgCreationPreset(pathID: "arcanist")!,
            starterSkillID: "ritual_circle", starterSpellIDs: ["mage_light"])))
        var state = player.rpg
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        state.level = RPG_LEVEL_CAP
        for skill in rpgBranchDefinition("arcanist_ritualist")!.skillIDs {
            state.skillRanks[skill] = 3
        }
        state = repairRPGCharacterState(state)
        state.preparedSpellIDs = [preparedSpell]
        state.selectedPreparedSpellID = preparedSpell
        state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: preparedSpell)
        state = repairRPGCharacterState(state)
        state.fatigue = rpgDerivedStats(state).maxFatigue
        player.rpg = state
    }

    private func assertPersistedRitualist(_ state: RPGCharacterState,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertTrue(state.created, file: file, line: line)
        XCTAssertEqual(state.pathID, "arcanist", file: file, line: line)
        XCTAssertGreaterThan(state.skillRanks["ritual_circle"] ?? 0, 0, file: file, line: line)
        XCTAssertGreaterThan(state.skillRanks["bound_servant"] ?? 0, 0, file: file, line: line)
        XCTAssertTrue(state.knownSpellIDs.contains("summon_servant"), file: file, line: line)
        XCTAssertEqual(state.preparedSpellIDs, ["summon_servant"], file: file, line: line)
        XCTAssertEqual(state.selectedPreparedSpellID, "summon_servant", file: file, line: line)
    }

    private func placeRayBlock(_ world: World, _ block: UInt16) {
        world.setBlock(0, 65, 4, Int(cell(block)))
    }

    private func makeMasteredPlayer(in world: World, pathID: String, starter: String,
                                    preparedSkill: String? = nil, preparedSpell: String? = nil,
                                    belowCap: Bool = false) -> Player {
        let player = Player(world: world)
        let starterSpells: [String]
        switch (pathID, starter) {
        case ("arcanist", "ritual_circle"): starterSpells = ["mage_light"]
        default: starterSpells = []
        }
        XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(
            pathID: pathID, attributes: rpgCreationPreset(pathID: pathID)!,
            starterSkillID: starter, starterSpellIDs: starterSpells)))
        var state = player.rpg
        state.xp = rpgXPRequiredForLevel(belowCap ? 19 : RPG_LEVEL_CAP)
        state.level = belowCap ? 19 : RPG_LEVEL_CAP
        if let branch = rpgBranchDefinition(state.specializationBranchID) {
            for skill in branch.skillIDs { state.skillRanks[skill] = 3 }
        }
        state = repairRPGCharacterState(state)
        if let preparedSkill {
            state.preparedSkillIDs = [preparedSkill]
            state.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: preparedSkill)
        }
        if let preparedSpell {
            state.preparedSpellIDs = [preparedSpell]
            state.selectedPreparedSpellID = preparedSpell
            state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: preparedSpell)
        }
        state = repairRPGCharacterState(state)
        state.fatigue = rpgDerivedStats(state).maxFatigue
        player.rpg = state
        if preparedSpell != nil {
            player.inventory[0] = ItemStack(iid("apprentice_focus"), 1)
            player.selectedSlot = 0
        }
        player.setPos(0.5, 64, 0.5)
        world.addEntity(player)
        return player
    }

    private func registerControlledCharge(_ world: World, player: Player,
                                          position: RPGBlockPosition, sequence: Int) {
        world.setBlock(position.x, position.y, position.z, Int(cell(B.tnt)))
        let draft = RPGTemporaryEffectDraft(
            kind: .controlledCharge, ownerAuthorityID: player.effectiveRPGAuthorityID,
            ownerEntityID: player.id, ownerSequence: sequence, center: position,
            durationTicks: 200,
            guardedBlock: RPGGuardedTemporaryBlock(position: position, originalCell: 0,
                                                   temporaryCell: Int(cell(B.tnt))))
        XCTAssertTrue(world.registerRPGTemporaryEffect(draft))
    }
}

private extension Result where Failure == RPGActionFailure {
    var failureValue: RPGActionFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
