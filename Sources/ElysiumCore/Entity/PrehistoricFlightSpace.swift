// Where a flying prehistoric creature fits. One owner for the questions the flight controller
// and every spawn path ask: can spread wings pass here, can a flyer stand here, can it climb
// from here, and so may one be placed here. Everything is RNG-free block reads over a bounded
// box, so asking never perturbs a controller's random stream.
import Foundation

/// How far above its first choice a flyer looks for the height where its wings have room.
let PREHISTORIC_FLYER_LIFT_SEARCH = 16

/// The height no flyer aims above: four cells under the top of the world.
func prehistoricFlightCeiling(_ world: World) -> Double {
    Double(world.info.minY + world.info.height - 4)
}

/// A cell neither a body nor a wing passes: water, lava, or any block that is not replaceable.
@inline(__always)
func prehistoricFlightCellIsBlocked(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    let block = world.getBlock(x, y, z) >> 4
    return block == Int(B.water) || block == Int(B.lava)
        || (block != 0 && (block >= blockDefs.count || !blockDefs[block].replaceable))
}

/// A cell a folded body cannot climb through: a block that is neither replaceable nor a fluid.
/// Water and lava do not hold a flyer down; it has always risen out of them.
@inline(__always)
func prehistoricClimbCellIsBlocked(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    let block = world.getBlock(x, y, z) >> 4
    guard block != 0, block != Int(B.water), block != Int(B.lava) else { return false }
    return block >= blockDefs.count || !blockDefs[block].replaceable
}

extension PrehistoricCreatureDefinition {
    /// Whether the body with spread wings fits with its feet at `py` over the column of `px, pz`.
    /// An unloaded column is no room.
    func flightSpaceIsClear(in world: World, _ px: Double, _ py: Double, _ pz: Double) -> Bool {
        let radius = flightOpenClearanceRadius
        let lower = ifloor(py)
        let upper = max(lower, flyerBodyTop(feetAt: py))
        for zz in (ifloor(pz) - radius)...(ifloor(pz) + radius) {
            for xx in (ifloor(px) - radius)...(ifloor(px) + radius) {
                guard world.isLoadedAt(xx, zz) else { return false }
                for yy in lower...upper where prehistoricFlightCellIsBlocked(world, xx, yy, zz) { return false }
            }
        }
        return true
    }

    /// Whether a flyer can stand at `x, y, z`: solid ground under its folded body, and under its
    /// spread wings the room an approach needs, three cells more than the body is high.
    func flyerPerchIsClear(in world: World, x: Int, y: Int, z: Int) -> Bool {
        let foldedRadius = flightFoldedClearanceRadius
        let openRadius = flightOpenClearanceRadius
        for zz in (z - openRadius)...(z + openRadius) {
            for xx in (x - openRadius)...(x + openRadius) {
                guard world.isLoadedAt(xx, zz) else { return false }
                if abs(xx - x) <= foldedRadius && abs(zz - z) <= foldedRadius {
                    let ground = world.getBlock(xx, y - 1, zz) >> 4
                    guard ground > 0, ground < blockDefs.count, blockDefs[ground].solid else { return false }
                }
                for yy in y..<(y + bodyClearanceHeight + 3) where prehistoricFlightCellIsBlocked(world, xx, yy, zz) {
                    return false
                }
            }
        }
        return true
    }

    /// The place on top of the column `x, z` where a flyer may land, if it may land there.
    func flyerLandingTarget(in world: World, x: Int, z: Int) -> (x: Double, y: Double, z: Double)? {
        guard world.isLoadedAt(x, z) else { return nil }
        let y = world.surfaceY(x, z)
        guard y > world.info.minY, flyerPerchIsClear(in: world, x: x, y: y, z: z) else { return nil }
        return (Double(x) + 0.5, Double(y), Double(z) + 0.5)
    }

    /// Whether the body alone, wings folded, can climb through the cells its collision box
    /// covers around `px, pz`, from `lowerY` through `upperY`.
    func flyerBodyColumnIsClear(in world: World, _ px: Double, _ pz: Double,
                                from lowerY: Int, through upperY: Int) -> Bool {
        // Outside the world every cell reads as air, so asking only inside it changes no answer
        // and keeps the walk as short as the world is high, wherever the flyer has been put.
        let lowerY = max(lowerY, world.info.minY), upperY = min(upperY, world.info.minY + world.info.height - 1)
        guard lowerY <= upperY else { return true }
        let half = collisionWidth / 2
        for zz in ifloor(pz - half)...ifloor(pz + half - 0.000_001) {
            for xx in ifloor(px - half)...ifloor(px + half - 0.000_001) {
                guard world.isLoadedAt(xx, zz) else { return false }
                for yy in lowerY...upperY where prehistoricClimbCellIsBlocked(world, xx, yy, zz) { return false }
            }
        }
        return true
    }

    /// The highest cell the body needs free with its feet at `py`.
    func flyerBodyTop(feetAt py: Double) -> Int {
        ifloor(py + Double(bodyClearanceHeight) - 0.000_001)
    }

    /// The highest cell the collision box is in with its feet at `py`. A climb is not asked
    /// about the cells up to here: the body is in them already.
    func flyerHeadCell(feetAt py: Double) -> Int {
        ifloor(py + collisionHeight - 0.000_001)
    }

