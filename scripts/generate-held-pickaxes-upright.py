#!/usr/bin/env python3
"""Render the original Elysium diagonal pickaxe (the authoritative per-material voxel art)
and stand it upright, matching the other stood-up held tools, so the fist grips a vertical
handle instead of the earlier hand-drawn vertical silhouette.

Writes held_<material>_pickaxe_128.png (the diagonal source, provenance) and
held_<material>_pickaxe_upright_128.png (embedded into HeldItemAssets.swift's
heldExtraVisualAssets) under Assets/Elysium/HeldTools/. All materials share one silhouette
(one shared rotation/scale/translation), so the material variants stay silhouette-identical.
"""
import os
import math

from PIL import Image
import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELD = os.path.join(REPO, "Assets", "Elysium", "HeldTools")

# The original diagonal silhouette (lowercase = material head shade, uppercase = wood handle).
SILHOUETTE = [
    "................", "................",
    "......dmmmmll...", "....ddmlllmmmd..", ".....dmmDDmmd...", ".........DMMmd..",
    "........DMM..d..", ".......DMM...d..", "......DMM....d..", ".....DMM......d.",
    "....DMM.........", "...DMM..........", "..DMM...........", ".DMM............",
    ".DM.............", "................",
]
HANDLE = {"D": (66, 36, 15), "M": (130, 78, 30), "L": (191, 128, 55)}
# Per-material head palettes (dark, middle, light) — matches HeldItemAssets.swift.
MATERIALS = {
    "wooden": ((82, 48, 22), (139, 88, 38), (193, 137, 67)),
    "stone": ((66, 70, 72), (112, 117, 119), (166, 171, 172)),
    "copper": ((101, 46, 27), (184, 89, 52), (237, 151, 92)),
    "iron": ((91, 101, 108), (164, 177, 183), (232, 239, 241)),
    "golden": ((134, 84, 0), (226, 168, 14), (255, 231, 91)),
    "diamond": ((8, 105, 116), (35, 195, 202), (159, 247, 244)),
    "netherite": ((38, 32, 41), (75, 65, 78), (119, 103, 121)),
}
SCALE = 6           # 16 -> 96 diagonal render
FIT_W, FIT_H = 118, 120
ANCHOR_X, ANCHOR_Y = 64, 124
SS = 4              # supersample for a clean rotation
REFERENCE = "iron"  # the variant the shared transform is measured from


def render_diagonal(material):
    dark, mid, light = MATERIALS[material]
    head = {"d": dark, "m": mid, "l": light}
    S = 16 * SCALE
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(SILHOUETTE):
        for x, ch in enumerate(row):
            col = head.get(ch) or HANDLE.get(ch)
            if not col:
                continue
            for yy in range(y * SCALE, (y + 1) * SCALE):
                for xx in range(x * SCALE, (x + 1) * SCALE):
                    px[xx, yy] = (col[0], col[1], col[2], 255)
    return im


def pca_angle(im):
    a = np.array(im)
    ys, xs = np.where(a[:, :, 3] > 32)
    xs0, ys0 = xs - xs.mean(), ys - ys.mean()
    _, vecs = np.linalg.eigh(np.cov(np.vstack([xs0, ys0])))
    ax = vecs[:, -1]
    return ((math.degrees(math.atan2(ax[0], -ax[1])) + 90) % 180) - 90


def rotated_content(im, ang):
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
    return xs[ys >= ys.max() - 8 * SS].mean()


def compose_128(content, scale, handle_x_ss):
    nw = max(1, round(content.width * scale))
    nh = max(1, round(content.height * scale))
    sm = content.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    out.alpha_composite(sm, (round(ANCHOR_X - handle_x_ss * scale), round(ANCHOR_Y - nh)))
    return out


def main():
    ref = render_diagonal(REFERENCE)
    ang = pca_angle(ref)
    ref_content = rotated_content(ref, ang)
    scale = min(FIT_W / ref_content.width, FIT_H / ref_content.height)
    hx = handle_bottom_x(ref_content)
    print(f"pickaxe angle={ang:+.1f} fit-scale={scale:.3f}")
    for material in MATERIALS:
        diag = render_diagonal(material)
        diag.save(os.path.join(HELD, f"held_{material}_pickaxe_128.png"))
        upright = compose_128(rotated_content(diag, ang), scale, hx)
        upright.save(os.path.join(HELD, f"held_{material}_pickaxe_upright_128.png"))
    print(f"wrote {len(MATERIALS)} diagonal + upright pickaxe sprites")


if __name__ == "__main__":
    main()
