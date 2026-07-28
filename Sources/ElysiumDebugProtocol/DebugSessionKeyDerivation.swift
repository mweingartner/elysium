import CryptoKit
import Foundation

/// Derives a fresh per-connection frame key from the descriptor token and a server nonce.
/// Binding the session and build identities prevents a valid transcript from being moved
/// to another running Elysium instance even when both connections begin at sequence one.
public enum DebugSessionKeyDerivation {
    public static let challengeByteCount = 32
    public static let derivedKeyByteCount = 32
    public static let connectionDomain = "dev.elysium.debug.connection-key.v1"

    public static func randomServerChallenge() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func deriveConnectionKey(
        token: DebugSessionToken,
        serverChallenge: Data,
        sessionID: UUID,
        buildIdentifier: String
    ) throws -> Data {
        guard serverChallenge.count == challengeByteCount else {
            throw DebugProtocolError.invalidMessage("server challenge length")
        }
        let buildBytes = Data(buildIdentifier.utf8)
        guard !buildBytes.isEmpty, buildBytes.count <= 128,
              buildBytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            throw DebugProtocolError.invalidMessage("build identifier")
        }

        var info = Data(connectionDomain.utf8)
        info.append(0)
        debugKeyAppendBigEndian(ElysiumDebugProtocolVersion.current, to: &info)
        info.append(0)
        info.append(Data(sessionID.uuidString.lowercased().utf8))
        info.append(0)
        debugKeyAppendBigEndian(UInt16(buildBytes.count), to: &info)
        info.append(buildBytes)

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token.data),
            salt: serverChallenge,
            info: info,
            outputByteCount: derivedKeyByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

private func debugKeyAppendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}
