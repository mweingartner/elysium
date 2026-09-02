import SwiftUI
import ElysiumCore

struct RPGLoadoutView: View {
    @Bindable var model: RPGNativeViewModel

    private var loadoutSelection: Binding<RPGNativeLoadoutSection> {
        Binding(
            get: { model.loadoutSection },
            set: { model.selectLoadoutSection($0) }
        )
    }

    private var activeSelection: Binding<String?> {
        Binding(
            get: { model.selectedActiveSkillID },
            set: { if let skillID = $0 { model.inspectActiveSkill(skillID) } }
        )
    }

    private func actionStatus(_ skillID: String) -> String {
        guard (model.state.skillRanks[skillID] ?? 0) > 0 else { return "Locked" }
        guard model.state.preparedSkillIDs.contains(skillID) else { return "Learned" }
        let token = rpgPreparedActionToken(kind: .skill, id: skillID)
        let preparation = model.selectedActionToken == token ? "Selected" : "Prepared"
        let quote = rpgActionResourceQuote(kind: .skill, id: skillID, state: model.state)
        return "\(preparation) · \(resourceAvailability(quote, prepared: true))"
    }

    private func spellStatus(_ spellID: String) -> String {
        guard model.state.knownSpellIDs.contains(spellID) else { return "Locked" }
        guard model.state.preparedSpellIDs.contains(spellID) else { return "Known" }
        let token = rpgPreparedActionToken(kind: .spell, id: spellID)
        let preparation = model.selectedActionToken == token ? "Selected" : "Prepared"
        let quote = rpgActionResourceQuote(kind: .spell, id: spellID, state: model.state)
        return "\(preparation) · \(resourceAvailability(quote, prepared: true))"
    }

    private func resourceAvailability(_ quote: RPGActionResourceQuote?, prepared: Bool) -> String {
        guard prepared else { return "Not prepared" }
        guard let quote else { return "Unavailable" }
        if quote.cooldownRemainingTicks > 0 {
            let seconds = Double(quote.cooldownRemainingTicks) / 20
            return "Cooldown · \(String(format: "%.1f", seconds)) seconds remaining"
        }
        if quote.resourceAvailable { return "Resources ready" }
        return "Needs \(String(format: "%.2f", quote.fatigueCost)) fatigue · " +
            "\(String(format: "%.2f", model.state.fatigue)) available"
    }

