import CryptoKit
import Foundation

public enum RPGCreationStep: String, CaseIterable, Codable { case path, branch, attributes, review }
public enum RPGCharacterTab: String, CaseIterable, Codable { case character, skills, actives, spells, progression }
public enum RPGFocusDirection: String, Codable { case up, down, left, right }

public enum RPGSemanticCommand: Equatable {
    case moveFocus(RPGFocusDirection)
    case focusNext
    case focusPrevious
    case activate
    case back
    case previousTab
    case nextTab
    case scrollRows(Int)
    case openCharacter
    case cyclePreparedAction
    case useSelectedAction
    case useQuickSlot(Int)
    case choosePath(String)
    case chooseBranch(String)
    case creationBack
    case creationNext
    case resetAttributes
    case adjustAttribute(RPGAttributeID, Int)
    case selectTab(RPGCharacterTab)
    case selectElement(RPGUIElementID)
    case create(RPGCreationDraft)
    case rankUp(String)
    case spendAttribute(RPGAttributeID)
    case prepareSkill(String)
    case unprepareSkill(String)
    case prepareSpell(String)
    case unprepareSpell(String)
    case selectSkill(String)
    case selectSpell(String)
    case assignSlot(token: String, slot: Int)
    case moveSlot(from: Int, to: Int)
    case clearSlot(Int)
    case tutorialBack
    case tutorialNext
    case tutorialFinish
    case tutorialSkip
}

public enum RPGSemanticActivationSource: String, CaseIterable, Codable {
    case mouse, keyboard, controller, accessibility
}

public enum RPGSemanticActivationResult: Equatable {
    case dispatched(serial: UInt64)
    case staleRequiresFreshActivation
    case unavailable
    case invalidOrReplayedReceipt
    case dispatchSerialExhausted
}

public struct RPGUIElementID: RawRepresentable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 160,
              rawValue.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else { return nil }
        self.rawValue = rawValue
    }

    public static func < (lhs: RPGUIElementID, rhs: RPGUIElementID) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func creationStep(_ step: RPGCreationStep) -> RPGUIElementID {
        RPGUIElementID(rawValue: "creation-step:\(step.rawValue)")!
    }
    public static func path(_ id: String) -> RPGUIElementID { RPGUIElementID(rawValue: "path:\(id)")! }
    public static func branch(_ id: String) -> RPGUIElementID { RPGUIElementID(rawValue: "branch:\(id)")! }
    public static func tab(_ tab: RPGCharacterTab) -> RPGUIElementID { RPGUIElementID(rawValue: "tab:\(tab.rawValue)")! }
    public static func skill(_ id: String) -> RPGUIElementID { RPGUIElementID(rawValue: "skill:\(id)")! }
    public static func rank(skillID: String, rank: Int) -> RPGUIElementID {
        RPGUIElementID(rawValue: "skill:\(skillID):rank:\(rank)")!
    }
    public static func operation(owner: RPGUIElementID, name: String) -> RPGUIElementID {
        RPGUIElementID(rawValue: "\(owner.rawValue):operation:\(name)")!
    }
    public static func tutorial(_ page: Int, pathID: String, branchID: String) -> RPGUIElementID {
        RPGUIElementID(rawValue: "tutorial:\(page):\(pathID):\(branchID)")!
    }
    public static func slot(_ slot: Int) -> RPGUIElementID { RPGUIElementID(rawValue: "slot:\(slot)")! }
    public static func action(kind: String, id: String) -> RPGUIElementID {
        RPGUIElementID(rawValue: "action:\(kind):\(id)")!
    }
    public static func attribute(_ attribute: RPGAttributeID) -> RPGUIElementID {
        RPGUIElementID(rawValue: "attribute:\(attribute.rawValue)")!
    }
    public static func spell(_ id: String) -> RPGUIElementID { RPGUIElementID(rawValue: "spell:\(id)")! }
}

public struct RPGCreationPathDraft: Equatable {
    public let pathID: String
    public var branchID: String
    public var attributes: RPGAttributes
}

public struct RPGCreationSession: Equatable {
    public var step: RPGCreationStep
    public var selectedPathID: String
    public var pathDrafts: [RPGCreationPathDraft]

    public var selectedDraft: RPGCreationPathDraft? {
        pathDrafts.first { $0.pathID == selectedPathID }
    }
}

public enum RPGCreationSessionCommand: Equatable {
    case selectPath(String)
    case selectBranch(String)
    case adjustAttribute(RPGAttributeID, Int)
    case resetToPreset
    case back
    case next
}

public enum RPGCreationSessionError: Error, Equatable {
    case unknownPath(String)
    case branchDoesNotBelongToPath(String)
    case starterRegistryMismatch
    case invalidAttributeValue(RPGAttributeID, Int)
    case invalidAttributeBudget(Int)
    case unmetStarterRequirement(RPGAttributeID, required: Int)
    case cannotAdvance
}

public func rpgInitialCreationSession() -> RPGCreationSession {
    let drafts = RPG_PATH_DEFINITIONS.map { path -> RPGCreationPathDraft in
        RPGCreationPathDraft(pathID: path.id,
                             branchID: path.branchIDs.first ?? "",
                             attributes: rpgCreationPreset(pathID: path.id) ?? .defaultCreation)
    }
    return RPGCreationSession(step: .path,
                              selectedPathID: RPG_PATH_DEFINITIONS.first?.id ?? "warden",
                              pathDrafts: drafts)
}

private func validatedStarter(pathID: String, branchID: String) -> String? {
    guard let path = rpgPathDefinition(pathID), path.branchIDs.contains(branchID),
          let branch = rpgBranchDefinition(branchID), branch.pathID == pathID,
          let starter = branch.skillIDs.first, path.starterSkillIDs.contains(starter) else { return nil }
    return starter
}

public func rpgCreationDraft(from session: RPGCreationSession) -> Result<RPGCreationDraft, RPGCreationSessionError> {
    guard let draft = session.selectedDraft else { return .failure(.unknownPath(session.selectedPathID)) }
    guard let starter = validatedStarter(pathID: draft.pathID, branchID: draft.branchID) else {
        return .failure(.starterRegistryMismatch)
    }
    var total = 0
    for attribute in RPG_ATTRIBUTE_DISPLAY_ORDER {
        let addition = total.addingReportingOverflow(draft.attributes.value(attribute))
        guard !addition.overflow else { return .failure(.invalidAttributeBudget(Int.max)) }
        total = addition.partialValue
    }
    guard total == RPGAttributes.creationBudget else {
        return .failure(.invalidAttributeBudget(total))
    }
    for attribute in RPG_ATTRIBUTE_DISPLAY_ORDER {
        let value = draft.attributes.value(attribute)
        guard (RPGAttributes.minimum...RPGAttributes.maximumAtCreation).contains(value) else {
            return .failure(.invalidAttributeValue(attribute, value))
        }
    }
    guard let starterDefinition = rpgSkillDefinition(starter) else {
        return .failure(.starterRegistryMismatch)
    }
    if let unmet = starterDefinition.requirements.first(where: {
        draft.attributes.value($0.attribute) < $0.minimum
    }) {
        return .failure(.unmetStarterRequirement(unmet.attribute, required: unmet.minimum))
    }
    return .success(RPGCreationDraft(pathID: draft.pathID, attributes: draft.attributes,
                                     starterSkillID: starter, starterSpellIDs: []))
}

public func rpgReduceCreationSession(_ session: RPGCreationSession,
                                     command: RPGCreationSessionCommand)
    -> Result<RPGCreationSession, RPGCreationSessionError> {
    var next = session
    switch command {
    case .selectPath(let pathID):
        guard rpgPathDefinition(pathID) != nil, next.pathDrafts.contains(where: { $0.pathID == pathID }) else {
            return .failure(.unknownPath(pathID))
        }
        next.selectedPathID = pathID
    case .selectBranch(let branchID):
        guard let path = rpgPathDefinition(next.selectedPathID), path.branchIDs.contains(branchID),
              validatedStarter(pathID: path.id, branchID: branchID) != nil else {
            return .failure(.branchDoesNotBelongToPath(branchID))
        }
        guard let index = next.pathDrafts.firstIndex(where: { $0.pathID == path.id }) else {
            return .failure(.unknownPath(path.id))
        }
        next.pathDrafts[index].branchID = branchID
    case .adjustAttribute(let attribute, let delta):
        guard let index = next.pathDrafts.firstIndex(where: { $0.pathID == next.selectedPathID }) else {
            return .failure(.unknownPath(next.selectedPathID))
        }
        let currentValue = next.pathDrafts[index].attributes.value(attribute)
        let addition = currentValue.addingReportingOverflow(delta)
        guard !addition.overflow else { return .failure(.invalidAttributeValue(attribute, currentValue)) }
        let value = addition.partialValue
        guard (RPGAttributes.minimum...RPGAttributes.maximumAtCreation).contains(value) else {
            return .failure(.invalidAttributeValue(attribute, value))
        }
        next.pathDrafts[index].attributes.set(attribute, value)
    case .resetToPreset:
        guard let preset = rpgCreationPreset(pathID: next.selectedPathID),
              let index = next.pathDrafts.firstIndex(where: { $0.pathID == next.selectedPathID }) else {
            return .failure(.unknownPath(next.selectedPathID))
        }
        next.pathDrafts[index].attributes = preset
    case .back:
        switch next.step {
        case .path: return .failure(.cannotAdvance)
        case .branch: next.step = .path
        case .attributes: next.step = .branch
        case .review: next.step = .attributes
        }
    case .next:
        switch next.step {
        case .path:
            guard rpgPathDefinition(next.selectedPathID) != nil else { return .failure(.cannotAdvance) }
            next.step = .branch
        case .branch:
            guard let draft = next.selectedDraft,
                  validatedStarter(pathID: draft.pathID, branchID: draft.branchID) != nil else {
                return .failure(.starterRegistryMismatch)
            }
            next.step = .attributes
        case .attributes:
            switch rpgCreationDraft(from: next) {
            case .success: next.step = .review
            case .failure(let error): return .failure(error)
            }
        case .review:
            return .failure(.cannotAdvance)
        }
    }
    return .success(next)
}

public let RPG_ATTRIBUTE_DISPLAY_ORDER: [RPGAttributeID] = [.strength, .dexterity, .endurance, .intelligence, .luck]

public struct RPGPathCardModel: Equatable {
    public let pathID: String
    public let iconAssetID: String
    public let displayName: String
    public let roleText: String
    public let primaryText: String
    public let presetText: String
    public let selected: Bool
    public let accessibilityLabel: String
    public let accessibilityHelp: String
    public let wrappedVisualLines: [String]
    public let focusSelection: RPGScreenSelection
    public let chooseCommand: RPGSemanticCommand?
}

private func shortAttribute(_ id: RPGAttributeID) -> String {
    switch id {
    case .strength: return "STR"
    case .dexterity: return "DEX"
    case .endurance: return "END"
    case .intelligence: return "INT"
    case .luck: return "LUCK"
    }
}

public func rpgPathCardModels(session: RPGCreationSession) -> [RPGPathCardModel] {
    RPG_PATH_DEFINITIONS.compactMap { path in
        let iconAssetID = rpgAssetIDForPath(path.id)
        guard let preset = rpgCreationPreset(pathID: path.id),
              rpgIconPixels(assetID: iconAssetID) != nil else { return nil }
        let primary = path.primaryAttributes.map(shortAttribute).joined(separator: " + ")
        let presetText = RPG_ATTRIBUTE_DISPLAY_ORDER
            .map { "\(shortAttribute($0)) \(preset.value($0))" }.joined(separator: " · ")
        let selected = path.id == session.selectedPathID
        let roleText = "Role: \(path.summary)"
        let primaryText = "Primary: \(primary)"
        let presetLine = "Preset: \(presetText)"
        let choose = selected ? "" : "; Choose \(path.displayName)"
        return RPGPathCardModel(pathID: path.id, iconAssetID: iconAssetID,
            displayName: path.displayName, roleText: roleText, primaryText: primaryText,
            presetText: presetLine, selected: selected,
            accessibilityLabel: "\(path.displayName), \(selected ? "selected" : "not selected")",
            accessibilityHelp: "\(roleText); \(primaryText); \(presetLine)\(choose)",
            wrappedVisualLines: [path.displayName, roleText, primaryText, presetLine,
                                 selected ? "Selected" : "Choose \(path.displayName)"],
            focusSelection: RPGScreenSelection(selectedSemanticID: .path(path.id)),
            chooseCommand: selected ? nil : .choosePath(path.id))
    }
}

public enum RPGSheetAuthoritativeOperation: Equatable {
    case create(RPGCreationDraft)
    case rankUp(skillID: String)
    case spendAttribute(RPGAttributeID)
    case prepareSkill(String), unprepareSkill(String), prepareSpell(String), unprepareSpell(String)
    case selectSkill(String), selectSpell(String)
}

public enum RPGSheetLocalOperation: Equatable {
    case assignSlot(token: String, slot: Int), moveSlot(from: Int, to: Int), clearSlot(Int)
    case tutorialBack, tutorialNext, tutorialFinish, tutorialSkip
}

public enum RPGAuthorityPresentationPhase: String, CaseIterable, Codable {
    case localReady, awaitingHost, committingAcceptedOwnerCheckpoint, committingRejectedOwnerCheckpoint
    case reconnecting, awaitingDispositionCheckpoint, authorityExhausted, unavailable
}

public struct RPGAuthorityPhasePresentation: Equatable {
    public let proceduralIconID: String
    public let visibleTitle: String
    public let visibleHelp: String
    public let disabledControlExplanation: String?
    public let voiceOverAnnouncement: String
}

public func rpgAuthorityPhasePresentation(_ phase: RPGAuthorityPresentationPhase) -> RPGAuthorityPhasePresentation {
    let icon: String
    let title: String
    let help: String
    let disabled: String?
    switch phase {
    case .localReady:
        icon = "authority.ready"; title = "Ready"
        help = "Character controls are available when their requirements are met."
        disabled = nil
    case .awaitingHost:
        icon = "authority.awaitingHost"; title = "Awaiting host"
        help = "Character changes are disabled until the host responds. Local quick slots remain available."
        disabled = help
    case .committingAcceptedOwnerCheckpoint:
        icon = "authority.savingAccepted"; title = "Saving accepted update"
        help = "Character changes are disabled while Elysium saves the accepted host update. Local quick slots remain available."
        disabled = help
    case .committingRejectedOwnerCheckpoint:
        icon = "authority.savingRejected"; title = "Restoring host state"
        help = "Character changes are disabled while Elysium restores the host’s character state. Local quick slots remain available."
        disabled = help
    case .reconnecting:
        icon = "authority.reconnecting"; title = "Reconnecting"
        help = "Character changes are disabled until the connection and pending request recover. Local quick slots remain available."
        disabled = help
    case .awaitingDispositionCheckpoint:
        icon = "authority.finalizing"; title = "Finalizing host response"
        help = "Character changes are disabled while Elysium finishes processing the host response. Local quick slots remain available."
        disabled = help
    case .authorityExhausted:
        icon = "authority.exhausted"; title = "Authority exhausted"
        help = "Character changes are permanently disabled for this character session. Valid local quick slots may still be moved or cleared."
        disabled = help
    case .unavailable:
        icon = "authority.unavailable"; title = "Character changes unavailable"
        help = "Character changes are unavailable in this LAN session. Quick-slot editing requires a compatible host session."
        disabled = help
    }
    return RPGAuthorityPhasePresentation(proceduralIconID: icon, visibleTitle: title,
        visibleHelp: help, disabledControlExplanation: disabled,
        voiceOverAnnouncement: "\(title). \(help)")
}

public enum RPGAuthorityPresentationError: Error, Equatable {
    case missingRequestIdentity
    case unexpectedRequestIdentity
    case invalidRequestIdentity
}

public enum RPGStatusKind: String, CaseIterable, Codable {
    case success, pending, rejection, cooldown, fatigue
    case missingFocus, missingEquipment, permissionDenied
    case persistenceFailure, authorityExhausted
}

public enum RPGStatusOperation: Equatable {
    case sheet(RPGSheetAuthoritativeOperation)
    case saveQuickSlots
    case cyclePreparedAction
    case usePreparedAction
    case useQuickSlot(Int)
}

public enum RPGStatusTarget: Equatable {
    case character
    case skill(String)
    case spell(String)
    case attribute(RPGAttributeID)
    case slot(Int)
    case equipment(String)
    case permission(String)
}

public enum RPGStatusPersistence: Equatable {
    case localUntilReplaced
    case authorityPhase
    case durableInboxPendingRender
    case durableInboxAcknowledged
}

public enum RPGStatusAcknowledgementEligibility: Equatable {
    case never
    case afterCommittedModelRevision(UInt64)
    case acknowledged
}

public enum RPGDurableNoticeStatus: String, CaseIterable, Codable {
    case accepted, rejected, outcomeEvicted, requestExhausted
}

public enum RPGDurableNoticeError: Error, Equatable {
    case invalidIdentity
    case reasonTooLong
    case messageTooLong
}

public struct RPGDurableNoticeIdentity: Equatable, Hashable {
    public let notificationID: String
    public let payloadDigest: String

    public init(notificationID: String, payloadDigest: String) throws {
        guard isLowercaseHexDigest(notificationID), isLowercaseHexDigest(payloadDigest) else {
            throw RPGDurableNoticeError.invalidIdentity
        }
        self.notificationID = notificationID
        self.payloadDigest = payloadDigest
    }
}

public struct RPGDurableNoticePayload: Equatable {
    public let identity: RPGDurableNoticeIdentity
    public let status: RPGDurableNoticeStatus
    public let reason: String
    public let message: String

    public init(identity: RPGDurableNoticeIdentity, status: RPGDurableNoticeStatus,
                reason: String, message: String) throws {
        guard reason.utf8.count <= 256 else { throw RPGDurableNoticeError.reasonTooLong }
        guard message.utf8.count <= 512 else { throw RPGDurableNoticeError.messageTooLong }
        self.identity = identity
        self.status = status
        self.reason = reason
        self.message = message
    }
}

public enum RPGStatusOperationTag: String, CaseIterable, Codable {
    case create, rankUp, spendAttribute, prepareSkill, unprepareSkill, prepareSpell, unprepareSpell
    case selectSkill, selectSpell, saveQuickSlots, cyclePreparedAction, usePreparedAction, useQuickSlot
}

public enum RPGStatusIdentity: Equatable {
    case local(counter: UInt64, operationTag: RPGStatusOperationTag)
    case authorityPhase(requestFingerprint: String, phase: RPGAuthorityPresentationPhase)
    case durable(RPGDurableNoticeIdentity, status: RPGDurableNoticeStatus)

    public var stableID: String? {
        switch self {
        case .local(let counter, let tag): return counter == 0 ? nil : "local:\(counter):\(tag.rawValue)"
        case .authorityPhase(let fingerprint, let phase):
            return isLowercaseHexDigest(fingerprint) ? "phase:\(fingerprint):\(phase.rawValue)" : nil
        case .durable(let identity, let status):
            return "notice:\(identity.notificationID):\(identity.payloadDigest):\(status.rawValue)"
        }
    }
}

public struct RPGStatusPresentation: Equatable {
    public let identity: RPGStatusIdentity
    public let operation: RPGStatusOperation
    public let target: RPGStatusTarget
    public let kind: RPGStatusKind
    public let text: String
    public let accessibilityText: String
    public let persistence: RPGStatusPersistence
    public let acknowledgement: RPGStatusAcknowledgementEligibility

