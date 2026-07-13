// Mob AI — A* pathfinding, navigation, goal framework,
// and the standard goal library used by every mob.
//
// deterministic-semantics contracts preserved here:
//  - GoalSelector.goals sort is STABLE (a stable sort); ties keep insert order.
//  - GoalSelector.active is insertion-ordered (deterministic Set iteration order).
//  - findPath pops the lowest-f node by linear scan, first match wins ties.

import Foundation

// ---------------------------------------------------------------------------
// Pathfinding (grid A*)
// ---------------------------------------------------------------------------
public struct PathNode {
    public var x: Int, y: Int, z: Int
}

private let NEIGHBORS: [(Int, Int, Int)] = [
    (1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1),
    (1, 0, 1), (1, 0, -1), (-1, 0, 1), (-1, 0, -1),
]

func walkable(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ avoidWater: Bool) -> Bool {
    let below = world.getBlock(x, y - 1, z)
    let bid = below >> 4
    let feet = world.getBlock(x, y, z) >> 4
    let head = world.getBlock(x, y + 1, z) >> 4
    let feetOK = feet == 0 || !blockDefs[feet].solid
    let headOK = head == 0 || !blockDefs[head].solid
    if !feetOK || !headOK { return false }
    if feet == Int(B.lava) || head == Int(B.lava) || bid == Int(B.lava) { return false }
    if feet == Int(B.fire) || bid == Int(B.magma_block) || bid == Int(B.cactus) { return false }
    if feet == Int(B.water) { return !avoidWater }
    if bid == Int(B.water) { return !avoidWater } // swim surface
    return bid != 0 && blockDefs[bid].solid
}

public func findPath(_ world: World, _ fromX: Double, _ fromY: Double, _ fromZ: Double,
                     _ toX: Double, _ toY: Double, _ toZ: Double,
                     _ maxNodes: Int = 600, _ avoidWater: Bool = false) -> [PathNode]? {
    let sx = ifloor(fromX), sy = ifloor(fromY), sz = ifloor(fromZ)
    let tx = ifloor(toX), ty = ifloor(toY), tz = ifloor(toZ)
    if sx == tx && sy == ty && sz == tz { return [] }
    struct K: Hashable { let x: Int, y: Int, z: Int }
    final class Node {
        let x: Int, y: Int, z: Int
        let g: Double, f: Double
        let parent: Node?
        init(_ x: Int, _ y: Int, _ z: Int, _ g: Double, _ f: Double, _ parent: Node?) {
            self.x = x; self.y = y; self.z = z; self.g = g; self.f = f; self.parent = parent
        }
    }
    var open: [Node] = [Node(sx, sy, sz, 0, 0, nil)]
    var seen: [K: Double] = [K(x: sx, y: sy, z: sz): 0]
    var best: Node? = nil
    var bestH = Double.infinity
    var iter = 0
    while !open.isEmpty {
        iter += 1
        if iter > maxNodes { break }
        // pop lowest f
        var bi = 0
        for i in 1..<open.count where open[i].f < open[bi].f { bi = i }
        let cur = open.remove(at: bi)
        let h = Double(abs(cur.x - tx) + abs(cur.y - ty) + abs(cur.z - tz))
        if h < bestH { bestH = h; best = cur }
        if cur.x == tx && abs(cur.y - ty) <= 1 && cur.z == tz { best = cur; break }
        for (dx, _, dz) in NEIGHBORS {
            let diag = dx != 0 && dz != 0
            for dy in [0, 1, -1, -2, -3] {
                if diag && dy != 0 { continue }
                let nx = cur.x + dx, ny = cur.y + dy, nz = cur.z + dz
                if dy == 1 {
                    // need headroom to jump
                    let above = world.getBlock(cur.x, cur.y + 2, cur.z) >> 4
                    if above != 0 && blockDefs[above].solid { continue }
                }
                if !walkable(world, nx, ny, nz, avoidWater) { continue }
                if diag {
                    // both cardinals must be passable
                    if !walkable(world, cur.x + dx, cur.y, cur.z, avoidWater) && !walkable(world, cur.x, cur.y, cur.z + dz, avoidWater) { continue }
                }
                let cost = (diag ? 1.41 : 1) + Double(abs(dy)) * 0.5 + (dy < -1 ? (dy < -2 ? 4.0 : 2.0) : 0.0)
                let g = cur.g + cost
                let k = K(x: nx, y: ny, z: nz)
                if let prev = seen[k], prev <= g { continue }
                seen[k] = g
                let hh = Double(abs(nx - tx) + abs(ny - ty) + abs(nz - tz))
                open.append(Node(nx, ny, nz, g, g + hh * 1.1, cur))
                break // take first valid dy per direction
            }
        }
    }
    guard let bestNode = best, bestH <= 24 else { return nil }
    var path: [PathNode] = []
    var n: Node? = bestNode
    while let cur = n {
        path.insert(PathNode(x: cur.x, y: cur.y, z: cur.z), at: 0)
        n = cur.parent
    }
    if !path.isEmpty { path.removeFirst() }
    return path
}

