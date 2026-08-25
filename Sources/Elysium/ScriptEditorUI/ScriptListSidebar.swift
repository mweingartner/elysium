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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scripts on \(model.targetDisplayName)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                SwiftUI.Button {
                    model.newScript()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("New script")
                .accessibilityLabel("New script")
            }
            .padding(.horizontal, theme.spacing)
            .padding(.vertical, 6)

            if model.scripts.isEmpty {
                Text("No scripts yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
            Text("This removes the script from \(model.targetDisplayName).")
        }
    }

    @ViewBuilder
    private func row(for record: ScriptRecord) -> some View {
        let isSelected = record.name == model.currentName
        HStack(spacing: 6) {
            SwiftUI.Button {
                model.switchTo(record.name)
            } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        Text(record.mode == .handler ? "handler" : "module")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    if !record.enabled {
                        Text("disabled")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SwiftUI.Button {
                pendingDelete = record.name
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Delete \(record.name)")
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 4)
        .background(isSelected ? theme.selection.color.opacity(0.35) : Color.clear)
        .cornerRadius(theme.cornerRadiusSmall)
        .padding(.horizontal, 4)
    }
}
