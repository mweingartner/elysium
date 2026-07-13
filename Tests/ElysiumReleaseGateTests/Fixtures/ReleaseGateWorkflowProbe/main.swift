import Darwin
import Foundation
import ElysiumReleaseGate

private final class FileReceiptStore: ReceiptStateStore, @unchecked Sendable {
    private let url: URL
    init(_ url: URL) { self.url = url }
    func load() throws -> ReleaseGatePayload {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReleaseGateError.absent }
        return try ReleaseGateCodec.decode(Data(contentsOf: url))
    }
    func add(_ value: ReleaseGatePayload) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ReleaseGateError.duplicate }
        try DurablePrivateFileWriter.write(try ReleaseGateCodec.encode(value), to: url)
    }
    func checkedUpdate(expectedSequence: UInt64, value: ReleaseGatePayload) throws {
        guard try load().sequence == expectedSequence else { throw ReleaseGateError.staleSequence }
        try FileManager.default.removeItem(at: url)
        try DurablePrivateFileWriter.write(try ReleaseGateCodec.encode(value), to: url)
    }
    func delete() throws { try? FileManager.default.removeItem(at: url) }
}

private enum ProbeScenario: String, CaseIterable {
    case clean, staleGeneratedRelease = "stale-generated-release"
}

private final class ProbeDependencies: ReleaseGateCommandDependencies {
    private let repository: URL
    private let gate: ReleaseGateCoordinator
    private let executable: URL
    private let scenario: ProbeScenario
    private lazy var context: ReleaseGateWorkflowContext = makeContext()

    init(repository: URL, scenario: ProbeScenario) throws {
        guard let repositoryResolved = realpath(repository.path, nil) else {
            throw ReleaseGateError.unsafePath
        }
        defer { free(repositoryResolved) }
        self.repository = URL(fileURLWithPath: String(cString: repositoryResolved))
        self.scenario = scenario
        guard let resolved = realpath(CommandLine.arguments[0], nil) else {
            throw ReleaseGateError.unsafePath
        }
        defer { free(resolved) }
        executable = URL(fileURLWithPath: String(cString: resolved))
        let authority = self.repository.appendingPathComponent(".probe-authority")
        try ReleaseGateCoordinator.ensurePrivateDirectory(authority)
        gate = try ReleaseGateCoordinator(
            store: FileReceiptStore(authority.appendingPathComponent("authority.bin")),
            root: authority.appendingPathComponent("cache"))
    }

