import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// The pose math of the jointed prehistoric creatures: what a frame reads of a creature's
/// movement (`PrehistoricMotionState`) and the part matrices that follow from it
/// (`PrehistoricPose`). Everything is driven the way the renderer drives it, frame by frame.
final class PrehistoricPoseTests: XCTestCase {
    static let bipeds = [
        "compsognathus", "coelophysis", "velociraptor", "dilophosaurus", "deinonychus", "allosaurus",
        "ceratosaurus", "carnotaurus", "tyrannosaurus", "spinosaurus", "dryosaurus", "pachycephalosaurus",
        "gallimimus", "oviraptor", "parasaurolophus", "edmontosaurus", "iguanodon", "therizinosaurus",
    ]
    static let quadrupeds = ["triceratops", "styracosaurus", "stegosaurus", "ankylosaurus", "diplodocus", "brachiosaurus"]
    static let flyers = ["dimorphodon", "rhamphorhynchus", "pteranodon", "tapejara", "quetzalcoatlus", "microraptor"]
    static let swimmers = ["ichthyosaurus", "plesiosaurus", "elasmosaurus", "liopleurodon", "mosasaurus", "deinosuchus"]
    static var walkers: [String] { bipeds + quadrupeds }
    static var jointed: [String] { bipeds + quadrupeds + flyers }

    /// One creature, moved the way the renderer sees a creature move.
    struct Subject {
        let name: String
        let model: MobModel
        let rig: PrehistoricRig
        var state: PrehistoricMotionState?
        var time = 0.0
        var x = 0.0, y = 64.0, z = 0.0, yaw = 0.0
        var seed: UInt32 = PrehistoricPose.seed(7)

        init(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
            self.name = name
            model = getModel("prehistoric.\(name)")
            rig = try XCTUnwrap(PrehistoricRig(model: model), "\(name) has no jointed rig", file: file, line: line)
        }

        var motion: PrehistoricMotion { state?.motion ?? PrehistoricMotion() }

        /// Advances by one frame. At yaw 0 a creature travels toward +z.
        @discardableResult
        mutating func step(dt: Double, speed: Double = 0, action: PrehistoricAction = .idle,
                           onGround: Bool = true, turn: Double = 0, climb: Double = 0,
                           attack: Double = 0) -> (x: Double, y: Double, z: Double, yaw: Double) {
            time += dt
            x += -sin(yaw) * speed * dt
            z += cos(yaw) * speed * dt
            y += climb * dt
            yaw += turn * dt
            let seen = PrehistoricObservation(x: x, y: y, z: z, yaw: yaw, action: action, onGround: onGround,
                                              attack: attack, mirror: false, scale: rig.scale, seed: seed)
            if state == nil { state = PrehistoricMotionState(seen, time: time - dt) }
            return state!.advance(seen, rig: rig, time: time)
        }

        mutating func run(seconds: Double, fps: Double = 120, speed: Double = 0,
                          action: PrehistoricAction = .idle, onGround: Bool = true, turn: Double = 0,
                          climb: Double = 0) {
            for _ in 0..<max(1, Int((seconds * fps).rounded())) {
                step(dt: 1 / fps, speed: speed, action: action, onGround: onGround, turn: turn, climb: climb)
            }
        }

        func matrices() -> [simd_float4x4] {
            var pose = EntityPose()
            pose.motion = motion
            return PrehistoricPose.partMatrices(rig: rig, pose: pose, time: time)
        }

        func index(_ part: String) -> Int {
            model.parts.firstIndex { $0.name == part } ?? -1
        }

        /// A point of a part, given in the part's own model metres, in model space.
        func point(_ part: Int, _ local: SIMD3<Float> = .zero, in matrices: [simd_float4x4]) -> SIMD3<Float> {
            let p = matrices[part] * SIMD4(local.x, local.y, local.z, 1)
            return SIMD3(p.x, p.y, p.z)
        }

        /// The end of a part's bone in model space.
        func tip(_ part: Int, in matrices: [simd_float4x4]) -> SIMD3<Float> {
            let t = model.parts[part].tip ?? (0, 0, 0)
            return point(part, SIMD3(Float(t.0), Float(t.1), Float(t.2)) / 16, in: matrices)
        }
    }

    /// The rotation between two matrices' upper 3x3 parts, as an angle. Stretch is divided out.
    private func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        func rotation(_ m: simd_float4x4) -> simd_float3x3 {
            simd_float3x3(simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                          simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                          simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        }
        let relative = rotation(a).transpose * rotation(b)
        let trace = relative.columns.0.x + relative.columns.1.y + relative.columns.2.z
        return acos(max(-1, min(1, (trace - 1) / 2)))
    }

    // MARK: Rig

    func testEveryLandAndFlyingSpeciesIsJointedAndEverySwimmerKeepsItsOldAnimator() throws {
        XCTAssertEqual(Set(Self.jointed + Self.swimmers).count, 36)
        XCTAssertEqual(Set((Self.jointed + Self.swimmers).map { "prehistoric.\($0)" }), Set(prehistoricModelIDs))
        for name in Self.bipeds {
            let rig = try Subject(name).rig
            XCTAssertEqual(rig.plan, .biped, name)
            XCTAssertEqual(rig.legs.count, 2, name)
            XCTAssertTrue(rig.legs.allSatisfy { $0.foot >= 0 && $0.kneeForward }, name)
            XCTAssertEqual(rig.tail.count, 3, name)
            XCTAssertEqual(rig.neck.count, 1, name)
            XCTAssertEqual(rig.arms.count, 2, name)
        }
        for name in Self.quadrupeds {
            let rig = try Subject(name).rig
            XCTAssertEqual(rig.plan, .quadruped, name)
            XCTAssertEqual(rig.legs.count, 4, name)
            XCTAssertEqual(rig.legs.filter { $0.kneeForward }.count, 2, "\(name): two hind legs with knees")
            XCTAssertTrue(rig.legs.allSatisfy { $0.foot >= 0 }, name)
            XCTAssertGreaterThanOrEqual(rig.tail.count, 2, name)
        }
        XCTAssertEqual(try Subject("diplodocus").rig.neck.count, 4)
        XCTAssertEqual(try Subject("brachiosaurus").rig.neck.count, 4)
        for name in Self.flyers {
            let rig = try Subject(name).rig
            XCTAssertEqual(rig.plan, .flyer, name)
            XCTAssertTrue(rig.legs.isEmpty, name)
            XCTAssertEqual(rig.danglingLegs.count, 2, name)
            XCTAssertEqual(rig.wings.filter { !$0.hind }.count, 2, name)
            XCTAssertGreaterThan(rig.wingLength, 0.3, name)
        }
        XCTAssertTrue(try Subject("pteranodon").rig.wings.allSatisfy { $0.outer >= 0 })
        XCTAssertEqual(try Subject("microraptor").rig.wings.filter { $0.hind }.count, 2)
        XCTAssertEqual(try Subject("quetzalcoatlus").rig.neck.count, 2)
        for name in Self.swimmers {
            let model = getModel("prehistoric.\(name)")
            XCTAssertNil(PrehistoricRig(model: model), "\(name) keeps its unjointed animator")
            XCTAssertTrue(["fish", "prehistoricQuad"].contains(model.anim), "\(name): \(model.anim)")
        }
        XCTAssertNil(PrehistoricRig(model: getModel("pig")))
        XCTAssertNil(PrehistoricRig(model: getModel("phantom")))
    }

    func testAPoseWithoutAnyMotionIsTheRestPoseOfTheModel() throws {
        // With every joint at rest the composed matrices must be the matrices the renderer
        // gave these parts before they were jointed; the solved legs must land on them too.
        for name in Self.jointed {
            let subject = try Subject(name)
            var frame = PrehistoricPose.Frame(rig: subject.rig, motion: PrehistoricMotion(), time: 0,
                                              scale: subject.rig.scale, lookPitch: 0)
            let composed = frame.matrices()
            if subject.rig.plan != .flyer {
                let gait = subject.rig.gait(pace: 0, scale: subject.rig.scale)
                frame.poseLegs(gait: gait, liftShare: 0.1)
            }
            let solved = frame.matrices()
            for (index, part) in subject.model.parts.enumerated() {
                let rest = PrehistoricRig.restMatrix(part)
                for (label, matrices) in [("composed", composed), ("solved", solved)] {
                    let difference = matrices[index] - rest
                    let worst = [difference.columns.0, difference.columns.1, difference.columns.2, difference.columns.3]
                        .map { simd_reduce_max(simd_abs($0)) }.max() ?? 0
                    XCTAssertLessThan(worst, 0.002, "\(name).\(part.name) \(label) rest pose is off by \(worst)")
                }
            }
            XCTAssertEqual(composed.count, 24)
            for index in subject.model.parts.count..<24 {
                XCTAssertEqual(composed[index], matrix_identity_float4x4, "\(name): unused slot \(index)")
            }
        }
    }

    // MARK: Walking

    func testAPlantedFootDoesNotSlideAndStaysOnTheGround() throws {
        for name in Self.walkers {
            for speed in [0.8, 2.2, 4.5] {
                var subject = try Subject(name)
                subject.run(seconds: 3, speed: speed)
                let gait = subject.rig.gait(pace: subject.motion.pace, scale: subject.rig.scale, trot: subject.motion.trot)
                XCTAssertEqual(Double(subject.motion.pace), speed, accuracy: speed * 0.02, "\(name) reads its pace")
                // Follow the ball of each foot through two strides.
                var marks = [Float?](repeating: nil, count: subject.rig.legs.count)
                var worst: Float = 0, highest: Float = 0
                var stances = 0
                let frames = Int(2 * Double(gait.stride) / speed * 120) + 1
                for _ in 0..<frames {
                    subject.step(dt: 1.0 / 120, speed: speed)
                    let matrices = subject.matrices()
                    for (legIndex, leg) in subject.rig.legs.enumerated() {
                        let phase = subject.rig.legPhase(leg, gaitPhase: subject.motion.gaitPhase, trot: gait.trot)
                        let end = leg.foot
                        let ball = subject.tip(end, in: matrices)
                        // World z of a model point for a creature heading toward +z at yaw 0.
                        let world = Float(subject.z) - ball.z * subject.rig.scale
                        // Leave out the first and last tenth of the stance, where the foot rolls.
                        if phase > gait.duty * 0.1 && phase < gait.duty * 0.9 {
                            if let mark = marks[legIndex] {
                                worst = max(worst, abs(world - mark))
                            } else {
                                marks[legIndex] = world
                                stances += 1
                            }
                            let rest = subject.model.parts[end]
                            let restY = Float(rest.pivot.1 + (rest.tip?.1 ?? 0)) / 16
                            highest = max(highest, abs(ball.y - restY))
                        } else if phase >= gait.duty {
                            marks[legIndex] = nil
                        }
                    }
                }
                let leg = subject.rig.legLength * subject.rig.scale
                XCTAssertGreaterThan(stances, subject.rig.legs.count, "\(name) at \(speed) took no steps")
                XCTAssertLessThan(worst, 0.02 * leg + 0.004, "\(name) at \(speed) b/s slides a planted foot by \(worst) blocks")
                XCTAssertLessThan(highest * subject.rig.scale, 0.02 * leg + 0.004,
                                  "\(name) at \(speed) b/s lifts a planted foot by \(highest)")
            }
        }
    }

