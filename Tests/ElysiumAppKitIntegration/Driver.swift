import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Security
import SystemConfiguration

private enum GateError: Error { case failed(String) }
private func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }; return String(cString: resolved)
}
private func canonicalURL(_ path: String) -> URL {
    URL(fileURLWithPath: canonicalPath(path)).standardizedFileURL
}
private func fail(_ stage: String) -> Never {
    FileHandle.standardError.write(Data("AppKit gate failed: \(stage)\n".utf8))
    exit(1)
}
private func hash(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func stringHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
private func secureRandom32() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw GateError.failed("coordinator random")
    }
    return Data(bytes)
}
private func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

private func setCloseOnExec(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFD)
    guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0,
          fcntl(fd, F_GETFD) & FD_CLOEXEC != 0 else {
        throw GateError.failed("Coordinator descriptor CLOEXEC")
    }
}

private final class CoordinatorSession {
    let directory: URL, socketURL: URL, nonce: Data
    private let directoryFD: Int32
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let directoryGroup: gid_t
    var listener: Int32
    var connection: Int32 = -1; var application: NSRunningApplication?; var wire: CoordinatorWire
    init(root: URL) throws {
        nonce = try secureRandom32(); wire = CoordinatorWire(key: SymmetricKey(data: nonce))
        directory = root.appendingPathComponent("coordinator-ipc-" + hexString(Data(SHA256.hash(data: nonce))).prefix(16))
        let priorMask = umask(0o077); defer { umask(priorMask) }
        guard mkdir(directory.path, 0o700) == 0 else { throw GateError.failed("coordinator directory") }
        directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw GateError.failed("coordinator directory authority") }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0, (directoryStat.st_mode & S_IFMT) == S_IFDIR,
              directoryStat.st_uid == geteuid(),
              directoryStat.st_mode & 0o777 == 0o700, directoryStat.st_nlink == 2 else {
            close(directoryFD); throw GateError.failed(
                "coordinator directory identity mode=\(directoryStat.st_mode & 0o777) " +
                "uid=\(directoryStat.st_uid)/\(geteuid()) gid=\(directoryStat.st_gid) " +
                "links=\(directoryStat.st_nlink)")
        }
        directoryDevice = directoryStat.st_dev; directoryInode = directoryStat.st_ino
        directoryGroup = directoryStat.st_gid
        socketURL = directory.appendingPathComponent("control.sock")
        guard socketURL.path.utf8.count < 104 else { throw GateError.failed("coordinator socket path") }
        listener = socket(AF_UNIX, SOCK_STREAM, 0); guard listener >= 0 else { throw GateError.failed("coordinator socket") }
        try setCloseOnExec(listener)
        var one: Int32 = 1
        guard setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &one,
                         socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            throw GateError.failed("coordinator socket option")
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in socketURL.path.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
        }}
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }}
        var socketStat = stat()
        guard bound == 0, fchmodat(directoryFD, "control.sock", 0o600, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(directoryFD, "control.sock", &socketStat, AT_SYMLINK_NOFOLLOW) == 0,
              (socketStat.st_mode & S_IFMT) == S_IFSOCK, socketStat.st_uid == geteuid(),
              socketStat.st_gid == directoryGroup, socketStat.st_mode & 0o777 == 0o600,
              listen(listener, 1) == 0 else {
            throw GateError.failed("coordinator bind")
        }
    }
    deinit { if connection >= 0 { close(connection) }; if listener >= 0 { close(listener) }; close(directoryFD) }
    func validateNamespace(expectSocket: Bool) throws {
        var current = stat(), socketStat = stat()
        guard fstat(directoryFD, &current) == 0, current.st_dev == directoryDevice,
              current.st_ino == directoryInode, current.st_uid == geteuid(),
              current.st_mode & 0o777 == 0o700 else { throw GateError.failed("Coordinator namespace replaced") }
        var ambient = stat()
        guard lstat(directory.path, &ambient) == 0, (ambient.st_mode & S_IFMT) == S_IFDIR,
              ambient.st_dev == directoryDevice, ambient.st_ino == directoryInode else {
            throw GateError.failed("Coordinator ambient namespace replaced")
        }
        let names = try coordinatorDirectoryEntries(directoryFD)
        guard names == (expectSocket ? ["control.sock"] : []) else { throw GateError.failed("Coordinator namespace entries") }
        if expectSocket {
            guard fstatat(directoryFD, "control.sock", &socketStat, AT_SYMLINK_NOFOLLOW) == 0,
                  (socketStat.st_mode & S_IFMT) == S_IFSOCK, socketStat.st_uid == geteuid(),
                  socketStat.st_gid == directoryGroup, socketStat.st_mode & 0o777 == 0o600 else {
                throw GateError.failed("Coordinator socket replaced")
            }
        }
    }
    func cleanup() throws {
        var first: String?
        if connection >= 0 { if close(connection) != 0 { first = "connection close" }; connection = -1 }
        if listener >= 0 { if close(listener) != 0, first == nil { first = "listener close" }; listener = -1 }
        do { try validateNamespace(expectSocket: true) } catch { first = first ?? "namespace before unlink" }
        if first == nil && unlinkat(directoryFD, "control.sock", 0) != 0 { first = "socket unlink" }
        if first == nil && fsync(directoryFD) != 0 { first = "directory fsync" }
        do { try validateNamespace(expectSocket: false) } catch { first = first ?? "namespace after unlink" }
        var ambient = stat()
        if first == nil && (lstat(directory.path, &ambient) != 0 || ambient.st_dev != directoryDevice ||
                            ambient.st_ino != directoryInode) { first = "ambient identity before rmdir" }
        if first == nil && rmdir(directory.path) != 0 { first = "directory removal" }
        if first == nil && lstat(directory.path, &ambient) == 0 { first = "directory remains" }
        if let first { throw GateError.failed("Coordinator cleanup: \(first)") }
    }
}
private func runningCommand(_ pid: pid_t) -> String? {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(pid)", "-o", "command="]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return command?.split(separator: " ").first.map(String.init)
}
private struct ProcessStartIdentity: Equatable {
    let seconds: UInt64
    let microseconds: UInt64

    static func capture(_ pid: pid_t) -> ProcessStartIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return ProcessStartIdentity(
            seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec))
    }
}
private struct LiveCodeIdentity: Equatable {
    let cdHash: Data
    let requirement: String
}
private func liveCodeIdentity(_ pid: pid_t) -> LiveCodeIdentity? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &information) == errSecSuccess,
          let dictionary = information as? [String: Any],
          let cdHash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
    var requirement: SecRequirement?, text: CFString?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
          let requirement,
          SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
    return LiveCodeIdentity(cdHash: cdHash, requirement: text as String)
}
private func staticCodeIdentity(_ url: URL) -> LiveCodeIdentity? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
          let staticCode, SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &information) == errSecSuccess,
          let dictionary = information as? [String: Any],
          let cdHash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
    var requirement: SecRequirement?, text: CFString?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
          let requirement, SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
          let text else { return nil }
    return LiveCodeIdentity(cdHash: cdHash, requirement: text as String)
}

private final class CoordinatorForegroundLedger {
    private let center = NSWorkspace.shared.notificationCenter
    private let predecessor: NSRunningApplication
    private var coordinator: NSRunningApplication?
    private var provisionalActivation: NSRunningApplication?
    private var tokens: [NSObjectProtocol] = []
    private var predecessorDeactivated = 0
    private var coordinatorActivated = 0
    private var invalid = false
    init?() {
        guard let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier != getpid() else { return nil }
        predecessor = current
    }
    func install() {
        for (name, activation) in [(NSWorkspace.didDeactivateApplicationNotification, false),
                                   (NSWorkspace.didActivateApplicationNotification, true)] {
            tokens.append(center.addObserver(forName: name, object: NSWorkspace.shared, queue: .main) {
                [weak self] note in self?.record(note, activation: activation)
            })
        }
    }
    func bind(_ application: NSRunningApplication) {
        coordinator = application
        if let provisionalActivation {
            if provisionalActivation.processIdentifier == application.processIdentifier {
                coordinatorActivated = 1
            } else { invalid = true }
            self.provisionalActivation = nil
        }
    }
    private func record(_ notification: Notification, activation: Bool) {
        guard !invalid,
              let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { invalid = true; return }
        if !activation, application.processIdentifier == predecessor.processIdentifier {
            predecessorDeactivated += 1
        } else if activation, let coordinator,
                  application.processIdentifier == coordinator.processIdentifier {
            coordinatorActivated += 1
        } else if activation, coordinator == nil, provisionalActivation == nil {
            provisionalActivation = application
        } else { invalid = true }
        if predecessorDeactivated > 1 || coordinatorActivated > 1 { invalid = true }
    }
    func ready(_ application: NSRunningApplication) -> Bool {
        coordinator?.processIdentifier == application.processIdentifier && !invalid &&
        predecessorDeactivated == 1 && coordinatorActivated == 1 &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier &&
        application.isActive
    }
    func close() { tokens.forEach(center.removeObserver); tokens.removeAll() }
    deinit { close() }
}
private func pumpAppKitEvent(until date: Date) {
    if let event = NSApp.nextEvent(
        matching: .any, until: date, inMode: .default, dequeue: true
    ) {
        NSApp.sendEvent(event)
    } else {
        RunLoop.current.run(until: date)
    }
}
private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if condition() { return true }
        pumpAppKitEvent(until: Date(timeIntervalSinceNow: 0.05))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}
private func axValue(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
}
private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    axValue(element, attribute) as? String
}
private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    axValue(element, attribute) as? Bool
}
private func axElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(raw, to: AXUIElement.self)
}
private func axRange(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var range = CFRange(location: 0, length: 0)
    return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
}
private func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
}
private func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    guard let raw = axValue(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
}
private func axFullScreen(_ element: AXUIElement) -> Bool? {
    guard let raw = axValue(element, "AXFullScreen" as CFString),
          CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue(unsafeBitCast(raw, to: CFBoolean.self))
}
private enum DisplayQueryState: String {
    case failure, zero, values, capacityExceeded, configurationChanged, truncated
}

private struct BoundedDisplayList {
    let state: DisplayQueryState
    let displays: [CGDirectDisplayID]
    let count: Int

    var querySuccess: Bool { state == .zero || state == .values }
}

private typealias DisplayListQuery = (
    UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?
) -> CGError

private func boundedDisplayList(_ query: DisplayListQuery) -> BoundedDisplayList {
    let capacity: UInt32 = 32
    var firstCount: UInt32 = 0
    guard query(0, nil, &firstCount) == .success else {
        return BoundedDisplayList(state: .failure, displays: [], count: -1)
    }
    guard firstCount > 0 else {
        return BoundedDisplayList(state: .zero, displays: [], count: 0)
    }
    guard firstCount <= capacity else {
        return BoundedDisplayList(
            state: .capacityExceeded, displays: [], count: Int(capacity) + 1)
    }
    var displays = Array(repeating: CGDirectDisplayID(), count: Int(firstCount))
    var secondCount = firstCount
    guard query(firstCount, &displays, &secondCount) == .success else {
        return BoundedDisplayList(state: .failure, displays: [], count: -1)
    }
    guard secondCount <= firstCount else {
        return BoundedDisplayList(
            state: .truncated, displays: [], count: Int(capacity) + 1)
    }
    guard secondCount == firstCount else {
        return BoundedDisplayList(
            state: .configurationChanged, displays: [], count: min(Int(secondCount), 33))
    }
    let exact = Array(displays.prefix(Int(secondCount))).sorted()
    guard Set(exact).count == exact.count else {
        return BoundedDisplayList(
            state: .configurationChanged, displays: [], count: exact.count)
    }
    return BoundedDisplayList(state: .values, displays: exact, count: exact.count)
}

private func activeDisplayObservation() -> BoundedDisplayList {
    boundedDisplayList { CGGetActiveDisplayList($0, $1, $2) }
}

private func onlineDisplayObservation() -> BoundedDisplayList {
    boundedDisplayList { CGGetOnlineDisplayList($0, $1, $2) }
}

private struct DisplayAuthoritySnapshot {
    let active: BoundedDisplayList
    let online: BoundedDisplayList
    let activeAwake: [Bool]
    let screenMappingCounts: [Int]
    let screenFrames: [CGRect?]

    static func capture() -> DisplayAuthoritySnapshot {
        let active = activeDisplayObservation()
        let online = onlineDisplayObservation()
        let awake = active.displays.map {
            CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
        }
        let mappings = active.displays.map { display -> (Int, CGRect?) in
            let matches = NSScreen.screens.filter {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == display
            }
            return (min(matches.count, 33), matches.count == 1 ? matches[0].frame : nil)
        }
        return DisplayAuthoritySnapshot(
            active: active, online: online, activeAwake: awake,
            screenMappingCounts: mappings.map(\.0), screenFrames: mappings.map(\.1))
    }

    var eligible: Bool {
        active.state == .values && !active.displays.isEmpty &&
            activeAwake.count == active.displays.count && activeAwake.allSatisfy { $0 } &&
            screenMappingCounts.count == active.displays.count &&
            screenMappingCounts.allSatisfy { $0 == 1 } &&
            screenFrames.count == active.displays.count && screenFrames.allSatisfy { $0 != nil }
    }

    func exactlyMatches(_ baseline: DisplayAuthoritySnapshot) -> Bool {
        eligible && baseline.eligible && active.displays == baseline.active.displays &&
            activeAwake == baseline.activeAwake &&
            screenMappingCounts == baseline.screenMappingCounts && screenFrames == baseline.screenFrames
    }

    var redactedAggregate: String {
        let activeCount = active.count < 0 ? "unknown" : String(min(active.count, 33))
        let onlineCount = online.count < 0 ? "unknown" : String(min(online.count, 33))
        let awake = activeAwake.isEmpty ? "unknown" : String(activeAwake.allSatisfy { $0 })
        let mappingCount = screenMappingCounts.isEmpty ? "unknown" :
            String(min(screenMappingCounts.reduce(0, +), 33))
        return "active_display_query_state=\(active.state.rawValue) " +
            "active_display_query_success=\(active.querySuccess) " +
            "active_display_count=\(activeCount) " +
            "online_display_query_state=\(online.state.rawValue) " +
            "online_display_query_success=\(online.querySuccess) " +
            "online_display_count=\(onlineCount) containing_display_awake=\(awake) " +
            "nsscreen_mapping_count=\(mappingCount)"
    }
}

private struct CGOwnerWindow {
    let id: CGWindowID
    let rectangle: CGRect
    let onScreen: Bool
    let alpha: Double
}

private struct BoundCGWindowObservation {
    let presentExactlyOnce: Bool
    let pidExact: Bool
    let windowIDExact: Bool
    let layerExact: Bool
    let titleExact: Bool
    let rectangleExact: Bool
    let onScreen: Bool?
    let alpha: Double?

    var identityExact: Bool {
        presentExactlyOnce && pidExact && windowIDExact && layerExact && titleExact && rectangleExact
    }
}

private func boundCGOwnerWindow(
    pid: pid_t, windowID: CGWindowID, layer: Int, rectangle: CGRect,
    title: String? = nil
) -> BoundCGWindowObservation {
    let options: CGWindowListOption = [.excludeDesktopElements]
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
        return BoundCGWindowObservation(
            presentExactlyOnce: false, pidExact: false, windowIDExact: false,
            layerExact: false, titleExact: false, rectangleExact: false,
            onScreen: nil, alpha: nil)
    }
    let boundRows = rows.filter {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
    }
    guard boundRows.count == 1 else {
        return BoundCGWindowObservation(
            presentExactlyOnce: false, pidExact: false, windowIDExact: false,
            layerExact: false, titleExact: false, rectangleExact: false,
            onScreen: nil, alpha: nil)
    }
    let row = boundRows[0]
    let candidatePID = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    let candidateID = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    let candidateLayer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue
    let candidateTitle = row[kCGWindowName as String] as? String
    let candidateRectangle = (row[kCGWindowBounds as String]).flatMap {
        CGRect(dictionaryRepresentation: $0 as! CFDictionary)
    }
    return BoundCGWindowObservation(
        presentExactlyOnce: true,
        pidExact: candidatePID == pid,
        windowIDExact: candidateID == windowID,
        layerExact: candidateLayer == layer,
        titleExact: title == nil || candidateTitle == title,
        rectangleExact: candidateRectangle == rectangle,
        onScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
        alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue)
}

