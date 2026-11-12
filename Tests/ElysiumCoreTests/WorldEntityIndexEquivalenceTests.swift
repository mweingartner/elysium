import XCTest
@testable import ElysiumCore

/// Deeper equivalence checks for the world's player and living-entity index, written by an
/// independent reviewer. Each test keeps an independent copy of the walk the index replaced and
/// holds the shipped reader to it, including under every way code mutates `World.entities`.
final class WorldEntityIndexEquivalenceTests: XCTestCase {
    override class func setUp() {
        registerAllBlocks(); registerAllItems(); registerAllBiomes(); registerAllEntities(); registerAllSystems()
    }
    override func tearDown() { resetGameRng(0x6A57); super.tearDown() }

    /// An entity-list member that is not an `Entity`.
    private final class Bystander: EntityRef {
        let id: Int
        var x: Double, y: Double, z: Double
        var dead = false
        init(id: Int, x: Double, y: Double, z: Double) { self.id = id; self.x = x; self.y = y; self.z = z }
        func bb() -> AABB { AABB(x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3) }
    }

    private func world() -> World {
        let world = World(dim: .overworld, seed: 12345, generationSettings: .init(preset: .normal))
        world.dayTime = 18_000; world.time = 100; world.difficulty = 2
        for cz in -3...2 {
            for cx in -3...2 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                chunk.biomes = Array(repeating: UInt8(Biome.plains.rawValue), count: chunk.biomes.count)
                for z in 0..<16 { for x in 0..<16 {
                    chunk.set(x, 19, z, cell(B.stone))
                    chunk.heightmap[z * 16 + x] = 19
                } }
                world.setChunk(chunk)
            }
        }
        return world
    }

    private func remotePlayer(_ world: World, id: String, x: Double, y: Double, z: Double) -> LANRemotePlayerEntity {
        LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: id, displayName: "Guest", x: x, y: y, z: z, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival))
    }

    // MARK: - Oracles: the walks the index replaced, copied from the pre-index code.

    private func walkPlayers(_ world: World) -> [ObjectIdentifier] {
        var out: [ObjectIdentifier] = []
        for e in world.entities { if let ent = e as? Entity, ent.isPlayer { out.append(ObjectIdentifier(ent)) } }
        return out
    }

    private func walkLiving(_ world: World) -> [ObjectIdentifier] {
        world.entities.compactMap { ($0 as? LivingEntity).map(ObjectIdentifier.init) }
    }

    /// `getEntitiesNear(x, y, z, r) { ($0 as? Entity)?.isPlayer ?? false }`, inlined so the oracle
    /// does not share code with the shipped reader.
    private func walkPlayersNear(_ world: World, _ x: Double, _ y: Double, _ z: Double, _ r: Double) -> [ObjectIdentifier] {
        let r2 = r * r
        var out: [ObjectIdentifier] = []
        for e in world.entities {
            if e.dead { continue }
            let dx = e.x - x, dy = e.y - y, dz = e.z - z
            if dx * dx + dy * dy + dz * dz <= r2 && ((e as? Entity)?.isPlayer ?? false) { out.append(ObjectIdentifier(e)) }
        }
        return out
    }

    /// The despawn distance `Mob.mobTick` computed before the index existed.
    private func walkNearestPlayerSquared(_ mob: Mob) -> Double {
        var nearest = Double.infinity
        for e in mob.world.entities {
            if let ent = e as? Entity, ent.isPlayer {
                let d = (ent.x - mob.x) * (ent.x - mob.x) + (ent.y - mob.y) * (ent.y - mob.y) + (ent.z - mob.z) * (ent.z - mob.z)
                nearest = min(nearest, d)
            }
        }
        return nearest
    }

    // MARK: - Model-based fuzz over every mutation path of `World.entities`.

    /// Every way production and test code edits the list (add/remove helpers, subscript
    /// replacement, insert, reverse, swap, sort, filtered removal, whole assignment, and edits made
    /// while iterating a snapshot as `GameCore.tick` does) must be seen by the next read.
    func testIndexMatchesTheWalkAfterEveryKindOfEntityListMutation() throws {
        var rng = RandomX(0xE17A)
        var nextBystander = 50_000
        var playerHits = 0, livingHits = 0, nearHits = 0, mutations = 0
        let elsewhere = World(dim: .overworld, seed: 7, generationSettings: .init(preset: .normal))
        for round in 0..<40 {
            let world = world()
            func coordinate(_ spread: Double) -> Double { (rng.nextFloat() * 2 - 1) * spread }
            func make() throws -> EntityRef {
                let x = coordinate(30), y = 20 + coordinate(6), z = coordinate(30)
                let made: EntityRef
                switch rng.nextInt(8) {
                case 0: let p = Player(world: world); p.setPos(x, y, z); made = p
                case 1: made = remotePlayer(world, id: "g-\(round)-\(rng.nextInt(1_000_000))", x: x, y: y, z: z)
                case 2: let p = Player(world: elsewhere); p.setPos(x, y, z); made = p
                case 3, 4:
                    let mob = try XCTUnwrap(createEntity(["cow", "zombie", "pig"][rng.nextInt(3)], world))
                    mob.setPos(x, y, z); made = mob
                case 5:
                    let item = ItemEntity(world: world); item.stack = ItemStack(iid("stone"), 1)
                    item.setPos(x, y, z); made = item
                default:
                    nextBystander += 1
                    made = Bystander(id: nextBystander, x: x, y: y, z: z)
                }
                if let entity = made as? Entity, rng.nextInt(6) == 0 { entity.dead = true }
                return made
            }
            for _ in 0..<(4 + rng.nextInt(8)) { world.addEntity(try make()) }
            for _ in 0..<60 {
                let count = world.entities.count
                switch rng.nextInt(11) {
                case 0, 1: world.addEntity(try make())
                case 2: if count > 0 { world.removeEntity(world.entities[rng.nextInt(count)]) }
                case 3: world.entities.reverse()
                case 4: if count > 1 { world.entities.swapAt(rng.nextInt(count), rng.nextInt(count)) }
                case 5: if count > 0 { world.entities[rng.nextInt(count)] = try make() }
                case 6: world.entities.insert(try make(), at: rng.nextInt(count + 1))
                case 7:
                    let modulus = 2 + rng.nextInt(3), keep = rng.nextInt(modulus)
                    world.entities.removeAll { $0.id % modulus == keep }
                case 8: world.entities.sort { $0.id > $1.id }
                case 9:
                    // A tick-style loop over a snapshot: entities spawn and die as it walks, and a
                    // reader inside the loop must see each change immediately.
                    for (index, e) in Array(world.entities).enumerated() {
                        if index % 3 == 0 { world.addEntity(try make()) }
                        if index % 4 == 1 { world.removeEntity(e) }
                        XCTAssertEqual(world.playerEntities.map(ObjectIdentifier.init), walkPlayers(world))
                        XCTAssertEqual(world.livingEntities.map(ObjectIdentifier.init), walkLiving(world))
                    }
                default:
                    world.entities = Array(world.entities.prefix(rng.nextInt(count + 1)))
                }
                mutations += 1
                // Liveness and position change without touching the list; the index must not cache them.
                if !world.entities.isEmpty, let entity = world.entities[rng.nextInt(world.entities.count)] as? Entity,
                   rng.nextInt(3) == 0 {
                    if rng.nextInt(2) == 0 { entity.dead.toggle() } else { entity.setPos(coordinate(30), 20, coordinate(30)) }
                }
                let players = world.playerEntities.map(ObjectIdentifier.init)
                XCTAssertEqual(players, walkPlayers(world), "round \(round)")
                let living = world.livingEntities.map(ObjectIdentifier.init)
                XCTAssertEqual(living, walkLiving(world), "round \(round)")
                let x = coordinate(30), y = 20 + coordinate(8), z = coordinate(30)
                let radius = [1.2, 3, 9, 16, 32, 64][rng.nextInt(6)]
                let near = world.getPlayersNear(x, y, z, radius).map(ObjectIdentifier.init)
                XCTAssertEqual(near, walkPlayersNear(world, x, y, z, radius), "round \(round) radius \(radius)")
                if !players.isEmpty { playerHits += 1 }
                if !living.isEmpty { livingHits += 1 }
                if !near.isEmpty { nearHits += 1 }
            }
        }
        XCTAssertEqual(mutations, 40 * 60)
        XCTAssertGreaterThan(playerHits, 1_000, "comparisons must cover populated player lists")
        XCTAssertGreaterThan(livingHits, 1_000)
        XCTAssertGreaterThan(nearHits, 300, "and real proximity hits, not only empty answers")
    }

    /// Iterating the typed list visits the members present when the loop started, exactly as
    /// `for e in world.entities` did, even when the loop body grows the world.
    func testLoopsOverTheIndexIterateTheSnapshotTheWalkWouldHave() throws {
        let world = world()
        for index in 0..<6 {
            let cow = try XCTUnwrap(createEntity("cow", world)); cow.setPos(Double(index), 20, 0); world.addEntity(cow)
        }
        var walked: [ObjectIdentifier] = []
        for e in world.entities {
            if let living = e as? LivingEntity {
                walked.append(ObjectIdentifier(living))
                let calf = try XCTUnwrap(createEntity("cow", world)); calf.setPos(0, 20, 9); world.addEntity(calf)
            }
        }
        XCTAssertEqual(world.entities.count, 12)
        var indexed: [ObjectIdentifier] = []
        let before = world.livingEntities.map(ObjectIdentifier.init)
        for living in world.livingEntities {
            indexed.append(ObjectIdentifier(living))
            let calf = try XCTUnwrap(createEntity("cow", world)); calf.setPos(0, 20, 9); world.addEntity(calf)
        }
        XCTAssertEqual(indexed, before, "the loop visits the 12 members present when it began")
        XCTAssertEqual(indexed.count, 12)
        XCTAssertEqual(Array(indexed.prefix(6)), walked)
        XCTAssertEqual(world.livingEntities.count, 24, "and the next read sees every calf added during it")
    }

    // MARK: - The monster despawn rule.

    /// A dead player still counts for the despawn distance, as it always has: a zombie next to a
    /// dead player is never despawned, and draws no despawn random number while it waits.
    func testDeadPlayerNearbyStillKeepsAMonsterFromDespawning() throws {
        resetGameRng(0x0DEA)
        let world = world()
        let zombie = try XCTUnwrap(createEntity("zombie", world) as? Mob); zombie.setPos(0.5, 20, 0.5)
        world.addEntity(zombie)
        let player = Player(world: world); player.setPos(10.5, 20, 0.5); player.dead = true
        world.addEntity(player)
        XCTAssertEqual(walkNearestPlayerSquared(zombie), 100)
        XCTAssertTrue(world.getPlayersNear(0.5, 20, 0.5, 64).isEmpty, "the proximity reader skips the dead player")
        // Forty ticks of wandering cannot carry it 22 blocks farther, so only the rule decides.
        for tick in 0..<40 {
            zombie.mobTick()
            XCTAssertFalse(zombie.dead, "tick \(tick): a dead player within 32 blocks keeps the zombie")
        }
        // Without any listed player, the same zombie despawns on its next tick.
        world.removeEntity(player)
        zombie.mobTick()
        XCTAssertTrue(zombie.dead)
    }

    /// Over random worlds the shipped rule agrees with the walk it replaced wherever the rule is
    /// deterministic: nearer than 32 blocks the monster stays, beyond 128 it is removed at once.
    func testMonsterDespawnFollowsTheEntityWalkOverRandomWorlds() throws {
        resetGameRng(0x0DEB)
        var rng = RandomX(0xDE5B)
        let elsewhere = World(dim: .overworld, seed: 9, generationSettings: .init(preset: .normal))
        var kept = 0, removed = 0, keptByDeadPlayer = 0
        for round in 0..<240 {
            let world = world()
            let zombie = try XCTUnwrap(createEntity("zombie", world) as? Mob); zombie.setPos(0.5, 20, 0.5)
            world.addEntity(zombie)
            func coordinate(_ spread: Double) -> Double { (rng.nextFloat() * 2 - 1) * spread }
            var listedLivePlayerNear = false
            for index in 0..<rng.nextInt(4) {
                let distance = [6.0, 20, 31, 60, 140, 200][rng.nextInt(6)]
                let angle = rng.nextFloat() * 2 * Double.pi
                let x = 0.5 + distance * cos(angle), z = 0.5 + distance * sin(angle)
                let entity: Entity
                switch rng.nextInt(4) {
                case 0: entity = remotePlayer(world, id: "g-\(round)-\(index)", x: x, y: 20, z: z)
                case 1: entity = Player(world: elsewhere)   // listed here, counted by the old walk too
                default: entity = Player(world: world)
                }
                entity.setPos(x, 20, z)
                switch rng.nextInt(8) {
                case 0: entity.dead = true
                case 1: entity.x = .nan
                case 2: entity.lanReplicatedMirror = true
                default: break
                }
                if !entity.dead && distance < 32 { listedLivePlayerNear = true }
                world.addEntity(entity)
            }
            // Non-players (kept out of push range) must never count as the nearest player.
            for _ in 0..<rng.nextInt(4) {
                let cow = try XCTUnwrap(createEntity("cow", world)); cow.setPos(8 + coordinate(4), 20, 8 + coordinate(4))
                world.addEntity(cow)
            }
            world.addEntity(Bystander(id: 70_000 + round, x: 2, y: 20, z: 2))
            let reference = walkNearestPlayerSquared(zombie)
            let distance = reference.squareRoot()
            zombie.mobTick()
            if distance < 31.5 {
                XCTAssertFalse(zombie.dead, "round \(round): nearest listed player \(distance) blocks away")
                kept += 1
                if !listedLivePlayerNear { keptByDeadPlayer += 1 }
            } else if distance > 128.5 {
                XCTAssertTrue(zombie.dead, "round \(round): nearest listed player \(distance) blocks away")
                removed += 1
            }
        }
        XCTAssertGreaterThan(kept, 60)
        XCTAssertGreaterThan(removed, 30)
        XCTAssertGreaterThan(keptByDeadPlayer, 3, "dead and mirror players must be exercised, not only live ones")
    }
}
