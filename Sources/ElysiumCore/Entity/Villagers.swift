// Villagers with profession-based trading, wandering traders, horses, golems
//
//
// RNG contract: tradesFor builds the full trade table first (librarian rows
// call enchBookOffer, consuming rng DURING construction, in textual order),
// then shuffles each level's pool. Keep that order exactly.

import Foundation

public struct TradeOffer: Codable {
    public var buyA: ItemStack
    public var buyB: ItemStack?
    public var sell: ItemStack
    public var maxUses: Int
    public var uses: Int
    public var xp: Int
}

private func offer(_ buyA: (String, Int), _ sell: (String, Int), _ maxUses: Int = 12, _ xp: Int = 2,
                   _ buyB: (String, Int)? = nil) -> TradeOffer {
    TradeOffer(
        buyA: ItemStack(iid(buyA.0), buyA.1),
        buyB: buyB.map { ItemStack(iid($0.0), $0.1) },
        sell: ItemStack(iid(sell.0), sell.1),
        maxUses: maxUses, uses: 0, xp: xp
    )
}

public let PROFESSIONS = ["farmer", "librarian", "armorer", "weaponsmith", "toolsmith", "cleric", "butcher", "fisherman", "shepherd", "fletcher", "mason", "cartographer", "leatherworker"]

public let WORKSTATIONS: [String: String] = [
    "composter": "farmer", "lectern": "librarian", "blast_furnace": "armorer",
    "grindstone": "weaponsmith", "smithing_table": "toolsmith", "brewing_stand": "cleric",
    "smoker": "butcher", "barrel": "fisherman", "loom": "shepherd",
    "fletching_table": "fletcher", "stonecutter": "mason", "cartography_table": "cartographer",
    "cauldron": "leatherworker",
]

