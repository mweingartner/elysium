// Entity box models (box-UV) + dormant procedural skin painters — geometry
// is pinned by the golden baselines.
// Model space: 1 unit = 1/16 block, Y up, origin at feet center.

import Foundation

public struct ModelBox {
    public let x: Double, y: Double, z: Double
    public let w: Double, h: Double, d: Double
    public let u: Double, v: Double
    public let grow: Double

    public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double, _ h: Double, _ d: Double, _ u: Double, _ v: Double, _ grow: Double = 0) {
        self.x = x; self.y = y; self.z = z
        self.w = w; self.h = h; self.d = d
        self.u = u; self.v = v
        self.grow = grow
    }
}

public struct ModelPart {
    public let name: String
    public let pivot: (Double, Double, Double)
    public let rot: (Double, Double, Double)   // baked rotation, radians (XYZ order)
    public let boxes: [ModelBox]

    public init(name: String, pivot: (Double, Double, Double),
                rot: (Double, Double, Double) = (0, 0, 0), boxes: [ModelBox]) {
        self.name = name
        self.pivot = pivot
        self.rot = rot
        self.boxes = boxes
    }
}

public struct MobModel {
    public let texW: Int
    public let texH: Int
    public let parts: [ModelPart]
    public let anim: String
    public let scale: Double
    public let paint: (EntitySkin) -> Void
    /// vanilla entity texture path(s) this model's UV layout matches —
    /// base texture + optional overlays composited in order (eyes etc.)
    public let packTex: [String]
    /// true = packTex entries stack VERTICALLY into one sheet (sheep + fur)
    /// instead of compositing over each other
    public let packTexStack: Bool
    /// per-layer RGB multipliers for packTex — vanilla ships some entity art
    /// grayscale and tints it at render time (tropical fish, sheep wool);
    /// empty = no tinting
    public let packTexTints: [Int]

    public init(texW: Int, texH: Int, parts: [ModelPart], anim: String, scale: Double,
                paint: @escaping (EntitySkin) -> Void, packTex: [String] = [], packTexStack: Bool = false,
                packTexTints: [Int] = []) {
        self.texW = texW
        self.texH = texH
        self.parts = parts
        self.anim = anim
        self.scale = scale
        self.paint = paint
        self.packTex = packTex
        self.packTexStack = packTexStack
        self.packTexTints = packTexTints
    }
}

/// raw-pixel skin painter (the original renderer design painted a canvas)
public final class EntitySkin {
    public let w: Int, h: Int
    public var data: [UInt8]
    public let seed: UInt32

    public init(_ w: Int, _ h: Int, _ name: String) {
        self.w = w
        self.h = h
        data = [UInt8](repeating: 0, count: w * h * 4)
        seed = hashString(name)
    }

