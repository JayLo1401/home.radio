"""The films part's tile - a clapperboard in the style of the other parts'
tiles (green ribbons with a darker fold on the dark tile, see
make_home_system_logo.py).

    python tool/make_movies_logo.py

Writes assets/icon/movies_logo.png (512 px). Needs Pillow.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_home_system_logo import ROOT, gradient, rounded_mask, tile_background  # noqa: E402


def _clapper_bar(n: int, k: float, box, frame: float, slant: float, rungs: int, rung: float) -> Image.Image:
    """A clapper bar as one ribbon: a rounded frame with slanted rungs across
    it - the black-and-white stripes of a real clapperboard."""
    x0, y0, x1, y1 = box
    bar = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(bar)
    r = (y1 - y0) * 0.36
    d.rounded_rectangle((x0 * k, y0 * k, x1 * k, y1 * k), radius=r * k, fill=255)
    d.rounded_rectangle(((x0 + frame) * k, (y0 + frame) * k, (x1 - frame) * k, (y1 - frame) * k),
                        radius=max(1.0, r - frame) * k, fill=0)
    step = (x1 - x0) / (rungs + 1)
    for i in range(1, rungs + 1):
        x = x0 + i * step
        d.polygon([((x + slant / 2 - rung / 2) * k, y0 * k), ((x + slant / 2 + rung / 2) * k, y0 * k),
                   ((x - slant / 2 + rung / 2) * k, y1 * k), ((x - slant / 2 - rung / 2) * k, y1 * k)], fill=255)
    return bar


def movies_logo(size: int) -> Image.Image:
    """Filme: a clapperboard - the slate as a ribbon frame with two lines
    on it (scene / take), its striped bar, and the clapper arm swung open
    above it from the hinge on the left."""
    s = 4
    n = size * s
    k = n / 1000
    shape = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(shape)
    t = 76
    # The slate: outer minus inner area.
    d.rounded_rectangle((175 * k, 475 * k, 825 * k, 825 * k), radius=95 * k, fill=255)
    d.rounded_rectangle(((175 + t) * k, (475 + t) * k, (825 - t) * k, (825 - t) * k), radius=35 * k, fill=0)
    # The fixed striped bar on the slate, and the arm swung open.
    box = (175, 335, 825, 445)
    shape = ImageChops.lighter(shape, _clapper_bar(n, k, box, frame=40, slant=62, rungs=4, rung=62))
    arm = _clapper_bar(n, k, box, frame=40, slant=-62, rungs=4, rung=62)
    arm = arm.rotate(14, resample=Image.BICUBIC, center=(200 * k, 335 * k))
    arm = ImageChops.offset(arm, 0, round(-44 * k))
    shape = ImageChops.lighter(shape, arm)

    accent = Image.new('L', (n, n), 0)
    ad = ImageDraw.Draw(accent)
    # Scene / take: two lines on the slate.
    for x0, x1, y in ((300, 700, 610), (300, 540, 693)):
        ad.line((x0 * k, y * k, x1 * k, y * k), fill=255, width=round(46 * k))
        for x in (x0, x1):
            ad.ellipse(((x - 23) * k, (y - 23) * k, (x + 23) * k, (y + 23) * k), fill=255)

    out = tile_background(n)
    fold = ImageChops.offset(shape, round(16 * k), round(16 * k)).filter(ImageFilter.GaussianBlur(6 * k))
    out = Image.composite(Image.new('RGBA', (n, n), (0, 95, 35, 255)), out, fold)
    out = Image.composite(gradient(n), out, shape)
    out = Image.composite(gradient(n, start=(170, 255, 60), end=(20, 200, 70)), out, accent)
    out = out.resize((size, size), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), rounded_mask(size, inset=0.0, radius=0.19)))
    return out


if __name__ == '__main__':
    movies_logo(512).save(ROOT / 'assets/icon/movies_logo.png')
    print('ok')
