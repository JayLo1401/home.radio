"""Home System's logo - the green house with a play button on a dark tile -
in the sizes the app needs, from tool/home_system_logo_source.png.

    python tool/make_home_system_logo.py [reference.png]

With a reference image (the three-icon draft), its right-hand tile is cut
out first and stored as the source. Writes
- assets/icon/home_system_logo.png       the tile, transparent corners (in the app)
- assets/icon/home_system_foreground.png the house alone, for adaptive icons
- android/app/src/main/res/drawable/tv_banner.png  the Android TV banner
- assets/icon/tv_logo.png, dashboard_logo.png  the parts' tiles
- android/app/src/main/res/drawable-nodpi/launch_logo.png  Android's launch screen
then `dart run flutter_launcher_icons` makes the app icons from them.
Needs Pillow; the banner text uses Segoe UI (Windows).
"""
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tool/home_system_logo_source.png'
DARK = (13, 16, 17)  # the tile's colour, also the adaptive icon background
LIME = (190, 255, 40)


RADIO_SOURCE = ROOT / 'tool/radio_logo_source.png'


def cut_reference(path: str):
    im = Image.open(path).convert('RGB')
    # The tiles of the draft (found by their grey outlines): right = Home
    # Media, middle = Radio.
    im.crop((1187, 162, 1718, 693)).save(SOURCE)
    im.crop((624, 162, 1155, 693)).save(RADIO_SOURCE)


def gradient(size: int, start=(205, 255, 35), end=(0, 196, 80)) -> Image.Image:
    """Lime top left to green bottom right, like the draft's ribbons."""
    # (x + y) / 2: diagonal without the empty corners a rotated gradient has,
    # stretched over the glyph's area (15..85 %) for the full lime-to-green.
    v = Image.linear_gradient('L').resize((size, size))
    g = ImageChops.add(v, v.rotate(90), scale=2).point(lambda x: max(0, min(255, round((x - 45) * 255 / 165))))
    bands = [g.point(lambda v, a=a, b=b: round(a + (b - a) * v / 255)) for a, b in zip(start, end)]
    return Image.merge('RGB', bands).convert('RGBA')


def tile_background(size: int) -> Image.Image:
    """The draft's dark tile: graphite fading to black, a faint green glow at
    the bottom edge, a thin grey outline."""
    top, bottom = (36, 39, 41), (6, 8, 9)
    g = Image.linear_gradient('L').resize((size, size))
    bands = [g.point(lambda v, a=a, b=b: round(a + (b - a) * v / 255)) for a, b in zip(top, bottom)]
    bg = Image.merge('RGB', bands).convert('RGBA')
    glow = Image.new('L', (size, size), 0)
    ImageDraw.Draw(glow).ellipse((0.0 * size, 0.92 * size, 1.0 * size, 1.3 * size), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.05))
    bg = Image.composite(Image.new('RGBA', bg.size, (30, 120, 30, 255)), bg, glow)
    ImageDraw.Draw(bg).rounded_rectangle((2, 2, size - 3, size - 3), radius=0.19 * size, outline=(70, 74, 74, 255),
                                         width=max(2, size // 300))
    bg.putalpha(rounded_mask(size, inset=0.0, radius=0.19))
    return bg


def tv_logo(size: int) -> Image.Image:
    """TV in the draft's style: a screen with antenna and a play button,
    as green ribbons with a darker fold underneath."""
    s = 4
    n = size * s
    k = n / 1000
    shape = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(shape)
    # Screen frame: outer minus inner area (PIL's thick rounded outlines
    # leave spikes in the corners).
    t = 100
    d.rounded_rectangle((170 * k, 270 * k, 830 * k, 790 * k), radius=130 * k, fill=255)
    d.rounded_rectangle(((170 + t) * k, (270 + t) * k, (830 - t) * k, (790 - t) * k), radius=50 * k, fill=0)
    # Antenna (round ends).
    for x0, x1 in ((440, 350), (560, 650)):
        d.line((x0 * k, 270 * k, x1 * k, 150 * k), fill=255, width=round(62 * k))
        for x, y in ((x0, 270), (x1, 150)):
            d.ellipse(((x - 31) * k, (y - 31) * k, (x + 31) * k, (y + 31) * k), fill=255)
    play = Image.new('L', (n, n), 0)
    pd = ImageDraw.Draw(play)
    tri = [(445 * k, 425 * k), (445 * k, 635 * k), (620 * k, 530 * k)]
    pd.polygon(tri, fill=255)
    pd.line(tri + [tri[0]], fill=255, width=round(40 * k), joint='curve')
    for x, y in tri:
        pd.ellipse((x - 20 * k, y - 20 * k, x + 20 * k, y + 20 * k), fill=255)

    out = tile_background(n)
    fold = ImageChops.offset(shape, round(16 * k), round(16 * k)).filter(ImageFilter.GaussianBlur(6 * k))
    out = Image.composite(Image.new('RGBA', (n, n), (0, 95, 35, 255)), out, fold)
    out = Image.composite(gradient(n), out, shape)
    out = Image.composite(gradient(n, start=(170, 255, 60), end=(20, 200, 70)), out, play)
    out = out.resize((size, size), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), rounded_mask(size, inset=0.0, radius=0.19)))
    return out


