import XCTest
@testable import PebbleCore

final class InputChordTests: XCTestCase {
    func testControlDropCompatibilityIsNarrowAndDoesNotRelaxAppHUDModifiers() throws {
        let drop = try XCTUnwrap(PebbleTerminalKey(rawValue: "KeyQ"))
        let controlDrop = PebbleKeyEvent(
            terminal: drop, modifiers: .control, routingSerial: 801)
        XCTAssertEqual(resolveLegacyControlDropAll(
            event: controlDrop, bindings: rpgDefaultChordBindings()),
            .worldAction("dropAll"))
        XCTAssertNil(resolveKeyCommand(event: controlDrop,
            allowedContexts: [.appHUD], bindings: rpgDefaultChordBindings()))

        let commandDrop = PebbleKeyEvent(
            terminal: drop, modifiers: .command, routingSerial: 802)
        XCTAssertNil(resolveLegacyControlDropAll(
            event: commandDrop, bindings: rpgDefaultChordBindings()))
        XCTAssertTrue(isProtectedAppChord(try XCTUnwrap(commandDrop.chord)))

        var modified = rpgDefaultChordBindings()
        modified["drop"] = "Option+KeyQ"
        XCTAssertNil(resolveLegacyControlDropAll(event: controlDrop, bindings: modified))

        modified["drop"] = "Control+KeyQ"
        XCTAssertNil(resolveLegacyControlDropAll(event: controlDrop, bindings: modified))
        XCTAssertEqual(resolveKeyCommand(
            event: controlDrop, allowedContexts: [.appHUD], bindings: modified),
            .binding(.drop), "an explicitly configured Control+Drop is ordinary single-item Drop")
    }

    func testModifiedMovementAndHUDBindingsResolveTypedAndPairExactPressCode() throws {
        var bindings = rpgDefaultChordBindings()
        bindings["forward"] = "Option+KeyW"
        bindings["inventory"] = "Control+KeyE"
        bindings["drop"] = "Shift+KeyQ"
        var ledger = PebbleConfiguredBindingPressLedger()

        for (action, key, modifiers, expectedCode) in [
            (PebbleGameBindingAction.forward, "KeyW", PebbleKeyModifiers.option, "Option+KeyW"),
            (.inventory, "KeyE", .control, "Control+KeyE"),
            (.drop, "KeyQ", .shift, "Shift+KeyQ"),
        ] {
            let terminal = try XCTUnwrap(PebbleTerminalKey(rawValue: key))
            let event = PebbleKeyEvent(
                terminal: terminal, modifiers: modifiers,
                routingSerial: UInt64(expectedCode.utf8.count))
            XCTAssertEqual(resolveKeyCommand(
                event: event, allowedContexts: [.movement, .appHUD], bindings: bindings),
                .binding(action))
            let press = try XCTUnwrap(ledger.press(action: action, event: event, bindings: bindings))
            XCTAssertEqual(press.executedCode, expectedCode)

            // Release is paired to the press snapshot, not re-resolved against mutable bindings.
            bindings[action.rawValue] = "F12"
            XCTAssertEqual(ledger.release(terminal: terminal), press)
            XCTAssertNil(ledger.release(terminal: terminal))
        }
        XCTAssertTrue(ledger.pressed.isEmpty)
    }

    func testUnmodifiedMovementRelaxationPublishesConfiguredCodeAndLedgerRejectsRepeat() throws {
        let bindings = rpgDefaultChordBindings()
        let terminal = try XCTUnwrap(PebbleTerminalKey(rawValue: "KeyW"))
        let shifted = PebbleKeyEvent(
            terminal: terminal, modifiers: .shift, routingSerial: 901)
        XCTAssertEqual(resolveKeyCommand(
            event: shifted, allowedContexts: [.movement], bindings: bindings),
            .binding(.forward))
        var ledger = PebbleConfiguredBindingPressLedger()
        XCTAssertEqual(ledger.press(action: .forward, event: shifted, bindings: bindings)?.executedCode,
                       "KeyW")
        let repeated = PebbleKeyEvent(
            terminal: terminal, modifiers: .shift, isRepeat: true, routingSerial: 902)
        XCTAssertNil(ledger.press(action: .forward, event: repeated, bindings: bindings))
        XCTAssertEqual(ledger.pressed.count, 1)
    }
    func testCanonicalParserDefaultsAndProtection() throws {
        XCTAssertEqual(KEYBIND_DEFINITIONS.count, 25)
        XCTAssertEqual(rpgDefaultChordBindings().count, 25)
        XCTAssertEqual(try PebbleKeyChord(parsing: "Command+Control+Option+Shift+KeyK").description,
                       "Command+Control+Option+Shift+KeyK")
        for invalid in ["", "Shift", "Shift+Shift", "Shift+", "Shift+Command+KeyK",
                        "KeyK+KeyL", "Shift+ShiftLeft", "Unknown"] {
            XCTAssertThrowsError(try PebbleKeyChord(parsing: invalid), invalid)
        }
        XCTAssertTrue(isProtectedAppChord(try PebbleKeyChord(parsing: "F11")))
        XCTAssertTrue(isProtectedAppChord(try PebbleKeyChord(parsing: "Shift+F11")))
        for menu in SHIPPING_MENU_COMMANDS { XCTAssertTrue(isProtectedAppChord(menu.chord)) }
    }

