// What the renderer remembers about each prehistoric creature it draws, so that the creature
// can step, beat its wings and change its bearing smoothly.
//
// Everything here is presentation. It is derived from what a frame can already see of an
// entity (where it is drawn, which way it faces, its replicated action, whether it stands on
// the ground), it is kept by the renderer alone, and it is never saved, sent over the LAN or
// read by the simulation. It draws on no simulation RNG. A LAN guest's mirrored creatures do
// not tick, and this needs nothing from a tick, so they animate the same way.

import Foundation
import simd
import ElysiumCore

/// How strongly each action shapes the pose, eased so that a change of action never pops.
/// An idle animal on the ground has every weight at 0.
struct PrehistoricActionWeights: Equatable {
    var browse: Float = 0
    var alert: Float = 0
    var charge: Float = 0
    var eat: Float = 0
    var recover: Float = 0
    /// 0 for a flyer at rest with folded wings, 1 in the air.
    var flight: Float = 0
    /// 0 gliding, 1 beating.
    var power: Float = 0
    var takeoff: Float = 0
    var landing: Float = 0
}

/// One frame's reading of a creature's movement: the input of `PrehistoricPose`.
struct PrehistoricMotion: Equatable {
    /// Where the legs are in their cycle, 0 ..< 1.
    var gaitPhase: Float = 0
    /// 0 standing, 1 stepping.
    var walk: Float = 0
    /// Blocks per second that set stride and cadence: travel, plus turning on the spot.
    var pace: Float = 0
    /// The share of the pace that is travel; 0 for an animal that only turns.
    var travel: Float = 1
    /// How far a quadruped has changed from a walk to a trot, eased toward what the pace asks
    /// for. Nil until a motion state has set it; the pose then takes the pairing of the pace.
    var trot: Float?
    /// Turning, radians per second, positive toward larger yaw.
    var turn: Float = 0
    /// Blocks per second forward, and upward.
    var speed: Float = 0
    var climb: Float = 0
    /// Where the wings are in their beat, 0 ..< 1.
    var flapPhase: Float = 0
    /// A land animal off the ground: 0 standing, 1 in the air.
    var airborne: Float = 0
    var weights = PrehistoricActionWeights()
    /// Seconds since the animal last struck; large when it has not.
    var strikeAge: Float = 1_000
    /// Tells animals apart, so a herd does not move in step.
    var seed: UInt32 = 0
    /// The moment this reading was taken, on the motion store's own clock, which only runs
    /// forward. The pose is drawn for this moment. Nil for a creature no store follows; it is
    /// then posed for the time the renderer hands in.
    var clock: Double?
}

/// What a frame sees of one creature.
struct PrehistoricObservation {
    var x: Double
    var y: Double
    var z: Double
    var yaw: Double
    var action: PrehistoricAction
    var onGround: Bool
    /// `LivingEntity.attackAnim`: jumps to 1 when the animal strikes. Not replicated.
    var attack: Double
    /// A LAN guest's copy of a host creature: its position arrives a few times a second.
    var mirror: Bool
    /// Display scale of this animal (the model's scale, halved for a baby).
    var scale: Float
    var seed: UInt32
}

struct PrehistoricMotionState {
    private(set) var motion = PrehistoricMotion()
    private(set) var time: Double
    /// Where the creature was drawn last.
    private(set) var x: Double
    private(set) var y: Double
    private(set) var z: Double
    private(set) var yaw: Double
    private var action: PrehistoricAction
    private var attack: Double
    // A mirror glides from where it is drawn to each new snapshot over one snapshot interval.
    private var fromX: Double, fromY: Double, fromZ: Double, fromYaw: Double
    private var toX: Double, toY: Double, toZ: Double, toYaw: Double
    private var glideStart: Double
    private var glideSpan: Double
    private var snapshotTime: Double
    var lastFrame: UInt64 = 0

