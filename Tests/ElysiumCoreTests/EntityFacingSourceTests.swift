import Foundation
import XCTest
@testable import ElysiumCore

/// Guards the mob-facing convention end to end. Every entity model is authored
/// vanilla-style with its face toward -Z, while the deterministic movement basis
/// drives a yaw-0 entity toward +Z (vx = -sin(yaw), vz = +cos(yaw)). The renderer
/// therefore MUST rotate by (pi - yaw), not (-yaw); dropping the pi term makes
/// every creature in the game walk backwards.
final class EntityFacingSourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testEntityRendererAppliesVanillaRigFacingFlip() throws {
        let renderer = try source("Sources/Elysium/EntityRendererM.swift")
        XCTAssertTrue(renderer.contains("m = mRotateY(m, Float(.pi - p.yaw))"),
                      "entity draw must rotate by (pi - yaw); models are authored facing -Z " +
                      "while motion at yaw 0 is +Z — without the pi flip every mob walks backwards")
        XCTAssertFalse(renderer.contains("mRotateY(m, Float(-p.yaw))"),
                       "the unflipped (-yaw) entity rotation must not come back")
    }

    func testPhotoBoothOrbitStaysAuthoredForTheFacingConvention() throws {
        // The booth orbit was always authored for "yaw 0 faces +Z" — with the
        // renderer flip in place its unmodified orbit photographs faces at the
        // "front" angle. Verified empirically against captured frames; do not
        // re-add a compensation offset here.
        let booth = try source("Sources/Elysium/PhotoBooth.swift")
        XCTAssertTrue(booth.contains("let yaw = yawDeg * .pi / 180"),
                      "PhotoBooth orbit must stay uncompensated; the renderer flip already points " +
                      "subject faces at the booth's front-angle camera")
        XCTAssertFalse(booth.contains("yawDeg + 180"),
                       "a +180 orbit compensation double-flips portraits into back-of-head shots")
    }

    func testModelsAreAuthoredFacingNegativeZ() throws {
        // The convention the renderer flip depends on: quadruped heads sit at
        // negative-z pivots, hind legs at positive z. If a future model rework
        // re-authors fronts toward +Z, the renderer flip must be removed with it.
        let pig = getModel("pig")
        let head = try XCTUnwrap(pig.parts.first { $0.name == "head" })
        let backLeg = try XCTUnwrap(pig.parts.first { $0.name == "legBR" })
        XCTAssertLessThan(head.pivot.2, 0, "pig head must pivot at negative z (front = -Z)")
        XCTAssertGreaterThan(backLeg.pivot.2, 0, "pig hind legs must pivot at positive z")
    }
}
