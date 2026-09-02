import Foundation
import Observation
import ElysiumCore

@MainActor
@Observable
final class RPGNativeViewModel {
    @ObservationIgnored private weak var screen: RPGCharacterScreen?

    private(set) var committed: RPGCommittedSemanticSnapshot
    private(set) var runtime: RPGScreenRuntimeSnapshot
    private(set) var creation: RPGCreationSession
    private(set) var tab: RPGCharacterTab

    var pendingPathID: String
    var pendingBranchID: String?
    var selectedActiveSkillID: String?
    @ObservationIgnored private var selectedActiveSkillWasExplicit = false
    var loadoutSection: RPGNativeLoadoutSection
    var rankPurchaseSkillID: String?
    var showsDiscardConfirmation = false

    init(screen: RPGCharacterScreen,
         committed: RPGCommittedSemanticSnapshot,
         runtime: RPGScreenRuntimeSnapshot,
         creation: RPGCreationSession,
         tab: RPGCharacterTab) {
        self.screen = screen
        self.committed = committed
        self.runtime = runtime
        self.creation = creation
        self.tab = tab
        pendingPathID = creation.selectedPathID
        pendingBranchID = creation.selectedDraft?.branchID
        let activeIDs = committed.model.projection?.activeSkillIDs ?? []
        selectedActiveSkillID = rpgPreferredActiveSkillID(
            activeSkillIDs: activeIDs, state: runtime.state,
            current: nil, currentIsExplicit: false)
        loadoutSection = tab == .spells ? .spells : .actions
    }

    var model: RPGScreenModel { committed.model }
    var state: RPGCharacterState { runtime.state }
    var projection: RPGPathProjection? { model.projection }
    var summary: RPGCharacterSummaryProjection? { model.characterSummary }
    var progression: RPGProgressionSummaryProjection? { model.progressionSummary }
    var review: RPGCreationReviewProjection? { model.creationReview }
    var pathDefinition: RPGPathDefinition? { rpgPathDefinition(state.pathID) }
    var pathIdentity: RPGPathIdentity? {
        rpgPathIdentity(pathID: state.created ? state.pathID : creation.selectedPathID)
    }
    var authority: RPGAuthorityPhasePresentation { model.authority }
    var status: RPGStatusPresentation? { model.status }

    var characterSection: RPGNativeCharacterSection {
        switch tab {
        case .character: return .overview
        case .skills: return .skills
        case .actives, .spells: return .loadout
        case .progression: return .progress
        }
    }

    var chosenStartingSkillIDs: [String] {
        creation.selectedDraft?.startingSkillIDs ?? []
    }

    var hasCreationChanges: Bool {
        creation != rpgInitialCreationSession() ||
            pendingPathID != rpgInitialCreationSession().selectedPathID ||
            pendingBranchID != nil
    }

    var selectedActiveSkill: RPGSkillDefinition? {
        selectedActiveSkillID.flatMap(rpgSkillDefinition)
    }

    var selectedActionToken: String? { state.selectedPreparedActionID }
    var preparedActions: [RPGPreparedAction] { rpgPreparedActions(state) }
    var creationCommand: RPGSemanticCommand? {
        guard case .success(let draft) = rpgCreationDraft(from: creation) else { return nil }
        return .create(draft)
    }
    var canCreateCharacter: Bool {
        creationCommand.map(canPerform) == true
    }
    var createCharacterHelp: String {
        guard let creationCommand else { return model.errorText ?? "Resolve the creation requirements first." }
        return commandHelp(creationCommand) ?? "Create this character and save it to the world."
    }
    var tutorialPage: Int? {
        (1...RPG_TUTORIAL_PAGES.count).first { page in
            model.descriptors.contains {
                $0.id == .tutorial(page, pathID: state.pathID,
                                    branchID: state.specializationBranchID)
            }
        }
    }

    func refresh(committed: RPGCommittedSemanticSnapshot,
                 runtime: RPGScreenRuntimeSnapshot,
                 creation: RPGCreationSession,
                 tab: RPGCharacterTab) {
        let previousCreation = self.creation
        self.committed = committed
        self.runtime = runtime
        self.creation = creation
        self.tab = tab
        // A runtime rebuild can arrive while a decision card is selected but before Continue is
        // pressed. Preserve that UI-local choice while the user remains on the same step; only
        // reseed it when the authoritative creation flow actually enters that step.
        if creation.step == .path, previousCreation.step != .path {
            pendingPathID = creation.selectedPathID
        }
        if creation.step == .branch,
           previousCreation.step != .branch ||
            previousCreation.selectedPathID != creation.selectedPathID {
            pendingBranchID = creation.selectedDraft?.branchID
        }
        if tab == .spells { loadoutSection = .spells }
        if tab == .actives { loadoutSection = .actions }
        if let activeIDs = committed.model.projection?.activeSkillIDs {
            if selectedActiveSkillID.map({ !activeIDs.contains($0) }) ?? true {
                selectedActiveSkillWasExplicit = false
            }
            selectedActiveSkillID = rpgPreferredActiveSkillID(
                activeSkillIDs: activeIDs, state: runtime.state,
                current: selectedActiveSkillID,
                currentIsExplicit: selectedActiveSkillWasExplicit)
        }
    }

