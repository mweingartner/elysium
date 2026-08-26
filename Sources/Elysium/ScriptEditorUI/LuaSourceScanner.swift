// LuaSourceScanner.swift — small, error-tolerant tokenizer for editor intelligence. It is
// deliberately independent from the sandbox validator: editor analysis must preserve UTF-16
// ranges and continue through incomplete code, while the runtime validator remains authoritative.

import Foundation

enum LuaSourceTokenKind: Equatable, Sendable {
    case identifier
    case keyword
    case string
    case number
    case symbol
    case newline
}

struct LuaSourceToken: Equatable, Sendable {
    let kind: LuaSourceTokenKind
    let text: String
    let range: NSRange

    var stringValue: String? {
        guard kind == .string, text.count >= 2 else { return nil }
        if text.hasPrefix("[[") && text.hasSuffix("]]"), text.utf8.count >= 4 {
            return String(text.dropFirst(2).dropLast(2))
        }
        guard let first = text.first, first == "\"" || first == "'", text.last == first else { return nil }
        var output = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                output.append(character)
            }
        }
        if escaped { output.append("\\") }
        return output
    }
}

enum LuaSourceScanner {
    static func tokens(in source: String) -> [LuaSourceToken] {
        let sourceUTF16 = source as NSString
        let length = sourceUTF16.length
        var tokens: [LuaSourceToken] = []
        var index = 0

        func unit(_ offset: Int) -> UInt16 {
            sourceUTF16.character(at: offset)
        }

        func isASCIILetter(_ value: UInt16) -> Bool {
            (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
        }

        func isASCIIDigit(_ value: UInt16) -> Bool {
            value >= 48 && value <= 57
        }

        func append(_ kind: LuaSourceTokenKind, from start: Int, to end: Int) {
            let range = NSRange(location: start, length: end - start)
            tokens.append(LuaSourceToken(kind: kind, text: sourceUTF16.substring(with: range), range: range))
        }

        func longBracketLevel(at start: Int) -> Int? {
            guard start < length, unit(start) == 91 else { return nil } // [
            var cursor = start + 1
            var level = 0
            while cursor < length, unit(cursor) == 61 { // =
                level += 1
                cursor += 1
            }
            return cursor < length && unit(cursor) == 91 ? level : nil
        }

        func endOfLongBracket(from bodyStart: Int, level: Int) -> Int {
            var cursor = bodyStart
            while cursor < length {
                if unit(cursor) == 93 { // ]
                    var closing = cursor + 1
                    var equalsCount = 0
                    while closing < length, unit(closing) == 61 {
                        equalsCount += 1
                        closing += 1
                    }
                    if equalsCount == level, closing < length, unit(closing) == 93 {
                        return closing + 1
                    }
                }
                cursor += 1
            }
            return length
        }

        while index < length {
            let value = unit(index)
            if value == 10 { // newline
                append(.newline, from: index, to: index + 1)
                index += 1
                continue
            }
            if value == 9 || value == 13 || value == 32 {
                index += 1
                continue
            }

            // Lua line or long comment.
            if value == 45, index + 1 < length, unit(index + 1) == 45 {
                if let level = longBracketLevel(at: index + 2) {
                    let bodyStart = index + 4 + level
                    index = endOfLongBracket(from: bodyStart, level: level)
                } else {
                    index += 2
                    while index < length, unit(index) != 10 { index += 1 }
                }
                continue
            }

            // Quoted strings. An incomplete string remains one token through EOF so completion
            // can still understand an event-name argument while the user is typing it.
            if value == 34 || value == 39 { // " or '
                let start = index
                let quote = value
                index += 1
                while index < length {
                    if unit(index) == 92 { // backslash
                        index = min(length, index + 2)
                    } else if unit(index) == quote {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                append(.string, from: start, to: index)
                continue
            }

            if let level = longBracketLevel(at: index) {
                let start = index
                let bodyStart = index + 2 + level
                index = endOfLongBracket(from: bodyStart, level: level)
                append(.string, from: start, to: index)
                continue
            }

            if isASCIILetter(value) || value == 95 { // _
                let start = index
                index += 1
                while index < length {
                    let next = unit(index)
                    guard isASCIILetter(next) || isASCIIDigit(next) || next == 95 else { break }
                    index += 1
                }
                let text = sourceUTF16.substring(with: NSRange(location: start, length: index - start))
                append(LuaSyntaxColoring.keywords.contains(text) ? .keyword : .identifier, from: start, to: index)
                continue
            }

            if isASCIIDigit(value) || (value == 46 && index + 1 < length && isASCIIDigit(unit(index + 1))) {
                let start = index
                index += 1
                while index < length {
                    let next = unit(index)
                    if isASCIIDigit(next) || isASCIILetter(next) || next == 46 || next == 95 {
                        index += 1
                    } else {
                        break
                    }
                }
                append(.number, from: start, to: index)
                continue
            }

            let start = index
            index += 1
            if index < length {
                let pair = sourceUTF16.substring(with: NSRange(location: start, length: 2))
                if ["==", "~=", "<=", ">=", "::", "..", "//", "<<", ">>"].contains(pair) {
                    index += 1
                }
                if pair == "..", index < length, unit(index) == 46 { index += 1 }
            }
            append(.symbol, from: start, to: index)
        }
        return tokens
    }
}
