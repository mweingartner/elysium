import Foundation
import XCTest
import ElysiumCore

final class TextEntrySourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    private func dictionaryKeys(in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\"([A-Za-z][A-Za-z0-9]*)\"\s*:"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let value = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[value])
        })
    }

    func testCanonicalKeyDownOwnsOrdinaryTextAndPreflightDoesNotFingerprintIt() throws {
        let router = try source("Sources/Elysium/AppInputRouterM.swift")
        XCTAssertTrue(router.contains("if source == .performKeyEquivalent"))
        XCTAssertTrue(router.contains("guard isProtectedEquivalent else { return false }"))
        XCTAssertTrue(router.contains(
            "private let exhaustionLatch = ElysiumAppInputExhaustionLatch()"))
        let disposition = try XCTUnwrap(router.range(of: "exhaustionLatch.disposition("))
        let protectedBranch = try XCTUnwrap(router.range(
            of: "if source == .performKeyEquivalent", range: disposition.upperBound..<router.endIndex))
        XCTAssertLessThan(disposition.lowerBound, protectedBranch.lowerBound)
        let flagsStart = try XCTUnwrap(router.range(of: "func flagsChanged(with event: NSEvent)"))
        let releaseStart = try XCTUnwrap(router.range(
            of: "func release(event: NSEvent)", range: flagsStart.upperBound..<router.endIndex))
        let flags = String(router[flagsStart.lowerBound..<releaseStart.lowerBound])
        let record = try XCTUnwrap(flags.range(of: "exhaustionLatch.recordFlagsChanged("))
        XCTAssertLessThan(record.lowerBound,
                          try XCTUnwrap(flags.range(of: "release(terminal:")).lowerBound)
        XCTAssertLessThan(record.lowerBound,
                          try XCTUnwrap(flags.range(of: "modifierSynthesizer.update(")).lowerBound)
        let overflow = try XCTUnwrap(router.range(of: "guard !addition.overflow"))
        let exhausted = try XCTUnwrap(router.range(
            of: "routingSerialExhausted = true", range: overflow.upperBound..<router.endIndex))
        let latch = try XCTUnwrap(router.range(
            of: "exhaustionLatch.exhaust()", range: exhausted.upperBound..<router.endIndex))
        XCTAssertLessThan(exhausted.lowerBound, latch.lowerBound)
        let resetStart = try XCTUnwrap(router.range(of: "func resetPressedBindings()"))
        let resetEnd = try XCTUnwrap(router.range(
            of: "private func makePhysicalEvent", range: resetStart.upperBound..<router.endIndex))
        let reset = String(router[resetStart.lowerBound..<resetEnd.lowerBound])
        var resetCursor = reset.startIndex
        for marker in ["router = RPGPureInputRouter()",
                       "handledEquivalents.removeAll(keepingCapacity: false)",
                       "nextPhysicalRoutingSerial = 0",
                       "routingSerialExhausted = false",
                       "exhaustionLatch.resetInputSession()"] {
            let range = try XCTUnwrap(reset.range(of: marker, range: resetCursor..<reset.endIndex))
            resetCursor = range.upperBound
        }
        XCTAssertTrue(reset.contains("routingSerialExhausted = false"))
        XCTAssertTrue(reset.contains("exhaustionLatch.resetInputSession()"))
        XCTAssertFalse(router.contains("elysiumExhaustedInputDisposition("))
        XCTAssertTrue(router.contains("return source == .keyDown ? routeUnmappedScreenText(event) : false"))
        XCTAssertEqual(router.components(separatedBy: "ElysiumTextEventIngressAdapter.route(").count - 1,
                       2)
        XCTAssertTrue(router.contains("screen.insertText(ui, game, $0)"))
        XCTAssertTrue(router.contains("ui.textIngressMustBeConsumed(for: screen, game: game)"))
        XCTAssertFalse(router.contains("source _: AppKeyEventSource"))
        XCTAssertFalse(router.contains("characters.utf8.count"))
        XCTAssertFalse(router.contains("event.eventNumber"))
        XCTAssertTrue(router.contains("$0.event === event"))
    }

    func testUIManagerOwnsCapabilityReadinessAndAllOrdinaryActivationPaths() throws {
        let manager = try source("Sources/Elysium/UIManagerM.swift")
        for token in ["private init(token: ElysiumTextOwnerToken)",
                      "TextFocusAuthorization.mint(token)",
                      "ElysiumTextFocusTransactionAdapter()",
                      "textFocusTransaction.perform(",
                      "textInputView?.window?.firstResponder === textInputView",
                      "screen.textActivationDescriptorID(self, game)",
                      "screen.placeReadyTextCaret(descriptorID:",
                      "cancelImplicitTextOwnerActivation"] {
            XCTAssertTrue(manager.contains(token), token)
        }
        XCTAssertEqual(manager.components(separatedBy: "TextFocusAuthorization.mint(token)").count - 1,
                       1)
        XCTAssertFalse(manager.contains("focusTextDescriptor(id:"))

        let screens = try source("Sources/Elysium/ScreensM.swift")
        XCTAssertFalse(screens.contains("field.focused = true"))
        for id in ["inventory.recipeQuery", "crafting.recipeQuery", "sign.editor",
                   "template.name", "chat.input"] {
            XCTAssertTrue(screens.contains("textActivationDescriptorID"), id)
            XCTAssertTrue(screens.contains(id), id)
        }
    }

    func testAllShippingFieldsHaveStableUniqueIDsAndLimitsRemainAtCallSites() throws {
        let sources = try ["Sources/Elysium/MenusM.swift", "Sources/Elysium/LANLobbyScreen.swift",
                           "Sources/Elysium/ScreensM.swift"].map(source).joined(separator: "\n")
        let ids = ["create.worldName", "create.seed", "settings.ollamaModel", "lan.player",
                   "lan.hostCode", "lan.hostPort", "lan.joinHost", "lan.joinPort", "lan.joinCode",
                   "anvil.name", "creative.search", "template.name"]
        for id in ids {
            XCTAssertEqual(sources.components(separatedBy: "id: \"\(id)\"").count - 1, 1, id)
        }
        for limit in ["maxLength = 128", "maxLength = 253", "maxLength = 8",
                      "maxLength = 5", "maxLength = OBJECT_TEMPLATE_NAME_MAX"] {
            XCTAssertTrue(sources.contains(limit), limit)
        }
    }

    func testPasteIsOwnerCapturedBoundedAndTextPrecedesTemplatePlacement() throws {
        let main = try source("Sources/Elysium/main.swift")
        let pasteStart = try XCTUnwrap(main.range(of: "@objc func pasteText"))
        let copyStart = try XCTUnwrap(main.range(of: "@objc func copyObjectTemplate", range: pasteStart.upperBound..<main.endIndex))
        let paste = String(main[pasteStart.lowerBound..<copyStart.lowerBound])
        XCTAssertTrue(paste.contains("captureTextOwner"))
        XCTAssertTrue(paste.contains("ElysiumTextPasteIngressAdapter.route"))
        XCTAssertTrue(paste.contains("data(forType: .string)"))
        XCTAssertTrue(paste.contains("data.count <= 65_536"))
        XCTAssertTrue(paste.contains("revalidateTextOwner"))
        XCTAssertEqual(paste.components(separatedBy: "data(forType:").count - 1, 1)

        let commandStart = try XCTUnwrap(main.range(of: "@objc func pasteOrPlaceTemplate"))
        let commandEnd = try XCTUnwrap(main.range(of: "/// AppKit refuses", range: commandStart.upperBound..<main.endIndex))
        let command = String(main[commandStart.lowerBound..<commandEnd.lowerBound])
        XCTAssertLessThan(try XCTUnwrap(command.range(of: "ui?.hasScreen()")).lowerBound,
                          try XCTUnwrap(command.range(of: "performObjectTemplateShortcut")).lowerBound)
    }

    func testCustomOwnersUseOneInsertionPathAndBoundedPolicies() throws {
        let screens = try source("Sources/Elysium/ScreensM.swift")
        XCTAssertFalse(screens.contains("override func onChar"))
        for token in ["inventory.recipeQuery", "crafting.recipeQuery", "sign.editor", "chat.input",
                      "Input limit reached", "Line is full", "Sign text repaired",
                      "Only the host can edit signs.", "maximumCharacters: 2_048",
                      "maximumUTF8Bytes: 16_384", "ChatScreen.history.count > 100"] {
            XCTAssertTrue(screens.contains(token), token)
        }
    }

    func testTextAccessibilityCoexistsWithRPGAndHasNoValueMutationAPI() throws {
        let bridge = try source("Sources/Elysium/TextEntryAccessibilityM.swift")
        let main = try source("Sources/Elysium/main.swift")
        XCTAssertTrue(main.contains("setAccessibilityChildren(textEntryAccessibilityBridge.children +"))
        for token in ["weak var originScreen: Screen?", "presentationGeneration",
                      "setAccessibilitySelectedTextRange", "screen.textScreenIdentity",
                      "screen.textPresentationGeneration",
                      "accessibilityIsAttributeSettable",
                      "attribute == .value || attribute == .selectedTextRange",
                      "elysiumClampTextRect"] {
            XCTAssertTrue(bridge.contains(token), token)
        }
        XCTAssertFalse(bridge.contains("override func setAccessibilityValue"))
        XCTAssertFalse(bridge.contains("accessibilitySetValue"))
        XCTAssertTrue(bridge.contains("func retire()"))
        XCTAssertTrue(bridge.contains("private var elements: [TextEntryAccessibilityElement] = []"))
        XCTAssertFalse(main.contains("override func accessibilityChildren()"))
    }

    func testPackageTopologyHasNormalNonProductSupportTargetAndNoExecutableTestImport() throws {
        let package = try source("Package.swift")
        XCTAssertTrue(package.contains("name: \"ElysiumTextInput\""))
        XCTAssertFalse(package.contains(".library(name: \"ElysiumTextInput\""))
        XCTAssertFalse(package.contains("dependencies: [\"Elysium\"]"))
        let sources = try source("Sources/ElysiumTextInput/ElysiumTextInput.swift")
        XCTAssertFalse(sources.contains("XCTest"))
        XCTAssertFalse(sources.contains("@testable"))
        XCTAssertFalse(sources.contains("ProcessInfo"))
    }

    func testNoSignSpecificLANWireOrReplicationSymbolsWereAdded() throws {
        let tree = try source("Sources/Elysium/ScreensM.swift")
        for forbidden in ["LANSignEditIntent", "LANSignEditResult", "signEditRequestResult",
                          "Saving sign…", "committedRevision", "expectedRevision"] {
            XCTAssertFalse(tree.contains(forbidden), forbidden)
        }
    }

    func testMachineGatesPinOneReleaseBuildBeforeAppKitAndDeploy() throws {
        let script = try source("scripts/pipeline.sh")
        var pipelineCursor = script.startIndex
        for marker in ["scripts/installed-signoff-receipt.sh run-prepare-gates",
                       "scripts/installed-signoff-receipt.sh verify-current",
                       "PENDING_INSTALLED_SIGNOFF", "exit 75"] {
            let range = try XCTUnwrap(script.range(
                of: marker, range: pipelineCursor..<script.endIndex), marker)
            pipelineCursor = range.upperBound
        }
        XCTAssertEqual(script.components(
            separatedBy: "scripts/installed-signoff-receipt.sh run-prepare-gates").count - 1, 1)
        for forbidden in ["swift package clean", "verify-elysium-storage-release-surface.sh",
                          "security-check-binary.sh", "appkit-text-entry-integration.sh",
                          "swift test", "elysmoke", "elysium install", "RELEASE_HASH=",
                          "automated-gates.json", "passedCount", "failedCount", "\"PASS\"",
                          "PASS="] {
            XCTAssertFalse(script.contains(forbidden), forbidden)
        }
        XCTAssertTrue(script.contains("PENDING_INSTALLED_SIGNOFF"))
        XCTAssertTrue(script.contains("exit 75"))

        let receipt = try source("scripts/installed-signoff-receipt.swift")
        let authority = try source("Sources/ElysiumReleaseGate/ReleaseGate.swift")
        let commandStart = try XCTUnwrap(authority.range(of: "case \"run-prepare-gates\":"))
        let commandEnd = try XCTUnwrap(authority.range(
            of: "case \"verify-current\":" , range: commandStart.upperBound..<authority.endIndex))
        let command = String(authority[commandStart.lowerBound..<commandEnd.lowerBound])
        XCTAssertTrue(command.contains("arguments.count == 1"))
        XCTAssertTrue(receipt.contains("ReleaseGateCommandDispatcher("))
        XCTAssertFalse(receipt.contains("case \"prepare\":"))
        let specsStart = try XCTUnwrap(authority.range(of: "private func specs(releaseHash:"))
        let specsEnd = try XCTUnwrap(authority.range(
            of: "func run(receiptDirectory:", range: specsStart.upperBound..<authority.endIndex))
        let specs = String(authority[specsStart.lowerBound..<specsEnd.lowerBound])
        var specsCursor = specs.startIndex
        for id in ["source-security", "release-build", "release-surface", "binary-scan",
                   "appkit-text-entry", "xctest", "elysmoke"] {
            let range = try XCTUnwrap(specs.range(
                of: "commandID: \"\(id)\"", range: specsCursor..<specs.endIndex), id)
            specsCursor = range.upperBound
        }
        let prepareStart = try XCTUnwrap(authority.range(of: "func run(receiptDirectory:"))
        let prepareEnd = try XCTUnwrap(authority.range(
            of: "private func removeValidatedGeneratedReleaseIfPresent",
            range: prepareStart.upperBound..<authority.endIndex))
        let prepare = String(authority[prepareStart.lowerBound..<prepareEnd.lowerBound])
        var prepareCursor = prepare.startIndex
        for marker in ["dependencies.commandRunner().run(", "guard result.status == 0",
                       "if spec.commandID == \"release-build\"", "releaseIdentity = try",
                       "ClosedGateOutputParser.counts(",
                       "DurablePrivateFileWriter.write(result.output",
                       "entries.append(.init(", "gateEvidence.validate(in: automated)",
                       "dependencies.installAndObserve(", "manifest.validate(",
                       "StableFileHasher.revalidate(releaseIdentity)",
                       "LiveProcessKernelIdentityReader.revalidate"] {
            let range = try XCTUnwrap(prepare.range(
                of: marker, range: prepareCursor..<prepare.endIndex), marker)
            prepareCursor = range.upperBound
        }
        let dispatchStart = try XCTUnwrap(authority.range(of: "case .runPrepareGates:"))
        let dispatchEnd = try XCTUnwrap(authority.range(
            of: "case .verifyCurrent:", range: dispatchStart.upperBound..<authority.endIndex))
        let dispatch = String(authority[dispatchStart.lowerBound..<dispatchEnd.lowerBound])
        for marker in ["gate.restart(", "ReleaseGatePreparationWorkflow(",
                       "from: .preparing, to: .prepared", "dependencies.validateCurrent(prepared)",
                       "gate.invalidate()"] {
            XCTAssertTrue(dispatch.contains(marker), marker)
        }
        for marker in ["\"install\", \"--no-build\"", "StableFileHasher.capture(",
                       "waitForBoundElysiumProcess("] {
            XCTAssertTrue(receipt.contains(marker), marker)
        }

        let prepush = try source(".githooks/pre-push")
        XCTAssertTrue(prepush.contains("installed-signoff-receipt.sh prepush"))
        XCTAssertEqual(prepush.components(separatedBy: "installed-signoff-receipt.sh prepush").count - 1, 2)
        for gate in ["scripts/security-scan.sh", "scripts/prepush-release-build.sh", "swift test",
                     "swift run -c release elysmoke"] {
            XCTAssertTrue(prepush.contains(gate), gate)
        }
    }

    func testFailClosedPackagerAndZeroClipboardDriverAreDocumented() throws {
        let packager = try source("scripts/package-app.sh")
        for token in ["cmp -s", "codesign --verify --deep --strict", "Identifier=",
                      "CDHash=", "Sealed Resources version=", "chmod 600"] {
            XCTAssertTrue(packager.contains(token), token)
        }
        XCTAssertFalse(packager.contains("warning:"))
        XCTAssertFalse(packager.contains("warn()"))
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        XCTAssertFalse(driver.contains("NSPasteboard"))
        XCTAssertFalse(driver.contains("pasteboard"))
        XCTAssertFalse(driver.contains("maskCommand"))
    }

    func testAppKitDriverUsesOneShotActionsPreRepairProofAndPerKeyBarriers() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        let expectedIDs = [
            "launch.application",
            "navigation.singleplayer.click", "navigation.create-world.click",
            "world-name.click", "world-name.key.a",
            "finder.activate", "elysium.reactivate", "world-name.reactivation-focus",
            "world-name.key.b", "world-name.key.c", "world-name.key.d",
            "world-name.key.left-1", "world-name.key.left-2", "world-name.key.backspace",
            "seed.focus", "seed.key.7", "world-name.focus",
            "world-name.key.right-1", "world-name.key.right-2",
            "world-name.key.right-saturated", "window.fullscreen.key.f11",
        ]
        for id in expectedIDs {
            XCTAssertEqual(
                driver.components(separatedBy: "\"\(id)\"").count - 1,
                2, id)
        }
        XCTAssertTrue(driver.contains("performed.insert(id).inserted"))
        XCTAssertTrue(driver.contains("performed == expected"))
        XCTAssertFalse(driver.contains("func retire("))

        let waitStart = try XCTUnwrap(driver.range(of: "private func wait("))
        let waitEnd = try XCTUnwrap(driver.range(
            of: "private func axValue", range: waitStart.upperBound..<driver.endIndex))
        let waitBody = String(driver[waitStart.lowerBound..<waitEnd.lowerBound])
        for forbidden in ["activate(", "postMouse", "postKey", "AXUIElementSetAttributeValue"] {
            XCTAssertFalse(waitBody.contains(forbidden), forbidden)
        }

        let validationStart = try XCTUnwrap(driver.range(of: "func validateBeforeAction()"))
        let validationEnd = try XCTUnwrap(driver.range(
            of: "func validateFieldBeforeAction", range: validationStart.upperBound..<driver.endIndex))
        XCTAssertFalse(String(driver[validationStart.lowerBound..<validationEnd.lowerBound])
            .contains("activate("))

        let preservation = try XCTUnwrap(driver.range(of: "gateStage = \"reactivation-preservation\""))
        let settling = try XCTUnwrap(driver.range(
            of: "readyEpoch.settle(", range: preservation.upperBound..<driver.endIndex))
        let proof = try XCTUnwrap(driver.range(
            of: "let preservedSurface = try handoffBoundSurface(nameA)",
            range: settling.upperBound..<driver.endIndex))
        let preserve = try XCTUnwrap(driver.range(
            of: "readyEpoch.preserve(true)", range: proof.upperBound..<driver.endIndex))
        let ready = try XCTUnwrap(driver.range(
            of: "readyEpoch.enterReady()", range: preserve.upperBound..<driver.endIndex))
        let setter = try XCTUnwrap(driver.range(
            of: "setFocusedOnce(\"world-name.reactivation-focus\"",
            range: ready.upperBound..<driver.endIndex))
        let postcondition = try XCTUnwrap(driver.range(
            of: "requireSynchronousState(\"post-reactivation focus\", nameA)",
            range: setter.upperBound..<driver.endIndex))
        XCTAssertLessThan(preservation.lowerBound, settling.lowerBound)
        XCTAssertLessThan(settling.lowerBound, proof.lowerBound)
        XCTAssertLessThan(proof.lowerBound, setter.lowerBound)
        XCTAssertLessThan(preserve.lowerBound, ready.lowerBound)
        XCTAssertLessThan(ready.lowerBound, setter.lowerBound)
        XCTAssertLessThan(setter.lowerBound, postcondition.lowerBound)

        for marker in [
            "nameValue: \"a\", nameRange: 1", "nameValue: \"ab\", nameRange: 2",
            "nameValue: \"abc\", nameRange: 3", "nameValue: \"abcd\", nameRange: 4",
            "nameValue: \"abcd\", nameRange: 3", "nameValue: \"abcd\", nameRange: 2",
            "nameValue: \"acd\", nameRange: 1", "seedValue: \"7\", seedRange: 1",
            "nameValue: \"acd\", nameRange: 2", "nameValue: \"acd\", nameRange: 3",
            "requireSynchronousState(\"world-name right saturated\", nameAtEnd)",
        ] { XCTAssertTrue(driver.contains(marker), marker) }
        for forbidden in ["postToPid", "event.eventNumber", "observed_value",
                          "observed_name_value", "observed_seed_value", "retry"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
        for aggregate in ["observed_name_length", "observed_name_range",
                          "observed_name_focus", "observed_seed_length",
                          "observed_seed_range", "observed_seed_focus"] {
            XCTAssertTrue(driver.contains(aggregate), aggregate)
        }
    }

    func testAppKitReadyEpochSettlesOnceThenFailsFastWithoutRecovery() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        XCTAssertEqual(driver.components(separatedBy: "readyEpoch.settle(").count - 1, 1)
        let readyEpochStart = try XCTUnwrap(driver.range(of: "private final class ReadyEpoch"))
        let readyEpochEnd = try XCTUnwrap(driver.range(
            of: "private func waitFailFast", range: readyEpochStart.upperBound..<driver.endIndex))
        let readyEpochSource = String(
            driver[readyEpochStart.lowerBound..<readyEpochEnd.lowerBound])
        XCTAssertEqual(
            readyEpochSource.components(separatedBy: "consecutiveSamples = 0").count - 1, 2)
        XCTAssertTrue(driver.contains("minimumStableDuration: 0.25"))
        XCTAssertTrue(driver.contains("requiredConsecutiveSamples: 4"))
        XCTAssertTrue(driver.contains("private enum Phase { case settling, preserved, ready, failed }"))
        XCTAssertTrue(driver.contains("guard phase == .ready, exact else"))
        XCTAssertTrue(driver.contains("phase = .failed"))
        XCTAssertTrue(driver.contains("firstPostReadyMismatchIsTerminal([false, true])"))
        XCTAssertTrue(driver.contains("if !sample { return observed == 1 }"))

        for identity in ["NSWorkspace.shared.frontmostApplication",
                         "frontmost?.isEqual(app) == true",
                         "kAXFocusedWindowAttribute", "LaunchPresentationBinding",
                         "axFullScreen", "presentationBinding.displayID",
                         "presentationBinding.cgWindowID", "geometryRetained",
                         "CFEqual(groups[0], reactivationGroup)",
                         "currentFields.contains(where: { CFEqual($0, name) })",
                         "currentFields.contains(where: { CFEqual($0, seed) })"] {
            XCTAssertTrue(driver.contains(identity), identity)
        }
        let semanticStart = try XCTUnwrap(driver.range(of: "func requireSemanticTransition"))
        let semanticEnd = try XCTUnwrap(driver.range(
            of: "try requireFieldState(\"pre-reactivation state\"",
            range: semanticStart.upperBound..<driver.endIndex))
        let semantic = String(driver[semanticStart.lowerBound..<semanticEnd.lowerBound])
        let surface = try XCTUnwrap(semantic.range(
            of: "let surface = try handoffBoundSurface(expected)"))
        let assertion = try XCTUnwrap(semantic.range(
            of: "readyEpoch.assertReady(surface.exact", range: surface.upperBound..<semantic.endIndex))
        let target = try XCTUnwrap(semantic.range(
            of: "fieldStateMatches(expected)", range: assertion.upperBound..<semantic.endIndex))
        XCTAssertLessThan(surface.lowerBound, assertion.lowerBound)
        XCTAssertLessThan(assertion.lowerBound, target.lowerBound)

        XCTAssertGreaterThanOrEqual(driver.components(separatedBy: "finalCheck:").count - 1, 20)
        for token in ["app_not_terminated", "app_pid", "app_bundle", "app_executable",
                      "app_measured_bytes", "active", "frontmost_present",
                      "frontmost_value_equal", "frontmost_pid", "frontmost_bundle",
                      "frontmost_executable", "window_count", "window_identity",
                      "focused_window_identity", "ax_fullscreen_present",
                      "ax_fullscreen_value", "presentation_mode_bound",
                      "containing_display_count_exact", "display_identity",
                      "cg_window_count_exact", "cg_window_identity", "cg_window_onscreen",
                      "cg_window_opaque", "ax_cg_rectangle_equal", "geometry_retained",
                      "group_count", "group_identity", "field_count",
                      "name_identity", "seed_identity", "name_focus", "seed_focus",
                      "field_state_exact"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        for forbidden in ["frontmost?.localizedName", "CGEventTapCreate", "postToPid",
                          "frontmost === app", "frontmost !== app", "fullscreenGeometry",
                          "reactivationScreenFrame", "Thread.sleep", "usleep("] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
        XCTAssertFalse(driver.replacingOccurrences(
            of: "CGDisplayIsAsleep(", with: "CGDisplaySleepState(").contains("sleep("))
    }

    func testAppKitApplicationValueIdentityAndSettlingDiagnosticsAreClosedAndSafe() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        XCTAssertEqual(driver.components(separatedBy: "frontmost?.isEqual(app) == true").count - 1, 6)
        for identity in ["BoundRunningApplicationIdentity", "candidatePID == original.pid",
                         "candidateBundle == original.bundle",
                         "candidateExecutable == original.executable",
                         "measuredSHA256 == original.measuredSHA256",
                         "app.processIdentifier == boundAppIdentity.pid",
                         "(try? hash(stagedExecutable)) == boundAppIdentity.measuredSHA256"] {
            XCTAssertTrue(driver.contains(identity), identity)
        }
        XCTAssertTrue(driver.contains("valueEqual: true"))
        XCTAssertTrue(driver.contains("valueEqual: false"))
        XCTAssertTrue(driver.contains("candidatePID: app.processIdentifier + 1"))
        XCTAssertTrue(driver.contains("candidateBundle: bundleURL.deletingLastPathComponent()"))
        XCTAssertTrue(driver.contains("candidateExecutable: bundleURL"))
        XCTAssertTrue(driver.contains("measuredSHA256: String(repeating: \"0\", count: 64)"))

        let settleStart = try XCTUnwrap(driver.range(of: "func settle(timeout:"))
        let settleEnd = try XCTUnwrap(driver.range(
            of: "func preserve(", range: settleStart.upperBound..<driver.endIndex))
        let settle = String(driver[settleStart.lowerBound..<settleEnd.lowerBound])
        for token in ["lastSample", "totalSamples", "maximumConsecutiveSamples", "everTrue",
                      "everFalse", "_last=", "_ever_true=", "_ever_false=",
                      "total_samples=", "maximum_consecutive_samples=", "fieldAggregate"] {
            XCTAssertTrue(settle.contains(token), token)
        }
        let sample = try XCTUnwrap(driver.range(of: "let sample = SettlingSample("))
        let settleCall = try XCTUnwrap(driver.range(of: "readyEpoch.settle("))
        XCTAssertGreaterThan(sample.lowerBound, settleCall.lowerBound)
        for forbidden in ["localizedName", "debugDescription", "fieldValue", "eventData",
                          "clipboard", "NSPasteboard"] {
            XCTAssertFalse(settle.contains(forbidden), forbidden)
        }
        XCTAssertFalse(driver.contains("CGDisplayBounds($0) == fullscreenRectangle"))
        XCTAssertFalse(driver.contains("fullscreenRectangle == fullscreenDisplayBounds"))
        XCTAssertFalse(driver.contains("visibleFrame"))
        XCTAssertTrue(driver.contains("CGDisplayBounds($0).contains(rectangle)"))
    }

    func testAppKitPresentationBindingUsesTypedModeVisibleFallbackAndOppositeF11() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        let binding = try XCTUnwrap(driver.range(
            of: "let presentationBinding = try launchSettlement.settle("))
        let title = try XCTUnwrap(driver.range(
            of: "gateStage = \"title-navigation\"", range: binding.upperBound..<driver.endIndex))
        XCTAssertLessThan(binding.lowerBound, title.lowerBound)
        for token in ["CFGetTypeID(raw) == CFBooleanGetTypeID()",
                      "LaunchPresentationMode.fullscreen : .windowedFallback",
                      "candidateMode == .fullscreen ||",
                      "displays.count == 1", "cgWindows.count == 1",
                      "CGDisplayBounds($0).contains(candidateRectangle)",
                      "(row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0",
                      "kCGWindowOwnerPID", "kCGWindowIsOnscreen", "kCGWindowAlpha",
                      "kAXStandardWindowSubrole", "postbindRehashExact",
                      "launchPresentationRetained()", "presentation_binding_retained=false",
                      "let oppositeMode = presentationBinding.mode.opposite",
                      "currentMode == presentationBinding.mode", "!sawOppositeMode",
                      "currentMode == oppositeMode", "oppositeConsecutive >= 4"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        XCTAssertTrue(driver.contains(
            "private static let preFallbackDuration: TimeInterval = 8.1"))
        XCTAssertTrue(driver.contains("cgWindows[0].alpha == 1.0"))
        for forbidden in ["CGDisplayBounds($0) == fullscreenRectangle",
                          "fullscreenRectangle == fullscreenDisplayBounds", "visibleFrame",
                          "epsilon"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
        XCTAssertTrue(driver.contains("case fullscreen"))
        XCTAssertTrue(driver.contains("case windowedFallback"))
        XCTAssertTrue(driver.contains("self == .fullscreen ? .windowedFallback : .fullscreen"))
    }

    func testLaunchActivationIsProductOwnedOneShotAtTruthfulReveal() throws {
        let main = try source("Sources/Elysium/main.swift")
        for token in ["final class LaunchActivationAtRevealCoordinator",
                      "ElysiumLaunchActivationState<ObjectIdentifier>",
                      "ElysiumLaunchRevealToken<ObjectIdentifier>",
                      "window.alphaValue == 1", "window.isVisible", "window.level == .normal",
                      "!window.ignoresMouseEvents", "window.screen.map",
                      "$0.frame.contains(frame)", "frame.width > 0", "frame.height > 0",
                      "guard decision == .request else { return }", "NSApp.activate()",
                      "kind: .fullscreen", "kind: .windowedFallback",
                      "enteredWindow.alphaValue == 1", "if fsChecks >= 5",
                      "if NSApp.isActive", "window.orderFront(nil)",
                      "func applicationDidBecomeActive", "window.makeKey()",
                      "window.makeFirstResponder(gameView)", "window.isKeyWindow",
                      "publishedAccessibilityFocusEpoch != activationEpoch",
                      "retainedAccessibilityFocusTarget()"] {
            XCTAssertTrue(main.contains(token), token)
        }
        XCTAssertEqual(main.components(separatedBy: "NSApp.activate()").count - 1, 1)
        XCTAssertFalse(main.contains("activate(ignoringOtherApps:"))
        XCTAssertFalse(main.contains("activateAllWindows"))

        let support = try source("Sources/ElysiumAppSupport/ElysiumAppSupport.swift")
        let consume = try XCTUnwrap(support.range(of: "public mutating func consume("))
        let input = try XCTUnwrap(support.range(
            of: "public enum ElysiumAppInputEntrySource", range: consume.upperBound..<support.endIndex))
        let authority = String(support[consume.lowerBound..<input.lowerBound])
        let close = try XCTUnwrap(authority.range(of: "isClosed = true"))
        let request = try XCTUnwrap(authority.range(of: "return applicationActive ? .noRequest : .request"))
        XCTAssertLessThan(close.lowerBound, request.lowerBound)

        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        XCTAssertTrue(driver.contains("configuration.activates = true"))
        for forbidden in ["LaunchActivationBranch", "launch.activate",
                          "app.activate(options: [])", "beginInactiveDecisionSample",
                          "recordLaunchActivationResult"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
    }

    func testConditionalDenialClickIsClosedOneShotAndNonshipping() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in ["enum ConditionalLaunchDenialState", "case unresolved",
                      "case skippedSystemGranted", "case armedDeniedClick",
                      "case performedDeniedClick",
                      "func armSyntheticDenialClick(lease:",
                      "denialConsecutive >= 2", "now - first >= 0.25",
                      "let adjacentDisposition = try commonModeLaunchDisposition()",
                      "CGPreflightPostEventAccess()", "PreparedDeniedClick(point:",
                      "try handoffLedger.armSyntheticDenialClick",
                      "try conditionalLaunchAction.close(.armedDeniedClick)",
                      "executeConditionalDenialAction(", "try conditionalLaunchAction.markPerformed()",
                      "launch_activation_path=", "synthetic_provenance=automation_only"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        XCTAssertFalse(driver.contains("func retire("))
        XCTAssertFalse(driver.contains("CGRequestPostEventAccess"))

        let conditionalStart = try XCTUnwrap(driver.range(
            of: "let conditionalLaunchAction = ConditionalLaunchDenialAction()"))
        let settlement = try XCTUnwrap(driver.range(
            of: "let launchSettlement = LaunchPresentationSettlement()",
            range: conditionalStart.upperBound..<driver.endIndex))
        let conditional = String(driver[conditionalStart.lowerBound..<settlement.lowerBound])
        for forbidden in ["activate(", "AXUIElementSetAttributeValue",
                          "AXUIElementPerformAction", "keyboardEventSource", "while true",
                          "postMouseOnce(", "postKeyOnce("] {
            XCTAssertFalse(conditional.contains(forbidden), forbidden)
        }
        let prepare = try XCTUnwrap(conditional.range(of: "PreparedDeniedClick(point:"))
        let arm = try XCTUnwrap(conditional.range(
            of: "armSyntheticDenialClick", range: prepare.upperBound..<conditional.endIndex))
        let close = try XCTUnwrap(conditional.range(
            of: "close(.armedDeniedClick)", range: arm.upperBound..<conditional.endIndex))
        let post = try XCTUnwrap(conditional.range(
            of: "executeConditionalDenialAction(", range: close.upperBound..<conditional.endIndex))
        XCTAssertLessThan(prepare.lowerBound, arm.lowerBound)
        XCTAssertLessThan(arm.lowerBound, close.lowerBound)
        XCTAssertLessThan(close.lowerBound, post.lowerBound)

        let preparedStart = try XCTUnwrap(driver.range(of: "private final class PreparedDeniedClick"))
        let fullSnapshot = try XCTUnwrap(driver.range(
            of: "private struct LaunchFullSnapshot", range: preparedStart.upperBound..<driver.endIndex))
        let prepared = String(driver[preparedStart.lowerBound..<fullSnapshot.lowerBound])
        XCTAssertEqual(prepared.components(separatedBy: "mouseType: .leftMouseDown").count - 1, 1)
        XCTAssertEqual(prepared.components(separatedBy: "mouseType: .leftMouseUp").count - 1, 1)
        XCTAssertEqual(prepared.components(separatedBy: ".mouseEventClickState").count - 1, 2)
        XCTAssertEqual(prepared.components(separatedBy: "down?.post(tap: .cghidEventTap)").count - 1, 1)
        XCTAssertEqual(prepared.components(separatedBy: "up?.post(tap: .cghidEventTap)").count - 1, 1)

        let package = try source("Package.swift")
        XCTAssertFalse(package.contains("Tests/ElysiumAppKitIntegration"))
        let shipping = try ["Sources/Elysium/main.swift", "Sources/Elysium/AppInputRouterM.swift"]
            .map(source).joined(separator: "\n")
        for forbidden in ["CGEvent(mouseEventSource:", "CGRequestPostEventAccess",
                          "postZeroDragPair", "ConditionalLaunchDenial"] {
            XCTAssertFalse(shipping.contains(forbidden), forbidden)
        }
    }

    func testConditionalDenialCoordinateAndLifecycleFixtureMatrix() throws {
        struct CoordinateFixture {
            let display: CGRect
            let screen: CGRect
            let window: CGRect
            let chrome: CGFloat

            func point() -> CGPoint? {
                guard display.contains(window), display != window, chrome > 0,
                      chrome < window.height, window.width > 192 else { return nil }
                let appFrame = CGRect(
                    x: screen.minX + window.minX - display.minX,
                    y: screen.maxY - (window.maxY - display.minY),
                    width: window.width, height: window.height)
                let appPoint = CGPoint(x: appFrame.midX, y: appFrame.maxY - chrome / 2)
                let cgPoint = CGPoint(
                    x: display.minX + appPoint.x - screen.minX,
                    y: display.minY + screen.maxY - appPoint.y)
                let roundTrip = CGPoint(
                    x: screen.minX + cgPoint.x - display.minX,
                    y: screen.maxY - (cgPoint.y - display.minY))
                guard abs(roundTrip.x - appPoint.x) <= 0.5,
                      abs(roundTrip.y - appPoint.y) <= 0.5,
                      window.contains(cgPoint), display.contains(cgPoint),
                      cgPoint.x > window.minX + 96, cgPoint.x < window.maxX - 96,
                      cgPoint.y > window.minY, cgPoint.y < window.minY + chrome else { return nil }
                return cgPoint
            }
        }
        for fixture in [
            CoordinateFixture(
                display: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                window: CGRect(x: 240, y: 120, width: 1440, height: 810), chrome: 28),
            CoordinateFixture(
                display: CGRect(x: -1600, y: -200, width: 1600, height: 1000),
                screen: CGRect(x: -1600, y: 80, width: 1600, height: 1000),
                window: CGRect(x: -1450, y: -80, width: 1100, height: 700), chrome: 30),
            CoordinateFixture(
                display: CGRect(x: 1920, y: 120, width: 2560, height: 1440),
                screen: CGRect(x: 1920, y: -360, width: 2560, height: 1440),
                window: CGRect(x: 2200, y: 300, width: 1600, height: 900), chrome: 32),
        ] {
            XCTAssertNotNil(fixture.point())
        }
        XCTAssertNil(CoordinateFixture(
            display: CGRect(x: 0, y: 0, width: 1000, height: 800),
            screen: CGRect(x: 0, y: 0, width: 1000, height: 800),
            window: CGRect(x: 0, y: 0, width: 1000, height: 800), chrome: 28).point())
        XCTAssertNil(CoordinateFixture(
            display: CGRect(x: 0, y: 0, width: 1000, height: 800),
            screen: CGRect(x: 0, y: 0, width: 1000, height: 800),
            window: CGRect(x: 20, y: 20, width: 180, height: 300), chrome: 28).point())

        enum State { case unresolved, skipped, clicked, terminal }
        enum Event { case targetActivate, predecessorDeactivate, foreign }
        func reduce(_ initial: State, grant: Bool, denialSamples: Int,
                    adjacentDenial: Bool, events: [Event]) -> State {
            guard initial == .unresolved else { return .terminal }
            if grant { return events.isEmpty ? .skipped : .terminal }
            guard denialSamples >= 2, adjacentDenial else { return .terminal }
            guard events.count == 2,
                  Set(events.map { String(describing: $0) }) ==
                    Set([String(describing: Event.targetActivate),
                         String(describing: Event.predecessorDeactivate)]) else { return .terminal }
            return .clicked
        }
        XCTAssertEqual(reduce(.unresolved, grant: true, denialSamples: 0,
                              adjacentDenial: false, events: []), .skipped)
        for order in [[Event.targetActivate, .predecessorDeactivate],
                      [Event.predecessorDeactivate, .targetActivate]] {
            XCTAssertEqual(reduce(.unresolved, grant: false, denialSamples: 2,
                                  adjacentDenial: true, events: order), .clicked)
        }
        let invalidEvents: [[Event]] = [[], [.targetActivate],
            [.foreign, .predecessorDeactivate], [.targetActivate, .targetActivate],
            [.targetActivate, .predecessorDeactivate, .foreign]]
        for events in invalidEvents {
            XCTAssertEqual(reduce(.unresolved, grant: false, denialSamples: 2,
                                  adjacentDenial: true, events: events), .terminal)
        }
    }

    func testConditionalDenialV15ClosesPairBeforeDenialObservationAndOneBoundedAXSnapshot() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in ["enum LaunchShippingPhase", "case hiddenAlphaZero",
                      "case visibleAlphaOne", "case ambiguous",
                      "private let deniedAXDescendantCap = 768",
                      "private struct DeniedAXSnapshot",
                      "boundedDescendants(application, cap: deniedAXDescendantCap)",
                      "axSnapshotTruncated", "ax_snapshot_not_truncated",
                      "case .attributeUnsupported, .noValue:",
                      "if lease.authority == .expectedPairSurface",
                      "cheap.shippingPhase != .visibleAlphaOne",
                      "candidate_id_equal", "candidate_rectangle_equal",
                      "candidate_alpha_equal", "candidate_display_equal",
                      "candidate_titlebar_point_equal", "candidate_titlebar_band_equal",
                      "candidate_private_tuple_equal", "shipping_phase=",
                      "sample_duration_ms=", "first_eligible_offset_ms="] {
            XCTAssertTrue(driver.contains(token), token)
        }

        let cheapStart = try XCTUnwrap(driver.range(of: "func launchCheapObservation(lease:"))
        let denialStart = try XCTUnwrap(driver.range(
            of: "func launchDenialObservation(", range: cheapStart.upperBound..<driver.endIndex))
        let cheap = String(driver[cheapStart.lowerBound..<denialStart.lowerBound])
        for forbidden in ["axValue(", "axElement(", "descendants(",
                          "boundedDescendants(", "DeniedAXSnapshot.capture"] {
            XCTAssertFalse(cheap.contains(forbidden), forbidden)
        }
        for required in ["visibleCGOwnerWindows", "DisplayAuthoritySnapshot.capture()",
                         "CGPreflightPostEventAccess()"] {
            XCTAssertTrue(cheap.contains(required), required)
        }
        XCTAssertTrue(driver.contains("return .hiddenAlphaZero"))
        XCTAssertTrue(driver.contains("return .visibleAlphaOne"))

        let commonStart = try XCTUnwrap(driver.range(of: "func commonModeLaunchDisposition()"))
        let gateStart = try XCTUnwrap(driver.range(
            of: "gateStage = \"launch-settle\"", range: commonStart.upperBound..<driver.endIndex))
        let common = String(driver[commonStart.lowerBound..<gateStart.lowerBound])
        let begin = try XCTUnwrap(common.range(of: "beginLaunchSettlementSample()"))
        let pairFirst = try XCTUnwrap(common.range(
            of: "if lease.authority == .expectedPairSurface",
            range: begin.upperBound..<common.endIndex))
        let pairFinish = try XCTUnwrap(common.range(
            of: "finishLaunchSettlementSample(lease: lease)",
            range: pairFirst.upperBound..<common.endIndex))
        let cheapCapture = try XCTUnwrap(common.range(
            of: "launchCheapObservation(lease:", range: pairFinish.upperBound..<common.endIndex))
        let snapshot = try XCTUnwrap(common.range(
            of: "DeniedAXSnapshot.capture(application: axApp)",
            range: cheapCapture.upperBound..<common.endIndex))
        XCTAssertLessThan(begin.lowerBound, pairFirst.lowerBound)
        XCTAssertLessThan(pairFirst.lowerBound, pairFinish.lowerBound)
        XCTAssertLessThan(pairFinish.lowerBound, cheapCapture.lowerBound)
        XCTAssertLessThan(cheapCapture.lowerBound, snapshot.lowerBound)
        let pairBranch = String(common[pairFirst.lowerBound..<cheapCapture.lowerBound])
        for forbidden in ["visibleCGOwnerWindows", "DisplayAuthoritySnapshot.capture",
                          "CGPreflightPostEventAccess", "DeniedAXSnapshot.capture", "CGEvent("] {
            XCTAssertFalse(pairBranch.contains(forbidden), forbidden)
        }
        XCTAssertEqual(common.components(
            separatedBy: "DeniedAXSnapshot.capture(application: axApp)").count - 1, 1)
        XCTAssertEqual(common.components(separatedBy: "boundedDescendants").count - 1, 0)

        let snapshotStart = try XCTUnwrap(driver.range(of: "private struct DeniedAXSnapshot"))
        let denialStruct = try XCTUnwrap(driver.range(
            of: "private struct LaunchDenialObservation",
            range: snapshotStart.upperBound..<driver.endIndex))
        let snapshotBody = String(driver[snapshotStart.lowerBound..<denialStruct.lowerBound])
        XCTAssertEqual(snapshotBody.components(separatedBy: "boundedDescendants(").count - 1, 1)
        XCTAssertTrue(snapshotBody.contains("bounded.truncated ? nil"))
        XCTAssertTrue(driver.contains("!axSnapshotTruncated && privateState?.text.isEmpty == true"))

        let conditionalStart = try XCTUnwrap(driver.range(
            of: "let conditionalLaunchAction = ConditionalLaunchDenialAction()"))
        let firstConsecutive = try XCTUnwrap(driver.range(
            of: "denialConsecutive = 1", range: conditionalStart.upperBound..<driver.endIndex))
        let firstRecord = try XCTUnwrap(driver.range(
            of: "denialDiagnostics.record(", range: firstConsecutive.upperBound..<driver.endIndex))
        let increment = try XCTUnwrap(driver.range(
            of: "denialConsecutive += 1", range: firstRecord.upperBound..<driver.endIndex))
        let laterRecord = try XCTUnwrap(driver.range(
            of: "denialDiagnostics.record(", range: increment.upperBound..<driver.endIndex))
        XCTAssertLessThan(firstConsecutive.lowerBound, firstRecord.lowerBound)
        XCTAssertLessThan(increment.lowerBound, laterRecord.lowerBound)
    }

    func testConditionalDenialV19OneShotBudgetBoundaryAndSourceOrdering() throws {
        struct Budget {
            static let old = 8.1, extensionDuration = 4.0, cap = 10.5
            let start: Double, oldDeadline: Double, hardDeadline: Double
            var anchor: Double?, deadline: Double?

            init?(_ start: Double) {
                guard start.isFinite, start >= 0 else { return nil }
                let oldDeadline = start + Self.old
                let hardDeadline = start + Self.cap
                guard oldDeadline.isFinite, hardDeadline.isFinite,
                      oldDeadline > start, hardDeadline > oldDeadline else { return nil }
                self.start = start
                self.oldDeadline = oldDeadline
                self.hardDeadline = hardDeadline
            }

            mutating func install(_ recordedStart: Double) -> Bool {
                if deadline != nil { return true }
                guard recordedStart.isFinite, recordedStart >= start,
                      recordedStart <= oldDeadline else { return false }
                let extended = recordedStart + Self.extensionDuration
                guard extended.isFinite, extended > recordedStart else { return false }
                let value = min(extended, hardDeadline)
                guard value >= recordedStart, value <= hardDeadline else { return false }
                anchor = recordedStart
                deadline = value
                return true
            }

            var effective: Double { deadline ?? oldDeadline }
            func contains(_ instant: Double) -> Bool {
                instant.isFinite && instant >= start && instant <= effective
            }
        }

        XCTAssertEqual(Budget.old, 8.1)
        XCTAssertEqual(Budget.extensionDuration, 4.0)
        XCTAssertEqual(Budget.cap, 10.5)
        XCTAssertEqual(Budget(0)?.effective, 8.1)
        for (anchor, expected) in [(6.1, 10.1), (6.5, 10.5), (8.1, 10.5)] {
            var budget = try XCTUnwrap(Budget(0))
            XCTAssertTrue(budget.install(anchor))
            XCTAssertEqual(budget.effective, expected)
            XCTAssertLessThanOrEqual(budget.effective, budget.hardDeadline)
        }
        for invalid in [8.100001, -1.0, .nan, .infinity,
                        Double.greatestFiniteMagnitude] {
            var budget = try XCTUnwrap(Budget(0))
            XCTAssertFalse(budget.install(invalid))
            XCTAssertEqual(budget.effective, 8.1)
        }
        for invalid in [-1.0, .nan, .infinity, Double.greatestFiniteMagnitude] {
            XCTAssertNil(Budget(invalid))
        }
        var immutable = try XCTUnwrap(Budget(0))
        XCTAssertTrue(immutable.install(6.1))
        let firstAnchor = try XCTUnwrap(immutable.anchor).bitPattern
        let firstDeadline = immutable.effective.bitPattern
        for mutationOrResetAttempt in [6.5, 0, 8.1, .nan] {
            XCTAssertTrue(immutable.install(mutationOrResetAttempt))
            XCTAssertEqual(immutable.anchor?.bitPattern, firstAnchor)
            XCTAssertEqual(immutable.effective.bitPattern, firstDeadline)
        }
        XCTAssertTrue(immutable.contains(immutable.effective))
        XCTAssertFalse(immutable.contains(immutable.effective.nextUp))
        func reserve(_ remaining: Double) -> Bool { remaining >= 0.100 }
        XCTAssertTrue(reserve(0.100))
        XCTAssertFalse(reserve(0.099))

        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in [
            "private struct ConditionalDenialTimingBudget",
            "private static let preFallbackDuration: TimeInterval = 8.1",
            "private static let eligibleDenialDuration: TimeInterval = 4.0",
            "private static let hardCapDuration: TimeInterval = 10.5",
            "recordedStart: sample.startedAt)",
            "conditionalDenialTimingBudget.anchoredDeadline",
            "deadline: conditionalDenialDeadline",
            "inputMayHaveOccurred = true", "postDownAction()",
            "no_synthetic_click_sent=true verification_set_stopped=true",
            "input_may_have_occurred=true result_invalid=true verification_set_stopped=true",
            "Conditional denial action and presentation budget self-test: PASS cases=52",
            "budget_anchor_offset_ms=", "budget_deadline_offset_ms=",
            "budget_hard_cap_offset_ms=",
        ] { XCTAssertTrue(driver.contains(token), token) }

        let budgetStart = try XCTUnwrap(driver.range(
            of: "private struct ConditionalDenialTimingBudget"))
        let budgetEnd = try XCTUnwrap(driver.range(
            of: "private enum ConditionalLaunchDenialState", range: budgetStart.upperBound..<driver.endIndex))
        let budgetSource = String(driver[budgetStart.lowerBound..<budgetEnd.lowerBound])
        for forbidden in ["+=", " max(", "reset", "rearm", "retry", "Sources/Elysium"] {
            XCTAssertFalse(budgetSource.contains(forbidden), forbidden)
        }

        let runtimeStart = try XCTUnwrap(driver.range(
            of: "let conditionalLaunchAction = ConditionalLaunchDenialAction()"))
        let runtimeEnd = try XCTUnwrap(driver.range(
            of: "gateStage = \"title-navigation\"", range: runtimeStart.upperBound..<driver.endIndex))
        let runtime = String(driver[runtimeStart.lowerBound..<runtimeEnd.lowerBound])
        XCTAssertEqual(runtime.components(
            separatedBy: "recordedStart: sample.startedAt)").count - 1, 1)
        let eligibility = try XCTUnwrap(runtime.range(of: "guard denial.eligible else"))
        let anchorSite = try XCTUnwrap(runtime.range(
            of: "recordedStart: sample.startedAt)"))
        XCTAssertLessThan(eligibility.lowerBound, anchorSite.lowerBound)
        XCTAssertEqual(runtime.components(separatedBy: "inputMayHaveOccurred = true").count - 1, 0)

        let actionStart = try XCTUnwrap(driver.range(
            of: "fileprivate func execute("))
        let actionEnd = try XCTUnwrap(driver.range(
            of: "private func executeConditionalDenialAction(",
            range: actionStart.upperBound..<driver.endIndex))
        let action = String(driver[actionStart.lowerBound..<actionEnd.lowerBound])
        let latch = try XCTUnwrap(action.range(of: "inputMayHaveOccurred = true"))
        let firstPost = try XCTUnwrap(action.range(of: "postDownAction()"))
        XCTAssertLessThan(latch.lowerBound, firstPost.lowerBound)
        XCTAssertEqual(action.components(separatedBy: "inputMayHaveOccurred = true").count - 1, 1)
        XCTAssertEqual(action.components(separatedBy: "postDownAction()").count - 1, 1)
        XCTAssertFalse(runtime.contains("retry"))
        XCTAssertFalse(runtime.contains("resume"))
    }

    func testLaunchPresentationV21BarrierBoundariesAndSourceOrdering() throws {
        struct Budget {
            let notBefore: Double, deadline: Double, hardCap: Double, started: Double
            init?(conditional: Double, presentation: Double) {
                guard conditional.isFinite, conditional >= 0,
                      presentation.isFinite, presentation >= conditional else { return nil }
                let notBefore = conditional + 6.1
                let postBarrier = notBefore + 4.0
                let hardCap = presentation + 12.5
                guard notBefore.isFinite, notBefore > conditional,
                      postBarrier.isFinite, postBarrier > notBefore,
                      hardCap.isFinite, hardCap > presentation else { return nil }
                let deadline = min(postBarrier, hardCap)
                guard deadline >= presentation, deadline >= notBefore else { return nil }
                self.notBefore = notBefore; self.deadline = deadline
                self.hardCap = hardCap; self.started = presentation
            }
            func live(_ value: Double) -> Bool {
                value.isFinite && value >= started && value <= deadline
            }
            func open(_ value: Double) -> Bool { live(value) && value >= notBefore }
        }

        let initial = try XCTUnwrap(Budget(conditional: 0, presentation: 0))
        XCTAssertEqual(initial.notBefore, 6.1)
        XCTAssertFalse(initial.open(6.099))
        XCTAssertTrue(initial.open(6.100))
        XCTAssertTrue(initial.live(initial.deadline))
        XCTAssertFalse(initial.live(initial.deadline.nextUp))
        let late = try XCTUnwrap(Budget(conditional: 0, presentation: 7))
        XCTAssertTrue(late.open(7))
        XCTAssertEqual(late.deadline, 10.1)
        XCTAssertNotNil(Budget(conditional: 0, presentation: 10.1))
        XCTAssertNil(Budget(conditional: 0, presentation: 10.1.nextUp))
        for pair in [(-1.0, 0.0), (.nan, 0.0), (.infinity, 0.0),
                     (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
                     (1.0, 0.0), (0.0, .nan), (0.0, .infinity),
                     (0.0, Double.greatestFiniteMagnitude)] {
            XCTAssertNil(Budget(conditional: pair.0, presentation: pair.1))
        }

        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in [
            "private static let shippingNotBeforeDuration: TimeInterval = 6.1",
            "private static let postBarrierDuration: TimeInterval = 4.0",
            "private static let hardCapDuration: TimeInterval = 12.5",
            "conditionalSamplingStarted: conditionalSamplingStarted",
            "presentationSamplingStarted: presentationSamplingStart",
            "waitForLaunchPresentationBarrier(launchPresentationTimingBudget)",
            "mode: .common", "budget: launchPresentationTimingBudget",
            "try requireBudget(fastSampleCompleted)",
            "try requireBudget(commitCompleted)",
            "presentation_budget_not_before_offset_ms=",
            "Conditional denial action and presentation budget self-test: PASS cases=52",
        ] { XCTAssertTrue(driver.contains(token), token) }
        XCTAssertFalse(driver.contains("presentation_budget_anchor_offset_ms="))

        let budgetStart = try XCTUnwrap(driver.range(
            of: "private final class LaunchPresentationTimingBudget"))
        let budgetEnd = try XCTUnwrap(driver.range(
            of: "private func runLaunchPresentationTimingBudgetSelfTest()",
            range: budgetStart.upperBound..<driver.endIndex))
        let budgetSource = String(driver[budgetStart.lowerBound..<budgetEnd.lowerBound])
        XCTAssertFalse(budgetSource.contains("anchorFirstEligibleSample("))
        for forbidden in ["+=", "restart", "rearm", "retry", "activate", "permission",
                          "clipboard", "Sources/Elysium", "CGEvent", "ConditionalDenial",
                          "beginLaunchSettlementSample", "beginSample", "fastSample",
                          "fullSnapshot", "candidate", "record("] {
            XCTAssertFalse(budgetSource.contains(forbidden), forbidden)
        }

        let terminal = try XCTUnwrap(driver.range(
            of: "conditionalLaunchAction.state == .skippedSystemGranted ||"))
        let construction = try XCTUnwrap(driver.range(
            of: "LaunchPresentationTimingBudget(", range: terminal.upperBound..<driver.endIndex))
        let barrier = try XCTUnwrap(driver.range(
            of: "waitForLaunchPresentationBarrier(launchPresentationTimingBudget)",
            range: construction.upperBound..<driver.endIndex))
        let settlement = try XCTUnwrap(driver.range(
            of: "let presentationBinding = try launchSettlement.settle(",
            range: barrier.upperBound..<driver.endIndex))
        XCTAssertLessThan(terminal.lowerBound, construction.lowerBound)
        XCTAssertLessThan(construction.lowerBound, barrier.lowerBound)
        XCTAssertLessThan(barrier.lowerBound, settlement.lowerBound)
        let runtime = String(driver[terminal.lowerBound..<settlement.upperBound])
        XCTAssertEqual(runtime.components(
            separatedBy: "LaunchPresentationTimingBudget(").count - 1, 1)
        XCTAssertEqual(runtime.components(
            separatedBy: "waitForLaunchPresentationBarrier(").count - 1, 1)
        XCTAssertFalse(runtime.contains("deadline: conditionalDenialTimingBudget.effectiveDeadline"))

        let barrierStart = try XCTUnwrap(driver.range(
            of: "private func waitForLaunchPresentationBarrier("))
        let barrierEnd = try XCTUnwrap(driver.range(
            of: "private func runLaunchPresentationTimingBudgetSelfTest()",
            range: barrierStart.upperBound..<driver.endIndex))
        let barrierSource = String(driver[barrierStart.lowerBound..<barrierEnd.lowerBound])
        for forbidden in ["beginLaunchSettlementSample", "beginSample", "fastSample",
                          "fullSnapshot", "CGWindow", "Display", "predicate", "candidate",
                          "rehash", "consecutive", "stability"] {
            XCTAssertFalse(barrierSource.contains(forbidden), forbidden)
        }
        XCTAssertTrue(driver.contains("deadline: conditionalDenialDeadline"))
    }

    func testConditionalDenialV15BoundAndExecutableDeadlineBoundaryMatrices() throws {
        struct BoundResult: Equatable {
            let values: [Int]
            let truncated: Bool
        }
        func bounded(_ graph: [[Int]], cap: Int) -> BoundResult {
            guard cap > 0 else { return BoundResult(values: [], truncated: true) }
            var result: [Int] = [], queue = [0], index = 0
            while index < queue.count {
                let node = queue[index]
                index += 1
                for child in graph[node] {
                    guard result.count < cap else {
                        return BoundResult(values: result, truncated: true)
                    }
                    result.append(child)
                    queue.append(child)
                }
            }
            return BoundResult(values: result, truncated: false)
        }
        func chain(descendants: Int) -> [[Int]] {
            (0...descendants).map { index in
                index < descendants ? [index + 1] : []
            }
        }
        let cap = 768
        XCTAssertEqual(bounded(chain(descendants: cap - 1), cap: cap),
                       BoundResult(values: Array(1..<cap), truncated: false))
        XCTAssertEqual(bounded(chain(descendants: cap), cap: cap),
                       BoundResult(values: Array(1...cap), truncated: false))
        let over = bounded(chain(descendants: cap + 1), cap: cap)
        XCTAssertEqual(over.values.count, cap)
        XCTAssertTrue(over.truncated)
        let wide = bounded([Array(1...(cap + 1))] + Array(repeating: [], count: cap + 1), cap: cap)
        XCTAssertEqual(wide.values.count, cap)
        XCTAssertTrue(wide.truncated)

        func hasReserve(milliseconds: Int) -> Bool {
            Double(milliseconds) / 1_000 >= 0.100
        }
        XCTAssertFalse(hasReserve(milliseconds: 99))
        XCTAssertTrue(hasReserve(milliseconds: 100))
        XCTAssertTrue(hasReserve(milliseconds: 101))
        func completed(end: UInt64, deadline: UInt64) -> Bool { end <= deadline }
        XCTAssertTrue(completed(end: 1_000_000, deadline: 1_000_000))
        XCTAssertFalse(completed(end: 1_000_001, deadline: 1_000_000))

        struct Fingerprint: Equatable {
            let id: Int
            let rectangle: Int
            let onScreen: Bool
            let alpha: Int
            let display: Int
            let titlebarPoint: Int
            let titlebarBand: Int
            let privateTuple: Int
        }
        let fingerprint = Fingerprint(
            id: 1, rectangle: 2, onScreen: true, alpha: 1, display: 3,
            titlebarPoint: 4, titlebarBand: 5, privateTuple: 6)
        let mutations = [
            Fingerprint(id: 9, rectangle: 2, onScreen: true, alpha: 1, display: 3,
                        titlebarPoint: 4, titlebarBand: 5, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 9, onScreen: true, alpha: 1, display: 3,
                        titlebarPoint: 4, titlebarBand: 5, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 2, onScreen: false, alpha: 1, display: 3,
                        titlebarPoint: 4, titlebarBand: 5, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 2, onScreen: true, alpha: 9, display: 3,
                        titlebarPoint: 4, titlebarBand: 5, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 2, onScreen: true, alpha: 1, display: 9,
                        titlebarPoint: 4, titlebarBand: 5, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 2, onScreen: true, alpha: 1, display: 3,
                        titlebarPoint: 9, titlebarBand: 5, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 2, onScreen: true, alpha: 1, display: 3,
                        titlebarPoint: 4, titlebarBand: 9, privateTuple: 6),
            Fingerprint(id: 1, rectangle: 2, onScreen: true, alpha: 1, display: 3,
                        titlebarPoint: 4, titlebarBand: 5, privateTuple: 9),
        ]
        XCTAssertTrue(mutations.allSatisfy { $0 != fingerprint })
        let phases: [(alpha: Int, time: Double, value: Fingerprint)] = [
            (0, 0.00, fingerprint), (1, 0.10, fingerprint),
            (1, 0.36, fingerprint), (1, 0.40, fingerprint),
        ]
        var candidate: Fingerprint?, first: Double?, consecutive = 0, adjacent = false
        for phase in phases {
            guard phase.alpha == 1 else {
                candidate = nil; first = nil; consecutive = 0; continue
            }
            if candidate != phase.value {
                candidate = phase.value; first = phase.time; consecutive = 1; continue
            }
            consecutive += 1
            if consecutive >= 2, phase.time - (first ?? phase.time) >= 0.25 {
                adjacent = true
            }
        }
        XCTAssertTrue(adjacent)

        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elysium-driver-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let compile = Process(), compileOutput = Pipe()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", root.appendingPathComponent(
            "Tests/ElysiumAppKitIntegration/Driver.swift").path, "-o", temporary.path,
            "-framework", "AppKit", "-framework", "ApplicationServices",
            "-framework", "CryptoKit", "-framework", "SystemConfiguration"]
        compile.standardOutput = compileOutput; compile.standardError = compileOutput
        try compile.run(); compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0,
                       String(decoding: compileOutput.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self))
        let selfTest = Process(), selfTestOutput = Pipe()
        selfTest.executableURL = temporary
        selfTest.arguments = ["--self-test-conditional-denial-action-v1"]
        selfTest.standardOutput = selfTestOutput; selfTest.standardError = selfTestOutput
        try selfTest.run(); selfTest.waitUntilExit()
        let selfTestText = String(decoding: selfTestOutput.fileHandleForReading.readDataToEndOfFile(),
                                  as: UTF8.self)
        XCTAssertEqual(selfTest.terminationStatus, 0, selfTestText)
        XCTAssertEqual(selfTestText.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Conditional denial action and presentation budget self-test: PASS cases=52")
        let conditionalStart = try XCTUnwrap(driver.range(
            of: "let conditionalLaunchAction = ConditionalLaunchDenialAction()"))
        let settlementStart = try XCTUnwrap(driver.range(
            of: "let launchSettlement = LaunchPresentationSettlement()",
            range: conditionalStart.upperBound..<driver.endIndex))
        let conditional = String(driver[conditionalStart.lowerBound..<settlementStart.lowerBound])
        var cursor = conditional.startIndex
        for token in ["let allocationStart = ProcessInfo.processInfo.systemUptime",
                      "conditionalDenialReservationAvailable(",
                      "let prepared = PreparedDeniedClick(point: point)",
                      "let adjacentDisposition = try commonModeLaunchDisposition()",
                      "let adjacentEnd = ProcessInfo.processInfo.systemUptime",
                      "conditionalDenialDeadline - adjacentEnd >= denialPostBudget",
                      "armSyntheticDenialClick(lease:",
                      "close(.armedDeniedClick)", "executeConditionalDenialAction(",
                      "authorized: conditionalLaunchAction.state == .armedDeniedClick",
                      "conditional_launch_action_deadline_miss",
                      "markPerformed()"] {
            let range = try XCTUnwrap(
                conditional.range(of: token, range: cursor..<conditional.endIndex), token)
            cursor = range.upperBound
        }
        XCTAssertTrue(driver.contains("private let denialPostBudget: TimeInterval = 0.100"))
        for forbidden in ["anchoredDeadline +=", "anchoredDeadline = max(",
                          "retryConditional", "resumeConditional"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
    }

    func testDisplayAuthorityIsTypedAwakeStableRedactedAndNeverSubstituted() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in ["enum DisplayQueryState", "case failure, zero, values, capacityExceeded",
                      "configurationChanged, truncated", "private func boundedDisplayList",
                      "guard firstCount <= capacity", "guard secondCount <= firstCount",
                      "guard secondCount == firstCount", "Set(exact).count == exact.count",
                      "CGDisplayIsActive($0) != 0", "CGDisplayIsAsleep($0) == 0",
                      "screenMappingCounts.allSatisfy { $0 == 1 }",
                      "func exactlyMatches(_ baseline: DisplayAuthoritySnapshot)",
                      "conditional_launch_display_unavailable",
                      "guard sample.cheap.displayAuthorityExact else",
                      "guard adjacentDenial.displayAuthorityExact else"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        XCTAssertFalse(driver.contains("func activeDisplayIDs()"))
        for forbidden in ["CGRequestPostEventAccess", "CGRequestScreenCaptureAccess",
                          "caffeinate", "IOPMAssertion", "wakeUp", "wake display",
                          "max(by:", "largest window", "auxiliary", "resumeConditional",
                          "retryConditional"] {
            XCTAssertFalse(driver.localizedCaseInsensitiveContains(forbidden), forbidden)
        }

        let denialStart = try XCTUnwrap(driver.range(of: "func launchCheapObservation(lease:"))
        let commonMode = try XCTUnwrap(driver.range(
            of: "func launchDenialObservation(", range: denialStart.upperBound..<driver.endIndex))
        let denial = String(driver[denialStart.lowerBound..<commonMode.lowerBound])
        XCTAssertTrue(denial.contains("displayAuthority.active.displays.filter"))
        XCTAssertFalse(denial.contains("online.displays"))
        XCTAssertFalse(denial.contains("CGGetOnlineDisplayList"))

        let denialStruct = try XCTUnwrap(driver.range(of: "private struct LaunchDenialObservation"))
        let aggregateStart = try XCTUnwrap(driver.range(
            of: "var redactedAggregate: String {", range: denialStruct.upperBound..<denialStart.lowerBound))
        let diagnosticsStart = try XCTUnwrap(driver.range(
            of: "private final class LaunchDenialDiagnostics",
            range: aggregateStart.upperBound..<driver.endIndex))
        let predicatesStart = try XCTUnwrap(driver.range(
            of: "var predicates: [(String, Bool)]", range: denialStruct.upperBound..<aggregateStart.lowerBound))
        let aggregate = String(driver[predicatesStart.lowerBound..<diagnosticsStart.lowerBound])
        var cursor = aggregate.startIndex
        for field in ["authority_exact", "finished_launching", "inactive",
                      "predecessor_frontmost_exact", "workspace_zero_event_lease",
                      "workspace_unchanged", "ax_unchanged",
                      "focused_children_zero", "standard_inactive_surface_zero",
                      "input_preflight", "owner_window_count", "active_display_query_state",
                      "active_display_count", "containing_active_display_count",
                      "online_display_query_state", "online_display_count",
                      "nsscreen_mapping_count", "private_text_count"] {
            let range = try XCTUnwrap(aggregate.range(of: field, range: cursor..<aggregate.endIndex), field)
            cursor = range.upperBound
        }
        for forbidden in ["rectangle", "coordinate", "displayID", "windowID", "pid=",
                          "predecessorName", "AXValue", "textValue", "sha256"] {
            XCTAssertFalse(aggregate.localizedCaseInsensitiveContains(forbidden), forbidden)
        }

        enum Query: Equatable { case failure, zero, values([Int]), capacity, changed, truncated }
        func model(firstStatus: Bool, firstCount: Int, secondStatus: Bool = true,
                   secondCount: Int? = nil, duplicate: Bool = false) -> Query {
            guard firstStatus else { return .failure }
            guard firstCount > 0 else { return .zero }
            guard firstCount <= 32 else { return .capacity }
            guard secondStatus else { return .failure }
            let observed = secondCount ?? firstCount
            guard observed <= firstCount else { return .truncated }
            guard observed == firstCount, !duplicate else { return .changed }
            return .values(Array(0..<observed))
        }
        XCTAssertEqual(model(firstStatus: false, firstCount: 0), .failure)
        XCTAssertEqual(model(firstStatus: true, firstCount: 0), .zero)
        XCTAssertEqual(model(firstStatus: true, firstCount: 2), .values([0, 1]))
        XCTAssertEqual(model(firstStatus: true, firstCount: 33), .capacity)
        XCTAssertEqual(model(firstStatus: true, firstCount: 2, secondCount: 3), .truncated)
        XCTAssertEqual(model(firstStatus: true, firstCount: 2, secondCount: 1), .changed)
        XCTAssertEqual(model(firstStatus: true, firstCount: 2, duplicate: true), .changed)

        func stable(preflight: (active: [Int], awake: [Bool], screens: [Int]),
                    sample: (active: [Int], awake: [Bool], screens: [Int])) -> Bool {
            !preflight.active.isEmpty && preflight.active == sample.active &&
                preflight.awake == sample.awake && sample.awake.allSatisfy { $0 } &&
                preflight.screens == sample.screens && sample.screens.allSatisfy { $0 == 1 }
        }
        let base = (active: [1], awake: [true], screens: [1])
        XCTAssertTrue(stable(preflight: base, sample: base))
        XCTAssertFalse(stable(preflight: base, sample: ([1], [false], [1])))
        XCTAssertFalse(stable(preflight: base, sample: ([2], [true], [1])))
        XCTAssertFalse(stable(preflight: base, sample: ([1], [true], [0])))
        XCTAssertFalse(stable(preflight: base, sample: ([1], [true], [2])))
    }

    func testTypedLaunchLeaseSeparatesPairGrantFromFreshPresentationBinding() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in ["enum LaunchSettlementAuthorityCase", "case zeroEventSurface",
                      "case expectedPairSurface", "struct LaunchSettlementLease",
                      "generation: generation, authority: authority",
                      "func finishLaunchSettlementSample(lease:",
                      "lease.authority == .expectedPairSurface",
                      "pair.workspaceUnchanged", "sample.axUnchanged",
                      "conditional_launch_pair_authority_loss",
                      "let launchSettlement = LaunchPresentationSettlement()",
                      "presentation_target_authority_loss", "presentation_workspace_changed",
                      "presentation_display_authority_loss", "commitLaunchPresentation(lease:"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        for forbidden in ["lifecycleUnchanged", "lifecycleSequence",
                          "commitLaunchPresentation(sequence:",
                          "finishLaunchSettlementSample(sequence:", "lifecycleTransition"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }

        let conditionalStart = try XCTUnwrap(driver.range(
            of: "case .expectedPair(let pair):"))
        let zeroGrant = try XCTUnwrap(driver.range(
            of: "if fast.eligible && sample.axUnchanged",
            range: conditionalStart.upperBound..<driver.endIndex))
        let mixed = try XCTUnwrap(driver.range(
            of: "if fast.active || fast.frontmostExact",
            range: zeroGrant.upperBound..<driver.endIndex))
        let denial = try XCTUnwrap(driver.range(
            of: "guard denial.eligible else",
            range: mixed.upperBound..<driver.endIndex))
        XCTAssertLessThan(conditionalStart.lowerBound, zeroGrant.lowerBound)
        XCTAssertLessThan(zeroGrant.lowerBound, mixed.lowerBound)
        XCTAssertLessThan(mixed.lowerBound, denial.lowerBound)

        let close = try XCTUnwrap(driver.range(
            of: "try conditionalLaunchAction.close(.skippedSystemGranted)",
            range: conditionalStart.upperBound..<zeroGrant.lowerBound))
        let fresh = try XCTUnwrap(driver.range(
            of: "let launchSettlement = LaunchPresentationSettlement()",
            range: close.upperBound..<driver.endIndex))
        XCTAssertLessThan(close.lowerBound, fresh.lowerBound)
        let pairBreak = try XCTUnwrap(driver.range(
            of: "break", range: close.upperBound..<zeroGrant.lowerBound))
        let transfer = String(driver[close.lowerBound..<pairBreak.upperBound])
        for forbidden in ["commitLaunchPresentation", "boundNavigation", "CGEvent(",
                          "postZeroDragPair", "presentationDeadline ="] {
            XCTAssertFalse(transfer.contains(forbidden), forbidden)
        }

        let settleStart = try XCTUnwrap(driver.range(of: "private final class LaunchPresentationSettlement"))
        let finderStart = try XCTUnwrap(driver.range(
            of: "private struct FinderSurfaceObservation", range: settleStart.upperBound..<driver.endIndex))
        let settle = String(driver[settleStart.lowerBound..<finderStart.lowerBound])
        for terminal in ["presentation_missing_lease", "presentation_target_authority_loss",
                         "presentation_workspace_changed", "presentation_display_authority_loss",
                         "presentation_commit_changed"] {
            XCTAssertTrue(settle.contains(terminal), terminal)
        }
        for publicationReset in [".axUnpublished", ".transitionWindow", ".focusedWindowLag",
                                 ".typedModeLag", ".geometryPublication",
                                 ".targetObserverInvalidation", ".displayPublication",
                                 ".cgPublication"] {
            XCTAssertTrue(settle.contains(publicationReset), publicationReset)
        }

        enum Lease { case none, zero, pair, invalid }
        enum Result: Equatable { case wait, skipped, zeroGrant, denial, terminal }
        func decide(lease: Lease, workspace: Bool, ax: Bool, finished: Bool,
                    active: Bool, frontmost: Bool, surface: Bool,
                    denialEligible: Bool) -> Result {
            switch lease {
            case .none: return .wait
            case .invalid: return .terminal
            case .pair:
                guard workspace else { return .terminal }
                guard finished else { return .wait }
                return active && frontmost ? .skipped : .terminal
            case .zero:
                guard workspace else { return .wait }
                if surface && ax && finished && active && frontmost { return .zeroGrant }
                if active || frontmost { return .terminal }
                return denialEligible && ax ? .denial : .wait
            }
        }
        for ax in [false, true] {
            XCTAssertEqual(decide(
                lease: .pair, workspace: true, ax: ax, finished: true,
                active: true, frontmost: true, surface: false, denialEligible: false), .skipped)
        }
        XCTAssertEqual(decide(
            lease: .pair, workspace: true, ax: false, finished: false,
            active: false, frontmost: false, surface: false, denialEligible: false), .wait)
        XCTAssertEqual(decide(
            lease: .none, workspace: false, ax: false, finished: true,
            active: false, frontmost: false, surface: false, denialEligible: true), .wait)
        XCTAssertEqual(decide(
            lease: .zero, workspace: true, ax: true, finished: true,
            active: false, frontmost: false, surface: false, denialEligible: true), .denial)
        XCTAssertEqual(decide(
            lease: .zero, workspace: true, ax: true, finished: true,
            active: true, frontmost: true, surface: false, denialEligible: false), .terminal)
        XCTAssertEqual(decide(
            lease: .invalid, workspace: true, ax: true, finished: true,
            active: true, frontmost: true, surface: true, denialEligible: true), .terminal)
    }

    func testInitialLaunchSettlementUsesTwoDistinctTurnSamplesAndLaterPhasesRemainFour() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        let initialStart = try XCTUnwrap(driver.range(
            of: "let launchSettlement = LaunchPresentationSettlement()"))
        let initialEnd = try XCTUnwrap(driver.range(
            of: "gateStage = \"title-navigation\"", range: initialStart.upperBound..<driver.endIndex))
        let initial = String(driver[initialStart.lowerBound..<initialEnd.lowerBound])
        XCTAssertTrue(initial.contains(
            "budget: launchPresentationTimingBudget"))
        XCTAssertTrue(initial.contains("requiredConsecutiveSamples: 2"))
        XCTAssertTrue(initial.contains("minimumStableDuration: 0.25"))
        let settlementTypeStart = try XCTUnwrap(driver.range(
            of: "private final class LaunchPresentationSettlement"))
        let settlementTypeEnd = try XCTUnwrap(driver.range(
            of: "private struct FinderSurfaceObservation",
            range: settlementTypeStart.upperBound..<driver.endIndex))
        let settlementType = String(
            driver[settlementTypeStart.lowerBound..<settlementTypeEnd.lowerBound])
        var authorityCursor = settlementType.startIndex
        for marker in ["fullSnapshot(window, mode, rectangle, true)",
                       "snapshot.postbindRehashExact", "finalWorkspaceUnchanged",
                       "fullAXUnchanged", "commitLaunchPresentation("] {
            let range = try XCTUnwrap(settlementType.range(
                of: marker, range: authorityCursor..<settlementType.endIndex), marker)
            authorityCursor = range.upperBound
        }

        let finderStart = try XCTUnwrap(driver.range(
            of: "let finderSurfaceSettlement = FinderSurfaceSettlement()"))
        let finderEnd = try XCTUnwrap(driver.range(
            of: "try activateOnce(\"elysium.reactivate\"",
            range: finderStart.upperBound..<driver.endIndex))
        let finder = String(driver[finderStart.lowerBound..<finderEnd.lowerBound])
        XCTAssertTrue(finder.contains("requiredConsecutiveSamples: 4"))
        let readyStart = try XCTUnwrap(driver.range(of: "try readyEpoch.settle("))
        let readyEnd = try XCTUnwrap(driver.range(
            of: "let preservedSurface", range: readyStart.upperBound..<driver.endIndex))
        let ready = String(driver[readyStart.lowerBound..<readyEnd.lowerBound])
        XCTAssertTrue(ready.contains("requiredConsecutiveSamples: 4"))

        struct Candidate: Equatable {
            var axObject = 1
            var typedMode = 1
            var rectangle = 1
            var display = 1
            var cgOwner = 1
            var workspaceLease = 1
            var targetAXSequence = 1
        }
        struct Sample { let turn: Int; let milliseconds: Int; let candidate: Candidate }
        func reachesFinalValidation(_ samples: [Sample]) -> Bool {
            var candidate: Candidate?
            var firstTurn: Int?
            var firstMilliseconds: Int?
            var count = 0
            for sample in samples {
                if sample.candidate != candidate {
                    candidate = sample.candidate
                    firstTurn = sample.turn
                    firstMilliseconds = sample.milliseconds
                    count = 1
                    continue
                }
                guard sample.turn != firstTurn else { continue }
                count += 1
                if count >= 2,
                   sample.milliseconds - (firstMilliseconds ?? sample.milliseconds) >= 250 {
                    return true
                }
            }
            return false
        }
        let base = Candidate()
        XCTAssertFalse(reachesFinalValidation([Sample(turn: 1, milliseconds: 0, candidate: base)]))
        XCTAssertFalse(reachesFinalValidation([
            Sample(turn: 1, milliseconds: 0, candidate: base),
            Sample(turn: 1, milliseconds: 250, candidate: base),
        ]))
        XCTAssertFalse(reachesFinalValidation([
            Sample(turn: 1, milliseconds: 0, candidate: base),
            Sample(turn: 2, milliseconds: 249, candidate: base),
        ]))
        XCTAssertTrue(reachesFinalValidation([
            Sample(turn: 1, milliseconds: 0, candidate: base),
            Sample(turn: 2, milliseconds: 250, candidate: base),
        ]))
        XCTAssertTrue(reachesFinalValidation([
            Sample(turn: 1, milliseconds: 0, candidate: base),
            Sample(turn: 2, milliseconds: 822, candidate: base),
        ]))
        let mutations: [Candidate] = [
            Candidate(axObject: 2), Candidate(typedMode: 2), Candidate(rectangle: 2),
            Candidate(display: 2), Candidate(cgOwner: 2), Candidate(workspaceLease: 2),
            Candidate(targetAXSequence: 2),
        ]
        for mutation in mutations {
            XCTAssertFalse(reachesFinalValidation([
                Sample(turn: 1, milliseconds: 0, candidate: base),
                Sample(turn: 2, milliseconds: 250, candidate: mutation),
            ]))
            XCTAssertTrue(reachesFinalValidation([
                Sample(turn: 1, milliseconds: 0, candidate: base),
                Sample(turn: 2, milliseconds: 250, candidate: mutation),
                Sample(turn: 3, milliseconds: 500, candidate: mutation),
            ]))
        }
    }

    func testLaunchLifecycleBaselineAndPresentationBinderAreClosedAndDeterministic() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in ["StaticArtifactAuthority", "ImmutableLaunchAuthority",
                      "RegularFileIdentity", "lstat(", "S_IFREG",
                      "installAndArmLifecycleLedger", "beginLaunchPathCapture()",
                      "capturePredecessorOrStaticTarget", "armOpenAction()",
                      "LaunchCompletionState", "bindTargetAndReconcile(",
                      "provisionalTarget", "provisional_capacity", "ingressSnapshot() <= 2",
                      "zeroEventSurface", "expectedPairSurface",
                      "launch_authority_path=", "finished_launching",
                      "app.isFinishedLaunching", "exactCompletionRuntimeAuthority",
                      "launch_surface_final_drain",
                      "launch_baseline_path=", "alreadyFrontmost", "expectedLaunchPair",
                      "provisional_foreign_or_duplicate", "event_before_open_action",
                      "event_after_launch_pair", "event_during_launch_baseline",
                      "event_ingress_race", "ingress_count=", "phase = .launchSettlement",
                      "phase = .boundNavigation", "observer_generation_mismatch",
                      "LaunchPresentationSettlement", "case unpublished, transitioning, candidate, bound, failed",
                      "TargetAXInvalidationLedger", "kAXWindowCreatedNotification",
                      "kAXFocusedWindowChangedNotification", "kAXMovedNotification",
                      "kAXResizedNotification", "kAXUIElementDestroyedNotification",
                      "kAXStandardWindowSubrole", "targetObserverInvalidation",
                      "postbindRehashExact", "exactWithRehash()",
                      "commitLaunchPresentation(lease:", "requireBoundNavigation()"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        let staticAuthority = try XCTUnwrap(driver.range(of: "let staticArtifactAuthority ="))
        let install = try XCTUnwrap(driver.range(
            of: "installAndArmLifecycleLedger", range: staticAuthority.upperBound..<driver.endIndex))
        let capture = try XCTUnwrap(driver.range(
            of: "beginLaunchPathCapture()", range: install.upperBound..<driver.endIndex))
        let arm = try XCTUnwrap(driver.range(
            of: "handoffLedger.armOpenAction()", range: capture.upperBound..<driver.endIndex))
        let open = try XCTUnwrap(driver.range(
            of: "NSWorkspace.shared.openApplication", range: arm.upperBound..<driver.endIndex))
        let completionAuthority = try XCTUnwrap(driver.range(
            of: "let immutableLaunchAuthority =", range: open.upperBound..<driver.endIndex))
        let reconcile = try XCTUnwrap(driver.range(
            of: "handoffLedger.bindTargetAndReconcile(",
            range: completionAuthority.upperBound..<driver.endIndex))
        let settlement = try XCTUnwrap(driver.range(
            of: "launchSettlement.settle(", range: reconcile.upperBound..<driver.endIndex))
        let navigation = try XCTUnwrap(driver.range(
            of: "gateStage = \"title-navigation\"", range: settlement.upperBound..<driver.endIndex))
        XCTAssertLessThan(staticAuthority.lowerBound, install.lowerBound)
        XCTAssertLessThan(install.lowerBound, capture.lowerBound)
        XCTAssertLessThan(capture.lowerBound, arm.lowerBound)
        XCTAssertLessThan(arm.lowerBound, open.lowerBound)
        XCTAssertLessThan(open.lowerBound, completionAuthority.lowerBound)
        XCTAssertLessThan(completionAuthority.lowerBound, reconcile.lowerBound)
        XCTAssertLessThan(reconcile.lowerBound, settlement.lowerBound)
        XCTAssertLessThan(settlement.lowerBound, navigation.lowerBound)
        let launchSlice = String(driver[staticAuthority.lowerBound..<navigation.lowerBound])
        XCTAssertFalse(launchSlice.contains("app.activate(options: [])"))
        XCTAssertFalse(launchSlice.contains("launch.activate"))
        XCTAssertEqual(driver.components(separatedBy: "openApplication(at:").count - 1, 1)
        XCTAssertTrue(launchSlice.contains("configuration.activates = true"))
        XCTAssertEqual(driver.components(
            separatedBy: "let conditionalSamplingStarted =").count - 1, 1)

        enum Path { case unbound, alreadyFrontmost, expectedLaunchPair }
        enum Event { case elysiumActivate, predecessorDeactivate, elysiumDeactivate,
                          otherActivate, wrongDeactivate }
        struct BaselineModel {
            var path = Path.unbound
            var terminal = false
            var pair = Set<String>()
            var pairComplete = false
            var committed = false
            var generation = 1
            var actionArmed = false
            var completionBound = false

            mutating func bind(_ value: Path) {
                guard !terminal, path == .unbound else { terminal = true; return }
                path = value
            }
            mutating func armAction() {
                guard !terminal, path != .unbound else { terminal = true; return }
                actionArmed = true
            }
            mutating func event(_ value: Event, generation incoming: Int = 1) {
                guard !terminal, incoming == generation, actionArmed, !committed else {
                    terminal = true; return
                }
                guard path == .expectedLaunchPair, !pairComplete else {
                    terminal = true; return
                }
                switch value {
                case .elysiumActivate:
                    guard pair.insert("elysium.activate").inserted else { terminal = true; return }
                case .predecessorDeactivate:
                    guard pair.insert("predecessor.deactivate").inserted else {
                        terminal = true; return
                    }
                case .elysiumDeactivate, .otherActivate, .wrongDeactivate:
                    terminal = true; return
                }
                pairComplete = pair.count == 2
            }
            mutating func complete(exact: Bool = true) {
                guard !terminal, actionArmed, !completionBound, exact else {
                    terminal = true; return
                }
                completionBound = true
            }
            mutating func baseline(propertiesExact: Bool, eventDuringRead: Bool = false) -> Bool {
                if eventDuringRead { terminal = true }
                guard !terminal, completionBound, propertiesExact,
                      pair.isEmpty || pairComplete else { return false }
                committed = true
                return true
            }
            mutating func authorityFailure() { terminal = true }
            mutating func timeout() { terminal = true }
            mutating func close() { terminal = true; generation += 1 }
        }

        var already = BaselineModel(); already.bind(.alreadyFrontmost); already.armAction()
        already.complete()
        XCTAssertFalse(already.baseline(propertiesExact: false))
        XCTAssertTrue(already.baseline(propertiesExact: true))
        var firstOrder = BaselineModel(); firstOrder.bind(.expectedLaunchPair); firstOrder.armAction()
        firstOrder.event(.elysiumActivate); firstOrder.event(.predecessorDeactivate)
        firstOrder.complete()
        XCTAssertFalse(firstOrder.baseline(propertiesExact: false))
        XCTAssertTrue(firstOrder.baseline(propertiesExact: true))
        var secondOrder = BaselineModel(); secondOrder.bind(.expectedLaunchPair); secondOrder.armAction()
        secondOrder.event(.predecessorDeactivate); secondOrder.complete()
        secondOrder.event(.elysiumActivate)
        XCTAssertTrue(secondOrder.baseline(propertiesExact: true))
        var afterCompletion = BaselineModel(); afterCompletion.bind(.expectedLaunchPair)
        afterCompletion.armAction(); afterCompletion.complete()
        afterCompletion.event(.elysiumActivate); afterCompletion.event(.predecessorDeactivate)
        XCTAssertTrue(afterCompletion.baseline(propertiesExact: true))
        var zeroEventPredecessor = BaselineModel(); zeroEventPredecessor.bind(.expectedLaunchPair)
        zeroEventPredecessor.armAction(); zeroEventPredecessor.complete()
        XCTAssertTrue(zeroEventPredecessor.baseline(propertiesExact: true))
        var missing = BaselineModel(); missing.bind(.expectedLaunchPair); missing.armAction()
        missing.complete(); missing.event(.elysiumActivate)
        XCTAssertFalse(missing.baseline(propertiesExact: true))
        missing.timeout(); XCTAssertTrue(missing.terminal)

        for event in [Event.elysiumDeactivate, .otherActivate, .wrongDeactivate] {
            var model = BaselineModel(); model.bind(.expectedLaunchPair); model.armAction()
            model.event(event)
            XCTAssertTrue(model.terminal)
            XCTAssertFalse(model.baseline(propertiesExact: true))
        }
        for duplicate in [Event.elysiumActivate, .predecessorDeactivate] {
            var model = BaselineModel(); model.bind(.expectedLaunchPair); model.armAction()
            model.event(duplicate); model.event(duplicate)
            XCTAssertTrue(model.terminal)
        }
        var beforeBinding = BaselineModel(); beforeBinding.event(.elysiumActivate)
        XCTAssertTrue(beforeBinding.terminal)
        var afterPair = BaselineModel(); afterPair.bind(.expectedLaunchPair); afterPair.armAction()
        afterPair.event(.elysiumActivate); afterPair.event(.predecessorDeactivate)
        afterPair.event(.otherActivate); XCTAssertTrue(afterPair.terminal)
        var duringRead = BaselineModel(); duringRead.bind(.alreadyFrontmost)
        duringRead.armAction(); duringRead.complete()
        XCTAssertFalse(duringRead.baseline(propertiesExact: true, eventDuringRead: true))
        var wrongGeneration = BaselineModel(); wrongGeneration.bind(.expectedLaunchPair)
        wrongGeneration.armAction()
        wrongGeneration.event(.elysiumActivate, generation: 2)
        XCTAssertTrue(wrongGeneration.terminal)
        var disappeared = BaselineModel(); disappeared.bind(.expectedLaunchPair)
        disappeared.armAction()
        disappeared.authorityFailure(); XCTAssertFalse(disappeared.baseline(propertiesExact: true))
        var cleaned = BaselineModel(); cleaned.bind(.alreadyFrontmost); cleaned.armAction(); cleaned.close()
        XCTAssertFalse(cleaned.baseline(propertiesExact: true))
        var badCompletion = BaselineModel(); badCompletion.bind(.expectedLaunchPair)
        badCompletion.armAction(); badCompletion.complete(exact: false)
        XCTAssertTrue(badCompletion.terminal)

        struct ActivationOutcome: Equatable {
            let branch: String?
            let calls: Int
            let terminal: Bool
        }
        func activationDecision(
            selfActivated: Bool = false, inactiveSamples: Int = 0,
            distinctTurnsAndDuration: Bool = true, activeAtFinalCheck: Bool = false,
            partialPairObserved: Bool = false, activationReturn: Bool = true
        ) -> ActivationOutcome {
            if selfActivated || partialPairObserved || activeAtFinalCheck {
                return ActivationOutcome(branch: "selfActivated", calls: 0, terminal: false)
            }
            guard inactiveSamples >= 2, distinctTurnsAndDuration else {
                return ActivationOutcome(branch: nil, calls: 0, terminal: false)
            }
            return ActivationOutcome(
                branch: "explicitActivation", calls: 1, terminal: !activationReturn)
        }
        XCTAssertEqual(activationDecision(selfActivated: true),
                       ActivationOutcome(branch: "selfActivated", calls: 0, terminal: false))
        XCTAssertEqual(activationDecision(inactiveSamples: 1),
                       ActivationOutcome(branch: nil, calls: 0, terminal: false))
        XCTAssertEqual(activationDecision(inactiveSamples: 2,
                                           distinctTurnsAndDuration: false),
                       ActivationOutcome(branch: nil, calls: 0, terminal: false))
        XCTAssertEqual(activationDecision(inactiveSamples: 2),
                       ActivationOutcome(branch: "explicitActivation", calls: 1, terminal: false))
        XCTAssertEqual(activationDecision(inactiveSamples: 2, activeAtFinalCheck: true),
                       ActivationOutcome(branch: "selfActivated", calls: 0, terminal: false))
        XCTAssertEqual(activationDecision(partialPairObserved: true),
                       ActivationOutcome(branch: "selfActivated", calls: 0, terminal: false))
        XCTAssertEqual(activationDecision(inactiveSamples: 2, activationReturn: false),
                       ActivationOutcome(branch: "explicitActivation", calls: 1, terminal: true))

        enum Publication { case unpublished, unknownWindow, candidate, axInvalidation,
                                firstPairMember,
                                authorityFailure, lifecycleEvent, rehashFailure }
        func mayBind(_ samples: [Publication]) -> Bool {
            var consecutive = 0
            var terminal = false
            for sample in samples {
                if terminal { return false }
                switch sample {
                case .unpublished, .unknownWindow, .axInvalidation, .firstPairMember:
                    consecutive = 0
                case .candidate:
                    consecutive += 1
                    if consecutive == 4 { return true }
                case .authorityFailure, .lifecycleEvent, .rehashFailure: terminal = true
                }
            }
            return false
        }
        XCTAssertTrue(mayBind([.unpublished, .unknownWindow, .candidate, .candidate,
                               .candidate, .candidate]))
        XCTAssertTrue(mayBind([.candidate, .candidate, .axInvalidation, .candidate,
                               .candidate, .candidate, .candidate]))
        XCTAssertFalse(mayBind([.candidate, .candidate, .candidate, .firstPairMember,
                                .candidate, .candidate, .candidate]))
        XCTAssertTrue(mayBind([.candidate, .candidate, .candidate, .firstPairMember,
                               .candidate, .candidate, .candidate, .candidate]))
        for terminal in [Publication.authorityFailure, .lifecycleEvent, .rehashFailure] {
            XCTAssertFalse(mayBind([terminal, .candidate, .candidate, .candidate, .candidate]))
        }
        for forbidden in ["localizedName", "debugDescription", "kCGWindowName",
                          "predecessor_pid", "predecessor_bundle", "predecessor_path"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
    }

    func testWorkspaceActivationHandoffLedgerIsBoundOrderedAndRaceClosed() throws {
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        for token in ["WorkspaceActivationHandoffLedger", "NSLock()", "generation: UInt64 = 1",
                      "NSWorkspace.didActivateApplicationNotification",
                      "NSWorkspace.didDeactivateApplicationNotification",
                      "NSWorkspace.applicationUserInfoKey", "expectedPredecessor, expectedFinder",
                      "beginFinderAction(", "awaitFinderPair(timeout: 2)",
                      "beginElysiumAction()", "awaitElysiumPair(timeout: 2)",
                      "event_during_surface_sample", "postcommit_event", "launch_lifecycle_event",
                      "finder_pair_duplicate_or_order", "pebble_pair_duplicate_or_order",
                      "event_between_action_pairs", "unexpected_or_identity_mismatch",
                      "phase = .closed", "generation &+= 1", "center.removeObserver(token)",
                      "cleanup.closeObservers", "beginSurfaceSample()",
                      "finishSurfaceSample(sequence:", "markReady()",
                      "FinderSurfaceSettlement", "beginFinderSurfaceSample()",
                      "finishFinderSurfaceSample(sequence:", "requireFinderSurfaceFinal()",
                      "terminateFinderSurface(", "finder_surface_identity_or_authority",
                      "finder_surface_timeout", "boundCGOwnerWindow(",
                      "presentExactlyOnce", "boundWindow.onScreen == expectedOnScreen",
                      "boundWindow.alpha == 1.0"] {
            XCTAssertTrue(driver.contains(token), token)
        }
        let install = try XCTUnwrap(driver.range(of: "installAndArmLifecycleLedger(center:"))
        let finder = try XCTUnwrap(driver.range(
            of: "activateOnce(\"finder.activate\"", range: install.upperBound..<driver.endIndex))
        let finderBoundary = try XCTUnwrap(driver.range(
            of: "handoffLedger.beginFinderAction(", range: finder.upperBound..<driver.endIndex))
        let finderAwait = try XCTUnwrap(driver.range(
            of: "handoffLedger.awaitFinderPair", range: finderBoundary.upperBound..<driver.endIndex))
        let finderSettlement = try XCTUnwrap(driver.range(
            of: "finderSurfaceSettlement.settle(",
            range: finderAwait.upperBound..<driver.endIndex))
        let elysium = try XCTUnwrap(driver.range(
            of: "activateOnce(\"elysium.reactivate\"",
            range: finderSettlement.upperBound..<driver.endIndex))
        let elysiumBoundary = try XCTUnwrap(driver.range(
            of: "handoffLedger.beginElysiumAction()", range: elysium.upperBound..<driver.endIndex))
        let elysiumAwait = try XCTUnwrap(driver.range(
            of: "handoffLedger.awaitElysiumPair", range: elysiumBoundary.upperBound..<driver.endIndex))
        let settling = try XCTUnwrap(driver.range(
            of: "readyEpoch.settle(", range: elysiumAwait.upperBound..<driver.endIndex))
        XCTAssertLessThan(install.lowerBound, finder.lowerBound)
        XCTAssertLessThan(finder.lowerBound, finderBoundary.lowerBound)
        XCTAssertLessThan(finderBoundary.lowerBound, finderAwait.lowerBound)
        XCTAssertLessThan(finderAwait.lowerBound, finderSettlement.lowerBound)
        XCTAssertLessThan(finderSettlement.lowerBound, elysium.lowerBound)
        XCTAssertLessThan(elysium.lowerBound, elysiumBoundary.lowerBound)
        XCTAssertLessThan(elysiumBoundary.lowerBound, elysiumAwait.lowerBound)
        XCTAssertLessThan(elysiumAwait.lowerBound, settling.lowerBound)

        func accepts(_ first: [String], _ second: [String]) -> Bool {
            Set(first) == Set(["finder.activate", "elysium.deactivate"]) && first.count == 2 &&
                Set(second) == Set(["elysium.activate", "finder.deactivate"]) && second.count == 2
        }
        XCTAssertTrue(accepts(["finder.activate", "elysium.deactivate"],
                              ["elysium.activate", "finder.deactivate"]))
        XCTAssertTrue(accepts(["elysium.deactivate", "finder.activate"],
                              ["finder.deactivate", "elysium.activate"]))
        XCTAssertFalse(accepts(["finder.activate"], ["elysium.activate", "finder.deactivate"]))
        XCTAssertFalse(accepts(["finder.activate", "finder.activate"],
                               ["elysium.activate", "finder.deactivate"]))
        XCTAssertFalse(accepts(["elysium.activate", "finder.deactivate"],
                               ["finder.activate", "elysium.deactivate"]))
        XCTAssertFalse(accepts(["unexpected.activate", "elysium.deactivate"],
                               ["elysium.activate", "finder.deactivate"]))

        enum Mode { case fullscreen, windowedFallback }
        struct FinderSample {
            var finderIdentity = true
            var finderActive = true
            var finderFrontmost = true
            var elysiumIdentity = true
            var elysiumInactive = true
            var axWindowIdentity = true
            var axModeExact = true
            var axGeometryExact = true
            var boundPresent = true
            var boundPID = true
            var boundID = true
            var boundLayer = true
            var boundRectangle = true
            var onScreen: Bool? = false
            var opaque = true

            var authorityExact: Bool {
                finderIdentity && finderActive && finderFrontmost && elysiumIdentity &&
                    elysiumInactive && axWindowIdentity && axModeExact && axGeometryExact &&
                    boundPresent && boundPID && boundID && boundLayer && boundRectangle &&
                    onScreen != nil
            }
        }
        struct Outcome: Equatable {
            let reverseActions: Int
            let terminal: Bool
            let timedOut: Bool
        }
        func model(
            mode: Mode, samples: [FinderSample], eventDuringSample: Int? = nil,
            unexpectedOtherAt: Int? = nil, laterBounce: Bool = false
        ) -> Outcome {
            var consecutive = 0
            for (index, sample) in samples.enumerated() {
                if eventDuringSample == index || unexpectedOtherAt == index {
                    return Outcome(reverseActions: 0, terminal: true, timedOut: false)
                }
                guard sample.authorityExact else {
                    return Outcome(reverseActions: 0, terminal: true, timedOut: false)
                }
                let publicationExact: Bool
                switch mode {
                case .fullscreen: publicationExact = sample.onScreen == false
                case .windowedFallback:
                    publicationExact = sample.onScreen == true && sample.opaque
                }
                consecutive = publicationExact ? consecutive + 1 : 0
                if consecutive >= 4 {
                    return Outcome(reverseActions: 1, terminal: laterBounce, timedOut: false)
                }
            }
            return Outcome(reverseActions: 0, terminal: true, timedOut: true)
        }
        let offscreen = FinderSample()
        var onscreen = FinderSample(); onscreen.onScreen = true
        XCTAssertEqual(model(mode: .fullscreen, samples: [onscreen, onscreen, onscreen, onscreen]),
                       Outcome(reverseActions: 0, terminal: true, timedOut: true))
        XCTAssertEqual(model(mode: .fullscreen,
                             samples: [offscreen, offscreen, offscreen, offscreen]),
                       Outcome(reverseActions: 1, terminal: false, timedOut: false))
        XCTAssertEqual(model(mode: .windowedFallback,
                             samples: [onscreen, onscreen, onscreen, onscreen]),
                       Outcome(reverseActions: 1, terminal: false, timedOut: false))
        var translucent = onscreen; translucent.opaque = false
        XCTAssertEqual(model(mode: .windowedFallback,
                             samples: [translucent, translucent, translucent, translucent]),
                       Outcome(reverseActions: 0, terminal: true, timedOut: true))
        var finderInactive = offscreen; finderInactive.finderActive = false
        var finderNotFrontmost = offscreen; finderNotFrontmost.finderFrontmost = false
        var elysiumActive = offscreen; elysiumActive.elysiumInactive = false
        var missing = offscreen; missing.boundPresent = false
        var substitutedPID = offscreen; substitutedPID.boundPID = false
        var substitutedID = offscreen; substitutedID.boundID = false
        var substitutedLayer = offscreen; substitutedLayer.boundLayer = false
        var substitutedRectangle = offscreen; substitutedRectangle.boundRectangle = false
        for invalid in [finderInactive, finderNotFrontmost, elysiumActive, missing,
                        substitutedPID, substitutedID, substitutedLayer, substitutedRectangle] {
            XCTAssertEqual(model(mode: .fullscreen, samples: [invalid]),
                           Outcome(reverseActions: 0, terminal: true, timedOut: false))
        }
        XCTAssertEqual(model(mode: .fullscreen, samples: [offscreen], eventDuringSample: 0),
                       Outcome(reverseActions: 0, terminal: true, timedOut: false))
        XCTAssertEqual(model(mode: .fullscreen, samples: [offscreen], unexpectedOtherAt: 0),
                       Outcome(reverseActions: 0, terminal: true, timedOut: false))
        XCTAssertEqual(model(mode: .fullscreen,
                             samples: [offscreen, offscreen, offscreen, offscreen],
                             laterBounce: true),
                       Outcome(reverseActions: 1, terminal: true, timedOut: false))

        let boundQueryStart = try XCTUnwrap(driver.range(of: "private func boundCGOwnerWindow("))
        let boundQueryEnd = try XCTUnwrap(driver.range(
            of: "private func matchingCGOwnerWindows(", range: boundQueryStart.upperBound..<driver.endIndex))
        let boundQuery = String(driver[boundQueryStart.lowerBound..<boundQueryEnd.lowerBound])
        XCTAssertTrue(boundQuery.contains("[.excludeDesktopElements]"))
        XCTAssertFalse(boundQuery.contains(".optionOnScreenOnly"))
        for forbidden in ["localizedName", "unexpectedBundle", "unexpectedPath",
                          "unexpectedPID", "kCGWindowName"] {
            XCTAssertFalse(driver.contains(forbidden), forbidden)
        }
    }

    func testInstalledSignoffReceiptIsExhaustiveAuthenticatedAndHookEnforced() throws {
        let receipt = try source("scripts/installed-signoff-receipt.swift")
        let authority = try source("Sources/ElysiumReleaseGate/ReleaseGate.swift")
        let observer = try source("scripts/observe-installed-signoff.swift")
        let designer = try source("scripts/designer-attest-installed-signoff.swift")
        let observerWrapper = try source("scripts/observe-installed-signoff.sh")
        let designerWrapper = try source("scripts/designer-attest-installed-signoff.sh")
        for token in ["git([\"ls-files\", \"-z\"])",
                      "git([\"ls-files\", \"--others\", \"--exclude-standard\", \"-z\"])",
                      "git([\"ls-files\", \"--stage\", \"-z\"])",
                      "ReleaseGateCommandDispatcher("] {
            XCTAssertTrue(receipt.contains(token), token)
        }
        for token in ["case \"observe-interactive\"", "case \"run-prepare-gates\"",
                      "ReleaseGateCommand", "ReleaseGateCommandDependencies",
                      "PackageManifest", "AutomatedGateEvidence"] {
            XCTAssertTrue(authority.contains(token), token)
        }
        XCTAssertFalse(receipt.contains("case \"observe\":"))
        XCTAssertFalse(receipt.contains("case \"prepare\":"))
        let preparedStart = try XCTUnwrap(authority.range(of: "case .runPrepareGates:"))
        let preparedEnd = try XCTUnwrap(authority.range(
            of: "case .verifyCurrent:", range: preparedStart.upperBound..<authority.endIndex))
        let publication = String(authority[preparedStart.lowerBound..<preparedEnd.lowerBound])
        var publicationCursor = publication.startIndex
        for marker in ["gate.restart(", "ReleaseGatePreparationWorkflow(",
                       "from: .preparing, to: .prepared",
                       "dependencies.validateCurrent(prepared)", "} catch {", "gate.invalidate()"] {
            let range = try XCTUnwrap(publication.range(
                of: marker, range: publicationCursor..<publication.endIndex), marker)
            publicationCursor = range.upperBound
        }
        for token in ["KeychainReceiptStateStore", "checkedUpdate", "O_NOFOLLOW",
                      "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", "restart(",
                      "requirePrivateFile", "staleSequence"] {
            XCTAssertTrue(authority.contains(token), token)
        }
        for token in ["captureWindow", "axReport", "observationChallenge",
                      "designerChallenge"] {
            XCTAssertTrue(observer.contains(token), token)
        }
        for forbidden in ["designer-attestation.json", "designer-attest\"",
                          "from: .observedPendingDesigner, to: .observed", ".transition(",
                          ".invalidate("] {
            XCTAssertFalse(observer.contains(forbidden), forbidden)
        }
        for token in ["isatty(STDIN_FILENO)", "isatty(STDOUT_FILENO)",
                      "pending.state == .observedPendingDesigner", "observerPID != getpid()",
                      "observerStart != designerStart", "productionValidateCurrent(pending)",
                      "validateBoundElysiumProcess(pending)", "validateSealedInstalledEvidence(",
                      "pending.evidenceDigest", "pending.designerChallenge"] {
            XCTAssertTrue(designer.contains(token), token)
        }
        for forbidden in ["ElysiumDesignerAttestationV2", "designer-attestation.json",
                          ".transition(", ".invalidate("] {
            XCTAssertFalse(designer.contains(forbidden), forbidden)
        }
        for token in ["from: .prepared, to: .observedPendingDesigner",
                      "from: .observedPendingDesigner, to: .observed",
                      "ElysiumDesignerAttestationV2", "designer-attestation.json",
                      "ReleaseGatePrivateEvidence.digest("] {
            XCTAssertTrue(authority.contains(token), token)
        }
        XCTAssertTrue(observerWrapper.contains(
            "scripts/installed-signoff-receipt.sh observe-interactive"))
        XCTAssertTrue(designerWrapper.contains(
            "scripts/installed-signoff-receipt.sh designer-attest"))
        let observerInvocations = observerWrapper.split(separator: "\n").filter {
            $0.contains("installed-signoff-receipt.sh")
        }
        XCTAssertEqual(observerInvocations.filter { $0.contains("observe-interactive") }.count, 1)
        XCTAssertEqual(observerInvocations.filter { $0.contains("designer-attest") }.count, 0)
        let designerInvocations = designerWrapper.split(separator: "\n").filter {
            $0.contains("installed-signoff-receipt.sh")
        }
        XCTAssertEqual(designerInvocations.filter { $0.contains("designer-attest") }.count, 1)
        XCTAssertEqual(designerInvocations.filter { $0.contains("observe-interactive") }.count, 0)
        let allowedStart = try XCTUnwrap(authority.range(of: "private static func allowed"))
        let allowedEnd = try XCTUnwrap(authority.range(
            of: "private func withLock", range: allowedStart.upperBound..<authority.endIndex))
        let allowed = String(authority[allowedStart.lowerBound..<allowedEnd.lowerBound])
        XCTAssertTrue(allowed.contains("(.prepared, .observedPendingDesigner)"))
        XCTAssertTrue(allowed.contains("(.observedPendingDesigner, .observed)"))
        XCTAssertFalse(allowed.contains("(.prepared, .observed)"))

        let helperSources = [
            "observer": observer, "designer": designer,
            "observer-wrapper": observerWrapper, "designer-wrapper": designerWrapper,
        ]
        let forbiddenPrivacy = [
            "NSPasteboard", "generalPasteboard", "pasteboardWithName", "pbcopy", "pbpaste",
            "readObjects", "canReadObject", "writeObjects", "clearContents", "declareTypes",
            "data(forType:", "string(forType:", "setData", "setString",
            "NSApp.sendAction", "sendAction(", "#selector", "paste:",
            "performKeyEquivalent", "CGEventCreateKeyboardEvent", "NSEvent.keyEvent",
            "osascript", "System Events", "keystroke", "key code 9", "Command-V", "⌘V",
        ]
        for (name, helper) in helperSources {
            for forbidden in forbiddenPrivacy {
                XCTAssertFalse(helper.contains(forbidden), "\(name) privacy escape: \(forbidden)")
            }
        }
        for (name, wrapper) in ["observer": observerWrapper, "designer": designerWrapper] {
            for forbidden in ["eval", "sh -c", "bash -c", "\"$@\""] {
                XCTAssertFalse(wrapper.contains(forbidden), "\(name) arbitrary command: \(forbidden)")
            }
        }

        let axStart = try XCTUnwrap(observer.range(of: "let value: [String: Any] = ["))
        let axEnd = try XCTUnwrap(observer.range(
            of: "return try JSONSerialization.data", range: axStart.upperBound..<observer.endIndex))
        let axSchema = String(observer[axStart.lowerBound..<axEnd.lowerBound])
        XCTAssertEqual(try dictionaryKeys(in: axSchema), [
            "schema", "itemID", "windowCount", "elementCount", "focusedCount",
            "settableValueCount", "finiteFrameCount", "roleCounts",
        ])
        let commandStart = try XCTUnwrap(observer.range(
            of: "let command: [String: Any] = ["))
        let commandEnd = try XCTUnwrap(observer.range(
            of: "try privateWrite(JSONSerialization.data", range: commandStart.upperBound..<observer.endIndex))
        let commandSchema = String(observer[commandStart.lowerBound..<commandEnd.lowerBound])
        XCTAssertEqual(try dictionaryKeys(in: commandSchema), [
            "schema", "commandID", "captureStatus", "axStatus", "windowID",
            "screenshotSHA256", "axReportSHA256", "operationLogSHA256",
        ])
        let attestationStart = try XCTUnwrap(authority.range(
            of: "let attestation: [String: Any] = ["))
        let attestationEnd = try XCTUnwrap(authority.range(
            of: "let attestationURL", range: attestationStart.upperBound..<authority.endIndex))
        let attestationSchema = String(
            authority[attestationStart.lowerBound..<attestationEnd.lowerBound])
        XCTAssertEqual(try dictionaryKeys(in: attestationSchema), [
            "schema", "verdict", "checklistPassed", "checklistTotal",
            "sealedEvidenceSHA256", "designerPID", "designerProcessStart", "timestamp",
        ])
        let forbiddenSchemaNames = ["text", "enteredText", "value", "selectedText", "clipboard",
                                    "pasteboard", "sentinel", "axValue", "description", "label", "help"]
        for schema in [axSchema, commandSchema, attestationSchema] {
            for forbidden in forbiddenSchemaNames {
                XCTAssertFalse(schema.contains("\"\(forbidden)\""), forbidden)
            }
        }

        let pasteStart = try XCTUnwrap(observer.range(of: "private func verifyManualPaste"))
        let pasteEnd = try XCTUnwrap(observer.range(
            of: "func captureIntegratedInstalledObservation",
            range: pasteStart.upperBound..<observer.endIndex))
        let manualPaste = String(observer[pasteStart.lowerBound..<pasteEnd.lowerBound])
        XCTAssertEqual(manualPaste.components(
            separatedBy: "observerAXValue(names[0], kAXValueAttribute as CFString)").count - 1, 1)
        XCTAssertTrue(manualPaste.contains("as? String == sentinel"))
        for forbidden in ["let value", "print(", "privateWrite", "JSONSerialization",
                          "operationLog", "sha256", "\\(sentinel)"] {
            XCTAssertFalse(manualPaste.contains(forbidden), forbidden)
        }
        XCTAssertEqual(observer.components(
            separatedBy: "sentinel: checklist.fixedPasteSentinel").count - 1, 1)
        let checklistData = try Data(contentsOf: root.appendingPathComponent(
            "scripts/installed-signoff-checklist-v1.json"))
        let checklist = try XCTUnwrap(JSONSerialization.jsonObject(with: checklistData) as? [String: Any])
        let fixedSentinel = try XCTUnwrap(checklist["fixedPasteSentinel"] as? String)
        for (name, helper) in helperSources {
            XCTAssertFalse(helper.contains(fixedSentinel), "\(name) exposed fixed sentinel")
            for line in helper.split(separator: "\n") where
                line.contains("print(") || line.contains("echo ") || line.contains("printf") {
                for forbidden in ["sentinel", "fixedPasteSentinel", "observerAXValue",
                                  "kAXValueAttribute", "answer", "NSPasteboard", "pasteboard",
                                  "clipboardData", "enteredText"] {
                    XCTAssertFalse(line.contains(forbidden), "\(name) output sink: \(line)")
                }
            }
        }
        for hook in [".githooks/pre-commit", ".githooks/post-commit", ".githooks/pre-push"] {
            let value = try source(hook)
            XCTAssertFalse(value.contains("--no-verify"))
            XCTAssertTrue(value.contains("installed-signoff-receipt.sh"))
        }
    }
}

final class CraftingRecipeTypeaheadTextEntryTests: XCTestCase {
    func testRollingSuffixIsCharacterAndByteBounded() {
        var value = CraftingRecipeTypeahead(maxRows: 8, maxQueryLength: 48)
        value.open(plans: [])
        XCTAssertTrue(value.append(String(repeating: "a", count: 49), plans: []))
        XCTAssertEqual(value.query.count, 48)
        XCTAssertTrue(value.append("👩‍💻", plans: []))
        XCTAssertEqual(value.query.count, 48)
        XCTAssertLessThanOrEqual(value.query.utf8.count, 1_024)
        XCTAssertTrue(value.deleteBackward(plans: []))
        XCTAssertEqual(value.query.count, 47)
    }

    func testInvalidCharacterStopsProposalAtFirstInvalid() {
        var value = CraftingRecipeTypeahead()
        value.open(plans: [])
        XCTAssertTrue(value.append("abc\nignored", plans: []))
        XCTAssertEqual(value.query, "abc")
        XCTAssertFalse(value.append("\u{202E}hidden", plans: []))
        XCTAssertEqual(value.query, "abc")
        value.close()
        XCTAssertEqual(value.query, "")
    }
}
