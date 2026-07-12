#!/usr/bin/env swift

import Foundation
import CryptoKit

struct ScanFailure: Error, CustomStringConvertible {
    let description: String
}

struct LexedLiteral {
    let text: String
    /// Half-open UTF-8 byte range including raw-string pounds and quote delimiters.
    let sourceRange: Range<Int>
}

struct LexedSource {
    let code: String
    let maskedCodeBytes: [UInt8]
    let literals: [LexedLiteral]
}

func lexSwift(_ source: String) throws -> LexedSource {
    let bytes = Array(source.utf8)
    var masked = bytes
    var literals: [LexedLiteral] = []
    var index = 0

    func blank(_ range: Range<Int>) {
        for offset in range where masked[offset] != 10 && masked[offset] != 13 {
            masked[offset] = 32
        }
    }

    while index < bytes.count {
        if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 47 {
            let start = index
            index += 2
            while index < bytes.count, bytes[index] != 10 { index += 1 }
            blank(start..<index)
            continue
        }
        if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
            let start = index
            index += 2
            var depth = 1
            while index < bytes.count, depth > 0 {
                if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
                    depth += 1
                    index += 2
                } else if index + 1 < bytes.count, bytes[index] == 42, bytes[index + 1] == 47 {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            guard depth == 0 else { throw ScanFailure(description: "unterminated block comment") }
            blank(start..<index)
            continue
        }

        var quoteIndex = index
        var poundCount = 0
        while quoteIndex < bytes.count, bytes[quoteIndex] == 35 {
            poundCount += 1
            quoteIndex += 1
        }
        if quoteIndex < bytes.count, bytes[quoteIndex] == 34 {
            let start = index
            let multiline = quoteIndex + 2 < bytes.count
                && bytes[quoteIndex + 1] == 34 && bytes[quoteIndex + 2] == 34
            var cursor = quoteIndex + (multiline ? 3 : 1)
            let contentStart = cursor
            var content = [UInt8]()
            var terminated = false
            while cursor < bytes.count {
                if multiline {
                    if cursor + 2 + poundCount < bytes.count,
                       bytes[cursor] == 34, bytes[cursor + 1] == 34,
                       bytes[cursor + 2] == 34,
                       (0..<poundCount).allSatisfy({ bytes[cursor + 3 + $0] == 35 }) {
                        content.append(contentsOf: bytes[contentStart..<cursor])
                        cursor += 3 + poundCount
                        terminated = true
                        break
                    }
                } else if bytes[cursor] == 34,
                          cursor + poundCount < bytes.count,
                          (0..<poundCount).allSatisfy({ bytes[cursor + 1 + $0] == 35 }) {
                    content.append(contentsOf: bytes[contentStart..<cursor])
                    cursor += 1 + poundCount
                    terminated = true
                    break
                }
                if poundCount == 0, bytes[cursor] == 92, cursor + 1 < bytes.count {
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            guard terminated else { throw ScanFailure(description: "unterminated string literal") }
            literals.append(LexedLiteral(
                text: String(decoding: content, as: UTF8.self),
                sourceRange: start..<cursor))
            blank(start..<cursor)
            index = cursor
            continue
        }
        index += 1
    }
    return LexedSource(code: String(decoding: masked, as: UTF8.self),
                       maskedCodeBytes: masked, literals: literals)
}

private func isWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
}

/// Swift has no implicit adjacent-literal concatenation. A chain exists only when each masked-code
/// gap contains whitespace/comments plus exactly one binary `+` and no other token.
func literalConcatenationChains(_ lexed: LexedSource) -> [[LexedLiteral]] {
    guard let first = lexed.literals.first else { return [] }
    var chains: [[LexedLiteral]] = []
    var current = [first]
    for literal in lexed.literals.dropFirst() {
        let previous = current.last!
        let gap = lexed.maskedCodeBytes[
            previous.sourceRange.upperBound..<literal.sourceRange.lowerBound]
        var plusCount = 0
        var isConcatenation = true
        for byte in gap {
            if isWhitespaceByte(byte) { continue }
            if byte == 43, plusCount == 0 {
                plusCount = 1
            } else {
                isConcatenation = false
                break
            }
        }
        if isConcatenation, plusCount == 1 {
            current.append(literal)
        } else {
            if current.count > 1 { chains.append(current) }
            current = [literal]
        }
    }
    if current.count > 1 { chains.append(current) }
    return chains
}

func identifiers(in code: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
    let range = NSRange(code.startIndex..<code.endIndex, in: code)
    return expression.matches(in: code, range: range).compactMap {
        Range($0.range, in: code).map { String(code[$0]) }
    }
}

func containsSQL(_ literal: String) -> Bool {
    let normalized = literal.lowercased()
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
        "\\bselect\\b.+\\bfrom\\b", "\\binsert(?: or replace)?\\b.+\\binto\\b",
        "\\bupdate\\b.+\\bset\\b", "\\bdelete\\s+from\\b",
        "\\b(?:create|alter|drop)\\s+table\\b", "\\bpragma\\b",
        "\\bbegin(?:\\s+immediate)?\\b", "\\bcommit\\b", "\\brollback\\b",
    ]
    return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
}