    public func rand(_ x: Int, _ y: Int, _ salt: UInt32 = 0) -> Double {
        Double(hash2(seed, x, y, salt)) / 4294967296.0
    }
    private func put(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int) {
        if x < 0 || x >= w || y < 0 || y >= h { return }
        let i = (y * w + x) * 4
        data[i] = UInt8(min(255, max(0, r)))
        data[i + 1] = UInt8(min(255, max(0, g)))
        data[i + 2] = UInt8(min(255, max(0, b)))
        data[i + 3] = 255
    }
    public func fill(_ u: Int, _ v: Int, _ fw: Int, _ fh: Int, _ c: Int, _ noise: Double = 0.08) {
        for y in 0..<fh {
            for x in 0..<fw {
                let f = 1 - noise + rand(u + x, v + y) * noise * 2
                put(u + x, v + y, Int(Double((c >> 16) & 255) * f), Int(Double((c >> 8) & 255) * f), Int(Double(c & 255) * f))
            }
        }
    }
    public func px(_ u: Int, _ v: Int, _ c: Int) {
        put(u, v, (c >> 16) & 255, (c >> 8) & 255, c & 255)
    }
    public func rect(_ u: Int, _ v: Int, _ rw: Int, _ rh: Int, _ c: Int) {
        for y in 0..<rh { for x in 0..<rw { px(u + x, v + y, c) } }
    }
    /// fill the whole box-UV unwrap of a box at (u,v) sized w,h,d
    public func box(_ u: Int, _ v: Int, _ bw: Int, _ bh: Int, _ bd: Int, _ c: Int, _ noise: Double = 0.08) {
        fill(u + bd, v, bw, bd, c, noise)                       // top
        fill(u + bd + bw, v, bw, bd, shadeColor(c, 0.8), noise) // bottom
        fill(u, v + bd, bd, bh, shadeColor(c, 0.85), noise)     // right
        fill(u + bd, v + bd, bw, bh, c, noise)                  // front
        fill(u + bd + bw, v + bd, bd, bh, shadeColor(c, 0.85), noise) // left
        fill(u + bd + bw + bd, v + bd, bw, bh, shadeColor(c, 0.92), noise) // back
    }
    private func putA(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, _ a: Int) {
        if x < 0 || x >= w || y < 0 || y >= h { return }
        let i = (y * w + x) * 4
        data[i] = UInt8(min(255, max(0, r)))
        data[i + 1] = UInt8(min(255, max(0, g)))
        data[i + 2] = UInt8(min(255, max(0, b)))
        data[i + 3] = UInt8(min(255, max(0, a)))
    }
    public func fillA(_ u: Int, _ v: Int, _ fw: Int, _ fh: Int, _ c: Int, _ a: Int, _ noise: Double = 0.08) {
        for y in 0..<fh {
            for x in 0..<fw {
                let f = 1 - noise + rand(u + x, v + y) * noise * 2
                putA(u + x, v + y, Int(Double((c >> 16) & 255) * f), Int(Double((c >> 8) & 255) * f), Int(Double(c & 255) * f), a)
            }
        }
    }
    /// box unwrap fill with uniform alpha (translucent shells like slime gel)
    public func boxA(_ u: Int, _ v: Int, _ bw: Int, _ bh: Int, _ bd: Int, _ c: Int, _ a: Int, _ noise: Double = 0.08) {
        fillA(u + bd, v, bw, bd, c, a, noise)
        fillA(u + bd + bw, v, bw, bd, shadeColor(c, 0.8), a, noise)
        fillA(u, v + bd, bd, bh, shadeColor(c, 0.85), a, noise)
        fillA(u + bd, v + bd, bw, bh, c, a, noise)
        fillA(u + bd + bw, v + bd, bd, bh, shadeColor(c, 0.85), a, noise)
        fillA(u + bd + bw + bd, v + bd, bw, bh, shadeColor(c, 0.92), a, noise)
    }

    public func eyes(_ u: Int, _ v: Int, _ d: Int, _ fx: Int, _ fy: Int, _ gap: Int, _ ew: Int, _ eh: Int, _ white: Int, _ pupil: Int) {
        let fu = u + d, fv = v + d
        rect(fu + fx, fv + fy, ew, eh, white)
        rect(fu + fx + ew - 1, fv + fy, 1, eh, pupil)
        rect(fu + fx + gap, fv + fy, ew, eh, white)
        rect(fu + fx + gap, fv + fy, 1, eh, pupil)
    }
}

func shadeColor(_ c: Int, _ f: Double) -> Int {
    let r = min(255, Int(detRound(Double((c >> 16) & 255) * f)))
    let g = min(255, Int(detRound(Double((c >> 8) & 255) * f)))
    let b = min(255, Int(detRound(Double(c & 255) * f)))
    return (r << 16) | (g << 8) | b
}

var MODELS: [String: MobModel] = [:]

public func getModel(_ name: String) -> MobModel {
    ensureModels()
    return MODELS[name] ?? MODELS["pig"]!
}
public func hasModel(_ name: String) -> Bool {
    ensureModels()
    return MODELS[name] != nil
}

private func M(_ name: String, _ m: MobModel) { MODELS[name] = m }
private func part(_ name: String, _ pivot: (Double, Double, Double), _ boxes: ModelBox...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, boxes: boxes)
}
private func rpart(_ name: String, _ pivot: (Double, Double, Double), _ rot: (Double, Double, Double), _ boxes: ModelBox...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, rot: rot, boxes: boxes)
}
private func box(_ x: Double, _ y: Double, _ z: Double, _ w: Double, _ h: Double, _ d: Double, _ u: Double, _ v: Double, _ grow: Double = 0) -> ModelBox {
    ModelBox(x, y, z, w, h, d, u, v, grow)
}

