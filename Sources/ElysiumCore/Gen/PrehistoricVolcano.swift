// Small, dormant prehistoric volcanoes. Planning reads only exact immutable
// terrain; emission replays the same bounded piece in every intersecting chunk.

import Foundation

let prehistoricVolcanoStructureID = "prehistoric_volcano"

/// The whole starter grove reaches twelve blocks from its centre. Keep an
/// additional sixteen-block dry approach between that envelope and hot rock.
func prehistoricVolcanoAvoidsShelter(x: Int, z: Int, radius: Int,
                                     shelter: PrehistoricStarterShelterSite?) -> Bool {
    guard let shelter else { return true }
    let protectedRadius = 12 + 16
    return x + radius < shelter.x - protectedRadius
        || x - radius > shelter.x + protectedRadius
        || z + radius < shelter.z - protectedRadius
        || z - radius > shelter.z + protectedRadius
}

/// An exact-surface seam keeps wet/unsupported/steep rejection testable
/// without replacing the production planner with an approximate height map.
func planPrehistoricVolcano(seed: UInt32, x: Int, z: Int, radius: Int,
                            height: Int, craterRadius: Int,
                            surfaceAt: (Int, Int) -> ExactTerrainSurface?,
                            cellAt: (Int, Int, Int) -> Int?) -> StructurePlan? {
    guard (10...14).contains(radius), (8...11).contains(height),
          (2...3).contains(craterRadius) else { return nil }
    struct Column {
        let x: Int
        let z: Int
        let groundY: Int
        let distance: Double
    }
    var columns: [Column] = []
    var low = Int.max, high = Int.min
    for dz in -radius...radius {
        for dx in -radius...radius {
            let distance = detHyp(Double(dx), Double(dz))
            guard distance <= Double(radius) else { continue }
            let px = x + dx, pz = z + dz
            guard let surface = surfaceAt(px, pz), surface.isDry,
                  surface.feetY > DIMS[Dim.overworld.rawValue].seaLevel + 2 else { return nil }
            // Reject a thin unsupported cave roof instead of plugging an
            // unknown void with an unbounded foundation.
            for depth in 1...3 {
                guard let c = cellAt(px, surface.feetY - depth, pz), c > 0,
                      c >> 4 < SOLID.count, SOLID[c >> 4] == 1,
                      c >> 4 != Int(B.water), c >> 4 != Int(B.lava) else { return nil }
            }
            low = min(low, surface.feetY)
            high = max(high, surface.feetY)
            guard high - low <= 6 else { return nil }
            columns.append(Column(x: px, z: pz, groundY: surface.feetY - 1, distance: distance))
        }
    }
    let summitY = high - 1 + height
    guard !columns.isEmpty, summitY + 2 < GEN_MIN_Y + WORLD_H else { return nil }
    let lavaY = summitY - 2
    let shapeSeed = hash2(seed, x, z, 0x701C_A110)
    return StructurePlan(id: prehistoricVolcanoStructureID, pieces: [
        piece(x - radius, low - 1, z - radius, x + radius, summitY + 1, z + radius) { builder in
            for column in columns {
                let dx = column.x - x, dz = column.z - z
                let inCrater = dx * dx + dz * dz <= craterRadius * craterRadius
                let slope = clampD((Double(radius) - column.distance)
                                    / Double(radius - craterRadius - 1), 0, 1)
                var topY = column.groundY
                    + Int((Double(summitY - column.groundY) * slope).rounded(.down))
                // Low shoulders vary by position, while the complete crater
                // rim stays at a fixed height above its contained lava pool.
                if column.distance > Double(craterRadius + 2), slope > 0.15 {
                    topY += Int(hash2(shapeSeed, floorDiv(column.x, 3), floorDiv(column.z, 3), 7) % 3) - 1
                }
                topY = max(column.groundY, min(summitY, topY))
                for y in column.groundY...topY {
                    let materialHash = hash3(shapeSeed, column.x, y, column.z, 11)
                    let material: UInt16 = materialHash % 9 == 0 ? B.stone
                        : materialHash % 5 == 0 ? B.blackstone : B.basalt
                    builder.set(column.x, y, column.z, Int(cell(material)))
                }
                if inCrater {
                    // A solid two-block bed, a single source-lava layer, and
                    // a raised continuous rim contain the pool at rest.
                    builder.set(column.x, lavaY - 1, column.z, Int(cell(B.basalt)))
                    builder.set(column.x, lavaY, column.z, Int(cell(B.lava)))
                    builder.clear(column.x, lavaY + 1, column.z, column.x, summitY + 1, column.z)
                } else if column.distance <= Double(craterRadius + 1) {
                    builder.set(column.x, topY, column.z, Int(cell(B.magma_block)))
                }
            }
        },
    ], ref: StructRefBox(x - radius, low - 1, z - radius,
                         x + radius, summitY + 1, z + radius))
}

