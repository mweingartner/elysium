// First-person presentation timelines, independent of the HUD and mesh geometry.
// The renderer samples these states at frame rate while gameplay remains authoritative.
import Foundation
import ElysiumCore

let HELD_EQUIP_FLIP_DURATION = 0.62
/// A real action takes ownership of the grip promptly without snapping a partial twirl.
let HELD_EQUIP_INTERRUPT_DURATION = 0.08
/// One full mining/punching stroke while the primary button is held; also the one-shot attack.
let HELD_PRIMARY_ACTION_CYCLE_DURATION = 0.32
/// A one-shot use gesture (placing, opening, interacting) is a shorter stroke than an attack.
let HELD_USE_SWING_DURATION = 0.2
/// Switching items lowers the outgoing item out of view, then raises the incoming one.
let HELD_EQUIP_LOWER_DURATION = 0.14
let HELD_EQUIP_RAISE_DURATION = 0.22
/// Releasing a guard or a bowstring relaxes the hand home instead of snapping it.
let HELD_SHIELD_LOWER_DURATION = 0.12
let HELD_BOW_RELAX_DURATION = 0.16

/// A visual value that follows its target instantly on the way up (the engine's authoritative
/// raise) and settles back over `fallDuration` seconds on the way down.
struct HeldRelaxState: Equatable {
    private(set) var value = 0.0
    private(set) var observedAt: Double?

    mutating func observe(target: Double, at now: Double, fallDuration: Double) -> Double {
        let goal = target.isFinite ? max(0, min(1, target)) : 0
        guard now.isFinite, fallDuration.isFinite, fallDuration > 0 else {
            value = goal
            observedAt = nil
            return goal
        }
        let dt = observedAt.map { max(0, now - $0) } ?? 0
        observedAt = now
        value = goal >= value ? goal : max(goal, value - dt / fallDuration)
        return value
    }
}

/// The first-person swing timeline. The engine's `attackAnim` only *triggers* strokes here — it
/// is a four-tick value that steps at 20Hz and restarts while mining — so the arm is driven on
/// the wall clock: a continuous stroke cycle while the primary button is held (mining,
/// punching), the in-flight stroke completing after release instead of snapping to rest, and a
/// one-shot stroke for each engine-reported swing while idle (a use gesture, a placed block).
struct HeldSwingAnimationState: Equatable {
    private(set) var cycleStartedAt: Double?
    private(set) var cycleEndsAt: Double?
    private(set) var strokeStartedAt: Double?
    private(set) var strokeDuration = HELD_PRIMARY_ACTION_CYCLE_DURATION
    private(set) var lastEngineAttack = 0.0

    /// Normalized stroke progress (0 = wind-up, 1 = rest), or nil while the hand rests.
    mutating func observe(primaryHeld: Bool, engineAttack: Double,
                          at now: Double, eligible: Bool) -> Double? {
        // Track the engine baseline even while ineligible so a screen closing mid-decay does not
        // read as a fresh swing.
        let engine = engineAttack.isFinite ? max(0, min(1, engineAttack)) : 0
        let rose = engine > lastEngineAttack + 1e-6
        lastEngineAttack = engine
        guard eligible, now.isFinite else {
            cycleStartedAt = nil
            cycleEndsAt = nil
            strokeStartedAt = nil
            return nil
        }
        let cycle = HELD_PRIMARY_ACTION_CYCLE_DURATION
        if primaryHeld {
            strokeStartedAt = nil
            cycleEndsAt = nil
            if let start = cycleStartedAt, start <= now {
                return (now - start).truncatingRemainder(dividingBy: cycle) / cycle
            }
            cycleStartedAt = now
            return 0
        }
        if let start = cycleStartedAt {
            let elapsed = max(0, now - start)
            let end = cycleEndsAt ?? (start + (Foundation.floor(elapsed / cycle) + 1) * cycle)
            cycleEndsAt = end
            if now < end {
                return elapsed.truncatingRemainder(dividingBy: cycle) / cycle
            }
            cycleStartedAt = nil
            cycleEndsAt = nil
        }
        if rose {
            strokeStartedAt = now
            strokeDuration = engine >= 0.99 ? cycle : HELD_USE_SWING_DURATION
        }
        guard let start = strokeStartedAt else { return nil }
        let progress = (now - start) / strokeDuration
        guard progress >= 0, progress < 1 else {
            strokeStartedAt = nil
            return nil
        }
        return progress
    }
}

enum HeldSwapPhase: Equatable {
    case rest
    /// The previous item sinks out of the frame before its replacement rises.
    case lowering(previousKey: Int, progress: Double)
    case raising(progress: Double)
}

/// Changing what a hand holds is choreographed like a real hand-off: the outgoing item is
/// lowered out of view, then the incoming one rises into the fist. A change during a swap
/// continues from what is on screen — a lowering item keeps lowering, a half-raised item is
/// lowered from its current height — so rapid hotbar scrolling never stacks transitions.
struct HeldSwapAnimationState: Equatable {
    private(set) var itemKey: Int?
    private(set) var initialized = false
    private(set) var loweringKey: Int?
    private(set) var loweringStartedAt: Double?
    private(set) var raisingStartedAt: Double?

