// Non-living entities — dropped items, XP orbs,
// falling blocks, primed TNT, lightning bolts, end crystals, area effect
// clouds, eyes of ender.
//
// cosmetic jitter (bob phase, drop velocities, anvil-degrade chance,
// eye-of-ender survival) is deliberately nondeterministic; golden tests
// must not hash values derived from it.

import Foundation

public final class ItemEntity: Entity {
    public override var type: String { "item" }
    public var stack = ItemStack(0, 1)
    public var pickupDelay = 10
    public var lifeTime = 6000
    public var bobOffset = Double.random(in: 0..<1) * .pi * 2

    public override init(world: World) {
        super.init(world: world)
        width = 0.25
        height = 0.25
    }

    public override func tick() {
        baseTick()
        if pickupDelay > 0 { pickupDelay -= 1 }
        lifeTime -= 1
        if lifeTime <= 0 { remove(); return }

        // float up in water
        if inWater {
            vy = min(vy + 0.04, 0.06)
            vx *= 0.95; vz *= 0.95
        } else if inLava {
            let nm = itemDef(stack.id).name
            if nm == "netherite_ingot" || nm == "ancient_debris" || nm.contains("netherite") {
                vy = min(vy + 0.05, 0.08)
            } else {
                remove()
                return
            }
        } else if !noGravity {
            vy -= 0.04
        }
        move(vx, vy, vz)
        let drag = onGround ? 0.6 : 0.98
        vx *= drag; vz *= drag
        vy *= 0.98

        // merge with nearby item entities
        if age % 20 == 0 && stack.count < maxStackOf(stack) {
            for e in world.getEntitiesInBox(bb().expand(0.8, 0.5, 0.8), except: self) {
                guard let other = e as? ItemEntity, !other.dead else { continue }
                if canMerge(stack, other.stack) && stack.count + other.stack.count <= maxStackOf(stack) {
                    stack.count += other.stack.count
                    other.remove()
                }
            }
        }
        if fireTicks > 0 { remove() }
    }

    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if source == "explosion" || source == "fire" || source == "lava" { remove(); return true }
        return false
    }

    public override func save() -> [String: Any] {
        var d = super.save()
        if let enc = try? JSONEncoder().encode(stack),
           let obj = try? JSONSerialization.jsonObject(with: enc) {
            d["stack"] = obj
        }
        d["pickupDelay"] = pickupDelay
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        if let raw = d["stack"],
           let bytes = try? JSONSerialization.data(withJSONObject: raw),
           let s = try? JSONDecoder().decode(ItemStack.self, from: bytes) {
            stack = s
        } else {
            stack = ItemStack(0, 1)
        }
        pickupDelay = inum(d["pickupDelay"])
    }
}

public final class XPOrb: Entity {
    public override var type: String { "xp_orb" }
    public var amount = 1
    public var lifeTime = 6000
    public var followTarget: Entity?

    public override init(world: World) {
        super.init(world: world)
        width = 0.4
        height = 0.4
    }
    public override func tick() {
        baseTick()
        lifeTime -= 1
        if lifeTime <= 0 { remove(); return }
        if inWater { vy = min(vy + 0.03, 0.05) }
        else if !noGravity { vy -= 0.03 }
        // magnet toward player
        if age % 10 == 0 || followTarget?.dead == true {
            followTarget = nil
            let players = world.getEntitiesNear(x, y, z, 8) { e in
                ((e as? Entity)?.isPlayer ?? false) && !e.dead
            }
            if !players.isEmpty { followTarget = players[0] as? Entity }
        }
        if let t = followTarget {
            let dx = t.x - x
            let dy = t.eyeY() - 0.5 - y
            let dz = t.z - z
            let d = (dx * dx + dy * dy + dz * dz).squareRoot()
            if d < 8 {
                let f = (1 - d / 8) * 0.1
                vx += dx / d * f
                vy += dy / d * f
                vz += dz / d * f
            }
        }
        move(vx, vy, vz)
        let drag = onGround ? 0.7 : 0.98
        vx *= drag; vz *= drag
        vy *= 0.98
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["amount"] = amount
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        amount = (d["amount"] as? NSNumber)?.intValue ?? 1
    }
}

