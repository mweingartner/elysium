import XCTest
@testable import Elysium

final class WaterMeshPartitionTests: XCTestCase {
    func testOnlyCompleteWaterTrianglesUseTheWaterPass() {
        var words: [UInt32] = []
        for animation: UInt32 in [0, 1, 2, 3, 4, 5, 6] {
            for _ in 0..<3 { words += [0, 0, 0, 0, 0, 0, animation << 24] }
        }
        let split = WaterMeshIndices(words: words, indices: Array(0..<21).map(UInt32.init))
        XCTAssertEqual(split.water, [3, 4, 5])
        XCTAssertEqual(split.other, [0, 1, 2] + Array(6..<21).map(UInt32.init))
    }

    func testMalformedOrMixedTrianglesCannotEnterTheWaterPass() {
        let words: [UInt32] = [0,0,0,0,0,0,1 << 24, 0,0,0,0,0,0,0, 0,0,0,0,0,0,1 << 24]
        let split = WaterMeshIndices(words: words, indices: [0,1,2, 0,1,UInt32.max, 2])
        XCTAssertEqual(split.water, [])
        XCTAssertEqual(split.other, [0,1,2])
        XCTAssertEqual(WaterMeshIndices(words: [], indices: []).water, [])
    }
}