func run(_ executable: String, _ arguments: [String], root: URL) throws -> (String, Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

func loadJSON(_ url: URL) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url))
}

func relativePath(_ url: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
}

func productionInventory(root: URL) throws -> (files: [URL], description: [String: Any]) {
    let (output, status) = try run("/usr/bin/env", ["swift", "package", "describe", "--type", "json"], root: root)
    guard status == 0, let data = output.data(using: .utf8),
          let description = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let targets = description["targets"] as? [[String: Any]] else {
        throw ScanFailure(description: "swift package describe failed")
    }
    let productionNames: Set<String> = ["PebbleStorage", "PebbleCore", "Pebble", "pebsmoke"]
    var described = Set<String>()
    var discovered = Set<String>()
    let manager = FileManager.default
    for target in targets where productionNames.contains(target["name"] as? String ?? "") {
        guard let path = target["path"] as? String,
              let sources = target["sources"] as? [String] else {
            throw ScanFailure(description: "production target source inventory missing")
        }
        for source in sources where source.hasSuffix(".swift") {
            described.insert(URL(fileURLWithPath: path, relativeTo: root)
                .appendingPathComponent(source).standardizedFileURL.path)
        }
        let targetRoot = root.appendingPathComponent(path, isDirectory: true)
        guard let enumerator = manager.enumerator(
            at: targetRoot, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [], errorHandler: { _, _ in false }) else {
            throw ScanFailure(description: "cannot enumerate \(path)")
        }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                throw ScanFailure(description: "symlink below production target: \(relativePath(file, root: root))")
            }
            if values.isRegularFile == true, file.pathExtension == "swift" {
                discovered.insert(file.standardizedFileURL.path)
            }
        }
    }
    guard described == discovered else {
        throw ScanFailure(description: "SwiftPM production inventory mismatch")
    }
    return (described.sorted().map(URL.init(fileURLWithPath:)), description)
}

func storageIdentifiers(graph: [String: Any]) -> Set<String> {
    guard let symbols = graph["symbols"] as? [[String: Any]] else { return [] }
    var output = Set<String>()
    for symbol in symbols {
        guard let fragments = symbol["declarationFragments"] as? [[String: Any]] else { continue }
        for fragment in fragments where fragment["kind"] as? String == "identifier" {
            if let spelling = fragment["spelling"] as? String, spelling.hasPrefix("Pebble") {
                output.insert(spelling)
            }
        }
    }
    return output
}

