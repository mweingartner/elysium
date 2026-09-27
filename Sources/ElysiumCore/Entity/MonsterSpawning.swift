// Host-owned dungeon and periodic underground spawning, including prehistoric maps.
// Existing surface spawning and dinosaur dawn populations keep their own rules.
import Foundation

private func eligibleMonsterSpawnPlayer(_ entity: Entity, in world: World) -> Bool {
    entity.world === world && entity.isPlayer && !entity.dead && !entity.lanReplicatedMirror
        && ((entity as? LivingEntity)?.health ?? 0) > 0
        && entity.x.isFinite && entity.y.isFinite && entity.z.isFinite
        && abs(entity.x) < 30_000_000 && abs(entity.z) < 30_000_000
        && entity.y >= Double(world.info.minY) && entity.y < Double(world.info.minY + world.info.height)
}

/// Validate the actual factory body's entire footprint before publishing it.
/// Factories may reserve an ID for a refused candidate; no refused entity enters
/// the world, event bus or save. This uses deterministic, bounded body geometry.
func monsterSpawnBodyFits(_ world: World, _ entity: Entity) -> Bool {
    let box = entity.bb()
    guard box.y0 > Double(world.info.minY), box.y1 < Double(world.info.minY + world.info.height) else { return false }
    for z in ifloor(box.z0)...ifloor(box.z1 - 0.0001) {
        for x in ifloor(box.x0)...ifloor(box.x1 - 0.0001) {
            guard world.isLoadedAt(x, z),
                  world.playableMinX.map({ x >= $0 }) ?? true,
                  world.playableMaxX.map({ x <= $0 }) ?? true,
                  world.playableMinZ.map({ z >= $0 }) ?? true,
                  world.playableMaxZ.map({ z <= $0 }) ?? true else { return false }
            for y in ifloor(box.y0)...ifloor(box.y1 - 0.0001) {
                if spawnPlacementCellIsFluid(world, x, y, z) { return false }
            }
        }
    }
    let below = world.getBlockId(ifloor(entity.x), ifloor(entity.y) - 1, ifloor(entity.z))
    guard below != 0, blockDefs[below].solid, below != Int(B.bedrock) else { return false }
    var blocked = false
    world.forEachCollisionBox(box) { if box.intersects($0) { blocked = true } }
    if blocked { return false }
    return !world.entities.contains { ref in
        guard let other = ref as? LivingEntity, !other.dead else { return false }
        return box.intersects(other.bb())
    }
}

func tickMonsterSpawner(_ world: World, _ be: BlockEntityData) {
    guard !world.isTransientLANClient, world.difficulty > 0, world.rule("doMobSpawning"),
          world.getBlockId(be.x, be.y, be.z) == Int(B.spawner) else { return }
    let near = world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 16) {
        guard let entity = $0 as? Entity else { return false }
        return eligibleMonsterSpawnPlayer(entity, in: world)
    }
    guard !near.isEmpty else { return }
    if world.time % 10 == 0 {
        world.hooks.addParticles("flame", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 0.4, 0)
        world.hooks.addParticles("smoke", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 0.4, 0)
    }
    be.delay = max(0, be.delay ?? 0) - 1
    guard (be.delay ?? 0) <= 0 else { return }
    let type = be.mob ?? "zombie"
    let count = world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 9) {
        guard let entity = $0 as? LivingEntity else { return false }
        return !entity.dead && entity.health > 0 && entity.type == type
    }.count
    guard count < 6 else { be.delay = 200; return }
    let target = min(6 - count, 1 + gameRng.nextInt(4))
    var spawned = 0
    // A dungeon's floor is normally at be.y. Scan all three authored nearby
    // floor heights per column instead of spending most waves on air/stone.
    for _ in 0..<32 {
        if spawned >= target { break }
        let x = be.x + gameRng.nextInt(7) - 3
        let z = be.z + gameRng.nextInt(7) - 3
        for y in [be.y, be.y - 1, be.y + 1] {
            guard spawnPlacementIsValid(world, type, x, y, z),
                  world.getBlockId(x, y - 1, z) != 0,
                  blockDefs[world.getBlockId(x, y - 1, z)].solid,
                  world.getBlockLight(x, y, z) <= (type == "blaze" ? 11 : 0),
                  let entity = createEntity(type, world) else { continue }
            entity.setPos(Double(x) + 0.5, Double(y), Double(z) + 0.5)
            guard monsterSpawnBodyFits(world, entity) else { continue }
            world.addEntity(entity)
            spawned += 1
            world.hooks.addParticles("flame", entity.x, entity.y + 0.5, entity.z, 8, 0.4, 0)
            break
        }
    }
    // Failed geometry/light attempts retry in one second, without a false
    // success sound or another 10–40-second empty wave.
    be.delay = spawned > 0 ? 200 + gameRng.nextInt(600) : 20
    if spawned > 0 {
        world.hooks.playSound("block.spawner.spawn", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 1)
    }
}

