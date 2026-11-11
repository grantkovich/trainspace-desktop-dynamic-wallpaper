#!/usr/bin/env python3
"""Builds Resources/rail-<region>.bin (track geometry, stations and timetables) from static GTFS.

Usage: python3 -I Tools/build_rail.py <download-dir> <output.bin> <region>

Regions: dcbal (DC–Baltimore), nyc (New York), phl (Philadelphia), bos (Boston). The download
dir holds each agency's GTFS zip (fetch with Tools/fetch_data.sh); see REGIONS for which.

Format (all little-endian):
  "TSRL" u8 version=3, then a raw-deflate stream of:
    i32 reference latitude (1e-5 deg) for the flat-metre distances below
    varint stringCount, strings (varint byteLength + UTF-8)          -- string table
    varint lineCount, lines (in drawing order within each system):
      u8 system, varint id, varint name, varint shortName,
      u24 color, u24 textColor (the agency's own, for signs and boards),
      u24 mapColor (what the map draws; the app tunes it for light and dark),
      varint routeIdCount, varint routeId...                          -- GTFS route_ids it covers
    varint shapeCount, shapes:
      varint lineIndex, varint pointCount, zigzag-varint deltas of (lat, lon) in 1e-5 degrees
    varint stationCount, stations:
      u8 system, varint name, i32 lat, i32 lon (1e-5 deg),
      u8 rank (0 = hub or terminal, 1 = transfer between lines, 2 = other),
      varint code (Amtrak station code, e.g. WAS; empty otherwise)
    varint stopCount, GTFS stops (for matching live trip updates):
      u8 system, varint stopId, varint station index
    varint serviceCount, services:
      u8 system, u8 weekdayMask (bit 0 = Monday), u32 startDate, u32 endDate (yyyymmdd, 0 = none),
      varint addedCount, u32 dates..., varint removedCount, u32 dates...
    varint tripCount, trips:
      varint lineIndex, varint serviceIndex, varint shapeIndex, varint tripId, varint headsign,
      varint trainNumber, u8 directionId, varint stopCount, then per stop:
        varint arrival (seconds after midnight for the first stop; delta from the previous
        departure afterwards), varint dwell (departure − arrival), varint distance (metres
        along the shape; delta from the previous stop), varint station index + 1 (0 = none)

Every string field is an index into the string table (0 = empty string).
"""
import csv
import datetime
import io
import math
import re
import struct
import sys
import zipfile
import zlib

Q = 100000

# System ids, shared with TransitSystem in Swift (Sources/TrainspaceCore/Systems.swift).
(METRORAIL, MARC, VRE, AMTRAK, LIGHTRAIL, SUBWAY, NYC_SUBWAY, SIR, LIRR, MNR, NJT_RAIL, NJT_LR, PATH,
 SEPTA_RAIL, SEPTA_METRO, PATCO, MBTA_SUBWAY, MBTA_CR) = range(18)
SYSTEM_IDS = {
    METRORAIL: "metrorail", MARC: "marc", VRE: "vre", AMTRAK: "amtrak", LIGHTRAIL: "lightrail", SUBWAY: "subway",
    NYC_SUBWAY: "nyct", SIR: "sir", LIRR: "lirr", MNR: "mnr", NJT_RAIL: "njt", NJT_LR: "njtlr", PATH: "path",
    SEPTA_RAIL: "septa", SEPTA_METRO: "septametro", PATCO: "patco", MBTA_SUBWAY: "mbta", MBTA_CR: "mbtacr",
}
RAPID = {METRORAIL, SUBWAY, NYC_SUBWAY, SIR, PATH, SEPTA_METRO, PATCO, MBTA_SUBWAY}
MAINLINE = {MARC, VRE, AMTRAK, LIRR, MNR, NJT_RAIL, SEPTA_RAIL, MBTA_CR}

# Map colours where the agency's own would be confused with a neighbour's: MARC's orange and VRE's
# red and blue sit beside Metrorail's lines, so they're drawn in their own hues; Amtrak is drawn
# neutral everywhere. The app keeps DC's hand-tuned light and dark versions of these (Palette.swift).
MAP_COLORS = {
    "marc": 0x8A3FC4, "vre": 0xD0337F, "amtrak": 0x2A2B2E,
}


class Feed:
    """One GTFS zip and how its routes become lines.

    `route(r)` gets a routes.txt row and returns (system, line key, name, short name) or None to
    skip the route; routes sharing a line key are one line. `order` lists line keys to draw first
    (lowest) to last; others follow in routes.txt order.
    """
    def __init__(self, zip_path, route, number=None, order=(), map_color=None, inner=None, headsign=None,
                 is_station=None):
        self.zip_path, self.inner, self.route, self.order = zip_path, inner, route, list(order)
        # Which stops get a station marker (trolleys stop at every street corner on the surface).
        self.is_station = is_station or (lambda name: True)
        self.number = number or (lambda t: (t.get("trip_short_name") or t.get("train_id") or "").replace("Train", "").strip())
        self.map_color = map_color
        self.headsign = headsign


def rt(r):
    return r.get("route_type", "").strip()


def fixed(system, table):
    """Routes listed in `table` (route_id → (key, name, short)), nothing else."""
    def route(r):
        spec = table.get(r["route_id"])
        return None if spec is None else (system, *spec)
    return route


def amtrak_route(r):
    # Amtrak's GTFS also carries partners (MARC, VIA, Thruway buses): keep Amtrak's own trains.
    if r.get("agency_id") != "51" or rt(r) != "2":
        return None
    return (AMTRAK, "amtrak", "Amtrak", "AMTK")