func scanSource(relative: String, source: String,
                storageTypeNames: Set<String>) throws {
    let owner = "Sources/PebbleStorage/StorageEngine.swift"
    let adapterOwners: Set<String> = [
        "Sources/PebbleCore/Game/Saves.swift",
        "Sources/PebbleCore/Game/LegacySaveMigration.swift",
    ]
    let lexed = try lexSwift(source)
    let tokens = identifiers(in: lexed.code)
    let tokenSet = Set(tokens)
    let importLines = lexed.code.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("import ") || $0.hasPrefix("import") }
    let interpolatedCapability = lexed.literals.contains {
        $0.text.contains("\\(") && ($0.text.lowercased().contains("sqlite")
            || $0.text.lowercased().contains("pebblestorage"))
    }

    if relative == owner {
        guard importLines.contains("import SQLite3") else {
            throw ScanFailure(description: "SQLite owner lost its plain import")
        }
        if tokenSet.contains("PebbleCore") || lexed.code.contains("DispatchQueue.main")
            || tokenSet.contains("MainActor") {
            throw ScanFailure(description: "PebbleStorage gained a reverse/publication dependency")
        }
    } else {
        if tokenSet.contains("SQLite3") || tokens.contains(where: {
            $0.hasPrefix("sqlite3_") || $0.hasPrefix("SQLITE_") || $0 == "OpaquePointer"
        }) {
            throw ScanFailure(description: "SQLite capability outside owner: \(relative)")
        }
        if lexed.literals.contains(where: {
            $0.text.contains("sqlite3_") || $0.text.contains("SQLITE_")
        }) {
            throw ScanFailure(description: "SQLite literal outside owner: \(relative)")
        }
        if lexed.code.range(of: "@\\s*_[A-Za-z][A-Za-z0-9_]*|@(?:cdecl|extern)",
                            options: .regularExpression) != nil {
            throw ScanFailure(description: "foreign linkage attribute outside owner: \(relative)")
        }
        if interpolatedCapability {
            throw ScanFailure(description: "interpolated storage capability outside owner: \(relative)")
        }
    }

    let referencesStorage = tokenSet.contains("PebbleStorage")
    if adapterOwners.contains(relative) {
        guard importLines.filter({ $0.contains("PebbleStorage") }) == ["import PebbleStorage"] else {
            throw ScanFailure(description: "adapter requires one plain PebbleStorage import: \(relative)")
        }
    } else if referencesStorage || lexed.code.contains("PebbleStorage.") {
        throw ScanFailure(description: "PebbleStorage import/qualification outside adapter: \(relative)")
    }

    if !adapterOwners.contains(relative), relative != owner {
        let escaped = tokenSet.intersection(storageTypeNames)
        if !escaped.isEmpty {
            throw ScanFailure(description: "PebbleStorage type escaped adapter in \(relative)")
        }
        let bridgeNames: Set<String> = ["LegacyMigrationStorageSession", "LegacyMigrationPreflight",
                                        "LegacySaveMigration", "OpenComponents"]
        if !tokenSet.intersection(bridgeNames).isEmpty {
            throw ScanFailure(description: "migration capability escaped adapter in \(relative)")
        }
    }

    if relative == "Sources/PebbleCore/Game/LegacySaveMigration.swift" {
        let denied = ["FileManager", "contentsOfDirectory", "moveItem"]
        if denied.contains(where: tokenSet.contains) || lexed.code.contains("Data(contentsOf:") {
            throw ScanFailure(description: "path-based migration API in LegacySaveMigration.swift")
        }
    }
    if relative.hasPrefix("Sources/PebbleCore/"),
       lexed.literals.contains(where: { containsSQL($0.text) }) ||
        literalConcatenationChains(lexed).contains(where: { chain in
            containsSQL(chain.map(\.text).joined())
        }) {
        throw ScanFailure(description: "persistence SQL literal in PebbleCore: \(relative)")
    }
}

