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

Edge quality: resampling is done in premultiplied alpha so fully transparent (black)
texels never bleed into the edge colour; a half-output-pixel Gaussian pre-filter
followed by a box downscale keeps the source's 45-degree outline staircase from
aliasing into a serrated edge; and the result is returned to straight alpha with
specks (< EDGE_SPECK_ALPHA) dropped and near-opaque pixels snapped solid.
Straight-alpha bicubic/Lanczos resampling used to leave a dashed ring of dark,
half-transparent pixels around every tool that the nearest-sampled first-person
layer rendered as missing fragments along the blade and haft.
"""
import hashlib
import json
import math
import os
import sys

from PIL import Image, ImageFilter
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
EDGE_PREFILTER = 0.5     # Gaussian radius, in output pixels, applied before the downscale
EDGE_SPECK_ALPHA = 32    # coverage below this is dropped (stray resampling specks)
EDGE_SOLID_ALPHA = 224   # coverage at or above this is snapped fully opaque


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


def premultiplied(im):
    """RGBA -> premultiplied RGBA so resampling never mixes in the black of clear texels."""
    a = np.array(im).astype(np.float32)
    a[:, :, :3] *= a[:, :, 3:4] / 255.0
    return Image.fromarray(np.rint(a).clip(0, 255).astype(np.uint8), "RGBA")


def straight_alpha(im):
    """Premultiplied RGBA -> straight RGBA with cleaned coverage.

    True colours are restored by dividing out coverage; stray specks are dropped and
    near-solid pixels snapped opaque, so the only partial pixels left are a thin,
    correctly coloured anti-aliased rim (no dark half-transparent fringe).
    """
    a = np.array(im).astype(np.float32)
    alpha = a[:, :, 3]
    keep = alpha >= EDGE_SPECK_ALPHA
    rgb = np.zeros_like(a[:, :, :3])
    rgb[keep] = a[:, :, :3][keep] * (255.0 / alpha[keep][:, None])
    out = np.zeros_like(a)
    out[:, :, :3] = np.rint(rgb).clip(0, 255)
    out[:, :, 3] = np.where(keep, np.where(alpha >= EDGE_SOLID_ALPHA, 255, alpha), 0)
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def rotated_content(im, ang):
    """Rotate upright on a large transparent canvas; return the tight-cropped SS content
    (premultiplied alpha)."""
    up = premultiplied(im).resize((im.width * SS, im.height * SS), Image.NEAREST)
    canvas = Image.new("RGBA", (up.width * 2, up.height * 2), (0, 0, 0, 0))
    canvas.paste(up, (up.width // 2, up.height // 2))
    r = canvas.rotate(ang, resample=Image.BILINEAR, center=(up.width, up.height))
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
    filtered = content.filter(ImageFilter.GaussianBlur(radius=EDGE_PREFILTER / scale))
    sm = filtered.resize((nw, nh), Image.BOX)  # premultiplied, ring-free area average
    hx = handle_x_ss * scale
    out = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    out.paste(sm, (round(ANCHOR_X - hx), round(ANCHOR_Y - nh)))
    return straight_alpha(out)


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
