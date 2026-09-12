import XCTest
import simd
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class FirstPersonTargetTests: XCTestCase {
    private func camera(x: Double = 0, y: Double = 0, z: Double = 0, fov: Double = 70) -> CamState {
        var cam = CamState(); cam.x = x; cam.y = y; cam.z = z; cam.fov = fov
        return cam
    }

    func testDifferentWorldAndViewmodelLensesPreserveExactScreenPointAtAllAspects() throws {
        for fov in [50.0, 70, 90, 110] {
            for aspect: Float in [0.75, 1, 16.0/9, 3] {
                let cam = camera(fov: fov)
                let projection = try XCTUnwrap(FirstPersonTarget.project(worldPoint: SIMD3(-1,0.5,3), cam: cam, aspect: aspect))
                for depthRange: ClosedRange<Float> in [0.6...1, 2...4, 5...8] {
                    let proxy = try XCTUnwrap(FirstPersonTarget.viewmodelPoint(ndc: projection.ndc,
                        worldDepth: projection.depth, depthRange: depthRange, aspect: aspect))
                    let matrix = Elysium.mat4Perspective(fovYRad: 70 * .pi/180, aspect: aspect, near: 0.035, far: 12)
                    let clip = matrix * SIMD4(proxy, 1)
                    XCTAssertEqual(clip.x / clip.w, projection.ndc.x, accuracy: 1e-6)
                    XCTAssertEqual(clip.y / clip.w, projection.ndc.y, accuracy: 1e-6)
                    XCTAssertTrue(depthRange.contains(-proxy.z))
                }
            }
        }
    }

    func testSuppliedBobbedCameraAndYawPitchBasisAreUsedRatherThanPlayerEye() throws {
        var cam = camera(x: 1_000_000.2, y: 64.1, z: 1_000_000, fov: 90)
        let p = try XCTUnwrap(FirstPersonTarget.project(worldPoint: SIMD3(1_000_000,64,1_000_003), cam: cam, aspect: 2))
        XCTAssertEqual(p.ndc.x, 0.2 / 6, accuracy: 1e-6)
        XCTAssertEqual(p.ndc.y, -0.1 / 3, accuracy: 1e-6)
        cam.yaw = .pi / 2; cam.pitch = .pi / 4
        let point = SIMD3(cam.x - 3 / sqrt(2), cam.y - 3 / sqrt(2), cam.z)
        let angled = try XCTUnwrap(FirstPersonTarget.project(worldPoint: point, cam: cam, aspect: 1.5))
        XCTAssertEqual(angled.ndc.x, 0, accuracy: 1e-6)
        XCTAssertEqual(angled.ndc.y, 0, accuracy: 1e-6)
        XCTAssertEqual(angled.depth, 3, accuracy: 1e-6)
    }

    func testNearBehindAndMalformedProjectionInputsFailSafely() {
        for point: SIMD3<Double> in [SIMD3(0,0,-1), SIMD3(0,0,0.01), SIMD3(.nan,0,3), SIMD3(0,0,.infinity)] {
            XCTAssertNil(FirstPersonTarget.project(worldPoint: point, cam: camera(), aspect: 1))
        }
        for aspect: Float in [0, -1, .nan, .infinity] {
            XCTAssertNil(FirstPersonTarget.project(worldPoint: SIMD3(0,0,3), cam: camera(), aspect: aspect))
        }
        for fov in [0.0, 180, .nan, .infinity] {
            XCTAssertNil(FirstPersonTarget.project(worldPoint: SIMD3(0,0,3), cam: camera(fov: fov), aspect: 1))
        }
        XCTAssertNil(FirstPersonTarget.viewmodelPoint(ndc: .zero, worldDepth: 2, depthRange: 0...1, aspect: 1))
        XCTAssertNil(FirstPersonTarget.viewmodelPoint(ndc: SIMD2(.nan,0), worldDepth: 2, depthRange: 1...3, aspect: 1))
        XCTAssertNil(FirstPersonTarget.viewmodelPoint(ndc: .zero, worldDepth: .infinity, depthRange: 1...3, aspect: 1))
    }

    private func fixture() -> (World, Player, CamState) {
        registerAllBlocks(); registerAllItems()
        let world = World(dim: .overworld, seed: 37)
        for cz in 0...4 {
            world.setChunk(Chunk(cx: 0, cz: cz, minY: world.info.minY, height: world.info.height))
        }
        let player = Player(world: world); player.setPos(0.5,64,0.5)
        return (world, player, camera(x: player.x, y: player.eyeY(), z: player.z))
    }

    private func entity(_ world: World, x: Double = 0.5, z: Double) -> LivingEntity {
        let entity = LivingEntity(world: world); entity.setPos(x,64,z)
        entity.width = 0.6; entity.height = 2
        world.entities.append(entity)
        return entity
    }

    func testExactBlockFaceAndNearestEntityOcclusionWithoutMutation() throws {
        let (world, player, cam) = fixture()
        world.setBlock(0,65,3,Int(B.stone) << 4)
        let behind = entity(world, z: 4)
        let blocked = try XCTUnwrap(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1))
        XCTAssertEqual(blocked.kind, .block(x: 0,y: 65,z: 3,face: 2))
        XCTAssertEqual(blocked.worldPoint.z, 3, accuracy: 1e-9)
        XCTAssertEqual(blocked.worldNormal, SIMD3(0,0,-1))
        let front = entity(world, z: 2)
        let nearest = try XCTUnwrap(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1))
        XCTAssertEqual(nearest.kind, .entity(front.id))
        XCTAssertEqual(nearest.worldPoint.z, 1.6, accuracy: 1e-9)
        XCTAssertEqual(world.getBlock(0,65,3), Int(B.stone) << 4)
        XCTAssertEqual(front.z, 2); XCTAssertEqual(behind.z, 4)
        XCTAssertEqual(player.z, 0.5); XCTAssertEqual(world.entities.count, 2)
    }

    func testSelectedEntityPointFollowsRenderInterpolationWithoutChangingIdentity() throws {
        let (world, player, cam) = fixture()
        let moving = entity(world, z: 3)
        moving.prevZ = 1
        for partial in [0.0, 0.5, 1] {
            let target = try XCTUnwrap(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: partial, aspect: 1))
            XCTAssertEqual(target.kind, .entity(moving.id))
            XCTAssertEqual(target.worldPoint.z, 0.6 + 2 * partial, accuracy: 1e-9)
        }
        XCTAssertEqual(moving.z, 3); XCTAssertEqual(moving.prevZ, 1)
    }

    func testRangedTargetIsBoundedTo64AndNeverExtendsMeleeReach() throws {
        let (world, player, cam) = fixture()
        let distant = entity(world, z: 20)
        XCTAssertNil(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1))
        let ranged = try XCTUnwrap(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1, ranged: true))
        XCTAssertEqual(ranged.kind, .entity(distant.id))
        distant.setPos(0.5,64,66)
        XCTAssertNil(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1, ranged: true))
    }

    func testBobbedEyeCannotGrantExtraBlockReach() {
        let (world, player, original) = fixture()
        // World surface is 4.6 from simulation eye but only 4.4 from rendered eye.
        player.setPos(0.5,64,0.4)
        world.setBlock(0,65,5,Int(B.stone) << 4)
        var cam = original; cam.z = 0.6
        XCTAssertNil(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1))
        player.setGameMode(GameMode.creative)
        XCTAssertNotNil(FirstPersonTarget.resolve(world: world, player: player, cam: cam, partial: 1, aspect: 1))
    }

    func testBobbingAcrossBlockEdgeKeepsActualGameplayTargetAndProjectsItsOffset() throws {
        let (world, player, original) = fixture()
        player.setPos(0.95,64,0.5)
        world.setBlock(0,65,3,Int(B.stone) << 4)
        var cam = original; cam.x = 1.05; cam.fov = 90
        let target = try XCTUnwrap(FirstPersonTarget.resolve(world: world, player: player,
            cam: cam, partial: 1, aspect: 2))
        XCTAssertEqual(target.kind, .block(x: 0,y: 65,z: 3,face: 2))
        XCTAssertEqual(target.worldPoint.x, 0.95, accuracy: 1e-9)
        XCTAssertEqual(target.worldNDC.x, 0.1 / 5, accuracy: 1e-6)
        XCTAssertNil(world.raycast(cam.x,cam.y,cam.z,0,0,1,REACH_SURVIVAL),
                     "the old rendered-eye query must actually miss this gameplay target")
    }
}
