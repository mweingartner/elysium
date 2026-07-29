#!/usr/bin/env python3
"""Generate Elysium's non-pickaxe held-tool sprites inside Blender.

Run this file through the reviewed localhost Blender bridge:

    python3 ~/dev/blender-bridge/bb.py file scripts/generate-held-tools-blender.py

The bundled Faithful 64x pack is Elysium's licensed visual baseline. Blender
decodes those source pixels, exports deterministic 2x nearest-neighbour RGBA
sprites, and writes a manifest binding every output to its exact source entry.
Pickaxes are intentionally excluded: their separately reviewed Elysium
silhouette is the accepted in-game shape.
"""

import bpy
import hashlib
import json
import pathlib
import zipfile


def repository_root():
    candidates = (
        pathlib.Path.cwd(),
        pathlib.Path.home() / "dev" / "elysium-arm-inventory-sort",
        pathlib.Path.home() / "dev" / "elysium",
        pathlib.Path.home() / "dev" / "pebble",
    )
    for candidate in candidates:
        if (candidate / "Package.swift").is_file() and (
            candidate / "packaging" / "Faithful 64x - December 2025 Release.zip"
        ).is_file():
            return candidate.resolve()
    raise RuntimeError("cannot locate an Elysium checkout with the managed Faithful pack")


ROOT = repository_root()
PACK = ROOT / "packaging" / "Faithful 64x - December 2025 Release.zip"
OUTPUT = ROOT / "Assets" / "Elysium" / "HeldTools"
SOURCE_PREFIX = "assets/minecraft/textures/item/"
OUTPUT_SIZE = 128

MATERIALS = ("wooden", "stone", "copper", "iron", "golden", "diamond", "netherite")
FAMILIES = ("sword", "axe", "shovel", "hoe")

SOURCES = {
    **{f"{material}_{family}": f"{material}_{family}.png"
       for material in MATERIALS for family in FAMILIES},
    "shears": "shears.png",
    "flint_and_steel": "flint_and_steel.png",
    "fishing_rod": "fishing_rod.png",
    "bow": "bow.png",
    "bow_pulling_0": "bow_pulling_0.png",
    "bow_pulling_1": "bow_pulling_1.png",
    "bow_pulling_2": "bow_pulling_2.png",
    "crossbow": "crossbow_standby.png",
    "trident": "trident.png",
    "brush": "brush.png",
    "flying_wand": "blaze_rod.png",
    "shield": "assets/minecraft/textures/entity/shield_base_nopattern.png",
}


def image_pixels_from_png(encoded, name):
    temporary = OUTPUT / f".{name}.source.png"
    temporary.write_bytes(encoded)
    try:
        image = bpy.data.images.load(str(temporary), check_existing=False)
        image.colorspace_settings.name = "Non-Color"
        width, height = image.size
        if width <= 0 or height <= 0 or width > 4096 or height > 4096:
            raise RuntimeError(f"{name}: invalid source bounds {width}x{height}")
        source = list(image.pixels[:])
        return width, height, source
    finally:
        try:
            if 'image' in locals():
                bpy.data.images.remove(image)
        finally:
            temporary.unlink(missing_ok=True)


