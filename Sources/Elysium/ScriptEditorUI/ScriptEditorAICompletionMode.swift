// ScriptEditorAICompletionMode.swift — explicit policy for optional Ollama inline proposals.

import Foundation

enum ScriptEditorAICompletionMode: String, CaseIterable, Identifiable {
    case off
    case manual
    case onIdle

    static let defaultsKey = "elysiumScriptEditorAICompletionMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .manual: "Manual"
        case .onIdle: "On Idle"
        }
    }

    var detail: String {
        switch self {
        case .off: "Never contact Ollama from the editor"
        case .manual: "Only request a suggestion with Option-Command-/"
        case .onIdle: "Request after a short pause; every request remains cancellable"
        }
    }

    static func persisted() -> ScriptEditorAICompletionMode {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = ScriptEditorAICompletionMode(rawValue: value)
        else { return .manual }
        return mode
    }
}

enum ScriptEditorAIRequestError: LocalizedError {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Editor AI is Off. Choose Manual or On Idle before contacting Ollama."
        }
    }
}
