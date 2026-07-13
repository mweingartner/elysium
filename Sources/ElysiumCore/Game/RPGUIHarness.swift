import Foundation

public enum RPGUIHarnessViewport: String, CaseIterable, Equatable {
    case compact = "360x224", medium = "520x330", large = "700x420"
    public var size: (Double, Double) {
        switch self { case .compact: return (360, 224); case .medium: return (520, 330); case .large: return (700, 420) }
    }
}

public enum RPGUIHarnessAppearance: String, CaseIterable, Equatable {
    case standard, highContrast, reduceMotion, highContrastReduceMotion
    public var highContrast: Bool { self == .highContrast || self == .highContrastReduceMotion }
    public var reduceMotion: Bool { self == .reduceMotion || self == .highContrastReduceMotion }
}

public enum RPGUIHarnessAuthority: String, CaseIterable, Equatable {
    case ready, pending, acceptedCommit, rejectedCommit, reconnecting, disposition, exhausted, unavailable
    public var phase: RPGAuthorityPresentationPhase {
        switch self {
        case .ready: return .localReady
        case .pending: return .awaitingHost
        case .acceptedCommit: return .committingAcceptedOwnerCheckpoint
        case .rejectedCommit: return .committingRejectedOwnerCheckpoint
        case .reconnecting: return .reconnecting
        case .disposition: return .awaitingDispositionCheckpoint
        case .exhausted: return .authorityExhausted
        case .unavailable: return .unavailable
        }
    }
}

public struct RPGUIHarnessShotSpec: Equatable, Sendable {
    public let basename: String
    public let frames: Int
}

public enum RPGUIHarnessSelector: Equatable {
    case creation(RPGCreationStep, pathID: String, branchID: String, profile: String)
    case tutorial(page: Int, pathID: String, branchID: String)
    case tab(pathID: String, branchID: String, tab: RPGCharacterTab)
    case skill(skillID: String, rank: Int, state: String)
    case active(skillID: String, state: String)
    case spell(spellID: String, state: String)
    case slots(pathID: String, branchID: String, selected: Int, profile: String)
    case status(kind: String, operation: String, target: String, persistence: String)
    case error(kind: String, kindTarget: String, registeredID: String)
}

public struct RPGUIHarnessBootstrap: Equatable {
    public let selectorText: String
    public let selector: RPGUIHarnessSelector
    public let authority: RPGUIHarnessAuthority
    public let viewport: RPGUIHarnessViewport
    public let appearance: RPGUIHarnessAppearance
    public let semanticSummaryRequested: Bool
    public let shot: RPGUIHarnessShotSpec?

    public static let allowedElysiumKeys: Set<String> = [
        "ELYSIUM_RPG_UI_CASE", "ELYSIUM_RPG_UI_AUTHORITY", "ELYSIUM_RPG_UI_VIEWPORT",
        "ELYSIUM_RPG_UI_APPEARANCE", "ELYSIUM_RPG_UI_SEMANTIC_SUMMARY", "ELYSIUM_SHOT",
    ]

    public static func parseIfPresent(_ environment: [String: String]) -> RPGUIHarnessBootstrapResult {
        guard let selectorText = environment["ELYSIUM_RPG_UI_CASE"] else { return .ordinary }
        guard environment.count <= 64 else { return .rejected("RPG UI harness rejected: environment entry limit") }
        var aggregate = 0
        for key in environment.keys.sorted() {
            guard let value = environment[key] else { continue }
            guard key.utf8.count <= 128 else { return .rejected("RPG UI harness rejected: environment key limit") }
            let valueLimit = key == "ELYSIUM_RPG_UI_CASE" ? 192 : 512
            guard value.utf8.count <= valueLimit else { return .rejected("RPG UI harness rejected: environment value limit") }
            let addition = aggregate.addingReportingOverflow(key.utf8.count + value.utf8.count)
            guard !addition.overflow, addition.partialValue <= 4_096 else {
                return .rejected("RPG UI harness rejected: environment aggregate limit")
            }
            aggregate = addition.partialValue
        }
        let elysiumKeys = environment.keys.filter { $0.hasPrefix("ELYSIUM_") }
        guard elysiumKeys.allSatisfy(allowedElysiumKeys.contains) else {
            return .rejected("RPG UI harness rejected: non-harness ELYSIUM key")
        }
        guard let selector = parseSelector(selectorText) else {
            return .rejected("RPG UI harness rejected: invalid case selector")
        }
        let authorityText = environment["ELYSIUM_RPG_UI_AUTHORITY"] ?? "ready"
        let viewportText = environment["ELYSIUM_RPG_UI_VIEWPORT"] ?? "520x330"
        let appearanceText = environment["ELYSIUM_RPG_UI_APPEARANCE"] ?? "standard"
        guard let authority = RPGUIHarnessAuthority(rawValue: authorityText),
              let viewport = RPGUIHarnessViewport(rawValue: viewportText),
              let appearance = RPGUIHarnessAppearance(rawValue: appearanceText) else {
            return .rejected("RPG UI harness rejected: invalid fixture option")
        }
        if case .status(_, _, _, let persistence) = selector,
           persistence == "authority",
           authority.phase == .localReady || authority.phase == .unavailable {
            return .rejected("RPG UI harness rejected: inconsistent authority status")
        }
        if case .status(let kind, _, _, let persistence) = selector {
            let validLifecycle: Bool
            switch persistence {
            case "local": validLifecycle = kind != "pending" && kind != "authorityExhausted"
            case "authority":
                validLifecycle = authority.phase == .authorityExhausted
                    ? kind == "authorityExhausted" : kind == "pending"
            case "durablePending", "durableAcknowledged":
                validLifecycle = ["success", "rejection", "authorityExhausted"].contains(kind)
            default: validLifecycle = false
            }
            guard validLifecycle else {
                return .rejected("RPG UI harness rejected: inconsistent status lifecycle")
            }
        }
        let summary: Bool
        switch environment["ELYSIUM_RPG_UI_SEMANTIC_SUMMARY"] {
        case nil: summary = false
        case "1"?: summary = true
        default: return .rejected("RPG UI harness rejected: invalid semantic summary option")
        }
        let shot: RPGUIHarnessShotSpec?
        if let raw = environment["ELYSIUM_SHOT"] {
            guard let parsed = parseShot(raw) else {
                return .rejected("RPG UI harness rejected: invalid screenshot basename")
            }
            shot = parsed
        } else { shot = nil }
        return .harness(RPGUIHarnessBootstrap(
            selectorText: selectorText, selector: selector, authority: authority,
            viewport: viewport, appearance: appearance,
            semanticSummaryRequested: summary, shot: shot))
    }

