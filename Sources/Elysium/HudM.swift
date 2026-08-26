// HUD — hotbar, hearts, hunger, armor, air, XP bar,
// crosshair, boss bars, effect icons, action bar, debug screen, subtitles,
// toasts. Same pixel layouts, drawn through UICanvas.

import Foundation
import QuartzCore
import ElysiumCore

/// A fixed spatial spectrum for the earned XP prefix.  It deliberately has no
/// clock input: progress changes colour only by growing into the next band.
struct XPRainbowSegment: Equatable {
    let x: Double
    let width: Double
    let color: String
}

func xpRainbowSegments(progress: Double, width: Double) -> [XPRainbowSegment] {
    guard width.isFinite, width > 0 else { return [] }
    let clampedProgress = progress.isNaN ? 0 : max(0, min(1, progress))
    let earned = min(width, (clampedProgress * width).rounded())
    guard earned > 0 else { return [] }
    let colors = [
        "#ff4040", "#ff9b32", "#ffe84d", "#6eea58",
        "#43d6c5", "#3978ff", "#9b70f5",
    ]
    var result: [XPRainbowSegment] = []
    for index in colors.indices {
        let start = (Double(index) * width / Double(colors.count)).rounded(.down)
        let end = (Double(index + 1) * width / Double(colors.count)).rounded(.down)
        let clippedEnd = min(earned, end)
        if clippedEnd > start {
            result.append(XPRainbowSegment(x: start, width: clippedEnd - start, color: colors[index]))
        }
    }
    return result
}

struct HeldOverlayPlan: Equatable {
    let armLayer: FirstPersonArmLayer
    let drawsGrip: Bool
    /// Grip point shared by the arm, foreground fingers, and held-item handle.
    let armX: Double
    let armY: Double
    let armAssetX: Double
    let armAssetY: Double
    let armAssetSize: Double
    /// The sleeve terminates on a screen edge so the arm never appears to float.
    let armBaseX: Double
    let armBaseY: Double
    /// Off-screen shoulder/sleeve pivot for the complete mining arc.
    let assemblyPivotX: Double
    let assemblyPivotY: Double
    let iconX: Double
    let iconY: Double
    let iconSize: Double
    let toolPivotX: Double
    let toolPivotY: Double
    let scale: Double
    /// `attack` is remaining attack progress: 1 and 0 are both rest.
    let attack: Double
    let use: Double
    let rotation: Double
    /// Late tool rotation around the fixed hand grip during a strike.
    let wristRotation: Double
    /// One-shot tool-only flourish around the fixed hand grip.
    let toolRotation: Double
    /// Conservative envelope of the transformed arm and optional icon.
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    /// True only when an opaque arm or item envelope covers the aim region.
    let obscuresCrosshair: Bool
}

struct LeftHandItemOverlayPlan: Equatable {
    let itemName: String
    let armAssetX: Double
    let armAssetY: Double
    let armAssetSize: Double
    let gripX: Double
    let gripY: Double
    let itemX: Double
    let itemY: Double
    let itemSize: Double
    let itemRotation: Double
}

struct BowOverlayPlan: Equatable {
    let frameName: String
    let drawProgress: Double
    let bow: LeftHandItemOverlayPlan
    let rightArmAssetX: Double?
    let rightArmAssetY: Double?
}

let HELD_EQUIP_FLIP_DURATION = 0.62
let HELD_PRIMARY_ACTION_CYCLE_DURATION = 0.32

private func armAssetOrigin(gripX: Double, gripY: Double,
                            size: Double, mirrored: Bool) -> (Double, Double) {
    let normalizedGripX = mirrored ? (1 - 0.361328125) : 0.361328125
    return (gripX - normalizedGripX * size,
            gripY - 0.498046875 * size)
}

func leftHandShieldOverlayPlan(viewWidth: Double, viewHeight: Double,
                               guiVisible: Bool, firstPerson: Bool,
                               screenOpen: Bool, hotbarLeftX: Double,
                               raised: Bool = false) -> LeftHandItemOverlayPlan? {
    guard guiVisible, firstPerson, !screenOpen,
          viewWidth.isFinite, viewHeight.isFinite, hotbarLeftX.isFinite,
          viewWidth >= 160, viewHeight >= 120 else { return nil }
    let scale = min(1.15, max(0.72, min(viewWidth / 320, viewHeight / 180)))
    let armSize = 160 * scale
    // The angled "held_shield" sprite has transparent margin around a 3D-posed shield, so it is
    // framed a touch larger than the old flat sprite and offset to sit over the fist. When the
    // shield is actively raised to block it rises up and swings inward toward the crosshair to
    // cover the centre — the same motion Minecraft's shield makes going idle → blocking.
    let itemSize = (raised ? 168 : 156) * scale
    let raiseUp = raised ? 40 * scale : 0
    let raiseIn = raised ? 34 * scale : 0
    let gripX = max(12 * scale, hotbarLeftX - 18 * scale) + raiseIn
    let gripY = viewHeight - 48 * scale - raiseUp
    let armOrigin = armAssetOrigin(
        gripX: gripX, gripY: gripY, size: armSize, mirrored: true)
    return LeftHandItemOverlayPlan(
        itemName: "held_shield",
        armAssetX: armOrigin.0, armAssetY: armOrigin.1, armAssetSize: armSize,
        gripX: gripX, gripY: gripY,
        itemX: gripX - itemSize * 0.58,
        itemY: gripY - itemSize * 0.64,
        itemSize: itemSize, itemRotation: 0)
}

/// A torch carried in the left (off) hand: stood upright in the fist with the flame up, held a
/// little in from the screen edge so it lights the way without blocking the view. The grip
/// fingers are drawn over the stick, same as a right-hand tool.
func leftHandTorchOverlayPlan(viewWidth: Double, viewHeight: Double,
                              guiVisible: Bool, firstPerson: Bool,
                              screenOpen: Bool, hotbarLeftX: Double) -> LeftHandItemOverlayPlan? {
    guard guiVisible, firstPerson, !screenOpen,
          viewWidth.isFinite, viewHeight.isFinite, hotbarLeftX.isFinite,
          viewWidth >= 160, viewHeight >= 120 else { return nil }
    let scale = min(1.15, max(0.72, min(viewWidth / 320, viewHeight / 180)))
    let armSize = 160 * scale
    let itemSize = 108 * scale
    let gripX = max(16 * scale, hotbarLeftX - 10 * scale)
    let gripY = viewHeight - 46 * scale
    let armOrigin = armAssetOrigin(
        gripX: gripX, gripY: gripY, size: armSize, mirrored: true)
    return LeftHandItemOverlayPlan(
        itemName: "held_torch",
        armAssetX: armOrigin.0, armAssetY: armOrigin.1, armAssetSize: armSize,
        gripX: gripX, gripY: gripY,
        itemX: gripX - itemSize * 0.5,
        itemY: gripY - itemSize * 0.86,
        itemSize: itemSize, itemRotation: 0)
}

