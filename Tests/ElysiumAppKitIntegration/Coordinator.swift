import AppKit
import CryptoKit
import Darwin
import os
import Security

private enum CoordinatorFailure: Error { case invalid(String) }

private func sha256(_ url: URL) throws -> String {
    Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
        .map { String(format: "%02x", $0) }.joined()
}
private func hex(_ value: String) -> Data? {
    guard value.count == 64 else { return nil }
    var result = Data(); var index = value.startIndex
    for _ in 0..<32 {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
        result.append(byte); index = next
    }
    return result
}
private func processStart(_ pid: pid_t) -> (UInt64, UInt64)? {
    var info = proc_bsdinfo(); let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
}
private func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}
private func validLiveCode(_ pid: pid_t, executable: String) -> Bool {
    var live: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &live) == errSecSuccess,
          let live, SecCodeCheckValidity(live, [], nil) == errSecSuccess else { return false }
    var liveStatic: SecStaticCode?, expectedStatic: SecStaticCode?
    guard SecCodeCopyStaticCode(live, [], &liveStatic) == errSecSuccess, let liveStatic,
          SecStaticCodeCreateWithPath(URL(fileURLWithPath: executable) as CFURL, [],
                                      &expectedStatic) == errSecSuccess, let expectedStatic,
          SecStaticCodeCheckValidity(expectedStatic, [], nil) == errSecSuccess else { return false }
    func identity(_ code: SecStaticCode) -> (Data, String)? {
        var info: CFDictionary?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let cdHash = dictionary[kSecCodeInfoUnique as String] as? Data,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement, SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { return nil }
        return (cdHash, text as String)
    }
    guard let left = identity(liveStatic), let right = identity(expectedStatic) else { return false }
    return left.0 == right.0 && left.1 == right.1
}
private func setCloseOnExec(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFD)
    return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 &&
        fcntl(fd, F_GETFD) & FD_CLOEXEC != 0
}
private func connectSocket(_ path: String) throws -> Int32 {
    guard !path.utf8.contains(0), path.utf8.count < 104 else { throw CoordinatorFailure.invalid("path") }
    var socketIdentity = stat()
    guard lstat(path, &socketIdentity) == 0, (socketIdentity.st_mode & S_IFMT) == S_IFSOCK,
          socketIdentity.st_uid == geteuid(),
          socketIdentity.st_mode & 0o777 == 0o600 else { throw CoordinatorFailure.invalid("socket identity") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, setCloseOnExec(fd) else { if fd >= 0 { close(fd) }; throw CoordinatorFailure.invalid("socket") }
    var one: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                     socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
        close(fd); throw CoordinatorFailure.invalid("socket option")
    }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        path.withCString { source in strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }}
    var connectedIdentity = stat()
    guard status == 0, lstat(path, &connectedIdentity) == 0,
          connectedIdentity.st_dev == socketIdentity.st_dev,
          connectedIdentity.st_ino == socketIdentity.st_ino else {
        close(fd); throw CoordinatorFailure.invalid("connect")
    }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                     socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                     socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
        close(fd); throw CoordinatorFailure.invalid("deadline")
    }
    return fd
}

let args = CommandLine.arguments
guard args.count == 8, args[1] == "1", let nonce = hex(args[3]), let rawPID = pid_t(args[4]),
      rawPID > 0, args[5].count == 64, args[7].count == 64 else { exit(64) }
let socketPath = args[2]
let targetBundle = URL(fileURLWithPath: args[6]).resolvingSymlinksInPath().standardizedFileURL
guard targetBundle.path == args[6],
      let targetExecutable = Bundle(url: targetBundle)?.executableURL?.resolvingSymlinksInPath(),
      (try? sha256(targetExecutable)) == args[7] else { exit(65) }

do {
    let app = NSApplication.shared
    if app.activationPolicy() != .regular {
        guard app.setActivationPolicy(.regular) else { throw CoordinatorFailure.invalid("policy") }
    }
    app.finishLaunching()
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 360, height: 96),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Elysium Verification Coordinator"
    window.contentView = NSTextField(labelWithString: "Preparing Elysium verification")
    window.makeKeyAndOrderFront(nil); app.activate()
    let fd = try connectSocket(socketPath); defer { close(fd) }
    guard let credentials = try? coordinatorPeerCredentials(fd), credentials.pid == rawPID,
          let rawStart = processStart(rawPID), let rawPath = processPath(rawPID),
          (try? sha256(URL(fileURLWithPath: rawPath))) == args[5], validLiveCode(rawPID, executable: rawPath) else {
        throw CoordinatorFailure.invalid("peer")
    }
    var wire = CoordinatorWire(key: SymmetricKey(data: nonce))
    try wire.send(fd, type: 1, payload: Data("pid=\(getpid())".utf8))
    let challenge = try wire.receive(fd, type: 2); guard challenge.count == 32 else { throw CoordinatorFailure.invalid("challenge") }
    let deadline = Date(timeIntervalSinceNow: 5)
    while (!app.isActive || !window.isKeyWindow) && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    guard app.isActive, window.isKeyWindow else { throw CoordinatorFailure.invalid("foreground") }
    try wire.send(fd, type: 3, payload: Data(SHA256.hash(data: challenge)))
    let launch = try wire.receive(fd, type: 4)
    guard launch == Data(SHA256.hash(data: Data((targetBundle.path + args[7]).utf8))) else {
        throw CoordinatorFailure.invalid("launch authority")
    }
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
    configuration.createsNewApplicationInstance = false
    configuration.allowsRunningApplicationSubstitution = false
    let state = DispatchSemaphore(value: 0); var launched: NSRunningApplication?; var launchError: Error?
    NSWorkspace.shared.openApplication(at: targetBundle, configuration: configuration) {
        launched = $0; launchError = $1; state.signal()
    }
    let targetDeadline = ProcessInfo.processInfo.systemUptime + 15
    while state.wait(timeout: .now()) != .success && ProcessInfo.processInfo.systemUptime < targetDeadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    guard state.wait(timeout: .now()) == .success || launched != nil || launchError != nil else {
        throw CoordinatorFailure.invalid("target deadline")
    }
    guard let currentRawStart = processStart(rawPID), currentRawStart.0 == rawStart.0,
          currentRawStart.1 == rawStart.1, processPath(rawPID) == rawPath,
          (try? coordinatorPeerCredentials(fd).pid) == rawPID,
          validLiveCode(rawPID, executable: rawPath) else {
        throw CoordinatorFailure.invalid("peer drift")
    }
    guard launchError == nil, let launched, launched.processIdentifier > 0 else { throw CoordinatorFailure.invalid("target") }
    try wire.send(fd, type: 5, payload: Data("pid=\(launched.processIdentifier)".utf8))
    var actionDeadline = timeval(tv_sec: 60, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &actionDeadline,
                     socklen_t(MemoryLayout.size(ofValue: actionDeadline))) == 0 else {
        throw CoordinatorFailure.invalid("action-deadline")
    }
    _ = try wire.receive(fd, type: 6, deadline: .seconds(60))
    try wire.send(fd, type: 7, payload: Data("bye".utf8))
    window.orderOut(nil); window.close(); exit(0)
} catch CoordinatorFailure.invalid(let stage) {
    os_log("Elysium integration Coordinator failed at %{public}s", type: .error, stage)
    exit(70)
} catch {
    NSLog("Elysium integration Coordinator failed unexpectedly")
    exit(71)
}
