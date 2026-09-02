import SwiftUI
import ElysiumCore

struct RPGSkillsView: View {
    @Bindable var model: RPGNativeViewModel

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { model.rankPurchaseSkillID != nil },
            set: { if !$0 { model.cancelRankPurchase() } }
        )
    }

    private var pendingCard: RPGSkillCardProjection? {
        guard let skillID = model.rankPurchaseSkillID else { return nil }
        return model.projection?.skillCards.first { $0.skillID == skillID }
    }

    private func failureText(_ failure: RPGSkillPurchaseFailure?) -> String {
        switch failure {
        case nil: return "Ready to purchase"
        case .characterNotCreated: return "Create a character first"
        case .unknownOrCrossPathSkill: return "This skill is not on your path"
        case .authorityRevisionExhausted: return "Character authority is unavailable"
        case .alreadyAtMaximumRank: return "Maximum rank reached"
        case .insufficientLevel(let required): return "Requires level \(required)"
        case .insufficientSkillPoints(let required, let available):
            return "Requires \(required) SP; \(available) available"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Develop Your Path")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Your chosen sub-class costs 1 SP per rank. Skills from the other two sub-classes cost 2 SP per rank.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.summary?.availableSkillPoints ?? 0) SP available")
                    .font(.headline)
            }
            .padding(RPGNativeDesign.contentPadding)

            List {
                let groups = Dictionary(grouping: model.projection?.skillCards ?? [],
                                        by: \.subClassDisplayName)
                ForEach(model.projection?.branchIDs ?? [], id: \.self) { branchID in
                    if let branch = rpgBranchDefinition(branchID),
                       let cards = groups[branch.displayName] {
                        Section {
                            ForEach(cards, id: \.skillID) { card in
                                if let skill = rpgSkillDefinition(card.skillID) {
                                    HStack(alignment: .top, spacing: 14) {
                                        Image(systemName: skill.kind == .active
                                              ? "bolt.circle.fill" : "circle.hexagongrid.fill")
                                            .font(.title3)
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(skill.displayName)
                                                    .font(.headline)
                                                if skill.kind == .active {
                                                    Text("ACTIVE")
                                                        .font(.caption2)
                                                        .fontWeight(.semibold)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            HStack(spacing: 4) {
                                                ForEach(1...RPG_SKILL_RANK_CAP, id: \.self) { rank in
                                                    Image(systemName: rank <= card.currentRank
                                                          ? "circle.inset.filled" : "circle")
                                                        .foregroundStyle(rank <= card.currentRank
                                                                         ? AnyShapeStyle(.tint)
                                                                         : AnyShapeStyle(.tertiary))
                                                        .accessibilityHidden(true)
                                                }
                                                Text("Rank \(card.currentRank) of \(RPG_SKILL_RANK_CAP)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let benefit = card.currentBenefit {
                                                Text(benefit)
                                                    .font(.subheadline)
                                            } else {
                                                Text("Not learned")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let evaluation = card.nextEvaluation {
                                                let nextBenefit = evaluation.effectText ??
                                                    rpgSkillRankBenefit(card.skillID,
                                                                        rank: evaluation.targetRank) ?? ""
                                                Text("Next: \(nextBenefit)")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                Text(failureText(evaluation.failure))
                                                    .font(.caption)
                                                    .foregroundStyle(evaluation.permitted
                                                                     ? Color.secondary : Color.orange)
                                            }
                                        }
                                        Spacer(minLength: 10)
                                        if let evaluation = card.nextEvaluation {
                                            SwiftUI.Button("Rank Up") {
                                                model.requestRankPurchase(card.skillID)
                                            }
                                            .disabled(!model.canPerform(.rankUp(card.skillID)))
                                            .help(model.commandHelp(.rankUp(card.skillID)) ??
                                                  failureText(evaluation.failure))
                                        } else {
                                            Label("Mastered", systemImage: "checkmark.seal.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 7)
                                    .accessibilityElement(children: .contain)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(branch.displayName)
                                Text(branch.summary)
                                    .font(.caption)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .confirmationDialog("Spend Skill Points?",
                            isPresented: confirmationPresented,
                            titleVisibility: .visible) {
            if let card = pendingCard, let evaluation = card.nextEvaluation {
                SwiftUI.Button("Buy Rank \(evaluation.targetRank) for \(evaluation.cost ?? 0) SP") {
                    model.confirmRankPurchase()
                }
                SwiftUI.Button("Cancel", role: .cancel) {
                    model.cancelRankPurchase()
                }
            }
        } message: {
            if let card = pendingCard, let evaluation = card.nextEvaluation {
                let name = rpgSkillDefinition(card.skillID)?.displayName ?? "this skill"
                Text("\(name) Rank \(evaluation.targetRank) is permanent for this character. " +
                     (evaluation.specializationImpact.canStillCompleteSelectedSpecialization
                      ? "Your selected sub-class route remains completable by level 20."
                      : "This purchase leaves too few level-cap points to complete your selected sub-class route."))
            }
        }
    }
}