func bowOverlayPlan(viewWidth: Double, viewHeight: Double,
                    guiVisible: Bool, firstPerson: Bool, screenOpen: Bool,
                    usingItem: Bool, useTicks: Int,
                    hotbarLeftX: Double) -> BowOverlayPlan? {
    guard guiVisible, firstPerson, !screenOpen,
          viewWidth.isFinite, viewHeight.isFinite, hotbarLeftX.isFinite,
          viewWidth >= 160, viewHeight >= 120 else { return nil }
    let scale = min(1.15, max(0.72, min(viewWidth / 320, viewHeight / 180)))
    let armSize = 160 * scale
    let bowSize = 138 * scale
    let ticks = max(0, useTicks)
    let progress = usingItem ? min(1, Double(ticks) / 20) : 0
    let raise = usingItem ? smoothStep(min(1, Double(ticks + 1) / 6)) : 0
    let leftRestX = max(12 * scale, hotbarLeftX - 18 * scale)
    let leftRestY = viewHeight - 48 * scale
    let leftRaisedX = max(armSize * 0.48, viewWidth * 0.34)
    let leftRaisedY = viewHeight * 0.60
    let gripX = leftRestX + (leftRaisedX - leftRestX) * raise
    let gripY = leftRestY + (leftRaisedY - leftRestY) * raise
    let bowRotation = -0.40 + (-0.78 + 0.40) * raise
    let armOrigin = armAssetOrigin(
        gripX: gripX, gripY: gripY, size: armSize, mirrored: true)
    let frameName: String
    switch ticks {
    case ..<6: frameName = usingItem ? "bow_pulling_0" : "bow"
    case ..<13: frameName = "bow_pulling_1"
    default: frameName = "bow_pulling_2"
    }
    let bowPlan = LeftHandItemOverlayPlan(
        itemName: frameName,
        armAssetX: armOrigin.0, armAssetY: armOrigin.1, armAssetSize: armSize,
        gripX: gripX, gripY: gripY,
        itemX: gripX - bowSize * 0.33,
        itemY: gripY - bowSize * 0.42,
        itemSize: bowSize, itemRotation: bowRotation)

    guard usingItem else {
        return BowOverlayPlan(frameName: frameName, drawProgress: 0, bow: bowPlan,
                              rightArmAssetX: nil, rightArmAssetY: nil)
    }
    // The right hand reaches the string during the raise, then travels toward
    // the player's cheek as projectile charge approaches full power.
    let reach = smoothStep(min(1, Double(ticks + 1) / 5))
    let stringX = gripX + 34 * scale
    let stringY = gripY - 8 * scale
    let restRightX = viewWidth - 52 * scale
    let restRightY = viewHeight - 48 * scale
    let reachedX = restRightX + (stringX - restRightX) * reach
    let reachedY = restRightY + (stringY - restRightY) * reach
    let pulledX = viewWidth * 0.63
    let pulledY = viewHeight * 0.48
    let rightGripX = reachedX + (pulledX - reachedX) * progress
    let rightGripY = reachedY + (pulledY - reachedY) * progress
    let rightOrigin = armAssetOrigin(
        gripX: rightGripX, gripY: rightGripY, size: armSize, mirrored: false)
    return BowOverlayPlan(frameName: frameName, drawProgress: progress, bow: bowPlan,
                          rightArmAssetX: rightOrigin.0,
                          rightArmAssetY: rightOrigin.1)
}

enum HeldItemPresentationKind: Equatable {
    case empty
    case tool
    case food
    case block
    case generic
}

struct HeldItemAlphaBounds: Equatable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

/// Rendering contract for a held-item family. New Meshy bakes plug into the item
/// asset registry; this profile supplies a stable pose even before bespoke art exists.
struct HeldItemPresentation: Equatable {
    let kind: HeldItemPresentationKind
    let armLayer: FirstPersonArmLayer
    let drawsGrip: Bool
    let iconBaseSize: Double
    let gripAnchorX: Double
    let gripAnchorY: Double
    let alphaBounds: HeldItemAlphaBounds
    let restRotation: Double
    let performsEquipFlip: Bool

    var hasItem: Bool { kind != .empty }
}

let GENERIC_HELD_ITEM_PRESENTATION = HeldItemPresentation(
    kind: .generic, armLayer: .back, drawsGrip: true,
    iconBaseSize: 60, gripAnchorX: 0.44, gripAnchorY: 0.70,
    alphaBounds: HeldItemAlphaBounds(minX: 0, minY: 0, maxX: 1, maxY: 1),
    restRotation: 0,
    performsEquipFlip: false)

func heldItemPresentation(for definition: ItemDef?, hasDetailedVisual: Bool) -> HeldItemPresentation {
    guard let definition else {
        return HeldItemPresentation(
            kind: .empty, armLayer: .empty, drawsGrip: false,
            iconBaseSize: 0, gripAnchorX: 0, gripAnchorY: 0,
            alphaBounds: HeldItemAlphaBounds(minX: 0, minY: 0, maxX: 0, maxY: 0),
            restRotation: 0,
            performsEquipFlip: false)
    }

    let full = HeldItemAlphaBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)
    if let tool = definition.tool {
        let detailedBounds = HeldItemAlphaBounds(
            minX: 2 / 128, minY: 2 / 128, maxX: 126 / 128, maxY: 126 / 128)
        let isBow = definition.name == "bow"
        let isCrossbow = definition.name == "crossbow"
        let isCompact = definition.name == "shears" || definition.name == "flint_and_steel"
        // Melee/mining tools whose authored image is upright: pickaxes use model renders and the
        // remaining families currently use aligned Faithful sprites. In both cases the handle is
        // a vertical column the fist grips directly, with no runtime counter-rotation. Grip anchor
        // is the pommel at the bottom-centre of the frame.
        let isUprightTool = hasDetailedVisual
            && ["sword", "axe", "shovel", "hoe", "pickaxe"].contains(tool.type)
        let iconSize: Double = isUprightTool ? 98
            : hasDetailedVisual ? (isCompact ? 96 : (isBow ? 112 : (isCrossbow ? 132 : 118)))
            : 82
        let gripX = isUprightTool ? 0.50
            : isBow ? 0.34
            : isCrossbow ? 0.78
            : isCompact ? 0.27
            : 0.16
        let gripY = isUprightTool ? 0.88
            : isBow ? 0.55
            : isCrossbow ? 0.87
            : isCompact ? 0.74
            : 0.86
        // Upright tools need no counter-rotation; the sprite is already vertical.
        let restRotation = isBow ? -0.08
            : isCompact ? -0.16
            : 0
        // Opaque envelope of the upright sprites (union of sword/axe/shovel/hoe/pickaxe): a
        // bottom-anchored vertical column, widened to admit the pickaxe head — used by the
        // crosshair-obscure and clamp math.
        let uprightBounds = HeldItemAlphaBounds(minX: 0.18, minY: 0, maxX: 0.86, maxY: 0.97)
        return HeldItemPresentation(
            kind: .tool, armLayer: .back, drawsGrip: true,
            iconBaseSize: iconSize,
            gripAnchorX: gripX,
            gripAnchorY: gripY,
            alphaBounds: isUprightTool ? uprightBounds
                : hasDetailedVisual ? detailedBounds : full,
            restRotation: restRotation,
            performsEquipFlip: true)
    }
    if definition.food != nil {
        return HeldItemPresentation(
            kind: .food, armLayer: .back, drawsGrip: true,
            iconBaseSize: 66, gripAnchorX: 0.44, gripAnchorY: 0.66,
            alphaBounds: full, restRotation: 0, performsEquipFlip: false)
    }
    if definition.block != nil {
        return HeldItemPresentation(
            kind: .block, armLayer: .back, drawsGrip: false,
            iconBaseSize: 70, gripAnchorX: 0.34, gripAnchorY: 0.72,
            alphaBounds: full, restRotation: -0.08, performsEquipFlip: false)
    }
    if definition.name == "shield", hasDetailedVisual {
        return HeldItemPresentation(
            kind: .generic, armLayer: .back, drawsGrip: false,
            iconBaseSize: 132, gripAnchorX: 0.46, gripAnchorY: 0.76,
            alphaBounds: HeldItemAlphaBounds(
                minX: 38 / 128, minY: 20 / 128, maxX: 90 / 128, maxY: 108 / 128),
            restRotation: -0.10, performsEquipFlip: false)
    }
    return GENERIC_HELD_ITEM_PRESENTATION
}

struct HeldPrimaryActionAnimationState: Equatable {
    private(set) var startedAt: Double?

    /// Returns a normalized repeating cycle while the primary button is held.
    /// Releasing, obscuring gameplay, or invalid time stops the cycle immediately.
    mutating func observe(isHeld: Bool, at now: Double, eligible: Bool) -> Double? {
        guard isHeld, eligible, now.isFinite else {
            startedAt = nil
            return nil
        }
        if startedAt == nil { startedAt = now }
        let elapsed = max(0, now - (startedAt ?? now))
        return elapsed.truncatingRemainder(dividingBy: HELD_PRIMARY_ACTION_CYCLE_DURATION)
            / HELD_PRIMARY_ACTION_CYCLE_DURATION
    }
}

struct HeldEquipmentAnimationState: Equatable {
    private(set) var itemID: Int?
    private(set) var flipStartedAt: Double?
    private(set) var initialized = false

