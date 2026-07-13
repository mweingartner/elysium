// Atlas painters part 2 — plants, crops, mushroom blocks, functional blocks,
// torches/lanterns, redstone, rails, doors/trapdoors, misc, saplings,
// destroy stages, particle sprites.

import Foundation

private func flower(_ t: T, _ head: Int, _ center: Int?, _ tall: Bool = false) {
    t.clearAlpha()
    let stem = 0x4f8f2e
    t.vline(7, tall ? 6 : 8, 15, stem)
    t.set(6, 11, stem); t.set(8, 12, stem)
    let hy = tall ? 4 : 6
    t.disc(7.5, Double(hy), 2.4, head)
    if let center {
        t.set(7, hy, center); t.set(8, hy, center)
    }
}

private func froglight(_ t: T, _ c: Int) {
    t.blotch(c, 0.04)
    t.disc(7.5, 7.5, 5, shade(c, 1.05))
    t.border(shade(c, 0.92))
}
private func froglightSide(_ t: T, _ c: Int) {
    t.blotch(c, 0.05)
    for x in [0, 15] { t.vline(x, 0, 15, shade(c, 0.9)) }
    var y = 2
    while y < 14 { t.hline(y, 2, 13, shade(c, 1.06)); y += 4 }
}

func registerPainters2() {
    // --- plants ---
    p("short_grass") { t in t.cross(0x8e8e8e) }
    p("fern") { t in
        t.clearAlpha()
        let c = 0x8e8e8e
        t.vline(7, 4, 15, shade(c, 0.85))
        for i in 0..<5 {
            let y = 5 + i * 2
            t.hline(y, 7 - (5 - i), 7, c); t.hline(y, 8, 8 + (5 - i), c)
        }
    }
    p("dead_bush") { t in
        t.clearAlpha()
        let c = 0x946428
        t.vline(7, 8, 15, c)
        t.set(6, 7, c); t.set(5, 6, c); t.set(8, 7, c); t.set(9, 6, c); t.set(10, 5, c)
        t.set(6, 10, c); t.set(5, 9, c); t.set(9, 11, c); t.set(10, 10, c)
    }
    p("tall_grass_bottom") { t in t.cross(0x8e8e8e) }
    p("tall_grass_top") { t in t.cross(0x8e8e8e) }
    p("dandelion") { t in flower(t, 0xf6e23c, 0xd8b820) }
    p("poppy") { t in flower(t, 0xd0392e, 0x1c1c1c) }
    p("blue_orchid") { t in flower(t, 0x32a3d4, 0xe8f0f8) }
    p("allium") { t in flower(t, 0xb97bd8, nil) }
    p("azure_bluet") { t in
        t.clearAlpha()
        let s = 0x4f8f2e
        for (x, y) in [(3, 9), (8, 7), (12, 10)] {
            t.vline(x, y + 2, 15, s)
            t.disc(Double(x) + 0.5, Double(y), 1.4, 0xe8e8f0)
            t.set(x, y, 0xd8c840)
        }
    }
    p("red_tulip") { t in flower(t, 0xc83a2a, nil) }
    p("orange_tulip") { t in flower(t, 0xe07a2c, nil) }
    p("white_tulip") { t in flower(t, 0xeaeaea, nil) }
    p("pink_tulip") { t in flower(t, 0xe8a8c8, nil) }
    p("oxeye_daisy") { t in flower(t, 0xefefef, 0xe8c63c) }
    p("cornflower") { t in flower(t, 0x4660c8, 0x2a3c8a) }
    p("lily_of_the_valley") { t in
        t.clearAlpha()
        let s = 0x4f8f2e
        t.vline(7, 5, 15, s)
        for (x, y) in [(5, 7), (6, 9), (5, 11), (6, 13)] { t.disc(Double(x), Double(y), 1.2, 0xf4f8f4) }
    }
    p("torchflower") { t in flower(t, 0xe8742c, 0xf8c83c); t.set(7, 4, 0xf8c83c) }
    p("wither_rose") { t in flower(t, 0x1c1c1c, 0x080808) }
    p("sunflower_bottom") { t in t.cross(0x8e8e8e) }
    p("sunflower_top") { t in t.clearAlpha(); t.vline(7, 8, 15, 0x4f8f2e); t.disc(7.5, 5, 4, 0xe8b820); t.disc(7.5, 5, 2, 0x6a4a1a) }
    p("lilac_bottom") { t in t.cross(0x8e8e8e) }
    p("lilac_top") { t in t.clearAlpha(); t.vline(7, 10, 15, 0x4f8f2e); t.disc(6, 5, 2.6, 0xc8a0d8); t.disc(10, 7, 2.4, 0xd8b8e4) }
    p("rose_bush_bottom") { t in t.cross(0x3f6a1e) }
    p("rose_bush_top") { t in
        t.clearAlpha()
        for (x, y) in [(4, 5), (9, 3), (12, 7), (6, 9)] {
            t.disc(Double(x), Double(y), 1.5, 0xd03030)
            t.set(x, y, 0xf05050)
        }
        for i in 0..<14 {
            let x = 2 + Int(t.rand(i, 0) * 12), y = 8 + Int(t.rand(i, 1) * 7)
            t.set(x, y, 0x3f6a1e)
        }
    }
    p("peony_bottom") { t in t.cross(0x3f6a1e) }
    p("peony_top") { t in
        t.clearAlpha()
        for (x, y) in [(5, 5), (10, 4), (12, 8), (7, 9)] { t.disc(Double(x), Double(y), 2, 0xe8b8d0) }
        for i in 0..<12 {
            let x = 2 + Int(t.rand(i, 0) * 12), y = 9 + Int(t.rand(i, 1) * 6)
            t.set(x, y, 0x3f6a1e)
        }
    }
    p("pitcher_plant_bottom") { t in t.clearAlpha(); t.vline(7, 4, 15, 0x3a7a4a); t.vline(8, 6, 15, 0x3a7a4a) }
    p("pitcher_plant_top") { t in t.clearAlpha(); t.disc(7.5, 8, 4, 0x4a9ab0); t.rect(5, 3, 10, 8, 0x4a9ab0); t.hline(3, 5, 10, 0x86c8d8); t.set(7, 2, 0x86c8d8) }
    p("brown_mushroom") { t in t.clearAlpha(); t.vline(7, 9, 15, 0xc8bca8); t.disc(7.5, 7, 3, 0x9a7050); t.hline(9, 5, 10, 0x9a7050) }
    p("red_mushroom") { t in t.clearAlpha(); t.vline(7, 10, 15, 0xe0d8c8); t.disc(7.5, 7, 3.4, 0xd03030); t.set(6, 6, 0xf0f0e8); t.set(9, 8, 0xf0f0e8) }
    p("crimson_fungus") { t in t.clearAlpha(); t.vline(7, 9, 15, 0x9a4a4a); t.disc(7.5, 7, 3, 0xb02828); t.hline(6, 6, 9, 0xd86a2a) }
    p("warped_fungus") { t in t.clearAlpha(); t.vline(7, 9, 15, 0x4a8a80); t.disc(7.5, 7, 3, 0x14a8a8); t.hline(6, 6, 9, 0xd87a3a) }
    p("crimson_roots") { t in
        t.clearAlpha()
        for i in 0..<6 {
            let x = 2 + i * 2 + Int(t.rand(i, 0) * 2)
            t.vline(x, 9 + Int(t.rand(i, 1) * 4), 15, 0xc12c4c)
        }
    }
    p("warped_roots") { t in
        t.clearAlpha()
        for i in 0..<6 {
            let x = 2 + i * 2 + Int(t.rand(i, 0) * 2)
            t.vline(x, 9 + Int(t.rand(i, 1) * 4), 15, 0x18a888)
        }
    }
    p("nether_sprouts") { t in
        t.clearAlpha()
        for i in 0..<7 {
            let x = 1 + i * 2
            t.vline(x, 12 + Int(t.rand(i, 0) * 2), 15, 0x16c0a8)
            t.set(x, 11 + Int(t.rand(i, 0) * 2), 0x5ce8cc)
        }
    }
    p("weeping_vines") { t in t.clearAlpha(); t.vline(7, 0, 15, 0x8a1c1c); t.set(6, 3, 0xb12c2c); t.set(8, 7, 0xb12c2c); t.set(6, 11, 0xb12c2c); t.set(7, 15, 0xd84c4c) }
    p("twisting_vines") { t in t.clearAlpha(); t.vline(7, 0, 15, 0x14887c); t.set(8, 2, 0x18b89c); t.set(6, 6, 0x18b89c); t.set(8, 10, 0x18b89c); t.set(7, 0, 0x2ce8c8) }
    p("sugar_cane") { t in
        t.clearAlpha()
        for x in [4, 8, 12] {
            t.vline(x, 0, 15, 0x9eb55e)
            t.vline(x + 1, 0, 15, 0x88a04e)
            for y in [4, 9, 13] { t.set(x, y, 0x6e8440) }
        }
    }
    p("cactus_side") { t in
        t.blotch(0x10821c, 0.08, 3)
        t.vline(0, 0, 15, 0x0a5c14); t.vline(15, 0, 15, 0x0a5c14)
        for x in [3, 7, 11] {
            var y = 1
            while y < 16 { t.set(x, y, 0xd8e8b0); y += 3 }
        }
    }
    p("cactus_top") { t in t.blotch(0x14942a, 0.07, 3); t.border(0x0a5c14); t.speckle(0xd8e8b0, 6) }
    p("cactus_bottom") { t in t.blotch(0x0e7018, 0.07, 3) }
    p("bamboo") { t in
        t.clearAlpha()
        t.vline(6, 0, 15, 0x82a83c); t.vline(7, 0, 15, 0x94c046); t.vline(8, 0, 15, 0x82a83c)
        for y in [3, 8, 13] { t.hline(y, 6, 8, 0x5c7e2a) }
        t.set(9, 4, 0x6e9434); t.set(10, 3, 0x6e9434)
    }
    p("vine") { t in
        t.clearAlpha()
        for i in 0..<24 {
            let x = Int(t.rand(i, 0) * 16), y = Int(t.rand(i, 1) * 16)
            t.set(x, y, shade(0x8e8e8e, 0.8 + t.rand(i, 2) * 0.4))
            if t.rand(i, 3) < 0.6 { t.set(x, min(15, y + 1), 0x7a7a7a) }
        }
        t.vline(4, 0, 15, 0x868686); t.vline(11, 0, 13, 0x808080)
    }
    p("glow_lichen") { t in
        t.clearAlpha()
        for i in 0..<22 {
            let x = Int(t.rand(i, 0) * 16), y = Int(t.rand(i, 1) * 16)
            t.set(x, y, 0x6f8a84, 220)
            if t.rand(i, 2) < 0.5 { t.set(x + 1, y, 0x90b8ae, 220) }
        }
        t.speckle(0xc8e8dc, 8)
    }
    p("sculk_vein") { t in
        t.clearAlpha()
        for i in 0..<20 {
            let x = Int(t.rand(i, 0) * 16), y = Int(t.rand(i, 1) * 16)
            t.set(x, y, 0x0c2330, 230)
            if t.rand(i, 2) < 0.5 { t.set(x + 1, y, 0x16424e, 230) }
        }
        t.speckle(0x2ce8e8, 4)
    }
    p("lily_pad") { t in t.clearAlpha(); t.disc(7.5, 7.5, 6, 0x208030); t.rect(8, 1, 14, 7, 0x000000, 0); t.set(5, 5, 0x2ca040); t.set(9, 10, 0x2ca040) }
    p("seagrass") { t in
        t.clearAlpha()
        for x in [3, 7, 11] {
            for y in 4..<16 {
                let wob = Int((Foundation.sin(Double(y) * 0.8 + Double(x)) * 1.2).rounded(.down))
                t.set(x + wob, y, y % 3 == 0 ? 0x4a9a28 : 0x3f8a20)
            }
        }
    }
    p("tall_seagrass_bottom") { t in paintInto(t, "seagrass") }
    p("tall_seagrass_top") { t in
        t.clearAlpha()
        for x in [4, 8, 12] {
            for y in 8..<16 {
                let wob = Int((Foundation.sin(Double(y) * 0.7 + Double(x)) * 1.4).rounded(.down))
                t.set(x + wob, y, 0x3f8a20)
            }
            t.set(x, 7, 0x5cb434)
        }
    }
    p("kelp") { t in t.clearAlpha(); t.vline(7, 2, 15, 0x3a7a1e); t.set(6, 4, 0x4f9a28); t.set(8, 7, 0x4f9a28); t.set(6, 10, 0x4f9a28); t.set(7, 1, 0x68b83a) }
    p("kelp_plant") { t in t.clearAlpha(); t.vline(7, 0, 15, 0x3a7a1e); t.set(6, 2, 0x4f9a28); t.set(8, 5, 0x4f9a28); t.set(6, 9, 0x4f9a28); t.set(8, 13, 0x4f9a28) }
    p("sea_pickle") { t in t.clearAlpha(); t.rect(6, 8, 9, 15, 0x5a6a28); t.rect(7, 6, 8, 8, 0x6e8030); t.set(7, 5, 0x9ab84a); t.set(8, 5, 0x9ab84a) }
    p("spore_blossom") { t in t.clearAlpha(); t.disc(7.5, 7.5, 5, 0xd667a8); t.disc(7.5, 7.5, 2, 0x68c860); t.set(2, 2, 0xe88ac8); t.set(13, 3, 0xe88ac8); t.set(3, 13, 0xe88ac8) }
    p("hanging_roots") { t in
        t.clearAlpha()
        for x in [3, 6, 9, 12] { t.vline(x, 0, 8 + Int(t.rand(x, 0) * 6), 0xa3835c) }
    }
    p("big_dripleaf") { t in
        t.fill(0x8e8e8e)
        t.border(0x787878)
        t.set(0, 0, 0x000000, 0); t.set(15, 0, 0x000000, 0)
        for i in 0..<5 { t.set(7 + Int(t.rand(i, 0) * 2), 3 + i * 2, 0x6e6e6e) }
    }
    p("big_dripleaf_stem") { t in t.clearAlpha(); t.vline(7, 0, 15, 0x8e8e8e); t.vline(8, 0, 15, 0x7a7a7a) }
    p("small_dripleaf_top") { t in t.clearAlpha(); t.disc(7.5, 6, 4, 0x8e8e8e); t.vline(7, 9, 15, 0x7a7a7a) }
    p("small_dripleaf_bottom") { t in t.clearAlpha(); t.vline(7, 0, 15, 0x7a7a7a); t.set(6, 4, 0x8e8e8e) }
    p("moss_block") { t in t.blotch(0x586e2e, 0.11, 2); t.speckle(0x6e8a3a, 14) }
    p("pink_petals") { t in
        t.clearAlpha()
        for i in 0..<7 {
            let x = 1 + Int(t.rand(i, 0) * 13), y = 1 + Int(t.rand(i, 1) * 13)
            t.disc(Double(x), Double(y), 1.3, 0xf0b8d0)
            t.set(x, y, 0xf8d8e4)
        }
    }
    p("azalea") { t in t.blotch(0x5e7c2a, 0.12, 2); t.speckle(0x76a032, 10) }
    p("flowering_azalea") { t in t.blotch(0x5e7c2a, 0.12, 2); t.speckle(0xd667c8, 8) }
    p("cave_vines") { t in t.clearAlpha(); t.vline(7, 0, 15, 0x5a7a2e); t.set(6, 4, 0x6e9438); t.set(8, 9, 0x6e9438) }
    p("cave_vines_lit") { t in paintInto(t, "cave_vines"); t.set(5, 6, 0xffb83c); t.set(9, 11, 0xffb83c); t.set(7, 14, 0xffd86a) }
    p("cave_vines_plant") { t in paintInto(t, "cave_vines") }
    p("cave_vines_plant_lit") { t in paintInto(t, "cave_vines_lit") }
    rp("^sweet_berry_bush_stage(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        let c = 0x3f6a26
        for i in 0..<(12 + stage * 4) {
            let x = 2 + Int(t.rand(i, 0) * 12), y = 4 + Int(t.rand(i, 1) * 11)
            t.set(x, y, shade(c, 0.85 + t.rand(i, 2) * 0.35))
        }
        if stage >= 2 {
            for i in 0..<(3 + stage) {
                t.set(3 + Int(t.rand(i, 5) * 10), 5 + Int(t.rand(i, 6) * 9), 0xd03048)
            }
        }
    }

    // --- crops ---
    rp("^wheat_stage(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        let c = mixC(0x3fa82e, 0xd8c054, Double(stage) / 7)
        let h = 4 + Double(stage) * 1.4
        for x in [2, 5, 8, 11, 14] {
            t.vline(x, Int((16 - h).rounded(.down)), 15, c)
            if stage >= 4 {
                t.set(x, Int((15 - h).rounded(.down)), shade(c, 1.15))
                t.set(x - 1, Int((16 - h).rounded(.down)), shade(c, 0.9))
            }
        }
    }
    rp("^(carrots|potatoes)_stage(\\d)$") { t, m in
        let stage = Int(m[2]!)!
        t.clearAlpha()
        let green = m[1] == "carrots" ? 0x2c8a1e : 0x3c9a2a
        let h = 3 + stage * 3
        for x in [3, 7, 11] {
            var y = 0
            while y < h && y < 12 {
                t.set(x + (y % 2), 15 - y, green)
                y += 1
            }
            if stage == 3 && m[1] == "carrots" { t.set(x, 15, 0xe87a2c) }
        }
    }
    rp("^beetroots_stage(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        for x in [3, 7, 11] {
            let h = 2 + stage * 2
            var y = 0
            while y < h && y < 9 {
                t.set(x + (y % 2), 15 - y, 0x3c7a3c)
                y += 1
            }
            if stage >= 3 { t.set(x, 15, 0xa82a4a) }
        }
    }
    rp("^torchflower_crop_stage(\\d)$") { t, m in
        t.clearAlpha()
        t.vline(7, 9, 15, 0x4f8f2e)
        if m[1] == "1" { t.disc(7.5, 7, 2, 0xc86428) }
    }
    rp("^stem_stage(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        let c = 0x9ab43c
        let h = 2 + Double(stage) * 1.7
        var y = 0
        while Double(y) < h && y < 15 {
            t.set(7 + (y % 2), 15 - y, shade(c, 1 - Double(y) * 0.02))
            y += 1
        }
    }
    p("attached_stem") { t in
        t.clearAlpha()
        for y in 8..<16 { t.set(7, y, 0x86a032) }
        t.hline(8, 7, 13, 0x86a032)
    }
    rp("^nether_wart_stage(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        for i in 0..<(6 + stage * 5) {
            let x = 1 + Int(t.rand(i, 0) * 14), y = 9 - stage + Int(t.rand(i, 1) * Double(6 + stage))
            t.set(x, min(15, y + 6), 0xa01818)
            if t.rand(i, 2) < 0.4 { t.set(x, min(15, y + 7), 0xc23030) }
        }
    }
    p("melon_side") { t in t.blotch(0x71aa22, 0.08, 2); for x in [2, 6, 10, 14] { t.vline(x, 0, 15, 0x5a8c1a) }; t.speckle(0x9ec83c, 10) }
    p("melon_top") { t in t.blotch(0x7ab426, 0.08, 2); t.disc(7.5, 7.5, 2, 0x5a8c1a) }
    p("pumpkin_side") { t in
        t.blotch(0xd87e1c, 0.07, 2)
        for x in [3, 8, 13] { t.vline(x, 1, 14, 0xb8650f) }
        t.hline(0, 0, 15, 0xb8650f); t.hline(15, 0, 15, 0xb8650f)
    }
    p("pumpkin_top") { t in t.blotch(0xc8741a, 0.07, 2); t.disc(7.5, 7.5, 2, 0x5a7a1c); t.set(7, 7, 0x4a6516) }
    p("carved_pumpkin") { t in
        paintInto(t, "pumpkin_side")
        t.rect(3, 4, 5, 6, 0x3a2408); t.rect(10, 4, 12, 6, 0x3a2408); t.rect(5, 9, 10, 11, 0x3a2408)
        t.set(5, 9, 0xd87e1c); t.set(10, 9, 0xd87e1c); t.set(7, 11, 0xd87e1c)
    }
    p("jack_o_lantern") { t in
        paintInto(t, "pumpkin_side")
        t.rect(3, 4, 5, 6, 0xffd83c); t.rect(10, 4, 12, 6, 0xffd83c); t.rect(5, 9, 10, 11, 0xffd83c)
        t.set(5, 9, 0xd87e1c); t.set(10, 9, 0xd87e1c)
    }
    rp("^cocoa_stage(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        let c = stage == 0 ? 0x6a9a3c : stage == 1 ? 0xb8862c : 0xc06820
        let size = 3 + stage * 2
        t.rect(8 - size / 2, 4, 8 + size / 2 - 1, 4 + size + 1, c)
        t.vline(7, 0, 3, 0x5a7a2c)
        t.rect(8 - size / 2, 4, 8 + size / 2 - 1, 4, shade(c, 1.15))
    }

    // --- mushroom blocks ---
    p("brown_mushroom_block") { t in t.blotch(0x946848, 0.07, 4); t.border(shade(0x946848, 0.88)) }
    p("red_mushroom_block") { t in t.blotch(0xb82c2a, 0.07, 4); t.speckle(0xf0e8dc, 12) }
    p("mushroom_stem") { t in t.blotch(0xd8d2c4, 0.05, 4); for x in [2, 6, 10, 14] { t.vline(x, 0, 15, shade(0xd8d2c4, 0.9)) } }

    // --- functional blocks ---
    p("crafting_table_top") { t in paintInto(t, "oak_planks"); t.border(0x6a5530); t.rect(3, 3, 12, 12, shade(C_OAK, 1.05)); t.rect(4, 4, 11, 11, shade(C_OAK, 0.95)) }
    p("crafting_table_side") { t in paintInto(t, "oak_planks"); t.rect(3, 3, 7, 8, 0x7a5c34); t.rect(9, 3, 12, 8, 0x9a7a48) }
    p("crafting_table_front") { t in paintInto(t, "oak_planks"); t.rect(3, 3, 6, 7, 0x9a7a48); t.rect(9, 4, 12, 8, 0x7a5c34) }
    p("furnace_top") { t in t.blotch(shade(C_STONE, 0.95), 0.08); t.border(shade(C_STONE, 0.8)) }
    p("furnace_side") { t in t.blotch(C_STONE, 0.08); t.border(shade(C_STONE, 0.75)); t.hline(8, 1, 14, shade(C_STONE, 0.85)) }
    p("furnace_front") { t in paintInto(t, "furnace_side"); t.rect(4, 8, 11, 14, 0x202020); t.rect(5, 6, 10, 7, 0x303030) }
    p("furnace_front_lit") { t in
        paintInto(t, "furnace_side")
        t.rect(4, 8, 11, 14, 0x301808); t.rect(5, 6, 10, 7, 0x303030)
        for x in 4...11 {
            let h = Int(t.rand(x, 0) * 3)
            t.vline(x, 11 - h, 14, x % 2 != 0 ? 0xff9a2c : 0xffc84c)
        }
    }
    p("blast_furnace_top") { t in t.blotch(0x585858, 0.07); t.border(0x3c3c3c) }
    p("blast_furnace_side") { t in t.blotch(0x676767, 0.07); t.border(0x444444); t.hline(7, 1, 14, 0x4c4c4c) }
    p("blast_furnace_front") { t in paintInto(t, "blast_furnace_side"); t.rect(4, 9, 11, 13, 0x18181c); t.rect(3, 4, 12, 6, 0x303034) }
    p("blast_furnace_front_lit") { t in
        paintInto(t, "blast_furnace_side")
        t.rect(4, 9, 11, 13, 0x401c08)
        for x in 4...11 { t.set(x, 12 + (x % 2), 0xffb84c) }
        t.rect(3, 4, 12, 6, 0x303034)
    }
    p("smoker_top") { t in t.blotch(0x5c5347, 0.08); t.border(0x423a30) }
    p("smoker_bottom") { t in t.blotch(0x55493c, 0.08) }
    p("smoker_side") { t in t.blotch(0x6a5d4c, 0.08); t.border(0x4a4034); for y in [4, 11] { t.hline(y, 1, 14, 0x57493a) } }
    p("smoker_front") { t in paintInto(t, "smoker_side"); t.rect(4, 8, 11, 14, 0x241a10); t.rect(5, 5, 10, 7, 0x38302a) }
    p("smoker_front_lit") { t in
        paintInto(t, "smoker_side")
        t.rect(4, 8, 11, 14, 0x38200a)
        for x in 5...10 { t.set(x, 12 - (x % 2), 0xffa83c) }
        t.rect(5, 5, 10, 7, 0x38302a)
    }
    p("chest_side") { t in t.planks(0x9a6b35); t.border(0x5c3c1c); t.rect(6, 7, 9, 10, 0x6a6a6a); t.rect(7, 7, 8, 9, 0x8a8a8a) }
    p("ender_chest_side") { t in t.blotch(0x10211e, 0.1, 3); t.border(0x081210); t.rect(6, 7, 9, 10, 0x1c5c50); t.set(7, 8, 0x39e8c8); t.set(8, 8, 0x39e8c8) }
    p("barrel_side") { t in t.planks(0x8a6234); for y in [2, 13] { t.hline(y, 0, 15, 0x4c3418) } }
    p("barrel_top") { t in t.blotch(0x9a7040, 0.08); t.border(0x4c3418); t.rect(4, 4, 11, 11, shade(0x9a7040, 0.88)); t.hline(7, 2, 13, 0x6a4c24) }
    p("barrel_top_open") { t in paintInto(t, "barrel_top"); t.rect(3, 3, 12, 12, 0x241808) }
    p("barrel_bottom") { t in t.blotch(0x84602e, 0.08); t.border(0x4c3418) }
    p("bookshelf") { t in
        paintInto(t, "oak_planks")
        let bookCols = [0xc23a3a, 0x3a64c2, 0x3aa44a, 0xc2a43a, 0x8a4ac2, 0xd8d8d8]
        for row in [2, 9] {
            t.rect(1, row, 14, row + 4, 0x3c2c14)
            var x = 1
            while x <= 13 {
                let w = 1 + Int(t.rand(x, row) * 2)
                let c = bookCols[Int(t.rand(x, row, 3) * Double(bookCols.count))]
                var dx = 0
                while dx < w && x + dx <= 14 {
                    t.vline(x + dx, row, row + 4, dx == 0 ? c : shade(c, 0.85))
                    dx += 1
                }
                if t.rand(x, row, 5) < 0.18 { t.rect(x, row, x + w - 1, row + 4, 0x3c2c14) }
                x += w
            }
        }
    }
    p("chiseled_bookshelf_top") { t in paintInto(t, "oak_planks"); t.border(0x6a5530) }
    p("chiseled_bookshelf_side") { t in paintInto(t, "oak_planks"); t.rect(2, 2, 13, 13, 0x8a6a3c) }
    p("chiseled_bookshelf_empty") { t in paintInto(t, "oak_planks"); t.rect(1, 2, 14, 6, 0x3c2c14); t.rect(1, 9, 14, 13, 0x3c2c14) }
    p("chiseled_bookshelf_occupied") { t in paintInto(t, "bookshelf") }
    p("enchanting_table_top") { t in
        t.blotch(0x2a2025, 0.08); t.border(0x4a3a42)
        let c = 0xd84a4a
        t.rect(3, 3, 12, 12, 0x1c1418)
        t.disc(7.5, 7.5, 3, c)
        t.disc(7.5, 7.5, 1.4, 0xf8f8f0)
    }
    p("enchanting_table_side") { t in t.blotch(0x2a2025, 0.07); t.hline(0, 0, 15, 0xc8b8c8); t.rect(3, 5, 5, 8, 0xc23a3a); t.rect(9, 6, 12, 9, 0xc23a3a); t.speckle(0x8862bf, 6) }
    p("enchanting_table_bottom") { t in t.blotch(0x1c1418, 0.06) }
    p("anvil_top") { t in t.blotch(0x404040, 0.06); t.rect(2, 4, 13, 11, 0x4c4c4c); t.border(0x2c2c2c) }
    p("chipped_anvil_top") { t in paintInto(t, "anvil_top"); crack(t, 0x252525) }
    p("damaged_anvil_top") { t in paintInto(t, "anvil_top"); crack(t, 0x202020); t.rect(7, 2, 10, 5, 0x252525) }
    p("anvil_side") { t in t.blotch(0x3c3c3c, 0.07); t.rect(0, 0, 15, 3, 0x484848); t.rect(4, 4, 11, 9, 0x333333); t.rect(2, 10, 13, 15, 0x424242) }
    p("grindstone_side") { t in t.blotch(0x8a8a8a, 0.09); t.disc(7.5, 7.5, 6, 0x767676); t.disc(7.5, 7.5, 2, 0x5c5c5c) }
    p("grindstone_pivot") { t in t.blotch(0x767676, 0.08); t.rect(5, 5, 10, 10, 0x6a4c24) }
    p("stonecutter_top") { t in t.blotch(shade(C_STONE, 0.96), 0.07); t.border(shade(C_STONE, 0.8)); t.hline(7, 1, 14, 0xb8b8c0); t.hline(8, 1, 14, 0x8a8a92) }
    p("stonecutter_side") { t in t.blotch(C_STONE, 0.07); t.rect(0, 8, 15, 15, shade(C_STONE, 0.9)); t.hline(0, 0, 15, 0x9a9aa2) }
    p("stonecutter_bottom") { t in t.blotch(shade(C_STONE, 0.9), 0.07) }
    p("smithing_table_top") { t in t.blotch(0x3a3440, 0.06); t.border(0x241f2c); t.rect(3, 3, 7, 7, 0x57505e); t.rect(9, 9, 12, 12, 0x6c6474) }
    p("smithing_table_front") { t in t.blotch(0x4a4450, 0.07); t.hline(0, 0, 15, 0x241f2c); t.rect(3, 4, 6, 8, 0xc8c8d0); t.rect(9, 5, 12, 9, 0x8a8a94) }
    p("smithing_table_side") { t in t.blotch(0x4a4450, 0.07); t.hline(0, 0, 15, 0x241f2c); t.rect(2, 9, 13, 15, 0x3c3030) }
    p("smithing_table_bottom") { t in t.blotch(0x3c3030, 0.07) }
    p("fletching_table_top") { t in t.blotch(0xc8b88a, 0.06); t.border(0xa89868); t.rect(3, 3, 12, 5, 0xe0d8b8) }
    p("fletching_table_front") { t in
        t.blotch(0xd0c094, 0.06)
        t.px(["  F  ", " FFF ", "FFFFF", "  |  ", "  |  "], ["F": 0xe8e8e8, "|": 0x8a6a3c], 5, 4)
    }
    p("fletching_table_side") { t in t.blotch(0xd0c094, 0.06); t.rect(3, 4, 5, 11, 0xb89858); t.rect(9, 4, 12, 7, 0xb89858) }
    p("cartography_table_top") { t in t.blotch(0x6a5538, 0.06); t.rect(2, 2, 13, 13, 0xd8cfa8); t.rect(4, 4, 8, 8, 0xb8a878); t.hline(6, 4, 11, 0x8a7a52) }
    p("cartography_table_side") { t in t.blotch(0x7a6240, 0.07); t.hline(0, 0, 15, 0x584830); t.rect(3, 4, 12, 10, 0x9a8a62) }
    p("loom_top") { t in t.blotch(0xb89868, 0.06); t.rect(2, 2, 13, 13, 0xe8e0d0); for x in [4, 7, 10] { t.vline(x, 2, 13, 0xc8b8a0) } }
    p("loom_front") { t in t.blotch(0x9a7a4c, 0.07); t.rect(2, 2, 13, 8, 0xd8d0c0); for y in [3, 5, 7] { t.hline(y, 2, 13, 0xb8a890) } }
    p("loom_side") { t in t.blotch(0x9a7a4c, 0.07); t.rect(3, 2, 12, 8, 0x7a5c34) }
    p("loom_bottom") { t in t.blotch(0x8a6a40, 0.07) }
    p("composter_top") { t in paintInto(t, "oak_planks"); t.rect(2, 2, 13, 13, 0x241808) }
    p("composter_side") { t in t.planks(0x8a6a3a); for x in [0, 5, 10, 15] { t.vline(x, 0, 15, 0x5c4420) } }
    p("composter_bottom") { t in t.blotch(0x6a4e26, 0.09) }
    p("composter_compost") { t in t.blotch(0x4c3a1a, 0.12, 2); t.speckle(0x6a5226, 14); t.speckle(0x3c8a2a, 6) }
    p("composter_ready") { t in paintInto(t, "composter_compost"); t.speckle(0xc8c8c8, 8) }
    p("cauldron_side") { t in t.blotch(0x3a3a3a, 0.07); t.border(0x262626); t.rect(0, 0, 2, 15, 0x303030); t.rect(13, 0, 15, 15, 0x303030); t.hline(3, 0, 15, 0x4a4a4a) }
    p("cauldron_top") { t in t.blotch(0x303030, 0.06); t.rect(2, 2, 13, 13, 0x1c1c1c) }
    p("cauldron_bottom") { t in t.blotch(0x2c2c2c, 0.06) }
    p("brewing_stand") { t in t.clearAlpha(); t.vline(7, 2, 13, 0x8a8a52); t.set(7, 1, 0xd8c83c); t.rect(2, 12, 5, 14, 0x5c5c5c); t.rect(10, 12, 13, 14, 0x5c5c5c) }
    p("jukebox_top") { t in t.planks(0x6a4226); t.disc(7.5, 7.5, 4.5, 0x1c1410); t.disc(7.5, 7.5, 1.5, 0xc8a84a) }
    p("jukebox_side") { t in t.planks(0x6a4226); t.border(0x44290f); t.hline(11, 2, 13, 0x2a1a0c) }
    p("note_block") { t in t.planks(0x6a4226); t.border(0x44290f); t.disc(7.5, 7.5, 3, 0x2a1a0c); t.set(7, 7, 0xd8c83c) }
    p("lectern_top") { t in t.planks(0x9a7444); t.rect(3, 3, 12, 11, 0xe8e0c8); t.hline(7, 4, 11, 0xb8a880) }
    p("lectern_side") { t in t.planks(0x8a6a3c); t.rect(4, 0, 11, 4, 0x7a5a30) }
    p("bell_body") { t in t.blotch(0xe8c84a, 0.07, 3); t.hline(11, 0, 15, 0xb89a2c); t.border(0xc8a834) }
    p("beacon") { t in t.fill(0x18403c); t.border(0x0e2624); t.rect(2, 2, 13, 13, 0x2a8a80); t.rect(4, 4, 11, 11, 0x4ee8dc); t.rect(6, 6, 9, 9, 0xc8fff8) }
    p("conduit") { t in t.blotch(0x9a8a6a, 0.08); t.disc(7.5, 7.5, 3.5, 0x18403c); t.disc(7.5, 7.5, 1.5, 0x4ee8dc) }
    p("lodestone_top") { t in t.blotch(0x6a6a72, 0.07); t.border(0x44444c); t.rect(4, 4, 11, 11, 0x52525a); t.rect(6, 6, 9, 9, 0x7a7a84) }
    p("lodestone_side") { t in t.blotch(0x62626a, 0.07); t.border(0x44444c) }
    p("respawn_anchor_top") { t in t.blotch(0x241038, 0.1); t.border(0x3c1c5c); t.rect(3, 3, 12, 12, 0x4a1d80); t.speckle(0x8a3cf0, 14); t.speckle(0xc88af8, 6) }
    p("respawn_anchor_top_off") { t in t.blotch(0x241038, 0.1); t.border(0x3c1c5c); t.rect(3, 3, 12, 12, 0x180a28) }
    p("respawn_anchor_side") { t in
        t.blotch(0x1c1024, 0.09)
        t.hline(0, 0, 15, 0x3c1c5c)
        t.rect(0, 8, 15, 15, 0x14091c)
        var x = 1
        while x < 15 { t.set(x, 5, 0x8a3cf0); x += 3 }
    }
    p("respawn_anchor_bottom") { t in t.blotch(0x14091c, 0.08) }
    p("flower_pot") { t in t.clearAlpha(); t.rect(5, 10, 10, 15, 0x9a5838); t.rect(6, 10, 9, 11, 0x3c2410); t.rect(4, 9, 11, 9, 0xa86040) }
    p("decorated_pot_side") { t in t.blotch(0x9a5838, 0.08); t.border(0x7a4228); t.hline(2, 1, 14, 0xb87048); t.rect(4, 5, 11, 12, 0x8a4c30) }
    p("decorated_pot_top") { t in t.blotch(0x9a5838, 0.08); t.disc(7.5, 7.5, 4, 0x3c2410); t.border(0x7a4228) }
    p("spawner") { t in
        t.fill(0x1a2c38); t.border(0x0c161e)
        var y = 2
        while y < 14 {
            var x = 2
            while x < 14 { t.rect(x, y, x + 1, y + 1, 0x2c4456); x += 3 }
            y += 3
        }
        t.speckle(0x3c5c74, 8)
    }
    p("slime_block") { t in t.fill(0x6fc05c, 200); t.border(shade(0x6fc05c, 0.85)); t.rect(4, 4, 11, 11, 0x84d46e, 220) }
    p("honey_block") { t in t.fill(0xf0a83c, 220); t.border(0xd88c24); t.rect(4, 4, 11, 11, 0xf8c05c, 235) }
    p("honeycomb_block") { t in
        t.fill(0xe89a2c)
        for row in 0..<4 {
            for col in 0..<4 {
                let x = col * 4 + (row % 2) * 2, y = row * 4
                t.disc(Double(x) + 1.5, Double(y) + 1.5, 1.6, 0xc87818)
                t.set(x + 1, y + 1, 0xf8c860)
            }
        }
    }
    p("bee_nest_front") { t in t.blotch(0xc8a05c, 0.09, 2); for y in [2, 7, 12] { t.hline(y, 0, 15, 0xa8824a) }; t.rect(6, 9, 9, 12, 0x3c2c10) }
    p("bee_nest_side") { t in t.blotch(0xc8a05c, 0.09, 2); for y in [2, 7, 12] { t.hline(y, 0, 15, 0xa8824a) } }
    p("bee_nest_top") { t in t.blotch(0xd8b878, 0.08, 2); t.disc(7.5, 7.5, 3.5, 0xb8964e) }
    p("bee_nest_bottom") { t in t.blotch(0xb8965c, 0.08, 2) }
    p("beehive_front") { t in paintInto(t, "oak_planks"); t.rect(6, 9, 9, 12, 0x3c2c10); t.hline(7, 0, 15, 0x6a5530) }
    p("beehive_side") { t in paintInto(t, "oak_planks"); t.hline(7, 0, 15, 0x6a5530) }
    p("beehive_end") { t in paintInto(t, "oak_planks"); t.border(0x6a5530) }
    p("hay_block_side") { t in
        t.blotch(0xc8a834, 0.12, 2)
        for y in [5, 11] { t.hline(y, 0, 15, 0x8a701c) }
        for i in 0..<14 { t.set(Int(t.rand(i, 0) * 16), Int(t.rand(i, 1) * 16), 0xe0c454) }
    }
    p("hay_block_top") { t in t.blotch(0xb89a2c, 0.1, 2); t.border(0x8a701c); t.rect(5, 5, 10, 10, 0xc8a834) }
    p("target_side") { t in t.blotch(0xe0d8c8, 0.05); t.disc(7.5, 7.5, 6, 0xd03030); t.disc(7.5, 7.5, 4, 0xe0d8c8); t.disc(7.5, 7.5, 2, 0xd03030) }
    p("target_top") { t in paintInto(t, "target_side") }
    p("tnt_side") { t in
        t.fill(0xc8412e)
        for y in [0, 1, 14, 15] { t.hline(y, 0, 15, 0xa83020) }
        t.rect(2, 5, 13, 9, 0xe8e0d0)
        t.px(["### # # ###", " #  ##   # ", " #  # #  # "], ["#": 0x202020], 2, 6)
    }
    p("tnt_top") { t in t.fill(0xc8412e); t.disc(7.5, 7.5, 3, 0x8a2418); t.set(7, 7, 0x3c1008); t.set(8, 8, 0x3c1008) }
    p("tnt_bottom") { t in t.blotch(0xa83020, 0.07) }
    p("cake_top") { t in t.fill(0xf0e8e0); t.speckle(0xd03030, 8); t.border(0xe0d0c8) }
    p("cake_side") { t in t.rect(0, 0, 15, 7, 0xf0e8e0); t.rect(0, 8, 15, 15, 0xa86838); t.hline(7, 0, 15, 0xd84848); t.hline(8, 0, 15, 0xc84040) }
    p("cake_bottom") { t in t.blotch(0xa86838, 0.06) }

    // --- torches / lanterns ---
    p("torch") { t in t.clearAlpha(); t.vline(7, 6, 15, 0x7a5c34); t.vline(8, 6, 15, 0x6a4c2a); t.rect(7, 4, 8, 5, 0xffd75c); t.set(7, 3, 0xffaa2c); t.set(8, 3, 0xff8a1c) }
    p("soul_torch") { t in t.clearAlpha(); t.vline(7, 6, 15, 0x7a5c34); t.vline(8, 6, 15, 0x6a4c2a); t.rect(7, 4, 8, 5, 0x5ce8e8); t.set(7, 3, 0x2cb8c8); t.set(8, 3, 0x1c98b0) }
    p("redstone_torch") { t in t.clearAlpha(); t.vline(7, 6, 15, 0x7a5c34); t.vline(8, 6, 15, 0x6a4c2a); t.rect(7, 4, 8, 5, 0xff3c2c); t.set(7, 3, 0xffa89c) }
    p("redstone_torch_off") { t in t.clearAlpha(); t.vline(7, 6, 15, 0x7a5c34); t.vline(8, 6, 15, 0x6a4c2a); t.rect(7, 4, 8, 5, 0x6a1410) }
    p("lantern") { t in
        t.clearAlpha()
        t.rect(5, 6, 10, 13, 0x4a4a52); t.rect(6, 7, 9, 12, 0xffc84c); t.rect(6, 4, 9, 5, 0x3a3a42)
        t.set(7, 2, 0x2c2c34); t.set(8, 3, 0x2c2c34); t.set(5, 6, 0x3a3a42); t.set(10, 6, 0x3a3a42)
    }
    p("soul_lantern") { t in paintInto(t, "lantern"); t.rect(6, 7, 9, 12, 0x4ce0e0) }
    p("chain") { t in t.clearAlpha(); t.rect(6, 0, 7, 3, 0x44444c); t.rect(8, 3, 9, 7, 0x52525a); t.rect(6, 7, 7, 11, 0x44444c); t.rect(8, 11, 9, 15, 0x52525a) }
    p("campfire_log") { t in t.planks(0x6a4a26); t.rect(0, 6, 15, 9, 0x3c2a12) }
    p("soul_campfire_log") { t in t.planks(0x6a4a26); t.rect(0, 6, 15, 9, 0x1c3a3c) }
    p("campfire_fire") { t in
        t.clearAlpha()
        for x in 0..<16 {
            let h = 4 + Int(t.rand(x, 0) * 9)
            var y = 15
            while y > 15 - h {
                let f = Double(15 - y) / Double(h)
                t.set(x, y, f < 0.4 ? 0xff8a1c : f < 0.7 ? 0xffc23c : 0xfff09c)
                y -= 1
            }
        }
    }
    p("soul_campfire_fire") { t in
        t.clearAlpha()
        for x in 0..<16 {
            let h = 4 + Int(t.rand(x, 0) * 9)
            var y = 15
            while y > 15 - h {
                let f = Double(15 - y) / Double(h)
                t.set(x, y, f < 0.4 ? 0x1c98b0 : f < 0.7 ? 0x4ce0e0 : 0xc8fcfc)
                y -= 1
            }
        }
    }
    p("fire") { t in
        t.clearAlpha()
        for x in 0..<16 {
            let h = 6 + Int(t.rand(x, 0) * 10)
            var y = 15
            while y > 15 - h {
                let f = Double(15 - y) / Double(h)
                if t.rand(x, y) < 0.85 { t.set(x, y, f < 0.35 ? 0xff6a0c : f < 0.65 ? 0xffa01c : 0xffe05c) }
                y -= 1
            }
        }
    }
    p("soul_fire") { t in
        t.clearAlpha()
        for x in 0..<16 {
            let h = 6 + Int(t.rand(x, 0) * 10)
            var y = 15
            while y > 15 - h {
                let f = Double(15 - y) / Double(h)
                if t.rand(x, y) < 0.85 { t.set(x, y, f < 0.35 ? 0x0c6a8a : f < 0.65 ? 0x2cb8c8 : 0x9cf0f0) }
                y -= 1
            }
        }
    }

    // --- redstone ---
    p("redstone_dust_dot") { t in t.clearAlpha(); t.disc(7.5, 7.5, 2.4, 0xff2200); t.set(7, 7, 0xff6644) }
    p("redstone_dust_line") { t in t.clearAlpha(); t.rect(0, 7, 15, 8, 0xff2200); t.hline(7, 0, 15, 0xdd1c00) }
    p("repeater") { t in t.blotch(0x8a8a92, 0.06); t.border(0x6a6a72); t.rect(7, 2, 8, 3, 0x6a1410); t.rect(7, 9, 8, 10, 0x6a1410); t.hline(7, 2, 13, 0x3c3c44) }
    p("repeater_on") { t in t.blotch(0x9a9aa2, 0.06); t.border(0x6a6a72); t.rect(7, 2, 8, 3, 0xff3c2c); t.rect(7, 9, 8, 10, 0xff3c2c); t.hline(7, 2, 13, 0x3c3c44) }
    p("comparator") { t in
        t.blotch(0x8a8a92, 0.06); t.border(0x6a6a72)
        for (x, y) in [(3, 11), (12, 11), (7, 3)] { t.rect(x, y, x + 1, y + 1, 0x6a1410) }
    }
    p("comparator_on") { t in
        t.blotch(0x9a9aa2, 0.06); t.border(0x6a6a72)
        for (x, y) in [(3, 11), (12, 11), (7, 3)] { t.rect(x, y, x + 1, y + 1, 0xff3c2c) }
    }
    p("lever") { t in t.clearAlpha(); t.rect(4, 10, 11, 15, 0x6a6a6a); t.vline(7, 2, 9, 0x8a6a3c); t.vline(8, 2, 9, 0x7a5c34); t.set(7, 1, 0xc84040); t.set(8, 1, 0xc84040) }
    p("tripwire_hook") { t in t.clearAlpha(); t.vline(7, 8, 15, 0x8a8a8a); t.rect(6, 4, 9, 7, 0x9a7444); t.set(7, 2, 0x6a6a6a); t.set(8, 3, 0x6a6a6a) }
    p("tripwire") { t in t.clearAlpha(); t.hline(7, 0, 15, 0xc8c8c8) }
    p("observer_top") { t in t.blotch(0x6a6a6a, 0.07); t.rect(2, 6, 13, 9, 0x3c3c3c) }
    p("observer_side") { t in t.blotch(0x5c5c5c, 0.07); t.hline(7, 0, 15, 0x444444) }
    p("observer_front") { t in t.blotch(0x6a6a6a, 0.07); t.rect(2, 2, 13, 5, 0x8a2418); t.rect(4, 3, 11, 4, 0xc8412e); t.rect(2, 10, 13, 13, 0x3c3c3c) }
    p("observer_back") { t in t.blotch(0x5c5c5c, 0.07); t.rect(6, 6, 9, 9, 0x6a1410) }
    p("observer_back_lit") { t in t.blotch(0x5c5c5c, 0.07); t.rect(6, 6, 9, 9, 0xff3c2c) }
    p("dispenser_front") { t in paintInto(t, "furnace_side"); t.disc(7.5, 7.5, 4, 0x202020); t.disc(7.5, 7.5, 2.2, 0x3c3c3c) }
    p("dispenser_front_vertical") { t in paintInto(t, "furnace_top"); t.disc(7.5, 7.5, 4, 0x202020); t.disc(7.5, 7.5, 2.2, 0x3c3c3c) }
    p("dropper_front") { t in paintInto(t, "furnace_side"); t.rect(4, 4, 11, 11, 0x202020); t.rect(6, 6, 9, 9, 0x3c3c3c) }
    p("dropper_front_vertical") { t in paintInto(t, "furnace_top"); t.rect(4, 4, 11, 11, 0x202020); t.rect(6, 6, 9, 9, 0x3c3c3c) }
    p("hopper_outside") { t in t.blotch(0x3a3a3a, 0.06); t.rect(0, 10, 15, 15, 0x2c2c2c) }
    p("hopper_top") { t in t.blotch(0x3a3a3a, 0.06); t.rect(2, 2, 13, 13, 0x1c1c1c) }
    p("redstone_lamp") { t in t.blotch(0x46280e, 0.1, 2); t.rect(3, 3, 12, 12, 0x6a3c1c); t.rect(5, 5, 10, 10, 0x8a5424); t.border(0x33200c) }
    p("redstone_lamp_on") { t in t.blotch(0xa86420, 0.08, 2); t.rect(3, 3, 12, 12, 0xe8a04c); t.rect(5, 5, 10, 10, 0xffd88c); t.border(0x7a4818) }
    p("daylight_detector_top") { t in
        t.fill(0x1c2c4c); t.border(0x6a5c3c)
        var y = 2
        while y < 14 {
            var x = 2
            while x < 14 { t.rect(x, y, x + 2, y + 2, 0x2c4474); x += 4 }
            y += 4
        }
    }
    p("daylight_detector_inverted_top") { t in
        t.fill(0x4c3c2c); t.border(0x6a5c3c)
        var y = 2
        while y < 14 {
            var x = 2
            while x < 14 { t.rect(x, y, x + 2, y + 2, 0x745c44); x += 4 }
            y += 4
        }
    }
    p("daylight_detector_side") { t in t.planks(0x9a7444); t.rect(0, 0, 15, 3, 0xd8d0b8) }
    p("sculk") { t in t.blotch(0x0c2330, 0.14, 2); t.speckle(0x16424e, 16); t.speckle(0x2ce8e8, 3) }
    p("sculk_catalyst_top") { t in t.blotch(0x16424e, 0.1, 2); t.speckle(0x52e8d8, 10); t.rect(5, 5, 10, 10, 0xe8f8e0); t.rect(6, 6, 9, 9, 0xc8f0d0) }
    p("sculk_catalyst_side") { t in t.blotch(0x0c2330, 0.12, 2); t.rect(0, 0, 15, 4, 0x16424e); t.speckle(0x9cf0dc, 8) }
    p("sculk_catalyst_bottom") { t in paintInto(t, "sculk") }
    p("sculk_sensor_top") { t in t.blotch(0x0c3340, 0.1, 2); t.disc(4, 4, 1.4, 0x2ce8e8); t.disc(11, 4, 1.4, 0x2ce8e8); t.disc(4, 11, 1.4, 0x2ce8e8); t.disc(11, 11, 1.4, 0x2ce8e8) }
    p("sculk_sensor_side") { t in t.blotch(0x0c2c38, 0.1, 2); t.rect(0, 8, 15, 15, 0x0a2430) }
    p("sculk_sensor_bottom") { t in paintInto(t, "sculk") }
    p("calibrated_sculk_sensor_top") { t in paintInto(t, "sculk_sensor_top"); t.rect(6, 2, 9, 7, 0x8a62c8) }
    p("calibrated_sculk_sensor_side") { t in paintInto(t, "sculk_sensor_side"); t.rect(6, 0, 9, 4, 0x8a62c8) }
    p("sculk_shrieker_top") { t in t.blotch(0x0c2330, 0.1, 2); t.border(0xc8d0c8); t.disc(7.5, 7.5, 4, 0x041018); t.disc(7.5, 7.5, 1.8, 0x16424e) }
    p("sculk_shrieker_side") { t in t.blotch(0x10303c, 0.1, 2); t.hline(0, 0, 15, 0xc8d0c8) }
    p("sculk_shrieker_bottom") { t in paintInto(t, "sculk") }
    rp("^(rail|powered_rail|detector_rail|activator_rail)(_on)?$") { t, m in
        t.clearAlpha()
        let tie = 0x7a5c34
        for y in [1, 5, 9, 13] { t.rect(2, y, 13, y + 1, tie) }
        let railC = m[1] == "rail" ? 0x9a9a9a : m[2] != nil ? 0xd8a84c : 0x8a7a5a
        t.vline(3, 0, 15, railC); t.vline(4, 0, 15, shade(railC, 0.8))
        t.vline(11, 0, 15, railC); t.vline(12, 0, 15, shade(railC, 0.8))
        if m[1] == "detector_rail" { t.rect(6, 6, 9, 9, m[2] != nil ? 0xff5c4c : 0x6a1410) }
        if m[1] == "powered_rail" { t.hline(7, 5, 10, m[2] != nil ? 0xff3c2c : 0x6a1410) }
        if m[1] == "activator_rail" {
            t.vline(7, 2, 13, m[2] != nil ? 0xff3c2c : 0x6a1410)
            t.vline(8, 2, 13, m[2] != nil ? 0xc82c1c : 0x4a0e0a)
        }
    }

    // --- doors / trapdoors ---
    rp("^(\\w+?)_door$") { t, m in
        let wood = WOOD_COLORS[m[1] ?? ""]
        if wood == nil && m[1] != "iron" { fallbackPaint(t); return }
        let c = m[1] == "iron" ? 0xc8c8c8 : wood!.plank
        t.planks(c)
        t.border(shade(c, 0.7))
        t.rect(3, 2, 12, 6, shade(c, 0.88))
        t.rect(4, 3, 11, 5, shade(c, 1.06))
        t.rect(3, 9, 12, 13, shade(c, 0.88))
        t.rect(4, 10, 11, 12, shade(c, 1.06))
    }
    rp("^(\\w+?)_trapdoor$") { t, m in
        let wood = WOOD_COLORS[m[1] ?? ""]
        let c = m[1] == "iron" ? 0xc8c8c8 : (wood?.plank ?? 0xb8945f)
        if m[1] == "iron" {
            t.blotch(c, 0.05)
            t.border(shade(c, 0.75))
            t.rect(4, 4, 11, 11, shade(c, 0.9))
            t.rect(6, 6, 9, 9, shade(c, 1.05))
        } else {
            t.planks(c)
            t.border(shade(c, 0.7))
            t.rect(6, 2, 9, 13, shade(c, 0.85))
            t.rect(2, 6, 13, 9, shade(c, 0.85))
        }
    }

    // --- misc ---
    p("ladder") { t in
        t.clearAlpha()
        t.vline(2, 0, 15, 0x8a6a3c); t.vline(3, 0, 15, 0x7a5c34)
        t.vline(12, 0, 15, 0x8a6a3c); t.vline(13, 0, 15, 0x7a5c34)
        for y in [2, 6, 10, 14] { t.rect(4, y, 11, y + 1, 0x9a7a48) }
    }
    p("scaffolding_side") { t in
        t.clearAlpha()
        for x in [0, 1, 14, 15] { t.vline(x, 0, 15, 0xc8a85c) }
        for y in [0, 7, 15] { t.hline(y, 0, 15, 0xb8964e) }
        t.set(4, 3, 0xb8964e); t.set(8, 11, 0xb8964e)
    }
    p("scaffolding_top") { t in
        t.fill(0xc8a85c); t.border(0xa8854a)
        var i = 2
        while i < 14 { t.hline(i, 1, 14, 0xb8964e); i += 3 }
    }
    p("cobweb") { t in
        t.clearAlpha()
        let c = 0xe8e8e8
        for i in 0..<16 { t.set(i, i, c, 200); t.set(15 - i, i, c, 200) }
        t.hline(7, 1, 14, c); t.vline(7, 1, 14, c)
        for r in [4, 7] {
            t.set(7 - r, 7 - r / 2, c); t.set(7 + r, 7 - r / 2, c)
            t.set(7 - r / 2, 7 - r, c); t.set(7 + r / 2, 7 + r, c)
        }
    }
    p("pointed_dripstone") { t in
        t.clearAlpha()
        for y in 0..<16 {
            let w = max(0, 3 - y / 5)
            t.rect(7 - w, y, 8 + w, y, shade(0x866956, 0.9 + t.rand(0, y) * 0.2))
        }
    }
    p("amethyst_cluster") { t in
        t.clearAlpha()
        for (x, h) in [(3, 8), (7, 12), (11, 7), (5, 5), (13, 4)] {
            for y in 0..<h {
                t.set(x, 15 - y, y > h - 3 ? 0xc8a8e8 : 0x9a72d0)
                t.set(x + 1, 15 - y, 0x8662bf)
            }
        }
    }
    p("large_amethyst_bud") { t in
        t.clearAlpha()
        for (x, h) in [(5, 8), (9, 6)] {
            for y in 0..<h {
                t.set(x, 15 - y, 0xa886d8)
                t.set(x + 1, 15 - y, 0x8662bf)
            }
        }
    }
    p("medium_amethyst_bud") { t in
        t.clearAlpha()
        for (x, h) in [(6, 5), (10, 4)] {
            for y in 0..<h { t.set(x, 15 - y, 0xa886d8) }
        }
    }
    p("small_amethyst_bud") { t in t.clearAlpha(); t.rect(6, 13, 7, 15, 0xa886d8); t.set(10, 14, 0x9a72d0); t.set(10, 15, 0x9a72d0) }
    p("sniffer_egg") { t in t.blotch(0xb04a3c, 0.1, 3); t.speckle(0x44aa44, 10); t.border(0x8a382e) }
    p("turtle_egg") { t in t.clearAlpha(); t.disc(7.5, 9, 4.5, 0xe8e8d0); t.speckle(0x9aa86a, 6) }
    p("frogspawn") { t in
        t.clearAlpha()
        for i in 0..<9 {
            let x = 2 + Int(t.rand(i, 0) * 12), y = 2 + Int(t.rand(i, 1) * 12)
            t.disc(Double(x), Double(y), 1.6, 0x6a7a8a)
            t.set(x, y, 0x1c1c24)
        }
    }
    p("ochre_froglight_top") { t in froglight(t, 0xf8e8b0) }
    p("ochre_froglight_side") { t in froglightSide(t, 0xf8e8b0) }
    p("verdant_froglight_top") { t in froglight(t, 0xc8f0c0) }
    p("verdant_froglight_side") { t in froglightSide(t, 0xc8f0c0) }
    p("pearlescent_froglight_top") { t in froglight(t, 0xf0d8f0) }
    p("pearlescent_froglight_side") { t in froglightSide(t, 0xf0d8f0) }
    p("mangrove_roots") { t in
        t.clearAlpha()
        for i in 0..<6 {
            let x = 1 + i * 2 + Int(t.rand(i, 0) * 2)
            t.vline(x, Int(t.rand(i, 1) * 4), 15, shade(0x583c2e, 0.85 + t.rand(i, 2) * 0.3))
        }
        t.hline(15, 0, 15, 0x44291f); t.hline(3, 2, 13, 0x4c3023)
    }
    p("mangrove_propagule") { t in t.clearAlpha(); t.vline(7, 2, 12, 0x4a7c3c); t.set(7, 13, 0x6aa04c); t.set(7, 1, 0x386030) }
    p("lectern_front") { t in t.planks(0x8a6a3c) }
    p("end_gateway") { t in paintInto(t, "end_portal") }

    // --- saplings & leftover plants ---
    rp("^(\\w+?)_sapling$") { t, m in
        let key = m[1] ?? ""
        let c = LEAF_COLORS[key] ?? 0x59ab30
        let real = (key == "oak" || key == "jungle" || key == "dark_oak" || key == "acacia") ? 0x4a8a28 : c
        t.clearAlpha()
        t.vline(7, 9, 15, 0x6a4c2a)
        t.disc(7.5, 7, 3.2, real)
        t.disc(6, 5, 1.8, shade(real, 1.15))
        t.set(9, 8, shade(real, 0.85))
    }
    p("tall_grass") { t in t.cross(0x8e8e8e); t.vline(7, 2, 15, 0x868686); t.set(6, 3, 0x9a9a9a); t.set(8, 5, 0x7a7a7a) }
    p("large_fern") { t in paintInto(t, "fern"); t.vline(7, 1, 4, 0x868686); t.hline(3, 4, 11, 0x7e7e7e) }
    p("pitcher_crop") { t in t.clearAlpha(); t.vline(7, 10, 15, 0x3a7a4a); t.disc(7.5, 8, 2, 0x4a9ab0) }
    p("bamboo_sapling") { t in t.clearAlpha(); t.vline(7, 6, 15, 0x82a83c); t.set(8, 5, 0x94c046); t.set(6, 8, 0x94c046) }
    p("small_dripleaf") { t in t.clearAlpha(); t.disc(7.5, 5, 3.4, 0x8e8e8e); t.vline(7, 8, 15, 0x7a7a7a) }
    p("piston_side") { t in t.planks(0x9a7444); t.rect(0, 0, 15, 3, 0x8a8a92); t.hline(4, 0, 15, 0x6a6a72) }
    p("piston_top") { t in t.planks(0xab854f); t.border(0x8a8a92); t.rect(5, 5, 10, 10, shade(0xab854f, 0.9)) }
    p("piston_top_sticky") { t in paintInto(t, "piston_top"); t.rect(4, 4, 11, 11, 0x6fc05c); t.rect(6, 6, 9, 9, 0x84d46e) }
    p("moving_piston") { t in t.blotch(0x9a7444, 0.1) }
    rp("^destroy_(\\d)$") { t, m in
        let stage = Int(m[1]!)!
        t.clearAlpha()
        let cracks = 2 + stage * 2
        for i in 0..<cracks {
            var x = Int(t.rand(i, 0) * 16), y = Int(t.rand(i, 1) * 16)
            let len = 3 + stage
            for j in 0..<len {
                t.set(x, y, 0x000000, 140 + stage * 10)
                x += Int(t.rand(i, j + 2) * 3) - 1
                y += Int(t.rand(i, j + 9) * 3) - 1
                x = max(0, min(15, x)); y = max(0, min(15, y))
            }
        }
    }
    p("air") { t in t.clearAlpha() }
    p("cave_air") { t in t.clearAlpha() }
    p("void_air") { t in t.clearAlpha() }

    // --- particle sprites ---
    p("smoke_particle") { t in
        t.clearAlpha()
        t.disc(7.5, 7.5, 5.5, 0xffffff)
        t.disc(5, 5, 2, 0xe8e8e8)
        for i in 0..<10 {
            let x = Int(t.rand(i, 0) * 16), y = Int(t.rand(i, 1) * 16)
            if t.alphaAt(x, y) > 0 { t.set(x, y, 0xd0d0d0) }
        }
    }
    p("flame_particle") { t in t.clearAlpha(); t.disc(7.5, 9, 4, 0xff8a1c); t.disc(7.5, 10, 2.6, 0xffc23c); t.set(7, 5, 0xff8a1c); t.set(8, 6, 0xffaa2c); t.disc(7.5, 11, 1.2, 0xfff0a0) }
    p("portal_particle") { t in t.clearAlpha(); t.disc(7.5, 7.5, 3, 0xffffff); t.disc(7.5, 7.5, 1.4, 0xe8d8f8) }
    p("crit_particle") { t in t.clearAlpha(); t.disc(7.5, 7.5, 2.5, 0xffffff); t.set(7, 7, 0xfff8d0) }
    p("heart_particle") { t in
        t.clearAlpha()
        t.px([".RR.RR.", "RRRRRRR", "RRRRRRR", ".RRRRR.", "..RRR..", "...R..."], ["R": 0xe83a3a], 4, 5)
        t.set(5, 6, 0xff8a8a)
    }
    p("angry_particle") { t in
        t.clearAlpha()
        t.px([".SS.SS.", "SSSSSSS", "SSSSSSS", ".SSSSS.", "..SSS..", "...S..."], ["S": 0x707070], 4, 5)
    }
    p("splash_particle") { t in t.clearAlpha(); t.rect(7, 4, 8, 11, 0xffffff); t.set(7, 12, 0xd8e8ff) }
    p("bubble_particle") { t in t.clearAlpha(); t.disc(7.5, 7.5, 3.5, 0xffffff); t.disc(7.5, 7.5, 2.4, 0xa8c8e8); t.set(6, 6, 0xffffff) }
    p("snow_particle") { t in t.clearAlpha(); t.disc(7.5, 7.5, 2, 0xffffff) }
    p("petal_particle") { t in t.clearAlpha(); t.disc(7, 7, 2.2, 0xf0b8d0); t.set(8, 6, 0xf8d8e4); t.set(6, 8, 0xe8a0c0) }
    p("note_particle") { t in
        t.clearAlpha()
        t.px(["..##", "..##", "..#.", "..#.", "###.", "###."], ["#": 0xffffff], 6, 4)
    }
    p("redstone_particle") { t in t.clearAlpha(); t.disc(7.5, 7.5, 2.6, 0xffffff) }
    p("soul_particle") { t in t.clearAlpha(); t.disc(7.5, 6.5, 3, 0xffffff); t.rect(5, 8, 10, 11, 0xffffff); t.set(6, 6, 0x80f0f0); t.set(9, 6, 0x80f0f0) }
    p("enchant_particle") { t in
        t.clearAlpha()
        t.px(["#.#", ".#.", "#.#"], ["#": 0xffffff], 6, 6)
    }
    p("slime_particle") { t in t.clearAlpha(); t.disc(7.5, 7.5, 3.4, 0xffffff); t.disc(6.5, 6.5, 1.2, 0xd8f8d0) }
    p("sweep_particle") { t in
        t.clearAlpha()
        for x in 1..<15 {
            let y = Int((8 - Foundation.sin(Double(x) / 14 * Double.pi) * 5).rounded(.down))
            t.set(x, y, 0xffffff)
            t.set(x, y + 1, 0xe8e8e8, 180)
        }
    }
}
