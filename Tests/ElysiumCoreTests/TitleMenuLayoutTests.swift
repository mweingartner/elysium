import Foundation
import XCTest
@testable import ElysiumCore

final class TitleMenuLayoutTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCanonicalHeroMetadataAndRepresentativeGeometry() throws {
        let png = try Data(contentsOf: repositoryRoot.appendingPathComponent("packaging/title-bg.png"))
        XCTAssertGreaterThanOrEqual(png.count, 24)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        func u32(_ offset: Int) -> UInt32 {
            png[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        XCTAssertEqual(u32(16), 1_672)
        XCTAssertEqual(u32(20), 941)
        for (width, height, expected) in [(360.0, 224.0, 106.0),
                                           (520.0, 330.0, 152.0),
                                           (700.0, 420.0, 192.0)] {
            let layout = TitleMenuLayout.resolve(viewportWidth: width, viewportHeight: height)
            XCTAssertTrue(layout.heroClearanceIsSatisfiable)
            XCTAssertEqual(layout.primaryButtonOriginsY.first, expected)
            assertValid(layout, height: height)
        }
    }

    func testSupportedViewportSweepIsFiniteAndCollisionFree() {
        for width in stride(from: 360.0, through: 1_200.0, by: 7) {
            for height in stride(from: 224.0, through: 800.0, by: 11) {
                let layout = TitleMenuLayout.resolve(viewportWidth: width, viewportHeight: height)
                XCTAssertTrue(layout.heroClearanceIsSatisfiable, "\(width)x\(height)")
                assertValid(layout, height: height)
            }
        }
    }

    func testInvalidAndUndersizedInputsFailClosed() {
        for pair in [(0.0, 224.0), (-1, 224), (.nan, 224), (.infinity, 224), (360, 0)] {
            let layout = TitleMenuLayout.resolve(viewportWidth: pair.0, viewportHeight: pair.1)
            XCTAssertFalse(layout.heroClearanceIsSatisfiable)
            XCTAssertTrue((layout.primaryButtonOriginsY + [layout.secondaryButtonOriginY,
                layout.heroProtectedBottomY]).allSatisfy(\.isFinite))
        }
        XCTAssertFalse(TitleMenuLayout.resolve(
            viewportWidth: 360, viewportHeight: 120).heroClearanceIsSatisfiable)
    }

    func testProductionTitleFocusAndAccessibilityContractsAreWired() throws {
        let menus = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/Elysium/MenusM.swift"), encoding: .utf8)
        for id in ["title:singleplayer", "title:multiplayer", "title:credits",
                   "title:options", "title:quit"] {
            XCTAssertTrue(menus.contains(id), id)
        }
        XCTAssertTrue(menus.contains("TitleMenuLayout.resolve(viewportWidth: ui.width"))
        XCTAssertTrue(menus.contains("event.modifiers.isEmpty || event.modifiers == [.shift]"))
        XCTAssertTrue(menus.contains("guard !event.isRepeat, let focusedAction"))
        XCTAssertTrue(menus.contains("role: .button"))
        XCTAssertTrue(menus.contains("ui.current() === self"))
        XCTAssertTrue(menus.contains("publishOrdinaryAccessibilityFocus"))
        XCTAssertTrue(menus.contains("button.x + 1, button.y + 1, button.w - 2, button.h - 2"))

        let manager = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/Elysium/UIManagerM.swift"), encoding: .utf8)
        let layoutPost = try XCTUnwrap(manager.range(of: "notification: .layoutChanged"))
        let focusPost = try XCTUnwrap(manager.range(
            of: "publishOrdinaryAccessibilityFocus(", range: layoutPost.upperBound..<manager.endIndex))
        XCTAssertLessThan(layoutPost.lowerBound, focusPost.lowerBound)
        XCTAssertTrue(manager.contains("view.window?.firstResponder === view"))

        let bridge = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/Elysium/TextEntryAccessibilityM.swift"), encoding: .utf8)
        XCTAssertTrue(bridge.contains("setAccessibilityIdentifier(stableID)"))
        XCTAssertTrue(bridge.contains("setAccessibilityIdentifier(nil)"))
    }

    private func assertValid(_ layout: TitleMenuLayout, height: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.primaryButtonOriginsY.count, 3, file: file, line: line)
        XCTAssertEqual(layout.primaryButtonOriginsY[1] - layout.primaryButtonOriginsY[0], 24,
                       file: file, line: line)
        XCTAssertEqual(layout.primaryButtonOriginsY[2] - layout.primaryButtonOriginsY[1], 24,
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.primaryButtonOriginsY[0] - layout.heroProtectedBottomY, 6,
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.secondaryButtonOriginY -
                                    (layout.primaryButtonOriginsY[2] + 20), 4,
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(layout.secondaryButtonOriginY + 20, height - 24,
                                 file: file, line: line)
    }
}
