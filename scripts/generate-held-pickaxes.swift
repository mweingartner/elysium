#!/usr/bin/env swift

import AppKit
import Foundation

private struct RGB {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var color: NSColor {
        NSColor(
            calibratedRed: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: 1)
    }
}

private struct HeadPalette {
    let dark: RGB
    let middle: RGB
    let light: RGB
}

private let headPalettes: [(name: String, palette: HeadPalette)] = [
    ("wooden", HeadPalette(
        dark: RGB(red: 82, green: 48, blue: 22),
        middle: RGB(red: 139, green: 88, blue: 38),
        light: RGB(red: 193, green: 137, blue: 67))),
    ("stone", HeadPalette(
        dark: RGB(red: 66, green: 70, blue: 72),
        middle: RGB(red: 112, green: 117, blue: 119),
        light: RGB(red: 166, green: 171, blue: 172))),
    ("copper", HeadPalette(
        dark: RGB(red: 101, green: 46, blue: 27),
        middle: RGB(red: 184, green: 89, blue: 52),
        light: RGB(red: 237, green: 151, blue: 92))),
    ("iron", HeadPalette(
        dark: RGB(red: 91, green: 101, blue: 108),
        middle: RGB(red: 164, green: 177, blue: 183),
        light: RGB(red: 232, green: 239, blue: 241))),
    ("golden", HeadPalette(
        dark: RGB(red: 134, green: 84, blue: 0),
        middle: RGB(red: 226, green: 168, blue: 14),
        light: RGB(red: 255, green: 231, blue: 91))),
    ("diamond", HeadPalette(
        dark: RGB(red: 8, green: 105, blue: 116),
        middle: RGB(red: 35, green: 195, blue: 202),
        light: RGB(red: 159, green: 247, blue: 244))),
    ("netherite", HeadPalette(
        dark: RGB(red: 38, green: 32, blue: 41),
        middle: RGB(red: 75, green: 65, blue: 78),
        light: RGB(red: 119, green: 103, blue: 121))),
]

// One original 16x16 silhouette shared by every material. Lowercase cells are
// head shades; uppercase cells are the invariant wooden handle. The image is
// enlarged 6x with exact nearest-neighbor squares for a 96x96 held-item bake.
private let silhouette = [
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

private let handlePalette: [Character: RGB] = [
    "D": RGB(red: 66, green: 36, blue: 15),
    "M": RGB(red: 130, green: 78, blue: 30),
    "L": RGB(red: 191, green: 128, blue: 55),
]

private func render(_ palette: HeadPalette) throws -> Data {
    let logicalSize = 16
    let pixelScale = 6
    let size = logicalSize * pixelScale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32)
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    guard let bitmapData = bitmap.bitmapData else {
        throw CocoaError(.fileWriteUnknown)
    }
    bitmapData.initialize(repeating: 0, count: bitmap.bytesPerRow * size)
    let head: [Character: RGB] = [
        "d": palette.dark,
        "m": palette.middle,
        "l": palette.light,
    ]
    for (sourceY, row) in silhouette.enumerated() {
        for (sourceX, cell) in row.enumerated() {
            guard let rgb = head[cell] ?? handlePalette[cell] else { continue }
            // NSBitmapImageRep writes these rows in the same top-down order used
            // by the runtime PNG decoder.
            let startY = sourceY * pixelScale
            for y in startY..<(startY + pixelScale) {
                for x in (sourceX * pixelScale)..<((sourceX + 1) * pixelScale) {
                    bitmap.setColor(rgb.color, atX: x, y: y)
                }
            }
        }
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = repository.appending(path: "Assets/Elysium/HeldPickaxes", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for entry in headPalettes {
    let destination = output.appending(path: "held_\(entry.name)_pickaxe_96.png")
    try render(entry.palette).write(to: destination, options: .atomic)
    print(destination.path)
}
