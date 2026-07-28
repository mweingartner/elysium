import Foundation

/// Fail-closed errors raised while decoding or validating the local debug protocol.
public enum DebugProtocolError: Error, Equatable, Sendable {
    case invalidSessionKeyLength(actual: Int, minimum: Int)
    case invalidSequence(UInt64)
    case unexpectedSequence(expected: UInt64, actual: UInt64)
    case sequenceExhausted
    case payloadTooLarge(actual: Int, maximum: Int)
    case invalidFrameLength(actual: Int, expected: Int?)
    case invalidMagic(UInt32)
    case unsupportedProtocolVersion(UInt16)
    case unknownFrameKind(UInt16)
    case authenticationFailed
    case truncatedFrame(pendingBytes: Int)
    case decoderFailed
    case invalidMessage(String)
    case invalidManifest(DebugManifestValidationFailure)
    case fileSystemFailure(String)
}

extension DebugProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSessionKeyLength(let actual, let minimum):
            return "Debug session key is \(actual) bytes; at least \(minimum) bytes are required."
        case .invalidSequence(let sequence):
            return "Debug frame sequence \(sequence) is invalid."
        case .unexpectedSequence(let expected, let actual):
            return "Expected debug frame sequence \(expected), received \(actual)."
        case .sequenceExhausted:
            return "Debug frame sequence is exhausted."
        case .payloadTooLarge(let actual, let maximum):
            return "Debug frame payload is \(actual) bytes; the maximum is \(maximum)."
        case .invalidFrameLength(let actual, let expected):
            if let expected {
                return "Debug frame is \(actual) bytes; exactly \(expected) bytes were required."
            }
            return "Debug frame has an invalid length of \(actual) bytes."
        case .invalidMagic(let value):
            return String(format: "Invalid debug frame magic 0x%08x.", value)
        case .unsupportedProtocolVersion(let version):
            return "Unsupported debug protocol version \(version)."
        case .unknownFrameKind(let kind):
            return "Unknown debug frame kind \(kind)."
        case .authenticationFailed:
            return "Debug frame authentication failed."
        case .truncatedFrame(let pendingBytes):
            return "Debug stream ended with \(pendingBytes) pending bytes."
        case .decoderFailed:
            return "Debug frame decoder is already in a failed state."
        case .invalidMessage(let reason):
            return "Invalid debug protocol message: \(reason)."
        case .invalidManifest(let failure):
            return "Invalid debug session manifest: \(failure.rawValue)."
        case .fileSystemFailure(let operation):
            return "Debug protocol file-system operation failed: \(operation)."
        }
    }
}

/// Stable categories for local manifest validation failures. These are safe to report
/// without placing the session token or arbitrary file contents in logs.
public enum DebugManifestValidationFailure: String, Codable, Equatable, Sendable {
    case invalidURL
    case invalidDirectory
    case directoryOwner
    case directoryPermissions
    case directoryReplaced
    case invalidFile
    case fileOwner
    case filePermissions
    case fileLinkCount
    case fileTooLarge
    case readFailed
    case decodeFailed
    case invalidFields
    case invalidProcessIdentity
    case processNotRunning
    case executableMismatch
    case executableHashMismatch
}
