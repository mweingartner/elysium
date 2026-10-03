import XCTest
@testable import Elysium
@testable import ElysiumCore

/// White-box coverage for the native Skills projection: XP boundaries, every tree's copy, rank
/// status sequences, fast-bar filtering, item-mastery folding, action effects, and an XP sweep
/// asserting the invariants the window relies on.
final class SkillsPresentationEdgeTests: XCTestCase {
    private func context(slots: [SkillTreeActionID: Int] = [:],
                         outputs: [Int] = [],
                         isLANGuest: Bool = false) -> SkillsPresentationContext {
        SkillsPresentationContext(quickSlot: { slots[$0] },
                                  recipeOutputItemIDs: outputs,
                                  itemName: { "Item \($0)" },
                                  isLANGuest: isLANGuest)
    }

    private func state(all xp: Int, mastery: [UInt8] = []) -> SkillTreeState {
        state(mining: xp, melee: xp, ranged: xp, crafting: xp, mastery: mastery)
    }

    private func state(mining: Int = 0, melee: Int = 0, ranged: Int = 0, crafting: Int = 0,
                       mastery: [UInt8] = []) -> SkillTreeState {
        SkillTreeState(mining: SkillTreeBranchState(xp: mining),
                       melee: SkillTreeBranchState(xp: melee),
                       ranged: SkillTreeBranchState(xp: ranged),
                       crafting: SkillTreeCraftingBranchState(
                        progress: SkillTreeBranchState(xp: crafting),
                        recipeMasteryCounts: mastery))
    }

    private func tree(_ id: SkillTreeID, xp: Int,
                      slots: [SkillTreeActionID: Int] = [:]) throws -> SkillsTreePresentation {
        try XCTUnwrap(makeSkillsPresentation(state: state(all: xp), context: context(slots: slots)).tree(id))
    }

    // MARK: - XP boundaries

    /// Exactly at each threshold the rank is reached; one XP below it is not.
    func testEveryThresholdBoundaryAndOneBelow() throws {
        let primary = [100, 250, 450, 700, 1_000]
        let advanced = [1_200, 1_450, 1_750, 2_100, 2_500]
        for id in SkillTreeID.allCases {
            for (index, threshold) in primary.enumerated() {
                let at = try tree(id, xp: threshold)
                XCTAssertEqual(at.primaryRank, index + 1, "\(id) at \(threshold)")
                XCTAssertEqual(at.advancedRank, 0, "\(id) at \(threshold)")
                let below = try tree(id, xp: threshold - 1)
                XCTAssertEqual(below.primaryRank, index, "\(id) at \(threshold - 1)")
                let belowNext = try XCTUnwrap(below.nextRank)
                XCTAssertEqual(belowNext.targetXP, threshold)
                XCTAssertEqual(belowNext.remainingXP, 1)
                XCTAssertEqual(belowNext.currentXP, threshold - 1)
                if threshold < 1_000 {
                    let atNext = try XCTUnwrap(at.nextRank)
                    XCTAssertEqual(atNext.currentXP, threshold)
                    XCTAssertEqual(atNext.fraction, 0, "a fresh rank band starts empty")
                }
            }
            for (index, threshold) in advanced.enumerated() {
                let at = try tree(id, xp: threshold)
                XCTAssertEqual(at.primaryRank, 5)
                XCTAssertEqual(at.advancedRank, index + 1, "\(id) at \(threshold)")
                let below = try tree(id, xp: threshold - 1)
                XCTAssertEqual(below.primaryRank, 5)
                XCTAssertEqual(below.advancedRank, index, "\(id) at \(threshold - 1)")
                let belowNext = try XCTUnwrap(below.nextRank)
                XCTAssertEqual(belowNext.targetXP, threshold)
                XCTAssertEqual(belowNext.remainingXP, 1)
                XCTAssertEqual(belowNext.title, "Advanced rank \(index + 1) · " + below.advancedRanks[index].title)
            }
        }
    }

    func testPrimaryCapOpensAdvancedTrackWithEmptyBand() throws {
        let melee = try tree(.melee, xp: 1_000)
        XCTAssertNil(melee.advancedLockNote)
        XCTAssertEqual(melee.statusText, "Advanced rank 0")
        XCTAssertEqual(melee.primaryRanks.map(\.status), Array(repeating: .earned, count: 5))
        XCTAssertEqual(melee.advancedRanks.map(\.status), [.next, .locked, .locked, .locked, .locked])
        let next = try XCTUnwrap(melee.nextRank)
        XCTAssertEqual(next.title, "Advanced rank 1 · Stun Enemy")
        XCTAssertEqual(next.currentXP, 1_000)
        XCTAssertEqual(next.targetXP, 1_200)
        XCTAssertEqual(next.remainingXP, 200)
        XCTAssertEqual(next.fraction, 0)
        XCTAssertEqual(next.hint, "About 50 sword hits")
    }