    func coordinator() throws -> ReleaseGateCoordinator { gate }
    func arrangeScenario() throws {
        guard scenario == .staleGeneratedRelease else { return }
        let url = context.releaseExecutable
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try Data("stale-generated-release".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }
    func workflowContext() throws -> ReleaseGateWorkflowContext { context }
    func preparationFacts() throws -> ReleaseGatePreparationFacts {
        let tracked = try git(["ls-files", "-z"]).stdout
        return .init(
            repositoryRootDigest: AutomatedGateEvidence.sha256(Data(repository.path.utf8)),
            contentDigest: AutomatedGateEvidence.sha256(tracked),
            contentCount: tracked.split(separator: 0).count,
            checklistDigest: String(repeating: "3", count: 64),
            observerDigest: String(repeating: "4", count: 64))
    }
    func commandRunner() -> any ClosedCommandRunning { FoundationClosedCommandRunner() }
    func installAndObserve(
        release: StableFileIdentity, manifestURL: URL, context: ReleaseGateWorkflowContext
    ) throws -> ReleaseGateInstalledFacts {
        try StableFileHasher.revalidate(release)
        try FileManager.default.createDirectory(
            at: context.stagedBundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        let staged = context.stagedBundle.appendingPathComponent("Contents/MacOS/Elysium")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: context.installedExecutable, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let installed = try StableFileHasher.capture(
            context.installedExecutable, exactCanonicalPath: context.installedExecutable.path,
            requireExecutable: true)
        let requirement = "identifier \"com.briangao.elysium\""
        let cdhash = AutomatedGateEvidence.sha256(Data("fixture-cdhash".utf8))
        let manifest = Data("""
        release_path=\(release.canonicalPath)
        bundle_path=\(context.stagedBundle.path)
        executable_path=\(staged.path)
        pre_sign_input_sha256=\(release.sha256)
        pre_sign_staged_sha256=\(release.sha256)
        post_sign_executable_sha256=\(installed.sha256)
        bundle_id=\(context.bundleID)
        cdhash=\(cdhash)
        designated_requirement=\(requirement)
        sealed_resources=true
        """.utf8)
        try DurablePrivateFileWriter.write(manifest, to: manifestURL)
        return .init(
            manifest: manifest, installedIdentity: installed, identifier: context.bundleID,
            cdhash: cdhash, signingRequirement: requirement,
            liveProcess: try LiveProcessKernelIdentityReader.capture(pid: getpid()))
    }
    func randomChallengeBytes() throws -> [UInt8] { Array(repeating: 0x5a, count: 32) }
    func nowEpochSeconds() -> Int64 { Int64(Date().timeIntervalSince1970) }
    func preflightSummary() throws -> [String] { ["fixture preflight complete"] }
    func validateCurrent(_ payload: ReleaseGatePayload) throws {
        guard payload.expiresEpochSeconds > nowEpochSeconds(),
              payload.repositoryRootDigest ==
                AutomatedGateEvidence.sha256(Data(repository.path.utf8)) else {
            throw ReleaseGateError.evidence
        }
    }
    func readObservationConsent(prompt: String) throws -> String? {
        prompt.split(separator: " ").first(where: { $0.hasPrefix("OBSERVE-") })
            .map(String.init)
    }
    func captureInstalledObservation(
        payload: ReleaseGatePayload, directory: URL
    ) throws -> ReleaseGateObservationFacts {
        try ReleaseGateCoordinator.ensurePrivateDirectory(directory)
        for index in 1...14 {
            let prefix = String(format: "%02d-fixture-%02d", index, index)
            let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            let operation = Data("capture=0 ax=-1 screenshot_bytes=8\n".utf8)
            let command: [String: Any] = [
                "schema": "ElysiumInstalledCommandEvidenceV1", "commandID": "fixture-\(index)",
                "captureStatus": 0, "axStatus": -1, "windowID": 1,
                "screenshotSHA256": AutomatedGateEvidence.sha256(png),
                "axReportSHA256": "",
                "operationLogSHA256": AutomatedGateEvidence.sha256(operation),
            ]
            try DurablePrivateFileWriter.write(png, to: directory.appendingPathComponent("\(prefix).png"))
            try DurablePrivateFileWriter.write(operation, to: directory.appendingPathComponent("\(prefix).operation.log"))
            try DurablePrivateFileWriter.write(
                JSONSerialization.data(withJSONObject: command, options: [.sortedKeys]),
                to: directory.appendingPathComponent("\(prefix).command.json"))
        }
        return .init(processID: getpid(),
                     processStart: try LiveProcessKernelIdentityReader.capture(pid: getpid()).startIdentity)
    }
    func reviewInstalledObservation(
        payload: ReleaseGatePayload, directory: URL, prompt: String
    ) throws -> ReleaseGateDesignerFacts {
        let answer = prompt.split(separator: " ").first(where: { $0.hasPrefix("DESIGN-") })
            .map(String.init)
        return .init(
            rawLine: answer, processID: getpid(),
            processStart: try LiveProcessKernelIdentityReader.capture(pid: getpid()).startIdentity,
            timestamp: nowEpochSeconds())
    }
    func emitPublicLine(_ line: String) { print(line) }
    func requireIndexMatchesWorktree() throws {
        guard try git(["diff", "--quiet"]).status == 0 else { throw ReleaseGateError.evidence }
    }
    func currentHead() throws -> String {
        String(decoding: try git(["rev-parse", "HEAD"]).stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func parent(of commit: String) throws -> String {
        String(decoding: try git(["show", "-s", "--format=%P", commit]).stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeContext() -> ReleaseGateWorkflowContext {
        let output = try! git(["build-bin-path"]).stdout
        let bin = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            repository: repository,
            evidenceRoot: repository.appendingPathComponent(".probe-authority/evidence"),
            releaseExecutable: URL(fileURLWithPath: bin).resolvingSymlinksInPath()
                .appendingPathComponent("Elysium"),
            stagedBundle: repository.appendingPathComponent("dist/Elysium.app"),
            installedBundle: executable.deletingLastPathComponent(),
            installedExecutable: executable, bundleID: "com.briangao.elysium",
            expirySeconds: 600)
    }

    private func git(_ arguments: [String]) throws -> (status: Int32, stdout: Data) {
        let process = Process(), pipe = Pipe()
        if arguments == ["build-bin-path"] {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = ["build", "-c", "release", "--show-bin-path"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
        }
        process.currentDirectoryURL = repository
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReleaseGateError.evidence }
        return (process.terminationStatus, pipe.fileHandleForReading.readDataToEndOfFile())
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3, let scenario = ProbeScenario(rawValue: arguments[0]) else {
        throw ReleaseGateError.malformed
    }
    let repository = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let dependencies = try ProbeDependencies(repository: repository, scenario: scenario)
    try dependencies.arrangeScenario()
    let result = try ReleaseGateCommandDispatcher(dependencies: dependencies)
        .dispatch(arguments: Array(arguments.dropFirst(2)))
    result.lines.forEach { print($0) }
} catch {
    FileHandle.standardError.write(Data("Workflow probe failed.\n".utf8))
    exit(1)
}
