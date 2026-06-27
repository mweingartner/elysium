// Hostile mobs — undead, spiders, creepers,
// slimes, witches, endermen, phantoms, guardians, shulkers, silverfish, and
// the illager family.

import Foundation

let isPlayerTarget: (LivingEntity) -> Bool = { e in e.isPlayer && !e.dead }
let targetsVillagers: (LivingEntity) -> Bool = { e in
    e.isPlayer || e.type == "villager" || e.type == "wandering_trader" || e.type == "iron_golem"
}

func blockNameOf(_ id: Int) -> String {
    id >= 0 && id < blockDefs.count ? blockDefs[id].name : ""
}

open class Monster: Mob {
    public override init(world: World) {
        super.init(world: world)
        category = "monster"
        xpReward = 5
    }
    public func addMonsterGoals(_ speed: Double = 1.05) {
        goals.add(FloatGoal(self, 0))
        goals.add(MeleeAttackGoal(self, 2, speed))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        goals.add(RandomLookGoal(self, 8))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, isPlayerTarget, followRange))
    }
}

// ZOMBIES ----------------------------------------------------------------------
open class Zombie: Monster {
    open override var type: String { "zombie" }
    public var conversionTime = -1
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 20; health = 20
        speed = 0.095
        attackDamage = 3
        burnsInSun = true
        if gameRng.nextFloat() < 0.05 { baby = true }
        if baby { speed *= 1.5 }
        addMonsterGoals()
        targetGoals.add(NearestTargetGoal(self, 3, { e in
            e.type == "villager" || e.type == "iron_golem" || e.type == "snow_golem"
        }, 16))
    }
    open override func tick() {
        super.tick()
        // drowned conversion
        if type == "zombie" && underwater {
            if conversionTime < 0 { conversionTime = 600 }
            else {
                conversionTime -= 1
                if conversionTime <= 0 {
                    let d = spawnMobFn?(world, "drowned", x, y, z, SpawnOpts(baby: baby))
                    if d != nil { remove() }
                }
            }
        } else if type == "zombie" {
            conversionTime = -1
        }
    }
    open override func drops() -> [DropEntry] {
        [
            DropEntry("rotten_flesh", min: 0, max: 2, lootingBonus: 1),
            DropEntry("iron_ingot", chance: 0.025, lootingBonus: 0.01),
            DropEntry("carrot", chance: 0.025, lootingBonus: 0.01),
            DropEntry("potato", chance: 0.025, lootingBonus: 0.01),
        ]
    }
}
public final class Husk: Zombie {
    public override var type: String { "husk" }
    public override init(world: World) {
        super.init(world: world)
        burnsInSun = false
    }
    public override func doMeleeAttack(_ target: LivingEntity) {
        super.doMeleeAttack(target)
        target.addEffect("hunger", 140, 0)
    }
}
public final class Drowned: Zombie {
    public override var type: String { "drowned" }
    public var hasTrident = false
    public override init(world: World) {
        super.init(world: world)
        hasTrident = gameRng.nextFloat() < 0.15   // baseline field-init order
        breathesWater = true
        burnsInSun = true
        if hasTrident {
            goals.add(RangedAttackGoal(self, 1, 40, 10, { [unowned self] t, _ in
                throwTridentFn?(self, t)
            }))
        }
        goals.add(RandomSwimGoal(self, 5, 1, 30))
    }
    public override func drops() -> [DropEntry] {
        var d = [DropEntry("rotten_flesh", min: 0, max: 2, lootingBonus: 1)]
        d.append(DropEntry("copper_ingot", chance: 0.11, lootingBonus: 0.02))
        if hasTrident { d.append(DropEntry("trident", chance: 0.085)) }
        return d
    }
}
public final class ZombieVillagerMob: Zombie {
    public override var type: String { "zombie_villager" }
    public var curing = -1
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        // cure with golden apple while weak
        if let stack, itemDef(stack.id).name == "golden_apple", hasEffect("weakness") {
            (player as? LivingEntity)?.consumeHeld(1)
            curing = 2000 + gameRng.nextInt(2000)
            addEffect("strength", curing, 0)
            world.hooks.playSound("entity.zombie_villager.cure", x, y, z, 1, 1)
            return true
        }
        return false
    }
    public override func tick() {
        super.tick()
        if curing > 0 {
            curing -= 1
            if curing == 0 {
                let v = spawnMobFn?(world, "villager", x, y, z, SpawnOpts())
                if v != nil { remove() }
            }
        }
    }
}

