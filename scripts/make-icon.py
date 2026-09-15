#!/usr/bin/env python3
"""Draws the app icon and writes Resources/AppIcon.iconset, AppIcon.icns and a preview.

Run it only when the artwork changes; the generated files are committed, so building
the app needs neither Python nor Pillow.

Two forms of the icon are written. The .iconset folder is what macOS's own iconutil
turns into an .icns at build time, which is the form Finder is guaranteed to read. The
.icns here is written by hand as a fallback for building without iconutil.

    python3 -m pip install Pillow
    python3 scripts/make-icon.py

The artwork: a photo card inside a ring of sync arrows, on the rounded square macOS
uses for app icons. Everything is laid out in a 1024-unit square and rendered at four
times the target size, then downsampled, which is what gives the edges their
antialiasing. Sizes of 32 points and below get a simplified drawing, without the ring
and with a larger card, because the ring turns to mush at 16 pixels.
"""

from __future__ import annotations

import math
import pathlib
import struct

from PIL import Image, ImageDraw, ImageFilter

# --- palette -------------------------------------------------------------------------

GRADIENT_TOP = (86, 170, 255)      # azure
GRADIENT_BOTTOM = (46, 62, 190)    # indigo
CARD = (255, 255, 255)
SKY = (233, 242, 255)
MOUNTAIN_BACK = (111, 168, 245)
MOUNTAIN_FRONT = (47, 98, 207)
SUN = (255, 194, 77)
RING = (255, 255, 255, 240)

# --- geometry, in a 1024-unit square ------------------------------------------------

CANVAS = 1024.0
SQUIRCLE_INSET = 100.0             # macOS leaves the art 824 of 1024 wide
SQUIRCLE_INSET_SMALL = 78.0        # small sizes keep less margin so they stay readable
SUPERSAMPLE = 4

ROOT = pathlib.Path(__file__).resolve().parent.parent


def superellipse(cx, cy, half, exponent=5.0, steps=720):
    """The rounded square macOS uses, which is a superellipse rather than a rounded rect."""
    points = []
    for step in range(steps):
        angle = 2 * math.pi * step / steps
        cos_a, sin_a = math.cos(angle), math.sin(angle)
        x = math.copysign(abs(cos_a) ** (2 / exponent), cos_a)
        y = math.copysign(abs(sin_a) ** (2 / exponent), sin_a)
        points.append((cx + half * x, cy + half * y))
    return points


