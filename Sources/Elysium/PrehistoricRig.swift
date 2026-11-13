// The jointed skeleton of a prehistoric creature, read once from its `MobModel`.
//
// A model lists rigid parts; a jointed model also says which part each one hangs from
// (`ModelPart.parent`) and where its bone ends (`ModelPart.tip`). This file turns that into
// indices, rest matrices and bone lengths, so the per-frame pose code (`PrehistoricPose`) does
// arithmetic only: no string comparison and no search runs while a frame is drawn.
//
// Lengths are in model metres (a sixteenth of the model's authoring unit, the unit of the
// entity vertex stream). `scale` turns them into blocks.

import Foundation
import simd
import ElysiumCore

struct PrehistoricRig {
    /// The body plan decides which motions apply.
    typealias Plan = PrehistoricRigPlan

    /// One leg that walks: an upper leg, a lower leg and a foot.
    struct Leg {
        let upper: Int
        let lower: Int
        let foot: Int
        /// The hip, seen from the body's rest pivot.
        let hip: SIMD3<Float>
        let upperLength: Float
        let lowerLength: Float
        /// Rest angles of the two bones in the animal's side plane (0 hangs straight down,
        /// positive swings toward the head).
        let upperRest: Float
        let lowerRest: Float
        /// The ankle at rest, as height and fore-aft position in model space.
        let restEnd: SIMD2<Float>
        /// Where the middle of a stride falls, fore-aft in model space: nearer the hip than the
        /// rest position, so the leg reaches as far ahead of the hip as behind it.
        let centre: Float
        /// The ankle seen from the ball of the foot, as height and fore-aft distance: a foot
        /// turns about its ball.
        let toe: SIMD2<Float>
        /// A knee points toward the head; the elbow of a fore leg points toward the tail.
        let kneeForward: Bool
        /// Where in the stride this leg starts its stance, at a walk and at a trot.
        let walkPhase: Float
        let trotPhase: Float
        /// The longest stance this leg can sweep without help, and with the hips dropped by
        /// `PrehistoricRig.hipDropShare` of the leg length.
        let reach: Float
    }

    /// One wing: the part at the shoulder and, for a pterosaur, the part beyond the wrist.
    struct Wing {
        let inner: Int
        /// The outer wing, or -1 when the wing is one piece.
        let outer: Int
        /// -1 on the animal's right (negative x), +1 on its left.
        let side: Float
        /// A hind wing of a four-winged glider.
        let hind: Bool
    }

    static let maximumParts = 24
    /// How far the hips may sink, as a share of the leg length, to lengthen a stride.
    static let hipDropShare: Float = 0.08
    /// How much of its full length a leg may straighten to while it stands.
    static let reachShare: Float = 0.985
    /// The least share of a stride a foot spends on the ground, at a flat-out sprint.
    static let shortestDuty: Float = 0.22

    let plan: Plan
    let partCount: Int
    /// The index of each part's parent, -1 for a root.
    let parents: [Int]
    /// Rest matrix of each part in model space.
    let rest: [simd_float4x4]
    /// Rest matrix of each part seen from its parent (from model space for a root).
    let local: [simd_float4x4]

    let body: Int
    /// Neck segments from the shoulders to the skull; empty when the head sits on the body.
    let neck: [Int]
    let head: Int
    /// The lower jaw, or -1.
    let jaw: Int
    /// Tail segments from the hips to the tip.
    let tail: [Int]
    /// The arms of a biped (right, left); empty otherwise.
    let arms: [Int]
    let legs: [Leg]
    let wings: [Wing]
    /// The legs of a flyer, which hang from the hip in one piece.
    let danglingLegs: [Int]

    /// Height of the hind hips above the ground at rest: the size that sets stride and cadence.
    let legLength: Float
    /// The point the body pitches about when it leans: between the hips of a biped.
    let hipCentre: SIMD3<Float>
    /// How far the feet stand from the turning axis; an animal that turns on the spot steps.
    let turnRadius: Float
    /// Shoulder to wing tip.
    let wingLength: Float
    /// A neck that rises steeply at rest belongs to a high browser.
    let neckRise: Float
    /// The model's own display scale (blocks per model metre).
    let scale: Float

