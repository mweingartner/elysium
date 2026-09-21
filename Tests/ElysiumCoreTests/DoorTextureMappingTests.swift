import XCTest
@testable import ElysiumCore

final class DoorTextureMappingTests: XCTestCase {
    private struct Vertex {
        let x: Double
        let y: Double
        let z: Double
        let u: Float
    }

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func inputIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        ((y + 1) * 18 + (z + 1)) * 18 + (x + 1)
    }

    private func packedContext() -> MeshRenderContext {
        MeshRenderContext(
            tintGate: [UInt8](repeating: 0, count: allTileNames().count),
            textureGate: [UInt8](repeating: 1, count: allTileNames().count),
            generation: 1
        )!
    }

    private func meshForDoor(_ block: UInt16, facing: Int, open: Bool, hingeRight: Bool) -> MeshLayer {
        let count = 18 * 18 * 18
        var blocks = [UInt16](repeating: cell(B.air), count: count)
        blocks[inputIndex(8, 8, 8)] = cell(block, facing | (open ? 4 : 0))
        blocks[inputIndex(8, 9, 8)] = cell(block, 8 | (hingeRight ? 1 : 0))
        return buildSectionMesh(MeshInput(
            blocks: blocks,
            skyLight: [UInt8](repeating: 15, count: count),
            blockLight: [UInt8](repeating: 0, count: count),
            biomes: [UInt8](repeating: 0, count: 18 * 18),
            noMerge: true,
            renderContext: packedContext()
        )).cutout
    }

    private func faceVertices(_ layer: MeshLayer, tile: String, normal: Int, blockY: Int) -> [Vertex] {
        stride(from: 0, to: layer.count, by: 4).flatMap { first -> [Vertex] in
            guard first + 3 < layer.count else { return [] }
            let material = layer.data[first * 7 + 5]
            guard tileName(Int(material & 4095)) == tile,
                  Int((material >> 12) & 7) == normal else { return [] }
            let vertices = (0..<4).map { offset -> Vertex in
                let base = (first + offset) * 7
                return Vertex(
                    x: Double(Float(bitPattern: layer.data[base])),
                    y: Double(Float(bitPattern: layer.data[base + 1])),
                    z: Double(Float(bitPattern: layer.data[base + 2])),
                    u: Float(bitPattern: layer.data[base + 3])
                )
            }
            let centerY = vertices.reduce(0) { $0 + $1.y } / 4
            return centerY >= Double(blockY) && centerY <= Double(blockY + 1) ? vertices : []
        }
    }

    /// Returns the world-space edge occupied by one authored texture U edge.
    /// Both broad faces of a physical door must return the same edge: viewing
    /// from the other side can reverse screen-left/right, but must not move a
    /// handle or latch to the hinge edge.
    private func textureEdgeProjection(_ vertices: [Vertex], side: Int, textureU: Float) -> Double? {
        let edge = vertices.filter { abs($0.u - textureU) < 0.001 }
        guard let first = edge.first else { return nil }
        let axis = rightOf(side)
        let projection: (Vertex) -> Double = {
            $0.x * Double(FACE_DX[axis]) + $0.z * Double(FACE_DZ[axis])
        }
        let value = projection(first)
        guard edge.allSatisfy({ abs(projection($0) - value) < 0.0001 }) else { return nil }
        return value
    }

    func testEveryDoorKeepsEachAuthoredTextureEdgeOnOnePhysicalDoorEdge() {
        let doors = WOODS.map { bid("\($0)_door") } + [B.iron_door]

        for door in doors {
            let name = blockDefs[Int(door)].name
            for facing in 0..<4 {
                for open in [false, true] {
                    for hingeRight in [false, true] {
                        let side = open
                            ? (hingeRight ? leftOf(facing) : rightOf(facing))
                            : facing
                        let mesh = meshForDoor(door, facing: facing, open: open, hingeRight: hingeRight)
                        for blockY in [8, 9] {
                            let front = faceVertices(mesh, tile: name, normal: side + 2, blockY: blockY)
                            let back = faceVertices(mesh, tile: name,
                                                    normal: FACE_OPP[side] + 2, blockY: blockY)
                            XCTAssertFalse(front.isEmpty,
                                           "missing front face for \(name), facing \(facing), open \(open), hinge \(hingeRight), y \(blockY)")
                            XCTAssertFalse(back.isEmpty,
                                           "missing back face for \(name), facing \(facing), open \(open), hinge \(hingeRight), y \(blockY)")
                            for textureU: Float in [0, 1] {
                                guard let frontEdge = textureEdgeProjection(front, side: side, textureU: textureU),
                                      let backEdge = textureEdgeProjection(back, side: side, textureU: textureU) else {
                                    XCTFail("missing or split U=\(textureU) edge for \(name), facing \(facing), open \(open), hinge \(hingeRight), y \(blockY)")
                                    continue
                                }
                                XCTAssertEqual(frontEdge, backEdge, accuracy: 0.0001,
                                               "U=\(textureU) moved across the door thickness for \(name), facing \(facing), open \(open), hinge \(hingeRight), y \(blockY)")
                            }
                        }
                    }
                }
            }
        }
    }
}
