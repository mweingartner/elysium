import XCTest
@testable import Elysium

@MainActor
final class LANSkillTreeAuthorityTests: XCTestCase {
    func testUsageTreeKeepsHostedRPGClockEnabledAfterClassesRetired() {
        XCTAssertTrue(
            LANMultiplayerManager.hostedRPGClockShouldAdvance(
                legacyClassesEnabled: false,
                hasUsageTreeAuthority: true
            )
        )
        XCTAssertTrue(
            LANMultiplayerManager.hostedRPGClockShouldAdvance(
                legacyClassesEnabled: true,
                hasUsageTreeAuthority: false
            )
        )
        XCTAssertFalse(
            LANMultiplayerManager.hostedRPGClockShouldAdvance(
                legacyClassesEnabled: false,
                hasUsageTreeAuthority: false
            )
        )
    }
}