// SKELETONS --------------------------------------------------------------------
open class Skeleton: Monster {
    open override var type: String { "skeleton" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.99
        maxHealth = 20; health = 20
        speed = 0.1
        burnsInSun = true
        goals.add(FloatGoal(self, 0))
        goals.add(RangedAttackGoal(self, 2, 30, 15, { [unowned self] t, power in
            shootArrowFn?(self, t, power, 2 + Double(self.world.difficulty))
        }))
        goals.add(AvoidEntityGoal(self, 3, { e in e.type == "wolf" }, 6, 1.2))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        goals.add(RandomLookGoal(self, 8))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, isPlayerTarget, 16))
        targetGoals.add(NearestTargetGoal(self, 3, { e in e.type == "iron_golem" }, 16))
    }
    open override func drops() -> [DropEntry] {
        [
            DropEntry("arrow", min: 0, max: 2, lootingBonus: 1),
            DropEntry("bone", min: 0, max: 2, lootingBonus: 1),
        ]
    }
}
public final class Stray: Skeleton {
    public override var type: String { "stray" }
    public override func drops() -> [DropEntry] {
        var d = super.drops()
        d.append(DropEntry("tipped_arrow", chance: 0.5))
        return d
    }
}

// CREEPER ------------------------------------------------------------------------
public final class Creeper: Monster {
    public override var type: String { "creeper" }
    public var swellTicks = 0
    public var charged = false
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.7
        maxHealth = 20; health = 20
        speed = 0.1
        goals.add(FloatGoal(self, 0))
        goals.add(SwellGoal(self, 1))
        goals.add(MeleeAttackGoal(self, 2, 1.0))
        goals.add(AvoidEntityGoal(self, 3, { e in e.type == "cat" || e.type == "ocelot" }, 6, 1.3))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        goals.add(RandomLookGoal(self, 8))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, isPlayerTarget, 16))
    }
    public override func doMeleeAttack(_ target: LivingEntity) {} // creepers don't melee
    public override func tick() {
        super.tick()
        if swellTicks > 0 {
            data.swelling = Double(swellTicks) / 30
            if swellTicks == 1 { world.hooks.playSound("entity.creeper.primed", x, y, z, 1, 0.6) }
            swellTicks += 1
            if swellTicks > 30 {
                remove()
                explodeFn?(world, x, y + 0.5, z, charged ? 6 : 3, false, self)
            }
        } else {
            data.swelling = 0
        }
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("gunpowder", min: 0, max: 2, lootingBonus: 1)]
    }
}
final class SwellGoal: Goal {
    override func canUse() -> Bool {
        guard let c = mob as? Creeper, let t = c.target else { return false }
        return !t.dead && c.distanceToSq(t) < 9
    }
    override func tick() {
        guard let c = mob as? Creeper else { return }
        if let t = c.target, c.distanceToSq(t) < 9, c.canSee(t) {
            if c.swellTicks == 0 { c.swellTicks = 1 }
            c.nav.stop()
        } else {
            c.swellTicks = 0
        }
    }
    override func stop() { (mob as? Creeper)?.swellTicks = 0 }
}

// SPIDERS -----------------------------------------------------------------------
open class Spider: Monster {
    open override var type: String { "spider" }
    public override init(world: World) {
        super.init(world: world)
        width = 1.4; height = 0.9
        maxHealth = 16; health = 16
        speed = 0.13
        attackDamage = 2
        addMonsterGoals(1.1)
    }
    open override func tick() {
        super.tick()
        // wall climbing
        if horizontalCollision { vy = 0.2 }
    }
    public func canTargetInLight() -> Bool {
        // spiders neutral in daylight
        world.lightAt(ifloor(x), ifloor(y), ifloor(z)) <= 7
    }
    open override func drops() -> [DropEntry] {
        [
            DropEntry("string", min: 0, max: 2, lootingBonus: 1),
            DropEntry("spider_eye", chance: 0.33, lootingBonus: 0.05),
        ]
    }
}
public final class CaveSpider: Spider {
    public override var type: String { "cave_spider" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.7; height = 0.5
        maxHealth = 12; health = 12
    }
    public override func doMeleeAttack(_ target: LivingEntity) {
        super.doMeleeAttack(target)
        target.addEffect("poison", world.difficulty >= 2 ? 140 : 70, 0)
    }
}

