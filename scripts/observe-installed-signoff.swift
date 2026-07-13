import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import ElysiumReleaseGate
import Security

private struct ChecklistItem: Decodable { let id: String; let prompt: String; let requiresAX: Bool }
private struct Checklist: Decodable { let version: String; let fixedPasteSentinel: String; let items: [ChecklistItem] }

struct BoundLiveElysiumProcess: Equatable {
    let pid: Int32
    let startIdentity: String
    let executablePath: String
    let cdhash: String
    let requirement: String
}

func processStartIdentity(pid: Int32) throws -> String {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var value = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0,
          size == MemoryLayout<kinfo_proc>.stride else { throw ReleaseGateError.evidence }
    let start = value.kp_proc.p_starttime
    return "\(start.tv_sec).\(start.tv_usec)"
}

func captureBoundElysiumProcess(pid: Int32) throws -> BoundLiveElysiumProcess {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
        throw ReleaseGateError.evidence
    }
    let executable = String(cString: path)
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
        throw ReleaseGateError.authorization
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { throw ReleaseGateError.authorization }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &information) == errSecSuccess,
          let values = information as? [String: Any],
          let unique = values[kSecCodeInfoUnique as String] as? Data else {
        throw ReleaseGateError.authorization
    }
    var requirementRef: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirementRef) == errSecSuccess,
          let requirementRef else { throw ReleaseGateError.authorization }
    var requirementText: CFString?
    guard SecRequirementCopyString(requirementRef, [], &requirementText) == errSecSuccess,
          let requirementText else { throw ReleaseGateError.authorization }
    return BoundLiveElysiumProcess(
        pid: pid, startIdentity: try processStartIdentity(pid: pid),
        executablePath: executable,
        cdhash: unique.map { String(format: "%02x", $0) }.joined(),
        requirement: requirementText as String)
}

func validateBoundElysiumProcess(_ payload: ReleaseGatePayload) throws -> BoundLiveElysiumProcess {
    let expected = payload.artifacts
    guard expected.livePID > 0 else { throw ReleaseGateError.evidence }
    let live = try captureBoundElysiumProcess(pid: expected.livePID)
    guard live.startIdentity == expected.liveStartIdentity,
          live.executablePath == expected.installedExecutablePath,
          live.cdhash == expected.installedCDHash,
          live.requirement == expected.signingRequirement else {
        throw ReleaseGateError.artifact
    }
    let disk = try StableFileHasher.capture(
        URL(fileURLWithPath: live.executablePath), exactCanonicalPath: live.executablePath,
        requireExecutable: true)
    guard disk.sha256 == expected.installedSHA256 else { throw ReleaseGateError.artifact }
    return live
}

func waitForBoundElysiumProcess(expectedExecutable: StableFileIdentity, expectedCDHash: String,
                               expectedRequirement: String) throws -> BoundLiveElysiumProcess {
    let deadline = Date().addingTimeInterval(15)
    repeat {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.briangao.elysium" &&
                $0.bundleURL?.path == "/Applications/Elysium.app"
        }), let live = try? captureBoundElysiumProcess(pid: app.processIdentifier),
           live.executablePath == expectedExecutable.canonicalPath,
           live.cdhash == expectedCDHash, live.requirement == expectedRequirement {
            return live
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    throw ReleaseGateError.evidence
}

private func observerPrompt(_ value: String, expected: String) throws {
    print(value, terminator: " "); fflush(stdout)
    guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
        throw ReleaseGateError.evidence
    }
}
private func observerAXValue(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
}
private func observerDescendants(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = [], queue = [root], index = 0
    while index < queue.count && result.count < 512 {
        let next = observerAXValue(queue[index], kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        index += 1; result.append(contentsOf: next); queue.append(contentsOf: next)
    }
    return result
}
private func privateWrite(_ data: Data, _ url: URL) throws {
    try DurablePrivateFileWriter.write(data, to: url)
}
private func appWindow(payload: ReleaseGatePayload) throws -> (NSRunningApplication, CGWindowID) {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.briangao.elysium" && $0.bundleURL?.path == "/Applications/Elysium.app"
    }), app.isActive, app.processIdentifier == payload.artifacts.livePID else {
        throw ReleaseGateError.evidence
    }
    _ = try validateBoundElysiumProcess(payload)
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = info.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
            ($0[kCGWindowLayer as String] as? Int) == 0
    }
    guard matches.count == 1, let number = matches[0][kCGWindowNumber as String] as? UInt32 else {
        throw ReleaseGateError.evidence
    }
    return (app, number)
}
private func captureWindow(_ id: CGWindowID, to url: URL) throws {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", "\(id)", url.path]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ReleaseGateError.evidence }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try ReleaseGateCoordinator.requirePrivateFile(url)
    let data = try Data(contentsOf: url)
    guard data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
          let image = NSBitmapImageRep(data: data), image.pixelsWide > 0, image.pixelsHigh > 0 else {
        throw ReleaseGateError.evidence
    }
}
private func axReport(pid: pid_t, itemID: String) throws -> Data {
    let app = AXUIElementCreateApplication(pid)
    guard let windows = observerAXValue(app, kAXWindowsAttribute as CFString) as? [AXUIElement],
          windows.count == 1 else { throw ReleaseGateError.evidence }
    let elements = observerDescendants(windows[0])
    var roles: [String: Int] = [:], focused = 0, settableValues = 0, finiteFrames = 0
    for element in elements {
        if let role = observerAXValue(element, kAXRoleAttribute as CFString) as? String {
            roles[role, default: 0] += 1
        }
        if observerAXValue(element, kAXFocusedAttribute as CFString) as? Bool == true { focused += 1 }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { settableValues += 1 }
        if let rawPosition = observerAXValue(element, kAXPositionAttribute as CFString),
           let rawSize = observerAXValue(element, kAXSizeAttribute as CFString),
           CFGetTypeID(rawPosition) == AXValueGetTypeID(),
           CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var position = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
               AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
               [position.x, position.y, size.width, size.height].allSatisfy(\.isFinite) {
                finiteFrames += 1
            }
        }
    }
    let value: [String: Any] = ["schema": "ElysiumInstalledAXEvidenceV1", "itemID": itemID,
        "windowCount": windows.count, "elementCount": elements.count, "focusedCount": focused,
        "settableValueCount": settableValues, "finiteFrameCount": finiteFrames, "roleCounts": roles]
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func verifyManualPaste(pid: pid_t, sentinel: String) throws {
    let app = AXUIElementCreateApplication(pid)
    guard let windows = observerAXValue(app, kAXWindowsAttribute as CFString) as? [AXUIElement], windows.count == 1 else {
        throw ReleaseGateError.evidence
    }
    let names = observerDescendants(windows[0]).filter {
        observerAXValue($0, kAXDescriptionAttribute as CFString) as? String == "World Name"
    }
    guard names.count == 1,
          observerAXValue(names[0], kAXValueAttribute as CFString) as? String == sentinel,
          observerAXValue(names[0], kAXFocusedAttribute as CFString) as? Bool == true else {
        throw ReleaseGateError.evidence
    }
}