def nyct_route(r):
    rid = r["route_id"]
    if rid == "SI":
        return (SIR, "sir", "Staten Island Railway", "SIR")
    base = {"FX": "F", "6X": "6", "7X": "7"}.get(rid, rid)   # diamond expresses run as their route
    short = r.get("route_short_name") or base
    if base in ("GS", "FS", "H"):
        return (NYC_SUBWAY, base, r["route_long_name"], "S")
    return (NYC_SUBWAY, base, f"{short} train", short if base == rid else base)


def lirr_route(r):
    return (LIRR, r["route_id"], r["route_long_name"], r["route_long_name"].replace(" Branch", ""))


def mnr_route(r):
    return (MNR, r["route_id"], f"{r['route_long_name']} Line", r["route_long_name"])


def njt_route(region):
    def route(r):
        short = r.get("route_short_name", "")
        light = rt(r) == "0"
        if region == "nyc" and short in ("ATLC", "RVLN"):
            return None
        if region == "phl" and short not in ("ATLC", "RVLN"):
            return None
        # A few lines are split into two routes (Montclair-Boonton, Coast Line): one line each.
        key = {"BNTNM": "BNTN", "NJCLL": "NJCL", "PRIN": "PRIN"}.get(short, short)
        name = r["route_long_name"]
        return (NJT_LR if light else NJT_RAIL, key, name, short)
    return route


def path_route(r):
    rid = {"1024": "861"}.get(r["route_id"], r["route_id"])   # JSQ–33 via Hoboken is the JSQ–33 line
    name = r["route_long_name"].replace(" (via Hoboken)", "")
    if r["route_id"] == "1024":
        name = "Journal Square - 33rd Street"
    return (PATH, rid, name, {"859": "HOB-33", "860": "HOB-WTC", "862": "NWK-WTC", "861": "JSQ-33",
                              "74320": "NWK-HAR", "77285": "WTC-33"}.get(rid, "PATH"))


def septa_rail_route(r):
    return (SEPTA_RAIL, r["route_id"], r["route_long_name"], r["route_id"])


def septa_metro_route(r):
    rid = r["route_id"]
    if rt(r) not in ("0", "1") or not re.fullmatch(r"[LBTGDM]\d", rid):
        return None
    key = {"B2": "B1"}.get(rid, rid)   # Broad Street express runs on the local's tracks
    # SEPTA Metro's own names for its lines (2025 wayfinding), not the GTFS route descriptions.
    name = {"L1": "L Market-Frankford", "B1": "B Broad Street", "B3": "B3 Broad-Ridge Spur", "G1": "G Girard Avenue",
            "M1": "M Norristown", "D1": "D1 Media", "D2": "D2 Sharon Hill"}.get(key, f"{key} Trolley")
    return (SEPTA_METRO, key, name, key)


def patco_route(r):
    return (PATCO, "patco", "PATCO Speedline", "PATCO")


def mbta_route(r):
    rid, t = r["route_id"], rt(r)
    if t in ("0", "1"):
        return (MBTA_SUBWAY, rid, r["route_long_name"], r.get("route_short_name") or rid)
    if t == "2" and rid.startswith("CR-") and rid != "CR-Foxboro":
        return (MBTA_CR, rid, r["route_long_name"], rid[3:])
    return None


def njt_headsign(raw):
    """NJ TRANSIT's headsigns are capitals with the light rail line in front ("HBLR 8TH STREET LIGHT RAIL")."""
    h = re.sub(r"^(HBLR|NLR|RVLN)\s+", "", (raw or "").strip(), flags=re.I)
    h = re.sub(r"\s+(VIA PENN|LIGHT RAIL STATION|LIGHT RAIL|LIGHT|TRANSP CENT|STATION)$", "", h, flags=re.I)
    return clean_station_name(h)


def septa_number(t):
    # "CYN1052" → "1052"
    return re.sub(r"^[A-Z]+", "", t.get("trip_short_name") or t.get("block_id") or "")


def wmata():
    return Feed("wmata.zip", fixed(METRORAIL, {
        "RED": ("red", "Red Line", "RD"), "ORANGE": ("orange", "Orange Line", "OR"),
        "BLUE": ("blue", "Blue Line", "BL"), "GREEN": ("green", "Green Line", "GR"),
        "YELLOW": ("yellow", "Yellow Line", "YL"), "SILVER": ("silver", "Silver Line", "SV"),
    }), order=["silver", "yellow", "green", "blue", "orange", "red"])