    /// How much longer a mirror's glide lasts than the gap between its last two snapshots.
    static let glideStretch = 1.15
    /// A longer gap than this between two frames is a pause, not a movement.
    static let longestStep = 0.1
    /// A creature that moved farther than this in one frame was moved, not walking.
    static let teleportDistance = 8.0

    init(_ seen: PrehistoricObservation, time: Double) {
        self.time = time
        x = seen.x; y = seen.y; z = seen.z; yaw = seen.yaw
        fromX = seen.x; fromY = seen.y; fromZ = seen.z; fromYaw = seen.yaw
        toX = seen.x; toY = seen.y; toZ = seen.z; toYaw = seen.yaw
        glideStart = time
        snapshotTime = time
        glideSpan = LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL * Self.glideStretch
        action = seen.action
        attack = seen.attack
        motion.seed = seen.seed
        // A creature seen for the first time is already doing what it does: no easing in.
        motion.weights = Self.targetWeights(seen.action)
        motion.airborne = seen.onGround ? 0 : 1
        // Spread a herd's legs and wings over their cycles.
        motion.gaitPhase = Float(seen.seed & 0xff) / 256
        motion.flapPhase = Float((seen.seed >> 8) & 0xff) / 256
        motion.clock = time
    }

    /// The weights an action aims for.
    static func targetWeights(_ action: PrehistoricAction) -> PrehistoricActionWeights {
        var w = PrehistoricActionWeights()
        switch action {
        case .browse: w.browse = 1
        case .alert: w.alert = 1
        case .charge: w.charge = 1
        case .eat: w.eat = 1
        case .recover: w.recover = 1
        case .takeoff: w.flight = 1; w.power = 1; w.takeoff = 1
        case .flap: w.flight = 1; w.power = 1
        case .glide: w.flight = 1
        case .landing: w.flight = 1; w.power = 1; w.landing = 1
        case .idle, .cruise, .surface, .dive, .turn, .burst, .stranded: break
        }
        return w
    }

