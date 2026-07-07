// LivingEntity — health, status effects, equipment,
// movement physics (ground friction / water / lava / climbing), armor damage
// math, death.
//
// `effects` is insertion-ordered with replace-in-place on re-add — that is deterministic
// Map.set semantics and the iteration order feeds damage/heal tick order.

import Foundation

public struct DropEntry {
    public var item: String
    public var min: Int?
    public var max: Int?
    public var chance: Double?
    public var lootingBonus: Double?

    public init(_ item: String, min: Int? = nil, max: Int? = nil, chance: Double? = nil, lootingBonus: Double? = nil) {
        self.item = item; self.min = min; self.max = max
        self.chance = chance; self.lootingBonus = lootingBonus
    }
}

open class LivingEntity: Entity {
    public var health = 20.0
    public var maxHealth = 20.0
    public var absorption = 0.0
    public var effects: [ActiveEffect] = []   // ordered like an insertion-ordered map
    /// equipment: 0 head 1 chest 2 legs 3 feet
    public var armor: [ItemStack?] = [nil, nil, nil, nil]
    private var _mainHand: ItemStack?
    open var mainHand: ItemStack? {
        get { _mainHand }
        set { _mainHand = newValue }
    }
    public var offHand: ItemStack?
    public var hurtTime = 0
    public var deathTime = 0
    /// one-shot flag consumed by the sculk catalyst bloom check after this tick's death
    public var catalystBloomPending = false
    public var attackCooldown = 0.0
    /// movement attributes
    public var speed = 0.1
    public var kbResist = 0.0
    public var jumpPower = 0.42
    /// AI movement intent (set by goals / input)
    public var moveForward = 0.0
    public var moveStrafe = 0.0
    public var jumping = false
    public var sprinting = false
    public var sneaking = false
    public var limbSwing = 0.0
    public var limbAmp = 0.0
    public var attackAnim = 0.0
    public var headYaw = 0.0
    public var bodyYaw = 0.0
    public var lastAttacker: Entity?
    /// set by Player on outgoing attacks (wolf assist targeting reads it)
    public var lastHurtTarget: Entity?
    public var lastHurtByPlayerTime = 0
    public var rng = RandomX(0)   // seeded from gameRng in init (baseline field-init order)
    public var xpReward = 5
    /// water mobs (baseline dynamic props)
    public var breathesWater = false
    public override init(world: World) {
        super.init(world: world)
        // baseline Living field initializer order: rng seeds from gameRng here
        rng = RandomX(UInt32(gameRng.nextInt(1000000000)))
    }

    public var breathesWaterOnly = false
    /// player-only props read through `(e as any)` in baseline goal filters
    open var gameMode: Int { 0 }
    open var invisibleToMobs: Bool { false }
    /// player-only inventory hooks called from mob interactions (no-ops here)
    open func consumeHeld(_ n: Int) {}
    open func replaceHeld(_ stack: ItemStack) {}
    open func damageHeld(_ n: Int) {}
    @discardableResult
    open func give(_ stack: ItemStack?) -> Bool { false }
    open var wearingPumpkin: Bool { false }

    // ---- effects ----------------------------------------------------------
    public func addEffect(_ id: String, _ duration: Int, _ amplifier: Int = 0, ambient: Bool = false) {
        if let i = effects.firstIndex(where: { $0.id == id }) {
            let cur = effects[i]
            if cur.amplifier > amplifier || (cur.amplifier == amplifier && cur.duration > duration) { return }
            effects[i] = ActiveEffect(id: id, duration: duration, amplifier: amplifier, ambient: ambient)
        } else {
            effects.append(ActiveEffect(id: id, duration: duration, amplifier: amplifier, ambient: ambient))
        }
        let def = effectDef(id)
        if def.instant { applyInstantEffect(id, amplifier) }
    }
    private func applyInstantEffect(_ id: String, _ amp: Int) {
        if id == "instant_health" { heal(4 * pow(2, Double(amp))) }
        else if id == "instant_damage" { hurt(6 * pow(2, Double(amp)), "magic") }
        else if id == "saturation" { feed(amp + 1, 2) }
    }
    /// Player hook (baseline `(this as any).feed?.()`)
    open func feed(_ hunger: Int, _ saturation: Double) {}
    /// Player hook (baseline `(this as any).addExhaustion?.()`)
    open func addExhaustion(_ amount: Double) {}

