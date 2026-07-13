// Incremental flood-fill lighting — LightEngine.
// computeLocalLight (LocalLight.swift) does initial chunk lighting on flat
// arrays; this engine handles seam stitching after adoption and incremental
// add/remove on block edits. Frontier rule preserved from the golden baselines: never
// keep propagating into a missing chunk or border cells ping-pong forever.
//
// One deliberate divergence: the golden baselines packs dirty-section keys into a
// float ((cx*(1<<26)+cz)*64+sy) which silently rounds sy bits at the f64
// mantissa edge — a latent remesh-skipping bug. Dirty marking only affects
// remesh scheduling (never light values), so Swift uses exact Int packing.

import Foundation

private let DX = [0, 0, 0, 0, -1, 1]
private let DY = [-1, 1, 0, 0, 0, 0]
private let DZ = [0, 0, -1, 1, 0, 0]

final class LightQueue {
    var xs = [Int32](repeating: 0, count: 1 << 16)
    var ys = [Int32](repeating: 0, count: 1 << 16)
    var zs = [Int32](repeating: 0, count: 1 << 16)
    var vs = [Int32](repeating: 0, count: 1 << 16)
    var head = 0
    var tail = 0

    func push(_ x: Int, _ y: Int, _ z: Int, _ v: Int) {
        if tail >= xs.count { grow() }
        xs[tail] = Int32(x); ys[tail] = Int32(y); zs[tail] = Int32(z); vs[tail] = Int32(v)
        tail += 1
    }
    private func grow() {
        xs.append(contentsOf: [Int32](repeating: 0, count: xs.count))
        ys.append(contentsOf: [Int32](repeating: 0, count: ys.count))
        zs.append(contentsOf: [Int32](repeating: 0, count: zs.count))
        vs.append(contentsOf: [Int32](repeating: 0, count: vs.count))
    }
    var empty: Bool { head >= tail }
    func reset() { head = 0; tail = 0 }
}

public final class LightEngine {
    private unowned let world: World
    private let addSky = LightQueue()
    private let delSky = LightQueue()
    private let addBlock = LightQueue()
    private let delBlock = LightQueue()
    private var dirtySections = Set<Int64>()

    public init(_ world: World) {
        self.world = world
    }

