// Bosses — the Warden (vibration-driven, sonic
// boom, darkness), the Ender Dragon (phase machine, crystal healing, perch +
// breath), and the Wither (summon charge-up, skull volleys, armor phase,
// block breaking).

import Foundation

// =============================================================================
// WARDEN
// =============================================================================
public final class Warden: Monster {
    public override var type: String { "warden" }
    public var anger: [Int: Int] = [:]   // entity id → anger
    public var sonicCharge = 0
    public var sniffCooldown = 0
    public var diggingOut = 60
    public var emerging = true
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 2.9
        maxHealth = 500; health = 500
        speed = 0.13
        attackDamage = 30
        kbResist = 1
        persistent = true
        xpReward = 5
        goals.add(FloatGoal(self, 0))
        goals.add(MeleeAttackGoal(self, 2, 1.2))
        goals.add(StrollGoal(self, 6, 0.6))
    }
    /// vibration event from the world
    public func hearVibration(_ x: Double, _ y: Double, _ z: Double, _ srcEntity: Entity?) {
        if dead { return }
        let dx = x - self.x, dy = y - self.y, dz = z - self.z
        let d = (dx * dx + dy * dy + dz * dz).squareRoot()
        if d > 24 { return }
        if let src = srcEntity as? LivingEntity {
            addAnger(src, 35)
        }
        // investigate location
        if target == nil {
            nav.moveTo(x, y, z, 1.1)
            world.hooks.playSound("entity.warden.listening", self.x, self.y, self.z, 2, 1)
        }
    }
    public func addAnger(_ e: Entity, _ amount: Int) {
        let cur = (anger[e.id] ?? 0) + amount
        anger[e.id] = cur
        if cur >= 80, let living = e as? LivingEntity {
            setTarget(living)
            world.hooks.playSound("entity.warden.angry", x, y, z, 3, 1)
        }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let r = super.hurt(amount, source, attacker)
        if r, let attacker { addAnger(attacker, 100) }
        return r
    }
    public override func tick() {
        if emerging {
            diggingOut -= 1
            if age % 5 == 0 {
                world.hooks.addParticles("block", x, y + 0.5, z, 8, 0.8, Int(cell(B.sculk)))
                world.hooks.playSound("entity.warden.dig", x, y, z, 1, 1)
            }
            if diggingOut <= 0 {
                emerging = false
                world.hooks.playSound("entity.warden.emerge", x, y, z, 3, 1)
            }
            baseLivingTick()
            return
        }
        super.tick()
        // darkness pulse
        if age % 120 == 0 {
            for p in world.getEntitiesNear(x, y, z, 20, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                (p as? LivingEntity)?.addEffect("darkness", 260, 0)
            }
            world.hooks.playSound("entity.warden.heartbeat", x, y, z, 3, 0.8)
        }
        // sniff for players when no target
        if target == nil {
            sniffCooldown -= 1
            if sniffCooldown <= 0 {
                sniffCooldown = 100
                let players = world.getEntitiesNear(x, y, z, 16) { e in
                    guard let p = e as? LivingEntity else { return false }
                    return p.isPlayer && !p.sneaking
                }
                if let p = players.first as? LivingEntity {
                    world.hooks.playSound("entity.warden.sniff", x, y, z, 2, 1)
                    addAnger(p, 20)
                    nav.moveTo(p.x, p.y, p.z, 1)
                }
            }
        }
        // sonic boom when target unreachable or far
        if let t = target, !t.dead {
            let dSq = distanceToSq(t)
            if dSq > 9 && dSq < 240 && age % 10 == 0 && (nav.isDone() || dSq > 60) {
                sonicCharge += 1
                if sonicCharge == 2 { world.hooks.playSound("entity.warden.sonic_charge", x, y, z, 3, 1) }
                if sonicCharge >= 4 {
                    sonicCharge = 0
                    // sonic boom: pierce armor
                    world.hooks.playSound("entity.warden.sonic_boom", x, y, z, 3, 1)
                    let steps = 12
                    for i in 1...steps {
                        let f = Double(i) / Double(steps)
                        world.hooks.addParticles("sculk_soul",
                                                 x + (t.x - x) * f, y + 1.6 + (t.eyeY() - y - 1.6) * f, z + (t.z - z) * f, 1, 0.05, 0)
                    }
                    t.hurt(10, "sonic", self)
                    t.vx += (t.x - x) * 0.15
                    t.vy += 0.5
                    t.vz += (t.z - z) * 0.15
                }
            }
        }
        // calm down over time
        if age % 20 == 0 {
            for (id, a) in anger {
                if a <= 1 { anger.removeValue(forKey: id) }
                else { anger[id] = a - 1 }
            }
        }
    }
    public override func drops() -> [DropEntry] { [DropEntry("sculk_catalyst")] }
}

