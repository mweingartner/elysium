import SwiftUI
import ElysiumCore

struct RPGProgressView: View {
    let model: RPGNativeViewModel
    @State private var showsFullRoadmap = false

    var body: some View {
        List {
            if let identity = model.pathIdentity {
                Section("How \(model.summary?.path ?? "This Path") Earns XP") {
                    Text(identity.playLoop)
                        .foregroundStyle(.secondary)
                    ForEach(identity.progressionCriteria, id: \.eventKind) { criterion in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "target")
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(criterion.title)
                                    .font(.headline)
                                Text(criterion.criterion)
                                    .foregroundStyle(.secondary)
                                Text(criterion.reward)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                                Text(criterion.limit)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }

            if let progression = model.progression {
                Section("Sub-class Plan") {
                    LabeledContent("Selected sub-class",
                                   value: progression.plan.selectedBranchDisplayName)
                    LabeledContent("Route completion",
                                   value: "\(progression.specializationRemainingCost) SP remaining")
                    LabeledContent("Points earned by level 20",
                                   value: "\(progression.plan.levelCapEarnedSkillPoints) SP")
                    LabeledContent("Points left after this route",
                                   value: "\(progression.plan.utilityAllowance) SP")
                    Label(progression.plan.completionImpactText,
                          systemImage: progression.specializationCanComplete
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(progression.specializationCanComplete
                                         ? Color.green : Color.orange)
                    Text(progression.plan.crossBranchCapstoneText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Next Purchase") {
                    LabeledContent("Banked skill points", value: "\(progression.bankedSkillPoints)")
                    LabeledContent("Next legal rank",
                                   value: progression.nextLegalPurchase ?? "No legal purchase now")
                    if let warning = progression.divergenceWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Current Progress") {
                    if let current = progression.levels.first(where: { $0.level == model.state.level }) {
                        LabeledContent("Current level",
                                       value: "Level \(current.level) · \(current.earnedSkillPoints) SP earned")
                    }
                    if let next = progression.levels.first(where: { $0.level == model.state.level + 1 }) {
                        LabeledContent("Next level",
                                       value: "Level \(next.level) at \(next.absoluteXPThreshold) XP")
                        if !next.roadmapMilestones.isEmpty {
                            ForEach(Array(next.roadmapMilestones.enumerated()), id: \.offset) { _, milestone in
                                let name = rpgSkillDefinition(milestone.skillID)?.displayName ?? "Unavailable skill"
                                Label("Next route milestone: \(name) Rank \(milestone.rank) · \(milestone.cost) SP",
                                      systemImage: "arrow.right.circle")
                            }
                        }
                    } else {
                        Label("Level cap reached", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section("Level Roadmap") {
                    DisclosureGroup("Show all 20 levels", isExpanded: $showsFullRoadmap) {
                        ForEach(progression.levels, id: \.level) { level in
                            let reached = level.level <= model.state.level
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(reached ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text("Level \(level.level)")
                                            .font(.headline)
                                        Text("\(level.absoluteXPThreshold) XP")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(level.earnedSkillPoints) SP earned")
                                            .font(.subheadline)
                                        Text(reached ? "Reached" : "Planned")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(reached ? Color.green : Color.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(.regularMaterial, in: Capsule())
                                            .accessibilityLabel("Level status")
                                            .accessibilityValue(reached ? "Reached" : "Not reached")
                                    }
                                    if level.milestoneBonusPoint {
                                        Label("Milestone bonus point", systemImage: "star.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    ForEach(Array(level.roadmapMilestones.enumerated()),
                                            id: \.offset) { _, milestone in
                                        let name = rpgSkillDefinition(milestone.skillID)?.displayName ?? "Unavailable skill"
                                        let complete = level.completedMilestones.contains(milestone)
                                        HStack {
                                            Label("\(name) Rank \(milestone.rank) · \(milestone.cost) SP",
                                                  systemImage: complete ? "checkmark" : "arrow.right")
                                            Spacer()
                                            Text(complete ? "Completed" : "Planned")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                        }
                                        .font(.subheadline)
                                        .foregroundStyle(complete ? Color.green : Color.secondary)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(name) Rank \(milestone.rank), \(milestone.cost) skill points")
                                        .accessibilityValue(complete ? "Completed" : "Not completed")
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
