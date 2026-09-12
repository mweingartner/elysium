import simd
import XCTest
@testable import Elysium

final class FirstPersonSpecialItemMeshTests: XCTestCase {
    private func assertValid(_ mesh: ViewmodelMesh, name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(mesh.vertices.isEmpty,name,file:file,line:line)
        XCTAssertLessThan(mesh.vertices.count,10_000,name,file:file,line:line)
        XCTAssertEqual(mesh.vertices.count%3,0,name,file:file,line:line)
        for v in mesh.vertices {
            XCTAssertTrue([v.position.x,v.position.y,v.position.z,v.normal.x,v.normal.y,v.normal.z,
                           v.color.x,v.color.y,v.color.z,v.color.w].allSatisfy(\.isFinite),name,file:file,line:line)
            XCTAssertLessThan(simd_length(SIMD3(v.position.x,v.position.y,v.position.z)),1,name,file:file,line:line)
            XCTAssertEqual(v.position.w,1,name,file:file,line:line)
            XCTAssertEqual(v.normal.w,0,name,file:file,line:line)
            XCTAssertEqual(simd_length(SIMD3(v.normal.x,v.normal.y,v.normal.z)),1,
                           accuracy:0.00001,name,file:file,line:line)
            XCTAssertTrue([v.color.x,v.color.y,v.color.z,v.color.w].allSatisfy { (0...1).contains($0) },
                          name,file:file,line:line)
            XCTAssertLessThan(v.surface.z,0,"native props must not reference an unrelated inventory atlas slice",
                              file:file,line:line)
        }
        for i in stride(from:0,to:mesh.vertices.count,by:3) {
            let a=mesh.vertices[i],b=mesh.vertices[i+1],c=mesh.vertices[i+2]
            let ab=b.position-a.position,ac=c.position-a.position
            let cross=simd_cross(SIMD3(ab.x,ab.y,ab.z),SIMD3(ac.x,ac.y,ac.z))
            XCTAssertGreaterThan(simd_dot(cross,SIMD3(a.normal.x,a.normal.y,a.normal.z)),0,
                                 name,file:file,line:line)
        }
        XCTAssertGreaterThan(Set(mesh.vertices.map(\.color)).count,5,
                             "keep authored material and grain detail",file:file,line:line)
    }

    func testCrossbowAndWandAreFiniteDetailedOutwardWoundMeshes() {
        assertValid(.crossbow(),name:"crossbow")
        assertValid(.flyingWand(),name:"flying wand")
        assertValid(ViewmodelMesh.crossbow().reflectedX(),name:"reflected crossbow")
    }

    func testCrossbowGripRunsVerticallyWhileStockAimsIntoWorld() {
        let mesh=ViewmodelMesh.crossbow()
        let grip=mesh.vertices.filter { abs($0.position.y-0.115)<0.00001 || abs($0.position.y+0.115)<0.00001 }
            .filter { abs($0.position.x)<=0.03501 && abs($0.position.z)<=0.02751 }
        XCTAssertFalse(grip.isEmpty)
        XCTAssertEqual(grip.map(\.position.x).min() ?? 1,-0.035,accuracy:0.00001)
        XCTAssertEqual(grip.map(\.position.x).max() ?? -1,0.035,accuracy:0.00001)
        XCTAssertEqual(grip.map(\.position.z).min() ?? 1,-0.0275,accuracy:0.00001)
        XCTAssertEqual(grip.map(\.position.z).max() ?? -1,0.0275,accuracy:0.00001)
        XCTAssertLessThan(mesh.vertices.map(\.position.z).min() ?? 0,-0.5)
        XCTAssertGreaterThan(mesh.vertices.map(\.position.x).max() ?? 0,0.35)
        XCTAssertLessThan(mesh.vertices.map(\.position.x).min() ?? 0,-0.35)
        XCTAssertLessThan(mesh.vertices.map(\.position.z).max() ?? 1,0.3,
                          "the long muzzle must point -Z, not back toward the player")
    }

    func testWandShaftSharesOneStraightGripAxisWithItsCrown() {
        let mesh=ViewmodelMesh.flyingWand()
        let shaft=mesh.vertices.filter { abs($0.position.y-0.50)<0.00001 || abs($0.position.y+0.13)<0.00001 }
            .filter { abs($0.position.x)<=0.03501 && abs($0.position.z)<=0.02401 }
        XCTAssertFalse(shaft.isEmpty)
        XCTAssertEqual(shaft.map(\.position.x).min() ?? 1,-0.035,accuracy:0.00001)
        XCTAssertEqual(shaft.map(\.position.x).max() ?? -1,0.035,accuracy:0.00001)
        XCTAssertEqual(shaft.map(\.position.z).min() ?? 1,-0.024,accuracy:0.00001)
        XCTAssertEqual(shaft.map(\.position.z).max() ?? -1,0.024,accuracy:0.00001)
        let crown=mesh.vertices.filter { $0.position.y>0.635 }
        XCTAssertFalse(crown.isEmpty)
        XCTAssertEqual((crown.map(\.position.x).min() ?? 1)+(crown.map(\.position.x).max() ?? 1),0,
                       accuracy:0.00001)
        XCTAssertEqual((crown.map(\.position.z).min() ?? 1)+(crown.map(\.position.z).max() ?? 1),0,
                       accuracy:0.00001)
        XCTAssertGreaterThan(mesh.vertices.map(\.position.y).max() ?? 0,0.65)
    }
}
