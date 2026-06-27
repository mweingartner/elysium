import Foundation

public let MAP_MIN_VIEW_BLOCKS = 100.0
public let MAP_DEFAULT_VIEW_BLOCKS = 256.0
public let MAP_MAX_UNBOUNDED_VIEW_BLOCKS = 4096.0
public let MAP_ZOOM_FACTOR = 2.0
public let MAP_MARGIN = 6.0
public let MAP_MINIMAP_MAX_GUI_SIZE = 128.0
public let MAP_MINIMAP_MIN_GUI_SIZE = 64.0

public struct MapOverlayRect: Equatable {
    public let x: Double
    public let y: Double
    public let size: Double

    public init(x: Double, y: Double, size: Double) {
        self.x = x
        self.y = y
        self.size = size
    }

    public var midX: Double { x + size / 2 }
    public var midY: Double { y + size / 2 }
}

public struct MapBlockBounds: Equatable {
    public let minX: Int
    public let minZ: Int
    public let maxX: Int
    public let maxZ: Int

    public init(minX: Int, minZ: Int, maxX: Int, maxZ: Int) {
        self.minX = min(minX, maxX)
        self.minZ = min(minZ, maxZ)
        self.maxX = max(minX, maxX)
        self.maxZ = max(minZ, maxZ)
    }

    public var spanX: Double { Double(maxX - minX + 1) }
    public var spanZ: Double { Double(maxZ - minZ + 1) }
    public var squareSpan: Double { max(spanX, spanZ) }
    public var midX: Double { (Double(minX) + Double(maxX) + 1) / 2 }
    public var midZ: Double { (Double(minZ) + Double(maxZ) + 1) / 2 }
}

public struct MapViewport: Equatable {
    public let centerX: Double
    public let centerZ: Double
    public let spanBlocks: Double

    public init(centerX: Double, centerZ: Double, spanBlocks: Double) {
        self.centerX = centerX
        self.centerZ = centerZ
        self.spanBlocks = spanBlocks
    }
}

public func mapBoundsForLoadedChunks(_ chunks: [(cx: Int, cz: Int)]) -> MapBlockBounds? {
    guard let first = chunks.first else { return nil }
    var minX = first.cx * CHUNK_W
    var maxX = minX + CHUNK_W - 1
    var minZ = first.cz * CHUNK_W
    var maxZ = minZ + CHUNK_W - 1
    for c in chunks.dropFirst() {
        let x0 = c.cx * CHUNK_W
        let z0 = c.cz * CHUNK_W
        minX = min(minX, x0)
        maxX = max(maxX, x0 + CHUNK_W - 1)
        minZ = min(minZ, z0)
        maxZ = max(maxZ, z0 + CHUNK_W - 1)
    }
    return MapBlockBounds(minX: minX, minZ: minZ, maxX: maxX, maxZ: maxZ)
}

public func mapMinimapRect(screenWidth: Double, screenHeight: Double,
                           hotbarCenterX: Double, hotbarHalfWidth: Double,
                           hotbarTopY: Double, margin: Double = MAP_MARGIN) -> MapOverlayRect {
    let hotbarRight = hotbarCenterX + hotbarHalfWidth
    let rightSpace = max(0, screenWidth - hotbarRight - margin * 2)
    let verticalSpace = max(0, hotbarTopY - margin * 2)
    var size = min(MAP_MINIMAP_MAX_GUI_SIZE, rightSpace, verticalSpace).rounded(.down)
    if size < MAP_MINIMAP_MIN_GUI_SIZE {
        size = min(MAP_MINIMAP_MIN_GUI_SIZE, max(32, min(screenWidth - margin * 2, verticalSpace))).rounded(.down)
    }
    let x = max(0, screenWidth - size).rounded(.down)
    let y = max(0, screenHeight - size).rounded(.down)
    return MapOverlayRect(x: x, y: y, size: size)
}

public func mapExpandedRect(screenWidth: Double, screenHeight: Double,
                            margin: Double = 16) -> MapOverlayRect {
    let available = max(MAP_MINIMAP_MIN_GUI_SIZE, min(screenWidth - margin * 2, screenHeight - margin * 2))
    let size = max(MAP_MINIMAP_MIN_GUI_SIZE, (available * 0.88).rounded(.down))
    return MapOverlayRect(x: ((screenWidth - size) / 2).rounded(.down),
                          y: ((screenHeight - size) / 2).rounded(.down),
                          size: size)
}

public func mapMaxZoomOutSpan(for bounds: MapBlockBounds?) -> Double {
    guard let bounds else { return MAP_MAX_UNBOUNDED_VIEW_BLOCKS }
    return max(MAP_DEFAULT_VIEW_BLOCKS, MAP_MIN_VIEW_BLOCKS, bounds.squareSpan)
}

