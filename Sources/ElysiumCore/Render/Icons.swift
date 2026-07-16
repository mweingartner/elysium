// Item icons — 16×16 RGBA pixel sprites rendered once
// into a cache: blocks as isometric mini-cubes from atlas tiles, items from
// pixel-art templates. Same templates, same colors, same fallbacks.

import Foundation

private struct IconCacheKey: Hashable {
    let itemId: Int
    let aliasId: Int?
    let potion: String?
    let generation: UInt64
    let rendererRevision: UInt64
}

private var iconCache: [IconCacheKey: [UInt8]] = [:]
private struct IconSourceSnapshot {
    let atlas: BuiltAtlas
    let overrides: [String: [UInt8]]
    let generation: UInt64
    let rendererRevision: UInt64
}
private let iconSourceLock = NSLock()
private var iconSourceSnapshot: IconSourceSnapshot?
private var nextIconGeneration: UInt64 = 0
let iconMaximumShapeBoxes = 256
let iconMaximumCandidateFaces = iconMaximumShapeBoxes * 6
let iconMaximumFacePixelTests = iconMaximumCandidateFaces * 16 * 16

public struct IconSourceCandidate {
    fileprivate let atlas: BuiltAtlas
    fileprivate let overrides: [String: [UInt8]]
    fileprivate let rendererRevision: UInt64

    public init?(atlas: BuiltAtlas, itemOverrides: [String: [UInt8]] = [:],
                 rendererRevision: UInt64 = 1) {
        guard atlas.count == atlas.pixels.count,
              atlas.pixels.allSatisfy({ $0.count == 16 * 16 * 4 }) else { return nil }
        self.atlas = atlas
        self.overrides = itemOverrides.filter { $0.value.count == 16 * 16 * 4 }
        self.rendererRevision = rendererRevision
    }
}

/// app-installed resource-pack item textures (item name → 16×16 straight RGBA).
/// elysmoke never sets this, so the icon goldens always see the painters.
/// Sole Core publication seam. Candidate validation/copying is complete before this lock is acquired;
/// Core never invokes caller or App code while holding its source/cache lock.
@discardableResult
public func publishIconSourceSnapshot(_ candidate: IconSourceCandidate) -> UInt64 {
    iconSourceLock.lock(); defer { iconSourceLock.unlock() }
    nextIconGeneration &+= 1
    iconSourceSnapshot = IconSourceSnapshot(atlas: candidate.atlas, overrides: candidate.overrides,
                                            generation: nextIconGeneration,
                                            rendererRevision: candidate.rendererRevision)
    iconCache.removeAll(keepingCapacity: true)
    return nextIconGeneration
}

public func currentIconSourceGeneration() -> UInt64 {
    iconSourceLock.lock(); defer { iconSourceLock.unlock() }
    return iconSourceSnapshot?.generation ?? 0
}

public func blockItemIconUsesThreeDimensionalPreview(_ blockId: Int) -> Bool {
    guard blockId > 0, blockId < blockDefs.count else { return false }
    let shape = Shape(rawValue: SHAPE_OF[blockId]) ?? .cube
    switch shape {
    case .air, .liquid, .fire, .portalShape, .endPortalShape,
         .cross, .tallCross, .crop, .netherWart, .sweetBerry, .rootsShape, .web,
         .caveVinesShape, .hangingRoots, .sporeBlossom,
         .vine, .glowLichen, .sculkVein,
         .lilyPad, .frogspawn:
        return false
    default:
        var boxes: [AABB] = []
        shapeBoxes(Int(cell(UInt16(blockId))), { _, _, _ in 0 }, &boxes, false)
        return boxes.contains { box in
            box.x1 > box.x0 && box.y1 > box.y0 && box.z1 > box.z0
        }
    }
}

private func iconAliasDef(for def: ItemDef) -> ItemDef? {
    guard def.icon != def.name,
          let aliasId = iidOpt(def.icon),
          aliasId != def.id else { return nil }
    return itemDefs[aliasId]
}

private func tilePixels(_ tile: Int, atlas: BuiltAtlas) -> [UInt8]? {
    guard tile >= 0, tile < atlas.pixels.count, atlas.pixels[tile].count == 1024 else { return nil }
    return atlas.pixels[tile]
}

/// 16×16 RGBA pixels for an item icon (cached per item+potion)
public func itemIconPixels(_ itemId: Int, _ data: StackData? = nil) -> [UInt8] {
    guard itemId >= 0, itemId < itemDefs.count else { return missingIconPixels() }
    let def = itemDefs[itemId]
    let aliasDef = iconAliasDef(for: def)
    while true {
        iconSourceLock.lock()
        guard let snapshot = iconSourceSnapshot else {
            iconSourceLock.unlock()
            return missingIconPixels()
        }
        let key = IconCacheKey(itemId: itemId, aliasId: aliasDef?.id,
                               potion: data?.potion, generation: snapshot.generation,
                               rendererRevision: snapshot.rendererRevision)
        if let cached = iconCache[key] {
            iconSourceLock.unlock()
            return cached
        }
        iconSourceLock.unlock()

        let rendered: [UInt8]
        if data?.potion == nil, let px = snapshot.overrides[def.name] {
            rendered = px
        } else if data?.potion == nil, let aliasDef, let px = snapshot.overrides[aliasDef.name] {
            rendered = px
        } else if data?.potion == nil, let sourceName = copperToolSourceName(def.name),
                  let px = snapshot.overrides[sourceName] {
            rendered = recolorIronToolIconToCopper(px)
        } else {
            var img = [UInt8](repeating: 0, count: 1024)
            paintIcon(&img, aliasDef ?? def, data, atlas: snapshot.atlas)
            rendered = stride(from: 3, to: img.count, by: 4).contains(where: { img[$0] != 0 })
                ? img : missingIconPixels()
        }

        iconSourceLock.lock()
        if iconSourceSnapshot?.generation == snapshot.generation {
            iconCache[key] = rendered
            iconSourceLock.unlock()
            return rendered
        }
        iconSourceLock.unlock()
        // Publication raced rendering. Retry against the complete new snapshot; stale work is discarded.
    }
}

private func missingIconPixels() -> [UInt8] {
    var img = [UInt8](repeating: 0, count: 16 * 16 * 4)
    for y in 2..<14 {
        for x in 2..<14 where x == 2 || x == 13 || y == 2 || y == 13 || x == y || x + y == 15 {
            let i = (y * 16 + x) * 4
            img[i] = 255; img[i + 1] = 0; img[i + 2] = 255; img[i + 3] = 255
        }
    }
    return img
}

