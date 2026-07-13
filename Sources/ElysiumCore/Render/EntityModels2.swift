// Entity models, full bestiary — geometry pinned by the golden baselines.
// Registration order and every box/pixel matches the golden baselines; EntityModels.swift
// owns the types (ModelBox/ModelPart/MobModel/EntitySkin) and the geometry builder.

import Foundation

func M2(_ name: String, _ m: MobModel) { MODELS[name] = m }
private func rpart(_ name: String, _ pivot: (Double, Double, Double), _ rot: (Double, Double, Double), _ boxes: ModelBox...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, rot: rot, boxes: boxes)
}
private func part(_ name: String, _ pivot: (Double, Double, Double), _ boxes: ModelBox...) -> ModelPart {
    ModelPart(name: name, pivot: pivot, boxes: boxes)
}
private func partList(_ name: String, _ pivot: (Double, Double, Double), _ boxes: [ModelBox]) -> ModelPart {
    ModelPart(name: name, pivot: pivot, boxes: boxes)
}
private func box(_ x: Double, _ y: Double, _ z: Double, _ w: Double, _ h: Double, _ d: Double, _ u: Double, _ v: Double, _ grow: Double = 0) -> ModelBox {
    ModelBox(x, y, z, w, h, d, u, v, grow)
}

// ---------------------------------------------------------------------------
// shared model factories
// ---------------------------------------------------------------------------
func bipedModel(_ paint: @escaping (EntitySkin) -> Void, scale: Double = 1, anim: String = "biped",
                texH: Int = 64, packTex: [String] = []) -> MobModel {
    MobModel(
        texW: 64, texH: texH,
        parts: [
            part("head", (0, 24, 0), box(-4, 0, -4, 8, 8, 8, 0, 0)),
            part("body", (0, 24, 0), box(-4, -12, -2, 8, 12, 4, 16, 16)),
            part("armR", (-5, 22, 0), box(-3, -10, -2, 4, 12, 4, 40, 16)),
            part("armL", (5, 22, 0), box(-1, -10, -2, 4, 12, 4, 40, 16, 0)),
            part("legR", (-2, 12, 0), box(-2, -12, -2, 4, 12, 4, 0, 16)),
            part("legL", (2, 12, 0), box(-2, -12, -2, 4, 12, 4, 0, 16)),
        ],
        anim: anim, scale: scale, paint: paint, packTex: packTex)
}
/// vanilla skeleton rig: biped pivots but THIN 2×12×2 limbs — the player-
/// sized 4-wide limbs over-read the unwrap into skeleton.png's legacy pink
/// junk region (the "pink rear" bug)
func skeletonModel(_ paint: @escaping (EntitySkin) -> Void, scale: Double = 1,
                   packTex: [String] = []) -> MobModel {
    MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 24, 0), box(-4, 0, -4, 8, 8, 8, 0, 0)),
            part("body", (0, 24, 0), box(-4, -12, -2, 8, 12, 4, 16, 16)),
            part("armR", (-5, 22, 0), box(-1, -10, -1, 2, 12, 2, 40, 16)),
            part("armL", (5, 22, 0), box(-1, -10, -1, 2, 12, 2, 40, 16)),
            part("legR", (-2, 12, 0), box(-1, -12, -1, 2, 12, 2, 0, 16)),
            part("legL", (2, 12, 0), box(-1, -12, -1, 2, 12, 2, 0, 16)),
        ],
        anim: "skeleton", scale: scale, paint: paint, packTex: packTex)
}

func villagerModelPacked(_ packTex: [String], _ scale: Double = 1, _ paint: @escaping (EntitySkin) -> Void) -> MobModel {
    villagerModel(paint, scale, packTex: packTex)
}
func villagerModel(_ paint: @escaping (EntitySkin) -> Void, _ scale: Double = 1, packTex: [String] = []) -> MobModel {
    MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 24, 0), box(-4, 0, -4, 8, 10, 8, 0, 0), box(-1, 0, -6, 2, 4, 2, 24, 0)), // head + nose
            part("body", (0, 24, 0), box(-4, -12, -3, 8, 12, 6, 16, 20)),
            part("armR", (0, 22, 0), box(-8, -4, -2, 4, 8, 4, 44, 22)),
            part("armL", (0, 22, 0), box(4, -4, -2, 4, 8, 4, 44, 22)),
            part("legR", (-2, 12, 0), box(-2, -12, -2, 4, 12, 4, 0, 22)),
            part("legL", (2, 12, 0), box(-2, -12, -2, 4, 12, 4, 0, 22)),
        ],
        anim: "villager", scale: scale, paint: paint, packTex: packTex)
}

