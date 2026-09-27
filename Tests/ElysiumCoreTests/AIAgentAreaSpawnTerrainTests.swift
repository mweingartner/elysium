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