// rgb int helpers (baseline used css strings; here colors are 0xRRGGBB ints, -1 = clear)
@inline(__always) private func put(_ img: inout [UInt8], _ x: Int, _ y: Int, _ c: Int) {
    if x < 0 || x > 15 || y < 0 || y > 15 || c < 0 { return }
    let i = (y * 16 + x) * 4
    img[i] = UInt8((c >> 16) & 255)
    img[i + 1] = UInt8((c >> 8) & 255)
    img[i + 2] = UInt8(c & 255)
    img[i + 3] = 255
}

private func hsl(_ h: Double, _ s: Double, _ l: Double) -> Int {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double)
    switch Int(hp) {
    case 0: (r1, g1, b1) = (c, x, 0)
    case 1: (r1, g1, b1) = (x, c, 0)
    case 2: (r1, g1, b1) = (0, c, x)
    case 3: (r1, g1, b1) = (0, x, c)
    case 4: (r1, g1, b1) = (x, 0, c)
    default: (r1, g1, b1) = (c, 0, x)
    }
    let m = l - c / 2
    let r = Int(((r1 + m) * 255).rounded()), g = Int(((g1 + m) * 255).rounded()), b = Int(((b1 + m) * 255).rounded())
    return (max(0, min(255, r)) << 16) | (max(0, min(255, g)) << 8) | max(0, min(255, b))
}

private func materialColors(_ name: String) -> (Int, Int, Int) {
    if name.hasPrefix("wooden") { return (0xa8845c, 0x8a6a42, 0x5c4426) }
    if name.hasPrefix("stone") { return (0xaaaaaa, 0x8a8a8a, 0x5c5c5c) }
    if name.hasPrefix("iron") { return (0xe8e8e8, 0xc8c8c8, 0x8a8a8a) }
    if name.hasPrefix("copper") { return (0xf0b080, 0xd0784f, 0x8a4a30) }
    if name.hasPrefix("golden") { return (0xfcee4b, 0xe8c83c, 0xa8862c) }
    if name.hasPrefix("diamond") { return (0x8cf4e2, 0x4aedd9, 0x2ca89a) }
    if name.hasPrefix("netherite") { return (0x5a5054, 0x42383b, 0x2a2326) }
    if name.hasPrefix("leather") { return (0xc08850, 0x9a6a42, 0x6a4426) }
    if name.hasPrefix("chainmail") { return (0xd8d8d8, 0xaaaaaa, 0x787878) }
    if name.hasPrefix("turtle") { return (0x6a9a4c, 0x47702e, 0x2c4c1c) }
    return (0xcccccc, 0x999999, 0x666666)
}

private func copperToolSourceName(_ name: String) -> String? {
    guard name.hasPrefix("copper_") else { return nil }
    let suffix = String(name.dropFirst("copper_".count))
    switch suffix {
    case "sword", "pickaxe", "axe", "shovel", "hoe":
        return "iron_\(suffix)"
    default:
        return nil
    }
}

private func recolorIronToolIconToCopper(_ source: [UInt8]) -> [UInt8] {
    guard source.count == 16 * 16 * 4 else { return source }
    var out = source
    let dark = (r: 0x8a, g: 0x4a, b: 0x30)
    let base = (r: 0xd0, g: 0x78, b: 0x4f)
    let light = (r: 0xf0, g: 0xb0, b: 0x80)

    func mix(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int), _ t: Double) -> (Int, Int, Int) {
        let clamped = max(0, min(1, t))
        return (
            Int((Double(a.r) + (Double(b.r) - Double(a.r)) * clamped).rounded()),
            Int((Double(a.g) + (Double(b.g) - Double(a.g)) * clamped).rounded()),
            Int((Double(a.b) + (Double(b.b) - Double(a.b)) * clamped).rounded())
        )
    }

    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Int(source[i + 3])
        if a == 0 { continue }
        let r = Int(source[i]), g = Int(source[i + 1]), b = Int(source[i + 2])
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let chroma = maxC - minC
        // Faithful handles are warm brown and should stay untouched. The iron
        // heads/blades are neutral grays, including antialiased edge pixels.
        guard maxC >= 28, chroma <= 34 else { continue }
        let luminance = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
        let shade = max(0, min(1, (luminance - 0.16) / 0.76))
        let rgb = shade < 0.5
            ? mix(dark, base, shade / 0.5)
            : mix(base, light, (shade - 0.5) / 0.5)
        out[i] = UInt8(rgb.0)
        out[i + 1] = UInt8(rgb.1)
        out[i + 2] = UInt8(rgb.2)
    }
    return out
}

private let TOOL_TEMPLATES: [String: [String]] = [
    "sword": [
        "..........#...",
        ".........#H#..",
        "........#HB#..",
        ".......#HB#...",
        "......#HB#....",
        ".....#HB#.....",
        "....#HB#......",
        ".W.#HB#.......",
        ".WW#B#........",
        ".WWW#.........",
        "#WWW..........",
        "#W#WW.........",
        ".#..#.........",
    ],
    "pickaxe": [
        "....#HHHH#....",
        "..#HHBBBBH#...",
        ".#HB##..#BH#..",
        ".#B#..W..#B#..",
        ".##..WW...##..",
        ".....WW.......",
        "....WW........",
        "...WW.........",
        "..WW..........",
        ".WW...........",
        "#W............",
    ],
    "axe": [
        "...#HH#.......",
        "..#HBBH#......",
        ".#HBB#B#......",
        ".#BB#WW#......",
        ".#B#.WW.......",
        ".##.WW........",
        "...WW.........",
        "..WW..........",
        ".WW...........",
        "#W............",
    ],
    "shovel": [
        ".......#HH#...",
        "......#HBBH#..",
        "......#BBBB#..",
        ".....W#BBB#...",
        "....WW.##.....",
        "...WW.........",
        "..WW..........",
        ".WW...........",
        "#W............",
    ],
    "hoe": [
        "....#HHH#.....",
        "..#HHBB##.....",
        "..##.#W#......",
        ".....WW.......",
        "....WW........",
        "...WW.........",
        "..WW..........",
        ".WW...........",
        "#W............",
    ],
]
private let ARMOR_TEMPLATES: [Int: [String]] = [
    0: [
        "....######....",
        "...#HHHHHH#...",
        "..#HHBBBBHH#..",
        "..#HBBBBBBB#..",
        "..#BB####BB#..",
        "..#BB#..#BB#..",
        "..###....###..",
    ],
    1: [
        "..##......##..",
        ".#HH#....#HH#.",
        ".#HBB####BBH#.",
        ".#HBBBBBBBBH#.",
        "..##BBBBBB##..",
        "...#BBBBBB#...",
        "...#BBBBBB#...",
        "...#BBBBBB#...",
        "...########...",
    ],
    2: [
        "...########...",
        "..#HBBBBBBH#..",
        "..#HB####BH#..",
        "..#BB#..#BB#..",
        "..#BB#..#BB#..",
        "..#BB#..#BB#..",
        "..#BB#..#BB#..",
        "..####..####..",
    ],
    3: [
        "..............",
        "..##....##....",
        "..#B#...#B#...",
        "..#B#...#B#...",
        "..#BB#..#BB#..",
        "..#BBB#.#BBB#.",
        "..#####.#####.",
    ],
]