    public init?(identity: RPGStatusIdentity, operation: RPGStatusOperation, target: RPGStatusTarget,
                 kind: RPGStatusKind, rawDetail: String, persistence: RPGStatusPersistence,
                 acknowledgement: RPGStatusAcknowledgementEligibility) {
        guard identity.stableID != nil, rpgStatusOperationIsValid(operation),
              rpgStatusTargetIsValid(target),
              rpgStatusOperationTargetIsCompatible(operation, target),
              rpgStatusKindOperationIsCompatible(kind, operation),
              rpgStatusLifecycleIsValid(identity: identity, operation: operation,
                                        kind: kind,
                                        persistence: persistence,
                                        acknowledgement: acknowledgement) else { return nil }
        let leading = rpgStatusLeadingText(kind)
        let displayDetail = rpgSanitizeStatusText(rawDetail, byteLimit: max(0, 157 - leading.utf8.count))
        let accessibilityDetail = rpgSanitizeStatusText(rawDetail, byteLimit: max(0, 509 - leading.utf8.count))
        let separator = displayDetail.isEmpty ? "" : ": "
        let accessibilitySeparator = accessibilityDetail.isEmpty ? "" : ": "
        self.identity = identity
        self.operation = operation
        self.target = target
        self.kind = kind
        self.text = leading + separator + displayDetail
        self.accessibilityText = leading + accessibilitySeparator + accessibilityDetail
        self.persistence = persistence
        self.acknowledgement = acknowledgement
    }
}

private func rpgStatusKindOperationIsCompatible(_ kind: RPGStatusKind,
                                                 _ operation: RPGStatusOperation) -> Bool {
    switch kind {
    case .cooldown, .fatigue, .missingFocus, .missingEquipment, .permissionDenied:
        switch operation {
        case .usePreparedAction, .useQuickSlot: return true
        default: return false
        }
    case .persistenceFailure:
        switch operation {
        case .saveQuickSlots, .sheet(.create): return true
        default: return false
        }
    case .success, .pending, .rejection, .authorityExhausted:
        return true
    }
}

private func rpgStatusOperationTag(_ operation: RPGStatusOperation) -> RPGStatusOperationTag {
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

private func rpgStatusOperationTargetIsCompatible(_ operation: RPGStatusOperation,
                                                   _ target: RPGStatusTarget) -> Bool {
    switch operation {
    case .sheet(let sheet):
        switch (sheet, target) {
        case (.create, .character): return true
        case (.rankUp(let operationID), .skill(let targetID)),
             (.prepareSkill(let operationID), .skill(let targetID)),
             (.unprepareSkill(let operationID), .skill(let targetID)),
             (.selectSkill(let operationID), .skill(let targetID)),
             (.prepareSpell(let operationID), .spell(let targetID)),
             (.unprepareSpell(let operationID), .spell(let targetID)),
             (.selectSpell(let operationID), .spell(let targetID)):
            return operationID == targetID
        case (.spendAttribute(let operationID), .attribute(let targetID)):
            return operationID == targetID
        default: return false
        }
    case .saveQuickSlots:
        switch target {
        case .character, .slot: return true
        default: return false
        }
    case .cyclePreparedAction:
        switch target {
        case .character, .skill, .spell: return true
        default: return false
        }
    case .usePreparedAction:
        switch target {
        case .character, .skill, .spell, .equipment, .permission: return true
        default: return false
        }
    case .useQuickSlot(let operationSlot):
        guard case .slot(let targetSlot) = target else { return false }
        return operationSlot == targetSlot
    }
}

private func rpgStatusLifecycleIsValid(
    identity: RPGStatusIdentity, operation: RPGStatusOperation,
    kind: RPGStatusKind,
    persistence: RPGStatusPersistence,
    acknowledgement: RPGStatusAcknowledgementEligibility
) -> Bool {
    switch identity {
    case .local(_, let tag):
        guard tag == rpgStatusOperationTag(operation),
              persistence == .localUntilReplaced,
              kind != .pending, kind != .authorityExhausted else { return false }
        if case .never = acknowledgement { return true }
        return false
    case .authorityPhase(_, let phase):
        guard phase != .localReady, phase != .unavailable,
              persistence == .authorityPhase,
              kind == (phase == .authorityExhausted ? .authorityExhausted : .pending) else {
            return false
        }
        if case .never = acknowledgement { return true }
        return false
    case .durable(_, let noticeStatus):
        let expectedKind: RPGStatusKind
        switch noticeStatus {
        case .accepted: expectedKind = .success
        case .rejected, .outcomeEvicted: expectedKind = .rejection
        case .requestExhausted: expectedKind = .authorityExhausted
        }
        guard kind == expectedKind else { return false }
        switch (persistence, acknowledgement) {
        case (.durableInboxPendingRender, .afterCommittedModelRevision(let revision)):
            return revision > 0
        case (.durableInboxAcknowledged, .acknowledged):
            return true
        default:
            return false
        }
    }
}

private func rpgStatusSymbolIsValid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
        !$0.properties.isWhitespace && $0.properties.generalCategory != .control &&
            $0.properties.generalCategory != .format
    }
}

private func rpgStatusOperationIsValid(_ operation: RPGStatusOperation) -> Bool {
    switch operation {
    case .saveQuickSlots, .cyclePreparedAction, .usePreparedAction:
        return true
    case .useQuickSlot(let slot):
        return (0..<RPG_ACTION_QUICK_SLOT_COUNT).contains(slot)
    case .sheet(let operation):
        switch operation {
        case .create(let draft):
            return rpgStatusSymbolIsValid(draft.pathID) &&
                (draft.starterSkillID.map(rpgStatusSymbolIsValid) ?? true) &&
                draft.starterSpellIDs.count <= RPG_SPELL_DEFINITIONS.count &&
                draft.starterSpellIDs.allSatisfy(rpgStatusSymbolIsValid)
        case .rankUp(let skillID), .prepareSkill(let skillID), .unprepareSkill(let skillID),
             .selectSkill(let skillID):
            return rpgStatusSymbolIsValid(skillID)
        case .prepareSpell(let spellID), .unprepareSpell(let spellID), .selectSpell(let spellID):
            return rpgStatusSymbolIsValid(spellID)
        case .spendAttribute:
            return true
        }
    }
}

private func rpgStatusTargetIsValid(_ target: RPGStatusTarget) -> Bool {
    switch target {
    case .character, .attribute:
        return true
    case .slot(let slot):
        return (0..<RPG_ACTION_QUICK_SLOT_COUNT).contains(slot)
    case .skill(let value), .spell(let value), .equipment(let value), .permission(let value):
        return rpgStatusSymbolIsValid(value)
    }
}

public func rpgStatusLeadingText(_ kind: RPGStatusKind) -> String {
    switch kind {
    case .success: return "Success"
    case .pending: return "Awaiting host"
    case .rejection: return "Rejected"
    case .cooldown: return "Cooldown"
    case .fatigue: return "Not enough fatigue"
    case .missingFocus: return "Focus required"
    case .missingEquipment: return "Equipment required"
    case .permissionDenied: return "Permission denied"
    case .persistenceFailure: return "Could not save"
    case .authorityExhausted: return "Authority exhausted"
    }
}

public func rpgStatusIconID(_ kind: RPGStatusKind) -> String {
    switch kind {
    case .success: return "status.check"
    case .pending: return "status.hourglass"
    case .rejection: return "status.cross"
    case .cooldown: return "status.clock"
    case .fatigue: return "status.fatigue"
    case .missingFocus: return "status.focus"
    case .missingEquipment: return "status.equipment"
    case .permissionDenied: return "status.lock"
    case .persistenceFailure: return "status.diskWarning"
    case .authorityExhausted: return "status.stop"
    }
}

public func rpgSanitizeStatusText(_ raw: String, byteLimit: Int) -> String {
    guard byteLimit > 0 else { return "" }
    let boundedInput = String(decoding: raw.utf8.prefix(2_048), as: UTF8.self)
    var scalars: [Unicode.Scalar] = []
    scalars.reserveCapacity(min(512, byteLimit))
    var pendingSpace = false
    for scalar in boundedInput.unicodeScalars.prefix(512) {
        let value = scalar.value
        let invisibleFormat = value == 0x061c ||
            (0x200e...0x200f).contains(value) || (0x202a...0x202e).contains(value) ||
            (0x2066...0x2069).contains(value) || value == 0x200b || value == 0x2060 ||
            scalar.properties.generalCategory == .format
        if invisibleFormat { continue }
        let controlOrSpace = value <= 0x1f || (0x7f...0x9f).contains(value) ||
            CharacterSet.whitespacesAndNewlines.contains(scalar) || value == 0x2028 || value == 0x2029
        if controlOrSpace {
            pendingSpace = !scalars.isEmpty
            continue
        }
        if pendingSpace {
            scalars.append(" ")
            pendingSpace = false
        }
        scalars.append(scalar)
    }
    var output = ""
    for scalar in scalars {
        let candidate = output + String(scalar)
        guard candidate.utf8.count <= byteLimit else { break }
        output = candidate
    }
    return output.trimmingCharacters(in: .whitespaces)
}

private func isLowercaseHexDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}

public struct RPGAuthorityPresentation: Equatable {
    public let phase: RPGAuthorityPresentationPhase
    public let requestIdentity: String?
    public let operation: RPGSheetAuthoritativeOperation?
    public let status: RPGStatusPresentation?
    public let semanticRevision: UInt64

    public init(validating phase: RPGAuthorityPresentationPhase, requestIdentity: String? = nil,
                operation: RPGSheetAuthoritativeOperation? = nil,
                status: RPGStatusPresentation? = nil,
                semanticRevision: UInt64 = 0) throws {
        let identityMustBeAbsent = phase == .localReady || phase == .unavailable
        if identityMustBeAbsent {
            guard requestIdentity == nil else { throw RPGAuthorityPresentationError.unexpectedRequestIdentity }
        } else {
            guard let requestIdentity else { throw RPGAuthorityPresentationError.missingRequestIdentity }
            guard isLowercaseHexDigest(requestIdentity) else {
                throw RPGAuthorityPresentationError.invalidRequestIdentity
            }
        }
        if let status, case .authorityPhase(let fingerprint, let statusPhase) = status.identity {
            guard requestIdentity == fingerprint, phase == statusPhase else {
                throw RPGAuthorityPresentationError.invalidRequestIdentity
            }
        }
        if let operation, let status {
            guard case .sheet(let statusOperation) = status.operation,
                  operation == statusOperation else {
                throw RPGAuthorityPresentationError.invalidRequestIdentity
            }
        }
        self.phase = phase
        self.requestIdentity = requestIdentity
        self.operation = operation
        self.status = status
        self.semanticRevision = semanticRevision
    }

    public static let localReady = try! RPGAuthorityPresentation(validating: .localReady)
    public static let unavailable = try! RPGAuthorityPresentation(validating: .unavailable)
}

public struct RPGLogicalRect: Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }
    public func contains(_ other: RPGLogicalRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}

public enum RPGSemanticRole: String, Codable { case button, staticText, tab, group, row, scrollArea, rankCell }

public enum RPGSemanticLayoutRegion: String, Codable {
    case fixed
    case scrollingContent
}

public enum RPGDescriptorAdornment: String, Codable {
    case none
    case selectedCheckDoubleBorder
    case moveLeft
    case moveRight
}

public struct RPGScreenLayout: Equatable {
    public let panelFrame: RPGLogicalRect
    public let headerFrame: RPGLogicalRect
    public let authorityChipFrame: RPGLogicalRect
    public let statusChipFrame: RPGLogicalRect?
    public let contextualDetailFrame: RPGLogicalRect?
    public let stepOrTabFrame: RPGLogicalRect
    public let contentFrame: RPGLogicalRect
    public let commandFrame: RPGLogicalRect
    public let footerHelpFrame: RPGLogicalRect

    public init(panelFrame: RPGLogicalRect, headerFrame: RPGLogicalRect,
                authorityChipFrame: RPGLogicalRect, statusChipFrame: RPGLogicalRect?,
                contextualDetailFrame: RPGLogicalRect?, stepOrTabFrame: RPGLogicalRect,
                contentFrame: RPGLogicalRect, commandFrame: RPGLogicalRect,
                footerHelpFrame: RPGLogicalRect) {
        self.panelFrame = panelFrame
        self.headerFrame = headerFrame
        self.authorityChipFrame = authorityChipFrame
        self.statusChipFrame = statusChipFrame
        self.contextualDetailFrame = contextualDetailFrame
        self.stepOrTabFrame = stepOrTabFrame
        self.contentFrame = contentFrame
        self.commandFrame = commandFrame
        self.footerHelpFrame = footerHelpFrame
    }
}

public struct RPGFocusRingToken: Equatable {
    public let lightOuterWidth: Double
    public let darkSeparationWidth: Double
}

public struct RPGFocusRingGeometry: Equatable {
    public let lightOuterFrame: RPGLogicalRect
    public let darkSeparationFrame: RPGLogicalRect
}

public func rpgFocusRingToken(highContrast: Bool) -> RPGFocusRingToken {
    RPGFocusRingToken(lightOuterWidth: highContrast ? 2 : 1,
                      darkSeparationWidth: 1)
}

public func rpgFocusRingGeometry(frame: RPGLogicalRect,
                                 token: RPGFocusRingToken) -> RPGFocusRingGeometry? {
    guard frame.isFinite, frame.width > 0, frame.height > 0,
          token.lightOuterWidth.isFinite, token.darkSeparationWidth.isFinite,
          token.lightOuterWidth > 0, token.darkSeparationWidth > 0 else { return nil }
    let outerInset = token.lightOuterWidth / 2
    let darkInset = token.lightOuterWidth + token.darkSeparationWidth / 2
    guard frame.width > darkInset * 2, frame.height > darkInset * 2 else { return nil }
    return RPGFocusRingGeometry(
        lightOuterFrame: RPGLogicalRect(
            x: frame.x + outerInset, y: frame.y + outerInset,
            width: frame.width - outerInset * 2,
            height: frame.height - outerInset * 2),
        darkSeparationFrame: RPGLogicalRect(
            x: frame.x + darkInset, y: frame.y + darkInset,
            width: frame.width - darkInset * 2,
            height: frame.height - darkInset * 2))
}

public struct RPGSemanticDescriptor: Equatable {
    public let id: RPGUIElementID
    public let role: RPGSemanticRole
    public let groupID: RPGUIElementID?
    public let label: String
    public let value: String
    public let help: String
    public let selected: Bool
    public let prepared: Bool
    public let slotted: Bool
    public let enabled: Bool
    public let locked: Bool
    public let isFocusable: Bool
    public let focusSelection: RPGScreenSelection?
    public let layoutRegion: RPGSemanticLayoutRegion
    public let iconAssetID: String?
    public let visualLines: [String]
    public let adornment: RPGDescriptorAdornment
    public let frame: RPGLogicalRect
    public let visibleFrame: RPGLogicalRect?
    public let actionCommand: RPGSemanticCommand?
    public var isActionable: Bool { actionCommand != nil && enabled }

    public init(id: RPGUIElementID, role: RPGSemanticRole, groupID: RPGUIElementID? = nil,
                label: String, value: String = "", help: String = "", selected: Bool = false,
                prepared: Bool = false, slotted: Bool = false, enabled: Bool,
                locked: Bool = false, isFocusable: Bool, focusSelection: RPGScreenSelection? = nil,
                layoutRegion: RPGSemanticLayoutRegion = .scrollingContent,
                iconAssetID: String? = nil, visualLines: [String] = [],
                adornment: RPGDescriptorAdornment = .none,
                frame: RPGLogicalRect, visibleFrame: RPGLogicalRect? = nil,
                actionCommand: RPGSemanticCommand? = nil) {
        self.id = id
        self.role = role
        self.groupID = groupID
        self.label = label
        self.value = value
        self.help = help
        self.selected = selected
        self.prepared = prepared
        self.slotted = slotted
        self.enabled = enabled
        self.locked = locked
        self.isFocusable = isFocusable
        self.focusSelection = focusSelection
        self.layoutRegion = layoutRegion
        self.iconAssetID = iconAssetID
        self.visualLines = visualLines
        self.adornment = adornment
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.actionCommand = actionCommand
    }
}

public struct RPGScreenSelection: Equatable {
    public let selectedSemanticID: RPGUIElementID
    public let inspectorItemID: RPGUIElementID?

    public init(selectedSemanticID: RPGUIElementID, inspectorItemID: RPGUIElementID? = nil) {
        self.selectedSemanticID = selectedSemanticID
        self.inspectorItemID = inspectorItemID
    }
}

public struct RPGSemanticActivationCapture: Equatable, Hashable {
    public let activationReceipt: UInt64
    public let screenInstanceID: UInt64
    public let id: RPGUIElementID
    public let semanticRevision: UInt64
    public let commandFingerprint: String
    public let semanticInputFingerprint: String

    init?(activationReceipt: UInt64, screenInstanceID: UInt64,
          id: RPGUIElementID, semanticRevision: UInt64,
          commandFingerprint: String, semanticInputFingerprint: String) {
        guard activationReceipt > 0, screenInstanceID > 0, semanticRevision > 0,
              isLowercaseHexDigest(commandFingerprint),
              isLowercaseHexDigest(semanticInputFingerprint) else { return nil }
        self.activationReceipt = activationReceipt
        self.screenInstanceID = screenInstanceID
        self.id = id
        self.semanticRevision = semanticRevision
        self.commandFingerprint = commandFingerprint
        self.semanticInputFingerprint = semanticInputFingerprint
    }
}

/// Receipt-free, origin-bound semantic tuple cached by accessibility elements. A fresh receipt may
/// be attached only by the process-global activation boundary; no current-state component is
/// substituted when the cached element is pressed.
public struct RPGSemanticActivationOrigin: Equatable, Hashable {
    public let screenInstanceID: UInt64
    public let id: RPGUIElementID
    public let semanticRevision: UInt64
    public let commandFingerprint: String
    public let semanticInputFingerprint: String

    public init?(screenInstanceID: UInt64, semanticRevision: UInt64,
                 descriptor: RPGSemanticDescriptor, input: RPGSemanticInputSnapshot) {
        guard screenInstanceID > 0, semanticRevision > 0,
              descriptor.isFocusable, descriptor.enabled,
              let command = descriptor.actionCommand else { return nil }
        self.screenInstanceID = screenInstanceID
        self.id = descriptor.id
        self.semanticRevision = semanticRevision
        self.commandFingerprint = rpgSemanticCommandFingerprint(command)
        self.semanticInputFingerprint = rpgSemanticInputFingerprint(input)
    }
}

public struct RPGSemanticInputSnapshot: Equatable {
    public let localPreferenceScope: RPGLocalPreferenceScope?
    public let localPreferenceRevision: UInt64
    public let localPreferenceWritable: Bool
    public let worldEntryGeneration: UInt64
    public let rulesGeneration: UInt64
    public let ownerRevision: UInt64
    public let inventoryDigest: String
    public let equipmentFocusDigest: String
    public let authorityRevision: UInt64
    public let authorityPhase: RPGAuthorityPresentationPhase
    public let authorityRequestIdentity: String?
    public let operationExpectedState: String

    public init?(localPreferenceScope: RPGLocalPreferenceScope?, localPreferenceRevision: UInt64,
                 localPreferenceWritable: Bool, worldEntryGeneration: UInt64 = 0,
                 rulesGeneration: UInt64, ownerRevision: UInt64,
                 inventoryDigest: String, equipmentFocusDigest: String, authorityRevision: UInt64,
                 authorityPhase: RPGAuthorityPresentationPhase, authorityRequestIdentity: String?,
                 operationExpectedState: String) {
        guard operationExpectedState.utf8.count <= 512, !operationExpectedState.isEmpty,
              isLowercaseHexDigest(inventoryDigest),
              isLowercaseHexDigest(equipmentFocusDigest) else { return nil }
        let needsIdentity = authorityPhase != .localReady && authorityPhase != .unavailable
        guard needsIdentity == (authorityRequestIdentity != nil),
              authorityRequestIdentity.map(isLowercaseHexDigest) ?? true else { return nil }
        self.localPreferenceScope = localPreferenceScope
        self.localPreferenceRevision = localPreferenceRevision
        self.localPreferenceWritable = localPreferenceWritable
        self.worldEntryGeneration = worldEntryGeneration
        self.rulesGeneration = rulesGeneration
        self.ownerRevision = ownerRevision
        self.inventoryDigest = inventoryDigest
        self.equipmentFocusDigest = equipmentFocusDigest
        self.authorityRevision = authorityRevision
        self.authorityPhase = authorityPhase
        self.authorityRequestIdentity = authorityRequestIdentity
        self.operationExpectedState = operationExpectedState
    }
}