    private static func parseShot(_ raw: String) -> RPGUIHarnessShotSpec? {
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let basename = String(parts[0])
        guard (1...96).contains(basename.utf8.count), basename != ".", basename != "..",
              basename.utf8.allSatisfy({ byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                    (byte >= 48 && byte <= 57) || byte == 46 || byte == 95 || byte == 45
              }), !basename.contains("/"), !basename.contains("\\") else { return nil }
        let frames = parts.count == 2
            ? parseCanonicalDecimal(String(parts[1]), range: 1...600)
            : 1
        guard let frames else { return nil }
        return RPGUIHarnessShotSpec(basename: basename, frames: frames)
    }

    private static func parseCanonicalDecimal(_ text: String,
                                              range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              text == "0" || text.utf8.first != 48,
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    private static func parseSelector(_ raw: String) -> RPGUIHarnessSelector? {
        guard (1...192).contains(raw.utf8.count) else { return nil }
        let p = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let family = p.first else { return nil }
        switch family {
        case "creation" where p.count == 5:
            guard let step = RPGCreationStep(rawValue: p[1]), validPathBranch(p[2], p[3]),
                  ["preset", "editedValid", "underBudget", "unmetRequirement", "inventoryFull"].contains(p[4]) else { return nil }
            return .creation(step, pathID: p[2], branchID: p[3], profile: p[4])
        case "tutorial" where p.count == 4:
            guard let page = parseCanonicalDecimal(p[1], range: 1...4),
                  validPathBranch(p[2], p[3]) else { return nil }
            return .tutorial(page: page, pathID: p[2], branchID: p[3])
        case "tab" where p.count == 4:
            guard validPathBranch(p[1], p[2]), let tab = RPGCharacterTab(rawValue: p[3]) else { return nil }
            return .tab(pathID: p[1], branchID: p[2], tab: tab)
        case "skill" where p.count == 4:
            guard rpgSkillDefinition(p[1]) != nil,
                  let rank = parseCanonicalDecimal(p[2], range: 1...3),
                  validSkillRankPresentation(skillID: p[1], rank: rank, state: p[3]) else { return nil }
            return .skill(skillID: p[1], rank: rank, state: p[3])
        case "active" where p.count == 3:
            guard let skill = rpgSkillDefinition(p[1]), skill.kind == .active,
                  ["unknown", "known", "prepared", "selected", "slotted"].contains(p[2]) else { return nil }
            return .active(skillID: p[1], state: p[2])
        case "spell" where p.count == 3:
            guard rpgSpellDefinition(p[1]) != nil,
                  ["locked", "known", "prepared", "selected", "slotted"].contains(p[2]) else { return nil }
            return .spell(spellID: p[1], state: p[2])
        case "slots" where p.count == 5:
            guard validPathBranch(p[1], p[2]),
                  let slot = parseCanonicalDecimal(p[3], range: 0...8),
                  ["empty", "sparse", "maximal", "repairInvalid"].contains(p[4]) else { return nil }
            return .slots(pathID: p[1], branchID: p[2], selected: slot, profile: p[4])
        case "status" where p.count == 5:
            let kinds = ["success", "pending", "rejection", "cooldown", "fatigue", "missingFocus", "missingEquipment", "permissionDenied", "persistenceFailure", "authorityExhausted"]
            let operations = ["sheet", "saveSlots", "cycle", "useSelected", "useSlot"]
            let persistences = ["local", "authority", "durablePending", "durableAcknowledged"]
            guard kinds.contains(p[1]), operations.contains(p[2]), validStatusTarget(p[3]),
                  validStatusCombination(operation: p[2], target: p[3]),
                  validStatusKindOperationCombination(
                    kind: p[1], operation: p[2], target: p[3]),
                  persistences.contains(p[4]) else { return nil }
            return .status(kind: p[1], operation: p[2], target: p[3], persistence: p[4])
        case "error" where p.count == 4:
            guard ["cooldown", "fatigue", "missingFocus", "missingEquipment",
                   "permissionDenied", "persistenceFailure"].contains(p[1]),
                  ["skill", "spell"].contains(p[2]) else { return nil }
            if p[2] == "skill" {
                guard let skill = rpgSkillDefinition(p[3]),
                      p[1] == "persistenceFailure" || skill.kind == .active else { return nil }
            } else {
                guard rpgSpellDefinition(p[3]) != nil else { return nil }
            }
            return .error(kind: p[1], kindTarget: p[2], registeredID: p[3])
        default: return nil
        }
    }

    private static func validPathBranch(_ pathID: String, _ branchID: String) -> Bool {
        guard let path = rpgPathDefinition(pathID), let branch = rpgBranchDefinition(branchID) else { return false }
        return branch.pathID == pathID && path.branchIDs.contains(branchID)
    }

    /// Closed grammar for rank states that can exist in a repaired character. Rank three cannot be
    /// purchased-but-not-current, rank one cannot be future, and a foundation rank cannot precede
    /// the valid rank-one starter state.
    private static func validSkillRankPresentation(skillID: String, rank: Int,
                                                    state: String) -> Bool {
        guard let node = rpgSkillNodeIndex(skillID), (1...3).contains(rank) else { return false }
        switch state {
        case "purchased": return rank < 3
        case "current": return true
        case "nextLegal", "locked": return node > 0 || rank > 1
        case "future": return rank > 1 && (node > 0 || rank > 2)
        default: return false
        }
    }

    private static func validStatusTarget(_ value: String) -> Bool {
        if value == "character" { return true }
        if rpgSkillDefinition(value) != nil || rpgSpellDefinition(value) != nil || RPGAttributeID(rawValue: value) != nil { return true }
        if statusSlotIndex(value) != nil { return true }
        let equipment = ["apprenticeFocus", "heldMeleeWeapon", "heldBowAndArrow", "heldPickaxe", "heldTool"]
        let permissions = ["build", "container", "buildOnlyForBlockTarget"]
        return equipment.contains(value) || permissions.contains(value)
    }

    private static func validStatusCombination(operation: String, target: String) -> Bool {
        let isSkill = rpgSkillDefinition(target) != nil
        let isSpell = rpgSpellDefinition(target) != nil
        let isAttribute = RPGAttributeID(rawValue: target) != nil
        let isSlot = statusSlotIndex(target) != nil
        let isEquipment = ["apprenticeFocus", "heldMeleeWeapon", "heldBowAndArrow", "heldPickaxe", "heldTool"].contains(target)
        let isPermission = ["build", "container", "buildOnlyForBlockTarget"].contains(target)
        switch operation {
        case "sheet": return target == "character" || isSkill || isSpell || isAttribute
        case "saveSlots": return target == "character" || isSlot
        case "cycle": return target == "character" || isSkill || isSpell
        case "useSelected": return target == "character" || isSkill || isSpell || isEquipment || isPermission
        case "useSlot": return isSlot
        default: return false
        }
    }

    private static func validStatusKindOperationCombination(
        kind: String, operation: String, target: String
    ) -> Bool {
        switch kind {
        case "cooldown", "fatigue", "missingFocus", "missingEquipment":
            return operation == "useSelected" || operation == "useSlot"
        case "permissionDenied":
            return operation == "useSelected" || operation == "useSlot"
        case "persistenceFailure":
            return operation == "saveSlots" || (operation == "sheet" && target == "character")
        case "success", "pending", "rejection", "authorityExhausted":
            return true
        default: return false
        }
    }

    private static func statusSlotIndex(_ value: String) -> Int? {
        guard value.hasPrefix("slot") else { return nil }
        return parseCanonicalDecimal(String(value.dropFirst(4)), range: 0...8)
    }
}

public enum RPGUIHarnessBootstrapResult: Equatable {
    case ordinary
    case harness(RPGUIHarnessBootstrap)
    case rejected(String)
}

public struct RPGUIHarnessFixture: Equatable {
    public let model: RPGScreenModel
    public let modelInput: RPGScreenModelInput
    public let status: RPGStatusPresentation?
    public let characterState: RPGCharacterState
    public let quickSlots: RPGQuickSlotPreferences
    public let summary: String