public final class Navigation {
    public var path: [PathNode]? = nil
    public var pathIndex = 0
    public var repathCooldown = 0
    public var targetX = 0.0, targetY = 0.0, targetZ = 0.0
    public var speedMod = 1.0
    public var stuckTicks = 0
    public var nodeTicks = 0
    public var lastX = 0.0, lastZ = 0.0
    public var avoidWater = false

    unowned let mob: Mob
    init(_ mob: Mob) { self.mob = mob }

    @discardableResult
    public func moveTo(_ x: Double, _ y: Double, _ z: Double, _ speedMod: Double = 1) -> Bool {
        self.speedMod = speedMod
        let dx = x - targetX, dy = y - targetY, dz = z - targetZ
        if let p = path, dx * dx + dy * dy + dz * dz < 1, pathIndex < p.count { return true }
        targetX = x; targetY = y; targetZ = z
        if repathCooldown > 0 { return path != nil }
        repathCooldown = 20
        path = findPath(mob.world, mob.x, mob.y, mob.z, x, y, z, 600, avoidWater)
        pathIndex = 0
        return path != nil
    }
    @discardableResult
    public func moveToEntity(_ e: Entity, _ speedMod: Double = 1) -> Bool {
        moveTo(e.x, e.y, e.z, speedMod)
    }
    public func stop() {
        path = nil
        mob.moveForward = 0
        mob.jumping = false
    }
    public func isDone() -> Bool {
        path == nil || pathIndex >= (path?.count ?? 0)
    }

    public func tick() {
        if repathCooldown > 0 { repathCooldown -= 1 }
        guard let p = path, pathIndex < p.count else {
            mob.moveForward *= 0.5
            return
        }
        let node = p[pathIndex]
        let nx = Double(node.x) + 0.5, nz = Double(node.z) + 0.5
        let dx = nx - mob.x, dz = nz - mob.z
        let distSq = dx * dx + dz * dz
        // accept on horizontal arrival regardless of y when very close — a mob
        // >1 block above/below its node otherwise orbits it forever (the old
        // y-gate + fast movement never tripped the stuck detector)
        if distSq < 0.6 * 0.6 && (abs(node.y - ifloor(mob.y)) <= 1 || distSq < 0.35 * 0.35) {
            pathIndex += 1
            nodeTicks = 0
            return
        }
        nodeTicks += 1
        if nodeTicks > 80 {   // orbit/unreachable-node breaker
            stop()
            nodeTicks = 0
            return
        }
        // steer
        let targetYaw = detAtan2(-dx, dz)
        var d = targetYaw - mob.yaw
        while d > .pi { d -= .pi * 2 }
        while d < -.pi { d += .pi * 2 }
        mob.yaw += clampD(d, -0.35, 0.35)
        mob.moveForward = abs(d) > 1.6 ? 0.2 : speedMod
        mob.jumping = (node.y > ifloor(mob.y) && distSq < 2.5) || (mob.horizontalCollision && mob.onGround)
        if mob.inWater && node.y >= ifloor(mob.y) { mob.jumping = true }
        // stuck detection
        let mdx = mob.x - lastX, mdz = mob.z - lastZ
        let moved = (mdx * mdx + mdz * mdz).squareRoot()
        lastX = mob.x; lastZ = mob.z
        if moved < 0.01 {
            stuckTicks += 1
            if stuckTicks > 50 {
                stop()
                stuckTicks = 0
                repathCooldown = 0
            }
        } else {
            stuckTicks = 0
        }
    }
}

// ---------------------------------------------------------------------------
// Goal framework
// ---------------------------------------------------------------------------
public enum GoalFlag {
    public static let move = 1
    public static let look = 2
    public static let target = 4
}

