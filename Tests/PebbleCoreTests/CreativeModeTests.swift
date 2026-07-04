import XCTest
@testable import PebbleCore

final class CreativeModeTests: XCTestCase {
    private final class FlightFixture {
        let world: World
        let player: Player

        init(world: World, player: Player) {
            self.world = world
            self.player = player
        }
    }

    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makePlacementWorld(mode: Int) -> (World, Player, RaycastHit) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 123)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.set(0, 63, 0, cell(B.stone))
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)

        let player = Player(world: world)
        player.setGameMode(mode)
        player.setPos(4.5, 64, 4.5)
        let hit = RaycastHit(x: 0, y: 63, z: 0, face: Dir.up, cell: Int(cell(B.stone)),
                             t: 1, px: 0.5, py: 64, pz: 0.5)
        return (world, player, hit)
    }

    private func makeFlightPlayer(mode: Int = GameMode.creative) -> FlightFixture {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 321)
        let player = Player(world: world)
        player.setGameMode(mode)
        player.setPos(0.5, 80, 0.5)
        player.onGround = true
        return FlightFixture(world: world, player: player)
    }

    func testSurvivalPlacementConsumesSelectedHotbarStack() {
        let (world, player, hit) = makePlacementWorld(mode: GameMode.survival)
        player.inventory[0] = stack("dirt", 3)
        player.selectedSlot = 0

        XCTAssertTrue(placeBlock(InteractCtx(world: world, player: player), hit, Int(B.dirt), player.mainHand!))

        XCTAssertEqual(world.getBlock(0, 64, 0) >> 4, Int(B.dirt))
        XCTAssertEqual(player.inventory[0]?.id, iid("dirt"))
        XCTAssertEqual(player.inventory[0]?.count, 2)
    }

    func testCreativePlacementKeepsSelectedHotbarStack() {
        let (world, player, hit) = makePlacementWorld(mode: GameMode.creative)
        player.inventory[0] = stack("dirt", 3)
        player.selectedSlot = 0

        XCTAssertTrue(placeBlock(InteractCtx(world: world, player: player), hit, Int(B.dirt), player.mainHand!))

        XCTAssertEqual(world.getBlock(0, 64, 0) >> 4, Int(B.dirt))
        XCTAssertEqual(player.inventory[0]?.id, iid("dirt"))
        XCTAssertEqual(player.inventory[0]?.count, 3)
    }

    func testCreativePlayerIgnoresAllDamageSources() {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 456)
        let player = Player(world: world)
        player.setGameMode(GameMode.creative)
        player.setPos(0.5, 64, 0.5)

        for source in ["mob", "fall", "fall_high", "fire", "lava", "drown", "freeze", "magic", "wither", "starve", "explosion", "void"] {
            player.health = 7
            player.deathTime = 0
            player.invulnTicks = 0

            XCTAssertFalse(player.hurt(100, source), "creative player should ignore \(source) damage")
            XCTAssertEqual(player.health, 7, accuracy: 0.000_001)
            XCTAssertEqual(player.deathTime, 0)
            XCTAssertFalse(player.dead)
        }
    }

    func testCreativePlayerDoesNotTakeTickDamageFromVoidOrFire() {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 789)
        let player = Player(world: world)
        player.setGameMode(GameMode.creative)
        player.setPos(0.5, Double(world.info.minY - 80), 0.5)
        player.health = 6
        player.fireTicks = 20

        player.tick()

        XCTAssertEqual(player.health, 6, accuracy: 0.000_001)
        XCTAssertEqual(player.deathTime, 0)
        XCTAssertFalse(player.dead)
    }

    func testCreativeDoubleJumpStartsFlightAndLaunchesAirborne() {
        let fixture = makeFlightPlayer()
        withExtendedLifetime(fixture) {
            let player = fixture.player

            XCTAssertFalse(player.creativeJumpPressed(now: 1_000))
            XCTAssertFalse(player.flying)
            XCTAssertTrue(player.onGround)

            XCTAssertTrue(player.creativeJumpPressed(now: 1_200))

            XCTAssertTrue(player.flying)
            XCTAssertFalse(player.onGround)
            XCTAssertGreaterThanOrEqual(player.vy, 0.35)

            let startY = player.y
            player.travelCreativeFlight(ascend: false, descend: false)

            XCTAssertGreaterThan(player.y, startY)
            XCTAssertTrue(player.flying)
            XCTAssertEqual(player.fallDistance, 0, accuracy: 0.000_001)
        }
    }

    func testCreativeFlightUsesSpaceShiftAndWASDMovement() {
        let fixture = makeFlightPlayer()
        withExtendedLifetime(fixture) {
            let player = fixture.player
            XCTAssertTrue(player.startCreativeFlight())

            let startY = player.y
            player.travelCreativeFlight(ascend: true, descend: false)
            XCTAssertGreaterThan(player.y, startY)

            let highY = player.y
            player.travelCreativeFlight(ascend: false, descend: true)
            XCTAssertLessThan(player.y, highY)

            player.yaw = 0
            player.moveForward = 1
            player.moveStrafe = 0
            let startZ = player.z
            player.travelCreativeFlight(ascend: false, descend: false)
            XCTAssertGreaterThan(player.z, startZ)
        }
    }

    func testFlyingWandAllowsSurvivalCreativeFlightControls() {
        let fixture = makeFlightPlayer(mode: GameMode.survival)
        withExtendedLifetime(fixture) {
            let player = fixture.player
            player.inventory[0] = stack(FLYING_WAND_ITEM_NAME)
            player.selectedSlot = 0

            XCTAssertFalse(player.creativeJumpPressed(now: 1_000))
            XCTAssertTrue(player.creativeJumpPressed(now: 1_200))
            XCTAssertTrue(player.flying)
            XCTAssertFalse(player.onGround)

            let startY = player.y
            player.travelCreativeFlight(ascend: true, descend: false)

            XCTAssertGreaterThan(player.y, startY)
            XCTAssertTrue(player.flying)
            XCTAssertEqual(player.fallDistance, 0, accuracy: 0.000_001)
        }
    }

    func testUnequippingFlyingWandMidairForcesHalfDamageFallAndLockout() {
        let normalFixture = makeFlightPlayer(mode: GameMode.survival)
        let wandFixture = makeFlightPlayer(mode: GameMode.survival)
        withExtendedLifetime((normalFixture, wandFixture)) {
            let normal = normalFixture.player
            normal.health = 20
            normal.invulnTicks = 0
            normal.onLand(10)
            let normalDamage = 20 - normal.health

            let player = wandFixture.player
            player.inventory[0] = stack(FLYING_WAND_ITEM_NAME)
            player.inventory[1] = stack("dirt")
            player.selectedSlot = 0
            player.health = 20
            player.invulnTicks = 0

            XCTAssertTrue(player.startCreativeFlight())
            XCTAssertTrue(player.flying)

            player.selectedSlot = 1
            player.syncFlightEquipmentState()

            XCTAssertFalse(player.flying)
            XCTAssertEqual(player.fallDistance, 0, accuracy: 0.000_001)

            player.selectedSlot = 0
            XCTAssertFalse(player.startCreativeFlight(), "wand flight should stay locked until landing after a midair unequip")

            player.onLand(10)

            XCTAssertEqual(20 - player.health, normalDamage * 0.5, accuracy: 0.000_001)
            XCTAssertTrue(player.startCreativeFlight(), "landing should clear the wand-fall lockout")
        }
    }

    func testSurvivalCannotStartOrRetainCreativeFlight() {
        let survivalFixture = makeFlightPlayer(mode: GameMode.survival)
        withExtendedLifetime(survivalFixture) {
            let survival = survivalFixture.player

            XCTAssertFalse(survival.creativeJumpPressed(now: 1_000))
            XCTAssertFalse(survival.creativeJumpPressed(now: 1_200))
            XCTAssertFalse(survival.flying)
        }

        let creativeFixture = makeFlightPlayer()
        withExtendedLifetime(creativeFixture) {
            let creative = creativeFixture.player
            XCTAssertTrue(creative.startCreativeFlight())
            XCTAssertTrue(creative.flying)

            creative.setGameMode(GameMode.survival)

            XCTAssertFalse(creative.flying)
            XCTAssertFalse(creative.creativeJumpPressed(now: 1_300))
        }
    }
}