    private struct PreparedCandidate {
        let kind: RPGPreparedActionKind
        let id: String
        let unlockingSkillID: String
        let unlockingRank: Int
        var token: String { rpgPreparedActionToken(kind: kind, id: id) }
    }

    private static func statusTarget(_ value: String) -> RPGStatusTarget? {
        if value == "character" { return .character }
        if rpgSkillDefinition(value) != nil { return .skill(value) }
        if rpgSpellDefinition(value) != nil { return .spell(value) }
        if let attribute = RPGAttributeID(rawValue: value) { return .attribute(attribute) }
        if value.hasPrefix("slot"), let slot = Int(value.dropFirst(4)),
           value == "slot" + String(slot), (0...8).contains(slot) {
            return .slot(slot)
        }
        if ["apprenticeFocus", "heldMeleeWeapon", "heldBowAndArrow", "heldPickaxe", "heldTool"].contains(value) {
            return .equipment(value)
        }
        if ["build", "container", "buildOnlyForBlockTarget"].contains(value) {
            return .permission(value)
        }
        return nil
    }

    private static func statusOperation(_ value: String, target: RPGStatusTarget) -> RPGStatusOperation? {
        switch value {
        case "sheet":
            switch target {
            case .skill(let id): return .sheet(.rankUp(skillID: id))
            case .spell(let id): return .sheet(.prepareSpell(id))
            case .attribute(let id): return .sheet(.spendAttribute(id))
            case .character:
                guard let path = RPG_PATH_DEFINITIONS.first,
                      let branchID = path.branchIDs.first,
                      let starterSkillID = rpgBranchDefinition(branchID)?.skillIDs.first,
                      let attributes = rpgCreationPreset(pathID: path.id) else { return nil }
                return .sheet(.create(RPGCreationDraft(
                    pathID: path.id, attributes: attributes,
                    starterSkillID: starterSkillID, starterSpellIDs: [])))
            default: return nil
            }
        case "saveSlots": return .saveQuickSlots
        case "cycle": return .cyclePreparedAction
        case "useSelected": return .usePreparedAction
        case "useSlot":
            if case .slot(let slot) = target { return .useQuickSlot(slot) }
            return nil
        default: return nil
        }
    }