    /// Moves the state on to `time` and returns where to draw the creature.
    /// Calling it again for the same instant changes nothing. A clock that runs backward has
    /// been restarted: the creature then starts again from what is seen of it now, so that it
    /// can never be left standing where it last was until the clock catches up.
    mutating func advance(_ seen: PrehistoricObservation, rig: PrehistoricRig,
                          time now: Double) -> (x: Double, y: Double, z: Double, yaw: Double) {
        guard now.isFinite, seen.x.isFinite, seen.y.isFinite, seen.z.isFinite, seen.yaw.isFinite else {
            return (x, y, z, yaw)
        }
        let elapsed = now - time
        if elapsed < 0 {
            let frame = lastFrame
            self = PrehistoricMotionState(seen, time: now)
            lastFrame = frame
            return (x, y, z, yaw)
        }
        guard elapsed > 0 else { return (x, y, z, yaw) }
        let dt = min(elapsed, Self.longestStep)
        let previous = time
        time = now

        // Where to draw it. The host's creatures are already interpolated between ticks;
        // a mirror only jumps when a snapshot arrives, so it glides to each new one.
        var drawX = seen.x, drawY = seen.y, drawZ = seen.z, drawYaw = seen.yaw
        if seen.mirror {
            if seen.x != toX || seen.y != toY || seen.z != toZ || seen.yaw != toYaw {
                // A little longer than the snapshots are apart, so a glide is still under way
                // when the next snapshot arrives and the creature never stands waiting for it.
                glideSpan = min(0.5, max(0.05, now - snapshotTime)) * Self.glideStretch
                snapshotTime = now
                fromX = x; fromY = y; fromZ = z; fromYaw = yaw
                toX = seen.x; toY = seen.y; toZ = seen.z; toYaw = seen.yaw
                // The glide leaves from where the creature was drawn in the frame before.
                glideStart = max(previous, now - Self.longestStep)
            }
            let t = min(1, max(0, (now - glideStart) / glideSpan))
            drawX = fromX + (toX - fromX) * t
            drawY = fromY + (toY - fromY) * t
            drawZ = fromZ + (toZ - fromZ) * t
            drawYaw = fromYaw + Self.shortestTurn(from: fromYaw, to: toYaw) * t
        }
        let dx = drawX - x, dy = drawY - y, dz = drawZ - z
        let moved = (dx * dx + dz * dz).squareRoot()
        let turned = Self.shortestTurn(from: yaw, to: drawYaw)
        // A mirror's numbers come from another machine. Whatever cannot be a step of a walking
        // animal (a leap, or arithmetic that left the finite numbers) is treated as a move. The
        // leap is measured to where the creature now is, not to where its glide would draw it:
        // a mirror that was moved far away appears there, it does not race across the gap.
        let leapX = seen.x - x, leapZ = seen.z - z
        let leap = (leapX * leapX + leapZ * leapZ).squareRoot()
        let jumped = !(moved <= Self.teleportDistance) || !(abs(dy) <= Self.teleportDistance)
            || !(leap <= Self.teleportDistance) || !(abs(seen.y - y) <= Self.teleportDistance)
            || !drawYaw.isFinite || elapsed > Self.longestStep * 5
        if jumped {
            // Moved by a command, a respawn or a long pause: start again from here.
            fromX = seen.x; fromY = seen.y; fromZ = seen.z; fromYaw = seen.yaw
            toX = seen.x; toY = seen.y; toZ = seen.z; toYaw = seen.yaw
            drawX = seen.x; drawY = seen.y; drawZ = seen.z; drawYaw = seen.yaw
        }
        x = drawX; y = drawY; z = drawZ; yaw = drawYaw

        let step = Float(dt)
        func ease(_ value: inout Float, toward target: Float, seconds: Float) {
            value += (target - value) * (1 - exp(-step / seconds))
        }
        ease(&motion.speed, toward: jumped ? 0 : Float(moved / dt), seconds: 0.12)
        ease(&motion.climb, toward: jumped ? 0 : Float(dy / dt), seconds: 0.30)
        ease(&motion.turn, toward: jumped ? 0 : Float(turned / dt), seconds: 0.15)

        // Legs. An animal that turns on the spot has to step too, or its feet would spin.
        if rig.plan != .flyer {
            let turning = abs(motion.turn) * rig.turnRadius * seen.scale
            let pace = motion.speed + turning
            let stepping: Float = pace > 0.05 + 0.06 * rig.legLength * seen.scale ? 1 : 0
            ease(&motion.walk, toward: stepping, seconds: 0.16)
            ease(&motion.travel, toward: pace > 0.001 ? motion.speed / pace : 1, seconds: 0.12)
            ease(&motion.airborne, toward: seen.onGround ? 0 : 1, seconds: 0.12)
            motion.pace = pace
            // The legs turn by the stride of the very gait the pose will draw from this pace,
            // or a standing foot would be dragged. Only the pairing of a quadruped's legs is
            // eased: a leg cannot move to another place in the stride within a frame.
            let gait = rig.gait(pace: pace, scale: seen.scale)
            if var trot = motion.trot {
                ease(&trot, toward: gait.trot, seconds: 0.35)
                motion.trot = trot
            } else {
                motion.trot = gait.trot
            }
            if pace > 0.001 {
                motion.gaitPhase = Self.wrapped(motion.gaitPhase + step * pace / max(0.05, gait.stride))
            }
        }

        // Actions and wings.
        let target = Self.targetWeights(seen.action)
        ease(&motion.weights.browse, toward: target.browse, seconds: 0.35)
        ease(&motion.weights.alert, toward: target.alert, seconds: 0.22)
        ease(&motion.weights.charge, toward: target.charge, seconds: 0.20)
        ease(&motion.weights.eat, toward: target.eat, seconds: 0.30)
        ease(&motion.weights.recover, toward: target.recover, seconds: 0.30)
        ease(&motion.weights.flight, toward: target.flight, seconds: 0.30)
        ease(&motion.weights.power, toward: target.power, seconds: 0.35)
        ease(&motion.weights.takeoff, toward: target.takeoff, seconds: 0.25)
        ease(&motion.weights.landing, toward: target.landing, seconds: 0.30)
        if rig.plan == .flyer, motion.weights.flight > 0.01 {
            // A glider's wings still ride the air; they only stop beating in earnest.
            let effort = 0.45 + 0.55 * motion.weights.power + 0.20 * motion.weights.takeoff
            motion.flapPhase = Self.wrapped(motion.flapPhase + step * rig.beatRate(scale: seen.scale) * effort)
        }

        // A strike: the host sees the swing itself, and both sides see a charge end in recovery.
        let struck = seen.attack > attack + 0.3 || (action == .charge && seen.action == .recover)
        motion.strikeAge = struck ? 0 : min(1_000, motion.strikeAge + step)
        attack = seen.attack
        action = seen.action
        motion.clock = now
        return (x, y, z, yaw)
    }

