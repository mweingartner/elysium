// ScriptValidator.swift — task 3.3. design.md Decision 12 / spec "Validator stages
// 0-3". Stage 2 is deliberately conservative (design.md: "it never refuses a program
// that would run; its value is the hint text for authors and models") — its job is to
// warn, never to be the actual security boundary (that is the sandbox itself, C-side).

import CryptoKit
import Foundation

public enum ScriptValidation: Equatable {
    case accepted(sourceSHA256: String)
    /// `stage` is 0-3; `message`/`hint` are address-free and <= 512 bytes; `line` is
    /// 1-based (0 when a stage has no single-line locus, e.g. a stage 1 message the
    /// compiler did not tag with a parseable line).
    case refused(stage: Int, message: String, hint: String, line: Int)
}

public enum ScriptValidator {
    private static let bannedGlobals: Set<String> = [
        "load", "loadstring", "loadfile", "dofile", "require", "collectgarbage", "rawset", "rawget",
    ]
    private static let bannedLibraryRoots: Set<String> = ["os", "io", "debug"]
    private static let fenceMarkers = [
        "```", "<|im_start|>", "<|im_end|>", "<|eot_id|>", "<<SYS>>", "[INST]",
    ]

    /// Runs stages 0-3 in order, stopping at the first refusal (design.md: "in
    /// order"). `state` supplies stage 1's real compiler (`checkSyntax`) and the
    /// stage 0 source-size cap (`ScriptBudgets.sourceBytes`); nothing is compiled or
    /// retained past stage 1 — `checkSyntax` itself discards its result.
    public static func validate(source: String, chunkName: String, using state: LuaState) -> ScriptValidation {
        if let refusal = stage0(source: source, sourceCap: state.budgets.sourceBytes) {
            return refusal
        }
        if let fault = state.checkSyntax(source: source, chunkName: chunkName) {
            return .refused(stage: 1, message: fault.message, hint: "fix the syntax error", line: parsedLine(from: fault.message))
        }
        let tokens = LuaTokenizer.tokenize(source)
        if let refusal = stage2(tokens: tokens) {
            return refusal
        }
        if let refusal = stage3(source: source) {
            return refusal
        }
        return .accepted(sourceSHA256: sha256Hex(of: source))
    }

    // MARK: - Stage 0: text hygiene

    private static func stage0(source: String, sourceCap: Int) -> ScriptValidation? {
        guard source.utf8.count <= sourceCap else {
            return .refused(
                stage: 0, message: "source exceeds \(sourceCap) bytes",
                hint: "shorten the script", line: 1
            )
        }
        if let violation = ScriptTextHygiene.firstViolation(in: source) {
            return .refused(
                stage: 0,
                message: "invalid character at \(violation.line):\(violation.column)",
                hint: "remove control characters and unusual Unicode formatting; use \\n for newlines",
                line: violation.line
            )
        }
        return nil
    }

    // MARK: - Stage 2: token lint

    private static func stage2(tokens: [LuaToken]) -> ScriptValidation? {
        let locals = localDeclaredNames(tokens)

        for (index, token) in tokens.enumerated() {
            // Builder fix (found by testFormatPRejectionGrammar): this check must
            // run before the `.name`-only guard below -- a string token can never
            // satisfy `case .name` (the two are different Token.Kind cases on the
            // same token), so placing it after the guard made it unreachable dead
            // code and let every '%p' literal through stage 2 silently.
            if case .string(let content) = token.kind, formatGrammarRejectsP(content),
                isFirstArgumentOfFormatCall(tokens: tokens, stringIndex: index) {
                return .refused(
                    stage: 2, message: "'%p' is not a permitted format conversion",
                    hint: "remove the %p conversion from the format string", line: token.line
                )
            }

            guard case .name(let name) = token.kind else { continue }
            if index > 0, isDotOrColon(tokens[index - 1].kind) { continue } // field/method position

            if bannedGlobals.contains(name), !locals.contains(name) {
                return .refused(
                    stage: 2, message: "reference to '\(name)' is not available",
                    hint: "'\(name)' is not part of the sandboxed API", line: token.line
                )
            }

            if !locals.contains(name), index + 2 < tokens.count,
                case .symbol(".") = tokens[index + 1].kind,
                case .name(let field) = tokens[index + 2].kind {
                if bannedLibraryRoots.contains(name) {
                    return .refused(
                        stage: 2, message: "reference to '\(name).\(field)' is not available",
                        hint: "'\(name)' is not part of the sandboxed API", line: token.line
                    )
                }
                if name == "string", field == "dump" {
                    return .refused(
                        stage: 2, message: "reference to 'string.dump' is not available",
                        hint: "'string.dump' is not part of the sandboxed API", line: token.line
                    )
                }
            }
        }
        return nil
    }

