// Nether mobs — blazes, ghasts, magma cubes,
// piglins (with bartering), piglin brutes, zombified piglins, hoglins,
// zoglins, wither skeletons.

import Foundation

public final class Blaze: Monster {
    public override var type: String { "blaze" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.8
        maxHealth = 20; health = 20
        speed = 0.1
        gravityScale = 0.3
        xpReward = 10
        goals.add(RangedAttackGoal(self, 1, 60, 24, { [unowned self] t, _ in
            // 3-shot volley
            for i in 0..<3 {
                scheduleEntityTimeout(self.world, i * 6) { [weak self, weak t] in
                    guard let self, let t, !self.dead, !t.dead else { return }
                    let fb = Fireball(world: self.world)
                    fb.small = true
                    fb.width = 0.3
                    let dx = t.x - self.x, dy = t.eyeY() - (self.y + 1), dz = t.z - self.z
                    fb.setPos(self.x, self.y + 1, self.z)
                    fb.owner = self
                    fb.shoot(dx, dy + (dx * dx + dz * dz).squareRoot() * 0.04, dz, 1.1, 6)
                    self.world.addEntity(fb)
                    self.world.hooks.playSound("entity.blaze.shoot", self.x, self.y, self.z, 1, 1)
                }
            }
        }, false))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, isPlayerTarget, 48, false))
    }
    public override func tick() {
        super.tick()
        if dead || deathTime > 0 { return }
        if vy < 0 { vy *= 0.6 }
        if let t = target, t.y > y + 1, rng.nextFloat() < 0.1 { vy = 0.2 }
        if age % 8 == 0 { world.hooks.addParticles("smoke", x, y + 0.8, z, 1, 0.3, 0) }
        if inWater { hurt(1, "drown") }
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("blaze_rod", min: 0, max: 1, lootingBonus: 1)]
    }
}

// keyed by world identity — dims tick independent time counters, and a
// timeout scheduled in the nether must not fire against overworld time
private var pendingTimeouts: [(world: ObjectIdentifier, time: Int, fn: () -> Void)] = []
func scheduleEntityTimeout(_ world: World, _ delayTicks: Int, _ fn: @escaping () -> Void) {
    pendingTimeouts.append((world: ObjectIdentifier(world), time: world.time + delayTicks, fn: fn))
}
public func tickPendingTimeouts(_ world: World) {
    let wid = ObjectIdentifier(world)
    var fired: [() -> Void] = []
    pendingTimeouts.removeAll { t in
        guard t.world == wid && t.time <= world.time else { return false }
        fired.append(t.fn)
        return true
    }
    for fn in fired { fn() } // FIFO, deterministically setTimeout
}
/// drop everything on world exit — entries hold closures that would otherwise
/// keep dead worlds' entities alive (and could fire into a reloaded world)
public func clearEntityTimeouts() {
    pendingTimeouts.removeAll()
}

public final class Ghast: Monster {
    public override var type: String { "ghast" }
    public var shootCooldown = 0
    public override init(world: World) {
        super.init(world: world)
        width = 4; height = 4
        maxHealth = 10; health = 10
        noGravity = true
        xpReward = 5
        targetGoals.add(NearestTargetGoal(self, 1, isPlayerTarget, 64, false))
    }
    public override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        targetGoals.tick(2, age)
        // wander
        if age % 60 == 0 && rng.nextFloat() < 0.5 {
            vx = (rng.nextFloat() - 0.5) * 0.1
            vy = (rng.nextFloat() - 0.5) * 0.06
            vz = (rng.nextFloat() - 0.5) * 0.1
        }
        move(vx, vy, vz)
        if horizontalCollision {
            vx = (rng.nextFloat() - 0.5) * 0.1
            vz = (rng.nextFloat() - 0.5) * 0.1
        }
        // shoot fireballs
        if shootCooldown > 0 { shootCooldown -= 1 }
        if let t = target, !t.dead, shootCooldown <= 0 {
            let dSq = distanceToSq(t)
            if dSq < 64 * 64 && canSee(t) {
                shootCooldown = 60
                world.hooks.playSound("entity.ghast.warn", x, y, z, 4, 1)
                let fb = Fireball(world: world)
                fb.power = 1
                fb.setPos(x, y + 2, z)
                fb.owner = self
                fb.shoot(t.x - x, t.eyeY() - (y + 2), t.z - z, 0.8, 0)
                world.addEntity(fb)
                world.hooks.playSound("entity.ghast.shoot", x, y, z, 4, 1)
            }
        }
        if let t = target, !t.dead {
            lookX = t.x; lookY = t.y; lookZ = t.z
            yaw = detAtan2(-(t.x - x), t.z - z)
        }
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("ghast_tear", min: 0, max: 1, lootingBonus: 1), DropEntry("gunpowder", min: 0, max: 2)]
    }
}