    mutating func observe(itemKey newKey: Int?, at now: Double, eligible: Bool) -> HeldSwapPhase {
        guard now.isFinite, eligible else {
            itemKey = newKey
            initialized = true
            loweringKey = nil
            loweringStartedAt = nil
            raisingStartedAt = nil
            return .rest
        }
        if !initialized {
            initialized = true
            itemKey = newKey
            return .rest
        }
        if newKey != itemKey {
            let previousKey = itemKey
            itemKey = newKey
            if loweringStartedAt == nil {
                if let raiseStart = raisingStartedAt, let previousKey {
                    // Interrupted mid-raise: lower from the height the item actually reached.
                    let raised = max(0, min(1, (now - raiseStart) / HELD_EQUIP_RAISE_DURATION))
                    loweringKey = previousKey
                    loweringStartedAt = now - (1 - raised) * HELD_EQUIP_LOWER_DURATION
                } else if let previousKey {
                    loweringKey = previousKey
                    loweringStartedAt = now
                } else if newKey != nil {
                    raisingStartedAt = now
                }
                if loweringStartedAt != nil { raisingStartedAt = nil }
            }
        }
        if let key = loweringKey, let start = loweringStartedAt {
            let progress = (now - start) / HELD_EQUIP_LOWER_DURATION
            if progress + 1e-9 < 1 {
                return .lowering(previousKey: key, progress: max(0, progress))
            }
            loweringKey = nil
            loweringStartedAt = nil
            raisingStartedAt = itemKey == nil ? nil : start + HELD_EQUIP_LOWER_DURATION
        }
        if let start = raisingStartedAt {
            guard itemKey != nil else {
                raisingStartedAt = nil
                return .rest
            }
            let progress = (now - start) / HELD_EQUIP_RAISE_DURATION
            if progress + 1e-9 < 1 { return .raising(progress: max(0, progress)) }
            raisingStartedAt = nil
        }
        return .rest
    }
}

/// Per-hand bookkeeping lets the viewmodel keep drawing an outgoing item while it lowers
/// out of view, after the inventory already holds its replacement.
struct HeldHandDisplay {
    private(set) var swap = HeldSwapAnimationState()
    private(set) var previousStack: ItemStack?
    private(set) var previousKey: Int?

    /// The stack to draw for this hand, its identity key, and how far (0...1) it is dropped
    /// out of the frame by an in-flight swap.
    mutating func observe(stack: ItemStack?, key: Int?, at now: Double,
                          eligible: Bool) -> (stack: ItemStack?, key: Int?, lift: Double) {
        switch swap.observe(itemKey: key, at: now, eligible: eligible) {
        case let .lowering(previousKey, progress):
            return (previousStack, previousKey, smoothStep(progress))
        case let .raising(progress):
            remember(stack, key)
            return (stack, key, 1 - smoothStep(progress))
        case .rest:
            remember(stack, key)
            return (stack, key, 0)
        }
    }

    private mutating func remember(_ stack: ItemStack?, _ key: Int?) {
        guard key != previousKey else { return }
        previousStack = stack?.copy()
        previousKey = key
    }
}

struct HeldEquipmentAnimationState: Equatable {
    private(set) var itemID: Int?
    private(set) var flipStartedAt: Double?
    private(set) var initialized = false
    private(set) var interruptionStartedAt: Double?
    private(set) var interruptionFrom = 1.0
    private(set) var interruptionTo = 1.0
    private var observedSelectionID: Int?
    private var suppressedSelectionID: Int?

    mutating func reset(to itemID: Int?) {
        self.itemID = itemID
        flipStartedAt = nil
        interruptionStartedAt = nil
        interruptionFrom = 1
        interruptionTo = 1
        observedSelectionID = itemID
        suppressedSelectionID = nil
        initialized = true
    }

    /// Returns 0...1 while a newly visible item performs its one-shot flip; 1 is rest.
    /// Hidden screens do not consume the transition, so an inventory equip is celebrated
    /// when gameplay becomes visible again rather than expiring behind the menu.
    mutating func observe(itemID newItemID: Int?, at now: Double,
                          eligible: Bool, working: Bool = false,
                          selectedItemID: Int? = nil) -> Double {
        guard now.isFinite else { return 1 }
        guard eligible else { return 1 }
        let selection = selectedItemID ?? newItemID
        if !initialized {
            reset(to: newItemID)
            observedSelectionID = selection
            if working { suppressedSelectionID = selection }
            return 1
        }
        // The renderer still displays the outgoing item during a swap. Remember
        // selection intent now so work that ends before the replacement rises
        // cannot accidentally schedule a delayed flourish for that replacement.
        if selection != observedSelectionID {
            observedSelectionID = selection
            suppressedSelectionID = working ? selection : nil
        }
        if newItemID != itemID {
            itemID = newItemID
            interruptionStartedAt = nil
            let suppressed = working || (newItemID != nil && newItemID == suppressedSelectionID)
            flipStartedAt = newItemID == nil || suppressed ? nil : now
            if newItemID == suppressedSelectionID { suppressedSelectionID = nil }
        }
        if working, let start = flipStartedAt {
            let progress = max(0, min(1, (now - start) / HELD_EQUIP_FLIP_DURATION))
            flipStartedAt = nil // cancellation is permanent, including after release
            if progress > 0, progress < 1 {
                interruptionStartedAt = now
                interruptionFrom = progress
                interruptionTo = progress < 0.5 ? 0 : 1
            }
        }
        if let start = interruptionStartedAt {
            let progress = max(0, (now - start) / HELD_EQUIP_INTERRUPT_DURATION)
            if progress + 1e-9 >= 1 {
                interruptionStartedAt = nil
                return 1 // zero and one are the same full-turn rest orientation
            }
            return interruptionFrom + (interruptionTo - interruptionFrom) * smoothStep(progress)
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

private func smoothStep(_ value: Double) -> Double {
    let t = max(0, min(1, value))
    return t * t * (3 - 2 * t)
}