private struct RPGSemanticDigestEncoder {
    var data = Data()

    mutating func append(_ value: String) {
        let bytes = Array(value.utf8)
        append(UInt64(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
    mutating func append(_ value: Data) {
        append(UInt64(value.count))
        data.append(value)
    }

    mutating func append(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func appendOptional(_ value: String?) {
        data.append(value == nil ? 0 : 1)
        if let value { append(value) }
    }
}

private func rpgHexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func canonicalSemanticCommand(_ command: RPGSemanticCommand) -> [String] {
    switch command {
    case .moveFocus(let direction): return ["moveFocus", direction.rawValue]
    case .focusNext: return ["focusNext"]
    case .focusPrevious: return ["focusPrevious"]
    case .activate: return ["activate"]
    case .back: return ["back"]
    case .previousTab: return ["previousTab"]
    case .nextTab: return ["nextTab"]
    case .scrollRows(let rows): return ["scrollRows", String(rows)]
    case .openCharacter: return ["openCharacter"]
    case .cyclePreparedAction: return ["cyclePreparedAction"]
    case .useSelectedAction: return ["useSelectedAction"]
    case .useQuickSlot(let slot): return ["useQuickSlot", String(slot)]
    case .choosePath(let id): return ["choosePath", id]
    case .chooseBranch(let id): return ["chooseBranch", id]
    case .creationBack: return ["creationBack"]
    case .creationNext: return ["creationNext"]
    case .resetAttributes: return ["resetAttributes"]
    case .adjustAttribute(let attribute, let delta):
        return ["adjustAttribute", attribute.rawValue, String(delta)]
    case .selectTab(let tab): return ["selectTab", tab.rawValue]
    case .selectElement(let id): return ["selectElement", id.rawValue]
    case .create(let draft):
        var components = ["create", draft.pathID, draft.starterSkillID ?? "",
                          String(draft.attributes.strength), String(draft.attributes.dexterity),
                          String(draft.attributes.endurance), String(draft.attributes.intelligence),
                          String(draft.attributes.luck), "starterSpellCount",
                          String(draft.starterSpellIDs.count)]
        for spellID in draft.starterSpellIDs {
            components.append("starterSpell")
            components.append(spellID)
        }
        return components
    case .rankUp(let skillID): return ["rankUp", skillID]
    case .spendAttribute(let attribute): return ["spendAttribute", attribute.rawValue]
    case .prepareSkill(let id): return ["prepareSkill", id]
    case .unprepareSkill(let id): return ["unprepareSkill", id]
    case .prepareSpell(let id): return ["prepareSpell", id]
    case .unprepareSpell(let id): return ["unprepareSpell", id]
    case .selectSkill(let id): return ["selectSkill", id]
    case .selectSpell(let id): return ["selectSpell", id]
    case .assignSlot(let token, let slot): return ["assignSlot", token, String(slot)]
    case .moveSlot(let from, let to): return ["moveSlot", String(from), String(to)]
    case .clearSlot(let slot): return ["clearSlot", String(slot)]
    case .tutorialBack: return ["tutorialBack"]
    case .tutorialNext: return ["tutorialNext"]
    case .tutorialFinish: return ["tutorialFinish"]
    case .tutorialSkip: return ["tutorialSkip"]
    }
}

public func rpgSemanticCommandFingerprint(_ command: RPGSemanticCommand) -> String {
    var encoder = RPGSemanticDigestEncoder()
    encoder.append("Pebble/RPGSemanticCommand/v1")
    for component in canonicalSemanticCommand(command) { encoder.append(component) }
    return rpgHexDigest(encoder.data)
}

public func rpgSemanticInputFingerprint(_ snapshot: RPGSemanticInputSnapshot) -> String {
    var encoder = RPGSemanticDigestEncoder()
    encoder.append("Pebble/RPGSemanticInput/v1")
    switch snapshot.localPreferenceScope {
    case nil:
        encoder.append("none")
    case .localWorld(let id):
        encoder.append("localWorld")
        encoder.append(id)
    case .lanV6(let host, let world):
        encoder.append("lanV6")
        encoder.append(Data(host.bytes).base64EncodedString())
        encoder.append(Data(world.bytes).base64EncodedString())
    }
    encoder.append(snapshot.localPreferenceRevision)
    encoder.append(snapshot.localPreferenceWritable)
    encoder.append(snapshot.worldEntryGeneration)
    encoder.append(snapshot.rulesGeneration)
    encoder.append(snapshot.ownerRevision)
    encoder.append(snapshot.inventoryDigest)
    encoder.append(snapshot.equipmentFocusDigest)
    encoder.append(snapshot.authorityRevision)
    encoder.append(snapshot.authorityPhase.rawValue)
    encoder.appendOptional(snapshot.authorityRequestIdentity)
    encoder.append(snapshot.operationExpectedState)
    return rpgHexDigest(encoder.data)
}

/// Binds a semantic operation to the complete authoritative RPG state that was used to build its
/// committed model. The UI never parses this digest; it is an opaque ABA/staleness component.
public func rpgSemanticOperationExpectedState(_ command: RPGSemanticCommand,
                                               state: RPGCharacterState,
                                               settingsRevision: UInt64? = nil,
                                               tutorialVersion: Int? = nil) -> String? {
    var encoder = RPGSemanticDigestEncoder()
    encoder.append("Pebble/RPGSemanticOperationExpectedState/v1")
    for component in canonicalSemanticCommand(command) { encoder.append(component) }
    let json = JSONEncoder()
    json.outputFormatting = [.sortedKeys]
    guard let encoded = try? json.encode(state), encoded.count <= 1_048_576 else { return nil }
    encoder.append(encoded)
    if let settingsRevision {
        encoder.append("settingsRevision")
        encoder.append(settingsRevision)
    }
    if let tutorialVersion {
        encoder.append("tutorialVersion")
        encoder.append(UInt64(max(0, tutorialVersion)))
    }
    return rpgHexDigest(encoder.data)
}

private func rpgSemanticEncodedDigest<T: Encodable>(_ value: T, domain: String) -> String? {
    let json = JSONEncoder()
    json.outputFormatting = [.sortedKeys]
    guard let encoded = try? json.encode(value), encoded.count <= 1_048_576 else { return nil }
    var encoder = RPGSemanticDigestEncoder()
    encoder.append(domain)
    encoder.append(encoded)
    return rpgHexDigest(encoder.data)
}

/// Full collision-resistant digest for the exact inventory input to a semantic activation.
public func rpgSemanticInventoryDigest<T: Encodable>(_ value: T) -> String? {
    rpgSemanticEncodedDigest(value, domain: "Pebble/RPGSemanticInventory/v1")
}

/// Full collision-resistant digest for selected-slot, focus, offhand, and armor inputs.
public func rpgSemanticEquipmentFocusDigest<T: Encodable>(_ value: T) -> String? {
    rpgSemanticEncodedDigest(value, domain: "Pebble/RPGSemanticEquipmentFocus/v1")
}

private func rpgSemanticActivationCapture(activationReceipt: UInt64,
                                          screenInstanceID: UInt64, semanticRevision: UInt64,
                                          descriptor: RPGSemanticDescriptor,
                                          input: RPGSemanticInputSnapshot) -> RPGSemanticActivationCapture? {
    guard descriptor.isFocusable, descriptor.enabled, let command = descriptor.actionCommand else { return nil }
    return RPGSemanticActivationCapture(
        activationReceipt: activationReceipt,
        screenInstanceID: screenInstanceID,
        id: descriptor.id,
        semanticRevision: semanticRevision,
        commandFingerprint: rpgSemanticCommandFingerprint(command),
        semanticInputFingerprint: rpgSemanticInputFingerprint(input)
    )
}

public func rpgSemanticActivationOriginMatches(
    _ origin: RPGSemanticActivationOrigin,
    screenInstanceID: UInt64,
    semanticRevision: UInt64,
    descriptor: RPGSemanticDescriptor?,
    input: RPGSemanticInputSnapshot?
) -> Bool {
    guard origin.screenInstanceID == screenInstanceID,
          origin.semanticRevision == semanticRevision,
          let descriptor, descriptor.id == origin.id,
          let input,
          let current = RPGSemanticActivationOrigin(
            screenInstanceID: screenInstanceID, semanticRevision: semanticRevision,
            descriptor: descriptor, input: input) else { return false }
    return current == origin
}

public func rpgRevalidateSemanticActivation(_ capture: RPGSemanticActivationCapture,
                                            screenInstanceID: UInt64,
                                            semanticRevision: UInt64,
                                            descriptor: RPGSemanticDescriptor?,
                                            input: RPGSemanticInputSnapshot) -> Bool {
    guard capture.screenInstanceID == screenInstanceID,
          capture.semanticRevision == semanticRevision,
          let descriptor, descriptor.id == capture.id,
          descriptor.isFocusable, descriptor.enabled,
          let command = descriptor.actionCommand else { return false }
    return capture.commandFingerprint == rpgSemanticCommandFingerprint(command) &&
        capture.semanticInputFingerprint == rpgSemanticInputFingerprint(input)
}

@MainActor
public final class RPGSemanticActivationBoundary {
    private var lastIssuedActivationReceipt: UInt64 = 0
    private var activationReceiptExhausted = false
    private var dispatchSerial: UInt64 = 0
    public private(set) var highestConsumedActivationReceipt: UInt64 = 0
    public private(set) var recentConsumedActivationReceipts: [UInt64] = []
    private var recentConsumedActivationReceiptSet: Set<UInt64> = []

    public init() {}

    init(testLastIssuedActivationReceipt: UInt64 = 0,
         testActivationReceiptExhausted: Bool = false,
         testDispatchSerial: UInt64 = 0) {
        lastIssuedActivationReceipt = testLastIssuedActivationReceipt
        activationReceiptExhausted = testActivationReceiptExhausted
        dispatchSerial = testDispatchSerial
    }

    var issuedReceiptHighWaterForTesting: UInt64 { lastIssuedActivationReceipt }
    var receiptExhaustedForTesting: Bool { activationReceiptExhausted }

    public func capture(screenInstanceID: UInt64, semanticRevision: UInt64,
                        descriptor: RPGSemanticDescriptor,
                        input: RPGSemanticInputSnapshot) -> RPGSemanticActivationCapture? {
        guard let origin = RPGSemanticActivationOrigin(
            screenInstanceID: screenInstanceID, semanticRevision: semanticRevision,
            descriptor: descriptor, input: input) else { return nil }
        return capture(origin: origin)
    }

    public func capture(origin: RPGSemanticActivationOrigin) -> RPGSemanticActivationCapture? {
        guard !activationReceiptExhausted else { return nil }
        let addition = lastIssuedActivationReceipt.addingReportingOverflow(1)
        guard !addition.overflow, addition.partialValue != 0 else {
            activationReceiptExhausted = true
            return nil
        }
        guard let capture = RPGSemanticActivationCapture(
            activationReceipt: addition.partialValue,
            screenInstanceID: origin.screenInstanceID, id: origin.id,
            semanticRevision: origin.semanticRevision,
            commandFingerprint: origin.commandFingerprint,
            semanticInputFingerprint: origin.semanticInputFingerprint) else { return nil }
        lastIssuedActivationReceipt = addition.partialValue
        return capture
    }

    public func dispatch(_ capture: RPGSemanticActivationCapture,
                         source _: RPGSemanticActivationSource,
                         screenInstanceID: UInt64,
                         semanticRevision: UInt64,
                         descriptor: RPGSemanticDescriptor?,
                         input: RPGSemanticInputSnapshot) -> RPGSemanticActivationResult {
        guard consume(capture.activationReceipt) else { return .invalidOrReplayedReceipt }
        guard rpgRevalidateSemanticActivation(capture, screenInstanceID: screenInstanceID,
                                              semanticRevision: semanticRevision,
                                              descriptor: descriptor, input: input),
              let command = descriptor?.actionCommand else {
            return .staleRequiresFreshActivation
        }
        if command.requiresAuthority, input.authorityPhase != .localReady { return .unavailable }
        if command.disallowedWhenAuthorityExhausted,
           input.authorityPhase == .authorityExhausted { return .unavailable }
        if command.requiresWritableQuickSlotScope,
           (input.localPreferenceScope == nil || !input.localPreferenceWritable) { return .unavailable }
        guard dispatchSerial < UInt64.max else { return .dispatchSerialExhausted }
        dispatchSerial += 1
        return .dispatched(serial: dispatchSerial)
    }

    /// Consumes an issued activation when its input owner is covered, closed, or cancelled.
    /// Cancellation never allocates a routing serial and the capture can never dispatch later.
    public func cancel(_ capture: RPGSemanticActivationCapture) -> Bool {
        consume(capture.activationReceipt)
    }

    private func consume(_ receipt: UInt64) -> Bool {
        guard receipt > 0, receipt <= lastIssuedActivationReceipt,
              receipt > highestConsumedActivationReceipt,
              !recentConsumedActivationReceiptSet.contains(receipt) else { return false }
        highestConsumedActivationReceipt = receipt
        recentConsumedActivationReceipts.append(receipt)
        recentConsumedActivationReceiptSet.insert(receipt)
        if recentConsumedActivationReceipts.count > 64 {
            let evicted = recentConsumedActivationReceipts.removeFirst()
            recentConsumedActivationReceiptSet.remove(evicted)
        }
        return true
    }
}

extension RPGSemanticCommand {
    var requiresAuthority: Bool {
        switch self {
        case .create, .rankUp, .spendAttribute, .prepareSkill, .unprepareSkill,
             .prepareSpell, .unprepareSpell, .selectSkill, .selectSpell,
             .cyclePreparedAction, .useSelectedAction, .useQuickSlot:
            return true
        default:
            return false
        }
    }

    var requiresWritableQuickSlotScope: Bool {
        switch self {
        case .assignSlot, .moveSlot, .clearSlot: return true
        default: return false
        }
    }

    var disallowedWhenAuthorityExhausted: Bool {
        if case .assignSlot = self { return true }
        return false
    }
}

public struct RPGSkillRankProjection: Equatable {
    public let id: RPGUIElementID
    public let skillID: String
    public let rank: Int
    public let purchased: Bool
    public let current: Bool
    public let nextEvaluation: RPGSkillPurchaseEvaluation?
}

public struct RPGPathProjection: Equatable {
    public let pathID: String
    public let branchIDs: [String]
    public let skillIDs: [String]
    public let ranks: [RPGSkillRankProjection]
    public let activeSkillIDs: [String]
    public let reachableSpellIDs: [String]
}

public struct RPGSpellUnlockProjection: Equatable {
    public let spellID: String
    public let unlockingSkillRanks: [String]
}

public struct RPGProgressionLevelProjection: Equatable {
    public let level: Int
    public let absoluteXPThreshold: Int
    public let earnedSkillPoints: Int
    public let earnedAttributePoints: Int
    public let roadmapMilestones: [RPGSpecializationMilestone]
    public let completedMilestones: [RPGSpecializationMilestone]
}

public struct RPGCharacterSummaryProjection: Equatable {
    public let path: String
    public let specialization: String
    public let level: Int
    public let absoluteXP: Int
    public let nextLevelXPThreshold: Int?
    public let fatigue: Double
    public let attributes: [(RPGAttributeID, Int)]
    public let derivedStats: RPGDerivedStats
    public let availableSkillPoints: Int
    public let availableAttributePoints: Int
    public let equipmentSummary: String
    public let focusSummary: String
    public let nextActionableMilestone: String
    public let levelOneGuidance: String?

    public static func == (lhs: RPGCharacterSummaryProjection,
                           rhs: RPGCharacterSummaryProjection) -> Bool {
        lhs.path == rhs.path && lhs.specialization == rhs.specialization && lhs.level == rhs.level &&
            lhs.absoluteXP == rhs.absoluteXP && lhs.nextLevelXPThreshold == rhs.nextLevelXPThreshold &&
            lhs.fatigue == rhs.fatigue && lhs.attributes.map { "\($0.0.rawValue):\($0.1)" } ==
            rhs.attributes.map { "\($0.0.rawValue):\($0.1)" } && lhs.derivedStats == rhs.derivedStats &&
            lhs.availableSkillPoints == rhs.availableSkillPoints &&
            lhs.availableAttributePoints == rhs.availableAttributePoints &&
            lhs.equipmentSummary == rhs.equipmentSummary && lhs.focusSummary == rhs.focusSummary &&
            lhs.nextActionableMilestone == rhs.nextActionableMilestone &&
            lhs.levelOneGuidance == rhs.levelOneGuidance
    }
}

public struct RPGProgressionSummaryProjection: Equatable {
    public let plan: RPGProgressionPlanProjection
    public let levels: [RPGProgressionLevelProjection]
    public let bankedSkillPoints: Int
    public let bankedAttributePoints: Int
    public let nextLegalPurchase: String?
    public let specializationRemainingCost: Int
    public let specializationCanComplete: Bool
    public let divergenceWarning: String?
}

public struct RPGProgressionPlanProjection: Equatable {
    public let selectedBranchDisplayName: String
    public let routeMilestones: [RPGSpecializationMilestone]
    public let completionCost: Int
    public let levelCapEarnedSkillPoints: Int
    public let utilityAllowance: Int
    public let completionImpactText: String
    public let crossBranchCapstoneText: String
}

public struct RPGCreationReviewItemProjection: Equatable {
    public let displayName: String
    public let count: Int
    public let displayNameDetail: String?
}

public struct RPGCreationReviewChordProjection: Equatable {
    public let actionDisplayName: String
    public let chord: String
}

public struct RPGCreationReviewProjection: Equatable {
    public let path: String
    public let branch: String
    public let attributes: [(RPGAttributeID, Int)]
    public let starterSkill: String
    public let starterKit: [String]
    public let starterKitItems: [RPGCreationReviewItemProjection]
    public let automaticSpells: [String]
    public let focusRequirement: String
    public let levelOneGuidance: String
    public let configuredChords: [String]
    public let configuredChordProjections: [RPGCreationReviewChordProjection]
    public let controllerScope: String
    public let inventoryCapacityCaveat: String
    public let authorityCaveat: String

    public static func == (lhs: RPGCreationReviewProjection,
                           rhs: RPGCreationReviewProjection) -> Bool {
        lhs.path == rhs.path && lhs.branch == rhs.branch &&
            lhs.attributes.map { "\($0.0.rawValue):\($0.1)" } ==
            rhs.attributes.map { "\($0.0.rawValue):\($0.1)" } &&
            lhs.starterSkill == rhs.starterSkill && lhs.starterKit == rhs.starterKit &&
            lhs.starterKitItems == rhs.starterKitItems &&
            lhs.automaticSpells == rhs.automaticSpells && lhs.focusRequirement == rhs.focusRequirement &&
            lhs.levelOneGuidance == rhs.levelOneGuidance && lhs.configuredChords == rhs.configuredChords &&
            lhs.configuredChordProjections == rhs.configuredChordProjections &&
            lhs.controllerScope == rhs.controllerScope &&
            lhs.inventoryCapacityCaveat == rhs.inventoryCapacityCaveat &&
            lhs.authorityCaveat == rhs.authorityCaveat
    }
}

public func rpgCharacterSummaryProjection(_ state: RPGCharacterState,
                                          equipmentSummary: String,
                                          focusSummary: String) -> RPGCharacterSummaryProjection? {
    guard state.created, let path = rpgPathDefinition(state.pathID),
          let branch = rpgBranchDefinition(state.specializationBranchID) else { return nil }
    let roadmap = rpgSpecializationRoadmap(branchID: state.specializationBranchID, in: state)?.milestones ?? []
    let nextMilestone = roadmap.first { (state.skillRanks[$0.skillID] ?? 0) < $0.rank }
    let nextText = nextMilestone.map {
        "Level \($0.level): \(rpgSkillDefinition($0.skillID)?.displayName ?? "Unavailable skill") rank \($0.rank)"
    } ?? "Selected specialization complete"
    return RPGCharacterSummaryProjection(path: path.displayName, specialization: branch.displayName,
        level: state.level, absoluteXP: state.xp,
        nextLevelXPThreshold: state.level < RPG_LEVEL_CAP ? rpgXPRequiredForLevel(state.level + 1) : nil,
        fatigue: state.fatigue,
        attributes: RPG_ATTRIBUTE_DISPLAY_ORDER.map { ($0, state.attributes.value($0)) },
        derivedStats: rpgDerivedStats(state), availableSkillPoints: rpgAvailableSkillPoints(state),
        availableAttributePoints: rpgAvailableAttributePoints(state),
        equipmentSummary: rpgSanitizeStatusText(equipmentSummary, byteLimit: 160),
        focusSummary: rpgSanitizeStatusText(focusSummary, byteLimit: 160),
        nextActionableMilestone: nextText,
        levelOneGuidance: state.level == 1 ? rpgLevelOneProgressionGuidance(pathID: state.pathID)?.visibleText : nil)
}

public func rpgProgressionSummaryProjection(_ state: RPGCharacterState) -> RPGProgressionSummaryProjection {
    let levels = rpgProgressionProjection(state)
    let roadmap = levels.flatMap(\.roadmapMilestones)
    let remaining = roadmap.filter { (state.skillRanks[$0.skillID] ?? 0) < $0.rank }
        .reduce(0) { partial, milestone in
            let sum = partial.addingReportingOverflow(milestone.cost)
            return sum.overflow ? Int.max : sum.partialValue
        }
    let stillEarnable = max(0, rpgEarnedSkillPoints(level: RPG_LEVEL_CAP) - rpgSpentSkillPoints(state))
    let canComplete = remaining <= stillEarnable
    let nextLegal = RPG_SKILL_DEFINITIONS.first { definition in
        definition.pathID == state.pathID && rpgEvaluateSkillPurchase(definition.id, in: state).permitted
    }.map { definition in
        let evaluation = rpgEvaluateSkillPurchase(definition.id, in: state)
        return "\(definition.displayName) rank \(evaluation.targetRank)"
    }
    let completionCost = roadmap.reduce(0) { partial, milestone in
        let cost = rpgSkillPointCost(milestone.skillID,
                                     targetRank: milestone.rank, in: state) ?? Int.max
        let result = partial.addingReportingOverflow(cost)
        return result.overflow ? Int.max : result.partialValue
    }
    let earnedAtCap = rpgEarnedSkillPoints(level: RPG_LEVEL_CAP)
    let utilityAllowance = max(0, earnedAtCap - completionCost)
    let branchName = rpgBranchDefinition(state.specializationBranchID)?.displayName ??
        "Unavailable specialization"
    let impact = canComplete
        ? "Current purchases leave \(remaining) SP of selected-branch milestones; completion remains possible by level 20."
        : "Current purchases leave \(remaining) SP of selected-branch milestones; completion is no longer possible by level 20."
    let plan = RPGProgressionPlanProjection(
        selectedBranchDisplayName: branchName, routeMilestones: roadmap,
        completionCost: completionCost, levelCapEarnedSkillPoints: earnedAtCap,
        utilityAllowance: utilityAllowance, completionImpactText: impact,
        crossBranchCapstoneText:
            "Cross-branch Mastery III requires level 22; the level cap is 20, so it is unreachable.")
    return RPGProgressionSummaryProjection(plan: plan, levels: levels,
        bankedSkillPoints: rpgAvailableSkillPoints(state),
        bankedAttributePoints: rpgAvailableAttributePoints(state), nextLegalPurchase: nextLegal,
        specializationRemainingCost: remaining, specializationCanComplete: canComplete,
        divergenceWarning: canComplete ? nil : "Current purchases prevent completing the selected specialization by level 20.")
}

public func rpgCreationReviewProjection(session: RPGCreationSession,
                                        chordBindings: [String: String],
                                        authority: RPGAuthorityPresentation,
                                        inventoryCapacitySummary: String) -> RPGCreationReviewProjection? {
    guard let selected = session.selectedDraft,
          case .success(let draft) = rpgCreationDraft(from: session),
          let path = rpgPathDefinition(draft.pathID),
          let branch = rpgBranchDefinition(selected.branchID),
          let starterID = draft.starterSkillID,
          let starter = rpgSkillDefinition(starterID),
          let kit = rpgStarterKit(pathID: draft.pathID) else { return nil }
    let spells = starter.spellUnlocks.filter { $0.rank == 1 }.compactMap {
        rpgSpellDefinition($0.spellID)?.displayName
    }
    let chordIDs = ["rpgCharacter", "rpgCycleAction", "rpgUseAction"] +
        (1...9).map { "rpgQuickSlot\($0)" }
    let sanitizedBindings = rpgSanitizedChordBindings(chordBindings)
    func chordDisplayName(_ id: String) -> String? {
        switch id {
        case "rpgCharacter": return "Character"
        case "rpgCycleAction": return "Cycle Prepared Action"
        case "rpgUseAction": return "Use Selected Action"
        default:
            guard id.hasPrefix("rpgQuickSlot"),
                  let slot = Int(id.dropFirst("rpgQuickSlot".count)),
                  (1...9).contains(slot) else { return nil }
            return "Quick Slot \(slot)"
        }
    }
    let chordProjections = chordIDs.compactMap { id -> RPGCreationReviewChordProjection? in
        guard let display = chordDisplayName(id), let chord = sanitizedBindings[id] else { return nil }
        return RPGCreationReviewChordProjection(actionDisplayName: display, chord: chord)
    }
    guard chordProjections.count == chordIDs.count else { return nil }
    let chordLines = chordProjections.map { "\($0.actionDisplayName): \($0.chord)" }
    let kitItems = kit.compactMap { entry -> RPGCreationReviewItemProjection? in
        guard let display = rpgStarterKitItemRegistrationDisplayName(entry.itemID),
              !display.isEmpty else { return nil }
        let potionDisplay: String?
        if let potionID = entry.potionID {
            guard let potion = POTIONS.first(where: { $0.id == potionID }),
                  !potion.displayName.isEmpty else { return nil }
            potionDisplay = potion.displayName
        } else {
            potionDisplay = nil
        }
        return RPGCreationReviewItemProjection(displayName: display,
            count: entry.count, displayNameDetail: potionDisplay)
    }
    guard kitItems.count == kit.count else { return nil }
    let kitLines = kitItems.map {
        "\($0.displayName) x\($0.count)" +
            ($0.displayNameDetail.map { " (\($0))" } ?? "")
    }
    return RPGCreationReviewProjection(path: path.displayName, branch: branch.displayName,
        attributes: RPG_ATTRIBUTE_DISPLAY_ORDER.map { ($0, draft.attributes.value($0)) },
        starterSkill: starter.displayName, starterKit: kitLines,
        starterKitItems: kitItems, automaticSpells: spells,
        focusRequirement: spells.isEmpty ? "No starter spell focus requirement." :
            "Starter spells require an Apprentice Focus in either hand.",
        levelOneGuidance: rpgLevelOneProgressionGuidance(pathID: draft.pathID)?.visibleText ?? "",
        configuredChords: chordLines,
        configuredChordProjections: chordProjections,
        controllerScope: "Controller support covers RPG menus and actions only.",
        inventoryCapacityCaveat: rpgSanitizeStatusText(inventoryCapacitySummary, byteLimit: 160),
        authorityCaveat: {
            switch authority.phase {
            case .localReady:
                return "Create saves this character and starter kit to this world."
            case .unavailable:
                return "This LAN host does not support character creation. Your draft will not be submitted."
            default:
                return rpgAuthorityPhasePresentation(authority.phase).visibleHelp
            }
        }())
}

public func rpgSpellUnlockProjections(pathID: String) -> [RPGSpellUnlockProjection] {
    guard let path = rpgPathDefinition(pathID) else { return [] }
    let skills = path.branchIDs.flatMap { rpgBranchDefinition($0)?.skillIDs ?? [] }
    return RPG_SPELL_DEFINITIONS.compactMap { spell in
        let unlockers = skills.compactMap { skillID -> String? in
            guard let unlock = rpgSkillDefinition(skillID)?.spellUnlocks.first(where: {
                $0.spellID == spell.id
            }) else { return nil }
            return "\(skillID):rank:\(unlock.rank)"
        }
        return unlockers.isEmpty ? nil : RPGSpellUnlockProjection(spellID: spell.id,
                                                                   unlockingSkillRanks: unlockers)
    }
}

public func rpgProgressionProjection(_ state: RPGCharacterState) -> [RPGProgressionLevelProjection] {
    let roadmap = rpgSpecializationRoadmap(branchID: state.specializationBranchID, in: state)?.milestones ?? []
    return (1...RPG_LEVEL_CAP).map { level in
        let levelMilestones = roadmap.filter { $0.level == level }
        return RPGProgressionLevelProjection(
            level: level,
            absoluteXPThreshold: rpgXPRequiredForLevel(level),
            earnedSkillPoints: rpgEarnedSkillPoints(level: level),
            earnedAttributePoints: rpgEarnedAttributePoints(level: level),
            roadmapMilestones: levelMilestones,
            completedMilestones: levelMilestones.filter { (state.skillRanks[$0.skillID] ?? 0) >= $0.rank }
        )
    }
}

public func rpgPathProjection(pathID: String, state: RPGCharacterState) -> RPGPathProjection? {
    guard let path = rpgPathDefinition(pathID), path.branchIDs.count == 3 else { return nil }
    let skillIDs = path.branchIDs.flatMap { rpgBranchDefinition($0)?.skillIDs ?? [] }
    guard skillIDs.count == 9 else { return nil }
    let ranks = skillIDs.flatMap { skillID -> [RPGSkillRankProjection] in
        let current = max(0, min(3, state.skillRanks[skillID] ?? 0))
        return (1...3).map { rank in
            return RPGSkillRankProjection(
                id: .rank(skillID: skillID, rank: rank), skillID: skillID,
                rank: rank, purchased: rank <= current, current: rank == current,
                nextEvaluation: rank == current + 1 ? rpgEvaluateSkillPurchase(skillID, in: state) : nil)
        }
    }
    let active = RPG_SKILL_DEFINITIONS.filter { $0.pathID == pathID && $0.kind == .active }.map(\.id)
    let reachable = RPG_SPELL_DEFINITIONS.filter { spell in
        skillIDs.contains { rpgSkillDefinition($0)?.spellUnlocks.contains(where: { $0.spellID == spell.id }) == true }
    }.map(\.id)
    return RPGPathProjection(pathID: pathID, branchIDs: path.branchIDs, skillIDs: skillIDs,
                             ranks: ranks, activeSkillIDs: active, reachableSpellIDs: reachable)
}

public let RPG_TUTORIAL_VERSION = 1

public struct RPGTutorialState: Equatable {
    public var seenVersion: Int
    public var page: Int?
    public init(seenVersion: Int = 0, page: Int? = nil) {
        self.seenVersion = max(0, min(RPG_TUTORIAL_VERSION, seenVersion))
        self.page = page.map { max(1, min(4, $0)) }
    }
}

public let RPG_TUTORIAL_PAGES: [String] = [
    "Rank Foundation, Technique, and Mastery skills in your branch.",
    "Prepare actions, then explicitly select the action you want to use.",
    "Choose a prepared action and assign it to a local quick slot.",
    "Close the sheet and use your configured keyboard or RPG controller chords.",
]

public func rpgTutorialAfter(_ command: RPGSheetLocalOperation,
                             state: RPGTutorialState) -> RPGTutorialState {
    var next = state
    switch command {
    case .tutorialBack:
        let current = min(4, max(1, next.page ?? 1))
        let value = current.subtractingReportingOverflow(1)
        next.page = value.overflow ? 1 : max(1, value.partialValue)
    case .tutorialNext:
        let current = min(4, max(1, next.page ?? 1))
        let value = current.addingReportingOverflow(1)
        next.page = value.overflow ? 4 : min(4, value.partialValue)
    case .tutorialFinish, .tutorialSkip: next.seenVersion = RPG_TUTORIAL_VERSION; next.page = nil
    default: break
    }
    return next
}

public struct RPGScreenModelInput: Equatable {
    public let state: RPGCharacterState
    public let quickSlots: RPGQuickSlotPreferences
    public let localPreferenceScope: RPGLocalPreferenceScope?
    public let localPreferenceRevision: UInt64
    public let localPreferenceWritable: Bool
    public let localPreferenceStatus: RPGStatusPresentation?
    public var localPreferencePersistenceFailed: Bool {
        localPreferenceStatus?.kind == .persistenceFailure
    }
    public let worldEntryGeneration: UInt64
    public let authority: RPGAuthorityPresentation
    public let rulesGeneration: UInt64
    public let inventoryRevision: UInt64
    public let equipmentFocusRevision: UInt64
    public let equipmentSummary: String
    public let focusSummary: String
    public let configuredChords: [String: String]
    public let inventoryCapacitySummary: String
    public let inventoryCapacityAvailable: Bool
    public let creation: RPGCreationSession
    public let tutorial: RPGTutorialState
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let tab: RPGCharacterTab
    public let focusedID: RPGUIElementID?
    public let selection: RPGScreenSelection?
    public let scrollOffset: Double
    public let highContrast: Bool
    public let reduceMotion: Bool

    public init(state: RPGCharacterState, quickSlots: RPGQuickSlotPreferences = .empty,
                localPreferenceScope: RPGLocalPreferenceScope? = nil,
                localPreferenceRevision: UInt64 = 0, localPreferenceWritable: Bool = false,
                localPreferenceStatus: RPGStatusPresentation? = nil,
                worldEntryGeneration: UInt64 = 0,
                authority: RPGAuthorityPresentation = .localReady,
                rulesGeneration: UInt64 = 0, inventoryRevision: UInt64 = 0,
                equipmentFocusRevision: UInt64 = 0,
                equipmentSummary: String = "Equipment status unavailable.",
                focusSummary: String = "Focus status unavailable.",
                configuredChords: [String: String] = rpgDefaultChordBindings(),
                inventoryCapacitySummary: String = "The starter kit requires enough inventory capacity; creation fails atomically if it cannot fit.",
                inventoryCapacityAvailable: Bool = true,
                creation: RPGCreationSession = rpgInitialCreationSession(), tutorial: RPGTutorialState = RPGTutorialState(),
                viewportWidth: Double, viewportHeight: Double, tab: RPGCharacterTab = .character,
                focusedID: RPGUIElementID? = nil,
                selection: RPGScreenSelection? = nil, scrollOffset: Double = 0,
                highContrast: Bool = false, reduceMotion: Bool = false) {
        self.state = state; self.quickSlots = quickSlots
        self.localPreferenceScope = localPreferenceScope
        self.localPreferenceRevision = localPreferenceRevision
        self.localPreferenceWritable = localPreferenceWritable
        self.localPreferenceStatus = localPreferenceStatus
        self.worldEntryGeneration = worldEntryGeneration
        self.authority = authority
        self.rulesGeneration = rulesGeneration
        self.inventoryRevision = inventoryRevision
        self.equipmentFocusRevision = equipmentFocusRevision
        self.equipmentSummary = rpgSanitizeStatusText(equipmentSummary, byteLimit: 160)
        self.focusSummary = rpgSanitizeStatusText(focusSummary, byteLimit: 160)
        self.configuredChords = rpgSanitizedChordBindings(configuredChords)
        self.inventoryCapacitySummary = rpgSanitizeStatusText(inventoryCapacitySummary, byteLimit: 160)
        self.inventoryCapacityAvailable = inventoryCapacityAvailable
        self.creation = creation; self.tutorial = tutorial; self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight; self.tab = tab; self.focusedID = focusedID
        self.selection = selection
        self.scrollOffset = scrollOffset; self.highContrast = highContrast; self.reduceMotion = reduceMotion
    }

    public func withScrollOffset(_ offset: Double) -> RPGScreenModelInput {
        RPGScreenModelInput(
            state: state, quickSlots: quickSlots,
            localPreferenceScope: localPreferenceScope,
            localPreferenceRevision: localPreferenceRevision,
            localPreferenceWritable: localPreferenceWritable,
            localPreferenceStatus: localPreferenceStatus,
            worldEntryGeneration: worldEntryGeneration, authority: authority,
            rulesGeneration: rulesGeneration, inventoryRevision: inventoryRevision,
            equipmentFocusRevision: equipmentFocusRevision,
            equipmentSummary: equipmentSummary, focusSummary: focusSummary,
            configuredChords: configuredChords,
            inventoryCapacitySummary: inventoryCapacitySummary,
            inventoryCapacityAvailable: inventoryCapacityAvailable,
            creation: creation, tutorial: tutorial,
            viewportWidth: viewportWidth, viewportHeight: viewportHeight,
            tab: tab, focusedID: focusedID, selection: selection,
            scrollOffset: offset, highContrast: highContrast,
            reduceMotion: reduceMotion)
    }
}

/// Immutable, app-independent capture of every mutable GameCore value consumed by the screen model.
/// App code adds only viewport and presentation selection state after this capture returns.
public struct RPGScreenRuntimeSnapshot: Equatable {
    public let state: RPGCharacterState
    public let quickSlots: RPGQuickSlotPreferences
    public let localPreferenceScope: RPGLocalPreferenceScope?
    public let localPreferenceRevision: UInt64
    public let localPreferenceWritable: Bool
    public let localPreferenceStatus: RPGStatusPresentation?
    public var localPreferencePersistenceFailed: Bool {
        localPreferenceStatus?.kind == .persistenceFailure
    }
    public let worldEntryGeneration: UInt64
    public let authority: RPGAuthorityPresentation
    public let rulesGeneration: UInt64
    public let inventoryRevision: UInt64
    public let equipmentFocusRevision: UInt64
    public let inventoryDigest: String
    public let equipmentFocusDigest: String
    public let settingsRevision: UInt64
    public let equipmentSummary: String
    public let focusSummary: String
    public let configuredChords: [String: String]
    public let inventoryCapacitySummary: String
    public let inventoryCapacityByPath: [String: Bool]
    public let tutorial: RPGTutorialState
    public let highContrast: Bool
    public let reduceMotion: Bool

    public init(state: RPGCharacterState, quickSlots: RPGQuickSlotPreferences,
                localPreferenceScope: RPGLocalPreferenceScope?, localPreferenceRevision: UInt64,
                localPreferenceWritable: Bool, worldEntryGeneration: UInt64,
                localPreferenceStatus: RPGStatusPresentation?,
                authority: RPGAuthorityPresentation, rulesGeneration: UInt64,
                inventoryRevision: UInt64, equipmentFocusRevision: UInt64,
                inventoryDigest: String, equipmentFocusDigest: String, settingsRevision: UInt64,
                equipmentSummary: String, focusSummary: String,
                configuredChords: [String: String], inventoryCapacitySummary: String,
                inventoryCapacityByPath: [String: Bool],
                tutorial: RPGTutorialState, highContrast: Bool, reduceMotion: Bool) {
        self.state = state; self.quickSlots = quickSlots
        self.localPreferenceScope = localPreferenceScope
        self.localPreferenceRevision = localPreferenceRevision
        self.localPreferenceWritable = localPreferenceWritable
        self.localPreferenceStatus = localPreferenceStatus
        self.worldEntryGeneration = worldEntryGeneration
        self.authority = authority; self.rulesGeneration = rulesGeneration
        self.inventoryRevision = inventoryRevision
        self.equipmentFocusRevision = equipmentFocusRevision
        self.inventoryDigest = inventoryDigest
        self.equipmentFocusDigest = equipmentFocusDigest
        self.settingsRevision = settingsRevision
        self.equipmentSummary = rpgSanitizeStatusText(equipmentSummary, byteLimit: 160)
        self.focusSummary = rpgSanitizeStatusText(focusSummary, byteLimit: 160)
        self.configuredChords = rpgSanitizedChordBindings(configuredChords)
        self.inventoryCapacitySummary = rpgSanitizeStatusText(
            inventoryCapacitySummary, byteLimit: 160)
        self.inventoryCapacityByPath = Dictionary(uniqueKeysWithValues:
            RPG_PATH_DEFINITIONS.map { ($0.id, inventoryCapacityByPath[$0.id] == true) })
        self.tutorial = tutorial; self.highContrast = highContrast
        self.reduceMotion = reduceMotion
    }

    public func modelInput(viewportWidth: Double, viewportHeight: Double,
                           creation: RPGCreationSession = rpgInitialCreationSession(),
                           tab: RPGCharacterTab = .character,
                           focusedID: RPGUIElementID? = nil,
                           selection: RPGScreenSelection? = nil,
                           scrollOffset: Double = 0) -> RPGScreenModelInput {
        RPGScreenModelInput(
            state: state, quickSlots: quickSlots,
            localPreferenceScope: localPreferenceScope,
            localPreferenceRevision: localPreferenceRevision,
            localPreferenceWritable: localPreferenceWritable,
            localPreferenceStatus: localPreferenceStatus,
            worldEntryGeneration: worldEntryGeneration, authority: authority,
            rulesGeneration: rulesGeneration, inventoryRevision: inventoryRevision,
            equipmentFocusRevision: equipmentFocusRevision,
            equipmentSummary: equipmentSummary, focusSummary: focusSummary,
            configuredChords: configuredChords,
            inventoryCapacitySummary: inventoryCapacitySummary,
            inventoryCapacityAvailable: inventoryCapacityByPath[
                creation.selectedPathID] == true,
            creation: creation, tutorial: tutorial,
            viewportWidth: viewportWidth, viewportHeight: viewportHeight,
            tab: tab, focusedID: focusedID, selection: selection,
            scrollOffset: scrollOffset,
            highContrast: highContrast, reduceMotion: reduceMotion)
    }

    public func semanticInput(for command: RPGSemanticCommand) -> RPGSemanticInputSnapshot? {
        guard let expected = rpgSemanticOperationExpectedState(
            command, state: state, settingsRevision: settingsRevision,
            tutorialVersion: tutorial.seenVersion) else { return nil }
        return RPGSemanticInputSnapshot(
            localPreferenceScope: localPreferenceScope,
            localPreferenceRevision: localPreferenceRevision,
            localPreferenceWritable: localPreferenceWritable,
            worldEntryGeneration: worldEntryGeneration,
            rulesGeneration: rulesGeneration,
            ownerRevision: UInt64(max(0, state.authorityRevision)),
            inventoryDigest: inventoryDigest,
            equipmentFocusDigest: equipmentFocusDigest,
            authorityRevision: UInt64(max(0, state.authorityRevision)),
            authorityPhase: authority.phase,
            authorityRequestIdentity: authority.requestIdentity,
            operationExpectedState: expected)
    }
}

public struct RPGScreenModel: Equatable {
    public let layout: RPGScreenLayout
    public let panelFrame: RPGLogicalRect
    public let contentFrame: RPGLogicalRect
    public let headerText: String
    public let statusText: String
    public let footerText: String
    public let authority: RPGAuthorityPhasePresentation
    public let status: RPGStatusPresentation?
    public let descriptors: [RPGSemanticDescriptor]
    public let visibleDescriptors: [RPGSemanticDescriptor]
    public let projection: RPGPathProjection?
    public let characterSummary: RPGCharacterSummaryProjection?
    public let progressionSummary: RPGProgressionSummaryProjection?
    public let creationReview: RPGCreationReviewProjection?
    public let contentHeight: Double
    public let viewportHeight: Double
    public let scrollOffset: Double
    public let focusedID: RPGUIElementID?
    public let nextFocusableID: RPGUIElementID?
    public let errorText: String?
    public let contextualDetailLines: [String]
    public let stepOrTabText: String
}

public func rpgClampedScrollOffset(contentHeight: Double, viewportHeight: Double,
                                   requested: Double) -> Double {
    guard contentHeight.isFinite, viewportHeight.isFinite, requested.isFinite,
          contentHeight > 0, viewportHeight > 0 else { return 0 }
    return min(max(0, requested), max(0, contentHeight - viewportHeight))
}

public func rpgAnchoredScrollOffset(previousFocusedFrame: RPGLogicalRect?,
                                    newUnscrolledFocusedFrame: RPGLogicalRect?,
                                    currentOffset: Double, contentHeight: Double,
                                    viewportHeight: Double,
                                    viewportOriginY: Double = 0) -> Double {
    let ordinary = rpgClampedScrollOffset(contentHeight: contentHeight,
                                          viewportHeight: viewportHeight,
                                          requested: currentOffset)
    guard let previous = previousFocusedFrame, let next = newUnscrolledFocusedFrame,
          previous.isFinite, next.isFinite, previous.height > 0, next.height > 0,
          currentOffset.isFinite, viewportHeight.isFinite, viewportHeight > 0,
          viewportOriginY.isFinite else {
        return ordinary
    }
    var requested = next.y - previous.y
    guard requested.isFinite else { return ordinary }
    let projectedY = next.y - requested
    if projectedY < viewportOriginY {
        requested += projectedY - viewportOriginY
    } else if projectedY + next.height > viewportOriginY + viewportHeight {
        requested += projectedY + next.height - (viewportOriginY + viewportHeight)
    }
    return rpgClampedScrollOffset(contentHeight: contentHeight,
                                  viewportHeight: viewportHeight,
                                  requested: requested)
}

public func rpgScreenLayout(viewportWidth: Double, viewportHeight: Double,
                            hasStatus: Bool, contextualDetailText: String?) -> RPGScreenLayout? {
    guard viewportWidth.isFinite, viewportHeight.isFinite,
          viewportWidth >= 360, viewportHeight >= 224 else { return nil }
    let panelWidth = min(700, viewportWidth - 12)
    let panelHeight = min(420, viewportHeight - 12)
    let panel = RPGLogicalRect(x: (viewportWidth - panelWidth) / 2,
                               y: (viewportHeight - panelHeight) / 2,
                               width: panelWidth, height: panelHeight)
    let innerX = panel.x + 6
    let innerWidth = panel.width - 12
    let header = RPGLogicalRect(x: innerX, y: panel.y, width: innerWidth, height: 24)
    let authority = RPGLogicalRect(x: innerX, y: header.maxY, width: innerWidth, height: 18)
    var top = authority.maxY
    let status: RPGLogicalRect?
    if hasStatus {
        status = RPGLogicalRect(x: innerX, y: top, width: innerWidth, height: 18)
        top += 18
    } else {
        status = nil
    }
    let detail: RPGLogicalRect?
    if let text = contextualDetailText, !text.isEmpty {
        let lineCount = max(1, rpgWrappedPresentationLines(text, width: innerWidth - 8).count)
        let measured = max(18, Double(lineCount) * 12 + RPG_PRESENTATION_GLYPH_BOTTOM_PADDING)
        let chipHeights = 18.0 + (hasStatus ? 18.0 : 0.0)
        let cap = min(72, panel.height - 24 - chipHeights - 20 - 26 - 18 - 20)
        let height = max(0, min(measured, cap))
        detail = height >= 18
            ? RPGLogicalRect(x: innerX, y: top, width: innerWidth, height: height)
            : nil
        top += detail?.height ?? 0
    } else {
        detail = nil
    }
    let step = RPGLogicalRect(x: innerX, y: top, width: innerWidth, height: 20)
    let footer = RPGLogicalRect(x: innerX, y: panel.maxY - 18,
                                width: innerWidth, height: 18)
    let command = RPGLogicalRect(x: innerX, y: footer.y - 26,
                                 width: innerWidth, height: 26)
    let content = RPGLogicalRect(x: innerX, y: step.maxY,
                                 width: innerWidth,
                                 height: max(0, command.y - step.maxY))
    guard content.height >= 20 else { return nil }
    return RPGScreenLayout(panelFrame: panel, headerFrame: header,
                           authorityChipFrame: authority, statusChipFrame: status,
                           contextualDetailFrame: detail, stepOrTabFrame: step,
                           contentFrame: content, commandFrame: command,
                           footerHelpFrame: footer)
}

private func descriptor(id: RPGUIElementID, role: RPGSemanticRole, label: String,
                        value: String = "", help: String = "", selected: Bool = false,
                        prepared: Bool = false, slotted: Bool = false,
                        enabled: Bool = true, locked: Bool = false, frame: RPGLogicalRect,
                        visibleIn content: RPGLogicalRect, command: RPGSemanticCommand? = nil,
                        focusSelection: RPGScreenSelection? = nil,
                        layoutRegion: RPGSemanticLayoutRegion = .scrollingContent,
                        iconAssetID: String? = nil, visualLines: [String] = [],
                        adornment: RPGDescriptorAdornment = .none) -> RPGSemanticDescriptor {
    let resolvedLines: [String]
    if !visualLines.isEmpty {
        resolvedLines = visualLines
    } else {
        let textWidth = max(1, frame.width - 8 - (iconAssetID == nil ? 0 : 28))
        resolvedLines = rpgWrappedPresentationLines(label, width: textWidth) +
            (value.isEmpty ? [] : rpgWrappedPresentationLines(value, width: textWidth))
    }
    let presentationFits = rpgDescriptorVisualLinesFit(
        frame: frame, iconAssetID: iconAssetID, visualLines: resolvedLines)
    // An enabled command whose complete visible label cannot fit would create an activation
    // surface without a truthful visible description. Fail closed by retaining the semantic row
    // for inspection while removing its command and enabled hit capability.
    let resolvedCommand = presentationFits ? command : nil
    let resolvedEnabled = enabled && (command == nil || presentationFits)
    let resolvedLocked = locked || (command != nil && !presentationFits)
    return RPGSemanticDescriptor(id: id, role: role, groupID: nil, label: label, value: value, help: help,
        selected: selected, prepared: prepared, slotted: slotted,
        enabled: resolvedEnabled, locked: resolvedLocked,
        isFocusable: true, focusSelection: focusSelection,
        layoutRegion: layoutRegion, iconAssetID: iconAssetID,
        visualLines: resolvedLines, adornment: adornment,
        frame: frame, visibleFrame: content.contains(frame) ? frame : nil,
        actionCommand: resolvedCommand)
}

private func shiftedContentDescriptor(_ value: RPGSemanticDescriptor, deltaY: Double,
                                      content: RPGLogicalRect) -> RPGSemanticDescriptor {
    guard value.layoutRegion == .scrollingContent,
          value.frame.y < content.maxY + 10_000,
          value.frame.y >= content.y - 10_000 else { return value }
    let frame = RPGLogicalRect(x: value.frame.x, y: value.frame.y + deltaY,
                               width: value.frame.width, height: value.frame.height)
    return RPGSemanticDescriptor(id: value.id, role: value.role, groupID: value.groupID,
        label: value.label, value: value.value, help: value.help, selected: value.selected,
        prepared: value.prepared, slotted: value.slotted, enabled: value.enabled, locked: value.locked,
        isFocusable: value.isFocusable, focusSelection: value.focusSelection,
        layoutRegion: value.layoutRegion, iconAssetID: value.iconAssetID,
        visualLines: value.visualLines, adornment: value.adornment, frame: frame,
        visibleFrame: content.contains(frame) ? frame : nil, actionCommand: value.actionCommand)
}

public func rpgWrappedPresentationLines(_ text: String, width: Double) -> [String] {
    guard width.isFinite, width > 0 else { return text.isEmpty ? [] : [text] }
    let maxWidth = max(1, Int(width.rounded(.down)))
    return wrapTextByWidth(text, maxWidth: maxWidth) { value in
        Int((Double(value.utf8.count) * 6.5).rounded(.up))
    }
}

public func rpgSharedConservativeTextWidth(_ text: String) -> Double? {
    let width = Double(text.utf8.count) * 6.5
    return width.isFinite && width >= 0 ? width : nil
}

public struct RPGCharacterTabFrameProjection: Equatable {
    public let tab: RPGCharacterTab
    public let frame: RPGLogicalRect
    public let visualLines: [String]
}

/// Exact checked five-tab partition. Minimums preserve complete labels; only the unrounded
/// remainder is distributed, and the fifth frame absorbs floating residual to close the strip.
public func rpgCharacterTabFrames(in frame: RPGLogicalRect)
    -> [RPGCharacterTabFrameProjection]? {
    guard frame.isFinite, frame.width > 0, frame.height > 0,
          frame.maxX.isFinite, frame.maxY.isFinite else { return nil }
    let tabs = RPGCharacterTab.allCases
    guard tabs.count == 5 else { return nil }
    var minimums: [Double] = []
    var minimumSum = 0.0
    for tab in tabs {
        let label = tab.rawValue.capitalized
        guard let measured = rpgSharedConservativeTextWidth(label) else { return nil }
        let minimum = measured.rounded(.up) + 8
        let next = minimumSum + minimum
        guard minimum.isFinite, minimum > 0, next.isFinite, next >= minimumSum else { return nil }
        minimums.append(minimum)
        minimumSum = next
    }
    let remaining = frame.width - minimumSum
    guard remaining.isFinite, remaining >= 0 else { return nil }
    let share = remaining / Double(tabs.count)
    guard share.isFinite, share >= 0 else { return nil }
    var result: [RPGCharacterTabFrameProjection] = []
    var x = frame.x
    for index in tabs.indices {
        let width = index == tabs.index(before: tabs.endIndex)
            ? frame.maxX - x : minimums[index] + share
        guard x.isFinite, width.isFinite, width > 0,
              width >= minimums[index] else { return nil }
        let tabFrame = RPGLogicalRect(x: x, y: frame.y,
                                      width: width, height: frame.height)
        let lines = [tabs[index].rawValue.capitalized]
        guard tabFrame.maxX.isFinite, tabFrame.maxY.isFinite,
              frame.contains(tabFrame), rpgDescriptorVisualLinesFit(
            frame: tabFrame, iconAssetID: nil, visualLines: lines) else { return nil }
        result.append(RPGCharacterTabFrameProjection(
            tab: tabs[index], frame: tabFrame, visualLines: lines))
        x = tabFrame.maxX
        guard x.isFinite else { return nil }
    }
    guard result.count == tabs.count, result.first?.frame.x == frame.x,
          result.last?.frame.maxX == frame.maxX else { return nil }
    return result
}

public func rpgPreparedActionDisplayName(_ token: String?) -> String {
    guard let token else { return "Empty" }
    guard let action = rpgParsePreparedActionToken(token) else { return "Unavailable action" }
    switch action.kind {
    case .skill:
        return rpgSkillDefinition(action.id)?.displayName ?? "Unavailable action"
    case .spell:
        return rpgSpellDefinition(action.id)?.displayName ?? "Unavailable action"
    }
}

public func rpgWrappedControlLines(_ text: String, width: Double) -> [String] {
    rpgWrappedPresentationLines(text, width: max(1, width - 8))
}

public func rpgControlHeight(lines: [String]) -> Double {
    max(20, Double(max(1, lines.count)) * 9 + 8)
}

/// Shared production/harness contract for complete descriptor-line rendering. The production
/// renderer's four-point top inset is the stricter of the two renderers and therefore canonical.
public func rpgDescriptorVisualLinesFit(frame: RPGLogicalRect, iconAssetID: String?,
                                        visualLines: [String]) -> Bool {
    guard frame.isFinite, frame.width > 0, frame.height > 0 else { return false }
    guard !visualLines.isEmpty else { return true }
    let width = frame.width - 8 - (iconAssetID == nil ? 0 : 28)
    guard width > 0 else { return false }
    let lastBaseline = frame.y + 4 + Double(visualLines.count - 1) * 9
    guard lastBaseline + 8 <= frame.maxY else { return false }
    return visualLines.allSatisfy { line in
        Double(line.utf8.count) * 6.5 <= width
    }
}

private func rpgWrappedLineCount(_ text: String, width: Double) -> Int {
    max(1, min(8, rpgWrappedPresentationLines(text, width: width).count))
}

private func rpgWrappedCardLines(_ lines: [String], width: Double) -> [String] {
    lines.flatMap { rpgWrappedPresentationLines($0, width: width) }
}

private func rpgCardHeight(visualLines: [String], hasOperation: Bool) -> Double {
    let completeTextHeight = Double(max(1, visualLines.count)) * 9 + 3
    return max(28, completeTextHeight) + (hasOperation ? 24 : 0)
}

private func rpgAuthorityEnabled(_ authority: RPGAuthorityPresentation) -> Bool {
    authority.phase == .localReady
}

public let RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP =
    "Quick-slot editing requires writable local storage or a compatible host session."
public let RPG_PRESENTATION_GLYPH_BOTTOM_PADDING = 4.0
public let RPG_AUTHORITY_FOCUS_STROKE_CLEARANCE = 2.0

private func rpgContextualDetailText(resolvedFocus: RPGSemanticDescriptor,
                                     input: RPGScreenModelInput,
                                     effectiveStatus: RPGStatusPresentation?) -> String? {
    if resolvedFocus.id.rawValue == "status:current", let effectiveStatus {
        return effectiveStatus.accessibilityText
    }
    if input.authority.phase != .localReady, !resolvedFocus.enabled,
       resolvedFocus.actionCommand?.requiresAuthority == true {
        return rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
    }
    if resolvedFocus.id.rawValue == "authority:phase" {
        return rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
    }
    return nil
}

private func rpgBoundedCommandFreeScreenModel(_ input: RPGScreenModelInput,
                                               status: RPGStatusPresentation?,
                                               message: String) -> RPGScreenModel {
    let zero = RPGLogicalRect(x: 0, y: 0, width: 0, height: 0)
    let zeroLayout = RPGScreenLayout(panelFrame: zero, headerFrame: zero,
        authorityChipFrame: zero, statusChipFrame: nil, contextualDetailFrame: nil,
        stepOrTabFrame: zero, contentFrame: zero, commandFrame: zero,
        footerHelpFrame: zero)
    return RPGScreenModel(layout: zeroLayout, panelFrame: zero, contentFrame: zero,
        headerText: "RPG", statusText: "Unavailable", footerText: "",
        authority: rpgAuthorityPhasePresentation(input.authority.phase),
        status: status, descriptors: [], visibleDescriptors: [],
        projection: nil, characterSummary: nil, progressionSummary: nil, creationReview: nil,
        contentHeight: 0, viewportHeight: 0, scrollOffset: 0,
        focusedID: nil, nextFocusableID: nil, errorText: message,
        contextualDetailLines: [], stepOrTabText: "")
}

public func rpgBuildScreenModel(_ input: RPGScreenModelInput) -> RPGScreenModel {
    let effectiveStatus = input.localPreferenceStatus ?? input.authority.status
    let candidate = rpgBuildScreenModelPass(
        input, contextualDetailText: nil, resolvedFocusID: nil)
    guard candidate.panelFrame.width > 0, candidate.panelFrame.height > 0 else {
        return candidate
    }
    guard let resolvedID = candidate.focusedID,
          let candidateFocus = candidate.descriptors.first(where: {
              $0.id == resolvedID && $0.isFocusable
          }) else {
        return rpgBoundedCommandFreeScreenModel(input, status: effectiveStatus,
            message: "RPG screen could not resolve a focusable descriptor")
    }
    let candidateCommandFingerprint = candidateFocus.actionCommand.map(
        rpgSemanticCommandFingerprint)
    let candidateRequiresAuthority = candidateFocus.actionCommand?.requiresAuthority == true
    let detailText = rpgContextualDetailText(
        resolvedFocus: candidateFocus, input: input, effectiveStatus: effectiveStatus)
    let final = rpgBuildScreenModelPass(
        input, contextualDetailText: detailText, resolvedFocusID: resolvedID)
    guard final.panelFrame.width > 0, final.panelFrame.height > 0,
          final.focusedID == resolvedID,
          let finalFocus = final.descriptors.first(where: {
              $0.id == resolvedID && $0.isFocusable
          }),
          finalFocus.actionCommand.map(rpgSemanticCommandFingerprint) ==
            candidateCommandFingerprint,
          (finalFocus.actionCommand?.requiresAuthority == true) ==
            candidateRequiresAuthority else {
        return rpgBoundedCommandFreeScreenModel(input, status: effectiveStatus,
            message: "RPG screen focus changed during final contextual layout")
    }
    return final
}

private func rpgBuildScreenModelPass(_ input: RPGScreenModelInput,
                                     contextualDetailText detailText: String?,
                                     resolvedFocusID: RPGUIElementID?) -> RPGScreenModel {
    // A local disk failure is the immediate actionable condition and therefore atomically wins
    // over a concurrent authority-phase status. Text, icon, identity, and accessibility all use
    // this one effective value; clearing the local status reveals the authority status again.
    let effectiveStatus = input.localPreferenceStatus ?? input.authority.status
    guard let layout = rpgScreenLayout(viewportWidth: input.viewportWidth,
                                       viewportHeight: input.viewportHeight,
                                       hasStatus: effectiveStatus != nil,
                                       contextualDetailText: detailText) else {
        return rpgBoundedCommandFreeScreenModel(input, status: effectiveStatus,
            message: "RPG screen requires a finite viewport of at least 360 x 224")
    }
    let panel = layout.panelFrame
    let content = layout.contentFrame
    let authorityPresentation = rpgAuthorityPhasePresentation(input.authority.phase)
    let statusText = effectiveStatus?.text ?? authorityPresentation.visibleTitle
    let projection = input.state.created ? rpgPathProjection(
        pathID: input.state.pathID, state: input.state) : nil
    let characterSummary = rpgCharacterSummaryProjection(input.state,
        equipmentSummary: input.equipmentSummary, focusSummary: input.focusSummary)
    let progressionSummary = input.state.created ? rpgProgressionSummaryProjection(input.state) : nil
    let creationReview = !input.state.created ? rpgCreationReviewProjection(session: input.creation,
        chordBindings: input.configuredChords, authority: input.authority,
        inventoryCapacitySummary: input.inventoryCapacitySummary) : nil
    var descriptors: [RPGSemanticDescriptor] = []
    let authorityID = RPGUIElementID(rawValue: "authority:phase")!
    let authorityFrame = layout.authorityChipFrame
    descriptors.append(RPGSemanticDescriptor(
        id: authorityID, role: .group, label: "RPG authority",
        value: authorityPresentation.visibleTitle, help: authorityPresentation.visibleHelp,
        enabled: true, isFocusable: true,
        focusSelection: RPGScreenSelection(selectedSemanticID: authorityID), layoutRegion: .fixed,
        frame: authorityFrame, visibleFrame: authorityFrame))
    if let statusFrame = layout.statusChipFrame {
        let statusID = RPGUIElementID(rawValue: "status:current")!
        descriptors.append(RPGSemanticDescriptor(
            id: statusID, role: .group, label: "RPG status",
            value: statusText,
            help: effectiveStatus?.accessibilityText ?? statusText,
            enabled: true, isFocusable: true,
            focusSelection: RPGScreenSelection(selectedSemanticID: statusID), layoutRegion: .fixed,
            frame: statusFrame, visibleFrame: statusFrame))
    }
    let contextualDetailLines = detailText.map {
        rpgWrappedPresentationLines($0, width: (layout.contextualDetailFrame?.width ?? 8) - 8)
    } ?? []
    if let detailFrame = layout.contextualDetailFrame, let detailText {
        let detailID = RPGUIElementID(rawValue: "contextual-detail")!
        descriptors.append(RPGSemanticDescriptor(
            id: detailID, role: .staticText, label: "Context", value: detailText,
            help: detailText, enabled: true, isFocusable: false,
            layoutRegion: .fixed, visualLines: contextualDetailLines,
            frame: detailFrame, visibleFrame: detailFrame))
    }
    let stepText: String = {
        if !input.state.created { return input.creation.step.rawValue.capitalized }
        if let page = input.tutorial.page, input.tutorial.seenVersion < RPG_TUTORIAL_VERSION {
            return "Tutorial \(min(4, max(1, page))) of 4"
        }
        return input.tab.rawValue.capitalized
    }()
    if !input.state.created || input.tutorial.page != nil {
        let stepID = !input.state.created
            ? RPGUIElementID.creationStep(input.creation.step)
            : RPGUIElementID(rawValue: "tutorial-step")!
        descriptors.append(RPGSemanticDescriptor(
            id: stepID, role: .staticText, label: stepText, value: stepText,
            help: stepText,
            enabled: true, isFocusable: false, layoutRegion: .fixed,
            visualLines: rpgWrappedPresentationLines(
                stepText, width: layout.stepOrTabFrame.width - 8),
            frame: layout.stepOrTabFrame, visibleFrame: layout.stepOrTabFrame))
    }
    var y = content.y - input.scrollOffset

    if !input.state.created {
        switch input.creation.step {
        case .path:
            let pathOrder = Dictionary(uniqueKeysWithValues:
                RPG_PATH_DEFINITIONS.enumerated().map { ($0.element.id, $0.offset) })
            let cards = rpgPathCardModels(session: input.creation).sorted { lhs, rhs in
                if lhs.selected != rhs.selected { return lhs.selected && !rhs.selected }
                return (pathOrder[lhs.pathID] ?? Int.max) <
                    (pathOrder[rhs.pathID] ?? Int.max)
            }
            let columns = input.viewportWidth >= 520 && input.viewportHeight >= 330 ? 3 : 1
            let gap = 6.0
            let cardWidth = (content.width - gap * Double(columns - 1)) / Double(columns)
            let textWidth = max(1, cardWidth - 42)
            let cardLines = cards.map { card in
                rpgWrappedCardLines([card.displayName, card.roleText, card.primaryText,
                                     card.presetText,
                                     card.selected ? "Selected" : "Choose \(card.displayName)"],
                                    width: textWidth)
            }
            let cardHeights = cardLines.enumerated().map { index, lines in
                max(52, rpgCardHeight(
                    visualLines: lines, hasOperation: !cards[index].selected))
            }
            let cardHeight = max(72, cardHeights.max() ?? 72)
            var compactY = y
            for (index, card) in cards.enumerated() {
                let column = index % columns
                let row = index / columns
                let height = columns == 1 ? cardHeights[index] : cardHeight
                let frame = RPGLogicalRect(x: content.x + Double(column) * (cardWidth + gap),
                    y: columns == 1 ? compactY : y + Double(row) * (cardHeight + gap),
                    width: cardWidth, height: height)
                descriptors.append(descriptor(id: .path(card.pathID), role: .group,
                    label: card.accessibilityLabel, value: card.selected ? "Selected" : "Not selected",
                    help: card.accessibilityHelp, selected: card.selected, frame: frame, visibleIn: content,
                    focusSelection: card.focusSelection,
                    iconAssetID: card.iconAssetID, visualLines: cardLines[index],
                    adornment: card.selected ? .selectedCheckDoubleBorder : .none))
                if !card.selected {
                    let chooseID = RPGUIElementID.operation(owner: .path(card.pathID), name: "choose")
                    let chooseFrame = RPGLogicalRect(x: frame.x + 6, y: frame.maxY - 24,
                        width: frame.width - 12, height: 18)
                    descriptors.append(descriptor(id: chooseID, role: .button,
                        label: "Choose \(card.displayName)", help: card.accessibilityHelp,
                        frame: chooseFrame, visibleIn: content, command: .choosePath(card.pathID),
                        visualLines: ["Choose \(card.displayName)"]))
                }
                if columns == 1 { compactY = frame.maxY + gap }
            }
            y = columns == 1 ? compactY
                : y + Double((cards.count + columns - 1) / columns) * (cardHeight + gap)
        case .branch:
            if let path = rpgPathDefinition(input.creation.selectedPathID) {
                let selectedBranchID = input.creation.selectedDraft?.branchID
                let branchIDs = path.branchIDs.sorted { lhs, rhs in
                    if (lhs == selectedBranchID) != (rhs == selectedBranchID) {
                        return lhs == selectedBranchID
                    }
                    return (path.branchIDs.firstIndex(of: lhs) ?? Int.max) <
                        (path.branchIDs.firstIndex(of: rhs) ?? Int.max)
                }
                let large = input.viewportWidth >= 520 && input.viewportHeight >= 330
                let columns = large ? 3 : 1
                let gap = 6.0
                let cardWidth = (content.width - gap * Double(columns - 1)) / Double(columns)
                var branchLines: [[String]] = []
                for branchID in branchIDs {
                    guard let branch = rpgBranchDefinition(branchID),
                          let starter = branch.skillIDs.first,
                          let skill = rpgSkillDefinition(starter) else {
                        branchLines.append([])
                        continue
                    }
                    let benefit = rpgSkillRankBenefit(starter, rank: 1) ?? ""
                    let unlockNames = skill.spellUnlocks.filter { $0.rank == 1 }.compactMap {
                        rpgSpellDefinition($0.spellID)?.displayName
                    }
                    let selected = selectedBranchID == branchID
                    branchLines.append(rpgWrappedCardLines([
                        branch.displayName,
                        skill.kind == .active ? "Active Foundation" : "Passive Foundation",
                        benefit,
                        "Automatic unlocks: \(unlockNames.isEmpty ? "None" : unlockNames.joined(separator: ", "))",
                        selected ? "Selected" : "Choose \(branch.displayName)",
                    ], width: max(1, cardWidth - 42)))
                }
                let cardHeights = branchLines.enumerated().map { index, lines in
                    let selected = selectedBranchID == branchIDs[index]
                    return max(52, rpgCardHeight(
                        visualLines: lines, hasOperation: !selected))
                }
                let cardHeight = max(72, cardHeights.max() ?? (large ? 112 : 84))
                var compactY = y
                for (index, branchID) in branchIDs.enumerated() {
                    guard let branch = rpgBranchDefinition(branchID), let starter = branch.skillIDs.first,
                          let skill = rpgSkillDefinition(starter),
                          rpgIconPixels(assetID: rpgAssetIDForSkill(starter)) != nil else { continue }
                    let column = index % columns
                    let row = index / columns
                    let height = columns == 1 ? cardHeights[index] : cardHeight
                    let frame = RPGLogicalRect(x: content.x + Double(column) * (cardWidth + gap),
                        y: columns == 1 ? compactY : y + Double(row) * (cardHeight + gap),
                        width: cardWidth, height: height)
                    let unlocks = skill.spellUnlocks.filter { $0.rank == 1 }.compactMap {
                        rpgSpellDefinition($0.spellID)?.displayName
                    }
                    let benefit = rpgSkillRankBenefit(starter, rank: 1) ?? ""
                    let unlockHelp = "; Automatic unlocks: \(unlocks.isEmpty ? "None" : unlocks.joined(separator: ", "))"
                    let selected = input.creation.selectedDraft?.branchID == branchID
                    descriptors.append(descriptor(id: .branch(branchID), role: .group,
                        label: branch.displayName, value: skill.kind == .active ? "Active Foundation" : "Passive Foundation",
                        help: "\(benefit)\(unlockHelp)", selected: selected,
                        frame: frame, visibleIn: content,
                        focusSelection: RPGScreenSelection(selectedSemanticID: .branch(branchID)),
                        iconAssetID: rpgAssetIDForSkill(starter), visualLines: branchLines[index],
                        adornment: selected ? .selectedCheckDoubleBorder : .none))
                    if !selected {
                        let chooseID = RPGUIElementID.operation(owner: .branch(branchID), name: "choose")
                        let chooseFrame = RPGLogicalRect(x: frame.x + 6, y: frame.maxY - 24,
                            width: frame.width - 12, height: 18)
                        descriptors.append(descriptor(id: chooseID, role: .button,
                            label: "Choose \(branch.displayName)", frame: chooseFrame, visibleIn: content,
                            command: .chooseBranch(branchID),
                            visualLines: ["Choose \(branch.displayName)"]))
                    }
                    if columns == 1 { compactY = frame.maxY + gap }
                }
                y = columns == 1 ? compactY
                    : y + Double((path.branchIDs.count + columns - 1) / columns) *
                        (cardHeight + gap)
            }
        case .attributes:
            for attribute in RPG_ATTRIBUTE_DISPLAY_ORDER {
                let id = RPGUIElementID.attribute(attribute)
                let value = input.creation.selectedDraft?.attributes.value(attribute) ?? 0
                let frame = RPGLogicalRect(x: content.x, y: y, width: content.width, height: 28)
                descriptors.append(descriptor(id: id, role: .row, label: shortAttribute(attribute),
                    value: String(value), help: "Creation range 6 through 14; total must be 42.",
                    frame: frame, visibleIn: content,
                    focusSelection: RPGScreenSelection(selectedSemanticID: id)))
                let decrementID = RPGUIElementID.operation(owner: id, name: "decrement")
                let incrementID = RPGUIElementID.operation(owner: id, name: "increment")
                descriptors.append(descriptor(id: decrementID, role: .button, label: "Decrease \(shortAttribute(attribute))",
                    enabled: value > RPGAttributes.minimum,
                    frame: RPGLogicalRect(x: frame.maxX - 54, y: frame.y + 4, width: 22, height: 20),
                    visibleIn: content, command: .adjustAttribute(attribute, -1),
                    visualLines: ["-"]))
                descriptors.append(descriptor(id: incrementID, role: .button, label: "Increase \(shortAttribute(attribute))",
                    enabled: value < RPGAttributes.maximumAtCreation,
                    frame: RPGLogicalRect(x: frame.maxX - 26, y: frame.y + 4, width: 22, height: 20),
                    visibleIn: content, command: .adjustAttribute(attribute, 1),
                    visualLines: ["+"]))
                y += 28
            }
            let resetID = RPGUIElementID(rawValue: "creation:attributes:operation:reset")!
            descriptors.append(descriptor(id: resetID, role: .button, label: "Reset to Preset",
                frame: RPGLogicalRect(x: content.x, y: y, width: 132, height: 22), visibleIn: content,
                command: .resetAttributes))
            y += 28
        case .review:
            let result = rpgCreationDraft(from: input.creation)
            let id = RPGUIElementID(rawValue: "creation:review")!
            let reviewLines: [(String, String)]
            if let review = creationReview {
                let attributes = review.attributes.map { "\(shortAttribute($0.0)) \($0.1)" }.joined(separator: " · ")
                reviewLines = [
                    ("Path and specialization", "\(review.path) · \(review.branch)"),
                    ("Attributes", attributes),
                    ("Foundation", review.starterSkill),
                    ("Starter kit", review.starterKit.joined(separator: ", ")),
                    ("Automatic spells", review.automaticSpells.isEmpty ? "None" : review.automaticSpells.joined(separator: ", ")),
                    ("Focus requirement", review.focusRequirement),
                    ("Level-one progression", review.levelOneGuidance),
                    ("Configured RPG chords", review.configuredChords.joined(separator: "; ")),
                    ("Controller scope", review.controllerScope),
                    ("Inventory", review.inventoryCapacityCaveat),
                    ("Authority", review.authorityCaveat),
                ]
            } else {
                switch result {
                case .failure(.invalidAttributeBudget(let total)):
                    reviewLines = [("Attributes",
                        "Current total is \(total); required total is 42.")]
                case .failure(.unmetStarterRequirement):
                    reviewLines = [("Foundation",
                        "The selected Foundation attribute requirement is not met.")]
                case .failure:
                    reviewLines = [("Review", "Creation draft is invalid.")]
                case .success:
                    reviewLines = []
                }
            }
            for (index, line) in reviewLines.enumerated() {
                let rowID = RPGUIElementID(rawValue: "\(id.rawValue):row:\(index)")!
                let lines = rpgWrappedPresentationLines(line.0, width: content.width - 8) +
                    rpgWrappedPresentationLines(line.1, width: content.width - 8)
                let height = max(28, Double(lines.count) * 9 + 8)
                let frame = RPGLogicalRect(x: content.x, y: y,
                                           width: content.width, height: height)
                descriptors.append(descriptor(id: rowID, role: .row, label: line.0, value: line.1,
                    help: line.1, frame: frame, visibleIn: content,
                    visualLines: lines))
                y += height
            }
        }
        let commandY = layout.commandFrame.y + 3
        let leftFrame = RPGLogicalRect(x: layout.commandFrame.x + 4, y: commandY,
                                       width: 84, height: 20)
        if input.creation.step == .review {
            let reviewID = RPGUIElementID(rawValue: "creation:review")!
            let createID = RPGUIElementID.operation(owner: reviewID, name: "create")
            let result = rpgCreationDraft(from: input.creation)
            let authorityReady = rpgAuthorityEnabled(input.authority)
            let enabled: Bool
            let help: String
            let command: RPGSemanticCommand?
            switch result {
            case .success(let draft):
                enabled = authorityReady && input.inventoryCapacityAvailable
                help = !input.inventoryCapacityAvailable
                    ? input.inventoryCapacitySummary
                    : authorityReady ? "Creates this character and starter kit atomically." :
                        rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                command = input.inventoryCapacityAvailable ? .create(draft) : nil
            case .failure(.invalidAttributeBudget(let total)):
                enabled = false
                help = "Attributes must total 42; current total is \(total)."
                command = nil
            case .failure(.unmetStarterRequirement):
                enabled = false
                help = "Resolve the Foundation attribute requirement before continuing."
                command = nil
            case .failure:
                enabled = false
                help = "Resolve the creation requirements before continuing."
                command = nil
            }
            let frame = RPGLogicalRect(x: layout.commandFrame.maxX - 158, y: commandY,
                                       width: 154, height: 20)
            descriptors.append(descriptor(id: createID, role: .button,
                label: "Create Character", help: help, enabled: enabled, locked: !enabled,
                frame: frame, visibleIn: layout.commandFrame, command: command,
                layoutRegion: .fixed, visualLines: ["Create Character"]))
        } else {
            let nextID = RPGUIElementID(rawValue: "creation:\(input.creation.step.rawValue):operation:next")!
            let nextValidation: (Bool, String) = {
                switch input.creation.step {
                case .path:
                    return (rpgPathDefinition(input.creation.selectedPathID) != nil,
                            "Select a registered path.")
                case .branch:
                    guard let draft = input.creation.selectedDraft,
                          validatedStarter(pathID: draft.pathID, branchID: draft.branchID) != nil else {
                        return (false, "Starter registry mismatch")
                    }
                    return (true, "Continue to attributes.")
                case .attributes:
                    switch rpgCreationDraft(from: input.creation) {
                    case .success: return (true, "Continue to review.")
                    case .failure(.invalidAttributeBudget(let total)):
                        return (false, "Attributes must total 42; current total is \(total).")
                    case .failure: return (false, "Resolve the creation requirements before continuing.")
                    }
                case .review: return (false, "")
                }
            }()
            descriptors.append(descriptor(id: nextID, role: .button, label: "Next",
                help: nextValidation.1, enabled: nextValidation.0, locked: !nextValidation.0,
                frame: RPGLogicalRect(x: layout.commandFrame.maxX - 70, y: commandY,
                                      width: 66, height: 20),
                visibleIn: layout.commandFrame, command: nextValidation.0 ? .creationNext : nil,
                layoutRegion: .fixed, visualLines: ["Next"]))
        }
        let backID = RPGUIElementID(rawValue: "creation:\(input.creation.step.rawValue):operation:back")!
        descriptors.append(descriptor(id: backID, role: .button,
            label: input.creation.step == .path ? "Close" : "Back",
            frame: leftFrame, visibleIn: layout.commandFrame, command: .creationBack,
            layoutRegion: .fixed,
            visualLines: [input.creation.step == .path ? "Close" : "Back"]))
    } else if let page = input.tutorial.page, input.tutorial.seenVersion < RPG_TUTORIAL_VERSION {
        let page = min(4, max(1, page))
        let id = RPGUIElementID.tutorial(page, pathID: input.state.pathID,
                                         branchID: input.state.specializationBranchID)
        let tutorialLabel = "RPG tutorial, page \(page) of 4"
        let tutorialValue = RPG_TUTORIAL_PAGES[page - 1]
        let tutorialLines = rpgWrappedPresentationLines(
            tutorialLabel, width: content.width - 8) +
            rpgWrappedPresentationLines(tutorialValue, width: content.width - 8)
        let tutorialHeight = max(28, Double(tutorialLines.count) * 9 + 8)
        let frame = RPGLogicalRect(
            x: content.x, y: y, width: content.width, height: tutorialHeight)
        descriptors.append(descriptor(id: id, role: .group, label: "RPG tutorial, page \(page) of 4",
            value: tutorialValue, frame: frame, visibleIn: content,
            visualLines: tutorialLines))
        y += tutorialHeight
        let commandY = layout.commandFrame.y + 3
        descriptors.append(descriptor(id: .operation(owner: id, name: "close"), role: .button,
            label: "Close", frame: RPGLogicalRect(x: layout.commandFrame.x + 4, y: commandY,
                                                   width: 58, height: 20),
            visibleIn: layout.commandFrame, command: .back,
            layoutRegion: .fixed, visualLines: ["Close"]))
        if page > 1 {
            descriptors.append(descriptor(id: .operation(owner: id, name: "back"), role: .button,
                label: "Back", frame: RPGLogicalRect(x: layout.commandFrame.x + 66, y: commandY,
                                                       width: 58, height: 20),
                visibleIn: layout.commandFrame, command: .tutorialBack,
                layoutRegion: .fixed, visualLines: ["Back"]))
        }
        let isLast = page == 4
        descriptors.append(descriptor(id: .operation(owner: id, name: isLast ? "finish" : "next"), role: .button,
            label: isLast ? "Finish" : "Next",
            frame: RPGLogicalRect(x: layout.commandFrame.maxX - 86, y: commandY,
                                  width: 82, height: 20),
            visibleIn: layout.commandFrame, command: isLast ? .tutorialFinish : .tutorialNext,
            layoutRegion: .fixed, visualLines: [isLast ? "Finish" : "Next"]))
        descriptors.append(descriptor(id: .operation(owner: id, name: "skip"), role: .button,
            label: "Skip", frame: RPGLogicalRect(x: layout.commandFrame.maxX - 148, y: commandY,
                                                  width: 58, height: 20),
            visibleIn: layout.commandFrame, command: .tutorialSkip,
            layoutRegion: .fixed, visualLines: ["Skip"]))
    } else if let projection {
        guard let tabFrames = rpgCharacterTabFrames(in: layout.stepOrTabFrame) else {
            return rpgBoundedCommandFreeScreenModel(input, status: effectiveStatus,
                message: "RPG screen cannot fit all five complete character tabs")
        }
        for tabProjection in tabFrames {
            let tab = tabProjection.tab
            descriptors.append(descriptor(id: .tab(tab), role: .tab,
                label: tab.rawValue.capitalized, selected: tab == input.tab,
                frame: tabProjection.frame,
                visibleIn: layout.stepOrTabFrame,
                command: tab == input.tab ? nil : .selectTab(tab),
                layoutRegion: .fixed, visualLines: tabProjection.visualLines))
        }
        let closeID = RPGUIElementID(rawValue: "sheet:operation:close")!
        descriptors.append(descriptor(id: closeID, role: .button, label: "Close",
            frame: RPGLogicalRect(x: layout.commandFrame.x + 4,
                                  y: layout.commandFrame.y + 3,
                                  width: 66, height: 20),
            visibleIn: layout.commandFrame, command: .back,
            layoutRegion: .fixed, visualLines: ["Close"]))
        switch input.tab {
        case .skills:
            for rank in projection.ranks {
                let evaluation = rank.nextEvaluation
                let locked = !rank.purchased && evaluation?.permitted != true
                let reason = evaluation.flatMap { purchaseFailureText($0.failure) } ?? ""
                let skillDisplayName = rpgSkillDefinition(rank.skillID)?.displayName ?? "Unavailable skill"
                let operationLabel = "Rank Up \(skillDisplayName)"
                let operationLines = evaluation == nil ? [] :
                    rpgWrappedControlLines(operationLabel, width: 102)
                let operationHeight = evaluation == nil ? 0 : rpgControlHeight(lines: operationLines)
                let rankValue = rank.current ? "Current rank" :
                    rank.purchased ? "Purchased" :
                    rank.nextEvaluation != nil ? (locked ? "Locked next rank" : "Next rank") :
                    "Future rank"
                let rankLines = rpgWrappedPresentationLines(
                    "\(skillDisplayName), rank \(rank.rank)", width: content.width - 8) +
                    rpgWrappedPresentationLines(rankValue, width: content.width - 8)
                let rankHeight = rpgControlHeight(lines: rankLines)
                let rowHeight = max(20, rankHeight,
                    operationHeight + (evaluation == nil ? 0 : 2))
                let frame = RPGLogicalRect(x: content.x, y: y,
                                           width: content.width, height: rowHeight)
                descriptors.append(descriptor(id: rank.id, role: .rankCell,
                    label: "\(skillDisplayName), rank \(rank.rank)",
                    value: rankValue,
                    help: reason, enabled: true, locked: locked, frame: frame, visibleIn: content,
                    focusSelection: RPGScreenSelection(
                        selectedSemanticID: rank.id, inspectorItemID: rank.id),
                    visualLines: rankLines))
                if let evaluation {
                    let operationID = RPGUIElementID.operation(owner: rank.id, name: "rank-up")
                    let authorityReady = rpgAuthorityEnabled(input.authority)
                    let enabled = evaluation.permitted && authorityReady
                    let help = authorityReady ? (purchaseFailureText(evaluation.failure) ??
                        "Spend \(evaluation.cost ?? 0) skill points.") :
                        rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                    descriptors.append(descriptor(id: operationID, role: .button,
                        label: operationLabel,
                        value: "Rank \(evaluation.targetRank)", help: help, enabled: enabled, locked: !enabled,
                        frame: RPGLogicalRect(x: frame.maxX - 104, y: frame.y + 1,
                                              width: 102, height: operationHeight),
                        visibleIn: content,
                        command: evaluation.permitted ? .rankUp(rank.skillID) : nil,
                        visualLines: operationLines))
                }
                y += rowHeight
            }
        case .actives:
            let actionsHeadingID = RPGUIElementID(rawValue: "actives:path-actions")!
            descriptors.append(descriptor(id: actionsHeadingID, role: .staticText,
                label: "Path Actions", frame: RPGLogicalRect(
                    x: content.x, y: y, width: content.width, height: 20),
                visibleIn: content, visualLines: ["Path Actions"]))
            y += 20
            for skillID in projection.activeSkillIDs {
                let displayName = rpgSkillDefinition(skillID)?.displayName ?? "Unavailable action"
                let learned = (input.state.skillRanks[skillID] ?? 0) > 0
                let prepared = input.state.preparedSkillIDs.contains(skillID)
                let token = rpgPreparedActionToken(kind: .skill, id: skillID)
                let slotted = input.quickSlots.tokens.contains(token)
                let frame = RPGLogicalRect(x: content.x, y: y,
                                           width: content.width, height: 32)
                descriptors.append(descriptor(id: .skill(skillID), role: .row,
                    label: displayName,
                    value: !learned ? "Locked" : prepared ? "Prepared" : "Learned, not prepared",
                    prepared: prepared, slotted: slotted, frame: frame, visibleIn: content,
                    focusSelection: RPGScreenSelection(selectedSemanticID: .skill(skillID),
                                                       inspectorItemID: .skill(skillID))))
                y += 32
            }
            let selectedSkillID: String? = {
                if let inspector = input.selection?.inspectorItemID {
                    return projection.activeSkillIDs.first { inspector == .skill($0) }
                }
                return projection.activeSkillIDs.first
            }()
            if let skillID = selectedSkillID {
                let displayName = rpgSkillDefinition(skillID)?.displayName ?? "Unavailable action"
                let learned = (input.state.skillRanks[skillID] ?? 0) > 0
                let prepared = input.state.preparedSkillIDs.contains(skillID)
                let token = rpgPreparedActionToken(kind: .skill, id: skillID)
                let operationLabel = prepared ? "Unprepare \(displayName)" : "Prepare \(displayName)"
                let operationLines = rpgWrappedControlLines(operationLabel, width: 150)
                let operationHeight = rpgControlHeight(lines: operationLines)
                let inspectorHeight = 28 + operationHeight + (prepared ? 86 : 0)
                let inspectorID = RPGUIElementID(rawValue: "actives:selected-action")!
                let inspectorFrame = RPGLogicalRect(x: content.x, y: y,
                    width: content.width, height: inspectorHeight)
                descriptors.append(descriptor(id: inspectorID, role: .group,
                    label: "Selected Action", value: displayName, frame: inspectorFrame,
                    visibleIn: content, visualLines: ["Selected Action", displayName]))
                let operationID = RPGUIElementID.operation(owner: .skill(skillID),
                                                            name: prepared ? "unprepare" : "prepare")
                let enabled = learned && rpgAuthorityEnabled(input.authority)
                let operationHelp = rpgAuthorityEnabled(input.authority)
                    ? (learned ? (prepared ? "Remove this skill from prepared actions." :
                        "Add this skill to prepared actions.") : "Learn this skill before preparing it.")
                    : rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                descriptors.append(descriptor(id: operationID, role: .button,
                    label: operationLabel,
                    help: operationHelp,
                    enabled: enabled, locked: !enabled,
                    frame: RPGLogicalRect(x: content.x, y: y + 28,
                                          width: 150, height: operationHeight),
                    visibleIn: content,
                    command: learned
                        ? (prepared ? .unprepareSkill(skillID) : .prepareSkill(skillID)) : nil,
                    visualLines: operationLines))
                if prepared {
                    let selected = input.state.selectedPreparedActionID == token
                    let selectHelp = rpgAuthorityEnabled(input.authority)
                        ? (selected ? "This skill is already selected." : "Select this prepared skill.")
                        : rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                    descriptors.append(descriptor(id: .operation(owner: .skill(skillID), name: "select"),
                        role: .button, label: "Select \(displayName)", help: selectHelp,
                        selected: selected,
                        enabled: !selected && rpgAuthorityEnabled(input.authority), locked: selected,
                        frame: RPGLogicalRect(x: content.x + 154, y: y + 28,
                                              width: 150, height: operationHeight), visibleIn: content,
                        command: !selected ? .selectSkill(skillID) : nil,
                        visualLines: rpgWrappedControlLines("Select \(displayName)", width: 150)))
                    let writable = input.localPreferenceWritable && input.localPreferenceScope != nil
                    let assignable = writable && input.authority.phase != .authorityExhausted
                    let headingID = RPGUIElementID.operation(owner: .skill(skillID), name: "assign-heading")
                    descriptors.append(descriptor(id: headingID, role: .staticText,
                        label: "Assign \(displayName) to a quick slot", enabled: true,
                        frame: RPGLogicalRect(x: content.x, y: y + 28 + operationHeight,
                                              width: content.width, height: 20), visibleIn: content))
                    let gap = 3.0
                    let buttonWidth = (content.width - gap * 2) / 3
                    for slot in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
                        let column = slot % 3, row = slot / 3
                        descriptors.append(descriptor(
                            id: .operation(owner: .skill(skillID), name: "assign-\(slot)"),
                            role: .button, label: "Assign Slot \(slot + 1)",
                            help: input.authority.phase == .authorityExhausted
                                ? rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                                : writable ? "Assign \(displayName) to quick slot \(slot + 1)."
                                    : RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP,
                            selected: input.quickSlots.tokens[slot] == token,
                            slotted: input.quickSlots.tokens[slot] == token,
                            enabled: assignable, locked: !assignable,
                            frame: RPGLogicalRect(
                                x: content.x + Double(column) * (buttonWidth + gap),
                                y: y + 48 + operationHeight + Double(row) * 22,
                                width: buttonWidth, height: 20), visibleIn: content,
                            command: assignable ? .assignSlot(token: token, slot: slot) : nil))
                    }
                }
                y += inspectorHeight
            }
            let slotsHeadingID = RPGUIElementID(rawValue: "actives:local-quick-slots")!
            descriptors.append(descriptor(id: slotsHeadingID, role: .staticText,
                label: "Local Quick Slots", frame: RPGLogicalRect(
                    x: content.x, y: y, width: content.width, height: 20),
                visibleIn: content, visualLines: ["Local Quick Slots"]))
            y += 20
            for slot in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
                let token = input.quickSlots.tokens[slot]
                let slotID = RPGUIElementID.slot(slot)
                let frame = RPGLogicalRect(x: content.x, y: y, width: content.width, height: 28)
                descriptors.append(descriptor(id: slotID, role: .row,
                    label: "Quick Slot \(slot + 1)", value: rpgPreparedActionDisplayName(token),
                    slotted: token != nil, enabled: true, frame: frame, visibleIn: content,
                    focusSelection: RPGScreenSelection(selectedSemanticID: slotID)))
                var advance = 28.0
                if token != nil {
                    let writable = input.localPreferenceWritable && input.localPreferenceScope != nil
                    let gap = 4.0
                    let buttonWidth = (content.width - gap * 2) / 3
                    let controlY = frame.maxY + 2
                    let controlHeight = 20.0
                    descriptors.append(descriptor(id: .operation(owner: slotID, name: "clear"),
                        role: .button, label: "Clear Slot \(slot + 1)",
                        help: writable ? "" : RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP,
                        enabled: writable, locked: !writable,
                        frame: RPGLogicalRect(x: content.x, y: controlY,
                                              width: buttonWidth, height: controlHeight),
                        visibleIn: content, command: writable ? .clearSlot(slot) : nil,
                        visualLines: ["Clear"]))
                    if slot > 0 {
                        descriptors.append(descriptor(id: .operation(owner: slotID, name: "move-left"),
                            role: .button, label: "Move Quick Slot \(slot + 1) Left",
                            help: writable ? "" : RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP,
                            enabled: writable, locked: !writable,
                            frame: RPGLogicalRect(x: content.x + buttonWidth + gap,
                                                  y: controlY, width: buttonWidth,
                                                  height: controlHeight), visibleIn: content,
                            command: writable ? .moveSlot(from: slot, to: slot - 1) : nil,
                            visualLines: ["← Move Left"], adornment: .moveLeft))
                    }
                    if slot + 1 < RPG_ACTION_QUICK_SLOT_COUNT {
                        descriptors.append(descriptor(id: .operation(owner: slotID, name: "move-right"),
                            role: .button, label: "Move Quick Slot \(slot + 1) Right",
                            help: writable ? "" : RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP,
                            enabled: writable, locked: !writable,
                            frame: RPGLogicalRect(x: content.x + 2 * (buttonWidth + gap),
                                                  y: controlY, width: buttonWidth,
                                                  height: controlHeight), visibleIn: content,
                            command: writable ? .moveSlot(from: slot, to: slot + 1) : nil,
                            visualLines: ["Move Right →"], adornment: .moveRight))
                    }
                    advance += controlHeight + 4
                }
                y += advance
            }
        case .spells:
            if projection.reachableSpellIDs.isEmpty {
                let id = RPGUIElementID(rawValue: "spells:empty")!
                let frame = RPGLogicalRect(x: content.x, y: y, width: content.width, height: 28)
                descriptors.append(descriptor(id: id, role: .staticText, label: "No spells on this path",
                    help: "This path advances through passive and active skills.", frame: frame, visibleIn: content))
                y += 28
            } else {
                for spellID in projection.reachableSpellIDs {
                    let displayName = rpgSpellDefinition(spellID)?.displayName ?? "Unavailable action"
                    let known = input.state.knownSpellIDs.contains(spellID)
                    let prepared = input.state.preparedSpellIDs.contains(spellID)
                    let token = rpgPreparedActionToken(kind: .spell, id: spellID)
                    let slotted = input.quickSlots.tokens.contains(token)
                    let operationLabel = prepared ? "Unprepare \(displayName)" : "Prepare \(displayName)"
                    let operationLines = rpgWrappedControlLines(operationLabel, width: 100)
                    let operationHeight = rpgControlHeight(lines: operationLines)
                    let rowHeight = max(28, operationHeight + 8)
                    let frame = RPGLogicalRect(x: content.x, y: y,
                                               width: content.width, height: rowHeight)
                    descriptors.append(descriptor(id: .spell(spellID), role: .row,
                        label: displayName,
                        value: !known ? "Locked" : prepared ? "Prepared" : "Known, not prepared",
                        prepared: prepared, slotted: slotted, frame: frame, visibleIn: content,
                        focusSelection: RPGScreenSelection(selectedSemanticID: .spell(spellID))))
                    let operationID = RPGUIElementID.operation(owner: .spell(spellID),
                                                                name: prepared ? "unprepare" : "prepare")
                    let enabled = known && rpgAuthorityEnabled(input.authority)
                    let operationHelp = rpgAuthorityEnabled(input.authority)
                        ? (known ? (prepared ? "Remove this spell from prepared actions." :
                            "Add this spell to prepared actions.") : "Learn this spell before preparing it.")
                        : rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                    descriptors.append(descriptor(id: operationID, role: .button,
                        label: operationLabel,
                        help: operationHelp,
                        enabled: enabled, locked: !enabled,
                        frame: RPGLogicalRect(x: frame.maxX - 104, y: frame.y + 4,
                                              width: 100, height: operationHeight),
                        visibleIn: content,
                        command: known
                            ? (prepared ? .unprepareSpell(spellID) : .prepareSpell(spellID)) : nil,
                        visualLines: operationLines))
                    var rowAdvance = rowHeight
                    if prepared {
                        let selected = input.state.selectedPreparedSpellID == spellID
                        let selectHelp = rpgAuthorityEnabled(input.authority)
                            ? (selected ? "This spell is already selected." : "Select this prepared spell.")
                            : rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                        descriptors.append(descriptor(id: .operation(owner: .spell(spellID), name: "select"),
                            role: .button, label: "Select \(displayName)", help: selectHelp,
                            selected: selected,
                            enabled: !selected && rpgAuthorityEnabled(input.authority), locked: selected,
                            frame: RPGLogicalRect(x: frame.maxX - 212, y: frame.y + 4,
                                                  width: 104, height: 20), visibleIn: content,
                            command: !selected ? .selectSpell(spellID) : nil,
                            visualLines: rpgWrappedControlLines("Select \(displayName)", width: 104)))
                        let writable = input.localPreferenceWritable && input.localPreferenceScope != nil
                        let assignable = writable && input.authority.phase != .authorityExhausted
                        let headingID = RPGUIElementID.operation(owner: .spell(spellID), name: "assign-heading")
                        descriptors.append(descriptor(id: headingID, role: .staticText,
                            label: "Assign \(displayName) to a quick slot", enabled: true,
                            frame: RPGLogicalRect(x: content.x, y: frame.maxY,
                                                  width: content.width, height: 20), visibleIn: content))
                        let gap = 3.0
                        let buttonWidth = (content.width - gap * 2) / 3
                        for slot in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
                            let column = slot % 3, row = slot / 3
                            descriptors.append(descriptor(
                                id: .operation(owner: .spell(spellID), name: "assign-\(slot)"),
                                role: .button, label: "Assign Slot \(slot + 1)",
                                help: input.authority.phase == .authorityExhausted
                                    ? rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp
                                    : writable ? "Assign \(displayName) to quick slot \(slot + 1)."
                                        : RPG_LOCAL_SLOT_PERSISTENCE_DISABLED_HELP,
                                selected: input.quickSlots.tokens[slot] == token,
                                slotted: input.quickSlots.tokens[slot] == token,
                                enabled: assignable, locked: !assignable,
                                frame: RPGLogicalRect(
                                    x: content.x + Double(column) * (buttonWidth + gap),
                                    y: frame.maxY + 20 + Double(row) * 22,
                                    width: buttonWidth, height: 20), visibleIn: content,
                                command: assignable ? .assignSlot(token: token, slot: slot) : nil))
                        }
                        rowAdvance = rowHeight + 86
                    }
                    y += rowAdvance
                }
            }
        case .character:
            if let summary = characterSummary {
                let attributes = summary.attributes.map { "\(shortAttribute($0.0)) \($0.1)" }.joined(separator: " · ")
                let derived = summary.derivedStats
                let nextThreshold = summary.nextLevelXPThreshold.map { " · next at \($0)" } ?? " · level cap"
                let levelAndXP = "Level \(summary.level) · \(summary.absoluteXP) XP" + nextThreshold
                let fatigue = String(format: "%.2f / %.2f", summary.fatigue, derived.maxFatigue)
                let recovery = String(format: "fatigue %.4f/tick · action x%.3f",
                                      derived.fatigueRegenPerTick, derived.actionRecoveryMultiplier)
                let offense = String(format: "melee +%.2f · accuracy +%.3f · spell +%.2f",
                                     derived.meleeDamageBonus, derived.actionAccuracyBonus,
                                     derived.spellPotencyBonus)
                var rows: [(String, String)] = [
                    ("Path", summary.path), ("Specialization", summary.specialization),
                    ("Level and XP", levelAndXP), ("Fatigue", fatigue),
                    ("Attributes", attributes),
                    ("Derived health", String(format: "%.2f", derived.maxHealth)),
                    ("Derived recovery", recovery), ("Derived offense", offense),
                    ("Banked points", "SP \(summary.availableSkillPoints) · AP \(summary.availableAttributePoints)"),
                    ("Equipment", summary.equipmentSummary), ("Focus", summary.focusSummary),
                    ("Next milestone", summary.nextActionableMilestone),
                ]
                if let guidance = summary.levelOneGuidance { rows.append(("Level-one guidance", guidance)) }
                for (index, row) in rows.enumerated() {
                    let id = RPGUIElementID(rawValue: "character:row:\(index)")!
                    let frame = RPGLogicalRect(x: content.x, y: y, width: content.width, height: 28)
                    descriptors.append(descriptor(id: id, role: .row, label: row.0, value: row.1,
                        help: row.1, frame: frame, visibleIn: content))
                    y += 28
                }
                for attribute in RPG_ATTRIBUTE_DISPLAY_ORDER {
                    let owner = RPGUIElementID.attribute(attribute)
                    let authorityReady = rpgAuthorityEnabled(input.authority)
                    let enabled = summary.availableAttributePoints > 0 && authorityReady
                    let frame = RPGLogicalRect(x: content.x, y: y,
                                               width: content.width, height: 28)
                    descriptors.append(descriptor(id: owner, role: .row,
                        label: "Spend Attribute: \(shortAttribute(attribute))",
                        value: "Current \(summary.attributes.first(where: { $0.0 == attribute })?.1 ?? 0)",
                        enabled: true, frame: frame, visibleIn: content,
                        focusSelection: RPGScreenSelection(selectedSemanticID: owner)))
                    descriptors.append(descriptor(id: .operation(owner: owner, name: "spend"),
                        role: .button, label: "Spend +1 \(shortAttribute(attribute))",
                        help: enabled ? "Spend one attribute point." :
                            (authorityReady ? "No attribute points available." :
                                rpgAuthorityPhasePresentation(input.authority.phase).visibleHelp),
                        enabled: enabled, locked: !enabled,
                        frame: RPGLogicalRect(x: frame.maxX - 112, y: frame.y + 4,
                                              width: 108, height: 20), visibleIn: content,
                        command: summary.availableAttributePoints > 0
                            ? .spendAttribute(attribute) : nil))
                    y += 28
                }
            }
        case .progression:
            if let summary = progressionSummary {
                func appendProgressionRow(id: RPGUIElementID, label: String, value: String) {
                    let lines = rpgWrappedPresentationLines(label, width: content.width - 8) +
                        rpgWrappedPresentationLines(value, width: content.width - 8)
                    let height = max(28, Double(lines.count) * 9 + 8)
                    let frame = RPGLogicalRect(x: content.x, y: y,
                                               width: content.width, height: height)
                    descriptors.append(descriptor(id: id, role: .row, label: label,
                        value: value, help: value, frame: frame, visibleIn: content,
                        visualLines: lines))
                    y += height
                }
                appendProgressionRow(
                    id: RPGUIElementID(rawValue: "progression:plan:selected-branch")!,
                    label: "Selected Branch",
                    value: summary.plan.selectedBranchDisplayName)
                for (index, milestone) in summary.plan.routeMilestones.enumerated() {
                    let name = rpgSkillDefinition(milestone.skillID)?.displayName ??
                        "Unavailable skill"
                    appendProgressionRow(
                        id: RPGUIElementID(rawValue: "progression:plan:milestone:\(index)")!,
                        label: "Route Milestone \(index + 1)",
                        value: "Level \(milestone.level) · \(name) rank \(milestone.rank) · \(milestone.cost) SP")
                }
                appendProgressionRow(
                    id: RPGUIElementID(rawValue: "progression:plan:completion-cost")!,
                    label: "Completion Cost",
                    value: "\(summary.plan.completionCost) SP completes all nine selected-branch milestones; \(summary.plan.levelCapEarnedSkillPoints) SP are earned by level 20.")
                appendProgressionRow(
                    id: RPGUIElementID(rawValue: "progression:plan:utility")!,
                    label: "Utility Allowance",
                    value: "\(summary.plan.utilityAllowance) SP remain for one cross-branch Foundation I.")
                appendProgressionRow(
                    id: RPGUIElementID(rawValue: "progression:plan:impact")!,
                    label: "Completion Impact",
                    value: summary.plan.completionImpactText)
                appendProgressionRow(
                    id: RPGUIElementID(rawValue: "progression:plan:cross-branch")!,
                    label: "Cross-Branch Constraint",
                    value: summary.plan.crossBranchCapstoneText)
                for level in summary.levels {
                    let roadmap = level.roadmapMilestones.map { milestone in
                        let name = rpgSkillDefinition(milestone.skillID)?.displayName ?? "Unavailable skill"
                        let complete = level.completedMilestones.contains(milestone) ? "complete" : "planned"
                        return "\(name) \(milestone.rank) (\(complete), \(milestone.cost) SP)"
                    }.joined(separator: "; ")
                    let value = "\(level.absoluteXPThreshold) XP · earned SP \(level.earnedSkillPoints) · earned AP \(level.earnedAttributePoints)" +
                        (roadmap.isEmpty ? "" : " · \(roadmap)")
                    let id = RPGUIElementID(rawValue: "progression:level:\(level.level)")!
                    appendProgressionRow(id: id, label: "Level \(level.level)", value: value)
                }
                let summaries: [(String, String)] = [
                    ("Banked points", "SP \(summary.bankedSkillPoints) · AP \(summary.bankedAttributePoints)"),
                    ("Next legal purchase", summary.nextLegalPurchase ?? "No legal skill purchase now"),
                    ("Specialization completion", "\(summary.specializationRemainingCost) SP remaining · " +
                        (summary.specializationCanComplete ? "completion remains possible" : "completion is no longer possible")),
                    ("Divergence", summary.divergenceWarning ?? "No specialization divergence warning"),
                ]
                for (index, row) in summaries.enumerated() {
                    let id = RPGUIElementID(rawValue: "progression:summary:\(index)")!
                    appendProgressionRow(id: id, label: row.0, value: row.1)
                }
            }
        }
    }
    let contentHeight = max(0, y + input.scrollOffset - content.y)
    let offset = rpgClampedScrollOffset(contentHeight: contentHeight, viewportHeight: content.height,
                                        requested: input.scrollOffset)
    if offset != input.scrollOffset {
        let delta = input.scrollOffset - offset
        descriptors = descriptors.map { descriptor in
            if descriptor.frame.y >= panel.maxY - 28 || descriptor.role == .tab ||
                descriptor.id.rawValue == "authority:phase" ||
                descriptor.id.rawValue == "status:current" { return descriptor }
            return shiftedContentDescriptor(descriptor, deltaY: delta, content: content)
        }
    }
    let focusable = descriptors.filter(\.isFocusable)
    let focused: RPGUIElementID?
    if let resolvedFocusID {
        guard focusable.contains(where: { $0.id == resolvedFocusID }) else {
            return rpgBoundedCommandFreeScreenModel(input, status: effectiveStatus,
                message: "RPG screen final focus is unavailable")
        }
        focused = resolvedFocusID
    } else {
        focused = input.focusedID.flatMap { wanted in
            focusable.first(where: { $0.id == wanted })?.id
        } ?? focusable.first?.id
    }
    let modelErrorText: String? = {
        guard !input.state.created, input.creation.step == .review else { return nil }
        if !input.inventoryCapacityAvailable { return input.inventoryCapacitySummary }
        if case .failure(.unmetStarterRequirement) = rpgCreationDraft(from: input.creation) {
            return "Resolve the Foundation attribute requirement before continuing."
        }
        if case .failure(.invalidAttributeBudget(let total)) = rpgCreationDraft(from: input.creation) {
            return "Current attribute total is \(total); required total is 42."
        }
        return nil
    }()
    return RPGScreenModel(layout: layout, panelFrame: panel, contentFrame: content,
        headerText: input.state.created ? "Character" : "Create Character",
        statusText: statusText,
        footerText: input.state.created ? "Tab to move focus; Enter to activate" : "Back · Next",
        authority: rpgAuthorityPhasePresentation(input.authority.phase),
        status: effectiveStatus, descriptors: descriptors,
        visibleDescriptors: descriptors.filter { $0.visibleFrame != nil }, projection: projection,
        characterSummary: characterSummary, progressionSummary: progressionSummary,
        creationReview: creationReview,
        contentHeight: contentHeight, viewportHeight: content.height, scrollOffset: offset,
        focusedID: focused,
        nextFocusableID: rpgNextFocusableID(in: descriptors, current: focused, forward: true),
        errorText: modelErrorText, contextualDetailLines: contextualDetailLines,
        stepOrTabText: stepText)
}

/// Step-5 production projection. It preserves the complete pure model and semantic geometry while
/// removing every command capability. The passive renderer, focus lookup, and semantic inspection
/// all consume this value; actionability is enabled only by the later guarded-input step.
public func rpgBuildPassiveScreenModel(_ input: RPGScreenModelInput) -> RPGScreenModel {
    let model = rpgBuildScreenModel(input)
    func passive(_ value: RPGSemanticDescriptor) -> RPGSemanticDescriptor {
        RPGSemanticDescriptor(
            id: value.id, role: value.role, groupID: value.groupID,
            label: value.label, value: value.value, help: value.help,
            selected: value.selected, prepared: value.prepared, slotted: value.slotted,
            enabled: value.enabled, locked: value.locked, isFocusable: value.isFocusable,
            focusSelection: value.focusSelection, layoutRegion: value.layoutRegion,
            iconAssetID: value.iconAssetID, visualLines: value.visualLines,
            adornment: value.adornment, frame: value.frame,
            visibleFrame: value.visibleFrame, actionCommand: nil)
    }
    return RPGScreenModel(
        layout: model.layout, panelFrame: model.panelFrame, contentFrame: model.contentFrame,
        headerText: model.headerText, statusText: model.statusText,
        footerText: model.footerText, authority: model.authority,
        status: model.status,
        descriptors: model.descriptors.map(passive),
        visibleDescriptors: model.visibleDescriptors.map(passive),
        projection: model.projection, characterSummary: model.characterSummary,
        progressionSummary: model.progressionSummary,
        creationReview: model.creationReview, contentHeight: model.contentHeight,
        viewportHeight: model.viewportHeight, scrollOffset: model.scrollOffset,
        focusedID: model.focusedID, nextFocusableID: model.nextFocusableID,
        errorText: model.errorText, contextualDetailLines: model.contextualDetailLines,
        stepOrTabText: model.stepOrTabText)
}

/// A passive semantic tree publication. Both identifiers are checked monotonic values and every
/// descriptor is capability-free, so inspection cannot become an accidental activation route.
public struct RPGPassiveSemanticSnapshot: Equatable {
    public let screenInstanceID: UInt64
    public let semanticRevision: UInt64
    public let model: RPGScreenModel

