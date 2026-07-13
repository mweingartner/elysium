// Procedural texture atlas core — (paint surface +
// registry + assembly). Painters live in AtlasPainters1/2.swift. Pixel output
// is byte-identical to the golden baselines: same hash-driven randomness, same
// integer color math.

import Foundation

public let TILE = 16

@inline(__always) public func rgb(_ r: Int, _ g: Int, _ b: Int) -> Int {
    (r << 16) | (g << 8) | b
}
public func shade(_ c: Int, _ f: Double) -> Int {
    let r = min(255, max(0, Int(detRound(Double((c >> 16) & 255) * f))))
    let g = min(255, max(0, Int(detRound(Double((c >> 8) & 255) * f))))
    let b = min(255, max(0, Int(detRound(Double(c & 255) * f))))
    return rgb(r, g, b)
}
public func mixC(_ a: Int, _ b: Int, _ t: Double) -> Int {
    let ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255
    let br = (b >> 16) & 255, bg = (b >> 8) & 255, bb = b & 255
    return rgb(Int(detRound(Double(ar) + Double(br - ar) * t)),
               Int(detRound(Double(ag) + Double(bg - ag) * t)),
               Int(detRound(Double(ab) + Double(bb - ab) * t)))
}

/// per-tile paint surface
public final class T {
    public var data = [UInt8](repeating: 0, count: TILE * TILE * 4)
    public let seed: UInt32
    public let name: String

    public init(_ name: String) {
        self.name = name
        seed = hashString(name)
    }

