// Projectiles — arrows, snowballs, eggs, ender
// pearls, XP bottles, potions, fireballs, wither skulls, shulker bullets,
// tridents, fishing bobbers, fireworks, llama spit, dragon fireballs.
//
// Two deterministic bug-compats kept on purpose: Fireball.width and WitherSkull.drag read
// their `small`/`blue` flags during construction (always false), so width=1 /
// drag=1 regardless of the flag set afterwards.

import Foundation

open class Projectile: Entity {
    public var owner: Entity?
    public var gravity = 0.03
    public var drag = 0.99
    public var stuck = false

    public override init(world: World) {
        super.init(world: world)
        width = 0.25
        height = 0.25
    }

    public func shoot(_ dx: Double, _ dy: Double, _ dz: Double, _ power: Double, _ inaccuracy: Double) {
        var len = (dx * dx + dy * dy + dz * dz).squareRoot()
        if len == 0 { len = 1 }
        func r() -> Double { (gameRng.nextFloat() - 0.5) * 0.0075 * inaccuracy }
        vx = (dx / len + r()) * power
        vy = (dy / len + r()) * power
        vz = (dz / len + r()) * power
        yaw = detAtan2(-vx, vz)
        pitch = -detAtan2(vy, (vx * vx + vz * vz).squareRoot())
    }

    public func shootFrom(_ shooter: Entity, _ pitchRad: Double, _ yawRad: Double, _ power: Double, _ inaccuracy: Double) {
        let dx = -detSin(yawRad) * detCos(pitchRad)
        let dy = -detSin(pitchRad)
        let dz = detCos(yawRad) * detCos(pitchRad)
        let ey = shooter.eyeY() - 0.1
        setPos(shooter.x, ey, shooter.z)
        shoot(dx, dy, dz, power, inaccuracy)
        owner = shooter
    }

    open override func tick() {
        baseTick()
        if stuck {
            onStuckTick()
            return
        }
        // move with raycast collision
        let speed = (vx * vx + vy * vy + vz * vz).squareRoot()
        if speed > 0.001 {
            let hit = world.raycast(x, y, z, vx / speed, vy / speed, vz / speed, speed)
            // entity hit check along path — eHit.t is a FRACTION of this
            // tick's travel, hit.t is in BLOCKS; scale before comparing or
            // entities get hit through walls
            let eHit = findEntityHit(speed)
            if let eHit, hit == nil || eHit.t * speed <= hit!.t {
                onHitEntity(eHit.entity)
            } else if let hit {
                x = hit.px; y = hit.py; z = hit.pz
                onHitBlock(hit)
            }
        }
        if dead { return }
        x += vx; y += vy; z += vz
        vy -= gravity
        let dragF = inWater ? 0.8 : drag
        vx *= dragF; vy *= dragF; vz *= dragF
        yaw = detAtan2(-vx, vz)
        pitch = -detAtan2(vy, (vx * vx + vz * vz).squareRoot())
        if age > 1200 { remove() }
    }

    func findEntityHit(_ speed: Double) -> (entity: Entity, t: Double)? {
        var best: (entity: Entity, t: Double)? = nil
        for e in world.getEntitiesNear(x, y, z, speed + 2) {
            guard let ent = e as? Entity else { continue }
            if ent === self || (ent === owner && age < 5) || ent.dead { continue }
            if !(ent is LivingEntity) && ent.type != "end_crystal" { continue }
            let bb = ent.bb()
            // ray vs box
            let t = rayBox(x, y, z, vx, vy, vz,
                           bb.x0 - 0.1, bb.y0 - 0.1, bb.z0 - 0.1,
                           bb.x1 + 0.1, bb.y1 + 0.1, bb.z1 + 0.1)
            if let t, t <= 1, best == nil || t < best!.t { best = (ent, t) }
        }
        return best
    }

    open func onStuckTick() { remove() }
    open func onHitEntity(_ e: Entity) {}
    open func onHitBlock(_ hit: RaycastHit) {}
}

