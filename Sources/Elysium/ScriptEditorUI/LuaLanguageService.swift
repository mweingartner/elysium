// LuaLanguageService.swift — deterministic, side-effect-free language intelligence for the
// native editor. The parser is intentionally error tolerant: it extracts scopes and useful types
// from an incomplete 16 KiB document while the runtime's real validator remains the final gate.

import Foundation
import ElysiumCore

enum LuaLanguageService {
    static func analyze(source: String, environment: LuaLanguageEnvironment) -> LuaLanguageAnalysis {
        let tokens = LuaSourceScanner.tokens(in: source)
        let symbols = collectSymbols(tokens: tokens, environment: environment)
        let symbolTable = Dictionary(symbols.map { ($0.name, $0.type) }, uniquingKeysWith: { _, latest in latest })
        let semanticTokens = semanticTokens(
            source: source, tokens: tokens, symbols: symbols, symbolTable: symbolTable, environment: environment
        )
        let diagnostics = diagnostics(
            source: source, tokens: tokens, symbolTable: symbolTable, environment: environment
        )
        return LuaLanguageAnalysis(
            semanticTokens: semanticTokens,
            symbols: symbols,
            diagnostics: diagnostics
        )
    }

    static func completions(
        source: String,
        cursorUTF16: Int,
        environment: LuaLanguageEnvironment,
        analysis suppliedAnalysis: LuaLanguageAnalysis? = nil
    ) -> LuaCompletionResult {
        let sourceLength = (source as NSString).length
        let cursor = min(max(0, cursorUTF16), sourceLength)
        let tokens = LuaSourceScanner.tokens(in: source)
        let analysis = suppliedAnalysis ?? analyze(source: source, environment: environment)
        let visibleSymbols = analysis.symbols.filter { $0.declarationRange.location < cursor }
        let symbolTable = Dictionary(visibleSymbols.map { ($0.name, $0.type) }, uniquingKeysWith: { _, latest in latest })

        if let eventContext = eventArgumentContext(source: source, tokens: tokens, cursor: cursor) {
            let items = LuaCompletion.eventItems(quoted: eventContext.insideString)
            return LuaCompletionResult(
                context: .eventName,
                prefix: eventContext.prefix,
                replacementRange: eventContext.replacementRange,
                items: LuaCompletion.rank(items: items, prefix: eventContext.prefix)
            )
        }

        if let referenceContext = objectReferenceArgumentContext(source: source, tokens: tokens, cursor: cursor) {
            let items = LuaCompletion.objectReferenceItems(
                references: environment.objectReferences,
                quoted: referenceContext.insideString,
                asHandleLookup: referenceContext.asHandleLookup
            )
            return LuaCompletionResult(
                context: .objectReference,
                prefix: referenceContext.prefix,
                replacementRange: referenceContext.replacementRange,
                items: LuaCompletion.rank(items: items, prefix: referenceContext.prefix)
            )
        }

        if isInNonCodeRegion(source: source, tokens: tokens, cursor: cursor) {
            return LuaCompletionResult(
                context: .keywordsAndGlobals,
                prefix: "",
                replacementRange: NSRange(location: cursor, length: 0),
                items: []
            )
        }

        let prefix = identifierPrefix(in: source, cursor: cursor)
        if let member = memberContext(source: source, cursor: cursor, prefixRange: prefix.range) {
            let receiverType = inferReceiverType(
                member.receiver, tokens: LuaSourceScanner.tokens(in: member.receiver),
                symbolTable: symbolTable, environment: environment
            )
            let items = LuaCompletion.memberItems(
                receiver: receiverType,
                access: member.access,
                receiverText: liveAttributeReceiverText(member.receiver, sourceTokens: tokens),
                environment: environment,
                isCurrentTargetReceiver: isCurrentTargetReceiver(member.receiver, sourceTokens: tokens)
            )
            return LuaCompletionResult(
                context: .members(receiver: member.receiver, access: member.access),
                prefix: prefix.text,
                replacementRange: prefix.range,
                items: LuaCompletion.rank(items: items, prefix: prefix.text)
            )
        }

        var items = LuaCompletion.globalItems
        if environment.handlerEvent == nil, !visibleSymbols.contains(where: { $0.name == "ev" }) {
            items.removeAll { $0.label == "ev" }
        }
        // Nearest declarations come first so equal-priority shadowed names resolve to the latest
        // preceding declaration; locals also outrank same-named engine globals in `rank`.
        items.append(contentsOf: visibleSymbols.reversed().map { symbol in
            LuaCompletionItem(
                label: symbol.name,
                insertionText: symbol.name,
                kind: symbol.kind == .parameter ? .parameter : symbol.kind == .function ? .function : .variable,
                detail: symbol.type.displayName,
                documentation: symbol.kind == .parameter ? "Function parameter" : "Local \(symbol.kind.rawValue)",
                source: .local,
                isReadOnly: false,
                sortPriority: symbol.kind == .parameter ? 0 : 1
            )
        })
        return LuaCompletionResult(
            context: .keywordsAndGlobals,
            prefix: prefix.text,
            replacementRange: prefix.range,
            items: LuaCompletion.rank(items: items, prefix: prefix.text)
        )
    }