public final class FallingBlockEntity: Entity {
    public override var type: String { "falling_block" }
    public var blockCell = 0
    public override init(world: World) {
        super.init(world: world)
        width = 0.98
        height = 0.98
    }
    public override func tick() {
        baseTick()
        vy -= 0.04
        move(vx, vy, vz)
        vx *= 0.98; vy *= 0.98; vz *= 0.98
        if onGround {
            let bx = ifloor(x), by = ifloor(y + 0.01), bz = ifloor(z)
            let cur = world.getBlock(bx, by, bz)
            let curId = cur >> 4
            if curId == 0 || blockDefs[curId].replaceable || !blockDefs[curId].solid {
                // anvil damage on landing
                var placeCell = blockCell
                let bid = blockCell >> 4
                if (bid == Int(B.anvil) || bid == Int(B.chipped_anvil) || bid == Int(B.damaged_anvil)) && fallDistance > 1 {
                    // hurt entities below
                    for e in world.getEntitiesInBox(bb()) {
                        (e as? Entity)?.hurt(min(40, (fallDistance * 2).rounded(.up)), "anvil")
                    }
                    if gameRng.nextFloat() < 0.05 * fallDistance {
                        placeCell = bid == Int(B.anvil) ? Int(cell(B.chipped_anvil, blockCell & 15))
                            : bid == Int(B.chipped_anvil) ? Int(cell(B.damaged_anvil, blockCell & 15)) : 0
                    }
                    world.hooks.playSound("block.anvil.land", x, y, z, 1, 1)
                }
                if placeCell != 0 { world.setBlock(bx, by, bz, placeCell) }
            } else {
                // can't place — drop as item
                let itemId = blockToItem[blockCell >> 4]
                if itemId >= 0 { spawnItem(world, x, y, z, ItemStack(Int(itemId), 1)) }
            }
            remove()
        }
        if age > 600 {
            remove()
        }
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["blockCell"] = blockCell
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        blockCell = inum(d["blockCell"])
    }
}

public final class TNTEntity: Entity {
    public override var type: String { "tnt" }
    public var fuse = 80
    public var power = 4.0
    public var rpgControlledChargeOwnerEntityID: Int?
    public var rpgControlledChargeOwnerAuthorityID: String?
    public override init(world: World) {
        super.init(world: world)
        width = 0.98
        height = 0.98
    }
    public override func tick() {
        baseTick()
        vy -= 0.04
        move(vx, vy, vz)
        vx *= 0.98; vy *= 0.98; vz *= 0.98
        if onGround { vx *= 0.7; vz *= 0.7 }
        if age % 5 == 0 {
            world.hooks.addParticles("smoke", x, y + 1, z, 1, 0.05, 0)
        }
        fuse -= 1
        if fuse <= 0 {
            remove()
            explodeFn?(world, x, y + 0.5, z, power, true, self)
        }
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["fuse"] = fuse
        if let owner = rpgControlledChargeOwnerEntityID { d["rpgChargeOwner"] = owner }
        if let authority = rpgControlledChargeOwnerAuthorityID, rpgIsBoundedID(authority) {
            d["rpgChargeAuthority"] = authority
        }
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        fuse = (d["fuse"] as? NSNumber)?.intValue ?? 80
        rpgControlledChargeOwnerEntityID = (d["rpgChargeOwner"] as? NSNumber)?.intValue
        if let authority = d["rpgChargeAuthority"] as? String, rpgIsBoundedID(authority) {
            rpgControlledChargeOwnerAuthorityID = authority
        }
    }
}

public final class LightningBolt: Entity {
    public override var type: String { "lightning" }
    public var life = 6
    public override init(world: World) {
        super.init(world: world)
        width = 0.1; height = 12
        noGravity = true
    }
    public override func tick() {
        if age == 0 {
            world.hooks.playSound("entity.lightning_bolt.thunder", x, y, z, 6, 0.8 + Double.random(in: 0..<1) * 0.2)
            world.hooks.playSound("entity.lightning_bolt.impact", x, y, z, 2, 0.6)
            // fire + damage + mob conversion
            if world.rule("doFireTick") {
                let bx = ifloor(x), bz = ifloor(z)
                let by = world.surfaceY(bx, bz)
                if (world.getBlock(bx, by, bz) >> 4) == 0 {
                    world.setBlock(bx, by, bz, Int(cell(B.fire)))
                }
            }
            for e in world.getEntitiesNear(x, y, z, 4) {
                guard let ent = e as? Entity, ent !== self else { continue }
                struckByLightningFn?(ent)
                ent.hurt(5, "lightning")
                ent.fireTicks = max(ent.fireTicks, 160)
            }
        }
        age += 1
        if age > life { remove() }
    }
}

public final class EndCrystal: Entity {
    public override var type: String { "end_crystal" }
    public var showBottom = true
    public var beamTarget: (Int, Int, Int)? = nil
    public override init(world: World) {
        super.init(world: world)
        width = 2; height = 2
        noGravity = true
    }
    public override func tick() {
        age += 1
        // fire below
        let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
        if world.dim == .end && (world.getBlock(bx, by, bz) >> 4) == 0 {
            world.setBlock(bx, by, bz, Int(cell(B.fire)))
        }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if dead || (source == "explosion" && amount < 0) { return false }
        remove()
        explodeFn?(world, x, y + 1, z, 6, false, self)
        crystalDestroyedFn?(self, attacker)
        return true
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["showBottom"] = showBottom
        if let bt = beamTarget { d["beamTarget"] = [bt.0, bt.1, bt.2] }
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        showBottom = (d["showBottom"] as? Bool) ?? true
        if let bt = d["beamTarget"] as? [NSNumber], bt.count == 3 {
            beamTarget = (bt[0].intValue, bt[1].intValue, bt[2].intValue)
        } else {
            beamTarget = nil
        }
    }
}

