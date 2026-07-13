// Passive & tameable mobs — farm animals, pets,
// water creatures, and ambient mobs. (Villagers/golems/horses live in
// Villagers.swift, mirroring the baseline file split.)
//
// constructor randomness (variants, colors, egg timers) is deliberately
// nondeterministic; golden tests override those fields after spawning.

import Foundation

func heldStack(_ player: Entity?) -> ItemStack? { (player as? LivingEntity)?.mainHand }
func heldName(_ player: Entity?) -> String? {
    guard let h = heldStack(player) else { return nil }
    return itemDef(h.id).name
}

open class Animal: Mob {
    public var foods: [String] = []

    public override init(world: World) {
        super.init(world: world)
        category = "creature"
    }

    open override func isFood(_ stack: ItemStack?) -> Bool {
        guard let stack else { return false }
        return foods.contains(itemDef(stack.id).name)
    }

    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if let stack, isFood(stack) {
            if tryFeed(player, stack) {
                (player as? LivingEntity)?.consumeHeld(1)
                world.hooks.playSound("entity.generic.eat", x, y, z, 1, 1)
                return true
            }
        }
        return false
    }

    public func addBasicGoals(_ speed: Double = 1, _ panicSpeed: Double = 1.4) {
        goals.add(FloatGoal(self, 0))
        goals.add(PanicGoal(self, 1, panicSpeed))
        goals.add(BreedGoal(self, 2) { [unowned self] a, b in self.spawnBaby(a, b) })
        if !foods.isEmpty { goals.add(TemptGoal(self, 3, foods, 1.1)) }
        goals.add(FollowParentGoal(self, 4))
        goals.add(StrollGoal(self, 6, speed * 0.8))
        goals.add(LookAtPlayerGoal(self, 7))
        goals.add(RandomLookGoal(self, 8))
    }

    open func spawnBaby(_ a: Mob, _ b: Mob) {
        let baby = spawnMobFn?(world, type, a.x, a.y, a.z, SpawnOpts(baby: true))
        if baby != nil {
            spawnXP(world, a.x, a.y, a.z, 1 + gameRng.nextInt(7))
        }
    }
}

// ---------------------------------------------------------------------------
open class Cow: Animal {
    open override var type: String { "cow" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 1.4
        maxHealth = 10; health = 10
        speed = 0.08
        foods = ["wheat"]
        xpReward = 3
        addBasicGoals()
    }
    open override func drops() -> [DropEntry] {
        [
            DropEntry("leather", min: 0, max: 2, lootingBonus: 1),
            DropEntry(fireTicks > 0 ? "cooked_beef" : "beef", min: 1, max: 3, lootingBonus: 1),
        ]
    }
    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if let stack, itemDef(stack.id).name == "bucket", !baby {
            (player as? LivingEntity)?.replaceHeld(ItemStack(iid("milk_bucket"), 1))
            world.hooks.playSound("entity.cow.milk", x, y, z, 1, 1)
            return true
        }
        return super.interact(player, stack)
    }
}

public final class Mooshroom: Cow {
    public override var type: String { "mooshroom" }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if name == "bowl" && !baby {
            (player as? LivingEntity)?.replaceHeld(ItemStack(iid("mushroom_stew"), 1))
            world.hooks.playSound("entity.mooshroom.milk", x, y, z, 1, 1)
            return true
        }
        if name == "shears" && !baby {
            // shear into cow
            let cow = spawnMobFn?(world, "cow", x, y, z, SpawnOpts())
            if cow != nil {
                remove()
                for _ in 0..<5 { spawnItem(world, x, y + 1, z, ItemStack(iid("red_mushroom"), 1)) }
                (player as? LivingEntity)?.damageHeld(1)
                world.hooks.playSound("entity.mooshroom.shear", x, y, z, 1, 1)
            }
            return true
        }
        return super.interact(player, stack)
    }
}

public final class Pig: Animal {
    public override var type: String { "pig" }
    public var saddled = false
    public var boostTime = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 0.9
        maxHealth = 10; health = 10
        speed = 0.09
        foods = ["carrot", "potato", "beetroot"]
        xpReward = 3
        addBasicGoals()
    }
    public override func drops() -> [DropEntry] {
        var d = [DropEntry(fireTicks > 0 ? "cooked_porkchop" : "porkchop", min: 1, max: 3, lootingBonus: 1)]
        if saddled { d.append(DropEntry("saddle")) }
        return d
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if name == "saddle" && !saddled && !baby {
            saddled = true
            (player as? LivingEntity)?.consumeHeld(1)
            world.hooks.playSound("entity.pig.saddle", x, y, z, 1, 1)
            return true
        }
        if saddled && !((player as? LivingEntity)?.sneaking ?? false) && (stack == nil || name != "carrot") {
            player.mount(self)
            return true
        }
        return super.interact(player, stack)
    }
    public override func tick() {
        super.tick()
        // carrot-on-a-stick steering
        if let rider = passengers.first as? LivingEntity, rider.isPlayer, saddled {
            if let held = rider.mainHand, itemDef(held.id).name == "carrot_on_a_stick" {
                yaw = rider.yaw
                moveForward = 0.7 + (boostTime > 0 ? 0.6 : 0)
                if boostTime > 0 { boostTime -= 1 }
            } else {
                moveForward = 0
            }
        }
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["saddled"] = saddled
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        saddled = (d["saddled"] as? Bool) ?? false
    }
}

