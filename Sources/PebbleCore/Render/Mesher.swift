// Section mesher — Builds opaque/cutout/translucent
// vertex buffers from a padded 18×18×18 snapshot. Greedy merging for uniform
// full-cube faces, per-vertex AO, smooth light, biome tints, shape geometry.
//
// Vertex layout (28 bytes, 7 uint32 words):
//   float x, y, z      — section-local position
//   float u, v         — tile-local UV (wraps across merged quads)
//   uint32 A: layer(12) | normal(3) | ao(2) | sky(4) | block(4) | emissive(1)
//   uint32 B: tintR(8) | tintG(8) | tintB(8) | anim(3)
// anim: 0 none, 1 water, 2 lava, 3 portal, 4 fire, 5 sway-weak, 6 sway-strong

import Foundation

public struct MeshInput {
    /// 18×18×18 padded cells: idx = ((y+1)*18 + (z+1))*18 + (x+1)
    public var blocks: [UInt16]
    public var skyLight: [UInt8]
    public var blockLight: [UInt8]
    /// per-column biome for 18×18 (padded)
    public var biomes: [UInt8]
    /// emit one quad per face instead of greedy-merged spans
    public var noMerge = false

    public init(blocks: [UInt16], skyLight: [UInt8], blockLight: [UInt8], biomes: [UInt8], noMerge: Bool = false) {
        self.blocks = blocks
        self.skyLight = skyLight
        self.blockLight = blockLight
        self.biomes = biomes
        self.noMerge = noMerge
    }
}

public struct MeshLayer {
    /// interleaved vertex words: x,y,z,u,v as Float bitPattern + A,B raw
    public let data: [UInt32]
    public let idx: [UInt32]
    public let count: Int
}

public struct MeshOutput {
    public let opaque: MeshLayer
    public let cutout: MeshLayer
    public let translucent: MeshLayer
}

private let P = 18

@inline(__always) private func idxOf(_ x: Int, _ y: Int, _ z: Int) -> Int {
    ((y + 1) * P + (z + 1)) * P + (x + 1)
}

// dirs: 0=-y 1=+y 2=-z 3=+z 4=-x 5=+x
private let FACE_OFF: [(Int, Int, Int)] = [
    (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0),
]

final class MeshBuilder {
    var verts: [Float] = []   // 5 per vertex
    var uints: [UInt32] = []  // 2 per vertex (A, B)
    var idx: [UInt32] = []
    var vcount = 0

    // swiftlint:disable:next function_parameter_count
    func quad(
        _ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double,
        _ x2: Double, _ y2: Double, _ z2: Double, _ x3: Double, _ y3: Double, _ z3: Double,
        _ u0: Double, _ v0: Double, _ u1: Double, _ v1: Double, _ u2: Double, _ v2: Double, _ u3: Double, _ v3: Double,
        _ layer: Int, _ normal: Int,
        _ ao0: Int, _ ao1: Int, _ ao2: Int, _ ao3: Int,
        _ sky0: Int, _ sky1: Int, _ sky2: Int, _ sky3: Int,
        _ blk0: Int, _ blk1: Int, _ blk2: Int, _ blk3: Int,
        _ emissive: Int, _ tint: Int, _ anim: Int
    ) {
        let base = UInt32(vcount)
        let xs = [x0, x1, x2, x3], ys = [y0, y1, y2, y3], zs = [z0, z1, z2, z3]
        let us = [u0, u1, u2, u3], vs = [v0, v1, v2, v3]
        let aos = [ao0, ao1, ao2, ao3], skys = [sky0, sky1, sky2, sky3], blks = [blk0, blk1, blk2, blk3]
        for c in 0..<4 {
            verts.append(Float(xs[c])); verts.append(Float(ys[c])); verts.append(Float(zs[c]))
            verts.append(Float(us[c])); verts.append(Float(vs[c]))
            let A = UInt32(layer & 4095) | (UInt32(normal) << 12) | (UInt32(aos[c] & 3) << 15)
                | (UInt32(skys[c] & 15) << 17) | (UInt32(blks[c] & 15) << 21) | (UInt32(emissive) << 25)
            let Bv = UInt32(tint & 0xffffff) | (UInt32(anim) << 24)
            uints.append(A); uints.append(Bv)
            vcount += 1
        }
        // flip quad for better AO interpolation
        if ao0 + ao2 > ao1 + ao3 {
            idx.append(contentsOf: [base + 1, base + 2, base + 3, base + 3, base + 0, base + 1])
        } else {
            idx.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
    }

    func build() -> MeshLayer {
        var data = [UInt32](repeating: 0, count: vcount * 7)
        for i in 0..<vcount {
            data[i * 7] = verts[i * 5].bitPattern
            data[i * 7 + 1] = verts[i * 5 + 1].bitPattern
            data[i * 7 + 2] = verts[i * 5 + 2].bitPattern
            data[i * 7 + 3] = verts[i * 5 + 3].bitPattern
            data[i * 7 + 4] = verts[i * 5 + 4].bitPattern
            data[i * 7 + 5] = uints[i * 2]
            data[i * 7 + 6] = uints[i * 2 + 1]
        }
        return MeshLayer(data: data, idx: idx, count: vcount)
    }
}

private let WHITE = 0xffffff
private let GRASS_FALLBACK = 0x91bd59

/// per-tile biome-tint gate installed by the app when a resource pack is
/// active (1 = tile keeps its tint, 0 = render untinted because the imported
/// art is pre-colored). nil — the always-tint vanilla-parity path pebsmoke
/// goldens exercise — costs nothing in the hot loop.
public var PACK_TINT_GATE: [UInt8]? = nil

let TILE_WIRE_DOT = tileId("redstone_dust_dot")
let TILE_WIRE_LINE = tileId("redstone_dust_line")

public func buildSectionMesh(_ input: MeshInput) -> MeshOutput {
    let m = SectionMesher(input)
    return m.run()
}

final class SectionMesher {
    let input: MeshInput
    let opaque = MeshBuilder()
    let cutout = MeshBuilder()
    let translucent = MeshBuilder()

    init(_ input: MeshInput) {
        self.input = input
    }