public final class MagmaCube: Slime {
    public override var type: String { "magma_cube" }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if source == "fire" || source == "lava" { return false }
        return super.hurt(amount, source, attacker)
    }
    public override func drops() -> [DropEntry] {
        size > 1 ? [DropEntry("magma_cream", min: 0, max: 1, lootingBonus: 1)] : []
    }
}

public final class ZombifiedPiglin: Monster {
    public override var type: String { "zombified_piglin" }
    public var angerTime = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 20; health = 20
        speed = 0.1
        attackDamage = 8 // golden sword
        goals.add(FloatGoal(self, 0))
        goals.add(MeleeAttackGoal(self, 2, 1.2))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1, true))
    }
    public override func tick() {
        super.tick()
        if angerTime > 0 {
            angerTime -= 1
            if angerTime == 0 { setTarget(nil) }
        }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let r = super.hurt(amount, source, attacker)
        if r, let attacker, attacker.isPlayer {
            angerTime = 800
            // alert the pack!
            for e in world.getEntitiesNear(x, y, z, 32, filter: { ($0 as? Entity)?.type == "zombified_piglin" }) {
                guard let zp = e as? ZombifiedPiglin else { continue }
                zp.setTarget(attacker as? LivingEntity)
                zp.angerTime = 800
            }
        }
        return r
    }
    public override func drops() -> [DropEntry] {
        [
            DropEntry("rotten_flesh", min: 0, max: 1, lootingBonus: 1),
            DropEntry("gold_nugget", min: 0, max: 1, lootingBonus: 1),
            DropEntry("gold_ingot", chance: 0.025, lootingBonus: 0.01),
        ]
    }
}

open class Piglin: Monster {
    open override var type: String { "piglin" }
    public var admiring = 0
    public var admiredItem: ItemStack? = nil
    public var zombifyTime = 300
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 16; health = 16
        speed = 0.11
        attackDamage = 5
        goals.add(FloatGoal(self, 0))
        goals.add(AvoidEntityGoal(self, 1, { e in ["zombified_piglin", "zoglin"].contains(e.type) }, 8, 1.1))
        goals.add(MeleeAttackGoal(self, 2, 1.15))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1, true))
        targetGoals.add(NearestTargetGoal(self, 2, { e in
            // attacks players not wearing gold
            if !e.isPlayer || e.dead { return false }
            for a in e.armor {
                if let a, itemDef(a.id).name.contains("golden_") { return false }
            }
            return true
        }, 16))
        targetGoals.add(NearestTargetGoal(self, 3, { e in e.type == "wither_skeleton" }, 16))
    }
    open override func tick() {
        super.tick()
        // overworld zombification
        if world.dim == .overworld {
            zombifyTime -= 1
            if zombifyTime <= 0 {
                let z = spawnMobFn?(world, "zombified_piglin", x, y, z, SpawnOpts())
                if z != nil {
                    world.hooks.playSound("entity.zombified_piglin.angry", x, y, self.z, 1, 1)
                    remove()
                    return
                }
            }
        }
        // admire gold ingots thrown nearby (bartering)
        if admiring > 0 {
            admiring -= 1
            nav.stop()
            if admiring == 0 && admiredItem != nil {
                // barter!
                let loot = rollLoot("piglin_bartering", &rng)
                for s in loot {
                    spawnItem(world, x, y + 0.8, z, s,
                              -detSin(yaw) * 0.2, 0.2, detCos(yaw) * 0.2)
                }
                admiredItem = nil
            }
        } else if age % 10 == 0 && target == nil {
            for e in world.getEntitiesNear(x, y, z, 2, filter: { ($0 as? Entity)?.type == "item" }) {
                guard let item = e as? ItemEntity else { continue }
                if itemDef(item.stack.id).name == "gold_ingot" && item.pickupDelay <= 0 {
                    item.stack.count -= 1
                    if item.stack.count <= 0 { item.remove() }
                    admiring = 120
                    admiredItem = ItemStack(item.stack.id, 1)
                    world.hooks.playSound("entity.piglin.admiring_item", x, y, z, 1, 1)
                    break
                }
            }
        }
    }
    open override func drops() -> [DropEntry] { [] }
}
public final class PiglinBrute: Piglin {
    public override var type: String { "piglin_brute" }
    public override init(world: World) {
        super.init(world: world)
        maxHealth = 50; health = 50
        attackDamage = 13 // golden axe
        xpReward = 20
        // brutes fear nothing — drop the avoid goal inherited from Piglin
        goals.goals.removeAll { $0 is AvoidEntityGoal }
        // brutes attack regardless of gold — this priority-1 goal outranks
        // the inherited gold-check target goal
        targetGoals.add(NearestTargetGoal(self, 1, isPlayerTarget, 16))
    }
    public override func tick() {
        // no bartering, no fleeing — call Monster-level behavior
        mobTick()
        if world.dim == .overworld {
            zombifyTime -= 1
            if zombifyTime <= 0 {
                let z = spawnMobFn?(world, "zombified_piglin", x, y, z, SpawnOpts())
                if z != nil { remove() }
            }
        }
    }
    public override func drops() -> [DropEntry] { [DropEntry("golden_axe", chance: 0.085)] }
}