public final class Sheep: Animal {
    public override var type: String { "sheep" }
    public var sheared: Bool {
        get { data.sheared ?? false }
        set { data.sheared = newValue }
    }
    public var color: Int {
        get { data.color ?? 0 }
        set { data.color = newValue }
    }
    public var eatGrassTimer = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 1.3
        maxHealth = 8; health = 8
        speed = 0.09
        foods = ["wheat"]
        xpReward = 2
        if gameRng.nextFloat() < 0.05 { color = gameRng.nextFloat() < 0.5 ? 7 : 8 } // gray-ish rare
        if gameRng.nextFloat() < 0.03 { color = 12 }                                  // brown
        if gameRng.nextFloat() < 0.0016 { color = 6 }                                 // pink!
        addBasicGoals()
        goals.add(EatGrassGoal(self, 5))
    }
    public override func drops() -> [DropEntry] {
        var d = [DropEntry(fireTicks > 0 ? "cooked_mutton" : "mutton", min: 1, max: 2, lootingBonus: 1)]
        if !sheared { d.append(DropEntry(COLORS[color] + "_wool")) }
        return d
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if name == "shears" && !sheared && !baby {
            sheared = true
            let count = 1 + gameRng.nextInt(3)
            for _ in 0..<count { spawnItem(world, x, y + 0.5, z, ItemStack(iid(COLORS[color] + "_wool"), 1)) }
            (player as? LivingEntity)?.damageHeld(1)
            world.hooks.playSound("entity.sheep.shear", x, y, z, 1, 1)
            return true
        }
        if let name, name.hasSuffix("_dye") {
            let colorIdx = COLORS.firstIndex(of: String(name.dropLast(4))) ?? -1
            if colorIdx >= 0 && colorIdx != color {
                color = colorIdx
                (player as? LivingEntity)?.consumeHeld(1)
                return true
            }
        }
        return super.interact(player, stack)
    }
}
final class EatGrassGoal: Goal {
    var timer = 0
    override func canUse() -> Bool {
        let m = mob
        if m.rng.nextInt(m.baby ? 50 : 1000) != 0 { return false }
        let below = m.world.getBlock(ifloor(m.x), ifloor(m.y - 1), ifloor(m.z)) >> 4
        let at = m.world.getBlock(ifloor(m.x), ifloor(m.y), ifloor(m.z)) >> 4
        return below == Int(B.grass_block) || at == Int(B.short_grass)
    }
    override func canContinue() -> Bool { timer > 0 }
    override func start() { timer = 40; mob.nav.stop(); mob.data.grazing = true }
    override func stop() { mob.data.grazing = false }
    override func tick() {
        timer -= 1
        if timer == 4 {
            guard let m = mob as? Sheep else { return }
            let bx = ifloor(m.x), by = ifloor(m.y), bz = ifloor(m.z)
            if (m.world.getBlock(bx, by, bz) >> 4) == Int(B.short_grass) {
                m.world.breakBlockNaturally(bx, by, bz)
                m.sheared = false
            } else if (m.world.getBlock(bx, by - 1, bz) >> 4) == Int(B.grass_block) && m.world.rule("mobGriefing") {
                m.world.setBlock(bx, by - 1, bz, Int(cell(B.dirt)))
                m.sheared = false
            }
            if m.baby { m.growUpAge = max(0, m.growUpAge - 600) }
        }
    }
}

public final class Chicken: Animal {
    public override var type: String { "chicken" }
    public var eggTime = 0
    public override init(world: World) {
        super.init(world: world)
        eggTime = 6000 + gameRng.nextInt(6000)   // baseline field-init order
        width = 0.4; height = 0.7
        maxHealth = 4; health = 4
        speed = 0.1
        foods = ["wheat_seeds", "melon_seeds", "pumpkin_seeds", "beetroot_seeds", "torchflower_seeds", "pitcher_pod"]
        xpReward = 2
        addBasicGoals()
    }
    public override func tick() {
        super.tick()
        // flap fall
        if !onGround && vy < 0 { vy *= 0.6 }
        data.airborne = !onGround
        if !baby {
            eggTime -= 1
            if eggTime <= 0 {
                eggTime = 6000 + gameRng.nextInt(6000)
                spawnItem(world, x, y, z, ItemStack(iid("egg"), 1))
                world.hooks.playSound("entity.chicken.egg", x, y, z, 1, 1)
            }
        }
    }
    public override func drops() -> [DropEntry] {
        [
            DropEntry("feather", min: 0, max: 2, lootingBonus: 1),
            DropEntry(fireTicks > 0 ? "cooked_chicken" : "chicken", min: 1, max: 1),
        ]
    }
}

public final class Rabbit: Animal {
    public override var type: String { "rabbit" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.4; height = 0.5
        maxHealth = 3; health = 3
        speed = 0.3
        jumpPower = 0.5
        foods = ["carrot", "golden_carrot", "dandelion"]
        xpReward = 2
        addBasicGoals(1, 2.2)
        goals.add(AvoidEntityGoal(self, 2, { e in e.isPlayer || e.type == "wolf" }, 8, 2.2))
    }
    public override func drops() -> [DropEntry] {
        [
            DropEntry("rabbit_hide", min: 0, max: 1, lootingBonus: 1),
            DropEntry(fireTicks > 0 ? "cooked_rabbit" : "rabbit", min: 1, max: 1),
            DropEntry("rabbit_foot", chance: 0.1, lootingBonus: 0.03),
        ]
    }
}

open class TamableAnimal: Animal {
    public var tamed = false
    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if tamed && ownerId == player.id && stack == nil {
            sitting = !sitting
            return true
        }
        return super.interact(player, stack)
    }
    @discardableResult
    public func tryTame(_ player: Entity, _ chance: Double) -> Bool {
        (player as? LivingEntity)?.consumeHeld(1)
        if gameRng.nextFloat() < chance {
            tamed = true
            ownerId = player.id
            persistent = true
            world.hooks.addParticles("heart", x, y + height, z, 6, 0.4, 0)
            return true
        }
        world.hooks.addParticles("smoke", x, y + height, z, 6, 0.4, 0)
        return false
    }
    open override func save() -> [String: Any] {
        var d = super.save()
        d["tamed"] = tamed
        return d
    }
    open override func load(_ d: [String: Any]) {
        super.load(d)
        tamed = (d["tamed"] as? Bool) ?? false
    }
}

