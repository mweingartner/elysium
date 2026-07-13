import XCTest
@testable import ElysiumCore

final class RPGControllerInputTests: XCTestCase {
    func testSheetMappingsHysteresisAndNeutralRearm() {
        var input = RPGControllerInput()
        input.transition(to: .sheet)
        XCTAssertTrue(input.update(control: .dpadRight, value: 0, timestampMilliseconds: 0).isEmpty)
        XCTAssertEqual(input.update(control: .dpadRight, value: 0.60, timestampMilliseconds: 0),
                       [.moveFocus(.right)])
        XCTAssertTrue(input.update(control: .dpadRight, value: 1, timestampMilliseconds: 1).isEmpty)
        XCTAssertTrue(input.update(control: .dpadRight, value: 0.36, timestampMilliseconds: 2).isEmpty)
        XCTAssertTrue(input.update(control: .dpadRight, value: 0.35, timestampMilliseconds: 3).isEmpty)
        XCTAssertEqual(input.update(control: .dpadRight, value: 0.60, timestampMilliseconds: 4),
                       [.moveFocus(.right)])
        XCTAssertTrue(input.update(control: .buttonA, value: 0, timestampMilliseconds: 5).isEmpty)
        XCTAssertTrue(input.update(control: .buttonB, value: 0, timestampMilliseconds: 5).isEmpty)
        XCTAssertEqual(input.update(control: .buttonA, value: 1, timestampMilliseconds: 6), [.activate])
        XCTAssertEqual(input.update(control: .buttonB, value: 1, timestampMilliseconds: 7), [.back])
    }

    func testWorldMappingsSlotsAndContextResetRequireNeutral() {
        var input = RPGControllerInput()
        input.transition(to: .world)
        for control in [RPGControllerControl.options, .leftShoulder, .rightShoulder, .leftTrigger, .buttonY] {
            XCTAssertTrue(input.update(control: control, value: 0, timestampMilliseconds: 0).isEmpty)
        }
        XCTAssertEqual(input.update(control: .options, value: 1, timestampMilliseconds: 0), [.openCharacter])
        XCTAssertEqual(input.update(control: .leftShoulder, value: 1, timestampMilliseconds: 1),
                       [.cyclePreparedAction])
        XCTAssertEqual(input.update(control: .rightShoulder, value: 1, timestampMilliseconds: 2),
                       [.useSelectedAction])
        XCTAssertTrue(input.update(control: .leftTrigger, value: 0.65, timestampMilliseconds: 3).isEmpty)
        XCTAssertEqual(input.update(control: .buttonY, value: 1, timestampMilliseconds: 4), [.useQuickSlot(4)])
        input.transition(to: .sheet)
        XCTAssertTrue(input.update(control: .buttonY, value: 1, timestampMilliseconds: 5).isEmpty)
        XCTAssertTrue(input.update(control: .buttonY, value: 0, timestampMilliseconds: 6).isEmpty)
    }

    func testScrollRepeatCatchupIsCapped() {
        var input = RPGControllerInput()
        input.transition(to: .sheet)
        XCTAssertTrue(input.update(control: .rightStickDown, value: 0, timestampMilliseconds: 0).isEmpty)
        XCTAssertEqual(input.update(control: .rightStickDown, value: 1, timestampMilliseconds: 0),
                       [.scrollRows(1)])
        let repeats = input.update(control: .rightStickDown, value: 1, timestampMilliseconds: 10_000)
        XCTAssertEqual(repeats.count, RPGControllerInput.maximumRepeatsPerUpdate)
        XCTAssertTrue(repeats.allSatisfy { $0 == .scrollRows(1) })
    }

    func testGenerationGateRejectsDelayedCallbacksAndRequiresNeutralClaim() throws {
        var gate = RPGControllerGenerationGate()
        XCTAssertNil(gate.claimAfterInput(controllerID: "controller-a"))
        gate.noteNeutral(controllerID: "controller-a")
        let first = try XCTUnwrap(gate.claimAfterInput(controllerID: "controller-a"))
        XCTAssertTrue(gate.accepts(first))
        gate.contextBoundary()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertNil(gate.activeControllerID)
        XCTAssertNil(gate.claimAfterInput(controllerID: "controller-a"))
        gate.noteNeutral(controllerID: "controller-a")
        let second = try XCTUnwrap(gate.claimAfterInput(controllerID: "controller-a"))
        XCTAssertTrue(gate.accepts(second))
        gate.disconnectOrReplace()
        XCTAssertFalse(gate.accepts(second))
    }

