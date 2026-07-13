// Java-format resource pack imports — reads .zip or folder packs from
// ~/Library/Application Support/Elysium/resourcepacks/, maps
// the standard pack texture tree onto the procedural
// tile registry, scales 16×/32× art to one atlas resolution, plays .mcmeta
// frame animations, and falls back to the procedural painter for anything a
// pack doesn't cover. Pure app-layer: ElysiumCore goldens never see any of it.

import AppKit
import Compression
import CoreGraphics
import Foundation
import ImageIO
import ElysiumCore

private let MAX_PACK_ARCHIVE_BYTES = 512 << 20
private let MAX_PACK_FILE_BYTES = 64 << 20
private let MAX_PACK_ENTRIES = 100_000

private func safePackPath(_ path: String) -> Bool {
    if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("\\") || path.contains("\0") { return false }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
}

private func preferredTextureRoot(from paths: Dictionary<String, String>.Keys) -> String {
    var namespaces: Set<String> = []
    for key in paths {
        let lower = key.lowercased()
        guard let assets = lower.range(of: "assets/") else { continue }
        let parts = lower[assets.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[0].isEmpty, parts[1] == "textures" else { continue }
        namespaces.insert(String(parts[0]))
    }
    guard !namespaces.isEmpty else { return "" }
    let namespace = namespaces.contains("minecraft") ? "minecraft" : namespaces.sorted()[0]
    return "assets/\(namespace)/textures/"
}

// =============================================================================
// minimal read-only zip (central directory + raw deflate via Compression)
// =============================================================================
final class MiniZip {
    struct Entry {
        let method: UInt16
        let compSize: Int
        let uncompSize: Int
        let localOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= MAX_PACK_ARCHIVE_BYTES else { return nil }
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        data = d
        guard parseCentralDirectory() else { return nil }
    }

    private func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
    private func u32(_ o: Int) -> Int {
        Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
    }

    private func parseCentralDirectory() -> Bool {
        // EOCD signature scan from the tail (comment can pad up to 64KB)
        let n = data.count
        guard n > 22 else { return false }
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65535)
        while i >= stop {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return false }
        let count = u16(eocd + 10)
        guard count <= MAX_PACK_ENTRIES else { return false }
        var off = u32(eocd + 16)
        for _ in 0..<count {
            guard off + 46 <= n, u32(off) == 0x02014b50 else { return false }
            let method = UInt16(u16(off + 10))
            let compSize = u32(off + 20)
            let uncompSize = u32(off + 24)
            let nameLen = u16(off + 28)
            let extraLen = u16(off + 30)
            let commentLen = u16(off + 32)
            let localOffset = u32(off + 42)
            guard off + 46 + nameLen <= n,
                  off + 46 + nameLen + extraLen + commentLen <= n else { return false }
            if let name = String(data: data.subdata(in: (off + 46)..<(off + 46 + nameLen)), encoding: .utf8),
               safePackPath(name),
               !name.hasSuffix("/") {
                entries[name] = Entry(method: method, compSize: compSize,
                                      uncompSize: uncompSize, localOffset: localOffset)
            }
            off += 46 + nameLen + extraLen + commentLen
        }
        return true
    }

    func file(_ name: String) -> Data? {
        guard let e = entries[name] else { return nil }
        let lo = e.localOffset
        guard lo + 30 <= data.count, u32(lo) == 0x04034b50 else { return nil }
        // local header name/extra lengths can differ from the central record
        let nameLen = u16(lo + 26)
        let extraLen = u16(lo + 28)
        let start = lo + 30 + nameLen + extraLen
        guard start + e.compSize <= data.count else { return nil }
        let raw = data.subdata(in: start..<(start + e.compSize))
        if e.method == 0 {
            guard e.uncompSize == e.compSize, e.uncompSize <= MAX_PACK_FILE_BYTES else { return nil }
            return raw
        }
        guard e.method == 8 else { return nil }
        // uncompSize is an untrusted u32 from the central directory — cap it
        // so a tiny crafted zip can't force a multi-GB allocation
        guard e.uncompSize <= MAX_PACK_FILE_BYTES else { return nil }
        if e.uncompSize == 0 { return Data() }
        guard !raw.isEmpty else { return nil }
        var out = Data(count: e.uncompSize)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase, e.uncompSize,
                    srcBase, raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == e.uncompSize else { return nil }
        return out
    }
}

// =============================================================================
// PNG decode → straight (un-premultiplied) RGBA8
// =============================================================================
struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]   // straight RGBA, width*height*4
}

func decodePNG(_ data: Data) -> RGBAImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    guard w > 0, h > 0, w <= 4096, h <= 8192 else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let ok = px.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    // un-premultiply back to straight alpha (atlas + UI expect straight RGBA)
    var i = 0
    while i < px.count {
        let a = Int(px[i + 3])
        if a > 0 && a < 255 {
            px[i] = UInt8(min(255, Int(px[i]) * 255 / a))
            px[i + 1] = UInt8(min(255, Int(px[i + 1]) * 255 / a))
            px[i + 2] = UInt8(min(255, Int(px[i + 2]) * 255 / a))
        }
        i += 4
    }
    return RGBAImage(width: w, height: h, pixels: px)
}

// ---- pixel helpers ----------------------------------------------------------

