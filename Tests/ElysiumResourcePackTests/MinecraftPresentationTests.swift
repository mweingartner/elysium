import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Broad silhouette checks informed by six native Minecraft 26.2 rest captures
/// on September 12, 2026. These are visibility regressions, not pixel goldens or
/// proof of aesthetic equivalence. Native sequence comparison remains required.
final class MinecraftPresentationTests: XCTestCase {
    private static let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let pack = ResourcePack(url:repository.appendingPathComponent(
        "packaging/Faithful 64x - December 2025 Release.zip"))

    private struct Envelope {
        let left: Float, top: Float, right: Float, bottom: Float
        let coverage: Float
        var width: Float { right-left }
        var height: Float { bottom-top }
        func description(aspect: Float) -> String {
            String(format:"bounds=(%.3f,%.3f)-(%.3f,%.3f), width16:9=%.3f height=%.3f coverage16:9=%.4f",
                   Double(left),Double(top),Double(right),Double(bottom),
                   Double(width*aspect/(16/9)),Double(height),Double(coverage*aspect/(16/9)))
        }
    }

    private struct ReferenceFloor {
        let width: Float, height: Float, coverage: Float, highestTop: Float
        func accepts(_ value: Envelope, aspect: Float) -> Bool {
            let normalization = aspect/(16/9)
            // Account for the 240px raster's edge quantization, not visual drift.
            return value.width*normalization+0.005 >= width && value.height+1/240 >= height
                && value.coverage*normalization+0.0002 >= coverage && value.top-1/240 <= highestTop
        }
    }

    // Reference estimates are intentionally much larger than these lower bounds:
    // tools ~17-22% wide and ~46-70% tall; bread ~20%/55%; log ~35%/28%.
    // Screen width/area normalize to 16:9 because the viewmodel lens fixes vertical FOV.
    private func floor(for name: String) -> ReferenceFloor {
        switch name {
        case "iron_sword": return .init(width:0.13,height:0.40,coverage:0.025,highestTop:0.40)
        case "bread": return .init(width:0.13,height:0.30,coverage:0.035,highestTop:0.68)
        case "spruce_log": return .init(width:0.20,height:0.16,coverage:0.030,highestTop:0.84)
        case "iron_shovel": return .init(width:0.09,height:0.30,coverage:0.018,highestTop:0.70)
        default: return .init(width:0.12,height:0.30,coverage:0.020,highestTop:0.70)
        }
    }

    override func setUp() {
        super.setUp()
        registerAllBlocks(); registerAllItems(); registerAllBiomes()
    }

    private func mesh(_ name: String, profile: ViewmodelProfile? = nil) throws -> ViewmodelMesh {
        let definition = itemDef(iid(name))
        let pack = try XCTUnwrap(Self.pack)
        if let block = definition.block {
            // Opaque log geometry is the actual held-block mesher, with packed
            // surface availability checked; texel colors do not change its silhouette.
            XCTAssertNotNil(pack.file("assets/minecraft/textures/block/\(name).png"))
            return .block(Int(block))
        }
        let data = try XCTUnwrap(pack.file("assets/minecraft/textures/item/\(name).png"))
        return .extruded(try XCTUnwrap(decodePNG(data)),profile:profile ?? ViewmodelProfile.item(definition))
    }