    mutating func reset(to itemID: Int?) {
        self.itemID = itemID
        flipStartedAt = nil
        initialized = true
    }

    /// Returns 0...1 while a newly visible item performs its one-shot flip; 1 is rest.
    /// Hidden screens do not consume the transition, so an inventory equip is celebrated
    /// when gameplay becomes visible again rather than expiring behind the menu.
    mutating func observe(itemID newItemID: Int?, at now: Double,
                          eligible: Bool) -> Double {
        guard now.isFinite else { return 1 }
        guard eligible else { return 1 }
        if !initialized {
            reset(to: newItemID)
            return 1
        }
        if newItemID != itemID {
            itemID = newItemID
            flipStartedAt = newItemID == nil ? nil : now
        }
        guard let start = flipStartedAt else { return 1 }
        let elapsed = max(0, now - start)
        if elapsed + 1e-9 >= HELD_EQUIP_FLIP_DURATION {
            flipStartedAt = nil
            return 1
        }
        return min(1, elapsed / HELD_EQUIP_FLIP_DURATION)
    }
}

struct HeldMotionPose: Equatable {
    let x: Double
    let y: Double
    let armRotation: Double
    let wristRotation: Double
    let toolRotation: Double
}

private func smoothStep(_ value: Double) -> Double {
    let t = max(0, min(1, value))
    return t * t * (3 - 2 * t)
}

/// A first-person mining stroke driven by translation and rigid rotation. Held
/// model renders are never non-uniformly scaled: that used to visibly shear the
/// pickaxe during a strike. The per-axis scaling path is intentionally absent.
/// Attack progress is the engine's remaining value (1 -> 0); both endpoints are at rest.
func heldMotionPose(attack: Double, usingItem: Bool, useTicks: Int,
                    equipFlipProgress: Double,
                    primaryActionProgress: Double? = nil) -> HeldMotionPose {
    let engineRemaining = attack.isFinite ? max(0, min(1, attack)) : 0
    let remaining: Double
    if let progress = primaryActionProgress, progress.isFinite {
        remaining = 1 - max(0, min(1, progress))
    } else {
        remaining = engineRemaining
    }
    let use = usingItem ? min(1, Double(max(0, useTicks)) / 12) : 0
    let t = 1 - remaining
    let x: Double
    let y: Double
    let rotation: Double
    let wristRotation: Double
    if usingItem {
        let raised = smoothStep(use)
        x = -22 * raised
        y = -24 * raised
        rotation = 0.55 * raised
        wristRotation = 0
    } else if t <= 0 || t >= 1 {
        x = 0
        y = 0
        rotation = 0
        wristRotation = 0
    } else if t < 0.12 {
        // Brief shoulder-led wind-up before the tool accelerates toward the target.
        let p = smoothStep(t / 0.12)
        x = 4 * p
        y = -3 * p
        rotation = 0.10 * p
        wristRotation = 0.05 * p
    } else {
        let strike = (t - 0.12) / 0.88
        let rootArc = Foundation.sin(Foundation.sqrt(strike) * .pi)
        let strikeArc = Foundation.sin(strike * .pi)
        let verticalWave = Foundation.sin(Foundation.sqrt(strike) * .pi * 2)
        let unwind = 1 - strike
        x = 4 * unwind - 22 * rootArc
        y = -3 * unwind + 6 * verticalWave + 18 * strikeArc
        rotation = 0.10 * unwind - 0.34 * rootArc - 0.10 * strikeArc
        wristRotation = 0.05 * unwind - 0.20 * strikeArc
    }

    let flip = equipFlipProgress.isFinite ? max(0, min(1, equipFlipProgress)) : 1
    if flip >= 1 {
        return HeldMotionPose(x: x, y: y, armRotation: rotation,
                              wristRotation: wristRotation,
                              toolRotation: 0)
    }
    let easedFlip = smoothStep(flip)
    let handDip = Foundation.sin(flip * .pi) * 6
    let wristFollow = Foundation.sin(flip * .pi * 2) * 0.08
    return HeldMotionPose(x: x, y: y + handDip,
                          armRotation: rotation + wristFollow,
                          wristRotation: wristRotation,
                          toolRotation: easedFlip * .pi * 2)
}

