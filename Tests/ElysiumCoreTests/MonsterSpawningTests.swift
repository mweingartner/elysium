import XCTest
@testable import ElysiumCore

final class MonsterSpawningTests: XCTestCase {
    override class func setUp() {
        registerAllBlocks(); registerAllItems(); registerAllBiomes(); registerAllEntities(); registerAllSystems()
    }
    override func tearDown() { resetGameRng(0x6A57); super.tearDown() }

    private func cave(_ preset: WorldPreset = .normal, tunnel: Bool = false) -> (World, Player) {
        let world = World(dim: .overworld, seed: 12345, generationSettings: .init(preset: preset))
        world.dayTime = 18_000; world.time = 100; world.difficulty = 2
        for cz in -5...4 {
            for cx in -5...4 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                chunk.biomes = Array(repeating: UInt8(Biome.plains.rawValue), count: chunk.biomes.count)
                for z in 0..<16 { for x in 0..<16 {
                    chunk.set(x, 19, z, cell(B.stone)); chunk.set(x, 23, z, cell(B.stone))
                    if tunnel && abs(cz * 16 + z) > 2 {
                        for y in 20...22 { chunk.set(x, y, z, cell(B.stone)) }
                    }
                    chunk.heightmap[z * 16 + x] = 23
                } }
                world.setChunk(chunk)
            }
        }
        let player = Player(world: world); player.setPos(0.5, 20, 0.5); world.addEntity(player)
        return (world, player)
    }
    private func monsters(_ world: World) -> [Mob] {
        world.entities.compactMap { $0 as? Mob }.filter { $0.category == "monster" && !$0.dead }
    }
    private func state(_ rng: RandomX) -> [UInt32] { let s = rng.stateWords; return [s.0, s.1, s.2, s.3] }
    private func spawner(_ world: World, x: Int = 4, type: String = "zombie") -> BlockEntityData {
        world.setBlock(x, 20, 0, Int(cell(B.spawner)))
        let be = makeSpawnerBE(x, 20, 0, type); be.delay = 0
        world.setBlockEntity(be)
        return be
    }

    func testGeneratedDungeonSpawnerTicksAndRestoredSpawnerWorksInNormalAndDinosaurMaps() throws {
        let output = generateChunk(.overworld, 12345, -16, -71)
        let spec = try XCTUnwrap(output.blockEntities.first { $0.kind == "spawner" })
        guard case let .str(type)? = spec.data["mob"] else { return XCTFail("missing mob") }
        for preset in [WorldPreset.normal, .prehistoricLostWorld, .prehistoricLostWorldV4] {
            let world = World(dim: .overworld, seed: 12345, generationSettings: .init(preset: preset))
            world.difficulty = 2; world.randomTickSpeed = 0
            let chunk = Chunk(cx: -16, cz: -71, minY: world.info.minY, height: world.info.height)
            chunk.blocks = output.blocks; chunk.status = .lit; chunk.buildHeightmap(); world.setChunk(chunk)
            world.light.initChunkLight(chunk)
            let original = makeSpawnerBE(spec.x, spec.y, spec.z, type)
            original.delay = 1
            let restored = try JSONDecoder().decode(BlockEntityData.self, from: JSONEncoder().encode(original))
            world.setBlockEntity(restored)
            let player = Player(world: world); player.setPos(Double(spec.x) + 1.5, Double(spec.y), Double(spec.z) + 0.5)
            world.addEntity(player); resetGameRng(0xDA61)
            for _ in 0..<100 { world.tick() }
            XCTAssertFalse(monsters(world).isEmpty, "a real generated and restored dungeon must spawn on \(preset)")
            XCTAssertTrue(monsters(world).allSatisfy { $0.type == type && ifloor($0.y) == spec.y })
            XCTAssertGreaterThan(restored.delay ?? 0, 0)
        }
    }

    func testSpawnerRetainsSixMobCapAndEverySpawnHasClearSupportedBody() {
        for type in ["zombie", "skeleton", "spider", "cave_spider", "silverfish", "blaze"] {
            let (world, _) = cave(.prehistoricLostWorld)
            let be = spawner(world, type: type)
            for _ in 0..<25 { be.delay = 0; tickMonsterSpawner(world, be) }
            let births = monsters(world)
            XCTAssertEqual(births.count, 6, type)
            for mob in births {
                world.removeEntity(mob)
                XCTAssertTrue(monsterSpawnBodyFits(world, mob), type)
                world.addEntity(mob)
            }
        }
    }

    func testSpawnerHonorsLightPeacefulDisabledClientDistanceAndRemovedBlock() {
        let (world, player) = cave()
        let be = spawner(world)
        for condition in 0..<6 {
            world.difficulty = 2; world.gameRules["doMobSpawning"] = 1; world.isTransientLANClient = false
            player.setPos(0.5, 20, 0.5); world.setBlock(4, 20, 0, Int(cell(B.spawner)))
            for chunk in world.chunks.values { chunk.blockLight = Array(repeating: 0, count: chunk.blockLight.count) }
            switch condition {
            case 0: world.difficulty = 0
            case 1: world.gameRules["doMobSpawning"] = 0
            case 2: world.isTransientLANClient = true
            case 3: player.setPos(100, 20, 0)
            case 4: world.setBlock(4, 20, 0, 0)
            default: for chunk in world.chunks.values { chunk.blockLight = Array(repeating: 8, count: chunk.blockLight.count) }
            }
            be.delay = 0; tickMonsterSpawner(world, be)
            XCTAssertTrue(monsters(world).isEmpty, "condition \(condition)")
        }
    }

    func testDarkCavesRefillAcrossNightCyclesAndStopAtLocalCapOnBothMapTypes() {
        for preset in [WorldPreset.normal, .prehistoricLostWorld, .prehistoricLostWorldV4] {
            let (world, player) = cave(preset)
            var rng = RandomX(44)
            for tick in stride(from: 100, through: 2_000, by: 100) {
                world.time = tick
                let report = spawnNightCaveMonsters(world, [player], &rng)
                XCTAssertLessThanOrEqual(report.spawned, 4)
                XCTAssertLessThanOrEqual(report.columnsChecked, 16)
                XCTAssertLessThanOrEqual(report.floorChecks, 528)
            }
            XCTAssertEqual(monsters(world).count, 16)
            for mob in monsters(world) {
                XCTAssertGreaterThanOrEqual((mob.x-player.x)*(mob.x-player.x)+(mob.z-player.z)*(mob.z-player.z), 24*24)
                XCTAssertEqual(mob.y, 20)
                world.removeEntity(mob)
            }
            world.dayTime = 1_000; world.time = 2_100
            XCTAssertEqual(spawnNightCaveMonsters(world, [player], &rng).spawned, 0)
            world.dayTime = 18_000; world.time = 26_100
            XCTAssertGreaterThan(spawnNightCaveMonsters(world, [player], &rng).spawned, 0)
        }
    }

    func testNarrowTunnelGetsPeriodicSpawnsAndLitTunnelDoesNot() {
        for light: UInt8 in [0, 8] {
            let (world, player) = cave(.prehistoricLostWorld, tunnel: true)
            if light > 0 { for chunk in world.chunks.values { chunk.blockLight = Array(repeating: light, count: chunk.blockLight.count) } }
            var rng = RandomX(224)
            for tick in stride(from: 100, through: 4_000, by: 100) {
                world.time = tick; spawnNightCaveMonsters(world, [player], &rng)
            }
            if light == 0 { XCTAssertGreaterThan(monsters(world).count, 2) }
            else { XCTAssertTrue(monsters(world).isEmpty) }
        }
    }

    func testCaveGatesDoNotDrawRNGAndOpenSkyDoesNotCountAsCave() {
        let (world, player) = cave()
        var rng = RandomX(33)
        for condition in 0..<7 {
            world.time = 100; world.dayTime = 18_000; world.difficulty = 2
            world.gameRules["doMobSpawning"] = 1; world.isTransientLANClient = false; player.dead = false
            switch condition {
            case 0: world.time = 101
            case 1: world.dayTime = 12_999
            case 2: world.dayTime = 23_000
            case 3: world.difficulty = 0
            case 4: world.gameRules["doMobSpawning"] = 0
            case 5: world.isTransientLANClient = true
            default: player.dead = true
            }
            let before = state(rng)
            XCTAssertEqual(spawnNightCaveMonsters(world, [player], &rng), CaveSpawnReport())
            XCTAssertEqual(state(rng), before)
        }
        player.dead = false
        for chunk in world.chunks.values { chunk.skyLight = Array(repeating: 15, count: chunk.skyLight.count) }
        XCTAssertEqual(spawnNightCaveMonsters(world, [player], &rng).spawned, 0)
    }

    func testTorchDisablesSpawnerAndRemovingItRestoresSpawning() {
        let (world, _) = cave()
        let be = spawner(world)
        world.setBlock(4, 22, 0, Int(cell(B.torch)))
        world.light.flush()
        XCTAssertGreaterThan(world.getBlockLight(4, 20, 1), 0)
        tickMonsterSpawner(world, be)
        XCTAssertTrue(monsters(world).isEmpty)
        XCTAssertEqual(be.delay, 20)
        world.setBlock(4, 22, 0, 0)
        world.light.flush()
        be.delay = 0; tickMonsterSpawner(world, be)
        XCTAssertFalse(monsters(world).isEmpty)
    }

    func testCaveSpawnAvoidsEveryPlayerAndRespectsOverlappingLocalCaps() {
        let (world, player) = cave(.prehistoricLostWorldV4)
        let other = Player(world: world); other.setPos(20.5, 20, 0.5); world.addEntity(other)
        var rng = RandomX(99)
        for time in stride(from: 100, through: 2_000, by: 100) {
            world.time = time; spawnNightCaveMonsters(world, [player, other], &rng)
        }
        XCTAssertFalse(monsters(world).isEmpty)
        for p in [player, other] {
            let local = monsters(world).filter { ($0.x-p.x)*($0.x-p.x)+($0.z-p.z)*($0.z-p.z) <= 80*80 }
            XCTAssertLessThanOrEqual(local.count, 16)
            for mob in local { XCTAssertGreaterThanOrEqual((mob.x-p.x)*(mob.x-p.x)+(mob.z-p.z)*(mob.z-p.z), 24*24) }
        }
    }

    func testBlockedBodiesAndUnloadedEdgesAreRefused() throws {
        let (world, _) = cave()
        let spider = try XCTUnwrap(createEntity("spider", world))
        spider.setPos(79.5, 20, 0.5)
        XCTAssertFalse(monsterSpawnBodyFits(world, spider), "wide body crosses an unloaded chunk")
        spider.setPos(10.5, 20, 0.5)
        world.setBlock(11, 20, 0, Int(cell(B.stone)))
        XCTAssertFalse(monsterSpawnBodyFits(world, spider), "wide body intersects neighbouring wall")
        let zombie = try XCTUnwrap(createEntity("zombie", world))
        zombie.setPos(10.5, 20, 0.5)
        world.setBlock(10, 21, 0, Int(cell(B.stone)))
        XCTAssertFalse(monsterSpawnBodyFits(world, zombie), "head intersects roof")
        world.setBlock(10, 21, 0, Int(cell(B.lava)))
        XCTAssertFalse(monsterSpawnBodyFits(world, zombie))
    }

    func testCaveSpawningIsDeterministicAndFarMonstersDoNotStarveIt() {
        func run() -> [String] {
            let (world, player) = cave(.prehistoricLostWorld)
            for i in 0..<70 { spawnMob(world, "zombie", Double(1_000+i), 20, 0) }
            var rng = RandomX(555); resetGameRng(888)
            for time in stride(from: 100, through: 1_000, by: 100) { world.time = time; spawnNightCaveMonsters(world, [player], &rng) }
            return monsters(world).filter { $0.x < 100 }.map { "\($0.type):\($0.x),\($0.y),\($0.z)" }
        }
        let first = run(); XCTAssertFalse(first.isEmpty); XCTAssertEqual(first, run())
    }
}
