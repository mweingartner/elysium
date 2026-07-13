import XCTest
@testable import ElysiumCore

final class RPGScreenInteractionTests: XCTestCase {
    private func id(_ value: String) -> RPGUIElementID {
        RPGUIElementID(rawValue: value)!
    }

    private func descriptor(_ value: String, x: Double, y: Double,
                            width: Double = 20, height: Double = 20,
                            visible: Bool = true, focusable: Bool = true,
                            enabled: Bool = true, locked: Bool = false,
                            command: RPGSemanticCommand? = nil,
                            selection: RPGScreenSelection? = nil,
                            layoutRegion: RPGSemanticLayoutRegion = .scrollingContent)
        -> RPGSemanticDescriptor {
        let frame = RPGLogicalRect(x: x, y: y, width: width, height: height)
        return RPGSemanticDescriptor(
            id: id(value), role: .button, label: value, enabled: enabled,
            locked: locked, isFocusable: focusable, focusSelection: selection,
            layoutRegion: layoutRegion,
            frame: frame, visibleFrame: visible ? frame : nil,
            actionCommand: command)
    }

    private func model(_ descriptors: [RPGSemanticDescriptor],
                       contentHeight: Double = 200,
                       viewportHeight: Double = 50,
                       scrollOffset: Double = 0,
                       contentFrame: RPGLogicalRect = RPGLogicalRect(
                        x: 0, y: 0, width: 100, height: 50)) -> RPGScreenModel {
        let panel = RPGLogicalRect(x: 0, y: 0, width: 120, height: 80)
        let layout = RPGScreenLayout(
            panelFrame: panel,
            headerFrame: RPGLogicalRect(x: 0, y: 0, width: 100, height: 10),
            authorityChipFrame: RPGLogicalRect(x: 0, y: 10, width: 100, height: 10),
            statusChipFrame: nil, contextualDetailFrame: nil,
            stepOrTabFrame: RPGLogicalRect(x: 0, y: 20, width: 100, height: 10),
            contentFrame: contentFrame,
            commandFrame: RPGLogicalRect(x: 0, y: 50, width: 100, height: 15),
            footerHelpFrame: RPGLogicalRect(x: 0, y: 65, width: 100, height: 15))
        return RPGScreenModel(
            layout: layout, panelFrame: panel,
            contentFrame: contentFrame, headerText: "RPG", statusText: "Ready",
            footerText: "", authority: rpgAuthorityPhasePresentation(.localReady),
            status: nil,
            descriptors: descriptors,
            visibleDescriptors: descriptors.filter { $0.visibleFrame != nil },
            projection: nil, characterSummary: nil, progressionSummary: nil,
            creationReview: nil, contentHeight: contentHeight,
            viewportHeight: viewportHeight, scrollOffset: scrollOffset,
            focusedID: nil, nextFocusableID: nil, errorText: nil,
            contextualDetailLines: [], stepOrTabText: "Character")
    }

    private func context(_ descriptors: [RPGSemanticDescriptor],
                         instance: UInt64 = 7, revision: UInt64 = 11,
                         contentHeight: Double = 200,
                         viewportHeight: Double = 50) -> RPGScreenInteractionContext {
        RPGScreenInteractionContext(
            model: model(descriptors, contentHeight: contentHeight,
                         viewportHeight: viewportHeight),
            screenInstanceID: instance, semanticRevision: revision)!
    }

    private func capture(_ elementID: RPGUIElementID,
                         instance: UInt64 = 7, revision: UInt64 = 11,
                         receipt: UInt64 = 1) -> RPGSemanticActivationCapture {
        RPGSemanticActivationCapture(
            activationReceipt: receipt, screenInstanceID: instance,
            id: elementID, semanticRevision: revision,
            commandFingerprint: String(repeating: "a", count: 64),
            semanticInputFingerprint: String(repeating: "b", count: 64))!
    }

    private func apply(_ state: RPGScreenInteractionState,
                       _ command: RPGSemanticCommand,
                       context: RPGScreenInteractionContext,
                       tutorialPublished: Bool = false) -> RPGScreenInteractionTransition {
        rpgReduceScreenInteraction(
            state, event: .applyCommand(
                command, tutorialCompletionPublished: tutorialPublished),
            context: context)
    }

