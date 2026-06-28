// Entity base — AABB physics with auto-step, fluid
// state, fire, riding, fall tracking, persistence hooks.

import Foundation

@inline(__always) func ifloor(_ x: Double) -> Int { Int(x.rounded(.down)) }

private var nextEntityId = 1
/// true reset (not a ratchet) — called on world load so id sequences don't
/// depend on which worlds were opened earlier in the session
public func resetEntityIds(_ start: Int) { nextEntityId = start }
public func peekNextEntityId() -> Int { nextEntityId }

/// generic per-entity data bag (variant, color, tame owner id, …) — closed
/// field set surveyed from the baseline `data: Record<string, any>` usage.
public struct EntityData: Codable, Equatable {
    public var variant: Int?
    public var color: Int?
    public var size: Int?
    public var pattern: Int?
    public var puffed: Bool?
    public var swelling: Double?
    public var grazing: Bool?
    public var stingTimer: Int?
    public var buckTimer: Int?
    public var loveCause: Int?
    public var baby: Bool?
    public var brown: Bool?
    public var sheared: Bool?
    public var charged: Bool?
    public var captain: Bool?
    public var cold: Bool?
    public var hanging: Bool?
    public var aiming: Bool?
    public var airborne: Bool?
    public var crossed: Bool?
    public var leatherBoots: Bool?
    public var persistent: Bool?
    public var open: Double?
    public var gene: String?
    public var deathCause: String?
    public var deathAttacker: String?
    public var swimTarget: [Double]?

    public init() {}
}

open class Entity: EntityRef {
    public let id: Int
    open var type: String { "entity" }
    public var x = 0.0, y = 0.0, z = 0.0
    public var prevX = 0.0, prevY = 0.0, prevZ = 0.0
    public var vx = 0.0, vy = 0.0, vz = 0.0
    public var yaw = 0.0, pitch = 0.0            // radians
    public var prevYaw = 0.0, prevPitch = 0.0
    public var width = 0.6, height = 1.8
    public var stepHeight = 0.6
    public var onGround = false
    public var horizontalCollision = false
    public var dead = false
    public var age = 0
    public var fireTicks = 0
    public var airSupply = 300
    public var invulnTicks = 0
    public var fallDistance = 0.0
    public var inWater = false
    public var inLava = false
    public var underwater = false
    public var inPowderSnow = false
    public var freezeTicks = 0
    public var noGravity = false
    public var gravityScale = 1.0
    /// riding
    public weak var vehicle: Entity?
    public var passengers: [Entity] = []
    /// mark for save persistence
    public var persistent = false
    /// non-persistent LAN mirror metadata; host-authoritative replicated
    /// entities use this to avoid local ticking, pickup, and save authority.
    public var lanReplicationSourceID: Int?
    public var lanReplicatedMirror = false
    public var data = EntityData()
    public var portalCooldown = 0
    public var portalTime = 0
    /// player-only flags surfaced on the base for baseline `(this as any)` checks
    open var isPlayer: Bool { false }
    public var noClip = false

    /// var (not let): dimension travel re-homes the player into the dest world
    public unowned var world: World

    public init(world: World) {
        self.id = nextEntityId
        nextEntityId += 1
        self.world = world
    }

    public func bb() -> AABB {
        let hw = width / 2
        return AABB(x - hw, y, z - hw, x + hw, y + height, z + hw)
    }
    public func eyeY() -> Double { y + height * 0.85 }
    public func centerY() -> Double { y + height / 2 }

    public func setPos(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
        prevX = x; prevY = y; prevZ = z
    }

    open func remove() {
        dead = true
        for p in passengers { p.vehicle = nil }
        passengers.removeAll()
        if vehicle != nil { dismount() }
    }

    public func mount(_ v: Entity) {
        if vehicle != nil { dismount() }
        vehicle = v
        v.passengers.append(self)
    }
    public func dismount() {
        guard let v = vehicle else { return }
        vehicle = nil
        if let i = v.passengers.firstIndex(where: { $0 === self }) {
            v.passengers.remove(at: i)
        }
        // pop out to a safe spot
        y = v.y + v.height + 0.01
    }

    public func baseTick() {
        prevX = x; prevY = y; prevZ = z
        prevYaw = yaw; prevPitch = pitch
        age += 1
        if invulnTicks > 0 { invulnTicks -= 1 }
        if portalCooldown > 0 { portalCooldown -= 1 }
        updateFluidState()
        // fire
        if fireTicks > 0 {
            if inWater || inPowderSnow {
                fireTicks = 0
                if inPowderSnow { world.setBlock(ifloor(x), ifloor(y), ifloor(z), 0) }
            } else {
                if fireTicks % 20 == 0 && world.rule("fireDamage") { _ = hurt(1, "fire") }
                fireTicks -= 1
            }
        }
        if inLava {
            _ = hurt(4, "lava")
            fireTicks = max(fireTicks, 300)
            fallDistance *= 0.5
        }
        // void
        if y < Double(world.info.minY - 64) {
            _ = hurt(4, "void")
            if y < Double(world.info.minY - 128) && !isPlayer { remove() }
        }
        // freezing
        if inPowderSnow {
            freezeTicks = min(freezeTicks + 1, 140)
        } else {
            freezeTicks = max(0, freezeTicks - 2)
        }
        if freezeTicks >= 140 && age % 40 == 0 { _ = hurt(1, "freeze") }
    }

