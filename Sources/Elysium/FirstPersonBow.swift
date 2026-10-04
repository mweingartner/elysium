// FirstPersonBow — Minecraft Java Edition's first-person bow presentation.
//
// The reference is the vanilla client (ItemInHandRenderer.renderArmWithItem, UseAnim.BOW branch,
// applyItemArmTransform) and the bow item model (models/item/bow.json display transforms), as
// verified against Mojang-mapped 1.21.1 and Yarn sources on 2026-10-04:
//   - no arm is drawn while a bow is held; the bow is the flat extruded sprite in its own hand
//     (main hand on the right, off hand on the left), mirrored by the arm sign `i`;
//   - while drawing, only the using hand renders; the bow swings toward screen centre, tilts,
//     shakes slightly once drawn past 10%, pulls back and stretches along view depth;
//   - the texture steps through bow_pulling_0/1/2 at 0.65 and 0.9 of a 20-tick draw.
// Camera space matches Minecraft's hand pass: +X right, +Y up, -Z forward, 70° vertical lens.

import Foundation
import simd

enum FirstPersonBow {
    /// Minecraft `rotationXYZ` / `mulPose` order: X, then Y, then Z (Rx · Ry · Rz).
    static func rotationXYZ(degrees x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        let r = Float.pi / 180
        return simd_float4x4(simd_quatf(angle: x * r, axis: SIMD3(1, 0, 0)))
            * simd_float4x4(simd_quatf(angle: y * r, axis: SIMD3(0, 1, 0)))
            * simd_float4x4(simd_quatf(angle: z * r, axis: SIMD3(0, 0, 1)))
    }

    /// Draw strength curve shared with BowItem.getPowerForTime: reaches 1 at 20 ticks.
    static func pull(ticks: Double) -> Float {
        guard ticks.isFinite, ticks > 0 else { return 0 }
        let s = Float(ticks) / 20
        return min(1, (s * s + s * 2) / 3)
    }

    /// Texture stage while drawing: nil = the idle `bow` texture.
    /// Vanilla uses whole ticks: 0–12 → pulling_0, 13–17 → pulling_1, 18+ → pulling_2.
    static func pullingStage(useTicks: Int) -> Int {
        let u = Double(max(0, useTicks)) / 20
        return u < 0.65 ? 0 : (u < 0.9 ? 1 : 2)
    }

    /// Full model matrix for the bow sprite. The sprite mesh is centred on the origin
    /// (Minecraft's model space after its `translate(-0.5, -0.5, -0.5)`), 1 unit square.
    /// - Parameters:
    ///   - right: main hand (right side) or off hand (left side).
    ///   - lift: 0 at rest, 1 fully lowered during an item swap (Minecraft's equip progress).
    ///   - drawTicks: ticks of the current draw including the render partial, or nil when idle.
    static func transform(right: Bool, lift: Float, drawTicks: Double?,
                          bob: SIMD3<Float> = .zero) -> simd_float4x4 {
        let i: Float = right ? 1 : -1
        let equip = lift.isFinite ? min(1, max(0, lift)) : 0
        // applyItemArmTransform
        var m = vmTranslation(SIMD3(i * 0.56, -0.52 - 0.6 * equip, -0.72) + bob)
        if let drawTicks, drawTicks.isFinite {
            m = m * vmTranslation(SIMD3(i * -0.2785682, 0.18344387, 0.15731531))
                * rotationXYZ(degrees: -13.935, 0, 0)
                * rotationXYZ(degrees: 0, i * 35.3, 0)
                * rotationXYZ(degrees: 0, 0, i * -9.785)
            // Vanilla measures from one tick earlier than the use counter.
            let t = max(0, drawTicks - 1)
            let f = pull(ticks: t)
            if f > 0.1 {
                let shake = Float(sin((t - 0.1) * 1.3)) * (f - 0.1)
                m = m * vmTranslation(SIMD3(0, shake * 0.004, 0))
            }
            m = m * vmTranslation(SIMD3(0, 0, f * 0.04))
                * simd_float4x4(diagonal: SIMD4(1, 1, 1 + f * 0.2, 1))
                * rotationXYZ(degrees: 0, -i * 45, 0)
        }
        // bow.json firstperson display: translation in pixels (1/16), rotation [0,-90,25] for
        // both hands after vanilla's left-hand negation of the authored [0,90,-25], scale 0.68.
        return m * vmTranslation(SIMD3(i * 1.13, 3.2, 1.13) / 16)
            * rotationXYZ(degrees: 0, -90, 25)
            * vmScale(0.68)
    }
}
