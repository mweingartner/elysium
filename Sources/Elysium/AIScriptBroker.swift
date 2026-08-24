// AIScriptBroker.swift — ai-object-graph (change 2). design.md §9.6: "script:
// ai.ask/ai.await -> ScriptRuntime.aiOutbox ; app (per frame, next to
// tickReplication): drain outbox -> OllamaAgentService.generateText... ->
// inbox; tick(): phase step 3 drains the inbox in requestId order ->
// ai.replied events / resumptions." All networking stays inside
// `OllamaAgentService` (`Sources/Elysium/OllamaAgent.swift`) — the one file
// `scripts/security-scan.sh` allowlists for network APIs/the local Ollama URL
// literal — this file only wires `ScriptRuntime`'s outbox-handoff seam to it
// and is called once per frame from `main.swift`, next to `tickReplication`.

import ElysiumCore
import Foundation

enum AIScriptBroker {
    /// Idempotent: re-registers the handoff closure only when the current
    /// session's `ScriptRuntime` doesn't have one yet (a fresh `ScriptRuntime`
    /// is created every `enterWorld`, so this naturally re-wires itself each
    /// session without needing its own "world entered" hook).
    static func pump(game: GameCore) {
        guard game.hasWorld(), let runtime = game.scripting.scriptRuntime, runtime.outboxHandoff == nil else { return }
        runtime.outboxHandoff = { [weak game, weak runtime] id, prompt in
            // `runtime` is captured weakly and re-checked by identity (not
            // just `game.hasWorld()`) before every delivery below: `GameCore`
            // itself outlives one world session, and a fresh `ScriptRuntime`
            // restarts its own request-id counter from 1 every `enterWorld`
            // — without the identity check, a reply that arrives after the
            // player has exited to the title screen and entered a *different*
            // world could be misdelivered to that new session's runtime under
            // a coincidentally-reused id.
            guard let game, game.hasWorld(), let runtime else { return }
            let model = sanitizedOllamaModelName(game.settings.aiOllamaModel)
            guard !model.isEmpty, isAllowedLocalOllamaModelName(model) else {
                runtime.submitAIReply(id: id, text: nil, error: "no model configured")
                return
            }
            elysiumOllamaAgent.generateScriptReply(requestID: id, model: model, prompt: prompt, maxChars: 2_000) { [weak game, weak runtime] text, error in
                guard let game, game.hasWorld(), let runtime, game.scripting.scriptRuntime === runtime else { return }
                runtime.submitAIReply(id: id, text: text, error: error)
            }
        }
    }

    /// Called on world exit, before `ScriptRuntime` is torn down — cancels
    /// every in-flight broker request so a late reply never targets a
    /// session that no longer exists.
    static func cancelAll() {
        elysiumOllamaAgent.cancelAllScriptRequests()
    }
}