def export_nearest_rgba(name, source_width, source_height, source):
    if OUTPUT_SIZE % source_width != 0 or OUTPUT_SIZE % source_height != 0:
        raise RuntimeError(f"{name}: {source_width}x{source_height} does not divide {OUTPUT_SIZE}")
    scale_x = OUTPUT_SIZE // source_width
    scale_y = OUTPUT_SIZE // source_height
    target = [0.0] * (OUTPUT_SIZE * OUTPUT_SIZE * 4)
    for y in range(OUTPUT_SIZE):
        source_y = min(source_height - 1, y // scale_y)
        for x in range(OUTPUT_SIZE):
            source_x = min(source_width - 1, x // scale_x)
            source_offset = (source_y * source_width + source_x) * 4
            target_offset = (y * OUTPUT_SIZE + x) * 4
            target[target_offset:target_offset + 4] = source[source_offset:source_offset + 4]

    image = bpy.data.images.new(
        f"Elysium_{name}", width=OUTPUT_SIZE, height=OUTPUT_SIZE, alpha=True, float_buffer=False)
    try:
        image.colorspace_settings.name = "Non-Color"
        image.alpha_mode = "STRAIGHT"
        image.file_format = "PNG"
        image.filepath_raw = str(OUTPUT / f"held_{name}_128.png")
        image.pixels.foreach_set(target)
        image.update()
        image.save()
    finally:
        bpy.data.images.remove(image)


def export_shield_rgba(source_width, source_height, source):
    if source_width != 256 or source_height != 256:
        raise RuntimeError(f"shield: expected Faithful 256x256 entity atlas, got {source_width}x{source_height}")
    # The unpatterned front occupies a 52x88 region in the visual upper-left of
    # the entity atlas. Blender's pixel buffer is bottom-up, so that visual crop
    # begins at source row 168. Center it without distorting the authored ratio.
    crop_width, crop_height = 52, 88
    target_x, target_y = (OUTPUT_SIZE - crop_width) // 2, (OUTPUT_SIZE - crop_height) // 2
    source_y = source_height - crop_height
    target = [0.0] * (OUTPUT_SIZE * OUTPUT_SIZE * 4)
    for y in range(crop_height):
        for x in range(crop_width):
            source_offset = ((source_y + y) * source_width + x) * 4
            target_offset = ((target_y + y) * OUTPUT_SIZE + target_x + x) * 4
            target[target_offset:target_offset + 4] = source[source_offset:source_offset + 4]
    image = bpy.data.images.new(
        "Elysium_shield", width=OUTPUT_SIZE, height=OUTPUT_SIZE, alpha=True, float_buffer=False)
    try:
        image.colorspace_settings.name = "Non-Color"
        image.alpha_mode = "STRAIGHT"
        image.file_format = "PNG"
        image.filepath_raw = str(OUTPUT / "held_shield_128.png")
        image.pixels.foreach_set(target)
        image.update()
        image.save()
    finally:
        bpy.data.images.remove(image)


def export_contact_sheet(records):
    columns = 6
    rows = (len(records) + columns - 1) // columns
    padding = 8
    width = columns * OUTPUT_SIZE + (columns + 1) * padding
    height = rows * OUTPUT_SIZE + (rows + 1) * padding
    background = (0.035, 0.035, 0.035, 1.0)
    target = list(background) * (width * height)
    for index, record in enumerate(records):
        image = bpy.data.images.load(str(OUTPUT / record["output"]), check_existing=False)
        try:
            source = list(image.pixels[:])
        finally:
            bpy.data.images.remove(image)
        column = index % columns
        row = rows - 1 - index // columns
        origin_x = padding + column * (OUTPUT_SIZE + padding)
        origin_y = padding + row * (OUTPUT_SIZE + padding)
        for y in range(OUTPUT_SIZE):
            for x in range(OUTPUT_SIZE):
                source_offset = (y * OUTPUT_SIZE + x) * 4
                alpha = source[source_offset + 3]
                target_offset = ((origin_y + y) * width + origin_x + x) * 4
                for channel in range(3):
                    target[target_offset + channel] = (
                        source[source_offset + channel] * alpha
                        + background[channel] * (1.0 - alpha)
                    )
                target[target_offset + 3] = 1.0

    sheet = bpy.data.images.new(
        "Elysium_HeldTools_Contact", width=width, height=height,
        alpha=False, float_buffer=False)
    try:
        sheet.colorspace_settings.name = "Non-Color"
        sheet.file_format = "PNG"
        sheet.filepath_raw = str(OUTPUT / "held_tools_blender_contact.png")
        sheet.pixels.foreach_set(target)
        sheet.update()
        sheet.save()
    finally:
        bpy.data.images.remove(sheet)


def main():
    if not PACK.is_file():
        raise RuntimeError(f"missing managed Faithful pack: {PACK}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    records = []
    with zipfile.ZipFile(PACK, "r") as archive:
        names = set(archive.namelist())
        for item_name in sorted(SOURCES):
            source_name = SOURCES[item_name]
            entry = source_name if source_name.startswith("assets/") else SOURCE_PREFIX + source_name
            if entry not in names:
                raise RuntimeError(f"{item_name}: missing source entry {entry}")
            encoded = archive.read(entry)
            width, height, pixels = image_pixels_from_png(encoded, item_name)
            if item_name == "shield":
                export_shield_rgba(width, height, pixels)
            else:
                if width != height or width > OUTPUT_SIZE:
                    raise RuntimeError(f"{item_name}: expected a bounded square source, got {width}x{height}")
                export_nearest_rgba(item_name, width, height, pixels)
            output_path = OUTPUT / f"held_{item_name}_128.png"
            output_bytes = output_path.read_bytes()
            records.append({
                "item": item_name,
                "source": entry,
                "source_sha256": hashlib.sha256(encoded).hexdigest(),
                "output": output_path.name,
                "output_sha256": hashlib.sha256(output_bytes).hexdigest(),
                "width": OUTPUT_SIZE,
                "height": OUTPUT_SIZE,
            })

    export_contact_sheet(records)

    manifest = {
        "generator": "Blender 5.1 bpy image pipeline",
        "source_pack": PACK.name,
        "source_license": "Faithful License v3; see packaging/FAITHFUL-LICENSE.txt",
        "pixel_filter": "2x nearest-neighbour",
        "pickaxes": "Excluded; Elysium diagonal pickaxe silhouette remains authoritative",
        "assets": records,
    }
    (OUTPUT / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "ok": True,
        "blender": bpy.app.version_string,
        "assets": len(records),
        "output": str(OUTPUT),
    }, sort_keys=True))


main()
