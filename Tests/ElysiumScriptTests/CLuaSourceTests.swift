// CLuaSourceTests.swift — task 6.2 (+ the C22/C25/C31 pins from 6.5 that concern
// vendored sources). Lane A (vendoring) owns this file: it is a hermetic, network-free
// check that Sources/CLua is byte-identical to the pinned upstream tarball plus
// scripts/clua/elysium.patch, that the patch touches exactly the eleven files
// design.md Decision 3 names, and that the determinism/boundary pins those eleven
// files exist to establish are actually present in the checked-in tree.
//
// This file never `import CLua` (CLuaSourceTests reasons about source text only, the
// same discipline scripts/clua/rederive.sh itself follows) and reads everything
// through #filePath-relative paths, matching the repository's other *SourceTests.swift.

import CryptoKit
import Foundation
import XCTest

final class CLuaSourceTests: XCTestCase {
    // MARK: - Repository plumbing

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private var cluaRoot: URL { repository.appendingPathComponent("Sources/CLua") }
    private var manifestURL: URL {
        repository.appendingPathComponent("scripts/clua/upstream-manifest.json")
    }
    private var patchURL: URL {
        repository.appendingPathComponent("scripts/clua/elysium.patch")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The four public headers that move under Sources/CLua/include/ (design.md
    /// Decision 1); every other kept upstream file stays flat beside the .c files.
    private static let publicHeaders: Set<String> = ["lua.h", "luaconf.h", "lauxlib.h", "lualib.h"]

    private static func layoutRelativePath(for upstreamName: String) -> String {
        publicHeaders.contains(upstreamName) ? "include/\(upstreamName)" : upstreamName
    }

    /// design.md Decision 1: 54 kept files = every src/*.c|*.h of 5.4.8 except these
    /// seven (lua.hpp is not matched by *.c|*.h and was never a candidate).
    private static let droppedFiles: Set<String> = [
        "lua.c", "luac.c", "liolib.c", "loslib.c", "loadlib.c", "linit.c", "ldblib.c",
    ]

    /// The five Elysium-authored files: never touched by rederive.sh/the patch, the
    /// only additions to the vendored tree.
    private static let elysiumOwnedRelativePaths: Set<String> = [
        "elysium_shim.c", "elysium_sandbox.c", "elysium_internal.h",
        "include/elysium_shim.h", "include/module.modulemap",
    ]

    /// design.md Decision 3: the exact eleven files the patch may touch.
    private static let expectedPatchedFiles: Set<String> = [
        "include/luaconf.h", "lobject.h", "lstate.h", "lstate.c", "lgc.c", "ltable.c",
        "include/lauxlib.h", "lauxlib.c", "lstrlib.c", "lvm.c", "lundump.c",
    ]

    private struct UpstreamManifest: Decodable {
        struct Tarball: Decodable { let url: String; let sha256: String; let bytes: Int }
        let tarball: Tarball
        let files: [String: String]
    }

    private func loadManifest() throws -> UpstreamManifest {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(UpstreamManifest.self, from: data)
    }

    // MARK: - Vendored file set vs manifest

    func testManifestListsExactlyTheFiftyFourKeptUpstreamFiles() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.files.count, 54)
        XCTAssertEqual(manifest.tarball.sha256,
                        "4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae")
        XCTAssertEqual(manifest.tarball.bytes, 374_332)
        XCTAssertEqual(manifest.tarball.url, "https://www.lua.org/ftp/lua-5.4.8.tar.gz")
        for dropped in Self.droppedFiles {
            XCTAssertNil(manifest.files[dropped], "\(dropped) must not be a kept file")
        }
        XCTAssertNil(manifest.files["lua.hpp"])
    }

    func testVendoredFileSetIsExactlyManifestPlusElysiumOwnedFiles() throws {
        let manifest = try loadManifest()
        var expected = Set(manifest.files.keys.map(Self.layoutRelativePath(for:)))
        expected.formUnion(Self.elysiumOwnedRelativePaths)

        var actual: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: cluaRoot, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            XCTAssertNotEqual(values.isSymbolicLink, true, "no symlinks allowed under Sources/CLua: \(url.path)")
            if values.isDirectory == true { continue }
            let relative = String(url.path.dropFirst(cluaRoot.path.count + 1))
            actual.insert(relative)
        }