private func drawTemplate(_ img: inout [UInt8], _ rows: [String], _ H: Int, _ Bc: Int, _ D: Int, _ ox: Int = 1, _ oy: Int = 1) {
    for (y, row) in rows.enumerated() {
        for (x, ch) in row.enumerated() {
            if ch == "." { continue }
            let c = ch == "H" ? H : ch == "B" ? Bc : ch == "#" ? D : ch == "W" ? 0x8a6a42 : D
            put(&img, x + ox, y + oy, c)
        }
    }
}

private func paintIcon(_ img: inout [UInt8], _ def: ItemDef, _ data: StackData?, atlas: BuiltAtlas) {
    let name = def.name
    // tools
    if let tool = def.tool, let tpl = TOOL_TEMPLATES[tool.type] {
        let (H, Bc, D) = materialColors(name)
        drawTemplate(&img, tpl, H, Bc, D)
        return
    }
    // armor
    if let armor = def.armor, armor.material != "elytra", let tpl = ARMOR_TEMPLATES[armor.slot] {
        let (H, Bc, D) = materialColors(armor.material)
        drawTemplate(&img, tpl, H, Bc, D, 1, 3)
        return
    }
    // block items → mini isometric cube or flat tile
    if let block = def.block {
        let bid = Int(block)
        let bdef = blockDefs[bid]
        let threeDimensional = blockItemIconUsesThreeDimensionalPreview(bid)
        func tile(_ face: Int) -> Int {
            bdef.texFn?(0, face) ?? (bdef.tex.isEmpty ? 0 : Int(bdef.tex[face]))
        }
        if !threeDimensional {
            blitTile(&img, tile(2), tintFor(bid), atlas: atlas)
            return
        }
        var boxes: [AABB] = []
        // Inventory previews are deliberately isolated and use canonical metadata 0:
        // straight bottom stairs, closed doors/trapdoors/gates, and unconnected posts.
        shapeBoxes(Int(cell(UInt16(bid), 0)), { _, _, _ in 0 }, &boxes, false)
        if !drawIsometricShape(&img, boxes: boxes,
                               topTile: tile(1), leftTile: tile(2), rightTile: tile(5),
                               tint: tintFor(bid), atlas: atlas) {
            img = missingIconPixels()
        }
        return
    }
    if paintSpecific(&img, name, data) { return }
    // generic fallback: rounded blob with hashed hue, category-shaped
    let h = hashString(name)
    let hue = Double(h % 360)
    let base = hsl(hue, 0.45, 0.55)
    let dark = hsl(hue, 0.45, 0.38)
    let light = hsl(hue, 0.50, 0.70)
    if def.category == "food" {
        for y in 4..<13 {
            for x in 3..<13 {
                let d = Double((x - 8) * (x - 8)) + (Double(y) - 8.5) * (Double(y) - 8.5)
                if d < 22 { put(&img, x, y, d < 9 ? light : base) }
            }
        }
        put(&img, 8, 3, 0x6a4426)
        put(&img, 8, 2, 0x4a7a2c)
    } else {
        for y in 5..<12 {
            for x in 3..<13 {
                let ax = abs(Double(x) - 8)
                let inside = Double(y) >= 5 + ax * 0.3 - 1 && Double(y) <= 11 - ax * 0.2
                if inside { put(&img, x, y, y < 8 ? light : y < 10 ? base : dark) }
            }
        }
    }
}

private struct IconFace {
    let points: [(Double, Double)]
    let tile: [UInt8]
    let uv: [(Double, Double)]
    let brightness: Double
    let tint: Bool
    let depth: Double
    let order: Int
}

@inline(__always) private func iconProject(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double) {
    (8 + (x - z) * 6, 2 + (x + z) * 3 + (1 - y) * 9)
}

