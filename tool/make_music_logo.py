"""Musik's tile in the parts' style (see make_home_system_logo.py, whose
helpers it uses): two beamed notes as a lime-to-green ribbon on the dark
tile, with a small sound wave as the accent.

    python tool/make_music_logo.py

Writes assets/icon/music_logo.png (512 px). Needs Pillow.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_home_system_logo import ROOT, gradient, rounded_mask, tile_background  # noqa: E402


def music_logo(size: int) -> Image.Image:
    s = 4
    n = size * s
    k = n / 1000
    shape = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(shape)

    def head(cx: float, cy: float):
        # A note head: a tilted ellipse.
        h = Image.new('L', (n, n), 0)
        ImageDraw.Draw(h).ellipse(((cx - 105) * k, (cy - 75) * k, (cx + 105) * k, (cy + 75) * k), fill=255)
        return h.rotate(22, center=(cx * k, cy * k), resample=Image.BICUBIC)

    left, right = (255, 720), (600, 640)
    stem = 64
    shape = ImageChops.lighter(shape, head(*left))
    shape = ImageChops.lighter(shape, head(*right))
    d = ImageDraw.Draw(shape)
    # Stems on the heads' right side, up to the beam.
    lx = left[0] + 105 - stem
    rx = right[0] + 105 - stem
    d.rounded_rectangle((lx * k, 260 * k, (lx + stem) * k, (left[1] - 10) * k), radius=20 * k, fill=255)
    d.rounded_rectangle((rx * k, 180 * k, (rx + stem) * k, (right[1] - 10) * k), radius=20 * k, fill=255)
    # The beam: a slanted bar over both stems.
    d.polygon([(lx * k, 230 * k), ((rx + stem) * k, 150 * k), ((rx + stem) * k, 270 * k), (lx * k, 350 * k)],
              fill=255)

    # The accent: a second, thinner beam (sixteenths) and a sound wave.
    accent = Image.new('L', (n, n), 0)
    ad = ImageDraw.Draw(accent)
    ad.polygon([(lx * k, 400 * k), ((rx + stem) * k, 320 * k), ((rx + stem) * k, 375 * k), (lx * k, 455 * k)],
               fill=255)
    for r, w in ((95, 34), (170, 34)):
        ad.arc(((705 - r) * k, (420 - r) * k, (705 + r) * k, (420 + r) * k), start=-40, end=40, fill=255,
               width=round(w * k))
    # Keep the waves off the notes.
    accent = ImageChops.subtract(accent, shape.filter(ImageFilter.MaxFilter(31)))

    out = tile_background(n)
    fold = ImageChops.offset(shape, round(16 * k), round(16 * k)).filter(ImageFilter.GaussianBlur(6 * k))
    out = Image.composite(Image.new('RGBA', (n, n), (0, 95, 35, 255)), out, fold)
    out = Image.composite(gradient(n), out, shape)
    out = Image.composite(gradient(n, start=(170, 255, 60), end=(20, 200, 70)), out, accent)
    out = out.resize((size, size), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), rounded_mask(size, inset=0.0, radius=0.19)))
    return out


if __name__ == '__main__':
    music_logo(512).save(ROOT / 'assets/icon/music_logo.png')
    print('ok')