    @inline(__always) func cellAt(_ x: Int, _ y: Int, _ z: Int) -> Int { Int(input.blocks[idxOf(x, y, z)]) }
    @inline(__always) func skyAt(_ x: Int, _ y: Int, _ z: Int) -> Int { Int(input.skyLight[idxOf(x, y, z)]) }
    @inline(__always) func blkAt(_ x: Int, _ y: Int, _ z: Int) -> Int { Int(input.blockLight[idxOf(x, y, z)]) }
    @inline(__always) func biomeAt(_ x: Int, _ z: Int) -> Int { Int(input.biomes[(z + 1) * P + (x + 1)]) }

    func tintFor(_ cell: Int, _ x: Int, _ z: Int) -> Int {
        let t = TINT_OF[cell >> 4]
        if t == 0 { return WHITE }
        guard biomeAt(x, z) < BIOMES.count, let bd = BIOMES[biomeAt(x, z)] else { return GRASS_FALLBACK }
        if t == 1 { return Int(bd.grassColor) }
        if t == 2 { return Int(bd.foliageColor) }
        return Int(bd.waterColor)
    }

    func animFor(_ id: Int, _ shape: Shape) -> Int {
        if id == Int(B.water) { return 1 }
        if id == Int(B.lava) { return 2 }
        if id == Int(B.nether_portal) || id == Int(B.end_portal) || id == Int(B.end_gateway) { return 3 }
        if id == Int(B.fire) || id == Int(B.soul_fire) { return 4 }
        if shape == .cross || shape == .crop || shape == .tallCross || shape == .rootsShape || shape == .netherWart || shape == .sweetBerry { return 6 }
        if IS_LEAVES[id] == 1 { return 5 }
        return 0
    }

    /// corner light = avg of the 4 cells adjacent to the corner on the face's outside plane
    func cornerLight(
        _ ox: Int, _ oy: Int, _ oz: Int,
        _ ux: Int, _ uy: Int, _ uz: Int,
        _ vx: Int, _ vy: Int, _ vz: Int,
        _ du: Int, _ dv: Int, _ sky: Bool
    ) -> Int {
        let get = sky ? skyAt : blkAt
        let a = get(ox, oy, oz)
        let b = get(ox + ux * du, oy + uy * du, oz + uz * du)
        let c = get(ox + vx * dv, oy + vy * dv, oz + vz * dv)
        let dcell = cellAt(ox + ux * du + vx * dv, oy + uy * du + vy * dv, oz + uz * du + vz * dv)
        let occluded = OPAQUE[dcell >> 4] == 1
            && OPAQUE[cellAt(ox + ux * du, oy + uy * du, oz + uz * du) >> 4] == 1
            && OPAQUE[cellAt(ox + vx * dv, oy + vy * dv, oz + vz * dv) >> 4] == 1
        let d = occluded ? a : get(ox + ux * du + vx * dv, oy + uy * du + vy * dv, oz + uz * du + vz * dv)
        return Int(detRound(Double(a + b + c + d) / 4))
    }

    func cornerAO(
        _ ox: Int, _ oy: Int, _ oz: Int,
        _ ux: Int, _ uy: Int, _ uz: Int,
        _ vx: Int, _ vy: Int, _ vz: Int,
        _ du: Int, _ dv: Int
    ) -> Int {
        let side1 = Int(OPAQUE[cellAt(ox + ux * du, oy + uy * du, oz + uz * du) >> 4])
        let side2 = Int(OPAQUE[cellAt(ox + vx * dv, oy + vy * dv, oz + vz * dv) >> 4])
        let corner = Int(OPAQUE[cellAt(ox + ux * du + vx * dv, oy + uy * du + vy * dv, oz + uz * du + vz * dv) >> 4])
        if side1 == 1 && side2 == 1 { return 0 }
        return 3 - (side1 + side2 + corner)
    }

    struct MaskData {
        var layer = 0
        var ao = [0, 0, 0, 0]
        var sky = [0, 0, 0, 0]
        var blk = [0, 0, 0, 0]
        var tint = 0
        var emissive = 0
    }

    func run() -> MeshOutput {
        greedyPass()
        blockPass()
        return MeshOutput(opaque: opaque.build(), cutout: cutout.build(), translucent: translucent.build())
    }