/// nearest-neighbor (upscale / same size)
func scaleNearest(_ img: RGBAImage, to res: Int) -> [UInt8] {
    if img.width == res && img.height == res { return img.pixels }
    var out = [UInt8](repeating: 0, count: res * res * 4)
    for y in 0..<res {
        let sy = y * img.height / res
        for x in 0..<res {
            let sx = x * img.width / res
            let s = (sy * img.width + sx) * 4, d = (y * res + x) * 4
            out[d] = img.pixels[s]; out[d + 1] = img.pixels[s + 1]
            out[d + 2] = img.pixels[s + 2]; out[d + 3] = img.pixels[s + 3]
        }
    }
    return out
}

/// alpha-weighted box filter (downscale)
func scaleBox(_ img: RGBAImage, to res: Int) -> [UInt8] {
    if img.width == res && img.height == res { return img.pixels }
    // either axis smaller than the target → box dims would hit zero (div-by-zero
    // on a wide-but-short pack texture); nearest handles upscale fine
    if img.width < res || img.height < res { return scaleNearest(img, to: res) }
    var out = [UInt8](repeating: 0, count: res * res * 4)
    let bx = img.width / res, by = img.height / res
    for y in 0..<res {
        for x in 0..<res {
            var r = 0, g = 0, b = 0, a = 0, n = 0
            for dy in 0..<by {
                for dx in 0..<bx {
                    let s = ((y * by + dy) * img.width + (x * bx + dx)) * 4
                    let pa = Int(img.pixels[s + 3])
                    r += Int(img.pixels[s]) * pa
                    g += Int(img.pixels[s + 1]) * pa
                    b += Int(img.pixels[s + 2]) * pa
                    a += pa
                    n += 1
                }
            }
            let d = (y * res + x) * 4
            if a > 0 {
                out[d] = UInt8(r / a); out[d + 1] = UInt8(g / a); out[d + 2] = UInt8(b / a)
            }
            out[d + 3] = UInt8(a / n)
        }
    }
    return out
}

func scaleTo(_ img: RGBAImage, _ res: Int) -> [UInt8] {
    img.width > res ? scaleBox(img, to: res) : scaleNearest(img, to: res)
}

/// multiply RGB by a fixed color (bake a vanilla tint into the pixels)
func bakeTint(_ px: inout [UInt8], _ rgb: Int) {
    let tr = (rgb >> 16) & 255, tg = (rgb >> 8) & 255, tb = rgb & 255
    var i = 0
    while i < px.count {
        px[i] = UInt8(Int(px[i]) * tr / 255)
        px[i + 1] = UInt8(Int(px[i + 1]) * tg / 255)
        px[i + 2] = UInt8(Int(px[i + 2]) * tb / 255)
        i += 4
    }
}

// =============================================================================
// pack handle (zip or folder) + discovery
// =============================================================================
final class ResourcePack {
    let fileName: String          // what settings stores ("Faithful 32x - 1.20.1.zip")
    let displayName: String
    private(set) var description = ""
    private(set) var packFormat = 0
    private let zip: MiniZip?
    private let folderURL: URL?
    /// lowercased path → exact path (zips from Windows tools vary in case)
    private var pathIndex: [String: String] = [:]
    /// the pack's texture root, detected from its own folder layout
    /// ("assets/<namespace>/textures/") — Java packs declare the namespace
    private(set) var texRoot = ""

    init?(url: URL) {
        fileName = url.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            zip = nil
            folderURL = url
            displayName = fileName
            let root = url.standardizedFileURL.path
            if let e = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let f as URL in e where f.pathExtension != "" {
                    if pathIndex.count >= MAX_PACK_ENTRIES { return nil }
                    let full = f.standardizedFileURL.path
                    guard full.hasPrefix(root + "/") else { continue }
                    let rel = String(full.dropFirst(root.count + 1))
                    guard safePackPath(rel) else { continue }
                    pathIndex[rel.lowercased()] = rel
                }
            }
        } else if url.pathExtension.lowercased() == "zip", let z = MiniZip(url: url) {
            zip = z
            folderURL = nil
            displayName = String(fileName.dropLast(4))
            for k in z.entries.keys { pathIndex[k.lowercased()] = k }
        } else {
            return nil
        }
        guard pathIndex.keys.contains(where: { $0.hasSuffix("pack.mcmeta") }) else { return nil }
        // Texture packs often include helper namespaces (forge/fabric/realms).
        // Block/item/UI art is vanilla-compatible only under minecraft; using
        // dictionary iteration here made launches randomly fall back to the
        // procedural atlas. Prefer minecraft and keep fallback deterministic.
        texRoot = preferredTextureRoot(from: pathIndex.keys)
        parseMeta()
    }

    /// raw bytes for an in-pack path ("assets/<ns>/textures/block/stone.png")
    func file(_ path: String) -> Data? {
        // some packs nest everything one folder deep inside the zip
        for candidate in [path, prefixedPath(path)] {
            guard let c = candidate, let exact = pathIndex[c.lowercased()] else { continue }
            if let z = zip { return z.file(exact) }
            if let dir = folderURL {
                let url = dir.appendingPathComponent(exact)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= MAX_PACK_FILE_BYTES else { continue }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            }
        }
        return nil
    }

    private var nestedPrefix: String?
    private var nestedResolved = false
    private func prefixedPath(_ path: String) -> String? {
        if !nestedResolved {
            nestedResolved = true
            if pathIndex["pack.mcmeta"] == nil,
               let meta = pathIndex.keys.first(where: { $0.hasSuffix("/pack.mcmeta") && $0.components(separatedBy: "/").count == 2 }) {
                nestedPrefix = String(meta.dropLast("pack.mcmeta".count))
            }
        }
        guard let p = nestedPrefix else { return nil }
        return p + path
    }

    func has(_ path: String) -> Bool {
        pathIndex[path.lowercased()] != nil || (prefixedPath(path).map { pathIndex[$0.lowercased()] != nil } ?? false)
    }

    /// all in-pack paths under a directory prefix (normalized, nested prefix stripped)
    func list(prefix: String) -> [String] {
        let p = prefix.lowercased()
        var out: [String] = []
        for k in pathIndex.keys {
            if k.hasPrefix(p) { out.append(pathIndex[k]!) }
            else if let np = nestedPrefixLowercased(), k.hasPrefix(np + p) {
                out.append(String(pathIndex[k]!.dropFirst(np.count)))
            }
        }
        return out
    }
    private func nestedPrefixLowercased() -> String? {
        _ = prefixedPath("x")   // force resolution
        return nestedPrefix?.lowercased()
    }

    private func parseMeta() {
        guard let d = file("pack.mcmeta"),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pack = json["pack"] as? [String: Any] else { return }
        packFormat = pack["pack_format"] as? Int ?? 0
        if let s = pack["description"] as? String {
            description = s
        } else if let arr = pack["description"] as? [Any] {
            description = arr.compactMap { ($0 as? [String: Any])?["text"] as? String ?? $0 as? String }.joined()
        } else if let obj = pack["description"] as? [String: Any] {
            description = obj["text"] as? String ?? ""
        }
        // strip § formatting codes for our 5×7 UI font
        while let r = description.range(of: "§") {
            let next = description.index(after: r.lowerBound)
            description.removeSubrange(r.lowerBound..<(next < description.endIndex ? description.index(after: next) : description.endIndex))
        }
    }
}