    /// The rig of a jointed prehistoric model, or nil for every other model. A model that
    /// claims a prehistoric plan but breaks the rig rules is a programming error in its
    /// builder; `prehistoricModelValidationErrors` reports those, and here it simply falls
    /// back to the rest pose by returning nil.
    init?(model: MobModel) {
        guard let plan = Plan(rawValue: model.anim) else { return nil }
        let parts = model.parts
        guard !parts.isEmpty, parts.count <= Self.maximumParts else { return nil }

        var indexByName: [String: Int] = [:]
        for (index, part) in parts.enumerated() {
            guard indexByName[part.name] == nil else { return nil }
            indexByName[part.name] = index
        }
        var parents: [Int] = []
        var rest: [simd_float4x4] = []
        var local: [simd_float4x4] = []
        for (index, part) in parts.enumerated() {
            var parent = -1
            if let name = part.parent {
                // A parent is listed before its children, so one forward pass composes a pose.
                guard let found = indexByName[name], found < index else { return nil }
                parent = found
            }
            let matrix = Self.restMatrix(part)
            parents.append(parent)
            rest.append(matrix)
            local.append(parent < 0 ? matrix : rest[parent].inverse * matrix)
        }

        func index(_ name: String) -> Int { indexByName[name] ?? -1 }
        func chain(_ first: String) -> [Int] {
            var out: [Int] = []
            var name = first
            var number = 1
            while let found = indexByName[name] {
                out.append(found)
                name = "\(first)\(number)"
                number += 1
            }
            return out
        }
        func pivot(_ index: Int) -> SIMD3<Float> {
            let p = parts[index].pivot
            return SIMD3(Float(p.0), Float(p.1), Float(p.2)) / 16
        }
        func tip(_ index: Int) -> SIMD3<Float>? {
            guard let t = parts[index].tip else { return nil }
            return SIMD3(Float(t.0), Float(t.1), Float(t.2)) / 16
        }

        let body = index("body"), head = index("head")
        // The body is the root and carries no baked rotation: hips and shoulders are read
        // straight from the pivots.
        guard body >= 0, head >= 0, parents[body] < 0,
              parts[body].rot.0 == 0, parts[body].rot.1 == 0, parts[body].rot.2 == 0 else { return nil }

        var legs: [Leg] = []
        if plan != .flyer {
            // Stance order: a biped alternates; a quadruped at a walk sets down left hind,
            // left fore, right hind, right fore, and at a trot moves diagonal pairs together.
            let layout: [(suffix: String, fore: Bool, walk: Float, trot: Float)] = plan == .biped
                ? [("L", false, 0, 0), ("R", false, 0.5, 0.5)]
                : [("BL", false, 0, 0), ("FL", true, 0.25, 0.5), ("BR", false, 0.5, 0.5), ("FR", true, 0.75, 1)]
            for entry in layout {
                let upper = index("leg\(entry.suffix)"), lower = index("shin\(entry.suffix)")
                let foot = index("foot\(entry.suffix)")
                guard upper >= 0, lower >= 0, foot >= 0, parents[upper] == body, parents[lower] == upper,
                      parents[foot] == lower, let knee = tip(upper), let end = tip(lower),
                      let ball = tip(foot) else { return nil }
                let toe = SIMD2(-ball.y, -ball.z)
                let upperLength = simd_length(SIMD2(knee.y, knee.z))
                let lowerLength = simd_length(SIMD2(end.y, end.z))
                guard upperLength > 0.001, lowerLength > 0.001 else { return nil }
                let hip = pivot(upper)
                let restEnd3 = pivot(lower) + end
                let restEnd = SIMD2(restEnd3.y, restEnd3.z)
                // A stride may reach as far as the straightened leg allows once the hips have
                // sunk by the permitted share.
                let centre = restEnd.y + (hip.z - restEnd.y) * 0.7
                let total = (upperLength + lowerLength) * Self.reachShare
                let height = max(0.001, (hip.y - restEnd.x) * (1 - Self.hipDropShare))
                let offset = abs(hip.z - centre)
                let half = max(0, (max(0, total * total - height * height)).squareRoot() - offset)
                legs.append(Leg(
                    upper: upper, lower: lower, foot: foot,
                    hip: hip - pivot(body), upperLength: upperLength, lowerLength: lowerLength,
                    upperRest: Self.boneAngle(knee), lowerRest: Self.boneAngle(end), restEnd: restEnd,
                    centre: centre, toe: toe, kneeForward: !entry.fore, walkPhase: entry.walk, trotPhase: entry.trot, reach: half * 2))
            }
        }

        var wings: [Wing] = []
        var danglingLegs: [Int] = []
        var wingLength: Float = 0
        if plan == .flyer {
            for (suffix, side) in [("R", Float(-1)), ("L", Float(1))] {
                let inner = index("wing\(suffix)")
                guard inner >= 0, parents[inner] == body, let wrist = tip(inner) else { return nil }
                let outer = index("wingTip\(suffix)")
                var length = simd_length(wrist)
                if outer >= 0 {
                    guard parents[outer] == inner, let end = tip(outer) else { return nil }
                    length += simd_length(end)
                }
                wingLength = max(wingLength, length)
                wings.append(Wing(inner: inner, outer: outer, side: side, hind: false))
                let hind = index("hindWing\(suffix)")
                if hind >= 0 {
                    guard parents[hind] == body else { return nil }
                    wings.append(Wing(inner: hind, outer: -1, side: side, hind: true))
                }
                let leg = index("leg\(suffix)")
                if leg >= 0, parents[leg] == body { danglingLegs.append(leg) }
            }
        }

        let neck = chain("neck"), tail = chain("tail")
        let hindLegs = legs.filter { $0.kneeForward }
        let legLength = hindLegs.isEmpty ? 0
            : hindLegs.reduce(Float(0)) { $0 + $1.hip.y + pivot(body).y } / Float(hindLegs.count)
        var hipCentre = SIMD3<Float>(0, 0, 0)
        if !hindLegs.isEmpty {
            hipCentre = hindLegs.reduce(SIMD3<Float>(0, 0, 0)) { $0 + $1.hip } / Float(hindLegs.count)
            hipCentre.x = 0
        }
        var turnRadius: Float = 0
        for leg in legs {
            turnRadius = max(turnRadius, simd_length(SIMD2(leg.hip.x, leg.restEnd.y)))
        }
        var neckRise: Float = 0
        if let first = neck.first {
            let span = pivot(head) - pivot(first)
            neckRise = span.y / max(0.001, abs(span.z))
        }

        self.plan = plan
        self.partCount = parts.count
        self.parents = parents
        self.rest = rest
        self.local = local
        self.body = body
        self.neck = neck
        self.head = head
        self.jaw = index("jaw")
        self.tail = tail
        self.arms = plan == .biped ? [index("armR"), index("armL")].filter { $0 >= 0 } : []
        self.legs = legs
        self.wings = wings
        self.danglingLegs = danglingLegs
        self.legLength = legLength
        self.hipCentre = hipCentre
        self.turnRadius = turnRadius
        self.wingLength = wingLength
        self.neckRise = neckRise
        self.scale = Float(model.scale)
    }

