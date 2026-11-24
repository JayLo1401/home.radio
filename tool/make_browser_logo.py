"""The browser's tile - a globe with a shield (the ad blocker) - in the style
of the other parts' tiles (tv_logo, dashboard_logo: green ribbons on the dark
tile), with make_home_system_logo.py's helpers.

    python tool/make_browser_logo.py

Writes assets/icon/browser_logo.png (512 px). Needs Pillow.
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_home_system_logo import ROOT, gradient, rounded_mask, tile_background  # noqa: E402


def _ring(d: ImageDraw.ImageDraw, box, t, k):
    """An ellipse's ribbon: outer minus inner area."""
    x0, y0, x1, y1 = box
    d.ellipse((x0 * k, y0 * k, x1 * k, y1 * k), fill=255)
    d.ellipse(((x0 + t) * k, (y0 + t) * k, (x1 - t) * k, (y1 - t) * k), fill=0)


def _shield(cx, top, w, h, k):
    """A shield's outline: flat top with rounded shoulders, sides bending to a point."""
    pts = []
    half = w / 2
    # Top edge, slightly dipping in the middle.
    pts += [(cx - half, top + 0.10 * h), (cx - 0.25 * w, top + 0.02 * h), (cx, top), (cx + 0.25 * w, top + 0.02 * h),
            (cx + half, top + 0.10 * h)]
    # Right side down to the point (a soft curve).
    steps = 12
    for i in range(1, steps + 1):
        f = i / steps
        x = cx + half * (1 - f ** 1.8)
        y = top + 0.10 * h + (0.90 * h) * (f ** 0.85)
        pts.append((x, y))
    for i in range(steps - 1, 0, -1):
        f = i / steps
        x = cx - half * (1 - f ** 1.8)
        y = top + 0.10 * h + (0.90 * h) * (f ** 0.85)
        pts.append((x, y))
    return [(x * k, y * k) for x, y in pts]


def browser_logo(size: int) -> Image.Image:
    s = 4
    n = size * s
    k = n / 1000
    shape = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(shape)
    # The globe: rim, a meridian and the equator plus two parallels.
    cx, cy, r, t = 425, 440, 300, 70
    _ring(d, (cx - r, cy - r, cx + r, cy + r), t, k)
    inner = Image.new('L', (n, n), 0)
    idr = ImageDraw.Draw(inner)
    idr.ellipse(((cx - r + t - 2) * k, (cy - r + t - 2) * k, (cx + r - t + 2) * k, (cy + r - t + 2) * k), fill=255)
    lines = Image.new('L', (n, n), 0)
    ld = ImageDraw.Draw(lines)
    _ring(ld, (cx - 118, cy - r, cx + 118, cy + r), 44, k)
    lw = 42
    for y in (cy - 112, cy, cy + 112):
        ld.rounded_rectangle(((cx - r) * k, (y - lw / 2) * k, (cx + r) * k, (y + lw / 2) * k), radius=lw / 2 * k, fill=255)
    lines = ImageChops.multiply(lines, inner)
    shape = ImageChops.lighter(shape, lines)

    # The shield over the globe's bottom right, cut free by a gap.
    sx, stop, sw, sh = 688, 520, 300, 372
    shield = Image.new('L', (n, n), 0)
    ImageDraw.Draw(shield).polygon(_shield(sx, stop, sw, sh, k), fill=255)
    shield = shield.filter(ImageFilter.GaussianBlur(4 * k)).point(lambda v: 255 if v > 128 else 0)
    gap = Image.new('L', (n, n), 0)
    ImageDraw.Draw(gap).polygon(_shield(sx, stop - 42, sw + 84, sh + 80, k), fill=255)
    gap = gap.filter(ImageFilter.GaussianBlur(8 * k)).point(lambda v: 255 if v > 128 else 0)
    shape = ImageChops.subtract(shape, gap)
    # A check mark cut into the shield.
    check = Image.new('L', (n, n), 0)
    cd = ImageDraw.Draw(check)
    pts = [(sx - 78, stop + 188), (sx - 18, stop + 246), (sx + 86, stop + 124)]
    cd.line([(x * k, y * k) for x, y in pts], fill=255, width=round(46 * k), joint='curve')
    for x, y in (pts[0], pts[-1]):
        cd.ellipse(((x - 23) * k, (y - 23) * k, (x + 23) * k, (y + 23) * k), fill=255)
    accent = ImageChops.subtract(shield, check)

    out = tile_background(n)
    both = ImageChops.lighter(shape, accent)
    fold = ImageChops.offset(both, round(16 * k), round(16 * k)).filter(ImageFilter.GaussianBlur(6 * k))
    out = Image.composite(Image.new('RGBA', (n, n), (0, 95, 35, 255)), out, fold)
    out = Image.composite(gradient(n), out, shape)
    out = Image.composite(gradient(n, start=(170, 255, 60), end=(20, 200, 70)), out, accent)
    out = out.resize((size, size), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), rounded_mask(size, inset=0.0, radius=0.19)))
    return out


if __name__ == '__main__':
    browser_logo(512).save(ROOT / 'assets/icon/browser_logo.png')