open class Goal {
    public var flags = GoalFlag.move | GoalFlag.look
    public unowned let mob: Mob
    public let priority: Int
    public init(_ mob: Mob, _ priority: Int) {
        self.mob = mob
        self.priority = priority
    }
    open func canUse() -> Bool { false }
    open func canContinue() -> Bool { canUse() }
    open func start() {}
    open func stop() {}
    open func tick() {}
}

public final class GoalSelector {
    public var goals: [Goal] = []
    public var active: [Goal] = []   // insertion-ordered like a deterministic Set

    public init() {}

    public func add(_ goal: Goal) {
        goals.append(goal)
        // stable sort by priority (a stable sort)
        goals = goals.enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map { $0.element }
    }
    public func tick(_ interval: Int, _ age: Int) {
        // stop finished
        for g in active where !g.canContinue() {
            g.stop()
            active.removeAll { $0 === g }
        }
        // try to start (staggered)
        if age % interval == 0 {
            for g in goals {
                if active.contains(where: { $0 === g }) { continue }
                // check mutex with higher-priority active goals
                var blocked = false
                for a in active where (a.flags & g.flags) != 0 {
                    if a.priority <= g.priority { blocked = true; break }
                }
                if blocked { continue }
                if g.canUse() {
                    // cancel lower-priority conflicting
                    for a in active where (a.flags & g.flags) != 0 && a.priority > g.priority {
                        a.stop()
                        active.removeAll { $0 === a }
                    }
                    g.start()
                    active.append(g)
                }
            }
        }
        for g in active { g.tick() }
    }
    public func stopAll() {
        for g in active { g.stop() }
        active.removeAll()
    }
}

// ---------------------------------------------------------------------------
// Mob base
// ---------------------------------------------------------------------------
open class Mob: LivingEntity {
    public var goals = GoalSelector()
    public var targetGoals = GoalSelector()
    public lazy var nav = Navigation(self)
    public var target: LivingEntity?
    public var lookX: Double? = nil
    public var lookY = 0.0, lookZ = 0.0
    public var ambientSoundTimer = 0
    public var baby = false
    public var growUpAge = 0       // ticks until adult (if baby)
    public var loveTicks = 0
    public var breedCooldown = 0
    public var category = "creature"   // monster | creature | water | ambient | misc
    public var attackDamage = 2.0
    public var followRange = 16.0
    public var burnsInSun = false
    public var leashedTo: Entity?
    public var leashFence: (Int, Int, Int)? = nil
    public var ownerId: Int? = nil
    public var sitting = false

    open override func tick() { mobTick() }

    /// the Mob-level tick body — exposed so PiglinBrute/Zoglin can mimic the
    /// baseline `Monster.prototype.tick.call(this)` grandparent dispatch
    public final func mobTick() {
        baseLivingTick()
        if dead || deathTime > 0 { return }

        // despawn rules
        if !persistent && category == "monster" {
            var nearestPlayer = Double.infinity
            for e in world.entities {
                if let ent = e as? Entity, ent.isPlayer {
                    let d = (ent.x - x) * (ent.x - x) + (ent.y - y) * (ent.y - y) + (ent.z - z) * (ent.z - z)
                    nearestPlayer = min(nearestPlayer, d)
                }
            }
            if nearestPlayer > 128 * 128 { remove(); return }
            if nearestPlayer > 32 * 32 && rng.nextFloat() < 1.0 / 800 { remove(); return }
        }

        // sunlight burning
        tickSunlightBurning()

        // baby growth
        if baby && growUpAge > 0 {
            growUpAge -= 1
            if growUpAge <= 0 { baby = false }
        }
        if loveTicks > 0 {
            loveTicks -= 1
            if age % 8 == 0 { world.hooks.addParticles("heart", x, y + height + 0.3, z, 1, 0.3, 0) }
        }
        if breedCooldown > 0 { breedCooldown -= 1 }

        // AI
        targetGoals.tick(2, age)
        goals.tick(2, age)
        nav.tick()

        // look control
        if let lx = lookX {
            lookAt(lx, lookY, lookZ, 0.25, 0.25)
        }

        // leash physics
        if leashedTo != nil || leashFence != nil {
            let lx = leashedTo?.x ?? Double(leashFence!.0) + 0.5
            let ly = leashedTo?.y ?? Double(leashFence!.1) + 0.5
            let lz = leashedTo?.z ?? Double(leashFence!.2) + 0.5
            let dx = lx - x, dy = ly - y, dz = lz - z
            let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
            if dist > 10 {
                leashedTo = nil; leashFence = nil
                dropStack(ItemStack(iid("lead"), 1))
            } else if dist > 4 {
                vx += dx * 0.02; vy += dy * 0.01; vz += dz * 0.02
            }
        }

        travel()

        // ambient sound
        ambientSoundTimer -= 1
        if ambientSoundTimer <= 0 {
            ambientSoundTimer = 80 + rng.nextInt(160)
            if let snd = ambientSound() {
                world.hooks.playSound(snd, x, y, z, 1, baby ? 1.4 : 0.95 + rng.nextFloat() * 0.1)
            }
        }
    }

