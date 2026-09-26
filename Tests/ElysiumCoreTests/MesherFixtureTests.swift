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

    private struct MaterialVertex {
        let x: Double
        let y: Double
        let z: Double
        let normal: Int
        let anim: Int
        let emissive: Int
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

    private func materialVertices(in layer: MeshLayer, matchingTileName name: String) -> [MaterialVertex] {
        (0..<layer.count).compactMap { index in
            let base = index * 7
            let material = layer.data[base + 5]
            guard tileName(Int(material & 4095)) == name else { return nil }
            let tint = layer.data[base + 6]
            return MaterialVertex(
                x: Double(Float(bitPattern: layer.data[base])),
                y: Double(Float(bitPattern: layer.data[base + 1])),
                z: Double(Float(bitPattern: layer.data[base + 2])),
                normal: Int((material >> 12) & 7),
                anim: Int((tint >> 24) & 7),
                emissive: Int((material >> 25) & 1)
            )
        }
    }

    private func flameQuadsHaveNormalsMatchingTheirWinding(_ layer: MeshLayer, named name: String) -> Bool {
        stride(from: 0, to: layer.count, by: 4).allSatisfy { first in
            guard first + 3 < layer.count else { return false }
            let material = layer.data[first * 7 + 5]
            guard tileName(Int(material & 4095)) == name else { return true }
            let normal = Int((material >> 12) & 7)
            let normalZ: Double
            switch normal {
            case 2: normalZ = -1
            case 3: normalZ = 1
            default: return false
            }
            func point(_ offset: Int) -> (Double, Double, Double) {
                let base = (first + offset) * 7
                return (Double(Float(bitPattern: layer.data[base])),
                        Double(Float(bitPattern: layer.data[base + 1])),
                        Double(Float(bitPattern: layer.data[base + 2])))
            }
            let a = point(0), b = point(1), c = point(2)
            let geometricZ = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
            // World meshes use the renderer's clockwise convention. The
            // viewmodel intentionally reverses it while preserving UVs.
            return geometricZ * normalZ < 0
        }
    }

    func testLiveTorchMeshUsesAnimatedFireInsteadOfGlowstoneHead() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.torch)
        let tiles = tileNames(in: mesh.cutout)
        let flame = materialVertices(in: mesh.cutout, matchingTileName: "fire")

        XCTAssertGreaterThanOrEqual(mesh.cutout.count, 40)
        XCTAssertTrue(tiles.contains("oak_planks"))
        XCTAssertTrue(tiles.contains("fire"))
        XCTAssertFalse(tiles.contains("glowstone"))
        XCTAssertFalse(tiles.contains("torch"))
        XCTAssertEqual(Set(flame.map(\.anim)), [4])
        XCTAssertEqual(Set(flame.map(\.emissive)), [1])
        XCTAssertTrue(flameQuadsHaveNormalsMatchingTheirWinding(mesh.cutout, named: "fire"))
    }

    func testSoulTorchUsesAnimatedSoulFireMaterialInLiveMesh() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.soul_torch)
        let tiles = tileNames(in: mesh.cutout)
        let flame = materialVertices(in: mesh.cutout, matchingTileName: "soul_fire")

        XCTAssertGreaterThanOrEqual(mesh.cutout.count, 40)
        XCTAssertTrue(tiles.contains("oak_planks"))
        XCTAssertTrue(tiles.contains("soul_fire"))
        XCTAssertFalse(tiles.contains("sea_lantern"))
        XCTAssertFalse(tiles.contains("soul_torch"))
        XCTAssertEqual(Set(flame.map(\.anim)), [4])
        XCTAssertEqual(Set(flame.map(\.emissive)), [1])
        XCTAssertTrue(flameQuadsHaveNormalsMatchingTheirWinding(mesh.cutout, named: "soul_fire"))
    }

    func testRedstoneTorchesKeepTheirDistinctIndicatorTip() {
        registerCoreIfNeeded()

        let active = meshFor(B.redstone_torch)
        let inactive = meshFor(B.redstone_torch_off)
        XCTAssertTrue(tileNames(in: active.cutout).contains("redstone_block"))
        XCTAssertFalse(tileNames(in: active.cutout).contains("fire"))
        XCTAssertEqual(Set(materialVertices(in: active.cutout, matchingTileName: "redstone_block").map(\.emissive)), [1])
        XCTAssertEqual(Set(materialVertices(in: inactive.cutout, matchingTileName: "redstone_block").map(\.emissive)), [0])
        XCTAssertFalse(tileNames(in: inactive.cutout).contains("fire"))
    }

    func testTorchFlamesRemainBoundedForFloorAndWallFixtures() {
        registerCoreIfNeeded()

        for meta in [0, 2, 3, 4, 5] {
            let mesh = meshFor(B.torch, meta: meta)
            let flame = materialVertices(in: mesh.cutout, matchingTileName: "fire")
            XCTAssertEqual(flame.count, 16, "torch meta \(meta)")
            XCTAssertTrue(flame.allSatisfy {
                $0.x >= 8 && $0.x <= 9 && $0.y >= 8 && $0.y <= 9 && $0.z >= 8 && $0.z <= 9
            }, "torch meta \(meta) escaped its fixture cell")
        }
    }

    func testLitFurnaceAddsOneAnimatedFlameOnlyOnItsVisibleFront() {
        registerCoreIfNeeded()
        XCTAssertTrue(materialVertices(in: meshFor(B.furnace).cutout, matchingTileName: "fire").isEmpty)

        let epsilon = 1.0 / 1024.0
        for meta in 0..<4 {
            let mesh = meshFor(B.furnace_lit, meta: meta)
            let flame = materialVertices(in: mesh.cutout, matchingTileName: "fire")
            XCTAssertEqual(flame.count, 4, "furnace meta \(meta)")
            XCTAssertEqual(Set(flame.map(\.normal)), [meta + 2])
            XCTAssertEqual(Set(flame.map(\.anim)), [4])
            XCTAssertEqual(Set(flame.map(\.emissive)), [1])
            switch meta {
            case 0:
                XCTAssertTrue(flame.allSatisfy { abs($0.z - (8 - epsilon)) < 0.000_001 })
            case 1:
                XCTAssertTrue(flame.allSatisfy { abs($0.z - (9 + epsilon)) < 0.000_001 })
            case 2:
                XCTAssertTrue(flame.allSatisfy { abs($0.x - (8 - epsilon)) < 0.000_001 })
            default:
                XCTAssertTrue(flame.allSatisfy { abs($0.x - (9 + epsilon)) < 0.000_001 })
            }
        }

        let occluded = meshForCells([
            (8, 8, 8, B.furnace_lit, 0),
            (8, 8, 7, B.stone, 0),
        ])
        XCTAssertTrue(materialVertices(in: occluded.cutout, matchingTileName: "fire").isEmpty)
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

    func testEverySolidNetherTerrainBlockProducesVisibleGeometry() {
        registerCoreIfNeeded()

        // These are the solid materials emitted by Nether base terrain, biome surfaces,
        // ore placement, vegetation structures, delta features, and the Nether World
        // gateway chamber. A solid generated cell with no vertices exposes all terrain
        // behind it and creates the appearance of a hole through the world.
        let generatedSolids: [UInt16] = [
            B.bedrock, B.netherrack, B.crimson_nylium, B.warped_nylium,
            B.soul_sand, B.soul_soil, B.magma_block, B.glowstone,
            B.shroomlight, B.nether_wart_block, B.warped_wart_block,
            B.basalt, B.blackstone, B.bone_block, B.nether_gold_ore,
            B.nether_quartz_ore, B.ancient_debris, B.lava,
            B.obsidian,
        ]

        for block in generatedSolids {
            let definition = blockDefs[Int(block)]
            XCTAssertTrue(definition.solid || block == B.lava,
                          "fixture drifted away from generated solid/fluid coverage: \(definition.name)")
            let mesh = meshFor(block)
            let vertices = mesh.opaque.count + mesh.cutout.count + mesh.translucent.count
            XCTAssertGreaterThan(vertices, 0, "generated Nether block has no mesh: \(definition.name)")
        }
    }

    func testEveryRegisteredCubeShapeProducesVisibleGeometryRegardlessOfFullCubeFlag() {
        registerCoreIfNeeded()

        for definition in blockDefs where definition.shape == .cube {
            let mesh = meshFor(UInt16(definition.id))
            let vertices = mesh.opaque.count + mesh.cutout.count + mesh.translucent.count
            XCTAssertGreaterThan(vertices, 0,
                                 "registered cube has no visible geometry: \(definition.name)")
        }
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
            let centerSeamPosition = centerVertices.map {
                horizontalProjection($0, direction: right)
            }.max() ?? -1
            let rightSeamPosition = rightVertices.map {
                horizontalProjection($0, direction: right)
            }.min() ?? -2
            XCTAssertEqual(centerSeamPosition, rightSeamPosition, accuracy: 0.0001,
                           "paired chest geometry must meet without a gap facing \(facing)")
            let outsideSpan = (rightVertices + centerVertices).map {
                horizontalProjection($0, direction: right)
            }
            XCTAssertEqual((outsideSpan.max() ?? 0) - (outsideSpan.min() ?? 0),
                           30.0 / 16.0, accuracy: 0.0001,
                           "paired chest must preserve two authored fifteen-texel halves")
        }

        let single = meshFor(B.chest, meta: 0, renderContext: packedContext).cutout
        XCTAssertEqual(vRange(single, matchingTileName: "chest_side").0, 0, accuracy: 0.001)
        XCTAssertEqual(vRange(single, matchingTileName: "chest_side").1, 1.0 / 3.0, accuracy: 0.001)
        let ender = meshFor(B.ender_chest, meta: 0, renderContext: packedContext).cutout
        XCTAssertEqual(vRange(ender, matchingTileName: "ender_chest_side").0, 0, accuracy: 0.001)
        XCTAssertEqual(vRange(ender, matchingTileName: "ender_chest_side").1, 1, accuracy: 0.001)
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

    func testPackBackedAtlasKeepsAuthoredTopAtSpatialTop() {
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

        XCTAssertEqual(packed.keys, procedural.keys)
        XCTAssertFalse(packed.isEmpty)

        let cubeSide = quads(meshFor(B.oak_planks, renderContext: packedContext).opaque,
                             tileName: "oak_planks", normal: 2,
                             blockX: 8, blockY: 8, blockZ: 8).flatMap { $0 }
        XCTAssertFalse(cubeSide.isEmpty)
        for vertex in cubeSide {
            XCTAssertEqual(vertex.v, vertex.y > 8.5 ? 0 : 1, accuracy: 0.0001,
                           "a cube's spatial top must sample the authored top row")
        }

        let grass = quads(meshFor(B.short_grass, renderContext: packedContext).cutout,
                          tileName: "short_grass", normal: 3,
                          blockX: 8, blockY: 8, blockZ: 8).flatMap { $0 }
        XCTAssertFalse(grass.isEmpty)
        for vertex in grass {
            XCTAssertEqual(vertex.v, vertex.y > 8.5 ? 0 : 1, accuracy: 0.0001,
                           "cutout vegetation must grow from the authored bottom row")
        }
    }

    // MARK: - waterlogged aquatic plants (seagrass, kelp, sea pickle, coral)

    /// Builds a 5x5 sand seabed at y=6 with the given plant column standing on it at
    /// (8, 8, 8), surrounded and covered by two layers of real water. `column` lists the
    /// plant's own (block, meta) cells from bottom to top (length 1 for most plants, 2 for
    /// tall_seagrass). The plant is fully submerged: real water fills every other cell in
    /// the 5x5 footprint from its base up through two layers above its top.
    private func submergedAquaticPlantCells(_ column: [(UInt16, Int)]) -> [(Int, Int, Int, UInt16, Int)] {
        let baseY = 8
        let topY = baseY + column.count - 1
        var cells: [(Int, Int, Int, UInt16, Int)] = []
        for x in 6...10 {
            for z in 6...10 {
                cells.append((x, baseY - 1, z, B.sand, 0))
                for y in baseY...(topY + 2) {
                    if x == 8, z == 8, y <= topY { continue }
                    cells.append((x, y, z, B.water, 0))
                }
            }
        }
        for (offset, entry) in column.enumerated() {
            cells.append((8, baseY + offset, 8, entry.0, entry.1))
        }
        return cells
    }

    func testWaterAboveSubmergedAquaticPlantHasNoInternalInterface() {
        registerCoreIfNeeded()

        let columns: [(String, [(UInt16, Int)])] = [
            ("seagrass", [(B.seagrass, 0)]),
            ("tall_seagrass (both halves)", [(B.tall_seagrass, 0), (B.tall_seagrass, 8)]),
            ("kelp (falling meta 12)", [(B.kelp, 12)]),
            ("kelp_plant", [(B.kelp_plant, 0)]),
            ("sea_pickle", [(B.sea_pickle, 0)]),
            ("tube_coral", [(B.tube_coral, 0)]),
        ]

        for (name, column) in columns {
            let mesh = meshForCells(submergedAquaticPlantCells(column))
            let topY = 8 + column.count - 1

            // Before the fix, the real water cell directly above the plant's top emitted
            // a spurious bottom-facing water quad at the plant/water boundary, splitting
            // the water column in two. That boundary sits exactly one block above topY.
            let internalInterface = quads(mesh.translucent, tileName: "water", normal: 0,
                                          blockX: 8, blockY: topY + 1, blockZ: 8)
            XCTAssertTrue(internalInterface.isEmpty,
                         "\(name): found an internal water-to-air interface above the submerged plant")

            // The real surface two layers above the plant must be undisturbed: full
            // 14/16 height, animated as water.
            let surfaceY = topY + 2
            let surface = quads(mesh.translucent, tileName: "water", normal: 1,
                                blockX: 8, blockY: surfaceY, blockZ: 8)
            XCTAssertEqual(surface.count, 1, "\(name): expected exactly one surface quad over the plant column")
            for vertex in surface.flatMap({ $0 }) {
                XCTAssertEqual(vertex.y, Double(surfaceY) + 14.0 / 16, accuracy: 0.0001, "\(name)")
            }
            let surfaceAnim = materialVertices(in: mesh.translucent, matchingTileName: "water").filter {
                $0.normal == 1 && $0.x >= 8 && $0.x <= 9 && $0.z >= 8 && $0.z <= 9
                    && abs($0.y - (Double(surfaceY) + 14.0 / 16)) < 0.01
            }
            XCTAssertFalse(surfaceAnim.isEmpty, "\(name): surface quad vanished from the material scan")
            XCTAssertEqual(Set(surfaceAnim.map(\.anim)), [1], "\(name): surface must stay animated water")
        }
    }

    func testSurfaceLayerAquaticPlantCarriesTheWaterSurface() {
        registerCoreIfNeeded()

        let cases: [(String, UInt16, Int, String)] = [
            ("seagrass", B.seagrass, 0, "seagrass"),
            ("kelp (falling meta 12)", B.kelp, 12, "kelp"),
            ("kelp_plant", B.kelp_plant, 0, "kelp_plant"),
            ("sea_pickle", B.sea_pickle, 0, "sea_pickle"),
            ("tube_coral", B.tube_coral, 0, "tube_coral"),
        ]

        for (name, block, meta, ownTile) in cases {
            var cells: [(Int, Int, Int, UInt16, Int)] = []
            for x in 6...10 {
                for z in 6...10 {
                    cells.append((x, 7, z, B.sand, 0))
                    if !(x == 8 && z == 8) { cells.append((x, 8, z, B.water, 0)) }
                }
            }
            cells.append((8, 8, 8, block, meta))
            let mesh = meshForCells(cells)

            // The plant's own water must fill the hole a bare cross/box mesh would leave:
            // a full 14/16 surface, animated as water, matching the surrounding water.
            let surface = quads(mesh.translucent, tileName: "water", normal: 1,
                                blockX: 8, blockY: 8, blockZ: 8)
            XCTAssertEqual(surface.count, 1, "\(name): expected the plant to carry its own water surface")
            for vertex in surface.flatMap({ $0 }) {
                XCTAssertEqual(vertex.y, 8 + 14.0 / 16, accuracy: 0.0001,
                              "\(name): surface height must match GameWorld.fluidHeight's 14/16, never the plant's own meta")
            }
            let anim = materialVertices(in: mesh.translucent, matchingTileName: "water").filter {
                $0.normal == 1 && $0.x >= 8 && $0.x <= 9 && $0.z >= 8 && $0.z <= 9
            }
            XCTAssertEqual(Set(anim.map(\.anim)), [1], "\(name)")

            // No side wall between the plant's synthetic water and the real water beside it.
            for direction in 2...5 {
                let side = quads(mesh.translucent, tileName: "water", normal: direction,
                                 blockX: 8, blockY: 8, blockZ: 8)
                XCTAssertTrue(side.isEmpty, "\(name): unexpected water side face toward direction \(direction)")
            }

            // The plant's own geometry must still be present in the cutout layer.
            XCTAssertTrue(tileNames(in: mesh.cutout).contains(ownTile),
                         "\(name): plant geometry disappeared from the cutout layer")
        }
    }

    func testWaterloggedPlantNextToOrBelowLavaNeverMergesTheTwoFluids() {
        registerCoreIfNeeded()

        // Lava directly above a waterlogged plant: a physically unusual world state, but the
        // mesher must still treat lava as a different fluid instead of continuing the water
        // column straight through it.
        let above = meshForCells([(8, 7, 8, B.sand, 0), (8, 8, 8, B.seagrass, 0), (8, 9, 8, B.lava, 0)])
        let topSurface = quads(above.translucent, tileName: "water", normal: 1, blockX: 8, blockY: 8, blockZ: 8)
        XCTAssertEqual(topSurface.count, 1,
                      "The plant's own synthetic water must surface a real interface, not merge into lava above")
        for vertex in topSurface.flatMap({ $0 }) {
            XCTAssertEqual(vertex.y, 8 + 14.0 / 16, accuracy: 0.0001,
                          "Interface height must follow the water rule, never lava's own fluid-level math")
        }

        // Lava directly beside a waterlogged plant: the side boundary must remain real, not
        // culled as though the two fluids were the same.
        let beside = meshForCells([(8, 7, 8, B.sand, 0), (8, 8, 8, B.seagrass, 0), (9, 8, 8, B.lava, 0)])
        let sideFace = quads(beside.translucent, tileName: "water", normal: 5, blockX: 8, blockY: 8, blockZ: 8)
        XCTAssertFalse(sideFace.isEmpty,
                      "A waterlogged plant's own water must show a real boundary face against neighboring lava")
    }

    func testKelpMetaNeverChangesTheSyntheticWaterSurfaceHeight() {
        registerCoreIfNeeded()

        // Kelp's meta (0-15) encodes plant age/orientation, not a fluid level. Every meta value
        // must produce exactly the same synthetic water surface as every other.
        for meta in 0...15 {
            let mesh = meshForCells(submergedAquaticPlantCells([(B.kelp, meta)]))
            let surfaceY = 8 + 2 // topY (8, single-cell column) + two layers of real water above
            let surface = quads(mesh.translucent, tileName: "water", normal: 1, blockX: 8, blockY: surfaceY, blockZ: 8)
            XCTAssertEqual(surface.count, 1, "kelp meta \(meta): expected exactly one surface quad")
            for vertex in surface.flatMap({ $0 }) {
                XCTAssertEqual(vertex.y, Double(surfaceY) + 14.0 / 16, accuracy: 0.0001,
                              "kelp meta \(meta) must never be read as a fluid level for the surface height")
            }
        }
    }
}
