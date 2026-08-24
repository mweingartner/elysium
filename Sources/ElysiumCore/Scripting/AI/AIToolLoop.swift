// AIToolLoop.swift — ai-object-graph (change 2). design.md §9.1: the bounded
// tool loop itself — lanes, turn/mutation/retry budgets, the refusal
// envelope, malformed tool-call repair, and the give-up/fallback paths. Pure
// and network-free: the actual HTTP round-trip to Ollama is injected as an
// `AIChatTransport` closure, so this whole file (and therefore the entire
// loop's control flow) is headless-testable with a fake transport — the app
// layer (`Sources/Elysium/OllamaAgent.swift`) only ever implements
// `AIChatTransport` and calls `AIToolLoop.run`.

import Foundation

public enum AIChatRole: String, Equatable, Sendable {
    case system, user, assistant, tool
}

public struct AIChatMessage: Equatable, Sendable {
    public var role: AIChatRole
    public var content: String
    /// Set only for `role == .tool` — which tool this result answers.
    public var toolName: String?

    public init(role: AIChatRole, content: String, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolName = toolName
    }
}

/// One tool call the model asked for, already reduced to a name + a raw
/// JSON arguments object text — whether it arrived as a native Ollama
/// `tool_calls` entry or was rescued from the message content by
/// `AIToolCallRepair`.
public struct AIToolCallRequest: Equatable, Sendable {
    public var name: String
    public var argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// One `/api/chat` round trip's result, already normalized by the transport.
/// `nil` from the transport itself (not this type) means "the request
/// failed outright" (no Ollama, network error, timeout) — see
/// `AIChatTransport`.
public struct AIChatTurn: Equatable, Sendable {
    public var content: String?
    public var toolCalls: [AIToolCallRequest]

