import Foundation

public enum RPGAssetKind: String, Codable {
    case pathIcon
    case branchIcon
    case skillIcon
    case spellIcon
    case actionIcon
}

public struct RPGAssetManifestEntry: Codable, Equatable {
    public var id: String
    public var kind: RPGAssetKind
    public var ownerID: String
    public var displayName: String
    public var proceduralSeed: UInt32
    public var palette: [Int]

    public init(id: String, kind: RPGAssetKind, ownerID: String, displayName: String,
                proceduralSeed: UInt32, palette: [Int]) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.displayName = displayName
        self.proceduralSeed = proceduralSeed
        self.palette = palette
    }
}

private let RPG_PATH_PALETTES: [String: [Int]] = [
    "warden": [0xd7dde6, 0x6f7f95, 0x2d3542],
    "ranger": [0xa8d67a, 0x4f8f45, 0x21351e],
    "delver": [0xe0bf75, 0x92652f, 0x2f241b],
    "arcanist": [0x9ad7ff, 0x6f63d9, 0x2c245f],
    "mender": [0xf2d7b8, 0x68b870, 0x24442a],
    "tinker": [0xf0b080, 0xb55f37, 0x2f3e46],
]

private let RPG_SPELL_PALETTES: [RPGSpellCategory: [Int]] = [
    .damage: [0xffb35c, 0xd84a32, 0x4a1b16],
    .defense: [0xb8ddff, 0x4d85bf, 0x1f3756],
    .movement: [0xc7f0ff, 0x42b4cb, 0x17434b],
    .utility: [0xf2e17a, 0xaa8f2e, 0x3c3217],
    .illusion: [0xd0b7ff, 0x7c64d9, 0x2c245f],
    .creation: [0xb8e6b0, 0x4d9a52, 0x1d3b24],
    .healing: [0xffc8d4, 0xd96583, 0x5f2032],
    .control: [0xc0d0d8, 0x617887, 0x25333a],
]

public let RPG_ACTION_ASSET_IDS: [String] = [
    "character_sheet",
    "prepare_spell",
    "cast_spell",
    "learn_skill",
    "spend_attribute",
    "toggle_rpg_classes",
]

public func rpgAssetManifest() -> [RPGAssetManifestEntry] {
    var entries: [RPGAssetManifestEntry] = []
    for path in RPG_PATH_DEFINITIONS {
        entries.append(RPGAssetManifestEntry(
            id: "rpg.path.\(path.id)",
            kind: .pathIcon,
            ownerID: path.id,
            displayName: path.displayName,
            proceduralSeed: stableRPGSeed(path.id),
            palette: RPG_PATH_PALETTES[path.id] ?? [0xcccccc, 0x999999, 0x666666]
        ))
    }
    for branch in RPG_BRANCH_DEFINITIONS {
        let pathPalette = RPG_PATH_PALETTES[branch.pathID] ?? [0xcccccc, 0x999999, 0x666666]
        entries.append(RPGAssetManifestEntry(
            id: "rpg.branch.\(branch.id)",
            kind: .branchIcon,
            ownerID: branch.id,
            displayName: branch.displayName,
            proceduralSeed: stableRPGSeed(branch.id),
            palette: rotatedPalette(pathPalette, by: stableRPGSeed(branch.id))
        ))
    }
    for skill in RPG_SKILL_DEFINITIONS {
        let pathPalette = RPG_PATH_PALETTES[skill.pathID] ?? [0xcccccc, 0x999999, 0x666666]
        entries.append(RPGAssetManifestEntry(
            id: "rpg.skill.\(skill.id)",
            kind: .skillIcon,
            ownerID: skill.id,
            displayName: skill.displayName,
            proceduralSeed: stableRPGSeed(skill.id),
            palette: rotatedPalette(pathPalette, by: stableRPGSeed(skill.branchID))
        ))
    }
    for spell in RPG_SPELL_DEFINITIONS {
        let category = spell.categories.first ?? .utility
        entries.append(RPGAssetManifestEntry(
            id: "rpg.spell.\(spell.id)",
            kind: .spellIcon,
            ownerID: spell.id,
            displayName: spell.displayName,
            proceduralSeed: stableRPGSeed(spell.id),
            palette: RPG_SPELL_PALETTES[category] ?? [0xcccccc, 0x999999, 0x666666]
        ))
    }
    for actionID in RPG_ACTION_ASSET_IDS {
        entries.append(RPGAssetManifestEntry(
            id: "rpg.action.\(actionID)",
            kind: .actionIcon,
            ownerID: actionID,
            displayName: prettify(actionID),
            proceduralSeed: stableRPGSeed(actionID),
            palette: [0xf5f5f5, 0x8c9aa8, 0x26313d]
        ))
    }
    return entries
}

public func rpgAssetEntry(id: String) -> RPGAssetManifestEntry? {
    rpgAssetManifest().first { $0.id == id }
}

public func rpgAssetIDForPath(_ pathID: String) -> String { "rpg.path.\(pathID)" }
public func rpgAssetIDForBranch(_ branchID: String) -> String { "rpg.branch.\(branchID)" }
public func rpgAssetIDForSkill(_ skillID: String) -> String { "rpg.skill.\(skillID)" }
public func rpgAssetIDForSpell(_ spellID: String) -> String { "rpg.spell.\(spellID)" }
public func rpgAssetIDForAction(_ actionID: String) -> String { "rpg.action.\(actionID)" }

public func rpgIconPixels(assetID: String) -> [UInt8]? {
    guard let entry = rpgAssetEntry(id: assetID) else { return nil }
    return rpgIconPixels(entry)
}