def feeds_for(region):
    amtrak = Feed("amtrak.zip", amtrak_route)
    if region == "dcbal":
        return [
            wmata(),
            Feed("marc.zip", fixed(MARC, {
                "11705": ("penn", "MARC Penn Line", "PENN"), "11706": ("camden", "MARC Camden Line", "CAMDEN"),
                "11704": ("brunswick", "MARC Brunswick Line", "BRUNSWICK")}), map_color=MAP_COLORS["marc"]),
            Feed("vre.zip", fixed(VRE, {
                "2": ("fredericksburg", "VRE Fredericksburg Line", "FBG"), "4": ("manassas", "VRE Manassas Line", "MSS")}),
                map_color=MAP_COLORS["vre"]),
            Feed("lightrail.zip", fixed(LIGHTRAIL, {"11693": ("lightrail", "Light RailLink", "LR")})),
            Feed("subway.zip", fixed(SUBWAY, {"11682": ("subway", "Metro SubwayLink", "SUB")})),
            amtrak,
        ]
    if region == "nyc":
        return [
            Feed("nyct-subway.zip", nyct_route,
                 # Drawn first to last; signs list them the other way round (1 2 3 4 5 6 7 A C E…).
                 order=["H", "FS", "GS", "W", "R", "Q", "N", "L", "Z", "J", "G", "M", "F", "D", "B", "E", "C", "A",
                        "7", "6", "5", "4", "3", "2", "1"]),
            Feed("lirr.zip", lirr_route),
            Feed("mnr.zip", mnr_route),
            Feed("njt-rail.zip", njt_route("nyc"), number=lambda t: (t.get("block_id") or "").strip(), headsign=njt_headsign),
            Feed("path.zip", path_route),
            amtrak,
        ]
    if region == "phl":
        return [
            Feed("septa.zip", septa_rail_route, number=septa_number, inner="google_rail.zip"),
            Feed("septa.zip", septa_metro_route, inner="google_bus.zip", is_station=lambda n: " & " not in n,
                 order=["D1", "D2", "G1", "T5", "T4", "T3", "T2", "T1", "M1", "B3", "B1", "L1"]),
            Feed("patco.zip", patco_route),
            Feed("njt-rail.zip", njt_route("phl"), number=lambda t: (t.get("block_id") or "").strip(), headsign=njt_headsign),
            amtrak,
        ]
    if region == "bos":
        return [
            Feed("mbta.zip", mbta_route,
                 order=["Mattapan", "Green-E", "Green-D", "Green-C", "Green-B", "Blue", "Orange", "Red"]),
            amtrak,
        ]
    raise SystemExit(f"unknown region {region}")


# Rail data covers each commuter region; feeds reaching beyond (Amtrak's national network) are cropped.
REGION_BOXES = {  # min lat, max lat, min lon, max lon
    "dcbal": (37.85, 40.15, -78.75, -75.45),
    "nyc": (39.95, 41.9, -75.1, -71.85),
    "phl": (39.3, 40.45, -75.85, -74.35),
    "bos": (41.5, 42.95, -71.95, -70.55),
}
RAIL_REGION = REGION_BOXES["dcbal"]
# Hub names, by Amtrak station code: the name on the great hall, whatever each feed calls it.
HUB_NAMES = {
    "WAS": "Union Station", "BAL": "Penn Station", "NYP": "Penn Station", "NWK": "Newark Penn Station",
    "PHL": "30th Street Station", "BOS": "South Station", "BBY": "Back Bay", "TRE": "Trenton",
    "NHV": "New Haven", "STM": "Stamford", "PVD": "Providence", "WIL": "Wilmington",
}

# Timetables are kept for services running in the next few months (some feeds publish half a
# year of dated services); once they lapse the app falls back to the last weekday it knows.
KEEP_DAYS = 120

SIMPLIFY_M = 3.0  # Douglas–Peucker tolerance: well under a screen point at the closest zoom


# ---------------------------------------------------------------- helpers

def varint(n, out):
    assert n >= 0, n
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


def read_csv(z, name):
    try:
        with z.open(name) as f:
            return list(csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig")))
    except KeyError:
        return []


def iter_csv(z, name):
    try:
        f = z.open(name)
    except KeyError:
        return
    with f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))


def seconds(t):
    h, m, s = (int(x) for x in t.strip().split(":"))
    return h * 3600 + m * 60 + s


def in_region(lat, lon):
    a, b, c, d = RAIL_REGION
    return a <= lat <= b and c <= lon <= d


def color(hex_text, default):
    try:
        return int(hex_text.strip().lstrip("#"), 16) if hex_text and hex_text.strip() else default
    except ValueError:
        return default


class Local:
    """Equirectangular metres around a reference latitude: plenty for a 200 km region."""
    def __init__(self, lat0):
        self.kx = 111320.0 * math.cos(math.radians(lat0))
        self.ky = 110540.0

    def xy(self, p):
        return (p[1] * self.kx, p[0] * self.ky)


LOCAL = Local(38.9)


def dist(a, b):
    ax, ay = LOCAL.xy(a)
    bx, by = LOCAL.xy(b)
    return math.hypot(ax - bx, ay - by)


def simplify(points, tol):
    """Iterative Douglas–Peucker on (lat, lon) points, tolerance in metres."""
    if len(points) < 3:
        return points
    xy = [LOCAL.xy(p) for p in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        ax, ay = xy[i]
        bx, by = xy[j]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        best, idx = -1.0, -1
        for k in range(i + 1, j):
            px, py = xy[k]
            if L2 == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
                d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best:
                best, idx = d, k
        if best > tol:
            keep[idx] = True
            stack.append((i, idx))
            stack.append((idx, j))
    return [p for p, k in zip(points, keep) if k]


def cumulative(points):
    out = [0.0]
    for a, b in zip(points, points[1:]):
        out.append(out[-1] + dist(a, b))
    return out


def project(points, cum, p, start_seg):
    """Nearest point on the polyline at or after segment `start_seg`: (arc metres, segment, metres away)."""
    px, py = LOCAL.xy(p)
    best = (float("inf"), cum[-1], len(points) - 2)
    for i in range(max(0, start_seg), len(points) - 1):
        ax, ay = LOCAL.xy(points[i])
        bx, by = LOCAL.xy(points[i + 1])
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        t = 0 if L2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L2))
        d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
        if d < best[0]:
            best = (d, cum[i] + t * math.sqrt(L2), i)
    return best[1], best[2], best[0]