    public init(content: String?, toolCalls: [AIToolCallRequest] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

/// The network seam. Production (`Sources/Elysium/OllamaAgent.swift`) posts
/// `messages`/`tools` to local Ollama's `/api/chat` (or, for a tool-less
/// model, schema-constrained JSON emulating one call per turn — §9.1) off
/// the calling thread and normalizes the response into one `AIChatTurn`; a
/// `nil` result means the transport itself failed (fallback path — §9.1's
/// "fallback on model absence"). **Contract**: the transport MUST invoke
/// `completion` on the same thread/queue `AIToolLoop.run` itself was called
/// from (the app layer always hops back to main before calling it — the
/// same discipline every other network callback in this codebase already
/// follows) — `AIToolLoop` performs tool dispatch (which touches live game
/// state) synchronously inside that callback, never on a background thread,
/// so the game's single-threaded simulation invariant holds even though the
/// network round trip itself never blocks it. Tests inject a fake closure
/// that calls `completion` synchronously with canned turns, including
/// malformed/refusal/oversized cases.
public typealias AIChatTransport = (_ messages: [AIChatMessage], _ tools: [AIToolDefinition], _ completion: @escaping (AIChatTurn?) -> Void) -> Void

public struct AIToolLoopResult: Equatable {
    public var transcript: [AIChatMessage]
    public var finalMessage: String
    public var mutationsApplied: Int
    public var requestID: UInt64
    /// `true` only when the loop reached a real final answer from the model
    /// (as opposed to a transport failure or the turn budget running out) —
    /// lets the caller phrase "the AI gave up" differently from a normal
    /// closing message.
    public var completedNormally: Bool
}

/// design.md §9.1: "`AIAgentSkillDefinition` gains `kind: .query | .mutation`
/// and per-skill typed argument decoding" — implemented here as a sibling
/// tool-list type (`AIToolDefinition`, `AIObjectGraphQueryTools.definitions`
/// + `AIObjectGraphMutationTools.definitions`) rather than retrofitting the
/// large, separately-owned `AIAgentSkillDefinition`/`allAIAgentSkills` list
/// the "world" lane already uses — smaller blast radius on code the earlier
/// phases already shipped and tested; documented in ARCHITECTURE.md.
public final class AIToolLoop {
    public static let maxTurns = 8
    public static let maxMutationsPerRequest = 4
    public static let maxRetriesPerTool = 3
    /// The full "scripting" lane tool list — every query then every
    /// mutation tool, in the fixed order §9.2/§9.3 declare them (also the
    /// order the app layer renders them to the model, so the tool schema is
    /// byte-stable across turns of one request, matching §9.1's "the
    /// prefix is byte-stable... for Ollama's KV cache").
    public static let allDefinitions: [AIToolDefinition] = AIObjectGraphQueryTools.definitions + AIObjectGraphMutationTools.definitions

    private let queryContext: AIQueryContext
    private let mutationContext: AIMutationContext
    private let transport: AIChatTransport
    private let nonce: String

    public init(queryContext: AIQueryContext, mutationContext: AIMutationContext, transport: @escaping AIChatTransport, nonce: String = AIToolLoop.randomNonce()) {
        self.queryContext = queryContext
        self.mutationContext = mutationContext
        self.transport = transport
        self.nonce = nonce
    }

    public static func randomNonce() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    /// design.md §9.1: "lane = classify(request) -- 'scripting' ... | 'world'
    /// ... ; Direct keyword parsers yield to the loop when the request
    /// contains scripting vocabulary." A deliberately generous keyword
    /// heuristic — a false positive just means an ordinary world-building
    /// request goes through the (strictly more capable) tool loop instead of
    /// the single-shot world-skill path, which still works; a false
    /// negative sends a scripting request through the unchanged world lane,
    /// where it will simply fail to find a matching skill and get a plain
    /// "I don't understand" — never a crash, never a silent no-op.
    public static func isScriptingRequest(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let keywords = [
            "script", "attach", "attribute", "attr ", "event", "subscribe", "trigger", "handler",
            "emit", "inspect", "object graph", "lua", "unsubscribe", "journal", "undo",
        ]
        return keywords.contains { lowered.contains($0) }
    }

    /// Runs the bounded loop. `systemPrompt` is the stable prefix (rules +
    /// generated Lua/attribute guide, §9.1); `userPrompt` is the player's
    /// request text. `completion` fires exactly once, on whatever
    /// thread/queue the transport's own completions arrive on (§9.1's own
    /// per-turn progress could be surfaced by a caller wrapping `transport`
    /// to also report progress before calling its completion — not done by
    /// this type itself).
    public func run(systemPrompt: String, userPrompt: String, completion: @escaping (AIToolLoopResult) -> Void) {
        let messages: [AIChatMessage] = [
            AIChatMessage(role: .system, content: systemPrompt),
            AIChatMessage(role: .user, content: userPrompt),
        ]
        step(turnsRemaining: Self.maxTurns, messages: messages, mutationsApplied: 0, retryCounts: [:], completion: completion)
    }

    private func step(
        turnsRemaining: Int, messages: [AIChatMessage], mutationsApplied: Int, retryCounts: [String: Int],
        completion: @escaping (AIToolLoopResult) -> Void
    ) {
        guard turnsRemaining > 0 else {
            completion(AIToolLoopResult(
                transcript: messages, finalMessage: "reached the turn limit without a final answer",
                mutationsApplied: mutationsApplied, requestID: mutationContext.requestID, completedNormally: false
            ))
            return
        }
        transport(messages, Self.allDefinitions) { [self] turn in
            guard let turn else {
                completion(AIToolLoopResult(
                    transcript: messages, finalMessage: "the AI is unavailable right now (no local Ollama response)",
                    mutationsApplied: mutationsApplied, requestID: mutationContext.requestID, completedNormally: false
                ))
                return
            }

            var calls = turn.toolCalls
            if calls.isEmpty {
                if let content = turn.content, let repaired = AIToolCallRepair.repair(content) {
                    calls = [repaired]
                } else {
                    let final = turn.content ?? ""
                    var next = messages
                    next.append(AIChatMessage(role: .assistant, content: final))
                    completion(AIToolLoopResult(
                        transcript: next, finalMessage: final, mutationsApplied: mutationsApplied,
                        requestID: mutationContext.requestID, completedNormally: true
                    ))
                    return
                }
            }

            var next = messages
            next.append(AIChatMessage(role: .assistant, content: turn.content ?? ""))
            var applied = mutationsApplied
            var retries = retryCounts

            for call in calls {
                guard let def = Self.allDefinitions.first(where: { $0.name == call.name }) else {
                    next.append(toolResultMessage(.refuse(stage: "args", message: "'\(call.name)' is not a known tool"), name: call.name))
                    continue
                }
                if def.kind == .mutation, applied >= Self.maxMutationsPerRequest {
                    next.append(toolResultMessage(
                        .refuse(stage: "budget", message: "mutation limit reached for this request (max \(Self.maxMutationsPerRequest))"),
                        name: call.name
                    ))
                    continue
                }
                let retryCount = retries[call.name, default: 0]
                if retryCount >= Self.maxRetriesPerTool {
                    next.append(toolResultMessage(
                        .refuse(stage: "budget", message: "too many failed attempts calling '\(call.name)' this request"),
                        name: call.name
                    ))
                    continue
                }
                guard let args = AIToolArguments(json: call.argumentsJSON) else {
                    retries[call.name] = retryCount + 1
                    next.append(toolResultMessage(
                        .refuse(stage: "args", message: "arguments were not valid JSON", hint: "resend as a JSON object matching the tool's parameters"),
                        name: call.name
                    ))
                    continue
                }
                // Tool dispatch runs synchronously, inline, right here — by
                // `AIChatTransport`'s own contract this closure is already
                // executing on the thread `run` was called from (main, in
                // production), so touching live game state through
                // `queryContext`/`mutationContext` is safe.
                let outcome: AIToolOutcome = def.kind == .query
                    ? AIObjectGraphQueryTools.run(call.name, args: args, context: queryContext)
                    : AIObjectGraphMutationTools.run(call.name, args: args, context: mutationContext)
                if outcome.refused {
                    retries[call.name] = retryCount + 1
                } else if def.kind == .mutation {
                    applied += 1
                }
                next.append(toolResultMessage(outcome, name: call.name))
            }

            step(turnsRemaining: turnsRemaining - 1, messages: next, mutationsApplied: applied, retryCounts: retries, completion: completion)
        }
    }

    private func toolResultMessage(_ outcome: AIToolOutcome, name: String) -> AIChatMessage {
        AIChatMessage(role: .tool, content: AIToolEnvelope.wrap(outcome, nonce: nonce), toolName: name)
    }
}

/// design.md §9.1: "tool-call text repair: `{"name":…,"arguments":…}` or
/// fenced JSON in content is rescued (Hype's `HypeAIResponseRepair`)." A
/// tool-less/misbehaving model sometimes prints the call as plain text
/// instead of using the API's native tool-call channel; this recovers the
/// common shapes rather than treating that turn as a final answer.
public enum AIToolCallRepair {
    public static func repair(_ content: String) -> AIToolCallRequest? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = parse(trimmed) { return direct }
        if let fenced = extractFenced(trimmed), let parsed = parse(fenced) { return parsed }
        if let braces = extractOutermostBraces(trimmed), let parsed = parse(braces) { return parsed }
        return nil
    }

    private static func parse(_ text: String) -> AIToolCallRequest? {
        guard text.utf8.count <= 16_384, let data = text.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
        let argsValue = obj["arguments"] ?? obj["args"] ?? [String: Any]()
        guard JSONSerialization.isValidJSONObject(argsValue) || argsValue is [String: Any] else { return nil }
        let argsObject = (argsValue as? [String: Any]) ?? [:]
        guard let argsData = try? JSONSerialization.data(withJSONObject: argsObject) else { return nil }
        guard let argsJSON = String(data: argsData, encoding: .utf8) else { return nil }
        return AIToolCallRequest(name: name, argumentsJSON: argsJSON)
    }

    private static func extractFenced(_ text: String) -> String? {
        guard let start = text.range(of: "```") else { return nil }
        var afterFence = text[start.upperBound...]
        if afterFence.hasPrefix("json") { afterFence = afterFence.dropFirst(4) }
        guard let end = afterFence.range(of: "```") else { return nil }
        return String(afterFence[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the first `{...}` span with balanced braces (skipping braces
    /// inside string literals) — rescues a tool call the model wrapped in a
    /// sentence ("I'll call attach_script: {...}").
    private static func extractOutermostBraces(_ text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = firstBrace
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[firstBrace...i]) }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
