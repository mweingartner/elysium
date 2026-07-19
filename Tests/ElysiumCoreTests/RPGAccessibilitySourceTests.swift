import Foundation
import XCTest

final class RPGAccessibilitySourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testAppKitBridgeCachesExactOriginStrongScreenAndNoCurrentTupleSubstitution() throws {
        let bridge = try source("Sources/Elysium/RPGAccessibilityM.swift")
        for token in ["private(set) var cached: RPGAccessibilityElementSnapshot",
                      "let screenInstanceID: UInt64", "private(set) var semanticRevision: UInt64",
                      "weak var originScreen: Screen?", "captureRPGAccessibilityActivation(origin: origin)",
                      "dispatchRPGAccessibilityActivation(",
                      "cached.descriptor.visibleFrame == nil"] {
            XCTAssertTrue(bridge.contains(token), "missing origin-bound bridge token: \(token)")
        }
        for retained in ["case .scalarRefresh(let retained)", "element.refreshScalars(",
                         "private func structuralKey", "ElysiumRetainedStructureKey"] {
            XCTAssertTrue(bridge.contains(retained), retained)
        }
        let scalarStart = try XCTUnwrap(bridge.range(of: "case .scalarRefresh(let retained):"))
        let replacementStart = try XCTUnwrap(bridge.range(
            of: "case .structuralReplacement", range: scalarStart.upperBound..<bridge.endIndex))
        let scalar = String(bridge[scalarStart.lowerBound..<replacementStart.lowerBound])
        for forbidden in ["setAccessibilityParent", "setAccessibilityChildren",
                          "nestChildren", "publishAccessibilityChildren"] {
            XCTAssertFalse(scalar.contains(forbidden), "equal-key refresh published tree: \(forbidden)")
        }
        let pressStart = try XCTUnwrap(bridge.range(of: "func press("))
        let frameStart = try XCTUnwrap(bridge.range(of: "private func screenFrame",
                                                   range: pressStart.upperBound..<bridge.endIndex))
        let press = String(bridge[pressStart.lowerBound..<frameStart.lowerBound])
        XCTAssertFalse(press.contains("semanticSnapshot"))
        XCTAssertFalse(press.contains("rpgPassiveDescriptor"))
        XCTAssertFalse(press.contains("captureRPGSemanticActivation(id:"))
    }

    func testGameViewGroupRolesCoordinatesAndNonactionablePressContract() throws {
        let bridge = try source("Sources/Elysium/RPGAccessibilityM.swift")
        // The retired .rankCell semantic role was the only source of the AppKit .cell role; skill
        // ranks now ride on .row descriptors (with rankPips), so .cell is no longer produced.
        for role in [".button", ".staticText", ".radioButton", ".tabGroup", ".group", ".row",
                     ".scrollArea"] {
            XCTAssertTrue(bridge.contains("return \(role)"), "missing role \(role)")
        }
        XCTAssertTrue(bridge.contains("nestChildren(parentID: \"accessibility:tab-group\""))
        XCTAssertTrue(bridge.contains("nestChildren(parentID: \"accessibility:skills-root\""))
        XCTAssertTrue(bridge.contains("cached.hasPressAction ? [.press] : []"))
        for coordinate in ["view.ui?.scale", "window.backingScaleFactor", "view.bounds.height",
                           "view.convert(", "window.convertPoint(toScreen:"] {
            XCTAssertTrue(bridge.contains(coordinate), "missing coordinate stage \(coordinate)")
        }
        let main = try source("Sources/Elysium/main.swift")
        XCTAssertTrue(main.contains("override func accessibilityRole()"))
        XCTAssertTrue(main.contains(".group"))
        XCTAssertTrue(main.contains("setAccessibilityChildren(textEntryAccessibilityBridge.children +"))
        XCTAssertFalse(main.contains("override func accessibilityChildren()"))
        XCTAssertTrue(main.contains("Elysium menus and actions"))
        // D4: the bridge posts the creation step title as an accessibility announcement, alongside
        // the authority-phase announcement, on each committed tree.
        XCTAssertTrue(bridge.contains("rpgAccessibilityCreationStepAnnouncement("),
                      "RPGAccessibilityM must post the creation-step announcement")
        XCTAssertEqual(bridge.components(separatedBy: ".announcementRequested").count - 1, 2,
                       "both authority and creation-step announcements are posted")
    }

    func testCachePublishesOnlyAtExplicitCommitAndFailureInvalidates() throws {
        let manager = try source("Sources/Elysium/UIManagerM.swift")
        XCTAssertTrue(manager.contains("var semanticSnapshot: RPGCommittedSemanticSnapshot? { nil }"))
        XCTAssertTrue(manager.contains("var semanticRevision: UInt64 { 0 }"))
        XCTAssertTrue(manager.contains("func focusSemanticElement("))
        XCTAssertEqual(manager.components(
            separatedBy: "publishRPGAccessibilityCommit(snapshot, screen: screen)").count - 1, 1)
        XCTAssertTrue(manager.contains("rpgAccessibilityDidCommit?(screen, tree)"))
        XCTAssertTrue(manager.contains("rpgAccessibilityDidInvalidate?()"))
        XCTAssertTrue(manager.contains("boundary.capture(origin: origin)"))
        XCTAssertTrue(manager.contains("guard let originScreen else"))
        XCTAssertTrue(manager.contains("cancelRPGSemanticActivation(capture)"))
        XCTAssertTrue(manager.contains("RPGAccessibilityPublicationClock()"))
        XCTAssertFalse(manager.contains("rpgAccessibilityLayoutGenerationExhausted"))
        let renderer = try source("Sources/Elysium/RPGScreensM.swift")
        let nilRuntime = try XCTUnwrap(renderer.range(of: "guard let runtime"))
        let tutorial = try XCTUnwrap(renderer.range(of: "if runtime.state.created",
                                                    range: nilRuntime.upperBound..<renderer.endIndex))
        let failure = String(renderer[nilRuntime.lowerBound..<tutorial.lowerBound])
        XCTAssertTrue(failure.contains("clearRPGPassiveSemanticSnapshot()"))
        XCTAssertTrue(failure.contains("ui.invalidateRPGAccessibilityCache()"))
        let drawStart = try XCTUnwrap(renderer.range(of: "override func draw("))
        let inputStart = try XCTUnwrap(renderer.range(of: "override func inputOwnershipLost",
                                                     range: drawStart.upperBound..<renderer.endIndex))
        let draw = String(renderer[drawStart.lowerBound..<inputStart.lowerBound])
        XCTAssertFalse(draw.contains("Accessibility"))
        XCTAssertFalse(draw.contains("publishRPGAccessibility"))
    }

    func testFocusNotificationsAndAppearanceUseCommittedSemanticPath() throws {
        let bridge = try source("Sources/Elysium/RPGAccessibilityM.swift")
        for token in [".focusedUIElementChanged", ".valueChanged", ".layoutChanged",
                      "rpgAccessibilityNotificationIntents(", "focusRPGAccessibilityElement("] {
            XCTAssertTrue(bridge.contains(token), "missing committed notification/focus token \(token)")
        }
        let screen = try source("Sources/Elysium/RPGScreensM.swift")
        XCTAssertTrue(screen.contains("override func focusSemanticElement"))
        XCTAssertTrue(screen.contains("reduceInteraction(.focusElement(id)"))
        let core = try source("Sources/ElysiumCore/Game/RPGSemanticAccessibility.swift")
        XCTAssertTrue(core.contains("self.highContrast = committed.highContrast"))
        XCTAssertTrue(core.contains("self.reduceMotion = committed.reduceMotion"))
        XCTAssertTrue(core.contains("public func rpgAccessibilityViewFrame("))
    }

    func testAccessibilityFocusRequiresActiveKeyWindowAndRetainsOneEpochTarget() throws {
        let rpg = try source("Sources/Elysium/RPGAccessibilityM.swift")
        XCTAssertTrue(rpg.contains("guard NSApp.isActive, view.window?.isKeyWindow == true"))
        XCTAssertTrue(rpg.contains("NSApp.isActive && view?.window?.isKeyWindow == true"))
        XCTAssertTrue(rpg.contains("func retainedFocusedElement() -> ElysiumAccessibilityElement?"))
        let notifications = try XCTUnwrap(rpg.range(of: "private func postNotifications("))
        let structural = try XCTUnwrap(rpg.range(
            of: "private func structuralKey", range: notifications.upperBound..<rpg.endIndex))
        let notificationBody = String(rpg[notifications.lowerBound..<structural.lowerBound])
        XCTAssertTrue(notificationBody.contains(
            "guard NSApp.isActive, view.window?.isKeyWindow == true else { continue }"))

        let text = try source("Sources/Elysium/TextEntryAccessibilityM.swift")
        func functionBody(_ start: String, before end: String) throws -> String {
            let startRange = try XCTUnwrap(text.range(of: start))
            let tail = text[startRange.lowerBound...]
            let endRange = try XCTUnwrap(tail.range(of: end))
            return String(tail[..<endRange.lowerBound])
        }
        for body in [
            try functionBody("func isFocused(", before: "func focus("),
            try functionBody("func focus(", before: "func retainedFocusedElement("),
            try functionBody("func press(", before: "private func descriptorIsBounded("),
        ] {
            XCTAssertTrue(body.contains(
                "guard NSApp.isActive, view?.window?.isKeyWindow == true,"))
            XCTAssertTrue(body.contains(
                "!element.retired, elements.contains(where: { $0 === element })"))
        }
        XCTAssertTrue(text.contains(
            "func retainedFocusedElement() -> TextEntryAccessibilityElement?"))
        let manager = try source("Sources/Elysium/UIManagerM.swift")
        XCTAssertTrue(manager.contains(
            "if focusChanged, NSApp.isActive, view.window?.isKeyWindow == true"))

        let main = try source("Sources/Elysium/main.swift")
        XCTAssertTrue(main.contains("func retainedAccessibilityFocusTarget() -> Any?"))
        XCTAssertTrue(main.contains("return candidates.count == 1 ? candidates[0] : nil"))
        XCTAssertTrue(main.contains("activationEpochOpen = false"))
        XCTAssertTrue(main.contains("guard !activationEpochOpen else { return }"))
        XCTAssertTrue(main.contains("activationEpochOpen = true"))
        XCTAssertTrue(main.contains("activationEpoch &+= 1"))
        XCTAssertTrue(main.contains("publishedAccessibilityFocusEpoch = activationEpoch"))
    }
}
