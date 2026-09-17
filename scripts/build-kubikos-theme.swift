#!/usr/bin/swift
// Builds Elysium's KUBIKOS Cubic World resource-pack alternative from a locally licensed Unity
// package. This is an ordinary deterministic raster conversion: it does not call an AI service or
// train/generate from the source art. Semantic alpha/luminance masks come from Elysium's frozen
// procedural registry, while colors and material detail come from KUBIKOS diffuse textures.

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum BuildError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)
    case process(String)

    var description: String {
        switch self {
        case .usage(let value), .invalid(let value), .process(let value): return value
        }
    }
}

private struct Options {
    let unityPackage: URL
    let registryExport: URL
    let titleBackground: URL
    let titleLogo: URL
    let output: URL
}

private struct RGBA {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

private enum Material: String, CaseIterable {
    case grass, soil, stone, sand, wood, water, lava, ice, crystal, foliage, snow, item
}

/// A normalized rectangle in one of KUBIKOS's fixed 1024px Cube.fbx diffuse layouts.  These
/// layouts are UV unwraps rather than directly tileable images: the central face is the only
/// coherent material surface.  Keep this provenance explicit instead of ever sampling an entire
/// Unity sheet or relying on a positional heuristic.
private struct NormalizedCrop {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private enum MaterialTreatment {
    case cubeFace
    case coherentSurface(NormalizedCrop)
}

private struct MaterialRecipe {
    let suffixes: [String]
    let treatment: MaterialTreatment
}

// Cube.fbx maps its central face to U .275...490 and V .502...718.  PNG rows are top-origin,
// so this is intentionally an inset of that face (292, 299, 200, 200 at 1024px), avoiding its
// beveled seams and the stretched padding outside the UV island.
private let cubeFaceCrop = NormalizedCrop(x: 292.0 / 1024.0, y: 299.0 / 1024.0,
                                          width: 200.0 / 1024.0, height: 200.0 / 1024.0)

// `Water.png` is the coherent repeatable ripple map used by the KUBIKOS water shader.  It is
// distinct from `Water_D.png`, whose dark center is merely one term in a Cube.fbx UV layout.
private let waterTextureCrop = NormalizedCrop(x: 0, y: 0, width: 1, height: 1)

// Crystal2_E is the KUBIKOS sapphire emission source.  Unlike the black `Crytal_D` crystal-model
// unwrap, this declared blue facet region is visibly coherent and keeps gem blocks/items luminous
// without borrowing from its unrelated UV islands.
private let sapphireCrystalCrop = NormalizedCrop(x: 160.0 / 1024.0, y: 160.0 / 1024.0,
                                                 width: 160.0 / 1024.0, height: 160.0 / 1024.0)

private let fixedBuildDate = Date(timeIntervalSince1970: 946_684_800)
private let tileRecordMagic = Data("ELYSIUM_TILE_RGBA_V1\n".utf8)
private let itemRecordMagic = Data("ELYSIUM_ITEM_RGBA_V1\n".utf8)
private let rgbaBytesPerTile = 16 * 16 * 4

private struct ItemManifestEntry {
    let name: String
    let icon: String
    let provider: String
}

private func parseOptions() throws -> Options {
    var values: [String: String] = [:]
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count.isMultiple(of: 2) else {
        throw BuildError.usage("usage: swift scripts/build-kubikos-theme.swift --unitypackage PATH --registry-export PATH --output PATH")
    }
    for index in stride(from: 0, to: args.count, by: 2) {
        let key = args[index]
        guard ["--unitypackage", "--registry-export", "--output"].contains(key),
              values[key] == nil else { throw BuildError.usage("invalid argument: \(key)") }
        values[key] = args[index + 1]
    }
    guard let package = values["--unitypackage"], let registry = values["--registry-export"],
          let output = values["--output"] else {
        throw BuildError.usage("all three arguments are required")
    }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
    let result = Options(
        unityPackage: URL(fileURLWithPath: package),
        registryExport: URL(fileURLWithPath: registry),
        // Title surfaces are Elysium-owned product assets, intentionally not caller-supplied
        // art.  The rest of the archive comes from KUBIKOS diffuse materials plus registry masks.
        titleBackground: repository.appendingPathComponent("packaging/title-bg.png"),
        titleLogo: repository.appendingPathComponent("packaging/logo.png"),
        output: URL(fileURLWithPath: output))
    let manager = FileManager.default
    for url in [result.unityPackage, result.registryExport,
                result.titleBackground, result.titleLogo] {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BuildError.invalid("missing regular input: \(url.path)")
        }
    }
    return result
}

@discardableResult
private func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                 input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    let stdin = input.map { _ in Pipe() }
    if let stdin { process.standardInput = stdin }
    try process.run()
    if let stdin, let input {
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
    }
    // Drain before waiting: the registry exporter intentionally emits every 16x16 tile mask,
    // which is larger than a pipe buffer. Waiting first would deadlock that child on stdout.
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BuildError.process("command failed (\(process.terminationStatus)): \(executable) \(arguments.joined(separator: " "))")
    }
    return output
}

private func decodePNG(_ url: URL) throws -> RGBA {
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw BuildError.invalid("cannot decode PNG: \(url.path)")
    }
    let width = image.width, height = image.height
    guard width > 0, height > 0, width <= 4096, height <= 4096,
          width <= Int.max / height / 4 else {
        throw BuildError.invalid("invalid PNG dimensions: \(url.path)")
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw BuildError.invalid("cannot allocate PNG surface: \(url.path)")
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RGBA(width: width, height: height, pixels: pixels)
}

