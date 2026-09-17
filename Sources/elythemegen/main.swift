import Foundation
import ElysiumCore

private func writeAll(_ data: Data) {
    var remaining = data
    while !remaining.isEmpty {
        let count = remaining.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.write(FileHandle.standardOutput.fileDescriptor, base, raw.count)
        }
        guard count > 0 else { Foundation.exit(1) }
        remaining.removeFirst(count)
    }
}

private func usage() -> Never {
    FileHandle.standardError.write(Data(
        "usage: elythemegen --tile-manifest | --tile-rgba | --item-manifest | --item-rgba\n".utf8))
    Foundation.exit(64)
}

registerAllBlocks()
let names = allTileNames()
let command: [String] = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments[1...]) : []

switch command {
case ["--tile-manifest"]:
    writeAll(Data((names.joined(separator: "\n") + "\n").utf8))
case ["--tile-rgba"]:
    // Binary records: magic, then big-endian UInt16 UTF-8 name length, name, 16x16 RGBA.
    // The target builder uses this stable semantic alpha/luminance mask when materializing
    // its direct per-tile KUBIKOS overrides.
    var out = Data("ELYSIUM_TILE_RGBA_V1\n".utf8)
    let atlas = buildAtlas()
    precondition(atlas.count == names.count)
    for (index, name) in names.enumerated() {
        let nameData = Data(name.utf8)
        precondition(nameData.count <= Int(UInt16.max))
        out.append(UInt8((nameData.count >> 8) & 0xff))
        out.append(UInt8(nameData.count & 0xff))
        out.append(nameData)
        out.append(contentsOf: atlas.pixels[index])
    }
    writeAll(out)
case ["--item-manifest"]:
    registerAllItems()
    // Each row records the runtime provider: item definition name, explicit icon alias, and
    // whether an atlas-backed block preview is an intentional provider. The strict pack audit
    // can accept only a direct/alias image or a themed atlas-backed block preview.
    let rows = itemDefs.map { definition in
        "\(definition.name)\t\(definition.icon)\t\(definition.block == nil ? "item" : "block")"
    }
    writeAll(Data((rows.joined(separator: "\n") + "\n").utf8))
case ["--item-rgba"]:
    registerAllItems()
    guard let candidate = IconSourceCandidate(atlas: buildAtlas()) else {
        Foundation.exit(1)
    }
    _ = publishIconSourceSnapshot(candidate)
    var out = Data("ELYSIUM_ITEM_RGBA_V1\n".utf8)
    for definition in itemDefs {
        let nameData = Data(definition.name.utf8)
        let pixels = itemIconPixels(definition.id)
        precondition(nameData.count <= Int(UInt16.max) && pixels.count == 16 * 16 * 4)
        out.append(UInt8((nameData.count >> 8) & 0xff))
        out.append(UInt8(nameData.count & 0xff))
        out.append(nameData)
        out.append(contentsOf: pixels)
    }
    writeAll(out)
default:
    usage()
}