    func tickSunlightBurning() {
        if shouldIgniteInSunlight() {
            fireTicks = 160
        }
    }

    private func shouldIgniteInSunlight() -> Bool {
        guard burnsInSun && world.info.hasSky && fireTicks <= 0 else { return false }
        guard armor[0] == nil && !inWater && !inPowderSnow && world.rainLevel < 0.4 else { return false }

        let bx = ifloor(x)
        let by = ifloor(y + height)
        let bz = ifloor(z)
        guard world.canSeeSky(bx, by, bz) else { return false }

        let adjustedSkyLight = Double(world.getSkyLight(bx, by, bz)) - world.skyDarken()
        return adjustedSkyLight >= 8
    }

    public func setTarget(_ t: LivingEntity?) { target = t }

    open func doMeleeAttack(_ target: LivingEntity) {
        attackAnim = 1
        var dmg = attackDamage
        dmg += 3 * Double(effectLevel("strength"))
        dmg -= 4 * Double(effectLevel("weakness"))
        target.hurt(max(0, dmg), "mob", self)
        world.hooks.playSound("entity.player.attack.strong", x, y, z, 0.7, 1)
    }

    open func isFood(_ stack: ItemStack?) -> Bool { false }

    /// breeding interaction — returns true if consumed
    public func tryFeed(_ player: Entity?, _ stack: ItemStack) -> Bool {
        if !isFood(stack) { return false }
        if baby {
            growUpAge = max(0, growUpAge - 1200)
            return true
        }
        if loveTicks <= 0 && breedCooldown <= 0 {
            loveTicks = 600
            data.loveCause = player?.id
            return true
        }
        return false
    }

    open override func save() -> [String: Any] {
        var d = super.save()
        d["health"] = health
        d["baby"] = baby
        d["sitting"] = sitting
        if let ownerId { d["ownerId"] = ownerId }
        return d
    }
    open override func load(_ d: [String: Any]) {
        super.load(d)
        health = (d["health"] as? NSNumber)?.doubleValue ?? maxHealth
        baby = (d["baby"] as? Bool) ?? false
        sitting = (d["sitting"] as? Bool) ?? false
        ownerId = (d["ownerId"] as? NSNumber)?.intValue
    }
}

// ---------------------------------------------------------------------------
// Standard goals
// ---------------------------------------------------------------------------
public final class FloatGoal: Goal {
    public override init(_ mob: Mob, _ priority: Int) {
        super.init(mob, priority)
        flags = 0
    }
    public override func canUse() -> Bool { mob.inWater || mob.inLava }
    public override func tick() { if mob.rng.nextFloat() < 0.8 { mob.jumping = true } }
}

public final class PanicGoal: Goal {
    let speedMod: Double
    public init(_ mob: Mob, _ priority: Int, _ speedMod: Double = 1.25) {
        self.speedMod = speedMod
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        (mob.lastAttacker != nil && mob.hurtTime > 0) || mob.fireTicks > 0
    }
    public override func canContinue() -> Bool { !mob.nav.isDone() }
    public override func start() {
        // run away from attacker or random
        let m = mob
        let away = m.lastAttacker
        let ang = away != nil ? detAtan2(m.x - away!.x, m.z - away!.z) : m.rng.nextFloat() * .pi * 2
        let tx = m.x + detSin(ang) * 8 + (m.rng.nextFloat() - 0.5) * 4
        let tz = m.z + detCos(ang) * 8 + (m.rng.nextFloat() - 0.5) * 4
        m.nav.moveTo(tx, m.y, tz, speedMod)
    }
}

