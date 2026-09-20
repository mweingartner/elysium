import XCTest
@testable import ElysiumCore

final class FenceGateRenderingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private let air: CellGetter = { _, _, _ in Int(cell(B.air)) }

    private func boxes(_ gateID: Int, meta: Int, collision: Bool = false,
                       get: CellGetter? = nil) -> [AABB] {
        var result: [AABB] = []
        shapeBoxes(Int(cell(UInt16(gateID), meta)), get ?? air, &result, collision)
        return result
    }

    private func leafUprights(_ boxes: [AABB]) -> [AABB] {
        boxes.filter { $0.y0 == 6.0 / 16 && $0.y1 == 15.0 / 16 }
    }

    private func renderedVertexCount(_ gateID: Int, meta: Int) -> Int {
        let paddedSide = 18
        var cells = [UInt16](repeating: cell(B.air), count: paddedSide * paddedSide * paddedSide)
        let center = ((8 + 1) * paddedSide + (8 + 1)) * paddedSide + (8 + 1)
        cells[center] = cell(UInt16(gateID), meta)
        let mesh = buildSectionMesh(MeshInput(
            blocks: cells,
            skyLight: [UInt8](repeating: 15, count: cells.count),
            blockLight: [UInt8](repeating: 0, count: cells.count),
            biomes: [UInt8](repeating: 0, count: paddedSide * paddedSide),
            noMerge: true,
            renderContext: .procedural
        ))
        return mesh.opaque.count + mesh.cutout.count + mesh.translucent.count
    }

    func testEveryRegisteredWoodGateHasCanonicalClosedAndOpenGeometry() {
        for wood in WOODS {
            let gateID = Int(bid("\(wood)_fence_gate"))
            XCTAssertEqual(blockDefs[gateID].shape, .fenceGate, wood)
            let expectedTexture = wood == "bamboo" ? "bamboo_fence_gate" : "\(wood)_planks"
            XCTAssertEqual(tileName(Int(blockDefs[gateID].tex[0])), expectedTexture, wood)

            for meta in 0..<16 {
                let renderBoxes = boxes(gateID, meta: meta)
                XCTAssertEqual(renderBoxes.count, 8, "\(wood), meta \(meta) must retain every gate rail and upright")
                XCTAssertGreaterThan(renderedVertexCount(gateID, meta: meta), 0,
                                 "\(wood), meta \(meta) must reach the live block mesher")

                let collisionBoxes = boxes(gateID, meta: meta, collision: true)
                if meta & 4 == 0 {
                    XCTAssertEqual(collisionBoxes.count, 1, "\(wood), closed meta \(meta)")
                    XCTAssertEqual(collisionBoxes[0].y1, 1.5, "\(wood), closed meta \(meta)")
                } else {
                    XCTAssertTrue(collisionBoxes.isEmpty, "\(wood), open meta \(meta) must not block passage")
                }
            }
        }
    }

    func testBambooGateHasAProceduralFallbackPainter() {
        let atlas = buildAtlas()
        XCTAssertFalse(atlas.missing.contains("bamboo_fence_gate"),
                       "the default atlas must not fall back when Faithful is unavailable")
    }

    func testOpenGateLeavesFoldTowardTheirStoredFacing() {
        let gateID = Int(bid("oak_fence_gate"))
        for facing in 0..<4 {
            let leaves = leafUprights(boxes(gateID, meta: facing | 4))
            XCTAssertEqual(leaves.count, 2, "open facing \(facing) must have two leaf uprights")
            switch facing {
            case 0:
                XCTAssertTrue(leaves.allSatisfy { $0.z1 <= 3.0 / 16 }, "north opens toward -Z")
            case 1:
                XCTAssertTrue(leaves.allSatisfy { $0.z0 >= 13.0 / 16 }, "south opens toward +Z")
            case 2:
                XCTAssertTrue(leaves.allSatisfy { $0.x1 <= 3.0 / 16 }, "west opens toward -X")
            default:
                XCTAssertTrue(leaves.allSatisfy { $0.x0 >= 13.0 / 16 }, "east opens toward +X")
            }
        }
    }

    func testClosedGatePlaneMatchesItsFacingAxis() {
        let gateID = Int(bid("oak_fence_gate"))
        for facing in 0..<4 {
            let rails = boxes(gateID, meta: facing).filter {
                ($0.y0 == 6.0 / 16 && $0.y1 == 9.0 / 16)
                    || ($0.y0 == 12.0 / 16 && $0.y1 == 15.0 / 16)
            }
            XCTAssertEqual(rails.count, 4, "closed facing \(facing) must have four rails")
            if facing < 2 {
                XCTAssertTrue(rails.allSatisfy { ($0.x1 - $0.x0) == 4.0 / 16 && ($0.z1 - $0.z0) == 2.0 / 16 })
            } else {
                XCTAssertTrue(rails.allSatisfy { ($0.x1 - $0.x0) == 2.0 / 16 && ($0.z1 - $0.z0) == 4.0 / 16 })
            }
        }
    }

    func testWallConnectedGateUsesTheLowerCanonicalModelWithoutChangingCollision() {
        let gateID = Int(bid("oak_fence_gate"))
        let wall = cell(bid("cobblestone_wall"))
        for facing in 0..<4 {
            for openBit in [0, 4] {
                let meta = facing | openBit
                let normal = boxes(gateID, meta: meta)
                let flaggedInWall = boxes(gateID, meta: meta | 8)
                XCTAssertEqual(normal.count, flaggedInWall.count)
                for (normalBox, loweredBox) in zip(normal, flaggedInWall) {
                    XCTAssertEqual(loweredBox.x0, normalBox.x0)
                    XCTAssertEqual(loweredBox.x1, normalBox.x1)
                    XCTAssertEqual(loweredBox.z0, normalBox.z0)
                    XCTAssertEqual(loweredBox.z1, normalBox.z1)
                    XCTAssertEqual(loweredBox.y0, normalBox.y0 - 3.0 / 16)
                    XCTAssertEqual(loweredBox.y1, normalBox.y1 - 3.0 / 16)
                }

                let wallAtGateEnds: CellGetter = { dx, _, dz in
                    let connected = facing < 2 ? (dx == -1 || dx == 1) : (dz == -1 || dz == 1)
                    return connected ? Int(wall) : Int(cell(B.air))
                }
                let derivedInWall = boxes(gateID, meta: meta, get: wallAtGateEnds)
                XCTAssertEqual(derivedInWall.map(\.y0), flaggedInWall.map(\.y0), "facing \(facing)")
                XCTAssertEqual(derivedInWall.map(\.y1), flaggedInWall.map(\.y1), "facing \(facing)")

                let wallOnWrongAxis: CellGetter = { dx, _, dz in
                    let unconnected = facing < 2 ? (dz == -1 || dz == 1) : (dx == -1 || dx == 1)
                    return unconnected ? Int(wall) : Int(cell(B.air))
                }
                let wrongAxis = boxes(gateID, meta: meta, get: wallOnWrongAxis)
                XCTAssertEqual(wrongAxis.map(\.y0), normal.map(\.y0), "facing \(facing)")
                XCTAssertEqual(wrongAxis.map(\.y1), normal.map(\.y1), "facing \(facing)")
                XCTAssertEqual(boxes(gateID, meta: meta, collision: true).count,
                               boxes(gateID, meta: meta | 8, collision: true).count)
            }
        }
    }

    func testFenceGateTogglePreservesAxisExceptWhenOpenedFromBehind() {
        for storedFacing in 0..<4 {
            for playerFacing in 0..<4 {
                let expectedFacing = storedFacing == FACE_OPP[playerFacing] ? playerFacing : storedFacing
                XCTAssertEqual(toggledFenceGateMeta(storedFacing, playerFacing: playerFacing), expectedFacing | 4,
                               "closed \(storedFacing), player \(playerFacing)")
                XCTAssertEqual(toggledFenceGateMeta(storedFacing | 12, playerFacing: playerFacing), storedFacing | 8,
                               "closing must preserve facing and the wall bit")
            }
        }
    }
}
