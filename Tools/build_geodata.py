#!/usr/bin/env python3
"""Builds Resources/geodata-<region>.bin, a region's base map, from Natural Earth GeoJSON.

Usage: python3 -I Tools/build_geodata.py <download-dir> <output.bin> <region>

Everything is clipped to the region's box (see REGIONS) so the bundle stays small.

Format (all little-endian):
  "TSGD" u8 version=1, then a raw-deflate stream of:
    u8 layerCount
    per layer: u8 layerId, u32 featureCount, features
      feature: u8 rank, u16 ringCount, rings
        ring: varint pointCount, then zigzag-varint deltas of (lat, lon) in 1e-5 degrees

Natural Earth is public domain.
"""
import json
import os
import struct
import sys
import zlib

Q = 100000  # 1e-5 degree quantization (~1.1 m)

# Generous boxes around each rail network, so even the widest zoom near an edge has a map.
REGIONS = {  # min lat, max lat, min lon, max lon
    "dcbal": (36.6, 41.4, -79.9, -74.3),
    "nyc": (38.9, 42.9, -76.4, -70.6),
    "phl": (38.5, 41.3, -77.1, -73.2),
    "bos": (40.8, 43.7, -73.2, -69.4),
}
REGION = REGIONS["dcbal"]

LAYER_LAND, LAYER_LAKES, LAYER_RIVERS, LAYER_URBAN, LAYER_ROADS, LAYER_STATES = range(6)
ROAD_TYPES = {"Major Highway", "Beltway", "Secondary Highway", "Road"}


def varint(n, out):
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def zigzag(n):
    return (n << 1) ^ (n >> 63)


# ---- clipping (points are (lon, lat) as in GeoJSON) ----

def clip_polygon(ring):
    """Sutherland–Hodgman against the region rectangle."""
    min_lat, max_lat, min_lon, max_lon = REGION
    edges = [
        (lambda p: p[0] >= min_lon, lambda a, b: _x_cross(a, b, min_lon)),
        (lambda p: p[0] <= max_lon, lambda a, b: _x_cross(a, b, max_lon)),
        (lambda p: p[1] >= min_lat, lambda a, b: _y_cross(a, b, min_lat)),
        (lambda p: p[1] <= max_lat, lambda a, b: _y_cross(a, b, max_lat)),
    ]
    pts = ring
    for inside, cross in edges:
        if not pts:
            break
        out = []
        prev = pts[-1]
        for cur in pts:
            if inside(cur):
                if not inside(prev):
                    out.append(cross(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(cross(prev, cur))
            prev = cur
        pts = out
    return pts if len(pts) >= 3 else []


def _x_cross(a, b, x):
    t = (x - a[0]) / (b[0] - a[0])
    return (x, a[1] + (b[1] - a[1]) * t)


def _y_cross(a, b, y):
    t = (y - a[1]) / (b[1] - a[1])
    return (a[0] + (b[0] - a[0]) * t, y)


def inside_region(p):
    min_lat, max_lat, min_lon, max_lon = REGION
    return min_lon <= p[0] <= max_lon and min_lat <= p[1] <= max_lat


def clip_line(line):
    """Splits a line into the runs inside the region, keeping one point either side."""
    runs, run = [], []
    for i, p in enumerate(line):
        if inside_region(p):
            if not run and i > 0:
                run.append(line[i - 1])
            run.append(p)
        elif run:
            run.append(p)
            runs.append(run)
            run = []
    if len(run) >= 2:
        runs.append(run)
    return [r for r in runs if len(r) >= 2]


def bbox_intersects(coords):
    min_lat, max_lat, min_lon, max_lon = REGION
    lons = [p[0] for p in coords]
    lats = [p[1] for p in coords]
    return min(lons) <= max_lon and max(lons) >= min_lon and min(lats) <= max_lat and max(lats) >= min_lat


# ---- encoding ----

def dedupe(points):
    out, last = [], None
    for lon, lat in points:
        p = (round(lat * Q), round(lon * Q))
        if p != last:
            out.append(p)
            last = p
    return out


def encode_layer(layer_id, features, out):
    body = bytearray()
    count = 0
    for rank, rings in features:
        qrings = [r for r in (dedupe(r) for r in rings) if len(r) >= 2]
        if not qrings:
            continue
        count += 1
        body += struct.pack("<BH", max(0, min(255, rank)), len(qrings))
        for r in qrings:
            varint(len(r), body)
            plat, plon = 0, 0
            for lat, lon in r:
                varint(zigzag(lat - plat), body)
                varint(zigzag(lon - plon), body)
                plat, plon = lat, lon
    out += struct.pack("<BI", layer_id, count)
    out += body
    return count


def load(dirpath, name):
    path = os.path.join(dirpath, name + ".geojson")
    if not os.path.exists(path):
        print(f"missing {name}, skipped", file=sys.stderr)
        return []
    with open(path, encoding="utf-8") as f:
        return json.load(f)["features"]


def rank_of(props):
    for key in ("scalerank", "min_zoom"):
        v = props.get(key)
        if isinstance(v, (int, float)):
            return int(v)
    return 0


def geo_layer(dirpath, names, polygons, keep=lambda p: True):
    feats = []
    for name in names:
        for f in load(dirpath, name):
            geom = f.get("geometry")
            if geom is None or not keep(f["properties"]):
                continue
            rank = rank_of(f["properties"])
            t, c = geom["type"], geom["coordinates"]
            if polygons:
                polys = [c] if t == "Polygon" else (c if t == "MultiPolygon" else [])
                for poly in polys:
                    if not bbox_intersects(poly[0]):
                        continue
                    rings = [r for r in (clip_polygon(ring) for ring in poly) if r]
                    if rings:
                        feats.append((rank, rings))
            else:
                lines = [c] if t == "LineString" else (c if t == "MultiLineString" else [])
                for line in lines:
                    if not bbox_intersects(line):
                        continue
                    for run in clip_line(line):
                        feats.append((rank, [run]))
    return feats


def main():
    global REGION
    src, dst = sys.argv[1], sys.argv[2]
    REGION = REGIONS[sys.argv[3] if len(sys.argv) > 3 else "dcbal"]
    layers = [
        (LAYER_LAND, geo_layer(src, ["ne_10m_land"], True)),
        (LAYER_LAKES, geo_layer(src, ["ne_10m_lakes", "ne_10m_lakes_north_america"], True)),
        (LAYER_RIVERS, geo_layer(src, ["ne_10m_rivers_lake_centerlines", "ne_10m_rivers_north_america"], False)),
        (LAYER_URBAN, geo_layer(src, ["ne_10m_urban_areas"], True)),
        (LAYER_ROADS, geo_layer(src, ["ne_10m_roads"], False, keep=lambda p: p.get("type") in ROAD_TYPES)),
        (LAYER_STATES, geo_layer(src, ["ne_10m_admin_1_states_provinces_lines"], False)),
    ]
    payload = bytearray(struct.pack("<B", len(layers)))
    for layer_id, feats in layers:
        n = encode_layer(layer_id, feats, payload)
        print(f"layer {layer_id}: {n} features", file=sys.stderr)
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = comp.compress(bytes(payload)) + comp.flush()
    with open(dst, "wb") as f:
        f.write(b"TSGD" + bytes([1]) + data)
    print(f"raw {len(payload)} bytes -> {len(data)} compressed", file=sys.stderr)


if __name__ == "__main__":
    main()
