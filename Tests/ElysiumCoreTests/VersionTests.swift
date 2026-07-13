import Foundation
import XCTest
@testable import ElysiumCore

final class VersionTests: XCTestCase {
    func testElysiumVersionUsesThreePartReleaseString() {
        let parts = ELYSIUM_VERSION.split(separator: ".", omittingEmptySubsequences: false)

        XCTAssertEqual(parts.count, 3)
        for part in parts {
            XCTAssertFalse(part.isEmpty)
            XCTAssertNotNil(Int(part))
        }
    }

    func testBundleVersionMatchesCoreVersion() throws {
        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("packaging/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])

        XCTAssertEqual(dict["CFBundleShortVersionString"] as? String, ELYSIUM_VERSION)
        XCTAssertEqual(dict["CFBundleVersion"] as? String, ELYSIUM_VERSION)
    }
}