public func clampedMapSpan(_ span: Double, bounds: MapBlockBounds?) -> Double {
    let clean = span.isFinite ? span : MAP_DEFAULT_VIEW_BLOCKS
    return min(max(clean, MAP_MIN_VIEW_BLOCKS), mapMaxZoomOutSpan(for: bounds))
}

public func mapZoomedSpan(current: Double, zoomIn: Bool, bounds: MapBlockBounds?) -> Double {
    let span = clampedMapSpan(current, bounds: bounds)
    if zoomIn {
        return max(MAP_MIN_VIEW_BLOCKS, span / MAP_ZOOM_FACTOR)
    }
    let maxSpan = mapMaxZoomOutSpan(for: bounds)
    let next = span * MAP_ZOOM_FACTOR
    return next >= maxSpan ? maxSpan : next
}

private func clampMapCenterAxis(_ center: Double, span: Double, minBlock: Int, maxBlock: Int) -> Double {
    let minEdge = Double(minBlock)
    let maxEdge = Double(maxBlock) + 1
    let minCenter = minEdge + span / 2
    let maxCenter = maxEdge - span / 2
    if minCenter > maxCenter { return (minEdge + maxEdge) / 2 }
    return min(max(center, minCenter), maxCenter)
}

public func clampedMapViewport(_ viewport: MapViewport, bounds: MapBlockBounds?) -> MapViewport {
    let span = clampedMapSpan(viewport.spanBlocks, bounds: bounds)
    guard let bounds else {
        return MapViewport(centerX: viewport.centerX, centerZ: viewport.centerZ, spanBlocks: span)
    }
    return MapViewport(centerX: clampMapCenterAxis(viewport.centerX, span: span, minBlock: bounds.minX, maxBlock: bounds.maxX),
                       centerZ: clampMapCenterAxis(viewport.centerZ, span: span, minBlock: bounds.minZ, maxBlock: bounds.maxZ),
                       spanBlocks: span)
}

public func mapViewportCenteredOnPlayer(playerX: Double, playerZ: Double,
                                        span: Double, bounds: MapBlockBounds?) -> MapViewport {
    clampedMapViewport(MapViewport(centerX: playerX, centerZ: playerZ, spanBlocks: span), bounds: bounds)
}

public func mapWorldPoint(forScreenX screenX: Double, screenY: Double,
                          rect: MapOverlayRect, viewport: MapViewport) -> (x: Double, z: Double) {
    let relX = (screenX - rect.midX) / rect.size
    let relZ = (screenY - rect.midY) / rect.size
    return (viewport.centerX + relX * viewport.spanBlocks,
            viewport.centerZ + relZ * viewport.spanBlocks)
}

public func mapScreenPoint(forWorldX worldX: Double, worldZ: Double,
                           rect: MapOverlayRect, viewport: MapViewport) -> (x: Double, y: Double) {
    let relX = (worldX - viewport.centerX) / viewport.spanBlocks
    let relZ = (worldZ - viewport.centerZ) / viewport.spanBlocks
    return (rect.midX + relX * rect.size, rect.midY + relZ * rect.size)
}

public func mapZoomedViewport(_ viewport: MapViewport, zoomIn: Bool,
                              focusScreenX: Double, focusScreenY: Double,
                              rect: MapOverlayRect, bounds: MapBlockBounds?) -> MapViewport {
    let before = mapWorldPoint(forScreenX: focusScreenX, screenY: focusScreenY, rect: rect, viewport: viewport)
    let nextSpan = mapZoomedSpan(current: viewport.spanBlocks, zoomIn: zoomIn, bounds: bounds)
    let relX = (focusScreenX - rect.midX) / rect.size
    let relZ = (focusScreenY - rect.midY) / rect.size
    let next = MapViewport(centerX: before.x - relX * nextSpan,
                           centerZ: before.z - relZ * nextSpan,
                           spanBlocks: nextSpan)
    return clampedMapViewport(next, bounds: bounds)
}

public func mapPannedViewport(_ viewport: MapViewport, screenDX: Double, screenDY: Double,
                              rect: MapOverlayRect, bounds: MapBlockBounds?) -> MapViewport {
    let blocksPerPixel = viewport.spanBlocks / max(1, rect.size)
    let next = MapViewport(centerX: viewport.centerX - screenDX * blocksPerPixel,
                           centerZ: viewport.centerZ - screenDY * blocksPerPixel,
                           spanBlocks: viewport.spanBlocks)
    return clampedMapViewport(next, bounds: bounds)
}