private func matchingCGOwnerWindows(pid: pid_t, rectangle: CGRect) -> [CGOwnerWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return rows.compactMap { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let boundsValue = row[kCGWindowBounds as String],
              let cgRectangle = CGRect(
                dictionaryRepresentation: boundsValue as! CFDictionary),
              cgRectangle == rectangle,
              let number = row[kCGWindowNumber as String] as? NSNumber else { return nil }
        let onScreen = (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
        let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
        return CGOwnerWindow(
            id: CGWindowID(number.uint32Value), rectangle: cgRectangle,
            onScreen: onScreen, alpha: alpha)
    }
}

private func visibleCGOwnerWindows(pid: pid_t) -> [CGOwnerWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return rows.compactMap { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let boundsValue = row[kCGWindowBounds as String],
              let rectangle = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
              let number = row[kCGWindowNumber as String] as? NSNumber else { return nil }
        return CGOwnerWindow(
            id: CGWindowID(number.uint32Value), rectangle: rectangle,
            onScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
            alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1)
    }
}

private struct DenialTitlebarPoint: Equatable {
    let cgPoint: CGPoint
    let cgTitlebarBand: CGRect
    let displayID: CGDirectDisplayID
}

/// Converts the exact CG window/display tuple into AppKit screen coordinates, derives the standard
/// titled-window chrome, then round-trips the selected non-content point back to CG event space.
private func denialTitlebarPoint(
    window: CGRect, displayID: CGDirectDisplayID, screenFrame: CGRect
) -> DenialTitlebarPoint? {
    let display = CGDisplayBounds(displayID)
    guard [window.minX, window.minY, window.width, window.height,
           display.minX, display.minY, display.width, display.height,
           screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height]
        .allSatisfy(\.isFinite), window.width > 0, window.height > 0,
          display.contains(window), display != window else { return nil }
    let appKitFrame = CGRect(
        x: screenFrame.minX + window.minX - display.minX,
        y: screenFrame.maxY - (window.maxY - display.minY),
        width: window.width, height: window.height)
    let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    let content = NSWindow.contentRect(forFrameRect: appKitFrame, styleMask: style)
    let chromeHeight = appKitFrame.maxY - content.maxY
    let edgeExclusion: CGFloat = 96
    guard chromeHeight.isFinite, chromeHeight > 0, chromeHeight < appKitFrame.height,
          appKitFrame.width > edgeExclusion * 2,
          content.minX >= appKitFrame.minX, content.maxX <= appKitFrame.maxX,
          content.minY >= appKitFrame.minY, content.maxY <= appKitFrame.maxY else { return nil }
    let appKitBand = CGRect(
        x: appKitFrame.minX + edgeExclusion, y: content.maxY,
        width: appKitFrame.width - edgeExclusion * 2, height: chromeHeight)
    let appKitPoint = CGPoint(x: appKitBand.midX, y: appKitBand.midY)
    let cgPoint = CGPoint(
        x: display.minX + appKitPoint.x - screenFrame.minX,
        y: display.minY + screenFrame.maxY - appKitPoint.y)
    let cgBand = CGRect(
        x: window.minX + edgeExclusion, y: window.minY,
        width: window.width - edgeExclusion * 2, height: chromeHeight)
    let roundTrip = CGPoint(
        x: screenFrame.minX + cgPoint.x - display.minX,
        y: screenFrame.maxY - (cgPoint.y - display.minY))
    let tolerance: CGFloat = 0.5
    guard window.contains(cgPoint), display.contains(cgPoint), cgBand.contains(cgPoint),
          !content.contains(appKitPoint),
          abs(roundTrip.x - appKitPoint.x) <= tolerance,
          abs(roundTrip.y - appKitPoint.y) <= tolerance else { return nil }
    return DenialTitlebarPoint(cgPoint: cgPoint, cgTitlebarBand: cgBand, displayID: displayID)
}

private enum LaunchPresentationMode: String {
    case fullscreen
    case windowedFallback

    var opposite: LaunchPresentationMode {
        self == .fullscreen ? .windowedFallback : .fullscreen
    }
}

private struct LaunchPresentationBinding {
    let mode: LaunchPresentationMode
    let displayID: CGDirectDisplayID
    let axWindow: AXUIElement
    let cgWindowID: CGWindowID
    let rectangle: CGRect
}
private func children(_ element: AXUIElement) -> [AXUIElement] {
    axValue(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}
private struct BoundedAXDescendants {
    let elements: [AXUIElement]
    let truncated: Bool
}

private func boundedDescendants(_ root: AXUIElement, cap: Int) -> BoundedAXDescendants {
    guard cap > 0 else { return BoundedAXDescendants(elements: [], truncated: true) }
    var result: [AXUIElement] = [], queue = [root], index = 0
    while index < queue.count {
        let node = queue[index]; index += 1
        var rawChildren: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            node, kAXChildrenAttribute as CFString, &rawChildren)
        let childBatch: [AXUIElement]
        switch error {
        case .success:
            guard let children = rawChildren as? [AXUIElement] else {
                return BoundedAXDescendants(elements: result, truncated: true)
            }
            childBatch = children
        case .attributeUnsupported, .noValue:
            childBatch = []
        default:
            return BoundedAXDescendants(elements: result, truncated: true)
        }
        for child in childBatch {
            guard result.count < cap else {
                return BoundedAXDescendants(elements: result, truncated: true)
            }
            result.append(child)
            queue.append(child)
        }
    }
    return BoundedAXDescendants(elements: result, truncated: false)
}

private func descendants(_ root: AXUIElement, cap: Int = 512) -> [AXUIElement] {
    boundedDescendants(root, cap: cap).elements
}

private let expectedOneShotActionIDs = [
    "launch.application",
    "title.tab.forward.1", "title.tab.forward.2", "title.tab.forward.3",
    "title.tab.forward.4", "title.tab.forward.5", "title.activate.modified",
    "title.activate.repeat", "title.activate.credits", "title.credits.escape",
    "title.tab.reverse.1", "title.tab.reverse.2", "title.tab.reverse.3",
    "title.tab.reverse.4", "title.tab.reverse.5",
    "navigation.singleplayer.click", "navigation.create-world.click",
    "world-name.click", "world-name.key.a",
    "finder.activate", "elysium.reactivate", "world-name.reactivation-focus",
    "world-name.key.b", "world-name.key.c", "world-name.key.d",
    "world-name.key.left-1", "world-name.key.left-2", "world-name.key.backspace",
    "seed.focus", "seed.key.7", "world-name.focus",
    "world-name.key.right-1", "world-name.key.right-2", "world-name.key.right-saturated",
    "window.fullscreen.key.f11",
]

private final class OneShotActionLedger {
    private let expected: Set<String>
    private var performed: Set<String> = []

    init(expectedIDs: [String]) {
        expected = Set(expectedIDs)
    }

    func validateConfiguration(expectedCount: Int) throws {
        guard expected.count == expectedCount else {
            throw GateError.failed("one-shot action configuration")
        }
    }

    func perform(_ id: String, _ action: () throws -> Void) throws {
        guard expected.contains(id), performed.insert(id).inserted else {
            throw GateError.failed("duplicate or unknown action \(id)")
        }
        try action()
    }

    func validateComplete() throws {
        guard performed == expected else {
            throw GateError.failed("incomplete one-shot actions")
        }
    }

    var receiptCount: Int { expected.count }

    var receiptDigest: String {
        let bytes = expected.sorted().map { "\($0)=\(performed.contains($0) ? 1 : 0)" }
            .joined(separator: "\n") + "\n"
        return stringHash(bytes)
    }
}

private struct FieldExpectation {
    let nameValue: String
    let nameRange: Int
    let nameFocused: Bool
    let seedValue: String
    let seedRange: Int
    let seedFocused: Bool
}

private struct ActiveSurfaceObservation {
    let appNotTerminated: Bool
    let appPID: Bool
    let appBundle: Bool
    let appExecutable: Bool
    let appMeasuredBytes: Bool
    let active: Bool
    let frontmostPresent: Bool
    let frontmostValueEqual: Bool
    let frontmostPID: Bool
    let frontmostBundle: Bool
    let frontmostExecutable: Bool
    let windowCount: Bool
    let windowIdentity: Bool
    let focusedWindowIdentity: Bool
    let axFullScreenPresent: Bool
    let axFullScreenValue: Bool
    let presentationModeBound: Bool
    let containingDisplayCountExact: Bool
    let displayIdentity: Bool
    let cgWindowCountExact: Bool
    let cgWindowIdentity: Bool
    let cgWindowOnScreen: Bool
    let cgWindowOpaque: Bool
    let axCGRectangleEqual: Bool
    let geometryRetained: Bool
    let groupCount: Bool
    let groupIdentity: Bool
    let fieldCount: Bool
    let nameIdentity: Bool
    let seedIdentity: Bool
    let nameFocus: Bool
    let seedFocus: Bool

    var predicates: [(String, Bool)] { [
        ("app_not_terminated", appNotTerminated), ("app_pid", appPID),
        ("app_bundle", appBundle), ("app_executable", appExecutable),
        ("app_measured_bytes", appMeasuredBytes), ("active", active),
        ("frontmost_present", frontmostPresent),
        ("frontmost_value_equal", frontmostValueEqual),
        ("frontmost_pid", frontmostPID), ("frontmost_bundle", frontmostBundle),
        ("frontmost_executable", frontmostExecutable), ("window_count", windowCount),
        ("window_identity", windowIdentity),
        ("focused_window_identity", focusedWindowIdentity),
        ("ax_fullscreen_present", axFullScreenPresent),
        ("ax_fullscreen_value", axFullScreenValue),
        ("presentation_mode_bound", presentationModeBound),
        ("containing_display_count_exact", containingDisplayCountExact),
        ("display_identity", displayIdentity), ("cg_window_count_exact", cgWindowCountExact),
        ("cg_window_identity", cgWindowIdentity), ("cg_window_onscreen", cgWindowOnScreen),
        ("cg_window_opaque", cgWindowOpaque),
        ("ax_cg_rectangle_equal", axCGRectangleEqual),
        ("geometry_retained", geometryRetained),
        ("group_count", groupCount), ("group_identity", groupIdentity),
        ("field_count", fieldCount), ("name_identity", nameIdentity),
        ("seed_identity", seedIdentity), ("name_focus", nameFocus),
        ("seed_focus", seedFocus),
    ] }

    var exact: Bool {
        predicates.allSatisfy(\.1)
    }

    var aggregate: String {
        predicates.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}

private struct SettlingSample {
    let surface: ActiveSurfaceObservation
    let fieldStateExact: Bool
    let fieldAggregate: String
    var exact: Bool { surface.exact && fieldStateExact }
    var predicates: [(String, Bool)] { surface.predicates + [("field_state_exact", fieldStateExact)] }
}

private struct BoundRunningApplicationIdentity: Equatable {
    let pid: pid_t
    let bundle: URL
    let executable: URL
    let measuredSHA256: String
}

private struct RegularFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let fileType: mode_t
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

private struct BundleDirectoryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
    let fileType: mode_t
    let permissions: mode_t
}

private func exactBundleDirectoryIdentity(_ url: URL) -> BundleDirectoryIdentity? {
    var value = stat()
    guard lstat(url.path, &value) == 0,
          value.st_mode & S_IFMT == S_IFDIR,
          canonicalURL(url.path).path == url.path,
          value.st_uid == geteuid(),
          value.st_mode & 0o022 == 0 else { return nil }
    return BundleDirectoryIdentity(
        device: UInt64(value.st_dev), inode: UInt64(value.st_ino), owner: value.st_uid,
        fileType: value.st_mode & S_IFMT, permissions: value.st_mode & 0o7777)
}

private func regularFileIdentity(_ url: URL) -> RegularFileIdentity? {
    var value = stat()
    guard lstat(url.path, &value) == 0,
          value.st_mode & S_IFMT == S_IFREG else { return nil }
    return RegularFileIdentity(
        device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
        fileType: value.st_mode & S_IFMT, size: Int64(value.st_size),
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
}

private struct ImmutableLaunchAuthority {
    let application: NSRunningApplication
    let identity: BoundRunningApplicationIdentity
    let fileIdentity: RegularFileIdentity
    let executable: URL
    let bundleDirectoryIdentity: BundleDirectoryIdentity

    func exactWithoutRehash() -> Bool {
        !application.isTerminated && application.processIdentifier == identity.pid &&
            application.bundleURL.map({ canonicalURL($0.path) }) == identity.bundle &&
            application.executableURL.map({ canonicalURL($0.path) }) == identity.executable &&
            exactBundleDirectoryIdentity(identity.bundle) == bundleDirectoryIdentity &&
            regularFileIdentity(executable) == fileIdentity
    }

    func exactWithRehash() -> Bool {
        exactWithoutRehash() && (try? hash(executable)) == identity.measuredSHA256
    }
}

private struct StaticArtifactAuthority {
    let bundle: URL
    let bundleIdentifier: String
    let executable: URL
    let fileIdentity: RegularFileIdentity
    let measuredSHA256: String

    func exact() -> Bool {
        regularFileIdentity(executable) == fileIdentity &&
            (try? hash(executable)) == measuredSHA256
    }
}

private func targetAXInvalidationCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<TargetAXInvalidationLedger>.fromOpaque(refcon)
        .takeUnretainedValue().record(notification: notification)
}

private final class TargetAXInvalidationLedger {
    private enum Phase { case installing, observing, bound, failed, closed }
    private let lock = NSLock()
    private let ingressLock = NSLock()
    private var phase: Phase = .installing
    private var generation: UInt64 = 1
    private var ingressCount: UInt64 = 0
    private var sequence: UInt64 = 0
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var watchedWindow: AXUIElement?
    private var terminalReason: String?
    private var lastCategory = "none"
    private var invalidationCount = 0

    func install(pid: pid_t, application: AXUIElement) throws {
        var created: AXObserver?
        guard AXObserverCreate(pid, targetAXInvalidationCallback, &created) == .success,
              let created else { throw GateError.failed("launch AX observer create") }
        lock.lock()
        guard phase == .installing else { lock.unlock(); throw GateError.failed("launch AX observer phase") }
        observer = created
        self.application = application
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let createdResult = AXObserverAddNotification(
            created, application, kAXWindowCreatedNotification as CFString, refcon)
        let focusedResult = AXObserverAddNotification(
            created, application, kAXFocusedWindowChangedNotification as CFString, refcon)
        guard createdResult == .success, focusedResult == .success else {
            phase = .failed
            terminalReason = "application_notification_registration"
            lock.unlock()
            throw GateError.failed("launch AX observer registration")
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        phase = .observing
        lock.unlock()
    }

    func watch(window: AXUIElement) throws {
        lock.lock()
        guard phase == .observing, terminalReason == nil, let observer else {
            lock.unlock(); throw GateError.failed(diagnostics())
        }
        if watchedWindow.map({ CFEqual($0, window) }) == true { lock.unlock(); return }
        let prior = watchedWindow
        watchedWindow = window
        lock.unlock()
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let prior {
            for name in [kAXMovedNotification, kAXResizedNotification,
                         kAXUIElementDestroyedNotification] {
                _ = AXObserverRemoveNotification(observer, prior, name as CFString)
            }
        }
        for name in [kAXMovedNotification, kAXResizedNotification,
                     kAXUIElementDestroyedNotification] {
            guard AXObserverAddNotification(observer, window, name as CFString, refcon) == .success else {
                lock.lock(); terminalReason = "window_notification_registration"; phase = .failed
                let evidence = diagnosticsLocked(); lock.unlock()
                throw GateError.failed(evidence)
            }
        }
    }

    func beginSample() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard phase == .observing, terminalReason == nil else {
            throw GateError.failed(diagnosticsLocked())
        }
        return sequence
    }

    func finishSample(sequence baseline: UInt64) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .observing, terminalReason == nil else {
            throw GateError.failed(diagnosticsLocked())
        }
        return sequence == baseline && ingressSnapshot() == baseline
    }

    func markBound(sequence baseline: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .observing, terminalReason == nil, sequence == baseline,
              ingressSnapshot() == baseline else {
            phase = .failed
            if terminalReason == nil { terminalReason = "invalidation_during_bind" }
            throw GateError.failed(diagnosticsLocked())
        }
        phase = .bound
    }

    func requireBound() throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .bound, terminalReason == nil else {
            throw GateError.failed(diagnosticsLocked())
        }
    }

    fileprivate func record(notification: CFString) {
        ingressLock.lock()
        ingressCount &+= 1
        ingressLock.unlock()
        let category: String
        switch notification as String {
        case kAXWindowCreatedNotification: category = "window_created"
        case kAXFocusedWindowChangedNotification: category = "focused_window_changed"
        case kAXMovedNotification: category = "window_moved"
        case kAXResizedNotification: category = "window_resized"
        case kAXUIElementDestroyedNotification: category = "window_destroyed"
        default: category = "unknown"
        }
        lock.lock(); defer { lock.unlock() }
        guard phase != .closed else { return }
        sequence &+= 1
        invalidationCount += 1
        lastCategory = category
        if phase == .bound || category == "unknown" {
            terminalReason = phase == .bound ? "postbind_invalidation" : "unknown_notification"
            phase = .failed
        }
    }

    func close() {
        lock.lock()
        guard phase != .closed else { lock.unlock(); return }
        phase = .closed
        generation &+= 1
        let observer = self.observer
        let application = self.application
        let window = watchedWindow
        self.observer = nil
        self.application = nil
        watchedWindow = nil
        lock.unlock()
        if let observer {
            if let application {
                _ = AXObserverRemoveNotification(
                    observer, application, kAXWindowCreatedNotification as CFString)
                _ = AXObserverRemoveNotification(
                    observer, application, kAXFocusedWindowChangedNotification as CFString)
            }
            if let window {
                for name in [kAXMovedNotification, kAXResizedNotification,
                             kAXUIElementDestroyedNotification] {
                    _ = AXObserverRemoveNotification(observer, window, name as CFString)
                }
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private func diagnostics() -> String {
        lock.lock(); defer { lock.unlock() }; return diagnosticsLocked()
    }

    private func diagnosticsLocked() -> String {
        "launch_ax terminal_reason=\(terminalReason ?? "none") " +
            "generation=\(generation) invalidation_count=\(invalidationCount) " +
            "ingress_count=\(ingressSnapshot()) last_category=\(lastCategory)"
    }

    private func ingressSnapshot() -> UInt64 {
        ingressLock.lock(); defer { ingressLock.unlock() }
        return ingressCount
    }
}

private enum LaunchSettlementAuthorityCase: String {
    case zeroEventSurface
    case expectedPairSurface
}

private struct LaunchSettlementLease {
    fileprivate let generation: UInt64
    let authority: LaunchSettlementAuthorityCase
    let sequence: UInt64
    fileprivate let eventCount: Int
}

private final class RawDriverToTargetHandoffLedger {
    private enum Phase {
        case installing, prelaunch, preLaunchActionArmed, actionPending,
             targetBoundAwaitingIngressDrain, launchPairAwaitingEvents,
             launchPairAwaitingBaseline, launchSettlement,
             boundNavigation, finderAction, finderCommitted, elysiumAction, committed, ready,
             failed, closed
    }
    private enum LaunchPath: String { case alreadyFrontmost, expectedLaunchPair }
    private enum LaunchAuthorityPath: String { case zeroEventSurface, expectedPairSurface }
    private enum Category: String {
        case provisionalTarget, elysium, expectedPredecessor, expectedFinder, unexpectedOther
    }
    private enum Kind: String { case activate, deactivate }
    private enum ExpectedApplicationKind { case packaged, rawPredecessor }
    private struct ExpectedApplication {
        let kind: ExpectedApplicationKind
        let object: NSRunningApplication
        let pid: pid_t
        let bundleIdentifier: String?
        let bundle: URL?
        let executable: URL
        let processStart: ProcessStartIdentity?
        let executableIdentity: RegularFileIdentity?
        let executableHash: String?
    }
    private struct Event {
        let kind: Kind
        let category: Category
        let offsetMilliseconds: UInt64
        let identityExact: Bool
        let application: NSRunningApplication
        let pid: pid_t
        let bundleIdentifier: String?
        let bundle: URL?
        let executable: URL?
    }

    private let lock = NSLock()
    private let ingressLock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private let staticTarget: StaticArtifactAuthority
    private var elysium: ExpectedApplication?
    private var alreadyFrontmostCandidate: ExpectedApplication?
    private var predecessor: ExpectedApplication?
    private var finder: ExpectedApplication?
    private var generation: UInt64 = 1
    private var ingressCount: UInt64 = 0
    private var phase: Phase = .installing
    private var events: [Event] = []
    private var observerTokens: [NSObjectProtocol] = []
    private var terminalReason: String?
    private var launchPath: LaunchPath?
    private var launchAuthorityPath: LaunchAuthorityPath?
    private var launchElysiumActivated = false
    private var launchPredecessorDeactivated = false
    private var launchPairCompletionSequence: UInt64?
    private var finderActivated = false
    private var elysiumDeactivated = false
    private var elysiumActivated = false
    private var finderDeactivated = false

    init(staticTarget: StaticArtifactAuthority) {
        self.staticTarget = staticTarget
    }

    func installAndArmLifecycleLedger(center: NotificationCenter) throws {
        lock.lock()
        guard phase == .installing, observerTokens.isEmpty else {
            lock.unlock(); throw GateError.failed("lifecycle ledger install phase")
        }
        let installedGeneration = generation
        let activate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            self?.record(notification, kind: .activate, generation: installedGeneration)
        }
        let deactivate = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            self?.record(notification, kind: .deactivate, generation: installedGeneration)
        }
        observerTokens = [activate, deactivate]
        phase = .prelaunch
        lock.unlock()
    }

    func beginLaunchPathCapture() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.prelaunch])
        guard launchPath == nil else { throw GateError.failed(diagnosticsLocked()) }
        return UInt64(events.count)
    }

    func capturePredecessorOrStaticTarget(
        sequence: UInt64, frontmost: NSRunningApplication?,
        requiredPredecessor: NSRunningApplication
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.prelaunch])
        guard launchPath == nil, UInt64(events.count) == sequence, let frontmost,
              frontmost.isEqual(requiredPredecessor),
              frontmost.processIdentifier == requiredPredecessor.processIdentifier,
              frontmost.bundleIdentifier == requiredPredecessor.bundleIdentifier,
              frontmost.bundleURL.map({ canonicalURL($0.path) }) ==
                requiredPredecessor.bundleURL.map({ canonicalURL($0.path) }),
              frontmost.executableURL.map({ canonicalURL($0.path) }) ==
                requiredPredecessor.executableURL.map({ canonicalURL($0.path) }),
              let executable = frontmost.executableURL.map({ canonicalURL($0.path) }) else {
            failLocked("launch_path_capture")
            throw GateError.failed(diagnosticsLocked())
        }
        let bundle = frontmost.bundleURL.map({ canonicalURL($0.path) })
        let captured = ExpectedApplication(
            kind: .rawPredecessor, object: frontmost, pid: frontmost.processIdentifier,
            bundleIdentifier: frontmost.bundleIdentifier, bundle: bundle, executable: executable,
            processStart: ProcessStartIdentity.capture(frontmost.processIdentifier),
            executableIdentity: regularFileIdentity(executable),
            executableHash: try? hash(executable))
        if frontmost.bundleIdentifier == staticTarget.bundleIdentifier &&
            bundle == staticTarget.bundle && executable == staticTarget.executable {
            alreadyFrontmostCandidate = captured
            launchPath = .alreadyFrontmost
        } else {
            predecessor = captured
            launchPath = .expectedLaunchPair
        }
        phase = .preLaunchActionArmed
    }

    func armOpenAction() throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.preLaunchActionArmed])
        phase = .actionPending
    }

    func bindTargetAndReconcile(
        application: NSRunningApplication, bundle: URL, executable: URL
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard terminalReason == nil, phase == .actionPending,
              application.processIdentifier > 0,
              application.bundleIdentifier == staticTarget.bundleIdentifier,
              bundle == staticTarget.bundle, executable == staticTarget.executable else {
            failLocked("completion_binding_authority")
            throw GateError.failed(diagnosticsLocked())
        }
        let target = ExpectedApplication(
            kind: .packaged, object: application, pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier, bundle: bundle, executable: executable,
            processStart: nil, executableIdentity: nil, executableHash: nil)
        elysium = target
        for event in events {
            let targetEventExact = event.kind == .activate &&
                event.application.isEqual(target.object) && event.pid == target.pid &&
                event.bundleIdentifier == staticTarget.bundleIdentifier &&
                event.bundle == target.bundle && event.executable == target.executable
            let predecessorEventExact = event.kind == .deactivate &&
                predecessor.map { event.application.isEqual($0.object) && event.pid == $0.pid &&
                    event.bundle == $0.bundle && event.executable == $0.executable } == true
            if targetEventExact, !launchElysiumActivated {
                launchElysiumActivated = true
            } else if predecessorEventExact, !launchPredecessorDeactivated {
                launchPredecessorDeactivated = true
            } else {
                failLocked("provisional_reconciliation");
                throw GateError.failed(diagnosticsLocked())
            }
        }
        let observedIngress = ingressSnapshot()
        guard observedIngress <= 2, UInt64(events.count) <= observedIngress,
              events.count <= 2 else {
            failLocked("provisional_capacity_or_ingress")
            throw GateError.failed(diagnosticsLocked())
        }
        if launchPath == .alreadyFrontmost {
            guard events.isEmpty, observedIngress == 0,
                  alreadyFrontmostCandidate.map({ application.isEqual($0.object) &&
                    application.processIdentifier == $0.pid && bundle == $0.bundle &&
                    executable == $0.executable }) == true else {
                failLocked("already_frontmost_reconciliation")
                throw GateError.failed(diagnosticsLocked())
            }
            launchPairCompletionSequence = 0
            launchAuthorityPath = .zeroEventSurface
            phase = .launchSettlement
        } else if observedIngress > UInt64(events.count) {
            phase = .targetBoundAwaitingIngressDrain
        } else if launchElysiumActivated && launchPredecessorDeactivated {
            launchPairCompletionSequence = UInt64(events.count)
            launchAuthorityPath = .expectedPairSurface
            phase = .launchSettlement
        } else if observedIngress == 0, events.isEmpty {
            launchPairCompletionSequence = 0
            launchAuthorityPath = .zeroEventSurface
            phase = .launchSettlement
        } else {
            phase = .launchPairAwaitingEvents
        }
    }

    func terminatePrelaunch(_ reason: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if terminalReason == nil { failLocked(reason) }
        return diagnosticsLocked()
    }

    func beginLaunchBaselineSample() throws -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard terminalReason == nil else { throw GateError.failed(diagnosticsLocked()) }
        let observedIngress = ingressSnapshot()
        if phase == .targetBoundAwaitingIngressDrain {
            guard observedIngress <= 2, observedIngress >= UInt64(events.count) else {
                failLocked("provisional_ingress_drain")
                throw GateError.failed(diagnosticsLocked())
            }
            if observedIngress > UInt64(events.count) { return nil }
            if launchElysiumActivated && launchPredecessorDeactivated {
                launchPairCompletionSequence = UInt64(events.count)
                phase = .launchPairAwaitingBaseline
            } else {
                phase = .launchPairAwaitingEvents
            }
        }
        if let elysium {
            guard !elysium.object.isTerminated,
                  elysium.object.processIdentifier == elysium.pid,
                  elysium.object.bundleURL.map({ canonicalURL($0.path) }) == elysium.bundle,
                  elysium.object.executableURL.map({ canonicalURL($0.path) }) ==
                    elysium.executable else {
                failLocked("bound_target_identity_changed")
                throw GateError.failed(diagnosticsLocked())
            }
        }
        if launchPath == .expectedLaunchPair, let predecessor {
            guard !predecessor.object.isTerminated,
                  predecessor.object.processIdentifier == predecessor.pid,
                  predecessor.object.bundleIdentifier == predecessor.bundleIdentifier,
                  predecessor.object.bundleURL.map({ canonicalURL($0.path) }) ==
                    predecessor.bundle,
                  predecessor.object.executableURL.map({ canonicalURL($0.path) }) ==
                    predecessor.executable,
                  ProcessStartIdentity.capture(predecessor.pid) == predecessor.processStart,
                  regularFileIdentity(predecessor.executable) == predecessor.executableIdentity,
                  (try? hash(predecessor.executable)) == predecessor.executableHash else {
                failLocked("predecessor_identity_changed")
                throw GateError.failed(diagnosticsLocked())
            }
        }
        if phase == .launchPairAwaitingEvents { return nil }
        try requireNonterminalLocked([.launchPairAwaitingBaseline])
        guard let completion = launchPairCompletionSequence,
              completion == UInt64(events.count), observedIngress == completion else {
            failLocked("launch_pair_sequence")
            throw GateError.failed(diagnosticsLocked())
        }
        return completion
    }

    func finishLaunchBaselineSample(sequence: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.launchPairAwaitingBaseline])
        guard UInt64(events.count) == sequence else {
            failLocked("event_during_launch_baseline")
            throw GateError.failed(diagnosticsLocked())
        }
    }

    func commitLaunchBaseline(sequence: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.launchPairAwaitingBaseline])
        guard UInt64(events.count) == sequence,
              ingressSnapshot() == sequence,
              launchPairCompletionSequence == sequence else {
            failLocked("launch_baseline_commit")
            throw GateError.failed(diagnosticsLocked())
        }
        phase = .launchSettlement
    }

    func terminateLaunchBaseline(_ reason: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if terminalReason == nil { failLocked(reason) }
        return diagnosticsLocked()
    }

    func beginLaunchSettlementSample() throws -> LaunchSettlementLease? {
        lock.lock(); defer { lock.unlock() }
        guard terminalReason == nil else { throw GateError.failed(diagnosticsLocked()) }
        let observedIngress = ingressSnapshot()
        if phase == .targetBoundAwaitingIngressDrain {
            guard observedIngress <= 2, observedIngress >= UInt64(events.count) else {
                failLocked("launch_surface_ingress_drain")
                throw GateError.failed(diagnosticsLocked())
            }
            if observedIngress > UInt64(events.count) { return nil }
            if launchElysiumActivated && launchPredecessorDeactivated {
                launchPairCompletionSequence = UInt64(events.count)
                launchAuthorityPath = .expectedPairSurface
                phase = .launchSettlement
            } else if events.isEmpty {
                launchPairCompletionSequence = 0
                launchAuthorityPath = .zeroEventSurface
                phase = .launchSettlement
            } else {
                phase = .launchPairAwaitingEvents
            }
        }
        if phase == .launchPairAwaitingEvents { return nil }
        try requireNonterminalLocked([.launchSettlement])
        let authority: LaunchSettlementAuthorityCase
        switch launchAuthorityPath {
        case .zeroEventSurface:
            guard events.isEmpty, observedIngress == 0,
                  !launchElysiumActivated,
                  launchPairCompletionSequence == 0 else {
                failLocked("zero_event_lease_authority")
                throw GateError.failed(diagnosticsLocked())
            }
            authority = .zeroEventSurface
        case .expectedPairSurface:
            guard events.count == 2, observedIngress == 2,
                  launchElysiumActivated, launchPredecessorDeactivated,
                  launchPairCompletionSequence == 2 else {
                failLocked("expected_pair_lease_authority")
                throw GateError.failed(diagnosticsLocked())
            }
            authority = .expectedPairSurface
        case nil:
            failLocked("missing_launch_lease_authority")
            throw GateError.failed(diagnosticsLocked())
        }
        return LaunchSettlementLease(
            generation: generation, authority: authority,
            sequence: UInt64(events.count), eventCount: events.count)
    }

    func finishLaunchSettlementSample(lease: LaunchSettlementLease) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard terminalReason == nil else { throw GateError.failed(diagnosticsLocked()) }
        if phase == .launchPairAwaitingEvents { return false }
        try requireNonterminalLocked([.launchSettlement])
        guard generation == lease.generation, events.count == lease.eventCount,
              UInt64(events.count) == lease.sequence,
              ingressSnapshot() == lease.sequence else { return false }
        switch lease.authority {
        case .zeroEventSurface:
            return launchAuthorityPath == .zeroEventSurface && events.isEmpty &&
                !launchElysiumActivated &&
                launchPairCompletionSequence == 0
        case .expectedPairSurface:
            return launchAuthorityPath == .expectedPairSurface && events.count == 2 &&
                launchElysiumActivated && launchPredecessorDeactivated &&
                launchPairCompletionSequence == lease.sequence
        }
    }

    func commitLaunchPresentation(lease: LaunchSettlementLease) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard terminalReason == nil else { throw GateError.failed(diagnosticsLocked()) }
        if phase == .launchPairAwaitingEvents { return false }
        try requireNonterminalLocked([.launchSettlement])
        guard generation == lease.generation, events.count == lease.eventCount,
              UInt64(events.count) == lease.sequence else { return false }
        guard ingressSnapshot() == lease.sequence,
              launchAuthorityPath != nil else {
            failLocked("launch_surface_final_drain")
            throw GateError.failed(diagnosticsLocked())
        }
        phase = .boundNavigation
        return true
    }

    func terminateLaunchSettlement(_ reason: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if terminalReason == nil { failLocked(reason) }
        return diagnosticsLocked()
    }

    func requireBoundNavigation() throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.boundNavigation])
    }

    func beginFinderAction(
        finder: NSRunningApplication, bundle: URL, executable: URL
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.boundNavigation])
        self.finder = ExpectedApplication(
            kind: .packaged, object: finder, pid: finder.processIdentifier,
            bundleIdentifier: finder.bundleIdentifier, bundle: bundle, executable: executable,
            processStart: nil, executableIdentity: nil, executableHash: nil)
        phase = .finderAction
    }

    func awaitFinderPair(timeout: TimeInterval) throws {
        try awaitPhase(.finderCommitted, timeout: timeout, missing: "finder_pair_missing")
    }

    func beginElysiumAction() throws {
        try transition(from: .finderCommitted, to: .elysiumAction, label: "pebble_action_boundary")
    }

    func beginFinderSurfaceSample() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.finderCommitted])
        return UInt64(events.count)
    }

    func finishFinderSurfaceSample(sequence: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.finderCommitted])
        guard UInt64(events.count) == sequence else {
            failLocked("event_during_finder_surface_sample")
            throw GateError.failed(diagnosticsLocked())
        }
    }

    func requireFinderSurfaceFinal() throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.finderCommitted])
    }

    func terminateFinderSurface(_ reason: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if terminalReason == nil {
            if samePhase(phase, .finderCommitted) {
                failLocked(reason)
            } else {
                failLocked("finder_surface_phase")
            }
        }
        return diagnosticsLocked()
    }

    func awaitElysiumPair(timeout: TimeInterval) throws {
        try awaitPhase(.committed, timeout: timeout, missing: "pebble_pair_missing")
    }

    func beginSurfaceSample() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.committed, .ready])
        return UInt64(events.count)
    }

    func finishSurfaceSample(sequence: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([.committed, .ready])
        guard UInt64(events.count) == sequence else {
            failLocked("event_during_surface_sample")
            throw GateError.failed(diagnosticsLocked())
        }
    }

    func markReady() throws {
        try transition(from: .committed, to: .ready, label: "ready_commit")
    }

    func close(center: NotificationCenter) {
        lock.lock()
        guard phase != .closed else { lock.unlock(); return }
        phase = .closed
        generation &+= 1
        let tokens = observerTokens
        observerTokens.removeAll(keepingCapacity: false)
        lock.unlock()
        for token in tokens { center.removeObserver(token) }
    }

    private func transition(from: Phase, to: Phase, label: String) throws {
        lock.lock(); defer { lock.unlock() }
        try requireNonterminalLocked([from])
        phase = to
        if label.isEmpty { failLocked("empty_action_boundary") }
    }

    private func awaitPhase(_ expected: Phase, timeout: TimeInterval, missing: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            lock.lock()
            if phase == .failed {
                let evidence = diagnosticsLocked(); lock.unlock()
                throw GateError.failed(evidence)
            }
            let complete = phase == expected
            lock.unlock()
            if complete { return }
            pumpAppKitEvent(until: Date(timeIntervalSinceNow: 0.02))
        } while ProcessInfo.processInfo.systemUptime < deadline
        lock.lock()
        failLocked(missing)
        let evidence = diagnosticsLocked()
        lock.unlock()
        throw GateError.failed(evidence)
    }

    private func record(_ notification: Notification, kind: Kind, generation: UInt64) {
        ingressLock.lock()
        ingressCount &+= 1
        ingressLock.unlock()
        lock.lock(); defer { lock.unlock() }
        guard phase != .closed else { return }
        guard generation == self.generation else {
            failLocked("observer_generation_mismatch"); return
        }
        guard let candidate = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { failLocked("notification_payload"); return }
        let classified = classify(candidate)
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        let event = Event(
            kind: kind, category: classified.category,
            offsetMilliseconds: UInt64(elapsed * 1_000), identityExact: classified.identityExact,
            application: candidate, pid: candidate.processIdentifier,
            bundleIdentifier: candidate.bundleIdentifier,
            bundle: candidate.bundleURL.map({ canonicalURL($0.path) }),
            executable: candidate.executableURL.map({ canonicalURL($0.path) }))
        switch phase {
        case .installing, .prelaunch, .preLaunchActionArmed:
            events.append(event)
            failLocked("event_before_open_action")
        case .actionPending:
            guard ingressSnapshot() <= 2, events.count < 2 else {
                failLocked("provisional_capacity"); return
            }
            let provisionalTarget = classified.category == .provisionalTarget && kind == .activate
            let predecessorExit = classified.category == .expectedPredecessor && kind == .deactivate
            guard launchPath == .expectedLaunchPair, classified.identityExact,
                  (provisionalTarget || predecessorExit),
                  !events.contains(where: { $0.category == classified.category && $0.kind == kind }) else {
                events.append(event)
                failLocked("provisional_foreign_or_duplicate"); return
            }
            events.append(event)
        case .targetBoundAwaitingIngressDrain, .launchPairAwaitingEvents:
            guard ingressSnapshot() <= 2, events.count < 2 else {
                failLocked("provisional_capacity"); return
            }
            events.append(event)
            guard classified.identityExact else {
                failLocked("bound_event_identity"); return
            }
            if classified.category == .elysium, kind == .activate, !launchElysiumActivated {
                launchElysiumActivated = true
            } else if classified.category == .expectedPredecessor, kind == .deactivate,
                      !launchPredecessorDeactivated {
                launchPredecessorDeactivated = true
            } else {
                failLocked("bound_pair_duplicate_or_foreign"); return
            }
            if launchElysiumActivated && launchPredecessorDeactivated &&
                ingressSnapshot() == UInt64(events.count) {
                launchPairCompletionSequence = UInt64(events.count)
                launchAuthorityPath = .expectedPairSurface
                phase = .launchSettlement
            }
        case .launchPairAwaitingBaseline:
            failLocked("event_after_launch_pair")
        case .launchSettlement:
            guard launchAuthorityPath == .zeroEventSurface,
                  ingressSnapshot() <= 1, events.isEmpty else {
                if events.count < 32 { events.append(event) }
                failLocked("event_after_launch_authority_freeze"); return
            }
            events.append(event)
            guard classified.identityExact,
                  classified.category == .elysium && kind == .activate else {
                failLocked("launch_surface_foreign_event"); return
            }
            launchAuthorityPath = .expectedPairSurface
            launchPairCompletionSequence = nil
            if classified.category == .elysium { launchElysiumActivated = true }
            phase = .launchPairAwaitingEvents
        case .boundNavigation:
            guard events.count < 32 else { failLocked("event_capacity"); return }
            events.append(event)
            guard classified.identityExact, classified.category != .unexpectedOther else {
                failLocked("unexpected_or_identity_mismatch"); return
            }
            failLocked("launch_lifecycle_event")
        case .finderAction:
            guard events.count < 32 else { failLocked("event_capacity"); return }
            events.append(event)
            guard classified.identityExact, classified.category != .unexpectedOther else {
                failLocked("unexpected_or_identity_mismatch"); return
            }
            if classified.category == .expectedFinder, kind == .activate, !finderActivated {
                finderActivated = true
            } else if classified.category == .elysium, kind == .deactivate, !elysiumDeactivated {
                elysiumDeactivated = true
            } else { failLocked("finder_pair_duplicate_or_order"); return }
            if finderActivated && elysiumDeactivated { phase = .finderCommitted }
        case .elysiumAction:
            guard events.count < 32 else { failLocked("event_capacity"); return }
            events.append(event)
            guard classified.identityExact, classified.category != .unexpectedOther else {
                failLocked("unexpected_or_identity_mismatch"); return
            }
            if classified.category == .elysium, kind == .activate, !elysiumActivated {
                elysiumActivated = true
            } else if classified.category == .expectedFinder, kind == .deactivate,
                      !finderDeactivated {
                finderDeactivated = true
            } else { failLocked("pebble_pair_duplicate_or_order"); return }
            if elysiumActivated && finderDeactivated { phase = .committed }
        case .finderCommitted:
            if events.count < 32 { events.append(event) }
            failLocked("event_between_action_pairs")
        case .committed, .ready:
            if events.count < 32 { events.append(event) }
            failLocked("postcommit_event")
        case .failed, .closed:
            return
        }
    }

    private func classify(_ candidate: NSRunningApplication)
        -> (category: Category, identityExact: Bool) {
        if let elysium, candidate.processIdentifier == elysium.pid {
            return (.elysium, candidate.isEqual(elysium.object) &&
                candidate.bundleIdentifier == staticTarget.bundleIdentifier &&
                candidate.bundleURL.map({ canonicalURL($0.path) }) == elysium.bundle &&
                candidate.executableURL.map({ canonicalURL($0.path) }) == elysium.executable)
        }
        if elysium == nil,
           candidate.bundleIdentifier == staticTarget.bundleIdentifier,
           candidate.bundleURL.map({ canonicalURL($0.path) }) == staticTarget.bundle,
           candidate.executableURL.map({ canonicalURL($0.path) }) == staticTarget.executable {
            return (.provisionalTarget, true)
        }
        if let finder, candidate.processIdentifier == finder.pid {
            return (.expectedFinder, candidate.isEqual(finder.object) &&
                candidate.bundleURL.map({ canonicalURL($0.path) }) == finder.bundle &&
                candidate.executableURL.map({ canonicalURL($0.path) }) == finder.executable)
        }
        if let predecessor, candidate.processIdentifier == predecessor.pid {
            return (.expectedPredecessor, candidate.isEqual(predecessor.object) &&
                candidate.bundleIdentifier == predecessor.bundleIdentifier &&
                candidate.bundleURL.map({ canonicalURL($0.path) }) == predecessor.bundle &&
                candidate.executableURL.map({ canonicalURL($0.path) }) == predecessor.executable &&
                ProcessStartIdentity.capture(candidate.processIdentifier) == predecessor.processStart &&
                regularFileIdentity(predecessor.executable) == predecessor.executableIdentity &&
                (try? hash(predecessor.executable)) == predecessor.executableHash)
        }
        return (.unexpectedOther, false)
    }

    private func requireNonterminalLocked(_ allowed: [Phase]) throws {
        let observedIngress = ingressSnapshot()
        guard observedIngress == UInt64(events.count) else {
            failLocked("event_ingress_race")
            throw GateError.failed(diagnosticsLocked())
        }
        guard terminalReason == nil, allowed.contains(where: { samePhase($0, phase) }) else {
            throw GateError.failed(diagnosticsLocked())
        }
    }

    private func samePhase(_ lhs: Phase, _ rhs: Phase) -> Bool {
        switch (lhs, rhs) {
        case (.installing, .installing), (.prelaunch, .prelaunch),
             (.preLaunchActionArmed, .preLaunchActionArmed),
             (.actionPending, .actionPending),
             (.targetBoundAwaitingIngressDrain, .targetBoundAwaitingIngressDrain),
             (.launchPairAwaitingEvents, .launchPairAwaitingEvents),
             (.launchPairAwaitingBaseline, .launchPairAwaitingBaseline),
             (.launchSettlement, .launchSettlement),
             (.boundNavigation, .boundNavigation), (.finderAction, .finderAction),
             (.finderCommitted, .finderCommitted), (.elysiumAction, .elysiumAction),
             (.committed, .committed), (.ready, .ready), (.failed, .failed), (.closed, .closed):
            return true
        default: return false
        }
    }

    private func failLocked(_ reason: String) {
        if terminalReason == nil { terminalReason = reason }
        phase = .failed
    }

    private func ingressSnapshot() -> UInt64 {
        ingressLock.lock(); defer { ingressLock.unlock() }
        return ingressCount
    }

    private func diagnosticsLocked() -> String {
        let eventEvidence = events.map {
            "\($0.kind.rawValue):\($0.category.rawValue):offset_ms=\($0.offsetMilliseconds):" +
                "identity=\($0.identityExact)"
        }.joined(separator: ",")
        return "handoff terminal=\(terminalReason ?? "none") " +
            "launch_baseline_path=\(launchPath?.rawValue ?? "terminal") " +
            "launch_authority_path=\(launchAuthorityPath?.rawValue ?? "terminal") " +
            "predecessor_bound=\(predecessor != nil) " +
            "pebble_activate_seen=\(launchElysiumActivated) " +
            "raw_state_transition_required=true " +
            "pair_complete=\(launchPairCompletionSequence != nil) " +
            "static_target_exact=\(staticTarget.exact()) " +
            "completion_bound=\(elysium != nil) buffer_reconciled=\(elysium != nil) " +
            "finder_bound=\(finder != nil) " +
            "finder_pair_committed=\(finderActivated && elysiumDeactivated) " +
            "pebble_pair_committed=\(elysiumActivated && finderDeactivated) " +
            "event_count=\(events.count) ingress_count=\(ingressSnapshot()) " +
            "events=[\(eventEvidence)]"
    }
}

