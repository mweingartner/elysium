#!/usr/bin/env python3
"""Stand the melee/mining held-tool sprites upright so their handle aligns to the
first-person fist grip (a vertical column), instead of the diagonal Minecraft-item
orientation the Faithful source ships.

Pipeline stage: run AFTER scripts/generate-held-tools-blender.py (which writes the
diagonal Faithful upscales `held_<item>_128.png`) and BEFORE
scripts/embed-held-tool-assets.swift (which embeds the manifest `output` PNG bytes
into Sources/Elysium/HeldToolGeneratedAssets.swift).

The diagonal `held_<item>_128.png` stays the committed provenance/source; this stage
reads it and writes an upright `held_<item>_upright_128.png`, then repoints the
manifest `output` (and `output_sha256`) at the upright file. So it is naturally
idempotent — it always re-derives from the unchanged diagonal source — and never
double-rotates.

Per tool TYPE the rotation/scale/translation is computed once (from the iron
variant) and applied identically to every material, so the material variants keep a
single shared silhouette (ResourcePackHardeningTests asserts this).
"""
import hashlib
import json
import math
import os
import sys

from PIL import Image
import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELD = os.path.join(REPO, "Assets", "Elysium", "HeldTools")
MANIFEST = os.path.join(HELD, "manifest.json")

TYPES = ["sword", "axe", "shovel", "hoe"]
MATERIALS = ["wooden", "stone", "copper", "iron", "golden", "diamond", "netherite"]
REFERENCE_MATERIAL = "iron"  # the variant the shared transform is measured from

# Fit box inside the 128 frame and where the handle bottom (pommel) is anchored.
FIT_W, FIT_H = 120, 122
ANCHOR_X, ANCHOR_Y = 64, 124
SS = 4  # supersample factor for a clean rotation


def diagonal_source(item):
    return Image.open(os.path.join(HELD, f"held_{item}_128.png")).convert("RGBA")


def pca_angle(im):
    a = np.array(im)
    ys, xs = np.where(a[:, :, 3] > 32)
    xs0, ys0 = xs - xs.mean(), ys - ys.mean()
    cov = np.cov(np.vstack([xs0, ys0]))
    _, vecs = np.linalg.eigh(cov)
    ax = vecs[:, -1]  # principal (longest) axis
    ang = math.degrees(math.atan2(ax[0], -ax[1]))
    return ((ang + 90) % 180) - 90  # fold to (-90, 90]; rotate by +ang -> vertical


def rotated_content(im, ang):
    """Rotate upright on a large transparent canvas; return the tight-cropped SS content."""
    up = im.resize((im.width * SS, im.height * SS), Image.NEAREST)
    canvas = Image.new("RGBA", (up.width * 2, up.height * 2), (0, 0, 0, 0))
    canvas.alpha_composite(up, (up.width // 2, up.height // 2))
    r = canvas.rotate(ang, resample=Image.BICUBIC, center=(up.width, up.height))
    a = np.array(r)
    ys, xs = np.where(a[:, :, 3] > 16)
    return r.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def handle_bottom_x(content):
    a = np.array(content)
    ys, xs = np.where(a[:, :, 3] > 16)
    ymax = ys.max()
    return xs[ys >= ymax - 8 * SS].mean()


def compose_128(content, scale, handle_x_ss):
    """Downscale the SS content by `scale`, then place it handle-centered & bottom-anchored."""
    nw = max(1, round(content.width * scale))
    nh = max(1, round(content.height * scale))
    sm = content.resize((nw, nh), Image.LANCZOS)
    hx = handle_x_ss * scale
    out = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    out.alpha_composite(sm, (round(ANCHOR_X - hx), round(ANCHOR_Y - nh)))
    return out


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    manifest = json.load(open(MANIFEST))
    by_item = {a["item"]: a for a in manifest["assets"]}
    changed = 0
    for t in TYPES:
        # Measure the shared transform once, from the reference material.
        ref = diagonal_source(f"{REFERENCE_MATERIAL}_{t}")
        ang = pca_angle(ref)
        ref_content = rotated_content(ref, ang)
        scale = min(FIT_W / ref_content.width, FIT_H / ref_content.height)
        hx = handle_bottom_x(ref_content)
        print(f"{t:7} angle={ang:+5.1f}  fit-scale={scale:.3f}")
        for m in MATERIALS:
            item = f"{m}_{t}"
            content = rotated_content(diagonal_source(item), ang)  # shared silhouette
            out = compose_128(content, scale, hx)
            out_name = f"held_{item}_upright_128.png"
            out.save(os.path.join(HELD, out_name))
            entry = by_item.get(item)
            if entry:
                entry["output"] = out_name
                entry["output_sha256"] = sha256(os.path.join(HELD, out_name))
                entry["orientation"] = "upright"
            changed += 1
    manifest["tool_orientation"] = (
        "melee/mining tools (sword/axe/shovel/hoe) stood upright by "
        "scripts/align-held-tools-upright.py so the handle aligns to the fist grip; "
        "the diagonal held_<item>_128.png remains the Faithful-derived source"
    )
    json.dump(manifest, open(MANIFEST, "w"), indent=2)
    open(MANIFEST, "a").write("\n")
    print(f"aligned {changed} tool sprites; manifest repointed to upright outputs")


if __name__ == "__main__":
    sys.exit(main())
