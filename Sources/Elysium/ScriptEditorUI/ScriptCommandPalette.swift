// ScriptCommandPalette.swift — native SwiftUI script editor (Stage A). A scrollable, categorized
// list of Lua/Elysium snippets generated from ElysiumCore's authoritative `ScriptLanguageSchema`.
// Clicking an item
// inserts its code AT THE CURRENT CURSOR POSITION in the active script
// (`ScriptEditorModel.insertAtCursor`) — never appended to the end, which is the whole point of a
// palette over a static cheat sheet.

import SwiftUI
import ElysiumCore

struct ScriptPaletteItem: Identifiable {
    let id: String
    let name: String
    let code: String
    let summary: String

    init(_ descriptor: ScriptSnippetDescriptor) {
        id = descriptor.id
        name = descriptor.name
        code = descriptor.code
        summary = descriptor.summary
    }
}

struct ScriptPaletteCategory: Identifiable {
    var id: String { title }
    let title: String
    let items: [ScriptPaletteItem]
}

enum ScriptPalette {
    static func categories(for kind: ObjectKind) -> [ScriptPaletteCategory] {
        ScriptLanguageSchema.snippetSections(for: kind).map { section in
            ScriptPaletteCategory(
                title: section.category.rawValue,
                items: section.items.map(ScriptPaletteItem.init)
            )
        }
    }
}

struct ScriptCommandPalette: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    @State private var expanded: Set<String> = ["Events", "Control", "Objects"]

    var body: some View {
        VStack(spacing: 0) {
            Text("Commands")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.spacing)
                .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ScriptPalette.categories(for: model.target.kind)) { category in
                        DisclosureGroup(isExpanded: bindingFor(category.title)) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(category.items) { item in
                                    SwiftUI.Button {
                                        model.insertAtCursor(item.code)
                                    } label: {
                                        Text(item.name)
                                            .font(.caption.monospaced())
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, 3)
                                    .padding(.leading, 14)
                                    .contentShape(Rectangle())
                                    .help(item.summary)
                                }
                            }
                        } label: {
                            Text(category.title)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, theme.spacing)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func bindingFor(_ title: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(title) },
            set: { isOn in
                if isOn { expanded.insert(title) } else { expanded.remove(title) }
            }
        )
    }
}
