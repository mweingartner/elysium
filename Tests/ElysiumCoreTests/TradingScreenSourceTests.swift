import Foundation
import XCTest

final class TradingScreenSourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTradingScreenIsPassiveScrollableAndUsesAuthoritativeCommit() throws {
        let screens = try source("Sources/Elysium/ScreensM.swift")
        let start = try XCTUnwrap(screens.range(of: "final class TradingScreen"))
        let end = try XCTUnwrap(screens.range(of: "// Creative inventory", range: start.upperBound..<screens.endIndex))
        let body = String(screens[start.lowerBound..<end.lowerBound])

        for required in ["prepareNPCBarter(for: villager)",
                         "commitNPCBarter(offer.receipt, merchant: villager)",
                         "selectedOfferID", "maxScroll()", "override func onWheel",
                         "case \"PageUp\"", "case \"PageDown\"", "case \"Enter\", \"Space\"",
                         "Wants:", "Villager wants:", "You receive:",
                         "if selected {", "if focused {", "cv.strokeRect",
                         "Out of stock", "Inventory full - make room for",
                         "npcBarterRestockMessage", "npcBarterSuccessMessage",
                         "NPCBarterScreenLayout.make"] {
            XCTAssertTrue(body.contains(required), "missing trading contract: \(required)")
        }
        for forbidden in ["var buyA:", "var buyB:", "buyA!.count", "onTake:",
                          "advance(\"trade_villager\")", "i < 7", "wants.prefix"] {
            XCTAssertFalse(body.contains(forbidden), "legacy staged trading remains: \(forbidden)")
        }
    }

    func testTradingAccessibilityPublishesHeadingListRowsAndDisabledReason() throws {
        let screens = try source("Sources/Elysium/ScreensM.swift")
        for token in ["id: \"trading.heading\", role: .heading",
                      "id: \"trading.offers\", role: .list",
                      "role: .listItem", "parentID: \"trading.offers\"",
                      "id: \"trading.trade\", role: .button",
                      "help: blockingStatus()", "actionable: tradeEnabled",
                      "consumeTextAccessibilityStatusAnnouncement"] {
            XCTAssertTrue(screens.contains(token), token)
        }

        let manager = try source("Sources/Elysium/UIManagerM.swift")
        XCTAssertTrue(manager.contains("case heading"))
        XCTAssertTrue(manager.contains("case list"))
        XCTAssertTrue(manager.contains("let parentID: String?"))

        let bridge = try source("Sources/Elysium/TextEntryAccessibilityM.swift")
        for token in ["hierarchyIsValid(descriptors)", "descriptor.parentID == nil",
                      "configureHierarchy(view: view)", "parent != descriptor.id",
                      "ids.contains(parent)", "visited.insert(id).inserted"] {
            XCTAssertTrue(bridge.contains(token), token)
        }
    }

    func testTradingControllerUsesTheSameSelectionAndCommitPath() throws {
        let screens = try source("Sources/Elysium/ScreensM.swift")
        let start = try XCTUnwrap(screens.range(of: "final class TradingScreen"))
        let end = try XCTUnwrap(screens.range(of: "// Creative inventory", range: start.upperBound..<screens.endIndex))
        let body = String(screens[start.lowerBound..<end.lowerBound])
        for token in ["func handleControllerCommand", "case .moveFocus(.up)",
                      "case .moveFocus(.down)", "case .activate:",
                      "executeTrade(game)", "case .back:", "ui.closeTop(game)"] {
            XCTAssertTrue(body.contains(token), token)
        }
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        XCTAssertTrue(adapter.contains("app.ui.current() is TradingScreen"))
        XCTAssertTrue(adapter.contains("screen.handleControllerCommand(command"))
    }

    func testInstalledScreenHarnessCanOpenARealAttachedMerchant() throws {
        let main = try source("Sources/Elysium/main.swift")
        for token in ["case \"trading\", \"barter\"", "Villager(world: game.world)",
                      "villager.profession = \"farmer\"", "villager.refreshTrades()",
                      "game.world.addEntity(villager)", "ui.open(TradingScreen(villager), game)"] {
            XCTAssertTrue(main.contains(token), token)
        }
    }
}