    func testOneBelowPrimaryCapLockNoteIsSingular() throws {
        let mining = try tree(.mining, xp: 999)
        XCTAssertEqual(mining.primaryRank, 4)
        XCTAssertEqual(mining.advancedLockNote, "Unlocks at primary rank 5 · 1 primary rank to go")
        XCTAssertEqual(mining.statusText, "Primary rank 4")
        XCTAssertEqual(try XCTUnwrap(mining.nextRank).fraction, 299.0 / 300.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(mining.nextRank).hint, "About 1 diamond or 1 iron ore")
    }

    func testNegativeXPClampsToUntrained() throws {
        for id in SkillTreeID.allCases {
            for xp in [-1, -500, Int.min] {
                let tree = try self.tree(id, xp: xp)
                XCTAssertEqual(tree.xp, 0, "\(id) \(xp)")
                XCTAssertEqual(tree.primaryRank, 0)
                XCTAssertEqual(tree.advancedRank, 0)
                let next = try XCTUnwrap(tree.nextRank)
                XCTAssertEqual(next.currentXP, 0)
                XCTAssertEqual(next.remainingXP, 100)
                XCTAssertEqual(next.fraction, 0)
            }
        }
    }

    func testXPAboveMaximumClampsToMastered() throws {
        for id in SkillTreeID.allCases {
            for xp in [2_500, 2_501, 10_000, Int.max] {
                let tree = try self.tree(id, xp: xp)
                XCTAssertEqual(tree.xp, 2_500, "\(id) \(xp)")
                XCTAssertTrue(tree.isMastered)
                XCTAssertNil(tree.nextRank)
                XCTAssertNil(tree.advancedLockNote)
                XCTAssertEqual(tree.statusText, "Mastered")
                XCTAssertEqual(tree.earnedRankCount, 10)
                XCTAssertTrue((tree.primaryRanks + tree.advancedRanks).allSatisfy { $0.status == .earned })
            }
        }
    }

    // MARK: - Per-tree copy

    func testEveryTreeNextRankTitleAndHintAtZero() throws {
        let expected: [SkillTreeID: (String, String?)] = [
            .mining: ("Primary rank 1 · Harvesting speed on stone and ore +10%", "About 17 diamond or 50 iron ore"),
            .melee: ("Primary rank 1 · Sword damage +10%", "About 25 sword hits"),
            .ranged: ("Primary rank 1 · Bow damage +10%", "About 25 bow hits"),
            .crafting: ("Primary rank 1 · Up to 2 rounds per craft", nil),
        ]
        for id in SkillTreeID.allCases {
            let next = try XCTUnwrap(try tree(id, xp: 0).nextRank)
            XCTAssertEqual(next.title, expected[id]?.0, "\(id)")
            XCTAssertEqual(next.hint, expected[id]?.1, "\(id)")
        }
    }

    func testPrimaryBenefitTitlesForEveryTree() throws {
        XCTAssertEqual(try tree(.mining, xp: 0).primaryRanks.map(\.title),
                       (1...5).map { "Harvesting speed on stone and ore +\($0 * 10)%" })
        XCTAssertEqual(try tree(.melee, xp: 0).primaryRanks.map(\.title),
                       (1...5).map { "Sword damage +\($0 * 10)%" })
        XCTAssertEqual(try tree(.ranged, xp: 0).primaryRanks.map(\.title),
                       (1...5).map { "Bow damage +\($0 * 10)%" })
        XCTAssertEqual(try tree(.crafting, xp: 0).primaryRanks.map(\.title),
                       [2, 4, 8, 16, 32].map { "Up to \($0) rounds per craft" })
        for id in SkillTreeID.allCases {
            let tree = try self.tree(id, xp: 0)
            XCTAssertTrue(tree.primaryRanks.allSatisfy { $0.detail == nil && $0.fastBarSlot == nil })
            XCTAssertEqual(tree.primaryRanks.map(\.id), (1...5).map { "\(id.rawValue).primary.\($0)" })
            XCTAssertEqual(tree.advancedRanks.map(\.id), (1...5).map { "\(id.rawValue).advanced.\($0)" })
            XCTAssertEqual(Set((tree.primaryRanks + tree.advancedRanks).map(\.id)).count, 10, "row IDs are unique")
        }
    }

