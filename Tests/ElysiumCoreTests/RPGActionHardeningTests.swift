import XCTest
@testable import ElysiumCore

final class RPGActionHardeningTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllRecipes()
        registerAllLootTables()
        registerAllSystems()
    }

    func testMetadataExhaustivelyCoversEveryActiveSkillAndSpellExactlyOnce() {
        let activeDefinitions = Set(RPG_SKILL_DEFINITIONS.filter { $0.kind == .active }.map(\.id))
        let activeMetadata = RPG_ACTIVE_ACTION_METADATA.compactMap { metadata -> String? in
            if case .skill = metadata.id { return metadata.id.rawValue }
            return nil
        }
        XCTAssertEqual(RPG_ACTIVE_ACTION_METADATA.count, 19)
        XCTAssertEqual(Set(activeMetadata), activeDefinitions)
        XCTAssertEqual(activeMetadata.count, Set(activeMetadata).count)

        let spellMetadata = RPG_SPELL_ACTION_METADATA.map { $0.id.rawValue }
        XCTAssertEqual(RPG_SPELL_ACTION_METADATA.count, 17)
        XCTAssertEqual(Set(spellMetadata), Set(RPGSpellEffectID.allCases.map(\.rawValue)))
        XCTAssertEqual(spellMetadata.count, Set(spellMetadata).count)
        for definition in RPG_SKILL_DEFINITIONS where definition.kind != .active {
            XCTAssertNil(rpgActionMetadata(kind: .skill, id: definition.id))
        }
    }

    func testContainerProvenanceChangeMakesPreparedActionStaleWithoutSpend() throws {
        let world = makeWorld(seed: 201)
        let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye",
                                        preparedSkill: "lock_touch")
        placeRayBlock(world, B.chest)
        let be = makeContainerBE(0, 65, 4, 27)
        be.lootTable = "dungeon"
        be.lootSeed = 44
        be.rpgGeneratedContainerKey = "generated:0:0:65:4"
        world.setBlockEntity(be)
        let before = player.rpg
        let prepared = try XCTUnwrap(tryPrepare(player, kind: .skill, id: "lock_touch"))

        be.rpgGeneratedContainerKey = "generated:0:1:65:4"
        world.setBlockEntity(be)

        XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
        XCTAssertEqual(player.rpg, before)
        XCTAssertEqual(be.lootTable, "dungeon")
    }

    func testRemoteTriggerRejectsScheduledTickAddedAfterPrepare() throws {
        let world = makeWorld(seed: 202)
        let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "circuit_sense",
                                        preparedSkill: "remote_trigger")
        placeRayBlock(world, B.dispenser)
        let before = player.rpg
        let prepared = try XCTUnwrap(tryPrepare(player, kind: .skill, id: "remote_trigger"))
        world.scheduleTick(0, 65, 4, Int(B.dispenser), 1)

        XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
        XCTAssertEqual(player.rpg, before)
    }

    func testRemoteTriggerSupportsEveryRegisteredInteractiveDevice() {
        let devices: [UInt16] = [
            B.lever, B.stone_button, B.dispenser, B.dropper,
            B.repeater, B.repeater_on, B.comparator, B.comparator_on,
            B.daylight_detector, B.daylight_detector_inverted,
        ]
        for (offset, block) in devices.enumerated() {
            let world = makeWorld(seed: UInt32(220 + offset))
            let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "circuit_sense",
                                            preparedSkill: "remote_trigger")
            player.pitch = 0.16
            placeRayBlock(world, block)
            let result = rpgUsePreparedSkill(player, skillID: "remote_trigger")
            guard case .success = result else {
                XCTFail("remote trigger rejected \(blockDefs[Int(block)].name): \(String(describing: result.failure))")
                continue
            }
        }
    }

    func testFullCooldownStateRejectsActionWithoutDroppingNewCooldownOrSpending() {
        let world = makeWorld(seed: 203)
        let player = makeMasteredPlayer(in: world, pathID: "warden", starter: "heavy_cut",
                                        preparedSkill: "heavy_cut")
        player.inventory[0] = ItemStack(iid("iron_sword"), 1)
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 3.5)
        world.addEntity(zombie)
        let ids = (RPG_SKILL_DEFINITIONS.map(\.id) + RPG_SPELL_DEFINITIONS.map(\.id))
            .filter { $0 != "heavy_cut" }
        player.rpg.activeCooldowns = Array(ids.prefix(RPG_MAX_COOLDOWNS)).map {
            RPGCooldown(id: $0, remainingTicks: 100)
        }
        XCTAssertEqual(player.rpg.activeCooldowns.count, RPG_MAX_COOLDOWNS)
        let before = player.rpg

        XCTAssertEqual(rpgUsePreparedSkill(player, skillID: "heavy_cut").failure, .boundedStateLimit)
        XCTAssertEqual(player.rpg, before)
        XCTAssertEqual(zombie.health, zombie.maxHealth)
    }

    func testAllySpellCannotPassThroughWallAndFallsBackToSelfOnlyWithoutEntityTarget() {
        let world = makeWorld(seed: 204)
        let player = makeMasteredPlayer(in: world, pathID: "mender", starter: "field_dressing",
                                        preparedSpell: "mend_wounds")
        player.health = 5
        let villager = Villager(world: world)
        villager.setPos(0.5, 64, 2)
        villager.health = 4
        world.addEntity(villager)
        world.setBlock(0, 65, 1, Int(cell(B.stone)))

        XCTAssertEqual(rpgCastPreparedSpell(player, spellID: "mend_wounds").failure,
                       .noTarget("mend_wounds"))
        XCTAssertEqual(player.health, 5)
        XCTAssertEqual(villager.health, 4)

        world.removeEntity(villager)
        world.setBlock(0, 65, 1, 0)
        guard case .success = rpgCastPreparedSpell(player, spellID: "mend_wounds") else {
            return XCTFail("self fallback should heal when no entity is targeted")
        }
        XCTAssertGreaterThan(player.health, 5)
    }

    func testAnchorLinePreservesInvalidHostileTargetFailure() {
        let world = makeWorld(seed: 205)
        let player = makeMasteredPlayer(in: world, pathID: "warden", starter: "guard_stance",
                                        preparedSkill: "anchor_line")
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 3)
        world.addEntity(zombie)
        XCTAssertEqual(rpgUsePreparedSkill(player, skillID: "anchor_line").failure,
                       .invalidTarget("anchor_line"))
    }

    func testShadowStepRejectsFloorChangedAfterPrepare() throws {
        let world = makeWorld(dim: .nether, seed: 206)
        let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "minor_glamour",
                                        preparedSpell: "shadow_step")
        world.setBlock(0, 64, 3, Int(cell(B.stone)))
        world.setBlock(0, 65, 4, Int(cell(B.stone)))
        let before = player.rpg
        let prepared = try XCTUnwrap(tryPrepare(player, kind: .spell, id: "shadow_step"))
        world.setBlock(0, 64, 3, 0)

        XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
        XCTAssertEqual(player.rpg, before)
        XCTAssertEqual(player.z, 0.5)
    }

    func testShadowStepRejectsDestinationHeadroomChangedAfterPrepare() throws {
        let world = makeWorld(dim: .nether, seed: 214)
        let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "minor_glamour",
                                        preparedSpell: "shadow_step")
        world.setBlock(0, 64, 3, Int(cell(B.stone)))
        world.setBlock(0, 65, 4, Int(cell(B.stone)))
        let before = player.rpg
        let prepared = try XCTUnwrap(tryPrepare(player, kind: .spell, id: "shadow_step"))
        world.setBlock(0, 66, 3, Int(cell(B.stone)))

        XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
        XCTAssertEqual(player.rpg, before)
    }

    func testSummonServantRejectsEntityEnteringSpawnAABB() throws {
        let world = makeWorld(seed: 207)
        let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                        preparedSpell: "summon_servant")
        let before = player.rpg
        let prepared = try XCTUnwrap(tryPrepare(player, kind: .spell, id: "summon_servant"))
        let cow = Cow(world: world)
        cow.setPos(0.5, 64, 2.5)
        world.addEntity(cow)

        XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
        XCTAssertEqual(player.rpg, before)
        XCTAssertFalse(world.entities.contains { $0 is Allay })
    }

    func testDiscoveryKeysUseRollingStableSixtyFourEntryRing() {
        var state = makeState(pathID: "ranger", starter: "trail_sense")
        for i in 0...RPG_MAX_XP_EVENT_KEYS {
            let report = rpgAwardXPEvent(RPGXPEvent(kind: .rangerFieldDiscovery,
                                                     key: "field:0:\(i):0"),
                                         simulationTick: i * RPG_XP_WINDOW_TICKS,
                                         worldDay: i / 20, to: &state)
            XCTAssertEqual(report.awardedXP, 3)
        }
        XCTAssertEqual(state.xpLedger.recentKeys.count, RPG_MAX_XP_EVENT_KEYS)
        XCTAssertFalse(state.xpLedger.recentKeys.contains("field:0:0:0"))
        XCTAssertEqual(state.xpLedger.recentKeys.first, "field:0:1:0")
        let beforeBackward = state
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .rangerFieldDiscovery,
                                                  key: "field:backward"),
                                       simulationTick: 1, worldDay: 0, to: &state).awardedXP, 0)
        XCTAssertEqual(state, beforeBackward)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .rangerFieldDiscovery,
                                                  key: "field:0:0:0"),
                                       simulationTick: 100_000, worldDay: 9, to: &state).awardedXP, 3)
    }

    func testActionBatchAtLastNormalRevisionAwardsBothHealEventsOnce() {
        let world = makeWorld(seed: 208)
        let player = makeMasteredPlayer(in: world, pathID: "mender", starter: "field_dressing",
                                        preparedSpell: "mend_wounds")
        player.rpg.xp = 0
        player.rpg.level = 1
        player.rpg = repairRPGCharacterState(player.rpg)
        player.rpg.fatigue = rpgDerivedStats(player.rpg).maxFatigue
        player.rpg.authorityRevision = RPG_MAX_COUNTER - 2
        let villager = Villager(world: world)
        villager.setPos(0.5, 64, 1.5)
        villager.health = 12
        world.addEntity(villager)
        let zombie = Zombie(world: world)
        zombie.setPos(4.5, 64, 4.5)
        world.addEntity(zombie)
        XCTAssertTrue(villager.hurt(8, "mob", zombie))
        XCTAssertEqual(villager.health, 4, accuracy: 0.000_001)
        XCTAssertNotNil(villager.validRPGMenderInjury(at: world.rpgSimulationTick))
        let beforeXP = player.rpg.xp

        guard case .success = rpgCastPreparedSpell(player, spellID: "mend_wounds") else {
            return XCTFail("last normal action should still commit")
        }
        XCTAssertEqual(player.rpg.authorityRevision, RPG_MAX_NORMAL_AUTHORITY_REVISION)
        XCTAssertGreaterThanOrEqual(player.rpg.xp - beforeXP, 6)
        XCTAssertEqual(player.rpg.xpLedger.counts.heal, 2)
    }

    func testGeneratedLootAwardsOnceClearsProvenanceAndCreativeNeverAwards() {
        let world = makeWorld(seed: 209)
        let delver = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye")
        delver.rpg = makeState(pathID: "delver", starter: "salvage_eye")
        let be = makeContainerBE(1, 64, 1, 27)
        be.lootTable = "dungeon"
        be.lootSeed = 9
        be.rpgGeneratedContainerKey = "generated:0:1:64:1"
        world.setBlockEntity(be)
        let before = delver.rpg.xp
        resolveLoot(world, be, discoveredBy: delver)
        XCTAssertEqual(delver.rpg.xp - before, 12)
        XCTAssertNil(be.lootTable)
        XCTAssertNil(be.lootSeed)
        XCTAssertNil(be.rpgGeneratedContainerKey)
        let once = delver.rpg
        resolveLoot(world, be, discoveredBy: delver)
        XCTAssertEqual(delver.rpg, once)

        let creative = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye")
        creative.setGameMode(GameMode.creative)
        let creativeBE = makeContainerBE(2, 64, 2, 27)
        creativeBE.lootTable = "dungeon"
        creativeBE.lootSeed = 10
        creativeBE.rpgGeneratedContainerKey = "generated:0:2:64:2"
        world.setBlockEntity(creativeBE)
        let creativeBefore = creative.rpg
        resolveLoot(world, creativeBE, discoveredBy: creative)
        XCTAssertEqual(creative.rpg, creativeBefore)
    }

    func testTemporaryCleanupExplosionWardAndSanctuaryHostilePolicy() {
        let world = makeWorld(seed: 210)
        world.setBlock(1, 64, 1, Int(cell(B.torch)))
        let guarded = RPGGuardedTemporaryBlock(position: RPGBlockPosition(1, 64, 1),
                                               originalCell: 0, temporaryCell: Int(cell(B.torch)))
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .mageLight, ownerAuthorityID: "owner", ownerEntityID: nil,
            ownerSequence: 1, center: RPGBlockPosition(1, 64, 1), durationTicks: 100,
            guardedBlock: guarded)))
        world.cancelRPGTemporaryEffects(ownerID: "owner")
        XCTAssertEqual(world.getBlock(1, 64, 1), 0)

        world.setBlock(4, 64, 4, Int(cell(B.stone)))
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .ward, ownerAuthorityID: "warder", ownerEntityID: nil,
            ownerSequence: 2, center: RPGBlockPosition(4, 64, 4), radius: 0,
            durationTicks: 100, remainingCharges: 1)))
        explode(world, 4.5, 64.5, 4.5, 5, false, TNTEntity(world: world))
        XCTAssertEqual(world.getBlock(4, 64, 4) >> 4, Int(B.stone))

        let zombie = Zombie(world: world)
        zombie.setPos(8.5, 64, 9.5)
        let cow = Cow(world: world)
        cow.setPos(9.5, 64, 8.5)
        world.addEntity(zombie)
        world.addEntity(cow)
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .sanctuary, ownerAuthorityID: "mender", ownerEntityID: nil,
            ownerSequence: 3, center: RPGBlockPosition(8, 64, 8), radius: 4,
            durationTicks: 100)))
        world.rpgSimulationTick = 20
        world.tickRPGTemporaryEffects()
        XCTAssertTrue(zombie.hasEffect("weakness"))
        XCTAssertFalse(zombie.hasEffect("slowness"))
        XCTAssertFalse(zombie.hasEffect("glowing"))
        XCTAssertFalse(cow.hasEffect("weakness"))
        XCTAssertEqual(zombie.effects.first(where: { $0.id == "weakness" })?.duration, 40)
        world.rpgSimulationTick = 21
        world.tickRPGTemporaryEffects()
        XCTAssertEqual(zombie.effects.first(where: { $0.id == "weakness" })?.duration, 40,
                       "sanctuary pulses must follow the global RPG clock cadence")
    }

    func testControlledChargeOwnershipTransfersForDirectAndChainPriming() {
        let world = makeWorld(seed: 211)
        let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "charge_pack")
        let ownPosition = RPGBlockPosition(3, 64, 3)
        registerControlledCharge(world, player: player, position: ownPosition, sequence: 1)
        igniteTNT(world, ownPosition.x, ownPosition.y, ownPosition.z)
        let ownTNT = world.entities.compactMap { $0 as? TNTEntity }.first
        XCTAssertEqual(ownTNT?.rpgControlledChargeOwnerEntityID, player.id)
        XCTAssertEqual(ownTNT?.rpgControlledChargeOwnerAuthorityID, player.effectiveRPGAuthorityID)
        XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        let ownMultiplier = rpgIncomingDamageMultiplier(player, source: "explosion", attacker: ownTNT)
        let foreignMultiplier = rpgIncomingDamageMultiplier(player, source: "explosion",
                                                            attacker: TNTEntity(world: world))
        XCTAssertLessThan(ownMultiplier, foreignMultiplier)

        let chainPosition = RPGBlockPosition(8, 64, 8)
        registerControlledCharge(world, player: player, position: chainPosition, sequence: 2)
        explode(world, 8.5, 64.5, 8.5, 5, false, TNTEntity(world: world))
        XCTAssertTrue(world.entities.compactMap { $0 as? TNTEntity }.contains {
            $0.rpgControlledChargeOwnerEntityID == player.id
                && $0.rpgControlledChargeOwnerAuthorityID == player.effectiveRPGAuthorityID
        })
        XCTAssertFalse(world.rpgTemporaryEffects.contains { $0.draft.kind == .controlledCharge })
    }

    func testSafeFuseRequiresLineOfSightToOwnedCharge() {
        let world = makeWorld(seed: 212)
        let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "charge_pack",
                                        preparedSkill: "safe_fuse")
        let position = RPGBlockPosition(0, 65, 4)
        registerControlledCharge(world, player: player, position: position, sequence: 1)
        world.setBlock(0, 65, 2, Int(cell(B.stone)))
        XCTAssertEqual(rpgUsePreparedSkill(player, skillID: "safe_fuse").failure,
                       .noTarget("safe_fuse"))
        world.setBlock(0, 65, 2, 0)
        guard case .success = rpgUsePreparedSkill(player, skillID: "safe_fuse") else {
            return XCTFail("visible charge should be defused")
        }
        XCTAssertFalse(world.rpgTemporaryEffects.contains { $0.draft.kind == .controlledCharge })
        XCTAssertEqual(world.getBlock(position.x, position.y, position.z), 0)
    }

    func testCreativeGameplayXPEntryPointLeavesStateExactlyUnchanged() {
        let world = makeWorld(seed: 213)
        let ranger = makeMasteredPlayer(in: world, pathID: "ranger", starter: "trail_sense")
        ranger.setGameMode(GameMode.creative)
        let before = ranger.rpg
        XCTAssertEqual(ranger.awardRPGXP(RPGXPEvent(kind: .rangerFieldDiscovery,
                                                    key: "field:0:0:0")).awardedXP, 0)
        XCTAssertEqual(ranger.rpg, before)
    }

    func testCausalMitigationAndDelayedSpellFireAwardOnlyOwningClass() {
        let world = makeWorld(seed: 215)
        let warden = Player(world: world)
        warden.rpg = makeState(pathID: "warden", starter: "guard_stance")
        world.addEntity(warden)
        let ally = Villager(world: world)
        world.addEntity(ally)
        ally.grantRPGWardenAbsorption(4, owner: warden, sequence: 7)
        let meleeHostile = Zombie(world: world)
        meleeHostile.setPos(2.5, 64, 2.5)
        world.addEntity(meleeHostile)
        XCTAssertTrue(ally.hurt(3, "mob", meleeHostile))
        XCTAssertEqual(warden.rpg.xp, 2)

        let arcanist = Player(world: world)
        arcanist.rpg = makeState(pathID: "arcanist", starter: "spell_formula")
        world.addEntity(arcanist)
        let target = Zombie(world: world)
        target.health = 1
        target.rpgArcanistFireOwner = arcanist
        target.rpgArcanistFireExpiryTick = 100
        world.addEntity(target)
        XCTAssertTrue(target.hurtFromPeriodicFire(1))
        XCTAssertEqual(arcanist.rpg.xp, 10)
    }

    func testHostileInjuryProvenanceTracksOnlyOutstandingAuthoritativeHarm() {
        let world = makeWorld(seed: 217)
        world.rpgSimulationTick = 100
        let villager = Villager(world: world)
        villager.setPos(0.5, 64, 1.5)
        world.addEntity(villager)
        let zombie = Zombie(world: world)
        zombie.setPos(3.5, 64, 3.5)
        world.addEntity(zombie)

        XCTAssertTrue(villager.hurt(5, "mob", zombie))
        var token = villager.validRPGMenderInjury(at: 100)
        XCTAssertEqual(token?.nonce, 1)
        XCTAssertEqual(token?.remaining ?? -1, 5, accuracy: 0.000_001)
        XCTAssertEqual(villager.rpgMenderInjuryExpiryTick, 100 + RPG_XP_WINDOW_TICKS)

        world.rpgSimulationTick = 200
        villager.invulnTicks = 0
        XCTAssertTrue(villager.hurt(3, "mob", zombie))
        token = villager.validRPGMenderInjury(at: 200)
        XCTAssertEqual(token?.nonce, 1, "later hostile hits refresh one active token")
        XCTAssertEqual(token?.remaining ?? -1, 8, accuracy: 0.000_001)
        XCTAssertEqual(villager.rpgMenderInjuryExpiryTick, 200 + RPG_XP_WINDOW_TICKS)

        villager.invulnTicks = 0
        XCTAssertTrue(villager.hurt(2, "fall", nil))
        XCTAssertEqual(villager.validRPGMenderInjury(at: 200)?.remaining, 8,
                       "unrelated damage neither adds nor clears hostile provenance")
        villager.heal(3)
        XCTAssertEqual(villager.validRPGMenderInjury(at: 200)?.remaining, 5,
                       "ordinary healing consumes the oldest outstanding hostile harm")
        villager.heal(5)
        XCTAssertNil(villager.validRPGMenderInjury(at: 200))
        XCTAssertEqual(villager.rpgMenderInjuryNonce, 0)
        XCTAssertEqual(villager.rpgMenderInjuryGeneration, 1)

        let absorbed = Villager(world: world)
        absorbed.setPos(2.5, 64, 1.5)
        absorbed.absorption = 8
        world.addEntity(absorbed)
        XCTAssertTrue(absorbed.hurt(5, "mob", zombie))
        XCTAssertNil(absorbed.validRPGMenderInjury(at: 200),
                     "absorption-only hits create no health-loss token")

        let partiallyAbsorbed = Villager(world: world)
        partiallyAbsorbed.setPos(2.5, 64, 2.5)
        partiallyAbsorbed.absorption = 2
        world.addEntity(partiallyAbsorbed)
        XCTAssertTrue(partiallyAbsorbed.hurt(5, "mob", zombie))
        XCTAssertEqual(partiallyAbsorbed.validRPGMenderInjury(at: 200)?.remaining ?? -1,
                       3, accuracy: 0.000_001,
                       "only post-absorption health loss is eligible hostile harm")

        let cow = Cow(world: world)
        cow.setPos(4.5, 64, 4.5)
        world.addEntity(cow)
        let passiveVictim = Villager(world: world)
        passiveVictim.setPos(3.5, 64, 1.5)
        world.addEntity(passiveVictim)
        XCTAssertTrue(passiveVictim.hurt(2, "mob", cow))
        XCTAssertNil(passiveVictim.validRPGMenderInjury(at: 200))

        let playerAttacker = Player(world: world)
        playerAttacker.setPos(5.5, 64, 5.5)
        world.addEntity(playerAttacker)
        passiveVictim.invulnTicks = 0
        XCTAssertTrue(passiveVictim.hurt(2, "player", playerAttacker))
        XCTAssertNil(passiveVictim.validRPGMenderInjury(at: 200))

        let detachedVictim = Villager(world: world)
        XCTAssertTrue(detachedVictim.hurt(2, "mob", zombie))
        XCTAssertNil(detachedVictim.validRPGMenderInjury(at: 200))
        let detachedHostile = Zombie(world: world)
        passiveVictim.invulnTicks = 0
        XCTAssertTrue(passiveVictim.hurt(2, "mob", detachedHostile))
        XCTAssertNil(passiveVictim.validRPGMenderInjury(at: 200))

        let removedHostile = Zombie(world: world)
        removedHostile.setPos(5.5, 64, 4.5)
        world.addEntity(removedHostile)
        world.removeEntity(removedHostile)
        passiveVictim.invulnTicks = 0
        XCTAssertTrue(passiveVictim.hurt(2, "mob", removedHostile))
        XCTAssertNil(passiveVictim.validRPGMenderInjury(at: 200),
                     "a removed hostile cannot mint provenance")
        let deadHostile = Zombie(world: world)
        deadHostile.setPos(5.5, 64, 3.5)
        world.addEntity(deadHostile)
        deadHostile.dead = true
        passiveVictim.invulnTicks = 0
        XCTAssertTrue(passiveVictim.hurt(2, "mob", deadHostile))
        XCTAssertNil(passiveVictim.validRPGMenderInjury(at: 200),
                     "a dead hostile cannot mint provenance")

        let malformed = Villager(world: world)
        malformed.setPos(6.5, 64, 1.5)
        world.addEntity(malformed)
        malformed.health = 19
        malformed.rpgMenderInjuryGeneration = 1
        malformed.rpgMenderInjuryNonce = 2
        malformed.rpgMenderInjuryExpiryTick = 300
        malformed.rpgMenderInjuryRemaining = 1
        XCTAssertNil(malformed.validRPGMenderInjury(at: 200))
        malformed.rpgMenderInjuryNonce = 1
        malformed.rpgMenderInjuryExpiryTick = 200 + RPG_XP_WINDOW_TICKS + 1
        XCTAssertNil(malformed.validRPGMenderInjury(at: 200))
        malformed.rpgMenderInjuryExpiryTick = 300
        malformed.health = malformed.maxHealth
        XCTAssertNil(malformed.validRPGMenderInjury(at: 200))
        malformed.health = .infinity
        XCTAssertNil(malformed.validRPGMenderInjury(at: 200))
        malformed.health = 19
        malformed.rpgMenderInjuryRemaining = 2
        XCTAssertNil(malformed.validRPGMenderInjury(at: 200),
                     "remaining harm cannot exceed the target's missing health")

        let expiring = Villager(world: world)
        expiring.setPos(7.5, 64, 2.5)
        world.addEntity(expiring)
        XCTAssertTrue(expiring.hurt(2, "mob", zombie))
        let firstExpiry = expiring.rpgMenderInjuryExpiryTick
        XCTAssertEqual(expiring.rpgMenderInjuryGeneration, 1)
        world.rpgSimulationTick = firstExpiry
        XCTAssertNil(expiring.validRPGMenderInjury(at: firstExpiry),
                     "the strict expiry boundary is already expired")
        expiring.invulnTicks = 0
        XCTAssertTrue(expiring.hurt(1, "mob", zombie))
        XCTAssertEqual(expiring.rpgMenderInjuryGeneration, 2)
        XCTAssertEqual(expiring.rpgMenderInjuryNonce, 2,
                       "post-expiry hostile harm starts a fresh generation")
        XCTAssertEqual(expiring.rpgMenderInjuryExpiryTick,
                       firstExpiry + RPG_XP_WINDOW_TICKS)

        world.gameRules[RPG_CLASSES_GAME_RULE] = 0
        let disabledVictim = Villager(world: world)
        disabledVictim.setPos(7.5, 64, 1.5)
        world.addEntity(disabledVictim)
        XCTAssertTrue(disabledVictim.hurt(2, "mob", zombie))
        world.gameRules[RPG_CLASSES_GAME_RULE] = 1
        XCTAssertNil(disabledVictim.validRPGMenderInjury(at: world.rpgSimulationTick))
    }

    func testMenderSupportXPIsCausalCappedAndTransactionallyConsumed() throws {
        do {
            let world = makeWorld(seed: 218)
            let mender = makeLevelOneMender(in: world, spell: "mend_wounds")
            let ally = Villager(world: world)
            ally.setPos(0.5, 64, 1.5)
            world.addEntity(ally)
            let hostile = Zombie(world: world)
            hostile.setPos(4.5, 64, 4.5)
            world.addEntity(hostile)
            XCTAssertTrue(ally.hurt(5, "mob", hostile))
            let beforeRevision = mender.rpg.authorityRevision

            guard case .success = rpgCastPreparedSpell(mender, spellID: "mend_wounds") else {
                return XCTFail("causal Mend Wounds should commit")
            }
            XCTAssertEqual(mender.rpg.xp, 2, "floor(5 causal health) / 2")
            XCTAssertEqual(mender.rpg.authorityRevision, beforeRevision + 1,
                           "action and support XP publish one revision")
            XCTAssertNil(ally.validRPGMenderInjury(at: world.rpgSimulationTick))
            XCTAssertEqual(ally.rpgMenderInjuryNonce, 0)
            XCTAssertEqual(ally.rpgMenderInjuryGeneration, 1)
        }

        do {
            let world = makeWorld(seed: 219)
            let mender = makeLevelOneMender(in: world, spell: "mend_wounds")
            for index in 0..<RPGXPEventCategory.heal.windowLimit {
                XCTAssertEqual(mender.awardRPGXP(RPGXPEvent(
                    kind: .menderProvisionCraft, key: "cap:\(index)"
                )).awardedXP, 6)
            }
            let ally = Villager(world: world)
            ally.setPos(0.5, 64, 1.5)
            world.addEntity(ally)
            let hostile = Zombie(world: world)
            hostile.setPos(4.5, 64, 4.5)
            world.addEntity(hostile)
            XCTAssertTrue(ally.hurt(10, "mob", hostile))
            let beforeXP = mender.rpg.xp
            let healthBefore = ally.health
            guard case .success = rpgCastPreparedSpell(mender, spellID: "mend_wounds") else {
                return XCTFail("category cap suppresses XP, not the heal")
            }
            let effective = ally.health - healthBefore
            XCTAssertEqual(mender.rpg.xp, beforeXP)
            let expectedRemaining = max(0, 10 - effective)
            XCTAssertEqual(ally.rpgMenderInjuryRemaining, expectedRemaining, accuracy: 0.000_001)
            if expectedRemaining > 0.000_001 {
                XCTAssertNotEqual(ally.rpgMenderInjuryNonce, 0,
                                  "a capped heal retains only its genuinely unhealed remainder")
            } else {
                XCTAssertEqual(ally.rpgMenderInjuryNonce, 0)
            }
        }

        do {
            let world = makeWorld(seed: 220)
            let mender = makeLevelOneMender(in: world, spell: "mend_wounds")
            let ally = Villager(world: world)
            ally.setPos(0.5, 64, 1.5)
            world.addEntity(ally)
            let hostile = Zombie(world: world)
            hostile.setPos(4.5, 64, 4.5)
            world.addEntity(hostile)
            XCTAssertTrue(ally.hurt(5, "mob", hostile))
            let prepared = try XCTUnwrap(tryPrepare(mender, kind: .spell, id: "mend_wounds"))
            let rpgBefore = mender.rpg
            let healthBefore = ally.health
            let nonce = ally.rpgMenderInjuryNonce
            ally.rpgMenderInjuryExpiryTick -= 1

            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: mender).failure, .staleMutation)
            XCTAssertEqual(mender.rpg, rpgBefore)
            XCTAssertEqual(ally.health, healthBefore)
            XCTAssertEqual(ally.rpgMenderInjuryNonce, nonce)
            XCTAssertGreaterThan(ally.rpgMenderInjuryRemaining, 0)
        }

        do {
            let world = makeWorld(seed: 221)
            let mender = makeLevelOneMender(in: world, spell: "mend_wounds")
            let ally = Villager(world: world)
            ally.setPos(0.5, 64, 1.5)
            world.addEntity(ally)
            ally.health = 5
            ally.invulnTicks = 0
            XCTAssertTrue(ally.hurt(1, "fall", nil))
            let hostile = Zombie(world: world)
            hostile.setPos(4.5, 64, 4.5)
            world.addEntity(hostile)
            ally.invulnTicks = 0
            XCTAssertTrue(ally.hurt(1, "mob", hostile))
            guard case .success = rpgCastPreparedSpell(mender, spellID: "mend_wounds") else {
                return XCTFail("heal itself should remain usable")
            }
            XCTAssertEqual(mender.rpg.xp, 0,
                           "one causal health cannot forge healing or threshold-crossing XP")
            XCTAssertNil(ally.validRPGMenderInjury(at: world.rpgSimulationTick))
        }

        do {
            let world = makeWorld(seed: 223)
            let mender = makeRestoreMender(in: world)
            let ally = Villager(world: world)
            ally.setPos(0.5, 64, 1.5)
            world.addEntity(ally)
            let hostile = Zombie(world: world)
            hostile.setPos(4.5, 64, 4.5)
            world.addEntity(hostile)
            XCTAssertTrue(ally.hurt(16, "mob", hostile))
            ally.addEffect("poison", 200, 0)
            let beforeXP = mender.rpg.xp
            let healthBefore = ally.health

            let restore = rpgCastPreparedSpell(mender, spellID: "restore")
            guard case .success = restore else {
                if case .failure(let failure) = restore {
                    return XCTFail("causal Restore should heal, cleanse, and rescue: \(failure)")
                }
                return XCTFail("causal Restore should heal, cleanse, and rescue")
            }
            let effective = ally.health - healthBefore
            XCTAssertGreaterThan(healthBefore + effective, ally.maxHealth * 0.25)
            XCTAssertFalse(ally.hasEffect("poison"))
            XCTAssertEqual(mender.rpg.xp - beforeXP,
                           4 + min(8, Int(effective.rounded(.down)) / 2),
                           "cleanse and rescue share one fixed four-XP event")
            XCTAssertEqual(mender.rpg.xpLedger.recentKeys.filter {
                $0.hasPrefix("support:")
            }.count, 1)
            XCTAssertNil(ally.validRPGMenderInjury(at: world.rpgSimulationTick))
        }

        for (index, damage) in [5.0, 19.0].enumerated() {
            let world = makeWorld(seed: UInt32(224 + index))
            let mender = makeLevelOneMender(in: world, spell: "mend_wounds")
            let ally = Villager(world: world)
            ally.setPos(0.5, 64, 1.5)
            world.addEntity(ally)
            let hostile = Zombie(world: world)
            hostile.setPos(4.5, 64, 4.5)
            world.addEntity(hostile)
            XCTAssertTrue(ally.hurt(damage, "mob", hostile))
            let prepared = try XCTUnwrap(tryPrepare(mender, kind: .spell, id: "mend_wounds"))
            XCTAssertNil(rpgCommitPreparedAction(prepared, for: mender).failure)
            let rpgAfter = mender.rpg
            let healthAfter = ally.health
            let nonceAfter = ally.rpgMenderInjuryNonce
            let remainingAfter = ally.rpgMenderInjuryRemaining

            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: mender).failure,
                           .staleMutation)
            XCTAssertEqual(mender.rpg, rpgAfter)
            XCTAssertEqual(ally.health, healthAfter)
            XCTAssertEqual(ally.rpgMenderInjuryNonce, nonceAfter)
            XCTAssertEqual(ally.rpgMenderInjuryRemaining, remainingAfter,
                           accuracy: 0.000_001,
                           "replay cannot duplicate either a full or partial heal")
        }
    }

    func testWardenMitigationLayersPreserveOwnersOrderAndCapacityAtomically() {
        let world = makeWorld(seed: 222)
        let first = Player(world: world)
        first.rpg = makeState(pathID: "warden", starter: "guard_stance")
        first.setPos(0.5, 64, 0.5)
        world.addEntity(first)
        let second = Player(world: world)
        second.rpg = makeState(pathID: "warden", starter: "guard_stance")
        second.setPos(1.5, 64, 0.5)
        world.addEntity(second)
        let ally = Villager(world: world)
        ally.setPos(0.5, 64, 2.5)
        world.addEntity(ally)
        let hostile = Zombie(world: world)
        hostile.setPos(4.5, 64, 4.5)
        world.addEntity(hostile)

        XCTAssertTrue(ally.grantRPGWardenAbsorption(2, owner: first, sequence: 1))
        XCTAssertTrue(ally.grantRPGWardenAbsorption(4, owner: second, sequence: 2))
        XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots.map(\.ownerEntityID),
                       [first.id, second.id])
        XCTAssertTrue(ally.hurt(3, "mob", hostile))
        XCTAssertEqual(first.rpg.xp, 2)
        XCTAssertEqual(second.rpg.xp, 0)
        XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots.first?.hostileAbsorbed ?? -1, 1,
                       accuracy: 0.000_001)
        ally.invulnTicks = 0
        XCTAssertTrue(ally.hurt(1, "mob", hostile))
        XCTAssertEqual(second.rpg.xp, 2)
        XCTAssertTrue(ally.rpgWardenMitigationLayerSnapshots.isEmpty)

        let sameOwner = Villager(world: world)
        sameOwner.setPos(2.5, 64, 2.5)
        world.addEntity(sameOwner)
        XCTAssertTrue(sameOwner.grantRPGWardenAbsorption(2, owner: first, sequence: 3))
        XCTAssertTrue(sameOwner.grantRPGWardenAbsorption(4, owner: first, sequence: 4))
        XCTAssertEqual(sameOwner.rpgWardenMitigationLayerSnapshots.count, 2,
                       "same-owner top-ups remain separate causal events")

        let mixed = Villager(world: world)
        mixed.setPos(3.5, 64, 2.5)
        world.addEntity(mixed)
        XCTAssertTrue(mixed.grantRPGWardenAbsorption(4, owner: first, sequence: 5))
        let cow = Cow(world: world)
        cow.setPos(5.5, 64, 5.5)
        world.addEntity(cow)
        let xpBeforeMixed = first.rpg.xp
        XCTAssertTrue(mixed.hurt(1, "mob", cow))
        mixed.invulnTicks = 0
        XCTAssertTrue(mixed.hurt(1, "mob", hostile))
        XCTAssertEqual(first.rpg.xp, xpBeforeMixed)
        mixed.invulnTicks = 0
        XCTAssertTrue(mixed.hurt(1, "mob", hostile))
        XCTAssertEqual(first.rpg.xp, xpBeforeMixed + 2)

        let capped = Villager(world: world)
        capped.setPos(0.5, 64, 3.5)
        world.addEntity(capped)
        for index in 1...8 {
            XCTAssertTrue(capped.grantRPGWardenAbsorption(Double(index) * 0.25,
                                                          owner: first, sequence: 10 + index))
        }
        XCTAssertEqual(capped.rpgWardenMitigationLayerSnapshots.count, 8)
        XCTAssertFalse(capped.canGrantRPGWardenAbsorption(3, owner: first))

        let interposer = makeMasteredPlayer(in: world, pathID: "warden",
                                            starter: "guard_stance",
                                            preparedSkill: "interpose")
        interposer.setPos(0.5, 64, 4.5)
        capped.setPos(0.5, 64, 5.5)
        let stateBefore = interposer.rpg
        let absorptionBefore = interposer.absorption
        let cappedBefore = capped.rpgWardenMitigationLayerSnapshots
        XCTAssertEqual(rpgUsePreparedSkill(interposer, skillID: "interpose").failure,
                       .boundedStateLimit)
        XCTAssertEqual(interposer.rpg, stateBefore)
        XCTAssertEqual(interposer.absorption, absorptionBefore)
        XCTAssertEqual(capped.rpgWardenMitigationLayerSnapshots, cappedBefore)
        XCTAssertFalse(interposer.hasEffect("resistance"))

        let creativeOwner = Player(world: world)
        creativeOwner.rpg = makeState(pathID: "warden", starter: "guard_stance")
        creativeOwner.setPos(6.5, 64, 6.5)
        creativeOwner.setGameMode(GameMode.creative)
        world.addEntity(creativeOwner)
        let creativeAlly = Villager(world: world)
        creativeAlly.setPos(6.5, 64, 2.5)
        world.addEntity(creativeAlly)
        XCTAssertTrue(creativeAlly.grantRPGWardenAbsorption(4, owner: creativeOwner, sequence: 30))
        XCTAssertTrue(creativeAlly.rpgWardenMitigationLayerSnapshots.isEmpty)
        creativeOwner.setGameMode(GameMode.survival)
        XCTAssertTrue(creativeAlly.hurt(3, "mob", hostile))
        XCTAssertEqual(creativeOwner.rpg.xp, 0)

        let preexisting = Villager(world: world)
        preexisting.setPos(7.5, 64, 2.5)
        preexisting.absorption = 3
        world.addEntity(preexisting)
        let beforePreexistingXP = first.rpg.xp
        XCTAssertTrue(preexisting.grantRPGWardenAbsorption(7, owner: first, sequence: 31))
        XCTAssertTrue(preexisting.hurt(3, "mob", hostile))
        XCTAssertEqual(first.rpg.xp, beforePreexistingXP)
        XCTAssertEqual(preexisting.rpgWardenMitigationLayerSnapshots.first?.remaining ?? -1,
                       4, accuracy: 0.000_001,
                       "unrelated absorption is consumed before a Warden layer")
        preexisting.invulnTicks = 0
        XCTAssertTrue(preexisting.hurt(2, "mob", hostile))
        XCTAssertEqual(first.rpg.xp, beforePreexistingXP + 2)

        let doomedOwner = Player(world: world)
        doomedOwner.rpg = makeState(pathID: "warden", starter: "guard_stance")
        doomedOwner.setPos(7.5, 64, 0.5)
        world.addEntity(doomedOwner)
        let doomedAlly = Villager(world: world)
        doomedAlly.setPos(7.5, 64, 1.5)
        world.addEntity(doomedAlly)
        XCTAssertTrue(doomedAlly.grantRPGWardenAbsorption(4, owner: doomedOwner, sequence: 32))
        XCTAssertTrue(doomedAlly.hurt(1, "mob", hostile))
        doomedOwner.dead = true
        doomedAlly.invulnTicks = 0
        XCTAssertTrue(doomedAlly.hurt(1, "mob", hostile))
        XCTAssertEqual(doomedOwner.rpg.xp, 0,
                       "a dead owner cannot receive a delayed mitigation award")
        XCTAssertTrue(doomedAlly.rpgWardenMitigationLayerSnapshots.isEmpty)

        let disabledLayer = Villager(world: world)
        disabledLayer.setPos(6.5, 64, 3.5)
        world.addEntity(disabledLayer)
        XCTAssertTrue(disabledLayer.grantRPGWardenAbsorption(4, owner: first, sequence: 33))
        XCTAssertFalse(disabledLayer.rpgWardenMitigationLayerSnapshots.isEmpty)
        world.gameRules[RPG_CLASSES_GAME_RULE] = 0
        world.tickRPGTemporaryEffects()
        XCTAssertTrue(disabledLayer.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "disabling classes clears all causal mitigation layers")
        world.gameRules[RPG_CLASSES_GAME_RULE] = 1
    }

    func testGlobalEffectTickPrunesDeadAndRemovedWardenLayerOwners() {
        let world = makeWorld(seed: 229)
        let deadOwner = Player(world: world)
        deadOwner.rpg = makeState(pathID: "warden", starter: "guard_stance")
        world.addEntity(deadOwner)
        let cappedAlly = Villager(world: world)
        world.addEntity(cappedAlly)
        for sequence in 1...8 {
            XCTAssertTrue(cappedAlly.grantRPGWardenAbsorption(
                Double(sequence), owner: deadOwner, sequence: sequence
            ))
        }
        XCTAssertEqual(cappedAlly.rpgWardenMitigationLayerSnapshots.count, 8)

        deadOwner.dead = true
        world.tickRPGTemporaryEffects()

        XCTAssertTrue(cappedAlly.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "a dead owner cannot leave an idle layer consuming the bounded causal ledger")
        XCTAssertEqual(cappedAlly.absorption, 8, accuracy: 0.000_001,
                       "pruning provenance must preserve already-granted generic absorption")
        let replacement = Player(world: world)
        replacement.rpg = makeState(pathID: "warden", starter: "guard_stance")
        world.addEntity(replacement)
        XCTAssertTrue(cappedAlly.canGrantRPGWardenAbsorption(9, owner: replacement),
                      "dead-owner cleanup must release layer capacity for a legitimate grant")

        let authorityAlly = Villager(world: world)
        world.addEntity(authorityAlly)
        XCTAssertTrue(authorityAlly.grantRPGWardenAbsorption(4, owner: replacement,
                                                            sequence: 19))
        replacement.rpgAuthorityID = "changed-authority"
        world.tickRPGTemporaryEffects()
        XCTAssertTrue(authorityAlly.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "an authority identity change invalidates the old causal owner")
        XCTAssertEqual(authorityAlly.absorption, 4, accuracy: 0.000_001)

        let wrongWorldOwner = Player(world: world)
        wrongWorldOwner.rpg = makeState(pathID: "warden", starter: "guard_stance")
        world.addEntity(wrongWorldOwner)
        let wrongWorldAlly = Villager(world: world)
        world.addEntity(wrongWorldAlly)
        XCTAssertTrue(wrongWorldAlly.grantRPGWardenAbsorption(4, owner: wrongWorldOwner,
                                                             sequence: 20))
        let alternateWorld = World(dim: .nether, seed: 230)
        wrongWorldOwner.world = alternateWorld
        world.tickRPGTemporaryEffects()
        XCTAssertTrue(wrongWorldAlly.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "an owner moved to another world cannot retain old-world delayed XP")

        let detachedGhostAlly = Villager(world: world)
        world.addEntity(detachedGhostAlly)
        do {
            let detachedGhost = Player(world: world)
            detachedGhost.rpgAuthorityID = "lan:detached"
            detachedGhost.rpg = makeState(pathID: "warden", starter: "guard_stance")
            XCTAssertTrue(detachedGhostAlly.grantRPGWardenAbsorption(
                4, owner: detachedGhost, sequence: 21
            ))
        }
        world.tickRPGTemporaryEffects()
        XCTAssertTrue(detachedGhostAlly.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "a deallocated detached ghost cannot pin a causal layer")

        let removedOwner = Player(world: world)
        removedOwner.rpg = makeState(pathID: "warden", starter: "guard_stance")
        world.addEntity(removedOwner)
        let secondAlly = Villager(world: world)
        world.addEntity(secondAlly)
        XCTAssertTrue(secondAlly.grantRPGWardenAbsorption(4, owner: removedOwner,
                                                         sequence: 20))
        world.removeEntity(removedOwner)
        world.tickRPGTemporaryEffects()
        XCTAssertTrue(secondAlly.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "a removed owner cannot leave delayed-XP provenance behind")
        XCTAssertEqual(secondAlly.absorption, 4, accuracy: 0.000_001)
    }

    func testImmediateHostileHitAfterWardenOwnerRemovalCannotMintDelayedXP() {
        let world = makeWorld(seed: 232)
        let owner = Player(world: world)
        owner.rpg = makeState(pathID: "warden", starter: "guard_stance")
        owner.setPos(0.5, 64, 0.5)
        world.addEntity(owner)
        let ally = Villager(world: world)
        ally.setPos(0.5, 64, 1.5)
        world.addEntity(ally)
        let hostile = Zombie(world: world)
        hostile.setPos(0.5, 64, 3.5)
        world.addEntity(hostile)

        XCTAssertTrue(ally.grantRPGWardenAbsorption(4, owner: owner, sequence: 1))
        XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots.count, 1)
        world.removeEntity(owner)

        XCTAssertTrue(ally.hurt(2, "mob", hostile))
        XCTAssertEqual(owner.rpg.xp, 0,
                       "an owner removed immediately before damage is no longer a causal authority")
        XCTAssertTrue(ally.rpgWardenMitigationLayerSnapshots.isEmpty,
                      "damage admission must prune invalid provenance without waiting for a world tick")
        XCTAssertEqual(ally.absorption, 2, accuracy: 0.000_001,
                       "already-granted absorption remains ordinary defense after provenance expires")
    }

    func testWardenAdmissionPrunesDetachedOwnerCapacityAtClockCeiling() {
        let world = makeWorld(seed: 231)
        world.rpgSimulationTick = RPG_MAX_COUNTER
        let ally = Villager(world: world)
        world.addEntity(ally)
        do {
            let detachedGhost = Player(world: world)
            detachedGhost.rpgAuthorityID = "lan:ceiling-detached"
            detachedGhost.rpg = makeState(pathID: "warden", starter: "guard_stance")
            for sequence in 1...8 {
                XCTAssertTrue(ally.grantRPGWardenAbsorption(
                    Double(sequence), owner: detachedGhost, sequence: sequence
                ))
            }
            XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots.count, 8)
        }
        let replacement = Player(world: world)
        replacement.rpg = makeState(pathID: "warden", starter: "guard_stance")
        world.addEntity(replacement)

        let staleLayers = ally.rpgWardenMitigationLayerSnapshots
        XCTAssertTrue(ally.canGrantRPGWardenAbsorption(9, owner: replacement),
                      "admission must release detached provenance even when the clock cannot tick")
        XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots, staleLayers,
                       "the capacity predicate is preflight and must remain mutation-free")
        XCTAssertTrue(ally.grantRPGWardenAbsorption(9, owner: replacement, sequence: 9))
        XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots.count, 1)
        XCTAssertEqual(ally.rpgWardenMitigationLayerSnapshots.first?.ownerEntityID,
                       replacement.id)
        XCTAssertEqual(ally.absorption, 9, accuracy: 0.000_001,
                       "commit pruning preserves prior absorption before applying the new minimum")
    }

    func testRangerDiscoveryFirstRecipeAndPoweredMechanismUseExactKeys() {
        let world = makeWorld(seed: 216)
        let ranger = Player(world: world)
        ranger.rpg = makeState(pathID: "ranger", starter: "trail_sense")
        world.addEntity(ranger)
        rpgAwardCurrentChunkDiscovery(ranger)
        rpgAwardCurrentChunkDiscovery(ranger)
        XCTAssertEqual(ranger.rpg.xp, 3)
        world.setChunk(Chunk(cx: 1, cz: 0, minY: world.info.minY, height: world.info.height))
        ranger.setPos(16.5, 64, 0.5)
        rpgAwardCurrentChunkDiscovery(ranger)
        XCTAssertEqual(ranger.rpg.xp, 6)
        XCTAssertEqual(ranger.rpg.xpLedger.recentKeys.count, 2)

        let tinker = Player(world: world)
        tinker.rpg = makeState(pathID: "tinker", starter: "circuit_sense")
        world.addEntity(tinker)
        rpgAwardCraftedRecipe(tinker, recipeIndex: 0)
        rpgAwardCraftedRecipe(tinker, recipeIndex: 0)
        XCTAssertEqual(tinker.rpg.xp, 4)

        world.setBlock(2, 64, 2, Int(cell(B.lever)))
        world.setBlock(3, 64, 2, Int(cell(B.redstone_block)))
        rpgAwardPoweredMechanismPlacement(tinker, blockID: Int(B.lever), x: 2, y: 64, z: 2)
        rpgAwardPoweredMechanismPlacement(tinker, blockID: Int(B.lever), x: 2, y: 64, z: 2)
        XCTAssertEqual(tinker.rpg.xp, 6)
        XCTAssertTrue(tinker.rpg.xpLedger.recentKeys.contains("mechanism:0:2:64:2"))

        let creative = Player(world: world)
        creative.rpg = makeState(pathID: "tinker", starter: "circuit_sense")
        creative.setGameMode(GameMode.creative)
        rpgAwardCraftedRecipe(creative, recipeIndex: 1)
        XCTAssertEqual(creative.rpg.xp, 0)
    }

    private func tryPrepare(_ player: Player, kind: RPGPreparedActionKind,
                            id: String) -> RPGPreparedMutation? {
        switch rpgPrepareAction(player, kind: kind, id: id, authorization: .local(for: player)) {
        case .success(let prepared): return prepared
        case .failure(let failure):
            XCTFail("preflight failed: \(failure)")
            return nil
        }
    }

    private func makeWorld(dim: Dim = .overworld, seed: UInt32) -> World {
        let world = World(dim: dim, seed: seed)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height))
        return world
    }

    private func placeRayBlock(_ world: World, _ block: UInt16, meta: Int = 0) {
        world.setBlock(0, 65, 4, Int(cell(block, meta)))
    }

    private func makeState(pathID: String, starter: String) -> RPGCharacterState {
        try! rpgCreateCharacter(RPGCreationDraft(pathID: pathID,
                                                 attributes: rpgCreationPreset(pathID: pathID)!,
                                                 starterSkillID: starter)).get()
    }

    private func makeMasteredPlayer(in world: World,
                                    pathID: String,
                                    starter: String,
                                    preparedSkill: String? = nil,
                                    preparedSpell: String? = nil) -> Player {
        let player = Player(world: world)
        let starterSpell: [String]
        switch (pathID, starter) {
        case ("arcanist", "spell_formula"): starterSpell = ["ignite"]
        case ("arcanist", "minor_glamour"): starterSpell = ["blur"]
        case ("arcanist", "ritual_circle"): starterSpell = ["mage_light"]
        case ("mender", "field_dressing"): starterSpell = ["mend_wounds"]
        case ("mender", "herbal_lore"): starterSpell = ["purify"]
        case ("mender", "safe_haven"): starterSpell = ["ward"]
        default: starterSpell = []
        }
        XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(
            pathID: pathID, attributes: rpgCreationPreset(pathID: pathID)!,
            starterSkillID: starter, starterSpellIDs: starterSpell)))
        var state = player.rpg
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        state.level = RPG_LEVEL_CAP
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
        player.yaw = 0
        player.pitch = 0
        world.addEntity(player)
        return player
    }

    private func makeLevelOneMender(in world: World, spell: String) -> Player {
        let player = makeMasteredPlayer(in: world, pathID: "mender",
                                        starter: "field_dressing", preparedSpell: spell)
        var state = makeState(pathID: "mender", starter: "field_dressing")
        state.preparedSpellIDs = [spell]
        state.selectedPreparedSpellID = spell
        state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: spell)
        state = repairRPGCharacterState(state)
        state.fatigue = rpgDerivedStats(state).maxFatigue
        player.rpg = state
        return player
    }

    private func makeRestoreMender(in world: World) -> Player {
        let player = Player(world: world)
        var state = makeState(pathID: "mender", starter: "field_dressing")
        state.xp = rpgXPRequiredForLevel(10)
        state.level = 10
        state.attributes.intelligence += 1
        state.skillRanks["field_dressing"] = 2
        state.skillRanks["triage"] = 2
        state = repairRPGCharacterState(state)
        state.preparedSpellIDs = ["restore"]
        state.selectedPreparedSpellID = "restore"
        state.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: "restore")
        state = repairRPGCharacterState(state)
        state.fatigue = rpgDerivedStats(state).maxFatigue
        player.rpg = state
        player.inventory[0] = ItemStack(iid("apprentice_focus"), 1)
        player.selectedSlot = 0
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        world.addEntity(player)
        return player
    }

    private func registerControlledCharge(_ world: World, player: Player,
                                          position: RPGBlockPosition, sequence: Int) {
        world.setBlock(position.x, position.y, position.z, Int(cell(B.tnt)))
        let guarded = RPGGuardedTemporaryBlock(position: position, originalCell: 0,
                                               temporaryCell: Int(cell(B.tnt)))
        XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
            kind: .controlledCharge, ownerAuthorityID: player.effectiveRPGAuthorityID,
            ownerEntityID: player.id, ownerSequence: sequence, center: position,
            durationTicks: 200, guardedBlock: guarded)))
    }
}

private extension Result where Failure == RPGActionFailure {
    var failure: RPGActionFailure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
