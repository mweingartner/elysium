import SwiftUI
import ElysiumCore

struct RPGCreationReviewView: View {
    @Bindable var model: RPGNativeViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    LabeledContent("Path", value: model.review?.path ?? "Unavailable")
                    LabeledContent("Sub-class", value: model.review?.subClass ?? "Unavailable")
                    LabeledContent("Growth", value: model.review?.growthLine ?? "Unavailable")
                    Label("Your path, sub-class, and starting skills are permanent for this character in this world.",
                          systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }

                Section("Starting Skills") {
                    ForEach(model.review?.startingSkills ?? [], id: \.displayName) { skill in
                        LabeledContent(skill.displayName,
                                       value: "Rank \(skill.rank) of \(skill.maxRank)")
                    }
                    LabeledContent("Granted spells",
                                   value: model.review?.automaticSpells.isEmpty == false
                                   ? model.review?.automaticSpells.joined(separator: ", ") ?? "None"
                                   : "None")
                    Text(model.review?.focusRequirement ?? "")
                        .foregroundStyle(.secondary)
                }

                Section("Starter Kit") {
                    ForEach(Array((model.review?.starterKitItems ?? []).enumerated()),
                            id: \.offset) { _, item in
                        LabeledContent(item.displayName,
                                       value: "\(item.count)" +
                                       (item.displayNameDetail.map { " · \($0)" } ?? ""))
                    }
                    Text(model.review?.inventoryCapacityCaveat ?? "")
                        .foregroundStyle(.secondary)
                }

                Section("First-Level Plan") {
                    Text(model.review?.levelOneGuidance ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let identity = model.pathIdentity {
                    Section("Exact Class XP Rules") {
                        ForEach(identity.progressionCriteria, id: \.eventKind) { criterion in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(criterion.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(criterion.reward)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                                Text(criterion.criterion)
                                Text(criterion.limit)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section("Controls") {
                    ForEach(model.review?.configuredChordProjections ?? [],
                            id: \.actionDisplayName) { chord in
                        LabeledContent(chord.actionDisplayName, value: chord.chord)
                    }
                    Text(model.review?.controllerScope ?? "")
                        .foregroundStyle(.secondary)
                }

                Section("Save") {
                    Label(model.review?.authorityCaveat ?? model.authority.visibleHelp,
                          systemImage: model.authority.disabledControlExplanation == nil
                          ? "checkmark.icloud" : "exclamationmark.icloud")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                SwiftUI.Button("Discard Draft", role: .destructive) {
                    model.showsDiscardConfirmation = true
                }
                SwiftUI.Button("Back") { model.goBack() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                SwiftUI.Button("Create Character") { model.createCharacter() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreateCharacter)
                    .help(model.createCharacterHelp)
            }
            .padding(RPGNativeDesign.contentPadding)
        }
    }
}
