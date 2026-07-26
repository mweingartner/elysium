import XCTest
@testable import ElysiumCore

final class WorldPresetTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
    }

    func testWorldPresetAliasesNormalizeToMojangIDs() {
        XCTAssertEqual(normalizedWorldPreset(nil), .normal)
        XCTAssertEqual(normalizedWorldPreset("default"), .normal)
        XCTAssertEqual(normalizedWorldPreset("flat"), .flat)
        XCTAssertEqual(normalizedWorldPreset("superflat"), .flat)
        XCTAssertEqual(normalizedWorldPreset("minecraft:large_biomes"), .largeBiomes)
        XCTAssertEqual(normalizedWorldPreset("elysium:moderate_hills_resource_rich"), .moderateHillsResourceRich)
        XCTAssertEqual(normalizedWorldPreset("Moderate Hills - Resource Rich"), .moderateHillsResourceRich)
        XCTAssertEqual(normalizedWorldPreset("Noderate Hills - Resource Rich"), .moderateHillsResourceRich)
        XCTAssertEqual(normalizedWorldPreset("single biome"), .singleBiomeSurface)
        XCTAssertEqual(normalizedWorldPreset("nether"), .netherWorld)
        XCTAssertEqual(normalizedWorldPreset("Nether World"), .netherWorld)
        XCTAssertEqual(normalizedWorldPreset("debug"), .debugAllBlockStates)
        XCTAssertEqual(normalizedWorldPreset("not-real"), .normal)
    }

    func testModerateHillsResourceRichDisplayNameIsRichResources() {
        // Rebrand: the create-world button used to read "Moderate Hills - Resource Rich",
        // which overflowed the fixed-width preset button. The on-disk/wire ID (used by
        // normalizedWorldPreset above) intentionally keeps the old wording; only the
        // user-facing label changed.
        XCTAssertEqual(WorldPreset.moderateHillsResourceRich.displayName, "Rich Resources")
        XCTAssertEqual(WorldPreset.moderateHillsResourceRich.rawValue,
                       "elysium:moderate_hills_resource_rich")
    }

    func testEveryWorldPresetHasANonEmptyDisplayName() {
        // Guards against a future case being added to the enum without a matching
        // displayName arm silently falling through to an empty/placeholder string.
        for preset in WorldPreset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty, "\(preset) has no display name")
        }
    }

    func testNetherWorldIsAVisibleStandardPresetWithNetherStartSemantics() {
        XCTAssertTrue(WorldPreset.normalCycle.contains(.netherWorld))
        XCTAssertEqual(WorldPreset.netherWorld.displayName, "Nether World")
        XCTAssertEqual(WorldPreset.netherWorld.rawValue, "elysium:nether_world")
        XCTAssertEqual(WorldPreset.netherWorld.startingDimension, .nether)
        XCTAssertEqual(WorldPreset.normal.startingDimension, .overworld)
    }

    func testNetherWorldGatewayPlacementIsDeterministicAndOnePerRegion() {
        let seed: UInt32 = 0x1020_3040
        XCTAssertTrue(isNetherWorldGatewayChunk(seed: seed, cx: 0, cz: 0),
                      "the origin portal is the guaranteed new-world escape route")
        for rz in -2...2 {
            for rx in -2...2 {
                var matches = 0
                for cz in (rz * 8)..<(rz * 8 + 8) {
                    for cx in (rx * 8)..<(rx * 8 + 8) {
                        if isNetherWorldGatewayChunk(seed: seed, cx: cx, cz: cz) { matches += 1 }
                    }
                }
                XCTAssertEqual(matches, 1, "region \(rx),\(rz) must contain exactly one gateway")
            }
        }
    }

    func testNetherWorldOriginChunkContainsACompleteActivePortalOnlyForThatPreset() {
        let seed: UInt32 = 424_242
        let settings = WorldGenerationSettings(preset: .netherWorld, dungeonDensity: .many)
        let generated = generateChunk(.nether, seed, 0, 0, settings: settings)
        let portalID = B.nether_portal
        XCTAssertEqual(generated.blocks.count { $0 >> 4 == portalID }, 6,
                       "the two-wide, three-high portal interior must be fully active")

        let ordinary = generateChunk(.nether, seed, 0, 0)
        XCTAssertEqual(ordinary.blocks.count { $0 >> 4 == portalID }, 0,
                       "ordinary worlds retain the established Nether generator")
    }

    func testDungeonDensityAliasesNormalizeToKnownLevels() {
        XCTAssertEqual(normalizedDungeonDensity(nil as Int?), .normal)
        XCTAssertEqual(normalizedDungeonDensity(1), .none)
        XCTAssertEqual(normalizedDungeonDensity(2), .normal)
        XCTAssertEqual(normalizedDungeonDensity(3), .more)
        XCTAssertEqual(normalizedDungeonDensity(4), .plentiful)
        XCTAssertEqual(normalizedDungeonDensity(5), .many)
        XCTAssertEqual(normalizedDungeonDensity(0), .normal)
        XCTAssertEqual(normalizedDungeonDensity(6), .normal)
        XCTAssertEqual(normalizedDungeonDensity("none"), .none)
        XCTAssertEqual(normalizedDungeonDensity("default"), .normal)
        XCTAssertEqual(normalizedDungeonDensity("very many"), .many)
        XCTAssertEqual(normalizedDungeonDensity("not-real"), .normal)
    }

    func testDungeonDensityLevelsDoublePassesAboveNormal() {
        XCTAssertEqual(DungeonDensity.none.dungeonPasses, 0)
        XCTAssertEqual(DungeonDensity.normal.dungeonPasses, 1)
        XCTAssertEqual(DungeonDensity.more.dungeonPasses, 2)
        XCTAssertEqual(DungeonDensity.plentiful.dungeonPasses, 4)
        XCTAssertEqual(DungeonDensity.many.dungeonPasses, 8)
    }

    func testWorldRecordDefaultsLegacyPresetFields() throws {
        let legacy = """
        {
          "id":"w1",
          "name":"Legacy",
          "seed":123,
          "gameMode":0,
          "difficulty":2,
          "lastPlayed":1,
          "version":"elysium-test",
          "dims":{
            "0":{"time":10,"dayTime":1000,"raining":false,"thundering":false,"weatherTimer":24000},
            "1":{"time":45,"dayTime":0,"raining":false,"thundering":false,"weatherTimer":24000},
            "2":{"time":-5,"dayTime":0,"raining":false,"thundering":false,"weatherTimer":24000}
          },
          "spawnX":0,
          "spawnY":80,
          "spawnZ":0,
          "gameRules":{},
          "dragonKilled":false,
          "gatewaysSpawned":0,
          "nextEntityId":1
        }
        """
        let rec = try JSONDecoder().decode(WorldRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(rec.generationSettings, .normal)
        XCTAssertEqual(rec.worldPreset, WorldPreset.normal.rawValue)
        XCTAssertEqual(rec.singleBiome, "plains")
        XCTAssertEqual(rec.dungeonDensity, DungeonDensity.normal.rawValue)
        XCTAssertEqual(rec.rpgSimulationTick, 45,
                       "legacy saves derive one monotonic clock from the greatest dimension age")
    }

    func testWorldRecordRPGSimulationTickRoundTripsAndClampsCorruptValues() throws {
        var record = WorldRecord(id: "clock", name: "Clock", seed: 7,
                                 gameMode: 0, difficulty: 2)
        record.rpgSimulationTick = 123_456
        let encoded = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(WorldRecord.self, from: encoded).rpgSimulationTick,
                       123_456)

        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["rpgSimulationTick"] = -1
        XCTAssertEqual(try JSONDecoder().decode(
            WorldRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        ).rpgSimulationTick, 0)
        object["rpgSimulationTick"] = RPG_MAX_COUNTER + 1
        XCTAssertEqual(try JSONDecoder().decode(
            WorldRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        ).rpgSimulationTick, RPG_MAX_COUNTER)
    }

    func testWorldRecordSanitizesUnknownPresetFields() throws {
        var rec = WorldRecord(id: "w2", name: "Bad", seed: 7, gameMode: 0, difficulty: 2,
                              worldPreset: .amplified, singleBiome: .desert,
                              dungeonDensity: .many)
        rec.worldPreset = "minecraft:not_real"
        rec.singleBiome = "minecraft:not_real"
        rec.dungeonDensity = 99
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(WorldRecord.self, from: data)
        XCTAssertEqual(decoded.generationSettings, .normal)
        XCTAssertEqual(decoded.worldPreset, WorldPreset.normal.rawValue)
        XCTAssertEqual(decoded.singleBiome, "plains")
        XCTAssertEqual(decoded.dungeonDensity, DungeonDensity.normal.rawValue)
    }

    func testWorldRecordAcceptsStringDungeonDensityForCorruptSaveCompatibility() throws {
        let raw = """
        {
          "id":"w3",
          "name":"String Density",
          "seed":123,
          "gameMode":0,
          "difficulty":2,
          "lastPlayed":1,
          "version":"elysium-test",
          "dims":{"0":{"time":0,"dayTime":1000,"raining":false,"thundering":false,"weatherTimer":24000}},
          "spawnX":0,
          "spawnY":80,
          "spawnZ":0,
          "worldPreset":"minecraft:normal",
          "singleBiome":"plains",
          "dungeonDensity":"many",
          "gameRules":{},
          "dragonKilled":false,
          "gatewaysSpawned":0,
          "nextEntityId":1
        }
        """
        let rec = try JSONDecoder().decode(WorldRecord.self, from: Data(raw.utf8))
        XCTAssertEqual(rec.generationSettings.dungeonDensity, .many)
        XCTAssertEqual(rec.dungeonDensity, DungeonDensity.many.rawValue)
    }

    func testFlatPresetUsesJavaDefaultLayerStack() {
        let out = generateChunk(.overworld, 123, 0, 0,
                                settings: WorldGenerationSettings(preset: .flat))
        func cellAt(_ x: Int, _ y: Int, _ z: Int) -> UInt16 {
            out.blocks[((y - GEN_MIN_Y) * 16 + z) * 16 + x]
        }
        XCTAssertEqual(cellAt(0, -64, 0), cell(B.bedrock))
        XCTAssertEqual(cellAt(0, -63, 0), cell(B.dirt))
        XCTAssertEqual(cellAt(0, -62, 0), cell(B.dirt))
        XCTAssertEqual(cellAt(0, -61, 0), cell(B.grass_block))
        XCTAssertEqual(cellAt(0, -60, 0), 0)
        XCTAssertTrue(out.biomes.allSatisfy { $0 == UInt8(Biome.plains.rawValue) })
    }

    func testSingleBiomePresetPinsOverworldBiomeData() {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface, singleBiome: .desert)
        let out = generateChunk(.overworld, 321, 0, 0, settings: settings)
        XCTAssertTrue(out.biomes.allSatisfy { $0 == UInt8(Biome.desert.rawValue) })
    }

    func testDebugPresetBuildsFloorAndBlockStateGrid() {
        let out = generateChunk(.overworld, 999, 0, 0,
                                settings: WorldGenerationSettings(preset: .debugAllBlockStates))
        func cellAt(_ x: Int, _ y: Int, _ z: Int) -> UInt16 {
            out.blocks[((y - GEN_MIN_Y) * 16 + z) * 16 + x]
        }
        XCTAssertEqual(cellAt(0, 60, 0), cell(B.bedrock))
        XCTAssertNotEqual(cellAt(0, 70, 0), 0)
        XCTAssertEqual(cellAt(0, 69, 0), 0)
    }

    func testDungeonDensityControlsDungeonPasses() {
        let normal = fixtureDungeonCount(density: .normal)
        let more = fixtureDungeonCount(density: .more)
        let plentiful = fixtureDungeonCount(density: .plentiful)
        let many = fixtureDungeonCount(density: .many)

        XCTAssertEqual(fixtureDungeonCount(density: .none), 0)
        XCTAssertGreaterThan(normal, 0)
        XCTAssertGreaterThan(more, normal)
        XCTAssertGreaterThan(plentiful, more)
        XCTAssertGreaterThan(many, plentiful)
        XCTAssertGreaterThanOrEqual(more, normal * 3 / 2)
        XCTAssertGreaterThanOrEqual(plentiful, more * 3 / 2)
        XCTAssertGreaterThanOrEqual(many, plentiful * 3 / 2)
    }

    func testFullChunkGenerationUsesSavedDungeonDensity() {
        guard let fixture = firstDefaultDungeonChunk() else {
            XCTFail("fixture list should include at least one normal-density dungeon chunk")
            return
        }

        let rec = WorldRecord(id: "w4", name: "No Dungeons", seed: Int32(bitPattern: fixture.seed),
                              gameMode: 0, difficulty: 2, dungeonDensity: .none)
        let none = generateChunk(.overworld, fixture.seed, fixture.cx, fixture.cz,
                                 settings: rec.generationSettings)

        XCTAssertGreaterThan(dungeonSpawnerCount(fixture.out), 0)
        XCTAssertEqual(dungeonSpawnerCount(none), 0)
        XCTAssertEqual(dungeonChestCount(none), 0)
    }

    func testModerateHillsResourceRichPresetIsHillyButCapped() {
        let settings = WorldGenerationSettings(preset: .moderateHillsResourceRich)
        let gen = OverworldGen(2468, settings: settings)
        var heights: [Int] = []
        for z in stride(from: -256, through: 256, by: 32) {
            for x in stride(from: -256, through: 256, by: 32) {
                heights.append(gen.heightEstimate(Double(x), Double(z)))
            }
        }
        let minH = heights.min() ?? 0
        let maxH = heights.max() ?? 0
        XCTAssertGreaterThan(maxH - minH, 12)
        XCTAssertGreaterThanOrEqual(minH, 54)
        XCTAssertLessThanOrEqual(maxH, 118)
    }

    func testModerateHillsResourceRichGreatlyIncreasesOreFamiliesOnSolidTerrain() {
        let normal = oreFamilyCounts(settings: .normal)
        let rich = oreFamilyCounts(settings: WorldGenerationSettings(preset: .moderateHillsResourceRich))
        for family in ["coal", "iron", "copper", "gold", "redstone", "lapis", "diamond"] {
            let normalCount = normal[family, default: 0]
            XCTAssertGreaterThan(normalCount, 0, "normal fixture should expose \(family) before comparison")
            XCTAssertGreaterThanOrEqual(rich[family, default: 0], normalCount * 9 / 5, "\(family) should reflect doubled placement attempts after vein collisions")
        }
        XCTAssertGreaterThan(rich["emerald", default: 0], 0)
    }

    func testModerateHillsResourceRichMakesCarvedCavernsRare() {
        let normal = carvedAirCount(settings: .normal)
        let rich = carvedAirCount(settings: WorldGenerationSettings(preset: .moderateHillsResourceRich))
        XCTAssertGreaterThan(normal, 0)
        XCTAssertLessThan(rich, normal / 4)
    }

    private func oreFamilyCounts(settings: WorldGenerationSettings) -> [String: Int] {
        let gen = OverworldGen(77, settings: settings)
        let surfaceBiomes = [UInt8](repeating: UInt8(Biome.plains.rawValue), count: 256)
        let families = oreFamilyByBlockID
        var counts: [String: Int] = [:]
        for cz in 0..<4 {
            for cx in 0..<4 {
                var blocks = solidOreFixtureBlocks()
                gen.placeOres(cx, cz, &blocks, surfaceBiomes)
                for cell in blocks {
                    let id = Int(cell >> 4)
                    if let family = families[id] {
                        counts[family, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    private func carvedAirCount(settings: WorldGenerationSettings) -> Int {
        let gen = OverworldGen(12345, settings: settings)
        var total = 0
        for cz in -1...1 {
            for cx in -1...1 {
                var blocks = solidOreFixtureBlocks()
                gen.carve(cx, cz, &blocks)
                total += blocks.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
            }
        }
        return total
    }

    private func solidOreFixtureBlocks() -> [UInt16] {
        var blocks = [UInt16](repeating: cell(B.stone), count: CHUNK_W * CHUNK_W * WORLD_H)
        for y in GEN_MIN_Y..<0 {
            for z in 0..<16 {
                for x in 0..<16 {
                    blocks[((y - GEN_MIN_Y) * 16 + z) * 16 + x] = cell(B.deepslate)
                }
            }
        }
        return blocks
    }

    private func fixtureDungeonCount(density: DungeonDensity) -> Int {
        var total = 0
        for cz in 0..<24 {
            for cx in 0..<24 {
                let sink = DungeonFixtureSink(cx: cx, cz: cz)
                total += tryDungeons(98765, cx, cz, sink, density: density)
                XCTAssertEqual(sink.blockEntities.filter { $0.kind == "spawner" }.count,
                               tryDungeons(98765, cx, cz, DungeonFixtureSink(cx: cx, cz: cz), density: density))
            }
        }
        return total
    }

    private func firstDefaultDungeonChunk() -> (seed: UInt32, cx: Int, cz: Int, out: GenOutput)? {
        let seed: UInt32 = 12345
        let candidates = [
            (7, -87), (-49, 22), (98, -85), (29, -14),
            (31, -17), (-16, -71), (37, -78), (-29, -59),
        ]
        for (cx, cz) in candidates {
            let out = generateChunk(.overworld, seed, cx, cz)
            if dungeonSpawnerCount(out) > 0 {
                return (seed, cx, cz, out)
            }
        }
        return nil
    }

    private func dungeonSpawnerCount(_ out: GenOutput) -> Int {
        out.blockEntities.count { $0.kind == "spawner" }
    }

    private func dungeonChestCount(_ out: GenOutput) -> Int {
        out.blockEntities.count { be in
            guard be.kind == "chest_loot", case .str("dungeon") = be.data["lootTable"] else { return false }
            return true
        }
    }

    private var oreFamilyByBlockID: [Int: String] {
        [
            Int(B.coal_ore): "coal", Int(B.deepslate_coal_ore): "coal",
            Int(B.iron_ore): "iron", Int(B.deepslate_iron_ore): "iron",
            Int(B.copper_ore): "copper", Int(B.deepslate_copper_ore): "copper",
            Int(B.gold_ore): "gold", Int(B.deepslate_gold_ore): "gold",
            Int(B.redstone_ore): "redstone", Int(B.deepslate_redstone_ore): "redstone",
            Int(B.lapis_ore): "lapis", Int(B.deepslate_lapis_ore): "lapis",
            Int(B.diamond_ore): "diamond", Int(B.deepslate_diamond_ore): "diamond",
            Int(B.emerald_ore): "emerald", Int(B.deepslate_emerald_ore): "emerald",
        ]
    }
}

@MainActor
final class NetherWorldCreationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
    }

    func testNetherWorldCreationPreservesOptionsAndGrantsStarterKitOnce() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "nether-world")
        let game = GameCore(db: database)
        game.createWorld(name: "Nether Start", seedText: "424242",
                         mode: GameMode.creative, difficulty: 3,
                         worldPreset: .netherWorld, singleBiome: .desert,
                         dungeonDensity: .many, mapSize: .small,
                         rpgClassesEnabled: false)

        XCTAssertEqual(game.dim, .nether)
        XCTAssertEqual(game.worldRec?.worldPreset, WorldPreset.netherWorld.rawValue)
        XCTAssertEqual(game.worldRec?.gameMode, GameMode.creative)
        XCTAssertEqual(game.worldRec?.difficulty, 3)
        XCTAssertEqual(game.worldRec?.dungeonDensity, DungeonDensity.many.rawValue)
        XCTAssertEqual(game.worldRec?.mapSize, .small)
        XCTAssertEqual(game.worldRec?.gameRules[RPG_CLASSES_GAME_RULE], 0)

        let inventory = game.player.inventory.compactMap { $0 }
        XCTAssertEqual(inventory.count, 5)
        XCTAssertEqual(inventory.filter { itemName($0.id) == "iron_pickaxe" }.map(\.count), [1, 1])
        XCTAssertEqual(inventory.first { itemName($0.id) == "iron_sword" }?.count, 1)
        XCTAssertEqual(inventory.first { itemName($0.id) == "iron_shovel" }?.count, 1)
        XCTAssertEqual(inventory.first { itemName($0.id) == "oak_log" }?.count, 64)

        let nether = try XCTUnwrap(game.worlds[.nether])
        let overworld = try XCTUnwrap(game.worlds[.overworld])
        XCTAssertEqual(try XCTUnwrap(nether.playableMaxX) - XCTUnwrap(nether.playableMinX) + 1,
                       WorldMapSize.small.sideBlocks)
        XCTAssertEqual(try XCTUnwrap(overworld.playableMaxX) - XCTUnwrap(overworld.playableMinX) + 1,
                       WorldMapSize.small.sideBlocks * 8)
        XCTAssertNotNil(nether.findPortalNear(ifloor(game.player.x), ifloor(game.player.y),
                                              ifloor(game.player.z), 1, Int(B.nether_portal)))
        XCTAssertTrue(blockDefs[nether.getBlockId(ifloor(game.player.x), ifloor(game.player.y) - 1,
                                                  ifloor(game.player.z))].solid)

        let worldID = try XCTUnwrap(game.worldRec?.id)
        game.saveAndFlush(synchronous: true)
        let relaunched = GameCore(db: database)
        relaunched.loadWorld(worldID)
        XCTAssertEqual(relaunched.dim, .nether)
        XCTAssertEqual(relaunched.player.inventory.compactMap { $0 }.count, 5,
                       "loading persisted player data must not grant a second starter kit")

        relaunched.player.dead = true
        relaunched.respawnPlayer()
        XCTAssertEqual(relaunched.dim, .nether,
                       "without a bed or anchor, Nether-first worlds respawn in the Nether")
    }
}

private final class DungeonFixtureSink: ChunkSink {
    let cx: Int
    let cz: Int
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    var blockEntities: [BESpec] = []

    init(cx: Int, cz: Int) {
        self.cx = cx
        self.cz = cz
    }

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {}

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        0 // deterministic dry cavern; density, not terrain rejection, is under test
    }

    func topY(_ x: Int, _ z: Int) -> Int { 64 }

    func addBlockEntity(_ spec: BESpec) {
        blockEntities.append(spec)
    }

    func addEntity(_ spec: EntitySpec) {}
}
