import Darwin
import ElysiumDebugProtocol
import Foundation

enum ElysiumDebugExitCode: Int32 {
    case success = 0
    case usage = 2
    case manifest = 3
    case transport = 4
    case protocolFailure = 5
    case remoteFailure = 6
}

enum ElysiumDebugCLIError: Error {
    case usage(String)
    case manifest(String)
    case transport(String)
    case protocolFailure(String)

    var exitCode: ElysiumDebugExitCode {
        switch self {
        case .usage:
            return .usage
        case .manifest:
            return .manifest
        case .transport:
            return .transport
        case .protocolFailure:
            return .protocolFailure
        }
    }

    var category: String {
        switch self {
        case .usage:
            return "usage"
        case .manifest:
            return "manifest"
        case .transport:
            return "transport"
        case .protocolFailure:
            return "protocol"
        }
    }

    var safeMessage: String {
        switch self {
        case .usage(let message), .manifest(let message), .transport(let message),
             .protocolFailure(let message):
            return message
        }
    }
}

struct ElysiumDebugCLI {
    static let defaultTimeoutSeconds = 10.0
    static let maximumTimeoutSeconds = 300.0
    static let maximumInlineJSONBytes = 64 * 1024
    static let maximumScenarioBytes = 8 * 1024 * 1024
    static let maximumScenarioLineBytes = 64 * 1024
    static let maximumScenarioSteps = 4_096

    private struct Options {
        let manifestURL: URL
        let timeoutSeconds: Double
        let command: Command
    }

    private enum Command {
        case help
        case status
        case snapshot([String: JSONValue])
        case capabilities
        case request(operation: String, arguments: [String: JSONValue])
        case scenario(URL)
        case stream
    }

    private struct ErrorOutput: Encodable {
        let ok = false
        let category: String
        let message: String
    }

    static func run(arguments: [String]) -> ElysiumDebugExitCode {
        do {
            let options = try parse(arguments: arguments)
            if case .help = options.command {
                FileHandle.standardOutput.write(Data(helpText.utf8))
                return .success
            }

            let scenarioSteps: [ScenarioStep]?
            if case .scenario(let url) = options.command {
                scenarioSteps = try loadScenario(from: url)
            } else {
                scenarioSteps = nil
            }

            let manifest: DebugSessionManifest
            do {
                manifest = try DebugManifestValidator.loadSecurely(from: options.manifestURL)
            } catch {
                throw ElysiumDebugCLIError.manifest(safeDescription(of: error))
            }

            let client = try ElysiumDebugClient(
                manifest: manifest,
                timeoutSeconds: options.timeoutSeconds
            )
            defer { client.close() }

            do {
                _ = try client.connectAndAuthenticate()
            } catch let error as ElysiumDebugCLIError {
                throw error
            } catch {
                throw ElysiumDebugCLIError.protocolFailure(safeDescription(of: error))
            }

            switch options.command {
            case .help:
                return .success
            case .capabilities:
                return try execute(
                    operation: "session.capabilities",
                    arguments: [:],
                    using: client,
                    timeoutSeconds: options.timeoutSeconds
                )
            case .status:
                return try execute(
                    operation: "session.status",
                    arguments: [:],
                    using: client,
                    timeoutSeconds: options.timeoutSeconds
                )
            case .snapshot(let arguments):
                return try execute(
                    operation: "state.snapshot",
                    arguments: arguments,
                    using: client,
                    timeoutSeconds: options.timeoutSeconds
                )
            case .request(let operation, let arguments):
                return try execute(
                    operation: operation,
                    arguments: arguments,
                    using: client,
                    timeoutSeconds: options.timeoutSeconds
                )
            case .scenario:
                guard let steps = scenarioSteps else {
                    throw ElysiumDebugCLIError.protocolFailure("scenario was not prepared")
                }
                for step in steps {
                    let request = try step.makeRequest(defaultTimeoutSeconds: options.timeoutSeconds)
                    let response = try client.send(request: request)
                    try writeJSON(response)
                    if !response.isSuccess {
                        return .remoteFailure
                    }
                }
                return .success
            case .stream:
                return try executeStream(using: client, timeoutSeconds: options.timeoutSeconds)
            }
        } catch let error as ElysiumDebugCLIError {
            writeError(category: error.category, message: error.safeMessage)
            return error.exitCode
        } catch let error as DebugProtocolError {
            writeError(category: "protocol", message: safeDescription(of: error))
            return .protocolFailure
        } catch {
            writeError(category: "protocol", message: safeDescription(of: error))
            return .protocolFailure
        }
    }