func verifyCapabilityManifest(root: URL) throws {
    let url = root.appendingPathComponent("scripts/pebble-core-storage-capability-v1.json")
    guard let object = try loadJSON(url) as? [String: Any],
          object["formatVersion"] as? Int == 2,
          let owners = object["owners"] as? [String: [String: String]],
          Set(owners.keys) == [
            "Sources/PebbleCore/Game/Saves.swift",
            "Sources/PebbleCore/Game/LegacySaveMigration.swift",
          ] else {
        throw ScanFailure(description: "invalid Core storage capability manifest")
    }
    for path in owners.keys.sorted() {
        guard let expected = owners[path]?["compilerParseASTSHA256"],
              expected.count == 64 else {
            throw ScanFailure(description: "invalid compiler AST capability entry: \(path)")
        }
        let actual = try compilerParseASTDigest(path: path, root: root,
                                                requireStorageImport: true)
        guard actual == expected else {
            throw ScanFailure(description: "compiler semantic capability inventory drift: \(path); actual=\(actual)")
        }
    }
}

func compilerParseASTDigest(path: String, root: URL,
                            requireStorageImport: Bool) throws -> String {
    let (rawAST, status) = try run("/usr/bin/xcrun", [
        "swiftc", "-frontend", "-dump-parse", path,
    ], root: root)
    guard status == 0 else {
        throw ScanFailure(description: "compiler AST inventory failed: \(path)")
    }
    if requireStorageImport, !rawAST.contains("module=\"PebbleStorage\"") {
        throw ScanFailure(description: "compiler AST lost adapter import: \(path)")
    }
    let basename = URL(fileURLWithPath: path).lastPathComponent
    let escaped = NSRegularExpression.escapedPattern(for: basename)
    let canonicalAST = rawAST
        .replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0xADDR",
                              options: .regularExpression)
        .replacingOccurrences(of: "[^\\s\\[\\\"]*\(escaped)", with: "<OWNER>",
                              options: .regularExpression)
    return SHA256.hash(data: Data(canonicalAST.utf8))
        .map { String(format: "%02x", $0) }.joined()
}

func verifySemanticMutationSelfTests(root: URL) throws {
    let relative = "Sources/PebbleCore/Game/LegacySaveMigration.swift"
    let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    let baseline = try compilerParseASTDigest(path: relative, root: root,
                                              requireStorageImport: true)
    var ownerUseMutation = source
    guard let ownerUseRange = ownerUseMutation.range(of: "PebbleStorageCoordinator") else {
        throw ScanFailure(description: "compiler AST owner-use fixture anchor missing")
    }
    ownerUseMutation.replaceSubrange(ownerUseRange, with: "PebbleLegacyCoreStorage")
    let mutations: [(String, String)] = [
        ("access", source.replacingOccurrences(of: "fileprivate struct LegacyFileIdentity",
                                                with: "private struct LegacyFileIdentity")),
        ("owner-use", ownerUseMutation),
        ("closure-generic", source + "\nprivate func scannerGeneric<T>(_ value: T) -> T { { value }() }\n"),
    ]
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pebble-scanner-ast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for (label, mutation) in mutations {
        let file = temporary.appendingPathComponent("LegacySaveMigration.swift")
        try Data(mutation.utf8).write(to: file)
        let digest = try compilerParseASTDigest(path: file.path, root: root,
                                                requireStorageImport: true)
        guard digest != baseline else {
            throw ScanFailure(description: "compiler AST count-preserving fixture passed: \(label)")
        }
    }
}

func verifyPackageEdges(_ description: [String: Any]) throws {
    guard let targets = description["targets"] as? [[String: Any]] else {
        throw ScanFailure(description: "package target list missing")
    }
    func dependencies(_ name: String) -> Set<String>? {
        guard let target = targets.first(where: { $0["name"] as? String == name }) else { return nil }
        return Set(target["target_dependencies"] as? [String] ?? [])
    }
    guard dependencies("PebbleStorage") == [],
          dependencies("PebbleCore")?.contains("PebbleStorage") == true else {
        throw ScanFailure(description: "PebbleCore/PebbleStorage dependency direction drift")
    }
}

