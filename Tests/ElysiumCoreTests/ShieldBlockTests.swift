import XCTest
@testable import ElysiumCore

@MainActor
final class ShieldBlockTests: XCTestCase {
    private func makeWorldPlayer() -> (World, Player) {
        registerAllBlocks(); registerAllItems(); registerAllEntities()
        let world = World(dim: .overworld, seed: 11)
        let p = Player(world: world)
        p.setPos(0.5, 64, 0.5)
        p.health = 20
        return (world, p)
    }

    func testCanRaiseOnlyWithShieldOffhandAndWeaponOrEmptyMainHand() {
        let (_, p) = makeWorldPlayer()
        XCTAssertFalse(p.canRaiseOffhandShield(), "no shield equipped")
        p.offHand = stack("shield", 1)
        XCTAssertTrue(p.canRaiseOffhandShield(), "shield + empty hand raises")
        p.inventory[0] = stack("iron_sword", 1); p.selectedSlot = 0
        XCTAssertTrue(p.canRaiseOffhandShield(), "shield + sword raises")
        p.inventory[0] = stack("iron_hoe", 1)
        XCTAssertFalse(p.canRaiseOffhandShield(), "a hoe keeps its own right-click action")
    }

    func testRaiseLiftDelayBeforeBlocking() {
        let (_, p) = makeWorldPlayer()
        p.offHand = stack("shield", 1)
        for tick in 1...4 { p.updateShieldRaise(rightHeld: true); XCTAssertFalse(p.isBlocking, "tick \(tick)") }
        p.updateShieldRaise(rightHeld: true)
        XCTAssertTrue(p.isBlocking, "blocking after the short lift")
        p.updateShieldRaise(rightHeld: false)
        XCTAssertFalse(p.isBlocking, "lowering the shield stops blocking")
        XCTAssertEqual(p.shieldRaiseTicks, 0)
    }

    func testBlocksFrontalHitButNotFromBehind() {
        let (world, p) = makeWorldPlayer()
        p.offHand = stack("shield", 1)
        p.yaw = 0  // faces +z
        for _ in 0..<6 { p.updateShieldRaise(rightHeld: true) }
        XCTAssertTrue(p.isBlocking)

        let front = Player(world: world); front.setPos(0.5, 64, 6)   // +z, in front
        let behind = Player(world: world); behind.setPos(0.5, 64, -6) // -z, behind
        XCTAssertTrue(p.shieldBlocks(source: "player", attacker: front))
        XCTAssertFalse(p.shieldBlocks(source: "player", attacker: behind))
        // Environmental damage is never blocked.
        XCTAssertFalse(p.shieldBlocks(source: "fall", attacker: nil))
    }

    func testHurtNegatesFrontalDamageWhileBlocking() {
        let (world, p) = makeWorldPlayer()
        p.offHand = stack("shield", 1)
        p.yaw = 0
        for _ in 0..<6 { p.updateShieldRaise(rightHeld: true) }
        let front = Player(world: world); front.setPos(0.5, 64, 6)

        XCTAssertFalse(p.hurt(6, "player", front), "a blocked frontal hit deals no damage")
        XCTAssertEqual(p.health, 20, accuracy: 0.001)

        let behind = Player(world: world); behind.setPos(0.5, 64, -6)
        p.invulnTicks = 0
        XCTAssertTrue(p.hurt(6, "player", behind), "a hit from behind still lands")
        XCTAssertLessThan(p.health, 20)
    }
}
