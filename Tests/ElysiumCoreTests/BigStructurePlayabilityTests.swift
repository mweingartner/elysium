import XCTest
@testable import ElysiumCore

private struct BigStructurePoint: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

/// Deliberately materializes a complete plan into all air.  Normal generation
/// replays pieces chunk-by-chunk; this focused fixture instead exposes whether
/// the authored structure itself supplies every threshold, tread, and route.
private final class BigStructureFixtureSink: ChunkSink {
    let cx = 0
    let cz = 0
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    private(set) var cells: [BigStructurePoint: UInt16] = [:]
    private(set) var blockEntities: [BESpec] = []
    private(set) var entities: [EntitySpec] = []

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard y >= minY, y < maxY else { return }
        cells[BigStructurePoint(x: x, y: y, z: z)] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard y >= minY, y < maxY else { return 0 }
        return Int(cells[BigStructurePoint(x: x, y: y, z: z)] ?? 0)
    }

    func topY(_ x: Int, _ z: Int) -> Int { minY }
    func addBlockEntity(_ spec: BESpec) { blockEntities.append(spec) }
    func addEntity(_ spec: EntitySpec) { entities.append(spec) }
}

final class BigStructurePlayabilityTests: XCTestCase {
    private let seed: UInt32 = 0x51A7_C0DE

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func fixture(_ structureID: String, context: GenCtx,
                         origin: (x: Int, z: Int), fixtureSeed: UInt32? = nil) throws -> (StructurePlan, BigStructureFixtureSink) {
        let activeSeed = fixtureSeed ?? seed
        let def = try XCTUnwrap(STRUCTURES.first { $0.id == structureID })
        let plan = try XCTUnwrap(def.plan(context, origin.x, origin.z,
                                          Rng(hash2(activeSeed, origin.x, origin.z, def.salt ^ 0x1234))),
                                 "the fixed \(structureID) fixture must plan")
        let sink = BigStructureFixtureSink()
        for (index, piece) in plan.pieces.enumerated() {
            // This is the same per-piece stream as `buildStructuresForChunk`.
            // A global all-air sink is intentional: it removes incidental
            // terrain support while preserving authoring order and RNG input.
            let rng = Rng(hash2(activeSeed,
                                 origin.x &* 1_000_003 &+ index,
                                 origin.z &* 31 &- index,
                                 def.salt ^ 0x9999))
            piece.build(Builder(sink, rng))
        }
        return (plan, sink)
    }

    private func cell(_ x: Int, _ y: Int, _ z: Int, _ sink: BigStructureFixtureSink) -> Int {
        sink.get(x, y, z)
    }

    private func isPlayerClear(_ value: Int) -> Bool { value == 0 }

    private func supportsPlayerFeet(_ value: Int) -> Bool {
        if sturdyTop(value) { return true }
        let id = value >> 4
        return blockDefs.indices.contains(id) && blockDefs[id].shape == .stairs
    }

    private func planBounds(_ plan: StructurePlan) throws -> (x0: Int, x1: Int, y0: Int, y1: Int, z0: Int, z1: Int) {
        (try XCTUnwrap(plan.pieces.map(\.x0).min()) - 3,
         try XCTUnwrap(plan.pieces.map(\.x1).max()) + 3,
         try XCTUnwrap(plan.pieces.map(\.y0).min()) - 3,
         try XCTUnwrap(plan.pieces.map(\.y1).max()) + 3,
         try XCTUnwrap(plan.pieces.map(\.z0).min()) - 3,
         try XCTUnwrap(plan.pieces.map(\.z1).max()) + 3)
    }

