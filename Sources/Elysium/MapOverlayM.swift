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

private func mapColorForBlock(_ world: World, _ x: Int, _ z: Int) -> SIMD4<Float> {
    guard world.isLoadedAt(x, z) else { return mapUnknownColor }
    let y = world.heightAt(x, z)
    guard y >= world.info.minY, y < world.info.minY + world.info.height else {
        return SIMD4<Float>(0.04, 0.05, 0.06, 1)
    }
    let cell = world.getBlock(x, y, z)
    let id = cell >> 4
    guard id > 0, id < blockDefs.count else {
        return SIMD4<Float>(0.04, 0.05, 0.06, 1)
    }

    let def = blockDefs[id]
    let name = def.name
    let biome = BIOMES[world.biomeAt(x, y, z)]
    if id == Int(B.water) { return shadedMapColor(Int(biome?.waterColor ?? 0x3f76e4), height: y, sea: world.info.seaLevel) }
    if id == Int(B.lava) { return mapRGBA(0xe05a1a) }
    if name == "grass_block" || name == "short_grass" || name == "tall_grass" || name == "fern" || name == "large_fern" {
        return shadedMapColor(Int(biome?.grassColor ?? 0x91bd59), height: y, sea: world.info.seaLevel)
    }
    if name.contains("leaves") || name.contains("azalea") {
        return shadedMapColor(Int(biome?.foliageColor ?? 0x77ab2f), height: y, sea: world.info.seaLevel)
    }
    if name.contains("sand") || name.contains("sandstone") { return shadedMapColor(0xd8c878, height: y, sea: world.info.seaLevel) }
    if name.contains("snow") { return shadedMapColor(0xf0f4f7, height: y, sea: world.info.seaLevel) }
    if name.contains("ice") { return shadedMapColor(0x9fd8f5, height: y, sea: world.info.seaLevel) }
    if name.contains("dirt") || name.contains("mud") || name.contains("podzol") || name.contains("farmland") {
        return shadedMapColor(0x7a5635, height: y, sea: world.info.seaLevel)
    }
    if name.contains("stone") || name.contains("deepslate") || name.contains("ore") ||
        name.contains("andesite") || name.contains("diorite") || name.contains("granite") || name.contains("tuff") {
        return shadedMapColor(0x858585, height: y, sea: world.info.seaLevel)
    }
    if name.contains("planks") || name.contains("log") || name.contains("wood") || name.contains("stem") ||
        name.contains("hyphae") || name.contains("bamboo") {
        return shadedMapColor(0x8a6236, height: y, sea: world.info.seaLevel)
    }
    if name.contains("netherrack") || name.contains("crimson") { return shadedMapColor(0x8a3030, height: y, sea: world.info.seaLevel) }
    if name.contains("warped") { return shadedMapColor(0x2f8f82, height: y, sea: world.info.seaLevel) }
    if name.contains("end_stone") { return shadedMapColor(0xdbd88a, height: y, sea: world.info.seaLevel) }
    if name.contains("wool") || name.contains("concrete") || name.contains("terracotta") {
        for c in COLORS where name.hasPrefix(c + "_") {
            return shadedMapColor(Int(COLOR_RGB[c] ?? 0xa0a0a0), height: y, sea: world.info.seaLevel)
        }
    }
    if def.lightEmit > 0 { return shadedMapColor(0xd0a65a, height: y, sea: world.info.seaLevel) }
    return shadedMapColor(def.solid ? 0x8a8a72 : 0x66885a, height: y, sea: world.info.seaLevel)
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

    for row in 0..<samples {
        let z = Int((worldMinZ + (Double(row) + 0.5) * step).rounded(.down))
        let y = innerY + Double(row) * cellSize
        for col in 0..<samples {
            let x = Int((worldMinX + (Double(col) + 0.5) * step).rounded(.down))
            cv.fillStyle = mapColorForBlock(game.world, x, z)
            cv.fillRect(innerX + Double(col) * cellSize, y, cellSize + 0.15, cellSize + 0.15)
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