    func testAdvancedBenefitTitlesAndDetailsForEveryTree() throws {
        let mining = try tree(.mining, xp: 0)
        XCTAssertEqual(mining.advancedRanks.map(\.title), (1...5).map { "Ore yield +\($0 * 10)%" })
        XCTAssertTrue(mining.advancedRanks.allSatisfy { $0.detail == nil })

        let melee = try tree(.melee, xp: 0)
        XCTAssertEqual(melee.advancedRanks.map(\.title),
                       ["Stun Enemy", "Spartan Kick", "Round House", "Disarm Enemy", "Battle Cry"])
        XCTAssertEqual(melee.advancedRanks.map(\.detail),
                       [SkillTreeActionID.stunEnemy, .spartanKick, .roundHouse, .disarmEnemy, .battleCry]
                        .map { skillsActionEffect(skillTreeActionDescriptor($0)) })

        let ranged = try tree(.ranged, xp: 0)
        XCTAssertEqual(ranged.advancedRanks.map(\.title),
                       ["Pinning Shot", "Power Shot", "Volley", "Disarming Shot", "Eagle Eye"])
        XCTAssertEqual(ranged.advancedRanks.map(\.detail),
                       [SkillTreeActionID.pinningShot, .powerShot, .volley, .disarmingShot, .eagleEye]
                        .map { skillsActionEffect(skillTreeActionDescriptor($0)) })

        let crafting = try tree(.crafting, xp: 0)
        XCTAssertEqual(crafting.advancedRanks.map(\.title),
                       ["Quality 1", "Quality 2", "Quality 3", "Quality 4", "Quality 5 and Field Repair"])
        XCTAssertEqual(crafting.advancedRanks.map(\.detail), [
            "Durability +10% · weapon damage +2.5% · repair +5%",
            "Durability +20% · weapon damage +5% · repair +10%",
            "Durability +35% · weapon damage +10% · repair +15%",
            "Durability +55% · weapon damage +15% · repair +20%",
            "Durability +80% · weapon damage +25% · repair +30%",
        ])
    }

    func testTreeCopyAndItemMasteryOnlyOnCrafting() throws {
        let presentation = makeSkillsPresentation(state: state(all: 0, mastery: [3]),
                                                  context: context(outputs: [42]))
        XCTAssertEqual(presentation.trees.map(\.name), ["Mining", "Melee", "Ranged", "Crafting"])
        XCTAssertEqual(presentation.trees.map(\.symbol),
                       ["hammer", "figure.fencing", "scope", "wrench.and.screwdriver"])
        XCTAssertEqual(presentation.trees.map(\.primaryTrackName),
                       ["Mining speed", "Sword damage", "Bow damage", "Batch size"])
        XCTAssertEqual(presentation.trees.map(\.advancedTrackName),
                       ["Ore yield", "Combat techniques", "Bow techniques", "Quality and repair"])
        for id in [SkillTreeID.mining, .melee, .ranged] {
            XCTAssertNil(presentation.tree(id)?.itemMastery, "\(id)")
        }
        XCTAssertEqual(presentation.tree(.crafting)?.itemMastery,
                       [SkillsItemMasteryRow(id: 42, name: "Item 42", crafts: 3)])
        XCTAssertTrue(try XCTUnwrap(presentation.tree(.crafting)).earningNote.contains("first 100 crafts"))
    }

    func testTreesAreIndependent() throws {
        let presentation = makeSkillsPresentation(state: state(mining: 99, melee: 1_000, ranged: 2_500, crafting: -3),
                                                  context: context())
        XCTAssertEqual(presentation.trees.map(\.primaryRank), [0, 5, 5, 0])
        XCTAssertEqual(presentation.trees.map(\.advancedRank), [0, 0, 5, 0])
        XCTAssertEqual(presentation.trees.map(\.xp), [99, 1_000, 2_500, 0])
        XCTAssertEqual(presentation.trees.map(\.isMastered), [false, false, true, false])
    }

    // MARK: - Rank status sequences

    func testRankStatusSequenceForEveryPrimaryAndAdvancedRank() throws {
        func expected(_ earned: Int, open: Bool = true) -> [SkillsRankStatus] {
            guard open else { return Array(repeating: .locked, count: 5) }
            return (1...5).map { $0 <= earned ? .earned : ($0 == earned + 1 ? .next : .locked) }
        }
        let primaryXP = [0, 100, 250, 450, 700]
        for id in SkillTreeID.allCases {
            for (rank, xp) in primaryXP.enumerated() {
                let tree = try self.tree(id, xp: xp)
                XCTAssertEqual(tree.primaryRanks.map(\.status), expected(rank), "\(id) primary \(rank)")
                XCTAssertEqual(tree.advancedRanks.map(\.status), expected(0, open: false), "\(id) primary \(rank)")
                XCTAssertEqual(tree.statusText, "Primary rank \(rank)")
                XCTAssertEqual(tree.advancedLockNote,
                               "Unlocks at primary rank 5 · \(5 - rank) primary \(5 - rank == 1 ? "rank" : "ranks") to go")
            }
            for (rank, xp) in [1_000, 1_200, 1_450, 1_750, 2_100, 2_500].enumerated() {
                let tree = try self.tree(id, xp: xp)
                XCTAssertEqual(tree.primaryRanks.map(\.status), expected(5), "\(id) advanced \(rank)")
                XCTAssertEqual(tree.advancedRanks.map(\.status), expected(rank), "\(id) advanced \(rank)")
                XCTAssertEqual(tree.statusText, rank == 5 ? "Mastered" : "Advanced rank \(rank)")
            }
        }
    }