public final class Wolf: TamableAnimal {
    public override var type: String { "wolf" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 0.85
        maxHealth = 8; health = 8
        speed = 0.15
        attackDamage = 4
        foods = ["beef", "cooked_beef", "porkchop", "cooked_porkchop", "mutton", "cooked_mutton", "chicken", "cooked_chicken", "rabbit", "cooked_rabbit", "rotten_flesh"]
        xpReward = 3
        goals.add(FloatGoal(self, 0))
        goals.add(SitWhenOrderedGoal(self, 1))
        goals.add(MeleeAttackGoal(self, 2, 1.3))
        goals.add(FollowOwnerGoal(self, 3))
        goals.add(BreedGoal(self, 4) { [unowned self] a, b in self.spawnBaby(a, b) })
        goals.add(StrollGoal(self, 6, 0.9))
        goals.add(LookAtPlayerGoal(self, 7))
        goals.add(RandomLookGoal(self, 8))
        targetGoals.add(HurtByTargetGoal(self, 1, true))
        targetGoals.add(OwnerHurtTargetGoal(self, 2))
        targetGoals.add(NearestTargetGoal(self, 3, { [unowned self] e in
            !self.tamed && (e.type == "sheep" || e.type == "rabbit" || e.type == "fox" || e.type == "skeleton")
        }, 16))
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if !tamed && name == "bone" {
            tryTame(player, 1.0 / 3)
            return true
        }
        if tamed, let stack, isFood(stack), health < maxHealth {
            heal(Double(itemDef(stack.id).food?.hunger ?? 2))
            (player as? LivingEntity)?.consumeHeld(1)
            return true
        }
        return super.interact(player, stack)
    }
}
final class OwnerHurtTargetGoal: Goal {
    override init(_ mob: Mob, _ priority: Int) {
        super.init(mob, priority)
        flags = GoalFlag.target
    }
    override func canUse() -> Bool {
        let m = mob
        guard let tam = m as? TamableAnimal, tam.tamed, !m.sitting, let ownerId = m.ownerId else { return false }
        guard let owner = m.world.entityById[ownerId] as? LivingEntity else { return false }
        let t = owner.lastAttacker ?? owner.lastHurtTarget
        if let t, !t.dead, t !== m, let living = t as? LivingEntity {
            m.setTarget(living)
            return true
        }
        return false
    }
    override func canContinue() -> Bool { mob.target != nil && !mob.target!.dead }
}

open class Cat: TamableAnimal {
    open override var type: String { "cat" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 0.7
        maxHealth = 10; health = 10
        speed = 0.15
        attackDamage = 3
        foods = ["cod", "salmon"]
        xpReward = 2
        goals.add(FloatGoal(self, 0))
        goals.add(SitWhenOrderedGoal(self, 1))
        goals.add(TemptGoal(self, 3, foods, 0.9))
        goals.add(FollowOwnerGoal(self, 4))
        goals.add(BreedGoal(self, 5) { [unowned self] a, b in self.spawnBaby(a, b) })
        goals.add(StrollGoal(self, 6, 0.9))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(NearestTargetGoal(self, 1, { e in e.type == "rabbit" || e.type == "chicken" }, 10))
        goals.add(MeleeAttackGoal(self, 2, 1.3))
    }
    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if !tamed && (name == "cod" || name == "salmon") {
            tryTame(player, 1.0 / 3)
            return true
        }
        return super.interact(player, stack)
    }
}
public final class Ocelot: Cat {
    public override var type: String { "ocelot" }
}

public final class Fox: Animal {
    public override var type: String { "fox" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.6; height = 0.7
        maxHealth = 10; health = 10
        speed = 0.16
        attackDamage = 2
        foods = ["sweet_berries", "glow_berries"]
        xpReward = 3
        addBasicGoals(1, 2)
        goals.add(AvoidEntityGoal(self, 2, { e in e.isPlayer || e.type == "wolf" }, 10, 2))
        targetGoals.add(NearestTargetGoal(self, 1, { e in e.type == "chicken" || e.type == "rabbit" || e.type == "cod" }, 12))
        goals.add(MeleeAttackGoal(self, 3, 1.4))
    }
    public override func drops() -> [DropEntry] { [] }
}

public final class Parrot: TamableAnimal {
    public override var type: String { "parrot" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.5; height = 0.9
        maxHealth = 6; health = 6
        speed = 0.15
        foods = []
        xpReward = 2
        data.variant = gameRng.nextInt(5)
        goals.add(FloatGoal(self, 0))
        goals.add(PanicGoal(self, 1, 1.3))
        goals.add(SitWhenOrderedGoal(self, 2))
        goals.add(FollowOwnerGoal(self, 3))
        goals.add(StrollGoal(self, 5, 1))
        goals.add(LookAtPlayerGoal(self, 6))
    }
    public override func tick() {
        super.tick()
        data.airborne = !onGround
        if !onGround && vy < 0 { vy *= 0.6 }
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if !tamed, let name, ["wheat_seeds", "melon_seeds", "pumpkin_seeds", "beetroot_seeds"].contains(name) {
            tryTame(player, 1.0 / 3)
            return true
        }
        if name == "cookie" {
            hurt(100, "poison")
            return true
        }
        return super.interact(player, stack)
    }
    public override func drops() -> [DropEntry] { [DropEntry("feather", min: 1, max: 2)] }
}