func resourcePacksDir() -> URL {
    let dir = vcSupportDir().appendingPathComponent("resourcepacks", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// =============================================================================
// the default pack — behaves like built-in textures: always present (re-copied
// from the app bundle if deleted), always applied as the base layer under any
// user packs, shown in the pack list as a pinned "Default" entry. The
// procedural atlas remains the last-resort fallback if the bundle itself is
// damaged. Faithful 32x is third-party art — credit and license travel with
// it (packaging/FAITHFUL-LICENSE.txt, in-game credits, README).
// =============================================================================
let DEFAULT_PACK_FILE = "Faithful 32x - 1.20.1.zip"
let DEFAULT_PACK_LABEL = "Default (Faithful 32x)"

private func sameFileContents(_ lhs: String, _ rhs: String) -> Bool {
    let lhsURL = URL(fileURLWithPath: lhs)
    let rhsURL = URL(fileURLWithPath: rhs)
    guard let lhsValues = try? lhsURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          let rhsValues = try? rhsURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          lhsValues.isRegularFile == true,
          rhsValues.isRegularFile == true,
          lhsValues.fileSize == rhsValues.fileSize,
          let lhsData = try? Data(contentsOf: lhsURL, options: .mappedIfSafe),
          let rhsData = try? Data(contentsOf: rhsURL, options: .mappedIfSafe) else { return false }
    return lhsData == rhsData
}

/// restore the bundled default pack if the app-support copy is missing or stale
func ensureDefaultPack() {
    let dest = resourcePacksDir().appendingPathComponent(DEFAULT_PACK_FILE)
    guard let bundled = bundleResourcePath(DEFAULT_PACK_FILE),
          !sameFileContents(dest.path, bundled) else { return }
    try? FileManager.default.removeItem(at: dest)
    if (try? FileManager.default.copyItem(atPath: bundled, toPath: dest.path)) != nil {
        print("[packs] default pack restored from app bundle")
    }
}

/// user pack list → applied list: default pack force-appended at the END
/// (lowest priority — user packs override it, like vanilla's layering)
func withDefaultPack(_ userPacks: [String]) -> [String] {
    var list = userPacks.filter { $0 != DEFAULT_PACK_FILE }
    let dest = resourcePacksDir().appendingPathComponent(DEFAULT_PACK_FILE)
    if FileManager.default.fileExists(atPath: dest.path) { list.append(DEFAULT_PACK_FILE) }
    return list
}

func discoverResourcePacks() -> [ResourcePack] {
    let dir = resourcePacksDir()
    guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return items
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .compactMap { ResourcePack(url: $0) }
        .sorted { $0.fileName.lowercased() < $1.fileName.lowercased() }
}

// =============================================================================
// tile name → pack texture path mapping
// =============================================================================

// plain renames: tile name → ordered candidate paths under the texture root
private let NAME_MAP: [String: [String]] = [
    "grass_top": ["block/grass_block_top"],
    "grass_side": ["block/grass_block_side"],
    "farmland_dry": ["block/farmland"],
    "farmland_wet": ["block/farmland_moist"],
    "sandstone_side": ["block/sandstone"],
    "red_sandstone_side": ["block/red_sandstone"],
    "snow_block": ["block/snow"],
    "frosted_ice": ["block/frosted_ice_0"],
    "dried_kelp_block": ["block/dried_kelp_side"],
    "magma_block": ["block/magma"],
    "water": ["block/water_still"],
    "lava": ["block/lava_still"],
    "fire": ["block/fire_0"],
    "soul_fire": ["block/soul_fire_0"],
    "short_grass": ["block/short_grass", "block/grass"],
    "mangrove_roots": ["block/mangrove_roots_side", "block/mangrove_roots"],
    "suspicious_sand": ["block/suspicious_sand_0"],
    "suspicious_gravel": ["block/suspicious_gravel_0"],
    "bamboo": ["block/bamboo_stalk"],
    "bamboo_sapling": ["block/bamboo_stage0"],
    "big_dripleaf": ["block/big_dripleaf_top"],
    "small_dripleaf": ["block/small_dripleaf_top"],
    "azalea": ["block/azalea_top"],
    "flowering_azalea": ["block/flowering_azalea_top"],
    "pitcher_plant_top": ["block/pitcher_plant_top", "block/pitcher_crop_top"],
    "pitcher_plant_bottom": ["block/pitcher_plant_bottom", "block/pitcher_crop_bottom"],
    "pitcher_crop": ["block/pitcher_crop_top", "block/pitcher_crop_bottom"],
    "furnace_front_lit": ["block/furnace_front_on"],
    "blast_furnace_front_lit": ["block/blast_furnace_front_on"],
    "smoker_front_lit": ["block/smoker_front_on"],
    "observer_back_lit": ["block/observer_back_on"],
    "anvil_side": ["block/anvil"],
    "cartography_table_side": ["block/cartography_table_side3"],
    "lectern_side": ["block/lectern_sides"],
    "soul_campfire_log": ["block/soul_campfire_log_lit"],
    "respawn_anchor_side": ["block/respawn_anchor_side0"],
    "honey_block": ["block/honey_block_side"],
    "calibrated_sculk_sensor_side": ["block/calibrated_sculk_sensor_input_side"],
    "pointed_dripstone": ["block/pointed_dripstone_down_tip"],
    "sniffer_egg": ["block/sniffer_egg_not_cracked_north", "block/sniffer_egg_not_cracked"],
    "cocoa_stage3": ["block/cocoa_stage2"],
    "redstone_dust_line": ["block/redstone_dust_line0"],
    "stem_stage7": ["block/pumpkin_stem", "block/melon_stem"],
    "attached_stem": ["block/attached_pumpkin_stem", "block/attached_melon_stem"],
    // particle sprites (best-effort; procedural fallback is fine)
    "smoke_particle": ["particle/big_smoke_2", "particle/generic_3"],
    "flame_particle": ["particle/flame"],
    "heart_particle": ["particle/heart"],
    "angry_particle": ["particle/angry"],
    "crit_particle": ["particle/critical_hit"],
    "splash_particle": ["particle/splash_0"],
    "bubble_particle": ["particle/bubble"],
    "note_particle": ["particle/note"],
    "soul_particle": ["particle/soul_1", "particle/soul_0"],
    "sweep_particle": ["particle/sweep_2", "particle/sweep_0"],
    "slime_particle": ["item/slime_ball"],
    "snow_particle": ["particle/snowflake"],
    "petal_particle": ["particle/cherry_0", "particle/glow"],
    "portal_particle": ["particle/glow"],
    "redstone_particle": ["particle/glitter_0"],
    "enchant_particle": ["particle/sga_a"],
    // entity-textured / shader-effect blocks: stay procedural
    "air": [], "cave_air": [], "void_air": [],
    "end_portal": [], "chest_side": [], "ender_chest_side": [],
    "decorated_pot_side": [], "bell_body": [],
]

/// fixed vanilla tints to bake (engine renders these tiles untinted, MC art is grayscale)
private let BAKE_TINT: [String: Int] = [
    "birch_leaves": 0x80A755,
    "spruce_leaves": 0x619961,
    "redstone_dust_dot": 0xFF3030,
    "redstone_dust_line": 0xFF3030,
]

/// tiles whose MC art is grayscale-by-design and must KEEP the engine's biome
/// tint when a pack overrides them; every other overridden tile renders untinted
private let TINT_EXPECTED: Set<String> = [
    "grass_top", "water", "short_grass", "fern", "tall_grass", "large_fern",
    "sugar_cane", "vine", "lily_pad", "big_dripleaf", "small_dripleaf",
    "oak_leaves", "jungle_leaves", "acacia_leaves", "dark_oak_leaves", "mangrove_leaves",
]

private func candidates(_ tile: String) -> [String] {
    if let m = NAME_MAP[tile] { return m }
    if tile.hasPrefix("destroy_"), let n = Int(tile.dropFirst("destroy_".count)) {
        return ["block/destroy_stage_\(n)"]
    }
    if tile.hasPrefix("stem_stage"), Int(tile.dropFirst("stem_stage".count)) != nil {
        return ["block/pumpkin_stem", "block/melon_stem"]
    }
    return ["block/\(tile)"]
}

/// tiles built by stacking MC top/bottom halves into one square (door + 2-tall plants)
private func compositeHalves(_ tile: String) -> (top: String, bottom: String)? {
    if tile.hasSuffix("_door") {
        return ("block/\(tile)_top", "block/\(tile)_bottom")
    }
    if tile == "tall_grass" || tile == "large_fern" {
        return ("block/\(tile)_top", "block/\(tile)_bottom")
    }
    return nil
}

// vanilla stem age tint: r = age*32, g = 255-age*8, b = age*4
private func stemTint(_ age: Int) -> Int {
    (min(255, age * 32) << 16) | ((255 - age * 8) << 8) | (age * 4)
}

// =============================================================================
// atlas build
// =============================================================================
struct TileAnimation {
    let slice: Int
    let frames: [[UInt8]]           // each res*res*4
    let order: [(Int, Int)]         // (frame index, ticks)
    let interpolate: Bool
}

struct PackAtlasResult {
    var res: Int
    var slices: [[UInt8]]
    var icon16: BuiltAtlas
    var animations: [TileAnimation]
    var itemIcons: [String: [UInt8]]
    var tintGate: [UInt8]
    var fluidAnimated: Bool
    var appliedTiles: Int
    var appliedItems: Int
}

private struct LoadedTexture {
    var image: RGBAImage
    /// (frame index, ticks) play order + interpolate flag
    var animation: (frames: [(Int, Int)], interpolate: Bool)?
}

/// load a texture + its optional .mcmeta animation from the pack stack (first hit wins)
// =============================================================================
// entity-texture crops — beds, chests, the bell and the decorated pot are
// rendered by vanilla as block ENTITIES, so no Java pack has flat block/
// textures for them; the art lives in entity/ unwraps. These crops lift the
// pack's own art from there so every visible surface comes from the pack.
// (the end portal stays an engine effect — vanilla renders it as a shader,
// and packs have no texture for it either)
// =============================================================================
private struct EntityTileCrop {
    let path: String                                           // relative to texRoot, no .png
    let rects: [(x: Double, y: Double, w: Double, h: Double)]  // fractional; stacked vertically
    let rotate: Bool                                           // long bed strips lie sideways
}

private func entityTileCrop(_ tile: String) -> EntityTileCrop? {
    if tile.hasSuffix("_bed_top") {
        let c = String(tile.dropLast("_bed_top".count))
        // head (pillow) half over foot half, like the painter's layout
        return EntityTileCrop(path: "entity/bed/\(c)",
                              rects: [(6 / 64, 6 / 64, 16 / 64, 16 / 64),
                                      (6 / 64, 28 / 64, 16 / 64, 16 / 64)], rotate: false)
    }
    if tile.hasSuffix("_bed_side") {
        let c = String(tile.dropLast("_bed_side".count))
        // long side strip of the head piece; column nearest the top face
        // (x=22) becomes the tile's top row after rotation
        return EntityTileCrop(path: "entity/bed/\(c)",
                              rects: [(22 / 64, 6 / 64, 6 / 64, 16 / 64)], rotate: true)
    }
    switch tile {
    case "chest_side":
        // lid front (5 rows) stacked on base front (10 rows)
        return EntityTileCrop(path: "entity/chest/normal",
                              rects: [(14 / 64, 14 / 64, 14 / 64, 5 / 64),
                                      (14 / 64, 33 / 64, 14 / 64, 10 / 64)], rotate: false)
    case "ender_chest_side":
        return EntityTileCrop(path: "entity/chest/ender",
                              rects: [(14 / 64, 14 / 64, 14 / 64, 5 / 64),
                                      (14 / 64, 33 / 64, 14 / 64, 10 / 64)], rotate: false)
    case "bell_body":
        return EntityTileCrop(path: "entity/bell/bell_body",
                              rects: [(6 / 32, 6 / 32, 6 / 32, 7 / 32)], rotate: false)
    case "decorated_pot_side":
        return EntityTileCrop(path: "entity/decorated_pot/decorated_pot_side",
                              rects: [(0, 0, 1, 1)], rotate: false)
    default:
        return nil
    }
}

private func cropEntityTile(_ packs: [ResourcePack], _ crop: EntityTileCrop) -> RGBAImage? {
    guard let tex = loadTexture(packs, crop.path) else { return nil }
    let img = tex.image
    var pieces: [RGBAImage] = []
    for r in crop.rects {
        let x0 = Int(r.x * Double(img.width)), y0 = Int(r.y * Double(img.height))
        let w = max(1, Int(r.w * Double(img.width))), h = max(1, Int(r.h * Double(img.height)))
        guard x0 + w <= img.width, y0 + h <= img.height else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = ((y0 + y) * img.width + (x0 + x)) * 4, d = (y * w + x) * 4
                px[d] = img.pixels[s]; px[d + 1] = img.pixels[s + 1]
                px[d + 2] = img.pixels[s + 2]; px[d + 3] = img.pixels[s + 3]
            }
        }
        pieces.append(RGBAImage(width: w, height: h, pixels: px))
    }
    var out: RGBAImage
    if pieces.count == 1 {
        out = pieces[0]
    } else {
        // stack vertically (all crops share a width by construction)
        let w = pieces[0].width
        let h = pieces.reduce(0) { $0 + $1.height }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var yOff = 0
        for p in pieces {
            for y in 0..<p.height {
                let s = y * p.width * 4, d = ((yOff + y) * w) * 4
                px.replaceSubrange(d..<(d + p.width * 4), with: p.pixels[s..<(s + p.width * 4)])
            }
            yOff += p.height
        }
        out = RGBAImage(width: w, height: h, pixels: px)
    }
    if crop.rotate {
        // dst(row r, col c) = src(col r, row c): strip column 0 → tile row 0
        var px = [UInt8](repeating: 0, count: out.width * out.height * 4)
        for r in 0..<out.width {
            for c in 0..<out.height {
                let s = (c * out.width + r) * 4, d = (r * out.height + c) * 4
                px[d] = out.pixels[s]; px[d + 1] = out.pixels[s + 1]
                px[d + 2] = out.pixels[s + 2]; px[d + 3] = out.pixels[s + 3]
            }
        }
        out = RGBAImage(width: out.height, height: out.width, pixels: px)
    }
    return out
}

