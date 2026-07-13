import Foundation
import XCTest
@testable import ElysiumCore

final class ControlsScreenTests: XCTestCase {
    func testDefinitionsExposeAllTwentyFiveActionsInStableOrder() {
        XCTAssertEqual(KEYBIND_DEFINITIONS.map(\.actionID), [
            "forward", "back", "left", "right", "jump", "sneak", "sprint", "inventory",
            "drop", "chat", "command", "perspective", "swapOffhand", "rpgCharacter",
            "rpgCycleAction", "rpgUseAction", "rpgQuickSlot1", "rpgQuickSlot2",
            "rpgQuickSlot3", "rpgQuickSlot4", "rpgQuickSlot5", "rpgQuickSlot6",
            "rpgQuickSlot7", "rpgQuickSlot8", "rpgQuickSlot9",
        ])
        XCTAssertEqual(Set(KEYBIND_DEFINITIONS.map(\.displayName)).count, 25)
        XCTAssertTrue(KEYBIND_DEFINITIONS.allSatisfy { !$0.displayName.isEmpty })
    }

    func testLayoutIsSingleColumnBelowBreakpointAndClampsBothEnds() {
        let bindings = rpgDefaultChordBindings()
        let first = ElysiumControlsLayout(
            viewportWidth: 360, contentTop: 72, contentBottom: 172,
            requestedScrollOffset: -.infinity, bindings: bindings)
        XCTAssertEqual(first.columnCount, 1)
        XCTAssertEqual(first.clampedScrollOffset, 0)
        XCTAssertEqual(first.visibleRows.map(\.definitionIndex), [0, 1, 2, 3])
        XCTAssertGreaterThan(first.maximumScrollOffset, 0)

        let last = ElysiumControlsLayout(
            viewportWidth: 360, contentTop: 72, contentBottom: 172,
            requestedScrollOffset: .greatestFiniteMagnitude, bindings: bindings)
        XCTAssertEqual(last.clampedScrollOffset, last.maximumScrollOffset)
        XCTAssertEqual(last.visibleRows.last?.definitionIndex, 24)
        XCTAssertTrue(last.visibleRows.allSatisfy { $0.y + $0.height > 72 && $0.y < 172 })
    }

    func testLayoutUsesTwoColumnsAtBreakpointAndBoundsNonfiniteGeometry() {
        let bindings = rpgDefaultChordBindings()
        let wide = ElysiumControlsLayout(
            viewportWidth: 520, contentTop: 72, contentBottom: 182,
            requestedScrollOffset: 0, bindings: bindings)
        XCTAssertEqual(wide.columnCount, 2)
        XCTAssertEqual(wide.visibleRows.map(\.definitionIndex), Array(0..<10))
        XCTAssertEqual(wide.visibleRows[0].y, wide.visibleRows[1].y)
        XCTAssertLessThan(wide.visibleRows[0].x, wide.visibleRows[1].x)

        let hostile = ElysiumControlsLayout(
            viewportWidth: .nan, contentTop: .infinity, contentBottom: -.infinity,
            requestedScrollOffset: .nan, bindings: bindings)
        XCTAssertEqual(hostile.columnCount, 1)
        XCTAssertEqual(hostile.clampedScrollOffset, 0)
        XCTAssertTrue(hostile.maximumScrollOffset.isFinite)
        XCTAssertTrue(hostile.visibleRows.isEmpty)
    }

    func testRequiredViewportLayoutsStayBoundedAndReachEveryDefinition() {
        let bindings = rpgDefaultChordBindings()
        for (width, height) in [(360.0, 224.0), (520.0, 330.0), (700.0, 420.0)] {
            let top = 72.0
            let bottom = height - 52
            let first = ElysiumControlsLayout(
                viewportWidth: width, contentTop: top, contentBottom: bottom,
                requestedScrollOffset: 0, bindings: bindings)
            let last = ElysiumControlsLayout(
                viewportWidth: width, contentTop: top, contentBottom: bottom,
                requestedScrollOffset: first.maximumScrollOffset, bindings: bindings)
            XCTAssertEqual(first.columnCount, width < 520 ? 1 : 2)
            XCTAssertTrue((first.visibleRows + last.visibleRows).allSatisfy {
                $0.x >= 0 && $0.x + $0.width <= width &&
                    $0.y >= top && $0.y + $0.height <= bottom
            }, "\(Int(width))x\(Int(height))")
            let reachable = Set(first.visibleRows.map(\.definitionIndex)
                + last.visibleRows.map(\.definitionIndex))
            if first.maximumScrollOffset == 0 {
                XCTAssertEqual(reachable, Set(0..<25))
            } else {
                XCTAssertTrue(reachable.contains(0))
                XCTAssertTrue(reachable.contains(24))
            }
        }
    }