def crop_to_region(points):
    """Longest run of the shape inside the rail region (Amtrak shapes span the country)."""
    runs, run = [], []
    for p in points:
        if in_region(*p):
            run.append(p)
        elif run:
            runs.append(run)
            run = []
    if run:
        runs.append(run)
    return max(runs, key=len) if runs else []


STATION_SUFFIXES = [
    " EB", " WB", " MARC STATION", " AMTRAK", " METRO", " MARC", " STATION (METRO)", " (METRO)", " METRO STATION", " STATION", " LIGHT RAIL",
    " (NORTHBOUND)", " (SOUTHBOUND)", " NORTHBOUND", " SOUTHBOUND", " NB", " SB", " AMTRAK STATION",
    " - FS", " - NS", " - MBFS", " - MBNS", " - FS", " SEPTA", " LIGHT RAIL STA", " INTERIM",
    " LIGHT RAIL ARRIVAL", " LIGHT RAIL DEPARTURE", " LIGHT RAIL STATION", " DEPARTURE", " ARRIVAL", " HBLR",
    " TRANSPORTATION CENTER", " TRANSIT CENTER", " INTERMODAL CENTER", " INTERMODAL TRANSPORTATION CENTER",
]
# Names that are only a word or two without "Station" keep it ("South Station", not "South").
KEEP_STATION = {"SOUTH", "NORTH", "SUBURBAN", "JEFFERSON", "30TH STREET", "30TH ST", "BACK BAY"}
REGION_FIXES = {"dcbal": {
    "WASHINGTON UNION STATION": "Union Station", "WASHINGTON UNION": "Union Station",
    "BALTIMORE PENN": "Penn Station", "PENN STATION": "Penn Station", "BALTIMORE PENN STATION": "Penn Station",
    "BWI THURGOOD MARSHALL AIRPORT": "BWI Airport", "BWI MARSHALL AIRPORT": "BWI Airport", "BWI AIRPORT": "BWI Airport",
    "CAMDEN": "Camden Yards", "CAMDEN YARDS": "Camden Yards", "CAMDEN STATION": "Camden Yards",
    "PENN": "Penn Station", "UNION": "Union Station", "L ENFANT": "L'Enfant", "BWI RAIL": "BWI Rail Station",
    "RONALD REAGAN WASHINGTON NATIONAL AIRPORT": "National Airport",
    "WASHINGTON DULLES INTERNATIONAL AIRPORT": "Dulles Airport",
    "MARTINSBURG W VA": "Martinsburg", "HARPERS FERRY W VA": "Harpers Ferry", "DUFFIELDS W VA": "Duffields",
    "BRUNSWICK MD": "Brunswick", "NEWARK": "Newark, DE",
}}
NAME_FIXES = {
    # New York
    "NEW YORK PENN": "Penn Station", "NEW YORK PENN STATION": "Penn Station", "NEW YORK MOYNIHAN TRAIN HALL AT PENN": "Penn Station",
    "NEWARK PENN": "Newark Penn Station", "NEWARK PENN STATION": "Newark Penn Station",
    "GRAND CENTRAL TERMINAL": "Grand Central", "SECAUCUS UPPER LVL": "Secaucus Junction",
    "SECAUCUS LOWER LVL": "Secaucus Junction", "SECAUCUS JUNCTION": "Secaucus Junction",
    "HOBOKEN TERMINAL": "Hoboken", "NEWARK AIRPORT RAILROAD": "Newark Airport", "NEWARK AIRPORT": "Newark Airport",
    "NEWARK BROAD ST": "Newark Broad Street", "MSU": "Montclair State University", "HOHOKUS": "Ho-Ho-Kus",
    "WAYNE/ROUTE 23 TRANSIT CENTER [RR]": "Wayne/Route 23", "NJPAC/CENTRE STREET": "NJPAC/Center Street",
    "LIBERTY STATE PARK-RIDE LIGHT RAIL STA": "Liberty State Park", "SECAUCUS LOWER LEVEL": "Secaucus Junction",
    "SECAUCUS UPPER LEVEL": "Secaucus Junction", "JERSEY AVE.": "Jersey Avenue", "PENN STATION": "Penn Station",
    "NY MOYNIHAN TRAIN HALL AT PENN": "Penn Station", "NEWARK LIBERTY INTERNATIONAL AIRPORT": "Newark Airport", "WTC": "World Trade Center",
    "TRENTON TRANSIT": "Trenton", "TRENTON": "Trenton", "METROPARK": "Metropark",
    "NEW HAVEN UNION": "New Haven", "NEW HAVEN": "New Haven", "STAMFORD TRANSPORTATION": "Stamford",
    # Philadelphia
    "GRAY 30TH ST": "30th Street Station", "30TH STREET": "30th Street Station", "30TH ST": "30th Street Station",
    "30TH ST. PHL.": "30th Street Station", "PHILADELPHIA 30TH STREET": "30th Street Station",
    "PHILADELPHIA WILLIAM H. GRAY III 30TH STREET": "30th Street Station",
    "PHILADELPHIA": "30th Street Station", "SUBURBAN": "Suburban Station", "JEFFERSON": "Jefferson Station",
    "PHILADELPHIA INTERNATIONAL AIRPORT": "Airport", "WILMINGTON JOSEPH R. BIDEN JR.": "Wilmington",
    "WILMINGTON JOSEPH R. BIDEN, JR. RAILROAD": "Wilmington", "WILMINGTON": "Wilmington",
    "ATLANTIC CITY RAIL TERMINAL": "Atlantic City", "ATLANTIC CITY": "Atlantic City",
    "RACE VINE STATION - BSL": "Race-Vine", "RACE VINE": "Race-Vine",
    "PRINCETON JCT.": "Princeton Junction", "MEADOWLANDS RAIL": "Meadowlands", "BROAD ST": "Newark Broad Street",
    "GROVE ST": "Grove Street", "WALTER RAND": "Walter Rand", "PENNSAUKEN RT 73": "Route 73/Pennsauken",
    "BURLINGTON TOWNE CTR": "Burlington Towne Centre", "NRG": "NRG",
    "PENNSAUKEN TRANSIT": "Pennsauken", "PENNSAUKEN": "Pennsauken", "WALTER RAND": "Walter Rand",
    # Boston
    "BOSTON SOUTH": "South Station", "BOSTON BACK BAY": "Back Bay", "BOSTON NORTH": "North Station",
    "SOUTH": "South Station", "NORTH": "North Station", "PROVIDENCE": "Providence",
    "WORCESTER UNION": "Worcester", "ROUTE 128": "Route 128",
}
SMALL_WORDS = {"of", "the", "and", "at", "on", "via"}
CAPS = {"BWI", "UMD", "NIH", "NW", "NE", "SW", "SE", "GMU", "VA", "MD", "DC", "WV", "II", "III", "NJ", "NY", "PA",
        "JFK", "MLK", "UMASS", "WTC", "US", "CT", "MA", "DE", "RI", "NRG", "MGH", "MIT", "TF", "NJPAC", "HBLR"}


