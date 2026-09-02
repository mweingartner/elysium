import Foundation

public struct RPGPathProgressionCriterion: Equatable {
    public let eventKind: RPGXPEventKind
    public let title: String
    public let criterion: String
    public let reward: String
    public let limit: String

    public init(eventKind: RPGXPEventKind, title: String,
                criterion: String, reward: String, limit: String) {
        self.eventKind = eventKind
        self.title = title
        self.criterion = criterion
        self.reward = reward
        self.limit = limit
    }
}

/// Player-facing identity for one path. Purpose and play loop are deliberately separate from the
/// XP rows: the former explains why the path exists, while the latter states exactly what advances
/// it. Criteria are projected from the closed event registry so every shipped XP source appears
/// once and only on its owning path.
public struct RPGPathIdentity: Equatable {
    public let pathID: String
    public let purpose: String
    public let playLoop: String
    public let progressionCriteria: [RPGPathProgressionCriterion]

    public init(pathID: String, purpose: String, playLoop: String,
                progressionCriteria: [RPGPathProgressionCriterion]) {
        self.pathID = pathID
        self.purpose = purpose
        self.playLoop = playLoop
        self.progressionCriteria = progressionCriteria
    }
}

public func rpgPathIdentity(pathID: String) -> RPGPathIdentity? {
    let purpose: String
    let playLoop: String
    switch pathID {
    case "warden":
        purpose = "Front-line protector who converts close combat and timely defense into team safety."
        playLoop = "Hold dangerous ground, stop hostile pressure, and spend fatigue on protection or decisive melee control."
    case "ranger":
        purpose = "Mobile ranged scout who turns distance, terrain knowledge, and fieldcraft into control."
        playLoop = "Explore ahead, establish safe sightlines, and finish threats before they reach close range."
    case "delver":
        purpose = "Underground specialist who finds resources, manages hazards, and extracts guarded treasure."
        playLoop = "Descend deliberately, read the terrain, open dangerous sites, and bring valuable material back safely."
    case "arcanist":
        purpose = "Fatigue-driven spellcaster who reshapes encounters with damage, deception, wards, and summons."
        playLoop = "Prepare a compact spell kit, create real magical effects, and manage fatigue and focus positioning."
    case "mender":
        purpose = "Support specialist who preserves a group through healing, provisions, cleansing, and safe zones."
        playLoop = "Prevent losses, answer hostile injuries, and turn gathered supplies into sustained expedition strength."
    case "tinker":
        purpose = "Engineering specialist who solves problems with mechanisms, maintained gear, and controlled demolition."
        playLoop = "Learn useful recipes, build working devices, and trade setup time for repeatable mechanical advantage."
    default:
        return nil
    }
    let criteria = RPGXPEventKind.allCases
        .filter { $0.pathID == pathID }
        .map {
            RPGPathProgressionCriterion(
                eventKind: $0,
                title: $0.progressionTitle,
                criterion: $0.progressionCriterion,
                reward: $0.progressionReward,
                limit: $0.progressionLimit)
        }
    guard !criteria.isEmpty else { return nil }
    return RPGPathIdentity(pathID: pathID, purpose: purpose,
                           playLoop: playLoop, progressionCriteria: criteria)
}

public enum RPGSkillPurchaseFailure: Equatable {
    case characterNotCreated
    case unknownOrCrossPathSkill(String)
    case authorityRevisionExhausted
    case alreadyAtMaximumRank(String)
    case insufficientLevel(required: Int)
    case insufficientSkillPoints(required: Int, available: Int)
}

public struct RPGSpecializationMilestone: Equatable {
    public let level: Int
    public let skillID: String
    public let rank: Int
    public let cost: Int

    public init(level: Int, skillID: String, rank: Int, cost: Int) {
        self.level = level
        self.skillID = skillID
        self.rank = rank
        self.cost = cost
    }
}

public struct RPGSpecializationImpact: Equatable {
    public let remainingSpecializationCost: Int
    public let totalPointsStillEarnableThroughLevel20: Int
    public let canStillCompleteSelectedSpecialization: Bool
    public let firstMissedRoadmapMilestone: RPGSpecializationMilestone?

