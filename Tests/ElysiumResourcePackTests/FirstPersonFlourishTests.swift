import Foundation
import XCTest
@testable import Elysium

final class FirstPersonFlourishTests: XCTestCase {
    private func freshFlip() -> HeldEquipmentAnimationState {
        var state = HeldEquipmentAnimationState()
        XCTAssertEqual(state.observe(itemID: 10, at: 0, eligible: true), 1)
        XCTAssertEqual(state.observe(itemID: 20, at: 1, eligible: true), 0)
        return state
    }

    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        let radians = (a - b) * .pi * 2
        return abs(atan2(sin(radians), cos(radians)))
    }

    func testOldObserveAPIPreservesUninterruptedFullTurn() {
        var state = freshFlip()
        XCTAssertEqual(state.observe(itemID: 20, at: 1.31, eligible: true), 0.5, accuracy: 0.000001)
        XCTAssertEqual(state.observe(itemID: 20, at: 1.62, eligible: true), 1)
        XCTAssertNil(state.flipStartedAt)
    }

    func testEarlyInterruptionIsContinuousEasesToNearestRestAndNeverResumes() {
        var state = freshFlip()
        let before = state.observe(itemID: 20, at: 1.20, eligible: true)
        let interrupted = state.observe(itemID: 20, at: 1.20, eligible: true, working: true)
        XCTAssertEqual(interrupted, before, accuracy: 0.000001)
        XCTAssertNil(state.flipStartedAt)
        let halfway = state.observe(itemID: 20, at: 1.24, eligible: true, working: true)
        XCTAssertEqual(halfway, before * 0.5, accuracy: 0.000001)
        let nearlyRest = state.observe(itemID: 20, at: 1.279999, eligible: true, working: true)
        let rest = state.observe(itemID: 20, at: 1.28, eligible: true, working: true)
        XCTAssertLessThan(angularDistance(nearlyRest, rest), 0.000001)
        XCTAssertEqual(rest, 1)
        XCTAssertNil(state.interruptionStartedAt)
        for now in [1.29, 1.35, 1.50, 1.60, 2.0] {
            XCTAssertEqual(state.observe(itemID: 20, at: now, eligible: true), 1,
                           "releasing work must not resume the cancelled timer")
        }
    }

    func testLateInterruptionMovesForwardToNearestFullTurn() {
        var state = freshFlip()
        let now = 1 + HELD_EQUIP_FLIP_DURATION * 0.75
        let start = state.observe(itemID: 20, at: now, eligible: true, working: true)
        XCTAssertEqual(start, 0.75, accuracy: 0.000001)
        let halfway = state.observe(itemID: 20, at: now + 0.04, eligible: true, working: true)
        XCTAssertEqual(halfway, 0.875, accuracy: 0.000001)
        XCTAssertEqual(state.observe(itemID: 20, at: now + 0.08, eligible: true), 1)
        XCTAssertEqual(state.observe(itemID: 20, at: now + 0.10, eligible: true), 1)
    }

    func testReleaseDuringInterruptionFinishesEaseWithoutRestartingFlourish() {
        var state = freshFlip()
        let start = state.observe(itemID: 20, at: 1.20, eligible: true, working: true)
        let continued = state.observe(itemID: 20, at: 1.22, eligible: true, working: false)
        XCTAssertGreaterThan(continued, 0)
        XCTAssertLessThan(continued, start)
        XCTAssertEqual(state.observe(itemID: 20, at: 1.28, eligible: true), 1)
        XCTAssertEqual(state.observe(itemID: 20, at: 1.32, eligible: true), 1)
    }

    func testItemSelectedDuringWorkDoesNotTwirlAfterRelease() {
        var state = freshFlip()
        XCTAssertEqual(state.observe(itemID: 30, at: 1.20, eligible: true, working: true), 1)
        XCTAssertEqual(state.observe(itemID: 30, at: 1.30, eligible: true), 1)
        XCTAssertEqual(state.observe(itemID: 30, at: 1.40, eligible: true), 1)
        XCTAssertNil(state.flipStartedAt)
    }

    func testSelectionDuringWorkStaysSuppressedWhenDisplayedAfterWorkEnds() {
        var state = HeldEquipmentAnimationState()
        XCTAssertEqual(state.observe(itemID: 10, at: 0, eligible: true, selectedItemID: 10), 1)
        XCTAssertEqual(state.observe(itemID: 10, at: 1, eligible: true,
                                     working: true, selectedItemID: 20), 1)
        // The outgoing item is still lowering, but the real action has finished.
        XCTAssertEqual(state.observe(itemID: 10, at: 1.05, eligible: true, selectedItemID: 20), 1)
        XCTAssertEqual(state.observe(itemID: 20, at: 1.14, eligible: true, selectedItemID: 20), 1)
        XCTAssertEqual(state.observe(itemID: 20, at: 1.30, eligible: true, selectedItemID: 20), 1)
        // A later ordinary idle equip still receives its one-shot flourish.
        XCTAssertEqual(state.observe(itemID: 20, at: 2, eligible: true, selectedItemID: 30), 1)
        XCTAssertEqual(state.observe(itemID: 30, at: 2.14, eligible: true, selectedItemID: 30), 0)
        XCTAssertEqual(state.observe(itemID: 30, at: 2.45, eligible: true, selectedItemID: 30), 0.5,
                       accuracy: 0.000001)
    }

    func testResetImmediatelyCancelsTurnAndInterruptionForReducedMotion() {
        var state = freshFlip()
        _ = state.observe(itemID: 20, at: 1.20, eligible: true, working: true)
        state.reset(to: 20)
        XCTAssertNil(state.flipStartedAt)
        XCTAssertNil(state.interruptionStartedAt)
        XCTAssertEqual(state.observe(itemID: 20, at: 1.21, eligible: true), 1)
    }

    func testInterruptionAlwaysStaysNormalizedAndDoesNotRestartOnRepeatedWorkFrames() {
        for initial in [0.01, 0.25, 0.5, 0.75, 0.99] {
            var state = freshFlip()
            let start = 1 + initial * HELD_EQUIP_FLIP_DURATION
            for frame in 0...20 {
                let value = state.observe(itemID: 20, at: start + Double(frame) * 0.005,
                                          eligible: true, working: true)
                XCTAssertTrue(value.isFinite)
                XCTAssertTrue((0...1).contains(value))
            }
            XCTAssertNil(state.interruptionStartedAt)
            XCTAssertNil(state.flipStartedAt)
        }
    }
}
