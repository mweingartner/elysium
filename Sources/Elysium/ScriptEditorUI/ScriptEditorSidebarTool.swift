// ScriptEditorSidebarTool.swift — persisted selection for the left-side authoring browser.

enum ScriptEditorSidebarTool: String, CaseIterable, Identifiable {
    case snippets
    case worldObjects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snippets: "Snippets"
        case .worldObjects: "World Objects"
        }
    }
}