    private static func operationTag(_ operation: RPGStatusOperation) -> RPGStatusOperationTag {
        switch operation {
        case .sheet(let sheet):
            switch sheet {
            case .create: return .create
            case .rankUp: return .rankUp
            case .spendAttribute: return .spendAttribute
            case .prepareSkill: return .prepareSkill
            case .unprepareSkill: return .unprepareSkill
            case .prepareSpell: return .prepareSpell
            case .unprepareSpell: return .unprepareSpell
            case .selectSkill: return .selectSkill
            case .selectSpell: return .selectSpell
            }
        case .saveQuickSlots: return .saveQuickSlots
        case .cyclePreparedAction: return .cyclePreparedAction
        case .usePreparedAction: return .usePreparedAction
        case .useQuickSlot: return .useQuickSlot
        }
    }

    private static func makeStatus(kind: String, operation operationText: String,
                                   target targetText: String, persistence persistenceText: String,
                                   authorityPhase: RPGAuthorityPresentationPhase,
                                   authorityRequestIdentity: String?,
                                   detail: String? = nil) -> RPGStatusPresentation? {
        guard let statusKind = RPGStatusKind(rawValue: kind),
              let target = statusTarget(targetText),
              let operation = statusOperation(operationText, target: target) else { return nil }
        let persistence: RPGStatusPersistence
        let identity: RPGStatusIdentity
        let acknowledgement: RPGStatusAcknowledgementEligibility
        switch persistenceText {
        case "local":
            persistence = .localUntilReplaced
            identity = .local(counter: 1, operationTag: operationTag(operation))
            acknowledgement = .never
        case "authority":
            guard let authorityRequestIdentity,
                  authorityPhase != .localReady, authorityPhase != .unavailable else { return nil }
            persistence = .authorityPhase
            identity = .authorityPhase(requestFingerprint: authorityRequestIdentity,
                                       phase: authorityPhase)
            acknowledgement = .never
        case "durablePending", "durableAcknowledged":
            guard let durable = try? RPGDurableNoticeIdentity(
                notificationID: String(repeating: "d", count: 64),
                payloadDigest: String(repeating: "e", count: 64)) else { return nil }
            let noticeStatus: RPGDurableNoticeStatus
            switch statusKind {
            case .success: noticeStatus = .accepted
            case .rejection: noticeStatus = .rejected
            case .authorityExhausted: noticeStatus = .requestExhausted
            default: return nil
            }
            identity = .durable(durable, status: noticeStatus)
            if persistenceText == "durablePending" {
                persistence = .durableInboxPendingRender
                acknowledgement = .afterCommittedModelRevision(7)
            } else {
                persistence = .durableInboxAcknowledged
                acknowledgement = .acknowledged
            }
        default: return nil
        }
        let canonicalDetail = detail ?? statusOperationText(operation) + " — " + statusTargetText(target)
        return RPGStatusPresentation(identity: identity, operation: operation, target: target,
            kind: statusKind, rawDetail: canonicalDetail, persistence: persistence,
            acknowledgement: acknowledgement)
    }

    private static func makeStatus(for selector: RPGUIHarnessSelector,
                                   authorityPhase: RPGAuthorityPresentationPhase,
                                   authorityRequestIdentity: String?) -> RPGStatusPresentation? {
        switch selector {
        case .status(let kind, let operation, let target, let persistence):
            return makeStatus(kind: kind, operation: operation, target: target,
                persistence: persistence, authorityPhase: authorityPhase,
                authorityRequestIdentity: authorityRequestIdentity)
        case .error(let kind, let targetKind, let registeredID):
            if kind == "persistenceFailure" {
                let displayName = targetKind == "skill"
                    ? (rpgSkillDefinition(registeredID)?.displayName ?? "Registered skill")
                    : (rpgSpellDefinition(registeredID)?.displayName ?? "Registered spell")
                return makeStatus(kind: kind, operation: "saveSlots", target: "character",
                    persistence: "local", authorityPhase: authorityPhase,
                    authorityRequestIdentity: authorityRequestIdentity,
                    detail: "Quick-slot save after viewing " +
                        (targetKind == "skill" ? "skill" : "spell") + " — " + displayName)
            }
            return makeStatus(kind: kind, operation: "useSelected", target: registeredID,
                persistence: "local", authorityPhase: authorityPhase,
                authorityRequestIdentity: authorityRequestIdentity,
                detail: (targetKind == "skill" ? "Skill" : "Spell") +
                    " action — " + (targetKind == "skill"
                        ? (rpgSkillDefinition(registeredID)?.displayName ?? "")
                        : (rpgSpellDefinition(registeredID)?.displayName ?? "")))
        default: return nil
        }
    }

    private static func statusOperationText(_ operation: RPGStatusOperation) -> String {
        switch operation {
        case .sheet: return "Character sheet operation"
        case .saveQuickSlots: return "Save quick slots"
        case .cyclePreparedAction: return "Cycle prepared action"
        case .usePreparedAction: return "Use selected action"
        case .useQuickSlot: return "Use quick slot"
        }
    }

    private static func statusTargetText(_ target: RPGStatusTarget) -> String {
        switch target {
        case .character: return "Character"
        case .skill(let id): return rpgSkillDefinition(id)?.displayName ?? "Registered skill"
        case .spell(let id): return rpgSpellDefinition(id)?.displayName ?? "Registered spell"
        case .attribute(let id):
            switch id {
            case .strength: return "Strength"
            case .dexterity: return "Dexterity"
            case .endurance: return "Endurance"
            case .intelligence: return "Intelligence"
            case .luck: return "Luck"
            }
        case .slot(let slot): return "Quick slot " + String(slot + 1)
        case .equipment(let id):
            switch id {
            case "apprenticeFocus": return "Apprentice Focus"
            case "heldMeleeWeapon": return "Held melee weapon"
            case "heldBowAndArrow": return "Held bow and arrow"
            case "heldPickaxe": return "Held pickaxe"
            default: return "Held tool"
            }
        case .permission(let id):
            switch id {
            case "build": return "Build permission"
            case "container": return "Container permission"
            default: return "Block-target build permission"
            }
        }
    }