// SLIME --------------------------------------------------------------------------
open class Slime: Monster {
    open override var type: String { "slime" }
    public var size = 2
    public var jumpDelay = 0
    public override init(world: World) {
        super.init(world: world)
        setSize([1, 2, 4][gameRng.nextInt(3)])
        targetGoals.add(NearestTargetGoal(self, 1, isPlayerTarget, 16))
        targetGoals.add(HurtByTargetGoal(self, 2))
    }
    public func setSize(_ s: Int) {
        size = s
        width = 0.51 * Double(s)
        height = 0.51 * Double(s)
        maxHealth = Double(s * s); health = Double(s * s)
        attackDamage = Double(s)
        xpReward = s
    }
    open override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        targetGoals.tick(2, age)
        // hop toward target
        if onGround {
            jumpDelay -= 1
            if jumpDelay <= 0 {
                jumpDelay = 10 + rng.nextInt(40)
                if let t = target, !t.dead {
                    jumpDelay = 6
                    let dx = t.x - x, dz = t.z - z
                    var d = (dx * dx + dz * dz).squareRoot()
                    if d == 0 { d = 1 }
                    vx = dx / d * 0.25
                    vz = dz / d * 0.25
                } else {
                    let ang = rng.nextFloat() * .pi * 2
                    vx = detSin(ang) * 0.18
                    vz = detCos(ang) * 0.18
                }
                vy = 0.42
                world.hooks.playSound("entity.slime.jump", x, y, z, 0.6, 0.8 + rng.nextFloat() * 0.4)
            } else {
                vx *= 0.5; vz *= 0.5
            }
        }
        move(vx, vy, vz)
        vy -= 0.08
        vy *= 0.98
        // damage on touch
        if let t = target, !t.dead, distanceToSq(t) < (width * 0.8) * (width * 0.8) + 1, age % 20 == 0 {
            t.hurt(attackDamage, "mob", self)
        }
    }
    open override func die(_ source: String, _ attacker: Entity? = nil) {
        super.die(source, attacker)
        if size > 1 {
            // baseline: `for (let i = 0; i < 2 + this.rng.nextInt(2); i++)` — the
            // bound REROLLS on every condition check; each check consumes rng
            var i = 0
            while i < 2 + rng.nextInt(2) {
                _ = spawnMobFn?(world, type, x + (rng.nextFloat() - 0.5), y + 0.5, z + (rng.nextFloat() - 0.5), SpawnOpts(size: size / 2))
                i += 1
            }
        }
    }
    open override func drops() -> [DropEntry] {
        size == 1 ? [DropEntry("slime_ball", min: 0, max: 2, lootingBonus: 1)] : []
    }
    open override func load(_ d: [String: Any]) {
        super.load(d)
        if let dd = d["data"] as? [String: Any], let s = (dd["size"] as? NSNumber)?.intValue, s != 0 {
            setSize(s)
        }
    }
}

// WITCH --------------------------------------------------------------------------
public final class Witch: Monster {
    public override var type: String { "witch" }
    public var drinkTime = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 26; health = 26
        speed = 0.1
        goals.add(FloatGoal(self, 0))
        goals.add(RangedAttackGoal(self, 2, 50, 10, { [unowned self] t, _ in
            let pot = ThrownPotion(world: self.world)
            let dy = t.y + t.height * 0.5 - (self.y + 1.4)
            pot.potionId = t.hasEffect("slowness") ? "harming" : (self.distanceToSq(t) > 64 ? "slowness" : "poison")
            let horiz = ((t.x - self.x) * (t.x - self.x) + (t.z - self.z) * (t.z - self.z)).squareRoot()
            pot.shootFrom(self, -detAtan2(dy + 0.3, horiz), detAtan2(-(t.x - self.x), t.z - self.z), 0.75, 8)
            pot.gravity = 0.05
            self.world.addEntity(pot)
            self.world.hooks.playSound("entity.witch.throw", self.x, self.y, self.z, 1, 1)
        }))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, isPlayerTarget, 16))
    }
    public override func tick() {
        super.tick()
        // drink potions defensively
        if drinkTime > 0 { drinkTime -= 1 }
        else {
            if fireTicks > 0 && !hasEffect("fire_resistance") {
                addEffect("fire_resistance", 400, 0)
                drinkTime = 40
            } else if health < maxHealth * 0.75 && rng.nextFloat() < 0.05 {
                heal(6)
                drinkTime = 40
                world.hooks.playSound("entity.witch.drink", x, y, z, 1, 1)
            }
        }
    }
    public override func drops() -> [DropEntry] {
        [
            DropEntry("glass_bottle", min: 0, max: 2, lootingBonus: 1),
            DropEntry("glowstone_dust", min: 0, max: 2, lootingBonus: 1),
            DropEntry("gunpowder", min: 0, max: 2, lootingBonus: 1),
            DropEntry("redstone", min: 0, max: 2, lootingBonus: 1),
            DropEntry("spider_eye", min: 0, max: 2, chance: 0.5),
            DropEntry("sugar", min: 0, max: 2, chance: 0.5),
            DropEntry("stick", min: 0, max: 2, chance: 0.5),
        ]
    }
}