/// Internal for focused adversarial tests. Invalid geometry is rejected as a whole before projection.
@discardableResult
func drawIsometricShape(_ img: inout [UInt8], boxes: [AABB],
                        topTile: Int, leftTile: Int, rightTile: Int, tint: Int?,
                        atlas: BuiltAtlas) -> Bool {
    guard img.count == 1024, !boxes.isEmpty, boxes.count <= iconMaximumShapeBoxes,
          let top = tilePixels(topTile, atlas: atlas),
          let left = tilePixels(leftTile, atlas: atlas),
          let right = tilePixels(rightTile, atlas: atlas) else { return false }
    for b in boxes {
        let values = [b.x0, b.y0, b.z0, b.x1, b.y1, b.z1]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              b.x0 < b.x1, b.y0 < b.y1, b.z0 < b.z1 else { return false }
    }

    var faces: [IconFace] = []
    faces.reserveCapacity(boxes.count * 3)
    for (index, b) in boxes.enumerated() {
        func face(_ xyz: [(Double, Double, Double)], _ pix: [UInt8],
                  _ uv: [(Double, Double)], _ bright: Double, _ useTint: Bool) {
            faces.append(IconFace(points: xyz.map(iconProject), tile: pix, uv: uv,
                                  brightness: bright, tint: useTint,
                                  depth: xyz.map { $0.0 + $0.1 + $0.2 }.reduce(0, +) / 4,
                                  order: index))
        }
        face([(b.x0,b.y1,b.z0),(b.x1,b.y1,b.z0),(b.x1,b.y1,b.z1),(b.x0,b.y1,b.z1)], top,
             [(b.x0,b.z0),(b.x1,b.z0),(b.x1,b.z1),(b.x0,b.z1)], 1, true)
        face([(b.x1,b.y0,b.z0),(b.x1,b.y0,b.z1),(b.x1,b.y1,b.z1),(b.x1,b.y1,b.z0)], right,
             [(b.z0,1-b.y0),(b.z1,1-b.y0),(b.z1,1-b.y1),(b.z0,1-b.y1)], 0.8, false)
        face([(b.x0,b.y0,b.z1),(b.x1,b.y0,b.z1),(b.x1,b.y1,b.z1),(b.x0,b.y1,b.z1)], left,
             [(b.x0,1-b.y0),(b.x1,1-b.y0),(b.x1,1-b.y1),(b.x0,1-b.y1)], 0.65, false)
    }
    faces.sort { $0.depth == $1.depth ? $0.order < $1.order : $0.depth < $1.depth }

    func rasterTriangle(_ f: IconFace, _ a: Int, _ b: Int, _ c: Int) {
        let p0 = f.points[a], p1 = f.points[b], p2 = f.points[c]
        let area = (p1.0-p0.0)*(p2.1-p0.1) - (p1.1-p0.1)*(p2.0-p0.0)
        guard abs(area) > 0.000_001 else { return }
        for y in 0..<16 { for x in 0..<16 {
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let w1 = ((px-p0.0)*(p2.1-p0.1) - (py-p0.1)*(p2.0-p0.0)) / area
            let w2 = ((p1.0-p0.0)*(py-p0.1) - (p1.1-p0.1)*(px-p0.0)) / area
            let w0 = 1 - w1 - w2
            guard w0 >= -0.000_001, w1 >= -0.000_001, w2 >= -0.000_001 else { continue }
            let u = f.uv[a].0*w0 + f.uv[b].0*w1 + f.uv[c].0*w2
            let v = f.uv[a].1*w0 + f.uv[b].1*w1 + f.uv[c].1*w2
            let tx = min(15, max(0, Int(u * 16))), ty = min(15, max(0, Int(v * 16)))
            let si = (ty * 16 + tx) * 4
            guard f.tile[si + 3] >= 50 else { continue }
            var r = Double(f.tile[si]), g = Double(f.tile[si+1]), bl = Double(f.tile[si+2])
            if f.tint, let tint {
                r *= Double((tint >> 16) & 255) / 255
                g *= Double((tint >> 8) & 255) / 255
                bl *= Double(tint & 255) / 255
            }
            let di = (y * 16 + x) * 4
            img[di] = UInt8(min(255, (r*f.brightness).rounded()))
            img[di+1] = UInt8(min(255, (g*f.brightness).rounded()))
            img[di+2] = UInt8(min(255, (bl*f.brightness).rounded()))
            img[di+3] = f.tile[si+3]
        }}
    }
    for f in faces { rasterTriangle(f, 0, 1, 2); rasterTriangle(f, 0, 2, 3) }
    return stride(from: 3, to: img.count, by: 4).contains { img[$0] != 0 }
}

private func tintFor(_ blockId: Int) -> Int? {
    let t = blockDefs[blockId].tint
    if t == 1 { return 0x7cbd4f }
    if t == 2 { return 0x59ab30 }
    if t == 3 { return 0x3f76e4 }
    return nil
}

private func blitTile(_ img: inout [UInt8], _ tile: Int, _ tint: Int?, atlas: BuiltAtlas) {
    guard img.count == 1024, let pix = tilePixels(tile, atlas: atlas) else { return }
    for i in 0..<256 {
        var r = Double(pix[i * 4]), g = Double(pix[i * 4 + 1]), b = Double(pix[i * 4 + 2])
        if let tint {
            r = r * Double((tint >> 16) & 255) / 255
            g = g * Double((tint >> 8) & 255) / 255
            b = b * Double(tint & 255) / 255
        }
        img[i * 4] = UInt8(min(255, r))
        img[i * 4 + 1] = UInt8(min(255, g))
        img[i * 4 + 2] = UInt8(min(255, b))
        img[i * 4 + 3] = pix[i * 4 + 3]
    }
}

