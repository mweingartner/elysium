import Foundation

/// What undo has to put back at one cell: the block standing there now, and its block entity.
func templateUndoCell(in world: World, at pos: TemplatePos) -> TemplatePlacementUndoCell {
    let cellValue = world.getBlock(pos.x, pos.y, pos.z)
    let id = cellValue >> 4
    let blockEntity = id > 0 && id < blockDefs.count
        ? world.getBlockEntity(pos.x, pos.y, pos.z).flatMap(sanitizedTemplateBlockEntity)
        : nil
    return TemplatePlacementUndoCell(x: pos.x, y: pos.y, z: pos.z, cell: cellValue, blockEntity: blockEntity)
}

/// The undo record of one template placement, built while the placement runs.
///
/// Undo must give back exactly what the placement itself removed, once. So the record holds
/// only the cells the job has taken, each as it stood immediately before the job's first
/// write to it. It is deliberately not a picture of the footprint at admission. A tick-sliced
/// job is admitted many ticks before it reaches most of its cells, and on a LAN host the
/// world keeps changing in between: a guest can empty a chest or mine a block inside the
/// footprint before the job gets there, and a chunk can unload so that the job never gets
/// there at all. Restoring an admission-time picture would hand those contents back a
/// second time.
struct TemplateUndoLedger {
    let templateName: String
    let dimension: Int
    /// Every cell the placement may change, ascending, with no repeats.
    let positions: [TemplatePos]
    private var taken: [TemplatePlacementUndoCell?]

    /// `positions` must be ascending with no repeats, as
    /// `objectTemplatePlacementPositions` returns them.
    init(templateName: String, dimension: Int, positions: [TemplatePos]) {
        self.templateName = templateName
        self.dimension = dimension
        self.positions = positions
        taken = Array(repeating: nil, count: positions.count)
    }

    /// The cells recorded so far, ascending.
    var snapshot: TemplatePlacementUndoSnapshot {
        TemplatePlacementUndoSnapshot(templateName: templateName, dimension: dimension,
                                      cells: taken.compactMap { $0 })
    }

    /// Records the cell at `pos` as it stands now, unless it is already recorded, and returns
    /// whether the job may write it. The answer is no for a cell whose chunk is not loaded
    /// (nothing can be read or written there) and for a position the placement never planned;
    /// a cell the job may not write never enters the record.
    mutating func record(_ pos: TemplatePos, in world: World) -> Bool {
        guard world.isLoadedAt(pos.x, pos.z), let index = index(of: pos) else { return false }
        if taken[index] == nil { taken[index] = templateUndoCell(in: world, at: pos) }
        return true
    }

    /// Whether the job has taken the cell at `pos`.
    func holds(_ pos: TemplatePos) -> Bool {
        index(of: pos).map { taken[$0] != nil } ?? false
    }

    private func index(of pos: TemplatePos) -> Int? {
        var low = 0
        var high = positions.count
        while low < high {
            let mid = (low + high) / 2
            if positions[mid] < pos { low = mid + 1 } else { high = mid }
        }
        return low < positions.count && positions[low] == pos ? low : nil
    }
}
