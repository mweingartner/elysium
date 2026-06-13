// Entity drawing — Builds one vertex buffer
// + skin texture per model, computes per-part pose matrices from the animator
// profiles, draws with the entity pipeline.

import Foundation
import Metal
import simd
import PebbleCore

struct EntityPose {
    var x = 0.0, y = 0.0, z = 0.0
    var yaw = 0.0
    var headYaw = 0.0
    var pitch = 0.0
    var limbSwing = 0.0
    var limbAmp = 0.0
    var attackSwing = 0.0
    var hurtFlash = 0.0
    var scale = 1.0
    var baby = false
    var sky = 0, block = 0
    var ageTicks = 0
    var alpha = 1.0
    // mob-specific data (the golden baselines read these off ent.data)
    var aiming = false
    var crossed = false
    var grazing = false
    var airborne = false
    var hanging = false
    var open = 0.0
    var sitting = false
}

struct EntityUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    // 24 slots — the ender dragon's rig needs more than the old 16
    var parts: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
                simd_float4x4, simd_float4x4, simd_float4x4)
    var light: SIMD4<Float>     // sky, block, dayLight, gamma
    var misc: SIMD4<Float>      // ambient, alpha, fogStart, fogEnd
    var overlay: SIMD4<Float>
    var fogColor: SIMD4<Float>
}

final class ModelGPU {
    let vb: MTLBuffer
    let count: Int
    let texture: MTLTexture
    let model: MobModel

    init(vb: MTLBuffer, count: Int, texture: MTLTexture, model: MobModel) {
        self.vb = vb
        self.count = count
        self.texture = texture
        self.model = model
    }
}

final class EntityRendererM {
    private let device: MTLDevice
    private var geoms: [String: ModelGPU] = [:]
    private var partMats = [simd_float4x4](repeating: matrix_identity_float4x4, count: 24)

    init(device: MTLDevice) {
        self.device = device
    }

    /// resource-pack swap: rebuild skins (geometry is rebuilt with them)
    func resetSkins() {
        geoms.removeAll()
    }