private func runningApplicationIdentityMatches(
    valueEqual: Bool, original: BoundRunningApplicationIdentity,
    candidatePID: pid_t?, candidateBundle: URL?, candidateExecutable: URL?,
    measuredSHA256: String?
) -> Bool {
    valueEqual && candidatePID == original.pid && candidateBundle == original.bundle &&
        candidateExecutable == original.executable && measuredSHA256 == original.measuredSHA256
}

private struct BoundedTargetProcessSet {
    let matches: [NSRunningApplication]
    let enumerationExact: Bool

    static func capture(
        workspace: NSWorkspace = .shared, identity: BoundRunningApplicationIdentity,
        bundleIdentifier: String, cap: Int = 512
    ) -> BoundedTargetProcessSet {
        let applications = workspace.runningApplications
        guard applications.count <= cap else {
            return BoundedTargetProcessSet(matches: [], enumerationExact: false)
        }
        let matches = applications.filter { candidate in
            candidate.processIdentifier == identity.pid ||
                candidate.bundleIdentifier == bundleIdentifier ||
                candidate.bundleURL.map({ canonicalURL($0.path) }) == identity.bundle ||
                candidate.executableURL.map({ canonicalURL($0.path) }) == identity.executable
        }
        return BoundedTargetProcessSet(matches: matches, enumerationExact: true)
    }

    func isSoleOriginal(_ original: NSRunningApplication,
                        identity: BoundRunningApplicationIdentity) -> Bool {
        enumerationExact && matches.count == 1 && matches[0].isEqual(original) &&
            matches[0].processIdentifier == identity.pid &&
            matches[0].bundleURL.map({ canonicalURL($0.path) }) == identity.bundle &&
            matches[0].executableURL.map({ canonicalURL($0.path) }) == identity.executable
    }
}

private struct LaunchFastObservation {
    let authorityExact: Bool
    let finishedLaunching: Bool
    let active: Bool
    let frontmostExact: Bool
    let windowCountExact: Bool
    let focusedWindowExact: Bool
    let roleExact: Bool
    let subroleStandard: Bool
    let typedModePresent: Bool
    let finiteRectangle: Bool
    let window: AXUIElement?
    let mode: LaunchPresentationMode?
    let rectangle: CGRect?

    var eligible: Bool {
        finishedLaunching && active && frontmostExact && windowCountExact && focusedWindowExact && roleExact &&
            subroleStandard && typedModePresent && finiteRectangle && window != nil &&
            mode != nil && rectangle != nil
    }

    var predicates: [(String, Bool)] { [
        ("authority_exact", authorityExact), ("finished_launching", finishedLaunching),
        ("active", active),
        ("frontmost_exact", frontmostExact), ("window_count_exact", windowCountExact),
        ("focused_window_exact", focusedWindowExact), ("role_exact", roleExact),
        ("subrole_standard", subroleStandard), ("typed_mode_present", typedModePresent),
        ("finite_rectangle", finiteRectangle),
    ] }
}

private enum LaunchShippingPhase: String {
    case hiddenAlphaZero
    case visibleAlphaOne
    case ambiguous
}

private struct LaunchCheapObservation {
    let authorityExact: Bool
    let finishedLaunching: Bool
    let active: Bool
    let frontmostExact: Bool
    let predecessorFrontmostExact: Bool
    let lease: LaunchSettlementLease
    let inputPreflight: Bool
    let ownerWindowCount: Int
    let ownerGeometryFinite: Bool
    let ownerOnScreen: Bool
    let ownerAlpha: Double?
    let activeDisplays: BoundedDisplayList
    let onlineDisplays: BoundedDisplayList
    let displayAuthorityExact: Bool
    let containingActiveDisplayCount: Int
    let containingDisplayAwake: Bool
    let nsscreenMappingCount: Int
    let cgWindow: CGOwnerWindow?
    let displayID: CGDirectDisplayID?
    let titlebar: DenialTitlebarPoint?

    var shippingPhase: LaunchShippingPhase {
        if ownerWindowCount == 1, ownerGeometryFinite, ownerOnScreen, ownerAlpha == 0.0 {
            return .hiddenAlphaZero
        }
        if ownerWindowCount == 1, ownerGeometryFinite, ownerOnScreen, ownerAlpha == 1.0 {
            return .visibleAlphaOne
        }
        return .ambiguous
    }
}

private struct ExpectedPairLaunchSample {
    let authorityExact: Bool
    let finishedLaunching: Bool
    let active: Bool
    let frontmostExact: Bool
    let workspaceUnchanged: Bool
    let startedAt: TimeInterval
    let endedAt: TimeInterval

    var completedWithinDeadline: Bool {
        startedAt.isFinite && endedAt.isFinite && endedAt >= startedAt
    }
}

private struct DenialModeLaunchSample {
    let cheap: LaunchCheapObservation
    let fast: LaunchFastObservation?
    let denial: LaunchDenialObservation?
    let workspaceUnchanged: Bool
    let axUnchanged: Bool
    let startedAt: TimeInterval
    let endedAt: TimeInterval

    var completedWithinDeadline: Bool {
        startedAt.isFinite && endedAt.isFinite && endedAt >= startedAt
    }
}

private enum CommonModeLaunchDisposition {
    case expectedPair(ExpectedPairLaunchSample)
    case denial(DenialModeLaunchSample)

    var endedAt: TimeInterval {
        switch self {
        case .expectedPair(let value): return value.endedAt
        case .denial(let value): return value.endedAt
        }
    }
}

private let denialPostBudget: TimeInterval = 0.100

private struct ConditionalDenialTimingBudget {
    private static let preFallbackDuration: TimeInterval = 8.1
    private static let eligibleDenialDuration: TimeInterval = 4.0
    private static let hardCapDuration: TimeInterval = 10.5

    enum AnchorResult { case installed, unchanged, unavailable }

    let samplingStarted: TimeInterval
    let preFallbackDeadline: TimeInterval
    let hardCapDeadline: TimeInterval
    private(set) var eligibleAnchor: TimeInterval?
    private(set) var anchoredDeadline: TimeInterval?

    init?(samplingStarted: TimeInterval) {
        guard let preFallbackDeadline = Self.checkedAdd(
            samplingStarted, Self.preFallbackDuration),
              let hardCapDeadline = Self.checkedAdd(
                samplingStarted, Self.hardCapDuration),
              preFallbackDeadline <= hardCapDeadline else { return nil }
        self.samplingStarted = samplingStarted
        self.preFallbackDeadline = preFallbackDeadline
        self.hardCapDeadline = hardCapDeadline
    }

    var effectiveDeadline: TimeInterval { anchoredDeadline ?? preFallbackDeadline }
    var isAnchored: Bool { anchoredDeadline != nil }

    mutating func anchorFirstEligibleSample(recordedStart: TimeInterval) -> AnchorResult {
        if anchoredDeadline != nil { return .unchanged }
        guard recordedStart.isFinite, recordedStart >= samplingStarted,
              recordedStart <= preFallbackDeadline,
              let eligibleDeadline = Self.checkedAdd(
                recordedStart, Self.eligibleDenialDuration) else { return .unavailable }
        let deadline = min(eligibleDeadline, hardCapDeadline)
        guard deadline.isFinite, deadline >= samplingStarted,
              deadline >= recordedStart, deadline <= hardCapDeadline else { return .unavailable }
        eligibleAnchor = recordedStart
        anchoredDeadline = deadline
        return .installed
    }

    func contains(_ instant: TimeInterval) -> Bool {
        instant.isFinite && instant >= samplingStarted && instant <= effectiveDeadline
    }

    var redactedOffsets: (anchor: Int?, deadline: Int?, hardCap: Int?) {
        (Self.checkedMilliseconds(eligibleAnchor.map { $0 - samplingStarted }),
         Self.checkedMilliseconds(effectiveDeadline - samplingStarted),
         Self.checkedMilliseconds(hardCapDeadline - samplingStarted))
    }

    private static func checkedAdd(
        _ value: TimeInterval, _ duration: TimeInterval
    ) -> TimeInterval? {
        guard value.isFinite, value >= 0, duration.isFinite, duration > 0 else { return nil }
        let result = value + duration
        guard result.isFinite, result > value else { return nil }
        return result
    }

    private static func checkedMilliseconds(_ value: TimeInterval?) -> Int? {
        guard let value, value.isFinite, value >= 0, value <= hardCapDuration else { return nil }
        let milliseconds = value * 1_000
        guard milliseconds.isFinite, milliseconds <= TimeInterval(Int.max) else { return nil }
        return Int(milliseconds.rounded())
    }
}

private enum ConditionalLaunchDenialState: String {
    case unresolved
    case skippedSystemGranted
}

private final class ConditionalLaunchDenialAction {
    private(set) var state: ConditionalLaunchDenialState = .unresolved

    func close(_ terminal: ConditionalLaunchDenialState) throws {
        guard state == .unresolved, terminal == .skippedSystemGranted else {
            throw GateError.failed("conditional launch action reused")
        }
        state = terminal
    }

    var diagnosticPath: String {
        switch state {
        case .unresolved: return "terminal"
        case .skippedSystemGranted: return "systemGranted"
        }
    }
}

private struct PrivateTextTuple {
    let element: AXUIElement
    let value: String
    let range: CFRange
    let editable: Bool
}

private struct PrivateLaunchStateSnapshot {
    let text: [PrivateTextTuple]

    static func capture(application: AXUIElement) -> PrivateLaunchStateSnapshot? {
        capture(elements: descendants(application))
    }

    static func capture(elements: [AXUIElement]) -> PrivateLaunchStateSnapshot? {
        let fields = elements.filter {
            axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole
        }
        guard fields.count <= 8 else { return nil }
        var tuples: [PrivateTextTuple] = []
        for field in fields {
            guard let value = axString(field, kAXValueAttribute as CFString),
                  let range = axRange(field, kAXSelectedTextRangeAttribute as CFString),
                  range.location >= 0, range.length >= 0 else { return nil }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                field, kAXValueAttribute as CFString, &settable) == .success else { return nil }
            tuples.append(PrivateTextTuple(
                element: field, value: value, range: range, editable: settable.boolValue))
        }
        return PrivateLaunchStateSnapshot(text: tuples)
    }

    func isExactlyRetained(in application: AXUIElement) -> Bool {
        guard let current = Self.capture(application: application),
              current.text.count == text.count else { return false }
        return zip(text, current.text).allSatisfy { before, after in
            CFEqual(before.element, after.element) && before.value == after.value &&
                before.range.location == after.range.location &&
                before.range.length == after.range.length && before.editable == after.editable
        }
    }
}

private let deniedAXDescendantCap = 768

private struct DeniedAXSnapshot {
    let windows: [AXUIElement]
    let truncated: Bool
    let focusedChildrenZero: Bool
    let standardInactiveSurfaceZero: Bool
    let privateState: PrivateLaunchStateSnapshot?

    static func capture(application: AXUIElement) -> DeniedAXSnapshot {
        let windows = axValue(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        let bounded = boundedDescendants(application, cap: deniedAXDescendantCap)
        let focusedChildren = bounded.elements.filter { element in
            !windows.contains(where: { window in CFEqual(window, element) }) &&
                axBool(element, kAXFocusedAttribute as CFString) == true
        }
        let standardSurface = windows.contains { window in
            guard axString(window, kAXRoleAttribute as CFString) == kAXWindowRole,
                  axString(window, kAXSubroleAttribute as CFString) ==
                    kAXStandardWindowSubrole,
                  axFullScreen(window) != nil,
                  let point = axPoint(window, kAXPositionAttribute as CFString),
                  let size = axSize(window, kAXSizeAttribute as CFString) else { return false }
            return [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite) &&
                size.width > 0 && size.height > 0
        }
        return DeniedAXSnapshot(
            windows: windows, truncated: bounded.truncated,
            focusedChildrenZero: focusedChildren.isEmpty,
            standardInactiveSurfaceZero: !standardSurface,
            privateState: bounded.truncated ? nil :
                PrivateLaunchStateSnapshot.capture(elements: bounded.elements))
    }
}

private struct LaunchDenialObservation {
    let authorityExact: Bool
    let finishedLaunching: Bool
    let inactive: Bool
    let predecessorFrontmostExact: Bool
    let lease: LaunchSettlementLease
    var workspaceUnchanged: Bool
    var axUnchanged: Bool
    let noFocusedProductChild: Bool
    let noStandardInactiveSurface: Bool
    let inputPreflight: Bool
    let ownerWindowCount: Int
    let ownerGeometryFinite: Bool
    let ownerOnScreen: Bool
    let ownerAlphaOne: Bool
    let activeDisplays: BoundedDisplayList
    let onlineDisplays: BoundedDisplayList
    let displayAuthorityExact: Bool
    let containingActiveDisplayCount: Int
    let containingDisplayAwake: Bool
    let nsscreenMappingCount: Int
    let cgWindow: CGOwnerWindow?
    let displayID: CGDirectDisplayID?
    let titlebar: DenialTitlebarPoint?
    let privateState: PrivateLaunchStateSnapshot?
    let axSnapshotTruncated: Bool

    var eligible: Bool {
        authorityExact && finishedLaunching && inactive && predecessorFrontmostExact &&
            lease.authority == .zeroEventSurface && lease.sequence == 0 &&
            workspaceUnchanged && axUnchanged && noFocusedProductChild &&
            noStandardInactiveSurface && inputPreflight && ownerWindowCount == 1 &&
            ownerGeometryFinite && ownerOnScreen && ownerAlphaOne && displayAuthorityExact &&
            containingActiveDisplayCount == 1 && containingDisplayAwake &&
            nsscreenMappingCount == 1 && cgWindow != nil && displayID != nil &&
            titlebar != nil && !axSnapshotTruncated && privateState?.text.isEmpty == true
    }

    func sameCandidate(as other: LaunchDenialObservation) -> Bool {
        eligible && other.eligible && candidateComparison(as: other).allSatisfy(\.1)
    }

    func candidateComparison(as other: LaunchDenialObservation) -> [(String, Bool)] {
        let lhsWindow = cgWindow
        let rhsWindow = other.cgWindow
        let lhsTitlebar = titlebar
        let rhsTitlebar = other.titlebar
        return [
            ("candidate_id_equal", lhsWindow?.id == rhsWindow?.id && lhsWindow != nil),
            ("candidate_rectangle_equal",
             lhsWindow?.rectangle == rhsWindow?.rectangle && lhsWindow != nil),
            ("candidate_onscreen_equal",
             lhsWindow?.onScreen == rhsWindow?.onScreen && lhsWindow != nil),
            ("candidate_alpha_equal", lhsWindow?.alpha == rhsWindow?.alpha && lhsWindow != nil),
            ("candidate_display_equal", displayID == other.displayID && displayID != nil),
            ("candidate_titlebar_point_equal",
             lhsTitlebar?.cgPoint == rhsTitlebar?.cgPoint && lhsTitlebar != nil),
            ("candidate_titlebar_band_equal",
             lhsTitlebar?.cgTitlebarBand == rhsTitlebar?.cgTitlebarBand && lhsTitlebar != nil),
            ("candidate_private_tuple_equal",
             privateTextSnapshotsEqual(privateState, other.privateState)),
        ]
    }

    var predicates: [(String, Bool)] { [
        ("authority_exact", authorityExact), ("finished_launching", finishedLaunching),
        ("inactive", inactive),
        ("predecessor_frontmost_exact", predecessorFrontmostExact),
        ("workspace_zero_event_lease", lease.authority == .zeroEventSurface && lease.sequence == 0),
        ("workspace_unchanged", workspaceUnchanged), ("ax_unchanged", axUnchanged),
        ("focused_children_zero", noFocusedProductChild),
        ("standard_inactive_surface_zero", noStandardInactiveSurface),
        ("input_preflight", inputPreflight), ("owner_window_unique", ownerWindowCount == 1),
        ("owner_geometry_finite", ownerGeometryFinite), ("owner_onscreen", ownerOnScreen),
        ("owner_alpha_one", ownerAlphaOne),
        ("active_display_query_success", activeDisplays.querySuccess),
        ("online_display_query_success", onlineDisplays.querySuccess),
        ("containing_display_awake", containingDisplayAwake),
        ("titlebar_conversion_valid", titlebar != nil),
        ("ax_snapshot_not_truncated", !axSnapshotTruncated),
        ("private_snapshot_capture", privateState != nil),
        ("private_text_empty", privateState?.text.isEmpty == true),
    ] }

    var redactedAggregate: String {
        let booleans = predicates.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let activeCount = activeDisplays.count < 0 ? "unknown" :
            String(min(activeDisplays.count, 33))
        let onlineCount = onlineDisplays.count < 0 ? "unknown" :
            String(min(onlineDisplays.count, 33))
        let textCount = privateState.map { String(min($0.text.count, 9)) } ?? "unknown"
        return booleans + " owner_window_count=\(min(ownerWindowCount, 33)) " +
            "active_display_query_state=\(activeDisplays.state.rawValue) " +
            "active_display_count=\(activeCount) " +
            "containing_active_display_count=\(min(containingActiveDisplayCount, 33)) " +
            "online_display_query_state=\(onlineDisplays.state.rawValue) " +
            "online_display_count=\(onlineCount) " +
            "nsscreen_mapping_count=\(min(nsscreenMappingCount, 33)) " +
            "private_text_count=\(textCount)"
    }
}

private func privateTextSnapshotsEqual(
    _ lhs: PrivateLaunchStateSnapshot?, _ rhs: PrivateLaunchStateSnapshot?
) -> Bool {
    guard let lhs, let rhs, lhs.text.count == rhs.text.count else { return false }
    return zip(lhs.text, rhs.text).allSatisfy { before, after in
        CFEqual(before.element, after.element) && before.value == after.value &&
            before.range.location == after.range.location &&
            before.range.length == after.range.length && before.editable == after.editable
    }
}

private final class LaunchDenialDiagnostics {
    private var last: LaunchDenialObservation?
    private var everTrue: [String: Bool] = [:]
    private var everFalse: [String: Bool] = [:]
    private(set) var totalSamples = 0
    private(set) var maximumConsecutiveSamples = 0
    private var lastCandidateComparison: [(String, Bool)] = []
    private var lastShippingPhase = LaunchShippingPhase.ambiguous
    private var lastSampleDurationMilliseconds: Int?
    private var maximumSampleDurationMilliseconds = 0
    private var firstEligibleOffsetMilliseconds: Int?
    private var allocationStartedBeforeDeadline: Bool?
    private var allocationBudgetRemaining: Bool?
    private var adjacentCheckCompleted: Bool?
    private var adjacentDurationMilliseconds: Int?
    private var postBudgetRemaining: Bool?
    private var postStartedBeforeDeadline: Bool?
    private var postCompletedByDeadline: Bool?
    private var postDurationMilliseconds: Int?
    private var budgetAnchorOffsetMilliseconds: Int?
    private var budgetDeadlineOffsetMilliseconds: Int?
    private var budgetHardCapOffsetMilliseconds: Int?

    func recordBudget(_ budget: ConditionalDenialTimingBudget) {
        let offsets = budget.redactedOffsets
        budgetAnchorOffsetMilliseconds = offsets.anchor
        budgetDeadlineOffsetMilliseconds = offsets.deadline
        budgetHardCapOffsetMilliseconds = offsets.hardCap
    }

    func record(
        _ value: LaunchDenialObservation, consecutive: Int,
        comparedTo candidate: LaunchDenialObservation?, shippingPhase: LaunchShippingPhase,
        sampleDuration: TimeInterval, firstEligibleOffset: TimeInterval?
    ) {
        last = value
        lastCandidateComparison = candidate.map { value.candidateComparison(as: $0) } ?? []
        lastShippingPhase = shippingPhase
        lastSampleDurationMilliseconds = cappedMilliseconds(sampleDuration)
        maximumSampleDurationMilliseconds = max(
            maximumSampleDurationMilliseconds, lastSampleDurationMilliseconds ?? 0)
        if firstEligibleOffsetMilliseconds == nil, let firstEligibleOffset {
            firstEligibleOffsetMilliseconds = cappedMilliseconds(firstEligibleOffset)
        }
        totalSamples = min(totalSamples + 1, 10_000)
        maximumConsecutiveSamples = min(max(maximumConsecutiveSamples, consecutive), 10_000)
        for (name, predicate) in value.predicates {
            everTrue[name, default: false] = everTrue[name, default: false] || predicate
            everFalse[name, default: false] = everFalse[name, default: false] || !predicate
        }
    }

    func recordAllocation(startedBeforeDeadline: Bool, budgetRemaining: Bool) {
        allocationStartedBeforeDeadline = startedBeforeDeadline
        allocationBudgetRemaining = budgetRemaining
    }

    func recordAdjacent(
        completed: Bool, duration: TimeInterval, postBudgetRemaining: Bool
    ) {
        adjacentCheckCompleted = completed
        adjacentDurationMilliseconds = cappedMilliseconds(duration)
        self.postBudgetRemaining = postBudgetRemaining
    }

    func recordPost(startedBeforeDeadline: Bool, completedByDeadline: Bool,
                    duration: TimeInterval) {
        postStartedBeforeDeadline = startedBeforeDeadline
        postCompletedByDeadline = completedByDeadline
        postDurationMilliseconds = cappedMilliseconds(duration)
    }

    func aggregate(state: ConditionalLaunchDenialState, consecutive: Int) -> String {
        let ordered = last?.predicates.map { name, value in
            "\(name)_last=\(value) \(name)_ever_true=\(everTrue[name, default: false]) " +
                "\(name)_ever_false=\(everFalse[name, default: false])"
        }.joined(separator: " ") ?? "denial_sample_present=false"
        let comparison = lastCandidateComparison.isEmpty ? "candidate_comparison_present=false" :
            lastCandidateComparison.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let lastDuration = lastSampleDurationMilliseconds.map(String.init) ?? "unknown"
        let firstOffset = firstEligibleOffsetMilliseconds.map(String.init) ?? "unknown"
        let adjacentDuration = adjacentDurationMilliseconds.map(String.init) ?? "unknown"
        let postDuration = postDurationMilliseconds.map(String.init) ?? "unknown"
        let budgetAnchor = budgetAnchorOffsetMilliseconds.map(String.init) ?? "unknown"
        let budgetDeadline = budgetDeadlineOffsetMilliseconds.map(String.init) ?? "unknown"
        let budgetHardCap = budgetHardCapOffsetMilliseconds.map(String.init) ?? "unknown"
        return ordered + " " + comparison + " " + (last?.redactedAggregate ?? "") +
            " denial_consecutive=\(min(consecutive, 10_000)) " +
            "conditional_state=\(state.rawValue) total_samples=\(totalSamples) " +
            "maximum_consecutive_samples=\(maximumConsecutiveSamples) " +
            "shipping_phase=\(lastShippingPhase.rawValue) " +
            "sample_duration_ms=\(lastDuration) " +
            "maximum_sample_duration_ms=\(maximumSampleDurationMilliseconds) " +
            "first_eligible_offset_ms=\(firstOffset) " +
            "allocation_started_before_deadline=\(boolText(allocationStartedBeforeDeadline)) " +
            "allocation_post_budget_remaining=\(boolText(allocationBudgetRemaining)) " +
            "adjacent_check_completed=\(boolText(adjacentCheckCompleted)) " +
            "adjacent_duration_ms=\(adjacentDuration) post_budget_ms=100 " +
            "post_budget_remaining=\(boolText(postBudgetRemaining)) " +
            "post_started_before_deadline=\(boolText(postStartedBeforeDeadline)) " +
            "post_completed_by_deadline=\(boolText(postCompletedByDeadline)) " +
            "post_duration_ms=\(postDuration) " +
            "budget_anchor_offset_ms=\(budgetAnchor) " +
            "budget_deadline_offset_ms=\(budgetDeadline) " +
            "budget_hard_cap_offset_ms=\(budgetHardCap)"
    }

    private func cappedMilliseconds(_ interval: TimeInterval) -> Int? {
        guard interval.isFinite, interval >= 0 else { return nil }
        return min(Int((interval * 1_000).rounded()), 10_000)
    }

    private func boolText(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }
}

private final class PreparedDeniedClick {
    let point: CGPoint
    private var down: CGEvent?
    private var up: CGEvent?

    init?(point: CGPoint) {
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        self.point = point
        self.down = down
        self.up = up
    }

    func discard() {
        down = nil
        up = nil
    }

