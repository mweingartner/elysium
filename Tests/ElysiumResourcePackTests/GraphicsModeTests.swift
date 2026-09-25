import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class GraphicsModeTests: XCTestCase {
    func testSupportedCycleIncludesTrueRayTracedModeAndReturnsToOff() {
        var mode = GraphicsMode.standard
        for expected in [GraphicsMode.ultra, .rayTraced, .standard] {
            mode = mode.next(rayTracingSupported: true)
            XCTAssertEqual(mode, expected)
            XCTAssertEqual(GraphicsMode(shader: mode.shader), mode)
        }
    }

    func testUnsupportedDeviceSkipsRayTracingWithoutLyingAboutStoredRequest() {
        XCTAssertEqual(GraphicsMode.standard.next(rayTracingSupported: false), .ultra)
        XCTAssertEqual(GraphicsMode.ultra.next(rayTracingSupported: false), .standard)
        XCTAssertEqual(GraphicsMode.rayTraced.effective(rayTracingSupported: false), .ultra)
        XCTAssertEqual(GraphicsMode.rayTraced.shader, "raytraced")
        XCTAssertTrue(GraphicsMode.rayTraced.buttonLabel(rayTracingSupported: false).contains("UNAVAILABLE"))
        XCTAssertEqual(GraphicsMode.rayTraced.next(rayTracingSupported: false), .standard)
    }

    func testLegacyGraphicsPreferencesRetainTheirMeaning() {
        XCTAssertEqual(GraphicsMode(shader: nil), .standard)
        XCTAssertEqual(GraphicsMode(shader: "ultra"), .ultra)
        XCTAssertEqual(GraphicsMode(shader: "legacy-pack.zip"), .standard)
        XCTAssertEqual(GraphicsMode.rayTraced.effective(rayTracingSupported: true), .rayTraced)
    }

    func testRayTracingPreferenceRoundTripsThroughRealIsolatedSettingsStore() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-graphics-preference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSettingsStore(directoryURL: root)
        var settings = Settings()
        settings.shader = GraphicsMode.rayTraced.shader
        try store.persistSettings(settings).get()
        let loaded = try store.loadSettings().get()
        XCTAssertEqual(loaded.shader, "raytraced")
        XCTAssertEqual(GraphicsMode(shader: loaded.shader), .rayTraced)
        XCTAssertEqual(loaded.clouds, settings.clouds)
        XCTAssertEqual(loaded.renderDistance, settings.renderDistance)
    }
}
