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
                    // Keep the sponge chamber part of the monument's water
                    // circuit.  A three-wide, three-high water arch reaches
                    // the existing interior sea while retaining its solid
                    // prismarine floor and roof.
                    b.fill(sx + 3, y0 + 11, sz, sx + 5, y0 + 13, sz, W)
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
            // room grid: 5 × 4 rooms of 8×8, 3 floors
            let ROOMS_X = 5, ROOMS_Z = 4, ROOM = 8, FLOORS = 3, FLOOR_H = 6
            let width = ROOMS_X * ROOM + 2, depth = ROOMS_Z * ROOM + 2
            // A mansion is too broad for a one-column height guess.  Its
            // plan may only use a dry, exact terrain pad whose eight-block
            // maximum drop remains inside the 12-block support foundation.
            // Legacy synthetic contexts without an oracle retain their
            // explicit height function, but normal Overworld plans fail
            // closed on wet, unsupported, or excessively varied ground.
            let y: Int
            if ctx.terrainOracle != nil {
                guard let padY = exactDryTerrainPadY(ctx, x0, z0 - 3,
                                                      x0 + width, z0 + depth,
                                                      maxVariation: 8) else {
                    return nil
                }
                y = padY
            } else {
                y = ctx.heightAt(ocx * 16 + 8, ocz * 16 + 8)
            }
            var pieces: [StructPiece] = []
            let PLANK = Int(cell(B.dark_oak_planks)), LOG = Int(cell(B.dark_oak_log))
            let CARPET = Int(cell(B.red_carpet))
            let COBBLE = Int(cell(B.cobblestone)), GLASS = Int(cell(B.glass_pane))
            let BIRCH = Int(cell(B.birch_planks))
            let STAIR = Int(cell(B.dark_oak_stairs)), PATH = Int(cell(B.dirt_path))
            let DOOR = bid("dark_oak_door")
            // The southeast room is deliberately a circulation hall, rather
            // than a furnished room subsequently carved open for stairs.
            // Keeping the shaft in a reserved room preserves the remaining
            // plan and gives every floor a predictable way up and down.
            let stairHallX = x0 + 1 + (ROOMS_X - 1) * ROOM
            let stairHallZ = z0 + 1 + (ROOMS_Z - 1) * ROOM

            // foundation + shell
            pieces.append(piece(x0 - 2, y - 12, z0 - 3, x0 + width + 2, y + FLOORS * FLOOR_H + 8, z0 + depth + 2) { b in
                for dz in 0...depth { for dx in 0...width {
                    b.foundation(x0 + dx, y - 1, z0 + dz, COBBLE, 12)
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
                // A real north-facing double doorway, with an exterior stair
                // whose high half leads back to the house and a short, clear
                // approach.  Earlier mansions merely removed wall blocks,
                // leaving an implausible hole with no interactive entrance.
                let entranceX = x0 + width / 2
                for dx in -1...0 {
                    let doorX = entranceX + dx
                    b.set(doorX, y, z0, Int(cell(DOOR, 0)))
                    // Complementary hinge bits let the two leaves open away
                    // from the centre seam instead of colliding as twins.
                    b.set(doorX, y + 1, z0, Int(cell(DOOR, dx == -1 ? 9 : 8)))
                    b.clear(doorX, y, z0 + 1, doorX, y + 3, z0 + 1)
                    b.foundation(doorX, y - 2, z0 - 1, COBBLE, 12)
                    b.set(doorX, y - 1, z0 - 1, STAIR | FACE_OPP[0])
                    for approachZ in (z0 - 3)...(z0 - 2) {
                        b.foundation(doorX, y - 2, approachZ, COBBLE, 12)
                        b.set(doorX, y - 1, approachZ, PATH)
                    }
                    b.clear(doorX, y, z0 - 3, doorX, y + 2, z0 - 1)
                }
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
                        let isStairHall = rx == ROOMS_X - 1 && rz == ROOMS_Z - 1
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
                            if !isStairHall {
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
                            }
                            // illager population
                            let r = b.rng.nextFloat()
                            // Keep one per-room RNG draw even for the stair
                            // hall.  Its construction must not perturb the
                            // deterministic room-kind stream elsewhere.
                            let occupantX = roomX + 6, occupantZ = roomZ + 6
                            if !isStairHall, r < 0.3 {
                                b.clear(occupantX, fy, occupantZ, occupantX, fy + 2, occupantZ)
                                b.mob("vindicator", occupantX, fy, occupantZ, ["persistent": .bool(true)])
                            } else if !isStairHall, r < 0.42 {
                                b.clear(occupantX, fy, occupantZ, occupantX, fy + 2, occupantZ)
                                b.mob("evoker", occupantX, fy, occupantZ, ["persistent": .bool(true)])
                            }
                            // torch
                            if !isStairHall { b.set(roomX + 1, fy + 3, roomZ + 1, Int(cell(B.torch, 0))) }
                        })
                    }
                }
            }
            // A two-flight stair hall connects all three floor decks.  The
            // closure comes after room furnishing, but it owns a room that was
            // reserved above, so it never tears a route through a furnished
            // bedroom or blocks a resident spawn.
            pieces.append(piece(stairHallX + 1, y - 1, stairHallZ + 1,
                                stairHallX + 6, y + FLOORS * FLOOR_H - 1, stairHallZ + 6) { b in
                b.clear(stairHallX + 1, y, stairHallZ + 1,
                        stairHallX + 6, y + FLOORS * FLOOR_H - 1, stairHallZ + 6)
                for f in 0..<FLOORS {
                    let fy = y + f * FLOOR_H
                    b.fill(stairHallX + 1, fy - 1, stairHallZ + 1,
                           stairHallX + 6, fy - 1, stairHallZ + 6,
                           f == 0 ? COBBLE : BIRCH)
                }
                func stairFlight(_ floor: Int, _ z: Int, risingEast: Bool) {
                    let fy = y + floor * FLOOR_H
                    for step in 0..<FLOOR_H {
                        let x = risingEast ? stairHallX + 1 + step : stairHallX + 6 - step
                        // A tread cannot float above the stair shaft.  Every
                        // rise gets a solid riser beneath it, while the next
                        // two cells remain clear for a player's body/head.
                        if step > 0 {
                            b.fill(x, fy, z, x, fy + step - 1, z,
                                   floor == 0 ? COBBLE : BIRCH)
                        }
                        b.set(x, fy + step, z, STAIR | (risingEast ? 3 : 2))
                        b.set(x, fy + step + 1, z, AIR)
                        b.set(x, fy + step + 2, z, AIR)
                    }
                }
                stairFlight(0, stairHallZ + 1, risingEast: true)
                stairFlight(1, stairHallZ + 6, risingEast: false)
            })
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
            let STAIR = Int(cell(B.nether_brick_stairs))
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
                        // Bridges and side rooms meet a crossing at its middle
                        // three cells.  Leave those matching gates open; the
                        // former off-centre gaps decorated the rail but sealed
                        // every authored bridge at the junction.
                        if abs(d) <= 1 { continue }
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
                            // The first/last four bridge cells lie inside a
                            // crossing's 7×7 deck.  Their transverse rails
                            // would otherwise intersect the perpendicular arm
                            // and turn the junction into a fence grid.
                            if abs(w) == 2 && i > 3 && i < len - 3 {
                                b.set(wx, y + 1, wz, FENCE)
                            }
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
            /// A raised blaze platform attaches to a crossing at `entryDir`.
            /// Its threshold is a real one-block stair, not a disconnected
            /// decorative stair floating above the bridge deck.
            func blazePlatform(_ x: Int, _ z: Int, _ entryDir: Int) {
                pieces.append(piece(x - 3, y, z - 3, x + 3, y + 9, z + 3) { b in
                    b.fill(x - 3, y + 1, z - 3, x + 3, y + 1, z + 3, NB)
                    b.fill(x - 2, y + 2, z - 2, x + 2, y + 7, z + 2, AIR)
                    b.fill(x - 1, y + 2, z - 1, x + 1, y + 2, z + 1, NB)
                    b.spawner(x, y + 3, z, "blaze")
                    for d in -2...2 {
                        b.set(x + d, y + 2, z - 2, FENCE); b.set(x + d, y + 2, z + 2, FENCE)
                        b.set(x - 2, y + 2, z + d, FENCE); b.set(x + 2, y + 2, z + d, FENCE)
                    }
                    // The platform's near edge shares the crossing's outer
                    // deck coordinate.  Back the threshold directly and
                    // clear both the old crossing rail and platform rail so
                    // the stair joins a legal two-block-high route.
                    let dx = FACE_DX[entryDir], dz = FACE_DZ[entryDir]
                    let entryX = x - dx * 3, entryZ = z - dz * 3
                    let landingX = entryX + dx, landingZ = entryZ + dz
                    b.foundation(entryX, y - 1, entryZ, NB, 14)
                    b.set(entryX, y, entryZ, STAIR | entryDir)
                    b.clear(entryX, y + 1, entryZ, entryX, y + 2, entryZ)
                    b.clear(landingX, y + 2, landingZ, landingX, y + 3, landingZ)
                })
            }
            /// A nether-wart room has a three-wide threshold that rises from
            /// the crossing deck to the soul-sand bed without erasing crops
            /// or openings on the other three sides.
            func wartRoom(_ x: Int, _ z: Int, _ entryDir: Int) {
                pieces.append(piece(x - 4, y - 2, z - 4, x + 4, y + 6, z + 4) { b in
                    b.walls(x - 4, y, z - 4, x + 4, y + 5, z + 4, NB, AIR)
                    b.fill(x - 3, y + 1, z - 3, x + 3, y + 1, z + 3, Int(cell(B.soul_sand)))
                    for dz in -3...3 { for dx in -3...3 {
                        if b.rng.nextFloat() < 0.7 { b.set(x + dx, y + 2, z + dz, Int(cell(B.nether_wart, b.rng.nextInt(4)))) }
                    } }
                    let dx = FACE_DX[entryDir], dz = FACE_DZ[entryDir]
                    let sideX = FACE_DZ[entryDir], sideZ = -FACE_DX[entryDir]
                    for offset in -1...1 {
                        let entryX = x - dx * 4 + sideX * offset
                        let entryZ = z - dz * 4 + sideZ * offset
                        let landingX = entryX + dx, landingZ = entryZ + dz
                        b.foundation(entryX, y - 1, entryZ, NB, 14)
                        b.set(entryX, y, entryZ, STAIR | entryDir)
                        b.clear(entryX, y + 1, entryZ, entryX, y + 3, entryZ)
                        // Reserve the first crop row as a clear landing.  Its
                        // soul-sand surface remains intact at y + 1.
                        b.clear(landingX, y + 2, landingZ, landingX, y + 3, landingZ)
                    }
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
                // Put side rooms flush with a crossing's outer deck.  The
                // orientation is derived, not random, so this does not alter
                // the frozen plan RNG stream.
                // Direction IDs are N,S,W,E rather than a rotational enum,
                // so choose the right-hand perpendicular explicitly.  Simple
                // modular arithmetic would send south/east branches back onto
                // their bridge instead of beside it.
                let sideDir = [3, 2, 0, 1][dir]
                if what < 0.4 {
                    blazePlatform(ex + FACE_DX[sideDir] * 6,
                                  ez + FACE_DZ[sideDir] * 6, sideDir)
                } else if what < 0.65 {
                    wartRoom(ex + FACE_DX[sideDir] * 7,
                             ez + FACE_DZ[sideDir] * 7, sideDir)
                }
                else if what < 0.85 {
                    let len2 = 12 + rng.nextInt(12)
                    let dir2 = (dir + (rng.nextBoolean() ? 2 : 3)) % 4
                    let (ex2, ez2) = bridge(ex, ez, dir2, len2)
                    crossing(ex2, ez2)
                    if rng.nextBoolean() {
                        let sideDir2 = [3, 2, 0, 1][dir2]
                        blazePlatform(ex2 + FACE_DX[sideDir2] * 6,
                                      ez2 + FACE_DZ[sideDir2] * 6, sideDir2)
                    }
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
            let BLACKSTONE = Int(cell(B.blackstone))
            let STAIR = Int(cell(B.nether_brick_stairs))
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
                    // Fixed circulation is stamped after the ruined shell and
                    // randomized bridges.  It supplies a grounded north
                    // entrance, a reliable route through every deck height,
                    // and a small threshold into the raised treasure room.
                    let entryX = x0 + W / 2
                    for dx in -1...1 {
                        let px = entryX + dx
                        b.foundation(px, y - 1, z0 - 1, BLACKSTONE, 14)
                        b.clear(px, y, z0 - 1, px, y + 2, z0)
                    }

                    // The ruined suspended bridges can otherwise turn the
                    // entire ground deck into a head-height checkerboard.
                    // Carve one explicit lower promenade from the north gate
                    // to the stair spine and treasure-room threshold.
                    let promenadeX = x0 + 4

                    // A supported south-rising stair spine reaches the three
                    // authored bridge decks (y + 1, y + 7, and y + 13).  The
                    // riser column below each later tread is deliberate: an
                    // all-air fixture must not be able to make these stairs
                    // float merely because a terrain column happens to exist.
                    let stairX = x0 + 3
                    for level in 0..<3 {
                        let deckY = y + 1 + level * 6
                        let deckZ = z0 + 4 + level * 6
                        b.fill(stairX, deckY, deckZ, x0 + W - 3, deckY, deckZ, BLACKSTONE)
                    }
                    for step in 0...13 {
                        let stairZ = z0 + 3 + step
                        if step > 0 {
                            b.fill(stairX, y, stairZ, stairX, y + step - 1, stairZ, BLACKSTONE)
                        }
                        b.set(stairX, y + step, stairZ, STAIR | 1)
                        b.clear(stairX, y + step + 1, stairZ, stairX, y + step + 2, stairZ)
                    }
                    // Stamp this after the fixed deck rows as well: the first
                    // row otherwise becomes a head-height ceiling across the
                    // ground route at z0 + 4.
                    b.clear(promenadeX, y, z0 + 1, entryX, y + 2, z0 + 1)
                    b.clear(promenadeX, y, z0 + 1, promenadeX, y + 2, z0 + 16)
                    b.clear(promenadeX, y, z0 + 16, cx - 5, y + 2, z0 + 16)

                    // The room's retained bottom wall block forms the raised
                    // floor threshold.  A backed east-rising stair makes that
                    // one-block change usable instead of a decorative hole.
                    b.foundation(cx - 5, y - 1, cz, BLACKSTONE, 14)
                    b.set(cx - 5, y, cz, STAIR | 3)
                    b.clear(cx - 5, y + 1, cz, cx - 5, y + 2, cz)
                    // Persistent mobs outlive normal spawn admission, so they
                    // must never inherit an incidental ruined bridge cell.
                    // Each patrol deck owns a three-by-three solid floor and
                    // two clear cells above its selected spawn point.  The
                    // fixed lower promenade and bridge decks keep these
                    // guards connected to the authored circulation network.
                    func patrolDeck(_ x: Int, _ feetY: Int, _ z: Int) {
                        b.fill(x - 1, feetY - 1, z - 1,
                               x + 1, feetY - 1, z + 1, BLACKSTONE)
                        b.clear(x - 1, feetY, z - 1,
                                x + 1, feetY + 1, z + 1)
                    }
                    patrolDeck(x0 + 9, y, z0 + 3)              // lower promenade
                    patrolDeck(x0 + 8, y, z0 + 16)             // treasure approach
                    patrolDeck(x0 + 14, y + 2, z0 + 4)         // lower bridge deck
                    patrolDeck(x0 + 14, y + 8, z0 + 10)        // middle bridge deck
                    patrolDeck(x0 + W - 6, y + 14, z0 + 16)    // upper bridge deck

                    // The two interior guards use the treasure room's solid
                    // bottom course; the remaining guards stand on authored
                    // patrol decks rather than sampled bridge cells.
                    b.mob("piglin", cx + 3, y + 1, cz + 3, ["persistent": .bool(true)])
                    b.mob("piglin", cx - 3, y + 1, cz - 3, ["persistent": .bool(true)])
                    b.mob("piglin", x0 + 9, y, z0 + 3, ["persistent": .bool(true)])
                    b.mob("piglin_brute", x0 + 14, y + 2, z0 + 4, ["persistent": .bool(true)])
                    b.mob("piglin_brute", x0 + W - 6, y + 14, z0 + 16, ["persistent": .bool(true)])
                    b.mob("hoglin", x0 + 8, y, z0 + 16, ["persistent": .bool(true)])
                    b.mob("hoglin", x0 + 14, y + 8, z0 + 10, ["persistent": .bool(true)])
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
            let PUR_STAIR = Int(cell(B.purpur_stairs))
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
                    // shulker guarding each floor
                    b.mob("shulker", cx + (f % 2 == 0 ? 2 : -2), fy, cz + (f % 2 == 0 ? 2 : -2), ["persistent": .bool(true)])
                    // end rods
                    b.set(cx - 3, fy + 3, cz - 3, END_ROD)
                    b.set(cx + 3, fy + 3, cz + 3, END_ROD)
                }
                // door at base
                b.fill(cx, baseY, cz - 4, cx, baseY + 2, cz - 4, AIR)
                // Extend the doorway one supported cell beyond the tower so
                // a player can arrive from an all-air island edge rather than
                // appearing inside an isolated door opening.
                for dx in -1...1 {
                    b.foundation(cx + dx, baseY - 1, cz - 5, Int(cell(B.end_stone_bricks)), 6)
                    b.clear(cx + dx, baseY, cz - 5, cx + dx, baseY + 2, cz - 5)
                }
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

                // Each completed flight starts on one floor deck and ends on
                // the next.  The final six-tread flight cuts a controlled
                // roof hatch, so the roof loot is reachable too.  Build after
                // every floor/roof clear so a later deck cannot erase a tread.
                for f in 0..<floors {
                    let fy = baseY + f * 5
                    let risingEast = f % 2 == 0
                    let stairZ = cz + (risingEast ? -1 : 1)
                    let treadCount = f == floors - 1 ? 6 : 5
                    let startX = risingEast ? cx - 3 : cx + 2
                    for step in 0..<treadCount {
                        let stairX = risingEast ? startX + step : startX - step
                        if step > 0 {
                            b.fill(stairX, fy, stairZ, stairX, fy + step - 1, stairZ, PUR)
                        }
                        b.set(stairX, fy + step, stairZ, PUR_STAIR | (risingEast ? 3 : 2))
                        b.clear(stairX, fy + step + 1, stairZ,
                                stairX, fy + step + 2, stairZ)
                    }
                }
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
                    // The cabin walls establish their floor at sy + 3, so
                    // furnishing belongs one cell above it.  Writing loot at
                    // the floor level used to replace the floor itself and
                    // embed the chest in the deck.
                    b.chest(sx + 10, sy + 4, sz, 4, "end_city_treasure")
                    b.s.addBlockEntity(BESpec(x: sx + 11, y: sy + 4, z: sz, kind: "elytra_chest"))
                    b.set(sx + 11, sy + 4, sz, Int(cell(B.chest, 4)))
                    b.set(sx + 12, sy + 4, sz - 1, Int(cell(B.brewing_stand)))
                    b.mob("shulker", sx + 7, sy + 3, sz, ["persistent": .bool(true)])
                    b.mob("shulker", sx + 11, sy + 4, sz + 1, ["persistent": .bool(true)])

                    // The cabin is one block above the deck.  Its west wall
                    // now has a backed east-rising stair and a two-block arch
                    // rather than trapping the elytra chest behind solid
                    // purpur.
                    // Use the north deck slot so the threshold lands on an
                    // open cabin floor tile rather than directly into the
                    // centered chest pair.
                    let cabinEntryZ = sz - 1
                    b.set(sx + 8, sy + 3, cabinEntryZ, PUR_STAIR | 3)
                    b.clear(sx + 8, sy + 4, cabinEntryZ, sx + 8, sy + 5, cabinEntryZ)
                    b.clear(sx + 9, sy + 4, cabinEntryZ, sx + 9, sy + 5, cabinEntryZ)
                })
                // A short, supported bridge from the roof descends two blocks
                // onto the ship deck.  It is a later piece so the hull/deck
                // cannot overwrite its landing or headroom.
                let ty = baseY + floors * 5
                pieces.append(piece(cx + 5, ty - 3, cz - 1, sx + 3, ty + 2, cz + 1) { b in
                    b.fill(cx + 5, ty, cz, sx + 1, ty, cz, PUR)
                    for (step, stairX) in [(0, sx + 2), (1, sx + 3)] {
                        let stairY = ty - 1 - step
                        b.set(stairX, stairY - 1, cz, PUR)
                        b.set(stairX, stairY, cz, PUR_STAIR | 2)
                        b.clear(stairX, stairY + 1, cz, stairX, stairY + 2, cz)
                    }
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
    registerStructure(prehistoricVolcanoStructureDefinition())
}()
public func registerAllStructures() {
    _ = structuresRegistered
}