def dashboard_logo(size: int) -> Image.Image:
    """Haussteuerung in the same style: a light bulb as a green ribbon with
    its screw base, and short rays - "the house's lights and switches"."""
    s = 4
    n = size * s
    k = n / 1000
    shape = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(shape)
    t = 82
    # Bulb: a circle running into a neck - outer minus inner area.
    d.ellipse((300 * k, 210 * k, 700 * k, 610 * k), fill=255)
    d.polygon([(330 * k, 500 * k), (670 * k, 500 * k), (610 * k, 700 * k), (390 * k, 700 * k)], fill=255)
    d.ellipse(((300 + t) * k, (210 + t) * k, (700 - t) * k, (610 - t) * k), fill=0)
    d.polygon([((330 + t) * k, 500 * k), ((670 - t) * k, 500 * k), ((610 - t) * k, (700 - t) * k),
               ((390 + t) * k, (700 - t) * k)], fill=0)
    # Screw base: two rounded bars.
    for y in (725, 800):
        d.rounded_rectangle((405 * k, y * k, 595 * k, (y + 50) * k), radius=25 * k, fill=255)
    accent = Image.new('L', (n, n), 0)
    ad = ImageDraw.Draw(accent)
    # Rays around the top.
    for x0, y0, x1, y1 in ((500, 95, 500, 150), (245, 200, 285, 240), (755, 200, 715, 240),
                           (165, 410, 220, 410), (835, 410, 780, 410)):
        ad.line((x0 * k, y0 * k, x1 * k, y1 * k), fill=255, width=round(46 * k))
        for x, y in ((x0, y0), (x1, y1)):
            ad.ellipse(((x - 23) * k, (y - 23) * k, (x + 23) * k, (y + 23) * k), fill=255)
    # Filament: a small zigzag inside the bulb.
    pts = [(430, 470), (470, 400), (500, 470), (530, 400), (570, 470)]
    ad.line([(x * k, y * k) for x, y in pts], fill=255, width=round(34 * k), joint='curve')
    for x, y in (pts[0], pts[-1]):
        ad.ellipse(((x - 17) * k, (y - 17) * k, (x + 17) * k, (y + 17) * k), fill=255)

    out = tile_background(n)
    fold = ImageChops.offset(shape, round(16 * k), round(16 * k)).filter(ImageFilter.GaussianBlur(6 * k))
    out = Image.composite(Image.new('RGBA', (n, n), (0, 95, 35, 255)), out, fold)
    out = Image.composite(gradient(n), out, shape)
    out = Image.composite(gradient(n, start=(170, 255, 60), end=(20, 200, 70)), out, accent)
    out = out.resize((size, size), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), rounded_mask(size, inset=0.0, radius=0.19)))
    return out


def rounded_mask(size: int, inset: float, radius: float) -> Image.Image:
    s = 4
    m = Image.new('L', (size * s, size * s), 0)
    i = inset * size * s
    ImageDraw.Draw(m).rounded_rectangle((i, i, size * s - i, size * s - i), radius=radius * size * s, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def logo(size: int, source: Path = SOURCE) -> Image.Image:
    src = Image.open(source).convert('RGB').resize((size, size), Image.LANCZOS)
    src = src.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))
    out = src.convert('RGBA')
    # Own rounded corners, just inside the draft's outline and glow.
    out.putalpha(rounded_mask(size, inset=0.006, radius=0.19))
    return out


def foreground(size: int) -> Image.Image:
    """The house alone (its green), centred small enough for any icon mask."""
    src = Image.open(SOURCE).convert('RGB')
    w, h = src.size
    inner = src.crop((int(w * 0.08), int(h * 0.08), int(w * 0.92), int(h * 0.92)))
    r, g, b = inner.split()
    # Green/lime is bright in the green channel; the tile around it is dark.
    alpha = g.point(lambda v: max(0, min(255, (v - 70) * 4)))
    house = inner.convert('RGBA')
    house.putalpha(alpha)
    box = alpha.getbbox()
    house = house.crop(box)
    target = int(size * 0.60)
    scale = target / max(house.size)
    house = house.resize((round(house.width * scale), round(house.height * scale)), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.alpha_composite(house, ((size - house.width) // 2, (size - house.height) // 2))
    return out


def banner() -> Image.Image:
    w, h, s = 320, 180, 4
    big = Image.new('RGBA', (w * s, h * s), DARK + (255,))
    # A soft green glow behind the logo.
    glow = Image.new('L', (w * s, h * s), 0)
    ImageDraw.Draw(glow).ellipse((-20 * s, 10 * s, 170 * s, 170 * s), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(28 * s))
    big = Image.composite(Image.new('RGBA', big.size, (40, 160, 60, 255)), big, glow)
    big.alpha_composite(logo(124 * s), (18 * s, 28 * s))
    d = ImageDraw.Draw(big)
    bold = ImageFont.truetype('C:/Windows/Fonts/segoeuib.ttf', 34 * s)
    small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 15 * s)
    d.text((156 * s, 50 * s), 'Home', font=bold, fill=(255, 255, 255))
    d.text((156 * s, 88 * s), 'System', font=bold, fill=(255, 255, 255))
    d.text((158 * s, 132 * s), 'Radio · TV · Apps', font=small, fill=LIME)
    return big.resize((w, h), Image.LANCZOS).convert('RGB')


if __name__ == '__main__':
    if len(sys.argv) > 1:
        cut_reference(sys.argv[1])
    logo(1024).save(ROOT / 'assets/icon/home_system_logo.png')
    logo(512, RADIO_SOURCE).save(ROOT / 'assets/icon/radio_logo.png')
    tv_logo(512).save(ROOT / 'assets/icon/tv_logo.png')
    dashboard_logo(512).save(ROOT / 'assets/icon/dashboard_logo.png')
    foreground(1024).save(ROOT / 'assets/icon/home_system_foreground.png')
    banner().save(ROOT / 'android/app/src/main/res/drawable/tv_banner.png')
    # Android's launch screen (launch_background.xml shows it at 144dp).
    logo(432).save(ROOT / 'android/app/src/main/res/drawable-nodpi/launch_logo.png')
    print('ok')
