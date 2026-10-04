import simd
import XCTest
@testable import Elysium

/// Pins the first-person bow to Minecraft Java Edition's hand transforms
/// (ItemInHandRenderer UseAnim.BOW + models/item/bow.json).
final class FirstPersonBowTests: XCTestCase {
    private func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

    func testPullingTextureStagesUseVanillaWholeTickThresholds() {
        for (ticks, stage) in [(0, 0), (12, 0), (13, 1), (17, 1), (18, 2), (72_000, 2), (-5, 0)] {
            XCTAssertEqual(FirstPersonBow.pullingStage(useTicks: ticks), stage, "\(ticks) ticks")
        }
    }

    func testDrawCurveMatchesBowPowerForTime() {
        XCTAssertEqual(FirstPersonBow.pull(ticks: 0), 0)
        XCTAssertEqual(FirstPersonBow.pull(ticks: 10), (0.25 + 1) / 3, accuracy: 1e-6)
        XCTAssertEqual(FirstPersonBow.pull(ticks: 20), 1)
        XCTAssertEqual(FirstPersonBow.pull(ticks: 400), 1)
        XCTAssertEqual(FirstPersonBow.pull(ticks: .nan), 0)
        var previous: Float = 0
        for tick in stride(from: 0.0, through: 25, by: 0.25) {
            let value = FirstPersonBow.pull(ticks: tick)
            XCTAssertGreaterThanOrEqual(value, previous); previous = value
        }
    }

    func testIdleRightHandIsArmOffsetPlusDisplayTranslation() {
        // applyItemArmTransform then bow.json firstperson translation (pixels / 16).
        let idle = position(FirstPersonBow.transform(right: true, lift: 0, drawTicks: nil))
        XCTAssertEqual(idle.x, 0.56 + 1.13 / 16, accuracy: 1e-6)
        XCTAssertEqual(idle.y, -0.52 + 3.2 / 16, accuracy: 1e-6)
        XCTAssertEqual(idle.z, -0.72 + 1.13 / 16, accuracy: 1e-6)
        let lowered = position(FirstPersonBow.transform(right: true, lift: 1, drawTicks: nil))
        XCTAssertEqual(idle.y - lowered.y, 0.6, accuracy: 1e-6, "equip progress lowers by 0.6")
    }

    func testLeftHandMirrorsTheRightHandPosition() {
        for ticks in [nil, 0.0, 5.5, 13.0, 30.0] as [Double?] {
            let right = position(FirstPersonBow.transform(right: true, lift: 0, drawTicks: ticks))
            let left = position(FirstPersonBow.transform(right: false, lift: 0, drawTicks: ticks))
            XCTAssertEqual(left.x, -right.x, accuracy: 1e-5, "\(String(describing: ticks))")
            XCTAssertEqual(left.y, right.y, accuracy: 1e-5)
            XCTAssertEqual(left.z, right.z, accuracy: 1e-5)
        }
    }

    func testDrawingSwingsTheBowTowardScreenCentreAndBack() {
        let idle = position(FirstPersonBow.transform(right: true, lift: 0, drawTicks: nil))
        let drawn = position(FirstPersonBow.transform(right: true, lift: 0, drawTicks: 20))
        XCTAssertLessThan(abs(drawn.x), abs(idle.x), "drawing pulls the bow inward")
        XCTAssertGreaterThan(drawn.y, idle.y, "and raises it toward eye level")
        // The z-stretch grows with the draw.
        let early = FirstPersonBow.transform(right: true, lift: 0, drawTicks: 2)
        let full = FirstPersonBow.transform(right: true, lift: 0, drawTicks: 20)
        XCTAssertGreaterThan(simd_length(SIMD3(full.columns.2.x, full.columns.2.y, full.columns.2.z)),
                             simd_length(SIMD3(early.columns.2.x, early.columns.2.y, early.columns.2.z)))
    }

    func testBowStaysOnScreenThroughTheDraw() {
        let projection = mat4Perspective(fovYRad: 70 * .pi / 180, aspect: 16.0 / 9, near: 0.035, far: 12)
        for right in [true, false] {
            for ticks in [nil, 0, 4, 10, 15, 20, 40] as [Double?] {
                let clip = projection * FirstPersonBow.transform(right: right, lift: 0, drawTicks: ticks)
                    * SIMD4<Float>(0, 0, 0, 1)
                XCTAssertGreaterThan(clip.w, 0, "in front of the camera")
                let ndc = SIMD2(clip.x, clip.y) / clip.w
                XCTAssertLessThan(abs(ndc.x), 1, "right=\(right) ticks=\(String(describing: ticks))")
                XCTAssertLessThan(abs(ndc.y), 1)
                if let ticks, ticks >= 10 { XCTAssertGreaterThan(ndc.x * (right ? 1 : -1), 0, "stays on its own side") }
            }
        }
    }

    func testRotationOrderIsXThenYThenZ() {
        let m = FirstPersonBow.rotationXYZ(degrees: 30, 40, 50)
        let r = Float.pi / 180
        let expected = simd_float4x4(simd_quatf(angle: 30 * r, axis: [1, 0, 0]) * simd_quatf(angle: 40 * r, axis: [0, 1, 0])
                                     * simd_quatf(angle: 50 * r, axis: [0, 0, 1]))
        for c in 0..<4 { for row in 0..<4 { XCTAssertEqual(m[c][row], expected[c][row], accuracy: 1e-6) } }
    }
}
