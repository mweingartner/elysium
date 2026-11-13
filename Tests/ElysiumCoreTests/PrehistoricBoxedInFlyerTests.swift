import Foundation
import XCTest
@testable import ElysiumCore

/// A flyer with nowhere to fly. Found in a player's Jurassic world on 2026-11-12: dimorphodons
/// standing on the forest floor in a gap of the canopy, where the leaves of the neighbouring
/// trees close the 3x3 column a take-off needs. Each tried to take off on every tick, gave up in
/// the same tick, and played a "takes off" and a "settles" cue each time: forty sounds a second
/// from one animal, heard from forty blocks as an engine.
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
    func growCanopy(_ world: World, layers: ClosedRange<Int> = PrehistoricBoxedInFlyerTests.canopy, reach: Int = 20) {
        let leaves = Int(cell(B.oak_leaves))
        for z in (Self.site.z - reach)...(Self.site.z + reach) {
            for x in (Self.site.x - reach)...(Self.site.x + reach) where !(x == Self.site.x && z == Self.site.z) {
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
        let world = makeFlatWorld()
        growCanopy(world, layers: 69...71)
        let flyer = try makeFlyer(world)
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

    func testFlyerHeldInTheAirWithNoRouteIsSilent() throws {
        // A chimney of leaves from the ground up around a flyer high inside it, open above: it
        // has nothing to stand on, its wings fit neither up nor down the shaft, and the foot of
        // the shaft is no place to land. It does not rest, and it announces nothing either.
        let world = makeFlatWorld()
        let leaves = Int(cell(B.oak_leaves))
        for dz in -1...1 { for dx in -1...1 where dx != 0 || dz != 0 {
            for y in 64...90 { _ = world.setBlock(Self.site.x + dx, y, Self.site.z + dz, leaves) }
        } }
        let hover = (x: Double(Self.site.x) + 0.5, y: 80.0, z: Double(Self.site.z) + 0.5)
        let flyer = try makeFlyer(world, at: hover)
        var searches = 0
        var before = flyer.rng.stateWords

        let heard = run(flyer, ticks: 200) { _ in
            let after = flyer.rng.stateWords
            if after != before { searches += 1 }
            before = after
        }

        XCTAssertTrue(heard.isEmpty, "\(heard.count) sounds: \(Set(heard.map(\.name)))")
        XCTAssertEqual(flyer.x, hover.x); XCTAssertEqual(flyer.y, hover.y); XCTAssertEqual(flyer.z, hover.z)
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertEqual(searches, 200, "a flyer with no ground under it and no perch below keeps looking on every tick")
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