    func testEveryBoundaryClearsOwnershipAndGenerationExhaustionFailsClosed() throws {
        for boundary in ["context", "disconnect"] {
            var gate = RPGControllerGenerationGate()
            gate.noteNeutral(controllerID: "controller")
            let identity = try XCTUnwrap(gate.claimAfterInput(controllerID: "controller"))
            if boundary == "context" { gate.contextBoundary() } else { gate.disconnectOrReplace() }
            XCTAssertNil(gate.activeControllerID)
            XCTAssertFalse(gate.accepts(identity))
            XCTAssertNil(gate.claimAfterInput(controllerID: "controller"))
            gate.noteNeutral(controllerID: "controller")
            XCTAssertNotNil(gate.claimAfterInput(controllerID: "controller"))
        }

        var contextExhausted = RPGControllerGenerationGate(contextGeneration: UInt64.max)
        contextExhausted.noteNeutral(controllerID: "controller")
        XCTAssertNotNil(contextExhausted.claimAfterInput(controllerID: "controller"))
        contextExhausted.contextBoundary()
        XCTAssertTrue(contextExhausted.generationExhausted)
        XCTAssertNil(contextExhausted.currentIdentity)
        contextExhausted.noteNeutral(controllerID: "controller")
        XCTAssertNil(contextExhausted.claimAfterInput(controllerID: "controller"))

        var adapterExhausted = RPGControllerGenerationGate(adapterGeneration: UInt64.max)
        adapterExhausted.noteNeutral(controllerID: "controller")
        XCTAssertNotNil(adapterExhausted.claimAfterInput(controllerID: "controller"))
        adapterExhausted.disconnectOrReplace()
        XCTAssertTrue(adapterExhausted.generationExhausted)
        XCTAssertNil(adapterExhausted.currentIdentity)
    }

    func testEverySheetWorldAndNineSlotMapping() {
        let sheetMappings: [(RPGControllerControl, RPGSemanticCommand)] = [
            (.dpadUp, .moveFocus(.up)), (.dpadRight, .moveFocus(.right)),
            (.dpadDown, .moveFocus(.down)), (.dpadLeft, .moveFocus(.left)),
            (.leftStickUp, .moveFocus(.up)), (.leftStickRight, .moveFocus(.right)),
            (.leftStickDown, .moveFocus(.down)), (.leftStickLeft, .moveFocus(.left)),
            (.buttonA, .activate), (.buttonB, .back),
            (.leftShoulder, .previousTab), (.rightShoulder, .nextTab),
        ]
        for (control, expected) in sheetMappings {
            var input = RPGControllerInput()
            input.transition(to: .sheet)
            XCTAssertTrue(input.update(control: control, value: 0, timestampMilliseconds: 0).isEmpty)
            XCTAssertEqual(input.update(control: control, value: 1, timestampMilliseconds: 1), [expected],
                           "sheet \(control)")
        }
        for (control, expected) in [(RPGControllerControl.rightStickUp, RPGSemanticCommand.scrollRows(-1)),
                                    (.rightStickDown, .scrollRows(1))] {
            var input = RPGControllerInput()
            input.transition(to: .sheet)
            _ = input.update(control: control, value: 0, timestampMilliseconds: 0)
            XCTAssertEqual(input.update(control: control, value: 1, timestampMilliseconds: 1), [expected])
        }

        let worldMappings: [(RPGControllerControl, RPGSemanticCommand)] = [
            (.options, .openCharacter), (.leftShoulder, .cyclePreparedAction),
            (.rightShoulder, .useSelectedAction),
        ]
        for (control, expected) in worldMappings {
            var input = RPGControllerInput()
            input.transition(to: .world)
            _ = input.update(control: control, value: 0, timestampMilliseconds: 0)
            XCTAssertEqual(input.update(control: control, value: 1, timestampMilliseconds: 1), [expected])
        }

        let slotControls: [RPGControllerControl] = [
            .dpadUp, .dpadRight, .dpadDown, .dpadLeft,
            .buttonY, .buttonB, .buttonA, .buttonX, .rightStickClick,
        ]
        for (slot, control) in slotControls.enumerated() {
            var input = RPGControllerInput()
            input.transition(to: .world)
            _ = input.update(control: .leftTrigger, value: 0, timestampMilliseconds: 0)
            _ = input.update(control: control, value: 0, timestampMilliseconds: 0)
            XCTAssertTrue(input.update(control: .leftTrigger, value: 1, timestampMilliseconds: 1).isEmpty)
            XCTAssertEqual(input.update(control: control, value: 1, timestampMilliseconds: 2),
                           [.useQuickSlot(slot)], "slot \(slot + 1)")
        }
    }

