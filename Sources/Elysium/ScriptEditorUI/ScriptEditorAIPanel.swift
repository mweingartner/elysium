// ScriptEditorAIPanel.swift — native SwiftUI script editor (Stage A). The collapsible right-hand
// AI chat column: transcript bubbles + auto-scroll + "Working…" (ported from Hype's
// `Hype/Views/ScriptEditorAIView.swift`), wired to Elysium's own agent
// (`elysiumOllamaAgent.runToolLoop(prompt:game:reportLine:)` / `.cancelToolLoop()`) instead of
// Hype's `HypeAIConfiguration` client. Shows the currently selected model
// (`game.settings.aiOllamaModel`) with a picker (`elysiumOllamaAgent.fetchModels`), prompt
// history via ↑/↓ (`AIChatPromptHistory`), and an auto-growing input (`AutoGrowingTextInput`).
// Detects a fenced ```lua block in the final reply and offers "Insert into editor".

import SwiftUI
import ElysiumCore

struct ScriptEditorAIPanel: View {
    @ObservedObject var model: ScriptEditorModel
    @Environment(\.scriptEditorTheme) private var theme

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
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let luaBlock = lastAssistantLuaBlock {
                HStack {
                    SwiftUI.Button {
                        model.insertAtCursor(luaBlock)
                    } label: {
                        Label("Insert into editor", systemImage: "arrow.down.doc")
                    }
                    .font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, theme.spacing)
                .padding(.top, 4)
            }
            Divider()
            inputArea
        }
        .background(theme.panelBackground.color)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.sparkles")
                .foregroundColor(.secondary)
            Text("Script AI")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            Menu {
                if availableModels.isEmpty {
                    Text(isFetchingModels ? "Loading…" : "No local models found")
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
                }
            } label: {
                Text(model.aiModelName.isEmpty ? "Choose model" : model.aiModelName)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onAppear(perform: refreshModels)

            if !messages.isEmpty {
                SwiftUI.Button {
                    messages.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
        }
        .padding(.horizontal, theme.spacing)
        .padding(.vertical, 6)
        .background(theme.toolbarBackground.color)
    }

    private func refreshModels() {
        guard availableModels.isEmpty, !isFetchingModels else { return }
        isFetchingModels = true
        elysiumOllamaAgent.fetchModels { result in
            isFetchingModels = false
            if case .success(let names) = result {
                availableModels = names
            }
        }
    }

    // MARK: - transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.spacing) {
                    if messages.isEmpty {
                        Text("Ask about \(model.targetDisplayName)'s scripts, or request one.")
                            .font(.system(size: 11))
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
                                .font(.system(size: 11))
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
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(message.content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(message.role == "user" ? Color.accentColor.opacity(0.15) : theme.background.color)
                .cornerRadius(theme.cornerRadiusSmall)
        }
        .padding(.horizontal, theme.spacing)
    }

    /// Fenced ```lua (or a bare ```) block in the most recent assistant message, if any — used to
    /// show "Insert into editor".
    private var lastAssistantLuaBlock: String? {
        guard let last = messages.last(where: { $0.role == "assistant" }) else { return nil }
        return Self.extractFencedCode(last.content)
    }

    static func extractFencedCode(_ text: String) -> String? {
        guard let openRange = text.range(of: "```") else { return nil }
        var rest = text[openRange.upperBound...]
        if let firstNewline = rest.firstIndex(of: "\n") {
            let langTag = rest[rest.startIndex..<firstNewline].trimmingCharacters(in: .whitespaces)
            if langTag.isEmpty || langTag.lowercased() == "lua" {
                rest = rest[rest.index(after: firstNewline)...]
            }
        }
        guard let closeRange = rest.range(of: "```") else { return nil }
        let body = String(rest[rest.startIndex..<closeRange.lowerBound])
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - input

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Ask Script AI…")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                        .padding(8)
                        .allowsHitTesting(false)
                }
                AutoGrowingTextInput(
                    text: $prompt,
                    contentHeight: $promptContentHeight,
                    isEnabled: !isProcessing,
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
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(theme.spacing)
    }

    private func send() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isProcessing else { return }
        history = AIChatPromptHistory.appending(request, to: history)
        historyIndex = -1
        messages.append(Bubble(role: "user", content: request))
        prompt = ""
        isProcessing = true
        elysiumOllamaAgent.runToolLoop(prompt: request, game: model.game) { line in
            // `reportLine` fires once with the "thinking…" status and once with the final
            // "<Elysium AI> …" reply (or a refusal) — every line is meaningful transcript
            // content, so it is appended verbatim rather than filtered.
            messages.append(Bubble(role: "assistant", content: Self.stripChatColorCodes(line)))
            isProcessing = false
        }
    }

    private func stop() {
        elysiumOllamaAgent.cancelToolLoop()
        isProcessing = false
    }

    private func recallHistory(_ direction: AIChatPromptHistoryDirection) {
        if let recalled = AIChatPromptHistory.recall(direction: direction, from: history, index: &historyIndex) {
            prompt = recalled
        }
    }

    /// `reportLine` carries Elysium's `§`-prefixed chat color codes (`§7`, `§c`, `§d`, …) meant
    /// for the in-world chat overlay — stripped here so the AI panel's plain-text bubbles don't
    /// show raw section-sign codes.
    private static func stripChatColorCodes(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            if ch == "\u{00A7}" { _ = iterator.next(); continue }
            out.append(ch)
        }
        return out
    }
}