func heldOverlayPlan(viewWidth: Double, viewHeight: Double,
                     guiVisible: Bool, firstPerson: Bool, screenOpen: Bool,
                     attack: Double, usingItem: Bool, useTicks: Int,
                     presentation: HeldItemPresentation = GENERIC_HELD_ITEM_PRESENTATION,
                     equipFlipProgress: Double = 1,
                     primaryActionProgress: Double? = nil,
                     hotbarRightX: Double? = nil,
                     rightObstruction: MapOverlayRect? = nil) -> HeldOverlayPlan? {
    guard guiVisible, firstPerson, !screenOpen,
          presentation.hasItem,
          viewWidth.isFinite, viewHeight.isFinite,
          viewWidth >= 160, viewHeight >= 120 else { return nil }
    let remaining = attack.isFinite ? max(0, min(1, attack)) : 0
    let use = usingItem ? min(1, Double(max(0, useTicks)) / 12) : 0
    let pose = heldMotionPose(attack: remaining, usingItem: usingItem,
                              useTicks: useTicks,
                              equipFlipProgress: equipFlipProgress,
                              primaryActionProgress: primaryActionProgress)
    let scale = min(1.15, max(0.72, min(viewWidth / 320, viewHeight / 180)))
    let iconSize = presentation.iconBaseSize * scale
    let armAssetSize = 160 * scale
    let motionScale = min(1, max(0.2, (viewWidth - 128) / 192))

    // Every layer starts from one rest grip. Motion offsets the grip while the
    // complete assembly rotates about the fixed shoulder/sleeve pivot below it.
    let anchoredHotbarRight = hotbarRightX.flatMap {
        $0.isFinite ? max(0, min(viewWidth, $0)) : nil
    }
    var restArmX = anchoredHotbarRight.map {
        min(viewWidth - 12 * scale, $0 + 18 * scale)
    } ?? (viewWidth - 52 * scale)
    let restArmY = viewHeight - 48 * scale
    let rotationScale = 0.4 + 0.6 * motionScale
    let rotation = pose.armRotation * rotationScale
    let toolRotation = pose.toolRotation
    var armBaseX = viewWidth
    let armBaseY = viewHeight

    // The Meshy arm's visible right edge is 58.4% of its canvas beyond the grip.
    // Keep that opaque edge left of a lower-right obstruction while allowing the
    // transparent canvas and offscreen sleeve tail to clip normally.
    let armRightOfGrip = (0.9453125 - 0.361328125) * armAssetSize
    // Reserve the full animated wrist/tool sweep, not merely the rest pose.
    // Without this margin the raised wind-up can touch the minimap and
    // make the entire first-person assembly disappear for one frame.
    let animatedRightClearance = 24 * scale
    if let obstruction = rightObstruction,
       obstruction.x.isFinite, obstruction.y.isFinite, obstruction.size.isFinite,
       obstruction.size > 0, obstruction.y < viewHeight,
       obstruction.x + obstruction.size > 0 {
        armBaseX = max(0, min(viewWidth, obstruction.x - 4))
        if anchoredHotbarRight == nil {
            restArmX = min(restArmX,
                           obstruction.x - 4 - armRightOfGrip - animatedRightClearance)
        }
    }
    // On compact viewports a correctly sized long-handled tool can otherwise sit
    // across the aim point. Prefer moving the rest grip left; the shoulder pivot
    // and all animation phases follow that correction as one assembly.
    if presentation.hasItem {
        let restIconMinY = restArmY - iconSize * presentation.gripAnchorY
            + iconSize * presentation.alphaBounds.minY
        let restIconMaxY = restArmY - iconSize * presentation.gripAnchorY
            + iconSize * presentation.alphaBounds.maxY
        if restIconMaxY > viewHeight / 2 - 24 && restIconMinY < viewHeight / 2 + 24 {
            let restIconMinX = restArmX - iconSize * presentation.gripAnchorX
                + iconSize * presentation.alphaBounds.minX
            let restIconMaxX = restArmX - iconSize * presentation.gripAnchorX
                + iconSize * presentation.alphaBounds.maxX
            if anchoredHotbarRight != nil {
                restArmX += max(0, (viewWidth / 2 + 25) - restIconMinX)
            } else {
                // One extra logical pixel avoids floating-point contact being treated
                // as overlap by the conservative crosshair envelope below.
                restArmX -= max(0, restIconMaxX - (viewWidth / 2 - 25))
            }
        }
    }
    let restArmMinY = restArmY + (0.38671875 - 0.498046875) * armAssetSize
    let restArmMaxY = restArmY + (1 - 0.498046875) * armAssetSize
    if restArmMaxY > viewHeight / 2 - 24 && restArmMinY < viewHeight / 2 + 24 {
        let restArmMinX = restArmX - (0.361328125 - 0.28515625) * armAssetSize
        let restArmMaxX = restArmX + armRightOfGrip
        if anchoredHotbarRight != nil {
            restArmX += max(0, (viewWidth / 2 + 25) - restArmMinX)
        } else {
            restArmX -= max(0, restArmMaxX - (viewWidth / 2 - 25))
        }
    }
    let baseArmX = restArmX + pose.x * scale * motionScale
    let baseArmY = restArmY + pose.y * scale * motionScale
    // The opaque sleeve exits below/right of the hand. Pivoting there produces the
    // broad shoulder/elbow arc of a striking tool instead of rotating the forearm
    // around a stationary wrist.
    let shoulderPivotX = restArmX + 0.38 * armAssetSize
    let shoulderPivotY = restArmY + 0.45 * armAssetSize
    let iconX = baseArmX - iconSize * presentation.gripAnchorX
    let iconY = baseArmY - iconSize * presentation.gripAnchorY
    let toolPivotX = iconX + iconSize / 2
    let toolPivotY = iconY + iconSize / 2
    let restWristRotation = anchoredHotbarRight != nil ? presentation.restRotation : 0
    let wristRotation = restWristRotation + pose.wristRotation

    // The item spins as one complete object around its own visual center. The
    // hand follows the rotated handle contact point, so head, handle, and grip
    // remain one physical assembly throughout the equip flourish.
    let gripDX = baseArmX - toolPivotX
    let gripDY = baseArmY - toolPivotY
    let toolCos = Foundation.cos(toolRotation)
    let toolSin = Foundation.sin(toolRotation)
    let armX = toolPivotX + gripDX * toolCos - gripDY * toolSin
    let armY = toolPivotY + gripDX * toolSin + gripDY * toolCos
    // Eating and the equip flourish retain their close wrist pivot; mining and
    // punching use the off-screen shoulder pivot for the complete assembly.
    let usesClosePivot = usingItem || abs(toolRotation) > 0.0001
    let assemblyPivotX = usesClosePivot ? armX : shoulderPivotX
    let assemblyPivotY = usesClosePivot ? armY : shoulderPivotY
    let armAssetX = armX - 0.361328125 * armAssetSize
    let armAssetY = armY - 0.498046875 * armAssetSize

    func transformed(_ x: Double, _ y: Double) -> (Double, Double) {
        let dx = x - assemblyPivotX, dy = y - assemblyPivotY
        let c = Foundation.cos(rotation), s = Foundation.sin(rotation)
        return (assemblyPivotX + dx * c - dy * s,
                assemblyPivotY + dx * s + dy * c)
    }
    func transformedTool(_ x: Double, _ y: Double) -> (Double, Double) {
        let dx = x - toolPivotX, dy = y - toolPivotY
        let c = Foundation.cos(toolRotation), s = Foundation.sin(toolRotation)
        let equippedX = toolPivotX + dx * c - dy * s
        let equippedY = toolPivotY + dx * s + dy * c
        let wristDX = equippedX - armX, wristDY = equippedY - armY
        let wristCos = Foundation.cos(wristRotation)
        let wristSin = Foundation.sin(wristRotation)
        return transformed(armX + wristDX * wristCos - wristDY * wristSin,
                           armY + wristDX * wristSin + wristDY * wristCos)
    }
    // Opaque bounds of the generated layers, excluding transparent canvas. Keep
    // arm and item envelopes separate: their combined AABB can cover empty space
    // between them and falsely report that the aim point is obscured.
    let armMinX = armAssetX + 0.28515625 * armAssetSize
    let armMaxX = armAssetX + 0.9453125 * armAssetSize
    let armMinY = armAssetY + 0.38671875 * armAssetSize
    let armMaxY = armAssetY + armAssetSize
    let armEnvelope = [
        transformed(armMinX, armMinY), transformed(armMaxX, armMinY),
        transformed(armMaxX, armMaxY), transformed(armMinX, armMaxY),
    ]
    var toolEnvelope: [(Double, Double)] = []
    if presentation.hasItem {
        let toolMinX = iconX + iconSize * presentation.alphaBounds.minX
        let toolMaxX = iconX + iconSize * presentation.alphaBounds.maxX
        let toolMinY = iconY + iconSize * presentation.alphaBounds.minY
        let toolMaxY = iconY + iconSize * presentation.alphaBounds.maxY
        toolEnvelope = [
            transformedTool(toolMinX, toolMinY), transformedTool(toolMaxX, toolMinY),
            transformedTool(toolMaxX, toolMaxY), transformedTool(toolMinX, toolMaxY),
        ]
    }
    let vertices = armEnvelope + toolEnvelope
    let rawMinX = vertices.map(\.0).min() ?? armX
    let rawMinY = vertices.map(\.1).min() ?? armY
    let rawMaxX = vertices.map(\.0).max() ?? armX
    let rawMaxY = vertices.map(\.1).max() ?? armY
    guard rawMaxX > 0, rawMaxY > 0, rawMinX < viewWidth, rawMinY < viewHeight else { return nil }
    let minX = max(0, rawMinX)
    let minY = max(0, rawMinY)
    let maxX = min(viewWidth, rawMaxX)
    let maxY = min(viewHeight, rawMaxY)
    func overlapsCrosshair(_ envelope: [(Double, Double)]) -> Bool {
        guard let envelopeMinX = envelope.map(\.0).min(),
              let envelopeMinY = envelope.map(\.1).min(),
              let envelopeMaxX = envelope.map(\.0).max(),
              let envelopeMaxY = envelope.map(\.1).max() else { return false }
        return envelopeMaxX > viewWidth / 2 - 24 && envelopeMinX < viewWidth / 2 + 24 &&
            envelopeMaxY > viewHeight / 2 - 24 && envelopeMinY < viewHeight / 2 + 24
    }
    let crossesCrosshair = overlapsCrosshair(armEnvelope) || overlapsCrosshair(toolEnvelope)
    // The resting hand must never cover the aim point. A deliberate attack/use arc may
    // briefly pass through it; suppressing the whole arm mid-swing creates a visible pop.
    let isResting = abs(pose.x) < 0.0001 && abs(pose.y) < 0.0001 &&
        abs(pose.armRotation) < 0.0001 && abs(pose.wristRotation) < 0.0001 &&
        abs(toolRotation) < 0.0001 && use < 0.0001
    guard !(isResting && crossesCrosshair),
          anchoredHotbarRight != nil || rightObstruction.map({
              maxX <= $0.x || minX >= $0.x + $0.size ||
              maxY <= $0.y || minY >= $0.y + $0.size
          }) ?? true else { return nil }
    return HeldOverlayPlan(armLayer: presentation.armLayer,
                           drawsGrip: presentation.drawsGrip,
                           armX: armX, armY: armY,
                           armAssetX: armAssetX, armAssetY: armAssetY,
                           armAssetSize: armAssetSize,
                           armBaseX: armBaseX, armBaseY: armBaseY,
                           assemblyPivotX: assemblyPivotX,
                           assemblyPivotY: assemblyPivotY,
                           iconX: iconX, iconY: iconY, iconSize: iconSize,
                           toolPivotX: toolPivotX, toolPivotY: toolPivotY,
                           scale: scale,
                           attack: remaining, use: use, rotation: rotation,
                           wristRotation: wristRotation,
                           toolRotation: toolRotation,
                           minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                           obscuresCrosshair: crossesCrosshair)
}

