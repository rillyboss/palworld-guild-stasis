"""Generate the mod thumbnail.

Design intent: it has to be legible as a small tile in a mod-site list, and it has to
say "server-side" at a glance, because the single biggest support problem for this mod
is people installing it client-side. So the words carry the work, not the artwork.

Two outputs:
  thumbnail.png  512x512, the square tile the first-party loader and mod sites use
  banner.png     1280x720, for a mod page header
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "."

BG_TOP = (16, 22, 34)
BG_BOT = (28, 40, 58)
ACCENT = (94, 200, 168)
TEXT = (238, 244, 250)
MUTED = (140, 158, 178)

FONT_DIRS = [r"C:\Windows\Fonts"]


def font(names, size):
    """First available font, falling back to PIL's default rather than crashing."""
    for name in names:
        for d in FONT_DIRS:
            p = os.path.join(d, name)
            if os.path.exists(p):
                try:
                    return ImageFont.truetype(p, size)
                except OSError:
                    pass
    return ImageFont.load_default()


BOLD = ["segoeuib.ttf", "arialbd.ttf", "calibrib.ttf"]
REG = ["segoeui.ttf", "arial.ttf", "calibri.ttf"]


def gradient(w, h):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line(
            [(0, y), (w, y)],
            fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOT)),
        )
    return img


def centre(d, box, text, f, fill):
    x0, y0, x1, y1 = box
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text((x0 + (x1 - x0 - (r - l)) / 2 - l, y0 + (y1 - y0 - (b - t)) / 2 - t),
           text, font=f, fill=fill)


def zzz(d, x, baseline, scale, colour):
    """Sleeping Pals, which is what suppression actually looks like in game.

    Zs grow as they rise, which is the conventional reading. Drawn from an explicit
    baseline so the group can be cleared of the divider above it rather than
    colliding with it, which the first attempt did.
    """
    steps = [(0.00, 0.00, 0.52, 0.55), (0.40, -0.34, 0.74, 0.78), (0.92, -0.78, 1.00, 1.00)]
    for dx, dy, size, alpha in steps:
        f = font(BOLD, max(10, int(scale * size)))
        d.text((x + dx * scale, baseline + dy * scale), "Z", font=f,
               fill=tuple(int(c * alpha) for c in colour))


def square(path):
    W = H = 512
    img = gradient(W, H)
    d = ImageDraw.Draw(img)

    # Accent rule under the wordmark.
    d.rectangle([0, 0, W, 6], fill=ACCENT)

    centre(d, (0, 92, W, 168), "GUILD", font(REG, 54), MUTED)
    centre(d, (0, 150, W, 268), "STASIS", font(BOLD, 108), TEXT)

    d.rectangle([196, 286, 316, 289], fill=ACCENT)

    # Baseline sits well below the divider so the tallest Z has clearance.
    zzz(d, 196, 372, 78, ACCENT)

    centre(d, (0, 436, W, 470), "SERVER-SIDE MOD", font(BOLD, 30), ACCENT)
    centre(d, (0, 468, W, 500), "PALWORLD DEDICATED SERVER", font(REG, 23), MUTED)

    img.save(path)
    return path


def banner(path):
    W, H = 1280, 720
    img = gradient(W, H)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 8], fill=ACCENT)

    d.text((96, 214), "GUILD", font=font(REG, 62), fill=MUTED)
    d.text((96, 268), "STASIS", font=font(BOLD, 150), fill=TEXT)
    d.rectangle([100, 452, 420, 456], fill=ACCENT)

    lines = [
        "Offline guilds stop starving, stop losing SAN,",
        "and stop producing. Every other guild untouched.",
    ]
    y = 486
    for ln in lines:
        d.text((98, y), ln, font=font(REG, 34), fill=MUTED)
        y += 46

    d.text((98, 606), "SERVER-SIDE  ·  WINDOWS DEDICATED  ·  REQUIRES UE4SS",
           font=font(BOLD, 26), fill=ACCENT)

    zzz(d, 940, 430, 140, ACCENT)

    img.save(path)
    return path


for p in (square(os.path.join(OUT_DIR, "thumbnail.png")),
          banner(os.path.join(OUT_DIR, "banner.png"))):
    im = Image.open(p)
    print(f"{os.path.basename(p):16} {im.size[0]}x{im.size[1]}  {os.path.getsize(p):,} bytes")
