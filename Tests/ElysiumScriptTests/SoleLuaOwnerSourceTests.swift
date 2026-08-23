// SoleLuaOwnerSourceTests.swift — tasks 6.3/6.5. spec "Sole-Lua-owner scanner rules
// with fixtures" and design.md Condition 3 / Decision 16 / Condition 25: `Sources/
// ElysiumScript/` is the only place allowed to import `CLua` or spell a raw `lua_`/
// `luaL_`/`LUA_` identifier, `OpaquePointer` is confined to `LuaState.swift` (plus
// the pre-existing `StorageEngine.swift`), the raising-API denylist never appears in
// `ElysiumScript` itself, and the public symbol graph exposes no raw Lua type. This
// file reads source text directly (like CLuaSourceTests) — it is not the
// `scripts/sqlite-boundary-scan.swift` gate itself, which is a separate deliverable;
// this is the hermetic, always-on regression net for the same invariants.

import Foundation
import XCTest

final class SoleLuaOwnerSourceTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private var sourcesRoot: URL { repository.appendingPathComponent("Sources") }

    /// Strips `//` line comments (a deliberately simple heuristic — this file's own
    /// prose comments legitimately *discuss* the tokens these tests police, e.g.
    /// "never `OpaquePointer` itself", so a raw substring search over the whole file
    /// text would flag its own documentation; stripping comments first checks actual
    /// code, matching what these rules are really about).
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// Every `.swift` file under `Sources/`, paired with its path relative to
    /// `Sources/` (e.g. `"ElysiumScript/LuaState.swift"`).
    private func allSwiftFiles() throws -> [(relativePath: String, text: String)] {
        var results: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.path.dropFirst(sourcesRoot.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            results.append((relative, text))
        }
        return results
    }

    // MARK: - `import CLua` and raw lua_/luaL_/LUA_ identifiers only under ElysiumScript

    func testLuaOwnedTokensOnlyUnderElysiumScript() throws {
        let files = try allSwiftFiles()
        var violations: [String] = []
        for (path, text) in files {
            guard !path.hasPrefix("ElysiumScript/") else { continue }
            for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = codeOnly(String(rawLine))
                let s = line
                if s.contains("import CLua") || s.range(of: #"import\s+\S*\bCLua\b"#, options: .regularExpression) != nil {
                    violations.append("\(path):\(lineNumber + 1): imports CLua")
                }
                for prefix in ["lua_", "luaL_", "LUA_"] {
                    if s.contains(prefix) {
                        violations.append("\(path):\(lineNumber + 1): contains '\(prefix)' outside ElysiumScript")
                    }
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "violations:\n\(violations.joined(separator: "\n"))")
    }

    // MARK: - The raising-API denylist is absent from ElysiumScript itself

    func testRaisingAPIDenylistAbsentInElysiumScript() throws {
        // spec "Swift source denylist" — the exact identifier list, plus the five
        // forbidden prefixes.
        let deniedExact: Set<String> = [
            "lua_error", "luaL_error", "lua_yield", "lua_yieldk", "lua_call", "lua_callk",
            "lua_pcall", "lua_pcallk", "lua_resume", "lua_load", "luaL_loadbufferx",
            "luaL_loadbuffer", "luaL_loadstring", "luaL_dostring", "luaL_dofile",
            "luaL_loadfile", "luaL_loadfilex", "lua_gettable", "lua_getfield", "lua_geti",
            "lua_getglobal", "lua_settable", "lua_setfield", "lua_seti", "lua_setglobal",
            "lua_concat", "lua_arith", "lua_compare", "lua_len", "luaL_len", "luaL_tolstring",
            "luaL_checkstack", "luaL_newstate", "luaL_openlibs", "luaL_requiref",
            "luaL_setfuncs", "luaL_newmetatable", "luaL_setmetatable", "luaL_traceback",
            "luaL_where", "luaL_gsub", "lua_newstate", "lua_atpanic", "lua_close", "lua_topointer",
        ]
        let deniedPrefixes = ["luaL_check", "luaL_opt", "luaL_arg", "luaL_type", "luaL_newlib", "luaopen_"]

        let files = try allSwiftFiles().filter { $0.relativePath.hasPrefix("ElysiumScript/") }
        XCTAssertFalse(files.isEmpty, "expected to find ElysiumScript sources")

        var violations: [String] = []
        for (path, text) in files {
            // This target's own comments legitimately name the very APIs it must
            // never *call* (as design.md commentary and as evidence for a fix, e.g.
            // "never lua_resume/lua_pcall directly ... use the shim") — strip
            // comments so the check is about code, not prose about the rule.
            let code = codeOnly(text)
            // Word-boundary matching: a plain substring search would flag e.g. the
            // allowed `lua_getiuservalue` as containing the denylisted `lua_geti`.
            for exact in deniedExact where code.range(of: "\\b\(exact)\\b", options: .regularExpression) != nil {
                violations.append("\(path): contains denylisted identifier '\(exact)'")
            }
            for prefix in deniedPrefixes where code.range(of: "\\b\(prefix)", options: .regularExpression) != nil {
                violations.append("\(path): contains denylisted prefix '\(prefix)'")
            }
            if code.range(of: #"@_[A-Za-z]"#, options: .regularExpression) != nil {
                violations.append("\(path): contains an @_ attribute")
            }
        }
        XCTAssertTrue(violations.isEmpty, "violations:\n\(violations.joined(separator: "\n"))")
    }

    // MARK: - OpaquePointer confined to LuaState.swift (+ the pre-existing StorageEngine.swift)

    func testOpaquePointerOnlyInLuaStateAndStorageEngine() throws {
        let allowed: Set<String> = ["ElysiumScript/LuaState.swift", "ElysiumStorage/StorageEngine.swift"]
        var offenders: [String] = []
        for (path, text) in try allSwiftFiles() {
            guard codeOnly(text).contains("OpaquePointer") else { continue }
            if !allowed.contains(path) { offenders.append(path) }
        }
        XCTAssertTrue(offenders.isEmpty, "OpaquePointer must appear only in \(allowed.sorted()), also found in: \(offenders)")
    }

    // MARK: - No @_ attributes anywhere the new targets touch

    func testNoUnderscoreAttributesInNewTargets() throws {
        let newTargetPrefixes = ["ElysiumScript/", "ElysiumCore/Scripting/", "elysmoke/"]
        var offenders: [String] = []
        for (path, text) in try allSwiftFiles() {
            guard newTargetPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            if text.range(of: #"@_[A-Za-z]"#, options: .regularExpression) != nil {
                offenders.append(path)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "unexpected @_ attribute in: \(offenders)")
    }

    // MARK: - No release-surface denylist substrings in the new targets

    func testNoDenylistSubstringsInNewTargets() throws {
        // design.md Condition 13/15: the exact substrings named as forbidden in
        // identifiers/strings of any *new* code. Scoped to the code Elysium actually
        // authored: the wider vendored-but-patched Sources/CLua tree (already
        // pinned byte-for-byte against upstream by CLuaSourceTests) legitimately
        // contains incidental matches that are not identifiers of ours at all —
        // e.g. stock Lua's own `luaM_testsize` macro, or this very rule being
        // *described* in a patch comment — neither is a new identifier or string
        // this Condition is policing.
        let denylist = [
            "_test", "testSet", "testOpen", "testInject", "testLegacy", "testArmStage",
            "faultInjector", "externalWait", "executorWait", "activeTestStage", "observeTestStage",
        ]
        var offenders: [String] = []
        for (path, text) in try allSwiftFiles() {
            let inNewSwiftTarget = path.hasPrefix("ElysiumScript/") || path.hasPrefix("ElysiumCore/Scripting/") || path.hasPrefix("elysmoke/")
            guard inNewSwiftTarget else { continue }
            for needle in denylist where codeOnly(text).contains(needle) {
                offenders.append("\(path): contains denylisted substring '\(needle)'")
            }
        }

        let elysiumOwnedCFiles = [
            "CLua/elysium_shim.c", "CLua/elysium_sandbox.c", "CLua/elysium_internal.h",
            "CLua/include/elysium_shim.h",
        ]
        for relative in elysiumOwnedCFiles {
            let url = sourcesRoot.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("expected to find \(relative)")
                continue
            }
            for needle in denylist where text.contains(needle) {
                offenders.append("\(relative): contains denylisted substring '\(needle)'")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "violations:\n\(offenders.joined(separator: "\n"))")
    }

    // MARK: - Public symbol graph exposes no raw Lua type (Condition 25)

    /// A pure source-level check (no subprocess build): `swift package
    /// dump-symbol-graph` needs the SwiftPM build lock, which the *outer* `swift
    /// test` process invoking this very test already holds for its entire run (not
    /// just its initial build phase) -- spawning it from inside an XCTest is a
    /// guaranteed self-deadlock, not merely slow (found the hard way: the nested
    /// process waits forever for a lock its own parent will never release before
    /// the nested process exits). This scans every `public`/`open` declaration line
    /// under `Sources/ElysiumScript/` directly instead, which is what the scanner
    /// (`scripts/sqlite-boundary-scan.swift`) does too -- this test is defense in
    /// depth for the same invariant, not the only check of it.
    func testPublicSurfaceHasNoRawLuaTypes() throws {
        let forbidden = ["OpaquePointer", "LuaStatePointer", "UnsafeMutableRawPointer", "UnsafeMutablePointer", "lua_State"]
        // Conservative: any line whose stripped-of-comments code contains `public`
        // (or `open`) alongside something that looks like a declaration (a
        // parameter list, a return-type arrow, or a type annotation) is treated as
        // a public declaration line -- deliberately over-inclusive so a
        // multi-line-unfriendly heuristic never *misses* a real public signature.
        let declarationMarkers: Set<String> = ["(", "->", ":"]
        var offenders: [String] = []
        var sawAnyPublicDeclaration = false

        for (path, text) in try allSwiftFiles() {
            guard path.hasPrefix("ElysiumScript/") else { continue }
            for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = codeOnly(String(rawLine))
                guard line.range(of: #"\b(public|open)\b"#, options: .regularExpression) != nil else { continue }
                guard declarationMarkers.contains(where: { line.contains($0) }) else { continue }
                sawAnyPublicDeclaration = true
                for needle in forbidden where line.contains(needle) {
                    offenders.append("\(path):\(lineNumber + 1): public declaration mentions '\(needle)': \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(sawAnyPublicDeclaration, "sanity: expected to find at least one public declaration line in ElysiumScript")
        XCTAssertTrue(offenders.isEmpty, "public ElysiumScript declarations must never mention a raw Lua type:\n\(offenders.joined(separator: "\n"))")
    }
}