private func quadModel(
    _ paint: @escaping (EntitySkin) -> Void,
    bodyW: Double = 10, bodyH: Double = 8, bodyL: Double = 16,
    legH: Double = 6, headS: Double = 8, scale: Double = 1, anim: String = "quad",
    texW: Int = 64, texH: Int = 64
) -> MobModel {
    let bw = bodyW, bh = bodyH, bl = bodyL, lh = legH, hs = headS
    return MobModel(
        texW: texW, texH: texH,
        parts: [
            part("head", (0, lh + bh - 1, -bl / 2), box(-hs / 2, -hs / 2 + 1, -hs, hs, hs, hs, 0, 0)),
            part("body", (0, lh, 0), box(-bw / 2, 0, -bl / 2, bw, bh, bl, 28, 8)),
            part("legFR", (-bw / 2 + 2, lh, -bl / 2 + 2), box(-2, -lh, -2, 4, lh, 4, 0, 16)),
            part("legFL", (bw / 2 - 2, lh, -bl / 2 + 2), box(-2, -lh, -2, 4, lh, 4, 0, 16)),
            part("legBR", (-bw / 2 + 2, lh, bl / 2 - 2), box(-2, -lh, -2, 4, lh, 4, 0, 16)),
            part("legBL", (bw / 2 - 2, lh, bl / 2 - 2), box(-2, -lh, -2, 4, lh, 4, 0, 16)),
        ],
        anim: anim, scale: scale, paint: paint
    )
}

private func cowModel(_ c: Int, packTex: [String]) -> MobModel {
    MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 20, -8), box(-4, -4, -6, 8, 8, 6, 0, 0),
                 box(-5, 2, -4, 1, 3, 1, 22, 0), box(4, 2, -4, 1, 3, 1, 22, 0)),
            rpart("body", (0, 19, 2), (-Double.pi / 2, 0, 0),
                  box(-6, -8, -7, 12, 18, 10, 18, 4), box(-2, -8, -8, 4, 6, 1, 52, 0)),
            part("legFR", (-4, 12, -6), box(-2, -12, -2, 4, 12, 4, 0, 16)),
            part("legFL", (4, 12, -6), box(-2, -12, -2, 4, 12, 4, 0, 16)),
            part("legBR", (-4, 12, 7), box(-2, -12, -2, 4, 12, 4, 0, 16)),
            part("legBL", (4, 12, 7), box(-2, -12, -2, 4, 12, 4, 0, 16)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            s.box(0, 0, 8, 8, 6, c, 0.12)
            s.eyes(0, 0, 6, 1, 3, 5, 2, 1, 0xffffff, 0x1c1c1c)
            s.box(22, 0, 1, 3, 1, 0xc8c0b0, 0.06)               // horns
            s.box(18, 4, 12, 18, 10, c, 0.12)                   // body
            s.box(52, 0, 4, 6, 1, 0xe8d8d0, 0.08)               // udder
            s.box(0, 16, 4, 12, 4, c, 0.12)                     // legs
            s.fill(4, 29, 4, 3, 0xe8e0d8, 0.1)                  // hooves
        },
        packTex: packTex)
}

