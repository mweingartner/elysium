import Foundation
import XCTest
@testable import ElysiumCore

/// A flyer with nowhere to fly. Found in a player's Jurassic world on 2026-11-12: dimorphodons
/// standing on the forest floor in a gap of the canopy, where the leaves of the neighbouring
/// trees close the 3x3 column a take-off needs. Each tried to take off on every tick, gave up in
/// the same tick, and played a "takes off" and a "settles" cue each time: forty sounds a second
/// from one animal, heard from forty blocks as an engine.
///
/// 1.5.4 made such a flyer quiet. 1.5.5 lets one whose body fits the gap climb out of it with
/// folded wings and stops the spawn paths from placing a flyer where it cannot take off. So the
/// fixture for "cannot leave" is the canopy without a gap; the gap has its own tests below.
final class PrehistoricBoxedInFlyerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerBlockEntityHandlers()
    }

    struct Heard { let tick: Int; let name: String }

    /// Flat grass at y 63 over nine loaded chunks, so a body stands at y 64.
    func makeFlatWorld() -> World {
        let world = World(dim: .overworld, seed: 0xC0DE, generationSettings: .init(preset: .prehistoricLostWorld))
        for cz in -1...1 {
            for cx in 0...2 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        chunk.set(x, 62, z, cell(B.stone))
                        chunk.set(x, 63, z, cell(B.grass_block))
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    static let site = (x: 24, y: 64, z: 8)
    static let canopy = 66...68

    /// The forest gap: three layers of leaves two blocks above the ground everywhere within
    /// `reach` of the site, with the one column above the site left open to the sky.
    func growCanopy(_ world: World, layers: ClosedRange<Int> = PrehistoricBoxedInFlyerTests.canopy,
                    gap: Bool = false, reach: Int = 20) {
        let leaves = Int(cell(B.oak_leaves))
        for z in (Self.site.z - reach)...(Self.site.z + reach) {
            for x in (Self.site.x - reach)...(Self.site.x + reach) where !(gap && x == Self.site.x && z == Self.site.z) {
                guard world.isLoadedAt(x, z) else { continue }
                for y in layers { _ = world.setBlock(x, y, z, leaves) }
            }
        }
    }

    func clearCanopy(_ world: World, reach: Int = 20) {
        for z in (Self.site.z - reach)...(Self.site.z + reach) {
            for x in (Self.site.x - reach)...(Self.site.x + reach) {
                guard world.isLoadedAt(x, z) else { continue }
                for y in Self.canopy { _ = world.setBlock(x, y, z, 0) }
            }
        }
    }

    func makeFlyer(_ world: World, _ id: String = "prehistoric.dimorphodon", seed: UInt32 = 42,
                           at position: (x: Double, y: Double, z: Double)? = nil) throws -> PrehistoricCreature {
        let definition = try XCTUnwrap(PrehistoricCreatureDefinition.named(id))
        let flyer = PrehistoricCreature(world: world, definition: definition)
        let p = position ?? (Double(Self.site.x) + 0.5, Double(Self.site.y), Double(Self.site.z) + 0.5)
        flyer.setPos(p.x, p.y, p.z)
        flyer.rng = RandomX(seed)
        flyer.persistent = true
        return flyer
    }

    /// Ticks the flyer and returns every sound the world was asked to play, with its tick.
    func run(_ flyer: PrehistoricCreature, ticks: Int, each: (Int) -> Void = { _ in }) -> [Heard] {
        var heard: [Heard] = []
        var now = 0
        let world = flyer.world
        let previous = world.hooks.playSound
        world.hooks.playSound = { name, _, _, _, _, _ in heard.append(Heard(tick: now, name: name)) }
        defer { world.hooks.playSound = previous }
        for tick in 0..<ticks {
            now = tick
            flyer.tick()
            each(tick)
        }
        return heard
    }

    func cue(_ flyer: PrehistoricCreature, _ cue: PrehistoricSoundCue) -> String {
        flyer.definition.soundName(for: cue)
    }

    // MARK: - the reported noise

    func testFlyerBoxedInUnderACanopyDoesNotAnnounceATakeOffItCannotMake() throws {
        let world = makeFlatWorld()
        growCanopy(world)
        let flyer = try makeFlyer(world)
        let start = (flyer.x, flyer.y, flyer.z)
        var movedOn: [Int] = []

        let heard = run(flyer, ticks: 400) { tick in
            if flyer.x != start.0 || flyer.y != start.1 || flyer.z != start.2 { movedOn.append(tick) }
        }

        XCTAssertEqual(movedOn, [], "a boxed-in flyer must not move at all, not only end where it began")
        let takeoffs = heard.filter { $0.name == cue(flyer, .takeoff) }.count
        let settles = heard.filter { $0.name == cue(flyer, .idle) }.count
        XCTAssertEqual(takeoffs, 0, "a take-off that never happens was announced \(takeoffs) times in 400 ticks")
        XCTAssertEqual(settles, 0, "a flyer that never left was said to settle \(settles) times in 400 ticks")
        // What is left is the animal's own call, at most once every 90 ticks.
        XCTAssertTrue(heard.allSatisfy { $0.name == cue(flyer, .ambient) }, "\(Set(heard.map(\.name)))")
        XCTAssertLessThanOrEqual(heard.count, 400 / 90 + 1)
        XCTAssertEqual(flyer.x, start.0); XCTAssertEqual(flyer.y, start.1); XCTAssertEqual(flyer.z, start.2)
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertTrue(flyer.onGround)
        XCTAssertEqual(flyer.data.airborne, false)
    }

    func testFlyerOnAPerchItCannotLeaveDoesNotAnnounceALandingOnTheSpot() throws {
        // A higher canopy: the gap is a proper perch (the body and its approach are clear), but
        // the leaves still close every way up. The only landing place in reach is the one the
        // flyer stands on, and standing there is no landing.
        // A pteranodon: its body is wider than the one-column gap, so it cannot climb out.
        let world = makeFlatWorld()
        growCanopy(world, layers: 69...71, gap: true)
        let flyer = try makeFlyer(world, "prehistoric.pteranodon")
        XCTAssertNotNil(flyer.definition.flyerLandingTarget(in: world, x: Self.site.x, z: Self.site.z),
                        "fixture: the site must be a perch")
        let start = (flyer.x, flyer.y, flyer.z)

        let heard = run(flyer, ticks: 600)

        XCTAssertTrue(heard.allSatisfy { $0.name == cue(flyer, .ambient) }, "\(Set(heard.map(\.name)))")
        XCTAssertLessThanOrEqual(heard.count, 600 / 90 + 1)
        XCTAssertEqual(flyer.x, start.0); XCTAssertEqual(flyer.y, start.1); XCTAssertEqual(flyer.z, start.2)
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertTrue(flyer.onGround)
    }

    func testEveryFlyingSpeciesStaysQuietWhenBoxedIn() throws {
        for definition in PrehistoricCreatureDefinition.all where definition.medium == .air {
            for seed: UInt32 in [1, 7, 42, 0xA11D_5100] {
                let world = makeFlatWorld()
                growCanopy(world)
                let flyer = try makeFlyer(world, definition.id, seed: seed)
                let heard = run(flyer, ticks: 200)
                let actionCues = heard.filter { $0.name != cue(flyer, .ambient) }
                XCTAssertTrue(actionCues.isEmpty, "\(definition.id) seed \(seed): \(actionCues.count) cues, \(Set(actionCues.map(\.name)))")
                XCTAssertLessThanOrEqual(heard.count, 200 / 90 + 1, "\(definition.id) seed \(seed)")
            }
        }
    }

    func testBoxedInFlyerLooksForAWayOutOnlyWhenItsRestRunsOut() throws {
        let world = makeFlatWorld()
        growCanopy(world)
        let flyer = try makeFlyer(world)
        // Keep the animal's own call out of the count: it draws from the same stream.
        flyer.ambientSoundTimer = 10_000
        var searches = 0
        var before = flyer.rng.stateWords
        _ = run(flyer, ticks: 400) { _ in
            let after = flyer.rng.stateWords
            if after != before { searches += 1 }
            before = after
        }
        // A search draws headings for its candidates; a resting tick draws nothing. The rest is
        // 20 ticks long, so 400 ticks hold at most 20 searches (and the first tick's).
        XCTAssertGreaterThanOrEqual(searches, 10, "the flyer must keep looking for a way out")
        XCTAssertLessThanOrEqual(searches, 400 / 20 + 1, "the flyer searched on \(searches) of 400 ticks")
    }

    func testFlyerHeldInTheAirWithNoRouteComesDownAndRestsQuietly() throws {
        // A chimney of leaves from the ground up around a flyer high inside it, with a lid: its
        // wings fit neither up nor down the shaft, its body does not pass the lid, and the foot
        // of the shaft is no place to land. It has nowhere to fly. It does not hang there for
        // good: it comes down the shaft to the ground, stands, and rests. It announces nothing.
        let world = makeFlatWorld()
        let leaves = Int(cell(B.oak_leaves))
        for dz in -1...1 { for dx in -1...1 where dx != 0 || dz != 0 {
            for y in 64...90 { _ = world.setBlock(Self.site.x + dx, y, Self.site.z + dz, leaves) }
        } }
        _ = world.setBlock(Self.site.x, 91, Self.site.z, leaves)
        let hover = (x: Double(Self.site.x) + 0.5, y: 80.0, z: Double(Self.site.z) + 0.5)
        let flyer = try makeFlyer(world, at: hover)
        var searches = 0
        var before = flyer.rng.stateWords
        var claimedGroundInTheAir: Int?
        var landedAt: Int?

        func count(_ tick: Int) {
            let after = flyer.rng.stateWords
            if after != before { searches += 1 }
            before = after
        }
        flyer.ambientSoundTimer = 10_000
        let coming = run(flyer, ticks: 200) { tick in
            count(tick)
            if flyer.y > 64.5 {
                if claimedGroundInTheAir == nil, flyer.onGround || flyer.data.airborne != true { claimedGroundInTheAir = tick }
            } else if landedAt == nil, flyer.onGround {
                landedAt = tick
            }
        }
        XCTAssertTrue(coming.isEmpty, "\(coming.count) sounds: \(Set(coming.map(\.name)))")
        XCTAssertNil(claimedGroundInTheAir, "in the shaft it reported onGround or folded wings on tick \(claimedGroundInTheAir ?? -1)")
        XCTAssertNotNil(landedAt, "the flyer never reached the foot of the shaft, y \(flyer.y)")
        XCTAssertEqual(flyer.x, hover.x); XCTAssertEqual(flyer.z, hover.z)
        XCTAssertEqual(flyer.y, 64, accuracy: 1e-6)

        searches = 0
        let resting = run(flyer, ticks: 200, each: count)
        XCTAssertTrue(resting.isEmpty, "\(Set(resting.map(\.name)))")
        XCTAssertLessThanOrEqual(searches, 200 / 20 + 1, "standing at the foot of the shaft it searched on \(searches) of 200 ticks")
        XCTAssertTrue(flyer.onGround)
        XCTAssertEqual(flyer.data.airborne, false)
        XCTAssertEqual(flyer.action, .idle)
    }

    // MARK: - the canopy gap: a body that fits climbs out with folded wings

    func testSmallFlyerClimbsOutOfTheCanopyGapItWasPlacedIn() throws {
        // The reported site: leaves two to four blocks up everywhere but the flyer's own column.
        // Its wings do not fit, its body does. It climbs its column and flies off above the trees.
        for id in ["prehistoric.dimorphodon", "prehistoric.rhamphorhynchus", "prehistoric.tapejara", "prehistoric.microraptor"] {
            for seed: UInt32 in [1, 42] {
                let world = makeFlatWorld()
                growCanopy(world, gap: true)
                let flyer = try makeFlyer(world, id, seed: seed)
                XCTAssertLessThanOrEqual(flyer.definition.collisionWidth, 1, "fixture: \(id) must fit one column")
                let above = Double(Self.canopy.upperBound + 1)
                var clearedAt: Int?
                var leftItsColumnBelow = false
                var touchedLeaves = false
                let heard = run(flyer, ticks: 200) { tick in
                    if flyer.y < above {
                        if ifloor(flyer.x) != Self.site.x || ifloor(flyer.z) != Self.site.z { leftItsColumnBelow = true }
                        if flyer.horizontalCollision { touchedLeaves = true }
                    } else if clearedAt == nil {
                        clearedAt = tick
                    }
                }
                let label = "\(id) seed \(seed)"
                let cleared = try XCTUnwrap(clearedAt, "\(label) never rose above the canopy, y \(flyer.y)")
                XCTAssertLessThanOrEqual(cleared, 80, "\(label) took \(cleared) ticks for five blocks")
                XCTAssertFalse(leftItsColumnBelow, "\(label) passed through leaves")
                XCTAssertFalse(touchedLeaves, "\(label) scraped the side of its column")
                let takeoffs = heard.filter { $0.name == cue(flyer, .takeoff) && $0.tick <= cleared }.map(\.tick)
                XCTAssertEqual(takeoffs, [0], "\(label): one take-off, on the tick it starts")
                XCTAssertFalse(heard.contains { $0.name.hasPrefix("entity.generic.") || $0.name == cue(flyer, .hurt) }, label)
                XCTAssertFalse(flyer.dead || flyer.deathTime > 0, label)
            }
        }
    }

    func testFlyerWiderThanTheGapStaysPutAndQuiet() throws {
        for id in ["prehistoric.pteranodon", "prehistoric.quetzalcoatlus"] {
            let world = makeFlatWorld()
            growCanopy(world, gap: true)
            let flyer = try makeFlyer(world, id)
            XCTAssertGreaterThan(flyer.definition.collisionWidth, 1, "fixture: \(id) must be wider than one column")
            let start = (flyer.x, flyer.y, flyer.z)
            let heard = run(flyer, ticks: 400)
            XCTAssertTrue(heard.allSatisfy { $0.name == cue(flyer, .ambient) }, "\(id): \(Set(heard.map(\.name)))")
            XCTAssertEqual(flyer.x, start.0, id); XCTAssertEqual(flyer.y, start.1, id); XCTAssertEqual(flyer.z, start.2, id)
            XCTAssertEqual(flyer.action, .idle, id)
        }
    }

    func testFlyerStandingInWaterInAGapRisesOutOfIt() throws {
        // Water in its own cell under the gap: it used to stand there until its air ran out.
        let world = makeFlatWorld()
        growCanopy(world, gap: true)
        _ = world.setBlock(Self.site.x, Self.site.y, Self.site.z, Int(cell(B.water)))
        let flyer = try makeFlyer(world)
        var highest = flyer.y
        let heard = run(flyer, ticks: 400) { _ in highest = max(highest, flyer.y) }
        XCTAssertGreaterThan(highest, Double(Self.canopy.upperBound + 1), "the flyer stayed in the water")
        XCTAssertFalse(heard.contains { $0.name == cue(flyer, .hurt) || $0.name == cue(flyer, .death) }, "\(Set(heard.map(\.name)))")
        XCTAssertFalse(flyer.dead || flyer.deathTime > 0)
    }

    // MARK: - where a flyer may be placed

    private var flyers: [PrehistoricCreatureDefinition] { PrehistoricCreatureDefinition.all.filter { $0.medium == .air } }

    private func mayBePlaced(_ definition: PrehistoricCreatureDefinition, in world: World) -> Bool {
        let placed = spawnPlacementIsValid(world, definition.id, Self.site.x, Self.site.y, Self.site.z)
        XCTAssertEqual(placed, prehistoricHasClearance(world, definition: definition, x: Self.site.x, y: Self.site.y,
                                                       z: Self.site.z, requireGround: true), definition.id)
        return placed
    }

    func testNoFlyerIsPlacedWhereItCannotTakeOff() throws {
        // The reported site, a closed canopy and a cave roof. The body fits in all three, which
        // was the whole rule before; none is a perch with a lift.
        let roof: (World) -> Void = { world in
            for z in -12...28 { for x in 4...44 { _ = world.setBlock(x, 66, z, Int(cell(B.stone))) } }
        }
        let places: [(String, (World) -> Void)] = [
            ("canopy gap", { self.growCanopy($0, gap: true) }),
            ("closed canopy", { self.growCanopy($0) }),
            ("cave roof", roof),
        ]
        for (name, build) in places {
            let world = makeFlatWorld()
            build(world)
            for definition in flyers {
                XCTAssertFalse(mayBePlaced(definition, in: world), "\(definition.id) was placed under a \(name)")
            }
        }
    }

    func testFlyerIsPlacedOnOpenGroundAndUnderAGapItCanClimb() throws {
        let open = makeFlatWorld()
        for definition in flyers { XCTAssertTrue(mayBePlaced(definition, in: open), "\(definition.id) on open ground") }

        // A higher canopy with a one-column gap: a perch for a narrow body, with a lift through
        // the gap. A body wider than the gap has no lift there and is not placed.
        let gap = makeFlatWorld()
        growCanopy(gap, layers: 69...71, gap: true)
        for definition in flyers {
            XCTAssertEqual(mayBePlaced(definition, in: gap), definition.collisionWidth <= 1, definition.id)
        }
    }

    func testEveryPlaceThatAdmitsAFlyerCanBeLeft() throws {
        // The rule the spawn paths now hold: where a flyer may be placed, it takes off. Canopies
        // at five heights, with and without a gap, and open ground; every flying species.
        var shapes: [(String, (World) -> Void)] = [("open ground", { _ in })]
        for bottom in 66...70 {
            shapes.append(("gap canopy from \(bottom)", { self.growCanopy($0, layers: bottom...(bottom + 2), gap: true) }))
            shapes.append(("closed canopy from \(bottom)", { self.growCanopy($0, layers: bottom...(bottom + 2)) }))
        }
        var admitted = 0
        for (name, build) in shapes {
            let world = makeFlatWorld()
            build(world)
            for definition in flyers where mayBePlaced(definition, in: world) {
                admitted += 1
                let flyer = try makeFlyer(world, definition.id, seed: 7)
                var highest = flyer.y
                _ = run(flyer, ticks: 300) { _ in highest = max(highest, flyer.y) }
                XCTAssertGreaterThan(highest, Double(Self.site.y) + 3, "\(definition.id) was placed under a \(name) and never left")
            }
        }
        XCTAssertGreaterThan(admitted, flyers.count, "fixture: more than the open ground must admit a flyer")
    }

    func testPlacingLandCreaturesIsUnchanged() throws {
        // The launch rule is for flyers. A small land animal still stands under the canopy.
        let world = makeFlatWorld()
        growCanopy(world)
        let runner = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.compsognathus"))
        XCTAssertEqual(runner.medium, .land)
        XCTAssertTrue(spawnPlacementIsValid(world, runner.id, Self.site.x, Self.site.y, Self.site.z))
    }

    // MARK: - what must keep working

    func testFlyerLeavesAsSoonAsTheCanopyOpensAndAnnouncesThatOnce() throws {
        let world = makeFlatWorld()
        growCanopy(world)
        let flyer = try makeFlyer(world)
        XCTAssertTrue(run(flyer, ticks: 100).allSatisfy { $0.name == cue(flyer, .ambient) })
        let ground = flyer.y

        clearCanopy(world)
        var tookOffAt: Int?
        var highest = flyer.y
        let heard = run(flyer, ticks: 200) { tick in
            if tookOffAt == nil, flyer.action == .takeoff { tookOffAt = tick }
            highest = max(highest, flyer.y)
        }

        let left = try XCTUnwrap(tookOffAt, "the flyer never took off after the canopy was cleared")
        XCTAssertLessThanOrEqual(left, 20, "a boxed-in flyer looks again within one rest of 20 ticks")
        XCTAssertGreaterThan(highest, ground + 2, "the flyer took off but did not climb")
        let firstTakeoffCue = try XCTUnwrap(heard.first { $0.name == cue(flyer, .takeoff) })
        XCTAssertEqual(firstTakeoffCue.tick, left, "the take-off cue belongs to the tick the flyer takes off")
        let duringTakeoff = heard.filter { $0.name == cue(flyer, .takeoff) && $0.tick < left + 36 }.map(\.tick)
        XCTAssertEqual(duringTakeoff, [left], "one take-off is announced once")
    }

    func testFlyerInTheOpenStillTakesOffLandsAndNeverRepeatsACueTickAfterTick() throws {
        for seed: UInt32 in [3, 42, 99] {
            let world = makeFlatWorld()
            let flyer = try makeFlyer(world, seed: seed)
            var actions = Set<PrehistoricAction>()
            let heard = run(flyer, ticks: 1_200) { _ in actions.insert(flyer.action) }

            XCTAssertTrue(actions.contains(.takeoff), "seed \(seed): \(actions)")
            XCTAssertTrue(actions.contains(.glide) || actions.contains(.flap), "seed \(seed): \(actions)")
            XCTAssertTrue(heard.contains { $0.name == cue(flyer, .takeoff) }, "seed \(seed)")
            // The periodic landing still begins and is announced. (That it never completes on
            // level ground is pinned by `testFlyerInTheOpenCompletesALandingAndRests`.)
            XCTAssertTrue(actions.contains(.landing), "seed \(seed): \(actions)")
            XCTAssertTrue(heard.contains { $0.name == cue(flyer, .landing) }, "seed \(seed)")
            // No cue of one kind on two ticks in a row, and no more than a handful a second.
            for name in Set(heard.map(\.name)) where name != cue(flyer, .wingbeat) {
                let ticks = heard.filter { $0.name == name }.map(\.tick)
                for (a, b) in zip(ticks, ticks.dropFirst()) {
                    XCTAssertGreaterThan(b - a, 1, "seed \(seed): \(name) on ticks \(a) and \(b)")
                }
            }
            for window in stride(from: 0, to: 1_200, by: 20) {
                let inWindow = heard.filter { $0.tick >= window && $0.tick < window + 20 }.count
                XCTAssertLessThanOrEqual(inWindow, 8, "seed \(seed): \(inWindow) sounds in the second starting at tick \(window)")
            }
        }
    }
}