private func loadTexture(_ packs: [ResourcePack], _ relPath: String) -> LoadedTexture? {
    for p in packs {
        let full = "\(p.texRoot)\(relPath).png"
        guard let d = p.file(full), let img = decodePNG(d) else { continue }
        var anim: (frames: [(Int, Int)], interpolate: Bool)?
        if img.height > img.width, img.height % img.width == 0 {
            // animated strip; .mcmeta refines timing/order
            var frametime = 1
            var interpolate = false
            var frames: [(Int, Int)] = []
            if let md = p.file(full + ".mcmeta"),
               let json = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
               let a = json["animation"] as? [String: Any] {
                frametime = max(1, a["frametime"] as? Int ?? 1)
                interpolate = a["interpolate"] as? Bool ?? false
                if let list = a["frames"] as? [Any] {
                    for f in list {
                        if let i = f as? Int { frames.append((i, frametime)) }
                        else if let o = f as? [String: Any], let i = o["index"] as? Int {
                            frames.append((i, max(1, o["time"] as? Int ?? frametime)))
                        }
                    }
                }
            }
            let count = img.height / img.width
            if frames.isEmpty { frames = (0..<count).map { ($0, frametime) } }
            frames = frames.filter { $0.0 >= 0 && $0.0 < count }
            if frames.count > 1 { anim = (frames, interpolate) }
        }
        return LoadedTexture(image: img, animation: anim)
    }
    return nil
}