    func testResolverUsesExactChordAndAtMostOneRoutingSerial() throws {
        let bindings = rpgDefaultChordBindings()
        let digit = try XCTUnwrap(PebbleTerminalKey(rawValue: "Digit1"))
        let event = PebbleKeyEvent(terminal: digit, modifiers: .shift, routingSerial: 7)
        XCTAssertEqual(resolveKeyCommand(event: event, allowedContexts: [.rpgWorldAction, .hotbar],
                                         bindings: bindings), .semantic(.useQuickSlot(0)))
        var router = RPGPureInputRouter()
        XCTAssertEqual(router.resolve(event: event, allowedContexts: [.rpgWorldAction], bindings: bindings),
                       .semantic(.useQuickSlot(0)))
        XCTAssertNil(router.resolve(event: event, allowedContexts: [.rpgWorldAction], bindings: bindings))
        let repeated = PebbleKeyEvent(terminal: digit, modifiers: .shift, isRepeat: true, routingSerial: 8)
        XCTAssertNil(resolveKeyCommand(event: repeated, allowedContexts: [.rpgWorldAction], bindings: bindings))
    }

    func testConflictWinnerIsStableByContextThenDefinitionOrder() {
        var bindings = rpgDefaultChordBindings()
        bindings["forward"] = "KeyK"
        bindings["rpgCharacter"] = "KeyK"
        let conflict = keybindConflicts(bindings: bindings).first { $0.chord.description == "KeyK" }
        XCTAssertEqual(conflict?.winnerActionID, "rpgCharacter")
        XCTAssertEqual(conflict?.actionIDs, ["rpgCharacter", "forward"])
    }

    func testRPGDefaultsResolveToSemanticCommands() throws {
        let bindings = rpgDefaultChordBindings()
        for (key, expected) in [("KeyK", RPGSemanticCommand.openCharacter),
                                ("KeyO", .cyclePreparedAction),
                                ("KeyL", .useSelectedAction)] {
            let terminal = try XCTUnwrap(PebbleTerminalKey(rawValue: key))
            let event = PebbleKeyEvent(terminal: terminal, routingSerial: UInt64(key.utf8.first!))
            XCTAssertEqual(resolveKeyCommand(event: event, allowedContexts: [.rpgWorldAction], bindings: bindings),
                           .semantic(expected))
        }
    }

    func testSanitizationFallsBackPerActionAndPersistenceRejectsProtected() throws {
        var raw = rpgDefaultChordBindings()
        raw["rpgCharacter"] = "Command+KeyQ"
        raw["rpgCycleAction"] = "bad"
        raw["rpgUseAction"] = "Control+KeyL"
        let sanitized = rpgSanitizedChordBindings(raw)
        XCTAssertEqual(sanitized["rpgCharacter"], "KeyK")
        XCTAssertEqual(sanitized["rpgCycleAction"], "KeyO")
        XCTAssertEqual(sanitized["rpgUseAction"], "Control+KeyL")
        XCTAssertEqual(rpgValidateChordBindingsForPersistence(raw), .failure(.protectedChord("rpgCharacter")))
        XCTAssertEqual(rpgValidateChordBindingsForPersistence(["extra": "KeyA"]),
                       .failure(.unknownAction("extra")))
    }