    public func rand(_ x: Int, _ y: Int, _ salt: UInt32 = 0) -> Double {
        Double(hash2(seed, x, y, salt)) / 4294967296.0
    }
    public func set(_ x: Int, _ y: Int, _ c: Int, _ a: Int = 255) {
        if x < 0 || x >= TILE || y < 0 || y >= TILE { return }
        let i = (y * TILE + x) * 4
        data[i] = UInt8((c >> 16) & 255)
        data[i + 1] = UInt8((c >> 8) & 255)
        data[i + 2] = UInt8(c & 255)
        data[i + 3] = UInt8(min(255, max(0, a)))
    }
    public func get(_ x: Int, _ y: Int) -> Int {
        let i = (y * TILE + x) * 4
        return rgb(Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    public func alphaAt(_ x: Int, _ y: Int) -> Int { Int(data[(y * TILE + x) * 4 + 3]) }
    public func fill(_ c: Int, _ a: Int = 255) {
        for y in 0..<TILE { for x in 0..<TILE { set(x, y, c, a) } }
    }
    /// filled with per-pixel brightness noise
    public func noise(_ c: Int, _ amt: Double = 0.12, _ salt: UInt32 = 0) {
        for y in 0..<TILE {
            for x in 0..<TILE {
                let f = 1 - amt + rand(x, y, salt) * amt * 2
                set(x, y, shade(c, f))
            }
        }
    }
    /// smooth blotchy noise (2-scale)
    public func blotch(_ c: Int, _ amt: Double = 0.14, _ scale: Int = 4, _ salt: UInt32 = 1) {
        for y in 0..<TILE {
            for x in 0..<TILE {
                let bx = x / scale, by = y / scale
                let fx = Double(x % scale) / Double(scale), fy = Double(y % scale) / Double(scale)
                let v00 = rand(bx, by, salt), v10 = rand(bx + 1, by, salt)
                let v01 = rand(bx, by + 1, salt), v11 = rand(bx + 1, by + 1, salt)
                let v = (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy
                let fine = rand(x, y, salt + 7) * 0.5 + 0.5
                let f = 1 - amt + (v * 0.7 + fine * 0.3) * amt * 2
                set(x, y, shade(c, f))
            }
        }
    }
    public func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Int, _ a: Int = 255) {
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 { set(x, y, c, a); x += 1 }
            y += 1
        }
    }
    public func speckle(_ c: Int, _ count: Int, _ salt: UInt32 = 2) {
        for i in 0..<count {
            let x = Int(rand(i, 0, salt) * Double(TILE))
            let y = Int(rand(i, 1, salt) * Double(TILE))
            set(x, y, c)
        }
    }
    public func border(_ c: Int) {
        for i in 0..<TILE {
            set(i, 0, c); set(i, TILE - 1, c)
            set(0, i, c); set(TILE - 1, i, c)
        }
    }
    /// ore blobs over existing base
    public func oreBlobs(_ c: Int, _ count: Int = 5, _ salt: UInt32 = 3) {
        let hi = shade(c, 1.35), lo = shade(c, 0.7)
        for i in 0..<count {
            let cx = 2 + Int(rand(i, 0, salt) * 12)
            let cy = 2 + Int(rand(i, 1, salt) * 12)
            for dy in -1...1 {
                for dx in -1...1 {
                    if abs(dx) + abs(dy) == 2 && rand(cx + dx, cy + dy, salt) < 0.5 { continue }
                    let r = rand(cx + dx, cy + dy, salt + 1)
                    set(cx + dx, cy + dy, r < 0.3 ? hi : r < 0.7 ? c : lo)
                }
            }
        }
    }
    /// vertical wood grain — NOTE: TILE/cols is FLOAT division in the baseline source
    public func grain(_ base: Int, _ contrast: Double = 0.16, _ cols: Int = 4, _ salt: UInt32 = 4) {
        for x in 0..<TILE {
            let colSeed = Int((Double(x) / (Double(TILE) / Double(cols))).rounded(.down))
            let tone = 1 - contrast / 2 + rand(colSeed, 0, salt) * contrast
            for y in 0..<TILE {
                let wob = rand(colSeed, y / 3, salt + 1) * 0.1
                let fine = rand(x, y, salt + 2) * 0.08
                set(x, y, shade(base, tone - wob + fine))
            }
        }
    }
    public func planks(_ base: Int, _ salt: UInt32 = 5) {
        grain(base, 0.12, 5, salt)
        let dark = shade(base, 0.62)
        for y in [3, 7, 11, 15] {
            for x in 0..<TILE { set(x, y, dark) }
        }
        // staggered vertical joints
        set(4, 0, dark); set(4, 1, dark); set(4, 2, dark)
        set(11, 4, dark); set(11, 5, dark); set(11, 6, dark)
        set(2, 8, dark); set(2, 9, dark); set(2, 10, dark)
        set(13, 12, dark); set(13, 13, dark); set(13, 14, dark)
    }
    public func bricks(_ base: Int, _ mortar: Int, _ bw: Int = 8, _ bh: Int = 4, _ salt: UInt32 = 6) {
        for y in 0..<TILE {
            let row = y / bh
            let off = (row % 2) * (bw / 2)
            for x in 0..<TILE {
                let isMortarY = (y % bh) == bh - 1
                let isMortarX = ((x + off) % bw) == bw - 1
                if isMortarY || isMortarX { set(x, y, mortar) }
                else {
                    let bidx = (x + off) / bw + row * 7
                    let tone = 0.9 + rand(bidx, row, salt) * 0.2 + rand(x, y, salt + 1) * 0.08
                    set(x, y, shade(base, tone))
                }
            }
        }
    }
    /// ASCII pixel art: rows of chars; palette maps char→color
    public func px(_ rows: [String], _ palette: [Character: Int], _ dx: Int = 0, _ dy: Int = 0) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                if ch == " " || ch == "." { continue }
                guard let c = palette[ch] else { continue }
                set(x + dx, y + dy, c)
            }
        }
    }
    public func clearAlpha() {
        var i = 3
        while i < data.count { data[i] = 0; i += 4 }
    }
    public func vline(_ x: Int, _ y0: Int, _ y1: Int, _ c: Int) {
        var y = y0
        while y <= y1 { set(x, y, c); y += 1 }
    }
    public func hline(_ y: Int, _ x0: Int, _ x1: Int, _ c: Int) {
        var x = x0
        while x <= x1 { set(x, y, c); x += 1 }
    }
    public func disc(_ cx: Double, _ cy: Double, _ r: Double, _ c: Int) {
        var y = Int((cy - r).rounded(.down))
        while Double(y) <= cy + r {
            var x = Int((cx - r).rounded(.down))
            while Double(x) <= cx + r {
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy <= r * r { set(x, y, c) }
                x += 1
            }
            y += 1
        }
    }
    public func cross(_ base: Int, _ salt: UInt32 = 8) {
        // generic plant: stems + leaf clusters
        clearAlpha()
        let dark = shade(base, 0.7), light = shade(base, 1.25)
        for i in 0..<4 {
            let x = 3 + Int(rand(i, 0, salt) * 10)
            let h = 5 + Int(rand(i, 1, salt) * 9)
            var y = TILE - 1
            while y > TILE - 1 - h {
                let wob = Int(rand(i, y, salt) * 2)
                set(x + wob, y, rand(x, y, salt) < 0.5 ? base : dark)
                y -= 1
            }
            set(x, TILE - h, light)
        }
    }
}

