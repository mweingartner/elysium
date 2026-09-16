import XCTest
@testable import ElysiumCore

private struct MineshaftPoint: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

private struct MineshaftStairRow: Hashable {
    let y: Int
    let facing: Int
    /// The corridor-axis coordinate; the remaining coordinate is the three-wide row.
    let axis: Int
}

/// An all-air materialization makes every safe tread and loot support an
/// authored requirement.  It deliberately uses the production per-piece RNG
/// derivation while avoiding accidental terrain support in the assertion.
private final class MineshaftFixtureSink: ChunkSink {
    let cx = 0
    let cz = 0
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    private(set) var cells: [MineshaftPoint: UInt16] = [:]
    private(set) var blockEntities: [BESpec] = []
    private(set) var entities: [EntitySpec] = []

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard y >= minY, y < maxY else { return }
        cells[MineshaftPoint(x: x, y: y, z: z)] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard y >= minY, y < maxY else { return 0 }
        return Int(cells[MineshaftPoint(x: x, y: y, z: z)] ?? 0)
    }

    func topY(_ x: Int, _ z: Int) -> Int { minY }
    func addBlockEntity(_ spec: BESpec) { blockEntities.append(spec) }
    func addEntity(_ spec: EntitySpec) { entities.append(spec) }
}

