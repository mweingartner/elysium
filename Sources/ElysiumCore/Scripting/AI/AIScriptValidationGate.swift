// AIScriptValidationGate.swift — ai-object-graph (change 2). design.md §9.4:
// "1. size -> 2. text hygiene -> 3. compile text-only -> 4. AST lint ->
// 5. references -> 6. dry-run ... 7. Load outcome." Stages 1-4 are exactly
// `ScriptValidator.validate` (change 0/1c, `ElysiumScript`) — this file adds
// the two AI-specific stages that sit on top of it: stage 5 ("references":
// event names, attribute names per kind, refs) and the plumbing that hands
// stage 6 off to `ScriptRuntime.dryRun`. Every AI-authored `attach_script`
// call runs the whole chain; the chat `/script attach` command runs stages
// 0-5 (`validateForAttach` below) before storing anything.
//
// Stage 5 is deliberately literal-only and conservative, exactly like
// `ScriptValidator`'s own stage 2 (design.md: "it never refuses a program
// that would run; its value is the hint text for authors and models") — it
// scans event name literals passed to `on(...)` or an `{on = "..."}` trigger
// table for a *grammatically* invalid name (uppercase letters, punctuation,
// a leading digit — a realistic LLM capitalization/formatting mistake). It
// cannot and does not claim to catch a semantic typo that still happens to
// be grammar-valid (`"attribute.change"` instead of `"attribute.changed"`):
// custom events share the exact same grammar as catalog ones (§7.2's own
// "bare names, namespaced by convention"), so there is no closed catalog to
// check a literal against without also rejecting every legitimate custom
// event name. A near miss of a built-in is therefore only ever a non-blocking
// hint (`eventTypoWarnings`), never a refusal.

import Foundation

public struct AIScriptStageResult: Equatable {
    public var stage: Int
    public var message: String
    public var hint: String
    public var line: Int
}

public enum AIScriptValidationOutcome: Equatable {
    case accepted(sourceSHA256: String)
    case refused(AIScriptStageResult)
}

public enum AIScriptValidationGate {
    /// Runs `ScriptValidator`'s stages 0-3 (via `runtime.validateSource`)
    /// then this file's stage 5. Stage numbering matches design.md's own
    /// (stage 4 is folded into `ScriptValidator`'s stage-2 token lint; there
    /// is no separate stage-4 pass in this implementation — documented in
    /// ARCHITECTURE.md).
    public static func validate(source: String, chunkName: String, runtime: ScriptRuntime) -> AIScriptValidationOutcome {
        validate(source: source, chunkName: chunkName, runtime: runtime, literals: { eventNameLiterals(in: source) })
    }

    /// The attach path (chat `/script attach`, AI `attach_script`): `validate` plus the non-blocking
    /// event typo hints, from ONE scan of the source's event-name literals.
    public static func validateForAttach(
        source: String, chunkName: String, runtime: ScriptRuntime, isDeclared: (String) -> Bool
    ) -> (outcome: AIScriptValidationOutcome, warnings: [String]) {
        var scanned: [(name: String, location: Int)]?
        let literals = {
            if let scanned { return scanned }
            let found = eventNameLiterals(in: source)
            scanned = found
            return found
        }
        let outcome = validate(source: source, chunkName: chunkName, runtime: runtime, literals: literals)
        guard case .accepted = outcome else { return (outcome, []) }
        return (outcome, eventTypoWarnings(literals: literals(), isDeclared: isDeclared))
    }