public class StrollGoal: Goal {
    public let speedMod: Double
    public let interval: Int
    public init(_ mob: Mob, _ priority: Int, _ speedMod: Double = 1, _ interval: Int = 120) {
        self.speedMod = speedMod
        self.interval = interval
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        if mob.sitting { return false }
        return mob.rng.nextInt(interval) == 0
    }
    public override func canContinue() -> Bool { !mob.nav.isDone() }
    public override func start() {
        let m = mob
        for _ in 0..<8 {
            let tx = ifloor(m.x) + m.rng.nextInt(21) - 10
            let tz = ifloor(m.z) + m.rng.nextInt(21) - 10
            let ty = ifloor(m.y) + m.rng.nextInt(7) - 3
            if walkable(m.world, tx, ty, tz, m.nav.avoidWater) {
                m.nav.moveTo(Double(tx), Double(ty), Double(tz), speedMod)
                return
            }
        }
    }
    public override func stop() { mob.nav.stop() }
}

public final class LookAtPlayerGoal: Goal {
    let range: Double
    let chance: Double
    var lookTime = 0
    var targetE: Entity?
    public init(_ mob: Mob, _ priority: Int, _ range: Double = 8, _ chance: Double = 0.02) {
        self.range = range
        self.chance = chance
        super.init(mob, priority)
        flags = GoalFlag.look
    }
    public override func canUse() -> Bool {
        if mob.rng.nextFloat() > chance { return false }
        let players = mob.world.getEntitiesNear(mob.x, mob.y, mob.z, range) { ($0 as? Entity)?.isPlayer ?? false }
        if players.isEmpty { return false }
        targetE = players[0] as? Entity
        return true
    }
    public override func canContinue() -> Bool { lookTime > 0 && targetE != nil && !targetE!.dead }
    public override func start() { lookTime = 40 + mob.rng.nextInt(40) }
    public override func tick() {
        lookTime -= 1
        if let t = targetE {
            mob.lookX = t.x
            mob.lookY = t.eyeY()
            mob.lookZ = t.z
        }
    }
    public override func stop() { mob.lookX = nil }
}

public final class RandomLookGoal: Goal {
    var time = 0
    public override init(_ mob: Mob, _ priority: Int) {
        super.init(mob, priority)
        flags = GoalFlag.look
    }
    public override func canUse() -> Bool { mob.rng.nextFloat() < 0.02 }
    public override func canContinue() -> Bool { time > 0 }
    public override func start() {
        time = 20 + mob.rng.nextInt(20)
        let ang = mob.rng.nextFloat() * .pi * 2
        mob.lookX = mob.x + detSin(ang) * 4
        mob.lookY = mob.eyeY()
        mob.lookZ = mob.z + detCos(ang) * 4
    }
    public override func tick() { time -= 1 }
    public override func stop() { mob.lookX = nil }
}

public final class MeleeAttackGoal: Goal {
    let speedMod: Double
    var attackCooldown = 0
    public init(_ mob: Mob, _ priority: Int, _ speedMod: Double = 1.2) {
        self.speedMod = speedMod
        super.init(mob, priority)
    }
    public override func canUse() -> Bool { mob.target != nil && !mob.target!.dead }
    public override func start() { mob.sprinting = true }
    public override func stop() {
        mob.sprinting = false
        mob.nav.stop()
    }
    public override func tick() {
        let m = mob
        guard let t = m.target else { return }
        m.lookX = t.x; m.lookY = t.eyeY(); m.lookZ = t.z
        if attackCooldown > 0 { attackCooldown -= 1 }
        let reach = m.width / 2 + t.width / 2 + 0.8
        let reachSq = reach * reach
        let dSq = (m.x - t.x) * (m.x - t.x) + (m.z - t.z) * (m.z - t.z)
        let vert = abs(t.y - m.y)
        if dSq <= reachSq && vert < 2.5 {
            if attackCooldown <= 0 {
                attackCooldown = 20
                m.doMeleeAttack(t)
            }
            m.nav.stop()
        } else {
            m.nav.moveToEntity(t, speedMod)
        }
    }

}