// ---------------------------------------------------------------------------
// skins + model registrations (the frozen baseline order, then the frozen baseline)
// ---------------------------------------------------------------------------
func registerAllModels() {
    // PLAYER
    M2("player", bipedModel({ s in
        s.box(0, 0, 8, 8, 8, 0xc8987a)                    // head skin tone
        s.fill(8, 8, 8, 3, 0x3a2c1c, 0.15)                // hair top of face
        s.fill(8, 0, 8, 8, 0x3a2c1c, 0.15)                // hair top
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xffffff, 0x4a3cc8)
        s.rect(11, 14, 2, 1, 0xa87858)                    // mouth shadow
        s.box(16, 16, 8, 12, 4, 0x2ca89a)                 // teal shirt
        s.box(40, 16, 4, 12, 4, 0xc8987a)                 // arms skin
        s.fill(44, 20, 4, 6, 0x2ca89a, 0.08)              // sleeve
        s.box(0, 16, 4, 12, 4, 0x4a4a6a)                  // pants
        s.fill(4, 24, 4, 4, 0x3a3a3a, 0.1)                // shoes
    }, packTex: ["entity/player/wide/steve.png"]))

    // VILLAGER-LIKE
    M2("villager", villagerModelPacked(["entity/villager/villager.png"]) { s in
        s.box(0, 0, 8, 10, 8, 0xb88a68)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xffffff, 0x3c7a3c)
        s.rect(8 + 3, 8 + 5 + 2, 2, 3, 0xa07050) // nose shading on front
        s.box(24, 0, 2, 4, 2, 0xa87858)          // nose box
        s.fill(8, 8, 8, 2, 0x6a4c2c, 0.12)       // unibrow/hair
        s.box(16, 20, 8, 12, 6, 0x7a5c3c)        // brown robe
        s.fill(20, 26, 8, 12, 0x8a6a48, 0.1)
        s.box(44, 22, 4, 8, 4, 0x7a5c3c)
        s.box(0, 22, 4, 12, 4, 0x5a4430)
    })
    // professioned villagers: base skin + the pack's profession overlay.
    // modelNameFor routes by Villager.profession
    let vilBase = MODELS["villager"]!
    for prof in ["farmer", "fisherman", "shepherd", "fletcher", "librarian", "cartographer",
                 "cleric", "armorer", "weaponsmith", "toolsmith", "butcher", "leatherworker",
                 "mason", "nitwit"] {
        M2("villager_\(prof)", MobModel(texW: vilBase.texW, texH: vilBase.texH, parts: vilBase.parts,
                                        anim: vilBase.anim, scale: vilBase.scale, paint: vilBase.paint,
                                        packTex: ["entity/villager/villager.png",
                                                  "entity/villager/profession/\(prof).png"]))
    }
    M2("wandering_trader", villagerModelPacked(["entity/wandering_trader.png"]) { s in
        s.box(0, 0, 8, 10, 8, 0xb88a68)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xffffff, 0x3c5ac8)
        s.box(24, 0, 2, 4, 2, 0xa87858)
        s.box(16, 20, 8, 12, 6, 0x2c5ac8)
        s.box(44, 22, 4, 8, 4, 0x2c5ac8)
        s.box(0, 22, 4, 12, 4, 0x24449a)
    })
    M2("zombie_villager", villagerModel({ s in
        s.box(0, 0, 8, 10, 8, 0x6a9a5a)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xc83a3a, 0x6a1010)
        s.box(24, 0, 2, 4, 2, 0x5a8a4c)
        s.box(16, 20, 8, 12, 6, 0x5a4430)
        s.box(44, 22, 4, 8, 4, 0x6a9a5a)
        s.box(0, 22, 4, 12, 4, 0x44341f)
    }, 1, packTex: ["entity/zombie_villager/zombie_villager.png"]))

    // UNDEAD
    M2("zombie", bipedModel({ s in
        s.box(0, 0, 8, 8, 8, 0x5a9a4c)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0x1c1c1c, 0x000000)
        s.box(16, 16, 8, 12, 4, 0x2c8a8a)
        s.box(40, 16, 4, 12, 4, 0x5a9a4c)
        s.box(0, 16, 4, 12, 4, 0x4a3c8a)
    }, anim: "zombie", packTex: ["entity/zombie/zombie.png"]))
    M2("husk", bipedModel({ s in
        s.box(0, 0, 8, 8, 8, 0xb89a6a)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0x2c2418, 0x000000)
        s.box(16, 16, 8, 12, 4, 0x8a7a4c)
        s.box(40, 16, 4, 12, 4, 0xb89a6a)
        s.box(0, 16, 4, 12, 4, 0x6a5c38)
    }, anim: "zombie", packTex: ["entity/zombie/husk.png"]))
    M2("drowned", bipedModel({ s in
        s.box(0, 0, 8, 8, 8, 0x6a9a8a)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xc8e8e0, 0x2c6a5a)
        s.box(16, 16, 8, 12, 4, 0x4a7a8a)
        s.box(40, 16, 4, 12, 4, 0x6a9a8a)
        s.box(0, 16, 4, 12, 4, 0x3a5a6a)
    }, anim: "zombie", packTex: ["entity/zombie/drowned.png", "entity/zombie/drowned_outer_layer.png"]))
    M2("skeleton", skeletonModel({ s in
        s.box(0, 0, 8, 8, 8, 0xc8c8c0)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 2, 0x2c2c2c, 0x000000)
        s.rect(11, 14, 4, 1, 0x4a4a4a)
        s.box(16, 16, 8, 12, 4, 0xb8b8b0)
        s.fill(20, 20, 8, 8, 0x9a9a92, 0.2)   // ribs shading
        for i in 0..<3 { s.rect(20, 21 + i * 2, 8, 1, 0xc8c8c0) }
        s.box(40, 16, 2, 12, 2, 0xc8c8c0)
        s.box(0, 16, 2, 12, 2, 0xc8c8c0)
    }, packTex: ["entity/skeleton/skeleton.png"]))
    M2("stray", skeletonModel({ s in
        s.box(0, 0, 8, 8, 8, 0xb0c0c0)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 2, 0x2c2c2c, 0x000000)
        s.box(16, 16, 8, 12, 4, 0x6a8a8a)
        s.box(40, 16, 2, 12, 2, 0xb0c0c0)
        s.box(0, 16, 2, 12, 2, 0xb0c0c0)
    }, packTex: ["entity/skeleton/stray.png", "entity/skeleton/stray_overlay.png"]))
    M2("wither_skeleton", skeletonModel({ s in
        s.box(0, 0, 8, 8, 8, 0x2c2c2c)
        s.eyes(0, 0, 8, 1, 4, 5, 2, 2, 0x0a0a0a, 0x000000)
        s.box(16, 16, 8, 12, 4, 0x222222)
        s.box(40, 16, 2, 12, 2, 0x2c2c2c)
        s.box(0, 16, 2, 12, 2, 0x2c2c2c)
    }, scale: 1.2, packTex: ["entity/skeleton/wither_skeleton.png"]))

    // CREEPER
    M2("creeper", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 18, 0), box(-4, 0, -4, 8, 8, 8, 0, 0)),
            part("body", (0, 18, 0), box(-4, -12, -2, 8, 12, 4, 16, 16)),
            part("legFR", (-2, 6, -2), box(-2, -6, -4, 4, 6, 4, 0, 16)),
            part("legFL", (2, 6, -2), box(-2, -6, -4, 4, 6, 4, 0, 16)),
            part("legBR", (-2, 6, 2), box(-2, -6, 0, 4, 6, 4, 0, 16)),
            part("legBL", (2, 6, 2), box(-2, -6, 0, 4, 6, 4, 0, 16)),
        ],
        anim: "creeper", scale: 1,
        paint: { s in
            let green = 0x4eaa3c
            s.box(0, 0, 8, 8, 8, green, 0.25)
            // iconic face
            s.rect(9 + 1, 8 + 3, 2, 2, 0x0a0a0a); s.rect(9 + 5, 8 + 3, 2, 2, 0x0a0a0a)
            s.rect(9 + 3, 8 + 5, 2, 3, 0x0a0a0a)
            s.rect(9 + 2, 8 + 6, 1, 2, 0x0a0a0a); s.rect(9 + 6 - 1, 8 + 6, 1, 2, 0x0a0a0a)
            s.box(16, 16, 8, 12, 4, green, 0.25)
            s.box(0, 16, 4, 6, 4, green, 0.25)
        }, packTex: ["entity/creeper/creeper.png"]))

    // SPIDERS
    func spiderModel(_ skinC: Int, _ eyeC: Int, _ scale: Double, _ packTex: [String] = []) -> MobModel {
        var parts: [ModelPart] = [
            part("head", (0, 9, -3), box(-4, -4, -8, 8, 8, 8, 32, 4)),
            part("body", (0, 9, 9), box(-5, -4, -6, 10, 8, 12, 0, 12)),
        ]
        for i in 0..<4 {
            parts.append(part("legR\(i)", (-4, 9, Double(-4 + i * 3)), box(-14, -1, -1, 14, 2, 2, 18, 0)))
            parts.append(part("legL\(i)", (4, 9, Double(-4 + i * 3)), box(0, -1, -1, 14, 2, 2, 18, 0)))
        }
        return MobModel(
            texW: 64, texH: 32, parts: parts, anim: "spider", scale: scale,
            paint: { s in
                s.box(32, 4, 8, 8, 8, skinC, 0.2)
                s.box(0, 12, 10, 8, 12, shadeColor(skinC, 0.9), 0.2)
                s.box(18, 0, 14, 2, 2, shadeColor(skinC, 0.8), 0.15)
                // 8 eyes
                let fu = 32 + 8, fv = 4 + 8
                for (ex, ey, w2) in [(1, 2, 1), (6, 2, 1), (2, 4, 2), (5, 4, 2)] {
                    s.rect(fu + ex, fv + ey, w2, 1, eyeC)
                }
            }, packTex: packTex)
    }
    M2("spider", spiderModel(0x352a24, 0xc83a3a, 1, ["entity/spider/spider.png", "entity/spider/spider_eyes.png"]))
    M2("cave_spider", spiderModel(0x0c4c44, 0xc83a3a, 0.7, ["entity/spider/cave_spider.png", "entity/spider/spider_eyes.png"]))

    // FARM ANIMALS — pig/cow/mooshroom/sheep/chicken stay registered by
    // ensureModels() (identical pixels); rabbit/goat and everything below are new
    M2("rabbit", MobModel(
        texW: 64, texH: 32,
        parts: [
            rpart("body", (0, 5, 8), (0.349, 0, 0), box(-3, -3, -10, 6, 5, 10, 0, 0)),
            part("head", (0, 8, -1), box(-2.5, 0, -5, 5, 4, 5, 32, 0),
                 box(-2.5, 4, -1, 2, 5, 1, 52, 0), box(0.5, 4, -1, 2, 5, 1, 58, 0)),
            part("tail", (0, 4, 7), box(-1.5, -1.5, 0, 3, 3, 2, 52, 6)),
            part("legFR", (-3, 7, -1), box(-1, -7, -1, 2, 7, 2, 0, 15)),
            part("legFL", (3, 7, -1), box(-1, -7, -1, 2, 7, 2, 0, 15)),
            part("legBR", (-3, 4, 4), box(-1, -4, -2.5, 2, 4, 5, 30, 15)),
            part("legBL", (3, 4, 4), box(-1, -4, -2.5, 2, 4, 5, 30, 15)),
        ],
        anim: "rabbit", scale: 0.4,
        paint: { s in
            let fur = 0xa8845c
            s.box(0, 0, 6, 5, 10, fur, 0.12)
            s.box(32, 0, 5, 4, 5, fur, 0.12)
            s.px(37 + 1, 4 + 1, 0x1c1c1c); s.px(37 + 4, 4 + 1, 0x1c1c1c)
            s.box(52, 0, 2, 5, 1, fur, 0.12); s.box(58, 0, 2, 5, 1, fur, 0.12)
            s.box(52, 6, 3, 3, 2, 0xf0e8e0, 0.08)
            s.box(0, 15, 2, 7, 2, fur, 0.12)
            s.box(30, 15, 2, 4, 5, fur, 0.12)
        },
        packTex: ["entity/rabbit/brown.png"]))
    // vanilla GoatModel geometry (64×64, modern unrotated two-cube body)
    M2("goat", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0.5, 17, -8), box(-2.5, -2, -8, 5, 7, 10, 34, 46),
                 box(2.5, 2, -2, 3, 2, 1, 2, 61), box(-5.5, 2, -2, 3, 2, 1, 2, 61),       // ears
                 box(0, -11, -6, 0, 7, 5, 23, 52),                                         // beard
                 box(-2.49, 2, -2, 2, 7, 2, 12, 55), box(0.49, 2, -2, 2, 7, 2, 12, 55)),   // horns
            part("body", (0, 0, 0), box(-4, 6, -7, 9, 11, 16, 1, 1),
                 box(-5, 4, -8, 11, 14, 11, 0, 28)),                                       // fur
            part("legFR", (-3, 10, -6), box(0, -10, 0, 3, 10, 3, 49, 2)),
            part("legFL", (1, 10, -6), box(0, -10, 0, 3, 10, 3, 35, 2)),
            part("legBR", (-3, 10, 4), box(0, -10, 0, 3, 6, 3, 49, 29)),
            part("legBL", (1, 10, 4), box(0, -10, 0, 3, 6, 3, 36, 29)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            let c = 0xd8d0c4
            s.box(34, 46, 5, 7, 10, c, 0.1)
            s.box(2, 61, 3, 2, 1, 0xc8bcae, 0.08)                       // ears
            s.box(12, 55, 2, 7, 2, 0x9a8a72, 0.08)                      // horns
            s.box(23, 52, 0, 7, 5, 0xc8bcae, 0.08)                      // beard
            s.box(1, 1, 9, 11, 16, c, 0.1)                              // body
            s.box(0, 28, 11, 14, 11, shadeColor(c, 0.95), 0.12)         // fur
            s.box(35, 2, 3, 10, 3, 0xc8bcae, 0.1); s.box(49, 2, 3, 10, 3, 0xc8bcae, 0.1)
            s.box(36, 29, 3, 6, 3, 0xc8bcae, 0.1); s.box(49, 29, 3, 6, 3, 0xc8bcae, 0.1)
        },
        packTex: ["entity/goat/goat.png"]))

    // WOLF / CAT / FOX
    M2("wolf", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (-1, 10.5, -7), box(-2, -3, -2, 6, 6, 4, 0, 0),
                 box(-2, 3, 0, 2, 2, 1, 16, 14), box(2, 3, 0, 2, 2, 1, 16, 14),
                 box(-0.5, -3, -5, 3, 3, 4, 0, 10)),
            rpart("body", (0, 10, 2), (-Double.pi / 2, 0, 0), box(-3, -7, -3, 6, 9, 6, 18, 14)),
            rpart("mane", (-1, 10, -3), (-Double.pi / 2, 0, 0), box(-3, -3, -3, 8, 6, 7, 21, 0)),
            part("tail", (-1, 12, 8), box(-1, -8, -1, 2, 8, 2, 9, 18)),
            part("legFR", (-2.5, 8, -4), box(-1, -8, -1, 2, 8, 2, 0, 18)),
            part("legFL", (0.5, 8, -4), box(-1, -8, -1, 2, 8, 2, 0, 18)),
            part("legBR", (-2.5, 8, 7), box(-1, -8, -1, 2, 8, 2, 0, 18)),
            part("legBL", (0.5, 8, 7), box(-1, -8, -1, 2, 8, 2, 0, 18)),
        ],
        anim: "quadTail", scale: 1,
        paint: { s in
            let fur = 0xb8b4ac
            s.box(0, 0, 6, 6, 4, fur, 0.12)
            let fu = 4, fv = 4
            s.px(fu + 1, fv + 2, 0x1c1c1c); s.px(fu + 4, fv + 2, 0x1c1c1c)
            s.box(0, 10, 3, 3, 4, shadeColor(fur, 0.85), 0.1) // snout
            s.px(4 + 1, 14 + 1, 0x141414)                     // nose tip
            s.box(16, 14, 2, 2, 1, shadeColor(fur, 0.8))      // ears
            s.box(18, 14, 6, 9, 6, fur, 0.12)                 // body
            s.box(21, 0, 8, 6, 7, shadeColor(fur, 0.95), 0.12) // mane
            s.box(9, 18, 2, 8, 2, fur, 0.12)                  // tail
            s.box(0, 18, 2, 8, 2, fur, 0.12)                  // legs
        },
        packTex: ["entity/wolf/wolf.png"]))
    M2("cat", catModel(["entity/cat/tabby.png"]))
    M2("fox", MobModel(
        texW: 48, texH: 32,
        parts: [
            part("head", (-1, 7.5, -3), box(-3.5, -4, -5, 8, 6, 6, 1, 5),
                 box(-3.5, 2, -4, 2, 2, 1, 8, 1), box(1.5, 2, -4, 2, 2, 1, 15, 1),
                 box(-1.5, -2, -8, 3, 2, 3, 6, 18)),
            rpart("body", (0, 8, -6), (-Double.pi / 2, 0, 0), box(-3, -15, -3.5, 6, 11, 6, 24, 15)),
            rpart("tail", (0, 9, 8), (-0.5, 0, 0), box(-2, -9, -2.5, 4, 9, 5, 30, 0)),
            part("legFR", (-2.25, 6, -2), box(-1, -6, -1, 2, 6, 2, 13, 24)),
            part("legFL", (2.25, 6, -2), box(-1, -6, -1, 2, 6, 2, 13, 24)),
            part("legBR", (-2.25, 6, 6), box(-1, -6, -1, 2, 6, 2, 4, 24)),
            part("legBL", (2.25, 6, 6), box(-1, -6, -1, 2, 6, 2, 4, 24)),
        ],
        anim: "quadTail", scale: 0.8,
        paint: { s in
            let fur = 0xe07a2c
            s.box(1, 5, 8, 6, 6, fur, 0.12)
            let fu = 1 + 6, fv = 5 + 6
            s.px(fu + 1, fv + 1, 0x1c1c1c); s.px(fu + 6, fv + 1, 0x1c1c1c)
            s.box(8, 1, 2, 2, 1, 0x2c2424); s.box(15, 1, 2, 2, 1, 0x2c2424)
            s.box(6, 18, 3, 2, 3, 0xf8f0e8, 0.08)   // white snout
            s.box(24, 15, 6, 11, 6, fur, 0.12)
            s.box(30, 0, 4, 9, 5, fur, 0.12)
            s.fill(36, 10, 5, 4, 0xf8f0e8, 0.06)    // tail tip
            s.box(13, 24, 2, 6, 2, 0x2c2424, 0.1)
            s.box(4, 24, 2, 6, 2, 0x2c2424, 0.1)
        },
        packTex: ["entity/fox/fox.png"]))

    // HORSE FAMILY
    func horseModel(_ color: Int, _ maneC: Int, _ scale: Double = 1, _ anim: String = "horse", _ packTex: [String] = []) -> MobModel {
        MobModel(
            texW: 64, texH: 64,
            parts: [
                // vanilla head_parts group: neck + head + mouth + mane + ears,
                // pitched 30 deg forward as one unit
                rpart("head", (0, 20, -12), (-0.5236, 0, 0),
                      box(-2.05, -5, -2, 4.1, 14.8, 8, 0, 35),
                      box(-3, 6, -2, 6, 5, 7, 0, 13),
                      box(-2, 6, -7, 4, 5, 5, 0, 25),
                      box(-1, -5, 5.01, 2, 16, 2, 56, 36),
                      box(0.55, 10, 4, 2, 3, 1, 19, 16),
                      box(-2.55, 10, 4, 2, 3, 1, 29, 16)),
                part("body", (0, 13, 5), box(-5, -2, -19, 10, 10, 22, 0, 32)),
                rpart("tail", (0, 19, 9), (-0.5, 0, 0), box(-1.5, -14, 0, 3, 14, 4, 42, 36)),
                part("legFR", (-4, 11, -8), box(-2, -11, -2, 4, 11, 4, 48, 21)),
                part("legFL", (4, 11, -8), box(-2, -11, -2, 4, 11, 4, 48, 21)),
                part("legBR", (-4, 11, 9), box(-2, -11, -2, 4, 11, 4, 48, 21)),
                part("legBL", (4, 11, 9), box(-2, -11, -2, 4, 11, 4, 48, 21)),
            ],
            anim: anim, scale: scale,
            paint: { s in
                s.box(0, 35, 4, 15, 8, color, 0.1)   // neck
                s.box(0, 13, 6, 5, 7, color, 0.1)   // head
                s.px(2, 20, 0x1c1c1c); s.px(17, 20, 0x1c1c1c)
                s.box(0, 25, 4, 5, 5, color, 0.1)   // mouth
                s.box(56, 36, 2, 16, 2, maneC, 0.12)
                s.box(19, 16, 2, 3, 1, shadeColor(color, 0.85))
                s.box(29, 16, 2, 3, 1, shadeColor(color, 0.85))
                s.box(0, 32, 10, 10, 22, color, 0.1)
                s.box(42, 36, 3, 14, 4, maneC, 0.12)
                s.box(48, 21, 4, 11, 4, color, 0.1)
            }, packTex: packTex)
    }
    M2("horse", horseModel(0x8a5c34, 0x3c2c1c, 1, "horse", ["entity/horse/horse_brown.png"]))
    M2("donkey", horseModel(0x8a7a6a, 0x5a4c40, 0.9, "horse", ["entity/horse/donkey.png"]))
    M2("mule", horseModel(0x6a4a32, 0x3a2a1c, 0.95, "horse", ["entity/horse/mule.png"]))
    M2("skeleton_horse", horseModel(0xc8c8c0, 0xb0b0a8, 1, "horse", ["entity/horse/horse_skeleton.png"]))
    // vanilla LlamaModel geometry (128×64) — the old 64-wide layout's body
    // unwrap overflowed the texture and rendered hollow from one side
    M2("llama", MobModel(
        texW: 128, texH: 64,
        parts: [
            part("head", (0, 17, -6),
                 box(-2, 10, -10, 4, 4, 9, 0, 0),                         // muzzle
                 box(-4, -2, -6, 8, 18, 6, 0, 14),                        // neck + head
                 box(-4, 16, -4, 3, 3, 2, 17, 0), box(1, 16, -4, 3, 3, 2, 17, 0)), // ears
            rpart("body", (0, 19, 2), (-Double.pi / 2, 0, 0),
                  box(-6, -8, -7, 12, 18, 10, 29, 0)),
            part("legFR", (-3.5, 14, -5), box(-2, -14, -2, 4, 14, 4, 29, 29)),
            part("legFL", (3.5, 14, -5), box(-2, -14, -2, 4, 14, 4, 29, 29)),
            part("legBR", (-3.5, 14, 6), box(-2, -14, -2, 4, 14, 4, 29, 29)),
            part("legBL", (3.5, 14, 6), box(-2, -14, -2, 4, 14, 4, 29, 29)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            let wool = 0xd8c8a8
            s.box(0, 0, 4, 4, 9, shadeColor(wool, 0.95), 0.1)             // muzzle
            s.box(0, 14, 8, 18, 6, wool, 0.1)                             // neck
            s.box(17, 0, 3, 3, 2, shadeColor(wool, 0.9), 0.08)            // ears
            s.box(29, 0, 12, 18, 10, wool, 0.1)                           // body
            s.box(29, 29, 4, 14, 4, shadeColor(wool, 0.92), 0.1)          // legs
        },
        packTex: ["entity/llama/creamy.png"]))
    // vanilla CamelModel geometry (128×128) — modern unrotated rig
    M2("camel", MobModel(
        texW: 128, texH: 128,
        parts: [
            part("body", (0.5, 20, 9.5), box(-8, 0, -23.5, 15, 12, 27, 0, 25)),
            part("hump", (0.5, 32, 0), box(-5, 0, -6, 9, 5, 11, 74, 0)),
            part("tail", (0, 29, 13), box(-1.5, -14, 0, 3, 14, 0, 122, 0)),
            part("head", (0.5, 25, -10),
                 box(-4, -3, -15, 7, 8, 19, 60, 24),                      // snout/head
                 box(-4, 5, -15, 7, 14, 7, 21, 0),                        // neck
                 box(-3, 14, -21, 5, 5, 6, 50, 0),                        // crown
                 box(2.5, 17.5, -10.5, 3, 1, 2, 45, 0),                   // left ear
                 box(-6.5, 17.5, -10.5, 3, 1, 2, 67, 0)),                 // right ear
            part("legFR", (-4.9, 23, -10.5), box(-2.5, -23, -2.5, 5, 21, 5, 0, 26)),
            part("legFL", (4.9, 23, -10.5), box(-2.5, -23, -2.5, 5, 21, 5, 0, 0)),
            part("legBR", (-4.9, 23, 9.5), box(-2.5, -23, -2.5, 5, 21, 5, 94, 16)),
            part("legBL", (4.9, 23, 9.5), box(-2.5, -23, -2.5, 5, 21, 5, 58, 16)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            let c = 0xd8a868
            s.box(0, 25, 15, 12, 27, c, 0.1)                              // body
            s.box(74, 0, 9, 5, 11, shadeColor(c, 0.9), 0.1)               // hump
            s.box(60, 24, 7, 8, 19, c, 0.1)                               // head
            s.box(21, 0, 7, 14, 7, shadeColor(c, 0.95), 0.1)              // neck
            s.box(50, 0, 5, 5, 6, shadeColor(c, 0.95), 0.1)               // crown
            s.box(45, 0, 3, 1, 2, shadeColor(c, 0.9))                     // ears
            s.box(0, 0, 5, 21, 5, shadeColor(c, 0.92), 0.1)               // legs
            s.box(0, 26, 5, 21, 5, shadeColor(c, 0.92), 0.1)
            s.box(58, 16, 5, 21, 5, shadeColor(c, 0.92), 0.1)
            s.box(94, 16, 5, 21, 5, shadeColor(c, 0.92), 0.1)
        },
        packTex: ["entity/camel/camel.png"]))

    registerModels2()
}

func catModel(_ packTex: [String]) -> MobModel {
    MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 9, -9), box(-2.5, -2, -3, 5, 4, 5, 0, 0),
                 box(-1.5, -2, -4, 3, 2, 2, 0, 24),
                 box(-2, 2, -1, 1, 1, 2, 0, 10), box(1, 2, -1, 1, 1, 2, 0, 10)),
            rpart("body", (0, 12, -10), (-Double.pi / 2, 0, 0), box(-2, -19, -8, 4, 16, 6, 20, 0)),
            part("tail", (0, 9, 8), box(-0.5, -8, -0.5, 1, 8, 1, 0, 15)),
            part("legFR", (-1.2, 10, -5), box(-1, -10, -1, 2, 10, 2, 40, 0)),
            part("legFL", (1.2, 10, -5), box(-1, -10, -1, 2, 10, 2, 40, 0)),
            part("legBR", (-1.1, 6, 5), box(-1, -6, -1, 2, 6, 2, 8, 13)),
            part("legBL", (1.1, 6, 5), box(-1, -6, -1, 2, 6, 2, 8, 13)),
        ],
        anim: "quadTail", scale: 1, paint: catPaint, packTex: packTex)
}

