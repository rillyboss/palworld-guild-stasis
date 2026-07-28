"""Generate every image the mod page needs, at the sizes Nexus asks for.

Outputs:
  thumbnail.png        512x512    square tile, used by the first-party loader
  header.png          1300x372    Nexus "Header", the banner atop the mod page
  gallery-1-problem.png     1920x1080
  gallery-2-what.png        1920x1080
  gallery-3-requirements.png 1920x1080

Design intent. The audience is server admins, not players, so gameplay screenshots would
say less than plain information. Each gallery image answers one question a prospective
installer actually has: what problem does this solve, what does it do, and can I even run
it. The last one exists because the biggest support problem for a server-side mod is
people installing it client-side.

Reproducible on purpose: art that only exists as a binary is art nobody can edit.
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1] if len(sys.argv) > 1 else "."

BG_TOP = (16, 22, 34)
BG_BOT = (28, 40, 58)
ACCENT = (94, 200, 168)
TEXT = (238, 244, 250)
MUTED = (140, 158, 178)
DIM = (104, 120, 138)
WARN = (240, 176, 96)

FONT_DIRS = [r"C:\Windows\Fonts", "/usr/share/fonts/truetype/dejavu"]
BOLD = ["segoeuib.ttf", "arialbd.ttf", "calibrib.ttf", "DejaVuSans-Bold.ttf"]
REG = ["segoeui.ttf", "arial.ttf", "calibri.ttf", "DejaVuSans.ttf"]
MONO = ["consola.ttf", "cour.ttf", "DejaVuSansMono.ttf"]


def font(names, size):
    for name in names:
        for d in FONT_DIRS:
            p = os.path.join(d, name)
            if os.path.exists(p):
                try:
                    return ImageFont.truetype(p, size)
                except OSError:
                    pass
    return ImageFont.load_default()


def gradient(w, h):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOT)))
    return img


def centre_x(d, y, text, f, fill, w):
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text(((w - (r - l)) / 2 - l, y), text, font=f, fill=fill)


def zzz(d, x, baseline, scale, colour):
    """Zs grow as they rise. Sleeping Pals is literally what suppression looks like."""
    for dx, dy, size, alpha in [(0.00, 0.00, 0.52, 0.55),
                                (0.40, -0.34, 0.74, 0.78),
                                (0.92, -0.78, 1.00, 1.00)]:
        f = font(BOLD, max(10, int(scale * size)))
        d.text((x + dx * scale, baseline + dy * scale), "Z", font=f,
               fill=tuple(int(c * alpha) for c in colour))


def wordmark(d, x, y, small, big, muted=MUTED):
    d.text((x, y), "GUILD", font=font(REG, small), fill=muted)
    d.text((x, y + int(small * 0.95)), "STASIS", font=font(BOLD, big), fill=TEXT)


# ---------------------------------------------------------------- square tile
def thumbnail(path):
    W = H = 512
    img = gradient(W, H)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 6], fill=ACCENT)
    centre_x(d, 92, "GUILD", font(REG, 54), MUTED, W)
    centre_x(d, 150, "STASIS", font(BOLD, 108), TEXT, W)
    d.rectangle([196, 286, 316, 289], fill=ACCENT)
    zzz(d, 196, 372, 78, ACCENT)
    centre_x(d, 436, "SERVER-SIDE MOD", font(BOLD, 30), ACCENT, W)
    centre_x(d, 468, "PALWORLD DEDICATED SERVER", font(REG, 23), MUTED, W)
    img.save(path)
    return path


# ------------------------------------------------------- Nexus header 1300x372
def header(path):
    W, H = 1300, 372
    img = gradient(W, H)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 5], fill=ACCENT)

    # Squat aspect, so the wordmark goes left and the art right, nothing stacked.
    # No divider rule here: at 372px tall the descenders of STASIS reach far enough
    # down that a rule under it reads as a strikethrough.
    wordmark(d, 72, 44, 34, 96)
    d.text((74, 208), "Offline guilds stop starving, losing SAN, and producing.",
           font=font(REG, 30), fill=MUTED)
    d.rectangle([76, 268, 268, 271], fill=ACCENT)
    d.text((74, 296), "SERVER-SIDE   ·   WINDOWS DEDICATED   ·   REQUIRES UE4SS",
           font=font(BOLD, 22), fill=ACCENT)

    zzz(d, 1010, 250, 120, ACCENT)
    img.save(path)
    return path


# ------------------------------------------------------------- gallery helpers
def card(title, kicker=None):
    W, H = 1920, 1080
    img = gradient(W, H)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 8], fill=ACCENT)
    d.text((120, 92), title, font=font(BOLD, 84), fill=TEXT)
    d.rectangle([124, 208, 460, 212], fill=ACCENT)
    if kicker:
        d.text((122, 238), kicker, font=font(REG, 38), fill=DIM)
    # Small wordmark bottom-right so each image is attributable on its own.
    d.text((1560, 990), "GUILD STASIS", font=font(BOLD, 28), fill=DIM)
    return img, d


def gallery_problem(path):
    img, d = card("THE PROBLEM", "Palworld only simulates the world while someone is connected.")
    y = 340
    for line, col, f in [
        ("That someone is often not you.", TEXT, font(BOLD, 52)),
        ("", MUTED, font(REG, 20)),
        ("Another guild logs in and grinds for four hours, or just sits AFK.", MUTED, font(REG, 40)),
        ("Your base is running the whole time.", MUTED, font(REG, 40)),
        ("", MUTED, font(REG, 20)),
        ("Your Pals keep working  →  empty the feed box  →  starve  →  sicken  →  die.", WARN, font(REG, 40)),
        ("", MUTED, font(REG, 24)),
        ("You log in to a wreck and spend the session mending, not playing.", TEXT, font(BOLD, 44)),
        ("", MUTED, font(REG, 20)),
        ("No server setting fixes this. PalStomachDecreaceRate is global, so", DIM, font(REG, 34)),
        ("turning it down helps the AFK player as much as it helps you.", DIM, font(REG, 34)),
    ]:
        if line:
            d.text((122, y), line, font=f, fill=col)
        y += f.size + 16
    img.save(path)
    return path


def gallery_what(path):
    img, d = card("WHILE EVERY MEMBER IS OFFLINE", "Per guild. Every other guild carries on as normal.")
    y = 360
    for label, value in [("HUNGER", "frozen"),
                         ("SAN", "frozen"),
                         ("WORK SPEED", "zero")]:
        d.text((122, y), label, font=font(REG, 46), fill=MUTED)
        d.text((640, y - 6), value, font=font(BOLD, 60), fill=ACCENT)
        y += 108

    d.rectangle([124, y + 10, 1100, y + 13], fill=(52, 66, 84))
    y += 52
    for line, f, col in [
        ("Work speed hits zero across all thirteen suitabilities: kindling, watering,", MUTED, 0),
        ("planting, electricity, handiwork, gathering, lumbering, mining, oil,", MUTED, 0),
        ("medicine, cooling, hauling and farming. No output. No XP.", MUTED, 0),
    ]:
        d.text((122, y), line, font=font(REG, 34), fill=MUTED)
        y += 46

    y += 34
    d.text((122, y), "Nothing is written to the save file.", font=font(BOLD, 42), fill=TEXT)
    d.text((122, y + 58),
           "All of it reverses on login. Uninstalling leaves no trace.",
           font=font(REG, 34), fill=DIM)
    img.save(path)
    return path


def gallery_requirements(path):
    img, d = card("BEFORE YOU INSTALL", "This is the part people skip, then wonder why nothing happened.")
    y = 350
    d.text((122, y), "SERVER-SIDE ONLY.  Not a client mod.", font=font(BOLD, 56), fill=WARN)
    y += 104
    d.text((122, y), "It installs on a Palworld dedicated server. Players install nothing.",
           font=font(REG, 36), fill=MUTED)
    y += 96

    for line in [
        "Windows dedicated build.  Wine-hosted Windows is fine. Linux cannot run it.",
        "Write access to  Pal/Binaries/Win64  and the ability to restart.",
        "UE4SS installed first. This is a Lua mod and does nothing without it.",
        "No launch arguments. No client-side files.",
    ]:
        d.rectangle([124, y + 18, 140, y + 34], fill=ACCENT)
        d.text((168, y), line, font=font(REG, 36), fill=MUTED)
        y += 68

    y += 30
    d.text((122, y), "Quick test:  list  Pal/Binaries/Win64  over FTP.",
           font=font(REG, 34), fill=DIM)
    d.text((122, y + 48), "If you cannot see it, your host cannot run this mod.",
           font=font(BOLD, 34), fill=TEXT)
    img.save(path)
    return path


for fn, name in [(thumbnail, "thumbnail.png"),
                 (header, "header.png"),
                 (gallery_problem, "gallery-1-problem.png"),
                 (gallery_what, "gallery-2-what.png"),
                 (gallery_requirements, "gallery-3-requirements.png")]:
    p = fn(os.path.join(OUT, name))
    im = Image.open(p)
    print(f"{name:30} {im.size[0]}x{im.size[1]}  {os.path.getsize(p):,} bytes")
