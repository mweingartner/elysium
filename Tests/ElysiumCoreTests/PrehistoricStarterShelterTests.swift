import XCTest
@testable import ElysiumCore

/// Contract coverage for the version-two prehistoric first-night shelter.
/// These tests inspect real generated chunks and one complete GameCore world
/// entry, so a visual-looking layout regression cannot be hidden behind an
/// inventory shortcut or a post-generation spawn correction.
final class PrehistoricStarterShelterTests: XCTestCase {
    private let seed: UInt32 = 0x51_E1_5A

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerBlockEntityHandlers()
        registerAllLootTables()
    }

    private var currentProfiles: [WorldPreset] {
        [
            .prehistoricLostWorldV2,
            .prehistoricJurassicGiantsV2,
            .prehistoricCretaceousFrontiersV2,
            .prehistoricAncientSeasV2,
        ]
    }

    private var classicProfiles: [WorldPreset] {
        [
            .prehistoricLostWorld,
            .prehistoricJurassicGiants,
            .prehistoricCretaceousFrontiers,
            .prehistoricAncientSeas,
        ]
    }

    private func generatedCell(_ x: Int, _ y: Int, _ z: Int,
                               outputs: [String: GenOutput]) -> Int {
        guard y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H else { return -1 }
        let cx = floorDiv(x, CHUNK_W), cz = floorDiv(z, CHUNK_W)
        guard let output = outputs["\(cx),\(cz)"] else { return -1 }
        let lx = x - cx * CHUNK_W, lz = z - cz * CHUNK_W
        return Int(output.blocks[((y - GEN_MIN_Y) * CHUNK_W + lz) * CHUNK_W + lx])
    }

    private func generatedOutputs(for site: PrehistoricStarterShelterSite,
                                  settings: WorldGenerationSettings,
                                  worldSeed: UInt32? = nil) -> [String: GenOutput] {
        var outputs: [String: GenOutput] = [:]
        for cz in floorDiv(site.z - 12, CHUNK_W)...floorDiv(site.z + 12, CHUNK_W) {
            for cx in floorDiv(site.x - 12, CHUNK_W)...floorDiv(site.x + 12, CHUNK_W) {
                outputs["\(cx),\(cz)"] = generateChunk(.overworld, worldSeed ?? seed, cx, cz,
                                                            settings: settings)
            }
        }
        return outputs
    }

    private func stackNames(_ stacks: [ItemStack]) -> [String] {
        stacks.map { itemDef($0.id).name }
    }

    private func assertStarterCategories(_ stacks: [ItemStack], file: StaticString = #filePath,
                                         line: UInt = #line) {
        let names = stackNames(stacks)
        let toolNames = ["wooden_pickaxe", "stone_pickaxe", "wooden_axe", "wooden_sword", "stone_axe"]
        let resourceNames = ["oak_log", "stick", "cobblestone", "coal"]
        let foodNames = ["bread", "apple", "cooked_chicken"]
        XCTAssertGreaterThanOrEqual(names.filter { toolNames.contains($0) }.count, 2,
                                    "starter chest must always provide two basic tools", file: file, line: line)
        XCTAssertGreaterThanOrEqual(names.filter { resourceNames.contains($0) }.count, 2,
                                    "starter chest must always provide practical resources", file: file, line: line)
        XCTAssertGreaterThanOrEqual(names.filter { foodNames.contains($0) }.count, 1,
                                    "starter chest must always provide food", file: file, line: line)
        XCTAssertLessThanOrEqual(stacks.count, 5, "starter supplies must remain modest", file: file, line: line)
        XCTAssertLessThanOrEqual(stacks.reduce(0) { $0 + $1.count }, 18,
                                 "starter supplies must remain a small first-night cache", file: file, line: line)
    }

    func testV2SitesAreDeterministicAndClassicProfilesHaveNone() throws {
        for preset in currentProfiles {
            let settings = WorldGenerationSettings(preset: preset)
            let first = try XCTUnwrap(prehistoricStarterShelterSite(seed: seed, settings: settings))
            let second = try XCTUnwrap(prehistoricStarterShelterSite(seed: seed, settings: settings))
            XCTAssertEqual(first, second)
            XCTAssertEqual(posMod(first.x, CHUNK_W), CHUNK_W / 2)
            XCTAssertEqual(posMod(first.z, CHUNK_W), CHUNK_W / 2)
            XCTAssertGreaterThanOrEqual(first.y, DIMS[Dim.overworld.rawValue].seaLevel + 4)
            XCTAssertGreaterThanOrEqual(first.x - 12, -WorldMapSize.small.sideBlocks / 2)
            XCTAssertLessThanOrEqual(first.x + 12, WorldMapSize.small.sideBlocks / 2 - 1)
            XCTAssertGreaterThanOrEqual(first.z - 12, -WorldMapSize.small.sideBlocks / 2)
            XCTAssertLessThanOrEqual(first.z + 12, WorldMapSize.small.sideBlocks / 2 - 1)
            XCTAssertTrue(first.intersectsGeneratedExtent(chunkX: floorDiv(first.x, CHUNK_W),
                                                          chunkZ: floorDiv(first.z, CHUNK_W)))
        }
        for preset in classicProfiles {
            XCTAssertNil(prehistoricStarterShelterSite(seed: seed,
                                                        settings: .init(preset: preset)))
        }
    }

    func testCurrentGenerationPublishesACompleteShelterAndWoodGrove() throws {
        let settings = WorldGenerationSettings(preset: .prehistoricLostWorldV2)
        let site = try XCTUnwrap(prehistoricStarterShelterSite(seed: seed, settings: settings))
        let outputs = generatedOutputs(for: site, settings: settings)

        // Every floor column is solid and every roof column covers the room.
        for dz in -3...3 {
            for dx in -3...3 {
                XCTAssertEqual(generatedCell(site.x + dx, site.y - 1, site.z + dz, outputs: outputs) >> 4,
                               Int(B.oak_planks))
            }
        }
        for dz in -4...4 {
            for dx in -4...4 {
                XCTAssertEqual(generatedCell(site.x + dx, site.y + 3, site.z + dz, outputs: outputs) >> 4,
                               Int(B.oak_planks))
            }
        }

        for h in 0..<3 {
            XCTAssertEqual(generatedCell(site.x - 3, site.y + h, site.z - 2, outputs: outputs) >> 4,
                           Int(B.oak_planks))
            XCTAssertEqual(generatedCell(site.x + 3, site.y + h, site.z + 2, outputs: outputs) >> 4,
                           Int(B.oak_planks))
        }
        XCTAssertEqual(generatedCell(site.x - 3, site.y, site.z - 3, outputs: outputs) >> 4, Int(B.oak_log))
        XCTAssertEqual(generatedCell(site.x + 3, site.y + 2, site.z + 3, outputs: outputs) >> 4, Int(B.oak_log))
        XCTAssertEqual(generatedCell(site.x, site.y, site.z - 3, outputs: outputs), Int(cell(B.oak_door, 0)))
        XCTAssertEqual(generatedCell(site.x, site.y + 1, site.z - 3, outputs: outputs), Int(cell(B.oak_door, 8)))
        XCTAssertEqual(generatedCell(site.x, site.y - 1, site.z - 4, outputs: outputs),
                       Int(cell(B.oak_stairs, FACE_OPP[0])))
        for dx in -1...1 {
            XCTAssertEqual(generatedCell(site.x + dx, site.y, site.z - 4, outputs: outputs), 0,
                           "the door porch must not be buried by terrain or foliage")
            XCTAssertEqual(generatedCell(site.x + dx, site.y + 1, site.z - 4, outputs: outputs), 0)
            XCTAssertEqual(generatedCell(site.x + dx, site.y + 2, site.z - 4, outputs: outputs), 0)
        }

        XCTAssertEqual(generatedCell(site.x, site.y, site.z, outputs: outputs), 0,
                       "the saved spawn cell must remain clear")
        XCTAssertEqual(generatedCell(site.x, site.y + 1, site.z, outputs: outputs), 0,
                       "the player head cell must remain clear")
        XCTAssertEqual(generatedCell(site.x, site.y + 2, site.z, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(site.bedFoot.x, site.bedFoot.y, site.bedFoot.z, outputs: outputs),
                       Int(cell(B.red_bed, 1)))
        XCTAssertEqual(generatedCell(site.bedHead.x, site.bedHead.y, site.bedHead.z, outputs: outputs),
                       Int(cell(B.red_bed, 1 | 4)))
        XCTAssertEqual(generatedCell(site.craftingStation.x, site.craftingStation.y,
                                     site.craftingStation.z, outputs: outputs) >> 4,
                       Int(B.crafting_table))
        XCTAssertEqual(generatedCell(site.chest.x, site.chest.y, site.chest.z, outputs: outputs) >> 4,
                       Int(B.chest))

        let specs = outputs.values.flatMap(\.blockEntities).filter {
            $0.kind == "chest_loot" && $0.x == site.chest.x && $0.y == site.chest.y && $0.z == site.chest.z
        }
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs.first?.data["lootTable"], .str("prehistoric_starter"))
        XCTAssertNil(specs.first?.data["seed"], "the chest seed must include the world seed at adoption")

        var guaranteedLogCount = 0
        for root in site.woodGroveRoots {
            for height in 0..<5 {
                XCTAssertEqual(generatedCell(root.x, root.y + height, root.z, outputs: outputs) >> 4,
                               Int(B.oak_log))
                guaranteedLogCount += 1
            }
        }
        XCTAssertGreaterThanOrEqual(guaranteedLogCount, 40,
                                    "the hut must always have ample nearby harvestable wood")
    }

    func testRaisedAncientSeasDeckConnectsTheHutToItsGrove() throws {
        let settings = WorldGenerationSettings(preset: .prehistoricAncientSeasV2)
        let oceanFixtureSeed: UInt32 = 2
        let site = try XCTUnwrap(prehistoricStarterShelterSite(seed: oceanFixtureSeed, settings: settings))
        XCTAssertTrue(site.usesRaisedPlatform,
                      "this fixed ocean fixture must exercise the supported fallback deck")
        let outputs = generatedOutputs(for: site, settings: settings, worldSeed: oceanFixtureSeed)

        func isPassable(_ x: Int, _ z: Int) -> Bool {
            let floor = generatedCell(x, site.y - 1, z, outputs: outputs)
            guard floor >= 0 else { return false }
            let floorID = floor >> 4
            guard floorID >= 0 && floorID < SOLID.count,
                  (SOLID[floorID] == 1 || floorID == Int(B.oak_stairs)),
                  floorID != Int(B.water), floorID != Int(B.lava)
            else { return false }
            for y in site.y...(site.y + 1) {
                let value = generatedCell(x, y, z, outputs: outputs)
                guard value >= 0 else { return false }
                let id = value >> 4
                if id == Int(B.oak_door) { continue } // the paired door is usable by interaction
                if id != 0 && (id >= SOLID.count || SOLID[id] == 1 || id == Int(B.water) || id == Int(B.lava)) {
                    return false
                }
            }
            return true
        }

        let targetRoot = try XCTUnwrap(site.woodGroveRoots.first)
        let target = (x: targetRoot.x + 1, z: targetRoot.z)
        var queue = [(x: site.x, z: site.z)]
        var cursor = 0
        var visited: Set<String> = ["\(site.x),\(site.z)"]
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            if current.x == target.x && current.z == target.z { break }
            for step in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let next = (x: current.x + step.0, z: current.z + step.1)
                guard next.x >= site.x - 10, next.x <= site.x + 10,
                      next.z >= site.z - 10, next.z <= site.z + 10,
                      isPassable(next.x, next.z)
                else { continue }
                let key = "\(next.x),\(next.z)"
                if visited.insert(key).inserted { queue.append(next) }
            }
        }
        XCTAssertTrue(visited.contains("\(target.x),\(target.z)"),
                      "the ocean deck must provide a dry walk from the hut to a guaranteed tree")
    }

    func testStarterLootIsRandomBoundedAndCategoryComplete() {
        var signatures: [String] = []
        for lootSeed: UInt32 in [1, 2, 3, 4, 5, 6, 7, 8] {
            var rng = RandomX(lootSeed)
            let loot = rollLoot("prehistoric_starter", &rng)
            assertStarterCategories(loot)
            signatures.append(loot.map { "\(itemDef($0.id).name):\($0.count)" }.joined(separator: ","))
        }
        XCTAssertGreaterThan(Set(signatures).count, 1,
                             "different chest seeds must select genuinely different small supplies")
    }

    func testClassicGenerationDoesNotPublishStarterShelter() {
        for preset in classicProfiles {
            let output = generateChunk(.overworld, seed, 0, 0, settings: .init(preset: preset))
            XCTAssertFalse(output.blockEntities.contains {
                $0.kind == "chest_loot" && $0.data["lootTable"] == .str("prehistoric_starter")
            }, "v1 generation must remain unchanged for \(preset.rawValue)")
        }
    }

    @MainActor
    func testAncientSeasWorldEntryKeepsPlayerInsideShelterAndAdoptsWorldSeededChest() throws {
        let settings = WorldGenerationSettings(preset: .prehistoricAncientSeasV2)
        let site = try XCTUnwrap(prehistoricStarterShelterSite(seed: seed, settings: settings))

        let game = PersistenceTestSupport.makeGame(owner: self, label: "prehistoric-starter-shelter")
        game.createWorld(name: "Ancient Seas Shelter", seedText: String(Int32(bitPattern: seed)),
                         mode: GameMode.survival, difficulty: 2,
                         worldPreset: .prehistoricAncientSeasV2)
        let record = try XCTUnwrap(game.worldRec)
        XCTAssertEqual(record.spawnX, site.x)
        XCTAssertEqual(record.spawnY, site.y)
        XCTAssertEqual(record.spawnZ, site.z)
        XCTAssertEqual(game.player.x, Double(site.x) + 0.5, accuracy: 0.000_001)
        XCTAssertEqual(game.player.y, Double(site.y), accuracy: 0.000_001,
                       "world entry must not ground the player on the hut roof")
        XCTAssertEqual(game.player.z, Double(site.z) + 0.5, accuracy: 0.000_001)
        XCTAssertEqual(game.world.getBlock(site.x, site.y, site.z), 0)

        let chest = try XCTUnwrap(game.world.getBlockEntity(site.chest.x, site.chest.y, site.chest.z))
        XCTAssertEqual(chest.lootTable, "prehistoric_starter")
        XCTAssertEqual(chest.lootSeed,
                       Int(hash3(game.world.seed ^ 0xBE5, site.chest.x, site.chest.y, site.chest.z)))
        XCTAssertNotNil(resolveLoot(game.world, chest))
        let materialized = try XCTUnwrap(game.world.getBlockEntity(site.chest.x, site.chest.y, site.chest.z))
        assertStarterCategories(materialized.items?.compactMap { $0 } ?? [])
    }

    @MainActor
    func testModifiedShelterUsesADeckOrGroundFallbackInsteadOfItsRoof() throws {
        let settings = WorldGenerationSettings(preset: .prehistoricAncientSeasV2)
        let site = try XCTUnwrap(prehistoricStarterShelterSite(seed: seed, settings: settings))
        let game = PersistenceTestSupport.makeGame(owner: self, label: "prehistoric-modified-shelter")
        game.createWorld(name: "Modified Shelter", seedText: String(Int32(bitPattern: seed)),
                         mode: GameMode.survival, difficulty: 2,
                         worldPreset: .prehistoricAncientSeasV2)
        game.world.setBlock(site.x, site.y - 1, site.z, 0)
        game.respawnPlayer()
        XCTAssertFalse(abs(ifloor(game.player.x) - site.x) <= 4
                       && abs(ifloor(game.player.z) - site.z) <= 4,
                       "a modified hut centre must not fall back to its roof")
        XCTAssertNotEqual(ifloor(game.player.y), site.y + 4,
                          "the roof height is never a valid modified-shelter fallback")
    }
}