// ENDERMAN ------------------------------------------------------------------------
public final class Enderman: Monster {
    public override var type: String { "enderman" }
    public var carrying = 0 // block cell
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 2.9
        maxHealth = 40; health = 40
        speed = 0.15
        attackDamage = 7
        goals.add(FloatGoal(self, 0))
        goals.add(MeleeAttackGoal(self, 2, 1.2))
        goals.add(StrollGoal(self, 7, 0.8))
        goals.add(LookAtPlayerGoal(self, 8))
        targetGoals.add(HurtByTargetGoal(self, 1))
    }
    public override func tick() {
        super.tick()
        // stare aggro
        if target == nil && age % 10 == 0 {
            for e in world.getEntitiesNear(x, y, z, 32, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                guard let p = e as? LivingEntity else { continue }
                if p.gameMode == 1 { continue }
                if p.wearingPumpkin { continue }
                // is the player looking at my head?
                let dx = x - p.x, dy = (y + 2.55) - p.eyeY(), dz = z - p.z
                let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
                let lookX = -detSin(p.yaw) * detCos(p.pitch)
                let lookY = -detSin(p.pitch)
                let lookZ = detCos(p.yaw) * detCos(p.pitch)
                let dot = (dx / dist) * lookX + (dy / dist) * lookY + (dz / dist) * lookZ
                if dot > 0.99 && p.canSee(self) {
                    setTarget(p)
                    world.hooks.playSound("entity.enderman.stare", p.x, p.y, p.z, 1, 1)
                }
            }
        }
        // water hurts
        if inWater || (world.rainLevel > 0.5 && world.canSeeSky(ifloor(x), ifloor(y), ifloor(z))) {
            hurt(1, "drown")
            teleportRandomly()
        }
        // teleport when hurt by projectile or to chase
        if let t = target, age % 30 == 0, distanceToSq(t) > 256 {
            teleportNear(t)
        }
        // pick up / place blocks rarely
        if world.rule("mobGriefing") && rng.nextFloat() < 0.002 {
            if carrying == 0 {
                let bx = ifloor(x) + rng.nextInt(5) - 2
                let by = ifloor(y) + rng.nextInt(3)
                let bz = ifloor(z) + rng.nextInt(5) - 2
                let c = world.getBlock(bx, by, bz)
                let bid = c >> 4
                let name = blockNameOf(bid)
                if ["grass_block", "dirt", "sand", "gravel", "pumpkin", "melon", "cactus", "clay", "mycelium", "podzol", "red_mushroom", "brown_mushroom", "tnt"].contains(name) {
                    carrying = c
                    world.setBlock(bx, by, bz, 0)
                }
            } else {
                let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
                if world.getBlock(bx, by, bz) == 0 && (world.getBlock(bx, by - 1, bz) >> 4) != 0 {
                    world.setBlock(bx, by, bz, carrying)
                    carrying = 0
                }
            }
        }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if source == "projectile" {
            teleportRandomly()
            if let living = attacker as? LivingEntity { setTarget(living) }
            return false
        }
        return super.hurt(amount, source, attacker)
    }
    public func teleportRandomly() {
        for _ in 0..<16 {
            let tx = x + (rng.nextFloat() - 0.5) * 32
            let tz = z + (rng.nextFloat() - 0.5) * 32
            let ty = world.surfaceY(ifloor(tx), ifloor(tz))
            if ty > world.info.minY + 1 {
                world.hooks.addParticles("portal", x, y + 1, z, 16, 0.5, 0)
                setPos(tx, Double(ty), tz)
                world.hooks.playSound("entity.enderman.teleport", tx, Double(ty), tz, 1, 1)
                return
            }
        }
    }
    public func teleportNear(_ t: Entity) {
        let tx = t.x + (rng.nextFloat() - 0.5) * 8
        let tz = t.z + (rng.nextFloat() - 0.5) * 8
        let ty = world.surfaceY(ifloor(tx), ifloor(tz))
        world.hooks.addParticles("portal", x, y + 1, z, 16, 0.5, 0)
        setPos(tx, Double(ty), tz)
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("ender_pearl", min: 0, max: 1, lootingBonus: 1)]
    }
}

