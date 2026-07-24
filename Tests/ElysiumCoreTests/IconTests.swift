import XCTest
@testable import ElysiumCore

final class IconTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    private func alphaMask(_ pixels: [UInt8]) -> [Bool] {
        stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] != 0 }
    }

    @discardableResult private func install(_ atlas: BuiltAtlas = buildAtlas(),
                                             overrides: [String: [UInt8]] = [:]) -> UInt64 {
        publishIconSourceSnapshot(IconSourceCandidate(atlas: atlas, itemOverrides: overrides)!)
    }

    func testReportedSpruceFamilyUsesDistinctShapeSilhouettes() {
        registerCoreIfNeeded()
        let atlas = buildAtlas()
        install(atlas)

        let names = ["spruce_planks", "spruce_pressure_plate", "spruce_slab", "spruce_stairs",
                     "spruce_fence_gate", "spruce_sign", "spruce_trapdoor", "spruce_wood"]
        let masks = names.map { alphaMask(itemIconPixels(iid($0))) }
        // Planks and wood are both full cubes and distinguish by registered face art; every
        // geometry-changing member must additionally have a distinct alpha silhouette.
        XCTAssertEqual(Set(masks.dropLast().map { $0.map { $0 ? "1" : "0" }.joined() }).count,
                       names.count - 1)
        XCTAssertNotEqual(itemIconPixels(iid("spruce_planks")), itemIconPixels(iid("spruce_wood")))
        for pixels in names.map({ itemIconPixels(iid($0)) }) {
            XCTAssertEqual(pixels.count, 16 * 16 * 4)
            XCTAssertTrue(alphaMask(pixels).contains(true))
        }
    }

    func testInvalidIdentityAndGeometryFailToDeterministicMissingIcon() {
        registerCoreIfNeeded()
        let atlas = buildAtlas()
        install(atlas)

        let low = itemIconPixels(-1)
        XCTAssertEqual(low, itemIconPixels(itemDefs.count))
        XCTAssertEqual(low.count, 1024)
        XCTAssertTrue(alphaMask(low).contains(true))

        let invalidBoxes = [
            AABB(.nan, 0, 0, 1, 1, 1),
            AABB(0, 0, 0, .infinity, 1, 1),
            AABB(0, 0, 0, 0, 1, 1),
            AABB(0, 0, 0, 2, 1, 1),
        ]
        for box in invalidBoxes {
            var pixels = [UInt8](repeating: 0, count: 1024)
            XCTAssertFalse(drawIsometricShape(&pixels, boxes: [box], topTile: 0,
                                               leftTile: 0, rightTile: 0, tint: nil, atlas: atlas))
            XCTAssertFalse(alphaMask(pixels).contains(true))
        }
        var overLimit = [UInt8](repeating: 0, count: 1024)
        var atLimit = [UInt8](repeating: 0, count: 1024)
        let visibleTile = atlas.pixels.firstIndex { pixels in
            stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 }
        } ?? 0
        XCTAssertTrue(drawIsometricShape(&atLimit,
                                          boxes: Array(repeating: AABB(0, 0, 0, 1, 1, 1), count: 256),
                                          topTile: visibleTile, leftTile: visibleTile,
                                          rightTile: visibleTile, tint: nil, atlas: atlas))
        XCTAssertFalse(drawIsometricShape(&overLimit,
                                           boxes: Array(repeating: AABB(0, 0, 0, 1, 1, 1), count: 257),
                                           topTile: 0, leftTile: 0, rightTile: 0, tint: nil, atlas: atlas))
        XCTAssertEqual(iconMaximumShapeBoxes, 256)
        XCTAssertEqual(iconMaximumCandidateFaces, 1_536)
        XCTAssertEqual(iconMaximumFacePixelTests, 393_216)

        for count in [0, 1023, 1025] {
            var destination = [UInt8](repeating: 7, count: count)
            let original = destination
            XCTAssertFalse(drawIsometricShape(&destination, boxes: [AABB(0, 0, 0, 1, 1, 1)],
                                               topTile: visibleTile, leftTile: visibleTile,
                                               rightTile: visibleTile, tint: nil, atlas: atlas))
            XCTAssertEqual(destination, original)
        }
    }

    func testConcurrentReadersObserveOnlyCompletePublishedSnapshots() throws {
        registerCoreIfNeeded()
        let atlas = buildAtlas()
        var old = [UInt8](repeating: 0, count: 1024)
        old[3] = 255
        install(atlas, overrides: ["spruce_slab": old])
        XCTAssertEqual(itemIconPixels(iid("spruce_slab")), old)

        var next = [UInt8](repeating: 0, count: 1024)
        next[0] = 99; next[3] = 255
        let candidate = try XCTUnwrap(IconSourceCandidate(atlas: atlas,
                                                           itemOverrides: ["spruce_slab": next]))
        let lock = NSLock()
        var observed: [[UInt8]] = []
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index == 16 { publishIconSourceSnapshot(candidate) }
            let value = itemIconPixels(iid("spruce_slab"))
            lock.lock(); observed.append(value); lock.unlock()
        }
        XCTAssertTrue(observed.allSatisfy { $0 == old || $0 == next })
        XCTAssertEqual(itemIconPixels(iid("spruce_slab")), next)
    }

    func testInvalidGenerationCandidateRetainsPriorGeneration() {
        registerCoreIfNeeded()
        var old = [UInt8](repeating: 0, count: 1024)
        old[3] = 255
        let atlas = buildAtlas()
        install(atlas, overrides: ["spruce_slab": old])
        XCTAssertNil(IconSourceCandidate(
            atlas: BuiltAtlas(count: 1, pixels: [[1, 2, 3]], missing: []),
            itemOverrides: [:]))
        XCTAssertEqual(itemIconPixels(iid("spruce_slab")), old)
    }

    func testAppPackPublicationRejectsOffMainAndReentrantEntry() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Elysium/ResourcePacks.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("guard Thread.isMainThread, !iconPackPublicationActive"))
        XCTAssertTrue(source.contains("iconPackPublicationActive = true"))
        XCTAssertTrue(source.contains("defer { iconPackPublicationActive = false }"))
        XCTAssertTrue(source.contains("failNextIconPackPublicationBeforeMutation"))
        XCTAssertTrue(source.contains("iconPackPublicationHook?(.uiWorldInstalled)"))
        XCTAssertTrue(source.contains("iconPackPublicationHook?(.coreCommitted)"))
        let publicationStart = try XCTUnwrap(
            source.range(of: "final class StagedResourcePackPublication"))
        let publicationEnd = try XCTUnwrap(
            source.range(of: "func validateResourcePackStack", range: publicationStart.upperBound..<source.endIndex))
        let publication = publicationStart.lowerBound..<publicationEnd.lowerBound
        let install = try XCTUnwrap(
            source.range(of: "renderer.installStagedWorldAtlas(world)", range: publication))
        let commit = try XCTUnwrap(
            source.range(of: "let generation = publishIconSourceSnapshot(candidate)", range: publication))
        let record = try XCTUnwrap(
            source.range(of: "recordUIIconGeneration(generation)", range: publication))
        XCTAssertLessThan(install.lowerBound, commit.lowerBound,
                          "UI/world B must install while Core readers still see A")
        XCTAssertLessThan(commit.lowerBound, record.lowerBound,
                          "matching generation is recorded only after the Core commit")
        XCTAssertTrue(source.contains("currentIconSourceGeneration() == generation"))
        XCTAssertTrue(source.contains("currentUIIconGeneration() == generation"))
        XCTAssertTrue(source.contains("renderer.currentWorldIconGeneration() == generation"))
    }

    func testMalformedOverrideFallsBackAndOverrideChangeInvalidatesCache() {
        registerCoreIfNeeded()
        let atlas = buildAtlas()

        install(atlas)
        let generated = itemIconPixels(iid("spruce_slab"))
        for count in [1023, 1025] {
            install(atlas, overrides: ["spruce_slab": [UInt8](repeating: 1, count: count)])
            XCTAssertEqual(itemIconPixels(iid("spruce_slab")), generated,
                           "non-1024-byte source must be excluded before publication")
        }

        var explicit = [UInt8](repeating: 0, count: 1024)
        explicit[0] = 12; explicit[1] = 34; explicit[2] = 56; explicit[3] = 255
        install(atlas, overrides: ["spruce_slab": explicit])
        XCTAssertEqual(itemIconPixels(iid("spruce_slab")), explicit)
        XCTAssertNotEqual(generated, explicit)
    }

    func testTorchLanternAndChainBlockItemsUseThreeDimensionalIcons() {
        registerCoreIfNeeded()

        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.torch)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.soul_torch)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.lantern)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.soul_lantern)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.chain)))
    }

    func testFlatAndEffectBlockItemsStayFlatIcons() {
        registerCoreIfNeeded()

        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.stone)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.short_grass)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.vine)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.water)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.fire)))
    }

    func testFlyingWandUsesTorchIconAndDiamondSwordCombatStats() throws {
        registerCoreIfNeeded()
        install()

        let wand = itemDef(iid(FLYING_WAND_ITEM_NAME))
        let sword = itemDef(iid("diamond_sword"))
        let wandTool = try XCTUnwrap(wand.tool)
        let swordTool = try XCTUnwrap(sword.tool)

        XCTAssertEqual(wand.displayName, "Flying Wand")
        XCTAssertEqual(wand.maxStack, 1)
        XCTAssertEqual(wand.category, "combat")
        XCTAssertEqual(wand.icon, "torch")
        XCTAssertEqual(wandTool.type, swordTool.type)
        XCTAssertEqual(wandTool.tier, swordTool.tier)
        XCTAssertEqual(wandTool.speed, swordTool.speed, accuracy: 0.000_001)
        XCTAssertEqual(wandTool.attackDamage, swordTool.attackDamage, accuracy: 0.000_001)
        XCTAssertEqual(wandTool.attackSpeed, swordTool.attackSpeed, accuracy: 0.000_001)
        XCTAssertEqual(wandTool.durability, swordTool.durability)
        XCTAssertEqual(wandTool.enchantability, swordTool.enchantability)
        XCTAssertEqual(itemIconPixels(wand.id), itemIconPixels(iid("torch")))
    }
}