private func rayBox(_ ox: Double, _ oy: Double, _ oz: Double,
                    _ dx: Double, _ dy: Double, _ dz: Double,
                    _ x0: Double, _ y0: Double, _ z0: Double,
                    _ x1: Double, _ y1: Double, _ z1: Double) -> Double? {
    var tmin = 0.0, tmax = 1.0
    let axes: [(Double, Double, Double, Double)] = [(ox, dx, x0, x1), (oy, dy, y0, y1), (oz, dz, z0, z1)]
    for (o, d, lo, hi) in axes {
        if abs(d) < 1e-9 {
            if o < lo || o > hi { return nil }
        } else {
            var t1 = (lo - o) / d, t2 = (hi - o) / d
            if t1 > t2 { swap(&t1, &t2) }
            tmin = max(tmin, t1)
            tmax = min(tmax, t2)
            if tmin > tmax { return nil }
        }
    }
    return tmin
}

public final class ArrowEntity: Projectile {
    public override var type: String { "arrow" }
    public var damage = 2.0
    public var critical = false
    public var pickupable = true
    public var punchLevel = 0
    public var flame = false
    public var potionId: String? = nil // tipped
    public var spectral = false
    public var stuckTime = 0
    public var fromCrossbow = false
    public var piercingLeft = 0

    public override init(world: World) {
        super.init(world: world)
        gravity = 0.05
    }

    public override func onHitEntity(_ e: Entity) {
        let speed = (vx * vx + vy * vy + vz * vz).squareRoot()
        var dmg = (speed * damage).rounded(.up)
        if critical { dmg += (gameRng.nextFloat() * (dmg / 2 + 1)).rounded(.down) }
        if flame { e.fireTicks = max(e.fireTicks, 100) }
        let hurt = e.hurt(dmg, "projectile", owner)
        if hurt {
            if punchLevel > 0, let liv = e as? LivingEntity {
                var d = (vx * vx + vz * vz).squareRoot()
                if d == 0 { d = 1 }
                liv.vx += vx / d * Double(punchLevel) * 0.4
                liv.vz += vz / d * Double(punchLevel) * 0.4
            }
            if let potionId, let liv = e as? LivingEntity {
                let pot = potionDef(potionId)
                for ef in pot.effects { liv.addEffect(ef.effect, ef.duration / 8, ef.amplifier) }
            }
            if spectral, let liv = e as? LivingEntity { liv.addEffect("glowing", 200, 0) }
            world.hooks.playSound("entity.arrow.hit_player", e.x, e.y, e.z, 0.6, 1.2)
        }
        if piercingLeft > 0 {
            piercingLeft -= 1
        } else {
            remove()
        }
    }
    public override func onHitBlock(_ hit: RaycastHit) {
        stuck = true
        vx = 0; vy = 0; vz = 0
        world.hooks.playSound("entity.arrow.hit", x, y, z, 0.7, 1.1)
        // target block signal
        if (hit.cell >> 4) == Int(B.target) {
            let cx = Double(hit.x) + 0.5, cy = Double(hit.y) + 0.5, cz = Double(hit.z) + 0.5
            let ddx = x - cx, ddy = y - cy, ddz = z - cz
            let dist = (ddx * ddx + ddy * ddy + ddz * ddz).squareRoot()
            let power = max(1, min(15, Int(detRound((1 - dist) * 15 + 8))))
            world.setBlock(hit.x, hit.y, hit.z, Int(cell(B.target, min(15, power))))
            world.scheduleTick(hit.x, hit.y, hit.z, Int(B.target), 20)
        }
    }
    public override func onStuckTick() {
        stuckTime += 1
        // pickup
        if pickupable && stuckTime > 10 {
            for e in world.getEntitiesNear(x, y, z, 1.2, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                guard let p = e as? LivingEntity else { continue }
                let s = ItemStack(iid(potionId != nil ? "tipped_arrow" : spectral ? "spectral_arrow" : "arrow"), 1)
                if let potionId { s.data.potion = potionId }
                if p.give(s) {
                    world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.6)
                    remove()
                    return
                }
            }
        }
        if stuckTime > 1200 { remove() }
    }
}