    func testEveryLifecycleTransitionRequiresNeutralRearm() {
        var input = RPGControllerInput()
        input.transition(to: .sheet)
        _ = input.update(control: .buttonA, value: 0, timestampMilliseconds: 0)
        XCTAssertEqual(input.update(control: .buttonA, value: 1, timestampMilliseconds: 1), [.activate])

        input.resetForLifecycleBoundary()
        input.transition(to: .sheet)
        XCTAssertTrue(input.update(control: .buttonA, value: 1, timestampMilliseconds: 2).isEmpty)
        XCTAssertTrue(input.update(control: .buttonA, value: 0, timestampMilliseconds: 3).isEmpty)
        XCTAssertEqual(input.update(control: .buttonA, value: 1, timestampMilliseconds: 4), [.activate])

        input.transition(to: .world)
        XCTAssertTrue(input.update(control: .leftShoulder, value: 1, timestampMilliseconds: 5).isEmpty)
        _ = input.update(control: .leftShoulder, value: 0, timestampMilliseconds: 6)
        XCTAssertEqual(input.update(control: .leftShoulder, value: 1, timestampMilliseconds: 7),
                       [.cyclePreparedAction])

        input.transition(to: .inactive)
        _ = input.update(control: .options, value: 0, timestampMilliseconds: 8)
        XCTAssertTrue(input.update(control: .options, value: 1, timestampMilliseconds: 9).isEmpty)
    }

    func testExactNavigationAndTriggerHysteresisThresholds() {
        var navigation = RPGControllerInput()
        navigation.transition(to: .sheet)
        _ = navigation.update(control: .dpadUp, value: 0, timestampMilliseconds: 0)
        XCTAssertTrue(navigation.update(control: .dpadUp, value: 0.5999,
                                        timestampMilliseconds: 1).isEmpty)
        XCTAssertEqual(navigation.update(control: .dpadUp, value: 0.60,
                                         timestampMilliseconds: 2), [.moveFocus(.up)])
        XCTAssertTrue(navigation.update(control: .dpadUp, value: 0.3501,
                                        timestampMilliseconds: 3).isEmpty)
        XCTAssertTrue(navigation.update(control: .dpadUp, value: 0.60,
                                        timestampMilliseconds: 4).isEmpty)
        _ = navigation.update(control: .dpadUp, value: 0.35, timestampMilliseconds: 5)
        XCTAssertEqual(navigation.update(control: .dpadUp, value: 0.60,
                                         timestampMilliseconds: 6), [.moveFocus(.up)])

        var trigger = RPGControllerInput()
        trigger.transition(to: .world)
        for control in [RPGControllerControl.leftTrigger, .buttonA] {
            _ = trigger.update(control: control, value: 0, timestampMilliseconds: 0)
        }
        _ = trigger.update(control: .leftTrigger, value: 0.6499, timestampMilliseconds: 1)
        XCTAssertTrue(trigger.update(control: .buttonA, value: 1,
                                     timestampMilliseconds: 2).isEmpty)
        _ = trigger.update(control: .buttonA, value: 0, timestampMilliseconds: 3)
        _ = trigger.update(control: .leftTrigger, value: 0.65, timestampMilliseconds: 4)
        XCTAssertEqual(trigger.update(control: .buttonA, value: 1,
                                      timestampMilliseconds: 5), [.useQuickSlot(6)])
        _ = trigger.update(control: .buttonA, value: 0, timestampMilliseconds: 6)
        _ = trigger.update(control: .leftTrigger, value: 0.4501, timestampMilliseconds: 7)
        XCTAssertEqual(trigger.update(control: .buttonA, value: 1,
                                      timestampMilliseconds: 8), [.useQuickSlot(6)])
        _ = trigger.update(control: .leftTrigger, value: 0.45, timestampMilliseconds: 9)
        _ = trigger.update(control: .buttonA, value: 0, timestampMilliseconds: 10)
        XCTAssertTrue(trigger.update(control: .buttonA, value: 1,
                                     timestampMilliseconds: 11).isEmpty)
    }

