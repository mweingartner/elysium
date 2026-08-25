// ScriptEditorView.swift — native SwiftUI script editor (Stage A). The SwiftUI root: a three-
// column `HSplitView` (script list + command palette | Lua editor + toolbar + error banner |
// collapsible AI chat), themed via `ScriptEditorTheme`, laid out with SwiftUI's own flexbox-style
// stacks so nothing overlaps regardless of window size (the whole point of going native — the
// retired `ScriptEditorScreen` hand-placed pixel rects on a fixed canvas).

import SwiftUI
import ElysiumCore

// This module also defines its own game-canvas `Button`/`TextField` (`UIManagerM.swift`) with
// unrelated initializers — every SwiftUI `Button`/`TextField` call site below is qualified
// `SwiftUI.Button`/`SwiftUI.TextField` so it resolves unambiguously.
struct ScriptEditorView: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("elysiumScriptEditorAIPanelOpen") private var aiPanelOpen = false
    @State private var theme: ScriptEditorTheme = ScriptEditorTheme.currentSystem()

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            editorColumn
                .frame(minWidth: 380, maxWidth: .infinity)

            if aiPanelOpen {
                ScriptEditorAIPanel(model: model)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.scriptEditorTheme, theme)
        .environment(\.colorScheme, theme.chromeColorScheme)
        .onAppear { theme = ScriptEditorTheme.resolved(for: systemColorScheme) }
        .onChange(of: systemColorScheme) { _, newValue in theme = ScriptEditorTheme.resolved(for: newValue) }
        .background(theme.background.color)
    }

    // MARK: - left column: script list + palette

    private var leftColumn: some View {
        VStack(spacing: 0) {
            ScriptListSidebar(model: model)
            ScriptCommandPalette(model: model)
        }
        .background(theme.panelBackground.color)
    }

    // MARK: - center column: toolbar + editor + status banner

    private var editorColumn: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            LuaCodeTextView(
                text: $model.source,
                selectedRange: $model.selectedRange,
                errorLine: model.errorLine,
                targetKind: model.target.kind,
                theme: theme,
                onTextChange: {
                    model.errorLine = nil
                    if model.statusIsError { model.status = nil }
                }
            )
            .background(theme.background.color)
            .overlay(
                Rectangle().stroke(theme.divider.color, lineWidth: 1)
            )
            .padding(theme.spacing)

            if let status = model.status {
                statusBanner(status)
            } else {
                Text("\(model.sourceByteCount)/16384 bytes")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, theme.spacing)
                    .padding(.bottom, theme.spacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var isHandlerMode: Binding<Bool> {
        Binding(get: { model.mode == .handler }, set: { model.mode = $0 ? .handler : .module })
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: theme.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                SwiftUI.TextField("script name", text: $model.currentName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.isLANGuest ? "\(model.target.canonical) (guest)" : model.target.canonical)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 110, idealWidth: 160, maxWidth: 190, alignment: .leading)
            .layoutPriority(0)

            Picker("", selection: isHandlerMode) {
                Text("module").tag(false)
                Text("handler").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            if model.mode == .handler {
                SwiftUI.TextField("event name", text: $model.handlerEvent)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 170)
            }

            Spacer(minLength: theme.spacing)

            HStack(spacing: 6) {
                SwiftUI.Button("Check") { model.check() }
                    .disabled(model.isLANGuest)
                    .help(model.isLANGuest ? "Check is not available for guests yet" : "Compile and dry-run without persisting")
                SwiftUI.Button("Run") { model.run() }
                    .help("Run once, ephemeral — never saved")
                SwiftUI.Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Attach this script to \(model.target.canonical)")
            }
            // Never let the action buttons compress below their label width — the name field
            // (layoutPriority 0) truncates first when the toolbar is tight.
            .fixedSize()
            .layoutPriority(1)

            Divider().frame(height: 20)

            SwiftUI.Button {
                aiPanelOpen.toggle()
            } label: {
                Image(systemName: aiPanelOpen ? "sidebar.trailing" : "sidebar.leading")
            }
            .help(aiPanelOpen ? "Hide AI panel" : "Show AI panel")
            .accessibilityLabel("Toggle AI panel")
        }
        .padding(theme.spacing)
        .background(theme.toolbarBackground.color)
    }

    private func statusBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(model.statusIsError ? theme.error.color : .green)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(model.statusIsError ? theme.error.color : .green)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 6)
        .background((model.statusIsError ? theme.error.color : Color.green).opacity(0.12))
    }
}