    /// The signed turn from one heading to another, within half a turn either way. It takes
    /// the same time for any finite input, however large: a heading may come off the network.
    static func shortestTurn(from: Double, to: Double) -> Double {
        let turn = (to - from).remainder(dividingBy: 2 * .pi)
        return turn.isFinite ? turn : 0
    }

    private static func wrapped(_ phase: Float) -> Float {
        let fraction = phase - phase.rounded(.down)
        return fraction.isFinite ? fraction : 0
    }
}

/// The renderer's motion states, one for each prehistoric creature it has drawn lately.
final class PrehistoricMotionStore {
    private var states: [Int: PrehistoricMotionState] = [:]
    private var frame: UInt64 = 0
    /// The store's own clock, in seconds. It only runs forward. The renderer's frame time
    /// wraps every half hour (`timeSec` in main.swift); a creature must neither stall nor
    /// snap when it does, so nothing here or in the pose reads that time directly.
    private(set) var clock = 0.0
    private var frameTime: Double?
    /// States not drawn for this many frames are forgotten.
    static let idleFrames: UInt64 = 240
    static let sweepInterval: UInt64 = 120
    /// A frame that follows the one before by more than this, or precedes it, moves the clock
    /// on by one ordinary frame: the frame time wrapped, or the game stood still for a while.
    static let longestFrame = 1.0
    static let ordinaryFrame = 1.0 / 60

    var count: Int { states.count }

    /// Call once for each frame, before the frame's creatures, with the renderer's frame time.
    func beginFrame(time: Double) {
        frame &+= 1
        if time.isFinite {
            if let last = frameTime {
                let step = time - last
                clock += step > 0 && step <= Self.longestFrame ? step : Self.ordinaryFrame
            }
            frameTime = time
        }
        guard frame % Self.sweepInterval == 0 else { return }
        let frame = frame
        states = states.filter { frame - $0.value.lastFrame <= Self.idleFrames }
    }

    /// Fills in the pose's motion and moves the pose to where the creature is drawn.
    func present(_ pose: inout EntityPose, entity: Entity, rig: PrehistoricRig) {
        let living = entity as? LivingEntity
        let seen = PrehistoricObservation(
            x: pose.x, y: pose.y, z: pose.z, yaw: pose.yaw,
            action: normalizedPrehistoricAction(entity.data.prehistoricAction),
            onGround: entity.onGround, attack: living?.attackAnim ?? 0,
            mirror: entity.lanReplicatedMirror,
            scale: Float(pose.displayScale(modelScale: Double(rig.scale))),
            // A mirror shares its seed with the host's creature, so both screens agree.
            seed: PrehistoricPose.seed(entity.lanReplicationSourceID ?? entity.id))
        var state = states[entity.id] ?? PrehistoricMotionState(seen, time: clock)
        let drawn = state.advance(seen, rig: rig, time: clock)
        state.lastFrame = frame
        states[entity.id] = state
        pose.x = drawn.x; pose.y = drawn.y; pose.z = drawn.z; pose.yaw = drawn.yaw
        pose.motion = state.motion
    }
}
