import Foundation

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
            visibleText: "Defeat five hostile creatures in melee (5 x 10 XP), or earn XP by mitigating damage.")
    case "ranger":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .rangerFieldDiscovery, eventCount: 17, xpPerEvent: 3, rolloverEventCount: 0,
            visibleText: "Discover seventeen loaded-chunk field locations (17 x 3 XP).")
    case "delver":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .delverExcavation, eventCount: 13, xpPerEvent: 4, rolloverEventCount: 0,
            visibleText: "Complete thirteen legal deep excavations (13 x 4 XP).")
    case "arcanist":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .arcanistSpellPractice, eventCount: 9, xpPerEvent: 6, rolloverEventCount: 0,
            visibleText: "Make nine effect-producing practice casts across bounded windows (9 x 6 XP).")
    case "mender":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .menderProvisionCraft, eventCount: 9, xpPerEvent: 6, rolloverEventCount: 0,
            visibleText: "Produce nine qualifying provisions (9 x 6 XP), or earn XP through causal support healing.")
    case "tinker":
        return RPGPathProgressionGuidance(pathID: pathID, targetXP: target,
            eventKind: .tinkerEngineeringCraft, eventCount: 7, xpPerEvent: 6, rolloverEventCount: 1,
            visibleText: "Learn one engineering recipe (4 XP), make seven outputs (7 x 6 XP), then one output after rollover (+6 XP).")
    default:
        return nil
    }
}