func verifySymbolGraph(root: URL) throws -> Set<String> {
    let (output, status) = try run("/usr/bin/env", [
        "swift", "package", "dump-symbol-graph", "--minimum-access-level", "package",
        "--include-spi-symbols", "--skip-synthesized-members",
    ], root: root)
    guard status == 0,
          let range = output.range(of: "Files written to ", options: .backwards) else {
        throw ScanFailure(description: "PebbleStorage symbol graph generation failed")
    }
    let directory = output[range.upperBound...].split(separator: "\n", maxSplits: 1).first
        .map(String.init) ?? ""
    let graphURL = URL(fileURLWithPath: directory).appendingPathComponent("PebbleStorage.symbols.json")
    let data = try Data(contentsOf: graphURL)
    guard let manifest = try loadJSON(
        root.appendingPathComponent("scripts/pebble-storage-api-v1.json")) as? [String: Any],
          let expected = manifest["symbolGraphSHA256"] as? String,
          let manifestPlayerCASDeclarations =
            manifest["checkedPlayerCASPublicDeclarations"] as? [String] else {
        throw ScanFailure(description: "invalid PebbleStorage API manifest")
    }
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else {
        throw ScanFailure(description: "PebbleStorage externally reachable API drift")
    }
    guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ScanFailure(description: "invalid PebbleStorage symbol graph")
    }
    guard let symbols = graph["symbols"] as? [[String: Any]] else {
        throw ScanFailure(description: "PebbleStorage symbol list missing")
    }
    let requiredPlayerCASDeclarations = [
        "PebblePlayerJSONRowDigest",
        "PebblePlayerJSONExpectedRowState",
        "PebblePlayerJSONCompareAndSwapResult",
        "PebbleLegacyCoreStorage.compareAndSwapPlayerJSON(expected:candidate:)",
    ]
    guard manifestPlayerCASDeclarations == requiredPlayerCASDeclarations else {
        throw ScanFailure(description: "checked player CAS API manifest declaration drift")
    }
    let requiredPlayerCASSurface: [String: String] = [
        "PebblePlayerJSONRowDigest": "public|swift.struct",
        "PebblePlayerJSONRowDigest.data": "public|swift.property",
        "PebblePlayerJSONRowDigest.init(data:)": "public|swift.init",
        "PebblePlayerJSONExpectedRowState": "public|swift.enum",
        "PebblePlayerJSONExpectedRowState.absent": "public|swift.enum.case",
        "PebblePlayerJSONExpectedRowState.present(_:)": "public|swift.enum.case",
        "PebblePlayerJSONCompareAndSwapResult": "public|swift.enum",
        "PebblePlayerJSONCompareAndSwapResult.conflict": "public|swift.enum.case",
        "PebblePlayerJSONCompareAndSwapResult.committed(_:)": "public|swift.enum.case",
        "PebbleLegacyCoreStorage.compareAndSwapPlayerJSON(expected:candidate:)":
            "public|swift.method",
    ]
    let playerCASTypeRoots = Set(requiredPlayerCASDeclarations.prefix(3))
    var actualPlayerCASSurface: [String: String] = [:]
    for symbol in symbols {
        guard let path = symbol["pathComponents"] as? [String], let root = path.first else {
            continue
        }
        let isCASMethod = root == "PebbleLegacyCoreStorage"
            && path.dropFirst().first?.hasPrefix("compareAndSwapPlayerJSON") == true
        guard playerCASTypeRoots.contains(root) || isCASMethod else { continue }
        let joined = path.joined(separator: ".")
        guard actualPlayerCASSurface[joined] == nil,
              let access = symbol["accessLevel"] as? String,
              let kind = (symbol["kind"] as? [String: Any])?["identifier"] as? String else {
            throw ScanFailure(description: "duplicate or malformed checked player CAS symbol")
        }
        actualPlayerCASSurface[joined] = "\(access)|\(kind)"
    }
    guard actualPlayerCASSurface == requiredPlayerCASSurface else {
        throw ScanFailure(description: "checked player CAS public surface drift")
    }
    return storageIdentifiers(graph: graph)
}