public final class Bee: Animal {
    public override var type: String { "bee" }
    public var angry = 0
    public var hasNectar = false
    public var hasStung = false
    public var hiveX: Int? = nil
    public var hiveY = 0, hiveZ = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.7; height = 0.6
        maxHealth = 10; health = 10
        speed = 0.12
        attackDamage = 2
        noGravity = false
        gravityScale = 0.04
        foods = ["dandelion", "poppy", "blue_orchid", "allium", "azure_bluet", "red_tulip", "sunflower"]
        xpReward = 2
        goals.add(FloatGoal(self, 0))
        goals.add(MeleeAttackGoal(self, 1, 1.3))
        goals.add(BreedGoal(self, 2) { [unowned self] a, b in self.spawnBaby(a, b) })
        goals.add(TemptGoal(self, 3, foods, 1))
        goals.add(PollinateGoal(self, 4))
        goals.add(ReturnToHiveGoal(self, 5))
        goals.add(StrollGoal(self, 6, 1, 60))
        targetGoals.add(HurtByTargetGoal(self, 1, true))
    }
    public override func tick() {
        super.tick()
        // hover
        if !onGround && vy < 0 { vy *= 0.7 }
        if age % 30 == 0 && rng.nextFloat() < 0.5 { vy += 0.04 }
        if hasStung {
            let t = (data.stingTimer ?? 0) - 1
            data.stingTimer = t
            if t <= 0 { hurt(100, "sting") }
        }
    }
    public override func doMeleeAttack(_ target: LivingEntity) {
        super.doMeleeAttack(target)
        target.addEffect("poison", 100, 0)
        hasStung = true
        data.stingTimer = 1200
        setTarget(nil)
    }
    var hiveScanCooldown = 0
    /// find a nearby hive/nest to deposit nectar in (throttled — the scan box
    /// is ~5k getBlock calls)
    func locateHive() {
        if hiveScanCooldown > 0 { hiveScanCooldown -= 1; return }
        hiveScanCooldown = 40
        let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
        for dy in -4...4 {
            for dz in -12...12 {
                for dx in -12...12 {
                    let id = UInt16(world.getBlock(bx + dx, by + dy, bz + dz) >> 4)
                    if id == B.beehive || id == B.bee_nest {
                        hiveX = bx + dx; hiveY = by + dy; hiveZ = bz + dz
                        return
                    }
                }
            }
        }
    }
    public override func drops() -> [DropEntry] { [] }
}
final class PollinateGoal: MoveToBlockGoal {
    static let FLOWER_WORDS = ["tulip", "dandelion", "poppy", "orchid", "allium", "bluet", "daisy", "cornflower", "sunflower", "azalea", "flower"]
    var pollinating = 0
    init(_ mob: Mob, _ priority: Int) {
        super.init(mob, priority, { w, x, y, z in
            let id = w.getBlock(x, y, z) >> 4
            let name = id != 0 ? blockDefs[id].name : ""
            return PollinateGoal.FLOWER_WORDS.contains { name.contains($0) }
        }, 8, 1, 30)
    }
    override func canUse() -> Bool {
        guard let bee = mob as? Bee, !bee.hasNectar else { return false }
        return super.canUse()
    }
    override func tick() {
        if reached() {
            pollinating += 1
            mob.world.hooks.addParticles("crit", mob.x, mob.y, mob.z, 1, 0.3, 0)
            if pollinating > 100 {
                (mob as? Bee)?.hasNectar = true
                targetPos = nil
            }
        }
    }
}
final class ReturnToHiveGoal: Goal {
    override func canUse() -> Bool {
        guard let bee = mob as? Bee, bee.hasNectar else { return false }
        if bee.hiveX == nil { bee.locateHive() }
        return bee.hiveX != nil
    }
    override func tick() {
        guard let bee = mob as? Bee, let hx = bee.hiveX else { return }
        bee.nav.moveTo(Double(hx), Double(bee.hiveY), Double(bee.hiveZ), 1)
        let dx = bee.x - Double(hx), dy = bee.y - Double(bee.hiveY), dz = bee.z - Double(bee.hiveZ)
        if dx * dx + dy * dy + dz * dz < 4 {
            let c = bee.world.getBlock(hx, bee.hiveY, bee.hiveZ)
            let id = UInt16(c >> 4)
            if id == B.beehive || id == B.bee_nest {
                // player-placed hives have no BE until first use — create lazily
                let be = bee.world.getBlockEntity(hx, bee.hiveY, bee.hiveZ) ?? {
                    let nb = BlockEntityData(type: "beehive", x: hx, y: bee.hiveY, z: bee.hiveZ)
                    nb.honey = 0
                    bee.world.setBlockEntity(nb)
                    return nb
                }()
                be.honey = min(5, (be.honey ?? 0) + 1)
                bee.hasNectar = false
                if (be.honey ?? 0) >= 5 {
                    bee.world.setBlock(hx, bee.hiveY, bee.hiveZ, c) // refresh
                }
            } else {
                bee.hiveX = nil
            }
        }
    }
}

public final class Axolotl: Animal {
    public override var type: String { "axolotl" }
    public var playDead = 0
    public override init(world: World) {
        super.init(world: world)
        breathesWater = true
        width = 0.75; height = 0.42
        maxHealth = 14; health = 14
        speed = 0.12
        attackDamage = 2
        foods = ["tropical_fish_bucket"]
        xpReward = 3
        data.variant = gameRng.nextFloat() < 0.001 ? 4 : gameRng.nextInt(4) // blue rare!
        goals.add(RandomSwimGoal(self, 5, 1, 30))
        goals.add(MeleeAttackGoal(self, 2, 1.2))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(NearestTargetGoal(self, 1, { e in
            ["cod", "salmon", "tropical_fish", "pufferfish", "squid", "glow_squid", "drowned", "guardian"].contains(e.type)
        }, 8))
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let r = super.hurt(amount, source, attacker)
        if r && health < maxHealth / 2 && gameRng.nextFloat() < 0.33 {
            playDead = 200
            addEffect("regeneration", 100, 0)
        }
        return r
    }
    public override func tick() {
        if playDead > 0 {
            playDead -= 1
            baseLivingTick()
            travel()
            return
        }
        super.tick()
    }
    public override func drops() -> [DropEntry] { [] }
}