public final class AreaEffectCloud: Entity {
    public override var type: String { "effect_cloud" }
    public var radius = 3.0
    public var duration = 600
    public var effectId = "instant_damage"
    public var amplifier = 0
    public var reapplyDelay = 20
    private var affected: [Int: Int] = [:]
    public var particleType = "dragon_breath"
    public override init(world: World) {
        super.init(world: world)
        width = 6; height = 0.5
        noGravity = true
    }
    public override func tick() {
        age += 1
        if age > duration { remove(); return }
        radius = max(0.5, radius - 0.005)
        if age % 2 == 0 {
            let a = Double.random(in: 0..<1) * .pi * 2
            let r = Double.random(in: 0..<1) * radius
            world.hooks.addParticles(particleType, x + detCos(a) * r, y + 0.3, z + detSin(a) * r, 1, 0.1, 0)
        }
        if age % 5 == 0 {
            for e in world.getEntitiesNear(x, y + 0.25, z, radius) {
                guard let liv = e as? LivingEntity, !liv.dead else { continue }
                let last = affected[e.id] ?? -999
                if age - last < reapplyDelay { continue }
                affected[e.id] = age
                liv.addEffect(effectId, effectId.hasPrefix("instant") ? 1 : 200, amplifier)
            }
        }
    }
}

public final class EyeOfEnderEntity: Entity {
    public override var type: String { "eye_of_ender" }
    public var targetX = 0.0, targetZ = 0.0
    public var life = 0
    public var surviveChance = 0.8
    public override init(world: World) {
        super.init(world: world)
        width = 0.25; height = 0.25
        noGravity = true
    }
    public override func tick() {
        age += 1
        life += 1
        let dx = targetX - x, dz = targetZ - z
        let d = (dx * dx + dz * dz).squareRoot()
        if d > 1 {
            vx = dx / d * 0.3
            vz = dz / d * 0.3
            vy = life < 20 ? 0.18 : (y < Double(world.surfaceY(ifloor(x), ifloor(z)) + 12) ? 0.08 : -0.02)
        } else {
            vx *= 0.8; vz *= 0.8; vy = -0.01
        }
        x += vx; y += vy; z += vz
        world.hooks.addParticles("portal", x, y, z, 2, 0.15, 0)
        if life > 60 {
            remove()
            if gameRng.nextFloat() < surviveChance {
                spawnItem(world, x, y, z, ItemStack(iid("ender_eye"), 1))
            } else {
                world.hooks.addParticles("crit", x, y, z, 12, 0.3, 0)
                world.hooks.playSound("entity.ender_eye.death", x, y, z, 1, 1)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// helpers + late binding
// ---------------------------------------------------------------------------
@discardableResult
public func spawnItem(_ world: World, _ x: Double, _ y: Double, _ z: Double, _ stack: ItemStack,
                      _ vx: Double = 0, _ vy: Double = 0.2, _ vz: Double = 0) -> ItemEntity {
    let e = ItemEntity(world: world)
    e.setPos(x, y, z)
    e.stack = stack
    e.vx = vx + (gameRng.nextFloat() - 0.5) * 0.08
    e.vy = vy
    e.vz = vz + (gameRng.nextFloat() - 0.5) * 0.08
    world.addEntity(e)
    return e
}
public func spawnXP(_ world: World, _ x: Double, _ y: Double, _ z: Double, _ amountIn: Int) {
    var amount = amountIn
    while amount > 0 {
        let size = amount > 37 ? 37 : amount > 17 ? 17 : amount > 7 ? 7 : amount > 3 ? 3 : 1
        amount -= size
        let orb = XPOrb(world: world)
        orb.setPos(x + (gameRng.nextFloat() - 0.5) * 0.5, y, z + (gameRng.nextFloat() - 0.5) * 0.5)
        orb.amount = size
        orb.vx = (gameRng.nextFloat() - 0.5) * 0.2
        orb.vy = gameRng.nextFloat() * 0.2 + 0.1
        orb.vz = (gameRng.nextFloat() - 0.5) * 0.2
        world.addEntity(orb)
    }
}

/// the original design binds the spawners at module init; Swift does it lazily via
/// registerEntityHelpers() (called from registerAllEntities()).
public func registerEntityHelpers() {
    bindSpawners({ w, x, y, z, s, vx, vy, vz in _ = spawnItem(w, x, y, z, s, vx, vy, vz) }, spawnXP)
}

public var explodeFn: ((World, Double, Double, Double, Double, Bool, Entity?) -> Void)?
public func bindExplode(_ fn: ((World, Double, Double, Double, Double, Bool, Entity?) -> Void)?) { explodeFn = fn }
public var struckByLightningFn: ((Entity) -> Void)?
public func bindLightningConversion(_ fn: ((Entity) -> Void)?) { struckByLightningFn = fn }
public var crystalDestroyedFn: ((EndCrystal, Entity?) -> Void)?
public func bindCrystalDestroyed(_ fn: ((EndCrystal, Entity?) -> Void)?) { crystalDestroyedFn = fn }
