import XCTest
@testable import ElysiumCore

final class WoodlandMansionGenerationTests: XCTestCase {
    private let seed: UInt32 = 0x4D41_4E53
    /// Reviewed after exact full-footprint terrain admission.  Keep this
    /// literal: scanning for a convenient candidate in a regression test would
    /// hide an accidental change to mansion placement or grounding.
    private let mansionOrigin = (x: -535, z: 241)

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func mansionFixture() throws -> (settings: WorldGenerationSettings,
                                               plan: StructurePlan,
                                               outputs: [String: GenOutput]) {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .darkForest,
                                               villageDensity: .none)
        let mansion = try XCTUnwrap(STRUCTURES.first { $0.id == "woodland_mansion" })
        let generator = overworldGen(seed, settings: settings)
        let oracle = BaseTerrainOracle(seed: seed, settings: settings,
                                       maxCachedChunks: 512, maxQueries: 250_000)
        let context = GenCtx(
            seed: seed,
            heightAt: { x, z in
                oracle.topSolidY(x, z).map { $0 + 1 }
                    ?? generator.refinedHeightEstimate(Double(x), Double(z))
            },
            biomeAt: { x, z in generator.surfaceBiomeAt(Double(x), Double(z)).rawValue },
            dim: Dim.overworld.rawValue,
            villageDensity: .none,
            generationSettingsIdentity: settings.cacheIdentity,
            baseTerrainOracleVersion: baseTerrainOracleVersion,
            terrainOracle: oracle
        )
        let plan = try XCTUnwrap(getPlan(mansion, context, mansionOrigin.x, mansionOrigin.z),
                                 "reviewed dark-forest fixture must retain a grounded mansion")
        let reference = try XCTUnwrap(plan.ref)
        var outputs: [String: GenOutput] = [:]
        for cz in floorDiv(reference.z0, CHUNK_W)...floorDiv(reference.z1, CHUNK_W) {
            for cx in floorDiv(reference.x0, CHUNK_W)...floorDiv(reference.x1, CHUNK_W) {
                outputs["\(cx),\(cz)"] = generateChunk(.overworld, seed, cx, cz, settings: settings)
            }
        }
        return (settings, plan, outputs)
    }

    private func generatedCell(_ x: Int, _ y: Int, _ z: Int,
                               outputs: [String: GenOutput]) -> Int {
        guard y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H else { return -1 }
        let cx = floorDiv(x, CHUNK_W), cz = floorDiv(z, CHUNK_W)
        guard let output = outputs["\(cx),\(cz)"] else { return -1 }
        let lx = x - cx * CHUNK_W, lz = z - cz * CHUNK_W
        return Int(output.blocks[((y - GEN_MIN_Y) * CHUNK_W + lz) * CHUNK_W + lx])
    }

    func testMaterializedMansionHasOpenableEntryAndContinuousThreeFloorPath() throws {
        let fixture = try mansionFixture()
        let reference = try XCTUnwrap(fixture.plan.ref)
        // The reference preserves an eight-block margin around the architectural
        // shell, so recover the authored north-west corner from it.
        let x0 = reference.x0 + 8, z0 = reference.z0 + 8, y = reference.y0 + 8
        let entranceX = x0 + 42 / 2
        let hallX = x0 + 1 + 4 * 8, hallZ = z0 + 1 + 3 * 8
        let doorID = Int(bid("dark_oak_door")), stairID = Int(B.dark_oak_stairs)

        for doorX in (entranceX - 1)...entranceX {
            let lower = generatedCell(doorX, y, z0, outputs: fixture.outputs)
            let upper = generatedCell(doorX, y + 1, z0, outputs: fixture.outputs)
            XCTAssertEqual(lower >> 4, doorID, "mansion front must contain an interactive lower door half")
            XCTAssertEqual(lower & 15, 0, "north entrance door must face north")
            XCTAssertEqual(upper >> 4, doorID, "mansion front must contain a matching upper door half")
            XCTAssertEqual(upper & 15, doorX == entranceX - 1 ? 9 : 8,
                           "double doors must use complementary hinge halves")
            XCTAssertEqual(generatedCell(doorX, y, z0 + 1, outputs: fixture.outputs), 0,
                           "doorway must open onto clear interior space")
            let doorstep = generatedCell(doorX, y - 1, z0 - 1, outputs: fixture.outputs)
            XCTAssertEqual(doorstep >> 4, stairID, "front door must have a real stair approach")
            XCTAssertEqual(doorstep & 3, FACE_OPP[0], "doorstep must rise back toward the north door")
            XCTAssertEqual(generatedCell(doorX, y - 1, z0 - 2, outputs: fixture.outputs) >> 4,
                           Int(B.dirt_path), "approach must join the doorstep with a walkable path")
        }

        // Each six-step flight rises exactly one deck.  The two flights use
        // separate rows in the reserved hall, so the middle landing remains
        // traversable instead of a one-way shaft through an ordinary room.
        for floor in 0..<2 {
            let flightZ = floor == 0 ? hallZ + 1 : hallZ + 6
            let risingEast = floor == 0
            for step in 0..<6 {
                let x = risingEast ? hallX + 1 + step : hallX + 6 - step
                let stairY = y + floor * 6 + step
                let cell = generatedCell(x, stairY, flightZ, outputs: fixture.outputs)
                XCTAssertEqual(cell >> 4, stairID,
                               "floor \(floor + 1) stair flight must materialize every rise")
                XCTAssertEqual(cell & 3, risingEast ? 3 : 2,
                               "stair flight must keep its ascent-facing metadata")
                XCTAssertTrue(sturdyTop(generatedCell(x, stairY - 1, flightZ,
                                                       outputs: fixture.outputs)),
                              "every stair tread must have a direct solid riser below it")
                XCTAssertEqual(generatedCell(x, stairY + 1, flightZ,
                                              outputs: fixture.outputs), 0,
                               "each stair rise must retain player headroom")
            }
            let landing = generatedCell(hallX + 3, y + (floor + 1) * 6 - 1, hallZ + 3,
                                        outputs: fixture.outputs)
            XCTAssertTrue(sturdyTop(landing), "each stair flight must meet a stable floor landing")
        }

        struct Feet: Hashable { let x: Int; let y: Int; let z: Int }
        func isOpenOrOpenableDoor(_ value: Int) -> Bool {
            value == 0 || value >> 4 == doorID
        }
        func supportsPlayerFeet(_ value: Int) -> Bool {
            if sturdyTop(value) { return true }
            let id = value >> 4
            // `sturdyTop` deliberately reserves a full top face for support
            // attachments, whereas a player can walk the raised half of an
            // ordinary stair.  This route model therefore admits stairs while
            // still requiring every other surface to be a real walkable top.
            return blockDefs.indices.contains(id) && blockDefs[id].shape == .stairs
        }
        func canStand(_ point: Feet) -> Bool {
            guard point.x >= x0 + 1, point.x <= x0 + 41,
                  point.z >= z0 - 3, point.z <= z0 + 33,
                  point.y >= y, point.y <= y + 12 else { return false }
            return supportsPlayerFeet(generatedCell(point.x, point.y - 1, point.z, outputs: fixture.outputs))
                && isOpenOrOpenableDoor(generatedCell(point.x, point.y, point.z, outputs: fixture.outputs))
                && isOpenOrOpenableDoor(generatedCell(point.x, point.y + 1, point.z, outputs: fixture.outputs))
        }
        func hasPlayerPath(from start: Feet, to goal: Feet) -> Bool {
            var queue = [start]
            var index = 0
            var visited: Set<Feet> = [start]
            while index < queue.count {
                let current = queue[index]
                index += 1
                if current == goal { return true }
                for (dx, dz) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                    for nextY in (current.y - 1)...(current.y + 1) {
                        let next = Feet(x: current.x + dx, y: nextY, z: current.z + dz)
                        if !visited.contains(next), canStand(next) {
                            visited.insert(next)
                            queue.append(next)
                        }
                    }
                }
            }
            return false
        }
        let outside = Feet(x: entranceX - 1, y: y, z: z0 - 3)
        XCTAssertTrue(canStand(outside), "front path must be a safe starting surface")
        for floor in 0..<3 {
            let target = Feet(x: hallX + 3, y: y + floor * 6, z: hallZ + 3)
            XCTAssertTrue(hasPlayerPath(from: outside, to: target),
                          "opening the front doors must yield a continuous player route to floor \(floor + 1)")
        }
    }

    func testPersistentMansionResidentsHaveFootingAndClearance() throws {
        let fixture = try mansionFixture()
        let residentMobs: Set<String> = ["allay", "vindicator", "evoker"]
        let residents = fixture.outputs.values.flatMap(\.entities).filter {
            residentMobs.contains($0.mob) && $0.data["persistent"] == .bool(true)
        }
        XCTAssertFalse(residents.isEmpty, "materialized mansion fixture must publish persistent residents")
        for mob in residentMobs {
            XCTAssertTrue(residents.contains { $0.mob == mob },
                          "fixture must exercise persistent \(mob) placement")
        }
        for resident in residents {
            let x = Int(resident.x.rounded(.down))
            let y = Int(resident.y.rounded(.down))
            let z = Int(resident.z.rounded(.down))
            XCTAssertTrue(sturdyTop(generatedCell(x, y - 1, z, outputs: fixture.outputs)),
                          "persistent \(resident.mob) must have structural footing")
            let clearance = resident.mob == "allay" ? 1 : 2
            for dy in 0...clearance {
                XCTAssertEqual(generatedCell(x, y + dy, z, outputs: fixture.outputs), 0,
                               "persistent \(resident.mob) must have clear body space at height \(dy)")
            }
        }
    }

}
