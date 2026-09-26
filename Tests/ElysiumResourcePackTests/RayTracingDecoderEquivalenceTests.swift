import XCTest
import simd
@testable import Elysium
@testable import ElysiumCore

/// The table-driven decoder must produce byte-identical BLAS inputs to the former per-triangle
/// string-matching decoder. `legacyDecode` is a verbatim copy of that implementation, kept only
/// as an oracle.
final class RayTracingDecoderEquivalenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func legacyDecode(_ mesh: MeshOutput) -> RayTracingMeshDecoder.Decoded? {
        legacyDecodeLayers([(mesh.opaque.data,mesh.opaque.idx,mesh.opaque.count,0),
                            (mesh.cutout.data,mesh.cutout.idx,mesh.cutout.count,1),
                            (mesh.translucent.data,mesh.translucent.idx,mesh.translucent.count,4)])
    }

    private func legacyDecodeLayers(_ layers: [(data:[UInt32],idx:[UInt32],count:Int,flags:UInt32)]) -> RayTracingMeshDecoder.Decoded? {
        var output = RayTracingMeshDecoder.Decoded()
        let tiles = allTileNames()
        let foliageTiles = Set(LEAF_WOODS.map { "\($0)_leaves" })
        for layer in layers {
            let layerFlags=layer.flags
            guard layer.data.count == layer.count * 7, layer.idx.count % 3 == 0,
                  layer.idx.allSatisfy({ Int($0) < layer.count }) else { return nil }
            let base = UInt32(output.positions.count)
            for i in 0..<layer.count {
                let offset = i * 7
                let p = SIMD3<Float>(Float(bitPattern: layer.data[offset]),
                                     Float(bitPattern: layer.data[offset + 1]),
                                     Float(bitPattern: layer.data[offset + 2]))
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
                output.positions.append(p)
            }
            output.indices.append(contentsOf: layer.idx.map { $0 + base })
            for i in stride(from: 0, to: layer.idx.count, by: 3) {
                let offsets = (0..<3).map { Int(layer.idx[i + $0]) * 7 }
                func uv(_ j: Int) -> SIMD2<Float> {
                    SIMD2(Float(bitPattern: layer.data[offsets[j] + 3]), Float(bitPattern: layer.data[offsets[j] + 4]))
                }
                let a = layer.data[offsets[0] + 5], b = layer.data[offsets[0] + 6]
                let normalID = (a >> 12) & 7
                guard normalID < 6 else { return nil }
                let normals: [SIMD3<Float>] = [.init(0,-1,0), .init(0,1,0), .init(0,0,-1),
                                             .init(0,0,1), .init(-1,0,0), .init(1,0,0)]
                let anim = (b >> 24) & 7
                let layerIndex = Int(a & 4095)
                let name = tiles.indices.contains(layerIndex) ? tiles[layerIndex] : ""
                let furnaceFacade = name == "furnace_top" || name == "furnace_side"
                    || name == "furnace_front_lit"
                let emission: Float = ((a >> 25) & 1) == 1 && !furnaceFacade
                    ? (anim == 2 ? 5 : 2) * RenderLocalLightPolicy.outputMultiplier : 0
                let v0 = uv(0), v1 = uv(1), v2 = uv(2)
                guard [v0.x,v0.y,v1.x,v1.y,v2.x,v2.y].allSatisfy(\.isFinite) else { return nil }
                let p0 = output.positions[Int(layer.idx[i] + base)]
                let e1 = output.positions[Int(layer.idx[i+1] + base)] - p0
                let e2 = output.positions[Int(layer.idx[i+2] + base)] - p0
                let plane = simd_cross(e1,e2)
                let areaSquared = simd_length_squared(plane)
                let reciprocal1 = areaSquared > 1e-12 ? simd_cross(e2,plane)/areaSquared : .zero
                let reciprocal2 = areaSquared > 1e-12 ? simd_cross(plane,e1)/areaSquared : .zero
                let gradientU = reciprocal1*(v1.x-v0.x)+reciprocal2*(v2.x-v0.x)
                let gradientV = reciprocal1*(v1.y-v0.y)+reciprocal2*(v2.y-v0.y)
                var flags = anim == 1 ? UInt32(2) : layerFlags
                if foliageTiles.contains(name) { flags |= 32 | 1 }
                if ["iron_block","gold_block","copper_block","netherite_block","raw_iron_block","raw_gold_block"].contains(name)
                    || name.hasPrefix("cut_copper") || name.hasSuffix("_copper") { flags |= 16 }
                output.primitives.append(RayTracingPrimitive(uv01: .init(v0.x,v0.y,v1.x,v1.y),
                    uv2Light: .init(v2.x,v2.y,Float((a >> 17)&15)/15,Float((a >> 21)&15)/15),
                    normalEmission: .init(normals[Int(normalID)],emission),
                    material: .init(b & 0xffffff,a & 4095,flags,anim),
                    textureGradientU: .init(gradientU,0),textureGradientV: .init(gradientV,0)))
                if emission > 0, i % 6 == 0 {
                    let p0 = output.positions[Int(layer.idx[i] + base)]
                    let p1 = output.positions[Int(layer.idx[i+1] + base)]
                    let p2 = output.positions[Int(layer.idx[i+2] + base)]
                    let area = simd_length(simd_cross(p1-p0,p2-p0)) * 0.5
                    if area > 0.00001 {
                        let color: SIMD3<Float> = anim == 2 ? .init(1,0.29,0.04) : .init(1,0.68,0.27)
                        output.emitters.append(.init(positionRadius: .init((p0+p1+p2)/3 + normals[Int(normalID)]*0.04,30),
                            colorPower: .init(color, min(8 * RenderLocalLightPolicy.outputMultiplier,area*emission))))
                    }
                }
            }
        }
        return output
    }

    private func bytes<T>(_ values: [T]) -> [UInt8] { values.withUnsafeBytes { Array($0) } }

    private func assertIdentical(_ mesh: MeshOutput, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = legacyDecode(mesh), actual = RayTracingMeshDecoder.decode(mesh)
        XCTAssertEqual(expected == nil, actual == nil, message, file: file, line: line)
        guard let expected, let actual else { return }
        XCTAssertEqual(bytes(expected.positions), bytes(actual.positions), "positions: " + message, file: file, line: line)
        XCTAssertEqual(expected.indices, actual.indices, "indices: " + message, file: file, line: line)
        XCTAssertEqual(bytes(expected.primitives), bytes(actual.primitives), "primitives: " + message, file: file, line: line)
        XCTAssertEqual(bytes(expected.emitters), bytes(actual.emitters), "emitters: " + message, file: file, line: line)
    }

    /// Two triangles per quad so the emitter's every-sixth-index sampling is exercised.
    private func quad(tile: Int, animation: UInt32, emissive: Bool, normal: UInt32) -> MeshLayer {
        let positions: [SIMD3<Float>] = [.init(0,0,0), .init(1,0,0), .init(1,0.25,1), .init(0,0,1)]
        let uv: [SIMD2<Float>] = [.init(0,0), .init(3,0), .init(3,5), .init(0,5)]
        var words: [UInt32] = []
        for i in 0..<4 {
            words += [positions[i].x.bitPattern, positions[i].y.bitPattern, positions[i].z.bitPattern,
                      uv[i].x.bitPattern, uv[i].y.bitPattern,
                      UInt32(tile) | normal << 12 | 9 << 17 | 4 << 21 | (emissive ? 1 << 25 : 0),
                      0x2c7f1a | animation << 24]
        }
        return MeshLayer(data: words, idx: [0,1,2, 0,2,3], count: 4)
    }

    func testEveryRegisteredTileMatchesLegacyClassificationInEveryLayer() throws {
        let empty = MeshLayer(data: [], idx: [], count: 0)
        // One layer entry past the registry exercises the unnamed-layer path.
        for tile in 0...tileCount() {
            for animation: UInt32 in [0, 1, 2] {
                for emissive in [false, true] {
                    let layer = quad(tile: tile, animation: animation, emissive: emissive, normal: UInt32(tile % 6))
                    for slot in 0..<3 {
                        let mesh = MeshOutput(opaque: slot == 0 ? layer : empty, cutout: slot == 1 ? layer : empty,
                                              translucent: slot == 2 ? layer : empty)
                        try assertIdentical(mesh, "tile \(tile) anim \(animation) emissive \(emissive) slot \(slot)")
                    }
                }
            }
        }
    }

    func testRealMesherSectionOfEveryBlockMatchesLegacyDecoder() throws {
        let side = 18
        for metadata in [0, 1, 5] {
            var blocks = [UInt16](repeating: 0, count: side * side * side)
            var id = 1
            // A sparse checker leaves air around blocks so every face type is emitted.
            for y in 1..<(side - 1) { for z in 1..<(side - 1) { for x in 1..<(side - 1) where (x + y + z) % 2 == 0 {
                blocks[(y * side + z) * side + x] = cell(UInt16(id), metadata)
                id = id + 1 < blockDefs.count ? id + 1 : 1
            }}}
            let mesh = buildSectionMesh(MeshInput(blocks: blocks,
                skyLight: [UInt8](repeating: 15, count: blocks.count),
                blockLight: [UInt8](repeating: 7, count: blocks.count),
                biomes: [UInt8](repeating: 0, count: side * side)))
            XCTAssertGreaterThan(mesh.opaque.idx.count + mesh.cutout.idx.count + mesh.translucent.idx.count, 3000)
            try assertIdentical(mesh, "mesher section metadata \(metadata)")
        }
    }

    func testMalformedInputStillRejectsWholeMesh() {
        let empty = MeshLayer(data: [], idx: [], count: 0)
        var bad = quad(tile: 1, animation: 0, emissive: false, normal: 1)
        var words = bad.data
        words[5] = (words[5] & ~(UInt32(7) << 12)) | (6 << 12) // Normal id 6 is invalid.
        bad = MeshLayer(data: words, idx: bad.idx, count: bad.count)
        XCTAssertNil(RayTracingMeshDecoder.decode(MeshOutput(opaque: bad, cutout: empty, translucent: empty)))
        words = quad(tile: 1, animation: 0, emissive: false, normal: 1).data
        words[3] = Float.nan.bitPattern
        XCTAssertNil(RayTracingMeshDecoder.decode(MeshOutput(opaque: MeshLayer(data: words, idx: [0,1,2,0,2,3], count: 4),
                                                             cutout: empty, translucent: empty)))
    }

    /// Deterministic, seedable PRNG (SplitMix64). No system randomness: the same seed always
    /// produces the same packed layers, so a failure is reproducible from the seed alone.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A random, but always structurally well-formed (matching `data.count`/`idx` bounds),
    /// packed layer: random tile ids including several past the end of the registry, random
    /// normal ids including the two invalid values (6, 7), random anim bits, and occasional
    /// NaN/infinite positions and UVs, which both decoders must reject identically.
    private func randomLayer(vertexCount: Int, triangleCount: Int, tileSpan: Int,
                             rng: inout SplitMix64) -> MeshLayer {
        func coordinate() -> Float {
            switch rng.next() % 20 {
            case 0: return .nan
            case 1: return rng.next() % 2 == 0 ? .infinity : -.infinity
            default: return Float(Int64(rng.next() % 2001)) / 100 - 10
            }
        }
        var words: [UInt32] = []
        for _ in 0..<vertexCount {
            let position = SIMD3<Float>(coordinate(), coordinate(), coordinate())
            let uv = SIMD2<Float>(coordinate(), coordinate())
            let tile = UInt32(rng.next() % UInt64(tileSpan))
            let normal = UInt32(rng.next() % 8) // 0...7: 6 and 7 are invalid.
            let skyBlock = UInt32(rng.next() % 256)
            let emissive: UInt32 = rng.next() % 2
            let a = tile | (normal << 12) | (skyBlock << 17) | (emissive << 25)
            let material = UInt32(rng.next() % 0x100_0000)
            let anim = UInt32(rng.next() % 8)
            let b = material | (anim << 24)
            words += [position.x.bitPattern, position.y.bitPattern, position.z.bitPattern,
                      uv.x.bitPattern, uv.y.bitPattern, a, b]
        }
        var idx: [UInt32] = []
        for _ in 0..<triangleCount {
            for _ in 0..<3 { idx.append(UInt32(rng.next() % UInt64(max(1, vertexCount)))) }
        }
        return MeshLayer(data: words, idx: idx, count: vertexCount)
    }

    func testRandomizedPackedLayersMatchLegacyDecoderAcrossManySeeds() throws {
        let tileSpan = tileCount() + 8 // several ids intentionally past the end of the registry
        for seed: UInt64 in 0..<300 {
            var rng = SplitMix64(seed: seed &+ 1)
            let vertexCount = Int(rng.next() % 12) + 3
            let triangleCount = Int(rng.next() % 6) + 1
            let opaque = randomLayer(vertexCount: vertexCount, triangleCount: triangleCount, tileSpan: tileSpan, rng: &rng)
            let empty = MeshLayer(data: [], idx: [], count: 0)
            let cutout = rng.next() % 3 == 0
                ? randomLayer(vertexCount: vertexCount, triangleCount: triangleCount, tileSpan: tileSpan, rng: &rng) : empty
            let translucent = rng.next() % 3 == 0
                ? randomLayer(vertexCount: vertexCount, triangleCount: triangleCount, tileSpan: tileSpan, rng: &rng) : empty
            let mesh = MeshOutput(opaque: opaque, cutout: cutout, translucent: translucent)
            try assertIdentical(mesh, "seed \(seed)")
        }
    }

    func testTraitTableCoversTheWholeRegistryAndNamedMaterials() {
        XCTAssertEqual(RayTracingMeshDecoder.tileTraits().count, tileCount())
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("oak_leaves"), .foliage)
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("flowering_azalea_leaves"), .foliage)
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("oak_log"), [])
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("weathered_cut_copper"), .metal)
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("cut_copper_slab"), .metal)
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("gold_block"), .metal)
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("furnace_front_lit"), .furnaceFacade)
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of("furnace_front"), [])
        XCTAssertEqual(RayTracingMeshDecoder.TileTraits.of(""), [])
    }
}