/// cut frame i out of a vertical strip
private func stripFrame(_ img: RGBAImage, _ i: Int) -> RGBAImage {
    let w = img.width
    let start = i * w * w * 4
    return RGBAImage(width: w, height: w, pixels: Array(img.pixels[start..<(start + w * w * 4)]))
}

func buildPackAtlas(enabledFileNames: [String]) -> PackAtlasResult? {
    let all = discoverResourcePacks()
    let packs = enabledFileNames.compactMap { name in all.first { $0.fileName == name } }
    guard !packs.isEmpty else { return nil }

    let base = ElysiumCore.buildAtlas()
    let names = allTileNames()

    // resolve every tile to (image, animation) or nil
    var resolved: [Int: LoadedTexture] = [:]
    var compositeSrcs: [Int: (RGBAImage, RGBAImage)] = [:]
    var entityTiles: [Int: RGBAImage] = [:]
    for (i, name) in names.enumerated() {
        if let halves = compositeHalves(name) {
            if var t = loadTexture(packs, halves.top)?.image, var b = loadTexture(packs, halves.bottom)?.image {
                if t.height > t.width { t = stripFrame(t, 0) }
                if b.height > b.width { b = stripFrame(b, 0) }
                compositeSrcs[i] = (t, b)
            }
            continue
        }
        for c in candidates(name) {
            if let t = loadTexture(packs, c) { resolved[i] = t; break }
        }
        if resolved[i] == nil, let ec = entityTileCrop(name), let img = cropEntityTile(packs, ec) {
            entityTiles[i] = img
        }
    }

    // pick one atlas resolution: the largest native size found, clamped sanely
    var res = 16
    for t in resolved.values { res = max(res, min(128, t.image.width)) }
    for (a, b) in compositeSrcs.values { res = max(res, min(128, max(a.width, b.width))) }

    var slices: [[UInt8]] = []
    slices.reserveCapacity(names.count)
    var icon16: [[UInt8]] = []
    icon16.reserveCapacity(names.count)
    var animations: [TileAnimation] = []
    var tintGate = [UInt8](repeating: 1, count: names.count)
    var fluidAnimated = false
    var applied = 0

    for (i, name) in names.enumerated() {
        var px: [UInt8]
        if let t = resolved[i] {
            applied += 1
            if !TINT_EXPECTED.contains(name) { tintGate[i] = 0 }
            if let anim = t.animation {
                // frame 0 of the play order into the slice; full set to the animator
                var frames: [[UInt8]] = []
                let count = t.image.height / t.image.width
                for f in 0..<count {
                    var fp = scaleTo(stripFrame(t.image, f), res)
                    if let bake = BAKE_TINT[name] { bakeTint(&fp, bake) }
                    frames.append(fp)
                }
                px = frames[anim.frames[0].0]
                animations.append(TileAnimation(slice: i, frames: frames,
                                                order: anim.frames, interpolate: anim.interpolate))
                if name == "water" || name == "lava" || name == "fire" || name == "soul_fire" {
                    fluidAnimated = true
                }
            } else {
                var img = t.image
                if img.height > img.width { img = stripFrame(img, 0) }   // strip without anim meta
                px = scaleTo(img, res)
                if let bake = BAKE_TINT[name] { bakeTint(&px, bake) }
                if name.hasPrefix("stem_stage"), let age = Int(name.dropFirst("stem_stage".count)) {
                    // vanilla stem models crop from the bottom: keep 2*(age+1)/16 rows
                    let keep = res * 2 * (age + 1) / 16
                    for y in 0..<(res - keep) {
                        for x in 0..<res { px[(y * res + x) * 4 + 3] = 0 }
                    }
                    bakeTint(&px, stemTint(age))
                } else if name == "attached_stem" {
                    bakeTint(&px, stemTint(7))
                }
            }
        } else if let img = entityTiles[i] {
            applied += 1
            tintGate[i] = 0
            px = scaleTo(img, res)
        } else if let (top, bottom) = compositeSrcs[i] {
            applied += 1
            tintGate[i] = TINT_EXPECTED.contains(name) ? 1 : 0
            // squash both halves into one square (each block half repeats the tile)
            px = [UInt8](repeating: 0, count: res * res * 4)
            let half = res / 2
            let t = scaleTo(top, res), b = scaleTo(bottom, res)
            for y in 0..<half {
                for x in 0..<res {
                    let sT = ((y * 2) * res + x) * 4, dT = (y * res + x) * 4
                    px[dT] = t[sT]; px[dT + 1] = t[sT + 1]; px[dT + 2] = t[sT + 2]; px[dT + 3] = t[sT + 3]
                    let sB = ((y * 2) * res + x) * 4, dB = ((y + half) * res + x) * 4
                    px[dB] = b[sB]; px[dB + 1] = b[sB + 1]; px[dB + 2] = b[sB + 2]; px[dB + 3] = b[sB + 3]
                }
            }
        } else {
            // substrate fallback, upscaled to the pack resolution
            if ProcessInfo.processInfo.environment["ELYSIUM_PACKDEBUG"] != nil {
                print("[packs] no pack art for tile \(i): \(name)")
            }
            px = scaleNearest(RGBAImage(width: 16, height: 16, pixels: base.pixels[i]), to: res)
        }
        slices.append(px)
        icon16.append(scaleBox(RGBAImage(width: res, height: res, pixels: px), to: 16))
    }

    // item icons: every textures/item/*.png in the stack, 16× for the icon cache
    var itemIcons: [String: [UInt8]] = [:]
    for p in packs.reversed() {   // walk lowest→highest so highest priority wins
        for path in p.list(prefix: p.texRoot + "item/") where path.hasSuffix(".png") {
            let base = String(path.components(separatedBy: "/").last!.dropLast(4))
            guard let d = p.file(path), var img = decodePNG(d) else { continue }
            if img.height > img.width, img.height % img.width == 0 {
                img = stripFrame(img, 0)
            }
            guard img.width == img.height else { continue }
            itemIcons[base] = scaleBox(img, to: 16)
        }
    }

    return PackAtlasResult(
        res: res, slices: slices,
        icon16: BuiltAtlas(count: names.count, pixels: icon16, missing: []),
        animations: animations, itemIcons: itemIcons, tintGate: tintGate,
        fluidAnimated: fluidAnimated, appliedTiles: applied, appliedItems: itemIcons.count)
}

