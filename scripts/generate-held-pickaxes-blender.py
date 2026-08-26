#!/usr/bin/env python3
"""Render the bundled CC0 tfwa.games pickaxe mesh for every Elysium material.

Run with Blender, not the system Python:

    /Applications/Blender.app/Contents/MacOS/Blender --background --python-exit-code 1 \
      --python scripts/generate-held-pickaxes-blender.py

The source GLB remains the geometry authority.  This script changes only its
palette texture, then renders a stable three-quarter orthographic view with a
transparent background.  Runtime animation transforms the complete render;
it never rewrites these pixels.
"""

import bpy
import hashlib
import json
import math
import pathlib
import struct
import zlib
from mathutils import Vector


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Assets" / "Meshy" / "IronPickaxe" / "tfwa_pickaxe_cc0_source.glb"
OUTPUT = ROOT / "Assets" / "Elysium" / "HeldPickaxe3D"
SIZE = 128
EXPECTED_SOURCE_SHA256 = "3d3c188a832b80518f405f7ab95c7982d88cd482ac81fe9be4eb535e39269f1d"
EXPECTED_BLENDER_VERSION = (5, 1, 2)
EXPECTED_GENERATOR = "Blender 5.1.2 EEVEE model render"
EXPECTED_CAMERA = "orthographic three-quarter view; immutable runtime pixels"

