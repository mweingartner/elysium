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

/// The other half of the two-cell block at `x, y, z`, as it stands in `world`: the same block,
/// the opposite half and, for a bed, the same facing. Nil when the half stands alone.
func twoCellPartnerCell(in world: World, of cell: Int, _ x: Int, _ y: Int, _ z: Int) -> Int? {
    guard let half = twoCellHalf(of: cell),
          let position = twoCellPartnerPosition(of: cell, x, y, z) else { return nil }
    let partner = world.getBlock(position.x, position.y, position.z)
    guard partner >> 4 == cell >> 4, let partnerHalf = twoCellHalf(of: partner), partnerHalf != half else {
        return nil
    }
    if blockDefs[cell >> 4].shape == .bed, partner & 3 != cell & 3 { return nil }
    return partner
}
