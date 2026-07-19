import AppKit
import XCTest
@testable import ElysiumCore

final class RPGScreenModelTests: XCTestCase {
    func testEveryCreationAndTutorialStepOwnsExactNonemptyFittingVisualLines() throws {
        for viewport in RPGUIHarnessViewport.allCases {
            let size = viewport.size
            for step in RPGCreationStep.allCases {
                var creation = rpgInitialCreationSession()
                creation.step = step
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: .uncreated(), creation: creation,
                    viewportWidth: size.0, viewportHeight: size.1))
                let expected = rpgCreationStepTitle(step)
                let value = try XCTUnwrap(model.descriptors.first {
                    $0.id == .creationStep(step)
                })
                XCTAssertEqual(value.label, expected)
                XCTAssertEqual(value.value, expected)
                XCTAssertEqual(value.help, expected)
                XCTAssertFalse(value.visualLines.isEmpty)
                XCTAssertEqual(value.visualLines.joined(separator: " "), expected)
                XCTAssertTrue(rpgDescriptorVisualLinesFit(
                    frame: value.frame, iconAssetID: value.iconAssetID,
                    visualLines: value.visualLines))
            }
            let state = try XCTUnwrap(rpgScreenFixture(
                pathID: "warden", branchID: "warden_guardian"))
            for page in 1...4 {
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: state,
                    tutorial: RPGTutorialState(seenVersion: 0, page: page),
                    viewportWidth: size.0, viewportHeight: size.1))
                let expected = "Tutorial \(page) of 4"
                let value = try XCTUnwrap(model.descriptors.first {
                    $0.id.rawValue == "tutorial-step"
                })
                XCTAssertEqual(value.label, expected)
                XCTAssertEqual(value.value, expected)
                XCTAssertEqual(value.help, expected)
                XCTAssertEqual(value.visualLines, [expected])
                XCTAssertTrue(rpgDescriptorVisualLinesFit(
                    frame: value.frame, iconAssetID: value.iconAssetID,
                    visualLines: value.visualLines))
            }
        }
    }

    func testFiveCharacterTabsUseCheckedCompleteDisjointHalfOpenFrames() throws {
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for viewport in RPGUIHarnessViewport.allCases {
            let size = viewport.size
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: state, viewportWidth: size.0, viewportHeight: size.1))
            let projected = try XCTUnwrap(rpgCharacterTabFrames(
                in: model.layout.stepOrTabFrame))
            XCTAssertEqual(projected.map(\.tab), RPGCharacterTab.allCases)
            XCTAssertEqual(projected.first?.frame.x, model.layout.stepOrTabFrame.x)
            XCTAssertEqual(projected.last?.frame.maxX, model.layout.stepOrTabFrame.maxX)
            for (index, value) in projected.enumerated() {
                XCTAssertEqual(value.visualLines, [value.tab.rawValue.capitalized])
                XCTAssertTrue(value.frame.isFinite)
                XCTAssertGreaterThan(value.frame.width, 0)
                XCTAssertTrue(model.layout.stepOrTabFrame.contains(value.frame))
                XCTAssertTrue(rpgDescriptorVisualLinesFit(
                    frame: value.frame, iconAssetID: nil,
                    visualLines: value.visualLines))
                let descriptor = try XCTUnwrap(model.descriptors.first {
                    $0.id == .tab(value.tab)
                })
                XCTAssertEqual(descriptor.frame, value.frame)
                XCTAssertEqual(descriptor.visualLines, value.visualLines)
                let y = value.frame.y + value.frame.height / 2
                XCTAssertEqual(rpgScreenDescriptor(
                    atX: value.frame.x, y: y, in: model)?.id, descriptor.id)
                if index + 1 < projected.count {
                    XCTAssertEqual(value.frame.maxX, projected[index + 1].frame.x)
                    XCTAssertEqual(rpgScreenDescriptor(
                        atX: value.frame.maxX, y: y, in: model)?.id,
                        .tab(projected[index + 1].tab))
                }
            }
        }
        XCTAssertNil(rpgCharacterTabFrames(in: RPGLogicalRect(
            x: 0, y: 0, width: 1, height: 20)))
        XCTAssertNil(rpgCharacterTabFrames(in: RPGLogicalRect(
            x: .nan, y: 0, width: 400, height: 20)))
        XCTAssertNil(rpgCharacterTabFrames(in: RPGLogicalRect(
            x: Double.greatestFiniteMagnitude, y: 0,
            width: Double.greatestFiniteMagnitude, height: 20)))
        XCTAssertNil(rpgCharacterTabFrames(in: RPGLogicalRect(
            x: 0, y: Double.greatestFiniteMagnitude,
            width: 400, height: Double.greatestFiniteMagnitude)))
    }


    func testCreationRetainsSixDraftsAndProducesNoManualSpells() throws {
        var session = rpgInitialCreationSession()
        XCTAssertEqual(session.pathDrafts.count, 6)
        session = try rpgReduceCreationSession(session, command: .choosePath("arcanist")).get()
        session = try rpgReduceCreationSession(session, command: .chooseBranch("arcanist_ritualist")).get()
        session = try rpgReduceCreationSession(session, command: .toggleStartingSkill("ritual_circle")).get()
        session = try rpgReduceCreationSession(session, command: .toggleStartingSkill("bound_servant")).get()
        // Path is re-chosen with the SAME path (arcanist), retaining the branch/skill choice made
        // above (amendment A1); choosing a different path and back would reset it instead.
        session = try rpgReduceCreationSession(session, command: .back).get()
        session = try rpgReduceCreationSession(session, command: .back).get()
        session = try rpgReduceCreationSession(session, command: .choosePath("arcanist")).get()
        XCTAssertEqual(session.selectedDraft?.branchID, "arcanist_ritualist")
        XCTAssertEqual(Set(session.selectedDraft?.startingSkillIDs ?? []),
                       ["spell_formula", "minor_glamour", "bound_servant"])
        let draft = try rpgCreationDraft(from: session).get()
        XCTAssertEqual(draft.branchID, "arcanist_ritualist")
        XCTAssertTrue(draft.starterSpellIDs.isEmpty)
        XCTAssertEqual(rpgPathCardModels(session: session).count, 6)
    }

    func testCompactCreatorAndTutorialAlwaysExposeOneCompletePanelAndRevealCards() throws {
        for path in RPG_PATH_DEFINITIONS {
            let pathSession = rpgInitialCreationSession()
            let pathModel = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: pathSession,
                viewportWidth: 360, viewportHeight: 224))
            let pathCard = try XCTUnwrap(pathModel.descriptors.first { $0.id == .path(path.id) })
            XCTAssertEqual(pathCard.label,
                "\(path.displayName), path \(RPG_PATH_DEFINITIONS.firstIndex(where: { $0.id == path.id })! + 1) of 6")
            XCTAssertTrue(pathModel.visibleDescriptors.filter {
                $0.id.rawValue.hasPrefix("path:") &&
                    $0.layoutRegion == .scrollingContent
            }.allSatisfy { descriptor in
                guard let visible = descriptor.visibleFrame else { return false }
                return pathModel.contentFrame.contains(visible)
            })

            let branchSession = try rpgReduceCreationSession(
                pathSession, command: .choosePath(path.id)).get()
            let branchModel = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: branchSession,
                viewportWidth: 360, viewportHeight: 224))
            let branches = branchModel.descriptors.filter {
                $0.id.rawValue.hasPrefix("branch:") && !$0.id.rawValue.contains(":operation:")
            }
            XCTAssertEqual(branches.count, 3)
            XCTAssertTrue(branches.allSatisfy { $0.frame.width == branchModel.contentFrame.width })
            XCTAssertTrue(branches.contains { $0.visibleFrame != nil })
        }

        let created = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for page in 1...4 {
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: created, tutorial: RPGTutorialState(seenVersion: 0, page: page),
                viewportWidth: 360, viewportHeight: 224))
            let tutorial = try XCTUnwrap(model.descriptors.first {
                $0.id.rawValue.hasPrefix("tutorial:") &&
                    !$0.id.rawValue.contains(":operation:")
            })
            XCTAssertNotNil(tutorial.visibleFrame)
            XCTAssertTrue(model.contentFrame.contains(tutorial.frame))
            XCTAssertEqual(model.stepOrTabText, "Tutorial \(page) of 4")
            for label in ["Close", "Skip", page == 4 ? "Finish" : "Next"] {
                let command = try XCTUnwrap(model.descriptors.first { $0.label == label })
                XCTAssertEqual(command.layoutRegion, .fixed)
                XCTAssertNotNil(command.visibleFrame)
                XCTAssertTrue(model.layout.commandFrame.contains(command.frame))
            }
        }
    }

    func testEveryPathAndBranchCardPublishesCanonicalVisibleIconContentAndSelection() throws {
        for selectedPath in RPG_PATH_DEFINITIONS {
            let session = rpgInitialCreationSession()
            let pathModel = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: session,
                viewportWidth: 360, viewportHeight: 224))
            let card = try XCTUnwrap(pathModel.descriptors.first { $0.id == .path(selectedPath.id) })
            XCTAssertEqual(card.iconAssetID, rpgAssetIDForPath(selectedPath.id))
            XCTAssertNotNil(rpgIconPixels(assetID: try XCTUnwrap(card.iconAssetID)))
            XCTAssertTrue(card.visualLines.contains { $0.contains(selectedPath.displayName) })
            let source = try XCTUnwrap(rpgPathCardModels(session: session).first {
                $0.pathID == selectedPath.id
            })
            XCTAssertTrue(card.visualLines.joined(separator: " ").contains(source.roleText))

            var branchSession = try rpgReduceCreationSession(
                session, command: .choosePath(selectedPath.id)).get()
            for selectedBranch in selectedPath.branchIDs {
                branchSession = try rpgReduceCreationSession(
                    branchSession, command: .chooseBranch(selectedBranch)).get()
                // chooseBranch advances to .skills; step back to .branch to inspect the sub-class
                // cards with the chosen sub-class highlighted.
                branchSession.step = .branch
                let branchModel = rpgBuildScreenModel(RPGScreenModelInput(
                    state: .uncreated(), creation: branchSession,
                    viewportWidth: 360, viewportHeight: 224))
                for branchID in selectedPath.branchIDs {
                    let branch = try XCTUnwrap(rpgBranchDefinition(branchID))
                    let starterID = try XCTUnwrap(branch.skillIDs.first)
                    let branchCard = try XCTUnwrap(branchModel.descriptors.first {
                        $0.id == .branch(branchID)
                    })
                    XCTAssertEqual(branchCard.iconAssetID, rpgAssetIDForSkill(starterID))
                    XCTAssertNotNil(rpgIconPixels(assetID: try XCTUnwrap(branchCard.iconAssetID)))
                    XCTAssertTrue(branchCard.visualLines.contains(branch.displayName))
                    // C2: the Skills line names all three sub-class skills. At a compact viewport the
                    // line may wrap, so assert the joined visual text carries "Skills:" and each name.
                    let joined = branchCard.visualLines.joined(separator: " ")
                    XCTAssertTrue(joined.contains("Skills:"))
                    for skillName in branch.skillIDs.compactMap({ rpgSkillDefinition($0)?.displayName }) {
                        XCTAssertTrue(joined.contains(skillName), "\(branchID) missing \(skillName)")
                    }
                    XCTAssertEqual(branchCard.adornment,
                        branchID == selectedBranch ? .selectedCheckDoubleBorder : .none)
                    XCTAssertTrue(branchCard.help.contains(
                        branchID == selectedBranch ? "selected" : "Choose"))
                    XCTAssertTrue(branchCard.reservesIconCell)
                }
            }
        }
    }

    func testCanonicalDisplayNamesWrappedOperationsReviewAndDirectionalMovesNeverLeakIDs() throws {
        XCTAssertEqual(RPG_SKILL_DEFINITIONS.filter { $0.kind == .active }.count, 19)
        XCTAssertEqual(RPG_SPELL_DEFINITIONS.count, 17)
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("display-names")
        func assertNoRawID(_ descriptor: RPGSemanticDescriptor,
                           forbidden: [String], file: StaticString = #filePath,
                           line: UInt = #line) {
            let sinks = [descriptor.label, descriptor.value, descriptor.help] + descriptor.visualLines
            for value in forbidden where !value.isEmpty {
                XCTAssertTrue(sinks.allSatisfy { !$0.contains(value) },
                              "\(descriptor.id.rawValue) leaked \(value)", file: file, line: line)
            }
        }

        var activeCount = 0
        for definition in RPG_SKILL_DEFINITIONS where definition.kind == .active {
            let branch = try XCTUnwrap(rpgPathDefinition(definition.pathID)?.branchIDs.first)
            var state = try XCTUnwrap(rpgScreenFixture(
                pathID: definition.pathID, branchID: branch))
            state.skillRanks[definition.id] = max(1, state.skillRanks[definition.id] ?? 0)
            if !state.preparedSkillIDs.contains(definition.id) {
                state.preparedSkillIDs.append(definition.id)
            }
            let token = rpgPreparedActionToken(kind: .skill, id: definition.id)
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: state, quickSlots: RPGQuickSlotPreferences(tokens: [token]),
                localPreferenceScope: scope, localPreferenceRevision: 1,
                localPreferenceWritable: true, viewportWidth: 360,
                viewportHeight: 224, tab: .actives,
                selection: RPGScreenSelection(selectedSemanticID: .skill(definition.id),
                    inspectorItemID: .skill(definition.id))))
            let row = try XCTUnwrap(model.descriptors.first { $0.id == .skill(definition.id) })
            XCTAssertEqual(row.label, definition.displayName)
            let operation = try XCTUnwrap(model.descriptors.first {
                $0.id == .operation(owner: .skill(definition.id), name: "unprepare")
            })
            XCTAssertEqual(operation.label, "Unprepare \(definition.displayName)")
            XCTAssertGreaterThanOrEqual(operation.frame.height,
                rpgControlHeight(lines: operation.visualLines))
            XCTAssertEqual(model.descriptors.first { $0.id == .slot(0) }?.value,
                           definition.displayName)
            assertNoRawID(row, forbidden: [definition.id, token])
            assertNoRawID(operation, forbidden: [definition.id, token])
            activeCount += 1
        }
        XCTAssertEqual(activeCount, 19)

        var spellCount = 0
        for spell in RPG_SPELL_DEFINITIONS {
            let path = try XCTUnwrap(RPG_PATH_DEFINITIONS.first { path in
                path.branchIDs.flatMap { rpgBranchDefinition($0)?.skillIDs ?? [] }.contains { skillID in
                    rpgSkillDefinition(skillID)?.spellUnlocks.contains(where: {
                        $0.spellID == spell.id
                    }) == true
                }
            })
            let branch = try XCTUnwrap(path.branchIDs.first)
            var state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branch))
            if !state.knownSpellIDs.contains(spell.id) { state.knownSpellIDs.append(spell.id) }
            if !state.preparedSpellIDs.contains(spell.id) { state.preparedSpellIDs.append(spell.id) }
            let token = rpgPreparedActionToken(kind: .spell, id: spell.id)
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: state, quickSlots: RPGQuickSlotPreferences(tokens: [token]),
                localPreferenceScope: scope, localPreferenceRevision: 1,
                localPreferenceWritable: true, viewportWidth: 360,
                viewportHeight: 224, tab: .spells))
            let row = try XCTUnwrap(model.descriptors.first { $0.id == .spell(spell.id) })
            XCTAssertEqual(row.label, spell.displayName)
            let operation = try XCTUnwrap(model.descriptors.first {
                $0.id == .operation(owner: .spell(spell.id), name: "unprepare")
            })
            XCTAssertEqual(operation.label, "Unprepare \(spell.displayName)")
            XCTAssertGreaterThanOrEqual(operation.frame.height,
                rpgControlHeight(lines: operation.visualLines))
            assertNoRawID(row, forbidden: [spell.id, token])
            assertNoRawID(operation, forbidden: [spell.id, token])
            spellCount += 1
        }
        XCTAssertEqual(spellCount, 17)

        for path in RPG_PATH_DEFINITIONS {
            var session = rpgInitialCreationSession()
            session = try rpgReduceCreationSession(session, command: .choosePath(path.id)).get()
            let branchID = try XCTUnwrap(path.branchIDs.first)
            session = try rpgReduceCreationSession(session, command: .chooseBranch(branchID)).get()
            session = try rpgReduceCreationSession(session, command: .confirmStartingSkills).get()
            let review = try XCTUnwrap(rpgCreationReviewProjection(
                session: session, chordBindings: rpgDefaultChordBindings(),
                authority: .localReady, inventoryCapacitySummary: "Fits."))
            XCTAssertEqual(review.configuredChordProjections.count, 12)
            XCTAssertEqual(review.starterKitItems.count,
                           try XCTUnwrap(rpgStarterKit(pathID: path.id)).count)
            let visible = review.starterKit + review.configuredChords
            for forbidden in ["rpgCharacter", "rpgCycleAction", "rpgUseAction",
                              "rpgQuickSlot", "stone_sword", "apprentice_focus"] {
                XCTAssertTrue(visible.allSatisfy { !$0.contains(forbidden) },
                              "\(path.id) leaked \(forbidden)")
            }
            XCTAssertEqual(review.configuredChordProjections.map(\.actionDisplayName),
                ["Character", "Cycle Prepared Action", "Use Selected Action"] +
                    (1...9).map { "Quick Slot \($0)" })
        }

        let moveState = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        let moves = rpgBuildScreenModel(RPGScreenModelInput(
            state: moveState,
            quickSlots: RPGQuickSlotPreferences(tokens: [nil, "skill:interpose"]),
            localPreferenceScope: scope, localPreferenceRevision: 1,
            localPreferenceWritable: true, viewportWidth: 360,
            viewportHeight: 224, tab: .actives))
        let left = try XCTUnwrap(moves.descriptors.first {
            $0.id == .operation(owner: .slot(1), name: "move-left")
        })
        let right = try XCTUnwrap(moves.descriptors.first {
            $0.id == .operation(owner: .slot(1), name: "move-right")
        })
        XCTAssertEqual(left.label, "Move Quick Slot 2 Left")
        XCTAssertEqual(right.label, "Move Quick Slot 2 Right")
        XCTAssertEqual(left.visualLines, ["← Move Left"])
        XCTAssertEqual(right.visualLines, ["Move Right →"])
        XCTAssertEqual(left.adornment, .moveLeft)
        XCTAssertEqual(right.adornment, .moveRight)
        XCTAssertNotEqual(left.frame, right.frame)
        XCTAssertEqual(left.actionCommand, .moveSlot(from: 1, to: 0))
        XCTAssertEqual(right.actionCommand, .moveSlot(from: 1, to: 2))
        XCTAssertEqual(rpgPreparedActionDisplayName("skill:missing"), "Unavailable action")
        XCTAssertEqual(rpgPreparedActionDisplayName("not-a-token"), "Unavailable action")
    }

    func testActivesHierarchyPutsEveryPathActionBeforeInspectorAndQuickSlots() throws {
        for path in RPG_PATH_DEFINITIONS {
            let branch = try XCTUnwrap(path.branchIDs.first)
            let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branch))
            let projection = try XCTUnwrap(rpgPathProjection(pathID: path.id, state: state))
            for viewport in [(360.0, 224.0), (520.0, 330.0)] {
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: state, viewportWidth: viewport.0,
                    viewportHeight: viewport.1, tab: .actives))
                let ids = model.descriptors.map(\.id)
                let headingIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "actives:path-actions")!))
                let slotsIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "actives:local-quick-slots")!))
                if projection.activeSkillIDs.isEmpty {
                    XCTAssertNil(ids.firstIndex(of:
                        RPGUIElementID(rawValue: "actives:selected-action")!))
                    XCTAssertLessThan(headingIndex, slotsIndex)
                } else {
                    let inspectorIndex = try XCTUnwrap(ids.firstIndex(of:
                        RPGUIElementID(rawValue: "actives:selected-action")!))
                    XCTAssertLessThan(headingIndex, inspectorIndex)
                    XCTAssertLessThan(inspectorIndex, slotsIndex)
                    for skillID in projection.activeSkillIDs {
                        let actionIndex = try XCTUnwrap(ids.firstIndex(of: .skill(skillID)))
                        XCTAssertGreaterThan(actionIndex, headingIndex)
                        XCTAssertLessThan(actionIndex, inspectorIndex)
                    }
                }
                XCTAssertNotNil(model.descriptors.first {
                    $0.id.rawValue == "actives:path-actions"
                }?.visibleFrame)
                if let first = projection.activeSkillIDs.first {
                    XCTAssertNotNil(model.descriptors.first { $0.id == .skill(first) }?.visibleFrame)
                }
                XCTAssertGreaterThan(try XCTUnwrap(ids.firstIndex(of: .slot(0))), slotsIndex)
            }
        }

        var state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_vanguard"))
        let heavyCut = "heavy_cut"
        state.skillRanks[heavyCut] = max(1, state.skillRanks[heavyCut] ?? 0)
        if !state.preparedSkillIDs.contains(heavyCut) { state.preparedSkillIDs.append(heavyCut) }
        let model = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, viewportWidth: 360, viewportHeight: 224, tab: .actives,
            selection: RPGScreenSelection(selectedSemanticID: .skill(heavyCut),
                                           inspectorItemID: .skill(heavyCut))))
        XCTAssertEqual(model.descriptors.first { $0.id == .skill(heavyCut) }?.label,
                       "Heavy Cut")
        let actionY = try XCTUnwrap(model.descriptors.first { $0.id == .skill(heavyCut) }?.frame.y)
        let slotY = try XCTUnwrap(model.descriptors.first { $0.id == .slot(0) }?.frame.y)
        XCTAssertLessThan(actionY, slotY)
        XCTAssertEqual(model.descriptors.first {
            $0.id.rawValue == "actives:selected-action"
        }?.value, "Heavy Cut")
    }

    func testAllEighteenProgressionPlansExposeCanonicalCompleteRouteAndConstraint() throws {
        // v3: 5 ranks x 3 nodes = 15 route milestones per sub-class; every in-sub-class rank costs
        // a flat 1 point (rank 1 of each node is free). Completing the whole sub-class costs 14
        // (12 paid ranks after the 3 free node-1 ranks... rank1 node0 is the free starter),
        // against a 25-point lifetime budget, leaving an 11-point utility allowance.
        let expectedLevels = [1, 1, 1, 4, 6, 8, 8, 10, 12, 12, 14, 16, 16, 18, 20]
        let expectedCosts = [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        var count = 0
        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branchID))
                let summary = rpgProgressionSummaryProjection(state)
                XCTAssertEqual(summary.plan.selectedBranchDisplayName,
                               rpgBranchDefinition(branchID)?.displayName)
                XCTAssertEqual(summary.plan.routeMilestones.count, 15)
                XCTAssertEqual(summary.plan.routeMilestones.map(\.level), expectedLevels)
                XCTAssertEqual(summary.plan.routeMilestones.map(\.cost), expectedCosts)
                XCTAssertEqual(summary.plan.completionCost, 14)
                XCTAssertEqual(summary.plan.levelCapEarnedSkillPoints, 25)
                XCTAssertEqual(summary.plan.utilityAllowance, 11)
                XCTAssertTrue(summary.plan.completionImpactText.contains(
                    "\(summary.specializationRemainingCost) SP"))
                XCTAssertEqual(summary.plan.crossBranchCapstoneText,
                    "Off-sub-class Rank 5 of a third-position skill requires level 22; the level cap is 20, so it is unreachable.")

                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: state, viewportWidth: 700, viewportHeight: 420,
                    tab: .progression))
                let ids = model.descriptors.map(\.id)
                let branchIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "progression:plan:selected-branch")!))
                let costIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "progression:plan:completion-cost")!))
                let utilityIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "progression:plan:utility")!))
                let impactIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "progression:plan:impact")!))
                let crossIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "progression:plan:cross-branch")!))
                let levelOneIndex = try XCTUnwrap(ids.firstIndex(of:
                    RPGUIElementID(rawValue: "progression:level:1")!))
                XCTAssertLessThan(branchIndex, costIndex)
                XCTAssertLessThan(costIndex, utilityIndex)
                XCTAssertLessThan(utilityIndex, impactIndex)
                XCTAssertLessThan(impactIndex, crossIndex)
                XCTAssertLessThan(crossIndex, levelOneIndex)
                let cross = try XCTUnwrap(model.descriptors.first {
                    $0.id.rawValue == "progression:plan:cross-branch"
                })
                XCTAssertEqual(cross.value, summary.plan.crossBranchCapstoneText)
                XCTAssertEqual(cross.help, summary.plan.crossBranchCapstoneText)
                count += 1
            }
        }
        XCTAssertEqual(count, 18)
    }

    func testSharedFocusRingTokenProvidesExactContainedStandardAndHighContrastGeometry() throws {
        let frame = RPGLogicalRect(x: 10, y: 20, width: 100, height: 40)
        let standard = rpgFocusRingToken(highContrast: false)
        XCTAssertEqual(standard.lightOuterWidth, 1)
        XCTAssertEqual(standard.darkSeparationWidth, 1)
        let standardGeometry = try XCTUnwrap(
            rpgFocusRingGeometry(frame: frame, token: standard))
        XCTAssertTrue(frame.contains(standardGeometry.lightOuterFrame))
        XCTAssertTrue(frame.contains(standardGeometry.darkSeparationFrame))
        XCTAssertTrue(standardGeometry.lightOuterFrame.contains(
            standardGeometry.darkSeparationFrame))

        let high = rpgFocusRingToken(highContrast: true)
        XCTAssertEqual(high.lightOuterWidth, 2)
        XCTAssertEqual(high.darkSeparationWidth, 1)
        let highGeometry = try XCTUnwrap(
            rpgFocusRingGeometry(frame: frame, token: high))
        XCTAssertTrue(frame.contains(highGeometry.lightOuterFrame))
        XCTAssertTrue(frame.contains(highGeometry.darkSeparationFrame))
        XCTAssertTrue(highGeometry.lightOuterFrame.contains(highGeometry.darkSeparationFrame))
        XCTAssertNil(rpgFocusRingGeometry(
            frame: RPGLogicalRect(x: 0, y: 0, width: 1, height: 1), token: high))
    }

    /// The per-rank-cell model was retired: a skill is now a single card whose `rankPips`
    /// summarizes all five ranks at once, so a path now projects 3 branches, 9 skills, and 9
    /// skill cards (not 27 individual rank cells).
    func testEveryPathProjectsThreeBranchesNineSkillsNineCardsAndAggregateIsUnique() throws {
        var allCardIDs = Set<RPGUIElementID>()
        var branchCount = 0, skillCount = 0, cardCount = 0
        for path in RPG_PATH_DEFINITIONS {
            let branch = try XCTUnwrap(path.branchIDs.first)
            let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branch))
            let projection = try XCTUnwrap(rpgPathProjection(pathID: path.id, state: state))
            XCTAssertEqual(projection.branchIDs.count, 3)
            XCTAssertEqual(projection.skillIDs.count, 9)
            XCTAssertEqual(projection.skillCards.count, 9)
            branchCount += projection.branchIDs.count
            skillCount += projection.skillIDs.count
            cardCount += projection.skillCards.count
            projection.skillCards.forEach { allCardIDs.insert($0.id) }

            for (width, height) in [(360.0, 224.0), (520.0, 330.0), (700.0, 420.0)] {
                let model = rpgBuildScreenModel(RPGScreenModelInput(state: state,
                    viewportWidth: width, viewportHeight: height, tab: .skills))
                XCTAssertNil(model.errorText)
                let cards = model.descriptors.filter { $0.role == .row && $0.rankPips != nil }
                XCTAssertEqual(cards.count, 9)
                XCTAssertTrue(cards.allSatisfy { $0.actionCommand == nil && $0.isFocusable && !$0.isActionable })
                XCTAssertTrue(model.visibleDescriptors.allSatisfy { $0.visibleFrame != nil })
                XCTAssertTrue(model.visibleDescriptors.allSatisfy {
                    guard let frame = $0.visibleFrame else { return false }
                    return model.panelFrame.contains(frame)
                })
            }
        }
        XCTAssertEqual(branchCount, 18)
        XCTAssertEqual(skillCount, 54)
        XCTAssertEqual(cardCount, 54)
        XCTAssertEqual(allCardIDs.count, 54)
    }

    func testAuthorityCopyAndTutorialAreExactAndBounded() throws {
        for phase in RPGAuthorityPresentationPhase.allCases {
            let presentation = rpgAuthorityPhasePresentation(phase)
            XCTAssertFalse(presentation.visibleTitle.isEmpty)
            XCTAssertFalse(presentation.visibleHelp.isEmpty)
            XCTAssertEqual(presentation.voiceOverAnnouncement,
                           "\(presentation.visibleTitle). \(presentation.visibleHelp)")
            let forbidden = ["owner checkpoint", "request-zero checkpoint", "reviewed v6 coordinator", "v5 fallback"]
            XCTAssertTrue(forbidden.allSatisfy { !presentation.visibleHelp.lowercased().contains($0) })
        }
        var tutorial = RPGTutorialState(seenVersion: 0, page: 1)
        tutorial = rpgTutorialAfter(.tutorialNext, state: tutorial)
        XCTAssertEqual(tutorial.page, 2)
        tutorial = rpgTutorialAfter(.tutorialFinish, state: tutorial)
        XCTAssertEqual(tutorial.seenVersion, 1)
        XCTAssertNil(tutorial.page)
        XCTAssertEqual(rpgClampedScrollOffset(contentHeight: 100, viewportHeight: 40, requested: 99), 60)
        XCTAssertEqual(rpgClampedScrollOffset(contentHeight: .nan, viewportHeight: 40, requested: 1), 0)
    }

    func testCompactStatusWrappingSplitsUnbrokenASCIIAndUnicodeWithSharedMeasurement() throws {
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for detail in [String(repeating: "W", count: 200),
                       String(repeating: "界", count: 80)] {
            let status = try XCTUnwrap(RPGStatusPresentation(
                identity: .local(counter: 1, operationTag: .usePreparedAction),
                operation: .usePreparedAction, target: .character,
                kind: .cooldown, rawDetail: detail,
                persistence: .localUntilReplaced, acknowledgement: .never))
            XCTAssertLessThanOrEqual(status.text.utf8.count, 160)
            let authority = try RPGAuthorityPresentation(
                validating: .localReady, status: status)
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: state, authority: authority,
                viewportWidth: 360, viewportHeight: 224, tab: .skills))
            let descriptor = try XCTUnwrap(model.descriptors.first {
                $0.id.rawValue == "status:current"
            })
            XCTAssertEqual(descriptor.frame.height, 18)
            XCTAssertNotNil(model.layout.contextualDetailFrame)
            XCTAssertEqual(model.contextualDetailLines,
                rpgWrappedPresentationLines(model.authority.visibleHelp,
                    width: try XCTUnwrap(model.layout.contextualDetailFrame).width - 8))
            let focused = rpgBuildScreenModel(RPGScreenModelInput(
                state: state, authority: authority,
                viewportWidth: 360, viewportHeight: 224, tab: .skills,
                focusedID: RPGUIElementID(rawValue: "status:current")!))
            let detailFrame = try XCTUnwrap(focused.layout.contextualDetailFrame)
            let lines = rpgWrappedPresentationLines(
                status.accessibilityText, width: detailFrame.width - 8)
            XCTAssertGreaterThan(lines.count, 1)
            XCTAssertEqual(focused.contextualDetailLines, lines)
            XCTAssertEqual(detailFrame.height,
                min(68, max(18, Double(lines.count) * 12 + 4)))
            XCTAssertGreaterThanOrEqual(focused.contentFrame.height, 20)
        }
    }

    func testSharedPresentationWrappingConservativelyBoundsInstalledMonospacedMetrics() {
        let samples = [
            String(repeating: "W", count: 160),
            String(repeating: "界", count: 53),
            String(repeating: "W界🙂", count: 20),
            String(repeating: "🙂", count: 40),
        ]
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        for viewport in RPGUIHarnessViewport.allCases {
            let panelWidth = min(700, viewport.size.0 - 12)
            for allocatedWidth in [panelWidth - 20, panelWidth - 42] {
                for sample in samples {
                    XCTAssertLessThanOrEqual(sample.utf8.count, 160)
                    let lines = rpgWrappedPresentationLines(
                        sample, width: allocatedWidth)
                    XCTAssertEqual(lines.joined(), sample)
                    XCTAssertFalse(lines.isEmpty)
                    for line in lines {
                        let actualWidth = (line as NSString)
                            .size(withAttributes: attributes).width
                        XCTAssertLessThanOrEqual(actualWidth, allocatedWidth,
                            "\(viewport.rawValue) \(sample.utf8.count) bytes: \(line)")
                    }
                }
            }
        }
    }

    func testFixedBandContextMatrixAndCommandsRemainDisjointAndStable() throws {
        var state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        state = repairRPGCharacterState(state)
        let local = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, viewportWidth: 700, viewportHeight: 420, tab: .skills))
        let operationID = try XCTUnwrap(local.descriptors.first {
            $0.actionCommand?.requiresAuthority == true
        }?.id)
        let status = try XCTUnwrap(RPGStatusPresentation(
            identity: .local(counter: 7, operationTag: .saveQuickSlots),
            operation: .saveQuickSlots, target: .character,
            kind: .persistenceFailure, rawDetail: "RPG quick slots",
            persistence: .localUntilReplaced, acknowledgement: .never))
        let focuses: [RPGUIElementID?] = [
            nil,
            RPGUIElementID(rawValue: "status:current")!,
            RPGUIElementID(rawValue: "authority:phase")!,
            operationID,
        ]
        for phase in RPGAuthorityPresentationPhase.allCases {
            let request = phase == .localReady || phase == .unavailable
                ? nil : String(repeating: "a", count: 64)
            let authority = try RPGAuthorityPresentation(
                validating: phase, requestIdentity: request)
            for maybeStatus in [nil, status] as [RPGStatusPresentation?] {
                for focus in focuses {
                    for viewport in RPGUIHarnessViewport.allCases {
                        let size = viewport.size
                        let model = rpgBuildScreenModel(RPGScreenModelInput(
                            state: state, localPreferenceStatus: maybeStatus,
                            authority: authority, viewportWidth: size.0,
                            viewportHeight: size.1, tab: .skills, focusedID: focus))
                        let layout = model.layout
                        let frames = [layout.headerFrame, layout.authorityChipFrame] +
                            [layout.statusChipFrame, layout.contextualDetailFrame].compactMap { $0 } +
                            [layout.stepOrTabFrame, layout.contentFrame,
                             layout.commandFrame, layout.footerHelpFrame]
                        XCTAssertTrue(frames.allSatisfy(layout.panelFrame.contains))
                        for left in frames.indices {
                            for right in frames.indices where right > left {
                                let a = frames[left], b = frames[right]
                                let overlaps = a.x < b.maxX && b.x < a.maxX &&
                                    a.y < b.maxY && b.y < a.maxY
                                XCTAssertFalse(overlaps,
                                    "\(phase.rawValue) \(viewport.rawValue) \(left),\(right)")
                            }
                        }
                        XCTAssertEqual(layout.headerFrame.height, 24)
                        XCTAssertEqual(layout.authorityChipFrame.height, 18)
                        XCTAssertEqual(layout.statusChipFrame?.height,
                                       maybeStatus == nil ? nil : 18)
                        XCTAssertEqual(layout.stepOrTabFrame.height, 20)
                        XCTAssertEqual(layout.commandFrame.height, 26)
                        XCTAssertEqual(layout.footerHelpFrame.height, 18)
                        XCTAssertGreaterThanOrEqual(layout.contentFrame.height, 20)
                        let expectedDetail: String? = {
                            if focus?.rawValue == "status:current", let maybeStatus {
                                return maybeStatus.accessibilityText
                            }
                            if focus?.rawValue == "status:current", maybeStatus == nil {
                                return rpgAuthorityPhasePresentation(phase).visibleHelp
                            }
                            if focus == operationID, phase != .localReady {
                                return rpgAuthorityPhasePresentation(phase).visibleHelp
                            }
                            if focus?.rawValue == "authority:phase" {
                                return rpgAuthorityPhasePresentation(phase).visibleHelp
                            }
                            if focus == nil {
                                return rpgAuthorityPhasePresentation(phase).visibleHelp
                            }
                            return nil
                        }()
                        XCTAssertEqual(layout.contextualDetailFrame != nil,
                                       expectedDetail != nil)
                        if let expectedDetail, let frame = layout.contextualDetailFrame {
                            let expectedLines = rpgWrappedPresentationLines(
                                expectedDetail, width: frame.width - 8)
                            XCTAssertEqual(model.contextualDetailLines, expectedLines)
                            let chipHeights = 18.0 + (maybeStatus == nil ? 0 : 18)
                            let cap = min(72, layout.panelFrame.height - 24 - chipHeights -
                                20 - 26 - 18 - 20)
                            XCTAssertEqual(frame.height,
                                min(cap, max(18, Double(expectedLines.count) * 12 + 4)))
                        }
                    }
                }
            }
        }
        let compactReady = try XCTUnwrap(rpgScreenLayout(
            viewportWidth: 360, viewportHeight: 224,
            hasStatus: false, contextualDetailText: nil))
        XCTAssertEqual(compactReady.contentFrame.height, 106)

        var review = rpgInitialCreationSession()
        review.step = .review
        let first = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: review, viewportWidth: 360, viewportHeight: 224,
            scrollOffset: 0))
        let scrolled = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: review, viewportWidth: 360, viewportHeight: 224,
            scrollOffset: 10_000))
        let fixedIDs = Set(first.descriptors.filter { $0.layoutRegion == .fixed }.map(\.id))
        for id in fixedIDs {
            XCTAssertEqual(first.descriptors.first { $0.id == id }?.frame,
                           scrolled.descriptors.first { $0.id == id }?.frame)
        }
        let create = try XCTUnwrap(first.descriptors.first {
            $0.id.rawValue == "creation:review:operation:create"
        })
        XCTAssertEqual(create.layoutRegion, .fixed)
        XCTAssertNotNil(create.visibleFrame)
    }

    func testAnchoredScrollOffsetPreservesRepresentableFrameAndClampsNearestEdge() {
        let old = RPGLogicalRect(x: 0, y: 40, width: 20, height: 20)
        let shifted = RPGLogicalRect(x: 0, y: 104, width: 20, height: 20)
        XCTAssertEqual(rpgAnchoredScrollOffset(
            previousFocusedFrame: old, newUnscrolledFocusedFrame: shifted,
            currentOffset: 40, contentHeight: 300, viewportHeight: 100), 64)
        XCTAssertEqual(shifted.y - 64, old.y)

        let top = RPGLogicalRect(x: 0, y: -12, width: 20, height: 20)
        XCTAssertEqual(rpgAnchoredScrollOffset(
            previousFocusedFrame: old, newUnscrolledFocusedFrame: top,
            currentOffset: 0, contentHeight: 300, viewportHeight: 100), 0)
        let bottom = RPGLogicalRect(x: 0, y: 294, width: 20, height: 20)
        XCTAssertEqual(rpgAnchoredScrollOffset(
            previousFocusedFrame: old, newUnscrolledFocusedFrame: bottom,
            currentOffset: 190, contentHeight: 300, viewportHeight: 100), 200)
        XCTAssertEqual(rpgAnchoredScrollOffset(
            previousFocusedFrame: nil, newUnscrolledFocusedFrame: shifted,
            currentOffset: 999, contentHeight: 300, viewportHeight: 100), 200)
    }

    func testEveryEnabledActionPublishesCompleteContainedVisibleLinesAcrossRegistryStates() throws {
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("visual-fit")
        var models: [RPGScreenModel] = []
        for viewport in RPGUIHarnessViewport.allCases {
            let size = viewport.size
            for path in RPG_PATH_DEFINITIONS {
                var creation = rpgInitialCreationSession()
                creation = try rpgReduceCreationSession(
                    creation, command: .choosePath(path.id)).get()
                for step in RPGCreationStep.allCases {
                    var atStep = creation
                    atStep.step = step
                    models.append(rpgBuildScreenModel(RPGScreenModelInput(
                        state: .uncreated(), creation: atStep,
                        viewportWidth: size.0, viewportHeight: size.1)))
                }
                for branchID in path.branchIDs {
                    let state = try XCTUnwrap(rpgScreenFixture(
                        pathID: path.id, branchID: branchID))
                    for tab in RPGCharacterTab.allCases {
                        models.append(rpgBuildScreenModel(RPGScreenModelInput(
                            state: state, localPreferenceScope: scope,
                            localPreferenceRevision: 1, localPreferenceWritable: true,
                            viewportWidth: size.0, viewportHeight: size.1, tab: tab)))
                    }
                }
            }
            let tutorialState = try XCTUnwrap(rpgScreenFixture(
                pathID: "warden", branchID: "warden_guardian"))
            for page in 1...4 {
                models.append(rpgBuildScreenModel(RPGScreenModelInput(
                    state: tutorialState,
                    tutorial: RPGTutorialState(seenVersion: 0, page: page),
                    viewportWidth: size.0, viewportHeight: size.1)))
            }
        }

        var actionCount = 0
        for model in models {
            for value in model.descriptors where value.isActionable {
                actionCount += 1
                // The class carousel (whose chevrons were the only actionable descriptors with
                // empty visual lines) was retired; every actionable descriptor now carries text.
                XCTAssertFalse(value.visualLines.isEmpty, value.id.rawValue)
                XCTAssertTrue(rpgDescriptorVisualLinesFit(
                    frame: value.frame, iconAssetID: value.iconAssetID,
                    visualLines: value.visualLines), value.id.rawValue)
                if let visible = value.visibleFrame {
                    XCTAssertEqual(visible, value.frame, value.id.rawValue)
                    let region = value.layoutRegion == .fixed
                        ? model.panelFrame : model.contentFrame
                    XCTAssertTrue(region.contains(visible), value.id.rawValue)
                    XCTAssertTrue(model.visibleDescriptors.contains { $0.id == value.id })
                }
            }
        }
        XCTAssertGreaterThan(actionCount, 1_000)
    }

    func testAuthorityDetailUsesExactLegalCommandAndStatusPrecedence() throws {
        var state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        // stagger_chain is off-sub-class (vanguard) node 2; rank 4 is reachable at level 20 (gate 18),
        // but its rank 5 needs level 22, so its rank-up operation is present-but-illegal (command nil).
        state.skillRanks["stagger_chain"] = 4
        state = repairRPGCharacterState(state)
        let ready = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, viewportWidth: 700, viewportHeight: 420, tab: .skills))
        let legalAuthorityOperation = try XCTUnwrap(ready.descriptors.first {
            $0.actionCommand?.requiresAuthority == true && $0.enabled
        })
        let illegalOperation = try XCTUnwrap(ready.descriptors.first {
            $0.id.rawValue.contains(":operation:rank-up") && $0.actionCommand == nil
        })
        let pending = try RPGAuthorityPresentation(
            validating: .awaitingHost,
            requestIdentity: String(repeating: "a", count: 64))
        let authorityHelp = rpgAuthorityPhasePresentation(.awaitingHost).visibleHelp

        let legal = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, authority: pending, viewportWidth: 700, viewportHeight: 420,
            tab: .skills, focusedID: legalAuthorityOperation.id))
        XCTAssertEqual(legal.contextualDetailLines,
            rpgWrappedPresentationLines(authorityHelp,
                width: try XCTUnwrap(legal.layout.contextualDetailFrame).width - 8))
        XCTAssertEqual(legal.descriptors.first {
            $0.id == legalAuthorityOperation.id
        }?.actionCommand, legalAuthorityOperation.actionCommand)
        XCTAssertFalse(try XCTUnwrap(legal.descriptors.first {
            $0.id == legalAuthorityOperation.id
        }).enabled)

        let illegal = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, authority: pending, viewportWidth: 700, viewportHeight: 420,
            tab: .skills, focusedID: illegalOperation.id))
        XCTAssertNil(illegal.layout.contextualDetailFrame)

        let status = try XCTUnwrap(RPGStatusPresentation(
            identity: .local(counter: 8, operationTag: .saveQuickSlots),
            operation: .saveQuickSlots, target: .character,
            kind: .persistenceFailure, rawDetail: "local write failed",
            persistence: .localUntilReplaced, acknowledgement: .never))
        let statusFocused = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, localPreferenceStatus: status, authority: pending,
            viewportWidth: 700, viewportHeight: 420, tab: .skills,
            focusedID: RPGUIElementID(rawValue: "status:current")!))
        XCTAssertEqual(statusFocused.contextualDetailLines,
            rpgWrappedPresentationLines(status.accessibilityText,
                width: try XCTUnwrap(statusFocused.layout.contextualDetailFrame).width - 8))
        let operationFocused = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, localPreferenceStatus: status, authority: pending,
            viewportWidth: 700, viewportHeight: 420, tab: .skills,
            focusedID: legalAuthorityOperation.id))
        XCTAssertEqual(operationFocused.contextualDetailLines,
            rpgWrappedPresentationLines(authorityHelp,
                width: try XCTUnwrap(operationFocused.layout.contextualDetailFrame).width - 8))

        let close = RPGUIElementID(rawValue: "sheet:operation:close")!
        let fixedClose = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, authority: pending, viewportWidth: 700, viewportHeight: 420,
            tab: .skills, focusedID: close))
        XCTAssertNil(fixedClose.layout.contextualDetailFrame)
        var creation = rpgInitialCreationSession()
        creation.step = .review
        let fixedBackID = RPGUIElementID(rawValue: "creation:review:operation:back")!
        let fixedBack = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), authority: pending, creation: creation,
            viewportWidth: 700, viewportHeight: 420, focusedID: fixedBackID))
        XCTAssertNil(fixedBack.layout.contextualDetailFrame)
        let tutorialID = RPGUIElementID.operation(
            owner: .tutorial(1, pathID: state.pathID,
                branchID: state.specializationBranchID), name: "next")
        let tutorial = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, authority: pending,
            tutorial: RPGTutorialState(seenVersion: 0, page: 1),
            viewportWidth: 700, viewportHeight: 420,
            focusedID: tutorialID))
        XCTAssertNil(tutorial.layout.contextualDetailFrame)
    }

    func testResolvedDefaultAuthorityFocusBuildsFinalHelpAndPreservesCompactSurfaces() throws {
        let created = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for phase in RPGAuthorityPresentationPhase.allCases {
            let request = phase == .localReady || phase == .unavailable
                ? nil : String(repeating: "b", count: 64)
            let authority = try RPGAuthorityPresentation(
                validating: phase, requestIdentity: request)
            for viewport in RPGUIHarnessViewport.allCases {
                let size = viewport.size
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: created, authority: authority,
                    viewportWidth: size.0, viewportHeight: size.1))
                XCTAssertEqual(model.focusedID,
                    RPGUIElementID(rawValue: "authority:phase")!)
                let frame = try XCTUnwrap(model.layout.contextualDetailFrame)
                XCTAssertEqual(model.contextualDetailLines,
                    rpgWrappedPresentationLines(model.authority.visibleHelp,
                        width: frame.width - 8))
                XCTAssertGreaterThanOrEqual(model.contentFrame.height, 20)
            }
        }

        // Build a session that has advanced far enough for each step to render real content:
        // the path grid, then the sub-class grid, then the starting-skill pool, then review.
        var creation = rpgInitialCreationSession()
        creation = try rpgReduceCreationSession(creation, command: .choosePath("warden")).get()
        creation = try rpgReduceCreationSession(creation, command: .chooseBranch("warden_guardian")).get()
        for step in RPGCreationStep.allCases {
            creation.step = step
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: creation,
                viewportWidth: 360, viewportHeight: 224))
            switch step {
            case .path:
                // The Path step never shows a contextual-detail band.
                XCTAssertNil(model.layout.contextualDetailFrame, step.rawValue)
                XCTAssertTrue(model.contextualDetailLines.isEmpty, step.rawValue)
            case .branch:
                // C10: Step 2 shows "<Path> · choose a sub-class".
                XCTAssertNotNil(model.layout.contextualDetailFrame, step.rawValue)
                XCTAssertFalse(model.contextualDetailLines.isEmpty, step.rawValue)
            default:
                break // .skills / .review detail band is focus-dependent, not asserted here.
            }
            XCTAssertTrue(model.visibleDescriptors.contains {
                $0.layoutRegion == .scrollingContent &&
                    model.contentFrame.contains($0.frame)
            }, step.rawValue)
            XCTAssertTrue(model.descriptors.filter {
                $0.layoutRegion == .fixed && $0.role == .button
            }.allSatisfy { model.layout.commandFrame.contains($0.frame) })
            switch step {
            case .path:
                XCTAssertNotNil(model.descriptors.first {
                    $0.id == .path("warden") && $0.visibleFrame != nil
                }, step.rawValue)
            case .branch:
                XCTAssertNotNil(model.descriptors.first {
                    $0.id == .branch("warden_guardian") && $0.visibleFrame != nil
                }, step.rawValue)
            case .skills:
                // The starting-skill pool scrolls at the compact viewport, so a card need not be
                // fully visible; it must be present and actionable.
                XCTAssertNotNil(model.descriptors.first {
                    $0.id == .skill("guard_stance") && $0.isActionable
                }, step.rawValue)
            case .review:
                XCTAssertNotNil(model.descriptors.first {
                    $0.id.rawValue.hasPrefix("creation:review:row:")
                }, step.rawValue)
            }
        }
        for page in 1...4 {
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: created,
                tutorial: RPGTutorialState(seenVersion: 0, page: page),
                viewportWidth: 360, viewportHeight: 224))
            let tutorial = try XCTUnwrap(model.descriptors.first {
                $0.id.rawValue.hasPrefix("tutorial:") &&
                    !$0.id.rawValue.contains(":operation:")
            })
            XCTAssertNotNil(tutorial.visibleFrame)
            XCTAssertTrue(model.contentFrame.contains(tutorial.frame))
            XCTAssertTrue(rpgDescriptorVisualLinesFit(
                frame: tutorial.frame, iconAssetID: tutorial.iconAssetID,
                visualLines: tutorial.visualLines))
        }
    }

    func testStarterKitPrebootstrapNamesAreTheLiveRegistryCanonicalNames() throws {
        let reachableIDs = Set(try RPG_PATH_DEFINITIONS.flatMap { path -> [String] in
            try XCTUnwrap(rpgStarterKit(pathID: path.id)).map(\.itemID)
        })
        XCTAssertEqual(reachableIDs,
            Set(RPG_STARTER_KIT_ITEM_REGISTRATION_DISPLAY_NAMES.keys))
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        for id in reachableIDs.sorted() {
            let expected = try XCTUnwrap(rpgStarterKitItemRegistrationDisplayName(id))
            let registeredID = try XCTUnwrap(iidOpt(id))
            XCTAssertEqual(itemDef(registeredID).displayName, expected, id)
        }
        XCTAssertNil(rpgStarterKitItemRegistrationDisplayName("unknown_item"))
    }

    func testEveryAuthorityLastGlyphLineFitsModelFrameAtEveryViewport() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for phase in RPGAuthorityPresentationPhase.allCases {
            let request = phase == .localReady || phase == .unavailable
                ? nil : String(repeating: "a", count: 64)
            let authority = try RPGAuthorityPresentation(
                validating: phase, requestIdentity: request)
            for viewport in RPGUIHarnessViewport.allCases {
                let size = viewport.size
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: state, authority: authority,
                    viewportWidth: size.0, viewportHeight: size.1,
                    focusedID: RPGUIElementID(rawValue: "authority:phase")!))
                let descriptor = try XCTUnwrap(model.descriptors.first {
                    $0.id.rawValue == "authority:phase"
                })
                XCTAssertEqual(descriptor.frame.height, 18)
                let detailFrame = try XCTUnwrap(model.layout.contextualDetailFrame)
                let lines = rpgWrappedPresentationLines(
                    model.authority.visibleHelp, width: detailFrame.width - 8)
                let lastLine = try XCTUnwrap(lines.last)
                let lastOriginY = detailFrame.y + 2 +
                    Double(lines.count - 1) * 12
                let glyphHeight = (lastLine as NSString)
                    .size(withAttributes: attributes).height
                XCTAssertLessThanOrEqual(lastOriginY + glyphHeight +
                    RPG_AUTHORITY_FOCUS_STROKE_CLEARANCE,
                                         detailFrame.maxY,
                    "\(phase.rawValue) \(viewport.rawValue)")
                XCTAssertLessThanOrEqual(detailFrame.height, 72)
                XCTAssertLessThanOrEqual(detailFrame.maxY,
                                         model.layout.stepOrTabFrame.y)
                let tabs = model.descriptors.filter { $0.role == .tab }
                XCTAssertFalse(tabs.isEmpty)
                XCTAssertTrue(tabs.allSatisfy {
                    $0.layoutRegion == .fixed &&
                        model.layout.stepOrTabFrame.contains($0.frame)
                })
            }
        }
    }

    func testAuthorityIdentityValidationAndExactUnavailableCopy() throws {
        XCTAssertThrowsError(try RPGAuthorityPresentation(validating: .awaitingHost))
        XCTAssertThrowsError(try RPGAuthorityPresentation(validating: .localReady,
                                                           requestIdentity: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try RPGAuthorityPresentation(validating: .awaitingHost,
                                                           requestIdentity: String(repeating: "A", count: 64)))
        let pending = try RPGAuthorityPresentation(validating: .awaitingHost,
                                                   requestIdentity: String(repeating: "a", count: 64))
        XCTAssertEqual(pending.requestIdentity, String(repeating: "a", count: 64))
        XCTAssertEqual(rpgAuthorityPhasePresentation(.unavailable).visibleHelp,
                       "Character changes are unavailable in this LAN session. Quick-slot editing requires a compatible host session.")
    }

    /// D1: the Review step's three command-row buttons (Reject / Back / Accept) must never
    /// overlap -- an earlier 28px Reject/Back overlap routed discard-clicks to Reject under
    /// reverse-order hit-testing. Checked across every installed viewport.
    func testReviewCommandRowButtonsNeverOverlap() throws {
        var session = rpgInitialCreationSession()
        session = try rpgReduceCreationSession(session, command: .choosePath("warden")).get()
        session = try rpgReduceCreationSession(session, command: .chooseBranch("warden_guardian")).get()
        session = try rpgReduceCreationSession(session, command: .confirmStartingSkills).get()
        let reviewID = RPGUIElementID(rawValue: "creation:review")!
        let ids = [
            RPGUIElementID.operation(owner: reviewID, name: "create"),
            RPGUIElementID.operation(owner: reviewID, name: "reject"),
            RPGUIElementID(rawValue: "creation:review:operation:back")!,
        ]
        for viewport in RPGUIHarnessViewport.allCases {
            let size = viewport.size
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: session,
                viewportWidth: size.0, viewportHeight: size.1))
            let frames = try ids.map { id -> RPGLogicalRect in
                try XCTUnwrap(model.descriptors.first { $0.id == id }?.frame, "\(id.rawValue)")
            }
            for left in frames.indices {
                for right in frames.indices where left < right {
                    let a = frames[left], b = frames[right]
                    let overlaps = a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
                    XCTAssertFalse(overlaps,
                        "\(viewport.rawValue): review command buttons \(ids[left].rawValue) and \(ids[right].rawValue) overlap")
                }
            }
        }
    }

    func testCreationReviewAuthorityCaveatsAreExactForEveryPhase() throws {
        var session = rpgInitialCreationSession()
        session = try rpgReduceCreationSession(session, command: .choosePath("warden")).get()
        session = try rpgReduceCreationSession(session,
            command: .chooseBranch("warden_guardian")).get()
        session.step = .review
        for phase in RPGAuthorityPresentationPhase.allCases {
            let request = phase == .localReady || phase == .unavailable
                ? nil : String(repeating: "a", count: 64)
            let authority = try RPGAuthorityPresentation(
                validating: phase, requestIdentity: request)
            let review = try XCTUnwrap(rpgCreationReviewProjection(
                session: session, chordBindings: rpgDefaultChordBindings(),
                authority: authority, inventoryCapacitySummary: "Fits."))
            switch phase {
            case .localReady:
                XCTAssertEqual(review.authorityCaveat,
                    "Create saves this character and starter kit to this world.")
            case .unavailable:
                XCTAssertEqual(review.authorityCaveat,
                    "This LAN host does not support character creation. Your draft will not be submitted.")
            default:
                XCTAssertEqual(review.authorityCaveat,
                               rpgAuthorityPhasePresentation(phase).visibleHelp)
            }
        }
    }

    @MainActor
    func testSemanticCaptureIsDomainBoundAndRevalidated() throws {
        let state = try XCTUnwrap(rpgScreenFixture(pathID: "warden", branchID: "warden_guardian"))
        let model = rpgBuildScreenModel(RPGScreenModelInput(state: state,
            viewportWidth: 700, viewportHeight: 420, tab: .skills))
        let operation = try XCTUnwrap(model.descriptors.first { $0.actionCommand == .selectTab(.actives) })
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("world-1")
        let snapshot = try XCTUnwrap(RPGSemanticInputSnapshot(localPreferenceScope: scope,
            localPreferenceRevision: 2, localPreferenceWritable: true, rulesGeneration: 3,
            ownerRevision: 4, inventoryDigest: String(repeating: "1", count: 64),
            equipmentFocusDigest: String(repeating: "2", count: 64),
            authorityRevision: UInt64(state.authorityRevision), authorityPhase: .localReady,
            authorityRequestIdentity: nil, operationExpectedState: "guard_stance:rank:1"))
        let initialBoundary = RPGSemanticActivationBoundary()
        let capture = try XCTUnwrap(initialBoundary.capture(screenInstanceID: 1,
            semanticRevision: 9, descriptor: operation, input: snapshot))
        XCTAssertTrue(rpgRevalidateSemanticActivation(capture, screenInstanceID: 1,
            semanticRevision: 9, descriptor: operation, input: snapshot))
        let stale = try XCTUnwrap(RPGSemanticInputSnapshot(localPreferenceScope: scope,
            localPreferenceRevision: 3, localPreferenceWritable: true, rulesGeneration: 3,
            ownerRevision: 4, inventoryDigest: String(repeating: "1", count: 64),
            equipmentFocusDigest: String(repeating: "2", count: 64),
            authorityRevision: UInt64(state.authorityRevision), authorityPhase: .localReady,
            authorityRequestIdentity: nil, operationExpectedState: "guard_stance:rank:1"))
        XCTAssertFalse(rpgRevalidateSemanticActivation(capture, screenInstanceID: 1,
            semanticRevision: 9, descriptor: operation, input: stale))
        XCTAssertFalse(rpgRevalidateSemanticActivation(capture, screenInstanceID: 2,
            semanticRevision: 9, descriptor: operation, input: snapshot))
        for source in RPGSemanticActivationSource.allCases {
            let boundary = RPGSemanticActivationBoundary()
            let staleCapture = try XCTUnwrap(boundary.capture(screenInstanceID: 1,
                semanticRevision: 9, descriptor: operation, input: snapshot))
            XCTAssertEqual(boundary.dispatch(staleCapture, source: source, screenInstanceID: 1,
                semanticRevision: 9, descriptor: operation, input: stale),
                .staleRequiresFreshActivation)
            XCTAssertEqual(boundary.dispatch(staleCapture, source: source, screenInstanceID: 1,
                semanticRevision: 9, descriptor: operation, input: snapshot),
                .invalidOrReplayedReceipt)

            let freshCapture = try XCTUnwrap(boundary.capture(screenInstanceID: 1,
                semanticRevision: 9, descriptor: operation, input: snapshot))
            XCTAssertNotEqual(staleCapture.activationReceipt, freshCapture.activationReceipt)
            XCTAssertEqual(staleCapture.commandFingerprint, freshCapture.commandFingerprint)
            XCTAssertEqual(staleCapture.semanticInputFingerprint, freshCapture.semanticInputFingerprint)
            XCTAssertEqual(boundary.dispatch(freshCapture, source: source, screenInstanceID: 1,
                semanticRevision: 9, descriptor: operation, input: snapshot), .dispatched(serial: 1))
            XCTAssertEqual(boundary.dispatch(freshCapture, source: source, screenInstanceID: 1,
                semanticRevision: 9, descriptor: operation, input: snapshot),
                .invalidOrReplayedReceipt)
        }
    }

    @MainActor
    func testActivationReceiptFIFOHighWaterAndExhaustion() throws {
        let state = try XCTUnwrap(rpgScreenFixture(pathID: "warden", branchID: "warden_guardian"))
        let model = rpgBuildScreenModel(RPGScreenModelInput(state: state,
            viewportWidth: 700, viewportHeight: 420, tab: .skills))
        let descriptor = try XCTUnwrap(model.descriptors.first { $0.actionCommand == .selectTab(.actives) })
        let snapshot = try XCTUnwrap(RPGSemanticInputSnapshot(localPreferenceScope: nil,
            localPreferenceRevision: 0, localPreferenceWritable: false, rulesGeneration: 1,
            ownerRevision: 1, inventoryDigest: String(repeating: "1", count: 64),
            equipmentFocusDigest: String(repeating: "2", count: 64),
            authorityRevision: UInt64(state.authorityRevision), authorityPhase: .localReady,
            authorityRequestIdentity: nil, operationExpectedState: "tab:skills"))
        let boundary = RPGSemanticActivationBoundary()
        var firstCapture: RPGSemanticActivationCapture?
        for expected in 1...66 {
            let capture = try XCTUnwrap(boundary.capture(screenInstanceID: 1,
                semanticRevision: 1, descriptor: descriptor, input: snapshot))
            if expected == 1 { firstCapture = capture }
            XCTAssertEqual(boundary.dispatch(capture, source: .keyboard, screenInstanceID: 1,
                semanticRevision: 1, descriptor: descriptor, input: snapshot),
                .dispatched(serial: UInt64(expected)))
        }
        XCTAssertEqual(boundary.recentConsumedActivationReceipts.count, 64)
        XCTAssertEqual(boundary.highestConsumedActivationReceipt, 66)
        XCTAssertEqual(boundary.dispatch(try XCTUnwrap(firstCapture), source: .keyboard,
            screenInstanceID: 1, semanticRevision: 1, descriptor: descriptor, input: snapshot),
            .invalidOrReplayedReceipt)
        let unissued = try XCTUnwrap(RPGSemanticActivationCapture(activationReceipt: 67,
            screenInstanceID: 1, id: descriptor.id, semanticRevision: 1,
            commandFingerprint: rpgSemanticCommandFingerprint(try XCTUnwrap(descriptor.actionCommand)),
            semanticInputFingerprint: rpgSemanticInputFingerprint(snapshot)))
        XCTAssertEqual(boundary.dispatch(unissued, source: .mouse, screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot),
            .invalidOrReplayedReceipt)
        XCTAssertNil(RPGSemanticActivationCapture(activationReceipt: 0, screenInstanceID: 1,
            id: descriptor.id, semanticRevision: 1,
            commandFingerprint: rpgSemanticCommandFingerprint(try XCTUnwrap(descriptor.actionCommand)),
            semanticInputFingerprint: rpgSemanticInputFingerprint(snapshot)))

        let exhaustedBoundary = RPGSemanticActivationBoundary(testLastIssuedActivationReceipt: UInt64.max)
        XCTAssertNil(exhaustedBoundary.capture(screenInstanceID: 1, semanticRevision: 1,
            descriptor: descriptor, input: snapshot))
        XCTAssertTrue(exhaustedBoundary.receiptExhaustedForTesting)
        XCTAssertNil(exhaustedBoundary.capture(screenInstanceID: 1, semanticRevision: 1,
            descriptor: descriptor, input: snapshot))

        let routingExhausted = RPGSemanticActivationBoundary(testDispatchSerial: UInt64.max)
        let capture = try XCTUnwrap(routingExhausted.capture(screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot))
        XCTAssertEqual(routingExhausted.dispatch(capture, source: .accessibility, screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot), .dispatchSerialExhausted)
        XCTAssertEqual(routingExhausted.dispatch(capture, source: .accessibility, screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot), .invalidOrReplayedReceipt)

        let outOfOrder = RPGSemanticActivationBoundary()
        let older = try XCTUnwrap(outOfOrder.capture(screenInstanceID: 1, semanticRevision: 1,
            descriptor: descriptor, input: snapshot))
        let newer = try XCTUnwrap(outOfOrder.capture(screenInstanceID: 1, semanticRevision: 1,
            descriptor: descriptor, input: snapshot))
        XCTAssertEqual(outOfOrder.dispatch(newer, source: .controller, screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot), .dispatched(serial: 1))
        XCTAssertEqual(outOfOrder.dispatch(older, source: .controller, screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot), .invalidOrReplayedReceipt)

        let identityBoundary = RPGSemanticActivationBoundary()
        let alias = identityBoundary
        XCTAssertTrue(identityBoundary === alias)
        let aliasedCapture = try XCTUnwrap(identityBoundary.capture(screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot))
        XCTAssertEqual(alias.dispatch(aliasedCapture, source: .mouse, screenInstanceID: 1,
            semanticRevision: 1, descriptor: descriptor, input: snapshot), .dispatched(serial: 1))
        XCTAssertEqual(identityBoundary.dispatch(aliasedCapture, source: .accessibility,
            screenInstanceID: 1, semanticRevision: 1, descriptor: descriptor, input: snapshot),
            .invalidOrReplayedReceipt)
    }

    @MainActor
    func testCancelledActivationIsConsumedAndCannotReplayAfterCoverABA() throws {
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        let descriptor = try XCTUnwrap(rpgBuildScreenModel(RPGScreenModelInput(
            state: state, viewportWidth: 700, viewportHeight: 420, tab: .skills))
            .descriptors.first { $0.actionCommand == .selectTab(.actives) })
        let input = try XCTUnwrap(RPGSemanticInputSnapshot(
            localPreferenceScope: nil, localPreferenceRevision: 0,
            localPreferenceWritable: false, worldEntryGeneration: 1,
            rulesGeneration: 1, ownerRevision: 1,
            inventoryDigest: String(repeating: "1", count: 64),
            equipmentFocusDigest: String(repeating: "2", count: 64),
            authorityRevision: UInt64(state.authorityRevision),
            authorityPhase: .localReady, authorityRequestIdentity: nil,
            operationExpectedState: "tab:skills"))
        let boundary = RPGSemanticActivationBoundary()
        let capture = try XCTUnwrap(boundary.capture(
            screenInstanceID: 9, semanticRevision: 3,
            descriptor: descriptor, input: input))
        XCTAssertTrue(boundary.cancel(capture))
        XCTAssertFalse(boundary.cancel(capture))
        XCTAssertEqual(boundary.dispatch(capture, source: .mouse,
            screenInstanceID: 9, semanticRevision: 3,
            descriptor: descriptor, input: input), .invalidOrReplayedReceipt)
    }

    func testCreateFingerprintLengthPrefixesStartingSkillCountOrderAndIDs() {
        // The create-command fingerprint keys on pathID/branchID/startingSkillIDs (spells are
        // derived, not chosen). It count-prefixes the starting-skill list and is order- and
        // content-sensitive.
        func draft(_ skills: [String]) -> RPGCreationDraft {
            RPGCreationDraft(pathID: "arcanist", branchID: "arcanist_elementalist",
                             startingSkillIDs: skills)
        }
        let baseline = rpgSemanticCommandFingerprint(.create(draft(["spell_formula", "spark_weave"])))
        // Different content.
        XCTAssertNotEqual(baseline, rpgSemanticCommandFingerprint(.create(draft(["spell_formula", "storm_focus"]))))
        // Different order.
        XCTAssertNotEqual(baseline, rpgSemanticCommandFingerprint(.create(draft(["spark_weave", "spell_formula"]))))
        // Different count.
        XCTAssertNotEqual(baseline, rpgSemanticCommandFingerprint(.create(draft(["spell_formula"]))))
        // A different branch is a distinct create command even with the same skill list.
        XCTAssertNotEqual(baseline, rpgSemanticCommandFingerprint(.create(RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_illusionist",
            startingSkillIDs: ["spell_formula", "spark_weave"]))))
        // Stable / deterministic.
        XCTAssertEqual(baseline, rpgSemanticCommandFingerprint(.create(draft(["spell_formula", "spark_weave"]))))
    }

    func testStatusIdentityBoundsAndIndependentSanitization() throws {
        XCTAssertThrowsError(try RPGDurableNoticeIdentity(notificationID: "ABC", payloadDigest: "def"))
        let identity = try RPGDurableNoticeIdentity(notificationID: String(repeating: "a", count: 64),
                                                    payloadDigest: String(repeating: "b", count: 64))
        let payload = try RPGDurableNoticePayload(identity: identity, status: .rejected,
            reason: "bad\nreason\u{202e}", message: "message")
        XCTAssertEqual(payload.status, .rejected)
        let status = try XCTUnwrap(RPGStatusPresentation(identity: .durable(identity, status: .rejected),
            operation: .saveQuickSlots, target: .character, kind: .rejection,
            rawDetail: "bad\nreason\u{202e}   detail", persistence: .durableInboxPendingRender,
            acknowledgement: .afterCommittedModelRevision(1)))
        XCTAssertEqual(status.text, "Rejected: bad reason detail")
        XCTAssertLessThanOrEqual(status.text.utf8.count, 160)
        XCTAssertLessThanOrEqual(status.accessibilityText.utf8.count, 512)
        XCTAssertNil(RPGStatusPresentation(identity: .durable(identity, status: .rejected), operation: .useQuickSlot(9),
            target: .character, kind: .rejection, rawDetail: "bad slot",
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertNil(RPGStatusPresentation(identity: .durable(identity, status: .rejected), operation: .saveQuickSlots,
            target: .skill(String(repeating: "x", count: 65)), kind: .rejection, rawDetail: "bad target",
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertEqual(rpgSanitizeStatusText("a\u{200b}b\u{2060}c", byteLimit: 160), "abc")
        XCTAssertLessThanOrEqual(rpgSanitizeStatusText(String(repeating: "z", count: 100_000),
                                                       byteLimit: 160).utf8.count, 160)
    }

    func testStatusLifecycleOperationTargetAndAuthorityTupleFailClosed() throws {
        let durable = try RPGDurableNoticeIdentity(
            notificationID: String(repeating: "d", count: 64),
            payloadDigest: String(repeating: "e", count: 64))
        func build(identity: RPGStatusIdentity, operation: RPGStatusOperation = .usePreparedAction,
                   target: RPGStatusTarget = .character,
                   kind: RPGStatusKind = .rejection,
                   persistence: RPGStatusPersistence,
                   acknowledgement: RPGStatusAcknowledgementEligibility) -> RPGStatusPresentation? {
            RPGStatusPresentation(identity: identity, operation: operation, target: target,
                kind: kind, rawDetail: "Closed fixture", persistence: persistence,
                acknowledgement: acknowledgement)
        }
        XCTAssertNil(build(identity: .local(counter: 1, operationTag: .usePreparedAction),
            operation: .useQuickSlot(1), target: .skill("interpose"),
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertNil(build(identity: .local(counter: 1, operationTag: .saveQuickSlots),
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertNil(build(identity: .local(counter: 1, operationTag: .usePreparedAction),
            persistence: .durableInboxPendingRender,
            acknowledgement: .afterCommittedModelRevision(1)))
        XCTAssertNil(build(identity: .durable(durable, status: .rejected),
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertNil(build(identity: .durable(durable, status: .rejected),
            persistence: .durableInboxPendingRender, acknowledgement: .never))
        XCTAssertNil(build(identity: .durable(durable, status: .rejected),
            persistence: .durableInboxPendingRender,
            acknowledgement: .afterCommittedModelRevision(0)))
        XCTAssertNil(build(identity: .durable(durable, status: .rejected),
            persistence: .durableInboxAcknowledged,
            acknowledgement: .afterCommittedModelRevision(1)))
        XCTAssertNil(build(identity: .authorityPhase(
            requestFingerprint: String(repeating: "a", count: 64), phase: .awaitingHost),
            persistence: .localUntilReplaced, acknowledgement: .never))

        let fingerprint = String(repeating: "a", count: 64)
        let phaseStatus = try XCTUnwrap(build(identity: .authorityPhase(
            requestFingerprint: fingerprint, phase: .awaitingHost),
            kind: .pending,
            persistence: .authorityPhase, acknowledgement: .never))
        XCTAssertNoThrow(try RPGAuthorityPresentation(
            validating: .awaitingHost, requestIdentity: fingerprint, status: phaseStatus))
        XCTAssertThrowsError(try RPGAuthorityPresentation(
            validating: .awaitingHost, requestIdentity: String(repeating: "b", count: 64),
            status: phaseStatus))
        XCTAssertThrowsError(try RPGAuthorityPresentation(
            validating: .reconnecting, requestIdentity: fingerprint, status: phaseStatus))

        let exactOperations: [(RPGStatusOperation, RPGStatusTarget)] = [
            (.sheet(.rankUp(skillID: "interpose")), .skill("interpose")),
            (.sheet(.prepareSkill("interpose")), .skill("interpose")),
            (.sheet(.unprepareSkill("interpose")), .skill("interpose")),
            (.sheet(.selectSkill("interpose")), .skill("interpose")),
            (.sheet(.prepareSpell("ignite")), .spell("ignite")),
            (.sheet(.unprepareSpell("ignite")), .spell("ignite")),
            (.sheet(.selectSpell("ignite")), .spell("ignite")),
        ]
        for (operation, target) in exactOperations {
            let tag: RPGStatusOperationTag
            switch operation {
            case .sheet(.rankUp): tag = .rankUp
            case .sheet(.prepareSkill): tag = .prepareSkill
            case .sheet(.unprepareSkill): tag = .unprepareSkill
            case .sheet(.selectSkill): tag = .selectSkill
            case .sheet(.prepareSpell): tag = .prepareSpell
            case .sheet(.unprepareSpell): tag = .unprepareSpell
            case .sheet(.selectSpell): tag = .selectSpell
            default: XCTFail("Unexpected operation"); continue
            }
            XCTAssertNotNil(build(identity: .local(counter: 2, operationTag: tag),
                operation: operation, target: target,
                persistence: .localUntilReplaced, acknowledgement: .never))
        }
        XCTAssertNil(build(identity: .local(counter: 2, operationTag: .rankUp),
            operation: .sheet(.rankUp(skillID: "interpose")), target: .skill("heavy_cut"),
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertNil(build(identity: .local(counter: 2, operationTag: .prepareSpell),
            operation: .sheet(.prepareSpell("ignite")), target: .skill("ignite"),
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertNil(build(identity: .durable(durable, status: .accepted), kind: .rejection,
            persistence: .durableInboxPendingRender,
            acknowledgement: .afterCommittedModelRevision(1)))
        XCTAssertNil(build(identity: .durable(durable, status: .rejected), kind: .cooldown,
            persistence: .durableInboxPendingRender,
            acknowledgement: .afterCommittedModelRevision(1)))
        XCTAssertNil(build(identity: .authorityPhase(
            requestFingerprint: fingerprint, phase: .awaitingHost), kind: .success,
            persistence: .authorityPhase, acknowledgement: .never))
        XCTAssertNil(build(identity: .authorityPhase(
            requestFingerprint: fingerprint, phase: .localReady), kind: .pending,
            persistence: .authorityPhase, acknowledgement: .never))
    }

    func testLocalPersistenceStatusAtomicallyPrecedesAndRevealsAuthorityStatus() throws {
        let fingerprint = String(repeating: "a", count: 64)
        let authorityStatus = try XCTUnwrap(RPGStatusPresentation(
            identity: .authorityPhase(requestFingerprint: fingerprint,
                                      phase: .awaitingHost),
            operation: .saveQuickSlots, target: .character, kind: .pending,
            rawDetail: "Host decision", persistence: .authorityPhase,
            acknowledgement: .never))
        let authority = try RPGAuthorityPresentation(
            validating: .awaitingHost, requestIdentity: fingerprint,
            status: authorityStatus)
        let localStatus = try XCTUnwrap(RPGStatusPresentation(
            identity: .local(counter: 9, operationTag: .saveQuickSlots),
            operation: .saveQuickSlots, target: .character,
            kind: .persistenceFailure, rawDetail: "Local storage write",
            persistence: .localUntilReplaced, acknowledgement: .never))
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        let localModel = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, localPreferenceStatus: localStatus,
            authority: authority, viewportWidth: 700, viewportHeight: 420))
        XCTAssertEqual(localModel.status, localStatus)
        XCTAssertEqual(localModel.statusText, localStatus.text)
        XCTAssertEqual(rpgStatusIconID(try XCTUnwrap(localModel.status).kind),
                       "status.diskWarning")
        let localDescriptor = try XCTUnwrap(localModel.descriptors.first {
            $0.id.rawValue == "status:current"
        })
        XCTAssertEqual(localDescriptor.value, localStatus.text)
        XCTAssertEqual(localDescriptor.help, localStatus.accessibilityText)

        let authorityModel = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, localPreferenceStatus: nil,
            authority: authority, viewportWidth: 700, viewportHeight: 420))
        XCTAssertEqual(authorityModel.status, authorityStatus)
        XCTAssertEqual(authorityModel.statusText, authorityStatus.text)
        XCTAssertEqual(rpgStatusIconID(try XCTUnwrap(authorityModel.status).kind),
                       "status.hourglass")

        let noStatus = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, localPreferenceStatus: nil, authority: .localReady,
            viewportWidth: 700, viewportHeight: 420))
        XCTAssertNil(noStatus.status)
        XCTAssertEqual(noStatus.statusText, "Ready")
    }

    func testProgressionAndSpellProjectionsAreRegistryComplete() throws {
        var projectedSpells = Set<String>()
        for path in RPG_PATH_DEFINITIONS {
            let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id,
                                                      branchID: try XCTUnwrap(path.branchIDs.first)))
            let levels = rpgProgressionProjection(state)
            XCTAssertEqual(levels.map(\.level), Array(1...20))
            XCTAssertEqual(levels.map(\.absoluteXPThreshold), (1...20).map(rpgXPRequiredForLevel))
            let spells = rpgSpellUnlockProjections(pathID: path.id)
            spells.forEach { projectedSpells.insert($0.spellID) }
            XCTAssertTrue(spells.allSatisfy { !$0.unlockingSkillRanks.isEmpty })
        }
        XCTAssertEqual(projectedSpells, Set(RPG_SPELL_DEFINITIONS.map(\.id)))
    }

    func testCreationAndTutorialExposeOnlyExplicitOperations() {
        let creation = rpgBuildScreenModel(RPGScreenModelInput(state: .uncreated(),
            viewportWidth: 360, viewportHeight: 224))
        // Single-click card activation: every path card carries its own .choosePath command and
        // is directly actionable (the class carousel's separate prev/next arrows are retired).
        XCTAssertTrue(creation.descriptors.filter { $0.id.rawValue.hasPrefix("path:") }
            .allSatisfy { $0.actionCommand != nil && $0.isActionable })
        for path in RPG_PATH_DEFINITIONS {
            XCTAssertTrue(creation.descriptors.contains {
                $0.id == .path(path.id) && $0.actionCommand == .choosePath(path.id)
            }, path.id)
        }

        var created = RPGCharacterState.uncreated()
        if let fixture = rpgScreenFixture(pathID: "warden", branchID: "warden_guardian") { created = fixture }
        let tutorial = rpgBuildScreenModel(RPGScreenModelInput(state: created,
            tutorial: RPGTutorialState(seenVersion: 0, page: 1), viewportWidth: 360, viewportHeight: 224))
        XCTAssertTrue(tutorial.descriptors.contains { $0.actionCommand == .tutorialNext })
        XCTAssertTrue(tutorial.descriptors.contains { $0.actionCommand == .tutorialSkip })
    }

    func testCharacterProgressionAndReviewContainCompleteBoundedContent() throws {
        let state = try XCTUnwrap(rpgScreenFixture(pathID: "arcanist", branchID: "arcanist_elementalist"))
        let character = rpgBuildScreenModel(RPGScreenModelInput(state: state,
            equipmentSummary: "Apprentice robes", focusSummary: "Apprentice Focus equipped",
            viewportWidth: 700, viewportHeight: 420, tab: .character))
        let characterLabels = Set(character.descriptors.map(\.label))
        for label in ["Path", "Sub-class", "Level and XP", "Fatigue", "Health", "Growth",
                      "Derived recovery", "Derived offense", "Banked points",
                      "Equipment", "Focus", "Next milestone", "Level-one guidance"] {
            XCTAssertTrue(characterLabels.contains(label), label)
        }
        XCTAssertFalse(character.descriptors.contains { $0.label.hasPrefix("Character detail") })

        let progression = rpgBuildScreenModel(RPGScreenModelInput(state: state,
            viewportWidth: 700, viewportHeight: 420, tab: .progression))
        XCTAssertEqual(progression.descriptors.filter { $0.id.rawValue.hasPrefix("progression:level:") }.count, 20)
        XCTAssertTrue(progression.descriptors.contains { $0.label == "Banked points" })
        XCTAssertTrue(progression.descriptors.contains { $0.label == "Next legal purchase" })
        XCTAssertTrue(progression.descriptors.contains { $0.label == "Sub-class completion" })
        XCTAssertTrue(progression.descriptors.contains { $0.label == "Divergence" })

        var session = rpgInitialCreationSession()
        session = try rpgReduceCreationSession(session, command: .choosePath("arcanist")).get()
        let branchID = try XCTUnwrap(rpgPathDefinition("arcanist")?.branchIDs.first)
        session = try rpgReduceCreationSession(session, command: .chooseBranch(branchID)).get()
        session = try rpgReduceCreationSession(session, command: .confirmStartingSkills).get()
        let review = rpgBuildScreenModel(RPGScreenModelInput(state: .uncreated(), creation: session,
            viewportWidth: 700, viewportHeight: 420))
        let reviewLabels = Set(review.descriptors.map(\.label))
        for label in ["Path", "Sub-class", "Starting skills", "Spells granted",
                      "Health and fatigue", "Starter kit", "Focus requirement",
                      "Level-one progression", "Configured RPG chords", "Controller scope",
                      "Inventory", "Authority"] {
            XCTAssertTrue(reviewLabels.contains(label), label)
        }
        XCTAssertEqual(review.creationReview?.configuredChords.count, 12)
        XCTAssertTrue(review.creationReview?.controllerScope.contains("RPG menus and actions") == true)
    }

    /// Wrong-step creation commands and extreme tutorial-page arithmetic both fail closed without
    /// trapping. The attribute +/- arithmetic this test used to cover no longer exists (the
    /// attribute system was removed); the creation reducer's remaining unbounded-input surface is
    /// step-gating, exercised here directly.
    func testWrongStepCreationCommandsAndExtremeTutorialArithmeticFailClosedWithoutTrap() throws {
        XCTAssertEqual(rpgReduceCreationSession(
            rpgInitialCreationSession(), command: .chooseBranch("warden_guardian")),
            .failure(.cannotAdvance))
        XCTAssertEqual(rpgReduceCreationSession(
            rpgInitialCreationSession(), command: .toggleStartingSkill("guard_stance")),
            .failure(.cannotAdvance))
        XCTAssertEqual(rpgReduceCreationSession(
            rpgInitialCreationSession(), command: .confirmStartingSkills),
            .failure(.cannotAdvance))

        var tutorial = RPGTutorialState(seenVersion: 0, page: 1)
        tutorial.page = Int.max
        XCTAssertEqual(rpgTutorialAfter(.tutorialNext, state: tutorial).page, 4)
        tutorial.page = Int.min
        XCTAssertEqual(rpgTutorialAfter(.tutorialBack, state: tutorial).page, 1)
        let state = try XCTUnwrap(rpgScreenFixture(pathID: "warden", branchID: "warden_guardian"))
        XCTAssertNoThrow(rpgBuildScreenModel(RPGScreenModelInput(state: state, tutorial: tutorial,
            viewportWidth: 360, viewportHeight: 224)))
    }

    func testCreationReducerExhaustiveSixPathEighteenBranchMatrix() throws {
        var reviewed = 0
        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                var session = rpgInitialCreationSession()
                XCTAssertEqual(session.step, .path)
                session = try rpgReduceCreationSession(session, command: .choosePath(path.id)).get()
                XCTAssertEqual(session.step, .branch)
                session = try rpgReduceCreationSession(session, command: .chooseBranch(branchID)).get()
                XCTAssertEqual(session.selectedDraft?.branchID, branchID)
                XCTAssertEqual(session.step, .skills)
                session = try rpgReduceCreationSession(session, command: .confirmStartingSkills).get()
                XCTAssertEqual(session.step, .review)
                let draft = try rpgCreationDraft(from: session).get()
                XCTAssertEqual(draft.pathID, path.id)
                XCTAssertEqual(draft.branchID, branchID)
                XCTAssertEqual(draft.startingSkillIDs.count, RPG_STARTING_SKILL_COUNT)
                XCTAssertTrue(draft.starterSpellIDs.isEmpty)
                reviewed += 1

                session = try rpgReduceCreationSession(session, command: .back).get()
                XCTAssertEqual(session.step, .skills)
                session = try rpgReduceCreationSession(session, command: .back).get()
                XCTAssertEqual(session.step, .branch)
                session = try rpgReduceCreationSession(session, command: .back).get()
                XCTAssertEqual(session.step, .path)
                XCTAssertEqual(rpgReduceCreationSession(session, command: .back), .failure(.cannotAdvance))

                let otherPath = try XCTUnwrap(RPG_PATH_DEFINITIONS.first { $0.id != path.id })
                let otherBranch = otherPath.branchIDs[0]
                var atPath = try rpgReduceCreationSession(session, command: .choosePath(path.id)).get()
                XCTAssertEqual(rpgReduceCreationSession(atPath, command: .chooseBranch(otherBranch)),
                               .failure(.branchDoesNotBelongToPath(otherBranch)))
                atPath = try rpgReduceCreationSession(atPath, command: .chooseBranch(branchID)).get()
                atPath = try rpgReduceCreationSession(atPath, command: .confirmStartingSkills).get()
                XCTAssertEqual(atPath.step, .review)
            }
        }
        XCTAssertEqual(reviewed, 18)
        XCTAssertEqual(rpgReduceCreationSession(rpgInitialCreationSession(), command: .choosePath("missing")),
                       .failure(.unknownPath("missing")))
    }

    func testCompleteCharacterProgressionReviewRegistryMatrix() throws {
        var combinations = 0
        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branchID))
                let character = try XCTUnwrap(rpgCharacterSummaryProjection(state,
                    equipmentSummary: "equipment", focusSummary: "focus"))
                XCTAssertEqual(character.path, path.displayName)
                XCTAssertEqual(character.subClass, rpgBranchDefinition(branchID)?.displayName)
                XCTAssertFalse(character.growthLine.isEmpty)
                XCTAssertFalse(character.healthLine.isEmpty)
                XCTAssertFalse(character.fatigueLine.isEmpty)
                XCTAssertNotNil(character.levelOneGuidance)

                let progression = rpgProgressionSummaryProjection(state)
                XCTAssertEqual(progression.levels.count, 20)
                XCTAssertEqual(progression.levels.map(\.level), Array(1...20))
                // Each sub-class roadmap has 15 milestones (5 ranks * 3 nodes); every level's
                // milestones are disjoint, so the flattened total across all 20 levels is exact.
                XCTAssertEqual(progression.levels.flatMap(\.roadmapMilestones).count, 15)

                var session = rpgInitialCreationSession()
                session = try rpgReduceCreationSession(session, command: .choosePath(path.id)).get()
                session = try rpgReduceCreationSession(session, command: .chooseBranch(branchID)).get()
                session = try rpgReduceCreationSession(session, command: .confirmStartingSkills).get()
                let review = try XCTUnwrap(rpgCreationReviewProjection(session: session,
                    chordBindings: rpgDefaultChordBindings(), authority: .localReady,
                    inventoryCapacitySummary: "inventory caveat"))
                XCTAssertEqual(review.path, path.displayName)
                XCTAssertEqual(review.subClass, rpgBranchDefinition(branchID)?.displayName)
                XCTAssertEqual(review.startingSkills.count, RPG_STARTING_SKILL_COUNT)
                XCTAssertEqual(review.configuredChords.count, 12)
                XCTAssertFalse(review.starterKit.isEmpty)
                XCTAssertFalse(review.levelOneGuidance.isEmpty)
                combinations += 1
            }
        }
        XCTAssertEqual(combinations, 18)
    }

    func testPassiveProjectionPreservesSemanticContentAndStripsEveryCommand() throws {
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "arcanist", branchID: "arcanist_elementalist"))
        let input = RPGScreenModelInput(
            state: state, viewportWidth: 700, viewportHeight: 420, tab: .skills)
        let active = rpgBuildScreenModel(input)
        let passive = rpgBuildPassiveScreenModel(input)

        XCTAssertEqual(passive.panelFrame, active.panelFrame)
        XCTAssertEqual(passive.layout, active.layout)
        XCTAssertEqual(passive.contentFrame, active.contentFrame)
        XCTAssertEqual(passive.headerText, active.headerText)
        XCTAssertEqual(passive.statusText, active.statusText)
        XCTAssertEqual(passive.footerText, active.footerText)
        XCTAssertEqual(passive.authority, active.authority)
        XCTAssertEqual(passive.projection, active.projection)
        XCTAssertEqual(passive.characterSummary, active.characterSummary)
        XCTAssertEqual(passive.progressionSummary, active.progressionSummary)
        XCTAssertEqual(passive.creationReview, active.creationReview)
        XCTAssertEqual(passive.contentHeight, active.contentHeight)
        XCTAssertEqual(passive.viewportHeight, active.viewportHeight)
        XCTAssertEqual(passive.scrollOffset, active.scrollOffset)
        XCTAssertEqual(passive.focusedID, active.focusedID)
        XCTAssertEqual(passive.nextFocusableID, active.nextFocusableID)
        XCTAssertEqual(passive.errorText, active.errorText)
        XCTAssertEqual(passive.descriptors.count, active.descriptors.count)
        XCTAssertEqual(passive.visibleDescriptors.count, active.visibleDescriptors.count)
        for (value, original) in zip(passive.descriptors, active.descriptors) {
            XCTAssertEqual(value.id, original.id)
            XCTAssertEqual(value.role, original.role)
            XCTAssertEqual(value.groupID, original.groupID)
            XCTAssertEqual(value.label, original.label)
            XCTAssertEqual(value.value, original.value)
            XCTAssertEqual(value.help, original.help)
            XCTAssertEqual(value.selected, original.selected)
            XCTAssertEqual(value.prepared, original.prepared)
            XCTAssertEqual(value.slotted, original.slotted)
            XCTAssertEqual(value.enabled, original.enabled)
            XCTAssertEqual(value.locked, original.locked)
            XCTAssertEqual(value.isFocusable, original.isFocusable)
            XCTAssertEqual(value.focusSelection, original.focusSelection)
            XCTAssertEqual(value.layoutRegion, original.layoutRegion)
            XCTAssertEqual(value.iconAssetID, original.iconAssetID)
            XCTAssertEqual(value.visualLines, original.visualLines)
            XCTAssertEqual(value.adornment, original.adornment)
            XCTAssertEqual(value.frame, original.frame)
            XCTAssertEqual(value.visibleFrame, original.visibleFrame)
            XCTAssertNil(value.actionCommand)
            XCTAssertFalse(value.isActionable)
        }
        XCTAssertTrue(passive.visibleDescriptors.allSatisfy { $0.actionCommand == nil })
    }

    func testPassiveProjectionIsCommandFreeForEveryStepTabAndRepresentativeViewport() throws {
        let viewports = [(240.0, 160.0), (360.0, 224.0), (700.0, 420.0)]
        for step in RPGCreationStep.allCases {
            var session = rpgInitialCreationSession()
            session.step = step
            for viewport in viewports {
                let model = rpgBuildPassiveScreenModel(RPGScreenModelInput(
                    state: .uncreated(), creation: session,
                    viewportWidth: viewport.0, viewportHeight: viewport.1))
                XCTAssertTrue(model.descriptors.allSatisfy { $0.actionCommand == nil })
                XCTAssertTrue(model.visibleDescriptors.allSatisfy { $0.actionCommand == nil })
            }
        }
        let created = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for tab in RPGCharacterTab.allCases {
            for viewport in viewports {
                let model = rpgBuildPassiveScreenModel(RPGScreenModelInput(
                    state: created, viewportWidth: viewport.0,
                    viewportHeight: viewport.1, tab: tab))
                XCTAssertTrue(model.descriptors.allSatisfy { $0.actionCommand == nil })
                XCTAssertTrue(model.visibleDescriptors.allSatisfy { $0.actionCommand == nil })
            }
        }
    }

    func testPassiveSemanticSnapshotAndCheckedClockFailClosed() throws {
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        let input = RPGScreenModelInput(
            state: state, viewportWidth: 700, viewportHeight: 420, tab: .character)
        let active = rpgBuildScreenModel(input)
        let passive = rpgBuildPassiveScreenModel(input)
        XCTAssertNil(RPGPassiveSemanticSnapshot(
            screenInstanceID: 0, semanticRevision: 1, model: passive))
        XCTAssertNil(RPGPassiveSemanticSnapshot(
            screenInstanceID: 1, semanticRevision: 0, model: passive))
        XCTAssertNil(RPGPassiveSemanticSnapshot(
            screenInstanceID: 1, semanticRevision: 1, model: active))
        XCTAssertNotNil(RPGPassiveSemanticSnapshot(
            screenInstanceID: 1, semanticRevision: 1, model: passive))

        var clock = RPGPassiveSemanticClock()
        XCTAssertEqual(clock.allocateScreenInstanceID(), 1)
        XCTAssertEqual(clock.allocateScreenInstanceID(), 2)
        XCTAssertEqual(clock.nextSemanticRevision(after: nil), 1)
        XCTAssertEqual(clock.nextSemanticRevision(after: 41), 42)
        XCTAssertNil(clock.nextSemanticRevision(after: UInt64.max))

        var exhausted = RPGPassiveSemanticClock(lastScreenInstanceID: UInt64.max)
        XCTAssertNil(exhausted.allocateScreenInstanceID())
        XCTAssertTrue(exhausted.screenInstanceIDExhausted)
        XCTAssertNil(exhausted.allocateScreenInstanceID())
        XCTAssertEqual(exhausted.lastScreenInstanceID, UInt64.max)
    }

    func testActiveModelsExposeOnlyExplicitOperationsAndEveryQuickSlotDestination() throws {
        var state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        let projection = try XCTUnwrap(rpgPathProjection(pathID: state.pathID, state: state))
        let activeID = try XCTUnwrap(projection.activeSkillIDs.first)
        state.skillRanks[activeID] = max(1, state.skillRanks[activeID] ?? 0)
        if !state.preparedSkillIDs.contains(activeID) { state.preparedSkillIDs.append(activeID) }
        let skillToken = rpgPreparedActionToken(kind: .skill, id: activeID)
        var tokens = Array<String?>(repeating: nil, count: RPG_ACTION_QUICK_SLOT_COUNT)
        tokens[4] = skillToken
        let preferences = RPGQuickSlotPreferences(tokens: tokens)
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("action-model")

        let actives = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, quickSlots: preferences, localPreferenceScope: scope,
            localPreferenceRevision: 1, localPreferenceWritable: true,
            viewportWidth: 700, viewportHeight: 420, tab: .actives))
        let activeCommands = actives.descriptors.compactMap(\.actionCommand)
        XCTAssertEqual(activeCommands.filter {
            if case .assignSlot(let token, _) = $0 { return token == skillToken }; return false
        }.count, 9)
        XCTAssertTrue(activeCommands.contains(.clearSlot(4)))
        XCTAssertTrue(activeCommands.contains(.moveSlot(from: 4, to: 3)))
        XCTAssertTrue(activeCommands.contains(.moveSlot(from: 4, to: 5)))
        XCTAssertTrue(activeCommands.contains(.selectSkill(activeID)) ||
                      state.selectedPreparedActionID == activeID)

        var spellState = try XCTUnwrap(rpgScreenFixture(
            pathID: "arcanist", branchID: "arcanist_elementalist"))
        let spellProjection = try XCTUnwrap(rpgPathProjection(
            pathID: spellState.pathID, state: spellState))
        let spellID = try XCTUnwrap(spellProjection.reachableSpellIDs.first)
        if !spellState.knownSpellIDs.contains(spellID) { spellState.knownSpellIDs.append(spellID) }
        if !spellState.preparedSpellIDs.contains(spellID) { spellState.preparedSpellIDs.append(spellID) }
        let spellToken = rpgPreparedActionToken(kind: .spell, id: spellID)
        var spellTokens = Array<String?>(repeating: nil, count: RPG_ACTION_QUICK_SLOT_COUNT)
        spellTokens[5] = spellToken
        let spellPreferences = RPGQuickSlotPreferences(tokens: spellTokens)
        let spells = rpgBuildScreenModel(RPGScreenModelInput(
            state: spellState, quickSlots: spellPreferences, localPreferenceScope: scope,
            localPreferenceRevision: 1, localPreferenceWritable: true,
            viewportWidth: 700, viewportHeight: 420, tab: .spells))
        let spellCommands = spells.descriptors.compactMap(\.actionCommand)
        XCTAssertEqual(spellCommands.filter {
            if case .assignSlot(let token, _) = $0 { return token == spellToken }; return false
        }.count, 9)
        XCTAssertTrue(spellCommands.contains(.selectSpell(spellID)) ||
                      spellState.selectedPreparedSpellID == spellID)
        XCTAssertTrue(actives.descriptors.filter { $0.role == .row }
            .allSatisfy { $0.actionCommand == nil })
        XCTAssertTrue(spells.descriptors.filter { $0.role == .row }
            .allSatisfy { $0.actionCommand == nil })
    }

    func testQuickSlotPersistenceFailureProjectsTruthWithoutChangingSlots() throws {
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        let preferences = RPGQuickSlotPreferences(tokens: ["skill:interpose"])
        let status = try XCTUnwrap(RPGStatusPresentation(
            identity: .local(counter: 1, operationTag: .saveQuickSlots),
            operation: .saveQuickSlots, target: .character,
            kind: .persistenceFailure, rawDetail: "RPG quick slots",
            persistence: .localUntilReplaced, acknowledgement: .never))
        let model = rpgBuildScreenModel(RPGScreenModelInput(
            state: state, quickSlots: preferences,
            localPreferenceStatus: status,
            viewportWidth: 700, viewportHeight: 420, tab: .actives))
        XCTAssertEqual(model.statusText, status.text)
        XCTAssertEqual(model.status, status)
        XCTAssertTrue(model.descriptors.contains {
            $0.id == .slot(0) && $0.value == "Interpose"
        })
    }

    /// The class carousel was retired for a single-click card grid: every path is simultaneously
    /// present as its own actionable card (amendment behind the design mock), no arrows, no
    /// dedicated attribute step, and no actionable descriptors overlap at the compact viewport.
    func testCreationPathGridReplacesCarouselWithNoOverlapAndNoLegacyAttributeStep() throws {
        let session = rpgInitialCreationSession()
        let model = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: session,
            viewportWidth: 700, viewportHeight: 420))
        let pathCards = model.descriptors.filter { $0.id.rawValue.hasPrefix("path:") }
        XCTAssertEqual(pathCards.count, RPG_PATH_DEFINITIONS.count)
        for path in RPG_PATH_DEFINITIONS {
            let card = try XCTUnwrap(model.descriptors.first { $0.id == .path(path.id) }, path.id)
            XCTAssertEqual(card.actionCommand, .choosePath(path.id), path.id)
            XCTAssertTrue(card.isActionable, path.id)
        }
        XCTAssertFalse(model.descriptors.contains {
            $0.visualLines.contains("‹") || $0.visualLines.contains("›")
        })
        XCTAssertFalse(model.descriptors.contains { $0.id.rawValue.hasPrefix("attribute:") })
        XCTAssertEqual(model.footerText, "Tab to move focus; Enter to activate")
        XCTAssertEqual(model.stepOrTabText, rpgCreationStepTitle(.path))

        let compact = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: session,
            viewportWidth: 360, viewportHeight: 224))
        let actions = compact.visibleDescriptors.filter { $0.isActionable }
        XCTAssertFalse(actions.isEmpty)
        for left in actions.indices {
            for right in actions.indices where left < right {
                let a = actions[left].frame, b = actions[right].frame
                let overlaps = a.x < b.maxX && b.x < a.maxX &&
                    a.y < b.maxY && b.y < a.maxY
                XCTAssertFalse(overlaps,
                    "\(actions[left].id.rawValue) overlaps \(actions[right].id.rawValue)")
            }
        }

        for size in [(360.0, 224.0), (700.0, 420.0)] {
            let sized = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: session,
                viewportWidth: size.0, viewportHeight: size.1))
            XCTAssertEqual(sized.stepOrTabText, rpgCreationStepTitle(.path))
            XCTAssertEqual(sized.footerText, "Tab to move focus; Enter to activate")
        }
    }

    func testCreationFooterIsTruthfulAcrossStepsAppearancesAndViewports() {
        for step in RPGCreationStep.allCases {
            for size in [(360.0, 224.0), (700.0, 420.0)] {
                for appearance in [(false, false), (true, false), (false, true), (true, true)] {
                    var session = rpgInitialCreationSession()
                    session.step = step
                    let model = rpgBuildScreenModel(RPGScreenModelInput(
                        state: .uncreated(), creation: session,
                        viewportWidth: size.0, viewportHeight: size.1,
                        highContrast: appearance.0, reduceMotion: appearance.1))
                    XCTAssertEqual(model.footerText,
                                   "Tab to move focus; Enter to activate")
                    XCTAssertFalse(model.footerText.contains("Back · Next"))
                }
            }
        }
    }

    func testMalformedCreationDraftRegistriesFailClosedWithoutMutation() throws {
        let valid = rpgInitialCreationSession()
        var duplicate = valid
        duplicate.pathDrafts[1] = duplicate.pathDrafts[0]
        var missing = valid
        missing.pathDrafts.removeLast()
        var extra = valid
        extra.pathDrafts.append(try XCTUnwrap(valid.pathDrafts.first))
        // Structural malformations (wrong draft count or a duplicate/unknown path) are caught by
        // the reducer's registry guard, which fails every command closed with .starterRegistryMismatch.
        for session in [duplicate, missing, extra] {
            XCTAssertEqual(rpgCreationDraft(from: session), .failure(.starterRegistryMismatch))
            XCTAssertEqual(rpgReduceCreationSession(session, command: .choosePath(session.selectedPathID)),
                           .failure(.starterRegistryMismatch))
            XCTAssertEqual(rpgReduceCreationSession(session,
                command: .toggleStartingSkill("guard_stance")), .failure(.starterRegistryMismatch))
            _ = rpgBuildScreenModel(RPGScreenModelInput(
                state: .uncreated(), creation: session,
                viewportWidth: 360, viewportHeight: 224))
        }

        // A structurally-valid session whose selected draft carries a branch from the wrong path
        // passes the registry guard but still fails draft assembly closed (branch/path mismatch).
        var wrongBranch = valid
        wrongBranch.pathDrafts[0].branchID = try XCTUnwrap(
            RPG_PATH_DEFINITIONS.first { $0.id != wrongBranch.pathDrafts[0].pathID }?.branchIDs.first)
        XCTAssertEqual(rpgCreationDraft(from: wrongBranch), .failure(.starterRegistryMismatch))
        _ = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: wrongBranch,
            viewportWidth: 360, viewportHeight: 224))
    }

    func testCreationAccessibilityAndReducedMotionShareImmediateSemanticState() throws {
        let session = rpgInitialCreationSession()
        let standard = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: session,
            viewportWidth: 360, viewportHeight: 224, reduceMotion: false))
        let reduced = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: session,
            viewportWidth: 360, viewportHeight: 224, reduceMotion: true))
        let highContrast = rpgBuildScreenModel(RPGScreenModelInput(
            state: .uncreated(), creation: session,
            viewportWidth: 360, viewportHeight: 224, highContrast: true))
        let semantic: (RPGScreenModel) -> [(String, String, String, Bool)] = { model in
            model.descriptors.map { ($0.id.rawValue, $0.label, $0.help, $0.isActionable) }
        }
        XCTAssertEqual(semantic(standard).map { "\($0.0)|\($0.1)|\($0.2)|\($0.3)" },
                       semantic(reduced).map { "\($0.0)|\($0.1)|\($0.2)|\($0.3)" })
        XCTAssertEqual(semantic(standard).map { "\($0.0)|\($0.1)|\($0.2)|\($0.3)" },
                       semantic(highContrast).map { "\($0.0)|\($0.1)|\($0.2)|\($0.3)" })
        let firstPath = try XCTUnwrap(RPG_PATH_DEFINITIONS.first)
        let card = try XCTUnwrap(reduced.descriptors.first { $0.id == .path(firstPath.id) })
        XCTAssertTrue(card.label.contains("path 1 of 6"))
        XCTAssertEqual(highContrast.descriptors.first { $0.id == .path(firstPath.id) }?.adornment,
                       .selectedCheckDoubleBorder)
    }

    /// Every skill card's text fits inside its own bounded frame at the compact viewport, across
    /// every path/sub-class's five-skill starting pool -- the closest present-day analog of the
    /// retired attribute rows that used to fit their text strictly before the +/- controls.
    func testCompactSkillCardTextFitsWithinItsOwnFrameAcrossEveryStartingSkillPool() throws {
        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                var session = rpgInitialCreationSession()
                session = try rpgReduceCreationSession(session, command: .choosePath(path.id)).get()
                session = try rpgReduceCreationSession(session, command: .chooseBranch(branchID)).get()
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: .uncreated(), creation: session,
                    viewportWidth: 360, viewportHeight: 224))
                let pool = rpgStartingSkillPool(pathID: path.id, branchID: branchID)
                XCTAssertEqual(pool.count, 5, branchID)
                // Skill cards are laid out in a scrolling region, so a compact viewport legitimately
                // pushes later cards below the content frame; each card's own text still fits its own
                // frame (a failing fit would strip the toggle command), and every card is actionable.
                for skillID in pool {
                    let card = try XCTUnwrap(model.descriptors.first { $0.id == .skill(skillID) },
                                             "\(branchID) \(skillID)")
                    XCTAssertTrue(rpgDescriptorVisualLinesFit(
                        frame: card.frame, iconAssetID: card.iconAssetID,
                        visualLines: card.visualLines), "\(branchID) \(skillID)")
                    XCTAssertTrue(card.isActionable, "\(branchID) \(skillID)")
                    XCTAssertTrue(card.reservesIconCell, "\(branchID) \(skillID)")
                    XCTAssertNotNil(card.rankPips, "\(branchID) \(skillID)")
                }
            }
        }
    }
}
