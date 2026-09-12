import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class BatPresentationTests: XCTestCase {
    private func point(_ part: String, _ x: Float, _ y: Float, _ z: Float,
                       hanging: Bool = false, time: Double = 0) -> SIMD3<Float> {
        let matrix = BatPresentation.partMatrix(part, hanging: hanging, time: time)
        let result = matrix * SIMD4<Float>(x / 16, y / 16, z / 16, 1)
        return SIMD3(result.x, result.y, result.z)
    }

    func testModernBatRigMatchesBundledFaithfulUVLayout() throws {
        let geometry = buildEntityGeometry("bat")
        XCTAssertEqual(geometry.model.texW, 32)
        XCTAssertEqual(geometry.model.texH, 32)
        XCTAssertEqual(geometry.model.scale, 1)
        XCTAssertEqual(geometry.partNames,
                       ["head", "body", "feet", "wingR", "wingTipR", "wingL", "wingTipL"])
        for index in stride(from: 0, to: geometry.verts.count, by: 9) {
            XCTAssertTrue(geometry.verts[index..<index + 9].allSatisfy(\.isFinite))
            XCTAssertTrue((0...1).contains(geometry.verts[index + 6]))
            XCTAssertTrue((0...1).contains(geometry.verts[index + 7]))
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pack = try XCTUnwrap(ResourcePack(url: repository.appendingPathComponent(
            "packaging/Faithful 64x - December 2025 Release.zip")))
        let image = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file(
            "assets/minecraft/textures/entity/bat.png"))))
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
        let head = try XCTUnwrap(geometry.model.parts.first { $0.name == "head" })
        let face = try XCTUnwrap(head.boxes.first)
        XCTAssertEqual(face.u, 0)
        XCTAssertEqual(face.v, 7)
        XCTAssertEqual(face.w, 4)
        XCTAssertEqual(face.h, 3)
        XCTAssertEqual(face.d, 2)

        // Faithful places one eye on each side of the head, not on the central
        // snout. Sample those actual mapped side faces; matching a square aspect
        // ratio alone would admit the incompatible old 64-unit UV layout.
        var eyePixels = 0
        for y in 36..<48 {
            for x in Array(0..<8) + Array(24..<32) {
                let index = (y * image.width + x) * 4
                if image.pixels[index] > 150 && image.pixels[index + 1] > 150 &&
                    image.pixels[index + 2] > 150 && image.pixels[index + 3] > 200 {
                    eyePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(eyePixels, 4, "modern head-side UVs must actually contain the Faithful eyes")
    }

    func testFlightStaysHeadUpThroughEntireWingbeat() {
        for frame in 0...240 {
            let time = Double(frame) / 240
            let head = point("head", 0, 1.5, 0, time: time)
            let ears = point("head", 0, 6, 0, time: time)
            let body = point("body", 0, -2.5, 0, time: time)
            let feet = point("feet", 0, -1, 0, time: time)
            XCTAssertGreaterThan(head.y, body.y)
            XCTAssertGreaterThan(ears.y, head.y)
            XCTAssertGreaterThan(head.y, feet.y)
            XCTAssertGreaterThan(body.z, head.z, "body must trail behind the -Z-facing head")
        }
    }

    func testRoostInvertsWholeBatAndDoesNotFlap() {
        let head = point("head", 0, 1.5, 0, hanging: true)
        let body = point("body", 0, -2.5, 0, hanging: true)
        let feet = point("feet", 0, -1, 0, hanging: true)
        XCTAssertLessThan(head.y, body.y)
        XCTAssertLessThan(body.y, feet.y)
        XCTAssertEqual(point("feet", 0, -2, 0, hanging: true).y, 1, accuracy: 0.00001)
        for name in buildEntityGeometry("bat").partNames {
            let still = BatPresentation.partMatrix(name, hanging: true, time: 0)
            for time in [0.125, 0.25, 0.50, 12.9] {
                let later = BatPresentation.partMatrix(name, hanging: true, time: time)
                for column in 0..<4 {
                    XCTAssertEqual(simd_distance(still[column], later[column]), 0, accuracy: 0.00001)
                }
            }
        }
    }

    func testWingTipsStayAttachedAndMirrorAcrossTheBody() {
        for hanging in [false, true] {
            for frame in 0...120 {
                let time = Double(frame) / 120
                for (inner, tip, sign): (String, String, Float) in [
                    ("wingR", "wingTipR", -1), ("wingL", "wingTipL", 1),
                ] {
                    let hinge = point(inner, sign * 2, 0, 0, hanging: hanging, time: time)
                    let tipRoot = point(tip, 0, 0, 0, hanging: hanging, time: time)
                    XCTAssertEqual(simd_distance(hinge, tipRoot), 0, accuracy: 0.00001)
                }
                let right = point("wingTipR", -6, 0, 0, hanging: hanging, time: time)
                let left = point("wingTipL", 6, 0, 0, hanging: hanging, time: time)
                XCTAssertEqual(left.x, -right.x, accuracy: 0.00001)
                XCTAssertEqual(left.y, right.y, accuracy: 0.00001)
                XCTAssertEqual(left.z, right.z, accuracy: 0.00001)
            }
        }
    }

    func testWingbeatIsContinuousAndHasVisibleUpAndDownStroke() {
        let samples = (0...120).map {
            point("wingTipL", 6, 0, 0, time: Double($0) / 240)
        }
        XCTAssertGreaterThan(samples.map(\.y).max()! - samples.map(\.y).min()!, 0.40)
        XCTAssertEqual(simd_distance(samples.first!, samples.last!), 0, accuracy: 0.00001)
        for index in 1..<samples.count {
            XCTAssertLessThan(simd_distance(samples[index - 1], samples[index]), 0.045)
        }
    }

    func testRoostAnchorUsesCeilingUndersideForFractionalWorldHeight() {
        for y in [12.0, 12.25, -3.4] {
            let offset = floor(y + 1) - y
            let transform = BatPresentation.partMatrix("feet", hanging: true,
                                                       time: 0, ceilingOffset: offset)
            let footTip = transform * SIMD4<Float>(0, -2.0 / 16, 0, 1)
            XCTAssertEqual(Double(footTip.y) + y, floor(y + 1), accuracy: 0.00001)
        }
    }
}
