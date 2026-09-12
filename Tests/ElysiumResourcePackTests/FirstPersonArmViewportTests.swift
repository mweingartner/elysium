import simd
import XCTest
@testable import Elysium

final class FirstPersonArmViewportTests: XCTestCase {
    func testSegmentedShoulderCapStaysOutsideViewportThroughoutLiveStrike() throws {
        let mesh = ViewmodelMesh(FirstPersonModelAssets.upperArm)
        let lowest = try XCTUnwrap(mesh.vertices.map(\.position.y).min())
        let cap = Set(mesh.vertices.filter { abs($0.position.y-lowest)<1e-6 }.map(\.position))
        XCTAssertLessThan(lowest,-0.45)
        for (width,height) in [(320.0,240.0),(480,270),(800,600),(1920,1080),(2560,1080)] {
            let aspect = Float(width/height)
            let projection = Elysium.mat4Perspective(fovYRad:70 * .pi/180,aspect:aspect,near:0.035,far:12)
            for left in [false,true] {
                let rest = ViewmodelPlacement.grip(left:left,logicalWidth:width,aspect:aspect,bob:SIMD3(0.02,0.025,0.02))
                for frame in 0...100 {
                    let hand = FirstPersonStrike.pose(rest:rest,progress:Double(frame)/100,action:.mining,
                        workingPoint:SIMD3(-0.31,0.56,0),target:SIMD3(0,0,-1.75),reducedMotion:false)
                    let bones = FirstPersonArmPose.solve(hand:hand,left:left)
                    for point in cap {
                        var local = point; if left { local.x *= -1 }
                        let clip = projection * bones.upperArm * local
                        XCTAssertTrue(clip.y < -clip.w || abs(clip.x) > clip.w,
                            "visible shoulder cap phase=\(frame), left=\(left), \(width)x\(height)")
                    }
                }
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
