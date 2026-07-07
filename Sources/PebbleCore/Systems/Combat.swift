// Combat — player attacks (1.9 cooldown, crits,
// sweeping, knockback, fire aspect), mob ranged-attack bindings, evoker
// fangs, lightning conversions, breaking and harvesting math.

import Foundation

private func typeMatchesAny(_ type: String, _ words: [String]) -> Bool {
    words.contains { type.contains($0) }
}

// ---------------------------------------------------------------------------
// Player melee attack
// ---------------------------------------------------------------------------
public func playerAttack(_ player: Player, _ target: Entity) {
    let strength = player.attackStrength()
    player.resetAttackCooldown()
    player.attackAnim = 1
    player.lastHurtTarget = target

    let held = player.mainHand
    let tool = held.map { itemDef($0.id).tool } ?? nil
    var dmg = 1 + (tool?.attackDamage ?? 0)
    if player.rpgClassesEnabled(), player.rpg.created {
        dmg += rpgDerivedStats(player.rpg).meleeDamageBonus
    }
    // enchants
    if let held {
        dmg += Double(enchLevel(held, "sharpness")) * 0.5 + (enchLevel(held, "sharpness") > 0 ? 0.5 : 0)
        if typeMatchesAny(target.type, ["zombie", "skeleton", "wither", "phantom", "drowned", "husk", "stray", "zoglin"]) {
            dmg += Double(enchLevel(held, "smite")) * 2.5
        }
        if typeMatchesAny(target.type, ["spider", "silverfish", "endermite", "bee"]) {
            dmg += Double(enchLevel(held, "bane_of_arthropods")) * 2.5
        }
    }
    dmg += 3 * Double(player.effectLevel("strength"))
    dmg -= 4 * Double(player.effectLevel("weakness"))
    // cooldown scaling
    dmg *= 0.2 + strength * strength * 0.8

    // crit: falling, not sprinting, full strength
    let crit = strength > 0.9 && player.fallDistance > 0 && !player.onGround && !player.inWater && !player.sprinting && !player.hasEffect("blindness")
    if crit {
        dmg *= 1.5
        player.world.hooks.addParticles("crit", target.x, target.y + target.height * 0.7, target.z, 10, 0.4, 0)
        player.world.hooks.playSound("entity.player.attack.crit", player.x, player.y, player.z, 0.8, 1)
    } else if strength > 0.9 {
        player.world.hooks.playSound("entity.player.attack.strong", player.x, player.y, player.z, 0.8, 1)
    } else {
        player.world.hooks.playSound("entity.player.attack.weak", player.x, player.y, player.z, 0.6, 1)
    }

    let hurt = target.hurt(max(0, dmg), "mob", player)
    if hurt {
        // knockback enchant + sprint knockback (capture sprint state first —
        // the kb branch clears it, and the sweep gate below must see it)
        let wasSprinting = player.sprinting
        let kb = (held.map { enchLevel($0, "knockback") } ?? 0) + (wasSprinting ? 1 : 0)
        if kb > 0 {
            target.vx += -detSin(player.yaw) * Double(kb) * 0.4
            target.vz += detCos(player.yaw) * Double(kb) * 0.4
            player.sprinting = false
        }
        // fire aspect
        let fa = held.map { enchLevel($0, "fire_aspect") } ?? 0
        if fa > 0 { target.fireTicks = max(target.fireTicks, fa * 80) }
        // thorns on target
        if let liv = target as? LivingEntity {
            var thorns = 0
            for a in liv.armor { if let a { thorns += enchLevel(a, "thorns") } }
            if thorns > 0 && gameRng.nextFloat() < Double(thorns) * 0.15 {
                player.hurt(Double(1 + gameRng.nextInt(4)), "thorns", target)
            }
        }
        // sweeping (sword, full strength, on ground-ish)
        if tool?.type == "sword" && strength > 0.9 && !crit && !wasSprinting && player.onGround {
            let sweepLvl = held.map { enchLevel($0, "sweeping_edge") } ?? 0
            let sweepDmg = 1 + (sweepLvl > 0 ? dmg * Double(sweepLvl) / Double(sweepLvl + 1) : 0)
            for e in player.world.getEntitiesNear(target.x, target.y, target.z, 1.5) {
                guard let other = e as? LivingEntity, other !== target, other !== player else { continue }
                other.hurt(sweepDmg, "mob", player)
            }
            player.world.hooks.addParticles("sweep", player.x - detSin(player.yaw) * 1.5, player.y + 1.1, player.z + detCos(player.yaw) * 1.5, 1, 0, 0)
            player.world.hooks.playSound("entity.player.attack.sweep", player.x, player.y, player.z, 0.8, 1)
        }
        // durability
        if held != nil, let tool {
            player.damageHeld(tool.type == "sword" || tool.type == "trident" ? 1 : 2)
        }
        player.addExhaustion(0.1)
    }
}