open class Hoglin: Monster {
    open override var type: String { "hoglin" }
    public var zombifyTime = 300
    public override init(world: World) {
        super.init(world: world)
        width = 1.4; height = 1.4
        maxHealth = 40; health = 40
        speed = 0.12
        attackDamage = 6
        xpReward = 5
        addMonsterGoals(1.2)
    }
    open override func tick() {
        super.tick()
        // flee warped fungus
        if age % 20 == 0 {
            var dx = -4
            while dx <= 4 {
                var dz = -4
                while dz <= 4 {
                    if (world.getBlock(ifloor(x) + dx, ifloor(y), ifloor(z) + dz) >> 4) == Int(B.warped_fungus) {
                        nav.moveTo(x - Double(dx) * 3, y, z - Double(dz) * 3, 1.3)
                    }
                    dz += 2
                }
                dx += 2
            }
        }
        if world.dim == .overworld {
            zombifyTime -= 1
            if zombifyTime <= 0 {
                let z = spawnMobFn?(world, "zoglin", x, y, z, SpawnOpts())
                if z != nil { remove() }
            }
        }
    }
    open override func doMeleeAttack(_ target: LivingEntity) {
        super.doMeleeAttack(target)
        target.vy += 0.5 // fling
    }
    open override func drops() -> [DropEntry] {
        [DropEntry(fireTicks > 0 ? "cooked_porkchop" : "porkchop", min: 2, max: 4, lootingBonus: 1), DropEntry("leather", min: 0, max: 1)]
    }
}
public final class Zoglin: Hoglin {
    public override var type: String { "zoglin" }
    public override init(world: World) {
        super.init(world: world)
        zombifyTime = Int.max   // baseline sets Infinity; the check never fires
        targetGoals.add(NearestTargetGoal(self, 1, { e in
            !["zoglin", "creeper", "ghast"].contains(e.type)
        }, 16))
    }
    public override func tick() {
        mobTick()
    }
    public override func drops() -> [DropEntry] { [DropEntry("rotten_flesh", min: 1, max: 3, lootingBonus: 1)] }
}

public final class WitherSkeletonMob: Monster {
    public override var type: String { "wither_skeleton" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.7; height = 2.4
        maxHealth = 20; health = 20
        speed = 0.12
        attackDamage = 8 // stone sword
        xpReward = 5
        addMonsterGoals(1.2)
    }
    public override func doMeleeAttack(_ target: LivingEntity) {
        super.doMeleeAttack(target)
        target.addEffect("wither", 200, 0)
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if source == "fire" || source == "lava" { return false }
        return super.hurt(amount, source, attacker)
    }
    public override func drops() -> [DropEntry] {
        [
            DropEntry("coal", min: 0, max: 1, lootingBonus: 1),
            DropEntry("bone", min: 0, max: 2, lootingBonus: 1),
            DropEntry("wither_skeleton_skull", chance: 0.025, lootingBonus: 0.01),
        ]
    }
}
