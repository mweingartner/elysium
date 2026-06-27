import Foundation

public func cursorPlacementPosition(from hit: RaycastHit?) -> (x: Int, y: Int, z: Int)? {
    guard let hit else { return nil }
    return (hit.x + DIR_X[hit.face], hit.y + DIR_Y[hit.face], hit.z + DIR_Z[hit.face])
}

public func splitCommandLineArguments(_ raw: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuote: Character?
    var escaping = false
    for ch in raw {
        if escaping {
            current.append(ch)
            escaping = false
            continue
        }
        if ch == "\\" {
            escaping = true
            continue
        }
        if let quote = inQuote {
            if ch == quote {
                inQuote = nil
            } else {
                current.append(ch)
            }
            continue
        }
        if ch == "\"" || ch == "'" {
            inQuote = ch
            continue
        }
        if ch.isWhitespace {
            if !current.isEmpty {
                parts.append(current)
                current.removeAll(keepingCapacity: true)
            }
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty { parts.append(current) }
    return parts
}

public func cloneTemplateNameFromCommandArgs(_ args: [String]) -> String? {
    let lower = args.map { $0.lowercased() }
    if let idx = lower.firstIndex(of: "name"), idx + 1 < args.count {
        return args[(idx + 1)...].joined(separator: " ")
    }
    if lower.first == "target", args.count >= 2 {
        return args.dropFirst().joined(separator: " ")
    }
    if lower.count >= 2, lower[0] == "the", lower[1] == "target", args.count >= 3 {
        return args.dropFirst(2).joined(separator: " ")
    }
    return nil
}

public func placeTemplateNameFromCommandArgs(_ args: [String]) -> String? {
    let lower = args.map { $0.lowercased() }
    let hasObjectPrefix = lower.first == "object"
    guard args.count >= (hasObjectPrefix ? 2 : 1) else { return nil }
    let rest = hasObjectPrefix ? Array(args.dropFirst()) : args
    let restLower = hasObjectPrefix ? Array(lower.dropFirst()) : lower
    if let at = restLower.firstIndex(of: "at") {
        let nameParts = rest[..<at]
        return nameParts.isEmpty ? nil : nameParts.joined(separator: " ")
    }
    return rest.joined(separator: " ")
}

public struct CommandLineCompletion: Equatable {
    public let completedInput: String
    public let tokenPrefix: String
    public let replacement: String
    public let matches: [String]
    public let selectedIndex: Int?
    public let usedCommonPrefix: Bool
}

private func commandLineTokenRange(atEndOf input: String) -> Range<String.Index>? {
    if input.isEmpty { return nil }
    var start = input.endIndex
    var idx = input.endIndex
    while idx > input.startIndex {
        let prev = input.index(before: idx)
        if input[prev].isWhitespace { break }
        start = prev
        idx = prev
    }
    return start..<input.endIndex
}

private func normalizedCompletionPrefix(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "minecraft:", with: "")
        .replacingOccurrences(of: " ", with: "_")
}

public func itemCompletionCandidates(for prefix: String, limit: Int = Int.max) -> [String] {
    let p = normalizedCompletionPrefix(prefix)
    if itemDefs.isEmpty { return [] }
    let defs = itemDefs.sorted { $0.name < $1.name }
    let matches: [String]
    if p.isEmpty {
        matches = defs.map(\.name)
    } else {
        matches = defs.compactMap { def in
            let name = def.name.lowercased()
            let display = def.displayName.lowercased().replacingOccurrences(of: " ", with: "_")
            let spaced = name.replacingOccurrences(of: "_", with: " ")
            return name.hasPrefix(p) || display.hasPrefix(p) || spaced.hasPrefix(p) ? def.name : nil
        }
    }
    if limit == Int.max { return matches }
    return Array(matches.prefix(max(0, limit)))
}

private func commonPrefix(_ strings: [String]) -> String {
    guard var prefix = strings.first else { return "" }
    for value in strings.dropFirst() {
        while !value.hasPrefix(prefix), !prefix.isEmpty {
            prefix.removeLast()
        }
        if prefix.isEmpty { break }
    }
    return prefix
}

public func completeCommandLineItem(input: String, cycleIndex: Int? = nil, maxMatches: Int = Int.max) -> CommandLineCompletion? {
    guard let range = commandLineTokenRange(atEndOf: input) else { return nil }
    let rawPrefix = String(input[range])
    if rawPrefix.hasPrefix("/") { return nil }
    let matches = itemCompletionCandidates(for: rawPrefix, limit: maxMatches)
    guard !matches.isEmpty else { return nil }

    let normalizedPrefix = normalizedCompletionPrefix(rawPrefix)
    let shared = commonPrefix(matches)
    let shouldUseShared = cycleIndex == nil && matches.count > 1 && shared.count > normalizedPrefix.count
    let selectedIndex: Int?
    let replacement: String
    if shouldUseShared {
        replacement = shared
        selectedIndex = nil
    } else {
        let index = ((cycleIndex ?? 0) % matches.count + matches.count) % matches.count
        replacement = matches[index]
        selectedIndex = index
    }

    let completed = input.replacingCharacters(in: range, with: replacement)
    return CommandLineCompletion(
        completedInput: completed,
        tokenPrefix: rawPrefix,
        replacement: replacement,
        matches: matches,
        selectedIndex: selectedIndex,
        usedCommonPrefix: shouldUseShared)
}

public func wrapTextByWidth(_ text: String, maxWidth: Int, measure: (String) -> Int) -> [String] {
    guard !text.isEmpty else { return [] }
    guard maxWidth > 0 else { return [text] }

    func splitToken(_ token: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var i = token.startIndex
        while i < token.endIndex {
            var piece = String(token[i])
            var next = token.index(after: i)
            if token[i] == "§", next < token.endIndex {
                piece += String(token[next])
                next = token.index(after: next)
            }
            let candidate = current + piece
            if !current.isEmpty && measure(candidate) > maxWidth {
                pieces.append(current)
                current = piece
            } else {
                current = candidate
            }
            i = next
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    func wrapParagraph(_ paragraph: String) -> [String] {
        let words = paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        var current = ""
        for raw in words {
            if raw.isEmpty {
                if !current.isEmpty && measure(current + " ") <= maxWidth {
                    current += " "
                }
                continue
            }
            let pieces = splitToken(raw)
            for (idx, piece) in pieces.enumerated() {
                let candidate = current.isEmpty ? piece : current + " " + piece
                if !current.isEmpty && measure(candidate) > maxWidth {
                    lines.append(current)
                    current = piece
                } else {
                    current = candidate
                }
                if idx < pieces.count - 1 {
                    lines.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    var out: [String] = []
    for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let wrapped = wrapParagraph(paragraph)
        if wrapped.isEmpty {
            out.append("")
        } else {
            out.append(contentsOf: wrapped)
        }
    }
    return out
}