    func testOnePhysicalCallbackEmitsOneEdgeAndUpdatesEveryHeldState() {
        var input = RPGControllerInput()
        input.transition(to: .sheet)
        let neutral = RPGControllerControl.allCases.map {
            RPGControllerSample(control: $0, value: 0)
        }
        XCTAssertTrue(input.updateCallback(neutral, timestampMilliseconds: 0).isEmpty)
        let simultaneous = [
            RPGControllerSample(control: .buttonA, value: 1),
            RPGControllerSample(control: .buttonB, value: 1),
            RPGControllerSample(control: .rightShoulder, value: 1),
        ]
        XCTAssertEqual(input.updateCallback(simultaneous, timestampMilliseconds: 1), [.activate])
        XCTAssertTrue(input.updateCallback(simultaneous, timestampMilliseconds: 2).isEmpty)
        _ = input.updateCallback(simultaneous.map {
            RPGControllerSample(control: $0.control, value: 0)
        }, timestampMilliseconds: 3)
        XCTAssertEqual(input.updateCallback(simultaneous, timestampMilliseconds: 4), [.activate])
    }

    func testCallbackGenerationValidationRejectsDelayedFocusContextAndDisconnect() throws {
        var gate = RPGControllerGenerationGate()
        let callback = try XCTUnwrap(RPGControllerCallbackIdentity(
            controllerID: "physical-a", adapterGeneration: gate.adapterGeneration,
            contextGeneration: gate.contextGeneration))
        XCTAssertTrue(gate.acceptsCallback(callback))
        gate.contextBoundary()
        XCTAssertFalse(gate.acceptsCallback(callback))
        let afterFocus = try XCTUnwrap(RPGControllerCallbackIdentity(
            controllerID: "physical-a", adapterGeneration: gate.adapterGeneration,
            contextGeneration: gate.contextGeneration))
        XCTAssertTrue(gate.acceptsCallback(afterFocus))
        gate.disconnectOrReplace()
        XCTAssertFalse(gate.acceptsCallback(afterFocus))
    }

    func testTwoControllerNeutralThenInputArbitration() throws {
        var gate = RPGControllerGenerationGate()
        gate.noteNeutral(controllerID: "a")
        gate.noteNeutral(controllerID: "b")
        XCTAssertEqual(try XCTUnwrap(gate.claimAfterInput(controllerID: "a")).controllerID, "a")
        XCTAssertTrue(gate.isNeutralEligible(controllerID: "b"))
        gate.disconnectOrReplace()
        XCTAssertNil(gate.claimAfterInput(controllerID: "b"))
        gate.noteNeutral(controllerID: "b")
        XCTAssertEqual(try XCTUnwrap(gate.claimAfterInput(controllerID: "b")).controllerID, "b")
    }

    func testRepeatDelayIntervalAndEightCommandCatchupAreExact() {
        var input = RPGControllerInput()
        input.transition(to: .sheet)
        _ = input.update(control: .rightStickDown, value: 0, timestampMilliseconds: 0)
        XCTAssertEqual(input.update(control: .rightStickDown, value: 1,
                                    timestampMilliseconds: 100), [.scrollRows(1)])
        XCTAssertTrue(input.update(control: .rightStickDown, value: 1,
                                   timestampMilliseconds: 399).isEmpty)
        XCTAssertEqual(input.update(control: .rightStickDown, value: 1,
                                    timestampMilliseconds: 400), [.scrollRows(1)])
        XCTAssertTrue(input.update(control: .rightStickDown, value: 1,
                                   timestampMilliseconds: 489).isEmpty)
        XCTAssertEqual(input.update(control: .rightStickDown, value: 1,
                                    timestampMilliseconds: 490), [.scrollRows(1)])
        XCTAssertEqual(input.update(control: .rightStickDown, value: 1,
                                    timestampMilliseconds: 10_000).count, 8)
    }

    func testHeldRepeatTickCannotManufactureInitialEdgeOrWorldMutation() {
        var input = RPGControllerInput()
        input.transition(to: .sheet)
        XCTAssertTrue(input.updateHeldRepeat(timestampMilliseconds: 10_000).isEmpty)
        _ = input.update(control: .rightStickUp, value: 0, timestampMilliseconds: 0)
        XCTAssertEqual(input.update(control: .rightStickUp, value: 1,
                                    timestampMilliseconds: 100), [.scrollRows(-1)])
        XCTAssertTrue(input.updateHeldRepeat(timestampMilliseconds: 399).isEmpty)
        XCTAssertEqual(input.updateHeldRepeat(timestampMilliseconds: 400), [.scrollRows(-1)])
        input.transition(to: .world)
        XCTAssertTrue(input.updateHeldRepeat(timestampMilliseconds: 100_000).isEmpty)
    }

