import XCTest
@testable import ElysiumCore

/// Guards on the AI companion's area spawns: bosses stay cursor-only and negated
/// requests are never executed literally by the direct parser.
final class AIAgentAreaSpawnSafetyTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        registerAllSystems()
    }

    private func makePlain() -> (World, Player) {
        let world = World(dim: .overworld, seed: 0x5AFE)
        for cz in -3..<3 {
            for cx in -3..<3 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        chunk.set(x, 62, z, cell(B.stone))
                        chunk.set(x, 63, z, cell(B.grass_block))
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        world.addEntity(player)
        return (world, player)
    }

    func testBossesAreNeverScatteredAroundThePlayer() throws {
        let (world, player) = makePlain()
        for boss in ["wither", "ender dragon", "warden", "elder guardian"] {
            XCTAssertThrowsError(try executeAIAgentAreaSpawn("2 \(boss)s", count: nil, radius: nil,
                                                             world: world, player: player), boss) { error in
                guard case .areaSpawnNotAllowed? = error as? AIAgentError else {
                    return XCTFail("\(boss): \(error)")
                }
            }
            XCTAssertThrowsError(try executeAIAgentAction(
                AIAgentAction(action: "spawn_entity", count: 1, target: "area", entity: boss),
                world: world, player: player, cursor: nil), boss)
        }
        XCTAssertFalse(world.entities.contains { ["wither", "ender_dragon", "warden", "elder_guardian"].contains(($0 as? Entity)?.type ?? "") })
        XCTAssertNotEqual(inferDirectAIAgentAction(from: "spawn some withers around me")?.action, "spawn_group",
                          "the direct parser does not route a boss to the area spawn")

        // Deliberate cursor summons keep working as before.
        let hit = RaycastHit(x: 6, y: 63, z: 6, face: Dir.up, cell: Int(cell(B.grass_block)),
                             t: 1, px: 6.5, py: 64, pz: 6.5)
        _ = try executeAIAgentAction(AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "wither"),
                                     world: world, player: player, cursor: hit)
        XCTAssertTrue(world.entities.contains { ($0 as? Entity)?.type == "wither" })
    }

    func testNegatedRequestsAreNotExecutedByTheDirectParser() {
        for request in [
            "don't spawn any predators near me",
            "do not spawn dinosaurs around me",
            "please never summon raptors nearby",
            "stop spawning herbivores in my area",
            "spawn no dinosaurs",
        ] {
            XCTAssertNotEqual(inferDirectAIAgentAction(from: request)?.action, "spawn_group", request)
        }
        XCTAssertEqual(inferDirectAIAgentAction(from: "spawn some predators near me")?.action, "spawn_group")
    }
}