    public init?(screenInstanceID: UInt64, semanticRevision: UInt64, model: RPGScreenModel) {
        guard screenInstanceID > 0, semanticRevision > 0,
              model.descriptors.allSatisfy({ $0.actionCommand == nil }),
              model.visibleDescriptors.allSatisfy({ $0.actionCommand == nil }) else { return nil }
        self.screenInstanceID = screenInstanceID
        self.semanticRevision = semanticRevision
        self.model = model
    }
}

/// Atomically committed actionable model and the exact immutable semantic inputs used to build it.
/// Capture reads this value; dispatch independently revalidates against current GameCore state.
public struct RPGCommittedSemanticSnapshot: Equatable {
    public let screenInstanceID: UInt64
    public let semanticRevision: UInt64
    public let model: RPGScreenModel
    public let semanticInputs: [RPGUIElementID: RPGSemanticInputSnapshot]
    public let worldEntryGeneration: UInt64
    public let localPreferenceRevision: UInt64
    public let localPreferencePersistenceFailed: Bool
    public let highContrast: Bool
    public let reduceMotion: Bool

    public init?(screenInstanceID: UInt64, semanticRevision: UInt64,
                 model: RPGScreenModel, runtime: RPGScreenRuntimeSnapshot) {
        guard screenInstanceID > 0, semanticRevision > 0 else { return nil }
        var inputs: [RPGUIElementID: RPGSemanticInputSnapshot] = [:]
        for descriptor in model.descriptors {
            guard let command = descriptor.actionCommand else { continue }
            guard descriptor.isFocusable, descriptor.enabled,
                  inputs[descriptor.id] == nil,
                  let input = runtime.semanticInput(for: command) else { return nil }
            inputs[descriptor.id] = input
        }
        self.screenInstanceID = screenInstanceID
        self.semanticRevision = semanticRevision
        self.model = model
        self.semanticInputs = inputs
        self.worldEntryGeneration = runtime.worldEntryGeneration
        self.localPreferenceRevision = runtime.localPreferenceRevision
        self.localPreferencePersistenceFailed = runtime.localPreferencePersistenceFailed
        self.highContrast = runtime.highContrast
        self.reduceMotion = runtime.reduceMotion
    }
}

/// Checked process clock used by the app's semantic snapshot owner. Exhaustion fails closed and is
/// latched instead of wrapping an identifier back to zero or reusing an earlier screen identity.
public struct RPGPassiveSemanticClock: Equatable {
    public static let maximumScreenInstanceID = UInt64.max >> 1
    public private(set) var lastScreenInstanceID: UInt64
    public private(set) var screenInstanceIDExhausted: Bool

