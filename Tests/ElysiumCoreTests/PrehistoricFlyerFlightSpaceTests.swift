import Foundation
import XCTest
@testable import ElysiumCore

/// The flight geometry of 1.5.5 (`PrehistoricFlightSpace.swift`) against real collision: the
/// folded-wing climb through gaps of every size and offset, a gap that closes or bends, the
/// 0.05-block tolerance of a vertical route, climbs out of water and lava, landings and the
/// land-rest-take-off cycle, the `onGround` and `airborne` flags on every tick, spawn admission as
/// a property over generated places, admission at the edges of the world and against the
/// pre-1.5.5 rule for every other species, save and reload in mid-climb and mid-landing, and
/// what launch and lift cost.
///
/// An extension of `PrehistoricBoxedInFlyerTests`, so it shares that class's fixtures and runs
/// with it under one filter.
extension PrehistoricBoxedInFlyerTests {

    // MARK: - fixture

    struct Column: Hashable, CustomStringConvertible {
        let x, z: Int
        var description: String { "(\(x),\(z))" }
    }

    var airSpecies: [PrehistoricCreatureDefinition] {
        PrehistoricCreatureDefinition.all.filter { $0.medium == .air }
    }

    /// A body exactly one block wide, the widest that fits a one-column gap. No species is this
    /// wide (the pteranodon is 1.02), so it is built here from the pteranodon.
    func unitWideFlyer() throws -> PrehistoricCreatureDefinition {
        let p = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.pteranodon"))
        return PrehistoricCreatureDefinition(
            id: "prehistoric.test_unit_wide", displayName: "Unit-wide flyer", medium: .air, family: p.family,
            authoringLengthMetres: p.authoringLengthMetres, collisionWidth: 1.0, collisionHeight: p.collisionHeight,
            health: p.health, speed: p.speed, attackDamage: p.attackDamage, spawnWeight: 0, minPack: 1, maxPack: 1)
    }

    /// Leaves from `layers` everywhere except over `open`, on the flat world.
    func canopyWorld(open: Set<Column>, layers: ClosedRange<Int> = 66...68) -> World {
        let leaves = cell(B.oak_leaves)
        return makeShapedWorld { x, y, z in
            layers.contains(y) && !open.contains(Column(x: x, z: z)) ? leaves : nil
        }
    }

    /// The columns a collision box covers, computed from `bb()` alone: a cell is covered when the
    /// box overlaps it by more than the 1e-6 the geometry leaves at the box's far edges.
    func columnsCovered(by box: AABB) -> Set<Column> {
        var covered = Set<Column>()
        for z in (ifloor(box.z0) - 1)...(ifloor(box.z1) + 1) {
            for x in (ifloor(box.x0) - 1)...(ifloor(box.x1) + 1)
            where Double(x) < box.x1 - 1e-6 && Double(x + 1) > box.x0
                && Double(z) < box.z1 - 1e-6 && Double(z + 1) > box.z0 {
                covered.insert(Column(x: x, z: z))
            }
        }
        return covered
    }

    /// A block whose collision box overlaps the entity's body, if any.
    func blockInside(_ entity: Entity) -> AABB? {
        let box = entity.bb()
        var inside: AABB?
        entity.world.forEachCollisionBox(box) { b in
            if b.x0 < box.x1 - 1e-6, b.x1 > box.x0 + 1e-6, b.y0 < box.y1 - 1e-6, b.y1 > box.y0 + 1e-6,
               b.z0 < box.z1 - 1e-6, b.z1 > box.z0 + 1e-6 {
                inside = b
            }
        }
        return inside
    }

    /// Whether the top of some block's collision box is exactly under the entity's feet.
    func standsOnABlock(_ entity: Entity) -> Bool {
        let box = entity.bb()
        var stands = false
        entity.world.forEachCollisionBox(AABB(box.x0, box.y0 - 0.01, box.z0, box.x1, box.y0, box.z1)) { b in
            if abs(b.y1 - box.y0) < 1e-6, b.x0 < box.x1, b.x1 > box.x0, b.z0 < box.z1, b.z1 > box.z0 { stands = true }
        }
        return stands
    }

    /// A pool three deep (water or lava from 61 to 63, a stone floor at 60) five by five around
    /// the site, under `cover`. A flyer stands on its floor at y 61.
    enum PoolCover: Equatable { case open, gap, closedCanopy, roof(Int) }

    func poolWorld(_ cover: PoolCover, fluid: UInt16 = cell(B.water)) -> World {
        let s = Self.site
        let leaves = cell(B.oak_leaves), stone = cell(B.stone)
        return makeShapedWorld { x, y, z in
            let dx = abs(x - s.x), dz = abs(z - s.z)
            if dx <= 3, dz <= 3 {
                if y == 60 { return stone }
                if (61...63).contains(y) { return dx <= 2 && dz <= 2 ? fluid : stone }
            }
            switch cover {
            case .open: return nil
            case .gap: return (66...68).contains(y) && !(x == s.x && z == s.z) ? leaves : nil
            case .closedCanopy: return (66...68).contains(y) ? leaves : nil
            case .roof(let at): return y == at ? stone : nil
            }
        }
    }

    // MARK: - the folded body column is the collision box

    func testFoldedBodyColumnIsExactlyTheColumnsTheCollisionBoxCovers() throws {
        // One marker block per column around (24, 8), each at its own height, so asking about one
        // height asks about one column. For every species and a body exactly one block wide, at
        // exact cell edges, half-cells and 300 seeded positions, the climb check must name exactly
        // the columns the creature's own `bb()` covers: fewer would let a body climb through a
        // leaf, more would refuse a gap it fits.
        let base = Column(x: 24, z: 8)
        let offsets = -2...3
        func markerY(_ dx: Int, _ dz: Int) -> Int { 64 + (dz - offsets.lowerBound) * offsets.count + (dx - offsets.lowerBound) }
        let world = makeShapedWorld { x, y, z in
            let dx = x - base.x, dz = z - base.z
            return offsets.contains(dx) && offsets.contains(dz) && y == markerY(dx, dz) ? cell(B.stone) : nil
        }
        var rng = RandomX(0xB0D7)
        for definition in airSpecies + [try unitWideFlyer()] {
            let creature = PrehistoricCreature(world: world, definition: definition)
            let half = definition.collisionWidth / 2
            var samples: [(Double, Double)] = [
                (24.5, 8.5), (24 + half, 8 + half), (25 - half, 9 - half), (24.0, 8.0),
                (24 + half + 1e-9, 8.5), (25 - half - 1e-9, 8.5), (24.999_999, 8.000_001),
            ]
            for _ in 0..<300 { samples.append((24 + rng.nextFloat(), 8 + rng.nextFloat())) }
            for (px, pz) in samples {
                creature.setPos(px, 64, pz)
                let covered = columnsCovered(by: creature.bb())
                var checked = Set<Column>()
                for dz in offsets {
                    for dx in offsets {
                        let y = markerY(dx, dz)
                        if !definition.flyerBodyColumnIsClear(in: world, px, pz, from: y, through: y) {
                            checked.insert(Column(x: base.x + dx, z: base.z + dz))
                        }
                    }
                }
                XCTAssertEqual(checked, covered, "\(definition.id) width \(definition.collisionWidth) at (\(px), \(pz))")
            }
        }
    }