    private func envelope(_ mesh: ViewmodelMesh, pose: simd_float4x4, aspect: Float) -> Envelope {
        // Union real projected triangles, not their bounding box: a clipped
        // sword sliver or the empty space under a pickaxe head cannot count as art.
        let height = 240, width = Int((Float(height)*aspect).rounded())
        let projection = Elysium.mat4Perspective(fovYRad:70 * .pi/180,aspect:aspect,near:0.035,far:12)
        let matrix = projection*pose
        var pixels = [Bool](repeating:false,count:width*height)
        func project(_ vertex: SIMD4<Float>) -> SIMD2<Float>? {
            let p = matrix*vertex
            guard p.w > 0.035, [p.x,p.y,p.z,p.w].allSatisfy(\.isFinite) else { return nil }
            return SIMD2((p.x/p.w+1)*0.5*Float(width),(1-p.y/p.w)*0.5*Float(height))
        }
        func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ p: SIMD2<Float>) -> Float {
            (p.x-a.x)*(b.y-a.y)-(p.y-a.y)*(b.x-a.x)
        }
        for index in stride(from:0,to:mesh.vertices.count,by:3) {
            guard let a = project(mesh.vertices[index].position),
                  let b = project(mesh.vertices[index+1].position),
                  let c = project(mesh.vertices[index+2].position) else {
                XCTFail("actual item triangle reaches the camera/near plane")
                continue
            }
            let area = edge(a,b,c)
            guard abs(area)>1e-6 else { continue }
            let loX = max(0,Int(Foundation.floor(min(a.x,b.x,c.x))))
            let hiX = min(width-1,Int(Foundation.ceil(max(a.x,b.x,c.x))))
            let loY = max(0,Int(Foundation.floor(min(a.y,b.y,c.y))))
            let hiY = min(height-1,Int(Foundation.ceil(max(a.y,b.y,c.y))))
            guard loX<=hiX,loY<=hiY else { continue }
            let sign: Float = area>0 ? 1 : -1
            for y in loY...hiY {
                for x in loX...hiX {
                    let p = SIMD2<Float>(Float(x)+0.5,Float(y)+0.5)
                    if sign*edge(a,b,p)>=0 && sign*edge(b,c,p)>=0 && sign*edge(c,a,p)>=0 {
                        pixels[y*width+x] = true
                    }
                }
            }
        }
        var loX = width,hiX = -1,loY = height,hiY = -1,count = 0
        for index in pixels.indices where pixels[index] {
            let x = index%width,y = index/width
            loX = min(loX,x); hiX = max(hiX,x); loY = min(loY,y); hiY = max(hiY,y); count += 1
        }
        guard count>0 else { return .init(left:1,top:1,right:1,bottom:1,coverage:0) }
        return .init(left:Float(loX)/Float(width),top:Float(loY)/Float(height),
                     right:Float(hiX+1)/Float(width),bottom:Float(hiY+1)/Float(height),
                     coverage:Float(count)/Float(width*height))
    }

    func testActualFaithfulRestSilhouettesHaveUsefulVisibleAreaAcrossAspects() throws {
        for name in ["iron_pickaxe","iron_axe","iron_shovel","iron_sword","bread","spruce_log"] {
            let definition = itemDef(iid(name)), geometry = try mesh(name)
            for aspect: Float in [4/3,16/9,21/9] {
                for left in [false,true] {
                    let pose = ViewmodelPlacement.item(definition,left:left,aspect:aspect)
                    let value = envelope(geometry,pose:pose,aspect:aspect)
                    let detail = "\(name) aspect=\(aspect) left=\(left): \(value.description(aspect:aspect))"
                    print("Minecraft envelope: \(detail)")
                    let limit = floor(for:name), normalization = aspect/(16/9)
                    XCTAssertGreaterThanOrEqual(value.width*normalization+0.005,limit.width,detail)
                    XCTAssertGreaterThanOrEqual(value.height+1/240,limit.height,detail)
                    XCTAssertGreaterThanOrEqual(value.coverage*normalization+0.0002,limit.coverage,detail)
                    XCTAssertLessThanOrEqual(value.top-1/240,limit.highestTop,detail)
                    XCTAssertLessThan(value.coverage*normalization,0.24,"oversized item obscures world: \(detail)")
                    XCTAssertGreaterThan(value.bottom,0.88,"idle item floats away from lower edge: \(detail)")
                }
            }
        }
    }

    func testKnownLowSwordBladeAndTinyFoodCandidateFailsVisibilityFloor() throws {
        let aspect: Float = 16/9
        for name in ["iron_sword","bread"] {
            let food = name == "bread"
            let profile = ViewmodelProfile(action:food ? .eating : .cutting,length:food ? 0.90 : 1.35,
                grip:food ? SIMD2(0.5,0.78) : SIMD2(0.23,0.77),straighten:food ? 0 : .pi/4)
            let depth: Float = food ? 1.05 : 1.10
            let halfHeight = depth*tan(35 * Float.pi/180)
            let x: Float = food ? 0.94 : 0.91, y: Float = food ? 1.05 : 1.04
            let old = vmTranslation(SIMD3((x*2-1)*halfHeight*aspect,(1-y*2)*halfHeight,-depth))
                * vmRotation(SIMD3(-0.08,-0.55,-0.43))
            let value = envelope(try mesh(name,profile:profile),pose:old,aspect:aspect)
            print("Minecraft rejected candidate: \(name): \(value.description(aspect:aspect))")
            XCTAssertFalse(floor(for:name).accepts(value,aspect:aspect),
                "the first candidate places the visible sword tip/food too low: \(name)")
        }
    }

    func testOrdinarySocketsAndSwingMirrorWithoutChangingHandedness() {
        let reflection = simd_float4x4(diagonal:SIMD4(-1,1,1,1))
        for name in ["iron_pickaxe","iron_axe","iron_shovel","iron_sword","bread","spruce_log"] {
            let definition = itemDef(iid(name))
            for aspect: Float in [4/3,16/9,21/9] {
                for progress in [nil,0.06,0.25,0.50,0.75,1] as [Double?] {
                    let a = FirstPersonSwing.pose(rest:ViewmodelPlacement.item(definition,left:false,aspect:aspect),
                        progress:progress,action:ViewmodelProfile.item(definition).action,left:false,reducedMotion:false)
                    let b = FirstPersonSwing.pose(rest:ViewmodelPlacement.item(definition,left:true,aspect:aspect),
                        progress:progress,action:ViewmodelProfile.item(definition).action,left:true,reducedMotion:false)
                    let expected = reflection*a*reflection
                    for column in 0..<4 { XCTAssertEqual(simd_distance(b[column],expected[column]),0,accuracy:1e-5) }
                    XCTAssertEqual(simd_determinant(a),1,accuracy:1e-5)
                    XCTAssertEqual(simd_determinant(b),1,accuracy:1e-5)
                }
            }
        }
    }

    func testHeldAttackRepeatsAtObservedPointTwoSecondCadenceAndCompletesOnRelease() throws {
        XCTAssertEqual(HELD_PRIMARY_ACTION_CYCLE_DURATION,0.20,accuracy:0.0001)
        var state = HeldSwingAnimationState()
        for (time,expected) in [(0.0,0.0),(0.05,0.25),(0.10,0.5),(0.15,0.75),(0.20,0.0),(0.25,0.25)] {
            XCTAssertEqual(try XCTUnwrap(state.observe(primaryHeld:true,engineAttack:0,at:time,eligible:true)),
                           expected,accuracy:0.0001)
        }
        XCTAssertNotNil(state.observe(primaryHeld:false,engineAttack:0,at:0.26,eligible:true))
        XCTAssertNil(state.observe(primaryHeld:false,engineAttack:0,at:0.401,eligible:true))
    }

    func testOrdinaryRendererUsesTargetIndependentSwingBeforeSpecializedRangedOverrides() throws {
        let text = try String(contentsOf:Self.repository.appendingPathComponent("Sources/Elysium/FirstPersonRenderer.swift"),encoding:.utf8)
        let start = try XCTUnwrap(text.range(of:"var assembly = FirstPersonSwing.pose("))
        let end = try XCTUnwrap(text.range(of:"if isUsing",range:start.upperBound..<text.endIndex))
        let ordinaryCall = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(ordinaryCall.contains("ViewmodelPlacement.item(definition"))
        for forbidden in ["target:","workingPoint:","aimedTarget","crosshairBlock","cam.fov"] {
            XCTAssertFalse(ordinaryCall.contains(forbidden),"ordinary motion must not depend on \(forbidden)")
        }
        XCTAssertFalse(text.contains("FirstPersonStrike.pose("))
    }

    func testTridentChargePreservesOrdinaryRestOriginAndCrossbowRetainsDedicatedGrip() throws {
        let source = try String(contentsOf:Self.repository.appendingPathComponent("Sources/Elysium/FirstPersonRenderer.swift"),encoding:.utf8)
            .filter { !$0.isWhitespace }
        // Bind the origin invariant to the real renderer branch, not a helper
        // invocation that could pass while charging still jumps to the old fist.
        XCTAssertTrue(source.contains("ifmainName==\"crossbow\"||(mainName==\"trident\"&&isUsing){"))
        XCTAssertTrue(source.contains("letaimRest=mainName==\"trident\"?ViewmodelPlacement.item(definition,left:false,aspect:aspect,bob:bob):grip(left:false)"))
        XCTAssertTrue(source.contains("assembly=FirstPersonStrike.aimedProp(rest:aimRest,"))
        XCTAssertTrue(source.contains("letaimDepth=mainName==\"trident\"?max(3,rangedDepth):rangedDepth"))

        let definition = itemDef(iid("trident"))
        let tip = FirstPersonStrike.workingPoint(definition,mesh:try mesh("trident"))
        func xyz(_ value: SIMD4<Float>) -> SIMD3<Float> { SIMD3(value.x,value.y,value.z) }
        for aspect: Float in [4/3,16/9,21/9] {
            for bob in [SIMD3<Float>.zero,SIMD3(0.012,-0.009,0.006)] {
                let rest = ViewmodelPlacement.item(definition,left:false,aspect:aspect,bob:bob)
                let oldGrip = ViewmodelPlacement.grip(left:false,logicalWidth:Double(aspect)*540,aspect:aspect,bob:bob)
                XCTAssertGreaterThan(simd_distance(rest.columns.3,oldGrip.columns.3),0.25,
                    "negative control must reproduce the former charge-start translation jump")
                for depth: Float in [3,8,32,64] {
                    for horizontal: Float in [-0.15,0,0.15] {
                        let target = SIMD3<Float>(horizontal,0.05,-depth)
                        let aimed = FirstPersonStrike.aimedProp(rest:rest,muzzle:tip,forward:SIMD3(0,1,0),target:target)
                        XCTAssertEqual(simd_distance(aimed.columns.3,rest.columns.3),0,accuracy:1e-6,
                            "trident must pivot at its displayed rest origin at aspect \(aspect), depth \(depth)")
                        XCTAssertEqual(simd_determinant(aimed),1,accuracy:1e-5)
                        let axis = simd_normalize(xyz(aimed*SIMD4<Float>(0,1,0,0)))
                        let desired = simd_normalize(target-xyz(aimed*SIMD4(tip,1)))
                        XCTAssertGreaterThan(simd_dot(axis,desired),0.99999)
                        for lift in [0.0,0.5,1] {
                            let idle = FirstPersonStrike.equipmentPose(rest,lift:lift)
                            let charging = FirstPersonStrike.equipmentPose(aimed,lift:lift)
                            XCTAssertEqual(simd_distance(idle.columns.3,charging.columns.3),0,accuracy:1e-6)
                        }
                        let crossbow = FirstPersonStrike.aimedProp(rest:oldGrip,muzzle:SIMD3(0,0.15,-0.55),
                            forward:SIMD3(0,0,-1),target:target)
                        XCTAssertEqual(simd_distance(crossbow.columns.3,oldGrip.columns.3),0,accuracy:1e-6,
                            "the crossbow's dedicated origin must remain unchanged")
                    }
                }
            }
        }
    }
}