    func updateFluidState() {
        let box = bb()
        var water = false, lava = false, powder = false
        let x0 = ifloor(box.x0), x1 = ifloor(box.x1)
        let y0 = ifloor(box.y0), y1 = ifloor(box.y1)
        let z0 = ifloor(box.z0), z1 = ifloor(box.z1)
        for yy in y0...max(y0, y1) {
            for zz in z0...max(z0, z1) {
                for xx in x0...max(x0, x1) {
                    let cell = world.getBlock(xx, yy, zz)
                    let bid = cell >> 4
                    if bid == Int(B.water) || (cell >= 0 && isWaterlogged(UInt16(cell))) {
                        let h = Double(yy) + world.fluidHeight(xx, yy, zz)
                        if box.y0 < h { water = true }
                    } else if bid == Int(B.lava) {
                        let h = Double(yy) + world.fluidHeight(xx, yy, zz)
                        if box.y0 < h { lava = true }
                    } else if bid == Int(B.powder_snow) {
                        powder = true
                    }
                }
            }
        }
        inWater = water
        inLava = lava
        inPowderSnow = powder
        let eyeCell = world.getBlock(ifloor(x), ifloor(eyeY()), ifloor(z))
        underwater = (eyeCell >> 4) == Int(B.water) || (eyeCell >= 0 && isWaterlogged(UInt16(eyeCell)))
        // bubble columns: water column above magma (down) or soul sand (up)
        if water {
            let bx = ifloor(x), bz = ifloor(z)
            var by = ifloor(box.y0)
            while by > world.info.minY && by > ifloor(box.y0) - 16 {
                let c = world.getBlock(bx, by, bz) >> 4
                if c == Int(B.water) { by -= 1; continue }
                if c == Int(B.magma_block) { vy = max(vy - 0.05, -0.5) }
                else if c == Int(B.soul_sand) { vy = min(vy + 0.06, 0.6) }
                break
            }
        }
    }

    /// swept AABB move with auto-step
    public func move(_ dxIn: Double, _ dyIn: Double, _ dzIn: Double) {
        var dx = dxIn, dy = dyIn, dz = dzIn
        if noClip {
            x += dx; y += dy; z += dz
            return
        }
        // cobweb / sweet berry slow
        let cell = world.getBlock(ifloor(x), ifloor(y + 0.2), ifloor(z))
        let bid = cell >> 4
        if bid == Int(B.cobweb) { dx *= 0.25; dy *= 0.05; dz *= 0.25; vx = 0; vy = 0; vz = 0 }
        else if bid == Int(B.sweet_berry_bush) { dx *= 0.8; dy *= 0.75; dz *= 0.8 }
        else if bid == Int(B.powder_snow) && !(data.leatherBoots ?? false) { dx *= 0.9; dy *= 0.9; dz *= 0.9 }
        if bid == Int(B.honey_block) || (world.getBlock(ifloor(x), ifloor(y - 0.1), ifloor(z)) >> 4) == Int(B.honey_block) {
            dx *= 0.4; dz *= 0.4
            if dy < -0.13 { dy = -0.05; vy = -0.05 }
        }

        let origDx = dx, origDy = dy, origDz = dz
        var boxes: [AABB] = []
        let bb0 = bb()
        let query = AABB(
            min(bb0.x0, bb0.x0 + dx) - 0.5, min(bb0.y0, bb0.y0 + dy) - 1.5,
            min(bb0.z0, bb0.z0 + dz) - 0.5, max(bb0.x1, bb0.x1 + dx) + 0.5,
            max(bb0.y1, bb0.y1 + dy) + 0.5, max(bb0.z1, bb0.z1 + dz) + 0.5
        )
        world.forEachCollisionBox(query) { boxes.append($0) }

        var box = bb0
        // Y
        for b in boxes { dy = sweepY(box, b, dy) }
        box = AABB(box.x0, box.y0 + dy, box.z0, box.x1, box.y1 + dy, box.z1)
        // X
        for b in boxes { dx = sweepX(box, b, dx) }
        box = AABB(box.x0 + dx, box.y0, box.z0, box.x1 + dx, box.y1, box.z1)
        // Z
        for b in boxes { dz = sweepZ(box, b, dz) }

        let hitX = abs(dx - origDx) > 1e-7
        let hitZ = abs(dz - origDz) > 1e-7
        let hitY = abs(dy - origDy) > 1e-7
        let wasOnGround = onGround || (hitY && origDy < 0)

        // auto-step
        if (hitX || hitZ) && wasOnGround && stepHeight > 0 {
            var sx = origDx, sy = stepHeight, sz = origDz
            var sbox = bb0
            for b in boxes { sy = sweepY(sbox, b, sy) }
            sbox = AABB(sbox.x0, sbox.y0 + sy, sbox.z0, sbox.x1, sbox.y1 + sy, sbox.z1)
            for b in boxes { sx = sweepX(sbox, b, sx) }
            sbox = AABB(sbox.x0 + sx, sbox.y0, sbox.z0, sbox.x1 + sx, sbox.y1, sbox.z1)
            for b in boxes { sz = sweepZ(sbox, b, sz) }
            sbox = AABB(sbox.x0, sbox.y0, sbox.z0 + sz, sbox.x1, sbox.y1, sbox.z1 + sz)
            // settle back down
            var down = -stepHeight
            for b in boxes { down = sweepY(sbox, b, down) }
            if (sx * sx + sz * sz) > (dx * dx + dz * dz) + 1e-7 {
                dx = sx; dz = sz; dy = sy + down
            }
        }

        x += dx; y += dy; z += dz
        horizontalCollision = hitX || hitZ
        onGround = hitY && origDy < 0
        if hitX { vx = 0 }
        if hitY { vy = 0 }
        if hitZ { vz = 0 }

        // fall distance
        if onGround {
            if fallDistance > 0 {
                onLand(fallDistance)
                fallDistance = 0
            }
        } else if dy < 0 {
            fallDistance -= dy
        }
        if inWater || isClimbing() { fallDistance = 0 }
    }