// ---------------------------------------------------------------------------
// painter registry
// ---------------------------------------------------------------------------
public typealias Painter = (T) -> Void
public typealias RegexPainter = (T, [String?]) -> Void

var painters: [String: Painter] = [:]
var regexPainters: [(NSRegularExpression, RegexPainter)] = []

func p(_ name: String, _ fn: @escaping Painter) { painters[name] = fn }
func rp(_ pattern: String, _ fn: @escaping RegexPainter) {
    let re = try! NSRegularExpression(pattern: pattern)
    regexPainters.append((re, fn))
}

func matchGroups(_ name: String, _ re: NSRegularExpression) -> [String?]? {
    let range = NSRange(name.startIndex..., in: name)
    guard let m = re.firstMatch(in: name, range: range) else { return nil }
    var groups: [String?] = []
    for i in 0..<m.numberOfRanges {
        let r = m.range(at: i)
        if r.location == NSNotFound { groups.append(nil) }
        else { groups.append((name as NSString).substring(with: r)) }
    }
    return groups
}

public var missingTiles: [String] = []

func fallbackPaint(_ t: T) {
    let h = mix32(t.seed)
    let c = rgb(100 + Int(h & 63), 100 + Int((h >> 6) & 63), 100 + Int((h >> 12) & 63))
    t.blotch(c, 0.13, 3)
    missingTiles.append(t.name)
}

func paintInto(_ t: T, _ name: String) {
    if let fn = painters[name] { fn(t); return }
    for (re, rfn) in regexPainters {
        if let m = matchGroups(name, re) { rfn(t, m); return }
    }
    fallbackPaint(t)
}

private var paintersRegistered = false
public func ensurePainters() {
    if paintersRegistered { return }
    paintersRegistered = true
    registerPainters1()
    registerPainters2()
}

public func paintTile(_ name: String) -> T {
    ensurePainters()
    let t = T(name)
    if let fn = painters[name] { fn(t); return t }
    for (re, rfn) in regexPainters {
        if let m = matchGroups(name, re) { rfn(t, m); return t }
    }
    fallbackPaint(t)
    return t
}

public struct BuiltAtlas {
    public let count: Int
    /// tiles as raw RGBA (TILE*TILE*4 bytes each) for Metal upload
    public let pixels: [[UInt8]]
    public let missing: [String]

    public init(count: Int, pixels: [[UInt8]], missing: [String]) {
        self.count = count
        self.pixels = pixels
        self.missing = missing
    }
}

public func buildAtlas() -> BuiltAtlas {
    ensurePainters()
    missingTiles = []
    let names = allTileNames()
    var pixels: [[UInt8]] = []
    pixels.reserveCapacity(names.count)
    for n in names {
        pixels.append(paintTile(n).data)
    }
    return BuiltAtlas(count: names.count, pixels: pixels, missing: missingTiles)
}