    public init(lastScreenInstanceID: UInt64 = 0, screenInstanceIDExhausted: Bool = false) {
        self.lastScreenInstanceID = lastScreenInstanceID
        self.screenInstanceIDExhausted = screenInstanceIDExhausted
    }

    public mutating func allocateScreenInstanceID() -> UInt64? {
        guard !screenInstanceIDExhausted,
              lastScreenInstanceID < Self.maximumScreenInstanceID,
              let next = lastScreenInstanceID.addingReportingOverflow(1).partialValue.nonzero else {
            screenInstanceIDExhausted = true
            return nil
        }
        lastScreenInstanceID = next
        return next
    }

    public func nextSemanticRevision(after current: UInt64?) -> UInt64? {
        let value = current ?? 0
        let result = value.addingReportingOverflow(1)
        guard !result.overflow, result.partialValue > 0 else { return nil }
        return result.partialValue
    }
}

private extension UInt64 {
    var nonzero: UInt64? { self == 0 ? nil : self }
}

private func purchaseFailureText(_ failure: RPGSkillPurchaseFailure?) -> String? {
    switch failure {
    case nil: return nil
    case .characterNotCreated: return "Create a character first"
    case .unknownOrCrossPathSkill: return "Skill is not on this path"
    case .authorityRevisionExhausted: return "Authority exhausted"
    case .alreadyAtMaximumRank: return "Maximum rank"
    case .insufficientLevel(let required): return "Requires level \(required)"
    case .insufficientAttribute(let id, let required): return "Requires \(shortAttribute(id)) \(required)"
    case .missingPrerequisite(let id):
        return "Requires \(rpgSkillDefinition(id)?.displayName ?? "Unavailable skill") rank 2"
    case .insufficientSkillPoints(let required, let available):
        return "Requires \(required) skill points; \(available) available"
    }
}

public func rpgNextFocusableID(in descriptors: [RPGSemanticDescriptor], current: RPGUIElementID?,
                               forward: Bool) -> RPGUIElementID? {
    let ids = descriptors.filter(\.isFocusable).map(\.id)
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else { return forward ? ids.first : ids.last }
    let next = forward ? (index + 1) % ids.count : (index + ids.count - 1) % ids.count
    return ids[next]
}

public func rpgRetainedFocusID(previousID: RPGUIElementID?, previousOrder: [RPGUIElementID],
                               newDescriptors: [RPGSemanticDescriptor]) -> RPGUIElementID? {
    let newIDs = newDescriptors.filter(\.isFocusable).map(\.id)
    guard !newIDs.isEmpty else { return nil }
    guard let previousID else { return newIDs.first }
    if newIDs.contains(previousID) { return previousID }
    guard let oldIndex = previousOrder.firstIndex(of: previousID) else { return newIDs.first }
    if oldIndex > 0 {
        for index in stride(from: oldIndex - 1, through: 0, by: -1) {
            let candidate = previousOrder[index]
            if newIDs.contains(candidate) { return candidate }
        }
    }
    return newIDs.first
}

public func rpgSpatialFocusableID(in descriptors: [RPGSemanticDescriptor],
                                  current: RPGUIElementID?, direction: RPGFocusDirection)
    -> RPGUIElementID? {
    let focusable = descriptors.filter(\.isFocusable)
    guard let current, let origin = focusable.first(where: { $0.id == current }) else {
        return focusable.first?.id
    }
    let originX = origin.frame.x + origin.frame.width / 2
    let originY = origin.frame.y + origin.frame.height / 2
    let candidates = focusable.enumerated().compactMap { index, candidate
        -> (RPGSemanticDescriptor, Double, Double, Int)? in
        guard candidate.id != current else { return nil }
        let x = candidate.frame.x + candidate.frame.width / 2
        let y = candidate.frame.y + candidate.frame.height / 2
        let dx = x - originX
        let dy = y - originY
        let primary: Double
        let secondary: Double
        switch direction {
        case .up: guard dy < 0 else { return nil }; primary = -dy; secondary = abs(dx)
        case .down: guard dy > 0 else { return nil }; primary = dy; secondary = abs(dx)
        case .left: guard dx < 0 else { return nil }; primary = -dx; secondary = abs(dy)
        case .right: guard dx > 0 else { return nil }; primary = dx; secondary = abs(dy)
        }
        return (candidate, primary, secondary, index)
    }
    return candidates.min {
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        if $0.2 != $1.2 { return $0.2 < $1.2 }
        return $0.3 < $1.3
    }?.0.id ?? current
}

public func rpgScreenFixture(pathID: String, branchID: String) -> RPGCharacterState? {
    guard let preset = rpgCreationPreset(pathID: pathID),
          let starter = validatedStarter(pathID: pathID, branchID: branchID),
          case .success(let state) = rpgCreateCharacter(RPGCreationDraft(
            pathID: pathID, attributes: preset, starterSkillID: starter, starterSpellIDs: [])) else { return nil }
    return state
}