    private static func statusPersistenceText(_ persistence: RPGStatusPersistence) -> String {
        switch persistence {
        case .localUntilReplaced: return "Local until replaced"
        case .authorityPhase: return "Authority phase"
        case .durableInboxPendingRender: return "Durable pending render"
        case .durableInboxAcknowledged: return "Durable acknowledged"
        }
    }

    private static func statusAcknowledgementText(
        _ acknowledgement: RPGStatusAcknowledgementEligibility
    ) -> String {
        switch acknowledgement {
        case .never: return "Never"
        case .afterCommittedModelRevision(let revision):
            return "After committed model revision " + String(revision)
        case .acknowledged: return "Acknowledged"
        }
    }

    private static func repairedRankState(skillID: String, rank: Int,
                                          presentation: String) -> RPGCharacterState? {
        guard let skill = rpgSkillDefinition(skillID),
              var state = rpgScreenFixture(pathID: skill.pathID, branchID: skill.branchID),
              let node = rpgSkillNodeIndex(skillID),
              let branch = rpgBranchDefinition(skill.branchID) else { return nil }
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        state = repairRPGCharacterState(state)
        guard state.created, state.level == RPG_LEVEL_CAP else { return nil }

        func raiseRequirements(for definition: RPGSkillDefinition,
                               in state: inout RPGCharacterState) -> Bool {
            for requirement in definition.requirements {
                while state.attributes.value(requirement.attribute) < requirement.minimum {
                    guard rpgSpendAttributePoint(requirement.attribute, in: &state) == nil else {
                        return false
                    }
                }
            }
            return true
        }
        func learn(_ id: String, through targetRank: Int,
                   in state: inout RPGCharacterState) -> Bool {
            guard let definition = rpgSkillDefinition(id),
                  raiseRequirements(for: definition, in: &state) else { return false }
            if let skillNode = rpgSkillNodeIndex(id), skillNode > 0,
               let skillBranch = rpgBranchDefinition(definition.branchID),
               !learn(skillBranch.skillIDs[skillNode - 1], through: 2, in: &state) {
                return false
            }
            while (state.skillRanks[id] ?? 0) < targetRank {
                guard rpgLearnSkill(id, in: &state) == nil else { return false }
            }
            return true
        }

        let currentRank: Int
        switch presentation {
        case "purchased": currentRank = rank + 1
        case "current": currentRank = rank
        case "nextLegal", "locked": currentRank = rank - 1
        case "future": currentRank = rank - 2
        default: return nil
        }
        if node > 0, presentation == "nextLegal" {
            guard learn(branch.skillIDs[node - 1], through: 2, in: &state) else { return nil }
        }
        if currentRank > 0, !learn(skillID, through: currentRank, in: &state) { return nil }
        if presentation == "locked" {
            state.authorityRevision = RPG_MAX_NORMAL_AUTHORITY_REVISION
            state = repairRPGCharacterState(state)
        }
        let projected = rpgPathProjection(pathID: skill.pathID, state: state)?.ranks.first {
            $0.skillID == skillID && $0.rank == rank
        }
        let actual = projected.map { value -> String in
            if value.current { return "current" }
            if value.purchased { return "purchased" }
            if let evaluation = value.nextEvaluation {
                return evaluation.permitted ? "nextLegal" : "locked"
            }
            return "future"
        }
        return actual == presentation ? state : nil
    }

