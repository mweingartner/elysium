import XCTest
@testable import PebbleCore

final class RPGCoreV2Tests: XCTestCase {
    func testApprenticeFocusIsAppendOnlyAfterFrozenItemRange() {
        XCTAssertEqual(iid("copper_hoe"), 1_193)
        XCTAssertEqual(iid("apprentice_focus"), 1_194)
        XCTAssertEqual(itemDefs.count, 1_195)
    }

    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllRecipes()
        registerAllSystems()
    }

    func testAllPresetsAreValidAndAllSixKitsGrantExactlyOnce() {
        let expected: [String: [String: Int]] = [
            "warden": ["stone_sword": 1, "shield": 1, "bread": 4],
            "ranger": ["bow": 1, "arrow": 24, "stone_sword": 1, "bread": 4],
            "delver": ["stone_pickaxe": 1, "torch": 16, "bread": 4],
            "arcanist": ["apprentice_focus": 1, "torch": 8, "bread": 4],
            "mender": ["apprentice_focus": 1, "potion": 2, "bread": 4],
            "tinker": ["stone_pickaxe": 1, "redstone": 12, "torch": 4, "bread": 4],
        ]
        for path in RPG_PATH_DEFINITIONS {
            guard let preset = rpgCreationPreset(pathID: path.id) else { return XCTFail(path.id) }
            XCTAssertEqual(preset.total, RPGAttributes.creationBudget, path.id)
            for starter in path.starterSkillIDs {
                XCTAssertNoThrow(try rpgCreateCharacter(RPGCreationDraft(pathID: path.id,
                                                                         attributes: preset,
                                                                         starterSkillID: starter)).get(), path.id)
            }

            let world = World(dim: .overworld, seed: 100)
            let player = Player(world: world)
            XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(pathID: path.id,
                                                                    attributes: preset,
                                                                    starterSkillID: path.starterSkillIDs[0])))
            for (item, count) in expected[path.id] ?? [:] {
                XCTAssertEqual(player.countItem(iid(item)), count, "\(path.id):\(item)")
            }
            XCTAssertEqual(player.rpg.kitGrantID,
                           rpgStarterKitGrantID(pathID: path.id, starterSkillID: path.starterSkillIDs[0]))
            let before = inventorySignature(player.inventory)
            XCTAssertEqual(player.createRPGCharacter(RPGCreationDraft(pathID: path.id,
                                                                       attributes: preset,
                                                                       starterSkillID: path.starterSkillIDs[0])),
                           .alreadyCreated)
            XCTAssertEqual(inventorySignature(player.inventory), before)
            if path.id == "mender" {
                let healing = player.inventory.compactMap { $0 }.filter { $0.id == iid("potion") && $0.data.potion == "healing" }
                XCTAssertEqual(healing.count, 2)
                XCTAssertTrue(healing.allSatisfy { $0.count == 1 })
            }
        }
    }

    func testEveryStarterReachesLevelTwoThroughItsLegitimateLevelOneLoop() throws {
        let provisionRecipe = try XCTUnwrap(craftingRecipes.firstIndex {
            itemDef(craftingRecipeOutput($0).id).name == "mushroom_stew"
        })
        let repeaterRecipe = try XCTUnwrap(craftingRecipes.firstIndex {
            itemDef(craftingRecipeOutput($0).id).name == "repeater"
        })

        for (pathIndex, path) in RPG_PATH_DEFINITIONS.enumerated() {
            for (starterIndex, starter) in path.starterSkillIDs.enumerated() {
                let world = World(dim: .overworld,
                                  seed: UInt32(10_000 + pathIndex * 100 + starterIndex))
                world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY,
                                     height: world.info.height))
                let player = Player(world: world)
                XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(
                    pathID: path.id, attributes: rpgCreationPreset(pathID: path.id)!,
                    starterSkillID: starter
                )))
                player.setPos(0.5, 64, 0.5)
                player.yaw = 0
                player.pitch = 0
                world.addEntity(player)

                switch path.id {
                case "warden":
                    for index in 0..<5 {
                        let hostile = Zombie(world: world)
                        hostile.setPos(3.5, 64, Double(index) + 3.5)
                        hostile.health = 1
                        world.addEntity(hostile)
                        XCTAssertTrue(hostile.hurt(1, RPG_DAMAGE_SOURCE_WARDEN_MELEE, player))
                    }
                case "ranger":
                    for index in 0..<17 {
                        let cx = index
                        world.setChunk(Chunk(cx: cx, cz: 0, minY: world.info.minY,
                                             height: world.info.height))
                        world.rpgSimulationTick = (index / 8) * RPG_XP_WINDOW_TICKS
                        player.setPos(Double(cx * CHUNK_W) + 0.5, 64, 0.5)
                        rpgAwardCurrentChunkDiscovery(player)
                    }
                case "delver":
                    player.inventory[0] = ItemStack(iid("stone_pickaxe"), 1)
                    player.selectedSlot = 0
                    for index in 0..<13 {
                        world.rpgSimulationTick = (index / 8) * RPG_XP_WINDOW_TICKS
                        world.setBlock(index, 62, 0, Int(cell(B.stone)))
                        finishBreaking(InteractCtx(world: world, player: player), index, 62, 0)
                        XCTAssertEqual(world.getBlock(index, 62, 0), 0,
                                       "progression must follow an actual completed break")
                    }
                case "arcanist":
                    let spell: String
                    switch starter {
                    case "spell_formula": spell = "ignite"
                    case "minor_glamour": spell = "blur"
                    default: spell = "mage_light"
                    }
                    for index in 0..<9 {
                        if spell == "ignite" {
                            let hostile = Zombie(world: world)
                            hostile.setPos(0.5, 64, 3.5)
                            world.addEntity(hostile)
                        } else if spell == "mage_light" {
                            world.setBlock(0, 65, 4, Int(cell(B.stone)))
                        }
                        guard case .success = rpgCastPreparedSpell(player, spellID: spell) else {
                            return XCTFail("\(starter) could not execute \(spell) at cast \(index)")
                        }
                        for entity in Array(world.entities) where entity is Zombie {
                            if let concrete = entity as? Entity { concrete.remove() }
                            world.removeEntity(entity)
                        }
                        let advanceTicks = spell == "mage_light"
                            ? RPG_XP_WINDOW_TICKS + 200
                            : RPG_XP_WINDOW_TICKS
                        for _ in 0..<advanceTicks {
                            world.rpgSimulationTick += 1
                            player.tickRPGContinuousState()
                        }
                        world.tickRPGTemporaryEffects()
                    }
                case "mender":
                    var resources: [ItemStack?] = [
                        ItemStack(iid("brown_mushroom"), 9),
                        ItemStack(iid("red_mushroom"), 9),
                        ItemStack(iid("bowl"), 9),
                    ]
                    var grid = [ItemStack?](repeating: nil, count: 4)
                    let plan = try XCTUnwrap(craftingPlans(
                        for: resources, gridWidth: 2, gridHeight: 2
                    ).first { $0.recipeIndex == provisionRecipe })
                    XCTAssertTrue(populateCraftingGrid(plan, grid: &grid,
                                                       inventory: &resources))
                    let firstPreview = plan.output.copy()
                    firstPreview.count = plan.output.count * 8
                    let firstCommit = try XCTUnwrap(commitCraftingOutputRounds(
                        player: player, grid: &grid, gridWidth: 2, gridHeight: 2,
                        plan: plan, displayedOutput: firstPreview, requestedRounds: 8
                    ) { nextGrid in
                        populateCraftingGrid(plan, grid: &nextGrid, inventory: &resources)
                    })
                    XCTAssertEqual(firstCommit.completedRounds, 8)
                    XCTAssertEqual(firstCommit.output.count, plan.output.count * 8)
                    XCTAssertEqual(firstCommit.progression.awardedXP, 48)
                    world.rpgSimulationTick = RPG_XP_WINDOW_TICKS
                    let rolloverPreview = plan.output.copy()
                    let rolloverCommit = try XCTUnwrap(commitCraftingOutputRounds(
                        player: player, grid: &grid, gridWidth: 2, gridHeight: 2,
                        plan: plan, displayedOutput: rolloverPreview, requestedRounds: 1
                    ) { nextGrid in
                        populateCraftingGrid(plan, grid: &nextGrid, inventory: &resources)
                    })
                    XCTAssertEqual(rolloverCommit.completedRounds, 1)
                    XCTAssertEqual(rolloverCommit.progression.awardedXP, 6)
                case "tinker":
                    var resources: [ItemStack?] = [
                        ItemStack(iid("redstone_torch"), 18),
                        ItemStack(iid("redstone"), 9),
                        ItemStack(iid("stone"), 27),
                    ]
                    var grid = [ItemStack?](repeating: nil, count: 9)
                    let plan = try XCTUnwrap(craftingPlans(
                        for: resources, gridWidth: 3, gridHeight: 3
                    ).first { $0.recipeIndex == repeaterRecipe })
                    XCTAssertTrue(populateCraftingGrid(plan, grid: &grid,
                                                       inventory: &resources))
                    let firstPreview = plan.output.copy()
                    firstPreview.count = plan.output.count * 8
                    let firstCommit = try XCTUnwrap(commitCraftingOutputRounds(
                        player: player, grid: &grid, gridWidth: 3, gridHeight: 3,
                        plan: plan, displayedOutput: firstPreview, requestedRounds: 8
                    ) { nextGrid in
                        populateCraftingGrid(plan, grid: &nextGrid, inventory: &resources)
                    })
                    XCTAssertEqual(firstCommit.completedRounds, 8)
                    XCTAssertEqual(firstCommit.output.count, plan.output.count * 8)
                    XCTAssertEqual(firstCommit.progression.awardedXP, 46)
                    world.rpgSimulationTick = RPG_XP_WINDOW_TICKS
                    let rolloverPreview = plan.output.copy()
                    let rolloverCommit = try XCTUnwrap(commitCraftingOutputRounds(
                        player: player, grid: &grid, gridWidth: 3, gridHeight: 3,
                        plan: plan, displayedOutput: rolloverPreview, requestedRounds: 1
                    ) { nextGrid in
                        populateCraftingGrid(plan, grid: &nextGrid, inventory: &resources)
                    })
                    XCTAssertEqual(rolloverCommit.completedRounds, 1)
                    XCTAssertEqual(rolloverCommit.progression.awardedXP, 6)
                default:
                    XCTFail("uncovered RPG path \(path.id)")
                }

                XCTAssertGreaterThanOrEqual(player.rpg.xp, rpgXPRequiredForLevel(2),
                                            "\(path.id)/\(starter) lacks a viable first loop")
                XCTAssertEqual(player.rpg.level, 2, "\(path.id)/\(starter)")
            }
        }
    }

    func testEveryPathCanReachExactLevelTwentyThroughThePublicGameplayEventGate() {
        let fixtures: [(path: String, starter: String, kind: RPGXPEventKind, magnitude: Int)] = [
            ("warden", "guard_stance", .wardenMeleeDefeat, 1),
            ("ranger", "trail_sense", .rangerFieldDiscovery, 1),
            ("delver", "vein_reader", .delverExcavation, 1),
            ("arcanist", "spell_formula", .arcanistSpellPractice, 1),
            ("mender", "field_dressing", .menderProvisionCraft, 1),
            ("tinker", "circuit_sense", .tinkerEngineeringCraft, 1),
        ]
        let capXP = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        XCTAssertEqual(capXP, 7_790)
        for fixture in fixtures {
            var state = makeState(pathID: fixture.path, starter: fixture.starter)
            var sequence = 0
            var window = 0
            while state.xp < capXP {
                let limit = fixture.kind.category.windowLimit
                let offset = sequence % limit
                if offset == 0, sequence > 0 { window += 1 }
                let registryIndex = fixture.kind == .arcanistSpellPractice ? offset : nil
                let event = RPGXPEvent(kind: fixture.kind,
                                       key: "cap:\(fixture.path):\(sequence)",
                                       magnitude: fixture.magnitude,
                                       registryIndex: registryIndex)
                _ = rpgAwardXPEvent(event,
                                    simulationTick: window * RPG_XP_WINDOW_TICKS,
                                    worldDay: window, to: &state)
                sequence += 1
                XCTAssertLessThan(sequence, 10_000, "\(fixture.path) progression stalled")
            }
            XCTAssertEqual(state.xp, capXP, fixture.path)
            XCTAssertEqual(state.level, RPG_LEVEL_CAP, fixture.path)
        }
    }

    func testAllSeventeenSpellIndicesAreBoundedAndResetOnlyWithGlobalWindow() {
        var state = makeState(pathID: "arcanist", starter: "spell_formula")
        for index in RPG_SPELL_DEFINITIONS.indices {
            let window = index / RPGXPEventCategory.cast.windowLimit
            XCTAssertEqual(rpgAwardXPEvent(
                RPGXPEvent(kind: .arcanistSpellPractice, key: "spell:\(index)",
                           registryIndex: index),
                simulationTick: window * RPG_XP_WINDOW_TICKS,
                worldDay: window, to: &state
            ).awardedXP, 6, RPG_SPELL_DEFINITIONS[index].id)
        }
        let beforeInvalid = state
        XCTAssertEqual(rpgAwardXPEvent(
            RPGXPEvent(kind: .arcanistSpellPractice, key: "spell:invalid",
                       registryIndex: RPG_SPELL_DEFINITIONS.count),
            simulationTick: 3 * RPG_XP_WINDOW_TICKS,
            worldDay: 3, to: &state
        ).awardedXP, 0)
        XCTAssertEqual(state, beforeInvalid)

        var dayDoesNotReset = makeState(pathID: "arcanist", starter: "spell_formula")
        XCTAssertEqual(rpgAwardXPEvent(
            RPGXPEvent(kind: .arcanistSpellPractice, key: "day:first", registryIndex: 0),
            simulationTick: 5, worldDay: 0, to: &dayDoesNotReset
        ).awardedXP, 6)
        XCTAssertEqual(rpgAwardXPEvent(
            RPGXPEvent(kind: .arcanistSpellPractice, key: "day:second", registryIndex: 0),
            simulationTick: 6, worldDay: 999, to: &dayDoesNotReset
        ).awardedXP, 0, "world-day changes cannot reset distinct spell practice")
    }

    func testStarterKitPreflightRollsBackFullInventoryAndCharacterState() {
        let world = World(dim: .overworld, seed: 101)
        let player = Player(world: world)
        player.inventory = (0..<36).map { _ in ItemStack(iid("shield"), 1) }
        let before = inventorySignature(player.inventory)

        let error = player.createRPGCharacter(RPGCreationDraft(pathID: "warden",
                                                                attributes: rpgCreationPreset(pathID: "warden")!,
                                                                starterSkillID: "guard_stance"))

        XCTAssertEqual(error, .insufficientInventoryForStarterKit)
        XCTAssertFalse(player.rpg.created)
        XCTAssertEqual(inventorySignature(player.inventory), before)
    }

    func testFocusMustBeInEitherHand() {
        let world = World(dim: .overworld, seed: 102)
        let player = Player(world: world)
        XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(pathID: "arcanist",
                                                                attributes: rpgCreationPreset(pathID: "arcanist")!,
                                                                starterSkillID: "spell_formula")))
        XCTAssertTrue(rpgPlayerHasSpellFocus(player))
        player.selectedSlot = 1
        XCTAssertFalse(rpgPlayerHasSpellFocus(player), "carried but unready focus must not satisfy casting")
        player.offHand = player.inventory[0]
        player.inventory[0] = nil
        XCTAssertTrue(rpgPlayerHasSpellFocus(player))
    }

    func testCanonicalDerivedFormulasAndGeneratedRegistryContracts() {
        var state = RPGCharacterState(
            created: true, pathID: "tinker", starterSkillID: "circuit_sense",
            specializationBranchID: "tinker_redstone",
            attributes: RPGAttributes(strength: 18, dexterity: 18, intelligence: 18,
                                      endurance: 18, luck: 18),
            xp: 0, level: 1, skillRanks: [:], preparedSkillIDs: [],
            knownSpellIDs: [], preparedSpellIDs: [], fatigue: 0
        )
        let derived = rpgDerivedStats(state)
        XCTAssertEqual(derived.maxHealth, 39)
        XCTAssertEqual(derived.meleeDamageBonus, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(derived.exhaustionMultiplier, 0.88, accuracy: 0.000_001)
        XCTAssertEqual(derived.actionAccuracyBonus, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(derived.actionRecoveryMultiplier, 0.82, accuracy: 0.000_001)
        XCTAssertEqual(derived.spellPotencyBonus, 2, accuracy: 0.000_001)
        XCTAssertEqual(derived.focusCostMultiplier, 0.70, accuracy: 0.000_001)
        XCTAssertEqual(derived.luckProcChance, 0.12, accuracy: 0.000_001)
        state.skillRanks["guard_stance"] = 3
        XCTAssertEqual(rpgDerivedStats(state).maxHealth, 42,
                       "typed Guard Stance is additive after the canonical attribute base")

        XCTAssertEqual(rpgPathDefinition("delver")?.primaryAttributes, [.strength, .endurance])
        let passiveUnlocks: Set<String> = ["storm_focus", "mirror_work", "bound_servant",
                                           "ward_scribe", "sanctuary_bell"]
        for skill in RPG_SKILL_DEFINITIONS {
            XCTAssertEqual(skill.rankValues.count, 3, skill.id)
            XCTAssertEqual(skill.rankBenefits.count, 3, skill.id)
            XCTAssertTrue(skill.rankBenefits.allSatisfy { skill.summary.contains($0) }, skill.id)
            if passiveUnlocks.contains(skill.id) { XCTAssertEqual(skill.kind, .passive, skill.id) }
        }
        for branch in RPG_BRANCH_DEFINITIONS {
            for (index, skillID) in branch.skillIDs.enumerated() {
                let expected = index == 0 ? [] : [branch.skillIDs[index - 1]]
                XCTAssertEqual(rpgSkillDefinition(skillID)?.prerequisiteSkillIDs, expected, skillID)
            }
        }
        XCTAssertEqual(rpgSpellDefinition("aegis")?.upkeepCostPerSecond, 0)
        XCTAssertTrue(rpgSpellDefinition("aegis")?.summary.contains("no upkeep") == true)
    }

    func testBoundedDecodeEncodingPayloadAndNumericEdges() throws {
        XCTAssertEqual(rpgSaturatedAdd(1, 1, maximum: -1), 0)
        XCTAssertEqual(rpgSaturatedAdd(.max, .max, maximum: RPG_MAX_COUNTER), RPG_MAX_COUNTER)
        XCTAssertEqual(rpgEarnedSkillPoints(level: .min), 0)

        let sixtyFour = String(repeating: "x", count: RPG_MAX_ID_UTF8_BYTES)
        XCTAssertEqual(rpgParsePreparedActionToken("spell:\(sixtyFour)")?.id, sixtyFour)
        XCTAssertNil(rpgParsePreparedActionToken("spell:\(sixtyFour)x"))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RPGCooldown.self,
            from: Data("{\"id\":\"\(sixtyFour)x\",\"remainingTicks\":20}".utf8)
        ))
        let nonfinite = JSONDecoder()
        nonfinite.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        XCTAssertThrowsError(try nonfinite.decode(
            RPGUpkeep.self,
            from: Data("{\"spellID\":\"blur\",\"ownerSequence\":1,\"remainingTicks\":20,\"costPerSecond\":\"NaN\"}".utf8)
        ))

        let validState = makeState(pathID: "warden", starter: "guard_stance")
        var malformedObject = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(validState)) as? [String: Any])
        malformedObject["activeCooldowns"] = [NSNull(), ["id": "guard_stance", "remainingTicks": 20]]
        XCTAssertThrowsError(try JSONDecoder().decode(
            RPGCharacterState.self,
            from: try JSONSerialization.data(withJSONObject: malformedObject)
        ), "a malformed capped prefix must fail the RPG component instead of erasing a valid suffix")
        var malformedLedger = try XCTUnwrap(malformedObject["xpLedger"] as? [String: Any])
        malformedObject["activeCooldowns"] = []
        malformedLedger["recentKeys"] = [NSNull(), "valid:dedup"]
        malformedObject["xpLedger"] = malformedLedger
        XCTAssertThrowsError(try JSONDecoder().decode(
            RPGCharacterState.self,
            from: try JSONSerialization.data(withJSONObject: malformedObject)
        ))
        malformedLedger["recentKeys"] = []
        malformedLedger["lifetimeKeys"] = [NSNull(),
            ["kind": "rangerFieldDiscovery", "key": "valid:lifetime"]]
        malformedObject["xpLedger"] = malformedLedger
        XCTAssertThrowsError(try JSONDecoder().decode(
            RPGCharacterState.self,
            from: try JSONSerialization.data(withJSONObject: malformedObject)
        ))

        var raw = makeState(pathID: "arcanist", starter: "spell_formula")
        raw.preparedSpellIDs = Array(repeating: sixtyFour + "x", count: 100)
        raw.selectedPreparedActionID = "spell:\(sixtyFour)"
        raw.actionQuickSlots = ["spell:\(sixtyFour)", "spell:\(sixtyFour)x"]
        raw.activeCooldowns = [RPGCooldown(id: sixtyFour + "x", remainingTicks: 10)]
        raw.activeUpkeeps = [RPGUpkeep(spellID: "blur", ownerSequence: 1,
                                       remainingTicks: 10, costPerSecond: .nan)]
        let encoded = try JSONEncoder().encode(raw)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["preparedSpellIDs"] as? [Any])?.count, 0)
        XCTAssertEqual(object["selectedPreparedActionID"] as? String, "spell:\(sixtyFour)")
        XCTAssertEqual((object["actionQuickSlots"] as? [Any])?.count, 2)
        XCTAssertEqual((object["activeCooldowns"] as? [Any])?.count, 0)
        XCTAssertEqual((object["activeUpkeeps"] as? [Any])?.count, 0)

        let world = World(dim: .overworld, seed: 1_005)
        let source = Player(world: world)
        source.inventory[0] = ItemStack(iid("bread"), 2)
        source.health = 7
        var playerData = source.save()
        var oversizedRPG = try XCTUnwrap(playerData["rpg"] as? [String: Any])
        oversizedRPG["ignoredPadding"] = String(repeating: "p", count: RPG_MAX_PERSISTED_PAYLOAD_BYTES)
        playerData["rpg"] = oversizedRPG
        playerData["stats"] = ["rpg.toolTuneCounter": NSNumber(value: Double.nan)]
        let loaded = Player(world: world)
        loaded.load(playerData)
        XCTAssertFalse(loaded.rpg.created)
        XCTAssertEqual(loaded.health, 7)
        XCTAssertEqual(loaded.inventory[0]?.id, iid("bread"))
        XCTAssertEqual(loaded.inventory[0]?.count, 2)
        XCTAssertEqual(loaded.stats["rpg.toolTuneCounter"], 0)
    }

    func testSeededMalformedRepairIsIdempotent() {
        for seed in 0..<32 {
            var state = mastered(pathID: seed.isMultiple(of: 2) ? "arcanist" : "tinker",
                                 starter: seed.isMultiple(of: 2) ? "spell_formula" : "field_mod")
            state.attributes = RPGAttributes(
                strength: seed.isMultiple(of: 3) ? .min : 100 + seed,
                dexterity: seed.isMultiple(of: 5) ? .max : -seed,
                intelligence: 1_000 - seed,
                endurance: seed * 100,
                luck: -1_000
            )
            state.actionSequence = seed.isMultiple(of: 2) ? .max : .min
            state.authorityRevision = seed.isMultiple(of: 3) ? .max : .min
            state.preparedSpellIDs += [String(repeating: "z", count: 65), "unknown:\(seed)"]
            state.xpLedger.recentKeys += [String(repeating: "k", count: 65), "seed:\(seed)"]
            let once = repairRPGCharacterState(state)
            XCTAssertEqual(repairRPGCharacterState(once), once, "seed \(seed)")
        }
    }

    func testRepairMigratesV1DeterministicallyAndFutureVersionFailsClosed() {
        var legacy = RPGCharacterState(version: 1, created: true, pathID: "arcanist",
                                       attributes: .defaultCreation, xp: 37_050, level: 99,
                                       skillRanks: ["spell_formula": 1, "minor_glamour": 3, "false_step": 2],
                                       preparedSkillIDs: ["minor_glamour"], knownSpellIDs: ["blur"],
                                       preparedSpellIDs: ["blur"], fatigue: 10,
                                       kitGrantVersion: 99, kitGrantID: "forged")
        legacy = repairRPGCharacterState(legacy)
        XCTAssertEqual(legacy.version, 2)
        XCTAssertEqual(legacy.starterSkillID, "spell_formula",
                       "equally legal inferred candidates tie in frozen registry order")
        XCTAssertEqual(legacy.specializationBranchID, "arcanist_elementalist")
        XCTAssertEqual(legacy.kitGrantVersion, 0)
        XCTAssertNil(legacy.kitGrantID)
        XCTAssertEqual(repairRPGCharacterState(legacy), legacy)

        var future = legacy
        future.version = RPG_STATE_CURRENT_VERSION + 1
        XCTAssertFalse(repairRPGCharacterState(future).created)

        var negative = legacy
        negative.version = -1
        XCTAssertFalse(repairRPGCharacterState(negative).created)

        var encodedObject = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(makeState(pathID: "warden", starter: "guard_stance"))) as! [String: Any]
        encodedObject["version"] = -1
        let negativeJSON = try! JSONSerialization.data(withJSONObject: encodedObject)
        XCTAssertFalse(repairRPGCharacterState(
            try! JSONDecoder().decode(RPGCharacterState.self, from: negativeJSON)
        ).created)
        encodedObject.removeValue(forKey: "version")
        let missingVersionJSON = try! JSONSerialization.data(withJSONObject: encodedObject)
        let migratedMissingVersion = repairRPGCharacterState(
            try! JSONDecoder().decode(RPGCharacterState.self, from: missingVersionJSON)
        )
        XCTAssertTrue(migratedMissingVersion.created, "missing version is the supported v0 sentinel")
        XCTAssertEqual(migratedMissingVersion.version, RPG_STATE_CURRENT_VERSION)
    }

    func testV1XPStarterInferenceAndGlobalReplayUseShippedHistory() {
        let xpFixtures: [(old: Int, new: Int, level: Int)] = [
            (0, 0, 1),
            (150, 50, 2),
            (325, 95, 2),
            (500, 140, 3),
            (8_550, 1_890, 10),
            (9_525, 2_095, 10),
            (37_050, 7_790, 20),
        ]
        for fixture in xpFixtures {
            var legacy = makeState(pathID: "warden", starter: "guard_stance")
            legacy.version = 1
            legacy.xp = fixture.old
            legacy.level = fixture.level == 1 ? 20 : 1 // persisted level is ignored
            let repaired = repairRPGCharacterState(legacy)
            XCTAssertEqual(repaired.xp, fixture.new, "old XP \(fixture.old)")
            XCTAssertEqual(repaired.level, fixture.level, "old XP \(fixture.old)")
        }

        var unique = makeState(pathID: "arcanist", starter: "spell_formula")
        unique.version = 1
        unique.xp = 37_050
        unique.skillRanks = ["minor_glamour": 1, "spark_weave": 3, "storm_focus": 3]
        XCTAssertEqual(repairRPGCharacterState(unique).starterSkillID, "minor_glamour")

        var grandfathered = makeState(pathID: "ranger", starter: "trail_sense")
        grandfathered.version = 1
        grandfathered.xp = 500
        grandfathered.attributes = .defaultCreation // Luck 6 misses Trail Sense's current Luck 7 gate.
        grandfathered.skillRanks = ["trail_sense": 2]
        let migratedGrandfather = repairRPGCharacterState(grandfathered)
        XCTAssertEqual(migratedGrandfather.attributes, .defaultCreation)
        XCTAssertEqual(migratedGrandfather.starterSkillID, "trail_sense")
        XCTAssertEqual(migratedGrandfather.skillRanks["trail_sense"], 1,
                       "only inferred Foundation rank 1 is grandfathered")

        var ordered = makeState(pathID: "arcanist", starter: "ritual_circle")
        ordered.version = 1
        ordered.xp = 8_550 // old level 10, nine earned skill points
        ordered.skillRanks = ["spell_formula": 1, "ritual_circle": 3, "bound_servant": 2]
        let replayed = repairRPGCharacterState(ordered)
        XCTAssertEqual(replayed.starterSkillID, "ritual_circle")
        XCTAssertEqual(replayed.skillRanks["spell_formula"], 1,
                       "the frozen global registry replays Elementalist before Ritualist")
        XCTAssertEqual(replayed.skillRanks["ritual_circle"], 3)
        XCTAssertEqual(replayed.skillRanks["bound_servant"], 1)

        var wardenTie = makeState(pathID: "warden", starter: "guard_stance")
        wardenTie.version = 1
        wardenTie.xp = 500
        wardenTie.skillRanks = ["heavy_cut": 1, "shield_bind": 1]
        let migratedTie = repairRPGCharacterState(wardenTie)
        XCTAssertEqual(migratedTie.level, 3)
        XCTAssertEqual(migratedTie.starterSkillID, "heavy_cut",
                       "ties use frozen path branch order, not UI starter order")

        var malformedV2 = makeState(pathID: "ranger", starter: "trail_sense")
        malformedV2.attributes = RPGAttributes(strength: 12, dexterity: 9, intelligence: 9,
                                                endurance: 6, luck: 6)
        XCTAssertFalse(repairRPGCharacterState(malformedV2).created,
                       "a v2 starter that fails its creation requirement fails only RPG state closed")
        malformedV2 = makeState(pathID: "ranger", starter: "trail_sense")
        malformedV2.skillRanks["trail_sense"] = 0
        XCTAssertFalse(repairRPGCharacterState(malformedV2).created)
        malformedV2 = makeState(pathID: "warden", starter: "guard_stance")
        malformedV2.attributes = RPGAttributes(strength: 8, dexterity: 6, intelligence: 6,
                                                endurance: 8, luck: 6)
        XCTAssertLessThan(malformedV2.attributes.total, RPGAttributes.creationBudget)
        XCTAssertFalse(repairRPGCharacterState(malformedV2).created,
                       "v2 cannot silently replace an under-budget persisted build")
    }

    func testRecipeMilestonesPreserveBeforeRegistrationAndMaskAfterExactCount() {
        let raw = [UInt64.max, UInt64.max, 0x1234]
        XCTAssertEqual(rpgRepairRecipeMilestoneWords(raw, registeredRecipeCount: nil), raw)
        XCTAssertEqual(rpgRepairRecipeMilestoneWords(raw, registeredRecipeCount: 0), [])
        XCTAssertEqual(rpgRepairRecipeMilestoneWords(raw, registeredRecipeCount: 64), [UInt64.max])
        XCTAssertEqual(rpgRepairRecipeMilestoneWords(raw, registeredRecipeCount: 65),
                       [UInt64.max, 1])
        XCTAssertEqual(registeredCraftingRecipeCount, craftingRecipes.count)

        var state = makeState(pathID: "tinker", starter: "circuit_sense")
        state.xpLedger.recipeMilestoneWords = Array(repeating: UInt64.max,
                                                    count: RPG_MAX_RECIPE_MILESTONE_WORDS)
        let repaired = repairRPGCharacterState(state)
        let expectedWords = (craftingRecipes.count + 63) / 64
        XCTAssertEqual(repaired.xpLedger.recipeMilestoneWords.count, expectedWords)
        if craftingRecipes.count % 64 != 0 {
            let validBits = craftingRecipes.count % 64
            let mask = (UInt64(1) << UInt64(validBits)) - 1
            XCTAssertEqual(repaired.xpLedger.recipeMilestoneWords.last, mask)
        }
    }

    func testRepairBoundsCollectionsArithmeticAndInvalidGrantIdentity() {
        var state = mastered(pathID: "arcanist", starter: "spell_formula")
        state.actionSequence = .max
        state.authorityRevision = .max
        state.fatigue = .infinity
        state.activeCooldowns = (RPG_SKILL_DEFINITIONS + []).prefix(40).map {
            RPGCooldown(id: $0.id, remainingTicks: .max)
        }
        state.activeUpkeeps = Array(repeating: RPGUpkeep(spellID: "blur", ownerSequence: .max,
                                                         remainingTicks: .max, costPerSecond: .infinity), count: 40)
        state.xpLedger.recentKeys = (0..<100).map { "key:\($0)" }
        state.kitGrantVersion = RPG_STARTER_KIT_VERSION
        state.kitGrantID = "v1:wrong:wrong"

        let repaired = repairRPGCharacterState(state)

        XCTAssertEqual(repaired.actionSequence, RPG_MAX_COUNTER)
        XCTAssertEqual(repaired.authorityRevision, RPG_MAX_COUNTER)
        XCTAssertNil(rpgNextActionSequence(repaired))
        XCTAssertLessThanOrEqual(repaired.activeCooldowns.count, RPG_MAX_COOLDOWNS)
        XCTAssertTrue(repaired.activeCooldowns.allSatisfy { $0.remainingTicks <= RPG_MAX_EFFECT_TICKS })
        XCTAssertLessThanOrEqual(repaired.activeUpkeeps.count, RPG_MAX_UPKEEPS)
        XCTAssertLessThanOrEqual(repaired.xpLedger.recentKeys.count, RPG_MAX_XP_EVENT_KEYS)
        XCTAssertEqual(repaired.kitGrantVersion, 0)
        XCTAssertNil(repaired.kitGrantID)
        XCTAssertEqual(repairRPGCharacterState(repaired), repaired)
    }

    func testXPEventCapsRollbackDistinctMasksAndFiniteRecipeBitset() {
        var warden = makeState(pathID: "warden", starter: "guard_stance")
        for i in 0..<7 {
            let report = rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "mob:\(i)"),
                                         simulationTick: 100, worldDay: 0, to: &warden)
            XCTAssertEqual(report.awardedXP, i < 6 ? 10 : 0)
        }
        XCTAssertEqual(warden.xp, 60)
        let beforeBackward = warden
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "rollback"),
                                       simulationTick: 50, worldDay: 0, to: &warden).awardedXP, 0)
        XCTAssertEqual(warden, beforeBackward)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat,
                                                  key: String(repeating: "x", count: 65)),
                                       simulationTick: 51, worldDay: 0, to: &warden).awardedXP, 0)
        let beforeInvalidTime = warden
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "negative:tick"),
                                       simulationTick: -1, worldDay: 0, to: &warden).awardedXP, 0)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "large:tick"),
                                       simulationTick: RPG_MAX_COUNTER + 1, worldDay: 0,
                                       to: &warden).awardedXP, 0)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "negative:day"),
                                       simulationTick: 100, worldDay: -1, to: &warden).awardedXP, 0)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "large:day"),
                                       simulationTick: 100, worldDay: RPG_MAX_COUNTER + 1,
                                       to: &warden).awardedXP, 0)
        XCTAssertEqual(warden, beforeInvalidTime)

        var arcanist = makeState(pathID: "arcanist", starter: "spell_formula")
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .arcanistSpellPractice, key: "ignite:0", registryIndex: 0),
                                       simulationTick: 0, worldDay: 0, to: &arcanist).awardedXP, 6)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .arcanistSpellPractice, key: "ignite:again", registryIndex: 0),
                                       simulationTick: 1, worldDay: 0, to: &arcanist).awardedXP, 0)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .arcanistSpellPractice, key: "ignite:window2", registryIndex: 0),
                                       simulationTick: 1_201, worldDay: 1, to: &arcanist).awardedXP, 6)

        XCTAssertGreaterThan(craftingRecipes.count, 64)
        var tinker = makeState(pathID: "tinker", starter: "circuit_sense")
        let lastRecipe = craftingRecipes.count - 1
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .tinkerFirstRecipe, key: "recipe:last", registryIndex: lastRecipe),
                                       simulationTick: 0, worldDay: 0, to: &tinker).awardedXP, 4)
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .tinkerFirstRecipe, key: "recipe:last2", registryIndex: lastRecipe),
                                       simulationTick: 1, worldDay: 0, to: &tinker).awardedXP, 0)

        var ceiling = makeState(pathID: "warden", starter: "guard_stance")
        XCTAssertEqual(rpgAwardXPEvent(RPGXPEvent(kind: .wardenMeleeDefeat, key: "ceiling"),
                                       simulationTick: RPG_MAX_COUNTER,
                                       worldDay: RPG_MAX_COUNTER, to: &ceiling).awardedXP, 10)
    }

    func testLegacyXPDedupMergesIntoRollingRingAndNewEncodingDropsLifetimeField() throws {
        let raw = """
        {
          "windowStartTick":12,
          "counts":{"combat":0,"explore":0,"depthDungeon":0,"cast":0,"heal":0,"engineer":0},
          "recentKeys":["shared","recent"],
          "lifetimeKeys":[
            {"kind":"rangerFieldDiscovery","key":"historical"},
            {"kind":"delverDungeon","key":"shared"}
          ]
        }
        """
        let ledger = try JSONDecoder().decode(RPGXPLedger.self, from: Data(raw.utf8))
        XCTAssertEqual(ledger.recentKeys, ["historical", "shared", "recent"],
                       "current recent order wins when a legacy key is duplicated")
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ledger)) as? [String: Any])
        XCTAssertNil(encoded["lifetimeKeys"])
        XCTAssertEqual(encoded["recentKeys"] as? [String], ledger.recentKeys)
    }

    func testDiscoveryDungeonAndMechanismIdentitiesAllRollAfterSixtyFourEntries() {
        func exercise(pathID: String, starter: String, kind: RPGXPEventKind,
                      prefix: String, expectedAward: Int) {
            var state = makeState(pathID: pathID, starter: starter)
            for index in 0...RPG_MAX_XP_EVENT_KEYS {
                let report = rpgAwardXPEvent(
                    RPGXPEvent(kind: kind, key: "\(prefix):\(index)"),
                    simulationTick: index * RPG_XP_WINDOW_TICKS,
                    worldDay: index, to: &state
                )
                XCTAssertEqual(report.awardedXP, expectedAward, "\(pathID) index \(index)")
            }
            XCTAssertEqual(state.xpLedger.recentKeys.count, RPG_MAX_XP_EVENT_KEYS)
            XCTAssertFalse(state.xpLedger.recentKeys.contains("\(prefix):0"))
            XCTAssertEqual(rpgAwardXPEvent(
                RPGXPEvent(kind: kind, key: "\(prefix):0"),
                simulationTick: (RPG_MAX_XP_EVENT_KEYS + 2) * RPG_XP_WINDOW_TICKS,
                worldDay: RPG_MAX_XP_EVENT_KEYS + 2, to: &state
            ).awardedXP, expectedAward)
        }
        exercise(pathID: "ranger", starter: "trail_sense", kind: .rangerFieldDiscovery,
                 prefix: "field", expectedAward: 3)
        exercise(pathID: "delver", starter: "vein_reader", kind: .delverDungeonMilestone,
                 prefix: "dungeon", expectedAward: 12)
        exercise(pathID: "tinker", starter: "circuit_sense", kind: .tinkerMechanismTransition,
                 prefix: "mechanism", expectedAward: 2)
    }

    func testPassiveConsumersChangeBowMiningDamageExhaustionDurabilityAndAnimalAvoidance() {
        let world = World(dim: .overworld, seed: 103)
        let ranger = Player(world: world)
        ranger.rpg = mastered(pathID: "ranger", starter: "quick_draw")
        ranger.onGround = true
        XCTAssertEqual(rpgBowEffectiveChargeTicks(ranger, rawTicks: 14), 20)
        XCTAssertLessThan(rpgBowInaccuracy(ranger), 0.55)

        let delver = Player(world: ranger.world)
        delver.rpg = mastered(pathID: "delver", starter: "vein_reader")
        XCTAssertEqual(rpgMiningSpeedMultiplier(delver, blockID: Int(B.stone)), 1.3, accuracy: 0.0001)

        delver.rpg = mastered(pathID: "delver", starter: "trap_probe")
        XCTAssertEqual(rpgIncomingDamageMultiplier(delver, source: "explosion", attacker: nil), 0.55, accuracy: 0.0001)

        let normal = Player(world: ranger.world)
        let beforeNormal = normal.exhaustion
        normal.addExhaustion(1)
        let beforeRanger = ranger.exhaustion
        ranger.addExhaustion(1)
        XCTAssertLessThan(ranger.exhaustion - beforeRanger, normal.exhaustion - beforeNormal)

        let tuned = Player(world: ranger.world)
        tuned.rpg = mastered(pathID: "tinker", starter: "field_mod")
        XCTAssertFalse(tuned.shouldPreserveRPGToolDurability())
        XCTAssertFalse(tuned.shouldPreserveRPGToolDurability())
        XCTAssertFalse(tuned.shouldPreserveRPGToolDurability())
        XCTAssertTrue(tuned.shouldPreserveRPGToolDurability())

        let survivalist = Player(world: ranger.world)
        survivalist.rpg = mastered(pathID: "ranger", starter: "campcraft")
        survivalist.setPos(0, 64, 0)
        let cow = Cow(world: ranger.world)
        cow.setPos(1, 64, 0)
        ranger.world.addEntity(survivalist)
        ranger.world.addEntity(cow)
        let avoid = AvoidEntityGoal(cow, 1, { $0.isPlayer }, 10, 1)
        XCTAssertFalse(avoid.canUse())
    }

    func testDepthMilestonesPersistAndOnlyHostilesAwardKillXP() {
        let world = World(dim: .overworld, seed: 104)
        world.gameRules["doMobLoot"] = 0
        let delver = Player(world: world)
        delver.rpg = makeState(pathID: "delver", starter: "vein_reader")
        delver.setPos(0, -48, 0)
        rpgAwardReachedDepthMilestones(delver)
        XCTAssertEqual(delver.rpg.xp, 18)
        let once = delver.rpg
        rpgAwardReachedDepthMilestones(delver)
        XCTAssertEqual(delver.rpg.xp, once.xp)

        let warden = Player(world: world)
        warden.rpg = makeState(pathID: "warden", starter: "guard_stance")
        let cow = Cow(world: world)
        cow.die("mob", warden)
        XCTAssertEqual(warden.rpg.xp, 0)
        let zombie = Zombie(world: world)
        zombie.die(RPG_DAMAGE_SOURCE_WARDEN_MELEE, warden)
        XCTAssertEqual(warden.rpg.xp, 10)
    }

    func testDisabledRuleRejectsEveryRequestAndDirectEntryPointByteForByte() {
        let disabledWorld = World(dim: .overworld, seed: 105)
        disabledWorld.gameRules[RPG_CLASSES_GAME_RULE] = 0
        let uncreated = Player(world: disabledWorld)
        let creationState = uncreated.rpg
        let creationInventory = inventorySignature(uncreated.inventory)
        XCTAssertEqual(uncreated.createRPGCharacter(RPGCreationDraft(
            pathID: "warden", attributes: rpgCreationPreset(pathID: "warden")!,
            starterSkillID: "guard_stance"
        )), .classesDisabled)
        XCTAssertEqual(uncreated.rpg, creationState)
        XCTAssertEqual(inventorySignature(uncreated.inventory), creationInventory)

        let disabledXP = Player(world: disabledWorld)
        disabledXP.rpg = makeState(pathID: "warden", starter: "guard_stance")
        let xpState = disabledXP.rpg
        XCTAssertEqual(disabledXP.awardRPGXP(RPGXPEvent(kind: .wardenMeleeDefeat,
                                                        key: "disabled:xp")).awardedXP, 0)
        XCTAssertEqual(disabledXP.rpg, xpState)

        var unrepaired = makeState(pathID: "warden", starter: "guard_stance")
        unrepaired.version = -1
        disabledXP.rpg = unrepaired
        disabledXP.maxHealth = 30
        disabledXP.health = 30
        disabledXP.applyRPGDerivedStats()
        XCTAssertEqual(disabledXP.rpg, unrepaired, "disabled derived stats must not repair RPG state")
        XCTAssertEqual(disabledXP.maxHealth, 20)
        XCTAssertEqual(disabledXP.health, 20)

        let game = GameCore()
        game.createWorld(name: "Disabled RPG API", seedText: "105", mode: GameMode.survival,
                         difficulty: 2)
        game.player.rpg = mastered(pathID: "arcanist", starter: "spell_formula")
        game.setGameRule(RPG_CLASSES_GAME_RULE, 0)
        let expectedMessage = RPGActionFailure.classesDisabled.description
        let requests: [() -> String] = [
            { game.requestRPGCreateCharacter(RPGCreationDraft(pathID: "warden")) },
            { game.requestRPGLearnSkill("spark_weave") },
            { game.requestRPGTogglePreparedSkill("spark_weave") },
            { game.requestRPGTogglePreparedSpell("ignite") },
            { game.requestRPGSelectPreparedSkill("spark_weave") },
            { game.requestRPGSelectPreparedSpell("ignite") },
            { game.requestRPGAssignPreparedActionToQuickSlot(kind: .spell, id: "ignite", slot: 0) },
            { game.requestRPGClearActionQuickSlot(0) },
            { game.requestRPGSpendAttributePoint(.strength) },
            { game.requestRPGCyclePreparedSpell() },
            { game.requestRPGCyclePreparedAction() },
            { game.requestRPGCastSelectedSpell() },
            { game.requestRPGUseSelectedAction() },
            { game.requestRPGUseActionQuickSlot(0) },
        ]
        for request in requests {
            let beforeState = game.player.rpg
            let beforeInventory = inventorySignature(game.player.inventory)
            XCTAssertEqual(request(), expectedMessage)
            XCTAssertEqual(game.player.rpg, beforeState)
            XCTAssertEqual(inventorySignature(game.player.inventory), beforeInventory)
        }
    }

    func testRevisionNoOpsNormalCeilingAndTerminalCleanup() {
        var spells = mastered(pathID: "arcanist", starter: "spell_formula")
        XCTAssertTrue(spells.knownSpellIDs.contains("ignite"))
        XCTAssertTrue(spells.knownSpellIDs.contains("storm_aura"))
        spells.preparedSpellIDs = ["ignite"]
        spells.selectedPreparedSpellID = "ignite"
        spells.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: "ignite")
        spells = repairRPGCharacterState(spells)
        var before = spells
        XCTAssertNil(rpgPrepareSpell("ignite", in: &spells))
        XCTAssertEqual(spells, before)
        XCTAssertNil(rpgSelectPreparedSpell("ignite", in: &spells))
        XCTAssertEqual(spells, before)
        XCTAssertNil(rpgUnprepareSpell("storm_aura", in: &spells))
        XCTAssertEqual(spells, before)

        XCTAssertNil(rpgPrepareSpell("storm_aura", in: &spells))
        XCTAssertEqual(spells.authorityRevision, before.authorityRevision + 1)
        before = spells
        XCTAssertNil(rpgPrepareSpell("storm_aura", in: &spells))
        XCTAssertEqual(spells, before)
        XCTAssertNil(rpgSelectPreparedSpell("storm_aura", in: &spells))
        XCTAssertEqual(spells.authorityRevision, before.authorityRevision + 1)
        before = spells
        XCTAssertNil(rpgSelectPreparedSpell("storm_aura", in: &spells))
        XCTAssertEqual(spells, before)
        XCTAssertNil(rpgUnprepareSpell("storm_aura", in: &spells))
        XCTAssertEqual(spells.authorityRevision, before.authorityRevision + 1)

        var skills = mastered(pathID: "warden", starter: "guard_stance")
        skills.preparedSkillIDs = ["interpose"]
        skills.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: "interpose")
        skills = repairRPGCharacterState(skills)
        before = skills
        XCTAssertNil(rpgPrepareSkill("interpose", in: &skills))
        XCTAssertEqual(skills, before)
        XCTAssertNil(rpgSelectPreparedSkill("interpose", in: &skills))
        XCTAssertEqual(skills, before)
        XCTAssertNil(rpgUnprepareSkill("anchor_line", in: &skills))
        XCTAssertEqual(skills, before)
        XCTAssertNil(rpgPrepareSkill("anchor_line", in: &skills))
        XCTAssertEqual(skills.authorityRevision, before.authorityRevision + 1)
        before = skills
        XCTAssertNil(rpgSelectPreparedSkill("anchor_line", in: &skills))
        XCTAssertEqual(skills.authorityRevision, before.authorityRevision + 1)
        before = skills
        XCTAssertNil(rpgUnprepareSkill("anchor_line", in: &skills))
        XCTAssertEqual(skills.authorityRevision, before.authorityRevision + 1)

        var ceiling = makeState(pathID: "warden", starter: "guard_stance")
        ceiling.authorityRevision = RPG_MAX_NORMAL_AUTHORITY_REVISION - 1
        XCTAssertTrue(rpgIncrementAuthorityRevision(&ceiling))
        XCTAssertEqual(ceiling.authorityRevision, RPG_MAX_NORMAL_AUTHORITY_REVISION)
        XCTAssertFalse(rpgIncrementAuthorityRevision(&ceiling))

        var terminal = mastered(pathID: "arcanist", starter: "ritual_circle")
        terminal.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 7,
                                            remainingTicks: 20, costPerSecond: 0.5)]
        terminal.authorityRevision = 41
        XCTAssertTrue(rpgClearTerminalUpkeeps(&terminal))
        XCTAssertEqual(terminal.authorityRevision, 42)
        XCTAssertTrue(terminal.activeUpkeeps.isEmpty)
        let cleared = terminal
        XCTAssertFalse(rpgClearTerminalUpkeeps(&terminal))
        XCTAssertEqual(terminal, cleared)

        terminal.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 8,
                                            remainingTicks: 20, costPerSecond: 0.5)]
        terminal.authorityRevision = RPG_MAX_NORMAL_AUTHORITY_REVISION
        XCTAssertTrue(rpgClearTerminalUpkeeps(&terminal))
        XCTAssertEqual(terminal.authorityRevision, RPG_MAX_COUNTER)

        terminal.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 9,
                                            remainingTicks: 20, costPerSecond: 0.5)]
        let malformedMax = terminal
        XCTAssertFalse(rpgClearTerminalUpkeeps(&terminal))
        XCTAssertEqual(terminal, malformedMax)
        XCTAssertTrue(repairRPGCharacterState(terminal).activeUpkeeps.isEmpty)
    }

    func testPassiveCadenceHarvestBrewTrailAndCampContracts() {
        let world = World(dim: .overworld, seed: 103)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height))

        let scout = Player(world: world)
        scout.rpg = mastered(pathID: "ranger", starter: "trail_sense")
        scout.setPos(0.5, 64, 0.5)
        scout.onGround = true
        scout.sneaking = true
        world.rpgSimulationTick = 20
        let zombie = Zombie(world: world)
        zombie.setPos(7.5, 64, 0.5)
        let cow = Cow(world: world)
        cow.setPos(2.5, 64, 0.5)
        world.addEntity(scout)
        world.addEntity(zombie)
        world.addEntity(cow)
        scout.tickRPGState()
        XCTAssertTrue(zombie.hasEffect("glowing"))
        XCTAssertFalse(cow.hasEffect("glowing"), "Trail Sense only reveals legal hostiles")
        zombie.removeEffect("glowing")
        world.rpgSimulationTick = 21
        scout.tickRPGState()
        XCTAssertFalse(zombie.hasEffect("glowing"), "Trail Sense pulses only every 20 player ticks")

        scout.sneaking = false
        scout.moveForward = 0
        scout.moveStrafe = 0
        scout.vx = 0
        scout.vz = 0
        XCTAssertFalse(rpgCampcraftSafeRest(scout), "nearby legal hostile prevents safe rest")
        zombie.remove()
        world.removeEntity(zombie)
        XCTAssertTrue(rpgCampcraftSafeRest(scout))
        world.setBlock(0, 64, 0, Int(cell(B.magma_block)))
        XCTAssertFalse(rpgCampcraftSafeRest(scout), "explicit hazardous footing prevents safe rest")
        world.setBlock(0, 64, 0, 0)
        scout.hurtTime = 1
        XCTAssertFalse(rpgCampcraftSafeRest(scout))
        scout.hurtTime = 0

        let delver = Player(world: world)
        delver.rpg = mastered(pathID: "delver", starter: "vein_reader")
        delver.inventory[0] = ItemStack(iid("stone_pickaxe"), 1)
        delver.selectedSlot = 0
        let stoneCell = Int(cell(B.stone))
        XCTAssertTrue(rpgCanHarvestHardStoneOrOre(delver, cell: stoneCell))
        XCTAssertTrue(rpgIsHardStoneOrOreBlock(Int(B.iron_ore)))
        XCTAssertFalse(rpgIsHardStoneOrOreBlock(Int(B.dirt)))
        delver.rpg.fatigue = 0
        for _ in 0..<4 { rpgHandleBlockBreak(delver, cell: stoneCell, y: 62) }
        XCTAssertEqual(delver.rpg.fatigue, 1, accuracy: 0.000_001,
                       "Deep Reserves is capped at one fatigue per simulation tick")
        delver.inventory[0] = ItemStack(iid("stone_shovel"), 1)
        XCTAssertFalse(rpgCanHarvestHardStoneOrOre(delver, cell: stoneCell))
        let beforeWrongTool = delver.rpg.fatigue
        rpgHandleBlockBreak(delver, cell: stoneCell, y: 62)
        XCTAssertEqual(delver.rpg.fatigue, beforeWrongTool)

        let mender = Player(world: world)
        mender.rpg = mastered(pathID: "mender", starter: "herbal_lore")
        XCTAssertEqual(rpgCleanBrewDuration(mender, effectID: "speed", baseDuration: 101), 131)
        XCTAssertEqual(rpgCleanBrewDuration(mender, effectID: "poison", baseDuration: 101), 101)
        XCTAssertEqual(rpgCleanBrewDuration(mender, effectID: "instant_health", baseDuration: 1), 1)
        XCTAssertEqual(rpgCleanBrewDuration(mender, effectID: "speed",
                                            baseDuration: RPG_MAX_EFFECT_TICKS),
                       RPG_MAX_EFFECT_TICKS)
    }

    func testSustainableDelverExcavationUsesExactCoordinatesAndLegalHarvest() {
        let world = World(dim: .overworld, seed: 104)
        let delver = Player(world: world)
        delver.rpg = makeState(pathID: "delver", starter: "vein_reader")
        delver.inventory[0] = ItemStack(iid("stone_pickaxe"), 1)
        delver.selectedSlot = 0
        let stone = Int(cell(B.stone))

        rpgHandleBlockBreak(delver, cell: stone, x: 1, y: 62, z: 1)
        rpgHandleBlockBreak(delver, cell: stone, x: 1, y: 62, z: 1)
        XCTAssertEqual(delver.rpg.xp, 4, "the same excavation identity awards once while retained")
        rpgHandleBlockBreak(delver, cell: stone, x: 2, y: 62, z: 1)
        XCTAssertEqual(delver.rpg.xp, 8)

        rpgHandleBlockBreak(delver, cell: Int(cell(B.dirt)), x: 3, y: 62, z: 1)
        rpgHandleBlockBreak(delver, cell: stone, x: 4, y: 63, z: 1)
        delver.inventory[0] = ItemStack(iid("stone_shovel"), 1)
        rpgHandleBlockBreak(delver, cell: stone, x: 5, y: 62, z: 1)
        XCTAssertEqual(delver.rpg.xp, 8)

        let nether = World(dim: .nether, seed: 104)
        let netherDelver = Player(world: nether)
        netherDelver.rpg = makeState(pathID: "delver", starter: "vein_reader")
        netherDelver.inventory[0] = ItemStack(iid("stone_pickaxe"), 1)
        rpgHandleBlockBreak(netherDelver, cell: stone, x: 1, y: 20, z: 1)
        XCTAssertEqual(netherDelver.rpg.xp, 0)
    }

    func testProvisionAndEngineeringCraftClassificationAndRoundBoundedAwards() throws {
        XCTAssertTrue(rpgIsProvisionFoodItem(iid("bread")))
        XCTAssertTrue(rpgIsProvisionFoodItem(iid("golden_apple")))
        XCTAssertFalse(rpgIsProvisionFoodItem(iid("poisonous_potato")))
        XCTAssertFalse(rpgIsProvisionFoodItem(iid("pufferfish")))
        XCTAssertFalse(rpgIsProvisionFoodItem(iid("stone")))

        XCTAssertTrue(rpgIsEngineeringItem(iid("repeater")))
        XCTAssertTrue(rpgIsEngineeringItem(iid("stone_pickaxe")))
        XCTAssertFalse(rpgIsEngineeringItem(iid("stone_sword")))
        XCTAssertFalse(rpgIsEngineeringItem(iid("dirt")))

        let provisionRecipe = try XCTUnwrap(craftingRecipes.firstIndex {
            itemDef(craftingRecipeOutput($0).id).name == "mushroom_stew"
        })
        let repeaterRecipe = try XCTUnwrap(craftingRecipes.firstIndex {
            itemDef(craftingRecipeOutput($0).id).name == "repeater"
        })
        let world = World(dim: .overworld, seed: 105)

        let mender = Player(world: world)
        mender.rpg = makeState(pathID: "mender", starter: "herbal_lore")
        var personalResources: [ItemStack?] = [
            ItemStack(iid("brown_mushroom"), 8), ItemStack(iid("red_mushroom"), 8),
            ItemStack(iid("bowl"), 8),
        ]
        var personalGrid = [ItemStack?](repeating: nil, count: 4)
        let personalPlan = try XCTUnwrap(craftingPlans(
            for: personalResources, gridWidth: 2, gridHeight: 2
        ).first { $0.recipeIndex == provisionRecipe })
        XCTAssertTrue(populateCraftingGrid(personalPlan, grid: &personalGrid,
                                           inventory: &personalResources))
        let personalPreview = personalPlan.output.copy()
        personalPreview.count = personalPlan.output.count * 8
        let menderRevision = mender.rpg.authorityRevision
        let personalCommit = try XCTUnwrap(commitCraftingOutputRounds(
            player: mender, grid: &personalGrid, gridWidth: 2, gridHeight: 2,
            plan: personalPlan, displayedOutput: personalPreview, requestedRounds: 8
        ) { grid in
            guard grid.allSatisfy({ $0 == nil }) else { return false }
            return populateCraftingGrid(personalPlan, grid: &grid, inventory: &personalResources)
        })
        XCTAssertEqual(personalCommit.completedRounds, 8)
        XCTAssertEqual(personalCommit.output.count, personalPlan.output.count * 8)
        XCTAssertTrue(personalGrid.allSatisfy { $0 == nil },
                      "the 2x2 production seam must consume the final matched grid")
        XCTAssertTrue(personalResources.allSatisfy { $0 == nil },
                      "eight reported rounds must consume exactly eight real ingredient sets")
        XCTAssertEqual(personalCommit.progression.awardedXP, 48)
        XCTAssertEqual(mender.rpg.xpLedger.counts.heal, 8)
        XCTAssertEqual(mender.rpg.authorityRevision, menderRevision + 1,
                       "one output batch publishes one RPG revision")
        let cappedMender = mender.rpg
        XCTAssertEqual(rpgAwardCraftedRecipe(mender, recipeIndex: provisionRecipe).awardedXP, 0)
        XCTAssertEqual(mender.rpg, cappedMender)
        world.rpgSimulationTick = RPG_XP_WINDOW_TICKS
        XCTAssertEqual(rpgAwardCraftedRecipe(mender, recipeIndex: provisionRecipe).awardedXP, 6)

        world.rpgSimulationTick = 0
        let tinker = Player(world: world)
        tinker.rpg = makeState(pathID: "tinker", starter: "circuit_sense")
        var tableResources: [ItemStack?] = [
            ItemStack(iid("redstone_torch"), 16), ItemStack(iid("redstone"), 8),
            ItemStack(iid("stone"), 24),
        ]
        var tableGrid = [ItemStack?](repeating: nil, count: 9)
        let tablePlan = try XCTUnwrap(craftingPlans(
            for: tableResources, gridWidth: 3, gridHeight: 3
        ).first { $0.recipeIndex == repeaterRecipe })
        XCTAssertTrue(populateCraftingGrid(tablePlan, grid: &tableGrid,
                                           inventory: &tableResources))
        let tablePreview = tablePlan.output.copy()
        tablePreview.count = tablePlan.output.count * 8
        let tinkerRevision = tinker.rpg.authorityRevision
        let tableCommit = try XCTUnwrap(commitCraftingOutputRounds(
            player: tinker, grid: &tableGrid, gridWidth: 3, gridHeight: 3,
            plan: tablePlan, displayedOutput: tablePreview, requestedRounds: 8
        ) { grid in
            guard grid.allSatisfy({ $0 == nil }) else { return false }
            return populateCraftingGrid(tablePlan, grid: &grid, inventory: &tableResources)
        })
        XCTAssertEqual(tableCommit.completedRounds, 8)
        XCTAssertEqual(tableCommit.output.count, tablePlan.output.count * 8)
        XCTAssertTrue(tableGrid.allSatisfy { $0 == nil },
                      "the 3x3 production seam must consume the final matched grid")
        XCTAssertTrue(tableResources.allSatisfy { $0 == nil },
                      "eight reported rounds must consume exactly eight real ingredient sets")
        XCTAssertEqual(tableCommit.progression.awardedXP, 46,
                       "first recipe plus seven engineering rounds fills the eight-event window")
        XCTAssertEqual(tinker.rpg.xpLedger.counts.engineer, 8)
        XCTAssertEqual(tinker.rpg.authorityRevision, tinkerRevision + 1)
        XCTAssertEqual(rpgAwardCraftedRecipe(tinker, recipeIndex: repeaterRecipe).awardedXP, 0)
        world.rpgSimulationTick = RPG_XP_WINDOW_TICKS
        XCTAssertEqual(rpgAwardCraftedRecipe(tinker, recipeIndex: repeaterRecipe).awardedXP, 6,
                       "the persistent first-recipe bit does not repeat in a later window")

        let creative = Player(world: world)
        creative.rpg = makeState(pathID: "tinker", starter: "circuit_sense")
        creative.setGameMode(GameMode.creative)
        let creativeBefore = creative.rpg
        XCTAssertEqual(rpgAwardCraftedRecipe(creative, recipeIndex: repeaterRecipe,
                                             completedRounds: 8).awardedXP, 0)
        XCTAssertEqual(creative.rpg, creativeBefore)
    }

    func testSoftStepAndIndependentDurabilityCountersPersist() {
        let world = World(dim: .overworld, seed: 103)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height))
        let baseline = Player(world: world)
        baseline.rpg = mastered(pathID: "ranger", starter: "trail_sense")
        baseline.rpg.skillRanks["soft_step"] = 0
        let soft = Player(world: world)
        soft.rpg = mastered(pathID: "ranger", starter: "trail_sense")
        XCTAssertEqual(rpgSneakingMovementMultiplier(baseline, swiftSneakLevel: 0), 0.3,
                       accuracy: 0.000_001)
        XCTAssertEqual(rpgSneakingMovementMultiplier(soft, swiftSneakLevel: 0), 0.345,
                       accuracy: 0.000_001)

        let tuned = Player(world: world)
        tuned.rpg = mastered(pathID: "tinker", starter: "field_mod")
        XCTAssertEqual((1...4).map { _ in tuned.shouldPreserveRPGToolDurability() },
                       [false, false, false, true])
        XCTAssertNil(tuned.stats["rpg.salvageCounter"], "tool and salvage counters are independent")
        let saved = tuned.save()
        let restored = Player(world: world)
        restored.load(saved)
        XCTAssertEqual(restored.stats["rpg.toolTuneCounter"], 4)
        XCTAssertFalse(restored.shouldPreserveRPGToolDurability())

        let salvager = Player(world: world)
        salvager.rpg = mastered(pathID: "delver", starter: "salvage_eye")
        let results = (1...5).map { _ in salvager.shouldPreserveRPGSalvageDurability() }
        XCTAssertTrue(results[4], "rank-three Salvage Eye always preserves the fifth event")
        XCTAssertNil(salvager.stats["rpg.toolTuneCounter"])
    }

    func testEndedServantUpkeepRemovesOnlyExactOwnerSequence() {
        let world = World(dim: .overworld, seed: 106)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height))
        let player = Player(world: world)
        player.rpg = mastered(pathID: "arcanist", starter: "ritual_circle")
        player.rpg.preparedSpellIDs = ["summon_servant"]
        player.rpg.selectedPreparedSpellID = "summon_servant"
        player.rpg.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 4,
                                              remainingTicks: 1, costPerSecond: 0.5)]
        player.rpg = repairRPGCharacterState(player.rpg)
        world.addEntity(player)
        let first = Allay(world: world), second = Allay(world: world)
        first.setPos(1.5, 64, 0.5)
        second.setPos(2.5, 64, 0.5)
        world.addEntity(first)
        world.addEntity(second)
        let owner = player.effectiveRPGAuthorityID
        let firstDraft = RPGTemporaryEffectDraft(kind: .servant, ownerAuthorityID: owner,
                                                 ownerEntityID: player.id, ownerSequence: 4,
                                                 center: RPGBlockPosition(1, 64, 0),
                                                 durationTicks: 100)
        let secondDraft = RPGTemporaryEffectDraft(kind: .servant, ownerAuthorityID: owner,
                                                  ownerEntityID: player.id, ownerSequence: 5,
                                                  center: RPGBlockPosition(2, 64, 0),
                                                  durationTicks: 100)
        world.rpgTemporaryEffects = [
            RPGTemporaryEffect(draft: firstDraft, dimension: 0, createdTick: 0,
                               expiryTick: 100, entityID: first.id),
            RPGTemporaryEffect(draft: secondDraft, dimension: 0, createdTick: 0,
                               expiryTick: 100, entityID: second.id),
        ]

        player.tickRPGState()

        XCTAssertNil(world.rpgTemporaryEffect(for: firstDraft.key))
        XCTAssertNil(world.entityById[first.id])
        XCTAssertNotNil(world.rpgTemporaryEffect(for: secondDraft.key))
        XCTAssertNotNil(world.entityById[second.id])
    }

    func testGameCoreGlobalClockDrivesAuthorityButNeverSpeculatesOnLANClient() {
        let host = GameCore()
        host.createWorld(name: "RPG Clock Host", seedText: "107",
                         mode: GameMode.survival, difficulty: 2)
        host.player.rpg = makeState(pathID: "warden", starter: "guard_stance")
        host.player.rpg.activeCooldowns = [RPGCooldown(id: "guard_stance", remainingTicks: 5)]
        host.player.rpg.fatigue = max(0, rpgDerivedStats(host.player.rpg).maxFatigue - 1)
        let hostFatigue = host.player.rpg.fatigue

        _ = host.frame(dtMs: TICK_MS)

        XCTAssertEqual(host.rpgSimulationTick, 1)
        XCTAssertEqual(host.player.rpg.activeCooldowns.first?.remainingTicks, 4)
        XCTAssertGreaterThan(host.player.rpg.fatigue, hostFatigue)
        XCTAssertTrue(host.worlds.values.allSatisfy { $0.rpgSimulationTick == 1 })

        host.worldRec?.rpgSimulationTick = RPG_MAX_COUNTER
        for world in host.worlds.values { world.rpgSimulationTick = RPG_MAX_COUNTER }
        let stateAtClockCeiling = host.player.rpg
        _ = host.frame(dtMs: TICK_MS)
        XCTAssertEqual(host.rpgSimulationTick, RPG_MAX_COUNTER)
        XCTAssertEqual(host.player.rpg, stateAtClockCeiling,
                       "cooldowns, fatigue, and upkeeps must freeze when the global clock cannot advance")

        let client = GameCore()
        client.enterLANClientWorld(LANWorldSummary(
            worldID: "clock-host", worldName: "Clock Host", seed: 108,
            gameMode: GameMode.survival, difficulty: 2,
            dimension: Dim.overworld.rawValue, playerCount: 2
        ))
        client.player.rpg = makeState(pathID: "warden", starter: "guard_stance")
        client.player.rpg.activeCooldowns = [RPGCooldown(id: "guard_stance", remainingTicks: 5)]
        let clientBefore = client.player.rpg
        _ = client.frame(dtMs: TICK_MS)
        XCTAssertEqual(client.rpgSimulationTick, 0)
        XCTAssertEqual(client.player.rpg, clientBefore,
                       "a LAN render step cannot consume host-authoritative cooldown or fatigue")
    }

    func testClockCeilingCannotReplayRangerDelverOrCampcraftGameplayHooks() {
        let game = GameCore()
        game.createWorld(name: "RPG Gameplay Clock Ceiling", seedText: "112",
                         mode: GameMode.survival, difficulty: 2)
        let world = game.world
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        world.setBlock(0, 63, 0, Int(cell(B.stone)))
        world.setBlock(0, -49, 0, Int(cell(B.stone)))
        game.worldRec?.rpgSimulationTick = RPG_MAX_COUNTER
        for loadedWorld in game.worlds.values {
            loadedWorld.rpgSimulationTick = RPG_MAX_COUNTER
        }

        game.player.setPos(0.5, 64, 0.5)
        game.player.onGround = true
        game.player.rpg = makeState(pathID: "ranger", starter: "trail_sense")
        let rangerBefore = game.player.rpg
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertFalse(game.rpgClockAdvancedThisTick)
        XCTAssertEqual(game.player.rpg, rangerBefore,
                       "a saturated clock cannot replay the current-chunk discovery hook")

        game.player.setPos(0.5, -48, 0.5)
        game.player.onGround = true
        game.player.rpg = makeState(pathID: "delver", starter: "vein_reader")
        let delverBefore = game.player.rpg
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertFalse(game.rpgClockAdvancedThisTick)
        XCTAssertEqual(game.player.rpg, delverBefore,
                       "a saturated clock cannot replay depth milestones")

        game.player.setPos(0.5, 64, 0.5)
        game.player.onGround = true
        game.player.sprinting = false
        game.player.hurtTime = 0
        game.player.moveForward = 0
        game.player.moveStrafe = 0
        game.player.vx = 0
        game.player.vz = 0
        game.player.rpg = makeState(pathID: "ranger", starter: "campcraft")
        game.player.rpg.fatigue = 0
        let campcraftBefore = game.player.rpg
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertFalse(game.rpgClockAdvancedThisTick)
        XCTAssertEqual(game.player.rpg, campcraftBefore,
                       "a saturated clock cannot replay Campcraft restoration")
        XCTAssertEqual(game.rpgSimulationTick, RPG_MAX_COUNTER)
    }

    func testRPGGameRuleTransitionHookIsSynchronousEdgeTriggeredAndPreMutation() {
        let game = GameCore()
        game.createWorld(name: "RPG Rule Transition Hook", seedText: "113",
                         mode: GameMode.survival, difficulty: 2)
        var callbackValues: [Bool] = []
        var ruleValuesObservedInsideCallback: [Bool] = []
        game.onRPGGameRuleTransition = { [weak game] enabled in
            callbackValues.append(enabled)
            ruleValuesObservedInsideCallback.append(
                game?.world.rule(RPG_CLASSES_GAME_RULE) ?? enabled
            )
        }

        game.setGameRule(RPG_CLASSES_GAME_RULE, 1)
        XCTAssertTrue(callbackValues.isEmpty,
                      "writing the existing value is not a transition")

        game.setGameRule(RPG_CLASSES_GAME_RULE, 0)
        XCTAssertEqual(callbackValues, [false],
                       "the callback must have completed before setGameRule returns")
        XCTAssertEqual(ruleValuesObservedInsideCallback, [true],
                       "terminal authority cleanup runs before the disabling rule mutation")
        XCTAssertFalse(game.world.rule(RPG_CLASSES_GAME_RULE))

        game.setGameRule(RPG_CLASSES_GAME_RULE, 0)
        XCTAssertEqual(callbackValues, [false],
                       "repeated disabled writes cannot replay terminal persistence")

        game.setGameRule(RPG_CLASSES_GAME_RULE, 1)
        XCTAssertEqual(callbackValues, [false, true])
        XCTAssertEqual(ruleValuesObservedInsideCallback, [true, false],
                       "both edges are synchronously observable against the prior rule value")
        XCTAssertTrue(game.world.rule(RPG_CLASSES_GAME_RULE))

        game.setGameRule("keepInventory", 1)
        XCTAssertEqual(callbackValues, [false, true],
                       "unrelated rule changes cannot trigger RPG authority transitions")
    }

    func testLANHostMenuKeepsGlobalClockRunningWhilePlayerInputRemainsBlocked() throws {
        let game = GameCore()
        game.createWorld(name: "RPG Clock Menu Host", seedText: "110",
                         mode: GameMode.survival, difficulty: 2)
        let menuHost = RPGClockMenuHost()
        game.host = menuHost
        game.lanHostKeepsSimulationRunning = true
        game.player.rpg = makeState(pathID: "warden", starter: "guard_stance")
        game.player.rpg.activeCooldowns = [
            RPGCooldown(id: "guard_stance", remainingTicks: 5),
        ]

        let forwardKey = try XCTUnwrap(game.keybinds["forward"])
        game.keyDown(forwardKey, now: 1_000)
        game.player.moveForward = 1
        game.player.moveStrafe = 1
        game.player.jumping = true
        game.player.sprinting = true

        _ = game.frame(dtMs: TICK_MS)

        XCTAssertFalse(game.paused, "a LAN host menu must not pause authority")
        XCTAssertEqual(game.rpgSimulationTick, 1)
        XCTAssertEqual(game.player.rpg.activeCooldowns.first?.remainingTicks, 4)
        XCTAssertEqual(game.player.moveForward, 0,
                       "held movement keys cannot drive the local player through a menu")
        XCTAssertEqual(game.player.moveStrafe, 0)
        XCTAssertFalse(game.player.jumping)
        XCTAssertFalse(game.player.sprinting)

        menuHost.showingScreen = false
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertEqual(game.rpgSimulationTick, 2)
        XCTAssertEqual(game.player.moveForward, 1,
                       "the held key proves the preceding menu tick blocked input rather than losing it")
    }

    func testSyntheticTickZeroPlayerStateBatchCannotRewindOrPoisonNewerClientClock() {
        let game = GameCore()
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "clock-batch-host", worldName: "Clock Batch Host", seed: 111,
            gameMode: GameMode.survival, difficulty: 2,
            dimension: Dim.overworld.rawValue, playerCount: 2
        ))
        let session = LANMultiplayerClientSession()
        let authoritative = LANReplicationBatch(tick: 750, fullSnapshot: false)
        _ = session.apply(authoritative)
        _ = game.applyLANHostReplicationBatch(authoritative)

        let directPlayerState = LANPlayerState(
            playerID: "peer-direct", displayName: "Direct Peer",
            x: 1.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
            health: 7, hunger: 18, selectedHotbarSlot: 2,
            gameMode: GameMode.survival
        )
        let synthetic = LANReplicationBatch(
            tick: 0, fullSnapshot: false, players: [directPlayerState]
        )
        _ = session.apply(synthetic)
        _ = game.applyLANHostReplicationBatch(synthetic)

        XCTAssertEqual(session.players[directPlayerState.playerID], directPlayerState,
                       "the legacy direct-player-state envelope is still processed")
        XCTAssertEqual(session.latestTick, 750,
                       "its synthetic tick cannot rewind the client-session authority clock")
        XCTAssertEqual(game.rpgSimulationTick, 750)
        XCTAssertTrue(game.worlds.values.allSatisfy { $0.rpgSimulationTick == 750 },
                      "its synthetic tick cannot rewind any loaded dimension clock")

        let next = LANReplicationBatch(tick: 751, fullSnapshot: false)
        _ = session.apply(next)
        _ = game.applyLANHostReplicationBatch(next)
        XCTAssertEqual(session.latestTick, 751,
                       "a synthetic zero cannot poison acceptance of the next host tick")
        XCTAssertEqual(game.rpgSimulationTick, 751)

        let malformedPlayer = LANPlayerState(
            playerID: "malformed-tick", displayName: "Malformed Tick",
            x: 0, y: 64, z: 0, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        )
        for invalidTick in [-1, RPG_MAX_COUNTER + 1] {
            let invalid = LANReplicationBatch(
                tick: invalidTick, fullSnapshot: false, players: [malformedPlayer]
            )
            _ = session.apply(invalid)
            _ = game.applyLANHostReplicationBatch(invalid)
        }
        XCTAssertNil(session.players[malformedPlayer.playerID],
                     "out-of-range envelopes fail before processing their player payload")
        XCTAssertEqual(session.latestTick, 751)
        XCTAssertEqual(game.rpgSimulationTick, 751)
        XCTAssertTrue(game.worlds.values.allSatisfy { $0.rpgSimulationTick == 751 })
    }

    func testGlobalClockExpiresGuardedEffectInInactiveDimension() {
        let game = GameCore()
        game.createWorld(name: "RPG Cross-Dimension Clock", seedText: "109",
                         mode: GameMode.survival, difficulty: 2)
        let nether = game.worlds[.nether]!
        nether.setChunk(Chunk(cx: 0, cz: 0, minY: nether.info.minY, height: nether.info.height))
        let position = RPGBlockPosition(1, 64, 1)
        nether.setBlock(position.x, position.y, position.z, Int(cell(B.torch)))
        let draft = RPGTemporaryEffectDraft(
            kind: .mageLight, ownerAuthorityID: "clock-owner", ownerEntityID: nil,
            ownerSequence: 1, center: position, durationTicks: 1,
            guardedBlock: RPGGuardedTemporaryBlock(position: position, originalCell: 0,
                                                   temporaryCell: Int(cell(B.torch)))
        )
        XCTAssertTrue(nether.registerRPGTemporaryEffect(draft))
        XCTAssertEqual(game.dim, .overworld)

        _ = game.frame(dtMs: TICK_MS)

        XCTAssertEqual(nether.rpgSimulationTick, 1)
        XCTAssertNil(nether.rpgTemporaryEffect(for: draft.key))
        XCTAssertEqual(nether.getBlock(position.x, position.y, position.z), 0)
        XCTAssertEqual(game.dim, .overworld)
    }

    private func makeState(pathID: String, starter: String) -> RPGCharacterState {
        try! rpgCreateCharacter(RPGCreationDraft(pathID: pathID,
                                                 attributes: rpgCreationPreset(pathID: pathID)!,
                                                 starterSkillID: starter)).get()
    }

    private func mastered(pathID: String, starter: String) -> RPGCharacterState {
        var state = makeState(pathID: pathID, starter: starter)
        state.xp = rpgXPRequiredForLevel(20)
        state.level = 20
        if let branch = rpgBranchDefinition(state.specializationBranchID) {
            for skill in branch.skillIDs { state.skillRanks[skill] = 3 }
        }
        return repairRPGCharacterState(state)
    }

    private func inventorySignature(_ inventory: [ItemStack?]) -> [String] {
        inventory.map { stack in
            guard let stack else { return "-" }
            return "\(itemDef(stack.id).name):\(stack.count):\(stack.data.potion ?? "-")"
        }
    }
}

private final class RPGClockMenuHost: GameHost {
    var showingScreen = true

    func hasScreen() -> Bool { showingScreen }
    func screenPausesGame() -> Bool { true }
    func openScreen(_ kind: String, _ data: ScreenData?) {}
    func openTrading(_ villager: Mob) {}
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
    func openChat(_ prefix: String) {}
    func openDeathScreen(_ message: String) {}
    func openPauseScreen() {}
    func openTitleScreen() {}
    func closeAllScreens() {}
    func releasePointer() {}
    func capturePointer() {}
    func showActionBar(_ text: String, _ time: Int) {}
    func pushChat(_ line: String) {}
    func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double,
                   _ volume: Double, _ pitch: Double) {}
    func playUI(_ name: String) {}
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double,
                          _ yaw: Double) {}
    func tickMusic(_ mood: String, _ enabled: Bool) {}
    func stopDisc() {}
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double,
                      _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double,
                            _ groundY: Double) {}
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int,
                    _ mesh: MeshOutput) {}
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}
    func clearAllSections() {}
}
