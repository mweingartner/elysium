// The player — inventory, hunger/saturation, XP,
// mining state, abilities, elytra flight, sleeping, ender chest, and
// interaction helpers.

import Foundation

public let PLAYER_HEIGHT = 1.8
public let PLAYER_SNEAK_HEIGHT = 1.5
public let PLAYER_EYE = 1.62
public let PLAYER_SNEAK_EYE = 1.27

public enum GameMode {
    public static let survival = 0
    public static let creative = 1
}

public let CREATIVE_FLIGHT_DOUBLE_JUMP_MS = 280.0
private let CREATIVE_FLIGHT_VERTICAL_SPEED = 0.35
public let FLYING_WAND_ITEM_NAME = "flying_wand"
private let FLYING_WAND_FALL_DAMAGE_MULTIPLIER = 0.5

public final class Player: LivingEntity {
    public override var type: String { "player" }
    public override var isPlayer: Bool { true }
    private var _gameMode = GameMode.survival
    public override var gameMode: Int { _gameMode }
    private var lastCreativeJumpPress: Double?
    private var creativeFlightLaunchTicks = 0
    private var flyingWandFlightActive = false
    private var flyingWandFallLocked = false
    private var flyingWandFallDamageMultiplier: Double? = nil

    public func setGameMode(_ m: Int) {
        _gameMode = m
        if _gameMode != GameMode.creative {
            flying = false
            flyingWandFlightActive = false
            creativeFlightLaunchTicks = 0
            lastCreativeJumpPress = nil
        } else {
            clearFlyingWandFallState()
            flyingWandFlightActive = false
        }
    }
    /// inventory: 0-8 hotbar, 9-35 main
    public var inventory: [ItemStack?] = Array(repeating: nil, count: 36)
    public var enderChest: [ItemStack?] = Array(repeating: nil, count: 27)
    public var selectedSlot = 0
    public var hunger = 20
    public var saturation = 5.0
    public var exhaustion = 0.0
    public var foodTickTimer = 0
    public var xp = 0          // total points
    public var xpLevel = 0
    public var xpProgress = 0.0  // 0..1
    public var flying = false
    public var elytraFlying = false
    public var sleepTicks = 0
    public var bedPos: (Int, Int, Int)? = nil
    public var spawnPoint: (Int, Int, Int)? = nil
    public var spawnDim = 0
    public var spawnForced = false
    /// mining state
    public var breakingX = 0, breakingY = 0, breakingZ = 0
    public var breakingProgress = -1.0
    public var attackStrengthTicker = 100.0
    public var usingItem = false
    public var useItemTicks = 0
    public var useItemHand = "main"   // main | off
    public var useItemSlot = -1
    public var useItemItemId = -1
    public var fishingBobberId: Int? = nil
    private var _wearingPumpkin = false
    public override var wearingPumpkin: Bool { _wearingPumpkin }
    /// stats for advancements
    public var stats: [String: Double] = [:]
    public var portalTicks = 0
    public var insidePortalKind: String? = nil   // nether | end | nil
    public var rpg = RPGCharacterState.uncreated()
    /// Security amendment S2 (forward guard): transient, never persisted. True only immediately
    /// after `load(_:)` decoded an `rpg` payload whose `version` exceeds
    /// `RPG_STATE_CURRENT_VERSION` -- i.e. this build cannot yet understand that save. Callers
    /// that would otherwise persist `repairRPGCharacterState(rpg)` (which fails closed to
    /// `.uncreated()` for a future version) must check this flag first so a future-version
    /// payload never overwrites a local resume cache's last-known-good snapshot.
    public private(set) var rpgDecodedVersionExceedsCurrent = false
    /// Compatibility copy of the pre-local-preferences quick-slot field. LAN/protocol-5 sessions
    /// deliberately retain it; only an exact local-world migration receipt can make it omittable.
    public private(set) var rpgLegacyQuickSlotEnvelope: RPGLegacyQuickSlotEnvelope?
    private var rpgLegacyEnvelopeVersion: UInt64 = 0
    /// Session-only authority identity used by bounded RPG world effects.
    /// LAN ghost hydration replaces the default with the stable peer ID.
    public var rpgAuthorityID = ""

    public var effectiveRPGAuthorityID: String {
        rpgAuthorityID.isEmpty ? "entity:\(id)" : rpgAuthorityID
    }

    public override init(world: World) {
        super.init(world: world)
        width = 0.6
        height = PLAYER_HEIGHT
        maxHealth = 20
        health = 20
        speed = 0.1
        persistent = true
        stepHeight = 0.6
    }

    public var mainHandStack: ItemStack? { inventory[selectedSlot] }
    public override var mainHand: ItemStack? {
        get { inventory[selectedSlot] }
        set { inventory[selectedSlot] = newValue }
    }

    public var hasFlyingWandEquipped: Bool {
        guard let stack = mainHandStack else { return false }
        return itemDef(stack.id).name == FLYING_WAND_ITEM_NAME
    }

    private var canUseFlyingWandFlight: Bool {
        hasFlyingWandEquipped && !flyingWandFallLocked
    }

