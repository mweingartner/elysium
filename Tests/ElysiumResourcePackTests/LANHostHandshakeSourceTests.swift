// The host builds the world summary for a joining guest on the network queue. Reading the
// script-sound catalog there traps (it is main-actor state), and from 1.3.0 to 1.4.5 that crashed
// the host whenever a guest joined. No test in this target runs a live listener (see
// docs/LAN_TEST_LAB.md), so this pins the shape of the fix in the source: the catalog is read only
// behind a main-thread check, and the handshake uses the summary captured when hosting started.

import Foundation
import XCTest

final class LANHostHandshakeSourceTests: XCTestCase {
    func testTheJoinHandshakeNeverReadsTheSoundCatalogOffTheMainThread() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Elysium/LANTransport.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func makeWorldSummary(playerCount: Int) -> LANWorldSummary {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        let reads = body.components(separatedBy: "\n").filter { $0.contains("scriptSoundNames()") }
        XCTAssertEqual(reads.count, 1, "one read of the sound catalog, in one place")
        XCTAssertTrue(reads.allSatisfy { $0.contains("Thread.isMainThread ?") },
                      "the handshake runs on the network queue: \(reads)")
        // The handshake itself still goes through this function, so the guard is what protects it.
        XCTAssertTrue(source.contains("let summary = makeWorldSummary(playerCount: hostPeers.values.filter { $0.accepted }.count)"))
    }
}