public final class Frog: Animal {
    public override var type: String { "frog" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.5; height = 0.5
        maxHealth = 10; health = 10
        speed = 0.16
        jumpPower = 0.6
        foods = ["slime_ball"]
        xpReward = 2
        data.variant = gameRng.nextInt(3) // temperate/warm/cold
        addBasicGoals()
        targetGoals.add(NearestTargetGoal(self, 1, { e in
            ((e as? Mob)?.type == "slime" && (e as? Slime)?.size == 1) || ((e as? Mob)?.type == "magma_cube" && (e as? Slime)?.size == 1)
        }, 8))
        goals.add(MeleeAttackGoal(self, 2, 1.2))
    }
    public override func doMeleeAttack(_ target: LivingEntity) {
        // tongue eat
        if target.type == "magma_cube", (target as? Slime)?.size == 1 {
            target.remove()
            let lights = ["ochre_froglight", "pearlescent_froglight", "verdant_froglight"]
            spawnItem(world, x, y, z, ItemStack(iid(lights[(data.variant ?? 0) % 3]), 1))
            world.hooks.playSound("entity.frog.eat", x, y, z, 1, 1)
        } else if target.type == "slime", (target as? Slime)?.size == 1 {
            target.remove()
            spawnItem(world, x, y, z, ItemStack(iid("slime_ball"), 1))
            world.hooks.playSound("entity.frog.eat", x, y, z, 1, 1)
        } else {
            super.doMeleeAttack(target)
        }
    }
    public override func spawnBaby(_ a: Mob, _ b: Mob) {
        // frogs lay frogspawn on water
        for _ in 0..<8 {
            let x = ifloor(a.x) + a.rng.nextInt(5) - 2
            let z = ifloor(a.z) + a.rng.nextInt(5) - 2
            var y = ifloor(a.y) + 2
            while y > ifloor(a.y) - 3 {
                if (a.world.getBlock(x, y, z) >> 4) == Int(B.water) && (a.world.getBlock(x, y + 1, z) >> 4) == 0 {
                    a.world.setBlock(x, y + 1, z, Int(cell(B.frogspawn)))
                    return
                }
                y -= 1
            }
        }
    }
}

public final class Tadpole: Animal {
    public override var type: String { "tadpole" }
    public override init(world: World) {
        super.init(world: world)
        breathesWater = true
        width = 0.4; height = 0.3
        maxHealth = 6; health = 6
        speed = 0.1
        growUpAge = 24000
        baby = true
        xpReward = 1
        goals.add(RandomSwimGoal(self, 2, 1, 20))
    }
    public override func tick() {
        super.tick()
        if !baby {
            // grow into frog
            _ = spawnMobFn?(world, "frog", x, y, z, SpawnOpts())
            remove()
        }
    }
}

public final class Goat: Animal {
    public override var type: String { "goat" }
    public var ramCooldown = 200
    public override init(world: World) {
        super.init(world: world)
        _ = gameRng.nextFloat()   // baseline field-init order (lockstep)
        width = 0.9; height = 1.3
        maxHealth = 10; health = 10
        speed = 0.1
        jumpPower = 0.6
        attackDamage = 2
        foods = ["wheat"]
        xpReward = 3
        addBasicGoals()
        goals.add(RamGoal(self, 5))
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if let stack, itemDef(stack.id).name == "bucket", !baby {
            (player as? LivingEntity)?.replaceHeld(ItemStack(iid("milk_bucket"), 1))
            world.hooks.playSound("entity.goat.milk", x, y, z, 1, 1)
            return true
        }
        return super.interact(player, stack)
    }
}
final class RamGoal: Goal {
    var target: Entity?
    var charging = false
    override func canUse() -> Bool {
        guard let g = mob as? Goat else { return false }
        let cd = g.ramCooldown
        g.ramCooldown -= 1
        if cd > 0 { return false }
        let targets = g.world.getEntitiesNear(g.x, g.y, g.z, 9) { e in
            e is LivingEntity && !(e === g) && (e as? Entity)?.type != "goat"
        }
        if targets.isEmpty || g.rng.nextFloat() > 0.1 { return false }
        target = targets[0] as? Entity
        g.ramCooldown = 600 + g.rng.nextInt(600)
        return true
    }
    override func canContinue() -> Bool { target != nil && !target!.dead && charging }
    override func start() {
        charging = true
        mob.world.hooks.playSound("entity.goat.ram_impact", mob.x, mob.y, mob.z, 0.6, 1.3)
    }
    override func tick() {
        let m = mob
        guard let t = target else { return }
        m.nav.moveToEntity(t, 2.5)
        if m.distanceToSq(t) < 2.5 {
            t.hurt(2, "mob", m)
            let dx = t.x - m.x, dz = t.z - m.z
            var d = (dx * dx + dz * dz).squareRoot()
            if d == 0 { d = 1 }
            t.vx += dx / d * 1.2; t.vz += dz / d * 1.2; t.vy += 0.4
            charging = false
            mob.world.hooks.playSound("entity.goat.ram_impact", m.x, m.y, m.z, 1, 1)
        }
        if m.distanceToSq(t) > 200 { charging = false }
    }
}