    public func canUseCreativeFlight() -> Bool {
        gameMode == GameMode.creative || canUseFlyingWandFlight
    }

    private func clearFlyingWandFallState() {
        flyingWandFallLocked = false
        flyingWandFallDamageMultiplier = nil
    }

    private func clearFlyingWandFallStateIfSettled() {
        if onGround || inWater || isClimbing() {
            clearFlyingWandFallState()
        }
    }

    private func stopFlyingWandFlightForUnequip() {
        let wasWandFlight = flyingWandFlightActive
        flying = false
        flyingWandFlightActive = false
        creativeFlightLaunchTicks = 0
        lastCreativeJumpPress = nil
        if wasWandFlight && !onGround {
            flyingWandFallLocked = true
            flyingWandFallDamageMultiplier = FLYING_WAND_FALL_DAMAGE_MULTIPLIER
            fallDistance = 0
        }
    }

    public func syncFlightEquipmentState() {
        clearFlyingWandFallStateIfSettled()
        if gameMode == GameMode.creative {
            flyingWandFlightActive = false
            return
        }
        if flying && !canUseFlyingWandFlight {
            stopFlyingWandFlightForUnequip()
        } else if flying {
            flyingWandFlightActive = true
        }
    }

    public func beginUsingMainHand() {
        usingItem = true
        useItemTicks = 0
        useItemHand = "main"
        useItemSlot = selectedSlot
        useItemItemId = mainHand?.id ?? -1
    }

    public func cancelUsingItem() {
        usingItem = false
        useItemTicks = 0
        useItemHand = "main"
        useItemSlot = -1
        useItemItemId = -1
    }

    public func usingMainHandStack() -> ItemStack? {
        guard useItemHand == "main",
              useItemSlot >= 0,
              useItemSlot < inventory.count,
              selectedSlot == useItemSlot,
              let stack = inventory[useItemSlot],
              stack.id == useItemItemId
        else { return nil }
        return stack
    }

    public func consumeUsingMainHand(_ n: Int) {
        if gameMode == GameMode.creative { return }
        guard useItemSlot >= 0, useItemSlot < inventory.count, let stack = inventory[useItemSlot] else { return }
        stack.count -= n
        if stack.count <= 0 { inventory[useItemSlot] = nil }
    }

    public func replaceUsingMainHand(_ stack: ItemStack) {
        if gameMode == GameMode.creative {
            if countItem(stack.id) == 0 { give(stack) }
            return
        }
        guard useItemSlot >= 0, useItemSlot < inventory.count else { return }
        if let current = inventory[useItemSlot], current.count > 1 {
            current.count -= 1
            if !give(stack) { spawnItem(world, x, y, z, stack) }
        } else {
            inventory[useItemSlot] = stack
        }
    }

    public override func eyeY() -> Double {
        y + (sneaking ? PLAYER_SNEAK_EYE : PLAYER_EYE)
    }

    public override func tick() {
        tickPlayer(advanceRPGClock: true, applyRPGGameplay: true)
    }

    /// GameCore owns the authoritative RPG clock. Keeping this entry point
    /// separate prevents Player.tick() from double-advancing host state and
    /// prevents a LAN client render step from locally consuming cooldowns.
    func tickFromGameCore(authoritativeRPG: Bool) {
        tickPlayer(advanceRPGClock: false, applyRPGGameplay: authoritativeRPG)
    }