private func paintSpecific(_ img: inout [UInt8], _ name: String, _ data: StackData?) -> Bool {
    func px(_ x: Int, _ y: Int, _ c: Int) { put(&img, x, y, c) }
    func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Int) {
        for y in y0...y1 { for x in x0...x1 { px(x, y, c) } }
    }
    switch name {
    case "stick":
        fill(11, 2, 12, 3, 0x8a6a42); fill(9, 4, 10, 5, 0x8a6a42); fill(7, 6, 8, 7, 0x6a4f30)
        fill(5, 8, 6, 9, 0x8a6a42); fill(3, 10, 4, 11, 0x6a4f30)
        return true
    case "coal", "charcoal": blob(&img, name == "coal" ? 0x2e2e2e : 0x3a3026, 0x4a4a4a); return true
    case "diamond": gem(&img, 0x4aedd9, 0x2ca89a, 0xaef8ee); return true
    case "emerald": gem(&img, 0x2cc24e, 0x1a8a36, 0x7ce89a); return true
    case "lapis_lazuli": blob(&img, 0x1e4ca8, 0x3a6ac8); return true
    case "quartz": gem(&img, 0xece6df, 0xb8b0a6, 0xffffff); return true
    case "amethyst_shard": gem(&img, 0x9a72d0, 0x6a4a9e, 0xc8aae8); return true
    case "echo_shard": gem(&img, 0x0c4456, 0x062c3a, 0x2ce8e8); return true
    case "iron_ingot": ingot(&img, 0xe8e8e8, 0xc8c8c8, 0x8a8a8a); return true
    case "gold_ingot": ingot(&img, 0xfcee4b, 0xe8c83c, 0xa8862c); return true
    case "copper_ingot": ingot(&img, 0xe8966a, 0xc06843, 0x8a4a30); return true
    case "netherite_ingot": ingot(&img, 0x5a5054, 0x42383b, 0x2a2326); return true
    case "netherite_scrap": blob(&img, 0x42383b, 0x5e4439); return true
    case "raw_iron": blob(&img, 0xa88a72, 0xc8aa90); return true
    case "raw_copper": blob(&img, 0xa05a3c, 0xc87a52); return true
    case "raw_gold": blob(&img, 0xddaa3e, 0xf8d860); return true
    case "iron_nugget": smallBlob(&img, 0xc8c8c8, 0xe8e8e8); return true
    case "gold_nugget": smallBlob(&img, 0xe8c83c, 0xfcee4b); return true
    case "redstone": pile(&img, 0xcc1500, 0xff2200); return true
    case "glowstone_dust": pile(&img, 0xd8a84a, 0xfcd97a); return true
    case "gunpowder": pile(&img, 0x5a5a5a, 0x7a7a7a); return true
    case "sugar": pile(&img, 0xe8e8e8, 0xffffff); return true
    case "bone_meal": pile(&img, 0xd8d8c8, 0xf0f0e0); return true
    case "apple": fruit(&img, 0xd03030, 0xf05050); return true
    case "golden_apple", "enchanted_golden_apple": fruit(&img, 0xe8c83c, 0xfcee6b); return true
    case "bread":
        fill(3, 6, 12, 10, 0xa87838); fill(4, 5, 11, 5, 0xc89858); fill(4, 7, 11, 7, 0xc89858)
        return true
    case "wheat":
        for i in 0..<4 {
            fill(4 + i * 2, 4, 4 + i * 2, 12, 0xd8c054)
            px(4 + i * 2, 3, 0xe8d87a)
        }
        return true
    case "wheat_seeds", "beetroot_seeds", "melon_seeds", "pumpkin_seeds", "torchflower_seeds", "pitcher_pod":
        seeds(&img, name == "melon_seeds" ? 0x1c1c1c : name == "pumpkin_seeds" ? 0xe8e0c8 : 0x4a8a2c)
        return true
    case "egg":
        fill(6, 4, 9, 5, 0xe8dcc0); fill(5, 6, 10, 10, 0xe8dcc0); fill(6, 11, 9, 12, 0xe8dcc0); fill(6, 5, 7, 7, 0xf8f0e0)
        return true
    case "bone":
        fill(3, 11, 4, 12, 0xe8e8d8); fill(11, 3, 12, 4, 0xe8e8d8)
        for i in 0..<6 { px(5 + i, 10 - i, 0xd8d8c8) }
        for i in 0..<6 { px(6 + i, 11 - i, 0xe8e8d8) }
        return true
    case "string":
        for i in 0..<10 { px(3 + i, 5 + Int((Foundation.sin(Double(i)) * 2 + 4).rounded(.down)), 0xe8e8e8) }
        return true
    case "feather":
        for i in 0..<8 {
            px(4 + i, 11 - i, 0xe8e8e8)
            px(5 + i, 11 - i, 0xd8d8d8)
        }
        px(3, 12, 0xb8b8b8)
        return true
    case "flint": blob(&img, 0x3a3a3a, 0x555555); return true
    case "leather": fill(4, 5, 11, 11, 0x9a6a42); fill(5, 4, 10, 4, 0x9a6a42); return true
    case "arrow":
        for i in 0..<9 { px(11 - i, 4 + i, 0x8a6a42) }
        px(12, 3, 0xd8d8d8); px(11, 4, 0xd8d8d8); px(3, 12, 0xe8e8e8); px(4, 11, 0xe8e8e8)
        return true
    case "bow": arc(&img); return true
    case "ender_pearl": orb(&img, 0x1c5c50, 0x39e8c8); return true
    case "ender_eye": orb(&img, 0x39e8c8, 0x1c5c50); return true
    case "blaze_rod":
        for i in 0..<10 {
            px(10 - i / 2, 3 + i, 0xe8c23c)
            px(11 - i / 2, 3 + i, 0xd8a02c)
        }
        return true
    case "blaze_powder": pile(&img, 0xe8901c, 0xfcb83c); return true
    case "ghast_tear": gem(&img, 0xe8e8f0, 0xb8b8c8, 0xffffff); return true
    case "slime_ball": orb(&img, 0x6fc05c, 0x84d46e); return true
    case "magma_cream": orb(&img, 0xc8742c, 0xe8a23c); return true
    case "snowball": orb(&img, 0xe8f0f0, 0xffffff); return true
    case "clay_ball": orb(&img, 0x9aa3b3, 0xb8c0cc); return true
    case "brick": ingot(&img, 0xb87058, 0x96604f, 0x6a4438); return true
    case "nether_brick": ingot(&img, 0x3c2228, 0x2c171b, 0x1a0d10); return true
    case "paper": fill(4, 3, 11, 12, 0xf0f0f0); fill(4, 3, 5, 12, 0xd8d8d8); return true
    case "book": bookIcon(&img, 0x8a4a2c); return true
    case "enchanted_book":
        bookIcon(&img, 0x8a4a2c)
        px(5, 4, 0xd667e8); px(10, 6, 0xd667e8); px(7, 9, 0xe89af0)
        return true
    case "writable_book": bookIcon(&img, 0x6a4a8a); return true
    case "compass", "recovery_compass":
        orb(&img, 0x5a5a62, 0x8a8a92)
        px(8, 6, name == "compass" ? 0xe83a3a : 0x2ce8e8); px(8, 7, 0xe8e8e8)
        return true
    case "clock": orb(&img, 0xe8c83c, 0xa8862c); px(8, 7, 0x3a3a3a); px(9, 8, 0x3a3a3a); return true
    case "bucket": bucketIcon(&img, nil); return true
    case "water_bucket": bucketIcon(&img, 0x3f76e4); return true
    case "lava_bucket": bucketIcon(&img, 0xe85d10); return true
    case "milk_bucket": bucketIcon(&img, 0xf0f0f0); return true
    case "powder_snow_bucket": bucketIcon(&img, 0xe8f0f0); return true
    case "cod_bucket", "salmon_bucket", "pufferfish_bucket", "tropical_fish_bucket", "axolotl_bucket", "tadpole_bucket":
        bucketIcon(&img, 0x3f76e4)
        px(8, 5, name == "salmon_bucket" ? 0xa84a3a : name == "pufferfish_bucket" ? 0xd8b83c : name == "axolotl_bucket" ? 0xf0a8c8 : 0x8a7a5c)
        return true
    case "potion", "splash_potion", "lingering_potion":
        let pot = potionDef(data?.potion ?? "water")
        bottleIcon(&img, pot.color)
        return true
    case "glass_bottle": bottleIcon(&img, nil); return true
    case "experience_bottle": bottleIcon(&img, 0x7ce84a); return true
    case "honey_bottle": bottleIcon(&img, 0xf0a83c); return true
    case "dragon_breath": bottleIcon(&img, 0xc84ae8); return true
    case "rotten_flesh": blob(&img, 0x8a5a3c, 0x6a9a5a); return true
    case "spider_eye": orb(&img, 0x8a1c2c, 0xc83a4a); px(8, 7, 0x3c0a12); return true
    case "fermented_spider_eye": orb(&img, 0x9a6a8a, 0xc898b8); px(8, 7, 0x3c0a12); return true
    case "shield": shieldIcon(&img); return true
    case "elytra": elytraIcon(&img); return true
    case "totem_of_undying": totemIcon(&img); return true
    case "nether_star": starIcon(&img, 0xf8f8d8); return true
    case "ender_chest": return false
    case "firework_rocket": rocketIcon(&img); return true
    case "name_tag": fill(4, 6, 11, 10, 0xd8c898); px(5, 7, 0x8a7a52); fill(3, 7, 3, 9, 0x8a7a52); return true
    case "lead":
        for i in 0..<8 { px(4 + i, 4 + Int((Foundation.sin(Double(i) * 0.8) * 2).rounded(.down)) + 4, 0xb89868) }
        return true
    case "saddle":
        fill(4, 6, 11, 8, 0x8a4a2c); fill(5, 5, 10, 5, 0x6a3a20); px(4, 9, 0xe8c83c); px(11, 9, 0xe8c83c)
        return true
    case "shulker_shell": fill(4, 5, 11, 9, 0x976797); fill(5, 4, 10, 4, 0xb89ab8); fill(5, 10, 10, 10, 0x7a527a); return true
    case "nautilus_shell": orb(&img, 0xd8c8b8, 0xb89a88); px(7, 7, 0x8a6a58); px(9, 7, 0x8a6a58); return true
    case "heart_of_the_sea": orb(&img, 0x1c8ac8, 0x3ab8e8); return true
    case "prismarine_shard": gem(&img, 0x6fa495, 0x4a7468, 0x9ac8b8); return true
    case "prismarine_crystals": gem(&img, 0xcdebe2, 0x9ac0b4, 0xffffff); return true
    case "ink_sac": blob(&img, 0x1c1c28, 0x3a3a4a); return true
    case "glow_ink_sac": blob(&img, 0x1c5c5c, 0x2ce8e8); return true
    case "scute": blob(&img, 0x47702e, 0x6a9a4c); return true
    case "honeycomb":
        fill(4, 4, 11, 11, 0xe89a2c)
        px(6, 6, 0xc87818); px(9, 6, 0xc87818); px(6, 9, 0xc87818); px(9, 9, 0xc87818)
        return true
    case "rabbit_hide": fill(4, 5, 11, 11, 0xb8966a); fill(5, 4, 7, 4, 0xb8966a); return true
    case "rabbit_foot": fill(6, 3, 9, 11, 0xb8966a); fill(5, 10, 10, 12, 0xa8865a); return true
    case "phantom_membrane": fill(4, 4, 11, 11, 0xb8c8d8); px(6, 6, 0x8aa0b8); px(9, 8, 0x8aa0b8); return true
    case "fire_charge": orb(&img, 0x3a1c0c, 0xe85d10); px(7, 5, 0xfcb83c); return true
    case "bowl": fill(4, 8, 11, 10, 0x8a6a42); fill(5, 11, 10, 11, 0x6a4f30); return true
    case "flint_and_steel": fill(3, 8, 6, 11, 0x3a3a3a); fill(9, 4, 12, 7, 0xc8c8c8); px(8, 8, 0xfcb83c); return true
    case "shears":
        fill(5, 3, 6, 8, 0xc8c8c8); fill(9, 3, 10, 8, 0xc8c8c8)
        fill(4, 9, 6, 11, 0x8a3a3a); fill(9, 9, 11, 11, 0x8a3a3a)
        return true
    case "fishing_rod":
        for i in 0..<9 { px(3 + i, 12 - i, 0x8a6a42) }
        for i in 0..<5 { px(12, 4 + i, 0xd8d8d8) }
        px(12, 9, 0x8a8a8a)
        return true
    case "carrot_on_a_stick", "warped_fungus_on_a_stick":
        for i in 0..<8 { px(3 + i, 12 - i, 0x8a6a42) }
        let c = name.hasPrefix("carrot") ? 0xe87a2c : 0x14a8a8
        px(12, 5, c); px(12, 6, c)
        return true
    case "spyglass": fill(5, 8, 7, 10, 0xc06843); fill(8, 5, 10, 7, 0x7a5c34); px(11, 4, 0xaee8f8); return true
    case "goat_horn":
        for i in 0..<8 {
            px(4 + i, 11 - Int((Double(i) * 0.8).rounded(.down)), 0xd8d0c4)
            px(4 + i, 12 - Int((Double(i) * 0.8).rounded(.down)), 0xb8b0a4)
        }
        return true
    case "brush": fill(7, 3, 8, 7, 0x8a6a42); fill(6, 8, 9, 11, 0xc8a868); fill(6, 12, 9, 12, 0xe8d8a8); return true
    case "end_crystal": gem(&img, 0xe8a8e8, 0xc84ae8, 0xf8e0f8); return true
    case "trident":
        for i in 0..<9 { px(8, 4 + i, 0x2c8a7a) }
        px(6, 4, 0x2c8a7a); px(10, 4, 0x2c8a7a); px(6, 5, 0x2c8a7a); px(10, 5, 0x2c8a7a)
        px(6, 3, 0x4ab8a8); px(8, 3, 0x4ab8a8); px(10, 3, 0x4ab8a8)
        return true
    case "crossbow":
        fill(4, 6, 11, 7, 0x6a4f30); fill(7, 4, 8, 11, 0x8a6a42); px(4, 5, 0xd8d8d8); px(11, 5, 0xd8d8d8)
        return true
    case "spectral_arrow":
        for i in 0..<9 { px(11 - i, 4 + i, 0xd8c054) }
        px(12, 3, 0xfcee9a)
        return true
    case "tipped_arrow":
        for i in 0..<9 { px(11 - i, 4 + i, 0x8a6a42) }
        px(12, 3, 0xc84ae8); px(11, 4, 0xc84ae8)
        return true
    case "chorus_fruit", "popped_chorus_fruit": blob(&img, name == "chorus_fruit" ? 0x6a4a7a : 0x9a7ab0, 0xb796c8); return true
    case "nether_wart": blob(&img, 0x71080a, 0xa61415); return true
    case "glistering_melon_slice": melonSlice(&img, 0xe8c83c); return true
    case "melon_slice": melonSlice(&img, 0xd83030); return true
    case "cocoa_beans": seeds(&img, 0x8a5a2c); return true
    case "sweet_berries": seeds(&img, 0xd03048); return true
    case "glow_berries": seeds(&img, 0xffb83c); return true
    case "cookie":
        orb(&img, 0xb8824a, 0xd8a86a)
        px(6, 6, 0x4a2c14); px(9, 8, 0x4a2c14); px(7, 9, 0x4a2c14)
        return true
    case "cake": return false
    case "music_disc_wander", "music_disc_aurora", "music_disc_descent":
        orb(&img, 0x1c1c1c, 0x3a3a3a)
        px(8, 7, name.hasSuffix("wander") ? 0x4ae04a : name.hasSuffix("aurora") ? 0x4a8ae8 : 0xe84a8a)
        px(7, 8, 0xc8c8c8)
        return true
    default:
        break
    }
    if name.hasSuffix("_dye") {
        let colorName = String(name.dropLast(4))
        if let col = COLOR_RGB[colorName] {
            pile(&img, Int(col), lighten(Int(col)))
            return true
        }
    }
    if name.hasSuffix("_spawn_egg") {
        let h = hashString(name)
        let c1 = hsl(Double(h % 360), 0.50, 0.55)
        let c2 = hsl(Double((h >> 8) % 360), 0.55, 0.40)
        for y in 3..<13 {
            for x in 4..<12 {
                let dx = (Double(x) - 7.5) / 3.6, dy = (Double(y) - 8) / 4.6
                if dx * dx + dy * dy < 1 {
                    put(&img, x, y, hash2(h, x, y) % 5 == 0 ? c2 : c1)
                }
            }
        }
        return true
    }
    if name.contains("_boat") || name.contains("_raft") {
        func fill2(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Int) {
            for y in y0...y1 { for x in x0...x1 { put(&img, x, y, c) } }
        }
        fill2(3, 7, 12, 9, 0x9a6b35); fill2(4, 10, 11, 11, 0x7a5226); fill2(4, 6, 5, 6, 0x9a6b35); fill2(10, 6, 11, 6, 0x9a6b35)
        if name.contains("chest") { fill2(6, 4, 9, 6, 0x8a5c2c) }
        return true
    }
    if name.contains("minecart") {
        fill(3, 6, 12, 11, 0x6a6a72); fill(4, 5, 11, 5, 0x8a8a92); fill(4, 7, 11, 10, 0x3a3a3e)
        if name.hasPrefix("chest") { fill(5, 4, 10, 8, 0x9a6b35) }
        if name.hasPrefix("furnace") { fill(5, 4, 10, 8, 0x7d7d7d) }
        if name.hasPrefix("tnt") { fill(5, 4, 10, 8, 0xc8412e) }
        if name.hasPrefix("hopper") { fill(5, 4, 10, 8, 0x4a4a4e) }
        return true
    }
    if name.hasSuffix("_sign") || name.hasSuffix("_hanging_sign") {
        fill(3, 4, 12, 9, 0xb8945f); fill(7, 10, 8, 13, 0x8a6a42)
        return true
    }
    if name.hasSuffix("_door") {
        let iron = name.hasPrefix("iron")
        fill(4, 2, 11, 13, iron ? 0xc8c8c8 : 0x9a6b35)
        fill(5, 3, 10, 6, iron ? 0xa8a8a8 : 0x7a5226)
        fill(5, 9, 10, 12, iron ? 0xa8a8a8 : 0x7a5226)
        return true
    }
    if name.hasSuffix("_bed") {
        let col = Int(COLOR_RGB[String(name.dropLast(4))] ?? 0xb02e26)
        fill(2, 7, 13, 9, col); fill(2, 6, 5, 6, 0xf0f0f0); fill(2, 10, 13, 11, 0x8a6a42)
        return true
    }
    if name.hasSuffix("pottery_sherd") {
        fill(4, 5, 11, 11, 0x9a5838); px(5, 4, 0x9a5838); px(10, 4, 0x9a5838)
        px(7, 7, 0x5a3220); px(8, 8, 0x5a3220)
        return true
    }
    if name.hasSuffix("armor_trim") || name == "netherite_upgrade" {
        fill(4, 3, 11, 12, 0x3a5c5c); fill(5, 4, 10, 11, 0x4a7474); px(7, 6, 0x8ac8c8); px(8, 8, 0x8ac8c8)
        return true
    }
    return false
}

