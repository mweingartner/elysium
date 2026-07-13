import AppKit
import CryptoKit
import Darwin
import Foundation
import ElysiumReleaseGate
import Security

private enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "release gate failed" }
}

private let fm = FileManager.default
private let encoder: JSONEncoder = { let v = JSONEncoder(); v.outputFormatting = [.sortedKeys]; return v }()

private func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process(), output = Pipe(), error = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                       "LANG": "C", "LC_ALL": "C",
                       "TMPDIR": FileManager.default.temporaryDirectory.path]
    if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
        environment["DEVELOPER_DIR"] = developer
    }
    process.environment = environment
    process.standardOutput = output; process.standardError = error
    if let input {
        let pipe = Pipe(); process.standardInput = pipe; try process.run()
        pipe.fileHandleForWriting.write(input); try pipe.fileHandleForWriting.close()
    } else { try process.run() }
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.message(String(decoding: err, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "command failed")
    }
    return out
}
private func git(_ args: [String], input: Data? = nil) throws -> Data { try run("/usr/bin/git", args, input: input) }
private func digest(_ data: Data) -> String { AutomatedGateEvidence.sha256(data) }
func fileDigest(_ path: String) throws -> String { digest(try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) }
private func canonical(_ path: String) throws -> String {
    guard let value = realpath(path, nil) else { throw CLIError.message("path identity failed") }
    defer { free(value) }; return String(cString: value)
}
let repositoryRoot: String = {
    guard let raw = try? git(["rev-parse", "--show-toplevel"]),
          let value = try? canonical(String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else { return "" }
    return value
}()
let rootDigest = digest(Data(repositoryRoot.utf8))
private let support = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support")
let authorityRoot = support.appendingPathComponent("Elysium/InstalledSignoffAuthority/\(rootDigest)")
let evidenceRoot = authorityRoot.appendingPathComponent("evidence")

func productionCoordinator() throws -> ReleaseGateCoordinator {
    try ReleaseGateCoordinator(
        store: KeychainReceiptStateStore(productionRepositoryRootDigest: rootDigest),
        root: authorityRoot, validator: { try validateArtifactContinuity($0) })
}
private func nulStrings(_ data: Data) throws -> [String] {
    try data.split(separator: 0).map {
        guard let value = String(data: $0, encoding: .utf8), !value.isEmpty else { throw CLIError.message("invalid repository path") }
        return value
    }
}
private func validPath(_ value: String) -> Bool {
    !value.hasPrefix("/") && !value.split(separator: "/").contains("..") &&
        ![".git/", ".build/", ".swiftpm/", "dist/"].contains(where: value.hasPrefix)
}
private struct Snapshot { let digest: String; let count: Int; let paths: [String]; let untracked: [String] }
private func appendRecord(_ stream: inout Data, path: String, mode: String, data: Data) {
    stream.append(Data("\(path)\0\(mode)\0\(data.count)\0\(digest(data))\0".utf8))
}
private func worktreeSnapshot() throws -> Snapshot {
    let tracked = try nulStrings(git(["ls-files", "-z"]))
    let untracked = try nulStrings(git(["ls-files", "--others", "--exclude-standard", "-z"]))
    let paths = (tracked + untracked).sorted()
    guard Set(paths).count == paths.count else { throw CLIError.message("duplicate repository path") }
    var stream = Data("elysium-content-v2\0".utf8)
    for path in paths {
        guard validPath(path) else { throw CLIError.message("unsafe repository path") }
        let url = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(path)
        var info = stat(); guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CLIError.message("unsupported repository entry")
        }
        let mode = info.st_mode & 0o111 == 0 ? "100644" : "100755"
        appendRecord(&stream, path: path, mode: mode, data: try Data(contentsOf: url))
    }
    return Snapshot(digest: digest(stream), count: paths.count, paths: paths, untracked: untracked.sorted())
}
private func indexSnapshot() throws -> Snapshot {
    let entries = try nulStrings(git(["ls-files", "--stage", "-z"]))
    var values: [(String, String, Data)] = []
    for entry in entries {
        guard let tab = entry.firstIndex(of: "\t") else { throw CLIError.message("malformed index") }
        let fields = entry[..<tab].split(separator: " "), path = String(entry[entry.index(after: tab)...])
        guard fields.count == 3, fields[2] == "0", validPath(path),
              ["100644", "100755"].contains(String(fields[0])) else { throw CLIError.message("unsafe index") }
        values.append((path, String(fields[0]), try git(["cat-file", "blob", String(fields[1])])))
    }
    values.sort { $0.0 < $1.0 }; var stream = Data("elysium-content-v2\0".utf8)
    values.forEach { appendRecord(&stream, path: $0.0, mode: $0.1, data: $0.2) }
    return Snapshot(digest: digest(stream), count: values.count, paths: values.map(\.0), untracked: [])
}
func evidenceDigest(_ directory: URL) throws -> String {
    try ReleaseGateCoordinator.requirePrivateDirectory(directory)
    guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { throw CLIError.message("evidence enumeration failed") }
    let urls = (enumerator.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
    var stream = Data("elysium-private-evidence-v2\0".utf8)
    for url in urls {
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw CLIError.message("evidence identity failed") }
        let relative = String(url.path.dropFirst(directory.path.count + 1))
        if info.st_mode & S_IFMT == S_IFDIR {
            guard info.st_mode & 0o777 == 0o700 else { throw CLIError.message("unsafe evidence directory") }
        } else {
            try ReleaseGateCoordinator.requirePrivateFile(url)
            appendRecord(&stream, path: relative, mode: "0600", data: try Data(contentsOf: url))
        }
    }
    return digest(stream)
}
private func copyEvidence(from source: URL, to destination: URL) throws {
    try ReleaseGateCoordinator.requirePrivateDirectory(source)
    try ReleaseGateCoordinator.ensurePrivateDirectory(destination)
    for name in try fm.contentsOfDirectory(atPath: source.path).sorted() {
        let input = source.appendingPathComponent(name), output = destination.appendingPathComponent(name)
        try ReleaseGateCoordinator.requirePrivateFile(input)
        guard !fm.fileExists(atPath: output.path) else { throw CLIError.message("duplicate evidence") }
        try fm.copyItem(at: input, to: output)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
func observerDigest() throws -> String {
    var bytes = Data("observer-v2\0".utf8)
    bytes.append(try Data(contentsOf: URL(fileURLWithPath: canonical(CommandLine.arguments[0]))))
    bytes.append(0)
    for path in ["scripts/observe-installed-signoff.swift", "scripts/observe-installed-signoff.sh",
                 "scripts/designer-attest-installed-signoff.swift",
                 "scripts/designer-attest-installed-signoff.sh", "scripts/run-release-gate-tool.sh"] {
        bytes.append(try Data(contentsOf: URL(fileURLWithPath: repositoryRoot).appendingPathComponent(path)))
        bytes.append(0)
    }
    return digest(bytes)
}
private func codesign(_ bundle: String) throws -> (identifier: String, cdhash: String, requirement: String) {
    _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle])
    let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-d", "--verbose=4", bundle]; process.standardError = pipe
    try process.run(); let raw = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let text = String(decoding: raw, as: UTF8.self)
    func value(_ prefix: String) -> String { text.split(separator: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "" }
    guard process.terminationStatus == 0, text.contains("Sealed Resources version=") else { throw CLIError.message("signature invalid") }
    let requirement = try CodesignRawCapture.capture(canonicalBundlePath: bundle)
    return (value("Identifier="), value("CDHash="), requirement)
}
private func validateArtifactContinuity(_ payload: ReleaseGatePayload) throws {
    guard payload.state != .preparing else { return }
    let expectedInstalled = "/Applications/Elysium.app/Contents/MacOS/Elysium"
    guard payload.artifacts.installedBundlePath == "/Applications/Elysium.app",
          payload.artifacts.installedExecutablePath == expectedInstalled else {
        throw CLIError.message("installed path identity changed")
    }
    let release = try StableFileHasher.capture(
        URL(fileURLWithPath: payload.artifacts.releasePath),
        exactCanonicalPath: payload.artifacts.releasePath, requireExecutable: true)
    let installed = try StableFileHasher.capture(
        URL(fileURLWithPath: expectedInstalled), exactCanonicalPath: expectedInstalled,
        requireExecutable: true)
    guard release.sha256 == payload.artifacts.releaseSHA256,
          installed.sha256 == payload.artifacts.installedSHA256 else {
        throw CLIError.message("artifact changed")
    }
    let signed = try codesign(payload.artifacts.installedBundlePath)
    guard signed.identifier == payload.artifacts.bundleID,
          signed.cdhash == payload.artifacts.installedCDHash,
          signed.requirement == payload.artifacts.signingRequirement else {
        throw CLIError.message("signature identity changed")
    }
}
func productionValidateCurrent(_ payload: ReleaseGatePayload) throws {
    guard payload.expiresEpochSeconds > Int64(Date().timeIntervalSince1970) else {
        throw CLIError.message("receipt expired")
    }
    try validateArtifactContinuity(payload)
    let content = try worktreeSnapshot()
    guard content.digest == payload.contentDigest, content.count == payload.contentCount,
          try evidenceDigest(evidenceRoot.appendingPathComponent(payload.receiptID)) ==
            payload.evidenceDigest else {
        throw CLIError.message("content or evidence changed")
    }
}
private func secureRandomChallengeBytes() throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CLIError.message("challenge generation failed") }
    return bytes
}