// SILVERFISH / ENDERMITE -------------------------------------------------------------
public final class Silverfish: Monster {
    public override var type: String { "silverfish" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.4; height = 0.3
        maxHealth = 8; health = 8
        speed = 0.13
        attackDamage = 1
        addMonsterGoals(1.2)
    }
    public override func drops() -> [DropEntry] { [] }
}
public final class Endermite: Monster {
    public override var type: String { "endermite" }
    public var lifeTicks = 2400
    public override init(world: World) {
        super.init(world: world)
        width = 0.4; height = 0.3
        maxHealth = 8; health = 8
        speed = 0.13
        attackDamage = 2
        addMonsterGoals(1.2)
    }
    public override func tick() {
        super.tick()
        lifeTicks -= 1
        if lifeTicks <= 0 { remove() }
    }
    public override func drops() -> [DropEntry] { [] }
}

// PHANTOM -----------------------------------------------------------------------------
public final class Phantom: Monster {
    public override var type: String { "phantom" }
    public var circleX = 0.0, circleY = 0.0, circleZ = 0.0
    public var attackPhase = "circle"   // circle | swoop
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 0.5
        maxHealth = 20; health = 20
        attackDamage = 6
        noGravity = true
        burnsInSun = true
        targetGoals.add(NearestTargetGoal(self, 1, isPlayerTarget, 64, false))
    }
    public override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        tickSunlightBurning()
        targetGoals.tick(2, age)
        if circleX == 0 && circleY == 0 {
            circleX = x; circleY = y + 10; circleZ = z
        }
        if let t = target, !t.dead {
            if attackPhase == "circle" {
                circleX = t.x
                circleY = t.y + 12
                circleZ = t.z
                let ang = Double(age) * 0.06
                let tx = circleX + detCos(ang) * 12
                let tz = circleZ + detSin(ang) * 12
                flyToward(tx, circleY, tz, 0.12)
                if age % 100 == 0 && rng.nextFloat() < 0.4 {
                    attackPhase = "swoop"
                    world.hooks.playSound("entity.phantom.swoop", x, y, z, 2, 1)
                }
            } else {
                flyToward(t.x, t.y + 1, t.z, 0.25)
                if distanceToSq(t) < 3 {
                    doMeleeAttack(t)
                    attackPhase = "circle"
                }
                if y < t.y - 2 || hurtTime > 0 { attackPhase = "circle" }
            }
        } else {
            let ang = Double(age) * 0.04
            flyToward(circleX + detCos(ang) * 14, circleY, circleZ + detSin(ang) * 14, 0.1)
        }
        move(vx, vy, vz)
        yaw = detAtan2(-vx, vz)
    }
    private func flyToward(_ tx: Double, _ ty: Double, _ tz: Double, _ speed: Double) {
        let dx = tx - x, dy = ty - y, dz = tz - z
        var d = (dx * dx + dy * dy + dz * dz).squareRoot()
        if d == 0 { d = 1 }
        vx += (dx / d * speed - vx) * 0.1
        vy += (dy / d * speed - vy) * 0.1
        vz += (dz / d * speed - vz) * 0.1
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("phantom_membrane", min: 0, max: 1, lootingBonus: 1)]
    }
}