    func testCandidateCanonicalizesWithoutMutatingPublishedBindings() throws {
        let live = rpgDefaultChordBindings()
        let chord = try ElysiumKeyChord(parsing: "Command+Control+Option+Shift+F12")
        guard case .ready(let actionID, let returnedChord, let candidate) =
            prepareControlsKeybindCandidate(
                bindings: live, actionID: "rpgCharacter", chord: chord) else {
            return XCTFail("nonconflicting canonical chord should be ready")
        }
        XCTAssertEqual(actionID, "rpgCharacter")
        XCTAssertEqual(returnedChord.description, "Command+Control+Option+Shift+F12")
        XCTAssertEqual(candidate["rpgCharacter"], returnedChord.description)
        XCTAssertEqual(live["rpgCharacter"], "KeyK")
        XCTAssertEqual(candidate.filter { live[$0.key] != $0.value }.map(\.key), ["rpgCharacter"])
    }

    func testConflictNamesEveryActionAndKeepsDetachedCandidate() throws {
        let live = rpgDefaultChordBindings()
        let chord = try ElysiumKeyChord(parsing: "KeyW")
        guard case .conflict(let pending) = prepareControlsKeybindCandidate(
            bindings: live, actionID: "rpgCharacter", chord: chord) else {
            return XCTFail("colliding chord should require confirmation")
        }
        XCTAssertEqual(pending.actionID, "rpgCharacter")
        XCTAssertEqual(pending.conflictingActionIDs, ["rpgCharacter", "forward"])
        XCTAssertEqual(pending.winnerActionID, "rpgCharacter")
        XCTAssertEqual(pending.candidateBindings["rpgCharacter"], "KeyW")
        XCTAssertEqual(live["rpgCharacter"], "KeyK")
    }

    func testConflictDisclosureIsBoundedAndIncludesAllTwentyFiveActions() throws {
        var live = rpgDefaultChordBindings()
        for definition in KEYBIND_DEFINITIONS {
            live[definition.actionID] = "Option+F12"
        }
        guard case .conflict(let pending) = prepareControlsKeybindCandidate(
            bindings: live, actionID: "forward",
            chord: try ElysiumKeyChord(parsing: "Option+F12")) else {
            return XCTFail("shared chord should disclose the complete conflict")
        }
        XCTAssertEqual(pending.conflictingActionIDs.count, 25)
        XCTAssertEqual(Set(pending.conflictingActionIDs), Set(KEYBIND_DEFINITIONS.map(\.actionID)))
        XCTAssertEqual(pending.winnerActionID, "inventory")
    }

    func testProtectedAndStructurallyInvalidCandidatesFailClosed() throws {
        let live = rpgDefaultChordBindings()
        for raw in ["F11", "Shift+F11", "Command+KeyQ", "Command+KeyZ"] {
            XCTAssertEqual(prepareControlsKeybindCandidate(
                bindings: live, actionID: "forward", chord: try ElysiumKeyChord(parsing: raw)),
                .reserved, raw)
        }
        XCTAssertEqual(prepareControlsKeybindCandidate(
            bindings: live, actionID: "unknown",
            chord: try ElysiumKeyChord(parsing: "F12")), .invalidAction)
        var missing = live
        missing.removeValue(forKey: "back")
        XCTAssertEqual(prepareControlsKeybindCandidate(
            bindings: missing, actionID: "forward",
            chord: try ElysiumKeyChord(parsing: "F12")), .invalidBindings)
    }

    func testProductionControlsSourceUsesCandidateBeforePublicationAndNoFixedBindingList() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository
            .appendingPathComponent("Sources/Elysium/MenusM.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ElysiumControlsLayout("))
        XCTAssertTrue(source.contains("KEYBIND_DEFINITIONS[row.definitionIndex]"))
        XCTAssertTrue(source.contains("prepareControlsKeybindCandidate("))
        XCTAssertTrue(source.contains("persistAndPublishKeybindCandidate("))
        XCTAssertTrue(source.contains("Reserved by Elysium"))
        XCTAssertTrue(source.contains("Use Anyway"))
        XCTAssertFalse(source.contains("let binds: [(String, String)]"))
        XCTAssertFalse(source.contains("game.keybinds[actionID] ="))
    }
}
