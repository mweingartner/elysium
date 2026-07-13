import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import ElysiumReleaseGate

final class ReleaseGateTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testOptionalDiagnosticIsDisconnectedAndSelfDisqualifying() throws {
        let diagnosticName = "release-gate-adversarial-test.sh"
        let runner = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/\(diagnosticName)"), encoding: .utf8)
        XCTAssertTrue(runner.contains("PREFIX='NON-AUTHORITATIVE DIAGNOSTIC'"))
        XCTAssertTrue(runner.contains(
            "This result does not authorize release, installed sign-off, deployment, commit, or push."))
        XCTAssertFalse(runner.contains("PENDING_INSTALLED_SIGNOFF"))
        XCTAssertFalse(runner.contains("INSTALLED_SIGNOFF_COMPLETE"))
        XCTAssertFalse(runner.contains("DEPLOYED"))
        XCTAssertFalse(runner.contains("echo "))
        for relative in [
            "scripts/security-scan.sh", ".githooks/pre-commit", ".githooks/post-commit",
            ".githooks/pre-push", "scripts/pipeline.sh", "elysium",
            "scripts/package-app.sh", "scripts/installed-signoff-receipt.sh",
            "scripts/installed-signoff-receipt.swift", "scripts/run-release-gate-tool.sh",
            "scripts/observe-installed-signoff.sh", "scripts/observe-installed-signoff.swift",
            "scripts/designer-attest-installed-signoff.sh",
            "scripts/designer-attest-installed-signoff.swift",
            "scripts/finalize-installed-signoff.sh",
            "scripts/resume-installed-signoff-commit.sh",
        ] {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(relative),
                                    encoding: .utf8)
            XCTAssertFalse(source.contains(diagnosticName), relative)
            XCTAssertFalse(source.contains("NON-AUTHORITATIVE DIAGNOSTIC"), relative)
        }
    }

    func testOptionalDiagnosticEarlyMissingToolOutputIsPrefixedCappedAndSelfDisqualifying() throws {
        let script = repositoryRoot.appendingPathComponent(
            "scripts/release-gate-adversarial-test.sh")
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/nonexistent/elysium-optional-diagnostic-path"
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let output = String(decoding: outputData, as: UTF8.self)
        let prefix = "NON-AUTHORITATIVE DIAGNOSTIC: "
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        for line in lines {
            XCTAssertTrue(line.hasPrefix(prefix), line)
            XCTAssertLessThanOrEqual(line.utf8.count, prefix.utf8.count + 220, line)
        }
        let finalStatement = prefix
            + "This result does not authorize release, installed sign-off, deployment, commit, or push."
        XCTAssertEqual(lines.filter { $0 == finalStatement }.count, 1)
    }

    func testOptionalDiagnosticUnexpectedRowExtractionFailureIsPrefixedCappedAndCleansUp() throws {
        let script = repositoryRoot.appendingPathComponent(
            "scripts/release-gate-adversarial-test.sh")
        let fixtureDirectory = try temporaryDirectory("optional-diagnostic-late-failure")
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let fakeSwift = fixtureDirectory.appendingPathComponent("swift")
        let workspaceMarker = fixtureDirectory.appendingPathComponent("workspaces.txt")
        try """
        #!/bin/bash
        for candidate in /tmp/elysium-release-gate-adversarial.*; do
          if [ -d "$candidate" ]; then
            printf '%s\\n' "$candidate" >> "$ELYSIUM_FAKE_SWIFT_MARKER"
          fi
        done
        printf 'Executed 1 test, with 0 failures\\n'
        """.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeSwift.path)
        let preexisting = Set(try FileManager.default.contentsOfDirectory(
            atPath: "/tmp").filter { $0.hasPrefix("elysium-release-gate-adversarial.") })

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixtureDirectory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["ELYSIUM_FAKE_SWIFT_MARKER"] = workspaceMarker.path
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let output = String(decoding: outputData, as: UTF8.self)
        let prefix = "NON-AUTHORITATIVE DIAGNOSTIC: "
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        for line in lines {
            XCTAssertTrue(line.hasPrefix(prefix), line)
            XCTAssertLessThanOrEqual(line.utf8.count, prefix.utf8.count + 220, line)
        }
        let finalStatement = prefix
            + "This result does not authorize release, installed sign-off, deployment, commit, or push."
        XCTAssertEqual(lines.filter { $0 == finalStatement }.count, 1)

        let recorded = try String(contentsOf: workspaceMarker, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        let created = recorded.filter {
            !preexisting.contains(URL(fileURLWithPath: $0).lastPathComponent)
        }
        XCTAssertEqual(created.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created[0]))
    }

    private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-release-gate-tests-\(name)")
        try? FileManager.default.removeItem(at: value)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return value
    }

    private func payload(sequence: UInt64 = 0, state: ReleaseGateState = .prepared)
        -> ReleaseGatePayload {
        ReleaseGatePayload(
            sequence: sequence, state: state,
            repositoryRootDigest: String(repeating: "1", count: 64),
            contentDigest: String(repeating: "2", count: 64), contentCount: 10,
            checklistDigest: String(repeating: "3", count: 64),
            observerDigest: String(repeating: "4", count: 64),
            automatedGateDigest: String(repeating: "5", count: 64),
            observationChallenge: UUID().uuidString,
            designerChallenge: UUID().uuidString,
            artifacts: ReleaseArtifactIdentity(
                releasePath: "/tmp/release", releaseSHA256: String(repeating: "6", count: 64),
                installedBundlePath: "/Applications/Elysium.app",
                installedExecutablePath: "/Applications/Elysium.app/Contents/MacOS/Elysium",
                installedSHA256: String(repeating: "7", count: 64), installedCDHash: "abc",
                bundleID: "com.briangao.elysium"),
            expiresEpochSeconds: Int64(Date().timeIntervalSince1970) + 3600)
    }

    func testCanonicalCodecRejectsUnknownMalformedAndTamperedMAC() throws {
        let value = payload(), encoded = try ReleaseGateCodec.encode(value)
        XCTAssertEqual(try ReleaseGateCodec.decode(encoded), value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["extra"] = true
        XCTAssertThrowsError(try ReleaseGateCodec.decode(
            JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "extra")
        object["internalMAC"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ReleaseGateCodec.decode(
            JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try ReleaseGateCodec.decode(Data("{}".utf8)))
    }

    func testFullStateSequenceAndReplayCacheCannotRollBackAuthority() throws {
        let root = try temporaryDirectory(), store = try EphemeralReceiptStateStore()
        let coordinator = try ReleaseGateCoordinator(store: store, root: root)
        try coordinator.create(payload())
        let preparedCache = try Data(contentsOf: coordinator.cacheURL)
        var sequence: UInt64 = 0
        let transitions: [(ReleaseGateState, ReleaseGateState)] = [
            (.prepared, .observedPendingDesigner), (.observedPendingDesigner, .observed),
            (.observed, .finalized),
            (.finalized, .commitArmed), (.commitArmed, .committed),
            (.committed, .pushArmed),
        ]
        for transition in transitions {
            let next = try coordinator.transition(from: transition.0, to: transition.1,
                                                  expectedSequence: sequence)
            sequence += 1
            XCTAssertEqual(next.sequence, sequence); XCTAssertEqual(next.state, transition.1)
        }
        try preparedCache.write(to: coordinator.cacheURL)
        XCTAssertEqual(try coordinator.authoritative().state, .pushArmed)
        XCTAssertEqual(try coordinator.authoritative().sequence, 6)
    }

    func testInvalidTransitionsStaleSequenceAndExhaustionFailClosed() throws {
        let root = try temporaryDirectory(), store = try EphemeralReceiptStateStore()
        let coordinator = try ReleaseGateCoordinator(store: store, root: root)
        try coordinator.create(payload())
        XCTAssertThrowsError(try coordinator.transition(
            from: .prepared, to: .finalized, expectedSequence: 0))
        XCTAssertThrowsError(try coordinator.transition(
            from: .prepared, to: .observedPendingDesigner, expectedSequence: 9))
        let exhaustedStore = try EphemeralReceiptStateStore(
            initial: payload(sequence: .max, state: .prepared))
        let exhausted = try ReleaseGateCoordinator(store: exhaustedStore,
                                                    root: try temporaryDirectory())
        XCTAssertThrowsError(try exhausted.transition(
            from: .prepared, to: .observedPendingDesigner)) {
            XCTAssertEqual($0 as? ReleaseGateError, .exhausted)
        }
        XCTAssertEqual(try exhausted.authoritative().state, .prepared)
    }

    func testInjectedStoreFailuresNeverForgeEarlierSuccess() throws {
        for fault in [EphemeralReceiptStateStore.Fault.load, .beforeUpdate, .afterUpdate] {
            let store = try EphemeralReceiptStateStore(initial: payload())
            store.faults = [fault]
            let coordinator = try ReleaseGateCoordinator(store: store,
                                                          root: try temporaryDirectory())
            XCTAssertThrowsError(try coordinator.transition(
                from: .prepared, to: .observedPendingDesigner))
            store.faults = []
            let state = try coordinator.authoritative().state
            if fault == .afterUpdate { XCTAssertEqual(state, .observedPendingDesigner) }
            else { XCTAssertEqual(state, .prepared) }
        }
    }

    func testConcurrentCheckedTransitionAllowsExactlyOneWinner() throws {
        let root = try temporaryDirectory(), store = try EphemeralReceiptStateStore()
        let coordinator = try ReleaseGateCoordinator(store: store, root: root)
        try coordinator.create(payload())
        let queue = DispatchQueue(label: "release-gate", attributes: .concurrent)
        let group = DispatchGroup(), lock = NSLock()
        var successes = 0
        for _ in 0..<16 {
            group.enter(); queue.async {
                defer { group.leave() }
                if (try? coordinator.transition(from: .prepared, to: .observedPendingDesigner,
                                                expectedSequence: 0)) != nil {
                    lock.withLock { successes += 1 }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1)
    }

    func testLockCacheAndEvidenceRejectLinksAndModes() throws {
        let root = try temporaryDirectory(), store = try EphemeralReceiptStateStore()
        let coordinator = try ReleaseGateCoordinator(store: store, root: root)
        let target = root.appendingPathComponent("target")
        FileManager.default.createFile(atPath: target.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
        try FileManager.default.createSymbolicLink(at: coordinator.lockURL,
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try coordinator.create(payload()))
        try FileManager.default.removeItem(at: coordinator.lockURL)
        try coordinator.create(payload())
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: coordinator.cacheURL.path)
        XCTAssertThrowsError(try ReleaseGateCoordinator.requirePrivateFile(coordinator.cacheURL))
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: coordinator.cacheURL.path)
        let alias = root.appendingPathComponent("alias")
        XCTAssertEqual(link(coordinator.cacheURL.path, alias.path), 0)
        XCTAssertThrowsError(try ReleaseGateCoordinator.requirePrivateFile(coordinator.cacheURL))
    }

    func testPackageManifestBindsCapturedReleaseAndClosedFields() throws {
        let hash = String(repeating: "a", count: 64)
        let text = """
        release_path=/tmp/Elysium
        bundle_path=/tmp/repository/dist/Elysium.app
        executable_path=/tmp/repository/dist/Elysium.app/Contents/MacOS/Elysium
        pre_sign_input_sha256=\(hash)
        pre_sign_staged_sha256=\(hash)
        post_sign_executable_sha256=bbb
        bundle_id=com.briangao.elysium
        cdhash=ccc
        designated_requirement=identifier "com.briangao.elysium"
        sealed_resources=true
        """
        let manifest = try PackageManifest(data: Data(text.utf8))
        XCTAssertNoThrow(try manifest.validate(capturedReleaseSHA256: hash))
        XCTAssertThrowsError(try manifest.validate(capturedReleaseSHA256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try PackageManifest(data: Data((text + "\nunknown=yes\n").utf8)))
    }

    func testAutomatedEvidenceRequiresRealPrivateLogsCountsAndClosedGateSet() throws {
        let root = try temporaryDirectory()
        var entries: [AutomatedGateEntry] = []
        for id in AutomatedGateEvidence.requiredIDs.sorted() {
            let file = "\(id).log", data = Data("redacted \(id) PASS\n".utf8)
            FileManager.default.createFile(atPath: root.appendingPathComponent(file).path,
                                           contents: data, attributes: [.posixPermissions: 0o600])
            entries.append(AutomatedGateEntry(
                commandID: id, status: 0,
                passedCount: id == "elysmoke" ? 457 : id == "appkit-text-entry" ? 2 : 1,
                failedCount: 0, logFile: file,
                logSHA256: AutomatedGateEvidence.sha256(data), artifactSHA256: nil,
                executablePath: "/bin/bash",
                executableSHA256: String(repeating: "a", count: 64),
                arguments: [id], toolVersion: "test-v1"))
        }
        let evidence = AutomatedGateEvidence(schema: "AutomatedGateEvidenceV1", entries: entries)
        XCTAssertNoThrow(try evidence.validate(in: root))
        try Data("tampered".utf8).write(to: root.appendingPathComponent(entries[0].logFile))
        XCTAssertThrowsError(try evidence.validate(in: root))
    }

    func testKeychainTestIdentityCannotAliasProduction() throws {
        XCTAssertThrowsError(try KeychainReceiptIdentity.isolatedTest(
            service: KeychainReceiptIdentity.productionService, account: "test:x"))
        XCTAssertThrowsError(try KeychainReceiptIdentity.isolatedTest(
            service: "com.briangao.elysium.test.installed-signoff.x", account: "repository:x"))
        XCTAssertNoThrow(try KeychainReceiptIdentity.isolatedTest(
            service: "com.briangao.elysium.test.installed-signoff.\(UUID().uuidString)",
            account: "test:\(UUID().uuidString)"))
    }

    func testHooksAreExecutableConfiguredAndFailingBuildCannotBeMasked() throws {
        XCTAssertEqual(try runGit(["config", "--get", "core.hooksPath"])
            .trimmingCharacters(in: .whitespacesAndNewlines), ".githooks")
        for path in [".githooks/pre-commit", ".githooks/post-commit", ".githooks/pre-push",
                     "scripts/prepush-release-build.sh"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: repositoryRoot.appendingPathComponent(path).path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(mode & 0o777, 0o755, path)
        }
        let temporary = try temporaryDirectory(), fake = temporary.appendingPathComponent("swift")
        try Data("#!/bin/sh\necho fake build output\nexit 42\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repositoryRoot.appendingPathComponent("scripts/prepush-release-build.sh").path,
                             temporary.appendingPathComponent("build.log").path]
        process.environment = ["PATH": temporary.path + ":/usr/bin:/bin"]
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .contains("release build failed"))
    }

    func testAdversarialCategory01FixedPrepareWorkflowCleanStartAndRealBuild() throws {
        let products = repositoryRoot.appendingPathComponent(".build/out/Products/Debug")
        let probe = try temporaryDirectory("probe-binary").appendingPathComponent("workflow-probe")
        let compile = try runExecutable(URL(fileURLWithPath: "/usr/bin/xcrun"), [
            "swiftc", repositoryRoot.appendingPathComponent(
                "Tests/ElysiumReleaseGateTests/Fixtures/ReleaseGateWorkflowProbe/main.swift").path,
            "-I", products.path, products.appendingPathComponent("ElysiumReleaseGate.o").path,
            "-framework", "Security", "-o", probe.path,
        ], timeout: 30)
        XCTAssertEqual(compile.0, 0, compile.1)
        for scenario in ["clean", "stale-generated-release"] {
            let root = try temporaryDirectory("real-prepare-\(scenario)")
            defer { try? FileManager.default.removeItem(at: root) }
            func write(_ relative: String, _ contents: String, executable: Bool = false) throws {
                let url = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
                if executable {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                          ofItemAtPath: url.path)
                }
            }
            try write("Package.swift", """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Fixture", products: [
              .executable(name: "Elysium", targets: ["Elysium"]),
              .executable(name: "elysmoke", targets: ["elysmoke"]),
            ], targets: [
              .executableTarget(name: "Elysium"), .executableTarget(name: "elysmoke"),
              .testTarget(name: "FixtureTests", dependencies: []),
            ])
            """)
            try write("Sources/Elysium/main.swift", "print(\"fixture Elysium\")\n")
            try write("Sources/elysmoke/main.swift", "print(\"457 passed, 0 failed\")\n")
            try write("Tests/FixtureTests/FixtureTests.swift", """
            import XCTest
            final class FixtureTests: XCTestCase { func testOne() { XCTAssertTrue(true) } }
            """)
            try write("scripts/security-scan.sh", """
            #!/bin/bash
            set -euo pipefail
            ! find .build -type f -name Elysium -print -quit 2>/dev/null | grep -q .
            echo '==> security: passed'
            """, executable: true)
            try write("scripts/verify-elysium-storage-release-surface.sh",
                      "#!/bin/bash\necho 'Elysium storage release surface verified'\n", executable: true)
            try write("scripts/security-check-binary.sh",
                      "#!/bin/bash\nset -eu\ntest -x \"$1\"\necho '==> binary: passed'\n", executable: true)
            try write("scripts/appkit-text-entry-integration.sh", """
            #!/bin/bash
            set -euo pipefail
            test "$1" = --no-build; test "$2" = --executable; test -x "$3"
            test "$4" = --expected-hash; test "${#5}" = 64; test "$6" = --timeout; test "$7" = 90
            echo 'fields=2 clipboard_access=0 cleanup=verified'
            """, executable: true)
            let git = { (args: [String]) in
                try self.runExecutable(URL(fileURLWithPath: "/usr/bin/git"),
                    ["-C", root.path] + args)
            }
            XCTAssertEqual(try git(["init", "-q"]).0, 0)
            XCTAssertEqual(try git(["config", "user.email", "fixture@elysium.invalid"]).0, 0)
            XCTAssertEqual(try git(["config", "user.name", "Elysium Fixture"]).0, 0)
            XCTAssertEqual(try git(["add", "Package.swift", "Sources", "Tests", "scripts"]).0, 0)
            XCTAssertEqual(try git(["commit", "-q", "-m", "fixture"]).0, 0)
            let run = try runExecutable(probe,
                [scenario, root.path, "run-prepare-gates"], timeout: 180)
            XCTAssertEqual(run.0, 0, "\(scenario): \(run.1)")
            let runningLabels = (1...7).map { "\($0)/7 " }
            var cursor = run.1.startIndex
            for label in runningLabels {
                let range = try XCTUnwrap(run.1.range(of: label, range: cursor..<run.1.endIndex))
                cursor = range.upperBound
            }
            XCTAssertTrue(run.1.contains("PENDING_INSTALLED_SIGNOFF"), run.1)
            let authority = root.appendingPathComponent(".probe-authority/authority.bin")
            let prepared = try ReleaseGateCodec.decode(Data(contentsOf: authority))
            XCTAssertEqual(prepared.state, .prepared)
            XCTAssertEqual(prepared.observationChallenge?.count, 64)
            XCTAssertEqual(prepared.designerChallenge?.count, 64)
            let automatedURL = root.appendingPathComponent(
                ".probe-authority/evidence/\(prepared.receiptID)/automated")
            let encoded = try Data(contentsOf: automatedURL.appendingPathComponent(
                "automated-gates.json"))
            let evidence = try JSONDecoder().decode(AutomatedGateEvidence.self, from: encoded)
            XCTAssertEqual(evidence.entries.map(\.commandID), ["source-security", "release-build",
                "release-surface", "binary-scan", "appkit-text-entry", "xctest", "elysmoke"])
            XCTAssertNil(evidence.entries.first?.artifactSHA256)
            XCTAssertTrue(evidence.entries.dropFirst().allSatisfy {
                $0.artifactSHA256 == prepared.artifacts.releaseSHA256
            })
            XCTAssertNoThrow(try evidence.validate(in: automatedURL))
        }
        AdversarialRowsV16.emit(category: 1)
    }

    func testAdversarialCategory02CommandFailuresForgeryAndTimeout() throws {
        let root = try temporaryDirectory(), helper = root.appendingPathComponent("gate-helper")
        try Data("""
        #!/bin/bash
        case "${1:-}" in
          version) echo helper-v1 ;;
          ok) echo security: passed ;;
          bad) echo failed; exit 42 ;;
          sleep) sleep 3 ;;
          *) echo wrong-argv; exit 64 ;;
        esac
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: helper.path)
        let runner = FoundationClosedCommandRunner()
        let good = ClosedCommandSpec(
            commandID: "source-security", executable: helper.path, arguments: ["ok"],
            versionArguments: ["version"], expectedVersionPrefix: "helper-v1", timeoutSeconds: 2)
        let result = try runner.run(good, repositoryRoot: root)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.toolVersion, "helper-v1")
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).contains("security: passed"))
        for spec in [
            ClosedCommandSpec(commandID: "source-security", executable: helper.path,
                              arguments: ["bad"], versionArguments: ["version"],
                              expectedVersionPrefix: "helper-v1"),
            ClosedCommandSpec(commandID: "source-security", executable: helper.path,
                              arguments: ["wrong"], versionArguments: ["version"],
                              expectedVersionPrefix: "helper-v1"),
            ClosedCommandSpec(commandID: "source-security", executable: helper.path,
                              arguments: ["ok"], versionArguments: ["version"],
                              expectedVersionPrefix: "helper-v2"),
            ClosedCommandSpec(commandID: "source-security", executable: helper.path,
                              arguments: ["sleep"], versionArguments: ["version"],
                              expectedVersionPrefix: "helper-v1", timeoutSeconds: 0.05),
            ClosedCommandSpec(commandID: "source-security",
                              executable: root.appendingPathComponent("missing").path,
                              arguments: ["ok"]),
        ] { XCTAssertThrowsError(try runner.run(spec, repositoryRoot: root)) }
        AdversarialRowsV16.emit(category: 2)
    }

    func testCodesignTwoChannelFixtureCorpusMatchesSwiftAndPackageParser() throws {
        let executable = "/tmp/Elysium.app/Contents/MacOS/Elysium"
        let payload = "cdhash H\"0123456789abcdef\""
        let stderr = Data("Executable=\(executable)\n".utf8)
        let accepted = [Data("# designated => \(payload)\n".utf8),
                        Data("designated => \(payload)\n".utf8)]
        let failures: [CodesignChannelFixture] = [
            .init(status: 1, stdout: accepted[0], stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: stderr, stderr: accepted[0], expectedExecutable: executable),
            .init(status: 0, stdout: accepted[0], stderr: accepted[0], expectedExecutable: executable),
            .init(status: 0, stdout: Data(), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: accepted[0], stderr: Data(), expectedExecutable: executable),
            .init(status: 0, stdout: accepted[0] + accepted[0], stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: accepted[0], stderr: stderr + stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("# designated => \(payload)".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("# designated => \(payload)\r\n".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("# designated => \0bad\n".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data([0xff, 0x0a]), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("# designated => \n".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("## designated => \(payload)\n".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("#  designated => \(payload)\n".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: Data("# designated => \(payload)#comment\n".utf8), stderr: stderr, expectedExecutable: executable),
            .init(status: 0, stdout: accepted[0], stderr: Data("Executable=/tmp/Other\n".utf8), expectedExecutable: executable),
            .init(status: 0, stdout: Data("# designated => \(payload)\nextra\n".utf8), stderr: stderr, expectedExecutable: executable),
        ]
        for stdout in accepted {
            XCTAssertEqual(try CodesignRawChannelParser.parse(.init(
                status: 0, stdout: stdout, stderr: stderr,
                expectedExecutable: executable)), payload)
        }
        for fixture in failures {
            XCTAssertThrowsError(try CodesignRawChannelParser.parse(fixture))
        }

        let root = try temporaryDirectory("codesign-shell-fixtures")
        func packageParser(_ fixture: CodesignChannelFixture) throws -> (Int32, String?) {
            let stdoutURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
            let stderrURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
            let outputURL = root.appendingPathComponent(UUID().uuidString + ".normalized")
            try fixture.stdout.write(to: stdoutURL); try fixture.stderr.write(to: stderrURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: stdoutURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: stderrURL.path)
            let result = try runExecutable(
                repositoryRoot.appendingPathComponent("scripts/package-app.sh"),
                ["--validate-codesign-fixture", "\(fixture.status)", stdoutURL.path,
                 stderrURL.path, fixture.expectedExecutable, outputURL.path], timeout: 30)
            let normalized = try? String(contentsOf: outputURL, encoding: .utf8)
                .trimmingCharacters(in: .newlines)
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
            try? FileManager.default.removeItem(at: outputURL)
            return (result.0, normalized)
        }
        for stdout in accepted {
            let parsed = try packageParser(.init(
                status: 0, stdout: stdout, stderr: stderr, expectedExecutable: executable))
            XCTAssertEqual(parsed.0, 0, parsed.1 ?? "")
            XCTAssertEqual(parsed.1, payload)
        }
        for fixture in failures { XCTAssertNotEqual(try packageParser(fixture).0, 0) }
    }

    func testCodesignRawCaptureHandlesTimingFragmentationCapacityEarlyCloseAndStatus() throws {
        let root = try temporaryDirectory("codesign-channel-runner")
        let helper = root.appendingPathComponent("channel-helper")
        try Data("""
        #!/bin/bash
        exe="$2"
        req='# designated => cdhash H"0123456789abcdef"'
        case "$1" in
          stdout-first) printf '%s\\n' "$req"; sleep 0.05; printf 'Executable=%s\\n' "$exe" >&2 ;;
          stderr-first) printf 'Executable=%s\\n' "$exe" >&2; sleep 0.05; printf '%s\\n' "$req" ;;
          fragmented) printf '# des'; printf 'ignated => cdhash H"0123'; printf '456789abcdef"\\n'; printf 'Exec' >&2; printf 'utable=%s\\n' "$exe" >&2 ;;
          capacity) i=0; while [ "$i" -lt 20000 ]; do printf x; printf y >&2; i=$((i+1)); done ;;
          early-close) exec 1>&-; printf 'Executable=%s\\n' "$exe" >&2 ;;
          mid-record) printf '# designated => partial'; printf 'Executable=%s\\n' "$exe" >&2 ;;
          nonzero) printf '%s\\n' "$req"; printf 'Executable=%s\\n' "$exe" >&2; exit 42 ;;
        esac
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let expected = "/tmp/Elysium.app/Contents/MacOS/Elysium"
        for mode in ["stdout-first", "stderr-first", "fragmented"] {
            let result = try RawTwoChannelProcessCapture.capture(
                executable: helper.path, arguments: [mode, expected], timeoutSeconds: 5)
            XCTAssertEqual(try CodesignRawChannelParser.parse(.init(
                status: result.status, stdout: result.stdout, stderr: result.stderr,
                expectedExecutable: expected)), "cdhash H\"0123456789abcdef\"")
        }
        for mode in ["capacity", "early-close", "mid-record", "nonzero"] {
            let result = try RawTwoChannelProcessCapture.capture(
                executable: helper.path, arguments: [mode, expected], timeoutSeconds: 5)
            if mode == "capacity" {
                XCTAssertEqual(result.stdout.count, 20_000)
                XCTAssertEqual(result.stderr.count, 20_000)
            }
            if mode == "nonzero" { XCTAssertEqual(result.status, 42) }
            XCTAssertThrowsError(try CodesignRawChannelParser.parse(.init(
                status: result.status, stdout: result.stdout, stderr: result.stderr,
                expectedExecutable: expected)))
        }
    }

    func testCodesignSeededRawByteMutationRejectsEveryEnvelopeEscape() throws {
        let executable = "/tmp/Elysium.app/Contents/MacOS/Elysium"
        let validOut = Data("# designated => cdhash H\"0123456789abcdef\"\n".utf8)
        let validErr = Data("Executable=\(executable)\n".utf8)
        var state: UInt64 = 0x434f44455349474e
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        for index in 0..<256 {
            var stdout = validOut, stderr = validErr
            switch index % 4 {
            case 0:
                stdout.insert(UInt8(next() % 0x20), at: Int(next() % UInt64(stdout.count - 1)))
            case 1:
                stdout[Int(next() % UInt64("# designated".utf8.count))] ^= 1
            case 2:
                stdout.insert(0x0a, at: Int(next() % UInt64(stdout.count)))
            default:
                stderr.insert(0x23, at: Int(next() % UInt64(stderr.count - 1)))
            }
            XCTAssertThrowsError(try CodesignRawChannelParser.parse(.init(
                status: 0, stdout: stdout, stderr: stderr,
                expectedExecutable: executable)), "mutation \(index)")
        }
    }

    func testRealPackageCodesignRequirementMatchesFreshParserAndSecurityFramework() throws {
        let root = try temporaryDirectory("real-package-codesign")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.swift")
        let release = root.appendingPathComponent("Elysium")
        try Data("print(\"isolated package fixture\")\n".utf8).write(to: source)
        let compile = try runExecutable(URL(fileURLWithPath: "/usr/bin/xcrun"),
                                        ["swiftc", source.path, "-o", release.path], timeout: 60)
        XCTAssertEqual(compile.0, 0, compile.1)
        let releaseIdentity = try StableFileHasher.capture(release, requireExecutable: true)
        let bundle = root.appendingPathComponent("dist/Elysium.app")
        try FileManager.default.createDirectory(
            at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest")
        let result = try runExecutable(
            repositoryRoot.appendingPathComponent("scripts/package-app.sh"),
            ["--executable", releaseIdentity.canonicalPath, "--output", bundle.path,
             "--manifest", manifestURL.path, "--expected-hash", releaseIdentity.sha256],
            timeout: 60)
        XCTAssertEqual(result.0, 0, result.1)
        let manifest = try PackageManifest(data: Data(contentsOf: manifestURL))
        try manifest.validate(capturedReleaseSHA256: releaseIdentity.sha256)
        let canonicalBundle = try XCTUnwrap(manifest.values["bundle_path"])
        let fresh = try CodesignRawCapture.capture(canonicalBundlePath: canonicalBundle)
        XCTAssertEqual(manifest.values["designated_requirement"], fresh)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(
            bundle as CFURL, [], &staticCode), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(
            try XCTUnwrap(staticCode), [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(
            try XCTUnwrap(requirement), [], &text), errSecSuccess)
        XCTAssertEqual(fresh, try XCTUnwrap(text) as String)
    }

    func testAllSevenClosedParsersRejectWrongCountsAndForgedPassText() throws {
        let valid: [String: String] = [
            "source-security": "==> security: passed",
            "release-build": "Build complete!",
            "release-surface": "Elysium storage release surface verified",
            "binary-scan": "==> binary: passed",
            "appkit-text-entry": "fields=2 clipboard_access=0 cleanup=verified",
            "xctest": "Executed 1020 tests, with 0 failures",
            "elysmoke": "457 passed, 0 failed",
        ]
        XCTAssertEqual(Set(valid.keys), AutomatedGateEvidence.requiredIDs)
        for id in AutomatedGateEvidence.requiredIDs {
            XCTAssertNoThrow(try ClosedGateOutputParser.counts(
                commandID: id, output: try XCTUnwrap(valid[id])))
            XCTAssertThrowsError(try ClosedGateOutputParser.counts(
                commandID: id, output: "PASS \(id)"))
        }
        XCTAssertThrowsError(try ClosedGateOutputParser.counts(
            commandID: "elysmoke", output: "456 passed, 0 failed"))
        XCTAssertThrowsError(try ClosedGateOutputParser.counts(
            commandID: "xctest", output: "Executed 1020 tests, with 1 failures"))
    }

    func testAdversarialCategory05PathAndArtifactReplacementBoundaries() throws {
        let root = try temporaryDirectory(), file = root.appendingPathComponent("Elysium")
        try Data("captured".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let captured = try StableFileHasher.capture(file, requireExecutable: true)
        XCTAssertThrowsError(try StableFileHasher.capture(
            file, exactCanonicalPath: root.appendingPathComponent("other").path,
            requireExecutable: true))
        XCTAssertNoThrow(try StableFileHasher.revalidate(captured))
        let symlink = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertThrowsError(try StableFileHasher.capture(symlink, requireExecutable: true))
        let hardlink = root.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, hardlink.path), 0)
        XCTAssertThrowsError(try StableFileHasher.capture(file, requireExecutable: true))
        try FileManager.default.removeItem(at: hardlink)
        XCTAssertNoThrow(try StableFileHasher.capture(file, requireExecutable: true))
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertThrowsError(try StableFileHasher.revalidate(captured))
        try FileManager.default.moveItem(at: moved, to: file)
        try Data("replaced".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        XCTAssertThrowsError(try StableFileHasher.revalidate(captured))
        // An unrelated sibling is intentionally outside the sealed identity and remains allowed.
        let unrelated = root.appendingPathComponent("unrelated")
        try Data("outside sealed identity".utf8).write(to: unrelated)
        XCTAssertNoThrow(try StableFileHasher.capture(unrelated))
        AdversarialRowsV16.emit(category: 5)
    }

    func testAdversarialCategory09DurableEvidencePersistenceAndRecoveryPoints() throws {
        for point in DurableFilePoint.allCases {
            let root = try temporaryDirectory(), target = root.appendingPathComponent("evidence")
            XCTAssertThrowsError(try DurablePrivateFileWriter.write(
                Data("sealed".utf8), to: target, fault: { $0 == point }))
            if point == .afterRename {
                XCTAssertEqual(try Data(contentsOf: target), Data("sealed".utf8))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
            let residue = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix(".durable.") }
            XCTAssertTrue(residue.isEmpty, "residue after \(point)")
        }
        for point in ReleaseGatePersistencePoint.allCases {
            let store = try EphemeralReceiptStateStore()
            let root = try temporaryDirectory()
            let coordinator = try ReleaseGateCoordinator(
                store: store, root: root, fault: { $0 == point })
            XCTAssertThrowsError(try coordinator.create(payload()))
            let recovery = try ReleaseGateCoordinator(store: store, root: root)
            XCTAssertEqual(try recovery.authoritative().state, .prepared)
            XCTAssertNoThrow(try ReleaseGateCoordinator.requirePrivateFile(recovery.cacheURL))
        }
        AdversarialRowsV16.emit(category: 9)
    }

    func testAdversarialCategory03PublicCommandSurfaceRejectsCallerForgery() throws {
        let receipt = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/installed-signoff-receipt.swift"), encoding: .utf8)
        let pipeline = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/pipeline.sh"), encoding: .utf8)
        let observer = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/observe-installed-signoff.swift"), encoding: .utf8)
        let designer = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/designer-attest-installed-signoff.swift"), encoding: .utf8)
        let releaseGate = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/ElysiumReleaseGate/ReleaseGate.swift"), encoding: .utf8)
        XCTAssertFalse(receipt.contains("case \"prepare\""))
        XCTAssertTrue(releaseGate.contains("case \"run-prepare-gates\""))
        XCTAssertTrue(receipt.contains("ReleaseGateCommandDispatcher("))
        for forged in [
            ["prepare"], ["run-prepare-gates", "PASS"], ["run-prepare-gates", "0", "1"],
            ["observe-interactive", "true"], ["designer-attest", "digest"],
            ["finalize", "evidence.json"], ["prepush", "bad", "tuple"],
            ["status", "extra"],
        ] {
            XCTAssertThrowsError(try ReleaseGateCommand.parse(forged), forged.joined(separator: " "))
        }
        XCTAssertEqual(try ReleaseGateCommand.parse(["run-prepare-gates"]), .runPrepareGates)
        XCTAssertFalse(receipt.contains("Fixtures"))
        XCTAssertFalse(receipt.contains("#if TEST"))
        XCTAssertFalse(receipt.contains("ProcessInfo.processInfo.environment[\"ELYSIUM_RELEASE_GATE"))
        XCTAssertFalse(pipeline.contains("automated-gates.json"))
        XCTAssertFalse(pipeline.contains("PACKAGE_MANIFEST"))
        XCTAssertFalse(observer.contains("to: .observedPendingDesigner"))
        XCTAssertFalse(observer.contains("to: .observed,"))
        XCTAssertFalse(designer.contains("from: .observedPendingDesigner, to: .observed"))
        XCTAssertTrue(designer.contains("observerPID != getpid()"))
        AdversarialRowsV16.emit(category: 3)
    }

    func testAdversarialCategory06LiveProcessIdentityMismatchAndExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        let captured = try LiveProcessKernelIdentityReader.capture(pid: process.processIdentifier)
        XCTAssertEqual(captured.pid, process.processIdentifier)
        XCTAssertNoThrow(try LiveProcessKernelIdentityReader.revalidate(captured))
        XCTAssertThrowsError(try LiveProcessKernelIdentityReader.revalidate(.init(
            pid: captured.pid, startIdentity: captured.startIdentity + "-reused",
            executablePath: captured.executablePath)))
        process.terminate(); process.waitUntilExit()
        XCTAssertThrowsError(try LiveProcessKernelIdentityReader.revalidate(captured))
        AdversarialRowsV16.emit(category: 6)
    }

    func testAdversarialCategory04ObserverDesignerChallengeAndEvidenceSubstitution() throws {
        let store = try EphemeralReceiptStateStore(), root = try temporaryDirectory()
        let coordinator = try ReleaseGateCoordinator(store: store, root: root)
        try coordinator.create(payload())
        let pending = try coordinator.transition(
            from: .prepared, to: .observedPendingDesigner, expectedSequence: 0) {
                $0.observationChallenge = nil
                $0.observerProcessID = 11; $0.observerProcessStart = "start-a"
            }
        XCTAssertNil(pending.observationChallenge)
        XCTAssertNotNil(pending.designerChallenge)
        XCTAssertThrowsError(try coordinator.transition(
            from: .prepared, to: .observedPendingDesigner, expectedSequence: 0))
        XCTAssertThrowsError(try coordinator.transition(
            from: .prepared, to: .observed, expectedSequence: pending.sequence))
        let observed = try coordinator.transition(
            from: .observedPendingDesigner, to: .observed,
            expectedSequence: pending.sequence) { $0.designerChallenge = nil }
        XCTAssertNil(observed.designerChallenge)
        XCTAssertThrowsError(try coordinator.transition(
            from: .observedPendingDesigner, to: .observed,
            expectedSequence: pending.sequence))
        let evidence = root.appendingPathComponent("sealed")
        try ReleaseGateCoordinator.ensurePrivateDirectory(evidence)
        var entries: [AutomatedGateEntry] = []
        for id in AutomatedGateEvidence.requiredIDs.sorted() {
            let data: Data
            switch id {
            case "source-security": data = Data("security: passed\n".utf8)
            case "release-build": data = Data("Build complete!\n".utf8)
            case "release-surface": data = Data("release surface verified\n".utf8)
            case "binary-scan": data = Data("binary: passed\n".utf8)
            case "appkit-text-entry": data = Data("fields=2 clipboard_access=0 cleanup=verified\n".utf8)
            case "xctest": data = Data("Executed 1 test, with 0 failures\n".utf8)
            default: data = Data("457 passed, 0 failed\n".utf8)
            }
            let file = "\(id).log"
            try DurablePrivateFileWriter.write(data, to: evidence.appendingPathComponent(file))
            entries.append(.init(
                commandID: id, status: 0,
                passedCount: id == "elysmoke" ? 457 : id == "appkit-text-entry" ? 2 : 1,
                failedCount: 0, logFile: file,
                logSHA256: AutomatedGateEvidence.sha256(data), artifactSHA256: nil,
                executablePath: "/bin/bash",
                executableSHA256: String(repeating: "a", count: 64),
                arguments: [id], toolVersion: "fixture-v1"))
        }
        let sealed = AutomatedGateEvidence(schema: "AutomatedGateEvidenceV1", entries: entries)
        XCTAssertNoThrow(try sealed.validate(in: evidence))
        try Data("substituted\n".utf8).write(to: evidence.appendingPathComponent(entries[0].logFile))
        XCTAssertThrowsError(try sealed.validate(in: evidence))
        let releaseGateSource = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/ElysiumReleaseGate/ReleaseGate.swift"), encoding: .utf8)
        let observerSource = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/observe-installed-signoff.swift"), encoding: .utf8)
        let designerSource = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "scripts/designer-attest-installed-signoff.swift"), encoding: .utf8)
        XCTAssertFalse(observerSource.contains(".transition("))
        XCTAssertFalse(designerSource.contains(".transition("))
        XCTAssertFalse(observerSource.contains(".invalidate("))
        XCTAssertFalse(designerSource.contains(".invalidate("))
        XCTAssertEqual(releaseGateSource.components(separatedBy: "gate.transition(").count - 1, 7)
        AdversarialRowsV16.emit(category: 4)
    }

    func testAdversarialCategory07TemporaryGitHooksInterruptionRecoveryAndReplay() throws {
        let root = try temporaryDirectory(), fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        func runProcess(_ executable: String, _ arguments: [String], input: Data? = nil,
                        environment: [String: String]? = nil) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.currentDirectoryURL = root; process.standardOutput = pipe; process.standardError = pipe
            if let environment { process.environment = environment }
            if let input {
                let stdin = Pipe(); process.standardInput = stdin; try process.run()
                stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
            } else { try process.run() }
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        func executable(_ relative: String, _ body: String) throws {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let products = repositoryRoot.appendingPathComponent(".build/out/Products/Debug")
        let probe = root.appendingPathComponent("workflow-probe")
        let compile = try runExecutable(URL(fileURLWithPath: "/usr/bin/xcrun"), [
            "swiftc", repositoryRoot.appendingPathComponent(
                "Tests/ElysiumReleaseGateTests/Fixtures/ReleaseGateWorkflowProbe/main.swift").path,
            "-I", products.path, products.appendingPathComponent("ElysiumReleaseGate.o").path,
            "-framework", "Security", "-o", probe.path,
        ], timeout: 30)
        XCTAssertEqual(compile.0, 0, compile.1)
        XCTAssertEqual(try runProcess("/usr/bin/git", ["init", "-q"]).0, 0)
        XCTAssertEqual(try runProcess("/usr/bin/git", ["config", "user.email", "test@elysium.invalid"]).0, 0)
        XCTAssertEqual(try runProcess("/usr/bin/git", ["config", "user.name", "Elysium Test"]).0, 0)
        XCTAssertEqual(try runProcess("/usr/bin/git", ["config", "core.hooksPath", ".githooks"]).0, 0)
        try fm.createDirectory(at: root.appendingPathComponent(".githooks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        for name in ["pre-commit", "post-commit", "pre-push"] {
            try fm.copyItem(at: repositoryRoot.appendingPathComponent(".githooks/\(name)"),
                            to: root.appendingPathComponent(".githooks/\(name)"))
        }
        for name in ["prepush-release-build.sh", "finalize-installed-signoff.sh",
                     "resume-installed-signoff-commit.sh", "observe-installed-signoff.sh",
                     "designer-attest-installed-signoff.sh"] {
            try fm.copyItem(at: repositoryRoot.appendingPathComponent("scripts/\(name)"),
                            to: root.appendingPathComponent("scripts/\(name)"))
        }
        try executable("scripts/installed-signoff-receipt.sh", """
        #!/bin/sh
        set -eu
        exec "\(probe.path)" clean "\(root.path)" "$@"
        """)
        try executable("scripts/security-scan.sh", "#!/bin/sh\nset -eu\n! find .build -type f -name Elysium -print -quit 2>/dev/null | grep -q .\necho '==> security: passed'\n")
        try executable("scripts/verify-elysium-storage-release-surface.sh",
                       "#!/bin/sh\necho 'Elysium storage release surface verified'\n")
        try executable("scripts/security-check-binary.sh", "#!/bin/sh\necho '==> binary: passed'\n")
        try executable("scripts/appkit-text-entry-integration.sh",
                       "#!/bin/sh\necho 'fields=2 clipboard_access=0 cleanup=verified'\n")
        try executable("Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", products: [
          .executable(name: "Elysium", targets: ["Elysium"]),
          .executable(name: "elysmoke", targets: ["elysmoke"]),
        ], targets: [.executableTarget(name: "Elysium"), .executableTarget(name: "elysmoke"),
                     .testTarget(name: "FixtureTests")])
        """)
        try executable("Sources/Elysium/main.swift", "print(\"fixture\")\n")
        try executable("Sources/elysmoke/main.swift", "print(\"457 passed, 0 failed\")\n")
        try executable("Tests/FixtureTests/FixtureTests.swift", "import XCTest\nfinal class FixtureTests: XCTestCase { func testOne() { XCTAssertTrue(true) } }\n")
        try executable("fake-bin/swift", """
        #!/bin/sh
        set -eu
        case "${1:-}" in
          package) rm -rf .build; exit 0 ;;
          build) mkdir -p .build/release; printf '#!/bin/sh\nexit 0\n' > .build/release/Elysium; chmod 755 .build/release/Elysium; echo 'Build complete!';;
          test) echo 'Executed 1 test, with 0 failures';;
          run) echo '457 passed, 0 failed';;
          --version) echo 'Swift fixture version 1';;
          *) exit 64 ;;
        esac
        """)
        try executable("fake-bin/mpd", """
        #!/bin/sh
        set -eu
        [ "$#" -eq 3 ]
        [ "$1" = check ]
        [ "$2" = --staged ]
        [ "$3" = --quiet ]
        """)
        try Data("tracked\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(try runProcess("/usr/bin/git", ["add", "tracked.txt"]).0, 0)
        XCTAssertEqual(try runProcess(
            "/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "fixture"]).0, 0)
        let firstHead = try runProcess("/usr/bin/git", ["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = ["PATH": root.appendingPathComponent("fake-bin").path +
            ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        XCTAssertEqual(try runProcess(probe.path,
            ["clean", root.path, "run-prepare-gates"], environment: environment).0, 0)
        XCTAssertEqual(try runProcess(probe.path,
            ["clean", root.path, "observe-interactive"], environment: environment).0, 0)
        XCTAssertEqual(try runProcess(probe.path,
            ["clean", root.path, "designer-attest"], environment: environment).0, 0)
        XCTAssertEqual(try runProcess(probe.path,
            ["clean", root.path, "finalize"], environment: environment).0, 0)
        try Data("tracked\nchanged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        XCTAssertEqual(try runProcess("/usr/bin/git", ["add", "tracked.txt"]).0, 0)
        let committed = try runProcess("/usr/bin/git", ["commit", "-m", "verified change"],
                                       environment: environment)
        XCTAssertEqual(committed.0, 0, committed.1)
        let head = try runProcess("/usr/bin/git", ["rev-parse", "HEAD"]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(head, firstHead)
        XCTAssertEqual(try runProcess(
            root.appendingPathComponent("scripts/resume-installed-signoff-commit.sh").path,
            [], environment: environment).0, 0)
        let tuple = Data("refs/heads/main \(head) refs/heads/main \(String(repeating: "0", count: 40))\n".utf8)
        let push = try runProcess(root.appendingPathComponent(".githooks/pre-push").path,
                                  ["origin", "unused"], input: tuple, environment: environment)
        XCTAssertEqual(push.0, 0, push.1)
        let replay = try runProcess(root.appendingPathComponent(".githooks/pre-push").path,
                                    ["origin", "unused"], input: tuple, environment: environment)
        XCTAssertEqual(replay.0, 0, replay.1)
        let different = Data("refs/heads/other \(head) refs/heads/other \(String(repeating: "0", count: 40))\n".utf8)
        XCTAssertNotEqual(try runProcess(
            root.appendingPathComponent(".githooks/pre-push").path, ["origin", "unused"],
            input: different, environment: environment).0, 0)
        XCTAssertNotEqual(try runProcess(
            root.appendingPathComponent("scripts/observe-installed-signoff.sh").path, []).0, 0)
        XCTAssertNotEqual(try runProcess(
            root.appendingPathComponent("scripts/designer-attest-installed-signoff.sh").path, []).0, 0)
        let status = try runProcess(probe.path,
                                    ["clean", root.path, "status"], environment: environment)
        XCTAssertEqual(status.0, 0, status.1)
        XCTAssertTrue(status.1.contains("state=pushArmed"), status.1)
        AdversarialRowsV16.emit(category: 7)
    }

    func testAdversarialCategory08ConcurrencyAndEverySecureStoreBoundary() throws {
        let addStore = try EphemeralReceiptStateStore()
        addStore.faults = [.add]
        let addGate = try ReleaseGateCoordinator(store: addStore, root: try temporaryDirectory())
        XCTAssertThrowsError(try addGate.create(payload()))
        let deleteStore = try EphemeralReceiptStateStore(initial: payload())
        deleteStore.faults = [.delete]
        XCTAssertThrowsError(try deleteStore.delete())
        for fault in [EphemeralReceiptStateStore.Fault.load, .beforeUpdate, .afterUpdate] {
            let store = try EphemeralReceiptStateStore(initial: payload())
            store.faults = [fault]
            let gate = try ReleaseGateCoordinator(store: store, root: try temporaryDirectory())
            XCTAssertThrowsError(try gate.transition(
                from: .prepared, to: .observedPendingDesigner, expectedSequence: 0))
            store.faults = []
            XCTAssertEqual(try gate.authoritative().state,
                           fault == .afterUpdate ? .observedPendingDesigner : .prepared)
        }
        let malformedStore = try EphemeralReceiptStateStore(initial: payload())
        malformedStore.replaceForTest(Data("malformed".utf8))
        XCTAssertThrowsError(try malformedStore.load()) {
            XCTAssertEqual($0 as? ReleaseGateError, .malformed)
        }

        let store = try EphemeralReceiptStateStore()
        let gate = try ReleaseGateCoordinator(store: store, root: try temporaryDirectory())
        try gate.create(payload())
        let queue = DispatchQueue(label: "release-gate-category-8", attributes: .concurrent)
        let group = DispatchGroup(), lock = NSLock()
        var successes = 0
        for _ in 0..<32 {
            group.enter()
            queue.async {
                defer { group.leave() }
                if (try? gate.transition(from: .prepared, to: .observedPendingDesigner,
                                         expectedSequence: 0)) != nil {
                    lock.withLock { successes += 1 }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try gate.authoritative().state, .observedPendingDesigner)
        AdversarialRowsV16.emit(category: 8)
    }

    private func runExecutable(_ executable: URL, _ arguments: [String],
                               timeout: TimeInterval = 10) throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate(); throw ReleaseGateError.unavailable }
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = repositoryRoot
        process.standardOutput = output; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReleaseGateError.persistence }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
