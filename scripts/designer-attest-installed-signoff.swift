import AppKit
import Darwin
import Foundation
import ElysiumReleaseGate

private struct DesignerChecklistItem: Decodable {
    let id: String
    let requiresAX: Bool
}
private struct DesignerChecklist: Decodable {
    let version: String
    let items: [DesignerChecklistItem]
}

private func designerWrite(_ data: Data, to url: URL) throws {
    try DurablePrivateFileWriter.write(data, to: url)
}

private func exactObject(_ url: URL, keys: Set<String>) throws -> [String: Any] {
    try ReleaseGateCoordinator.requirePrivateFile(url)
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        as? [String: Any], Set(object.keys) == keys else {
        throw ReleaseGateError.evidence
    }
    return object
}

private func validateSealedInstalledEvidence(
    _ directory: URL, checklist: DesignerChecklist
) throws {
    try ReleaseGateCoordinator.requirePrivateDirectory(directory)
    guard checklist.version == "elysium-installed-text-entry-v2", checklist.items.count == 14,
          Set(checklist.items.map(\.id)).count == checklist.items.count else {
        throw ReleaseGateError.evidence
    }
    for (index, item) in checklist.items.enumerated() {
        let prefix = String(format: "%02d-%@", index + 1, item.id)
        let screenshot = directory.appendingPathComponent("\(prefix).png")
        let command = directory.appendingPathComponent("\(prefix).command.json")
        let operation = directory.appendingPathComponent("\(prefix).operation.log")
        try ReleaseGateCoordinator.requirePrivateFile(screenshot)
        let screenshotData = try Data(contentsOf: screenshot)
        guard let image = NSBitmapImageRep(data: screenshotData),
              image.pixelsWide > 0, image.pixelsHigh > 0 else {
            throw ReleaseGateError.evidence
        }
        let values = try exactObject(command, keys: [
            "schema", "commandID", "captureStatus", "axStatus", "windowID",
            "screenshotSHA256", "axReportSHA256", "operationLogSHA256",
        ])
        try ReleaseGateCoordinator.requirePrivateFile(operation)
        guard values["schema"] as? String == "ElysiumInstalledCommandEvidenceV1",
              values["commandID"] as? String == item.id,
              values["captureStatus"] as? Int == 0,
              values["screenshotSHA256"] as? String ==
                AutomatedGateEvidence.sha256(screenshotData),
              values["operationLogSHA256"] as? String ==
                AutomatedGateEvidence.sha256(try Data(contentsOf: operation)) else {
            throw ReleaseGateError.evidence
        }
        if item.requiresAX {
            let report = directory.appendingPathComponent("\(prefix).ax.json")
            try ReleaseGateCoordinator.requirePrivateFile(report)
            let reportData = try Data(contentsOf: report)
            guard values["axStatus"] as? Int == 0,
                  values["axReportSHA256"] as? String ==
                    AutomatedGateEvidence.sha256(reportData),
                  let reportObject = try JSONSerialization.jsonObject(with: reportData)
                    as? [String: Any],
                  Set(reportObject.keys) == ["schema", "itemID", "windowCount",
                    "elementCount", "focusedCount", "settableValueCount",
                    "finiteFrameCount", "roleCounts"],
                  reportObject["schema"] as? String == "ElysiumInstalledAXEvidenceV1",
                  reportObject["itemID"] as? String == item.id else {
                throw ReleaseGateError.evidence
            }
        } else {
            guard values["axStatus"] as? Int == -1,
                  values["axReportSHA256"] as? String == "" else {
                throw ReleaseGateError.evidence
            }
        }
    }
}

func reviewIndependentDesignerAttestation(
    payload pending: ReleaseGatePayload, directory installed: URL, prompt: String
) throws -> ReleaseGateDesignerFacts {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        throw ReleaseGateError.authorization
    }
    let designerStart = try processStartIdentity(pid: getpid())
    guard pending.state == .observedPendingDesigner,
          pending.designerChallenge != nil,
          let observerPID = pending.observerProcessID,
          let observerStart = pending.observerProcessStart,
          observerPID != getpid() || observerStart != designerStart else {
        throw ReleaseGateError.staleSequence
    }
    try productionValidateCurrent(pending)
    _ = try validateBoundElysiumProcess(pending)
    let checklist = try JSONDecoder().decode(
        DesignerChecklist.self,
        from: Data(contentsOf: URL(fileURLWithPath: "scripts/installed-signoff-checklist-v1.json")))
    try validateSealedInstalledEvidence(installed, checklist: checklist)
    guard try evidenceDigest(evidenceRoot.appendingPathComponent(pending.receiptID)) ==
        pending.evidenceDigest else { throw ReleaseGateError.evidence }

    print("Review the sealed screenshots, AX reports, and operation records in this indexed view.")
    for (index, item) in checklist.items.enumerated() {
        print("Record \(index + 1)/\(checklist.items.count): \(item.id)")
    }
    print("This is a separate Designer gate. Enter no observed field text.")
    print(prompt, terminator: " ")
    fflush(stdout)
    return .init(rawLine: readLine(), processID: getpid(), processStart: designerStart,
                 timestamp: Int64(Date().timeIntervalSince1970))
}