    public init(remainingSpecializationCost: Int,
                totalPointsStillEarnableThroughLevel20: Int,
                canStillCompleteSelectedSpecialization: Bool,
                firstMissedRoadmapMilestone: RPGSpecializationMilestone?) {
        self.remainingSpecializationCost = remainingSpecializationCost
        self.totalPointsStillEarnableThroughLevel20 = totalPointsStillEarnableThroughLevel20
        self.canStillCompleteSelectedSpecialization = canStillCompleteSelectedSpecialization
        self.firstMissedRoadmapMilestone = firstMissedRoadmapMilestone
    }
}

public struct RPGSpecializationRoadmap: Equatable {
    public let branchID: String
    public let milestones: [RPGSpecializationMilestone]

    public init(branchID: String, milestones: [RPGSpecializationMilestone]) {
        self.branchID = branchID
        self.milestones = milestones
    }
}

public struct RPGSkillPurchaseEvaluation: Equatable {
    public let skillID: String
    public let currentRank: Int
    public let targetRank: Int
    public let cost: Int?
    public let levelGate: Int?
    public let availableSkillPoints: Int
    public let failure: RPGSkillPurchaseFailure?
    public let effectText: String?
    public let specializationImpact: RPGSpecializationImpact

    public var permitted: Bool { failure == nil }
}

private let specializationRanksByNode: [[Int]] = [
    Array(1...RPG_SKILL_RANK_CAP), Array(1...RPG_SKILL_RANK_CAP), Array(1...RPG_SKILL_RANK_CAP),
]

public func rpgSpecializationRoadmap(branchID: String,
                                     in state: RPGCharacterState) -> RPGSpecializationRoadmap? {
    guard let branch = rpgBranchDefinition(branchID), branch.skillIDs.count == 3 else { return nil }
    var milestones: [RPGSpecializationMilestone] = []
    milestones.reserveCapacity(3 * RPG_SKILL_RANK_CAP)
    for (node, skillID) in branch.skillIDs.enumerated() {
        for rank in specializationRanksByNode[node] {
            guard let level = rpgMinimumLevel(for: skillID, targetRank: rank,
                                              specializationBranchID: branchID),
                  let cost = rpgSkillPointCost(skillID, targetRank: rank, in: state) else {
                return nil
            }
            milestones.append(RPGSpecializationMilestone(level: level, skillID: skillID,
                                                          rank: rank, cost: cost))
        }
    }
    milestones.sort {
        if $0.level != $1.level { return $0.level < $1.level }
        guard let left = branch.skillIDs.firstIndex(of: $0.skillID),
              let right = branch.skillIDs.firstIndex(of: $1.skillID) else { return $0.skillID < $1.skillID }
        return left == right ? $0.rank < $1.rank : left < right
    }
    return RPGSpecializationRoadmap(branchID: branchID, milestones: milestones)
}

private func specializationImpact(_ state: RPGCharacterState) -> RPGSpecializationImpact {
    guard state.created,
          let roadmap = rpgSpecializationRoadmap(branchID: state.specializationBranchID, in: state) else {
        return RPGSpecializationImpact(remainingSpecializationCost: 0,
                                       totalPointsStillEarnableThroughLevel20: 0,
                                       canStillCompleteSelectedSpecialization: false,
                                       firstMissedRoadmapMilestone: nil)
    }
    var remaining = 0
    var firstMissed: RPGSpecializationMilestone?
    for milestone in roadmap.milestones {
        if (state.skillRanks[milestone.skillID] ?? 0) < milestone.rank {
            let (sum, overflow) = remaining.addingReportingOverflow(milestone.cost)
            remaining = overflow ? Int.max : sum
            if firstMissed == nil, milestone.level <= state.level { firstMissed = milestone }
        }
    }
    let pointsAtCap = rpgEarnedSkillPoints(level: RPG_LEVEL_CAP)
    let spent = rpgSpentSkillPoints(state)
    let stillEarnable = max(0, pointsAtCap - spent)
    return RPGSpecializationImpact(
        remainingSpecializationCost: remaining,
        totalPointsStillEarnableThroughLevel20: stillEarnable,
        canStillCompleteSelectedSpecialization: remaining <= stillEarnable,
        firstMissedRoadmapMilestone: firstMissed
    )
}