// =============================================================================
// apply / revert — the single entry point used at boot and from the packs screen
// =============================================================================
/// the enabled pack stack, highest priority first — entity skins resolve here
var ACTIVE_PACKS: [ResourcePack] = []

/// load + composite a vanilla entity texture from the active packs
/// (base + overlays alpha-blended in order, or stacked vertically); nil when absent
func packEntityImage(_ rels: [String], stack: Bool = false, tints: [Int] = []) -> RGBAImage? {
    guard !rels.isEmpty, !ACTIVE_PACKS.isEmpty else { return nil }
    func load(_ rel: String) -> RGBAImage? {
        for p in ACTIVE_PACKS {
            if let d = p.file(p.texRoot + rel), var img = decodePNG(d) {
                // vanilla ships some entity art grayscale for render-time
                // tinting (tropical fish, sheep wool) — bake the tint here
                if let i = rels.firstIndex(of: rel), i < tints.count, tints[i] != 0xFFFFFF {
                    bakeTint(&img.pixels, tints[i])
                }
                return img
            }
        }
        return nil
    }
    guard var base = load(rels[0]) else { return nil }
    if stack {
        // vertical sheet: each entry appended below the previous (sheep + fur)
        for rel in rels.dropFirst() {
            guard let next = load(rel), next.width == base.width else { return nil }
            base = RGBAImage(width: base.width, height: base.height + next.height,
                             pixels: base.pixels + next.pixels)
        }
        return base
    }
    for rel in rels.dropFirst() {
        guard let over = load(rel), over.width == base.width, over.height == base.height else { continue }
        for i in stride(from: 0, to: base.pixels.count, by: 4) {
            let a = Int(over.pixels[i + 3])
            if a == 0 { continue }
            for c in 0..<3 {
                let o = Int(over.pixels[i + c]), b = Int(base.pixels[i + c])
                base.pixels[i + c] = UInt8((o * a + b * (255 - a)) / 255)
            }
            base.pixels[i + 3] = 255
        }
    }
    return base
}

