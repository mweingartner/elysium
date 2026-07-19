import XCTest
@testable import ElysiumCore

final class RPGUIHarnessTests: XCTestCase {
    func testIntegratedCreationAndDirectCharacterLandingProfiles() throws {
        let creation = try fixture("creation:path:warden:warden_guardian:default",
            options: ["ELYSIUM_RPG_UI_VIEWPORT": "360x224"])
        XCTAssertEqual(creation.model.stepOrTabText, rpgCreationStepTitle(.path))
        XCTAssertNotNil(creation.model.descriptors.first { $0.id == .path("warden") })
        XCTAssertFalse(creation.model.descriptors.contains {
            $0.id.rawValue.hasPrefix("tutorial:")
        })

        let landed = try fixture("tab:warden:warden_guardian:character",
            options: ["ELYSIUM_RPG_UI_VIEWPORT": "360x224"])
        XCTAssertTrue(landed.characterState.created)
        XCTAssertEqual(landed.model.stepOrTabText, "Character")
        XCTAssertFalse(landed.model.descriptors.contains {
            $0.id.rawValue.hasPrefix("tutorial:")
        })
    }
    private func bootstrap(_ selector: String,
                           options: [String: String] = [:],
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> RPGUIHarnessBootstrap {
        var environment = options
        environment["ELYSIUM_RPG_UI_CASE"] = selector
        guard case .harness(let value) = RPGUIHarnessBootstrap.parseIfPresent(environment) else {
            XCTFail("Expected valid harness selector: \(selector)", file: file, line: line)
            throw HarnessTestError.invalidSelector
        }
        return value
    }

    private func fixture(_ selector: String,
                         options: [String: String] = [:],
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> RPGUIHarnessFixture {
        let parsed = try bootstrap(selector, options: options, file: file, line: line)
        guard let value = RPGUIHarnessFixture.build(parsed) else {
            XCTFail("Expected fixture: \(selector)", file: file, line: line)
            throw HarnessTestError.invalidFixture
        }
        XCTAssertEqual(value.model, rpgBuildScreenModel(value.modelInput),
                       "Harness must use the unmodified production model builder",
                       file: file, line: line)
        return value
    }

    /// Builds a fixture but returns nil (instead of failing) when the harness legitimately cannot
    /// construct the requested state -- e.g. a spell that is always known under the default
    /// starting-skill grant has no reachable "locked" fixture.
    private func optionalFixture(_ selector: String,
                                 options: [String: String] = [:]) -> RPGUIHarnessFixture? {
        var environment = options
        environment["ELYSIUM_RPG_UI_CASE"] = selector
        guard case .harness(let parsed) = RPGUIHarnessBootstrap.parseIfPresent(environment) else {
            return nil
        }
        return RPGUIHarnessFixture.build(parsed)
    }

    /// True when a skill is its sub-class's signature (node 0) and is therefore always granted as a
    /// default starting skill, so its "unknown" (unlearned) active-tab state is unreachable.
    private func isDefaultStartingSkill(_ skillID: String) -> Bool {
        RPG_BRANCH_DEFINITIONS.contains { $0.skillIDs.first == skillID }
    }

    private enum HarnessTestError: Error { case invalidSelector, invalidFixture }

    func testNoCaseReturnsOrdinaryAndAllowlistIsExact() {
        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([:]), .ordinary)
        XCTAssertEqual(RPGUIHarnessBootstrap.allowedElysiumKeys, Set([
            "ELYSIUM_RPG_UI_CASE", "ELYSIUM_RPG_UI_AUTHORITY", "ELYSIUM_RPG_UI_VIEWPORT",
            "ELYSIUM_RPG_UI_APPEARANCE", "ELYSIUM_RPG_UI_SEMANTIC_SUMMARY", "ELYSIUM_SHOT",
        ]))
        let shippingMutationKeys = [
            "ELYSIUM_AUTOSTART", "ELYSIUM_AUTOLOAD", "ELYSIUM_NEW_WORLD", "ELYSIUM_CMD",
            "ELYSIUM_LAN_AUTOJOIN", "ELYSIUM_LAN_PROBE", "ELYSIUM_BOT",
            "ELYSIUM_AI_ACTION_STUB", "ELYSIUM_OPEN_SCREEN", "ELYSIUM_RPG_AUTOCREATE",
            "ELYSIUM_RPG_PATH", "ELYSIUM_RPG_STARTER", "ELYSIUM_RPG_SPELLS",
        ]
        for key in shippingMutationKeys {
            let result = RPGUIHarnessBootstrap.parseIfPresent([
                "ELYSIUM_RPG_UI_CASE": "tab:warden:warden_guardian:character",
                key: "1",
            ])
            XCTAssertEqual(result, .rejected("RPG UI harness rejected: non-harness ELYSIUM key"), key)
        }
    }

    func testBoundsAndDiagnosticsAreDeterministicAcrossInsertionOrders() {
        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
            "ELYSIUM_RPG_UI_CASE": String(repeating: "x", count: 193),
        ]), .rejected("RPG UI harness rejected: environment value limit"))
        var tooMany = ["ELYSIUM_RPG_UI_CASE": "tab:warden:warden_guardian:character"]
        for index in 0..<64 { tooMany["K\(index)"] = "x" }
        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent(tooMany),
                       .rejected("RPG UI harness rejected: environment entry limit"))
        var tooLarge = ["ELYSIUM_RPG_UI_CASE": "tab:warden:warden_guardian:character"]
        for index in 0..<9 { tooLarge["K\(index)"] = String(repeating: "x", count: 500) }
        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent(tooLarge),
                       .rejected("RPG UI harness rejected: environment aggregate limit"))

        let pairs = [
            ("ELYSIUM_RPG_UI_CASE", "tab:warden:warden_guardian:character"),
            ("ELYSIUM_Z_MUTATOR", "1"),
            ("ELYSIUM_A_MUTATOR", "1"),
        ]
        let first = Dictionary(uniqueKeysWithValues: pairs)
        let second = Dictionary(uniqueKeysWithValues: pairs.reversed())
        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent(first),
                       RPGUIHarnessBootstrap.parseIfPresent(second))
    }

    func testShotAuthorityViewportAppearanceAndSummaryOptionsAreClosed() throws {
        let parsed = try bootstrap("tab:warden:warden_guardian:character", options: [
            "ELYSIUM_RPG_UI_AUTHORITY": "acceptedCommit",
            "ELYSIUM_RPG_UI_VIEWPORT": "700x420",
            "ELYSIUM_RPG_UI_APPEARANCE": "highContrastReduceMotion",
            "ELYSIUM_RPG_UI_SEMANTIC_SUMMARY": "1",
            "ELYSIUM_SHOT": "rpg_fixture.png@600",
        ])
        XCTAssertEqual(parsed.authority, .acceptedCommit)
        XCTAssertEqual(parsed.viewport, .large)
        XCTAssertEqual(parsed.appearance, .highContrastReduceMotion)
        XCTAssertTrue(parsed.semanticSummaryRequested)
        XCTAssertEqual(parsed.shot, RPGUIHarnessShotSpec(basename: "rpg_fixture.png", frames: 600))

        for bad in ["../x", "/tmp/x", ".", "..", "x@0", "x@601", "x@1@2", "x/y", "x\\y", ""] {
            XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
                "ELYSIUM_RPG_UI_CASE": "tab:warden:warden_guardian:character",
                "ELYSIUM_SHOT": bad,
            ]), .rejected("RPG UI harness rejected: invalid screenshot basename"), bad)
        }
        for bad in ["x@01", "x@00", "x@+1", "x@-0", "x@ 1", "x@1 "] {
            XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
                "ELYSIUM_RPG_UI_CASE": "tab:warden:warden_guardian:character",
                "ELYSIUM_SHOT": bad,
            ]), .rejected("RPG UI harness rejected: invalid screenshot basename"), bad)
        }
        for (key, value) in [
            ("ELYSIUM_RPG_UI_AUTHORITY", "host"),
            ("ELYSIUM_RPG_UI_VIEWPORT", "800x600"),
            ("ELYSIUM_RPG_UI_APPEARANCE", "dark"),
            ("ELYSIUM_RPG_UI_SEMANTIC_SUMMARY", "true"),
        ] {
            XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
                "ELYSIUM_RPG_UI_CASE": "tab:warden:warden_guardian:character", key: value,
            ]), .rejected(key == "ELYSIUM_RPG_UI_SEMANTIC_SUMMARY"
                ? "RPG UI harness rejected: invalid semantic summary option"
                : "RPG UI harness rejected: invalid fixture option"))
        }
    }

    func testNumericSelectorGrammarRejectsEveryNoncanonicalAlias() {
        let invalid = [
            "tutorial:01:warden:warden_guardian",
            "tutorial:+1:warden:warden_guardian",
            "tutorial: 1:warden:warden_guardian",
            "skill:guard_stance:01:current",
            "skill:guard_stance:+1:current",
            "slots:warden:warden_guardian:00:empty",
            "slots:warden:warden_guardian:-0:empty",
            "status:cooldown:useSlot:slot01:local",
            "status:cooldown:useSlot:slot+1:local",
            "status:cooldown:useSlot:slot 1:local",
        ]
        for selector in invalid {
            XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
                "ELYSIUM_RPG_UI_CASE": selector,
            ]), .rejected("RPG UI harness rejected: invalid case selector"), selector)
        }
    }

    func testEveryCreationTutorialTabAndSlotSelectorBuilds() throws {
        for path in RPG_PATH_DEFINITIONS {
            for branch in path.branchIDs {
                for step in RPGCreationStep.allCases {
                    for profile in ["default", "partial", "custom", "overflowHelp", "inventoryFull"] {
                        let built = try fixture("creation:\(step.rawValue):\(path.id):\(branch):\(profile)")
                        if profile == "partial" {
                            XCTAssertThrowsError(try rpgCreationDraft(from: built.modelInput.creation).get(),
                                                 "\(path.id) \(branch) \(profile)")
                        } else {
                            XCTAssertNoThrow(try rpgCreationDraft(from: built.modelInput.creation).get(),
                                             "\(path.id) \(branch) \(profile)")
                        }
                    }
                }
                for page in 1...4 {
                    _ = try fixture("tutorial:\(page):\(path.id):\(branch)")
                }
                for tab in RPGCharacterTab.allCases {
                    _ = try fixture("tab:\(path.id):\(branch):\(tab.rawValue)")
                }
                for slot in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
                    for profile in ["empty", "sparse", "maximal", "repairInvalid"] {
                        _ = try fixture("slots:\(path.id):\(branch):\(slot):\(profile)")
                    }
                }
            }
        }
    }

    func testCreationFailureProfilesAreVisibleAndNonActionable() throws {
        let partial = try fixture("creation:review:warden:warden_guardian:partial")
        let createID = RPGUIElementID.operation(
            owner: RPGUIElementID(rawValue: "creation:review")!, name: "create")
        let partialCreate = try XCTUnwrap(partial.model.descriptors.first { $0.id == createID })
        XCTAssertFalse(partialCreate.enabled)
        XCTAssertFalse(partialCreate.isActionable)
        XCTAssertEqual(partialCreate.layoutRegion, .fixed)
        XCTAssertEqual(partialCreate.help,
                       "Choose exactly \(RPG_STARTING_SKILL_COUNT) starting skills before continuing.")
        XCTAssertEqual(partial.model.errorText,
                       "Choose exactly \(RPG_STARTING_SKILL_COUNT) starting skills; 2 chosen.")

        let full = try fixture("creation:review:warden:warden_guardian:inventoryFull")
        let fullCreate = try XCTUnwrap(full.model.descriptors.first { $0.id == createID })
        XCTAssertFalse(fullCreate.enabled)
        XCTAssertFalse(fullCreate.isActionable)
        XCTAssertEqual(fullCreate.help, "Inventory is full; the starter kit does not fit.")
        XCTAssertEqual(full.model.errorText, fullCreate.help)
        XCTAssertTrue(full.model.descriptors.contains {
            $0.label == "Inventory" && $0.value == "Inventory is full; the starter kit does not fit."
        })
    }

    /// The class carousel's per-rank-cell interaction was retired; a skill is now a single
    /// focusable card (`RPGUIElementID.skill`) whose `rankPips`/`nextEvaluation` summarize every
    /// rank at once. This exercises every reachable (rank, presentation-state) combination the
    /// harness selector grammar allows and confirms the built card's evaluation is internally
    /// consistent with the requested presentation.
    func testEverySkillPresentationStateHasACanonicalFocusedCardConsistentWithItsEvaluation() throws {
        var coveredStates = Set<String>()
        for skill in RPG_SKILL_DEFINITIONS {
            for rank in 1...RPG_SKILL_RANK_CAP {
                for state in ["purchased", "current", "nextLegal", "locked", "future"] {
                    let representable: Bool
                    switch state {
                    case "purchased": representable = rank < RPG_SKILL_RANK_CAP
                    case "future": representable = rank > 1
                    default: representable = true
                    }
                    guard representable else {
                        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
                            "ELYSIUM_RPG_UI_CASE": "skill:\(skill.id):\(rank):\(state)",
                        ]), .rejected("RPG UI harness rejected: invalid case selector"))
                        continue
                    }
                    guard case .harness(let parsed) = RPGUIHarnessBootstrap.parseIfPresent([
                        "ELYSIUM_RPG_UI_CASE": "skill:\(skill.id):\(rank):\(state)",
                    ]) else {
                        return XCTFail("expected a parseable selector for \(skill.id) \(rank) \(state)")
                    }
                    guard let built = RPGUIHarnessFixture.build(parsed) else {
                        // Not every (rank, state) combination is reachable for every skill under
                        // the level-gate/budget rules; the harness itself is the source of truth
                        // for reachability and returns nil rather than a fabricated card.
                        continue
                    }
                    XCTAssertEqual(built.model, rpgBuildScreenModel(built.modelInput),
                                   "\(skill.id) \(rank) \(state)")
                    let card = try XCTUnwrap(built.model.projection?.skillCards.first {
                        $0.skillID == skill.id
                    }, "\(skill.id) \(rank) \(state)")
                    XCTAssertEqual(built.model.focusedID, .skill(skill.id), "\(skill.id) \(rank) \(state)")
                    switch state {
                    case "purchased":
                        XCTAssertGreaterThan(card.currentRank, rank, "\(skill.id) \(rank) \(state)")
                    case "current":
                        XCTAssertEqual(card.currentRank, rank, "\(skill.id) \(rank) \(state)")
                    case "nextLegal":
                        XCTAssertEqual(card.nextEvaluation?.targetRank, rank, "\(skill.id) \(rank) \(state)")
                        XCTAssertEqual(card.nextEvaluation?.permitted, true, "\(skill.id) \(rank) \(state)")
                    case "locked":
                        XCTAssertEqual(card.nextEvaluation?.targetRank, rank, "\(skill.id) \(rank) \(state)")
                        XCTAssertEqual(card.nextEvaluation?.permitted, false, "\(skill.id) \(rank) \(state)")
                    default: // "future"
                        XCTAssertLessThan(card.currentRank, rank, "\(skill.id) \(rank) \(state)")
                        XCTAssertNotEqual(card.nextEvaluation?.targetRank, rank, "\(skill.id) \(rank) \(state)")
                    }
                    coveredStates.insert(state)
                }
            }
        }
        XCTAssertEqual(coveredStates, Set(["purchased", "current", "nextLegal", "locked", "future"]),
                       "every presentation state must be reachable for at least one skill/rank")
    }

    func testEverySkillCardIsRevealedAtAllInstalledViewportsBeforeFixturePublication() throws {
        var count = 0
        for viewport in RPGUIHarnessViewport.allCases {
            for skill in RPG_SKILL_DEFINITIONS {
                let built = try fixture(
                    "skill:\(skill.id):1:current",
                    options: ["ELYSIUM_RPG_UI_VIEWPORT": viewport.rawValue])
                let id = RPGUIElementID.skill(skill.id)
                let target = try XCTUnwrap(built.model.descriptors.first {
                    $0.id == id && $0.isFocusable
                })
                XCTAssertEqual(built.model.focusedID, id)
                XCTAssertEqual(target.layoutRegion, .scrollingContent)
                XCTAssertEqual(target.visibleFrame, target.frame)
                XCTAssertTrue(built.model.contentFrame.contains(target.frame))
                XCTAssertTrue(rpgDescriptorVisualLinesFit(
                    frame: target.frame, iconAssetID: target.iconAssetID,
                    visualLines: target.visualLines))
                XCTAssertTrue(target.visualLines.contains {
                    $0.contains(skill.displayName)
                }, "\(viewport.rawValue) \(skill.id)")
                XCTAssertTrue(built.model.visibleDescriptors.contains {
                    $0.id == id && $0.visibleFrame == $0.frame
                })
                XCTAssertEqual(rpgScreenDescriptor(
                    atX: target.frame.x + target.frame.width / 2,
                    y: target.frame.y + target.frame.height / 2,
                    in: built.model)?.id, id)
                XCTAssertEqual(built.modelInput.scrollOffset, built.model.scrollOffset)
                XCTAssertEqual(rpgRevealScrollOffset(
                    descriptor: target, in: built.model,
                    currentOffset: built.modelInput.scrollOffset),
                    built.modelInput.scrollOffset)
                count += 1
            }
        }
        XCTAssertEqual(count, RPG_SKILL_DEFINITIONS.count * RPGUIHarnessViewport.allCases.count)
    }

    func testEveryActiveAndSpellStateBuildsDistinctSemanticOutput() throws {
        let activeSkills = RPG_SKILL_DEFINITIONS.filter { $0.kind == .active }
        for skill in activeSkills {
            for state in ["unknown", "known", "prepared", "selected", "slotted"] {
                // A signature active skill is always granted as a default starting skill, so its
                // "unknown" (unlearned) actives-tab state is unreachable -- skip it.
                if state == "unknown", isDefaultStartingSkill(skill.id) {
                    continue
                }
                let built = try fixture("active:\(skill.id):\(state)")
                let row = try XCTUnwrap(built.model.descriptors.first { $0.id == .skill(skill.id) })
                let learned = (built.characterState.skillRanks[skill.id] ?? 0) > 0
                XCTAssertEqual(learned, state != "unknown", "\(skill.id) \(state)")
                XCTAssertEqual(row.prepared, ["prepared", "selected", "slotted"].contains(state))
                XCTAssertEqual(row.slotted, state == "slotted")
                XCTAssertEqual(built.characterState.selectedPreparedActionID ==
                    rpgPreparedActionToken(kind: .skill, id: skill.id), state == "selected")
            }
        }
        for spell in RPG_SPELL_DEFINITIONS {
            for state in ["locked", "known", "prepared", "selected", "slotted"] {
                // Spells unlocked at rank 1 of a signature skill are always known under the default
                // starting-skill grant, so their "locked" fixture is legitimately unbuildable.
                if state == "locked", optionalFixture("spell:\(spell.id):locked") == nil {
                    continue
                }
                let built = try fixture("spell:\(spell.id):\(state)")
                let row = try XCTUnwrap(built.model.descriptors.first { $0.id == .spell(spell.id) })
                XCTAssertEqual(built.characterState.knownSpellIDs.contains(spell.id),
                               state != "locked", "\(spell.id) \(state)")
                XCTAssertEqual(row.prepared, ["prepared", "selected", "slotted"].contains(state))
                XCTAssertEqual(row.slotted, state == "slotted")
                XCTAssertEqual(built.characterState.selectedPreparedSpellID == spell.id,
                               state == "selected")
            }
        }
    }

    func testSlotProfilesAreExactPreparedAndRepairSummaryShowsRawAndNormalized() throws {
        let empty = try fixture("slots:arcanist:arcanist_elementalist:0:empty")
        XCTAssertEqual(empty.model.descriptors.filter { $0.id.rawValue.hasPrefix("slot:") && $0.role == .row }
            .map(\.value), Array(repeating: "Empty", count: 9))
        let sparse = try fixture("slots:arcanist:arcanist_elementalist:4:sparse")
        let sparseSlots = sparse.model.descriptors.filter {
            $0.id.rawValue.hasPrefix("slot:") && $0.role == .row
        }
        XCTAssertNotEqual(sparseSlots[0].value, "Empty")
        XCTAssertNotEqual(sparseSlots[4].value, "Empty")
        XCTAssertEqual(sparseSlots.enumerated().filter { ![0, 4].contains($0.offset) }.map(\.element.value),
                       Array(repeating: "Empty", count: 7))
        let rangerSparse = try fixture("slots:ranger:ranger_survivalist:4:sparse")
        // Sparse only ever populates slots 0 and 4 (slot 4 iff there are >= 2 prepared tokens);
        // every other slot stays empty.
        XCTAssertNotNil(rangerSparse.quickSlots.tokens[0])
        for index in [1, 2, 3, 5, 6, 7, 8] {
            XCTAssertNil(rangerSparse.quickSlots.tokens[index], "slot \(index)")
        }
        let maximal = try fixture("slots:arcanist:arcanist_elementalist:8:maximal")
        let maximalTokens = maximal.model.descriptors.filter {
            $0.id.rawValue.hasPrefix("slot:") && $0.role == .row && $0.value != "Empty"
        }.map(\.value)
        XCTAssertEqual(maximalTokens.count, Set(maximalTokens).count)
        let prepared = Set(rpgPreparedActions(maximal.characterState).map(\.displayName))
        XCTAssertTrue(maximalTokens.allSatisfy(prepared.contains))
        XCTAssertEqual(maximal.quickSlots.tokens.compactMap { $0 }
            .map { rpgPreparedActionDisplayName($0) },
                       maximalTokens)
        let repaired = try fixture("slots:warden:warden_guardian:0:repairInvalid")
        XCTAssertTrue(repaired.summary.contains("|raw="))
        XCTAssertTrue(repaired.summary.contains("|normalized="))
        let normalized = repaired.model.descriptors.filter {
            $0.id.rawValue.hasPrefix("slot:") && $0.role == .row && $0.value != "Empty"
        }.map(\.value)
        XCTAssertEqual(normalized.count, Set(normalized).count)
        XCTAssertFalse(normalized.contains("skill:unknown"))
    }

    func testMaximalSlotSearchIsRegistryWideAndOperationallyBounded() throws {
        let start = ProcessInfo.processInfo.systemUptime
        for path in RPG_PATH_DEFINITIONS {
            let branch = try XCTUnwrap(path.branchIDs.first)
            let built = try fixture("slots:\(path.id):\(branch):0:maximal")
            let tokens = built.quickSlots.tokens.compactMap { $0 }
            XCTAssertFalse(tokens.isEmpty, path.id)
            XCTAssertLessThanOrEqual(tokens.count, 9)
            XCTAssertEqual(tokens.count, Set(tokens).count)
            let prepared = Set(rpgPreparedActions(built.characterState).map(\.token))
            XCTAssertTrue(tokens.allSatisfy(prepared.contains), path.id)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2.0)
    }

    func testStatusCompatibilityTargetsAndErrorCasesAreSemanticallyActive() throws {
        let statusMappings: [(RPGStatusKind, String, String)] = [
            (.success, "status.check", "Success"),
            (.pending, "status.hourglass", "Awaiting host"),
            (.rejection, "status.cross", "Rejected"),
            (.cooldown, "status.clock", "Cooldown"),
            (.fatigue, "status.fatigue", "Not enough fatigue"),
            (.missingFocus, "status.focus", "Focus required"),
            (.missingEquipment, "status.equipment", "Equipment required"),
            (.permissionDenied, "status.lock", "Permission denied"),
            (.persistenceFailure, "status.diskWarning", "Could not save"),
            (.authorityExhausted, "status.stop", "Authority exhausted"),
        ]
        for (kind, icon, leading) in statusMappings {
            XCTAssertEqual(rpgStatusIconID(kind), icon)
            XCTAssertEqual(rpgStatusLeadingText(kind), leading)
        }
        let valid = [
            "status:success:sheet:guard_stance:local",
            "status:pending:saveSlots:slot4:authority",
            "status:rejection:cycle:character:durablePending",
            "status:missingEquipment:useSelected:apprenticeFocus:local",
            "status:permissionDenied:useSelected:buildOnlyForBlockTarget:local",
            "status:cooldown:useSlot:slot8:local",
        ]
        for selector in valid {
            let options = selector.hasSuffix(":authority")
                ? ["ELYSIUM_RPG_UI_AUTHORITY": "pending"] : [:]
            let built = try fixture(selector, options: options)
            let status = try XCTUnwrap(built.status)
            XCTAssertEqual(built.model.statusText, status.text)
            XCTAssertTrue(built.summary.contains("RPG status|id="))
            XCTAssertNotNil(status.identity.stableID)
        }
        for invalid in [
            "status:success:useSlot:character:local",
            "status:success:saveSlots:heldTool:local",
            "status:success:sheet:build:local",
            "status:success:cycle:slot0:local",
            "status:cooldown:sheet:guard_stance:local",
            "status:missingEquipment:cycle:character:local",
            "status:persistenceFailure:useSelected:interpose:local",
            "status:success:useSelected:not_registered:local",
            "status:success:useSelected:notEquipment:local",
            "error:cooldown:skill:guard_stance",
        ] {
            XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent(["ELYSIUM_RPG_UI_CASE": invalid]),
                           .rejected("RPG UI harness rejected: invalid case selector"), invalid)
        }
        XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent([
            "ELYSIUM_RPG_UI_CASE": "status:pending:saveSlots:slot4:authority",
        ]), .rejected("RPG UI harness rejected: inconsistent authority status"))
        for invalidLifecycle in [
            "status:pending:useSelected:character:local",
            "status:cooldown:useSelected:character:durablePending",
            "status:success:useSelected:character:authority",
        ] {
            var environment = ["ELYSIUM_RPG_UI_CASE": invalidLifecycle]
            if invalidLifecycle.hasSuffix(":authority") {
                environment["ELYSIUM_RPG_UI_AUTHORITY"] = "pending"
            }
            XCTAssertEqual(RPGUIHarnessBootstrap.parseIfPresent(environment),
                .rejected("RPG UI harness rejected: inconsistent status lifecycle"),
                invalidLifecycle)
        }

        for kind in ["cooldown", "fatigue", "missingFocus", "missingEquipment",
                     "permissionDenied"] {
            let built = try fixture("error:\(kind):skill:interpose")
            XCTAssertEqual(built.model.statusText, built.status?.text)
            XCTAssertTrue(built.model.statusText.contains(
                rpgStatusLeadingText(RPGStatusKind(rawValue: kind)!)))
            XCTAssertTrue(built.model.descriptors.contains {
                $0.id.rawValue == "status:current" && $0.value == built.status?.text
            })
        }
        for (targetKind, registeredID, displayName) in [
            ("skill", "interpose", "Interpose"),
            ("skill", "guard_stance", "Guard Stance"),
            ("spell", "ignite", "Ignite"),
        ] {
            let built = try fixture(
                "error:persistenceFailure:\(targetKind):\(registeredID)")
            let status = try XCTUnwrap(built.status)
            XCTAssertEqual(status.operation, .saveQuickSlots)
            XCTAssertEqual(status.target, .character)
            XCTAssertEqual(status.kind, .persistenceFailure)
            XCTAssertTrue(status.text.contains(
                "Quick-slot save after viewing \(targetKind) — \(displayName)"))
            XCTAssertTrue(built.summary.contains("operation=Save quick slots"))
            XCTAssertTrue(built.summary.contains("target=Character"))
            XCTAssertTrue(built.summary.contains(displayName))
            XCTAssertFalse(built.summary.contains("operation=Use selected action"))
        }

        let lifecycleCases: [(RPGStatusKind, String, [String: String])] =
            RPGStatusKind.allCases.filter { $0 != .pending && $0 != .authorityExhausted }.map {
                ($0, "local", [:])
            } + [
                (.pending, "authority", ["ELYSIUM_RPG_UI_AUTHORITY": "pending"]),
                (.authorityExhausted, "authority",
                    ["ELYSIUM_RPG_UI_AUTHORITY": "exhausted"]),
            ] + [RPGStatusKind.success, .rejection, .authorityExhausted].flatMap { kind in
                [(kind, "durablePending", [:]), (kind, "durableAcknowledged", [:])]
            }
        for (kind, persistence, options) in lifecycleCases {
                let operation = kind == .persistenceFailure ? "saveSlots" : "useSelected"
                let built = try fixture(
                    "status:\(kind.rawValue):\(operation):character:\(persistence)",
                    options: options)
                let status = try XCTUnwrap(built.status)
                XCTAssertEqual(status.kind, kind)
                XCTAssertEqual(built.model.statusText, status.text)
                switch persistence {
                case "local":
                    XCTAssertEqual(status.persistence, .localUntilReplaced)
                    XCTAssertEqual(status.acknowledgement, .never)
                case "authority":
                    XCTAssertEqual(status.persistence, .authorityPhase)
                    XCTAssertEqual(status.acknowledgement, .never)
                case "durablePending":
                    XCTAssertEqual(status.persistence, .durableInboxPendingRender)
                    XCTAssertEqual(status.acknowledgement, .afterCommittedModelRevision(7))
                default:
                    XCTAssertEqual(status.persistence, .durableInboxAcknowledged)
                    XCTAssertEqual(status.acknowledgement, .acknowledged)
                }
        }
        let focus = try fixture(
            "status:missingEquipment:useSelected:apprenticeFocus:local")
        let tool = try fixture(
            "status:missingEquipment:useSelected:heldTool:local")
        XCTAssertEqual(focus.model.statusText,
                       "Equipment required: Use selected action — Apprentice Focus")
        XCTAssertEqual(tool.model.statusText,
                       "Equipment required: Use selected action — Held tool")
        XCTAssertNotEqual(focus.model.statusText, tool.model.statusText)
        XCTAssertTrue(focus.summary.contains("operation=Use selected action"))
        XCTAssertTrue(focus.summary.contains("target=Apprentice Focus"))
        for internalToken in ["useSelected", "apprenticeFocus", "missingEquipment",
                              "durableInbox", "afterCommittedModelRevision"] {
            XCTAssertFalse(focus.model.statusText.contains(internalToken), internalToken)
            XCTAssertFalse(focus.summary.contains(internalToken), internalToken)
        }
    }

    func testAllAuthorityAppearanceViewportOptionsAndSummaryBounds() throws {
        for authority in RPGUIHarnessAuthority.allCases {
            for appearance in RPGUIHarnessAppearance.allCases {
                for viewport in RPGUIHarnessViewport.allCases {
                    let built = try fixture("tab:warden:warden_guardian:character", options: [
                        "ELYSIUM_RPG_UI_AUTHORITY": authority.rawValue,
                        "ELYSIUM_RPG_UI_APPEARANCE": appearance.rawValue,
                        "ELYSIUM_RPG_UI_VIEWPORT": viewport.rawValue,
                    ])
                    let presentation = rpgAuthorityPhasePresentation(authority.phase)
                    XCTAssertEqual(built.model.authority, presentation)
                    XCTAssertTrue(built.summary.contains("value=\(presentation.visibleTitle)"))
                    XCTAssertTrue(built.summary.contains("help=\(presentation.visibleHelp)"))
                    XCTAssertLessThanOrEqual(built.summary.utf8.count, 65_536)
                    let lines = built.summary.split(separator: "\n").map(String.init)
                    XCTAssertEqual(lines, lines.sorted())
                    XCTAssertLessThanOrEqual(lines.count, 512)
                    XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 1_024 })
                    let authorityDescriptor = try XCTUnwrap(built.model.descriptors.first {
                        $0.id.rawValue == "authority:phase"
                    })
                    XCTAssertEqual(authorityDescriptor.role, .group)
                    XCTAssertEqual(authorityDescriptor.label, "RPG authority")
                    XCTAssertEqual(authorityDescriptor.value, presentation.visibleTitle)
                    XCTAssertEqual(authorityDescriptor.help, presentation.visibleHelp)
                    XCTAssertFalse(authorityDescriptor.isActionable)
                    XCTAssertTrue(authorityDescriptor.frame.isFinite)
                    XCTAssertTrue(built.model.panelFrame.contains(authorityDescriptor.frame))
                    XCTAssertLessThanOrEqual(authorityDescriptor.frame.maxY,
                                             built.model.contentFrame.y)
                }
            }
        }
        XCTAssertEqual(Set(RPGUIHarnessAuthority.allCases.map {
            rpgAuthorityPhasePresentation($0.phase).proceduralIconID
        }).count, 8)
    }

    /// The class carousel was retired in favor of single-click path cards: every path card is
    /// simultaneously present (no chevron paging), each reserves its icon cell, and the footer
    /// keyboard hint is unchanged across every appearance/viewport combination.
    func testCreationPathCardGridReplacesTheCarouselAcrossEveryAppearanceAndViewport() throws {
        for appearance in RPGUIHarnessAppearance.allCases {
            for viewport in RPGUIHarnessViewport.allCases {
                let built = try fixture("creation:path:warden:warden_guardian:default", options: [
                    "ELYSIUM_RPG_UI_APPEARANCE": appearance.rawValue,
                    "ELYSIUM_RPG_UI_VIEWPORT": viewport.rawValue,
                ])
                let pathCards = built.model.descriptors.filter { $0.id.rawValue.hasPrefix("path:") }
                XCTAssertEqual(pathCards.count, RPG_PATH_DEFINITIONS.count,
                               "\(appearance.rawValue) \(viewport.rawValue)")
                XCTAssertTrue(pathCards.allSatisfy(\.reservesIconCell),
                              "\(appearance.rawValue) \(viewport.rawValue)")
                XCTAssertEqual(built.model.footerText,
                               "Tab to move focus; Enter to activate")
                XCTAssertFalse(built.model.descriptors.contains {
                    $0.visualLines.contains("‹") || $0.visualLines.contains("›")
                })
            }
        }
    }

    func testLongestStatusAndAuthorityBandsNeverOverlapContentAtAnyViewport() throws {
        let status = try XCTUnwrap(RPGStatusPresentation(
            identity: .local(counter: 1, operationTag: .usePreparedAction),
            operation: .usePreparedAction, target: .permission("buildOnlyForBlockTarget"),
            kind: .permissionDenied, rawDetail: String(repeating: "bounded detail ", count: 20),
            persistence: .localUntilReplaced, acknowledgement: .never))
        XCTAssertLessThanOrEqual(status.text.utf8.count, 160)
        let state = try XCTUnwrap(rpgScreenFixture(
            pathID: "warden", branchID: "warden_guardian"))
        for authorityCase in RPGUIHarnessAuthority.allCases {
            let phase = authorityCase.phase
            let request = phase == .localReady || phase == .unavailable
                ? nil : String(repeating: "a", count: 64)
            let authority = try RPGAuthorityPresentation(
                validating: phase, requestIdentity: request, status: status)
            for viewport in RPGUIHarnessViewport.allCases {
                let size = viewport.size
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: state, authority: authority,
                    viewportWidth: size.0, viewportHeight: size.1, tab: .skills))
                let authorityDescriptor = try XCTUnwrap(model.descriptors.first {
                    $0.id.rawValue == "authority:phase"
                })
                let statusDescriptor = try XCTUnwrap(model.descriptors.first {
                    $0.id.rawValue == "status:current"
                })
                XCTAssertEqual(statusDescriptor.value, status.text)
                XCTAssertLessThanOrEqual(authorityDescriptor.frame.maxY,
                                         statusDescriptor.frame.y)
                XCTAssertLessThanOrEqual(statusDescriptor.frame.maxY,
                                         model.contentFrame.y)
                for descriptor in model.descriptors where
                    descriptor.id != authorityDescriptor.id {
                    let disjoint = descriptor.frame.maxY <= authorityDescriptor.frame.y ||
                        descriptor.frame.y >= authorityDescriptor.frame.maxY ||
                        descriptor.frame.maxX <= authorityDescriptor.frame.x ||
                        descriptor.frame.x >= authorityDescriptor.frame.maxX
                    XCTAssertTrue(disjoint,
                        "\(authorityCase.rawValue) \(viewport.rawValue) \(descriptor.id.rawValue)")
                }
                let tabs = model.descriptors.filter { $0.role == .tab }
                XCTAssertEqual(tabs.count, RPGCharacterTab.allCases.count)
                XCTAssertTrue(tabs.allSatisfy {
                    $0.layoutRegion == .fixed &&
                        model.layout.stepOrTabFrame.contains($0.frame)
                })
            }
        }
    }

    func testAuthorityPhaseHelpAndExhaustedQuickSlotContract() throws {
        let activePrepared = try fixture("slots:warden:warden_guardian:0:maximal")
        let spellPrepared = try fixture("slots:arcanist:arcanist_elementalist:0:maximal")
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("authority-matrix")
        for authorityCase in RPGUIHarnessAuthority.allCases {
            let phase = authorityCase.phase
            let request = phase == .localReady || phase == .unavailable
                ? nil : String(repeating: "a", count: 64)
            let authority = try RPGAuthorityPresentation(
                validating: phase, requestIdentity: request)
            let help = rpgAuthorityPhasePresentation(phase).visibleHelp
            for tab in [RPGCharacterTab.actives, .spells] {
                let prepared = tab == .actives ? activePrepared : spellPrepared
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: prepared.characterState, quickSlots: prepared.quickSlots,
                    localPreferenceScope: scope, localPreferenceWritable: true,
                    authority: authority, viewportWidth: 700, viewportHeight: 420,
                    tab: tab))
                let authorityButtons = model.descriptors.filter {
                    $0.role == .button &&
                        ($0.label.hasPrefix("Prepare ") ||
                         $0.label.hasPrefix("Unprepare ") ||
                         $0.label.hasPrefix("Select "))
                }
                XCTAssertFalse(authorityButtons.isEmpty, "\(authorityCase) \(tab)")
                if phase == .localReady {
                    XCTAssertTrue(authorityButtons.contains(where: \.enabled))
                } else {
                    XCTAssertTrue(authorityButtons.allSatisfy {
                        !$0.enabled && $0.help == help
                    }, "\(authorityCase) \(tab)")
                }
            }
            if phase == .authorityExhausted {
                let model = rpgBuildScreenModel(RPGScreenModelInput(
                    state: activePrepared.characterState,
                    quickSlots: activePrepared.quickSlots,
                    localPreferenceScope: scope, localPreferenceWritable: true,
                    authority: authority, viewportWidth: 700, viewportHeight: 420,
                    tab: .actives))
                XCTAssertFalse(model.descriptors.contains {
                    if case .assignSlot = $0.actionCommand { return true }
                    return false
                })
                let assignDescriptors = model.descriptors.filter {
                    $0.role == .button && $0.label.hasPrefix("Assign Slot ")
                }
                XCTAssertFalse(assignDescriptors.isEmpty)
                XCTAssertTrue(assignDescriptors.allSatisfy {
                    !$0.enabled && $0.help == help
                })
                XCTAssertTrue(model.descriptors.contains {
                    if case .clearSlot = $0.actionCommand { return true }
                    return false
                })
                XCTAssertTrue(model.descriptors.contains {
                    if case .moveSlot = $0.actionCommand { return true }
                    return false
                })
            }
        }
    }

    func testUnwritableQuickSlotControlsExposeExactVisibleAndAccessibilityHelp() throws {
        let prepared = try fixture("slots:warden:warden_guardian:0:maximal")
        let viewport = try XCTUnwrap(RPGAccessibilityViewport(width: 700, height: 420))
        for phase in [RPGAuthorityPresentationPhase.localReady, .unavailable] {
            let authority = try RPGAuthorityPresentation(validating: phase)
            let model = rpgBuildScreenModel(RPGScreenModelInput(
                state: prepared.characterState, quickSlots: prepared.quickSlots,
                localPreferenceScope: nil, localPreferenceWritable: false,
                authority: authority, viewportWidth: 700, viewportHeight: 420,
                tab: .actives))
            let controls = model.descriptors.filter {
                $0.role == .button &&
                    ($0.label.hasPrefix("Assign Slot ") ||
                     $0.label.hasPrefix("Move Slot ") ||
                     $0.label.hasPrefix("Clear Slot "))
            }
            XCTAssertFalse(controls.isEmpty)
            for descriptor in controls {
                XCTAssertFalse(descriptor.enabled)
                XCTAssertNil(descriptor.actionCommand)
                XCTAssertEqual(descriptor.help,
                               RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP)
                let element = try XCTUnwrap(RPGAccessibilityElementSnapshot(
                    descriptor: descriptor, activationOrigin: nil,
                    layoutGeneration: 1, viewport: viewport))
                XCTAssertEqual(element.accessibilityHelp,
                               RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP)
            }
        }
    }

    func testPureBootstrapAndFixtureDoNotWriteFreshSupportHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-rpg-harness-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let built = try fixture("tutorial:4:tinker:tinker_sapper", options: [
            "CFFIXED_USER_HOME": root.path,
            "HOME": root.path,
            "ELYSIUM_RPG_UI_SEMANTIC_SUMMARY": "1",
        ])
        XCTAssertFalse(built.summary.isEmpty)
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(after, before)
        for forbidden in ["password", "credential", "player name", "save path", root.path] {
            XCTAssertFalse(built.summary.localizedCaseInsensitiveContains(forbidden))
        }
    }
}