private func encodePNG(_ image: RGBA, to url: URL) throws {
    let data = Data(image.pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(width: image.width, height: image.height,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                              UTType.png.identifier as CFString, 1, nil) else {
        throw BuildError.invalid("cannot encode PNG: \(url.path)")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw BuildError.invalid("cannot finalize PNG: \(url.path)")
    }
}

private func fnv1a(_ text: String) -> UInt64 {
    text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}

/// Map a semantic Elysium path to one of the reviewed KUBIKOS swatches.  The caller supplies
/// the fallback because an unknown solid tile should be stone-like, while an unknown direct item
/// should use the neutral item swatch.  Keeping that distinction at this one boundary prevents a
/// future identifier from silently becoming grass-green in either surface.
private func material(for path: String, fallback: Material) -> Material {
    let lower = path.lowercased()
    // These are solid terrain surfaces, unlike short/tall grass and plants below.  This check
    // must precede the foliage family so a grass block cannot inherit the large plant atlas.
    if lower == "grass" || lower == "grass_top" || lower == "grass_side" ||
        lower.contains("grass_block") || lower.contains("grass_path") {
        return .grass
    }
    if lower.contains("water") || lower.contains("bubble") || lower.contains("kelp") ||
        lower.contains("coral") || lower.contains("prismarine") || lower.contains("conduit") {
        return .water
    }
    if lower.contains("lava") || lower.contains("magma") || lower.contains("fire") ||
        lower.contains("torch") || lower.contains("blaze") || lower.contains("campfire") ||
        lower.contains("lantern") || lower.contains("glow") || lower.contains("shroomlight") {
        return .lava
    }
    if lower.contains("ice") || lower.contains("snow") || lower.contains("frost") ||
        lower.contains("powder") || lower.contains("polar") {
        return lower.contains("ice") ? .ice : .snow
    }
    if lower.contains("redstone") {
        return .lava
    }
    if lower.contains("emerald") {
        return .foliage
    }
    if lower.contains("diamond") || lower.contains("amethyst") || lower.contains("crystal") ||
        lower.contains("lapis") ||
        lower.contains("enchant") || lower.contains("beacon") || lower.contains("end") {
        return .crystal
    }
    if lower.contains("gold") || lower.contains("glistering") {
        return .lava
    }
    if lower.contains("iron") || lower.contains("copper") || lower.contains("netherite") ||
        lower.contains("chainmail") || lower.contains("shear") || lower.contains("flint") ||
        lower.contains("compass") || lower.contains("clock") || lower.contains("minecart") {
        return .stone
    }
    // These colour families are limited to manufactured coloured surfaces.  They retain a useful
    // semantic colour family without treating an unrelated word such as "bedrock" as a bed.
    let colourableSurface = lower.contains("_bed_") || lower.hasSuffix("_bed") ||
        lower.contains("_candle") || lower.contains("_shulker_box") ||
        lower.contains("_stained_glass") || lower.hasSuffix("_wool")
    if colourableSurface {
        if lower.hasPrefix("red_") || lower.hasPrefix("orange_") || lower.hasPrefix("yellow_") {
            return .lava
        }
        if lower.hasPrefix("light_blue_") || lower.hasPrefix("blue_") || lower.hasPrefix("cyan_") {
            return .water
        }
        if lower.hasPrefix("green_") || lower.hasPrefix("lime_") {
            return .foliage
        }
        if lower.hasPrefix("purple_") || lower.hasPrefix("magenta_") || lower.hasPrefix("pink_") {
            return .crystal
        }
        if lower.hasPrefix("white_") {
            return .snow
        }
        if lower.hasPrefix("black_") || lower.hasPrefix("gray_") || lower.hasPrefix("light_gray_") {
            return .stone
        }
        if lower.hasPrefix("brown_") {
            return .wood
        }
    }
    if lower.contains("bee_nest") || lower.contains("beehive") ||
        lower.contains("crimson_stem") || lower.contains("warped_stem") ||
        lower.contains("cartography") || lower.contains("fletching") ||
        lower.contains("composter") || lower.contains("jukebox") ||
        lower.contains("lectern") || lower.contains("loom") || lower.contains("scaffolding") ||
        lower.contains("note_block") || lower.contains("pumpkin") ||
        lower.contains("wood") || lower.contains("log") || lower.contains("plank") ||
        lower.contains("chest") || lower.contains("barrel") || lower.contains("ladder") ||
        lower.contains("door") || lower.contains("fence") || lower.contains("sign") ||
        lower.contains("bookshelf") || lower.contains("crafting") || lower.contains("bowl") {
        return .wood
    }
    if lower.contains("portal") || lower.contains("respawn_anchor") ||
        lower.contains("sculk") || lower.contains("froglight") || lower.contains("dragon_egg") ||
        lower.contains("shulker") || lower == "glass" || lower.contains("tinted_glass") {
        return .crystal
    }
    if lower.contains("tnt") {
        return .lava
    }
    if lower.contains("frogspawn") {
        return .water
    }
    if lower.contains("sponge") || lower.contains("honey") || lower.contains("cake") ||
        lower.contains("turtle_egg") || lower.contains("sniffer_egg") {
        return .sand
    }
    if lower.contains("bedrock") || lower.contains("debris") || lower.contains("andesite") ||
        lower.contains("diorite") || lower.contains("granite") || lower.contains("calcite") ||
        lower.contains("quartz") || lower.contains("netherrack") || lower.contains("chain") ||
        lower.contains("bell") || lower.contains("cauldron") || lower.contains("brewing") ||
        lower.contains("comparator") || lower.contains("repeater") || lower.contains("rail") ||
        lower.contains("hopper") || lower.contains("dispenser") || lower.contains("dropper") ||
        lower.contains("observer") || lower.contains("piston") || lower.contains("lever") ||
        lower.contains("lightning_rod") || lower.contains("spawner") || lower.contains("smithing") ||
        lower.contains("target") || lower.contains("daylight_detector") ||
        lower.contains("tripwire") || lower.contains("bone_block") || lower.contains("coal_block") ||
        lower.contains("decorated_pot") || lower.contains("purpur") || lower.contains("smoker") {
        return .stone
    }
    if lower.contains("leaf") || lower.contains("leaves") || lower.contains("grass") ||
        lower.contains("vine") || lower.contains("flower") || lower.contains("sapling") ||
        lower.contains("wheat") || lower.contains("crop") || lower.contains("moss") ||
        lower.contains("fern") || lower.contains("azalea") || lower.contains("bamboo") ||
        lower.contains("cactus") || lower.contains("plant") || lower.contains("mushroom") ||
        lower.contains("root") || lower.contains("stem") || lower.contains("sprout") ||
        lower.contains("wart") || lower.contains("fungus") || lower.contains("propagule") ||
        lower.contains("sugar_cane") || lower.contains("berry") || lower.contains("cocoa") ||
        lower.contains("carrot") || lower.contains("potato") || lower.contains("allium") ||
        lower.contains("bluet") || lower.contains("orchid") || lower.contains("dandelion") ||
        lower.contains("tulip") || lower.contains("daisy") || lower.contains("lilac") ||
        lower.contains("lily") || lower.contains("peony") || lower.contains("poppy") ||
        lower.contains("rose") || lower.contains("dead_bush") || lower.contains("petal") ||
        lower.contains("sea_pickle") || lower.contains("melon") || lower.contains("hay") ||
        lower.contains("slime") {
        return .foliage
    }
    if lower.contains("sand") || lower.contains("gravel") || lower.contains("clay") ||
        lower.contains("terracotta") || lower.contains("concrete") || lower.contains("mud") {
        return .sand
    }
    if lower.contains("dirt") || lower.contains("farmland") || lower.contains("soil") ||
        lower.contains("mycelium") || lower.contains("nylium") || lower.contains("soul") {
        return .soil
    }
    if lower.contains("stone") || lower.contains("ore") || lower.contains("deepslate") ||
        lower.contains("brick") || lower.contains("cobble") || lower.contains("tuff") ||
        lower.contains("basalt") || lower.contains("blackstone") || lower.contains("obsidian") ||
        lower.contains("anvil") || lower.contains("furnace") || lower.contains("metal") {
        return .stone
    }
    if lower.contains("item") || lower.contains("gui") || lower.contains("font") ||
        lower.contains("entity") || lower.contains("environment") {
        return .item
    }
    return fallback
}

/// Direct item identifiers contain fewer material cues than block names.  Classify the tool,
/// equipment, food, and spawn-egg families before falling back to the normal block classifier so
/// a sword or bow never becomes an arbitrary grass-colored icon.
private func material(forItem name: String) -> Material {
    let lower = name.lowercased()
    if lower.contains("wooden") || lower.contains("bow") || lower.contains("rod") ||
        lower.contains("stick") || lower.contains("boat") || lower.contains("raft") ||
        lower.contains("book") || lower.contains("paper") || lower.contains("bowl") ||
        lower.contains("leather") || lower.contains("saddle") || lower.contains("shield") ||
        lower.contains("arrow") || lower.contains("brush") {
        return .wood
    }
    if lower.contains("axolotl_bucket") || lower.contains("cod_bucket") ||
        lower.contains("pufferfish_bucket") || lower.contains("salmon_bucket") ||
        lower.contains("tadpole_bucket") || lower.contains("tropical_fish_bucket") {
        return .water
    }
    if lower.contains("turtle_helmet") {
        return .foliage
    }
    if lower.contains("bucket") {
        // Preserve liquid/snow buckets through the shared semantic classifier, while ordinary
        // and milk buckets take the neutral metal fallback.
        return material(for: lower, fallback: .stone)
    }
    if lower.contains("trident") || lower.contains("spyglass") || lower.contains("armor_trim") ||
        lower.contains("mace") {
        return .stone
    }
    if lower.contains("sword") || lower.contains("pickaxe") || lower.contains("axe") ||
        lower.contains("shovel") || lower.contains("hoe") || lower.contains("helmet") ||
        lower.contains("chestplate") || lower.contains("leggings") || lower.contains("boots") {
        return material(for: lower, fallback: .item)
    }
    if lower.contains("apple") || lower.contains("bread") || lower.contains("cookie") ||
        lower.contains("melon") || lower.contains("beef") || lower.contains("pork") ||
        lower.contains("mutton") || lower.contains("chicken") || lower.contains("rabbit") ||
        lower.contains("fish") || lower.contains("carrot") || lower.contains("potato") ||
        lower.contains("beetroot") || lower.contains("stew") || lower.contains("fruit") ||
        lower.contains("honey") || lower.contains("wheat") || lower.contains("egg") ||
        lower.contains("spawn_egg") {
        return .foliage
    }
    return material(for: lower, fallback: .item)
}

private func cropped(_ source: RGBA, normalized rect: NormalizedCrop, label: String) throws -> RGBA {
    guard source.width == 1_024, source.height == 1_024 else {
        throw BuildError.invalid("expected fixed 1024px KUBIKOS source for \(label), got \(source.width)x\(source.height)")
    }
    let x = Int((rect.x * Double(source.width)).rounded(.down))
    let y = Int((rect.y * Double(source.height)).rounded(.down))
    let width = Int((rect.width * Double(source.width)).rounded(.down))
    let height = Int((rect.height * Double(source.height)).rounded(.down))
    guard x >= 0, y >= 0, width >= 16, height >= 16,
          x <= source.width - width, y <= source.height - height else {
        throw BuildError.invalid("invalid declared KUBIKOS material crop for \(label)")
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        let sourceRange = ((y + row) * source.width + x) * 4..<( (y + row) * source.width + x + width) * 4
        let destinationRange = row * width * 4..<(row + 1) * width * 4
        pixels.replaceSubrange(destinationRange, with: source.pixels[sourceRange])
    }
    return RGBA(width: width, height: height, pixels: pixels)
}

/// KUBIKOS crystal art is an emission source, authored substantially darker than it appears once
/// Unity applies the material emission pass.  Compensate only for that missing renderer stage;
/// every output pixel remains a scaled KUBIKOS source pixel.
private func emissionBalanced(_ source: RGBA, exposure: Double) -> RGBA {
    var output = source
    for offset in stride(from: 0, to: output.pixels.count, by: 4) {
        for channel in 0..<3 {
            output.pixels[offset + channel] = UInt8(min(255, max(0,
                Int(Double(output.pixels[offset + channel]) * exposure))))
        }
    }
    return output
}

private func loadKUBIKOSMaterials(from root: URL) throws -> [Material: RGBA] {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
        throw BuildError.invalid("cannot enumerate extracted KUBIKOS package")
    }
    var entries: [(String, URL)] = []
    for case let pathnameURL as URL in enumerator where pathnameURL.lastPathComponent == "pathname" {
        guard let logical = try? String(contentsOf: pathnameURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), logical.hasSuffix(".png") else { continue }
        let asset = pathnameURL.deletingLastPathComponent().appendingPathComponent("asset")
        guard manager.fileExists(atPath: asset.path) else { continue }
        entries.append((logical, asset))
    }
    entries.sort { $0.0 < $1.0 }
    // Do not add `Items_D`, `TreesAndPlants_D`, or `CubeAtlas 1_D` here.  They are 4096px
    // heterogeneous UV atlases, not material swatches.  Every recipe below is either a fixed
    // Cube.fbx diffuse map with an explicitly declared coherent face crop or a named, coherent
    // KUBIKOS shader/emission surface.
    let preferred: [Material: MaterialRecipe] = [
        .grass: .init(suffixes: ["/Textures/Grass_D.png"], treatment: .cubeFace),
        .soil: .init(suffixes: ["/Textures/Planes/Soil_D.png", "/Textures/Soil_D.png"], treatment: .cubeFace),
        .stone: .init(suffixes: ["/Textures/Stone_4_D.png", "/Textures/Rock_2_D.png"], treatment: .cubeFace),
        .sand: .init(suffixes: ["/Textures/Sand_D.png", "/Textures/GroundDried_D.png"], treatment: .cubeFace),
        .wood: .init(suffixes: ["/Textures/Wood_Light_D.png", "/Textures/Wood_Normal_D.png"], treatment: .cubeFace),
        .water: .init(suffixes: ["/Textures/Water.png"], treatment: .coherentSurface(waterTextureCrop)),
        .lava: .init(suffixes: ["/Textures/Lava.png"], treatment: .coherentSurface(waterTextureCrop)),
        .ice: .init(suffixes: ["/Textures/Ice_D.png"], treatment: .cubeFace),
        .crystal: .init(suffixes: ["/Textures/Crystal/Crystal2_E.png"], treatment: .coherentSurface(sapphireCrystalCrop)),
        .foliage: .init(suffixes: ["/Textures/Grass_D.png"], treatment: .cubeFace),
        .snow: .init(suffixes: ["/Textures/Snow_D.png", "/Textures/Planes/Snow_D.png"], treatment: .cubeFace),
        .item: .init(suffixes: ["/Textures/Wood_Normal_D.png", "/Textures/Wood_Light_D.png"], treatment: .cubeFace),
    ]
    var result: [Material: RGBA] = [:]
    for material in Material.allCases {
        guard let recipe = preferred[material] else { continue }
        guard let entry = recipe.suffixes.lazy.compactMap({ suffix in
            entries.first(where: { $0.0.hasSuffix(suffix) })
        }).first else {
            throw BuildError.invalid("missing KUBIKOS diffuse material for \(material.rawValue)")
        }
        let source = try decodePNG(entry.1)
        let swatch: RGBA
        switch recipe.treatment {
        case .cubeFace:
            swatch = try cropped(source, normalized: cubeFaceCrop, label: entry.0)
        case .coherentSurface(let crop):
            swatch = try cropped(source, normalized: crop, label: entry.0)
        }
        result[material] = material == .crystal ? emissionBalanced(swatch, exposure: 1.8) : swatch
    }
    return result
}