// ---------------------------------------------------------------------------
// Bow / crossbow shooting (player)
// ---------------------------------------------------------------------------
public func shootBow(_ player: Player, _ chargeTicks: Int) {
    guard let held = player.mainHand else { return }
    var power = Double(chargeTicks) / 20
    power = (power * power + power * 2) / 3
    if power < 0.1 { return }
    if power > 1 { power = 1 }

    let infinity = enchLevel(held, "infinity") > 0
    let hasArrow = player.gameMode == 1 || infinity || player.countItem(iid("arrow")) > 0 ||
        player.countItem(iid("spectral_arrow")) > 0 || player.countItem(iid("tipped_arrow")) > 0
    if !hasArrow { return }

    // find arrow type
    var arrowItem = "arrow"
    var potionId: String? = nil
    for name in ["tipped_arrow", "spectral_arrow", "arrow"] {
        if player.countItem(iid(name)) > 0 {
            arrowItem = name
            break
        }
    }
    if arrowItem == "tipped_arrow" {
        for s in player.inventory {
            if let s, s.id == iid("tipped_arrow") { potionId = s.data.potion; break }
        }
    }
    if player.gameMode != 1 && !(infinity && arrowItem == "arrow") {
        player.removeItems(iid(arrowItem), 1)
    }

    let arrow = ArrowEntity(world: player.world)
    arrow.shootFrom(player, player.pitch, player.yaw, power * 3, 1)
    arrow.damage = 2 + Double(enchLevel(held, "power")) * 0.5 + (enchLevel(held, "power") > 0 ? 0.5 : 0)
    arrow.critical = power >= 1
    arrow.punchLevel = enchLevel(held, "punch")
    arrow.flame = enchLevel(held, "flame") > 0
    arrow.potionId = potionId
    arrow.spectral = arrowItem == "spectral_arrow"
    arrow.pickupable = !(infinity && arrowItem == "arrow") && player.gameMode != 1
    player.world.addEntity(arrow)
    player.world.hooks.playSound("entity.arrow.shoot", player.x, player.y, player.z, 1, 1 / (Double.random(in: 0..<1) * 0.4 + 1.2) + power * 0.5)
    player.damageHeld(1)
    player.stats["arrowsShot"] = (player.stats["arrowsShot"] ?? 0) + 1
}

