// SkillsWindowView — the native Skills workspace, built from Atrium's components.
//
// Layout: a sidebar with the four skill trees and the action fast bar, and a detail page for the
// selected tree (next rank, primary and advanced ranks, item mastery, how XP is earned). The view
// renders a `SkillsPresentation` value only; it cannot use an action or change progress.

import SwiftUI
import Atrium
import ElysiumCore

@MainActor
@Observable
final class SkillsWindowModel {
    var presentation: SkillsPresentation?
    var selection: SkillTreeID?
    @ObservationIgnored let requestClose: () -> Void

    init(presentation: SkillsPresentation?, selection: SkillTreeID, requestClose: @escaping () -> Void) {
        self.presentation = presentation
        self.selection = selection
        self.requestClose = requestClose
    }

    var selectedTree: SkillsTreePresentation? {
        guard let presentation else { return nil }
        return selection.flatMap(presentation.tree) ?? presentation.trees.first
    }
}

struct SkillsWindowView: View {
    @Bindable var model: SkillsWindowModel

    var body: some View {
        NavigationSplitView {
            SkillsSidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: Metrics.sidebar.min, ideal: Metrics.sidebar.ideal, max: Metrics.sidebar.max)
        } detail: {
            if let presentation = model.presentation, let tree = model.selectedTree {
                SkillsTreeDetail(tree: tree, isLANGuest: presentation.isLANGuest)
            } else {
                EmptyState("Skills appear once the world loads",
                           message: "Your four skill trees show here as soon as the world finishes loading.",
                           systemImage: "clock")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SwiftUI.Button("Done") { model.requestClose() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Skills and return to the game")
            }
        }
    }
}

private struct SkillsSidebar: View {
    @Bindable var model: SkillsWindowModel

    var body: some View {
        List(selection: $model.selection) {
            if let trees = model.presentation?.trees, !trees.isEmpty {
                Section("Skill trees") {
                    ForEach(trees) { tree in
                        Label {
                            VStack(alignment: .leading, spacing: Spacing.hair) {
                                Text(tree.name).font(Typography.body)
                                Text(tree.statusText)
                                    .font(Typography.meta)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: tree.symbol)
                        }
                        .badge(Text("\(tree.earnedRankCount)/10").monospacedDigit())
                        .frame(minHeight: Metrics.doubleRow)
                        .tag(tree.id)
                        .accessibilityLabel("\(tree.name), \(tree.statusText), \(tree.earnedRankCount) of 10 ranks")
                    }
                }
            }
            if let fastBar = model.presentation?.fastBar, !fastBar.isEmpty {
                Section("Action fast bar") {
                    ForEach(fastBar) { entry in
                        HStack(spacing: Spacing.snug) {
                            SkillsKeycap(slot: entry.slot)
                            Text(entry.name).font(Typography.body)
                        }
                        .selectionDisabled()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SkillsTreeDetail: View {
    let tree: SkillsTreePresentation
    let isLANGuest: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(tree.name, subtitle: tree.summary) {
                    Text("\(tree.xp.formatted()) XP")
                        .font(Typography.numeric)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(tree.xp) total XP")
                }
                if isLANGuest {
                    Label("This world’s host keeps your skill progress and checks every action you use.",
                          systemImage: "info.circle")
                        .font(Typography.supporting)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Spacing.group)
                }
                SkillsNextRank(tree: tree)
                    .padding(.bottom, Spacing.section)

                SkillsRankSection(title: "Primary ranks", track: tree.primaryTrackName,
                                  lockNote: nil, ranks: tree.primaryRanks)
                SkillsRankSection(title: "Advanced ranks", track: tree.advancedTrackName,
                                  lockNote: tree.advancedLockNote, ranks: tree.advancedRanks)
                if let items = tree.itemMastery {
                    SkillsItemMasterySection(items: items)
                }
                SkillsEarningSection(rows: tree.earning, note: tree.earningNote)
            }
            .atriumPageMargins()
        }
        .navigationTitle("Skills")
    }
}

private struct SkillsNextRank: View {
    let tree: SkillsTreePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if let next = tree.nextRank {
                HStack(alignment: .firstTextBaseline) {
                    Text("Next rank")
                        .font(Typography.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.snug)
                    Text("\(next.remainingXP.formatted()) XP to go")
                        .font(Typography.heading)
                        .monospacedDigit()
                }
                Text(next.title).font(Typography.heading)
                ProgressView(value: next.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Progress to the next rank")
                    .accessibilityValue("\(next.currentXP) of \(next.targetXP) XP")
                HStack(alignment: .firstTextBaseline) {
                    Text("\(next.currentXP.formatted()) of \(next.targetXP.formatted()) XP")
                    Spacer(minLength: Spacing.snug)
                    if let hint = next.hint { Text(hint) }
                }
                .font(Typography.meta)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                StatusBadge("Tree mastered", kind: .positive)
                Text("All ten ranks are earned.")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atriumSurface()
    }
}

private struct SkillsRankSection: View {
    let title: String
    let track: String
    let lockNote: String?
    let ranks: [SkillsRankPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title) { Text(track) }
            if let lockNote {
                Label(lockNote, systemImage: "lock")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Spacing.snug)
            }
            ForEach(Array(ranks.enumerated()), id: \.element.id) { index, rank in
                if index > 0 { Hairline() }
                SkillsRankRow(rank: rank)
            }
        }
        .padding(.bottom, Spacing.section)
    }
}