private var modelsRegistered = false
public func ensureModels() {
    if modelsRegistered { return }
    modelsRegistered = true

    M("pig", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 12, -6), box(-4, -4, -8, 8, 8, 8, 0, 0), box(-2, -3, -9, 4, 3, 1, 16, 16)),
            rpart("body", (0, 13, 2), (-Double.pi / 2, 0, 0), box(-5, -6, -7, 10, 16, 8, 28, 8)),
            part("legFR", (-3, 6, -5), box(-2, -6, -2, 4, 6, 4, 0, 16)),
            part("legFL", (3, 6, -5), box(-2, -6, -2, 4, 6, 4, 0, 16)),
            part("legBR", (-3, 6, 7), box(-2, -6, -2, 4, 6, 4, 0, 16)),
            part("legBL", (3, 6, 7), box(-2, -6, -2, 4, 6, 4, 0, 16)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            s.box(0, 0, 8, 8, 8, 0xeea4a4, 0.12)
            s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xffffff, 0x1c1c1c)
            s.box(16, 16, 4, 3, 1, 0xd88a8a, 0.1)   // snout
            s.box(28, 8, 10, 16, 8, 0xeea4a4, 0.12)
            s.box(0, 16, 4, 6, 4, 0xeea4a4, 0.12)
        },
        packTex: ["entity/pig/pig.png"]))

    M("cow", cowModel(0x443626, packTex: ["entity/cow/cow.png"]))

    M("sheep", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 18, -8), box(-3, -2, -6, 6, 6, 8, 0, 0), box(-3, -2, -6, 6, 6, 8, 0, 32, 0.6)),
            rpart("body", (0, 19, 2), (-Double.pi / 2, 0, 0),
                  box(-4, -6, -7, 8, 16, 6, 28, 8), box(-4, -6, -7, 8, 16, 6, 28, 40, 1.75)),
            part("legFR", (-3, 12, -5), box(-2, -12, -2, 4, 12, 4, 0, 16), box(-2, -6, -2, 4, 6, 4, 0, 48, 0.5)),
            part("legFL", (3, 12, -5), box(-2, -12, -2, 4, 12, 4, 0, 16), box(-2, -6, -2, 4, 6, 4, 0, 48, 0.5)),
            part("legBR", (-3, 12, 7), box(-2, -12, -2, 4, 12, 4, 0, 16), box(-2, -6, -2, 4, 6, 4, 0, 48, 0.5)),
            part("legBL", (3, 12, 7), box(-2, -12, -2, 4, 12, 4, 0, 16), box(-2, -6, -2, 4, 6, 4, 0, 48, 0.5)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            let skin = 0xb89a8a, wool = 0xe8e8e8
            s.box(0, 0, 6, 6, 8, skin, 0.1)
            s.rect(8 + 1, 8 + 2, 1, 2, 0x1c1c1c); s.rect(8 + 4, 8 + 2, 1, 2, 0x1c1c1c) // eyes
            s.box(28, 8, 8, 16, 6, skin, 0.1)
            s.box(0, 16, 4, 12, 4, skin, 0.1)
            s.box(0, 32, 6, 6, 8, wool, 0.05)
            s.box(28, 40, 8, 16, 6, wool, 0.05)
            s.box(0, 48, 4, 6, 4, wool, 0.05)
        },
        packTex: ["entity/sheep/sheep.png", "entity/sheep/sheep_fur.png"], packTexStack: true))
    // dyed sheep: same rig, wool sheet (layer 2 of the stack) tinted per dye.
    // modelNameFor routes sheep with data.color N to "sheep_N"
    let sheepBase = MODELS["sheep"]!
    let DYE_RGB: [Int] = [0xF9FFFE, 0xF9801D, 0xC74EBD, 0x3AB3DA, 0xFED83D, 0x80C71F, 0xF38BAA, 0x474F52,
                          0x9D9D97, 0x169C9C, 0x8932B8, 0x3C44AA, 0x835432, 0x5E7C16, 0xB02E26, 0x1D1D21]
    for (i, dye) in DYE_RGB.enumerated() where i > 0 {
        M("sheep_\(i)", MobModel(texW: sheepBase.texW, texH: sheepBase.texH, parts: sheepBase.parts,
                                 anim: sheepBase.anim, scale: 1, paint: sheepBase.paint,
                                 packTex: sheepBase.packTex, packTexStack: true,
                                 packTexTints: [0xFFFFFF, dye]))
    }

    M("chicken", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 9, -4), box(-2, 0, -2, 4, 6, 3, 0, 0), box(-2, 2, -4, 4, 2, 2, 14, 0), box(-1, 0, -3, 2, 2, 2, 14, 4)),
            rpart("body", (0, 8, 0), (-Double.pi / 2, 0, 0), box(-3, -4, -3, 6, 8, 6, 0, 9)),
            part("wingR", (-3, 11, 0), box(-1, -4, -3, 1, 4, 6, 24, 13)),
            part("wingL", (3, 11, 0), box(0, -4, -3, 1, 4, 6, 24, 13)),
            part("legR", (-2, 5, 1), box(-1, -5, -3, 3, 5, 3, 26, 0)),
            part("legL", (2, 5, 1), box(-2, -5, -3, 3, 5, 3, 26, 0)),
        ],
        anim: "chicken", scale: 1,
        paint: { s in
            s.box(0, 0, 4, 6, 3, 0xe8e8e8, 0.08)
            s.box(14, 0, 4, 2, 2, 0xe8a83c)  // beak
            s.box(14, 4, 2, 2, 2, 0xc84040)  // wattle
            let fu = 0 + 3, fv = 0 + 3
            s.px(fu + 0, fv + 1, 0x1c1c1c); s.px(fu + 3, fv + 1, 0x1c1c1c)
            s.box(0, 9, 6, 8, 6, 0xe8e8e8, 0.08)
            s.box(24, 13, 1, 4, 6, 0xd8d8d8, 0.08)
            s.box(26, 0, 3, 5, 3, 0xe8a83c, 0.08)
        },
        packTex: ["entity/chicken.png"]))

    M("mooshroom", {
        let base = cowModel(0xa42c2c, packTex: ["entity/cow/red_mooshroom.png"])
        var parts = base.parts
        // back mushrooms — small caps sampling the red hide region of the
        // mooshroom sheet (vanilla renders real mushroom blocks; this is a
        // textured approximation)
        parts.append(ModelPart(name: "shrooms", pivot: (0, 24, 2), boxes: [
            box(-1.5, 0, -7, 3, 3, 3, 20, 6), box(-1.5, 0, -1, 3, 3, 3, 20, 6),
            box(-1.5, 0, 5, 3, 3, 3, 20, 6),
        ]))
        return MobModel(texW: base.texW, texH: base.texH, parts: parts, anim: base.anim,
                        scale: base.scale, paint: base.paint, packTex: base.packTex)
    }())

    // everything else EntityModels2.swift
    registerAllModels()
}