    private static func execute(
        operation: String,
        arguments: [String: JSONValue],
        using client: ElysiumDebugClient,
        timeoutSeconds: Double
    ) throws -> ElysiumDebugExitCode {
        let request = try DebugRequest(
            operation: operation,
            arguments: arguments,
            deadlineUptimeNanoseconds: try monotonicDeadline(after: timeoutSeconds)
        )
        let response = try client.send(request: request)
        try writeJSON(response)
        return response.isSuccess ? .success : .remoteFailure
    }

    private static func parse(arguments: [String]) throws -> Options {
        var manifestURL = defaultManifestURL
        var timeoutSeconds = defaultTimeoutSeconds
        var index = 0

        if arguments.isEmpty {
            return Options(manifestURL: manifestURL, timeoutSeconds: timeoutSeconds, command: .help)
        }

        while index < arguments.count, arguments[index].hasPrefix("--") {
            let option = arguments[index]
            if option == "--help" {
                return Options(manifestURL: manifestURL, timeoutSeconds: timeoutSeconds, command: .help)
            } else if option == "--manifest" {
                index += 1
                guard index < arguments.count else {
                    throw ElysiumDebugCLIError.usage("--manifest requires a path")
                }
                manifestURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            } else if option.hasPrefix("--manifest=") {
                let value = String(option.dropFirst("--manifest=".count))
                guard !value.isEmpty else {
                    throw ElysiumDebugCLIError.usage("--manifest requires a path")
                }
                manifestURL = URL(fileURLWithPath: value).standardizedFileURL
            } else if option == "--timeout" {
                index += 1
                guard index < arguments.count else {
                    throw ElysiumDebugCLIError.usage("--timeout requires seconds")
                }
                timeoutSeconds = try parseTimeout(arguments[index])
            } else if option.hasPrefix("--timeout=") {
                let value = String(option.dropFirst("--timeout=".count))
                timeoutSeconds = try parseTimeout(value)
            } else {
                throw ElysiumDebugCLIError.usage("unknown option: \(option)")
            }
            index += 1
        }

        guard index < arguments.count else {
            throw ElysiumDebugCLIError.usage("missing command")
        }
        let commandName = arguments[index]
        let commandArguments = Array(arguments.dropFirst(index + 1))
        let command: Command

        switch commandName {
        case "help":
            guard commandArguments.isEmpty else {
                throw ElysiumDebugCLIError.usage("help takes no arguments")
            }
            command = .help
        case "status":
            guard commandArguments.isEmpty else {
                throw ElysiumDebugCLIError.usage("status takes no arguments")
            }
            command = .status
        case "snapshot":
            guard commandArguments.count <= 1 else {
                throw ElysiumDebugCLIError.usage("snapshot accepts at most one JSON object")
            }
            let arguments = try decodeArguments(commandArguments.first)
            try validateRequestShape(operation: "state.snapshot", arguments: arguments)
            command = .snapshot(arguments)
        case "capabilities":
            guard commandArguments.isEmpty else {
                throw ElysiumDebugCLIError.usage("capabilities takes no arguments")
            }
            command = .capabilities
        case "request":
            guard commandArguments.count == 1 || commandArguments.count == 2 else {
                throw ElysiumDebugCLIError.usage("request requires OP and an optional JSON object")
            }
            let arguments = try decodeArguments(commandArguments.count == 2 ? commandArguments[1] : nil)
            try validateRequestShape(operation: commandArguments[0], arguments: arguments)
            command = .request(operation: commandArguments[0], arguments: arguments)
        case "scenario":
            guard commandArguments.count == 1 else {
                throw ElysiumDebugCLIError.usage("scenario requires one JSONL path")
            }
            command = .scenario(URL(fileURLWithPath: commandArguments[0]).standardizedFileURL)
        case "stream":
            guard commandArguments.isEmpty else {
                throw ElysiumDebugCLIError.usage("stream takes no arguments")
            }
            command = .stream
        default:
            throw ElysiumDebugCLIError.usage("unknown command: \(commandName)")
        }

        return Options(manifestURL: manifestURL, timeoutSeconds: timeoutSeconds, command: command)
    }

