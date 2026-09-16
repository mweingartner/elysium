import XCTest
@testable import ElysiumCore

private struct AncientCityFixturePoint: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

/// Materializes an authored city without incidental terrain so route assertions
/// prove that the city itself supplies its paving, threshold, and clearance.
private final class AncientCityFixtureSink: ChunkSink {
    let cx = 0
    let cz = 0
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    private(set) var cells: [AncientCityFixturePoint: UInt16] = [:]
    private(set) var blockEntities: [BESpec] = []
    private(set) var entities: [EntitySpec] = []

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard y >= minY, y < maxY else { return }
        cells[AncientCityFixturePoint(x: x, y: y, z: z)] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard y >= minY, y < maxY else { return 0 }
        return Int(cells[AncientCityFixturePoint(x: x, y: y, z: z)] ?? 0)
    }

    func topY(_ x: Int, _ z: Int) -> Int { minY }
    func addBlockEntity(_ spec: BESpec) { blockEntities.append(spec) }
    func addEntity(_ spec: EntitySpec) { entities.append(spec) }
}

final class AncientCityGenerationTests: XCTestCase {
    private let origin = (x: 0, z: 0)
    private let literalSeeds: [UInt32] = [0, 1, 0x1234_5678, 0x51A7_C0DE,
                                           0xCAFE_BABE, 0xDEAD_BEEF, 0xFFFF_FFFF]

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func fixture(_ seed: UInt32) throws -> (StructurePlan, AncientCityFixtureSink) {
        let city = try XCTUnwrap(STRUCTURES.first { $0.id == "ancient_city" })
        let context = GenCtx(seed: seed,
                             heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.deepDark.rawValue },
                             dim: Dim.overworld.rawValue,
                             villageDensity: .none,
                             generationSettingsIdentity: "ancient-city-form-fixture")
        let plan = try XCTUnwrap(city.plan(context, origin.x, origin.z,
                                            Rng(hash2(seed, origin.x, origin.z, city.salt ^ 0x1234))),
                                 "literal ancient-city fixture must plan")
        let sink = AncientCityFixtureSink()
        for (index, piece) in plan.pieces.enumerated() {
            // Match production's per-piece random stream while deliberately
            // exposing missing authored support and clearance.
            piece.build(Builder(sink, Rng(hash2(seed,
                                                 origin.x &* 1_000_003 &+ index,
                                                 origin.z &* 31 &- index,
                                                 city.salt ^ 0x9999))))
        }
        return (plan, sink)
    }

    private func cell(_ x: Int, _ y: Int, _ z: Int, _ sink: AncientCityFixtureSink) -> Int {
        sink.get(x, y, z)
    }

    private func supportsPlayerFeet(_ value: Int) -> Bool {
        if sturdyTop(value) { return true }
        let id = value >> 4
        return blockDefs.indices.contains(id) && blockDefs[id].shape == .stairs
    }

    private struct SideBuildingEntry {
        let x: Int
        let wallZ: Int
        let boulevardZ: Int
        let boulevardDirection: Int
        let shell: SideBuildingReservation
        let route: SideBuildingReservation
    }

    /// Mirrors a generated `StructPiece` AABB.  The side-building planner
    /// reserves its expanded shell rather than only the room interior.
    private struct SideBuildingReservation: Equatable {
        let x0: Int, y0: Int, z0: Int
        let x1: Int, y1: Int, z1: Int

        func intersects(_ other: SideBuildingReservation) -> Bool {
            !(x1 < other.x0 || other.x1 < x0
              || y1 < other.y0 || other.y1 < y0
              || z1 < other.z0 || other.z1 < z0)
        }
    }

    /// Mirrors only the plan-time side-building choices.  Piece-local
    /// decoration uses a separate RNG, so this makes every expected doorway
    /// inspectable without coupling the test to cosmetic cell choices.
    private func plannedSideBuildingEntries(_ seed: UInt32, salt: UInt32) -> [SideBuildingEntry] {
        let rng = Rng(hash2(seed, origin.x, origin.z, salt ^ 0x1234))
        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8
        let y = -51
        let centralChamber = SideBuildingReservation(
            x0: cx - 20, y0: y - 3, z0: cz - 12,
            x1: cx + 20, y1: y + 22, z1: cz + 12
        )
        let boulevardReservations = [
            SideBuildingReservation(
                x0: cx - 76, y0: y - 2, z0: cz - 5,
                x1: cx - 20, y1: y + 12, z1: cz + 5
            ),
            SideBuildingReservation(
                x0: cx + 20, y0: y - 2, z0: cz - 5,
                x1: cx + 76, y1: y + 12, z1: cz + 5
            )
        ]
        let protectedShellReservations = [centralChamber] + boulevardReservations
        var entries: [SideBuildingEntry] = []
        var acceptedShells: [SideBuildingReservation] = []
        var acceptedRoutes: [SideBuildingReservation] = []
        for dir in [-1, 1] {
            let count = 3 + rng.nextInt(3)
            for _ in 0..<count {
                let bx = cx + dir * (26 + rng.nextInt(44))
                let side = rng.nextBoolean() ? 1 : -1
                let sideDistance = 7 + rng.nextInt(8)
                let w = 5 + rng.nextInt(5)
                let d = 5 + rng.nextInt(5)
                let h = 4 + rng.nextInt(3)
                let bz = side > 0 ? cz + sideDistance : cz - sideDistance - d
                let entryX = bx + w / 2
                let wallZ = side > 0 ? bz : bz + d
                let shell = SideBuildingReservation(
                    x0: bx - 1, y0: y - 2, z0: bz - 1,
                    x1: bx + w + 1, y1: y + h + 6, z1: bz + d + 1
                )
                let route = SideBuildingReservation(
                    x0: entryX - 1, y0: y - 1,
                    z0: min(wallZ, cz + side * 3),
                    x1: entryX + 1, y1: y + 2,
                    z1: max(wallZ, cz + side * 3)
                )
                let shellCollides = protectedShellReservations.contains { shell.intersects($0) }
                    || acceptedShells.contains { shell.intersects($0) }
                    || acceptedRoutes.contains { shell.intersects($0) }
                let routeCollides = centralChamber.intersects(route)
                    || acceptedShells.contains { route.intersects($0) }
                    || acceptedRoutes.contains { route.intersects($0) }
                guard !shellCollides && !routeCollides else { continue }
                acceptedShells.append(shell)
                acceptedRoutes.append(route)
                entries.append(SideBuildingEntry(
                    x: entryX,
                    wallZ: wallZ,
                    boulevardZ: cz + side * 3,
                    boulevardDirection: dir,
                    shell: shell,
                    route: route
                ))
            }
        }
        return entries
    }

    /// This mirrors the former placement arithmetic only to prove the fixed
    /// corpus contains the regression: a negative-side ruin formerly grew
    /// toward, rather than away from, the boulevard.
    private func legacyPlacementWouldEnterBoulevard(_ seed: UInt32, salt: UInt32) -> Bool {
        let rng = Rng(hash2(seed, origin.x, origin.z, salt ^ 0x1234))
        for _ in [-1, 1] {
            let count = 3 + rng.nextInt(3)
            for _ in 0..<count {
                _ = rng.nextInt(44)
                let side = rng.nextBoolean() ? 1 : -1
                let sideDistance = 7 + rng.nextInt(8)
                _ = rng.nextInt(5)
                let depth = 5 + rng.nextInt(5)
                _ = rng.nextInt(3)
                let legacyStart = side > 0 ? 8 + sideDistance : 8 - sideDistance
                if legacyStart <= 8 + 2 && legacyStart + depth >= 8 - 2 { return true }
            }
        }
        return false
    }

    /// Replays the prior admission rule, which reserved only the interior
    /// room.  Keeping this separate from the current planner proves the fixed
    /// corpus includes an actual expanded-shell/core collision that would
    /// previously have materialized.
    private func legacyExpandedShellWouldReachCentralChamber(_ seed: UInt32,
                                                             salt: UInt32) -> Bool {
        let rng = Rng(hash2(seed, origin.x, origin.z, salt ^ 0x1234))
        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8, y = -51
        let centralChamber = SideBuildingReservation(
            x0: cx - 20, y0: y - 3, z0: cz - 12,
            x1: cx + 20, y1: y + 22, z1: cz + 12
        )
        var acceptedInteriors: [SideBuildingReservation] = []
        var acceptedRoutes: [SideBuildingReservation] = []
        for dir in [-1, 1] {
            let count = 3 + rng.nextInt(3)
            for _ in 0..<count {
                let bx = cx + dir * (26 + rng.nextInt(44))
                let side = rng.nextBoolean() ? 1 : -1
                let sideDistance = 7 + rng.nextInt(8)
                let w = 5 + rng.nextInt(5)
                let d = 5 + rng.nextInt(5)
                let h = 4 + rng.nextInt(3)
                let bz = side > 0 ? cz + sideDistance : cz - sideDistance - d
                let entryX = bx + w / 2
                let wallZ = side > 0 ? bz : bz + d
                let interior = SideBuildingReservation(
                    x0: bx, y0: y - 2, z0: bz,
                    x1: bx + w, y1: y + h + 6, z1: bz + d
                )
                let shell = SideBuildingReservation(
                    x0: bx - 1, y0: y - 2, z0: bz - 1,
                    x1: bx + w + 1, y1: y + h + 6, z1: bz + d + 1
                )
                let route = SideBuildingReservation(
                    x0: entryX - 1, y0: y - 1,
                    z0: min(wallZ, cz + side * 3),
                    x1: entryX + 1, y1: y + 2,
                    z1: max(wallZ, cz + side * 3)
                )
                let interiorCollides = acceptedInteriors.contains { interior.intersects($0) }
                    || acceptedRoutes.contains { interior.intersects($0) }
                let routeCollides = acceptedInteriors.contains { route.intersects($0) }
                guard !interiorCollides && !routeCollides else { continue }
                acceptedInteriors.append(interior)
                acceptedRoutes.append(route)
                if shell.intersects(centralChamber) {
                    return true
                }
            }
        }
        return false
    }

    private func emittedSideRuinShells(_ plan: StructurePlan, y: Int) -> [SideBuildingReservation] {
        plan.pieces.compactMap { piece in
            let xSpan = piece.x1 - piece.x0
            let zSpan = piece.z1 - piece.z0
            guard piece.y0 == y - 2,
                  (y + 10...y + 12).contains(piece.y1),
                  (7...11).contains(xSpan),
                  (7...11).contains(zSpan) else {
                return nil
            }
            return SideBuildingReservation(
                x0: piece.x0, y0: piece.y0, z0: piece.z0,
                x1: piece.x1, y1: piece.y1, z1: piece.z1
            )
        }
    }

    func testExpandedSideRuinShellsReserveCoreAndBoulevardWithoutClosingIngresses() throws {
        let city = try XCTUnwrap(STRUCTURES.first { $0.id == "ancient_city" })
        XCTAssertTrue(literalSeeds.contains {
            legacyExpandedShellWouldReachCentralChamber($0, salt: city.salt)
        }, "fixed corpus must exercise the former expanded-shell core intrusion")

        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8, y = -51
        let centralChamber = SideBuildingReservation(
            x0: cx - 20, y0: y - 3, z0: cz - 12,
            x1: cx + 20, y1: y + 22, z1: cz + 12
        )
        let boulevardReservations = [
            SideBuildingReservation(
                x0: cx - 76, y0: y - 2, z0: cz - 5,
                x1: cx - 20, y1: y + 12, z1: cz + 5
            ),
            SideBuildingReservation(
                x0: cx + 20, y0: y - 2, z0: cz - 5,
                x1: cx + 76, y1: y + 12, z1: cz + 5
            )
        ]

        for seed in literalSeeds {
            let (plan, sink) = try fixture(seed)
            let entries = plannedSideBuildingEntries(seed, salt: city.salt)
            let shells = emittedSideRuinShells(plan, y: y)
            XCTAssertEqual(shells, entries.map { $0.shell },
                           "the plan must emit exactly the shells that survived reservation; seed=\(seed)")

            for (index, shell) in shells.enumerated() {
                XCTAssertFalse(shell.intersects(centralChamber),
                               "side shell must not intrude into the central chamber; seed=\(seed) shell=\(index)")
                XCTAssertFalse(boulevardReservations.contains(where: { shell.intersects($0) }),
                               "side shell must not overlap either boulevard; seed=\(seed) shell=\(index)")
                for laterShell in shells.dropFirst(index + 1) {
                    XCTAssertFalse(shell.intersects(laterShell),
                                   "expanded side shells must not overlap; seed=\(seed)")
                }
            }

            for entry in entries {
                let boulevard = boulevardReservations[entry.boulevardDirection < 0 ? 0 : 1]
                XCTAssertFalse(entry.route.intersects(centralChamber),
                               "an ingress may join its boulevard but never enter the core; seed=\(seed)")
                XCTAssertTrue(entry.route.intersects(boulevard),
                              "every accepted side ruin needs its intentional boulevard contact; seed=\(seed)")
                XCTAssertTrue(plan.pieces.contains {
                    $0.x0 == entry.route.x0 && $0.y0 == entry.route.y0 && $0.z0 == entry.route.z0
                        && $0.x1 == entry.route.x1 && $0.y1 == entry.route.y1 && $0.z1 == entry.route.z1
                }, "accepted ingress must emit its exact route piece; seed=\(seed)")
                for x in entry.route.x0...entry.route.x1 {
                    for z in entry.route.z0...entry.route.z1 {
                        XCTAssertEqual(cell(x, y - 1, z, sink), Int(ElysiumCore.cell(B.deepslate_bricks)),
                                       "ingress floor must survive side-shell reservation; seed=\(seed) x=\(x) z=\(z)")
                        XCTAssertEqual(cell(x, y, z, sink), 0,
                                       "ingress body clearance must survive side-shell reservation; seed=\(seed) x=\(x) z=\(z)")
                        XCTAssertEqual(cell(x, y + 1, z, sink), 0,
                                       "ingress headroom must survive side-shell reservation; seed=\(seed) x=\(x) z=\(z)")
                    }
                }
            }
        }
    }

    func testSideRuinsNeverOverwriteTheRaisedBoulevard() throws {
        let city = try XCTUnwrap(STRUCTURES.first { $0.id == "ancient_city" })
        XCTAssertTrue(literalSeeds.contains { legacyPlacementWouldEnterBoulevard($0, salt: city.salt) },
                      "fixed corpus must exercise the former south-side boulevard intrusion")

        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8, y = -51
        let boulevardX = Array((cx - 75)...(cx - 20)) + Array((cx + 20)...(cx + 75))
        for seed in literalSeeds {
            let (_, sink) = try fixture(seed)
            for x in boulevardX {
                for zOffset in -2...2 {
                    XCTAssertEqual(cell(x, y - 1, cz + zOffset, sink), Int(ElysiumCore.cell(B.deepslate_tiles)),
                                   "side ruins must not replace boulevard paving; seed=\(seed) x=\(x) z=\(cz + zOffset)")
                    XCTAssertEqual(cell(x, y, cz + zOffset, sink), 0,
                                   "boulevard needs clear player body space; seed=\(seed) x=\(x) z=\(cz + zOffset)")
                    XCTAssertEqual(cell(x, y + 1, cz + zOffset, sink), 0,
                                   "boulevard needs clear player headroom; seed=\(seed) x=\(x) z=\(cz + zOffset)")
                }
            }
        }
    }

    func testEverySideRuinHasAnOpenArchRouteAndReachableLoot() throws {
        let city = try XCTUnwrap(STRUCTURES.first { $0.id == "ancient_city" })
        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8, y = -51
        var observedSideLoot = 0
        for seed in literalSeeds {
            let (_, sink) = try fixture(seed)
            let entries = plannedSideBuildingEntries(seed, salt: city.salt)
            XCTAssertFalse(entries.isEmpty)
            for entry in entries {
                let z0 = min(entry.wallZ, entry.boulevardZ)
                let z1 = max(entry.wallZ, entry.boulevardZ)
                for x in (entry.x - 1)...(entry.x + 1) {
                    for z in z0...z1 {
                        XCTAssertEqual(cell(x, y - 1, z, sink), Int(ElysiumCore.cell(B.deepslate_bricks)),
                                       "side ruin route needs an authored floor; seed=\(seed) x=\(x) z=\(z)")
                        XCTAssertEqual(cell(x, y, z, sink), 0,
                                       "side ruin route needs body clearance; seed=\(seed) x=\(x) z=\(z)")
                        XCTAssertEqual(cell(x, y + 1, z, sink), 0,
                                       "side ruin route needs headroom; seed=\(seed) x=\(x) z=\(z)")
                        XCTAssertEqual(cell(x, y + 2, z, sink), 0,
                                       "side ruin arch must remain three blocks tall; seed=\(seed) x=\(x) z=\(z)")
                    }
                }
            }

            func canStand(_ point: AncientCityFixturePoint) -> Bool {
                guard point.x >= cx - 80, point.x <= cx + 80,
                      point.y == y,
                      point.z >= cz - 30, point.z <= cz + 30 else {
                    return false
                }
                return supportsPlayerFeet(cell(point.x, point.y - 1, point.z, sink))
                    && cell(point.x, point.y, point.z, sink) == 0
                    && cell(point.x, point.y + 1, point.z, sink) == 0
            }

            var visited: Set<AncientCityFixturePoint> = []
            var queue: [AncientCityFixturePoint] = []
            for x in Array((cx - 75)...(cx - 20)) + Array((cx + 20)...(cx + 75)) {
                for z in (cz - 2)...(cz + 2) {
                    let start = AncientCityFixturePoint(x: x, y: y, z: z)
                    if canStand(start), visited.insert(start).inserted {
                        queue.append(start)
                    }
                }
            }
            var index = 0
            while index < queue.count {
                let current = queue[index]
                index += 1
                for (dx, dz) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                    let next = AncientCityFixturePoint(x: current.x + dx, y: y, z: current.z + dz)
                    if !visited.contains(next), canStand(next) {
                        visited.insert(next)
                        queue.append(next)
                    }
                }
            }

            let sideLoot = sink.blockEntities.filter {
                $0.kind == "chest_loot" && $0.data["lootTable"] == .str("ancient_city") && $0.y == y
            }
            observedSideLoot += sideLoot.count
            for chest in sideLoot {
                XCTAssertEqual(cell(chest.x, chest.y, chest.z, sink) >> 4, Int(B.chest),
                               "side-ruin loot metadata must still match a real chest")
                XCTAssertTrue(supportsPlayerFeet(cell(chest.x, chest.y - 1, chest.z, sink)),
                              "side-ruin chest needs direct footing")
                XCTAssertEqual(cell(chest.x, chest.y + 1, chest.z, sink), 0,
                               "side-ruin chest lid needs clearance")
                let approaches = [(0, -1), (0, 1), (-1, 0), (1, 0)].map {
                    AncientCityFixturePoint(x: chest.x + $0.0, y: chest.y, z: chest.z + $0.1)
                }
                XCTAssertTrue(approaches.contains(where: visited.contains),
                              "side-ruin loot must be reachable from its boulevard route; seed=\(seed) chest=\(chest.x),\(chest.y),\(chest.z)")
            }
        }
        XCTAssertGreaterThan(observedSideLoot, 0,
                             "fixed corpus must exercise side-ruin loot accessibility")
    }

    func testIceBoxHasSupportedStairIngressFromCentralChamber() throws {
        let (_, sink) = try fixture(0x51A7_C0DE)
        let cx = origin.x * 16 + 8, cz = origin.z * 16 + 8, y = -51
        let stair = Int(ElysiumCore.cell(B.stone_brick_stairs, 0))
        for x in (cx - 11)...(cx - 9) {
            XCTAssertEqual(cell(x, y, cz - 14, sink), stair,
                           "ice-box threshold must use a north-rising stair")
            XCTAssertTrue(sturdyTop(cell(x, y - 1, cz - 14, sink)),
                          "every ice-box stair tread needs a direct solid support")
            XCTAssertEqual(cell(x, y + 1, cz - 14, sink), 0,
                           "ice-box stair needs clear body space")
            XCTAssertEqual(cell(x, y + 2, cz - 14, sink), 0,
                           "ice-box stair needs clear headroom")
            for z in (cz - 13)...(cz - 11) {
                XCTAssertEqual(cell(x, y - 1, z, sink), Int(ElysiumCore.cell(B.deepslate_bricks)),
                               "short ingress corridor must retain a paved floor")
                XCTAssertEqual(cell(x, y, z, sink), 0)
                XCTAssertEqual(cell(x, y + 1, z, sink), 0)
            }
        }

        let chest = try XCTUnwrap(sink.blockEntities.first {
            $0.kind == "chest_loot" && $0.data["lootTable"] == .str("ancient_city")
                && $0.x == cx - 10 && $0.y == y + 3 && $0.z == cz - 18
        }, "ice box must retain its authored chest")
        XCTAssertEqual(cell(chest.x, chest.y, chest.z, sink) >> 4, Int(B.chest))
        XCTAssertTrue(sturdyTop(cell(chest.x, chest.y - 1, chest.z, sink)),
                      "ice-box chest must remain supported by its packed-ice pedestal")
        XCTAssertEqual(cell(chest.x, chest.y + 1, chest.z, sink), 0,
                       "ice-box chest lid needs headroom")

        let bounds = (x0: cx - 19, x1: cx + 19, y0: y, y1: y + 5, z0: cz - 22, z1: cz - 11)
        func canStand(_ point: AncientCityFixturePoint) -> Bool {
            guard point.x >= bounds.x0, point.x <= bounds.x1,
                  point.y >= bounds.y0, point.y <= bounds.y1,
                  point.z >= bounds.z0, point.z <= bounds.z1 else { return false }
            return supportsPlayerFeet(cell(point.x, point.y - 1, point.z, sink))
                && cell(point.x, point.y, point.z, sink) == 0
                && cell(point.x, point.y + 1, point.z, sink) == 0
        }

        let start = AncientCityFixturePoint(x: cx - 10, y: y, z: cz - 11)
        let goal = AncientCityFixturePoint(x: cx - 10, y: y + 1, z: cz - 15)
        XCTAssertTrue(canStand(start), "central chamber must provide the ingress starting floor")
        XCTAssertTrue(canStand(goal), "ice-box floor behind the threshold must be a legal player position")

        var visited: Set<AncientCityFixturePoint> = [start]
        var queue = [start]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for (dx, dz) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                for nextY in (current.y - 1)...(current.y + 1) {
                    let next = AncientCityFixturePoint(x: current.x + dx, y: nextY, z: current.z + dz)
                    if !visited.contains(next), canStand(next) {
                        visited.insert(next)
                        queue.append(next)
                    }
                }
            }
        }
        XCTAssertTrue(visited.contains(goal),
                      "central chamber, paved link, arch, and stair must form a real ice-box route")
    }
}
