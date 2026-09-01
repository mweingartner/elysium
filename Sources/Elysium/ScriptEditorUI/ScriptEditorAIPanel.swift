// ScriptEditorAIPanel.swift — native SwiftUI script editor (Stage A). The collapsible right-hand
// AI help column: transcript bubbles + auto-scroll + "Working…" (ported from Hype's
// `Hype/Views/ScriptEditorAIView.swift`), wired only to the editor's bounded proposal service.
// Unlike `/ai`, this panel receives no world query/mutation tools and cannot execute, save, or run
// a script. It restores and preloads the currently selected local model
// (`game.settings.aiOllamaModel`) whenever the panel becomes visible, refreshes the picker through
// `elysiumOllamaAgent.fetchModels`, keeps prompt history via ↑/↓ (`AIChatPromptHistory`), and uses
// an auto-growing input (`AutoGrowingTextInput`). A successful response can be inserted explicitly
// after the user has reviewed it.

import SwiftUI
import ElysiumCore

struct ScriptEditorAIModelLoader {
    let fetchModels: @MainActor () async throws -> [String]
    let preloadModel: @MainActor (String) async throws -> Void

    static let live = ScriptEditorAIModelLoader(
        fetchModels: { try await elysiumOllamaAgent.fetchModels() },
        preloadModel: { try await elysiumOllamaAgent.preloadModel($0) }
    )
}

@MainActor
final class ScriptEditorAIModelPreloader: ObservableObject {
    private let preloadOperation: @MainActor (String) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var satisfiedModel: String?

    init(preloadOperation: @escaping @MainActor (String) async throws -> Void) {
        self.preloadOperation = preloadOperation
    }

    deinit {
        task?.cancel()
    }

    func preload(_ requestedModel: String, force: Bool = false) {
        let model = sanitizedOllamaModelName(requestedModel)
        guard isAllowedLocalOllamaModelName(model) else { return }
        guard force || satisfiedModel != model else { return }

        generation &+= 1
        let currentGeneration = generation
        task?.cancel()
        satisfiedModel = model
        let operation = preloadOperation
        task = Task { @MainActor [weak self] in
            do {
                try await operation(model)
                guard let self, self.generation == currentGeneration else { return }
                self.task = nil
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.task = nil
                self.satisfiedModel = nil
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        satisfiedModel = nil
    }
}

struct ScriptEditorAIPanel: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    private let modelLoader: ScriptEditorAIModelLoader
    @StateObject private var modelPreloader: ScriptEditorAIModelPreloader

    private struct Bubble: Identifiable, Equatable {
        let id = UUID()
        let role: String // "user" | "assistant"
        let content: String
    }

    @State private var messages: [Bubble] = []
    @State private var prompt = ""
    @State private var promptContentHeight: CGFloat = 18
    @State private var isProcessing = false
    @State private var history: [String] = []
    @State private var historyIndex = -1
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelDiscoveryTask: Task<Void, Never>?
    @State private var modelDiscoveryGeneration: UInt64 = 0
    @State private var requestTask: Task<Void, Never>?
    @State private var lastAssistantInsertion: String?
    @State private var lastAssistantInsertionRefusal: String?
    @State private var requestGeneration: UInt64 = 0
    @FocusState private var isPromptFocused: Bool

    init(
        model: ScriptEditorModel,
        modelLoader: ScriptEditorAIModelLoader = .live
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.modelLoader = modelLoader
        _modelPreloader = StateObject(wrappedValue: ScriptEditorAIModelPreloader(
            preloadOperation: modelLoader.preloadModel
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let insertion = lastAssistantInsertion {
                HStack {
                    SwiftUI.Button {
                        if let refusal = model.aiInsertionPreflightFailure(insertion) {
                            lastAssistantInsertionRefusal = refusal
                            lastAssistantInsertion = nil
                        } else {
                            model.insertAtCursor(insertion)
                            lastAssistantInsertion = nil
                            lastAssistantInsertionRefusal = nil
                        }
                    } label: {
                        Label("Insert response at cursor", systemImage: "arrow.down.doc")
                    }
                    .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, theme.spacing)
                .padding(.top, 4)
            }
            if let refusal = lastAssistantInsertionRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, theme.spacing)
                    .padding(.top, 4)
                    .accessibilityLabel(refusal)
            }
            Divider()
            inputArea
        }
        .background(theme.panelBackground.color)
        .onAppear {
            model.refreshAIConfiguration()
            activateConfiguredModel()
        }
        .onChange(of: model.aiCompletionMode) { _, mode in
            if mode == .off {
                stop()
            } else {
                activateConfiguredModel()
            }
        }
        .onChange(of: model.isWorldSessionActive) { _, active in
            if active {
                activateConfiguredModel()
            } else {
                stop()
            }
        }
        .onChange(of: model.aiModelName) { _, _ in
            preloadConfiguredModel()
        }
        .onChange(of: model.documentIdentity) { _, _ in
            clearConversation()
        }
        .onDisappear {
            stop()
        }
    }

