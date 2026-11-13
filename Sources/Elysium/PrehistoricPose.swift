// The pose of a prehistoric creature: one matrix for each rigid part of its jointed model.
//
// A pose is a pure function of the rig (`PrehistoricRig`), of this frame's reading of the
// creature's movement (`PrehistoricMotion`) and of the time. The same inputs always give the
// same matrices, and nothing here feeds the simulation: it is how a creature looks, not what
// it does.
//
// Conventions of the entity rig: y is up, the head points along negative z, and the parts
// named R sit at negative x. A rotation about x by a positive angle lifts whatever points
// toward the head and swings a hanging limb forward; about y it turns the head toward the R
// side; about z it lifts the L side.

import Foundation
import simd
import ElysiumCore

enum PrehistoricPose {
    // MARK: Entry point

    /// The 24 part matrices `EntityUniforms` carries; unused slots are identity.
    static func partMatrices(rig: PrehistoricRig, pose: EntityPose, time: Double) -> [simd_float4x4] {
        // A creature the motion store follows is posed on the store's clock, which only runs
        // forward; the renderer's frame time wraps every half hour.
        var frame = Frame(rig: rig, motion: pose.motion, time: pose.motion.clock ?? time,
                          scale: Float(pose.displayScale(modelScale: Double(rig.scale))),
                          lookPitch: pose.pitch.isFinite ? Float(max(-0.6, min(0.6, pose.pitch))) : 0)
        switch rig.plan {
        case .biped: frame.poseBiped()
        case .quadruped: frame.poseQuadruped()
        case .flyer: frame.poseFlyer()
        }
        return frame.matrices()
    }

    /// A stable per-animal number, so that a herd does not nod and step in unison.
    static func seed(_ id: Int) -> UInt32 {
        var x = UInt32(truncatingIfNeeded: id) &* 0x9E37_79B1
        x ^= x >> 15
        x = x &* 0x85EB_CA6B
        x ^= x >> 13
        return x
    }

    /// A number in 0 ..< 1 from two integers.
    static func hash(_ a: UInt32, _ b: UInt32) -> Float {
        var x = a ^ (b &* 0x9E37_79B1) ^ 0x7F4A_7C15
        x ^= x >> 16
        x = x &* 0x85EB_CA6B
        x ^= x >> 13
        x = x &* 0xC2B2_AE35
        x ^= x >> 16
        return Float(x >> 8) / Float(1 << 24)
    }

    /// Where an animal is looking, as yaw and pitch in -1 ... 1. It settles on a new point
    /// every `period` seconds, takes the first third of the period to turn there, and looks
    /// straight ahead about a third of the time. Continuous in time for a fixed period.
    static func gaze(seed: UInt32, time: Double, period: Double, salt: UInt32) -> SIMD2<Float> {
        // Bounded, so the whole part always fits an integer whatever time is handed in.
        let cycles = max(-1e12, min(1e12, (time.isFinite ? time : 0) / max(0.1, period)))
            + Double(hash(seed, salt))
        let whole = cycles.rounded(.down)
        let index = UInt32(truncatingIfNeeded: Int64(whole))
        func target(_ i: UInt32) -> SIMD2<Float> {
            let pitch = hash(seed ^ salt, i &* 2 &+ 2) * 2 - 1
            if hash(seed &+ salt, i) < 0.30 { return SIMD2(0, pitch * 0.3) }
            return SIMD2(hash(seed ^ salt, i &* 2 &+ 1) * 2 - 1, pitch)
        }
        let turn = PrehistoricRig.smoothstep(0, 0.32, Float(cycles - whole))
        let from = target(index &- 1), to = target(index)
        return from + (to - from) * turn
    }

    /// The share of a wing beat spent on the downstroke; the upstroke takes the rest.
    static let downstrokeShare: Float = 0.42