// =============================================================================
// ENDER DRAGON
// =============================================================================
public final class EnderDragon: LivingEntity {
    public override var type: String { "ender_dragon" }
    public var phase = "circling"   // circling | strafing | approach_perch | perched | takeoff | charging | dying
    public var phaseTime = 0
    public var pathAngle = 0.0
    public var pathRadius = 50.0
    public var pathHeight = 80.0
    public var deathAnimTime = 0
    public var breathTime = 0
    /// set by Game: callback when dragon dies (portal activation)
    public var onDeath: ((EnderDragon) -> Void)? = nil
    public override init(world: World) {
        super.init(world: world)
        pathAngle = gameRng.nextFloat() * .pi * 2   // baseline field-init order
        width = 8; height = 3
        maxHealth = 200; health = 200
        noGravity = true
        kbResist = 1
        persistent = true
        xpReward = 12000
    }
    public override func tick() {
        prevX = x; prevY = y; prevZ = z
        prevYaw = yaw
        age += 1
        phaseTime += 1
        if hurtTime > 0 { hurtTime -= 1 }
        if invulnTicks > 0 { invulnTicks -= 1 }

        if phase == "dying" {
            deathAnimTime += 1
            vy = 0.08
            y += vy
            if age % 3 == 0 {
                world.hooks.addParticles("explosion", x + (Double.random(in: 0..<1) - 0.5) * 8, y + Double.random(in: 0..<1) * 3, z + (Double.random(in: 0..<1) - 0.5) * 8, 2, 1, 0)
            }
            if deathAnimTime % 10 == 0 {
                spawnXP(world, x, 70, z, 500)
                world.hooks.playSound("entity.generic.explode", x, y, z, 4, 0.8)
            }
            if deathAnimTime >= 120 {
                spawnXP(world, 0.5, 70, 0.5, 6000)
                onDeath?(self)
                remove()
            }
            return
        }

        // crystal healing
        if age % 10 == 0 {
            for e in world.entities {
                guard let c = e as? EndCrystal, !c.dead else { continue }
                let dSq = distanceToSq(c)
                if dSq < 32 * 32 {
                    heal(1)
                    c.beamTarget = (Int(x), Int(y + 1), Int(z))
                } else if let bt = c.beamTarget {
                    let ddx = Double(bt.0) - x, ddz = Double(bt.2) - z
                    if (ddx * ddx + ddz * ddz).squareRoot() < 12 {
                        c.beamTarget = nil
                    }
                }
            }
        }

        let nearestPlayer = findPlayer()

        switch phase {
        case "circling":
            pathAngle += 0.012
            let tx = detCos(pathAngle) * pathRadius
            let tz = detSin(pathAngle) * pathRadius
            let ty = pathHeight + detSin(Double(age) * 0.02) * 6
            flyToward(tx, ty, tz, 0.06)
            if phaseTime > 200 && gameRng.nextFloat() < 0.01 {
                setPhase(gameRng.nextFloat() < 0.5 ? "strafing" : (gameRng.nextFloat() < 0.35 ? "approach_perch" : "charging"))
            }
        case "strafing":
            guard let p = nearestPlayer else { setPhase("circling"); break }
            flyToward(p.x, p.y + 18, p.z, 0.07)
            let dSq = distanceToSq(p)
            if dSq < 30 * 30 {
                // fireball
                let fb = DragonFireball(world: world)
                fb.setPos(x, y - 1, z)
                fb.owner = self
                fb.shoot(p.x - x, p.eyeY() - y + 1, p.z - z, 0.6, 2)
                world.addEntity(fb)
                world.hooks.playSound("entity.ender_dragon.shoot", x, y, z, 4, 1)
                setPhase("circling")
            }
            if phaseTime > 200 { setPhase("circling") }
        case "approach_perch":
            flyToward(0, 70, 0, 0.08)
            if (x * x + z * z).squareRoot() < 8 && y < 74 {
                setPhase("perched")
                vx = 0; vy = 0; vz = 0
                setPosToFountain()
                world.hooks.playSound("entity.ender_dragon.growl", x, y, z, 5, 0.8)
            }
        case "perched":
            // breath attack at near players, vulnerable to melee
            if let p = nearestPlayer, distanceToSq(p) < 400, phaseTime > 25 {
                lookAt(p.x, p.y, p.z, 0.2, 0.2)
                breathTime += 1
                if breathTime > 10 && breathTime % 4 == 0 {
                    // breath cloud toward player
                    let dx = p.x - x, dz = p.z - z
                    var d = (dx * dx + dz * dz).squareRoot()
                    if d == 0 { d = 1 }
                    let px = x + dx / d * 6
                    let pz = z + dz / d * 6
                    world.hooks.addParticles("dragon_breath", px, 65, pz, 6, 1.2, 0)
                    for pp in world.getEntitiesNear(px, 64, pz, 3, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                        (pp as? Entity)?.hurt(3, "magic", self)
                    }
                }
            }
            if phaseTime > 220 || (hurtTime > 0 && phaseTime > 60) {
                setPhase("takeoff")
            }
        case "takeoff":
            flyToward(detCos(pathAngle) * 50, 90, detSin(pathAngle) * 50, 0.08)
            if phaseTime > 60 { setPhase("circling") }
        case "charging":
            guard let p = nearestPlayer else { setPhase("circling"); break }
            flyToward(p.x, p.y, p.z, 0.12)
            // damage players hit
            for pp in world.getEntitiesNear(x, y, z, 5, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                guard let pe = pp as? Entity else { continue }
                pe.hurt(10, "mob", self)
                pe.vx += vx * 2
                pe.vy += 0.6
                pe.vz += vz * 2
            }
            if phaseTime > 100 || distanceToSq(p) < 9 { setPhase("circling") }
        default:
            break
        }

        x += vx; y += vy; z += vz
        if phase != "perched" {
            yaw = detAtan2(-vx, vz)
        }
        // destroy blocks the dragon passes through (except end-grade blocks)
        if world.rule("mobGriefing") && age % 4 == 0 && phase != "perched" {
            let bx = ifloor(x), by = ifloor(y + 1), bz = ifloor(z)
            for dy in -1...2 {
                for dz in -3...3 {
                    for dx in -3...3 {
                        let c = world.getBlock(bx + dx, by + dy, bz + dz)
                        let bid = c >> 4
                        if bid != 0 && bid != Int(B.obsidian) && bid != Int(B.end_stone) && bid != Int(B.bedrock) && bid != Int(B.iron_bars) && bid != Int(B.end_portal) && bid != Int(B.end_portal_frame) && blockDefs[bid].hardness >= 0 {
                            world.setBlock(bx + dx, by + dy, bz + dz, 0)
                        }
                    }
                }
            }
        }
    }
    private func setPosToFountain() {
        x = 0.5; y = 66; z = 0.5
        yaw = gameRng.nextFloat() * .pi * 2
    }
    private func setPhase(_ p: String) {
        phase = p
        phaseTime = 0
        breathTime = 0
    }
    private func flyToward(_ tx: Double, _ ty: Double, _ tz: Double, _ accel: Double) {
        let dx = tx - x, dy = ty - y, dz = tz - z
        var d = (dx * dx + dy * dy + dz * dz).squareRoot()
        if d == 0 { d = 1 }
        let speed = phase == "charging" ? 1.3 : 0.8
        vx += (dx / d * speed - vx) * accel
        vy += (dy / d * speed - vy) * accel
        vz += (dz / d * speed - vz) * accel
    }
    private func findPlayer() -> LivingEntity? {
        var best: LivingEntity? = nil
        var bestD = Double.infinity
        for e in world.entities {
            guard let p = e as? LivingEntity, p.isPlayer, !p.dead, p.gameMode != 1 else { continue }
            let d = distanceToSq(p)
            if d < bestD { bestD = d; best = p }
        }
        return best
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if invulnTicks > 0 || phase == "dying" { return false }
        // reduced damage while flying (head hits are full — simplified: 50% while airborne)
        var dmg = amount
        if phase != "perched" { dmg *= 0.5 }
        if source == "explosion" { dmg *= 0.25 }
        health -= dmg
        hurtTime = 10
        invulnTicks = 10
        world.hooks.playSound("entity.ender_dragon.hurt", x, y, z, 4, 1)
        if health <= 0 {
            health = 0
            setPhase("dying")
            world.hooks.playSound("entity.ender_dragon.death", x, y, z, 6, 1)
        } else if phase == "perched" && gameRng.nextFloat() < 0.3 {
            setPhase("takeoff")
        }
        return true
    }
}