    func conditionalAction() -> ConditionalDenialPreparedAction {
        ConditionalDenialPreparedAction(
            discard: { [weak self] in self?.discard() },
            postDown: { [weak self] in self?.down?.post(tap: .cghidEventTap) },
            postUp: { [weak self] in self?.up?.post(tap: .cghidEventTap) })
    }
}

private enum ConditionalDenialExecutionDisposition: String {
    case completed
    case preActionExhausted
    case actionDeadlineMiss
}

private final class ConditionalDenialPreparedAction {
    private enum State { case prepared, discarded, posted }
    private var state: State = .prepared
    private let discardAction: () -> Void
    private let postDownAction: () -> Void
    private let postUpAction: () -> Void

    init(discard: @escaping () -> Void, postDown: @escaping () -> Void,
         postUp: @escaping () -> Void) {
        discardAction = discard
        postDownAction = postDown
        postUpAction = postUp
    }

    func discard() {
        guard state == .prepared else { return }
        state = .discarded
        discardAction()
    }

    fileprivate func execute(
        deadline: TimeInterval, authorized: Bool, inputMayHaveOccurred: inout Bool,
        now: () -> TimeInterval
    ) -> ConditionalDenialExecutionDisposition {
        let postStart = now()
        guard state == .prepared, authorized, postStart.isFinite, deadline.isFinite,
              postStart <= deadline else {
            discard()
            return .preActionExhausted
        }
        inputMayHaveOccurred = true
        postDownAction()
        postUpAction()
        state = .posted
        let postEnd = now()
        guard postEnd.isFinite, postEnd <= deadline else { return .actionDeadlineMiss }
        return .completed
    }
}

private func executeConditionalDenialAction(
    _ action: ConditionalDenialPreparedAction,
    deadline: TimeInterval,
    authorized: Bool,
    inputMayHaveOccurred: inout Bool,
    now: () -> TimeInterval
) -> ConditionalDenialExecutionDisposition {
    action.execute(deadline: deadline, authorized: authorized,
                   inputMayHaveOccurred: &inputMayHaveOccurred, now: now)
}

private func conditionalDenialReservationAvailable(
    allocationStart: TimeInterval, deadline: TimeInterval
) -> Bool {
    allocationStart.isFinite && deadline.isFinite && allocationStart <= deadline &&
        allocationStart <= deadline - denialPostBudget
}

private func runConditionalDenialActionSelfTest() -> Bool {
    struct Expected {
        let name: String
        let times: [TimeInterval]
        let deadline: TimeInterval
        let authorized: Bool
        let disposition: ConditionalDenialExecutionDisposition
        let discard: Int
        let down: Int
        let up: Int
        let inputMayHaveOccurred: Bool
    }
    guard !conditionalDenialReservationAvailable(allocationStart: .nan, deadline: 1),
          !conditionalDenialReservationAvailable(allocationStart: 0.901, deadline: 1),
          conditionalDenialReservationAvailable(allocationStart: 0.900, deadline: 1),
          conditionalDenialReservationAvailable(allocationStart: 0.899, deadline: 1) else {
        return false
    }
    let rows = [
        Expected(name: "discarded", times: [0.5], deadline: 1, authorized: false,
                 disposition: .preActionExhausted, discard: 1, down: 0, up: 0,
                 inputMayHaveOccurred: false),
        Expected(name: "nonfinite-start", times: [.nan], deadline: 1, authorized: true,
                 disposition: .preActionExhausted, discard: 1, down: 0, up: 0,
                 inputMayHaveOccurred: false),
        Expected(name: "pre-post-stall", times: [1.001], deadline: 1, authorized: true,
                 disposition: .preActionExhausted, discard: 1, down: 0, up: 0,
                 inputMayHaveOccurred: false),
        Expected(name: "exact-start-end", times: [1, 1], deadline: 1, authorized: true,
                 disposition: .completed, discard: 0, down: 1, up: 1,
                 inputMayHaveOccurred: true),
        Expected(name: "one-tick-overrun", times: [1, 1.001], deadline: 1, authorized: true,
                 disposition: .actionDeadlineMiss, discard: 0, down: 1, up: 1,
                 inputMayHaveOccurred: true),
        Expected(name: "nonfinite-end", times: [0.9, .infinity], deadline: 1, authorized: true,
                 disposition: .actionDeadlineMiss, discard: 0, down: 1, up: 1,
                 inputMayHaveOccurred: true),
    ]
    for row in rows {
        var times = row.times
        var discard = 0, down = 0, up = 0
        var inputMayHaveOccurred = false
        var order: [String] = []
        let action = ConditionalDenialPreparedAction(
            discard: { discard += 1; order.append("discard") },
            postDown: { down += 1; order.append("down") },
            postUp: { up += 1; order.append("up") })
        let result = executeConditionalDenialAction(
            action, deadline: row.deadline, authorized: row.authorized,
            inputMayHaveOccurred: &inputMayHaveOccurred,
            now: { times.removeFirst() })
        action.discard()
        guard result == row.disposition, discard == row.discard, down == row.down, up == row.up,
              inputMayHaveOccurred == row.inputMayHaveOccurred,
              order == (row.down == 1 ? ["down", "up"] : ["discard"]) else {
            FileHandle.standardError.write(Data("conditional action self-test failed: \(row.name)\n".utf8))
            return false
        }
    }
    var secondExecutionInputMayHaveOccurred = false
    var secondExecutionTimes: [TimeInterval] = [0.5, 0.5, 0.5]
    var secondExecutionDown = 0, secondExecutionUp = 0
    let oneShot = ConditionalDenialPreparedAction(
        discard: {}, postDown: { secondExecutionDown += 1 },
        postUp: { secondExecutionUp += 1 })
    guard executeConditionalDenialAction(
        oneShot, deadline: 1, authorized: true,
        inputMayHaveOccurred: &secondExecutionInputMayHaveOccurred,
        now: { secondExecutionTimes.removeFirst() }) == .completed,
          executeConditionalDenialAction(
            oneShot, deadline: 1, authorized: true,
            inputMayHaveOccurred: &secondExecutionInputMayHaveOccurred,
            now: { secondExecutionTimes.removeFirst() }) == .preActionExhausted,
          secondExecutionInputMayHaveOccurred,
          secondExecutionDown == 1, secondExecutionUp == 1 else {
        FileHandle.standardError.write(Data(
            "conditional action self-test failed: one-shot second execution\n".utf8))
        return false
    }
    var budget = ConditionalDenialTimingBudget(samplingStarted: 0)
    guard budget?.effectiveDeadline == 8.1,
          budget?.anchorFirstEligibleSample(recordedStart: 6.1) == .installed,
          budget?.effectiveDeadline == 10.1 else {
        FileHandle.standardError.write(Data("conditional budget self-test failed: initial anchor\n".utf8))
        return false
    }
    let firstDeadlineBits = budget?.effectiveDeadline.bitPattern
    guard budget?.anchorFirstEligibleSample(recordedStart: 7.0) == .unchanged,
          budget?.effectiveDeadline.bitPattern == firstDeadlineBits,
          budget?.contains(10.1) == true,
          budget?.contains(10.1.nextUp) == false else {
        FileHandle.standardError.write(Data("conditional budget self-test failed: immutable boundary\n".utf8))
        return false
    }
    for (anchor, deadline) in [(6.5, 10.5), (8.1, 10.5)] {
        var row = ConditionalDenialTimingBudget(samplingStarted: 0)
        guard row?.anchorFirstEligibleSample(recordedStart: anchor) == .installed,
              row?.effectiveDeadline == deadline else {
            FileHandle.standardError.write(Data("conditional budget self-test failed: cap anchor\n".utf8))
            return false
        }
    }
    for invalidStart in [-1.0, .nan, .infinity, Double.greatestFiniteMagnitude] {
        guard ConditionalDenialTimingBudget(samplingStarted: invalidStart) == nil else {
            FileHandle.standardError.write(Data("conditional budget self-test failed: invalid start\n".utf8))
            return false
        }
    }
    for invalidAnchor in [8.100001, -1.0, .nan, .infinity,
                          Double.greatestFiniteMagnitude] {
        var row = ConditionalDenialTimingBudget(samplingStarted: 0)
        guard row?.anchorFirstEligibleSample(recordedStart: invalidAnchor) == .unavailable,
              row?.effectiveDeadline == 8.1 else {
            FileHandle.standardError.write(Data("conditional budget self-test failed: invalid anchor\n".utf8))
            return false
        }
    }
    return true
}

private final class LaunchPresentationTimingBudget {
    private static let shippingNotBeforeDuration: TimeInterval = 6.1
    private static let postBarrierDuration: TimeInterval = 4.0
    private static let hardCapDuration: TimeInterval = 12.5

    let conditionalSamplingStarted: TimeInterval
    let samplingStarted: TimeInterval
    let notBefore: TimeInterval
    let effectiveDeadline: TimeInterval
    let hardCapDeadline: TimeInterval

    init?(
        conditionalSamplingStarted: TimeInterval,
        presentationSamplingStarted: TimeInterval
    ) {
        guard presentationSamplingStarted.isFinite,
              presentationSamplingStarted >= conditionalSamplingStarted,
              let notBefore = Self.checkedAdd(
                conditionalSamplingStarted, Self.shippingNotBeforeDuration),
              let postBarrierDeadline = Self.checkedAdd(
                notBefore, Self.postBarrierDuration),
              let hardCapDeadline = Self.checkedAdd(
                presentationSamplingStarted, Self.hardCapDuration) else { return nil }
        let effectiveDeadline = min(postBarrierDeadline, hardCapDeadline)
        guard effectiveDeadline.isFinite,
              effectiveDeadline >= presentationSamplingStarted,
              effectiveDeadline >= notBefore,
              effectiveDeadline <= hardCapDeadline else { return nil }
        self.conditionalSamplingStarted = conditionalSamplingStarted
        self.samplingStarted = presentationSamplingStarted
        self.notBefore = notBefore
        self.effectiveDeadline = effectiveDeadline
        self.hardCapDeadline = hardCapDeadline
    }

    func isLive(_ instant: TimeInterval) -> Bool {
        instant.isFinite && instant >= samplingStarted && instant <= effectiveDeadline
    }

    func barrierIsOpen(_ instant: TimeInterval) -> Bool {
        isLive(instant) && instant >= notBefore
    }

    func contains(_ instant: TimeInterval) -> Bool { isLive(instant) }

    var redactedAggregate: String {
        let barrier = checkedOffset(notBefore).map(String.init) ?? "unknown"
        let deadline = checkedOffset(effectiveDeadline).map(String.init) ?? "unknown"
        let hardCap = checkedOffset(hardCapDeadline).map(String.init) ?? "unknown"
        return "presentation_budget_not_before_offset_ms=\(barrier) " +
            "presentation_budget_deadline_offset_ms=\(deadline) " +
            "presentation_budget_hard_cap_offset_ms=\(hardCap)"
    }

    private func checkedOffset(_ instant: TimeInterval?) -> Int? {
        guard let instant, instant.isFinite else { return nil }
        let value = instant - samplingStarted
        guard value.isFinite, value >= -Self.shippingNotBeforeDuration,
              value <= Self.hardCapDuration else { return nil }
        let milliseconds = value * 1_000
        guard milliseconds.isFinite,
              milliseconds >= TimeInterval(Int.min),
              milliseconds <= TimeInterval(Int.max) else { return nil }
        return Int(milliseconds.rounded())
    }

    private static func checkedAdd(
        _ value: TimeInterval, _ duration: TimeInterval
    ) -> TimeInterval? {
        guard value.isFinite, value >= 0, duration.isFinite, duration > 0 else { return nil }
        let result = value + duration
        guard result.isFinite, result > value else { return nil }
        return result
    }
}

private func waitForLaunchPresentationBarrier(
    _ budget: LaunchPresentationTimingBudget
) -> Bool {
    while true {
        let instant = ProcessInfo.processInfo.systemUptime
        guard budget.isLive(instant) else { return false }
        if budget.barrierIsOpen(instant) { return true }
        let remaining = budget.notBefore - instant
        _ = RunLoop.current.run(
            mode: .common,
            before: Date(timeIntervalSinceNow: min(0.02, remaining)))
    }
}

private func runLaunchPresentationTimingBudgetSelfTest() -> Bool {
    guard let initial = LaunchPresentationTimingBudget(
        conditionalSamplingStarted: 0, presentationSamplingStarted: 0),
          initial.notBefore == 6.1, initial.effectiveDeadline == 10.1,
          initial.hardCapDeadline == 12.5,
          !initial.barrierIsOpen(6.099), initial.barrierIsOpen(6.100),
          initial.contains(10.1), !initial.contains(10.1.nextUp) else { return false }
    guard let late = LaunchPresentationTimingBudget(
        conditionalSamplingStarted: 0, presentationSamplingStarted: 7),
          late.barrierIsOpen(7), late.effectiveDeadline == 10.1 else { return false }
    guard let equality = LaunchPresentationTimingBudget(
        conditionalSamplingStarted: 0, presentationSamplingStarted: 10.1),
          equality.barrierIsOpen(10.1),
          LaunchPresentationTimingBudget(
            conditionalSamplingStarted: 0,
            presentationSamplingStarted: 10.1.nextUp) == nil else { return false }
    for (conditional, presentation) in [
        (-1.0, 0.0), (.nan, 0.0), (.infinity, 0.0),
        (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
        (1.0, 0.0), (0.0, .nan), (0.0, .infinity),
        (0.0, Double.greatestFiniteMagnitude),
    ] {
        guard LaunchPresentationTimingBudget(
            conditionalSamplingStarted: conditional,
            presentationSamplingStarted: presentation) == nil else { return false }
    }
    for _ in ["fast", "full", "final", "commit"] {
        guard initial.contains(initial.effectiveDeadline),
              !initial.contains(initial.effectiveDeadline.nextUp) else { return false }
    }
    return true
}

private struct LaunchFullSnapshot {
    let authorityExact: Bool
    let displayAuthorityExact: Bool
    let candidateRetained: Bool
    let containingDisplayCountExact: Bool
    let cgWindowCountExact: Bool
    let cgWindowOnScreen: Bool
    let cgWindowOpaque: Bool
    let postbindRehashExact: Bool
    let binding: LaunchPresentationBinding?

    var publicationExact: Bool {
        displayAuthorityExact && candidateRetained && containingDisplayCountExact && cgWindowCountExact &&
            cgWindowOnScreen && cgWindowOpaque && binding != nil
    }

    var predicates: [(String, Bool)] { [
        ("authority_exact", authorityExact), ("candidate_retained", candidateRetained),
        ("display_authority_exact", displayAuthorityExact),
        ("containing_display_count_exact", containingDisplayCountExact),
        ("cg_window_count_exact", cgWindowCountExact),
        ("cg_window_onscreen", cgWindowOnScreen), ("cg_window_opaque", cgWindowOpaque),
        ("postbind_rehash_exact", postbindRehashExact),
    ] }
}

private final class LaunchPresentationSettlement {
    private enum Phase { case unpublished, transitioning, candidate, bound, failed }
    private enum ResetReason: String {
        case axUnpublished, transitionWindow, focusedWindowLag, typedModeLag,
             geometryPublication, propertyLag, targetObserverInvalidation,
             displayPublication, cgPublication
    }
    private var phase: Phase = .unpublished

    func settle(
        budget: LaunchPresentationTimingBudget, requiredConsecutiveSamples: Int,
        minimumStableDuration: TimeInterval, allowInitialPartialPair: Bool,
        lifecycle: RawDriverToTargetHandoffLedger,
        axInvalidation: TargetAXInvalidationLedger,
        fastSample: () -> LaunchFastObservation,
        fullSnapshot: (_ window: AXUIElement, _ mode: LaunchPresentationMode,
                       _ rectangle: CGRect, _ requireRehash: Bool) -> LaunchFullSnapshot
    ) throws -> LaunchPresentationBinding {
        guard requiredConsecutiveSamples > 1 else {
            throw GateError.failed("launch settlement configuration")
        }
        var candidateWindow: AXUIElement?
        var candidateMode: LaunchPresentationMode?
        var candidateRectangle: CGRect?
        var candidateDisplayID: CGDirectDisplayID?
        var candidateCGWindowID: CGWindowID?
        var candidateFirstExact: TimeInterval?
        var consecutiveSamples = 0
        var maximumConsecutiveSamples = 0
        var maximumCandidateDuration: TimeInterval = 0
        var totalSamples = 0
        var lastReset = ResetReason.axUnpublished
        var lastPredicates: [(String, Bool)] = []
        var everTrue: [String: Bool] = [:]
        var everFalse: [String: Bool] = [:]
        var mayAwaitPairComplement = allowInitialPartialPair

        func record(_ predicates: [(String, Bool)]) {
            lastPredicates = predicates
            for (name, value) in predicates {
                everTrue[name, default: false] = everTrue[name, default: false] || value
                everFalse[name, default: false] = everFalse[name, default: false] || !value
            }
        }
        func reset(_ reason: ResetReason) {
            phase = reason == .axUnpublished ? .unpublished : .transitioning
            lastReset = reason
            candidateWindow = nil
            candidateMode = nil
            candidateRectangle = nil
            candidateDisplayID = nil
            candidateCGWindowID = nil
            candidateFirstExact = nil
            consecutiveSamples = 0
        }
        func diagnostics() -> String {
            let aggregate = lastPredicates.map { name, value in
                "\(name)_last=\(value) \(name)_ever_true=\(everTrue[name, default: false]) " +
                    "\(name)_ever_false=\(everFalse[name, default: false])"
            }.joined(separator: " ")
            return "launch presentation phase=\(phase) reset_reason=\(lastReset.rawValue) " +
                "total_samples=\(totalSamples) " +
                "maximum_candidate_consecutive=\(maximumConsecutiveSamples) " +
                "maximum_candidate_duration_ms=\(Int(maximumCandidateDuration * 1_000)) " +
                aggregate + " " + budget.redactedAggregate
        }
        func requireBudget(_ instant: TimeInterval) throws {
            guard budget.contains(instant) else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "launch_presentation_timeout")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
        }
        repeat {
            guard let lifecycleLease = try lifecycle.beginLaunchSettlementSample() else {
                if mayAwaitPairComplement {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                    continue
                }
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement("presentation_missing_lease")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            if mayAwaitPairComplement, lifecycleLease.authority == .zeroEventSurface {
                _ = try lifecycle.finishLaunchSettlementSample(lease: lifecycleLease)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            mayAwaitPairComplement = false
            let axSequence = try axInvalidation.beginSample()
            let observed = fastSample()
            let workspaceUnchanged = try lifecycle.finishLaunchSettlementSample(
                lease: lifecycleLease)
            let axUnchanged = try axInvalidation.finishSample(sequence: axSequence)
            let fastSampleCompleted = ProcessInfo.processInfo.systemUptime
            totalSamples += 1
            record(observed.predicates)
            guard observed.authorityExact else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement("launch_authority_loss")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard observed.finishedLaunching, observed.active, observed.frontmostExact else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_target_authority_loss")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard workspaceUnchanged else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_workspace_changed")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard axUnchanged else {
                reset(.targetObserverInvalidation)
                continue
            }
            guard observed.eligible, let window = observed.window,
                  let mode = observed.mode, let rectangle = observed.rectangle else {
                if !observed.windowCountExact { reset(.axUnpublished) }
                else if !observed.roleExact || !observed.subroleStandard {
                    reset(.transitionWindow)
                } else if !observed.focusedWindowExact { reset(.focusedWindowLag) }
                else if !observed.typedModePresent { reset(.typedModeLag) }
                else if !observed.finiteRectangle { reset(.geometryPublication) }
                else { reset(.propertyLag) }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            try requireBudget(fastSampleCompleted)
            try axInvalidation.watch(window: window)
            guard let candidateLifecycleLease = try lifecycle.beginLaunchSettlementSample() else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement("presentation_missing_lease")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            let candidateAXSequence = try axInvalidation.beginSample()
            let completeSnapshot = fullSnapshot(window, mode, rectangle, false)
            let completeWorkspaceUnchanged = try lifecycle.finishLaunchSettlementSample(
                lease: candidateLifecycleLease)
            let completeAXUnchanged = try axInvalidation.finishSample(
                sequence: candidateAXSequence)
            let completeSnapshotCompleted = ProcessInfo.processInfo.systemUptime
            try requireBudget(completeSnapshotCompleted)
            record(completeSnapshot.predicates)
            guard completeSnapshot.authorityExact else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement("launch_snapshot_authority_loss")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard completeSnapshot.displayAuthorityExact else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_display_authority_loss")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard completeWorkspaceUnchanged else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_workspace_changed")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard completeAXUnchanged else {
                reset(.targetObserverInvalidation)
                continue
            }
            guard completeSnapshot.publicationExact,
                  let completeBinding = completeSnapshot.binding else {
                reset(completeSnapshot.containingDisplayCountExact ?
                    .cgPublication : .displayPublication)
                continue
            }
            let sameCandidate = candidateWindow.map({ CFEqual($0, window) }) == true &&
                candidateMode == mode && candidateRectangle == rectangle &&
                candidateDisplayID == completeBinding.displayID &&
                candidateCGWindowID == completeBinding.cgWindowID
            if !sameCandidate {
                candidateWindow = window
                candidateMode = mode
                candidateRectangle = rectangle
                candidateDisplayID = completeBinding.displayID
                candidateCGWindowID = completeBinding.cgWindowID
                candidateFirstExact = ProcessInfo.processInfo.systemUptime
                consecutiveSamples = 0
            }
            phase = .candidate
            consecutiveSamples += 1
            maximumConsecutiveSamples = max(maximumConsecutiveSamples, consecutiveSamples)
            let stabilityDecisionAt = ProcessInfo.processInfo.systemUptime
            try requireBudget(stabilityDecisionAt)
            if let first = candidateFirstExact {
                maximumCandidateDuration = max(
                    maximumCandidateDuration, stabilityDecisionAt - first)
            }
            guard consecutiveSamples >= requiredConsecutiveSamples,
                  let first = candidateFirstExact,
                  stabilityDecisionAt - first >= minimumStableDuration else {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }

            guard let fullLifecycleLease = try lifecycle.beginLaunchSettlementSample() else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement("presentation_missing_lease")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            let fullAXSequence = try axInvalidation.beginSample()
            let finalRehashStarted = ProcessInfo.processInfo.systemUptime
            try requireBudget(finalRehashStarted)
            let snapshot = fullSnapshot(window, mode, rectangle, true)
            let finalWorkspaceUnchanged = try lifecycle.finishLaunchSettlementSample(
                lease: fullLifecycleLease)
            let fullAXUnchanged = try axInvalidation.finishSample(sequence: fullAXSequence)
            let finalRehashCompleted = ProcessInfo.processInfo.systemUptime
            try requireBudget(finalRehashCompleted)
            record(snapshot.predicates)
            guard snapshot.authorityExact, snapshot.postbindRehashExact else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement("launch_snapshot_authority_loss")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard snapshot.displayAuthorityExact else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_display_authority_loss")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard finalWorkspaceUnchanged else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_workspace_changed")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard fullAXUnchanged else {
                reset(.targetObserverInvalidation)
                continue
            }
            guard snapshot.publicationExact, let binding = snapshot.binding else {
                reset(snapshot.containingDisplayCountExact ? .cgPublication : .displayPublication)
                continue
            }
            guard candidateDisplayID == binding.displayID,
                  candidateCGWindowID == binding.cgWindowID,
                  candidateMode == binding.mode,
                  candidateRectangle == binding.rectangle,
                  candidateWindow.map({ CFEqual($0, binding.axWindow) }) == true else {
                reset(.cgPublication)
                continue
            }
            guard try lifecycle.finishLaunchSettlementSample(
                lease: fullLifecycleLease) else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_workspace_changed")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            guard try axInvalidation.finishSample(sequence: fullAXSequence) else {
                reset(.targetObserverInvalidation)
                continue
            }
            let finalClosureCompleted = ProcessInfo.processInfo.systemUptime
            try requireBudget(finalClosureCompleted)
            let commitStarted = ProcessInfo.processInfo.systemUptime
            try requireBudget(commitStarted)
            guard try lifecycle.commitLaunchPresentation(
                lease: fullLifecycleLease) else {
                phase = .failed
                let terminal = lifecycle.terminateLaunchSettlement(
                    "presentation_commit_changed")
                throw GateError.failed("\(diagnostics()) \(terminal)")
            }
            let commitCompleted = ProcessInfo.processInfo.systemUptime
            try requireBudget(commitCompleted)
            try axInvalidation.markBound(sequence: fullAXSequence)
            phase = .bound
            return binding
        } while ProcessInfo.processInfo.systemUptime < budget.effectiveDeadline

        phase = .failed
        let terminal = lifecycle.terminateLaunchSettlement("launch_presentation_timeout")
        throw GateError.failed("\(diagnostics()) \(terminal)")
    }
}

private struct FinderSurfaceObservation {
    let finderIdentity: Bool
    let finderActive: Bool
    let finderFrontmost: Bool
    let elysiumIdentity: Bool
    let elysiumInactive: Bool
    let axWindowIdentity: Bool
    let axModeExact: Bool
    let axGeometryExact: Bool
    let boundWindowPresent: Bool
    let boundWindowPID: Bool
    let boundWindowID: Bool
    let boundWindowLayer: Bool
    let boundWindowRectangle: Bool
    let boundWindowOnScreenPresent: Bool
    let boundWindowOnScreenExpected: Bool
    let boundWindowOpaque: Bool

    var authorityExact: Bool {
        finderIdentity && finderActive && finderFrontmost && elysiumIdentity && elysiumInactive &&
            axWindowIdentity && axModeExact && axGeometryExact && boundWindowPresent &&
            boundWindowPID && boundWindowID && boundWindowLayer && boundWindowRectangle &&
            boundWindowOnScreenPresent
    }

    var publicationExact: Bool {
        boundWindowOnScreenExpected && boundWindowOpaque
    }

    var aggregate: String {
        [
            ("finder_identity", finderIdentity), ("finder_active", finderActive),
            ("finder_frontmost", finderFrontmost), ("pebble_identity", elysiumIdentity),
            ("pebble_inactive", elysiumInactive), ("ax_window_identity", axWindowIdentity),
            ("ax_mode_exact", axModeExact), ("ax_geometry_exact", axGeometryExact),
            ("bound_window_present", boundWindowPresent),
            ("bound_window_pid", boundWindowPID), ("bound_window_id", boundWindowID),
            ("bound_window_layer", boundWindowLayer),
            ("bound_window_rectangle", boundWindowRectangle),
            ("bound_window_onscreen_present", boundWindowOnScreenPresent),
            ("bound_window_onscreen_expected", boundWindowOnScreenExpected),
            ("bound_window_opaque", boundWindowOpaque),
        ].map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}

private final class FinderSurfaceSettlement {
    private enum Phase { case pending, settled, failed }
    private var phase: Phase = .pending

