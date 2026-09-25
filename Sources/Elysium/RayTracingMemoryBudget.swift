import Foundation

/// Render-resource policy, not a promise of free system RAM. Metal's recommendation covers the
/// device's complete working set; app-wide allocations and a reserved margin constrain each
/// additional ray-tracing allocation independently of the geometry cache's own cap.
struct RayTracingMemoryBudget {
    static let mebibyte=1_024*1_024
    static let gibibyte=1_024*mebibyte
    static let maximumPolicyBytes=32*gibibyte

    let workingSetBytes: Int
    let policyLimitBytes: Int
    let reservedBytes: Int
    let usesPhysicalMemoryFallback: Bool

    init(recommendedWorkingSet: UInt64,physicalMemory: UInt64) {
        let validRecommendation=recommendedWorkingSet>0 && recommendedWorkingSet<=UInt64(Int.max)
        usesPhysicalMemoryFallback = !validRecommendation
        if validRecommendation {
            workingSetBytes=Int(recommendedWorkingSet)
        } else if physicalMemory>0 && physicalMemory<=UInt64(Int.max) {
            // Missing/broken device advice must not turn all unified RAM into a GPU budget.
            workingSetBytes=Int(physicalMemory/2)
        } else {
            workingSetBytes=Self.gibibyte
        }
        policyLimitBytes=min(Self.maximumPolicyBytes,workingSetBytes/4)
        reservedBytes=min(workingSetBytes/2,
            max(64*Self.mebibyte,min(2*Self.gibibyte,workingSetBytes/16)))
    }

    struct Availability {
        let policyLimitBytes: Int
        let effectiveBudgetBytes: Int
        let additionalBytes: Int
        let deviceHeadroomBytes: Int
    }

    func availability(deviceAllocatedBytes: Int,trackedBytes: Int) -> Availability {
        let allocated=max(0,deviceAllocatedBytes), tracked=max(0,trackedBytes)
        let usable=max(0,workingSetBytes-reservedBytes)
        let headroom=allocated<usable ? usable-allocated:0
        let remaining=tracked<policyLimitBytes ? policyLimitBytes-tracked:0
        let additional=min(remaining,headroom)
        return Availability(policyLimitBytes:policyLimitBytes,
            effectiveBudgetBytes:min(policyLimitBytes,Self.saturatingAdd(tracked,headroom)),
            additionalBytes:additional,deviceHeadroomBytes:headroom)
    }

    static func saturatingAdd(_ lhs: Int,_ rhs: Int) -> Int {
        let (value,overflow)=max(0,lhs).addingReportingOverflow(max(0,rhs))
        return overflow ? Int.max:value
    }
}