func tradesFor(_ prof: String, _ level: Int, _ rng: inout RandomX) -> [TradeOffer] {
    // table construction consumes rng for the librarian's book offers — must
    // run for EVERY profession before any pick(), mirroring the baseline object
    // literal evaluation order.
    var T: [String: [[TradeOffer]]] = [:]
    T["farmer"] = [
        [offer(("wheat", 20), ("emerald", 1)), offer(("potato", 26), ("emerald", 1)), offer(("carrot", 22), ("emerald", 1)), offer(("beetroot", 15), ("emerald", 1)), offer(("emerald", 1), ("bread", 6), 16, 1)],
        [offer(("pumpkin", 6), ("emerald", 1)), offer(("emerald", 1), ("pumpkin_pie", 4)), offer(("emerald", 1), ("apple", 4))],
        [offer(("melon", 4), ("emerald", 1)), offer(("emerald", 3), ("cookie", 18))],
        [offer(("emerald", 1), ("cake", 1)), offer(("emerald", 1), ("suspicious_stew", 1))],
        [offer(("emerald", 3), ("golden_carrot", 3)), offer(("emerald", 4), ("glistering_melon_slice", 3))],
    ]
    T["librarian"] = [
        [offer(("paper", 24), ("emerald", 1)), offer(("emerald", 9), ("book", 1)), enchBookOffer(&rng, 1)],
        [offer(("book", 4), ("emerald", 1)), offer(("emerald", 1), ("lantern", 1)), enchBookOffer(&rng, 2)],
        [offer(("ink_sac", 5), ("emerald", 1)), offer(("emerald", 1), ("glass", 4)), enchBookOffer(&rng, 3)],
        [offer(("writable_book", 2), ("emerald", 1)), offer(("emerald", 5), ("clock", 1)), offer(("emerald", 4), ("compass", 1))],
        [offer(("emerald", 20), ("name_tag", 1)), enchBookOffer(&rng, 4)],
    ]
    T["armorer"] = [
        [offer(("coal", 15), ("emerald", 1)), offer(("emerald", 5), ("iron_helmet", 1)), offer(("emerald", 9), ("iron_chestplate", 1))],
        [offer(("iron_ingot", 4), ("emerald", 1)), offer(("emerald", 36), ("bell", 1)), offer(("emerald", 7), ("iron_leggings", 1))],
        [offer(("lava_bucket", 1), ("emerald", 1)), offer(("emerald", 4), ("chainmail_leggings", 1)), offer(("emerald", 1), ("chainmail_boots", 1))],
        [offer(("emerald", 19), ("diamond_leggings", 1)), offer(("emerald", 13), ("shield", 1))],
        [offer(("emerald", 21), ("diamond_chestplate", 1)), offer(("emerald", 13), ("diamond_helmet", 1))],
    ]
    T["weaponsmith"] = [
        [offer(("coal", 15), ("emerald", 1)), offer(("emerald", 3), ("iron_axe", 1)), offer(("emerald", 7), ("iron_sword", 1))],
        [offer(("iron_ingot", 4), ("emerald", 1)), offer(("emerald", 36), ("bell", 1))],
        [offer(("flint", 24), ("emerald", 1))],
        [offer(("diamond", 1), ("emerald", 1)), offer(("emerald", 19), ("diamond_axe", 1))],
        [offer(("emerald", 13), ("diamond_sword", 1))],
    ]
    T["toolsmith"] = [
        [offer(("coal", 15), ("emerald", 1)), offer(("emerald", 1), ("stone_axe", 1)), offer(("emerald", 1), ("stone_pickaxe", 1))],
        [offer(("iron_ingot", 4), ("emerald", 1)), offer(("emerald", 36), ("bell", 1))],
        [offer(("flint", 30), ("emerald", 1)), offer(("emerald", 6), ("iron_pickaxe", 1))],
        [offer(("diamond", 1), ("emerald", 1)), offer(("emerald", 18), ("diamond_pickaxe", 1))],
        [offer(("emerald", 16), ("diamond_shovel", 1)), offer(("emerald", 22), ("diamond_hoe", 1))],
    ]
    T["cleric"] = [
        [offer(("rotten_flesh", 32), ("emerald", 1)), offer(("emerald", 1), ("redstone", 2))],
        [offer(("gold_ingot", 3), ("emerald", 1)), offer(("emerald", 1), ("lapis_lazuli", 1))],
        [offer(("rabbit_foot", 2), ("emerald", 1)), offer(("emerald", 4), ("glowstone", 1))],
        [offer(("scute", 4), ("emerald", 1)), offer(("glass_bottle", 9), ("emerald", 1)), offer(("emerald", 5), ("ender_pearl", 1))],
        [offer(("nether_wart", 22), ("emerald", 1)), offer(("emerald", 3), ("experience_bottle", 1))],
    ]
    T["butcher"] = [
        [offer(("chicken", 14), ("emerald", 1)), offer(("porkchop", 7), ("emerald", 1)), offer(("rabbit", 4), ("emerald", 1)), offer(("emerald", 1), ("rabbit_stew", 1))],
        [offer(("coal", 15), ("emerald", 1)), offer(("emerald", 1), ("cooked_porkchop", 5)), offer(("emerald", 1), ("cooked_chicken", 8))],
        [offer(("mutton", 7), ("emerald", 1)), offer(("beef", 10), ("emerald", 1))],
        [offer(("dried_kelp_block", 10), ("emerald", 1))],
        [offer(("sweet_berries", 10), ("emerald", 1))],
    ]
    T["fisherman"] = [
        [offer(("string", 20), ("emerald", 1)), offer(("coal", 10), ("emerald", 1)), offer(("emerald", 1), ("cod_bucket", 1)), offer(("cod", 6), ("emerald", 1))],
        [offer(("cod", 15), ("emerald", 1)), offer(("emerald", 1), ("cooked_cod", 6))],
        [offer(("salmon", 13), ("emerald", 1)), offer(("emerald", 8), ("fishing_rod", 1))],
        [offer(("tropical_fish", 6), ("emerald", 1))],
        [offer(("pufferfish", 4), ("emerald", 1)), offer(("emerald", 3), ("campfire", 1))],
    ]
    T["shepherd"] = [
        [offer(("white_wool", 18), ("emerald", 1)), offer(("emerald", 2), ("shears", 1))],
        [offer(("white_dye", 12), ("emerald", 1)), offer(("emerald", 1), ("white_wool", 1)), offer(("emerald", 1), ("white_carpet", 4))],
        [offer(("red_dye", 12), ("emerald", 1)), offer(("emerald", 3), ("red_bed", 1))],
        [offer(("blue_dye", 12), ("emerald", 1))],
        [offer(("emerald", 2), ("pink_wool", 3)), offer(("emerald", 2), ("cyan_wool", 3))],
    ]
    T["fletcher"] = [
        [offer(("stick", 32), ("emerald", 1)), offer(("emerald", 1), ("arrow", 16)), offer(("gravel", 10), ("emerald", 1), 12, 1, ("flint", 10))],
        [offer(("flint", 26), ("emerald", 1)), offer(("emerald", 2), ("bow", 1))],
        [offer(("string", 14), ("emerald", 1)), offer(("emerald", 3), ("crossbow", 1))],
        [offer(("feather", 24), ("emerald", 1))],
        [offer(("emerald", 2), ("spectral_arrow", 5))],
    ]
    T["mason"] = [
        [offer(("clay_ball", 10), ("emerald", 1)), offer(("emerald", 1), ("bricks", 10))],
        [offer(("stone", 20), ("emerald", 1)), offer(("emerald", 1), ("chiseled_stone_bricks", 4))],
        [offer(("granite", 16), ("emerald", 1)), offer(("emerald", 1), ("polished_andesite", 4)), offer(("emerald", 1), ("polished_granite", 4))],
        [offer(("quartz", 12), ("emerald", 1)), offer(("emerald", 1), ("orange_terracotta", 1)), offer(("emerald", 1), ("red_glazed_terracotta", 1))],
        [offer(("emerald", 1), ("quartz_pillar", 1)), offer(("emerald", 1), ("quartz_block", 1))],
    ]
    T["cartographer"] = [
        [offer(("paper", 24), ("emerald", 1)), offer(("emerald", 7), ("compass", 1))],
        [offer(("glass_pane", 11), ("emerald", 1))],
        [offer(("compass", 1), ("emerald", 1))],
        [offer(("emerald", 14), ("ender_eye", 1))],
        [offer(("emerald", 8), ("clock", 1))],
    ]
    T["leatherworker"] = [
        [offer(("leather", 6), ("emerald", 1)), offer(("emerald", 3), ("leather_leggings", 1))],
        [offer(("flint", 26), ("emerald", 1)), offer(("emerald", 5), ("leather_chestplate", 1))],
        [offer(("rabbit_hide", 9), ("emerald", 1)), offer(("emerald", 4), ("leather_helmet", 1))],
        [offer(("scute", 4), ("emerald", 1)), offer(("emerald", 4), ("leather_boots", 1))],
        [offer(("emerald", 6), ("leather_horse_armor", 1)), offer(("emerald", 5), ("saddle", 1))],
    ]
    guard let tables = T[prof] else { return [] }
    let lvl = min(level, tables.count)
    var out: [TradeOffer] = []
    for i in 0..<lvl {
        var pool = tables[i]
        rng.shuffle(&pool)
        out.append(contentsOf: pool.prefix(min(2, pool.count)))
    }
    return out
}