// GUARDIANS -----------------------------------------------------------------------------
open class Guardian: Monster {
    open override var type: String { "guardian" }
    public var laserTarget: LivingEntity?
    public var laserTime = 0
    public override init(world: World) {
        super.init(world: world)
        breathesWater = true
        breathesWaterOnly = true
        width = 0.85; height = 0.85
        maxHealth = 30; health = 30
        attackDamage = 6
        speed = 0.1
        goals.add(RandomSwimGoal(self, 5, 1, 20))
        targetGoals.add(NearestTargetGoal(self, 1, { e in
            isPlayerTarget(e) || e.type == "squid" || e.type == "axolotl"
        }, 16))
    }
    open override func tick() {
        super.tick()
        if let t = target, !t.dead, canSee(t), inWater {
            if laserTarget == nil {
                laserTarget = t
                laserTime = 0
                world.hooks.playSound("entity.guardian.attack", x, y, z, 1, 1)
            }
            laserTime += 1
            lookX = t.x; lookY = t.eyeY(); lookZ = t.z
            if laserTime % 10 == 0 {
                // beam particles
                let steps = 8
                for i in 1..<steps {
                    let f = Double(i) / Double(steps)
                    world.hooks.addParticles("bubble",
                                             x + (t.x - x) * f,
                                             y + 0.5 + (t.eyeY() - y - 0.5) * f,
                                             z + (t.z - z) * f, 1, 0.05, 0)
                }
            }
            if laserTime >= (type == "elder_guardian" ? 60 : 80) {
                t.hurt(type == "elder_guardian" ? 8 : 6, "magic", self)
                laserTarget = nil
                laserTime = 0
            }
        } else {
            laserTarget = nil
            laserTime = 0
        }
    }
    @discardableResult
    open override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        // thorns
        if source == "mob", let attacker, rng.nextFloat() < 0.5 {
            attacker.hurt(2, "thorns", self)
        }
        return super.hurt(amount, source, attacker)
    }
    open override func drops() -> [DropEntry] {
        [
            DropEntry("prismarine_shard", min: 0, max: 2, lootingBonus: 1),
            DropEntry("cod", chance: 0.4, lootingBonus: 0.02),
            DropEntry("prismarine_crystals", chance: 0.4, lootingBonus: 0.05),
        ]
    }
}
public final class ElderGuardian: Guardian {
    public override var type: String { "elder_guardian" }
    public override init(world: World) {
        super.init(world: world)
        width = 2; height = 2
        maxHealth = 80; health = 80
        attackDamage = 8
        persistent = true
        xpReward = 10
    }
    public override func tick() {
        super.tick()
        // mining fatigue aura
        if age % 1200 == 0 {
            for p in world.getEntitiesNear(x, y, z, 50, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                guard let pl = p as? LivingEntity else { continue }
                pl.addEffect("mining_fatigue", 6000, 2)
                world.hooks.playSound("entity.elder_guardian.curse", pl.x, pl.y, pl.z, 1, 1)
            }
        }
    }
    public override func drops() -> [DropEntry] {
        var d = super.drops()
        d.append(DropEntry("wet_sponge"))
        d.append(DropEntry("tide_armor_trim", chance: 0.2))
        return d
    }
}

// SHULKER --------------------------------------------------------------------------------
public final class Shulker: Monster {
    public override var type: String { "shulker" }
    public var peekAmount = 0.0
    public override init(world: World) {
        super.init(world: world)
        width = 1; height = 1
        maxHealth = 30; health = 30
        speed = 0
        kbResist = 1
        noGravity = true
        targetGoals.add(NearestTargetGoal(self, 1, isPlayerTarget, 16))
    }
    public override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        targetGoals.tick(2, age)
        vx = 0; vy = 0; vz = 0
        if let t = target, !t.dead, canSee(t) {
            data.open = 0.7
            if age % 40 == 0 {
                let bullet = ShulkerBullet(world: world)
                bullet.setPos(x, y + 0.5, z)
                bullet.owner = self
                bullet.targetId = t.id
                bullet.vx = 0.1
                world.addEntity(bullet)
                world.hooks.playSound("entity.shulker.shoot", x, y, z, 1, 1)
            }
        } else {
            data.open = rng.nextFloat() < 0.05 ? 0.3 : 0
        }
    }
    @discardableResult
    public override func hurt(_ amountIn: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        var amount = amountIn
        if (data.open ?? 0) < 0.1 && source != "magic" { amount *= 0.3 } // closed armor
        let r = super.hurt(amount, source, attacker)
        if r && health < maxHealth / 2 && rng.nextFloat() < 0.25 {
            // teleport to nearby surface
            for _ in 0..<8 {
                let tx = ifloor(x) + rng.nextInt(17) - 8
                let tz = ifloor(z) + rng.nextInt(17) - 8
                let ty = world.surfaceY(tx, tz)
                if ty > world.info.minY {
                    setPos(Double(tx) + 0.5, Double(ty), Double(tz) + 0.5)
                    world.hooks.playSound("entity.shulker.teleport", Double(tx), Double(ty), Double(tz), 1, 1)
                    break
                }
            }
        }
        return r
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("shulker_shell", chance: 0.5, lootingBonus: 0.0625)]
    }
}