    /// Whether a flyer at `from` can fly to `target`. A climb or a drop straight up or down its
    /// own place is made with the wings folded, so only the body has to fit: that is how a small
    /// flyer leaves a gap in a canopy that is narrower than its wings. Every other route is
    /// swept with the wings spread, and one that ends in a landing has to end on a perch.
    func flightRouteIsClear(in world: World, from: (x: Double, y: Double, z: Double),
                            to target: (x: Double, y: Double, z: Double), landing: Bool) -> Bool {
        let dx = target.x - from.x, dy = target.y - from.y, dz = target.z - from.z
        if !landing, abs(dx) < 0.05, abs(dz) < 0.05 {
            let below = ifloor(min(from.y, target.y)), above = flyerBodyTop(feetAt: max(from.y, target.y))
            return flyerBodyColumnIsClear(in: world, from.x, from.z, from: below, through: ifloor(from.y) - 1)
                && flyerBodyColumnIsClear(in: world, from.x, from.z,
                                          from: flyerHeadCell(feetAt: from.y) + 1, through: above)
        }
        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
        let steps = max(1, min(24, Int((distance / 1.5).rounded(.up))))
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let px = from.x + dx * fraction, py = from.y + dy * fraction, pz = from.z + dz * fraction
            if landing && step == steps {
                guard flyerLandingTarget(in: world, x: ifloor(px), z: ifloor(pz)) != nil else { return false }
            } else if !flightSpaceIsClear(in: world, px, py, pz) {
                return false
            }
        }
        return true
    }

    /// Straight up from `px, py, pz`: the lowest height at which the wings have room, when the
    /// folded body fits all the way up to it. The first choice is four cells above the flyer and
    /// above the top of its column, as before; the search above it is bounded, and a roof over
    /// the flyer ends it, because a body does not pass a roof. With `toOpenSky`, the height
    /// also has to be above everything the heightmap knows under the spread wings (whatever
    /// stops light: ground, leaves, a built roof; a glass roof is not seen).
    func flyerLift(in world: World, _ px: Double, _ py: Double, _ pz: Double,
                   toOpenSky: Bool = false) -> (x: Double, y: Double, z: Double)? {
        let ceiling = prehistoricFlightCeiling(world)
        let first = min(ceiling, max(Double(world.surfaceY(ifloor(px), ifloor(pz))) + 4, py + 4))
        var sky = world.info.minY
        if toOpenSky {
            let radius = flightOpenClearanceRadius
            for zz in (ifloor(pz) - radius)...(ifloor(pz) + radius) {
                for xx in (ifloor(px) - radius)...(ifloor(px) + radius) {
                    guard world.isLoadedAt(xx, zz) else { return nil }
                    sky = max(sky, world.heightAt(xx, zz) + 1)
                }
            }
        }
        var checkedThrough = flyerHeadCell(feetAt: py)
        for rise in 0...PREHISTORIC_FLYER_LIFT_SEARCH {
            let height = first + Double(rise)
            guard height <= ceiling else { return nil }
            let top = flyerBodyTop(feetAt: height)
            guard flyerBodyColumnIsClear(in: world, px, pz, from: checkedThrough + 1, through: top) else { return nil }
            checkedThrough = max(checkedThrough, top)
            if ifloor(height) >= sky, flightSpaceIsClear(in: world, px, height, pz) { return (px, height, pz) }
        }
        return nil
    }

    /// Whether a flyer may be placed at `x, y, z`: on a perch it could have landed on, with a
    /// lift from it into the open sky. Body clearance alone admitted the forest floor under a
    /// canopy, where a flyer stands for the rest of its life.
    func flyerCanLaunch(in world: World, x: Int, y: Int, z: Int) -> Bool {
        // The same bound the world has for anything that lives in it; past it a coordinate no
        // longer survives the trip through a Double.
        guard x > -30_000_000, x < 30_000_000, z > -30_000_000, z < 30_000_000,
              y > world.info.minY, y < world.info.minY + world.info.height else { return false }
        return flyerPerchIsClear(in: world, x: x, y: y, z: z)
            && flyerLift(in: world, Double(x) + 0.5, Double(y), Double(z) + 0.5, toOpenSky: true) != nil
    }

    /// An upper bound on the cells one `flyerCanLaunch` reads in `world`, for a caller that
    /// budgets its work (the AI companion's area spawn).
    func flyerLaunchReadBound(in world: World) -> Int {
        let wings = (2 * flightOpenClearanceRadius + 1) * (2 * flightOpenClearanceRadius + 1)
        let bodySide = Int(collisionWidth.rounded(.up)) + 1
        let folded = 2 * flightFoldedClearanceRadius + 1
        return wings * (bodyClearanceHeight + 3) + folded * folded                  // the perch and its ground
            + world.info.height                                                     // the top of its column
            + wings                                                                 // the heightmap under the wings
            + bodySide * bodySide * world.info.height                               // the folded climb
            + (PREHISTORIC_FLYER_LIFT_SEARCH + 1) * wings * bodyClearanceHeight     // the wings at each height tried
    }
}
