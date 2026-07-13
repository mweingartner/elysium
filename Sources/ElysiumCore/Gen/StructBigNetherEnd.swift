// Ocean monuments, woodland mansions and nether
// fortresses, bastion remnants, end cities.

import Foundation

private let AIR = 0

func registerBigStructures() {
    let W = Int(cell(B.water, 0))

    registerStructure(StructureDef(
        id: "ocean_monument", spacing: 32, separation: 5, salt: 10387313, maxRadiusChunks: 3,
        check: { ctx, ocx, ocz, _ in
            let b = ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)
            return b == Biome.deepOcean.rawValue || b == Biome.deepColdOcean.rawValue
                || b == Biome.deepLukewarmOcean.rawValue || b == Biome.deepFrozenOcean.rawValue
        },
        plan: { _, ocx, ocz, _ in
            let x0 = ocx * 16 - 21, z0 = ocz * 16 - 21
            let y0 = 39
            let PR = Int(cell(B.prismarine)), PB = Int(cell(B.prismarine_bricks)), SL = Int(cell(B.sea_lantern))
            return StructurePlan(id: "ocean_monument", pieces: [
                piece(x0, y0 - 2, z0, x0 + 57, y0 + 22, z0 + 57) { b in
                    // platform
                    for dz in 0..<58 { for dx in 0..<58 { b.set(x0 + dx, y0 - 1, z0 + dz, PR) } }
                    // outer wall ring
                    for h in 0..<18 {
                        for d in 0..<58 {
                            let edge = h < 2 || d % 14 < 2
                            b.set(x0 + d, y0 + h, z0, edge ? PB : PR)
                            b.set(x0 + d, y0 + h, z0 + 57, edge ? PB : PR)
                            b.set(x0, y0 + h, z0 + d, edge ? PB : PR)
                            b.set(x0 + 57, y0 + h, z0 + d, edge ? PB : PR)
                        }
                    }
                    // interior water
                    for h in 0..<18 {
                        for dz in 1..<57 { for dx in 1..<57 { b.set(x0 + dx, y0 + h, z0 + dz, W) } }
                    }
                    // roof
                    for dz in 0..<58 { for dx in 0..<58 {
                        b.set(x0 + dx, y0 + 18, z0 + dz, (dx + dz) % 9 == 0 ? SL : PR)
                    } }
                    // entrance (north): gap in wall
                    b.fill(x0 + 26, y0, z0, x0 + 31, y0 + 8, z0 + 1, W)
                    // pillars at corners
                    for (px, pz) in [(6, 6), (51, 6), (6, 51), (51, 51)] {
                        b.fill(x0 + px - 1, y0, z0 + pz - 1, x0 + px + 1, y0 + 17, z0 + pz + 1, PB)
                    }
                    // central core with gold
                    let cx = x0 + 29, cz = z0 + 29
                    b.fill(cx - 4, y0 + 2, cz - 4, cx + 4, y0 + 12, cz + 4, PB)
                    b.fill(cx - 3, y0 + 3, cz - 3, cx + 3, y0 + 11, cz + 3, W)
                    b.fill(cx - 1, y0 + 6, cz - 1, cx + 1, y0 + 7, cz + 1, Int(cell(B.gold_block)))
                    b.fill(cx - 4, y0 + 7, cz - 4, cx - 4, y0 + 8, cz + 4, W) // openings
                    b.fill(cx + 4, y0 + 7, cz - 4, cx + 4, y0 + 8, cz + 4, W)
                    b.set(cx, y0 + 12, cz, SL)
                    // sponge room
                    let sx = x0 + 12, sz = z0 + 40
                    b.fill(sx, y0 + 10, sz, sx + 8, y0 + 14, sz + 8, PB)
                    b.fill(sx + 1, y0 + 11, sz + 1, sx + 7, y0 + 13, sz + 7, AIR)
                    for _ in 0..<12 {
                        b.set(sx + 1 + b.rng.nextInt(7), y0 + 13, sz + 1 + b.rng.nextInt(7), Int(cell(B.wet_sponge)))
                    }
                    // elder guardians
                    b.mob("elder_guardian", cx, y0 + 9, cz)
                    b.mob("elder_guardian", x0 + 8, y0 + 6, z0 + 8)
                    b.mob("elder_guardian", x0 + 49, y0 + 6, z0 + 49)
                },
            ], ref: StructRefBox(x0, y0 - 2, z0, x0 + 57, y0 + 22, z0 + 57))
        }
    ))

    registerStructure(StructureDef(
        id: "woodland_mansion", spacing: 80, separation: 20, salt: 10387319, maxRadiusChunks: 4,
        check: { ctx, ocx, ocz, _ in
            ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8) == Biome.darkForest.rawValue
        },
        plan: { ctx, ocx, ocz, rng in
            let x0 = ocx * 16 - 16, z0 = ocz * 16 - 24
            let y = ctx.heightAt(ocx * 16 + 8, ocz * 16 + 8)
            var pieces: [StructPiece] = []
            let PLANK = Int(cell(B.dark_oak_planks)), LOG = Int(cell(B.dark_oak_log))
            let CARPET = Int(cell(B.red_carpet))
            let COBBLE = Int(cell(B.cobblestone)), GLASS = Int(cell(B.glass_pane))
            let BIRCH = Int(cell(B.birch_planks))
            // room grid: 5 × 4 rooms of 8×8, 3 floors
            let ROOMS_X = 5, ROOMS_Z = 4, ROOM = 8, FLOORS = 3, FLOOR_H = 6
            let width = ROOMS_X * ROOM + 2, depth = ROOMS_Z * ROOM + 2

            // foundation + shell
            pieces.append(piece(x0 - 2, y - 10, z0 - 2, x0 + width + 2, y + FLOORS * FLOOR_H + 8, z0 + depth + 2) { b in
                for dz in 0...depth { for dx in 0...width {
                    b.foundation(x0 + dx, y - 1, z0 + dz, COBBLE, 10)
                } }
                // outer walls
                for f in 0..<FLOORS {
                    let fy = y + f * FLOOR_H
                    for h in 0..<FLOOR_H {
                        for d in 0...width {
                            let isWin = h >= 2 && h <= 3 && d % 6 == 3
                            b.set(x0 + d, fy + h, z0, isWin ? GLASS : PLANK)
                            b.set(x0 + d, fy + h, z0 + depth, isWin ? GLASS : PLANK)
                        }
                        for d in 0...depth {
                            let isWin = h >= 2 && h <= 3 && d % 6 == 3
                            b.set(x0, fy + h, z0 + d, isWin ? GLASS : PLANK)
                            b.set(x0 + width, fy + h, z0 + d, isWin ? GLASS : PLANK)
                        }
                    }
                    // floor
                    for dz in 1..<depth { for dx in 1..<width {
                        b.set(x0 + dx, fy - 1, z0 + dz, f == 0 ? COBBLE : BIRCH)
                        for h in 0..<(FLOOR_H - 1) { b.set(x0 + dx, fy + h, z0 + dz, AIR) }
                    } }
                }
                // roof
                for dz in -1...(depth + 1) { for dx in -1...(width + 1) {
                    b.set(x0 + dx, y + FLOORS * FLOOR_H, z0 + dz, PLANK)
                    b.set(x0 + dx, y + FLOORS * FLOOR_H + 1, z0 + dz, posMod(dx, 4) == 0 ? Int(cell(B.dark_oak_slab, 0)) : AIR)
                } }
                // corner pillars
                for (px, pz) in [(0, 0), (width, 0), (0, depth), (width, depth)] {
                    for h in 0..<(FLOORS * FLOOR_H + 2) { b.set(x0 + px, y + h, z0 + pz, LOG) }
                }
                // entrance
                b.fill(x0 + width / 2 - 1, y, z0, x0 + width / 2 + 1, y + 3, z0 + 1, AIR)
            })

            // rooms with interior walls + furnishings + mobs
            let roomKinds = ["bedroom", "library", "dining", "storage", "allay", "conference", "flower", "plain", "lootRare"]
            for f in 0..<FLOORS {
                for rz in 0..<ROOMS_Z {
                    for rx in 0..<ROOMS_X {
                        let roomX = x0 + 1 + rx * ROOM, roomZ = z0 + 1 + rz * ROOM
                        let fy = y + f * FLOOR_H
                        let kind = rng.pick(roomKinds)
                        let hasEastWall = rx < ROOMS_X - 1
                        let hasSouthWall = rz < ROOMS_Z - 1
                        pieces.append(piece(roomX, fy, roomZ, roomX + ROOM, fy + FLOOR_H - 1, roomZ + ROOM) { b in
                            // interior walls with door gaps
                            if hasEastWall {
                                for h in 0..<(FLOOR_H - 1) {
                                    for d in 0..<ROOM {
                                        if d == 4 && h < 2 { continue } // doorway
                                        b.set(roomX + ROOM, fy + h, roomZ + d, PLANK)
                                    }
                                }
                            }
                            if hasSouthWall {
                                for h in 0..<(FLOOR_H - 1) {
                                    for d in 0..<ROOM {
                                        if d == 4 && h < 2 { continue }
                                        b.set(roomX + d, fy + h, roomZ + ROOM, PLANK)
                                    }
                                }
                            }
                            let midX = roomX + 3, midZ = roomZ + 3
                            switch kind {
                            case "bedroom":
                                b.set(midX, fy, midZ, Int(cell(B.red_bed, 0 | 4)))
                                b.set(midX, fy, midZ + 1, Int(cell(B.red_bed, 0)))
                                b.set(midX + 2, fy, midZ, Int(cell(B.chest, 1)))
                                b.set(midX - 1, fy, midZ - 1, CARPET)
                            case "library":
                                for i in 0..<3 {
                                    for h in 0..<3 {
                                        b.set(roomX + 1, fy + h, roomZ + 1 + i * 2, Int(cell(B.bookshelf)))
                                        b.set(roomX + 5, fy + h, roomZ + 1 + i * 2, Int(cell(B.bookshelf)))
                                    }
                                }
                            case "dining":
                                b.fill(midX - 1, fy, midZ, midX + 1, fy, midZ, Int(cell(B.dark_oak_slab, 1)))
                                b.set(midX - 2, fy, midZ, Int(cell(B.dark_oak_stairs, 3)))
                                b.set(midX + 2, fy, midZ, Int(cell(B.dark_oak_stairs, 2)))
                            case "storage":
                                b.chest(midX, fy, midZ, 0, "woodland_mansion")
                                b.set(midX + 1, fy, midZ, Int(cell(B.barrel, 1)))
                            case "allay":
                                // jail cell with allay
                                b.fill(midX - 1, fy, midZ - 1, midX + 1, fy + 2, midZ + 1, Int(cell(B.dark_oak_fence)))
                                b.fill(midX, fy, midZ, midX, fy + 1, midZ, AIR)
                                b.mob("allay", midX, fy, midZ, ["persistent": .bool(true)])
                            case "conference":
                                for i in 0..<4 { b.set(roomX + 1 + i, fy, roomZ + 2, Int(cell(B.dark_oak_stairs, 1))) }
                                b.set(midX, fy + 3, midZ, Int(cell(B.lantern, 1)))
                            case "flower":
                                b.set(midX, fy, midZ, Int(cell(B.flower_pot)))
                                b.s.addBlockEntity(BESpec(x: midX, y: fy, z: midZ, kind: "pot_plant", data: ["plant": .str("poppy")]))
                                b.set(midX, fy - 1, midZ, Int(cell(B.grass_block)))
                            case "lootRare":
                                b.chest(midX, fy, midZ, 0, "woodland_mansion")
                                b.set(midX, fy - 1, midZ, Int(cell(B.obsidian)))
                            default:
                                break
                            }
                            // illager population
                            let r = b.rng.nextFloat()
                            if r < 0.3 { b.mob("vindicator", midX + 1, fy, midZ + 1, ["persistent": .bool(true)]) }
                            else if r < 0.42 { b.mob("evoker", midX - 1, fy, midZ - 1, ["persistent": .bool(true)]) }
                            // torch
                            b.set(roomX + 1, fy + 3, roomZ + 1, Int(cell(B.torch, 0)))
                        })
                    }
                }
            }
            return StructurePlan(id: "woodland_mansion", pieces: pieces,
                                 ref: StructRefBox(x0 - 8, y - 8, z0 - 8, x0 + width + 8, y + FLOORS * FLOOR_H + 8, z0 + depth + 8))
        }
    ))
}

