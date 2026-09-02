// ScriptEditorAIPanel.swift — native SwiftUI script editor (Stage A). The collapsible right-hand
// AI help column: transcript bubbles + auto-scroll + "Working…" (ported from Hype's
// `Hype/Views/ScriptEditorAIView.swift`), wired only to the editor's bounded proposal service.
// Unlike `/ai`, this panel receives no world query/mutation tools and cannot execute, save, or run
// a script. The editor lifecycle prepares the selected local model even while this panel is hidden;
// this view refreshes the picker through
// `elysiumOllamaAgent.fetchModels`, keeps prompt history via ↑/↓ (`AIChatPromptHistory`), and uses
// an auto-growing input (`AutoGrowingTextInput`). Explicit Write Code may apply only Lua that passes
// the editor's mode-aware deterministic validation boundary; Ask always remains transcript-only.

import SwiftUI
import ElysiumCore

struct ScriptEditorAIModelLoader {
    let fetchModels: @MainActor () async throws -> [String]

    static let live = ScriptEditorAIModelLoader(
        fetchModels: { try await elysiumOllamaAgent.fetchModels() }
    )
}

struct ScriptEditorAIPanel: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme
    private let modelLoader: ScriptEditorAIModelLoader

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
    @State private var lastAssistantInsertionStatus: String?
    @State private var lastAssistantInsertionRefusal: String?
    @State private var requestGeneration: UInt64 = 0
    @State private var requestIntent: ScriptEditorAIRequestIntent = .writeCode
    @FocusState private var isPromptFocused: Bool

    init(
        model: ScriptEditorModel,
        modelLoader: ScriptEditorAIModelLoader = .live
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.modelLoader = modelLoader
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let insertionStatus = lastAssistantInsertionStatus {
                Label(insertionStatus, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, theme.spacing)
                    .padding(.top, 4)
                    .accessibilityLabel(insertionStatus)
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
            refreshModels()
        }
        .onChange(of: model.aiCompletionMode) { _, mode in
            if mode == .off {
                stop()
            } else {
                refreshModels()
            }
        }
        .onChange(of: model.isWorldSessionActive) { _, active in
            if active {
                refreshModels()
            } else {
                stop()
            }
        }
        .onChange(of: model.documentIdentity) { _, _ in
            clearConversation()
        }
        .onDisappear {
            stop()
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(spacing: 3) {
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
                        .disabled(
                            isFetchingModels || model.aiCompletionMode == .off ||
                                !model.isWorldSessionActive
                        )
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
            readinessRow
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 6)
        .background(theme.toolbarBackground.color)
    }

    @ViewBuilder
    private var readinessRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                switch model.aiReadinessState {
                case .preparing:
                    ProgressView().controlSize(.small)
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .off, .needsModel, .idle:
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                }
                Text(model.aiReadinessState.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if case .failed = model.aiReadinessState {
                    SwiftUI.Button("Retry") { model.retryAIReadiness() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            if case .failed(_, let message) = model.aiReadinessState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.aiReadinessState.accessibilityText)
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
        model.retryAIReadiness()
    }

    // MARK: - transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.spacing) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Write validated Lua for \(model.targetDisplayName), or switch to Ask for transcript-only help.")
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
                            Text(processingStatusText)
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
        VStack(alignment: .leading, spacing: 7) {
            Picker("Request type", selection: $requestIntent) {
                ForEach(ScriptEditorAIRequestIntent.allCases) { intent in
                    Text(intent.rawValue).tag(intent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isProcessing)
            .accessibilityLabel("Script AI request type")

            Text(requestIntent == .writeCode
                 ? "Validated Lua inserts into the current Module or Handler. It is never saved or run automatically."
                 : "Answers appear here and never edit your script.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Each request is independent; prior bubbles are not sent to Ollama. Restate any detail the next request needs.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text(promptPlaceholder)
                            .foregroundColor(.secondary)
                            .font(.body)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    AutoGrowingTextInput(
                        text: $prompt,
                        contentHeight: $promptContentHeight,
                        isEnabled: !isProcessing && model.aiCompletionMode != .off &&
                            model.isWorldSessionActive,
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
                    SwiftUI.Button(requestIntent == .writeCode ? "Write" : "Ask") { send() }
                        .disabled(
                            model.aiCompletionMode == .off ||
                                !model.isWorldSessionActive ||
                                prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(theme.spacing)
    }

    private var promptPlaceholder: String {
        if model.aiCompletionMode == .off { return "Editor AI is Off" }
        return requestIntent == .writeCode
            ? "Describe code to add…"
            : "Ask about this script…"
    }

    private var processingStatusText: String {
        switch model.aiReadinessState {
        case .ready:
            requestIntent == .writeCode ? "Generating and validating…" : "Thinking…"
        default:
            model.aiReadinessState.statusText
        }
    }

    private func send() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.aiCompletionMode != .off, model.isWorldSessionActive,
              !request.isEmpty, !isProcessing else { return }
        history = AIChatPromptHistory.appending(request, to: history)
        historyIndex = -1
        messages.append(Bubble(role: "user", content: request))
        lastAssistantInsertionStatus = nil
        lastAssistantInsertionRefusal = nil
        prompt = ""
        isProcessing = true
        requestGeneration &+= 1
        let generation = requestGeneration
        let intent = requestIntent
        requestTask = Task { @MainActor in
            defer {
                if requestGeneration == generation {
                    isProcessing = false
                    requestTask = nil
                }
            }
            do {
                let reply = try await model.requestEditorAIReply(
                    instruction: request,
                    intent: intent
                )
                guard !Task.isCancelled, requestGeneration == generation else { return }
                messages.append(Bubble(role: "assistant", content: reply.text))
                switch reply.applyOutcome {
                case .inserted(let receipt):
                    let omission = receipt.omittedTrailingText ? " Trailing non-code text was omitted." : ""
                    lastAssistantInsertionStatus = "Inserted validated Lua into \(receipt.destinationDescription).\(omission)"
                    lastAssistantInsertionRefusal = nil
                case .answerOnly:
                    lastAssistantInsertionStatus = nil
                    lastAssistantInsertionRefusal = intent == .writeCode
                        ? "No code was inserted because the model returned an answer instead of valid Lua."
                        : nil
                case .refused(let message):
                    lastAssistantInsertionStatus = nil
                    lastAssistantInsertionRefusal = message
                }
            } catch let error as OllamaCodeCompletionError where error == .cancelled {
                return
            } catch let error as OllamaCodeCompletionError where error == .stale {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                let message = "The draft, selection, mode, event, or model changed. This request was not applied."
                messages.append(Bubble(role: "assistant", content: message))
                lastAssistantInsertionStatus = nil
                lastAssistantInsertionRefusal = message
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                lastAssistantInsertionStatus = nil
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
        lastAssistantInsertionStatus = nil
        lastAssistantInsertionRefusal = nil
    }

    private func recallHistory(_ direction: AIChatPromptHistoryDirection) {
        if let recalled = AIChatPromptHistory.recall(direction: direction, from: history, index: &historyIndex) {
            prompt = recalled
        }
    }

}
