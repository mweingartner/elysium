// ScriptTextHygiene.swift — task 3.3. Backs `ScriptValidator` stage 0 and the address-
// free hygiene filter design.md Condition 29 requires of every `ScriptFault.message`/
// `.traceback` and every `print` line before it reaches a `ScriptLogSink`.
//
// `elysiumValidateTextCharacter` is declared `package` in `ElysiumTextInput`
// (Sources/ElysiumTextInput/ElysiumTextInput.swift:113) and `ElysiumScript` already
// depends on that target (Package.swift) — Swift's `package` access level is visible to
// every module in the same SwiftPM package, not just the declaring module, so this file
// imports it directly rather than duplicating the predicate (design.md Decision 12).

import ElysiumTextInput

public enum ScriptTextHygiene {
    /// The first character stage 0 refuses, if any: `\n` is an accepted line break,
    /// `\t` is accepted, `\r` is always rejected (design.md Decision 12: "authoring
    /// paths normalize CRLF before validation; the validator never rewrites"), and
    /// everything else defers to `elysiumValidateTextCharacter` (C0/C1 controls,
    /// U+2028/9, noncharacters, bidi controls, private-use, unassigned, lone format
    /// characters). `line`/`column` are both 1-based.
    public static func firstViolation(in source: String) -> (line: Int, column: Int)? {
        var line = 1
        var column = 1
        for character in source {
            if character == "\n" {
                line += 1
                column = 1
                continue
            }
            if character == "\r" {
                return (line, column)
            }
            if character != "\t" {
                switch elysiumValidateTextCharacter(character) {
                case .accepted:
                    break
                case .rejected:
                    return (line, column)
                }
            }
            column += 1
        }
        return nil
    }

    public static func isClean(_ source: String) -> Bool {
        firstViolation(in: source) == nil
    }

    /// Replaces every character `elysiumValidateTextCharacter` would reject (plus
    /// `\r`) with U+FFFD; `\n`/`\t` pass through untouched. Applied to shim-produced
    /// fault messages and tracebacks as a construction-time backstop (design.md
    /// Condition 29: those are address-free *by construction* — the shim never emits a
    /// raw pointer — this filter exists only to catch a stray control character in,
    /// say, a script-supplied string error value, never to "parse out" an address).
    public static func sanitize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if character == "\n" || character == "\t" {
                result.append(character)
                continue
            }
            if character == "\r" {
                result.append("\u{FFFD}")
                continue
            }
            switch elysiumValidateTextCharacter(character) {
            case .accepted:
                result.append(character)
            case .rejected:
                result.append("\u{FFFD}")
            }
        }
        return result
    }
}
