// SkillsPresentation — the pure, value-typed projection the native Skills window renders.
//
// Every number here is derived from an authoritative `SkillTreeState` through the ElysiumCore
// progression functions (XP thresholds, rank benefits, action descriptors, mastery cap), so the
// window cannot drift from the rules the simulation applies. Nothing in this file reads or writes
// a player, a save, or a LAN peer.

import Foundation
import ElysiumCore

/// Where one rank sits relative to the player's progress.
enum SkillsRankStatus: Equatable {
    case earned
    case next
    case locked
}

/// One rank row: primary ranks 1–5, or advanced ranks 1–5 after the primary cap.
struct SkillsRankPresentation: Equatable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let detail: String?
    /// Cumulative tree XP at which this rank is reached.
    let thresholdXP: Int
    let status: SkillsRankStatus
    /// One-based action fast-bar slot for an unlocked action this rank grants.
    let fastBarSlot: Int?
}

/// The progress toward the next rank, or `nil` once a tree is mastered.
struct SkillsNextRankPresentation: Equatable {
    let title: String
    let currentXP: Int
    let targetXP: Int
    let remainingXP: Int
    /// Progress inside the current rank band, 0...1.
    let fraction: Double
    let hint: String?
}

/// One output item's crafting mastery, aggregated across every recipe that makes it.
struct SkillsItemMasteryRow: Equatable, Identifiable {
    let id: Int
    let name: String
    let crafts: Int
    var isMastered: Bool { crafts >= SKILL_TREE_RECIPE_MASTERY_CAP }
}

struct SkillsEarningRow: Equatable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

struct SkillsTreePresentation: Equatable, Identifiable {
    let id: SkillTreeID
    let name: String
    let summary: String
    let symbol: String
    let xp: Int
    let primaryRank: Int
    let advancedRank: Int
    let primaryTrackName: String
    let advancedTrackName: String
    let primaryRanks: [SkillsRankPresentation]
    let advancedRanks: [SkillsRankPresentation]
    let nextRank: SkillsNextRankPresentation?
    /// Present while the advanced ranks are still closed.
    let advancedLockNote: String?
    let earning: [SkillsEarningRow]
    let earningNote: String
    /// Crafting only: per-item mastery rows that have at least one recorded craft.
    let itemMastery: [SkillsItemMasteryRow]?

    var isMastered: Bool {
        primaryRank == SKILL_TREE_PRIMARY_RANK_CAP && advancedRank == SKILL_TREE_ADVANCED_RANK_CAP
    }

    var earnedRankCount: Int { primaryRank + advancedRank }

    var statusText: String {
        if isMastered { return "Mastered" }
        if primaryRank < SKILL_TREE_PRIMARY_RANK_CAP { return "Primary rank \(primaryRank)" }
        return "Advanced rank \(advancedRank)"
    }
}

/// One unlocked action and its action fast-bar slot.
struct SkillsFastBarEntry: Equatable, Identifiable {
    var id: SkillTreeActionID { action }
    let action: SkillTreeActionID
    let name: String
    let slot: Int
}

struct SkillsPresentation: Equatable {
    let trees: [SkillsTreePresentation]
    let fastBar: [SkillsFastBarEntry]
    /// The local player is a guest in another player's LAN world; the host owns progress.
    let isLANGuest: Bool

    func tree(_ id: SkillTreeID) -> SkillsTreePresentation? {
        trees.first { $0.id == id }
    }
}

/// Inputs the presentation needs beyond the tree state. Kept as plain values and closures so the
/// projection is testable without a world, a registry, or AppKit.
struct SkillsPresentationContext {
    /// One-based fast-bar slot for an action, or `nil` while it has no slot.
    var quickSlot: (SkillTreeActionID) -> Int?
    /// Output item ID per registered crafting recipe index (append-only registry order).
    var recipeOutputItemIDs: [Int]
    /// Display name for an item ID.
    var itemName: (Int) -> String
    var isLANGuest: Bool
}