public func rpgIconPixels(_ entry: RPGAssetManifestEntry) -> [UInt8] {
    var img = [UInt8](repeating: 0, count: 16 * 16 * 4)
    let palette = entry.palette.isEmpty ? [0xcccccc, 0x999999, 0x666666] : entry.palette
    let primary = palette[0]
    let secondary = palette[min(1, palette.count - 1)]
    let dark = palette[min(2, palette.count - 1)]
    drawRPGIconBase(&img, primary: primary, secondary: secondary, dark: dark)
    switch entry.kind {
    case .pathIcon:
        drawRPGDiamond(&img, primary: primary, dark: dark)
    case .branchIcon:
        drawRPGChevron(&img, primary: primary, dark: dark, seed: entry.proceduralSeed)
    case .skillIcon:
        drawRPGSkillGlyph(&img, primary: primary, dark: dark, seed: entry.proceduralSeed)
    case .spellIcon:
        drawRPGSpellGlyph(&img, primary: primary, secondary: secondary, dark: dark, seed: entry.proceduralSeed)
    case .actionIcon:
        drawRPGActionGlyph(&img, primary: primary, dark: dark, seed: entry.proceduralSeed)
    }
    return img
}

private func stableRPGSeed(_ text: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in text.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16_777_619
    }
    return hash
}

private func rotatedPalette(_ palette: [Int], by seed: UInt32) -> [Int] {
    guard !palette.isEmpty else { return palette }
    let shift = Int(seed % UInt32(palette.count))
    return Array(palette[shift...]) + Array(palette[..<shift])
}

@inline(__always) private func putRPG(_ img: inout [UInt8], _ x: Int, _ y: Int, _ rgb: Int, alpha: UInt8 = 255) {
    if x < 0 || x > 15 || y < 0 || y > 15 { return }
    let i = (y * 16 + x) * 4
    img[i] = UInt8((rgb >> 16) & 255)
    img[i + 1] = UInt8((rgb >> 8) & 255)
    img[i + 2] = UInt8(rgb & 255)
    img[i + 3] = alpha
}

private func drawRPGIconBase(_ img: inout [UInt8], primary: Int, secondary: Int, dark: Int) {
    for y in 2...13 {
        for x in 2...13 {
            if x == 2 || x == 13 || y == 2 || y == 13 {
                putRPG(&img, x, y, dark)
            } else if (x + y) % 3 == 0 {
                putRPG(&img, x, y, secondary)
            }
        }
    }
    for y in 4...11 {
        for x in 4...11 where (x + y) % 2 == 0 {
            putRPG(&img, x, y, primary)
        }
    }
}

private func drawRPGDiamond(_ img: inout [UInt8], primary: Int, dark: Int) {
    for y in 4...11 {
        let radius = y <= 7 ? y - 4 : 11 - y
        for x in (8 - radius)...(8 + radius) { putRPG(&img, x, y, primary) }
    }
    putRPG(&img, 8, 3, dark)
    putRPG(&img, 8, 12, dark)
    putRPG(&img, 3, 8, dark)
    putRPG(&img, 13, 8, dark)
}

private func drawRPGChevron(_ img: inout [UInt8], primary: Int, dark: Int, seed: UInt32) {
    let offset = Int(seed % 3)
    for y in 4...11 {
        let x0 = 4 + abs(8 - y) / 2 + offset / 2
        putRPG(&img, x0, y, dark)
        putRPG(&img, x0 + 1, y, primary)
        putRPG(&img, 15 - x0, y, dark)
        putRPG(&img, 14 - x0, y, primary)
    }
}

private func drawRPGSkillGlyph(_ img: inout [UInt8], primary: Int, dark: Int, seed: UInt32) {
    let vertical = (seed & 1) == 0
    for i in 4...11 {
        if vertical {
            putRPG(&img, 8, i, dark)
            putRPG(&img, 7, i, primary)
        } else {
            putRPG(&img, i, 8, dark)
            putRPG(&img, i, 7, primary)
        }
    }
    let pointCount = 3 + Int(seed % 3)
    for n in 0..<pointCount {
        let x = 4 + ((Int(seed >> (n * 3)) + n * 2) % 8)
        let y = 4 + ((Int(seed >> (n * 2)) + n * 3) % 8)
        putRPG(&img, x, y, dark)
        putRPG(&img, x + 1, y, primary)
    }
}

private func drawRPGSpellGlyph(_ img: inout [UInt8], primary: Int, secondary: Int, dark: Int, seed: UInt32) {
    let cx = 8
    let cy = 8
    for y in 4...12 {
        for x in 4...12 {
            let dx = x - cx
            let dy = y - cy
            let dist = dx * dx + dy * dy
            if dist == 9 || dist == 10 || dist == 13 {
                putRPG(&img, x, y, dark)
            } else if dist < 9 && ((x * 31 + y * 17 + Int(seed)) & 3) == 0 {
                putRPG(&img, x, y, secondary)
            }
        }
    }
    putRPG(&img, cx, cy, primary)
    putRPG(&img, cx + 1, cy, primary)
    putRPG(&img, cx, cy + 1, primary)
}

private func drawRPGActionGlyph(_ img: inout [UInt8], primary: Int, dark: Int, seed: UInt32) {
    let arrowRight = (seed & 1) == 0
    for x in 4...11 {
        putRPG(&img, x, 8, primary)
        putRPG(&img, x, 9, dark)
    }
    if arrowRight {
        putRPG(&img, 12, 8, primary)
        putRPG(&img, 11, 7, primary)
        putRPG(&img, 11, 9, dark)
    } else {
        putRPG(&img, 3, 8, primary)
        putRPG(&img, 4, 7, primary)
        putRPG(&img, 4, 9, dark)
    }
}
