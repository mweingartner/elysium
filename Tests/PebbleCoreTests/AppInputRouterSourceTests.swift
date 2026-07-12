import Foundation
import XCTest

final class AppInputRouterSourceTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testBothAppKitKeyboardEntrypointsDelegateToOneRouter() throws {
        let main = try source("Sources/Pebble/main.swift")
        let performStart = try XCTUnwrap(main.range(of: "override func performKeyEquivalent"))
        let keyUpStart = try XCTUnwrap(main.range(of: "override func keyUp", range: performStart.upperBound..<main.endIndex))
        let ingress = String(main[performStart.lowerBound..<keyUpStart.lowerBound])

        XCTAssertEqual(ingress.components(separatedBy: "appInputRouter.route(").count - 1, 2)
        XCTAssertTrue(ingress.contains("source: .performKeyEquivalent"))
        XCTAssertTrue(ingress.contains("source: .keyDown"))
        for forbidden in ["code == \"F11\"", "code == \"Escape\"", "game.keyDown(",
                          "handleObjectTemplateShortcut", "requestRPG"] {
            XCTAssertFalse(ingress.contains(forbidden), "independent main.swift route: \(forbidden)")
        }
    }

    func testRawGameCoreKeyDownContainsNoRPGChordFanout() throws {
        let core = try source("Sources/PebbleCore/Game/GameCore.swift")
        let start = try XCTUnwrap(core.range(of: "public func keyDown(_ code:"))
        let end = try XCTUnwrap(core.range(of: "public func keyUp(_ code:", range: start.upperBound..<core.endIndex))
        let body = String(core[start.lowerBound..<end.lowerBound])
        for forbidden in ["code == \"KeyK\"", "code == \"KeyO\"", "code == \"KeyL\"",
                          "requestRPG", "keys.contains(\"ShiftLeft\")"] {
            XCTAssertFalse(body.contains(forbidden), "raw RPG fanout remains: \(forbidden)")
        }
    }

    func testRouterOwnsPrecedenceDedupeAndConfiguredResolution() throws {
        let adapter = try source("Sources/Pebble/AppInputRouterM.swift")
        XCTAssertTrue(adapter.contains("private var router = RPGPureInputRouter()"))
        XCTAssertTrue(adapter.contains("private var configuredBindingPresses = " +
            "PebbleConfiguredBindingPressLedger()"))
        XCTAssertTrue(adapter.contains("bindings: game.keybinds"))
        XCTAssertTrue(adapter.contains("screenPresent: screenPresent"))
        XCTAssertTrue(adapter.contains("case .unhandledForMainMenu, .unhandledProtected, .unhandled:"))
        XCTAssertTrue(adapter.contains("resolveKeyCommand(event: event, allowedContexts: [.appHUD]"))
        XCTAssertFalse(adapter.contains("event.keyCode =="))
        XCTAssertTrue(adapter.contains("settings.hasActiveControlsCapture"))
        XCTAssertFalse(adapter.contains("event.eventNumber"))
        XCTAssertTrue(adapter.contains("private var handledEquivalents: [HandledEquivalent]"))
        let captureGate = try XCTUnwrap(adapter.range(of: "settings.hasActiveControlsCapture"))
        let pureRoute = try XCTUnwrap(adapter.range(
            of: "let disposition = router.route(", range: captureGate.upperBound..<adapter.endIndex))
        XCTAssertLessThan(adapter.distance(from: adapter.startIndex, to: captureGate.lowerBound),
                          adapter.distance(from: adapter.startIndex, to: pureRoute.lowerBound))
        let manager = try source("Sources/Pebble/UIManagerM.swift")
        XCTAssertTrue(manager.contains("lastWorldScreenInstanceID: UInt64 = " +
            "RPGPassiveSemanticClock.maximumScreenInstanceID"))
        XCTAssertTrue(adapter.contains(
            "ui.dispatchRPGWorldSemanticCommand(command, source: .keyboard, game: game)"))
        XCTAssertFalse(adapter.contains("screenInstanceID: 1"))
        XCTAssertTrue(adapter.contains("game.keyDown(binding: press.action, " +
            "configuredCode: press.executedCode"))

        let main = try source("Sources/Pebble/main.swift")
        let keyUp = try XCTUnwrap(main.range(of: "override func keyUp"))
        let flags = try XCTUnwrap(main.range(of: "override func flagsChanged", range: keyUp.upperBound..<main.endIndex))
        let keyUpBody = String(main[keyUp.lowerBound..<flags.lowerBound])
        XCTAssertTrue(keyUpBody.contains("appInputRouter.release(event: event)"))
        XCTAssertFalse(keyUpBody.contains("game.keyUp("))
    }

    func testInputSessionResetRetiresAllIdentityLedgersBeforeSerialAndLatchReuse() throws {
        let adapter = try source("Sources/Pebble/AppInputRouterM.swift")
        let start = try XCTUnwrap(adapter.range(of: "func resetPressedBindings()"))
        let end = try XCTUnwrap(adapter.range(
            of: "private func makePhysicalEvent", range: start.upperBound..<adapter.endIndex))
        let reset = String(adapter[start.lowerBound..<end.lowerBound])
        var cursor = reset.startIndex
        for marker in ["router = RPGPureInputRouter()",
                       "handledEquivalents.removeAll(keepingCapacity: false)",
                       "nextPhysicalRoutingSerial = 0",
                       "routingSerialExhausted = false",
                       "exhaustionLatch.resetInputSession()",
                       "configuredBindingPresses.removeAll()",
                       "modifierSynthesizer = PebbleModifierEdgeSynthesizer()"] {
            let range = try XCTUnwrap(reset.range(of: marker, range: cursor..<reset.endIndex), marker)
            cursor = range.upperBound
        }
        XCTAssertEqual(reset.components(separatedBy: "router = RPGPureInputRouter()").count - 1, 1)
        XCTAssertEqual(reset.components(
            separatedBy: "handledEquivalents.removeAll(keepingCapacity: false)").count - 1, 1)
        XCTAssertFalse(adapter.contains("event.eventNumber"))
        XCTAssertFalse(reset.contains("timestamp"))
        XCTAssertFalse(reset.contains("fingerprint"))
    }
}