func makeSkillsPresentation(state rawState: SkillTreeState,
                            context: SkillsPresentationContext) -> SkillsPresentation {
    let trees = SkillTreeID.allCases.map { id -> SkillsTreePresentation in
        let branch: SkillTreeBranchState
        switch id {
        case .mining: branch = skillTreeValidatedBranchState(rawState.mining)
        case .melee: branch = skillTreeValidatedBranchState(rawState.melee)
        case .ranged: branch = skillTreeValidatedBranchState(rawState.ranged)
        case .crafting: branch = skillTreeValidatedBranchState(rawState.crafting.progress)
        }
        let mastery = id == .crafting
            ? skillsItemMastery(counts: rawState.crafting.recipeMasteryCounts, context: context)
            : nil
        return skillsTreePresentation(id, branch: branch, quickSlot: context.quickSlot,
                                      itemMastery: mastery)
    }

    var slotted: [(order: Int, entry: SkillsFastBarEntry)] = []
    let validated = skillTreeValidatedState(rawState, recipeCount: context.recipeOutputItemIDs.count)
    for (order, descriptor) in skillTreeUnlockedActions(in: validated).enumerated() {
        guard let slot = context.quickSlot(descriptor.id),
              (1...RPG_ACTION_QUICK_SLOT_COUNT).contains(slot) else { continue }
        slotted.append((order, SkillsFastBarEntry(action: descriptor.id, name: descriptor.displayName,
                                                  slot: slot)))
    }
    // Slot order, then descriptor order, so shared slots never depend on sort stability.
    let fastBar = slotted.sorted {
        $0.entry.slot != $1.entry.slot ? $0.entry.slot < $1.entry.slot : $0.order < $1.order
    }.map(\.entry)
    return SkillsPresentation(trees: trees, fastBar: fastBar, isLANGuest: context.isLANGuest)
}

/// Cumulative XP needed for an advanced rank. Core stores advanced thresholds relative to the
/// primary cap; the window shows one continuous XP scale.
func skillsCumulativeAdvancedXP(forRank rank: Int) -> Int {
    skillTreePrimaryXPRequired(forRank: SKILL_TREE_PRIMARY_RANK_CAP)
        + skillTreeAdvancedXPRequired(forRank: rank)
}

private func skillsTreePresentation(_ id: SkillTreeID,
                                    branch: SkillTreeBranchState,
                                    quickSlot: (SkillTreeActionID) -> Int?,
                                    itemMastery: [SkillsItemMasteryRow]?) -> SkillsTreePresentation {
    let primaryRank = branch.primaryRank
    let advancedOpen = primaryRank == SKILL_TREE_PRIMARY_RANK_CAP
    let advancedRank = advancedOpen ? branch.advancedRank : 0
    let mastered = advancedOpen && advancedRank == SKILL_TREE_ADVANCED_RANK_CAP

    let primaryRanks = (1...SKILL_TREE_PRIMARY_RANK_CAP).map { rank -> SkillsRankPresentation in
        let status: SkillsRankStatus = rank <= primaryRank
            ? .earned : (rank == primaryRank + 1 ? .next : .locked)
        return SkillsRankPresentation(
            id: "\(id.rawValue).primary.\(rank)", number: rank,
            title: skillsPrimaryBenefit(id, rank: rank), detail: nil,
            thresholdXP: skillTreePrimaryXPRequired(forRank: rank),
            status: status, fastBarSlot: nil)
    }

    let advancedRanks = (1...SKILL_TREE_ADVANCED_RANK_CAP).map { rank -> SkillsRankPresentation in
        let status: SkillsRankStatus
        if !advancedOpen { status = .locked }
        else if rank <= advancedRank { status = .earned }
        else if rank == advancedRank + 1 { status = .next }
        else { status = .locked }
        let action = skillsAction(for: id, advancedRank: rank)
        let slot = status == .earned ? action.flatMap { quickSlot($0.id) } : nil
        let benefit = skillsAdvancedBenefit(id, rank: rank, action: action)
        return SkillsRankPresentation(
            id: "\(id.rawValue).advanced.\(rank)", number: rank,
            title: benefit.title, detail: benefit.detail,
            thresholdXP: skillsCumulativeAdvancedXP(forRank: rank),
            status: status,
            fastBarSlot: slot.flatMap { (1...RPG_ACTION_QUICK_SLOT_COUNT).contains($0) ? $0 : nil })
    }

    var nextRank: SkillsNextRankPresentation?
    if !mastered {
        let lower: Int
        let upper: Int
        let title: String
        if !advancedOpen {
            lower = skillTreePrimaryXPRequired(forRank: primaryRank)
            upper = skillTreePrimaryXPRequired(forRank: primaryRank + 1)
            title = "Primary rank \(primaryRank + 1) · " + primaryRanks[primaryRank].title
        } else {
            lower = skillsCumulativeAdvancedXP(forRank: advancedRank)
            upper = skillsCumulativeAdvancedXP(forRank: advancedRank + 1)
            title = "Advanced rank \(advancedRank + 1) · " + advancedRanks[advancedRank].title
        }
        let xp = min(max(branch.xp, lower), upper)
        let band = max(1, upper - lower)
        nextRank = SkillsNextRankPresentation(
            title: title, currentXP: xp, targetXP: upper, remainingXP: upper - xp,
            fraction: Double(xp - lower) / Double(band),
            hint: skillsEffortHint(id, remainingXP: upper - xp))
    }

    let lockNote: String?
    if advancedOpen {
        lockNote = nil
    } else {
        let remaining = SKILL_TREE_PRIMARY_RANK_CAP - primaryRank
        lockNote = "Unlocks at primary rank \(SKILL_TREE_PRIMARY_RANK_CAP) · "
            + "\(remaining) primary \(remaining == 1 ? "rank" : "ranks") to go"
    }

    let copy = skillsTreeCopy(id)
    return SkillsTreePresentation(
        id: id, name: copy.name, summary: copy.summary, symbol: copy.symbol,
        xp: branch.xp, primaryRank: primaryRank, advancedRank: advancedRank,
        primaryTrackName: copy.primaryTrack, advancedTrackName: copy.advancedTrack,
        primaryRanks: primaryRanks, advancedRanks: advancedRanks,
        nextRank: nextRank, advancedLockNote: lockNote,
        earning: skillsEarningRows(id), earningNote: copy.earningNote,
        itemMastery: itemMastery)
}