public final class Turtle: Animal {
    public override var type: String { "turtle" }
    public override init(world: World) {
        super.init(world: world)
        breathesWater = true
        width = 1.2; height = 0.4
        maxHealth = 30; health = 30
        speed = 0.07
        foods = ["seagrass"]
        xpReward = 3
        addBasicGoals()
        goals.add(MoveToBlockGoal(self, 5, { w, x, y, z in (w.getBlock(x, y, z) >> 4) == Int(B.water) }, 12, 1.2, 60))
    }
    public override func spawnBaby(_ a: Mob, _ b: Mob) {
        // lay eggs on sand
        let x = ifloor(a.x), z = ifloor(a.z)
        let y = a.world.surfaceY(x, z)
        if (a.world.getBlock(x, y - 1, z) >> 4) == Int(B.sand) {
            a.world.setBlock(x, y, z, Int(cell(B.turtle_egg, a.rng.nextInt(4))))
        }
    }
    public override func drops() -> [DropEntry] { [DropEntry("seagrass", chance: 1)] }
}

public final class Dolphin: Animal {
    public override var type: String { "dolphin" }
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 0.6
        maxHealth = 10; health = 10
        speed = 0.14
        attackDamage = 3
        xpReward = 3
        goals.add(RandomSwimGoal(self, 4, 1.2, 15))
        goals.add(LookAtPlayerGoal(self, 6))
        targetGoals.add(HurtByTargetGoal(self, 1, true))
        goals.add(MeleeAttackGoal(self, 2, 1.4))
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if name == "cod" || name == "salmon" {
            (player as? LivingEntity)?.consumeHeld(1)
            // grant dolphin's grace
            (player as? LivingEntity)?.addEffect("dolphins_grace", 2400, 0)
            world.hooks.playSound("entity.dolphin.eat", x, y, z, 1, 1)
            return true
        }
        return false
    }
    public override func tick() {
        super.tick()
        if inWater && age % 4 == 0 && (vx * vx + vz * vz).squareRoot() > 0.08 {
            world.hooks.addParticles("bubble", x, y + 0.3, z, 1, 0.3, 0)
        }
        // grace aura to nearby swimming players
        if age % 40 == 0 {
            for p in world.getEntitiesNear(x, y, z, 9, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                if let pl = p as? LivingEntity, pl.inWater { pl.addEffect("dolphins_grace", 100, 0) }
            }
        }
    }
    public override func drops() -> [DropEntry] { [DropEntry("cod", min: 0, max: 1)] }
}

open class Squid: Animal {
    open override var type: String { "squid" }
    public override init(world: World) {
        super.init(world: world)
        breathesWater = true
        breathesWaterOnly = true
        width = 0.8; height = 0.8
        maxHealth = 10; health = 10
        speed = 0.08
        category = "water"
        xpReward = 2
        goals.add(RandomSwimGoal(self, 2, 1, 20))
    }
    @discardableResult
    open override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let r = super.hurt(amount, source, attacker)
        if r {
            world.hooks.addParticles("squid_ink", x, y + 0.4, z, 12, 0.4, 0)
            // jet away
            let ang = gameRng.nextFloat() * .pi * 2
            vx = detSin(ang) * 0.3
            vz = detCos(ang) * 0.3
        }
        return r
    }
    open override func drops() -> [DropEntry] { [DropEntry("ink_sac", min: 1, max: 3, lootingBonus: 1)] }
}
public final class GlowSquid: Squid {
    public override var type: String { "glow_squid" }
    public override func drops() -> [DropEntry] { [DropEntry("glow_ink_sac", min: 1, max: 3, lootingBonus: 1)] }
}

public final class Bat: Mob {
    public override var type: String { "bat" }
    public var hanging = false
    public override init(world: World) {
        super.init(world: world)
        category = "ambient"
        width = 0.5; height = 0.9
        maxHealth = 6; health = 6
        noGravity = true
        xpReward = 1
    }
    public override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        let above = world.getBlock(ifloor(x), ifloor(y + 1), ifloor(z)) >> 4
        if hanging {
            data.hanging = true
            if above == 0 || rng.nextFloat() < 0.005 { hanging = false }
            vx = 0; vy = 0; vz = 0
        } else {
            data.hanging = false
            // erratic flight
            if age % 4 == 0 {
                vx += (rng.nextFloat() - 0.5) * 0.12
                vy += (rng.nextFloat() - 0.5) * 0.1
                vz += (rng.nextFloat() - 0.5) * 0.12
            }
            vy -= 0.005
            move(vx, vy, vz)
            vx *= 0.9; vy *= 0.9; vz *= 0.9
            // only steer toward real motion — assigning yaw from near-zero
            // noise velocity every tick made bats spin like tops
            if vx * vx + vz * vz > 0.0004 {
                let target = detAtan2(-vx, vz)
                yaw += clampD(wrapAngle(target - yaw), -0.5, 0.5)
            }
            if above != 0 && rng.nextFloat() < 0.01 { hanging = true }
            // despawn far
            if !persistent && age > 600 && rng.nextFloat() < 0.005 { remove() }
        }
    }
}

public final class PolarBear: Animal {
    public override var type: String { "polar_bear" }
    public override init(world: World) {
        super.init(world: world)
        width = 1.4; height = 1.4
        maxHealth = 30; health = 30
        speed = 0.13
        attackDamage = 6
        xpReward = 5
        addBasicGoals()
        goals.add(MeleeAttackGoal(self, 1, 1.25))
        targetGoals.add(HurtByTargetGoal(self, 1, true))
        // protective parents
        targetGoals.add(NearestTargetGoal(self, 2, { [unowned self] e in
            if !e.isPlayer { return false }
            // attack players near cubs
            let cubs = self.world.getEntitiesNear(self.x, self.y, self.z, 8) { e2 in
                (e2 as? Mob)?.type == "polar_bear" && ((e2 as? Mob)?.baby ?? false)
            }
            return !cubs.isEmpty
        }, 12))
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("cod", min: 0, max: 2, lootingBonus: 1), DropEntry("salmon", min: 0, max: 2, chance: 0.5)]
    }
}