def sign_priority(system):
    return (0 if system in RAPID else 1 if system in MAINLINE and system != AMTRAK else 2 if system == AMTRAK else 3, system)


def clean_station_name(raw):
    name = " ".join(raw.replace("–", "-").split())
    upper = name.upper()
    if upper in NAME_FIXES:
        return NAME_FIXES[upper]
    for _ in range(3):
        for suffix in STATION_SUFFIXES:
            if upper.endswith(suffix) and len(upper) > len(suffix) + 2:
                rest = upper[: -len(suffix)].rstrip(" -,")
                if suffix == " STATION" and rest in KEEP_STATION:
                    continue
                upper = rest
                name = name[: len(upper)]
    # Drop a trailing parenthetical direction such as "(Northbound)".
    if name.endswith(")") and "(" in name:
        inner = name[name.rindex("(") + 1:-1].lower()
        if any(w in inner for w in ("bound", "platform", "track")):
            name = name[: name.rindex("(")].rstrip()
    upper = name.upper()
    if upper in NAME_FIXES:
        return NAME_FIXES[upper]
    # Lower-case words after a slash ("Cooper Street/rutgers") or all caps → title case.
    name = re.sub(r"/([a-z])", lambda m: "/" + m.group(1).upper(), name)
    if name.upper() in CAPS:
        return name.upper()
    if name == upper or name == name.lower():
        words = []
        for i, w in enumerate(name.lower().split(" ")):
            if w.upper().rstrip(".") in CAPS:
                words.append(w.upper())
            elif i > 0 and w in SMALL_WORDS:
                words.append(w)
            elif re.fullmatch(r"\d+(st|nd|rd|th)", w):
                words.append(w)
            else:
                words.append("/".join("-".join(p[:1].upper() + p[1:] for p in part.split("-")) for part in w.split("/")))
        name = " ".join(words)
    upper = name.upper()
    if upper in NAME_FIXES:
        return NAME_FIXES[upper]
    if upper in KEEP_STATION:
        name += " Station"
    return name.replace(" Mtc", " MTC").replace("U Street/African-Amer Civil War Memorial/Cardozo", "U Street")


# ---------------------------------------------------------------- build