    func testCreationReducerTraversesAllFourStepsAndRetainsPerPathDrafts() throws {
        let empty = context([])
        var state = RPGScreenInteractionState()

        var transition = apply(state, .choosePath("arcanist"), context: empty)
        XCTAssertTrue(transition.handled)
        state = transition.state
        transition = apply(state, .creationNext, context: empty)
        XCTAssertEqual(transition.state.creation.step, .branch)
        state = transition.state

        transition = apply(state, .chooseBranch("arcanist_ritualist"), context: empty)
        state = transition.state
        transition = apply(state, .creationNext, context: empty)
        XCTAssertEqual(transition.state.creation.step, .attributes)
        state = transition.state

        transition = apply(state, .adjustAttribute(.luck, -1), context: empty)
        state = transition.state
        transition = apply(state, .adjustAttribute(.endurance, 1), context: empty)
        state = transition.state
        transition = apply(state, .creationNext, context: empty)
        XCTAssertEqual(transition.state.creation.step, .review)
        XCTAssertEqual(transition.state.creation.selectedDraft?.branchID,
                       "arcanist_ritualist")
        XCTAssertEqual(transition.state.creation.selectedDraft?.attributes.luck, 7)
        XCTAssertEqual(transition.state.creation.pathDrafts.count, 6)

        state = transition.state
        transition = apply(state, .creationNext, context: empty)
        XCTAssertEqual(transition.creationError, .cannotAdvance)
        XCTAssertEqual(transition.state, state)

        transition = apply(state, .creationBack, context: empty)
        XCTAssertEqual(transition.state.creation.step, .attributes)
        transition = apply(transition.state, .creationBack, context: empty)
        XCTAssertEqual(transition.state.creation.step, .branch)
        transition = apply(transition.state, .creationBack, context: empty)
        XCTAssertEqual(transition.state.creation.step, .path)
        transition = apply(transition.state, .creationBack, context: empty)
        XCTAssertEqual(transition.effects, [.close])
    }

    func testCreationFailuresAreExplicitAndLeaveStateByteEquivalent() {
        let empty = context([])
        let state = RPGScreenInteractionState()
        var transition = apply(state, .choosePath("unknown"), context: empty)
        XCTAssertEqual(transition.creationError, .unknownPath("unknown"))
        XCTAssertEqual(transition.state, state)

        transition = apply(state, .adjustAttribute(.strength, Int.max), context: empty)
        XCTAssertNotNil(transition.creationError)
        XCTAssertEqual(transition.state, state)
    }

    func testFiveTabsSelectAndCycleInCanonicalOrderWithWrap() {
        let empty = context([])
        var state = RPGScreenInteractionState(tab: .character, scrollOffset: 42)
        var visited: [RPGCharacterTab] = []
        for _ in RPGCharacterTab.allCases {
            visited.append(state.tab)
            state = apply(state, .nextTab, context: empty).state
        }
        XCTAssertEqual(visited, [.character, .skills, .actives, .spells, .progression])
        XCTAssertEqual(state.tab, .character)
        XCTAssertEqual(state.focusedID, .tab(.character))
        XCTAssertEqual(state.scrollOffset, 0)

        state = apply(state, .previousTab, context: empty).state
        XCTAssertEqual(state.tab, .progression)
        state = apply(state, .selectTab(.actives), context: empty).state
        XCTAssertEqual(state.tab, .actives)
        XCTAssertEqual(state.focusedID, .tab(.actives))
    }