    func testPureRouterDedupesOneDeliveryButNeverEqualSignatureIndependentKeyDowns() throws {
        let terminal = try XCTUnwrap(PebbleTerminalKey(rawValue: "Digit1"))
        let event = PebbleKeyEvent(terminal: terminal, modifiers: .shift, routingSerial: 99)
        let fingerprint = AppKeyEventFingerprint(eventNumber: 7, keyCode: 18,
            timestampMicroseconds: 10, windowNumber: 1, modifiers: .shift,
            isRepeat: false, origin: .physical)
        var router = RPGPureInputRouter()
        XCTAssertEqual(router.route(event: event, fingerprint: fingerprint, nowMilliseconds: 1,
            allowedContexts: [.rpgWorldAction, .hotbar], bindings: rpgDefaultChordBindings()),
            .resolved(.semantic(.useQuickSlot(0))))
        XCTAssertEqual(router.route(event: event, fingerprint: fingerprint, nowMilliseconds: 2,
            allowedContexts: [.rpgWorldAction], bindings: rpgDefaultChordBindings()), .consumedDuplicate)
        let independent = PebbleKeyEvent(
            terminal: terminal, modifiers: .shift, routingSerial: 100)
        XCTAssertEqual(router.route(event: independent, fingerprint: fingerprint, nowMilliseconds: 2,
            allowedContexts: [.rpgWorldAction], bindings: rpgDefaultChordBindings()),
            .resolved(.semantic(.useQuickSlot(0))))

        let quit = PebbleKeyEvent(terminal: try XCTUnwrap(PebbleTerminalKey(rawValue: "KeyQ")),
                                  modifiers: .command, routingSerial: 101)
        let quitFingerprint = AppKeyEventFingerprint(eventNumber: 8, keyCode: 12,
            timestampMicroseconds: 11, windowNumber: 1, modifiers: .command,
            isRepeat: false, origin: .physical)
        XCTAssertEqual(router.route(event: quit, fingerprint: quitFingerprint, nowMilliseconds: 300,
            screenCommand: .semantic(.activate), allowedContexts: [.rpgScreen], bindings: [:]),
            .unhandledForMainMenu)
    }

    func testNewInputSessionAcceptsReusedSerialOnlyAfterRouterLedgerReplacement() throws {
        let terminal = try XCTUnwrap(PebbleTerminalKey(rawValue: "ArrowRight"))
        let event = PebbleKeyEvent(terminal: terminal, routingSerial: 1)
        let fingerprint = AppKeyEventFingerprint(
            eventNumber: 0, keyCode: 124, timestampMicroseconds: 0,
            windowNumber: 1, modifiers: [], isRepeat: false, origin: .physical)
        var router = RPGPureInputRouter()

        XCTAssertEqual(router.route(
            event: event, fingerprint: fingerprint, nowMilliseconds: 1,
            screenPresent: true, allowedContexts: [], bindings: [:]), .routeToScreen)
        router.rememberConsumed(event)
        XCTAssertEqual(router.route(
            event: event, fingerprint: fingerprint, nowMilliseconds: 2,
            screenPresent: true, allowedContexts: [], bindings: [:]), .consumedDuplicate)

        router = RPGPureInputRouter()
        XCTAssertEqual(router.route(
            event: event, fingerprint: fingerprint, nowMilliseconds: 3,
            screenPresent: true, allowedContexts: [], bindings: [:]), .routeToScreen)
    }

    func testPureRouterDefersToScreenOnlyAfterGlobalAndProtectedPrecedence() throws {
        let key = try XCTUnwrap(PebbleTerminalKey(rawValue: "KeyK"))
        let event = PebbleKeyEvent(terminal: key, routingSerial: 120)
        let fingerprint = AppKeyEventFingerprint(
            eventNumber: 120, keyCode: 40, timestampMicroseconds: 120,
            windowNumber: 1, modifiers: [], isRepeat: false, origin: .physical)
        var router = RPGPureInputRouter()
        XCTAssertEqual(router.route(
            event: event, fingerprint: fingerprint, nowMilliseconds: 1,
            screenPresent: true, independentCommand: .semantic(.openCharacter),
            allowedContexts: [.rpgWorldAction], bindings: rpgDefaultChordBindings()),
            .routeToScreen)

        router.rememberConsumed(event)
        XCTAssertEqual(router.route(
            event: event, fingerprint: fingerprint, nowMilliseconds: 2,
            screenPresent: true, allowedContexts: [.rpgWorldAction],
            bindings: rpgDefaultChordBindings()), .consumedDuplicate)

        let fullscreen = PebbleKeyEvent(
            terminal: try XCTUnwrap(PebbleTerminalKey(rawValue: "F11")), routingSerial: 121)
        let fullscreenFingerprint = AppKeyEventFingerprint(
            eventNumber: 121, keyCode: 103, timestampMicroseconds: 121,
            windowNumber: 1, modifiers: [], isRepeat: false, origin: .physical)
        XCTAssertEqual(router.route(
            event: fullscreen, fingerprint: fullscreenFingerprint, nowMilliseconds: 3,
            screenPresent: true, allowedContexts: [.rpgScreen], bindings: [:]),
            .globalFullscreen)
    }