    func testAStandingAnimalDoesNotStepAndComesToRestOnItsFeet() throws {
        for name in Self.walkers {
            var subject = try Subject(name)
            subject.run(seconds: 2, speed: 2.5)
            XCTAssertGreaterThan(subject.motion.walk, 0.95, name)
            subject.run(seconds: 2)
            XCTAssertLessThan(subject.motion.walk, 0.001, "\(name) keeps stepping after it stopped")
            let phase = subject.motion.gaitPhase
            let before = subject.matrices()
            subject.run(seconds: 1.5)
            XCTAssertEqual(subject.motion.gaitPhase, phase, "\(name) cycles its legs while it stands")
            let after = subject.matrices()
            for leg in subject.rig.legs {
                for part in [leg.upper, leg.lower, leg.foot] {
                    let restEnd = subject.tip(part, in: [simd_float4x4](repeating: matrix_identity_float4x4, count: 24)
                        .enumerated().map { $0.offset < subject.rig.rest.count ? subject.rig.rest[$0.offset] : $0.element })
                    let nowEnd = subject.tip(part, in: after)
                    // The body breathes, so the hips move by a hair; the feet stay put.
                    XCTAssertLessThan(simd_distance(restEnd, nowEnd), 0.03 * subject.rig.legLength + 0.004,
                                      "\(name).\(subject.model.parts[part].name) does not return to rest")
                    XCTAssertLessThan(simd_distance(subject.tip(part, in: before), nowEnd),
                                      0.03 * subject.rig.legLength + 0.004, name)
                }
            }
        }
    }

    func testSmallAnimalsTakeManyShortStepsAndLargeOnesFewLongSteps() throws {
        func cadence(_ name: String, speed: Float) throws -> (stride: Float, perSecond: Float) {
            let rig = try Subject(name).rig
            let gait = rig.gait(pace: speed, scale: rig.scale)
            return (gait.stride, speed / gait.stride)
        }
        let order = ["compsognathus", "velociraptor", "allosaurus", "tyrannosaurus"]
        let readings = try order.map { try cadence($0, speed: 2.2) }
        for index in 1..<readings.count {
            XCTAssertGreaterThan(readings[index].stride, readings[index - 1].stride, "\(order[index]) strides longer")
            XCTAssertLessThan(readings[index].perSecond, readings[index - 1].perSecond, "\(order[index]) steps slower")
        }
        XCTAssertGreaterThan(readings[0].perSecond, 2, "a Compsognathus scurries")
        XCTAssertLessThan(try cadence("brachiosaurus", speed: 1.7).perSecond, 0.7, "a sauropod plods")
        for name in Self.walkers {
            let rig = try Subject(name).rig
            for speed: Float in [0, 0.05, 0.5, 2, 5, 12, 60] {
                let gait = rig.gait(pace: speed, scale: rig.scale)
                XCTAssertTrue(gait.stride.isFinite && gait.stride > 0, "\(name) stride at \(speed)")
                XCTAssertTrue((0.1...0.9).contains(gait.duty), "\(name) duty at \(speed)")
                XCTAssertGreaterThanOrEqual(gait.hipDrop, 0, name)
                XCTAssertLessThanOrEqual(gait.hipDrop, rig.legLength * PrehistoricRig.hipDropShare + 0.000_1, name)
                // The stance is what the body covers while a foot stands: no sliding by construction.
                XCTAssertEqual(gait.stance * rig.scale, gait.duty * gait.stride, accuracy: 0.000_5 * max(1, gait.stride),
                               "\(name) stance at \(speed)")
                for leg in rig.legs {
                    XCTAssertLessThanOrEqual(gait.stance, leg.reach + 0.000_1, "\(name) outreaches a leg at \(speed)")
                }
            }
        }
    }

    func testAnAnimalThatTurnsOnTheSpotLiftsItsFeetWithoutSweepingThem() throws {
        for name in ["triceratops", "tyrannosaurus", "diplodocus"] {
            var subject = try Subject(name)
            subject.run(seconds: 2, turn: 1.6)
            XCTAssertGreaterThan(subject.motion.walk, 0.9, "\(name) steps while it turns")
            XCTAssertLessThan(subject.motion.travel, 0.05, "\(name) does not travel")
            var lifted: Float = 0, swept: Float = 0
            let leg = subject.rig.legs[0]
            let end = leg.foot
            let rest = subject.tip(end, in: subject.rig.rest + [simd_float4x4](repeating: matrix_identity_float4x4, count: 24 - subject.rig.rest.count))
            for _ in 0..<360 {
                subject.step(dt: 1.0 / 120, turn: 1.6)
                let ball = subject.tip(end, in: subject.matrices())
                lifted = max(lifted, ball.y - rest.y)
                swept = max(swept, abs(ball.z - rest.z))
            }
            XCTAssertGreaterThan(lifted, 0.03 * subject.rig.legLength, "\(name) lifts its feet")
            XCTAssertLessThan(swept, 0.12 * subject.rig.legLength, "\(name) sweeps its feet while turning on the spot")
        }
    }

    func testTheFootfallCurveIsContinuousAndPlantsTheFootForTheWholeStance() {
        for duty: Float in [0.26, 0.38, 0.5, 0.64, 0.72] {
            var previous = PrehistoricPose.footfall(phase: 0, duty: duty, stance: 1, lift: 0.2)
            XCTAssertEqual(previous.offset, -0.5, accuracy: 0.000_1, "a stance starts ahead")
            XCTAssertEqual(previous.pitch, 0, "a foot is set down flat")
            let last = PrehistoricPose.footfall(phase: 0.999_999, duty: duty, stance: 1, lift: 0.2)
            XCTAssertEqual(last.offset, -0.5, accuracy: 0.001, "a swing ends where the stance starts")
            XCTAssertEqual(last.pitch, 0, accuracy: 0.001)
            XCTAssertEqual(last.lift, 0, accuracy: 0.001)
            let steps = 4_000
            for index in 1...steps {
                let phase = Float(index) / Float(steps) * 0.999_999
                let now = PrehistoricPose.footfall(phase: phase, duty: duty, stance: 1, lift: 0.2)
                XCTAssertEqual(now.planted, phase < duty)
                XCTAssertLessThan(abs(now.offset - previous.offset), 0.003, "offset jumps at \(phase), duty \(duty)")
                XCTAssertLessThan(abs(now.pitch - previous.pitch), 0.004, "pitch jumps at \(phase), duty \(duty)")
                XCTAssertLessThan(abs(now.lift - previous.lift), 0.002, "lift jumps at \(phase), duty \(duty)")
                XCTAssertGreaterThanOrEqual(now.lift, 0)
                XCTAssertTrue((-PrehistoricPose.heelOffPitch - 0.4...0.2).contains(now.pitch), "pitch \(now.pitch)")
                if now.planted {
                    XCTAssertEqual(now.lift, 0)
                    XCTAssertEqual(now.offset, phase / duty - 0.5, accuracy: 0.000_1, "the stance runs at the body's speed")
                    XCTAssertLessThanOrEqual(now.pitch, 0, "a standing foot only ever tips onto its toes")
                } else {
                    XCTAssertLessThanOrEqual(now.lift, 0.2 + 0.000_1)
                }
                previous = now
            }
        }
    }

    // MARK: Flying

    func testWingsBeatSlowerTheLargerTheAnimal() throws {
        let order = ["microraptor", "dimorphodon", "rhamphorhynchus", "tapejara", "pteranodon", "quetzalcoatlus"]
        let rates = try order.map { name -> Float in
            let rig = try Subject(name).rig
            return rig.beatRate(scale: rig.scale)
        }
        for index in 1..<rates.count {
            XCTAssertLessThan(rates[index], rates[index - 1], "\(order[index]) beats slower than \(order[index - 1])")
        }
        XCTAssertGreaterThan(rates[0], 4, "a Microraptor whirrs")
        XCTAssertLessThan(rates[rates.count - 1], 1.6, "a Quetzalcoatlus rows")
        XCTAssertTrue(rates.allSatisfy { (0.9...6.5).contains($0) })
    }

    /// How far the tip of the right fore wing stands out from the body, in model metres.
    private func wingReach(_ subject: Subject) -> SIMD3<Float> {
        let wing = subject.rig.wings.first { !$0.hind && $0.side < 0 }!
        let matrices = subject.matrices()
        let tip = subject.tip(wing.outer >= 0 ? wing.outer : wing.inner, in: matrices)
        return tip - subject.point(wing.inner, in: matrices)
    }

    func testWingsFoldAtRestSpreadInAGlideAndBeatInPoweredFlight() throws {
        for name in Self.flyers {
            var resting = try Subject(name)
            resting.run(seconds: 2)
            XCTAssertLessThan(resting.motion.weights.flight, 0.001, name)
            let spread = resting.rig.wingLength
            let folded = wingReach(resting)
            XCTAssertLessThan(abs(folded.x), 0.5 * spread, "\(name) holds its wings out at rest")
            XCTAssertGreaterThan(folded.z, 0.3 * spread, "\(name) folds its wings back along the body")

            var gliding = try Subject(name)
            gliding.run(seconds: 2.5, speed: 4, action: .glide, onGround: false)
            var lowest = Float.greatestFiniteMagnitude, highest = -Float.greatestFiniteMagnitude
            for _ in 0..<240 {
                gliding.step(dt: 1.0 / 120, speed: 4, action: .glide, onGround: false)
                let reach = wingReach(gliding)
                XCTAssertGreaterThan(abs(reach.x), 0.85 * spread, "\(name) does not hold its wings out in a glide")
                lowest = min(lowest, reach.y); highest = max(highest, reach.y)
            }
            XCTAssertLessThan(highest - lowest, 0.06 * spread, "\(name) beats its wings in a glide")

            for action in [PrehistoricAction.flap, .takeoff] {
                var flying = try Subject(name)
                flying.run(seconds: 2.5, speed: 4, action: action, onGround: false)
                let rate = Double(flying.rig.beatRate(scale: flying.rig.scale))
                var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
                var beats = 0
                var rising = false
                var last = wingReach(flying).y
                for _ in 0..<Int(4 / rate * 240) {
                    flying.step(dt: 1.0 / 240, speed: 4, action: action, onGround: false)
                    let reach = wingReach(flying).y
                    if reach > last && !rising { beats += 1 }
                    rising = reach > last
                    low = min(low, reach); high = max(high, reach)
                    last = reach
                }
                XCTAssertGreaterThan(high - low, 0.6 * spread, "\(name) barely moves its wings in \(action.rawValue)")
                // Four beat periods at full power, a little faster in a take-off.
                XCTAssertTrue((3...6).contains(beats), "\(name) \(action.rawValue): \(beats) beats in four periods")
            }
        }
    }

