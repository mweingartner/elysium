import Foundation

/// The only blocks a prepared template placement may create under its footprint.
///
/// A support column is made from nothing, so it has to be plain natural ground. Copying
/// whatever stands beside the gap would hand that block out for free: an ore, glowstone,
/// packed ice, a block of diamond, or a furnace with no block entity behind it. Every name
/// here is bulk terrain that a template can never capture (`isTemplateCloneableBlock` is
/// false for it), so the fill adds nothing a player could not dig up beside it.
///
/// `TemplateDuplicationRegressionTests` pins what may be listed: a registered, solid, full
/// cube that is terrain, earns no Mining XP, gives off no light and needs no block entity.
let TEMPLATE_SUPPORT_FILL_GROUND: Set<String> = [
    "stone", "granite", "diorite", "andesite", "deepslate", "tuff", "dripstone_block",
    "basalt", "smooth_basalt", "blackstone",
    "grass_block", "dirt", "coarse_dirt", "rooted_dirt", "podzol", "mycelium", "mud",
    "sand", "red_sand", "gravel",
    "netherrack", "crimson_nylium", "warped_nylium", "soul_soil", "end_stone",
]

/// What a support cell at `x, y, z` is made of: the first neighbouring block of plain ground,
/// with its metadata dropped, or dirt when no neighbour is ground. Neighbours are read in a
/// fixed order (west, east, north, south, below, above), so a column filled bottom-up takes
/// the terrain beside it before the material it stands on.
func templateSupportFillCell(in world: World, _ x: Int, _ y: Int, _ z: Int) -> Int {
    let deltas = [(-1, 0, 0), (1, 0, 0), (0, 0, -1), (0, 0, 1), (0, -1, 0), (0, 1, 0)]
    for d in deltas {
        let id = world.getBlock(x + d.0, y + d.1, z + d.2) >> 4
        if id > 0, id < blockDefs.count, TEMPLATE_SUPPORT_FILL_GROUND.contains(blockDefs[id].name) {
            return Int(cell(UInt16(id)))
        }
    }
    return Int(cell(B.dirt))
}
