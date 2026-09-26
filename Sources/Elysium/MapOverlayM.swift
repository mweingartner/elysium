import Foundation
import ElysiumCore

private let mapUnknownColor = SIMD4<Float>(0.03, 0.035, 0.045, 0.72)

private func mapRGBA(_ rgb: Int, _ alpha: Float = 1) -> SIMD4<Float> {
    SIMD4<Float>(Float((rgb >> 16) & 255) / 255,
                 Float((rgb >> 8) & 255) / 255,
                 Float(rgb & 255) / 255,
                 alpha)
}

private func shadedMapColor(_ rgb: Int, height y: Int, sea: Int) -> SIMD4<Float> {
    let shade = Float(max(0.68, min(1.22, 0.92 + Double(y - sea) / 160)))
    let c = mapRGBA(rgb)
    return SIMD4<Float>(min(1, c.x * shade), min(1, c.y * shade), min(1, c.z * shade), 1)
}

/// Name-derived minimap material for one registered block. The string rules below run once
/// per block id, not once per map cell per frame; biome tints and height shading stay per cell.
/// The rule order is exactly the former per-cell order, so every block keeps its colour.
enum MapColorRule: Equatable {
    case water
    case lava
    case grass
    case foliage
    case shaded(Int)
}

func mapColorRule(id: Int, name: String, solid: Bool, lightEmit: Int) -> MapColorRule {
    if id == Int(B.water) { return .water }
    if id == Int(B.lava) { return .lava }
    if name == "grass_block" || name == "short_grass" || name == "tall_grass" || name == "fern" || name == "large_fern" {
        return .grass
    }
    if name.contains("leaves") || name.contains("azalea") { return .foliage }
    // Dimension-specific materials must win over generic substrings such as
    // "sand", "stone", and "stem" so Nether biomes remain distinguishable.
    if name == "soul_sand" || name == "soul_soil" { return .shaded(0x5b4b3b) }
    if name.contains("netherrack") || name.contains("crimson") { return .shaded(0x8a3030) }
    if name.contains("warped") { return .shaded(0x2f8f82) }
    if name.contains("basalt") || name.contains("blackstone") { return .shaded(0x3b3b42) }
    if name.contains("nether_brick") { return .shaded(0x4b1f28) }
    if name.contains("quartz") { return .shaded(0xd8d1c5) }
    if name.contains("end_stone") { return .shaded(0xdbd88a) }
    if name.contains("sand") || name.contains("sandstone") { return .shaded(0xd8c878) }
    if name.contains("snow") { return .shaded(0xf0f4f7) }
    if name.contains("ice") { return .shaded(0x9fd8f5) }
    if name.contains("dirt") || name.contains("mud") || name.contains("podzol") || name.contains("farmland") {
        return .shaded(0x7a5635)
    }
    if name.contains("stone") || name.contains("deepslate") || name.contains("ore") ||
        name.contains("andesite") || name.contains("diorite") || name.contains("granite") || name.contains("tuff") {
        return .shaded(0x858585)
    }
    if name.contains("planks") || name.contains("log") || name.contains("wood") || name.contains("stem") ||
        name.contains("hyphae") || name.contains("bamboo") {
        return .shaded(0x8a6236)
    }
    if name.contains("wool") || name.contains("concrete") || name.contains("terracotta") {
        for c in COLORS where name.hasPrefix(c + "_") {
            return .shaded(Int(COLOR_RGB[c] ?? 0xa0a0a0))
        }
    }
    if lightEmit > 0 { return .shaded(0xd0a65a) }
    return .shaded(solid ? 0x8a8a72 : 0x66885a)
}

/// Rules for every registered block, rebuilt only if the registry size changes.
private var mapColorRuleTable: [MapColorRule] = []

func mapColorRules() -> [MapColorRule] {
    if mapColorRuleTable.count != blockDefs.count {
        mapColorRuleTable = blockDefs.indices.map { id in
            let def = blockDefs[id]
            return mapColorRule(id: id, name: def.name, solid: def.solid, lightEmit: def.lightEmit)
        }
    }
    return mapColorRuleTable
}

private func mapColorForBlock(_ world: World, _ x: Int, _ z: Int,
                              referenceY: Int, rules: [MapColorRule]) -> SIMD4<Float> {
    guard let sample = mapColumnSample(world, x: x, z: z, referenceY: referenceY) else {
        return mapUnknownColor
    }
    let y = sample.y
    let id = sample.cell >> 4
    guard id > 0, id < blockDefs.count, id < rules.count else {
        return SIMD4<Float>(0.04, 0.05, 0.06, 1)
    }
    let sea = world.info.seaLevel
    switch rules[id] {
    case .water:
        return shadedMapColor(Int(BIOMES[world.biomeAt(x, y, z)]?.waterColor ?? 0x3f76e4), height: y, sea: sea)
    case .lava:
        return mapRGBA(0xe05a1a)
    case .grass:
        return shadedMapColor(Int(BIOMES[world.biomeAt(x, y, z)]?.grassColor ?? 0x91bd59), height: y, sea: sea)
    case .foliage:
        return shadedMapColor(Int(BIOMES[world.biomeAt(x, y, z)]?.foliageColor ?? 0x77ab2f), height: y, sea: sea)
    case .shaded(let rgb):
        return shadedMapColor(rgb, height: y, sea: sea)
    }
}

