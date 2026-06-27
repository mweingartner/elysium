import XCTest
@testable import PebbleCore

final class CameraTests: XCTestCase {
    func testWalkingCameraBobPresentationAmplitudeIsHalved() {
        let peak = cameraBobOffset(phase: 0.5, amplitude: 0.2, yaw: 0)

        XCTAssertEqual(peak.y, 0.12, accuracy: 1e-12)
        XCTAssertEqual(peak.x, 0.03, accuracy: 1e-12)
        XCTAssertEqual(peak.z, 0.0, accuracy: 1e-12)
    }
}