public final class NearestTargetGoal: Goal {
    let filter: (LivingEntity) -> Bool
    let range: Double
    let needSight: Bool
    let lightGate: ((World, Int, Int, Int) -> Bool)?
    var scanCooldown = 0
    public init(_ mob: Mob, _ priority: Int, _ filter: @escaping (LivingEntity) -> Bool,
                _ range: Double = 16, _ needSight: Bool = true,
                _ lightGate: ((World, Int, Int, Int) -> Bool)? = nil) {
        self.filter = filter
        self.range = range
        self.needSight = needSight
        self.lightGate = lightGate
        super.init(mob, priority)
        flags = GoalFlag.target
    }
    public override func canUse() -> Bool {
        let sc = scanCooldown
        scanCooldown -= 1
        if sc > 0 { return false }
        scanCooldown = 10
        let m = mob
        let candidates = m.world.getEntitiesNear(m.x, m.y, m.z, range) { e in
            guard let le = e as? LivingEntity else { return false }
            return le !== m && !le.dead && self.filter(le)
        }.compactMap { $0 as? LivingEntity }
        var best: LivingEntity? = nil
        var bestD = Double.infinity
        for c in candidates {
            if c.isPlayer && (c.gameMode == 1 || c.invisibleToMobs) { continue }
            let d = m.distanceToSq(c)
            if d < bestD && (!needSight || m.canSee(c)) { bestD = d; best = c }
        }
        if let best {
            m.setTarget(best)
            return true
        }
        return false
    }
    public override func canContinue() -> Bool {
        guard let t = mob.target, !t.dead else { return false }
        if mob.distanceToSq(t) > (range * 1.5) * (range * 1.5) { mob.setTarget(nil); return false }
        return true
    }
}

public final class HurtByTargetGoal: Goal {
    let alertSame: Bool
    public init(_ mob: Mob, _ priority: Int, _ alertSame: Bool = false) {
        self.alertSame = alertSame
        super.init(mob, priority)
        flags = GoalFlag.target
    }
    public override func canUse() -> Bool {
        let m = mob
        if let attacker = m.lastAttacker, !attacker.dead, m.hurtTime > 0, let living = attacker as? LivingEntity {
            m.setTarget(living)
            if alertSame {
                for e in m.world.getEntitiesNear(m.x, m.y, m.z, 16, filter: { ($0 as? Entity)?.type == m.type }) {
                    if let mob2 = e as? Mob, mob2.target == nil {
                        mob2.setTarget(living)
                    }
                }
            }
            return true
        }
        return false
    }
    public override func canContinue() -> Bool { mob.target != nil && !mob.target!.dead }
}

public final class AvoidEntityGoal: Goal {
    let filter: (Entity) -> Bool
    let range: Double
    let speedMod: Double
    var fleeing: Entity?
    public init(_ mob: Mob, _ priority: Int, _ filter: @escaping (Entity) -> Bool,
                _ range: Double = 8, _ speedMod: Double = 1.2) {
        self.filter = filter
        self.range = range
        self.speedMod = speedMod
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        let near = mob.world.getEntitiesNear(mob.x, mob.y, mob.z, range) { e in
            guard let ent = e as? Entity else { return false }
            if self.mob is Animal, let player = ent as? Player,
               player.rpgClassesEnabled(), player.rpg.created,
               self.mob.lastAttacker !== player {
                let calmRadius = rpgSkillEffectValue(.beastKinship, in: player.rpg)
                if calmRadius > 0, self.mob.distanceToSq(player) <= calmRadius * calmRadius { return false }
            }
            return self.filter(ent)
        }
        fleeing = near.first as? Entity
        return fleeing != nil
    }
    public override func tick() {
        let m = mob
        guard let f = fleeing else { return }
        if m.nav.isDone() {
            let ang = detAtan2(m.x - f.x, m.z - f.z)
            m.nav.moveTo(m.x + detSin(ang) * 10, m.y, m.z + detCos(ang) * 10, speedMod)
        }
    }
    public override func stop() { mob.nav.stop() }
}

public final class TemptGoal: Goal {
    let items: [String]
    let speedMod: Double
    var player: LivingEntity?
    public init(_ mob: Mob, _ priority: Int, _ items: [String], _ speedMod: Double = 1) {
        self.items = items
        self.speedMod = speedMod
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        let players = mob.world.getEntitiesNear(mob.x, mob.y, mob.z, 10) { ($0 as? Entity)?.isPlayer ?? false }
        for p in players {
            guard let pl = p as? LivingEntity else { continue }
            if let held = pl.mainHand, items.contains(itemDef(held.id).name) {
                player = pl
                return true
            }
        }
        return false
    }
    public override func tick() {
        let m = mob
        guard let p = player else { return }
        m.lookX = p.x; m.lookY = p.eyeY(); m.lookZ = p.z
        if m.distanceToSq(p) > 5 { m.nav.moveToEntity(p, speedMod) }
        else { m.nav.stop() }
    }
    public override func stop() { mob.nav.stop(); player = nil }
}