private func enchBookOffer(_ rng: inout RandomX, _ tier: Int) -> TradeOffer {
    let tradeable = ENCHANTMENTS.filter { $0.tradeable && !$0.curse }
    let e = tradeable[rng.nextInt(tradeable.count)]
    let lvl = 1 + rng.nextInt(min(e.maxLevel, tier + 1))
    let cost = 2 + rng.nextInt(5 + lvl * 10) + lvl * 3
    return TradeOffer(
        buyA: ItemStack(iid("emerald"), min(64, cost)),
        buyB: ItemStack(iid("book"), 1),
        sell: ItemStack(iid("enchanted_book"), 1, ench: [EnchInstance(e.id, lvl)]),
        maxUses: 12, uses: 0, xp: 5
    )
}

// ---------------------------------------------------------------------------
open class Villager: Mob {
    open override var type: String { "villager" }
    public var profession = "none"
    public var tradeLevel = 1
    public var tradeXP = 0
    public var offers: [TradeOffer] = []
    public var restockTimer = 0
    public var workstation: (Int, Int, Int)? = nil
    public var homeBed: (Int, Int, Int)? = nil
    public override init(world: World) {
        super.init(world: world)
        category = "creature"
        width = 0.6; height = 1.95
        maxHealth = 20; health = 20
        speed = 0.1
        persistent = true
        xpReward = 0
        goals.add(FloatGoal(self, 0))
        goals.add(AvoidEntityGoal(self, 1, { e in
            ["zombie", "husk", "drowned", "zombie_villager", "pillager", "vindicator", "evoker", "vex", "ravager", "zoglin"].contains(e.type)
        }, 10, 1.2))
        goals.add(FindWorkstationGoal(self, 2))
        goals.add(StrollGoal(self, 6, 0.7))
        goals.add(LookAtPlayerGoal(self, 7, 8, 0.05))
        goals.add(RandomLookGoal(self, 8))
    }
    open override func tick() {
        super.tick()
        // acquire profession from claimed workstation
        if profession == "none", let ws = workstation, age % 40 == 0 {
            let bid = world.getBlock(ws.0, ws.1, ws.2) >> 4
            let name = blockNameOf(bid)
            if let prof = WORKSTATIONS[name] {
                profession = prof
                refreshTrades()
                world.hooks.playSound("entity.villager.work", x, y, z, 1, 1)
            } else {
                workstation = nil
            }
        }
        // restock at workstation
        if restockTimer > 0 { restockTimer -= 1 }
    }
    public func refreshTrades() {
        if profession == "none" || profession == "nitwit" { return }
        offers = tradesFor(profession, tradeLevel, &rng)
    }
    public func addTradeXP(_ xp: Int) {
        tradeXP += xp
        let thresholds = [0, 10, 70, 150, 250]
        if tradeLevel < 5 && tradeXP >= thresholds[tradeLevel] {
            tradeLevel += 1
            refreshTrades()
            world.hooks.addParticles("heart", x, y + 2, z, 5, 0.4, 0)
        }
    }
    public func restock() {
        for i in offers.indices { offers[i].uses = 0 }
        restockTimer = 2400
    }
    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if baby || profession == "none" || profession == "nitwit" {
            world.hooks.playSound("entity.villager.no", x, y, z, 1, 1)
            return false
        }
        if offers.isEmpty { refreshTrades() }
        openTradingFn?(player, self)
        return true
    }
    @discardableResult
    open override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let r = super.hurt(amount, source, attacker)
        if r, let attacker, attacker.isPlayer {
            // gossip: minor reputation hit — golems may aggro
            for g in world.getEntitiesNear(x, y, z, 16, filter: { ($0 as? Entity)?.type == "iron_golem" }) {
                (g as? Mob)?.setTarget(attacker as? LivingEntity)
            }
        }
        return r
    }
    open override func save() -> [String: Any] {
        var d = super.save()
        d["profession"] = profession
        d["tradeLevel"] = tradeLevel
        d["tradeXP"] = tradeXP
        if let enc = try? JSONEncoder().encode(offers),
           let obj = try? JSONSerialization.jsonObject(with: enc) {
            d["offers"] = obj
        }
        return d
    }
    open override func load(_ d: [String: Any]) {
        super.load(d)
        profession = (d["profession"] as? String) ?? "none"
        tradeLevel = (d["tradeLevel"] as? NSNumber)?.intValue ?? 1
        tradeXP = (d["tradeXP"] as? NSNumber)?.intValue ?? 0
        if let raw = d["offers"],
           let bytes = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([TradeOffer].self, from: bytes) {
            offers = decoded
        } else {
            offers = []
        }
    }
}

