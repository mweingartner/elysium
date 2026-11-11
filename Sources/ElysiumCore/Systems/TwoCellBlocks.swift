import Foundation

/// A door, a bed and a tall plant each stand on two cells but are one item.
///
/// One half is the primary: the door's lower half, the bed's foot, the plant's base. It carries
/// the item. The other is the secondary half and is worth nothing by itself, so a break that
/// treats the two cells separately (an explosion, a pasted half without its partner) cannot
/// pay out twice. Every rule about the pair asks here which half a cell is.
enum TwoCellHalf: Equatable {
    case primary
    case secondary
}

/// Which half of a two-cell block `cell` is, or nil for a block that stands on one cell.
func twoCellHalf(of cell: Int) -> TwoCellHalf? {
    let id = cell >> 4
    let meta = cell & 15
    guard id > 0, id < blockDefs.count else { return nil }
    switch blockDefs[id].shape {
    case .door:
        return meta & 8 != 0 ? .secondary : .primary
    case .bed:
        return meta & 4 != 0 ? .secondary : .primary
    case .tallCross, .smallDripleafShape:
        return meta & 1 != 0 ? .secondary : .primary
    default:
        return nil
    }
}

/// Where the other half of the two-cell block `cell` stands when `cell` is at `x, y, z`.
func twoCellPartnerPosition(of cell: Int, _ x: Int, _ y: Int, _ z: Int) -> (x: Int, y: Int, z: Int)? {
    guard let half = twoCellHalf(of: cell) else { return nil }
    let towardSecondary = half == .primary ? 1 : -1
    if blockDefs[cell >> 4].shape == .bed {
        // A bed's head lies one cell from its foot, in the direction the bed faces.
        let facing = cell & 3
        return (x + towardSecondary * [0, 0, -1, 1][facing], y, z + towardSecondary * [-1, 1, 0, 0][facing])
    }
    return (x, y + towardSecondary, z)
}

/// A template cell as it is after the template is turned `rotationSteps` quarter turns. A
/// template keeps the facing of its blocks when it is turned, with one exception: a bed's two
/// halves find each other through their facing, so a bed that is turned without it is two loose
/// halves. Each quarter turn takes north to east, east to south, south to west, west to north.
func rotatedTemplateCell(_ cell: UInt16, rotationSteps: Int) -> UInt16 {
    let id = Int(cell >> 4)
    guard id > 0, id < blockDefs.count, blockDefs[id].shape == .bed else { return cell }
    var facing = Int(cell & 3)
    for _ in 0..<(((rotationSteps % 4) + 4) % 4) { facing = [3, 2, 0, 1][facing] }
    return (cell & ~3) | UInt16(facing)
}

/// Whether the bed cell `cell` at `x, y, z` works as a bed. The foot is the bed: it carries the
/// item, so a foot works by itself. A head works when a foot of its own block lies beside it:
/// the one its facing names, or any foot of that block next to it, because worlds hold beds
/// whose two halves disagree about the way the bed faces (world generation wrote an igloo's bed
/// that way). A head with no foot beside it is a leftover and no bed.
func bedCellWorks(in world: World, _ cell: Int, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    guard twoCellHalf(of: cell) == .secondary else { return true }
    if twoCellPartnerCell(in: world, of: cell, x, y, z) != nil { return true }
    for side in 0..<4 {
        let other = world.getBlock(x + FACE_DX[side], y, z + FACE_DZ[side])
        if other >> 4 == cell >> 4, twoCellHalf(of: other) == .primary { return true }
    }
    return false
}

/// The other half of the two-cell block at `x, y, z`, as it stands in `world`: the same block,
/// the opposite half and, for a bed, the same facing. Nil when the half stands alone.
func twoCellPartnerCell(in world: World, of cell: Int, _ x: Int, _ y: Int, _ z: Int) -> Int? {
    twoCellPartnerCell(of: cell, x, y, z) { world.getBlock($0, $1, $2) }
}

/// The same question wherever the cells are kept: a world, or the blocks of a template.
/// `cellAt` answers 0 where nothing stands.
func twoCellPartnerCell(of cell: Int, _ x: Int, _ y: Int, _ z: Int,
                        cellAt: (Int, Int, Int) -> Int) -> Int? {
    guard let half = twoCellHalf(of: cell),
          let position = twoCellPartnerPosition(of: cell, x, y, z) else { return nil }
    let partner = cellAt(position.x, position.y, position.z)
    guard partner >> 4 == cell >> 4, let partnerHalf = twoCellHalf(of: partner), partnerHalf != half else {
        return nil
    }
    if blockDefs[cell >> 4].shape == .bed, partner & 3 != cell & 3 { return nil }
    return partner
}
