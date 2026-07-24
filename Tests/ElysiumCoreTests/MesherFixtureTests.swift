import XCTest
@testable import ElysiumCore

final class MesherFixtureTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    private func meshFor(_ block: UInt16, meta: Int = 0,
                         renderContext: MeshRenderContext = .procedural) -> MeshOutput {
        let paddedCount = 18 * 18 * 18
        var blocks = [UInt16](repeating: B.air << 4, count: paddedCount)
        let sky = [UInt8](repeating: 15, count: paddedCount)
        let light = [UInt8](repeating: 0, count: paddedCount)
        let biomes = [UInt8](repeating: 0, count: 18 * 18)
        blocks[inputIndex(8, 8, 8)] = (block << 4) | UInt16(meta & 15)
        return buildSectionMesh(MeshInput(blocks: blocks, skyLight: sky, blockLight: light,
                                          biomes: biomes, noMerge: true,
                                          renderContext: renderContext))
    }

    private func meshForCells(_ cells: [(Int, Int, Int, UInt16, Int)],
                              renderContext: MeshRenderContext = .procedural) -> MeshOutput {
        let paddedCount = 18 * 18 * 18
        var blocks = [UInt16](repeating: B.air << 4, count: paddedCount)
        for (x, y, z, block, meta) in cells {
            blocks[inputIndex(x, y, z)] = (block << 4) | UInt16(meta & 15)
        }
        return buildSectionMesh(MeshInput(blocks: blocks,
            skyLight: [UInt8](repeating: 15, count: paddedCount),
            blockLight: [UInt8](repeating: 0, count: paddedCount),
            biomes: [UInt8](repeating: 0, count: 18 * 18), noMerge: true,
            renderContext: renderContext))
    }

    private func vRange(_ layer: MeshLayer) -> (Float, Float) {
        let values = (0..<layer.count).map { Float(bitPattern: layer.data[$0 * 7 + 4]) }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    private func vRange(_ layer: MeshLayer, matchingTileName name: String) -> (Float, Float) {
        let values = (0..<layer.count).compactMap { index -> Float? in
            let tile = Int(layer.data[index * 7 + 5] & 4095)
            return tileName(tile) == name ? Float(bitPattern: layer.data[index * 7 + 4]) : nil
        }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    private func vRange(_ layer: MeshLayer, matchingTileName name: String,
                        blockX: Int, blockY: Int = 8, blockZ: Int) -> (Float, Float) {
        let values = (0..<layer.count).compactMap { index -> Float? in
            let base = index * 7
            guard tileName(Int(layer.data[base + 5] & 4095)) == name else { return nil }
            let x = Double(Float(bitPattern: layer.data[base]))
            let y = Double(Float(bitPattern: layer.data[base + 1]))
            let z = Double(Float(bitPattern: layer.data[base + 2]))
            guard x >= Double(blockX), x <= Double(blockX + 1),
                  y >= Double(blockY), y <= Double(blockY + 1),
                  z >= Double(blockZ), z <= Double(blockZ + 1) else { return nil }
            return Float(bitPattern: layer.data[base + 4])
        }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    private func vertexVByPosition(_ layer: MeshLayer) -> [String: Float] {
        Dictionary(uniqueKeysWithValues: (0..<layer.count).map { index in
            let base = index * 7
            let normal = (layer.data[base + 5] >> 12) & 7
            let key = "\(layer.data[base]),\(layer.data[base + 1]),\(layer.data[base + 2]),\(normal)"
            return (key, Float(bitPattern: layer.data[base + 4]))
        })
    }

    private struct Vertex {
        let x: Double
        let y: Double
        let z: Double
        let u: Float
        let v: Float
    }

    private func quads(_ layer: MeshLayer, tileName expectedName: String, normal: Int,
                       blockX: Int, blockY: Int, blockZ: Int) -> [[Vertex]] {
        stride(from: 0, to: layer.count, by: 4).compactMap { first in
            guard first + 3 < layer.count else { return nil }
            let word = layer.data[first * 7 + 5]
            guard tileName(Int(word & 4095)) == expectedName,
                  Int((word >> 12) & 7) == normal else { return nil }
            let vertices = (0..<4).map { offset -> Vertex in
                let base = (first + offset) * 7
                return Vertex(x: Double(Float(bitPattern: layer.data[base])),
                              y: Double(Float(bitPattern: layer.data[base + 1])),
                              z: Double(Float(bitPattern: layer.data[base + 2])),
                              u: Float(bitPattern: layer.data[base + 3]),
                              v: Float(bitPattern: layer.data[base + 4]))
            }
            let center = vertices.reduce((0.0, 0.0, 0.0)) {
                ($0.0 + $1.x / 4, $0.1 + $1.y / 4, $0.2 + $1.z / 4)
            }
            guard center.0 >= Double(blockX), center.0 <= Double(blockX + 1),
                  center.1 >= Double(blockY), center.1 <= Double(blockY + 1),
                  center.2 >= Double(blockZ), center.2 <= Double(blockZ + 1) else { return nil }
            return vertices
        }
    }

    private func uvRange(_ quads: [[Vertex]]) -> (u: (Float, Float), v: (Float, Float)) {
        let vertices = quads.flatMap { $0 }
        let us = vertices.map(\.u), vs = vertices.map(\.v)
        return ((us.min() ?? 0, us.max() ?? 0), (vs.min() ?? 0, vs.max() ?? 0))
    }

    private func horizontalProjection(_ vertex: Vertex, direction: Int) -> Double {
        vertex.x * Double(FACE_DX[direction]) + vertex.z * Double(FACE_DZ[direction])
    }

    private func inputIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        ((y + 1) * 18 + (z + 1)) * 18 + (x + 1)
    }

    private func tileNames(in layer: MeshLayer) -> Set<String> {
        var names: Set<String> = []
        for vertex in 0..<layer.count {
            let tile = Int(layer.data[vertex * 7 + 5] & 4095)
            names.insert(tileName(tile))
        }
        return names
    }

    func testLiveTorchMeshUses3DMaterialPiecesInsteadOfSpriteCard() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.torch)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThanOrEqual(mesh.cutout.count, 48)
        XCTAssertTrue(tiles.contains("oak_planks"))
        XCTAssertTrue(tiles.contains("glowstone"))
        XCTAssertFalse(tiles.contains("torch"))
    }

    func testSoulTorchUsesSoulGlowMaterialInLiveMesh() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.soul_torch)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThanOrEqual(mesh.cutout.count, 48)
        XCTAssertTrue(tiles.contains("oak_planks"))
        XCTAssertTrue(tiles.contains("sea_lantern"))
        XCTAssertFalse(tiles.contains("soul_torch"))
    }

    func testLiveLanternMeshUsesFrameAndGlowingCorePieces() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.lantern)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThan(mesh.cutout.count, 24)
        XCTAssertTrue(tiles.contains("iron_block"))
        XCTAssertTrue(tiles.contains("glowstone"))
        XCTAssertFalse(tiles.contains("lantern"))
    }

    func testSoulLanternUsesSoulGlowMaterialInLiveMesh() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.soul_lantern)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThan(mesh.cutout.count, 24)
        XCTAssertTrue(tiles.contains("iron_block"))
        XCTAssertTrue(tiles.contains("sea_lantern"))
        XCTAssertFalse(tiles.contains("soul_lantern"))
    }

    func testPackMultipartUVsSelectDoorBedAndDoubleChestPartsDeterministically() {
        registerCoreIfNeeded()
        let packedContext = MeshRenderContext(
            tintGate: [UInt8](repeating: 0, count: allTileNames().count),
            textureGate: [UInt8](repeating: 1, count: allTileNames().count),
            generation: 2)!

        for facing in 0..<4 {
            for open in [0, 4] {
                for hinge in 0...1 {
                    let mesh = meshForCells([
                        (8, 8, 8, B.oak_door, facing | open),
                        (8, 9, 8, B.oak_door, 8 | hinge),
                    ], renderContext: packedContext).cutout
                    let side = open == 0 ? facing
                        : (hinge == 1 ? leftOf(facing) : rightOf(facing))
                    let lower = quads(mesh, tileName: "oak_door", normal: side + 2,
                                      blockX: 8, blockY: 8, blockZ: 8)
                    let upper = quads(mesh, tileName: "oak_door", normal: side + 2,
                                      blockX: 8, blockY: 9, blockZ: 8)
                    XCTAssertFalse(lower.isEmpty, "lower facing \(facing) open \(open) hinge \(hinge)")
                    XCTAssertFalse(upper.isEmpty, "upper facing \(facing) open \(open) hinge \(hinge)")
                    XCTAssertEqual(uvRange(lower).v.0, 0.5, accuracy: 0.001)
                    XCTAssertEqual(uvRange(lower).v.1, 1, accuracy: 0.001)
                    XCTAssertEqual(uvRange(upper).v.0, 0, accuracy: 0.001)
                    XCTAssertEqual(uvRange(upper).v.1, 0.5, accuracy: 0.001)
                }
            }

            let leftHinge = quads(meshForCells([
                (8, 8, 8, B.oak_door, facing), (8, 9, 8, B.oak_door, 8),
            ], renderContext: packedContext).cutout, tileName: "oak_door", normal: facing + 2,
               blockX: 8, blockY: 8, blockZ: 8).flatMap { $0 }
            let rightHinge = quads(meshForCells([
                (8, 8, 8, B.oak_door, facing), (8, 9, 8, B.oak_door, 9),
            ], renderContext: packedContext).cutout, tileName: "oak_door", normal: facing + 2,
               blockX: 8, blockY: 8, blockZ: 8).flatMap { $0 }
            XCTAssertEqual(leftHinge.count, rightHinge.count)
            for (left, right) in zip(leftHinge, rightHinge) {
                XCTAssertEqual(right.u, 1 - left.u, accuracy: 0.001,
                               "hinge mirrors facing \(facing)")
            }

            let foot = (x: 8, z: 8)
            let head = (x: foot.x + FACE_DX[facing], z: foot.z + FACE_DZ[facing])
            let bed = meshForCells([
                (foot.x, 8, foot.z, B.red_bed, facing),
                (head.x, 8, head.z, B.red_bed, facing | 4),
            ], renderContext: packedContext).cutout
            for (position, start) in [(foot, Float(0.5)), (head, Float(0))] {
                let top = quads(bed, tileName: "red_bed_top", normal: 1,
                                blockX: position.x, blockY: 8, blockZ: position.z)
                let range = uvRange(top)
                XCTAssertEqual(range.v.0, start, accuracy: 0.001)
                XCTAssertEqual(range.v.1, start + 0.5, accuracy: 0.001)
                let forward = top.flatMap { $0 }.max {
                    let ap = ($0.x - Double(position.x) - 0.5) * Double(FACE_DX[facing])
                        + ($0.z - Double(position.z) - 0.5) * Double(FACE_DZ[facing])
                    let bp = ($1.x - Double(position.x) - 0.5) * Double(FACE_DX[facing])
                        + ($1.z - Double(position.z) - 0.5) * Double(FACE_DZ[facing])
                    if abs(ap - bp) > 0.001 { return ap < bp }
                    let left = leftOf(facing)
                    let al = ($0.x - Double(position.x) - 0.5) * Double(FACE_DX[left])
                        + ($0.z - Double(position.z) - 0.5) * Double(FACE_DZ[left])
                    let bl = ($1.x - Double(position.x) - 0.5) * Double(FACE_DX[left])
                        + ($1.z - Double(position.z) - 0.5) * Double(FACE_DZ[left])
                    return al < bl
                }
                XCTAssertEqual(forward?.u ?? -1, 0, accuracy: 0.001,
                               "authored left corner facing \(facing)")
                XCTAssertEqual(forward?.v ?? -1, start, accuracy: 0.001,
                               "authored top edge facing \(facing)")
            }
        }

        for facing in 0..<4 {
            let right = rightOf(facing)
            let dx = FACE_DX[right], dz = FACE_DZ[right]
            let center = (x: 8, z: 8)
            let rightCell = (x: center.x + dx, z: center.z + dz)
            let paired = meshForCells([
                (center.x, 8, center.z, B.chest, facing),
                (rightCell.x, 8, rightCell.z, B.chest, facing),
            ], renderContext: packedContext).cutout
            let front = facing + 2
            let centerFront = quads(paired, tileName: "chest_side", normal: front,
                                    blockX: center.x, blockY: 8, blockZ: center.z)
            let rightFront = quads(paired, tileName: "chest_side", normal: front,
                                   blockX: rightCell.x, blockY: 8, blockZ: rightCell.z)
            XCTAssertEqual(uvRange(centerFront).v.0, 1.0 / 3.0, accuracy: 0.001, "facing \(facing)")
            XCTAssertEqual(uvRange(centerFront).v.1, 2.0 / 3.0, accuracy: 0.001, "facing \(facing)")
            XCTAssertEqual(uvRange(rightFront).v.0, 2.0 / 3.0, accuracy: 0.001, "facing \(facing)")
            XCTAssertEqual(uvRange(rightFront).v.1, 1, accuracy: 0.001, "facing \(facing)")
            let centerVertices = centerFront.flatMap { $0 }
            let rightVertices = rightFront.flatMap { $0 }
            let centerSeam = centerVertices.max {
                horizontalProjection($0, direction: right)
                    < horizontalProjection($1, direction: right)
            }
            let rightSeam = rightVertices.min {
                horizontalProjection($0, direction: right)
                    < horizontalProjection($1, direction: right)
            }
            XCTAssertEqual(centerSeam?.u ?? -1, 1, accuracy: 0.001, "left part seam facing \(facing)")
            XCTAssertEqual(rightSeam?.u ?? -1, 0, accuracy: 0.001, "right part seam facing \(facing)")
        }

        let single = meshFor(B.chest, meta: 0, renderContext: packedContext).cutout
        XCTAssertEqual(vRange(single, matchingTileName: "chest_side").0, 0, accuracy: 0.001)
        XCTAssertEqual(vRange(single, matchingTileName: "chest_side").1, 1.0 / 3.0, accuracy: 0.001)
        let ender = meshFor(B.ender_chest, meta: 0, renderContext: packedContext).cutout
        XCTAssertEqual(vRange(ender, matchingTileName: "ender_chest_side").0, 0, accuracy: 0.001)
        XCTAssertEqual(vRange(ender, matchingTileName: "ender_chest_side").1, 15.0 / 16.0, accuracy: 0.001)
        // A front/back neighbour is not a legal double-chest pair and cannot
        // select a left/right image; mismatched metadata likewise falls back.
        let frontOrphan = meshForCells(
            [(8, 8, 8, B.chest, 0), (8, 8, 7, B.chest, 0)],
            renderContext: packedContext).cutout
        XCTAssertEqual(vRange(frontOrphan, matchingTileName: "chest_side", blockX: 8, blockZ: 8).1,
                       1.0 / 3.0, accuracy: 0.001)
        let inconsistent = meshForCells(
            [(8, 8, 8, B.chest, 0), (7, 8, 8, B.chest, 1)],
            renderContext: packedContext).cutout
        XCTAssertEqual(vRange(inconsistent, matchingTileName: "chest_side", blockX: 8, blockZ: 8).1,
                       1.0 / 3.0, accuracy: 0.001)
    }

    func testPackBackedGreedyCubeFlipsVAtSharedMeshBoundary() {
        registerCoreIfNeeded()
        let procedural = vertexVByPosition(meshFor(B.oak_planks).opaque)
        let shortContext = MeshRenderContext(tintGate: [], textureGate: [], generation: 2)!
        let shortGate = vertexVByPosition(meshFor(
            B.oak_planks, renderContext: shortContext).opaque)
        XCTAssertEqual(procedural, shortGate, "short provenance gates must fall back without trapping")
        let packedContext = MeshRenderContext(
            tintGate: nil,
            textureGate: [UInt8](repeating: 1, count: allTileNames().count),
            generation: 3)!
        let packed = vertexVByPosition(meshFor(
            B.oak_planks, renderContext: packedContext).opaque)

        XCTAssertEqual(procedural.keys, packed.keys)
        XCTAssertFalse(procedural.isEmpty)
        for (position, before) in procedural {
            guard let after = packed[position] else { return XCTFail("missing packed cube vertex") }
            XCTAssertEqual(after, 1 - before, accuracy: 0.0001,
                           "pack-backed greedy cube V must use the shared visual-top transform")
        }
    }
}