func prehistoricVolcanoStructureDefinition() -> StructureDef {
    StructureDef(
        id: prehistoricVolcanoStructureID, spacing: 24, separation: 8,
        salt: 0x701C_A103, maxRadiusChunks: 2,
        placement: { context in
            guard context.dim == Dim.overworld.rawValue,
                  context.terrainOracle?.settings.preset.supportsVolcanicTerrain == true else { return nil }
            return StructurePlacement(spacing: 24, separation: 8)
        },
        check: { context, _, _, _ in
            context.dim == Dim.overworld.rawValue
                && context.terrainOracle?.settings.preset.supportsVolcanicTerrain == true
        },
        plan: { context, ocx, ocz, rng in
            guard let oracle = context.terrainOracle else { return nil }
            let x = ocx * CHUNK_W + CHUNK_W / 2
            let z = ocz * CHUNK_W + CHUNK_W / 2
            let radius = 10 + rng.nextInt(5)
            let height = 8 + rng.nextInt(4)
            let craterRadius = 2 + rng.nextInt(2)
            let shelter = prehistoricStarterShelterSite(seed: context.seed, settings: oracle.settings)
            guard prehistoricVolcanoAvoidsShelter(x: x, z: z, radius: radius, shelter: shelter) else { return nil }
            return planPrehistoricVolcano(seed: context.seed, x: x, z: z, radius: radius,
                                          height: height, craterRadius: craterRadius,
                                          surfaceAt: oracle.exactSurface,
                                          cellAt: oracle.cell)
        })
}

private struct VolcanoAdmissionKey: Hashable {
    let seed: UInt32
    let dimension: Int
    let settings: String
    let oracleVersion: Int
    let domain: String
    let pieces: String
}

private let volcanoAdmissionLock = NSLock()
private var volcanoAdmissions: [VolcanoAdmissionKey: Bool] = [:]

func resetPrehistoricVolcanoAdmissionCacheForTesting() {
    volcanoAdmissionLock.withLock { volcanoAdmissions.removeAll() }
}

/// Strongholds use a finite ring, not the apparent spacing-one lattice.
/// Enumerating that lattice would evict the entire 600-entry plan cache with
/// hundreds of guaranteed rejections for a single small volcanic footprint.
func prehistoricVolcanoCollisionOrigins(for def: StructureDef, placement: StructurePlacement,
                                        seed: UInt32, piece: StructPiece) -> [(Int, Int)] {
    let radius = def.maxRadiusChunks
    let minX = floorDiv(piece.x0, CHUNK_W) - radius
    let maxX = floorDiv(piece.x1, CHUNK_W) + radius
    let minZ = floorDiv(piece.z0, CHUNK_W) - radius
    let maxZ = floorDiv(piece.z1, CHUNK_W) + radius
    if def.id == "stronghold", def.salt == 0,
       placement.spacing == 1, placement.separation == 0 {
        return strongholdPositions(seed).filter {
            $0.0 >= minX && $0.0 <= maxX && $0.1 >= minZ && $0.1 <= maxZ
        }
    }
    var origins: [(Int, Int)] = []
    for rz in floorDiv(minZ, placement.spacing)...floorDiv(maxZ, placement.spacing) {
        for rx in floorDiv(minX, placement.spacing)...floorDiv(maxX, placement.spacing) {
            let origin = structureOriginFor(def, placement: placement, seed: seed, regionX: rx, regionZ: rz)
            if origin.0 >= minX, origin.0 <= maxX, origin.1 >= minZ, origin.1 <= maxZ {
                origins.append(origin)
            }
        }
    }
    return origins
}

/// Volcanoes always yield to existing structures. This is called only after
/// their raw plan has completed, and other plans receive a volcano-free
/// domain, so no cache computation can recursively wait on its own plan.
func prehistoricVolcanoPlanWins(_ plan: StructurePlan, _ context: GenCtx,
                                collisionDefinitions: [StructureDef]) -> Bool {
    let otherDefinitions = collisionDefinitions.filter { $0.id != prehistoricVolcanoStructureID }
    let key = VolcanoAdmissionKey(
        seed: context.seed, dimension: context.dim, settings: context.generationSettingsIdentity,
        oracleVersion: context.baseTerrainOracleVersion,
        domain: structureDefinitionDomainIdentity(otherDefinitions),
        pieces: plan.pieces.map { "\($0.x0),\($0.y0),\($0.z0):\($0.x1),\($0.y1),\($0.z1)" }.joined(separator: "|"))
    if let cached = volcanoAdmissionLock.withLock({ volcanoAdmissions[key] }) { return cached }
    let otherContext = GenCtx(
        seed: context.seed, heightAt: context.heightAt, biomeAt: context.biomeAt,
        dim: context.dim, villageDensity: context.villageDensity,
        generationSettingsIdentity: context.generationSettingsIdentity,
        baseTerrainOracleVersion: context.baseTerrainOracleVersion,
        terrainOracle: context.terrainOracle, activeStructureDefinitions: otherDefinitions)
    var accepted = !plan.pieces.isEmpty
    candidateLoop: for def in otherDefinitions {
        guard let placement = def.placement(otherContext) else { continue }
        for volcanicPiece in plan.pieces {
            let origins = prehistoricVolcanoCollisionOrigins(for: def, placement: placement,
                                                              seed: context.seed, piece: volcanicPiece)
            for origin in origins {
                guard let other = getPlan(def, otherContext, origin.0, origin.1),
                      surfaceStructurePlanWins(def, other, otherContext, origin.0, origin.1,
                                               collisionDefinitions: otherDefinitions) else { continue }
                for piece in other.pieces {
                    if !(volcanicPiece.x1 < piece.x0 || volcanicPiece.x0 > piece.x1
                         || volcanicPiece.y1 < piece.y0 || volcanicPiece.y0 > piece.y1
                         || volcanicPiece.z1 < piece.z0 || volcanicPiece.z0 > piece.z1) {
                        accepted = false
                        break candidateLoop
                    }
                }
            }
        }
    }
    volcanoAdmissionLock.withLock {
        if volcanoAdmissions.count >= 2_048 { volcanoAdmissions.removeAll(keepingCapacity: true) }
        volcanoAdmissions[key] = accepted
    }
    return accepted
}
