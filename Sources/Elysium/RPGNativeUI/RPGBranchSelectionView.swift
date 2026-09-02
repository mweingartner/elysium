import SwiftUI
import ElysiumCore

struct RPGBranchSelectionView: View {
    @Bindable var model: RPGNativeViewModel

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: RPGNativeDesign.cardSpacing)]

    private var path: RPGPathDefinition? {
        rpgPathDefinition(model.creation.selectedPathID)
    }

    private func signatureSpellUnlockText(for branch: RPGBranchDefinition) -> String? {
        guard let signatureID = branch.skillIDs.first,
              let signature = rpgSkillDefinition(signatureID) else { return nil }
        let unlocks = signature.spellUnlocks.compactMap { unlock -> String? in
            guard let spell = rpgSpellDefinition(unlock.spellID) else { return nil }
            return "\(spell.displayName) at Rank \(unlock.rank)"
        }
        guard !unlocks.isEmpty else { return nil }
        return "Signature unlock: \(unlocks.joined(separator: ", "))"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RPGNativeDesign.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Choose a Sub-class")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text("Specialize your \(path?.displayName ?? "path"). Each sub-class has a focused job and its own three-skill progression route.")
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, alignment: .leading,
                              spacing: RPGNativeDesign.cardSpacing) {
                        ForEach(path?.branchIDs ?? [], id: \.self) { branchID in
                            if let branch = rpgBranchDefinition(branchID) {
                                let selected = model.pendingBranchID == branch.id
                                let signatureUnlock = signatureSpellUnlockText(for: branch)
                                SwiftUI.Button {
                                    model.pendingBranchID = branch.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 11) {
                                        HStack {
                                            Image(systemName: "arrow.triangle.branch")
                                                .foregroundStyle(.tint)
                                            Text(branch.displayName)
                                                .font(.title2)
                                                .fontWeight(.semibold)
                                            Spacer()
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                                .accessibilityHidden(true)
                                        }
                                        Text(branch.summary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Divider()
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Skill route")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.secondary)
                                            ForEach(branch.skillIDs, id: \.self) { skillID in
                                                if let skill = rpgSkillDefinition(skillID) {
                                                    Label(skill.displayName,
                                                          systemImage: skill.kind == .active
                                                          ? "bolt.circle" : "circle.dotted")
                                                        .font(.subheadline)
                                                }
                                            }
                                            if let signatureUnlock {
                                                Label(signatureUnlock, systemImage: "wand.and.stars")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
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
                                .accessibilityLabel("\(branch.displayName), \(selected ? "selected" : "not selected")")
                                .accessibilityValue("\(branch.summary) Skill route: " +
                                    branch.skillIDs.compactMap {
                                        rpgSkillDefinition($0)?.displayName
                                    }.joined(separator: ", ") +
                                    (signatureUnlock.map { ". \($0)." } ?? ""))
                                .accessibilityHint("Select this sub-class.")
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
                SwiftUI.Button("Continue") { model.choosePendingBranch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pendingBranchID == nil)
                    .help("Continue to starting skills")
            }
            .padding(RPGNativeDesign.contentPadding)
        }
    }
}