    /// Maps the even wing phase onto one whose first half (the downstroke) passes faster.
    static func beat(_ phase: Float) -> Float {
        phase < downstrokeShare
            ? phase / downstrokeShare * 0.5
            : 0.5 + (phase - downstrokeShare) / (1 - downstrokeShare) * 0.5
    }

    // MARK: Leg cycle

    /// Where one foot is in the stride.
    struct Footfall: Equatable {
        /// Fore-aft offset from the rest position, in model metres (negative is ahead).
        var offset: Float
        /// Height of the ball of the foot above the ground.
        var lift: Float
        /// Pitch of the foot (negative points the toes down).
        var pitch: Float
        /// True while the foot stands on the ground.
        var planted: Bool
    }

    /// How far a foot tips onto its toes before it leaves the ground, in radians.
    static let heelOffPitch: Float = 0.45

    /// The path of a foot through one cycle. In the stance (`phase` below `duty`) the foot
    /// stands still on the ground while the body passes over it: its offset runs at the
    /// body's own speed, which is what keeps a foot from sliding. In the swing it lifts,
    /// passes forward and meets the ground again at that same speed.
    static func footfall(phase: Float, duty: Float, stance: Float, lift: Float) -> Footfall {
        let duty = min(0.9, max(0.1, duty))
        if phase < duty {
            let t = phase / duty
            // The foot rolls onto its toes at the end of the stance.
            let heelOff = PrehistoricRig.smoothstep(0.7, 1, t)
            return Footfall(offset: stance * (t - 0.5), lift: 0, pitch: -heelOffPitch * heelOff, planted: true)
        }
        let s = (phase - duty) / (1 - duty)
        // Hermite curve from the rear end of the stance to its front end. Both ends keep the
        // stance's own slope, so the foot neither jerks off the ground nor skids onto it.
        let slope = stance / duty * (1 - duty)
        let s2 = s * s, s3 = s2 * s
        let offset = (2 * s3 - 3 * s2 + 1) * (stance * 0.5) + (s3 - 2 * s2 + s) * slope
            + (-2 * s3 + 3 * s2) * (-stance * 0.5) + (s3 - s2) * slope
        let arc = sin(Float.pi * s)
        let pitch = -heelOffPitch * (1 - s) * (1 - s) - 0.4 * arc * (1 - s) + 0.2 * arc * s
        return Footfall(offset: offset, lift: lift * arc, pitch: pitch, planted: false)
    }

    // MARK: Frame

    /// The working state of one pose: the animation of each part in its own rest frame, and
    /// a stretch that is applied to a part's geometry only (a furled wing membrane).
    struct Frame {
        let rig: PrehistoricRig
        let motion: PrehistoricMotion
        let time: Double
        let scale: Float
        let lookPitch: Float
        var joint: [simd_float4x4]
        var stretch: [SIMD3<Float>]
        /// Filled by `poseLegs` for the legs, which are solved in model space.
        var solved: [simd_float4x4?]
        /// 0 ..< 1, different for each animal.
        let own: Double

        init(rig: PrehistoricRig, motion: PrehistoricMotion, time: Double, scale: Float, lookPitch: Float) {
            self.rig = rig
            self.motion = motion
            self.time = time.isFinite ? time : 0
            self.scale = scale
            self.lookPitch = lookPitch
            joint = [simd_float4x4](repeating: matrix_identity_float4x4, count: rig.partCount)
            stretch = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: rig.partCount)
            solved = [simd_float4x4?](repeating: nil, count: rig.partCount)
            own = Double(PrehistoricPose.hash(motion.seed, 0x51))
        }

        /// A sine of the given rate in cycles per second, with this animal's own offset.
        func wave(_ rate: Double, _ offset: Double = 0) -> Float {
            Float(sin((time * rate + own + offset) * 2 * .pi))
        }