// ILLAGERS --------------------------------------------------------------------------------
public final class Pillager: Monster {
    public override var type: String { "pillager" }
    public var isCaptain = false
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 24; health = 24
        speed = 0.11
        data.crossed = true
        goals.add(FloatGoal(self, 0))
        goals.add(RangedAttackGoal(self, 2, 40, 10, { [unowned self] t, power in
            shootArrowFn?(self, t, power * 1.1, 4)
            self.world.hooks.playSound("item.crossbow.shoot", self.x, self.y, self.z, 1, 1)
        }, false))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, targetsVillagers, 24))
    }
    public override func drops() -> [DropEntry] {
        var d = [DropEntry("arrow", min: 0, max: 2), DropEntry("crossbow", chance: 0.085)]
        if isCaptain { d.append(DropEntry("emerald", min: 1, max: 3)) }
        return d
    }
    public override func die(_ source: String, _ attacker: Entity? = nil) {
        super.die(source, attacker)
        if isCaptain, let attacker, attacker.isPlayer {
            (attacker as? LivingEntity)?.addEffect("bad_omen", 120000, 0)
        }
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["captain"] = isCaptain
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        if let c = d["captain"] as? Bool {
            isCaptain = c
        } else if let dd = d["data"] as? [String: Any], let c = dd["captain"] as? Bool {
            isCaptain = c
        } else {
            isCaptain = false
        }
    }
}

public final class Vindicator: Monster {
    public override var type: String { "vindicator" }
    public var isCaptain = false
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 24; health = 24
        speed = 0.115
        attackDamage = 8 // wields axe (built into damage)
        addMonsterGoals(1.15)
        targetGoals.add(NearestTargetGoal(self, 3, targetsVillagers, 24))
    }
    public override func drops() -> [DropEntry] {
        var d = [DropEntry("emerald", min: 0, max: 1, lootingBonus: 1), DropEntry("iron_axe", chance: 0.085)]
        if isCaptain { d.append(DropEntry("emerald", min: 1, max: 3)) }
        return d
    }
    public override func die(_ source: String, _ attacker: Entity? = nil) {
        super.die(source, attacker)
        if isCaptain, let attacker, attacker.isPlayer {
            (attacker as? LivingEntity)?.addEffect("bad_omen", 120000, 0)
        }
    }
}

public final class Evoker: Monster {
    public override var type: String { "evoker" }
    public var castCooldown = 100
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 1.95
        maxHealth = 24; health = 24
        speed = 0.12
        goals.add(FloatGoal(self, 0))
        goals.add(AvoidEntityGoal(self, 1, { [unowned self] e in
            guard let t = self.target else { return false }
            return e === t && self.distanceToSq(t) < 36
        }, 7, 1.1))
        goals.add(StrollGoal(self, 6, 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, targetsVillagers, 24))
    }
    public override func tick() {
        super.tick()
        if let t = target, !t.dead {
            castCooldown -= 1
            if castCooldown <= 0 {
                let which = rng.nextFloat()
                if which < 0.6 {
                    // evoker fangs line
                    castCooldown = 100
                    world.hooks.playSound("entity.evoker.cast_spell", x, y, z, 1, 1)
                    let dx = t.x - x, dz = t.z - z
                    var d = (dx * dx + dz * dz).squareRoot()
                    if d == 0 { d = 1 }
                    for i in 1...16 {
                        let fx = x + dx / d * Double(i)
                        let fz = z + dz / d * Double(i)
                        spawnFangsFn?(world, fx, y, fz, i * 2, self)
                    }
                } else {
                    // summon vexes
                    castCooldown = 340
                    world.hooks.playSound("entity.evoker.prepare_summon", x, y, z, 1, 1)
                    for _ in 0..<3 {
                        let vex = spawnMobFn?(world, "vex", x + rng.nextFloat() * 2 - 1, y + 1, z + rng.nextFloat() * 2 - 1, SpawnOpts())
                        (vex as? Mob)?.setTarget(target)
                    }
                }
            }
        }
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("totem_of_undying"), DropEntry("emerald", min: 0, max: 1, lootingBonus: 1)]
    }
}
public var spawnFangsFn: ((World, Double, Double, Double, Int, Entity) -> Void)?
public func bindFangs(_ fn: ((World, Double, Double, Double, Int, Entity) -> Void)?) { spawnFangsFn = fn }