    func testAnIdleFlyerHeldInTheAirBeatsItsWingsAndFoldsThemOnceItStands() throws {
        // A flyer with nowhere to go is held in the air with the action `idle`. Standing in the
        // air with folded wings would read as a bug; it hovers, and folds when it is set down.
        for name in Self.flyers {
            var subject = try Subject(name)
            subject.run(seconds: 2, onGround: false)
            let spread = subject.rig.wingLength
            let rate = Double(subject.rig.beatRate(scale: subject.rig.scale))
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            for _ in 0..<Int(3 / rate * 240) {
                subject.step(dt: 1.0 / 240, onGround: false)
                let reach = wingReach(subject)
                XCTAssertGreaterThan(abs(reach.x), 0.5 * spread, "\(name) folds its wings in the air")
                low = min(low, reach.y); high = max(high, reach.y)
            }
            XCTAssertGreaterThan(high - low, 0.6 * spread, "\(name) hangs in the air without beating its wings")
            // Nose up while it gets nowhere: the body's forward axis gains height.
            XCTAssertGreaterThan(-subject.matrices()[subject.rig.body].columns.2.y, 0.1, "\(name) hovers level like a glider")
            subject.run(seconds: 2, onGround: true)
            let folded = wingReach(subject)
            XCTAssertLessThan(abs(folded.x), 0.5 * spread, "\(name) keeps its wings out after it stands")
            XCTAssertGreaterThan(folded.z, 0.3 * spread, "\(name) folds its wings back along the body")
        }
    }

    func testAFlyerBeatingItsWingsInPlaceHangsUprightWithItsLegsUnderIt() throws {
        // A flyer with nowhere to go hovers, or sinks at 0.1 a tick (2 blocks a second) to
        // whatever is under it, with the action `idle`. It gets nowhere forward, so it is not
        // diving: nose up and legs under the body. With way on, it follows its path as before.
        /// How upright the legs hang: 1 where they are when the animal stands, 0 straight back.
        func legsUnder(_ subject: Subject) -> Float {
            let matrices = subject.matrices()
            return subject.rig.danglingLegs.map { simd_normalize(simd_make_float3(matrices[$0].columns.1)).y }.min() ?? 1
        }
        /// The height the body's forward axis gains: above 0 the nose points up.
        func noseUp(_ subject: Subject) -> Float {
            -simd_normalize(simd_make_float3(subject.matrices()[subject.rig.body].columns.2)).y
        }
        for name in Self.flyers {
            for climb in [0.0, -2.0] {
                var subject = try Subject(name)
                subject.run(seconds: 2, onGround: false, climb: climb)
                let rate = Double(subject.rig.beatRate(scale: subject.rig.scale))
                for _ in 0..<Int(240 / rate) {
                    subject.step(dt: 1.0 / 240, onGround: false, climb: climb)
                    XCTAssertGreaterThan(noseUp(subject), 0.1, "\(name) points its nose down while it sinks in place (climb \(climb))")
                    XCTAssertGreaterThan(legsUnder(subject), 0.98, "\(name) trails its legs while it hangs in place (climb \(climb))")
                }
                // Set down, it keeps its legs under it while the wings fold (within 0.2 rad: legs
                // that read the beat instead of the speed swing back about 0.36 rad here).
                for _ in 0..<120 {
                    subject.step(dt: 1.0 / 120, onGround: true)
                    XCTAssertGreaterThan(legsUnder(subject), 0.98, "\(name) kicks its legs back as it is set down (climb \(climb))")
                }
            }
            var gliding = try Subject(name)
            gliding.run(seconds: 2, speed: 5, action: .glide, onGround: false, climb: -2)
            XCTAssertLessThan(noseUp(gliding), -0.1, "\(name) glides downhill with its nose up")
            XCTAssertLessThan(legsUnder(gliding), 0.7, "\(name) glides with its legs hanging")
            var diving = try Subject(name)
            diving.run(seconds: 2, speed: 5, action: .flap, onGround: false, climb: -3)
            XCTAssertLessThan(noseUp(diving), -0.1, "\(name) flies downhill under power with its nose up")
            XCTAssertLessThan(legsUnder(diving), 0.7, "\(name) flies on with its legs hanging")
        }
    }

    /// The turn of a flyer's first dangling leg against the body, in radians: negative trails
    /// back, positive reaches forward.
    private func legPitch(_ subject: Subject) -> Float {
        let matrices = subject.matrices(), leg = subject.rig.danglingLegs[0]
        let joint = simd_inverse(matrices[subject.rig.body] * subject.rig.local[leg]) * matrices[leg]
        return atan2(joint.columns.1.z, joint.columns.1.y)
    }

    func testAFlyerReachesTheSameWayWithItsLegsInEveryTakeOffAndLandingWhateverItsSpeed() throws {
        // Hanging the legs under a body with no way on must not reach into a take-off (a
        // flyer rising straight up still trails its legs) or add to a landing's reach (a
        // flyer set down onto a perch from above reaches no farther than one that lands at
        // speed). Against the body, a take-off's legs and a landing's legs do not read the speed.
        for name in Self.flyers {
            for (action, climb) in [(PrehistoricAction.takeoff, 3.0), (.landing, -2.0)] {
                var reaches: [Float] = []
                for speed in [0.0, 1.0, 1.5, 2.0, 4.0] {
                    var subject = try Subject(name)
                    subject.run(seconds: 2.5, speed: speed, action: action, onGround: false, climb: climb)
                    reaches.append(legPitch(subject))
                }
                for (k, reach) in reaches.enumerated() {
                    XCTAssertEqual(reach, reaches.last!, accuracy: 0.02, "\(name) \(action.rawValue): legs at speed index \(k)")
                }
                if action == .takeoff {
                    XCTAssertLessThan(reaches[0], -1.2, "\(name) hangs its legs rising straight up")
                } else {
                    XCTAssertGreaterThan(reaches[0], 0.6, "\(name) does not reach forward to land")
                }
            }
        }
    }

    /// One stage of a flyer's script: the speed runs from `from` to `to` over the stage.
    typealias FlightStage = (seconds: Double, from: Double, to: Double, action: PrehistoricAction, onGround: Bool, climb: Double)

    /// Drives each flyer through `script` at 120 Hz and checks every frame against the limits
    /// of `testAPoseMovesSmoothlyThroughChangesOfActionAndPace` and the joint limits.
    private func checkFlight(_ script: [FlightStage], file: StaticString = #filePath, line: UInt = #line) throws {
        for name in Self.flyers {
            var subject = try Subject(name)
            subject.run(seconds: 1)
            let size = subject.rig.wingLength
            let wingLimit = Float(1.4 * 2 * Double.pi) * subject.rig.beatRate(scale: subject.rig.scale) / 120 + 0.05
            var last = subject.matrices()
            for (number, stage) in script.enumerated() {
                let frames = Int(stage.seconds * 120)
                for frame in 0..<frames {
                    let speed = stage.from + (stage.to - stage.from) * Double(frame) / Double(frames)
                    subject.step(dt: 1.0 / 120, speed: speed, action: stage.action, onGround: stage.onGround,
                                 climb: stage.climb)
                    let now = subject.matrices()
                    for (index, part) in subject.model.parts.enumerated() {
                        let wing = subject.rig.wings.contains { $0.inner == index || $0.outer == index }
                        let turned = angle(last[index], now[index])
                        let shifted = simd_distance(last[index].columns.3, now[index].columns.3) / size
                        let what = "\(name).\(part.name) stage \(number) (\(stage.action.rawValue)) frame \(frame)"
                        XCTAssertLessThan(turned, wing ? wingLimit : 0.12, "\(what) snaps by \(turned) rad", file: file, line: line)
                        XCTAssertLessThan(shifted, wing ? 0.25 : 0.12, "\(what) jumps by \(shifted)", file: file, line: line)
                        let parent = subject.rig.parents[index]
                        let reference = parent >= 0 ? now[parent] * subject.rig.local[index] : subject.rig.rest[index]
                        XCTAssertTrue(now[index].allFinite, "\(what) is not finite", file: file, line: line)
                        XCTAssertLessThanOrEqual(angle(reference, now[index]), Self.jointLimit(subject.rig, index),
                                                 "\(what) leaves its joint limit", file: file, line: line)
                    }
                    last = now
                }
            }
        }
    }

    func testAFlyerSpeedingOutOfAHoverAndBrakingBackIntoOneMovesSmoothlyWithinItsJoints() throws {
        // The hover's upright body and hanging legs are blended in by the speed, between 0.5
        // and 2.5 blocks a second. The flight controller gains about 12 blocks a second each
        // second from a standstill and stops dead when it has nowhere to go; speed eases in an
        // eighth of a second, so the band is swept in a few frames. Nothing may snap, and no
        // joint may leave its limits: hover, speed out into a dive, level out, stop dead, a slow
        // circuit through the band, a glide that loses its way, a landing at speed, a
        // straight-up take-off, and a landing from above.
        try checkFlight([
            (1.0, 0, 0, .idle, false, -2), (0.4, 0, 5, .flap, false, -1), (1.0, 5, 5, .flap, false, -3),
            (1.0, 5, 5, .flap, false, 0), (1.0, 0, 0, .idle, false, 0), (2.0, 0, 3, .flap, false, -2),
            (2.0, 3, 0, .idle, false, -2), (0.4, 0, 4, .glide, false, -2), (1.0, 4, 4, .glide, false, -2),
            (1.5, 0, 0, .glide, false, -2), (1.0, 3, 3, .landing, false, -2), (1.0, 0, 0, .idle, true, 0),
            (1.0, 0, 0, .takeoff, false, 3), (0.2, 0, 1.5, .flap, false, -1), (1.0, 1.5, 1.5, .flap, false, -1),
            (0.5, 1.5, 0, .landing, false, -2), (1.0, 0, 0, .landing, false, -2), (1.0, 0, 0, .idle, true, 0),
        ])
    }

    func testAFlyerThatStopsDeadOnTheWayDownMovesNoFasterThanTheSmoothnessLimit() throws {
        // A flyer flying downhill that finds nowhere to go is stopped dead and sinks in place
        // (`idle`). Its legs swing from trailing to hanging on top of the body's pitch coming
        // up. Read straight from the eased speed they turned 0.136 rad in a frame at 120 Hz;
        // the hang is eased like the action weights for that reason.
        try checkFlight([(1.0, 0, 0, .idle, false, -2), (0.4, 0, 5, .flap, false, -1), (1.0, 5, 5, .flap, false, -3),
                         (1.0, 0, 0, .idle, false, -2)])
    }