    private func greedyPass() {
        var maskKeyA = [Int](repeating: 0, count: 256)
        // Double, not UInt64: the golden baselines packs this key into a Float64Array
        // where tint*2^32 pushes the sum past 2^53 — the low bits (sky[0]) are
        // rounded away and quads with slightly different corner light merge.
        // That lossy equality is part of the golden baselines canonical mesh output.
        var maskKeyB = [Double](repeating: 0, count: 256)
        var maskCell = [Int](repeating: 0, count: 256)
        var maskData = [MaskData](repeating: MaskData(), count: 256)

        for dir in 0..<6 {
            let (nx, ny, nz) = FACE_OFF[dir]
            // axis setup: w = layer axis, u/v = in-plane axes
            var ux = 0, uy = 0, uz = 0, vx = 0, vy = 0, vz = 0
            if dir < 2 { ux = 1; vz = 1 }        // y faces: u=x, v=z
            else if dir < 4 { ux = 1; vy = 1 }   // z faces: u=x, v=y
            else { uz = 1; vy = 1 }              // x faces: u=z, v=y

            for layer in 0..<16 {
                var maskFilled = false
                for v in 0..<16 {
                    for u in 0..<16 {
                        let x = ux * u + vx * v + (dir >= 4 ? layer : 0)
                        let y = uy * u + vy * v + (dir < 2 ? layer : 0)
                        let z = uz * u + vz * v + (dir >= 2 && dir < 4 ? layer : 0)
                        let mi = v * 16 + u
                        maskCell[mi] = 0
                        let cell = cellAt(x, y, z)
                        if cell == 0 { continue }
                        let id = cell >> 4
                        if FULL_CUBE[id] == 0 || SHAPE_OF[id] != Shape.cube.rawValue { continue }
                        // neighbor cull
                        let ncell = cellAt(x + nx, y + ny, z + nz)
                        let nid = ncell >> 4
                        if OPAQUE[nid] == 1 { continue }
                        if CULL_SAME[id] == 1 && nid == id { continue }
                        if TRANSLUCENT[id] == 1 && nid == id { continue }
                        // light + AO at 4 corners (outside cell)
                        let ox = x + nx, oy = y + ny, oz = z + nz
                        let useAO = AO_OF[id] == 1
                        var ao = [0, 0, 0, 0]
                        var sky = [0, 0, 0, 0]
                        var blk = [0, 0, 0, 0]
                        // corner order: (-u,-v) (+u,-v) (+u,+v) (-u,+v)
                        let dirs = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
                        for ci in 0..<4 {
                            let (du, dv) = dirs[ci]
                            ao[ci] = useAO ? cornerAO(ox, oy, oz, ux, uy, uz, vx, vy, vz, du, dv) : 3
                            sky[ci] = cornerLight(ox, oy, oz, ux, uy, uz, vx, vy, vz, du, dv, true)
                            blk[ci] = cornerLight(ox, oy, oz, ux, uy, uz, vx, vy, vz, du, dv, false)
                        }
                        let tile = Int(TILE_TABLE[(Int(cell) << 3) | dir])
                        var tint = tintFor(cell, x, z)
                        if let gate = PACK_TINT_GATE, gate[tile] == 0 { tint = WHITE }
                        maskCell[mi] = cell | 0x10000 // mark filled
                        maskKeyA[mi] = (tile << 8) | (ao[0] << 0) | (ao[1] << 2) | (ao[2] << 4) | (ao[3] << 6) | (id << 20)
                        maskKeyB[mi] = Double(sky[0]) + Double(sky[1]) * 16 + Double(sky[2]) * 256 + Double(sky[3]) * 4096
                            + Double(blk[0]) * 65536 + Double(blk[1]) * 1048576 + Double(blk[2]) * 16777216
                            + Double(blk[3]) * 268435456 + Double(tint) * 4294967296
                        maskData[mi] = MaskData(layer: tile, ao: ao, sky: sky, blk: blk, tint: tint, emissive: Int(EMISSIVE[id]))
                        maskFilled = true
                    }
                }
                if !maskFilled { continue }
                // greedy merge
                for v in 0..<16 {
                    var u = 0
                    while u < 16 {
                        let mi = v * 16 + u
                        if maskCell[mi] == 0 { u += 1; continue }
                        let keyA = maskKeyA[mi], keyB = maskKeyB[mi]
                        // expand width
                        var w = 1
                        while !input.noMerge && u + w < 16 {
                            let mj = v * 16 + u + w
                            if maskCell[mj] == 0 || maskKeyA[mj] != keyA || maskKeyB[mj] != keyB { break }
                            w += 1
                        }
                        // expand height
                        var h = 1
                        outer: while !input.noMerge && v + h < 16 {
                            for du in 0..<w {
                                let mj = (v + h) * 16 + u + du
                                if maskCell[mj] == 0 || maskKeyA[mj] != keyA || maskKeyB[mj] != keyB { break outer }
                            }
                            h += 1
                        }
                        let d = maskData[mi]
                        let cell = maskCell[mi] & 0xffff
                        let id = cell >> 4
                        // emit quad: compute corners
                        let L = layer + (dir == 1 || dir == 3 || dir == 5 ? 1 : 0)
                        var corners: [(Double, Double, Double)] = []
                        // corner uv space: (u, v), (u+w, v), (u+w, v+h), (u, v+h)
                        let cuv = [(u, v), (u + w, v), (u + w, v + h), (u, v + h)]
                        for (cu, cv) in cuv {
                            let x = ux * cu + vx * cv + (dir >= 4 ? L : 0)
                            let y = uy * cu + vy * cv + (dir < 2 ? L : 0)
                            let z = uz * cu + vz * cv + (dir >= 2 && dir < 4 ? L : 0)
                            corners.append((Double(x), Double(y), Double(z)))
                        }
                        // winding: flip for negative dirs so faces point outward
                        let flip = (dir == 0 || dir == 3 || dir == 4)
                        let ord = flip ? [0, 3, 2, 1] : [0, 1, 2, 3]
                        let aoO = flip ? [d.ao[0], d.ao[3], d.ao[2], d.ao[1]] : d.ao
                        let skyO = flip ? [d.sky[0], d.sky[3], d.sky[2], d.sky[1]] : d.sky
                        let blkO = flip ? [d.blk[0], d.blk[3], d.blk[2], d.blk[1]] : d.blk
                        let uvO = flip ? [cuv[0], cuv[3], cuv[2], cuv[1]] : cuv
                        let target = TRANSLUCENT[id] == 1 ? translucent : (TRANSPARENT_RENDER[id] == 1 ? cutout : opaque)
                        target.quad(
                            corners[ord[0]].0, corners[ord[0]].1, corners[ord[0]].2,
                            corners[ord[1]].0, corners[ord[1]].1, corners[ord[1]].2,
                            corners[ord[2]].0, corners[ord[2]].1, corners[ord[2]].2,
                            corners[ord[3]].0, corners[ord[3]].1, corners[ord[3]].2,
                            Double(uvO[0].0 - u), Double(uvO[0].1 - v), Double(uvO[1].0 - u), Double(uvO[1].1 - v),
                            Double(uvO[2].0 - u), Double(uvO[2].1 - v), Double(uvO[3].0 - u), Double(uvO[3].1 - v),
                            d.layer, dir,
                            aoO[0], aoO[1], aoO[2], aoO[3],
                            skyO[0], skyO[1], skyO[2], skyO[3],
                            blkO[0], blkO[1], blkO[2], blkO[3],
                            d.emissive, d.tint, animFor(id, .cube)
                        )
                        // clear mask
                        for dv2 in 0..<h {
                            for du2 in 0..<w { maskCell[(v + dv2) * 16 + u + du2] = 0 }
                        }
                        u += w
                    }
                }
            }
        }
    }