    /// The rest matrix `EntityRendererM.partTransforms` gives a part before any animation:
    /// the pivot, then the baked rotation in z, y, x order.
    static func restMatrix(_ part: ModelPart) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m = mTranslate(m, Float(part.pivot.0 / 16), Float(part.pivot.1 / 16), Float(part.pivot.2 / 16))
        if part.rot.2 != 0 { m = mRotateZ(m, Float(part.rot.2)) }
        if part.rot.1 != 0 { m = mRotateY(m, Float(part.rot.1)) }
        if part.rot.0 != 0 { m = mRotateX(m, Float(part.rot.0)) }
        return m
    }

    /// The angle of a bone in the side plane: 0 hangs straight down, positive points toward
    /// the head (negative z). A rotation about x by this angle turns a hanging bone onto it.
    static func boneAngle(_ bone: SIMD3<Float>) -> Float {
        atan2(-bone.z, -bone.y)
    }

    // MARK: Gait

    /// How an animal of this build steps at a given pace.
    ///
    /// One rule holds for every gait this file hands out: the stance is exactly what the body
    /// covers while a foot stands (`stance * scale == duty * stride`). The motion state turns
    /// the legs by `stride` and the pose sweeps a standing foot by `stance`; a foot stays put
    /// only while both come from the same gait.
    struct Gait {
        /// Blocks travelled in one full cycle of the legs.
        var stride: Float
        /// The share of a cycle a foot spends on the ground.
        var duty: Float
        /// How far a foot sweeps under the body while it stands, in model metres.
        var stance: Float
        /// How far the hips sink to make that sweep reachable, in model metres.
        var hipDrop: Float
        /// 0 at a walk, 1 at a full run.
        var run: Float
        /// 0 while a quadruped sets one foot down after another, 1 when its diagonal legs move
        /// together. Only the lighter animals trot; the giants walk at every pace.
        var trot: Float
    }

    /// Where a leg is in its own cycle, 0 ..< 1, for a given point of the animal's stride.
    func legPhase(_ leg: Leg, gaitPhase: Float, trot: Float) -> Float {
        let phase = gaitPhase + leg.walkPhase + (leg.trotPhase - leg.walkPhase) * trot
        return phase - phase.rounded(.down)
    }

    /// Stride and cadence from the pace, after the dynamic similarity of walking animals: a
    /// small animal at the same speed takes many short steps, a large one few long ones.
    /// `pace` is in blocks per second and `scale` is the animal's display scale.
    ///
    /// `trot` is how far the animal has changed from a walk to a trot by now. A pace asks for
    /// one or the other at once, but a leg cannot move to another place in the stride within
    /// a frame: the motion state eases the change over a few steps and hands it in here.
    /// Without it the gait has the pairing its pace asks for.
    func gait(pace: Float, scale: Float, trot settled: Float? = nil) -> Gait {
        let leg = max(0.05, legLength * scale)
        let froude = pace * pace / (9.81 * leg)
        // Animals change from a walk to a run near a Froude number of one half.
        let run = Self.smoothstep(0.3, 1.0, froude)
        // Heavy animals keep more feet down: a sauropod never leaves the ground.
        let heavy = Self.smoothstep(1.4, 2.8, leg)
        let walkDuty: Float = plan == .biped ? 0.62 : 0.68
        // A small animal at full tilt spends most of each stride in the air.
        let sprint = Self.smoothstep(1.0, 6.0, froude)
        let runDuty: Float = (plan == .biped ? 0.36 : 0.42) + 0.22 * heavy - 0.10 * sprint
        var duty = walkDuty + (min(walkDuty, runDuty) - walkDuty) * run
        var stride = leg * min(4.5, max(0.6, 2.3 * pow(max(froude, 0.000_001), 0.3)))
        // A stride longer than the legs can sweep is made up in the air: the feet spend less
        // of it on the ground. The cadence stays the one the pace asks for, so the legs never
        // slow down while the animal speeds up.
        let reach = legs.reduce(Float.greatestFiniteMagnitude) { min($0, $1.reach) }
        duty = min(duty, max(Self.shortestDuty, reach * scale / stride))
        var stance = duty * stride / max(0.001, scale)
        if stance > reach {
            // Only at the shortest duty: then the stride gives way.
            stance = reach
            stride = stance * scale / duty
        }
        let asked: Float = plan == .quadruped ? run * (1 - Self.smoothstep(1.0, 2.2, leg)) : 0
        let trot = settled.map { min(1, max(0, $0)) } ?? asked
        var drop: Float = 0
        for leg in legs {
            // The hips sink just far enough for the longest reach of this stance.
            let total = (leg.upperLength + leg.lowerLength) * Self.reachShare
            let bodyY = rest[body].columns.3.y
            let hipY = bodyY + leg.hip.y, hipZ = rest[body].columns.3.z + leg.hip.z
            let far = abs(hipZ - leg.centre) + stance * 0.5
            let allowed = (max(0, total * total - far * far)).squareRoot()
            drop = max(drop, (hipY - leg.restEnd.x) - allowed)
        }
        return Gait(stride: stride, duty: duty, stance: stance,
                    hipDrop: min(max(0, drop), legLength * Self.hipDropShare), run: run, trot: trot)
    }

    /// Wing beats per second from the wingspan: a Quetzalcoatlus rows slowly, a Microraptor whirrs.
    func beatRate(scale: Float) -> Float {
        let span = max(0.2, 2 * wingLength * scale)
        return min(6.5, max(0.9, 3.6 * pow(span, -0.55)))
    }

    static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}