    func settle(
        mode: LaunchPresentationMode, timeout: TimeInterval,
        minimumStableDuration: TimeInterval, requiredConsecutiveSamples: Int,
        ledger: RawDriverToTargetHandoffLedger,
        sample: () -> FinderSurfaceObservation
    ) throws {
        guard phase == .pending, requiredConsecutiveSamples > 1 else {
            phase = .failed
            throw GateError.failed("finder-surface settlement configuration")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var totalSamples = 0
        var consecutiveSamples = 0
        var maximumConsecutiveSamples = 0
        var firstExactSample: TimeInterval?
        var lastSample: FinderSurfaceObservation?
        repeat {
            let sequence = try ledger.beginFinderSurfaceSample()
            let current = sample()
            try ledger.finishFinderSurfaceSample(sequence: sequence)
            totalSamples += 1
            lastSample = current
            guard current.authorityExact else {
                phase = .failed
                let handoff = ledger.terminateFinderSurface("finder_surface_identity_or_authority")
                throw GateError.failed(
                    "finder-surface settlement mode=\(mode.rawValue) total_samples=\(totalSamples) " +
                    "maximum_consecutive_samples=\(maximumConsecutiveSamples) " +
                    "\(current.aggregate) \(handoff)")
            }
            try ledger.requireFinderSurfaceFinal()
            let now = ProcessInfo.processInfo.systemUptime
            if current.publicationExact {
                if firstExactSample == nil { firstExactSample = now }
                consecutiveSamples += 1
                maximumConsecutiveSamples = max(maximumConsecutiveSamples, consecutiveSamples)
                if consecutiveSamples >= requiredConsecutiveSamples,
                   let firstExactSample, now - firstExactSample >= minimumStableDuration {
                    try ledger.requireFinderSurfaceFinal()
                    phase = .settled
                    return
                }
            } else {
                consecutiveSamples = 0
                firstExactSample = nil
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        phase = .failed
        let handoff = ledger.terminateFinderSurface("finder_surface_timeout")
        throw GateError.failed(
            "finder-surface settlement mode=\(mode.rawValue) total_samples=\(totalSamples) " +
            "maximum_consecutive_samples=\(maximumConsecutiveSamples) " +
            "\(lastSample?.aggregate ?? "sample_present=false") \(handoff)")
    }

    func requireSettled() throws {
        guard phase == .settled else {
            phase = .failed
            throw GateError.failed("finder-surface not settled")
        }
    }
}

private final class ReadyEpoch {
    private enum Phase { case settling, preserved, ready, failed }
    private var phase: Phase = .settling

    func settle(timeout: TimeInterval, minimumStableDuration: TimeInterval,
                requiredConsecutiveSamples: Int, sample: () throws -> SettlingSample) throws {
        guard phase == .settling, requiredConsecutiveSamples > 1 else {
            throw GateError.failed("settling phase configuration")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var consecutiveSamples = 0
        var maximumConsecutiveSamples = 0
        var totalSamples = 0
        var firstExactSample: TimeInterval?
        var lastSample: SettlingSample?
        var everTrue: [String: Bool] = [:]
        var everFalse: [String: Bool] = [:]
        repeat {
            let now = ProcessInfo.processInfo.systemUptime
            let current = try sample()
            totalSamples += 1
            lastSample = current
            for (name, value) in current.predicates {
                everTrue[name, default: false] = everTrue[name, default: false] || value
                everFalse[name, default: false] = everFalse[name, default: false] || !value
            }
            if current.exact {
                if firstExactSample == nil { firstExactSample = now }
                consecutiveSamples += 1
                maximumConsecutiveSamples = max(maximumConsecutiveSamples, consecutiveSamples)
                if consecutiveSamples >= requiredConsecutiveSamples,
                   let firstExactSample, now - firstExactSample >= minimumStableDuration {
                    return
                }
            } else {
                consecutiveSamples = 0
                firstExactSample = nil
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        phase = .failed
        let predicateAggregate = lastSample?.predicates.map { name, value in
            "\(name)_last=\(value) \(name)_ever_true=\(everTrue[name, default: false]) " +
                "\(name)_ever_false=\(everFalse[name, default: false])"
        }.joined(separator: " ") ?? "sample_present=false"
        throw GateError.failed(
            "initial active-surface settling total_samples=\(totalSamples) " +
            "maximum_consecutive_samples=\(maximumConsecutiveSamples) " + predicateAggregate + " " +
            (lastSample?.fieldAggregate ?? "field_sample_present=false"))
    }

    func preserve(_ exact: Bool) throws {
        guard phase == .settling, exact else {
            phase = .failed
            throw GateError.failed("pre-repair preservation")
        }
        phase = .preserved
    }

    func enterReady() throws {
        guard phase == .preserved else {
            phase = .failed
            throw GateError.failed("ready epoch transition")
        }
        phase = .ready
    }

    func assertReady(_ exact: Bool, failure: String) throws {
        guard phase == .ready, exact else {
            phase = .failed
            throw GateError.failed(failure)
        }
    }

    /// Source-contract fixture: the second sample must never be observed after the first mismatch.
    static func firstPostReadyMismatchIsTerminal(_ samples: [Bool]) -> Bool {
        guard samples.count >= 2 else { return false }
        var observed = 0
        for sample in samples {
            observed += 1
            if !sample { return observed == 1 }
        }
        return false
    }
}

private func waitFailFast(_ seconds: TimeInterval,
                          until sample: () throws -> Bool) throws -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if try sample() { return true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}

private func postMouseOnce(_ id: String, _ point: CGPoint, ledger: OneShotActionLedger,
                           finalCheck: () throws -> Void) throws {
    try ledger.perform(id) {
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw GateError.failed("event-post prerequisite \(id)")
        }
        try finalCheck()
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}

private func postKeyOnce(_ id: String, _ code: CGKeyCode,
                         flags: CGEventFlags = [], ledger: OneShotActionLedger,
                         finalCheck: () throws -> Void) throws {
    try ledger.perform(id) {
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw GateError.failed("event-post prerequisite \(id)")
        }
        down.flags = flags; up.flags = flags
        try finalCheck()
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}

private func postRepeatingKeyOnce(_ id: String, _ code: CGKeyCode,
                                  ledger: OneShotActionLedger,
                                  finalCheck: () throws -> Void) throws {
    try ledger.perform(id) {
        guard CGPreflightPostEventAccess(),
              let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw GateError.failed("event-post prerequisite \(id)")
        }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        try finalCheck()
        event.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private func activateOnce(_ id: String, _ application: NSRunningApplication,
                          ledger: OneShotActionLedger,
                          finalCheck: () throws -> Void) throws {
    try ledger.perform(id) {
        try finalCheck()
        guard application.activate(options: []) else {
            throw GateError.failed("activation rejected \(id)")
        }
    }
}

private func setFocusedOnce(_ id: String, _ element: AXUIElement,
                            ledger: OneShotActionLedger,
                            finalCheck: () throws -> Void) throws {
    try ledger.perform(id) {
        try finalCheck()
        guard AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw GateError.failed("Accessibility focus rejected \(id)")
        }
    }
}

private final class LaunchCompletionState {
    private let lock = NSLock()
    private var callbackCount = 0
    private var application: NSRunningApplication?
    private var error: Error?

    func receive(application: NSRunningApplication?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        callbackCount += 1
        if callbackCount == 1 {
            self.application = application
            self.error = error
        }
    }

    func isComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }; return callbackCount > 0
    }

    func exactApplication() throws -> NSRunningApplication {
        lock.lock(); defer { lock.unlock() }
        guard callbackCount == 1, error == nil, let application else {
            throw GateError.failed("launch completion authority")
        }
        return application
    }
}

private struct Manifest {
    let values: [String: String]
    init(url: URL) throws {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var result: [String: String] = [:]
        for line in lines {
            guard let split = line.firstIndex(of: "=") else { throw GateError.failed("manifest") }
            result[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        values = result
    }
    subscript(_ key: String) -> String { values[key] ?? "" }
}

private final class Cleanup {
    var application: NSRunningApplication?
    var expectedPID: pid_t = 0
    var expectedExecutable = ""
    var cleanupFailed = false
    var cleanupFailureReason = ""
    var closeObservers: (() -> Void)?
    private var didRun = false

    func run() {
        guard !didRun else { return }
        didRun = true
        closeObservers?()
        closeObservers = nil
        if let application, application.processIdentifier == expectedPID && !application.isTerminated {
            guard runningCommand(expectedPID) == expectedExecutable else {
                cleanupFailed = true
                cleanupFailureReason = "initial-process-identity"
                return
            }
            application.terminate()
            _ = wait(5) { application.isTerminated && kill(self.expectedPID, 0) != 0 }
            if kill(expectedPID, 0) == 0 {
                if runningCommand(expectedPID) != expectedExecutable {
                    self.application = nil
                    return
                }
                application.forceTerminate()
                _ = wait(5) { kill(self.expectedPID, 0) != 0 }
            }
            if kill(expectedPID, 0) == 0 {
                if runningCommand(expectedPID) == expectedExecutable {
                    cleanupFailed = true
                    cleanupFailureReason = "process-still-running"
                }
            }
        }
        application = nil
    }
}

private struct RawDriverForegroundSample: Equatable {
    let processStart: ProcessStartIdentity
    let command: String
    let executableIdentity: RegularFileIdentity
    let executableHash: String
    let windowRectangle: CGRect
    let cgWindowID: CGWindowID
    let consoleUser: String
    let displayID: CGDirectDisplayID
    let cgIdentity: RawDriverCGWindowIdentity
    let appKitActive: Bool
    let runningApplicationActive: Bool
}

private let rawDriverWindowIdentifierPrefix = "elysium-integration-driver-window:"

private func randomRawDriverWindowIdentifier() -> String? {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        return nil
    }
    return rawDriverWindowIdentifierPrefix + bytes.map { String(format: "%02x", $0) }.joined()
}

private struct RawDriverDisplayBinding: Equatable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let displayBounds: CGRect
}

private struct RawDriverDisplayTopology: Equatable {
    let online: [CGDirectDisplayID]
    let bounds: [CGRect]
    let active: [Bool]
    let awake: [Bool]
    let screenFrames: [CGRect?]

    static func capture(containing displayID: CGDirectDisplayID) -> RawDriverDisplayTopology? {
        let observation = onlineDisplayObservation()
        guard observation.querySuccess, !observation.displays.isEmpty,
              observation.displays.filter({ $0 == displayID }).count == 1 else { return nil }
        let bounds = observation.displays.map(CGDisplayBounds)
        let awake = observation.displays.map { CGDisplayIsAsleep($0) == 0 }
        let frames = observation.displays.map { id -> CGRect? in
            let matches = NSScreen.screens.filter {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == id
            }
            return matches.count == 1 ? matches[0].frame : nil
        }
        // NSScreen is AppKit's active display topology. CGGetActiveDisplayList/CGDisplayIsActive
        // are empirically empty/false for this raw CLI process despite the same online display
        // owning a live NSScreen and the window-server surface.
        let active = frames.map { $0 != nil }
        guard bounds.allSatisfy({ $0.origin.x.isFinite && $0.origin.y.isFinite &&
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }),
              active.count == observation.displays.count, awake.count == observation.displays.count,
              active[observation.displays.firstIndex(of: displayID)!],
              frames[observation.displays.firstIndex(of: displayID)!] != nil else { return nil }
        return RawDriverDisplayTopology(
            online: observation.displays, bounds: bounds, active: active,
            awake: awake, screenFrames: frames)
    }
}

private struct ExactCGFloat: Equatable {
    let value: CGFloat
    private let bits: UInt64

    init?(_ value: CGFloat) {
        guard value.isFinite else { return nil }
        self.value = value
        bits = Double(value).bitPattern
    }
}

private struct ExactRectangle: Equatable {
    let rectangle: CGRect
    private let x: ExactCGFloat
    private let y: ExactCGFloat
    private let width: ExactCGFloat
    private let height: ExactCGFloat

    init?(_ rectangle: CGRect) {
        guard let x = ExactCGFloat(rectangle.origin.x),
              let y = ExactCGFloat(rectangle.origin.y),
              let width = ExactCGFloat(rectangle.width),
              let height = ExactCGFloat(rectangle.height),
              width.value > 0, height.value > 0 else { return nil }
        self.rectangle = rectangle
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

private struct CompositorInsetIdentity: Equatable {
    let left: ExactCGFloat
    let top: ExactCGFloat
    let right: ExactCGFloat
    let bottom: ExactCGFloat
}

private struct RawDriverCGWindowIdentity: Equatable {
    let pid: pid_t
    let number: CGWindowID
    let layer: Int
    let owner: String
    let title: String
    let bounds: ExactRectangle
    let localCGFrame: ExactRectangle
    let display: RawDriverDisplayBinding
    let insets: CompositorInsetIdentity
    let onScreen: Bool
    let alpha: ExactCGFloat
}

private struct RawDriverLocalWindowBinding {
    let objectIdentity: ObjectIdentifier
    let number: Int
    let title: String
    let identifier: String
    let styleMask: NSWindow.StyleMask
    let level: NSWindow.Level
    let alpha: CGFloat
    let ignoresMouse: Bool
    let frame: CGRect
    let display: RawDriverDisplayBinding
    let displayTopology: RawDriverDisplayTopology
    let cgIdentity: RawDriverCGWindowIdentity
}

private enum RawDriverAXGeometry {
    case absent
    case exact(CGRect)
    case invalid
}

private func rawDriverDisplayBinding(for window: NSWindow) -> RawDriverDisplayBinding? {
    guard let screen = window.screen,
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
    }
    let displayID = CGDirectDisplayID(number.uint32Value)
    let displayBounds = CGDisplayBounds(displayID)
    guard displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite,
          displayBounds.width.isFinite, displayBounds.height.isFinite,
          displayBounds.width > 0, displayBounds.height > 0 else { return nil }
    return RawDriverDisplayBinding(
        displayID: displayID, screenFrame: screen.frame, displayBounds: displayBounds)
}

private func rawDriverCGRectangle(
    appKitFrame: CGRect, display: RawDriverDisplayBinding
) -> CGRect? {
    guard appKitFrame.origin.x.isFinite, appKitFrame.origin.y.isFinite,
          appKitFrame.width.isFinite, appKitFrame.height.isFinite,
          appKitFrame.width > 0, appKitFrame.height > 0,
          display.screenFrame.contains(appKitFrame) else { return nil }
    let x = display.displayBounds.minX + (appKitFrame.minX - display.screenFrame.minX)
    let y = display.displayBounds.minY + (display.screenFrame.maxY - appKitFrame.maxY)
    let rectangle = CGRect(x: x, y: y, width: appKitFrame.width, height: appKitFrame.height)
    guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
          rectangle.width.isFinite, rectangle.height.isFinite else { return nil }
    return rectangle
}

private func containedCompositorInsets(
    local: CGRect, compositor: CGRect
) -> CompositorInsetIdentity? {
    guard let localExact = ExactRectangle(local), let compositorExact = ExactRectangle(compositor),
          localExact.rectangle.minX <= compositorExact.rectangle.minX,
          localExact.rectangle.minY <= compositorExact.rectangle.minY,
          localExact.rectangle.maxX >= compositorExact.rectangle.maxX,
          localExact.rectangle.maxY >= compositorExact.rectangle.maxY,
          let left = ExactCGFloat(compositor.minX - local.minX),
          let top = ExactCGFloat(compositor.minY - local.minY),
          let right = ExactCGFloat(local.maxX - compositor.maxX),
          let bottom = ExactCGFloat(local.maxY - compositor.maxY),
          left.value >= 0, top.value >= 0, right.value >= 0, bottom.value >= 0 else {
        return nil
    }
    return CompositorInsetIdentity(left: left, top: top, right: right, bottom: bottom)
}

private func exactInteger<T: FixedWidthInteger>(_ value: Any?, as: T.Type) -> T? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          let exact = T(exactly: double) else { return nil }
    return exact
}

private func captureRawDriverCGIdentity(
    pid: pid_t, number: Int, title: String, localCGFrame: CGRect,
    display: RawDriverDisplayBinding
) -> RawDriverCGWindowIdentity? {
    guard number > 0, let exactNumber = UInt32(exactly: number),
          let localExact = ExactRectangle(localCGFrame),
          display.displayBounds.contains(localCGFrame),
          let rows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    let numbered = rows.filter {
        exactInteger($0[kCGWindowNumber as String], as: UInt32.self) == exactNumber
    }
    guard numbered.count == 1 else { return nil }
    let row = numbered[0]
    guard exactInteger(row[kCGWindowOwnerPID as String], as: Int32.self) == pid,
          exactInteger(row[kCGWindowLayer as String], as: Int.self) == 0,
          let owner = row[kCGWindowOwnerName as String] as? String,
          owner == ProcessInfo.processInfo.processName,
          let candidateTitle = row[kCGWindowName as String] as? String, candidateTitle == title,
          let onScreenNumber = row[kCGWindowIsOnscreen as String] as? NSNumber,
          CFGetTypeID(onScreenNumber) == CFBooleanGetTypeID(), onScreenNumber.boolValue,
          let alphaNumber = row[kCGWindowAlpha as String] as? NSNumber,
          let alpha = ExactCGFloat(CGFloat(alphaNumber.doubleValue)), alpha.value == 1,
          let boundsValue = row[kCGWindowBounds as String],
          let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
          let exactBounds = ExactRectangle(bounds), display.displayBounds.contains(bounds),
          let insets = containedCompositorInsets(local: localCGFrame, compositor: bounds) else { return nil }
    return RawDriverCGWindowIdentity(
        pid: pid, number: exactNumber, layer: 0, owner: owner, title: candidateTitle,
        bounds: exactBounds, localCGFrame: localExact, display: display, insets: insets,
        onScreen: true, alpha: alpha)
}

private func captureRawDriverLocalWindowBinding(_ window: NSWindow) -> RawDriverLocalWindowBinding? {
    let identifier = window.accessibilityIdentifier()
    guard window.windowNumber > 0,
          identifier.hasPrefix(rawDriverWindowIdentifierPrefix),
          identifier.count == rawDriverWindowIdentifierPrefix.count + 64,
          identifier.dropFirst(rawDriverWindowIdentifierPrefix.count).allSatisfy({
              $0.isNumber || ("a"..."f").contains(String($0))
          }),
          let display = rawDriverDisplayBinding(for: window),
          let displayTopology = RawDriverDisplayTopology.capture(containing: display.displayID),
          let localCGFrame = rawDriverCGRectangle(appKitFrame: window.frame, display: display),
          let cgIdentity = captureRawDriverCGIdentity(
            pid: getpid(), number: window.windowNumber, title: window.title,
            localCGFrame: localCGFrame, display: display) else { return nil }
    return RawDriverLocalWindowBinding(
        objectIdentity: ObjectIdentifier(window), number: window.windowNumber,
        title: window.title, identifier: identifier, styleMask: window.styleMask,
        level: window.level, alpha: window.alphaValue,
        ignoresMouse: window.ignoresMouseEvents, frame: window.frame, display: display,
        displayTopology: displayTopology,
        cgIdentity: cgIdentity)
}

private func rawDriverAXGeometry(_ window: AXUIElement) -> RawDriverAXGeometry {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    let positionError = AXUIElementCopyAttributeValue(
        window, kAXPositionAttribute as CFString, &rawPosition)
    let sizeError = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize)
    let absent: Set<AXError> = [.noValue, .attributeUnsupported]
    if absent.contains(positionError), absent.contains(sizeError) { return .absent }
    guard positionError == .success, sizeError == .success,
          let rawPosition, let rawSize,
          CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          CFGetTypeID(rawSize) == AXValueGetTypeID() else { return .invalid }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
          AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return .invalid }
    let rectangle = CGRect(origin: point, size: size)
    guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
          rectangle.width.isFinite, rectangle.height.isFinite,
          rectangle.width > 0, rectangle.height > 0 else { return .invalid }
    return .exact(rectangle)
}

private func validateRawDriverLocalCGBinding(
    window: NSWindow, retained: RawDriverLocalWindowBinding
) -> RawDriverCGWindowIdentity? {
    guard ObjectIdentifier(window) == retained.objectIdentity,
          NSApplication.shared.windows.count == 1,
          window.windowNumber == retained.number, window.title == retained.title,
          window.accessibilityIdentifier() == retained.identifier,
          window.styleMask == retained.styleMask, window.level == retained.level,
          window.alphaValue == retained.alpha, window.ignoresMouseEvents == retained.ignoresMouse,
          window.frame == retained.frame,
          rawDriverDisplayBinding(for: window) == retained.display,
          RawDriverDisplayTopology.capture(containing: retained.display.displayID) ==
            retained.displayTopology,
          let localCGFrame = rawDriverCGRectangle(
            appKitFrame: retained.frame, display: retained.display),
          let identity = captureRawDriverCGIdentity(
            pid: getpid(), number: retained.number, title: retained.title,
            localCGFrame: localCGFrame, display: retained.display),
          identity == retained.cgIdentity else { return nil }
    return identity
}

private struct RawForegroundPredecessor {
    let application: NSRunningApplication
    let pid: pid_t
    let bundleIdentifier: String?
    let bundle: URL?
    let executable: URL
    let processStart: ProcessStartIdentity
    let executableIdentity: RegularFileIdentity
    let executableHash: String

    static func capture(_ application: NSRunningApplication) -> RawForegroundPredecessor? {
        let pid = application.processIdentifier
        guard pid > 0, pid != getpid(), !application.isTerminated,
              let executable = application.executableURL.map({ canonicalURL($0.path) }),
              let processStart = ProcessStartIdentity.capture(pid),
              let executableIdentity = regularFileIdentity(executable),
              let executableHash = try? hash(executable) else { return nil }
        return RawForegroundPredecessor(
            application: application, pid: pid,
            bundleIdentifier: application.bundleIdentifier,
            bundle: application.bundleURL.map({ canonicalURL($0.path) }),
            executable: executable, processStart: processStart,
            executableIdentity: executableIdentity, executableHash: executableHash)
    }

    func matches(_ candidate: NSRunningApplication) -> Bool {
        candidate.isEqual(application) && candidate.processIdentifier == pid &&
            !candidate.isTerminated && candidate.bundleIdentifier == bundleIdentifier &&
            candidate.bundleURL.map({ canonicalURL($0.path) }) == bundle &&
            candidate.executableURL.map({ canonicalURL($0.path) }) == executable &&
            ProcessStartIdentity.capture(pid) == processStart &&
            regularFileIdentity(executable) == executableIdentity &&
            (try? hash(executable)) == executableHash
    }
}

private final class RawDriverActiveLifecycleLedger {
    private enum Phase { case installing, prestateBound, actionConsumed, poststateCandidate, stableCommitted, frozen, failed }
    private let lock = NSLock()
    private let generation: UInt64 = 1
    private let predecessor: RawForegroundPredecessor
    private var phase: Phase = .installing
    private var workspaceIngress = 0
    private var workspaceTokens: [NSObjectProtocol] = []
    private var actionConsumed = false
    private var applicationFrontmostSucceeded = false
    private var successfulWindowWrites: Set<String> = []
    private var terminalReason: String?

    init(predecessor: RawForegroundPredecessor) {
        self.predecessor = predecessor
    }

    func install() throws {
        lock.lock()
        guard phase == .installing, workspaceTokens.isEmpty else {
            lock.unlock(); throw GateError.failed("driver foreground ledger install")
        }
        let installedGeneration = generation
        let activate = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared, queue: .main
        ) { [weak self] notification in
            self?.recordWorkspace(notification, activation: true, generation: installedGeneration)
        }
        let deactivate = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: NSWorkspace.shared, queue: .main
        ) { [weak self] notification in
            self?.recordWorkspace(notification, activation: false, generation: installedGeneration)
        }
        workspaceTokens = [activate, deactivate]
        phase = .prestateBound
        lock.unlock()
    }

    func armCompositeAction() throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .prestateBound, workspaceIngress == 0, !actionConsumed else {
            failLocked("driver_foreground_arm"); throw GateError.failed(diagnosticsLocked())
        }
        actionConsumed = true
        phase = .actionConsumed
    }

    func requireBeforeApplicationFrontmostSet() throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .actionConsumed, actionConsumed,
              !applicationFrontmostSucceeded, successfulWindowWrites.isEmpty,
              workspaceIngress <= 1,
              terminalReason == nil else {
            failLocked("driver_foreground_set_order"); throw GateError.failed(diagnosticsLocked())
        }
    }

    func recordApplicationFrontmostResult(success: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .actionConsumed, !applicationFrontmostSucceeded,
              terminalReason == nil, success else {
            failLocked("driver_foreground_set_result"); throw GateError.failed(diagnosticsLocked())
        }
        applicationFrontmostSucceeded = true
        phase = .poststateCandidate
    }

    func requirePoststateCandidate() throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .poststateCandidate, applicationFrontmostSucceeded,
              workspaceIngress <= 1, terminalReason == nil else {
            failLocked("driver_foreground_pair_boundary")
            throw GateError.failed(diagnosticsLocked())
        }
    }

    func recordWindowWrite(_ attribute: CFString) throws {
        let name = attribute as String
        lock.lock(); defer { lock.unlock() }
        guard phase == .poststateCandidate, applicationFrontmostSucceeded,
              workspaceIngress <= 1, terminalReason == nil,
              (name == (kAXMainAttribute as String) ||
               name == (kAXFocusedAttribute as String)),
              !successfulWindowWrites.contains(name) else {
            failLocked("driver_foreground_window_write")
            throw GateError.failed(diagnosticsLocked())
        }
        successfulWindowWrites.insert(name)
    }

    func commitStable() throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .poststateCandidate, applicationFrontmostSucceeded,
              workspaceIngress <= 1, terminalReason == nil else {
            failLocked("driver_foreground_stable_commit")
            throw GateError.failed(diagnosticsLocked())
        }
        phase = .stableCommitted
    }

    func closeAndFreeze() throws -> String {
        lock.lock()
        guard phase == .stableCommitted, applicationFrontmostSucceeded,
              workspaceIngress <= 1, terminalReason == nil else {
            failLocked("driver_foreground_freeze")
            let result = diagnosticsLocked(); lock.unlock()
            throw GateError.failed(result)
        }
        let closingWorkspaceTokens = workspaceTokens
        workspaceTokens.removeAll()
        phase = .frozen
        let material = "generation=\(generation);workspace_ingress=\(workspaceIngress);" +
            "event=causalRawForegroundTransition" +
            ";frontmost=1;window_writes=\(successfulWindowWrites.sorted().joined(separator: ","))"
        lock.unlock()
        for token in closingWorkspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        return stringHash(material)
    }

    private func recordWorkspace(
        _ notification: Notification, activation: Bool, generation: UInt64
    ) {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation, phase != .frozen else {
            failLocked("driver_foreground_late_event"); return
        }
        workspaceIngress += 1
        guard phase == .actionConsumed || phase == .poststateCandidate,
              workspaceIngress == 1, !activation,
              notification.name == NSWorkspace.didDeactivateApplicationNotification,
              notification.object as AnyObject? === NSWorkspace.shared,
              let candidate = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              predecessor.matches(candidate) else {
            failLocked("driver_foreground_workspace_interposition"); return
        }
    }

    private func failLocked(_ reason: String) {
        if terminalReason == nil { terminalReason = reason }
        phase = .failed
    }

    private func diagnosticsLocked() -> String {
        "driver_foreground generation=\(generation) workspace_ingress=\(workspaceIngress) " +
            "frontmost=\(applicationFrontmostSucceeded) " +
            "window_writes=\(successfulWindowWrites.count) " +
            "terminal=\(terminalReason ?? "none")"
    }
}

private func validateRawDriverAXApplication(
    _ axApplication: AXUIElement, localWindow: NSWindow,
    localBinding: RawDriverLocalWindowBinding,
    executable: URL, expectedStart: ProcessStartIdentity,
    expectedIdentity: RegularFileIdentity, expectedHash: String
) -> Bool {
    var applicationPID: pid_t = 0
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
          AXUIElementGetPid(axApplication, &applicationPID) == .success,
          applicationPID == getpid(),
          axString(axApplication, kAXRoleAttribute as CFString) == (kAXApplicationRole as String),
          axBool(axApplication, kAXFrontmostAttribute as CFString) != nil,
          NSRunningApplication.current.processIdentifier == getpid(),
          !NSRunningApplication.current.isTerminated,
          ProcessStartIdentity.capture(getpid()) == expectedStart,
          runningCommand(getpid()).map({ canonicalURL($0).path }) == executable.path,
          regularFileIdentity(executable) == expectedIdentity,
          (try? hash(executable)) == expectedHash,
          validateRawDriverLocalCGBinding(window: localWindow, retained: localBinding) != nil else {
        return false
    }
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(
        axApplication, kAXFrontmostAttribute as CFString, &settable) == .success &&
        settable.boolValue
}

private func validateRawDriverAXWindowBinding(
    axApplication: AXUIElement, axWindow: AXUIElement, localWindow: NSWindow,
    localBinding: RawDriverLocalWindowBinding,
    executable: URL, expectedStart: ProcessStartIdentity,
    expectedIdentity: RegularFileIdentity, expectedHash: String
) -> Bool {
    var windowPID: pid_t = 0
    guard validateRawDriverAXApplication(
            axApplication, localWindow: localWindow, localBinding: localBinding,
            executable: executable, expectedStart: expectedStart,
            expectedIdentity: expectedIdentity, expectedHash: expectedHash),
          AXUIElementGetPid(axWindow, &windowPID) == .success, windowPID == getpid(),
          let windows = axValue(axApplication, kAXWindowsAttribute as CFString) as? [AXUIElement],
          windows.count == 1, !CFEqual(axApplication, axWindow), CFEqual(windows[0], axWindow),
          axString(axWindow, kAXRoleAttribute as CFString) == (kAXWindowRole as String),
          axString(axWindow, kAXSubroleAttribute as CFString) == (kAXStandardWindowSubrole as String),
          axString(axWindow, kAXTitleAttribute as CFString) == localBinding.title,
          axString(axWindow, kAXIdentifierAttribute as CFString) == localBinding.identifier,
          let cgIdentity = validateRawDriverLocalCGBinding(
            window: localWindow, retained: localBinding) else { return false }
    switch rawDriverAXGeometry(axWindow) {
    case .absent: return false
    case .exact(let rectangle):
        return ExactRectangle(rectangle) == cgIdentity.localCGFrame
    case .invalid: return false
    }
}