    // MARK: - Fast bar

    func testFastBarSlotBoundaries() {
        let unlocked = state(melee: 2_500, ranged: 2_500, crafting: 2_500)
        let slots: [SkillTreeActionID: Int] = [
            .stunEnemy: 1, .spartanKick: 9, .roundHouse: 0, .disarmEnemy: 10, .battleCry: -1,
            .pinningShot: Int.min, .powerShot: Int.max, .fieldRepair: 5,
        ]
        let presentation = makeSkillsPresentation(state: unlocked, context: context(slots: slots))
        XCTAssertEqual(presentation.fastBar.map(\.action), [.stunEnemy, .fieldRepair, .spartanKick])
        XCTAssertEqual(presentation.fastBar.map(\.slot), [1, 5, 9])
        XCTAssertEqual(presentation.fastBar.map(\.name), ["Stun Enemy", "Field Repair", "Spartan Kick"])

        let melee = presentation.tree(.melee)
        XCTAssertEqual(melee?.advancedRanks.map(\.fastBarSlot), [1, 9, nil, nil, nil],
                       "rank rows apply the same 1...9 slot filter")
        XCTAssertEqual(presentation.tree(.crafting)?.advancedRanks.map(\.fastBarSlot), [nil, nil, nil, nil, 5])
        XCTAssertEqual(presentation.tree(.mining)?.advancedRanks.map(\.fastBarSlot), [nil, nil, nil, nil, nil])
    }

    func testFastBarExcludesLockedActionsPerRank() {
        let slots = Dictionary(uniqueKeysWithValues: SkillTreeActionID.allCases.enumerated().map {
            ($0.element, ($0.offset % 9) + 1)
        })
        for (rank, xp) in [999, 1_000, 1_200, 1_450, 1_750, 2_100, 2_500].enumerated() {
            let advanced = max(0, rank - 1)
            let presentation = makeSkillsPresentation(state: state(melee: xp, ranged: xp, crafting: xp),
                                                      context: context(slots: slots))
            let expected = SKILL_TREE_ACTION_DESCRIPTORS.filter {
                xp >= 1_000 && $0.advancedRankRequired <= advanced
            }.map(\.id)
            XCTAssertEqual(Set(presentation.fastBar.map(\.action)), Set(expected), "xp \(xp)")
            XCTAssertEqual(presentation.fastBar.map(\.slot), presentation.fastBar.map(\.slot).sorted())
            // Locked or next ranks never show a slot, even when the provider has one.
            for id in [SkillTreeID.melee, .ranged, .crafting] {
                for row in presentation.tree(id)?.advancedRanks ?? [] where row.status != .earned {
                    XCTAssertNil(row.fastBarSlot, "\(id) rank \(row.number) at xp \(xp)")
                }
            }
        }
    }

    func testFastBarDuplicateSlotsKeepDescriptorOrder() {
        let presentation = makeSkillsPresentation(
            state: state(melee: 2_500, ranged: 2_500),
            context: context(slots: [.eagleEye: 2, .battleCry: 2, .pinningShot: 2, .stunEnemy: 2, .volley: 1]))
        XCTAssertEqual(presentation.fastBar.map(\.slot), [1, 2, 2, 2, 2])
        XCTAssertEqual(presentation.fastBar.map(\.action),
                       [.volley, .stunEnemy, .pinningShot, .battleCry, .eagleEye])
        // Determinism: repeated projections are identical.
        for _ in 0..<20 {
            XCTAssertEqual(makeSkillsPresentation(
                state: state(melee: 2_500, ranged: 2_500),
                context: context(slots: [.eagleEye: 2, .battleCry: 2, .pinningShot: 2, .stunEnemy: 2, .volley: 1])),
                presentation)
        }
    }

