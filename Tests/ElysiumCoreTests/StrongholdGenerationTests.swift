import XCTest
@testable import ElysiumCore

private struct StrongholdFixturePoint: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

/// A deliberately unbounded structure sink.  Strongholds are authored from
/// multiple pieces and normally replayed one chunk at a time; this fixture
/// runs those same pieces in their production order over an all-air volume so
/// a route assertion cannot be accidentally satisfied by surrounding terrain.
private final class StrongholdFixtureSink: ChunkSink {
    let cx = 0
    let cz = 0
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    private(set) var cells: [StrongholdFixturePoint: UInt16] = [:]
    private(set) var blockEntities: [BESpec] = []
    private(set) var entities: [EntitySpec] = []

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard y >= minY, y < maxY else { return }
        cells[StrongholdFixturePoint(x: x, y: y, z: z)] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard y >= minY, y < maxY else { return 0 }
        return Int(cells[StrongholdFixturePoint(x: x, y: y, z: z)] ?? 0)
    }

    func topY(_ x: Int, _ z: Int) -> Int { minY }
    func addBlockEntity(_ spec: BESpec) { blockEntities.append(spec) }
    func addEntity(_ spec: EntitySpec) { entities.append(spec) }
}

final class StrongholdGenerationTests: XCTestCase {
    private let seed: UInt32 = 0x5354_524F

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func fixture() throws -> (origin: (x: Int, z: Int), plan: StructurePlan,
                                      sink: StrongholdFixtureSink) {
        let origin = try XCTUnwrap(strongholdPositions(seed).first,
                                   "fixed fixture seed must retain a stronghold")
        let stronghold = try XCTUnwrap(STRUCTURES.first { $0.id == "stronghold" })
        let context = GenCtx(seed: seed,
                             heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.plains.rawValue },
                             dim: Dim.overworld.rawValue,
                             villageDensity: .none,
                             generationSettingsIdentity: "stronghold-form-fixture")
        resetStructurePlanCacheForTesting()
        let plan = try XCTUnwrap(getPlan(stronghold, context, origin.0, origin.1),
                                 "the literal stronghold origin must plan")
        let sink = StrongholdFixtureSink()
        for (index, piece) in plan.pieces.enumerated() {
            // Match `buildStructuresForChunk`'s per-piece deterministic stream
            // while avoiding terrain or chunk-boundary incidental support.
            let rng = Rng(hash2(seed,
                                 origin.0 &* 1_000_003 &+ index,
                                 origin.1 &* 31 &- index,
                                 stronghold.salt ^ 0x9999))
            piece.build(Builder(sink, rng))
        }
        return ((origin.0, origin.1), plan, sink)
    }

    private func cell(_ x: Int, _ y: Int, _ z: Int, _ sink: StrongholdFixtureSink) -> Int {
        sink.get(x, y, z)
    }

    private func supportsPlayerFeet(_ value: Int) -> Bool {
        if sturdyTop(value) { return true }
        let id = value >> 4
        return blockDefs.indices.contains(id) && blockDefs[id].shape == .stairs
    }

    func testStrongholdPlannerAcceptsEveryRingPositionInFixedSeedCorpus() throws {
        let stronghold = try XCTUnwrap(STRUCTURES.first { $0.id == "stronghold" })
        // Literal, deliberately varied seeds exercise the bounded candidate
        // search without discovering a convenient success at test time.
        for corpusSeed: UInt32 in [0, 1, 0x1234_5678, 0xCAFE_BABE, 0xFFFF_FFFF] {
            let context = GenCtx(seed: corpusSeed,
                                 heightAt: { _, _ in 64 },
                                 biomeAt: { _, _ in Biome.plains.rawValue },
                                 dim: Dim.overworld.rawValue,
                                 villageDensity: .none,
                                 generationSettingsIdentity: "stronghold-envelope-\(corpusSeed)")
            resetStructurePlanCacheForTesting()
            for origin in strongholdPositions(corpusSeed) {
                let plan = try XCTUnwrap(getPlan(stronghold, context, origin.0, origin.1),
                                         "every canonical ring position must retain a non-overlapping stronghold plan; seed=\(corpusSeed) origin=\(origin)")
                let centerX = origin.0 * 16 + 8, centerZ = origin.1 * 16 + 8
                for piece in plan.pieces {
                    XCTAssertGreaterThanOrEqual(piece.x0, centerX - 160)
                    XCTAssertLessThanOrEqual(piece.x1, centerX + 160)
                    XCTAssertGreaterThanOrEqual(piece.z0, centerZ - 160)
                    XCTAssertLessThanOrEqual(piece.z1, centerZ + 160)
                }
            }
        }
    }

    func testStrongholdHasConnectedRoomThresholdsAndSupportedPortalApproach() throws {
        let fixture = try fixture()
        let pieces = fixture.plan.pieces
        let minX = try XCTUnwrap(pieces.map(\.x0).min())
        let maxX = try XCTUnwrap(pieces.map(\.x1).max())
        let minY = try XCTUnwrap(pieces.map(\.y0).min())
        let maxY = try XCTUnwrap(pieces.map(\.y1).max())
        let minZ = try XCTUnwrap(pieces.map(\.z0).min())
        let maxZ = try XCTUnwrap(pieces.map(\.z1).max())
        let baseY = try XCTUnwrap(pieces.first).y0 + 1
        let start = StrongholdFixturePoint(x: fixture.origin.x * 16 + 8, y: baseY,
                                           z: fixture.origin.z * 16 + 8)

        let frameID = Int(B.end_portal_frame)
        let frames = fixture.sink.cells.compactMap { point, value -> StrongholdFixturePoint? in
            value >> 4 == frameID ? point : nil
        }
        XCTAssertEqual(frames.count, 12, "portal room must publish its complete twelve-frame ring")
        let frameX0 = try XCTUnwrap(frames.map(\.x).min())
        let frameZ0 = try XCTUnwrap(frames.map(\.z).min())
        let frameY = try XCTUnwrap(frames.map(\.y).first)
        XCTAssertTrue(frames.allSatisfy { $0.y == frameY }, "portal frame ring must be level")

        let roomFloorY = frameY - 1
        let approachZ = frameZ0 - 1
        let roomX = frameX0 - 3, roomZ = frameZ0 - 6
        let stairID = Int(B.stone_brick_stairs)
        for x in (frameX0 + 1)...(frameX0 + 3) {
            let stair = cell(x, roomFloorY, approachZ, fixture.sink)
            XCTAssertEqual(stair >> 4, stairID,
                           "portal approach must contain every authored stair tread")
            XCTAssertEqual(stair & 3, 1, "portal stair must rise south toward the dais")
            XCTAssertTrue(sturdyTop(cell(x, roomFloorY - 1, approachZ, fixture.sink)),
                          "every portal stair tread requires a direct solid support")
            XCTAssertEqual(cell(x, roomFloorY + 1, approachZ, fixture.sink), 0,
                           "portal approach needs clear player body space")
            XCTAssertEqual(cell(x, roomFloorY + 2, approachZ, fixture.sink), 0,
                           "portal approach needs clear player headroom")
            XCTAssertTrue(sturdyTop(cell(x, roomFloorY, frameZ0, fixture.sink)),
                          "the stair must meet the raised portal platform")
        }

        let silverfish = try XCTUnwrap(fixture.sink.blockEntities.first {
            $0.kind == "spawner" && $0.data["mob"] == .str("silverfish")
        })
        XCTAssertEqual(cell(silverfish.x, silverfish.y, silverfish.z, fixture.sink) >> 4,
                       Int(B.spawner), "silverfish spawner must remain a placed block")
        XCTAssertTrue(sturdyTop(cell(silverfish.x, silverfish.y - 1, silverfish.z, fixture.sink)),
                      "silverfish spawner must have a real floor")

        let chestID = Int(B.chest)
        for chest in fixture.sink.blockEntities where chest.kind == "chest_loot" {
            let lootTable = String(describing: chest.data["lootTable"])
            XCTAssertEqual(cell(chest.x, chest.y, chest.z, fixture.sink) >> 4, chestID,
                           "stronghold loot must remain an emitted chest, not an orphaned block entity at \(chest.x),\(chest.y),\(chest.z), loot=\(lootTable)")
            XCTAssertTrue(sturdyTop(cell(chest.x, chest.y - 1, chest.z, fixture.sink)),
                          "every stronghold chest must have authored support")
        }

        func canStand(_ point: StrongholdFixturePoint) -> Bool {
            guard point.x >= minX, point.x <= maxX,
                  point.y >= minY + 1, point.y <= maxY,
                  point.z >= minZ, point.z <= maxZ else { return false }
            return supportsPlayerFeet(cell(point.x, point.y - 1, point.z, fixture.sink))
                && cell(point.x, point.y, point.z, fixture.sink) == 0
                && cell(point.x, point.y + 1, point.z, fixture.sink) == 0
        }

        let startSupport = cell(start.x, start.y - 1, start.z, fixture.sink)
        let startBody = cell(start.x, start.y, start.z, fixture.sink)
        let startHead = cell(start.x, start.y + 1, start.z, fixture.sink)
        XCTAssertTrue(canStand(start), "the spiral shaft must meet the first corridor on a walkable floor; support=\(blockName(startSupport >> 4)) body=\(blockName(startBody >> 4)) head=\(blockName(startHead >> 4))")
        let portalApproach = StrongholdFixturePoint(x: frameX0 + 2, y: roomFloorY + 1,
                                                     z: approachZ)
        XCTAssertTrue(canStand(portalApproach), "portal approach must be a legal player position")
        func hasPortalArch(atX x: Int) -> Bool {
            for z in (roomZ + 3)...(roomZ + 5) {
                for y in roomFloorY...(roomFloorY + 2) where cell(x, y, z, fixture.sink) != 0 {
                    return false
                }
            }
            return true
        }
        let westPortalArch = hasPortalArch(atX: roomX - 1)
        let eastPortalArch = hasPortalArch(atX: roomX + 11)
        XCTAssertNotEqual(westPortalArch, eastPortalArch,
                          "portal room must publish exactly one horizontal three-high entry arch")
        var queue = [start]
        var index = 0
        var visited: Set<StrongholdFixturePoint> = [start]
        while index < queue.count {
            let current = queue[index]
            index += 1
            if current == portalApproach { break }
            for (dx, dz) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                for nextY in (current.y - 1)...(current.y + 1) {
                    let next = StrongholdFixturePoint(x: current.x + dx, y: nextY, z: current.z + dz)
                    if !visited.contains(next), canStand(next) {
                        visited.insert(next)
                        queue.append(next)
                    }
                }
            }
        }
        XCTAssertTrue(visited.contains(portalApproach),
                      "the shaft, corridors, room arches, and portal stairs must form a continuous player route")
    }
}