public final class Panda: Animal {
    public override var type: String { "panda" }
    public override init(world: World) {
        super.init(world: world)
        width = 1.3; height = 1.25
        maxHealth = 20; health = 20
        speed = 0.1
        attackDamage = 6
        foods = ["bamboo"]
        xpReward = 4
        data.gene = ["normal", "lazy", "playful", "worried", "weak", "aggressive", "brown"][gameRng.nextInt(7)]
        addBasicGoals(0.9)
        targetGoals.add(HurtByTargetGoal(self, 1))
        goals.add(MeleeAttackGoal(self, 2, 1.1))
    }
    public override func drops() -> [DropEntry] { [DropEntry("bamboo", min: 0, max: 2)] }
}

public final class Strider: Animal {
    public override var type: String { "strider" }
    public var saddled = false
    public var boostTime = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 1.7
        maxHealth = 20; health = 20
        speed = 0.18
        foods = ["warped_fungus"]
        xpReward = 3
        addBasicGoals()
    }
    public override func tick() {
        super.tick()
        // walk on lava!
        if inLava {
            vy = max(vy, 0.12)
            inLava = false // immune
            fireTicks = 0
        }
        data.cold = !inLava && (world.getBlock(ifloor(x), ifloor(y - 0.2), ifloor(z)) >> 4) != Int(B.lava)
        if let rider = passengers.first as? LivingEntity, rider.isPlayer, saddled {
            if let held = rider.mainHand, itemDef(held.id).name == "warped_fungus_on_a_stick" {
                yaw = rider.yaw
                moveForward = 0.6 + (boostTime > 0 ? 0.4 : 0)
                if boostTime > 0 { boostTime -= 1 }
            } else { moveForward = 0 }
        }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if source == "lava" || source == "fire" { return false }
        return super.hurt(amount, source, attacker)
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if name == "saddle" && !saddled && !baby {
            saddled = true
            (player as? LivingEntity)?.consumeHeld(1)
            return true
        }
        if saddled && !((player as? LivingEntity)?.sneaking ?? false) {
            player.mount(self)
            return true
        }
        return super.interact(player, stack)
    }
    public override func drops() -> [DropEntry] { [DropEntry("string", min: 2, max: 5, lootingBonus: 1)] }
}

public final class Camel: Animal {
    public override var type: String { "camel" }
    public var saddled = false
    public var dashCooldown = 0
    public override init(world: World) {
        super.init(world: world)
        width = 1.7; height = 2.375
        maxHealth = 32; health = 32
        speed = 0.09
        stepHeight = 1.5
        foods = ["cactus"]
        xpReward = 4
        addBasicGoals()
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if name == "saddle" && !saddled && !baby {
            saddled = true
            (player as? LivingEntity)?.consumeHeld(1)
            return true
        }
        if saddled && !((player as? LivingEntity)?.sneaking ?? false) && !isFood(stack) {
            player.mount(self)
            return true
        }
        return super.interact(player, stack)
    }
    public override func tick() {
        super.tick()
        if dashCooldown > 0 { dashCooldown -= 1 }
        if let rider = passengers.first as? LivingEntity, rider.isPlayer, saddled {
            yaw = rider.yaw
            moveForward = rider.moveForward * 0.9
            moveStrafe = rider.moveStrafe * 0.5
            if rider.jumping && dashCooldown <= 0 && onGround {
                // dash!
                dashCooldown = 55
                vx += -detSin(yaw) * 1.4
                vz += detCos(yaw) * 1.4
                vy += 0.25
                world.hooks.playSound("entity.camel.dash", x, y, z, 1, 1)
            }
        }
    }
}

public final class Sniffer: Animal {
    public override var type: String { "sniffer" }
    public var digCooldown = 0
    public override init(world: World) {
        super.init(world: world)
        width = 1.9; height = 1.75
        maxHealth = 14; health = 14
        speed = 0.08
        foods = ["torchflower_seeds"]
        xpReward = 5
        addBasicGoals(0.9)
        goals.add(SniffDigGoal(self, 5))
    }
}
final class SniffDigGoal: Goal {
    var digging = 0
    override func canUse() -> Bool {
        guard let m = mob as? Sniffer else { return false }
        if m.digCooldown > 0 { m.digCooldown -= 1; return false }
        if m.rng.nextInt(400) != 0 { return false }
        let below = m.world.getBlock(ifloor(m.x), ifloor(m.y - 1), ifloor(m.z)) >> 4
        return below == Int(B.grass_block) || below == Int(B.dirt) || below == Int(B.moss_block) || below == Int(B.mud)
    }
    override func canContinue() -> Bool { digging < 120 }
    override func start() { digging = 0; mob.nav.stop() }
    override func tick() {
        digging += 1
        let m = mob
        if digging % 10 == 0 {
            m.world.hooks.addParticles("block", m.x, m.y + 0.2, m.z, 4, 0.5, Int(cell(B.dirt)))
            m.world.hooks.playSound("entity.sniffer.digging", m.x, m.y, m.z, 0.5, 1)
        }
        if digging == 119 {
            let loot = rollLoot("sniffer_digging", &m.rng)
            for s in loot { spawnItem(m.world, m.x, m.y, m.z, s) }
            (m as? Sniffer)?.digCooldown = 1200
        }
    }
}