    func testFastBarEmptyWithoutSlotsEvenWhenEverythingIsUnlocked() {
        let presentation = makeSkillsPresentation(state: state(all: 2_500), context: context())
        XCTAssertTrue(presentation.fastBar.isEmpty)
        XCTAssertTrue(presentation.trees.flatMap(\.advancedRanks).allSatisfy { $0.fastBarSlot == nil })
    }

    func testForgedStoredRanksDoNotUnlockFastBar() {
        var raw = state()
        raw.melee = SkillTreeBranchState(xp: 10, primaryRank: 5, advancedRank: 5)
        let presentation = makeSkillsPresentation(state: raw, context: context(slots: [.stunEnemy: 1, .battleCry: 2]))
        XCTAssertTrue(presentation.fastBar.isEmpty)
        XCTAssertEqual(presentation.tree(.melee)?.advancedRanks.map(\.fastBarSlot), [nil, nil, nil, nil, nil])
    }

    // MARK: - Item mastery

    func testItemMasteryCountsLongerThanOutputsAreIgnored() {
        let rows = skillsItemMastery(counts: [5, 6, 7, 8], context: context(outputs: [1, 2]))
        XCTAssertEqual(rows.map(\.id), [2, 1])
        XCTAssertEqual(rows.map(\.crafts), [6, 5])
    }

    func testItemMasteryCountsShorterThanOutputsUsePrefix() {
        let rows = skillsItemMastery(counts: [5], context: context(outputs: [1, 2, 3]))
        XCTAssertEqual(rows, [SkillsItemMasteryRow(id: 1, name: "Item 1", crafts: 5)])
    }

    func testItemMasteryEmptyAndZeroInputs() {
        XCTAssertEqual(skillsItemMastery(counts: [], context: context(outputs: [1, 2])), [])
        XCTAssertEqual(skillsItemMastery(counts: [1, 2], context: context(outputs: [])), [])
        XCTAssertEqual(skillsItemMastery(counts: [0, 0, 0], context: context(outputs: [1, 2, 3])), [])
    }

    func testItemMasteryFoldIsOrderIndependentAcrossThreeAlternates() {
        let triples: [[UInt8]] = [[70, 20, 30], [10, 20, 30], [100, 0, 1], [255, 255, 255], [33, 33, 34]]
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for triple in triples {
            let expected = min(SKILL_TREE_RECIPE_MASTERY_CAP, triple.reduce(0) { $0 + Int($1) })
            for order in permutations {
                let counts = order.map { triple[$0] }
                let rows = skillsItemMastery(counts: counts, context: context(outputs: [9, 9, 9]))
                XCTAssertEqual(rows.map(\.crafts), [expected], "\(counts)")
                XCTAssertEqual(rows.first?.isMastered, expected == 100)
            }
        }
    }

    func testItemMasteryCapBoundary() {
        let rows = skillsItemMastery(counts: [99, 100, 101, 255, 1],
                                     context: context(outputs: [1, 2, 3, 4, 5]))
        XCTAssertEqual(rows.map(\.id), [2, 3, 4, 1, 5])
        XCTAssertEqual(rows.map(\.crafts), [100, 100, 100, 99, 1])
        XCTAssertEqual(rows.map(\.isMastered), [true, true, true, false, false])
    }

    func testItemMasteryTiesOrderByFirstRecordedRecipeIndex() {
        // Item 30's first recipe (index 0) has no crafts, so its position is index 3.
        let rows = skillsItemMastery(counts: [0, 4, 4, 4, 4, 9],
                                     context: context(outputs: [30, 20, 10, 30, 40, 50]))
        XCTAssertEqual(rows.map(\.id), [50, 20, 10, 30, 40])
        XCTAssertEqual(rows.map(\.crafts), [9, 4, 4, 4, 4])
        // Same input in any number of runs gives the same order (no hash-order dependence).
        for _ in 0..<50 {
            XCTAssertEqual(skillsItemMastery(counts: [0, 4, 4, 4, 4, 9],
                                             context: context(outputs: [30, 20, 10, 30, 40, 50])), rows)
        }
    }

    func testItemMasteryUsesContextNames() {
        let ctx = SkillsPresentationContext(quickSlot: { _ in nil }, recipeOutputItemIDs: [7, -1],
                                            itemName: { $0 == 7 ? "Iron Pickaxe" : "Unknown item" },
                                            isLANGuest: false)
        XCTAssertEqual(skillsItemMastery(counts: [2, 1], context: ctx).map(\.name), ["Iron Pickaxe", "Unknown item"])
    }

