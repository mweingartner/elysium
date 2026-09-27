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

    private func spawnedCreatures(_ request: String, in world: World, at position: (Double, Double, Double))
        throws -> [Entity] {
        let player = Player(world: world)
        player.setPos(position.0, position.1, position.2)
        world.addEntity(player)
        _ = try executeAIAgentAreaSpawn(request, count: nil, radius: nil, world: world, player: player)
        return world.entities.compactMap { $0 as? Entity }.filter { $0.type.hasPrefix("prehistoric.") }
    }

    func testAPlayerUnderARoofStillGetsCompanyUnderOpenSky() throws {
        // A 49x49 pavilion roof, like standing in the starter hut but wider than the
        // default ring: covered ground is right there, yet open ground is in reach.
        let world = syntheticWorld { chunk, x, z in
            if abs(x) <= 24 && abs(z) <= 24 { chunk.set(posMod(x, CHUNK_W), 70, posMod(z, CHUNK_W), cell(B.stone)) }
        }
        XCTAssertTrue(roofed(world, 0, 64, 0))
        let spawned = try spawnedCreatures("various dinosaurs", in: world, at: (0.5, 64, 0.5))
        XCTAssertFalse(spawned.isEmpty)
        for creature in spawned {
            XCTAssertFalse(roofed(world, ifloor(creature.x), ifloor(creature.y), ifloor(creature.z)),
                           "\(creature.type) placed under the roof at \(ifloor(creature.x)),\(ifloor(creature.z))")
        }
    }

    func testAPlayerSealedInACaveStillGetsCompanyThere() throws {
        // Rock up to y 110 with a 61x61 chamber at y 50...56: no open sky within reach.
        let world = syntheticWorld { chunk, x, z in
            let lx = posMod(x, CHUNK_W), lz = posMod(z, CHUNK_W)
            for y in 64...110 { chunk.set(lx, y, lz, cell(B.stone)) }
            if abs(x) <= 30 && abs(z) <= 30 {
                for y in 50...56 { chunk.set(lx, y, lz, 0) }
            }
            for y in 30..<50 { chunk.set(lx, y, lz, cell(B.stone)) }
        }
        XCTAssertTrue(roofed(world, 0, 50, 0))
        let spawned = try spawnedCreatures("various dinosaurs", in: world, at: (0.5, 50, 0.5))
        XCTAssertFalse(spawned.isEmpty, "a covered player falls back to covered ground")
        XCTAssertTrue(spawned.allSatisfy { (50...56).contains(ifloor($0.y)) }, "company stays in the chamber")
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
}
