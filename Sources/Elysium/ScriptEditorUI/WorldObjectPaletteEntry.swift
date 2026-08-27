// WorldObjectPaletteEntry.swift — immutable, UI-only projection of one object that is safe to
// offer to a script author. The snapshot is built on the main actor from ObjectGraph and the same
// AttributeStore/ScriptStore read paths used by the scripting commands; the view never reaches
// into live game state while it renders or filters rows.

import Foundation
import ElysiumCore

struct WorldObjectPaletteEntry: Identifiable, Equatable {
    let ref: ObjectRef
    let displayName: String
    let distance: Double?
    let isLive: Bool
    let isTarget: Bool
    let isCursorTarget: Bool
    let attributeNames: [String]
    /// Typed, mutability-aware metadata captured from the same immutable refresh as `attributeNames`.
    /// The names remain as a presentation convenience; deterministic completion consumes this
    /// richer projection so a nearby object's readonly attribute is never advertised as writable.
    let attributeCompletions: [LuaCustomAttributeCompletion]
    let scriptNames: [String]
    let capabilities: [String]

    init(
        ref: ObjectRef,
        displayName: String,
        distance: Double?,
        isLive: Bool,
        isTarget: Bool,
        isCursorTarget: Bool,
        attributeNames: [String],
        scriptNames: [String],
        capabilities: [String],
        attributeCompletions: [LuaCustomAttributeCompletion]? = nil
    ) {
        self.ref = ref
        self.displayName = displayName
        self.distance = distance
        self.isLive = isLive
        self.isTarget = isTarget
        self.isCursorTarget = isCursorTarget
        self.attributeNames = attributeNames
        self.attributeCompletions = attributeCompletions
            ?? attributeNames.map { LuaCustomAttributeCompletion(name: $0) }
        self.scriptNames = scriptNames
        self.capabilities = capabilities
    }

    var id: String { ref.canonical }

    var kindLabel: String { ref.kind.rawValue }

    var capabilitySummary: String {
        return capabilities.joined(separator: ", ")
    }
}