final class FindWorkstationGoal: MoveToBlockGoal {
    init(_ mob: Mob, _ priority: Int) {
        super.init(mob, priority, { [unowned mob] w, x, y, z in
            guard let v = mob as? Villager else { return false }
            if v.profession != "none" && v.workstation != nil { return false }
            let name = blockNameOf(w.getBlock(x, y, z) >> 4)
            return WORKSTATIONS[name] != nil
        }, 10, 1, 80)
    }
    override func start() {
        super.start()
        guard let v = mob as? Villager else { return }
        if let t = targetPos, v.workstation == nil { v.workstation = t }
    }
}

/// late-bound trading UI hook (player.openTrading in baseline)
public var openTradingFn: ((Entity, Mob) -> Void)?
public func bindOpenTrading(_ fn: ((Entity, Mob) -> Void)?) { openTradingFn = fn }

public final class WanderingTrader: Mob {
    public override var type: String { "wandering_trader" }
    public var offers: [TradeOffer] = []
    public var despawnTimer = 48000
    public var restockTimer = 0
    public override init(world: World) {
        super.init(world: world)
        category = "creature"
        width = 0.6; height = 1.95
        maxHealth = 20; health = 20
        speed = 0.12
        persistent = true
        goals.add(FloatGoal(self, 0))
        goals.add(PanicGoal(self, 1, 1.4))
        goals.add(AvoidEntityGoal(self, 2, { e in
            ["zombie", "pillager", "vindicator", "evoker", "vex", "zoglin"].contains(e.type)
        }, 10, 1.2))
        goals.add(StrollGoal(self, 5, 1))
        goals.add(LookAtPlayerGoal(self, 7))
        var pool: [TradeOffer] = [
            offer(("emerald", 1), ("fern", 1)), offer(("emerald", 1), ("sugar_cane", 1)),
            offer(("emerald", 1), ("pumpkin", 1)), offer(("emerald", 1), ("dandelion", 1)),
            offer(("emerald", 1), ("poppy", 1)), offer(("emerald", 1), ("wheat_seeds", 1)),
            offer(("emerald", 1), ("beetroot_seeds", 1)), offer(("emerald", 1), ("oak_sapling", 1)),
            offer(("emerald", 5), ("cherry_sapling", 1)), offer(("emerald", 1), ("red_mushroom", 1)),
            offer(("emerald", 1), ("brown_mushroom", 1)), offer(("emerald", 1), ("lily_pad", 2)),
            offer(("emerald", 1), ("sand", 8)), offer(("emerald", 1), ("red_sand", 4)),
            offer(("emerald", 3), ("packed_ice", 1)), offer(("emerald", 6), ("blue_ice", 1)),
            offer(("emerald", 1), ("kelp", 1)), offer(("emerald", 5), ("nautilus_shell", 1)),
            offer(("emerald", 1), ("bamboo", 1)), offer(("emerald", 4), ("sea_pickle", 1)),
        ]
        rng.shuffle(&pool)
        offers = Array(pool.prefix(6))
    }
    public override func tick() {
        super.tick()
        despawnTimer -= 1
        if despawnTimer <= 0 { remove() }
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        openTradingFn?(player, self)
        return true
    }
    public func addTradeXP(_ xp: Int) {}
    public func restock() {}
}

