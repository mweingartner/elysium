// Read-only presentation targeting. This does not dispatch attacks, extend their
// reach, or change the gameplay crosshair/selection caches.
import Foundation
import simd
import ElysiumCore

struct FirstPersonTarget {
    enum Kind: Equatable {
        case block(x: Int, y: Int, z: Int, face: Int)
        case entity(Int)
    }

    let kind: Kind
    let worldPoint: SIMD3<Double>
    let worldNormal: SIMD3<Double>?
    let worldNDC: SIMD2<Float>
    let worldDepth: Float
    let distance: Double

    static func resolve(game: GameCore, cam: CamState, partial: Double,
                        aspect: Float, ranged: Bool = false) -> Self? {
        guard let player = game.player, game.perspective == 0 else { return nil }
        return resolve(world: game.world, player: player, cam: cam,
                       partial: partial, aspect: aspect, ranged: ranged)
    }

    static func resolve(world: World, player: Player, cam: CamState,
                        partial: Double, aspect: Float, ranged: Bool = false) -> Self? {
        guard validCamera(cam, aspect: aspect), partial.isFinite else { return nil }
        let origin = SIMD3(player.x, player.eyeY(), player.z)
        // raycast converts these coordinates to Int; reject malformed camera state
        // before that boundary. Real supported world extents are far smaller.
        guard [origin.x, origin.y, origin.z, player.yaw, player.pitch].allSatisfy(\.isFinite),
              [origin.x, origin.y, origin.z].allSatisfy({ abs($0) < Double(Int32.max) }) else { return nil }
        // Select the same surface that gameplay will mine/attack. The rendered
        // camera is used only for projection, preserving bob/interpolation parallax.
        let direction = SIMD3(-detSin(player.yaw) * detCos(player.pitch), -detSin(player.pitch),
                              detCos(player.yaw) * detCos(player.pitch))
        let blockReach = ranged ? 64 : player.gameMode == GameMode.creative ? REACH_CREATIVE : REACH_SURVIVAL
        let entityReach = ranged ? 64 : ATTACK_REACH
        let block = world.raycast(origin.x, origin.y, origin.z,
                                  direction.x, direction.y, direction.z, blockReach)
        var bestDistance = block?.t ?? blockReach
        var result: Self?

        func target(_ point: SIMD3<Double>, kind: Kind, normal: SIMD3<Double>?,
                    distance: Double, reach: Double) -> Self? {
            guard distance <= reach + 1e-7,
                  let projected = project(worldPoint: point, cam: cam, aspect: aspect) else { return nil }
            return .init(kind: kind, worldPoint: point, worldNormal: normal,
                         worldNDC: projected.ndc, worldDepth: projected.depth, distance: distance)
        }

        if let block {
            let normals: [SIMD3<Double>] = [SIMD3(0,-1,0), SIMD3(0,1,0),
                SIMD3(0,0,-1), SIMD3(0,0,1), SIMD3(-1,0,0), SIMD3(1,0,0)]
            result = target(SIMD3(block.px, block.py, block.pz),
                            kind: .block(x: block.x, y: block.y, z: block.z, face: block.face),
                            normal: normals.indices.contains(block.face) ? normals[block.face] : nil,
                            distance: block.t, reach: blockReach)
        }

        let t = min(1, max(0, partial))
        for reference in world.getEntitiesNear(origin.x, origin.y, origin.z, entityReach + 2) {
            guard let entity = reference as? Entity, entity !== player, !entity.dead,
                  entity is LivingEntity || ["boat", "minecart", "item_frame", "end_crystal"].contains(entity.type) else { continue }
            // Match ordinary render interpolation without invoking mutable remote
            // smoothing APIs or changing authoritative entity positions.
            let x = entity.prevX + (entity.x - entity.prevX) * t
            let y = entity.prevY + (entity.y - entity.prevY) * t
            let z = entity.prevZ + (entity.z - entity.prevZ) * t
            let box = entity.bb()
            // Match attack selection's 0.1 allowance, but never let interpolated
            // positions choose an entity that the actual gameplay ray missed.
            let expanded = AABB(box.x0-0.1, box.y0-0.1, box.z0-0.1,
                                box.x1+0.1, box.y1+0.1, box.z1+0.1)
            guard [expanded.x0, expanded.y0, expanded.z0, expanded.x1, expanded.y1, expanded.z1,
                   x, y, z].allSatisfy(\.isFinite) else { continue }
            let inside = origin.x >= expanded.x0 && origin.x <= expanded.x1
                && origin.y >= expanded.y0 && origin.y <= expanded.y1
                && origin.z >= expanded.z0 && origin.z <= expanded.z1
            let hit = inside ? 0 : rayAABB(origin.x, origin.y, origin.z, direction.x, direction.y, direction.z, expanded)
            guard hit >= 0, hit <= entityReach, hit < bestDistance,
                  let candidate = target(origin + direction * hit + SIMD3(x-entity.x,y-entity.y,z-entity.z), kind: .entity(entity.id),
                                         normal: nil, distance: hit, reach: entityReach) else { continue }
            bestDistance = hit
            result = candidate
        }
        return result
    }

