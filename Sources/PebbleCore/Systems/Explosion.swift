// Explosion engine — ray-based block
// destruction with blast resistance, entity damage + knockback, item drops,
// chain TNT ignition. All state randomness draws from gameRng in baseline order.

import Foundation

public func explode(_ world: World, _ x: Double, _ y: Double, _ z: Double, _ power: Double, _ fire: Bool, _ source: Entity?) {
    world.hooks.playSound("entity.generic.explode", x, y, z, 4, (1 + (Double.random(in: 0..<1) - Double.random(in: 0..<1)) * 0.2) * 0.7)
    world.hooks.addParticles("explosion", x, y, z, Int(min(40, power * 8)), power * 0.6, 0)

    // --- block destruction: 16×16 rays from center ---
    var destroyedList: [(Int, Int, Int)] = []
    var destroyedSet = Set<Int64>()
    func addDestroyed(_ bx: Int, _ by: Int, _ bz: Int) {
        let key = (Int64(bx) << 40) ^ (Int64(by) << 20) ^ Int64(bz)
        if destroyedSet.insert(key).inserted {
            destroyedList.append((bx, by, bz))
        }
    }
    if world.rule("mobGriefing") || source?.type == "tnt" {
        for rx in 0..<16 {
            for ry in 0..<16 {
                for rz in 0..<16 {
                    if rx != 0 && rx != 15 && ry != 0 && ry != 15 && rz != 0 && rz != 15 { continue }
                    var dx = Double(rx) / 15 * 2 - 1
                    var dy = Double(ry) / 15 * 2 - 1
                    var dz = Double(rz) / 15 * 2 - 1
                    let len = detHyp3(dx, dy, dz)
                    dx /= len; dy /= len; dz /= len
                    var intensity = power * (0.7 + gameRng.nextFloat() * 0.6)
                    var px = x, py = y, pz = z
                    while intensity > 0 {
                        let bx = ifloor(px), by = ifloor(py), bz = ifloor(pz)
                        let c = world.getBlock(bx, by, bz)
                        let bid = c >> 4
                        if bid != 0 {
                            let res = blockDefs[bid].resistance
                            if blockDefs[bid].hardness < 0 { break } // unbreakable
                            intensity -= (res + 0.3) * 0.3
                            if intensity > 0 { addDestroyed(bx, by, bz) }
                        }
                        intensity -= 0.225
                        px += dx * 0.3; py += dy * 0.3; pz += dz * 0.3
                    }
                }
            }
        }
    }

    // --- entity damage ---
    let radius = power * 2
    for e in world.getEntitiesNear(x, y, z, radius) {
        guard let ent = e as? Entity else { continue }
        let dist = detHyp3(ent.x - x, ent.y + ent.height / 2 - y, ent.z - z)
        if dist > radius { continue }
        let exposure = 1 - dist / radius // (skip expensive exposure rays)
        let dmg = ((exposure * exposure + exposure) / 2 * 7 * power + 1).rounded(.down)
        ent.hurt(dmg, "explosion", source)
        let dx2 = ent.x - x, dy2 = (ent.y + ent.height / 2) - y, dz2 = ent.z - z
        var d2 = detHyp3(dx2, dy2, dz2)
        if d2 == 0 { d2 = 1 }
        let kb = exposure * 1.2
        ent.vx += dx2 / d2 * kb
        ent.vy += dy2 / d2 * kb + 0.1
        ent.vz += dz2 / d2 * kb
    }

    // --- apply destruction ---
    for (bx, by, bz) in destroyedList {
        if world.consumeRPGExplosionProtection(at: RPGBlockPosition(bx, by, bz)) { continue }
        let c = world.getBlock(bx, by, bz)
        let bid = c >> 4
        if bid == 0 { continue }
        if bid == Int(B.tnt) {
            // chain ignite
            let tnt = TNTEntity(world: world)
            _ = world.transferRPGControlledCharge(at: RPGBlockPosition(bx, by, bz), to: tnt)
            world.setBlock(bx, by, bz, 0)
            tnt.setPos(Double(bx) + 0.5, Double(by), Double(bz) + 0.5)
            tnt.fuse = 10 + gameRng.nextInt(20)
            world.addEntity(tnt)
            continue
        }
        world.setBlock(bx, by, bz, 0)
        // drop with 1/power chance
        if world.rule("doTileDrops") && gameRng.nextFloat() < 1 / power {
            let ctx = DropCtx(fortune: 0, silkTouch: false, toolType: .none, toolTier: 0, shears: false,
                              random: { gameRng.nextFloat() })
            if let drops = blockDefs[bid].drops?(c & 15, ctx) {
                for d in drops {
                    if let itemId = iidOpt(d.item) {
                        let count = d.countMin == d.countMax
                            ? d.countMin
                            : d.countMin + gameRng.nextInt(d.countMax - d.countMin + 1)
                        spawnItem(world, Double(bx) + 0.5, Double(by) + 0.5, Double(bz) + 0.5, ItemStack(itemId, count))
                    }
                }
            }
        }
    }
    // fire
    if fire {
        for (bx, by, bz) in destroyedList {
            if gameRng.nextFloat() < 0.33 && world.getBlock(bx, by, bz) == 0 && (world.getBlock(bx, by - 1, bz) >> 4) != 0 {
                world.setBlock(bx, by, bz, Int(B.fire) << 4)
            }
        }
    }
}

public func registerExplosionHandler() {
    bindExplode(explode)
}
