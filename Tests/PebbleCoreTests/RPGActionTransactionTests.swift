import XCTest
@testable import PebbleCore

final class RPGActionTransactionTests: XCTestCase {
    // Entity.world is unowned. Retaining each fixture world for the complete
    // XCTest invocation prevents scoped sub-fixtures from releasing a world
    // before their local entity references are destroyed.
    private var retainedWorlds: [World] = []

    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllSystems()
    }

    func testMetadataIsAClosedBijectionOverNineteenActivesAndSeventeenSpells() {
        let activeDefinitions = RPG_SKILL_DEFINITIONS.filter { $0.kind == .active }.map(\.id)
        let activeMetadata = RPG_ACTIVE_ACTION_METADATA.map { $0.id.rawValue }
        XCTAssertEqual(activeDefinitions.count, 19)
        XCTAssertEqual(activeMetadata.count, 19)
        XCTAssertEqual(Set(activeMetadata), Set(activeDefinitions))
        XCTAssertEqual(activeMetadata.count, Set(activeMetadata).count)

        let spellDefinitions = RPG_SPELL_DEFINITIONS.map(\.id)
        let spellMetadata = RPG_SPELL_ACTION_METADATA.map { $0.id.rawValue }
        XCTAssertEqual(spellDefinitions.count, 17)
        XCTAssertEqual(spellMetadata.count, 17)
        XCTAssertEqual(Set(spellMetadata), Set(spellDefinitions))
        XCTAssertEqual(spellMetadata.count, Set(spellMetadata).count)

        for definition in RPG_SKILL_DEFINITIONS where definition.kind != .active {
            XCTAssertNil(rpgActionMetadata(kind: .skill, id: definition.id), definition.id)
        }
    }

    func testSuccessfulPreflightIsPureAcrossActorTargetItemsWorldAndFeedback() throws {
        let world = makeWorld(seed: 301)
        let player = makeMasteredPlayer(in: world, pathID: "warden", starter: "heavy_cut",
                                        preparedSkill: "heavy_cut")
        player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
        player.inventory[0] = ItemStack(iid("iron_sword"), 1)
        player.selectedSlot = 0
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 3.5)
        world.addEntity(zombie)
        world.setBlock(2, 64, 2, Int(cell(B.stone)))

        var blockChanges = 0
        var particles = 0
        var sounds = 0
        world.hooks.onBlockChanged = { _, _, _, _, _, _ in blockChanges += 1 }
        world.hooks.addParticles = { _, _, _, _, _, _, _ in particles += 1 }
        world.hooks.playSound = { _, _, _, _, _, _ in sounds += 1 }
        let ownerBefore = RPGEntityGuard.capture(player)
        let targetBefore = RPGEntityGuard.capture(zombie)
        let rpgBefore = player.rpg
        let itemsBefore = RPGPlayerItemsSnapshot.capture(player)
        let blockBefore = world.getBlock(2, 64, 2)
        let temporaryBefore = world.rpgTemporaryEffects

        _ = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "heavy_cut",
                                                authorization: .local(for: player)))

        XCTAssertEqual(player.rpg, rpgBefore)
        XCTAssertEqual(RPGPlayerItemsSnapshot.capture(player), itemsBefore)
        XCTAssertTrue(ownerBefore.matches(player))
        XCTAssertTrue(targetBefore.matches(zombie))
        XCTAssertEqual(world.getBlock(2, 64, 2), blockBefore)
        XCTAssertEqual(world.rpgTemporaryEffects, temporaryBefore)
        XCTAssertEqual(blockChanges, 0)
        XCTAssertEqual(particles, 0)
        XCTAssertEqual(sounds, 0)
    }

    func testCommitRejectsChangedRPGInventoryTargetBlockAndContainerWithoutSecondaryMutation() throws {
        do {
            let (world, player, zombie) = makeHeavyCutFixture(seed: 302)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "heavy_cut",
                                                               authorization: .local(for: player)))
            player.rpg.fatigue -= 0.25
            let afterChange = player.rpg
            let targetAfterChange = RPGEntityGuard.capture(zombie)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(player.rpg, afterChange)
            XCTAssertTrue(targetAfterChange.matches(zombie))
            XCTAssertEqual(world.rpgTemporaryEffects.count, 0)
        }

        do {
            let world = makeWorld(seed: 303)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "trap_probe",
                                            preparedSkill: "deadfall")
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            player.inventory[0] = ItemStack(iid("gravel"), 2)
            placeRayBlock(world, B.stone)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "deadfall",
                                                               authorization: .local(for: player)))
            player.inventory[0]?.count = 3
            let afterChange = RPGPlayerItemsSnapshot.capture(player)
            let destination = try XCTUnwrap(prepared.blockGuards.first?.position)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(RPGPlayerItemsSnapshot.capture(player), afterChange)
            XCTAssertEqual(world.getBlock(destination.x, destination.y, destination.z), 0)
            XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        }

        do {
            let (_, player, zombie) = makeHeavyCutFixture(seed: 304)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "heavy_cut",
                                                               authorization: .local(for: player)))
            zombie.x += 0.05
            zombie.vx = 0.125
            zombie.addEffect("glowing", 20, 0)
            let afterChange = RPGEntityGuard.capture(zombie)
            let actorAfterChange = RPGEntityGuard.capture(player)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertTrue(afterChange.matches(zombie))
            XCTAssertTrue(actorAfterChange.matches(player))
        }

        do {
            let world = makeWorld(seed: 305)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "trap_probe",
                                            preparedSkill: "deadfall")
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            player.inventory[0] = ItemStack(iid("gravel"), 2)
            placeRayBlock(world, B.stone)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "deadfall",
                                                               authorization: .local(for: player)))
            let destination = try XCTUnwrap(prepared.blockGuards.first?.position)
            world.setBlock(destination.x, destination.y, destination.z, Int(cell(B.dirt)))
            let afterChange = world.getBlock(destination.x, destination.y, destination.z)
            let actorAfterChange = RPGEntityGuard.capture(player)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(world.getBlock(destination.x, destination.y, destination.z), afterChange)
            XCTAssertTrue(actorAfterChange.matches(player))
            XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        }

        do {
            let world = makeWorld(seed: 306)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye",
                                            preparedSkill: "lock_touch")
            placeRayBlock(world, B.chest)
            let container = makeContainerBE(0, 65, 4, 27)
            container.lootTable = "dungeon"
            container.lootSeed = 44
            container.rpgGeneratedContainerKey = "generated:0:0:65:4"
            world.setBlockEntity(container)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "lock_touch",
                                                               authorization: .local(for: player)))
            container.rpgGeneratedContainerKey = "generated:0:changed:65:4"
            let actorAfterChange = RPGEntityGuard.capture(player)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(container.rpgGeneratedContainerKey, "generated:0:changed:65:4")
            XCTAssertEqual(container.lootTable, "dungeon")
            XCTAssertTrue(actorAfterChange.matches(player))
        }
    }

    func testCommitRevalidatesScheduledTriggerTeleportServantAndTemporaryCapacity() throws {
        do {
            let world = makeWorld(seed: 307)
            let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "circuit_sense",
                                            preparedSkill: "remote_trigger")
            placeRayBlock(world, B.dispenser)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "remote_trigger",
                                                               authorization: .local(for: player)))
            world.scheduleTick(0, 65, 4, Int(B.dispenser), 1)
            let beforeCommit = player.rpg
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(player.rpg, beforeCommit)
            XCTAssertTrue(world.hasScheduledTick(0, 65, 4, Int(B.dispenser)))
        }

        do {
            let world = makeWorld(dim: .nether, seed: 308)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "minor_glamour",
                                            preparedSpell: "shadow_step")
            configureShadowStepDestination(world)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .spell, id: "shadow_step",
                                                               authorization: .local(for: player)))
            let destination = try XCTUnwrap(prepared.operations.compactMap { operation -> RPGTeleportMutation? in
                if case .teleportOwner(let mutation) = operation { return mutation }
                return nil
            }.first)
            let floor = RPGBlockPosition(ifloor(destination.destinationX),
                                         ifloor(destination.destinationY) - 1,
                                         ifloor(destination.destinationZ))
            let floorCell = world.getBlock(floor.x, floor.y, floor.z)
            world.setBlock(floor.x, floor.y, floor.z, 0)
            let beforeFloorCommit = RPGEntityGuard.capture(player)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertTrue(beforeFloorCommit.matches(player))
            world.setBlock(floor.x, floor.y, floor.z, floorCell)
            let cow = Cow(world: world)
            cow.setPos(destination.destinationX, destination.destinationY, destination.destinationZ)
            world.addEntity(cow)
            let beforeCommit = RPGEntityGuard.capture(player)
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertTrue(beforeCommit.matches(player))
        }

        do {
            let world = makeWorld(seed: 309)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "ritual_circle",
                                            preparedSpell: "summon_servant")
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .spell, id: "summon_servant",
                                                               authorization: .local(for: player)))
            let spawn = try XCTUnwrap(prepared.operations.compactMap { operation -> RPGSpawnAllayMutation? in
                if case .spawnAllay(let mutation) = operation { return mutation }
                return nil
            }.first)
            let cow = Cow(world: world)
            cow.setPos(spawn.x, spawn.y, spawn.z)
            world.addEntity(cow)
            let beforeCommit = player.rpg
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(player.rpg, beforeCommit)
            XCTAssertFalse(world.entities.contains { $0 is Allay })
        }

        do {
            let world = makeWorld(seed: 310)
            let player = makeMasteredPlayer(in: world, pathID: "mender", starter: "safe_haven",
                                            preparedSkill: "safe_haven")
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "safe_haven",
                                                               authorization: .local(for: player)))
            for sequence in 100...101 {
                XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
                    kind: .safeHaven, ownerAuthorityID: player.effectiveRPGAuthorityID,
                    ownerEntityID: player.id, ownerSequence: sequence,
                    center: RPGBlockPosition(sequence - 100, 64, 0), durationTicks: 200)))
            }
            let beforeCommit = player.rpg
            XCTAssertEqual(rpgCommitPreparedAction(prepared, for: player).failure, .staleMutation)
            XCTAssertEqual(player.rpg, beforeCommit)
            XCTAssertEqual(world.rpgTemporaryEffects.count, 2)
        }
    }

    func testRejectedMaterialPermissionsPvPAndFocusConsumeNothing() {
        do {
            let world = makeWorld(seed: 311)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "trap_probe",
                                            preparedSkill: "deadfall")
            placeRayBlock(world, B.stone)
            assertRejectedWithoutMutation(player, expected: .missingMaterial("deadfall")) {
                rpgPrepareAction(player, kind: .skill, id: "deadfall",
                                 authorization: .local(for: player)).map { _ in () }
            }
        }

        do {
            let world = makeWorld(seed: 312)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "trap_probe",
                                            preparedSkill: "deadfall")
            player.inventory[0] = ItemStack(iid("gravel"), 1)
            placeRayBlock(world, B.stone)
            let denied = RPGActionAuthorization(ownerAuthorityID: player.effectiveRPGAuthorityID,
                                                worldOwnerEntityID: player.id,
                                                canBuild: false, canUseContainers: true)
            assertRejectedWithoutMutation(player, expected: .permissionDenied(.build)) {
                rpgPrepareAction(player, kind: .skill, id: "deadfall", authorization: denied).map { _ in () }
            }
        }

        do {
            let world = makeWorld(seed: 313)
            let player = makeMasteredPlayer(in: world, pathID: "delver", starter: "salvage_eye",
                                            preparedSkill: "lock_touch")
            placeRayBlock(world, B.chest)
            world.setBlockEntity(makeContainerBE(0, 65, 4, 27))
            let denied = RPGActionAuthorization(ownerAuthorityID: player.effectiveRPGAuthorityID,
                                                worldOwnerEntityID: player.id,
                                                canBuild: true, canUseContainers: false)
            assertRejectedWithoutMutation(player, expected: .permissionDenied(.container)) {
                rpgPrepareAction(player, kind: .skill, id: "lock_touch", authorization: denied).map { _ in () }
            }
        }

        do {
            let world = makeWorld(seed: 314)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "spell_formula",
                                            preparedSpell: "ignite")
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            player.offHand = nil
            let zombie = Zombie(world: world)
            zombie.setPos(0.5, 64, 3.5)
            world.addEntity(zombie)
            assertRejectedWithoutMutation(player, expected: .missingEquipment("an Apprentice Focus")) {
                rpgPrepareAction(player, kind: .spell, id: "ignite",
                                 authorization: .local(for: player)).map { _ in () }
            }
            XCTAssertEqual(zombie.health, zombie.maxHealth)
        }

        do {
            let world = makeWorld(seed: 315)
            let player = makeMasteredPlayer(in: world, pathID: "arcanist", starter: "spell_formula",
                                            preparedSpell: "ignite")
            let peer = Player(world: world)
            // Align the peer's center with the eye ray so this exercises the
            // explicit non-hostile/PvP rejection instead of a miss fixture.
            peer.setPos(0.5, 64.1, 3.5)
            world.addEntity(peer)
            assertRejectedWithoutMutation(player, expected: .invalidTarget("ignite")) {
                rpgPrepareAction(player, kind: .spell, id: "ignite",
                                 authorization: .local(for: player)).map { _ in () }
            }
            XCTAssertEqual(peer.health, peer.maxHealth)
        }
    }

    func testItemPlanningUsesDeepCopiesForRepairPlacementChargeAndRefund() throws {
        do {
            let world = makeWorld(seed: 316)
            let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "field_mod",
                                            preparedSkill: "quick_repair")
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            let tool = ItemStack(iid("diamond_pickaxe"), 1, damage: 100)
            let material = ItemStack(iid("diamond"), 2)
            player.inventory[0] = tool
            player.inventory[1] = material
            player.selectedSlot = 0
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "quick_repair",
                                                               authorization: .local(for: player)))
            XCTAssertEqual(tool.damage, 100)
            XCTAssertEqual(material.count, 2)
            XCTAssertFalse(prepared.nextItems?.inventory[0] === tool)
            XCTAssertFalse(prepared.nextItems?.inventory[1] === material)
            XCTAssertNotNil(try? rpgCommitPreparedAction(prepared, for: player).get())
            XCTAssertEqual(tool.damage, 100)
            XCTAssertEqual(material.count, 2)
            XCTAssertLessThan(player.inventory[0]?.damage ?? 100, 100)
            XCTAssertEqual(player.inventory[1]?.count, 1)
        }

        for (seed, skill, materialName, temporaryKind) in [
            (UInt32(317), "deadfall", "gravel", RPGTemporaryEffectKind.gravelTrap),
            (UInt32(318), "charge_pack", "tnt", RPGTemporaryEffectKind.controlledCharge),
        ] {
            let world = makeWorld(seed: seed)
            let starter = skill == "deadfall" ? "trap_probe" : "charge_pack"
            let path = skill == "deadfall" ? "delver" : "tinker"
            let player = makeMasteredPlayer(in: world, pathID: path, starter: starter,
                                            preparedSkill: skill)
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            let material = ItemStack(iid(materialName), 2)
            player.inventory[0] = material
            placeRayBlock(world, B.stone)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: skill,
                                                               authorization: .local(for: player)))
            XCTAssertEqual(material.count, 2)
            XCTAssertFalse(prepared.nextItems?.inventory[0] === material)
            XCTAssertNotNil(try? rpgCommitPreparedAction(prepared, for: player).get())
            XCTAssertEqual(material.count, 2)
            XCTAssertEqual(player.inventory[0]?.count, 1)
            XCTAssertTrue(world.rpgTemporaryEffects.contains { $0.draft.kind == temporaryKind })
        }

        do {
            let world = makeWorld(seed: 319)
            let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "charge_pack",
                                            preparedSkill: "safe_fuse")
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            let position = RPGBlockPosition(0, 65, 4)
            registerControlledCharge(world, owner: player, position: position, sequence: 7)
            let prepared = try unwrapPrepared(rpgPrepareAction(player, kind: .skill, id: "safe_fuse",
                                                               authorization: .local(for: player)))
            XCTAssertEqual(player.countItem(iid("tnt")), 0)
            XCTAssertNotNil(world.rpgTemporaryEffect(for: RPGTemporaryEffectKey(
                ownerAuthorityID: player.effectiveRPGAuthorityID, ownerSequence: 7,
                kind: .controlledCharge)))
            XCTAssertNotNil(try? rpgCommitPreparedAction(prepared, for: player).get())
            XCTAssertEqual(player.countItem(iid("tnt")), 1)
            XCTAssertEqual(world.getBlock(position.x, position.y, position.z), 0)
            XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        }
    }

    func testQuickRepairHasStrictlyIncreasingObservableOutcomesAtAllThreeRanks() {
        var resultingDamage: [Int] = []
        for rank in 1...3 {
            let world = makeWorld(seed: UInt32(320 + rank))
            let player = makeMasteredPlayer(in: world, pathID: "tinker", starter: "field_mod",
                                            preparedSkill: "quick_repair")
            var state = player.rpg
            state.skillRanks["quick_repair"] = rank
            state = repairRPGCharacterState(state)
            state.preparedSkillIDs = ["quick_repair"]
            state.fatigue = rpgDerivedStats(state).maxFatigue
            player.rpg = repairRPGCharacterState(state)
            player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
            player.inventory[0] = ItemStack(iid("diamond_pickaxe"), 1, damage: 400)
            player.inventory[1] = ItemStack(iid("diamond"), 1)
            player.selectedSlot = 0
            guard case .success = rpgUsePreparedSkill(player, skillID: "quick_repair") else {
                XCTFail("rank \(rank) did not execute")
                continue
            }
            resultingDamage.append(player.inventory[0]?.damage ?? 400)
            XCTAssertEqual(player.countItem(iid("diamond")), 0)
        }
        XCTAssertEqual(resultingDamage.count, 3)
        if resultingDamage.count == 3 {
            XCTAssertGreaterThan(resultingDamage[0], resultingDamage[1])
            XCTAssertGreaterThan(resultingDamage[1], resultingDamage[2])
        }
    }

    func testEverySpellHasALegalEffectProducingCommitAndExpectedPracticeXP() {
        var committedIDs: [String] = []
        for (index, spell) in RPGSpellEffectID.allCases.enumerated() {
            let world = makeWorld(dim: spell == .shadowStep ? .nether : .overworld,
                                  seed: UInt32(330 + index))
            let branch = spellBranchFixture(spell)
            let player = makeMasteredPlayer(in: world, pathID: branch.path,
                                            starter: branch.starter,
                                            preparedSpell: spell.rawValue)
            configureFixture(for: spell, player: player, world: world)
            player.rpg.xp = rpgXPRequiredForLevel(19)
            player.rpg.level = 19
            player.rpg = repairRPGCharacterState(player.rpg)
            player.rpg.fatigue = rpgDerivedStats(player.rpg).maxFatigue
            let beforeXP = player.rpg.xp
            switch rpgPrepareAction(player, kind: .spell, id: spell.rawValue,
                                    authorization: .local(for: player)) {
            case .success(let prepared):
                guard case .success = rpgCommitPreparedAction(prepared, for: player) else {
                    XCTFail("\(spell.rawValue) legal fixture failed commit")
                    continue
                }
                committedIDs.append(spell.rawValue)
                let expectedXP: Int
                if branch.path == "arcanist" {
                    expectedXP = 6
                } else {
                    expectedXP = switch spell {
                    case .mendWounds: 3
                    case .restore: 7
                    case .purify: 4
                    case .aegis, .sanctuary: 0
                    default: 0
                    }
                }
                XCTAssertEqual(player.rpg.xp - beforeXP, expectedXP,
                               "\(spell.rawValue) commit-to-XP contract")
            case .failure(let failure):
                XCTFail("\(spell.rawValue) legal fixture failed preparation: \(failure)")
            }
        }
        XCTAssertEqual(committedIDs, RPGSpellEffectID.allCases.map(\.rawValue))
    }

    func testTransientRegistryCapsRestoresGuardsConsumesChargesAndHonorsOwnerLOSAndLifecycle() throws {
        do {
            let world = makeWorld(seed: 350)
            for sequence in 1...2 {
                XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
                    kind: .decoy, ownerAuthorityID: "same-owner", ownerEntityID: nil,
                    ownerSequence: sequence, center: RPGBlockPosition(sequence, 64, 1),
                    durationTicks: 200)))
            }
            XCTAssertFalse(world.canRegisterRPGTemporaryEffect(ownerID: "same-owner", kind: .decoy))
            for index in 2..<RPG_MAX_TEMPORARY_EFFECTS_PER_WORLD {
                XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
                    kind: .decoy, ownerAuthorityID: "owner-\(index)", ownerEntityID: nil,
                    ownerSequence: 1, center: RPGBlockPosition(index % 16, 64, index / 16),
                    durationTicks: 200)))
            }
            XCTAssertEqual(world.rpgTemporaryEffects.count, RPG_MAX_TEMPORARY_EFFECTS_PER_WORLD)
            XCTAssertFalse(world.canRegisterRPGTemporaryEffect(ownerID: "overflow", kind: .ward))
        }

        do {
            let world = makeWorld(seed: 351)
            let position = RPGBlockPosition(1, 64, 1)
            world.setBlock(position.x, position.y, position.z, Int(cell(B.torch)))
            let key = registerGuarded(world, owner: "guard-owner", sequence: 1,
                                      kind: .mageLight, position: position,
                                      original: 0, temporary: Int(cell(B.torch)))
            world.setBlock(position.x, position.y, position.z, Int(cell(B.stone)))
            XCTAssertTrue(world.removeRPGTemporaryEffect(key, restoreGuardedBlock: true))
            XCTAssertEqual(world.getBlock(position.x, position.y, position.z), Int(cell(B.stone)))

            let deferredPosition = RPGBlockPosition(2, 64, 2)
            world.setBlock(deferredPosition.x, deferredPosition.y, deferredPosition.z, Int(cell(B.torch)))
            _ = registerGuarded(world, owner: "deferred-owner", sequence: 2,
                                kind: .mageLight, position: deferredPosition,
                                original: 0, temporary: Int(cell(B.torch)))
            let chunk = try XCTUnwrap(world.getChunk(0, 0))
            world.removeChunk(0, 0)
            world.cancelRPGTemporaryEffects(ownerID: "deferred-owner")
            XCTAssertTrue(world.rpgTemporaryEffects.contains { $0.draft.ownerAuthorityID == "deferred-owner" })
            world.setChunk(chunk)
            world.cancelRPGTemporaryEffects(ownerID: "deferred-owner")
            XCTAssertFalse(world.rpgTemporaryEffects.contains { $0.draft.ownerAuthorityID == "deferred-owner" })
            XCTAssertEqual(world.getBlock(deferredPosition.x, deferredPosition.y, deferredPosition.z), 0)
        }

        do {
            let world = makeWorld(seed: 352)
            XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
                kind: .ward, ownerAuthorityID: "warder", ownerEntityID: nil,
                ownerSequence: 1, center: RPGBlockPosition(4, 64, 4), radius: 1,
                durationTicks: 200, remainingCharges: 2)))
            XCTAssertTrue(world.consumeRPGExplosionProtection(at: RPGBlockPosition(4, 64, 4)))
            XCTAssertEqual(world.rpgTemporaryEffects.first?.draft.remainingCharges, 1)
            XCTAssertTrue(world.consumeRPGExplosionProtection(at: RPGBlockPosition(4, 64, 4)))
            XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
            XCTAssertFalse(world.consumeRPGExplosionProtection(at: RPGBlockPosition(4, 64, 4)))
        }

        do {
            let world = makeWorld(seed: 353)
            let owner = makeMasteredPlayer(in: world, pathID: "tinker", starter: "charge_pack")
            let chargePosition = RPGBlockPosition(0, 65, 4)
            registerControlledCharge(world, owner: owner, position: chargePosition, sequence: 3)
            world.setBlock(0, 65, 2, Int(cell(B.stone)))
            XCTAssertNil(world.nearestOwnedRPGCharge(ownerID: owner.effectiveRPGAuthorityID,
                                                     x: owner.x, eyeY: owner.eyeY(), y: owner.y, z: owner.z,
                                                     radius: 8))
            world.setBlock(0, 65, 2, 0)
            XCTAssertNotNil(world.nearestOwnedRPGCharge(ownerID: owner.effectiveRPGAuthorityID,
                                                        x: owner.x, eyeY: owner.eyeY(), y: owner.y, z: owner.z,
                                                        radius: 8))
            XCTAssertNil(world.nearestOwnedRPGCharge(ownerID: "different-owner",
                                                     x: owner.x, eyeY: owner.eyeY(), y: owner.y, z: owner.z,
                                                     radius: 8))
            XCTAssertTrue(world.registerRPGTemporaryEffect(RPGTemporaryEffectDraft(
                kind: .decoy, ownerAuthorityID: "unrelated", ownerEntityID: nil,
                ownerSequence: 4, center: RPGBlockPosition(2, 64, 2), durationTicks: 200)))
            world.cancelRPGTemporaryEffects(ownerID: owner.effectiveRPGAuthorityID)
            XCTAssertTrue(world.rpgTemporaryEffects.contains { $0.draft.ownerAuthorityID == "unrelated" })
            world.gameRules[RPG_CLASSES_GAME_RULE] = 0
            world.tickRPGTemporaryEffects()
            XCTAssertTrue(world.rpgTemporaryEffects.isEmpty)
        }
    }

    // MARK: - Fixtures

    private func makeWorld(dim: Dim = .overworld, seed: UInt32) -> World {
        let world = World(dim: dim, seed: seed)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height))
        retainedWorlds.append(world)
        return world
    }

    private func placeRayBlock(_ world: World, _ block: UInt16, meta: Int = 0) {
        world.setBlock(0, 65, 4, Int(cell(block, meta)))
    }

    private func makeMasteredPlayer(in world: World,
                                    pathID: String,
                                    starter: String,
                                    preparedSkill: String? = nil,
                                    preparedSpell: String? = nil) -> Player {
        let player = Player(world: world)
        let starterSpells: [String]
        switch (pathID, starter) {
        case ("arcanist", "spell_formula"): starterSpells = ["ignite"]
        case ("arcanist", "minor_glamour"): starterSpells = ["blur"]
        case ("arcanist", "ritual_circle"): starterSpells = ["mage_light"]
        case ("mender", "field_dressing"): starterSpells = ["mend_wounds"]
        case ("mender", "herbal_lore"): starterSpells = ["purify"]
        case ("mender", "safe_haven"): starterSpells = ["ward"]
        default: starterSpells = []
        }
        XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(
            pathID: pathID,
            attributes: rpgCreationPreset(pathID: pathID)!,
            starterSkillID: starter,
            starterSpellIDs: starterSpells)))
        var state = player.rpg
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        state.level = RPG_LEVEL_CAP
        if pathID == "arcanist" || pathID == "mender" {
            state.attributes.intelligence = max(13, state.attributes.intelligence)
        }
        if let branch = rpgBranchDefinition(state.specializationBranchID) {
            for skillID in branch.skillIDs { state.skillRanks[skillID] = 3 }
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
            player.offHand = ItemStack(iid("apprentice_focus"), 1)
        }
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        world.addEntity(player)
        return player
    }

    private func makeHeavyCutFixture(seed: UInt32) -> (World, Player, Zombie) {
        let world = makeWorld(seed: seed)
        let player = makeMasteredPlayer(in: world, pathID: "warden", starter: "heavy_cut",
                                        preparedSkill: "heavy_cut")
        player.inventory = [ItemStack?](repeating: nil, count: player.inventory.count)
        player.inventory[0] = ItemStack(iid("iron_sword"), 1)
        player.selectedSlot = 0
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 3.5)
        world.addEntity(zombie)
        return (world, player, zombie)
    }

    private func assertRejectedWithoutMutation(
        _ player: Player,
        expected: RPGActionFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () -> Result<Void, RPGActionFailure>
    ) {
        let owner = RPGEntityGuard.capture(player)
        let rpg = player.rpg
        let items = RPGPlayerItemsSnapshot.capture(player)
        let temporaries = player.world.rpgTemporaryEffects
        XCTAssertEqual(operation().failure, expected, file: file, line: line)
        XCTAssertTrue(owner.matches(player), file: file, line: line)
        XCTAssertEqual(player.rpg, rpg, file: file, line: line)
        XCTAssertEqual(RPGPlayerItemsSnapshot.capture(player), items, file: file, line: line)
        XCTAssertEqual(player.world.rpgTemporaryEffects, temporaries, file: file, line: line)
    }

    private func configureShadowStepDestination(_ world: World) {
        world.setBlock(0, 64, 3, Int(cell(B.stone)))
        world.setBlock(0, 65, 4, Int(cell(B.stone)))
    }

    private func spellBranchFixture(_ spell: RPGSpellEffectID) -> (path: String, starter: String) {
        switch spell {
        case .ignite, .frostRay, .shock, .stormAura:
            return ("arcanist", "spell_formula")
        case .blur, .decoy, .shadowStep, .mirrorImage:
            return ("arcanist", "minor_glamour")
        case .mageLight, .ward, .summonServant, .stoneWard:
            return ("arcanist", "ritual_circle")
        case .mendWounds, .restore:
            return ("mender", "field_dressing")
        case .purify:
            return ("mender", "herbal_lore")
        case .aegis, .sanctuary:
            return ("mender", "safe_haven")
        }
    }

    private func configureFixture(for spell: RPGSpellEffectID, player: Player, world: World) {
        switch spell {
        case .ignite, .frostRay, .shock:
            let zombie = Zombie(world: world)
            zombie.setPos(0.5, 64, 3.5)
            zombie.maxHealth = 100
            zombie.health = 100
            world.addEntity(zombie)
        case .shadowStep:
            configureShadowStepDestination(world)
        case .mageLight, .ward, .stoneWard:
            placeRayBlock(world, B.stone)
        case .mendWounds, .restore, .purify, .aegis:
            let villager = Villager(world: world)
            villager.setPos(0.5, 64, 1.5)
            world.addEntity(villager)
            if spell == .mendWounds || spell == .restore || spell == .purify {
                let zombie = Zombie(world: world)
                zombie.setPos(4.5, 64, 4.5)
                world.addEntity(zombie)
                XCTAssertTrue(villager.hurt(6, "mob", zombie))
            }
            if spell == .restore { villager.addEffect("slowness", 100, 0) }
            if spell == .purify { villager.addEffect("poison", 100, 0) }
        case .stormAura, .blur, .decoy, .mirrorImage, .summonServant, .sanctuary:
            break
        }
        player.rpg.activeCooldowns = []
        player.rpg.activeUpkeeps = []
        player.rpg.fatigue = rpgDerivedStats(player.rpg).maxFatigue
    }

    @discardableResult
    private func registerGuarded(_ world: World,
                                 owner: String,
                                 sequence: Int,
                                 kind: RPGTemporaryEffectKind,
                                 position: RPGBlockPosition,
                                 original: Int,
                                 temporary: Int) -> RPGTemporaryEffectKey {
        let guarded = RPGGuardedTemporaryBlock(position: position,
                                               originalCell: original,
                                               temporaryCell: temporary)
        let draft = RPGTemporaryEffectDraft(kind: kind, ownerAuthorityID: owner,
                                            ownerEntityID: nil, ownerSequence: sequence,
                                            center: position, durationTicks: 200,
                                            guardedBlock: guarded)
        XCTAssertTrue(world.registerRPGTemporaryEffect(draft))
        return draft.key
    }

    private func registerControlledCharge(_ world: World,
                                          owner: Player,
                                          position: RPGBlockPosition,
                                          sequence: Int) {
        world.setBlock(position.x, position.y, position.z, Int(cell(B.tnt)))
        _ = registerGuarded(world, owner: owner.effectiveRPGAuthorityID,
                            sequence: sequence, kind: .controlledCharge,
                            position: position, original: 0,
                            temporary: Int(cell(B.tnt)))
    }

    private func unwrapPrepared(
        _ result: Result<RPGPreparedMutation, RPGActionFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RPGPreparedMutation {
        switch result {
        case .success(let prepared): return prepared
        case .failure(let failure):
            XCTFail("preparation failed: \(failure)", file: file, line: line)
            throw failure
        }
    }
}

private extension Result where Failure == RPGActionFailure {
    var failure: RPGActionFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
