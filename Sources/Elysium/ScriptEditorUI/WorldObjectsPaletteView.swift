// WorldObjectsPaletteView.swift — searchable, permission-bounded object discovery for script
// authoring. It consumes ScriptEditorModel's immutable snapshot, so filtering and insertion never
// query or mutate the running world from SwiftUI's body.

import SwiftUI
import Foundation
import ElysiumCore

struct WorldObjectsPaletteView: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    @AppStorage("elysiumScriptEditorPinnedObjectRefsV2") private var pinnedRefsStorage = "{}"
    @State private var searchText = ""

    private var pinnedRefs: Set<String> {
        Set(decodedPins[model.worldObjectPinScope] ?? [])
    }

    private var decodedPins: [String: [String]] {
        guard let data = pinnedRefsStorage.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return value
    }

    private var allEntries: [WorldObjectPaletteEntry] {
        let liveIDs = Set(model.worldObjects.map(\.id))
        let missingPinned = pinnedRefs
            .subtracting(liveIDs)
            .sorted()
            .compactMap { canonical -> WorldObjectPaletteEntry? in
                guard let ref = ObjectRef.parse(canonical) else { return nil }
                return WorldObjectPaletteEntry(
                    ref: ref,
                    displayName: "Pinned object",
                    distance: nil,
                    isLive: false,
                    isTarget: false,
                    isCursorTarget: false,
                    attributeNames: [],
                    scriptNames: [],
                    capabilities: ["stale canonical reference"]
                )
            }
        return (model.worldObjects + missingPinned).sorted { lhs, rhs in
            if lhs.isTarget != rhs.isTarget { return lhs.isTarget }
            if lhs.isCursorTarget != rhs.isCursorTarget { return lhs.isCursorTarget }
            let lhsPinned = pinnedRefs.contains(lhs.id)
            let rhsPinned = pinnedRefs.contains(rhs.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            switch (lhs.distance, rhs.distance) {
            case let (.some(a), .some(b)) where a != b: return a < b
            case (.none, .some): return true
            case (.some, .none): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    private var visibleEntries: [WorldObjectPaletteEntry] {
        allEntries.filter { entry in
            searchText.isEmpty || entry.displayName.localizedStandardContains(searchText) ||
                entry.ref.canonical.localizedStandardContains(searchText) ||
                entry.kindLabel.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SwiftUI.TextField("Filter objects", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(theme.spacing)

            if allEntries.isEmpty {
                ContentUnavailableView(
                    "No World Objects",
                    systemImage: "scope",
                    description: Text("No objects are available in the current snapshot. Refresh after entering a world or moving nearby.")
                )
            } else if visibleEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(visibleEntries) { entry in
                    WorldObjectPaletteRow(
                        entry: entry,
                        isPinned: pinnedRefs.contains(entry.id),
                        insertReference: { model.insertObjectReference(entry) },
                        insertBinding: { model.insertObjectBinding(entry) },
                        togglePin: { togglePin(entry.id) }
                    )
                    .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                }
                .listStyle(.plain)
                .accessibilityLabel("Available world objects")
            }
        }
    }

    private var header: some View {
        HStack {
            Label("World Objects", systemImage: "scope")
                .font(.headline)
            Spacer()
            SwiftUI.Button("Refresh", systemImage: "arrow.clockwise", action: model.refreshWorldObjects)
                .labelStyle(.iconOnly)
                .help("Refresh nearby objects")
                .accessibilityLabel("Refresh nearby world objects")
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 6)
    }

    private func togglePin(_ ref: String) {
        var refs = pinnedRefs
        if refs.contains(ref) { refs.remove(ref) } else { refs.insert(ref) }
        var byScope = decodedPins
        byScope[model.worldObjectPinScope] = refs.sorted()
        guard let data = try? JSONEncoder().encode(byScope),
              let encoded = String(data: data, encoding: .utf8) else { return }
        pinnedRefsStorage = encoded
    }
}

private struct WorldObjectPaletteRow: View {
    let entry: WorldObjectPaletteEntry
    let isPinned: Bool
    let insertReference: () -> Void
    let insertBinding: () -> Void
    let togglePin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbolName)
                    .accessibilityHidden(true)
                Text(entry.displayName)
                    .font(.body)
                    .lineLimit(1)
                if entry.isTarget { Text("target").font(.caption).foregroundStyle(.secondary) }
                if entry.isCursorTarget { Text("cursor").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let distance = entry.distance {
                    Text(distance, format: .number.precision(.fractionLength(1)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(distance.formatted(.number.precision(.fractionLength(1)))) blocks away")
                }
            }

            Text(entry.ref.canonical)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(entry.kindLabel)
                    .font(.caption.weight(.semibold))
                Label(entry.isLive ? "live" : "stale", systemImage: entry.isLive ? "checkmark.circle" : "exclamationmark.triangle")
                Text("\(entry.attributeNames.count) attrs")
                Text("\(entry.scriptNames.count) scripts")
            }
            .font(.caption)
            .foregroundStyle(entry.isLive ? Color.secondary : Color.orange)

            HStack {
                SwiftUI.Button("Insert", systemImage: "text.insert", action: insertReference)
                    .disabled(!entry.isLive)
                    .help(entry.isLive ? "Insert this canonical object reference" : "Refresh before inserting this stale object")
                SwiftUI.Button("Bind", systemImage: "link", action: insertBinding)
                    .disabled(!entry.isLive)
                    .help(entry.isLive ? "Insert a local binding for this object" : "Refresh before binding this stale object")
                Spacer()
                SwiftUI.Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin", action: togglePin)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(
                        isPinned
                            ? "Unpin \(entry.displayName), \(entry.ref.canonical)"
                            : "Pin \(entry.displayName), \(entry.ref.canonical)"
                    )
            }
            .controlSize(.small)
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(entry.displayName), \(entry.kindLabel), \(entry.isLive ? "live" : "stale"), \(entry.ref.canonical)"
        )
        .accessibilityValue(
            "\(entry.attributeNames.count) attributes, \(entry.scriptNames.count) scripts"
        )
    }

    private var symbolName: String {
        switch entry.kindLabel {
        case "player": "person.fill"
        case "entity": "figure.walk"
        case "block": "cube.fill"
        case "dim": "square.3.layers.3d"
        default: "globe"
        }
    }

    private var helpText: String {
        let attrs = entry.attributeNames.isEmpty ? "none" : entry.attributeNames.joined(separator: ", ")
        let scripts = entry.scriptNames.isEmpty ? "none" : entry.scriptNames.joined(separator: ", ")
        return "Capabilities: \(entry.capabilitySummary)\nAttributes: \(attrs)\nScripts: \(scripts)"
    }
}
