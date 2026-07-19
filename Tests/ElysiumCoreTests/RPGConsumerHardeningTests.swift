import XCTest
@testable import ElysiumCore

@MainActor
final class RPGConsumerHardeningTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllRecipes()
        registerAllSystems()
    }

    func testWeatherEyeHerbalLoreAndHUDGateAtEveryRank() {
        let world = makeWorld(seed: 801)
        let ranger = Player(world: world)
        ranger.rpg = mastered(pathID: "ranger", starter: "campcraft")
        world.raining = true
        // Ranks 1-3: transition timer only, byte-identical to the shipped v2 output (no incoming
        // kind). Ranks 4-5: the same 20-tick quantum PLUS the named incoming weather kind.
        let weatherQuanta = [600, 200, 20, 20, 20]
        let weatherSeconds = [30, 10, 1, 1, 1]
        for rank in 1...RPG_SKILL_RANK_CAP {
            ranger.rpg.skillRanks["weather_eye"] = rank
            world.weatherTimer = weatherQuanta[rank - 1]
            let incoming = rank >= 4 ? "clear" : nil // currently raining -> next transition clears
            let status = rpgWeatherEyeStatus(ranger)
            XCTAssertEqual(status, .active(currentWeather: "rain",
                                           roundedTransitionTicks: weatherQuanta[rank - 1],
                                           roundedTransitionSeconds: weatherSeconds[rank - 1],
                                           incomingWeather: incoming))
            let line = rpgHUDInsightLines(ranger).first
            if rank >= 4 {
                // Rank 4+ names the incoming kind: "Weather rain · Clear in 1s".
                XCTAssertEqual(line, "Weather rain · Clear in \(weatherSeconds[rank - 1])s")
            } else {
                XCTAssertEqual(line, "Weather rain · change ~\(weatherSeconds[rank - 1])s")
            }
        }
        world.gameRules["doWeatherCycle"] = 0
        XCTAssertEqual(rpgWeatherEyeStatus(ranger), .cycleLocked(currentWeather: "rain"))
        XCTAssertEqual(rpgHUDInsightLines(ranger).first, "Weather rain · cycle locked")
        XCTAssertFalse(rpgHUDInsightLines(ranger).joined().contains("change ~"))
        world.gameRules["doWeatherCycle"] = 1

        // Cross-dimension: a rank-5 Weather Eye senses the overworld surface weather from the Nether.
        let nether = World(dim: .nether, seed: 813)
        nether.setChunk(Chunk(cx: 0, cz: 0, minY: nether.info.minY,
                              height: nether.info.height))
        let netherRanger = Player(world: nether)
        netherRanger.rpg = mastered(pathID: "ranger", starter: "campcraft")

        // With no overworld source wired, even rank 5 has nothing to read: unavailable (not faked).
        XCTAssertEqual(rpgWeatherEyeStatus(netherRanger),
                       .unavailable(dimensionName: "Nether"))
        XCTAssertEqual(rpgHUDInsightLines(netherRanger).first,
                       "Weather unavailable in Nether")

        // Rank 4 never reaches across dimensions, even with a source available.
        nether.overworldWeatherSource = world
        world.raining = true
        world.thundering = false
        world.weatherTimer = 20
        netherRanger.rpg.skillRanks["weather_eye"] = 4
        XCTAssertEqual(rpgWeatherEyeStatus(netherRanger),
                       .unavailable(dimensionName: "Nether"))

        // Rank 5 reads the overworld weather (rain -> incoming clear) from the Nether.
        netherRanger.rpg.skillRanks["weather_eye"] = 5
        XCTAssertEqual(rpgWeatherEyeStatus(netherRanger),
                       .active(currentWeather: "rain", roundedTransitionTicks: 20,
                               roundedTransitionSeconds: 1, incomingWeather: "clear"))
        XCTAssertEqual(rpgHUDInsightLines(netherRanger).first, "Weather rain · Clear in 1s")

        // When the overworld is clear, a rank-5 Nether reading names the incoming rain.
        world.raining = false
        world.thundering = false
        world.weatherTimer = 40
        XCTAssertEqual(rpgWeatherEyeStatus(netherRanger),
                       .active(currentWeather: "clear", roundedTransitionTicks: 40,
                               roundedTransitionSeconds: 2, incomingWeather: "rain"))
        XCTAssertEqual(rpgHUDInsightLines(netherRanger).first, "Weather clear · Rain in 2s")

        let mender = Player(world: world)
        mender.rpg = mastered(pathID: "mender", starter: "herbal_lore")
        // Herbal Lore's rank values are [0.5, 1.0, 1.5, 2.0, 2.5], but a single consume is capped
        // by the 1.5-fatigue-per-tick Herbal Lore budget, so ranks 4-5 restore 1.5 in one bite.
        for rank in 1...RPG_SKILL_RANK_CAP {
            mender.rpg.skillRanks["herbal_lore"] = rank
            mender.rpg.fatigue = 0
            world.rpgSimulationTick = rank
            XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("apple")),
                           min(1.5, [0.5, 1.0, 1.5, 2.0, 2.5][rank - 1]), accuracy: 0.000_001)
        }
        mender.rpg.skillRanks["herbal_lore"] = 3
        mender.rpg.fatigue = 0
        world.rpgSimulationTick += 1
        mender.restoreRPGFatigue(1, source: .harvest, perTickCap: 1)
        XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("apple")),
                       1.5, accuracy: 0.000_001,
                       "a Deep Reserves harvest-budget grant cannot consume Herbal Lore's budget")
        XCTAssertEqual(mender.rpg.fatigue, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("apple")), 0,
                       "repeated Herbal Lore grants remain bounded within their own tick budget")

        mender.rpg.fatigue = 0
        world.rpgSimulationTick += 1
        rpgHandleBlockBreak(mender, cell: Int(cell(B.wheat, 7)), y: 64)
        // Green Thumb is mastered (rank 5) -> 0.5 fatigue per mature crop.
        XCTAssertEqual(mender.rpg.fatigue, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("apple")),
                       1.5, accuracy: 0.000_001,
                       "Green Thumb and Herbal Lore have independent source budgets")
        mender.rpg.fatigue = 0
        world.rpgSimulationTick += 1
        XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("cooked_beef")), 0)
        XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("pufferfish")), 0)

        mender.rpg.skillRanks["herbal_lore"] = 3
        mender.rpg.fatigue = 0
        mender.inventory[0] = ItemStack(iid("apple"), 1)
        mender.selectedSlot = 0
        world.rpgSimulationTick += 1
        mender.beginUsingMainHand()
        finishUsingItem(InteractCtx(world: world, player: mender))
        XCTAssertEqual(mender.rpg.fatigue, 1.5, accuracy: 0.000_001,
                       "the real finishUsingItem path consumes Herbal Lore")

        world.gameRules[RPG_CLASSES_GAME_RULE] = 0
        XCTAssertNil(rpgWeatherEyeStatus(ranger))
        XCTAssertEqual(rpgRestoreHerbalLoreFatigue(mender, consumedItemID: iid("apple")), 0)
        XCTAssertFalse(rpgHUDVisible(ranger))
        XCTAssertTrue(rpgHUDInsightLines(ranger).isEmpty)

        let nominalLayout = rpgHUDInsightLayout(viewWidth: 854, viewHeight: 480)
        XCTAssertGreaterThanOrEqual(nominalLayout.maximumWidth, 300,
                                    "normal HUD widths preserve the full insight text")
        XCTAssertGreaterThanOrEqual(nominalLayout.x, 854 / 2 + 14)
        XCTAssertLessThanOrEqual(nominalLayout.x + Double(nominalLayout.maximumWidth), 854 - 6)
        let narrowLayout = rpgHUDInsightLayout(viewWidth: 80, viewHeight: 60)
        XCTAssertGreaterThanOrEqual(narrowLayout.maximumWidth, 0)
        XCTAssertLessThanOrEqual(narrowLayout.x + Double(narrowLayout.maximumWidth), 80 - 6)

        world.gameRules[RPG_CLASSES_GAME_RULE] = 1
        ranger.setGameMode(GameMode.creative)
        XCTAssertEqual(rpgHUDDrawPlan(ranger, screenOpen: false),
                       RPGHUDDrawPlan(showInsights: true, showQuickSlots: true,
                                      liftSurvivalHUD: false),
                       "enabled Creative still renders fatigue and the RPG quick-slot row")
        XCTAssertEqual(rpgHUDDrawPlan(ranger, screenOpen: true),
                       RPGHUDDrawPlan(showInsights: false, showQuickSlots: true,
                                      liftSurvivalHUD: false),
                       "crosshair inspection text is hidden while a screen is open")

        var cache = RPGHUDInsightCache()
        var computations = 0
        let firstKey = try! XCTUnwrap(rpgHUDInsightCacheKey(ranger, screenOpen: false))
        for _ in 0..<8 {
            _ = cache.resolve(key: firstKey) {
                computations += 1
                return rpgHUDInsightLines(ranger)
            }
        }
        XCTAssertEqual(computations, 1, "render frames share one insight computation per tick")
        world.rpgSimulationTick += 1
        let nextKey = try! XCTUnwrap(rpgHUDInsightCacheKey(ranger, screenOpen: false))
        _ = cache.resolve(key: nextKey) { computations += 1; return [] }
        XCTAssertEqual(computations, 2)
        XCTAssertTrue(cache.resolve(key: nil) { computations += 1; return ["stale"] }.isEmpty)
        _ = cache.resolve(key: nextKey) { computations += 1; return [] }
        XCTAssertEqual(computations, 3, "hiding resets the cache before the HUD is shown again")
    }

    /// Amendment C5 / acceptance criterion 13: each of Weather Eye's five ranks is a distinct
    /// experience -- coarse (30s), finer (10s), precise (1s), named-forecast (rank 4), and
    /// named-forecast-that-works-anywhere (rank 5). No rank is an empty tier.
    func testWeatherEyeFiveRanksAreFiveDistinctExperiences() {
        let world = makeWorld(seed: 850)
        let ranger = Player(world: world)
        ranger.rpg = mastered(pathID: "ranger", starter: "campcraft")
        world.raining = false // clear -> next transition brings rain
        world.weatherTimer = 33
        var lines: [String] = []
        for rank in 1...RPG_SKILL_RANK_CAP {
            ranger.rpg.skillRanks["weather_eye"] = rank
            lines.append(rpgHUDInsightLines(ranger).first ?? "<none>")
        }
        XCTAssertEqual(lines, [
            "Weather clear · change ~30s",  // rank 1: 33 -> ceil to 600 ticks = 30s
            "Weather clear · change ~10s",  // rank 2: 33 -> ceil to 200 ticks = 10s
            "Weather clear · change ~2s",   // rank 3: 33 -> ceil to 40 ticks = 2s
            "Weather clear · Rain in 2s",   // rank 4: names the incoming rain
            "Weather clear · Rain in 2s",   // rank 5: same forecast, plus cross-dimension reach
        ])
        // Rank 4 and rank 5 are only distinguishable by reach: rank 5 forecasts from the Nether.
        let nether = World(dim: .nether, seed: 851)
        nether.setChunk(Chunk(cx: 0, cz: 0, minY: nether.info.minY, height: nether.info.height))
        nether.overworldWeatherSource = world
        let netherRanger = Player(world: nether)
        netherRanger.rpg = mastered(pathID: "ranger", starter: "campcraft")
        netherRanger.rpg.skillRanks["weather_eye"] = 4
        XCTAssertEqual(rpgWeatherEyeStatus(netherRanger), .unavailable(dimensionName: "Nether"))
        netherRanger.rpg.skillRanks["weather_eye"] = 5
        XCTAssertEqual(rpgHUDInsightLines(netherRanger).first, "Weather clear · Rain in 2s")
    }

    /// Rank 5 senses the End's overworld weather too, not just the Nether.
    func testWeatherEyeRankFiveReachesFromTheEnd() {
        let overworld = makeWorld(seed: 860)
        overworld.raining = true
        overworld.thundering = true
        overworld.weatherTimer = 20
        let end = World(dim: .end, seed: 861)
        end.setChunk(Chunk(cx: 0, cz: 0, minY: end.info.minY, height: end.info.height))
        end.overworldWeatherSource = overworld
        let ender = Player(world: end)
        ender.rpg = mastered(pathID: "ranger", starter: "campcraft")
        ender.rpg.skillRanks["weather_eye"] = 4
        XCTAssertEqual(rpgWeatherEyeStatus(ender), .unavailable(dimensionName: "End"))
        ender.rpg.skillRanks["weather_eye"] = 5
        // Overworld is thundering -> reported as "thunder", incoming transition clears.
        XCTAssertEqual(rpgWeatherEyeStatus(ender),
                       .active(currentWeather: "thunder", roundedTransitionTicks: 20,
                               roundedTransitionSeconds: 1, incomingWeather: "clear"))
        XCTAssertEqual(rpgHUDInsightLines(ender).first, "Weather thunder · Clear in 1s")
    }

    /// Fortune Read's registry benefit text promises "Reveal two items" at rank 4 and "Reveal
    /// three items" at rank 5 (ranks 1-3 all stay at one item, differing only in fill precision).
    /// This pins the consumer to that scaling: revealed item count is 1/1/1/2/3, and a container
    /// with fewer occupied slots than the rank's reveal count is bounded rather than padded with
    /// duplicates.
    func testFortuneReadRevealsScaledItemCountsAtRanksFourAndFive() throws {
        func itemCount(_ message: String) -> Int { message.components(separatedBy: "×").count - 1 }

        let world = makeWorld(seed: 870)
        let delver = Player(world: world)
        delver.rpg = mastered(pathID: "delver", starter: "fortune_read")
        delver.rpg.preparedSkillIDs = ["fortune_read"]
        delver.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: "fortune_read")
        delver.rpg = repairRPGCharacterState(delver.rpg)
        delver.setPos(0.5, 64, 0.5)
        world.addEntity(delver)
        world.setBlock(0, 65, 4, Int(cell(B.chest)))
        let be = makeContainerBE(0, 65, 4, 6)
        be.items![0] = ItemStack(iid("torch"), 3)
        be.items![1] = ItemStack(iid("redstone"), 5)
        be.items![2] = ItemStack(iid("bread"), 1)
        world.setBlockEntity(be)

        for rank in 1...3 {
            delver.rpg.skillRanks["fortune_read"] = rank
            delver.rpg.activeCooldowns = []
            delver.rpg.fatigue = rpgDerivedStats(delver.rpg).maxFatigue
            let outcome = rpgUsePreparedSkill(delver, skillID: "fortune_read")
            guard case .success(let result) = outcome else {
                return XCTFail("rank \(rank) fortune_read must succeed against a loaded container: \(outcome)")
            }
            XCTAssertEqual(itemCount(result.message), 1, "rank \(rank) reveals exactly one item")
        }
        delver.rpg.skillRanks["fortune_read"] = 4
        delver.rpg.activeCooldowns = []
        delver.rpg.fatigue = rpgDerivedStats(delver.rpg).maxFatigue
        guard case .success(let rankFour) = rpgUsePreparedSkill(delver, skillID: "fortune_read") else {
            return XCTFail("rank 4 fortune_read must succeed")
        }
        XCTAssertEqual(itemCount(rankFour.message), 2, "rank 4 must reveal two items per its benefit text")
        XCTAssertTrue(rankFour.message.hasSuffix("3/6 slots filled"))

        delver.rpg.skillRanks["fortune_read"] = 5
        delver.rpg.activeCooldowns = []
        delver.rpg.fatigue = rpgDerivedStats(delver.rpg).maxFatigue
        guard case .success(let rankFive) = rpgUsePreparedSkill(delver, skillID: "fortune_read") else {
            return XCTFail("rank 5 fortune_read must succeed")
        }
        XCTAssertEqual(itemCount(rankFive.message), 3, "rank 5 must reveal three items per its benefit text")

        let sparseWorld = makeWorld(seed: 871)
        let sparseDelver = Player(world: sparseWorld)
        sparseDelver.rpg = mastered(pathID: "delver", starter: "fortune_read")
        sparseDelver.rpg.preparedSkillIDs = ["fortune_read"]
        sparseDelver.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: "fortune_read")
        sparseDelver.rpg = repairRPGCharacterState(sparseDelver.rpg)
        sparseDelver.setPos(0.5, 64, 0.5)
        sparseWorld.addEntity(sparseDelver)
        sparseWorld.setBlock(0, 65, 4, Int(cell(B.chest)))
        let sparseBE = makeContainerBE(0, 65, 4, 6)
        sparseBE.items![0] = ItemStack(iid("torch"), 1)
        sparseWorld.setBlockEntity(sparseBE)
        guard case .success(let sparseResult) = rpgUsePreparedSkill(sparseDelver, skillID: "fortune_read") else {
            return XCTFail("rank 5 against a one-item container must still succeed")
        }
        XCTAssertEqual(itemCount(sparseResult.message), 1,
                       "reveal count is bounded by occupied slots, not padded with duplicates")
    }

    func testCircuitSenseRanksAndBoundedSourceTrace() throws {
        let world = makeWorld(seed: 802)
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 10 * .pi / 180
        world.setChunk(Chunk(cx: -1, cz: 0, minY: world.info.minY,
                             height: world.info.height))
        world.setBlock(0, 65, 3, Int(cell(B.repeater_on, 11)), SET_SILENT)
        world.setBlock(-1, 65, 3, Int(cell(B.redstone_block)), SET_SILENT)
        player.rpg = mastered(pathID: "tinker", starter: "circuit_sense")

        player.rpg.skillRanks["circuit_sense"] = 1
        var reading = try XCTUnwrap(rpgCircuitSenseInspection(player))
        XCTAssertEqual(reading.range, 4)
        XCTAssertTrue(reading.powered)
        XCTAssertNil(reading.configuredDelayTicks)
        XCTAssertNil(reading.powerSourceDirection)

        player.rpg.skillRanks["circuit_sense"] = 2
        reading = try XCTUnwrap(rpgCircuitSenseInspection(player))
        XCTAssertEqual(reading.range, 6)
        XCTAssertEqual(reading.configuredDelayTicks, 6)
        XCTAssertNil(reading.powerSourceDirection)

        player.rpg.skillRanks["circuit_sense"] = 3
        reading = try XCTUnwrap(rpgCircuitSenseInspection(player))
        XCTAssertEqual(reading.range, 8)
        XCTAssertEqual(reading.powerSourceDirection, "west")
        XCTAssertTrue(rpgHUDInsightLines(player).contains { $0.contains("Source west") })

        XCTAssertEqual(rpgNearestPoweredRedstoneSource(world, x: -1, y: 65, z: 3)?.direction,
                       "self", "an intrinsic redstone block terminates at itself")

        let relayed = makeWorld(seed: 808)
        for x in 0...2 { relayed.setBlock(x, 63, 0, Int(cell(B.stone)), SET_SILENT) }
        relayed.setBlock(0, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        relayed.setBlock(1, 64, 0, Int(cell(B.repeater_on, 3)), SET_SILENT)
        relayed.setBlock(2, 64, 0, Int(cell(B.redstone_wire, 15)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(relayed, x: 1, y: 64, z: 0)?.direction,
                       "west", "inspecting a repeater follows its rear input")
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(relayed, x: 2, y: 64, z: 0)?.direction,
                       "west", "a downstream wire traverses the relay to its true source")

        let conducted = makeWorld(seed: 810)
        conducted.setBlock(0, 64, 0, Int(cell(B.redstone_wire, 15)), SET_SILENT)
        conducted.setBlock(1, 64, 0, Int(cell(B.stone)), SET_SILENT)
        conducted.setBlock(2, 64, 0, Int(cell(B.repeater_on, 2)), SET_SILENT)
        conducted.setBlock(3, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        let conductedBefore = (0...3).map { conducted.getBlock($0, 64, 0) }
        XCTAssertEqual(powerAt(conducted, 0, 64, 0, true), 15)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(conducted, x: 0, y: 64, z: 0)?.direction,
                       "east", "wire traces through the exact strongly powered solid")
        XCTAssertNil(rpgNearestPoweredRedstoneSource(conducted, x: 0, y: 64, z: 0,
                                                     nodeLimit: 3))
        XCTAssertEqual((0...3).map { conducted.getBlock($0, 64, 0) }, conductedBefore)

        let relayBehindSolid = makeWorld(seed: 811)
        relayBehindSolid.setBlock(0, 64, 0, Int(cell(B.repeater_on, 2)), SET_SILENT)
        relayBehindSolid.setBlock(1, 64, 0, Int(cell(B.stone)), SET_SILENT)
        relayBehindSolid.setBlock(2, 64, 0, Int(cell(B.repeater_on, 2)), SET_SILENT)
        relayBehindSolid.setBlock(3, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(relayBehindSolid,
                                                       x: 0, y: 64, z: 0)?.direction,
                       "east", "a relay rear input enqueues rather than terminates at a conductor")

        let conductedBoundary = makeWorld(seed: 812)
        conductedBoundary.setChunk(Chunk(cx: 1, cz: 0,
                                         minY: conductedBoundary.info.minY,
                                         height: conductedBoundary.info.height))
        conductedBoundary.setBlock(15, 64, 0, Int(cell(B.redstone_wire, 15)), SET_SILENT)
        conductedBoundary.setBlock(16, 64, 0, Int(cell(B.stone)), SET_SILENT)
        conductedBoundary.setBlock(17, 64, 0, Int(cell(B.repeater_on, 2)), SET_SILENT)
        conductedBoundary.setBlock(18, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(conductedBoundary,
                                                       x: 15, y: 64, z: 0)?.direction, "east")
        conductedBoundary.removeChunk(1, 0)
        XCTAssertNil(rpgNearestPoweredRedstoneSource(conductedBoundary,
                                                     x: 15, y: 64, z: 0))

        let directionalConsumer = makeWorld(seed: 815)
        directionalConsumer.setChunk(Chunk(cx: -1, cz: 0,
                                           minY: directionalConsumer.info.minY,
                                           height: directionalConsumer.info.height))
        directionalConsumer.setChunk(Chunk(cx: 0, cz: -1,
                                           minY: directionalConsumer.info.minY,
                                           height: directionalConsumer.info.height))
        directionalConsumer.setBlock(0, 64, 0, Int(cell(B.redstone_lamp)), SET_SILENT)
        directionalConsumer.setBlock(-1, 64, 0, Int(cell(B.stone)), SET_SILENT)
        directionalConsumer.setBlock(-2, 64, 0, Int(cell(B.repeater_on, 3)), SET_SILENT)
        directionalConsumer.setBlock(-3, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        directionalConsumer.setBlock(1, 63, 0, Int(cell(B.stone)), SET_SILENT)
        directionalConsumer.setBlock(1, 64, 0,
                                     Int(cell(B.redstone_wire, 15)), SET_SILENT)
        directionalConsumer.setBlock(1, 64, -1,
                                     Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertEqual(powerAt(directionalConsumer, 0, 64, 0, true), 15)
        XCTAssertEqual(emittedPower(directionalConsumer, 1, 64, 0, Dir.west), 0,
                       "the unrelated powered wire does not emit toward the lamp")
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(directionalConsumer,
                                                       x: 0, y: 64, z: 0)?.direction,
                       "west", "consumer admission follows exact directional wire power")

        let comparator = makeWorld(seed: 809)
        comparator.setChunk(Chunk(cx: 0, cz: -1, minY: comparator.info.minY,
                                  height: comparator.info.height))
        comparator.setBlock(1, 64, 0, Int(cell(B.comparator_on, 3)), SET_SILENT)
        comparator.setBlock(0, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        comparator.setBlock(1, 64, 1, Int(cell(B.redstone_block)), SET_SILENT)
        let comparatorData = BlockEntityData(type: "comparator", x: 1, y: 64, z: 0)
        comparatorData.output = 15
        comparator.setBlockEntity(comparatorData)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(comparator, x: 1, y: 64, z: 0)?.direction,
                       "west", "comparator ties use rear, left, then right input order")

        let traceWorld = makeWorld(seed: 803)
        for x in 0...3 { traceWorld.setBlock(x, 63, 0, Int(cell(B.stone)), SET_SILENT) }
        traceWorld.setBlock(0, 64, 0, Int(cell(B.redstone_wire, 12)), SET_SILENT)
        traceWorld.setBlock(1, 64, 0, Int(cell(B.redstone_wire, 13)), SET_SILENT)
        traceWorld.setBlock(2, 64, 0, Int(cell(B.redstone_wire, 14)), SET_SILENT)
        traceWorld.setBlock(3, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        let before = (0...3).map { traceWorld.getBlock($0, 64, 0) }
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(traceWorld, x: 0, y: 64, z: 0)?.direction,
                       "east")
        XCTAssertEqual((0...3).map { traceWorld.getBlock($0, 64, 0) }, before,
                       "Circuit Sense tracing is read-only")
        XCTAssertNil(rpgNearestPoweredRedstoneSource(traceWorld, x: 0, y: 64, z: 0,
                                                     nodeLimit: 2))

        let boundary = makeWorld(seed: 806)
        boundary.setChunk(Chunk(cx: 1, cz: 0, minY: boundary.info.minY,
                                height: boundary.info.height))
        boundary.setBlock(15, 63, 0, Int(cell(B.stone)), SET_SILENT)
        boundary.setBlock(16, 63, 0, Int(cell(B.stone)), SET_SILENT)
        boundary.setBlock(15, 64, 0, Int(cell(B.redstone_wire, 15)), SET_SILENT)
        boundary.setBlock(16, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(boundary, x: 15, y: 64, z: 0)?.direction,
                       "east")
        boundary.removeChunk(1, 0)
        XCTAssertNil(rpgNearestPoweredRedstoneSource(boundary, x: 15, y: 64, z: 0),
                     "the trace cannot inspect a powered source across an unloaded boundary")

        let tieWorld = makeWorld(seed: 804)
        tieWorld.setChunk(Chunk(cx: -1, cz: 0, minY: tieWorld.info.minY,
                                height: tieWorld.info.height))
        for x in -1...1 { tieWorld.setBlock(x, 63, 0, Int(cell(B.stone)), SET_SILENT) }
        tieWorld.setBlock(0, 64, 0, Int(cell(B.redstone_wire, 15)), SET_SILENT)
        tieWorld.setBlock(-1, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        tieWorld.setBlock(1, 64, 0, Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(tieWorld, x: 0, y: 64, z: 0)?.direction,
                       "west", "frozen direction order breaks equal-distance ties")

        let stepped = makeWorld(seed: 805)
        stepped.setBlock(0, 63, 0, Int(cell(B.stone)), SET_SILENT)
        stepped.setBlock(0, 64, 0, Int(cell(B.redstone_wire, 12)), SET_SILENT)
        stepped.setBlock(1, 65, 0, Int(cell(B.redstone_wire, 14)), SET_SILENT)
        stepped.setBlock(2, 65, 0, Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertNil(rpgNearestPoweredRedstoneSource(stepped, x: 0, y: 64, z: 0),
                     "an unsupported diagonal wire is not an up-step connection")
        stepped.setBlock(1, 64, 0, Int(cell(B.stone)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(stepped, x: 0, y: 64, z: 0)?.direction,
                       "east")
        stepped.setBlock(0, 65, 0, Int(cell(B.stone)), SET_SILENT)
        XCTAssertFalse(wireConnectsDir(stepped, 0, 64, 0, 3),
                       "an opaque block above the current wire blocks the wire up-step")
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(stepped,
                                                       x: 0, y: 64, z: 0)?.direction, "east",
                       "the independently powered support remains a valid conductive path")
        stepped.setBlock(0, 65, 0, 0, SET_SILENT)
        stepped.setBlock(1, 65, 0, 0, SET_SILENT)
        stepped.setBlock(1, 64, 0, 0, SET_SILENT)
        stepped.setBlock(1, 62, 0, Int(cell(B.stone)), SET_SILENT)
        stepped.setBlock(1, 63, 0, Int(cell(B.redstone_wire, 14)), SET_SILENT)
        stepped.setBlock(2, 63, 0, Int(cell(B.redstone_block)), SET_SILENT)
        XCTAssertEqual(rpgNearestPoweredRedstoneSource(stepped, x: 0, y: 64, z: 0)?.direction,
                       "east")
        stepped.setBlock(1, 64, 0, Int(cell(B.stone)), SET_SILENT)
        XCTAssertNil(rpgNearestPoweredRedstoneSource(stepped, x: 0, y: 64, z: 0),
                     "an opaque same-level neighbor blocks a down-step")

        world.gameRules[RPG_CLASSES_GAME_RULE] = 0
        XCTAssertNil(rpgCircuitSenseInspection(player))
    }

    func testServantUnprepareCycleCeilingDurabilityExhaustionAndRuleCleanup() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "rpg-consumer")
        game.createWorld(name: "RPG lifecycle", seedText: "807", mode: GameMode.survival,
                         difficulty: 2)
        let player = game.player!
        let world = game.world
        player.rpg = mastered(pathID: "arcanist", starter: "ritual_circle")
        player.rpg.preparedSpellIDs = ["summon_servant", "mage_light"]
        player.rpg.selectedPreparedSpellID = "summon_servant"
        player.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell,
                                                                     id: "summon_servant")
        player.rpg.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 7,
                                              remainingTicks: 100, costPerSecond: 0.5)]
        player.rpg = repairRPGCharacterState(player.rpg)
        let servant = Allay(world: world)
        servant.setPos(player.x + 1, player.y, player.z)
        world.addEntity(servant)
        let servantDraft = RPGTemporaryEffectDraft(kind: .servant,
                                                   ownerAuthorityID: player.effectiveRPGAuthorityID,
                                                   ownerEntityID: player.id, ownerSequence: 7,
                                                   center: RPGBlockPosition(ifloor(servant.x), ifloor(servant.y),
                                                                            ifloor(servant.z)),
                                                   durationTicks: 100)
        XCTAssertTrue(world.registerRPGTemporaryEffect(servantDraft, entityID: servant.id))
        let unrelated = RPGTemporaryEffectDraft(kind: .mageLight,
                                                ownerAuthorityID: player.effectiveRPGAuthorityID,
                                                ownerEntityID: player.id, ownerSequence: 8,
                                                center: RPGBlockPosition(ifloor(player.x), ifloor(player.y),
                                                                         ifloor(player.z)),
                                                durationTicks: 100)
        XCTAssertTrue(world.registerRPGTemporaryEffect(unrelated))
        let beforeRevision = player.rpg.authorityRevision
        XCTAssertTrue(game.requestRPGTogglePreparedSpell("summon_servant").contains("Unprepared"))
        XCTAssertEqual(player.rpg.authorityRevision, beforeRevision + 1)
        XCTAssertNil(world.rpgTemporaryEffect(for: servantDraft.key))
        XCTAssertNil(world.entityById[servant.id])
        XCTAssertNotNil(world.rpgTemporaryEffect(for: unrelated.key))

        player.rpg.preparedSpellIDs = ["mage_light", "stone_ward"]
        player.rpg.selectedPreparedSpellID = "mage_light"
        player.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: "mage_light")
        player.rpg.authorityRevision = RPG_MAX_NORMAL_AUTHORITY_REVISION
        player.rpg = repairRPGCharacterState(player.rpg)
        let beforeCycle = player.rpg
        XCTAssertEqual(rpgCyclePreparedSpell(player), .authorityExhausted)
        XCTAssertEqual(player.rpg, beforeCycle)
        XCTAssertEqual(game.requestRPGCyclePreparedSpell(),
                       RPGProgressionError.authorityExhausted.description)
        XCTAssertEqual(player.rpg, beforeCycle)

        player.rpg.authorityRevision = 10
        let extreme = rpgCyclePreparedSpell(player, direction: .max)
        XCTAssertNotEqual(extreme, .authorityExhausted)
        let afterExtreme = player.rpg
        XCTAssertEqual(rpgCyclePreparedSpell(player, direction: 0),
                       .noOp(player.rpg.selectedPreparedSpellID!))
        XCTAssertEqual(player.rpg, afterExtreme)
        XCTAssertNotEqual(rpgCyclePreparedSpell(player, direction: .min), .authorityExhausted)
        player.rpg.authorityRevision = RPG_MAX_NORMAL_AUTHORITY_REVISION
        let actionBefore = player.rpg
        XCTAssertEqual(rpgCyclePreparedAction(player, direction: 1), .authorityExhausted)
        XCTAssertEqual(player.rpg, actionBefore)

        let tuned = Player(world: world)
        tuned.rpg = mastered(pathID: "tinker", starter: "field_mod")
        tuned.stats["rpg.toolTuneCounter"] = Double(RPG_MAX_COUNTER - 1)
        XCTAssertTrue(tuned.shouldPreserveRPGToolDurability())
        XCTAssertFalse(tuned.shouldPreserveRPGToolDurability())
        XCTAssertEqual(tuned.stats["rpg.toolTuneCounter"], Double(RPG_MAX_COUNTER))
        let salvager = Player(world: world)
        salvager.rpg = mastered(pathID: "delver", starter: "salvage_eye")
        salvager.stats["rpg.salvageCounter"] = Double(RPG_MAX_COUNTER - 1)
        XCTAssertTrue(salvager.shouldPreserveRPGSalvageDurability())
        XCTAssertFalse(salvager.shouldPreserveRPGSalvageDurability())

        player.rpg = mastered(pathID: "arcanist", starter: "ritual_circle")
        player.rpg.preparedSpellIDs = ["summon_servant"]
        player.rpg.activeUpkeeps = [RPGUpkeep(spellID: "summon_servant", ownerSequence: 9,
                                              remainingTicks: 100, costPerSecond: 0.5)]
        player.maxHealth = 30
        player.health = 30
        let ruleRevision = player.rpg.authorityRevision
        game.setGameRule(RPG_CLASSES_GAME_RULE, 0)
        XCTAssertTrue(player.rpg.activeUpkeeps.isEmpty)
        XCTAssertEqual(player.rpg.authorityRevision, ruleRevision + 1)
        XCTAssertEqual(player.maxHealth, 20)
        XCTAssertEqual(player.health, 20)
        XCTAssertFalse(rpgHUDVisible(player))
        let disabledState = player.rpg
        game.setGameRule(RPG_CLASSES_GAME_RULE, 0)
        XCTAssertEqual(player.rpg, disabledState, "repeated disable is idempotent")
    }

    private func makeWorld(seed: UInt32) -> World {
        let world = World(dim: .overworld, seed: seed)
        world.setChunk(Chunk(cx: 0, cz: 0, minY: world.info.minY,
                             height: world.info.height))
        return world
    }

    private func state(pathID: String, starter: String) -> RPGCharacterState {
        let branch = RPG_BRANCH_DEFINITIONS.first { $0.pathID == pathID && $0.skillIDs.contains(starter) }!
        return try! rpgCreateCharacter(RPGCreationDraft(
            pathID: pathID, branchID: branch.id, startingSkillIDs: branch.skillIDs)).get()
    }

    private func mastered(pathID: String, starter: String) -> RPGCharacterState {
        var result = state(pathID: pathID, starter: starter)
        result.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        result.level = RPG_LEVEL_CAP
        if let branch = rpgBranchDefinition(result.specializationBranchID) {
            for skill in branch.skillIDs { result.skillRanks[skill] = RPG_SKILL_RANK_CAP }
        }
        return repairRPGCharacterState(result)
    }
}
