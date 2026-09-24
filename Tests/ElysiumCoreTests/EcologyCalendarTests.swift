import XCTest
@testable import ElysiumCore

final class EcologyCalendarTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
    }
    func testFrequencyCountsDawnsNotTicksAndConsumesEachOnce() {
        for frequency in CreatureRespawnFrequency.allCases {
            var calendar = EcologyCalendar()
            for day in 1...21 {
                calendar.advance(ticks: DAY_LENGTH - 1)
                XCTAssertFalse(calendar.consumeRespawnDawn(frequency: frequency))
                calendar.advance(ticks: 1, dawn: true)
                XCTAssertEqual(calendar.consumeRespawnDawn(frequency: frequency), day % frequency.dayCount == 0)
                XCTAssertFalse(calendar.consumeRespawnDawn(frequency: frequency))
            }
            XCTAssertEqual(calendar.elapsedTicks, 21 * DAY_LENGTH)
        }
    }

    func testSaveReloadPreservesProgressWithoutReplayingDawn() throws {
        var calendar = EcologyCalendar()
        calendar.advance(ticks: DAY_LENGTH, dawn: true)
        XCTAssertFalse(calendar.consumeRespawnDawn(frequency: .alternateDays))
        let data = try JSONEncoder().encode(calendar)
        var restored = try JSONDecoder().decode(EcologyCalendar.self, from: data)
        XCTAssertFalse(restored.consumeRespawnDawn(frequency: .alternateDays))
        restored.advance(ticks: DAY_LENGTH, dawn: true)
        XCTAssertTrue(restored.consumeRespawnDawn(frequency: .alternateDays))
        let dawnData = try JSONEncoder().encode(restored)
        var afterDawn = try JSONDecoder().decode(EcologyCalendar.self, from: dawnData)
        XCTAssertFalse(afterDawn.consumeRespawnDawn(frequency: .daily))
    }

    func testPreferenceChangeTakesEffectOnlyAtNextDawnAndDoesNotCatchUp() {
        var calendar = EcologyCalendar()
        for _ in 0..<6 {
            calendar.advance(ticks: DAY_LENGTH, dawn: true)
            XCTAssertFalse(calendar.consumeRespawnDawn(frequency: .weekly))
        }
        XCTAssertFalse(calendar.consumeRespawnDawn(frequency: .daily))
        calendar.advance(ticks: DAY_LENGTH, dawn: true)
        XCTAssertTrue(calendar.consumeRespawnDawn(frequency: .daily))
        XCTAssertFalse(calendar.consumeRespawnDawn(frequency: .daily))
    }

    func testLegacyDimensionStateAndBoundedCalendar() throws {
        let legacy = Data(#"{"time":4200,"dayTime":5200,"raining":false,"thundering":false,"weatherTimer":100}"#.utf8)
        let state = try JSONDecoder().decode(DimState.self, from: legacy)
        XCTAssertNil(state.ecologyCalendar)
        XCTAssertNil(state.creatureRespawnSequence)
        var bounded = EcologyCalendar(elapsedTicks: Int.max, completedDawns: 2, lastRespawnDawn: Int.max)
        bounded.advance(ticks: Int.max, dawn: true)
        XCTAssertEqual(bounded.elapsedTicks, EcologyCalendar.maximumTick)
        XCTAssertEqual(bounded.lastRespawnDawn, 2)
        let malformed = Data(#"{"elapsedTicks":-1,"completedDawns":"bad","lastRespawnDawn":-99}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EcologyCalendar.self, from: malformed), EcologyCalendar())
    }

    func testNaturalDawnSleepingFrozenClockAndCommands() {
        let world = World(dim: .overworld, seed: 21)
        world.randomTickSpeed = 0
        world.dayTime = DAY_LENGTH - 1
        world.tick()
        XCTAssertEqual(world.dayTime, 0)
        XCTAssertTrue(world.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
        world.dayTime = 13000 // clock-setting alone does not complete a day
        XCTAssertFalse(world.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
        world.skipEcologyToDawn()
        XCTAssertEqual(world.ecologyTick, 11001)
        XCTAssertTrue(world.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
        world.skipEcologyToDawn()
        XCTAssertFalse(world.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
        world.gameRules["doDaylightCycle"] = 0
        world.dayTime = DAY_LENGTH - 1
        world.tick()
        XCTAssertEqual(world.dayTime, DAY_LENGTH - 1)
        XCTAssertEqual(world.ecologyTick, 11001)
        XCTAssertFalse(world.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
    }

    func testSkylessAndGuestWorldNeverIssueDawn() {
        let nether = World(dim: .nether, seed: 22)
        nether.randomTickSpeed = 0
        nether.dayTime = DAY_LENGTH - 1
        nether.tick()
        XCTAssertEqual(nether.ecologyTick, 1)
        XCTAssertFalse(nether.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
        let guest = World(dim: .overworld, seed: 22)
        guest.isTransientLANClient = true
        guest.randomTickSpeed = 0
        guest.dayTime = DAY_LENGTH - 1
        guest.tick()
        guest.skipEcologyToDawn()
        XCTAssertEqual(guest.ecologyTick, 0)
        XCTAssertFalse(guest.ecologyCalendar.consumeRespawnDawn(frequency: .daily))
    }
}