func runSelfTests(root: URL, storageNames: Set<String>) throws {
    let fixtures = root.appendingPathComponent("Tests/SecurityScanFixtures", isDirectory: true)
    let positives = ["PositiveDarwinFD.swift", "PositiveUnrelatedLiteralsAndPlus.swift"]
    for name in positives {
        let source = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
        try scanSource(relative: "Sources/PebbleCore/Game/\(name)",
                       source: source, storageTypeNames: storageNames)
        if name == "PositiveUnrelatedLiteralsAndPlus.swift" {
            let lexed = try lexSwift(source)
            guard lexed.code.contains("+"),
                  containsSQL(lexed.literals.map(\.text).joined()),
                  !literalConcatenationChains(lexed).contains(where: { chain in
                      containsSQL(chain.map(\.text).joined())
                  }) else {
                throw ScanFailure(description:
                    "unrelated-literal false-positive regression fixture lost its shape")
            }
        }
    }
    let negatives = ["NegativeSQLiteImport.swift", "NegativeScopedSQLiteImport.swift",
                     "NegativeSQLiteSymbol.swift", "NegativeStorageImport.swift",
                     "NegativeSQLLiteral.swift", "NegativeConcatenatedSQL.swift",
                     "NegativeRawSQL.swift", "NegativeInterpolatedStorage.swift",
                     "NegativeForeignLinkage.swift", "NegativeUnderscoredAttribute.swift",
                     "NegativeCountPreservingCapability.swift",
                     "NegativeRPGFacadeEscape.swift", "NegativeClientSlotOnlyWrapper.swift",
                     "NegativeStorageAnyCarrier.swift", "NegativeStorageGenericAlias.swift"]
    let playerCASNegative = "NegativePlayerCASCarrier.swift"
    let allNegatives = negatives + [playerCASNegative]
    let concatenatedSource = try String(contentsOf:
        fixtures.appendingPathComponent("NegativeConcatenatedSQL.swift"), encoding: .utf8)
    let concatenatedLexed = try lexSwift(concatenatedSource)
    guard !concatenatedLexed.literals.contains(where: { containsSQL($0.text) }),
          literalConcatenationChains(concatenatedLexed).contains(where: { chain in
              containsSQL(chain.map(\.text).joined())
          }) else {
        throw ScanFailure(description: "concatenated SQL negative fixture lost its chain shape")
    }
    for name in allNegatives {
        let source = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
        var rejected = false
        do {
            try scanSource(relative: "Sources/PebbleCore/Game/\(name)",
                           source: source, storageTypeNames: storageNames)
        } catch is ScanFailure {
            rejected = true
        }
        guard rejected else {
            throw ScanFailure(description: "negative scanner fixture unexpectedly passed: \(name)")
        }
    }
    let moduleSearch = root.appendingPathComponent(".build/out/Products/Debug").path
    for name in positives + allNegatives {
        let (compileOutput, compileStatus) = try run("/usr/bin/xcrun", [
            "swiftc", "-typecheck", "-I", moduleSearch,
            fixtures.appendingPathComponent(name).path,
        ], root: root)
        guard compileStatus == 0 else {
            throw ScanFailure(description: "bypass fixture did not compile (\(name)): \(compileOutput)")
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let root: URL
if let rootIndex = arguments.firstIndex(of: "--root"), rootIndex + 1 < arguments.count {
    root = URL(fileURLWithPath: arguments[rootIndex + 1], isDirectory: true).standardizedFileURL
} else {
    root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .standardizedFileURL
}

do {
    let storageNames = try verifySymbolGraph(root: root)
    let inventory = try productionInventory(root: root)
    try verifyPackageEdges(inventory.description)
    for file in inventory.files {
        let source = try String(contentsOf: file, encoding: .utf8)
        try scanSource(relative: relativePath(file, root: root), source: source,
                       storageTypeNames: storageNames)
    }
    try verifyCapabilityManifest(root: root)
    if arguments.contains("--self-test") {
        try runSelfTests(root: root, storageNames: storageNames)
        try verifySemanticMutationSelfTests(root: root)
    }
    print("sqlite-boundary-scan: passed (\(inventory.files.count) production Swift files)")
} catch {
    fputs("sqlite-boundary-scan: FAIL: \(error)\n", stderr)
    exit(1)
}