    func geom(_ name: String) -> ModelGPU {
        if let g = geoms[name] { return g }
        let resolved = hasModel(name) ? name : "pig"
        let built = buildEntityGeometry(resolved)
        let vb = built.verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(1, $0.count))! }
        // pack entity texture when the model's UV layout matches vanilla and the
        // image proportions agree; otherwise the procedural skin
        var skinW = built.skin.w, skinH = built.skin.h
        var pixels = built.skin.data
        if let img = packEntityImage(built.model.packTex, stack: built.model.packTexStack,
                                     tints: built.model.packTexTints),
           img.width * built.model.texH == img.height * built.model.texW {
            skinW = img.width
            skinH = img.height
            pixels = img.pixels
        } else if ProcessInfo.processInfo.environment["PEBBLE_PACKDEBUG"] != nil {
            let why = built.model.packTex.isEmpty ? "no packTex mapping" : "pack image missing or proportions mismatch"
            print("[packs] PROCEDURAL skin for model \(resolved): \(why)")
            fflush(stdout)
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: skinW, height: skinH, mipmapped: false)
        td.usage = .shaderRead
        let tex = device.makeTexture(descriptor: td)!
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, skinW, skinH), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: skinW * 4)
        }
        let g = ModelGPU(vb: vb, count: built.vertexCount, texture: tex, model: built.model)
        if ProcessInfo.processInfo.environment["PEBBLE_GEOM_DEBUG"] != nil {
            print("[geom] \(name): \(built.model.parts.count) parts, \(built.vertexCount) verts")
            fflush(stdout)
        }
        geoms[name] = g
        return g
    }

    /// compute per-part matrices by animator profile
    private func pose(_ g: ModelGPU, _ p: EntityPose, _ time: Double) {
        let model = g.model
        let swing = p.limbSwing
        let amp = p.limbAmp
        let walkA = Foundation.cos(swing * 0.6662) * 1.2 * amp
        let walkB = Foundation.cos(swing * 0.6662 + .pi) * 1.2 * amp
        let idle = Foundation.sin(time * 2 + p.x) * 0.02
        for i in 0..<24 {
            guard i < model.parts.count else {
                partMats[i] = matrix_identity_float4x4
                continue
            }
            let part = model.parts[i]
            var m = matrix_identity_float4x4
            let (px, py, pz) = part.pivot
            m = mTranslate(m, Float(px / 16), Float(py / 16), Float(pz / 16))
            // baked part rotation (vanilla rotated boxes: quadruped bodies etc.)
            let (brx, bry, brz) = part.rot
            if brz != 0 { m = mRotateZ(m, Float(brz)) }
            if bry != 0 { m = mRotateY(m, Float(bry)) }
            if brx != 0 { m = mRotateX(m, Float(brx)) }
            let n = part.name
            let anim = model.anim
            switch anim {
            case "biped", "zombie", "skeleton", "illager", "villager", "fly_biped":
                if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                    m = mRotateX(m, Float(-p.pitch))
                } else if n == "armR" {
                    var rx = walkA * 0.8
                    if anim == "zombie" || (anim == "skeleton" && p.aiming) { rx = .pi / 2 + idle * 4 }
                    if p.attackSwing > 0 { rx = .pi / 2 * Foundation.sin(p.attackSwing * .pi) + 0.4 }
                    if anim == "illager" && p.crossed { rx = 0.7 }
                    m = mRotateX(m, Float(rx))
                } else if n == "armL" {
                    var rx = walkB * 0.8
                    if anim == "zombie" { rx = .pi / 2 - idle * 4 }
                    if anim == "illager" && p.crossed { rx = 0.7 }
                    m = mRotateX(m, Float(rx))
                } else if n == "legR" {
                    m = mRotateX(m, Float(walkA))
                } else if n == "legL" {
                    m = mRotateX(m, Float(walkB))
                } else if n == "wingR" {
                    m = mRotateY(m, Float(Foundation.sin(time * 18) * 0.8 + 0.3))
                } else if n == "wingL" {
                    m = mRotateY(m, Float(-Foundation.sin(time * 18) * 0.8 - 0.3))
                }
            case "quad", "quadTail", "horse":
                if n == "head" {
                    m = mRotateY(m, Float(p.headYaw * 0.6))
                    m = mRotateX(m, Float(-(p.pitch * 0.6) - (p.grazing ? 0.9 : 0)))
                } else if n == "legFR" || n == "legBL" {
                    m = mRotateX(m, Float(walkA))
                } else if n == "legFL" || n == "legBR" {
                    m = mRotateX(m, Float(walkB))
                } else if n == "tail" {
                    m = mRotateX(m, Float(-0.6 - Foundation.sin(time * 3) * 0.15 * (1 + amp * 2)))
                }
            case "creeper":
                if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                    m = mRotateX(m, Float(-p.pitch))
                } else if n == "legFR" || n == "legBL" {
                    m = mRotateX(m, Float(walkA * 0.6))
                } else if n == "legFL" || n == "legBR" {
                    m = mRotateX(m, Float(walkB * 0.6))
                }
            case "spider":
                if n.hasPrefix("legR") || n.hasPrefix("legL") {
                    let li = Double(Int(n.dropFirst(4)) ?? 0)
                    let side: Double = n[n.index(n.startIndex, offsetBy: 3)] == "R" ? -1 : 1
                    let lift = Foundation.cos(swing * 0.6662 * 2 + li * 1.7) * 0.3 * amp
                    m = mRotateZ(m, Float(-side * 0.55))
                    m = mRotateY(m, Float((li - 1.5) * 0.5236 * side))
                    m = mRotateZ(m, Float(-side * (0.05 + abs(lift))))
                } else if n == "head" {
                    m = mRotateY(m, Float(p.headYaw * 0.4))
                }
            case "chicken":
                if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                    m = mRotateX(m, Float(-p.pitch))
                } else if n == "legR" {
                    m = mRotateX(m, Float(walkA))
                } else if n == "legL" {
                    m = mRotateX(m, Float(walkB))
                } else if n == "wingR" {
                    m = mRotateZ(m, Float(p.airborne ? Foundation.sin(time * 30) * 0.8 + 0.8 : 0))
                } else if n == "wingL" {
                    m = mRotateZ(m, Float(p.airborne ? -Foundation.sin(time * 30) * 0.8 - 0.8 : 0))
                }
            case "slime":
                let squish = 1 + Foundation.sin(time * 6 + p.x) * 0.06 * (1 + amp)
                m = mScale(m, Float(squish), Float(1 / squish), Float(squish))
            case "blaze":
                if n.hasPrefix("rod") {
                    let ri = Double(Int(n.dropFirst(3)) ?? 0)
                    let ring = (ri / 4).rounded(.down)
                    let ang = (ri.truncatingRemainder(dividingBy: 4)) / 4 * .pi * 2 + time * (ring == 1 ? -1.1 : 1.3) + ring * 0.7
                    let r = 5.0 / 16 + ring * 2 / 16
                    m = mTranslate(m, Float(Foundation.cos(ang) * r),
                                   Float(-ring * 5 / 16 + Foundation.sin(time * 3 + ri) * 0.04),
                                   Float(Foundation.sin(ang) * r))
                } else if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                    m = mRotateX(m, Float(-p.pitch))
                }
            case "ghast":
                if n.hasPrefix("tent") {
                    let ti = Double(Int(n.dropFirst(4)) ?? 0)
                    m = mRotateX(m, Float(Foundation.sin(time * 2 + ti * 1.3) * 0.25))
                }
            case "squid":
                if n.hasPrefix("tent") {
                    let ti = Double(Int(n.dropFirst(4)) ?? 0)
                    let ang = ti / 8 * .pi * 2
                    let sway = Foundation.sin(time * 4 + ti) * 0.3 + 0.4 * amp
                    m = mRotateX(m, Float(Foundation.cos(ang) * sway * 0.4))
                    m = mRotateZ(m, Float(-Foundation.sin(ang) * sway * 0.4))
                }
            case "fish", "dolphin":
                if n == "tail" {
                    m = mRotateY(m, Float(Foundation.sin(time * 8 + swing) * 0.5))
                } else if n == "body" && anim == "fish" {
                    m = mRotateY(m, Float(Foundation.sin(time * 8) * 0.1))
                } else if n == "head" && anim == "dolphin" {
                    m = mRotateX(m, Float(-p.pitch * 0.5))
                }
            case "guardian":
                if n.hasPrefix("spike") {
                    let si = Int(n.dropFirst(5)) ?? 0
                    let dirs: [(Double, Double, Double)] = [
                        (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1),
                        (0.7, 0.7, 0), (-0.7, 0.7, 0), (0.7, -0.7, 0), (-0.7, -0.7, 0), (0, 0.7, 0.7), (0, 0.7, -0.7),
                    ]
                    let d = dirs[si % dirs.count]
                    let ext = 0.45 + Foundation.sin(time * 2 + Double(si)) * 0.06
                    m = mTranslate(m, Float(d.0 * ext), Float(d.1 * ext), Float(d.2 * ext))
                    m = mRotateX(m, Float(d.2 != 0 ? (d.2 > 0 ? 1.0 : -1.0) * .pi / 2 * abs(d.2) : 0))
                    m = mRotateZ(m, Float(d.0 != 0 ? -(d.0 > 0 ? 1.0 : -1.0) * .pi / 2 * abs(d.0) : (d.1 < 0 ? .pi : 0)))
                } else if n == "tail" {
                    m = mRotateY(m, Float(Foundation.sin(time * 4) * 0.3))
                }
            case "shulker":
                if n == "lid" {
                    let open = p.open
                    m = mTranslate(m, 0, Float(open * 0.45), 0)
                    m = mRotateY(m, Float(open * time * 1.5))
                }
            case "crystal":
                if n == "crystal" {
                    m = mTranslate(m, 0, Float(Foundation.sin(time * 1.5) * 0.1), 0)
                    m = mRotateY(m, Float(time * 1.6))
                    m = mRotateZ(m, 0.96)
                }
            case "bat":
                if n == "wingR" {
                    m = mRotateY(m, Float(Foundation.sin(time * 22) * 1 + 0.4))
                } else if n == "wingL" {
                    m = mRotateY(m, Float(-Foundation.sin(time * 22) * 1 - 0.4))
                } else if n == "head" && p.hanging {
                    m = mRotateX(m, .pi)
                }
            case "bee":
                if n == "wingR" {
                    m = mRotateY(m, Float(Foundation.sin(time * 40) * 0.9 + 0.3))
                } else if n == "wingL" {
                    m = mRotateY(m, Float(-Foundation.sin(time * 40) * 0.9 - 0.3))
                } else if n == "body" {
                    m = mRotateX(m, Float(Foundation.sin(time * 3) * 0.08))
                }
            case "parrot":
                if n == "wingR" || n == "wingL" {
                    let flap = p.airborne ? Foundation.sin(time * 25) * 0.8 : 0
                    m = mRotateZ(m, Float((n == "wingR" ? 1.0 : -1.0) * flap))
                } else if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                    m = mRotateX(m, Float(-p.pitch))
                }
            case "phantom":
                if n == "wingR" {
                    m = mRotateZ(m, Float(Foundation.sin(time * 4) * 0.3 + 0.1))
                } else if n == "wingL" {
                    m = mRotateZ(m, Float(-Foundation.sin(time * 4) * 0.3 - 0.1))
                }
            case "dragon":
                if n == "wingR" {
                    m = mRotateZ(m, Float(Foundation.sin(time * 1.6) * 0.55 + 0.12))
                } else if n == "wingL" {
                    m = mRotateZ(m, Float(-Foundation.sin(time * 1.6) * 0.55 - 0.12))
                } else if n == "head" {
                    m = mRotateY(m, Float(p.headYaw * 0.5))
                    m = mRotateX(m, Float(-p.pitch * 0.5))
                } else if n.hasPrefix("tail") {
                    let ti = Double(Int(n.dropFirst(4)) ?? 0)
                    m = mRotateY(m, Float(Foundation.sin(time * 1.2 - ti * 0.6) * 0.18))
                } else if n.hasPrefix("leg") {
                    m = mRotateX(m, 0.4)
                }
            case "wither":
                if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                    m = mRotateX(m, Float(-p.pitch))
                } else if n == "headR" {
                    m = mRotateY(m, Float(p.headYaw + Foundation.sin(time * 1.4) * 0.3))
                } else if n == "headL" {
                    m = mRotateY(m, Float(p.headYaw - Foundation.sin(time * 1.7) * 0.3))
                }
            case "snowman":
                if n == "head" {
                    m = mRotateY(m, Float(p.headYaw))
                } else if n == "armR" {
                    m = mRotateZ(m, Float(Foundation.sin(time * 2) * 0.05))
                } else if n == "armL" {
                    m = mRotateZ(m, Float(-Foundation.sin(time * 2) * 0.05))
                }
            case "strider":
                if n == "legR" {
                    m = mRotateX(m, Float(walkA))
                } else if n == "legL" {
                    m = mRotateX(m, Float(walkB))
                }
            case "rabbit", "frog":
                let hop = min(1, max(0, Foundation.sin(swing * 1.2) * amp * 2))
                if n.hasPrefix("legB") {
                    m = mRotateX(m, Float(-hop * 0.8))
                } else if n.hasPrefix("legF") {
                    m = mRotateX(m, Float(hop * 0.5))
                }
            case "silverfish":
                if n == "body" {
                    m = mRotateY(m, Float(Foundation.sin(swing * 1.5) * 0.15 * amp))
                }
            default:
                break
            }
            partMats[i] = m
        }
    }

    func draw(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
              viewProj: simd_float4x4, camPos: SIMD3<Double>, name: String, p: EntityPose,
              time: Double, dayLight: Double, fog: (color: SIMD3<Float>, start: Float, end: Float),
              gamma: Double, ambient: Double) {
        let g = geom(name)
        pose(g, p, time)
        var m = matrix_identity_float4x4
        m = mTranslate(m, Float(p.x - camPos.x), Float(p.y - camPos.y), Float(p.z - camPos.z))
        // models are built MC-style facing -Z; vanilla renders them rotated by
        // (180° - yaw) so the -Z front ends up pointing along the entity's yaw.
        // Without the 180° the whole bestiary (and 3rd-person player) moonwalks.
        m = mRotateY(m, Float(.pi - p.yaw))
        let sc = Float(p.scale * g.model.scale * (p.baby ? 0.5 : 1))
        m = mScale(m, sc, sc, sc)

        var u = EntityUniforms(
            viewProj: viewProj,
            model: m,
            parts: (partMats[0], partMats[1], partMats[2], partMats[3], partMats[4], partMats[5], partMats[6],
                    partMats[7], partMats[8], partMats[9], partMats[10], partMats[11], partMats[12], partMats[13],
                    partMats[14], partMats[15], partMats[16], partMats[17], partMats[18], partMats[19],
                    partMats[20], partMats[21], partMats[22], partMats[23]),
            light: SIMD4<Float>(Float(p.sky), Float(p.block), Float(dayLight), Float(gamma)),
            misc: SIMD4<Float>(Float(ambient), Float(p.alpha), fog.start, fog.end),
            overlay: SIMD4<Float>(1, 0.2, 0.2, Float(p.hurtFlash * 0.5)),
            fogColor: SIMD4<Float>(fog.color.x, fog.color.y, fog.color.z, 1))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(g.vb, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
        enc.setFragmentTexture(g.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.count)
    }
}
