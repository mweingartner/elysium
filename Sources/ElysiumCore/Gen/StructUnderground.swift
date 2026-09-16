// Underground structures —
// mineshafts, strongholds (with end portal room), ancient cities.

import Foundation

private let AIR = 0

private var strongholdCache: (seed: UInt32, positions: [(Int, Int)])?
/// Guards `strongholdCache`: `strongholdChunks` runs on every concurrent
/// chunk-generation GCD thread, and an unsynchronized seed-change
/// reassignment released the old positions array out from under a reader
/// (SIGSEGV in swift_release via `registerUndergroundStructures`'s check
/// closure — the recurring RPGCoreV2 multi-world test crash). NSLock is the
/// repo convention (Icons.swift's `iconSourceLock` etc.); determinism is
/// untouched — the cached value is a pure function of the seed.
private let strongholdCacheLock = NSLock()
private func strongholdChunks(_ seed: UInt32) -> [(Int, Int)] {
    strongholdCacheLock.lock()
    defer { strongholdCacheLock.unlock() }
    if strongholdCache == nil || strongholdCache!.seed != seed {
        strongholdCache = (seed, strongholdPositions(seed))
    }
    return strongholdCache!.positions
}

func registerUndergroundStructures() {
    registerStructure(StructureDef(
        // Radius covers the worst-case corridor walk plus the authored
        // three-block elevation ramps (about 106 blocks ≈ 7 chunks), so far
        // branches cannot be sliced off at chunk borders.
        id: "mineshaft", spacing: 16, separation: 4, salt: 30084232, maxRadiusChunks: 7,
        check: { _, _, _, rng in
            rng.nextFloat() < 0.25
        },
        plan: { _, ocx, ocz, rng in
            var pieces: [StructPiece] = []
            let baseY = -20 + rng.nextInt(50)
            let cx = ocx * 16 + 8, cz = ocz * 16 + 8
            let P = Int(cell(B.oak_planks)), F = Int(cell(B.oak_fence))
            let STAIR = Int(cell(B.oak_stairs))

            struct ElevationRamp {
                let x: Int, y: Int, z: Int
                let direction: Int, targetY: Int
            }
            struct LootAlcove {
                let x: Int, y: Int, z: Int
                let aisleX: Int, aisleZ: Int
                let facing: Int
            }
            struct RampFootprint {
                let x0: Int, y0: Int, z0: Int
                let x1: Int, y1: Int, z1: Int

                func overlaps(_ other: RampFootprint) -> Bool {
                    !(x1 < other.x0 || other.x1 < x0
                      || y1 < other.y0 || other.y1 < y0
                      || z1 < other.z0 || other.z1 < z0)
                }
            }
            // Connector and loot pieces stamp after every ordinary corridor
            // and nest.  That final order is part of their form contract:
            // no later cobweb, roof, or sibling corridor can reseal them.
            var elevationRamps: [ElevationRamp] = []
            var elevationRampFootprints: [RampFootprint] = []
            var lootAlcoves: [LootAlcove] = []

            /// Joins a branch that changes elevation with a three-wide,
            /// fully supported stair flight.  A child corridor begins one
            /// cell beyond the final tread, so neither closure can overwrite
            /// the other at a chunk seam or junction.
            func elevationRamp(_ x: Int, _ y: Int, _ z: Int,
                               _ direction: Int, _ targetY: Int) -> (x: Int, y: Int, z: Int) {
                let rise = targetY - y
                guard rise != 0 else { return (x, y, z) }
                let steps = abs(rise)
                let dx = FACE_DX[direction], dz = FACE_DZ[direction]
                let endX = x + dx * (steps + 1), endZ = z + dz * (steps + 1)
                let footprint = RampFootprint(
                    x0: min(x, endX) - (dz != 0 ? 1 : 0),
                    y0: min(y, targetY) - 1,
                    z0: min(z, endZ) - (dx != 0 ? 1 : 0),
                    x1: max(x, endX) + (dz != 0 ? 1 : 0),
                    y1: max(y, targetY) + 2,
                    z1: max(z, endZ) + (dx != 0 ? 1 : 0)
                )
                // A crossing stair flight would turn a safe three-wide ramp
                // into a clipped, ambiguous junction.  The height draw has
                // already been consumed, so flattening only this branch keeps
                // plan RNG stable while retaining a complete horizontal route.
                if elevationRampFootprints.contains(where: { $0.overlaps(footprint) }) {
                    return (x, y, z)
                }
                // Reserve it now, but emit it after all ordinary pieces.  A
                // cave-spider nest or a later sibling must not overwrite the
                // route's support or two-cell clearance.
                elevationRamps.append(ElevationRamp(x: x, y: y, z: z,
                                                     direction: direction, targetY: targetY))
                elevationRampFootprints.append(footprint)
                return (endX, targetY, endZ)
            }

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
                    // Repeated headings from one junction used to stack
                    // independent corridors (and, after an elevation change,
                    // incompatible ramps) on one footprint.  Membership is
                    // never iterated and is therefore deterministic.
                    var usedBranchDirections = [Bool](repeating: false, count: 4)
                    for _ in 0..<(branches + 1) {
                        let ndir = rng.nextInt(4)
                        if ndir == (dir ^ 1) || usedBranchDirections[ndir] { continue }
                        usedBranchDirections[ndir] = true
                        let ny = y + (rng.nextFloat() < 0.2 ? rng.nextInt(7) - 3 : 0)
                        // Draw the child length before adding geometry: plan
                        // RNG remains a pure, fixed-order function of this
                        // branch and never depends on target chunk contents.
                        let childLength = 8 + rng.nextInt(16)
                        let childStart = elevationRamp(ex, y, ez, ndir, ny)
                        corridor(childStart.x, childStart.y, childStart.z,
                                 ndir, childLength, depth + 1)
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
                        // Retain the three plan-time draws, but map them to a
                        // side alcove in this already-authored corridor.  The
                        // old random junction square could point into untouched
                        // rock, water, or a later branch and leave a loot chest
                        // suspended or impossible to reach.
                        let distanceDraw = rng.nextInt(5)
                        let sideDraw = rng.nextInt(5)
                        let facingDraw = rng.nextInt(4)
                        var safeSteps: [Int] = []
                        for step in 3...(len - 4) where step % 4 != 2 {
                            safeSteps.append(step)
                        }
                        // `len` is at least eight, so this contains at least
                        // the clear, non-supporting tread at index three.
                        let chestStep = safeSteps[(distanceDraw + facingDraw) % safeSteps.count]
                        let side = sideDraw & 1 == 0 ? -1 : 1
                        let centerX = x + dx * chestStep, centerZ = z + dz * chestStep
                        let lx = centerX + (dz != 0 ? side : 0)
                        let lz = centerZ + (dx != 0 ? side : 0)
                        let outwardDirection: Int
                        if dz != 0 { outwardDirection = side < 0 ? 2 : 3 }
                        else { outwardDirection = side < 0 ? 0 : 1 }
                        let facing = FACE_OPP[outwardDirection]
                        lootAlcoves.append(LootAlcove(x: lx, y: y, z: lz,
                                                      aisleX: centerX, aisleZ: centerZ,
                                                      facing: facing))
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
            for ramp in elevationRamps {
                let rise = ramp.targetY - ramp.y
                let steps = abs(rise)
                let dx = FACE_DX[ramp.direction], dz = FACE_DZ[ramp.direction]
                let endX = ramp.x + dx * (steps + 1), endZ = ramp.z + dz * (steps + 1)
                let minX = min(ramp.x, endX) - (dz != 0 ? 1 : 0)
                let maxX = max(ramp.x, endX) + (dz != 0 ? 1 : 0)
                let minZ = min(ramp.z, endZ) - (dx != 0 ? 1 : 0)
                let maxZ = max(ramp.z, endZ) + (dx != 0 ? 1 : 0)
                let lowY = min(ramp.y, ramp.targetY) - 1
                let highY = max(ramp.y, ramp.targetY) + 2
                pieces.append(piece(minX, lowY, minZ, maxX, highY, maxZ) { b in
                    for step in 1...steps {
                        let px = ramp.x + dx * step, pz = ramp.z + dz * step
                        let stairY = rise > 0 ? ramp.y + step - 1 : ramp.y - step
                        let stairFacing = rise > 0 ? ramp.direction : FACE_OPP[ramp.direction]
                        for width in -1...1 {
                            let wx = px + (dz != 0 ? width : 0)
                            let wz = pz + (dx != 0 ? width : 0)
                            // Each tread owns a solid support, rather than
                            // relying on terrain or a neighbouring stair.
                            b.set(wx, stairY - 1, wz, P)
                            b.clear(wx, stairY + 1, wz, wx, stairY + 2, wz)
                            b.set(wx, stairY, wz, STAIR | stairFacing)
                        }
                    }
                })
            }
            for alcove in lootAlcoves {
                // Include the aisle in the piece AABB too.  A chest on a
                // chunk edge may have its reachable aisle in the neighbour;
                // both chunks must replay the same support/clearance closure.
                pieces.append(piece(min(alcove.x, alcove.aisleX), alcove.y - 1,
                                    min(alcove.z, alcove.aisleZ),
                                    max(alcove.x, alcove.aisleX), alcove.y + 2,
                                    max(alcove.z, alcove.aisleZ)) { b in
                    // The chest and its adjacent aisle get explicit plank
                    // support and clearance.  This is needed in flooded/deep
                    // terrain too, not only in an all-air unit fixture.
                    b.set(alcove.x, alcove.y - 1, alcove.z, P)
                    b.clear(alcove.x, alcove.y + 1, alcove.z,
                            alcove.x, alcove.y + 2, alcove.z)
                    b.set(alcove.aisleX, alcove.y - 1, alcove.aisleZ, P)
                    b.clear(alcove.aisleX, alcove.y, alcove.aisleZ,
                            alcove.aisleX, alcove.y + 2, alcove.aisleZ)
                    b.chest(alcove.x, alcove.y, alcove.z, alcove.facing, "mineshaft")
                })
            }
            return StructurePlan(id: "mineshaft", pieces: pieces)
        }
    ))

    registerStructure(StructureDef(
        // The deterministic planner keeps every authored piece inside a
        // 160-block envelope around its ring origin.  Eleven chunks cover
        // that envelope plus room walls; too small and outer portal rooms get
        // sliced off at chunk borders.
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

            /// Builds a room around the endpoint of its incoming corridor.
            ///
            /// The corridor is emitted before its destination room so the
            /// room shell must explicitly restore the threshold afterwards.
            /// Keeping the room floor at the corridor's `y - 1` and carving
            /// this three-high arch after furnishings makes every authored
            /// transition a real walkable connection rather than a corridor
            /// hidden behind a later wall stamp.
            func room(_ x: Int, _ y: Int, _ z: Int, _ w: Int, _ h: Int, _ d: Int,
                      incomingX: Int, incomingZ: Int, incomingDirection: Int,
                      portalIngress: Bool = false,
                      _ fn: ((Builder, Int, Int, Int) -> Void)? = nil) {
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
                    // Furnishings are deliberately stamped before the route.
                    // This reserves a genuine three-wide connection from the
                    // arrival arch to the room's centre instead of allowing a
                    // fountain, shelf, or torch to block the only passage to
                    // the next corridor.  The terminal portal has its own
                    // side route so this general cross never cuts its lava or
                    // end-frame platform.
                    if portalIngress {
                        switch incomingDirection {
                        case 2: // enter east; route west only to the safe north approach
                            b.clear(x + 7, y, incomingZ - 1, x + w - 1, y + 2, incomingZ + 1)
                        case 3: // enter west; mirror the safe north approach
                            b.clear(x, y, incomingZ - 1, x + 3, y + 2, incomingZ + 1)
                        default:
                            break // portal planning only permits horizontal entries
                        }
                    } else {
                        switch incomingDirection {
                        case 0:
                            b.clear(incomingX - 1, y, incomingZ, incomingX + 1, y + 2, z + d - 1)
                        case 1:
                            b.clear(incomingX - 1, y, z, incomingX + 1, y + 2, incomingZ)
                        case 2:
                            b.clear(incomingX, y, incomingZ - 1, x + w - 1, y + 2, incomingZ + 1)
                        default:
                            b.clear(x, y, incomingZ - 1, incomingX, y + 2, incomingZ + 1)
                        }
                    }
                    // `incomingX` / `incomingZ` deliberately describe the
                    // corridor endpoint rather than the geometric centre of
                    // the shell.  Portal rooms are asymmetric along Z, so a
                    // centred doorway would miss their actual corridor.
                    switch incomingDirection {
                    case 0: // northbound corridor enters the south wall
                        b.clear(incomingX - 1, y, z + d, incomingX + 1, y + 2, z + d)
                    case 1: // southbound corridor enters the north wall
                        b.clear(incomingX - 1, y, z - 1, incomingX + 1, y + 2, z - 1)
                    case 2: // westbound corridor enters the east wall
                        b.clear(x + w, y, incomingZ - 1, x + w, y + 2, incomingZ + 1)
                    default: // eastbound corridor enters the west wall
                        b.clear(x - 1, y, incomingZ - 1, x - 1, y + 2, incomingZ + 1)
                    }
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

            // Rooms form a deterministic non-overlapping chain.  Earlier
            // code accepted the first random walk step unconditionally.  A
            // later room could then stamp over the entry shaft, a corridor, or
            // a previously placed chest.  Planning against emitted-piece
            // bounds is both cheaper and more reliable than trying to repair
            // collided blocks after the fact.
            var px = cx, py = baseY, pz = cz
            let roomCount = 6 + rng.nextInt(4)
            // A single seed-selected horizontal heading keeps the authored
            // route simple and prevents a random walk from folding back over
            // its own shaft, rooms, or loot.  Horizontal travel also gives
            // the asymmetric portal room its safe side entry.
            let heading = rng.nextInt(2) == 0 ? 2 : 3
            var anchorPieceIndex = pieces.count - 1
            var incomingCorridorIndex: Int?
            var incomingDirection: Int?
            let planningLimit = 160

            func overlapsExisting(_ x0: Int, _ y0: Int, _ z0: Int,
                                  _ x1: Int, _ y1: Int, _ z1: Int,
                                  excluding excluded: Set<Int> = []) -> Bool {
                for (index, existing) in pieces.enumerated() {
                    if excluded.contains(index) { continue }
                    if !(x1 < existing.x0 || existing.x1 < x0
                         || y1 < existing.y0 || existing.y1 < y0
                         || z1 < existing.z0 || existing.z1 < z0) {
                        return true
                    }
                }
                return false
            }

            func insidePlanningEnvelope(_ x0: Int, _ z0: Int, _ x1: Int, _ z1: Int) -> Bool {
                x0 >= cx - planningLimit && x1 <= cx + planningLimit
                    && z0 >= cz - planningLimit && z1 <= cz + planningLimit
            }

            for i in 0..<roomCount {
                let kind = i == roomCount - 1 ? "portal" : rng.pick(["plain", "library", "fountain", "storage", "plain"])
                let roomShape: (width: Int, height: Int, depth: Int, offsetX: Int, offsetZ: Int)
                switch kind {
                case "library": roomShape = (11, 7, 11, 5, 5)
                // A portal is entered at its northern approach row rather
                // than through its geometric centre; its lava/dais occupies
                // the centre and must remain intact.
                case "portal": roomShape = (11, 8, 13, 5, 4)
                default: roomShape = (7, 5, 7, 3, 3)
                }
                // Thirteen blocks separates even two full 11-wide room shells
                // by one cell; the bounded variation keeps each stronghold
                // recognizably varied without permitting a self-intersection.
                let preferredLength = 13 + rng.nextInt(5)
                let directionCandidates = [heading]
                var choice: (dir: Int, len: Int)?
                // Consume a fixed plan length draw, then try a bounded
                // geometric order.  This keeps results deterministic while
                // preserving the non-overlapping architectural chain.
                candidateSearch: for extraDistance in stride(from: 0, through: 32, by: 2) {
                    for candidateDir in directionCandidates {
                        let candidateLength = preferredLength + extraDistance
                        let dx = [0, 0, -1, 1][candidateDir]
                        let dz = [-1, 1, 0, 0][candidateDir]
                        let ex = px + dx * candidateLength
                        let ez = pz + dz * candidateLength
                        let corridorX0 = min(px, ex) - 2, corridorX1 = max(px, ex) + 2
                        let corridorZ0 = min(pz, ez) - 2, corridorZ1 = max(pz, ez) + 2
                        let roomX = ex - roomShape.offsetX, roomZ = ez - roomShape.offsetZ
                        let roomX0 = roomX - 1, roomX1 = roomX + roomShape.width + 1
                        let roomZ0 = roomZ - 1, roomZ1 = roomZ + roomShape.depth + 1
                        // A new corridor may continue through, or turn inside,
                        // the room just reached.  It must not double back over
                        // its incoming tunnel, which would overwrite the
                        // already-reserved route instead of extending it.
                        if let incomingDirection, candidateDir == (incomingDirection ^ 1) {
                            continue
                        }
                        var corridorExclusions: Set<Int> = [anchorPieceIndex]
                        if let incomingCorridorIndex { corridorExclusions.insert(incomingCorridorIndex) }
                        guard insidePlanningEnvelope(corridorX0, corridorZ0, corridorX1, corridorZ1),
                              insidePlanningEnvelope(roomX0, roomZ0, roomX1, roomZ1),
                              !overlapsExisting(corridorX0, py - 1, corridorZ0,
                                                corridorX1, py + 4, corridorZ1,
                                                excluding: corridorExclusions),
                              !overlapsExisting(roomX0, py - 1, roomZ0,
                                                roomX1, py + roomShape.height + 1, roomZ1) else {
                            continue
                        }
                        choice = (candidateDir, candidateLength)
                        break candidateSearch
                    }
                }
                // The bounded envelope and progressively longer candidates
                // leave abundant open space for the at-most-nine-room chain.
                // Failing closed here is preferable to emitting a sealed,
                // overlapping landmark.
                guard let choice else { return nil }
                let dir = choice.dir, len = choice.len
                incomingCorridorIndex = pieces.count
                (px, py, pz) = corridorPiece(px, py, pz, dir, len)
                if kind == "plain" {
                    room(px - 3, py, pz - 3, 7, 5, 7,
                         incomingX: px, incomingZ: pz, incomingDirection: dir)
                } else if kind == "library" {
                    room(px - 5, py, pz - 5, 11, 7, 11,
                         incomingX: px, incomingZ: pz, incomingDirection: dir) { b, x, y, z in
                        for bx in [1, 4, 7] {
                            for dz2 in 1..<10 {
                                if dz2 % 3 == 0 { continue }
                                for h in 0..<3 { b.set(x + bx, y + h, z + dz2, Int(cell(B.bookshelf))) }
                            }
                        }
                        b.chest(x + 9, y, z + 1, 2, "stronghold_library")
                        // Keep both library chests on the authored floor.  A
                        // former upper chest had no shelf, ladder, or floor
                        // beneath it, leaving loot suspended out of reach.
                        b.chest(x + 9, y, z + 9, 0, "stronghold_library")
                        for _ in 0..<8 {
                            let wx = x + 1 + b.rng.nextInt(9), wy = y + b.rng.nextInt(5), wz = z + 1 + b.rng.nextInt(9)
                            // draw before the chunk-relative get() so the rng
                            // stream stays identical across bordering chunks
                            let place = b.rng.nextFloat() < 0.5
                            if place && b.get(wx, wy, wz) == 0 { b.set(wx, wy, wz, Int(cell(B.cobweb))) }
                        }
                    }
                } else if kind == "fountain" {
                    room(px - 3, py, pz - 3, 7, 5, 7,
                         incomingX: px, incomingZ: pz, incomingDirection: dir) { b, x, y, z in
                        b.set(x + 3, y, z + 3, Int(cell(B.water, 0)))
                        b.fill(x + 2, y, z + 2, x + 4, y, z + 4, Int(cell(B.stone_brick_slab, 0)))
                        b.set(x + 3, y, z + 3, Int(cell(B.water, 0)))
                    }
                } else if kind == "storage" {
                    room(px - 3, py, pz - 3, 7, 5, 7,
                         incomingX: px, incomingZ: pz, incomingDirection: dir) { b, x, y, z in
                        // Keep storage at a corner outside the five-wide
                        // transit cross carved by the next corridor piece.
                        // That prevents a later corridor from erasing its
                        // chest while leaving a stale loot block entity.
                        b.chest(x, y, z, 1, "stronghold_corridor")
                        b.set(x + 6, y, z + 6, Int(cell(B.cobblestone)))
                        b.set(x + 6, y + 1, z + 6, Int(cell(B.torch, 0)))
                    }
                } else if kind == "portal" {
                    // PORTAL ROOM
                    room(px - 5, py, pz - 4, 11, 8, 13,
                         incomingX: px, incomingZ: pz, incomingDirection: dir,
                         portalIngress: true) { b, x, y, z in
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
                        // A single supported, south-rising three-wide step
                        // meets the one-block-high portal dais.  The previous
                        // diagonal decorations rose two blocks above the
                        // platform and left no usable route to it.
                        b.fill(x + 4, y - 1, z + 5, x + 6, y - 1, z + 5,
                               Int(cell(B.stone_bricks)))
                        b.clear(x + 4, y + 1, z + 5, x + 6, y + 2, z + 5)
                        b.fill(x + 4, y, z + 5, x + 6, y, z + 5,
                               Int(cell(B.stone_brick_stairs, 1)))
                        // Keep the silverfish spawner grounded but away from
                        // the portal approach and its required headroom.
                        b.spawner(x + 8, y, z + 10, "silverfish")
                        // infested blocks scattered (get() is -1 outside the
                        // building chunk — never feed that to UInt16)
                        for _ in 0..<10 {
                            let wx = x + b.rng.nextInt(11), wy = y + b.rng.nextInt(3), wz = z + b.rng.nextInt(13)
                            let cur = b.get(wx, wy, wz)
                            if cur > 0 && UInt16(cur >> 4) == B.stone_bricks { b.set(wx, wy, wz, Int(cell(B.infested_stone_bricks))) }
                        }
                    }
                }
                anchorPieceIndex = pieces.count - 1
                incomingDirection = dir
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
            struct SideBuildingEntry {
                let x: Int
                let wallZ: Int
                let boulevardZ: Int
            }
            /// The exact emitted piece envelope, not just the interior room.
            /// The shell deliberately extends one cell around the room, so an
            /// interior-only reservation is not enough to prevent a later
            /// ruin from stamping through it.
            struct SideBuildingReservation {
                let x0: Int, y0: Int, z0: Int
                let x1: Int, y1: Int, z1: Int

                func intersects(_ other: SideBuildingReservation) -> Bool {
                    !(x1 < other.x0 || other.x1 < x0
                      || y1 < other.y0 || other.y1 < y0
                      || z1 < other.z0 || other.z1 < z0)
                }
            }
            // The ruin shells are intentionally weathered, but a randomized
            // perimeter must never turn a generated loot room into a sealed
            // box.  Entrances are emitted after every shell so subsequent
            // decorative stamps cannot close their route to the boulevard.
            // Reserve the same AABBs that have already been (or will be)
            // emitted for the city's core.  This is declared before candidate
            // selection so a side shell can never reach the central frame or
            // a boulevard, even at the edge of its randomized footprint.
            let centralChamberReservation = SideBuildingReservation(
                x0: cx - 20, y0: y - 3, z0: cz - 12,
                x1: cx + 20, y1: y + 22, z1: cz + 12
            )
            let boulevardReservations = [
                SideBuildingReservation(
                    x0: cx - 76, y0: y - 2, z0: cz - 5,
                    x1: cx - 20, y1: y + 12, z1: cz + 5
                ),
                SideBuildingReservation(
                    x0: cx + 20, y0: y - 2, z0: cz - 5,
                    x1: cx + 76, y1: y + 12, z1: cz + 5
                )
            ]
            let protectedSideShellReservations = [centralChamberReservation]
                + boulevardReservations
            var sideBuildingEntries: [SideBuildingEntry] = []
            var acceptedSideShells: [SideBuildingReservation] = []
            var acceptedSideRoutes: [SideBuildingReservation] = []
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
                    // The south-side ruins used to start at a negative Z but
                    // still grow northward.  Their later pieces could then
                    // overwrite the boulevard they are meant to flank.  Pick
                    // the side before dimensions, then mirror its footprint
                    // wholly away from the nine-wide public route.
                    let side = rng.nextBoolean() ? 1 : -1
                    let sideDistance = 7 + rng.nextInt(8)
                    let w = 5 + rng.nextInt(5), d = 5 + rng.nextInt(5), h = 4 + rng.nextInt(3)
                    let bz = side > 0 ? cz + sideDistance : cz - sideDistance - d
                    let entryX = bx + w / 2
                    let entryWallZ = side > 0 ? bz : bz + d
                    // Match the shell piece below exactly.  Reserving only
                    // `bx...bx + w` / `bz...bz + d` omitted its expanded
                    // border and allowed an east-most west-side ruin to
                    // intrude into the central chamber.
                    let shellReservation = SideBuildingReservation(
                        x0: bx - 1, y0: y - 2, z0: bz - 1,
                        x1: bx + w + 1, y1: y + h + 6, z1: bz + d + 1
                    )
                    let routeReservation = SideBuildingReservation(
                        x0: entryX - 1, y0: y - 1,
                        z0: min(entryWallZ, cz + side * 3),
                        x1: entryX + 1, y1: y + 2,
                        z1: max(entryWallZ, cz + side * 3)
                    )
                    // Do not let a later ruin turn an earlier chest, shell,
                    // or already-paved ingress into an overlap artifact.
                    // Candidate RNG has already been consumed above, so a
                    // rejected footprint changes only the unsafe geometry,
                    // never the deterministic stream of later candidates.
                    let shellCollides = protectedSideShellReservations.contains {
                        shellReservation.intersects($0)
                    } || acceptedSideShells.contains {
                        shellReservation.intersects($0)
                    } || acceptedSideRoutes.contains {
                        shellReservation.intersects($0)
                    }
                    // Each side route intentionally joins its boulevard at
                    // `cz +/- 3`; the route is therefore checked against the
                    // central chamber and prior side reservations, but not
                    // against the boulevard AABB it is authored to contact.
                    let routeCollides = centralChamberReservation.intersects(routeReservation)
                        || acceptedSideShells.contains {
                            routeReservation.intersects($0)
                        } || acceptedSideRoutes.contains {
                            routeReservation.intersects($0)
                        }
                    guard !shellCollides && !routeCollides else { continue }
                    acceptedSideShells.append(shellReservation)
                    acceptedSideRoutes.append(routeReservation)
                    sideBuildingEntries.append(SideBuildingEntry(
                        x: entryX,
                        wallZ: entryWallZ,
                        boulevardZ: cz + side * 3
                    ))
                    pieces.append(piece(shellReservation.x0, shellReservation.y0, shellReservation.z0,
                                        shellReservation.x1, shellReservation.y1, shellReservation.z1) { b in
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
                        let chestLocation: (x: Int, z: Int)?
                        if b.rng.nextFloat() < 0.7 {
                            chestLocation = (
                                bx + 1 + b.rng.nextInt(max(1, w - 1)),
                                bz + 1 + b.rng.nextInt(max(1, d - 1))
                            )
                            b.chest(chestLocation!.x, y, chestLocation!.z, 0, "ancient_city")
                        } else {
                            chestLocation = nil
                        }
                        let sensorX = bx + 2, sensorZ = bz + 2
                        let sensorWouldReplaceChest = chestLocation?.x == sensorX
                            && chestLocation?.z == sensorZ
                        if b.rng.nextFloat() < 0.4
                            && !sensorWouldReplaceChest {
                            b.set(sensorX, y, sensorZ, Int(cell(B.sculk_sensor)))
                        }
                        let shriekerX = bx + w - 1, shriekerZ = bz + d - 1
                        let shriekerWouldReplaceChest = chestLocation?.x == shriekerX
                            && chestLocation?.z == shriekerZ
                        if b.rng.nextFloat() < 0.25
                            && !shriekerWouldReplaceChest {
                            b.set(shriekerX, y, shriekerZ, Int(cell(B.sculk_shrieker)))
                            b.s.addBlockEntity(BESpec(x: shriekerX, y: y, z: shriekerZ, kind: "shrieker", data: ["canSummon": .bool(true)]))
                        }
                        // candles + skulls flavor
                        let candleX = bx + 1, candleZ = bz + d - 1
                        let candleWouldReplaceChest = chestLocation?.x == candleX
                            && chestLocation?.z == candleZ
                        if b.rng.nextFloat() < 0.5
                            && !candleWouldReplaceChest {
                            b.set(candleX, y, candleZ, Int(cell(B.candle, 2 | 8)))
                        }
                        let skullX = bx + w - 1, skullZ = bz + 1
                        let skullWouldReplaceChest = chestLocation?.x == skullX
                            && chestLocation?.z == skullZ
                        if b.rng.nextFloat() < 0.3
                            && !skullWouldReplaceChest {
                            b.set(skullX, y, skullZ, Int(cell(B.skeleton_skull)))
                        }
                    })
                }
            }
            for entry in sideBuildingEntries {
                let z0 = min(entry.wallZ, entry.boulevardZ)
                let z1 = max(entry.wallZ, entry.boulevardZ)
                pieces.append(piece(entry.x - 1, y - 1, z0,
                                    entry.x + 1, y + 2, z1) { b in
                    // Ancient City side buildings are ruins, so this is an
                    // intentionally open three-wide arch rather than a
                    // pristine modern door.  It is nevertheless a complete,
                    // supported player route from the boulevard to the room.
                    for z in z0...z1 {
                        for x in (entry.x - 1)...(entry.x + 1) {
                            b.set(x, y - 1, z, Int(cell(B.deepslate_bricks)))
                            b.clear(x, y, z, x, y + 2, z)
                        }
                    }
                })
            }
            // ice box room
            pieces.append(piece(cx - 14, y - 1, cz - 22, cx - 6, y + 6, cz - 11) { b in
                b.walls(cx - 14, y, cz - 22, cx - 6, y + 5, cz - 14, Int(cell(B.deepslate_bricks)), AIR)
                b.fill(cx - 12, y + 1, cz - 20, cx - 8, y + 2, cz - 16, Int(cell(B.packed_ice)))
                b.chest(cx - 10, y + 3, cz - 18, 0, "ancient_city")
                // The ice box is a raised room, not a dig-only loot pocket.
                // Restore its three-wide southern arch after the shell, pave
                // the short link from the central chamber, and give its
                // one-block threshold a north-rising, fully supported stair.
                b.fill(cx - 11, y - 1, cz - 14, cx - 9, y - 1, cz - 11,
                       Int(cell(B.deepslate_bricks)))
                b.clear(cx - 11, y, cz - 14, cx - 9, y + 2, cz - 11)
                b.fill(cx - 11, y, cz - 14, cx - 9, y, cz - 14,
                       Int(cell(B.stone_brick_stairs, 0)))
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