    private func blockPass() {
        var boxes: [AABB] = []
        for y in 0..<16 {
            for z in 0..<16 {
                for x in 0..<16 {
                    let cell = cellAt(x, y, z)
                    if cell == 0 { continue }
                    let id = cell >> 4
                    let shape = Shape(rawValue: SHAPE_OF[id])!
                    if shape == .cube || shape == .air { continue }
                    let meta = cell & 15
                    let anim = animFor(id, shape)
                    let target = TRANSLUCENT[id] == 1 ? translucent : cutout
                    let sky = skyAt(x, y, z), blk = blkAt(x, y, z)
                    let skyUp = skyAt(x, y + 1, z), blkUp = blkAt(x, y + 1, z)
                    let s4 = max(sky, skyUp), b4 = max(blk, blkUp)
                    let tileOf: (Int) -> Int = { face in Int(TILE_TABLE[(Int(cell) << 3) | face]) }
                    var tint = tintFor(cell, x, z)
                    if let gate = PACK_TINT_GATE {
                        let crossLike = shape == .cross || shape == .crop || shape == .tallCross ||
                            shape == .rootsShape || shape == .netherWart || shape == .web ||
                            shape == .fire || shape == .sweetBerry || shape == .bambooSapling ||
                            shape == .caveVinesShape || shape == .hangingRoots ||
                            shape == .smallDripleafShape || shape == .pitcherCropShape ||
                            shape == .vine || shape == .glowLichen || shape == .sculkVein
                        if gate[tileOf(crossLike ? 2 : 1)] == 0 { tint = WHITE }
                    }

                    if shape == .liquid {
                        emitLiquid(target, x, y, z, cell, tileOf(1), tint, anim, s4, b4)
                        continue
                    }
                    if shape == .cross || shape == .crop || shape == .tallCross ||
                        shape == .rootsShape || shape == .netherWart || shape == .web ||
                        shape == .fire || shape == .sweetBerry || shape == .bambooSapling ||
                        shape == .caveVinesShape || shape == .hangingRoots || shape == .smallDripleafShape ||
                        shape == .pitcherCropShape {
                        emitCross(target, x, y, z, tileOf(2), s4, b4, tint, anim, shape == .crop)
                        continue
                    }
                    if shape == .vine || shape == .glowLichen || shape == .sculkVein {
                        emitWallQuads(target, x, y, z, cell, tileOf(2), s4, b4, tint)
                        continue
                    }
                    if shape == .redstoneWire {
                        emitWire(cutout, x, y, z, meta, s4, b4)
                        continue
                    }
                    if shape == .rail {
                        emitRail(cutout, x, y, z, cell >> 4, meta, tileOf(1), s4, b4)
                        continue
                    }
                    if shape == .lilyPad || shape == .frogspawn {
                        emitFlatTop(target, Double(x), Double(y), Double(z), tileOf(1), s4, b4, tint, 1.0 / 16)
                        continue
                    }
                    if shape == .portalShape || shape == .endPortalShape {
                        emitPortal(translucent, x, y, z, cell, tileOf(1), b4)
                        continue
                    }
                    if isTorchFixture(id) {
                        emitTorchFixture(target, x, y, z, cell, s4, b4)
                        continue
                    }
                    if shape == .lantern {
                        emitLanternFixture(target, x, y, z, cell, s4, b4)
                        continue
                    }
                    // generic: render the outline boxes with per-face culling
                    boxes.removeAll(keepingCapacity: true)
                    shapeBoxes(cell, { dx, dy, dz in self.cellAt(x + dx, y + dy, z + dz) }, &boxes, false)
                    for bx in boxes {
                        emitBox(target, x, y, z, bx, tileOf, s4, b4, tint, anim, Int(EMISSIVE[id]))
                    }
                }
            }
        }
    }

    // --- shape emitters -------------------------------------------------------

    private func faceTileOfBlock(_ id: UInt16, _ face: Int) -> Int {
        let def = blockDefs[Int(id)]
        return def.texFn?(0, face) ?? Int(def.tex[face])
    }

    private func isTorchFixture(_ id: Int) -> Bool {
        id == Int(B.torch) || id == Int(B.soul_torch) ||
            id == Int(B.redstone_torch) || id == Int(B.redstone_torch_off)
    }

    private func torchGlowTile(_ id: Int) -> Int {
        if id == Int(B.soul_torch) { return faceTileOfBlock(B.sea_lantern, 2) }
        if id == Int(B.redstone_torch) || id == Int(B.redstone_torch_off) { return faceTileOfBlock(B.redstone_block, 2) }
        return faceTileOfBlock(B.glowstone, 2)
    }

    private func lanternGlowTile(_ id: Int) -> Int {
        id == Int(B.soul_lantern) ? faceTileOfBlock(B.sea_lantern, 2) : faceTileOfBlock(B.glowstone, 2)
    }

    private func emitFixtureBox(
        _ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ box: AABB,
        _ tile: Int, _ sky: Int, _ blk: Int, _ emissive: Int = 0
    ) {
        emitBox(b, x, y, z, box, { _ in tile }, sky, blk, WHITE, 0, emissive)
    }

    private func emitTorchFixture(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ cell: Int, _ sky: Int, _ blk: Int) {
        let id = cell >> 4
        var boxes: [AABB] = []
        shapeBoxes(cell, { dx, dy, dz in self.cellAt(x + dx, y + dy, z + dz) }, &boxes, false)
        guard let outline = boxes.first else { return }

        let cx = (outline.x0 + outline.x1) * 0.5
        let cz = (outline.z0 + outline.z1) * 0.5
        let stemHalf = 1.0 / 16
        let headHalf = 2.0 / 16
        let stemTop = max(outline.y0 + 2.0 / 16, outline.y1 - 2.0 / 16)
        let headTop = min(1, outline.y1 + 1.0 / 16)
        let woodTile = faceTileOfBlock(B.oak_planks, 2)
        let glowTile = torchGlowTile(id)

        emitFixtureBox(
            b, x, y, z,
            aabb(cx - stemHalf, outline.y0, cz - stemHalf, cx + stemHalf, stemTop, cz + stemHalf),
            woodTile, sky, blk
        )
        emitFixtureBox(
            b, x, y, z,
            aabb(cx - headHalf, stemTop - 1.0 / 16, cz - headHalf, cx + headHalf, headTop, cz + headHalf),
            glowTile, sky, blk, Int(EMISSIVE[id])
        )
    }