class Builder:
    def __init__(self, src):
        self.src = src
        self.strings = {"": 0}
        self.string_list = [""]
        self.lines = []          # [system, id, name, short, color, text, map, [route ids], feed order]
        self.line_index = {}     # line id -> index
        self.shapes = []         # (line index, points, cumulative)
        self.shape_index = {}    # (feed, shape id, reversed) -> index
        self.shape_dedupe = {}   # (line, points) -> index
        self.stations = []       # (system, name, lat, lon, rank, key)
        self.station_codes = {}  # place key -> Amtrak station code
        self.stop_ids = {}       # (system, GTFS stop_id) -> place key
        self.places = {}         # (system, name) -> [(key, lat, lon)]: same-named stations, by location
        self.place_lines = {}    # place key -> {"pos", "lines", "ends", "visits"}
        self.station_index = {}  # place key -> merged station index
        self.services = []
        self.service_index = {}  # (feed, service id) -> index
        self.service_system = {}
        self.trips = []

    def s(self, text):
        text = text or ""
        if text not in self.strings:
            self.strings[text] = len(self.string_list)
            self.string_list.append(text)
        return self.strings[text]

    def place(self, system, name, lat, lon):
        """Same-named stations of one system within 400 m are one place (a station complex);
        further apart they're different stations (New York has five "86 St")."""
        cands = self.places.setdefault((system, name), [])
        for key, la, lo in cands:
            if dist((lat, lon), (la, lo)) < 400:
                return key
        key = (system, name, len(cands))
        cands.append((key, lat, lon))
        return key

    def add_feed(self, feed_name, feed):
        if feed.inner:
            with zipfile.ZipFile(f"{self.src}/{feed.zip_path}") as outer:
                z = zipfile.ZipFile(io.BytesIO(outer.read(feed.inner)))
        else:
            z = zipfile.ZipFile(f"{self.src}/{feed.zip_path}")
        routes = {}
        for r in read_csv(z, "routes.txt"):
            spec = feed.route(r)
            if spec is not None:
                routes[r["route_id"]] = (spec, r)
        if not routes:
            raise SystemExit(f"{feed_name}: no routes")

        def line_for(route_id):
            if route_id not in routes:
                return None
            (system, key, name, short), r = routes[route_id]
            lid = f"{SYSTEM_IDS[system]}.{key}" if key != SYSTEM_IDS[system] else key
            if lid not in self.line_index:
                c = color(r.get("route_color"), 0x808080)
                text = color(r.get("route_text_color"), 0xFFFFFF if c != 0xFFFFFF else 0)
                mapc = feed.map_color if feed.map_color is not None else (MAP_COLORS["amtrak"] if system == AMTRAK else c)
                order = feed.order.index(key) if key in feed.order else len(feed.order)
                self.line_index[lid] = len(self.lines)
                self.lines.append([system, lid, name, short, c, text, mapc, [], (order, len(self.lines))])
            idx = self.line_index[lid]
            if route_id not in self.lines[idx][7]:
                self.lines[idx][7].append(route_id)
            return idx

        # Services running in the window.
        today = datetime.date.today()
        lo, hi = int(today.strftime("%Y%m%d")), int((today + datetime.timedelta(days=KEEP_DAYS)).strftime("%Y%m%d"))
        cal = {}
        for row in read_csv(z, "calendar.txt"):
            mask = sum(1 << i for i, d in enumerate(
                ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]) if row[d] == "1")
            cal[row["service_id"]] = [mask, int(row["start_date"]), int(row["end_date"]), [], []]
        for row in iter_csv(z, "calendar_dates.txt"):
            entry = cal.setdefault(row["service_id"], [0, 0, 0, [], []])
            (entry[3] if row["exception_type"].strip() == "1" else entry[4]).append(int(row["date"]))
        latest = max([c[2] for c in cal.values()] + [d for c in cal.values() for d in c[3]] + [0])
        if latest < lo:   # the whole feed has lapsed: keep it all rather than nothing
            lo = 0

        def running(sid):
            c = cal.get(sid)
            if c is None:
                return True
            return (c[0] and c[1] <= hi and c[2] >= lo) or any(lo <= d <= hi for d in c[3])

        trips = [t for t in read_csv(z, "trips.txt") if t["route_id"] in routes and running(t["service_id"])]
        trip_ids = {t["trip_id"] for t in trips}
        shape_ids = {t.get("shape_id") or "" for t in trips}
        stops = {s["stop_id"]: s for s in read_csv(z, "stops.txt")}

        # Shapes, grouped by id.
        raw_shapes = {}
        for row in iter_csv(z, "shapes.txt"):
            if row["shape_id"] in shape_ids:
                raw_shapes.setdefault(row["shape_id"], []).append(
                    (int(float(row["shape_pt_sequence"])), float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))

        # Stop times, grouped by trip.
        stop_times = {}
        for row in iter_csv(z, "stop_times.txt"):
            if row["trip_id"] in trip_ids and row["arrival_time"].strip():
                stop_times.setdefault(row["trip_id"], []).append(row)

        def stop_pos(stop_id):
            s = stops.get(stop_id)
            return (float(s["stop_lat"]), float(s["stop_lon"])) if s and s.get("stop_lat") else None

        def station_of(stop_id):
            s = stops[stop_id]
            parent = s.get("parent_station") or ""
            if parent in stops and stops[parent].get("stop_lat"):
                return stops[parent]
            return s

        place_of = {}

        def place_key(system, stop_id):
            if (system, stop_id) not in place_of:
                st = station_of(stop_id)
                name = clean_station_name(st["stop_name"])
                up = name.upper()
                if "DIVISION" in up or "NOT A STOP" in up or "EMPLOYEE" in up or up.endswith((" FACILITY", " YARD")) or not feed.is_station(name):
                    place_of[(system, stop_id)] = (None, st)   # maintenance stops
                else:
                    place_of[(system, stop_id)] = (self.place(system, name, float(st["stop_lat"]), float(st["stop_lon"])), st)
            return place_of[(system, stop_id)]

        projections = {}
        kept = 0
        feed_stations = set()
        for t in trips:
            li = line_for(t["route_id"])
            system = self.lines[li][0]
            sts = sorted(stop_times.get(t["trip_id"], []), key=lambda r: int(r["stop_sequence"]))
            sts = [r for r in sts if stop_pos(r["stop_id"]) and in_region(*stop_pos(r["stop_id"]))]
            if len(sts) < 2:
                continue

            base_key = (feed_name, t.get("shape_id") or "", False)
            if not base_key[1]:   # no shape: one per stop pattern, through the stops themselves
                base_key = (feed_name, "stops:" + "|".join(r["stop_id"] for r in sts), False)
            if base_key not in self.shape_index:
                if base_key[1].startswith("stops:"):
                    pts = [stop_pos(r["stop_id"]) for r in sts]
                else:
                    pts = crop_to_region([(lat, lon) for _, lat, lon in sorted(raw_shapes.get(base_key[1], []))])
                if len(pts) < 2:
                    pts = [stop_pos(r["stop_id"]) for r in sts]
                pts = simplify(pts, SIMPLIFY_M)
                same = (li, tuple(pts))   # feeds that give every trip its own copy of a shape
                if same not in self.shape_dedupe:
                    self.shape_dedupe[same] = len(self.shapes)
                    self.shapes.append((li, pts, cumulative(pts)))
                self.shape_index[base_key] = self.shape_dedupe[same]
            si = self.shape_index[base_key]
            # Some feeds (VRE) draw one shape per line and use it in both directions.
            _, pts, cum = self.shapes[si]
            first, _, _ = project(pts, cum, stop_pos(sts[0]["stop_id"]), 0)
            last, _, _ = project(pts, cum, stop_pos(sts[-1]["stop_id"]), 0)
            if last < first:
                rev_key = (feed_name, base_key[1], True)
                if rev_key not in self.shape_index:
                    rpts = list(reversed(pts))
                    self.shape_index[rev_key] = len(self.shapes)
                    self.shapes.append((li, rpts, cumulative(rpts)))
                si = self.shape_index[rev_key]
            _, pts, cum = self.shapes[si]

            pattern = (si, tuple(r["stop_id"] for r in sts))
            if pattern not in projections:
                arcs, seg, ok = [], 0, True
                for r in sts:
                    arc, seg, off = project(pts, cum, stop_pos(r["stop_id"]), seg)
                    if off > 600:   # stop nowhere near this shape: don't trust the pattern
                        ok = False
                        break
                    arcs.append(arc)
                projections[pattern] = arcs if ok else None
            arcs = projections[pattern]
            if arcs is None:
                continue

            service = (feed_name, t["service_id"])
            if service not in self.service_index:
                self.service_index[service] = None   # filled in below
                self.service_system[service] = system
            times = [(seconds(r["arrival_time"]), seconds(r["departure_time"] or r["arrival_time"])) for r in sts]
            keys = [place_key(system, r["stop_id"])[0] for r in sts]
            headsign = t.get("trip_headsign") or ""
            if feed.headsign:
                headsign = feed.headsign(headsign)
            self.trips.append([li, service, si, t["trip_id"], headsign, feed.number(t),
                               int(t.get("direction_id") or 0), times, arcs, keys])
            kept += 1

            for k, r in enumerate(sts):
                key, st = place_key(system, r["stop_id"])
                if key is None:
                    continue
                feed_stations.add(key)
                self.stop_ids[(system, r["stop_id"])] = key
                if st is not stops[r["stop_id"]]:
                    self.stop_ids[(system, st["stop_id"])] = key
                if system == AMTRAK:
                    self.station_codes[key] = r["stop_id"]
                entry = self.place_lines.setdefault(key, {"pos": (float(st["stop_lat"]), float(st["stop_lon"])),
                                                          "lines": set(), "ends": 0, "visits": 0})
                entry["lines"].add(li)
                entry["visits"] += 1
                if k in (0, len(sts) - 1):
                    entry["ends"] += 1

        # Services.
        for (f, sid) in list(self.service_index):
            if f != feed_name:
                continue
            self.service_index[(f, sid)] = len(self.services)
            self.services.append((self.service_system[(f, sid)], *cal.get(sid, [0, 0, 0, [], []])))
        print(f"{feed_name}: {kept} trips, {len(feed_stations)} stations", file=sys.stderr)

    def finish_stations(self):
        for key, e in self.place_lines.items():
            lat, lon = e["pos"]
            # 0: real termini (not where a few short-turn trips end); 1: transfers between lines; 2: the rest.
            if e["ends"] >= 0.3 * e["visits"]:
                rank = 0
            elif len(e["lines"]) >= 2:
                rank = 1
            else:
                rank = 2
            self.stations.append((key[0], key[1], lat, lon, rank, key))

    def merge_stations(self):
        """One marker per place: stations of different systems within 350 m share a marker, and
        stations of one system share one when they're practically on top of each other. The marker
        takes the sign of the system riders see first: metro, then commuter rail, Amtrak, light rail."""
        merged = []   # [system, name, lat, lon, rank, code, {systems}, [(system, lat, lon)]]
        for st in sorted(self.stations, key=lambda s: (s[4], s[0], s[1])):
            key = st[5]
            best, best_d = None, None
            for i, m in enumerate(merged):
                if abs(m[2] - st[2]) > 0.01 or abs(m[3] - st[3]) > 0.013:
                    continue
                for sys_id, la, lo in m[7]:
                    d = dist((st[2], st[3]), (la, lo))
                    if d < (90 if sys_id == st[0] else 350) and (best_d is None or d < best_d):
                        best, best_d = i, d
            if best is not None:
                m = merged[best]
                self.station_index[key] = best
                if key in self.station_codes:
                    m[5] = self.station_codes[key]
                m[4] = min(m[4], st[4])
                if st[0] in RAPID and m[0] not in RAPID:   # metro names are the familiar ones
                    m[1] = st[1]
                # Shared by a mainline railway and another system (Union Station, Penn Station…): a hub.
                if st[0] not in m[6] and (st[0] in MAINLINE or m[6] & MAINLINE):
                    m[4] = 0
                if sign_priority(st[0]) < sign_priority(m[0]):
                    m[0] = st[0]
                m[6].add(st[0])
                m[7].append((st[0], st[2], st[3]))
            else:
                self.station_index[key] = len(merged)
                merged.append([st[0], st[1], st[2], st[3], st[4], self.station_codes.get(key, ""), {st[0]},
                               [(st[0], st[2], st[3])]])
        for m in merged:
            if m[5] in HUB_NAMES:
                m[1] = HUB_NAMES[m[5]]
        self.stations = [m[:6] for m in merged]

    def order_lines(self):
        """Lines in drawing order within each system; trips and shapes follow."""
        order = sorted(range(len(self.lines)), key=lambda i: (self.lines[i][0], self.lines[i][8]))
        remap = {old: new for new, old in enumerate(order)}
        self.lines = [self.lines[i] for i in order]
        self.shapes = [(remap[li], pts, cum) for li, pts, cum in self.shapes]
        for t in self.trips:
            t[0] = remap[t[0]]

    def encode(self, lat0):
        out = bytearray(struct.pack("<i", round(lat0 * Q)))
        # Intern all strings first.
        for ln in self.lines:
            self.s(ln[1]); self.s(ln[2]); self.s(ln[3])
            for r in ln[7]:
                self.s(r)
        for st in self.stations:
            self.s(st[1]); self.s(st[5])
        for (_, stop_id) in self.stop_ids:
            self.s(stop_id)
        for t in self.trips:
            self.s(t[3]); self.s(t[4]); self.s(t[5])

        varint(len(self.string_list), out)
        for text in self.string_list:
            b = text.encode("utf-8")
            varint(len(b), out)
            out += b

        def u24(v):
            out.extend(struct.pack("<I", v & 0xFFFFFF)[:3])

        varint(len(self.lines), out)
        for system, lid, name, short, c, text, mapc, routes, _ in self.lines:
            out += struct.pack("<B", system)
            varint(self.s(lid), out); varint(self.s(name), out); varint(self.s(short), out)
            u24(c); u24(text); u24(mapc)
            varint(len(routes), out)
            for r in routes:
                varint(self.s(r), out)

        varint(len(self.shapes), out)
        for li, pts, _ in self.shapes:
            varint(li, out)
            varint(len(pts), out)
            plat = plon = 0
            for lat, lon in pts:
                qa, qo = round(lat * Q), round(lon * Q)
                varint(zigzag(qa - plat), out)
                varint(zigzag(qo - plon), out)
                plat, plon = qa, qo

        varint(len(self.stations), out)
        for system, name, lat, lon, rank, code in self.stations:
            out += struct.pack("<B", system)
            varint(self.s(name), out)
            out += struct.pack("<iiB", round(lat * Q), round(lon * Q), rank)
            varint(self.s(code), out)

        stops = [(sysid, stop_id, self.station_index[key]) for (sysid, stop_id), key in self.stop_ids.items()
                 if key in self.station_index]
        varint(len(stops), out)
        for sysid, stop_id, idx in stops:
            out += struct.pack("<B", sysid)
            varint(self.s(stop_id), out)
            varint(idx, out)

        varint(len(self.services), out)
        for system, mask, start, end, added, removed in self.services:
            out += struct.pack("<BBII", system, mask, start, end)
            varint(len(added), out)
            for d in sorted(added):
                out += struct.pack("<I", d)
            varint(len(removed), out)
            for d in sorted(removed):
                out += struct.pack("<I", d)

        varint(len(self.trips), out)
        for li, service, si, trip_id, headsign, number, direction, times, arcs, keys in self.trips:
            varint(li, out)
            varint(self.service_index[service], out)
            varint(si, out)
            varint(self.s(trip_id), out)
            varint(self.s(headsign), out)
            varint(self.s(number), out)
            out += struct.pack("<B", direction)
            varint(len(times), out)
            prev_dep, prev_arc = 0, 0
            for (arr, dep), arc, key in zip(times, arcs, keys):
                arr = max(arr, prev_dep)
                dep = max(dep, arr)
                varint(arr - prev_dep, out)
                varint(dep - arr, out)
                a = max(prev_arc, int(round(arc)))   # trains never run backwards along their shape
                varint(a - prev_arc, out)
                varint(self.station_index[key] + 1 if key in self.station_index else 0, out)
                prev_dep, prev_arc = dep, a
        return out