    private static func parseTimeout(_ value: String) throws -> Double {
        guard let timeout = Double(value), timeout.isFinite,
              timeout >= 0.1, timeout <= maximumTimeoutSeconds else {
            throw ElysiumDebugCLIError.usage(
                "timeout must be between 0.1 and \(Int(maximumTimeoutSeconds)) seconds"
            )
        }
        return timeout
    }

    private static func decodeArguments(_ text: String?) throws -> [String: JSONValue] {
        guard let text else { return [:] }
        guard !text.isEmpty, text.utf8.count <= maximumInlineJSONBytes else {
            throw ElysiumDebugCLIError.usage("JSON object is empty or exceeds 64 KiB")
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard case .object(let object) = value else {
                throw ElysiumDebugCLIError.usage("arguments must be a JSON object")
            }
            return object
        } catch let error as ElysiumDebugCLIError {
            throw error
        } catch {
            throw ElysiumDebugCLIError.usage("invalid JSON object")
        }
    }

    private static var defaultManifestURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("Elysium Debug", isDirectory: true)
            .appendingPathComponent("Control", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
    }

    private static func loadScenario(from url: URL) throws -> [ScenarioStep] {
        let data: Data
        do {
            data = try readBoundedFile(at: url, maximumBytes: maximumScenarioBytes)
        } catch let error as ElysiumDebugCLIError {
            throw error
        } catch {
            throw ElysiumDebugCLIError.usage("could not read scenario file")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ElysiumDebugCLIError.usage("scenario must be UTF-8 JSONL")
        }

        var steps: [ScenarioStep] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
            if line.allSatisfy({ $0.isWhitespace }) { continue }
            guard line.utf8.count <= maximumScenarioLineBytes else {
                throw ElysiumDebugCLIError.usage("scenario line \(offset + 1) exceeds 64 KiB")
            }
            guard steps.count < maximumScenarioSteps else {
                throw ElysiumDebugCLIError.usage("scenario exceeds \(maximumScenarioSteps) steps")
            }
            do {
                let step = try JSONDecoder().decode(ScenarioStep.self, from: Data(line.utf8))
                try step.validateRequestShape()
                steps.append(step)
            } catch {
                throw ElysiumDebugCLIError.usage("invalid scenario step on line \(offset + 1)")
            }
        }
        guard !steps.isEmpty else {
            throw ElysiumDebugCLIError.usage("scenario contains no requests")
        }
        return steps
    }

    private static func readBoundedFile(at url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else {
            throw ElysiumDebugCLIError.usage("scenario path must be a file path")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ElysiumDebugCLIError.usage("could not open scenario file")
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw ElysiumDebugCLIError.usage("scenario path is not a regular file")
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumBytes) else {
            throw ElysiumDebugCLIError.usage("scenario file exceeds 8 MiB")
        }

        var result = Data()
        result.reserveCapacity(min(Int(status.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - result.count))
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw ElysiumDebugCLIError.usage("could not read scenario file")
            }
        }
        guard result.count <= maximumBytes else {
            throw ElysiumDebugCLIError.usage("scenario file exceeds 8 MiB")
        }
        return result
    }

    /// Reads and executes JSONL incrementally while retaining one authenticated connection. This
    /// is the low-latency control path for an agent: commands are not preloaded and each response
    /// is flushed before the next line is accepted. Per-line and per-session limits keep stdin
    /// from becoming an unbounded allocation or request stream.
    private static func executeStream(
        using client: ElysiumDebugClient,
        timeoutSeconds: Double
    ) throws -> ElysiumDebugExitCode {
        var reader = BoundedStandardInputLineReader(maximumLineBytes: maximumScenarioLineBytes)
        var lineNumber = 0
        var requestCount = 0
        while let line = try reader.nextLine() {
            lineNumber += 1
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0d }) { continue }
            guard requestCount < maximumScenarioSteps else {
                throw ElysiumDebugCLIError.usage(
                    "stream exceeds \(maximumScenarioSteps) requests; reconnect to continue"
                )
            }
            let step: ScenarioStep
            do {
                step = try JSONDecoder().decode(ScenarioStep.self, from: Data(line))
                try step.validateRequestShape()
            } catch {
                throw ElysiumDebugCLIError.usage("invalid stream step on line \(lineNumber)")
            }
            requestCount += 1
            let request = try step.makeRequest(defaultTimeoutSeconds: timeoutSeconds)
            let response = try client.send(request: request)
            try writeJSON(response)
            if !response.isSuccess { return .remoteFailure }
        }
        return .success
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private static func writeError(category: String, message: String) {
        let output = ErrorOutput(category: category, message: String(message.prefix(512)))
        if let data = try? JSONEncoder.sorted.encode(output) {
            var line = data
            line.append(0x0a)
            FileHandle.standardError.write(line)
        } else {
            FileHandle.standardError.write(Data("{\"category\":\"internal\",\"message\":\"error encoding failed\",\"ok\":false}\n".utf8))
        }
    }

    private static func safeDescription(of error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription, !description.isEmpty {
            return String(description.prefix(512))
        }
        return String(String(describing: error).prefix(512))
    }

    private static func monotonicDeadline(after timeoutSeconds: Double) throws -> UInt64 {
        let delta = UInt64(timeoutSeconds * 1_000_000_000)
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(delta)
        guard !overflow, deadline > 0 else {
            throw ElysiumDebugCLIError.usage("timeout is out of range")
        }
        return deadline
    }

    private static func validateRequestShape(
        operation: String,
        arguments: [String: JSONValue]
    ) throws {
        do {
            _ = try DebugRequest(
                operation: operation,
                arguments: arguments,
                deadlineUptimeNanoseconds: 1
            )
        } catch {
            throw ElysiumDebugCLIError.usage("invalid request operation or arguments")
        }
    }

    private static let helpText = """
    Usage: elydebug [--manifest PATH] [--timeout SECONDS] COMMAND

    Securely controls the currently running Elysium Debug app on 127.0.0.1.

    Commands:
      status                         Show the live debug-session status.
      snapshot [JSON_OBJECT]         Read a bounded state snapshot.
      capabilities                   Show authenticated server capabilities.
      request OP [JSON_OBJECT]       Send one protocol operation.
      scenario JSONL_PATH            Send JSONL requests over one connection.
      stream                         Stream JSONL from stdin over one connection.
      help                           Show this help.

    Global options:
      --manifest PATH                Secure session manifest. Default:
                                     ~/Library/Caches/Elysium Debug/Control/session.json
      --timeout SECONDS              Per-connect/request timeout (0.1...300; default 10).
      --help                         Show this help.

    Scenario lines are JSON objects with `operation`, optional `arguments`,
    `expectedEpoch`, `expectedRevision`, `deadlineUptimeNanoseconds`, and `id`.
    Output is JSON (one response per line for scenarios and streams). Remote and protocol
    errors return a nonzero status. The session token is never printed.
    """ + "\n"
}