public final class IronGolem: Mob {
    public override var type: String { "iron_golem" }
    public var playerMade = false
    public override init(world: World) {
        super.init(world: world)
        category = "creature"
        width = 1.4; height = 2.7
        maxHealth = 100; health = 100
        speed = 0.12
        attackDamage = 12
        kbResist = 1
        persistent = true
        xpReward = 0
        goals.add(FloatGoal(self, 0))
        goals.add(MeleeAttackGoal(self, 1, 1.1))
        goals.add(StrollGoal(self, 5, 0.6))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, { e in
            let t = e.type
            return ((e as? Mob)?.category == "monster" && t != "creeper")
                || ["zombie", "skeleton", "spider", "pillager", "vindicator", "evoker", "ravager"].contains(t)
        }, 20))
    }
    public override func doMeleeAttack(_ target: LivingEntity) {
        attackAnim = 1
        target.hurt(attackDamage + Double(rng.nextInt(8)), "mob", self)
        target.vy += 0.5 // launch!
        world.hooks.playSound("entity.iron_golem.attack", x, y, z, 1, 1)
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if let stack, itemDef(stack.id).name == "iron_ingot", health < maxHealth {
            heal(25)
            (player as? LivingEntity)?.consumeHeld(1)
            world.hooks.playSound("entity.iron_golem.repair", x, y, z, 1, 1)
            return true
        }
        return false
    }
    public override func drops() -> [DropEntry] {
        [DropEntry("iron_ingot", min: 3, max: 5), DropEntry("poppy", min: 0, max: 2)]
    }
}

