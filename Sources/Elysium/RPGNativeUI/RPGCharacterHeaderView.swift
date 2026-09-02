import SwiftUI
import ElysiumCore

struct RPGCharacterHeaderView: View {
    let model: RPGNativeViewModel

    private var progress: Double {
        guard let summary = model.summary,
              let next = summary.nextLevelXPThreshold else { return 1 }
        let floor = rpgXPRequiredForLevel(summary.level)
        guard next > floor else { return 0 }
        return min(1, max(0, Double(summary.absoluteXP - floor) / Double(next - floor)))
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: RPGNativeDesign.pathSymbol(model.state.pathID))
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.summary?.path ?? "Character") · \(model.summary?.subClass ?? "")")
                    .font(.title2)
                    .fontWeight(.semibold)
                HStack(spacing: 8) {
                    Text("Level \(model.summary?.level ?? 0)")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    if let next = model.summary?.nextLevelXPThreshold {
                        Text("\(model.summary?.absoluteXP ?? 0) / \(next) XP")
                    } else {
                        Text("Level cap")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .frame(maxWidth: 300)
                    .accessibilityLabel("Level progress")
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(model.summary?.availableSkillPoints ?? 0)")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Skill Points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
        .padding(RPGNativeDesign.contentPadding)
    }
}