public final class ThrownSnowball: Projectile {
    public override var type: String { "snowball" }
    public override func onHitEntity(_ e: Entity) {
        let dmg: Double = e.type == "blaze" ? 3 : 0
        e.hurt(dmg, "projectile", owner)
        world.hooks.addParticles("snow", x, y, z, 6, 0.2, 0)
        remove()
    }
    public override func onHitBlock(_ hit: RaycastHit) {
        world.hooks.addParticles("snow", x, y, z, 6, 0.2, 0)
        remove()
    }
}

public final class ThrownEgg: Projectile {
    public override var type: String { "egg" }
    public override func onHitEntity(_ e: Entity) {
        e.hurt(0, "projectile", owner)
        hatch()
    }
    public override func onHitBlock(_ hit: RaycastHit) { hatch() }
    private func hatch() {
        if gameRng.nextFloat() < 0.125 {
            let count = gameRng.nextFloat() < 0.0312 ? 4 : 1
            for _ in 0..<count {
                _ = spawnMobFn?(world, "chicken", x, y, z, SpawnOpts(baby: true))
            }
        }
        world.hooks.addParticles("block", x, y, z, 6, 0.2, Int(cell(B.bone_block)))
        remove()
    }
}

public final class ThrownPearl: Projectile {
    public override var type: String { "ender_pearl" }
    public override func onHitEntity(_ e: Entity) { teleport() }
    public override func onHitBlock(_ hit: RaycastHit) { teleport() }
    private func teleport() {
        if let owner, !owner.dead {
            owner.x = x
            owner.y = y + 0.1
            owner.z = z
            owner.hurt(5, "fall")
            world.hooks.playSound("entity.enderman.teleport", x, y, z, 1, 1)
            world.hooks.addParticles("portal", x, y + 1, z, 24, 0.5, 0)
        }
        remove()
    }
}

public final class ThrownXPBottle: Projectile {
    public override var type: String { "xp_bottle" }
    public override func onHitEntity(_ e: Entity) { smash() }
    public override func onHitBlock(_ hit: RaycastHit) { smash() }
    private func smash() {
        spawnXP(world, x, y, z, 3 + gameRng.nextInt(9))
        world.hooks.playSound("block.glass.break", x, y, z, 1, 1)
        world.hooks.addParticles("enchant", x, y, z, 16, 0.4, 0)
        remove()
    }
}

public final class ThrownPotion: Projectile {
    public override var type: String { "thrown_potion" }
    public var potionId = "water"
    public var lingering = false
    public override func onHitEntity(_ e: Entity) { smash() }
    public override func onHitBlock(_ hit: RaycastHit) { smash() }
    private func smash() {
        let pot = potionDef(potionId)
        world.hooks.playSound("block.glass.break", x, y, z, 1, 1)
        if lingering {
            let cloud = AreaEffectCloud(world: world)
            cloud.setPos(x, y, z)
            if let first = pot.effects.first {
                cloud.effectId = first.effect
                cloud.amplifier = first.amplifier
            }
            cloud.particleType = "portal"
            cloud.duration = 600
            world.addEntity(cloud)
        } else {
            for e in world.getEntitiesNear(x, y, z, 4) {
                guard let liv = e as? LivingEntity, !liv.dead else { continue }
                let ddx = e.x - x, ddy = e.y - y, ddz = e.z - z
                let dist = (ddx * ddx + ddy * ddy + ddz * ddz).squareRoot()
                let f = max(0, 1 - dist / 4)
                for ef in pot.effects {
                    liv.addEffect(ef.effect, Int((Double(ef.duration) * 0.75 * f).rounded(.down)), ef.amplifier)
                }
                // water extinguishes
                if potionId == "water" { liv.fireTicks = 0 }
            }
        }
        world.hooks.addParticles("splash", x, y, z, 20, 0.6, 0)
        remove()
    }
}

