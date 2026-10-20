"""Builds assets/map/relief.jpg: a shaded, green hypsometric relief of the
Alpine region (lon 7..19 E, lat 45..50 N, plate carree, ~250 m per pixel).

Source: Copernicus DEM GLO-90 tiles (free licence, attribution required:
"produced using Copernicus WorldDEM-90 (c) DLR e.V. 2010-2014 and (c) Airbus
Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European
Union and ESA; all rights reserved"), downloaded from
https://copernicus-dem-90m.s3.amazonaws.com/Copernicus_DSM_COG_30_N47_00_E015_00_DEM/...

usage: python make_relief.py <dir with Copernicus_DSM_COG_30_*.tif> <out.jpg>
needs: numpy, tifffile, imagecodecs, pillow
"""
import sys

import numpy as np
import tifffile
from PIL import Image

LON0, LON1, LAT0, LAT1 = 7, 19, 45, 50
TILE = 1200        # samples per degree in GLO-90 below 50 N
FX, FY = 4, 3      # downsampling -> 300 px/deg lon, 400 px/deg lat

# elevation (m) -> colour, light green lowlands to grey rock and snow
STOPS = [
    (-1, (46, 86, 130)),
    (0.5, (46, 86, 130)),
    (1, (68, 114, 50)),
    (400, (62, 106, 46)),
    (900, (54, 94, 41)),
    (1500, (88, 110, 70)),
    (2000, (128, 130, 114)),
    (2600, (176, 176, 170)),
    (3300, (238, 238, 238)),
]


def main():
    src, out = sys.argv[1], sys.argv[2]
    h = (LAT1 - LAT0) * TILE
    w = (LON1 - LON0) * TILE
    dem = np.zeros((h, w), dtype=np.float32)
    for lat in range(LAT0, LAT1):
        for lon in range(LON0, LON1):
            name = f"Copernicus_DSM_COG_30_N{lat:02d}_00_E{lon:03d}_00_DEM"
            try:
                tile = tifffile.imread(f"{src}/{name}.tif").astype(np.float32)
            except FileNotFoundError:
                print("missing", name)
                continue
            row = (LAT1 - 1 - lat) * TILE  # row 0 = north
            col = (lon - LON0) * TILE
            dem[row:row + TILE, col:col + TILE] = tile[:TILE, :TILE]
    dem = dem.reshape(h // FY, FY, w // FX, FX).mean(axis=(1, 3))
    dem = np.nan_to_num(dem, nan=0.0)

    rows, cols = dem.shape
    lat_c = LAT1 - (np.arange(rows) + 0.5) / rows * (LAT1 - LAT0)
    dx = 111320.0 * np.cos(np.radians(lat_c))[:, None] * (LON1 - LON0) / cols
    dy = 111320.0 * (LAT1 - LAT0) / rows
    gy, gx = np.gradient(dem)
    gx = gx / dx
    gy = gy / dy
    slope = np.arctan(np.hypot(gx, gy) * 1.6)  # slight vertical exaggeration
    aspect = np.arctan2(-gx, gy)
    az, alt = np.radians(315.0), np.radians(45.0)
    shade = np.sin(alt) * np.cos(slope) + np.cos(alt) * np.sin(slope) * np.cos(az - aspect)
    shade = np.clip(shade, 0, 1)

    elev = [s[0] for s in STOPS]
    rgb = np.zeros((rows, cols, 3), dtype=np.float32)
    for c in range(3):
        rgb[..., c] = np.interp(dem, elev, [s[1][c] for s in STOPS])
    land = dem > 0.5
    light = 0.45 + 0.75 * shade
    rgb[land] *= light[land][:, None]
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    img.save(out, quality=80, optimize=True, progressive=True)
    print(out, img.size)


if __name__ == "__main__":
    main()