public final class BreedGoal: Goal {
    let spawnBaby: (Mob, Mob) -> Void
    var partner: Mob?
    var timer = 0
    public init(_ mob: Mob, _ priority: Int, _ spawnBaby: @escaping (Mob, Mob) -> Void) {
        self.spawnBaby = spawnBaby
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        let m = mob
        if m.loveTicks <= 0 { return false }
        let partners = m.world.getEntitiesNear(m.x, m.y, m.z, 8) { e in
            guard let other = e as? Mob else { return false }
            return other.type == m.type && other !== m && other.loveTicks > 0
        }
        partner = partners.first as? Mob
        return partner != nil
    }
    public override func canContinue() -> Bool {
        partner != nil && !partner!.dead && mob.loveTicks > 0 && partner!.loveTicks > 0
    }
    public override func start() { timer = 0 }
    public override func tick() {
        let m = mob
        guard let p = partner else { return }
        m.lookX = p.x; m.lookY = p.y; m.lookZ = p.z
        m.nav.moveToEntity(p, 1)
        if m.distanceToSq(p) < 6 {
            timer += 1
            if timer >= 60 {
                m.loveTicks = 0; p.loveTicks = 0
                m.breedCooldown = 6000; p.breedCooldown = 6000
                spawnBaby(m, p)
                partner = nil
            }
        }
    }
}

public final class FollowParentGoal: Goal {
    var parent: Mob?
    public override init(_ mob: Mob, _ priority: Int) {
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        if !mob.baby { return false }
        let parents = mob.world.getEntitiesNear(mob.x, mob.y, mob.z, 12) { e in
            guard let other = e as? Mob else { return false }
            return other.type == self.mob.type && !other.baby
        }
        parent = parents.first as? Mob
        guard let p = parent else { return false }
        return mob.distanceToSq(p) > 9
    }
    public override func tick() {
        if let p = parent, mob.nav.isDone() { mob.nav.moveToEntity(p, 1.1) }
    }
}

public final class FollowOwnerGoal: Goal {
    let minDist: Double
    let teleportDist: Double
    public init(_ mob: Mob, _ priority: Int, _ minDist: Double = 4, _ teleportDist: Double = 12) {
        self.minDist = minDist
        self.teleportDist = teleportDist
        super.init(mob, priority)
    }
    func owner() -> Entity? {
        guard let ownerId = mob.ownerId else { return nil }
        return mob.world.entityById[ownerId] as? Entity
    }
    public override func canUse() -> Bool {
        if mob.sitting { return false }
        guard let o = owner() else { return false }
        return mob.distanceToSq(o) > minDist * minDist
    }
    public override func tick() {
        guard let o = owner() else { return }
        let m = mob
        m.lookX = o.x; m.lookY = o.eyeY(); m.lookZ = o.z
        let dSq = m.distanceToSq(o)
        if dSq > teleportDist * teleportDist {
            // teleport to owner
            m.setPos(o.x + (m.rng.nextFloat() - 0.5) * 3, o.y + 0.5, o.z + (m.rng.nextFloat() - 0.5) * 3)
            m.nav.stop()
        } else if m.nav.isDone() {
            m.nav.moveToEntity(o, 1.2)
        }
    }
    public override func stop() { mob.nav.stop() }
}

public final class SitWhenOrderedGoal: Goal {
    public override func canUse() -> Bool { mob.sitting }
    public override func tick() { mob.nav.stop(); mob.moveForward = 0 }
}

