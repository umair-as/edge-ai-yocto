#!/usr/bin/env python3
"""
Generate the EDGE AI OS boot splash.

Author  : Umair Ahmed Shah  <github.com/umair-as>
Purpose : Layered vector composition (gradient + neural-net field + hexagon
          chip motif + PCB corner traces + text) so the result stays sharp
          under photograph / screen-capture / video-record demos. Bright
          cyan text on dark navy = high contrast that survives downscaling.

Outputs (relative to repo root):
  meta-edge-distro/recipes-core/psplash/files/psplash-edge-img.png
      → psplash boot daemon (Linux side, post-kernel)
  meta-edge-bsp/recipes-bsp/splash-assets/files/splash.bmp
      → U-Boot BMP3 24-bit, displayed via `bmp display ${loadaddr} m m`
        (replaces the placeholder shipped by edge-splash-assets)

Usage:
  python3 scripts/generate-splash.py
  python3 scripts/generate-splash.py --preview          # open in image viewer
  python3 scripts/generate-splash.py --out-dir /tmp     # write elsewhere
"""

import math
import random
import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ── Canvas ──────────────────────────────────────────────────────────────────
W, H = 1920, 1080

# ── Palette ─────────────────────────────────────────────────────────────────
BG1      = (10,  14,  26)    # very dark navy  — center
BG2      = (16,  26,  50)    # slightly lighter — edge of gradient
CYAN     = (0,   210, 255)   # #00d2ff  primary accent
CYAN_DIM = (0,    70, 100)   # dim cyan  for background geometry
CYAN_MID = (0,   130, 170)   # mid cyan  for secondary outlines
WHITE    = (255, 255, 255)
GREY     = (180, 195, 225)   # slightly brighter than sibling — for visibility
DIM      = (90,  110, 150)   # bottom-strip text: lifted so it survives capture
STRIP    = (6,   10,  20)    # bottom strip background


# ── Helpers ──────────────────────────────────────────────────────────────────
def _font(name: str, size: int) -> ImageFont.FreeTypeFont:
    base = "/usr/share/fonts/truetype/dejavu/"
    try:
        return ImageFont.truetype(base + name, size)
    except OSError:
        return ImageFont.load_default()


def _hex_pts(cx, cy, r, angle_offset=0):
    return [
        (cx + r * math.cos(math.radians(60 * i + angle_offset)),
         cy + r * math.sin(math.radians(60 * i + angle_offset)))
        for i in range(6)
    ]


# ── Layer: gradient background ───────────────────────────────────────────────
def _gradient_bg() -> np.ndarray:
    xs = np.tile(np.arange(W, dtype=np.float32), (H, 1))
    ys = np.tile(np.arange(H, dtype=np.float32), (W, 1)).T
    cx, cy = W / 2.0, H / 2.0
    r = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2)
    r_norm = np.clip(r / math.sqrt(cx ** 2 + cy ** 2), 0.0, 1.0)

    arr = np.zeros((H, W, 3), dtype=np.uint8)
    for ch in range(3):
        arr[:, :, ch] = np.clip(
            BG1[ch] + (BG2[ch] - BG1[ch]) * r_norm, 0, 255
        ).astype(np.uint8)
    return arr


# ── Layer: neural-net field ─────────────────────────────────────────────────
def _neural_layer(seed: int = 42) -> Image.Image:
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    rng = random.Random(seed)

    # Nodes clustered near canvas centre so they survive display clipping
    nodes = []
    cx, cy = W // 2, H // 2
    for _ in range(22):
        radius = abs(rng.gauss(0, 280))
        theta  = rng.uniform(0, 2 * math.pi)
        nodes.append((cx + radius * math.cos(theta),
                      cy + radius * math.sin(theta) * 0.75))
    for _ in range(12):
        nodes.append((rng.uniform(60, W - 60), rng.uniform(60, H - 60)))

    # Connection lines — dim, fade with distance
    for i, (x1, y1) in enumerate(nodes):
        for j in range(i + 1, len(nodes)):
            x2, y2 = nodes[j]
            dist = math.hypot(x2 - x1, y2 - y1)
            if dist < 310:
                a = int(55 * (1.0 - dist / 310))
                d.line([(x1, y1), (x2, y2)], fill=(*CYAN_DIM, a), width=1)

    # Glow dots: bright points + blur, then crisp core on top
    dot_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dot_layer)
    for (x, y) in nodes:
        s = rng.uniform(3.5, 8.0)
        dd.ellipse([(x - s, y - s), (x + s, y + s)], fill=(*CYAN, 255))

    glow = dot_layer.filter(ImageFilter.GaussianBlur(radius=7))
    layer.alpha_composite(glow)
    layer.alpha_composite(dot_layer)
    return layer


