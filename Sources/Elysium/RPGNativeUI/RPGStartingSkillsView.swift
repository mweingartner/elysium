import SwiftUI
import ElysiumCore

struct RPGStartingSkillsView: View {
    @Bindable var model: RPGNativeViewModel

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: RPGNativeDesign.cardSpacing)]

    private var branch: RPGBranchDefinition? {
        model.creation.selectedDraft?.branchID.flatMap(rpgBranchDefinition)
    }

    private var pool: [String] {
        guard let branch else { return [] }
        return rpgStartingSkillPool(pathID: model.creation.selectedPathID,
                                    branchID: branch.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RPGNativeDesign.sectionSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Choose Starting Skills")
                                .font(.largeTitle)
                                .fontWeight(.semibold)
                            Text("Choose exactly three. One signature skill from each \(model.creation.selectedPathID.capitalized) sub-class is preselected. Customize those selections using any skill from your selected sub-class and the signature skill from each sibling sub-class.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(model.chosenStartingSkillIDs.count) of \(RPG_STARTING_SKILL_COUNT)")
                            .font(.headline)
                            .foregroundStyle(model.chosenStartingSkillIDs.count == RPG_STARTING_SKILL_COUNT
                                             ? Color.green : Color.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    if model.chosenStartingSkillIDs.count == RPG_STARTING_SKILL_COUNT {
                        Label("3 of 3 chosen. Unchoose a skill before selecting a different one.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, alignment: .leading,
                              spacing: RPGNativeDesign.cardSpacing) {
                        ForEach(pool, id: \.self) { skillID in
                            if let skill = rpgSkillDefinition(skillID) {
                                let selected = model.chosenStartingSkillIDs.contains(skillID)
                                let atLimit = model.chosenStartingSkillIDs.count >= RPG_STARTING_SKILL_COUNT
                                let branchName = rpgBranchDefinition(skill.branchID)?.displayName ?? "Sub-class"
                                let rankBenefit = rpgSkillRankBenefit(skillID, rank: 1) ??
                                    "Rank 1 benefit unavailable"
                                let spells = skill.spellUnlocks.filter { $0.rank == 1 }
                                    .compactMap { rpgSpellDefinition($0.spellID)?.displayName }
                                SwiftUI.Button {
                                    _ = model.perform(.toggleStartingSkill(skillID))
                                } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        HStack {
                                            Image(systemName: skill.kind == .active ? "bolt.circle" : "circle.dotted")
                                                .foregroundStyle(.tint)
                                            Text(skill.displayName)
                                                .font(.headline)
                                            Spacer()
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                                .accessibilityHidden(true)
                                        }
                                        Text(branchName)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                        Text(rankBenefit)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Label(spells.isEmpty ? "No Rank 1 spell" : "Unlocks \(spells.joined(separator: ", "))",
                                              systemImage: spells.isEmpty ? "wand.and.stars.inverse" : "wand.and.stars")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
                                    .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: RPGNativeDesign.cardRadius)
                                            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22),
                                                    lineWidth: selected ? 2 : 1)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: RPGNativeDesign.cardRadius))
                                    .contentShape(RoundedRectangle(cornerRadius: RPGNativeDesign.cardRadius))
                                }
                                .buttonStyle(.plain)
                                .disabled(atLimit && !selected)
                                .accessibilityLabel("\(skill.displayName), \(selected ? "selected" : "not selected")")
                                .accessibilityValue("\(branchName). \(rankBenefit). " +
                                    (spells.isEmpty
                                     ? "No spell unlock at Rank 1."
                                     : "Unlocks \(spells.joined(separator: ", "))."))
                                .accessibilityHint(atLimit && !selected
                                                   ? "Unchoose a skill before selecting this one"
                                                   : "Toggle this starting skill")
                            }
                        }
                    }
                }
                .padding(RPGNativeDesign.contentPadding)
            }

            Divider()
            HStack {
                SwiftUI.Button("Back") { model.goBack() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                SwiftUI.Button("Continue") { model.continueFromSkills() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosenStartingSkillIDs.count != RPG_STARTING_SKILL_COUNT ||
                              !model.canPerform(.creationNext))
                    .help("Review your character")
            }
            .padding(RPGNativeDesign.contentPadding)
        }
    }
}