private func lighten(_ c: Int) -> Int {
    let r = min(255, ((c >> 16) & 255) + 50), g = min(255, ((c >> 8) & 255) + 50), b = min(255, (c & 255) + 50)
    return (r << 16) | (g << 8) | b
}
private func blob(_ img: inout [UInt8], _ base: Int, _ light: Int) {
    for y in 4..<13 {
        for x in 3..<13 {
            let dx = (Double(x) - 8) / 4.6, dy = (Double(y) - 8.5) / 4.2
            let d = dx * dx + dy * dy
            if d < 1 { put(&img, x, y, d < 0.4 ? light : base) }
        }
    }
}
private func smallBlob(_ img: inout [UInt8], _ base: Int, _ light: Int) {
    for y in 6..<11 {
        for x in 6..<11 {
            let dx = (Double(x) - 8) / 2.4, dy = (Double(y) - 8.5) / 2.2
            let d = dx * dx + dy * dy
            if d < 1 { put(&img, x, y, d < 0.4 ? light : base) }
        }
    }
}
private func gem(_ img: inout [UInt8], _ base: Int, _ dark: Int, _ light: Int) {
    for y in 4..<12 {
        let hw = y < 7 ? Double(y - 3) * 1.6 : Double(12 - y) * 1.4
        var x = Int((8 - hw).rounded(.up))
        while Double(x) <= 7 + hw {
            put(&img, x, y, y < 6 ? light : y < 9 ? base : dark)
            x += 1
        }
    }
}
private func ingot(_ img: inout [UInt8], _ light: Int, _ base: Int, _ dark: Int) {
    for i in 0..<3 {
        put(&img, 5 - i + 3, 6 + i, light)
    }
    for y in 0..<4 {
        for x in 0..<9 {
            put(&img, 3 + x + (3 - Int((Double(y) * 0.8).rounded(.down))), 7 + y, y == 0 ? light : y < 3 ? base : dark)
        }
    }
}
private func pile(_ img: inout [UInt8], _ base: Int, _ light: Int) {
    for y in 8..<13 {
        let hw = Double(y - 7) * 1.2
        var x = Int((8 - hw).rounded(.up))
        while Double(x) <= 7 + hw {
            put(&img, x, y, (x + y) % 3 != 0 ? base : light)
            x += 1
        }
    }
    put(&img, 7, 7, light)
    put(&img, 8, 6, base)
}
private func seeds(_ img: inout [UInt8], _ c: Int) {
    for (x, y) in [(5, 6), (9, 5), (7, 8), (10, 9), (5, 10), (8, 11)] {
        put(&img, x, y, c)
        put(&img, x + 1, y, c)
        put(&img, x, y + 1, c)
    }
}
private func fruit(_ img: inout [UInt8], _ base: Int, _ light: Int) {
    for y in 5..<13 {
        for x in 4..<12 {
            let dx = (Double(x) - 8) / 3.8, dy = (Double(y) - 9) / 3.8
            if dx * dx + dy * dy < 1 { put(&img, x, y, x < 7 && y < 9 ? light : base) }
        }
    }
    put(&img, 8, 4, 0x6a4426)
    put(&img, 9, 3, 0x4a7a2c)
    put(&img, 10, 3, 0x4a7a2c)
}
private func orb(_ img: inout [UInt8], _ base: Int, _ light: Int) {
    for y in 4..<13 {
        for x in 4..<13 {
            let dx = (Double(x) - 8) / 4.2, dy = (Double(y) - 8) / 4.2
            let d = dx * dx + dy * dy
            if d < 1 { put(&img, x, y, d < 0.35 && x < 8 && y < 8 ? light : base) }
        }
    }
}
private func arc(_ img: inout [UInt8]) {
    for i in 0..<10 {
        let a = Double(i) / 9 * .pi / 2 + .pi * 0.75
        put(&img, Int((8 + Foundation.cos(a) * 5.5).rounded()), Int((8 + Foundation.sin(a) * 5.5).rounded()), 0x8a6a42)
        put(&img, Int((8 + Foundation.cos(a) * 4.5).rounded()), Int((8 + Foundation.sin(a) * 4.5).rounded()), 0x6a4f30)
    }
    for i in 0..<9 { put(&img, 4 + i, 4 + i, 0xe8e8e8) }
}
private func bookIcon(_ img: inout [UInt8], _ cover: Int) {
    for y in 3..<13 { for x in 4..<12 { put(&img, x, y, cover) } }
    for y in 4..<12 {
        put(&img, 11, y, 0xe8e0c8)
        put(&img, 10, y, 0xd8d0b8)
    }
    for y in 3..<13 { put(&img, 5, y, cover) }
}
private func bucketIcon(_ img: inout [UInt8], _ contents: Int?) {
    for i in 0..<8 { put(&img, 4 + i, 5, 0x8a8a8a) }
    for y in 6..<12 {
        let inset = Int((Double(y - 6) * 0.4).rounded(.down))
        put(&img, 4 + inset, y, 0xa8a8a8)
        put(&img, 11 - inset, y, 0x787878)
        for x in (5 + inset)..<(11 - inset) { put(&img, x, y, 0x989898) }
    }
    if let contents {
        for x in 5..<11 { put(&img, x, 5, contents) }
        for x in 6..<10 { put(&img, x, 6, contents) }
    }
    put(&img, 3, 5, 0x787878)
    put(&img, 12, 5, 0x787878)
}
private func bottleIcon(_ img: inout [UInt8], _ contents: Int?) {
    put(&img, 7, 2, 0xb8b8c8); put(&img, 8, 2, 0xb8b8c8)
    put(&img, 7, 3, 0xd8d8e8); put(&img, 8, 3, 0xd8d8e8)
    for y in 4..<13 {
        let hw = y < 6 ? 1 : 3
        for x in (8 - hw)...(7 + hw) {
            let edge = x == 8 - hw || x == 7 + hw || y == 12
            if edge { put(&img, x, y, 0xd8d8e8) }
            else if let contents, y >= 6 { put(&img, x, y, contents) }
        }
    }
}
private func shieldIcon(_ img: inout [UInt8]) {
    for y in 3..<13 {
        let hw = y < 9 ? 4 : 4 - (y - 9)
        for x in (8 - hw)...(7 + hw) {
            put(&img, x, y, (x + y) % 2 != 0 ? 0x8a6a42 : 0x9a7a52)
        }
    }
    for y in 3..<8 { put(&img, 7, y, 0xc8c8c8) }
}
private func elytraIcon(_ img: inout [UInt8]) {
    for i in 0..<6 {
        for w in 0...i {
            put(&img, 6 - i + w, 4 + i, 0xd8d8e8)
            put(&img, 9 + i - w, 4 + i, 0xb8b8d0)
        }
    }
    for i in 0..<4 {
        put(&img, 3 + i, 10 + i, 0xa8a8c0)
        put(&img, 12 - i, 10 + i, 0x8a8aa8)
    }
}
private func totemIcon(_ img: inout [UInt8]) {
    put(&img, 7, 3, 0xe8c83c); put(&img, 8, 3, 0xe8c83c)
    put(&img, 6, 4, 0xe8c83c); put(&img, 9, 4, 0xe8c83c)
    put(&img, 7, 4, 0x4ae04a); put(&img, 8, 4, 0x4ae04a)
    for y in 5..<9 { for x in 6..<10 { put(&img, x, y, 0xe8c83c) } }
    put(&img, 4, 6, 0xe8c83c); put(&img, 5, 6, 0xe8c83c); put(&img, 10, 6, 0xe8c83c); put(&img, 11, 6, 0xe8c83c)
    for y in 9..<12 {
        put(&img, 7, y, 0xc8a82c)
        put(&img, 8, y, 0xc8a82c)
    }
}
private func starIcon(_ img: inout [UInt8], _ c: Int) {
    put(&img, 8, 3, c); put(&img, 8, 4, c)
    for i in 0..<5 {
        put(&img, 4 + i, 8, c)
        put(&img, 8 + i, 8, c)
    }
    put(&img, 8, 12, c); put(&img, 8, 11, c)
    for y in 5..<11 {
        for x in 6..<11 {
            if abs(x - 8) + abs(y - 8) < 3 { put(&img, x, y, c) }
        }
    }
}
private func rocketIcon(_ img: inout [UInt8]) {
    for y in 3..<10 {
        put(&img, 7, y, 0xd8d8d8)
        put(&img, 8, y, 0xc8c8c8)
    }
    put(&img, 7, 2, 0xc84040); put(&img, 8, 2, 0xc84040)
    for i in 0..<4 { put(&img, 7 + (i % 2), 10 + i, 0x8a6a42) }
}
private func melonSlice(_ img: inout [UInt8], _ c: Int) {
    for y in 4..<12 {
        let hw = min(5, y - 3)
        for x in (8 - hw)...(7 + hw) {
            put(&img, x, y, y == 11 || abs(Double(x) - 7.5) > Double(hw) - 1.5 ? 0x5a8c1a : c)
        }
    }
    put(&img, 7, 6, 0x1c1c1c)
    put(&img, 9, 8, 0x1c1c1c)
}
