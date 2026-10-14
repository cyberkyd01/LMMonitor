#!/usr/bin/env python3
"""Render the LM Monitor app icon and write the macOS AppIcon.iconset."""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 2  # supersample factor for smooth edges
W = S * SS
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "AppIcon.iconset")

BG = (0x1E, 0x1E, 0x2E, 255)
TEAL = (0x2D, 0xD4, 0xBF)
PURPLE = (0xA8, 0x55, 0xF7)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def render():
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # Rounded-square background (macOS-style margin ~ 100px at 1024).
    m = int(100 * SS)
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [m, m, W - m, W - m], radius=int(185 * SS), fill=255)
    bg = Image.new("RGBA", (W, W), BG)
    # subtle vertical lightening
    grad = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(m, W - m):
        t = (y - m) / (W - 2 * m)
        a = int(28 * (1 - t))
        gd.line([(m, y), (W - m, y)], fill=(255, 255, 255, a))
    bg = Image.alpha_composite(bg, grad)
    img.paste(bg, (0, 0), mask)

    cx, cy = W // 2, int(W * 0.56)
    R = int(300 * SS)
    thick = int(58 * SS)
    start, end = 150, 390  # degrees, clockwise from +x (PIL convention)

    # Gradient arc: draw the arc as many short segments, colored teal->purple.
    arc = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arc)
    steps = 240
    bbox = [cx - R, cy - R, cx + R, cy + R]
    for i in range(steps):
        a0 = start + (end - start) * i / steps
        a1 = start + (end - start) * (i + 1) / steps + 0.6
        ad.arc(bbox, a0, a1, fill=lerp(TEAL, PURPLE, i / (steps - 1)) + (255,),
               width=thick)
    # Round caps
    for ang, col in ((start, TEAL), (end, PURPLE)):
        r = math.radians(ang)
        px = cx + (R - thick / 2) * math.cos(r)
        py = cy + (R - thick / 2) * math.sin(r)
        ad.ellipse([px - thick / 2, py - thick / 2, px + thick / 2, py + thick / 2],
                   fill=col + (255,))
    # soft glow behind the arc
    glow = arc.filter(ImageFilter.GaussianBlur(26 * SS))
    glow.putalpha(glow.getchannel("A").point(lambda v: int(v * 0.45)))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, arc)

    d = ImageDraw.Draw(img)

    # Tick marks inside the arc
    for i in range(9):
        ang = math.radians(start + (end - start) * i / 8)
        r0, r1 = R - thick - 26 * SS, R - thick - (60 if i % 4 == 0 else 44) * SS
        d.line([(cx + r0 * math.cos(ang), cy + r0 * math.sin(ang)),
                (cx + r1 * math.cos(ang), cy + r1 * math.sin(ang))],
               fill=(205, 214, 244, 150), width=int(7 * SS))

    # Needle pointing to ~ 70% of the sweep
    na = math.radians(start + (end - start) * 0.72)
    nl = R - thick - 40 * SS
    tip = (cx + nl * math.cos(na), cy + nl * math.sin(na))
    px, py = -math.sin(na), math.cos(na)
    bw = 20 * SS
    needle = [tip, (cx + px * bw, cy + py * bw), (cx - px * bw, cy - py * bw)]
    d.polygon(needle, fill=(243, 244, 255, 255))
    hub = 40 * SS
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=(243, 244, 255, 255))
    d.ellipse([cx - hub // 2, cy - hub // 2, cx + hub // 2, cy + hub // 2], fill=BG)

    # Lightning/spark accent, upper right inside the dial region
    sx, sy, sc = int(W * 0.5), int(W * 0.40), 1.0 * SS
    bolt = [(14, -62), (-26, 6), (-2, 6), (-14, 60), (28, -10), (4, -10)]
    pts = [(sx + x * sc * 1.0, sy + y * sc * 1.0) for x, y in bolt]
    # shift the bolt to sit above the hub, between needle and arc center
    pts = [(x - 0 * SS, y) for x, y in pts]
    spark = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spark)
    sd.polygon(pts, fill=(253, 224, 71, 255))
    sg = spark.filter(ImageFilter.GaussianBlur(14 * SS))
    img = Image.alpha_composite(img, sg)
    img = Image.alpha_composite(img, spark)

    # Small four-point sparkle, top right
    qx, qy, qr = int(W * 0.74), int(W * 0.27), 34 * SS
    star = []
    for k in range(8):
        a = math.pi / 4 * k - math.pi / 2
        r = qr if k % 2 == 0 else qr * 0.28
        star.append((qx + r * math.cos(a), qy + r * math.sin(a)))
    ImageDraw.Draw(img).polygon(star, fill=(253, 224, 71, 255))

    return img.resize((S, S), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()
    master.save(os.path.join(HERE, "icon_1024.png"))
    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        im = master if px == S else master.resize((px, px), Image.LANCZOS)
        im.save(os.path.join(OUT, name))
    print("wrote", len(sizes), "files to", OUT)


if __name__ == "__main__":
    main()