public final class SnowGolem: Mob {
    public override var type: String { "snow_golem" }
    public override init(world: World) {
        super.init(world: world)
        category = "creature"
        width = 0.7; height = 1.9
        maxHealth = 4; health = 4
        speed = 0.2
        persistent = true
        goals.add(FloatGoal(self, 0))
        goals.add(SnowballAttackGoal(self, 1))
        goals.add(StrollGoal(self, 5, 1))
        goals.add(LookAtPlayerGoal(self, 7))
        targetGoals.add(NearestTargetGoal(self, 1, { e in (e as? Mob)?.category == "monster" }, 10))
    }
    public override func tick() {
        super.tick()
        // snow trail
        if onGround && world.rule("mobGriefing") {
            let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
            let at = world.getBlock(bx, by, bz)
            if at == 0 && (world.getBlock(bx, by - 1, bz) >> 4) != 0 {
                world.setBlock(bx, by, bz, Int(cell(B.snow, 0)))
            }
        }
        // melt in hot/wet
        if inWater { hurt(1, "drown") }
    }
    public override func drops() -> [DropEntry] { [DropEntry("snowball", min: 0, max: 15)] }
}
final class SnowballAttackGoal: Goal {
    var cooldown = 0
    override func canUse() -> Bool { mob.target != nil && !mob.target!.dead }
    override func tick() {
        let m = mob
        guard let t = m.target else { return }
        m.lookX = t.x; m.lookY = t.eyeY(); m.lookZ = t.z
        if m.distanceToSq(t) > 100 { m.nav.moveToEntity(t, 1.2) }
        else { m.nav.stop() }
        let cd = cooldown
        cooldown -= 1
        if cd <= 0 && m.canSee(t) {
            cooldown = 20
            throwSnowballFn?(m, t)
        }
    }
}
public var throwSnowballFn: ((Mob, LivingEntity) -> Void)?
public func bindThrowSnowball(_ fn: ((Mob, LivingEntity) -> Void)?) { throwSnowballFn = fn }