/// Apply a KUBIKOS material to an Elysium-owned semantic mask. RGB from the mask is used only as
/// a scalar light map; no source palette pixels are carried into the generated art.
private func materialized(_ target: RGBA, with source: RGBA, key: String) -> RGBA {
    let seed = fnv1a(key)
    // Sample one contiguous portion of a pre-cropped material swatch.  In particular, never
    // modulo across a Unity UV sheet: that was what baked the visible cross/atlas collage into
    // the original generated KUBIKOS archive.
    let sampleWidth = max(1, source.width * 3 / 4)
    let sampleHeight = max(1, source.height * 3 / 4)
    let offsetX = Int(seed & 0xffff) % max(1, source.width - sampleWidth + 1)
    let offsetY = Int((seed >> 16) & 0xffff) % max(1, source.height - sampleHeight + 1)
    var output = RGBA(width: target.width, height: target.height,
                      pixels: [UInt8](repeating: 0, count: target.pixels.count))
    for y in 0..<target.height {
        for x in 0..<target.width {
            let index = (y * target.width + x) * 4
            let alpha = target.pixels[index + 3]
            guard alpha > 0 else { continue }
            let sx = offsetX + min(sampleWidth - 1, x * sampleWidth / target.width)
            let sy = offsetY + min(sampleHeight - 1, y * sampleHeight / target.height)
            let sourceIndex = (sy * source.width + sx) * 4
            let luminance = (Double(target.pixels[index]) * 0.2126 +
                             Double(target.pixels[index + 1]) * 0.7152 +
                             Double(target.pixels[index + 2]) * 0.0722) / 255
            // KUBIKOS is the entire visible material. The target contributes only illumination,
            // preserving Elysium's semantic seams and transparent silhouettes without copying
            // its palette into the alternate style.
            let intensity = min(1.28, max(0.36, 0.42 + luminance * 0.78))
            for channel in 0..<3 {
                let kubikos = Double(source.pixels[sourceIndex + channel]) * intensity
                output.pixels[index + channel] = UInt8(min(255, max(0, Int(kubikos))))
            }
            output.pixels[index + 3] = alpha
        }
    }
    return output
}