    static func signatureHelp(
        source: String,
        cursorUTF16: Int,
        environment: LuaLanguageEnvironment,
        analysis suppliedAnalysis: LuaLanguageAnalysis? = nil
    ) -> LuaSignatureHelp? {
        let tokens = LuaSourceScanner.tokens(in: source)
        guard let call = activeCall(tokens: tokens, cursor: cursorUTF16) else { return nil }
        _ = environment
        _ = suppliedAnalysis
        guard let signature = LuaCompletion.signature(
            for: call.callee, activeParameter: call.argumentIndex
        ) else { return nil }
        return LuaSignatureHelp(
            label: signature.label,
            documentation: signature.documentation,
            activeParameter: min(call.argumentIndex, max(0, signature.parameterCount - 1))
        )
    }

    // MARK: - symbols and inference

    private static func collectSymbols(
        tokens: [LuaSourceToken], environment: LuaLanguageEnvironment
    ) -> [LuaLanguageSymbol] {
        var symbols: [LuaLanguageSymbol] = []
        var known: [String: LuaInferredType] = implicitTypes(environment: environment)
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token.text == "local" {
                if let functionIndex = nextSignificantIndex(after: index, in: tokens),
                   tokens[functionIndex].text == "function",
                   let nameIndex = nextSignificantIndex(after: functionIndex, in: tokens),
                   tokens[nameIndex].kind == .identifier {
                    let nameToken = tokens[nameIndex]
                    let type = LuaInferredType.function(signature: "function")
                    symbols.append(.init(name: nameToken.text, kind: .function, type: type, declarationRange: nameToken.range))
                    known[nameToken.text] = type
                } else if let nameIndex = nextSignificantIndex(after: index, in: tokens),
                          tokens[nameIndex].kind == .identifier {
                    let nameToken = tokens[nameIndex]
                    var inferred: LuaInferredType = .unknown
                    if let equalsIndex = firstToken(named: "=", after: nameIndex, beforeLineEndIn: tokens),
                       let valueIndex = nextSignificantIndex(after: equalsIndex, in: tokens) {
                        inferred = inferExpression(
                            tokens: tokens, at: valueIndex, symbolTable: known, environment: environment
                        )
                        if tokenText(tokens, valueIndex + 1) == ".",
                           tokenText(tokens, valueIndex + 2) == "attrs",
                           case .object(let kind) = inferred {
                            inferred = .attributes(kind)
                        }
                    }
                    symbols.append(.init(name: nameToken.text, kind: .variable, type: inferred, declarationRange: nameToken.range))
                    known[nameToken.text] = inferred
                }
            }

            if token.text == "function" {
                var cursor = index + 1
                while cursor < tokens.count, tokens[cursor].kind == .newline { cursor += 1 }
                if cursor < tokens.count, tokens[cursor].kind == .identifier {
                    // Named declaration; member declarations may contain dots/colons. The first
                    // identifier remains useful for navigation and local completion.
                    if index == 0 || tokens[index - 1].text != "local" {
                        let nameToken = tokens[cursor]
                        let type = LuaInferredType.function(signature: "function")
                        symbols.append(.init(name: nameToken.text, kind: .function, type: type, declarationRange: nameToken.range))
                        known[nameToken.text] = type
                    }
                    while cursor < tokens.count, tokens[cursor].text != "(" { cursor += 1 }
                }
                if cursor < tokens.count, tokens[cursor].text == "(" {
                    let eventName = eventNameForAnonymousFunction(tokens: tokens, functionIndex: index)
                        ?? environment.handlerEvent
                    cursor += 1
                    while cursor < tokens.count, tokens[cursor].text != ")" {
                        let parameter = tokens[cursor]
                        if parameter.kind == .identifier {
                            let type: LuaInferredType = parameter.text == "ev" ? .event(eventName) : .unknown
                            symbols.append(.init(
                                name: parameter.text, kind: .parameter, type: type,
                                declarationRange: parameter.range
                            ))
                            known[parameter.text] = type
                        }
                        cursor += 1
                    }
                }
            }
            index += 1
        }
        return symbols
    }

    private static func implicitTypes(environment: LuaLanguageEnvironment) -> [String: LuaInferredType] {
        var result: [String: LuaInferredType] = [
            "self": .object(environment.targetKind),
            "world": .object(.world),
            "player": .object(.player),
            "objects": .module("objects"),
            "ai": .module("ai"),
            "math": .module("math"),
            "string": .module("string"),
            "table": .module("table"),
            "utf8": .module("utf8"),
        ]
        if let handlerEvent = environment.handlerEvent { result["ev"] = .event(handlerEvent) }
        return result
    }

    private static func inferExpression(
        tokens: [LuaSourceToken], at index: Int,
        symbolTable: [String: LuaInferredType], environment: LuaLanguageEnvironment
    ) -> LuaInferredType {
        guard index >= 0, index < tokens.count else { return .unknown }
        let token = tokens[index]
        switch token.kind {
        case .string:
            return .string
        case .number:
            return token.text.contains(".") || token.text.lowercased().contains("e") ? .number : .integer
        case .keyword:
            if token.text == "true" || token.text == "false" { return .boolean }
            if token.text == "nil" { return .nilValue }
            if token.text == "function" { return .function(signature: "function") }
        case .identifier:
            if token.text == "dim", tokenText(tokens, index + 1) == "(" { return .object(.dim) }
            if token.text == "objects", tokenText(tokens, index + 1) == "." {
                switch tokenText(tokens, index + 2) {
                case "block": return .object(.block)
                case "get":
                    if let literal = firstStringArgument(tokens: tokens, openingParenIndex: index + 3) {
                        if literal == "self" || literal == "player" { return .object(.player) }
                        if literal == "world" { return .object(.world) }
                        if let ref = ObjectRef.parse(literal) { return .object(ref.kind) }
                    }
                    return .object(nil)
                case "find":
                    return .list(.object(objectKindInFindOptions(tokens: tokens, after: index + 2)))
                default: break
                }
            }
            return symbolTable[token.text] ?? implicitTypes(environment: environment)[token.text] ?? .unknown
        case .symbol:
            if token.text == "{" { return .table(tableFields(tokens: tokens, openingIndex: index, symbolTable: symbolTable, environment: environment)) }
        case .newline:
            break
        }
        return .unknown
    }

    private static func inferReceiverType(
        _ receiver: String, tokens: [LuaSourceToken],
        symbolTable: [String: LuaInferredType], environment: LuaLanguageEnvironment
    ) -> LuaInferredType {
        guard let firstIndex = tokens.firstIndex(where: { $0.kind != .newline }) else { return .unknown }
        var type = inferExpression(tokens: tokens, at: firstIndex, symbolTable: symbolTable, environment: environment)
        var index = endOfBaseExpression(tokens: tokens, startingAt: firstIndex)
        while index + 1 < tokens.count {
            let access = tokens[index]
            let member = tokens[index + 1]
            if access.text == ".", member.kind == .identifier {
                switch (type, member.text) {
                case (.object(let kind), "attrs"):
                    type = .attributes(kind)
                case (.table(let fields), _):
                    type = fields[member.text] ?? .unknown
                case (.event(let eventName), _):
                    type = LuaCompletion.typeOfEventField(member.text, eventName: eventName)
                case (.module, _):
                    type = LuaCompletion.returnType(moduleOrReceiver: receiverBaseName(tokens: tokens), member: member.text)
                case (.object(let kind), _):
                    type = LuaCompletion.returnType(forHandleMember: member.text, kind: kind)
                default:
                    type = .unknown
                }
                index += 2
            } else {
                index += 1
            }
        }
        return type
    }

    private static func endOfBaseExpression(tokens: [LuaSourceToken], startingAt start: Int) -> Int {
        var openingIndex: Int?
        if tokenText(tokens, start + 1) == "(", tokenText(tokens, start) != nil {
            openingIndex = start + 1
        } else if tokenText(tokens, start + 1) == ".", tokenText(tokens, start + 2) != nil,
                  ["(", "{"].contains(tokenText(tokens, start + 3) ?? "") {
            openingIndex = start + 3
        }
        guard let openingIndex else { return start + 1 }
        let opening = tokens[openingIndex].text
        let closing = opening == "(" ? ")" : "}"
        var depth = 0
        var index = openingIndex
        while index < tokens.count {
            if tokens[index].text == opening { depth += 1 }
            if tokens[index].text == closing {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return tokens.count
    }

    private static func tableFields(
        tokens: [LuaSourceToken], openingIndex: Int,
        symbolTable: [String: LuaInferredType], environment: LuaLanguageEnvironment
    ) -> [String: LuaInferredType] {
        var result: [String: LuaInferredType] = [:]
        var depth = 0
        var index = openingIndex
        while index < tokens.count {
            let token = tokens[index]
            if token.text == "{" { depth += 1 }
            if token.text == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth == 1, token.kind == .identifier,
               tokenText(tokens, index + 1) == "=",
               index + 2 < tokens.count {
                result[token.text] = inferExpression(
                    tokens: tokens, at: index + 2, symbolTable: symbolTable, environment: environment
                )
            }
            index += 1
        }
        return result
    }

    // MARK: - semantic tokens

    private static func semanticTokens(
        source: String, tokens: [LuaSourceToken], symbols: [LuaLanguageSymbol],
        symbolTable: [String: LuaInferredType], environment: LuaLanguageEnvironment
    ) -> [LuaSemanticToken] {
        let declarations = Dictionary(symbols.map { ($0.declarationRange.location, $0) }, uniquingKeysWith: { first, _ in first })
        let symbolsByName = Dictionary(symbols.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        let engineGlobals = Set(LuaCompletion.globalItems.map(\.label))
        let modules: Set<String> = ["objects", "ai", "math", "string", "table", "utf8"]
        var result: [LuaSemanticToken] = []

        for (index, token) in tokens.enumerated() {
            guard token.kind == .identifier || token.kind == .string else { continue }
            if let declaration = declarations[token.range.location] {
                result.append(.init(
                    role: declaration.kind == .parameter ? .parameter : declaration.kind == .function ? .function : .declaration,
                    range: token.range
                ))
                continue
            }
            if token.kind == .string, isEventStringToken(index: index, tokens: tokens) {
                result.append(.init(role: .eventName, range: token.range))
                continue
            }
            guard token.kind == .identifier else { continue }
            if isMemberToken(index: index, tokens: tokens) {
                let operatorToken = tokens[index - 1]
                let receiver = receiverExpression(source: source, endingAt: operatorToken.range.location)
                let receiverType = inferReceiverType(
                    receiver, tokens: LuaSourceScanner.tokens(in: receiver),
                    symbolTable: symbolTable, environment: environment
                )
                let access: LuaMemberAccess = operatorToken.text == ":" ? .colon : .dot
                if let item = LuaCompletion.memberItems(
                    receiver: receiverType, access: access,
                    receiverText: liveAttributeReceiverText(receiver, sourceTokens: tokens),
                    environment: environment,
                    isCurrentTargetReceiver: isCurrentTargetReceiver(receiver, sourceTokens: tokens)
                ).first(where: { $0.label == token.text }) {
                    let role: LuaSemanticRole
                    switch item.kind {
                    case .method, .function: role = .method
                    case .attribute: role = .attribute(readOnly: item.isReadOnly)
                    case .field where ifCaseEvent(receiverType): role = .eventField
                    default: role = .property
                    }
                    result.append(.init(role: role, range: token.range))
                }
            } else if unavailableGlobals.contains(token.text), symbolsByName[token.text] == nil {
                result.append(.init(role: .unavailable, range: token.range))
            } else if let symbol = symbolsByName[token.text] {
                result.append(.init(role: symbol.kind == .parameter ? .parameter : symbol.kind == .function ? .function : .variable, range: token.range))
            } else if modules.contains(token.text) {
                result.append(.init(role: .module, range: token.range))
            } else if engineGlobals.contains(token.text) || ["self", "world", "player", "ev"].contains(token.text) {
                result.append(.init(role: .engineGlobal, range: token.range))
            }
        }
        return result
    }

    private static func ifCaseEvent(_ type: LuaInferredType) -> Bool {
        if case .event = type { return true }
        return false
    }

    // MARK: - diagnostics

    private static let unavailableGlobals: Set<String> = [
        "_G", "collectgarbage", "coroutine", "debug", "dofile", "io", "load", "loadfile", "log", "os", "package",
        "rawget", "rawset", "require", "warn",
    ]

    private static func diagnostics(
        source: String, tokens: [LuaSourceToken], symbolTable: [String: LuaInferredType],
        environment: LuaLanguageEnvironment
    ) -> [LuaDiagnostic] {
        var result = delimiterDiagnostics(tokens: tokens, sourceLength: (source as NSString).length)

        for (index, token) in tokens.enumerated() {
            if token.kind == .identifier, unavailableGlobals.contains(token.text),
               symbolTable[token.text] == nil, !isMemberToken(index: index, tokens: tokens) {
                var fixes: [LuaQuickFix] = []
                if token.text == "log" {
                    fixes.append(.init(title: "Replace log with say", replacementRange: token.range, replacementText: "say"))
                }
                result.append(.init(
                    id: "unavailable:\(token.range.location):\(token.text)", severity: .error,
                    message: "'\(token.text)' is not available in the Elysium sandbox.", range: token.range,
                    quickFixes: fixes
                ))
            }

            if token.kind == .string, let value = token.stringValue,
               let call = activeCall(tokens: tokens, cursor: NSMaxRange(token.range)),
               isEventArgument(call) {
                if EventKind.parse(value) == nil {
                    result.append(.init(
                        id: "invalid-event:\(token.range.location)", severity: .error,
                        message: "'\(value)' is not a valid event name.", range: token.range, quickFixes: []
                    ))
                } else if let descriptor = ScriptLanguageSchema.event(named: value),
                          case .reserved(let reason) = descriptor.availability {
                    result.append(.init(
                        id: "reserved-event:\(token.range.location)", severity: .warning,
                        message: "'\(value)' is reserved but has no shipped producer. \(reason)",
                        range: token.range, quickFixes: []
                    ))
                }
            }

            if !environment.isYieldable, token.text == "wait", symbolTable["wait"] == nil,
               tokenText(tokens, index + 1) == "(" {
                result.append(.init(
                    id: "wait-mode:\(token.range.location)", severity: .error,
                    message: "wait() requires a yieldable attached script.", range: token.range, quickFixes: []
                ))
            }
            if !environment.isYieldable, token.text == "ai", symbolTable["ai"] == nil,
               tokenText(tokens, index + 1) == ".",
               tokenText(tokens, index + 2) == "await" {
                result.append(.init(
                    id: "await-mode:\(token.range.location)", severity: .error,
                    message: "ai.await() requires a yieldable attached script.",
                    range: NSUnionRange(token.range, tokens[index + 2].range), quickFixes: []
                ))
            }

            if token.text == "pairs", tokenText(tokens, index + 1) == "(",
               let close = firstToken(named: ")", after: index + 1, beforeLineEndIn: tokens) {
                let argumentRange = NSRange(
                    location: tokens[index + 1].range.location,
                    length: NSMaxRange(tokens[close].range) - tokens[index + 1].range.location
                )
                let argument = (source as NSString).substring(with: argumentRange)
                if argument.contains(".attrs") {
                    result.append(.init(
                        id: "pairs-attrs:\(token.range.location)", severity: .error,
                        message: "pairs(h.attrs) is unsupported; access known custom attributes by name.",
                        range: argumentRange, quickFixes: []
                    ))
                }
            }

            guard isMemberToken(index: index, tokens: tokens) else { continue }
            let operatorToken = tokens[index - 1]
            let receiver = receiverExpression(source: source, endingAt: operatorToken.range.location)
            let receiverType = inferReceiverType(
                receiver, tokens: LuaSourceScanner.tokens(in: receiver),
                symbolTable: symbolTable, environment: environment
            )
            guard receiverType != .unknown else { continue }
            let access: LuaMemberAccess = operatorToken.text == ":" ? .colon : .dot
            let valid = LuaCompletion.memberItems(
                receiver: receiverType, access: access,
                receiverText: liveAttributeReceiverText(receiver, sourceTokens: tokens),
                environment: environment,
                isCurrentTargetReceiver: isCurrentTargetReceiver(receiver, sourceTokens: tokens)
            )
            if let item = valid.first(where: { $0.label == token.text }) {
                if item.isReadOnly, access == .dot, tokenText(tokens, index + 1) == "=",
                   !ifCaseEvent(receiverType) {
                    result.append(.init(
                        id: "readonly-member:\(token.range.location):\(token.text)", severity: .error,
                        message: "'\(token.text)' is read only.", range: token.range, quickFixes: []
                    ))
                }
                continue
            }
            let opposite: LuaMemberAccess = access == .dot ? .colon : .dot
            let oppositeItems = LuaCompletion.memberItems(
                receiver: receiverType, access: opposite,
                receiverText: liveAttributeReceiverText(receiver, sourceTokens: tokens),
                environment: environment,
                isCurrentTargetReceiver: isCurrentTargetReceiver(receiver, sourceTokens: tokens)
            )
            if oppositeItems.contains(where: { $0.label == token.text }) {
                let replacement = access == .dot ? ":" : "."
                result.append(.init(
                    id: "member-access:\(operatorToken.range.location)", severity: .error,
                    message: "Use '\(replacement)' for '\(token.text)'.",
                    range: NSUnionRange(operatorToken.range, token.range),
                    quickFixes: [.init(
                        title: "Replace with \(replacement)", replacementRange: operatorToken.range,
                        replacementText: replacement
                    )]
                ))
            } else if !isOpenDynamicReceiver(receiverType, access: access) {
                result.append(.init(
                    id: "unknown-member:\(token.range.location):\(token.text)", severity: .warning,
                    message: "'\(token.text)' is not available on \(receiverType.displayName).",
                    range: token.range, quickFixes: []
                ))
            }
        }

        return deduplicatedDiagnostics(result).sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return lhs.id < rhs.id
        }
    }

    private static func isOpenDynamicReceiver(_ receiver: LuaInferredType, access: LuaMemberAccess) -> Bool {
        switch receiver {
        case .attributes:
            return true
        case .event(let name):
            guard let name else { return true }
            return ScriptLanguageSchema.event(named: name) == nil
        case .table(let fields):
            return fields.isEmpty
        case .object(nil):
            return access == .dot
        default:
            return false
        }
    }

    private static func delimiterDiagnostics(tokens: [LuaSourceToken], sourceLength: Int) -> [LuaDiagnostic] {
        var stack: [(text: String, range: NSRange)] = []
        let matching: [String: String] = [")": "(", "]": "[", "}": "{"]
        var result: [LuaDiagnostic] = []
        for token in tokens where token.kind == .symbol {
            if ["(", "[", "{"].contains(token.text) {
                stack.append((token.text, token.range))
            } else if let expected = matching[token.text] {
                if stack.last?.text == expected {
                    stack.removeLast()
                } else {
                    result.append(.init(
                        id: "unexpected-close:\(token.range.location)", severity: .error,
                        message: "Unexpected closing '\(token.text)'.", range: token.range, quickFixes: []
                    ))
                }
            }
        }
        for opening in stack {
            let closing = opening.text == "(" ? ")" : opening.text == "[" ? "]" : "}"
            result.append(.init(
                id: "missing-close:\(opening.range.location)", severity: .error,
                message: "Missing closing '\(closing)'.", range: opening.range,
                quickFixes: [.init(
                    title: "Insert \(closing)", replacementRange: NSRange(location: sourceLength, length: 0),
                    replacementText: closing
                )]
            ))
        }
        return result
    }

    // MARK: - completion contexts and calls

    private struct Prefix {
        let text: String
        let range: NSRange
    }

    private struct MemberContext {
        let receiver: String
        let access: LuaMemberAccess
    }

    private struct EventArgumentContext {
        let prefix: String
        let replacementRange: NSRange
        let insideString: Bool
    }

    private struct ObjectReferenceArgumentContext {
        let prefix: String
        let replacementRange: NSRange
        let insideString: Bool
        let asHandleLookup: Bool
    }

    private struct ActiveCall {
        let callee: String
        let argumentIndex: Int
        let openingTokenIndex: Int
    }

    private static func identifierPrefix(in source: String, cursor: Int) -> Prefix {
        let text = source as NSString
        var start = min(max(0, cursor), text.length)
        while start > 0, isIdentifierUnit(text.character(at: start - 1)) { start -= 1 }
        let range = NSRange(location: start, length: cursor - start)
        return Prefix(text: text.substring(with: range), range: range)
    }

    private static func memberContext(source: String, cursor: Int, prefixRange: NSRange) -> MemberContext? {
        let operatorLocation = prefixRange.location - 1
        guard operatorLocation >= 0 else { return nil }
        let text = source as NSString
        let unit = text.character(at: operatorLocation)
        guard unit == 46 || unit == 58 else { return nil } // . or :
        let receiver = receiverExpression(source: source, endingAt: operatorLocation)
        guard !receiver.isEmpty else { return nil }
        return MemberContext(receiver: receiver, access: unit == 58 ? .colon : .dot)
    }

    private static func receiverExpression(source: String, endingAt operatorLocation: Int) -> String {
        let text = source as NSString
        var cursor = operatorLocation
        var parenDepth = 0
        var bracketDepth = 0
        while cursor > 0 {
            let value = text.character(at: cursor - 1)
            if value == 41 { parenDepth += 1; cursor -= 1; continue } // )
            if value == 93 { bracketDepth += 1; cursor -= 1; continue } // ]
            if value == 40 { // (
                if parenDepth > 0 { parenDepth -= 1; cursor -= 1; continue }
                break
            }
            if value == 91 { // [
                if bracketDepth > 0 { bracketDepth -= 1; cursor -= 1; continue }
                break
            }
            if parenDepth > 0 || bracketDepth > 0 {
                cursor -= 1
                continue
            }
            if isIdentifierUnit(value) || value == 46 || value == 58 || value == 34 || value == 39 || value == 44 {
                cursor -= 1
                continue
            }
            break
        }
        return text.substring(with: NSRange(location: cursor, length: operatorLocation - cursor))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func eventArgumentContext(
        source: String, tokens: [LuaSourceToken], cursor: Int
    ) -> EventArgumentContext? {
        guard let call = activeCall(tokens: tokens, cursor: cursor), isEventArgument(call)
        else { return nil }

        let text = source as NSString
        if let stringToken = tokens.last(where: {
            $0.kind == .string && caretIsInsideStringToken($0, cursor: cursor)
        }) {
            let quoteLength = stringToken.text.hasPrefix("[[") ? 2 : 1
            let start = min(cursor, stringToken.range.location + quoteLength)
            let range = NSRange(location: start, length: max(0, cursor - start))
            return EventArgumentContext(prefix: text.substring(with: range), replacementRange: range, insideString: true)
        }
        if tokens.last(where: { NSMaxRange($0.range) <= cursor && $0.kind != .newline })?.kind == .string {
            return nil
        }
        let prefix = identifierPrefix(in: source, cursor: cursor)
        return EventArgumentContext(prefix: prefix.text, replacementRange: prefix.range, insideString: false)
    }

    private static func isEventArgument(_ call: ActiveCall) -> Bool {
        (call.callee == "on" && call.argumentIndex == 0)
            || (call.callee == "emit" && call.argumentIndex == 0)
            || (call.callee == "subscribe" && call.argumentIndex == 1)
    }

    private static func objectReferenceArgumentContext(
        source: String, tokens: [LuaSourceToken], cursor: Int
    ) -> ObjectReferenceArgumentContext? {
        guard let call = activeCall(tokens: tokens, cursor: cursor),
              (call.callee == "objects.get" && call.argumentIndex == 0)
                || (call.callee == "subscribe" && call.argumentIndex == 0)
        else { return nil }
        let asHandleLookup = call.callee == "subscribe"
        let text = source as NSString
        if let stringToken = tokens.last(where: {
            $0.kind == .string && caretIsInsideStringToken($0, cursor: cursor)
        }) {
            let quoteLength = stringToken.text.hasPrefix("[[") ? 2 : 1
            let start = min(cursor, stringToken.range.location + quoteLength)
            let prefixRange = NSRange(location: start, length: max(0, cursor - start))
            return ObjectReferenceArgumentContext(
                prefix: text.substring(with: prefixRange),
                replacementRange: asHandleLookup ? stringToken.range : prefixRange,
                insideString: !asHandleLookup,
                asHandleLookup: asHandleLookup
            )
        }
        if tokens.last(where: { NSMaxRange($0.range) <= cursor && $0.kind != .newline })?.kind == .string {
            return nil
        }
        let prefix = identifierPrefix(in: source, cursor: cursor)
        return ObjectReferenceArgumentContext(
            prefix: prefix.text,
            replacementRange: prefix.range,
            insideString: false,
            asHandleLookup: asHandleLookup
        )
    }

    private static func activeCall(tokens: [LuaSourceToken], cursor: Int) -> ActiveCall? {
        let relevant = tokens.enumerated().filter { $0.element.range.location < cursor }
        var depth = 0
        var argumentIndex = 0
        for (index, token) in relevant.reversed() {
            if token.text == ")" || token.text == "}" || token.text == "]" { depth += 1; continue }
            if token.text == "(" {
                if depth > 0 { depth -= 1; continue }
                guard let callee = callee(before: index, tokens: tokens) else { return nil }
                return ActiveCall(callee: callee, argumentIndex: argumentIndex, openingTokenIndex: index)
            }
            if token.text == ",", depth == 0 { argumentIndex += 1 }
            if token.text == "(" || token.text == "{" || token.text == "[" { depth = max(0, depth - 1) }
        }
        return nil
    }

    private static func callee(before openingParenIndex: Int, tokens: [LuaSourceToken]) -> String? {
        var index = openingParenIndex - 1
        while index >= 0, tokens[index].kind == .newline { index -= 1 }
        guard index >= 0, tokens[index].kind == .identifier else { return nil }
        var pieces = [tokens[index].text]
        index -= 1
        while index >= 1, (tokens[index].text == "." || tokens[index].text == ":") {
            let separator = tokens[index].text
            let previous = tokens[index - 1]
            guard previous.kind == .identifier else { break }
            pieces.insert(separator, at: 0)
            pieces.insert(previous.text, at: 0)
            index -= 2
        }
        return pieces.joined()
    }

    // MARK: - token helpers

    private static func tokenText(_ tokens: [LuaSourceToken], _ index: Int) -> String? {
        guard index >= 0, index < tokens.count else { return nil }
        return tokens[index].text
    }

    private static func nextSignificantIndex(after index: Int, in tokens: [LuaSourceToken]) -> Int? {
        var cursor = index + 1
        while cursor < tokens.count, tokens[cursor].kind == .newline { cursor += 1 }
        return cursor < tokens.count ? cursor : nil
    }

    private static func firstToken(
        named name: String, after index: Int, beforeLineEndIn tokens: [LuaSourceToken]
    ) -> Int? {
        var cursor = index + 1
        while cursor < tokens.count, tokens[cursor].kind != .newline {
            if tokens[cursor].text == name { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func firstStringArgument(tokens: [LuaSourceToken], openingParenIndex: Int) -> String? {
        guard tokenText(tokens, openingParenIndex) == "(" else { return nil }
        var index = openingParenIndex + 1
        while index < tokens.count, tokens[index].kind == .newline { index += 1 }
        return index < tokens.count ? tokens[index].stringValue : nil
    }

    private static func objectKindInFindOptions(tokens: [LuaSourceToken], after index: Int) -> ObjectKind? {
        var cursor = index + 1
        let stop = min(tokens.count, index + 40)
        while cursor + 2 < stop {
            if tokens[cursor].text == "kind", tokens[cursor + 1].text == "=",
               let value = tokens[cursor + 2].stringValue {
                return ObjectKind(rawValue: value)
            }
            cursor += 1
        }
        return nil
    }

    private static func receiverBaseName(tokens: [LuaSourceToken]) -> String {
        tokens.first(where: { $0.kind == .identifier })?.text ?? ""
    }

    private static func liveAttributeReceiverText(
        _ receiver: String, sourceTokens: [LuaSourceToken]
    ) -> String {
        let compact = receiver.filter { !$0.isWhitespace }
        if compact == "self.attrs" { return compact }
        var targetAliases: Set<String> = ["self"]
        var attributeAliases: Set<String> = []
        var index = 0
        while index + 3 < sourceTokens.count {
            guard sourceTokens[index].text == "local",
                  sourceTokens[index + 1].kind == .identifier,
                  sourceTokens[index + 2].text == "=",
                  sourceTokens[index + 3].kind == .identifier else {
                index += 1
                continue
            }
            let name = sourceTokens[index + 1].text
            let sourceName = sourceTokens[index + 3].text
            if targetAliases.contains(sourceName) {
                if tokenText(sourceTokens, index + 4) == ".", tokenText(sourceTokens, index + 5) == "attrs" {
                    attributeAliases.insert(name)
                } else {
                    targetAliases.insert(name)
                }
            } else if attributeAliases.contains(sourceName) {
                attributeAliases.insert(name)
            }
            index += 1
        }
        if attributeAliases.contains(compact) { return "self.attrs" }
        if compact.hasSuffix(".attrs") {
            let base = String(compact.dropLast(".attrs".count))
            if targetAliases.contains(base) { return "self.attrs" }
        }
        return receiver
    }

    private static func isCurrentTargetReceiver(
        _ receiver: String, sourceTokens: [LuaSourceToken]
    ) -> Bool {
        let compact = receiver.filter { !$0.isWhitespace }
        if compact == "self" { return true }
        var aliases: Set<String> = ["self"]
        var index = 0
        while index + 3 < sourceTokens.count {
            defer { index += 1 }
            guard sourceTokens[index].text == "local",
                  sourceTokens[index + 1].kind == .identifier,
                  sourceTokens[index + 2].text == "=",
                  sourceTokens[index + 3].kind == .identifier,
                  aliases.contains(sourceTokens[index + 3].text),
                  tokenText(sourceTokens, index + 4) != "." else { continue }
            aliases.insert(sourceTokens[index + 1].text)
        }
        return aliases.contains(compact)
    }

    private static func eventNameForAnonymousFunction(tokens: [LuaSourceToken], functionIndex: Int) -> String? {
        guard let call = activeCall(tokens: tokens, cursor: tokens[functionIndex].range.location),
              call.callee == "on" || call.callee == "subscribe" else { return nil }
        let desiredArgument = call.callee == "subscribe" ? 1 : 0
        var argument = 0
        var depth = 0
        var index = call.openingTokenIndex + 1
        while index < functionIndex {
            let token = tokens[index]
            if ["(", "{", "["].contains(token.text) {
                depth += 1
            } else if [")", "}", "]"].contains(token.text) {
                depth = max(0, depth - 1)
            } else if token.text == ",", depth == 0 {
                argument += 1
            } else if argument == desiredArgument, let value = token.stringValue {
                return value
            }
            index += 1
        }
        return nil
    }

    private static func isEventStringToken(index: Int, tokens: [LuaSourceToken]) -> Bool {
        guard tokens[index].kind == .string else { return false }
        guard let call = activeCall(tokens: tokens, cursor: NSMaxRange(tokens[index].range)) else { return false }
        return isEventArgument(call)
    }

    private static func isMemberToken(index: Int, tokens: [LuaSourceToken]) -> Bool {
        index > 0 && tokens[index].kind == .identifier && (tokens[index - 1].text == "." || tokens[index - 1].text == ":")
    }

    private static func isIdentifierUnit(_ value: UInt16) -> Bool {
        value == 95 || (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func caretIsInsideStringToken(_ token: LuaSourceToken, cursor: Int) -> Bool {
        guard token.kind == .string, token.range.location < cursor, NSMaxRange(token.range) >= cursor else {
            return false
        }
        if cursor < NSMaxRange(token.range) { return true }
        return !isClosedStringToken(token.text)
    }

    private static func isClosedStringToken(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if first == "\"" || first == "'" { return text.count >= 2 && text.last == first }
        guard first == "[" else { return false }
        var level = 0
        var index = text.index(after: text.startIndex)
        while index < text.endIndex, text[index] == "=" {
            level += 1
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "[" else { return false }
        return text.hasSuffix("]" + String(repeating: "=", count: level) + "]")
    }

    private static func isInNonCodeRegion(
        source: String, tokens: [LuaSourceToken], cursor: Int
    ) -> Bool {
        if tokens.contains(where: { caretIsInsideStringToken($0, cursor: cursor) }) { return true }
        for span in LuaSyntaxColoring.colorSource(source)
            where span.kind == .comment && span.range.location < cursor && NSMaxRange(span.range) >= cursor {
            if cursor < NSMaxRange(span.range) { return true }
            let comment = (source as NSString).substring(with: span.range)
            if !comment.hasPrefix("--[") || !isClosedLongComment(comment) { return true }
        }
        return false
    }

    private static func isClosedLongComment(_ comment: String) -> Bool {
        guard comment.hasPrefix("--[") else { return false }
        let opening = String(comment.dropFirst(2))
        return isClosedStringToken(opening)
    }

    private static func deduplicatedDiagnostics(_ diagnostics: [LuaDiagnostic]) -> [LuaDiagnostic] {
        var seen: Set<String> = []
        return diagnostics.filter { seen.insert($0.id).inserted }
    }
}