// ---------------------------------------------------------------------------
// Horses
// ---------------------------------------------------------------------------
open class HorseBase: Animal {
    open override var type: String { "horse" }
    public var tamed = false
    public var saddled = false
    public var temper = 0
    public var jumpStrength = 0.0
    public override init(world: World) {
        super.init(world: world)
        jumpStrength = 0.5 + gameRng.nextFloat() * 0.5   // baseline field-init order
        width = 1.4; height = 1.6
        let hp = 15 + Double(gameRng.nextInt(16))
        maxHealth = hp; health = hp
        speed = 0.15 + gameRng.nextFloat() * 0.12
        stepHeight = 1.0
        foods = ["golden_apple", "golden_carrot", "apple", "sugar", "wheat", "hay_block"]
        xpReward = 3
        addBasicGoals(1, 1.6)
    }
    open override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        let name = stack.map { itemDef($0.id).name }
        if tamed && name == "saddle" && !saddled {
            saddled = true
            (player as? LivingEntity)?.consumeHeld(1)
            world.hooks.playSound("entity.horse.saddle", x, y, z, 1, 1)
            return true
        }
        if let stack, isFood(stack) { return super.interact(player, stack) }
        if !((player as? LivingEntity)?.sneaking ?? false) && !baby {
            if !tamed {
                // attempt taming by riding
                player.mount(self)
                temper += 5
                if rng.nextInt(100) < temper {
                    tamed = true
                    persistent = true
                    world.hooks.addParticles("heart", x, y + 1.6, z, 7, 0.6, 0)
                } else {
                    // buck off after a moment
                    data.buckTimer = 20 + rng.nextInt(20)
                }
            } else {
                player.mount(self)
            }
            return true
        }
        return super.interact(player, stack)
    }
    open override func tick() {
        super.tick()
        if data.buckTimer != nil && !passengers.isEmpty {
            data.buckTimer = (data.buckTimer ?? 0) - 1
            if (data.buckTimer ?? 0) <= 0 {
                let rider = passengers[0]
                rider.dismount()
                rider.vy = 0.4
                data.buckTimer = nil
                world.hooks.playSound("entity.horse.angry", x, y, z, 1, 1)
            }
        }
        // rider control
        if let rider = passengers.first as? LivingEntity, rider.isPlayer, tamed, saddled {
            yaw = rider.yaw
            moveForward = rider.moveForward
            moveStrafe = rider.moveStrafe * 0.5
            if rider.jumping && onGround {
                vy = jumpStrength
                onGround = false
            }
        }
    }
    open override func drops() -> [DropEntry] {
        var d = [DropEntry("leather", min: 0, max: 2, lootingBonus: 1)]
        if saddled { d.append(DropEntry("saddle")) }
        return d
    }
    open override func save() -> [String: Any] {
        var d = super.save()
        d["tamed"] = tamed; d["saddled"] = saddled
        d["jumpStrength"] = jumpStrength; d["speed"] = speed
        return d
    }
    open override func load(_ d: [String: Any]) {
        super.load(d)
        tamed = (d["tamed"] as? Bool) ?? false
        saddled = (d["saddled"] as? Bool) ?? false
        jumpStrength = (d["jumpStrength"] as? NSNumber)?.doubleValue ?? 0.7
        speed = (d["speed"] as? NSNumber)?.doubleValue ?? 0.2
    }
}
public final class Horse: HorseBase {
    public override var type: String { "horse" }
}
public final class Donkey: HorseBase {
    public override var type: String { "donkey" }
    public override init(world: World) {
        super.init(world: world)
        width = 1.3; height = 1.5
    }
}
public final class Mule: HorseBase {
    public override var type: String { "mule" }
}
public final class SkeletonHorse: HorseBase {
    public override var type: String { "skeleton_horse" }
    public override init(world: World) {
        super.init(world: world)
        maxHealth = 15; health = 15
        tamed = true
    }
    public override func drops() -> [DropEntry] { [DropEntry("bone", min: 0, max: 2)] }
}

public final class Llama: Animal {
    public override var type: String { "llama" }
    public var spitCooldown = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 1.87
        let hp = 15 + Double(gameRng.nextInt(16))
        maxHealth = hp; health = hp
        speed = 0.12
        foods = ["wheat", "hay_block"]
        xpReward = 3
        data.variant = gameRng.nextInt(4)
        addBasicGoals()
        targetGoals.add(HurtByTargetGoal(self, 1))
    }
    public override func tick() {
        super.tick()
        if spitCooldown > 0 { spitCooldown -= 1 }
        if let t = target, !t.dead, spitCooldown <= 0, distanceToSq(t) < 100 {
            spitCooldown = 40
            spitFn?(self, t)
            setTarget(nil)
        }
    }
    public override func drops() -> [DropEntry] { [DropEntry("leather", min: 0, max: 2)] }
}
public var spitFn: ((Mob, LivingEntity) -> Void)?
public func bindSpit(_ fn: ((Mob, LivingEntity) -> Void)?) { spitFn = fn }