def vertical_gradient(size, top, bottom):
    image = Image.new("RGB", (1, size))
    pixels = image.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        pixels[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return image.resize((size, size), Image.BICUBIC)


def radial_highlight(size, cx, cy, radius, strength):
    """A soft light from above, so the face is not flat."""
    small = 256
    mask = Image.new("L", (small, small))
    pixels = mask.load()
    scale = small / size
    for y in range(small):
        for x in range(small):
            dx = (x / scale - cx) / radius
            dy = (y / scale - cy) / radius
            d = math.hypot(dx, dy)
            value = max(0.0, 1.0 - d) ** 2
            pixels[x, y] = int(255 * value * strength)
    return mask.resize((size, size), Image.BICUBIC)


def arrow_ring(draw, size, center, radius, stroke):
    """Two arcs with arrowheads: the sync symbol, drawn by hand so the heads line up."""
    box = [center - radius, center - radius, center + radius, center + radius]
    for start, end in ((28, 158), (208, 338)):
        draw.arc(box, start=start, end=end, fill=RING, width=int(round(stroke)))

    for end_degrees in (158, 338):
        theta = math.radians(end_degrees)
        tip_theta = theta + 0.30
        tip = (center + radius * math.cos(tip_theta), center + radius * math.sin(tip_theta))
        outer = radius + stroke * 1.05
        inner = radius - stroke * 1.05
        base_outer = (center + outer * math.cos(theta), center + outer * math.sin(theta))
        base_inner = (center + inner * math.cos(theta), center + inner * math.sin(theta))
        draw.polygon([tip, base_outer, base_inner], fill=RING)


def photo_card(size, center, width, height, corner):
    """The card is drawn on its own layer so the picture inside can be clipped to it."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    left, top = center - width / 2, center - height / 2
    right, bottom = center + width / 2, center + height / 2
    draw.rounded_rectangle([left, top, right, bottom], radius=corner, fill=CARD)

    # The picture: sky, a sun, and two ridges, clipped to the inner rounded rectangle.
    inset = height * 0.09
    inner = [left + inset, top + inset, right - inset, bottom - inset]
    inner_w = inner[2] - inner[0]
    inner_h = inner[3] - inner[1]
    inner_corner = max(corner - inset * 0.75, 4)

    picture = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    picture_draw = ImageDraw.Draw(picture)
    picture_draw.rectangle(inner, fill=SKY)

    sun_r = inner_h * 0.17
    sun_c = (inner[0] + inner_w * 0.27, inner[1] + inner_h * 0.30)
    picture_draw.ellipse([sun_c[0] - sun_r, sun_c[1] - sun_r, sun_c[0] + sun_r, sun_c[1] + sun_r], fill=SUN)

    base = inner[3]
    picture_draw.polygon([
        (inner[0] + inner_w * 0.34, base),
        (inner[0] + inner_w * 0.70, inner[1] + inner_h * 0.34),
        (inner[2], base),
    ], fill=MOUNTAIN_BACK)
    picture_draw.polygon([
        (inner[0], base),
        (inner[0] + inner_w * 0.36, inner[1] + inner_h * 0.48),
        (inner[0] + inner_w * 0.78, base),
    ], fill=MOUNTAIN_FRONT)

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(inner, radius=inner_corner, fill=255)
    layer.paste(picture, (0, 0), mask)
    return layer


def render(size, simplified):
    """Draws the icon at `size` pixels, supersampled."""
    work = size * SUPERSAMPLE
    scale = work / CANVAS

    def u(value):  # 1024-unit value to pixels
        return value * scale

    image = Image.new("RGBA", (work, work), (0, 0, 0, 0))

    # Small icons give up less room to the margin and the shadow, or they turn to a
    # blur in a Finder list.
    inset = SQUIRCLE_INSET_SMALL if simplified else SQUIRCLE_INSET
    shadow_blur, shadow_alpha, shadow_drop = (14, 0.22, 9) if simplified else (22, 0.30, 14)

    # The rounded square, as a mask, so the gradient and highlight fill it exactly.
    half = (CANVAS - 2 * inset) / 2
    shape = [(u(x), u(y)) for x, y in superellipse(CANVAS / 2, CANVAS / 2, half)]
    shape_mask = Image.new("L", (work, work), 0)
    ImageDraw.Draw(shape_mask).polygon(shape, fill=255)

    # A soft shadow under the art, the way macOS icons carry one.
    shadow = shape_mask.filter(ImageFilter.GaussianBlur(u(shadow_blur)))
    shadow_layer = Image.new("RGBA", (work, work), (12, 20, 60, 0))
    shadow_layer.putalpha(shadow.point(lambda v: int(v * shadow_alpha)))
    image.alpha_composite(shadow_layer, (0, int(u(shadow_drop))))

    face = vertical_gradient(work, GRADIENT_TOP, GRADIENT_BOTTOM).convert("RGBA")
    highlight = Image.new("RGBA", (work, work), (255, 255, 255, 255))
    highlight.putalpha(radial_highlight(work, u(360), u(210), u(620), 0.42))
    face.alpha_composite(highlight)
    image.paste(face, (0, 0), shape_mask)

    overlay = Image.new("RGBA", (work, work), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    center = u(CANVAS / 2)

    if simplified:
        card = photo_card(work, center, u(568), u(466), u(62))
    else:
        arrow_ring(draw, work, center, u(300), u(52))
        card = photo_card(work, center, u(356), u(292), u(40))
    overlay.alpha_composite(card)

    image.alpha_composite(overlay)
    return image.resize((size, size), Image.LANCZOS)


# --- icns ----------------------------------------------------------------------------

# Pixel size, the name iconutil expects in an .iconset, the icns element type, and whether
# the size uses the simplified art. Each pair of rows is one logical size at 1x and 2x, so a
# size never changes design when the screen does.
ENTRIES = [
    (16, "icon_16x16.png", b"icp4", True),
    (32, "icon_16x16@2x.png", b"ic11", True),
    (32, "icon_32x32.png", b"icp5", True),
    (64, "icon_32x32@2x.png", b"ic12", True),
    (128, "icon_128x128.png", b"ic07", False),
    (256, "icon_128x128@2x.png", b"ic13", False),
    (256, "icon_256x256.png", b"ic08", False),
    (512, "icon_256x256@2x.png", b"ic14", False),
    (512, "icon_512x512.png", b"ic09", False),
    (1024, "icon_512x512@2x.png", b"ic10", False),
]


def write_icns(path, elements):
    """Writes an icns container: a table of contents, then a typed element per image.

    Each element is a four-byte type, a length that counts its own eight-byte header, and the
    PNG bytes. The leading `TOC ` repeats every type and length, which is what iconutil emits
    and what a strict reader looks for first.
    """
    def element(type_code, data):
        return type_code + struct.pack(">I", len(data) + 8) + data

    toc_data = b"".join(type_code + struct.pack(">I", len(data) + 8) for type_code, data in elements)
    body = element(b"TOC ", toc_data) + b"".join(element(t, d) for t, d in elements)
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main():
    import io
    import shutil

    iconset = ROOT / "Resources" / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

    rendered = {}
    elements = []
    for size, iconset_name, type_code, simplified in ENTRIES:
        key = (size, simplified)
        if key not in rendered:
            rendered[key] = render(size, simplified)
            print(f"  drew {size}px{' (simplified)' if simplified else ''}")
        buffer = io.BytesIO()
        rendered[key].save(buffer, format="PNG", optimize=True)
        png = buffer.getvalue()
        (iconset / iconset_name).write_bytes(png)
        elements.append((type_code, png))
    print(f"wrote {iconset.relative_to(ROOT)}/ ({len(ENTRIES)} images)")

    icns = ROOT / "Resources" / "AppIcon.icns"
    write_icns(icns, elements)
    print(f"wrote {icns.relative_to(ROOT)} ({icns.stat().st_size // 1024} KB)")

    preview = ROOT / "docs" / "app-icon.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    rendered[(1024, False)].resize((512, 512), Image.LANCZOS).save(preview, optimize=True)
    print(f"wrote {preview.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