    private static func maximallyPreparedState(pathID: String,
                                               branchID: String) -> (RPGCharacterState, [String])? {
        guard var base = rpgScreenFixture(pathID: pathID, branchID: branchID) else { return nil }
        base.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        base = repairRPGCharacterState(base)
        for id in base.preparedSkillIDs { _ = rpgUnprepareSkill(id, in: &base) }
        for id in base.preparedSpellIDs { _ = rpgUnprepareSpell(id, in: &base) }

        var candidates = RPG_SKILL_DEFINITIONS.filter {
            $0.pathID == pathID && $0.kind == .active
        }.map {
            PreparedCandidate(kind: .skill, id: $0.id,
                unlockingSkillID: $0.id, unlockingRank: 1)
        }
        let pathSkills = RPG_SKILL_DEFINITIONS.filter { $0.pathID == pathID }
        for spell in RPG_SPELL_DEFINITIONS {
            var unlockers: [(String, Int)] = []
            for skill in pathSkills {
                for unlock in skill.spellUnlocks where unlock.spellID == spell.id {
                    unlockers.append((skill.id, unlock.rank))
                }
            }
            unlockers.sort { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
            }
            if let unlocker = unlockers.first {
                candidates.append(PreparedCandidate(kind: .spell, id: spell.id,
                    unlockingSkillID: unlocker.0, unlockingRank: unlocker.1))
            }
        }
        guard !candidates.isEmpty, candidates.count <= 16 else { return nil }

        func attain(_ candidate: PreparedCandidate,
                    from initial: RPGCharacterState) -> RPGCharacterState? {
            var state = initial
            func meetRequirements(_ skill: RPGSkillDefinition) -> Bool {
                for requirement in skill.requirements {
                    while state.attributes.value(requirement.attribute) < requirement.minimum {
                        guard rpgSpendAttributePoint(requirement.attribute, in: &state) == nil else {
                            return false
                        }
                    }
                }
                return true
            }
            func learn(_ skillID: String, through rank: Int) -> Bool {
                guard let skill = rpgSkillDefinition(skillID), meetRequirements(skill) else {
                    return false
                }
                if let node = rpgSkillNodeIndex(skillID), node > 0,
                   let branch = rpgBranchDefinition(skill.branchID),
                   !learn(branch.skillIDs[node - 1], through: 2) { return false }
                while (state.skillRanks[skillID] ?? 0) < rank {
                    guard rpgLearnSkill(skillID, in: &state) == nil else { return false }
                }
                return true
            }
            guard learn(candidate.unlockingSkillID, through: candidate.unlockingRank) else {
                return nil
            }
            switch candidate.kind {
            case .skill:
                guard rpgPrepareSkill(candidate.id, in: &state) == nil else { return nil }
            case .spell:
                guard rpgPrepareSpell(candidate.id, in: &state) == nil else { return nil }
            }
            return state
        }

        // Deterministic inclusion-maximal search: at most 16 registry-stable candidates and 256
        // legal-transition simulations. The stable score prefers lower spent skill points, then
        // fewer attribute increases, then the canonical token. This does not claim globally
        // maximum cardinality; it proves no remaining candidate is attainable when it stops below
        // the nine-slot capacity.
        var state = base
        var tokens: [String] = []
        var remaining = candidates
        var attempts = 0
        var stoppedWithoutAttainableCandidate = false
        while tokens.count < 9, !remaining.isEmpty {
            var best: (index: Int, state: RPGCharacterState, score: (Int, Int, String))?
            for (index, candidate) in remaining.enumerated() {
                attempts += 1
                guard attempts <= 256, let next = attain(candidate, from: state) else { continue }
                let attributeIncrease = next.attributes.total - base.attributes.total
                let score = (rpgSpentSkillPoints(next), attributeIncrease, candidate.token)
                if best == nil || score < best!.score {
                    best = (index, next, score)
                }
            }
            guard let best else {
                stoppedWithoutAttainableCandidate = true
                break
            }
            state = best.state
            tokens.append(remaining[best.index].token)
            remaining.remove(at: best.index)
        }
        guard tokens.count == 9 || remaining.isEmpty || stoppedWithoutAttainableCandidate else {
            return nil
        }
        return tokens.isEmpty ? nil : (state, tokens)
    }

