// AIScriptValidationGate.swift — ai-object-graph (change 2). design.md §9.4:
// "1. size -> 2. text hygiene -> 3. compile text-only -> 4. AST lint ->
// 5. references -> 6. dry-run ... 7. Load outcome." Stages 1-4 are exactly
// `ScriptValidator.validate` (change 0/1c, `ElysiumScript`) — this file adds
// the two AI-specific stages that sit on top of it: stage 5 ("references":
// event names, attribute names per kind, refs) and the plumbing that hands
// stage 6 off to `ScriptRuntime.dryRun`. Every AI-authored `attach_script`
// call runs the whole chain; `check_script`/`/script attach` (player-
// authored) only ever need stages 0-3 (`ScriptValidator` directly).
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
// event name.

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
        switch runtime.validateSource(source, chunkName: chunkName) {
        case .refused(let stage, let message, let hint, let line):
            return .refused(AIScriptStageResult(stage: stage, message: message, hint: hint, line: line))
        case .accepted(let sha):
            if let violation = firstReferenceViolation(in: source) {
                return .refused(AIScriptStageResult(stage: 5, message: violation.message, hint: violation.hint, line: violation.line))
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

    private static func firstReferenceViolation(in source: String) -> (message: String, hint: String, line: Int)? {
        for pattern in [onCallPattern, triggerFieldPattern] {
            let ns = source as NSString
            let matches = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                let captured = ns.substring(with: match.range(at: 1))
                guard EventKind.parse(captured) == nil else { continue }
                let line = 1 + ns.substring(to: match.range.location).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                return (
                    "'\(captured)' is not a valid event name",
                    "event names are one to four '.'-separated lowercase segments, e.g. 'attribute.changed'",
                    line
                )
            }
        }
        return nil
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