    public func hasEffect(_ id: String) -> Bool { effects.contains { $0.id == id } }
    public func effectLevel(_ id: String) -> Int {
        guard let e = effects.first(where: { $0.id == id }) else { return 0 }
        return e.amplifier + 1
    }
    public func removeEffect(_ id: String) { effects.removeAll { $0.id == id } }
    public func clearEffects() { effects.removeAll() }

    func tickEffects() {
        for snapshot in effects {
            // re-locate: a prior iteration may have removed entries
            guard let i = effects.firstIndex(where: { $0.id == snapshot.id }) else { continue }
            if effects[i].duration > 0 { effects[i].duration -= 1 }
            if effects[i].duration == 0 { effects.remove(at: i); continue }
            let e = effects[i]
            switch e.id {
            case "regeneration":
                if age % max(1, 50 >> e.amplifier) == 0 { heal(1) }
            case "poison":
                if age % max(1, 25 >> e.amplifier) == 0 && health > 1 { hurt(1, "magic") }
            case "wither":
                if age % max(1, 40 >> e.amplifier) == 0 { hurt(1, "wither") }
            case "hunger":
                addExhaustion(0.005 * Double(e.amplifier + 1))
            case "levitation":
                vy += (0.05 * Double(e.amplifier + 1) - vy) * 0.2
                fallDistance = 0
            case "slow_falling":
                if vy < 0 { vy *= 0.6 }
                fallDistance = 0
            default: break
            }
        }
    }

    // ---- health -----------------------------------------------------------
    public func heal(_ amount: Double) {
        if dead { return }
        health = min(maxHealth, health + amount)
    }

    public func armorValue() -> Double {
        var v = 0.0
        for a in armor {
            if let a { v += Double(itemDef(a.id).armor?.defense ?? 0) }
        }
        return v
    }
    public func armorToughness() -> Double {
        var v = 0.0
        for a in armor {
            if let a { v += itemDef(a.id).armor?.toughness ?? 0 }
        }
        return v
    }
    public func protectionLevel(_ source: String) -> Double {
        var epf = 0
        for a in armor {
            guard let a else { continue }
            epf += enchLevel(a, "protection")
            if source == "fire" || source == "lava" { epf += enchLevel(a, "fire_protection") * 2 }
            if source == "explosion" { epf += enchLevel(a, "blast_protection") * 2 }
            if source == "projectile" { epf += enchLevel(a, "projectile_protection") * 2 }
            if source == "fall" { epf += enchLevel(a, "feather_falling") * 3 }
        }
        return Double(min(20, epf))
    }

    @discardableResult
    open override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if dead || deathTime > 0 || amount <= 0 { return false }
        if invulnTicks > 0 { return false }
        if source == "fire" && hasEffect("fire_resistance") { return false }
        if source == "lava" && hasEffect("fire_resistance") { return false }
        if source == "fall" && (type == "cat" || type == "ocelot" || type == "chicken" || type == "bat" || type == "parrot" || type == "bee" || type == "shulker" || type == "iron_golem") { return false }

        // armor reduction (vanilla formula)
        let bypassesArmor = source == "fall" || source == "void" || source == "magic" || source == "wither" || source == "starve" || source == "drown" || source == "freeze" || source == "sonic"
        var dmg = amount
        if !bypassesArmor {
            let armorV = armorValue()
            let tough = armorToughness()
            dmg = dmg * (1 - min(20, max(armorV / 5, armorV - 4 * dmg / (tough + 8))) / 25)
            damageArmor(amount)
        }
        // resistance effect
        let res = effectLevel("resistance")
        if res > 0 { dmg *= max(0, 1 - Double(res) * 0.2) }
        // protection enchants
        let epf = protectionLevel(source)
        dmg *= 1 - epf / 25

