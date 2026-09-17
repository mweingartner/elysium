import Foundation

/// Stable identifiers for the closed, reviewed set of bundled Faithful 64x add-ons.
public enum BundledResourcePackAddOnID: String, Codable, CaseIterable, Sendable {
    case oreBorders64x = "ore-borders-64x"
    case staticLanterns = "static-lanterns"
}

public struct BundledResourcePackAddOnDescriptor: Equatable, Sendable {
    public let id: BundledResourcePackAddOnID
    public let displayName: String
    public let conflictGroup: String?

    public init(id: BundledResourcePackAddOnID, displayName: String, conflictGroup: String?) {
        self.id = id
        self.displayName = displayName
        self.conflictGroup = conflictGroup
    }
}

/// Catalog order is also the deterministic resource-pack layering order.
public let BUNDLED_RESOURCE_PACK_ADD_ONS: [BundledResourcePackAddOnDescriptor] = [
    .init(id: .oreBorders64x, displayName: "Ore Borders 64x", conflictGroup: "ore-appearance"),
    .init(id: .staticLanterns, displayName: "Static Lanterns", conflictGroup: "sea-lantern-animation"),
]

public func sanitizedBundledResourcePackAddOnIDs(_ raw: [String]?) -> [BundledResourcePackAddOnID] {
    guard let raw else { return [] }
    let requested = Set(raw.compactMap(BundledResourcePackAddOnID.init(rawValue:)))
    return BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.id).filter(requested.contains)
}

public enum ResourcePackSelectionEvaluation: Equatable, Sendable {
    case ready([BundledResourcePackAddOnID])
    case conflict(requested: String, active: String)
    case invalid
}

/// Pure interaction policy with an injectable catalog. The app uses the closed shipped catalog;
/// tests may supply descriptors for otherwise-unrepresentable conflict states without changing it.
public struct ResourcePackScreenInteraction: Sendable {
    public let catalog: [BundledResourcePackAddOnDescriptor]

    public init(catalog: [BundledResourcePackAddOnDescriptor] = BUNDLED_RESOURCE_PACK_ADD_ONS) {
        self.catalog = catalog
    }

    public func evaluateToggle(
        selected: [BundledResourcePackAddOnID], requested: BundledResourcePackAddOnID
    ) -> ResourcePackSelectionEvaluation {
        let descriptors = Dictionary(grouping: catalog, by: \.id)
        guard descriptors.values.allSatisfy({ $0.count == 1 }),
              let requestedDescriptor = descriptors[requested]?.first else { return .invalid }
        var candidate = catalog.map(\.id).filter(Set(selected).contains)
        if let index = candidate.firstIndex(of: requested) {
            candidate.remove(at: index)
            return .ready(candidate)
        }
        if let group = requestedDescriptor.conflictGroup,
           let conflicting = candidate.first(where: {
               descriptors[$0]?.first?.conflictGroup == group
           }), let conflictingDescriptor = descriptors[conflicting]?.first {
            return .conflict(requested: requestedDescriptor.displayName,
                             active: conflictingDescriptor.displayName)
        }
        candidate.append(requested)
        let selectedSet = Set(candidate)
        return .ready(catalog.map(\.id).filter(selectedSet.contains))
    }
}

/// Pure toggle reducer. Unknown requested IDs fail closed; unknown/duplicate selected IDs are repaired.
public func evaluateBundledResourcePackToggle(
    selected: [String], requested: String
) -> ResourcePackSelectionEvaluation {
    guard let requestedID = BundledResourcePackAddOnID(rawValue: requested) else { return .invalid }
    return ResourcePackScreenInteraction().evaluateToggle(
        selected: sanitizedBundledResourcePackAddOnIDs(selected), requested: requestedID)
}

public enum ResourcePackPublishedGeneration: Equatable, Sendable {
    case faithful64x(activeAddOns: [BundledResourcePackAddOnID])
    case proceduralFallback(failedPackDisplayName: String)
}

public struct ResourcePackPresentationSnapshot: Equatable, Sendable {
    public let generation: ResourcePackPublishedGeneration
    public let noticeSerial: UInt64
    public let pendingNotice: String?

    public init(generation: ResourcePackPublishedGeneration,
                noticeSerial: UInt64 = 0, pendingNotice: String? = nil) {
        self.generation = generation
        self.noticeSerial = noticeSerial
        self.pendingNotice = pendingNotice.map { String($0.unicodeScalars.prefix(160)) }
    }
}

public enum ResourcePackScreenFocusID: Hashable, Sendable {
    case addOn(BundledResourcePackAddOnID)
    case acknowledge
    case done
}

public enum ResourcePackApplyState: Equatable, Sendable {
    case idle
    case awaitingPresentedFrame(transactionID: UInt64, pack: BundledResourcePackAddOnID)
    case preparing(transactionID: UInt64, pack: BundledResourcePackAddOnID)
}

public struct ResourcePackScreenRow: Equatable, Sendable {
    public let id: ResourcePackScreenFocusID
    public let y: Double
    public let height: Double
}

/// Bounded, stable-ID layout policy for the small add-on catalog.
public struct ResourcePackScreenLayout: Equatable, Sendable {
    public let visibleRows: [ResourcePackScreenRow]
    public let contentHeight: Double
    public let clampedScrollOffset: Double

    public init(viewportHeight: Double, contentTop: Double = 76, contentBottom: Double,
                requestedScrollOffset: Double, rowHeight: Double = 30) {
        let safeTop = contentTop.isFinite ? max(0, contentTop) : 76
        let safeBottom = contentBottom.isFinite ? max(safeTop, contentBottom) : safeTop
        let safeRowHeight = rowHeight.isFinite ? min(64, max(20, rowHeight)) : 30
        let ids = BUNDLED_RESOURCE_PACK_ADD_ONS.map { ResourcePackScreenFocusID.addOn($0.id) }
        contentHeight = Double(ids.count) * safeRowHeight
        let viewport = max(0, safeBottom - safeTop)
        let maximumOffset = max(0, contentHeight - viewport)
        let proposed = requestedScrollOffset.isFinite ? requestedScrollOffset : 0
        let resolvedOffset = min(maximumOffset, max(0, proposed))
        clampedScrollOffset = resolvedOffset
        visibleRows = ids.enumerated().compactMap { index, id in
            let y = safeTop + Double(index) * safeRowHeight - resolvedOffset
            guard y + safeRowHeight > safeTop, y < safeBottom else { return nil }
            return ResourcePackScreenRow(id: id, y: y, height: safeRowHeight)
        }
        _ = viewportHeight // explicit input retained for API symmetry with other screen layouts
    }
}