    /// Seeded property: aggregation equals an independent per-item sum-then-cap, and every item
    /// with a non-zero count appears exactly once.
    func testItemMasteryMatchesReferenceFoldForSeededInputs() {
        for seed in UInt64(1)...200 {
            var rng = SplitMix64(seed: seed)
            let outputCount = Int(rng.next() % 40)
            let countLength = Int(rng.next() % 45)
            let outputs = (0..<outputCount).map { _ in Int(rng.next() % 8) }
            let counts = (0..<countLength).map { _ in rng.next() % 3 == 0 ? UInt8(0) : UInt8(truncatingIfNeeded: rng.next()) }
            let rows = skillsItemMastery(counts: counts, context: context(outputs: outputs))

            var reference: [Int: Int] = [:]
            for index in 0..<min(outputs.count, counts.count) where counts[index] > 0 {
                reference[outputs[index], default: 0] += Int(counts[index])
            }
            XCTAssertEqual(rows.count, reference.count, "seed \(seed)")
            XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "seed \(seed): duplicate rows")
            for row in rows {
                XCTAssertEqual(row.crafts, min(100, reference[row.id] ?? -1), "seed \(seed) item \(row.id)")
                XCTAssertTrue((1...100).contains(row.crafts), "seed \(seed)")
            }
            XCTAssertEqual(rows.map(\.crafts), rows.map(\.crafts).sorted(by: >), "seed \(seed): crafts descending")
            XCTAssertEqual(skillsItemMastery(counts: counts, context: context(outputs: outputs)), rows,
                           "seed \(seed): deterministic")
        }
    }

    // MARK: - Action effects

    func testActionEffectStringsForAllDescriptors() {
        let expected: [SkillTreeActionID: String] = [
            .stunEnemy: "Stops a target’s actions and movement for 30 seconds",
            .pinningShot: "Stops a target’s actions and movement for 30 seconds",
            .spartanKick: "1.5× sword damage and a shove of up to 5 blocks",
            .powerShot: "1.5× bow damage and a shove of up to 5 blocks",
            .roundHouse: "1× sword damage to every hostile around you",
            .volley: "1× bow damage to every hostile around the aimed target",
            .disarmEnemy: "The target drops its equipped items",
            .disarmingShot: "The target drops its equipped items",
            .battleCry: "3× sword damage · 2-minute cooldown",
            .eagleEye: "3× bow damage · 2-minute cooldown",
            .fieldRepair: "Restores a quarter of a damaged item’s durability with its repair material · 30-second cooldown",
        ]
        XCTAssertEqual(SKILL_TREE_ACTION_DESCRIPTORS.count, 11)
        XCTAssertEqual(Set(expected.keys), Set(SkillTreeActionID.allCases))
        for descriptor in SKILL_TREE_ACTION_DESCRIPTORS {
            XCTAssertEqual(skillsActionEffect(descriptor), expected[descriptor.id], "\(descriptor.id)")
        }
    }

    func testActionEffectFormattingBranchesOnSyntheticDescriptors() {
        func effect(_ multiplier: Double = 1, stun: Int = 0, push: Int = 0, cooldown: Int = 0,
                    equipment: SkillTreeActionEquipment = .sword) -> String {
            skillsActionEffect(SkillTreeActionDescriptor(
                id: .battleCry, tree: .melee, displayName: "Test", advancedRankRequired: 5,
                equipment: equipment, targeting: .hostileRay, weaponDamageMultiplier: multiplier,
                stunDurationTicks: stun, pushDistanceBlocks: push, cooldownTicks: cooldown))
        }
        XCTAssertEqual(effect(stun: 1_200), "Stops a target’s actions and movement for 1 minute")
        XCTAssertEqual(effect(stun: 3_600), "Stops a target’s actions and movement for 3 minutes")
        XCTAssertEqual(effect(stun: 1_300), "Stops a target’s actions and movement for 65 seconds")
        XCTAssertEqual(effect(cooldown: 1_200), "1× sword damage · 1-minute cooldown")
        XCTAssertEqual(effect(cooldown: 1_300), "1× sword damage · 65-second cooldown")
        XCTAssertEqual(effect(2.25, equipment: .none), "2.25× sword damage")
        XCTAssertEqual(effect(0, equipment: .bow), "0× bow damage")
        XCTAssertEqual(effect(push: 2, cooldown: 20), "1× sword damage and a shove of up to 2 blocks · 1-second cooldown")
    }

    // MARK: - Earning

    func testMiningEarningCoversEveryHarvestableResourceOnceAndExcludesLabradorite() throws {
        let mining = try tree(.mining, xp: 0)
        let joined = mining.earning.map(\.label).joined(separator: ", ").lowercased()
        XCTAssertFalse(joined.contains("labradorite"))
        let names = joined.components(separatedBy: ", ")
        XCTAssertEqual(names.count, SkillTreeMiningResource.allCases.count - 1)
        XCTAssertEqual(Set(names).count, names.count, "each resource listed once")
        XCTAssertEqual(Set(mining.earning.map(\.id)).count, mining.earning.count, "row IDs unique")
        let values = mining.earning.map(\.value)
        XCTAssertEqual(values, values.sorted { Int($0.prefix { $0.isNumber })! < Int($1.prefix { $0.isNumber })! })
        // Every non-labradorite XP amount is represented.
        let amounts = Set(SkillTreeMiningResource.allCases.filter { $0 != .labradorite }.map(skillTreeMiningXP(for:)))
        XCTAssertEqual(Set(values), Set(amounts.map { "\($0) XP" }))
    }

    func testCombatAndCraftingEarningRows() throws {
        XCTAssertEqual(try tree(.melee, xp: 0).earning,
                       [SkillsEarningRow(label: "Sword hit on an animal or hostile enemy", value: "4 XP")])
        XCTAssertEqual(try tree(.ranged, xp: 0).earning,
                       [SkillsEarningRow(label: "Bow hit on an animal or hostile enemy", value: "4 XP")])
        XCTAssertEqual(try tree(.crafting, xp: 0).earning.map(\.value),
                       ["Tier 1", "Tier 2", "Tier 3", "Tier 4", "Tier 5"])
    }

    // MARK: - XP sweep property

    func testXPSweepInvariantsForEveryTree() {
        let allSlots = Dictionary(uniqueKeysWithValues: SkillTreeActionID.allCases.enumerated().map {
            ($0.element, ($0.offset % 9) + 1)
        })
        var previousEarned: [SkillTreeID: Int] = [:]
        for xp in -10...2_600 {
            let presentation = makeSkillsPresentation(state: state(all: xp), context: context(slots: allSlots))
            XCTAssertEqual(presentation.trees.map(\.id), SkillTreeID.allCases)
            let clamped = min(max(xp, 0), 2_500)
            for tree in presentation.trees {
                let label = "\(tree.id) xp \(xp)"
                let ranks = tree.primaryRanks + tree.advancedRanks
                XCTAssertEqual(tree.xp, clamped, label)
                XCTAssertEqual(tree.primaryRank, skillTreePrimaryRank(forXP: xp), label)
                XCTAssertEqual(tree.advancedRank, skillTreeAdvancedRank(forXP: xp), label)

                let thresholds = ranks.map(\.thresholdXP)
                XCTAssertEqual(thresholds, thresholds.sorted(), label)
                XCTAssertEqual(Set(thresholds).count, thresholds.count, "strictly increasing: \(label)")

                let earned = ranks.filter { $0.status == .earned }.count
                XCTAssertEqual(earned, tree.primaryRank + tree.advancedRank, label)
                XCTAssertEqual(earned, tree.earnedRankCount, label)
                for rank in ranks {
                    if rank.status == .earned {
                        XCTAssertLessThanOrEqual(rank.thresholdXP, clamped, label)
                    } else {
                        XCTAssertGreaterThan(rank.thresholdXP, clamped, label)
                    }
                }
                // Earned ranks form a prefix of the combined track.
                XCTAssertTrue(ranks.prefix(earned).allSatisfy { $0.status == .earned }, label)

                let nextRows = ranks.filter { $0.status == .next }
                XCTAssertEqual((tree.advancedLockNote == nil), tree.primaryRank == 5, label)
                if tree.isMastered {
                    XCTAssertEqual(nextRows.count, 0, label)
                    XCTAssertNil(tree.nextRank, label)
                    XCTAssertEqual(clamped, 2_500, label)
                } else {
                    XCTAssertEqual(nextRows.count, 1, label)
                    XCTAssertEqual(ranks.firstIndex { $0.status != .earned }, earned, label)
                    guard let next = tree.nextRank, let nextRow = nextRows.first else {
                        XCTFail("missing next rank: \(label)"); continue
                    }
                    XCTAssertEqual(next.targetXP, nextRow.thresholdXP, label)
                    XCTAssertTrue(next.title.hasSuffix(" · " + nextRow.title), label)
                    XCTAssertEqual(next.currentXP, clamped, label)
                    XCTAssertEqual(next.remainingXP, next.targetXP - next.currentXP, label)
                    XCTAssertGreaterThan(next.remainingXP, 0, label)
                    XCTAssertTrue((0...1).contains(next.fraction), label)
                    XCTAssertLessThan(next.fraction, 1, label)
                    XCTAssertEqual(next.hint == nil, tree.id == .crafting, label)
                }
                XCTAssertGreaterThanOrEqual(earned, previousEarned[tree.id] ?? 0, "monotonic: \(label)")
                previousEarned[tree.id] = earned
            }
            XCTAssertEqual(presentation, makeSkillsPresentation(state: state(all: xp), context: context(slots: allSlots)),
                           "deterministic at xp \(xp)")
        }
    }

    // MARK: - Native refresh inputs

    /// Mirrors SkillTreeScreen.makeNativePresentation: the presentation is a function of the
    /// inputs (state, per-descriptor quick slots, LAN role) plus the static recipe registry.
    private func presentation(from inputs: SkillsNativeInputs, outputs: [Int] = [1, 2, 2]) -> SkillsPresentation {
        let slotByAction = Dictionary(uniqueKeysWithValues: zip(SKILL_TREE_ACTION_DESCRIPTORS.map(\.id), inputs.quickSlots))
        let ctx = SkillsPresentationContext(quickSlot: { slotByAction[$0] ?? nil },
                                            recipeOutputItemIDs: outputs,
                                            itemName: { "Item \($0)" },
                                            isLANGuest: inputs.isLANGuest)
        return makeSkillsPresentation(state: inputs.state, context: ctx)
    }

    private func inputs(_ state: SkillTreeState, slots: [SkillTreeActionID: Int] = [:],
                        guest: Bool = false) -> SkillsNativeInputs {
        SkillsNativeInputs(state: state, quickSlots: SKILL_TREE_ACTION_DESCRIPTORS.map { slots[$0.id] },
                           isLANGuest: guest)
    }

    func testEqualNativeInputsGiveEqualPresentation() {
        let a = inputs(state(mining: 300, melee: 1_800, ranged: 2_200, crafting: 1_000, mastery: [4, 5, 6]),
                       slots: [.stunEnemy: 1, .pinningShot: 3], guest: true)
        let b = inputs(state(mining: 300, melee: 1_800, ranged: 2_200, crafting: 1_000, mastery: [4, 5, 6]),
                       slots: [.pinningShot: 3, .stunEnemy: 1], guest: true)
        XCTAssertEqual(a, b)
        XCTAssertEqual(presentation(from: a), presentation(from: b))
    }

    /// Every change that alters the presentation must also change the inputs, otherwise the
    /// window would keep showing stale values.
    func testEveryPresentationChangeIsVisibleInNativeInputs() {
        let base = inputs(state(mining: 300, melee: 1_800, ranged: 2_200, crafting: 1_000, mastery: [4, 5, 6]),
                          slots: [.stunEnemy: 1, .pinningShot: 3])
        var variants: [(String, SkillsNativeInputs)] = []
        var s = base.state; s.mining.xp += 1; variants.append(("mining xp", inputs(s, slots: [.stunEnemy: 1, .pinningShot: 3])))
        s = base.state; s.melee.xp -= 1; variants.append(("melee xp", inputs(s, slots: [.stunEnemy: 1, .pinningShot: 3])))
        s = base.state; s.ranged.xp = 2_500; variants.append(("ranged xp", inputs(s, slots: [.stunEnemy: 1, .pinningShot: 3])))
        s = base.state; s.crafting.progress.xp = 1_200; variants.append(("crafting xp", inputs(s, slots: [.stunEnemy: 1, .pinningShot: 3])))
        s = base.state; s.crafting.recipeMasteryCounts = [4, 5, 7]; variants.append(("mastery", inputs(s, slots: [.stunEnemy: 1, .pinningShot: 3])))
        variants.append(("slot moved", inputs(base.state, slots: [.stunEnemy: 2, .pinningShot: 3])))
        variants.append(("slot cleared", inputs(base.state, slots: [.pinningShot: 3])))
        variants.append(("slot added", inputs(base.state, slots: [.stunEnemy: 1, .pinningShot: 3, .spartanKick: 4])))
        variants.append(("LAN role", SkillsNativeInputs(state: base.state, quickSlots: base.quickSlots, isLANGuest: true)))

        let basePresentation = presentation(from: base)
        for (name, variant) in variants {
            XCTAssertNotEqual(variant, base, name)
            XCTAssertNotEqual(presentation(from: variant), basePresentation, "\(name) should re-render")
        }
    }

    /// Forged rank fields change the inputs (an extra, harmless refresh) but not what is shown.
    func testForgedRankFieldsRefreshButRenderTheSame() {
        let honest = inputs(state(melee: 1_800))
        var forgedState = honest.state
        forgedState.melee.primaryRank = 0
        forgedState.melee.advancedRank = 5
        let forged = inputs(forgedState)
        XCTAssertNotEqual(honest, forged)
        XCTAssertEqual(presentation(from: honest), presentation(from: forged))
    }
}

/// Small deterministic PRNG so seeded property failures replay exactly.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
