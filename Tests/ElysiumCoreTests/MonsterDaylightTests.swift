import XCTest
@testable import ElysiumCore

final class MonsterDaylightTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeWorld() -> World {
        World(dim: .nether, seed: 77)
    }

    private func tick(_ creeper: Creeper, count: Int) {
        for _ in 0..<count { creeper.tick() }
    }

    func testProximityFuseLatchesAndExplodesOnTickThirty() {
        let world = makeWorld()
        let creeper = Creeper(world: world)
        creeper.setPos(4.5, 65, 7.5)
        creeper.persistent = true
        world.addEntity(creeper)
        var explosions = 0
        var power = 0.0
        bindExplode { _, _, _, _, receivedPower, _, source in
            explosions += 1
            power = receivedPower
            XCTAssertTrue(source === creeper)
        }
        defer { bindExplode(nil) }

        creeper.startFuse(.proximity)
        tick(creeper, count: Creeper.proximityFuseTicks - 1)
        XCTAssertEqual(explosions, 0)
        XCTAssertFalse(creeper.dead)

        creeper.tick()
        XCTAssertEqual(explosions, 1)
        XCTAssertEqual(power, 3)
        XCTAssertTrue(creeper.dead)
    }

    func testSunlightFuseExplodesOnTickFifteenAndOnlyHissesOnce() {
        let world = makeWorld()
        var primedSounds = 0
        world.hooks.playSound = { name, _, _, _, _, _ in
            if name == "entity.creeper.primed" { primedSounds += 1 }
        }
        let creeper = Creeper(world: world)
        creeper.setPos(2.5, 65, 2.5)
        creeper.persistent = true
        var explosions = 0
        bindExplode { _, _, _, _, _, _, _ in explosions += 1 }
        defer { bindExplode(nil) }

        creeper.reactToDirectSunlight()
        creeper.reactToDirectSunlight()
        tick(creeper, count: Creeper.sunlightFuseTicks - 1)
        XCTAssertEqual(explosions, 0)
        XCTAssertEqual(primedSounds, 1)

        creeper.tick()
        XCTAssertEqual(explosions, 1)
        XCTAssertEqual(primedSounds, 1)
    }

    func testSunlightAcceleratesButNeverRestartsAnActiveFuse() throws {
        let world = makeWorld()
        let creeper = Creeper(world: world)
        creeper.setPos(9.5, 65, 9.5)
        creeper.persistent = true
        creeper.startFuse(.proximity)
        tick(creeper, count: 8)
        let elapsed = try XCTUnwrap(creeper.fuse?.elapsedTicks)

        creeper.reactToDirectSunlight()
        let accelerated = try XCTUnwrap(creeper.fuse)
        XCTAssertEqual(accelerated.trigger, .sunlight)
        XCTAssertEqual(accelerated.elapsedTicks, elapsed)
        XCTAssertLessThanOrEqual(accelerated.totalTicks - accelerated.elapsedTicks,
                                 Creeper.sunlightFuseTicks)

        creeper.reactToDirectSunlight()
        XCTAssertEqual(creeper.fuse, accelerated)
    }

    func testFusedCreeperKeepsLatchedHorizontalPositionAfterMotionAndKnockback() {
        let world = makeWorld()
        let creeper = Creeper(world: world)
        creeper.setPos(12.5, 65, -3.5)
        creeper.persistent = true
        let attacker = Zombie(world: world)
        attacker.setPos(10.5, 65, -3.5)
        creeper.startFuse(.proximity)

        creeper.vx = 1.2
        creeper.vz = -0.7
        creeper.moveForward = 1
        creeper.tick()
        XCTAssertEqual(creeper.x, 12.5, accuracy: 0.000_001)
        XCTAssertEqual(creeper.z, -3.5, accuracy: 0.000_001)
        XCTAssertEqual(creeper.vx, 0)
        XCTAssertEqual(creeper.vz, 0)
        XCTAssertEqual(creeper.limbAmp, 0)

        _ = creeper.hurt(1, "player", attacker)
        XCTAssertEqual(creeper.x, 12.5, accuracy: 0.000_001)
        XCTAssertEqual(creeper.z, -3.5, accuracy: 0.000_001)
        XCTAssertEqual(creeper.vx, 0)
        XCTAssertEqual(creeper.vz, 0)
        XCTAssertNotNil(creeper.fuse)
    }

    func testChargedAndAcceleratedFuseRoundTrip() throws {
        let world = makeWorld()
        let creeper = Creeper(world: world)
        creeper.setPos(3.5, 70, 8.5)
        creeper.persistent = true
        creeper.charged = true
        creeper.startFuse(.proximity)
        tick(creeper, count: 6)
        creeper.reactToDirectSunlight()
        let saved = creeper.save()

        let loaded = Creeper(world: world)
        loaded.load(saved)
        XCTAssertTrue(loaded.charged)
        XCTAssertEqual(loaded.fuse, creeper.fuse)
        XCTAssertEqual(loaded.data.fuseRapid, true)
        XCTAssertEqual(loaded.data.swelling ?? -1,
                       Double(try XCTUnwrap(loaded.fuse?.elapsedTicks)) /
                       Double(try XCTUnwrap(loaded.fuse?.totalTicks)),
                       accuracy: 0.000_001)
    }

    func testMalformedFusePayloadFailsClosed() {
        let world = makeWorld()
        let cases: [[String: Any]] = [
            ["trigger": "sunlight", "elapsed": 0, "total": 31, "x": 0.0, "z": 0.0],
            ["trigger": "sunlight", "elapsed": 0, "total": 20, "x": Double.nan, "z": 0.0],
            ["trigger": "proximity", "elapsed": 30, "total": 30, "x": 0.0, "z": 0.0],
            ["trigger": "other", "elapsed": 1, "total": 15, "x": 0.0, "z": 0.0],
        ]

        for payload in cases {
            let creeper = Creeper(world: world)
            creeper.load(["x": 0.0, "y": 65.0, "z": 0.0, "creeperFuse": payload])
            XCTAssertNil(creeper.fuse)
            XCTAssertEqual(creeper.data.swelling, 0)
            XCTAssertEqual(creeper.data.fuseRapid, false)
        }
    }

    func testFuseVisualProjectionIsBoundedAndScaleIsMonotonic() {
        var previousScale = 0.0
        for step in 0...1_000 {
            let visual = creeperFuseVisual(progress: Double(step) / 1_000)
            XCTAssertGreaterThanOrEqual(visual.scale, previousScale)
            XCTAssertGreaterThanOrEqual(visual.scale, 1.02)
            XCTAssertLessThanOrEqual(visual.scale, 1.08)
            XCTAssertGreaterThanOrEqual(visual.overlayAlpha, 0.15)
            XCTAssertLessThanOrEqual(visual.overlayAlpha, 0.45)
            previousScale = visual.scale
        }
        XCTAssertEqual(creeperFuseVisual(progress: .nan), creeperFuseVisual(progress: 0))
        XCTAssertEqual(creeperFuseVisual(progress: -10).scale, 1.02)
        XCTAssertEqual(creeperFuseVisual(progress: 10).scale, 1.08)
    }

    func testLANSnapshotCarriesFusePresentationAndMirrorCannotExplode() throws {
        let hostWorld = makeWorld()
        let host = Creeper(world: hostWorld)
        host.setPos(4.5, 65, 4.5)
        host.persistent = true
        host.charged = true
        host.startFuse(.sunlight)
        tick(host, count: 5)
        hostWorld.addEntity(host)

        let snapshot = try XCTUnwrap(makeLANEntitySnapshots(in: hostWorld).first)
        XCTAssertEqual(snapshot.type, "creeper")
        XCTAssertEqual(snapshot.fuseProgress ?? -1, 5.0 / 15.0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.fuseRapid, true)
        XCTAssertEqual(snapshot.charged, true)

        let clientWorld = makeWorld()
        XCTAssertEqual(applyLANEntitySnapshots([snapshot], to: clientWorld).appliedEntitySnapshots, 1)
        let mirror = try XCTUnwrap(clientWorld.entities.first as? Creeper)
        XCTAssertTrue(mirror.lanReplicatedMirror)
        mirror.persistent = true
        XCTAssertNil(mirror.fuse, "presentation data must never create client-side authority")
        XCTAssertEqual(mirror.data.swelling ?? -1, 5.0 / 15.0, accuracy: 0.000_001)
        XCTAssertEqual(mirror.data.fuseRapid, true)
        XCTAssertTrue(mirror.charged)

        var explosions = 0
        bindExplode { _, _, _, _, _, _, _ in explosions += 1 }
        defer { bindExplode(nil) }
        tick(mirror, count: 40)
        XCTAssertEqual(explosions, 0)
        XCTAssertNil(mirror.fuse)
    }

    func testLANLegacyPayloadDefaultsNewPresentationFieldsToNil() throws {
        let current = LANEntitySnapshot(entityID: 5, type: "creeper", x: 1, y: 2, z: 3,
                                        yaw: 0, pitch: 0, health: 20, dead: false)
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fuseProgress")
        object.removeValue(forKey: "fuseRapid")
        object.removeValue(forKey: "charged")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LANEntitySnapshot.self, from: legacy)
        XCTAssertNil(decoded.fuseProgress)
        XCTAssertNil(decoded.fuseRapid)
        XCTAssertEqual(decoded.charged, false)
    }

    func testLANInitializerClampsFiniteProgressAndRejectsNonFiniteProgress() {
        let high = LANEntitySnapshot(entityID: 1, type: "creeper", x: 0, y: 0, z: 0,
                                     yaw: 0, pitch: 0, health: 20, dead: false,
                                     fuseProgress: 50, fuseRapid: true)
        XCTAssertEqual(high.fuseProgress, 1)
        XCTAssertEqual(high.fuseRapid, true)

        let invalid = LANEntitySnapshot(entityID: 2, type: "creeper", x: 0, y: 0, z: 0,
                                        yaw: 0, pitch: 0, health: 20, dead: false,
                                        fuseProgress: .infinity, fuseRapid: true)
        XCTAssertNil(invalid.fuseProgress)
        XCTAssertNil(invalid.fuseRapid)

        let unrelated = LANEntitySnapshot(entityID: 3, type: "zombie", x: 0, y: 0, z: 0,
                                          yaw: 0, pitch: 0, health: 20, dead: false,
                                          fuseProgress: 0.5, fuseRapid: true, charged: true)
        XCTAssertNil(unrelated.fuseProgress)
        XCTAssertNil(unrelated.fuseRapid)
        XCTAssertNil(unrelated.charged)
    }
}