struct SubtitleInfo {
    var text: String
    var time: Int
}

final class HUD {
    var actionBarText = ""
    var actionBarTime = 0
    var toasts: [(def: AdvancementDef, time: Int)] = []
    var subtitles: [SubtitleInfo] = []
    var bossBars: [BossBarInfo] = []
    var debugVisible = false
    var debugInfo: [String: String] = [:]
    var hideGui = false
    // HUD timers are in 20Hz ticks but draw() runs per FRAME — convert real
    // time to whole tick steps or toasts/action bars expire 2-10× too fast
    // at high fps
    private var lastTimerTime = CACurrentMediaTime()
    private var timerAccum = 0.0
    private var tickSteps = 0
    private var rpgInsightCache = RPGHUDInsightCache()
    private var heldEquipmentAnimation = HeldEquipmentAnimationState()
    private var heldPrimaryActionAnimation = HeldPrimaryActionAnimationState()
    private var heldAnimationPlayer: ObjectIdentifier?

    func showActionBar(_ text: String) {
        actionBarText = text
        actionBarTime = 60
    }
    func pushToast(_ def: AdvancementDef) {
        toasts.append((def, 0))
    }
    func pushSubtitle(_ text: String) {
        if let last = subtitles.last, last.text == text {
            subtitles[subtitles.count - 1].time = 0
            return
        }
        subtitles.append(SubtitleInfo(text: text, time: 0))
        if subtitles.count > 5 { subtitles.removeFirst() }
    }

    func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        if hideGui { return }
        let nowT = CACurrentMediaTime()
        timerAccum += min(0.25, nowT - lastTimerTime)
        lastTimerTime = nowT
        tickSteps = Int(timerAccum * 20)
        timerAccum -= Double(tickSteps) / 20
        let cv = ui.cv
        guard let player = game.player else { return }
        let W = ui.width, H = ui.height
        let cx = (W / 2).rounded(.down)
        let screenOpen = ui.hasScreen()
        let rpgDrawPlan = rpgHUDDrawPlan(player, screenOpen: screenOpen)
        let rpgInsightLines = rpgInsightCache.resolve(
            key: rpgHUDInsightCacheKey(player, screenOpen: screenOpen)
        ) { rpgHUDInsightLines(player) }
        let rpgHudLift = rpgDrawPlan.liftSurvivalHUD ? 24.0 : 0.0

        // vanilla pack HUD when the GUI sheets are loaded; procedural fallback
        let packHud = ui.hasSheet("icons") && ui.hasSheet("widgets")

        // crosshair (plain white; canvas used difference-blend)
        if !ui.hasScreen() {
            if packHud {
                ui.blitSheet("icons", 0, 0, 15, 15, ((W - 15) / 2).rounded(), ((H - 15) / 2).rounded())
            } else {
                cv.setFill("rgba(255,255,255,0.85)")
                cv.fillRect(cx - 5, H / 2 - 0.5, 10, 1)
                cv.fillRect(cx - 0.5, H / 2 - 5, 1, 10)
            }
            // attack indicator
            let str = player.attackStrength()
            if str < 1 {
                cv.setFill("rgba(255,255,255,0.4)")
                cv.fillRect(cx - 8, H / 2 + 8, 16, 2)
                cv.setFill("#ffffff")
                cv.fillRect(cx - 8, H / 2 + 8, (16 * str).rounded(), 2)
            }
        }
        if rpgDrawPlan.showInsights {
            let layout = rpgHUDInsightLayout(viewWidth: W, viewHeight: H)
            for (index, line) in rpgInsightLines.enumerated() {
                cv.drawText(fitHUD(line, maxWidth: layout.maximumWidth),
                            layout.x, layout.y + Double(index * 10),
                            1, "#b9ddff", shadow: true)
            }
        }

        let hbX = cx - 91
        let hbY = packHud ? H - 22 : H - 23
        let showMinimap = shouldDrawMinimap(
            showPreference: game.settings.showMinimap,
            isExpandedMapScreen: ui.current() is MapScreen)
        let minimapRect = showMinimap
            ? mapMinimapRect(screenWidth: W, screenHeight: H,
                             hotbarCenterX: cx, hotbarHalfWidth: 91,
                             hotbarTopY: hbY,
                             sizeMode: game.mapMinimapSizeMode)
            : nil

        // A connected first-person forearm holds a large item sprite by its handle.
        // It is drawn before the hotbar so conventional controls remain readable.
        let held = player.inventory[player.selectedSlot]
        let heldDefinition = held.map { itemDef($0.id) }
        let heldName = heldDefinition?.name
        let offHandName = player.offHand.map { itemDef($0.id).name }
        let mainHandIsBow = heldName == "bow"
        let mainHandIsShield = heldName == "shield"
        let hasDetailedHeldAsset = heldName.flatMap(heldItemVisualAsset(for:)) != nil
        let heldPresentation = heldItemPresentation(
            for: heldDefinition, hasDetailedVisual: hasDetailedHeldAsset)
        let playerIdentity = ObjectIdentifier(player)
        if heldAnimationPlayer != playerIdentity {
            heldAnimationPlayer = playerIdentity
            heldEquipmentAnimation.reset(to: held?.id)
            heldPrimaryActionAnimation = HeldPrimaryActionAnimationState()
        }
        let equipFlipProgress = heldEquipmentAnimation.observe(
            itemID: heldPresentation.performsEquipFlip ? held?.id : nil,
            at: nowT,
            eligible: game.perspective == 0 && !screenOpen)
        let primaryActionProgress = heldPrimaryActionAnimation.observe(
            isHeld: game.primaryActionHeld,
            at: nowT,
            eligible: game.perspective == 0 && !screenOpen)

        // Shields are visually equipped in the left hand whether selected or in
        // the offhand slot. A bow owns that same hand while it is selected.
        if !mainHandIsBow, (mainHandIsShield || offHandName == "shield"),
           let shield = leftHandShieldOverlayPlan(
               viewWidth: W, viewHeight: H,
               guiVisible: !hideGui, firstPerson: game.perspective == 0,
               screenOpen: screenOpen, hotbarLeftX: hbX,
               raised: player.shieldRaised) {
            cv.drawFirstPersonArm(.back,
                                  shield.armAssetX, shield.armAssetY,
                                  shield.armAssetSize, shield.armAssetSize,
                                  mirrored: true)
            _ = cv.drawHeldItemVisual(
                shield.itemName, shield.itemX, shield.itemY,
                shield.itemSize, shield.itemSize)
        }

        // A torch carried in the off-hand renders upright in the left fist (and lights the
        // world via the dynamic held-light in the shader). Yields the left hand to a bow or
        // a shield if one is active there.
        if !mainHandIsBow, !mainHandIsShield, offHandName == "torch",
           let torch = leftHandTorchOverlayPlan(
               viewWidth: W, viewHeight: H,
               guiVisible: !hideGui, firstPerson: game.perspective == 0,
               screenOpen: screenOpen, hotbarLeftX: hbX) {
            cv.drawFirstPersonArm(.back,
                                  torch.armAssetX, torch.armAssetY,
                                  torch.armAssetSize, torch.armAssetSize,
                                  mirrored: true)
            _ = cv.drawHeldItemVisual(
                torch.itemName, torch.itemX, torch.itemY,
                torch.itemSize, torch.itemSize)
            cv.drawFirstPersonArm(.grip,
                                  torch.armAssetX, torch.armAssetY,
                                  torch.armAssetSize, torch.armAssetSize,
                                  mirrored: true)
        }

