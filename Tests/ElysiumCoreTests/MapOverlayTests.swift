import XCTest
@testable import ElysiumCore

final class MapOverlayTests: XCTestCase {
    func testDefaultMinimapSizeModeIsMediumAndCyclesThroughThreeSizes() {
        XCTAssertEqual(MAP_DEFAULT_MINIMAP_SIZE_MODE, .medium)
        XCTAssertEqual(cycledMapMinimapSizeMode(.medium, larger: true), .large)
        XCTAssertEqual(cycledMapMinimapSizeMode(.large, larger: true), .small)
        XCTAssertEqual(cycledMapMinimapSizeMode(.medium, larger: false), .small)
        XCTAssertEqual(cycledMapMinimapSizeMode(.small, larger: false), .large)
    }

    func testMinimapRectsUseThreeSizesPinnedToBottomRight() {
        let large = mapMinimapRect(screenWidth: 380, screenHeight: 240,
                                   hotbarCenterX: 190, hotbarHalfWidth: 91,
                                   hotbarTopY: 218,
                                   sizeMode: .large)
        let medium = mapMinimapRect(screenWidth: 380, screenHeight: 240,
                                    hotbarCenterX: 190, hotbarHalfWidth: 91,
                                    hotbarTopY: 218,
                                    sizeMode: .medium)
        let defaulted = mapMinimapRect(screenWidth: 380, screenHeight: 240,
                                       hotbarCenterX: 190, hotbarHalfWidth: 91,
                                       hotbarTopY: 218)
        let small = mapMinimapRect(screenWidth: 380, screenHeight: 240,
                                   hotbarCenterX: 190, hotbarHalfWidth: 91,
                                   hotbarTopY: 218,
                                   sizeMode: .small)

        XCTAssertEqual(large.size, 87)
        XCTAssertEqual(medium.size, 65)
        XCTAssertEqual(defaulted, medium)
        XCTAssertEqual(small.size, 43)
        for rect in [large, medium, small] {
            XCTAssertEqual(rect.x, 380 - rect.size)
            XCTAssertEqual(rect.y, 240 - rect.size)
            XCTAssertGreaterThanOrEqual(rect.x, 190 + 91 + MAP_MARGIN)
        }
    }

    func testLoadedChunkBoundsCoverAllLoadedChunkEdges() {
        let bounds = mapBoundsForLoadedChunks([(cx: 0, cz: 0), (cx: 2, cz: -1), (cx: -1, cz: 3)])

        XCTAssertEqual(bounds, MapBlockBounds(minX: -16, minZ: -16, maxX: 47, maxZ: 63))
        XCTAssertEqual(bounds?.squareSpan, 80)
    }

    func testMapZoomClampsToHundredBlockMinimumAndLoadedBoundsMaximum() {
        let bounds = MapBlockBounds(minX: -512, minZ: -64, maxX: 511, maxZ: 63)

        XCTAssertEqual(mapZoomedSpan(current: 128, zoomIn: true, bounds: bounds), MAP_MIN_VIEW_BLOCKS)
        XCTAssertEqual(mapZoomedSpan(current: 512, zoomIn: false, bounds: bounds), 1024)
        XCTAssertEqual(mapZoomedSpan(current: 1024, zoomIn: false, bounds: bounds), 1024)
    }

    func testPlayerCenteredViewportClampsOnlyWhenZoomedPastBounds() {
        let bounds = MapBlockBounds(minX: 0, minZ: 0, maxX: 255, maxZ: 255)
        let view = mapViewportCenteredOnPlayer(playerX: 220, playerZ: 48, span: 100, bounds: bounds)

        XCTAssertEqual(view.centerX, 206, accuracy: 1e-12)
        XCTAssertEqual(view.centerZ, 50, accuracy: 1e-12)
        XCTAssertEqual(view.spanBlocks, 100, accuracy: 1e-12)
    }

    func testExpandedZoomKeepsCursorWorldPointStableAwayFromBounds() {
        let bounds = MapBlockBounds(minX: -4096, minZ: -4096, maxX: 4095, maxZ: 4095)
        let rect = MapOverlayRect(x: 10, y: 20, size: 200)
        let view = MapViewport(centerX: 0, centerZ: 0, spanBlocks: 400)
        let focusBefore = mapWorldPoint(forScreenX: 160, screenY: 90, rect: rect, viewport: view)

        let zoomed = mapZoomedViewport(view, zoomIn: true, focusScreenX: 160, focusScreenY: 90,
                                       rect: rect, bounds: bounds)
        let focusAfter = mapWorldPoint(forScreenX: 160, screenY: 90, rect: rect, viewport: zoomed)

        XCTAssertEqual(zoomed.spanBlocks, 200)
        XCTAssertEqual(focusAfter.x, focusBefore.x, accuracy: 1e-12)
        XCTAssertEqual(focusAfter.z, focusBefore.z, accuracy: 1e-12)
    }

    func testExpandedPanUsesScreenDistanceAndClampsToLoadedBounds() {
        let bounds = MapBlockBounds(minX: 0, minZ: 0, maxX: 255, maxZ: 255)
        let rect = MapOverlayRect(x: 0, y: 0, size: 100)
        let view = MapViewport(centerX: 128, centerZ: 128, spanBlocks: 100)

        let panned = mapPannedViewport(view, screenDX: 25, screenDY: -50, rect: rect, bounds: bounds)
        XCTAssertEqual(panned.centerX, 103, accuracy: 1e-12)
        XCTAssertEqual(panned.centerZ, 178, accuracy: 1e-12)

        let clamped = mapPannedViewport(view, screenDX: 10_000, screenDY: 10_000, rect: rect, bounds: bounds)
        XCTAssertEqual(clamped.centerX, 50, accuracy: 1e-12)
        XCTAssertEqual(clamped.centerZ, 50, accuracy: 1e-12)
    }
}