// =============================================================================
// NETHER + END
// =============================================================================
private func netherStructurePick(_ rng: Rng) -> String {
    rng.nextFloat() < 0.4 ? "fortress" : "bastion"
}

func registerNetherEndStructures() {
    registerStructure(StructureDef(
        id: "fortress", spacing: 27, separation: 4, salt: 30084232, maxRadiusChunks: 6,
        check: { ctx, _, _, rng in
            ctx.dim == Dim.nether.rawValue && netherStructurePick(rng) == "fortress"
        },
        plan: { _, ocx, ocz, rng in
            var pieces: [StructPiece] = []
            let NB = Int(cell(B.nether_bricks))
            let FENCE = Int(cell(B.nether_brick_fence))
            let cx = ocx * 16 + 8, cz = ocz * 16 + 8
            let y = 48 + rng.nextInt(16)

            func crossing(_ x: Int, _ z: Int) {
                pieces.append(piece(x - 4, y - 6, z - 4, x + 4, y + 7, z + 4) { b in
                    b.fill(x - 3, y, z - 3, x + 3, y, z + 3, NB)
                    b.fill(x - 3, y + 1, z - 3, x + 3, y + 5, z + 3, AIR)
                    // pillars to ground
                    for (px, pz) in [(-3, -3), (3, -3), (-3, 3), (3, 3)] {
                        for d in 1..<18 {
                            let cur = b.get(x + px, y - d, z + pz)
                            if cur > 0 && UInt16(cur >> 4) != B.lava { break }
                            b.set(x + px, y - d, z + pz, NB)
                        }
                    }
                    // railings
                    for d in -3...3 {
                        if abs(d) == 2 { continue }
                        b.set(x + d, y + 1, z - 3, FENCE); b.set(x + d, y + 1, z + 3, FENCE)
                        b.set(x - 3, y + 1, z + d, FENCE); b.set(x + 3, y + 1, z + d, FENCE)
                    }
                })
            }
            func bridge(_ x: Int, _ z: Int, _ dir: Int, _ len: Int) -> (Int, Int) {
                let dx = [0, 0, -1, 1][dir], dz = [-1, 1, 0, 0][dir]
                let ex = x + dx * len, ez = z + dz * len
                pieces.append(piece(
                    min(x, ex) - 3, y - 10, min(z, ez) - 3,
                    max(x, ex) + 3, y + 7, max(z, ez) + 3
                ) { b in
                    for i in 0...len {
                        let px = x + dx * i, pz = z + dz * i
                        for w in -2...2 {
                            let wx = px + (dz != 0 ? w : 0), wz = pz + (dx != 0 ? w : 0)
                            b.set(wx, y, wz, NB)
                            for h in 1...5 { b.set(wx, y + h, wz, AIR) }
                            if abs(w) == 2 { b.set(wx, y + 1, wz, FENCE) }
                        }
                        // support arches
                        if i % 6 == 3 {
                            for w in [-2, 2] {
                                let wx = px + (dz != 0 ? w : 0), wz = pz + (dx != 0 ? w : 0)
                                for d in 1..<14 {
                                    let cur = b.get(wx, y - d, wz)
                                    if cur > 0 && UInt16(cur >> 4) != B.lava { break }
                                    b.set(wx, y - d, wz, NB)
                                }
                            }
                        }
                    }
                })
                return (ex, ez)
            }
            func blazePlatform(_ x: Int, _ z: Int) {
                pieces.append(piece(x - 3, y, z - 3, x + 3, y + 9, z + 3) { b in
                    b.fill(x - 3, y + 1, z - 3, x + 3, y + 1, z + 3, NB)
                    b.fill(x - 2, y + 2, z - 2, x + 2, y + 7, z + 2, AIR)
                    // stairs up
                    for i in 0..<3 { b.set(x - 3 + i, y + 1 + i, z, Int(cell(B.nether_brick_stairs, 3))) }
                    b.fill(x - 1, y + 2, z - 1, x + 1, y + 2, z + 1, NB)
                    b.spawner(x, y + 3, z, "blaze")
                    for d in -2...2 {
                        b.set(x + d, y + 2, z - 2, FENCE); b.set(x + d, y + 2, z + 2, FENCE)
                        b.set(x - 2, y + 2, z + d, FENCE); b.set(x + 2, y + 2, z + d, FENCE)
                    }
                })
            }
            func wartRoom(_ x: Int, _ z: Int) {
                pieces.append(piece(x - 4, y - 2, z - 4, x + 4, y + 6, z + 4) { b in
                    b.walls(x - 4, y, z - 4, x + 4, y + 5, z + 4, NB, AIR)
                    b.fill(x - 3, y + 1, z - 3, x + 3, y + 1, z + 3, Int(cell(B.soul_sand)))
                    for dz in -3...3 { for dx in -3...3 {
                        if b.rng.nextFloat() < 0.7 { b.set(x + dx, y + 2, z + dz, Int(cell(B.nether_wart, b.rng.nextInt(4)))) }
                    } }
                    b.set(x, y + 2, z - 4, AIR); b.set(x, y + 3, z - 4, AIR) // doorway
                    b.chest(x + 3, y + 2, z + 3, 0, "nether_fortress")
                })
            }

            crossing(cx, cz)
            var arms = 0
            for dir in 0..<4 {
                if rng.nextFloat() < 0.3 && arms >= 2 { continue }
                arms += 1
                let len = 16 + rng.nextInt(20)
                let (ex, ez) = bridge(cx, cz, dir, len)
                crossing(ex, ez)
                let what = rng.nextFloat()
                if what < 0.4 { blazePlatform(ex + (dir < 2 ? 8 : 0), ez + (dir >= 2 ? 8 : 0)) }
                else if what < 0.65 { wartRoom(ex + (dir < 2 ? 9 : 0), ez + (dir >= 2 ? 9 : 0)) }
                else if what < 0.85 {
                    let len2 = 12 + rng.nextInt(12)
                    let dir2 = (dir + (rng.nextBoolean() ? 2 : 3)) % 4
                    let (ex2, ez2) = bridge(ex, ez, dir2, len2)
                    crossing(ex2, ez2)
                    if rng.nextBoolean() { blazePlatform(ex2, ez2 + 8) }
                }
            }
            return StructurePlan(id: "fortress", pieces: pieces,
                                 ref: StructRefBox(cx - 70, y - 20, cz - 70, cx + 70, y + 12, cz + 70))
        }
    ))

    registerStructure(StructureDef(
        id: "bastion", spacing: 27, separation: 4, salt: 30084232, maxRadiusChunks: 3,
        check: { ctx, _, _, rng in
            if ctx.dim != Dim.nether.rawValue || netherStructurePick(rng) != "bastion" { return false }
            return true
        },
        plan: { _, ocx, ocz, rng in
            let x0 = ocx * 16 - 8, z0 = ocz * 16 - 8
            let y = 50 + rng.nextInt(12)
            let BS: [(Int, Double)] = [(Int(cell(B.blackstone)), 5), (Int(cell(B.polished_blackstone_bricks)), 4), (Int(cell(B.cracked_polished_blackstone_bricks)), 2), (Int(cell(B.gilded_blackstone)), 0.4)]
            let W = 32, D = 32, H = 20
            return StructurePlan(id: "bastion", pieces: [
                piece(x0 - 1, y - 16, z0 - 1, x0 + W + 1, y + H + 1, z0 + D + 1) { b in
                    // big hollow shell with internal bridges
                    for dz in 0...D {
                        for dx in 0...W {
                            let isWall = dx == 0 || dx == W || dz == 0 || dz == D
                            b.foundation(x0 + dx, y - 1, z0 + dz, Int(cell(B.blackstone)), 14)
                            for h in 0..<H {
                                if isWall {
                                    // ruined: upper parts decay
                                    if h < H - b.rng.nextInt(6) { b.fillRandom(x0 + dx, y + h, z0 + dz, x0 + dx, y + h, z0 + dz, BS) }
                                } else {
                                    b.set(x0 + dx, y + h, z0 + dz, AIR)
                                }
                            }
                        }
                    }
                    // internal floors (3 levels of partial bridges)
                    for lvl in 0..<3 {
                        let fy = y + 1 + lvl * 6
                        for dz in 2...(D - 2) {
                            for dx in 2...(W - 2) {
                                let onBridge = (dz % 10 < 3) || (dx % 12 < 3)
                                if onBridge && b.rng.nextFloat() < 0.92 {
                                    b.fillRandom(x0 + dx, fy, z0 + dz, x0 + dx, fy, z0 + dz, BS)
                                }
                            }
                        }
                    }
                    // gold blocks scattered
                    for _ in 0..<8 {
                        let gx = x0 + 3 + b.rng.nextInt(W - 6), gz = z0 + 3 + b.rng.nextInt(D - 6)
                        let gy = y + 1 + b.rng.nextInt(3) * 6 + 1
                        b.set(gx, gy, gz, Int(cell(B.gold_block)))
                    }
                    // treasure room at center bottom
                    let cx = x0 + W / 2, cz = z0 + D / 2
                    b.walls(cx - 4, y, cz - 4, cx + 4, y + 6, cz + 4, Int(cell(B.polished_blackstone_bricks)), AIR)
                    b.fill(cx - 1, y + 1, cz - 1, cx + 1, y + 1, cz + 1, Int(cell(B.gold_block)))
                    b.chest(cx, y + 2, cz, 0, "bastion_treasure")
                    b.set(cx - 4, y + 1, cz, AIR); b.set(cx - 4, y + 2, cz, AIR)
                    b.fill(cx - 2, y + 1, cz - 3, cx - 2, y + 1, cz - 3, Int(cell(B.lava, 0)))
                    // other chests (rng drawn before the chunk-relative get()
                    // so the stream stays identical across bordering chunks)
                    for _ in 0..<3 {
                        let lx = x0 + 4 + b.rng.nextInt(W - 8), lz = z0 + 4 + b.rng.nextInt(D - 8)
                        let ly = y + 1 + b.rng.nextInt(3) * 6 + 1
                        let facing = b.rng.nextInt(4)
                        if b.get(lx, ly - 1, lz) > 0 { b.chest(lx, ly, lz, facing, "bastion_other") }
                    }
                    // mobs
                    b.mob("piglin", cx + 3, y + 1, cz + 3, ["persistent": .bool(true)])
                    b.mob("piglin", cx - 3, y + 7, cz - 3, ["persistent": .bool(true)])
                    b.mob("piglin", x0 + 6, y + 1, z0 + 6, ["persistent": .bool(true)])
                    b.mob("piglin_brute", cx + 1, y + 3, cz - 2, ["persistent": .bool(true)])
                    b.mob("piglin_brute", x0 + W - 6, y + 13, z0 + 6, ["persistent": .bool(true)])
                    b.mob("hoglin", x0 + 8, y + 1, z0 + D - 8, ["persistent": .bool(true)])
                    b.mob("hoglin", x0 + W - 8, y + 1, z0 + D - 8, ["persistent": .bool(true)])
                },
            ], ref: StructRefBox(x0 - 8, y - 16, z0 - 8, x0 + W + 8, y + H + 4, z0 + D + 8))
        }
    ))

    registerStructure(StructureDef(
        id: "end_city", spacing: 20, separation: 11, salt: 10387313, maxRadiusChunks: 3,
        check: { ctx, ocx, ocz, rng in
            if ctx.dim != Dim.end.rawValue { return false }
            let x = ocx * 16 + 8, z = ocz * 16 + 8
            let distSq = x * x + z * z
            if distSq < 768 * 768 { return false } // outer islands only
            return ctx.heightAt(x, z) > 30 && rng.nextFloat() < 0.65
        },
        plan: { ctx, ocx, ocz, rng in
            let cx = ocx * 16 + 8, cz = ocz * 16 + 8
            let baseY = ctx.heightAt(cx, cz)
            let PUR = Int(cell(B.purpur_block)), PIL = Int(cell(B.purpur_pillar)), END_ROD = Int(cell(B.end_rod))
            var pieces: [StructPiece] = []
            let floors = 3 + rng.nextInt(3)

            // tower
            pieces.append(piece(cx - 7, baseY - 4, cz - 7, cx + 7, baseY + floors * 5 + 8, cz + 7) { b in
                for dz in -4...4 { for dx in -4...4 {
                    b.foundation(cx + dx, baseY - 1, cz + dz, Int(cell(B.end_stone_bricks)), 6)
                } }
                for f in 0..<floors {
                    let fy = baseY + f * 5
                    // walls 9×9
                    for h in 0..<5 {
                        for d in -4...4 {
                            let win = h >= 2 && h <= 3 && abs(d) == 2
                            b.set(cx + d, fy + h, cz - 4, win ? Int(cell(B.purple_stained_glass)) : PUR)
                            b.set(cx + d, fy + h, cz + 4, win ? Int(cell(B.purple_stained_glass)) : PUR)
                            b.set(cx - 4, fy + h, cz + d, win ? Int(cell(B.purple_stained_glass)) : PUR)
                            b.set(cx + 4, fy + h, cz + d, win ? Int(cell(B.purple_stained_glass)) : PUR)
                        }
                    }
                    // interior + floor
                    for dz in -3...3 { for dx in -3...3 {
                        b.set(cx + dx, fy - 1, cz + dz, PUR)
                        for h in 0..<4 { b.set(cx + dx, fy + h, cz + dz, AIR) }
                    } }
                    // corner pillars
                    for (px, pz) in [(-4, -4), (4, -4), (-4, 4), (4, 4)] {
                        for h in 0..<5 { b.set(cx + px, fy + h, cz + pz, PIL) }
                    }
                    // spiral purpur stairs inside
                    let steps = [(-2, -2), (0, -3), (2, -2), (3, 0), (2, 2), (0, 3), (-2, 2), (-3, 0)]
                    let (sx, sz) = steps[f % steps.count]
                    b.set(cx + sx, fy + 1, cz + sz, Int(cell(B.purpur_stairs, f % 4)))
                    b.set(cx + sx, fy + 2, cz + sz, AIR)
                    // shulker guarding each floor
                    b.mob("shulker", cx + (f % 2 == 0 ? 2 : -2), fy, cz + (f % 2 == 0 ? 2 : -2), ["persistent": .bool(true)])
                    // end rods
                    b.set(cx - 3, fy + 3, cz - 3, END_ROD)
                    b.set(cx + 3, fy + 3, cz + 3, END_ROD)
                }
                // door at base
                b.fill(cx, baseY, cz - 4, cx, baseY + 2, cz - 4, AIR)
                // roof + loot
                let ty = baseY + floors * 5
                for dz in -5...5 { for dx in -5...5 {
                    if abs(dx) == 5 || abs(dz) == 5 { b.set(cx + dx, ty, cz + dz, Int(cell(B.purpur_slab, 0))) }
                    else { b.set(cx + dx, ty, cz + dz, PUR) }
                } }
                b.chest(cx - 2, ty + 1, cz, 3, "end_city_treasure")
                b.chest(cx + 2, ty + 1, cz, 2, "end_city_treasure")
                b.set(cx, ty + 1, cz, END_ROD)
                b.mob("shulker", cx, ty + 1, cz + 2, ["persistent": .bool(true)])
            })

            // end ship (60%)
            if rng.nextFloat() < 0.6 {
                let sx = cx + 14, sy = baseY + floors * 5 - 4, sz = cz
                pieces.append(piece(sx - 3, sy - 4, sz - 4, sx + 18, sy + 10, sz + 4) { b in
                    // hull
                    for i in 0..<16 {
                        let w = i < 3 ? 1 : i > 12 ? 1 : 2
                        for dz in -w...w {
                            b.set(sx + i, sy, sz + dz, PUR)
                            b.set(sx + i, sy + 1, sz - w, PUR)
                            b.set(sx + i, sy + 1, sz + w, PUR)
                        }
                        for dz in (-w + 1)...(w - 1) { b.set(sx + i, sy + 1, sz + dz, AIR) }
                    }
                    // deck + cabin
                    b.fill(sx + 3, sy + 2, sz - 2, sx + 12, sy + 2, sz + 2, PUR)
                    b.walls(sx + 9, sy + 3, sz - 2, sx + 13, sy + 6, sz + 2, PUR, AIR)
                    // mast
                    for h in 0..<8 { b.set(sx + 6, sy + 3 + h, sz, PIL) }
                    // dragon head prow
                    b.set(sx - 1, sy + 1, sz, Int(cell(B.dragon_head)))
                    // treasure: elytra chest + brewing stand
                    b.chest(sx + 10, sy + 3, sz, 4, "end_city_treasure")
                    b.s.addBlockEntity(BESpec(x: sx + 11, y: sy + 3, z: sz, kind: "elytra_chest"))
                    b.set(sx + 11, sy + 3, sz, Int(cell(B.chest, 4)))
                    b.set(sx + 12, sy + 3, sz - 1, Int(cell(B.brewing_stand)))
                    b.mob("shulker", sx + 7, sy + 3, sz, ["persistent": .bool(true)])
                    b.mob("shulker", sx + 11, sy + 4, sz + 1, ["persistent": .bool(true)])
                })
            }
            return StructurePlan(id: "end_city", pieces: pieces,
                                 ref: StructRefBox(cx - 24, baseY - 8, cz - 24, cx + 36, baseY + floors * 5 + 12, cz + 24))
        }
    ))
}

/// register every structure family in a frozen order
/// (overworld, underground, big, nether_end) — STRUCTURES array order matters
/// for buildStructuresForChunk iteration.
/// A global `let` is dispatch_once-initialized, so concurrent generateChunk
/// calls on the gen queue can't double-register (a plain bool check raced).
private let structuresRegistered: Void = {
    registerOverworldStructures()
    registerUndergroundStructures()
    registerBigStructures()
    registerNetherEndStructures()
}()
public func registerAllStructures() {
    _ = structuresRegistered
}