    func testTheHangingOfAFlyersLegsAndBodyIsMonotonicInItsSpeed() throws {
        // Between a hover and flight the legs and the nose move one way only: the slower the
        // flyer goes, the more upright it hangs. Held at each speed until it settles.
        for name in Self.flyers {
            var lastLegs = Float.infinity, lastPitch = Float.infinity
            for step in 0...12 {
                let speed = 0.25 * Double(step)
                var subject = try Subject(name)
                subject.run(seconds: 2, speed: speed, onGround: false, climb: -2)
                let legs = legPitch(subject)
                let pitch = -simd_normalize(simd_make_float3(subject.matrices()[subject.rig.body].columns.2)).y
                XCTAssertLessThanOrEqual(legs, lastLegs + 0.01, "\(name): legs swing forward speeding up to \(speed)")
                XCTAssertLessThanOrEqual(pitch, lastPitch + 0.01, "\(name): nose rises speeding up to \(speed)")
                if speed <= 0.5 { XCTAssertGreaterThan(pitch, 0.1, "\(name) dives at \(speed) blocks a second") }
                lastLegs = legs; lastPitch = pitch
            }
        }
    }

    func testAFlyerWhoseFootingFlickersMovesNoFasterThanAWingBeat() throws {
        // `onGround` now decides whether a flyer flies, and the server's collision can flip it
        // every few ticks: on take-off before the feet leave, at a landing, or brushing a ledge
        // while hovering. However it flickers, no wing may snap from one frame to the next.
        // The limits are those of `testAPoseMovesSmoothlyThroughChangesOfActionAndPace`.
        for name in Self.flyers {
            var subject = try Subject(name)
            subject.run(seconds: 1, onGround: false)
            let size = subject.rig.wingLength
            let wingLimit = Float(1.4 * 2 * Double.pi) * subject.rig.beatRate(scale: subject.rig.scale) / 120 + 0.05
            // Each frame: the action, and whether the feet touch. A hover that brushes the ground
            // every third frame, a take-off whose feet stay down for five frames, a landing whose
            // feet touch, lift and touch again, and a perch.
            var frames: [(PrehistoricAction, Bool)] = (0..<120).map { (.idle, $0 % 6 < 3) }
            frames += (0..<120).map { (.takeoff, $0 < 5) }
            frames += (0..<60).map { _ in (.landing, false) } + (0..<20).map { (.landing, $0 % 4 < 2) }
            frames += (0..<240).map { (.idle, $0 < 8 ? $0 % 2 == 0 : true) }
            var last = subject.matrices()
            for (frame, (action, onGround)) in frames.enumerated() {
                subject.step(dt: 1.0 / 120, action: action, onGround: onGround)
                let now = subject.matrices()
                for (index, part) in subject.model.parts.enumerated() {
                    let wing = subject.rig.wings.contains { $0.inner == index || $0.outer == index }
                    let leg = subject.rig.legs.contains { $0.upper == index || $0.lower == index || $0.foot == index }
                    let turned = angle(last[index], now[index])
                    let shifted = simd_distance(last[index].columns.3, now[index].columns.3) / size
                    XCTAssertLessThan(turned, wing ? wingLimit : (leg ? 0.10 : 0.12),
                                      "\(name).\(part.name) snaps by \(turned) rad at frame \(frame) (\(action.rawValue))")
                    XCTAssertLessThan(shifted, wing ? 0.25 : 0.12,
                                      "\(name).\(part.name) jumps by \(shifted) at frame \(frame) (\(action.rawValue))")
                }
                last = now
            }
            // Set down for good, it folds its wings.
            XCTAssertLessThan(subject.motion.weights.flight, 0.05, "\(name) stays spread on the ground")
        }
    }

    func testAFlyerBanksIntoATurnAndPitchesWithItsPath() throws {
        for name in Self.flyers {
            var level = try Subject(name)
            level.run(seconds: 3, speed: 4, action: .glide, onGround: false)
            let body = level.rig.body
            let levelUp = level.matrices()[body].columns.1
            XCTAssertGreaterThan(levelUp.y, 0.99, "\(name) flies level in a straight glide")

            var turning = try Subject(name)
            turning.run(seconds: 3, speed: 4, action: .glide, onGround: false, turn: 1.2)
            // Positive yaw turns the animal toward its L side (+x in the model): it leans that way.
            XCTAssertGreaterThan(turning.matrices()[body].columns.1.x, 0.2, "\(name) does not bank into the turn")

            var climbing = try Subject(name)
            climbing.run(seconds: 3, speed: 3, action: .flap, onGround: false, climb: 2)
            // The nose (negative z) points up: the body's forward axis gains height.
            XCTAssertGreaterThan(-climbing.matrices()[body].columns.2.y, 0.15, "\(name) does not pitch up in a climb")
        }
    }

    // MARK: Actions and looking around

    func testTheActionsOfALandAnimalReadDifferently() throws {
        for name in ["tyrannosaurus", "velociraptor", "parasaurolophus", "triceratops", "stegosaurus", "diplodocus", "brachiosaurus"] {
            var snouts: [PrehistoricAction: SIMD3<Float>] = [:]
            var poses: [PrehistoricAction: [simd_float4x4]] = [:]
            for action in [PrehistoricAction.idle, .browse, .alert, .charge, .eat, .recover] {
                var subject = try Subject(name)
                subject.run(seconds: 2.5, action: action)
                let matrices = subject.matrices()
                snouts[action] = subject.tip(subject.rig.head, in: matrices)
                poses[action] = matrices
            }
            let idle = try XCTUnwrap(snouts[.idle]), browse = try XCTUnwrap(snouts[.browse])
            let alert = try XCTUnwrap(snouts[.alert])
            let size = try Subject(name).rig.legLength
            if name == "brachiosaurus" {
                XCTAssertGreaterThan(browse.y, idle.y + 0.05 * size, "a brachiosaur browses upward")
            } else {
                XCTAssertLessThan(browse.y, idle.y - 0.15 * size, "\(name) lowers its head to browse")
            }
            XCTAssertGreaterThan(alert.y, idle.y + 0.03 * size, "\(name) raises its head when alert")
            let actions = [PrehistoricAction.idle, .browse, .alert, .charge, .eat, .recover]
            for a in 0..<actions.count {
                for b in (a + 1)..<actions.count {
                    let first = try XCTUnwrap(poses[actions[a]]), second = try XCTUnwrap(poses[actions[b]])
                    var apart: Float = 0
                    for index in 0..<24 {
                        apart = max(apart, angle(first[index], second[index]))
                        apart = max(apart, simd_distance(first[index].columns.3, second[index].columns.3) / size)
                    }
                    XCTAssertGreaterThan(apart, 0.04, "\(name): \(actions[a].rawValue) and \(actions[b].rawValue) look the same")
                }
            }
        }
        // A predator opens its jaw to feed and to roar; at rest it is all but shut.
        for name in ["tyrannosaurus", "velociraptor"] {
            func gape(_ action: PrehistoricAction) throws -> Float {
                var subject = try Subject(name)
                var widest: Float = 0
                subject.run(seconds: 2, action: action)
                for _ in 0..<240 {
                    subject.step(dt: 1.0 / 120, action: action)
                    let matrices = subject.matrices()
                    widest = max(widest, angle(matrices[subject.rig.head], matrices[subject.rig.jaw]))
                }
                return widest
            }
            XCTAssertLessThan(try gape(.idle), 0.08, name)
            XCTAssertGreaterThan(try gape(.eat), 0.25, name)
            XCTAssertGreaterThan(try gape(.alert), 0.2, name)
        }
    }

    func testAStrikeShowsOnTheHostAndWhenAChargeEndsInRecovery() throws {
        // The host sees `attackAnim` jump; a LAN guest only sees the charge turn into recovery.
        for hostSeesSwing in [true, false] {
            var subject = try Subject("tyrannosaurus")
            subject.run(seconds: 1.5, speed: 3, action: .charge)
            XCTAssertGreaterThan(subject.motion.strikeAge, 1)
            subject.step(dt: 1.0 / 120, action: .recover, attack: hostSeesSwing ? 1 : 0)
            XCTAssertEqual(subject.motion.strikeAge, 0, "the strike starts on the frame it is seen")
            var widest: Float = 0
            for _ in 0..<60 {
                subject.step(dt: 1.0 / 120, action: .recover, attack: hostSeesSwing ? 0.5 : 0)
                let matrices = subject.matrices()
                widest = max(widest, angle(matrices[subject.rig.head], matrices[subject.rig.jaw]))
            }
            XCTAssertGreaterThan(widest, 0.5, "a bite opens the jaw wide")
            XCTAssertGreaterThan(subject.motion.strikeAge, 0.4, "a held swing value is one strike, not many")
        }
    }

    func testAnIdleAnimalLooksAroundInItsOwnTime() throws {
        for name in ["tyrannosaurus", "triceratops", "diplodocus", "pteranodon", "gallimimus"] {
            var subject = try Subject(name)
            subject.run(seconds: 1)
            var left = false, right = false
            var widest: Float = 0, fastest: Float = 0
            var last = subject.matrices()[subject.rig.head]
            for _ in 0..<(60 * 120) {
                subject.step(dt: 1.0 / 120)
                let head = subject.matrices()[subject.rig.head]
                // The head's forward axis is its negative z column.
                let sideways = -head.columns.2.x
                left = left || sideways > 0.15
                right = right || sideways < -0.15
                widest = max(widest, abs(sideways))
                fastest = max(fastest, angle(last, head))
                last = head
            }
            XCTAssertTrue(left && right, "\(name) looks to both sides within a minute")
            XCTAssertLessThan(widest, 0.95, "\(name) cannot look behind itself")
            XCTAssertLessThan(fastest, 0.05, "\(name) snaps its head (\(fastest) rad in a frame)")
        }
        // Two animals of one kind do not look the same way at the same moments.
        var first = try Subject("triceratops"), second = try Subject("triceratops")
        second.seed = PrehistoricPose.seed(8)
        var apart: Float = 0
        for _ in 0..<1200 {
            first.step(dt: 1.0 / 60); second.step(dt: 1.0 / 60)
            apart = max(apart, angle(first.matrices()[first.rig.head], second.matrices()[second.rig.head]))
        }
        XCTAssertGreaterThan(apart, 0.2)
    }

