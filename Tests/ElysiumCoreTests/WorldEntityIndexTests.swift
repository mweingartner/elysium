import XCTest
@testable import ElysiumCore

/// Per-tick code used to find players and living entities by walking every entity in the world.
/// The world now keeps exact typed lists (`playerEntities`, `livingEntities`, `getPlayersNear`);
/// these tests hold each reader to the answer the full walk gave.
final class WorldEntityIndexTests: XCTestCase {
    override class func setUp() {
        registerAllBlocks(); registerAllItems(); registerAllBiomes(); registerAllEntities(); registerAllSystems()
    }
    override func tearDown() { resetGameRng(0x6A57); super.tearDown() }

    /// An entity-list member that is not an `Entity`, counting how often simulation code reads it.
    private final class CountingBystander: EntityRef {
        let id: Int
        private(set) var reads = 0
        init(id: Int) { self.id = id }
        var x: Double { reads += 1; return 4 }
        var y: Double { reads += 1; return 20 }
        var z: Double { reads += 1; return 0 }
        var dead: Bool { reads += 1; return false }
        func bb() -> AABB { reads += 1; return AABB(3.5, 20, -0.5, 4.5, 21, 0.5) }
    }

    private func world(time: Int = 100) -> World {
        let world = World(dim: .overworld, seed: 12345, generationSettings: .init(preset: .normal))
        world.dayTime = 18_000; world.time = time; world.difficulty = 2
        for cz in -3...2 {
            for cx in -3...2 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                chunk.biomes = Array(repeating: UInt8(Biome.plains.rawValue), count: chunk.biomes.count)
                for z in 0..<16 { for x in 0..<16 {
                    chunk.set(x, 19, z, cell(B.stone)); chunk.set(x, 23, z, cell(B.stone))
                    chunk.heightmap[z * 16 + x] = 23
                } }
                world.setChunk(chunk)
            }
        }
        return world
    }

    /// The scan the spawner used before the player index existed.
    private func scanFindsEligiblePlayer(_ world: World, _ x: Double, _ y: Double, _ z: Double,
                                         radius: Double) -> Bool {
        !world.getEntitiesNear(x, y, z, radius) {
            guard let entity = $0 as? Entity else { return false }
            return eligibleMonsterSpawnPlayer(entity, in: world)
        }.isEmpty
    }

    private func remotePlayer(_ world: World, id: String, x: Double, y: Double, z: Double) -> LANRemotePlayerEntity {
        LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: id, displayName: "Guest", x: x, y: y, z: z, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival))
    }

    func testPlayerIndexFollowsEveryChangeToTheEntityList() throws {
        let world = world()
        XCTAssertTrue(world.playerEntities.isEmpty)
        let zombie = try XCTUnwrap(createEntity("zombie", world)); zombie.setPos(1.5, 20, 1.5)
        world.addEntity(zombie)
        XCTAssertTrue(world.playerEntities.isEmpty, "a monster is not a player")

        let first = Player(world: world); first.setPos(0.5, 20, 0.5); world.addEntity(first)
        let guest = remotePlayer(world, id: "guest", x: 5, y: 20, z: 5); world.addEntity(guest)
        let bystander = CountingBystander(id: 9_000); world.addEntity(bystander)
        let second = Player(world: world); second.setPos(8.5, 20, 0.5); world.addEntity(second)
        XCTAssertEqual(world.playerEntities.map(\.id), [first.id, guest.id, second.id],
                       "host players and LAN guests, in entity-list order")

        world.removeEntity(guest)
        XCTAssertEqual(world.playerEntities.map(\.id), [first.id, second.id])

        // Code that edits the array itself is followed too, including a reorder of equal length.
        world.entities.reverse()
        XCTAssertEqual(world.playerEntities.map(\.id), [second.id, first.id])
        world.entities.removeAll { $0 === second }
        XCTAssertEqual(world.playerEntities.map(\.id), [first.id])
        world.entities = [zombie]
        XCTAssertTrue(world.playerEntities.isEmpty)
        world.entities.append(second)
        XCTAssertEqual(world.playerEntities.map(\.id), [second.id])
        XCTAssertEqual(bystander.reads, 0, "membership is decided by type, without reading positions")
    }

    private func droppedItem(_ world: World, x: Double, z: Double) -> ItemEntity {
        let item = ItemEntity(world: world); item.stack = ItemStack(iid("stone"), 1)
        item.setPos(x, 20, z)
        return item
    }

    func testLivingIndexFollowsTheEntityListInOrder() throws {
        let world = world()
        let cow = try XCTUnwrap(createEntity("cow", world) as? LivingEntity); cow.setPos(1.5, 20, 1.5)
        let player = Player(world: world); player.setPos(0.5, 20, 0.5)
        let item = droppedItem(world, x: 2.5, z: 2.5)
        let zombie = try XCTUnwrap(createEntity("zombie", world) as? LivingEntity); zombie.setPos(3.5, 20, 3.5)
        for entity in [cow, item, player, zombie] as [Entity] { world.addEntity(entity) }
        world.addEntity(CountingBystander(id: 9_000))
        func expected() -> [Int] { world.entities.compactMap { ($0 as? LivingEntity)?.id } }
        XCTAssertEqual(world.livingEntities.map(\.id), [cow.id, player.id, zombie.id])
        XCTAssertEqual(world.livingEntities.map(\.id), expected())
        cow.dead = true
        XCTAssertEqual(world.livingEntities.map(\.id), expected(), "liveness is the reader's test, not the list's")
        world.removeEntity(cow)
        XCTAssertEqual(world.livingEntities.map(\.id), [player.id, zombie.id])
        world.entities.swapAt(0, world.entities.count - 1)
        XCTAssertEqual(world.livingEntities.map(\.id), expected())
    }

    func testPlayersNearReturnsTheEntityScanResultInTheSameOrder() throws {
        var rng = RandomX(0x9E37)
        var nonEmpty = 0
        for round in 0..<200 {
            let world = world()
            func coordinate(_ spread: Double) -> Double { (rng.nextFloat() * 2 - 1) * spread }
            for index in 0..<rng.nextInt(6) {
                let entity: Entity = rng.nextInt(3) == 0
                    ? remotePlayer(world, id: "guest-\(round)-\(index)", x: 0, y: 20, z: 0) : Player(world: world)
                entity.setPos(coordinate(24), 20 + coordinate(10), coordinate(24))
                if rng.nextInt(6) == 0 { entity.dead = true }
                if rng.nextInt(12) == 0 { entity.x = .nan }
                world.addEntity(entity)
                // Interleave creatures so players are not one contiguous run of the entity list.
                if rng.nextInt(2) == 0 {
                    let mob = try XCTUnwrap(createEntity("cow", world))
                    mob.setPos(coordinate(24), 20, coordinate(24)); world.addEntity(mob)
                }
            }
            for _ in 0..<10 {
                let x = coordinate(24), y = 20 + coordinate(10), z = coordinate(24)
                let radius = [1.2, 5, 10, 16, 32, 64][rng.nextInt(6)]
                let scan = world.getEntitiesNear(x, y, z, radius) { ($0 as? Entity)?.isPlayer ?? false }
                let indexed = world.getPlayersNear(x, y, z, radius)
                XCTAssertEqual(indexed.map(\.id), scan.map(\.id), "round \(round) radius \(radius)")
                XCTAssertTrue(zip(indexed, scan).allSatisfy { $0 === $1 })
                if !scan.isEmpty { nonEmpty += 1 }
            }
        }
        XCTAssertGreaterThan(nonEmpty, 400, "the comparison must cover real hits, not only empty answers")
    }

    /// The loop `LivingEntity.pushEntities` ran before the typed list existed, kept as the oracle.
    private func referencePush(_ me: LivingEntity) {
        if me.dead || me.vehicle != nil { return }
        if let p = me as? Player, p.flying { return }
        for e in me.world.entities {
            guard let other = e as? LivingEntity, other !== me, !other.dead,
                  other.deathTime == 0, other.vehicle !== me else { continue }
            let rx = (me.width + other.width) * 0.5
            if abs(other.x - me.x) >= rx || abs(other.z - me.z) >= rx { continue }
            if other.y >= me.y + me.height || me.y >= other.y + other.height { continue }
            var dx = other.x - me.x
            var dz = other.z - me.z
            var d = max(abs(dx), abs(dz))
            if d >= 0.01 {
                d = d.squareRoot()
                dx /= d
                dz /= d
                let scale = min(1.0, 1.0 / d) * 0.05
                other.vx += dx * scale
                other.vz += dz * scale
                me.vx -= dx * scale
                me.vz -= dz * scale
            }
        }
    }

    func testCrowdPushesMatchTheEntityWalkBitForBit() throws {
        let kinds = ["cow", "pig", "sheep", "chicken", "zombie", "spider"]
        var pushed = 0
        for seed in 0..<40 {
            // Two identical crowds: one pushed by the shipping code, one by the old loop.
            var crowds: [[LivingEntity]] = []
            var worlds: [World] = []    // entities hold their world unowned; keep both alive
            for _ in 0..<2 {
                var rng = RandomX(UInt32(0xC0FFEE + seed))
                let world = world()
                worlds.append(world)
                var crowd: [LivingEntity] = []
                for index in 0..<(8 + rng.nextInt(40)) {
                    let entity: LivingEntity
                    if index % 11 == 5 { entity = Player(world: world) }
                    else { entity = try XCTUnwrap(createEntity(kinds[rng.nextInt(kinds.count)], world) as? LivingEntity) }
                    // A pen three blocks wide: most pairs overlap, as in a herd at a fence.
                    entity.setPos(rng.nextFloat() * 3, 20 + Double(rng.nextInt(2)), rng.nextFloat() * 3)
                    if rng.nextInt(9) == 0 { entity.dead = true }
                    if rng.nextInt(9) == 0 { entity.deathTime = 3 }
                    if rng.nextInt(7) == 0, let mount = crowd.last { entity.vehicle = mount }
                    world.addEntity(entity); crowd.append(entity)
                    if rng.nextInt(5) == 0 { world.addEntity(droppedItem(world, x: 1, z: 1)) }
                }
                crowds.append(crowd)
            }
            for entity in crowds[0] { entity.pushEntities() }
            for entity in crowds[1] { referencePush(entity) }
            XCTAssertEqual(crowds[0].count, crowds[1].count)
            XCTAssertEqual(worlds.count, 2)
            for (shipped, reference) in zip(crowds[0], crowds[1]) {
                XCTAssertEqual(shipped.vx.bitPattern, reference.vx.bitPattern, "seed \(seed) \(shipped.type)")
                XCTAssertEqual(shipped.vz.bitPattern, reference.vz.bitPattern, "seed \(seed) \(shipped.type)")
                if reference.vx != 0 || reference.vz != 0 { pushed += 1 }
            }
        }
        XCTAssertGreaterThan(pushed, 300, "the crowds must actually push each other")
    }

    func testPlayerIndexDoesNotCacheLivenessPositionOrEligibility() {
        let world = world()
        let player = Player(world: world); player.setPos(0.5, 20, 0.5); world.addEntity(player)
        XCTAssertTrue(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16))
        // None of these change the entity list, so only a fresh look at the player can notice them.
        player.dead = true
        XCTAssertFalse(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16))
        player.dead = false; player.health = 0
        XCTAssertFalse(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16))
        player.health = 20; player.lanReplicatedMirror = true
        XCTAssertFalse(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16))
        player.lanReplicatedMirror = false; player.setPos(40.5, 20, 0.5)
        XCTAssertFalse(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16))
        player.setPos(4.5, 20.5, 16.5)
        XCTAssertTrue(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16), "exactly on the radius")
        player.setPos(4.5, 20.5, 16.5001)
        XCTAssertFalse(eligibleMonsterSpawnPlayerIsNear(world, 4.5, 20.5, 0.5, radius: 16))
    }

    func testProximityMatchesTheEntityScanItReplacesOverRandomWorlds() throws {
        var rng = RandomX(0x51A7)
        let elsewhere = World(dim: .overworld, seed: 7, generationSettings: .init(preset: .normal))
        var agreedNear = 0, agreedFar = 0
        for round in 0..<300 {
            let world = world()
            func coordinate(_ spread: Double) -> Double { (rng.nextFloat() * 2 - 1) * spread }
            var listed: [Entity] = []
            for index in 0..<rng.nextInt(5) {
                let x = coordinate(30), y = 20 + coordinate(14), z = coordinate(30)
                let entity: Entity
                switch rng.nextInt(4) {
                case 0: entity = remotePlayer(world, id: "guest-\(round)-\(index)", x: x, y: y, z: z)
                case 1: entity = Player(world: elsewhere)       // listed here, but belongs to another world
                default: entity = Player(world: world)
                }
                entity.setPos(x, y, z)
                switch rng.nextInt(18) {     // two in three stay ordinary, eligible players
                case 0: entity.dead = true
                case 1: (entity as? LivingEntity)?.health = 0
                case 2: entity.lanReplicatedMirror = true
                case 3: entity.x = .nan
                case 4: entity.y = Double(world.info.minY) - 4
                case 5: entity.z = 30_000_001
                default: break
                }
                world.addEntity(entity)
                listed.append(entity)
            }
            // Creatures and a non-`Entity` member near the spawner must never count as a player.
            for _ in 0..<rng.nextInt(6) {
                let mob = try XCTUnwrap(createEntity(rng.nextInt(2) == 0 ? "zombie" : "cow", world))
                mob.setPos(coordinate(10), 20, coordinate(10)); world.addEntity(mob)
            }
            world.addEntity(CountingBystander(id: 9_000 + round))
            for probe in 0..<12 {
                var x = Double(rng.nextInt(41) - 20) + 0.5, y = Double(20 + rng.nextInt(13) - 6) + 0.5
                var z = Double(rng.nextInt(41) - 20) + 0.5
                // Half the probes sit around a listed player, so both sides of the radius are hit.
                if probe % 2 == 0, !listed.isEmpty {
                    let anchor = listed[rng.nextInt(listed.count)]
                    if anchor.x.isFinite {
                        x = anchor.x + coordinate(11); y = anchor.y + coordinate(11); z = anchor.z + coordinate(11)
                    }
                }
                for radius in [16.0, 9.0] {
                    let expected = scanFindsEligiblePlayer(world, x, y, z, radius: radius)
                    XCTAssertEqual(eligibleMonsterSpawnPlayerIsNear(world, x, y, z, radius: radius), expected,
                                   "round \(round) at (\(x), \(y), \(z)) radius \(radius)")
                    if expected { agreedNear += 1 } else { agreedFar += 1 }
                }
            }
        }
        // The comparison is only worth something if both answers actually occur.
        XCTAssertGreaterThan(agreedNear, 800)
        XCTAssertGreaterThan(agreedFar, 800)
    }

    func testSleepingSpawnersDoNotWalkTheEntityList() {
        let world = world()
        world.setBlock(4, 20, 0, Int(cell(B.spawner)))
        let be = makeSpawnerBE(4, 20, 0, "zombie"); be.delay = 0
        world.setBlockEntity(be)
        let bystanders = (0..<64).map { CountingBystander(id: 9_000 + $0) }
        bystanders.forEach(world.addEntity)
        let far = Player(world: world); far.setPos(40.5, 20, 0.5); world.addEntity(far)
        let before = [gameRng.stateWords.0, gameRng.stateWords.1, gameRng.stateWords.2, gameRng.stateWords.3]
        for _ in 0..<200 { tickMonsterSpawner(world, be) }
        XCTAssertEqual(bystanders.reduce(0) { $0 + $1.reads }, 0,
                       "with no player in range a spawner reads players only, however many entities are loaded")
        XCTAssertEqual(be.delay, 0, "a sleeping spawner does not count down")
        XCTAssertEqual([gameRng.stateWords.0, gameRng.stateWords.1, gameRng.stateWords.2, gameRng.stateWords.3],
                       before, "and draws no random numbers")
        XCTAssertEqual(world.entities.count, 65)

        far.setPos(6.5, 20, 0.5)
        tickMonsterSpawner(world, be)
        XCTAssertGreaterThan(world.entities.count, 65, "the same spawner wakes once the player walks up")
    }
}
