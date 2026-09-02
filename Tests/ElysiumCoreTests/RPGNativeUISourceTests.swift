import Foundation
import XCTest

/// Source-level contracts for the AppKit/SwiftUI shell. The app target is intentionally not a
/// dependency of ElysiumCoreTests, so these checks protect the native presentation and its guarded
/// handoff without creating a second executable runtime in the unit-test process.
final class RPGNativeUISourceTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                   encoding: .utf8)
    }

    private func nativeSources() throws -> String {
        let directory = repositoryRoot.appendingPathComponent("Sources/Elysium/RPGNativeUI")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    func testCharacterWorkspaceUsesAStandardRestorableMacWindow() throws {
        let controller = try source("Sources/Elysium/RPGNativeUI/RPGNativeWindowController.swift")
        for required in [
            "final class RPGNativeWindowController: NSObject, NSWindowDelegate",
            "let window = NSWindow(",
            "styleMask: [.titled, .closable, .resizable, .miniaturizable]",
            "window.contentMinSize = NSSize(width: 980, height: 620)",
            "window.toolbarStyle = .unified",
            "NSHostingView(rootView: RPGNativeCharacterView(model: model))",
            "setFrameAutosaveName(\"ElysiumRPGCharacterWindow\")",
            "parent.addChildWindow(window, ordered: .above)",
            "func windowShouldClose(_ sender: NSWindow) -> Bool",
            "model?.requestClose()",
        ] {
            XCTAssertTrue(controller.contains(required), required)
        }
    }

    func testNativeHierarchyUsesMacControlsForEveryCharacterFlow() throws {
        let native = try nativeSources()
        for required in [
            "NavigationSplitView", "List(selection:", "Form {", "Picker(\"Loadout\"",
            "HSplitView", "ProgressView", "DisclosureGroup", ".confirmationDialog(",
            ".alert(\"Discard Character Draft?\"", ".keyboardShortcut(.defaultAction)",
            ".onExitCommand",
        ] {
            XCTAssertTrue(native.contains(required), required)
        }
        for forbidden in [
            "UICanvas", "drawRPGIcon", "fillRect(", "drawText(", "MTKView",
            "player.rpg =", "requestRPG", "rpgLearnSkill(", "rpgPrepareSkill(",
        ] {
            XCTAssertFalse(native.contains(forbidden), forbidden)
        }
    }

    func testNativeActionsRemainReceiptBoundAndCanvasAccessibilityIsNotDuplicated() throws {
        let model = try source("Sources/Elysium/RPGNativeUI/RPGNativeViewModel.swift")
        XCTAssertTrue(model.contains("descriptor(for: command)?.isActionable == true"))
        XCTAssertTrue(model.contains("let descriptor = descriptor(for: command), descriptor.isActionable"))
        XCTAssertTrue(model.contains("screen.activateNativeElement(descriptor.id)"))
        XCTAssertFalse(model.contains("GameCore"))
        XCTAssertFalse(model.contains("captureRPGSemanticActivation"))

        let screen = try source("Sources/Elysium/RPGScreensM.swift")
        XCTAssertTrue(screen.contains("ui.captureRPGSemanticActivation(id: id, on: self)"))
        XCTAssertTrue(screen.contains("ui.dispatchRPGSemanticActivation("))
        XCTAssertTrue(screen.contains("nativePresentationAvailable ? nil : rpgCommittedSemanticSnapshot"))
        XCTAssertTrue(screen.contains("if nativePresentationAvailable { ui.invalidateRPGAccessibilityCache() }"))
    }

    func testNativePresentationBlocksEveryLegacyCanvasInputIngress() throws {
        let screen = try source("Sources/Elysium/RPGScreensM.swift")
        let guardedSegments = [
            ("override func focusSemanticElement", "#if DEBUG"),
            ("override func onMouseDown", "override func onMouseUp"),
            ("override func onMouseUp", "override func onMouseMove"),
            ("override func onMouseMove", "override func onWheel"),
            ("override func onWheel", "override func onKeyEvent"),
            ("override func onKeyEvent", "override func onKey("),
            ("override func onKey(", "override func onChar"),
            ("func handleRPGControllerCommand", "override func handleRPGPresentationCommand"),
        ]
        for (startMarker, endMarker) in guardedSegments {
            let start = try XCTUnwrap(screen.range(of: startMarker), startMarker)
            let end = try XCTUnwrap(screen.range(
                of: endMarker, range: start.upperBound..<screen.endIndex), endMarker)
            let segment = String(screen[start.lowerBound..<end.lowerBound])
            XCTAssertTrue(segment.contains("guard !nativePresentationAvailable else"), startMarker)
        }
        XCTAssertTrue(screen.contains(
            "override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {\n" +
            "        nativePresentationAvailable\n"))
    }

    func testCreationAndProgressSurfacesExposeConsequencesAndCanonicalRules() throws {
        let path = try source("Sources/Elysium/RPGNativeUI/RPGPathSelectionView.swift")
        XCTAssertTrue(path.contains("How \\(path.displayName) Earns Class XP"))
        XCTAssertTrue(path.contains("identity.progressionCriteria"))
        XCTAssertTrue(path.contains("criterion.criterion"))
        XCTAssertTrue(path.contains("criterion.reward"))
        XCTAssertTrue(path.contains("criterion.limit"))

        let starting = try source("Sources/Elysium/RPGNativeUI/RPGStartingSkillsView.swift")
        XCTAssertTrue(starting.contains("Choose exactly three"))
        XCTAssertTrue(starting.contains("One signature skill from each"))
        XCTAssertTrue(starting.contains("any skill from your selected sub-class"))
        XCTAssertTrue(starting.contains("the signature skill from each sibling sub-class"))
        XCTAssertTrue(starting.contains("3 of 3 chosen. Unchoose a skill"))
        XCTAssertTrue(starting.contains(".disabled(atLimit && !selected)"))

        let branch = try source("Sources/Elysium/RPGNativeUI/RPGBranchSelectionView.swift")
        XCTAssertTrue(branch.contains("Signature unlock:"))
        XCTAssertTrue(branch.contains("spell.displayName"))

        let review = try source("Sources/Elysium/RPGNativeUI/RPGCreationReviewView.swift")
        XCTAssertTrue(review.contains("are permanent for this character in this world"))
        XCTAssertTrue(review.contains("SwiftUI.Button(\"Create Character\")"))
        XCTAssertTrue(review.contains("Section(\"Exact Class XP Rules\")"))
        XCTAssertTrue(review.contains("identity.progressionCriteria"))
        XCTAssertTrue(review.contains("id: \\.offset"))

        let creationWorkspace = try source(
            "Sources/Elysium/RPGNativeUI/RPGCreationWorkspaceView.swift")
        XCTAssertTrue(creationWorkspace.contains("List {"))
        XCTAssertTrue(creationWorkspace.contains("\"Completed\""))
        XCTAssertTrue(creationWorkspace.contains("\"Current\""))
        XCTAssertTrue(creationWorkspace.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertFalse(creationWorkspace.contains("List(selection:"))
        XCTAssertFalse(creationWorkspace.contains("set: { _ in }"))

        let progress = try source("Sources/Elysium/RPGNativeUI/RPGProgressView.swift")
        for required in [
            "identity.progressionCriteria", "criterion.criterion", "criterion.reward",
            "criterion.limit", "progression.plan.selectedBranchDisplayName",
            "DisclosureGroup(\"Show all 20 levels\"", "Level status",
            "complete ? \"Completed\" : \"Not completed\"",
        ] {
            XCTAssertTrue(progress.contains(required), required)
        }

        let loadout = try source("Sources/Elysium/RPGNativeUI/RPGLoadoutView.swift")
        XCTAssertEqual(loadout.components(separatedBy: "rpgActionResourceQuote(").count - 1, 4)
        XCTAssertTrue(loadout.contains("Effective fatigue"))
        XCTAssertTrue(loadout.contains("Effective cooldown"))
        XCTAssertTrue(loadout.contains("quote.cooldownRemainingTicks"))
        XCTAssertTrue(loadout.contains("quote.resourceAvailable"))
        XCTAssertTrue(loadout.contains("LabeledContent(\"Fatigue and cooldown\""))
        XCTAssertEqual(loadout.components(separatedBy:
            ".accessibilityValue(assigned ? \"Assigned\" : \"Not assigned\")").count - 1, 2)
        XCTAssertGreaterThanOrEqual(loadout.components(separatedBy:
            "Image(systemName: \"checkmark\")").count - 1, 2)
        for contextualLabel in [
            "accessibilityLabel(\"\\(prepared ? \"Unprepare\" : \"Prepare\") \\(skill.displayName)\")",
            "? \"\\(skill.displayName), selected for use\"",
            ": \"Select \\(skill.displayName) for use\"",
            "accessibilityLabel(\"\\(prepared ? \"Unprepare\" : \"Prepare\") \\(spell.displayName)\")",
            "? \"\\(spell.displayName), selected for use\"",
            ": \"Select \\(spell.displayName) for use\"",
            "accessibilityLabel(\"Move quick slot \\(slot + 1) left\")",
            "accessibilityLabel(\"Move quick slot \\(slot + 1) right\")",
            "accessibilityLabel(\"Clear quick slot \\(slot + 1)\")",
        ] {
            XCTAssertTrue(loadout.contains(contextualLabel), contextualLabel)
        }
        XCTAssertTrue(loadout.contains("rpgSpellUnlockProjections(pathID:"))
        XCTAssertTrue(loadout.contains("LabeledContent(\"Unlock requirement\""))

        let viewModel = try source("Sources/Elysium/RPGNativeUI/RPGNativeViewModel.swift")
        XCTAssertTrue(viewModel.contains("let previousCreation = self.creation"))
        XCTAssertTrue(viewModel.contains("previousCreation.step != .path"))
        XCTAssertTrue(viewModel.contains("previousCreation.step != .branch"))
        XCTAssertEqual(viewModel.components(separatedBy:
            "rpgPreferredActiveSkillID(").count - 1, 2)
        XCTAssertTrue(viewModel.contains("selectedActiveSkillWasExplicit = true"))
        XCTAssertTrue(viewModel.contains("currentIsExplicit: selectedActiveSkillWasExplicit"))
    }

    func testCharacterWindowHasStableGameMenuDiscovery() throws {
        let main = try source("Sources/Elysium/main.swift")
        XCTAssertTrue(main.contains("title: \"Character…\""))
        XCTAssertTrue(main.contains("#selector(AppDelegate.openCharacterWindow(_:))"))
        XCTAssertTrue(main.contains("dispatchRPGWorldSemanticCommand(.openCharacter"))
        XCTAssertTrue(main.contains("NSMenuItemValidation"))
    }

    func testDecisionCardsAndStatusRetainRichVoiceOverContent() throws {
        let status = try source("Sources/Elysium/RPGNativeUI/RPGNativeStatusBanner.swift")
        XCTAssertTrue(status.contains("[status?.accessibilityText, authority.visibleHelp]"))
        XCTAssertEqual(status.components(separatedBy: "Text(authority.visibleHelp)").count - 1, 1)
        for path in [
            "Sources/Elysium/RPGNativeUI/RPGPathSelectionView.swift",
            "Sources/Elysium/RPGNativeUI/RPGBranchSelectionView.swift",
            "Sources/Elysium/RPGNativeUI/RPGStartingSkillsView.swift",
        ] {
            XCTAssertTrue(try source(path).contains(".accessibilityValue("), path)
        }
    }
}
