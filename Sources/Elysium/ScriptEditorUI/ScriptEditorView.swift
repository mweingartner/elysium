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
    @State private var problemsExpanded = false
    @State private var showingGuestReplacementWarning = false
    @State private var showingOverwriteWarning = false
    @State private var showingScriptingActivationWarning = false
    @State private var pendingSaveCollision: ScriptEditorSaveCollision?
    @State private var pendingScriptingActivationAction: ScriptEditorScriptingActivationAction?

    var body: some View {
        HSplitView {
            ScriptEditorSidebar(model: model)
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            editorColumn
                .frame(minWidth: 380, maxWidth: .infinity)

            if aiPanelOpen {
                ScriptEditorAIPanel(model: model)
                    .id(model.documentIdentity)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.scriptEditorTheme, theme)
        .environment(\.colorScheme, theme.chromeColorScheme)
        .onAppear {
            theme = ScriptEditorTheme.resolved(for: systemColorScheme)
            model.refreshAIConfiguration()
            model.refreshScriptingAvailability()
        }
        .onChange(of: systemColorScheme) { _, newValue in theme = ScriptEditorTheme.resolved(for: newValue) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshScriptingAvailability()
        }
        .background(theme.background.color)
        .alert("Replace source hidden by the host?", isPresented: $showingGuestReplacementWarning) {
            SwiftUI.Button("Cancel", role: .cancel) { pendingSaveCollision = nil }
            SwiftUI.Button("Send Full Replacement", role: .destructive) {
                _ = model.save(confirming: pendingSaveCollision)
                pendingSaveCollision = nil
            }
        } message: {
            Text("The host does not reveal this script's existing source. Saving sends the complete text shown here as a replacement. Keep this draft until the host confirms it in chat.")
        }
        .alert("Replace an existing script?", isPresented: $showingOverwriteWarning) {
            SwiftUI.Button("Cancel", role: .cancel) { pendingSaveCollision = nil }
            SwiftUI.Button("Replace Script", role: .destructive) {
                requestGuestConfirmationOrSave(confirming: pendingSaveCollision)
            }
        } message: {
            Text((pendingSaveCollision?.description ?? "An existing script would be replaced.") + " This is destructive and cannot be undone from the editor after saving.")
        }
        .alert("Enable attached script execution?", isPresented: $showingScriptingActivationWarning) {
            SwiftUI.Button("Cancel", role: .cancel) {
                pendingScriptingActivationAction = nil
            }
            SwiftUI.Button(
                pendingScriptingActivationAction?.buttonTitle ?? "Enable",
                role: .destructive
            ) {
                if let pendingScriptingActivationAction {
                    model.enableAttachedScriptExecutionAfterConfirmation(
                        confirming: pendingScriptingActivationAction
                    )
                }
                pendingScriptingActivationAction = nil
            }
        } message: {
            Text(pendingScriptingActivationAction?.confirmationDetail
                 ?? "Script execution settings changed before confirmation. Cancel and review the current status.")
        }
    }

    // MARK: - center column: toolbar + editor + status banner

    private var editorColumn: some View {
        VStack(spacing: 0) {
            NativeScriptEditorToolbar(
                model: model,
                theme: theme,
                aiPanelOpen: aiPanelOpen,
                onSave: requestSave,
                onToggleAI: { aiPanelOpen.toggle() },
                onRequestScriptingActivation: requestScriptingActivation
            )
            .frame(maxWidth: .infinity)
            Divider()
            LuaCodeTextView(
                text: $model.source,
                selectedRange: $model.selectedRange,
                errorLine: model.errorLine,
                targetKind: model.target.kind,
                targetCanonicalRef: model.target.canonical,
                theme: theme,
                targetApplicableBuiltInAttributes: model.languageEnvironment.targetApplicableBuiltInAttributes,
                targetCustomAttributes: model.languageEnvironment.targetCustomAttributes,
                objectReferences: model.languageEnvironment.objectReferences,
                scriptMode: model.languageEnvironment.scriptMode,
                handlerEvent: model.languageEnvironment.handlerEvent,
                eventCandidates: model.languageEnvironment.eventCandidates,
                isYieldable: model.languageEnvironment.isYieldable,
                inlineSuggestion: model.inlineAISuggestion,
                isRequestingAISuggestion: model.isRequestingAISuggestion,
                externalEdit: model.externalEditorEdit,
                documentIdentity: model.documentIdentity,
                onTextChange: {
                    model.errorLine = nil
                    if model.statusIsError { model.status = nil }
                },
                onRequestAISuggestion: model.requestAISuggestion,
                onAcceptAISuggestion: model.didAcceptAISuggestionInTextView,
                onAcceptNextAISuggestionWord: model.acceptNextAIWord,
                onAcceptNextAISuggestionLine: model.acceptNextAILine,
                onDismissAISuggestion: model.dismissAISuggestion,
                onAnalysisChange: model.updateLanguageAnalysis
            )
            .background(theme.background.color)
            .overlay(
                Rectangle().stroke(theme.divider.color, lineWidth: 1)
            )
            .padding(theme.spacing)

            languageStatusBar

            if problemsExpanded, !model.editorDiagnostics.isEmpty {
                Divider()
                ScriptEditorProblemsView(
                    diagnostics: model.editorDiagnostics,
                    source: model.source,
                    select: { model.selectedRange = $0.range },
                    applyFix: model.applyQuickFix
                )
            }

            if let status = model.status {
                statusBanner(status)
            }
        }
    }

    private var languageStatusBar: some View {
        HStack(spacing: 8) {
            if let signature = model.signatureHelp {
                Label(signature.label, systemImage: "function")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .help("Active parameter \(signature.activeParameter + 1). \(signature.documentation)")
            } else if model.isRequestingAISuggestion {
                Label("Asking \(model.aiModelName)…", systemImage: "wand.and.sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = model.aiSuggestionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            } else if model.inlineAISuggestion != nil {
                Label("AI proposal from \(model.aiModelName) — Tab accepts, Escape dismisses", systemImage: "wand.and.sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Lua 5.4.8 sandbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !model.editorDiagnostics.isEmpty {
                SwiftUI.Button {
                    problemsExpanded.toggle()
                } label: {
                    Label(
                        "\(model.editorDiagnostics.count) problem\(model.editorDiagnostics.count == 1 ? "" : "s")",
                        systemImage: problemsExpanded ? "chevron.down.circle" : "exclamationmark.circle"
                    )
                }
                .buttonStyle(.plain)
                .help(problemsExpanded ? "Hide Lua problems" : "Show Lua problems")
            }

            Text("\(model.sourceByteCount)/16384 bytes")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.sourceByteCount > 16_384 ? theme.error.color : Color.secondary)
                .accessibilityLabel("\(model.sourceByteCount) of 16384 source bytes")
        }
        .padding(.horizontal, theme.spacing)
        .padding(.bottom, theme.spacing)
    }

    private func statusBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(model.statusIsError ? theme.error.color : .green)
            Text(text)
                .font(.caption)
                .foregroundColor(model.statusIsError ? theme.error.color : .green)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 6)
        .background((model.statusIsError ? theme.error.color : Color.green).opacity(0.12))
    }

    private func requestSave() {
        if let collision = model.saveCollision {
            pendingSaveCollision = collision
            showingOverwriteWarning = true
            return
        }
        requestGuestConfirmationOrSave(confirming: nil)
    }

    private func requestScriptingActivation(_ action: ScriptEditorScriptingActivationAction) {
        pendingScriptingActivationAction = action
        showingScriptingActivationWarning = true
    }

    private func requestGuestConfirmationOrSave(confirming collision: ScriptEditorSaveCollision?) {
        if model.isLANGuest, !model.isNewScript {
            pendingSaveCollision = collision
            showingGuestReplacementWarning = true
        } else {
            _ = model.save(confirming: collision)
            pendingSaveCollision = nil
        }
    }
}
