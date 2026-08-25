// ScriptCommandPalette.swift — native SwiftUI script editor (Stage A). A scrollable, categorized
// list of Lua/Elysium snippets (ported in spirit from Hype's `ScriptEditor.swift` `commandPalette`
// + `insertTemplate`, adapted from HypeTalk verbs to the Lua v1 API surface). Clicking an item
// inserts its code AT THE CURRENT CURSOR POSITION in the active script
// (`ScriptEditorModel.insertAtCursor`) — never appended to the end, which is the whole point of a
// palette over a static cheat sheet.

import SwiftUI
import ElysiumCore

struct ScriptPaletteItem: Identifiable {
    let id = UUID()
    let name: String
    let code: String
}

struct ScriptPaletteCategory: Identifiable {
    let id = UUID()
    let title: String
    let items: [ScriptPaletteItem]
}

enum ScriptPalette {
    /// Static categories that don't depend on the target's object kind.
    static let staticCategories: [ScriptPaletteCategory] = [
        ScriptPaletteCategory(title: "Events", items: [
            ScriptPaletteItem(name: "on(event, fn)", code: "on(\"load\", function(self, world, player, ev)\n  \nend)"),
            ScriptPaletteItem(name: "subscribe(target, event, fn)", code: "subscribe(self, \"attribute.changed\", function(self, world, player, ev)\n  \nend)"),
            ScriptPaletteItem(name: "emit(target, event)", code: "emit(self, \"custom.event\")"),
            ScriptPaletteItem(name: "register(name, fn)", code: "register(\"onLoaded\", function(self, world, player, ev)\n  \nend)"),
        ]),
        ScriptPaletteCategory(title: "Control", items: [
            ScriptPaletteItem(name: "if / then / end", code: "if condition then\n  \nend"),
            ScriptPaletteItem(name: "if / else / end", code: "if condition then\n  \nelse\n  \nend"),
            ScriptPaletteItem(name: "for i = 1, n", code: "for i = 1, 10 do\n  \nend"),
            ScriptPaletteItem(name: "while", code: "while condition do\n  \nend"),
            ScriptPaletteItem(name: "repeat / until", code: "repeat\n  \nuntil condition"),
            ScriptPaletteItem(name: "function", code: "function name(self, world, player)\n  \nend"),
        ]),
        ScriptPaletteCategory(title: "Objects", items: [
            ScriptPaletteItem(name: "self:get(name)", code: "self:get(\"name\")"),
            ScriptPaletteItem(name: "self:set(name, value)", code: "self:set(\"name\", value)"),
            ScriptPaletteItem(name: "self:exists()", code: "self:exists()"),
            ScriptPaletteItem(name: "self:scripts()", code: "self:scripts()"),
            ScriptPaletteItem(name: "self:define(name, value)", code: "self:define(\"name\", value)"),
            ScriptPaletteItem(name: "self:attach(name, source)", code: "self:attach(\"name\", \"module\", \"return\")"),
            ScriptPaletteItem(name: "self:detach(name)", code: "self:detach(\"name\")"),
            ScriptPaletteItem(name: "self:setBlock(x, y, z, name)", code: "self:setBlock(x, y, z, \"stone\")"),
            ScriptPaletteItem(name: "self:breakBlock(x, y, z)", code: "self:breakBlock(x, y, z)"),
            ScriptPaletteItem(name: "self.attrs", code: "self.attrs"),
            ScriptPaletteItem(name: "self.ref", code: "self.ref"),
            ScriptPaletteItem(name: "self.kind", code: "self.kind"),
            ScriptPaletteItem(name: "objects.get(ref)", code: "objects.get(\"player\")"),
            ScriptPaletteItem(name: "objects.find(kind)", code: "objects.find(\"entity\")"),
            ScriptPaletteItem(name: "objects.block(x, y, z)", code: "objects.block(x, y, z)"),
        ]),
        ScriptPaletteCategory(title: "Timing", items: [
            ScriptPaletteItem(name: "wait(n)", code: "wait(20)"),
            ScriptPaletteItem(name: "every(n, fn)", code: "every(20, function(self, world, player, ev)\n  \nend)"),
            ScriptPaletteItem(name: "after(n, fn)", code: "after(20, function(self, world, player, ev)\n  \nend)"),
            ScriptPaletteItem(name: "tick()", code: "tick()"),
        ]),
        ScriptPaletteCategory(title: "AI", items: [
            ScriptPaletteItem(name: "ai.ask(prompt)", code: "ai.ask(\"describe the scene\")"),
            ScriptPaletteItem(name: "ai.await(prompt)", code: "local reply = ai.await(\"describe the scene\")"),
        ]),
        ScriptPaletteCategory(title: "Misc", items: [
            ScriptPaletteItem(name: "rng()", code: "rng()"),
            ScriptPaletteItem(name: "say(text)", code: "say(\"hello\")"),
            ScriptPaletteItem(name: "sound(name)", code: "sound(\"block.stone.break\")"),
            ScriptPaletteItem(name: "particles(name, x, y, z)", code: "particles(\"smoke\", x, y, z)"),
            ScriptPaletteItem(name: "dim(name)", code: "dim(\"overworld\")"),
        ]),
    ]

    /// Attribute snippets for `kind` (block/entity/player/dim/world) — a get/set pair per
    /// registered `AttributeDescriptor`, using its own canonical name and mutability so a
    /// read-only attribute never gets a nonsensical `set` snippet.
    static func attributeCategory(for kind: ObjectKind) -> ScriptPaletteCategory {
        let items = AttributeRegistry.descriptors(for: kind).flatMap { descr -> [ScriptPaletteItem] in
            var out = [ScriptPaletteItem(name: "get \(descr.canonical)", code: "self:get(\"\(descr.canonical)\")")]
            if descr.mutability == .getSet {
                out.append(ScriptPaletteItem(name: "set \(descr.canonical)", code: "self:set(\"\(descr.canonical)\", value)"))
            }
            return out
        }
        return ScriptPaletteCategory(title: "Attributes", items: items)
    }

    static func categories(for kind: ObjectKind) -> [ScriptPaletteCategory] {
        staticCategories + [attributeCategory(for: kind)]
    }
}

struct ScriptCommandPalette: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    @State private var expanded: Set<String> = ["Events", "Control", "Objects"]

    var body: some View {
        VStack(spacing: 0) {
            Text("Commands")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
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
                                            .font(.system(size: 11, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, 3)
                                    .padding(.leading, 14)
                                    .contentShape(Rectangle())
                                }
                            }
                        } label: {
                            Text(category.title)
                                .font(.system(size: 11, weight: .semibold))
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