// =============================================================================
// WITHER
// =============================================================================
public final class WitherBoss: Monster {
    public override var type: String { "wither" }
    public var chargeTime = 220
    public var shootCooldown = [0, 0, 0]
    public override init(world: World) {
        super.init(world: world)
        width = 0.9; height = 3.5
        maxHealth = 300; health = 300
        attackDamage = 8
        noGravity = true
        kbResist = 1
        persistent = true
        xpReward = 50
        targetGoals.add(HurtByTargetGoal(self, 1))
        targetGoals.add(NearestTargetGoal(self, 2, { e in
            (e.isPlayer || (e as? Mob)?.category == "creature") && !e.dead
        }, 40, false))
    }
    public override func tick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }

        // summon charge-up
        if chargeTime > 0 {
            chargeTime -= 1
            health = min(maxHealth, health + maxHealth / 220)
            if chargeTime % 20 == 0 {
                world.hooks.playSound("entity.wither.ambient", x, y, z, 4, 0.7)
            }
            if chargeTime == 0 {
                explodeFn?(world, x, y + 1.7, z, 7, false, self)
                world.hooks.playSound("entity.wither.spawn", x, y, z, 8, 1)
            }
            return
        }

        targetGoals.tick(2, age)

        // hover toward target
        if let t = target, !t.dead {
            let ty = t.y + 5
            let dy = ty - y
            vy += clampD(dy * 0.02, -0.06, 0.06)
            let dx = t.x - x, dz = t.z - z
            let dh = (dx * dx + dz * dz).squareRoot()
            if dh > 10 {
                vx += dx / dh * 0.02
                vz += dz / dh * 0.02
            } else if dh < 5 {
                vx -= dx / dh * 0.02
                vz -= dz / dh * 0.02
            }
            yaw = detAtan2(-dx, dz)
            // shoot skulls from 3 heads
            for head in 0..<3 {
                if shootCooldown[head] > 0 { shootCooldown[head] -= 1 }
                else {
                    shootCooldown[head] = 40 + rng.nextInt(40)
                    let hx = head == 0 ? x : x + (head == 1 ? -1.3 : 1.3) * detCos(yaw)
                    let hz = head == 0 ? z : z + (head == 1 ? -1.3 : 1.3) * detSin(yaw)
                    let skull = WitherSkull(world: world)
                    skull.blue = rng.nextFloat() < 0.1
                    skull.setPos(hx, y + 3, hz)
                    skull.owner = self
                    skull.shoot(t.x - hx, t.eyeY() - (y + 3), t.z - hz, skull.blue ? 0.45 : 0.9, 4)
                    world.addEntity(skull)
                    world.hooks.playSound("entity.wither.shoot", x, y, z, 3, 1)
                }
            }
        } else {
            vy += (0.3 - vy) * 0.02
            vx *= 0.9; vz *= 0.9
        }
        move(vx, vy, vz)
        vx *= 0.95; vy *= 0.92; vz *= 0.95

        // break blocks around when hurt
        if hurtTime > 0 && world.rule("mobGriefing") && age % 10 == 0 {
            var broke = false
            for dy in 0...3 {
                for dz in -1...1 {
                    for dx in -1...1 {
                        let bx = ifloor(x) + dx, by = ifloor(y) + dy, bz = ifloor(z) + dz
                        let c = world.getBlock(bx, by, bz)
                        let bid = c >> 4
                        if bid != 0 && bid != Int(B.bedrock) && bid != Int(B.end_portal_frame) && bid != Int(B.end_portal) && blockDefs[bid].hardness >= 0 && blockDefs[bid].resistance < 1000 {
                            world.breakBlockNaturally(bx, by, bz)
                            broke = true
                        }
                    }
                }
            }
            if broke { world.hooks.playSound("entity.wither.break_block", x, y, z, 2, 1) }
        }
        // regen
        if age % 20 == 0 { heal(1) }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if chargeTime > 0 { return false }
        // armored below half health: immune to projectiles
        if health < maxHealth / 2 && source == "projectile" { return false }
        return super.hurt(amount, source, attacker)
    }
    public override func drops() -> [DropEntry] { [DropEntry("nether_star")] }
}