private func scaleNearest(_ image: RGBA, to side: Int) -> RGBA {
    var output = RGBA(width: side, height: side, pixels: [UInt8](repeating: 0, count: side * side * 4))
    for y in 0..<side {
        for x in 0..<side {
            let sx = min(image.width - 1, x * image.width / side)
            let sy = min(image.height - 1, y * image.height / side)
            let source = (sy * image.width + sx) * 4
            let destination = (y * side + x) * 4
            output.pixels[destination..<(destination + 4)] = image.pixels[source..<(source + 4)]
        }
    }
    return output
}

private func composeGrid(_ images: [RGBA], columns: Int) throws -> RGBA {
    guard !images.isEmpty, columns > 0, images.count.isMultiple(of: columns),
          let first = images.first, first.width > 0, first.height > 0,
          images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
        throw BuildError.invalid("invalid celestial image grid")
    }
    let rows = images.count / columns
    var output = RGBA(width: first.width * columns, height: first.height * rows,
                      pixels: [UInt8](repeating: 0, count: first.width * columns * first.height * rows * 4))
    for (index, image) in images.enumerated() {
        let x0 = (index % columns) * first.width
        let y0 = (index / columns) * first.height
        for y in 0..<first.height {
            let destination = ((y0 + y) * output.width + x0) * 4
            let source = y * first.width * 4
            output.pixels.replaceSubrange(destination..<(destination + first.width * 4),
                                          with: image.pixels[source..<(source + first.width * 4)])
        }
    }
    return output
}

private func decodeTileRecords(_ data: Data) throws -> [(String, RGBA)] {
    guard data.starts(with: tileRecordMagic) else { throw BuildError.invalid("unexpected registry-export format") }
    var offset = tileRecordMagic.count
    var output: [(String, RGBA)] = []
    while offset < data.count {
        guard offset + 2 <= data.count else { throw BuildError.invalid("truncated tile record") }
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        guard length > 0, offset + length + rgbaBytesPerTile <= data.count,
              let name = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
            throw BuildError.invalid("invalid tile record")
        }
        offset += length
        output.append((name, RGBA(width: 16, height: 16,
                                  pixels: Array(data[offset..<(offset + rgbaBytesPerTile)]))))
        offset += rgbaBytesPerTile
    }
    guard !output.isEmpty, Set(output.map(\.0)).count == output.count else {
        throw BuildError.invalid("invalid tile registry coverage")
    }
    return output
}

private func decodeItemRecords(_ data: Data) throws -> [String: RGBA] {
    guard data.starts(with: itemRecordMagic) else {
        throw BuildError.invalid("unexpected item registry-export format")
    }
    var offset = itemRecordMagic.count
    var output: [String: RGBA] = [:]
    while offset < data.count {
        guard offset + 2 <= data.count else {
            throw BuildError.invalid("truncated item record")
        }
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        guard length > 0, offset + length + rgbaBytesPerTile <= data.count,
              let name = String(data: data[offset..<(offset + length)], encoding: .utf8),
              output[name] == nil else {
            throw BuildError.invalid("invalid item record")
        }
        offset += length
        output[name] = RGBA(width: 16, height: 16,
                            pixels: Array(data[offset..<(offset + rgbaBytesPerTile)]))
        offset += rgbaBytesPerTile
    }
    guard !output.isEmpty else { throw BuildError.invalid("empty item registry coverage") }
    return output
}

private func decodeItemManifest(_ data: Data) throws -> [ItemManifestEntry] {
    guard let text = String(data: data, encoding: .utf8) else {
        throw BuildError.invalid("invalid item manifest UTF-8")
    }
    let entries = try text.split(separator: "\n", omittingEmptySubsequences: true).map { line -> ItemManifestEntry in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3,
              !fields[0].isEmpty, !fields[1].isEmpty,
              fields[2] == "item" || fields[2] == "block" else {
            throw BuildError.invalid("invalid item manifest record")
        }
        return ItemManifestEntry(name: String(fields[0]), icon: String(fields[1]),
                                 provider: String(fields[2]))
    }
    guard !entries.isEmpty, Set(entries.map(\.name)).count == entries.count else {
        throw BuildError.invalid("invalid item manifest coverage")
    }
    return entries
}

private func regularFiles(in root: URL) throws -> [URL] {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root,
                                              includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw BuildError.invalid("unexpected symlink: \(url.path)") }
        if values.isRegularFile == true { result.append(url) }
    }
    return result.sorted { $0.path < $1.path }
}

private func relativePath(_ url: URL, root: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path.hasSuffix("/")
        ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else { throw BuildError.invalid("path escaped stage") }
    return String(path.dropFirst(rootPath.count))
}