    public func isClimbing() -> Bool {
        let cell = world.getBlock(ifloor(x), ifloor(y), ifloor(z))
        let bid = cell >> 4
        return bid >= 0 && bid < CLIMBABLE.count && CLIMBABLE[bid] == 1
    }

    /// standing-on block
    public func groundBlock() -> Int {
        world.getBlock(ifloor(x), ifloor(y - 0.35), ifloor(z))
    }

    open func onLand(_ fallDistance: Double) {}

    open func tick() {}

    @discardableResult
    open func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool { false }

    /// right-click interaction; return true if handled
    open func interact(_ player: Entity, _ stack: ItemStack?) -> Bool { false }

    public func distanceToSq(_ e: Entity) -> Double {
        let dx = x - e.x, dy = y - e.y, dz = z - e.z
        return dx * dx + dy * dy + dz * dz
    }
    public func distanceTo(_ e: Entity) -> Double { distanceToSq(e).squareRoot() }

    public func lookAt(_ tx: Double, _ ty: Double, _ tz: Double, _ maxYawStep: Double = 0.5, _ maxPitchStep: Double = 0.5) {
        let dx = tx - x, dy = ty - eyeY(), dz = tz - z
        let targetYaw = detAtan2(-dx, dz)
        let horiz = (dx * dx + dz * dz).squareRoot()
        let targetPitch = -detAtan2(dy, horiz)
        var dYaw = targetYaw - yaw
        while dYaw > .pi { dYaw -= .pi * 2 }
        while dYaw < -.pi { dYaw += .pi * 2 }
        yaw += clampD(dYaw, -maxYawStep, maxYawStep)
        pitch += clampD(targetPitch - pitch, -maxPitchStep, maxPitchStep)
    }

    public func canSee(_ e: Entity) -> Bool {
        let ox = x, oy = eyeY(), oz = z
        let tx = e.x, ty = e.eyeY(), tz = e.z
        let dx = tx - ox, dy = ty - oy, dz = tz - oz
        let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
        if dist < 0.01 { return true }
        let hit = world.raycast(ox, oy, oz, dx / dist, dy / dist, dz / dist, dist)
        return hit == nil
    }

    /// serialize for chunk save
    open func save() -> [String: Any] {
        var d: [String: Any] = [
            "type": type, "x": x, "y": y, "z": z,
            "vx": vx, "vy": vy, "vz": vz,
            "yaw": yaw, "pitch": pitch, "age": age,
            "fire": fireTicks, "persistent": persistent,
        ]
        if let enc = try? JSONEncoder().encode(data),
           let obj = try? JSONSerialization.jsonObject(with: enc) {
            d["data"] = obj
        }
        return d
    }
    open func load(_ d: [String: Any]) {
        setPos(dnum(d["x"]), dnum(d["y"]), dnum(d["z"]))
        vx = dnum(d["vx"]); vy = dnum(d["vy"]); vz = dnum(d["vz"])
        yaw = dnum(d["yaw"]); pitch = dnum(d["pitch"])
        age = inum(d["age"]); fireTicks = inum(d["fire"])
        if let raw = d["data"],
           let bytes = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(EntityData.self, from: bytes) {
            data = decoded
        } else {
            data = EntityData()
        }
        persistent = (d["persistent"] as? Bool) ?? false
    }
}

// JSON field readers (baseline `d.x ?? 0` semantics)
@inline(__always) func dnum(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
@inline(__always) func inum(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