private func rawDriverForegroundPrestate(
    axApplication: AXUIElement, window: NSWindow,
    localBinding: RawDriverLocalWindowBinding, predecessor: RawForegroundPredecessor,
    executable: URL, expectedStart: ProcessStartIdentity,
    expectedIdentity: RegularFileIdentity, expectedHash: String
) -> RawDriverLocalWindowBinding? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
          predecessor.matches(frontmost), predecessor.application.isActive,
          !NSRunningApplication.current.isActive,
          axBool(axApplication, kAXFrontmostAttribute as CFString) == false,
          !window.isKeyWindow, !window.isMainWindow,
          NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.briangao.elysium").isEmpty,
          validateRawDriverAXApplication(
            axApplication, localWindow: window, localBinding: localBinding,
            executable: executable, expectedStart: expectedStart,
            expectedIdentity: expectedIdentity, expectedHash: expectedHash) else { return nil }
    return localBinding
}

private func rawDriverForegroundSample(
    application: NSApplication, window: NSWindow, executable: URL,
    expectedStart: ProcessStartIdentity, expectedIdentity: RegularFileIdentity,
    expectedHash: String, localBinding: RawDriverLocalWindowBinding,
    predecessor: RawForegroundPredecessor
) -> RawDriverForegroundSample? {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
          window.isKeyWindow, window.isMainWindow,
          let frontmost = NSWorkspace.shared.frontmostApplication,
          frontmost.isEqual(NSRunningApplication.current),
          frontmost.processIdentifier == getpid(), !predecessor.application.isActive,
          !predecessor.application.isTerminated,
          predecessor.matches(predecessor.application),
          frontmost.executableURL.map({ canonicalURL($0.path) }) == executable,
          runningCommand(getpid()).map({ canonicalURL($0).path }) == executable.path,
          ProcessStartIdentity.capture(getpid()) == expectedStart,
          regularFileIdentity(executable) == expectedIdentity,
          (try? hash(executable)) == expectedHash,
          let cgIdentity = validateRawDriverLocalCGBinding(
            window: window, retained: localBinding) else { return nil }
    var consoleUID: uid_t = 0
    var consoleGID: gid_t = 0
    guard let console = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) as String?,
          console != "loginwindow", consoleUID == getuid(),
          let screen = window.screen,
          let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber else { return nil }
    let axApplication = AXUIElementCreateApplication(getpid())
    guard axBool(axApplication, kAXFrontmostAttribute as CFString) == true,
          let axWindows = axValue(axApplication, kAXWindowsAttribute as CFString) as? [AXUIElement],
          axWindows.count == 1,
          let focusedWindow = axElement(axApplication, kAXFocusedWindowAttribute as CFString),
          CFEqual(axWindows[0], focusedWindow),
          axBool(focusedWindow, kAXMainAttribute as CFString) == true,
          axBool(focusedWindow, kAXFocusedAttribute as CFString) == true,
          axString(focusedWindow, kAXRoleAttribute as CFString) == (kAXWindowRole as String),
          axString(focusedWindow, kAXSubroleAttribute as CFString) ==
            (kAXStandardWindowSubrole as String),
          axString(focusedWindow, kAXTitleAttribute as CFString) == localBinding.title,
          axString(focusedWindow, kAXIdentifierAttribute as CFString) == localBinding.identifier,
          let position = axPoint(focusedWindow, kAXPositionAttribute as CFString),
          let size = axSize(focusedWindow, kAXSizeAttribute as CFString) else { return nil }
    let rectangle = CGRect(origin: position, size: size)
    guard ExactRectangle(rectangle) == cgIdentity.localCGFrame,
          let focusedElement = axElement(axApplication, kAXFocusedUIElementAttribute as CFString),
          CFEqual(focusedElement, focusedWindow) || CFEqual(focusedElement, window.contentView) else {
        return nil
    }
    return RawDriverForegroundSample(
        processStart: expectedStart, command: executable.path,
        executableIdentity: expectedIdentity, executableHash: expectedHash,
        windowRectangle: rectangle, cgWindowID: CGWindowID(localBinding.number),
        consoleUser: console, displayID: CGDirectDisplayID(displayNumber.uint32Value),
        cgIdentity: cgIdentity, appKitActive: application.isActive,
        runningApplicationActive: NSRunningApplication.current.isActive)
}

let arguments = CommandLine.arguments
if arguments == [arguments[0], "--self-test-conditional-denial-action-v1"] {
    guard runConditionalDenialActionSelfTest(), runLaunchPresentationTimingBudgetSelfTest() else {
        fail("conditional action and presentation budget self-test")
    }
    print("Conditional denial action and presentation budget self-test: PASS cases=53")
    exit(0)
}
guard arguments.count == 9 else { fail("arguments") }
let bundleURL = canonicalURL(arguments[1])
let manifestURL = URL(fileURLWithPath: arguments[2])
let releaseURL = canonicalURL(arguments[3])
let expectedReleaseHash = arguments[4]
let pidFile = arguments[5]
let rawDriverExecutable = canonicalURL(arguments[0])
guard let rawDriverStart = ProcessStartIdentity.capture(getpid()),
      let rawDriverFileIdentity = regularFileIdentity(rawDriverExecutable),
      let rawDriverHash = try? hash(rawDriverExecutable),
      AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    fail("raw Driver identity or TCC preflight")
}
let rawDriverApplication = NSApplication.shared
guard rawDriverApplication.setActivationPolicy(.accessory) else {
    fail("raw Driver accessory activation policy")
}
rawDriverApplication.finishLaunching()
private let workspaceCenter = NSWorkspace.shared.notificationCenter
private let cleanup = Cleanup()
private var gateStage = "preflight"
private let actionLedger = OneShotActionLedger(expectedIDs: expectedOneShotActionIDs)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
private let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
private let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for source in [interruptSource, terminateSource] {
    source.setEventHandler {
        cleanup.run()
        exit(130)
    }
    source.resume()
}

