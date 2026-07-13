// Underground structures —
// mineshafts, strongholds (with end portal room), ancient cities.

import Foundation

private let AIR = 0

private var strongholdCache: (seed: UInt32, positions: [(Int, Int)])?
private func strongholdChunks(_ seed: UInt32) -> [(Int, Int)] {
    if strongholdCache == nil || strongholdCache!.seed != seed {
        strongholdCache = (seed, strongholdPositions(seed))
    }
    return strongholdCache!.positions
}

func registerUndergroundStructures() {
    registerStructure(StructureDef(
        // radius must cover the worst-case corridor walk (~103 blocks ≈ 7
        // chunks) or far pieces get sliced off at chunk borders
        id: "mineshaft", spacing: 16, separation: 4, salt: 30084232, maxRadiusChunks: 7,
        check: { _, _, _, rng in
            rng.nextFloat() < 0.25
        },
        plan: { _, ocx, ocz, rng in
            var pieces: [StructPiece] = []
            let baseY = -20 + rng.nextInt(50)
            let cx = ocx * 16 + 8, cz = ocz * 16 + 8
            let P = Int(cell(B.oak_planks)), F = Int(cell(B.oak_fence))

            func corridor(_ x: Int, _ y: Int, _ z: Int, _ dir: Int, _ len: Int, _ depth: Int) {
                let dx = [0, 0, -1, 1][dir], dz = [-1, 1, 0, 0][dir]
                let ex = x + dx * len, ez = z + dz * len
                pieces.append(piece(
                    min(x, ex) - 2, y - 1, min(z, ez) - 2,
                    max(x, ex) + 2, y + 4, max(z, ez) + 2
                ) { b in
                    for i in 0...len {
                        let px = x + dx * i, pz = z + dz * i
                        // carve 3×3 tunnel — preserve water below sea level so
                        // shafts crossing aquifers/ocean floors flood like vanilla
                        for w in -1...1 {
                            for h in 0...2 {
                                let wx = px + (dz != 0 ? w : 0), wz = pz + (dx != 0 ? w : 0)
                                let cur = b.get(wx, y + h, wz)
                                if y + h <= SEA && (cur >> 4) == Int(B.water) { continue }
                                b.set(wx, y + h, wz, AIR)
                            }
                        }
                        // floor planks over gaps
                        for w in -1...1 {
                            let wx = px + (dz != 0 ? w : 0), wz = pz + (dx != 0 ? w : 0)
                            let below = b.get(wx, y - 1, wz)
                            if below == 0 { b.set(wx, y - 1, wz, P) }
                        }
                        // supports every 4
                        if i % 4 == 2 {
                            let lx = px + (dz != 0 ? -1 : 0), lz = pz + (dx != 0 ? -1 : 0)
                            let rx = px + (dz != 0 ? 1 : 0), rz = pz + (dx != 0 ? 1 : 0)
                            b.set(lx, y, lz, F); b.set(lx, y + 1, lz, F)
                            b.set(rx, y, rz, F); b.set(rx, y + 1, rz, F)
                            b.set(lx, y + 2, lz, P); b.set(px, y + 2, pz, P); b.set(rx, y + 2, rz, P)
                            if b.rng.nextFloat() < 0.25 { b.set(px, y + 2, pz, P) }
                            if b.rng.nextFloat() < 0.15 { b.set(px, y + 1, pz, Int(cell(B.torch, 0))) }
                        }
                        // rails
                        if b.rng.nextFloat() < 0.6 {
                            b.set(px, y, pz, Int(cell(B.rail, dir < 2 ? 0 : 1)))
                        }
                        // cobwebs
                        if b.rng.nextFloat() < 0.06 {
                            let wx = px + (dz != 0 ? b.rng.nextInt(3) - 1 : 0), wz = pz + (dx != 0 ? b.rng.nextInt(3) - 1 : 0)
                            b.set(wx, y + 1 + b.rng.nextInt(2), wz, Int(cell(B.cobweb)))
                        }
                    }
                })
                if depth < 3 {
                    // branches from the end
                    let branches = rng.nextInt(3)
                    for _ in 0..<(branches + 1) {
                        let ndir = rng.nextInt(4)
                        if ndir == (dir ^ 1) { continue }
                        let ny = y + (rng.nextFloat() < 0.2 ? rng.nextInt(7) - 3 : 0)
                        corridor(ex, ny, ez, ndir, 8 + rng.nextInt(16), depth + 1)
                    }
                    // special rooms at junctions
                    if rng.nextFloat() < 0.15 {
                        pieces.append(piece(ex - 3, y - 1, ez - 3, ex + 3, y + 4, ez + 3) { b in
                            // cave spider nest
                            b.spawner(ex, y + 1, ez, "cave_spider")
                            for _ in 0..<16 {
                                let wx = ex + b.rng.nextInt(7) - 3, wy = y + b.rng.nextInt(3), wz = ez + b.rng.nextInt(7) - 3
                                if b.get(wx, wy, wz) == 0 { b.set(wx, wy, wz, Int(cell(B.cobweb))) }
                            }
                        })
                    }
                    if rng.nextFloat() < 0.2 {
                        let lx = ex + rng.nextInt(5) - 2, lz = ez + rng.nextInt(5) - 2
                        // facing decided at PLAN time — drawing the shared plan rng
                        // inside build closures made results depend on which chunks
                        // happened to build first (a real bug the goldens caught)
                        let facing = rng.nextInt(4)
                        pieces.append(piece(lx, y, lz, lx, y + 1, lz) { b in
                            b.chest(lx, y, lz, facing, "mineshaft")
                        })
                    }
                }
            }
            // central room
            pieces.append(piece(cx - 4, baseY - 1, cz - 4, cx + 4, baseY + 5, cz + 4) { b in
                b.fill(cx - 3, baseY, cz - 3, cx + 3, baseY + 3, cz + 3, AIR)
                for dz in -3...3 { for dx in -3...3 {
                    if b.get(cx + dx, baseY - 1, cz + dz) == 0 { b.set(cx + dx, baseY - 1, cz + dz, P) }
                } }
            })
            for d in 0..<4 {
                if rng.nextFloat() < 0.8 { corridor(cx, baseY, cz, d, 10 + rng.nextInt(14), 0) }
            }
            return StructurePlan(id: "mineshaft", pieces: pieces)
        }
    ))

    registerStructure(StructureDef(
        // radius must cover the worst-case corridor walk: 9 rooms × 17-block
        // corridors ≈ 160 blocks ≈ 10 chunks — too small and the outer rooms
        // (the PORTAL ROOM is always last/farthest) get sliced off
        id: "stronghold", spacing: 1, separation: 0, salt: 0, maxRadiusChunks: 11,
        check: { ctx, ocx, ocz, _ in
            for (sx, sz) in strongholdChunks(ctx.seed) where sx == ocx && sz == ocz { return true }
            return false
        },
        plan: { _, ocx, ocz, rng in
            var pieces: [StructPiece] = []
            let SB: [(Int, Double)] = [(Int(cell(B.stone_bricks)), 7), (Int(cell(B.mossy_stone_bricks)), 2), (Int(cell(B.cracked_stone_bricks)), 2)]
            let baseY = 10 + rng.nextInt(15)
            let cx = ocx * 16 + 8, cz = ocz * 16 + 8

            func room(_ x: Int, _ y: Int, _ z: Int, _ w: Int, _ h: Int, _ d: Int, _ fn: ((Builder, Int, Int, Int) -> Void)? = nil) {
                pieces.append(piece(x - 1, y - 1, z - 1, x + w + 1, y + h + 1, z + d + 1) { b in
                    for dy in -1...h {
                        for dz in -1...d {
                            for dx in -1...w {
                                let isWall = dx == -1 || dx == w || dz == -1 || dz == d || dy == -1 || dy == h
                                if isWall {
                                    b.fillRandom(x + dx, y + dy, z + dz, x + dx, y + dy, z + dz, SB)
                                } else {
                                    b.set(x + dx, y + dy, z + dz, AIR)
                                }
                            }
                        }
                    }
                    fn?(b, x, y, z)
                })
            }
            func corridorPiece(_ x: Int, _ y: Int, _ z: Int, _ dir: Int, _ len: Int) -> (Int, Int, Int) {
                let dx = [0, 0, -1, 1][dir], dz = [-1, 1, 0, 0][dir]
                let ex = x + dx * len, ez = z + dz * len
                pieces.append(piece(
                    min(x, ex) - 2, y - 1, min(z, ez) - 2,
                    max(x, ex) + 2, y + 4, max(z, ez) + 2
                ) { b in
                    for i in 0...len {
                        let px = x + dx * i, pz = z + dz * i
                        for w in -2...2 {
                            for h in -1...3 {
                                let wx = px + (dz != 0 ? w : 0), wz = pz + (dx != 0 ? w : 0)
                                let isWall = abs(w) == 2 || h == -1 || h == 3
                                if isWall { b.fillRandom(wx, y + h, wz, wx, y + h, wz, SB) }
                                else { b.set(wx, y + h, wz, AIR) }
                            }
                        }
                        if i % 6 == 3 && b.rng.nextFloat() < 0.4 {
                            b.set(px + (dz != 0 ? 1 : 0), y + 2, pz + (dx != 0 ? 1 : 0), Int(cell(B.torch, 0)))
                        }
                    }
                })
                return (ex, y, ez)
            }

            // start: spiral stair shaft down to baseY
            pieces.append(piece(cx - 3, baseY - 1, cz - 3, cx + 3, baseY + 30, cz + 3) { b in
                for y in baseY..<(baseY + 28) {
                    for dz in -2...2 { for dx in -2...2 {
                        let isWall = abs(dx) == 2 || abs(dz) == 2
                        b.set(cx + dx, y, cz + dz, isWall ? Int(cell(B.stone_bricks)) : AIR)
                    } }
                    let step = posMod(y, 8)
                    let sx = [1, 1, 0, -1, -1, -1, 0, 1][step], sz = [0, 1, 1, 1, 0, -1, -1, -1][step]
                    b.set(cx + sx, y, cz + sz, Int(cell(B.stone_brick_slab, 0)))
                }
            })

            // rooms connected by corridors
            var px = cx, py = baseY, pz = cz
            let roomCount = 6 + rng.nextInt(4)
            for i in 0..<roomCount {
                let dir = rng.nextInt(4)
                let len = 8 + rng.nextInt(10)
                (px, py, pz) = corridorPiece(px, py, pz, dir, len)
                let kind = i == roomCount - 1 ? "portal" : rng.pick(["plain", "library", "fountain", "storage", "plain"])
                if kind == "plain" {
                    room(px - 3, py - 1, pz - 3, 7, 5, 7)
                } else if kind == "library" {
                    room(px - 5, py - 1, pz - 5, 11, 7, 11) { b, x, y, z in
                        for bx in [1, 4, 7] {
                            for dz2 in 1..<10 {
                                if dz2 % 3 == 0 { continue }
                                for h in 0..<3 { b.set(x + bx, y + h, z + dz2, Int(cell(B.bookshelf))) }
                            }
                        }
                        b.chest(x + 9, y, z + 1, 2, "stronghold_library")
                        b.chest(x + 9, y + 4, z + 9, 0, "stronghold_library")
                        for _ in 0..<8 {
                            let wx = x + 1 + b.rng.nextInt(9), wy = y + b.rng.nextInt(5), wz = z + 1 + b.rng.nextInt(9)
                            // draw before the chunk-relative get() so the rng
                            // stream stays identical across bordering chunks
                            let place = b.rng.nextFloat() < 0.5
                            if place && b.get(wx, wy, wz) == 0 { b.set(wx, wy, wz, Int(cell(B.cobweb))) }
                        }
                    }
                } else if kind == "fountain" {
                    room(px - 3, py - 1, pz - 3, 7, 5, 7) { b, x, y, z in
                        b.set(x + 3, y, z + 3, Int(cell(B.water, 0)))
                        b.fill(x + 2, y, z + 2, x + 4, y, z + 4, Int(cell(B.stone_brick_slab, 0)))
                        b.set(x + 3, y, z + 3, Int(cell(B.water, 0)))
                    }
                } else if kind == "storage" {
                    room(px - 3, py - 1, pz - 3, 7, 5, 7) { b, x, y, z in
                        b.chest(x + 1, y, z + 1, 1, "stronghold_corridor")
                        b.set(x + 5, y, z + 5, Int(cell(B.cobblestone)))
                        b.set(x + 5, y + 1, z + 5, Int(cell(B.torch, 0)))
                    }
                } else if kind == "portal" {
                    // PORTAL ROOM
                    room(px - 5, py - 1, pz - 5, 11, 8, 13) { b, x, y, z in
                        // lava pools
                        b.fill(x + 1, y, z + 1, x + 9, y, z + 2, Int(cell(B.lava, 0)))
                        // platform with portal frame
                        let fx = x + 3, fz = z + 6
                        b.fill(fx, y, fz, fx + 4, y, fz + 4, Int(cell(B.stone_bricks)))
                        b.fill(fx + 1, y, fz + 1, fx + 3, y, fz + 3, Int(cell(B.lava, 0)))
                        // frame ring with seeded eyes
                        var frameRng = RandomX(hash2(0xE7E, x, z, 0))
                        func setFrame(_ wx: Int, _ wz: Int, _ facing: Int) {
                            let eye = frameRng.nextFloat() < 0.1 ? 4 : 0
                            b.set(wx, y + 1, wz, Int(cell(B.end_portal_frame, facing | eye)))
                        }
                        for i2 in 1...3 {
                            setFrame(fx + i2, fz, 1)          // north row faces south
                            setFrame(fx + i2, fz + 4, 0)      // south row faces north
                            setFrame(fx, fz + i2, 3)          // west column faces east
                            setFrame(fx + 4, fz + i2, 2)      // east column faces west
                        }
                        // stairs up to portal
                        for i2 in 0..<3 {
                            b.fill(x + 4, y + i2, z + 3 + i2, x + 6, y + i2, z + 3 + i2, Int(cell(B.stone_brick_stairs, 1)))
                        }
                        b.spawner(x + 5, y + 1, z + 3, "silverfish")
                        // infested blocks scattered (get() is -1 outside the
                        // building chunk — never feed that to UInt16)
                        for _ in 0..<10 {
                            let wx = x + b.rng.nextInt(11), wy = y + b.rng.nextInt(3), wz = z + b.rng.nextInt(13)
                            let cur = b.get(wx, wy, wz)
                            if cur > 0 && UInt16(cur >> 4) == B.stone_bricks { b.set(wx, wy, wz, Int(cell(B.infested_stone_bricks))) }
                        }
                    }
                }
            }
            return StructurePlan(id: "stronghold", pieces: pieces,
                                 ref: StructRefBox(cx - 170, baseY - 10, cz - 170, cx + 170, baseY + 40, cz + 170))
        }
    ))

    registerStructure(StructureDef(
        id: "ancient_city", spacing: 24, separation: 8, salt: 20083232, maxRadiusChunks: 6,
        check: { _, _, _, rng in
            rng.nextFloat() < 0.28
        },
        plan: { _, ocx, ocz, rng in
            var pieces: [StructPiece] = []
            let cx = ocx * 16 + 8, cz = ocz * 16 + 8
            let y = -51
            let DS: [(Int, Double)] = [(Int(cell(B.deepslate_bricks)), 5), (Int(cell(B.cracked_deepslate_bricks)), 3), (Int(cell(B.deepslate_tiles)), 3), (Int(cell(B.cobbled_deepslate)), 2)]

            // grand central chamber + frame ("the portal")
            pieces.append(piece(cx - 20, y - 3, cz - 12, cx + 20, y + 22, cz + 12) { b in
                b.fill(cx - 19, y, cz - 11, cx + 19, y + 18, cz + 11, AIR)
                b.fillRandom(cx - 19, y - 1, cz - 11, cx + 19, y - 1, cz + 11, [(Int(cell(B.sculk)), 4), (Int(cell(B.deepslate)), 4), (Int(cell(B.deepslate_tiles)), 2)])
                // the frame structure
                let fx = cx, fz = cz
                b.fillRandom(fx - 7, y, fz - 1, fx + 7, y + 14, fz + 1, DS)
                b.fill(fx - 4, y + 1, fz - 1, fx + 4, y + 10, fz + 1, AIR)
                b.fill(fx - 4, y + 1, fz, fx + 4, y + 10, fz, Int(cell(B.reinforced_deepslate)))
                b.fill(fx - 3, y + 1, fz, fx + 3, y + 9, fz, AIR)
                // stepped arch corners like the vanilla frame
                for (sx, sy) in [(-3, 9), (3, 9), (-3, 8), (3, 8), (-2, 9), (2, 9)] {
                    b.set(fx + sx, y + sy, fz, Int(cell(B.reinforced_deepslate)))
                }
                // soul fire braziers
                for sx in [-6, 6] {
                    b.set(fx + sx, y + 1, fz - 2, Int(cell(B.soul_sand)))
                    b.set(fx + sx, y + 2, fz - 2, Int(cell(B.soul_fire)))
                }
                // sculk spread on floor (rng drawn before the chunk-relative
                // get() so the stream stays identical across bordering chunks)
                for _ in 0..<200 {
                    let wx = cx - 19 + b.rng.nextInt(39), wz = cz - 11 + b.rng.nextInt(23)
                    let spread = b.rng.nextFloat() < 0.5
                    let cur = b.get(wx, y - 1, wz)
                    if cur > 0 && spread { b.set(wx, y - 1, wz, Int(cell(B.sculk))) }
                }
                // shriekers + sensors near center
                b.set(cx - 9, y, cz + 4, Int(cell(B.sculk_shrieker)))
                b.s.addBlockEntity(BESpec(x: cx - 9, y: y, z: cz + 4, kind: "shrieker", data: ["canSummon": .bool(true)]))
                b.set(cx + 9, y, cz - 4, Int(cell(B.sculk_shrieker)))
                b.s.addBlockEntity(BESpec(x: cx + 9, y: y, z: cz - 4, kind: "shrieker", data: ["canSummon": .bool(true)]))
                b.set(cx - 6, y, cz - 6, Int(cell(B.sculk_sensor)))
                b.set(cx + 6, y, cz + 6, Int(cell(B.sculk_sensor)))
                b.set(cx, y, cz + 8, Int(cell(B.sculk_catalyst)))
            })

            // boulevard east-west with ruins
            for dir in [-1, 1] {
                pieces.append(piece(cx + (dir == 1 ? 20 : -76), y - 2, cz - 5, cx + (dir == 1 ? 76 : -20), y + 12, cz + 5) { b in
                    for i in 20..<76 {
                        let px = cx + dir * i
                        for w in -4...4 {
                            b.set(px, y - 1, cz + w, abs(w) <= 2 ? Int(cell(B.deepslate_tiles)) : Int(cell(B.cobbled_deepslate)))
                            for h in 0...8 { b.set(px, y + h, cz + w, AIR) }
                        }
                        if i % 9 == 0 {
                            b.set(px, y, cz - 4, Int(cell(B.soul_lantern, 0)))
                            b.set(px, y, cz + 4, Int(cell(B.soul_lantern, 0)))
                        }
                    }
                })
                // side buildings
                let count = 3 + rng.nextInt(3)
                for _ in 0..<count {
                    let bx = cx + dir * (26 + rng.nextInt(44))
                    let bz = cz + (rng.nextBoolean() ? 7 + rng.nextInt(8) : -(7 + rng.nextInt(8)))
                    let w = 5 + rng.nextInt(5), d = 5 + rng.nextInt(5), h = 4 + rng.nextInt(3)
                    pieces.append(piece(bx - 1, y - 2, bz - 1, bx + w + 1, y + h + 6, bz + d + 1) { b in
                        b.fill(bx, y + h + 1, bz, bx + w, y + h + 5, bz + d, AIR)
                        for dz2 in 0...d { for dx2 in 0...w {
                            b.set(bx + dx2, y - 1, bz + dz2, Int(cell(B.deepslate_bricks)))
                            let isWall = dx2 == 0 || dx2 == w || dz2 == 0 || dz2 == d
                            for dy2 in 0...h {
                                if isWall {
                                    if b.rng.nextFloat() < 0.75 { b.fillRandom(bx + dx2, y + dy2, bz + dz2, bx + dx2, y + dy2, bz + dz2, DS) }
                                } else {
                                    b.set(bx + dx2, y + dy2, bz + dz2, AIR)
                                }
                            }
                        } }
                        if b.rng.nextFloat() < 0.7 { b.chest(bx + 1 + b.rng.nextInt(max(1, w - 1)), y, bz + 1 + b.rng.nextInt(max(1, d - 1)), 0, "ancient_city") }
                        if b.rng.nextFloat() < 0.4 {
                            b.set(bx + 2, y, bz + 2, Int(cell(B.sculk_sensor)))
                        }
                        if b.rng.nextFloat() < 0.25 {
                            b.set(bx + w - 1, y, bz + d - 1, Int(cell(B.sculk_shrieker)))
                            b.s.addBlockEntity(BESpec(x: bx + w - 1, y: y, z: bz + d - 1, kind: "shrieker", data: ["canSummon": .bool(true)]))
                        }
                        // candles + skulls flavor
                        if b.rng.nextFloat() < 0.5 { b.set(bx + 1, y, bz + d - 1, Int(cell(B.candle, 2 | 8))) }
                        if b.rng.nextFloat() < 0.3 { b.set(bx + w - 1, y, bz + 1, Int(cell(B.skeleton_skull))) }
                    })
                }
            }
            // ice box room
            pieces.append(piece(cx - 14, y, cz - 22, cx - 6, y + 6, cz - 14) { b in
                b.walls(cx - 14, y, cz - 22, cx - 6, y + 5, cz - 14, Int(cell(B.deepslate_bricks)), AIR)
                b.fill(cx - 12, y + 1, cz - 20, cx - 8, y + 2, cz - 16, Int(cell(B.packed_ice)))
                b.chest(cx - 10, y + 3, cz - 18, 0, "ancient_city")
            })
            // wool corridors (sneaking path)
            pieces.append(piece(cx - 5, y, cz + 12, cx + 5, y + 3, cz + 30) { b in
                for i in 12..<30 {
                    b.set(cx, y - 1, cz + i, Int(cell(B.gray_wool)))
                    b.set(cx - 1, y - 1, cz + i, Int(cell(B.gray_carpet)))
                    b.set(cx + 1, y - 1, cz + i, Int(cell(B.gray_carpet)))
                    for h in 0...2 { for w in -1...1 { b.set(cx + w, y + h, cz + i, AIR) } }
                }
            })
            return StructurePlan(id: "ancient_city", pieces: pieces,
                                 ref: StructRefBox(cx - 80, y - 6, cz - 32, cx + 80, y + 24, cz + 32))
        }
    ))
}