public struct CaveSpawnReport: Equatable, Sendable {
    public internal(set) var columnsChecked = 0
    public internal(set) var floorChecks = 0
    public internal(set) var spawned = 0
}

/// Every 100 simulation ticks at night, search at most 16 columns × 33 heights
/// near active players for dark, roofed, supported floors. At most four births
/// per pass and 16 nearby monsters per player/vertical neighbourhood. Remote
/// loaded populations cannot consume another cave's entire local allowance.
@discardableResult
public func spawnNightCaveMonsters(_ world: World, _ players: [Entity], _ rng: inout RandomX) -> CaveSpawnReport {
    var report = CaveSpawnReport()
    guard !world.isTransientLANClient, world.info.hasSky, world.difficulty > 0,
          world.rule("doMobSpawning"), (13_000..<23_000).contains(world.dayTime),
          world.time % 100 == 0 else { return report }
    let active = players.filter { eligibleMonsterSpawnPlayer($0, in: world) }.sorted { $0.id < $1.id }
    guard !active.isEmpty else { return report }
    let monsters = world.entities.compactMap { $0 as? Mob }.filter { !$0.dead && $0.health > 0 && $0.category == "monster" }
    func nearby(_ x: Double, _ y: Double, _ z: Double, _ player: Entity) -> Bool {
        let dx = x - player.x, dz = z - player.z
        return dx * dx + dz * dz <= 80 * 80 && abs(y - player.y) <= 24
    }
    var counts = active.map { player in monsters.filter { nearby($0.x, $0.y, $0.z, player) }.count }
    guard counts.contains(where: { $0 < 16 }) else { return report }
    let first = rng.nextInt(active.count)
    for attempt in 0..<16 {
        if report.spawned >= 4 { break }
        let index = (first + attempt) % active.count
        guard counts[index] < 16 else { continue }
        let player = active[index]
        let distance = 24 + rng.nextFloat() * 40
        let angle = rng.nextFloat() * .pi * 2
        let x = ifloor(player.x + detCos(angle) * distance)
        let z = ifloor(player.z + detSin(angle) * distance)
        report.columnsChecked += 1
        guard world.isLoadedAt(x, z) else { continue }
        for step in 0..<33 {
            let offset = step == 0 ? 0 : (step + 1) / 2 * (step % 2 == 1 ? 1 : -1)
            let y = ifloor(player.y) + offset
            report.floorChecks += 1
            guard y > world.info.minY, y + 2 < world.info.minY + world.info.height,
                  world.heightAt(x, z) >= y + 2, world.getSkyLight(x, y, z) == 0,
                  world.getBlockLight(x, y, z) == 0,
                  world.getBlockId(x, y - 1, z) != 0,
                  blockDefs[world.getBlockId(x, y - 1, z)].solid,
                  spawnPlacementIsValid(world, "zombie", x, y, z) else { continue }
            let px = Double(x) + 0.5, py = Double(y), pz = Double(z) + 0.5
            guard !active.contains(where: {
                let dx = $0.x - px, dy = $0.y - py, dz = $0.z - pz
                return dx * dx + dy * dy + dz * dz < 24 * 24
            }), !active.enumerated().contains(where: { i, p in counts[i] >= 16 && nearby(px, py, pz, p) }) else { continue }
            guard let biome = BIOMES[Int(world.biomeAt(x, y, z))], !biome.monsters.isEmpty else { continue }
            let type = rng.pickWeighted(biome.monsters) { $0.weight }.mob
            guard canSpawnAt(world, type, "monster", x, y, z, &rng),
                  let mob = createEntity(type, world) as? Mob else { continue }
            mob.setPos(px, py, pz)
            guard monsterSpawnBodyFits(world, mob) else { continue }
            world.addEntity(mob)
            for (i, p) in active.enumerated() where nearby(px, py, pz, p) { counts[i] += 1 }
            report.spawned += 1
            break
        }
    }
    return report
}