        if mainHandIsBow,
           let bow = bowOverlayPlan(
               viewWidth: W, viewHeight: H,
               guiVisible: !hideGui, firstPerson: game.perspective == 0,
               screenOpen: screenOpen,
               usingItem: player.usingItem && player.useItemHand == "main",
               useTicks: player.useItemTicks,
               hotbarLeftX: hbX) {
            let left = bow.bow
            cv.drawFirstPersonArm(.back,
                                  left.armAssetX, left.armAssetY,
                                  left.armAssetSize, left.armAssetSize,
                                  mirrored: true)
            cv.save()
            cv.translate(left.gripX, left.gripY)
            cv.rotate(left.itemRotation)
            cv.translate(-left.gripX, -left.gripY)
            _ = cv.drawHeldItemVisual(
                bow.frameName, left.itemX, left.itemY,
                left.itemSize, left.itemSize)
            cv.restore()
            cv.drawFirstPersonArm(.grip,
                                  left.armAssetX, left.armAssetY,
                                  left.armAssetSize, left.armAssetSize,
                                  mirrored: true)
            if let rightX = bow.rightArmAssetX,
               let rightY = bow.rightArmAssetY {
                cv.drawFirstPersonArm(.back, rightX, rightY,
                                      left.armAssetSize, left.armAssetSize)
                cv.drawFirstPersonArm(.grip, rightX, rightY,
                                      left.armAssetSize, left.armAssetSize)
            }
        }

        if !mainHandIsBow, !mainHandIsShield,
           let hand = heldOverlayPlan(viewWidth: W, viewHeight: H,
                                      guiVisible: !hideGui,
                                      firstPerson: game.perspective == 0,
                                      screenOpen: screenOpen,
                                      attack: player.attackAnim,
                                      usingItem: player.usingItem,
                                      useTicks: player.useItemTicks,
                                      presentation: heldPresentation,
                                      equipFlipProgress: equipFlipProgress,
                                      primaryActionProgress: primaryActionProgress,
                                      hotbarRightX: hbX + 182,
                                      rightObstruction: minimapRect) {
            // One transform moves every layer around the physical grip. The arm-back
            // renders first, the item enters the palm, and handle-shaped items receive
            // the foreground finger layer. Empty slots produce no overlay at all.
            cv.save()
            cv.translate(hand.assemblyPivotX, hand.assemblyPivotY)
            cv.rotate(hand.rotation)
            cv.translate(-hand.assemblyPivotX, -hand.assemblyPivotY)
            cv.drawFirstPersonArm(hand.armLayer,
                                  hand.armAssetX, hand.armAssetY,
                                  hand.armAssetSize, hand.armAssetSize)
            if let held {
                cv.save()
                cv.translate(hand.armX, hand.armY)
                cv.rotate(hand.wristRotation)
                cv.translate(-hand.armX, -hand.armY)
                cv.translate(hand.toolPivotX, hand.toolPivotY)
                cv.rotate(hand.toolRotation)
                cv.translate(-hand.toolPivotX, -hand.toolPivotY)
                let drewDetailedAsset = heldName.map {
                    cv.drawHeldItemVisual($0, hand.iconX, hand.iconY,
                                          hand.iconSize, hand.iconSize)
                } ?? false
                if !drewDetailedAsset {
                    cv.drawItemIcon(held.id, held.data, hand.iconX, hand.iconY,
                                    hand.iconSize, hand.iconSize)
                }
                cv.restore()
            }
            if hand.drawsGrip {
                cv.drawFirstPersonArm(.grip,
                                      hand.armAssetX, hand.armAssetY,
                                      hand.armAssetSize, hand.armAssetSize)
            }
            cv.restore()
        }

        // hotbar
        if packHud {
            ui.blitSheet("widgets", 0, 0, 182, 22, hbX, hbY)
            ui.blitSheet("widgets", 0, 22, 24, 23, hbX - 1 + Double(player.selectedSlot) * 20, hbY - 1)
            if let off = player.offHand {
                ui.blitSheet("widgets", 24, 22, 29, 24, hbX - 29 - 3, hbY - 1)
                ui.drawItemStack(off, hbX - 29, hbY + 2)
            }
            for i in 0..<9 {
                if let s = player.inventory[i] {
                    ui.drawItemStack(s, hbX + 2 + Double(i) * 20, hbY + 2)
                }
            }
        } else {
            cv.setFill("rgba(0,0,0,0.55)")
            cv.fillRect(hbX, hbY, 182, 22)
            cv.setStroke("rgba(255,255,255,0.35)")
            cv.strokeRect(hbX, hbY, 182, 22)
            for i in 0..<9 {
                let sx = hbX + 1 + Double(i) * 20
                if i == player.selectedSlot {
                    cv.setStroke("#ffffff")
                    cv.strokeRect(sx - 1, hbY - 1, 23, 24, 2)
                }
                if let s = player.inventory[i] {
                    ui.drawItemStack(s, sx + 1, hbY + 2)
                }
            }
        }
        // held item name
        if let held, actionBarTime <= 0, game.heldNameTime > 0 {
            let name = held.label ?? itemDef(held.id).displayName
            cv.globalAlpha = Float(min(1, Double(game.heldNameTime) / 20))
            cv.drawTextCentered(name, cx, hbY - 38 - rpgHudLift, 1)
            cv.globalAlpha = 1
        }
        if actionBarTime > 0 {
            actionBarTime = max(0, actionBarTime - tickSteps)
            cv.globalAlpha = Float(min(1, Double(actionBarTime) / 20))
            cv.drawTextCentered(actionBarText, cx, hbY - 38 - rpgHudLift, 1)
            cv.globalAlpha = 1
        }

        // Deliberately paint the minimap after the arm, held item, and hotbar.
        // At compact sizes it is the topmost HUD surface and occludes any overlap.
        if showMinimap, let mapRect = minimapRect {
            let bounds = game.loadedMapBounds()
            let view = mapViewportCenteredOnPlayer(playerX: player.x, playerZ: player.z,
                                                   span: game.mapSpanBlocks,
                                                   bounds: bounds)
            drawMapOverlay(ui, game, rect: mapRect, viewport: view, expanded: false, bounds: bounds)
        }