final class MineshaftGenerationTests: XCTestCase {
    private let seed: UInt32 = 0x51A7_C0DE
    private let origins = [
        (x: 0, z: 0), (x: 1, z: 0), (x: 0, z: 1), (x: -1, z: 0),
        (x: 0, z: -1), (x: 2, z: 1), (x: -2, z: -1), (x: 3, z: -2),
    ]

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func fixture(_ origin: (x: Int, z: Int)) throws -> (StructurePlan, MineshaftFixtureSink) {
        let context = GenCtx(seed: seed, heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.plains.rawValue },
                             dim: Dim.overworld.rawValue, villageDensity: .none,
                             generationSettingsIdentity: "mineshaft-form-fixture")
        let def = try XCTUnwrap(STRUCTURES.first { $0.id == "mineshaft" })
        let plan = try XCTUnwrap(def.plan(context, origin.x, origin.z,
                                          Rng(hash2(seed, origin.x, origin.z,
                                                   def.salt ^ 0x1234))),
                                 "fixed mineshaft fixture must plan")
        let sink = MineshaftFixtureSink()
        for (index, piece) in plan.pieces.enumerated() {
            let pieceRNG = Rng(hash2(seed,
                                     origin.x &* 1_000_003 &+ index,
                                     origin.z &* 31 &- index,
                                     def.salt ^ 0x9999))
            piece.build(Builder(sink, pieceRNG))
        }
        return (plan, sink)
    }

    private func matchingFixture(_ predicate: (MineshaftFixtureSink) -> Bool) throws
        -> (origin: (x: Int, z: Int), plan: StructurePlan, sink: MineshaftFixtureSink) {
        for origin in origins {
            let (plan, sink) = try fixture(origin)
            if predicate(sink) { return (origin, plan, sink) }
        }
        throw NSError(domain: "MineshaftGenerationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "no deterministic mineshaft fixture satisfied the focused form predicate"])
    }

    private func valueAt(_ point: MineshaftPoint, _ sink: MineshaftFixtureSink) -> Int {
        sink.get(point.x, point.y, point.z)
    }

    private func isPassable(_ value: Int) -> Bool {
        guard value >= 0 else { return false }
        if value == 0 { return true }
        let id = value >> 4
        guard blockDefs.indices.contains(id) else { return false }
        switch blockDefs[id].shape {
        case .rail, .torch, .web:
            return true
        default:
            return false
        }
    }

    private func supportsFeet(_ value: Int) -> Bool {
        guard value >= 0 else { return false }
        if sturdyTop(value) { return true }
        let id = value >> 4
        return blockDefs.indices.contains(id) && blockDefs[id].shape == .stairs
    }

    private func bounds(_ plan: StructurePlan) throws
        -> (x0: Int, x1: Int, y0: Int, y1: Int, z0: Int, z1: Int) {
        (try XCTUnwrap(plan.pieces.map(\.x0).min()) - 2,
         try XCTUnwrap(plan.pieces.map(\.x1).max()) + 2,
         try XCTUnwrap(plan.pieces.map(\.y0).min()) - 2,
         try XCTUnwrap(plan.pieces.map(\.y1).max()) + 2,
         try XCTUnwrap(plan.pieces.map(\.z0).min()) - 2,
         try XCTUnwrap(plan.pieces.map(\.z1).max()) + 2)
    }

    private func reachable(from start: MineshaftPoint, plan: StructurePlan,
                           sink: MineshaftFixtureSink) throws -> Set<MineshaftPoint> {
        let limit = try bounds(plan)
        func canStand(_ point: MineshaftPoint) -> Bool {
            guard point.x >= limit.x0, point.x <= limit.x1,
                  point.y >= limit.y0, point.y <= limit.y1,
                  point.z >= limit.z0, point.z <= limit.z1 else { return false }
            return supportsFeet(sink.get(point.x, point.y - 1, point.z))
                && isPassable(sink.get(point.x, point.y, point.z))
                && isPassable(sink.get(point.x, point.y + 1, point.z))
        }
        XCTAssertTrue(canStand(start), "central mineshaft floor must be a valid start")
        guard canStand(start) else { return [] }

        var queue = [start]
        var cursor = 0
        var visited: Set<MineshaftPoint> = [start]
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for (dx, dz) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                for nextY in (current.y - 1)...(current.y + 1) {
                    let next = MineshaftPoint(x: current.x + dx, y: nextY,
                                              z: current.z + dz)
                    if !visited.contains(next), canStand(next) {
                        visited.insert(next)
                        queue.append(next)
                    }
                }
            }
        }
        return visited
    }

    func testVerticalMineshaftBranchesUseSupportedThreeWideStairRamps() throws {
        let fixture = try matchingFixture { sink in
            sink.cells.values.contains { $0 >> 4 == Int(B.oak_stairs) }
        }
        let stairs = fixture.sink.cells.keys.filter {
            fixture.sink.get($0.x, $0.y, $0.z) >> 4 == Int(B.oak_stairs)
        }.sorted { ($0.y, $0.z, $0.x) < ($1.y, $1.z, $1.x) }
        XCTAssertFalse(stairs.isEmpty, "fixture must include at least one elevation branch")
        var rowWidths: [MineshaftStairRow: [Int]] = [:]

        for tread in stairs {
            let value = valueAt(tread, fixture.sink)
            XCTAssertEqual(valueAt(MineshaftPoint(x: tread.x, y: tread.y - 1, z: tread.z), fixture.sink),
                           Int(cell(B.oak_planks)),
                           "mineshaft ramp tread at \(tread) must own a full plank support")
            XCTAssertEqual(valueAt(MineshaftPoint(x: tread.x, y: tread.y + 1, z: tread.z), fixture.sink), 0,
                           "mineshaft ramp tread at \(tread) needs body clearance")
            XCTAssertEqual(valueAt(MineshaftPoint(x: tread.x, y: tread.y + 2, z: tread.z), fixture.sink), 0,
                           "mineshaft ramp tread at \(tread) needs headroom")

            let facing = value & 3
            let row: MineshaftStairRow
            let crossCoordinate: Int
            if FACE_DZ[facing] != 0 {
                row = MineshaftStairRow(y: tread.y, facing: facing, axis: tread.z)
                crossCoordinate = tread.x
            } else {
                row = MineshaftStairRow(y: tread.y, facing: facing, axis: tread.x)
                crossCoordinate = tread.z
            }
            rowWidths[row, default: []].append(crossCoordinate)
        }
        for (row, rawCoordinates) in rowWidths.sorted(by: {
            ($0.key.y, $0.key.facing, $0.key.axis) < ($1.key.y, $1.key.facing, $1.key.axis)
        }) {
            let coordinates = rawCoordinates.sorted()
            var runStart = 0
            while runStart < coordinates.count {
                var runEnd = runStart + 1
                while runEnd < coordinates.count,
                      coordinates[runEnd] == coordinates[runEnd - 1] + 1 {
                    runEnd += 1
                }
                XCTAssertGreaterThanOrEqual(runEnd - runStart, 3,
                                              "elevation row \(row) at \(coordinates[runStart..<runEnd]) must remain three blocks wide; nearby=\(coordinates.map { coordinate in fixture.sink.get(row.facing < 2 ? coordinate : row.axis, row.y, row.facing < 2 ? row.axis : coordinate) })")
                runStart = runEnd
            }
        }
    }

    func testMineshaftLootChestsHaveSupportedReachableCorridorApproaches() throws {
        let fixture = try matchingFixture { sink in
            sink.blockEntities.contains {
                $0.kind == "chest_loot" && $0.data["lootTable"] == .str("mineshaft")
            }
        }
        let baseY = try XCTUnwrap(fixture.plan.pieces.first).y0 + 1
        let start = MineshaftPoint(x: fixture.origin.x * 16 + 8, y: baseY,
                                   z: fixture.origin.z * 16 + 8)
        let visited = try reachable(from: start, plan: fixture.plan, sink: fixture.sink)
        let chests = fixture.sink.blockEntities.filter {
            $0.kind == "chest_loot" && $0.data["lootTable"] == .str("mineshaft")
        }
        XCTAssertFalse(chests.isEmpty, "fixture must retain planned mineshaft loot")

        for chest in chests {
            XCTAssertEqual(fixture.sink.get(chest.x, chest.y, chest.z) >> 4, Int(B.chest),
                           "loot block entity must retain its chest cell")
            XCTAssertEqual(fixture.sink.get(chest.x, chest.y - 1, chest.z), Int(cell(B.oak_planks)),
                           "mineshaft chest must be grounded on an authored plank floor")
            XCTAssertEqual(fixture.sink.get(chest.x, chest.y + 1, chest.z), 0,
                           "mineshaft chest needs clear opening headroom")
            XCTAssertEqual(fixture.sink.get(chest.x, chest.y + 2, chest.z), 0,
                           "mineshaft chest needs clear opening headroom above")

            let approach = [(0, -1), (0, 1), (-1, 0), (1, 0)].map {
                MineshaftPoint(x: chest.x + $0.0, y: chest.y, z: chest.z + $0.1)
            }
            XCTAssertTrue(approach.contains { visited.contains($0) },
                          "every mineshaft loot chest must have a route from the central corridor")
        }
    }
}