func applyResourcePacks(_ userPacks: [String], game: GameCore, renderer: WorldRenderer, ui: UIManager) {
    let t0 = CFAbsoluteTimeGetCurrent()
    ensureDefaultPack()
    let enabled = withDefaultPack(userPacks)
    if let result = buildPackAtlas(enabledFileNames: enabled) {
        renderer.installPackAtlas(result)
        initIcons(result.icon16)
        setUIAtlas(result.icon16)
        PACK_TINT_GATE = result.tintGate
        let items = result.itemIcons
        itemIconOverride = items.isEmpty ? nil : { name in items[name] }
        // GUI sheets + bitmap font from the same pack stack
        let all = discoverResourcePacks()
        let packs = enabled.compactMap { name in all.first { $0.fileName == name } }
        ACTIVE_PACKS = packs
        renderer.sunTex = packEntityImage(["environment/sun.png"]).flatMap { renderer.makeImageTexture($0) }
        renderer.moonTex = packEntityImage(["environment/moon_phases.png"]).flatMap { renderer.makeImageTexture($0) }
        let pui = PackUI(packs: packs, device: renderer.device)
        ui.packUI = pui
        ui.cv.guiTexture = pui?.texture
        packFontWidths = pui?.fontWidths
        print(String(format: "[packs] %@ → %d/%d tiles, %d item icons, %d animated, %d× atlas, %d GUI sheets (%.0fms)",
                     enabled.joined(separator: " + "), result.appliedTiles, result.slices.count,
                     result.appliedItems, result.animations.count, result.res, pui?.sheets.count ?? 0,
                     (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    } else {
        renderer.installProceduralAtlas()
        PACK_TINT_GATE = nil
        itemIconOverride = nil
        ACTIVE_PACKS = []
        renderer.sunTex = nil
        renderer.moonTex = nil
        ui.packUI = nil
        ui.cv.guiTexture = nil
        packFontWidths = nil
        print("[packs] procedural atlas restored")
    }
    fflush(stdout)
    resetIconCache()
    ui.cv.resetIconSlots()
    renderer.resetSpriteSlots()
    renderer.entityRenderer.resetSkins()   // entity textures re-resolve vs the new stack
    game.remeshAllLoaded()   // vertex tints depend on the gate — rebuild meshes
}

// =============================================================================
// PACK GUI — imports the pack's interface art (HUD icons, widgets, container
// backgrounds, bitmap font, dirt background) into one composited texture.
// Sheets live in fixed 512×512 cells at exactly 2× base-GUI scale (16px-per-
// 8px-glyph); packs at other resolutions are rescaled on load.
// =============================================================================
final class PackUI {
    let texture: MTLTexture
    private(set) var sheets: Set<String> = []
    /// per-character advance in base px (8px grid), from ascii.png; nil = no pack font
    private(set) var fontWidths: [Double]?

    /// cell origins in the composite texture (each 512×512; content = base×2)
    static let CELLS: [String: (Int, Int)] = [
        "icons": (0, 0), "widgets": (512, 0), "ascii": (1024, 0), "bg": (1536, 0),
        "inventory": (0, 512), "generic_54": (512, 512), "crafting_table": (1024, 512), "furnace": (1536, 512),
        "brewing_stand": (0, 1024), "enchanting_table": (512, 1024), "anvil": (1024, 1024), "hopper": (1536, 1024),
        "dispenser": (0, 1536), "shulker_box": (512, 1536), "grindstone": (1024, 1536), "stonecutter": (1536, 1536),
        "smithing": (0, 2048), "cartography_table": (512, 2048), "beacon": (1024, 2048), "horse": (1536, 2048),
    ]

    init?(packs: [ResourcePack], device: MTLDevice) {
        let W = 2048, H = 2560
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        func load(_ rel: String) -> RGBAImage? {
            for p in packs {
                if let d = p.file(p.texRoot + "\(rel).png"), let img = decodePNG(d) {
                    return img
                }
            }
            return nil
        }
        func blit(_ img: RGBAImage, _ cellX: Int, _ cellY: Int, baseSize: Int) {
            // rescale so content occupies baseSize*2 px in the cell
            let target = baseSize * 2
            let scaled = img.width == target ? img.pixels : scaleTo(img, target)
            for y in 0..<min(target, 512) {
                let dst = ((cellY + y) * W + cellX) * 4
                let src = y * target * 4
                pixels.replaceSubrange(dst..<(dst + min(target, 512) * 4),
                                       with: scaled[src..<(src + min(target, 512) * 4)])
            }
        }

        let sources: [(String, String, Int)] = [
            ("icons", "gui/icons", 256), ("widgets", "gui/widgets", 256),
            ("bg", "gui/options_background", 16),
            ("inventory", "gui/container/inventory", 256),
            ("generic_54", "gui/container/generic_54", 256),
            ("crafting_table", "gui/container/crafting_table", 256),
            ("furnace", "gui/container/furnace", 256),
            ("brewing_stand", "gui/container/brewing_stand", 256),
            ("enchanting_table", "gui/container/enchanting_table", 256),
            ("anvil", "gui/container/anvil", 256),
            ("hopper", "gui/container/hopper", 256),
            ("dispenser", "gui/container/dispenser", 256),
            ("shulker_box", "gui/container/shulker_box", 256),
            ("grindstone", "gui/container/grindstone", 256),
            ("stonecutter", "gui/container/stonecutter", 256),
            ("smithing", "gui/container/smithing", 256),
            ("cartography_table", "gui/container/cartography_table", 256),
            ("beacon", "gui/container/beacon", 256),
            ("horse", "gui/container/horse", 256),
        ]
        for (key, rel, base) in sources {
            if let img = load(rel) {
                let cell = PackUI.CELLS[key]!
                blit(img, cell.0, cell.1, baseSize: base)
                sheets.insert(key)
            }
        }
        // bitmap font: 16×16 grid of 8×8 glyphs; advance = trailing edge + 1
        if let ascii = load("font/ascii") {
            let cell = PackUI.CELLS["ascii"]!
            blit(ascii, cell.0, cell.1, baseSize: 128)
            sheets.insert("ascii")
            let g = ascii.width / 16    // native glyph cell size
            var widths = [Double](repeating: 6, count: 256)
            for c in 0..<256 {
                let gx = (c % 16) * g, gy = (c / 16) * g
                var maxX = -1
                for y in 0..<g {
                    for x in 0..<g {
                        if ascii.pixels[((gy + y) * ascii.width + gx + x) * 4 + 3] > 32 {
                            if x > maxX { maxX = x }
                        }
                    }
                }
                let base = 8.0 / Double(g)
                widths[c] = maxX < 0 ? 4 : (Double(maxX + 1) * base + 1)
            }
            widths[32] = 4   // space
            fontWidths = widths
        }
        guard !sheets.isEmpty else { return nil }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: W * 4)
        }
        texture = tex
    }
}
