// ScriptEditorSidebar.swift — script list plus switchable authoring browsers. Keeping this out of
// ScriptEditorView avoids recomputing search/sort work in the root three-column layout.

import SwiftUI

struct ScriptEditorSidebar: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    @AppStorage("elysiumScriptEditorSidebarTool") private var selectedTool: ScriptEditorSidebarTool = .snippets

    var body: some View {
        VStack(spacing: 0) {
            ScriptListSidebar(model: model)
            Picker("Authoring tools", selection: $selectedTool) {
                ForEach(ScriptEditorSidebarTool.allCases) { tool in
                    Text(tool.title).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .padding(theme.spacing)

            switch selectedTool {
            case .snippets:
                ScriptCommandPalette(model: model)
            case .worldObjects:
                WorldObjectsPaletteView(model: model)
            }
        }
        .background(theme.panelBackground.color)
    }
}