# Dark / middle / light values follow Elysium's established material identity.
MATERIALS = {
    "wooden": ((82, 48, 22), (139, 88, 38), (193, 137, 67)),
    "stone": ((66, 70, 72), (112, 117, 119), (166, 171, 172)),
    "copper": ((101, 46, 27), (184, 89, 52), (237, 151, 92)),
    "iron": ((91, 101, 108), (164, 177, 183), (232, 239, 241)),
    "golden": ((134, 84, 0), (226, 168, 14), (255, 231, 91)),
    "diamond": ((8, 105, 116), (35, 195, 202), (159, 247, 244)),
    "netherite": ((38, 32, 41), (75, 65, 78), (119, 103, 121)),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonicalize_png(path):
    """Repack Blender's stable pixels into deterministic PNG bytes.

    Blender's threaded PNG writer can produce byte-different DEFLATE streams for
    identical pixels. Keep only color-critical chunks and recompress the exact
    filtered scanlines with Python zlib so manifest hashes reproduce byte-for-byte.
    """
    encoded = path.read_bytes()
    if encoded[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError(f"not a PNG: {path}")
    offset = 8
    retained = []
    compressed = bytearray()
    while offset < len(encoded):
        length = struct.unpack(">I", encoded[offset:offset + 4])[0]
        kind = encoded[offset + 4:offset + 8]
        data = encoded[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IDAT":
            compressed.extend(data)
        elif kind in {b"IHDR", b"sRGB", b"gAMA", b"cHRM"}:
            retained.append((kind, data))
        elif kind == b"IEND":
            break
    scanlines = zlib.decompress(bytes(compressed))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    canonical = bytearray(encoded[:8])
    for kind, data in retained:
        canonical.extend(chunk(kind, data))
    canonical.extend(chunk(b"IDAT", zlib.compress(scanlines, level=9)))
    canonical.extend(chunk(b"IEND", b""))
    path.write_bytes(canonical)


def add_area_light(name, location, energy, size):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    light = bpy.data.objects.new(name, data)
    light.location = location
    bpy.context.scene.collection.objects.link(light)


def palette_image(source, name, shades):
    image = source.copy()
    image.name = f"Elysium_{name}_pickaxe_palette"
    pixels = list(source.pixels[:])
    dark, middle, light = shades
    replacements = tuple(tuple(channel / 255.0 for channel in shade) for shade in shades)
    for offset in range(0, len(pixels), 4):
        red, green, blue, alpha = pixels[offset:offset + 4]
        if alpha <= 0 or max(red, green, blue) - min(red, green, blue) > 0.015:
            continue
        # The source head uses four neutral palette steps.  Preserve their
        # authored light ordering while mapping them onto the selected material.
        luminance = (red + green + blue) / 3
        if luminance < 0.30:
            color = replacements[0]
        elif luminance < 0.50:
            color = tuple((dark[i] * 0.35 + middle[i] * 0.65) / 255.0 for i in range(3))
        elif luminance < 0.75:
            color = replacements[1]
        else:
            color = replacements[2]
        pixels[offset:offset + 3] = color
    image.pixels.foreach_set(pixels)
    image.update()
    return image


def configure_scene():
    bpy.ops.import_scene.gltf(filepath=str(SOURCE))
    model = next(
        obj for obj in bpy.context.scene.objects
        if obj.type == "MESH" and obj.name.startswith("Node")
    )
    for obj in list(bpy.context.scene.objects):
        if obj != model:
            bpy.data.objects.remove(obj, do_unlink=True)

    corners = [model.matrix_world @ Vector(corner) for corner in model.bound_box]
    center = sum(corners, Vector()) / len(corners)
    model.location -= center
    model.rotation_euler[2] = math.radians(-5)

    camera_data = bpy.data.cameras.new("Elysium_Pickaxe_Camera")
    camera = bpy.data.objects.new("Elysium_Pickaxe_Camera", camera_data)
    bpy.context.scene.collection.objects.link(camera)
    camera.location = (5, -10, 3.5)
    camera.rotation_euler = (-camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 5.0
    bpy.context.scene.camera = camera

    add_area_light("Elysium_Key", (-4, -6, 7), 850, 5)
    add_area_light("Elysium_Fill", (5, 1, 3), 350, 4)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = SIZE
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.world.color = (0.08, 0.08, 0.08)
    return model


def main():
    if tuple(bpy.app.version) != EXPECTED_BLENDER_VERSION:
        expected = ".".join(str(component) for component in EXPECTED_BLENDER_VERSION)
        raise RuntimeError(
            f"unsupported Blender version: expected {expected}, got {bpy.app.version_string}")
    if not SOURCE.is_file():
        raise RuntimeError(f"missing source model: {SOURCE}")
    if SOURCE.is_symlink():
        raise RuntimeError(f"source model must be a regular non-symlink file: {SOURCE}")
    source_digest = sha256(SOURCE)
    if source_digest != EXPECTED_SOURCE_SHA256:
        raise RuntimeError(
            f"source model hash mismatch: expected {EXPECTED_SOURCE_SHA256}, got {source_digest}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    model = configure_scene()
    material = model.data.materials[0]
    texture_node = next(node for node in material.node_tree.nodes if node.type == "TEX_IMAGE")
    source_palette = texture_node.image
    records = []
    for name, shades in MATERIALS.items():
        rendered_palette = palette_image(source_palette, name, shades)
        texture_node.image = rendered_palette
        destination = OUTPUT / f"held_{name}_pickaxe_3d_128.png"
        bpy.context.scene.render.filepath = str(destination)
        bpy.ops.render.render(write_still=True)
        canonicalize_png(destination)
        records.append({
            "item": f"{name}_pickaxe",
            "output": destination.name,
            "output_sha256": sha256(destination),
            "width": SIZE,
            "height": SIZE,
        })
        bpy.data.images.remove(rendered_palette)

    manifest = {
        "generator": EXPECTED_GENERATOR,
        "geometry_source": str(SOURCE.relative_to(ROOT)),
        "geometry_source_sha256": source_digest,
        "geometry_provider": "tfwa.games Voxel Tools",
        "geometry_license": "CC0-1.0",
        "geometry_url": "https://tfwagames.itch.io/voxel-tools",
        "camera": EXPECTED_CAMERA,
        "assets": records,
    }
    (OUTPUT / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "assets": len(records), "output": str(OUTPUT)}))


main()
