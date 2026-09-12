// Modern bat UV layout used by the bundled Faithful texture (32 logical pixels).
// Model units are 1/16 block, Y up, face toward -Z. Keep each wing tip separate:
// its animation inherits the inner wing instead of orbiting a disconnected pivot.
// Compatibility reference: Mojang/bedrock-samples resource_pack/models/entity/bat_v2.geo.json.

func makeBatModel() -> MobModel {
    MobModel(
        texW: 32, texH: 32,
        parts: [
            ModelPart(name: "head", pivot: (0, 7, 0), boxes: [
                ModelBox(-2, 0, -1, 4, 3, 2, 0, 7),
                ModelBox(-4, 1, 0, 3, 5, 0, 1, 15),
                ModelBox(1, 1, 0, 3, 5, 0, 8, 15),
            ]),
            ModelPart(name: "body", pivot: (0, 7, 0), boxes: [
                ModelBox(-1.5, -5, -1, 3, 5, 2, 0, 0),
            ]),
            ModelPart(name: "feet", pivot: (0, 2, 0), boxes: [
                ModelBox(-1.5, -2, 0, 3, 2, 0, 16, 16),
            ]),
            ModelPart(name: "wingR", pivot: (-1.5, 7, 0), boxes: [
                ModelBox(-2, -5, 0, 2, 7, 0, 12, 0),
            ]),
            ModelPart(name: "wingTipR", pivot: (-3.5, 7, 0), boxes: [
                ModelBox(-6, -6, 0, 6, 8, 0, 16, 0),
            ]),
            ModelPart(name: "wingL", pivot: (1.5, 7, 0), boxes: [
                ModelBox(0, -5, 0, 2, 7, 0, 12, 7),
            ]),
            ModelPart(name: "wingTipL", pivot: (3.5, 7, 0), boxes: [
                ModelBox(0, -6, 0, 6, 8, 0, 16, 8),
            ]),
        ],
        anim: "bat", scale: 1,
        paint: { skin in
            // Fallback matches the same modern UV rectangles, never the old 64×64 rig.
            skin.box(0, 0, 3, 5, 2, 0x594334, 0.12)
            skin.box(0, 7, 4, 3, 2, 0x594334, 0.12)
            skin.px(2, 10, 0xf4e9d7); skin.px(5, 10, 0xf4e9d7)
            skin.box(1, 15, 3, 5, 0, 0x6d5155, 0.12)
            skin.box(8, 15, 3, 5, 0, 0x6d5155, 0.12)
            skin.box(16, 16, 3, 2, 0, 0x453428, 0.08)
            skin.box(12, 0, 2, 7, 0, 0x453428, 0.1)
            skin.box(12, 7, 2, 7, 0, 0x453428, 0.1)
            skin.box(16, 0, 6, 8, 0, 0x453428, 0.1)
            skin.box(16, 8, 6, 8, 0, 0x453428, 0.1)
        },
        packTex: ["entity/bat.png"])
}
