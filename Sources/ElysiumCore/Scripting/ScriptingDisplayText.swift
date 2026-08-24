// ScriptingDisplayText.swift — object-graph-attributes (change 1a). design.md
// Decision 10 / spec `scripting-commands` "Display hygiene". Applied to
// *every* output line `ScriptingCommands` produces — never only to attribute
// values — so a saved string can never inject a formatting code, a bidi
// override, or a second chat line.

import ElysiumScript

public enum ScriptingDisplayText {
    /// script-runtime (change 1c): the `ScriptEditorScreen`'s paste path
    /// needs stage 0's exact hygiene check (`\n`/`\t` accepted, everything
    /// `elysiumValidateTextCharacter` itself would reject refused) — this
    /// thin re-export keeps `Sources/Elysium` from importing `ElysiumScript`
    /// directly just for one predicate (`ElysiumScript` stays an
    /// `ElysiumCore`-internal implementation detail, not a second public
    /// surface the app target reaches into).
    public static func isValidScriptSource(_ text: String) -> Bool {
        ScriptTextHygiene.isClean(text)
    }

    /// `ScriptTextHygiene.sanitize` (strips C0/C1 and Unicode format/bidi
    /// controls), then `\n`/`\r`/`\t` folded to a single space (a display
    /// line is always exactly one physical line), then `§` replaced by a
    /// space (Elysium's own color-code marker — never let saved/attacker text
    /// re-color chat), then truncated to 256 UTF-8 bytes with a trailing `…`
    /// when cut (truncation lands on a `Character` — extended grapheme
    /// cluster — boundary, never mid codepoint and never splitting a
    /// combining mark or ZWJ sequence).
    public static func line(_ text: String) -> String {
        var sanitized = ScriptTextHygiene.sanitize(text)
        sanitized = String(sanitized.map { ch -> Character in
            switch ch {
            case "\n", "\r", "\t": return " "
            case "§": return " "
            default: return ch
            }
        })
        return truncateUTF8(sanitized, toByteCount: 256)
    }
}

/// Truncates `s` to at most `limit` UTF-8 bytes on a `Character` (extended
/// grapheme cluster) boundary — never splitting a base scalar from a
/// combining mark or a ZWJ emoji sequence (design.md Decision 4; Security
/// (code) SC-3 / Test N3) — appending `…` (3 bytes) when truncation actually
/// happened. The result is therefore never more than `limit` bytes.
func truncateUTF8(_ s: String, toByteCount limit: Int) -> String {
    guard s.utf8.count > limit else { return s }
    let ellipsis = "…"
    let budget = max(0, limit - ellipsis.utf8.count)
    var result = ""
    var bytes = 0
    for ch in s {
        let charBytes = String(ch).utf8.count
        guard bytes + charBytes <= budget else { break }
        result.append(ch)
        bytes += charBytes
    }
    return result + ellipsis
}
