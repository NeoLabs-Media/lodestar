#!/usr/bin/env python3
"""Draws the Lodestar icon (guiding star + hidden gem) and writes the macOS/iOS icon sets."""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 2048  # supersampled canvas


def gradient(size, c1, c2):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size - 2)
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return img


def astroid(cx, cy, r, n=400, power=2.6):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        c, s = math.cos(a), math.sin(a)
        pts.append((cx + r * math.copysign(abs(c) ** power, c), cy + r * math.copysign(abs(s) ** power, s)))
    return pts


def master(full_bleed):
    bg = gradient(S, (38, 36, 31), (13, 13, 12))
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse((S * .1, S * .02, S * .75, S * .67), fill=0)
    glow = glow.filter(ImageFilter.GaussianBlur(S * .12))
    bg = Image.composite(Image.new("RGB", (S, S), (60, 55, 40)), bg, glow)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # guiding star
    cx, cy = S * .45, S * .45
    d.polygon(astroid(cx + S * .012, cy + S * .02, S * .34), fill=(0, 0, 0, 110))  # soft shadow
    d.polygon(astroid(cx, cy, S * .34), fill=(227, 182, 91, 255))
    d.polygon(astroid(cx, cy, S * .15, power=2.6), fill=(250, 226, 160, 255))
    # hidden gem
    gx, gy, gr = S * .70, S * .71, S * .17
    top, bot = (gx, gy - gr), (gx, gy + gr * 1.05)
    left, right = (gx - gr * 1.0, gy - gr * .15), (gx + gr * 1.0, gy - gr * .15)
    d.polygon([top, right, bot, left], fill=(158, 216, 181, 255))
    d.polygon([top, right, (gx, gy - gr * .15)], fill=(205, 240, 220, 255))
    d.polygon([top, left, (gx, gy - gr * .15)], fill=(180, 228, 198, 255))
    d.polygon([left, right, bot], fill=(98, 160, 126, 255))
    d.polygon([(gx, gy - gr * .15), right, bot], fill=(118, 180, 144, 255))
    d.line([top, right, bot, left, top], fill=(255, 255, 255, 200), width=int(S * .006), joint="curve")
    # tiny sparkles
    for (sx, sy, sr) in [(S * .80, S * .24, S * .05), (S * .21, S * .76, S * .035)]:
        d.polygon(astroid(sx, sy, sr, power=2.6), fill=(236, 231, 220, 230))
    img = bg.convert("RGBA")
    img.alpha_composite(layer)
    if full_bleed:
        return img
    # macOS: rounded square inset like Apple's template (824/1024)
    inset = int(S * 100 / 1024)
    size = S - 2 * inset
    tile = img.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * .2237), fill=255)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sd).rounded_rectangle((inset, inset + S * .012, inset + size, inset + size + S * .012), radius=int(size * .2237), fill=110)
    shadow.putalpha(sd.filter(ImageFilter.GaussianBlur(S * .01)))
    out = shadow
    out.alpha_composite(Image.merge("RGBA", (*tile.split()[:3], mask)).convert("RGBA").transform((S, S), Image.AFFINE, (1, 0, -inset, 0, 1, -inset)))
    return out


def save(img, path, px):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.resize((px, px), Image.LANCZOS).save(path)


mac = master(False)
ios = master(True).convert("RGB")
mac_dir = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
for px in (16, 32, 64, 128, 256, 512, 1024):
    save(mac, mac_dir / f"app_icon_{px}.png", px)
ios_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
for f in ios_dir.glob("Icon-App-*.png"):
    w = int(f.stem.split("-")[2].split("x")[0].split(".")[0]) if False else None
import json
for e in json.loads((ios_dir / "Contents.json").read_text())["images"]:
    size = float(e["size"].split("x")[0]) * int(e["scale"].rstrip("x"))
    save(ios, ios_dir / e["filename"], int(round(size)))
save(mac, ROOT / "assets/icon_preview.png", 512)
web = ROOT / "web"
if web.exists():
    for px, name in ((192, "icons/Icon-192.png"), (512, "icons/Icon-512.png")):
        save(mac, web / name, px)
    for px, name in ((192, "icons/Icon-maskable-192.png"), (512, "icons/Icon-maskable-512.png")):
        save(ios.convert("RGBA"), web / name, px)
    save(mac, web / "favicon.png", 48)
print("icons written")