private func catPaint(_ s: EntitySkin) {
    let fur = 0xc89858
    s.box(0, 0, 5, 4, 5, fur, 0.14)
    let fu = 5, fv = 5
    s.px(fu + 0, fv + 0, 0x4ae04a); s.px(fu + 4, fv + 0, 0x4ae04a)
    s.box(0, 24, 3, 2, 2, shadeColor(fur, 0.9), 0.1)   // muzzle
    s.box(0, 10, 1, 1, 2, shadeColor(fur, 0.9))        // ears
    s.box(20, 0, 4, 16, 6, fur, 0.14)                  // body
    s.box(0, 15, 1, 8, 1, shadeColor(fur, 0.85), 0.1)  // tail
    s.box(40, 0, 2, 10, 2, fur, 0.14)                  // front legs
    s.box(8, 13, 2, 6, 2, fur, 0.14)                   // back legs
}

/// quadModel with the the frozen baseline option set (same math as EntityModels.quadModel)
func quadModel2(
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
        anim: anim, scale: scale, paint: paint)
}

// ===========================================================================
// the frozen baseline: nether, end, water, bosses, ambient mobs
// ===========================================================================
private func registerModels2() {
    // ENDERMAN
    M2("enderman", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("head", (0, 38, 0), box(-4, 0, -4, 8, 8, 8, 0, 0)),
            part("body", (0, 38, 0), box(-4, -12, -2, 8, 12, 4, 32, 16)),
            part("armR", (-5, 36, 0), box(-1, -28, -1, 2, 28, 2, 56, 0)),
            part("armL", (5, 36, 0), box(-1, -28, -1, 2, 28, 2, 56, 0)),
            part("legR", (-2, 26, 0), box(-1, -26, -1, 2, 26, 2, 56, 0)),
            part("legL", (2, 26, 0), box(-1, -26, -1, 2, 26, 2, 56, 0)),
        ],
        anim: "biped", scale: 1,
        paint: { s in
            s.box(0, 0, 8, 8, 8, 0x161616, 0.18)
            // glowing magenta eyes
            s.rect(8 + 1, 8 + 4, 2, 1, 0xe879e8); s.rect(8 + 5, 8 + 4, 2, 1, 0xe879e8)
            s.px(8 + 2, 8 + 4, 0xc83cc8); s.px(8 + 6, 8 + 4, 0xc83cc8)
            s.box(32, 16, 8, 12, 4, 0x101010, 0.15)
            s.box(56, 0, 2, 28, 2, 0x101010, 0.15)
        }, packTex: ["entity/enderman/enderman.png", "entity/enderman/enderman_eyes.png"]))
    M2("endermite", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("body", (0, 2, 0), box(-2, 0, -3, 4, 3, 2, 0, 0), box(-1.5, 0, -1, 3, 4, 4, 0, 5), box(-1, 0, 3, 2, 3, 2, 0, 14)),
        ],
        anim: "silverfish", scale: 1,
        paint: { s in
            s.box(0, 0, 4, 3, 2, 0x6a4a8a, 0.2)
            s.box(0, 5, 3, 4, 4, 0x5a3a7a, 0.2)
            s.box(0, 14, 2, 3, 2, 0x4a306a, 0.2)
        }, packTex: ["entity/endermite.png"]))
    M2("silverfish", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("body", (0, 2, 0), box(-1.5, 0, -4, 3, 2, 2, 0, 0), box(-2, 0, -2, 4, 3, 3, 0, 5), box(-1.5, 0, 1, 3, 2, 4, 0, 12), box(-1, 0, 5, 2, 1, 2, 0, 19)),
        ],
        anim: "silverfish", scale: 1,
        paint: { s in
            s.box(0, 0, 3, 2, 2, 0x9a9aa2, 0.15)
            s.box(0, 5, 4, 3, 3, 0x8a8a92, 0.15)
            s.box(0, 12, 3, 2, 4, 0x9a9aa2, 0.15)
            s.box(0, 19, 2, 1, 2, 0x7a7a82, 0.15)
        }, packTex: ["entity/silverfish.png"]))
    M2("shulker", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("lid", (0, 0, 0), box(-8, 4, -8, 16, 12, 16, 0, 0)),
            part("base", (0, 0, 0), box(-8, 0, -8, 16, 8, 16, 0, 28)),
            part("head", (0, 6, 0), box(-3, 0, -3, 6, 6, 6, 0, 52)),
        ],
        anim: "shulker", scale: 1,
        paint: { s in
            s.box(0, 0, 16, 12, 16, 0x976797, 0.1)
            s.box(0, 28, 16, 8, 16, 0x8a5c8a, 0.1)
            s.box(0, 52, 6, 6, 6, 0xb8a0b8, 0.1)
            s.px(16 + 1, 52 + 6 + 2, 0x1c1c1c); s.px(16 + 4, 52 + 6 + 2, 0x1c1c1c)
        }, packTex: ["entity/shulker/shulker.png"]))
    // vanilla vex/allay rigs (32×32) — two-cube body, thin arms, wing planes
    func flyBiped(_ name: String, _ armW: Double, _ wingBox: ModelBox, _ armRUV: Double, _ armLUV: Double,
                  _ scale: Double, _ packTex: [String], _ paint: @escaping (EntitySkin) -> Void) {
        M2(name, MobModel(
            texW: 32, texH: 32,
            parts: [
                part("head", (0, 20, 0), box(-2.5, 0, -2.5, 5, 5, 5, 0, 0)),
                part("body", (0, 20, 0), box(-1.5, -4, -1, 3, 4, 2, 0, 10),
                     box(-1.5, -6, -1, 3, 5, 2, 0, 16)),
                part("armR", (-1.75, 19.75, 0), box(-armW + 0.75, -3.5, -1, armW, 4, 2, armRUV, 0)),
                part("armL", (1.75, 19.75, 0), box(-0.75, -3.5, -1, armW, 4, 2, armLUV, 6)),
                part("wingR", (-0.5, 19, 1), wingBox),
                part("wingL", (0.5, 19, 1), wingBox),
            ],
            anim: "fly_biped", scale: scale, paint: paint, packTex: packTex))
    }
    flyBiped("vex", 2, box(-8, -5, 0, 8, 5, 0, 16, 22), 23, 23, 0.5, ["entity/illager/vex.png"]) { s in
        s.box(0, 0, 5, 5, 5, 0x8a9ab8, 0.12)
        s.px(5 + 1, 5 + 2, 0x2c3c5c); s.px(5 + 3, 5 + 2, 0x2c3c5c)
        s.box(0, 10, 3, 4, 2, 0x7a8aa8, 0.12)
        s.box(0, 16, 3, 5, 2, 0x7a8aa8, 0.12)
        s.box(23, 0, 2, 4, 2, 0x7a8aa8, 0.12)
        s.fill(16, 22, 8, 5, 0xb8c8d8, 0.1)
    }
    flyBiped("allay", 1, box(0, -5, 0, 0, 5, 8, 16, 14), 23, 23, 0.45, ["entity/allay/allay.png"]) { s in
        s.box(0, 0, 5, 5, 5, 0x4ab8d8, 0.1)
        s.px(5 + 1, 5 + 2, 0x1c3c4c); s.px(5 + 3, 5 + 2, 0x1c3c4c)
        s.box(0, 10, 3, 4, 2, 0x3ca8c8, 0.1)
        s.box(0, 16, 3, 5, 2, 0x3ca8c8, 0.1)
        s.box(23, 0, 1, 4, 2, 0x3ca8c8, 0.1)
        s.fill(16, 14, 8, 5, 0xc8e8f0, 0.08)
    }

    // ILLAGERS
    func illagerModel(_ robe: Int, _ skinTone: Int = 0x9a9a8a, _ packTex: [String] = []) -> MobModel {
        MobModel(
            texW: 64, texH: 64,
            parts: [
                part("head", (0, 24, 0), box(-4, 0, -4, 8, 10, 8, 0, 0), box(-1, 0, -6, 2, 4, 2, 24, 0)),
                part("body", (0, 24, 0), box(-4, -12, -3, 8, 12, 6, 16, 20)),
                part("armR", (-5, 22, 0), box(-3, -10, -2, 4, 12, 4, 40, 46)),
                part("armL", (5, 22, 0), box(-1, -10, -2, 4, 12, 4, 40, 46)),
                part("legR", (-2, 12, 0), box(-2, -12, -2, 4, 12, 4, 0, 22)),
                part("legL", (2, 12, 0), box(-2, -12, -2, 4, 12, 4, 0, 22)),
            ],
            anim: "illager", scale: 1,
            paint: { s in
                s.box(0, 0, 8, 10, 8, skinTone, 0.1)
                s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xffffff, 0x3c5a3c)
                s.fill(8, 8, 8, 2, 0x2c2c2c, 0.1)
                s.box(24, 0, 2, 4, 2, shadeColor(skinTone, 0.9))
                s.box(16, 20, 8, 12, 6, robe, 0.1)
                s.box(40, 46, 4, 12, 4, robe, 0.1)
                s.box(0, 22, 4, 12, 4, 0x3c3c44, 0.1)
            }, packTex: packTex)
    }
    M2("pillager", illagerModel(0x4c4438, 0x9a9a8a, ["entity/illager/pillager.png"]))
    M2("vindicator", illagerModel(0x3c4448, 0x9a9a8a, ["entity/illager/vindicator.png"]))
    M2("evoker", illagerModel(0x3a3a44, 0xb8b8a8, ["entity/illager/evoker.png"]))
    // vanilla ravager rig (128×128) — rotated two-cube body, mouth, neck, horns
    M2("ravager", MobModel(
        texW: 128, texH: 128,
        parts: [
            part("head", (0, 28, -10), box(-8, -14, -14, 16, 20, 16, 0, 0),
                 box(-2, -16, -18, 4, 8, 4, 0, 0)),
            part("mouth", (0, 15, -10), box(-8, -2, -14, 16, 3, 16, 0, 36)),
            part("neck", (0, 20, -20), box(-5, 1, 10, 10, 10, 18, 68, 73)),
            rpart("horns", (-5, 27, -19), (-1.0472, 0, 0),
                  box(-5, 0, -1, 2, 14, 4, 74, 55), box(13, 0, -1, 2, 14, 4, 74, 55)),
            rpart("body", (0, 19, 2), (-Double.pi / 2, 0, 0),
                  box(-7, -9, -4, 14, 16, 20, 0, 55), box(-6, -22, -4, 12, 13, 18, 0, 91)),
            part("legFR", (-8, 26, -4), box(-4, -26, -4, 8, 37, 8, 64, 0)),
            part("legFL", (8, 26, -4), box(-4, -26, -4, 8, 37, 8, 64, 0)),
            part("legBR", (-8, 30, 21), box(-4, -30, -4, 8, 37, 8, 96, 0)),
            part("legBL", (8, 30, 21), box(-4, -30, -4, 8, 37, 8, 96, 0)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            let c = 0x5c5c64
            s.box(0, 0, 16, 20, 16, c, 0.12)
            s.box(0, 36, 16, 3, 16, shadeColor(c, 0.8), 0.12)
            s.box(68, 73, 10, 10, 18, shadeColor(c, 0.95), 0.12)
            s.box(74, 55, 2, 14, 4, 0x8a8a82, 0.1)
            s.box(0, 55, 14, 16, 20, shadeColor(c, 0.92), 0.12)
            s.box(0, 91, 12, 13, 18, shadeColor(c, 0.92), 0.12)
            s.box(64, 0, 8, 37, 8, shadeColor(c, 0.85), 0.12)
            s.box(96, 0, 8, 37, 8, shadeColor(c, 0.85), 0.12)
        },
        packTex: ["entity/illager/ravager.png"]))
    M2("witch", {
        let base = illagerModel(0x2c2438, 0xb89a8a)
        var parts = base.parts
        parts.append(ModelPart(name: "hat", pivot: (0, 34, 0), boxes: [
            box(-5, 0, -5, 10, 2, 10, 0, 64), box(-3.5, 2, -3, 7, 4, 7, 0, 76),
            box(-2, 6, -1.5, 4, 4, 4, 0, 87), box(-0.5, 10, 0, 1, 2, 1, 0, 95),
        ]))
        return MobModel(texW: 64, texH: 128, parts: parts, anim: "illager", scale: 1,
                        paint: { s in
                            s.box(0, 0, 8, 10, 8, 0xb89a8a, 0.1)
                            s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0xffffff, 0x3c5a3c)
                            s.box(24, 0, 2, 4, 2, shadeColor(0xb89a8a, 0.9))
                            s.box(16, 20, 8, 12, 6, 0x2c2438, 0.1)
                            s.box(40, 46, 4, 12, 4, 0x2c2438, 0.1)
                            s.box(0, 22, 4, 12, 4, 0x3c3c44, 0.1)
                            s.box(0, 64, 10, 2, 10, 0x1c1428, 0.1)
                            s.box(0, 76, 7, 4, 7, 0x241a30, 0.1)
                            s.box(0, 87, 4, 4, 4, 0x1c1428, 0.1)
                            s.box(0, 95, 1, 2, 1, 0x2c2438, 0.1)
                        }, packTex: ["entity/witch.png"])
    }())

    // GOLEMS
    M2("iron_golem", MobModel(
        texW: 128, texH: 128,
        parts: [
            part("head", (0, 31, -2), box(-4, 2, -5.5, 8, 10, 8, 0, 0), box(-1, 1, -7.5, 2, 4, 2, 24, 0)),
            part("body", (0, 31, 0), box(-9, -10, -6, 18, 12, 11, 0, 40), box(-4.5, -15, -3, 9, 5, 6, 0, 70, 0.5)),
            part("armR", (0, 31, 0), box(-13, -25.5, -3, 4, 30, 6, 60, 21)),
            part("armL", (0, 31, 0), box(9, -25.5, -3, 4, 30, 6, 60, 58)),
            part("legR", (-4, 13, 0), box(-3.5, -13, -3, 6, 16, 5, 37, 0)),
            part("legL", (4, 13, 0), box(-2.5, -13, -3, 6, 16, 5, 60, 0)),
        ],
        anim: "biped", scale: 1,
        paint: { s in
            let iron = 0xc8beb0
            s.box(0, 0, 8, 10, 8, iron, 0.08)
            s.eyes(0, 0, 8, 1, 4, 4, 2, 1, 0x8a2c2c, 0x5a1c1c)
            s.box(24, 0, 2, 4, 2, 0x9a9088, 0.06)             // nose
            s.box(0, 40, 18, 12, 11, iron, 0.08)              // torso
            s.box(0, 70, 9, 5, 6, shadeColor(iron, 0.95), 0.08) // belly
            s.rect(13, 53, 6, 2, 0x4a7a3c); s.rect(20, 57, 4, 1, 0x4a7a3c) // vines
            s.box(60, 21, 4, 30, 6, shadeColor(iron, 0.95), 0.08)
            s.box(60, 58, 4, 30, 6, shadeColor(iron, 0.95), 0.08)
            s.box(37, 0, 6, 16, 5, shadeColor(iron, 0.92), 0.08)
            s.box(60, 0, 6, 16, 5, shadeColor(iron, 0.92), 0.08)
        },
        packTex: ["entity/iron_golem/iron_golem.png"]))
    M2("snow_golem", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 24, 0), box(-4, -4, -4, 8, 8, 8, 0, 0)),
            part("body", (0, 16, 0), box(-5, -5, -5, 10, 10, 10, 0, 16)),
            part("base", (0, 6, 0), box(-6, -6, -6, 12, 12, 12, 0, 36)),
            part("armR", (-6, 19, 0), box(-12, -1, -1, 12, 2, 2, 32, 0)),
            part("armL", (6, 19, 0), box(0, -1, -1, 12, 2, 2, 32, 0)),
        ],
        anim: "snowman", scale: 1,
        paint: { s in
            s.box(0, 0, 8, 8, 8, 0xe8f0f0, 0.05)
            s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0x2c2c2c, 0x000000)
            s.rect(8 + 3, 8 + 4, 2, 1, 0xe07a2c) // carrot nose
            s.box(0, 16, 10, 10, 10, 0xf0f6f6, 0.05)
            s.box(0, 36, 12, 12, 12, 0xe8f0f0, 0.05)
            s.box(32, 0, 12, 2, 2, 0x8a6a3c, 0.15)
        }, packTex: ["entity/snow_golem.png"]))

    // NETHER MOBS
    // vanilla piglin rig (64×64): 10-wide head + snout + tilted ears + a
    // grow-0.25 clothing layer; 1.20 zombified piglins use the same rig
    func piglinModel(_ packTex: [String], _ skin: Int, _ cloth: Int) -> MobModel {
        MobModel(
            texW: 64, texH: 64,
            parts: [
                part("head", (0, 24, 0), box(-5, 0, -4, 10, 8, 8, 0, 0),
                     box(-2, 0, -5, 4, 4, 1, 31, 1),                                   // snout
                     box(2, 0, -5, 1, 2, 1, 2, 4), box(-3, 0, -5, 1, 2, 1, 2, 0)),     // nostrils
                rpart("earL", (5, 30, 0), (0, 0, 0.5236), box(-1, -5, -2, 1, 5, 4, 51, 6)),
                rpart("earR", (-5, 30, 0), (0, 0, -0.5236), box(0, -5, -2, 1, 5, 4, 39, 6)),
                part("body", (0, 24, 0), box(-4, -12, -2, 8, 12, 4, 16, 16),
                     box(-4, -12, -2, 8, 12, 4, 16, 32, 0.25)),
                part("armR", (-5, 22, 0), box(-3, -10, -2, 4, 12, 4, 40, 16),
                     box(-3, -10, -2, 4, 12, 4, 40, 32, 0.25)),
                part("armL", (5, 22, 0), box(-1, -10, -2, 4, 12, 4, 32, 48),
                     box(-1, -10, -2, 4, 12, 4, 48, 48, 0.25)),
                part("legR", (-1.9, 12, 0), box(-2.1, -12, -2, 4, 12, 4, 0, 16),
                     box(-2.1, -12, -2, 4, 12, 4, 0, 32, 0.25)),
                part("legL", (1.9, 12, 0), box(-1.9, -12, -2, 4, 12, 4, 16, 48),
                     box(-1.9, -12, -2, 4, 12, 4, 0, 48, 0.25)),
            ],
            anim: "zombie", scale: 1,
            paint: { s in
                s.box(0, 0, 10, 8, 8, skin)
                s.box(31, 1, 4, 4, 1, shadeColor(skin, 0.9))
                s.box(51, 6, 1, 5, 4, shadeColor(skin, 0.92)); s.box(39, 6, 1, 5, 4, shadeColor(skin, 0.92))
                s.box(16, 16, 8, 12, 4, cloth)
                s.box(40, 16, 4, 12, 4, skin); s.box(32, 48, 4, 12, 4, skin)
                s.box(0, 16, 4, 12, 4, shadeColor(cloth, 0.85)); s.box(16, 48, 4, 12, 4, shadeColor(cloth, 0.85))
            },
            packTex: packTex)
    }
    M2("piglin", piglinModel(["entity/piglin/piglin.png"], 0xe8a4a4, 0x5a4a3a))
    M2("piglin_brute", piglinModel(["entity/piglin/piglin_brute.png"], 0xe8a4a4, 0x3a3026))
    M2("zombified_piglin", piglinModel(["entity/piglin/zombified_piglin.png"], 0xd89494, 0x8a5c4c))
    // vanilla hoglin rig (128×64) — tusked head pitched 50°, maned body
    let hoglinModel = MobModel(
        texW: 128, texH: 64,
        parts: [
            rpart("head", (0, 22, -5), (-0.8727, 0, 0),
                  box(-7, -1, -19, 14, 6, 19, 61, 1),
                  box(-8, 0, -14, 2, 11, 2, 1, 13), box(6, 0, -14, 2, 11, 2, 1, 13)), // tusks
            part("body", (0, 19, -3), box(-8, -8, -4, 16, 14, 26, 1, 1),
                 box(0, 3, -7, 0, 10, 19, 90, 33)),                                    // mane
            part("earR", (-7, 27, -7), box(-6, -1, -3, 6, 1, 4, 1, 1)),
            part("earL", (7, 27, -7), box(0, -1, -3, 6, 1, 4, 1, 6)),
            part("legFR", (-5, 12, -3), box(-3, -12, -3, 6, 14, 6, 66, 42)),
            part("legFL", (5, 12, -3), box(-3, -12, -3, 6, 14, 6, 41, 42)),
            part("legBR", (-5.5, 8, 15.5), box(-2.5, -8, -2.5, 5, 11, 5, 21, 45)),
            part("legBL", (5.5, 8, 15.5), box(-2.5, -8, -2.5, 5, 11, 5, 0, 45)),
        ],
        anim: "quad", scale: 1,
        paint: hoglinPaint, packTex: ["entity/hoglin/hoglin.png"])
    M2("hoglin", hoglinModel)

    M2("blaze", MobModel(
        texW: 64, texH: 32,
        parts: {
            var parts: [ModelPart] = [part("head", (0, 12, 0), box(-4, 0, -4, 8, 8, 8, 0, 0))]
            for i in 0..<12 {
                parts.append(part("rod\(i)", (0, 11, 0), box(-1, -10, -1, 2, 8, 2, 0, 16)))
            }
            return parts
        }(),
        anim: "blaze", scale: 1,
        paint: { s in
            s.box(0, 0, 8, 8, 8, 0xd8a02c, 0.18)
            s.eyes(0, 0, 8, 1, 4, 5, 2, 1, 0x2c1c08, 0x000000)
            s.box(0, 16, 2, 8, 2, 0xe8c23c, 0.2)
        }, packTex: ["entity/blaze.png"]))
    M2("ghast", MobModel(
        texW: 64, texH: 32,
        parts: {
            // sized for render scale 4.5: body fills the 4-block hitbox from the feet
            var parts: [ModelPart] = [part("body", (0, 0, 0), box(-8, 0, -8, 16, 16, 16, 0, 0))]
            for i in 0..<9 {
                let x = Double((i % 3) - 1) * 5
                let z = Double((i / 3) - 1) * 5
                parts.append(part("tent\(i)", (x, 1, z), box(-1, -9, -1, 2, 9, 2, 0, 0)))
            }
            return parts
        }(),
        anim: "ghast", scale: 4.5,
        paint: { s in
            s.box(0, 0, 16, 16, 16, 0xe8e8e8, 0.06)
            // closed eyes + mouth on front
            s.rect(16 + 3, 16 + 5, 2, 2, 0x3c3c3c); s.rect(16 + 11, 16 + 5, 2, 2, 0x3c3c3c)
            s.rect(16 + 6, 16 + 9, 4, 2, 0x3c3c3c)
        }, packTex: ["entity/ghast/ghast.png"]))
    // vanilla magma cube rig (64×32) — eight 1-tall slices + molten core
    M2("magma_cube", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("body", (0, 0, 0),
                 box(-4, 7, -4, 8, 1, 8, 0, 0), box(-4, 6, -4, 8, 1, 8, 0, 1),
                 box(-4, 5, -4, 8, 1, 8, 24, 10), box(-4, 4, -4, 8, 1, 8, 24, 19),
                 box(-4, 3, -4, 8, 1, 8, 0, 4), box(-4, 2, -4, 8, 1, 8, 0, 5),
                 box(-4, 1, -4, 8, 1, 8, 0, 6), box(-4, 0, -4, 8, 1, 8, 0, 7),
                 box(-2, 2, -2, 4, 4, 4, 0, 16)),                          // core
        ],
        anim: "slime", scale: 1,
        paint: { s in
            s.fill(0, 0, 40, 16, 0x3c1e12, 0.2)
            s.fill(24, 10, 32, 18, 0x3c1e12, 0.2)
            for row in [1, 5, 7] {
                for x in 0..<32 where s.rand(x, row) < 0.6 { s.px(x, row, 0xe8521a) }
            }
            s.fill(4, 16, 16, 8, 0xff7b1d, 0.25)
        },
        packTex: ["entity/slime/magmacube.png"]))
    M2("slime", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("body", (0, 0, 0), box(-3, 1, -3, 6, 6, 6, 0, 16),
                 box(-3.3, 3.5, -3.5, 2, 2, 2, 32, 0), box(1.3, 3.5, -3.5, 2, 2, 2, 32, 4),
                 box(0, 1, -3.5, 1, 1, 1, 32, 8)),
            part("gel", (0, 0, 0), box(-4, 0, -4, 8, 8, 8, 0, 0)),
        ],
        anim: "slime", scale: 1,
        paint: { s in
            s.box(0, 16, 6, 6, 6, 0x4a9a3c, 0.08)
            s.box(32, 0, 2, 2, 2, 0x1c1c1c); s.box(32, 4, 2, 2, 2, 0x1c1c1c)
            s.box(32, 8, 1, 1, 1, 0x1c1c1c)
            s.boxA(0, 0, 8, 8, 8, 0x6fc05c, 140, 0.08)
        }, packTex: ["entity/slime/slime.png"]))
    // vanilla strider rig (64×128) — body + six side bristle planes
    M2("strider", MobModel(
        texW: 64, texH: 128,
        parts: [
            part("body", (0, 16, 0), box(-8, -2, -8, 16, 14, 16, 0, 0),
                 box(8, 3, -8, 12, 0, 16, 16, 65), box(8, 8, -8, 12, 0, 16, 16, 49),
                 box(8, 12, -8, 12, 0, 16, 16, 33),
                 box(-20, 12, -8, 12, 0, 16, 16, 33), box(-20, 8, -8, 12, 0, 16, 16, 49),
                 box(-20, 3, -8, 12, 0, 16, 16, 65)),
            part("legR", (-4, 16, 0), box(-2, -16, -2, 4, 16, 4, 0, 32)),
            part("legL", (4, 16, 0), box(-2, -16, -2, 4, 16, 4, 0, 55)),
        ],
        anim: "strider", scale: 1,
        paint: { s in
            let c = 0xb83a3a
            s.box(0, 0, 16, 14, 16, c, 0.14)
            s.rect(16 + 3, 16 + 3, 2, 3, 0x2c1414); s.rect(16 + 11, 16 + 3, 2, 3, 0x2c1414)
            s.box(0, 32, 4, 16, 4, shadeColor(c, 0.85), 0.12)
            s.box(0, 55, 4, 16, 4, shadeColor(c, 0.85), 0.12)
            s.fill(32, 33, 12, 16, shadeColor(c, 0.9), 0.14)
            s.fill(32, 49, 12, 16, shadeColor(c, 0.9), 0.14)
            s.fill(32, 65, 12, 16, shadeColor(c, 0.9), 0.14)
        },
        packTex: ["entity/strider/strider.png"]))

    // WATER MOBS
    M2("squid", MobModel(
        texW: 64, texH: 32, parts: squidParts(), anim: "squid", scale: 1,
        paint: { s in
            s.box(0, 0, 12, 16, 12, 0x4a5a8a, 0.12)
            s.rect(12 + 2, 12 + 5, 2, 2, 0xd8d8e8); s.rect(12 + 8, 12 + 5, 2, 2, 0xd8d8e8)
            s.box(48, 0, 2, 18, 2, 0x44537e, 0.12)
        }, packTex: ["entity/squid/squid.png"]))
    M2("glow_squid", MobModel(
        texW: 64, texH: 32, parts: squidParts(), anim: "squid", scale: 1,
        paint: { s in
            s.box(0, 0, 12, 16, 12, 0x2c8a8a, 0.12)
            for i in 0..<18 { s.px(Int(s.rand(i, 0) * 48), Int(s.rand(i, 1) * 24), 0x6ae8d8) }
            s.rect(12 + 2, 12 + 5, 2, 2, 0xc8fff0); s.rect(12 + 8, 12 + 5, 2, 2, 0xc8fff0)
            s.box(48, 0, 2, 18, 2, 0x257575, 0.12)
        }, packTex: ["entity/squid/glow_squid.png"]))
    func fishModel(_ paint: @escaping (EntitySkin) -> Void, _ scale: Double = 1) -> MobModel {
        MobModel(
            texW: 32, texH: 32,
            parts: [
                part("body", (0, 2, 0), box(-1, 0, -3, 2, 3, 6, 0, 0)),
                part("tail", (0, 2, 3), box(0, 0, 0, 0.01, 3, 3, 14, 0), box(-0.5, 1, 0, 1, 1, 2, 14, 8)),
                part("finTop", (0, 5, 0), box(0, 0, -1, 0.01, 2, 3, 20, 0)),
            ],
            anim: "fish", scale: scale, paint: paint)
    }
    M2("cod", MobModel(
        texW: 32, texH: 32,
        parts: [
            part("body", (0, 1, 0), box(-1, 0, -3, 2, 4, 7, 0, 0)),
            part("head", (0, 1, -3), box(-1, 0, -3, 2, 4, 3, 11, 0), box(-1, 1, -4, 2, 3, 1, 0, 0)),
            part("tail", (0, 1, 4), box(0, 0, 0, 0.01, 4, 6, 20, 1)),
            part("finTop", (0, 5, -1), box(0, 0, 0, 0.01, 1, 4, 20, 10)),
        ],
        anim: "fish", scale: 1,
        paint: { s in
            let c = 0x8a7a5c
            s.box(0, 0, 2, 4, 7, c, 0.12)
            s.box(11, 0, 2, 4, 3, shadeColor(c, 0.95), 0.12)
            s.px(12, 2, 0x1c1c1c)
            s.fill(20, 1, 7, 5, shadeColor(c, 0.9), 0.1)
            s.fill(20, 10, 5, 2, shadeColor(c, 0.9), 0.1)
        },
        packTex: ["entity/fish/cod.png"]))
    M2("salmon", MobModel(
        texW: 32, texH: 32,
        parts: [
            part("body", (0, 1, -4), box(-1, 0, 0, 2, 4, 7, 0, 0)),
            part("tail", (0, 1, 3), box(-1, 0, 0, 2, 4, 6, 0, 13), box(0, 0, 6, 0.01, 4, 5, 20, 10)),
            part("finTop", (0, 5, -1), box(0, 0, 0, 0.01, 2, 4, 2, 1)),
        ],
        anim: "fish", scale: 1,
        paint: { s in
            let c = 0xa84a3a
            s.box(0, 0, 2, 4, 7, c, 0.12)
            s.box(0, 13, 2, 4, 6, shadeColor(c, 0.95), 0.12)
            s.px(3, 2, 0x1c1c1c)
            s.fill(20, 10, 5, 4, shadeColor(c, 0.85), 0.1)
            s.fill(2, 1, 4, 2, shadeColor(c, 0.85), 0.1)
        },
        packTex: ["entity/fish/salmon.png"]))
    // vanilla tropical fish shape A; base art is grayscale by design and
    // tinted per variant — we bake the clownfish colors (kob/orange-white)
    M2("tropical_fish", MobModel(
        texW: 32, texH: 32,
        parts: [
            part("body", (-0.5, 1.5, 0), box(-0.5, 0, -3, 2, 3, 6, 0, 0),
                 box(0.5, 3, -3, 0, 4, 6, 10, -6)),                       // dorsal fin
            part("tail", (0, 1.5, 3), box(0, 0, 0, 0, 3, 4, 24, -4)),
            part("finL", (0.5, 1.5, 1), box(0.336, 0, -0.1, 2, 2, 0, 2, 12)),
            part("finR", (-0.5, 1.5, 1), box(-2.336, 0, -0.1, 2, 2, 0, 2, 16)),
        ],
        anim: "fish", scale: 0.7,
        paint: { s in
            s.box(0, 0, 2, 3, 6, 0xe8743c, 0.08)
            s.rect(2, 4, 1, 3, 0xf8f8f8); s.rect(5, 4, 1, 3, 0xf8f8f8)
            s.px(2, 5, 0x1c1c1c)
            s.fill(24, 0, 4, 3, 0xf8f8f8, 0.08)
            s.fill(16, 0, 6, 4, 0xf8f8f8, 0.08)
        },
        packTex: ["entity/fish/tropical_a.png", "entity/fish/tropical_a_pattern_1.png"],
        packTexTints: [0xF6603A, 0xF8F8F8]))
    M2("pufferfish", MobModel(
        texW: 32, texH: 32,
        parts: [
            part("body", (0, 4, 0), box(-3.5, -3.5, -3.5, 7, 7, 7, 0, 0)),
            part("spikes", (0, 4, 0),
                 box(-3.5, 3.4, -3.5, 7, 1, 7, 14, 16),
                 box(-3.5, -4.4, -3.5, 7, 1, 7, 14, 16),
                 box(-4.4, -3.5, -3.5, 1, 7, 7, 14, 16),
                 box(3.4, -3.5, -3.5, 1, 7, 7, 14, 16)),
        ],
        anim: "fish", scale: 1,
        paint: { s in
            s.box(0, 0, 7, 7, 7, 0xd8b83c, 0.14)
            s.rect(7 + 1, 7 + 2, 2, 2, 0xf8f8f8); s.px(7 + 2, 7 + 2, 0x1c1c1c)
            s.rect(7 + 4, 7 + 2, 2, 2, 0xf8f8f8); s.px(7 + 5, 7 + 2, 0x1c1c1c)
            s.fill(0, 14, 4, 4, 0xe8e0c8, 0.1)    // belly hint
            for y in 16..<24 {
                for x in 14..<28 where s.rand(x, y) < 0.25 { s.px(x, y, 0x4c4c34) }
            }
        },
        packTex: ["entity/fish/pufferfish.png"]))
    // vanilla dolphin rig (64×64)
    M2("dolphin", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("body", (0, 4, -3), box(-4, -4, 0, 8, 7, 13, 0, 13),
                 box(-1, -4, -10, 2, 2, 4, 0, 13)),                        // nose
            part("head", (0, 4, -3), box(-4, -4, -6, 8, 7, 6, 0, 0)),
            part("tail", (0, 2.5, 11), box(-2, -2.5, -1, 4, 5, 11, 0, 33),
                 box(-5, -0.5, 8, 10, 1, 6, 0, 49)),                       // fluke
            rpart("backFin", (0, 7, 2), (0.5236, 0, 0), box(-0.5, -0.75, -1, 1, 5, 4, 29, 0)),
            rpart("finL", (3, 1, -1), (0, -0.4363, -0.3491), box(0, 0, -1.5, 8, 1, 4, 40, 0)),
            rpart("finR", (-3, 1, -1), (0, 0.4363, 0.3491), box(-8, 0, -1.5, 8, 1, 4, 40, 6)),
        ],
        anim: "dolphin", scale: 1,
        paint: { s in
            let c = 0x8a9aae
            s.box(0, 13, 8, 7, 13, c, 0.08)
            s.box(0, 0, 8, 7, 6, c, 0.08)
            s.box(0, 33, 4, 5, 11, c, 0.08)
            s.box(0, 49, 10, 1, 6, shadeColor(c, 0.9), 0.08)
            s.box(29, 0, 1, 5, 4, shadeColor(c, 0.88), 0.08)
            s.box(40, 0, 8, 1, 4, shadeColor(c, 0.9), 0.08)
            s.box(40, 6, 8, 1, 4, shadeColor(c, 0.9), 0.08)
        },
        packTex: ["entity/dolphin.png"]))
    // vanilla guardian rig: 16-deep body with side/top/bottom plates; eye and
    // spike art live in the unwrap's unused top-left corner ((8,0) and (0,0))
    let guardianModel = MobModel(
        texW: 64, texH: 64,
        parts: {
            var parts: [ModelPart] = [
                part("body", (0, 6, 0), box(-6, 0, -8, 12, 12, 16, 0, 0),
                     box(-8, 0, -6, 2, 12, 12, 0, 28),     // side plates
                     box(6, 0, -6, 2, 12, 12, 0, 28),
                     box(-6, 12, -6, 12, 2, 12, 16, 40),   // top plate
                     box(-6, -2, -6, 12, 2, 12, 16, 40)),  // bottom plate
                part("eye", (0, 12, -8.2), box(-1, -1, 0, 2, 2, 1, 8, 0)),
                part("tail", (0, 12, 8), box(-2, -2, -1, 4, 4, 8, 40, 0),
                     box(-1.5, -1.5, 6, 3, 3, 7, 0, 54),
                     box(-1, -1, 12, 2, 2, 6, 41, 32),
                     box(0, -4.5, 15, 1, 9, 9, 25, 19)),   // tail fin
            ]
            for i in 0..<12 { parts.append(part("spike\(i)", (0, 12, 0), box(-1, -4.5, -1, 2, 9, 2, 0, 0))) }
            return parts
        }(),
        anim: "guardian", scale: 1,
        paint: guardianPaint, packTex: ["entity/guardian.png"])
    M2("guardian", guardianModel)
    // vanilla axolotl rig (64×64) — gill planes, top fin, flat paddle legs
    M2("axolotl", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 2, -5), box(-4, -2, -5, 8, 5, 5, 0, 1),
                 box(4, -2, -1, 3, 7, 0, 11, 40),                          // gills
                 box(-7, -2, -1, 3, 7, 0, 0, 40),
                 box(-4, 3, -1, 8, 3, 0, 3, 37)),                          // top gills
            part("body", (0, 3, 4), box(-4, -3, -9, 8, 4, 10, 0, 11),
                 box(0, -3, -9, 0, 5, 9, 2, 17)),                          // back fin
            part("tail", (0, 2, 4), box(0, -2, 0, 0, 5, 12, 2, 19)),
            part("legFR", (-4, 1, -4), box(-3, -2, -2, 3, 5, 0, 2, 13)),
            part("legFL", (4, 1, -4), box(0, -2, -2, 3, 5, 0, 2, 13)),
            part("legBR", (-4, 1, 4), box(-3, -2, -2, 3, 5, 0, 2, 13)),
            part("legBL", (4, 1, 4), box(0, -2, -2, 3, 5, 0, 2, 13)),
        ],
        anim: "quadTail", scale: 0.8,
        paint: { s in
            let c = 0xf0a8c8
            s.box(0, 1, 8, 5, 5, c, 0.08)
            s.box(0, 11, 8, 4, 10, c, 0.08)
            s.fill(11, 40, 3, 7, 0xe87aa8, 0.1); s.fill(0, 40, 3, 7, 0xe87aa8, 0.1)
            s.fill(3, 37, 8, 3, 0xe87aa8, 0.1)
            s.fill(2, 17, 9, 5, 0xe87aa8, 0.08)
            s.fill(2, 19, 12, 5, 0xe87aa8, 0.08)
            s.fill(2, 13, 3, 5, c, 0.08)
        },
        packTex: ["entity/axolotl/axolotl_lucy.png"]))
    // vanilla turtle rig (128×64) — rotated shell + flat flippers
    M2("turtle", MobModel(
        texW: 128, texH: 64,
        parts: [
            part("head", (0, 5, -10), box(-3, -4, -3, 6, 5, 6, 2, 0)),
            rpart("body", (0, 13, -10), (-Double.pi / 2, 0, 0),
                  box(-9.5, -23, -10, 19, 20, 6, 6, 37),
                  box(-5.5, -21, -13, 11, 18, 3, 30, 1),
                  box(-4.5, -21, -14, 9, 18, 1, 69, 33)),                  // belly
            part("legFR", (-5, 3, -4), box(-13, -1, -2, 13, 1, 5, 26, 30)),
            part("legFL", (5, 3, -4), box(0, -1, -2, 13, 1, 5, 26, 24)),
            part("legBR", (-3.5, 2, 11), box(-2, -1, 0, 4, 1, 10, 0, 23)),
            part("legBL", (3.5, 2, 11), box(-2, -1, 0, 4, 1, 10, 0, 12)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            s.box(2, 0, 6, 5, 6, 0x6a9a4c, 0.1)
            s.box(6, 37, 19, 20, 6, 0x44702e, 0.12)
            s.box(30, 1, 11, 18, 3, 0x5c8a3c, 0.1)
            s.box(69, 33, 9, 18, 1, 0xc8b87a, 0.08)
            s.box(26, 30, 13, 1, 5, 0x6a9a4c, 0.1); s.box(26, 24, 13, 1, 5, 0x6a9a4c, 0.1)
            s.box(0, 23, 4, 1, 10, 0x6a9a4c, 0.1); s.box(0, 12, 4, 1, 10, 0x6a9a4c, 0.1)
        },
        packTex: ["entity/turtle/big_sea_turtle.png"]))
    // vanilla frog rig (48×48) — body/head planes, eyes, webbed foot planes
    M2("frog", MobModel(
        texW: 48, texH: 48,
        parts: [
            part("body", (0, 2, 4), box(-3.5, -1, -8, 7, 3, 9, 3, 1),
                 box(-3.5, 1, -8, 7, 0, 9, 23, 22)),
            part("head", (0, 4, 3), box(-3.5, 1, -7, 7, 0, 9, 23, 13),
                 box(-3.5, -1, -7, 7, 3, 9, 0, 13)),
            part("eyeR", (-2, 7, -1.5), box(-1.5, -1, -1.5, 3, 2, 3, 0, 0)),
            part("eyeL", (2, 7, -1.5), box(-1.5, -1, -1.5, 3, 2, 3, 0, 5)),
            part("legFR", (-4, 3, -2.5), box(-1, -3, -1, 2, 3, 3, 0, 38),
                 box(-4, -3.01, -5, 8, 0, 8, 2, 40)),
            part("legFL", (4, 3, -2.5), box(-1, -3, -1, 2, 3, 3, 0, 32),
                 box(-4, -3.01, -5, 8, 0, 8, 18, 40)),
            part("legBR", (-3.5, 3, 4), box(-2, -3, -2, 3, 3, 4, 0, 25),
                 box(-6, -3.01, -4, 8, 0, 8, 18, 32)),
            part("legBL", (3.5, 3, 4), box(-1, -3, -2, 3, 3, 4, 14, 25),
                 box(-2, -3.01, -4, 8, 0, 8, 2, 32)),
        ],
        anim: "frog", scale: 1,
        paint: { s in
            let c = 0xb87a4c
            s.box(3, 1, 7, 3, 9, c, 0.1)
            s.box(0, 13, 7, 3, 9, shadeColor(c, 1.05), 0.1)
            s.box(0, 0, 3, 2, 3, shadeColor(c, 1.05), 0.08)
            s.box(0, 5, 3, 2, 3, shadeColor(c, 1.05), 0.08)
            s.box(0, 38, 2, 3, 3, c, 0.1); s.box(0, 32, 2, 3, 3, c, 0.1)
            s.box(0, 25, 3, 3, 4, c, 0.1); s.box(14, 25, 3, 3, 4, c, 0.1)
        },
        packTex: ["entity/frog/temperate_frog.png"]))
    // vanilla tadpole rig (16×16)
    M2("tadpole", MobModel(
        texW: 16, texH: 16,
        parts: [
            part("body", (0, 3, -1), box(-1.5, 0, -1.5, 3, 2, 3, 0, 0)),
            part("tail", (0, 3, 1), box(0, 0, -1.5, 0, 2, 7, 0, 0)),
        ],
        anim: "fish", scale: 1,
        paint: { s in
            s.box(0, 0, 3, 2, 3, 0x6a5a4c, 0.12)
        },
        packTex: ["entity/tadpole/tadpole.png"]))

    // AMBIENT / MISC
    M2("bat", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 14, 0), box(-3, 0, -3, 6, 6, 6, 0, 0), box(-4, 5, -1, 3, 4, 1, 24, 0), box(1, 5, -1, 3, 4, 1, 24, 0)),
            part("body", (0, 14, 0), box(-3, -12, -3, 6, 12, 6, 0, 16)),
            part("wingR", (-3, 13, 0), box(-10, -15, 0, 10, 16, 1, 42, 0), box(-18, -13, 0, 8, 12, 1, 24, 16)),
            part("wingL", (3, 13, 0), box(0, -15, 0, 10, 16, 1, 42, 0), box(10, -13, 0, 8, 12, 1, 24, 16)),
        ],
        anim: "bat", scale: 0.5,
        paint: { s in
            s.box(0, 0, 6, 6, 6, 0x5a4a42, 0.14)
            s.px(6 + 1, 6 + 2, 0x1c1c1c); s.px(6 + 4, 6 + 2, 0x1c1c1c)
            s.box(24, 0, 3, 4, 1, 0x4a3c36, 0.1)
            s.box(0, 16, 6, 12, 6, 0x5a4a42, 0.14)
            s.box(42, 0, 10, 16, 1, 0x44382e, 0.1)
            s.box(24, 16, 8, 12, 1, 0x44382e, 0.1)
        }, packTex: ["entity/bat.png"]))
    M2("bee", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("body", (0, 7, 0), box(-3.5, 0, -5, 7, 7, 10, 0, 0)),
            part("wingR", (-1.5, 14, -3), box(-9, 0, 0, 9, 1, 6, 0, 18)),
            part("wingL", (1.5, 14, -3), box(0, 0, 0, 9, 1, 6, 0, 18)),
            part("sting", (0, 10, 5), box(-0.5, -0.5, 0, 1, 1, 2, 26, 7)),
        ],
        anim: "bee", scale: 0.55,
        paint: { s in
            s.box(0, 0, 7, 7, 10, 0xe8b83c, 0.1)
            // stripes
            s.rect(10 + 2, 7, 2, 7, 0x2c2418); s.rect(10 + 6, 7, 2, 7, 0x2c2418)
            s.rect(0, 7, 10, 7, 0xe8b83c); s.rect(2, 7, 2, 7, 0x2c2418)
            s.rect(7 + 1, 7 + 2, 2, 2, 0x1c1c1c); s.rect(7 + 5, 7 + 2, 2, 2, 0x1c1c1c)
            s.box(0, 18, 9, 1, 6, 0xd8e8f0, 0.05)
            s.box(26, 7, 1, 1, 2, 0x2c2418)
        }, packTex: ["entity/bee/bee.png"]))
    // vanilla parrot rig (32×32)
    M2("parrot", MobModel(
        texW: 32, texH: 32,
        parts: [
            part("head", (0, 8.3, -2.8), box(-1, -1.5, -1, 2, 3, 2, 2, 2),
                 box(-1, 1.5, -3, 2, 1, 4, 10, 0),                        // crown
                 box(-0.5, -0.5, -1.9, 1, 2, 1, 11, 7),                   // beak
                 box(-0.5, -0.2, -2.9, 1, 1.7, 1, 16, 7),
                 box(0, 0.8, -2.1, 0, 5, 4, 2, 18)),                      // feather
            part("body", (0, 7.5, -3), box(-1.5, -6, -1.5, 3, 6, 3, 2, 8)),
            part("tail", (0, 2.9, 1.2), box(-1.5, -3, -1, 3, 4, 1, 22, 1)),
            part("wingL", (1.5, 7.1, -2.8), box(-0.5, -5, -1.5, 1, 5, 3, 19, 8)),
            part("wingR", (-1.5, 7.1, -2.8), box(-0.5, -5, -1.5, 1, 5, 3, 19, 8)),
            part("legR", (-0.5, 1, -0.5), box(-1, -1.5, -1, 1, 2, 1, 14, 18)),
            part("legL", (1.5, 1, -0.5), box(-1, -1.5, -1, 1, 2, 1, 14, 18)),
        ],
        anim: "parrot", scale: 0.6,
        paint: { s in
            let c = 0xd83a3a
            s.box(2, 2, 2, 3, 2, c, 0.1)
            s.box(10, 0, 2, 1, 4, c, 0.1)
            s.box(11, 7, 1, 2, 1, 0x8a8a8a); s.box(16, 7, 1, 2, 1, 0x8a8a8a)
            s.box(2, 8, 3, 6, 3, c, 0.1)
            s.box(19, 8, 1, 5, 3, 0x3a5ac8, 0.1)
            s.box(22, 1, 3, 4, 1, 0xe8c83c, 0.1)
            s.fill(2, 18, 4, 5, 0x3a5ac8, 0.1)
            s.box(14, 18, 1, 2, 1, 0x8a8a8a)
        },
        packTex: ["entity/parrot/parrot_red_blue.png"]))
    // vanilla PandaModel geometry (64×64) — the old quadModel2 body unwrap
    // overflowed the 64-wide texture and rendered hollow from one side
    M2("panda", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 12.5, -17), box(-6.5, -5, -4, 13, 10, 9, 0, 6),
                 box(-3.5, -5, -6, 7, 5, 2, 45, 16),                      // nose
                 box(-8.5, 4, -1, 5, 4, 1, 52, 25), box(3.5, 4, -1, 5, 4, 1, 52, 25)), // ears
            rpart("body", (0, 14, 0), (-Double.pi / 2, 0, 0),
                  box(-9.5, -13, -6.5, 19, 26, 13, 0, 25)),
            part("legFR", (-5.5, 9, -9), box(-3, -9, -3, 6, 9, 6, 40, 0)),
            part("legFL", (5.5, 9, -9), box(-3, -9, -3, 6, 9, 6, 40, 0)),
            part("legBR", (-5.5, 9, 9), box(-3, -9, -3, 6, 9, 6, 40, 0)),
            part("legBL", (5.5, 9, 9), box(-3, -9, -3, 6, 9, 6, 40, 0)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            s.box(0, 6, 13, 10, 9, 0xe8e8e8, 0.06)                        // head
            s.box(45, 16, 7, 5, 2, 0x1c1c1c, 0.08)                        // nose
            s.box(52, 25, 5, 4, 1, 0x1c1c1c, 0.08)                        // ears
            s.box(0, 25, 19, 26, 13, 0xe8e8e8, 0.06)                      // body
            s.box(40, 0, 6, 9, 6, 0x1c1c1c, 0.08)                         // legs
        },
        packTex: ["entity/panda/panda.png"]))
    // vanilla PolarBearModel geometry (128×64)
    M2("polar_bear", MobModel(
        texW: 128, texH: 64,
        parts: [
            part("head", (0, 14, -16), box(-3.5, -4, -3, 7, 7, 7, 0, 0),
                 box(-2.5, -4, -6, 5, 3, 3, 0, 44),                       // snout
                 box(-4.5, 2, -1, 2, 2, 1, 26, 0), box(2.5, 2, -1, 2, 2, 1, 26, 0)), // ears
            rpart("body", (-2, 15, 12), (-Double.pi / 2, 0, 0),
                  box(-5, -1, -7, 14, 14, 11, 0, 19),                     // haunches
                  box(-4, 13, -7, 12, 12, 10, 39, 0)),                    // front torso
            part("legFR", (-3.5, 10, -8), box(-2, -10, -2, 4, 10, 6, 50, 40)),
            part("legFL", (3.5, 10, -8), box(-2, -10, -2, 4, 10, 6, 50, 40)),
            part("legBR", (-4.5, 10, 6), box(-2, -10, -2, 4, 10, 8, 50, 22)),
            part("legBL", (4.5, 10, 6), box(-2, -10, -2, 4, 10, 8, 50, 22)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            s.box(0, 0, 7, 7, 7, 0xe8e8e0, 0.06)                          // head
            s.box(0, 44, 5, 3, 3, 0xd8d8d0, 0.06)                         // snout
            s.box(26, 0, 2, 2, 1, 0xe0e0d8, 0.06)                         // ears
            s.box(0, 19, 14, 14, 11, 0xe8e8e0, 0.06)                      // haunches
            s.box(39, 0, 12, 12, 10, 0xe8e8e0, 0.06)                      // front torso
            s.box(50, 22, 4, 10, 8, 0xe0e0d8, 0.06)                       // hind legs
            s.box(50, 40, 4, 10, 6, 0xe0e0d8, 0.06)                       // front legs
        },
        packTex: ["entity/bear/polarbear.png"]))
    // vanilla sniffer rig (192×192) — six legs, beaked head with tall ears
    M2("sniffer", MobModel(
        texW: 192, texH: 192,
        parts: [
            part("body", (0, 0, 0), box(-12.5, 9, -20, 25, 24, 40, 62, 0),
                 box(-12.5, 4, -20, 25, 29, 40, 62, 68),
                 box(-12.5, 8, -20, 25, 0, 40, 87, 68)),
            part("head", (0, 13.5, -19.4), box(-6.5, -10.5, -11.5, 13, 18, 11, 8, 15),
                 box(-6.5, -7.5, -11.5, 13, 0, 11, 8, 4),
                 box(6.4, -11.5, -7.5, 1, 19, 7, 2, 0),                   // ears
                 box(-7.4, -11.5, -7.5, 1, 19, 7, 48, 0),
                 box(-6.5, 4.5, -20.5, 13, 2, 9, 10, 45),                 // nose
                 box(-6.5, -7.5, -20.5, 13, 12, 9, 10, 57)),              // lower beak
            part("legFR", (-7.5, 9, -15), box(-3.5, -9, -4, 7, 10, 8, 32, 87)),
            part("legFL", (7.5, 9, -15), box(-3.5, -9, -4, 7, 10, 8, 0, 87)),
            part("legMR", (-7.5, 9, 0), box(-3.5, -9, -4, 7, 10, 8, 32, 105)),
            part("legML", (7.5, 9, 0), box(-3.5, -9, -4, 7, 10, 8, 0, 105)),
            part("legBR", (-7.5, 9, 15), box(-3.5, -9, -4, 7, 10, 8, 32, 123)),
            part("legBL", (7.5, 9, 15), box(-3.5, -9, -4, 7, 10, 8, 0, 123)),
        ],
        anim: "quad", scale: 1,
        paint: { s in
            let c = 0xb04a3c
            s.box(62, 0, 25, 24, 40, c, 0.12)
            s.box(62, 68, 25, 29, 40, shadeColor(c, 0.95), 0.12)
            s.box(8, 15, 13, 18, 11, c, 0.12)
            s.box(10, 45, 13, 2, 9, 0x8a382e, 0.1)
            s.box(10, 57, 13, 12, 9, shadeColor(c, 0.92), 0.12)
            s.box(2, 0, 1, 19, 7, 0x44aa44, 0.15); s.box(48, 0, 1, 19, 7, 0x44aa44, 0.15)
            s.box(32, 87, 7, 10, 8, shadeColor(c, 0.9), 0.1); s.box(0, 87, 7, 10, 8, shadeColor(c, 0.9), 0.1)
            s.box(32, 105, 7, 10, 8, shadeColor(c, 0.9), 0.1); s.box(0, 105, 7, 10, 8, shadeColor(c, 0.9), 0.1)
            s.box(32, 123, 7, 10, 8, shadeColor(c, 0.9), 0.1); s.box(0, 123, 7, 10, 8, shadeColor(c, 0.9), 0.1)
        },
        packTex: ["entity/sniffer/sniffer.png"]))

    // WARDEN
    // vanilla warden rig (128×128) — ribcage + tendril planes included
    M2("warden", MobModel(
        texW: 128, texH: 128,
        parts: [
            part("head", (0, 34, 0), box(-8, 0, -5, 16, 16, 10, 0, 32),
                 box(-24, 9, 0, 16, 16, 0, 52, 32), box(8, 9, 0, 16, 16, 0, 58, 0)), // tendrils
            part("body", (0, 21, 0), box(-9, -8, -4, 18, 21, 11, 0, 0),
                 box(-9, -8, -4.1, 9, 21, 0, 90, 11), box(0, -8, -4.1, 9, 21, 0, 90, 11)), // ribcage
            part("armR", (-13, 34, 1), box(-4, -28, -4, 8, 28, 8, 44, 50)),
            part("armL", (13, 34, 1), box(-4, -28, -4, 8, 28, 8, 0, 58)),
            part("legR", (-5.9, 13, 0), box(-3.1, -13, -3, 6, 13, 6, 76, 48)),
            part("legL", (5.9, 13, 0), box(-2.9, -13, -3, 6, 13, 6, 76, 76)),
        ],
        anim: "biped", scale: 1,
        paint: { s in
            let c = 0x0c3340
            s.box(0, 32, 16, 16, 10, c, 0.14)
            s.rect(10 + 3, 32 + 10 + 2, 3, 4, 0x2ce8e8); s.rect(10 + 10, 32 + 10 + 2, 3, 4, 0x2ce8e8)
            s.box(0, 0, 18, 21, 11, shadeColor(c, 0.95), 0.14)
            s.rect(11 + 6, 11 + 6, 6, 8, 0x18b8c8)
            s.box(44, 50, 8, 28, 8, shadeColor(c, 0.92), 0.14)
            s.box(0, 58, 8, 28, 8, shadeColor(c, 0.92), 0.14)
            s.box(76, 48, 6, 13, 6, shadeColor(c, 0.9), 0.14)
            s.box(76, 76, 6, 13, 6, shadeColor(c, 0.9), 0.14)
        },
        packTex: ["entity/warden/warden.png"]))

    // DRAGON & WITHER
    // vanilla ender dragon rig (256×256) — wing membranes are 56×56 planes
    // whose unwrap starts at negative u (cancelled by +d); tips are folded
    // into the wing parts so the whole 112-unit span flaps as one
    M2("ender_dragon", MobModel(
        texW: 256, texH: 256,
        parts: [
            part("head", (0, 20, -34),
                 box(-8, -4, -6, 16, 16, 16, 112, 30),                     // skull
                 box(-6, 0, -22, 12, 5, 16, 176, 44),                      // snout
                 box(-5, 5, -20, 2, 2, 4, 112, 0), box(3, 5, -20, 2, 2, 4, 112, 0), // nostrils
                 box(-5, 12, 0, 2, 4, 6, 0, 0), box(3, 12, 0, 2, 4, 6, 0, 0),       // horns
                 box(-6, -4, -22, 12, 4, 16, 176, 65)),                    // jaw
            part("neck", (0, 22, -22), box(-5, -3, -10, 10, 10, 10, 192, 104),
                 box(-5, -3, 0, 10, 10, 10, 192, 104),
                 box(-1, 7, -8, 2, 4, 6, 48, 0), box(-1, 7, 2, 2, 4, 6, 48, 0)),
            part("body", (0, 18, 0), box(-12, -10, -12, 24, 24, 64, 0, 0),
                 box(-1, 14, -6, 2, 6, 12, 220, 53), box(-1, 14, 14, 2, 6, 12, 220, 53),
                 box(-1, 14, 34, 2, 6, 12, 220, 53)),
            part("wingR", (-12, 24, -2),
                 box(-56, -4, -4, 56, 8, 8, 112, 88), box(-56, 0, 4, 56, 0, 56, -56, 88),
                 box(-112, -2, -2, 56, 4, 4, 112, 136), box(-112, 0, 2, 56, 0, 56, -56, 144)),
            part("wingL", (12, 24, -2),
                 box(0, -4, -4, 56, 8, 8, 112, 88), box(0, 0, 4, 56, 0, 56, -56, 88),
                 box(56, -2, -2, 56, 4, 4, 112, 136), box(56, 0, 2, 56, 0, 56, -56, 144)),
            part("tail1", (0, 20, 52), box(-5, -5, 0, 10, 10, 10, 192, 104),
                 box(-1, 5, 2, 2, 4, 6, 48, 0)),
            part("tail2", (0, 20, 62), box(-5, -5, 0, 10, 10, 10, 192, 104),
                 box(-1, 5, 2, 2, 4, 6, 48, 0)),
            part("tail3", (0, 20, 72), box(-5, -5, 0, 10, 10, 10, 192, 104),
                 box(-1, 5, 2, 2, 4, 6, 48, 0)),
            part("legR", (-16, 32, 30), box(-8, -32, -8, 16, 32, 16, 0, 0),
                 box(-9, -38, -14, 18, 6, 24, 112, 0)),
            part("legL", (16, 32, 30), box(-8, -32, -8, 16, 32, 16, 0, 0),
                 box(-9, -38, -14, 18, 6, 24, 112, 0)),
            part("legFR", (-12, 24, -4), box(-4, -24, -4, 8, 24, 8, 112, 104),
                 box(-4, -28, -10, 8, 4, 16, 144, 104)),
            part("legFL", (12, 24, -4), box(-4, -24, -4, 8, 24, 8, 112, 104),
                 box(-4, -28, -10, 8, 4, 16, 144, 104)),
        ],
        anim: "dragon", scale: 1,
        paint: { s in
            let c = 0x1c1820
            s.box(112, 30, 16, 16, 16, c, 0.14)
            s.box(176, 44, 12, 5, 16, shadeColor(c, 0.9), 0.12)
            s.box(176, 65, 12, 4, 16, shadeColor(c, 0.9), 0.12)
            s.box(192, 104, 10, 10, 10, c, 0.14)
            s.box(0, 0, 24, 24, 64, c, 0.14)
            s.box(112, 88, 56, 8, 8, c, 0.14)
            s.fill(0, 88, 56, 56, 0x2c2433, 0.16)
            s.box(112, 136, 56, 4, 4, c, 0.14)
            s.fill(0, 144, 56, 56, 0x2c2433, 0.16)
            s.box(112, 104, 8, 24, 8, shadeColor(c, 0.92), 0.12)
            s.box(144, 104, 8, 4, 16, shadeColor(c, 0.92), 0.12)
            s.box(112, 0, 18, 6, 24, shadeColor(c, 0.92), 0.12)
            s.box(220, 53, 2, 6, 12, 0x3a3442, 0.1)
            s.box(48, 0, 2, 4, 6, 0x3a3442, 0.1)
        },
        packTex: ["entity/enderdragon/dragon.png"]))
    M2("wither", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("head", (0, 28, 0), box(-4, 0, -4, 8, 8, 8, 0, 0)),
            part("headR", (-8, 26, 0), box(-3, 0, -3, 6, 6, 6, 32, 0)),
            part("headL", (8, 26, 0), box(-3, 0, -3, 6, 6, 6, 32, 0)),
            part("body", (0, 28, 0), box(-10, -3, -1.5, 20, 3, 3, 0, 16), box(-1.5, -13, -1.5, 3, 10, 3, 0, 22), box(-1.5, -19, -1.5, 3, 6, 3, 12, 22)),
        ],
        anim: "wither", scale: 1.55,
        paint: { s in
            let c = 0x181818
            s.box(0, 0, 8, 8, 8, c, 0.16)
            s.eyes(0, 0, 8, 1, 3, 5, 2, 2, 0x3c3c3c, 0x0a0a0a)
            s.box(32, 0, 6, 6, 6, c, 0.16)
            s.rect(38 + 1, 6 + 2, 1, 1, 0x3c3c3c); s.rect(38 + 4, 6 + 2, 1, 1, 0x3c3c3c)
            s.box(0, 16, 20, 3, 3, shadeColor(c, 1.1), 0.16)
            s.box(0, 22, 3, 10, 3, shadeColor(c, 1.05), 0.16)
            s.box(12, 22, 3, 6, 3, shadeColor(c, 1.15), 0.16)
        }, packTex: ["entity/wither/wither.png"]))
    M2("phantom", MobModel(
        texW: 64, texH: 64,
        parts: [
            part("body", (0, 6, 0), box(-3, -1, -8, 5, 3, 9, 0, 8),
                 box(-2, 0, 1, 3, 2, 6, 3, 20), box(-1, 0.5, 7, 1, 1, 6, 4, 29)),
            part("head", (0, 5, -7), box(-4, -1, -5, 7, 3, 5, 0, 0)),
            part("wingR", (-3, 6, -4), box(-6, 0, -2, 6, 2, 9, 23, 12), box(-19, 0.2, -2, 13, 1, 9, 16, 24)),
            part("wingL", (2, 6, -4), box(0, 0, -2, 6, 2, 9, 23, 12), box(6, 0.2, -2, 13, 1, 9, 16, 24)),
        ],
        anim: "phantom", scale: 1,
        paint: { s in
            let c = 0x4a5a8a
            s.box(0, 0, 7, 3, 5, c, 0.12)
            s.rect(5 + 1, 5 + 0, 1, 1, 0x6ae84a); s.rect(5 + 5, 5 + 0, 1, 1, 0x6ae84a)
            s.box(0, 8, 6, 3, 9, c, 0.12)
            s.box(3, 20, 4, 2, 6, shadeColor(c, 0.92), 0.12)
            s.box(4, 29, 2, 1, 6, shadeColor(c, 0.9), 0.12)
            s.box(23, 12, 6, 2, 9, shadeColor(c, 1.06), 0.12)
            s.box(16, 24, 13, 1, 9, shadeColor(c, 1.06), 0.12)
        }, packTex: ["entity/phantom.png"]))

    // projectile / object models
    M2("arrow_model", MobModel(
        texW: 16, texH: 16,
        parts: [part("body", (0, 0, 0), box(-0.5, -0.5, -4, 1, 1, 8, 0, 0))],
        anim: "none", scale: 1,
        paint: { s in s.box(0, 0, 1, 1, 8, 0x8a6a3c, 0.15); s.rect(1, 1, 6, 1, 0xc8c8c8) }))
    M2("item_holder", MobModel(
        texW: 16, texH: 16,
        parts: [part("body", (0, 0, 0), box(-4, 0, -4, 8, 8, 8, 0, 0))],
        anim: "none", scale: 1,
        paint: { s in s.fill(0, 0, 16, 16, 0xffffff, 0) }))
    // vanilla boat rig (128×64) — model space is x-long, so every plank gets
    // a baked extra 90° yaw to run along z like our boat entity does
    M2("boat_model", MobModel(
        texW: 128, texH: 64,
        parts: [
            rpart("bottom", (1, 1, 0), (Double.pi / 2, Double.pi / 2, 0),
                  box(-14, -9, -3, 28, 16, 3, 0, 0)),
            part("stern", (0, 0, 14), box(-9, 0, -1, 18, 6, 2, 0, 19)),
            rpart("bow", (0, 0, -14), (0, Double.pi, 0), box(-8, 0, -1, 16, 6, 2, 0, 27)),
            rpart("sideR", (-8, 0, 0), (0, -Double.pi / 2, 0), box(-14, 0, -1, 28, 6, 2, 0, 35)),
            rpart("sideL", (8, 0, 0), (0, Double.pi / 2, 0), box(-14, 0, -1, 28, 6, 2, 0, 43)),
            part("seat", (0, 3, 0), box(-7, 0, -1, 14, 1, 2, 0, 19)),
            rpart("paddleR", (-8.5, 6, 1), (0, 0, 0.5),
                  box(-1, -7, -0.5, 2, 8, 1, 62, 0), box(-2, -10, -0.5, 3, 3, 1, 62, 20)),
            rpart("paddleL", (8.5, 6, 1), (0, 0, -0.5),
                  box(-1, -7, -0.5, 2, 8, 1, 62, 0), box(-1, -10, -0.5, 3, 3, 1, 62, 20)),
        ],
        anim: "none", scale: 1,
        paint: { s in
            s.box(0, 0, 28, 16, 3, 0x9a6b35, 0.12)
            s.box(0, 19, 18, 6, 2, 0x8a5c2c, 0.12)
            s.box(0, 27, 16, 6, 2, 0x8a5c2c, 0.12)
            s.box(0, 35, 28, 6, 2, 0x8a5c2c, 0.12)
            s.box(0, 43, 28, 6, 2, 0x8a5c2c, 0.12)
            s.box(62, 0, 2, 8, 1, 0x7a5228, 0.1)
            s.box(62, 20, 3, 3, 1, 0x7a5228, 0.1)
        },
        packTex: ["entity/boat/oak.png"]))
    // vanilla end crystal art (32×32): glass shell (0,0), core (0,16); the
    // base samples the core region too (vanilla draws a real bedrock block
    // there, which entity art can't express)
    M2("end_crystal_model", MobModel(
        texW: 64, texH: 32,
        parts: [
            part("base", (0, 0, 0), box(-4, 0, -4, 8, 3, 8, 0, 16)),
            part("crystal", (0, 13, 0), box(-4, -4, -4, 8, 8, 8, 0, 0), box(-2, -2, -2, 4, 4, 4, 0, 0)),
        ],
        anim: "crystal", scale: 1,
        paint: { s in
            s.boxA(0, 0, 8, 8, 8, 0xc89ae8, 150, 0.1)     // spinning glass shell
            s.box(0, 16, 4, 4, 4, 0xf0e8ff, 0.06)          // core
        },
        packTex: ["entity/end_crystal/end_crystal.png"]))
    // vanilla minecart rig (64×32) — rotated floor plate + four 16×8×2 walls
    M2("minecart_model", MobModel(
        texW: 64, texH: 32,
        parts: [
            rpart("floor", (0, 2, 0), (-Double.pi / 2, 0, 0), box(-10, -8, -1, 20, 16, 2, 0, 10)),
            part("sideL", (0, 0, 7), box(-8, 0, -1, 16, 8, 2, 0, 0)),
            part("sideR", (0, 0, -7), box(-8, 0, -1, 16, 8, 2, 0, 0)),
            rpart("endF", (-9, 0, 0), (0, Double.pi / 2, 0), box(-8, 0, -1, 16, 8, 2, 0, 0)),
            rpart("endB", (9, 0, 0), (0, -Double.pi / 2, 0), box(-8, 0, -1, 16, 8, 2, 0, 0)),
        ],
        anim: "none", scale: 0.85,
        paint: { s in
            s.box(0, 10, 20, 16, 2, 0x6a6a72, 0.1)
            s.box(0, 0, 16, 8, 2, 0x5c5c64, 0.1)
        },
        packTex: ["entity/minecart.png"]))

    // clones that tweak a base model (ocelot, zoglin, elder_guardian, goat_kid)
    let cat = MODELS["cat"]!
    M2("ocelot", MobModel(texW: cat.texW, texH: cat.texH, parts: cat.parts, anim: cat.anim, scale: cat.scale,
                          paint: { s in catPaint(s); s.fill(20, 0, 4, 4, 0xc8a23c, 0.3) },
                          packTex: ["entity/cat/ocelot.png"]))
    let hog = MODELS["hoglin"]!
    M2("zoglin", MobModel(texW: hog.texW, texH: hog.texH, parts: hog.parts, anim: hog.anim, scale: hog.scale,
                          paint: { s in hoglinPaint(s); s.fill(0, 0, 23, 15, 0x7aa05c, 0.25) },
                          packTex: ["entity/hoglin/zoglin.png"]))
    let guardian = MODELS["guardian"]!
    M2("elder_guardian", MobModel(texW: guardian.texW, texH: guardian.texH, parts: guardian.parts, anim: guardian.anim, scale: 2.3,
                                  paint: { s in guardianPaint(s); s.fill(0, 0, 36, 12, 0xb8b8b0, 0.2) },
                                  packTex: ["entity/guardian_elder.png"]))
    let goat = MODELS["goat"]!
    M2("goat_kid", MobModel(texW: goat.texW, texH: goat.texH, parts: goat.parts, anim: goat.anim, scale: 0.5, paint: goat.paint))
}

