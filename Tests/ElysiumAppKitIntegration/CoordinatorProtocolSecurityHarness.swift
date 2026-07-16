import CryptoKit
import Darwin
import Foundation

private struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
private func rejected(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
}

let key = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
var encoder = CoordinatorWire(key: key)
let valid = try encoder.encoded(type: 1, payload: Data("pid=42".utf8))
var decoder = CoordinatorWire(key: key)
guard try decoder.decode(valid, type: 1) == Data("pid=42".utf8) else { exit(1) }
guard rejected({ var wire = CoordinatorWire(key: key); wire.receiveSequence = 2
                 _ = try wire.decode(valid, type: 1) }),
      rejected({ var wire = CoordinatorWire(key: key); _ = try wire.decode(valid, type: 2) }),
      rejected({ var wire = CoordinatorWire(key: key); _ = try wire.decode(valid.dropLast(), type: 1) })
else { exit(2) }

private var generator = Generator(state: 0x454C595349554D01)
for _ in 0..<10_000 {
    var candidate = valid
    let index = Int(generator.next() % UInt64(candidate.count))
    candidate[index] ^= UInt8(truncatingIfNeeded: generator.next()) | 1
    guard rejected({ var wire = CoordinatorWire(key: key)
                     _ = try wire.decode(candidate, type: 1) }) else { exit(3) }
}
for delivered in 0..<valid.count {
    guard rejected({ var wire = CoordinatorWire(key: key)
                     _ = try wire.decode(valid.prefix(delivered), type: 1) }) else { exit(4) }
}

// Execute the production read/write loop over a real socketpair, including a
// one-byte slowloris whose incremental progress must not refresh the deadline.
var pair: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { exit(5) }
defer { close(pair[0]); close(pair[1]) }
var sender = CoordinatorWire(key: key), receiver = CoordinatorWire(key: key)
let writer = Thread {
    try? sender.send(pair[0], type: 1, payload: Data("production".utf8),
                     deadline: .seconds(1))
}
writer.start()
guard try receiver.receive(pair[1], type: 1, deadline: .seconds(1)) == Data("production".utf8)
else { exit(6) }
writer.cancel()

var slowPair: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &slowPair) == 0 else { exit(7) }
defer { close(slowPair[0]); close(slowPair[1]) }
let slow = Thread {
    for byte in valid.prefix(8) {
        _ = withUnsafeBytes(of: byte) { Darwin.write(slowPair[0], $0.baseAddress, 1) }
        usleep(40_000)
    }
}
slow.start()
let started = ProcessInfo.processInfo.systemUptime
guard rejected({ var wire = CoordinatorWire(key: key)
                 _ = try wire.receive(slowPair[1], type: 1, deadline: .seconds(0.10)) }),
      ProcessInfo.processInfo.systemUptime - started < 0.30 else { exit(8) }

// Execute exact kernel credential and descriptor-relative namespace primitives.
let credentials = try coordinatorPeerCredentials(pair[0])
guard credentials.uid == geteuid(), credentials.gid == getegid(), credentials.pid == getpid() else { exit(9) }
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
guard mkdir(root.path, 0o700) == 0 else { exit(10) }
let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
guard directoryFD >= 0 else { exit(11) }
guard try coordinatorDirectoryEntries(directoryFD).isEmpty else { exit(12) }
guard close(directoryFD) == 0, rmdir(root.path) == 0, access(root.path, F_OK) != 0 else { exit(13) }

print("Coordinator protocol security harness: PASS seed=0x454c595349554d01 mutations=10000 prefixes=\(valid.count) production_io=2 identity=1 cleanup=1")