    public static func build(_ bootstrap: RPGUIHarnessBootstrap) -> RPGUIHarnessFixture? {
        let phase = bootstrap.authority.phase
        let requestID = (phase == .localReady || phase == .unavailable) ? nil : String(repeating: "a", count: 64)
        let fixtureStatus = makeStatus(for: bootstrap.selector, authorityPhase: phase,
                                       authorityRequestIdentity: requestID)
        switch bootstrap.selector {
        case .status, .error:
            guard fixtureStatus != nil else { return nil }
        default: break
        }
        guard let authority = try? RPGAuthorityPresentation(validating: phase, requestIdentity: requestID,
            status: fixtureStatus, semanticRevision: fixtureStatus == nil ? 1 : 2) else { return nil }
        let size = bootstrap.viewport.size
        var state = RPGCharacterState.uncreated()
        var creation = rpgInitialCreationSession()
        var tutorial = RPGTutorialState(seenVersion: RPG_TUTORIAL_VERSION, page: nil)
        var tab: RPGCharacterTab = .character
        var focus: RPGUIElementID?
        var selection: RPGScreenSelection?
        var quickSlots = RPGQuickSlotPreferences.empty
        var caseMetadata = bootstrap.selectorText
        var inventoryCapacitySummary = "The starter kit fits in available inventory capacity."
        var inventoryCapacityAvailable = true

        func install(_ pathID: String, _ branchID: String) -> Bool {
            guard let fixture = rpgScreenFixture(pathID: pathID, branchID: branchID) else { return false }
            state = fixture
            return true
        }
        switch bootstrap.selector {
        case .creation(let step, let pathID, let branchID, let profile):
            guard case .success(let selected) = rpgReduceCreationSession(creation, command: .selectPath(pathID)),
                  case .success(let branched) = rpgReduceCreationSession(selected, command: .selectBranch(branchID)) else { return nil }
            creation = branched
            creation.step = step
            if let index = creation.pathDrafts.firstIndex(where: { $0.pathID == pathID }) {
                switch profile {
                case "editedValid":
                    guard let starterID = rpgBranchDefinition(branchID)?.skillIDs.first,
                          let starter = rpgSkillDefinition(starterID) else { return nil }
                    var attributes = creation.pathDrafts[index].attributes
                    let minimums = Dictionary(uniqueKeysWithValues:
                        starter.requirements.map { ($0.attribute, $0.minimum) })
                    guard let donor = RPG_ATTRIBUTE_DISPLAY_ORDER.reversed().first(where: {
                        attributes.value($0) - 1 >= max(
                            RPGAttributes.minimum, minimums[$0] ?? RPGAttributes.minimum)
                    }), let recipient = RPG_ATTRIBUTE_DISPLAY_ORDER.first(where: {
                        $0 != donor && attributes.value($0) < RPGAttributes.maximumAtCreation
                    }) else { return nil }
                    attributes.set(donor, attributes.value(donor) - 1)
                    attributes.set(recipient, attributes.value(recipient) + 1)
                    creation.pathDrafts[index].attributes = attributes
                case "underBudget": creation.pathDrafts[index].attributes.luck -= 1
                case "unmetRequirement":
                    if let starterID = rpgBranchDefinition(branchID)?.skillIDs.first,
                       let requirement = rpgSkillDefinition(starterID)?.requirements.first {
                        var attributes = creation.pathDrafts[index].attributes
                        let oldValue = attributes.value(requirement.attribute)
                        let newValue = max(RPGAttributes.minimum, requirement.minimum - 1)
                        attributes.set(requirement.attribute, newValue)
                        let delta = oldValue - newValue
                        if let compensation = RPG_ATTRIBUTE_DISPLAY_ORDER.first(where: {
                            $0 != requirement.attribute && attributes.value($0) + delta <= RPGAttributes.maximumAtCreation
                        }) {
                            attributes.set(compensation, attributes.value(compensation) + delta)
                        }
                        creation.pathDrafts[index].attributes = attributes
                    }
                default: break
                }
            }
            if profile == "inventoryFull" {
                caseMetadata += ":starter inventory full"
                let reason = "Inventory is full; the starter kit does not fit."
                inventoryCapacitySummary = reason
                inventoryCapacityAvailable = false
                if step == .review {
                    let reviewID = RPGUIElementID(rawValue: "creation:review")!
                    focus = RPGUIElementID.operation(owner: reviewID, name: "create")
                }
            }
        case .tutorial(let page, let pathID, let branchID):
            guard install(pathID, branchID) else { return nil }
            tutorial = RPGTutorialState(seenVersion: 0, page: page)
        case .tab(let pathID, let branchID, let selectedTab):
            guard install(pathID, branchID) else { return nil }; tab = selectedTab
        case .skill(let skillID, let rank, let rankState):
            guard let repaired = repairedRankState(
                skillID: skillID, rank: rank, presentation: rankState) else { return nil }
            state = repaired
            tab = .skills; focus = .rank(skillID: skillID, rank: rank)
        case .active(let skillID, let actionState):
            guard let skill = rpgSkillDefinition(skillID) else { return nil }
            if actionState == "unknown" {
                guard let path = rpgPathDefinition(skill.pathID),
                      let otherBranch = path.branchIDs.first(where: { $0 != skill.branchID }),
                      install(skill.pathID, otherBranch) else { return nil }
            } else {
                guard let repaired = repairedRankState(
                    skillID: skillID, rank: 1, presentation: "current") else { return nil }
                state = repaired
            }
            tab = .actives
            selection = RPGScreenSelection(selectedSemanticID: .skill(skillID),
                                           inspectorItemID: .skill(skillID))
            if actionState == "known" { _ = rpgUnprepareSkill(skillID, in: &state) }
            if ["prepared", "selected", "slotted"].contains(actionState) {
                guard rpgPrepareSkill(skillID, in: &state) == nil else { return nil }
            }
            if actionState == "selected" {
                guard rpgSelectPreparedSkill(skillID, in: &state) == nil else { return nil }
            }
            if actionState == "slotted" {
                quickSlots = rpgNormalizeQuickSlotPreferences(
                    RPGQuickSlotPreferences(tokens: [
                        rpgPreparedActionToken(kind: .skill, id: skillID),
                    ]), against: state)
            }
        case .spell(let spellID, let spellState):
            guard let unlock = RPG_SKILL_DEFINITIONS.lazy.compactMap({ skill in
                skill.spellUnlocks.first(where: { $0.spellID == spellID }).map {
                    (skill, $0.rank)
                }
            }).first else { return nil }
            if spellState == "locked" {
                guard let path = rpgPathDefinition(unlock.0.pathID),
                      let branchID = path.branchIDs.first(where: { branchID in
                        guard let candidate = rpgScreenFixture(
                            pathID: path.id, branchID: branchID) else { return false }
                        return !candidate.knownSpellIDs.contains(spellID)
                      }), install(path.id, branchID) else { return nil }
            } else {
                if let prepared = maximallyPreparedState(
                    pathID: unlock.0.pathID, branchID: unlock.0.branchID),
                   prepared.0.knownSpellIDs.contains(spellID) {
                    state = prepared.0
                } else {
                    guard let repaired = repairedRankState(
                        skillID: unlock.0.id, rank: unlock.1,
                        presentation: "current") else { return nil }
                    state = repaired
                }
                guard state.knownSpellIDs.contains(spellID) else { return nil }
                for preparedID in state.preparedSpellIDs {
                    _ = rpgUnprepareSpell(preparedID, in: &state)
                }
            }
            tab = .spells
            if spellState == "known" { _ = rpgUnprepareSpell(spellID, in: &state) }
            if ["prepared", "selected", "slotted"].contains(spellState) {
                if spellState != "selected",
                   let other = state.knownSpellIDs.first(where: { $0 != spellID }) {
                    guard rpgPrepareSpell(other, in: &state) == nil,
                          rpgSelectPreparedSpell(other, in: &state) == nil else { return nil }
                }
                guard rpgPrepareSpell(spellID, in: &state) == nil else { return nil }
            }
            if spellState == "selected" {
                guard rpgSelectPreparedSpell(spellID, in: &state) == nil else { return nil }
            }
            if spellState == "slotted" {
                quickSlots = rpgNormalizeQuickSlotPreferences(
                    RPGQuickSlotPreferences(tokens: [
                        rpgPreparedActionToken(kind: .spell, id: spellID),
                    ]), against: state)
            }
        case .slots(let pathID, let branchID, let selected, let profile):
            guard install(pathID, branchID) else { return nil }; tab = .actives; focus = .slot(selected)
            if profile != "empty" {
                guard let prepared = maximallyPreparedState(
                    pathID: pathID, branchID: branchID), !prepared.1.isEmpty else { return nil }
                state = prepared.0
            }
            let tokens = state.preparedSkillIDs.map {
                rpgPreparedActionToken(kind: .skill, id: $0)
            } + state.preparedSpellIDs.map {
                rpgPreparedActionToken(kind: .spell, id: $0)
            }
            switch profile {
            case "sparse":
                var values = Array(repeating: Optional<String>.none, count: 9)
                if let first = tokens.first { values[0] = first }
                if tokens.count > 1 { values[4] = tokens[1] }
                quickSlots = RPGQuickSlotPreferences(tokens: values)
            case "maximal": quickSlots = RPGQuickSlotPreferences(tokens: Array(tokens.prefix(9)))
            case "repairInvalid":
                guard let known = tokens.first else { return nil }
                let raw = RPGQuickSlotPreferences(tokens: [known, known, "skill:unknown"])
                quickSlots = raw
                caseMetadata += "|raw=" + raw.tokens.map { $0 ?? "nil" }.joined(separator: ",")
            default: quickSlots = .empty
            }
            quickSlots = rpgNormalizeQuickSlotPreferences(quickSlots, against: state)
            if profile == "repairInvalid" {
                caseMetadata += "|normalized=" + quickSlots.tokens.map { $0 ?? "nil" }.joined(separator: ",")
            }
        case .status:
            caseMetadata = "Status fixture"
            guard let path = RPG_PATH_DEFINITIONS.first, let branch = path.branchIDs.first,
                  install(path.id, branch) else { return nil }
        case .error:
            caseMetadata = "Error fixture"
            guard let path = RPG_PATH_DEFINITIONS.first, let branch = path.branchIDs.first,
                  install(path.id, branch) else { return nil }
        }
        let scope = try? RPGLocalPreferenceScope.validatedLocalWorld("harness-world")
        let candidateInput = RPGScreenModelInput(
            state: state, quickSlots: quickSlots,
            localPreferenceScope: phase == .unavailable ? nil : scope,
            localPreferenceRevision: 1,
            localPreferenceWritable: phase != .unavailable,
            worldEntryGeneration: 1, authority: authority,
            rulesGeneration: 1, inventoryRevision: 1, equipmentFocusRevision: 1,
            inventoryCapacitySummary: inventoryCapacitySummary,
            inventoryCapacityAvailable: inventoryCapacityAvailable,
            creation: creation, tutorial: tutorial,
            viewportWidth: size.0, viewportHeight: size.1, tab: tab, focusedID: focus,
            selection: selection,
            highContrast: bootstrap.appearance.highContrast,
            reduceMotion: bootstrap.appearance.reduceMotion)
        let candidateModel = rpgBuildScreenModel(candidateInput)
        let input: RPGScreenModelInput
        let model: RPGScreenModel
        if let requestedID = focus {
            guard let candidateTarget = candidateModel.descriptors.first(where: {
                $0.id == requestedID && $0.isFocusable
            }), let revealedOffset = rpgRevealScrollOffset(
                descriptor: candidateTarget, in: candidateModel,
                currentOffset: candidateInput.scrollOffset) else { return nil }
            let candidateRegion = candidateTarget.layoutRegion
            let candidateCommandFingerprint = candidateTarget.actionCommand.map(
                rpgSemanticCommandFingerprint)
            let finalInput = candidateInput.withScrollOffset(revealedOffset)
            let finalModel = rpgBuildScreenModel(finalInput)
            guard finalInput.scrollOffset == revealedOffset,
                  finalModel.scrollOffset == revealedOffset,
                  finalModel.focusedID == requestedID,
                  let finalTarget = finalModel.descriptors.first(where: {
                      $0.id == requestedID && $0.isFocusable
                  }), finalTarget.layoutRegion == candidateRegion,
                  finalTarget.actionCommand.map(rpgSemanticCommandFingerprint) ==
                    candidateCommandFingerprint,
                  finalTarget.visibleFrame == finalTarget.frame,
                  rpgDescriptorVisualLinesFit(
                      frame: finalTarget.frame, iconAssetID: finalTarget.iconAssetID,
                      visualLines: finalTarget.visualLines) else { return nil }
            if finalTarget.layoutRegion == .scrollingContent {
                guard finalModel.contentFrame.contains(finalTarget.frame) else { return nil }
            }
            input = finalInput
            model = finalModel
        } else {
            input = candidateInput
            model = candidateModel
        }
        let presentation = rpgAuthorityPhasePresentation(phase)
        var lines = [
            "RPG authority|value=\(presentation.visibleTitle)|help=\(presentation.visibleHelp)|announcement=\(presentation.voiceOverAnnouncement)",
            "case|\(caseMetadata)",
            "appearance|highContrast=\(bootstrap.appearance.highContrast)|reduceMotion=\(bootstrap.appearance.reduceMotion)",
        ]
        if let status = fixtureStatus {
            lines.append("RPG status|id=\(status.identity.stableID ?? "")|icon=\(rpgStatusIconID(status.kind))|kind=\(rpgStatusLeadingText(status.kind))|operation=\(statusOperationText(status.operation))|target=\(statusTargetText(status.target))|text=\(status.text)|accessibility=\(status.accessibilityText)|acknowledgement=\(statusAcknowledgementText(status.acknowledgement))|persistence=\(statusPersistenceText(status.persistence))")
        }
        lines += model.descriptors.map { descriptor in
            "\(descriptor.id.rawValue)|role=\(descriptor.role.rawValue)|focusable=\(descriptor.isFocusable)|actionable=\(descriptor.isActionable)|enabled=\(descriptor.enabled)|locked=\(descriptor.locked)|selected=\(descriptor.selected)|prepared=\(descriptor.prepared)|slotted=\(descriptor.slotted)|value=\(descriptor.value)|help=\(descriptor.help)"
        }
        lines.sort()
        let bounded = lines.prefix(512).map { String($0.prefix(1_024)) }.joined(separator: "\n")
        guard bounded.utf8.count <= 65_536 else { return nil }
        return RPGUIHarnessFixture(model: model, modelInput: input, status: fixtureStatus,
            characterState: state, quickSlots: quickSlots, summary: bounded)
    }
}
