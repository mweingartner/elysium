// ScriptListSidebar.swift — native SwiftUI script editor (Stage A). Lists every script attached
// to the current target (`model.scripts`) so the user can switch between them without leaving the
// window — the architecture doc's "a separate section listing all scripts on the current object
// to switch between", distinct from the command palette below it.

import SwiftUI
import ElysiumCore

struct ScriptListSidebar: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    @State private var pendingDelete: String? = nil
    @State private var pendingSwitchName: String? = nil
    @State private var pendingNewScript = false
    @State private var showingUnsavedChanges = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scripts on \(model.targetDisplayName)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                SwiftUI.Button("New script", systemImage: "plus.circle", action: requestNewScript)
                    .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("New script")
                .accessibilityLabel("New script")
            }
            .padding(.horizontal, theme.spacing)
            .padding(.vertical, 6)

            if model.scripts.isEmpty {
                Text("No scripts yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, theme.spacing)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.scripts, id: \.name) { record in
                            row(for: record)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Divider()
        }
        .alert(
            "Delete \"\(pendingDelete ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            SwiftUI.Button("Cancel", role: .cancel) { pendingDelete = nil }
            SwiftUI.Button("Delete", role: .destructive) {
                if let name = pendingDelete { model.deleteScript(name) }
                pendingDelete = nil
            }
        } message: {
            if pendingDelete == model.currentName, model.isDirty {
                Text("This removes the script from \(model.targetDisplayName) and discards the unsaved editor draft.")
            } else {
                Text("This removes the script from \(model.targetDisplayName).")
            }
        }
        .confirmationDialog(
            "Save changes to \(model.currentName.isEmpty ? "this new script" : model.currentName)?",
            isPresented: $showingUnsavedChanges,
            titleVisibility: .visible
        ) {
            SwiftUI.Button("Save and Continue") {
                if model.save() { continuePendingNavigation() }
            }
            SwiftUI.Button("Discard Changes", role: .destructive, action: continuePendingNavigation)
            SwiftUI.Button("Cancel", role: .cancel, action: clearPendingNavigation)
        } message: {
            Text(
                model.isLANGuest && !model.isNewScript
                    ? "The host does not reveal the existing source. Saving sends a complete replacement; this draft remains unsaved until the host confirms it in chat."
                    : "Switching scripts will otherwise discard the unsaved editor contents."
            )
        }
    }

    @ViewBuilder
    private func row(for record: ScriptRecord) -> some View {
        let isSelected = record.name == model.currentName
        HStack(spacing: 6) {
            SwiftUI.Button {
                requestSwitch(to: record.name)
            } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.name)
                            .font(isSelected ? .headline : .body)
                            .lineLimit(1)
                        Text(record.mode == .handler ? "handler" : "module")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !record.enabled {
                        Text("disabled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            SwiftUI.Button("Delete \(record.name)", systemImage: "trash") {
                pendingDelete = record.name
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete \(record.name)")
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 4)
        .background(isSelected ? theme.selection.color.opacity(0.35) : Color.clear)
        .clipShape(.rect(cornerRadius: theme.cornerRadiusSmall))
        .padding(.horizontal, 4)
    }

    private func requestNewScript() {
        guard model.isDirty else { model.newScript(); return }
        pendingNewScript = true
        pendingSwitchName = nil
        showingUnsavedChanges = true
    }

    private func requestSwitch(to name: String) {
        guard name != model.currentName else { return }
        guard model.isDirty else { model.switchTo(name); return }
        pendingNewScript = false
        pendingSwitchName = name
        showingUnsavedChanges = true
    }

    private func continuePendingNavigation() {
        if pendingNewScript {
            model.newScript()
        } else if let pendingSwitchName {
            model.switchTo(pendingSwitchName)
        }
        clearPendingNavigation()
    }

    private func clearPendingNavigation() {
        pendingNewScript = false
        pendingSwitchName = nil
        showingUnsavedChanges = false
    }
}