public func throwTridentPlayer(_ player: Player, _ chargeTicks: Int) {
    guard let held = player.mainHand, chargeTicks >= 10 else { return }
    let riptide = enchLevel(held, "riptide")
    if riptide > 0 {
        if !player.inWater && player.world.rainLevel < 0.2 { return }
        // launch player
        let lookX = -detSin(player.yaw) * detCos(player.pitch)
        let lookY = -detSin(player.pitch)
        let lookZ = detCos(player.yaw) * detCos(player.pitch)
        let f = 1.5 * Double(1 + riptide) / 4
        player.vx += lookX * f * 2
        player.vy += lookY * f * 2
        player.vz += lookZ * f * 2
        player.damageHeld(1)
        player.world.hooks.playSound("item.trident.riptide_1", player.x, player.y, player.z, 1, 1)
        return
    }
    let trident = TridentEntity(world: player.world)
    trident.shootFrom(player, player.pitch, player.yaw, 2.5, 1)
    trident.stack = held.copy()
    trident.loyalty = enchLevel(held, "loyalty")
    player.world.addEntity(trident)
    player.world.hooks.playSound("item.trident.throw", player.x, player.y, player.z, 1, 1)
    player.consumeHeld(1)
}

// ---------------------------------------------------------------------------
// Evoker fangs: delayed bite at position
// ---------------------------------------------------------------------------
private var fangQueue: [(world: World, x: Double, y: Double, z: Double, time: Int, owner: Entity)] = []

public func tickFangs(_ world: World) {
    tickPendingTimeouts(world)
    var i = fangQueue.count - 1
    while i >= 0 {
        let f = fangQueue[i]
        if f.world !== world { i -= 1; continue }
        if world.time >= f.time {
            fangQueue.remove(at: i)
            // snap to ground
            var gy = ifloor(f.y)
            for _ in 0..<4 {
                if (world.getBlock(ifloor(f.x), gy - 1, ifloor(f.z)) >> 4) != 0 { break }
                gy -= 1
            }
            world.hooks.addParticles("crit", f.x, Double(gy) + 0.3, f.z, 8, 0.3, 0)
            world.hooks.playSound("entity.evoker_fangs.attack", f.x, Double(gy), f.z, 1, 1)
            for e in world.getEntitiesNear(f.x, Double(gy) + 0.5, f.z, 1.2) {
                guard let liv = e as? LivingEntity, liv !== f.owner else { continue }
                liv.hurt(6, "magic", f.owner)
            }
        }
        i -= 1
    }
}

// ---------------------------------------------------------------------------
// Mining math
// ---------------------------------------------------------------------------
public func breakSpeed(_ player: Player, _ cellVal: Int) -> Double {
    let bid = cellVal >> 4
    let def = blockDefs[bid]
    if def.hardness < 0 { return 0 }
    if def.hardness == 0 { return .infinity }
    let held = player.mainHand
    let tool = held.map { itemDef($0.id).tool } ?? nil
    var speed = 1.0
    let matches = tool != nil && (tool!.type == def.tool.rawValue ||
        (tool!.type == "sword" && (bid == Int(B.cobweb) || bid == Int(B.bamboo))) ||
        (tool!.type == "shears" && (def.tool == .shears || def.name.contains("leaves") || def.name.contains("wool"))))
    if matches, let tool {
        speed = tool.speed
        let eff = held.map { enchLevel($0, "efficiency") } ?? 0
        if eff > 0 { speed += Double(eff * eff + 1) }
    }
    if player.hasEffect("haste") { speed *= 1 + 0.2 * Double(player.effectLevel("haste")) }
    if player.hasEffect("mining_fatigue") {
        // exact 0.3^n via repeated multiply (Math.pow is engine-specific)
        var fatigue = 1.0
        for _ in 0..<min(4, player.effectLevel("mining_fatigue")) { fatigue *= 0.3 }
        speed *= fatigue
    }
    if player.underwater && !(player.armor[0] != nil && enchLevel(player.armor[0]!, "aqua_affinity") > 0) { speed /= 5 }
    if !player.onGround { speed /= 5 }

    let canHarvestNow = !def.requiresTool || (matches && (tool?.tier ?? 0) >= def.tier)
    let divisor: Double = canHarvestNow ? 30 : 100
    return speed / def.hardness / divisor
}

