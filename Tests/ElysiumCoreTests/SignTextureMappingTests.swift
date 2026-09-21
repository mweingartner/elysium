import XCTest
@testable import ElysiumCore

/// Signs are compact boxes, but their visible boards use a Java entity-sheet
/// unwrap rather than the planks texture used by posts and supports. Keep the
/// two authored board faces attached to the actual board orientation for every
/// stored sign state.
final class SignTextureMappingTests: XCTestCase {
    private struct BoardVertex {
        let normal: Int
        let v: Double
    }

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func inputIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        ((y + 1) * 18 + (z + 1)) * 18 + (x + 1)
    }

    private func packedMesh(for id: UInt16, meta: Int, boardTile: Int) throws -> MeshOutput {
        let count = 18 * 18 * 18
        var blocks = [UInt16](repeating: cell(B.air), count: count)
        blocks[inputIndex(8, 8, 8)] = cell(id, meta)
        var textureGate = [UInt8](repeating: 0, count: allTileNames().count)
        textureGate[boardTile] = 1
        let context = try XCTUnwrap(MeshRenderContext(
            tintGate: nil, textureGate: textureGate, generation: 1))
        return buildSectionMesh(MeshInput(
            blocks: blocks,
            skyLight: [UInt8](repeating: 15, count: count),
            blockLight: [UInt8](repeating: 0, count: count),
            biomes: [UInt8](repeating: 0, count: 18 * 18),
            noMerge: true,
            renderContext: context
        ))
    }

    private func boardVertices(_ mesh: MeshOutput, tile: Int) -> [BoardVertex] {
        [mesh.opaque, mesh.cutout, mesh.translucent].flatMap { layer in
            (0..<layer.count).compactMap { index in
                let base = index * 7
                let material = layer.data[base + 5]
                guard Int(material & 4095) == tile else { return nil }
                return BoardVertex(normal: Int((material >> 12) & 7),
                                   v: Double(Float(bitPattern: layer.data[base + 4])))
            }
        }
    }

    private func assertBoard(_ id: UInt16, meta: Int, expectedFront: Int,
                             expectedTile: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let vertices = boardVertices(try packedMesh(for: id, meta: meta, boardTile: expectedTile),
                                    tile: expectedTile)
        let front = vertices.filter { $0.normal == expectedFront }
        let expectedBack = FACE_OPP[expectedFront - 2] + 2
        let back = vertices.filter { $0.normal == expectedBack }
        XCTAssertFalse(front.isEmpty, "front board missing for meta \(meta)", file: file, line: line)
        XCTAssertFalse(back.isEmpty, "back board missing for meta \(meta)", file: file, line: line)
        XCTAssertEqual(Set(vertices.map(\.normal)), [expectedFront, expectedBack],
                       "only broad board faces may use the semantic entity tile", file: file, line: line)
        XCTAssertLessThan(front.reduce(0) { $0 + $1.v } / Double(front.count), 0.4,
                          "front must sample the first entity-sheet band", file: file, line: line)
        XCTAssertGreaterThan(back.reduce(0) { $0 + $1.v } / Double(back.count), 0.6,
                             "back must sample the second entity-sheet band", file: file, line: line)
    }

    func testEveryWoodAppendsDedicatedBoardTilesAfterTheFrozenAtlasRange() {
        XCTAssertEqual(tileId("bamboo_fence_gate"), 757)
        for wood in WOODS {
            let board = tileId("\(wood)_sign_board")
            let hanging = tileId("\(wood)_hanging_sign_board")
            XCTAssertGreaterThan(board, 757, wood)
            XCTAssertGreaterThan(hanging, board, wood)
            XCTAssertEqual(signBoardTextureTiles[Int(bid("\(wood)_sign"))], board)
            XCTAssertEqual(signBoardTextureTiles[Int(bid("\(wood)_wall_sign"))], board)
            XCTAssertEqual(signBoardTextureTiles[Int(bid("\(wood)_hanging_sign"))], hanging)
        }
    }

    func testProceduralAtlasProvidesDeterministicBoardFallbacksWithoutMissingTiles() {
        let atlas = buildAtlas()
        let missing = Set(atlas.missing)
        for wood in WOODS {
            XCTAssertFalse(missing.contains("\(wood)_sign_board"), wood)
            XCTAssertFalse(missing.contains("\(wood)_hanging_sign_board"), wood)
        }
    }

    func testStandingSignBoardFacesAreHalfTurnInvariantAcrossAllSixteenStates() throws {
        let id = bid("oak_sign")
        let board = try XCTUnwrap(signBoardTextureTiles[Int(id)])
        for meta in 0..<16 {
            let front = standingSignFrontFace(meta)
            try assertBoard(id, meta: meta, expectedFront: front, expectedTile: board)
            XCTAssertEqual(standingSignBoardRunsAlongX(meta), standingSignBoardRunsAlongX(meta + 8),
                           "a 180-degree rotation must keep the same board axis")
        }
    }

    func testWallAndHangingSignBoardsUseTheirMappedBroadFaces() throws {
        let wall = bid("oak_wall_sign")
        let wallTile = try XCTUnwrap(signBoardTextureTiles[Int(wall)])
        for meta in 0..<4 {
            try assertBoard(wall, meta: meta, expectedFront: [3, 2, 5, 4][meta], expectedTile: wallTile)
        }

        let hanging = bid("oak_hanging_sign")
        let hangingTile = try XCTUnwrap(signBoardTextureTiles[Int(hanging)])
        for meta in 0..<2 {
            try assertBoard(hanging, meta: meta, expectedFront: meta == 0 ? 2 : 4, expectedTile: hangingTile)
        }
    }
}