        /// Rotation of a part about its own pivot: yaw, then roll, then pitch.
        static func turn(yaw: Float = 0, pitch: Float = 0, roll: Float = 0) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            if yaw != 0 { m = mRotateY(m, yaw) }
            if roll != 0 { m = mRotateZ(m, roll) }
            if pitch != 0 { m = mRotateX(m, pitch) }
            return m
        }

        /// 0 before a strike, rising to 1 and back within `seconds` after it.
        func strike(_ seconds: Float) -> Float {
            let t = motion.strikeAge / seconds
            return t >= 0 && t < 1 ? sin(Float.pi * t) : 0
        }

        /// Where the animal looks: yaw and pitch in radians before they are shared out over
        /// neck and head. An alert animal scans quickly; a busy one keeps its eyes on its work.
        func look(yawRange: Float, pitchRange: Float, focus: Float) -> SIMD2<Float> {
            let w = motion.weights
            let calm = PrehistoricPose.gaze(seed: motion.seed, time: time, period: 3.4 + 2.8 * own, salt: 1)
            let quick = PrehistoricPose.gaze(seed: motion.seed, time: time, period: 1.1 + 0.6 * own, salt: 2)
            let gaze = calm + (quick - calm) * w.alert
            // A walking animal mostly looks where it is going.
            let free = (1 - 0.8 * min(1, focus)) * (1 - 0.55 * motion.walk)
            // An animal leans its eyes into a turn.
            let lead = max(-0.35, min(0.35, -motion.turn * 0.12))
            return SIMD2(gaze.x * yawRange * free + lead, gaze.y * pitchRange * free)
        }

        // MARK: Bipeds

        /// The gait of this moment: the pace sets it, with the leg pairing the motion state has eased.
        var gait: PrehistoricRig.Gait {
            rig.gait(pace: motion.pace, scale: scale, trot: motion.trot)
        }

        mutating func poseBiped() {
            let w = motion.weights, walk = motion.walk, phase = motion.gaitPhase
            let gait = self.gait
            let run = gait.run * walk
            let stridePhase = phase * 2 * Float.pi
            let breath = wave(Double(0.30 / max(0.5, (rig.legLength * scale).squareRoot())))
            let chew = wave(1.5), tug = wave(2.1)
            let bite = strike(0.36)

            // The body rises over each standing leg, sinks into a long stride, and leans.
            let bob = -cos(stridePhase * 2) * 0.035 * rig.legLength * walk * (0.6 + 0.4 * run)
            let sink = gait.hipDrop * walk + rig.legLength * (0.05 * w.recover + 0.04 * w.eat + 0.02 * w.browse)
            var pitch = -0.10 * run - 0.20 * w.charge - 0.28 * w.browse - 0.34 * w.eat
                + 0.10 * w.alert - 0.06 * w.recover + 0.012 * breath - 0.10 * bite
            pitch = max(-0.6, min(0.3, pitch))
            let roll = 0.03 * sin(stridePhase) * walk + max(-0.1, min(0.1, -motion.turn * 0.05)) * walk
            let sway = 0.05 * cos(stridePhase) * walk
            joint[rig.body] = mTranslate(matrix_identity_float4x4, 0, bob - sink, 0)
                * Self.about(rig.hipCentre, Self.turn(yaw: sway, pitch: pitch, roll: roll))

            // Neck and head keep the eyes level against the body, and do the looking.
            let gaze = look(yawRange: 0.85, pitchRange: 0.22, focus: max(w.browse, max(w.eat, w.charge)))
            let neckPitch = -pitch * 0.55 + 0.04 * cos(stridePhase * 2) * walk
                - 0.45 * w.browse - 0.60 * w.eat + 0.28 * w.alert - 0.10 * w.charge
                + gaze.y * 0.4 + 0.015 * breath - 0.22 * bite
            for index in rig.neck {
                joint[index] = Self.turn(yaw: gaze.x * 0.45 / Float(rig.neck.count),
                                         pitch: neckPitch / Float(rig.neck.count))
            }
            let headPitch = -(pitch + neckPitch) * 0.30 + gaze.y * 0.6
                + w.browse * (-0.18 + 0.07 * chew) + w.eat * (-0.10 + 0.20 * tug)
                + 0.22 * w.charge + 0.20 * bite - lookPitch * 0.5 * w.charge
            joint[rig.head] = Self.turn(yaw: gaze.x * 0.55, pitch: headPitch,
                                        roll: 0.10 * w.eat * wave(1.05, 0.3))
            if rig.jaw >= 0 {
                let snap = strike(0.20)
                let roar = w.alert * (0.22 + 0.20 * max(0, wave(0.45)))
                let open = 0.03 + w.recover * (0.12 + 0.05 * breath) + 0.28 * w.charge
                    + w.eat * (0.20 + 0.16 * chew) + roar + 0.70 * snap
                joint[rig.jaw] = Self.turn(pitch: -max(0, min(0.95, open)))
            }

            // The tail balances the body: it swings against the hips and droops as they tip.
            let segments = Float(max(1, rig.tail.count))
            for (k, index) in rig.tail.enumerated() {
                let along = Float(k)
                let swing = 0.10 * walk * sin(stridePhase + Float.pi - 0.5 * along)
                    + 0.06 * (1 - walk) * wave(0.21, Double(-0.11 * along))
                    + max(-0.25, min(0.25, motion.turn * 0.05)) * (1 + 0.5 * along) / segments
                let droop = 0.6 * -pitch / segments - 0.05 * w.alert - 0.03 * w.charge + 0.012 * breath
                joint[index] = Self.turn(yaw: swing, pitch: droop)
            }

            // Arms hang and swing a little; they reach when the animal charges or strikes.
            for (k, index) in rig.arms.enumerated() {
                let side: Float = k == 0 ? 0 : Float.pi
                joint[index] = Self.turn(pitch: 0.12 * sin(stridePhase + side) * walk
                    + 0.35 * w.charge + 0.20 * w.alert + 0.45 * bite - pitch * 0.5)
            }
            poseLegs(gait: gait, liftShare: 0.10 + 0.14 * run)
        }

        // MARK: Quadrupeds

        mutating func poseQuadruped() {
            let w = motion.weights, walk = motion.walk, phase = motion.gaitPhase
            let gait = self.gait
            let stridePhase = phase * 2 * Float.pi
            let legWorld = rig.legLength * scale
            let breath = wave(Double(0.30 / max(0.5, legWorld.squareRoot())))
            let chew = wave(1.3)
            let blow = strike(0.45)
            let longNeck = rig.neck.count >= 2
            // An animal without a long neck fights with what it carries: a tail of three
            // segments ends in spikes or a club, a shorter one belongs to a horned head.
            let tailFighter = longNeck || rig.tail.count >= 3
            let lowBrowser = rig.neckRise < 0.9

            let bob = -cos(stridePhase * 2) * 0.012 * rig.legLength * walk
            let sink = gait.hipDrop * walk + rig.legLength * 0.03 * w.recover
            let pitch = -0.05 * w.charge + 0.03 * w.alert - (longNeck ? 0 : 0.03) * w.browse + 0.008 * breath
            let roll = 0.025 * sin(stridePhase) * walk + max(-0.06, min(0.06, -motion.turn * 0.03)) * walk
            joint[rig.body] = mTranslate(matrix_identity_float4x4, 0, bob - sink, 0)
                * Self.turn(yaw: 0.02 * cos(stridePhase) * walk, pitch: pitch, roll: roll)

            let gaze = look(yawRange: longNeck ? 1.0 : 0.42, pitchRange: 0.20,
                            focus: max(w.browse * (longNeck ? 0.4 : 1), max(w.eat, w.charge)))
            if longNeck {
                // A long neck shares every turn over its segments, sweeps while it feeds, and
                // the head stays level at the end of it.
                let count = Float(rig.neck.count)
                let sweep = w.browse * 0.5 * wave(0.11)
                let reach = w.browse * (lowBrowser ? -1.0 : 0.22) + w.alert * (lowBrowser ? 0.40 : 0.14)
                    + gaze.y * 0.5 + 0.03 * sin(stridePhase * 2) * walk + 0.02 * breath
                for index in rig.neck {
                    joint[index] = Self.turn(yaw: (gaze.x + sweep) * 0.8 / count, pitch: reach / count)
                }
                joint[rig.head] = Self.turn(yaw: (gaze.x + sweep) * 0.2,
                                            pitch: -reach * 0.7 + w.browse * 0.08 * chew)
            } else {
                // A horned head lowers to graze, lowers further to charge, and tosses to strike.
                let toss = tailFighter ? 0 : blow
                let headPitch = w.browse * (-0.85 + 0.06 * chew) - 0.50 * w.charge + 0.22 * w.alert
                    + gaze.y + 0.01 * breath + toss * 0.55 - lookPitch * 0.3 * w.charge
                joint[rig.head] = Self.turn(yaw: gaze.x, pitch: max(-1.1, min(0.6, headPitch)))
            }

            // The tail sways; an armoured animal that feels threatened swings it in earnest.
            let segments = Float(max(1, rig.tail.count))
            let threat = tailFighter && !longNeck ? max(w.alert, w.charge) : 0
            let swipe = tailFighter ? blow : 0
            for (k, index) in rig.tail.enumerated() {
                let along = Float(k)
                let calm = (0.04 + 0.015 * segments) * wave(0.19, Double(-0.12 * along))
                let armed = 0.20 * wave(0.85, Double(-0.10 * along))
                let swing = calm * (1 - threat) + armed * threat
                    + 0.05 * walk * sin(stridePhase + Float.pi - 0.5 * along)
                    + max(-0.2, min(0.2, motion.turn * 0.05)) * (1 + along) / segments
                    + swipe * 0.45 * (1 + along) / segments
                joint[index] = Self.turn(yaw: swing, pitch: -0.05 * threat + 0.008 * breath)
            }
            poseLegs(gait: gait, liftShare: 0.07 + 0.09 * gait.run * walk)
        }

        // MARK: Flyers

        mutating func poseFlyer() {
            let w = motion.weights
            let flight = w.flight, power = w.power * flight, fold = 1 - flight
            let stroke = PrehistoricPose.beat(motion.flapPhase) * 2 * Float.pi
            let breath = wave(0.42)
            let jointed = rig.wings.contains { $0.outer >= 0 }

            // In the air the body follows the flight path, banks into a turn and rides the beat.
            // With no way on (a hover, a straight descent to a perch, the first beats of a
            // take-off) it never points its nose down, because a body that sinks in place is
            // not diving, and while it beats its wings there it holds itself more upright.
            let path = atan2(motion.climb, max(2, motion.speed))
            let hang = motion.hang
            let pitch = min(0.8, fold * 0.10 + flight * max(-0.45 * (1 - hang), min(0.6, 0.8 * path))
                + 0.30 * w.takeoff + 0.40 * w.landing + 0.25 * power * hang + 0.01 * breath)
            let bank = flight * max(-0.7, min(0.7, -motion.turn * 0.45))
            let heave = -power * rig.wingLength * 0.05 * cos(stroke - 0.6)
            joint[rig.body] = mTranslate(matrix_identity_float4x4, 0, heave, 0)
                * Self.turn(pitch: pitch, roll: bank)

            // The head stays level through pitch and bank, and looks about at rest and in a glide.
            let gaze = look(yawRange: 0.75 - 0.3 * flight, pitchRange: 0.20, focus: w.takeoff + w.landing)
            let neckCount = Float(max(1, rig.neck.count))
            for (k, index) in rig.neck.enumerated() {
                joint[index] = Self.turn(yaw: gaze.x * 0.5 / neckCount,
                                         pitch: (-pitch * 0.6 + gaze.y * 0.4) / neckCount,
                                         roll: k == 0 ? -bank * 0.8 : 0)
            }
            joint[rig.head] = Self.turn(yaw: gaze.x * 0.5,
                                        pitch: -pitch * 0.25 + gaze.y * 0.6 - 0.12 * flight * (1 - power),
                                        roll: rig.neck.isEmpty ? -bank * 0.8 : 0)

            // Wings: beat in powered flight, hold a shallow V in a glide, fold away at rest.
            let reach: Float = 0.62 + 0.18 * w.takeoff + 0.10 * w.landing
            let flex = max(0, -sin(stroke))   // the upstroke
            for wing in rig.wings {
                let side = wing.side
                if wing.hind {
                    // Hind wings trail the fore wings in a beat and hang along the legs at rest.
                    let raise = fold * -1.0
                        + flight * (0.04 * (1 - w.power) + power * 0.45 * reach * cos(stroke - 1.2))
                    joint[wing.inner] = Self.turn(yaw: -side * fold * 0.5, pitch: 0, roll: side * raise)
                    stretch[wing.inner] = SIMD3(1, 1, 1 - 0.5 * fold)
                    continue
                }
                let beat = power * (0.08 + reach * cos(stroke))
                let raise = fold * (jointed ? -0.40 : -0.30) + flight * (1 - w.power) * 0.10 + beat
                    + 0.25 * w.landing * flight
                let sweep = fold * (jointed ? 1.0 : 1.15) - 0.12 * w.landing * flight
                let twist = -0.15 * power * sin(stroke)
                joint[wing.inner] = Self.turn(yaw: -side * sweep, pitch: twist, roll: side * raise)
                stretch[wing.inner] = SIMD3(1, 1, 1 - (jointed ? 0.68 : 0.55) * fold)
                if wing.outer >= 0 {
                    // The outer wing lags the inner one and bends at the wrist on the upstroke.
                    let outerRaise = fold * 0.55 + power * (0.40 * cos(stroke - 0.9) - 0.35 * flex)
                        - 0.05 * flight * (1 - w.power)
                    let outerSweep = fold * 0.75 + power * 0.45 * flex + 0.06 * flight * (1 - w.power)
                    joint[wing.outer] = Self.turn(yaw: -side * outerSweep, roll: side * outerRaise)
                    stretch[wing.outer] = SIMD3(1, 1, 1 - 0.70 * fold)
                }
            }

            // Legs trail in flight. Under a body with no way on they hang straight down,
            // whatever its pitch, as they do when it stands: so a flyer that is set down out of
            // a hover keeps them where they are while it folds. A landing reaches down and
            // forward from either, and each step is a plain blend, so none can overshoot.
            let trailing = -1.15 - 0.20 * w.takeoff
            let under = trailing + (-pitch - trailing) * hang * (1 - w.takeoff)
            let aloft = under + (trailing + 1.9 - under) * w.landing
            let trail = -pitch * fold + flight * aloft
            for index in rig.danglingLegs {
                joint[index] = Self.turn(pitch: trail)
            }
            let segments = Float(max(1, rig.tail.count))
            for (k, index) in rig.tail.enumerated() {
                let along = Float(k)
                let swing = 0.05 * wave(0.35, Double(-0.15 * along))
                    + max(-0.3, min(0.3, motion.turn * 0.10)) * (1 + along) / segments
                joint[index] = Self.turn(yaw: swing, pitch: 0.04 * power * sin(stroke - 0.4 * along))
            }
        }

        // MARK: Legs

        /// Solves every walking leg so that its foot follows its footfall. The hip comes from
        /// the posed body, the foot from the ground, and the knee from the two bone lengths.
        mutating func poseLegs(gait: PrehistoricRig.Gait, liftShare: Float) {
            let walk = motion.walk, air = motion.airborne
            let body = rig.rest[rig.body] * joint[rig.body]
            for leg in rig.legs {
                let phase = rig.legPhase(leg, gaitPhase: motion.gaitPhase, trot: gait.trot)
                // Turning on the spot lifts and sets the feet without sweeping them.
                let fall = PrehistoricPose.footfall(phase: phase, duty: gait.duty,
                                                    stance: gait.stance * motion.travel,
                                                    lift: rig.legLength * liftShare)
                // A standing animal keeps its feet under it; one in the air lets them hang.
                var end = SIMD2(leg.restEnd.x + fall.lift * walk,
                                leg.restEnd.y + (leg.centre - leg.restEnd.y + fall.offset) * walk)
                var footPitch = fall.pitch * walk
                // The foot turns about its ball, which lifts the ankle.
                let toe = leg.toe
                let c = cos(footPitch), s = sin(footPitch)
                end += SIMD2(toe.x * c - toe.y * s, toe.x * s + toe.y * c) - toe
                end += SIMD2(rig.legLength * 0.10, rig.legLength * 0.05) * air
                footPitch += -0.30 * air

                let hip4 = body * SIMD4(leg.hip.x, leg.hip.y, leg.hip.z, 1)
                let hip = SIMD2(hip4.y, hip4.z)
                var toEnd = end - hip
                let longest = (leg.upperLength + leg.lowerLength) * 0.999
                let shortest = abs(leg.upperLength - leg.lowerLength) + 0.001
                let wanted = simd_length(toEnd)
                let distance = min(longest, max(shortest, wanted))
                toEnd = wanted > 0.000_1 ? toEnd * (distance / wanted) : SIMD2(-distance, 0)
                end = hip + toEnd
                let line = atan2(-toEnd.y, -toEnd.x)
                let cosine = (leg.upperLength * leg.upperLength + distance * distance
                    - leg.lowerLength * leg.lowerLength) / (2 * leg.upperLength * distance)
                let bend = acos(max(-1, min(1, cosine)))
                let upperAngle = leg.kneeForward ? line + bend : line - bend
                let knee = hip + SIMD2(-cos(upperAngle), -sin(upperAngle)) * leg.upperLength
                let lowerAngle = atan2(-(end.y - knee.y), -(end.x - knee.x))

                solved[leg.upper] = mRotateX(mTranslate(matrix_identity_float4x4, hip4.x, hip.x, hip.y),
                                             upperAngle - leg.upperRest)
                solved[leg.lower] = mRotateX(mTranslate(matrix_identity_float4x4, hip4.x, knee.x, knee.y),
                                             lowerAngle - leg.lowerRest)
                solved[leg.foot] = mRotateX(mTranslate(matrix_identity_float4x4, hip4.x, end.x, end.y),
                                            footPitch)
            }
        }

        // MARK: Composition

        /// A rotation about a point of the part instead of its pivot.
        static func about(_ point: SIMD3<Float>, _ rotation: simd_float4x4) -> simd_float4x4 {
            mTranslate(mTranslate(matrix_identity_float4x4, point.x, point.y, point.z) * rotation,
                       -point.x, -point.y, -point.z)
        }

        /// Composes parent and child (a parent comes before its children), puts the solved
        /// legs in place, and applies each part's own stretch last so no child inherits it.
        func matrices() -> [simd_float4x4] {
            var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: PrehistoricRig.maximumParts)
            for index in 0..<rig.partCount {
                if let fixed = solved[index] {
                    world[index] = fixed
                    continue
                }
                let parent = rig.parents[index]
                let base = parent < 0 ? rig.local[index] : world[parent] * rig.local[index]
                world[index] = base * joint[index]
            }
            for index in 0..<rig.partCount where stretch[index] != SIMD3(1, 1, 1) {
                world[index] = mScale(world[index], stretch[index].x, stretch[index].y, stretch[index].z)
            }
            return world
        }
    }
}