    /// Stage 5 runs (and so scans) only once stages 0-3 accept the source.
    private static func validate(
        source: String, chunkName: String, runtime: ScriptRuntime, literals: () -> [(name: String, location: Int)]
    ) -> AIScriptValidationOutcome {
        switch runtime.validateSource(source, chunkName: chunkName) {
        case .refused(let stage, let message, let hint, let line):
            return .refused(AIScriptStageResult(stage: stage, message: message, hint: hint, line: line))
        case .accepted(let sha):
            if let invalid = literals().first(where: { EventKind.parse($0.name) == nil }) {
                return .refused(AIScriptStageResult(
                    stage: 5, message: "'\(invalid.name)' is not a valid event name",
                    hint: "event names are one to four '.'-separated lowercase segments, e.g. 'attribute.changed'",
                    line: lineNumber(atUTF16Offset: invalid.location, in: source)
                ))
            }
            return .accepted(sourceSHA256: sha)
        }
    }

    private static let onCallPattern: NSRegularExpression = {
        // `on(` followed by a double-quoted string literal — the common
        // "on(event, fn)" / "on(event, opts, fn)" sugar (design.md §8.5).
        try! NSRegularExpression(pattern: #"\bon\(\s*"([^"\n]*)""#)
    }()

    private static let triggerFieldPattern: NSRegularExpression = {
        // `on = "..."` inside a trigger options table (`h:attach(name,
        // source, {on = "attribute.changed", ...})`, design.md §8.5).
        try! NSRegularExpression(pattern: #"\bon\s*=\s*"([^"\n]*)""#)
    }()

    /// Every event-name string literal passed to `on(...)` or set as an `on = "..."` trigger field,
    /// with the UTF-16 offset of its match: all `on(` matches first, then trigger fields, each in
    /// source order. The one literal scanner shared by stage 5 and the typo hints below. Linear in
    /// the source: a line number is computed only for the literal actually reported.
    static func eventNameLiterals(in source: String) -> [(name: String, location: Int)] {
        var literals: [(name: String, location: Int)] = []
        let ns = source as NSString
        for pattern in [onCallPattern, triggerFieldPattern] {
            let matches = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                literals.append((ns.substring(with: match.range(at: 1)), match.range.location))
            }
        }
        return literals
    }

    /// The 1-based line containing UTF-16 offset `offset` of `source` (one pass over the prefix).
    static func lineNumber(atUTF16Offset offset: Int, in source: String) -> Int {
        1 + source.utf16.prefix(max(0, offset)).reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    /// At most this many literals are checked for typo hints, bounding the per-command sweep work.
    static let maxTypoCheckedLiterals = 64

    /// Non-blocking "did you mean" hints for literal event names that are well formed but are a
    /// near miss of a built-in and not declared (per `isDeclared`). Deduplicated, at most four, from
    /// the first `maxTypoCheckedLiterals` literals.
    public static func eventTypoWarnings(in source: String, isDeclared: (String) -> Bool) -> [String] {
        eventTypoWarnings(literals: eventNameLiterals(in: source), isDeclared: isDeclared)
    }

    private static func eventTypoWarnings(
        literals: [(name: String, location: Int)], isDeclared: (String) -> Bool
    ) -> [String] {
        var hints: [String] = []
        for literal in literals.prefix(maxTypoCheckedLiterals) where EventKind.parse(literal.name) != nil {
            guard let hint = ScriptNameSuggestions.eventTypoHint(
                for: literal.name, isDeclared: isDeclared(literal.name)
            ), !hints.contains(hint) else { continue }
            hints.append(hint)
            if hints.count == 4 { break }
        }
        return hints
    }
}

/// `check_script`'s query-tool payload: the validation outcome plus stage 6
/// (dry-run) only when a target `ref` was given — matches §9.2's "check_script{source} — validator
/// result without storing" (no ref in that tool's declared signature, so the
/// query path never dry-runs; `attach_script` is the only caller that does).
public enum AIScriptValidationSummary {
    public static func checkOnly(source: String) -> String {
        var out = "{\"size\":\(source.utf8.count)"
        if source.utf8.count > 16_384 {
            out += ",\"accepted\":false,\"stage\":0,\"message\":\"source exceeds 16384 bytes\"}"
            return out
        }
        out += ",\"note\":\"full compile/lint requires an active script runtime; use attach_script for the complete gate\"}"
        return out
    }
}
