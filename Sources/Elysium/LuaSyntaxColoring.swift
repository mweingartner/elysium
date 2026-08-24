// LuaSyntaxColoring.swift — scripting-ui-and-replication (change 3). design.md §12 "Phase 3
// polishes it (syntax colouring)". A small, deterministic, UI-side-only Lua lexer for the full
// `ScriptEditorScreen` editor — deliberately NOT a reuse of `ElysiumScript`'s own internal
// `LuaTokenizer` (change 0's validator-stage tokenizer): that type's `LuaToken` never
// represents comments or whitespace at all (both are silently skipped, which is correct for a
// *linter* but wrong for a *paint every character* syntax highlighter), and `Elysium` (this
// module) does not depend on `ElysiumScript` — only `ElysiumCore` re-exports the one predicate
// (`ScriptingDisplayText.isValidScriptSource`) the editor actually needs from that boundary.
// This tokenizer never runs on trusted input for anything but display color — the real gate is
// still `ScriptRuntime.validateSource` (`ScriptValidationResult`, `ElysiumCore`).
//
// The editor stores source as `[String]` (one entry per line, no embedded `\n` — see
// `ScriptEditorScreen`'s own comment on why), so this colors one line at a time, threading a
// small `LuaSyntaxLineState` across lines for constructs that span more than one (`--[[ ]]`
// long comments, `[[ ]]`/`[=[ ]=]` long strings).

enum LuaSyntaxSpanKind: Equatable {
    case plain
    case keyword
    case string
    case comment
    case number
}

struct LuaSyntaxSpan: Equatable {
    let kind: LuaSyntaxSpanKind
    let range: Range<Int>
}

enum LuaSyntaxLineState: Equatable {
    case normal
    case inLongComment(level: Int)
    case inLongString(level: Int)
}

enum LuaSyntaxColoring {
    private static let keywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
        "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
    ]

    /// Colors one line, given the multi-line state carried in from the end of the previous
    /// line. Returns non-overlapping, left-to-right, gap-free-only-where-covered spans (callers
    /// paint uncovered gaps as `.plain`) and the state to carry into the next line.
    static func colorLine(_ line: String, state: LuaSyntaxLineState) -> (spans: [LuaSyntaxSpan], nextState: LuaSyntaxLineState) {
        let chars = Array(line)
        var spans: [LuaSyntaxSpan] = []
        var i = 0
        var carry = state

        func appendSpan(_ kind: LuaSyntaxSpanKind, _ start: Int, _ end: Int) {
            guard end > start else { return }
            spans.append(LuaSyntaxSpan(kind: kind, range: start..<end))
        }

        switch carry {
        case .inLongComment(let level), .inLongString(let level):
            let kind: LuaSyntaxSpanKind = { if case .inLongComment = carry { return .comment } else { return .string } }()
            if let end = findLongBracketClose(chars, from: 0, level: level) {
                appendSpan(kind, 0, end)
                i = end
                carry = .normal
            } else {
                appendSpan(kind, 0, chars.count)
                return (spans, carry)
            }
        case .normal:
            break
        }

        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\r" {
                i += 1
                continue
            }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                let start = i
                if let level = matchLongBracketOpen(chars, at: i + 2) {
                    let bodyStart = i + 2 + 2 + level
                    if let end = findLongBracketClose(chars, from: bodyStart, level: level) {
                        appendSpan(.comment, start, end)
                        i = end
                    } else {
                        appendSpan(.comment, start, chars.count)
                        carry = .inLongComment(level: level)
                        i = chars.count
                    }
                } else {
                    appendSpan(.comment, start, chars.count)
                    i = chars.count
                }
                continue
            }
            if c == "\"" || c == "'" {
                let quote = c
                let start = i
                i += 1
                while i < chars.count, chars[i] != quote {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                if i < chars.count { i += 1 }
                appendSpan(.string, start, i)
                continue
            }
            if c == "[", let level = matchLongBracketOpen(chars, at: i) {
                let start = i
                let bodyStart = i + 2 + level
                if let end = findLongBracketClose(chars, from: bodyStart, level: level) {
                    appendSpan(.string, start, end)
                    i = end
                } else {
                    appendSpan(.string, start, chars.count)
                    carry = .inLongString(level: level)
                    i = chars.count
                }
                continue
            }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                let start = i
                while i < chars.count, chars[i].isHexDigit || chars[i] == "." || chars[i] == "x" || chars[i] == "X" {
                    i += 1
                }
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    let save = i
                    i += 1
                    if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
                    if i < chars.count, chars[i].isNumber {
                        while i < chars.count, chars[i].isNumber { i += 1 }
                    } else {
                        i = save
                    }
                }
                appendSpan(.number, start, i)
                continue
            }
            if c == "_" || c.isLetter {
                let start = i
                while i < chars.count, chars[i] == "_" || chars[i].isLetter || chars[i].isNumber {
                    i += 1
                }
                let word = String(chars[start..<i])
                appendSpan(keywords.contains(word) ? .keyword : .plain, start, i)
                continue
            }
            let start = i
            i += 1
            appendSpan(.plain, start, i)
        }
        return (spans, carry)
    }

    /// Colors every line of a full source, threading state from `.normal` at line 0 — the
    /// editor's own draw path calls this fresh (source sizes are capped at 16 KiB, a few
    /// hundred lines at most, so recomputing on every frame the screen is open is cheap and
    /// keeps this function the single source of truth rather than an incrementally-maintained
    /// cache that could drift from the actual text).
    static func colorLines(_ lines: [String]) -> [[LuaSyntaxSpan]] {
        var state = LuaSyntaxLineState.normal
        var out: [[LuaSyntaxSpan]] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let (spans, next) = colorLine(line, state: state)
            out.append(spans)
            state = next
        }
        return out
    }

    private static func matchLongBracketOpen(_ chars: [Character], at index: Int) -> Int? {
        guard index < chars.count, chars[index] == "[" else { return nil }
        var offset = 1
        var level = 0
        while index + offset < chars.count, chars[index + offset] == "=" {
            level += 1
            offset += 1
        }
        guard index + offset < chars.count, chars[index + offset] == "[" else { return nil }
        return level
    }

    private static func findLongBracketClose(_ chars: [Character], from: Int, level: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == "]" {
                var offset = 1
                var eq = 0
                while i + offset < chars.count, chars[i + offset] == "=" {
                    eq += 1
                    offset += 1
                }
                if eq == level, i + offset < chars.count, chars[i + offset] == "]" {
                    return i + offset + 1
                }
            }
            i += 1
        }
        return nil
    }
}
