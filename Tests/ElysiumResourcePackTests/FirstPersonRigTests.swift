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

    func testCanonicalSwingMovesInboardThenDownAndNeverPinsAnImpactPose() throws {
        registerAllBlocks(); registerAllItems()
        let definition = itemDef(iid("iron_pickaxe"))
        let pack = try XCTUnwrap(Self.faithfulPack)
        let data = try XCTUnwrap(pack.file("assets/minecraft/textures/item/iron_pickaxe.png"))
        let mesh = ViewmodelMesh.extruded(try XCTUnwrap(decodePNG(data)),profile:ViewmodelProfile.item(definition))
        let tip = xyz(try XCTUnwrap(mesh.vertices.max { $0.position.y < $1.position.y }).position)
        let rest = ViewmodelPlacement.item(definition,left:false,aspect:16.0/9)
        func pose(_ progress: Double) -> simd_float4x4 {
            FirstPersonSwing.pose(rest:rest,progress:progress,action:.mining,left:false,reducedMotion:false)
        }
        let presented = pose(0.0625), low = pose(0.5625), returning = pose(0.95)
        XCTAssertLessThan(presented.columns.3.x,rest.columns.3.x-0.25)
        XCTAssertGreaterThan(presented.columns.3.y,rest.columns.3.y+0.15)
        XCTAssertLessThan(low.columns.3.y,rest.columns.3.y-0.15)
        XCTAssertLessThan(low.columns.3.z,rest.columns.3.z-0.15)
        XCTAssertLessThan(simd_distance(returning.columns.3,rest.columns.3),
                          simd_distance(low.columns.3,rest.columns.3))
        // Direct Minecraft observation supersedes the old policy that froze the
        // working tip at a projected target throughout phases .43 through .49.
        // Both the grip and actual tip must continue moving across that interval.
        for (a,b) in [(0.43,0.46),(0.46,0.49)] {
            XCTAssertGreaterThan(simd_distance(pose(a).columns.3,pose(b).columns.3),0.01)
            XCTAssertGreaterThan(simd_distance(xyz(pose(a)*SIMD4(tip,1)),xyz(pose(b)*SIMD4(tip,1))),0.01)
        }
        func movesThroughFormerImpact(_ candidate: (Double) -> simd_float4x4) -> Bool {
            simd_distance(candidate(0.43).columns.3,candidate(0.49).columns.3) > 0.02
        }
        XCTAssertTrue(movesThroughFormerImpact(pose))
        XCTAssertFalse(movesThroughFormerImpact { _ in vmTranslation(SIMD3<Float>(0.24,-0.29,-1.13)) },
                       "negative control: the old held contact keyframe fails the movement envelope")
        // Target/FOV inputs are deliberately absent from the API. The tip may
        // naturally cross the reticle during the arc; that is not a regression.
        // Only adaptive target pinning and the fixed impact plateau are retired.
    }

    func testFaithfulAxeAndSwordWorkingEdgesRemainRealSurfacesWithoutContactConstraint() throws {
        registerAllBlocks(); registerAllItems()
        let pack = try XCTUnwrap(Self.faithfulPack)
        for family in ["axe","sword"] {
            let definition = itemDef(iid("iron_\(family)"))
            let image = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file("assets/minecraft/textures/item/iron_\(family).png"))))
            let mesh = ViewmodelMesh.extruded(image,profile:ViewmodelProfile.item(definition))
            let edge = FirstPersonStrike.workingPoint(definition,mesh:mesh)
            XCTAssertTrue(liesOnTriangle(edge,mesh:mesh),"\(family) contact must be an actual exposed mesh surface")
            let rest = ViewmodelPlacement.item(definition,left:false,aspect:16.0/9)
            let stroke = FirstPersonSwing.pose(rest:rest,progress:0.48,action:ViewmodelProfile.item(definition).action,
                left:false,reducedMotion:false)
            XCTAssertEqual(simd_distance(xyz(stroke * SIMD4(edge,1)),xyz(stroke.columns.3)),simd_length(edge),accuracy:1e-5)
            XCTAssertGreaterThan(simd_distance(edge,FirstPersonStrike.workingPoint(definition)),0.03,
                                 "fixture should expose the old guessed-edge discrepancy")
        }
    }

    func testCanonicalSwingMirrorsWholeTransformAndPreservesAuthoredDisplayScale() {
        registerAllBlocks(); registerAllItems()
        let definition = itemDef(iid("iron_pickaxe"))
        let reflection = simd_float4x4(diagonal:SIMD4(-1,1,1,1))
        for scale: Float in [0.65,1,1.35] {
            let rest = ViewmodelPlacement.item(definition,left:false,aspect:16.0/9) * vmScale(scale)
            let mirroredRest = reflection * rest * reflection
            for frame in 0...100 {
                let progress = Double(frame)/100
                let right = FirstPersonSwing.pose(rest:rest,progress:progress,action:.mining,left:false,reducedMotion:false)
                let left = FirstPersonSwing.pose(rest:mirroredRest,progress:progress,action:.mining,left:true,reducedMotion:false)
                let expectedLeft = reflection * right * reflection
                for column in 0..<4 {
                    XCTAssertEqual(simd_distance(left[column],expectedLeft[column]),0,accuracy:1e-5)
                }
                XCTAssertEqual(simd_determinant(right),scale*scale*scale,accuracy:1e-5)
                XCTAssertEqual(simd_determinant(left),scale*scale*scale,accuracy:1e-5)
                for column in 0..<3 {
                    XCTAssertEqual(simd_length(xyz(right[column])),scale,accuracy:1e-5)
                }
            }
        }
    }

    func testTwoBoneRigPreservesLengthsAndSharedEndpointsThroughAllStrikePhases() throws {
        for left in [false,true] {
            for lift in [0.0,0.5,1] {
                let rest = ViewmodelPlacement.grip(left:left,lift:lift,logicalWidth:960,aspect:16.0/9)
                for action in ViewmodelAction.allCases {
                    for frame in 0...100 {
                        let hand = FirstPersonSwing.pose(rest:rest,progress:Double(frame)/100,action:action,
                            left:left,reducedMotion:false)
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

    func testEquipmentLiftRemainsFinalAndCannotBeCancelledBySwing() throws {
        let tip = try authoredProng()
        registerAllBlocks(); registerAllItems()
        let rest = ViewmodelPlacement.item(itemDef(iid("iron_pickaxe")),left:false,aspect:16.0/9)
        for progress in [0.0,0.24,0.43,0.48,0.49,0.85,1] {
            let action = FirstPersonSwing.pose(rest:rest,progress:progress,action:.mining,
                left:false,reducedMotion:false)
            for lift in [0.0,0.5,1] {
                let displayed = FirstPersonStrike.equipmentPose(action,lift:lift)
                let originalTip = xyz(action * SIMD4(tip,1))
                let displayedTip = xyz(displayed * SIMD4(tip,1))
                XCTAssertEqual(simd_distance(displayedTip,originalTip+SIMD3(0,-Float(lift)*1.25,0)),
                               0,accuracy:1e-5,"equipment drop must survive the entire swing and recovery")
                XCTAssertEqual(displayed.columns.0,action.columns.0)
                XCTAssertEqual(displayed.columns.1,action.columns.1)
                XCTAssertEqual(displayed.columns.2,action.columns.2)
            }
        }
        for lift in [-1.0,Double.nan,Double.infinity] {
            XCTAssertEqual(FirstPersonStrike.equipmentPose(rest,lift:lift),rest)
        }
        XCTAssertEqual(FirstPersonStrike.equipmentPose(rest,lift:2),
                       FirstPersonStrike.equipmentPose(rest,lift:1))

        // The helper must own the final screen-space drop in the real renderer,
        // not only pass in isolation while another pose replaces the old rest lift.
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:root.appendingPathComponent("Sources/Elysium/FirstPersonRenderer.swift"),encoding:.utf8)
            .filter { !$0.isWhitespace }
        let poseCall = try XCTUnwrap(source.range(of:"varassembly=FirstPersonSwing.pose("))
        let dropCall = try XCTUnwrap(source.range(of:"assembly=FirstPersonStrike.equipmentPose(assembly,lift:main.lift)"))
        let itemCall = try XCTUnwrap(source.range(of:"item(mainStack,transform:assembly"))
        XCTAssertLessThan(poseCall.lowerBound,dropCall.lowerBound)
        XCTAssertLessThan(dropCall.lowerBound,itemCall.lowerBound)
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

    private var handMeshes: [(FirstPersonHandGrip, ViewmodelMesh)] {
        [(.standard,ViewmodelMesh(FirstPersonModelAssets.handNarrow)),
         (.pickaxe,ViewmodelMesh(FirstPersonModelAssets.hand)),
         (.round,ViewmodelMesh(FirstPersonModelAssets.handRound)),
         (.shield,ViewmodelMesh(FirstPersonModelAssets.handShield)),
         (.draw,ViewmodelMesh(FirstPersonModelAssets.handDraw))]
    }

    func testHandFacingCorrectionPreservesGripWristHaftAndProperHandedness() throws {
        // A correct helper is insufficient if the renderer draws the old hand
        // frame. Bind the semantic regression to the actual hand-only call site.
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let renderer = try String(contentsOf:root.appendingPathComponent("Sources/Elysium/FirstPersonRenderer.swift"),encoding:.utf8)
            .filter { !$0.isWhitespace }
        XCTAssertTrue(renderer.contains(#"draw("hand:\(left):\(handGrip.rawValue)",handGrip.meshTransform(in:transform))"#))
        for left in [false,true] {
            let rest = ViewmodelPlacement.grip(left:left,logicalWidth:960,aspect:16.0/9)
            for progress in [0.0,0.24,0.43,0.48,0.49,0.85,1] {
                let socket = FirstPersonSwing.pose(rest:rest,progress:progress,action:.mining,
                    left:left,reducedMotion:false)
                let bones = FirstPersonArmPose.solve(hand:socket,left:left)
                for (grip,_) in handMeshes {
                    let transform = grip.meshTransform(in:socket)
                    XCTAssertEqual(simd_determinant(transform),1,accuracy:1e-5,grip.rawValue)
                    XCTAssertEqual(transform.columns.3,socket.columns.3,"grip origin must stay fixed")
                    for y: Float in [-0.5,-0.10,0,0.5,1] {
                        XCTAssertEqual(transform * SIMD4(0,y,0,1),socket * SIMD4(0,y,0,1),
                            "\(grip.rawValue): local haft/wrist Y-axis must not change")
                    }
                    let correctedBones = FirstPersonArmPose.solve(hand:transform,left:left)
                    XCTAssertEqual(correctedBones.wrist,bones.wrist)
                    XCTAssertEqual(correctedBones.elbow,bones.elbow)
                    XCTAssertEqual(correctedBones.shoulder,bones.shoulder)
                }
            }
        }
    }

    func testAuthoredDorsalHandSurfaceFacesViewerInRetainedIdleAndGuardPoses() throws {
        for left in [false,true] {
            let rest = ViewmodelPlacement.grip(left:left,logicalWidth:960,aspect:16.0/9)
            // Ordinary held items no longer draw a fist. Preserve the facing
            // contract only for the retained idle/guard hand presentation.
            for guardAmount: Float in [0,1] {
                let socket = rest * vmRotation(SIMD3(0,-0.30*guardAmount,0.10*guardAmount))
                for (grip,source) in handMeshes where grip != .draw {
                    let mesh = left ? source.reflectedX() : source
                    let backZ = try XCTUnwrap(mesh.vertices.map(\.position.z).min())
                    let dorsal = mesh.vertices.filter { abs($0.position.z-backZ)<1e-6 && $0.normal.z < -0.99 }
                    XCTAssertFalse(dorsal.isEmpty,"\(grip.rawValue) must have an authored dorsal -Z surface")
                    guard !dorsal.isEmpty else { continue }
                    let center = dorsal.reduce(SIMD3<Float>.zero) { $0+xyz($1.position) } / Float(dorsal.count)
                    let transform = grip.meshTransform(in:socket)
                    let normal = simd_normalize(xyz(transform * SIMD4(0,0,-1,0)))
                    let towardViewer = simd_normalize(-xyz(transform * SIMD4(center,1)))
                    XCTAssertGreaterThan(simd_dot(normal,towardViewer),0,
                        "\(grip.rawValue), left=\(left), guard=\(guardAmount): dorsal face must face the camera")
                    let oldNormal = simd_normalize(xyz(socket * SIMD4(0,0,-1,0)))
                    let oldTowardViewer = simd_normalize(-xyz(socket * SIMD4(center,1)))
                    XCTAssertLessThan(simd_dot(oldNormal,oldTowardViewer),0,
                        "negative control must reproduce the former palm/fingers-facing-player orientation")
                }
            }
        }
    }

    func testBowDrawingHandKeepsExactStringContactAndAuthoredOrientation() {
        let contact = FirstPersonModelAssets.handDrawStringContact
        let stringAxis = FirstPersonModelAssets.handDrawStringAxis
        for draw: Float in [0,0.25,0.5,0.75,1] {
            let socket = vmTranslation(SIMD3(0.12+draw*0.25,-0.21,-1.30+draw*0.36))
                * vmRotation(SIMD3(0.30*draw,-0.45,0.70*draw))
            let transform = FirstPersonHandGrip.draw.meshTransform(in:socket)
            XCTAssertEqual(transform,socket,"the split-finger draw hand has its own authored contact pose")
            XCTAssertEqual(transform * SIMD4(contact,1),socket * SIMD4(contact,1))
            XCTAssertEqual(transform * SIMD4(stringAxis,0),socket * SIMD4(stringAxis,0))
            let wrong = FirstPersonHandGrip.standard.meshTransform(in:socket)
            XCTAssertGreaterThan(simd_distance(xyz(wrong * SIMD4(contact,1)),xyz(socket * SIMD4(contact,1))),0.08,
                "applying the ordinary gripping-hand turn would visibly detach the string contact")
        }
    }

    func testHandFacingTurnAndLeftReflectionPreserveActualTriangleWinding() throws {
        for left in [false,true] {
            let rest = ViewmodelPlacement.grip(left:left,logicalWidth:960,aspect:16.0/9)
            for progress in [0.0,0.48] {
                let socket = FirstPersonSwing.pose(rest:rest,progress:progress,action:.mining,
                    left:left,reducedMotion:false)
                for (grip,source) in handMeshes {
                    let mesh = left ? source.reflectedX() : source
                    let transform = grip.meshTransform(in:socket)
                    for index in stride(from:0,to:mesh.vertices.count,by:3) {
                        let a = xyz(transform * mesh.vertices[index].position)
                        let b = xyz(transform * mesh.vertices[index+1].position)
                        let c = xyz(transform * mesh.vertices[index+2].position)
                        let normal = xyz(transform * mesh.vertices[index].normal)
                        let area = simd_cross(b-a,c-a)
                        XCTAssertGreaterThan(simd_length(area),1e-10)
                        XCTAssertGreaterThan(simd_dot(area,normal),0,
                            "\(grip.rawValue), left=\(left), triangle=\(index/3): winding must agree with outward normal")
                    }
                }
            }
        }
    }
}
