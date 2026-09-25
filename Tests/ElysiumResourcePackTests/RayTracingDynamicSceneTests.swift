import Foundation
import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class RayTracingDynamicSceneTests: XCTestCase {
    private func assertMatrixEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            XCTAssertEqual(simd_distance(lhs[column], rhs[column]), 0, accuracy: 0.00001,
                           file: file, line: line)
        }
    }

    func testRigidPartitionPreservesEveryNativeVertexAndAllDinosaurDetail() throws {
        let names = ["player", "pig", "sheep", "horse", "creeper", "bat", "dolphin", "villager",
                     "arrow_model", "boat_model", "minecart_model", "end_crystal_model"]
            + PrehistoricWorldProfile.allCreatureIDs
        for name in names {
            XCTAssertTrue(hasModel(name), name)
            let original = buildEntityGeometry(name)
            let parts = try XCTUnwrap(EntityRigidGeometry.partition(original.verts,
                partCount: min(24, original.model.parts.count)), name)
            XCTAssertEqual(parts.flatMap(\.vertices), original.verts, name)
            XCTAssertEqual(parts.reduce(0) { $0 + $1.vertices.count / 9 }, original.vertexCount, name)
            for part in parts {
                XCTAssertFalse(part.vertices.isEmpty, name)
                XCTAssertEqual(part.vertices.count % 27, 0, name)
                for index in stride(from: 8, to: part.vertices.count, by: 9) {
                    XCTAssertEqual(part.vertices[index], Float(part.partIndex), name)
                }
            }
        }
    }

    func testRigidPartitionRejectsPartialNonFiniteAndMixedPartTriangles() {
        let triangle: [Float] = [0, 0, 0, 0, 1, 0, 0, 0, 0,
                                 1, 0, 0, 0, 1, 0, 1, 0, 0,
                                 0, 0, 1, 0, 1, 0, 0, 1, 0]
        XCTAssertNotNil(EntityRigidGeometry.partition(triangle, partCount: 1))
        XCTAssertNil(EntityRigidGeometry.partition(Array(triangle.dropLast()), partCount: 1))
        XCTAssertNil(EntityRigidGeometry.partition(triangle, partCount: 0))
        XCTAssertNil(EntityRigidGeometry.partition(triangle, partCount: 25))
        XCTAssertNil(EntityRigidGeometry.partition(triangle, partCount: -1))
        for (offset, value): (Int, Float) in [(0, .nan), (3, .infinity), (8, 0.5),
                                            (8, -1), (17, 1), (26, 1)] {
            var invalid = triangle
            invalid[offset] = value
            XCTAssertNil(EntityRigidGeometry.partition(invalid, partCount: 2))
        }
        XCTAssertEqual(EntityRigidGeometry.partition([], partCount: 0)?.count, 0)
    }

    func testCameraRelativeTranslationRetainsSubBlockPrecisionAndFacing() {
        let model = buildEntityGeometry("pig").model
        var pose = EntityPose()
        pose.x = 268_435_456.125; pose.y = 82.75; pose.z = -268_435_456.375
        pose.yaw = 0.7; pose.scale = 0.8
        let origin = SIMD3<Double>(268_435_456, 80, -268_435_456)
        let grown = EntityRendererM.presentation(model: model, pose: pose, time: 4.0, origin: origin)
        XCTAssertEqual(grown.model.columns.3, SIMD4<Float>(0.125, 2.75, -0.375, 1))
        let forward = grown.model * SIMD4<Float>(0, 0, -1, 0)
        let direction = simd_normalize(SIMD3<Float>(forward.x, forward.y, forward.z))
        XCTAssertEqual(direction.x, Float(-sin(pose.yaw)), accuracy: 0.00001)
        XCTAssertEqual(direction.y, 0, accuracy: 0.00001)
        XCTAssertEqual(direction.z, Float(cos(pose.yaw)), accuracy: 0.00001)
        pose.baby = true
        let baby = EntityRendererM.presentation(model: model, pose: pose, time: 4.0, origin: origin)
        for column in 0..<3 {
            XCTAssertEqual(simd_distance(baby.model[column], grown.model[column] * 0.5), 0,
                           accuracy: 0.00001)
        }
        XCTAssertEqual(baby.model.columns.3, grown.model.columns.3)
    }

    func testPartSnapshotsDoNotShareMutableAnimationStorage() throws {
        let model = buildEntityGeometry("player").model
        let arm = try XCTUnwrap(model.parts.firstIndex { $0.name == "armR" })
        var pose = EntityPose()
        pose.limbSwing = 0.2; pose.limbAmp = 1
        let first = EntityRendererM.presentation(model: model, pose: pose, time: 1, origin: .zero)
        let saved = first.parts[arm]
        pose.limbSwing = 2.2
        let second = EntityRendererM.presentation(model: model, pose: pose, time: 2, origin: .zero)
        XCTAssertGreaterThan(simd_distance(first.parts[arm][1], second.parts[arm][1]), 0.1)
        assertMatrixEqual(first.parts[arm], saved)
        XCTAssertEqual(first.parts.count, 24)
        for index in model.parts.count..<24 {
            assertMatrixEqual(first.parts[index], matrix_identity_float4x4)
        }
    }

    func testSharedPresentationKeepsBatAnatomyAndDinosaurActionPoses() throws {
        var batPose = EntityPose()
        batPose.y = 60.3; batPose.hanging = true; batPose.headYaw = 0.2
        let bat = buildEntityGeometry("bat").model
        let batMatrices = EntityRendererM.partTransforms(model: bat, pose: batPose, time: 3.5)
        for (index, part) in bat.parts.enumerated() {
            assertMatrixEqual(batMatrices[index], BatPresentation.partMatrix(part.name, hanging: true,
                time: 3.5, headYaw: 0.2, ceilingOffset: floor(batPose.y + 1) - batPose.y))
        }

        let dinosaur = buildEntityGeometry("prehistoric.triceratops").model
        let head = try XCTUnwrap(dinosaur.parts.firstIndex { $0.name == "head" })
        var dinosaurPose = EntityPose()
        let idle = EntityRendererM.partTransforms(model: dinosaur, pose: dinosaurPose, time: 0)
        dinosaurPose.prehistoricAction = "charge"
        let charging = EntityRendererM.partTransforms(model: dinosaur, pose: dinosaurPose, time: 0)
        XCTAssertGreaterThan(simd_distance(idle[head][1], charging[head][1]), 0.4)
    }

    func testSharedOverlayPreservesHurtFireAndChargedFusePrecedence() {
        let model = buildEntityGeometry("creeper").model
        var pose = EntityPose()
        pose.hurtFlash = 0.8
        var shown = EntityRendererM.presentation(model: model, pose: pose, time: 0, origin: .zero)
        XCTAssertEqual(shown.overlay, SIMD4<Float>(1, 0.2, 0.2, 0.4))
        pose.hurtFlash = 0; pose.onFire = true
        shown = EntityRendererM.presentation(model: model, pose: pose, time: 0, origin: .zero)
        XCTAssertEqual(shown.overlay, SIMD4<Float>(1, 0.45, 0.08, 0.22))
        pose.fuseCharged = true; pose.fuseOverlay = 0.7
        shown = EntityRendererM.presentation(model: model, pose: pose, time: 0, origin: .zero)
        XCTAssertEqual(shown.overlay, SIMD4<Float>(0.55, 0.85, 1, 0.7))
    }

    func testGPUExportUsesIdenticalPartsAndRetainsOldSkinAcrossReset() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Requires Metal device") }
        let renderer = EntityRendererM(device: device)
        var pose = EntityPose()
        pose.x = 128.125; pose.y = 70; pose.z = -65.5
        pose.yaw = 0.35; pose.headYaw = 0.3; pose.limbSwing = 0.8; pose.limbAmp = 0.7
        pose.alpha = 0.6; pose.hurtFlash = 0.3
        let origin = SIMD3<Double>(120, 72, -70)
        for name in ["player", "bat", "prehistoric.tyrannosaurus"] {
            let snapshot = renderer.snapshot(name: name, p: pose, time: 3.0, origin: origin)
            let instances = renderer.rayTracingInstances(snapshot: snapshot)
            XCTAssertFalse(instances.isEmpty)
            let again = renderer.snapshot(name: name, p: pose, time: 3.5, origin: origin)
            XCTAssertTrue(snapshot.geometry === again.geometry)
            for (index, part) in snapshot.geometry.rayTracingParts.enumerated() {
                let instance = instances[index]
                XCTAssertTrue(instance.geometry === part.geometry)
                XCTAssertTrue(instance.geometry.texture === snapshot.geometry.texture)
                XCTAssertEqual(instance.tint, SIMD4<Float>(1, 1, 1, 0.6))
                XCTAssertEqual(instance.overlay, snapshot.matrices.overlay)
                assertMatrixEqual(instance.transform,
                                  snapshot.matrices.model * snapshot.matrices.parts[part.partIndex])
                for vertex in stride(from: 0, to: part.geometry.vertices.count, by: 9) {
                    let data = part.geometry.vertices
                    let point = SIMD4<Float>(data[vertex], data[vertex + 1], data[vertex + 2], 1)
                    // Matches the two matrix multiplies in entity_vs, while
                    // the RT instance stores their composition only once.
                    let raster = snapshot.matrices.model * (snapshot.matrices.parts[part.partIndex] * point)
                    XCTAssertEqual(simd_distance(instance.transform * point, raster), 0, accuracy: 0.00001)
                }
            }
            let oldKeys = instances.map(\.geometry.key)
            renderer.resetSkins()
            let replaced = renderer.snapshot(name: name, p: pose, time: 3.0, origin: origin)
            XCTAssertFalse(snapshot.geometry === replaced.geometry)
            XCTAssertFalse(snapshot.geometry.texture === replaced.geometry.texture)
            XCTAssertNotEqual(oldKeys, renderer.rayTracingInstances(snapshot: replaced).map(\.geometry.key))
            XCTAssertEqual(instances.map(\.geometry.key), oldKeys)
        }
        XCTAssertTrue(renderer.geom("unknown-model") === renderer.geom("pig"))
    }
}