    func testIndependentCommandDoesNotOverrideExactConfiguredRPGChord() throws {
        let shiftedDigit = PebbleKeyEvent(
            terminal: try XCTUnwrap(PebbleTerminalKey(rawValue: "Digit1")),
            modifiers: .shift, routingSerial: 130)
        let shiftedFingerprint = AppKeyEventFingerprint(
            eventNumber: 130, keyCode: 18, timestampMicroseconds: 130,
            windowNumber: 1, modifiers: .shift, isRepeat: false, origin: .physical)
        var router = RPGPureInputRouter()
        XCTAssertEqual(router.route(
            event: shiftedDigit, fingerprint: shiftedFingerprint, nowMilliseconds: 1,
            independentCommand: .worldAction("hotbar:0"),
            allowedContexts: [.rpgWorldAction, .hotbar], bindings: rpgDefaultChordBindings()),
            .resolved(.semantic(.useQuickSlot(0))))
    }

    func testSynthesizedModifierEdgesHaveIndependentSerials() {
        var synthesizer = PebbleModifierEdgeSynthesizer()
        XCTAssertEqual(synthesizer.update(.shift).map(\.terminal.rawValue), ["ShiftLeft"])
        XCTAssertTrue(synthesizer.update(.shift).isEmpty)
        XCTAssertTrue(synthesizer.update([]).isEmpty)
        XCTAssertEqual(synthesizer.update(.control).map(\.terminal.rawValue), ["ControlLeft"])

        var exhausted = PebbleModifierEdgeSynthesizer(startingSerial: .max)
        XCTAssertTrue(exhausted.update(.shift).isEmpty)
        XCTAssertTrue(exhausted.exhausted)
        XCTAssertTrue(exhausted.update(.control).isEmpty, "exhaustion must remain latched")
    }

    func testPairwiseTwentyFiveDefinitionContextConflictMatrixAndCommandZ() throws {
        XCTAssertEqual(KEYBIND_DEFINITIONS.count, 25)
        var pairCount = 0
        for left in 0..<KEYBIND_DEFINITIONS.count {
            for right in (left + 1)..<KEYBIND_DEFINITIONS.count {
                var bindings = rpgDefaultChordBindings()
                bindings[KEYBIND_DEFINITIONS[left].actionID] = "Option+F12"
                bindings[KEYBIND_DEFINITIONS[right].actionID] = "Option+F12"
                let conflict = try XCTUnwrap(keybindConflicts(bindings: bindings).first {
                    $0.chord.description == "Option+F12"
                })
                let leftDefinition = KEYBIND_DEFINITIONS[left]
                let rightDefinition = KEYBIND_DEFINITIONS[right]
                let expectedWinner: String
                if leftDefinition.context != rightDefinition.context {
                    expectedWinner = leftDefinition.context > rightDefinition.context
                        ? leftDefinition.actionID : rightDefinition.actionID
                } else {
                    expectedWinner = leftDefinition.actionID
                }
                XCTAssertEqual(conflict.winnerActionID, expectedWinner, "pair \(left),\(right)")
                XCTAssertEqual(Set(conflict.actionIDs),
                               Set([leftDefinition.actionID, rightDefinition.actionID]))
                pairCount += 1
            }
        }
        XCTAssertEqual(pairCount, 300)

        let undoChord = try PebbleKeyChord(parsing: "Command+KeyZ")
        XCTAssertTrue(isProtectedAppChord(undoChord))
        var protectedBindings = rpgDefaultChordBindings()
        protectedBindings["rpgCharacter"] = undoChord.description
        XCTAssertEqual(rpgSanitizedChordBindings(protectedBindings)["rpgCharacter"], "KeyK")
        XCTAssertEqual(rpgValidateChordBindingsForPersistence(protectedBindings),
                       .failure(.protectedChord("rpgCharacter")))
        let event = PebbleKeyEvent(terminal: try XCTUnwrap(PebbleTerminalKey(rawValue: "KeyZ")),
                                   modifiers: .command, routingSerial: 999)
        XCTAssertNil(resolveKeyCommand(event: event, allowedContexts: Set(PebbleBindingContext.allCasesForTests),
                                       bindings: protectedBindings))
        let fingerprint = AppKeyEventFingerprint(eventNumber: 99, keyCode: 6,
            timestampMicroseconds: 99, windowNumber: 1, modifiers: .command,
            isRepeat: false, origin: .physical)
        var router = RPGPureInputRouter()
        XCTAssertEqual(router.route(event: event, fingerprint: fingerprint, nowMilliseconds: 1,
            allowedContexts: [.appHUD, .rpgWorldAction, .hotbar, .movement],
            bindings: protectedBindings), .unhandledProtected)
    }
}

private extension PebbleBindingContext {
    static let allCasesForTests: [PebbleBindingContext] =
        [.movement, .hotbar, .rpgWorldAction, .appHUD, .rpgScreen]
}
