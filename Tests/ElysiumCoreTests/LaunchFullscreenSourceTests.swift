import Foundation
import XCTest

final class LaunchFullscreenSourceTests: XCTestCase {
    func testLaunchPublishesWindowedAfterTitleSetupAndPreservesUserFullscreen() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = try String(contentsOf:
            testFile.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/Elysium/main.swift"),
            encoding: .utf8)
        let inputRouter = try String(contentsOf:
            testFile.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Elysium/AppInputRouterM.swift"),
            encoding: .utf8)

        XCTAssertFalse(source.contains("applyLaunchFullscreen"))
        XCTAssertFalse(source.contains("ElysiumLaunchFullscreenState"))
        XCTAssertFalse(source.contains("window.alphaValue = 0"))
        XCTAssertTrue(source.contains("window.collectionBehavior.insert(.fullScreenPrimary)"))
        XCTAssertTrue(source.contains("window.collectionBehavior.insert(.moveToActiveSpace)"))
        XCTAssertTrue(source.contains("window.orderFront(nil)"))
        XCTAssertFalse(source.contains("window.orderFrontRegardless()"))
        let reveal = try XCTUnwrap(source.range(of: "revealLaunchWindowed()"))
        XCTAssertTrue(source.contains("guard NSApp.isActive, window.isVisible"))
        XCTAssertTrue(source.contains("window.occlusionState.contains(.visible)"))
        XCTAssertTrue(source.contains(
            "let unlimited = game.hasWorld() && game.settings.maxFps >= 250"))
        XCTAssertTrue(source.contains("gameView.preferredFramesPerSecond = game.hasWorld()"))
        XCTAssertTrue(inputRouter.contains("view.window?.toggleFullScreen(nil)"))
        XCTAssertTrue(source.contains("kind: .windowedFallback"))
        let title = try XCTUnwrap(source.range(of: "ui.open(TitleScreen(), game)"))
        XCTAssertLessThan(title.lowerBound, reveal.lowerBound)
    }
}