private struct BoundedStandardInputLineReader {
    private let maximumLineBytes: Int
    private var buffered: [UInt8] = []
    private var reachedEOF = false

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        buffered.reserveCapacity(min(maximumLineBytes, 4_096))
    }

    mutating func nextLine() throws -> [UInt8]? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0a) {
                var line = Array(buffered[..<newline])
                buffered.removeFirst(newline + 1)
                if line.last == 0x0d { line.removeLast() }
                return line
            }
            if reachedEOF {
                guard !buffered.isEmpty else { return nil }
                var line = buffered
                buffered.removeAll(keepingCapacity: true)
                if line.last == 0x0d { line.removeLast() }
                return line
            }
            guard buffered.count <= maximumLineBytes else {
                throw ElysiumDebugCLIError.usage("stream line exceeds 64 KiB")
            }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count > 0 {
                buffered.append(contentsOf: chunk.prefix(count))
                if let newline = buffered.firstIndex(of: 0x0a) {
                    guard newline <= maximumLineBytes else {
                        throw ElysiumDebugCLIError.usage("stream line exceeds 64 KiB")
                    }
                } else if buffered.count > maximumLineBytes {
                    throw ElysiumDebugCLIError.usage("stream line exceeds 64 KiB")
                }
            } else if count == 0 {
                reachedEOF = true
            } else if errno != EINTR {
                throw ElysiumDebugCLIError.transport("could not read stream input")
            }
        }
    }
}

