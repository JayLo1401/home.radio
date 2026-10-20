"""Builds assets/map/alpine_basemap.json from Natural Earth (public domain) GeoJSON.

usage: python make_basemap.py <ne_data_dir> <out.json>
Coordinates are stored as integer thousandths of a degree, flattened
[lon, lat, lon, lat, ...] per line/ring.
"""
import json
import math
import sys

LON0, LON1, LAT0, LAT1 = 3.0, 23.0, 42.0, 52.0
TOL = 0.004  # simplification tolerance in degrees (~400 m)


def inside(p, margin=0.3):
    return LON0 - margin <= p[0] <= LON1 + margin and LAT0 - margin <= p[1] <= LAT1 + margin


def dp(points, tol):
    if len(points) < 3:
        return points
    a, b = points[0], points[-1]
    dx, dy = b[0] - a[0], b[1] - a[1]
    norm = math.hypot(dx, dy) or 1e-12
    best, idx = -1.0, 0
    for i in range(1, len(points) - 1):
        p = points[i]
        d = abs(dy * (p[0] - a[0]) - dx * (p[1] - a[1])) / norm
        if d > best:
            best, idx = d, i
    if best <= tol:
        return [a, b]
    return dp(points[: idx + 1], tol)[:-1] + dp(points[idx:], tol)


def clip_line(coords):
    """Splits a line into the runs that lie inside the box."""
    runs, cur = [], []
    for p in coords:
        if inside(p):
            cur.append(p)
        elif cur:
            cur.append(p)
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    return [r for r in runs if len(r) >= 2]


def lines_of(geom):
    t = geom["type"]
    if t == "LineString":
        return [geom["coordinates"]]
    if t == "MultiLineString":
        return geom["coordinates"]
    if t == "Polygon":
        return [geom["coordinates"][0]]
    if t == "MultiPolygon":
        return [poly[0] for poly in geom["coordinates"]]
    return []


def enc(points):
    out = []
    last = None
    for p in points:
        q = (round(p[0] * 1000), round(p[1] * 1000))
        if q != last:
            out.extend(q)
            last = q
    return out


def load(d, name):
    with open(f"{d}/{name}.geojson", encoding="utf-8") as f:
        return json.load(f)["features"]


def layer_lines(d, name, keep=lambda props: True, closed=False):
    result = []
    for feat in load(d, name):
        if not feat.get("geometry") or not keep(feat["properties"]):
            continue
        for line in lines_of(feat["geometry"]):
            if closed:
                if not any(inside(p, 0) for p in line):
                    continue
                # Closed ring: first == last point, so simplify two halves.
                mid = len(line) // 2
                pts = dp(line[: mid + 1], TOL)[:-1] + dp(line[mid:], TOL)
                if len(pts) >= 4:
                    result.append(enc(pts))
            else:
                for run in clip_line(line):
                    pts = dp(run, TOL)
                    if len(pts) >= 2:
                        result.append(enc(pts))
    return [r for r in result if len(r) >= 4]


def main():
    d, out = sys.argv[1], sys.argv[2]
    data = {
        "source": "Natural Earth (public domain), naturalearthdata.com",
        "scale": 1000,
        "countries": layer_lines(d, "ne_10m_admin_0_boundary_lines_land"),
        "coast": layer_lines(d, "ne_10m_coastline"),
        "states": layer_lines(
            d,
            "ne_10m_admin_1_states_provinces_lines",
            keep=lambda p: (p.get("ADM0_A3") or p.get("adm0_a3")) in ("AUT", "DEU", "CHE", "ITA", "SVN", "HRV", "HUN", "SVK", "CZE"),
        ),
        "lakes": layer_lines(d, "ne_10m_lakes", keep=lambda p: (p.get("scalerank") or 0) <= 10, closed=True),
        "rivers": layer_lines(d, "ne_10m_rivers_lake_centerlines", keep=lambda p: (p.get("scalerank") or 0) <= 9),
        "cities": [],
    }
    for feat in load(d, "ne_10m_populated_places_simple"):
        p = feat["properties"]
        lon, lat = p["longitude"], p["latitude"]
        if inside((lon, lat), 0) and (p.get("scalerank") or 10) <= 8:
            data["cities"].append([p["name"], round(lon * 1000), round(lat * 1000), int(p.get("scalerank") or 10)])
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    for k, v in data.items():
        if isinstance(v, list):
            print(k, len(v), sum(len(x) for x in v if isinstance(x, list)) if k != "cities" else "")


if __name__ == "__main__":
    main()