    private func emitLanternFixture(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ cell: Int, _ sky: Int, _ blk: Int) {
        let id = cell >> 4
        let hang = (cell & 1) != 0
        let y0 = hang ? 1.0 / 16 : 0
        let frameTile = faceTileOfBlock(B.iron_block, 2)
        let glowTile = lanternGlowTile(id)

        let posts = [
            aabb(5 / 16, y0 + 1 / 16, 5 / 16, 6 / 16, y0 + 7 / 16, 6 / 16),
            aabb(10 / 16, y0 + 1 / 16, 5 / 16, 11 / 16, y0 + 7 / 16, 6 / 16),
            aabb(5 / 16, y0 + 1 / 16, 10 / 16, 6 / 16, y0 + 7 / 16, 11 / 16),
            aabb(10 / 16, y0 + 1 / 16, 10 / 16, 11 / 16, y0 + 7 / 16, 11 / 16),
        ]

        emitFixtureBox(b, x, y, z, aabb(6 / 16, y0 + 2 / 16, 6 / 16, 10 / 16, y0 + 7 / 16, 10 / 16), glowTile, sky, blk, Int(EMISSIVE[id]))
        emitFixtureBox(b, x, y, z, aabb(5 / 16, y0, 5 / 16, 11 / 16, y0 + 1 / 16, 11 / 16), frameTile, sky, blk)
        emitFixtureBox(b, x, y, z, aabb(5 / 16, y0 + 7 / 16, 5 / 16, 11 / 16, y0 + 8 / 16, 11 / 16), frameTile, sky, blk)
        for post in posts {
            emitFixtureBox(b, x, y, z, post, frameTile, sky, blk)
        }
        if hang {
            emitFixtureBox(b, x, y, z, aabb(7 / 16, 0, 7 / 16, 9 / 16, y0, 9 / 16), frameTile, sky, blk)
        } else {
            emitFixtureBox(b, x, y, z, aabb(7 / 16, y0 + 8 / 16, 7 / 16, 9 / 16, y0 + 10 / 16, 9 / 16), frameTile, sky, blk)
        }
    }

    private func emitCross(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ tile: Int, _ sky: Int, _ blk: Int, _ tint: Int, _ anim: Int, _ inset: Bool) {
        let o = inset ? 4.0 / 16 : 1.6 / 16
        let xd = Double(x), yd = Double(y), zd = Double(z)
        let pairs: [(Double, Double, Double, Double)] = [
            (o, o, 1 - o, 1 - o), (1 - o, o, o, 1 - o), (o, 1 - o, 1 - o, o), (1 - o, 1 - o, o, o),
        ]
        // a real X needs the two PERPENDICULAR diagonals — pairs[3] is pairs[0]
        // reversed, which shipped every cross plant as a single flat plane
        let firstSet = inset ? [pairs[0], pairs[2]] : [pairs[0], pairs[1]]
        for (x0, z0, x1, z1) in firstSet {
            for flip in [false, true] {
                let a = flip ? (xd + x1, zd + z1) : (xd + x0, zd + z0)
                let c = flip ? (xd + x0, zd + z0) : (xd + x1, zd + z1)
                b.quad(
                    a.0, yd, a.1, c.0, yd, c.1, c.0, yd + 1, c.1, a.0, yd + 1, a.1,
                    0, 1, 1, 1, 1, 0, 0, 0,
                    tile, 3, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, anim
                )
            }
        }
        if inset {
            for (x0, z0, x1, z1) in [pairs[1], pairs[3]] {
                for flip in [false, true] {
                    let a = flip ? (xd + x1, zd + z1) : (xd + x0, zd + z0)
                    let c = flip ? (xd + x0, zd + z0) : (xd + x1, zd + z1)
                    b.quad(
                        a.0, yd, a.1, c.0, yd, c.1, c.0, yd + 1, c.1, a.0, yd + 1, a.1,
                        0, 1, 1, 1, 1, 0, 0, 0,
                        tile, 3, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, anim
                    )
                }
            }
        }
    }

    private func emitFlatTop(_ b: MeshBuilder, _ x: Double, _ y: Double, _ z: Double, _ tile: Int, _ sky: Int, _ blk: Int, _ tint: Int, _ h: Double) {
        for flip in [0, 1] {
            b.quad(
                x + (flip == 1 ? 1 : 0), y + h, z, x + (flip == 1 ? 0 : 1), y + h, z,
                x + (flip == 1 ? 0 : 1), y + h, z + 1, x + (flip == 1 ? 1 : 0), y + h, z + 1,
                Double(flip), 0, Double(1 - flip), 0, Double(1 - flip), 1, Double(flip), 1,
                tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, 0
            )
        }
    }

