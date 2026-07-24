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

    func testInstalledCodesignDetailsAreCapturedBeforeParsingWithoutEarlyClose() throws {
        let pipeline = try source("scripts/pipeline.sh")
        XCTAssertEqual(pipeline.components(separatedBy:
            "/usr/bin/codesign -d --verbose=4 \"$INSTALLED_APP\"").count - 1, 1)
        for marker in [
            "local installed_codesign_details=\"$TMP/installed-codesign-details.txt\"",
            ">\"$installed_codesign_details\" 2>&1 || return 1",
            "[ -f \"$installed_codesign_details\" ]",
            "[ ! -L \"$installed_codesign_details\" ]",
            "[ -r \"$installed_codesign_details\" ]",
            "codesign_field \"$installed_codesign_details\" Identifier",
            "codesign_field \"$installed_codesign_details\" CDHash",
            "grep -Ec '^Sealed Resources version=' \"$installed_codesign_details\"",
            "codesign --verify --deep --strict",
            "codesign_requirement \"$INSTALLED_APP\"",
        ] {
            XCTAssertTrue(pipeline.contains(marker), marker)
        }
        XCTAssertFalse(pipeline.contains("codesign -d --verbose=4 \"$1\" 2>&1 |"))
        XCTAssertFalse(pipeline.contains("codesign -d --verbose=4 \"$INSTALLED_APP\" 2>&1 |"))
        XCTAssertFalse(pipeline.contains("$1 == key { print $2; exit }"))
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

    func testFaithful64xPackagingIsExplicitAndInstalledHashesAreChecked() throws {
        let package = try source("scripts/package-app.sh")
        let pipeline = try source("scripts/pipeline.sh")
        let verifier = try source("scripts/verify-pack-assets.sh")
        let expected: [(String, String)] = [
            ("Faithful 64x - December 2025 Release.zip",
             "a136d9101a4748558587980dace3cd7447b758fb72c4684d15fb805d0a812dac"),
            ("Faithful 64x - Ore Borders 64x.zip",
             "232b8a64d745dc08b958c3c4c07167bd3f38eebdc4cd682da9d1016b2ed190f8"),
            ("Faithful 64x - Static Lanterns.zip",
             "d0165130d505da8996354c21090a47fd6def87f4c2a96442f1a4282b1bf2cbc8"),
        ]
        XCTAssertFalse(package.contains("packaging/*.zip"))
        XCTAssertTrue(package.contains("FAITHFUL-LICENSE.txt"))
        XCTAssertTrue(package.contains("FAITHFUL-ADDONS-CREDITS.txt"))
        XCTAssertTrue(package.contains("verify-pack-assets.sh"))
        XCTAssertTrue(pipeline.contains("verify_pack_set \"$INSTALLED_APP/Contents/Resources\""))
        for (name, hash) in expected {
            XCTAssertTrue(package.contains(name), name)
            XCTAssertTrue(verifier.contains(name), name)
            XCTAssertTrue(verifier.contains(hash), hash)
            XCTAssertTrue(pipeline.contains(name), name)
            XCTAssertTrue(pipeline.contains(hash), hash)
        }
    }

    func testResourcePackPublicationTruthIsInTheProductionAccessibilityTree() throws {
        let menus = try source("Sources/Elysium/MenusM.swift")
        let screen = try source("Sources/Elysium/ResourcePackScreenM.swift")
        let packs = try source("Sources/Elysium/ResourcePacks.swift")

        for marker in [
            "id: \"title:texture-generation\", role: .staticText, label: \"Textures\"",
            "focusable: false, actionable: false",
            "MainActor.assumeIsolated { consumeResourcePackPresentationNotice() }",
        ] { XCTAssertTrue(menus.contains(marker), marker) }
        for marker in [
            "id: \"resource-pack.baseline\", role: .staticText",
            "id: \"resource-pack.status\", role: .staticText",
            "var result: [TextEntryAccessibilityDescriptor] = [",
            "focusable: false, actionable: false",
        ] { XCTAssertTrue(screen.contains(marker), marker) }
        for marker in [
            "@MainActor private var consumedResourcePackPresentationNoticeSerial: UInt64 = 0",
            "func consumeResourcePackPresentationNotice() -> String?",
            "guard case .proceduralFallback(let failedPackDisplayName) = snapshot.generation",
            "failedPackDisplayName == \"Faithful 64x\"",
            "snapshot.noticeSerial != 0",
            "snapshot.noticeSerial != consumedResourcePackPresentationNoticeSerial",
            "notice == RESOURCE_PACK_FALLBACK_NOTICE",
            "func resourcePackPresentationAfterActivePublication(",
            "func resourcePackPresentationAfterFallbackPublication(",
        ] { XCTAssertTrue(packs.contains(marker), marker) }
        XCTAssertEqual(packs.components(separatedBy:
            "RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterActivePublication(").count - 1, 2,
            "both successful active publication writers must use the reviewed transition")
        XCTAssertEqual(packs.components(separatedBy:
            "RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterFallbackPublication(").count - 1, 1,
            "exactly one fallback writer must use the reviewed transition")
        let legacyDirectWriter = "RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot("
        XCTAssertEqual(packs.components(separatedBy: legacyDirectWriter).count - 1, 1,
                       "only the process-initial snapshot may use direct construction")
        let liveApply = try XCTUnwrap(packs.range(of: "func applyResourcePacks("))
        let liveBody = String(packs[liveApply.lowerBound...])
        let injectedFailure = try XCTUnwrap(liveBody.range(
            of: "if failNextIconPackPublicationBeforeMutation"))
        let fallbackFailure = try XCTUnwrap(liveBody.range(
            of: "if failNextIconPackPublicationBeforeMutation", options: .backwards))
        let activeWriter = try XCTUnwrap(liveBody.range(
            of: "RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterActivePublication("))
        let fallbackWriter = try XCTUnwrap(liveBody.range(
            of: "RESOURCE_PACK_PRESENTATION = resourcePackPresentationAfterFallbackPublication("))
        XCTAssertLessThan(injectedFailure.lowerBound, activeWriter.lowerBound,
                          "injected active failure must retain the entire prior snapshot")
        XCTAssertEqual(liveBody.components(separatedBy:
            "if failNextIconPackPublicationBeforeMutation").count - 1, 2)
        XCTAssertLessThan(fallbackFailure.lowerBound, fallbackWriter.lowerBound,
                          "injected fallback failure must retain the entire prior snapshot")
        XCTAssertEqual(menus.components(separatedBy: "consumeResourcePackPresentationNotice()").count - 1, 1)
        XCTAssertFalse([menus, screen, packs].joined().contains("ELYSIUM_RESOURCE_PACK_FAILURE"))
    }

    func testResourcePackConflictAndFailureRehearsalsAreAbsentFromSignedApp() throws {
        let package = try source("scripts/package-app.sh")
        let integration = try source("scripts/appkit-text-entry-integration.sh")
        let driver = try source("Tests/ElysiumAppKitIntegration/Driver.swift")
        let production = try [
            "Sources/Elysium/ResourcePackScreenM.swift",
            "Sources/Elysium/ResourcePacks.swift",
            "Sources/Elysium/main.swift",
            "Sources/ElysiumCore/Game/ResourcePackSelection.swift",
        ].map(source).joined(separator: "\n")

        XCTAssertTrue(driver.contains("--resource-pack-attestation-child"))
        XCTAssertTrue(driver.contains("Synthetic") == false,
                      "the executable Driver rehearsal is filesystem-only")
        XCTAssertTrue(integration.contains("Tests/ElysiumAppKitIntegration/Driver.swift"))
        XCTAssertFalse(package.contains("Tests/ElysiumAppKitIntegration"))
        XCTAssertFalse(package.contains("Driver.swift"))
        XCTAssertFalse(package.contains("resource-pack-attestation"))
        for forbidden in ["--resource-pack-attestation-child", "Synthetic Ore",
                          "Synthetic Lantern", "restore-failure"] {
            XCTAssertFalse(production.contains(forbidden), forbidden)
        }
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