public final class Fireball: Projectile {
    public override var type: String { "fireball" }
    public var power = 1.0
    public var small = false
    public override init(world: World) {
        super.init(world: world)
        gravity = 0
        drag = 1
        width = 1   // baseline evaluates `small ? 0.3 : 1` at construction (small=false)
    }
    public override func tick() {
        super.tick()
        if !dead && age % 2 == 0 {
            world.hooks.addParticles(small ? "flame" : "smoke", x, y, z, 1, 0.1, 0)
        }
    }
    public override func onHitEntity(_ e: Entity) {
        e.hurt(small ? 5 : 6, "fireball", owner)
        e.fireTicks = max(e.fireTicks, 100)
        explode()
    }
    public override func onHitBlock(_ hit: RaycastHit) { explode() }
    private func explode() {
        if small {
            // small fireball: just fire
            let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
            if world.rule("mobGriefing") && (world.getBlock(bx, by + 1, bz) >> 4) == 0 {
                world.setBlock(bx, by + 1, bz, Int(cell(B.fire)))
            }
        } else {
            explodeFn?(world, x, y, z, power, world.rule("mobGriefing"), self)
        }
        remove()
    }
    /// ghast fireballs can be deflected
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if let attacker {
            let dx = x - attacker.x, dy = y - attacker.eyeY(), dz = z - attacker.z
            var d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d == 0 { d = 1 }
            vx = dx / d * 1.2; vy = dy / d * 1.2; vz = dz / d * 1.2
            owner = attacker
            return true
        }
        return false
    }
}

public final class WitherSkull: Projectile {
    public override var type: String { "wither_skull" }
    public var blue = false
    public override init(world: World) {
        super.init(world: world)
        gravity = 0
        drag = 1    // baseline evaluates `blue ? 0.73 : 1` at construction (blue=false)
    }
    public override func onHitEntity(_ e: Entity) {
        e.hurt(8, "wither_skull", owner)
        (e as? LivingEntity)?.addEffect("wither", 200, 1)
        explode()
    }
    public override func onHitBlock(_ hit: RaycastHit) { explode() }
    private func explode() {
        explodeFn?(world, x, y, z, 1, false, self)
        remove()
    }
}

public final class DragonFireball: Projectile {
    public override var type: String { "dragon_fireball" }
    public override init(world: World) {
        super.init(world: world)
        gravity = 0
        drag = 1
    }
    public override func onHitEntity(_ e: Entity) { breath() }
    public override func onHitBlock(_ hit: RaycastHit) { breath() }
    private func breath() {
        let cloud = AreaEffectCloud(world: world)
        cloud.setPos(x, y, z)
        cloud.effectId = "instant_damage"
        cloud.amplifier = 0
        cloud.radius = 3
        cloud.duration = 120
        cloud.particleType = "dragon_breath"
        world.addEntity(cloud)
        world.hooks.playSound("entity.generic.explode", x, y, z, 1, 0.8)
        remove()
    }
}

public final class ShulkerBullet: Projectile {
    public override var type: String { "shulker_bullet" }
    public var targetId: Int? = nil
    public override init(world: World) {
        super.init(world: world)
        gravity = 0
        drag = 1
    }
    public override func tick() {
        // homing
        if let targetId, let t = world.entityById[targetId], !t.dead {
            let dx = t.x - x, dy = t.y + 1 - y, dz = t.z - z
            var d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d == 0 { d = 1 }
            vx += (dx / d * 0.18 - vx) * 0.18
            vy += (dy / d * 0.18 - vy) * 0.18
            vz += (dz / d * 0.18 - vz) * 0.18
        }
        super.tick()
        if !dead && age % 2 == 0 { world.hooks.addParticles("portal", x, y, z, 1, 0.1, 0) }
    }
    public override func onHitEntity(_ e: Entity) {
        e.hurt(4, "projectile", owner)
        (e as? LivingEntity)?.addEffect("levitation", 200, 0)
        remove()
    }
    public override func onHitBlock(_ hit: RaycastHit) { remove() }
}