public final class RangedAttackGoal: Goal {
    let interval: Int
    let range: Double
    let attack: (LivingEntity, Double) -> Void
    let strafe: Bool
    var cooldown = 0
    public init(_ mob: Mob, _ priority: Int, _ interval: Int, _ range: Double,
                _ attack: @escaping (LivingEntity, Double) -> Void, _ strafe: Bool = true) {
        self.interval = interval
        self.range = range
        self.attack = attack
        self.strafe = strafe
        super.init(mob, priority)
    }
    public override func canUse() -> Bool { mob.target != nil && !mob.target!.dead }
    public override func stop() { mob.nav.stop(); mob.sprinting = false; mob.data.aiming = false }
    public override func tick() {
        let m = mob
        guard let t = m.target else { return }
        m.lookX = t.x; m.lookY = t.eyeY(); m.lookZ = t.z
        m.data.aiming = true
        let dSq = m.distanceToSq(t)
        let canSee = m.canSee(t)
        if dSq < range * range && canSee {
            m.nav.stop()
            // strafe sideways
            if strafe {
                m.moveStrafe = detSin(Double(m.age) * 0.1) * 0.5
                if dSq < 9 { m.moveForward = -0.5 }
                else { m.moveForward = 0 }
            }
            let cd = cooldown
            cooldown -= 1
            if cd <= 0 {
                cooldown = interval
                attack(t, clampD(dSq.squareRoot() / range, 0.3, 1))
            }
        } else {
            m.moveStrafe = 0
            m.nav.moveToEntity(t, 1.1)
            cooldown = max(cooldown - 1, 10)
        }
    }
}

public class MoveToBlockGoal: Goal {
    public let valid: (World, Int, Int, Int) -> Bool
    public let range: Int
    public let speedMod: Double
    public let interval: Int
    public var targetPos: (Int, Int, Int)? = nil
    var tries = 0
    public init(_ mob: Mob, _ priority: Int, _ valid: @escaping (World, Int, Int, Int) -> Bool,
                _ range: Int = 8, _ speedMod: Double = 1, _ interval: Int = 40) {
        self.valid = valid
        self.range = range
        self.speedMod = speedMod
        self.interval = interval
        super.init(mob, priority)
    }
    public override func canUse() -> Bool {
        if mob.rng.nextInt(interval) != 0 { return false }
        let m = mob
        for _ in 0..<16 {
            let x = ifloor(m.x) + m.rng.nextInt(range * 2 + 1) - range
            let y = ifloor(m.y) + m.rng.nextInt(5) - 2
            let z = ifloor(m.z) + m.rng.nextInt(range * 2 + 1) - range
            if valid(m.world, x, y, z) {
                targetPos = (x, y, z)
                return true
            }
        }
        return false
    }
    public override func canContinue() -> Bool {
        guard let t = targetPos else { return false }
        return !mob.nav.isDone() && valid(mob.world, t.0, t.1, t.2)
    }
    public override func start() {
        if let t = targetPos { mob.nav.moveTo(Double(t.0), Double(t.1), Double(t.2), speedMod) }
    }
    public func reached() -> Bool {
        guard let t = targetPos else { return false }
        let dx = mob.x - Double(t.0) - 0.5, dz = mob.z - Double(t.2) - 0.5
        return dx * dx + dz * dz < 2 && abs(mob.y - Double(t.1)) < 2
    }
}

public class RandomSwimGoal: StrollGoal {
    public override func start() {
        let m = mob
        for _ in 0..<10 {
            let tx = ifloor(m.x) + m.rng.nextInt(15) - 7
            let ty = ifloor(m.y) + m.rng.nextInt(7) - 3
            let tz = ifloor(m.z) + m.rng.nextInt(15) - 7
            if (m.world.getBlock(tx, ty, tz) >> 4) == Int(B.water) {
                m.data.swimTarget = [Double(tx) + 0.5, Double(ty) + 0.5, Double(tz) + 0.5]
                return
            }
        }
    }
    public override func canContinue() -> Bool { mob.data.swimTarget != nil }
    public override func tick() {
        let m = mob
        guard let t = m.data.swimTarget else { return }
        let dx = t[0] - m.x, dy = t[1] - m.y, dz = t[2] - m.z
        let d = (dx * dx + dy * dy + dz * dz).squareRoot()
        if d < 1.2 || (m.world.getBlock(ifloor(t[0]), ifloor(t[1]), ifloor(t[2])) >> 4) != Int(B.water) {
            m.data.swimTarget = nil
            return
        }
        m.vx += dx / d * 0.02
        m.vy += dy / d * 0.02
        m.vz += dz / d * 0.02
        // near-vertical targets have degenerate horizontal headings — turning
        // toward atan2 noise made fish/squid spin in place
        if dx * dx + dz * dz > 0.01 {
            let target = detAtan2(-dx, dz)
            m.yaw += clampD(wrapAngle(target - m.yaw), -0.3, 0.3)
        }
    }
}
