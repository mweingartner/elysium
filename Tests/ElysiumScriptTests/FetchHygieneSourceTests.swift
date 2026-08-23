// FetchHygieneSourceTests.swift — task 6.5. design.md Condition 31 / security-plan.md
// F14: both fetch scripts must use HTTPS only, `curl --fail --proto '=https'
// --tlsv1.2 --max-redirs 0 --max-time`, and verify hashes *before* the fetched
// content is extracted, compiled, or otherwise trusted. This is a pure source-text
// pin (like CLuaSourceTests) — it never runs the scripts (no network access).

import Foundation
import XCTest

final class FetchHygieneSourceTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static let scripts = [
        "scripts/clua/rederive.sh",
        "scripts/fdlibm-reference/gen-explog-goldens.sh",
    ]

    // MARK: - HTTPS-only URLs

    func testFetchScriptsUseHTTPSOnly() throws {
        for path in Self.scripts {
            let text = try source(path)
            XCTAssertFalse(text.contains("http://"), "\(path) must never reference a plain-HTTP URL")
            // At least one https:// URL is actually present (the point of the script).
            XCTAssertTrue(text.contains("https://"), "\(path) must reference an HTTPS URL")
        }
    }

    // MARK: - The exact curl hygiene flags (Condition 31 / F14)

    func testFetchScriptsPinTheCurlHygieneFlags() throws {
        for path in Self.scripts {
            let text = try source(path)
            XCTAssertTrue(text.contains("curl"), "\(path) must fetch via curl")
            XCTAssertTrue(text.contains("--fail"), "\(path): curl must use --fail")
            XCTAssertTrue(text.contains("--proto '=https'"), "\(path): curl must pin --proto '=https'")
            XCTAssertTrue(text.contains("--tlsv1.2"), "\(path): curl must require --tlsv1.2")
            XCTAssertTrue(text.contains("--max-redirs 0"), "\(path): curl must forbid redirects (--max-redirs 0)")
            XCTAssertTrue(text.contains("--max-time"), "\(path): curl must bound the request with --max-time")
        }
    }

    // MARK: - Verify before extract/compile/use (order in the script text)

    func testRederiveVerifiesBeforeExtracting() throws {
        let text = try source("scripts/clua/rederive.sh")
        guard let fetchRange = text.range(of: "curl --fail") else { return XCTFail("expected a curl invocation") }
        guard let sha256Range = text.range(of: "ACTUAL_SHA256=", range: fetchRange.upperBound..<text.endIndex) else {
            return XCTFail("expected a SHA-256 verification after the fetch")
        }
        guard let extractRange = text.range(of: "tar -xzf", range: sha256Range.upperBound..<text.endIndex) else {
            return XCTFail("expected extraction (tar -xzf) after verification")
        }
        // The verification must also *fail closed*: an exit on mismatch, before extraction.
        let betweenVerifyAndExtract = String(text[sha256Range.upperBound..<extractRange.lowerBound])
        XCTAssertTrue(betweenVerifyAndExtract.contains("exit 1"), "a hash/size mismatch must exit before extraction: \(betweenVerifyAndExtract)")
        XCTAssertTrue(text.contains("SHA-256 mismatch"), "the mismatch path must be named for the reader")

        // No symlinks / path escapes in the kept-file list, checked before use.
        XCTAssertTrue(text.contains("is a symlink in the extracted tarball"), "extracted files must be checked for symlinks")
        XCTAssertTrue(text.contains("rejected path escape"), "the kept-file list must be checked for path escapes")
    }

    func testGenExplogGoldensVerifiesBeforeCompiling() throws {
        let text = try source("scripts/fdlibm-reference/gen-explog-goldens.sh")
        guard let fetchRange = text.range(of: "fetch_if_empty") else { return XCTFail("expected a fetch step") }
        guard let verifyRange = text.range(of: "verify_manifest \"$UPSTREAM_DIR\"", range: fetchRange.upperBound..<text.endIndex) else {
            return XCTFail("expected verify_manifest against the upstream directory after fetching")
        }
        guard let compileRange = text.range(of: "cc ", range: verifyRange.upperBound..<text.endIndex) else {
            return XCTFail("expected compilation (cc) after verification")
        }
        XCTAssertLessThan(verifyRange.lowerBound, compileRange.lowerBound, "verification must happen before any compile step")

        // The fetch-time verification (inside fetch_if_empty, before installing into
        // upstream/) is also present, not only the top-level one.
        guard let fetchBody = text.range(of: "fetch_if_empty()") else { return XCTFail() }
        let afterFetchBody = String(text[fetchBody.upperBound...])
        XCTAssertTrue(afterFetchBody.contains("verify_manifest \"$tmp\""), "the fetch itself must verify into a temp dir before installing")
    }

    // MARK: - shasum -a 256 -c (the actual verification mechanism, not just a string check)

    func testVerificationUsesShasumDashC() throws {
        let rederive = try source("scripts/clua/rederive.sh")
        XCTAssertTrue(rederive.contains("sha256_of()"), rederive)
        XCTAssertTrue(rederive.contains("shasum -a 256"), rederive)

        let gen = try source("scripts/fdlibm-reference/gen-explog-goldens.sh")
        XCTAssertTrue(gen.contains("shasum -a 256 -c"), "gen-explog-goldens.sh must verify with shasum -a 256 -c \(gen)")
    }

    // MARK: - Fresh temp directory per fetch (never reusing/overwriting in place)

    func testFetchesUseAFreshTemporaryDirectory() throws {
        let rederive = try source("scripts/clua/rederive.sh")
        XCTAssertTrue(rederive.contains("mktemp -d"), "rederive.sh must fetch into a fresh temp directory")
        XCTAssertTrue(rederive.contains("trap 'rm -rf \"$WORK\"' EXIT"), "rederive.sh must clean up its temp directory")

        let gen = try source("scripts/fdlibm-reference/gen-explog-goldens.sh")
        XCTAssertTrue(gen.contains("mktemp -d"), "gen-explog-goldens.sh must fetch into a fresh temp directory")
    }
}
