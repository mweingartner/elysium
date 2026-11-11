import Foundation
import ElysiumTextInput

// An object template as placing its blocks by hand would leave it.
//
// Two callers need this. A LAN host never takes a guest's word for a block entity
// (`lanHostTemplate`), and a survival paste may put into the world only what the items the
// player pays for would put there (`TemplateMaterials.swift`).

/// `template` with every block entity rebuilt as placing its block by hand would create it
/// (`placementBlockEntity`): containers, jukeboxes and furnaces empty and idle, and a block
/// that gets no entity when placed (a spawner, an end gateway) without one. Of the template's
/// own block-entity data only what a player could have typed or planted survives, and only
/// after the game's own checks: a sign's text and the plant in a flower pot. A cell that shows
/// what its block held (a lit furnace, a book on a shelf) is set to its empty form.
func templateAsPlacedByHand(_ template: ObjectTemplate) -> ObjectTemplate {
    var stored: [TemplatePos: BlockEntityData] = [:]
    for blockEntity in template.blockEntities { stored[templatePos(blockEntity)] = blockEntity }
    var rebuilt: [BlockEntityData] = []
    var out = template
    out.blocks = template.blocks.map { block in
        let cell = templateCellWithoutContainedItemState(block.cell)
        let position = templatePos(block)
        if let blockEntity = handPlacedBlockEntity(blockId: Int(cell >> 4), at: position,
                                                   stored: stored[position]) {
            rebuilt.append(blockEntity)
        }
        return TemplateBlock(dx: block.dx, dy: block.dy, dz: block.dz, cell: cell)
    }
    out.blockEntities = rebuilt
    return out
}

/// The block entity one block of a template gets when it is placed as if by hand. `stored` is
/// what the template holds for that position, if anything; it is read for a sign's lines and a
/// pot's plant only.
private func handPlacedBlockEntity(blockId: Int, at position: TemplatePos,
                                   stored: BlockEntityData?) -> BlockEntityData? {
    if blockId == Int(B.flower_pot) {
        // A potted plant must be a plant block as well as a pottable item: the pot hands its plant
        // back as an item, and "mushroom_stew" also contains a pottable word.
        guard let plant = stored?.plant, isPottablePlantName(plant), iidOpt(plant) != nil,
              bidOpt(plant) != nil else { return nil }
        let pot = BlockEntityData(type: "lectern", x: position.x, y: position.y, z: position.z)
        pot.plant = plant
        return pot
    }
    guard let fresh = placementBlockEntity(blockId, position.x, position.y, position.z) else { return nil }
    if fresh.type == "sign", stored?.type == "sign" {
        // The sign editor's own repair: four lines, valid characters only. The width rule is the
        // widest the editor could ever accept (one unit a character), since a host has no font.
        fresh.lines = elysiumRepairSignLines(stored?.lines, makeWidthStep: {
            var width = 0
            return { _ in width += 1; return width }
        }).lines.array
    }
    return fresh
}

/// The template a survival paste places: as placed by hand, with nothing grown, filled or
/// charged (`templateSurvivalCell`), and without the parts no item places by themselves. What
/// it costs is `templateMaterialBill` of the result. The result can be empty.
func templateForSurvivalPaste(_ template: ObjectTemplate) -> ObjectTemplate {
    var out = templateAsPlacedByHand(template)
    var cells: [TemplatePos: Int] = [:]
    for block in out.blocks { cells[templatePos(block)] = Int(block.cell) }
    out.blocks = out.blocks.compactMap { block in
        guard templatePartStandsWithItsOwner(block, among: cells) else { return nil }
        return TemplateBlock(dx: block.dx, dy: block.dy, dz: block.dz, cell: templateSurvivalCell(block.cell))
    }
    let kept = Set(out.blocks.map(templatePos))
    out.blockEntities = out.blockEntities.filter { kept.contains(templatePos($0)) }
    return out
}

/// Whether placing items by hand can put `block` where the template has it. Two kinds of cell
/// only ever exist as part of another: the second half of a door, a bed or a tall plant, which
/// comes with its first half, and the head of an extended piston, which a piston makes. A
/// second half whose first half is not in the template beside it is left out, and so is every
/// piston head: a hand-placed piston is retracted. Left in, such a part would be free, and it
/// would still be half a bed to sleep in or half a door to open.
private func templatePartStandsWithItsOwner(_ block: TemplateBlock, among cells: [TemplatePos: Int]) -> Bool {
    let cellValue = Int(block.cell)
    let id = cellValue >> 4
    guard id > 0, id < blockDefs.count else { return true }
    if blockDefs[id].shape == .pistonHead { return false }
    guard twoCellHalf(of: cellValue) == .secondary else { return true }
    return twoCellPartnerCell(of: cellValue, block.dx, block.dy, block.dz) { x, y, z in
        cells[TemplatePos(x: x, y: y, z: z)] ?? 0
    } != nil
}
