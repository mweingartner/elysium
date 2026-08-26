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
    let scriptNames: [String]
    let capabilities: [String]

    var id: String { ref.canonical }

    var kindLabel: String { ref.kind.rawValue }

    var capabilitySummary: String {
        return capabilities.joined(separator: ", ")
    }
}
