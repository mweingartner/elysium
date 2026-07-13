import XCTest
@testable import ElysiumCore

@MainActor
final class RPGSemanticAccessibilityTests: XCTestCase {
    private struct Fixture {
        let game: GameCore
        let runtime: RPGScreenRuntimeSnapshot
        let model: RPGScreenModel
        let committed: RPGCommittedSemanticSnapshot
        let tree: RPGAccessibilityTreeSnapshot
    }

    @MainActor
    private func fixture(tab: RPGCharacterTab = .skills,
                         focusedID: RPGUIElementID? = nil,
                         scrollOffset: Double = 0,
                         highContrast: Bool = false,
                         reduceMotion: Bool = false,
                         screenInstanceID: UInt64 = 1,
                         semanticRevision: UInt64 = 1,
                         layoutGeneration: UInt64? = nil) throws -> Fixture {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "accessibility")
        game.createWorld(name: "Accessibility", seedText: "8080",
                         mode: GameMode.survival, difficulty: 2)
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        game.player.rpg = state
        let base = try XCTUnwrap(game.rpgScreenRuntimeSnapshot())
        let runtime = RPGScreenRuntimeSnapshot(
            state: base.state, quickSlots: base.quickSlots,
            localPreferenceScope: base.localPreferenceScope,
            localPreferenceRevision: base.localPreferenceRevision,
            localPreferenceWritable: base.localPreferenceWritable,
            worldEntryGeneration: base.worldEntryGeneration,
            localPreferenceStatus: base.localPreferenceStatus,
            authority: base.authority, rulesGeneration: base.rulesGeneration,
            inventoryRevision: base.inventoryRevision,
            equipmentFocusRevision: base.equipmentFocusRevision,
            inventoryDigest: base.inventoryDigest,
            equipmentFocusDigest: base.equipmentFocusDigest,
            settingsRevision: base.settingsRevision,
            equipmentSummary: base.equipmentSummary, focusSummary: base.focusSummary,
            configuredChords: base.configuredChords,
            inventoryCapacitySummary: base.inventoryCapacitySummary,
            inventoryCapacityByPath: base.inventoryCapacityByPath,
            tutorial: RPGTutorialState(seenVersion: RPG_TUTORIAL_VERSION, page: nil),
            highContrast: highContrast,
            reduceMotion: reduceMotion)
        let model = rpgBuildScreenModel(runtime.modelInput(
            viewportWidth: 360, viewportHeight: 224, tab: tab,
            focusedID: focusedID, scrollOffset: scrollOffset))
        let committed = try XCTUnwrap(RPGCommittedSemanticSnapshot(
            screenInstanceID: screenInstanceID, semanticRevision: semanticRevision,
            model: model, runtime: runtime))
        let viewport = try XCTUnwrap(RPGAccessibilityViewport(width: 360, height: 224))
        let tree = try XCTUnwrap(RPGAccessibilityTreeSnapshot(
            committed: committed, layoutGeneration: layoutGeneration ?? semanticRevision,
            viewport: viewport))
        return Fixture(game: game, runtime: runtime, model: model,
                       committed: committed, tree: tree)
    }

    @MainActor
    func testTreePublishesRolesLabelsValuesHelpStateAndOnlyActionablePresses() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.tree.elements.contains { $0.descriptor.role == .tab })
        XCTAssertTrue(fixture.tree.elements.contains { $0.descriptor.role == .rankCell })
        XCTAssertTrue(fixture.tree.elements.contains { $0.descriptor.role == .scrollArea })
        for element in fixture.tree.elements {
            XCTAssertFalse(element.descriptor.label.isEmpty)
            XCTAssertEqual(element.hasPressAction, element.descriptor.isActionable)
            XCTAssertEqual(element.activationOrigin != nil, element.descriptor.isActionable)
            if element.descriptor.role == .rankCell {
                XCTAssertTrue(element.accessibilityValue.contains("Rank"))
                XCTAssertTrue(element.accessibilityValue.contains(
                    element.descriptor.locked ? "Locked" : "Enabled"))
            }
            if element.descriptor.selected {
                XCTAssertTrue(element.accessibilityValue.contains("Selected"))
            }
            if element.descriptor.prepared {
                XCTAssertTrue(element.accessibilityValue.contains("Prepared"))
            }
            if element.descriptor.slotted {
                XCTAssertTrue(element.accessibilityValue.contains("Slotted"))
            }
        }
        let actionable = try XCTUnwrap(fixture.tree.elements.first { $0.hasPressAction })
        let origin = try XCTUnwrap(actionable.activationOrigin)
        XCTAssertEqual(origin.screenInstanceID, fixture.committed.screenInstanceID)
        XCTAssertEqual(origin.semanticRevision, fixture.committed.semanticRevision)
        XCTAssertEqual(origin.id, actionable.descriptor.id)
        XCTAssertEqual(origin.commandFingerprint,
                       rpgSemanticCommandFingerprint(try XCTUnwrap(actionable.descriptor.actionCommand)))
        XCTAssertEqual(origin.semanticInputFingerprint,
                       rpgSemanticInputFingerprint(try XCTUnwrap(
                        fixture.committed.semanticInputs[actionable.descriptor.id])))
        XCTAssertEqual(actionable.layoutGeneration, fixture.tree.layoutGeneration)
        XCTAssertEqual(actionable.viewport, fixture.tree.viewport)
    }

    func testEverySemanticRoleAndSelectedPreparedSlottedLockedValueAreProjected() throws {
        let viewport = try XCTUnwrap(RPGAccessibilityViewport(width: 400, height: 300))
        for role in RPGSemanticRole.allCasesForAccessibilityTesting {
            let descriptor = RPGSemanticDescriptor(
                id: RPGUIElementID(rawValue: "accessibility-role:\(role.rawValue)")!,
                role: role, label: role.rawValue, value: "Rank state",
                help: "Canonical reason", selected: true, prepared: true,
                slotted: true, enabled: true, locked: true, isFocusable: true,
                frame: RPGLogicalRect(x: 1, y: 2, width: 30, height: 20))
            let element = try XCTUnwrap(RPGAccessibilityElementSnapshot(
                descriptor: descriptor, activationOrigin: nil,
                layoutGeneration: 7, viewport: viewport))
            XCTAssertEqual(element.descriptor.role, role)
            XCTAssertEqual(element.accessibilityHelp, "Canonical reason")
            for state in ["Selected", "Prepared", "Slotted", "Locked"] {
                XCTAssertTrue(element.accessibilityValue.contains(state), "\(role) lacks \(state)")
            }
            XCTAssertFalse(element.hasPressAction)
        }
    }

    func testAuthorityAndStatusValuesAreExactAndAnnouncementIsOneShot() throws {
        let viewport = try XCTUnwrap(RPGAccessibilityViewport(width: 400, height: 300))
        func element(id: String, value: String, help: String) throws
            -> RPGAccessibilityElementSnapshot {
            let descriptor = RPGSemanticDescriptor(
                id: RPGUIElementID(rawValue: id)!, role: .group,
                label: id, value: value, help: help, enabled: true,
                isFocusable: false,
                frame: RPGLogicalRect(x: 1, y: 2, width: 30, height: 20))
            return try XCTUnwrap(RPGAccessibilityElementSnapshot(
                descriptor: descriptor, activationOrigin: nil,
                layoutGeneration: 1, viewport: viewport))
        }
        let ready = try element(id: "authority:phase", value: "Ready",
                                help: "Controls are ready.")
        let status = try element(id: "status:current", value: "Cooldown: 2 seconds",
                                 help: "Wait before retrying.")
        XCTAssertEqual(ready.accessibilityValue, "Ready")
        XCTAssertEqual(status.accessibilityValue, "Cooldown: 2 seconds")
        XCTAssertFalse(ready.accessibilityValue.contains("Enabled"))
        let first = try XCTUnwrap(RPGAccessibilityTreeSnapshot(
            screenInstanceID: 1, semanticRevision: 1, layoutGeneration: 1,
            viewport: viewport, elements: [ready, status], focusedID: nil,
            highContrast: false, reduceMotion: false))
        XCTAssertEqual(rpgAccessibilityAuthorityAnnouncement(previous: nil, current: first),
                       "Ready. Controls are ready.")
        XCTAssertNil(rpgAccessibilityAuthorityAnnouncement(previous: first, current: first))
        let pendingElement = try element(id: "authority:phase", value: "Awaiting host",
                                         help: "Character changes are disabled.")
        let pending = try XCTUnwrap(RPGAccessibilityTreeSnapshot(
            screenInstanceID: 1, semanticRevision: 2, layoutGeneration: 1,
            viewport: viewport, elements: [pendingElement, status], focusedID: nil,
            highContrast: false, reduceMotion: false))
        XCTAssertEqual(rpgAccessibilityAuthorityAnnouncement(previous: first, current: pending),
                       "Awaiting host. Character changes are disabled.")
    }

    @MainActor
    func testSkillsTreeHasRootAndExactlyCurrentPathTwentySevenRanksIncludingOffscreen() throws {
        let fixture = try fixture()
        let ranks = fixture.tree.elements.filter { $0.descriptor.role == .rankCell }
        XCTAssertEqual(ranks.count, 27)
        XCTAssertTrue(ranks.contains { $0.descriptor.visibleFrame == nil })
        XCTAssertEqual(Set(ranks.map(\.descriptor.id)),
                       Set(try XCTUnwrap(fixture.model.projection).ranks.map(\.id)))
        let allOtherPathRanks: Set<RPGUIElementID> = Set(
            RPG_PATH_DEFINITIONS.filter { $0.id != "warden" }.flatMap { path -> [RPGUIElementID] in
            guard let branch = path.branchIDs.first,
                  let state = rpgScreenFixture(pathID: path.id, branchID: branch),
                  let projection = rpgPathProjection(pathID: path.id, state: state) else { return [] }
            return projection.ranks.map(\.id)
        })
        XCTAssertEqual(allOtherPathRanks.count, 135)
        XCTAssertTrue(Set(ranks.map(\.descriptor.id)).isDisjoint(with: allOtherPathRanks))
        let root = try XCTUnwrap(fixture.tree.elements.first {
            $0.descriptor.id.rawValue == "accessibility:skills-root"
        })
        XCTAssertEqual(root.descriptor.role, .scrollArea)
        XCTAssertEqual(root.descriptor.value, "3 branches, 9 skills, 27 ranks")
        XCTAssertFalse(root.hasPressAction)
        XCTAssertNotNil(fixture.tree.elements.first {
            $0.descriptor.id.rawValue == "accessibility:tab-group"
        })
    }

    @MainActor
    func testCachedOriginRejectsReplacementRevisionCommandAndInputFingerprintThenFreshSucceeds() throws {
        let fixture = try fixture()
        let cached = try XCTUnwrap(fixture.tree.elements.first { $0.hasPressAction })
        let origin = try XCTUnwrap(cached.activationOrigin)
        let descriptor = cached.descriptor
        let input = try XCTUnwrap(fixture.committed.semanticInputs[descriptor.id])

        for mismatch in ["screen", "revision", "command", "input", "removed"] {
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(boundary.capture(origin: origin))
            let currentScreen = mismatch == "screen" ? 2 : origin.screenInstanceID
            let currentRevision = mismatch == "revision" ? origin.semanticRevision + 1 : origin.semanticRevision
            let currentDescriptor: RPGSemanticDescriptor?
            let currentInput: RPGSemanticInputSnapshot
            if mismatch == "command" {
                currentDescriptor = RPGSemanticDescriptor(
                    id: descriptor.id, role: descriptor.role, label: descriptor.label,
                    enabled: true, isFocusable: true, frame: descriptor.frame,
                    visibleFrame: descriptor.visibleFrame, actionCommand: .selectTab(.spells))
                currentInput = try XCTUnwrap(fixture.runtime.semanticInput(for: .selectTab(.spells)))
            } else {
                currentDescriptor = mismatch == "removed" ? nil : descriptor
                if mismatch == "input" {
                    currentInput = try XCTUnwrap(RPGSemanticInputSnapshot(
                        localPreferenceScope: input.localPreferenceScope,
                        localPreferenceRevision: input.localPreferenceRevision,
                        localPreferenceWritable: input.localPreferenceWritable,
                        worldEntryGeneration: input.worldEntryGeneration,
                        rulesGeneration: input.rulesGeneration + 1,
                        ownerRevision: input.ownerRevision,
                        inventoryDigest: input.inventoryDigest,
                        equipmentFocusDigest: input.equipmentFocusDigest,
                        authorityRevision: input.authorityRevision,
                        authorityPhase: input.authorityPhase,
                        authorityRequestIdentity: input.authorityRequestIdentity,
                        operationExpectedState: input.operationExpectedState))
                } else {
                    currentInput = input
                }
            }
            XCTAssertEqual(boundary.dispatch(
                capture, source: .accessibility,
                screenInstanceID: currentScreen, semanticRevision: currentRevision,
                descriptor: currentDescriptor, input: currentInput),
                .staleRequiresFreshActivation, mismatch)
            XCTAssertEqual(boundary.highestConsumedActivationReceipt, capture.activationReceipt)
            XCTAssertEqual(boundary.dispatch(
                capture, source: .accessibility,
                screenInstanceID: origin.screenInstanceID,
                semanticRevision: origin.semanticRevision,
                descriptor: descriptor, input: input), .invalidOrReplayedReceipt)
        }

        let freshBoundary = RPGSemanticActivationBoundary()
        let fresh = try XCTUnwrap(freshBoundary.capture(origin: origin))
        XCTAssertEqual(freshBoundary.dispatch(
            fresh, source: .accessibility,
            screenInstanceID: origin.screenInstanceID,
            semanticRevision: origin.semanticRevision,
            descriptor: descriptor, input: input), .dispatched(serial: 1))
    }

    @MainActor
    func testRetainedOldElementPressReceiptIsConsumedAfterCacheReplacement() throws {
        let fixture = try fixture()
        let origin = try XCTUnwrap(fixture.tree.elements.first { $0.hasPressAction }?.activationOrigin)
        let boundary = RPGSemanticActivationBoundary()
        let stalePress = try XCTUnwrap(boundary.capture(origin: origin))
        XCTAssertTrue(boundary.cancel(stalePress),
                      "UIManager current-screen rejection consumes the old origin receipt")
        XCTAssertEqual(boundary.highestConsumedActivationReceipt, stalePress.activationReceipt)
        XCTAssertFalse(boundary.cancel(stalePress))
        let laterPress = try XCTUnwrap(boundary.capture(origin: origin))
        XCTAssertGreaterThan(laterPress.activationReceipt, stalePress.activationReceipt)
    }

    @MainActor
    func testNilOriginScreenRouteStillConsumesFreshCachedReceipt() throws {
        let fixture = try fixture()
        let origin = try XCTUnwrap(fixture.tree.elements.first { $0.hasPressAction }?.activationOrigin)
        let boundary = RPGSemanticActivationBoundary()
        let pressIssuedBeforeWeakScreenLookup = try XCTUnwrap(boundary.capture(origin: origin))
        XCTAssertTrue(boundary.cancel(pressIssuedBeforeWeakScreenLookup))
        XCTAssertEqual(boundary.highestConsumedActivationReceipt,
                       pressIssuedBeforeWeakScreenLookup.activationReceipt)
        XCTAssertEqual(boundary.recentConsumedActivationReceipts,
                       [pressIssuedBeforeWeakScreenLookup.activationReceipt])
    }

    func testFrameProjectionRejectsOverflowHugeScaleAndInvalidFinalBounds() throws {
        let valid = try XCTUnwrap(rpgAccessibilityViewFrame(
            logical: RPGLogicalRect(x: 10, y: 20, width: 30, height: 40),
            uiScale: 3, backingScale: 2, viewWidth: 800, viewHeight: 600))
        XCTAssertEqual(valid, RPGLogicalRect(x: 15, y: 510, width: 45, height: 60))
        for value in [Double.nan, .infinity, Double.greatestFiniteMagnitude] {
            XCTAssertNil(rpgAccessibilityViewFrame(
                logical: RPGLogicalRect(x: value, y: 1, width: 20, height: 20),
                uiScale: 3, backingScale: 2, viewWidth: 800, viewHeight: 600))
            XCTAssertNil(rpgAccessibilityViewFrame(
                logical: RPGLogicalRect(x: 1, y: 1, width: 20, height: 20),
                uiScale: value, backingScale: 2, viewWidth: 800, viewHeight: 600))
        }
        XCTAssertNil(rpgAccessibilityViewFrame(
            logical: RPGLogicalRect(x: 1, y: 1, width: 20, height: 20),
            uiScale: 3, backingScale: 0, viewWidth: 800, viewHeight: 600))
        XCTAssertNil(rpgAccessibilityViewFrame(
            logical: RPGLogicalRect(x: 1, y: 1, width: 20, height: 20),
            uiScale: 3, backingScale: 2, viewWidth: 0, viewHeight: 600))
    }

    func testPublicationClockRecoversAfterTransientFailureAndLatchesTrueExhaustion() {
        var clock = RPGAccessibilityPublicationClock()
        let invalid: String? = clock.publish { _ in nil }
        XCTAssertNil(invalid)
        XCTAssertEqual(clock.generation, 0)
        XCTAssertFalse(clock.exhausted)
        let valid: UInt64? = clock.publish { $0 }
        XCTAssertEqual(valid, 1)
        XCTAssertEqual(clock.generation, 1)
        XCTAssertFalse(clock.exhausted)

        var exhausted = RPGAccessibilityPublicationClock(generation: UInt64.max)
        let impossible: UInt64? = exhausted.publish { $0 }
        XCTAssertNil(impossible)
        XCTAssertTrue(exhausted.exhausted)
        XCTAssertNil(exhausted.publish { Optional($0) } as UInt64?)
    }

    @MainActor
    func testOffscreenSemanticFocusUsesSharedReducerRevealAndInvalidatesOldRevision() throws {
        let fixture = try fixture()
        let offscreen = try XCTUnwrap(fixture.tree.elements.first {
            $0.descriptor.role == .rankCell && $0.descriptor.visibleFrame == nil
        })
        let context = try XCTUnwrap(RPGScreenInteractionContext(
            model: fixture.model, screenInstanceID: 1, semanticRevision: 1))
        let transition = rpgReduceScreenInteraction(
            RPGScreenInteractionState(), event: .focusElement(offscreen.descriptor.id),
            context: context)
        XCTAssertTrue(transition.handled)
        XCTAssertEqual(transition.state.focusedID, offscreen.descriptor.id)
        XCTAssertGreaterThan(transition.state.scrollOffset, 0)
        let rebuilt = rpgBuildScreenModel(fixture.runtime.modelInput(
            viewportWidth: 360, viewportHeight: 224, tab: .skills,
            focusedID: transition.state.focusedID,
            scrollOffset: transition.state.scrollOffset))
        let next = try XCTUnwrap(RPGCommittedSemanticSnapshot(
            screenInstanceID: 1, semanticRevision: 2,
            model: rebuilt, runtime: fixture.runtime))
        XCTAssertNotEqual(next.semanticRevision, fixture.tree.semanticRevision)
        XCTAssertNotNil(next.model.descriptors.first {
            $0.id == offscreen.descriptor.id && $0.visibleFrame != nil
        })
    }

    @MainActor
    func testNotificationIntentsAndAppearanceSemanticsAreCommitBound() throws {
        let baseline = try fixture()
        XCTAssertTrue(rpgAccessibilityNotificationIntents(
            previous: baseline.tree, current: baseline.tree).isEmpty)
        let nextFocus = try XCTUnwrap(baseline.model.nextFocusableID)
        let focused = try fixture(focusedID: nextFocus, semanticRevision: 2)
        XCTAssertTrue(rpgAccessibilityNotificationIntents(
            previous: baseline.tree, current: focused.tree).contains(.focusedElementChanged))
        let appearance = try fixture(highContrast: true, reduceMotion: true,
                                     semanticRevision: 3)
        XCTAssertTrue(appearance.tree.highContrast)
        XCTAssertTrue(appearance.tree.reduceMotion)
        XCTAssertTrue(rpgAccessibilityNotificationIntents(
            previous: baseline.tree, current: appearance.tree).contains(.layoutChanged))
    }

    @MainActor
    func testEveryCachedIdentityAndContentReplacementInvalidatesSubtree() throws {
        let baseline = try fixture()
        XCTAssertEqual(rpgAccessibilityNotificationIntents(
            previous: baseline.tree, current: baseline.tree), [])

        let screenReplacement = try fixture(screenInstanceID: 2)
        func assertSingleLayout(_ current: RPGAccessibilityTreeSnapshot,
                                file: StaticString = #filePath, line: UInt = #line) {
            let intents = rpgAccessibilityNotificationIntents(
                previous: baseline.tree, current: current)
            XCTAssertEqual(intents.filter { $0 == .layoutChanged }.count, 1,
                           file: file, line: line)
        }
        assertSingleLayout(screenReplacement.tree)
        let revisionReplacement = try fixture(semanticRevision: 2, layoutGeneration: 1)
        assertSingleLayout(revisionReplacement.tree)
        let layoutReplacement = try fixture(semanticRevision: 1, layoutGeneration: 2)
        assertSingleLayout(layoutReplacement.tree)

        func tree(replacing index: Int,
                  with replacement: RPGAccessibilityElementSnapshot)
            throws -> RPGAccessibilityTreeSnapshot {
            var elements = baseline.tree.elements
            elements[index] = replacement
            return try XCTUnwrap(RPGAccessibilityTreeSnapshot(
                screenInstanceID: baseline.tree.screenInstanceID,
                semanticRevision: baseline.tree.semanticRevision,
                layoutGeneration: baseline.tree.layoutGeneration,
                viewport: baseline.tree.viewport, elements: elements,
                focusedID: baseline.tree.focusedID,
                highContrast: baseline.tree.highContrast,
                reduceMotion: baseline.tree.reduceMotion))
        }

        let index = try XCTUnwrap(baseline.tree.elements.firstIndex { $0.hasPressAction })
        let cached = baseline.tree.elements[index]
        let input = try XCTUnwrap(baseline.committed.semanticInputs[cached.descriptor.id])
        let changedCommand = RPGSemanticDescriptor(
            id: cached.descriptor.id, role: cached.descriptor.role,
            label: cached.descriptor.label, value: cached.descriptor.value,
            help: cached.descriptor.help, enabled: true, isFocusable: true,
            frame: cached.descriptor.frame, visibleFrame: cached.descriptor.visibleFrame,
            actionCommand: .selectTab(.spells))
        let commandInput = try XCTUnwrap(baseline.runtime.semanticInput(for: .selectTab(.spells)))
        let commandOrigin = try XCTUnwrap(RPGSemanticActivationOrigin(
            screenInstanceID: baseline.tree.screenInstanceID,
            semanticRevision: baseline.tree.semanticRevision,
            descriptor: changedCommand, input: commandInput))
        let commandElement = try XCTUnwrap(RPGAccessibilityElementSnapshot(
            descriptor: changedCommand, activationOrigin: commandOrigin,
            layoutGeneration: baseline.tree.layoutGeneration,
            viewport: baseline.tree.viewport))
        let commandFingerprintReplacement = try tree(replacing: index, with: commandElement)
        assertSingleLayout(commandFingerprintReplacement)

        let changedInput = try XCTUnwrap(RPGSemanticInputSnapshot(
            localPreferenceScope: input.localPreferenceScope,
            localPreferenceRevision: input.localPreferenceRevision,
            localPreferenceWritable: input.localPreferenceWritable,
            worldEntryGeneration: input.worldEntryGeneration,
            rulesGeneration: input.rulesGeneration + 1,
            ownerRevision: input.ownerRevision,
            inventoryDigest: input.inventoryDigest,
            equipmentFocusDigest: input.equipmentFocusDigest,
            authorityRevision: input.authorityRevision,
            authorityPhase: input.authorityPhase,
            authorityRequestIdentity: input.authorityRequestIdentity,
            operationExpectedState: input.operationExpectedState))
        let inputOrigin = try XCTUnwrap(RPGSemanticActivationOrigin(
            screenInstanceID: baseline.tree.screenInstanceID,
            semanticRevision: baseline.tree.semanticRevision,
            descriptor: cached.descriptor, input: changedInput))
        let inputElement = try XCTUnwrap(RPGAccessibilityElementSnapshot(
            descriptor: cached.descriptor, activationOrigin: inputOrigin,
            layoutGeneration: baseline.tree.layoutGeneration,
            viewport: baseline.tree.viewport))
        let inputFingerprintReplacement = try tree(replacing: index, with: inputElement)
        assertSingleLayout(inputFingerprintReplacement)

        let tabReplacement = try fixture(tab: .actives,
                                         semanticRevision: 1, layoutGeneration: 1)
        assertSingleLayout(tabReplacement.tree)
    }

    @MainActor
    func testGameCoreAccessibilityStaleOriginsConsumeWithoutMutationAndFreshMutatesOnce() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "accessibility-e2e")
        game.createWorld(name: "Accessibility E2E", seedText: "9090",
                         mode: GameMode.survival, difficulty: 2)
        let draft = RPGCreationDraft(
            pathID: "arcanist", attributes: .defaultCreation,
            starterSkillID: "spell_formula", starterSpellIDs: [])
        let command = RPGSemanticCommand.create(draft)
        let id = RPGUIElementID(rawValue: "accessibility:create")!
        let descriptor = RPGSemanticDescriptor(
            id: id, role: .button, label: "Create character",
            enabled: true, isFocusable: true,
            frame: RPGLogicalRect(x: 0, y: 0, width: 120, height: 24),
            visibleFrame: RPGLogicalRect(x: 0, y: 0, width: 120, height: 24),
            actionCommand: command)
        let input = try XCTUnwrap(game.rpgSemanticInputSnapshot(for: command))
        let oldOrigin = try XCTUnwrap(RPGSemanticActivationOrigin(
            screenInstanceID: 1, semanticRevision: 1,
            descriptor: descriptor, input: input))
        let changedDraft = RPGCreationDraft(
            pathID: "warden", attributes: .defaultCreation,
            starterSkillID: "guard_stance", starterSpellIDs: [])
        let changedDescriptor = RPGSemanticDescriptor(
            id: id, role: .button, label: "Create character",
            enabled: true, isFocusable: true,
            frame: descriptor.frame, visibleFrame: descriptor.visibleFrame,
            actionCommand: .create(changedDraft))

        let boundary = RPGSemanticActivationBoundary()
        let beforeRPG = game.player.rpg
        let beforeInventory = game.player.inventory
        let beforePreferences = game.rpgQuickSlotPreferences
        let staleCases: [(UInt64, UInt64, RPGSemanticDescriptor)] = [
            (2, 1, descriptor),
            (1, 2, descriptor),
            (1, 1, changedDescriptor),
        ]
        for (screenID, revision, currentDescriptor) in staleCases {
            let stale = try XCTUnwrap(boundary.capture(origin: oldOrigin))
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                stale, source: .accessibility, using: boundary,
                screenInstanceID: screenID, semanticRevision: revision,
                descriptor: currentDescriptor), .staleRequiresFreshActivation)
            XCTAssertEqual(game.player.rpg, beforeRPG)
            XCTAssertEqual(game.player.inventory, beforeInventory)
            XCTAssertEqual(game.rpgQuickSlotPreferences, beforePreferences)
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                stale, source: .accessibility, using: boundary,
                screenInstanceID: 1, semanticRevision: 1,
                descriptor: descriptor), .invalidOrReplayedReceipt)
        }

        let freshInput = try XCTUnwrap(game.rpgSemanticInputSnapshot(for: command))
        let freshOrigin = try XCTUnwrap(RPGSemanticActivationOrigin(
            screenInstanceID: 1, semanticRevision: 2,
            descriptor: descriptor, input: freshInput))
        let fresh = try XCTUnwrap(boundary.capture(origin: freshOrigin))
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            fresh, source: .accessibility, using: boundary,
            screenInstanceID: 1, semanticRevision: 2,
            descriptor: descriptor), .dispatched(serial: 1))
        XCTAssertTrue(game.player.rpg.created)
        XCTAssertNotEqual(game.player.inventory, beforeInventory)
        XCTAssertEqual(game.rpgQuickSlotPreferences, beforePreferences)
        let afterRPG = game.player.rpg
        let afterInventory = game.player.inventory
        let afterPreferences = game.rpgQuickSlotPreferences
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            fresh, source: .accessibility, using: boundary,
            screenInstanceID: 1, semanticRevision: 2,
            descriptor: descriptor), .invalidOrReplayedReceipt)
        XCTAssertEqual(game.player.rpg, afterRPG)
        XCTAssertEqual(game.player.inventory, afterInventory)
        XCTAssertEqual(game.rpgQuickSlotPreferences, afterPreferences)
    }
}

private extension RPGSemanticRole {
    static var allCasesForAccessibilityTesting: [RPGSemanticRole] {
        [.button, .staticText, .tab, .group, .row, .scrollArea, .rankCell]
    }
}