public final class TridentEntity: Projectile {
    public override var type: String { "trident" }
    public var stack: ItemStack? = nil
    public var loyalty = 0
    public var returning = false
    public var dealtDamage = false
    public override init(world: World) {
        super.init(world: world)
        gravity = 0.05
    }
    public override func tick() {
        if returning, let owner, !owner.dead {
            let dx = owner.x - x, dy = owner.eyeY() - y, dz = owner.z - z
            var d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d == 0 { d = 1 }
            vx = dx / d * (0.3 + Double(loyalty) * 0.12)
            vy = dy / d * (0.3 + Double(loyalty) * 0.12)
            vz = dz / d * (0.3 + Double(loyalty) * 0.12)
            x += vx; y += vy; z += vz
            age += 1
            if d < 1.5 {
                if (owner as? LivingEntity)?.give(stack) == true {
                    world.hooks.playSound("entity.item.pickup", x, y, z, 0.4, 1.4)
                }
                remove()
            }
            return
        }
        super.tick()
    }
    public override func onHitEntity(_ e: Entity) {
        if dealtDamage { return } // one target per throw — no piercing
        let impaling = stack.map { enchLevel($0, "impaling") } ?? 0
        let waterBonus = ((e as? LivingEntity)?.breathesWater ?? false) ? 1.0 : 0.0
        let dmg = 8 + Double(impaling) * 2.5 * waterBonus
        e.hurt(dmg, "projectile", owner)
        dealtDamage = true
        // channeling
        if let stack, enchLevel(stack, "channeling") > 0, world.thundering,
           world.canSeeSky(ifloor(e.x), ifloor(e.y), ifloor(e.z)) {
            spawnLightningFn?(world, e.x, e.y, e.z)
        }
        if loyalty > 0 {
            beginReturn()
        } else {
            // deflect and drop so it lands near the target for pickup
            vx *= -0.01; vy *= -0.1; vz *= -0.01
        }
    }
    public override func onHitBlock(_ hit: RaycastHit) {
        stuck = true
        vx = 0; vy = 0; vz = 0
        world.hooks.playSound("item.trident.hit_ground", x, y, z, 1, 1)
        if loyalty > 0 { beginReturn() }
    }
    private func beginReturn() {
        if loyalty > 0 {
            returning = true
            stuck = false
        }
    }
    public override func onStuckTick() {
        // pickup
        for e in world.getEntitiesNear(x, y, z, 1.4, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
            if (e as? LivingEntity)?.give(stack) == true {
                world.hooks.playSound("entity.item.pickup", x, y, z, 0.4, 1.2)
                remove()
                return
            }
        }
        if age > 2400 { remove() }
    }
}

public final class FireworkEntity: Entity {
    public override var type: String { "firework" }
    public var life = 0
    public var lifeTotal = 30
    public var attachedTo: Entity? = nil
    public var flightDuration = 1
    public override init(world: World) {
        super.init(world: world)
        width = 0.25; height = 0.25
        noGravity = true
    }
    public override func tick() {
        baseTick()
        // roll the fuse ONCE — re-rolling drained a gameRng draw per tick,
        // desyncing the shared deterministic stream for everything else
        if life == 0 { lifeTotal = 20 * (flightDuration + 1) + gameRng.nextInt(6) }
        if let e = attachedTo, !e.dead {
            // elytra boost
            let lookX = -detSin(e.yaw) * detCos(e.pitch)
            let lookY = -detSin(e.pitch)
            let lookZ = detCos(e.yaw) * detCos(e.pitch)
            e.vx += lookX * 0.1 + (lookX * 1.5 - e.vx) * 0.5
            e.vy += lookY * 0.1 + (lookY * 1.5 - e.vy) * 0.5
            e.vz += lookZ * 0.1 + (lookZ * 1.5 - e.vz) * 0.5
            setPos(e.x, e.y, e.z)
        } else {
            vy += 0.04
            move(vx, vy, vz)
        }
        if age % 2 == 0 { world.hooks.addParticles("flame", x, y - 0.3, z, 1, 0.05, 0) }
        life += 1
        if life > lifeTotal {
            world.hooks.playSound("entity.firework_rocket.blast", x, y, z, 2, 1)
            world.hooks.addParticles("totem", x, y, z, 30, 0.5, 0)
            // damage if boosted
            attachedTo?.hurt(0, "firework")
            remove()
        }
    }
}