// ---------------------------------------------------------------------------
// geometry: 9 floats per vertex (pos3, normal3, uv2, partIdx)
// ---------------------------------------------------------------------------
public struct EntityGeometry {
    public let verts: [Float]
    public let vertexCount: Int
    public let partNames: [String]
    public let model: MobModel
    public let skin: EntitySkin
}

public func buildEntityGeometry(_ name: String) -> EntityGeometry {
    ensureModels()
    let model = getModel(name)
    var verts: [Float] = []
    var partNames: [String] = []
    for (pi, p) in model.parts.enumerated() where pi < 24 {
        partNames.append(p.name)
        for b in p.boxes {
            let g = b.grow
            let x0 = (b.x - g) / 16, y0 = (b.y - g) / 16, z0 = (b.z - g) / 16
            let x1 = (b.x + b.w + g) / 16, y1 = (b.y + b.h + g) / 16, z1 = (b.z + b.d + g) / 16
            let tw = Double(model.texW), th = Double(model.texH)
            let u = b.u, v = b.v, w = b.w, h = b.h, d = b.d
            let top = (u + d, v, u + d + w, v + d)
            let bottom = (u + d + w, v, u + d + w + w, v + d)
            let right = (u, v + d, u + d, v + d + h)
            let front = (u + d, v + d, u + d + w, v + d + h)
            let left = (u + d + w, v + d, u + d + w + d, v + d + h)
            let back = (u + d + w + d, v + d, u + d + w + d + w, v + d + h)
            func quad(_ ax: Double, _ ay: Double, _ az: Double, _ bx: Double, _ by: Double, _ bz: Double,
                      _ cx: Double, _ cy: Double, _ cz: Double, _ dx: Double, _ dy: Double, _ dz: Double,
                      _ nx: Double, _ ny: Double, _ nz: Double, _ uv: (Double, Double, Double, Double)) {
                let (u0, v0, u1, v1) = uv
                let corners: [(Double, Double, Double, Double, Double)] = [
                    (ax, ay, az, u0 / tw, v1 / th), (bx, by, bz, u1 / tw, v1 / th),
                    (cx, cy, cz, u1 / tw, v0 / th), (dx, dy, dz, u0 / tw, v0 / th),
                ]
                for i in [0, 2, 1, 0, 3, 2] {
                    let c = corners[i]
                    verts.append(Float(c.0)); verts.append(Float(c.1)); verts.append(Float(c.2))
                    verts.append(Float(nx)); verts.append(Float(ny)); verts.append(Float(nz))
                    verts.append(Float(c.3)); verts.append(Float(c.4))
                    verts.append(Float(pi))
                }
            }
            quad(x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, bottom)
            quad(x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, top)
            quad(x1, y0, z0, x0, y0, z0, x0, y1, z0, x1, y1, z0, 0, 0, -1, front)
            quad(x0, y0, z1, x1, y0, z1, x1, y1, z1, x0, y1, z1, 0, 0, 1, back)
            quad(x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, right)
            quad(x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, left)
        }
    }
    let skin = EntitySkin(model.texW, model.texH, name)
    model.paint(skin)
    return EntityGeometry(verts: verts, vertexCount: verts.count / 9, partNames: partNames, model: model, skin: skin)
}