public final class Vex: Monster {
    public override var type: String { "vex" }
    public var lifeTicks = 0
    public override init(world: World) {
        super.init(world: world)
        lifeTicks = 600 + gameRng.nextInt(600)   // baseline field-init order
        width = 0.4; height = 0.8
        maxHealth = 14; health = 14
        attackDamage = 9
        noGravity = true
        noClip = true
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, isPlayerTarget, 16))
    }
    public override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        targetGoals.tick(2, age)
        lifeTicks -= 1
        if lifeTicks <= 0 { hurt(1, "magic") }
        if let t = target, !t.dead {
            let dx = t.x - x, dy = t.eyeY() - 0.5 - y, dz = t.z - z
            var d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d == 0 { d = 1 }
            vx += (dx / d * 0.18 - vx) * 0.12
            vy += (dy / d * 0.18 - vy) * 0.12
            vz += (dz / d * 0.18 - vz) * 0.12
            yaw = detAtan2(-dx, dz)
            if d < 1.2 && age % 20 == 0 { doMeleeAttack(t) }
        } else {
            vx *= 0.9; vy *= 0.9; vz *= 0.9
        }
        x += vx; y += vy; z += vz
    }
    public override func drops() -> [DropEntry] { [] }
}

public final class Ravager: Monster {
    public override var type: String { "ravager" }
    public var roarCooldown = 0
    public override init(world: World) {
        super.init(world: world)
        width = 1.95; height = 2.2
        maxHealth = 100; health = 100
        speed = 0.12
        attackDamage = 12
        kbResist = 0.75
        stepHeight = 1
        xpReward = 20
        addMonsterGoals(1.1)
        targetGoals.add(NearestTargetGoal(self, 3, targetsVillagers, 32))
    }
    public override func tick() {
        super.tick()
        // trample crops/leaves
        if world.rule("mobGriefing") && age % 5 == 0 {
            let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
            for (dx, dz) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                let c = world.getBlock(bx + dx, by, bz + dz)
                let name = blockNameOf(c >> 4)
                if ["leaves", "wheat", "carrot", "potato", "beetroot"].contains(where: { name.contains($0) }) {
                    world.breakBlockNaturally(bx + dx, by, bz + dz)
                }
            }
        }
        if roarCooldown > 0 { roarCooldown -= 1 }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let r = super.hurt(amount, source, attacker)
        if r && rng.nextFloat() < 0.15 && roarCooldown <= 0 {
            // roar: knockback all nearby
            roarCooldown = 100
            world.hooks.playSound("entity.ravager.roar", x, y, z, 2, 1)
            for e in world.getEntitiesNear(x, y, z, 5) {
                guard let ent = e as? Entity, ent !== self else { continue }
                let dx = ent.x - x, dz = ent.z - z
                var d = (dx * dx + dz * dz).squareRoot()
                if d == 0 { d = 1 }
                ent.vx += dx / d * 0.8
                ent.vy += 0.4
                ent.vz += dz / d * 0.8
            }
        }
        return r
    }
    public override func drops() -> [DropEntry] { [DropEntry("saddle")] }
}

// late-bound combat helpers
public var shootArrowFn: ((Mob, LivingEntity, Double, Double) -> Void)?
public func bindShootArrow(_ fn: ((Mob, LivingEntity, Double, Double) -> Void)?) { shootArrowFn = fn }
public var throwTridentFn: ((Mob, LivingEntity) -> Void)?
public func bindThrowTrident(_ fn: ((Mob, LivingEntity) -> Void)?) { throwTridentFn = fn }