private func blankImage(width: Int, height: Int) -> RGBA {
    RGBA(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
}

/// Paint a rectangular KUBIKOS-material swatch directly into an image.  The source has already
/// been reduced to one declared coherent Cube.fbx face, so this function scales that face without
/// wrapping across unrelated Unity UV islands.  It is the only source for generated UI, entity,
/// and celestial pixels; the surrounding geometry is Elysium-owned vector-like layout code rather
/// than imported raster art.
private func paintMaterial(_ destination: inout RGBA, source: RGBA, key: String,
                           x: Int, y: Int, width: Int, height: Int,
                           alpha: UInt8 = 255, brightness: Double = 1) {
    guard width > 0, height > 0 else { return }
    let seed = fnv1a(key)
    for dy in 0..<height {
        let destinationY = y + dy
        guard destinationY >= 0, destinationY < destination.height else { continue }
        for dx in 0..<width {
            let destinationX = x + dx
            guard destinationX >= 0, destinationX < destination.width else { continue }
            // Use the center of the matching source texel, including for a one-pixel glyph or
            // icon stroke.  This yields a stable representative material color without a seam.
            let sourceX = min(source.width - 1, ((dx * 2 + 1) * source.width) / (width * 2))
            let sourceY = min(source.height - 1, ((dy * 2 + 1) * source.height) / (height * 2))
            let sourceOffset = (sourceY * source.width + sourceX) * 4
            let destinationOffset = (destinationY * destination.width + destinationX) * 4
            // A small deterministic variation makes broad procedural panels retain the faceted
            // material detail of the KUBIKOS diffuse source without pulling in another texture.
            let variation = 0.90 + Double((dx &* 17 &+ dy &* 31 &+ Int(seed & 7)) & 7) * 0.025
            for channel in 0..<3 {
                destination.pixels[destinationOffset + channel] = UInt8(min(255, max(0,
                    Int(Double(source.pixels[sourceOffset + channel]) * brightness * variation))))
            }
            destination.pixels[destinationOffset + 3] = min(alpha, source.pixels[sourceOffset + 3])
        }
    }
}

private func materialImage(width: Int, height: Int, source: RGBA, key: String,
                           alpha: UInt8 = 255, brightness: Double = 1) -> RGBA {
    var result = blankImage(width: width, height: height)
    paintMaterial(&result, source: source, key: key, x: 0, y: 0,
                  width: width, height: height, alpha: alpha, brightness: brightness)
    return result
}

private func drawFrame(_ image: inout RGBA, material: RGBA, key: String,
                       x: Int, y: Int, width: Int, height: Int, thickness: Int = 2) {
    guard width > 0, height > 0, thickness > 0 else { return }
    paintMaterial(&image, source: material, key: key + "/top", x: x, y: y,
                  width: width, height: min(thickness, height), brightness: 0.78)
    paintMaterial(&image, source: material, key: key + "/bottom", x: x, y: y + height - thickness,
                  width: width, height: min(thickness, height), brightness: 1.12)
    paintMaterial(&image, source: material, key: key + "/left", x: x, y: y,
                  width: min(thickness, width), height: height, brightness: 0.90)
    paintMaterial(&image, source: material, key: key + "/right", x: x + width - thickness, y: y,
                  width: min(thickness, width), height: height, brightness: 1.04)
}

private func stampHeart(_ image: inout RGBA, material: RGBA, key: String, x: Int, y: Int,
                        half: Bool = false) {
    let rows = [".##.##.", "#######", ".#####.", "..###..", "...#..."]
    for (dy, row) in rows.enumerated() {
        for (dx, character) in row.enumerated() where character == "#" && (!half || dx < 4) {
            paintMaterial(&image, source: material, key: "\(key)/\(dx)/\(dy)",
                          x: x + dx, y: y + dy, width: 1, height: 1)
        }
    }
}

private func buildHUDIcons(materials: [Material: RGBA]) -> RGBA {
    var image = blankImage(width: 256, height: 256)
    let stone = materials[.stone]!
    let crystal = materials[.crystal]!
    let foliage = materials[.foliage]!
    let lava = materials[.lava]!
    paintMaterial(&image, source: crystal, key: "hud/crosshair/h", x: 0, y: 7, width: 15, height: 1)
    paintMaterial(&image, source: crystal, key: "hud/crosshair/v", x: 7, y: 0, width: 1, height: 15)
    paintMaterial(&image, source: crystal, key: "hud/crosshair/core", x: 6, y: 6, width: 3, height: 3,
                  brightness: 1.22)
    stampHeart(&image, material: stone, key: "hud/heart/container", x: 16, y: 1)
    stampHeart(&image, material: lava, key: "hud/heart/full", x: 52, y: 1)
    stampHeart(&image, material: lava, key: "hud/heart/half", x: 61, y: 1, half: true)
    stampHeart(&image, material: foliage, key: "hud/heart/poisoned", x: 88, y: 1)
    stampHeart(&image, material: foliage, key: "hud/heart/poisoned-half", x: 97, y: 1, half: true)
    stampHeart(&image, material: stone, key: "hud/heart/withered", x: 124, y: 1)
    stampHeart(&image, material: stone, key: "hud/heart/withered-half", x: 133, y: 1, half: true)
    stampHeart(&image, material: crystal, key: "hud/heart/absorbing", x: 160, y: 1)
    stampHeart(&image, material: materials[.ice]!, key: "hud/heart/frozen", x: 178, y: 1)
    stampHeart(&image, material: materials[.ice]!, key: "hud/heart/frozen-half", x: 187, y: 1, half: true)
    for (x, brightness) in [(16, 0.45), (25, 0.76), (34, 1.05)] {
        paintMaterial(&image, source: stone, key: "hud/armor/\(x)", x: x, y: 9,
                      width: 8, height: 8, brightness: brightness)
    }
    paintMaterial(&image, source: materials[.water]!, key: "hud/air", x: 16, y: 18, width: 8, height: 8)
    for (x, brightness) in [(16, 0.45), (52, 1.0), (61, 0.7), (88, 1.10), (97, 0.78)] {
        stampHeart(&image, material: foliage, key: "hud/food/\(x)", x: x, y: 28,
                   half: brightness < 0.75)
    }
    paintMaterial(&image, source: crystal, key: "hud/xp", x: 0, y: 64, width: 182, height: 5)
    return image
}

private func buildWidgets(materials: [Material: RGBA]) -> RGBA {
    var image = blankImage(width: 256, height: 256)
    let wood = materials[.wood]!
    let stone = materials[.stone]!
    let crystal = materials[.crystal]!
    paintMaterial(&image, source: wood, key: "widgets/hotbar", x: 0, y: 0, width: 182, height: 22)
    drawFrame(&image, material: stone, key: "widgets/hotbar-frame", x: 0, y: 0, width: 182, height: 22)
    for slot in 0..<9 {
        drawFrame(&image, material: stone, key: "widgets/hotbar-slot/\(slot)",
                  x: 3 + slot * 20, y: 3, width: 18, height: 16, thickness: 1)
    }
    drawFrame(&image, material: crystal, key: "widgets/selection", x: 0, y: 22, width: 24, height: 23)
    drawFrame(&image, material: crystal, key: "widgets/offhand", x: 24, y: 22, width: 29, height: 24)
    for (index, y) in [46, 66, 86].enumerated() {
        paintMaterial(&image, source: index == 0 ? stone : wood, key: "widgets/button/\(index)",
                      x: 0, y: y, width: 200, height: 20, brightness: index == 2 ? 1.12 : 0.96)
        drawFrame(&image, material: index == 2 ? crystal : stone, key: "widgets/button-frame/\(index)",
                  x: 0, y: y, width: 200, height: 20)
    }
    return image
}

private func buildContainer(_ name: String, materials: [Material: RGBA]) -> RGBA {
    var image = materialImage(width: 256, height: 256, source: materials[.stone]!,
                              key: "container/\(name)/background", brightness: 0.58)
    paintMaterial(&image, source: materials[.wood]!, key: "container/\(name)/panel",
                  x: 8, y: 8, width: 240, height: 240, brightness: 0.92)
    drawFrame(&image, material: materials[.crystal]!, key: "container/\(name)/frame",
              x: 8, y: 8, width: 240, height: 240, thickness: 3)
    let seed = fnv1a(name)
    let rows = 3 + Int(seed & 1)
    let columns = name == "horse" ? 5 : 9
    let originX = 16 + max(0, (9 - columns) * 9)
    for row in 0..<rows {
        for column in 0..<columns {
            let x = originX + column * 22
            let y = 40 + row * 22
            paintMaterial(&image, source: materials[.soil]!, key: "container/\(name)/slot/\(row)/\(column)",
                          x: x, y: y, width: 18, height: 18, brightness: 0.48)
            drawFrame(&image, material: materials[.stone]!, key: "container/\(name)/slot-frame/\(row)/\(column)",
                      x: x, y: y, width: 18, height: 18, thickness: 1)
        }
    }
    paintMaterial(&image, source: materials[.item]!, key: "container/\(name)/title",
                  x: 20, y: 18, width: 112, height: 8, brightness: 1.15)
    return image
}

private func glyphRows(for scalar: UInt8) -> [UInt8] {
    let uppercase = scalar >= 97 && scalar <= 122 ? scalar - 32 : scalar
    let letters: [UInt8: [UInt8]] = [
        65: [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        66: [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        67: [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        68: [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
        69: [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        70: [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
        71: [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110],
        72: [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        73: [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        74: [0b00001, 0b00001, 0b00001, 0b00001, 0b10001, 0b10001, 0b01110],
        75: [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
        76: [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
        77: [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
        78: [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
        79: [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        80: [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        81: [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
        82: [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
        83: [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        84: [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        85: [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        86: [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
        87: [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
        88: [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
        89: [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
        90: [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
        48: [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
        49: [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        50: [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
        51: [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
        52: [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        53: [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110],
        54: [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        55: [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        56: [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        57: [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b11100],
    ]
    if let rows = letters[uppercase] { return rows }
    switch scalar {
    case 32: return [0, 0, 0, 0, 0, 0, 0]
    case 46: return [0, 0, 0, 0, 0, 0b01100, 0b01100]
    case 44: return [0, 0, 0, 0, 0, 0b01100, 0b01000]
    case 33: return [0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0, 0b00100]
    case 63: return [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0, 0b00100]
    case 45: return [0, 0, 0, 0b11111, 0, 0, 0]
    case 58: return [0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0]
    case 47: return [0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0, 0]
    default: return [0b01110, 0b10001, 0b00010, 0b00100, 0b01000, 0, 0b00100]
    }
}

private func buildFont(materials: [Material: RGBA]) -> RGBA {
    var image = blankImage(width: 128, height: 128)
    let source = materials[.crystal]!
    for glyph in 0..<256 {
        let rows = glyphRows(for: UInt8(glyph))
        let originX = (glyph % 16) * 8 + 1
        let originY = (glyph / 16) * 8
        for (y, row) in rows.enumerated() {
            for x in 0..<5 where row & (1 << (4 - x)) != 0 {
                paintMaterial(&image, source: source, key: "font/\(glyph)/\(x)/\(y)",
                              x: originX + x, y: originY + y, width: 1, height: 1)
            }
        }
    }
    return image
}

private func entityMaterial(for path: String) -> Material {
    let lower = path.lowercased()
    if lower.contains("squid") || lower.contains("fish") || lower.contains("dolphin") ||
        lower.contains("guardian") || lower.contains("axolotl") || lower.contains("turtle") {
        return .water
    }
    if lower.contains("blaze") || lower.contains("ghast") || lower.contains("magma") ||
        lower.contains("piglin") || lower.contains("hoglin") || lower.contains("strider") {
        return .lava
    }
    if lower.contains("snow") || lower.contains("polar") || lower.contains("skeleton") {
        return .snow
    }
    if lower.contains("end") || lower.contains("warden") || lower.contains("allay") {
        return .crystal
    }
    if lower.contains("creeper") || lower.contains("frog") || lower.contains("sniffer") ||
        lower.contains("tadpole") || lower.contains("bee") {
        return .foliage
    }
    return .item
}

private func entityDimensions(for path: String) -> (Int, Int) {
    let twoToOne: Set<String> = [
        "entity/pig/pig.png", "entity/cow/cow.png", "entity/cow/red_mooshroom.png",
        "entity/sheep/sheep.png", "entity/sheep/sheep_fur.png", "entity/chicken.png",
        "entity/creeper/creeper.png", "entity/spider/spider.png", "entity/spider/cave_spider.png",
        "entity/spider/spider_eyes.png", "entity/rabbit/brown.png", "entity/wolf/wolf.png",
        "entity/cat/tabby.png", "entity/cat/all_black.png", "entity/cat/ocelot.png",
        "entity/llama/creamy.png", "entity/enderman/enderman.png", "entity/enderman/enderman_eyes.png",
        "entity/endermite.png", "entity/silverfish.png", "entity/hoglin/hoglin.png",
        "entity/hoglin/zoglin.png", "entity/blaze.png", "entity/ghast/ghast.png",
        "entity/slime/magmacube.png", "entity/slime/slime.png", "entity/squid/squid.png",
        "entity/squid/glow_squid.png", "entity/turtle/big_sea_turtle.png", "entity/bear/polarbear.png",
        "entity/boat/oak.png", "entity/end_crystal/end_crystal.png", "entity/minecart.png"
    ]
    if path == "entity/fox/fox.png" { return (48, 32) }
    if path == "entity/strider/strider.png" || path == "entity/witch.png" { return (32, 64) }
    return twoToOne.contains(path) ? (64, 32) : (64, 64)
}

private func entityPaths() -> [String] {
    let base = [
        "entity/allay/allay.png", "entity/axolotl/axolotl_lucy.png", "entity/bat.png",
        "entity/bear/polarbear.png", "entity/bee/bee.png", "entity/blaze.png", "entity/boat/oak.png",
        "entity/camel/camel.png", "entity/cat/all_black.png", "entity/cat/ocelot.png",
        "entity/cat/tabby.png", "entity/chicken.png", "entity/cow/cow.png",
        "entity/cow/red_mooshroom.png", "entity/creeper/creeper.png", "entity/dolphin.png",
        "entity/end_crystal/end_crystal.png", "entity/enderdragon/dragon.png",
        "entity/enderman/enderman.png", "entity/enderman/enderman_eyes.png", "entity/endermite.png",
        "entity/fish/cod.png", "entity/fish/pufferfish.png", "entity/fish/salmon.png",
        "entity/fish/tropical_a.png", "entity/fish/tropical_a_pattern_1.png", "entity/fox/fox.png",
        "entity/frog/temperate_frog.png", "entity/ghast/ghast.png", "entity/goat/goat.png",
        "entity/guardian.png", "entity/guardian_elder.png", "entity/hoglin/hoglin.png",
        "entity/hoglin/zoglin.png", "entity/horse/donkey.png", "entity/horse/horse_brown.png",
        "entity/horse/horse_skeleton.png", "entity/horse/mule.png", "entity/illager/evoker.png",
        "entity/illager/pillager.png", "entity/illager/ravager.png", "entity/illager/vex.png",
        "entity/illager/vindicator.png", "entity/iron_golem/iron_golem.png", "entity/llama/creamy.png",
        "entity/minecart.png", "entity/panda/panda.png", "entity/parrot/parrot_red_blue.png",
        "entity/phantom.png", "entity/pig/pig.png", "entity/piglin/piglin.png",
        "entity/piglin/piglin_brute.png", "entity/piglin/zombified_piglin.png",
        "entity/player/wide/steve.png", "entity/rabbit/brown.png", "entity/sheep/sheep.png",
        "entity/sheep/sheep_fur.png", "entity/shulker/shulker.png", "entity/silverfish.png",
        "entity/skeleton/skeleton.png", "entity/skeleton/stray.png", "entity/skeleton/stray_overlay.png",
        "entity/skeleton/wither_skeleton.png", "entity/slime/magmacube.png", "entity/slime/slime.png",
        "entity/sniffer/sniffer.png", "entity/snow_golem.png", "entity/spider/cave_spider.png",
        "entity/spider/spider.png", "entity/spider/spider_eyes.png", "entity/squid/glow_squid.png",
        "entity/squid/squid.png", "entity/strider/strider.png", "entity/tadpole/tadpole.png",
        "entity/turtle/big_sea_turtle.png", "entity/villager/villager.png", "entity/wandering_trader.png",
        "entity/warden/warden.png", "entity/witch.png", "entity/wither/wither.png", "entity/wolf/wolf.png",
        "entity/zombie/drowned.png", "entity/zombie/drowned_outer_layer.png", "entity/zombie/husk.png",
        "entity/zombie/zombie.png", "entity/zombie_villager/zombie_villager.png"
    ]
    let professions = ["farmer", "fisherman", "shepherd", "fletcher", "librarian", "cartographer",
                       "cleric", "armorer", "weaponsmith", "toolsmith", "butcher", "leatherworker",
                       "mason", "nitwit"].map { "entity/villager/profession/\($0).png" }
    return (base + professions).sorted()
}

private func buildEntityTexture(path: String, materials: [Material: RGBA]) -> RGBA {
    let dimensions = entityDimensions(for: path)
    let material = materials[entityMaterial(for: path)]!
    let overlay = path.contains("eyes") || path.contains("outer_layer") || path.contains("overlay") ||
        path.contains("pattern") || path.contains("/profession/")
    guard overlay else {
        return materialImage(width: dimensions.0, height: dimensions.1, source: material,
                             key: "entity/\(path)")
    }
    var image = blankImage(width: dimensions.0, height: dimensions.1)
    let seed = fnv1a(path)
    let period = path.contains("eyes") ? 7 : 5
    for y in 0..<dimensions.1 {
        for x in 0..<dimensions.0 where (x &* 5 &+ y &* 3 &+ Int(seed & 31)) % period == 0 {
            paintMaterial(&image, source: material, key: "entity-overlay/\(path)/\(x)/\(y)",
                          x: x, y: y, width: 1, height: 1, alpha: path.contains("eyes") ? 255 : 150,
                          brightness: path.contains("eyes") ? 1.25 : 1)
        }
    }
    return image
}

private func buildSun(materials: [Material: RGBA]) -> RGBA {
    var image = blankImage(width: 64, height: 64)
    let source = materials[.lava]!
    for y in 0..<64 {
        for x in 0..<64 {
            let dx = x - 31, dy = y - 31
            if dx * dx + dy * dy <= 26 * 26 {
                paintMaterial(&image, source: source, key: "sun/\(x)/\(y)", x: x, y: y,
                              width: 1, height: 1, brightness: 1.22)
            }
        }
    }
    return image
}

private func buildMoonPhases(materials: [Material: RGBA]) -> RGBA {
    var image = blankImage(width: 256, height: 128)
    let source = materials[.ice]!
    let phases = [1.0, 0.70, 0.42, 0.18, 0.0, 0.18, 0.42, 0.70]
    for (index, phase) in phases.enumerated() {
        let originX = (index % 4) * 64
        let originY = (index / 4) * 64
        for y in 0..<64 {
            for x in 0..<64 {
                let dx = x - 31, dy = y - 31
                guard dx * dx + dy * dy <= 25 * 25 else { continue }
                let lit = phase == 0 ? false : Double(x) / 63 <= phase
                guard lit else { continue }
                paintMaterial(&image, source: source, key: "moon/\(index)/\(x)/\(y)",
                              x: originX + x, y: originY + y, width: 1, height: 1,
                              brightness: 0.95)
            }
        }
    }
    return image
}

private func writeImage(_ image: RGBA, relativePath: String, stage: URL) throws {
    let path = stage.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encodePNG(image, to: path)
}


private func writeText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

private func normalizeTimes(in root: URL) throws {
    let manager = FileManager.default
    for file in try regularFiles(in: root) {
        try manager.setAttributes([.modificationDate: fixedBuildDate], ofItemAtPath: file.path)
    }
}

private func build(_ options: Options) throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("elysium-kubikos-theme-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: temporary) }
    let unity = temporary.appendingPathComponent("unity", isDirectory: true)
    let stage = temporary.appendingPathComponent("stage", isDirectory: true)
    try manager.createDirectory(at: unity, withIntermediateDirectories: true)
    try manager.createDirectory(at: stage, withIntermediateDirectories: true)
    _ = try run("/usr/bin/tar", ["-xzf", options.unityPackage.path, "-C", unity.path])

    let materials = try loadKUBIKOSMaterials(from: unity)

    let tileRecords = try decodeTileRecords(try run(options.registryExport.path, ["--tile-rgba"]))
    for (name, mask) in tileRecords.sorted(by: { $0.0 < $1.0 }) {
        let source = try materials[material(for: name, fallback: .stone)].map { $0 } ?? {
            throw BuildError.invalid("missing material for tile \(name)")
        }()
        let image = materialized(scaleNearest(mask, to: 64), with: source, key: "tile/\(name)")
        // Native Elysium tile layers are the atlas authority.  The matching conventional block
        // path is emitted too so user-pack tooling sees a complete one-for-one block surface.
        try writeImage(image, relativePath: "assets/elysium/textures/tiles/\(name).png", stage: stage)
        try writeImage(image, relativePath: "assets/minecraft/textures/block/\(name).png", stage: stage)
    }
    // Every direct item receives an explicit KUBIKOS icon from the frozen item silhouette export.
    // Block-backed items are resolved from the complete native tile atlas above.
    let itemRecords = try decodeItemRecords(try run(options.registryExport.path, ["--item-rgba"]))
    let itemManifest = try decodeItemManifest(try run(options.registryExport.path, ["--item-manifest"]))
    var generatedDirectItems = 0
    for entry in itemManifest.filter({ $0.provider == "item" }).sorted(by: { $0.name < $1.name }) {
        guard let mask = itemRecords[entry.name] else {
            throw BuildError.invalid("missing item mask for \(entry.name)")
        }
        let source = try materials[material(forItem: entry.name)].map { $0 } ?? {
            throw BuildError.invalid("missing material for item \(entry.name)")
        }()
        try writeImage(materialized(scaleNearest(mask, to: 64), with: source, key: "item/\(entry.name)"),
                       relativePath: "assets/minecraft/textures/item/\(entry.name).png", stage: stage)
        generatedDirectItems += 1
    }
    // Generate every entity texture contract directly from KUBIKOS material swatches.  These
    // include the legacy path names consumed by the native models; they are generated independently
    // instead of being copied from another pack or variant directory.
    for path in entityPaths() {
        try writeImage(buildEntityTexture(path: path, materials: materials),
                       relativePath: "assets/minecraft/textures/\(path)", stage: stage)
    }
    try writeImage(materialImage(width: 64, height: 64, source: materials[.item]!,
                                 key: "native/entity-fallback"),
                   relativePath: "assets/elysium/textures/entity/fallback.png", stage: stage)

    // The old renderer consumes three legacy HUD sheets plus a closed set of container surfaces.
    // Their pixel geometry is authored below from primitives, and every pixel comes from a KUBIKOS
    // material swatch.  No imported GUI raster is involved.
    try writeImage(buildHUDIcons(materials: materials),
                   relativePath: "assets/minecraft/textures/gui/icons.png", stage: stage)
    try writeImage(buildWidgets(materials: materials),
                   relativePath: "assets/minecraft/textures/gui/widgets.png", stage: stage)
    try writeImage(materialImage(width: 16, height: 16, source: materials[.stone]!,
                                 key: "gui/options-background"),
                   relativePath: "assets/minecraft/textures/gui/options_background.png", stage: stage)
    let containerNames = ["inventory", "generic_54", "crafting_table", "furnace", "brewing_stand",
                          "enchanting_table", "anvil", "hopper", "dispenser", "shulker_box",
                          "grindstone", "stonecutter", "smithing", "cartography_table", "beacon", "horse"]
    for name in containerNames {
        try writeImage(buildContainer(name, materials: materials),
                       relativePath: "assets/minecraft/textures/gui/container/\(name).png", stage: stage)
    }
    try writeImage(buildFont(materials: materials),
                   relativePath: "assets/minecraft/textures/font/ascii.png", stage: stage)

    // The native sky renderer takes one sun and a 4×2 moon sheet.  Generate both from KUBIKOS
    // material samples so the themed sky has no dependency on an external texture layout.
    try writeImage(buildSun(materials: materials),
                   relativePath: "assets/minecraft/textures/environment/sun.png", stage: stage)
    try writeImage(buildMoonPhases(materials: materials),
                   relativePath: "assets/minecraft/textures/environment/moon_phases.png", stage: stage)

    // Title assets are Elysium-owned product images. Their semantic shape and alpha are retained,
    // while their color comes entirely from the KUBIKOS material family.
    try writeImage(materialized(try decodePNG(options.titleBackground), with: materials[.grass]!,
                                key: "title/background"),
                   relativePath: "assets/elysium/textures/title/background.png", stage: stage)
    try writeImage(materialized(try decodePNG(options.titleLogo), with: materials[.crystal]!,
                                key: "title/logo"),
                   relativePath: "assets/elysium/textures/title/logo.png", stage: stage)

    try writeText("""
    {"pack":{"pack_format":75,"description":"Elysium KUBIKOS Cubic World alternate visual style"}}
    """ + "\n", to: stage.appendingPathComponent("pack.mcmeta"))
    try writeText("""
    KUBIKOS Cubic World for Elysium

    This embedded alternate resource pack is generated deterministically from the locally licensed
    KUBIKOS - Cube World diffuse materials, Elysium-owned registry masks, and Elysium-owned title
    surfaces. It does not embed or import another resource-pack archive.

    Source product: KUBIKOS - Cube World by ANIMMAL Game Assets
    Fab listing: 7bbf72cf-03bd-458f-9a74-1ab85bd1f2e5
    Source archive SHA-256: 4eb52b835610aca19a79681a81a744fc9a69b8414426e2f18a270e20f229e24e

    The source asset is not redistributed as a standalone archive. Keep this pack embedded in an
    Elysium project distributed under the applicable Fab Standard License.
    """ + "\n", to: stage.appendingPathComponent("LICENSE.txt"))
    try writeText("""
    KUBIKOS Cubic World visual-style build manifest
    source=KUBIKOS - Cube World by ANIMMAL Game Assets
    source_archive_sha256=4eb52b835610aca19a79681a81a744fc9a69b8414426e2f18a270e20f229e24e
    conversion=deterministic KUBIKOS material synthesis; no AI generation
    third_party_resource_pack_inputs=0
    direct_elysium_tile_overrides=\(tileRecords.count)
    direct_minecraft_block_textures=\(tileRecords.count)
    direct_entity_textures=\(entityPaths().count)
    generated_legacy_entity_paths=5
    generated_gui_surfaces=19
    generated_font=assets/minecraft/textures/font/ascii.png
    generated_environment_surfaces=2
    native_entity_fallback=assets/elysium/textures/entity/fallback.png
    native_title_background=assets/elysium/textures/title/background.png
    native_title_logo=assets/elysium/textures/title/logo.png
    generated_direct_item_icons=\(generatedDirectItems)
    """ + "\n", to: stage.appendingPathComponent("CREDITS.txt"))

    try normalizeTimes(in: stage)
    let outputDirectory = options.output.deletingLastPathComponent()
    try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let temporaryOutput = outputDirectory.appendingPathComponent(
        ".\(options.output.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryOutput) }
    let paths = try regularFiles(in: stage).map { try relativePath($0, root: stage) }.sorted()
    _ = try run("/usr/bin/zip", ["-X", "-q", temporaryOutput.path, "-@"], in: stage,
                input: Data((paths.joined(separator: "\n") + "\n").utf8))
    _ = try run("/usr/bin/unzip", ["-tq", temporaryOutput.path])
    let hashOutput = try run("/usr/bin/shasum", ["-a", "256", temporaryOutput.path])
    let hash = hashOutput.firstIndex(of: 0x20).map {
        String(decoding: hashOutput[..<$0], as: UTF8.self)
    } ?? ""
    guard hash.count == 64 else { throw BuildError.invalid("could not hash output") }
    guard Darwin.rename(temporaryOutput.path, options.output.path) == 0 else {
        throw BuildError.invalid("could not atomically publish output: \(String(cString: strerror(errno)))")
    }
    print("KUBIKOS_THEME_BUILT archive=\(options.output.path) sha256=\(hash) tiles=\(tileRecords.count) direct_items=\(generatedDirectItems) entities=\(entityPaths().count) files=\(paths.count)")
}

do {
    try build(try parseOptions())
} catch {
    FileHandle.standardError.write(Data("build-kubikos-theme: \(error)\n".utf8))
    Foundation.exit(1)
}