private struct SkillsRankRow: View {
    let rank: SkillsRankPresentation

    var body: some View {
        Row(rank.title, subtitle: rank.detail,
            systemImage: rank.status == .earned ? "\(rank.number).circle.fill" : "\(rank.number).circle") {
            HStack(spacing: Spacing.control) {
                if let slot = rank.fastBarSlot { SkillsKeycap(slot: slot) }
                Text("\(rank.thresholdXP.formatted()) XP")
                    .font(Typography.meta)
                    .monospacedDigit()
                // The widest badge, hidden, sizes the slot so the XP column stays aligned.
                ZStack(alignment: .leading) {
                    StatusBadge("Earned", kind: .positive).hidden()
                    switch rank.status {
                    case .earned: StatusBadge("Earned", kind: .positive)
                    case .next: StatusBadge("Next", kind: .info)
                    case .locked: StatusBadge("Locked", kind: .neutral)
                    }
                }
            }
        }
    }
}

private struct SkillsItemMasterySection: View {
    let items: [SkillsItemMasteryRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Item mastery") {
                Text("\(items.filter(\.isMastered).count) of \(items.count) mastered")
            }
            if items.isEmpty {
                Text("Craft an item to start tracking its mastery.")
                    .font(Typography.supporting)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline() }
                Row(item.name) {
                    HStack(spacing: Spacing.control) {
                        Text("\(item.crafts) / \(SKILL_TREE_RECIPE_MASTERY_CAP)")
                            .font(Typography.meta)
                            .monospacedDigit()
                        if item.isMastered {
                            StatusBadge("Mastered", kind: .positive)
                        } else {
                            Text("\(SKILL_TREE_RECIPE_MASTERY_CAP - item.crafts) to go")
                                .font(Typography.meta)
                        }
                    }
                }
            }
        }
        .padding(.bottom, Spacing.section)
    }
}

private struct SkillsEarningSection: View {
    let rows: [SkillsEarningRow]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Earning XP")
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Hairline() }
                ValueRow(row.label, value: row.value)
                    .padding(.vertical, Spacing.tight)
            }
            Text(note)
                .font(Typography.supporting)
                .foregroundStyle(.secondary)
                .padding(.top, Spacing.snug)
                .atriumReadableWidth()
        }
    }
}

/// A fast-bar key such as ⇧1, drawn like a keycap.
private struct SkillsKeycap: View {
    let slot: Int

    var body: some View {
        Text("⇧\(slot)")
            .font(Typography.label)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.tight)
            .frame(minWidth: Metrics.minimumControl)
            .padding(.vertical, Spacing.hair)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.badge)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            }
            .accessibilityLabel("Fast bar slot Shift \(slot)")
    }
}