public final class Allay: Mob {
    public override var type: String { "allay" }
    public var likedItem: ItemStack?
    public var heldItems: [ItemStack] = []
    public override init(world: World) {
        super.init(world: world)
        category = "creature"
        width = 0.35; height = 0.6
        maxHealth = 20; health = 20
        speed = 0.1
        noGravity = true
        xpReward = 2
        goals.add(AllayCollectGoal(self, 1))
        goals.add(FollowOwnerGoal(self, 2, 3, 16))
        goals.add(StrollGoal(self, 5, 1, 40))
        goals.add(LookAtPlayerGoal(self, 6))
    }
    public override func tick() {
        vy += 0.02 // hover
        super.tick()
        vy *= 0.85
        if age % 10 == 0 { world.hooks.addParticles("crit", x, y + 0.3, z, 1, 0.2, 0) }
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if let stack, likedItem == nil {
            let liked = stack.copy()
            liked.count = 1
            likedItem = liked
            ownerId = player.id
            persistent = true
            (player as? LivingEntity)?.consumeHeld(1)
            world.hooks.playSound("entity.allay.item_given", x, y, z, 1, 1)
            return true
        }
        if stack == nil && !heldItems.isEmpty {
            for s in heldItems { spawnItem(world, x, y, z, s) }
            heldItems = []
            return true
        }
        return false
    }
}
final class AllayCollectGoal: Goal {
    var targetItem: ItemEntity?
    override func canUse() -> Bool {
        guard let a = mob as? Allay, let liked = a.likedItem, a.heldItems.count < 1 else { return false }
        let items = a.world.getEntitiesNear(a.x, a.y, a.z, 16) { e in
            (e as? ItemEntity)?.stack.id == liked.id && !e.dead
        }
        targetItem = items.first as? ItemEntity
        return targetItem != nil
    }
    override func canContinue() -> Bool { targetItem != nil && !targetItem!.dead }
    override func tick() {
        guard let a = mob as? Allay, let t = targetItem else { return }
        let dx = t.x - a.x, dy = t.y - a.y, dz = t.z - a.z
        var d = (dx * dx + dy * dy + dz * dz).squareRoot()
        if d == 0 { d = 1 }
        a.vx += dx / d * 0.03
        a.vy += dy / d * 0.03
        a.vz += dz / d * 0.03
        a.yaw = detAtan2(-dx, dz)
        if d < 1.2 {
            a.heldItems.append(t.stack)
            t.remove()
            targetItem = nil
            a.world.hooks.playSound("entity.allay.item_taken", a.x, a.y, a.z, 1, 1)
        }
    }
}

// fish ------------------------------------------------------------------------
open class AbstractFish: Mob {
    open override var type: String { "cod" }
    public var bucketItem = "cod_bucket"
    public override init(world: World) {
        super.init(world: world)
        category = "water"
        breathesWater = true
        breathesWaterOnly = true
        width = 0.5; height = 0.4
        maxHealth = 3; health = 3
        speed = 0.12
        xpReward = 1
        goals.add(RandomSwimGoal(self, 2, 1, 12))
        goals.add(AvoidEntityGoal(self, 1, { e in e.isPlayer }, 6, 1.6))
    }
    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if let stack, itemDef(stack.id).name == "water_bucket" {
            (player as? LivingEntity)?.replaceHeld(ItemStack(iid(bucketItem), 1))
            remove()
            world.hooks.playSound("item.bucket.fill_fish", x, y, z, 1, 1)
            return true
        }
        return false
    }
    open override func tick() {
        super.tick()
        if !inWater && onGround {
            // flop
            if age % 10 == 0 {
                vy = 0.3
                vx = (rng.nextFloat() - 0.5) * 0.2
                vz = (rng.nextFloat() - 0.5) * 0.2
                world.hooks.playSound("entity.cod.flop", x, y, z, 0.4, 1.2)
            }
        }
    }
}
public final class Cod: AbstractFish {
    public override var type: String { "cod" }
    public override init(world: World) {
        super.init(world: world)
        bucketItem = "cod_bucket"
    }
    public override func drops() -> [DropEntry] { [DropEntry("cod"), DropEntry("bone_meal", chance: 0.05)] }
}
public final class Salmon: AbstractFish {
    public override var type: String { "salmon" }
    public override init(world: World) {
        super.init(world: world)
        bucketItem = "salmon_bucket"
    }
    public override func drops() -> [DropEntry] { [DropEntry("salmon"), DropEntry("bone_meal", chance: 0.05)] }
}
public final class TropicalFish: AbstractFish {
    public override var type: String { "tropical_fish" }
    public override init(world: World) {
        super.init(world: world)
        bucketItem = "tropical_fish_bucket"
        data.pattern = gameRng.nextInt(12)
    }
    public override func drops() -> [DropEntry] { [DropEntry("tropical_fish")] }
}
public final class Pufferfish: AbstractFish {
    public override var type: String { "pufferfish" }
    public var puffed = 0
    public override init(world: World) {
        super.init(world: world)
        bucketItem = "pufferfish_bucket"
    }
    public override func tick() {
        super.tick()
        let threats = world.getEntitiesNear(x, y, z, 2.5) { e in
            ((e as? Entity)?.isPlayer ?? false) || (e as? Entity)?.type == "axolotl"
        }
        if !threats.isEmpty {
            puffed = min(60, puffed + 3)
            for t in threats {
                if puffed > 20 && age % 20 == 0 {
                    (t as? Entity)?.hurt(2, "mob", self)
                    (t as? LivingEntity)?.addEffect("poison", 60, 0)
                }
            }
        } else if puffed > 0 { puffed -= 1 }
        data.puffed = puffed > 20
    }
    public override func drops() -> [DropEntry] { [DropEntry("pufferfish")] }
}