    func testBodyOneBlockWideFitsAOneColumnGapOnlyWhenCentred() throws {
        // The widest body a one-column gap takes: centred it lifts, a millionth off it does not.
        let world = canopyWorld(open: [Column(x: 24, z: 8)])
        let unit = try unitWideFlyer()
        XCTAssertNotNil(unit.flyerLift(in: world, 24.5, 64, 8.5), "a body exactly one block wide fits the gap")
        XCTAssertNil(unit.flyerLift(in: world, 24.5 + 1e-5, 64, 8.5))
        XCTAssertNil(unit.flyerLift(in: world, 24.5, 64, 8.5 - 1e-5))
        let pteranodon = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.pteranodon"))
        XCTAssertNil(pteranodon.flyerLift(in: world, 24.5, 64, 8.5), "1.02 blocks does not fit one column")
    }

    // MARK: - climbing out of gaps of every size

    func testFlyerClimbsAGapExactlyWhenItsBodyFitsAndNeverEntersALeaf() throws {
        // Gaps of 1x1, 1x2, 2x2 and 3x3 columns through leaves at 66 to 68, every species, at the
        // centre of the site's cell, off-centre at x.1, x.9 and z.9, and on the centre of a wider
        // gap. The lift exists exactly when the columns of `bb()` are all open; with a lift the
        // flyer is above the leaves within 100 ticks, without one it does not move or announce
        // anything. On no tick is any part of its body inside a block.
        func columns(_ xs: ClosedRange<Int>, _ zs: ClosedRange<Int>) -> Set<Column> {
            Set(xs.flatMap { x in zs.map { Column(x: x, z: $0) } })
        }
        let gaps: [(String, Set<Column>, [(Double, Double)])] = [
            ("1x1", columns(24...24, 8...8), [(24.5, 8.5), (24.1, 8.5), (24.9, 8.5), (24.5, 8.9)]),
            ("1x2", columns(24...25, 8...8), [(24.5, 8.5), (25.0, 8.5), (24.9, 8.5)]),
            ("2x2", columns(24...25, 8...9), [(24.5, 8.5), (25.0, 9.0), (24.1, 8.9)]),
            ("3x3", columns(23...25, 7...9), [(24.5, 8.5), (24.1, 8.5), (24.9, 8.9)]),
        ]
        var climbed = 0, held = 0
        for (name, open, positions) in gaps {
            let world = canopyWorld(open: open)
            for definition in airSpecies {
                for (px, pz) in positions {
                    let flyer = try makeFlyer(world, definition.id, seed: 9, at: (px, 64, pz))
                    let fits = columnsCovered(by: flyer.bb()).isSubset(of: open)
                    let label = "\(name) gap, \(definition.id) at (\(px), \(pz))"
                    XCTAssertEqual(definition.flyerLift(in: world, px, 64, pz) != nil, fits, label)
                    var inside: (Int, AABB)?
                    var clearedAt: Int?
                    let heard = run(flyer, ticks: fits ? 100 : 60) { tick in
                        if inside == nil, let block = self.blockInside(flyer) { inside = (tick, block) }
                        if clearedAt == nil, flyer.y >= 69 { clearedAt = tick }
                    }
                    XCTAssertNil(inside.map { "tick \($0.0): \($0.1)" }, label)
                    if fits {
                        climbed += 1
                        XCTAssertNotNil(clearedAt, "\(label) never rose above the leaves, y \(flyer.y)")
                    } else {
                        held += 1
                        XCTAssertEqual(flyer.x, px, label); XCTAssertEqual(flyer.y, 64, label); XCTAssertEqual(flyer.z, pz, label)
                        XCTAssertTrue(actionCues(flyer, heard).isEmpty, "\(label): \(heard.map(\.name))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(climbed, 20, "fixture: both outcomes must be exercised")
        XCTAssertGreaterThan(held, 10, "fixture: both outcomes must be exercised")
    }

    func testFlyerWithSidewaysMomentumInAOneColumnGapDoesNotPassALeaf() throws {
        // A lift target is straight up, but a flyer can carry momentum into it (a knock-back,
        // say). Whatever it carries, the leaves beside the gap stop it: no tick finds it inside a
        // block. (Whether it then still leaves is printed: a body pushed off the gap's column has
        // no lift and does not steer back.)
        let world = canopyWorld(open: [Column(x: 24, z: 8)])
        for (vx, vz) in [(0.05, 0.0), (-0.05, 0.0), (0.0, 0.2), (0.3, -0.3)] {
            let flyer = try makeFlyer(world, "prehistoric.dimorphodon", seed: 4, at: (24.8, 64, 8.5))
            flyer.vx = vx; flyer.vz = vz
            var inside: Int?
            var highest = flyer.y
            _ = run(flyer, ticks: 120) { tick in
                if inside == nil, self.blockInside(flyer) != nil { inside = tick }
                highest = max(highest, flyer.y)
            }
            XCTAssertNil(inside, "momentum (\(vx), \(vz)) carried the body into a leaf on tick \(inside ?? -1)")
            print("MOMENTUM (\(vx), \(vz)): highest \(highest), ends at (\(flyer.x), \(flyer.y), \(flyer.z)) \(flyer.action)")
        }
    }

    /// PRODUCT BUG (low; the hover itself predates 1.5.5): a flyer that has left the ground and
    /// then loses its route hovers where it is for good, even a few hundredths of a block above
    /// the floor, and searches for a way out on every tick. The no-route fallback in `tickFlight`
    /// zeroes the velocity and applies no gravity, the rest needs `standsOnSolidGround` (the
    /// block under the feet, which is air 0.03 above the floor), and the floor of a gap under
    /// leaves at 66 is no perch. Here a dimorphodon nudged 0.05 east in a one-column gap takes
    /// off for one tick, finds its body over the leaf column (no lift), and hangs at y 64.031.
    func testFlyerThatLosesItsRouteJustAboveTheFloorSettlesOnItAndRests() throws {
        let world = canopyWorld(open: [Column(x: 24, z: 8)])
        let flyer = try makeFlyer(world, "prehistoric.dimorphodon", seed: 4, at: (24.8, 64, 8.5))
        flyer.vx = 0.05
        _ = run(flyer, ticks: 40)
        let (_, searches) = runCountingSearches(flyer, ticks: 200)
        XCTAssertTrue(flyer.onGround, "the flyer hovers at y \(flyer.y), \(flyer.y - 64) above the floor")
        XCTAssertEqual(flyer.y, 64, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(searches, 200 / 20 + 1, "a flyer that could stand on the floor searched on \(searches) of 200 ticks")
    }

    func testGapThatClosesAboveAClimbingFlyerHoldsItBelowTheBlockAndReopeningLetsItGo() throws {
        // A leaf is put into the gap two blocks above a flyer that has begun to climb. It must
        // stop under the leaf without entering it, stay quiet, and climb out once the leaf goes.
        let world = canopyWorld(open: [Column(x: 24, z: 8)])
        let flyer = try makeFlyer(world, "prehistoric.dimorphodon", seed: 1)
        var ticks = 0
        while flyer.y < 64.5, ticks < 40 { flyer.tick(); ticks += 1 }
        XCTAssertGreaterThanOrEqual(flyer.y, 64.5, "fixture: the flyer must be climbing")
        XCTAssertLessThan(flyer.y + flyer.height, 67, "fixture: the leaf must still be above the flyer")
        _ = world.setBlock(24, 67, 8, Int(cell(B.oak_leaves)))

        var inside: Int?
        var highestTop = 0.0
        let heard = run(flyer, ticks: 200) { tick in
            if inside == nil, self.blockInside(flyer) != nil { inside = tick }
            highestTop = max(highestTop, flyer.y + flyer.height)
        }
        XCTAssertNil(inside, "the flyer entered a block on tick \(inside ?? -1)")
        XCTAssertLessThanOrEqual(highestTop, 67 + 1e-9, "the body passed the leaf")
        XCTAssertLessThanOrEqual(actionCues(flyer, heard).count, 2, "\(actionCues(flyer, heard).map { "\($0.tick):\($0.name)" })")
        XCTAssertFalse(flyer.dead || flyer.deathTime > 0)

        _ = world.setBlock(24, 67, 8, 0)
        var highest = flyer.y
        _ = run(flyer, ticks: 150) { _ in highest = max(highest, flyer.y) }
        XCTAssertGreaterThan(highest, 69, "with the gap open again the flyer must leave")
    }

    func testGapThatBendsIsNoWayOutAndNoPlaceToSpawn() throws {
        // The open column is at x 24 through 67 and at x 25 from 68 up: no straight climb fits,
        // and the wings fit nowhere below 71. Every species has no lift, is not placed, and a
        // flyer put there stays on the floor without a sound or a step into a leaf.
        let world = makeShapedWorld { x, y, z in
            guard (66...70).contains(y) else { return nil }
            let open = z == 8 && (y <= 67 ? x == 24 : x == 25)
            return open ? nil : cell(B.oak_leaves)
        }
        for definition in airSpecies {
            XCTAssertNil(definition.flyerLift(in: world, 24.5, 64, 8.5), definition.id)
            XCTAssertFalse(definition.flyerCanLaunch(in: world, x: 24, y: 64, z: 8), definition.id)
            XCTAssertFalse(spawnPlacementIsValid(world, definition.id, 24, 64, 8), definition.id)
            let flyer = try makeFlyer(world, definition.id, seed: 2)
            var inside = false
            let heard = run(flyer, ticks: 60) { _ in inside = inside || self.blockInside(flyer) != nil }
            XCTAssertFalse(inside, definition.id)
            XCTAssertEqual(flyer.y, 64, definition.id)
            XCTAssertTrue(actionCues(flyer, heard).isEmpty, "\(definition.id): \(heard.map(\.name))")
        }
    }

    // MARK: - the 0.05 tolerance of a vertical route

    func testOnlyARouteWithinFiveHundredthsOfVerticalIsAFoldedWingClimb() throws {
        // Through a one-column gap a climb straight up is clear for a dimorphodon; a route that
        // leans 0.051 is swept with spread wings and meets the leaves. A landing is never a
        // folded-wing climb, even straight down.
        let world = canopyWorld(open: [Column(x: 24, z: 8)])
        let d = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.dimorphodon"))
        let from = (x: 24.5, y: 64.0, z: 8.5)
        func clear(_ dx: Double, _ dz: Double, landing: Bool = false) -> Bool {
            d.flightRouteIsClear(in: world, from: from, to: (from.x + dx, 72, from.z + dz), landing: landing)
        }
        XCTAssertTrue(clear(0, 0))
        for lean in [0.049, -0.049] {
            XCTAssertTrue(clear(lean, 0), "dx \(lean)"); XCTAssertTrue(clear(0, lean), "dz \(lean)")
            XCTAssertTrue(clear(lean, lean), "dx and dz \(lean)")
        }
        for lean in [0.051, -0.051] {
            XCTAssertFalse(clear(lean, 0), "dx \(lean)"); XCTAssertFalse(clear(0, lean), "dz \(lean)")
        }
        XCTAssertFalse(clear(0, 0, landing: true), "a landing is swept with spread wings")
        // Down is the same climb: from above the leaves straight down to the floor of the gap.
        XCTAssertTrue(d.flightRouteIsClear(in: world, from: (24.5, 72, 8.5), to: (24.5, 64, 8.5), landing: false))
        XCTAssertFalse(d.flightRouteIsClear(in: world, from: (24.5, 72, 8.5), to: (24.56, 64, 8.5), landing: false))
    }

    func testVerticalRouteIsCheckedInTheColumnTheBodyStartsIn() throws {
        // Pinned as it is: the tolerance asks about the column of `from`, not of the target. A body
        // at x 24.80 (edges 24.625 to 24.975) with a target 0.049 further east would end with its
        // edge at 25.024, in the leaf column; the route is still called clear. The lift never makes
        // such a target (its x and z are the flyer's own), and `move` stops a drifting body at the
        // leaf (`testFlyerWithSidewaysMomentumInAOneColumnGapDoesNotPassALeaf`).
        let world = canopyWorld(open: [Column(x: 24, z: 8)])
        let d = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.dimorphodon"))
        XCTAssertTrue(d.flightRouteIsClear(in: world, from: (24.80, 64, 8.5), to: (24.849, 72, 8.5), landing: false))
        XCTAssertFalse(d.flightRouteIsClear(in: world, from: (24.85, 64, 8.5), to: (24.85, 72, 8.5), landing: false),
                       "starting in the leaf column's reach, the same climb is refused")
        let lift = try XCTUnwrap(d.flyerLift(in: world, 24.80, 64, 8.5))
        XCTAssertEqual(lift.x, 24.80); XCTAssertEqual(lift.z, 8.5)
    }

    // MARK: - climbing out of water and lava

    func testFlyerAtTheBottomOfAPoolClimbsOutUnhurtUnderOpenSkyAndThroughAGapItFits() throws {
        // Every species from the floor of a three-deep pool under open sky, and the narrow ones
        // under a canopy with a gap over the pool: out of the water within 40 ticks, above the
        // leaves, never hurt. (Before 1.5.5 the narrow ones drowned under the gap: the lift there
        // had no room for the wings and was never searched upward.)
        for cover in [PoolCover.open, .gap] {
            for definition in airSpecies where cover == .open || definition.collisionWidth <= 1 {
                let world = poolWorld(cover)
                let flyer = try makeFlyer(world, definition.id, seed: 7, at: (24.5, 61, 8.5))
                XCTAssertTrue(flyer.touchesWater(atX: flyer.x, y: flyer.y, z: flyer.z), "fixture: \(definition.id) in the water")
                let health = flyer.health
                var dryAt: Int?
                var highest = flyer.y
                let heard = run(flyer, ticks: 200) { tick in
                    if dryAt == nil, !flyer.inWater { dryAt = tick }
                    highest = max(highest, flyer.y)
                }
                let label = "\(cover) \(definition.id)"
                let dry = try XCTUnwrap(dryAt, "\(label) never left the water")
                XCTAssertLessThanOrEqual(dry, 40, label)
                XCTAssertGreaterThan(highest, cover == .gap ? 69 : 66, label)
                XCTAssertEqual(flyer.health, health, label)
                XCTAssertFalse(heard.contains { $0.name == cue(flyer, .hurt) }, label)
            }
        }
    }

    func testFlyerInALavaPoolClimbsOutAsFastUnderOpenSkyAndThroughAGap() throws {
        // Lava: the same climb. Fire resistance keeps it alive so the count is of ticks in lava.
        // 18 ticks under open sky, as before 1.5.5; under the gap it used to stay for good.
        for cover in [PoolCover.open, .gap] {
            for id in ["prehistoric.dimorphodon", "prehistoric.microraptor"] {
                let world = poolWorld(cover, fluid: cell(B.lava))
                let flyer = try makeFlyer(world, id, seed: 7, at: (24.5, 61, 8.5))
                flyer.addEffect("fire_resistance", 100_000)
                var lavaTicks = 0
                _ = run(flyer, ticks: 120) { _ in if flyer.inLava { lavaTicks += 1 } }
                XCTAssertLessThanOrEqual(lavaTicks, 20, "\(cover) \(id): \(lavaTicks) ticks in lava")
            }
        }
    }

    /// PRODUCT BUG (1.5.5, medium): a flyer in water under any cover drowns where it used to get
    /// out. `flyerLift` takes its first height from `surfaceY`, the top of the cover, so under a
    /// roof or a closed canopy the folded body never fits and there is no lift, however much air
    /// is between the water and the roof; the random routes are swept with spread wings from inside
    /// the water and fail; and the rest is refused in water. The flyer sits on the pool floor
    /// looking for a way out on every tick until it drowns (tick 319). Before 1.5.5 the unchecked
    /// lift above the roof at least carried it up against the roof's underside, out of the water.
    /// Here the roof is at 72, eight blocks of air above the water, and the wings fit at 64.
    func testFlyerInAPoolUnderARoofWithRoomAboveTheWaterGetsOutOfTheWater() throws {
        let cases: [(PoolCover, String)] = [
            (.roof(72), "prehistoric.dimorphodon"), (.roof(72), "prehistoric.tapejara"),
            (.roof(72), "prehistoric.quetzalcoatlus"), (.closedCanopy, "prehistoric.dimorphodon"),
        ]
        for (cover, id) in cases {
            let world = poolWorld(cover)
            let flyer = try makeFlyer(world, id, seed: 7, at: (24.5, 61, 8.5))
            XCTAssertTrue(flyer.definition.flightSpaceIsClear(in: world, 24.5, 64, 8.5),
                          "fixture: \(id) has room for its wings above the water")
            let health = flyer.health
            var dryAt: Int?
            _ = run(flyer, ticks: 400) { tick in if dryAt == nil, !flyer.inWater { dryAt = tick } }
            let label = "\(cover) \(id)"
            XCTAssertNotNil(dryAt, "\(label): stayed on the pool floor at y \(flyer.y) for 400 ticks")
            XCTAssertEqual(flyer.health, health, "\(label) drowned under a roof with room above the water")
        }
    }

    // MARK: - landings and the land, rest, take-off cycle

    /// Tracks every landing a flyer begins and checks how it ends.
    struct LandingLog {
        var begun = 0, settled = 0, longest = 0, cycles = 0
        var problems: [String] = []
    }

    func logLandings(_ flyer: PrehistoricCreature, ticks: Int,
                     each: (Int) -> Void = { _ in }) -> (LandingLog, [Heard]) {
        var log = LandingLog()
        var last = flyer.action
        var landingFrom = 0
        var restAt: (x: Double, y: Double, z: Double)?
        let heard = run(flyer, ticks: ticks) { tick in
            each(tick)
            let now = flyer.action
            if let rest = restAt, now == .idle, (flyer.x, flyer.y, flyer.z) != rest {
                log.problems.append("tick \(tick): moved while resting")
            }
            guard now != last else { return }
            defer { last = now }
            if now == .landing { log.begun += 1; landingFrom = tick }
            if last == .idle, restAt != nil {
                restAt = nil
                if now == .takeoff { log.cycles += 1 } else { log.problems.append("tick \(tick): a rest ended in \(now)") }
            }
            guard last == .landing else { return }
            log.longest = max(log.longest, tick - landingFrom)
            let perch = flyer.definition.flyerLandingTarget(in: flyer.world, x: ifloor(flyer.x), z: ifloor(flyer.z))
            if now == .idle, flyer.onGround, flyer.data.airborne == false,
               let perch, perch.x == flyer.x, perch.y == flyer.y, perch.z == flyer.z {
                log.settled += 1
                restAt = (flyer.x, flyer.y, flyer.z)
            } else {
                log.problems.append("tick \(tick): a landing ended in \(now) at (\(flyer.x), \(flyer.y), \(flyer.z)), onGround \(flyer.onGround)")
            }
        }
        return (log, heard)
    }

    func testEveryFlyerLandsOnItsPerchRestsAndTakesOffAgainForFiveMinutesUnhurt() throws {
        // 6,000 ticks of open-ground life for every species: every landing that begins ends on
        // the perch it chose (exact position, standing, wings folded, idle) within 100 ticks, the
        // rest that follows does not move, and every rest ends in a take-off. No fall, no hurt.
        for definition in airSpecies {
            let world = makeFlatWorld()
            let flyer = try makeFlyer(world, definition.id, seed: 3)
            let health = flyer.health
            let (log, heard) = logLandings(flyer, ticks: 6_000)
            let label = "\(definition.id): \(log.begun) begun, \(log.settled) settled, \(log.cycles) cycles"
            XCTAssertEqual(log.problems, [], label)
            XCTAssertGreaterThanOrEqual(log.settled, 20, label)
            XCTAssertLessThanOrEqual(log.begun - log.settled, 1, "\(label): only a landing still under way at the end may be unsettled")
            XCTAssertGreaterThanOrEqual(log.cycles, log.settled - 1, label)
            XCTAssertLessThanOrEqual(log.longest, 100, "\(label): the longest landing took \(log.longest) ticks")
            XCTAssertEqual(flyer.health, health, label)
            XCTAssertFalse(heard.contains { $0.name.hasPrefix("entity.generic.") || $0.name == cue(flyer, .hurt) },
                           "\(label): \(Set(heard.map(\.name)).sorted())")
        }
    }

    func testFlyerLandsOnTreeTopsAboveALake() throws {
        // A lake with a continuous crown of leaves from 70 to 72 over it: the only perches are the
        // tree tops at 73. Landings there end on a perch the same way, and nothing ends in water.
        let world = makeShapedWorld { _, y, _ in
            if y == 63 { return cell(B.water) }
            return (70...72).contains(y) ? cell(B.oak_leaves) : nil
        }
        for definition in airSpecies {
            let flyer = try makeFlyer(world, definition.id, seed: 11, at: (24.5, 73, 8.5))
            var lowest = flyer.y
            var wetTicks = 0
            let (log, _) = logLandings(flyer, ticks: 1_500) { _ in
                lowest = min(lowest, flyer.y)
                if flyer.inWater { wetTicks += 1 }
            }
            let label = "\(definition.id): \(log.begun) begun, \(log.settled) settled"
            XCTAssertEqual(log.problems, [], label)
            XCTAssertGreaterThanOrEqual(log.settled, 4, label)
            XCTAssertEqual(wetTicks, 0, label)
            XCTAssertGreaterThanOrEqual(lowest, 73, label)
        }
    }

    func testFlyerTouchingDownAfterALongDescentIsNotHurtButAWalkerIs() throws {
        // Since landings settle by `setPos` before the body reaches the ground, ordinary flight
        // never lands through `move`, and the open-ground tests pass with or without the
        // fall-damage override. A touch-down by collision still happens (an approach that meets the
        // ground before its settle window, a knock-back, a dug-out perch), and then `move` charges
        // the whole descent since take-off: 30 blocks here. A flyer takes nothing; a walker does.
        for definition in airSpecies + [try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.compsognathus"))] {
            let world = makeFlatWorld()
            let creature = try makeFlyer(world, definition.id, seed: 1, at: (24.5, 64.3, 8.5))
            let health = creature.health
            creature.fallDistance = 30
            var heard: [String] = []
            let previous = world.hooks.playSound
            world.hooks.playSound = { name, _, _, _, _, _ in heard.append(name) }
            creature.move(0, -0.5, 0)
            world.hooks.playSound = previous
            XCTAssertTrue(creature.onGround, "fixture: \(definition.id) must touch down by collision")
            XCTAssertEqual(creature.y, 64, accuracy: 1e-9)
            if definition.medium == .air {
                XCTAssertEqual(creature.health, health, "\(definition.id) was hurt by its own descent")
                XCTAssertFalse(heard.contains { $0.hasPrefix("entity.generic.") }, "\(definition.id): \(heard)")
            } else {
                XCTAssertLessThan(creature.health, health, "fixture: a walker falling 30 blocks is hurt")
            }
            XCTAssertEqual(creature.fallDistance, 0, "\(definition.id): a touch-down clears the fall")
        }
    }

    // MARK: - onGround and airborne on every tick

    func testOnGroundAndAirborneAgreeWithTheBodyOnEveryTick() throws {
        // Every species, every enclosure, the open and a pool, 300 ticks: on every tick
        //  - no block is inside the body;
        //  - `onGround` is true exactly when a block's top is under the feet;
        //  - `airborne` is exactly `!onGround` (wings folded only when standing).
        // A wide body placed inside the chimney's walls starts inside a block; those pairs are
        // left out (and reported: the chimney fixture of the cue-rate property embeds them).
        var places: [(String, () -> World, Double)] = [("open", { self.makeFlatWorld() }, 64),
                                                        ("pool", { self.poolWorld(.open) }, 61)]
        for enclosure in Enclosure.allCases {
            places.append((enclosure.rawValue, { self.makeShapedWorld(self.shape(of: enclosure)) }, 64))
        }
        var checked = 0, embedded: [String] = []
        for (name, make, y) in places {
            for definition in airSpecies {
                let world = make()
                let flyer = try makeFlyer(world, definition.id, seed: 5, at: (24.5, y, 8.5))
                guard blockInside(flyer) == nil else { embedded.append("\(name) \(definition.id)"); continue }
                checked += 1
                var failures: [String] = []
                _ = run(flyer, ticks: 300) { tick in
                    guard failures.count < 3 else { return }
                    let stands = self.standsOnABlock(flyer)
                    let state = "tick \(tick) y \(flyer.y) \(flyer.action) onGround \(flyer.onGround) airborne \(String(describing: flyer.data.airborne))"
                    if let block = self.blockInside(flyer) { failures.append("inside \(block): \(state)") }
                    if flyer.onGround != stands { failures.append("stands \(stands): \(state)") }
                    if flyer.data.airborne != !flyer.onGround { failures.append("airborne: \(state)") }
                }
                XCTAssertEqual(failures, [], "\(name) \(definition.id)")
            }
        }
        XCTAssertEqual(Set(embedded), ["chimney prehistoric.pteranodon", "chimney prehistoric.quetzalcoatlus"])
        XCTAssertEqual(checked, places.count * airSpecies.count - 2)
    }

    // MARK: - spawn admission as a property

    /// A seeded place around a few sites: a canopy at a random height and thickness with random
    /// holes, sometimes a stone roof with holes, random pillars, sometimes a pool under the
    /// first site. Everything is a pure function of the seed.
    struct GeneratedPlace: CustomStringConvertible {
        let seed: UInt32
        let canopy: ClosedRange<Int>?
        let canopyHoles: Double
        let roof: Int?
        let roofHoles: Double
        let pillars: [(x: Int, z: Int, top: Int)]
        let pool: Bool
        var description: String {
            "seed \(seed): canopy \(canopy.map { "\($0)" } ?? "none") holes \(canopyHoles), roof \(roof.map(String.init) ?? "none") holes \(roofHoles), \(pillars.count) pillars, pool \(pool)"
        }

        init(seed: UInt32) {
            self.seed = seed
            var rng = RandomX(seed &* 2_654_435_761 &+ 1)
            if rng.nextInt(4) > 0 {
                let bottom = 65 + rng.nextInt(10)
                canopy = bottom...(bottom + rng.nextInt(3))
            } else {
                canopy = nil
            }
            canopyHoles = [0, 0.05, 0.2, 0.5][rng.nextInt(4)]
            roof = rng.nextInt(4) == 0 ? 72 + rng.nextInt(20) : nil
            roofHoles = [0, 0.1, 0.6][rng.nextInt(3)]
            pillars = (0..<rng.nextInt(6)).map { _ in (18 + rng.nextInt(14), 2 + rng.nextInt(14), 64 + rng.nextInt(12)) }
            pool = rng.nextInt(5) == 0
        }

        static func hole(_ seed: UInt32, _ salt: UInt32, _ x: Int, _ z: Int, _ chance: Double) -> Bool {
            var h = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(salt) &* 0xBF58_476D_1CE4_E5B9
            h ^= UInt64(bitPattern: Int64(x)) &* 0x94D0_49BB_1331_11EB
            h ^= UInt64(bitPattern: Int64(z)) &* 0x2545_F491_4F6C_DD1D
            h ^= h >> 31; h &*= 0xD6E8_FEB8_6659_FD93; h ^= h >> 32
            return Double(h % 10_000) / 10_000 < chance
        }

        func block(_ x: Int, _ y: Int, _ z: Int) -> UInt16? {
            let s = PrehistoricBoxedInFlyerTests.site
            if pool, abs(x - s.x) <= 3, abs(z - s.z) <= 3 {
                if y == 60 { return cell(B.stone) }
                if (61...63).contains(y) { return abs(x - s.x) <= 2 && abs(z - s.z) <= 2 ? cell(B.water) : cell(B.stone) }
            }
            if pillars.contains(where: { $0.x == x && $0.z == z && (64...$0.top).contains(y) }) { return cell(B.oak_log) }
            if let canopy, canopy.contains(y), !Self.hole(seed, 1, x, z, canopyHoles) { return cell(B.oak_leaves) }
            if let roof, y == roof, !Self.hole(seed, 2, x, z, roofHoles) { return cell(B.stone) }
            return nil
        }
    }

    /// The sites the admission properties ask about: the middle of the world, two more, and one
    /// next to the edge of the loaded chunks (x 0 to 47, z -16 to 31).
    static let admissionSites: [(x: Int, z: Int)] = [(24, 8), (14, 0), (36, 20), (2, -14), (45, 29)]

    func testEverySiteThatAdmitsAFlyerIsOneItLeaves() throws {
        // For 30 generated places, five sites and every flying species, where
        // `spawnPlacementIsValid` admits a flyer, a flyer put there within 300 ticks
        //  - never has a block inside its body;
        //  - leaves its site: rises three blocks, or flies three blocks away from it;
        //  - and rises three blocks when the first height with room for its wings straight above
        //    it is already the open sky (the lift the controller flies is the lift admission saw).
        // Under a high canopy the first room for the wings is the understory below the leaves, and
        // a flyer can live there, flying between perches on the forest floor without rising three
        // blocks: that is counted and printed, not failed. Both answers of admission must occur,
        // and asking twice gives the same answer.
        var admitted = 0, refused = 0, refusedWithBodyRoom = 0, understory = 0
        for seed: UInt32 in 1...30 {
            let place = GeneratedPlace(seed: seed)
            let world = makeShapedWorld(place.block)
            for site in Self.admissionSites {
                let y = place.pool && site.x == Self.site.x && site.z == Self.site.z ? 61 : 64
                for definition in airSpecies {
                    let label = "\(place), site (\(site.x), \(y), \(site.z)), \(definition.id)"
                    let admits = spawnPlacementIsValid(world, definition.id, site.x, y, site.z)
                    XCTAssertEqual(spawnPlacementIsValid(world, definition.id, site.x, y, site.z), admits, label)
                    guard admits else {
                        refused += 1
                        if legacyPrehistoricHasClearance(world, definition: definition, x: site.x, y: y, z: site.z,
                                                         requireGround: true) {
                            refusedWithBodyRoom += 1
                        }
                        continue
                    }
                    admitted += 1
                    let start = (x: Double(site.x) + 0.5, y: Double(y), z: Double(site.z) + 0.5)
                    let skyIsFirstRoom = definition.flyerLift(in: world, start.x, start.y, start.z)?.y
                        == definition.flyerLift(in: world, start.x, start.y, start.z, toOpenSky: true)?.y
                    let flyer = try makeFlyer(world, definition.id, seed: seed, at: start)
                    var rose = false, travelled = false, inside = false
                    for _ in 0..<300 where !rose {
                        flyer.tick()
                        inside = inside || blockInside(flyer) != nil
                        rose = flyer.y >= start.y + 3
                        let dx = flyer.x - start.x, dz = flyer.z - start.z
                        travelled = travelled || dx * dx + dz * dz >= 9
                    }
                    XCTAssertFalse(inside, label)
                    XCTAssertTrue(rose || travelled, "\(label): admitted but boxed in at (\(flyer.x), \(flyer.y), \(flyer.z)), \(flyer.action)")
                    if skyIsFirstRoom {
                        XCTAssertTrue(rose, "\(label): admitted under open sky but never rose, y \(flyer.y), \(flyer.action)")
                    } else if !rose {
                        understory += 1
                    }
                }
            }
        }
        print("ADMISSION \(admitted) admitted, \(refused) refused (\(refusedWithBodyRoom) with room for the body), \(understory) admitted flyers stayed in an understory")
        XCTAssertGreaterThan(admitted, 100, "fixture: \(admitted) admitted")
        XCTAssertGreaterThan(refused, 100, "fixture: \(refused) refused")
        XCTAssertGreaterThan(refusedWithBodyRoom, 20, "fixture: the launch rule must refuse sites the body fits")
    }

    /// PRODUCT BUG (low to medium), found by `testEverySiteThatAdmitsAFlyerIsOneItLeaves` and
    /// pinned here: a flyer admitted on the forest floor under a hole in a canopy hops on the spot
    /// for good. Admission found a straight lift to the open sky from the centre of its cell. But
    /// while it is lower than `surface + 0.8`, `tickFlight` and then `tickFlightToward` each call
    /// `takeOff` on every tick, so the flyer takes a new random heading twice a tick; the zig-zag
    /// carries its body over the leaf column next to the hole, where it has no lift, its route is
    /// refused, and the fallback lands it back on its own perch. Take-off, landing and settle cues
    /// every 110 ticks, never rising. (Seed 13 of the generated places, site (36, 64, 20).)
    func testFlyerAdmittedUnderACanopyHoleDoesNotHopOnTheSpotForever() throws {
        let place = GeneratedPlace(seed: 13)
        let world = makeShapedWorld(place.block)
        let tapejara = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.tapejara"))
        XCTAssertTrue(spawnPlacementIsValid(world, tapejara.id, 36, 64, 20), "fixture: the site admits a tapejara")
        XCTAssertNotNil(tapejara.flyerLift(in: world, 36.5, 64, 20.5, toOpenSky: true), "fixture: with a lift to the sky")
        let flyer = try makeFlyer(world, tapejara.id, seed: 13, at: (36.5, 64, 20.5))
        var highest = flyer.y
        let heard = run(flyer, ticks: 300) { _ in highest = max(highest, flyer.y) }
        let landings = heard.filter { $0.name == cue(flyer, .landing) }.map(\.tick)
        XCTAssertGreaterThanOrEqual(highest, 67, "the flyer never rose above \(highest); it landed on ticks \(landings)")
    }

    func testAdmissionNeverTrapsAtTheEdgesOfTheWorldOrBeyondIt() throws {
        // Every species, at the bottom and top of the world, near the Int extremes of y, and far
        // outside the loaded chunks: the placement checks answer (false outside the world) and
        // never trap. Left out on purpose, because they trap (no caller passes them):
        //  - y = Int.max: `spawnPlacementIsValid` computes `y + 1` (as before 1.5.5);
        //  - x or z whose chunk key aliases a loaded chunk: `chunkKey` keeps only the low 32 bits
        //    of a chunk coordinate, so z = Int.max reads chunk z -1 and x = Int.min chunk x 0;
        //    `prehistoricHasClearance` then overflows on `z + radius` (as before 1.5.5), and for a
        //    flyer at z = Int.max - 10 the body check passes and `flyerLift` traps converting
        //    `Double(z) + 0.5` back to an Int (new in 1.5.5).
        let world = makeFlatWorld()
        let bottom = world.info.minY, top = world.info.minY + world.info.height - 1
        let ceiling = Double(world.info.minY + world.info.height - 4)
        let ys = [Int.min, Int.min + 1, bottom - 1, bottom, bottom + 1, 64, top - 2, top - 1, top, top + 1, Int.max - 1]
        let farX = [-1_000_000, -17, 48, 1_000_000, Int.max - 1, Int.max]
        let farZ = [-1_000_000, -33, 32, 1_000_000]
        var rng = RandomX(1)
        for definition in PrehistoricCreatureDefinition.all {
            for y in ys {
                if y <= bottom || y >= top - 1 {
                    XCTAssertFalse(spawnPlacementIsValid(world, definition.id, 24, y, 8), "\(definition.id) y \(y)")
                    XCTAssertFalse(canSpawnAt(world, definition.id, "creature", 24, y, 8, &rng), "\(definition.id) y \(y)")
                }
                for x in farX {
                    XCTAssertFalse(spawnPlacementIsValid(world, definition.id, x, y, 8), "\(definition.id) x \(x) y \(y)")
                    XCTAssertFalse(canSpawnAt(world, definition.id, "creature", x, 64, 8, &rng), "\(definition.id) x \(x)")
                }
                for z in farZ {
                    XCTAssertFalse(spawnPlacementIsValid(world, definition.id, 24, y, z), "\(definition.id) z \(z) y \(y)")
                }
            }
            for spot in [-1_000_000.5, 1_000_000.5] {
                let spec = EntitySpec(mob: definition.id, x: spot, y: 64, z: 8.5)
                XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(spec, in: world), "\(definition.id) at \(spot)")
            }
            let atTheTop = EntitySpec(mob: definition.id, x: 24.5, y: Double(top), z: 8.5)
            XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(atTheTop, in: world), "\(definition.id) at the top")
        }
        // The geometry itself at the top and bottom of a loaded column: answers, no trap, and a
        // lift never above the flight ceiling (from above it, the "lift" is down to it).
        for definition in airSpecies {
            XCTAssertFalse(definition.flyerCanLaunch(in: world, x: 24, y: bottom + 1, z: 8), definition.id)
            XCTAssertFalse(definition.flyerCanLaunch(in: world, x: 24, y: top, z: 8), definition.id)
            for py in [Double(bottom + 1), 64, ceiling - 1, ceiling, Double(top)] {
                for sky in [false, true] {
                    if let lift = definition.flyerLift(in: world, 24.5, py, 8.5, toOpenSky: sky) {
                        XCTAssertLessThanOrEqual(lift.y, ceiling, "\(definition.id) from \(py)")
                    }
                }
            }
            XCTAssertNotNil(definition.flyerLift(in: world, 24.5, 64, 8.5, toOpenSky: true), definition.id)
            XCTAssertNil(definition.flyerLift(in: world, 1_000_000.5, 64, 8.5), "\(definition.id): an unloaded column")
            XCTAssertNil(definition.flyerLift(in: world, 24.5, 64, 8.5 + 1_000_000, toOpenSky: true), definition.id)
            XCTAssertNil(definition.flyerLift(in: world, 47.5, 64, 8.5, toOpenSky: true),
                         "\(definition.id): wings reaching past the loaded chunks are no open sky")
        }
    }

    /// `prehistoricHasClearance` as it was before 1.5.5, verbatim.
    func legacyPrehistoricHasClearance(_ world: World, definition: PrehistoricCreatureDefinition,
                                       x: Int, y: Int, z: Int, requireGround: Bool) -> Bool {
        let radius = definition.bodyClearanceRadius
        let supportRadius = definition.groundSupportRadius
        let vertical = definition.bodyClearanceHeight
        for zz in (z - radius)...(z + radius) {
            for xx in (x - radius)...(x + radius) {
                guard world.isLoadedAt(xx, zz) else { return false }
                if requireGround,
                   abs(xx - x) <= supportRadius,
                   abs(zz - z) <= supportRadius {
                    let below = world.getBlock(xx, y - 1, zz) >> 4
                    guard below > 0, below < blockDefs.count, blockDefs[below].solid else { return false }
                }
                for yy in y..<(y + vertical) {
                    let cell = world.getBlock(xx, yy, zz)
                    let block = cell >> 4
                    if definition.medium == .aquatic {
                        if block != Int(B.water) && !(cell >= 0 && isWaterlogged(UInt16(cell))) { return false }
                    } else if block == Int(B.water) || block == Int(B.lava)
                        || block < 0 || (block != 0 && (block >= blockDefs.count || !blockDefs[block].replaceable)) {
                        return false
                    } else if cell >= 0, cell <= Int(UInt16.max), isWaterlogged(UInt16(cell)) {
                        return false
                    }
                }
            }
        }
        return true
    }

    func testAdmissionIsUnchangedForLandAndSeaCreaturesAndOnlyNarrowedForFlyers() throws {
        // Against the pre-1.5.5 body, for every species of every medium, over 12 generated places
        // sprinkled with water, lava, water-filled flora, glass, fences, torches, grass and snow,
        // at 40 seeded sites each and both ground rules: land and sea creatures answer exactly as
        // before; a flyer answers as before without ground, and with ground as before AND
        // `flyerCanLaunch`.
        let sprinkles: [UInt16] = [cell(B.water), cell(B.lava), cell(B.tall_seagrass), cell(B.kelp), cell(B.glass),
                                   cell(B.oak_fence), cell(B.torch), cell(B.short_grass), cell(B.snow)]
        var compared = 0, narrowed = 0, admittedBefore = 0
        for seed: UInt32 in 1...12 {
            let place = GeneratedPlace(seed: seed &+ 100)
            let world = makeShapedWorld { x, y, z in
                if (61...70).contains(y), GeneratedPlace.hole(seed, 3, x &* 131 &+ y, z, 0.04) {
                    return sprinkles[Int(UInt32(truncatingIfNeeded: x &* 7 &+ y &* 13 &+ z &* 17)) % sprinkles.count]
                }
                if seed % 3 == 0, (60...66).contains(y), abs(x - 30) <= 6, abs(z - 14) <= 6 { return cell(B.water) }
                return place.block(x, y, z)
            }
            var rng = RandomX(seed)
            for _ in 0..<40 {
                let x = rng.nextInt(48), z = -16 + rng.nextInt(48), y = 60 + rng.nextInt(12)
                for definition in PrehistoricCreatureDefinition.all {
                    for requireGround in [true, false] {
                        let before = legacyPrehistoricHasClearance(world, definition: definition, x: x, y: y, z: z, requireGround: requireGround)
                        let now = prehistoricHasClearance(world, definition: definition, x: x, y: y, z: z, requireGround: requireGround)
                        let label = "seed \(seed) \(definition.id) at (\(x), \(y), \(z)) ground \(requireGround)"
                        compared += 1
                        if before { admittedBefore += 1 }
                        if definition.medium == .air, requireGround {
                            XCTAssertEqual(now, before && definition.flyerCanLaunch(in: world, x: x, y: y, z: z), label)
                            if before && !now { narrowed += 1 }
                        } else {
                            XCTAssertEqual(now, before, label)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(admittedBefore, compared / 20, "fixture: the old rule must admit a fair share of the sites")
        XCTAssertGreaterThan(narrowed, 0, "fixture: some flyer site must be refused by the launch rule alone")
    }

    // MARK: - save and reload mid-climb and mid-landing

    func traceAfterReload(_ saved: [String: Any], in world: World, ticks: Int) throws -> (steps: [String], flyer: PrehistoricCreature) {
        let restored = try XCTUnwrap(loadEntity(world, saved) as? PrehistoricCreature)
        var steps: [String] = []
        _ = run(restored, ticks: ticks) { tick in
            steps.append("\(tick) \(restored.x) \(restored.y) \(restored.z) \(restored.action.rawValue) \(restored.onGround)")
        }
        return (steps, restored)
    }

    func testFlyerSavedMidClimbReloadsDeterministicallyAndStillClimbsOut() throws {
        // Saved half-way up a canopy gap (its flight target is not part of a save, so the reloaded
        // flyer plans again): two reloads of one save live the same life, and both leave the gap
        // without entering a leaf.
        let world = makeShapedWorld(shape(of: .canopyGap))
        let flyer = try makeFlyer(world, seed: 1)
        flyer.adoptPersistedId(0x5EED)
        var ticks = 0
        while flyer.y < 66, ticks < 80 { flyer.tick(); ticks += 1 }
        XCTAssertTrue((66.0..<68.0).contains(flyer.y), "fixture: save inside the leaves, y \(flyer.y)")
        let saved = flyer.save()
        let first = try traceAfterReload(saved, in: world, ticks: 150)
        let second = try traceAfterReload(saved, in: world, ticks: 150)
        XCTAssertEqual(first.steps, second.steps)
        var original: [String] = []
        _ = run(flyer, ticks: 150) { tick in original.append("\(tick) \(flyer.x) \(flyer.y) \(flyer.z) \(flyer.action.rawValue) \(flyer.onGround)") }
        let diverged = zip(original, first.steps).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        print("RELOAD mid-climb: reloaded copy \(diverged.map { "diverges from the original at tick \($0)" } ?? "matches the original")")
        for restored in [first.flyer, flyer] {
            XCTAssertGreaterThan(restored.y, 69, "the flyer did not leave the gap after the save")
            XCTAssertNil(blockInside(restored))
        }
    }

    func testFlyerSavedMidLandingReloadsAndSettlesOnAPerch() throws {
        // Saved during the approach of a landing on open ground: the reloaded flyer looks for a
        // perch again, finds one and settles on it exactly, the same way on two reloads.
        let world = makeFlatWorld()
        let flyer = try makeFlyer(world, seed: 3)
        flyer.adoptPersistedId(0x5EED)
        var ticks = 0
        while !(flyer.action == .landing && flyer.y > 64.6), ticks < 2_000 { flyer.tick(); ticks += 1 }
        XCTAssertEqual(flyer.action, .landing, "fixture: save mid-landing")
        let saved = flyer.save()
        let first = try traceAfterReload(saved, in: world, ticks: 160)
        let second = try traceAfterReload(saved, in: world, ticks: 160)
        XCTAssertEqual(first.steps, second.steps)
        let settled = try XCTUnwrap(first.steps.firstIndex { $0.hasSuffix(" idle true") },
                                    "the reloaded flyer never settled: \(first.steps.suffix(3))")
        XCTAssertLessThanOrEqual(settled, 100)
        let third = try XCTUnwrap(loadEntity(world, saved) as? PrehistoricCreature)
        for _ in 0...settled { third.tick() }
        let perch = try XCTUnwrap(third.definition.flyerLandingTarget(in: world, x: ifloor(third.x), z: ifloor(third.z)))
        XCTAssertEqual(third.action, .idle)
        XCTAssertTrue(third.onGround)
        XCTAssertEqual(third.data.airborne, false)
        XCTAssertEqual(perch.x, third.x); XCTAssertEqual(perch.y, third.y); XCTAssertEqual(perch.z, third.z)
    }

    // MARK: - cost

    func testLaunchAndLiftCostStaysBounded() throws {
        // 10,000 calls each of `flyerCanLaunch` and `flyerLift` for the smallest and the largest
        // species, on open ground, under a gap in a high canopy and under a closed canopy. The
        // numbers are printed for the report; the bound only catches a blow-up (a debug build
        // runs these at tens of microseconds a call).
        let places: [(String, World)] = [
            ("open", makeFlatWorld()),
            ("gap 69-71", canopyWorld(open: [Column(x: 24, z: 8)], layers: 69...71)),
            ("closed 66-68", canopyWorld(open: [])),
        ]
        for id in ["prehistoric.microraptor", "prehistoric.quetzalcoatlus"] {
            let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named(id))
            for (name, world) in places {
                var launches = 0, lifts = 0
                let launchStart = Date()
                for _ in 0..<10_000 where definition.flyerCanLaunch(in: world, x: 24, y: 64, z: 8) { launches += 1 }
                let launchTime = Date().timeIntervalSince(launchStart)
                let liftStart = Date()
                for _ in 0..<10_000 where definition.flyerLift(in: world, 24.5, 64, 8.5) != nil { lifts += 1 }
                let liftTime = Date().timeIntervalSince(liftStart)
                print("COST \(id) \(name): flyerCanLaunch \(Int(launchTime * 100_000)) ns/call (\(launches > 0 ? "launches" : "refused")), flyerLift \(Int(liftTime * 100_000)) ns/call (\(lifts > 0 ? "lift" : "none"))")
                XCTAssertLessThan(launchTime, 10, "\(id) \(name): 10,000 launches took \(launchTime) s")
                XCTAssertLessThan(liftTime, 10, "\(id) \(name): 10,000 lifts took \(liftTime) s")
            }
        }
        // What a tick costs a flyer resting boxed in (one search per 20 ticks) and one hovering
        // with no route (a search on every tick), over 1,000 ticks each.
        let closed = makeShapedWorld(shape(of: .closedCanopy)), gap = canopyWorld(open: [Column(x: 24, z: 8)])
        let resting = try makeFlyer(closed, seed: 1)
        let hovering = try makeFlyer(gap, seed: 4, at: (24.8, 64, 8.5))
        hovering.vx = 0.05
        for (name, flyer) in [("resting boxed in", resting), ("hovering without a route", hovering)] {
            _ = run(flyer, ticks: 20)
            let start = Date()
            _ = run(flyer, ticks: 1_000)
            let perTick = Date().timeIntervalSince(start) / 1_000
            print("COST a dimorphodon \(name): \(Int(perTick * 1_000_000_000)) ns/tick")
            XCTAssertLessThan(perTick, 0.01, name)
        }
        withExtendedLifetime((closed, gap)) {}
    }
}
