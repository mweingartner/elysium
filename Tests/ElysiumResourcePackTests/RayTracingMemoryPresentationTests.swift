import XCTest
@testable import Elysium

final class RayTracingMemoryPresentationTests: XCTestCase {
    func testSummaryDistinguishesRayBudgetTemporaryAndAllGPUAllocations() {
        var diagnostics = RayTracingDiagnostics()
        diagnostics.geometryBytes = 2_147_483_648
        diagnostics.memoryBudgetBytes = 28_862_181_376
        diagnostics.transientGeometryBytes = 536_870_912
        diagnostics.deviceAllocatedBytes = 4_294_967_296
        XCTAssertEqual(rayTracingMemorySummary(diagnostics),
                       "RT memory: 2.00/26.88 GiB (temporary 0.50)  GPU total: 4.00 GiB")
    }
}
