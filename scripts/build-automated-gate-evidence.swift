#!/usr/bin/env swift
import CryptoKit
import Foundation

struct Entry: Encodable {
    let commandID: String
    let status: Int32
    let passedCount: Int
    let failedCount: Int
    let logFile: String
    let logSHA256: String
    let artifactSHA256: String?
}
struct Manifest: Encodable {
    let schema: String
    let entries: [Entry]
    init(entries: [Entry]) { schema = "AutomatedGateEvidenceV1"; self.entries = entries }
}

do {
    guard CommandLine.arguments.count == 3 else { throw NSError(domain: "usage", code: 1) }
    let rows = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    let entries = try rows.map { row -> Entry in
        guard row.count == 6, let status = Int32(row[1]), let passed = Int(row[2]),
              let failed = Int(row[3]) else { throw NSError(domain: "row", code: 2) }
        let data = try Data(contentsOf: URL(fileURLWithPath: row[4]))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Entry(commandID: row[0], status: status, passedCount: passed,
                     failedCount: failed, logFile: URL(fileURLWithPath: row[4]).lastPathComponent,
                     logSHA256: hash, artifactSHA256: row[5].isEmpty ? nil : row[5])
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(Manifest(entries: entries)).write(
        to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
} catch { FileHandle.standardError.write(Data("gate evidence build failed\n".utf8)); exit(1) }