    private static func isDotOrColon(_ kind: LuaToken.Kind) -> Bool {
        if case .symbol(let s) = kind { return s == "." || s == ":" }
        return false
    }

    /// Every name declared by a `local` statement anywhere in the chunk (design.md:
    /// "conservative... a `local` declaration of the name anywhere in the chunk
    /// suppresses the rule").
    private static func localDeclaredNames(_ tokens: [LuaToken]) -> Set<String> {
        var names: Set<String> = []
        var i = 0
        while i < tokens.count {
            guard case .name("local") = tokens[i].kind else {
                i += 1
                continue
            }
            var j = i + 1
            if j < tokens.count, case .name("function") = tokens[j].kind {
                j += 1
                if j < tokens.count, case .name(let fname) = tokens[j].kind {
                    names.insert(fname)
                }
                i = j + 1
                continue
            }
            while j < tokens.count, case .name(let n) = tokens[j].kind {
                names.insert(n)
                j += 1
                guard j < tokens.count, case .symbol(",") = tokens[j].kind else { break }
                j += 1
            }
            i = j
        }
        return names
    }

    /// design.md Condition 28's grammar, mirrored for the lint hint (flags `-+ #0`,
    /// <= 2 width digits, optional `.` + <= 2 precision digits, conversion letter;
    /// `%%` is not a conversion).
    private static func formatGrammarRejectsP(_ format: String) -> Bool {
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else {
                i += 1
                continue
            }
            i += 1
            guard i < chars.count else { return false }
            if chars[i] == "%" {
                i += 1
                continue
            }
            while i < chars.count, "-+ #0".contains(chars[i]) { i += 1 }
            var width = 0
            while i < chars.count, width < 2, chars[i].isASCII, chars[i].isNumber { i += 1; width += 1 }
            if i < chars.count, chars[i] == "." {
                i += 1
                var precision = 0
                while i < chars.count, precision < 2, chars[i].isASCII, chars[i].isNumber { i += 1; precision += 1 }
            }
            guard i < chars.count else { return false }
            if chars[i] == "p" { return true }
            i += 1
        }
        return false
    }

    private static func isFirstArgumentOfFormatCall(tokens: [LuaToken], stringIndex: Int) -> Bool {
        guard stringIndex >= 2 else { return false }
        guard case .symbol("(") = tokens[stringIndex - 1].kind else { return false }
        guard case .name("format") = tokens[stringIndex - 2].kind else { return false }
        return true
    }

    // MARK: - Stage 3: fence / chat-template tokens

    private static func stage3(source: String) -> ScriptValidation? {
        var firstMatch: (marker: String, range: Range<String.Index>)?
        for marker in fenceMarkers {
            guard let range = source.range(of: marker) else { continue }
            if firstMatch == nil || range.lowerBound < firstMatch!.range.lowerBound {
                firstMatch = (marker, range)
            }
        }
        guard let match = firstMatch else { return nil }
        let line = 1 + source[source.startIndex..<match.range.lowerBound].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        return .refused(
            stage: 3,
            message: "source contains a disallowed fence/template token",
            hint: "remove '\(match.marker)' from the script",
            line: line
        )
    }

    // MARK: - Helpers

    private static func sha256Hex(of source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort: Lua compile errors are usually `chunkname:LINE: message`; a stage
    /// 1 refusal with no parseable line simply reports `0` (still address-free and
    /// still names the reason via `message`).
    private static func parsedLine(from message: String) -> Int {
        guard let firstColon = message.firstIndex(of: ":") else { return 0 }
        let afterFirst = message.index(after: firstColon)
        guard let secondColon = message[afterFirst...].firstIndex(of: ":") else { return 0 }
        return Int(message[afterFirst..<secondColon]) ?? 0
    }
}
