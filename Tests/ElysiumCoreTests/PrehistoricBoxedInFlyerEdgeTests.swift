import Foundation
import XCTest
@testable import ElysiumCore

/// The edges of the boxed-in flyer fix (`PrehistoricBoxedInFlyerTests`): water and lava in and
/// around the body, the edge of the loaded world, a floor dug away under a resting flyer, a cage
/// closed around a flyer in flight, save and reload, determinism, and a cue-rate bound over every
/// flying species and several enclosures, and over every creature of every medium.
///
/// The tests under "known defects" fail on purpose. Each pins a defect in the flight controller
/// that is older than the fix (the same scenario gives the same result on the pre-fix code); they
/// stay red until the controller is changed.
extension PrehistoricBoxedInFlyerTests {

    // MARK: - fixture

    /// The flat world of `makeFlatWorld`, with `shape` deciding extra blocks from y 60 to 100.
    /// The blocks go into the chunks before lighting, which is far cheaper than `setBlock`.
    func makeShapedWorld(_ shape: (_ x: Int, _ y: Int, _ z: Int) -> UInt16?) -> World {
        let world = World(dim: .overworld, seed: 0xC0DE, generationSettings: .init(preset: .prehistoricLostWorld))
        for cz in -1...1 {
            for cx in 0...2 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for lz in 0..<CHUNK_W {
                    for lx in 0..<CHUNK_W {
                        chunk.set(lx, 62, lz, cell(B.stone))
                        chunk.set(lx, 63, lz, cell(B.grass_block))
                        let x = cx * CHUNK_W + lx, z = cz * CHUNK_W + lz
                        for y in 60...100 { if let block = shape(x, y, z) { chunk.set(lx, y, lz, block) } }
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    /// One loaded chunk of flat grass (x and z 0 to 15): everything past it is unloaded.
    func makeOneChunkWorld() -> World {
        let world = World(dim: .overworld, seed: 0xC0DE, generationSettings: .init(preset: .prehistoricLostWorld))
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
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
        return world
    }

    /// Named enclosures around the site, for the property tests.
    enum Enclosure: String, CaseIterable {
        /// The reported forest gap: leaves at 66 to 68 everywhere but the site's own column.
        case canopyGap
        /// The same leaves, also over the site.
        case closedCanopy
        /// A stone ceiling at 66 everywhere.
        case caveRoof
        /// A ring of leaves from the ground to 90 around the site, open above.
        case chimney
        /// A stone room around the site, 9 by 9 inside and 7 high.
        case room
        /// The forest gap with a block of water in the site's own cell.
        case wetGap
    }

    func shape(of enclosure: Enclosure) -> (Int, Int, Int) -> UInt16? {
        let s = Self.site
        let leaves = cell(B.oak_leaves), stone = cell(B.stone), water = cell(B.water)
        switch enclosure {
        case .canopyGap:
            return { x, y, z in (66...68).contains(y) && !(x == s.x && z == s.z) ? leaves : nil }
        case .closedCanopy:
            return { _, y, _ in (66...68).contains(y) ? leaves : nil }
        case .caveRoof:
            return { _, y, _ in y == 66 ? stone : nil }
        case .chimney:
            return { x, y, z in
                (64...90).contains(y) && abs(x - s.x) <= 1 && abs(z - s.z) <= 1 && !(x == s.x && z == s.z) ? leaves : nil
            }
        case .room:
            return { x, y, z in
                let dx = abs(x - s.x), dz = abs(z - s.z)
                guard dx <= 5, dz <= 5, (64...71).contains(y) else { return nil }
                return dx == 5 || dz == 5 || y == 71 ? stone : nil
            }
        case .wetGap:
            return { x, y, z in
                if x == s.x, z == s.z, y == 64 { return water }
                return (66...68).contains(y) && !(x == s.x && z == s.z) ? leaves : nil
            }
        }
    }

    /// The sounds that announce a change of action (`setAction`), as opposed to the animal's own
    /// call, its wingbeats, steps, hurts and falls.
    func actionCues(_ flyer: PrehistoricCreature, _ heard: [Heard]) -> [Heard] {
        let names = Set(PrehistoricAction.allCases.map { flyer.definition.soundName(for: $0.soundCue) })
        return heard.filter { names.contains($0.name) }
    }

    /// Ticks the flyer with its own call silenced and counts the ticks on which it searched for a
    /// way out: a search draws headings from the controller RNG, a resting tick draws nothing.
    func runCountingSearches(_ flyer: PrehistoricCreature, ticks: Int,
                             each: (Int) -> Void = { _ in }) -> (heard: [Heard], searches: Int) {
        flyer.ambientSoundTimer = 10_000
        var searches = 0
        var before = flyer.rng.stateWords
        let heard = run(flyer, ticks: ticks) { tick in
            let after = flyer.rng.stateWords
            if after != before { searches += 1 }
            before = after
            each(tick)
        }
        return (heard, searches)
    }

    /// The largest number of `heard` entries in any 20-tick (one-second) window.
    func busiestSecond(_ heard: [Heard], ticks: Int) -> Int {
        stride(from: 0, to: ticks, by: 20).map { start in
            heard.filter { $0.tick >= start && $0.tick < start + 20 }.count
        }.max() ?? 0
    }

    /// Ticks on which two or more of `heard` were played.
    func crowdedTicks(_ heard: [Heard]) -> [Int] {
        var counts: [Int: Int] = [:]
        for sound in heard { counts[sound.tick, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map(\.key).sorted()
    }

    // MARK: - water

    func testFlyerStandingInWaterUnderACanopyKeepsLookingEveryTickAndStaysQuiet() throws {
        // Wet, the flyer must not rest (the rest is for dry ground): it tries to leave on every
        // tick. With nowhere to go, none of those tries may announce anything.
        let world = makeShapedWorld(shape(of: .wetGap))
        let flyer = try makeFlyer(world)
        let start = (flyer.x, flyer.y, flyer.z)

        // 120 ticks keeps the run short of the animal's air running out (300 ticks).
        let (heard, searches) = runCountingSearches(flyer, ticks: 120)

        XCTAssertTrue(flyer.inWater, "fixture: the flyer must stand in the water")
        XCTAssertEqual(searches, 120, "a wet flyer must look for a way out on every tick, not rest")
        XCTAssertTrue(heard.isEmpty, "\(heard.map(\.name))")
        XCTAssertEqual(flyer.x, start.0); XCTAssertEqual(flyer.y, start.1); XCTAssertEqual(flyer.z, start.2)
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertEqual(flyer.data.airborne, false)
    }

    func testWaterBesideABoxedInFlyerDoesNotCancelItsRest() throws {
        // Only water the body touches makes it wet. A puddle in the next cell changes nothing.
        let world = makeShapedWorld { x, y, z in
            if x == Self.site.x + 1, z == Self.site.z, y == 64 { return cell(B.water) }
            return self.shape(of: .canopyGap)(x, y, z)
        }
        let flyer = try makeFlyer(world)

        let (heard, searches) = runCountingSearches(flyer, ticks: 200)

        XCTAssertFalse(flyer.inWater)
        XCTAssertGreaterThanOrEqual(searches, 5, "the flyer must keep looking")
        XCTAssertLessThanOrEqual(searches, 200 / 20 + 1, "water beside the flyer stopped its rest: \(searches) searches")
        XCTAssertTrue(heard.isEmpty, "\(heard.map(\.name))")
    }

    func testWaterUnderAFlyerIsNoGroundToRestOn() throws {
        // Water under its feet is not solid ground: the flyer does not rest on it, keeps looking
        // on every tick, says nothing, and does not claim to stand.
        let world = makeShapedWorld { x, y, z in
            if x == Self.site.x, z == Self.site.z, y == 63 { return cell(B.water) }
            return self.shape(of: .canopyGap)(x, y, z)
        }
        let flyer = try makeFlyer(world)
        let start = (flyer.x, flyer.y, flyer.z)

        let (heard, searches) = runCountingSearches(flyer, ticks: 200)

        XCTAssertEqual(searches, 200)
        XCTAssertTrue(heard.isEmpty, "\(heard.map(\.name))")
        XCTAssertFalse(flyer.onGround)
        XCTAssertEqual(flyer.data.airborne, false)
        XCTAssertEqual(flyer.x, start.0); XCTAssertEqual(flyer.y, start.1); XCTAssertEqual(flyer.z, start.2)
    }

    // MARK: - lava (the security review's `!inLava` alternative)

    func testFlyerRestingOnAPerchTakesOffWhenLavaReachesIt() throws {
        // On open ground the site is a valid perch. Resting there with most of a 90-tick rest
        // left, lava flows into its cell: it must leave at once, not sit out the rest in lava.
        let world = makeFlatWorld()
        let flyer = try makeFlyer(world, seed: 3)
        flyer.addEffect("fire_resistance", 100_000) // keeps it alive and its hurt cues out of the count
        flyer.setAction(.idle, ticks: 90, emitsSound: false)
        let resting = run(flyer, ticks: 5)
        XCTAssertTrue(resting.allSatisfy { $0.name == cue(flyer, .ambient) }, "\(resting.map(\.name))")
        XCTAssertEqual(flyer.action, .idle, "fixture: the flyer must be resting before the lava comes")
        XCTAssertEqual(flyer.y, Double(Self.site.y))
        let restLeft = try XCTUnwrap(flyer.data.prehistoricActionTicks)
        XCTAssertGreaterThan(restLeft, 60)

        _ = world.setBlock(Self.site.x, Self.site.y, Self.site.z, Int(cell(B.lava)))
        var tookOffAt: Int?
        var sawLava = false
        let heard = run(flyer, ticks: 20) { tick in
            sawLava = sawLava || flyer.inLava
            if tookOffAt == nil, flyer.action == .takeoff { tookOffAt = tick }
        }

        XCTAssertTrue(sawLava, "fixture: baseTick must see the lava")
        let left = try XCTUnwrap(tookOffAt, "the flyer kept resting in lava")
        XCTAssertLessThanOrEqual(left, 1, "the flyer must leave within a tick or two, not after its rest")
        XCTAssertGreaterThan(flyer.y, Double(Self.site.y) + 1, "the flyer announced a take-off but did not climb")
        XCTAssertEqual(heard.filter { $0.name == cue(flyer, .takeoff) }.map(\.tick), [left])
    }

    func testBoxedInFlyerInLavaDoesNotRestThere() throws {
        // Boxed in, lava in its cell: it cannot leave, but it must not rest in the lava either.
        // It looks for a way out on every tick, and it says nothing while it does.
        let world = makeShapedWorld(shape(of: .canopyGap))
        let flyer = try makeFlyer(world)
        flyer.addEffect("fire_resistance", 100_000)
        _ = runCountingSearches(flyer, ticks: 3)
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertGreaterThan(flyer.data.prehistoricActionTicks ?? 0, 15, "fixture: it must have a rest left")

        _ = world.setBlock(Self.site.x, Self.site.y, Self.site.z, Int(cell(B.lava)))
        var lavaTicks = 0
        let (heard, searches) = runCountingSearches(flyer, ticks: 15) { _ in if flyer.inLava { lavaTicks += 1 } }

        XCTAssertEqual(lavaTicks, 15, "fixture: baseTick must see the lava on every tick")
        XCTAssertEqual(searches, 15, "a flyer in lava rested instead of looking for a way out")
        XCTAssertTrue(heard.isEmpty, "\(heard.map(\.name))")
        XCTAssertEqual(flyer.y, Double(Self.site.y))
    }

    // MARK: - the edge of the loaded world

    func testFlyerBoxedInByUnloadedChunksRestsWithoutLeavingTheLoadedWorld() throws {
        // A quetzalcoatlus (wing clearance 5) in the corner of the only loaded chunk: every route,
        // the vertical lift and every perch need a cell of an unloaded chunk, so all are refused.
        let world = makeOneChunkWorld()
        let flyer = try makeFlyer(world, "prehistoric.quetzalcoatlus", at: (2.5, 64, 2.5))
        var leftTheWorld = false

        let (heard, searches) = runCountingSearches(flyer, ticks: 400) { _ in
            if !world.isLoadedAt(ifloor(flyer.x), ifloor(flyer.z)) { leftTheWorld = true }
        }

        XCTAssertFalse(leftTheWorld)
        XCTAssertTrue(heard.isEmpty, "\(heard.map(\.name))")
        XCTAssertEqual(flyer.x, 2.5); XCTAssertEqual(flyer.y, 64); XCTAssertEqual(flyer.z, 2.5)
        XCTAssertGreaterThanOrEqual(searches, 10)
        XCTAssertLessThanOrEqual(searches, 400 / 20 + 1, "the flyer searched on \(searches) of 400 ticks")
    }

    func testNoFlyerInTheCornerOfTheLoadedWorldFliesIntoAnUnloadedChunk() throws {
        for definition in PrehistoricCreatureDefinition.all where definition.medium == .air {
            for seed: UInt32 in [1, 42] {
                let world = makeOneChunkWorld()
                let flyer = try makeFlyer(world, definition.id, seed: seed, at: (2.5, 64, 2.5))
                var outside: Int?
                _ = run(flyer, ticks: 300) { tick in
                    if outside == nil, !world.isLoadedAt(ifloor(flyer.x), ifloor(flyer.z)) { outside = tick }
                }
                XCTAssertNil(outside, "\(definition.id) seed \(seed) left the loaded chunk on tick \(outside ?? -1)")
            }
        }
    }

    // MARK: - the world changing under a flyer

    func testBoxedInFlyerWhoseFloorIsDugAwayStopsRestingAndStaysQuiet() throws {
        // What it does: with no ground under it, it no longer rests; it looks for a way out on
        // every tick and, finding none, hovers where it was (the controller applies no gravity
        // to a flyer with no route, the same as `testFlyerHeldInTheAirWithNoRouteIsSilent`).
        let world = makeShapedWorld(shape(of: .canopyGap))
        let flyer = try makeFlyer(world)
        _ = runCountingSearches(flyer, ticks: 5)
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertTrue(flyer.onGround, "fixture: the flyer must be resting before its floor goes")

        _ = world.setBlock(Self.site.x, Self.site.y - 1, Self.site.z, 0)
        let (heard, searches) = runCountingSearches(flyer, ticks: 200)

        XCTAssertEqual(searches, 200, "a flyer with nothing under it must not rest")
        XCTAssertTrue(heard.isEmpty, "\(heard.map(\.name))")
        XCTAssertEqual(flyer.y, Double(Self.site.y))
        XCTAssertEqual(flyer.action, .idle)
        XCTAssertEqual(flyer.data.airborne, false)
    }

    func testFlyerCagedInFlightStaysInsideTheCageAndStaysQuiet() throws {
        // A gliding flyer has a cage of leaves closed around it: its flight target and every new
        // one are now out of reach. It must not pass through the cage, and it must not chatter.
        let world = makeFlatWorld()
        let flyer = try makeFlyer(world, seed: 42)
        _ = run(flyer, ticks: 60)
        XCTAssertTrue([.glide, .flap].contains(flyer.action), "fixture: the flyer must be in flight, was \(flyer.action)")
        XCTAssertGreaterThan(flyer.y, 66, "fixture: the flyer must be in the air")
        let cx = ifloor(flyer.x), cy = ifloor(flyer.y), cz = ifloor(flyer.z)
        let leaves = Int(cell(B.oak_leaves))
        for dz in -3...3 { for dx in -3...3 { for dy in -3...4
        where abs(dx) == 3 || abs(dz) == 3 || dy == -3 || dy == 4 {
            _ = world.setBlock(cx + dx, cy + dy, cz + dz, leaves)
        } } }

        var escaped: Int?
        let heard = run(flyer, ticks: 200) { tick in
            let inside = flyer.x > Double(cx - 2) && flyer.x < Double(cx + 3)
                && flyer.z > Double(cz - 2) && flyer.z < Double(cz + 3)
                && flyer.y >= Double(cy - 2) && flyer.y + flyer.height <= Double(cy + 4)
            if escaped == nil, !inside { escaped = tick }
        }

        XCTAssertNil(escaped, "the flyer left the cage on tick \(escaped ?? -1)")
        let cues = actionCues(flyer, heard)
        XCTAssertLessThanOrEqual(cues.count, 2, "\(cues.map { "\($0.tick):\($0.name)" })")
        XCTAssertTrue(crowdedTicks(cues).isEmpty)
    }

    // MARK: - save and reload

    func testBoxedInFlyerSavedMidRestResumesExactlyWhereItLeftOff() throws {
        let world = makeShapedWorld(shape(of: .canopyGap))
        let flyer = try makeFlyer(world)
        _ = run(flyer, ticks: 27) // a search, then part of the second rest
        XCTAssertEqual(flyer.action, .idle)
        let restLeft = try XCTUnwrap(flyer.data.prehistoricActionTicks)
        XCTAssertTrue((1...19).contains(restLeft), "fixture: save mid-rest, had \(restLeft) ticks")

        let restored = try XCTUnwrap(loadEntity(world, flyer.save()) as? PrehistoricCreature)

        XCTAssertEqual(restored.action, .idle)
        XCTAssertEqual(restored.data.prehistoricActionTicks, restLeft)
        XCTAssertTrue(restored.rng.stateWords == flyer.rng.stateWords, "the controller RNG must survive a save")
        XCTAssertEqual(restored.ambientSoundTimer, flyer.ambientSoundTimer)
        XCTAssertEqual(restored.age, flyer.age)
        XCTAssertEqual(restored.x, flyer.x); XCTAssertEqual(restored.y, flyer.y); XCTAssertEqual(restored.z, flyer.z)

        // From here the original and the reloaded copy must live the same life.
        struct Step: Equatable { let x, y, z: Double; let action: PrehistoricAction; let ticks: Int?; let onGround: Bool }
        func trace(_ creature: PrehistoricCreature) -> ([Step], [String]) {
            var steps: [Step] = []
            let heard = run(creature, ticks: 300) { _ in
                steps.append(Step(x: creature.x, y: creature.y, z: creature.z, action: creature.action,
                                  ticks: creature.data.prehistoricActionTicks, onGround: creature.onGround))
            }
            return (steps, heard.map { "\($0.tick):\($0.name)" })
        }
        let (originalSteps, originalSounds) = trace(flyer)
        let (restoredSteps, restoredSounds) = trace(restored)
        XCTAssertEqual(restoredSteps, originalSteps)
        XCTAssertEqual(restoredSounds, originalSounds)
        XCTAssertFalse(originalSounds.isEmpty, "the animal's own call must be in the comparison")
        XCTAssertTrue(restored.rng.stateWords == flyer.rng.stateWords)
    }

    // MARK: - determinism

    func testTwoRunsWithTheSameSeedAreIdentical() throws {
        // Same world, same seed, same id: the same positions, actions and sounds on every tick.
        // Covers a flyer that cannot leave, one that hits a ceiling, and one in the open.
        let places: [Enclosure?] = [.canopyGap, .room, nil]
        for enclosure in places {
            for id in ["prehistoric.dimorphodon", "prehistoric.quetzalcoatlus"] {
                func trace() throws -> (steps: [String], sounds: [String]) {
                    let world = enclosure.map { makeShapedWorld(shape(of: $0)) } ?? makeFlatWorld()
                    let flyer = try makeFlyer(world, id, seed: 0x5EED)
                    // The wingbeat's phase is derived from the entity id (`tickLocomotionSound`),
                    // and every new entity mints a fresh id; a saved animal keeps its own.
                    flyer.adoptPersistedId(0x5EED)
                    var steps: [String] = []
                    let heard = run(flyer, ticks: 600) { tick in
                        steps.append("\(tick) \(flyer.x) \(flyer.y) \(flyer.z) \(flyer.action.rawValue) \(flyer.data.prehistoricActionTicks ?? -1)")
                    }
                    return (steps, heard.map { "\($0.tick) \($0.name)" })
                }
                let first = try trace(), second = try trace()
                let label = "\(id) in \(enclosure?.rawValue ?? "the open")"
                XCTAssertEqual(first.steps, second.steps, label)
                XCTAssertEqual(first.sounds, second.sounds, label)
            }
        }
    }

    // MARK: - properties

    func testEveryFlyerInEveryEnclosureKeepsItsActionCuesRare() throws {
        // For every flying species, three seeds and every enclosure: at most two action cues in
        // any second, never two on one tick, never one cue on two ticks in a row. Where the flyer
        // can neither leave nor rise at all, no action cue at all.
        let silent: Set<Enclosure> = [.canopyGap, .chimney, .wetGap]
        for enclosure in Enclosure.allCases {
            let world = makeShapedWorld(shape(of: enclosure))
            for definition in PrehistoricCreatureDefinition.all where definition.medium == .air {
                for seed: UInt32 in [1, 42, 0xBEEF] {
                    let flyer = try makeFlyer(world, definition.id, seed: seed)
                    let ticks = 400
                    let cues = actionCues(flyer, run(flyer, ticks: ticks))
                    let label = "\(enclosure.rawValue) \(definition.id) seed \(seed): \(cues.map { "\($0.tick):\($0.name)" }.prefix(12))"
                    XCTAssertLessThanOrEqual(busiestSecond(cues, ticks: ticks), 2, label)
                    XCTAssertTrue(crowdedTicks(cues).isEmpty, label)
                    for name in Set(cues.map(\.name)) {
                        let at = cues.filter { $0.name == name }.map(\.tick)
                        for (a, b) in zip(at, at.dropFirst()) { XCTAssertGreaterThan(b - a, 1, label) }
                    }
                    if silent.contains(enclosure) { XCTAssertTrue(cues.isEmpty, label) }
                    XCTAssertTrue(flyer.x.isFinite && flyer.y.isFinite && flyer.z.isFinite, label)
                }
            }
        }
    }

    func testNoCreatureOfAnyMediumChattersInAMinuteOfOrdinaryLife() throws {
        // Every species in an ordinary place for its medium (open grass for land and air, a deep
        // pool for swimmers) for one minute: at most three action cues in any second and at most
        // forty in the minute. The reported drone was forty a second.
        let land = makeFlatWorld()
        let sea = makeShapedWorld { x, y, z in
            (10...38).contains(x) && (-6...22).contains(z) && (60...70).contains(y) ? cell(B.water) : nil
        }
        let ticks = 1_200
        for definition in PrehistoricCreatureDefinition.all {
            let aquatic = definition.medium == .aquatic
            let creature = try makeFlyer(aquatic ? sea : land, definition.id, seed: 5,
                                         at: (24.5, aquatic ? 66 : 64, 8.5))
            let cues = actionCues(creature, run(creature, ticks: ticks))
            let label = "\(definition.id): \(cues.count) cues"
            XCTAssertGreaterThan(cues.count, 0, "\(label): the creature must do something worth announcing")
            XCTAssertLessThanOrEqual(busiestSecond(cues, ticks: ticks), 3, label)
            XCTAssertLessThanOrEqual(cues.count, 40, label)
        }
    }
}