        let missing = expected.subtracting(actual)
        let unexpected = actual.subtracting(expected)
        XCTAssertTrue(missing.isEmpty, "missing from Sources/CLua: \(missing.sorted())")
        XCTAssertTrue(unexpected.isEmpty, "unexpected files under Sources/CLua: \(unexpected.sorted())")
    }

    func testDroppedUpstreamFilesAreAbsent() throws {
        var namesUnderTree: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: cluaRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            namesUnderTree.insert(url.lastPathComponent)
        }
        for dropped in Self.droppedFiles.union(["lua.hpp"]) {
            XCTAssertFalse(namesUnderTree.contains(dropped), "\(dropped) must not be vendored")
        }
    }

    // MARK: - Provenance: reverse-apply the patch and compare against the manifest

    func testReverseApplyingPatchReproducesManifestHashes() throws {
        let manifest = try loadManifest()
        let unresolvedTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clua-reverse-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: cluaRoot, to: unresolvedTmp)
        defer { try? FileManager.default.removeItem(at: unresolvedTmp) }
        let tmp = unresolvedTmp.resolvingSymlinksInPath()

        // Drop the five Elysium-authored files before reversing: they are not part
        // of the patch and 'patch -R' has nothing to say about them.
        for relative in Self.elysiumOwnedRelativePaths {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(relative))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/patch")
        process.arguments = ["-R", "-p1", "--no-backup-if-mismatch", "-i", patchURL.path]
        process.currentDirectoryURL = tmp
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "patch -R -p1 failed: \(stderrText)")

        for (upstreamName, expectedHash) in manifest.files {
            let relative = Self.layoutRelativePath(for: upstreamName)
            let fileURL = tmp.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                XCTFail("reverse-patched tree is missing \(relative)")
                continue
            }
            let actualHash = try sha256Hex(of: fileURL)
            XCTAssertEqual(actualHash, expectedHash, "\(upstreamName) does not reverse-patch to the pinned upstream hash")
        }
    }

    func testReverseAppliedTreeHasNoSymlinksAndTheExpectedFileSet() throws {
        let manifest = try loadManifest()
        let unresolvedTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clua-reverse-set-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: cluaRoot, to: unresolvedTmp)
        defer { try? FileManager.default.removeItem(at: unresolvedTmp) }
        // Resolve symlinks (e.g. /tmp -> /private/tmp) only *after* the directory
        // exists: resolvingSymlinksInPath() on a not-yet-existing leaf can silently
        // skip an ancestor symlink, which would corrupt the prefix-strip below.
        let tmp = unresolvedTmp.resolvingSymlinksInPath()
        for relative in Self.elysiumOwnedRelativePaths {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(relative))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/patch")
        process.arguments = ["-R", "-p1", "--no-backup-if-mismatch", "-i", patchURL.path]
        process.currentDirectoryURL = tmp
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        var actual: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: tmp, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            XCTAssertNotEqual(values.isSymbolicLink, true, "no symlinks after the reverse patch: \(url.path)")
            if values.isDirectory == true { continue }
            let resolved = url.resolvingSymlinksInPath()
            actual.insert(String(resolved.path.dropFirst(tmp.path.count + 1)))
        }
        let expected = Set(manifest.files.keys.map(Self.layoutRelativePath(for:)))
        XCTAssertEqual(actual, expected)
    }

    // MARK: - The patch touches exactly the eleven listed files

    func testPatchTouchesExactlyElevenFiles() throws {
        let patchText = try String(contentsOf: patchURL, encoding: .utf8)
        var touched: Set<String> = []
        for line in patchText.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("--- a/") {
            var name = line.dropFirst("--- a/".count)
            if let tab = name.firstIndex(of: "\t") { name = name[..<tab] }
            touched.insert(String(name))
        }
        XCTAssertEqual(touched, Self.expectedPatchedFiles)
        XCTAssertEqual(touched.count, 11)
    }

    // MARK: - Forbidden call sites, URL allowlist, locale/time hygiene

    func testURLTextOnlyInLuaHeader() throws {
        let enumerator = FileManager.default.enumerator(at: cluaRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            guard url.pathExtension == "c" || url.pathExtension == "h"
                    || url.lastPathComponent == "module.modulemap" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("http://") || text.contains("https://") else { continue }
            XCTAssertEqual(url.lastPathComponent, "lua.h",
                            "unexpected URL text in \(url.path); only include/lua.h may contain one")
        }
    }

    func testNoSetlocaleAnywhereUnderSources() throws {
        let sourcesRoot = repository.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            guard url.pathExtension == "c" || url.pathExtension == "h" || url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("setlocale("), "\(url.path) must not call setlocale(")
        }
    }

    func testShimFilesCallNeitherTimeNorClock() throws {
        for file in ["Sources/CLua/elysium_shim.c", "Sources/CLua/elysium_sandbox.c",
                     "Sources/CLua/elysium_internal.h", "Sources/CLua/include/elysium_shim.h"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("time("), "\(file) must not call time(")
            XCTAssertFalse(text.contains("clock("), "\(file) must not call clock(")
        }
    }

    func testElysiumOwnedFilesNeverReferenceForbiddenLibraryOpeners() throws {
        let forbidden = ["luaopen_io", "luaopen_os", "luaopen_package", "luaopen_debug",
                          "luaopen_coroutine", "luaL_openlibs"]
        for file in ["Sources/CLua/elysium_shim.c", "Sources/CLua/elysium_sandbox.c",
                     "Sources/CLua/include/elysium_shim.h", "Sources/CLua/elysium_internal.h"] {
            let text = try source(file)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token)")
            }
        }
    }

    func testDangerousLibraryOpenersAppearOnlyWhereUpstreamPutsThem() throws {
        // luaopen_io/os/package/debug/coroutine never appear as *call sites*: their
        // implementation files (liolib.c, loslib.c, loadlib.c) are dropped entirely,
        // so the only legitimate occurrence left in the tree is lualib.h's own
        // prototype declaration (never a call) and, for coroutine specifically,
        // lcorolib.c's own (kept-but-never-opened) definition. luaL_openlibs is
        // never called either — elysium_openlibs opens libraries individually via
        // luaL_requiref.
        let enumerator = FileManager.default.enumerator(at: cluaRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            guard url.pathExtension == "c" || url.pathExtension == "h" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for name in ["luaopen_io", "luaopen_os", "luaopen_package", "luaopen_debug"] {
                guard text.contains(name) else { continue }
                XCTAssertEqual(url.lastPathComponent, "lualib.h",
                                "unexpected \(name) reference in \(url.lastPathComponent)")
            }
            if text.contains("luaopen_coroutine") {
                let allowed: Set<String> = ["lcorolib.c", "lualib.h"]
                XCTAssertTrue(allowed.contains(url.lastPathComponent),
                               "unexpected luaopen_coroutine reference in \(url.lastPathComponent)")
            }
            if text.contains("luaL_openlibs") {
                XCTAssertEqual(url.lastPathComponent, "lualib.h",
                                "luaL_openlibs must only be declared, never called, under Sources/CLua")
            }
        }
    }

    // MARK: - luaL_testudata/luaL_checkudata removed (release-surface denylist "_test")

    func testLuaLTestudataAndCheckudataAreAbsent() throws {
        let auxC = try source("Sources/CLua/lauxlib.c")
        let auxH = try source("Sources/CLua/include/lauxlib.h")
        for name in ["luaL_testudata", "luaL_checkudata"] {
            XCTAssertFalse(auxC.contains(name), "lauxlib.c must not define \(name)")
            XCTAssertFalse(auxH.contains(name), "lauxlib.h must not declare \(name)")
        }
    }

    // MARK: - Determinism/boundary pins (script-determinism spec, C22)

    func testLuaconfLocalSectionPins() throws {
        let text = try source("Sources/CLua/include/luaconf.h")
        XCTAssertTrue(text.contains("#define luai_makeseed(L)"))
        XCTAssertTrue(text.contains("0x454C5953u"))
        XCTAssertTrue(text.contains("#define l_randomizePivot()"))
        XCTAssertTrue(text.contains("#undef lua_getlocaledecpoint"))
        XCTAssertTrue(text.contains("#define lua_getlocaledecpoint()"))
        XCTAssertTrue(text.contains("elysium_numpow"))
        XCTAssertTrue(text.contains("#define luai_numpow(L,a,b)"))
        XCTAssertTrue(text.contains("#define ELYSIUM_MATCH_STEPS\t100000"))
        XCTAssertTrue(text.contains("#define ELYSIUM_MAX_STRING\t262144"))
        XCTAssertTrue(text.contains("#undef LUA_COMPAT_MATHLIB"))
        XCTAssertTrue(text.contains("#pragma STDC FP_CONTRACT OFF"))
    }

    func testLundumpIsTheStubNotTheLoader() throws {
        let text = try source("Sources/CLua/lundump.c")
        XCTAssertTrue(text.contains("binary chunks are disabled"))
        XCTAssertTrue(text.contains("luaD_throw"))
        XCTAssertFalse(text.contains("loadFunction"), "lundump.c must be the stub, not the stock loader")
        XCTAssertFalse(text.contains("LoadInt"), "lundump.c must be the stub, not the stock loader")
    }

    func testLvmUsesStrcmpNotStrcollAndEnforcesTheConcatCap() throws {
        let text = try source("Sources/CLua/lvm.c")
        XCTAssertFalse(text.contains("strcoll("), "l_strcmp must use strcmp, not strcoll")
        XCTAssertTrue(text.contains("strcmp(s1, s2)"))
        XCTAssertTrue(text.contains("ELYSIUM_MAX_STRING"), "luaV_concat must enforce the ELYSIUM_MAX_STRING cap")
        XCTAssertTrue(text.contains("\"string too long\""))
    }

    func testMainPositionTVHashesByOrdinal() throws {
        let text = try source("Sources/CLua/ltable.c")
        XCTAssertTrue(text.contains("hashmod(t, o->ordinal)"))
    }

    func testCommonHeaderAndGlobalStateOrdinalFields() throws {
        XCTAssertTrue(try source("Sources/CLua/lobject.h").contains("l_uint32 ordinal"))
        XCTAssertTrue(try source("Sources/CLua/lstate.h").contains("nextOrdinal"))
        let lgc = try source("Sources/CLua/lgc.c")
        XCTAssertTrue(lgc.contains("o->ordinal = g->nextOrdinal++"))
    }

    func testVersionMacrosAre548() throws {
        let text = try source("Sources/CLua/include/lua.h")
        XCTAssertTrue(text.contains("#define LUA_VERSION_MAJOR\t\"5\""))
        XCTAssertTrue(text.contains("#define LUA_VERSION_MINOR\t\"4\""))
        XCTAssertTrue(text.contains("#define LUA_VERSION_RELEASE\t\"8\""))
    }

    // MARK: - Package.swift

    func testPackageSwiftHasTheExactCLuaCSettingsAndNoUnsafeFlags() throws {
        let text = try source("Package.swift")
        XCTAssertFalse(text.contains("unsafeFlags"), "no target may use unsafeFlags")
        XCTAssertTrue(text.contains(#".define("LUA_USE_POSIX")"#))
        XCTAssertTrue(text.contains(#".define("LUAI_ASSERT", .when(configuration: .debug))"#))
        XCTAssertTrue(text.contains(#"name: "CLua""#))
        XCTAssertTrue(text.contains(#"name: "ElysiumScript""#))
        XCTAssertTrue(text.contains(#"dependencies: ["CLua", "ElysiumTextInput"]"#))
    }
}