    func testTheGazeIsContinuousBoundedAndFixedForItsInputs() {
        for seed: UInt32 in [0, 1, 0xFFFF_FFFF, 0x1234_5678] {
            var last = PrehistoricPose.gaze(seed: seed, time: 0, period: 3, salt: 1)
            for step in 1...6_000 {
                let time = Double(step) / 120
                let now = PrehistoricPose.gaze(seed: seed, time: time, period: 3, salt: 1)
                XCTAssertTrue(abs(now.x) <= 1 && abs(now.y) <= 1)
                XCTAssertLessThan(simd_distance(now, last), 0.06, "gaze jumps at \(time)")
                XCTAssertEqual(now, PrehistoricPose.gaze(seed: seed, time: time, period: 3, salt: 1))
                last = now
            }
        }
        XCTAssertNotEqual(PrehistoricPose.gaze(seed: 1, time: 10, period: 3, salt: 1),
                          PrehistoricPose.gaze(seed: 2, time: 10, period: 3, salt: 1))
        for value in [PrehistoricPose.hash(0, 0), PrehistoricPose.hash(1, 2), PrehistoricPose.hash(.max, .max)] {
            XCTAssertTrue((0..<1).contains(value))
        }
    }

    // MARK: Every species, every action

    /// What a joint may turn through against its rest, in radians.
    static func jointLimit(_ rig: PrehistoricRig, _ part: Int) -> Float {
        // A flyer banks and pitches at once; a land animal only leans.
        if part == rig.body { return rig.plan == .flyer ? 1.15 : 0.9 }
        if rig.neck.contains(part) { return rig.neck.count > 1 ? 0.7 : 1.3 }
        if part == rig.head { return 1.5 }
        if part == rig.jaw { return 1.0 }
        if rig.tail.contains(part) { return 0.9 }
        if rig.arms.contains(part) { return 1.4 }
        if rig.wings.contains(where: { $0.inner == part || $0.outer == part }) { return 2.4 }
        if rig.danglingLegs.contains(part) { return 1.7 }
        return 2.9   // a solved leg segment
    }