    private func emitWallQuads(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ cell: Int, _ tile: Int, _ sky: Int, _ blk: Int, _ tint: Int) {
        let id = cell >> 4, meta = cell & 15
        let e = 0.8 / 16
        let xd = Double(x), yd = Double(y), zd = Double(z)
        if id == Int(B.vine) {
            // meta bits: 1=N 2=S 4=W 8=E
            var faces: [(Double, Double, Double, Double, Int)] = []
            if meta & 1 != 0 { faces.append((xd, yd, zd + e, xd + 1, 2)) }
            if meta & 2 != 0 { faces.append((xd, yd, zd + 1 - e, xd + 1, 3)) }
            if meta & 4 != 0 { faces.append((xd + e, yd, zd, zd + 1, 4)) }
            if meta & 8 != 0 { faces.append((xd + 1 - e, yd, zd, zd + 1, 5)) }
            for f in faces {
                if f.4 < 4 {
                    for flip in [false, true] {
                        b.quad(
                            flip ? f.2 : f.0, yd, f.1, flip ? f.0 : f.2, yd, f.1,
                            flip ? f.0 : f.2, yd + 1, f.1, flip ? f.2 : f.0, yd + 1, f.1,
                            0, 1, 1, 1, 1, 0, 0, 0, tile, f.4, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, 5
                        )
                    }
                } else {
                    for flip in [false, true] {
                        b.quad(
                            f.0, yd, flip ? f.3 : f.2, f.0, yd, flip ? f.2 : f.3,
                            f.0, yd + 1, flip ? f.2 : f.3, f.0, yd + 1, flip ? f.3 : f.2,
                            0, 1, 1, 1, 1, 0, 0, 0, tile, f.4, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, 5
                        )
                    }
                }
            }
            // ceiling vine when block above is solid
            if OPAQUE[cellAt(x, y + 1, z) >> 4] == 1 {
                emitFlatTop(b, xd, yd - 1.0 / 16 + 15.0 / 16 - 14.0 / 16, zd, tile, sky, blk, tint, 15.0 / 16)
            }
            return
        }
        // glow lichen / sculk vein: meta = attach dir 0..5
        let d = meta % 6
        if d == 0 { emitFlatTop(b, xd, yd - 14.0 / 16, zd, tile, sky, blk, tint, 15.0 / 16) }
        else if d == 1 { emitFlatTop(b, xd, yd + 14.2 / 16 - 14.0 / 16, zd, tile, sky, blk, tint, 1.0 / 16 + 14.2 / 16 - 15.0 / 16 + 14.0 / 16) }
        else {
            let zq = d == 2 ? zd + e : d == 3 ? zd + 1 - e : 0
            let xq = d == 4 ? xd + e : d == 5 ? xd + 1 - e : 0
            for flip in [false, true] {
                if d < 4 {
                    b.quad(
                        flip ? xd + 1 : xd, yd, zq, flip ? xd : xd + 1, yd, zq,
                        flip ? xd : xd + 1, yd + 1, zq, flip ? xd + 1 : xd, yd + 1, zq,
                        0, 1, 1, 1, 1, 0, 0, 0, tile, d, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, 0
                    )
                } else {
                    b.quad(
                        xq, yd, flip ? zd + 1 : zd, xq, yd, flip ? zd : zd + 1,
                        xq, yd + 1, flip ? zd : zd + 1, xq, yd + 1, flip ? zd + 1 : zd,
                        0, 1, 1, 1, 1, 0, 0, 0, tile, d, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, tint, 0
                    )
                }
            }
        }
    }

    private func wireConnects(_ x: Int, _ y: Int, _ z: Int, _ dx: Int, _ dz: Int) -> Bool {
        let n = cellAt(x + dx, y, z + dz)
        let nid = UInt16(n >> 4)
        if nid == B.redstone_wire || nid == B.repeater || nid == B.repeater_on || nid == B.comparator || nid == B.comparator_on ||
            nid == B.redstone_torch || nid == B.redstone_torch_off || nid == B.lever || nid == B.target || nid == B.daylight_detector { return true }
        // wire up a block
        if OPAQUE[Int(nid)] == 1 && UInt16(cellAt(x + dx, y + 1, z + dz) >> 4) == B.redstone_wire { return true }
        // wire down a block
        if OPAQUE[Int(nid)] == 0 && UInt16(cellAt(x + dx, y - 1, z + dz) >> 4) == B.redstone_wire { return true }
        return false
    }

    private func emitWire(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ power: Int, _ sky: Int, _ blk: Int) {
        let bright = 0.3 + (Double(power) / 15) * 0.7
        let tint = (Int(detRound(255 * bright)) << 16) | (Int(detRound(40 * bright)) << 8) | Int(detRound(30 * bright))
        let h = 0.6 / 16
        let xd = Double(x), yd = Double(y), zd = Double(z)
        let conn = [
            wireConnects(x, y, z, 0, -1), wireConnects(x, y, z, 0, 1),
            wireConnects(x, y, z, -1, 0), wireConnects(x, y, z, 1, 0),
        ]
        let any = conn[0] || conn[1] || conn[2] || conn[3]
        // dot
        if !any || (conn[0] && conn[1] && conn[2] && conn[3]) || ((conn[0] || conn[1]) && (conn[2] || conn[3])) {
            quadFlat(b, xd, yd + h, zd, xd + 1, zd + 1, TILE_WIRE_DOT, sky, blk, tint)
        }
        if conn[0] { quadFlatRot(b, xd, yd + h, zd, xd + 1, zd + 0.5, TILE_WIRE_LINE, sky, blk, tint, true) }
        if conn[1] { quadFlatRot(b, xd, yd + h, zd + 0.5, xd + 1, zd + 1, TILE_WIRE_LINE, sky, blk, tint, true) }
        if conn[2] { quadFlatRot(b, xd, yd + h, zd, xd + 0.5, zd + 1, TILE_WIRE_LINE, sky, blk, tint, false) }
        if conn[3] { quadFlatRot(b, xd + 0.5, yd + h, zd, xd + 1, zd + 1, TILE_WIRE_LINE, sky, blk, tint, false) }
        // wall climbs
        for d in 0..<4 {
            let dx = [0, 0, -1, 1][d], dz = [-1, 1, 0, 0][d]
            let n = cellAt(x + dx, y, z + dz)
            if OPAQUE[n >> 4] == 1 && UInt16(cellAt(x + dx, y + 1, z + dz) >> 4) == B.redstone_wire {
                let e = 0.6 / 16
                let px = dx == -1 ? xd + e : dx == 1 ? xd + 1 - e : 0
                let pz = dz == -1 ? zd + e : dz == 1 ? zd + 1 - e : 0
                for flip in [false, true] {
                    if d < 2 {
                        b.quad(
                            flip ? xd + 1 : xd, yd, pz, flip ? xd : xd + 1, yd, pz,
                            flip ? xd : xd + 1, yd + 1, pz, flip ? xd + 1 : xd, yd + 1, pz,
                            0, 1, 1, 1, 1, 0, 0, 0, TILE_WIRE_LINE, d + 2, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 1, tint, 0
                        )
                    } else {
                        b.quad(
                            px, yd, flip ? zd + 1 : zd, px, yd, flip ? zd : zd + 1,
                            px, yd + 1, flip ? zd : zd + 1, px, yd + 1, flip ? zd + 1 : zd,
                            0, 1, 1, 1, 1, 0, 0, 0, TILE_WIRE_LINE, d + 2, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 1, tint, 0
                        )
                    }
                }
            }
        }
    }

    private func quadFlat(_ b: MeshBuilder, _ x0: Double, _ y: Double, _ z0: Double, _ x1: Double, _ z1: Double, _ tile: Int, _ sky: Int, _ blk: Int, _ tint: Int) {
        b.quad(
            x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1,
            0, 0, 1, 0, 1, 1, 0, 1,
            tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 1, tint, 0
        )
    }