def main():
    global RAIL_REGION, LOCAL
    src, dst = sys.argv[1], sys.argv[2]
    region = sys.argv[3] if len(sys.argv) > 3 else "dcbal"
    NAME_FIXES.update(REGION_FIXES.get(region, {}))
    RAIL_REGION = REGION_BOXES[region]
    LOCAL = Local((RAIL_REGION[0] + RAIL_REGION[1]) / 2)
    b = Builder(src)
    for i, feed in enumerate(feeds_for(region)):
        b.add_feed(f"{feed.zip_path}:{feed.inner or ''}:{i}", feed)
    b.finish_stations()
    b.merge_stations()
    b.order_lines()
    if "--names" in sys.argv:   # for checking how stations came out
        for st in sorted(b.stations, key=lambda s: (s[0], s[1])):
            print(f"{st[0]:2} r{st[4]} {st[5] or '   '} {st[1]}")
    payload = b.encode((RAIL_REGION[0] + RAIL_REGION[1]) / 2)
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = comp.compress(bytes(payload)) + comp.flush()
    with open(dst, "wb") as f:
        f.write(b"TSRL" + bytes([3]) + data)
    print(f"lines {len(b.lines)}, shapes {len(b.shapes)} ({sum(len(s[1]) for s in b.shapes)} points), "
          f"stations {len(b.stations)}, services {len(b.services)}, trips {len(b.trips)}", file=sys.stderr)
    print(f"raw {len(payload)} bytes -> {len(data)} compressed", file=sys.stderr)


if __name__ == "__main__":
    main()