private struct SkillsTreeCopy {
    let name: String
    let summary: String
    let symbol: String
    let primaryTrack: String
    let advancedTrack: String
    let earningNote: String
}

private func skillsTreeCopy(_ id: SkillTreeID) -> SkillsTreeCopy {
    switch id {
    case .mining:
        return SkillsTreeCopy(
            name: "Mining", summary: "Harvest ore to earn XP. Rarer ore earns more.",
            symbol: "hammer", primaryTrack: "Mining speed", advancedTrack: "Ore yield",
            earningNote: "Only successful ore harvests in Survival count.")
    case .melee:
        return SkillsTreeCopy(
            name: "Melee", summary: "Land sword hits on animals and hostile enemies.",
            symbol: "figure.fencing", primaryTrack: "Sword damage",
            advancedTrack: "Combat techniques",
            earningNote: "Misses, invalid targets and Creative mode earn nothing. Techniques need a sword in hand.")
    case .ranged:
        return SkillsTreeCopy(
            name: "Ranged", summary: "Land bow hits on animals and hostile enemies.",
            symbol: "scope", primaryTrack: "Bow damage", advancedTrack: "Bow techniques",
            earningNote: "Misses, invalid targets and Creative mode earn nothing. Techniques need a bow and arrows.")
    case .crafting:
        return SkillsTreeCopy(
            name: "Crafting",
            summary: "Complete crafting-grid recipes. More and rarer ingredients earn more.",
            symbol: "wrench.and.screwdriver", primaryTrack: "Batch size",
            advancedTrack: "Quality and repair",
            earningNote: "Each item earns XP for its first \(SKILL_TREE_RECIPE_MASTERY_CAP) crafts. XP grows with the number and tier of the ingredients a finished craft uses.")
    }
}

/// Formats a multiplier step such as 1.3 as "+30%".
private func skillsPercentBonus(_ multiplier: Double) -> String {
    "+\(Int(((multiplier - 1) * 100).rounded()))%"
}

/// Formats basis points such as 250 as "+2.5%".
private func skillsBasisPointBonus(_ basisPoints: Int) -> String {
    let whole = basisPoints / 100
    let tenths = (basisPoints % 100) / 10
    return tenths == 0 ? "+\(whole)%" : "+\(whole).\(tenths)%"
}

