import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class FirstPersonArmViewportTests: XCTestCase {
    func testOrdinaryItemMotionHasNoArmAndPreservesMirroredFiniteViewportPath() throws {
        // Live Minecraft reference supersedes the ordinary segmented-arm
        // viewport policy. Bow/shield still use the retained anatomical assets.
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let renderer = try String(contentsOf:root.appendingPathComponent("Sources/Elysium/FirstPersonRenderer.swift"),encoding:.utf8)
            .filter { !$0.isWhitespace }
        XCTAssertFalse(renderer.contains("arm(assembly,left:false,"))
        XCTAssertFalse(renderer.contains("arm(transform,left:false,"))
        XCTAssertTrue(renderer.contains("item(mainStack,transform:assembly"))
        registerAllBlocks(); registerAllItems()
        let definition = itemDef(iid("iron_pickaxe"))
        for (width,height) in [(320.0,240.0),(480,270),(800,600),(1920,1080),(2560,1080)] {
            let aspect = Float(width/height)
            let projection = Elysium.mat4Perspective(fovYRad:70 * .pi/180,aspect:aspect,near:0.035,far:12)
            let rightRest = ViewmodelPlacement.item(definition,left:false,aspect:aspect)
            let leftRest = ViewmodelPlacement.item(definition,left:true,aspect:aspect)
            for frame in 0...100 {
                let right = FirstPersonSwing.pose(rest:rightRest,progress:Double(frame)/100,action:.mining,
                    left:false,reducedMotion:false)
                let left = FirstPersonSwing.pose(rest:leftRest,progress:Double(frame)/100,action:.mining,
                    left:true,reducedMotion:false)
                let a = projection * right.columns.3, b = projection * left.columns.3
                XCTAssertTrue([a.x,a.y,a.z,a.w,b.x,b.y,b.z,b.w].allSatisfy(\.isFinite))
                XCTAssertGreaterThan(a.w,0.035); XCTAssertGreaterThan(b.w,0.035)
                XCTAssertEqual(a.x/a.w,-b.x/b.w,accuracy:1e-5)
                XCTAssertEqual(a.y/a.w,b.y/b.w,accuracy:1e-5)
                XCTAssertEqual(simd_determinant(right),1,accuracy:1e-5)
                XCTAssertEqual(simd_determinant(left),1,accuracy:1e-5)
            }
        }
    }

    func testSegmentMeshesActuallyOverlapTheirDocumentedBoneEndpoints() {
        for (data,length): ([Float],Float) in [(FirstPersonModelAssets.forearm,0.40),(FirstPersonModelAssets.upperArm,0.45)] {
            let mesh = ViewmodelMesh(data)
            XCTAssertGreaterThan(mesh.vertices.map(\.position.y).max() ?? -1,0.02)
            XCTAssertLessThan(mesh.vertices.map(\.position.y).min() ?? 1,-length-0.02)
            XCTAssertLessThan(mesh.vertices.map { abs($0.position.x) }.max() ?? 1,0.11)
        }
    }
}