    func testForwardReverseFocusIncludesLockedAndInformationalElementsAndWraps() {
        let a = descriptor("a", x: 0, y: 0, command: .back)
        let b = descriptor("b", x: 30, y: 0, enabled: false, locked: true)
        let c = descriptor("c", x: 60, y: 0)
        let ctx = context([a, b, c], contentHeight: 50, viewportHeight: 50)
        var state = RPGScreenInteractionState()

        var transition = rpgReduceScreenInteraction(state, event: .focusNext, context: ctx)
        XCTAssertEqual(transition.state.focusedID, a.id)
        state = transition.state
        transition = rpgReduceScreenInteraction(state, event: .focusNext, context: ctx)
        XCTAssertEqual(transition.state.focusedID, b.id)
        state = transition.state
        transition = rpgReduceScreenInteraction(state, event: .focusNext, context: ctx)
        XCTAssertEqual(transition.state.focusedID, c.id)
        state = transition.state
        transition = rpgReduceScreenInteraction(state, event: .focusNext, context: ctx)
        XCTAssertEqual(transition.state.focusedID, a.id)

        transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(), event: .focusPrevious, context: ctx)
        XCTAssertEqual(transition.state.focusedID, c.id)
    }

    func testSpatialFocusUsesGeometryStableTieBreakAndRevealsMinimumDelta() {
        let selected = RPGScreenSelection(selectedSemanticID: id("down"),
                                          inspectorItemID: id("inspect"))
        let origin = descriptor("origin", x: 40, y: 0)
        let down = descriptor("down", x: 40, y: 150, selection: selected)
        let diagonal = descriptor("diagonal", x: 70, y: 150)
        let ctx = context([origin, down, diagonal])
        let state = RPGScreenInteractionState(
            focusedID: origin.id, focusOrder: [origin.id, down.id, diagonal.id])

        let transition = rpgReduceScreenInteraction(
            state, event: .moveFocus(.down), context: ctx)
        XCTAssertEqual(transition.state.focusedID, down.id)
        XCTAssertEqual(transition.state.selection, selected)
        XCTAssertEqual(transition.state.scrollOffset, 120)

        let noCandidate = rpgReduceScreenInteraction(
            transition.state, event: .moveFocus(.down), context: ctx)
        XCTAssertEqual(noCandidate.state.focusedID, down.id)
    }

    func testMissingFocusFallsBackToNearestPrecedingFocusableElement() {
        let a = descriptor("a", x: 0, y: 0)
        let b = descriptor("b", x: 20, y: 0)
        let c = descriptor("c", x: 40, y: 0)
        let state = RPGScreenInteractionState(
            focusedID: c.id, focusOrder: [a.id, b.id, c.id])
        let transition = rpgReduceScreenInteraction(
            state, event: .activateFocused, context: context([a, b]))
        XCTAssertEqual(transition.state.focusedID, b.id)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testWheelUsesOneStrideAndClampsAtBothBoundsAndExtremeRows() {
        let value = descriptor("row", x: 0, y: 0)
        let ctx = context([value], contentHeight: 200, viewportHeight: 50)
        var state = RPGScreenInteractionState()
        var transition = rpgReduceScreenInteraction(
            state, event: .scrollRows(1), context: ctx)
        XCTAssertEqual(transition.state.scrollOffset, RPG_SCREEN_SCROLL_STRIDE)
        state = transition.state
        transition = rpgReduceScreenInteraction(
            state, event: .scrollRows(Int.max), context: ctx)
        XCTAssertEqual(transition.state.scrollOffset, 150)
        transition = rpgReduceScreenInteraction(
            transition.state, event: .scrollRows(Int.min), context: ctx)
        XCTAssertEqual(transition.state.scrollOffset, 0)

        let short = context([value], contentHeight: 40, viewportHeight: 50)
        transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(scrollOffset: 40),
            event: .scrollRows(1), context: short)
        XCTAssertFalse(transition.handled)
        XCTAssertEqual(transition.state.scrollOffset, 0)
    }

    func testFocusingFixedDescriptorNeverChangesScrollOffset() throws {
        let fixed = descriptor("close", x: 0, y: 60, command: .back,
                               layoutRegion: .fixed)
        let scrolling = descriptor("row", x: 0, y: 100)
        let ctx = try XCTUnwrap(RPGScreenInteractionContext(
            model: model([scrolling, fixed], contentHeight: 300,
                         viewportHeight: 50),
            screenInstanceID: 7, semanticRevision: 11))
        let initial = RPGScreenInteractionState(focusedID: scrolling.id,
                                                scrollOffset: 40)
        let focused = rpgReduceScreenInteraction(
            initial, event: .focusElement(fixed.id), context: ctx)
        XCTAssertTrue(focused.handled)
        XCTAssertEqual(focused.state.focusedID, fixed.id)
        XCTAssertEqual(focused.state.scrollOffset, 40)
        XCTAssertNil(focused.state.focusedScreenFrame)
    }

    func testReducerRebuildAnchorsAbsoluteFocusedFrameAcrossContextExpansionAndCollapse() throws {
        let oldContent = RPGLogicalRect(x: 0, y: 30, width: 100, height: 50)
        let oldDescriptor = descriptor("anchored", x: 0, y: 50)
        let oldContext = try XCTUnwrap(RPGScreenInteractionContext(
            model: model([oldDescriptor], contentHeight: 300,
                         viewportHeight: 50, scrollOffset: 40,
                         contentFrame: oldContent),
            screenInstanceID: 7, semanticRevision: 11))
        let focused = rpgReduceScreenInteraction(
            RPGScreenInteractionState(scrollOffset: 40),
            event: .focusElement(oldDescriptor.id), context: oldContext)
        XCTAssertEqual(focused.state.scrollOffset, 40)
        XCTAssertEqual(focused.state.focusedScreenFrame, oldDescriptor.frame)

        let expandedContent = RPGLogicalRect(x: 0, y: 50, width: 100, height: 50)
        // The rebuilt descriptor moved down with the expanded fixed context. Its unscrolled
        // absolute origin is 110 (70 on screen in the model built at offset 40).
        let expandedDescriptor = descriptor("anchored", x: 0, y: 70)
        let expandedContext = try XCTUnwrap(RPGScreenInteractionContext(
            model: model([expandedDescriptor], contentHeight: 300,
                         viewportHeight: 50, scrollOffset: 40,
                         contentFrame: expandedContent),
            screenInstanceID: 7, semanticRevision: 12))
        let expanded = rpgReduceScreenInteraction(
            focused.state, event: .activateFocused, context: expandedContext)
        XCTAssertEqual(expanded.state.scrollOffset, 60)
        XCTAssertEqual(expanded.state.focusedScreenFrame, oldDescriptor.frame)

        // Collapse rebuilds at offset 60; the same unscrolled content origin is 90, so its
        // published frame is 30 until the reducer restores the old absolute screen origin.
        let collapsedDescriptor = descriptor("anchored", x: 0, y: 30)
        let collapsedContext = try XCTUnwrap(RPGScreenInteractionContext(
            model: model([collapsedDescriptor], contentHeight: 300,
                         viewportHeight: 50, scrollOffset: 60,
                         contentFrame: oldContent),
            screenInstanceID: 7, semanticRevision: 13))
        let collapsed = rpgReduceScreenInteraction(
            expanded.state, event: .activateFocused, context: collapsedContext)
        XCTAssertEqual(collapsed.state.scrollOffset, 40)
        XCTAssertEqual(collapsed.state.focusedScreenFrame, oldDescriptor.frame)
    }

    func testProductionRebuildReconcilesBeforeCommitAndFocusedScrollNeverSnapsBack() throws {
        let oldContent = RPGLogicalRect(x: 0, y: 30, width: 100, height: 50)
        let expandedContent = RPGLogicalRect(x: 0, y: 50, width: 100, height: 50)
        let focusedID = id("production-anchor")
        let oldScreenFrame = RPGLogicalRect(x: 0, y: 50, width: 20, height: 20)
        var interaction = RPGScreenInteractionState(
            focusedID: focusedID, scrollOffset: 40,
            focusedScreenFrame: oldScreenFrame,
            focusOrder: [focusedID])

        let expandedDescriptor = descriptor("production-anchor", x: 0, y: 70)
        let expandedProvisional = model(
            [expandedDescriptor], contentHeight: 300, viewportHeight: 50,
            scrollOffset: 40, contentFrame: expandedContent)
        XCTAssertTrue(rpgReconcileProvisionalScreenModel(
            &interaction, provisionalModel: expandedProvisional))
        XCTAssertEqual(interaction.scrollOffset, 60)
        XCTAssertEqual(interaction.focusedScreenFrame, oldScreenFrame)
        let expandedCommitted = descriptor("production-anchor", x: 0, y: 50)
        XCTAssertEqual(expandedCommitted.frame, interaction.focusedScreenFrame)

        let collapsedDescriptor = descriptor("production-anchor", x: 0, y: 30)
        let collapsedProvisional = model(
            [collapsedDescriptor], contentHeight: 300, viewportHeight: 50,
            scrollOffset: 60, contentFrame: oldContent)
        XCTAssertTrue(rpgReconcileProvisionalScreenModel(
            &interaction, provisionalModel: collapsedProvisional))
        XCTAssertEqual(interaction.scrollOffset, 40)
        XCTAssertEqual(interaction.focusedScreenFrame, oldScreenFrame)

        let initialDescriptor = descriptor("production-anchor", x: 0, y: 50)
        let initialContext = try XCTUnwrap(RPGScreenInteractionContext(
            model: model([initialDescriptor], contentHeight: 300,
                         viewportHeight: 50, scrollOffset: 40,
                         contentFrame: oldContent),
            screenInstanceID: 7, semanticRevision: 20))
        let firstScroll = rpgReduceScreenInteraction(
            RPGScreenInteractionState(
                focusedID: focusedID, scrollOffset: 40,
                focusedScreenFrame: oldScreenFrame, focusOrder: [focusedID]),
            event: .scrollRows(1), context: initialContext)
        XCTAssertEqual(firstScroll.state.scrollOffset, 68)
        XCTAssertNil(firstScroll.state.focusedScreenFrame)

        let afterFirstDescriptor = descriptor("production-anchor", x: 0, y: 22)
        let afterFirstModel = model(
            [afterFirstDescriptor], contentHeight: 300, viewportHeight: 50,
            scrollOffset: 68, contentFrame: oldContent)
        var afterFirstState = firstScroll.state
        XCTAssertFalse(rpgReconcileProvisionalScreenModel(
            &afterFirstState, provisionalModel: afterFirstModel))
        XCTAssertEqual(afterFirstState.scrollOffset, 68)
        XCTAssertNil(afterFirstState.focusedScreenFrame)
        let afterFirstContext = try XCTUnwrap(RPGScreenInteractionContext(
            model: afterFirstModel, screenInstanceID: 7, semanticRevision: 21))
        let secondScroll = rpgReduceScreenInteraction(
            afterFirstState, event: .scrollRows(1), context: afterFirstContext)
        XCTAssertEqual(secondScroll.state.scrollOffset, 96)
        XCTAssertNil(secondScroll.state.focusedScreenFrame)
    }

    func testSharedRevealIsCheckedNearestEdgeAndInvalidFocusFailsWithoutMutation() throws {
        let offscreen = descriptor("reveal", x: 0, y: 150)
        let revealModel = model([offscreen], contentHeight: 240, viewportHeight: 50)
        let offset = try XCTUnwrap(rpgRevealScrollOffset(
            descriptor: offscreen, in: revealModel, currentOffset: 0))
        XCTAssertEqual(offset, 120)
        let unscrolledY = offscreen.frame.y + revealModel.scrollOffset
        let final = RPGLogicalRect(
            x: offscreen.frame.x, y: unscrolledY - offset,
            width: offscreen.frame.width, height: offscreen.frame.height)
        XCTAssertTrue(revealModel.contentFrame.contains(final))

        let fixed = descriptor("fixed-reveal", x: 0, y: 60,
                               layoutRegion: .fixed)
        XCTAssertEqual(rpgRevealScrollOffset(
            descriptor: fixed,
            in: model([fixed], contentHeight: 240, viewportHeight: 50),
            currentOffset: 28), 28)

        let invalidFixed = descriptor("invalid-fixed", x: 0, y: 100,
                                      layoutRegion: .fixed)
        let invalidFixedModel = model(
            [invalidFixed], contentHeight: 240, viewportHeight: 50)
        XCTAssertNil(rpgRevealScrollOffset(
            descriptor: invalidFixed, in: invalidFixedModel, currentOffset: 28))
        let fixedOriginal = RPGScreenInteractionState()
        let fixedTransition = rpgReduceScreenInteraction(
            fixedOriginal, event: .focusElement(invalidFixed.id),
            context: try XCTUnwrap(RPGScreenInteractionContext(
                model: invalidFixedModel, screenInstanceID: 8,
                semanticRevision: 2)))
        XCTAssertFalse(fixedTransition.handled)
        XCTAssertEqual(fixedTransition.state.focusedID, fixedOriginal.focusedID)
        XCTAssertEqual(fixedTransition.state.scrollOffset,
                       fixedOriginal.scrollOffset)

        let tooTall = descriptor("too-tall", x: 0, y: 0, height: 51)
        let invalidModel = model([tooTall], contentHeight: 240, viewportHeight: 50)
        XCTAssertNil(rpgRevealScrollOffset(
            descriptor: tooTall, in: invalidModel, currentOffset: 0))
        let original = RPGScreenInteractionState()
        let transition = rpgReduceScreenInteraction(
            original, event: .focusElement(tooTall.id),
            context: try XCTUnwrap(RPGScreenInteractionContext(
                model: invalidModel, screenInstanceID: 8, semanticRevision: 1)))
        XCTAssertFalse(transition.handled)
        XCTAssertEqual(transition.state.focusedID, original.focusedID)
        XCTAssertNil(rpgRevealScrollOffset(
            descriptor: offscreen, in: revealModel, currentOffset: .nan))
    }

    func testActivationSelectsFocusedDescriptorButOnlyRequestsExplicitAction() {
        let selection = RPGScreenSelection(selectedSemanticID: id("info"),
                                           inspectorItemID: id("inspector"))
        let info = descriptor("info", x: 0, y: 0, selection: selection)
        let action = descriptor("action", x: 30, y: 0, command: .back)
        let ctx = context([info, action], contentHeight: 50, viewportHeight: 50)

        var transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(focusedID: info.id,
                                      focusOrder: [info.id, action.id]),
            event: .activateFocused, context: ctx)
        XCTAssertTrue(transition.handled)
        XCTAssertEqual(transition.state.selection, selection)
        XCTAssertTrue(transition.effects.isEmpty)

        transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(focusedID: action.id,
                                      focusOrder: [info.id, action.id]),
            event: .activateFocused, context: ctx)
        XCTAssertEqual(transition.effects, [.activate(action.id)])
    }

    func testTutorialFinishRequiresLastPageAndConfirmedPersistence() {
        let empty = context([])
        var state = RPGScreenInteractionState(
            tutorial: RPGTutorialState(seenVersion: 0, page: 1))
        var transition = apply(
            state, .tutorialFinish, context: empty, tutorialPublished: true)
        XCTAssertFalse(transition.handled)
        XCTAssertEqual(transition.state, state)

        state.tutorial.page = 4
        transition = apply(
            state, .tutorialFinish, context: empty, tutorialPublished: false)
        XCTAssertFalse(transition.handled)
        XCTAssertEqual(transition.state, state)

        transition = apply(
            state, .tutorialFinish, context: empty, tutorialPublished: true)
        XCTAssertTrue(transition.handled)
        XCTAssertEqual(transition.state.tutorial.seenVersion, RPG_TUTORIAL_VERSION)
        XCTAssertNil(transition.state.tutorial.page)
        XCTAssertEqual(transition.effects, [.close])
    }

    func testTutorialNavigationAndSkipAreBoundedAndPersistBeforePublish() {
        let empty = context([])
        var state = RPGScreenInteractionState(
            tutorial: RPGTutorialState(seenVersion: 0, page: 1))
        var transition = apply(state, .tutorialBack, context: empty)
        XCTAssertEqual(transition.state.tutorial.page, 1)
        transition = apply(transition.state, .tutorialNext, context: empty)
        XCTAssertEqual(transition.state.tutorial.page, 2)

        state.tutorial.page = 4
        transition = apply(state, .tutorialNext, context: empty)
        XCTAssertFalse(transition.handled)
        XCTAssertEqual(transition.state.tutorial.page, 4)

        transition = apply(state, .tutorialSkip, context: empty, tutorialPublished: false)
        XCTAssertFalse(transition.handled)
        XCTAssertEqual(transition.state, state)
        transition = apply(state, .tutorialSkip, context: empty, tutorialPublished: true)
        XCTAssertEqual(transition.state.tutorial.seenVersion, RPG_TUTORIAL_VERSION)
        XCTAssertEqual(transition.effects, [.close])
    }

    func testMatchingMouseDownUpTransfersExactCaptureOnce() {
        let action = descriptor("action", x: 0, y: 0, command: .back)
        let ctx = context([action])
        let issued = capture(action.id)
        var transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: action.id, capture: issued), context: ctx)
        XCTAssertEqual(transition.state.pendingMouseActivation?.capture, issued)
        XCTAssertEqual(transition.state.focusedID, action.id)
        XCTAssertTrue(transition.effects.isEmpty)

        transition = rpgReduceScreenInteraction(
            transition.state, event: .mouseUp(elementID: action.id), context: ctx)
        XCTAssertNil(transition.state.pendingMouseActivation)
        XCTAssertEqual(transition.effects, [.dispatchMouse(issued)])

        let replay = rpgReduceScreenInteraction(
            transition.state, event: .mouseUp(elementID: action.id), context: ctx)
        XCTAssertFalse(replay.handled)
        XCTAssertTrue(replay.effects.isEmpty)
    }

    func testMouseReleaseMismatchCancelCoverAndExplicitCancelRelinquishOwnership() {
        let first = descriptor("first", x: 0, y: 0, command: .back)
        let second = descriptor("second", x: 30, y: 0, command: .nextTab)
        let ctx = context([first, second])
        let firstCapture = capture(first.id, receipt: 1)
        let secondCapture = capture(second.id, receipt: 2)

        var state = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: first.id, capture: firstCapture),
            context: ctx).state
        var transition = rpgReduceScreenInteraction(
            state, event: .mouseUp(elementID: second.id), context: ctx)
        XCTAssertEqual(transition.effects, [.cancelMouse(firstCapture)])
        XCTAssertNil(transition.state.pendingMouseActivation)

        state = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: first.id, capture: firstCapture),
            context: ctx).state
        transition = rpgReduceScreenInteraction(
            state, event: .mouseDown(elementID: second.id, capture: secondCapture),
            context: ctx)
        XCTAssertEqual(transition.effects, [.cancelMouse(firstCapture)])
        XCTAssertEqual(transition.state.pendingMouseActivation?.capture, secondCapture)

        transition = rpgReduceScreenInteraction(
            transition.state, event: .inputOwnershipLost, context: ctx)
        XCTAssertEqual(transition.effects, [.cancelMouse(secondCapture)])
        XCTAssertNil(transition.state.pendingMouseActivation)

        state = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: first.id, capture: firstCapture),
            context: ctx).state
        transition = rpgReduceScreenInteraction(state, event: .cancelMouse, context: ctx)
        XCTAssertEqual(transition.effects, [.cancelMouse(firstCapture)])
        XCTAssertNil(transition.state.pendingMouseActivation)
    }

    func testSemanticRevisionReplacementCancelsOldMouseOwnerBeforeOtherInput() {
        let action = descriptor("action", x: 0, y: 0, command: .back)
        let old = context([action], revision: 11)
        let issued = capture(action.id, revision: 11)
        let held = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: action.id, capture: issued), context: old).state

        let replacement = context([action], revision: 12)
        let transition = rpgReduceScreenInteraction(
            held, event: .focusNext, context: replacement)
        XCTAssertEqual(transition.effects, [.cancelMouse(issued)])
        XCTAssertNil(transition.state.pendingMouseActivation)
    }

    func testInvalidOrNonactionableMouseCaptureIsCancelledAndNeverOwned() {
        let selection = RPGScreenSelection(selectedSemanticID: id("info"))
        let info = descriptor("info", x: 0, y: 0, selection: selection)
        let action = descriptor("action", x: 30, y: 0, command: .back)
        let ctx = context([info, action])
        let infoCapture = capture(info.id)
        var transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: info.id, capture: infoCapture), context: ctx)
        XCTAssertEqual(transition.effects, [.cancelMouse(infoCapture)])
        XCTAssertNil(transition.state.pendingMouseActivation)
        XCTAssertEqual(transition.state.selection, selection)

        let wrongOwner = capture(action.id, instance: 8)
        transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(),
            event: .mouseDown(elementID: action.id, capture: wrongOwner), context: ctx)
        XCTAssertEqual(transition.effects, [.cancelMouse(wrongOwner)])
        XCTAssertNil(transition.state.pendingMouseActivation)
    }

    func testHitTestingUsesReverseDrawOrderAndRejectsEdgesAndNonfiniteCoordinates() {
        let low = descriptor("low", x: 0, y: 0, width: 20, height: 20)
        let high = descriptor("high", x: 0, y: 0, width: 20, height: 20)
        let value = model([low, high])
        XCTAssertEqual(rpgScreenDescriptor(atX: 10, y: 10, in: value)?.id, high.id)
        XCTAssertNil(rpgScreenDescriptor(atX: 20, y: 10, in: value))
        XCTAssertNil(rpgScreenDescriptor(atX: .nan, y: 10, in: value))
        XCTAssertNil(rpgScreenDescriptor(atX: 10, y: .infinity, in: value))
    }

    func testInvalidInteractionContextIdentifiersFailClosed() {
        let value = model([])
        XCTAssertNil(RPGScreenInteractionContext(
            model: value, screenInstanceID: 0, semanticRevision: 1))
        XCTAssertNil(RPGScreenInteractionContext(
            model: value, screenInstanceID: 1, semanticRevision: 0))
    }
}