private func skillsPrimaryBenefit(_ id: SkillTreeID, rank: Int) -> String {
    switch id {
    case .mining:
        return "Harvesting speed on stone and ore "
            + skillsPercentBonus(skillTreeMiningSpeedMultiplier(primaryRank: rank))
    case .melee:
        return "Sword damage " + skillsPercentBonus(skillTreeWeaponDamageMultiplier(primaryRank: rank))
    case .ranged:
        return "Bow damage " + skillsPercentBonus(skillTreeWeaponDamageMultiplier(primaryRank: rank))
    case .crafting:
        return "Up to \(skillTreeCraftingBatchRoundLimit(primaryRank: rank)) rounds per craft"
    }
}

private func skillsAction(for tree: SkillTreeID, advancedRank: Int) -> SkillTreeActionDescriptor? {
    SKILL_TREE_ACTION_DESCRIPTORS.first {
        $0.tree == tree && $0.advancedRankRequired == advancedRank
    }
}

private func skillsAdvancedBenefit(_ id: SkillTreeID, rank: Int,
                                   action: SkillTreeActionDescriptor?) -> (title: String, detail: String?) {
    switch id {
    case .mining:
        // Each advanced rank adds 1,000 basis points of ore-yield bonus (see
        // skillTreeMiningBonusDropCount).
        return ("Ore yield " + skillsBasisPointBonus(skillTreeClampAdvancedRank(rank) * 1_000), nil)
    case .melee, .ranged:
        guard let action else { return ("Advanced rank \(rank)", nil) }
        return (action.displayName, skillsActionEffect(action))
    case .crafting:
        let quality = "Durability "
            + skillsBasisPointBonus(skillTreeCraftingDurabilityBonusBasisPoints(qualityRank: rank))
            + " · weapon damage "
            + skillsBasisPointBonus(skillTreeCraftingDamageBonusBasisPoints(qualityRank: rank))
            + " · repair "
            + skillsBasisPointBonus(skillTreeCraftingRepairBonusBasisPoints(qualityRank: rank))
        // The capstone action is named in the title; its effect is in the fast-bar section and
        // the Player Guide, which keeps this one-line row readable.
        if let action { return ("Quality \(rank) and \(action.displayName)", quality) }
        return ("Quality \(rank)", quality)
    }
}

private func skillsDuration(ticks: Int) -> String {
    let seconds = ticks / 20
    if seconds >= 60, seconds % 60 == 0 {
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
    return "\(seconds) seconds"
}

private func skillsCooldown(ticks: Int) -> String {
    let seconds = ticks / 20
    if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60)-minute cooldown" }
    return "\(seconds)-second cooldown"
}

private func skillsMultiplier(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))×" : "\(value)×"
}

/// A one-line effect derived from the action descriptor's own fields.
func skillsActionEffect(_ action: SkillTreeActionDescriptor) -> String {
    let weapon = action.equipment == .bow ? "bow" : "sword"
    var effect: String
    if action.id == .fieldRepair {
        effect = "Restores a quarter of a damaged item’s durability with its repair material"
    } else if action.stunDurationTicks > 0 {
        effect = "Stops a target’s actions and movement for "
            + skillsDuration(ticks: action.stunDurationTicks)
    } else if action.disarmsTarget {
        effect = "The target drops its equipped items"
    } else if action.targeting == .hostileArea {
        let reach = action.tree == .ranged ? "around the aimed target" : "around you"
        effect = skillsMultiplier(action.weaponDamageMultiplier) + " \(weapon) damage to every hostile " + reach
    } else if action.pushDistanceBlocks > 0 {
        effect = skillsMultiplier(action.weaponDamageMultiplier)
            + " \(weapon) damage and a shove of up to \(action.pushDistanceBlocks) "
            + (action.pushDistanceBlocks == 1 ? "block" : "blocks")
    } else {
        effect = skillsMultiplier(action.weaponDamageMultiplier) + " \(weapon) damage"
    }
    if action.cooldownTicks > 0 {
        effect += " · " + skillsCooldown(ticks: action.cooldownTicks)
    }
    return effect
}

