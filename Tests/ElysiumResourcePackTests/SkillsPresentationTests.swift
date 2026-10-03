import XCTest
@testable import Elysium
@testable import ElysiumCore

final class SkillsPresentationTests: XCTestCase {
    private func context(slots: [SkillTreeActionID: Int] = [:],
                         outputs: [Int] = [],
                         isLANGuest: Bool = false) -> SkillsPresentationContext {
        SkillsPresentationContext(quickSlot: { slots[$0] },
                                  recipeOutputItemIDs: outputs,
                                  itemName: { "Item \($0)" },
                                  isLANGuest: isLANGuest)
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

    func testUntrainedTreeOffersFirstPrimaryRankAndLocksAdvancedRanks() throws {
        let presentation = makeSkillsPresentation(state: state(), context: context())
        XCTAssertEqual(presentation.trees.map(\.id), [.mining, .melee, .ranged, .crafting])
        let mining = try XCTUnwrap(presentation.tree(.mining))
        XCTAssertEqual(mining.primaryRanks.map(\.status), [.next, .locked, .locked, .locked, .locked])
        XCTAssertTrue(mining.advancedRanks.allSatisfy { $0.status == .locked })
        XCTAssertEqual(mining.advancedLockNote, "Unlocks at primary rank 5 · 5 primary ranks to go")
        let next = try XCTUnwrap(mining.nextRank)
        XCTAssertEqual(next.title, "Primary rank 1 · Harvesting speed on stone and ore +10%")
        XCTAssertEqual(next.targetXP, 100)
        XCTAssertEqual(next.remainingXP, 100)
        XCTAssertEqual(next.fraction, 0)
        XCTAssertEqual(mining.statusText, "Primary rank 0")
    }

    func testRankThresholdsUseOneCumulativeXPScale() throws {
        let tree = try XCTUnwrap(makeSkillsPresentation(state: state(), context: context()).tree(.melee))
        XCTAssertEqual(tree.primaryRanks.map(\.thresholdXP), [100, 250, 450, 700, 1_000])
        XCTAssertEqual(tree.advancedRanks.map(\.thresholdXP), [1_200, 1_450, 1_750, 2_100, 2_500])
    }

    func testAdvancedMeleeShowsTechniquesFastBarSlotsAndNextTechnique() throws {
        let presentation = makeSkillsPresentation(
            state: state(melee: 1_800),
            context: context(slots: [.stunEnemy: 1, .spartanKick: 2, .roundHouse: 3]))
        let melee = try XCTUnwrap(presentation.tree(.melee))
        XCTAssertEqual(melee.primaryRank, 5)
        XCTAssertEqual(melee.advancedRank, 3)
        XCTAssertNil(melee.advancedLockNote)
        XCTAssertEqual(melee.advancedRanks.map(\.status), [.earned, .earned, .earned, .next, .locked])
        XCTAssertEqual(melee.advancedRanks.map(\.title),
                       ["Stun Enemy", "Spartan Kick", "Round House", "Disarm Enemy", "Battle Cry"])
        XCTAssertEqual(melee.advancedRanks.map(\.fastBarSlot), [1, 2, 3, nil, nil])
        let next = try XCTUnwrap(melee.nextRank)
        XCTAssertEqual(next.title, "Advanced rank 4 · Disarm Enemy")
        XCTAssertEqual(next.remainingXP, 300)
        XCTAssertEqual(next.fraction, 50.0 / 350.0, accuracy: 1e-9)
        XCTAssertEqual(next.hint, "About 75 sword hits")
        XCTAssertEqual(presentation.fastBar.map(\.slot), [1, 2, 3])
        XCTAssertEqual(presentation.fastBar.map(\.name), ["Stun Enemy", "Spartan Kick", "Round House"])
    }

    func testMasteredTreeHasNoNextRank() throws {
        let crafting = try XCTUnwrap(
            makeSkillsPresentation(state: state(crafting: 2_500), context: context()).tree(.crafting))
        XCTAssertTrue(crafting.isMastered)
        XCTAssertNil(crafting.nextRank)
        XCTAssertEqual(crafting.statusText, "Mastered")
        XCTAssertEqual(crafting.earnedRankCount, 10)
        XCTAssertEqual(crafting.advancedRanks.last?.title, "Quality 5 and Field Repair")
        XCTAssertEqual(crafting.advancedRanks.first?.detail,
                       "Durability +10% · weapon damage +2.5% · repair +5%")
    }

    func testStoredRanksAreRederivedFromXP() throws {
        var raw = state()
        raw.ranged = SkillTreeBranchState(xp: 0, primaryRank: 5, advancedRank: 5)
        let ranged = try XCTUnwrap(makeSkillsPresentation(state: raw, context: context()).tree(.ranged))
        XCTAssertEqual(ranged.primaryRank, 0)
        XCTAssertEqual(ranged.advancedRank, 0)
        XCTAssertFalse(ranged.isMastered)
    }

    func testFastBarIgnoresLockedActionsAndOutOfRangeSlots() {
        let presentation = makeSkillsPresentation(
            state: state(melee: 1_200, ranged: 1_200),
            context: context(slots: [.pinningShot: 0, .stunEnemy: 4, .battleCry: 5]))
        XCTAssertEqual(presentation.fastBar.map(\.action), [.stunEnemy])
    }

    func testItemMasteryFoldsAlternateRecipesAndCapsEachItem() {
        let rows = skillsItemMastery(counts: [0, 60, 50, 100, 3, 9],
                                     context: context(outputs: [7, 8, 8, 9, 10]))
        XCTAssertEqual(rows.map(\.id), [8, 9, 10])
        XCTAssertEqual(rows.map(\.crafts), [100, 100, 3])
        XCTAssertEqual(rows.map(\.isMastered), [true, true, false])
        XCTAssertEqual(rows.first?.name, "Item 8")
    }

    func testActionEffectsComeFromDescriptors() {
        XCTAssertEqual(skillsActionEffect(skillTreeActionDescriptor(.stunEnemy)),
                       "Stops a target’s actions and movement for 30 seconds")
        XCTAssertEqual(skillsActionEffect(skillTreeActionDescriptor(.spartanKick)),
                       "1.5× sword damage and a shove of up to 5 blocks")
        XCTAssertEqual(skillsActionEffect(skillTreeActionDescriptor(.volley)),
                       "1× bow damage to every hostile around the aimed target")
        XCTAssertEqual(skillsActionEffect(skillTreeActionDescriptor(.battleCry)),
                       "3× sword damage · 2-minute cooldown")
    }

    func testMiningEarningRowsGroupResourcesByXP() throws {
        let mining = try XCTUnwrap(makeSkillsPresentation(state: state(), context: context()).tree(.mining))
        XCTAssertEqual(mining.earning.map(\.label), [
            "Coal, copper, iron, nether quartz",
            "Lapis, amethyst, emerald",
            "Nether gold, gold, redstone, diamond, ancient debris",
        ])
        XCTAssertEqual(mining.earning.map(\.value), ["2 XP", "4 XP", "6 XP"])
    }

    func testLANGuestFlagIsCarried() {
        XCTAssertTrue(makeSkillsPresentation(state: state(), context: context(isLANGuest: true)).isLANGuest)
    }
}