    /// The exact world's camera-space projection. Subtract in Double first so
    /// far-from-origin worlds do not lose block/tool alignment to Float precision.
    /// Active portal compositing may cosmetically warp pixels after this projection.
    static func project(worldPoint: SIMD3<Double>, cam: CamState,
                        aspect: Float) -> (ndc: SIMD2<Float>, depth: Float)? {
        guard validCamera(cam, aspect: aspect),
              [worldPoint.x, worldPoint.y, worldPoint.z].allSatisfy(\.isFinite) else { return nil }
        let relative = worldPoint - SIMD3(cam.x, cam.y, cam.z)
        let direction = SIMD3<Float>(Float(cos(cam.pitch) * -sin(cam.yaw)),
                                     Float(sin(-cam.pitch)), Float(cos(cam.pitch) * cos(cam.yaw)))
        let view = mat4LookDir(eye: .zero, dir: direction, up: SIMD3(0,1,0))
        let q = view * SIMD4(Float(relative.x), Float(relative.y), Float(relative.z), 1)
        let depth = -q.z
        guard depth > 0.05, depth.isFinite else { return nil }
        let focal = 1 / tan(Float(cam.fov) * .pi / 360)
        let ndc = SIMD2(q.x * focal / (aspect * depth), q.y * focal / depth)
        guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
        return (ndc, depth)
    }

    /// A presentation proxy, not physical reach: changing depth keeps the same
    /// screen pixel. The caller chooses a safe range ahead of its working socket.
    func viewmodelPoint(depthRange: ClosedRange<Float>, viewmodelFOV: Float = 70,
                        aspect: Float) -> SIMD3<Float>? {
        Self.viewmodelPoint(ndc: worldNDC, worldDepth: worldDepth, depthRange: depthRange,
                            viewmodelFOV: viewmodelFOV, aspect: aspect)
    }

    static func viewmodelPoint(ndc: SIMD2<Float>, worldDepth: Float,
                               depthRange: ClosedRange<Float>, viewmodelFOV: Float = 70,
                               aspect: Float) -> SIMD3<Float>? {
        guard ndc.x.isFinite, ndc.y.isFinite, worldDepth.isFinite, worldDepth > 0,
              depthRange.lowerBound.isFinite, depthRange.upperBound.isFinite,
              depthRange.lowerBound > 0.035, viewmodelFOV.isFinite,
              viewmodelFOV > 1, viewmodelFOV < 179, aspect.isFinite, aspect > 0 else { return nil }
        let depth = min(depthRange.upperBound, max(depthRange.lowerBound, worldDepth))
        let tangent = tan(viewmodelFOV * .pi / 360)
        let result = SIMD3(ndc.x * depth * tangent * aspect, ndc.y * depth * tangent, -depth)
        return [result.x, result.y, result.z].allSatisfy(\.isFinite) ? result : nil
    }

    private static func validCamera(_ cam: CamState, aspect: Float) -> Bool {
        [cam.x, cam.y, cam.z, cam.yaw, cam.pitch, cam.fov].allSatisfy(\.isFinite)
            && abs(cos(cam.pitch)) > 1e-6 && cam.fov > 1 && cam.fov < 179
            && aspect.isFinite && aspect > 0
    }
}