public final class FishingBobber: Entity {
    public override var type: String { "fishing_bobber" }
    public var ownerPlayer: LivingEntity? = nil
    public var biteTime = 0
    public var nibbling = 0
    public var hookedEntity: Entity? = nil
    public override init(world: World) {
        super.init(world: world)
        width = 0.25; height = 0.25
    }
    public override func tick() {
        baseTick()
        guard let op = ownerPlayer, !op.dead else { remove(); return }
        let ddx = x - op.x, ddy = y - op.y, ddz = z - op.z
        let d = (ddx * ddx + ddy * ddy + ddz * ddz).squareRoot()
        if d > 32 { retrieve(); return }
        if let hooked = hookedEntity {
            if hooked.dead { hookedEntity = nil; return }
            setPos(hooked.x, hooked.y + hooked.height / 2, hooked.z)
            return
        }
        let inWaterNow = (world.getBlock(ifloor(x), ifloor(y), ifloor(z)) >> 4) == Int(B.water)
        if inWaterNow {
            vy *= 0.4
            vx *= 0.9; vz *= 0.9
            let surface = Double(ifloor(y)) + world.fluidHeight(ifloor(x), ifloor(y), ifloor(z))
            if y < surface - 0.1 { vy += 0.1 }
            // bite logic: nibble phase first (bobber bobs, not catchable),
            // then the bite window where retrieve() actually catches
            if nibbling > 0 {
                nibbling -= 1
                vy -= 0.02
                if nibbling == 0 {
                    biteTime = 20
                    vy -= 0.2
                    world.hooks.playSound("entity.fishing_bobber.splash", x, y, z, 0.9, 0.8)
                    world.hooks.addParticles("splash", x, y + 0.2, z, 12, 0.3, 0)
                }
            } else if biteTime > 0 {
                biteTime -= 1
            } else {
                let lure = op.mainHand.map { enchLevel($0, "lure") } ?? 0
                if gameRng.nextFloat() < 1 / Double(max(20, 400 - lure * 100)) {
                    nibbling = 20 + gameRng.nextInt(20)
                    world.hooks.playSound("entity.fishing_bobber.splash", x, y, z, 0.6, 1)
                    world.hooks.addParticles("splash", x, y + 0.2, z, 8, 0.25, 0)
                }
            }
        } else {
            vy -= 0.04
        }
        move(vx, vy, vz)
        vx *= 0.92; vy *= 0.92; vz *= 0.92
        // hook entities
        for e in world.getEntitiesInBox(bb(), except: self, filter: { e2 in
            e2 is LivingEntity && !(e2 === self.ownerPlayer)
        }) {
            hookedEntity = e as? Entity
            break
        }
    }
    /// returns loot if a fish was caught
    public func retrieve() {
        if let e = hookedEntity, let op = ownerPlayer {
            // yank entity toward player
            e.vx += (op.x - e.x) * 0.1
            e.vy += (op.y - e.y) * 0.1 + 0.3
            e.vz += (op.z - e.z) * 0.1
        } else if biteTime > 0, let op = ownerPlayer {
            // catch!
            let luck = op.mainHand.map { enchLevel($0, "luck_of_the_sea") } ?? 0
            var rng = RandomX(UInt32(gameRng.nextInt(1000000000)))
            let roll = rng.nextFloat()
            let table = roll < 0.85 - Double(luck) * 0.02 ? "fishing_fish"
                : roll < 0.95 - Double(luck) * 0.01 ? "fishing_junk" : "fishing_treasure"
            let loot = rollLoot(table, &rng, luck: Double(luck))
            for stack in loot {
                let item = spawnItem(world, x, y, z, stack)
                let dx = op.x - x, dy = op.y + 1 - y, dz = op.z - z
                var dd = (dx * dx + dy * dy + dz * dz).squareRoot()
                if dd == 0 { dd = 1 }
                item.vx = dx / dd * 0.35
                item.vy = dy / dd * 0.35 + dd.squareRoot() * 0.04 + 0.15
                item.vz = dz / dd * 0.35
            }
            spawnXP(world, op.x, op.y, op.z, 1 + gameRng.nextInt(6))
        }
        remove()
    }
}

public final class LlamaSpit: Projectile {
    public override var type: String { "llama_spit" }
    public override func onHitEntity(_ e: Entity) {
        e.hurt(1, "projectile", owner)
        remove()
    }
    public override func onHitBlock(_ hit: RaycastHit) { remove() }
}

public var spawnLightningFn: ((World, Double, Double, Double) -> Void)?
public func bindSpawnLightning(_ fn: ((World, Double, Double, Double) -> Void)?) { spawnLightningFn = fn }