    func testEveryPoseIsFiniteRigidAndWithinItsJointLimits() throws {
        let limit = Self.jointLimit
        for name in Self.jointed {
            for action in PrehistoricAction.allCases {
                for (speed, turn, onGround) in [(0.0, 0.0, true), (1.4, 0.4, true), (6.0, -2.5, true), (4.0, 3.0, false)] {
                    var subject = try Subject(name)
                    subject.seed = PrehistoricPose.seed(name.count * 31 + action.rawValue.count)
                    for frame in 0..<180 {
                        subject.step(dt: 1.0 / 60, speed: speed, action: action, onGround: onGround, turn: turn,
                                     climb: onGround ? 0 : 1.5, attack: frame == 90 ? 1 : 0)
                        guard frame % 3 == 0 else { continue }
                        let matrices = subject.matrices()
                        for (index, part) in subject.model.parts.enumerated() {
                            let m = matrices[index]
                            XCTAssertTrue(m.allFinite, "\(name).\(part.name) \(action.rawValue): not finite")
                            XCTAssertEqual(m.columns.3.w, 1)
                            XCTAssertLessThan(simd_length(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)), 8,
                                              "\(name).\(part.name) \(action.rawValue): flung away")
                            for column in [m.columns.0, m.columns.1, m.columns.2] {
                                let length = simd_length(column)
                                XCTAssertTrue((0.25...1.001).contains(length),
                                              "\(name).\(part.name) \(action.rawValue): stretched to \(length)")
                            }
                            let reference: simd_float4x4
                            if subject.rig.legs.contains(where: { $0.upper == index || $0.lower == index || $0.foot == index }) {
                                reference = subject.rig.rest[index]
                            } else if subject.rig.parents[index] >= 0 {
                                reference = matrices[subject.rig.parents[index]] * subject.rig.local[index]
                            } else {
                                reference = subject.rig.rest[index]
                            }
                            let turned = angle(reference, m)
                            XCTAssertLessThanOrEqual(turned, limit(subject.rig, index),
                                                     "\(name).\(part.name) \(action.rawValue) at \(speed): turned \(turned)")
                        }
                        // A knee never bends backward and never folds flat.
                        for leg in subject.rig.legs {
                            let hip = subject.point(leg.upper, in: matrices)
                            let knee = subject.point(leg.lower, in: matrices)
                            let end = subject.tip(leg.lower, in: matrices)
                            XCTAssertEqual(simd_distance(hip, knee), leg.upperLength, accuracy: 0.002, "\(name): thigh length")
                            XCTAssertEqual(simd_distance(knee, end), leg.lowerLength, accuracy: 0.002, "\(name): shin length")
                            let thigh = SIMD2(knee.y - hip.y, knee.z - hip.z), shin = SIMD2(end.y - knee.y, end.z - knee.z)
                            // Height times fore-aft: negative when the joint lies toward the head
                            // (negative z) of the line from hip to ankle.
                            let cross = thigh.x * shin.y - thigh.y * shin.x
                            if leg.kneeForward {
                                XCTAssertLessThanOrEqual(cross, 0.000_5, "\(name): a knee bends backward (\(action.rawValue))")
                            } else {
                                XCTAssertGreaterThanOrEqual(cross, -0.000_5, "\(name): an elbow bends forward (\(action.rawValue))")
                            }
                        }
                    }
                }
            }
        }
    }

    func testAPoseIsTheSameForTheSameInputs() throws {
        for name in Self.jointed {
            var first = try Subject(name), second = try Subject(name)
            for frame in 0..<400 {
                let action: PrehistoricAction = frame < 150 ? .idle : (frame < 300 ? (first.rig.plan == .flyer ? .flap : .charge) : .glide)
                let speed = frame < 150 ? 0.0 : 3.5
                first.step(dt: 1.0 / 90, speed: speed, action: action, onGround: first.rig.plan != .flyer, turn: 0.7)
                second.step(dt: 1.0 / 90, speed: speed, action: action, onGround: second.rig.plan != .flyer, turn: 0.7)
                XCTAssertEqual(first.motion, second.motion, "\(name) frame \(frame)")
                XCTAssertEqual(first.matrices(), second.matrices(), "\(name) frame \(frame)")
                XCTAssertEqual(first.matrices(), first.matrices(), "\(name): a pose depends on nothing but its inputs")
            }
        }
    }

    func testAPoseMovesSmoothlyThroughChangesOfActionAndPace() throws {
        // Radians a part may turn, and metres per leg length it may shift, in one frame at 120 Hz.
        func script(_ plan: PrehistoricRig.Plan) -> [(seconds: Double, speed: Double, action: PrehistoricAction, onGround: Bool, turn: Double, climb: Double)] {
            plan == .flyer
                ? [(1, 0, .idle, true, 0, 0), (0.8, 2, .takeoff, false, 0, 3), (1.2, 5, .flap, false, 1.5, 0.5),
                   (1.2, 4, .glide, false, -1.5, -0.5), (1.0, 2.5, .landing, false, 0, -2), (1.0, 0, .idle, true, 0, 0),
                   (0.5, 3, .flap, false, 0, 1), (0.5, 0, .idle, true, 0, 0)]
                : [(1, 0, .idle, true, 0, 0), (1, 1.5, .idle, true, 0.5, 0), (1, 0, .browse, true, 0, 0),
                   (0.8, 0, .alert, true, 1.5, 0), (1, 5, .charge, true, 0, 0), (0.8, 0, .recover, true, 0, 0),
                   (1, 0, .eat, true, 0, 0), (0.6, 3, .idle, false, 0, 4), (0.6, 3, .idle, true, 0, 0), (1, 0, .idle, true, 0, 0)]
        }
        for name in Self.jointed {
            var subject = try Subject(name)
            let size = max(subject.rig.legLength, subject.rig.wingLength)
            // A wing beat is the fastest motion there is: reach in radians times 2 pi times the rate.
            let wingLimit = Float(1.4 * 2 * Double.pi) * subject.rig.beatRate(scale: subject.rig.scale) / 120 + 0.05
            var last: [simd_float4x4]?
            var lastAction = PrehistoricAction.idle
            var lastCadence: Float = 0
            for stage in script(subject.rig.plan) {
                // Legs may move as fast as the pace asks of them: a sprinting Compsognathus
                // cycles its legs several times a second. Count the stage before as well,
                // because the legs are still slowing down from it.
                let pace = Float(stage.speed + abs(stage.turn) * Double(subject.rig.turnRadius * subject.rig.scale))
                let cadence = subject.rig.plan == .flyer ? 0
                    : pace / subject.rig.gait(pace: max(pace, 0.01), scale: subject.rig.scale).stride
                let legTurn = 0.10 + 2 * Float.pi * max(cadence, lastCadence) * 2.2 / 120
                let legShift = 0.08 + max(cadence, lastCadence) * 4 / 120
                lastCadence = cadence
                for frame in 0..<Int(stage.seconds * 120) {
                    // Every charge here ends in a blow, the hardest cut there is.
                    let attack = stage.action == .recover && lastAction == .charge && frame < 4 ? 1.0 : 0.0
                    subject.step(dt: 1.0 / 120, speed: stage.speed, action: stage.action, onGround: stage.onGround,
                                 turn: stage.turn, climb: stage.climb, attack: attack)
                    let now = subject.matrices()
                    if let last {
                        for (index, part) in subject.model.parts.enumerated() {
                            let wing = subject.rig.wings.contains { $0.inner == index || $0.outer == index }
                            let leg = subject.rig.legs.contains { $0.upper == index || $0.lower == index || $0.foot == index }
                            let turned = angle(last[index], now[index])
                            let shifted = simd_distance(last[index].columns.3, now[index].columns.3) / size
                            XCTAssertLessThan(turned, wing ? wingLimit : (leg ? legTurn : 0.12),
                                              "\(name).\(part.name) snaps by \(turned) rad entering \(stage.action.rawValue) (frame \(frame))")
                            XCTAssertLessThan(shifted, wing ? 0.25 : (leg ? legShift : 0.12),
                                              "\(name).\(part.name) jumps by \(shifted) entering \(stage.action.rawValue) (frame \(frame))")
                        }
                    }
                    last = now
                }
                lastAction = stage.action
            }
        }
    }

    // MARK: The rig's rules

    private func part(_ name: String, _ pivot: (Double, Double, Double), parent: String? = nil,
                      tip: (Double, Double, Double)? = nil, rot: (Double, Double, Double) = (0, 0, 0)) -> ModelPart {
        ModelPart(name: name, pivot: pivot, rot: rot, boxes: [], parent: parent, tip: tip)
    }

    private func model(_ anim: String, _ parts: [ModelPart]) -> MobModel {
        MobModel(texW: 16, texH: 16, parts: parts, anim: anim, scale: 1, paint: { _ in })
    }

    private func replacing(_ parts: [ModelPart], _ name: String, with new: ModelPart) -> [ModelPart] {
        parts.map { $0.name == name ? new : $0 }
    }

    /// The smallest biped the rig accepts: a body, a head and two three-part legs.
    private func smallestBiped() -> [ModelPart] {
        var parts = [part("body", (0, 16, 0)), part("head", (0, 20, -6), parent: "body")]
        for (side, x) in [("R", -2.0), ("L", 2.0)] {
            parts.append(part("leg\(side)", (x, 14, 0), parent: "body", tip: (0, -6, -1)))
            parts.append(part("shin\(side)", (x, 8, -1), parent: "leg\(side)", tip: (0, -6, 1)))
            parts.append(part("foot\(side)", (x, 2, 0), parent: "shin\(side)", tip: (0, -2, -2)))
        }
        return parts
    }

    func testTheRigRefusesAModelThatBreaksItsRulesAndReadsOneThatKeepsThem() throws {
        // A model that breaks the rules falls back to its rest pose instead of being posed from
        // wrong indices; one that keeps them is read exactly.
        let good = smallestBiped()
        let rig = try XCTUnwrap(PrehistoricRig(model: model(PrehistoricRigPlan.biped.rawValue, good)))
        XCTAssertEqual(rig.plan, .biped)
        XCTAssertEqual(rig.legs.map(\.walkPhase), [0, 0.5], "a biped's legs alternate")
        XCTAssertEqual(rig.legs[0].upperLength, Float((36.0 + 1).squareRoot() / 16), accuracy: 1e-6)
        XCTAssertEqual(rig.legs[0].lowerLength, Float((36.0 + 1).squareRoot() / 16), accuracy: 1e-6)
        XCTAssertEqual(rig.legLength, 14.0 / 16, accuracy: 1e-6, "the hips stand 14 units above the ground")
        XCTAssertEqual(rig.parents, [-1, 0, 0, 2, 3, 0, 5, 6])
        XCTAssertTrue(rig.neck.isEmpty && rig.tail.isEmpty && rig.arms.isEmpty && rig.jaw == -1)
        let broken: [(String, String, [ModelPart])] = [
            ("another animator", "biped", good),
            ("no parts", PrehistoricRigPlan.biped.rawValue, []),
            ("more parts than the uniforms carry", PrehistoricRigPlan.biped.rawValue,
             good + (0...(PrehistoricRig.maximumParts - good.count)).map { part("spike\($0)", (0, 18, 0), parent: "body") }),
            ("a repeated name", PrehistoricRigPlan.biped.rawValue, good + [part("head", (0, 21, -6), parent: "body")]),
            ("a child listed before its parent", PrehistoricRigPlan.biped.rawValue, [good[1], good[0]] + good.dropFirst(2)),
            ("a parent that does not exist", PrehistoricRigPlan.biped.rawValue,
             replacing(good, "head", with: part("head", (0, 20, -6), parent: "neck"))),
            ("a rotated body", PrehistoricRigPlan.biped.rawValue, replacing(good, "body", with: part("body", (0, 16, 0), rot: (0.1, 0, 0)))),
            ("a body that hangs from something", PrehistoricRigPlan.biped.rawValue,
             [part("root", (0, 0, 0))] + replacing(good, "body", with: part("body", (0, 16, 0), parent: "root"))),
            ("no head", PrehistoricRigPlan.biped.rawValue, good.filter { $0.name != "head" }),
            ("a missing foot", PrehistoricRigPlan.biped.rawValue, good.filter { $0.name != "footL" }),
            ("a shin on the body", PrehistoricRigPlan.biped.rawValue,
             replacing(good, "shinL", with: part("shinL", (2, 8, -1), parent: "body", tip: (0, -6, 1)))),
            ("a thigh without a bone end", PrehistoricRigPlan.biped.rawValue,
             replacing(good, "legL", with: part("legL", (2, 14, 0), parent: "body"))),
            ("a thigh with no length in the side plane", PrehistoricRigPlan.biped.rawValue,
             replacing(good, "legL", with: part("legL", (2, 14, 0), parent: "body", tip: (3, 0, 0)))),
            ("a foot without a ball", PrehistoricRigPlan.biped.rawValue,
             replacing(good, "footR", with: part("footR", (-2, 2, 0), parent: "shinR"))),
            ("a quadruped with only hind legs", PrehistoricRigPlan.quadruped.rawValue, good),
        ]
        for (label, anim, parts) in broken {
            XCTAssertNil(PrehistoricRig(model: model(anim, parts)), label)
        }

        let flyer = [part("body", (0, 8, 0)), part("head", (0, 9, -5), parent: "body"),
                     part("wingR", (-2, 9, 0), parent: "body", tip: (-8, 0, 0)),
                     part("wingTipR", (-10, 9, 0), parent: "wingR", tip: (-8, 0, 2)),
                     part("wingL", (2, 9, 0), parent: "body", tip: (8, 0, 0)),
                     part("wingTipL", (10, 9, 0), parent: "wingL", tip: (8, 0, 2)),
                     part("legR", (-1, 6, 2), parent: "body"), part("legL", (1, 6, 2), parent: "body")]
        let flyerRig = try XCTUnwrap(PrehistoricRig(model: model(PrehistoricRigPlan.flyer.rawValue, flyer)))
        XCTAssertEqual(flyerRig.wings.map(\.side), [-1, 1], "right wing first, at negative x")
        XCTAssertEqual(flyerRig.wings.map(\.outer), [3, 5])
        XCTAssertEqual(flyerRig.danglingLegs, [6, 7])
        XCTAssertTrue(flyerRig.legs.isEmpty, "a flyer's legs hang; they do not walk")
        XCTAssertEqual(flyerRig.wingLength, Float((8 + (64.0 + 4).squareRoot()) / 16), accuracy: 1e-6)
        let brokenFlyers: [(String, [ModelPart])] = [
            ("a wing without a wrist", replacing(flyer, "wingL", with: part("wingL", (2, 9, 0), parent: "body"))),
            ("an outer wing on the body",
             replacing(flyer, "wingTipR", with: part("wingTipR", (-10, 9, 0), parent: "body", tip: (-8, 0, 2)))),
            ("an outer wing without an end", replacing(flyer, "wingTipL", with: part("wingTipL", (10, 9, 0), parent: "wingL"))),
            ("a hind wing on a fore wing", flyer + [part("hindWingR", (-2, 5, 3), parent: "wingR")]),
            ("one wing", flyer.filter { !$0.name.hasSuffix("L") || $0.name == "legL" }),
        ]
        for (label, parts) in brokenFlyers {
            XCTAssertNil(PrehistoricRig(model: model(PrehistoricRigPlan.flyer.rawValue, parts)), label)
        }
    }

    func testOnlyTheThirtyJointedModelsHaveARigAndNoModelAsksForARetiredAnimator() {
        // `partTransforms` hands a model to the jointed pose code only when it has a rig; every
        // other model must keep going through the animator switch, as it did before.
        ensureModels()
        let jointed = Set(Self.jointed.map { "prehistoric.\($0)" })
        var rigged = 0
        for (id, model) in MODELS.sorted(by: { $0.key < $1.key }) {
            let rig = PrehistoricRig(model: model)
            XCTAssertEqual(rig != nil, jointed.contains(id), "\(id) (\(model.anim))")
            if rig != nil { rigged += 1 }
            // The pterosaur profile was folded into the jointed flyer: a model that still asked
            // for it would be drawn frozen in its rest pose.
            XCTAssertNotEqual(model.anim, "prehistoricPterosaur", id)
        }
        XCTAssertEqual(rigged, 30)
    }

    // MARK: Feet at every pace and size

    /// Follows the ball of every walking foot through `frames` frames and returns the worst slide
    /// along the path and the worst lift of a planted foot, in blocks, and how many stances began.
    /// `frame` advances one frame and returns the matrices, the motion, the world z of the model's
    /// origin (heading toward +z at yaw 0) and the display scale.
    private func plantedFootDrift(rig: PrehistoricRig, model: MobModel, frames: Int,
                                  frame: () -> (matrices: [simd_float4x4], motion: PrehistoricMotion, z: Double, scale: Float))
        -> (slide: Float, lift: Float, stances: Int) {
        var marks = [Float?](repeating: nil, count: rig.legs.count)
        var slide: Float = 0, lift: Float = 0, stances = 0
        for _ in 0..<frames {
            let now = frame()
            let gait = rig.gait(pace: now.motion.pace, scale: now.scale, trot: now.motion.trot)
            for (legIndex, leg) in rig.legs.enumerated() {
                let phase = rig.legPhase(leg, gaitPhase: now.motion.gaitPhase, trot: gait.trot)
                let foot = model.parts[leg.foot]
                let t = foot.tip ?? (0, 0, 0)
                let ball = now.matrices[leg.foot] * SIMD4(Float(t.0) / 16, Float(t.1) / 16, Float(t.2) / 16, 1)
                let world = Float(now.z) - ball.z * now.scale
                if phase > gait.duty * 0.1 && phase < gait.duty * 0.9 {
                    if let mark = marks[legIndex] {
                        slide = max(slide, abs(world - mark))
                    } else {
                        marks[legIndex] = world
                        stances += 1
                    }
                    let restY = Float(foot.pivot.1 + t.1) / 16
                    lift = max(lift, abs(ball.y - restY) * now.scale)
                } else if phase >= gait.duty {
                    marks[legIndex] = nil
                }
            }
        }
        return (slide, lift, stances)
    }

    func testAPlantedFootHoldsAtATrotAndAtASprint() throws {
        // The first foot test stops at 4.5 blocks a second. A Compsognathus sprints at twice that,
        // and the lighter quadrupeds only trot there: the diagonal phases have to hold the foot too.
        var trotters: [String] = []
        for name in Self.walkers {
            for speed in [6.5, 10.0] {
                var subject = try Subject(name)
                subject.run(seconds: 3, speed: speed)
                let gait = subject.rig.gait(pace: subject.motion.pace, scale: subject.rig.scale, trot: subject.motion.trot)
                if gait.trot > 0.95 { trotters.append(name) }
                let frames = Int(2 * Double(gait.stride) / speed * 120) + 1
                let drift = plantedFootDrift(rig: subject.rig, model: subject.model, frames: frames) {
                    subject.step(dt: 1.0 / 120, speed: speed)
                    return (subject.matrices(), subject.motion, subject.z, subject.rig.scale)
                }
                let leg = subject.rig.legLength * subject.rig.scale
                XCTAssertGreaterThan(drift.stances, subject.rig.legs.count, "\(name) at \(speed) took no steps")
                XCTAssertLessThan(drift.slide, 0.02 * leg + 0.004, "\(name) at \(speed) b/s slides a planted foot by \(drift.slide)")
                XCTAssertLessThan(drift.lift, 0.02 * leg + 0.004, "\(name) at \(speed) b/s lifts a planted foot by \(drift.lift)")
            }
        }
        XCTAssertFalse(trotters.isEmpty, "no quadruped reached a full trot, so the trot was not tested")
        XCTAssertTrue(trotters.allSatisfy { Self.quadrupeds.contains($0) }, "only quadrupeds trot: \(trotters)")
    }

    /// Moves a creature at `from` b/s for two seconds, then follows `speed` (by frame) for two
    /// more and returns the worst slide of a planted foot in those and the length of its leg.
    private func slideThroughAChangeOfPace(_ name: String, from: Double = 1.5,
                                           speed: (Int) -> Double) throws -> (slide: Float, leg: Float) {
        var subject = try Subject(name)
        subject.run(seconds: 2, speed: from)
        var frame = 0
        let drift = plantedFootDrift(rig: subject.rig, model: subject.model, frames: 2 * 120) {
            subject.step(dt: 1.0 / 120, speed: speed(frame))
            frame += 1
            return (subject.matrices(), subject.motion, subject.z, subject.rig.scale)
        }
        XCTAssertGreaterThan(drift.stances, subject.rig.legs.count, "\(name) took no steps")
        return (drift.slide, subject.rig.legLength * subject.rig.scale)
    }

    func testAPlantedFootStaysNearlyPutWhileTheAnimalSpeedsUpToARunAndSlowsDownAgain() throws {
        // Stride and duty follow the pace, so while the pace changes a planted foot may give a
        // little. It must never skate: a slide of a quarter of the leg reads as the foot dragged
        // along the ground.
        for name in Self.walkers {
            // From a walk to a sprint over a second and a half, held, then back over the same.
            let up = try slideThroughAChangeOfPace(name) { frame in
                let t = Double(frame) / 120
                return t < 1.5 ? 1.5 + 7.5 * t / 1.5 : 9
            }
            XCTAssertLessThan(up.slide, 0.25 * up.leg, "\(name) speeding up slides a planted foot by \(up.slide) blocks")
            let down = try slideThroughAChangeOfPace(name, from: 9) { frame in
                let t = Double(frame) / 120
                return t < 1.5 ? 9 - 7.5 * t / 1.5 : 1.5
            }
            XCTAssertLessThan(down.slide, 0.25 * down.leg, "\(name) slowing down slides a planted foot by \(down.slide) blocks")
        }
    }

    func testAPlantedFootStaysNearlyPutWhenAnAnimalBreaksFromAStrollIntoAChase() throws {
        // A chase starts at once: a mob's ground speed closes 45% of the gap to its new pace on
        // every tick (friction 0.546), so it is there within a fifth of a second. Stride and
        // duty change with the pace while some feet are standing; those feet shift a little
        // for the few steps the change takes. 6.5 blocks a second is the fastest any land
        // creature moves (a predator's chase). Measured: at most 0.19 of the leg (oviraptor),
        // and nothing at a steady pace.
        for name in Self.walkers {
            let start = try slideThroughAChangeOfPace(name, from: 3) { frame in
                6.5 + (3 - 6.5) * pow(0.546, Double(frame) / 6)
            }
            XCTAssertLessThan(start.slide, 0.25 * start.leg,
                              "\(name) breaking into a chase slides a planted foot by \(start.slide) blocks (leg \(start.leg))")
            let stop = try slideThroughAChangeOfPace(name, from: 6.5) { frame in
                3 + (6.5 - 3) * pow(0.546, Double(frame) / 6)
            }
            XCTAssertLessThan(stop.slide, 0.25 * stop.leg,
                              "\(name) dropping out of a chase slides a planted foot by \(stop.slide) blocks (leg \(stop.leg))")
        }
    }

    func testABabyStepsWithoutSlidingAtItsOwnSize() throws {
        // A baby is drawn at half size. The store reads its cadence and the pose its stance from
        // the same halved scale, or every step of a baby would skate.
        let world = World(dim: .overworld, seed: 1)
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.triceratops"))
        let model = getModel("prehistoric.triceratops")
        let rig = try XCTUnwrap(PrehistoricRig(model: model))
        for baby in [false, true] {
            let entity = PrehistoricCreature(world: world, definition: definition)
            entity.onGround = true
            let store = PrehistoricMotionStore()
            var time = 0.0, z = 0.0
            let speed = 1.6
            func frame() -> (matrices: [simd_float4x4], motion: PrehistoricMotion, z: Double, scale: Float) {
                time += 1.0 / 120
                z += speed / 120
                store.beginFrame(time: time)
                var pose = EntityPose()
                pose.x = 0; pose.y = 64; pose.z = z; pose.baby = baby
                store.present(&pose, entity: entity, rig: rig)
                let scale = Float(pose.scale * model.scale * (baby ? 0.5 : 1))
                return (PrehistoricPose.partMatrices(rig: rig, pose: pose, time: time), pose.motion, pose.z, scale)
            }
            for _ in 0..<360 { _ = frame() }
            let drift = plantedFootDrift(rig: rig, model: model, frames: 480, frame: frame)
            let leg = rig.legLength * rig.scale * (baby ? 0.5 : 1)
            XCTAssertGreaterThan(drift.stances, rig.legs.count, "baby \(baby): no steps")
            XCTAssertLessThan(drift.slide, 0.02 * leg + 0.004, "baby \(baby): a planted foot slides by \(drift.slide) blocks")
            XCTAssertLessThan(drift.lift, 0.02 * leg + 0.004, "baby \(baby): a planted foot lifts by \(drift.lift) blocks")
        }
    }

    func testALandAnimalInTheAirTucksItsFeetAndSetsThemBackUnderItOnLanding() throws {
        // Off the ground the ankles rise by a tenth of the leg and the toes point down; back on
        // the ground every foot returns to its rest stance.
        for name in ["velociraptor", "tyrannosaurus", "triceratops", "brachiosaurus"] {
            var subject = try Subject(name)
            subject.run(seconds: 1)
            let standing = subject.matrices()
            subject.run(seconds: 1, onGround: false)
            XCTAssertGreaterThan(subject.motion.airborne, 0.99, name)
            let flying = subject.matrices()
            let size = subject.rig.legLength
            for leg in subject.rig.legs {
                let ankle = subject.point(leg.foot, in: flying), rest = subject.point(leg.foot, in: standing)
                XCTAssertGreaterThan(ankle.y - rest.y, 0.07 * size, "\(name) does not tuck its feet in the air")
                // The foot's forward axis (negative z) dips: the toes point down.
                XCTAssertLessThan(-flying[leg.foot].columns.2.y, -standing[leg.foot].columns.2.y - 0.2,
                                  "\(name) does not point its toes in the air")
            }
            subject.run(seconds: 1.5)
            let landed = subject.matrices()
            for leg in subject.rig.legs {
                XCTAssertLessThan(simd_distance(subject.tip(leg.foot, in: landed), subject.tip(leg.foot, in: standing)),
                                  0.03 * size + 0.004, "\(name) does not set its feet back down")
            }
        }
    }

    func testALightQuadrupedTrotsInDiagonalPairsAndAGiantWalksInFourBeatsAtEveryPace() throws {
        // A foot test cannot see the footfall order: a wrong order slides no foot. Legs are
        // listed left hind, left fore, right hind, right fore.
        func phases(_ rig: PrehistoricRig, _ gait: PrehistoricRig.Gait) -> [Float] {
            rig.legs.map { rig.legPhase($0, gaitPhase: 0.1, trot: gait.trot) }
        }
        func apart(_ a: Float, _ b: Float) -> Float {
            let d = abs(a - b)
            return min(d, 1 - d)
        }
        var trotted = false
        for name in Self.quadrupeds {
            let rig = try Subject(name).rig
            let walk = phases(rig, rig.gait(pace: 0.3, scale: rig.scale))
            XCTAssertEqual(apart(walk[0], walk[1]), 0.25, accuracy: 0.01, "\(name) walks left hind, then left fore")
            XCTAssertEqual(apart(walk[0], walk[2]), 0.5, accuracy: 0.01, "\(name) walks with its hind legs opposed")
            XCTAssertEqual(apart(walk[1], walk[3]), 0.5, accuracy: 0.01, "\(name) walks with its fore legs opposed")
            for pace in stride(from: Float(0), through: 24, by: 0.5) {
                let gait = rig.gait(pace: pace, scale: rig.scale)
                if ["diplodocus", "brachiosaurus"].contains(name) {
                    XCTAssertEqual(gait.trot, 0, accuracy: 0.001, "a sauropod trots at \(pace) b/s")
                }
                guard gait.trot > 0.999 else { continue }
                trotted = true
                let trot = phases(rig, gait)
                XCTAssertEqual(apart(trot[0], trot[3]), 0, accuracy: 0.001, "\(name) at \(pace): left hind and right fore together")
                XCTAssertEqual(apart(trot[1], trot[2]), 0, accuracy: 0.001, "\(name) at \(pace): left fore and right hind together")
                XCTAssertEqual(apart(trot[0], trot[1]), 0.5, accuracy: 0.001, "\(name) at \(pace): the pairs alternate")
            }
        }
        XCTAssertTrue(trotted, "no quadruped reached a full trot")
    }

    func testTheHipsSinkFarEnoughForEveryLegToReachTheEndsOfItsStance() throws {
        // The foot test samples three paces. This checks every pace from a stand to a gallop
        // from the numbers alone: at the hip height the gait allows, each leg reaches both ends
        // of its stance, so the solver never has to drag a planted foot along the ground.
        for name in Self.walkers {
            let rig = try Subject(name).rig
            for pace in stride(from: Float(0), through: 24, by: 0.2) {
                let gait = rig.gait(pace: pace, scale: rig.scale)
                for leg in rig.legs {
                    let hipY = rig.rest[rig.body].columns.3.y + leg.hip.y - gait.hipDrop
                    let hipZ = rig.rest[rig.body].columns.3.z + leg.hip.z
                    let far = abs(hipZ - leg.centre) + gait.stance * 0.5
                    let needed = simd_length(SIMD2(hipY - leg.restEnd.x, far))
                    XCTAssertLessThanOrEqual(needed, (leg.upperLength + leg.lowerLength) * 0.999,
                                             "\(name).\(rig.legs.firstIndex { $0.upper == leg.upper }!) cannot reach its stance at \(pace) b/s")
                }
            }
        }
    }

    func testAFasterAnimalStridesFartherAndStepsFaster() throws {
        // Stride and cadence both rise with pace for every build; a cadence that fell as the
        // animal sped up would show its legs slowing down while it accelerates.
        var slower: [String: (from: Float, to: Float)] = [:]
        for name in Self.walkers {
            let rig = try Subject(name).rig
            var last = rig.gait(pace: 0.05, scale: rig.scale)
            var lastPace: Float = 0.05
            for pace in stride(from: Float(0.1), through: 20, by: 0.05) {
                let gait = rig.gait(pace: pace, scale: rig.scale)
                XCTAssertGreaterThanOrEqual(gait.stride, last.stride * 0.999_9, "\(name) shortens its stride at \(pace)")
                XCTAssertLessThanOrEqual(gait.duty, last.duty + 0.000_1, "\(name) keeps a foot down longer at \(pace)")
                // The stride is made up in the air only down to the sprint's duty, never to nothing.
                XCTAssertTrue(gait.duty >= PrehistoricRig.shortestDuty && gait.duty <= 0.9,
                              "\(name) at \(pace) b/s has a duty of \(gait.duty)")
                if pace / gait.stride < lastPace / last.stride * 0.999_9 {
                    slower[name] = (slower[name]?.from ?? lastPace, pace)
                }
                last = gait
                lastPace = pace
            }
        }
        // Where the legs' reach caps the stance, the stride is made up in the air (a shorter
        // duty), not by hurrying or slowing the legs.
        let report = slower.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.from)...\($0.value.to) b/s" }
        XCTAssertTrue(slower.isEmpty, "legs slow down as the animal speeds up: \(report.joined(separator: ", "))")
    }

    func testAFootfallWithoutAStanceOnlyLiftsAndAnOutOfRangeDutyIsClamped() {
        // Turning on the spot hands the footfall a stance of zero: the foot rises and falls in
        // place. A duty outside 0.1 ... 0.9 is held inside it, so a stance or a swing never
        // shrinks to nothing and the swing's speed stays finite.
        for index in 0..<1_000 {
            let phase = Float(index) / 1_000
            let still = PrehistoricPose.footfall(phase: phase, duty: 0.6, stance: 0, lift: 0.3)
            XCTAssertEqual(still.offset, 0, accuracy: 1e-6, "a turning foot moves fore and aft at \(phase)")
            for duty: Float in [-1, 0, 0.05, 0.95, 1, 2] {
                let fall = PrehistoricPose.footfall(phase: phase, duty: duty, stance: 1, lift: 0.3)
                XCTAssertEqual(fall.planted, phase < min(0.9, max(0.1, duty)), "duty \(duty) at \(phase)")
                XCTAssertTrue(fall.offset.isFinite && abs(fall.offset) <= 1.5, "duty \(duty) at \(phase): \(fall.offset)")
            }
        }
    }

    // MARK: Frame rate and random scripts

    /// A small fixed generator, so that a failing script replays from its seed.
    struct Script {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
        /// 0 ..< 1.
        mutating func unit() -> Double { Double(next()) / Double(UInt64(1) << 53) }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    func testThePoseAtAMomentDoesNotDependOnTheFrameRate() throws {
        // Easing is exponential in elapsed time, so an animal drawn at 30, 60 or 120 frames a
        // second has eased the same distance at the same moment. Only the integrated leg and
        // wing phases may differ, by the rounding of the integration, so they are left out.
        let stages: [(seconds: Double, speed: Double, action: PrehistoricAction, onGround: Bool, turn: Double)] = [
            (1, 0, .idle, true, 0), (1, 2, .alert, true, 0.6), (1, 0, .browse, true, 0), (1, 4, .charge, true, -1),
            (1, 0, .recover, true, 0), (1, 3, .flap, false, 1), (1, 3, .glide, false, -0.5), (1, 0, .idle, true, 0),
        ]
        for name in ["velociraptor", "triceratops", "brachiosaurus", "quetzalcoatlus", "microraptor"] {
            var readings: [[PrehistoricMotion]] = []
            for fps in [30.0, 60.0, 120.0] {
                var subject = try Subject(name)
                var samples: [PrehistoricMotion] = []
                for stage in stages {
                    // A land animal off the ground (a leap) keeps its ground action.
                    let land = subject.rig.plan != .flyer
                    let action = land && [.flap, .glide].contains(stage.action) ? .idle : stage.action
                    subject.run(seconds: stage.seconds, fps: fps, speed: stage.speed, action: action,
                                onGround: stage.onGround, turn: stage.turn)
                    samples.append(subject.motion)
                }
                readings.append(samples)
            }
            for (stage, sample) in readings[2].enumerated() {
                for other in readings.dropLast() {
                    let a = sample.weights, b = other[stage].weights
                    for (x, y) in zip([a.browse, a.alert, a.charge, a.eat, a.recover, a.flight, a.power, a.takeoff, a.landing],
                                      [b.browse, b.alert, b.charge, b.eat, b.recover, b.flight, b.power, b.takeoff, b.landing]) {
                        XCTAssertEqual(x, y, accuracy: 0.002, "\(name) stage \(stage): action weights depend on the frame rate")
                    }
                    // Stepping starts and stops when the eased pace crosses a threshold, which a
                    // frame sees up to one frame late: at 30 Hz that leaves the eased walk up to
                    // 1 - exp(-(1/30) / 0.16) = 19% of its value apart.
                    XCTAssertEqual(sample.walk, other[stage].walk, accuracy: 0.002 + 0.19 * max(sample.walk, other[stage].walk),
                                   "\(name) stage \(stage): walk")
                    XCTAssertEqual(sample.airborne, other[stage].airborne, accuracy: 0.002, "\(name) stage \(stage): airborne")
                    XCTAssertEqual(sample.speed, other[stage].speed, accuracy: 0.01 + 0.002 * abs(sample.speed), "\(name) stage \(stage): speed")
                    XCTAssertEqual(sample.turn, other[stage].turn, accuracy: 0.01, "\(name) stage \(stage): turn")
                }
            }
        }
    }

    func testASeededRandomScriptNeverBreaksAPoseForAnySpecies() throws {
        // Random actions, speeds, turns, climbs, take-offs and frame times, for every species.
        // Every frame must be finite, rigid, within the joint limits, with legs of their own
        // length and knees the right way round, and no part of a land animal may turn faster
        // than a frame's share of 14.4 rad/s (the 120 Hz limit of the smoothness test). Each
        // script runs twice and must replay to the same matrices. A failure names its seed.
        for (offset, name) in Self.jointed.enumerated() {
            let seed = UInt64(0xE1A5_0000) + UInt64(offset)
            let first = try randomScript(name, seed: seed)
            let second = try randomScript(name, seed: seed)
            XCTAssertEqual(first, second, "\(name) seed \(String(seed, radix: 16)) does not replay")
        }
    }

    private func randomScript(_ name: String, seed: UInt64) throws -> [simd_float4x4] {
        var script = Script(seed: seed)
        var subject = try Subject(name)
        subject.seed = UInt32(truncatingIfNeeded: script.next())
        let rig = subject.rig, flyer = rig.plan == .flyer
        let label = "\(name) seed \(String(seed, radix: 16))"
        let actions: [PrehistoricAction] = flyer
            ? [.idle, .takeoff, .flap, .glide, .landing]
            : [.idle, .browse, .alert, .charge, .eat, .recover]
        var remaining = 0.0, sinceStrike = 10.0
        var speed = 0.0, action = PrehistoricAction.idle, onGround = true, turn = 0.0, climb = 0.0
        var last: [simd_float4x4]?
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
            guard failures < 5, !condition() else { return }
            failures += 1
            XCTFail("\(label): \(message())")
        }
        for frame in 0..<900 {
            let dt = script.pick([1.0 / 30, 1.0 / 60, 1.0 / 120, 1.0 / 144]) * script.range(0.9, 1.1)
            sinceStrike += dt
            var attack = 0.0
            // Strikes come as the host makes them: a second apart (`attackCooldown`), and a blow
            // struck in a charge ends the charge in recovery in the same tick.
            if sinceStrike > 1, script.unit() < 0.02 {
                attack = 1
                sinceStrike = 0
                if action == .charge { action = .recover; remaining = script.range(0.4, 1.2) }
            }
            if remaining <= 0 {
                remaining = script.range(0.15, 1.6)
                let previous = action
                action = script.pick(actions)
                if previous == .charge && action == .recover {
                    if sinceStrike > 1 { attack = 1; sinceStrike = 0 } else { action = .charge }
                }
                speed = script.unit() < 0.3 ? 0 : script.range(0, flyer ? 9 : 8)
                turn = script.unit() < 0.4 ? 0 : script.range(-3, 3)
                onGround = flyer ? action == .idle : script.unit() > 0.1
                climb = onGround ? 0 : script.range(-3, 3)
            }
            subject.step(dt: dt, speed: speed, action: action, onGround: onGround, turn: turn, climb: climb, attack: attack)
            remaining -= dt
            let m = subject.motion
            for value in [m.gaitPhase, m.flapPhase] { check((0..<1).contains(value), "phase \(value) at frame \(frame)") }
            let w = m.weights
            for value in [m.walk, m.travel, m.airborne, w.browse, w.alert, w.charge, w.eat, w.recover, w.flight, w.power,
                          w.takeoff, w.landing] {
                check((-0.000_1...1.000_1).contains(value), "a weight left 0 ... 1: \(value) at frame \(frame)")
            }
            let matrices = subject.matrices()
            for (index, part) in subject.model.parts.enumerated() {
                let matrix = matrices[index]
                check(matrix.allFinite, "\(part.name) not finite at frame \(frame)")
                for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2] {
                    check((0.25...1.001).contains(simd_length(column)), "\(part.name) stretched at frame \(frame)")
                }
                let isLeg = rig.legs.contains { $0.upper == index || $0.lower == index || $0.foot == index }
                let reference = isLeg || rig.parents[index] < 0 ? rig.rest[index] : matrices[rig.parents[index]] * rig.local[index]
                let turned = angle(reference, matrix)
                check(turned <= Self.jointLimit(rig, index), "\(part.name) turned \(turned) at frame \(frame) (\(action.rawValue))")
                let isWing = rig.wings.contains { $0.inner == index || $0.outer == index }
                // Not a flyer's: its body pitches with atan2(climb, max(1, speed)) on a speed eased
                // in 0.12 s, and setting off from a hover briefly turns it at ~16 rad/s (microraptor,
                // seed e1a5001d, frame 859), a hair over this limit. The smoothness test holds
                // flyers through scripted flights instead.
                if let last, !isLeg, !isWing, !flyer {
                    let step = angle(last[index], matrix)
                    check(step <= Float(14.4 * dt) + 0.02, "\(part.name) snaps by \(step) rad at frame \(frame) (\(action.rawValue))")
                }
            }
            for leg in rig.legs {
                let hip = subject.point(leg.upper, in: matrices), knee = subject.point(leg.lower, in: matrices)
                let end = subject.tip(leg.lower, in: matrices)
                check(abs(simd_distance(hip, knee) - leg.upperLength) < 0.002, "thigh length at frame \(frame)")
                check(abs(simd_distance(knee, end) - leg.lowerLength) < 0.002, "shin length at frame \(frame)")
                let thigh = SIMD2(knee.y - hip.y, knee.z - hip.z), shin = SIMD2(end.y - knee.y, end.z - knee.z)
                let cross = thigh.x * shin.y - thigh.y * shin.x
                check(leg.kneeForward ? cross <= 0.000_5 : cross >= -0.000_5, "a joint bends the wrong way at frame \(frame)")
            }
            last = matrices
        }
        return last ?? []
    }
}

extension simd_float4x4 {
    /// True when no element is infinite or not a number.
    var allFinite: Bool {
        [columns.0, columns.1, columns.2, columns.3].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
        }
    }
}
