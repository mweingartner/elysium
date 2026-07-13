import Foundation
import XCTest

final class RPGControllerAdapterSourceTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testGameControllerIsLinkedOnlyIntoAppAndAdapterScopeIsExact() throws {
        let package = try source("Package.swift")
        XCTAssertEqual(package.components(separatedBy: ".linkedFramework(\"GameController\")").count - 1, 1)
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        XCTAssertTrue(adapter.contains("import GameController"))
        XCTAssertTrue(adapter.contains("RPG menus and actions"))
        let model = try source("Sources/ElysiumCore/Game/RPGScreenModel.swift")
        XCTAssertTrue(model.contains("Controller support covers RPG menus and actions only."))
    }

    func testCallbacksCaptureStableIdentityAndBothCheckedGenerations() throws {
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        for required in ["ObjectIdentifier(controller)", "adapterGeneration: gate.adapterGeneration",
                         "contextGeneration: gate.contextGeneration", "controllers[objectID] === controller",
                         "gate.acceptsCallback(callbackIdentity)", "DispatchQueue.main.async"] {
            XCTAssertTrue(adapter.contains(required), "missing callback guard: \(required)")
        }
        XCTAssertTrue(adapter.contains("extendedGamepad?.valueChangedHandler = nil"))
        let boundary = try XCTUnwrap(adapter.range(of: "private func lifecycleBoundary"))
        let end = try XCTUnwrap(adapter.range(of: "private func replaceActiveController",
                                              range: boundary.upperBound..<adapter.endIndex))
        let body = String(adapter[boundary.lowerBound..<end.lowerBound])
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "removeEveryHandler()")).lowerBound,
                          try XCTUnwrap(body.range(of: "gate.contextBoundary()")).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "input.resetForLifecycleBoundary()")).lowerBound,
                          try XCTUnwrap(body.range(of: "gate.contextBoundary()")).lowerBound)
    }

    func testAdapterUsesOnlyReducerAndSoleSemanticDispatchers() throws {
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        XCTAssertTrue(adapter.contains("input.updateCallback("))
        XCTAssertTrue(adapter.contains("input.updateHeldRepeat("))
        XCTAssertTrue(adapter.contains("RPGControllerInput.callbackHasEnteredInput(values)"))
        XCTAssertTrue(adapter.contains("RPGControllerInput.callbackIsNeutral(values)"))
        XCTAssertFalse(adapter.contains("!Self.isNeutral(values)"))
        XCTAssertTrue(adapter.contains("handleRPGControllerCommand"))
        XCTAssertTrue(adapter.contains("dispatchRPGWorldSemanticCommand("))
        XCTAssertTrue(adapter.contains("source: .controller"))
        for forbidden in ["requestRPG", "player?.rpg", "player.rpg", "game.keyDown(",
                          "rpgLearnSkill", "rpgUsePreparedAction"] {
            XCTAssertFalse(adapter.contains(forbidden), "raw controller mutation: \(forbidden)")
        }
    }

    func testEveryPhysicalMappingAndLifecycleHookIsPresent() throws {
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        for token in ["gamepad.dpad", "gamepad.leftThumbstick", "gamepad.rightThumbstick",
                      "gamepad.buttonA", "gamepad.buttonB", "gamepad.buttonX", "gamepad.buttonY",
                      "gamepad.leftShoulder", "gamepad.rightShoulder", "gamepad.leftTrigger",
                      "gamepad.buttonOptions", "gamepad.rightThumbstickButton",
                      ".GCControllerDidConnect", ".GCControllerDidDisconnect"] {
            XCTAssertTrue(adapter.contains(token), "missing physical mapping: \(token)")
        }
        let main = try source("Sources/Elysium/main.swift")
        for token in ["RPGControllerAdapter(app: self)", "rpgControllerAdapter.start()",
                      "rpgControllerAdapter?.applicationDidResignActive()",
                      "rpgControllerAdapter?.applicationDidBecomeActive()",
                      "rpgControllerAdapter?.synchronizeContext()", "rpgControllerAdapter?.stop()"] {
            XCTAssertTrue(main.contains(token), "missing lifecycle hook: \(token)")
        }
        XCTAssertTrue(main.contains("rpgControllerAdapter.screenContextDidChange()"))
        XCTAssertTrue(adapter.contains("func screenContextDidChange()"))
        XCTAssertTrue(adapter.contains("synchronizeContext(forceBoundary: true)"))
    }

    func testConnectRetainsInventoryThenInvalidatesOldHandlersAndGeneration() throws {
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        let start = try XCTUnwrap(adapter.range(of: "private func connect("))
        let end = try XCTUnwrap(adapter.range(of: "private func disconnect(",
                                              range: start.upperBound..<adapter.endIndex))
        let body = String(adapter[start.lowerBound..<end.lowerBound])
        let retain = try XCTUnwrap(body.range(of: "controllers[objectID] = controller"))
        let boundary = try XCTUnwrap(body.range(
            of: "lifecycleBoundary(advanceContext: false, reinstall: focused, resetHelp: true)"))
        XCTAssertLessThan(retain.lowerBound, boundary.lowerBound)
        XCTAssertFalse(body.contains("controllers.remove"))

        let lifecycleStart = try XCTUnwrap(adapter.range(of: "private func lifecycleBoundary"))
        let lifecycleEnd = try XCTUnwrap(adapter.range(of: "private func replaceActiveController",
                                                       range: lifecycleStart.upperBound..<adapter.endIndex))
        let lifecycle = String(adapter[lifecycleStart.lowerBound..<lifecycleEnd.lowerBound])
        let remove = try XCTUnwrap(lifecycle.range(of: "removeEveryHandler()"))
        let reset = try XCTUnwrap(lifecycle.range(of: "input.resetForLifecycleBoundary()"))
        let generation = try XCTUnwrap(lifecycle.range(of: "gate.disconnectOrReplace()"))
        let reinstall = try XCTUnwrap(lifecycle.range(of: "installEveryHandler()"))
        XCTAssertLessThan(remove.lowerBound, reset.lowerBound)
        XCTAssertLessThan(reset.lowerBound, generation.lowerBound)
        XCTAssertLessThan(generation.lowerBound, reinstall.lowerBound)
    }

    func testControllerHelpRequiresAcceptedCommandAndKeyboardHelpRemains() throws {
        let adapter = try source("Sources/Elysium/RPGControllerM.swift")
        XCTAssertTrue(adapter.contains("if accepted { app.ui.setRPGControllerHelpPrimary(true"))
        let screen = try source("Sources/Elysium/RPGScreensM.swift")
        XCTAssertTrue(screen.contains("if ui.rpgControllerHelpPrimary"))
        XCTAssertTrue(screen.contains("RPG controller: D-pad/A/B · Keyboard:"))
        XCTAssertTrue(adapter.contains("setRPGControllerHelpPrimary(false"))
    }
}