        // absorption
        if absorption > 0 {
            let absorbed = min(absorption, dmg)
            absorption -= absorbed
            dmg -= absorbed
        }
        health -= dmg
        hurtTime = 10
        invulnTicks = 10
        if let attacker {
            lastAttacker = attacker
            if attacker.isPlayer { lastHurtByPlayerTime = 100 }
            // knockback
            let dx = x - attacker.x, dz = z - attacker.z
            var d = (dx * dx + dz * dz).squareRoot()
            if d == 0 { d = 1 }
            let kb = 0.4 * (1 - kbResist)
            vx += dx / d * kb
            vz += dz / d * kb
            vy = min(vy + 0.36 * (1 - kbResist), 0.4)
        }
        world.hooks.playSound(hurtSound(), x, y, z, 1, 0.9 + Double.random(in: 0..<1) * 0.2)
        if health <= 0 { die(source, attacker) }
        return true
    }

    func damageArmor(_ amount: Double) {
        let dmg = max(1, Int((amount / 4).rounded(.down)))
        for i in 0..<4 {
            guard let a = armor[i] else { continue }
            let unb = enchLevel(a, "unbreaking")
            if unb > 0 && rng.nextFloat() < Double(unb) / Double(unb + 1) * 0.6 { continue }
            a.damage += dmg
            let maxD = itemDef(a.id).armor?.durability ?? 100
            if a.damage >= maxD {
                armor[i] = nil
                world.hooks.playSound("entity.item.break", x, y, z, 1, 1)
            } else {
                armor[i] = a
            }
        }
    }

    open func die(_ source: String, _ attacker: Entity? = nil) {
        if deathTime > 0 { return }
        health = 0
        deathTime = 1
        catalystBloomPending = true
        world.hooks.playSound(deathSound(), x, y, z, 1, 1)
        if world.rule("doMobLoot") {
            let looting = (attacker as? LivingEntity)?.mainHand.map { enchLevel($0, "looting") } ?? 0
            dropLoot(looting, lastHurtByPlayerTime > 0)
        }
        if let player = attacker as? Player, player.rpgClassesEnabled(), player.rpg.created, self !== player {
            _ = player.awardRPGXP(max(1, xpReward))
        }
    }

    open override func onLand(_ fallDistance: Double) {
        if !world.rule("fallDamage") { return }
        if hasEffect("slow_falling") { return }
        let ground = groundBlock() >> 4
        var dmg = (fallDistance - 3 - Double(effectLevel("jump_boost"))).rounded(.up)
        if ground == Int(B.hay_block) { dmg = (dmg * 0.2).rounded(.up) }
        if ground == Int(B.slime_block) || ground == Int(B.honey_block) { dmg = 0 }
        if ground == Int(B.pointed_dripstone) { dmg = (fallDistance * 2 - 2).rounded(.up) }
        if ground >= 0 && ground < blockDefs.count && blockDefs[ground].shape == .bed { dmg = (dmg * 0.5).rounded(.up) }
        dmg *= fallDamageMultiplier(for: fallDistance)
        if dmg > 0 {
            hurt(dmg, fallDistance > 5 ? "fall_high" : "fall")
            let cell = groundBlock()
            world.hooks.playSound(dmg > 4 ? "entity.generic.big_fall" : "entity.generic.small_fall", x, y, z, 1, 1)
            // farmland trample
            if (cell >> 4) == Int(B.farmland) && world.rule("mobGriefing") {
                world.setBlock(ifloor(x), ifloor(y - 0.35), ifloor(z), Int(B.dirt) << 4)
            }
            // turtle egg trample
            if (cell >> 4) == Int(B.turtle_egg) && rng.chance(0.7) {
                world.breakBlockNaturally(ifloor(x), ifloor(y - 0.35), ifloor(z))
            }
        }
    }

    open func fallDamageMultiplier(for fallDistance: Double) -> Double { 1 }

    /// loot drops — override per mob
    open func dropLoot(_ looting: Int, _ byPlayer: Bool) {
        for d in drops() {
            let chance = d.chance ?? 1
            if rng.nextFloat() > chance + Double(looting) * (d.lootingBonus ?? 0.01) { continue }
            let mn = d.min ?? 1
            let mx = (d.max ?? mn) + (d.lootingBonus != nil ? rng.nextInt(looting + 1) : 0)
            let count = mn + rng.nextInt(max(1, mx - mn + 1))
            if count > 0 && itemExists(d.item) { dropStack(ItemStack(iid(d.item), count)) }
        }
    }
    open func drops() -> [DropEntry] { [] }

    public func dropStack(_ stack: ItemStack) {
        spawnItemFn?(world, x, y + height / 2, z, stack,
                     (rng.nextFloat() - 0.5) * 0.1, 0.2, (rng.nextFloat() - 0.5) * 0.1)
    }

    open func hurtSound() -> String { "entity.\(type).hurt" }
    open func deathSound() -> String { "entity.\(type).death" }
    open func ambientSound() -> String? { "entity.\(type).ambient" }

    // ---- movement -----------------------------------------------------------
    public func effectiveSpeed() -> Double {
        var s = speed
        s *= 1 + 0.2 * Double(effectLevel("speed"))
        s *= max(0.1, 1 - 0.15 * Double(effectLevel("slowness")))
        if sprinting { s *= 1.3 }
        if sneaking { s *= 0.3 }
        // soul speed / soul sand
        let ground = groundBlock() >> 4
        if ground == Int(B.soul_sand) {
            let soulSpeed = armor[3].map { enchLevel($0, "soul_speed") } ?? 0
            s *= soulSpeed > 0 ? 1 + 0.3 * Double(soulSpeed) : 0.4
        }
        if sneaking, let legs = armor[2] {
            let swift = enchLevel(legs, "swift_sneak")
            if swift > 0 { s *= 1 + 0.5 * Double(swift) }
        }
        return s
    }

    /// vanilla-style travel physics; call each tick with intent set
    public func travel() {
        let inWater = self.inWater, inLava = self.inLava
        let slipperinessBlock = world.getBlock(ifloor(x), ifloor(y - 0.5), ifloor(z)) >> 4
        let slip: Double = onGround
            ? (slipperinessBlock == Int(B.ice) || slipperinessBlock == Int(B.packed_ice) || slipperinessBlock == Int(B.frosted_ice) ? 0.98
                : slipperinessBlock == Int(B.blue_ice) ? 0.989
                : slipperinessBlock == Int(B.slime_block) ? 0.8 : 0.6)
            : 0.91

        if inWater {
            let depthStrider = armor[3].map { enchLevel($0, "depth_strider") } ?? 0
            var waterSpeed = 0.02 + Double(depthStrider) * 0.01 * (onGround ? 1 : 0.5)
            if hasEffect("dolphins_grace") { waterSpeed *= 3 }
            applyInput(waterSpeed)
            move(vx, vy, vz)
            vx *= 0.8; vy *= 0.8; vz *= 0.8
            if !noGravity { vy -= 0.02 * gravityScale }
            if jumping { vy = min(vy + 0.04, 0.2) }
            if horizontalCollision && isClimbing() { vy = 0.2 }
        } else if inLava {
            applyInput(0.02)
            move(vx, vy, vz)
            vx *= 0.5; vy *= 0.5; vz *= 0.5
            if !noGravity { vy -= 0.02 }
            if jumping { vy = min(vy + 0.04, 0.2) }
        } else {
            let accel = onGround ? effectiveSpeed() * (0.21600002 / (slip * slip * slip)) : 0.02 + (sprinting ? 0.006 : 0)
            applyInput(accel)
            if isClimbing() {
                vx = clampD(vx, -0.15, 0.15)
                vz = clampD(vz, -0.15, 0.15)
                if vy < -0.15 { vy = -0.15 }
                if sneaking && vy < 0 { vy = 0 }
                if horizontalCollision || jumping { vy = 0.2 }
            }
            move(vx, vy, vz)
            if !noGravity {
                var g = 0.08 * gravityScale
                if hasEffect("slow_falling") && vy <= 0 { g = 0.01 }
                vy -= g
            }
            vy *= 0.98
            vx *= slip * 0.91
            vz *= slip * 0.91
            // jump
            if jumping && onGround {
                vy = jumpPower + Double(effectLevel("jump_boost")) * 0.1
                if sprinting {
                    vx += -detSin(yaw) * 0.2
                    vz += detCos(yaw) * 0.2
                }
                onGround = false
            }
        }
        // limb animation
        let dxm = x - prevX, dzm = z - prevZ
        let moved = min(1, (dxm * dxm + dzm * dzm).squareRoot() * 4)
        limbAmp += (moved - limbAmp) * 0.4
        limbSwing += limbAmp * 1.2
    }

    func applyInput(_ accel: Double) {
        var f = moveForward, s = moveStrafe
        let len = (f * f + s * s).squareRoot()
        if len < 0.01 { return }
        if len > 1 { f /= len; s /= len }
        let sn = detSin(yaw), cs = detCos(yaw)
        vx += (s * cs - f * sn) * accel
        vz += (f * cs + s * sn) * accel
    }

    open func tickDeath() {
        deathTime += 1
        if deathTime >= 20 {
            // XP burst
            if lastHurtByPlayerTime > 0, let spawnXP = spawnXPFn {
                spawnXP(world, x, y + height / 2, z, xpReward)
            }
            world.hooks.addParticles("explosion", x, y + height / 2, z, 6, width, 0)
            remove()
        }
    }

    public func baseLivingTick() {
        baseTick()
        if hurtTime > 0 { hurtTime -= 1 }
        if lastHurtByPlayerTime > 0 { lastHurtByPlayerTime -= 1 }
        if attackAnim > 0 { attackAnim = max(0, attackAnim - 0.125) }
        tickEffects()
        if deathTime > 0 { tickDeath(); return }
        // drowning
        if underwater && !breathesWater && !hasEffect("water_breathing") && !hasEffect("conduit_power") {
            let respiration = armor[0].map { enchLevel($0, "respiration") } ?? 0
            if respiration == 0 || rng.nextFloat() < 1 / Double(respiration + 1) { airSupply -= 1 }
            if airSupply <= -20 {
                airSupply = 0
                if world.rule("drowningDamage") { hurt(2, "drown") }
            }
        } else if breathesWaterOnly && !inWater {
            airSupply -= 1
            if airSupply <= -20 { airSupply = 0; hurt(2, "drown") }
        } else {
            airSupply = min(300, airSupply + 4)
        }
        // body yaw follows movement
        let dxm = x - prevX, dzm = z - prevZ
        if dxm * dxm + dzm * dzm > 0.0025 {
            let moveYaw = detAtan2(-dxm, dzm)
            var d = moveYaw - bodyYaw
            while d > .pi { d -= .pi * 2 }
            while d < -.pi { d += .pi * 2 }
            bodyYaw += d * 0.3
        } else {
            var d = yaw - bodyYaw
            while d > .pi { d -= .pi * 2 }
            while d < -.pi { d += .pi * 2 }
            if abs(d) > 0.9 { bodyYaw += d * 0.2 }
        }
        headYaw = yaw
        pushEntities()
    }

    /// vanilla Entity.push — overlapping living entities shove each other apart
    /// (the missing piece that let the player walk straight through mobs)
    func pushEntities() {
        if dead || vehicle != nil { return }
        if let p = self as? Player, p.flying { return }
        for e in world.entities {
            guard let other = e as? LivingEntity, other !== self, !other.dead,
                  other.deathTime == 0, other.vehicle !== self else { continue }
            let rx = (width + other.width) * 0.5
            if abs(other.x - x) >= rx || abs(other.z - z) >= rx { continue }
            if other.y >= y + height || y >= other.y + other.height { continue }
            var dx = other.x - x
            var dz = other.z - z
            var d = max(abs(dx), abs(dz))
            if d >= 0.01 {
                d = d.squareRoot()
                dx /= d
                dz /= d
                let scale = min(1.0, 1.0 / d) * 0.05
                other.vx += dx * scale
                other.vz += dz * scale
                vx -= dx * scale
                vz -= dz * scale
            }
        }
    }
}

// late-bound spawners to avoid import cycles (set by Misc.swift registration)
public var spawnItemFn: ((World, Double, Double, Double, ItemStack, Double, Double, Double) -> Void)?
public var spawnXPFn: ((World, Double, Double, Double, Int) -> Void)?
public func bindSpawners(
    _ item: ((World, Double, Double, Double, ItemStack, Double, Double, Double) -> Void)?,
    _ xp: ((World, Double, Double, Double, Int) -> Void)?
) {
    spawnItemFn = item
    spawnXPFn = xp
}