/// The sampled colour grid for one map view. A still view reuses it; any change to the sampled
/// block coordinates, reference height, or world recomputes it, and a periodic refresh picks up
/// block edits under an unchanged view within a few frames.
private struct MapColorGridKey: Equatable {
    let world: ObjectIdentifier
    let samples: Int
    let worldMinX: Double
    let worldMinZ: Double
    let step: Double
    let referenceY: Int
}
private var mapColorGridCache: (key: MapColorGridKey, colors: [SIMD4<Float>], age: Int)?
private let mapColorGridRefreshFrames = 10

private func mapColorGrid(world: World, samples: Int, worldMinX: Double, worldMinZ: Double,
                          step: Double, referenceY: Int) -> [SIMD4<Float>] {
    let key = MapColorGridKey(world: ObjectIdentifier(world), samples: samples, worldMinX: worldMinX,
                              worldMinZ: worldMinZ, step: step, referenceY: referenceY)
    if let cached = mapColorGridCache, cached.key == key, cached.age < mapColorGridRefreshFrames {
        mapColorGridCache = (key, cached.colors, cached.age + 1)
        return cached.colors
    }
    let rules = mapColorRules()
    var colors = [SIMD4<Float>]()
    colors.reserveCapacity(samples * samples)
    for row in 0..<samples {
        let z = Int((worldMinZ + (Double(row) + 0.5) * step).rounded(.down))
        for col in 0..<samples {
            let x = Int((worldMinX + (Double(col) + 0.5) * step).rounded(.down))
            colors.append(mapColorForBlock(world, x, z, referenceY: referenceY, rules: rules))
        }
    }
    mapColorGridCache = (key, colors, 0)
    return colors
}

func drawMapOverlay(_ ui: UIManager, _ game: GameCore,
                    rect: MapOverlayRect, viewport rawViewport: MapViewport,
                    expanded: Bool, bounds providedBounds: MapBlockBounds? = nil) {
    guard let player = game.player else { return }
    let cv = ui.cv
    let bounds = providedBounds ?? game.loadedMapBounds()
    let viewport = clampedMapViewport(rawViewport, bounds: bounds)
    let outer = rect.size
    guard outer >= 16 else { return }

    cv.setFill(expanded ? "rgba(2,4,8,0.72)" : "rgba(0,0,0,0.58)")
    cv.fillRect(rect.x - 2, rect.y - 2, outer + 4, outer + 4)
    cv.setFill("#141b22")
    cv.fillRect(rect.x, rect.y, outer, outer)

    let inset = expanded ? 5.0 : 3.0
    let innerX = rect.x + inset
    let innerY = rect.y + inset
    let inner = max(1, outer - inset * 2)
    let samples = max(8, min(Int(inner.rounded(.down)), expanded ? 220 : 96))
    let cellSize = inner / Double(samples)
    let worldMinX = viewport.centerX - viewport.spanBlocks / 2
    let worldMinZ = viewport.centerZ - viewport.spanBlocks / 2
    let step = viewport.spanBlocks / Double(samples)
    let worldMinY = game.world.info.minY
    let worldMaxY = worldMinY + game.world.info.height - 1
    let boundedPlayerY = player.y.isFinite
        ? min(Double(worldMaxY), max(Double(worldMinY), player.y))
        : Double(game.world.info.seaLevel)
    let referenceY = Int(boundedPlayerY.rounded(.down))

    let world = game.world
    let colors = mapColorGrid(world: world, samples: samples, worldMinX: worldMinX, worldMinZ: worldMinZ,
                              step: step, referenceY: referenceY)
    for row in 0..<samples {
        let y = innerY + Double(row) * cellSize
        // Adjacent cells with an identical colour are one quad: same pixels, far fewer vertices.
        var col = 0
        while col < samples {
            let color = colors[row * samples + col]
            var end = col + 1
            while end < samples, colors[row * samples + end] == color { end += 1 }
            cv.fillStyle = color
            cv.fillRect(innerX + Double(col) * cellSize, y, Double(end - col) * cellSize + 0.15, cellSize + 0.15)
            col = end
        }
    }

    cv.setStroke(expanded ? "rgba(255,255,255,0.78)" : "rgba(255,255,255,0.55)")
    cv.strokeRect(rect.x, rect.y, outer, outer, expanded ? 2 : 1)
    if expanded {
        cv.setStroke("rgba(90,140,180,0.42)")
        cv.strokeRect(innerX, innerY, inner, inner)
    }

    let pos = mapScreenPoint(forWorldX: player.x, worldZ: player.z, rect: rect, viewport: viewport)
    if pos.x >= innerX, pos.x <= innerX + inner, pos.y >= innerY, pos.y <= innerY + inner {
        let marker = expanded ? 4.0 : 3.0
        cv.setFill("#ffffff")
        cv.fillRect(pos.x - marker / 2, pos.y - marker / 2, marker, marker)
        cv.setStroke("#202020")
        cv.strokeRect(pos.x - marker / 2, pos.y - marker / 2, marker, marker)
        let dx = detSin(player.yaw)
        let dz = detCos(player.yaw)
        cv.setStroke("#ffffff")
        cv.line(pos.x, pos.y, pos.x + dx * (expanded ? 10 : 6), pos.y + dz * (expanded ? 10 : 6), expanded ? 2 : 1)
    }
}