        if player.gameMode != GameMode.creative {
            // 9×9 icon blit from icons.png (vanilla offsets), pack path only
            func icon9(_ sx: Double, _ sy: Double, _ dx: Double, _ dy: Double) {
                ui.blitSheet("icons", sx, sy, 9, 9, dx, dy)
            }
            // hearts
            let healthY = (packHud ? H - 39 : hbY - 10) - rpgHudLift
            let hearts = Int((player.maxHealth / 2).rounded(.up))
            let hp = player.health
            let shake = player.hurtTime > 0 ? (Foundation.sin(CACurrentMediaTime() * 50) * 1).rounded() : 0
            let kind = player.hasEffect("wither") ? "wither"
                : player.hasEffect("poison") ? "poison"
                : player.freezeTicks > 100 ? "frozen" : "normal"
            // icons.png heart column x by kind (full, half)
            let heartX: [String: (Double, Double)] = [
                "normal": (52, 61), "poison": (88, 97), "wither": (124, 133),
                "absorb": (160, 169), "frozen": (178, 187),
            ]
            for i in 0..<hearts {
                // Wrap into rows of 10 stacking upward (like the absorption row below) so a player
                // with more than 20 max health never runs the hearts rightward into the hunger row.
                let hx = hbX + Double(i % 10) * 8
                let hy = healthY - Double(i / 10) * 10 + (player.hurtTime > 0 && i % 2 == 0 ? shake : 0)
                let v = hp - Double(i * 2)
                if packHud {
                    icon9(16, 0, hx, hy)
                    let (full, half) = heartX[kind]!
                    if v >= 2 { icon9(full, 0, hx, hy) }
                    else if v >= 1 { icon9(half, 0, hx, hy) }
                } else {
                    drawHeart(cv, hx, hy, "bg", false)
                    if v >= 2 { drawHeart(cv, hx, hy, kind, false) }
                    else if v >= 1 { drawHeart(cv, hx, hy, kind, true) }
                }
            }
            // absorption hearts
            if player.absorption > 0 {
                for i in 0..<Int((player.absorption / 2).rounded(.up)) {
                    if packHud { icon9(160, 0, hbX + Double(i % 10) * 8, healthY - 10) }
                    else { drawHeart(cv, hbX + Double(i % 10) * 8, healthY - 10, "absorb", false) }
                }
            }
            // hunger (right-aligned)
            for i in 0..<10 {
                let hx = hbX + 182 - 9 - Double(i) * 8
                let v = player.hunger - i * 2
                let rotten = player.hasEffect("hunger")
                if packHud {
                    icon9(16, 27, hx, healthY)
                    if v >= 2 { icon9(rotten ? 88 : 52, 27, hx, healthY) }
                    else if v >= 1 { icon9(rotten ? 97 : 61, 27, hx, healthY) }
                } else {
                    drawFood(cv, hx, healthY, "bg")
                    if v >= 2 { drawFood(cv, hx, healthY, rotten ? "rotten" : "normal") }
                    else if v >= 1 { drawFood(cv, hx, healthY, "half") }
                }
            }
            // armor
            let armorVal = player.armorValue()
            if armorVal > 0 {
                for i in 0..<10 {
                    let ax = hbX + Double(i) * 8
                    let v = armorVal - Double(i * 2)
                    if packHud {
                        if v >= 2 { icon9(34, 9, ax, healthY - 10) }
                        else if v >= 1 { icon9(25, 9, ax, healthY - 10) }
                        else { icon9(16, 9, ax, healthY - 10) }
                    } else {
                        if v >= 2 { drawArmorIcon(cv, ax, healthY - 10, "full") }
                        else if v >= 1 { drawArmorIcon(cv, ax, healthY - 10, "half") }
                        else { drawArmorIcon(cv, ax, healthY - 10, "empty") }
                    }
                }
            }
            // air bubbles (right-aligned, above hunger)
            if player.airSupply < 300 {
                let bubbles = Int((Double(player.airSupply) / 30).rounded(.up))
                for i in 0..<10 where i < bubbles {
                    if packHud { icon9(16, 18, hbX + 182 - 9 - Double(i) * 8, healthY - 10) }
                    else { drawBubble(cv, hbX + 182 - 9 - Double(i) * 8, healthY - 10) }
                }
            }
            // XP bar
            if packHud {
                let xpY = H - 29 - rpgHudLift
                ui.blitSheet("icons", 0, 64, 182, 5, hbX, xpY)
                // Keep the original track/frame and numeric level; the earned
                // prefix adds a fixed rainbow as a supplemental cue.
                for segment in xpRainbowSegments(progress: player.xpProgress, width: 182) {
                    cv.setFill(segment.color)
                    cv.fillRect(hbX + segment.x, xpY + 1, segment.width, 3)
                }
                if player.xpLevel > 0 {
                    cv.drawTextCentered(String(player.xpLevel), cx, xpY - 6, 1, "#80ff20")
                }
            } else {
                let xpY = hbY - 4 - rpgHudLift
                cv.setFill("#1c1c1c")
                cv.fillRect(hbX, xpY, 182, 3)
                for segment in xpRainbowSegments(progress: player.xpProgress, width: 182) {
                    cv.setFill(segment.color)
                    cv.fillRect(hbX + segment.x, xpY, segment.width, 3)
                }
                if player.xpLevel > 0 {
                    cv.drawTextCentered(String(player.xpLevel), cx, xpY - 10, 1, "#80ff20")
                }
            }
            // vehicle health (riding)
            if let v = player.vehicle as? LivingEntity {
                cv.drawTextCentered("♥ \(Int(v.health.rounded(.up))) / \(Int(v.maxHealth))", cx, healthY - 20, 1, "#ff5555")
            }
        }
        if rpgDrawPlan.showQuickSlots {
            let rpgState = repairRPGCharacterState(player.rpg)
            let derived = rpgDerivedStats(rpgState)
            let f = max(0, min(1, rpgState.fatigue / max(1, derived.maxFatigue)))
            let fx = hbX + 186
            let fy = hbY
            cv.setFill("#1c1c1c")
            cv.fillRect(fx, fy, 5, 22)
            cv.setFill("#55aaff")
            cv.fillRect(fx + 1, fy + 21 - (20 * f).rounded(), 3, (20 * f).rounded())
            drawRPGQuickSlots(
                ui, rpg: rpgState, preferences: game.rpgQuickSlotPreferences ?? .empty,
                hotbarX: hbX, hotbarY: hbY)
        }

        // boss bars
        var bbY = 6.0
        for bar in bossBars {
            cv.drawTextCentered(bar.name, cx, bbY, 1)
            cv.setFill("#1c1c1c")
            cv.fillRect(cx - 91, bbY + 10, 182, 5)
            cv.setFill(bar.color)
            cv.fillRect(cx - 91, bbY + 10, (182 * max(0, min(1, bar.progress))).rounded(), 5)
            bbY += 22
        }

        // status effect icons (top right)
        var efX = W - 26
        for e in player.effects {
            let def = effectDef(e.id)
            cv.setFill(def.beneficial ? "rgba(30,30,80,0.7)" : "rgba(80,30,30,0.7)")
            cv.fillRect(efX, 4, 22, 22)
            cv.setFill("#" + String(format: "%06x", def.color))
            cv.fillRect(efX + 4, 8, 14, 10)
            let secs = e.duration / 20
            let t = e.duration < 0 ? "∞" : "\(secs / 60):\(String(format: "%02d", secs % 60))"
            cv.drawTextCentered(t, efX + 11, 19, 1, "#ffffff", shadow: false)
            if e.amplifier > 0 { cv.drawText(String(e.amplifier + 1), efX + 2, 5, 1) }
            efX -= 24
        }

        // subtitles (accessibility)
        if game.settings.subtitles && !subtitles.isEmpty {
            var sy = H - 60
            var i = subtitles.count - 1
            while i >= 0 {
                subtitles[i].time += tickSteps
                if subtitles[i].time > 60 {
                    subtitles.remove(at: i)
                    i -= 1
                    continue
                }
                let sub = subtitles[i]
                let w = Double(textWidth(sub.text)) + 6
                cv.setFill("rgba(0,0,0,0.7)")
                cv.fillRect(W - w - 6, sy, w, 11)
                cv.drawText(sub.text, W - w - 3, sy + 2, 1)
                sy -= 12
                i -= 1
            }
        }

        // toasts
        var ti = toasts.count - 1
        while ti >= 0 {
            toasts[ti].time += tickSteps
            if toasts[ti].time > 120 {
                toasts.remove(at: ti)
                ti -= 1
                continue
            }
            let t = toasts[ti]
            let slide = t.time < 10 ? Double(10 - t.time) * 16 : t.time > 110 ? Double(t.time - 110) * 16 : 0
            let tx = W - 160 + slide
            let ty = 8 + Double(ti) * 36
            ui.drawPanel(tx, ty, 152, 32)
            cv.drawText(t.def.frame == "challenge" ? "§dChallenge Complete!" : "§eAdvancement Made!", tx + 28, ty + 6, 1)
            cv.drawText(t.def.title, tx + 28, ty + 17, 1)
            if let iconId = iidOpt(t.def.icon) {
                cv.drawItemIcon(iconId, nil, tx + 7, ty + 8, 16, 16)
            }
            ti -= 1
        }