    private func tickPlayer(advanceRPGClock: Bool, applyRPGGameplay: Bool) {
        height = sneaking ? PLAYER_SNEAK_HEIGHT : PLAYER_HEIGHT
        baseLivingTick()
        if dead { return }
        syncFlightEquipmentState()
        _wearingPumpkin = armor[0] != nil && itemDef(armor[0]!.id).name == "carved_pumpkin"
        advanceAttackStrengthRecovery(ticks: 1)
        if gameMode == GameMode.creative {
            hunger = 20
            airSupply = 300
            fireTicks = min(fireTicks, 0)
        } else {
            tickHunger()
        }
        if advanceRPGClock { tickRPGContinuousState() }
        if applyRPGGameplay { tickRPGGameplayState() }
        if sleepTicks > 0 { sleepTicks += 1 }
        if portalTicks > 0 && insidePortalKind == nil { portalTicks = max(0, portalTicks - 4) }
        // item magnet pickup
        if age % 2 == 0 && !dead {
            for e in world.getEntitiesNear(x, y + 0.5, z, 1.6) {
                if (e as? Entity)?.lanReplicatedMirror == true { continue }
                if let item = e as? ItemEntity, item.pickupDelay <= 0 {
                    let before = item.stack.count
                    if give(item.stack) {
                        world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.4 + Double.random(in: 0..<1) * 0.6)
                        item.remove()
                    } else if item.stack.count != before {
                        world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.4)
                    }
                } else if let orb = e as? XPOrb {
                    addXP(orb.amount)
                    world.hooks.playSound("entity.experience_orb.pickup", x, y, z, 0.4, 0.8 + Double.random(in: 0..<1) * 0.6)
                    orb.remove()
                }
            }
        }
        // elytra
        if elytraFlying {
            tickElytra()
            if onGround || inWater || !hasElytra() { elytraFlying = false }
        }
    }

    // =========================================================================
    // Vanilla-exact movement (Java 1.20). Overrides the shared LivingEntity
    // travel(), which mobs keep (their physics is golden-locked). References:
    // LocalPlayer.aiStep input shaping, LivingEntity.travel/handleRelative-
    // FrictionAndCalculateMovement, Entity.getBlockSpeedFactor.
    // =========================================================================
    public var noJumpDelay = 0

    /// speed attribute chain: base 0.1, sprint ×1.3, speed/slowness effects
    private func vanillaSpeed() -> Double {
        var s = 0.1
        if sprinting { s *= 1.3 }
        s *= 1 + 0.2 * Double(effectLevel("speed"))
        s *= max(0, 1 - 0.15 * Double(effectLevel("slowness")))
        return s
    }

    private func slipperiness(_ id: Int) -> Double {
        if id == Int(B.ice) || id == Int(B.packed_ice) || id == Int(B.frosted_ice) { return 0.98 }
        if id == Int(B.blue_ice) { return 0.989 }
        if id == Int(B.slime_block) { return 0.8 }
        return 0.6
    }

    private func moveRelativeP(_ f: Double, _ s: Double, _ accel: Double) {
        var ff = f, ss = s
        let lenSq = ff * ff + ss * ss
        if lenSq < 1e-7 { return }
        if lenSq > 1 {
            let len = lenSq.squareRoot()
            ff /= len
            ss /= len
        }
        let sn = detSin(yaw), cs = detCos(yaw)
        vx += (ss * cs - ff * sn) * accel
        vz += (ff * cs + ss * sn) * accel
    }

    private func wouldCollide(_ dx: Double, _ dy: Double, _ dz: Double) -> Bool {
        let b = bb()
        let test = AABB(b.x0 + dx, b.y0 + dy, b.z0 + dz, b.x1 + dx, b.y1 + dy, b.z1 + dz)
        var hit = false
        world.forEachCollisionBox(test) { box in
            if box.intersects(test) { hit = true }
        }
        return hit
    }

    private func jumpFromGround() {
        // honey reduces jump height (block at feet or below)
        let at = world.getBlockId(ifloor(x), ifloor(y), ifloor(z))
        let below = world.getBlockId(ifloor(x), ifloor(y - 0.5000001), ifloor(z))
        let jumpFactor = (at == Int(B.honey_block) || below == Int(B.honey_block)) ? 0.5 : 1.0
        vy = 0.42 * jumpFactor + Double(effectLevel("jump_boost")) * 0.1
        if sprinting {
            vx += -detSin(yaw) * 0.2
            vz += detCos(yaw) * 0.2
        }
        onGround = false
        addExhaustion(sprinting ? 0.2 : 0.05)
    }

    @discardableResult
    public func creativeJumpPressed(now: Double) -> Bool {
        defer { lastCreativeJumpPress = now }
        guard canUseCreativeFlight() else { return false }
        guard let last = lastCreativeJumpPress, now - last < CREATIVE_FLIGHT_DOUBLE_JUMP_MS else { return false }
        return startCreativeFlight()
    }

    @discardableResult
    public func startCreativeFlight() -> Bool {
        guard canUseCreativeFlight() else {
            flying = false
            flyingWandFlightActive = false
            return false
        }
        flying = true
        flyingWandFlightActive = gameMode != GameMode.creative
        elytraFlying = false
        sneaking = false
        onGround = false
        noJumpDelay = 0
        fallDistance = 0
        creativeFlightLaunchTicks = 1
        if vy < CREATIVE_FLIGHT_VERTICAL_SPEED { vy = CREATIVE_FLIGHT_VERTICAL_SPEED }
        return true
    }

    public func travelCreativeFlight(ascend: Bool, descend: Bool) {
        guard canUseCreativeFlight() && flying else {
            if gameMode != GameMode.creative { stopFlyingWandFlightForUnequip() }
            return
        }
        flyingWandFlightActive = gameMode != GameMode.creative
        if ascend {
            vy = CREATIVE_FLIGHT_VERTICAL_SPEED
            creativeFlightLaunchTicks = 0
        } else if descend {
            vy = -CREATIVE_FLIGHT_VERTICAL_SPEED
            creativeFlightLaunchTicks = 0
        } else if creativeFlightLaunchTicks > 0 {
            vy = max(vy, CREATIVE_FLIGHT_VERTICAL_SPEED)
            creativeFlightLaunchTicks -= 1
        } else {
            vy = 0
        }
        let speed = sprinting ? 0.05 : 0.025
        let sin = detSin(yaw), cos = detCos(yaw)
        vx += (moveStrafe * cos - moveForward * sin) * speed * 2.5
        vz += (moveForward * cos + moveStrafe * sin) * speed * 2.5
        move(vx, vy, vz)
        vx *= 0.85
        vy *= 0.6
        vz *= 0.85
        fallDistance = 0
        if onGround {
            flying = false
            flyingWandFlightActive = false
        }
    }

    public override func travel() {
        // ---- input shaping (LocalPlayer.aiStep) ----
        var f = moveForward, s = moveStrafe
        if sneaking {
            // swift sneak raises the 0.3 sneak multiplier toward 1.0
            let swift = armor[2].map { enchLevel($0, "swift_sneak") } ?? 0
            let mult = rpgSneakingMovementMultiplier(self, swiftSneakLevel: swift)
            f *= mult
            s *= mult
        }
        f *= 0.98
        s *= 0.98

        // ---- jumping (before physics, 10-tick re-jump delay while held) ----
        if noJumpDelay > 0 { noJumpDelay -= 1 }
        let fluid = inWater || inLava
        if jumping {
            if fluid {
                vy += 0.04
            } else if onGround && noJumpDelay == 0 {
                jumpFromGround()
                noJumpDelay = 10
            }
        } else {
            noJumpDelay = 0
        }

        if inWater {
            // ---- water (LivingEntity.travel water branch) ----
            let yBefore = y
            var waterSlow = sprinting ? 0.9 : 0.8   // vanilla sprint-swim inertia
            var speed = 0.02
            var ds = Double(armor[3].map { enchLevel($0, "depth_strider") } ?? 0)
            ds = min(3, ds)
            if !onGround { ds *= 0.5 }
            if ds > 0 {
                waterSlow += (0.54600006 - waterSlow) * ds / 3
                speed += (vanillaSpeed() - speed) * ds / 3
            }
            if hasEffect("dolphins_grace") { waterSlow = 0.96 }
            moveRelativeP(f, s, speed)
            move(vx, vy, vz)
            vx *= waterSlow
            vy *= 0.8
            vz *= waterSlow
            // fluid-falling gravity: 0.08/16 with the vanilla epsilon snap
            if !noGravity && !sprinting {
                let falling = vy <= 0
                if falling && abs(vy - 0.005) >= 0.003 && abs(vy - 0.08 / 16) < 0.003 {
                    vy = -0.003
                } else {
                    vy -= 0.08 / 16
                }
            }
            // hop out at edges
            if horizontalCollision && !wouldCollide(vx, vy + 0.6 - y + yBefore, vz) {
                vy = 0.3
            }
        } else if inLava {
            // ---- lava ----
            let yBefore = y
            moveRelativeP(f, s, 0.02)
            move(vx, vy, vz)
            vx *= 0.5
            vy *= 0.5
            vz *= 0.5
            if !noGravity {
                let falling = vy <= 0
                if falling && abs(vy - 0.005) >= 0.003 && abs(vy - 0.08 / 16) < 0.003 {
                    vy = -0.003
                } else {
                    vy -= 0.08 / 16
                }
            }
            if horizontalCollision && !wouldCollide(vx, vy + 0.6 - y + yBefore, vz) {
                vy = 0.3
            }
        } else {
            // ---- land / air ----
            let below = world.getBlockId(ifloor(x), ifloor(y - 0.5000001), ifloor(z))
            let slip = slipperiness(below)
            let friction = onGround ? slip * 0.91 : 0.91
            // 0.216/slip³ with the ×0.98 input gives the exact vanilla speeds:
            // walk 4.3172, sprint 5.6114, sneak 1.295 blocks/s at equilibrium
            let accel = onGround
                ? vanillaSpeed() * 0.21600002 / (slip * slip * slip)
                : 0.02 + (sprinting ? 0.006 : 0)
            moveRelativeP(f, s, accel)
            // climbing clamps (before move)
            if isClimbing() {
                vx = clampD(vx, -0.15, 0.15)
                vz = clampD(vz, -0.15, 0.15)
                if vy < -0.15 { vy = -0.15 }
                if sneaking && vy < 0 { vy = 0 }
            }
            move(vx, vy, vz)
            // pushing into a climbable (or jumping on it) climbs
            if (horizontalCollision || jumping) && isClimbing() {
                vy = 0.2
            }
            // gravity + drag
            if hasEffect("levitation") {
                vy += (0.05 * Double(effectLevel("levitation") + 1) - vy) * 0.2
                fallDistance = 0
            } else if !noGravity {
                var g = 0.08 * gravityScale
                if hasEffect("slow_falling") && vy <= 0 {
                    g = 0.01
                    fallDistance = 0
                }
                vy -= g
            }
            vy *= 0.98
            vx *= friction
            vz *= friction
            // soul sand velocity factor (honey is damped inside move())
            let at = world.getBlockId(ifloor(x), ifloor(y), ifloor(z))
            let under = at == 0 ? world.getBlockId(ifloor(x), ifloor(y - 0.5000001), ifloor(z)) : at
            if under == Int(B.soul_sand) {
                let soulSpeed = armor[3].map { enchLevel($0, "soul_speed") } ?? 0
                if soulSpeed == 0 {
                    vx *= 0.4
                    vz *= 0.4
                }
            }
        }

        // limb animation (matches LivingEntity)
        let dxm = x - prevX, dzm = z - prevZ
        let moved = min(1, (dxm * dxm + dzm * dzm).squareRoot() * 4)
        limbAmp += (moved - limbAmp) * 0.4
        limbSwing += limbAmp * 1.2
    }

    /// vanilla maybeBackOffFromEdge — sneaking on the ground never walks off
    public override func move(_ dxIn: Double, _ dyIn: Double, _ dzIn: Double) {
        var dx = dxIn, dz = dzIn
        if sneaking && onGround && dyIn <= 0 && !flying {
            let step = 0.05
            while dx != 0 && !wouldCollide(dx, -maxUpStep(), 0) {
                dx = abs(dx) <= step ? 0 : dx - (dx > 0 ? step : -step)
            }
            while dz != 0 && !wouldCollide(0, -maxUpStep(), dz) {
                dz = abs(dz) <= step ? 0 : dz - (dz > 0 ? step : -step)
            }
            while dx != 0 && dz != 0 && !wouldCollide(dx, -maxUpStep(), dz) {
                dx = abs(dx) <= step ? 0 : dx - (dx > 0 ? step : -step)
                dz = abs(dz) <= step ? 0 : dz - (dz > 0 ? step : -step)
            }
        }
        super.move(dx, dyIn, dz)
    }
    private func maxUpStep() -> Double { stepHeight }

    private func attackSpeedPerTick() -> Double {
        let t = mainHand.map { itemDef($0.id).tool } ?? nil
        let speed = t?.attackSpeed ?? 4
        return speed * 5 // reaches 100 in 20/speed ticks
    }

    public func advanceAttackStrengthRecovery(ticks: Int) {
        guard ticks > 0, ticks <= RPG_MAX_EFFECT_TICKS,
              attackStrengthTicker.isFinite else { return }
        attackStrengthTicker = min(100,
                                   attackStrengthTicker + attackSpeedPerTick() * Double(ticks))
    }
    public func attackStrength() -> Double {
        clampD(attackStrengthTicker / 100, 0, 1)
    }
    public func resetAttackCooldown() {
        attackStrengthTicker = 0
    }

    public func hasElytra() -> Bool {
        guard let chest = armor[1], itemDef(chest.id).name == "elytra" else { return false }
        return chest.damage < (itemDef(chest.id).armor?.durability ?? 432) - 1
    }
    @discardableResult
    public func startElytra() -> Bool {
        if !onGround && !elytraFlying && !inWater && hasElytra() {
            elytraFlying = true
            return true
        }
        return false
    }
    private func tickElytra() {
        // vanilla elytra physics
        let pitch = self.pitch
        let lookX = -detSin(yaw) * detCos(pitch)
        let lookZ = detCos(yaw) * detCos(pitch)
        let hLook = (lookX * lookX + lookZ * lookZ).squareRoot()
        let hVel = (vx * vx + vz * vz).squareRoot()
        let cosP = detCos(pitch)
        let cosP2 = cosP * cosP
        let g = hasEffect("slow_falling") && vy <= 0 ? 0.01 : 0.08
        vy += g * (-1 + cosP2 * 0.75)
        if vy < 0 && hLook > 0 {
            let lift = vy * -0.1 * cosP2
            vx += lookX / hLook * lift
            vy += lift
            vz += lookZ / hLook * lift
        }
        if pitch < 0 && hLook > 0 {
            // vanilla scales only the VERTICAL component by 3.2
            let pull = hVel * -detSin(pitch) * 0.04
            vx += -lookX / hLook * pull
            vy += pull * 3.2
            vz += -lookZ / hLook * pull
        }
        if hLook > 0 {
            vx += (lookX / hLook * hVel - vx) * 0.1
            vz += (lookZ / hLook * hVel - vz) * 0.1
        }
        vx *= 0.99
        vy *= 0.98
        vz *= 0.99
        // durability
        if age % 20 == 0, let chest = armor[1] {
            damageStack(chest, 1)
        }
        // wall smack damage
        if horizontalCollision {
            let speed = (vx * vx + vy * vy + vz * vz).squareRoot()
            let dmg = speed * 10 - 3
            if dmg > 0 { hurt(dmg, "fly_into_wall") }
        }
    }

    // ---- hunger ------------------------------------------------------------
    public override func addExhaustion(_ amount: Double) {
        if gameMode == GameMode.creative { return }
        let multiplier = rpgClassesEnabled() && rpg.created ? rpgDerivedStats(rpg).exhaustionMultiplier : 1
        exhaustion += max(0, amount) * multiplier
        while exhaustion >= 4 {
            exhaustion -= 4
            if saturation > 0 { saturation = max(0, saturation - 1) }
            else { hunger = max(0, hunger - 1) }
        }
    }
    public override func feed(_ hungerIn: Int, _ saturationIn: Double) {
        hunger = min(20, hunger + hungerIn)
        saturation = min(Double(hunger), saturation + saturationIn)
    }
    private func tickHunger() {
        foodTickTimer += 1
        if hunger >= 18 && health < maxHealth && world.rule("naturalRegeneration") {
            let fast = hunger >= 20 && saturation > 0
            if foodTickTimer >= (fast ? 10 : 80) {
                heal(1)
                addExhaustion(fast ? 6 : 6)
                foodTickTimer = 0
            }
        } else if hunger <= 0 {
            if foodTickTimer >= 80 {
                let diff = world.difficulty
                if health > (diff >= 3 ? 0 : diff == 2 ? 1 : 10) { hurt(1, "starve") }
                foodTickTimer = 0
            }
        } else if foodTickTimer > 80 {
            foodTickTimer = 0
        }
        // sprint exhaustion handled in movement; swimming:
        if inWater && (abs(x - prevX) > 0.01 || abs(z - prevZ) > 0.01) {
            let dx = x - prevX, dz = z - prevZ
            addExhaustion(0.01 * (dx * dx + dz * dz).squareRoot() * 5)
        } else if sprinting && onGround {
            let dx = x - prevX, dz = z - prevZ
            addExhaustion(0.1 * (dx * dx + dz * dz).squareRoot())
        }
    }

    // ---- XP ------------------------------------------------------------------
    public func xpForLevel(_ level: Int) -> Int {
        if level >= 30 { return 112 + (level - 30) * 9 }
        if level >= 15 { return 37 + (level - 15) * 5 }
        return 7 + level * 2
    }
    public func addXP(_ pointsIn: Int) {
        var points = pointsIn
        // mending first
        if points > 0 {
            var mendables: [ItemStack] = []
            var candidates: [ItemStack?] = [mainHand, offHand]
            candidates.append(contentsOf: armor)
            for s in candidates {
                if let s, enchLevel(s, "mending") > 0, s.damage > 0 { mendables.append(s) }
            }
            if !mendables.isEmpty {
                let s = mendables[gameRng.nextInt(mendables.count)]
                let repair = min(s.damage, points * 2)
                s.damage -= repair
                points -= Int((Double(repair) / 2).rounded(.up))
            }
        }
        xp += points
        var need = Double(xpForLevel(xpLevel))
        var cur = xpProgress * need + Double(points)
        while cur >= need {
            cur -= need
            xpLevel += 1
            need = Double(xpForLevel(xpLevel))
            world.hooks.playSound("entity.player.levelup", x, y, z, 0.7, 1)
        }
        while cur < 0 && xpLevel > 0 {
            xpLevel -= 1
            need = Double(xpForLevel(xpLevel))
            cur += need
        }
        xpProgress = max(0, cur / need)
    }
    public func takeLevels(_ levels: Int) {
        xpLevel = max(0, xpLevel - levels)
        xpProgress = 0
    }

    // ---- inventory -------------------------------------------------------------
    @discardableResult
    public override func give(_ stackIn: ItemStack?) -> Bool {
        guard let stack = stackIn else { return false }
        // merge into existing
        for i in 0..<inventory.count where stack.count > 0 {
            if let s = inventory[i], canMerge(s, stack) {
                let space = maxStackOf(s) - s.count
                let take = min(space, stack.count)
                s.count += take
                stack.count -= take
            }
        }
        if stack.count <= 0 { return true }
        for i in 0..<inventory.count {
            if inventory[i] == nil {
                inventory[i] = stack.copy()
                stack.count = 0
                return true
            }
        }
        return false
    }
    public func countItem(_ itemId: Int) -> Int {
        var n = 0
        for s in inventory { if let s, s.id == itemId { n += s.count } }
        return n
    }
    @discardableResult
    public func removeItems(_ itemId: Int, _ countIn: Int) -> Bool {
        if countItem(itemId) < countIn { return false }
        var count = countIn
        for i in 0..<inventory.count where count > 0 {
            if let s = inventory[i], s.id == itemId {
                let take = min(s.count, count)
                s.count -= take
                count -= take
                if s.count <= 0 { inventory[i] = nil }
            }
        }
        return true
    }
    public override func consumeHeld(_ n: Int) {
        if gameMode == GameMode.creative { return }
        guard let s = mainHand else { return }
        s.count -= n
        if s.count <= 0 { mainHand = nil }
    }
    public override func replaceHeld(_ stack: ItemStack) {
        let s = mainHand
        if gameMode == GameMode.creative {
            if countItem(stack.id) == 0 { give(stack) }
            return
        }
        if let s, s.count > 1 {
            s.count -= 1
            if !give(stack) { spawnItem(world, x, y, z, stack) }
        } else {
            mainHand = stack
        }
    }
    public override func damageHeld(_ amount: Int) {
        if let s = mainHand { damageStack(s, amount) }
    }
    public func damageStack(_ s: ItemStack, _ amount: Int) {
        if gameMode == GameMode.creative { return }
        let def = itemDef(s.id)
        let maxD = def.tool?.durability ?? def.armor?.durability ?? 0
        if maxD <= 0 { return }
        let unb = enchLevel(s, "unbreaking")
        for _ in 0..<amount {
            if unb > 0 && gameRng.nextFloat() < Double(unb) / Double(unb + 1) { continue }
            if def.tool != nil && shouldPreserveRPGToolDurability() { continue }
            s.damage += 1
        }
        if s.damage >= maxD {
            // break
            if let idx = inventory.firstIndex(where: { $0 === s }) { inventory[idx] = nil }
            if let aIdx = armor.firstIndex(where: { $0 === s }) { armor[aIdx] = nil }
            if offHand === s { offHand = nil }
            world.hooks.playSound("entity.item.break", x, y, z, 0.8, 1)
        }
    }
    public func dropSelected(_ all: Bool) {
        guard let s = mainHand else { return }
        let count = all ? s.count : 1
        let dropped = s.copy()
        dropped.count = count
        s.count -= count
        if s.count <= 0 { mainHand = nil }
        let e = spawnItem(world, x, eyeY() - 0.3, z, dropped)
        e.vx = -detSin(yaw) * 0.3
        e.vy = 0.1
        e.vz = detCos(yaw) * 0.3
        e.pickupDelay = 40
    }

    // ---- combat / death -------------------------------------------------------
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if gameMode == GameMode.creative { return false }
        let r = super.hurt(amount, source, attacker)
        if r {
            addExhaustion(0.1)
            sleepTicks = 0
            bedPos = nil
        }
        return r
    }
    public override func fallDamageMultiplier(for fallDistance: Double) -> Double {
        flyingWandFallDamageMultiplier ?? super.fallDamageMultiplier(for: fallDistance)
    }
    public override func onLand(_ fallDistance: Double) {
        defer {
            clearFlyingWandFallState()
            flyingWandFlightActive = false
        }
        super.onLand(fallDistance)
    }
    public override func die(_ source: String, _ attacker: Entity? = nil) {
        if deathTime > 0 { return }
        // totem of undying
        for hand in 0..<2 {
            let s = hand == 0 ? mainHand : offHand
            if let s, itemDef(s.id).name == "totem_of_undying" {
                if hand == 0 { mainHand = nil } else { offHand = nil }
                health = 1
                clearEffects()
                addEffect("regeneration", 900, 1)
                addEffect("absorption", 100, 1)
                addEffect("fire_resistance", 800, 0)
                world.hooks.playSound("item.totem.use", x, y, z, 1, 1)
                world.hooks.addParticles("totem", x, y + 1, z, 60, 0.6, 0)
                return
            }
        }
        health = 0
        deathTime = 1
        world.cancelRPGTemporaryEffects(ownerID: effectiveRPGAuthorityID)
        _ = world.removeRPGWardenMitigationLayers(
            ownerAuthorityID: effectiveRPGAuthorityID
        )
        clearRPGTerminalUpkeeps()
        data.deathCause = source
        data.deathAttacker = lastAttacker.map { prettyEntityName($0.type) }
        world.hooks.playSound("entity.player.death", x, y, z, 1, 1)
        if !world.rule("keepInventory") {
            for i in 0..<inventory.count {
                if let s = inventory[i] {
                    spawnItem(world, x, y + 0.5, z, s)
                    inventory[i] = nil
                }
            }
            for i in 0..<4 {
                if let s = armor[i] {
                    spawnItem(world, x, y + 0.5, z, s)
                    armor[i] = nil
                }
            }
            if let oh = offHand { spawnItem(world, x, y + 0.5, z, oh); offHand = nil }
            spawnXP(world, x, y, z, min(xpLevel * 7, 100))
            xpLevel = 0; xpProgress = 0; xp = 0
        }
    }
    public override func tickDeath() {
        deathTime += 1
        // Game shows death screen; respawn via respawn()
    }
    public func respawn() {
        dead = false
        deathTime = 0
        health = maxHealth
        hunger = 20
        saturation = 5
        exhaustion = 0
        fireTicks = 0
        airSupply = 300
        fallDistance = 0
        clearEffects()
        vx = 0; vy = 0; vz = 0
    }

    public override func save() -> [String: Any] {
        save(omitLegacyQuickSlots: rpgLegacyQuickSlotEnvelope?.omissionEligible == true)
    }

    /// Builds a detached player candidate. Passing `true` is reserved for GameCore's checked
    /// player-row CAS; it never mutates the live envelope or makes ordinary saves omit early.
    public func save(omitLegacyQuickSlots: Bool) -> [String: Any] {
        var d = super.save()
        func enc<T: Encodable>(_ v: T) -> Any? {
            guard let bytes = try? JSONEncoder().encode(v) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        }
        d["inventory"] = enc(inventory)
        d["enderChest"] = enc(enderChest)
        d["armor"] = enc(armor)
        if let oh = offHand { d["offHand"] = enc(oh) }
        d["selectedSlot"] = selectedSlot
        d["hunger"] = hunger
        d["saturation"] = saturation
        d["xpLevel"] = xpLevel
        d["xpProgress"] = xpProgress
        d["health"] = health
        d["gameMode"] = gameMode
        if let sp = spawnPoint { d["spawnPoint"] = [sp.0, sp.1, sp.2] }
        d["spawnDim"] = spawnDim
        d["effects"] = enc(effects)
        d["stats"] = stats
        if var encodedRPG = enc(repairRPGCharacterState(rpg)) as? [String: Any] {
            if let envelope = rpgLegacyQuickSlotEnvelope, !omitLegacyQuickSlots {
                encodedRPG["actionQuickSlots"] = envelope.preferences.tokens.map {
                    ($0 as Any?) ?? NSNull()
                }
            }
            d["rpg"] = encodedRPG
        }
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        func dec<T: Decodable>(_ raw: Any?, _ type: T.Type) -> T? {
            guard let raw,
                  let bytes = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONDecoder().decode(type, from: bytes)
        }
        inventory = dec(d["inventory"], [ItemStack?].self) ?? Array(repeating: nil, count: 36)
        enderChest = dec(d["enderChest"], [ItemStack?].self) ?? Array(repeating: nil, count: 27)
        armor = dec(d["armor"], [ItemStack?].self) ?? [nil, nil, nil, nil]
        offHand = dec(d["offHand"], ItemStack.self)
        // harden against corrupt/truncated saves: fix array sizes, clamp the
        // hotbar slot, drop stacks with out-of-range item ids (itemDefs is
        // indexed unchecked in hot paths)
        while inventory.count < 36 { inventory.append(nil) }
        while enderChest.count < 27 { enderChest.append(nil) }
        while armor.count < 4 { armor.append(nil) }
        let nItems = UInt16(itemDefs.count)
        func valid(_ s: ItemStack?) -> ItemStack? { (s?.id ?? 0) < nItems ? s : nil }
        for i in 0..<inventory.count { inventory[i] = valid(inventory[i]) }
        for i in 0..<enderChest.count { enderChest[i] = valid(enderChest[i]) }
        for i in 0..<armor.count { armor[i] = valid(armor[i]) }
        offHand = valid(offHand)
        selectedSlot = min(8, max(0, inum(d["selectedSlot"])))
        hunger = (d["hunger"] as? NSNumber)?.intValue ?? 20
        saturation = (d["saturation"] as? NSNumber)?.doubleValue ?? 5
        xpLevel = inum(d["xpLevel"])
        xpProgress = dnum(d["xpProgress"])
        health = (d["health"] as? NSNumber)?.doubleValue ?? 20
        _gameMode = inum(d["gameMode"])
        rpgDecodedVersionExceedsCurrent = false
        if let rawRPG = d["rpg"], JSONSerialization.isValidJSONObject(rawRPG),
           let bytes = try? JSONSerialization.data(withJSONObject: rawRPG, options: [.fragmentsAllowed]),
           bytes.count <= RPG_MAX_PERSISTED_PAYLOAD_BYTES,
           let decoded = try? JSONDecoder().decode(RPGCharacterState.self, from: bytes) {
            rpg = decoded
            rpgDecodedVersionExceedsCurrent = decoded.version > RPG_STATE_CURRENT_VERSION
            if let object = rawRPG as? [String: Any], object.keys.contains("actionQuickSlots") {
                let next = rpgLegacyEnvelopeVersion.addingReportingOverflow(1)
                if !next.overflow, next.partialValue > 0 {
                    rpgLegacyEnvelopeVersion = next.partialValue
                    rpgLegacyQuickSlotEnvelope = rpgExtractLegacyQuickSlotEnvelope(
                        from: object["actionQuickSlots"], envelopeVersion: next.partialValue)
                }
            } else {
                rpgLegacyQuickSlotEnvelope = nil
            }
        } else {
            // A malformed or oversized RPG component must not discard the
            // player's inventory, pose, health, or other vanilla save data.
            rpg = .uncreated()
            rpgLegacyQuickSlotEnvelope = nil
        }
        rpg = repairRPGCharacterState(rpg)
        // Active upkeep has no durable world counterpart: temporary servants,
        // auras, and images are deliberately omitted from chunk persistence.
        clearRPGTerminalUpkeeps()
        applyRPGDerivedStats()
        if let sp = d["spawnPoint"] as? [NSNumber], sp.count == 3 {
            spawnPoint = (sp[0].intValue, sp[1].intValue, sp[2].intValue)
        } else {
            spawnPoint = nil
        }
        spawnDim = inum(d["spawnDim"])
        stats = (d["stats"] as? [String: NSNumber])?.reduce(into: [:]) { result, pair in
            let value = pair.value.doubleValue
            result[pair.key] = value.isFinite ? max(0, min(Double(RPG_MAX_COUNTER), value)) : 0
        } ?? [:]
        if let fx = dec(d["effects"], [ActiveEffect].self) {
            for e in fx {
                if let i = effects.firstIndex(where: { $0.id == e.id }) { effects[i] = e }
                else { effects.append(e) }
            }
        }
    }

    /// Called only after GameCore verifies exact session provenance, source digest, and immutable
    /// migration origin. Returning false preserves the compatibility key byte-for-byte.
    @discardableResult
    public func markRPGLegacyQuickSlotsOmittable(
        envelopeVersion: UInt64, sourceDigest: LANV6SHA256Digest
    ) -> Bool {
        guard var envelope = rpgLegacyQuickSlotEnvelope,
              envelope.markOmissionEligible(
                envelopeVersion: envelopeVersion, sourceDigest: sourceDigest)
        else { return false }
        rpgLegacyQuickSlotEnvelope = envelope
        return true
    }
}
