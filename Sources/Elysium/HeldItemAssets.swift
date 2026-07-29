// Original held-item art reconstructed from bounded palette data so development,
// packaged, and installed builds use identical pixels without filesystem lookup.
//
// This registry is deliberately item-oriented rather than tool-oriented: food,
// blocks, and other future first-person models enter through the same seam.

import Foundation

struct HeldItemRGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct HeldPickaxePalette: Equatable {
    let dark: HeldItemRGB
    let middle: HeldItemRGB
    let light: HeldItemRGB
}

enum HeldItemPixelSource: Equatable {
    case pickaxe(HeldPickaxePalette)
    case pngBase64(String)
}

struct HeldItemVisualAsset: Equatable {
    let itemName: String
    let provider: String
    let modelTaskID: String
    let sourceSHA256: String
    let width: Int
    let height: Int
    let sourceEntry: String?
    let sourceEntrySHA256: String?
    let pixelSource: HeldItemPixelSource
}

private func heldPickaxeAsset(
    _ material: String,
    sha256: String,
    dark: HeldItemRGB,
    middle: HeldItemRGB,
    light: HeldItemRGB
) -> HeldItemVisualAsset {
    HeldItemVisualAsset(
        itemName: "\(material)_pickaxe",
        provider: "Elysium original procedural voxel art",
        modelTaskID: "elysium-diagonal-pickaxe-v1",
        sourceSHA256: sha256,
        width: 96,
        height: 96,
        sourceEntry: nil,
        sourceEntrySHA256: nil,
        pixelSource: .pickaxe(HeldPickaxePalette(dark: dark, middle: middle, light: light)))
}

private let heldPickaxeVisualAssets: [String: HeldItemVisualAsset] = [
    "wooden_pickaxe": heldPickaxeAsset(
        "wooden", sha256: "afed6517bcebba4e15eb25ad06ac735f6b2ed5c27cde0a37fd37050f600260d1",
        dark: HeldItemRGB(red: 82, green: 48, blue: 22),
        middle: HeldItemRGB(red: 139, green: 88, blue: 38),
        light: HeldItemRGB(red: 193, green: 137, blue: 67)),
    "stone_pickaxe": heldPickaxeAsset(
        "stone", sha256: "70cd6b14736c5edda1ba7ddb923da55db83879415e1a504fa33f288c04df7512",
        dark: HeldItemRGB(red: 66, green: 70, blue: 72),
        middle: HeldItemRGB(red: 112, green: 117, blue: 119),
        light: HeldItemRGB(red: 166, green: 171, blue: 172)),
    "copper_pickaxe": heldPickaxeAsset(
        "copper", sha256: "678aa81424d015268167ed29d5a925966c3369d76c8176c7eba4c3936457e6b5",
        dark: HeldItemRGB(red: 101, green: 46, blue: 27),
        middle: HeldItemRGB(red: 184, green: 89, blue: 52),
        light: HeldItemRGB(red: 237, green: 151, blue: 92)),
    "iron_pickaxe": heldPickaxeAsset(
        "iron", sha256: "baa468b50ae7a8ca62675f0b50fdbca8add32f9c5e1e1d4f0c81eb9e5156d6f4",
        dark: HeldItemRGB(red: 91, green: 101, blue: 108),
        middle: HeldItemRGB(red: 164, green: 177, blue: 183),
        light: HeldItemRGB(red: 232, green: 239, blue: 241)),
    "golden_pickaxe": heldPickaxeAsset(
        "golden", sha256: "51252cbc82cb2b60829e4101b1b8f58e38e5d67d095229584660ab863c7c63b6",
        dark: HeldItemRGB(red: 134, green: 84, blue: 0),
        middle: HeldItemRGB(red: 226, green: 168, blue: 14),
        light: HeldItemRGB(red: 255, green: 231, blue: 91)),
    "diamond_pickaxe": heldPickaxeAsset(
        "diamond", sha256: "c33551b610cf3d4e401c9d92953bc1bc69c2886acc6fa107ad886afcfbfa6aa5",
        dark: HeldItemRGB(red: 8, green: 105, blue: 116),
        middle: HeldItemRGB(red: 35, green: 195, blue: 202),
        light: HeldItemRGB(red: 159, green: 247, blue: 244)),
    "netherite_pickaxe": heldPickaxeAsset(
        "netherite", sha256: "89a7778bdf60d0416b6292570524c3ef16cab07ba030fc6cb4026ebbc3cec295",
        dark: HeldItemRGB(red: 38, green: 32, blue: 41),
        middle: HeldItemRGB(red: 75, green: 65, blue: 78),
        light: HeldItemRGB(red: 119, green: 103, blue: 121)),
]

// One original 16x16 silhouette shared by every material. Lowercase cells are
// head shades; uppercase cells are the invariant wooden handle.
private let heldPickaxeSilhouette = [
    "................",
    "................",
    "......dmmmmll...",
    "....ddmlllmmmd..",
    ".....dmmDDmmd...",
    ".........DMMmd..",
    "........DMM..d..",
    ".......DMM...d..",
    "......DMM....d..",
    ".....DMM......d.",
    "....DMM.........",
    "...DMM..........",
    "..DMM...........",
    ".DMM............",
    ".DM.............",
    "................",
]

private let heldPickaxeHandle: [Character: HeldItemRGB] = [
    "D": HeldItemRGB(red: 66, green: 36, blue: 15),
    "M": HeldItemRGB(red: 130, green: 78, blue: 30),
    "L": HeldItemRGB(red: 191, green: 128, blue: 55),
]

func heldItemVisualAsset(for itemName: String) -> HeldItemVisualAsset? {
    heldPickaxeVisualAssets[itemName] ?? blenderHeldToolVisualAssets[itemName]
}

func heldItemVisualImage(for itemName: String) -> RGBAImage? {
    guard let asset = heldItemVisualAsset(for: itemName) else { return nil }
    switch asset.pixelSource {
    case let .pngBase64(encoded):
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              data.count <= 256 * 1024,
              let image = decodePNG(data),
              image.width == asset.width, image.height == asset.height,
              image.pixels.count == asset.width * asset.height * 4 else { return nil }
        return image
    case let .pickaxe(palette):
        return heldPickaxeVisualImage(asset: asset, palette: palette)
    }
}

private func heldPickaxeVisualImage(
    asset: HeldItemVisualAsset,
    palette: HeldPickaxePalette
) -> RGBAImage? {
    let head: [Character: HeldItemRGB] = [
        "d": palette.dark,
        "m": palette.middle,
        "l": palette.light,
    ]
    let logicalSize = 16
    let pixelScale = 6
    let size = logicalSize * pixelScale
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for (sourceY, row) in heldPickaxeSilhouette.enumerated() {
        for (sourceX, cell) in row.enumerated() {
            guard let color = head[cell] ?? heldPickaxeHandle[cell] else { continue }
            for y in (sourceY * pixelScale)..<((sourceY + 1) * pixelScale) {
                for x in (sourceX * pixelScale)..<((sourceX + 1) * pixelScale) {
                    let offset = (y * size + x) * 4
                    pixels[offset] = color.red
                    pixels[offset + 1] = color.green
                    pixels[offset + 2] = color.blue
                    pixels[offset + 3] = 255
                }
            }
        }
    }
    return RGBAImage(width: size, height: size, pixels: pixels)
}
