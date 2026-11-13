import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// What the renderer remembers about each prehistoric creature it draws: the motion state
/// (`PrehistoricMotionState`), its store and its clock, and how a LAN guest's mirrored creature
/// is drawn between snapshots. The pose that follows from a motion is in `PrehistoricPoseTests`.
final class PrehistoricMotionTests: XCTestCase {
    typealias Subject = PrehistoricPoseTests.Subject
    typealias Script = PrehistoricPoseTests.Script

    // MARK: The motion state

    func testALANMirrorGlidesBetweenItsSnapshotsAndWalksInStep() throws {
        // A guest's copy of a host creature jumps five times a second. Drawn, it has to move
        // on every frame, and its legs have to keep the pace of what is drawn.
        for name in ["tyrannosaurus", "triceratops", "compsognathus"] {
            let rig = try Subject(name).rig
            let speed = 2.0, interval = LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL
            var hostZ = 0.0, time = 0.0, sinceSnapshot = 0.0, snapshotZ = 0.0
            var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: 0, action: .idle, onGround: true, attack: 0,
                                              mirror: true, scale: rig.scale, seed: 3)
            var state = PrehistoricMotionState(seen, time: 0)
            var lastDrawn = 0.0, longest = 0.0, stalled = 0
            for frame in 0..<(6 * 120) {
                time += 1.0 / 120
                hostZ += speed / 120
                sinceSnapshot += 1.0 / 120
                if sinceSnapshot >= interval {
                    sinceSnapshot -= interval
                    snapshotZ = hostZ
                }
                seen.z = snapshotZ
                let drawn = state.advance(seen, rig: rig, time: time)
                if frame > 120 {
                    let moved = drawn.z - lastDrawn
                    longest = max(longest, moved)
                    if moved <= 0 { stalled += 1 }
                    XCTAssertGreaterThanOrEqual(moved, -0.000_001, "\(name) is drawn moving backward")
                }
                lastDrawn = drawn.z
            }
            XCTAssertLessThan(longest, speed / 120 * 1.6, "\(name) is drawn in jumps of \(longest) blocks")
            XCTAssertLessThan(stalled, 12, "\(name) stands still between snapshots (\(stalled) frames)")
            XCTAssertEqual(lastDrawn, hostZ, accuracy: speed * interval * 1.5, "\(name) is drawn where the host has it, one snapshot late")
            XCTAssertEqual(Double(state.motion.speed), speed, accuracy: speed * 0.12, "\(name) reads the pace of what is drawn")
            XCTAssertGreaterThan(state.motion.walk, 0.95, name)
        }
    }

    func testTheMotionStateIgnoresRepeatedInstantsBadInputAndTeleports() throws {
        var subject = try Subject("velociraptor")
        subject.run(seconds: 2, speed: 3)
        let rig = subject.rig
        var state = try XCTUnwrap(subject.state)
        let settled = state.motion
        let seen = PrehistoricObservation(x: subject.x, y: subject.y, z: subject.z, yaw: subject.yaw, action: .idle,
                                          onGround: true, attack: 0, mirror: false, scale: rig.scale, seed: subject.seed)
        // The same instant again changes nothing.
        _ = state.advance(seen, rig: rig, time: subject.time)
        XCTAssertEqual(state.motion, settled)
        // Input that is not a number is not looked at.
        var broken = seen
        broken.x = .nan
        _ = state.advance(broken, rig: rig, time: subject.time + 0.01)
        _ = state.advance(seen, rig: rig, time: .infinity)
        XCTAssertEqual(state.motion, settled)
        // A creature moved a long way at once was moved, not sprinting.
        var moved = seen
        moved.z += 500
        let drawn = state.advance(moved, rig: rig, time: subject.time + 1.0 / 120)
        XCTAssertEqual(drawn.z, moved.z)
        XCTAssertLessThan(state.motion.speed, settled.speed, "a teleport reads as speed")
        XCTAssertTrue(state.motion.gaitPhase.isFinite && (0..<1).contains(state.motion.gaitPhase))
        // A long pause between frames is not a movement either.
        var paused = moved
        paused.z += 3
        _ = state.advance(paused, rig: rig, time: subject.time + 30)
        XCTAssertLessThan(state.motion.speed, settled.speed)
        XCTAssertTrue(state.motion.speed.isFinite)
    }

    func testNumbersFromAnotherMachineCannotStallOrPoisonTheMotionState() throws {
        // A guest's mirror carries whatever the host sent: finite, but as large as a number gets.
        XCTAssertEqual(PrehistoricMotionState.shortestTurn(from: 0, to: 1e300).magnitude <= .pi, true)
        XCTAssertEqual(PrehistoricMotionState.shortestTurn(from: -1e18, to: 1e18).magnitude <= .pi, true)
        XCTAssertEqual(PrehistoricMotionState.shortestTurn(from: 0, to: .greatestFiniteMagnitude).isFinite, true)
        XCTAssertEqual(PrehistoricMotionState.shortestTurn(from: 0.2, to: 0.5), 0.3, accuracy: 1e-12)
        XCTAssertEqual(PrehistoricMotionState.shortestTurn(from: 3.1, to: -3.1), 2 * .pi - 6.2, accuracy: 1e-12)
        XCTAssertEqual(PrehistoricMotionState.shortestTurn(from: 0, to: .infinity), 0)

        let rig = try Subject("tyrannosaurus").rig
        var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: 0, action: .idle, onGround: true, attack: 0,
                                          mirror: true, scale: rig.scale, seed: 5)
        var state = PrehistoricMotionState(seen, time: 0)
        var time = 0.0
        let hostile: [(Double, Double, Double, Double)] = [
            (1e300, 64, 0, 0), (0, 64, 0, 1e300), (-1e300, -1e300, 1e300, -1e18),
            (.greatestFiniteMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .greatestFiniteMagnitude),
            (0, 64, 0, 0), (2, 64, 2, 7e17), (2, 64, 3, 0.1),
        ]
        for (x, y, z, yaw) in hostile {
            for _ in 0..<40 {
                time += 1.0 / 120
                seen.x = x; seen.y = y; seen.z = z; seen.yaw = yaw
                let drawn = state.advance(seen, rig: rig, time: time)
                XCTAssertTrue(drawn.x.isFinite && drawn.y.isFinite && drawn.z.isFinite && drawn.yaw.isFinite,
                              "drawn at \(drawn) for \(x), \(y), \(z), \(yaw)")
                let m = state.motion
                for value in [m.gaitPhase, m.walk, m.pace, m.travel, m.turn, m.speed, m.climb, m.flapPhase, m.airborne] {
                    XCTAssertTrue(value.isFinite, "motion \(m) for \(x), \(y), \(z), \(yaw)")
                }
                XCTAssertTrue((0..<1).contains(m.gaitPhase))
                var pose = EntityPose()
                pose.motion = m
                for matrix in PrehistoricPose.partMatrices(rig: rig, pose: pose, time: time) {
                    XCTAssertTrue(matrix.allFinite)
                }
            }
        }
        // And a pose survives a time and a look that are not numbers.
        var pose = EntityPose()
        pose.pitch = .nan
        for time in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            for matrix in PrehistoricPose.partMatrices(rig: rig, pose: pose, time: time) {
                XCTAssertTrue(matrix.allFinite, "time \(time)")
            }
            let gaze = PrehistoricPose.gaze(seed: 1, time: time, period: 3, salt: 1)
            XCTAssertTrue(gaze.x.isFinite && gaze.y.isFinite)
        }
    }

    func testEveryActionAimsForKnownWeightsAndAForeignActionIsIdle() {
        for action in PrehistoricAction.allCases {
            let w = PrehistoricMotionState.targetWeights(action)
            for value in [w.browse, w.alert, w.charge, w.eat, w.recover, w.flight, w.power, w.takeoff, w.landing] {
                XCTAssertTrue(value == 0 || value == 1)
            }
            XCTAssertLessThanOrEqual(w.browse + w.alert + w.charge + w.eat + w.recover, 1, "\(action) is one ground action")
            XCTAssertEqual(w.flight == 1, [.takeoff, .flap, .glide, .landing].contains(action), "\(action)")
        }
        for swimming in [PrehistoricAction.cruise, .surface, .dive, .turn, .burst, .stranded] {
            XCTAssertEqual(PrehistoricMotionState.targetWeights(swimming), PrehistoricActionWeights())
        }
    }

    func testTheMotionStoreKeepsOnlyWhatIsStillDrawn() throws {
        let world = World(dim: .overworld, seed: 1)
        let store = PrehistoricMotionStore()
        let rig = try Subject("triceratops").rig
        var entities: [Entity] = []
        let triceratops = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.triceratops"))
        for _ in 0..<5 {
            entities.append(PrehistoricCreature(world: world, definition: triceratops))
        }
        var time = 0.0
        func frame(_ drawn: [Entity]) -> [EntityPose] {
            time += 1.0 / 60
            store.beginFrame(time: time)
            return drawn.map { entity in
                var pose = EntityPose()
                pose.x = 1; pose.y = 64; pose.z = time * 2
                store.present(&pose, entity: entity, rig: rig)
                return pose
            }
        }
        for _ in 0..<120 { _ = frame(entities) }
        XCTAssertEqual(store.count, 5)
        let walking = frame(entities)
        XCTAssertTrue(walking.allSatisfy { $0.motion.walk > 0.9 }, "the store reads each creature's own movement")
        XCTAssertEqual(Set(walking.map { $0.motion.seed }).count, 5, "each creature has its own seed")
        // Drawing a creature twice in one frame gives the same pose.
        var once = EntityPose(), twice = EntityPose()
        once.x = 1; once.y = 64; once.z = time * 2
        twice = once
        store.present(&once, entity: entities[0], rig: rig)
        store.present(&twice, entity: entities[0], rig: rig)
        XCTAssertEqual(once.motion, twice.motion)
        // Four of them leave the view: their states go, the fifth stays.
        for _ in 0..<Int(PrehistoricMotionStore.idleFrames + PrehistoricMotionStore.sweepInterval) + 1 {
            _ = frame([entities[4]])
        }
        XCTAssertEqual(store.count, 1)
    }


    // MARK: The clock

    /// The rotation between two part matrices, as an angle.
    private func turned(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        func axes(_ m: simd_float4x4) -> simd_float3x3 {
            simd_float3x3(simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                          simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                          simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        }
        let relative = axes(a).transpose * axes(b)
        return acos(max(-1, min(1, (relative.columns.0.x + relative.columns.1.y + relative.columns.2.z - 1) / 2)))
    }

    func testCreaturesKeepMovingWhenTheFrameTimeWrapsAfterHalfAnHour() throws {
        // The renderer's frame time is taken modulo 1800 seconds (`timeSec` in main.swift). At
        // the wrap it falls from just under 1800 to just over 0. A creature must keep walking
        // through that frame: drawn where it is, with its legs and its gaze carrying on.
        let world = World(dim: .overworld, seed: 2)
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.tyrannosaurus"))
        let walker = PrehistoricCreature(world: world, definition: definition)
        let stander = PrehistoricCreature(world: world, definition: definition)
        let model = getModel("prehistoric.tyrannosaurus")
        let rig = try XCTUnwrap(PrehistoricRig(model: model))
        let store = PrehistoricMotionStore()
        var frameTime = 1800 - 2.0
        var z = 0.0
        var last: (walker: [simd_float4x4], stander: [simd_float4x4], phase: Float, clock: Double)?
        var wrapped = false
        for frame in 0..<(6 * 120) {
            frameTime += 1.0 / 120
            if frameTime >= 1800 { frameTime -= 1800; wrapped = true }
            z += 3.0 / 120
            store.beginFrame(time: frameTime)
            var walking = EntityPose(), standing = EntityPose()
            walking.x = 0; walking.y = 64; walking.z = z
            standing.x = 9; standing.y = 64; standing.z = 0
            store.present(&walking, entity: walker, rig: rig)
            store.present(&standing, entity: stander, rig: rig)
            XCTAssertEqual(walking.z, z, accuracy: 1e-9, "frame \(frame): the walker is drawn where it is")
            let now = (EntityRendererM.partTransforms(model: model, pose: walking, time: frameTime, rig: rig),
                       EntityRendererM.partTransforms(model: model, pose: standing, time: frameTime, rig: rig),
                       walking.motion.gaitPhase, try XCTUnwrap(walking.motion.clock))
            if let last, frame > 120 {
                XCTAssertGreaterThan(now.3, last.clock, "frame \(frame): the clock runs on")
                XCTAssertEqual(now.3 - last.clock, 1.0 / 120, accuracy: frameTime < 0.02 ? 0.02 : 1e-6,
                               "frame \(frame): the clock moves by a frame")
                XCTAssertNotEqual(now.2, last.phase, "frame \(frame): the legs keep cycling")
                XCTAssertGreaterThan(walking.motion.walk, 0.95, "frame \(frame): the walker keeps walking")
                XCTAssertEqual(walking.motion.speed, 3, accuracy: 0.5, "frame \(frame): no burst of speed")
                for index in 0..<model.parts.count {
                    // The head of a standing animal turns slowly; nothing snaps at the wrap.
                    XCTAssertLessThan(turned(last.stander[index], now.1[index]), 0.05,
                                      "frame \(frame): the standing animal's \(model.parts[index].name) snaps")
                    XCTAssertLessThan(turned(last.walker[index], now.0[index]), 0.25,
                                      "frame \(frame): the walking animal's \(model.parts[index].name) snaps")
                }
            }
            last = now
        }
        XCTAssertTrue(wrapped, "the script crossed the wrap")
    }

    func testTheStoresClockOnlyRunsForwardWhateverFrameTimesItIsGiven() {
        let store = PrehistoricMotionStore()
        var last = store.clock
        var script = Script(seed: 0xC10C_0001)
        let odd: [Double] = [0, 0, 5, 4.999, 1799.99, 0.001, .nan, 0.002, .infinity, -.infinity, 0.01,
                             -3, 1e300, -1e300, 12, 12.016, 12.016, 3600, 0]
        for time in odd {
            store.beginFrame(time: time)
            XCTAssertTrue(store.clock.isFinite, "after \(time)")
            XCTAssertGreaterThanOrEqual(store.clock, last, "the clock ran backward at \(time)")
            XCTAssertLessThanOrEqual(store.clock - last, PrehistoricMotionStore.longestFrame + 1e-9,
                                     "the clock leapt at \(time)")
            last = store.clock
        }
        for _ in 0..<5_000 {
            let time = script.pick([script.range(0, 1800), script.range(-1e6, 1e6), last.truncatingRemainder(dividingBy: 1800)])
            store.beginFrame(time: time)
            XCTAssertTrue(store.clock.isFinite && store.clock >= last && store.clock - last <= PrehistoricMotionStore.longestFrame + 1e-9)
            last = store.clock
        }
        // Ordinary frames move it by exactly what passed.
        store.beginFrame(time: 100)
        let before = store.clock
        store.beginFrame(time: 100.25)
        XCTAssertEqual(store.clock - before, 0.25, accuracy: 1e-12)
    }

    func testAStateWhoseClockRunsBackwardStartsAgainInsteadOfStandingStill() throws {
        // Whoever drives a state with a clock that restarts must not leave the creature drawn
        // where it last was until that clock catches up.
        var subject = try Subject("velociraptor")
        subject.run(seconds: 2, speed: 3, action: .charge)
        let rig = subject.rig
        var state = try XCTUnwrap(subject.state)
        XCTAssertGreaterThan(state.motion.speed, 2)
        var seen = PrehistoricObservation(x: 50, y: 70, z: -20, yaw: 1, action: .idle, onGround: true, attack: 0,
                                          mirror: false, scale: rig.scale, seed: subject.seed)
        let drawn = state.advance(seen, rig: rig, time: 0.05)
        XCTAssertEqual(drawn.x, 50); XCTAssertEqual(drawn.y, 70); XCTAssertEqual(drawn.z, -20); XCTAssertEqual(drawn.yaw, 1)
        XCTAssertEqual(state.motion.speed, 0, "it starts again from what is seen")
        XCTAssertEqual(state.motion.weights, PrehistoricMotionState.targetWeights(.idle))
        XCTAssertEqual(state.motion.clock, 0.05)
        // From there it follows the new clock at once.
        seen.z += 3.0 / 60
        _ = state.advance(seen, rig: rig, time: 0.05 + 1.0 / 60)
        XCTAssertGreaterThan(state.motion.speed, 0)
        XCTAssertEqual(state.motion.clock, 0.05 + 1.0 / 60)
    }

    func testAPoseIsDrawnForItsMotionsMomentAndFallsBackToTheRenderersTime() throws {
        // A creature the store follows is posed for the store's moment whatever frame time the
        // renderer passes; one that nothing follows is posed for the time passed.
        let model = getModel("prehistoric.triceratops")
        let rig = try XCTUnwrap(PrehistoricRig(model: model))
        var followed = EntityPose()
        followed.motion.clock = 37.5
        let atStoreMoment = PrehistoricPose.partMatrices(rig: rig, pose: followed, time: 0)
        XCTAssertEqual(atStoreMoment, PrehistoricPose.partMatrices(rig: rig, pose: followed, time: 1234))
        let free = EntityPose()
        XCTAssertEqual(PrehistoricPose.partMatrices(rig: rig, pose: free, time: 37.5), atStoreMoment)
        XCTAssertNotEqual(PrehistoricPose.partMatrices(rig: rig, pose: free, time: 44), atStoreMoment)
        // A caller that does not hand in the rig gets the same pose: the rig is read for it.
        XCTAssertEqual(EntityRendererM.partTransforms(model: model, pose: followed, time: 0), atStoreMoment)
        XCTAssertEqual(EntityRendererM.partTransforms(model: model, pose: followed, time: 0, rig: rig), atStoreMoment)
    }

    // MARK: LAN mirrors

    func testALANMirrorTurnsTheShortWayAcrossTheHalfTurn() throws {
        // Headings arrive wrapped into -pi ... pi. A creature turning slowly through the back of
        // that range is drawn turning a little each frame, never spinning round the long way.
        let rig = try Subject("triceratops").rig
        let rate = 0.8   // radians a second, toward larger yaw
        var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: 2.9, action: .idle, onGround: true, attack: 0,
                                          mirror: true, scale: rig.scale, seed: 9)
        var state = PrehistoricMotionState(seen, time: 0)
        var time = 0.0, hostYaw = 2.9, lastDrawn = 2.9, worst = 0.0, sinceSnapshot = 0.0
        for frame in 0..<(3 * 120) {
            time += 1.0 / 120
            hostYaw += rate / 120
            sinceSnapshot += 1.0 / 120
            if sinceSnapshot >= LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL {
                sinceSnapshot = 0
                seen.yaw = hostYaw.remainder(dividingBy: 2 * .pi)
            }
            let drawn = state.advance(seen, rig: rig, time: time)
            let turned = PrehistoricMotionState.shortestTurn(from: lastDrawn, to: drawn.yaw)
            XCTAssertGreaterThanOrEqual(turned, -1e-9, "drawn turning backward at frame \(frame)")
            if frame > 30 { worst = max(worst, abs(turned)) }
            lastDrawn = drawn.yaw
        }
        XCTAssertGreaterThan(hostYaw, Double.pi + 0.5, "the host crossed the half turn")
        XCTAssertLessThan(worst, rate / 120 * 2, "the drawn heading jumps by \(worst) rad in a frame")
        XCTAssertEqual(Double(state.motion.turn), rate, accuracy: rate * 0.25, "the turn reads as the host's")
        XCTAssertLessThan(abs(PrehistoricMotionState.shortestTurn(from: lastDrawn, to: hostYaw)), rate * 0.5,
                          "drawn about one snapshot behind the host")
    }

    func testALANMirrorThatStopsComesToRestExactlyWhereTheHostHasIt() throws {
        let rig = try Subject("velociraptor").rig
        var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: 0, action: .idle, onGround: true, attack: 0,
                                          mirror: true, scale: rig.scale, seed: 4)
        var state = PrehistoricMotionState(seen, time: 0)
        var time = 0.0, hostZ = 0.0, sinceSnapshot = 0.0
        var drawn = (x: 0.0, y: 64.0, z: 0.0, yaw: 0.0)
        for frame in 0..<(4 * 120) {
            time += 1.0 / 120
            if frame < 2 * 120 { hostZ += 2.0 / 120 }
            sinceSnapshot += 1.0 / 120
            if sinceSnapshot >= LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL {
                sinceSnapshot = 0
                seen.z = hostZ
            }
            drawn = state.advance(seen, rig: rig, time: time)
        }
        XCTAssertEqual(drawn.z, hostZ, "a stopped mirror stands where the host stands, not short of it")
        XCTAssertLessThan(state.motion.walk, 0.01, "a stopped mirror stops stepping")
        XCTAssertLessThan(state.motion.speed, 0.01)
    }

    func testALANMirrorGlidesForwardWhateverTheFrameRateAndTheSnapshotJitter() throws {
        // Snapshots do not arrive like clockwork, and frames vary. Whatever the timing, a mirror
        // of a creature walking one way is never drawn stepping back, never leaps, and keeps
        // about one snapshot behind.
        var script = Script(seed: 0x5EED_0001)
        for name in ["compsognathus", "triceratops", "brachiosaurus", "pteranodon"] {
            let rig = try Subject(name).rig
            for fps in [30.0, 60.0, 120.0] {
                let speed = script.range(0.5, 6), heading = script.range(-.pi, .pi)
                let label = "\(name) at \(fps) fps, \(speed) b/s, seed 0x5EED_0001"
                let direction = (x: -sin(heading), z: cos(heading))
                var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: heading, action: .idle, onGround: true,
                                                  attack: 0, mirror: true, scale: rig.scale, seed: 2)
                var state = PrehistoricMotionState(seen, time: 0)
                var time = 0.0, host = 0.0, nextSnapshot = 0.2, lastProgress = 0.0, longest = 0.0
                for frame in 0..<Int(8 * fps) {
                    let dt = 1 / fps * script.range(0.85, 1.15)
                    time += dt
                    host += speed * dt
                    if time >= nextSnapshot {
                        nextSnapshot = time + script.range(0.15, 0.3)
                        seen.x = direction.x * host
                        seen.z = direction.z * host
                    }
                    let drawn = state.advance(seen, rig: rig, time: time)
                    let progress = drawn.x * direction.x + drawn.z * direction.z
                    XCTAssertGreaterThanOrEqual(progress - lastProgress, -1e-9, "\(label): drawn stepping back at frame \(frame)")
                    longest = max(longest, (progress - lastProgress) / dt)
                    XCTAssertLessThanOrEqual(host - progress, speed * 0.55 + 0.01, "\(label): falls behind at frame \(frame)")
                    lastProgress = progress
                }
                XCTAssertLessThan(longest, speed * 3, "\(label): drawn leaping at \(longest) b/s")
            }
        }
    }

    func testALANMirrorNeverStandsWaitingWhenItsSnapshotsArriveOnTime() throws {
        // The host sends every 0.2 s, but a frame sees a snapshot up to one frame late, so the
        // gaps a guest measures wander by a frame. The glide is stretched past the measured gap
        // (`glideStretch`) so that it is still under way when the next one lands. At 120 Hz with
        // 10% frame jitter a gap is off by under 5%, well inside the 15% stretch.
        let rig = try Subject("triceratops").rig
        var script = Script(seed: 0x5EED_0002)
        let interval = LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL
        var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: 0, action: .idle, onGround: true, attack: 0,
                                          mirror: true, scale: rig.scale, seed: 1)
        var state = PrehistoricMotionState(seen, time: 0)
        var time = 0.0, nextSnapshot = interval, last = 0.0, stalled = 0
        for frame in 0..<(8 * 120) {
            time += 1.0 / 120 * script.range(0.9, 1.1)
            while time >= nextSnapshot {
                seen.z = nextSnapshot * 2
                nextSnapshot += interval
            }
            let drawn = state.advance(seen, rig: rig, time: time)
            if frame > 120 && drawn.z <= last { stalled += 1 }
            last = drawn.z
        }
        XCTAssertEqual(stalled, 0, "the mirror stood waiting for a snapshot on \(stalled) frames")
    }

    func testALANMirrorMovedFarAtOnceIsDrawnThereAtOnceAndDoesNotRun() throws {
        // A host's creature moved by a command or a respawn arrives as one snapshot far away.
        // A host's own creature is redrawn there at once (`teleportDistance`); a mirror ought
        // to be too, instead of being drawn racing across the gap with its legs a blur.
        let rig = try Subject("triceratops").rig
        var seen = PrehistoricObservation(x: 0, y: 64, z: 0, yaw: 0, action: .idle, onGround: true, attack: 0,
                                          mirror: true, scale: rig.scale, seed: 6)
        var state = PrehistoricMotionState(seen, time: 0)
        var time = 0.0
        for _ in 0..<120 {
            time += 1.0 / 120
            _ = state.advance(seen, rig: rig, time: time)
        }
        seen.z = 40
        var fastest: Float = 0, firstDrawn = 0.0
        for frame in 0..<60 {
            time += 1.0 / 120
            let drawn = state.advance(seen, rig: rig, time: time)
            if frame == 0 { firstDrawn = drawn.z }
            fastest = max(fastest, state.motion.speed)
        }
        XCTAssertEqual(firstDrawn, 40, "a moved mirror is drawn where it was moved to")
        XCTAssertLessThan(fastest, 1, "a moved mirror is drawn running at \(fastest) b/s")
    }

    // MARK: The store

    func testTheStoreGivesAMirrorTheHostsSeedAndItsGlide() throws {
        // A guest's copy has its own entity id. Both screens agree on the herd's rhythm because
        // the copy takes its seed from the host's id, and only the copy glides.
        let world = World(dim: .overworld, seed: 1)
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.tyrannosaurus"))
        let rig = try Subject("tyrannosaurus").rig
        let host = PrehistoricCreature(world: world, definition: definition)
        let mirror = PrehistoricCreature(world: world, definition: definition)
        mirror.lanReplicatedMirror = true
        mirror.lanReplicationSourceID = host.id
        XCTAssertNotEqual(mirror.id, host.id)
        let store = PrehistoricMotionStore()
        var hostPose = EntityPose(), mirrorPose = EntityPose()
        // Twelve frames standing, then a snapshot one snapshot interval later.
        for (time, z) in (0...12).map({ (Double($0) / 60, $0 == 12 ? 1.0 : 0.0) }) {
            store.beginFrame(time: time)
            hostPose = EntityPose(); hostPose.y = 64; hostPose.z = z
            mirrorPose = hostPose
            store.present(&hostPose, entity: host, rig: rig)
            store.present(&mirrorPose, entity: mirror, rig: rig)
        }
        XCTAssertEqual(mirrorPose.motion.seed, PrehistoricPose.seed(host.id))
        XCTAssertEqual(mirrorPose.motion.seed, hostPose.motion.seed)
        XCTAssertEqual(hostPose.z, 1, "a host's creature is drawn where it is")
        XCTAssertGreaterThan(mirrorPose.z, 0, "a mirror starts its glide on the frame the snapshot arrives")
        XCTAssertLessThan(mirrorPose.z, 0.2, "a mirror glides to its snapshot instead of jumping")
        XCTAssertEqual(store.count, 2)
    }

    func testTheStoreKeepsTwoCreaturesMovementsApart() throws {
        let world = World(dim: .overworld, seed: 1)
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.velociraptor"))
        let rig = try Subject("velociraptor").rig
        let walker = PrehistoricCreature(world: world, definition: definition)
        let stander = PrehistoricCreature(world: world, definition: definition)
        walker.onGround = true; stander.onGround = true
        stander.data.prehistoricAction = PrehistoricAction.alert.rawValue
        let store = PrehistoricMotionStore()
        var walking = EntityPose(), standing = EntityPose()
        for frame in 1...240 {
            let time = Double(frame) / 120
            store.beginFrame(time: time)
            walking = EntityPose(); walking.y = 64; walking.z = time * 3
            standing = EntityPose(); standing.y = 64; standing.x = 5
            store.present(&walking, entity: walker, rig: rig)
            store.present(&standing, entity: stander, rig: rig)
        }
        XCTAssertGreaterThan(walking.motion.walk, 0.95)
        XCTAssertEqual(Double(walking.motion.speed), 3, accuracy: 0.1)
        XCTAssertEqual(walking.motion.weights.alert, 0, accuracy: 0.001, "one creature's action stays its own")
        XCTAssertLessThan(standing.motion.walk, 0.001)
        XCTAssertEqual(standing.motion.speed, 0, accuracy: 0.001)
        XCTAssertGreaterThan(standing.motion.weights.alert, 0.99)
        XCTAssertEqual(standing.x, 5)
    }
}