        // debug overlay
        if debugVisible {
            drawDebug(ui, game)
        }
    }

    private func drawHeart(_ cv: UICanvas, _ x: Double, _ y: Double, _ kind: String, _ half: Bool) {
        let colors: [String: (String, String)] = [
            "bg": ("#3f1414", "#1f0a0a"),
            "normal": ("#ff2020", "#a80000"),
            "poison": ("#94a061", "#586038"),
            "wither": ("#3a3a3a", "#1c1c1c"),
            "frozen": ("#60c8e8", "#3088a8"),
            "absorb": ("#e8c83c", "#a8862c"),
        ]
        let (main, dark) = colors[kind] ?? colors["normal"]!
        let rows = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                if half && rx >= 4 { continue }
                cv.setFill(ry < 3 ? main : dark)
                cv.fillRect(x + Double(rx), y + Double(ry), 1, 1)
            }
        }
        // shine pixel sits at rx=1, inside the half-heart clip — always drawn
        if kind != "bg" {
            cv.setFill("#ffffff")
            cv.fillRect(x + 1, y + 1, 1, 1)
        }
    }
    private func drawFood(_ cv: UICanvas, _ x: Double, _ y: Double, _ kind: String) {
        let main = kind == "bg" ? "#2a1c10" : kind == "rotten" ? "#7a8a4a" : "#c87830"
        let dark = kind == "bg" ? "#180f08" : kind == "rotten" ? "#586038" : "#8a4a1c"
        let rows = ["..###..", ".#####.", ".#####.", ".#####.", "..###..", "...#..."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                if kind == "half" && rx >= 4 { continue }
                cv.setFill(ry > 2 ? dark : main)
                cv.fillRect(x + Double(rx), y + Double(ry), 1, 1)
            }
        }
    }
    private func drawArmorIcon(_ cv: UICanvas, _ x: Double, _ y: Double, _ kind: String) {
        let main = kind == "empty" ? "#3a3a3a" : "#c8c8c8"
        let rows = ["##.##", "#####", "#####", ".###."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                cv.setFill(kind == "half" && rx >= 3 ? "#3a3a3a" : main)
                cv.fillRect(x + Double(rx) + 1, y + Double(ry) + 1, 1, 1)
            }
        }
    }
    private func drawBubble(_ cv: UICanvas, _ x: Double, _ y: Double) {
        let rows = [".###.", "#...#", "#...#", ".###."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                cv.setFill("#6ab8e8")
                cv.fillRect(x + Double(rx) + 1, y + Double(ry) + 1, 1, 1)
            }
        }
    }

    private func drawRPGQuickSlots(_ ui: UIManager, rpg: RPGCharacterState,
                                   preferences: RPGQuickSlotPreferences,
                                   hotbarX: Double, hotbarY: Double) {
        let cv = ui.cv
        let slots = rpgActionQuickSlotActions(rpg, preferences: preferences)
        let y = hotbarY - 25
        cv.setFill("rgba(12,12,12,0.68)")
        cv.fillRect(hotbarX, y, 182, 22)
        cv.setStroke("rgba(255,255,255,0.25)")
        cv.strokeRect(hotbarX, y, 182, 22)
        let selected = rpg.selectedPreparedActionID
        var selectedSlot: (index: Int, action: RPGPreparedAction)?
        for i in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
            let sx = hotbarX + 1 + Double(i) * 20
            let action = i < slots.count ? slots[i] : nil
            let isSelected = action?.token == selected
            if let action, isSelected { selectedSlot = (i, action) }
            if let action {
                let fill = isSelected ? "rgba(80,140,230,0.45)" : action.available ? "rgba(70,130,90,0.24)" : "rgba(150,92,48,0.28)"
                cv.setFill(fill)
                cv.fillRect(sx, y + 1, 20, 20)
                cv.drawRPGIcon(action.iconAssetID, sx + 2, y + 2, 16, 16)
                cv.setFill("rgba(0,0,0,0.55)")
                cv.fillRect(sx + 1, y + 12, 9, 8)
                cv.drawText(String(i + 1), sx + 2, y + 13, 1, "#ffffff", shadow: false)
                if action.cooldownRemainingTicks > 0 {
                    cv.setFill("rgba(0,0,0,0.64)")
                    cv.fillRect(sx + 10, y + 12, 10, 8)
                    cv.drawText(fitHUD(action.statusText, maxWidth: 10), sx + 11, y + 13, 1, "#ffc878", shadow: false)
                } else if !action.available {
                    cv.setStroke("#ffb070")
                    cv.strokeRect(sx + 1, y + 1, 18, 18)
                }
            } else {
                cv.setFill("rgba(0,0,0,0.26)")
                cv.fillRect(sx, y + 1, 20, 20)
                cv.drawTextCentered(String(i + 1), sx + 10, y + 8, 1, "#909090", shadow: false)
            }
            if isSelected {
                cv.setStroke("#ffffff")
                cv.strokeRect(sx - 1, y, 22, 22, 2)
            }
        }
        if let selectedSlot {
            let x = hotbarX + 196
            let w = min(128.0, max(0, ui.width - x - 6))
            if w >= 92 {
                cv.setFill("rgba(12,12,12,0.68)")
                cv.fillRect(x, y, w, 22)
                cv.setStroke("rgba(255,255,255,0.25)")
                cv.strokeRect(x, y, w, 22)
                let text = "Slot \(selectedSlot.index + 1) \(selectedSlot.action.displayName)"
                let status = "Fat \(Int(selectedSlot.action.fatigueCost.rounded(.up))) \(selectedSlot.action.statusText)"
                cv.drawText(fitHUD(text, maxWidth: Int(w - 6)), x + 3, y + 3, 1, "#ffffff", shadow: false)
                cv.drawText(fitHUD(status, maxWidth: Int(w - 6)), x + 3, y + 13, 1,
                            selectedSlot.action.available ? "#b8ffb8" : "#ffc878", shadow: false)
            }
        }
    }

    private func fitHUD(_ text: String, maxWidth: Int) -> String {
        guard maxWidth > 0 else { return "" }
        var out = text
        while textWidth(out) > maxWidth && out.count > 3 {
            out.removeLast()
        }
        if out.count < text.count {
            while textWidth(out + "...") > maxWidth && out.count > 1 { out.removeLast() }
            return out + "..."
        }
        return out
    }

    private func drawDebug(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        guard let p = game.player else { return }
        let world = game.world
        let bx = Int(p.x.rounded(.down)), by = Int(p.y.rounded(.down)), bz = Int(p.z.rounded(.down))
        let biome = BIOMES[world.biomeAt(bx, by, bz)]
        var lines = [
            "Elysium \(ELYSIUM_VERSION) (\(debugInfo["fps"] ?? "?") fps, \(debugInfo["chunkUpdates"] ?? "0") chunk updates)",
            "XYZ: \(String(format: "%.3f", p.x)) / \(String(format: "%.4f", p.y)) / \(String(format: "%.3f", p.z))",
            "Block: \(bx) \(by) \(bz)  Chunk: \(bx >> 4) \(bz >> 4)",
            "Facing: \(facingName(p.yaw)) (\(String(format: "%.1f", (p.yaw * 180 / .pi).truncatingRemainder(dividingBy: 360))) / \(String(format: "%.1f", p.pitch * 180 / .pi)))",
            "Biome: \(biome?.name ?? "?")",
            "Light: \(Int(world.lightAt(bx, by, bz))) (\(world.getSkyLight(bx, by, bz)) sky, \(world.getBlockLight(bx, by, bz)) block)",
            "Time: \(world.dayTime) (day \(world.time / 24000))  Weather: \(world.raining ? (world.thundering ? "thunder" : "rain") : "clear")",
            "E: \(world.entities.count)  Sections: \(debugInfo["sections"] ?? "?")  Draw: \(debugInfo["drawCalls"] ?? "?")",
            "Mem: \(debugInfo["mem"] ?? "?")  Seed: \(world.seed)",
        ]
        // scripting-ui-and-replication (change 3), design.md §12: "F3 summary" — script counts,
        // event/tick stats, budget trips, one line, only while a script runtime actually exists
        // this session (§15's zero-cost invariant: no line at all for a world with scripting
        // off/untrusted/absent, not an empty/zero line).
        if let runtime = game.scripting.scriptRuntime {
            let summary = runtime.summary
            let faultsThisWindow = game.eventBus.recentEvents().filter { $0.kind == .scriptFaulted }.count
            lines.append(
                "Scripts: \(summary.liveScripts) live, \(summary.suspendedCoroutines) waiting, "
                    + "\(summary.durableTimers) timers  Events: \(game.eventBus.pendingCount) pending, "
                    + "\(faultsThisWindow) faulted"
            )
        }
        if let t = game.targetedBlock {
            let def = blockDefs[t.cell >> 4]
            lines.append("Looking at: \(t.x) \(t.y) \(t.z) = \(def.name)#\(t.cell & 15)")
        }
        cv.setFill("rgba(16,16,16,0.4)")
        for (i, line) in lines.enumerated() {
            cv.fillRect(2, 2 + Double(i) * 10, Double(textWidth(line)) + 2, 10)
        }
        for (i, line) in lines.enumerated() {
            cv.drawText(line, 3, 3 + Double(i) * 10, 1, "#e8e8e8", shadow: false)
        }
    }
}

private func facingName(_ yaw: Double) -> String {
    let deg = ((yaw * 180 / .pi).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    if deg >= 315 || deg < 45 { return "south (+Z)" }
    if deg < 135 { return "west (-X)" }
    if deg < 225 { return "north (-Z)" }
    return "east (+X)"
}
