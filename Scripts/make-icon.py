#!/usr/bin/env python3
"""Draws the app icon (Resources/AppIcon.png and Resources/AppIcon.icns).

A white circular emblem with a sound wave inside, loosely based on the
OpenVox AI logo, on a macOS-style rounded square. Needs Pillow.
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling factor
SIZE = 1024 * S
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def background():
    # macOS icon grid: 824 pt rounded square centred on a 1024 canvas.
    inset, side, radius = 100 * S, 824 * S, 185 * S
    top, bottom = (66, 92, 214), (20, 22, 66)
    grad = Image.new("RGBA", (SIZE, SIZE))
    gd = ImageDraw.Draw(grad)
    for y in range(SIZE):
        t = min(1, max(0, (y - inset) / side))
        gd.line([(0, y), (SIZE, y)], fill=lerp(top, bottom, t) + (255,))
    # Soft glow behind the emblem.
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([312 * S, 280 * S, 712 * S, 680 * S], fill=(120, 200, 255, 90))
    grad.alpha_composite(glow.filter(ImageFilter.GaussianBlur(90 * S)))

    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, inset + side, inset + side], radius, fill=255)
    shape = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shape.paste(grad, mask=mask)

    # Drop shadow under the tile, like system icons.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [inset, inset + 12 * S, inset + side, inset + side + 12 * S], radius, fill=(0, 0, 0, 110))
    out = shadow.filter(ImageFilter.GaussianBlur(14 * S))
    out.alpha_composite(shape)
    return out


def emblem():
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx = cy = SIZE / 2
    R = 285 * S          # emblem radius
    w = 30 * S           # stroke width
    r = R * 0.17         # hook radius
    white = (255, 255, 255, 255)

    def arc(center, radius, start, end):
        x, y = center
        box = [x - radius - w / 2, y - radius - w / 2, x + radius + w / 2, y + radius + w / 2]
        d.arc(box, start, end, fill=white, width=w)

    def cap(angle_deg, center, radius):
        a = math.radians(angle_deg)
        x, y = center[0] + radius * math.cos(a), center[1] + radius * math.sin(a)
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=white)

    # Upper half: arc over the top from the left to the right, then a hook
    # curling down toward the centre. (PIL angles run clockwise from 3 o'clock.)
    end = 354
    start = end - 180  # meets the start of the lower half's hook
    arc((cx, cy), R, start, end)
    hc = (cx + (R - r) * math.cos(math.radians(end)), cy + (R - r) * math.sin(math.radians(end)))
    arc(hc, r, end, end + 180)
    cap(end + 180, hc, r)

    # The lower half is the same shape turned 180 degrees.
    layer.alpha_composite(layer.rotate(180, resample=Image.BICUBIC))
    d = ImageDraw.Draw(layer)

    # Sound wave bars.
    bar_w = 30 * S
    gap = 60 * S
    heights = [0.36, 0.74, 1.04, 0.74, 0.36]
    for i, h in enumerate(heights):
        x = cx + (i - 2) * gap
        half = R * h / 2
        d.rounded_rectangle([x - bar_w / 2, cy - half, x + bar_w / 2, cy + half], bar_w / 2, fill=white)

    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((10, 10, 40, 120), mask=layer.split()[3])
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -8 * S)).filter(ImageFilter.GaussianBlur(10 * S))
    shadow.alpha_composite(layer)
    return shadow


def main():
    icon = background()
    icon.alpha_composite(emblem())
    icon = icon.resize((1024, 1024), Image.LANCZOS)
    os.makedirs(OUT, exist_ok=True)
    icon.save(os.path.join(OUT, "AppIcon.png"))
    icon.save(os.path.join(OUT, "AppIcon.icns"),
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])


if __name__ == "__main__":
    main()