public func rpgEvaluateSkillPurchase(_ skillID: String,
                                     in repairedState: RPGCharacterState) -> RPGSkillPurchaseEvaluation {
    let state = repairedState
    let currentRank = max(0, min(RPG_SKILL_RANK_CAP, state.skillRanks[skillID] ?? 0))
    let targetRank = min(RPG_SKILL_RANK_CAP + 1, currentRank + 1)
    let definition = rpgSkillDefinition(skillID)
    let available = rpgAvailableSkillPoints(state)
    let cost = targetRank <= RPG_SKILL_RANK_CAP ? rpgSkillPointCost(skillID, targetRank: targetRank, in: state) : nil
    let levelGate = targetRank <= RPG_SKILL_RANK_CAP
        ? rpgMinimumLevel(for: skillID, targetRank: targetRank,
                          specializationBranchID: state.specializationBranchID)
        : nil

    let failure: RPGSkillPurchaseFailure?
    if !state.created {
        failure = .characterNotCreated
    } else if definition == nil || definition?.pathID != state.pathID {
        failure = .unknownOrCrossPathSkill(skillID)
    } else if state.authorityRevision >= RPG_MAX_NORMAL_AUTHORITY_REVISION {
        failure = .authorityRevisionExhausted
    } else if currentRank >= RPG_SKILL_RANK_CAP {
        failure = .alreadyAtMaximumRank(skillID)
    } else if let levelGate, state.level < levelGate {
        failure = .insufficientLevel(required: levelGate)
    } else if let cost, available < cost {
        failure = .insufficientSkillPoints(required: cost, available: available)
    } else {
        failure = nil
    }

    var proposedState = state
    if failure == nil, targetRank <= RPG_SKILL_RANK_CAP {
        proposedState.skillRanks[skillID] = targetRank
    }

    return RPGSkillPurchaseEvaluation(
        skillID: skillID,
        currentRank: currentRank,
        targetRank: targetRank,
        cost: cost,
        levelGate: levelGate,
        availableSkillPoints: available,
        failure: failure,
        effectText: targetRank <= RPG_SKILL_RANK_CAP ? rpgSkillRankBenefit(skillID, rank: targetRank) : nil,
        specializationImpact: specializationImpact(proposedState)
    )
}

public struct RPGPathProgressionGuidance: Equatable {
    public let pathID: String
    public let targetXP: Int
    public let eventKind: RPGXPEventKind
    public let eventCount: Int
    public let xpPerEvent: Int
    public let rolloverEventCount: Int
    public let visibleText: String
}

public func rpgLevelOneProgressionGuidance(pathID: String) -> RPGPathProgressionGuidance? {
    let target = rpgXPRequiredForLevel(2)
    switch pathID {
    case "warden":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .wardenMeleeDefeat, eventCount: 5, xpPerEvent: 10, rolloverEventCount: 0,
            visibleText: "Defeat five hostile creatures with a Warden's normal melee attack or melee action (5 x 10 XP), or earn 2 XP when a Warden protection effect absorbs at least 2 hostile damage.")
    case "ranger":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .rangerFieldDiscovery, eventCount: 17, xpPerEvent: 3, rolloverEventCount: 0,
            visibleText: "Earn 50 class XP through ranged victories or eligible loaded field locations. Exploration admits 8 events per 1,200 simulation ticks, so 17 location awards alone require 3 windows.")
    case "delver":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .delverExcavation, eventCount: 13, xpPerEvent: 4, rolloverEventCount: 0,
            visibleText: "Earn 50 class XP through depth milestones, generated world-structure treasure, or deep excavation. Thirteen excavations alone require 2 windows because depth, generated-structure treasure, and excavation events share an 8-event cap.")
    case "arcanist":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .arcanistSpellPractice, eventCount: 9, xpPerEvent: 6, rolloverEventCount: 0,
            visibleText: "Earn 50 class XP through spell victories or effect-producing practice. Practice awards once per distinct spell per window, so combine spells and victories instead of repeating one cast.")
    case "mender":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .menderProvisionCraft, eventCount: 9, xpPerEvent: 6, rolloverEventCount: 0,
            visibleText: "Earn 50 class XP by healing, cleansing, or rescuing a non-player ally through a live, unconsumed injury record before 1,200 simulation ticks have elapsed since that ally's latest hostile injury, or by completing crafting-grid recipes for qualifying beneficial food. Nine provisions alone require 2 windows.")
    case "tinker":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .tinkerEngineeringCraft, eventCount: 7, xpPerEvent: 6, rolloverEventCount: 1,
            visibleText: "Earn 50 class XP through first-time crafting-grid recipes, powered mechanisms, or qualifying crafting-grid outputs. Engineering admits 8 events per 1,200 simulation ticks.")
    default:
        return nil
    }
}
