import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class FirstPersonRigTests: XCTestCase {
    private static let faithfulPack: ResourcePack? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return ResourcePack(url: root.appendingPathComponent("packaging/Faithful 64x - December 2025 Release.zip"))
    }()

    private func xyz(_ p: SIMD4<Float>) -> SIMD3<Float> { SIMD3(p.x,p.y,p.z) }

    private func authoredProng() throws -> SIMD3<Float> {
        let mesh = ViewmodelMesh(FirstPersonModelAssets.pickaxe)
        let leftBottom = mesh.vertices.filter { $0.position.x < -0.2 && $0.normal.y < -0.99 }
        let bottom = try XCTUnwrap(leftBottom.map(\.position.y).min())
        let edge = leftBottom.filter { abs($0.position.y-bottom) < 1e-6 }.map { xyz($0.position) }
        let first = try XCTUnwrap(edge.first)
        let low = edge.reduce(first) { simd_min($0,$1) }, high = edge.reduce(first) { simd_max($0,$1) }
        return (low+high)*0.5*(0.98/0.85)+SIMD3(0,0.05,0)
    }

    private func liesOnTriangle(_ point: SIMD3<Float>, mesh: ViewmodelMesh) -> Bool {
        for offset in stride(from: 0,to: mesh.vertices.count,by: 3) {
            let a = xyz(mesh.vertices[offset].position), b = xyz(mesh.vertices[offset+1].position)
            let c = xyz(mesh.vertices[offset+2].position)
            let ab = b-a, ac = c-a, ap = point-a
            let normal = simd_cross(ab,ac), area = simd_length(normal)
            guard area > 1e-10, abs(simd_dot(ap,normal))/area < 1e-5 else { continue }
            let aa = simd_dot(ab,ab), bb = simd_dot(ac,ac), cross = simd_dot(ab,ac)
            let denominator = aa*bb-cross*cross
            guard denominator > 1e-12 else { continue }
            let u = (bb*simd_dot(ap,ab)-cross*simd_dot(ap,ac))/denominator
            let v = (aa*simd_dot(ap,ac)-cross*simd_dot(ap,ab))/denominator
            if u >= -1e-4 && v >= -1e-4 && u+v <= 1.0001 { return true }
        }
        return false
    }

    func testPickaxeWorkingPointComesFromActualLowestExposedProng() throws {
        registerAllBlocks(); registerAllItems()
        let tip = try authoredProng()
        XCTAssertEqual(simd_distance(tip,FirstPersonStrike.workingPoint(itemDef(iid("iron_pickaxe")))),0,accuracy:1e-6)
        XCTAssertLessThan(tip.x,-0.3)
        XCTAssertGreaterThan(tip.y,0.56)
    }

    func testActualProngMeetsProjectedTargetAtNearFarAndDifferentFOVs() throws {
        let tip = try authoredProng()
        for fov in [50.0,70,110] {
            var cam = CamState(); cam.fov = fov
            for aspect: Float in [0.75,16.0/9,2.37] {
                let rest = ViewmodelPlacement.grip(left:false,logicalWidth:960,aspect:aspect)
                let projection = Elysium.mat4Perspective(fovYRad:70 * .pi/180,aspect:aspect,near:0.035,far:12)
                for distance in [0.2,2.0,5] {
                    let world = try XCTUnwrap(FirstPersonTarget.project(worldPoint:SIMD3(-0.03,0.02,distance),cam:cam,aspect:aspect))
                    let proxy = try XCTUnwrap(FirstPersonTarget.viewmodelPoint(ndc:world.ndc,worldDepth:world.depth,
                        depthRange:1.60...1.85,aspect:aspect))
                    let impact = FirstPersonStrike.pose(rest:rest,progress:0.48,action:.mining,
                        workingPoint:tip,target:proxy,reducedMotion:false)
                    let actual = impact * SIMD4(tip,1)
                    XCTAssertEqual(simd_distance(xyz(actual),proxy),0,accuracy:1e-5)
                    let clip = projection * actual
                    XCTAssertEqual(clip.x/clip.w,world.ndc.x,accuracy:1e-5)
                    XCTAssertEqual(clip.y/clip.w,world.ndc.y,accuracy:1e-5)
                    XCTAssertEqual(simd_determinant(impact),1,accuracy:1e-5)
                }
            }
        }
        let rest = ViewmodelPlacement.grip(left:false,logicalWidth:960,aspect:16.0/9)
        let oldImpact = rest * vmTranslation(SIMD3(-0.15,-0.035,-0.24)) * vmRotation(SIMD3(-1,-0.10,0.18))
        let projection = Elysium.mat4Perspective(fovYRad:70 * .pi/180,aspect:16.0/9,near:0.035,far:12)
        let oldClip = projection * oldImpact * SIMD4(tip,1)
        XCTAssertGreaterThan(simd_length(SIMD2(oldClip.x/oldClip.w,oldClip.y/oldClip.w)),0.05,
                             "the frozen old stroke must demonstrably miss the real center target")
    }

    func testFaithfulAxeAndSwordWorkingEdgesAreRealSurfacesAndReachImpact() throws {
        registerAllBlocks(); registerAllItems()
        let pack = try XCTUnwrap(Self.faithfulPack)
        for family in ["axe","sword"] {
            let definition = itemDef(iid("iron_\(family)"))
            let image = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file("assets/minecraft/textures/item/iron_\(family).png"))))
            let mesh = ViewmodelMesh.extruded(image,profile:ViewmodelProfile.item(definition))
            let edge = FirstPersonStrike.workingPoint(definition,mesh:mesh)
            XCTAssertTrue(liesOnTriangle(edge,mesh:mesh),"\(family) contact must be an actual exposed mesh surface")
            let target = SIMD3<Float>(0.04,-0.03,-1.7)
            let rest = ViewmodelPlacement.grip(left:false,logicalWidth:960,aspect:16.0/9)
            let impact = FirstPersonStrike.pose(rest:rest,progress:0.48,action:ViewmodelProfile.item(definition).action,
                workingPoint:edge,target:target,reducedMotion:false)
            XCTAssertEqual(simd_distance(xyz(impact * SIMD4(edge,1)),target),0,accuracy:1e-5)
            XCTAssertGreaterThan(simd_distance(edge,FirstPersonStrike.workingPoint(definition)),0.03,
                                 "fixture should expose the old guessed-edge discrepancy")
        }
    }

    func testTwoBoneRigPreservesLengthsAndSharedEndpointsThroughAllStrikePhases() throws {
        let tip = try authoredProng()
        for left in [false,true] {
            for lift in [0.0,0.5,1] {
                let rest = ViewmodelPlacement.grip(left:left,lift:lift,logicalWidth:960,aspect:16.0/9)
                for action in ViewmodelAction.allCases {
                    for frame in 0...100 {
                        let hand = FirstPersonStrike.pose(rest:rest,progress:Double(frame)/100,action:action,
                            workingPoint:tip,target:SIMD3(0,0,-1.75),reducedMotion:false)
                        let rig = FirstPersonArmPose.solve(hand:hand,left:left)
                        XCTAssertEqual(simd_distance(rig.wrist,rig.elbow),0.40,accuracy:1e-5)
                        XCTAssertEqual(simd_distance(rig.elbow,rig.shoulder),0.45,accuracy:1e-5)
                        XCTAssertEqual(simd_distance(xyz(rig.forearm * SIMD4(0,-0.40,0,1)),rig.elbow),0,accuracy:1e-5)
                        XCTAssertEqual(simd_distance(xyz(rig.upperArm * SIMD4(0,0,0,1)),rig.elbow),0,accuracy:1e-5)
                        XCTAssertEqual(simd_distance(xyz(rig.upperArm * SIMD4(0,-0.45,0,1)),rig.shoulder),0,accuracy:1e-5)
                        XCTAssertEqual(simd_distance(xyz(hand * SIMD4(0,-0.10,0,1)),rig.wrist),0,accuracy:1e-5)
                        XCTAssertEqual(simd_determinant(rig.forearm),1,accuracy:1e-5)
                        XCTAssertEqual(simd_determinant(rig.upperArm),1,accuracy:1e-5)
                    }
                }
            }
        }
    }

    func testEquipmentLiftCannotBeCancelledByTargetContact() throws {
        let tip = try authoredProng()
        let target = SIMD3<Float>(0.02,-0.01,-1.75)
        let rest = ViewmodelPlacement.grip(left:false,logicalWidth:960,aspect:16.0/9)
        for progress in [0.0,0.24,0.43,0.48,0.49,0.85,1] {
            let action = FirstPersonStrike.pose(rest:rest,progress:progress,action:.mining,
                workingPoint:tip,target:target,reducedMotion:false)
            for lift in [0.0,0.5,1] {
                let displayed = FirstPersonStrike.equipmentPose(action,lift:lift)
                let originalTip = xyz(action * SIMD4(tip,1))
                let displayedTip = xyz(displayed * SIMD4(tip,1))
                XCTAssertEqual(simd_distance(displayedTip,originalTip+SIMD3(0,-Float(lift)*1.25,0)),
                               0,accuracy:1e-5,"equipment drop must survive contact and recovery")
                XCTAssertEqual(displayed.columns.0,action.columns.0)
                XCTAssertEqual(displayed.columns.1,action.columns.1)
                XCTAssertEqual(displayed.columns.2,action.columns.2)
                if progress == 0.48 {
                    XCTAssertEqual(displayedTip.y,target.y-Float(lift)*1.25,accuracy:1e-5,
                                   "a fully lowered item must not jump back to the contact target")
                }
            }
        }
        for lift in [-1.0,Double.nan,Double.infinity] {
            XCTAssertEqual(FirstPersonStrike.equipmentPose(rest,lift:lift),rest)
        }
        XCTAssertEqual(FirstPersonStrike.equipmentPose(rest,lift:2),
                       FirstPersonStrike.equipmentPose(rest,lift:1))

        // The helper must own the final screen-space drop in the real renderer,
        // not only pass in isolation while target solving cancels the old rest lift.
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:root.appendingPathComponent("Sources/Elysium/FirstPersonRenderer.swift"),encoding:.utf8)
            .filter { !$0.isWhitespace }
        let poseCall = try XCTUnwrap(source.range(of:"varassembly=FirstPersonStrike.pose(rest:grip(left:false),"))
        let dropCall = try XCTUnwrap(source.range(of:"assembly=FirstPersonStrike.equipmentPose(assembly,lift:main.lift)"))
        let handCall = try XCTUnwrap(source.range(of:"arm(assembly,left:false,"))
        XCTAssertLessThan(poseCall.lowerBound,dropCall.lowerBound)
        XCTAssertLessThan(dropCall.lowerBound,handCall.lowerBound)
    }

    func testAimDepthSmoothsWithoutChangingProjectedTargetAndHandlesClockDiscontinuity() throws {
        var state = FirstPersonAimDepth()
        XCTAssertEqual(state.observe(1.60,at:0),1.60)
        let halfway = state.observe(1.85,at:0.06)
        XCTAssertEqual(halfway,1.60+0.25*Float(1-exp(-1.0)),accuracy:1e-6)
        let target = SIMD2<Float>(0.12,-0.08)
        let point = try XCTUnwrap(FirstPersonTarget.viewmodelPoint(ndc:target,worldDepth:halfway,
            depthRange:1.60...1.85,aspect:16.0/9))
        let clip = Elysium.mat4Perspective(fovYRad:70 * .pi/180,aspect:16.0/9,near:0.035,far:12) * SIMD4(point,1)
        XCTAssertEqual(clip.x/clip.w,target.x,accuracy:1e-6)
        XCTAssertEqual(clip.y/clip.w,target.y,accuracy:1e-6)
        XCTAssertEqual(state.observe(.nan,at:0.07),halfway)
        XCTAssertEqual(state.observe(1.7,at:-1),1.7)
        XCTAssertEqual(state.observe(1.8,at:.nan),1.7)
    }

    private func assertAimedProp(muzzle: SIMD3<Float>, forward: SIMD3<Float>, label: String,
                                 depths: [Float] = [2,3,8,32,64],
                                 file: StaticString = #filePath, line: UInt = #line) {
        for left in [false,true] {
            let rest = ViewmodelPlacement.grip(left:left,logicalWidth:960,aspect:16.0/9)
            for depth in depths {
                for offset: Float in [-0.25,0,0.25] {
                    let target = SIMD3<Float>(offset,0.08,-depth)
                    let aimed = FirstPersonStrike.aimedProp(rest:rest,muzzle:muzzle,forward:forward,target:target)
                    let tip = xyz(aimed * SIMD4(muzzle,1))
                    let axis = simd_normalize(xyz(aimed * SIMD4(forward,0)))
                    let desired = simd_normalize(target-tip)
                    XCTAssertEqual(simd_distance(aimed.columns.3,rest.columns.3),0,accuracy:1e-6,
                                   "\(label) must pivot at its retained grip",file:file,line:line)
                    XCTAssertEqual(simd_determinant(aimed),1,accuracy:1e-5,file:file,line:line)
                    XCTAssertGreaterThan(simd_dot(axis,desired),0.99999,
                        "\(label) points away from target depth=\(depth),offset=\(offset),left=\(left)",file:file,line:line)
                    XCTAssertLessThan(simd_length(simd_cross(axis,desired)),0.003,
                        "\(label) muzzle ray misses target depth=\(depth),offset=\(offset),left=\(left)",file:file,line:line)
                }
            }
        }
    }

    func testCrossbowAimedPropAlignsMuzzleRayWhileRetainingGripAndHandedness() {
        assertAimedProp(muzzle:SIMD3(0,0.15,-0.55),forward:SIMD3(0,0,-1),label:"crossbow")
    }

    func testTridentAimedPropAlignsActualFaithfulTipWhileRetainingGripAndHandedness() throws {
        registerAllBlocks(); registerAllItems()
        let definition = itemDef(iid("trident"))
        let pack = try XCTUnwrap(Self.faithfulPack)
        let image = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file("assets/minecraft/textures/item/trident.png"))))
        let mesh = ViewmodelMesh.extruded(image,profile:ViewmodelProfile.item(definition))
        let tip = FirstPersonStrike.workingPoint(definition,mesh:mesh)
        assertAimedProp(muzzle:tip,forward:SIMD3(0,1,0),label:"trident",depths:[3,8,32,64])
        // A target inside the authored tip radius has no forward-ray solution
        // while preserving grip. Runtime uses >=3m proxy depth for this prop;
        // the helper still must fail safely if passed this impossible near case.
        let rest = ViewmodelPlacement.grip(left:false,logicalWidth:960,aspect:16.0/9)
        let tooClose = SIMD3<Float>(rest.columns.3.x,rest.columns.3.y,-2)
        XCTAssertLessThan(simd_distance(tooClose,xyz(rest.columns.3)),simd_length(tip))
        let fallback = FirstPersonStrike.aimedProp(rest:rest,muzzle:tip,forward:SIMD3(0,1,0),target:tooClose)
        XCTAssertEqual(simd_distance(fallback.columns.3,rest.columns.3),0,accuracy:1e-6)
        XCTAssertEqual(simd_determinant(fallback),1,accuracy:1e-5)
        for column in 0..<4 {
            XCTAssertTrue([fallback[column].x,fallback[column].y,fallback[column].z,fallback[column].w].allSatisfy(\.isFinite))
        }
    }
}