public func canHarvest(_ player: Player, _ cellVal: Int) -> Bool {
    let bid = cellVal >> 4
    let def = blockDefs[bid]
    if !def.requiresTool { return true }
    guard let held = player.mainHand, let tool = itemDef(held.id).tool else { return false }
    let matches = tool.type == def.tool.rawValue || (tool.type == "sword" && bid == Int(B.cobweb))
    return matches && tool.tier >= def.tier
}

// ---------------------------------------------------------------------------
// Bindings (baseline runs these at module import; Swift registers explicitly)
// ---------------------------------------------------------------------------
public func registerCombatBindings() {
    bindShootArrow { from, at, power, damage in
        let arrow = ArrowEntity(world: from.world)
        let dx = at.x - from.x
        let dy = at.y + at.height / 3 - (from.y + from.height * 0.85)
        let dz = at.z - from.z
        let horiz = detHyp(dx, dz)
        arrow.setPos(from.x, from.y + from.height * 0.85, from.z)
        arrow.owner = from
        arrow.shoot(dx, dy + horiz * 0.2, dz, 1.6, Double(14 - from.world.difficulty * 4))
        arrow.damage = damage / 2
        arrow.pickupable = false
        from.world.addEntity(arrow)
        from.world.hooks.playSound("entity.skeleton.shoot", from.x, from.y, from.z, 1, 1)
    }

    bindThrowTrident { from, at in
        let t = TridentEntity(world: from.world)
        let dx = at.x - from.x, dy = at.eyeY() - (from.y + from.height * 0.85), dz = at.z - from.z
        t.setPos(from.x, from.y + from.height * 0.85, from.z)
        t.owner = from
        t.shoot(dx, dy + detHyp(dx, dz) * 0.15, dz, 1.6, 6)
        t.stack = nil
        from.world.addEntity(t)
        from.world.hooks.playSound("item.trident.throw", from.x, from.y, from.z, 1, 1)
    }

    bindThrowSnowball { from, at in
        let s = ThrownSnowball(world: from.world)
        let dx = at.x - from.x, dy = at.eyeY() - 1 - (from.y + from.height * 0.85), dz = at.z - from.z
        s.setPos(from.x, from.y + from.height * 0.85, from.z)
        s.owner = from
        s.shoot(dx, dy + detHyp(dx, dz) * 0.12, dz, 1.5, 10)
        from.world.addEntity(s)
        from.world.hooks.playSound("entity.snowball.throw", from.x, from.y, from.z, 1, 0.6)
    }

    bindSpit { from, at in
        let s = LlamaSpit(world: from.world)
        let dx = at.x - from.x, dy = at.eyeY() - (from.y + from.height * 0.85), dz = at.z - from.z
        s.setPos(from.x, from.y + from.height * 0.85, from.z)
        s.owner = from
        s.shoot(dx, dy + detHyp(dx, dz) * 0.1, dz, 1.5, 8)
        from.world.addEntity(s)
        from.world.hooks.playSound("entity.llama.spit", from.x, from.y, from.z, 1, 1)
    }

    bindFangs { world, x, y, z, delay, owner in
        fangQueue.append((world: world, x: x, y: y, z: z, time: world.time + delay, owner: owner))
    }

    bindSpawnLightning { world, x, y, z in
        let bolt = LightningBolt(world: world)
        bolt.setPos(x, y, z)
        world.addEntity(bolt)
    }

    bindLightningConversion { e in
        let t = e.type
        let w = e.world
        if t == "pig" {
            let zp = spawnMob(w, "zombified_piglin", e.x, e.y, e.z, SpawnOpts())
            if zp != nil { e.remove() }
        } else if t == "creeper" {
            (e as? Creeper)?.charged = true
            e.data.charged = true
        } else if t == "villager" {
            let witch = spawnMob(w, "witch", e.x, e.y, e.z, SpawnOpts())
            if witch != nil { e.remove() }
        } else if t == "mooshroom" {
            // toggles brown/red — flavor
            e.data.brown = !(e.data.brown ?? false)
        }
    }
}