    // MARK: - header

    private func activateConfiguredModel() {
        refreshModels()
        preloadConfiguredModel()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.sparkles")
                .foregroundColor(.secondary)
            Text("Script AI")
                .font(.headline)
            Spacer(minLength: 4)
            Menu {
                if availableModels.isEmpty {
                    SwiftUI.Button(isFetchingModels ? "Loading local models…" : "Load local models") {
                        reloadModels()
                    }
                    .disabled(isFetchingModels || model.aiCompletionMode == .off || !model.isWorldSessionActive)
                } else {
                    ForEach(availableModels, id: \.self) { name in
                        SwiftUI.Button {
                            model.setAIModel(name)
                        } label: {
                            if name == model.aiModelName {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                    Divider()
                    SwiftUI.Button("Refresh local models") {
                        reloadModels()
                    }
                }
            } label: {
                Text(model.aiModelName.isEmpty ? "Choose model" : model.aiModelName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 150)
            .accessibilityLabel("AI model")

            if !messages.isEmpty {
                SwiftUI.Button {
                    clearConversation()
                } label: {
                    Label("Clear AI conversation", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
                .accessibilityLabel("Clear AI conversation")
            }
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 6)
        .background(theme.toolbarBackground.color)
    }

    private func refreshModels() {
        guard model.aiCompletionMode != .off, model.isWorldSessionActive,
              availableModels.isEmpty, !isFetchingModels else { return }
        isFetchingModels = true
        modelDiscoveryGeneration &+= 1
        let generation = modelDiscoveryGeneration
        modelDiscoveryTask = Task { @MainActor in
            defer {
                if modelDiscoveryGeneration == generation {
                    isFetchingModels = false
                    modelDiscoveryTask = nil
                }
            }
            do {
                let names = try await modelLoader.fetchModels()
                guard !Task.isCancelled, modelDiscoveryGeneration == generation,
                      model.aiCompletionMode != .off,
                      model.isWorldSessionActive else { return }
                availableModels = names
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func reloadModels() {
        availableModels = []
        refreshModels()
        preloadConfiguredModel(force: true)
    }

    private func preloadConfiguredModel(force: Bool = false) {
        guard model.aiCompletionMode != .off, model.isWorldSessionActive else { return }
        modelPreloader.preload(model.aiModelName, force: force)
    }

    // MARK: - transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.spacing) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ask about \(model.targetDisplayName)'s script, request a rewrite, or ask for Lua to insert.")
                            Label("Read-only proposal service · no world tools", systemImage: "lock.shield")
                        }
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(theme.spacing)
                    }
                    ForEach(messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if isProcessing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Working…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, theme.spacing)
                    }
                }
                .padding(.vertical, theme.spacing)
            }
            .onChange(of: messages) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: Bubble) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.role == "user" ? "You" : "Elysium AI")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(message.content)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(message.role == "user" ? Color.accentColor.opacity(0.15) : theme.background.color)
                .cornerRadius(theme.cornerRadiusSmall)
        }
        .padding(.horizontal, theme.spacing)
    }

    // MARK: - input

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(model.aiCompletionMode == .off ? "Editor AI is Off" : "Ask Script AI…")
                        .foregroundColor(.secondary)
                        .font(.body)
                        .padding(8)
                        .allowsHitTesting(false)
                }
                AutoGrowingTextInput(
                    text: $prompt,
                    contentHeight: $promptContentHeight,
                    isEnabled: !isProcessing && model.aiCompletionMode != .off && model.isWorldSessionActive,
                    onSubmit: send,
                    onHistoryUp: { recallHistory(.up) },
                    onHistoryDown: { recallHistory(.down) }
                )
                .padding(8)
                .focused($isPromptFocused)
            }
            .frame(height: min(max(promptContentHeight + 16, 32), 320))
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                    .stroke(Color.secondary.opacity(0.3))
            )

            if isProcessing {
                SwiftUI.Button("Stop") { stop() }
                    .foregroundColor(.red)
            } else {
                SwiftUI.Button("Send") { send() }
                    .disabled(
                        model.aiCompletionMode == .off ||
                            !model.isWorldSessionActive ||
                            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(theme.spacing)
    }

    private func send() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.aiCompletionMode != .off, model.isWorldSessionActive,
              !request.isEmpty, !isProcessing else { return }
        history = AIChatPromptHistory.appending(request, to: history)
        historyIndex = -1
        messages.append(Bubble(role: "user", content: request))
        lastAssistantInsertion = nil
        lastAssistantInsertionRefusal = nil
        prompt = ""
        isProcessing = true
        requestGeneration &+= 1
        let generation = requestGeneration
        requestTask = Task { @MainActor in
            defer {
                if requestGeneration == generation {
                    isProcessing = false
                    requestTask = nil
                }
            }
            do {
                let reply = try await model.requestEditorAIReply(instruction: request)
                guard !Task.isCancelled, requestGeneration == generation else { return }
                messages.append(Bubble(role: "assistant", content: reply))
                // Insert the salvaged code, not the raw reply: the model sometimes appends an
                // explanatory sentence the editor would treat as a syntax error. insertableProposal
                // unwraps any fence and trims trailing prose to the largest compilable prefix.
                if let insertable = model.insertableProposal(from: reply) {
                    lastAssistantInsertion = insertable
                    lastAssistantInsertionRefusal = nil
                } else {
                    lastAssistantInsertion = nil
                    lastAssistantInsertionRefusal = model.aiInsertionPreflightFailure(reply)
                        ?? "AI proposal refused: the reply contained no insertable Lua."
                }
            } catch let error as OllamaCodeCompletionError
                where error == .cancelled || error == .stale {
                return
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                lastAssistantInsertion = nil
                lastAssistantInsertionRefusal = nil
                messages.append(Bubble(role: "assistant", content: error.localizedDescription))
            }
        }
    }

    private func stop() {
        stopRequest()
        modelDiscoveryGeneration &+= 1
        modelDiscoveryTask?.cancel()
        modelDiscoveryTask = nil
        isFetchingModels = false
        modelPreloader.stop()
    }

    private func stopRequest() {
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
        isProcessing = false
    }

    private func clearConversation() {
        stopRequest()
        messages.removeAll()
        prompt = ""
        history.removeAll()
        historyIndex = -1
        lastAssistantInsertion = nil
        lastAssistantInsertionRefusal = nil
    }

    private func recallHistory(_ direction: AIChatPromptHistoryDirection) {
        if let recalled = AIChatPromptHistory.recall(direction: direction, from: history, index: &historyIndex) {
            prompt = recalled
        }
    }

}
