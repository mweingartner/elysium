// Chunk-local initial lighting on flat arrays — behavior pinned by the
// frozen baselines (including the frontier-guard lessons:
// this version never propagates outside its own chunk; seam stitching happens
// after adoption). Runs on background queues, no shared state.

import Foundation

private let LDX = [0, 0, 0, 0, -1, 1]
private let LDY = [-1, 1, 0, 0, 0, 0]
private let LDZ = [0, 0, -1, 1, 0, 0]

public func computeLocalLight(blocks: [UInt16], height: Int, hasSky: Bool) -> (sky: [UInt8], blk: [UInt8]) {
    let n = blocks.count
    var sky = [UInt8](repeating: 0, count: n)
    var blk = [UInt8](repeating: 0, count: n)
    var queue = [Int32](repeating: 0, count: 1 << 15)
    var qTail = 0
    let YS = 256

    func qPush(_ idx: Int) {
        if qTail >= queue.count {
            queue.append(contentsOf: [Int32](repeating: 0, count: queue.count))
        }
        queue[qTail] = Int32(idx)
        qTail += 1
    }

    if hasSky {
        // vertical fill: 15 falls straight down through transparent blocks
        blocks.withUnsafeBufferPointer { bp in
            sky.withUnsafeMutableBufferPointer { sp in
                for z in 0..<16 {
                    for x in 0..<16 {
                        let col = z * 16 + x
                        var level = 15
                        var y = height - 1
                        while y >= 0 {
                            let idx = y * YS + col
                            let op = Int(LIGHT_OPACITY[Int(bp[idx] >> 4)])
                            if op > 0 { level = max(0, level - max(op, 1)) }
                            else if level < 15 { level = max(0, level - 1) }
                            if level == 0 { break }
                            sp[idx] = UInt8(level)
                            y -= 1
                        }
                    }
                }
            }
        }
        // seed lateral spread: lit cells with a dimmer-than-reachable neighbor
        for y in 0..<height {
            let yb = y * YS
            for z in 0..<16 {
                for x in 0..<16 {
                    let idx = yb + z * 16 + x
                    let v = Int(sky[idx])
                    if v <= 1 { continue }
                    if (x > 0 && Int(sky[idx - 1]) < v - 1) || (x < 15 && Int(sky[idx + 1]) < v - 1) ||
                        (z > 0 && Int(sky[idx - 16]) < v - 1) || (z < 15 && Int(sky[idx + 16]) < v - 1) ||
                        (y > 0 && Int(sky[idx - YS]) < v - 1) {
                        qPush(idx)
                    }
                }
            }
        }
        bfsLocal(blocks: blocks, light: &sky, queue: &queue, tail: qTail, height: height, isSky: true)
    }

    // block light from emitters
    qTail = 0
    for i in 0..<n {
        let c = blocks[i]
        if c == 0 { continue }
        let emit = lightEmitOf(c)
        if emit > 0 {
            blk[i] = UInt8(emit)
            qPush(i)
        }
    }
    bfsLocal(blocks: blocks, light: &blk, queue: &queue, tail: qTail, height: height, isSky: false)
    return (sky, blk)
}

private func bfsLocal(blocks: [UInt16], light: inout [UInt8], queue: inout [Int32], tail: Int, height: Int, isSky: Bool) {
    let YS = 256
    var head = 0
    var qTail = tail
    while head < qTail {
        let idx = Int(queue[head])
        head += 1
        let v = Int(light[idx])
        if v <= 1 { continue }
        let x = idx & 15
        let z = (idx >> 4) & 15
        let y = idx / YS
        for d in 0..<6 {
            let nx = x + LDX[d], ny = y + LDY[d], nz = z + LDZ[d]
            if nx < 0 || nx > 15 || nz < 0 || nz > 15 || ny < 0 || ny >= height { continue }
            let nIdx = ny * YS + nz * 16 + nx
            let op = Int(LIGHT_OPACITY[Int(blocks[nIdx] >> 4)])
            let nv: Int
            if isSky && d == 0 && v == 15 && op == 0 { nv = 15 } // skylight falls undiminished
            else { nv = v - max(1, op) }
            if nv <= 0 || Int(light[nIdx]) >= nv { continue }
            light[nIdx] = UInt8(nv)
            if qTail >= queue.count {
                queue.append(contentsOf: [Int32](repeating: 0, count: queue.count))
            }
            queue[qTail] = Int32(nIdx)
            qTail += 1
        }
    }
}
