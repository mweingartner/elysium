import CryptoKit
import Darwin
import Foundation

enum CoordinatorProtocolError: Error { case invalid(String) }

struct CoordinatorDeadline {
    let uptime: TimeInterval
    static func seconds(_ seconds: TimeInterval) -> Self {
        Self(uptime: ProcessInfo.processInfo.systemUptime + seconds)
    }
    var remainingMilliseconds: Int32 {
        let remaining = uptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return 0 }
        return Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up))
    }
}

func coordinatorAppendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

func coordinatorTakeBE<T: FixedWidthInteger>(_ data: Data, _ cursor: inout Int) -> T {
    let size = MemoryLayout<T>.size
    defer { cursor += size }
    return data[cursor..<(cursor + size)].reduce(T.zero) { ($0 << 8) | T($1) }
}

func coordinatorConstantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

private func coordinatorWait(_ fd: Int32, events: Int16, deadline: CoordinatorDeadline) throws {
    while true {
        let milliseconds = deadline.remainingMilliseconds
        guard milliseconds > 0 else { throw CoordinatorProtocolError.invalid("absolute deadline") }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = Darwin.poll(&descriptor, 1, milliseconds)
        if result < 0 && errno == EINTR { continue }
        guard result > 0, descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0,
              descriptor.revents & events != 0 else {
            throw CoordinatorProtocolError.invalid("descriptor unavailable")
        }
        return
    }
}

func coordinatorReadExact(_ fd: Int32, _ count: Int, deadline: CoordinatorDeadline) throws -> Data {
    var result = Data(); result.reserveCapacity(count)
    while result.count < count {
        try coordinatorWait(fd, events: Int16(POLLIN), deadline: deadline)
        var bytes = [UInt8](repeating: 0, count: count - result.count)
        let value = Darwin.read(fd, &bytes, bytes.count)
        if value < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
        guard value > 0 else { throw CoordinatorProtocolError.invalid("eof") }
        result.append(contentsOf: bytes.prefix(value))
    }
    return result
}

func coordinatorWriteAll(_ fd: Int32, _ data: Data, deadline: CoordinatorDeadline) throws {
    var offset = 0
    while offset < data.count {
        try coordinatorWait(fd, events: Int16(POLLOUT), deadline: deadline)
        let value = data.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if value < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
        guard value > 0 else { throw CoordinatorProtocolError.invalid("write") }
        offset += value
    }
}

struct CoordinatorWire {
    static let magic: UInt32 = 0x454C5943
    static let version: UInt16 = 1
    static let maximumPayload: UInt32 = 4096
    let key: SymmetricKey
    var transcript = Data()
    var receiveSequence: UInt32 = 1
    var sendSequence: UInt32 = 1

    mutating func encoded(type: UInt16, payload: Data) throws -> Data {
        guard payload.count <= Int(Self.maximumPayload) else {
            throw CoordinatorProtocolError.invalid("payload")
        }
        var complete = Data()
        coordinatorAppendBE(Self.magic, to: &complete)
        coordinatorAppendBE(Self.version, to: &complete)
        coordinatorAppendBE(type, to: &complete)
        coordinatorAppendBE(sendSequence, to: &complete)
        coordinatorAppendBE(UInt32(payload.count), to: &complete)
        complete.append(payload)
        let tag = HMAC<SHA256>.authenticationCode(for: complete + transcript, using: key)
        complete.append(contentsOf: tag)
        return complete
    }

    mutating func send(_ fd: Int32, type: UInt16, payload: Data,
                       deadline: CoordinatorDeadline = .seconds(5)) throws {
        let complete = try encoded(type: type, payload: payload)
        try coordinatorWriteAll(fd, complete, deadline: deadline)
        transcript = Data(SHA256.hash(data: transcript + complete)); sendSequence &+= 1
    }

    mutating func decode(_ complete: Data, type: UInt16) throws -> Data {
        guard complete.count >= 48 else { throw CoordinatorProtocolError.invalid("short frame") }
        let fixed = complete.prefix(16); var cursor = 0
        let magic: UInt32 = coordinatorTakeBE(Data(fixed), &cursor)
        let version: UInt16 = coordinatorTakeBE(Data(fixed), &cursor)
        let observed: UInt16 = coordinatorTakeBE(Data(fixed), &cursor)
        let sequence: UInt32 = coordinatorTakeBE(Data(fixed), &cursor)
        let length: UInt32 = coordinatorTakeBE(Data(fixed), &cursor)
        guard magic == Self.magic, version == Self.version, observed == type,
              sequence == receiveSequence, length <= Self.maximumPayload,
              complete.count == 16 + Int(length) + 32 else {
            throw CoordinatorProtocolError.invalid("frame")
        }
        let payload = Data(complete[16..<(16 + Int(length))])
        let tag = Data(complete.suffix(32))
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: Data(fixed) + payload + transcript, using: key))
        guard coordinatorConstantTimeEqual(tag, expected) else {
            throw CoordinatorProtocolError.invalid("mac")
        }
        transcript = Data(SHA256.hash(data: transcript + complete)); receiveSequence &+= 1
        return payload
    }

    mutating func receive(_ fd: Int32, type: UInt16,
                          deadline: CoordinatorDeadline = .seconds(5)) throws -> Data {
        let fixed = try coordinatorReadExact(fd, 16, deadline: deadline)
        var cursor = 12
        let length: UInt32 = coordinatorTakeBE(fixed, &cursor)
        guard length <= Self.maximumPayload else { throw CoordinatorProtocolError.invalid("length") }
        let tail = try coordinatorReadExact(fd, Int(length) + 32, deadline: deadline)
        return try decode(fixed + tail, type: type)
    }
}

struct CoordinatorPeerCredentials: Equatable {
    let uid: uid_t; let gid: gid_t; let pid: pid_t
}

func coordinatorPeerCredentials(_ fd: Int32) throws -> CoordinatorPeerCredentials {
    var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
    var size = socklen_t(MemoryLayout.size(ofValue: pid))
    guard getpeereid(fd, &uid, &gid) == 0,
          getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
          size == MemoryLayout.size(ofValue: pid), uid == geteuid(), gid == getegid(), pid > 0 else {
        throw CoordinatorProtocolError.invalid("peer credentials")
    }
    return CoordinatorPeerCredentials(uid: uid, gid: gid, pid: pid)
}

func coordinatorDirectoryEntries(_ directoryFD: Int32) throws -> [String] {
    let copy = dup(directoryFD)
    guard copy >= 0, let directory = fdopendir(copy) else {
        if copy >= 0 { close(copy) }
        throw CoordinatorProtocolError.invalid("directory enumeration")
    }
    rewinddir(directory)
    defer { rewinddir(directory); closedir(directory) }
    var result: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { result.append(name) }
    }
    guard errno == 0 else { throw CoordinatorProtocolError.invalid("directory enumeration") }
    return result.sorted()
}
