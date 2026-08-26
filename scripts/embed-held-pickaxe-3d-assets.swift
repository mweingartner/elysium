#!/usr/bin/env swift

import Foundation
import CryptoKit
import Darwin

enum EmbedFailure: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

struct PickaxeManifest: Decodable {
    let generator: String
    let camera: String
    let geometry_source: String
    let geometry_source_sha256: String
    let geometry_provider: String
    let geometry_license: String
    let geometry_url: String
    let assets: [Asset]

    struct Asset: Decodable {
        let item: String
        let output: String
        let output_sha256: String
        let width: Int
        let height: Int
    }
}

func wrappedBase64(_ data: Data) -> String {
    let encoded = data.base64EncodedString()
    return stride(from: 0, to: encoded.count, by: 96).map { offset in
        let start = encoded.index(encoded.startIndex, offsetBy: offset)
        let end = encoded.index(start, offsetBy: min(96, encoded.count - offset))
        return "            " + encoded[start..<end]
    }.joined(separator: "\n")
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw EmbedFailure.invalid(message) }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func pngDimensions(_ data: Data) -> (Int, Int)? {
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard data.count >= 24, Array(data.prefix(8)) == signature,
          String(data: data[12..<16], encoding: .ascii) == "IHDR" else { return nil }
    func uint32(at offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    return (uint32(at: 16), uint32(at: 20))
}

do {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    try require(FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path),
                "run this script from the repository root")
    let directory = root.appending(path: "Assets/Elysium/HeldPickaxe3D", directoryHint: .isDirectory)
    let manifest = try JSONDecoder().decode(
        PickaxeManifest.self,
        from: Data(contentsOf: directory.appending(path: "manifest.json")))

    let expectedItems = Set([
        "wooden_pickaxe", "stone_pickaxe", "copper_pickaxe", "iron_pickaxe",
        "golden_pickaxe", "diamond_pickaxe", "netherite_pickaxe",
    ])
    let expectedGeometrySource = "Assets/Meshy/IronPickaxe/tfwa_pickaxe_cc0_source.glb"
    let expectedGeometrySHA256 = "3d3c188a832b80518f405f7ab95c7982d88cd482ac81fe9be4eb535e39269f1d"
    let expectedGenerator = "Blender 5.1.2 EEVEE model render"
    let expectedCamera = "orthographic three-quarter view; immutable runtime pixels"
    let expectedOutputSHA256: [String: String] = [
        "wooden_pickaxe": "1458f13918b2231e0db581612dced08a8f3ca10dff27f556049f076e29a506d6",
        "stone_pickaxe": "e39e893b62700a92619b0e31927d4c1bffb3db02fd9403a3b88399b79629a924",
        "copper_pickaxe": "eae95d2d26022b61e0b0be7eb52e13ee6f6a6a45182549f8b192705659ea3e2f",
        "iron_pickaxe": "9a53e7eea3b763006c8c3e4716e3212798d55c8f5531db230e25e88f279a77f6",
        "golden_pickaxe": "422edfdfdbe642b29a4cb4a751254d38930e0898a7fd49e92d058919b5781fdc",
        "diamond_pickaxe": "2d00d631fa617ae4eb4859f03e29c907ebaa1e7c1f95313de25951e03399f127",
        "netherite_pickaxe": "8318caefbf1887e1c4b48463f0dff508c8b069f4263c453537f4e7b8b20e6ab4",
    ]
    try require(manifest.generator == expectedGenerator, "unexpected generator toolchain")
    try require(manifest.camera == expectedCamera, "unexpected camera contract")
    try require(manifest.geometry_source == expectedGeometrySource, "unexpected geometry source")
    try require(manifest.geometry_source_sha256 == expectedGeometrySHA256,
                "unexpected geometry source hash")
    try require(manifest.geometry_provider == "tfwa.games Voxel Tools", "unexpected provider")
    try require(manifest.geometry_license == "CC0-1.0", "unexpected geometry license")
    try require(manifest.geometry_url == "https://tfwagames.itch.io/voxel-tools",
                "unexpected geometry URL")
    try require(manifest.assets.count == expectedItems.count, "manifest must contain exactly 7 assets")
    try require(Set(manifest.assets.map(\.item)) == expectedItems,
                "manifest item set does not match the registered pickaxes")

    let geometryURL = root.appending(path: expectedGeometrySource)
    let geometryValues = try geometryURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    try require(geometryValues.isRegularFile == true && geometryValues.isSymbolicLink != true,
                "geometry source must be a regular non-symlink file")
    let geometryDigest = sha256Hex(try Data(contentsOf: geometryURL, options: .mappedIfSafe))
    try require(geometryDigest == expectedGeometrySHA256, "geometry source hash mismatch")

    var verifiedPNGs: [String: Data] = [:]
    for asset in manifest.assets {
        try require(asset.output == URL(fileURLWithPath: asset.output).lastPathComponent &&
                    !asset.output.contains("/") && !asset.output.contains("\\"),
                    "unsafe output path for \(asset.item)")
        try require(asset.output == "held_\(asset.item)_3d_128.png",
                    "unexpected output name for \(asset.item)")
        try require(asset.width == 128 && asset.height == 128,
                    "unexpected dimensions for \(asset.item)")
        try require(asset.output_sha256 == expectedOutputSHA256[asset.item],
                    "output hash is not the reviewed value for \(asset.item)")
        let outputURL = directory.appending(path: asset.output)
        let values = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true,
                    "output must be a regular non-symlink file: \(asset.output)")
        let png = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        try require(png.count <= 256 * 1024, "output exceeds byte budget: \(asset.output)")
        guard let dimensions = pngDimensions(png) else {
            throw EmbedFailure.invalid("invalid PNG: \(asset.output)")
        }
        try require(dimensions == (asset.width, asset.height),
                    "PNG dimensions disagree with manifest: \(asset.output)")
        try require(sha256Hex(png) == asset.output_sha256,
                    "PNG hash disagrees with manifest: \(asset.output)")
        verifiedPNGs[asset.item] = png
    }

    var source = """
    // Generated by scripts/embed-held-pickaxe-3d-assets.swift from the manifest-bound
    // CC0 voxel model renders. Do not hand-edit this file.

    import Foundation

    let modelRenderedPickaxeVisualAssets: [String: HeldItemVisualAsset] = [
    """
    for asset in manifest.assets.sorted(by: { $0.item < $1.item }) {
        guard let png = verifiedPNGs[asset.item] else {
            throw EmbedFailure.invalid("missing verified PNG for \(asset.item)")
        }
        source += "\n    \(String(reflecting: asset.item)): HeldItemVisualAsset(\n"
        source += "        itemName: \(String(reflecting: asset.item)),\n"
        source += "        provider: \(String(reflecting: manifest.geometry_provider)),\n"
        source += "        modelTaskID: \"blender-cc0-pickaxe-3d-v1\",\n"
        source += "        sourceSHA256: \(String(reflecting: asset.output_sha256)),\n"
        source += "        width: \(asset.width), height: \(asset.height),\n"
        source += "        sourceEntry: \(String(reflecting: manifest.geometry_source)),\n"
        source += "        sourceEntrySHA256: \(String(reflecting: manifest.geometry_source_sha256)),\n"
        source += "        pixelSource: .pngBase64(\n"
        source += "            \"\"\"\n"
        source += wrappedBase64(png) + "\n"
        source += "            \"\"\")),\n"
    }
    source += "\n]\n"
    let destination = root.appending(path: "Sources/Elysium/HeldPickaxe3DGeneratedAssets.swift")
    try source.write(to: destination, atomically: true, encoding: .utf8)
    print("embedded \(manifest.assets.count) model-rendered pickaxes -> \(destination.path)")
} catch {
    let message = "embed-held-pickaxe-3d-assets: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
