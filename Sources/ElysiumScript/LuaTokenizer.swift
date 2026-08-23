// LuaTokenizer.swift — task 3.3. A small, source-only Lua lexer backing
// `ScriptValidator` stage 2 (design.md Decision 12: "a small Lua tokenizer in Swift...
// comments, short/long strings with levels, numbers, names, symbols"). This is
// intentionally not a full Lua grammar — it never runs on trusted input for anything
// but linting hints (stage 1's real gate is `LuaState.checkSyntax`, which uses the
// actual Lua compiler) — so a source this tokenizer cannot fully make sense of simply
// stops producing tokens rather than throwing; `ScriptValidator` treats "no lint
// finding" as acceptance, matching the "never refuses a program that would run" rule.

struct LuaToken: Equatable {
    enum Kind: Equatable {
        case name(String)
        case string(String)
        case number
        /// One or two-character punctuation/operator (`.`, `:`, `(`, `,`, `==`, ...).
        case symbol(String)
    }
    let kind: Kind
    let line: Int
    let column: Int
}

enum LuaTokenizer {
    static func tokenize(_ source: String) -> [LuaToken] {
        var scanner = Scanner(source: source)
        var tokens: [LuaToken] = []
        while let token = scanner.next() {
            tokens.append(token)
        }
        return tokens
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0
        var line = 1
        var column = 1

        init(source: String) {
            self.chars = Array(source)
        }

        var isAtEnd: Bool { i >= chars.count }

        mutating func advance() -> Character {
            let c = chars[i]
            i += 1
            if c == "\n" { line += 1; column = 1 } else { column += 1 }
            return c
        }

        func peek(_ offset: Int = 0) -> Character? {
            let idx = i + offset
            return idx < chars.count ? chars[idx] : nil
        }

        func isNameStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
        func isNameContinuation(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

        /// If positioned at `[`, `[=`, `[==`, ... followed by another `[`, returns the
        /// `=` level and leaves the scanner past the opening bracket; otherwise leaves
        /// the scanner untouched and returns `nil`.
        mutating func matchLongBracketOpen() -> Int? {
            guard peek() == "[" else { return nil }
            var offset = 1
            var level = 0
            while peek(offset) == "=" { level += 1; offset += 1 }
            guard peek(offset) == "[" else { return nil }
            for _ in 0...offset { _ = advance() }
            // Lua skips a first newline immediately after the opening long bracket.
            if peek() == "\n" { _ = advance() }
            return level
        }

        mutating func readLongBracketBody(level: Int) -> String {
            var s = ""
            while !isAtEnd {
                if peek() == "]" {
                    var offset = 1
                    var eq = 0
                    while peek(offset) == "=" { eq += 1; offset += 1 }
                    if eq == level, peek(offset) == "]" {
                        for _ in 0...offset { _ = advance() }
                        return s
                    }
                }
                s.append(advance())
            }
            return s
        }

        mutating func next() -> LuaToken? {
            while !isAtEnd {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\r" || c == "\n" {
                    _ = advance()
                    continue
                }
                if c == "-", peek(1) == "-" {
                    _ = advance()
                    _ = advance()
                    if let level = matchLongBracketOpen() {
                        _ = readLongBracketBody(level: level)
                    } else {
                        while !isAtEnd, chars[i] != "\n" { _ = advance() }
                    }
                    continue
                }
                break
            }
            guard !isAtEnd else { return nil }

            let startLine = line
            let startColumn = column
            let c = chars[i]

            if isNameStart(c) {
                var s = ""
                while !isAtEnd, isNameContinuation(chars[i]) { s.append(advance()) }
                return LuaToken(kind: .name(s), line: startLine, column: startColumn)
            }

            if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                while !isAtEnd {
                    let d = chars[i]
                    if d.isHexDigit || d == "." || d == "x" || d == "X" {
                        _ = advance()
                    } else if (d == "e" || d == "E" || d == "p" || d == "P"),
                        let sign = peek(1), (sign == "+" || sign == "-" || sign.isNumber) {
                        _ = advance()
                    } else if (d == "+" || d == "-") {
                        _ = advance()
                    } else {
                        break
                    }
                }
                return LuaToken(kind: .number, line: startLine, column: startColumn)
            }

            if c == "\"" || c == "'" {
                let quote = advance()
                var s = ""
                while !isAtEnd, chars[i] != quote, chars[i] != "\n" {
                    if chars[i] == "\\", peek(1) != nil {
                        _ = advance()
                        s.append(advance())
                    } else {
                        s.append(advance())
                    }
                }
                if !isAtEnd, chars[i] == quote { _ = advance() }
                return LuaToken(kind: .string(s), line: startLine, column: startColumn)
            }

            if c == "[", let level = matchLongBracketOpen() {
                let s = readLongBracketBody(level: level)
                return LuaToken(kind: .string(s), line: startLine, column: startColumn)
            }

            // Symbol/operator, with the two-character forms Lua actually has.
            let first = advance()
            let twoChar = "\(first)\(peek() ?? " ")"
            let twoCharOperators: Set<String> = ["==", "~=", "<=", ">=", "..", "::", "//"]
            if twoCharOperators.contains(twoChar) {
                _ = advance()
                if twoChar == "..", peek() == "." {
                    _ = advance()
                    return LuaToken(kind: .symbol("..."), line: startLine, column: startColumn)
                }
                return LuaToken(kind: .symbol(twoChar), line: startLine, column: startColumn)
            }
            return LuaToken(kind: .symbol(String(first)), line: startLine, column: startColumn)
        }
    }
}