private struct ScenarioStep: Decodable {
    let protocolVersion: UInt16
    let id: UUID
    let operation: String
    let arguments: [String: JSONValue]
    let expectedEpoch: UInt64?
    let expectedRevision: UInt64?
    let deadlineUptimeNanoseconds: UInt64?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion, id, operation, arguments
        case expectedEpoch, expectedRevision, deadlineUptimeNanoseconds
    }

    init(from decoder: Decoder) throws {
        let untyped = try decoder.container(keyedBy: ScenarioCodingKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard untyped.allKeys.allSatisfy({ allowedKeys.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown scenario field"
            ))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(UInt16.self, forKey: .protocolVersion)
            ?? ElysiumDebugProtocolVersion.current
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        operation = try container.decode(String.self, forKey: .operation)
        arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
        expectedEpoch = try container.decodeIfPresent(UInt64.self, forKey: .expectedEpoch)
        expectedRevision = try container.decodeIfPresent(UInt64.self, forKey: .expectedRevision)
        deadlineUptimeNanoseconds = try container.decodeIfPresent(
            UInt64.self,
            forKey: .deadlineUptimeNanoseconds
        )
    }

    func makeRequest(defaultTimeoutSeconds: Double) throws -> DebugRequest {
        let deadline: UInt64
        if let deadlineUptimeNanoseconds {
            deadline = deadlineUptimeNanoseconds
        } else {
            let delta = UInt64(defaultTimeoutSeconds * 1_000_000_000)
            let (value, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(delta)
            guard !overflow, value > 0 else {
                throw ElysiumDebugCLIError.usage("scenario timeout is out of range")
            }
            deadline = value
        }
        return try DebugRequest(
            protocolVersion: protocolVersion,
            id: id,
            operation: operation,
            arguments: arguments,
            expectedEpoch: expectedEpoch,
            expectedRevision: expectedRevision,
            deadlineUptimeNanoseconds: deadline
        )
    }

    func validateRequestShape() throws {
        _ = try DebugRequest(
            protocolVersion: protocolVersion,
            id: id,
            operation: operation,
            arguments: arguments,
            expectedEpoch: expectedEpoch,
            expectedRevision: expectedRevision,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds ?? 1
        )
    }
}

private struct ScenarioCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
