import XCTest
@testable import Elysium

final class RayTracingMemoryBudgetTests: XCTestCase {
    private let gib=1_024*1_024*1_024

    func testActual128GiBMacUsesQuarterOfMetalRecommendation() {
        let policy=RayTracingMemoryBudget(recommendedWorkingSet:115_448_725_504,
            physicalMemory:137_438_953_472)
        XCTAssertFalse(policy.usesPhysicalMemoryFallback)
        XCTAssertEqual(policy.policyLimitBytes,28_862_181_376)
        XCTAssertEqual(policy.reservedBytes,2*gib)
        XCTAssertGreaterThan(policy.policyLimitBytes,26*gib)
        XCTAssertLessThan(policy.policyLimitBytes,27*gib)
    }

    func testLargeDeviceStillHas32GiBSafetyCeiling() {
        let policy=RayTracingMemoryBudget(recommendedWorkingSet:UInt64(256*gib),
            physicalMemory:UInt64(512*gib))
        XCTAssertEqual(policy.policyLimitBytes,32*gib)
    }

    func testSmallDeviceIsNotForcedUpToLargeMachineMinimum() {
        let policy=RayTracingMemoryBudget(recommendedWorkingSet:UInt64(6*gib),
            physicalMemory:UInt64(8*gib))
        XCTAssertEqual(policy.policyLimitBytes,3*gib/2)
        XCTAssertEqual(policy.reservedBytes,3*gib/8)
        let tiny=RayTracingMemoryBudget(recommendedWorkingSet:1,physicalMemory:UInt64(8*gib))
        XCTAssertEqual(tiny.policyLimitBytes,0)
        XCTAssertEqual(tiny.availability(deviceAllocatedBytes:0,trackedBytes:0).additionalBytes,0)
    }

    func testInvalidAdviceUsesConservativeBoundedPhysicalFallback() {
        let missing=RayTracingMemoryBudget(recommendedWorkingSet:0,physicalMemory:UInt64(8*gib))
        XCTAssertTrue(missing.usesPhysicalMemoryFallback)
        XCTAssertEqual(missing.workingSetBytes,4*gib)
        XCTAssertEqual(missing.policyLimitBytes,gib)
        let invalid=RayTracingMemoryBudget(recommendedWorkingSet:.max,physicalMemory:.max)
        XCTAssertTrue(invalid.usesPhysicalMemoryFallback)
        XCTAssertEqual(invalid.workingSetBytes,gib)
        XCTAssertEqual(invalid.policyLimitBytes,gib/4)
        let unknown=RayTracingMemoryBudget(recommendedWorkingSet:0,physicalMemory:0)
        XCTAssertEqual(unknown.policyLimitBytes,gib/4)
    }

    func testAppWideHeadroomIncludesOtherRendererAndNeuralAllocations() {
        let policy=RayTracingMemoryBudget(recommendedWorkingSet:UInt64(8*gib),physicalMemory:UInt64(16*gib))
        let normal=policy.availability(deviceAllocatedBytes:5*gib,trackedBytes:gib)
        XCTAssertEqual(normal.policyLimitBytes,2*gib)
        XCTAssertEqual(normal.effectiveBudgetBytes,2*gib)
        XCTAssertEqual(normal.additionalBytes,gib)
        // Only 128 MiB remains after the reserve, even though the RT cap has another GiB.
        let loaded=policy.availability(deviceAllocatedBytes:8*gib-policy.reservedBytes-gib/8,trackedBytes:gib)
        XCTAssertEqual(loaded.deviceHeadroomBytes,gib/8)
        XCTAssertEqual(loaded.additionalBytes,gib/8)
        XCTAssertEqual(loaded.effectiveBudgetBytes,gib+gib/8)
        let exhausted=policy.availability(deviceAllocatedBytes:8*gib,trackedBytes:gib)
        XCTAssertEqual(exhausted.additionalBytes,0)
        XCTAssertEqual(exhausted.effectiveBudgetBytes,gib)
    }

    func testRetiredAndTransientBytesCountUntilReleasedWithoutDoubleCountingDeviceUsage() {
        let policy=RayTracingMemoryBudget(recommendedWorkingSet:UInt64(8*gib),physicalMemory:UInt64(16*gib))
        let busy=policy.availability(deviceAllocatedBytes:5*gib,trackedBytes:2*gib)
        XCTAssertEqual(busy.additionalBytes,0)
        let completed=policy.availability(deviceAllocatedBytes:4*gib,trackedBytes:gib)
        XCTAssertEqual(completed.additionalBytes,gib)
        XCTAssertEqual(completed.effectiveBudgetBytes,2*gib)
    }

    func testPolicyArithmeticHandlesNegativeAndOverflowInputs() {
        let policy=RayTracingMemoryBudget(recommendedWorkingSet:UInt64(Int.max),physicalMemory:UInt64(Int.max))
        let full=policy.availability(deviceAllocatedBytes:Int.max,trackedBytes:Int.max)
        XCTAssertEqual(full.additionalBytes,0)
        XCTAssertEqual(full.effectiveBudgetBytes,32*gib)
        let invalidCounters=policy.availability(deviceAllocatedBytes:-1,trackedBytes:-1)
        XCTAssertEqual(invalidCounters.additionalBytes,32*gib)
        XCTAssertEqual(RayTracingMemoryBudget.saturatingAdd(Int.max,1),Int.max)
        XCTAssertEqual(RayTracingMemoryBudget.saturatingAdd(-1,3),3)
    }
}