    func testConnectionBoundaryClearsStationaryRepeatRejectsOldCallbackAndRequiresNeutral() throws {
        var input = RPGControllerInput()
        var gate = RPGControllerGenerationGate()
        gate.noteNeutral(controllerID: "a")
        let activeA = try XCTUnwrap(gate.claimAfterInput(controllerID: "a"))
        let callbackA = try XCTUnwrap(RPGControllerCallbackIdentity(
            controllerID: "a", adapterGeneration: gate.adapterGeneration,
            contextGeneration: gate.contextGeneration))
        XCTAssertTrue(gate.accepts(activeA))
        XCTAssertTrue(gate.acceptsCallback(callbackA))

        input.transition(to: .sheet)
        _ = input.update(control: .rightStickDown, value: 0, timestampMilliseconds: 0)
        XCTAssertEqual(input.update(control: .rightStickDown, value: 1,
                                    timestampMilliseconds: 1), [.scrollRows(1)])

        // This is the pure seam used by a compatible-controller connection lifecycle boundary.
        input.resetForLifecycleBoundary()
        gate.disconnectOrReplace()
        XCTAssertTrue(input.updateHeldRepeat(timestampMilliseconds: 10_000).isEmpty)
        XCTAssertFalse(gate.acceptsCallback(callbackA))
        XCTAssertNil(gate.activeControllerID)
        XCTAssertNil(gate.claimAfterInput(controllerID: "a"))
        XCTAssertNil(gate.claimAfterInput(controllerID: "b"))

        gate.noteNeutral(controllerID: "a")
        gate.noteNeutral(controllerID: "b")
        XCTAssertEqual(try XCTUnwrap(gate.claimAfterInput(controllerID: "b")).controllerID, "b")
    }

    func testSameCoarseScreenContextReplacementClearsRepeatAndRejectsOldCallback() throws {
        var input = RPGControllerInput()
        var gate = RPGControllerGenerationGate()
        gate.noteNeutral(controllerID: "a")
        _ = try XCTUnwrap(gate.claimAfterInput(controllerID: "a"))
        let oldCallback = try XCTUnwrap(RPGControllerCallbackIdentity(
            controllerID: "a", adapterGeneration: gate.adapterGeneration,
            contextGeneration: gate.contextGeneration))

        input.transition(to: .sheet)
        _ = input.update(control: .rightStickUp, value: 0, timestampMilliseconds: 0)
        XCTAssertEqual(input.update(control: .rightStickUp, value: 1,
                                    timestampMilliseconds: 1), [.scrollRows(-1)])

        // RPG-sheet A -> RPG-sheet B keeps the same enum context but is an ownership boundary.
        input.resetForLifecycleBoundary()
        gate.contextBoundary()
        XCTAssertTrue(input.updateHeldRepeat(timestampMilliseconds: 10_000).isEmpty)
        XCTAssertFalse(gate.acceptsCallback(oldCallback))
        XCTAssertNil(gate.claimAfterInput(controllerID: "a"))
        gate.noteNeutral(controllerID: "a")
        XCTAssertNotNil(gate.claimAfterInput(controllerID: "a"))
    }

    func testArbitrationRequiresExactEnterThresholdNotExitBandDrift() {
        func samples(_ control: RPGControllerControl, _ value: Double) -> [RPGControllerSample] {
            [RPGControllerSample(control: control, value: value)]
        }
        XCTAssertTrue(RPGControllerInput.callbackIsNeutral(samples(.dpadRight, 0.35)))
        XCTAssertFalse(RPGControllerInput.callbackHasEnteredInput(samples(.dpadRight, 0.35)))
        XCTAssertFalse(RPGControllerInput.callbackIsNeutral(samples(.dpadRight, 0.36)))
        XCTAssertFalse(RPGControllerInput.callbackHasEnteredInput(samples(.dpadRight, 0.36)))
        XCTAssertFalse(RPGControllerInput.callbackHasEnteredInput(samples(.dpadRight, 0.5999)))
        XCTAssertTrue(RPGControllerInput.callbackHasEnteredInput(samples(.dpadRight, 0.60)))

        XCTAssertTrue(RPGControllerInput.callbackIsNeutral(samples(.leftTrigger, 0.45)))
        XCTAssertFalse(RPGControllerInput.callbackIsNeutral(samples(.leftTrigger, 0.4501)))
        XCTAssertFalse(RPGControllerInput.callbackHasEnteredInput(samples(.leftTrigger, 0.6499)))
        XCTAssertTrue(RPGControllerInput.callbackHasEnteredInput(samples(.leftTrigger, 0.65)))
        XCTAssertFalse(RPGControllerInput.callbackIsNeutral([
            RPGControllerSample(control: .dpadUp, value: .nan)
        ]))
        XCTAssertFalse(RPGControllerInput.callbackHasEnteredInput([
            RPGControllerSample(control: .dpadUp, value: .nan)
        ]))
    }
}
