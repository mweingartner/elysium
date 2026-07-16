import Foundation
import XCTest

final class AutomatedReleaseSourceTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testPipelineHasExactNineStageOrderAndTerminalCardinality() throws {
        let pipeline = try source("scripts/pipeline.sh")
        var cursor = pipeline.startIndex
        let stages = [
            ("run_stage 1 source-security", "Source security"),
            ("run_stage 2 release-build", "Warning-free release build"),
            ("run_stage 3 release-surface-binary", "Release surface and binary"),
            ("echo \"[4/9] Full XCTest ... PASS tests=$XCTEST_COUNT\"", "Full XCTest"),
            ("run_stage 5 elysmoke", "Elysmoke"),
            ("run_stage 6 package", "Package signed application"),
            ("run_stage 7 packaged-appkit", "Packaged AppKit text entry"),
            ("run_stage 8 install", "Install /Applications/Elysium.app"),
            ("run_stage 9 installed-identity-codesign", "Installed identity and codesign"),
        ]
        for (marker, label) in stages {
            let range = try XCTUnwrap(pipeline.range(of: marker, range: cursor..<pipeline.endIndex), label)
            cursor = range.upperBound
        }
        XCTAssertEqual(pipeline.components(separatedBy: "AUTOMATED RELEASE PASS path=").count - 1, 1)
        XCTAssertEqual(pipeline.components(separatedBy: "AUTOMATED RELEASE FAIL stage=").count - 1, 1)
        XCTAssertTrue(pipeline.contains("revalidate_source || fail"))
        XCTAssertTrue(pipeline.contains("package_unchanged"))
        XCTAssertTrue(pipeline.contains("release_unchanged"))
    }

    func testHooksSeparateFastCommitFromExactOutgoingPushAuthority() throws {
        let commit = try source(".githooks/pre-commit")
        XCTAssertTrue(commit.contains("mpd check --staged --quiet"))
        XCTAssertFalse(commit.contains("pipeline.sh"))
        let push = try source(".githooks/pre-push")
        for marker in ["exactly one outgoing ref", "local_sha\" = \"$HEAD_SHA",
                       "local_sha\" = \"$REF_SHA", "git status --porcelain=v1 --untracked-files=all",
                       "SOURCE_SNAPSHOT", "revalidate"] {
            XCTAssertTrue(push.contains(marker), marker)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".githooks/post-commit").path))
    }

    func testPostCommitMutationHookIsAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".githooks/post-commit").path))
    }

    func testSourceSnapshotBindsNonignoredUntrackedInputsAndExcludesIgnoredOutput() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-source-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func run(_ executable: URL, _ arguments: [String]) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.currentDirectoryURL = temporary; process.standardOutput = pipe
            process.standardError = pipe; try process.run(); process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, output)
            return output
        }
        _ = try run(URL(fileURLWithPath: "/usr/bin/git"), ["init", "-q"])
        try Data(".build/\n".utf8).write(to: temporary.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: temporary.appendingPathComponent("tracked"))
        _ = try run(URL(fileURLWithPath: "/usr/bin/git"), ["add", ".gitignore", "tracked"])
        let tool = root.appendingPathComponent("scripts/release-source-snapshot.py")
        let base = try run(tool, [temporary.path])
        try Data("input\n".utf8).write(to: temporary.appendingPathComponent("extensionless"))
        let added = try run(tool, [temporary.path])
        XCTAssertNotEqual(base, added)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent(".build"),
                                                withIntermediateDirectories: true)
        try Data("ignored\n".utf8).write(to: temporary.appendingPathComponent(".build/output"))
        XCTAssertEqual(added, try run(tool, [temporary.path]))
    }
}