func captureIntegratedInstalledObservation(
    payload prepared: ReleaseGatePayload, directory installed: URL
) throws -> ReleaseGateObservationFacts {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, AXIsProcessTrusted() else {
        throw ReleaseGateError.authorization
    }
    guard prepared.state == .prepared, prepared.observationChallenge != nil,
          prepared.designerChallenge != nil,
          prepared.checklistDigest == (try fileDigest("scripts/installed-signoff-checklist-v1.json")),
          prepared.observerDigest == (try observerDigest()) else { throw ReleaseGateError.staleSequence }
    try productionValidateCurrent(prepared)
    let checklist = try JSONDecoder().decode(Checklist.self, from: Data(contentsOf: URL(fileURLWithPath: "scripts/installed-signoff-checklist-v1.json")))
    guard checklist.version == "elysium-installed-text-entry-v2", checklist.items.count == 14,
          Set(checklist.items.map(\.id)).count == checklist.items.count else { throw ReleaseGateError.evidence }
    print("This is pending installed proof, not deployment success. Cancellation invalidates it.")
    print("Preserve clipboard content yourself. Elysium/tooling will not restore it; this tool never performs Paste or reads clipboard bytes.")
    try ReleaseGateCoordinator.ensurePrivateDirectory(installed)

    for (index, item) in checklist.items.enumerated() {
        print("Checklist \(index + 1)/\(checklist.items.count): \(item.prompt)")
        if index == 0 {
            print("Navigate to Create New World, focus the empty World Name field, perform one manual Paste, then return to this terminal after the field updates.")
        }
        try observerPrompt("Type CAPTURE when the installed state is visible:", expected: "CAPTURE")
        let (app, windowID) = try appWindow(payload: prepared)
        if index == 0 { try verifyManualPaste(pid: app.processIdentifier, sentinel: checklist.fixedPasteSentinel) }
        let prefix = String(format: "%02d-%@", index + 1, item.id)
        let screenshot = installed.appendingPathComponent("\(prefix).png")
        try captureWindow(windowID, to: screenshot)
        var axHash = ""
        if item.requiresAX {
            let report = try axReport(pid: app.processIdentifier, itemID: item.id)
            let url = installed.appendingPathComponent("\(prefix).ax.json")
            try privateWrite(report, url); axHash = AutomatedGateEvidence.sha256(report)
        }
        let screenshotHash = try fileDigest(screenshot.path)
        let operationLog = Data("capture=0 ax=\(item.requiresAX ? 0 : -1) screenshot_bytes=\((try Data(contentsOf: screenshot)).count)\n".utf8)
        let operationLogURL = installed.appendingPathComponent("\(prefix).operation.log")
        try privateWrite(operationLog, operationLogURL)
        let command: [String: Any] = ["schema": "ElysiumInstalledCommandEvidenceV1",
            "commandID": item.id, "captureStatus": 0,
            "axStatus": item.requiresAX ? 0 : -1, "windowID": windowID,
            "screenshotSHA256": screenshotHash, "axReportSHA256": axHash,
            "operationLogSHA256": AutomatedGateEvidence.sha256(operationLog)]
        try privateWrite(JSONSerialization.data(withJSONObject: command, options: [.sortedKeys]),
                         installed.appendingPathComponent("\(prefix).command.json"))
        try observerPrompt("After reviewing the captured state, type PASS:", expected: "PASS")
        print("completed=\(index + 1) remaining=\(checklist.items.count - index - 1)")
    }
    _ = try validateBoundElysiumProcess(prepared)
    return .init(processID: getpid(), processStart: try processStartIdentity(pid: getpid()))
}
