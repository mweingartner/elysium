import SwiftUI

struct RPGOverviewView: View {
    let model: RPGNativeViewModel

    private func number(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.*f", digits, value)
    }

    var body: some View {
        Form {
            if let identity = model.pathIdentity {
                Section("Purpose") {
                    Text(identity.purpose)
                    LabeledContent("Core loop", value: identity.playLoop)
                }
            }

            if let summary = model.summary {
                Section("Growth") {
                    LabeledContent("Health", value: summary.healthLine)
                    LabeledContent("Fatigue", value: summary.fatigueLine)
                    LabeledContent("Current fatigue", value: number(summary.fatigue))
                    LabeledContent("Per level", value: summary.growthLine)
                }

                Section("Combat and Recovery") {
                    LabeledContent("Melee damage bonus",
                                   value: "+\(number(summary.derivedStats.meleeDamageBonus))")
                    LabeledContent("Bow inaccuracy reduction",
                                   value: "\(number(summary.derivedStats.actionAccuracyBonus * 100, digits: 1))%")
                    LabeledContent("Spell potency bonus",
                                   value: "+\(number(summary.derivedStats.spellPotencyBonus))")
                    LabeledContent("Fatigue regeneration",
                                   value: "\(number(summary.derivedStats.fatigueRegenPerTick * 20, digits: 2)) per second")
                    LabeledContent("Cooldown reduction",
                                   value: "\(number((1 - summary.derivedStats.actionRecoveryMultiplier) * 100, digits: 1))%")
                    LabeledContent("Focus fatigue reduction",
                                   value: "\(number((1 - summary.derivedStats.focusCostMultiplier) * 100, digits: 1))%")
                }

                Section("Equipment") {
                    LabeledContent("Equipped", value: summary.equipmentSummary)
                    LabeledContent("Spell focus", value: summary.focusSummary)
                }

                Section("Next Step") {
                    LabeledContent("Sub-class milestone", value: summary.nextActionableMilestone)
                    if let guidance = summary.levelOneGuidance {
                        Text(guidance)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