    /// initial lighting for a freshly generated chunk (call when 3×3 ready or alone)
    public func initChunkLight(_ c: Chunk) {
        let w = world
        let minY = c.minY, H = c.height
        if w.info.hasSky {
            // top-down skylight columns
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    var level = 15
                    var y = minY + H - 1
                    while y >= minY {
                        let cell = c.get(x, y, z)
                        let op = Int(LIGHT_OPACITY[Int(cell >> 4)])
                        if op > 0 { level = max(0, level - max(op, 1)) }
                        else if level < 15 { level = max(0, level - 1) }
                        if level == 0 {
                            // zero the rest of the column quickly
                            var yy = y
                            while yy >= minY {
                                let cc = c.get(x, yy, z)
                                if lightEmitOf(cc) > 0 { break } // emitters handled below
                                c.setSky(x, yy, z, 0)
                                yy -= 1
                            }
                            break
                        }
                        c.setSky(x, y, z, level)
                        if level < 15 || columnNeedsSpread(c, x, y, z) {
                            addSky.push(c.cx * 16 + x, y, c.cz * 16 + z, level)
                        }
                        y -= 1
                    }
                }
            }
            // seed horizontal spread at exposed column borders
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    let h = c.heightAt(x, z)
                    var y = minY + H - 1
                    while y > h {
                        if x == 0 || x == 15 || z == 0 || z == 15 ||
                            c.heightAt(max(0, x - 1), z) > y || c.heightAt(min(15, x + 1), z) > y ||
                            c.heightAt(x, max(0, z - 1)) > y || c.heightAt(x, min(15, z + 1)) > y {
                            addSky.push(c.cx * 16 + x, y, c.cz * 16 + z, c.getSky(x, y, z))
                        }
                        y -= 1
                    }
                }
            }
        }
        // block light emitters
        for i in 0..<c.blocks.count {
            let cell = c.blocks[i]
            if cell == 0 { continue }
            let emit = lightEmitOf(cell)
            if emit > 0 {
                let x = i & 15, z = (i >> 4) & 15, y = (i >> 8) + minY
                c.setBlockLight(x, y, z, emit)
                addBlock.push(c.cx * 16 + x, y, c.cz * 16 + z, emit)
            }
        }
        c.status = .lit
        propagate()
    }
    private func columnNeedsSpread(_ c: Chunk, _ x: Int, _ y: Int, _ z: Int) -> Bool {
        y <= c.heightAt(x, z) + 1
    }

    /// Seam exchange for a chunk whose local light was precomputed (worker).
    public func stitchChunk(_ c: Chunk) {
        let w = world
        let minY = c.minY, H = c.height
        let hasSky = w.info.hasSky
        let YS = 256
        let x0 = c.cx * 16, z0 = c.cz * 16
        for (edge, ox, oz) in [(0, -1, 0), (1, 1, 0), (2, 0, -1), (3, 0, 1)] {
            guard let n = w.getChunk(c.cx + ox, c.cz + oz), n.status != .empty else { continue }
            for i in 0..<16 {
                // border cell in c and the adjacent cell in n, as flat-array bases
                let ax = edge == 0 ? 0 : edge == 1 ? 15 : i
                let az = edge == 2 ? 0 : edge == 3 ? 15 : i
                let bx = edge == 0 ? 15 : edge == 1 ? 0 : i
                let bz = edge == 2 ? 15 : edge == 3 ? 0 : i
                let aCol = az * 16 + ax, bCol = bz * 16 + bx
                let wxA = x0 + ax, wzA = z0 + az
                let wxB = wxA + ox, wzB = wzA + oz
                for y in 0..<H {
                    let ai = y * YS + aCol, bi = y * YS + bCol
                    if hasSky {
                        let aS = Int(c.skyLight[ai]), bS = Int(n.skyLight[bi])
                        if aS > bS + 1 { addSky.push(wxA, minY + y, wzA, aS) }
                        else if bS > aS + 1 { addSky.push(wxB, minY + y, wzB, bS) }
                    }
                    let aB = Int(c.blockLight[ai]), bB = Int(n.blockLight[bi])
                    if aB > bB + 1 { addBlock.push(wxA, minY + y, wzA, aB) }
                    else if bB > aB + 1 { addBlock.push(wxB, minY + y, wzB, bB) }
                }
            }
        }
        c.status = .lit
        propagate()
    }

    public func onBlockChanged(_ x: Int, _ y: Int, _ z: Int, _ oldCell: Int, _ newCell: Int) {
        let w = world
        let oldEmit = lightEmitOf(UInt16(oldCell)), newEmit = lightEmitOf(UInt16(newCell))
        let oldOp = Int(LIGHT_OPACITY[oldCell >> 4]), newOp = Int(LIGHT_OPACITY[newCell >> 4])

        if oldEmit > 0 {
            delBlock.push(x, y, z, oldEmit)
            _ = setBL(x, y, z, 0)
        }
        if newEmit > 0 {
            _ = setBL(x, y, z, newEmit)
            addBlock.push(x, y, z, newEmit)
        }
        if newOp > oldOp {
            // got more opaque: remove light passing through
            let bl = getBL(x, y, z)
            if bl > 0 && newEmit == 0 { delBlock.push(x, y, z, bl); _ = setBL(x, y, z, 0) }
            if w.info.hasSky {
                let sl = getSL(x, y, z)
                if sl > 0 { delSky.push(x, y, z, sl); _ = setSL(x, y, z, 0) }
            }
        } else if newOp < oldOp {
            // became transparent: pull light in from neighbors
            for d in 0..<6 {
                let nx = x + DX[d], ny = y + DY[d], nz = z + DZ[d]
                let nbl = getBL(nx, ny, nz)
                if nbl > 1 { addBlock.push(nx, ny, nz, nbl) }
                if w.info.hasSky {
                    let nsl = getSL(nx, ny, nz)
                    if nsl > 0 { addSky.push(nx, ny, nz, nsl) }
                }
            }
            if w.info.hasSky && y >= w.heightAt(x, z) {
                // direct sky above again — re-seed column
                _ = setSL(x, y, z, 15)
                addSky.push(x, y, z, 15)
            }
        }
        propagate()
    }

    /// drain queues — called from world tick and after edits
    public func flush() {
        if !addSky.empty || !delSky.empty || !addBlock.empty || !delBlock.empty {
            propagate()
        }
    }

    private func propagate() {
        removePass(delBlock, addBlock, false)
        addPass(addBlock, false)
        if world.info.hasSky {
            removePass(delSky, addSky, true)
            addPass(addSky, true)
        }
        delBlock.reset(); addBlock.reset()
        delSky.reset(); addSky.reset()
        // mark dirty sections for remesh
        for key in dirtySections {
            let sy = Int(key & 63)
            let cz = Int((key >> 6) & 0x3FF_FFFF) - (1 << 25)
            let cx = Int(key >> 32) - (1 << 25)
            if let c = world.getChunk(cx, cz) {
                c.dirty[max(0, min(c.sections - 1, sy))] = true
                c.version += 1
                world.hooks.onSectionDirty(cx, cz, sy)
            }
        }
        dirtySections.removeAll(keepingCapacity: true)
    }

    private func markDirty(_ x: Int, _ y: Int, _ z: Int) {
        let cx = Int64(floorDiv(x, 16) + (1 << 25))
        let cz = Int64(floorDiv(z, 16) + (1 << 25))
        let sy = Int64(max(0, min(63, (y - world.info.minY) >> 4)))
        dirtySections.insert((cx << 32) | (cz << 6) | sy)
    }

    private func getBL(_ x: Int, _ y: Int, _ z: Int) -> Int { world.getBlockLight(x, y, z) }
    /// returns false when the chunk doesn't exist — callers must NOT keep
    /// propagating there, or border cells ping-pong the queue forever
    private func setBL(_ x: Int, _ y: Int, _ z: Int, _ v: Int) -> Bool {
        guard let c = world.getChunkAt(x, z) else { return false }
        c.setBlockLight(posMod(x, 16), y, posMod(z, 16), v)
        markDirty(x, y, z)
        return true
    }
    private func getSL(_ x: Int, _ y: Int, _ z: Int) -> Int { world.getSkyLight(x, y, z) }
    private func setSL(_ x: Int, _ y: Int, _ z: Int, _ v: Int) -> Bool {
        guard let c = world.getChunkAt(x, z) else { return false }
        c.setSky(posMod(x, 16), y, posMod(z, 16), v)
        markDirty(x, y, z)
        return true
    }

    private func addPass(_ q: LightQueue, _ sky: Bool) {
        let w = world
        while !q.empty {
            let i = q.head
            q.head += 1
            let x = Int(q.xs[i]), y = Int(q.ys[i]), z = Int(q.zs[i]), v = Int(q.vs[i])
            let cur = sky ? getSL(x, y, z) : getBL(x, y, z)
            if cur > v { continue } // stale
            for d in 0..<6 {
                let nx = x + DX[d], ny = y + DY[d], nz = z + DZ[d]
                if ny < w.info.minY || ny >= w.info.minY + w.info.height { continue }
                let ncell = w.getBlock(nx, ny, nz)
                let rawOp = Int(LIGHT_OPACITY[ncell >> 4])
                let op = max(1, rawOp)
                let nv: Int
                if sky && d == 0 && v == 15 && rawOp == 0 { nv = 15 } // skylight falls undiminished
                else { nv = v - op }
                if nv <= 0 { continue }
                let ncur = sky ? getSL(nx, ny, nz) : getBL(nx, ny, nz)
                if ncur >= nv { continue }
                // only continue the flood where the write actually landed
                let wrote = sky ? setSL(nx, ny, nz, nv) : setBL(nx, ny, nz, nv)
                if !wrote { continue }
                q.push(nx, ny, nz, nv)
            }
        }
    }

    private func removePass(_ del: LightQueue, _ add: LightQueue, _ sky: Bool) {
        let w = world
        while !del.empty {
            let i = del.head
            del.head += 1
            let x = Int(del.xs[i]), y = Int(del.ys[i]), z = Int(del.zs[i]), v = Int(del.vs[i])
            for d in 0..<6 {
                let nx = x + DX[d], ny = y + DY[d], nz = z + DZ[d]
                if ny < w.info.minY || ny >= w.info.minY + w.info.height { continue }
                let ncur = sky ? getSL(nx, ny, nz) : getBL(nx, ny, nz)
                if ncur == 0 { continue }
                let wasFedByUs = ncur < v || (sky && d == 0 && v == 15 && ncur == 15)
                if wasFedByUs {
                    let wrote = sky ? setSL(nx, ny, nz, 0) : setBL(nx, ny, nz, 0)
                    if !wrote { continue } // missing chunk — do not chase the removal there
                    del.push(nx, ny, nz, ncur)
                    // re-add emitters encountered
                    if !sky {
                        let emit = lightEmitOf(UInt16(w.getBlock(nx, ny, nz)))
                        if emit > 0 {
                            _ = setBL(nx, ny, nz, emit)
                            add.push(nx, ny, nz, emit)
                        }
                    }
                } else {
                    // boundary: neighbor has light from another source — respread from it
                    add.push(nx, ny, nz, ncur)
                }
            }
        }
    }
}