    func descriptor(for command: RPGSemanticCommand) -> RPGSemanticDescriptor? {
        model.descriptors.first { $0.actionCommand == command }
    }

    func canPerform(_ command: RPGSemanticCommand) -> Bool {
        descriptor(for: command)?.isActionable == true
    }

    func commandHelp(_ command: RPGSemanticCommand) -> String? {
        descriptor(for: command)?.help.nonEmpty
    }

    @discardableResult
    func perform(_ command: RPGSemanticCommand) -> Bool {
        guard let screen, let descriptor = descriptor(for: command), descriptor.isActionable else {
            return false
        }
        if case .dispatched = screen.activateNativeElement(descriptor.id) { return true }
        return false
    }

    func choosePendingPath() {
        _ = perform(.choosePath(pendingPathID))
    }

    func choosePendingBranch() {
        guard let pendingBranchID else { return }
        _ = perform(.chooseBranch(pendingBranchID))
    }

    func goBack() {
        _ = perform(.creationBack)
    }

    func continueFromSkills() {
        _ = perform(.creationNext)
    }

    func createCharacter() {
        guard case .success(let draft) = rpgCreationDraft(from: creation) else { return }
        _ = perform(.create(draft))
    }

    func requestClose() {
        if !state.created && hasCreationChanges {
            showsDiscardConfirmation = true
        } else {
            screen?.closeNativeWindow()
        }
    }

    func discardAndClose() {
        showsDiscardConfirmation = false
        if perform(.creationReject) { return }
        // Earlier creation steps intentionally have no Reject descriptor. Closing the ephemeral
        // screen after confirmation drops its draft without creating an alternate state mutation
        // path; review-stage Reject still travels through its committed semantic receipt above.
        screen?.closeNativeWindow()
    }

    func handleEscape() {
        if !state.created, creation.step != .path {
            goBack()
        } else {
            requestClose()
        }
    }

    func selectCharacterSection(_ section: RPGNativeCharacterSection) {
        let destination: RPGCharacterTab
        switch section {
        case .overview: destination = .character
        case .skills: destination = .skills
        case .loadout: destination = loadoutSection == .spells ? .spells : .actives
        case .progress: destination = .progression
        }
        guard destination != tab else { return }
        _ = perform(.selectTab(destination))
    }

    func selectLoadoutSection(_ section: RPGNativeLoadoutSection) {
        loadoutSection = section
        let destination: RPGCharacterTab = section == .spells ? .spells : .actives
        guard destination != tab else { return }
        _ = perform(.selectTab(destination))
    }

    func inspectActiveSkill(_ skillID: String) {
        selectedActiveSkillID = skillID
        selectedActiveSkillWasExplicit = true
        _ = screen?.focusNativeElement(.skill(skillID))
    }

    func requestRankPurchase(_ skillID: String) {
        rankPurchaseSkillID = skillID
    }

    func confirmRankPurchase() {
        guard let skillID = rankPurchaseSkillID else { return }
        rankPurchaseSkillID = nil
        _ = perform(.rankUp(skillID))
    }

    func cancelRankPurchase() {
        rankPurchaseSkillID = nil
    }

    func prepareToggle(skillID: String) {
        let command: RPGSemanticCommand = state.preparedSkillIDs.contains(skillID)
            ? .unprepareSkill(skillID) : .prepareSkill(skillID)
        _ = perform(command)
    }

    func prepareToggle(spellID: String) {
        let command: RPGSemanticCommand = state.preparedSpellIDs.contains(spellID)
            ? .unprepareSpell(spellID) : .prepareSpell(spellID)
        _ = perform(command)
    }

    func selectPrepared(skillID: String) { _ = perform(.selectSkill(skillID)) }
    func selectPrepared(spellID: String) { _ = perform(.selectSpell(spellID)) }
    func assign(token: String, slot: Int) { _ = perform(.assignSlot(token: token, slot: slot)) }
    func clear(slot: Int) { _ = perform(.clearSlot(slot)) }
    func moveSlot(from: Int, to: Int) { _ = perform(.moveSlot(from: from, to: to)) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