private func skillsEffortHint(_ id: SkillTreeID, remainingXP: Int) -> String? {
    guard remainingXP > 0 else { return nil }
    func perAction(_ xp: Int) -> Int { (remainingXP + xp - 1) / max(1, xp) }
    switch id {
    case .mining:
        let diamond = perAction(skillTreeMiningXP(for: .diamond))
        let iron = perAction(skillTreeMiningXP(for: .iron))
        return "About \(diamond) diamond or \(iron) iron ore"
    case .melee:
        return "About \(perAction(skillTreeMeleeXP(successfulSwordDamage: true))) sword hits"
    case .ranged:
        return "About \(perAction(skillTreeRangedXP(successfulBowDamage: true))) bow hits"
    case .crafting:
        return nil
    }
}

private func skillsMiningResourceName(_ resource: SkillTreeMiningResource) -> String {
    switch resource {
    case .coal: return "Coal"
    case .copper: return "Copper"
    case .iron: return "Iron"
    case .netherQuartz: return "Nether quartz"
    case .netherGold: return "Nether gold"
    case .lapis: return "Lapis"
    case .amethyst: return "Amethyst"
    case .gold: return "Gold"
    case .redstone: return "Redstone"
    case .emerald: return "Emerald"
    case .diamond: return "Diamond"
    case .ancientDebris: return "Ancient debris"
    case .labradorite: return "Labradorite"
    }
}

private func skillsEarningRows(_ id: SkillTreeID) -> [SkillsEarningRow] {
    switch id {
    case .mining:
        // Labradorite is a progression-table entry with no block yet, so it is not offered.
        let resources = SkillTreeMiningResource.allCases.filter { $0 != .labradorite }
        let amounts = Array(Set(resources.map(skillTreeMiningXP(for:)))).sorted()
        return amounts.map { amount in
            let names = resources.filter { skillTreeMiningXP(for: $0) == amount }
                .map(skillsMiningResourceName)
            let label = names.enumerated().map { $0.offset == 0 ? $0.element : $0.element.lowercased() }
                .joined(separator: ", ")
            return SkillsEarningRow(label: label, value: "\(amount) XP")
        }
    case .melee:
        return [SkillsEarningRow(label: "Sword hit on an animal or hostile enemy",
                                 value: "\(skillTreeMeleeXP(successfulSwordDamage: true)) XP")]
    case .ranged:
        return [SkillsEarningRow(label: "Bow hit on an animal or hostile enemy",
                                 value: "\(skillTreeRangedXP(successfulBowDamage: true)) XP")]
    case .crafting:
        return [
            SkillsEarningRow(label: "Copper", value: "Tier 1"),
            SkillsEarningRow(label: "Iron", value: "Tier 2"),
            SkillsEarningRow(label: "Gold, redstone, lapis, quartz, amethyst", value: "Tier 3"),
            SkillsEarningRow(label: "Emerald, diamond", value: "Tier 4"),
            SkillsEarningRow(label: "Ancient debris, netherite", value: "Tier 5"),
        ]
    }
}

/// Aggregates the recipe-index mastery ledger per output item, the same way the craft boundary
/// folds alternate recipes (sum, capped at the mastery cap). Rows are ordered by crafts, then by
/// the first recipe index that recorded a craft for the item, so the order never depends on
/// hashing.
func skillsItemMastery(counts: [UInt8], context: SkillsPresentationContext) -> [SkillsItemMasteryRow] {
    let outputs = context.recipeOutputItemIDs
    var order: [Int] = []
    var totals: [Int: Int] = [:]
    for index in 0..<min(counts.count, outputs.count) where counts[index] > 0 {
        let item = outputs[index]
        if totals[item] == nil { order.append(item) }
        totals[item] = min(SKILL_TREE_RECIPE_MASTERY_CAP, (totals[item] ?? 0) + Int(counts[index]))
    }
    let rows = order.enumerated().map { position, item in
        (position, SkillsItemMasteryRow(id: item, name: context.itemName(item), crafts: totals[item] ?? 0))
    }
    return rows.sorted { lhs, rhs in
        lhs.1.crafts != rhs.1.crafts ? lhs.1.crafts > rhs.1.crafts : lhs.0 < rhs.0
    }.map(\.1)
}
