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
// Upright pickaxe (align-held-tools-upright work): a solid horizontal pick head over a
// vertical wooden handle the fist grips directly, matching the stood-up melee/mining tools.
private let heldPickaxeSilhouette = [
    "................",
    "................",
    "................",
    "...ld......dl...",
    "..lmmd....dmml..",
    "..mmmmddddmmmm..",
    "...dmmmmmmmd....",
    "......dMMd......",
    "......DMMD......",
    "......DMM.......",
    "......DMM.......",
    "......DMM.......",
    "......DMM.......",
    "......DMM.......",
    "......DML.......",
    "................",
]

private let heldPickaxeHandle: [Character: HeldItemRGB] = [
    "D": HeldItemRGB(red: 66, green: 36, blue: 15),
    "M": HeldItemRGB(red: 130, green: 78, blue: 30),
    "L": HeldItemRGB(red: 191, green: 128, blue: 55),
]

// Off-hand-only sprites, keyed distinctly from the item name so they never change how the
// same item renders in the main hand (a torch selected in the right hand stays a block icon;
// "held_torch" is the upright-in-fist art drawn only by the left-hand overlay).
private let heldExtraVisualAssets: [String: HeldItemVisualAsset] = [
    "held_torch": HeldItemVisualAsset(
        itemName: "held_torch",
        provider: "Elysium original held-torch art",
        modelTaskID: "elysium-held-torch-v1",
        sourceSHA256: "172ed96818032d24454d5187926c241538498647c9e65d7db48887c0b264f3e1",
        width: 128, height: 128,
        sourceEntry: nil, sourceEntrySHA256: nil,
        pixelSource: .pngBase64(
            """
            iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAACnUlEQVR4nO3cMUorURhA4WswnWUKCZLpQhBxARbWYmFt7Spc
            gktwCa7ABVhbiYRgp0iwSGmXIiJjkkkyMYMJRP5zPniQyeOBhON/75s7mpIkSZIklp0E1r1sjMavD+8GyM+itu0vQNtlAHAG
            ALebwOt/dro3vU5pRNwHOAHgavTdf5X3I0MGoClsAMX1v+yaAhdAcczXz04mf8r+ngAXgGYZABwqgPF4X7beZz/vk5YBVABa
            hL0T+K1+cD15PUwXiahGHf/FnX/xmrYMYAJQOQOAMwA4RACr/vs3j7QPQAQwb34DuOr9yJABaMoA4MIHsO463g2+DwgfwF/P
            +zPI8wGYAKpu9OqwjSAugLJzgLJritABbGr97gbeB4QOYN31PAPsAxABaDlUAFU3eHXQRjBsAJtet7tB9wFhA1A14QNYdyOX
            Bd8IYp8JHL7fbPtL+BfCTwD9LuTPwxc3bJsY4a8Pn5PX0X6HgBMALvweoPjdq0VOALhQ61lRp90pvXHT3G+u/Lf9j37p+72X
            XrjPywkAZwBwBgBnAHAGAGcAcAYAZwBwBgBnAHAGABfu3vYy50ezD3UetxafE2i3GjPXV7eP4T8fJwBc+OcBlnl6W3xOoOy9
            6JwAcNgJUGUPcP88SNE5AeAMAM4A4AwAzgDgDADOAOAMAM4A4LB3Aj0LyDkB4LATwLOAnBMAzgDgDADOAOAMAM4A4AwAzgDg
            DAAOeyfQs4CcEwAOOwE8C8g5AeAMAM4A4AwAzgDgDADOAOAMAM4A4LB3Aj0LyDkB4LATwLOAnBMAzgDgDADOAOAMAM4A4AwA
            zgDgDAAOeyfQs4CcEwAOOwE8C8g5AeAMAM4A4AwAzgDgDADOAOAMAM4A4AwAzgDgDADOACRJkoC+AOHsfz46DW86AAAAAElF
            TkSuQmCC
            """)),
    "held_shield": HeldItemVisualAsset(
        itemName: "held_shield",
        provider: "Elysium original angled-shield art",
        modelTaskID: "elysium-held-shield-v1",
        sourceSHA256: "460af890109acb58bd18c2b55efcbb72092a3d7d3ecb8f77e1d73d8c135d2782",
        width: 150, height: 150,
        sourceEntry: nil, sourceEntrySHA256: nil,
        pixelSource: .pngBase64(
            """
            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
            eUWIQIvV7QRCIOeO3NwgXV9OGXPlCqG6XonU6TpikGhCQKWRZQn8MBYZ8oLko8qhlsh0B5soyzvkyKGb5rkX4lXt6taw1tIV
            VlaPWVtq0n2ZI/QjpIvbouBkiaA0Pkw5x7WrX4UtEuxev4qti4/KGy4WyNdYZk4Kw5IER7okTmPvT7JJK89d1gODznIFMGUJ
            Lxrh8uM/JI+9/s3fQ2+wIS2eja2LUsNiVkoyixz5lOIoCaz81Y6x1s5iaW2v0HeRCEelBi+EyecchZCKu0wiawszewu6PBB9
            lGj0JC7iHm5ZoixtlWaUXoqpdVaolRL1aE6SFkXjbGWB2/DyBxAPtkRr1b3wJA4O9sSVdgYXEMQ9KcJSjryYni5Hzooq/eJL
            O29ghbF2xPK0X6saOEXjBlSV8mQqB3WpgV/rdkKcO78prRVmb91OJG4rSQpxhSQD4yySqNdxLo/uj8VQKCW6LMZZ/HNRdnke
            lmmCycGuWD4S2rJttJi7oL67Aa19hFGM+WQXRea22NwLF16tbo9wbYmlPW/cvEEcv6LEmNaEK4tINjab6d5Ery5lCCV1Kioe
            WAgleWTMvnK6dlnqQSuSUwzIrX1un6i4wsqIlIYk9ViyyDMc3noDy9kudq5t4/Y7L8MLOy4THGwdjZ/duvbWXYty7wSfd9UD
            97WLsf7lpz716GgwGjEO4rg74yuZBSwSFMs9cVssBGxtDiQ4XyzToyEJ9vqkcdz1sDdJ6hjNRV3zNMeSRc6jXQ6lKCNouWTJ
            Ld3bMoHyu6jSOV7/3/8NpfHQ63VlleRymaIjqlFmhIHIZbxTMkJW9nPVEmulYHMtcmRpINdQ9QKQMpu6QqWhK6NVqBWfMmCq
            EEa+ECzPuWab4kD3HMskqzXsbgMN3WuSFggCF+jHUpG30hrioAV/3oUtZqWcDPKwmM/g+aHMEbL57PuBxFinlRoknnPnVFYa
            6+UKjRkfN3Vdj46Be5UvAI7Vl9w044Jv1qM48iXxVbfj5DL12iHRx/OfWugn0hdj0Y2PZcZVvV6bQ6pknmtQu8fT5VEVwZ5i
            UVr4nSE6/XNugUieSDvntAEKeVpTtMRaKSgr8VXTbuEbLrs/87ksmWVjVzI/5WpRlL/QrdVCBiEP9yuwJMF6V14UUn1nMM8H
            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
            QmCC
            """)),
]

func heldItemVisualAsset(for itemName: String) -> HeldItemVisualAsset? {
    heldPickaxeVisualAssets[itemName]
        ?? heldExtraVisualAssets[itemName]
        ?? blenderHeldToolVisualAssets[itemName]
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
