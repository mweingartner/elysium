// Direction constants — table order is load-bearing (pinned by goldens).

import Foundation

public enum Dir {
    public static let down = 0
    public static let up = 1
    public static let north = 2
    public static let south = 3
    public static let west = 4
    public static let east = 5
}

public let DIR_X = [0, 0, 0, 0, -1, 1]
public let DIR_Y = [-1, 1, 0, 0, 0, 0]
public let DIR_Z = [0, 0, -1, 1, 0, 0]
public let DIR_OPPOSITE = [1, 0, 3, 2, 5, 4]

/// The step toward direction `dir`. Block metadata holds a facing in three or four bits, so a
/// cell that was pasted, imported or sent by a LAN guest can name a direction outside 0...5.
/// That is no step at all here, never a read past the end of the tables.
public func dirStep(_ dir: Int) -> (x: Int, y: Int, z: Int) {
    dir >= 0 && dir < 6 ? (DIR_X[dir], DIR_Y[dir], DIR_Z[dir]) : (0, 0, 0)
}
public let HORIZONTALS = [Dir.north, Dir.south, Dir.west, Dir.east]
public let DIR_NAMES = ["down", "up", "north", "south", "west", "east"]

/// yaw (degrees) → horizontal dir the entity FACES: 0=south,90=west,180=north,270=east
public func yawToDir(_ yawDeg: Double) -> Int {
    let a = (yawDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    if a >= 315 || a < 45 { return Dir.south }
    if a < 135 { return Dir.west }
    if a < 225 { return Dir.north }
    return Dir.east
}

public let DIR_YAW: [Int: Double] = [Dir.south: 0, Dir.west: 90, Dir.north: 180, Dir.east: 270]
