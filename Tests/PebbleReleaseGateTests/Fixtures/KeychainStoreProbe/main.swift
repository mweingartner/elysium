import Foundation
import PebbleReleaseGate

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 3 else { throw ReleaseGateError.malformed }
    let identity = try KeychainReceiptIdentity.isolatedTest(service: args[0], account: args[1])
    let store = KeychainReceiptStateStore(isolatedTestIdentity: identity)
    switch args[2] {
    case "add":
        guard args.count == 4, let data = Data(base64Encoded: args[3]) else {
            throw ReleaseGateError.malformed
        }
        try store.add(ReleaseGateCodec.decode(data)); print("added")
    case "load":
        let value = try store.load()
        print("sequence=\(value.sequence) state=\(value.state.rawValue)")
    case "update":
        guard args.count == 5, let expected = UInt64(args[3]),
              let state = ReleaseGateState(rawValue: args[4]) else {
            throw ReleaseGateError.malformed
        }
        var value = try store.load(); value.sequence = expected + 1; value.state = state
        try store.checkedUpdate(expectedSequence: expected, value: value); print("updated")
    case "accessibility": print(try store.accessibilityClass())
    case "delete": try store.delete(); print("deleted")
    case "absent":
        do { _ = try store.load(); throw ReleaseGateError.duplicate }
        catch ReleaseGateError.absent { print("absent") }
    default: throw ReleaseGateError.malformed
    }
} catch {
    FileHandle.standardError.write(Data("keychain probe failed: \(error)\n".utf8))
    exit(1)
}