    private func spellUnlockRequirement(_ spellID: String) -> String {
        rpgSpellUnlockProjections(pathID: model.state.pathID)
            .first(where: { $0.spellID == spellID })?
            .unlockRequirementText ?? "No unlock route is available for this path."
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Loadout", selection: loadoutSelection) {
                ForEach(RPGNativeLoadoutSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .padding(.vertical, 12)

            Divider()
            if model.loadoutSection == .actions {
                HSplitView {
                    List(selection: activeSelection) {
                        Section("Path Actions") {
                            ForEach(model.projection?.activeSkillIDs ?? [], id: \.self) { skillID in
                                if let skill = rpgSkillDefinition(skillID) {
                                    HStack {
                                        Image(systemName: "bolt.circle")
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.displayName)
                                            Text(actionStatus(skillID))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(skillID)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 220, idealWidth: 255, maxWidth: 310)

                    Form {
                        if let skill = model.selectedActiveSkill {
                            let rank = model.state.skillRanks[skill.id] ?? 0
                            let prepared = model.state.preparedSkillIDs.contains(skill.id)
                            let token = rpgPreparedActionToken(kind: .skill, id: skill.id)
                            let quote = rpgActionResourceQuote(kind: .skill,
                                                               id: skill.id,
                                                               state: model.state)

                            Section("\(skill.displayName) · Rank \(rank)") {
                                if rank > 0 {
                                    Text(rpgSkillRankBenefit(skill.id, rank: rank) ?? skill.summary)
                                    LabeledContent("Effective fatigue",
                                                   value: String(format: "%.2f", quote?.fatigueCost ?? 0))
                                    LabeledContent("Effective cooldown",
                                                   value: "\(String(format: "%.1f", Double(quote?.cooldownTicks ?? 0) / 20)) seconds")
                                    if prepared {
                                        LabeledContent("Fatigue and cooldown",
                                                       value: resourceAvailability(quote, prepared: true))
                                    }
                                } else {
                                    Label("Learn this skill on the Skills screen before preparing it.",
                                          systemImage: "lock.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Section("Preparation") {
                                HStack {
                                    SwiftUI.Button(prepared ? "Unprepare" : "Prepare") {
                                        model.prepareToggle(skillID: skill.id)
                                    }
                                    .disabled(!model.canPerform(prepared
                                                                ? .unprepareSkill(skill.id)
                                                                : .prepareSkill(skill.id)))
                                    .accessibilityLabel("\(prepared ? "Unprepare" : "Prepare") \(skill.displayName)")
                                    .help(model.commandHelp(prepared
                                                            ? .unprepareSkill(skill.id)
                                                            : .prepareSkill(skill.id)) ?? "")
                                    if prepared {
                                        SwiftUI.Button(model.selectedActionToken == token
                                                       ? "Selected" : "Select for Use") {
                                            model.selectPrepared(skillID: skill.id)
                                        }
                                        .disabled(model.selectedActionToken == token ||
                                                  !model.canPerform(.selectSkill(skill.id)))
                                        .accessibilityLabel(model.selectedActionToken == token
                                                            ? "\(skill.displayName), selected for use"
                                                            : "Select \(skill.displayName) for use")
                                    }
                                    Spacer()
                                    Text("\(model.state.preparedSkillIDs.count) of \(RPG_MAX_PREPARED_SKILLS) active skills prepared")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if prepared {
                                Section("Assign to Quick Slot") {
                                    HStack(spacing: 7) {
                                        ForEach(0..<RPG_ACTION_QUICK_SLOT_COUNT, id: \.self) { slot in
                                            let assigned = model.runtime.quickSlots.tokens[slot] == token
                                            SwiftUI.Button {
                                                model.assign(token: token, slot: slot)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text("\(slot + 1)")
                                                    if assigned {
                                                        Image(systemName: "checkmark")
                                                            .accessibilityHidden(true)
                                                    }
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(assigned ? .accentColor : nil)
                                            .disabled(!model.canPerform(.assignSlot(token: token,
                                                                                   slot: slot)))
                                            .accessibilityLabel("Assign \(skill.displayName) to quick slot \(slot + 1)")
                                            .accessibilityValue(assigned ? "Assigned" : "Not assigned")
                                        }
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView("No Active Skills",
                                                   systemImage: "bolt.slash",
                                                   description: Text("This path has no active skills."))
                        }

                        Section("Quick Slots") {
                            ForEach(0..<RPG_ACTION_QUICK_SLOT_COUNT, id: \.self) { slot in
                                let token = model.runtime.quickSlots.tokens[slot]
                                HStack {
                                    Text("\(slot + 1)")
                                        .font(.headline.monospacedDigit())
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rpgPreparedActionDisplayName(token))
                                        if let token,
                                           let prepared = model.preparedActions.first(where: { $0.token == token }) {
                                            Text(prepared.statusText)
                                                .font(.caption)
                                                .foregroundStyle(prepared.available ? Color.green : Color.orange)
                                        }
                                    }
                                    Spacer()
                                    if token != nil {
                                        SwiftUI.Button {
                                            model.moveSlot(from: slot, to: slot - 1)
                                        } label: {
                                            Label("Move Left", systemImage: "arrow.left")
                                        }
                                        .labelStyle(.iconOnly)
                                        .disabled(slot == 0 ||
                                                  !model.canPerform(.moveSlot(from: slot, to: slot - 1)))
                                        .accessibilityLabel("Move quick slot \(slot + 1) left")
                                        .help("Move Quick Slot \(slot + 1) left")

                                        SwiftUI.Button {
                                            model.moveSlot(from: slot, to: slot + 1)
                                        } label: {
                                            Label("Move Right", systemImage: "arrow.right")
                                        }
                                        .labelStyle(.iconOnly)
                                        .disabled(slot + 1 >= RPG_ACTION_QUICK_SLOT_COUNT ||
                                                  !model.canPerform(.moveSlot(from: slot, to: slot + 1)))
                                        .accessibilityLabel("Move quick slot \(slot + 1) right")
                                        .help("Move Quick Slot \(slot + 1) right")

                                        SwiftUI.Button(role: .destructive) {
                                            model.clear(slot: slot)
                                        } label: {
                                            Label("Clear Slot", systemImage: "xmark.circle")
                                        }
                                        .labelStyle(.iconOnly)
                                        .disabled(!model.canPerform(.clearSlot(slot)))
                                        .accessibilityLabel("Clear quick slot \(slot + 1)")
                                        .help("Clear Quick Slot \(slot + 1)")
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .frame(minWidth: 500)
                }
            } else {
                Form {
                    Section {
                        LabeledContent("Prepared",
                                       value: "\(model.state.preparedSpellIDs.count) of \(RPG_MAX_PREPARED_SPELLS)")
                        Text("Known spells are unlocked by skill ranks. Preparing a spell adds it to your action cycle; assigning it to a quick slot gives it a direct shortcut.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.projection?.reachableSpellIDs ?? [], id: \.self) { spellID in
                        if let spell = rpgSpellDefinition(spellID) {
                            let known = model.state.knownSpellIDs.contains(spellID)
                            let prepared = model.state.preparedSpellIDs.contains(spellID)
                            let token = rpgPreparedActionToken(kind: .spell, id: spellID)
                            let quote = rpgActionResourceQuote(kind: .spell,
                                                               id: spellID,
                                                               state: model.state)
                            Section {
                                Text(spell.summary)
                                if !known {
                                    LabeledContent("Unlock requirement",
                                                   value: spellUnlockRequirement(spellID))
                                }
                                HStack {
                                    LabeledContent("Circle", value: "\(spell.circle)")
                                    LabeledContent("Effective fatigue",
                                                   value: String(format: "%.2f", quote?.fatigueCost ?? 0))
                                    LabeledContent("Effective cooldown",
                                                   value: "\(String(format: "%.1f", Double(quote?.cooldownTicks ?? 0) / 20))s")
                                    LabeledContent("Status", value: spellStatus(spellID))
                                }
                                if prepared {
                                    LabeledContent("Fatigue and cooldown",
                                                   value: resourceAvailability(quote, prepared: true))
                                }
                                HStack {
                                    SwiftUI.Button(prepared ? "Unprepare" : "Prepare") {
                                        model.prepareToggle(spellID: spellID)
                                    }
                                    .disabled(!known || !model.canPerform(prepared
                                                                          ? .unprepareSpell(spellID)
                                                                          : .prepareSpell(spellID)))
                                    .accessibilityLabel("\(prepared ? "Unprepare" : "Prepare") \(spell.displayName)")
                                    if prepared {
                                        SwiftUI.Button(model.selectedActionToken == token
                                                       ? "Selected" : "Select for Use") {
                                            model.selectPrepared(spellID: spellID)
                                        }
                                        .disabled(model.selectedActionToken == token ||
                                                  !model.canPerform(.selectSpell(spellID)))
                                        .accessibilityLabel(model.selectedActionToken == token
                                                            ? "\(spell.displayName), selected for use"
                                                            : "Select \(spell.displayName) for use")
                                        Spacer()
                                        ForEach(0..<RPG_ACTION_QUICK_SLOT_COUNT, id: \.self) { slot in
                                            let assigned = model.runtime.quickSlots.tokens[slot] == token
                                            SwiftUI.Button {
                                                model.assign(token: token, slot: slot)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text("\(slot + 1)")
                                                    if assigned {
                                                        Image(systemName: "checkmark")
                                                            .accessibilityHidden(true)
                                                    }
                                                }
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(assigned ? .accentColor : nil)
                                            .disabled(!model.canPerform(.assignSlot(token: token,
                                                                                   slot: slot)))
                                            .accessibilityLabel("Assign \(spell.displayName) to quick slot \(slot + 1)")
                                            .accessibilityValue(assigned ? "Assigned" : "Not assigned")
                                        }
                                    }
                                }
                            } header: {
                                Label(spell.displayName,
                                      systemImage: known ? "wand.and.stars" : "lock.fill")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}