    private func quadFlatRot(_ b: MeshBuilder, _ x0: Double, _ y: Double, _ z0: Double, _ x1: Double, _ z1: Double, _ tile: Int, _ sky: Int, _ blk: Int, _ tint: Int, _ vertical: Bool) {
        if vertical {
            b.quad(
                x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1,
                0, 0, 0, 1, 1, 1, 1, 0,
                tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 1, tint, 0
            )
        } else {
            quadFlat(b, x0, y, z0, x1, z1, tile, sky, blk, tint)
        }
    }

    private func emitRail(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ id: Int, _ meta: Int, _ tile: Int, _ sky: Int, _ blk: Int) {
        // plain rail: meta IS the shape (0-9, curves 6-9). powered/detector/
        // activator rails: bit3 = powered flag, shape lives in bits 0-2 — a
        // meta threshold can't distinguish a powered straight rail (8/9)
        // from a plain curve (8/9)
        let shape = id == Int(B.rail) ? meta : (meta & 7)
        let h = 1.0 / 16
        let xd = Double(x), yd = Double(y), zd = Double(z)
        // ascending rails: tilt the quad
        if shape >= 2 && shape <= 5 {
            // 2=ascE 3=ascW 4=ascN 5=ascS
            if shape == 2 { // rises toward +x
                b.quad(xd, yd + h, zd, xd + 1, yd + 1 + h, zd, xd + 1, yd + 1 + h, zd + 1, xd, yd + h, zd + 1,
                       0, 0, 0, 1, 1, 1, 1, 0, tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, WHITE, 0)
            } else if shape == 3 {
                b.quad(xd, yd + 1 + h, zd, xd + 1, yd + h, zd, xd + 1, yd + h, zd + 1, xd, yd + 1 + h, zd + 1,
                       0, 0, 0, 1, 1, 1, 1, 0, tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, WHITE, 0)
            } else if shape == 4 {
                b.quad(xd, yd + 1 + h, zd, xd + 1, yd + 1 + h, zd, xd + 1, yd + h, zd + 1, xd, yd + h, zd + 1,
                       0, 0, 1, 0, 1, 1, 0, 1, tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, WHITE, 0)
            } else {
                b.quad(xd, yd + h, zd, xd + 1, yd + h, zd, xd + 1, yd + 1 + h, zd + 1, xd, yd + 1 + h, zd + 1,
                       0, 0, 1, 0, 1, 1, 0, 1, tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, WHITE, 0)
            }
            return
        }
        // flat: 0 NS, 1 EW, curves 6-9
        if shape == 1 {
            b.quad(xd, yd + h, zd, xd + 1, yd + h, zd, xd + 1, yd + h, zd + 1, xd, yd + h, zd + 1,
                   0, 0, 0, 1, 1, 1, 1, 0, tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, 0, WHITE, 0)
        } else {
            quadFlat(b, xd, yd + h, zd, xd + 1, zd + 1, tile, sky, blk, WHITE)
        }
    }

    private func emitPortal(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ cell: Int, _ tile: Int, _ blk: Int) {
        let id = cell >> 4
        let xd = Double(x), yd = Double(y), zd = Double(z)
        if id == Int(B.end_portal) || id == Int(B.end_gateway) {
            emitFlatTop(b, xd, yd - 4.0 / 16, zd, tile, 15, 15, WHITE, 12.0 / 16)
            return
        }
        // nether portal: vertical slab along axis (meta 0 = X axis, 1 = Z axis)
        let axis = cell & 1
        if axis == 0 {
            for zq in [6.0 / 16, 10.0 / 16] {
                for flip in [false, true] {
                    let a = flip ? xd + 1 : xd, c = flip ? xd : xd + 1
                    b.quad(a, yd, zd + zq, c, yd, zd + zq, c, yd + 1, zd + zq, a, yd + 1, zd + zq,
                           0, 1, 1, 1, 1, 0, 0, 0, tile, 2, 3, 3, 3, 3, 15, 15, 15, 15, blk, blk, blk, blk, 1, WHITE, 3)
                }
            }
        } else {
            for xq in [6.0 / 16, 10.0 / 16] {
                for flip in [false, true] {
                    let a = flip ? zd + 1 : zd, c = flip ? zd : zd + 1
                    b.quad(xd + xq, yd, a, xd + xq, yd, c, xd + xq, yd + 1, c, xd + xq, yd + 1, a,
                           0, 1, 1, 1, 1, 0, 0, 0, tile, 4, 3, 3, 3, 3, 15, 15, 15, 15, blk, blk, blk, blk, 1, WHITE, 3)
                }
            }
        }
    }

    private func heightOfFluid(_ cell: Int) -> Double {
        let level = cell & 7
        if cell & 8 != 0 { return 1 }
        if level == 0 { return 14.0 / 16 }
        return max(2.0 / 16, Double(8 - level) / 8 * 14 / 16)
    }