# ── Layer: hexagon chip motif ───────────────────────────────────────────────
def _chip_layer(cx: int, cy: int) -> Image.Image:
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d     = ImageDraw.Draw(layer)

    # outer glow rings (blurred separately)
    glow_src = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow_src)
    for r in (95, 82):
        pts = _hex_pts(cx, cy, r, -30)
        gd.polygon(pts, fill=None, outline=(*CYAN, 50), width=2)
    glow = glow_src.filter(ImageFilter.GaussianBlur(radius=20))
    layer.alpha_composite(glow)

    # faint outer rings
    for r in (128, 112, 96):
        alpha = int(25 * (1.0 - (r - 96) / 32.0))
        pts = _hex_pts(cx, cy, r, -30)
        d.polygon(pts, fill=None, outline=(*CYAN_DIM, alpha), width=1)

    # main hex outlines
    pts_outer = _hex_pts(cx, cy, 82, -30)
    pts_inner = _hex_pts(cx, cy, 58, -30)
    d.polygon(pts_outer, fill=None, outline=(*CYAN, 255), width=3)
    d.polygon(pts_inner, fill=None, outline=(*CYAN_MID, 200), width=1)

    # cross-hairs
    d.line([(cx - 42, cy), (cx + 42, cy)], fill=(*CYAN_MID, 170), width=1)
    d.line([(cx, cy - 42), (cx, cy + 42)], fill=(*CYAN_MID, 170), width=1)

    # pin stubs at each corner
    for i in range(6):
        angle = math.radians(60 * i - 30)
        x1 = cx + 82  * math.cos(angle)
        y1 = cy + 82  * math.sin(angle)
        x2 = cx + 118 * math.cos(angle)
        y2 = cy + 118 * math.sin(angle)
        d.line([(x1, y1), (x2, y2)], fill=(*CYAN_MID, 220), width=2)
        d.ellipse([(x2 - 4, y2 - 4), (x2 + 4, y2 + 4)], fill=(*CYAN, 230))

    # centre dot
    d.ellipse([(cx - 11, cy - 11), (cx + 11, cy + 11)], fill=(*CYAN, 255))
    d.ellipse([(cx -  5, cy -  5), (cx +  5, cy +  5)], fill=(*WHITE, 255))

    # small "AI" glyph inside hex centre
    fnt = _font("DejaVuSans-Bold.ttf", 28)
    label = "AI"
    bbox  = d.textbbox((0, 0), label, font=fnt)
    lw = bbox[2] - bbox[0]
    lh = bbox[3] - bbox[1]
    d.text((cx - lw // 2, cy - lh // 2 - 2), label, font=fnt,
           fill=(*CYAN, 220))

    return layer


# ── Layer: PCB corner traces ─────────────────────────────────────────────────
def _corner_traces(d: ImageDraw.ImageDraw):
    def trace(pts):
        d.line(pts, fill=DIM, width=1)
        for p in (pts[0], pts[-1]):
            d.ellipse([(p[0]-3, p[1]-3), (p[0]+3, p[1]+3)], fill=DIM)

    # top-left
    trace([(28, 72),  (115, 72),  (115, 105), (185, 105)])
    trace([(72, 28),  (72, 158)])
    trace([(115, 72), (115, 38)])
    # top-right
    trace([(W-28, 72),  (W-115, 72),  (W-115, 105), (W-185, 105)])
    trace([(W-72, 28),  (W-72, 158)])
    # bottom-left
    trace([(28, H-72),  (115, H-72),  (115, H-105), (185, H-105)])
    trace([(72, H-28),  (72, H-158)])
    # bottom-right
    trace([(W-28, H-72),  (W-115, H-72),  (W-115, H-105), (W-185, H-105)])
    trace([(W-72, H-28),  (W-72, H-158)])


# ── Layer: text + UI chrome ──────────────────────────────────────────────────
# All elements anchored to W//2 so content survives 1280x800 or smaller
# centred display clipping.

def _cx_text(d, y, text, font, fill):
    bbox = d.textbbox((0, 0), text, font=font)
    x = (W - (bbox[2] - bbox[0])) // 2
    d.text((x, y), text, font=font, fill=fill)


def _lh(font) -> int:
    asc, desc = font.getmetrics()
    return asc + desc


def _text_and_chrome(d: ImageDraw.ImageDraw):
    f_title = _font("DejaVuSans-Bold.ttf", 118)
    f_sub   = _font("DejaVuSans-Bold.ttf",  44)
    f_info  = _font("DejaVuSans.ttf",        27)
    f_tag   = _font("DejaVuSans-Bold.ttf",   28)
    f_bot   = _font("DejaVuSansMono-Bold.ttf", 26)

    # Title starts with a small gap below the chip (chip_cy = H//2-200,
    # chip bottom ~458). No version anywhere — recipe metadata carries
    # the version, the splash carries identity.
    ty = H // 2 - 60

    # Main title — "EDGE AI OS"
    _cx_text(d, ty, "EDGE AI OS", f_title, CYAN)

    # Subtitle — "AI ON EDGE"
    sub_y = ty + _lh(f_title) + 6
    _cx_text(d, sub_y, "AI  ON  EDGE", f_sub, WHITE)

    # Horizontal rule with endpoint dots
    rule_y = sub_y + _lh(f_sub) + 14
    rx0, rx1 = W // 2 - 260, W // 2 + 260
    d.line([(rx0, rule_y), (rx1, rule_y)], fill=CYAN, width=2)
    d.ellipse([(rx0 - 5, rule_y - 5), (rx0 + 5, rule_y + 5)], fill=CYAN)
    d.ellipse([(rx1 - 5, rule_y - 5), (rx1 + 5, rule_y + 5)], fill=CYAN)

    # Author + repo URL — both bright enough to read under capture
    _cx_text(d, rule_y + 18, "Umair Ahmed Shah", f_info, GREY)
    _cx_text(d, rule_y + 18 + _lh(f_info) + 6,
             "github.com/umair-as/edge-ai-yocto",
             f_tag, CYAN)

    # Bottom strip — repeats the repo URL prominently along the bottom edge
    # so it stays visible even when the upper half of the canvas is clipped
    # by a smaller-than-1920 display window.
    strip_y = H - 190
    d.rectangle([(0, strip_y), (W, strip_y + 50)], fill=STRIP)
    d.line([(0, strip_y), (W, strip_y)], fill=(*CYAN_DIM,), width=1)
    bot = ("Umair Ahmed Shah   ·   github.com/umair-as/edge-ai-yocto"
           "   ·   Edge AI on Yocto")
    _cx_text(d, strip_y + 12, bot, f_bot, DIM)


# ── Compose ──────────────────────────────────────────────────────────────────
def build() -> Image.Image:
    bg  = Image.fromarray(_gradient_bg(), "RGB").convert("RGBA")
    bg.alpha_composite(_neural_layer())

    chip_cx = W // 2
    chip_cy = H // 2 - 200
    bg.alpha_composite(_chip_layer(chip_cx, chip_cy))

    d = ImageDraw.Draw(bg)
    _corner_traces(d)
    _text_and_chrome(d)

    return bg.convert("RGB")


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", action="store_true",
                    help="Open result in image viewer after generation")
    ap.add_argument("--out-dir", default=None,
                    help="Write outputs here instead of the in-tree paths")
    args = ap.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    if args.out_dir:
        out = Path(args.out_dir)
        png_path = out / "psplash-edge-img.png"
        bmp_path = out / "splash.bmp"
    else:
        png_path = (repo_root /
            "meta-edge-distro/recipes-core/psplash/files/psplash-edge-img.png")
        bmp_path = (repo_root /
            "meta-edge-bsp/recipes-bsp/splash-assets/files/splash.bmp")

    print("Generating EDGE AI OS splash …")
    img = build()

    img.save(str(png_path), "PNG")
    print(f"  PNG  →  {png_path}")

    # PIL emits BMP3 (24-bit) for RGB — U-Boot bmp driver compatible
    img.save(str(bmp_path), "BMP")
    print(f"  BMP  →  {bmp_path}")

    if args.preview:
        img.show()

    print("Done.")


if __name__ == "__main__":
    main()