do {
    try actionLedger.validateConfiguration(expectedCount: expectedOneShotActionIDs.count)
    guard ReadyEpoch.firstPostReadyMismatchIsTerminal([false, true]) else {
        throw GateError.failed("ready epoch negative fixture")
    }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        throw GateError.failed("Accessibility and Input Monitoring permissions are required")
    }
    var consoleUID: uid_t = 0
    var consoleGID: gid_t = 0
    guard let console = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) as String?,
          console != "loginwindow", consoleUID == getuid() else {
        throw GateError.failed("interactive unlocked console session required")
    }
    let initialDisplayAuthority = DisplayAuthoritySnapshot.capture()
    guard initialDisplayAuthority.eligible else {
        throw GateError.failed(
            "conditional_launch_display_unavailable \(initialDisplayAuthority.redactedAggregate)")
    }
    let manifest = try Manifest(url: manifestURL)
    guard canonicalURL(manifest["bundle_path"]).path == bundleURL.path else {
        throw GateError.failed("bundle path identity expected_hash=\(stringHash(canonicalURL(manifest["bundle_path"]).path)) observed_hash=\(stringHash(bundleURL.path))")
    }
    guard manifest["bundle_id"] == "com.briangao.elysium" else {
        throw GateError.failed("bundle identifier identity")
    }
    guard manifest["sealed_resources"] == "true" else {
        throw GateError.failed("resource seal identity")
    }
    guard try hash(releaseURL) == expectedReleaseHash else {
        throw GateError.failed("release hash identity")
    }
    guard manifest["pre_sign_input_sha256"] == expectedReleaseHash else {
        throw GateError.failed("manifest release identity")
    }
    let stagedExecutable = canonicalURL(manifest["executable_path"])
    let measuredStagedHash = try hash(stagedExecutable)
    guard measuredStagedHash == manifest["post_sign_executable_sha256"] else {
        throw GateError.failed("signed executable identity")
    }
    guard let launchFileIdentity = regularFileIdentity(stagedExecutable) else {
        throw GateError.failed("static artifact file identity")
    }
    guard let launchBundleDirectoryIdentity = exactBundleDirectoryIdentity(bundleURL) else {
        throw GateError.failed("static bundle directory identity")
    }
    let staticArtifactAuthority = StaticArtifactAuthority(
        bundle: bundleURL, bundleIdentifier: "com.briangao.elysium",
        executable: stagedExecutable, fileIdentity: launchFileIdentity,
        measuredSHA256: measuredStagedHash)
    guard staticArtifactAuthority.exact() else {
        throw GateError.failed("static artifact authority")
    }
    let coordinatorBundle = canonicalURL(arguments[6])
    guard coordinatorBundle.lastPathComponent == "ElysiumIntegrationCoordinator.app",
          let coordinatorExecutable = Bundle(url: coordinatorBundle)?.executableURL.map({ canonicalURL($0.path) }),
          try hash(coordinatorExecutable) == arguments[7],
          let coordinatorStaticCode = staticCodeIdentity(coordinatorBundle) else {
        throw GateError.failed("Coordinator static identity")
    }
    let coordinatorSession = try CoordinatorSession(root: coordinatorBundle.deletingLastPathComponent())
    try coordinatorSession.validateNamespace(expectSocket: true)
    guard let coordinatorForeground = CoordinatorForegroundLedger() else {
        throw GateError.failed("Coordinator predecessor identity")
    }
    coordinatorForeground.install()
    defer { coordinatorForeground.close() }
    let coordinatorConfiguration = NSWorkspace.OpenConfiguration()
    coordinatorConfiguration.activates = true
    coordinatorConfiguration.createsNewApplicationInstance = true
    coordinatorConfiguration.allowsRunningApplicationSubstitution = false
    coordinatorConfiguration.arguments = [
        "1", coordinatorSession.socketURL.path, hexString(coordinatorSession.nonce), "\(getpid())",
        rawDriverHash, bundleURL.path, measuredStagedHash,
    ]
    coordinatorConfiguration.environment = [:]
    let coordinatorLaunch = LaunchCompletionState()
    NSWorkspace.shared.openApplication(at: coordinatorBundle, configuration: coordinatorConfiguration) {
        coordinatorLaunch.receive(application: $0, error: $1)
    }
    guard wait(8, until: { coordinatorLaunch.isComplete() }),
          let coordinatorApplication = try? coordinatorLaunch.exactApplication(),
          coordinatorApplication.bundleIdentifier == "com.briangao.elysium.integration-coordinator",
          coordinatorApplication.bundleURL.map({ canonicalURL($0.path) }) == coordinatorBundle,
          coordinatorApplication.executableURL.map({ canonicalURL($0.path) }) == coordinatorExecutable else {
        throw GateError.failed("Coordinator LaunchServices identity")
    }
    coordinatorForeground.bind(coordinatorApplication)
    coordinatorSession.application = coordinatorApplication
    try Data("\(coordinatorApplication.processIdentifier)\n".utf8).write(
        to: URL(fileURLWithPath: arguments[8]), options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: arguments[8])
    let originalFlags = fcntl(coordinatorSession.listener, F_GETFL)
    guard originalFlags >= 0,
          fcntl(coordinatorSession.listener, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
        throw GateError.failed("Coordinator listener nonblocking")
    }
    let acceptDeadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        coordinatorSession.connection = accept(coordinatorSession.listener, nil, nil)
        if coordinatorSession.connection >= 0 { break }
        guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
            throw GateError.failed("Coordinator accept")
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    } while ProcessInfo.processInfo.systemUptime < acceptDeadline
    guard coordinatorSession.connection >= 0 else { throw GateError.failed("Coordinator accept") }
    try setCloseOnExec(coordinatorSession.connection)
    let connectionFlags = fcntl(coordinatorSession.connection, F_GETFL)
    guard connectionFlags >= 0,
          fcntl(coordinatorSession.connection, F_SETFL, connectionFlags & ~O_NONBLOCK) == 0 else {
        throw GateError.failed("Coordinator connection blocking mode")
    }
    var protocolTimeout = timeval(tv_sec: 5, tv_usec: 0)
    guard setsockopt(coordinatorSession.connection, SOL_SOCKET, SO_RCVTIMEO, &protocolTimeout,
                     socklen_t(MemoryLayout.size(ofValue: protocolTimeout))) == 0,
          setsockopt(coordinatorSession.connection, SOL_SOCKET, SO_SNDTIMEO, &protocolTimeout,
                     socklen_t(MemoryLayout.size(ofValue: protocolTimeout))) == 0 else {
        throw GateError.failed("Coordinator connection deadline")
    }
    close(coordinatorSession.listener); coordinatorSession.listener = -1
    try coordinatorSession.validateNamespace(expectSocket: true)
    let peerCredentials = try coordinatorPeerCredentials(coordinatorSession.connection)
    let peer = peerCredentials.pid
    guard peer == coordinatorApplication.processIdentifier,
          let peerStart = ProcessStartIdentity.capture(peer),
          runningCommand(peer).map({ canonicalURL($0).path }) == coordinatorExecutable.path,
          regularFileIdentity(coordinatorExecutable) != nil,
          (try? hash(coordinatorExecutable)) == arguments[7],
          let peerCode = liveCodeIdentity(peer), peerCode == coordinatorStaticCode else {
        throw GateError.failed("Coordinator peer identity")
    }
    let hello = try coordinatorSession.wire.receive(coordinatorSession.connection, type: 1)
    guard hello == Data("pid=\(peer)".utf8) else { throw GateError.failed("Coordinator HELLO") }
    let challenge = try secureRandom32()
    try coordinatorSession.wire.send(coordinatorSession.connection, type: 2, payload: challenge)
    let ready = try coordinatorSession.wire.receive(coordinatorSession.connection, type: 3)
    guard ready == Data(SHA256.hash(data: challenge)),
          ProcessStartIdentity.capture(peer) == peerStart,
          runningCommand(peer).map({ canonicalURL($0).path }) == coordinatorExecutable.path,
          liveCodeIdentity(peer) == peerCode,
          coordinatorForeground.ready(coordinatorApplication) else {
        throw GateError.failed("Coordinator foreground READY")
    }
    // Install the target observer while the exact retained Coordinator foreground
    // generation is still live. There is no unobserved authorization interval.
    let handoffLedger = RawDriverToTargetHandoffLedger(
        staticTarget: staticArtifactAuthority)
    try handoffLedger.installAndArmLifecycleLedger(center: workspaceCenter)
    cleanup.closeObservers = { handoffLedger.close(center: workspaceCenter) }
    let launchCaptureSequence = try handoffLedger.beginLaunchPathCapture()
    let launchFrontmost = NSWorkspace.shared.frontmostApplication
    let launchPredecessorIdentity = launchFrontmost.flatMap { predecessor ->
        (application: NSRunningApplication, pid: pid_t, bundle: URL?, executable: URL)? in
        guard let executable = predecessor.executableURL.map({ canonicalURL($0.path) }) else {
            return nil
        }
        return (predecessor, predecessor.processIdentifier,
                predecessor.bundleURL.map({ canonicalURL($0.path) }), executable)
    }
    try handoffLedger.capturePredecessorOrStaticTarget(
        sequence: launchCaptureSequence, frontmost: launchFrontmost,
        requiredPredecessor: coordinatorApplication)
    coordinatorForeground.close()

    let home = bundleURL.deletingLastPathComponent().appendingPathComponent("profile").path
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let launchCompletion = LaunchCompletionState()
    try actionLedger.perform("launch.application") {
        guard !launchCompletion.isComplete() else {
            throw GateError.failed("launch adjacent assertion")
        }
        try handoffLedger.armOpenAction()
        let authority = Data(SHA256.hash(data: Data((bundleURL.path + measuredStagedHash).utf8)))
        try coordinatorSession.wire.send(coordinatorSession.connection, type: 4, payload: authority)
    }
    let completionFrame = try coordinatorSession.wire.receive(coordinatorSession.connection, type: 5)
    guard let completionString = String(data: completionFrame, encoding: .utf8),
          completionString.hasPrefix("pid="),
          let completionPID = pid_t(completionString.dropFirst(4)), completionPID > 0,
          let completedApplication = NSRunningApplication(processIdentifier: completionPID) else {
        throw GateError.failed(handoffLedger.terminatePrelaunch("launch_completion_invalid"))
    }
    launchCompletion.receive(application: completedApplication, error: nil)
    let app: NSRunningApplication
    do {
        app = try launchCompletion.exactApplication()
    } catch {
        throw GateError.failed(
            handoffLedger.terminatePrelaunch("launch_completion_invalid"))
    }
    cleanup.application = app
    cleanup.expectedPID = app.processIdentifier
    try Data("\(app.processIdentifier)\n".utf8).write(
        to: URL(fileURLWithPath: pidFile), options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFile)
    guard !app.isTerminated, app.processIdentifier > 0,
          app.bundleIdentifier == "com.briangao.elysium",
          app.bundleURL.map({ canonicalURL($0.path) }) == bundleURL,
          app.executableURL.map({ canonicalURL($0.path) }) == stagedExecutable else {
        throw GateError.failed(
            handoffLedger.terminatePrelaunch("launched_process_identity"))
    }
    var launchedExecutable: String?
    guard wait(5, until: {
        launchedExecutable = runningCommand(app.processIdentifier)
        return launchedExecutable != nil
    }), let launchedExecutable else {
        throw GateError.failed(
            handoffLedger.terminatePrelaunch("launched_command_unavailable"))
    }
    guard canonicalURL(launchedExecutable).path == stagedExecutable.path else {
        throw GateError.failed(
            handoffLedger.terminatePrelaunch("launched_command_identity"))
    }
    cleanup.expectedExecutable = launchedExecutable
    let boundAppIdentity = BoundRunningApplicationIdentity(
        pid: app.processIdentifier, bundle: bundleURL, executable: stagedExecutable,
        measuredSHA256: measuredStagedHash)
    guard ProcessStartIdentity.capture(boundAppIdentity.pid) != nil else {
        throw GateError.failed("target process start identity")
    }
    guard runningApplicationIdentityMatches(
        valueEqual: true, original: boundAppIdentity, candidatePID: app.processIdentifier,
        candidateBundle: bundleURL, candidateExecutable: stagedExecutable,
        measuredSHA256: measuredStagedHash),
        !runningApplicationIdentityMatches(
            valueEqual: false, original: boundAppIdentity, candidatePID: app.processIdentifier,
            candidateBundle: bundleURL, candidateExecutable: stagedExecutable,
            measuredSHA256: measuredStagedHash),
        !runningApplicationIdentityMatches(
            valueEqual: true, original: boundAppIdentity, candidatePID: app.processIdentifier + 1,
            candidateBundle: bundleURL, candidateExecutable: stagedExecutable,
            measuredSHA256: measuredStagedHash),
        !runningApplicationIdentityMatches(
            valueEqual: true, original: boundAppIdentity, candidatePID: app.processIdentifier,
            candidateBundle: bundleURL.deletingLastPathComponent(),
            candidateExecutable: stagedExecutable, measuredSHA256: measuredStagedHash),
        !runningApplicationIdentityMatches(
            valueEqual: true, original: boundAppIdentity, candidatePID: app.processIdentifier,
            candidateBundle: bundleURL, candidateExecutable: bundleURL,
            measuredSHA256: measuredStagedHash),
        !runningApplicationIdentityMatches(
            valueEqual: true, original: boundAppIdentity, candidatePID: app.processIdentifier,
            candidateBundle: bundleURL, candidateExecutable: stagedExecutable,
            measuredSHA256: String(repeating: "0", count: 64)) else {
        throw GateError.failed("running-application identity fixture")
    }
    let immutableLaunchAuthority = ImmutableLaunchAuthority(
        application: app, identity: boundAppIdentity,
        fileIdentity: launchFileIdentity, executable: stagedExecutable,
        bundleDirectoryIdentity: launchBundleDirectoryIdentity)
    guard immutableLaunchAuthority.exactWithRehash() else {
        throw GateError.failed(
            handoffLedger.terminatePrelaunch("immutable_launch_authority"))
    }
    try handoffLedger.bindTargetAndReconcile(
        application: app, bundle: boundAppIdentity.bundle,
        executable: boundAppIdentity.executable)
    func exactCompletionRuntimeAuthority(requireRehash: Bool) -> Bool {
        guard let completion = try? launchCompletion.exactApplication(),
              completion.isEqual(app),
              runningCommand(boundAppIdentity.pid).map({ canonicalURL($0) }) ==
                boundAppIdentity.executable else { return false }
        return requireRehash ? immutableLaunchAuthority.exactWithRehash() :
            immutableLaunchAuthority.exactWithoutRehash()
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard wait(3, until: {
        axString(axApp, kAXRoleAttribute as CFString) == (kAXApplicationRole as String)
    }) else {
        throw GateError.failed("launch AX application publication")
    }
    let launchAXInvalidation = TargetAXInvalidationLedger()
    try launchAXInvalidation.install(pid: boundAppIdentity.pid, application: axApp)
    cleanup.closeObservers = {
        launchAXInvalidation.close()
        handoffLedger.close(center: workspaceCenter)
    }
    // One fixed pre-fallback deadline covers product-owned activation until an eligible denial
    // installs the one allowed bounded extension.
    let conditionalSamplingStarted = ProcessInfo.processInfo.systemUptime
    guard var conditionalDenialTimingBudget = ConditionalDenialTimingBudget(
        samplingStarted: conditionalSamplingStarted) else {
        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
            "conditional_launch_denial_budget_unavailable") + " " +
            "no_synthetic_click_sent=true verification_set_stopped=true")
    }
    var stableWindow: AXUIElement?
    func currentWindow() throws -> AXUIElement {
        if let stableWindow {
            var ownerPID: pid_t = 0
            if AXUIElementGetPid(stableWindow, &ownerPID) == .success,
               ownerPID == app.processIdentifier,
               axString(stableWindow, kAXRoleAttribute as CFString) == kAXWindowRole {
                return stableWindow
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        repeat {
            if let windows = axValue(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] {
                if let rawFocused = axValue(axApp, kAXFocusedWindowAttribute as CFString),
                   CFGetTypeID(rawFocused) == AXUIElementGetTypeID() {
                    let focused = unsafeBitCast(rawFocused, to: AXUIElement.self)
                    if windows.filter({ CFEqual($0, focused) }).count == 1 { return focused }
                    if windows.count == 1,
                       axString(focused, kAXRoleAttribute as CFString) == kAXWindowRole,
                       axPoint(focused, kAXPositionAttribute as CFString) ==
                         axPoint(windows[0], kAXPositionAttribute as CFString),
                       axSize(focused, kAXSizeAttribute as CFString) ==
                         axSize(windows[0], kAXSizeAttribute as CFString) {
                        return windows[0]
                    }
                } else if windows.count == 1,
                          axString(windows[0], kAXRoleAttribute as CFString) == kAXWindowRole {
                    return windows[0]
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw GateError.failed("window identity unavailable after deadline")
    }
    func currentGroup() throws -> AXUIElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        repeat {
            if let window = try? currentWindow() {
                let matches = descendants(window).filter {
                    axString($0, kAXRoleAttribute as CFString) == kAXGroupRole &&
                        axString($0, kAXDescriptionAttribute as CFString) == "Elysium menus and actions"
                }
                if matches.count == 1 { return matches[0] }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw GateError.failed("GameView group")
    }
    func logicalPoint(x: Double, y: Double) throws -> CGPoint {
        let window = try currentWindow()
        guard let position = axPoint(window, kAXPositionAttribute as CFString),
              let size = axSize(window, kAXSizeAttribute as CFString),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(CGRect(origin: position, size: size)) }) else {
            throw GateError.failed("window geometry")
        }
        let backing = screen.backingScaleFactor
        let drawableWidth = Double(size.width * backing)
        let drawableHeight = Double(size.height * backing)
        let scale = max(1, min(floor(drawableWidth / 380), floor(drawableHeight / 240)))
        return CGPoint(x: position.x + x * scale / backing,
                       y: position.y + y * scale / backing)
    }
    func validateBeforeAction() throws {
        guard app.processIdentifier == cleanup.expectedPID, app.isActive,
              app.bundleURL.map({ canonicalURL($0.path) }) == bundleURL,
              try hash(stagedExecutable) == manifest["post_sign_executable_sha256"] else {
            throw GateError.failed("action identity")
        }
        _ = try currentWindow()
    }
    func validateFieldBeforeAction(_ target: AXUIElement) throws {
        try validateBeforeAction()
        let current = descendants(try currentGroup())
        guard current.contains(where: { CFEqual($0, target) }),
              axBool(target, kAXFocusedAttribute as CFString) == true else {
            throw GateError.failed("field action identity")
        }
    }
    func fieldCenter(_ target: AXUIElement) throws -> CGPoint {
        guard let position = axPoint(target, kAXPositionAttribute as CFString),
              let extent = axSize(target, kAXSizeAttribute as CFString) else {
            throw GateError.failed("field action geometry")
        }
        return CGPoint(x: position.x + extent.width / 2, y: position.y + extent.height / 2)
    }

    func launchFastObservation(windows: [AXUIElement]) -> LaunchFastObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let focused = axElement(axApp, kAXFocusedWindowAttribute as CFString)
        let window = windows.count == 1 ? windows[0] : nil
        let point = window.flatMap { axPoint($0, kAXPositionAttribute as CFString) }
        let extent = window.flatMap { axSize($0, kAXSizeAttribute as CFString) }
        let finite = point.map { $0.x.isFinite && $0.y.isFinite } == true &&
            extent.map { $0.width.isFinite && $0.height.isFinite &&
                $0.width > 0 && $0.height > 0 } == true
        let fullscreenValue = window.flatMap(axFullScreen)
        return LaunchFastObservation(
            authorityExact: exactCompletionRuntimeAuthority(requireRehash: false),
            finishedLaunching: app.isFinishedLaunching,
            active: app.isActive,
            frontmostExact: frontmost?.isEqual(app) == true &&
                frontmost?.processIdentifier == boundAppIdentity.pid &&
                frontmost?.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle &&
                frontmost?.executableURL.map({ canonicalURL($0.path) }) ==
                    boundAppIdentity.executable,
            windowCountExact: windows.count == 1,
            focusedWindowExact: window != nil &&
                focused.map({ CFEqual($0, window!) }) == true,
            roleExact: window.flatMap({ axString($0, kAXRoleAttribute as CFString) }) ==
                kAXWindowRole,
            subroleStandard: window.flatMap({
                axString($0, kAXSubroleAttribute as CFString)
            }) == kAXStandardWindowSubrole,
            typedModePresent: fullscreenValue != nil,
            finiteRectangle: finite, window: window,
            mode: fullscreenValue.map {
                $0 ? LaunchPresentationMode.fullscreen : .windowedFallback
            },
            rectangle: finite ? CGRect(origin: point!, size: extent!) : nil)
    }

    func launchFastObservation() -> LaunchFastObservation {
        launchFastObservation(
            windows: axValue(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? [])
    }

    func launchCheapObservation(lease: LaunchSettlementLease) -> LaunchCheapObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let predecessorExact = launchPredecessorIdentity.map { predecessor in
            predecessor.pid != boundAppIdentity.pid && !predecessor.application.isTerminated &&
                frontmost?.isEqual(predecessor.application) == true &&
                frontmost?.processIdentifier == predecessor.pid &&
                frontmost?.bundleURL.map({ canonicalURL($0.path) }) == predecessor.bundle &&
                frontmost?.executableURL.map({ canonicalURL($0.path) }) == predecessor.executable
        } == true
        let ownerWindows = visibleCGOwnerWindows(pid: boundAppIdentity.pid)
        let candidate = ownerWindows.count == 1 ? ownerWindows[0] : nil
        let geometryFinite = candidate.map {
            [$0.rectangle.minX, $0.rectangle.minY, $0.rectangle.width, $0.rectangle.height]
                .allSatisfy(\.isFinite) && $0.rectangle.width > 0 && $0.rectangle.height > 0
        } == true
        let displayAuthority = DisplayAuthoritySnapshot.capture()
        let displays = geometryFinite ? displayAuthority.active.displays.filter { display in
            candidate.map { CGDisplayBounds(display).contains($0.rectangle) } ?? false
        } : []
        let displayID = displays.count == 1 ? displays[0] : nil
        let containingIndex = displayID.flatMap { displayAuthority.active.displays.firstIndex(of: $0) }
        let containingAwake = containingIndex.map { displayAuthority.activeAwake[$0] } == true
        let mappingCount = containingIndex.map { displayAuthority.screenMappingCounts[$0] } ?? 0
        let clickPoint = candidate.flatMap { window in
            displayID.flatMap { display in
                containingIndex.flatMap { displayAuthority.screenFrames[$0] }.flatMap {
                    denialTitlebarPoint(
                        window: window.rectangle, displayID: display, screenFrame: $0)
                }
            }
        }
        return LaunchCheapObservation(
            authorityExact: exactCompletionRuntimeAuthority(requireRehash: false),
            finishedLaunching: app.isFinishedLaunching,
            active: app.isActive,
            frontmostExact: frontmost?.isEqual(app) == true &&
                frontmost?.processIdentifier == boundAppIdentity.pid &&
                frontmost?.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle &&
                frontmost?.executableURL.map({ canonicalURL($0.path) }) ==
                    boundAppIdentity.executable,
            predecessorFrontmostExact: predecessorExact, lease: lease,
            inputPreflight: CGPreflightPostEventAccess(),
            ownerWindowCount: min(ownerWindows.count, 33),
            ownerGeometryFinite: geometryFinite,
            ownerOnScreen: candidate?.onScreen == true,
            ownerAlpha: candidate?.alpha,
            activeDisplays: displayAuthority.active,
            onlineDisplays: displayAuthority.online,
            displayAuthorityExact: displayAuthority.exactlyMatches(initialDisplayAuthority),
            containingActiveDisplayCount: min(displays.count, 33),
            containingDisplayAwake: containingAwake,
            nsscreenMappingCount: mappingCount,
            cgWindow: geometryFinite ? candidate : nil,
            displayID: displayID, titlebar: clickPoint)
    }

    func launchDenialObservation(
        cheap: LaunchCheapObservation, axSnapshot: DeniedAXSnapshot
    ) -> LaunchDenialObservation {
        LaunchDenialObservation(
            authorityExact: cheap.authorityExact,
            finishedLaunching: cheap.finishedLaunching,
            inactive: !cheap.active && !cheap.frontmostExact,
            predecessorFrontmostExact: cheap.predecessorFrontmostExact,
            lease: cheap.lease, workspaceUnchanged: false, axUnchanged: false,
            noFocusedProductChild: axSnapshot.focusedChildrenZero,
            noStandardInactiveSurface: axSnapshot.standardInactiveSurfaceZero,
            inputPreflight: cheap.inputPreflight,
            ownerWindowCount: cheap.ownerWindowCount,
            ownerGeometryFinite: cheap.ownerGeometryFinite,
            ownerOnScreen: cheap.ownerOnScreen,
            ownerAlphaOne: cheap.shippingPhase == .visibleAlphaOne,
            activeDisplays: cheap.activeDisplays,
            onlineDisplays: cheap.onlineDisplays,
            displayAuthorityExact: cheap.displayAuthorityExact,
            containingActiveDisplayCount: cheap.containingActiveDisplayCount,
            containingDisplayAwake: cheap.containingDisplayAwake,
            nsscreenMappingCount: cheap.nsscreenMappingCount,
            cgWindow: cheap.cgWindow, displayID: cheap.displayID,
            titlebar: cheap.titlebar, privateState: axSnapshot.privateState,
            axSnapshotTruncated: axSnapshot.truncated)
    }

    func commonModeLaunchDisposition() throws -> CommonModeLaunchDisposition? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard let lease = try handoffLedger.beginLaunchSettlementSample() else { return nil }
        if lease.authority == .expectedPairSurface {
            let workspaceUnchanged = try handoffLedger.finishLaunchSettlementSample(lease: lease)
            let frontmost = NSWorkspace.shared.frontmostApplication
            return .expectedPair(ExpectedPairLaunchSample(
                authorityExact: exactCompletionRuntimeAuthority(requireRehash: false),
                finishedLaunching: app.isFinishedLaunching,
                active: app.isActive,
                frontmostExact: frontmost?.isEqual(app) == true &&
                    frontmost?.processIdentifier == boundAppIdentity.pid &&
                    frontmost?.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle &&
                    frontmost?.executableURL.map({ canonicalURL($0.path) }) ==
                        boundAppIdentity.executable,
                workspaceUnchanged: workspaceUnchanged,
                startedAt: startedAt, endedAt: ProcessInfo.processInfo.systemUptime))
        }
        let cheap = launchCheapObservation(lease: lease)
        if cheap.shippingPhase != .visibleAlphaOne {
            let workspaceUnchanged = try handoffLedger.finishLaunchSettlementSample(lease: lease)
            return .denial(DenialModeLaunchSample(
                cheap: cheap, fast: nil, denial: nil,
                workspaceUnchanged: workspaceUnchanged, axUnchanged: true,
                startedAt: startedAt, endedAt: ProcessInfo.processInfo.systemUptime))
        }
        let axSequence = try launchAXInvalidation.beginSample()
        let axSnapshot = DeniedAXSnapshot.capture(application: axApp)
        let fast = launchFastObservation(windows: axSnapshot.windows)
        var denial = launchDenialObservation(cheap: cheap, axSnapshot: axSnapshot)
        let workspaceUnchanged = try handoffLedger.finishLaunchSettlementSample(lease: lease)
        let axUnchanged = try launchAXInvalidation.finishSample(sequence: axSequence)
        denial.workspaceUnchanged = workspaceUnchanged
        denial.axUnchanged = axUnchanged
        return .denial(DenialModeLaunchSample(
            cheap: cheap, fast: fast, denial: denial,
            workspaceUnchanged: workspaceUnchanged, axUnchanged: axUnchanged,
            startedAt: startedAt, endedAt: ProcessInfo.processInfo.systemUptime))
    }

    gateStage = "launch-settle"
    // Shipping waits 0.1s, then checks fullscreen five times at 1.2s intervals before revealing
    // its opaque windowed fallback. The extra two-second margin is fixed and cannot extend itself.
    let conditionalLaunchAction = ConditionalLaunchDenialAction()
    var denialCandidate: LaunchDenialObservation?
    var denialFirstExact: TimeInterval?
    var denialConsecutive = 0
    var zeroEventFirstExact: TimeInterval?
    var zeroEventConsecutive = 0
    let denialDiagnostics = LaunchDenialDiagnostics()
    denialDiagnostics.recordBudget(conditionalDenialTimingBudget)
    let inputMayHaveOccurred = false
    func inputDisposition() -> String {
        inputMayHaveOccurred
            ? "input_may_have_occurred=true result_invalid=true verification_set_stopped=true"
            : "no_synthetic_click_sent=true verification_set_stopped=true"
    }
    func appendInputDisposition(_ message: String) -> String {
        if message.contains("no_synthetic_click_sent=true") ||
            message.contains("input_may_have_occurred=true") { return message }
        return message + " " + inputDisposition()
    }
    let presentationBinding = try { () throws -> LaunchPresentationBinding in
    do {
    conditionalSampling: repeat {
        guard let disposition = try commonModeLaunchDisposition() else {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            continue
        }
        switch disposition {
        case .expectedPair(let pair):
            guard pair.completedWithinDeadline,
                  conditionalDenialTimingBudget.contains(pair.endedAt) else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_sampling_budget_exhausted"))
            }
            guard pair.authorityExact else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_authority"))
            }
            guard pair.workspaceUnchanged else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_pair_lease_changed"))
            }
            denialCandidate = nil
            denialFirstExact = nil
            denialConsecutive = 0
            guard pair.finishedLaunching else {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            guard pair.active, pair.frontmostExact else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_pair_authority_loss"))
            }
            try conditionalLaunchAction.close(.skippedSystemGranted)
            break
        case .denial(let sample):
            guard sample.completedWithinDeadline else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_denial_budget_unavailable"))
            }
            if conditionalDenialTimingBudget.isAnchored,
               !conditionalDenialTimingBudget.contains(sample.endedAt) {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_denial_budget_exhausted"))
            }
            guard sample.cheap.authorityExact else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_authority"))
            }
            guard sample.workspaceUnchanged else {
                denialCandidate = nil
                denialFirstExact = nil
                denialConsecutive = 0
                continue
            }
            guard sample.cheap.displayAuthorityExact else {
                if let denial = sample.denial {
                    denialDiagnostics.record(
                        denial, consecutive: 0, comparedTo: denialCandidate,
                        shippingPhase: sample.cheap.shippingPhase,
                        sampleDuration: sample.endedAt - sample.startedAt,
                        firstEligibleOffset: nil)
                }
                throw GateError.failed(
                    handoffLedger.terminateLaunchSettlement(
                        "conditional_launch_display_unavailable") + " " +
                    denialDiagnostics.aggregate(
                        state: conditionalLaunchAction.state, consecutive: denialConsecutive))
            }
            guard sample.cheap.shippingPhase == .visibleAlphaOne else {
                denialCandidate = nil
                denialFirstExact = nil
                denialConsecutive = 0
                guard !sample.cheap.active, !sample.cheap.frontmostExact else {
                    throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                        "conditional_launch_mixed_evidence"))
                }
                guard conditionalDenialTimingBudget.contains(sample.endedAt) else {
                    throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                        "conditional_launch_sampling_budget_exhausted"))
                }
                if sample.cheap.finishedLaunching, sample.cheap.predecessorFrontmostExact,
                   sample.workspaceUnchanged, sample.axUnchanged {
                    if zeroEventFirstExact == nil {
                        zeroEventFirstExact = sample.endedAt
                        zeroEventConsecutive = 1
                    } else {
                        zeroEventConsecutive += 1
                    }
                    if zeroEventConsecutive >= 2,
                       let first = zeroEventFirstExact, sample.endedAt - first >= 0.25 {
                        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                            "foreground_driver_initial_handoff_missing"))
                    }
                } else {
                    zeroEventFirstExact = nil
                    zeroEventConsecutive = 0
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            guard let fast = sample.fast, let denial = sample.denial else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_visible_snapshot_missing"))
            }
            if fast.eligible && sample.axUnchanged {
                guard conditionalDenialTimingBudget.contains(sample.endedAt) else {
                    throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                        "conditional_launch_sampling_budget_exhausted"))
                }
                try conditionalLaunchAction.close(.skippedSystemGranted)
                break
            }
            if fast.active || fast.frontmostExact ||
                (!denial.inactive && fast.finishedLaunching) ||
                (!denial.noStandardInactiveSurface && denial.inactive) {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_mixed_evidence"))
            }
            if sample.cheap.finishedLaunching, sample.cheap.predecessorFrontmostExact,
               sample.workspaceUnchanged, sample.axUnchanged, denial.inactive {
                if zeroEventFirstExact == nil {
                    zeroEventFirstExact = sample.endedAt
                    zeroEventConsecutive = 1
                } else {
                    zeroEventConsecutive += 1
                }
                if zeroEventConsecutive >= 2,
                   let first = zeroEventFirstExact, sample.endedAt - first >= 0.25 {
                    throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                        "foreground_driver_initial_handoff_missing"))
                }
            } else {
                zeroEventFirstExact = nil
                zeroEventConsecutive = 0
            }
            guard denial.eligible else {
                denialCandidate = nil
                denialFirstExact = nil
                denialConsecutive = 0
                denialDiagnostics.record(
                    denial, consecutive: denialConsecutive, comparedTo: denialCandidate,
                    shippingPhase: sample.cheap.shippingPhase,
                    sampleDuration: sample.endedAt - sample.startedAt,
                    firstEligibleOffset: nil)
                guard conditionalDenialTimingBudget.contains(sample.endedAt) else {
                    throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                        "conditional_launch_sampling_budget_exhausted"))
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            switch conditionalDenialTimingBudget.anchorFirstEligibleSample(
                recordedStart: sample.startedAt) {
            case .installed, .unchanged:
                denialDiagnostics.recordBudget(conditionalDenialTimingBudget)
            case .unavailable:
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_denial_budget_unavailable"))
            }
            guard conditionalDenialTimingBudget.contains(sample.endedAt) else {
                throw GateError.failed(handoffLedger.terminateLaunchSettlement(
                    "conditional_launch_denial_budget_exhausted"))
            }
            if denialCandidate?.sameCandidate(as: denial) != true {
                let previousCandidate = denialCandidate
                denialCandidate = denial
                denialFirstExact = sample.endedAt
                denialConsecutive = 1
                denialDiagnostics.record(
                    denial, consecutive: denialConsecutive, comparedTo: previousCandidate,
                    shippingPhase: sample.cheap.shippingPhase,
                    sampleDuration: sample.endedAt - sample.startedAt,
                    firstEligibleOffset: sample.endedAt - conditionalSamplingStarted)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            denialConsecutive += 1
            denialDiagnostics.record(
                denial, consecutive: denialConsecutive, comparedTo: denialCandidate,
                shippingPhase: sample.cheap.shippingPhase,
                sampleDuration: sample.endedAt - sample.startedAt,
                firstEligibleOffset: nil)
        }
        if conditionalLaunchAction.state != .unresolved { break }
        guard case .denial(let sample) = disposition else { continue }
        precondition(sample.cheap.lease.authority == .zeroEventSurface)
        guard sample.denial != nil else { continue }
        let now = sample.endedAt
        guard denialConsecutive >= 2, let first = denialFirstExact,
              now - first >= 0.25, denialCandidate != nil else {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            continue
        }

        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
            "foreground_driver_initial_handoff_missing"))
    } while ProcessInfo.processInfo.systemUptime < conditionalDenialTimingBudget.effectiveDeadline
    guard conditionalLaunchAction.state != .unresolved else {
        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
            conditionalDenialTimingBudget.isAnchored
                ? "conditional_launch_denial_budget_exhausted"
                : "conditional_launch_sampling_budget_exhausted") + " " +
            denialDiagnostics.aggregate(
                state: conditionalLaunchAction.state, consecutive: denialConsecutive))
    }

    guard conditionalLaunchAction.state == .skippedSystemGranted else {
        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
            "conditional_launch_action_not_terminal"))
    }
    let launchSettlement = LaunchPresentationSettlement()
    let presentationSamplingStart = ProcessInfo.processInfo.systemUptime
    guard let launchPresentationTimingBudget = LaunchPresentationTimingBudget(
        conditionalSamplingStarted: conditionalSamplingStarted,
        presentationSamplingStarted: presentationSamplingStart) else {
        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
            "launch_presentation_budget_unavailable"))
    }
    guard waitForLaunchPresentationBarrier(launchPresentationTimingBudget) else {
        throw GateError.failed(handoffLedger.terminateLaunchSettlement(
            "launch_presentation_timeout"))
    }
    let presentationBinding = try launchSettlement.settle(
        budget: launchPresentationTimingBudget,
        requiredConsecutiveSamples: 2,
        minimumStableDuration: 0.25,
        allowInitialPartialPair: false,
        lifecycle: handoffLedger,
        axInvalidation: launchAXInvalidation,
        fastSample: { launchFastObservation() },
        fullSnapshot: { candidateWindow, candidateMode, candidateRectangle, requireRehash in
            let windows = axValue(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
            let focused = axElement(axApp, kAXFocusedWindowAttribute as CFString)
            let point = axPoint(candidateWindow, kAXPositionAttribute as CFString)
            let extent = axSize(candidateWindow, kAXSizeAttribute as CFString)
            let revalidatedRectangle = point.flatMap { point in
                extent.map { CGRect(origin: point, size: $0) }
            }
            let candidateRetained = windows.count == 1 &&
                CFEqual(windows[0], candidateWindow) &&
                focused.map({ CFEqual($0, candidateWindow) }) == true &&
                axString(candidateWindow, kAXRoleAttribute as CFString) == kAXWindowRole &&
                axString(candidateWindow, kAXSubroleAttribute as CFString) ==
                    kAXStandardWindowSubrole &&
                axFullScreen(candidateWindow) == (candidateMode == .fullscreen) &&
                revalidatedRectangle == candidateRectangle
            let displayAuthority = DisplayAuthoritySnapshot.capture()
            let displays = displayAuthority.exactlyMatches(initialDisplayAuthority) ?
                displayAuthority.active.displays.filter {
                CGDisplayBounds($0).contains(candidateRectangle)
            } : []
            let cgWindows = matchingCGOwnerWindows(
                pid: boundAppIdentity.pid, rectangle: candidateRectangle)
            let cgExact = cgWindows.count == 1 && cgWindows[0].onScreen &&
                (candidateMode == .fullscreen || cgWindows[0].alpha == 1.0)
            let binding = candidateRetained && displays.count == 1 && cgExact
                ? LaunchPresentationBinding(
                    mode: candidateMode, displayID: displays[0], axWindow: candidateWindow,
                    cgWindowID: cgWindows[0].id, rectangle: candidateRectangle)
                : nil
            return LaunchFullSnapshot(
                authorityExact: exactCompletionRuntimeAuthority(requireRehash: false),
                displayAuthorityExact: displayAuthority.exactlyMatches(initialDisplayAuthority),
                candidateRetained: candidateRetained,
                containingDisplayCountExact: displays.count == 1,
                cgWindowCountExact: cgWindows.count == 1,
                cgWindowOnScreen: cgWindows.count == 1 && cgWindows[0].onScreen,
                cgWindowOpaque: candidateMode == .fullscreen ||
                    (cgWindows.count == 1 && cgWindows[0].alpha == 1.0),
                postbindRehashExact: !requireRehash ||
                    exactCompletionRuntimeAuthority(requireRehash: true),
                binding: binding)
        })
    stableWindow = presentationBinding.axWindow
    return presentationBinding
    } catch GateError.failed(let message) {
        throw GateError.failed(appendInputDisposition(message))
    }
    }()
    func launchPresentationRetained() -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let windows = axValue(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        let focused = axElement(axApp, kAXFocusedWindowAttribute as CFString)
        let point = axPoint(presentationBinding.axWindow, kAXPositionAttribute as CFString)
        let extent = axSize(presentationBinding.axWindow, kAXSizeAttribute as CFString)
        let rectangle = point.flatMap { p in extent.map { CGRect(origin: p, size: $0) } }
        let displays: [CGDirectDisplayID] = rectangle.map { value in
            let displayAuthority = DisplayAuthoritySnapshot.capture()
            return displayAuthority.exactlyMatches(initialDisplayAuthority) ?
                displayAuthority.active.displays.filter {
                    CGDisplayBounds($0).contains(value)
                } : []
        } ?? []
        let cgWindows = rectangle.map {
            matchingCGOwnerWindows(pid: boundAppIdentity.pid, rectangle: $0)
        } ?? []
        let expectedFullscreen = presentationBinding.mode == .fullscreen
        return (try? handoffLedger.requireBoundNavigation()) != nil &&
            (try? launchAXInvalidation.requireBound()) != nil &&
            !app.isTerminated && app.isFinishedLaunching && app.isActive &&
            frontmost?.isEqual(app) == true &&
            app.processIdentifier == boundAppIdentity.pid &&
            frontmost?.processIdentifier == boundAppIdentity.pid &&
            frontmost?.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle &&
            frontmost?.executableURL.map({ canonicalURL($0.path) }) ==
                boundAppIdentity.executable &&
            exactCompletionRuntimeAuthority(requireRehash: true) &&
            windows.count == 1 && CFEqual(windows[0], presentationBinding.axWindow) &&
            focused.map({ CFEqual($0, presentationBinding.axWindow) }) == true &&
            axFullScreen(presentationBinding.axWindow) == expectedFullscreen &&
            rectangle == presentationBinding.rectangle && displays.count == 1 &&
            displays[0] == presentationBinding.displayID && cgWindows.count == 1 &&
            cgWindows[0].id == presentationBinding.cgWindowID && cgWindows[0].onScreen &&
            (presentationBinding.mode == .fullscreen || cgWindows[0].alpha == 1.0)
    }
    func requireLaunchPresentation(_ id: String) throws {
        guard launchPresentationRetained() else {
            throw GateError.failed("\(id) presentation_binding_retained=false")
        }
    }
    gateStage = "title-navigation"
    _ = try currentGroup()
    let window = presentationBinding.axWindow
    let size = try { () -> CGSize in
        guard let value = axSize(window, kAXSizeAttribute as CFString) else { throw GateError.failed("size") }
        return value
    }()
    let backing = NSScreen.main?.backingScaleFactor ?? 2
    let uiScale = max(1, min(floor(Double(size.width * backing) / 380), floor(Double(size.height * backing) / 240)))
    let uiWidth = Double(size.width * backing) / uiScale
    let uiHeight = Double(size.height * backing) / uiScale
    let titleButtons = descendants(try currentGroup()).filter {
        axString($0, kAXRoleAttribute as CFString) == kAXButtonRole
    }
    let expectedTitleIDs = ["text:title:singleplayer", "text:title:multiplayer",
        "text:title:credits", "text:title:options", "text:title:quit"]
    let expectedTitleLabels = ["Singleplayer", "Multiplayer", "Credits", "Options...", "Quit Game"]
    guard titleButtons.count == 5,
          titleButtons.compactMap({ axString($0, kAXIdentifierAttribute as CFString) }) == expectedTitleIDs,
          titleButtons.compactMap({ axString($0, kAXDescriptionAttribute as CFString) }) == expectedTitleLabels,
          titleButtons.filter({ axBool($0, kAXFocusedAttribute as CFString) == true }).count == 1 else {
        throw GateError.failed("title production accessibility publication")
    }
    func currentTitleButtons() throws -> [AXUIElement] {
        let values = descendants(try currentGroup()).filter {
            axString($0, kAXRoleAttribute as CFString) == kAXButtonRole &&
                (axString($0, kAXIdentifierAttribute as CFString) ?? "").hasPrefix("text:title:")
        }
        guard values.count == 5 else { throw GateError.failed("title button count") }
        return values
    }
    func requireTitleFocus(_ expectedID: String, _ stage: String) throws {
        guard try waitFailFast(2, until: {
            guard let values = try? currentTitleButtons() else { return false }
            let focused = values.filter { axBool($0, kAXFocusedAttribute as CFString) == true }
            return focused.count == 1 &&
                axString(focused[0], kAXIdentifierAttribute as CFString) == expectedID
        }) else { throw GateError.failed("\(stage) title focus") }
    }
    let forwardIDs = ["text:title:multiplayer", "text:title:credits",
                      "text:title:options", "text:title:quit", "text:title:singleplayer"]
    for (index, expectedID) in forwardIDs.enumerated() {
        try postKeyOnce("title.tab.forward.\(index + 1)", 48, ledger: actionLedger,
                        finalCheck: { try requireLaunchPresentation("title forward adjacent") })
        try requireTitleFocus(expectedID, "title forward \(index + 1)")
        if index == 1 {
            try postKeyOnce("title.activate.credits", 49, ledger: actionLedger,
                            finalCheck: { try requireLaunchPresentation("credits activate adjacent") })
            guard try waitFailFast(2, until: {
                (try? currentTitleButtons()) == nil
            }) else { throw GateError.failed("credits keyboard activation") }
            try postKeyOnce("title.credits.escape", 53, ledger: actionLedger,
                            finalCheck: { try requireLaunchPresentation("credits escape adjacent") })
            try requireTitleFocus("text:title:credits", "credits return retention")
        }
    }
    let reverseIDs = ["text:title:quit", "text:title:options", "text:title:credits",
                      "text:title:multiplayer", "text:title:singleplayer"]
    for (index, expectedID) in reverseIDs.enumerated() {
        try postKeyOnce("title.tab.reverse.\(index + 1)", 48, flags: .maskShift,
                        ledger: actionLedger,
                        finalCheck: { try requireLaunchPresentation("title reverse adjacent") })
        try requireTitleFocus(expectedID, "title reverse \(index + 1)")
    }
    try postKeyOnce("title.activate.modified", 36, flags: .maskCommand,
                    ledger: actionLedger,
                    finalCheck: { try requireLaunchPresentation("title modified activation adjacent") })
    try requireTitleFocus("text:title:singleplayer", "modified activation rejected")
    try postRepeatingKeyOnce("title.activate.repeat", 36, ledger: actionLedger,
                             finalCheck: { try requireLaunchPresentation("title repeat adjacent") })
    try requireTitleFocus("text:title:singleplayer", "repeat activation rejected")
    let imageAspect = 1_672.0 / 941.0, viewportAspect = uiWidth / uiHeight
    let protectedBottom: Double
    if imageAspect > viewportAspect {
        protectedBottom = 416.0 / 941.0 * uiHeight
    } else {
        let visible = imageAspect / viewportAspect
        protectedBottom = ((416.0 / 941.0 - (1 - visible) / 2) / visible) * uiHeight
    }
    let heroSafeOrigin = ceil(min(uiHeight, max(0, protectedBottom)) + 6)
    let maximumPrimaryOrigin = (uiHeight - 20) - 4 - 20 - 72
    let titlePrimaryOrigin = min(max(floor(uiHeight / 4) + 48, heroSafeOrigin), maximumPrimaryOrigin)
    try validateBeforeAction()
    try requireLaunchPresentation("singleplayer pre-action")
    try postMouseOnce(
        "navigation.singleplayer.click",
        logicalPoint(x: Double(size.width * backing) / uiScale / 2,
                     y: titlePrimaryOrigin + 10), ledger: actionLedger,
        finalCheck: {
            try validateBeforeAction()
            try requireLaunchPresentation("singleplayer adjacent")
        })
    guard try waitFailFast(2, until: {
        try requireLaunchPresentation("singleplayer acknowledgement")
        return (try? currentGroup()) != nil
    }) else { throw GateError.failed("singleplayer navigation acknowledgement") }
    try validateBeforeAction()
    try requireLaunchPresentation("create-world pre-action")
    try postMouseOnce(
        "navigation.create-world.click",
        logicalPoint(x: Double(size.width * backing) / uiScale / 2 + 104,
                     y: uiHeight - 72), ledger: actionLedger,
        finalCheck: {
            try validateBeforeAction()
            try requireLaunchPresentation("create-world adjacent")
        })

    gateStage = "field-publication"
    var group: AXUIElement?, fields: [AXUIElement] = []
    guard try waitFailFast(5, until: {
        try requireLaunchPresentation("field publication")
        group = try? currentGroup()
        fields = group.map { descendants($0) } ?? []
        return fields.filter { axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole }.count == 2
    }), let group else { throw GateError.failed("published text fields") }
    fields = descendants(group).filter { axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole }
    let names = fields.filter { axString($0, kAXDescriptionAttribute as CFString) == "World Name" }
    let seeds = fields.filter { axString($0, kAXDescriptionAttribute as CFString) == "Seed" }
    guard names.count == 1, seeds.count == 1 else { throw GateError.failed("unique labels") }
    let name = names[0], seed = seeds[0]
    func fieldStateMatches(_ expected: FieldExpectation) -> Bool {
        let currentFields = descendants(group).filter {
            axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole
        }
        guard currentFields.count == 2,
              currentFields.contains(where: { CFEqual($0, name) }),
              currentFields.contains(where: { CFEqual($0, seed) }),
              axString(name, kAXValueAttribute as CFString) == expected.nameValue,
              axString(seed, kAXValueAttribute as CFString) == expected.seedValue,
              let nameRange = axRange(name, kAXSelectedTextRangeAttribute as CFString),
              let seedRange = axRange(seed, kAXSelectedTextRangeAttribute as CFString) else {
            return false
        }
        return nameRange.location == expected.nameRange && nameRange.length == 0 &&
            seedRange.location == expected.seedRange && seedRange.length == 0 &&
            axBool(name, kAXFocusedAttribute as CFString) == expected.nameFocused &&
            axBool(seed, kAXFocusedAttribute as CFString) == expected.seedFocused
    }
    func fieldAggregate(_ expected: FieldExpectation) -> String {
        let observedNameLength = axString(name, kAXValueAttribute as CFString)?.count ?? -1
        let observedSeedLength = axString(seed, kAXValueAttribute as CFString)?.count ?? -1
        let observedNameRange = axRange(
            name, kAXSelectedTextRangeAttribute as CFString)?.location ?? -1
        let observedSeedRange = axRange(
            seed, kAXSelectedTextRangeAttribute as CFString)?.location ?? -1
        let observedNameFocus = axBool(name, kAXFocusedAttribute as CFString) ?? false
        let observedSeedFocus = axBool(seed, kAXFocusedAttribute as CFString) ?? false
        return "expected_name_length=\(expected.nameValue.count) " +
            "observed_name_length=\(observedNameLength) " +
            "expected_name_range=\(expected.nameRange) observed_name_range=\(observedNameRange) " +
            "expected_name_focus=\(expected.nameFocused) observed_name_focus=\(observedNameFocus) " +
            "expected_seed_length=\(expected.seedValue.count) " +
            "observed_seed_length=\(observedSeedLength) " +
            "expected_seed_range=\(expected.seedRange) observed_seed_range=\(observedSeedRange) " +
            "expected_seed_focus=\(expected.seedFocused) observed_seed_focus=\(observedSeedFocus)"
    }
    func requireFieldState(_ id: String, _ expected: FieldExpectation,
                           timeout: TimeInterval = 2) throws {
        guard wait(timeout, until: { fieldStateMatches(expected) }) else {
            throw GateError.failed("\(id) \(fieldAggregate(expected))")
        }
    }
    for field in [name, seed] {
        guard let position = axPoint(field, kAXPositionAttribute as CFString),
              let extent = axSize(field, kAXSizeAttribute as CFString),
              position.x.isFinite, position.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { throw GateError.failed("field frame") }
    }
    guard axString(name, kAXValueAttribute as CFString) == "",
          axString(seed, kAXValueAttribute as CFString) == "" else {
        throw GateError.failed("initial values")
    }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(name, kAXValueAttribute as CFString, &settable) == .success,
          !settable.boolValue,
          AXUIElementIsAttributeSettable(name, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
          !settable.boolValue else { throw GateError.failed("read-only AX") }

    let nameIdentity = name
    gateStage = "name-focus-and-edit"
    try validateBeforeAction()
    try requireLaunchPresentation("world-name click pre-action")
    try postMouseOnce("world-name.click", fieldCenter(name), ledger: actionLedger,
                      finalCheck: {
                          try validateBeforeAction()
                          try requireLaunchPresentation("world-name click adjacent")
                      })
    try requireFieldState("world-name click", FieldExpectation(
        nameValue: "", nameRange: 0, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false))
    try validateFieldBeforeAction(name)
    try requireLaunchPresentation("world-name key a pre-action")
    try postKeyOnce("world-name.key.a", 0, ledger: actionLedger,
                    finalCheck: {
                        try validateFieldBeforeAction(name)
                        try requireLaunchPresentation("world-name key a adjacent")
                    })
    let nameA = FieldExpectation(
        nameValue: "a", nameRange: 1, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try requireFieldState("world-name key a", nameA)

    let reactivationWindow = try currentWindow()
    let reactivationGroup = try currentGroup()
    guard CFEqual(reactivationWindow, window), CFEqual(reactivationGroup, group),
          let reactivationPosition = axPoint(
            reactivationWindow, kAXPositionAttribute as CFString),
          let reactivationSize = axSize(reactivationWindow, kAXSizeAttribute as CFString),
          [reactivationPosition.x, reactivationPosition.y,
           reactivationSize.width, reactivationSize.height].allSatisfy(\.isFinite),
          CGRect(origin: reactivationPosition, size: reactivationSize) ==
            presentationBinding.rectangle else {
        throw GateError.failed("pre-reactivation aggregate identity")
    }
    let finders = NSWorkspace.shared.runningApplications.filter {
        $0.processIdentifier != app.processIdentifier && $0.bundleIdentifier == "com.apple.finder"
    }
    guard finders.count == 1,
          let finderBundle = finders[0].bundleURL.map({ canonicalURL($0.path) }),
          let finderExecutable = finders[0].executableURL.map({ canonicalURL($0.path) }) else {
        throw GateError.failed("Finder activation target count")
    }
    let finder = finders[0]
    let finderPID = finder.processIdentifier
    let readyEpoch = ReadyEpoch()
    func activeSurface(_ expected: FieldExpectation) -> ActiveSurfaceObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let windows = axValue(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        let focusedWindow = axElement(axApp, kAXFocusedWindowAttribute as CFString)
        let currentPoint = axPoint(reactivationWindow, kAXPositionAttribute as CFString)
        let currentSize = axSize(reactivationWindow, kAXSizeAttribute as CFString)
        let currentRectangle = currentPoint.flatMap { point in
            currentSize.map { CGRect(origin: point, size: $0) }
        }
        let containingDisplays: [CGDirectDisplayID] = currentRectangle.map { rectangle in
            let displayAuthority = DisplayAuthoritySnapshot.capture()
            return displayAuthority.exactlyMatches(initialDisplayAuthority) ?
                displayAuthority.active.displays.filter {
                    CGDisplayBounds($0).contains(rectangle)
                } : []
        } ?? []
        let cgWindows = currentRectangle.map {
            matchingCGOwnerWindows(pid: boundAppIdentity.pid, rectangle: $0)
        } ?? []
        let fullscreenValue = axFullScreen(reactivationWindow)
        let expectedFullscreen = presentationBinding.mode == .fullscreen
        let modeExact = fullscreenValue == expectedFullscreen
        let geometryRetained = axPoint(
            reactivationWindow, kAXPositionAttribute as CFString) == reactivationPosition &&
            axSize(reactivationWindow, kAXSizeAttribute as CFString) == reactivationSize &&
            currentRectangle == presentationBinding.rectangle
        let groups = descendants(reactivationWindow).filter {
            axString($0, kAXRoleAttribute as CFString) == kAXGroupRole &&
                axString($0, kAXDescriptionAttribute as CFString) == "Elysium menus and actions"
        }
        let groupIdentity = groups.count == 1 && CFEqual(groups[0], reactivationGroup)
        let currentFields = groupIdentity ? descendants(reactivationGroup).filter {
            axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole
        } : []
        return ActiveSurfaceObservation(
            appNotTerminated: !app.isTerminated,
            appPID: app.processIdentifier == boundAppIdentity.pid,
            appBundle: app.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle,
            appExecutable: app.executableURL.map({ canonicalURL($0.path) }) ==
                boundAppIdentity.executable,
            appMeasuredBytes: (try? hash(stagedExecutable)) == boundAppIdentity.measuredSHA256,
            active: app.isActive, frontmostPresent: frontmost != nil,
            frontmostValueEqual: frontmost?.isEqual(app) == true,
            frontmostPID: frontmost?.processIdentifier == boundAppIdentity.pid,
            frontmostBundle: frontmost?.bundleURL.map({ canonicalURL($0.path) }) ==
                boundAppIdentity.bundle,
            frontmostExecutable: frontmost?.executableURL.map({ canonicalURL($0.path) }) ==
                boundAppIdentity.executable,
            windowCount: windows.count == 1,
            windowIdentity: windows.count == 1 && CFEqual(windows[0], reactivationWindow),
            focusedWindowIdentity: focusedWindow.map({ CFEqual($0, reactivationWindow) }) == true,
            axFullScreenPresent: fullscreenValue != nil, axFullScreenValue: modeExact,
            presentationModeBound: modeExact,
            containingDisplayCountExact: containingDisplays.count == 1,
            displayIdentity: containingDisplays.count == 1 &&
                containingDisplays[0] == presentationBinding.displayID,
            cgWindowCountExact: cgWindows.count == 1,
            cgWindowIdentity: cgWindows.count == 1 &&
                cgWindows[0].id == presentationBinding.cgWindowID,
            cgWindowOnScreen: cgWindows.count == 1 && cgWindows[0].onScreen,
            cgWindowOpaque: presentationBinding.mode == .fullscreen ||
                (cgWindows.count == 1 && cgWindows[0].alpha == 1.0),
            axCGRectangleEqual: cgWindows.count == 1 &&
                cgWindows[0].rectangle == currentRectangle,
            geometryRetained: geometryRetained, groupCount: groups.count == 1,
            groupIdentity: groupIdentity, fieldCount: currentFields.count == 2,
            nameIdentity: currentFields.contains(where: { CFEqual($0, name) }),
            seedIdentity: currentFields.contains(where: { CFEqual($0, seed) }),
            nameFocus: axBool(name, kAXFocusedAttribute as CFString) == expected.nameFocused,
            seedFocus: axBool(seed, kAXFocusedAttribute as CFString) == expected.seedFocused)
    }
    func handoffBoundSurface(_ expected: FieldExpectation) throws -> ActiveSurfaceObservation {
        let sequence = try handoffLedger.beginSurfaceSample()
        let surface = activeSurface(expected)
        try handoffLedger.finishSurfaceSample(sequence: sequence)
        return surface
    }
    func assertReadyState(_ id: String, _ expected: FieldExpectation) throws {
        let surface = try handoffBoundSurface(expected)
        let stateExact = fieldStateMatches(expected)
        try readyEpoch.assertReady(surface.exact && stateExact,
            failure: "\(id) \(surface.aggregate) state=\(stateExact) \(fieldAggregate(expected))")
    }
    func requireSynchronousState(_ id: String, _ expected: FieldExpectation) throws {
        let surface = try handoffBoundSurface(expected)
        let stateExact = fieldStateMatches(expected)
        try readyEpoch.assertReady(surface.exact && stateExact,
            failure: "\(id) \(surface.aggregate) state=\(stateExact) \(fieldAggregate(expected))")
    }
    func requireSemanticTransition(_ id: String, from prior: FieldExpectation,
                                   to expected: FieldExpectation,
                                   timeout: TimeInterval = 2) throws {
        let completed = try waitFailFast(timeout) {
            let surface = try handoffBoundSurface(expected)
            try readyEpoch.assertReady(surface.exact,
                failure: "\(id) \(surface.aggregate) \(fieldAggregate(expected))")
            if fieldStateMatches(expected) { return true }
            let priorStillExact = fieldStateMatches(prior)
            try readyEpoch.assertReady(priorStillExact,
                failure: "\(id) semantic_state=false \(surface.aggregate) \(fieldAggregate(expected))")
            return false
        }
        guard completed else {
            let surface = try handoffBoundSurface(expected)
            throw GateError.failed(
                "\(id) semantic_timeout=true \(surface.aggregate) \(fieldAggregate(expected))")
        }
    }
    try requireFieldState("pre-reactivation state", nameA)
    try activateOnce("finder.activate", finder, ledger: actionLedger,
                     finalCheck: {
                         try validateFieldBeforeAction(name)
                         try requireLaunchPresentation("finder adjacent")
                         try handoffLedger.beginFinderAction(
                            finder: finder, bundle: finderBundle,
                            executable: finderExecutable)
                     })
    try handoffLedger.awaitFinderPair(timeout: 2)
    let finderSurfaceSettlement = FinderSurfaceSettlement()
    try finderSurfaceSettlement.settle(
        mode: presentationBinding.mode, timeout: 3,
        minimumStableDuration: 0.25, requiredConsecutiveSamples: 4,
        ledger: handoffLedger,
        sample: {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let currentPoint = axPoint(reactivationWindow, kAXPositionAttribute as CFString)
            let currentSize = axSize(reactivationWindow, kAXSizeAttribute as CFString)
            let currentRectangle = currentPoint.flatMap { point in
                currentSize.map { CGRect(origin: point, size: $0) }
            }
            let fullscreenValue = axFullScreen(reactivationWindow)
            let boundWindow = boundCGOwnerWindow(
                pid: boundAppIdentity.pid, windowID: presentationBinding.cgWindowID,
                layer: 0, rectangle: presentationBinding.rectangle)
            let expectedOnScreen = presentationBinding.mode == .windowedFallback
            let expectedOpaque = presentationBinding.mode == .fullscreen ||
                boundWindow.alpha == 1.0
            var axOwnerPID: pid_t = 0
            let axWindowIdentity = AXUIElementGetPid(
                reactivationWindow, &axOwnerPID) == .success &&
                axOwnerPID == boundAppIdentity.pid &&
                axString(reactivationWindow, kAXRoleAttribute as CFString) == kAXWindowRole
            return FinderSurfaceObservation(
                finderIdentity: finder.processIdentifier == finderPID &&
                    finder.bundleURL.map({ canonicalURL($0.path) }) == finderBundle &&
                    finder.executableURL.map({ canonicalURL($0.path) }) == finderExecutable,
                finderActive: finder.isActive,
                finderFrontmost: frontmost?.isEqual(finder) == true &&
                    frontmost?.processIdentifier == finder.processIdentifier &&
                    frontmost?.bundleURL.map({ canonicalURL($0.path) }) == finderBundle &&
                    frontmost?.executableURL.map({ canonicalURL($0.path) }) == finderExecutable,
                elysiumIdentity: !app.isTerminated &&
                    app.processIdentifier == boundAppIdentity.pid &&
                    app.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle &&
                    app.executableURL.map({ canonicalURL($0.path) }) ==
                        boundAppIdentity.executable &&
                    (try? hash(stagedExecutable)) == boundAppIdentity.measuredSHA256,
                elysiumInactive: !app.isActive,
                axWindowIdentity: axWindowIdentity &&
                    CFEqual(reactivationWindow, presentationBinding.axWindow),
                axModeExact: fullscreenValue ==
                    (presentationBinding.mode == .fullscreen),
                axGeometryExact: currentRectangle == presentationBinding.rectangle &&
                    currentPoint == reactivationPosition && currentSize == reactivationSize,
                boundWindowPresent: boundWindow.presentExactlyOnce,
                boundWindowPID: boundWindow.pidExact,
                boundWindowID: boundWindow.windowIDExact,
                boundWindowLayer: boundWindow.layerExact,
                boundWindowRectangle: boundWindow.rectangleExact,
                boundWindowOnScreenPresent: boundWindow.onScreen != nil,
                boundWindowOnScreenExpected: boundWindow.onScreen == expectedOnScreen,
                boundWindowOpaque: expectedOpaque)
        })
    try activateOnce("elysium.reactivate", app, ledger: actionLedger, finalCheck: {
        guard app.processIdentifier == cleanup.expectedPID,
              app.bundleURL.map({ canonicalURL($0.path) }) == bundleURL,
              app.executableURL.map({ canonicalURL($0.path) }) == stagedExecutable else {
            throw GateError.failed("elysium reactivation adjacent identity")
        }
        try finderSurfaceSettlement.requireSettled()
        try handoffLedger.requireFinderSurfaceFinal()
        try handoffLedger.beginElysiumAction()
    })
    try handoffLedger.awaitElysiumPair(timeout: 2)
    gateStage = "reactivation-preservation"
    try readyEpoch.settle(
        timeout: 3, minimumStableDuration: 0.25, requiredConsecutiveSamples: 4,
        sample: {
            let sequence = try handoffLedger.beginSurfaceSample()
            let surface = activeSurface(nameA)
            let sample = SettlingSample(
                surface: surface, fieldStateExact: fieldStateMatches(nameA),
                fieldAggregate: fieldAggregate(nameA))
            try handoffLedger.finishSurfaceSample(sequence: sequence)
            return sample
        })
    let preservedSurface = try handoffBoundSurface(nameA)
    let preservedState = fieldStateMatches(nameA)
    guard preservedSurface.exact, preservedState else {
        throw GateError.failed(
            "pre-repair preservation \(preservedSurface.aggregate) state=\(preservedState) " +
            fieldAggregate(nameA))
    }
    try readyEpoch.preserve(true)
    try readyEpoch.enterReady()
    try handoffLedger.markReady()

    try assertReadyState("world-name reactivation-focus pre-action", nameA)
    try setFocusedOnce("world-name.reactivation-focus", name, ledger: actionLedger,
                       finalCheck: {
                           try assertReadyState(
                               "world-name reactivation-focus adjacent", nameA)
                       })
    try requireSynchronousState("post-reactivation focus", nameA)

    gateStage = "reactivation-and-middle-edit"
    let nameAB = FieldExpectation(
        nameValue: "ab", nameRange: 2, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try assertReadyState("world-name key b pre-action", nameA)
    try postKeyOnce("world-name.key.b", 11, ledger: actionLedger,
                    finalCheck: { try assertReadyState("world-name key b adjacent", nameA) })
    try requireSemanticTransition("world-name key b", from: nameA, to: nameAB)

    let nameABC = FieldExpectation(
        nameValue: "abc", nameRange: 3, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try assertReadyState("world-name key c pre-action", nameAB)
    try postKeyOnce("world-name.key.c", 8, ledger: actionLedger,
                    finalCheck: { try assertReadyState("world-name key c adjacent", nameAB) })
    try requireSemanticTransition("world-name key c", from: nameAB, to: nameABC)

    let nameABCD = FieldExpectation(
        nameValue: "abcd", nameRange: 4, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try assertReadyState("world-name key d pre-action", nameABC)
    try postKeyOnce("world-name.key.d", 2, ledger: actionLedger,
                    finalCheck: { try assertReadyState("world-name key d adjacent", nameABC) })
    try requireSemanticTransition("world-name key d", from: nameABC, to: nameABCD)

    let nameLeft1 = FieldExpectation(
        nameValue: "abcd", nameRange: 3, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try assertReadyState("world-name left 1 pre-action", nameABCD)
    try postKeyOnce("world-name.key.left-1", 123, ledger: actionLedger,
                    finalCheck: { try assertReadyState("world-name left 1 adjacent", nameABCD) })
    try requireSemanticTransition("world-name left 1", from: nameABCD, to: nameLeft1)

    let nameLeft2 = FieldExpectation(
        nameValue: "abcd", nameRange: 2, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try assertReadyState("world-name left 2 pre-action", nameLeft1)
    try postKeyOnce("world-name.key.left-2", 123, ledger: actionLedger,
                    finalCheck: { try assertReadyState("world-name left 2 adjacent", nameLeft1) })
    try requireSemanticTransition("world-name left 2", from: nameLeft1, to: nameLeft2)

    let nameACD = FieldExpectation(
        nameValue: "acd", nameRange: 1, nameFocused: true,
        seedValue: "", seedRange: 0, seedFocused: false)
    try assertReadyState("world-name backspace pre-action", nameLeft2)
    try postKeyOnce("world-name.key.backspace", 51, ledger: actionLedger,
                    finalCheck: { try assertReadyState("world-name backspace adjacent", nameLeft2) })
    try requireSemanticTransition("world-name backspace", from: nameLeft2, to: nameACD)

    gateStage = "field-switching"
    let seedFocused = FieldExpectation(
        nameValue: "acd", nameRange: 1, nameFocused: false,
        seedValue: "", seedRange: 0, seedFocused: true)
    try assertReadyState("seed focus pre-action", nameACD)
    try setFocusedOnce("seed.focus", seed, ledger: actionLedger,
                       finalCheck: { try assertReadyState("seed focus adjacent", nameACD) })
    try requireSynchronousState("seed focus", seedFocused)

    let seedSeven = FieldExpectation(
        nameValue: "acd", nameRange: 1, nameFocused: false,
        seedValue: "7", seedRange: 1, seedFocused: true)
    try assertReadyState("seed key 7 pre-action", seedFocused)
    try postKeyOnce("seed.key.7", 26, ledger: actionLedger,
                    finalCheck: { try assertReadyState("seed key 7 adjacent", seedFocused) })
    try requireSemanticTransition("seed key 7", from: seedFocused, to: seedSeven)

    let nameRestored = FieldExpectation(
        nameValue: "acd", nameRange: 1, nameFocused: true,
        seedValue: "7", seedRange: 1, seedFocused: false)
    try assertReadyState("world-name focus pre-action", seedSeven)
    try setFocusedOnce("world-name.focus", name, ledger: actionLedger,
                       finalCheck: { try assertReadyState("world-name focus adjacent", seedSeven) })
    try requireSynchronousState("world-name focus", nameRestored)

    let nameRight1 = FieldExpectation(
        nameValue: "acd", nameRange: 2, nameFocused: true,
        seedValue: "7", seedRange: 1, seedFocused: false)
    try assertReadyState("world-name right 1 pre-action", nameRestored)
    try postKeyOnce("world-name.key.right-1", 124, ledger: actionLedger,
                    finalCheck: {
                        try assertReadyState("world-name right 1 adjacent", nameRestored)
                    })
    try requireSemanticTransition("world-name right 1", from: nameRestored, to: nameRight1)

    let nameAtEnd = FieldExpectation(
        nameValue: "acd", nameRange: 3, nameFocused: true,
        seedValue: "7", seedRange: 1, seedFocused: false)
    try assertReadyState("world-name right 2 pre-action", nameRight1)
    try postKeyOnce("world-name.key.right-2", 124, ledger: actionLedger,
                    finalCheck: {
                        try assertReadyState("world-name right 2 adjacent", nameRight1)
                    })
    try requireSemanticTransition("world-name right 2", from: nameRight1, to: nameAtEnd)

    try assertReadyState("world-name right saturated pre-action", nameAtEnd)
    try postKeyOnce("world-name.key.right-saturated", 124, ledger: actionLedger,
                    finalCheck: {
                        try assertReadyState("world-name right saturated adjacent", nameAtEnd)
                    })
    try requireSynchronousState("world-name right saturated", nameAtEnd)
    let fieldsAfter = descendants(try currentGroup()).filter {
        axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole
    }
    guard fieldsAfter.contains(where: { CFEqual($0, nameIdentity) }), fieldsAfter.count == 2,
          axBool(name, kAXFocusedAttribute as CFString) == true,
          axBool(seed, kAXFocusedAttribute as CFString) == false else {
        throw GateError.failed("retained AX identity")
    }
    gateStage = "resize"
    try assertReadyState("window fullscreen pre-action", nameAtEnd)
    try postKeyOnce("window.fullscreen.key.f11", 103, ledger: actionLedger,
                    finalCheck: {
                        try assertReadyState("window fullscreen adjacent", nameAtEnd)
                    })
    stableWindow = nil
    var resizedWindow: AXUIElement?
    var resizedGroup: AXUIElement?
    var resizedName: AXUIElement?
    var oppositeCandidate: LaunchPresentationBinding?
    var oppositeConsecutive = 0
    var oppositeFirstExact: TimeInterval?
    var sawOppositeMode = false
    let oppositeMode = presentationBinding.mode.opposite
    let resizeDeadline = ProcessInfo.processInfo.systemUptime + 15
    repeat {
        let handoffSequence = try handoffLedger.beginSurfaceSample()
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard !app.isTerminated, app.isActive, frontmost?.isEqual(app) == true,
              app.processIdentifier == boundAppIdentity.pid,
              app.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle,
              app.executableURL.map({ canonicalURL($0.path) }) == boundAppIdentity.executable,
              (try? hash(stagedExecutable)) == boundAppIdentity.measuredSHA256,
              frontmost?.processIdentifier == boundAppIdentity.pid,
              frontmost?.bundleURL.map({ canonicalURL($0.path) }) == boundAppIdentity.bundle,
              frontmost?.executableURL.map({ canonicalURL($0.path) }) ==
                boundAppIdentity.executable,
              let windows = axValue(axApp, kAXWindowsAttribute as CFString) as? [AXUIElement],
              windows.count == 1,
              let focused = axElement(axApp, kAXFocusedWindowAttribute as CFString),
              CFEqual(focused, windows[0]),
              let position = axPoint(windows[0], kAXPositionAttribute as CFString),
              let extent = axSize(windows[0], kAXSizeAttribute as CFString),
              let fullscreenValue = axFullScreen(windows[0]),
              [position.x, position.y, extent.width, extent.height].allSatisfy(\.isFinite) else {
            // AppKit may temporarily withdraw the focused AX window while moving the app
            // between Spaces. No transient sample is accepted; retry until the fixed deadline,
            // where the exact identity, geometry and mode predicates below must still converge.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            continue
        }
        let candidate = windows[0]
        let currentMode: LaunchPresentationMode = fullscreenValue ? .fullscreen : .windowedFallback
        let rectangle = CGRect(origin: position, size: extent)
        let displayAuthority = DisplayAuthoritySnapshot.capture()
        let containingDisplays = displayAuthority.exactlyMatches(initialDisplayAuthority) ?
            displayAuthority.active.displays.filter { CGDisplayBounds($0).contains(rectangle) } : []
        let cgWindows = matchingCGOwnerWindows(pid: boundAppIdentity.pid, rectangle: rectangle)
        guard containingDisplays.count == 1, cgWindows.count == 1, cgWindows[0].onScreen,
              currentMode == .fullscreen || cgWindows[0].alpha == 1.0 else {
            throw GateError.failed(
                "resize containing_display_count_exact=\(containingDisplays.count == 1) " +
                "cg_window_count_exact=\(cgWindows.count == 1) " +
                "cg_window_onscreen=\(cgWindows.count == 1 && cgWindows[0].onScreen) " +
                "cg_window_opaque=\(cgWindows.count == 1 && cgWindows[0].alpha == 1.0)")
        }
        try handoffLedger.finishSurfaceSample(sequence: handoffSequence)
        if currentMode == presentationBinding.mode {
            guard !sawOppositeMode, CFEqual(candidate, reactivationWindow),
                  rectangle == presentationBinding.rectangle,
                  containingDisplays[0] == presentationBinding.displayID,
                  cgWindows[0].id == presentationBinding.cgWindowID,
                  fieldStateMatches(nameAtEnd) else {
                throw GateError.failed(
                    "resize old_mode_return=false old_binding_retained=false state=false")
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            continue
        }
        guard currentMode == oppositeMode else {
            throw GateError.failed("resize opposite_mode_established=false")
        }
        sawOppositeMode = true
        let groups = descendants(candidate).filter {
            axString($0, kAXRoleAttribute as CFString) == kAXGroupRole &&
                axString($0, kAXDescriptionAttribute as CFString) == "Elysium menus and actions"
        }
        guard groups.count == 1 else { throw GateError.failed("resize group=false") }
        let renewedFields = descendants(groups[0]).filter {
            axString($0, kAXRoleAttribute as CFString) == kAXTextFieldRole
        }
        let renewedNames = renewedFields.filter {
            axString($0, kAXDescriptionAttribute as CFString) == "World Name"
        }
        let renewedSeeds = renewedFields.filter {
            axString($0, kAXDescriptionAttribute as CFString) == "Seed"
        }
        guard renewedFields.count == 2, renewedNames.count == 1, renewedSeeds.count == 1,
              !CFEqual(renewedNames[0], nameIdentity),
              axString(nameIdentity, kAXValueAttribute as CFString) == nil,
              axString(renewedNames[0], kAXValueAttribute as CFString) == "acd",
              axString(renewedSeeds[0], kAXValueAttribute as CFString) == "7",
              axBool(renewedNames[0], kAXFocusedAttribute as CFString) == true,
              axBool(renewedSeeds[0], kAXFocusedAttribute as CFString) == false,
              axRange(renewedNames[0], kAXSelectedTextRangeAttribute as CFString)?.location == 3,
              axRange(renewedSeeds[0], kAXSelectedTextRangeAttribute as CFString)?.location == 1 else {
            throw GateError.failed(
                "resize fields=false focus=false expected_name_length=3 expected_name_range=3 " +
                "expected_seed_length=1 expected_seed_range=1")
        }
        let renewedBinding = LaunchPresentationBinding(
            mode: currentMode, displayID: containingDisplays[0], axWindow: candidate,
            cgWindowID: cgWindows[0].id, rectangle: rectangle)
        let sameCandidate = oppositeCandidate.map {
            $0.mode == renewedBinding.mode && $0.displayID == renewedBinding.displayID &&
                CFEqual($0.axWindow, renewedBinding.axWindow) &&
                $0.cgWindowID == renewedBinding.cgWindowID &&
                $0.rectangle == renewedBinding.rectangle
        } ?? false
        if !sameCandidate {
            oppositeCandidate = renewedBinding
            oppositeConsecutive = 0
            oppositeFirstExact = ProcessInfo.processInfo.systemUptime
        }
        oppositeConsecutive += 1
        if oppositeConsecutive >= 4,
           let first = oppositeFirstExact,
           ProcessInfo.processInfo.systemUptime - first >= 0.25 {
            resizedWindow = candidate
            resizedGroup = groups[0]
            resizedName = renewedNames[0]
            break
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    } while ProcessInfo.processInfo.systemUptime < resizeDeadline
    guard let resizedWindow, let resizedGroup, let resizedName else {
        throw GateError.failed("resize semantic_timeout=true")
    }
    stableWindow = resizedWindow
    guard descendants(resizedWindow).contains(where: { CFEqual($0, resizedGroup) }),
          descendants(resizedGroup).contains(where: { CFEqual($0, resizedName) }) else {
        throw GateError.failed("resize renewed_identity=false")
    }
    let finalHandoffSequence = try handoffLedger.beginSurfaceSample()
    try handoffLedger.finishSurfaceSample(sequence: finalHandoffSequence)
    let logTask = Process()
    gateStage = "exception-scan"
    logTask.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    logTask.arguments = ["show", "--last", "5m", "--style", "compact", "--predicate",
                         "processIdentifier == \(app.processIdentifier) AND (eventMessage CONTAINS[c] 'Invalid message sent to event' OR eventMessage CONTAINS[c] 'NSInternalInconsistencyException')"]
    let logPipe = Pipe(); logTask.standardOutput = logPipe; logTask.standardError = FileHandle.nullDevice
    try logTask.run(); logTask.waitUntilExit()
    let exceptionEvidence = String(data: logPipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
    guard logTask.terminationStatus == 0,
          !exceptionEvidence.contains("Invalid message sent to event"),
          !exceptionEvidence.contains("NSInternalInconsistencyException"), !app.isTerminated else {
        throw GateError.failed("AppKit exception or termination")
    }
    guard try hash(releaseURL) == expectedReleaseHash else { throw GateError.failed("release race") }
    try actionLedger.validateComplete()
    try coordinatorSession.wire.send(
        coordinatorSession.connection, type: 6,
        payload: Data(SHA256.hash(data: coordinatorSession.wire.transcript)))
    guard try coordinatorSession.wire.receive(coordinatorSession.connection, type: 7) == Data("bye".utf8),
          wait(5, until: { coordinatorApplication.isTerminated }) else {
        throw GateError.failed("Coordinator terminal handshake")
    }
    try coordinatorSession.cleanup()
    cleanup.run()
    gateStage = "cleanup"
    guard !cleanup.cleanupFailed else {
        throw GateError.failed("cleanup \(cleanup.cleanupFailureReason)")
    }
    guard ProcessStartIdentity.capture(getpid()) == rawDriverStart,
          regularFileIdentity(rawDriverExecutable) == rawDriverFileIdentity,
          (try? hash(rawDriverExecutable)) == rawDriverHash,
          AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        throw GateError.failed("raw Driver terminal identity")
    }
    print("AppKit text-entry integration: PASS fields=2 clipboard_access=0 foreground_driver=verified cleanup=verified")
} catch GateError.failed(let stage) {
    cleanup.run()
    fail("\(gateStage): \(stage)")
} catch {
    cleanup.run()
    fail("\(gateStage): unexpected error")
}
