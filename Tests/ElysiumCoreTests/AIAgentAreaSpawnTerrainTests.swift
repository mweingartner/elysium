import XCTest
@testable import ElysiumCore

/// "/ai spawn various dinosaurs near me" on real generated dinosaur-map terrain:
/// rugged peaks, swamp and wooded ground must all get company, a variety request
/// must bring several species, and an outdoor player's creatures stay under the sky.
final class AIAgentAreaSpawnTerrainTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerBlockEntityHandlers()
        registerAllSystems()
    }

    /// Generated chunks within three chunks of the site: the placement fallback reach.
    private func generatedWorld(seed: UInt32, x: Int, z: Int) -> World {
        let settings = WorldGenerationSettings(preset: .prehistoricLostWorldV4)
        let world = World(dim: .overworld, seed: seed, generationSettings: settings)
        let ccx = floorDiv(x, CHUNK_W), ccz = floorDiv(z, CHUNK_W)
        for cz in (ccz - 3)...(ccz + 3) {
            for cx in (ccx - 3)...(ccx + 3) {
                let output = generateChunk(.overworld, seed, cx, cz, settings: settings)
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.blocks = output.blocks
                chunk.biomes = output.biomes
                chunk.buildHeightmap()
                chunk.status = .lit
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    private func roofed(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
        var cy = y + 1
        while cy < world.info.minY + world.info.height - 1 {
            let id = world.getBlock(x, cy, z) >> 4
            if id > 0, id < blockDefs.count, blockDefs[id].solid, !isTreeCanopyOrTrunk(blockDefs[id].name) {
                return true
            }
            cy += 1
        }
        return false
    }

    func testVariousDinosaursNearMeRoutesToTheAreaSpawn() throws {
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "spawn various dinosaurs near me"))
        XCTAssertEqual(action.action, "spawn_group")
        XCTAssertEqual(action.entity, "various dinosaurs")
        let requests = try parseAIAgentSpawnList("various dinosaurs")
        XCTAssertEqual(requests, [AIAgentSpawnRequest(subject: .group(.dinosaurs), count: nil, mixed: true)])
        XCTAssertEqual(try parseAIAgentSpawnList("all kinds of herbivores"),
                       [AIAgentSpawnRequest(subject: .group(.herbivores), count: nil, mixed: true)])
        XCTAssertEqual(try parseAIAgentSpawnList("some predators"),
                       [AIAgentSpawnRequest(subject: .group(.predators), count: nil)])
        XCTAssertFalse(AIToolLoop.isScriptingRequest("spawn various dinosaurs near me"))
    }

    /// Flat grass over stone on a 128x128 square; `shape` may add a roof or a cave.
    private func syntheticWorld(_ shape: (Chunk, Int, Int) -> Void) -> World {
        let world = World(dim: .overworld, seed: 0xC0FE,
                          generationSettings: .init(preset: .prehistoricLostWorldV4))
        for cz in -4..<4 {
            for cx in -4..<4 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        chunk.set(x, 62, z, cell(B.stone))
                        chunk.set(x, 63, z, cell(B.grass_block))
                        shape(chunk, cx * CHUNK_W + x, cz * CHUNK_W + z)
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    private func spawnedCreatures(_ request: String, in world: World, at position: (Double, Double, Double),
                                  budget: AIAgentPlacementBudget = AIAgentPlacementBudget()) throws -> [Entity] {
        let player = Player(world: world)
        player.setPos(position.0, position.1, position.2)
        world.addEntity(player)
        _ = try executeAIAgentAreaSpawn(request, count: nil, radius: nil, world: world, player: player, budget: budget)
        return world.entities.compactMap { $0 as? Entity }.filter { $0.type.hasPrefix("prehistoric.") }
    }

    /// A flat world with a one-block roof of the given half-width over the origin.
    private func roofedWorld(halfWidth: Int, roofY: Int) -> World {
        syntheticWorld { chunk, x, z in
            if abs(x) <= halfWidth && abs(z) <= halfWidth {
                chunk.set(posMod(x, CHUNK_W), roofY, posMod(z, CHUNK_W), cell(B.oak_planks))
            }
        }
    }

    func testAPlayerUnderAWideRoofGetsCompanyOutsideNotOnTheRoof() throws {
        // A 49x49 pavilion wider than the default ring: every random draw lands under it,
        // and its roof top is open sky, yet creatures must go out to the open ground.
        let world = roofedWorld(halfWidth: 24, roofY: 70)
        XCTAssertTrue(roofed(world, 0, 64, 0))
        let spawned = try spawnedCreatures("various dinosaurs", in: world, at: (0.5, 64, 0.5))
        XCTAssertFalse(spawned.isEmpty)
        for creature in spawned {
            let x = ifloor(creature.x), y = ifloor(creature.y), z = ifloor(creature.z)
            XCTAssertEqual(y, 64, "\(creature.type) at \(x),\(y),\(z) must stand on the ground, not the roof")
            XCTAssertTrue(abs(x) > 24 || abs(z) > 24, "\(creature.type) at \(x),\(z) must be outside the pavilion")
            XCTAssertFalse(roofed(world, x, y, z))
        }
    }

    func testAPlayerInAHutSizedShelterGetsCompanyOnTheGroundOutside() throws {
        // The starter hut's footprint: a 9x9 roof three blocks above the floor.
        let world = roofedWorld(halfWidth: 4, roofY: 67)
        XCTAssertTrue(roofed(world, 0, 64, 0))
        let spawned = try spawnedCreatures("some predators and herbivores", in: world, at: (0.5, 64, 0.5))
        XCTAssertFalse(spawned.isEmpty)
        for creature in spawned {
            let x = ifloor(creature.x), y = ifloor(creature.y), z = ifloor(creature.z)
            XCTAssertEqual(y, 64, "\(creature.type) at \(x),\(y),\(z)")
            XCTAssertTrue(abs(x) > 4 || abs(z) > 4, "\(creature.type) at \(x),\(z) must be outside the hut")
        }
    }

    /// Rock from y 30 to 110 with a walled 61x61 chamber at y 50 up to `ceiling`.
    private func sealedCaveWorld(ceiling: Int = 56) -> World {
        syntheticWorld { chunk, x, z in
            let lx = posMod(x, CHUNK_W), lz = posMod(z, CHUNK_W)
            let inChamber = abs(x) <= 30 && abs(z) <= 30
            for y in 30...110 where !(inChamber && (50...ceiling).contains(y)) {
                chunk.set(lx, y, lz, cell(B.stone))
            }
        }
    }

    func testAPlayerSealedInACaveStillGetsCompanyThere() throws {
        let world = sealedCaveWorld()
        XCTAssertTrue(roofed(world, 0, 50, 0))
        XCTAssertEqual(world.getBlock(31, 52, 0) >> 4, Int(B.stone), "the chamber has walls")
        let spawned = try spawnedCreatures("various dinosaurs", in: world, at: (0.5, 50, 0.5))
        XCTAssertFalse(spawned.isEmpty, "a covered player falls back to covered ground")
        for creature in spawned {
            let x = ifloor(creature.x), y = ifloor(creature.y), z = ifloor(creature.z)
            XCTAssertEqual(y, 50, "\(creature.type) stands on the chamber floor")
            XCTAssertTrue(abs(x) <= 30 && abs(z) <= 30, "\(creature.type) at \(x),\(z) stays in the chamber")
        }
    }

    func testPlacementWorkStopsAtItsBudgetWhenNothingFits() throws {
        // A Brachiosaurus cannot fit a two-block-high crawlspace, so every search fails and
        // only the budget ends the work early. One check never charges more than a
        // sauropod's clearance envelope or one full column scan.
        let slack = 13 * 13 * 7 + 400
        for limit in [1_000, 25_000, 400_000] {
            let budget = AIAgentPlacementBudget(limit: limit)
            XCTAssertThrowsError(try spawnedCreatures("8 brachiosaurus", in: sealedCaveWorld(ceiling: 51),
                                                      at: (0.5, 50, 0.5), budget: budget)) {
                guard case .areaSpawnFailed? = $0 as? AIAgentError else { return XCTFail("\($0)") }
            }
            XCTAssertTrue(budget.exhausted, "limit \(limit)")
            XCTAssertLessThanOrEqual(budget.spent, limit + slack, "limit \(limit) overshot")
        }
        // Fish on dry ground: a cod's clearance check costs 2 per cell, so one failed search
        // of about 830 columns stays near 13,000 unless each column's seabed scan (about
        // 256 blocks here) is charged too. Only that charge can exhaust this budget.
        let seabed = AIAgentPlacementBudget(limit: 50_000)
        XCTAssertThrowsError(try spawnedCreatures("8 cod", in: syntheticWorld { _, _, _ in },
                                                  at: (0.5, 64, 0.5), budget: seabed))
        XCTAssertTrue(seabed.exhausted, "seabed scans are charged")
        XCTAssertLessThanOrEqual(seabed.spent, seabed.limit + slack)
        // Requests from chat use the production limit.
        XCTAssertEqual(AIAgentPlacementBudget().limit, AIAgentAreaSpawnPlacementBudget)
    }

    func testVariousDinosaursNearMeSucceedsOnRealRuggedAndWoodedTerrain() throws {
        // Stony peaks, a mangrove swamp, and taiga above caves (the rugged and wooded sites
        // where fixed pack offsets and topmost-ground placement used to fail).
        // On the steep peak only the smallest species fits, so a mix is asserted elsewhere.
        let sites: [(seed: UInt32, x: Int, z: Int, mixFits: Bool)] = [
            (0x5EED_0002, -1000, -600, false), (0x5EED_0002, -300, -600, true), (0x5EED_0001, -300, 0, true),
        ]
        for site in sites {
            let world = generatedWorld(seed: site.seed, x: site.x, z: site.z)
            // Stand on the nearest dry ground.
            var stand: (x: Int, y: Int, z: Int)?
            search: for ring in 0...12 {
                for dz in -ring...ring {
                    for dx in -ring...ring where max(abs(dx), abs(dz)) == ring {
                        if let y = world.dryGroundY(site.x + dx, site.z + dz) {
                            stand = (site.x + dx, y, site.z + dz)
                            break search
                        }
                    }
                }
            }
            let spot = try XCTUnwrap(stand, "\(site)")
            let player = Player(world: world)
            player.setPos(Double(spot.x) + 0.5, Double(spot.y), Double(spot.z) + 0.5)
            world.addEntity(player)
            XCTAssertFalse(roofed(world, spot.x, spot.y, spot.z), "the player stands outdoors at \(site)")

            let before = Set(world.entities.compactMap { ($0 as? Entity).map(ObjectIdentifier.init) })
            let result = try executeAIAgentAreaSpawn("various dinosaurs", count: nil, radius: nil,
                                                     world: world, player: player)
            let spawned = world.entities.compactMap { $0 as? Entity }
                .filter { !before.contains(ObjectIdentifier($0)) && $0.type.hasPrefix("prehistoric.") }
            XCTAssertGreaterThanOrEqual(spawned.count, 2, "\(site): \(result.message)")
            if site.mixFits {
                XCTAssertGreaterThanOrEqual(Set(spawned.map(\.type)).count, 2, "various means a mix: \(result.message)")
            }
            for creature in spawned {
                XCTAssertFalse(roofed(world, ifloor(creature.x), ifloor(creature.y), ifloor(creature.z)),
                               "\(creature.type) sealed under cover near an outdoor player at \(site)")
                let dx = creature.x - player.x, dz = creature.z - player.z
                XCTAssertLessThanOrEqual(dx * dx + dz * dz, 52.0 * 52.0, "\(creature.type) is near the player")
            }
        }
    }

    /// A synthetic flat world with a uniform layer at `y` across every loaded chunk in
    /// `-radius..<radius`. Cheap and deterministic, unlike real terrain generation.
    private func makeSyntheticWorld(preset: WorldPreset, seed: UInt32, radius: Int = 4,
                                    fill: (Chunk) -> Void) -> World {
        let world = World(dim: .overworld, seed: seed, generationSettings: .init(preset: preset))
        for cz in -radius..<radius {
            for cx in -radius..<radius {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                fill(chunk)
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    /// A player sealed in a cave (a solid ceiling everywhere, not just overhead) must
    /// still get company: `allowRoofed` lets the whole enclosed room admit placements
    /// that an outdoor request would otherwise refuse for lacking open sky.
    func testPlayerInAFullyEnclosedCaveStillGetsRoofedCompanions() throws {
        let world = makeSyntheticWorld(preset: .prehistoricLostWorldV4, seed: 0xCA0E, radius: 4) { chunk in
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    chunk.set(x, 62, z, cell(B.stone))
                    chunk.set(x, 63, z, cell(B.grass_block))
                    chunk.set(x, 68, z, cell(B.stone)) // a solid ceiling everywhere: a sealed cave
                }
            }
        }
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        world.addEntity(player)
        XCTAssertTrue(roofed(world, 0, 64, 0), "the whole cave is sealed above the player")

        let result = try executeAIAgentAreaSpawn("5 raptors", count: nil, radius: 16, world: world, player: player)
        let spawned = world.entities.compactMap { $0 as? PrehistoricCreature }
        XCTAssertEqual(spawned.count, 5, result.message)
        for creature in spawned {
            XCTAssertTrue(roofed(world, ifloor(creature.x), ifloor(creature.y), ifloor(creature.z)),
                          "\(creature.type) should still be admitted though the whole cave is roofed")
            XCTAssertTrue(spawnPlacementIsValid(world, creature.type, ifloor(creature.x), ifloor(creature.y),
                                               ifloor(creature.z)))
        }
    }

    /// A dense, unbroken canopy sits over every column except the player's own. If the
    /// open-sky rule mistook tree canopy for a roof, `allowRoofed` would flip true for the
    /// outdoor player and mask the bug; instead the player's column is genuinely open so
    /// only the canopy exemption itself can admit the treed sites the pack must use.
    func testOpenSkyRuleTreatsTreeCanopyAsPassableNotAsARoof() throws {
        let world = makeSyntheticWorld(preset: .prehistoricLostWorldV4, seed: 0xCA0F, radius: 4) { chunk in
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    chunk.set(x, 62, z, cell(B.stone))
                    chunk.set(x, 63, z, cell(B.grass_block))
                    guard chunk.cx != 0 || chunk.cz != 0 || x != 0 || z != 0 else { continue }
                    for y in 66...68 { chunk.set(x, y, z, cell(B.oak_log)) }
                    for y in 69...71 { chunk.set(x, y, z, cell(B.oak_leaves)) }
                }
            }
        }
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        world.addEntity(player)
        XCTAssertFalse(roofed(world, 0, 64, 0), "the player's own column is genuinely open to the sky")

        let result = try executeAIAgentAreaSpawn("5 raptors", count: nil, radius: 16, world: world, player: player)
        let spawned = world.entities.compactMap { $0 as? PrehistoricCreature }
        XCTAssertEqual(spawned.count, 5, result.message)
        for creature in spawned {
            let (x, y, z) = (ifloor(creature.x), ifloor(creature.y), ifloor(creature.z))
            XCTAssertFalse(roofed(world, x, y, z), "canopy overhead must not read as a roof for \(creature.type)")
            XCTAssertEqual(world.getBlock(x, y - 1, z) >> 4, Int(B.grass_block),
                           "\(creature.type) stands on real ground, not the trunk")
            XCTAssertEqual(world.getBlock(x, 66, z) >> 4, Int(B.oak_log),
                           "\(creature.type) has canopy directly overhead, proving the exemption fired")
        }
    }
}