    private func emitLiquid(_ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ cell: Int, _ tile: Int, _ tint: Int, _ anim: Int, _ sky: Int, _ blk: Int) {
        let id = cell >> 4
        let xd = Double(x), yd = Double(y), zd = Double(z)
        let sameAbove = (cellAt(x, y + 1, z) >> 4) == id
        let hSelf = sameAbove ? 1 : heightOfFluid(cell)
        let em = id == Int(B.lava) ? 1 : 0
        // corner heights: max over the 4 cells sharing the corner
        func cornerH(_ cx: Int, _ cz: Int) -> Double {
            if sameAbove { return 1 }
            var h = hSelf
            for (dx, dz) in [(cx - 1, cz - 1), (cx, cz - 1), (cx - 1, cz), (cx, cz)] {
                if dx == 0 && dz == 0 { continue }
                let n = cellAt(x + dx, y, z + dz)
                if (n >> 4) == id {
                    if (cellAt(x + dx, y + 1, z + dz) >> 4) == id { return 1 }
                    h = max(h, heightOfFluid(n))
                }
            }
            return h
        }
        let h00 = cornerH(0, 0), h10 = cornerH(1, 0), h11 = cornerH(1, 1), h01 = cornerH(0, 1)
        // top face (if not fully covered by same fluid)
        if !sameAbove {
            b.quad(
                xd, yd + h00, zd, xd + 1, yd + h10, zd, xd + 1, yd + h11, zd + 1, xd, yd + h01, zd + 1,
                0, 0, 1, 0, 1, 1, 0, 1,
                tile, 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, em, tint, anim
            )
            // underside of surface (visible from below water)
            b.quad(
                xd, yd + h00, zd, xd, yd + h01, zd + 1, xd + 1, yd + h11, zd + 1, xd + 1, yd + h10, zd,
                0, 0, 0, 1, 1, 1, 1, 0,
                tile, 0, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, em, tint, anim
            )
        }
        // sides + bottom: cull against same fluid and opaque
        let sides: [(Int, Int, Int)] = [(0, -1, 2), (0, 1, 3), (-1, 0, 4), (1, 0, 5)]
        for (dx, dz, dir) in sides {
            let n = cellAt(x + dx, y, z + dz)
            let nid = n >> 4
            if nid == id || OPAQUE[nid] == 1 || (isWaterlogged(UInt16(n)) && id == Int(B.water)) { continue }
            let hA = dir == 2 ? h00 : dir == 3 ? h01 : dir == 4 ? h00 : h10
            let hB = dir == 2 ? h10 : dir == 3 ? h11 : dir == 4 ? h01 : h11
            if dir < 4 {
                let zz = dir == 2 ? zd : zd + 1
                let flip = dir == 3
                b.quad(
                    flip ? xd + 1 : xd, yd, zz, flip ? xd : xd + 1, yd, zz,
                    flip ? xd : xd + 1, yd + (flip ? hA : hB), zz, flip ? xd + 1 : xd, yd + (flip ? hB : hA), zz,
                    0, 1, 1, 1, 1, 0, 0, 0,
                    tile, dir, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, em, tint, anim
                )
            } else {
                let xx = dir == 4 ? xd : xd + 1
                let flip = dir == 4
                b.quad(
                    xx, yd, flip ? zd + 1 : zd, xx, yd, flip ? zd : zd + 1,
                    xx, yd + (flip ? hA : hB), flip ? zd : zd + 1, xx, yd + (flip ? hB : hA), flip ? zd + 1 : zd,
                    0, 1, 1, 1, 1, 0, 0, 0,
                    tile, dir, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, em, tint, anim
                )
            }
        }
        let below = cellAt(x, y - 1, z)
        if (below >> 4) != id && OPAQUE[below >> 4] == 0 {
            b.quad(
                xd, yd, zd, xd, yd, zd + 1, xd + 1, yd, zd + 1, xd + 1, yd, zd,
                0, 0, 0, 1, 1, 1, 1, 0,
                tile, 0, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, em, tint, anim
            )
        }
    }

    private func emitBox(
        _ b: MeshBuilder, _ x: Int, _ y: Int, _ z: Int, _ box: AABB,
        _ tileOf: (Int) -> Int, _ sky: Int, _ blk: Int, _ tint: Int, _ anim: Int, _ emissive: Int
    ) {
        let x0 = Double(x) + box.x0, y0 = Double(y) + box.y0, z0 = Double(z) + box.z0
        let x1 = Double(x) + box.x1, y1 = Double(y) + box.y1, z1 = Double(z) + box.z1
        @inline(__always) func fullLow(_ v: Double) -> Bool { v <= 0.001 }
        @inline(__always) func fullHigh(_ v: Double) -> Bool { v >= 0.999 }
        // bottom (0)
        if !(fullLow(box.y0) && OPAQUE[cellAt(x, y - 1, z) >> 4] == 1) {
            b.quad(x0, y0, z0, x0, y0, z1, x1, y0, z1, x1, y0, z0,
                   box.x0, box.z0, box.x0, box.z1, box.x1, box.z1, box.x1, box.z0,
                   tileOf(0), 0, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, emissive, tint, anim)
        }
        // top (1)
        if !(fullHigh(box.y1) && OPAQUE[cellAt(x, y + 1, z) >> 4] == 1) {
            b.quad(x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1,
                   box.x0, box.z0, box.x1, box.z0, box.x1, box.z1, box.x0, box.z1,
                   tileOf(1), 1, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, emissive, tint, anim)
        }
        // north -z (2) — vertex order matches the greedy cube winding (back-culled)
        if !(fullLow(box.z0) && OPAQUE[cellAt(x, y, z - 1) >> 4] == 1) {
            b.quad(x0, y0, z0, x1, y0, z0, x1, y1, z0, x0, y1, z0,
                   1 - box.x0, 1 - box.y0, 1 - box.x1, 1 - box.y0, 1 - box.x1, 1 - box.y1, 1 - box.x0, 1 - box.y1,
                   tileOf(2), 2, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, emissive, tint, anim)
        }
        // south +z (3)
        if !(fullHigh(box.z1) && OPAQUE[cellAt(x, y, z + 1) >> 4] == 1) {
            b.quad(x1, y0, z1, x0, y0, z1, x0, y1, z1, x1, y1, z1,
                   box.x1, 1 - box.y0, box.x0, 1 - box.y0, box.x0, 1 - box.y1, box.x1, 1 - box.y1,
                   tileOf(3), 3, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, emissive, tint, anim)
        }
        // west -x (4)
        if !(fullLow(box.x0) && OPAQUE[cellAt(x - 1, y, z) >> 4] == 1) {
            b.quad(x0, y0, z1, x0, y0, z0, x0, y1, z0, x0, y1, z1,
                   box.z1, 1 - box.y0, box.z0, 1 - box.y0, box.z0, 1 - box.y1, box.z1, 1 - box.y1,
                   tileOf(4), 4, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, emissive, tint, anim)
        }
        // east +x (5)
        if !(fullHigh(box.x1) && OPAQUE[cellAt(x + 1, y, z) >> 4] == 1) {
            b.quad(x1, y0, z0, x1, y0, z1, x1, y1, z1, x1, y1, z0,
                   1 - box.z0, 1 - box.y0, 1 - box.z1, 1 - box.y0, 1 - box.z1, 1 - box.y1, 1 - box.z0, 1 - box.y1,
                   tileOf(5), 5, 3, 3, 3, 3, sky, sky, sky, sky, blk, blk, blk, blk, emissive, tint, anim)
        }
    }
}