private func hoglinPaint(_ s: EntitySkin) {
    let c = 0xb87a5c
    s.box(0, 0, 14, 6, 9, c, 0.14)
    s.px(9 + 2, 9 + 2, 0x1c1c1c); s.px(9 + 11, 9 + 2, 0x1c1c1c)
    s.box(50, 0, 1, 4, 1, 0xe8e0d0)
    s.box(48, 0, 12, 11, 19, shadeColor(c, 0.95), 0.14)
    s.box(0, 20, 4, 9, 4, shadeColor(c, 0.9), 0.12)
}

private func guardianPaint(_ s: EntitySkin) {
    s.box(0, 0, 12, 12, 12, 0x5a7a6a, 0.14)
    // orange spots
    for i in 0..<12 { s.px(Int(s.rand(i, 0) * 46), Int(s.rand(i, 1) * 22), 0xc87a3c) }
    s.box(8, 26, 2, 2, 1, 0xe8e0d0)
    s.px(8 + 1, 26 + 1, 0xc83a3a)
    s.box(40, 0, 4, 4, 8, 0x5a7a6a, 0.12)
    s.box(40, 14, 2, 2, 6, shadeColor(0x5a7a6a, 0.9), 0.12)
    s.box(28, 36, 2, 5, 2, 0xc8b86a, 0.12)
}

private func squidParts() -> [ModelPart] {
    var parts: [ModelPart] = [part("body", (0, 14, 0), box(-6, -8, -6, 12, 16, 12, 0, 0))]
    for i in 0..<8 {
        let ang = Double(i) / 8 * .pi * 2
        parts.append(part("tent\(i)", (Foundation.cos(ang) * 5, 7, Foundation.sin(ang) * 5), box(-1, -18, -1, 2, 18, 2, 48, 0)))
    }
    return parts
}
