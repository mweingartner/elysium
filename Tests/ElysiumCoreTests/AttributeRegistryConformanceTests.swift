// AttributeRegistryConformanceTests.swift — object-graph-attributes (change
// 1a). Spec `attribute-registry` "Registry is internally consistent",
// "Did-you-mean".

import XCTest
@testable import ElysiumCore

final class AttributeRegistryConformanceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    func testNoDuplicateCanonicalNameOrAliasWithinAKind() {
        for kind in ObjectKind.allCases {
            var seen = Set<String>()
            for descriptor in AttributeRegistry.descriptors(for: kind) {
                for name in [descriptor.canonical] + descriptor.aliases {
                    XCTAssertTrue(seen.insert(name).inserted, "duplicate name '\(name)' for kind \(kind)")
                }
            }
        }
    }

    func testEverySummaryIsNonEmptyAndHygieneClean() {
        // `ElysiumCoreTests` cannot import `ElysiumScript` directly
        // (Package.swift), so this checks the same property
        // `ScriptTextHygiene.isClean` enforces (no C0/C1 control characters)
        // without naming that type.
        for descriptor in AttributeRegistry.all {
            XCTAssertFalse(descriptor.summary.isEmpty, "\(descriptor.canonical) has an empty summary")
            XCTAssertLessThanOrEqual(descriptor.summary.utf8.count, 120)
            let hasControlChar = descriptor.summary.unicodeScalars.contains { $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F) }
            XCTAssertFalse(hasControlChar, "\(descriptor.canonical) summary contains a control character")
        }
    }

    func testEveryBlockNameApplicabilityResolvesThroughBidOpt() {
        for descriptor in AttributeRegistry.all {
            guard case .blockNames(let names) = descriptor.applicability else { continue }
            for name in names {
                XCTAssertNotNil(bidOpt(name), "'\(name)' named by \(descriptor.canonical) does not resolve through bidOpt")
            }
        }
    }

    /// Pinned conformance hash — the sorted `<kind>.<canonical>:<valueKind>:
    /// <mutability>` list, hashed. A change to this value on a future PR is
    /// exactly the "the registry table drifted" signal design.md's risk list
    /// names; update it deliberately, never silently.
    /// Test coverage gap 9: pinned to a literal (not merely self-equal across two
    /// computations in the same process, which can never actually observe a real
    /// drift — every table read in one process necessarily sees the same static
    /// data). `PINNED_REGISTRY_HASH` is recomputed and printed by
    /// `testPrintRegistryHashForRepinning` below whenever the table legitimately
    /// changes; update the literal from that output, not by hand.
    private static let pinnedRegistryHash: UInt64 = 0xDE75B48B7B6E89C7

    func testTableConformanceHashIsPinned() {
        var lines: [String] = []
        for kind in ObjectKind.allCases {
            for descriptor in AttributeRegistry.descriptors(for: kind) {
                lines.append("\(kind.rawValue).\(descriptor.canonical):\(valueKindText(descriptor.valueKind)):\(descriptor.mutability)")
            }
        }
        lines.sort()
        let joined = lines.joined(separator: "\n")
        let hash = stableHash(joined)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(hash, stableHash(joined), "stableHash must itself be a pure function of its input")
        XCTAssertEqual(
            hash, Self.pinnedRegistryHash,
            "the built-in attribute table changed — this is a real drift signal, not a false alarm; " +
                "if the change is intentional, re-run testPrintRegistryHashForRepinning and update pinnedRegistryHash"
        )
    }

    /// Not a real test — prints the current table hash to re-derive
    /// `pinnedRegistryHash` above after a genuine, intentional table change.
    /// Excluded from the normal drift assertion so it can never itself fail.
    func testPrintRegistryHashForRepinning() {
        var lines: [String] = []
        for kind in ObjectKind.allCases {
            for descriptor in AttributeRegistry.descriptors(for: kind) {
                lines.append("\(kind.rawValue).\(descriptor.canonical):\(valueKindText(descriptor.valueKind)):\(descriptor.mutability)")
            }
        }
        lines.sort()
        let hash = stableHash(lines.joined(separator: "\n"))
        print("[registry-hash] current table hash = 0x\(String(hash, radix: 16, uppercase: true))")
    }

    private func valueKindText(_ kind: AttrKind) -> String {
        switch kind {
        case .bool: return "bool"
        case .int: return "int"
        case .number: return "number"
        case .string: return "string"
        case .ref: return "ref"
        case .list: return "list"
        case .map: return "map"
        case .item: return "item"
        case .effectList: return "effectList"
        case .enumeration(let values): return "enum(\(values.joined(separator: "|")))"
        }
    }

    private func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a offset basis
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    // MARK: - did-you-mean

    func testDidYouMeanMatrix() {
        XCTAssertEqual(AttributeRegistry.didYouMean(kind: .entity, name: "Health"), ["health"])
        XCTAssertEqual(AttributeRegistry.didYouMean(kind: .entity, name: "healht"), ["health"])
        XCTAssertEqual(AttributeRegistry.didYouMean(kind: .entity, name: "maxhealth"), ["max_health"])
        XCTAssertEqual(AttributeRegistry.didYouMean(kind: .entity, name: "MaxHealth"), ["max_health"])
    }

    func testDidYouMeanAtMostThreeSuggestionsAndDeterministicOrder() {
        let a = AttributeRegistry.didYouMean(kind: .block, name: "fac")
        let b = AttributeRegistry.didYouMean(kind: .block, name: "fac")
        XCTAssertEqual(a, b)
        XCTAssertLessThanOrEqual(a.count, 3)
    }

    /// Security (code) SC-2: `didYouMean` bounds its input to 64 bytes before the
    /// Levenshtein sweep — a name over that bound returns no suggestions at all,
    /// not merely "does not trap" (which the pre-existing huge-name case below
    /// already established without pinning the actual bound).
    func testDidYouMeanBoundedInputNeverTraps() {
        let huge = String(repeating: "x", count: 10_000)
        _ = AttributeRegistry.didYouMean(kind: .entity, name: huge) // must not trap or hang
    }

    func testDidYouMeanRefusesInputOverSixtyFourBytes() {
        let sixtyFour = String(repeating: "h", count: 64)
        // At the bound: still processed normally (may or may not match anything,
        // but must not be short-circuited).
        _ = AttributeRegistry.didYouMean(kind: .entity, name: sixtyFour)
        let sixtyFive = String(repeating: "h", count: 65)
        XCTAssertEqual(AttributeRegistry.didYouMean(kind: .entity, name: sixtyFive), [],
                        "a name over 64 bytes must return no suggestions, per Security (code) SC-2")
    }

    // MARK: - resolve / applies

    func testResolveHandlesIndexedAndKeyedFamilies() {
        XCTAssertNotNil(AttributeRegistry.resolve(kind: .player, name: "inventory[3]"))
        XCTAssertNil(AttributeRegistry.resolve(kind: .player, name: "inventory[abc]"))
        XCTAssertNotNil(AttributeRegistry.resolve(kind: .block, name: "be.items[0]"))
        XCTAssertNotNil(AttributeRegistry.resolve(kind: .world, name: "gamerule.doFireTick"))
        XCTAssertNotNil(AttributeRegistry.resolve(kind: .player, name: "stats.jump"))
    }

    func testFacingNotApplicableToStone() {
        guard let descriptor = AttributeRegistry.resolve(kind: .block, name: "facing") else {
            return XCTFail("facing should be a registry built-in")
        }
        let context = AttributeApplicabilityContext.block(shape: .cube, name: "stone", blockEntityType: nil)
        XCTAssertFalse(AttributeRegistry.applies(descriptor, in: context))
    }

    func testOpenApplicableToDoor() {
        guard let descriptor = AttributeRegistry.resolve(kind: .block, name: "open") else {
            return XCTFail("open should be a registry built-in")
        }
        let context = AttributeApplicabilityContext.block(shape: .door, name: "oak_door", blockEntityType: nil)
        XCTAssertTrue(AttributeRegistry.applies(descriptor, in: context))
    }
}