    private func reachable(from start: BigStructurePoint, in plan: StructurePlan,
                           sink: BigStructureFixtureSink) throws -> Set<BigStructurePoint> {
        let bounds = try planBounds(plan)
        func canStand(_ point: BigStructurePoint) -> Bool {
            guard point.x >= bounds.x0, point.x <= bounds.x1,
                  point.y >= bounds.y0, point.y <= bounds.y1,
                  point.z >= bounds.z0, point.z <= bounds.z1 else { return false }
            return supportsPlayerFeet(cell(point.x, point.y - 1, point.z, sink))
                && isPlayerClear(cell(point.x, point.y, point.z, sink))
                && isPlayerClear(cell(point.x, point.y + 1, point.z, sink))
        }
        XCTAssertTrue(canStand(start), "fixture start must have support and two clear body cells")
        guard canStand(start) else { return [] }

        var queue = [start]
        var index = 0
        var visited: Set<BigStructurePoint> = [start]
        while index < queue.count {
            let current = queue[index]
            index += 1
            for (dx, dz) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                for nextY in (current.y - 1)...(current.y + 1) {
                    let next = BigStructurePoint(x: current.x + dx, y: nextY, z: current.z + dz)
                    if !visited.contains(next), canStand(next) {
                        visited.insert(next)
                        queue.append(next)
                    }
                }
            }
        }
        return visited
    }

    func testOceanMonumentSpongeRoomHasWaterConnection() throws {
        let context = GenCtx(seed: seed, heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.deepOcean.rawValue },
                             dim: Dim.overworld.rawValue, villageDensity: .none,
                             generationSettingsIdentity: "big-structure-form-fixture")
        let origin = (x: 9, z: 3)
        let (_, sink) = try fixture("ocean_monument", context: context, origin: origin)
        let x0 = origin.x * 16 - 21, z0 = origin.z * 16 - 21, y0 = 39
        let waterID = Int(B.water)
        let start = BigStructurePoint(x: x0 + 4 + 12, y: y0 + 11, z: z0 + 40 - 1)
        let target = BigStructurePoint(x: x0 + 4 + 12, y: y0 + 11, z: z0 + 40 + 1)

        func canSwim(_ point: BigStructurePoint) -> Bool {
            let value = cell(point.x, point.y, point.z, sink)
            return value == 0 || value >> 4 == waterID
        }
        XCTAssertTrue(canSwim(start))
        XCTAssertEqual(cell(x0 + 16, y0 + 11, z0 + 40, sink) >> 4, waterID,
                       "sponge-room arch must be water, not a sealed prismarine wall")
        XCTAssertTrue(canSwim(target))

        var queue = [start]
        var index = 0
        var visited: Set<BigStructurePoint> = [start]
        while index < queue.count {
            let current = queue[index]
            index += 1
            for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let next = BigStructurePoint(x: current.x + dx, y: current.y + dy, z: current.z + dz)
                guard next.x >= x0, next.x <= x0 + 57,
                      next.y >= y0, next.y <= y0 + 17,
                      next.z >= z0, next.z <= z0 + 57 else { continue }
                if !visited.contains(next), canSwim(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
        }
        XCTAssertTrue(visited.contains(target), "the monument water circuit must reach the sponge room")
    }

    func testFortressBranchesHaveBackedThresholdsAndRoutes() throws {
        let context = GenCtx(seed: seed, heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.netherWastes.rawValue },
                             dim: Dim.nether.rawValue, villageDensity: .none,
                             generationSettingsIdentity: "big-structure-form-fixture")
        let origin = (x: -14, z: 9)
        let (plan, sink) = try fixture("fortress", context: context, origin: origin)
        let baseY = try XCTUnwrap(plan.pieces.first).y0 + 6
        let root = BigStructurePoint(x: origin.x * 16 + 8, y: baseY + 1, z: origin.z * 16 + 8)
        let visited = try reachable(from: root, in: plan, sink: sink)

        let blaze = try XCTUnwrap(sink.blockEntities.first {
            $0.kind == "spawner" && $0.data["mob"] == .str("blaze")
        }, "fixture must retain a blaze platform")
        let blazeBaseY = blaze.y - 3
        var blazeLanding: BigStructurePoint?
        for dir in 0..<4 {
            let entryX = blaze.x - FACE_DX[dir] * 3, entryZ = blaze.z - FACE_DZ[dir] * 3
            let landing = BigStructurePoint(x: entryX + FACE_DX[dir], y: blazeBaseY + 2,
                                            z: entryZ + FACE_DZ[dir])
            if cell(entryX, blazeBaseY, entryZ, sink) >> 4 == Int(B.nether_brick_stairs) {
                XCTAssertTrue(sturdyTop(cell(entryX, blazeBaseY - 1, entryZ, sink)),
                              "blaze threshold stair must have direct support")
                XCTAssertEqual(cell(entryX, blazeBaseY + 1, entryZ, sink), 0,
                               "blaze threshold needs clear body space")
                XCTAssertEqual(cell(entryX, blazeBaseY + 2, entryZ, sink), 0,
                               "blaze threshold needs clear headroom")
                blazeLanding = landing
                break
            }
        }
        let confirmedBlazeLanding = try XCTUnwrap(blazeLanding)
        XCTAssertTrue(visited.contains(confirmedBlazeLanding),
                      "root crossing must lead onto the blaze platform's deck")

        let wartChest = try XCTUnwrap(sink.blockEntities.first {
            $0.kind == "chest_loot" && $0.data["lootTable"] == .str("nether_fortress")
        }, "fixture must retain a nether-wart room")
        let roomCenter = (x: wartChest.x - 3, z: wartChest.z - 3)
        let wartBaseY = wartChest.y - 2
        var wartLanding: BigStructurePoint?
        for dir in 0..<4 {
            let entryX = roomCenter.x - FACE_DX[dir] * 4
            let entryZ = roomCenter.z - FACE_DZ[dir] * 4
            let landing = BigStructurePoint(x: entryX + FACE_DX[dir], y: wartBaseY + 2,
                                            z: entryZ + FACE_DZ[dir])
            if cell(entryX, wartBaseY, entryZ, sink) >> 4 == Int(B.nether_brick_stairs) {
                XCTAssertTrue(sturdyTop(cell(entryX, wartBaseY - 1, entryZ, sink)),
                              "wart-room threshold must have direct support")
                XCTAssertEqual(cell(entryX, wartBaseY + 1, entryZ, sink), 0,
                               "wart-room threshold needs clear body space")
                XCTAssertEqual(cell(entryX, wartBaseY + 2, entryZ, sink), 0,
                               "wart-room threshold needs clear headroom")
                XCTAssertEqual(cell(landing.x, wartBaseY + 1, landing.z, sink) >> 4,
                               Int(B.soul_sand), "wart threshold must meet its raised crop bed")
                wartLanding = landing
                break
            }
        }
        let confirmedWartLanding = try XCTUnwrap(wartLanding)
        XCTAssertTrue(visited.contains(confirmedWartLanding),
                      "root crossing must lead through the wart-room doorway")
    }

    func testBastionHasGroundedIngressTreasureThresholdAndVerticalCirculation() throws {
        let context = GenCtx(seed: seed, heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.netherWastes.rawValue },
                             dim: Dim.nether.rawValue, villageDensity: .none,
                             generationSettingsIdentity: "big-structure-form-fixture")
        let origin = (x: 10, z: -71)
        let (plan, sink) = try fixture("bastion", context: context, origin: origin)
        let x0 = origin.x * 16 - 8, z0 = origin.z * 16 - 8
        let y = try XCTUnwrap(plan.pieces.first).y0 + 16
        let entryX = x0 + 16
        let start = BigStructurePoint(x: entryX, y: y, z: z0 - 1)
        let visited = try reachable(from: start, in: plan, sink: sink)

        let stairX = x0 + 3
        for step in 0...13 {
            let stairZ = z0 + 3 + step
            XCTAssertEqual(cell(stairX, y + step, stairZ, sink) >> 4, Int(B.nether_brick_stairs),
                           "bastion spine must retain tread \(step)")
            XCTAssertTrue(sturdyTop(cell(stairX, y + step - 1, stairZ, sink)),
                          "bastion tread \(step) must have direct support")
            XCTAssertEqual(cell(stairX, y + step + 1, stairZ, sink), 0,
                           "bastion stair must retain body clearance")
            XCTAssertEqual(cell(stairX, y + step + 2, stairZ, sink), 0,
                           "bastion stair must retain headroom")
        }

        let treasure = try XCTUnwrap(sink.blockEntities.first {
            $0.kind == "chest_loot" && $0.data["lootTable"] == .str("bastion_treasure")
        })
        let treasureApproach = BigStructurePoint(x: treasure.x - 4, y: y + 1, z: treasure.z)
        XCTAssertTrue(visited.contains(treasureApproach),
                      "the grounded entrance must reach the raised treasure-room threshold")
        let topDeck = BigStructurePoint(x: stairX + 1, y: y + 14, z: z0 + 16)
        XCTAssertTrue(visited.contains(topDeck),
                      "the stair spine must reach the upper authored bridge deck")

        XCTAssertEqual(sink.entities.count, 7,
                       "the Bastion fixture must expose every persistent guard")
        for entity in sink.entities {
            let feetX = Int(entity.x.rounded(.down))
            let feetY = Int(entity.y.rounded(.down))
            let feetZ = Int(entity.z.rounded(.down))
            XCTAssertEqual(entity.data["persistent"], .bool(true),
                           "Bastion guard \(entity.mob) must remain persistent")
            XCTAssertTrue(sturdyTop(cell(feetX, feetY - 1, feetZ, sink)),
                          "Bastion guard \(entity.mob) at (\(feetX), \(feetY), \(feetZ)) must have solid support")
            XCTAssertEqual(cell(feetX, feetY, feetZ, sink), 0,
                           "Bastion guard \(entity.mob) must have clear body space")
            XCTAssertEqual(cell(feetX, feetY + 1, feetZ, sink), 0,
                           "Bastion guard \(entity.mob) must have clear headroom")
        }
    }

    func testEndCityHasSupportedRouteToRoofAndShipCabin() throws {
        let endSeed: UInt32 = 0x51A7_C0DF
        let context = GenCtx(seed: endSeed, heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.endHighlands.rawValue },
                             dim: Dim.end.rawValue, villageDensity: .none,
                             generationSettingsIdentity: "big-structure-form-fixture")
        let origin = (x: 2, z: 48)
        let (plan, sink) = try fixture("end_city", context: context, origin: origin,
                                       fixtureSeed: endSeed)
        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8, baseY = 64
        let start = BigStructurePoint(x: cx, y: baseY, z: cz - 5)
        let visited = try reachable(from: start, in: plan, sink: sink)

        let stairs = sink.cells.filter { $0.value >> 4 == Int(B.purpur_stairs) }
        XCTAssertFalse(stairs.isEmpty, "end city must publish circulation stairs")
        for (point, value) in stairs {
            XCTAssertTrue(sturdyTop(cell(point.x, point.y - 1, point.z, sink)),
                          "purpur stair at \(point) must have direct support")
            XCTAssertEqual(cell(point.x, point.y + 1, point.z, sink), 0,
                           "purpur stair at \(point) must retain body clearance")
            XCTAssertEqual(cell(point.x, point.y + 2, point.z, sink), 0,
                           "purpur stair at \(point) must retain headroom")
            XCTAssertTrue(value >> 4 == Int(B.purpur_stairs))
        }

        let roofChest = try XCTUnwrap(sink.blockEntities.filter {
            $0.kind == "chest_loot" && $0.data["lootTable"] == .str("end_city_treasure")
        }.max { $0.y < $1.y }, "tower roof must retain treasure")
        let roofCandidates = [
            BigStructurePoint(x: roofChest.x - 1, y: roofChest.y, z: roofChest.z),
            BigStructurePoint(x: roofChest.x + 1, y: roofChest.y, z: roofChest.z),
            BigStructurePoint(x: roofChest.x, y: roofChest.y, z: roofChest.z - 1),
            BigStructurePoint(x: roofChest.x, y: roofChest.y, z: roofChest.z + 1),
        ]
        XCTAssertTrue(roofCandidates.contains(where: visited.contains),
                      "the tower entrance and stair flights must reach a roof-loot approach")

        let elytra = try XCTUnwrap(sink.blockEntities.first { $0.kind == "elytra_chest" },
                                   "fixed End-city fixture must include a ship")
        XCTAssertTrue(sturdyTop(cell(elytra.x, elytra.y - 1, elytra.z, sink)),
                      "elytra chest must rest on the cabin floor")
        let shipCandidates = [
            BigStructurePoint(x: elytra.x - 1, y: elytra.y, z: elytra.z),
            BigStructurePoint(x: elytra.x + 1, y: elytra.y, z: elytra.z),
            BigStructurePoint(x: elytra.x, y: elytra.y, z: elytra.z - 1),
            BigStructurePoint(x: elytra.x, y: elytra.y, z: elytra.z + 1),
        ]
        XCTAssertTrue(shipCandidates.contains(where: visited.contains),
                      "roof bridge, ship deck, and cabin arch must reach the elytra chest")
    }
}