private func installAndObserveProduction(
    release: StableFileIdentity, manifestURL: URL,
    context: ReleaseGateWorkflowContext
) throws -> ReleaseGateInstalledFacts {
    _ = try run(repositoryRoot + "/elysium", ["install", "--no-build",
                "--executable-hash", release.sha256,
                "--manifest-output", manifestURL.path])
    try ReleaseGateCoordinator.requirePrivateFile(manifestURL)
    let manifest = try Data(contentsOf: manifestURL)
    let installed = try StableFileHasher.capture(
        context.installedExecutable, exactCanonicalPath: context.installedExecutable.path,
        requireExecutable: true)
    let signed = try codesign(context.installedBundle.path)
    _ = try run("/usr/bin/open", ["-a", context.installedBundle.path])
    let live = try waitForBoundElysiumProcess(
        expectedExecutable: installed, expectedCDHash: signed.cdhash,
        expectedRequirement: signed.requirement)
    return .init(
        manifest: manifest, installedIdentity: installed, identifier: signed.identifier,
        cdhash: signed.cdhash, signingRequirement: signed.requirement,
        liveProcess: .init(pid: live.pid, startIdentity: live.startIdentity,
                           executablePath: live.executablePath))
}
private func head() throws -> String { String(decoding: try git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

private final class ProductionReleaseGateDependencies: ReleaseGateCommandDependencies {
    func coordinator() throws -> ReleaseGateCoordinator { try productionCoordinator() }
    func workflowContext() throws -> ReleaseGateWorkflowContext {
        ReleaseGateWorkflowContext(
            repository: URL(fileURLWithPath: repositoryRoot), evidenceRoot: evidenceRoot,
            releaseExecutable: URL(fileURLWithPath:
                repositoryRoot + "/.build/out/Products/Release/Elysium"),
            stagedBundle: URL(fileURLWithPath: repositoryRoot + "/dist/Elysium.app"),
            installedBundle: URL(fileURLWithPath: "/Applications/Elysium.app"),
            installedExecutable: URL(fileURLWithPath:
                "/Applications/Elysium.app/Contents/MacOS/Elysium"),
            bundleID: "com.briangao.elysium")
    }
    func preparationFacts() throws -> ReleaseGatePreparationFacts {
        let value = try worktreeSnapshot()
        return .init(
            repositoryRootDigest: rootDigest, contentDigest: value.digest,
            contentCount: value.count,
            checklistDigest: try fileDigest("scripts/installed-signoff-checklist-v1.json"),
            observerDigest: try observerDigest())
    }
    func commandRunner() -> any ClosedCommandRunning { FoundationClosedCommandRunner() }
    func installAndObserve(
        release: StableFileIdentity, manifestURL: URL, context: ReleaseGateWorkflowContext
    ) throws -> ReleaseGateInstalledFacts {
        try installAndObserveProduction(release: release, manifestURL: manifestURL,
                                        context: context)
    }
    func randomChallengeBytes() throws -> [UInt8] { try secureRandomChallengeBytes() }
    func nowEpochSeconds() -> Int64 { Int64(Date().timeIntervalSince1970) }
    func preflightSummary() throws -> [String] {
        let value = try worktreeSnapshot()
        return ["Preflight complete. Tracked and untracked content was enumerated safely.",
                "content_items=\(value.count)"]
    }
    func validateCurrent(_ payload: ReleaseGatePayload) throws {
        try productionValidateCurrent(payload)
    }
    func readObservationConsent(prompt: String) throws -> String? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ReleaseGateError.authorization
        }
        print(prompt, terminator: " "); fflush(stdout)
        return readLine()
    }
    func captureInstalledObservation(
        payload: ReleaseGatePayload, directory: URL
    ) throws -> ReleaseGateObservationFacts {
        try captureIntegratedInstalledObservation(payload: payload, directory: directory)
    }
    func reviewInstalledObservation(
        payload: ReleaseGatePayload, directory: URL, prompt: String
    ) throws -> ReleaseGateDesignerFacts {
        try reviewIndependentDesignerAttestation(
            payload: payload, directory: directory, prompt: prompt)
    }
    func emitPublicLine(_ line: String) { print(line) }
    func requireIndexMatchesWorktree() throws {
        let work = try worktreeSnapshot(), index = try indexSnapshot()
        guard work.digest == index.digest, work.paths == index.paths else {
            throw CLIError.message("index/worktree mismatch")
        }
    }
    func currentHead() throws -> String { try head() }
    func parent(of commit: String) throws -> String {
        String(decoding: try git(["show", "-s", "--format=%P", commit]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@main struct InstalledSignoffReceiptCLI {
    static func main() {
        do { try execute() }
        catch {
            FileHandle.standardError.write(Data(
                "Installed sign-off command failed. No private diagnostic was printed.\n".utf8))
            exit(1)
        }
    }
    static func execute() throws {
        guard !repositoryRoot.isEmpty else { throw CLIError.message("repository root unavailable") }
        fm.changeCurrentDirectoryPath(repositoryRoot)
        let args = Array(CommandLine.arguments.dropFirst())
        let result = try ReleaseGateCommandDispatcher(
            dependencies: ProductionReleaseGateDependencies()).dispatch(arguments: args)
        result.lines.forEach { print($0) }
    }
}

private func XCT<T>(_ value: T?) throws -> T { guard let value else { throw CLIError.message("manifest field missing") }; return value }
