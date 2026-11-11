# Trainspace: live DC–Baltimore train wallpaper for macOS

Date: 2026-11-08
Status: built from the request "the same app as Airspace, but for trains in the DC–Baltimore
area: VRE, MARC, Amtrak, Baltimore Light Rail, DC Metro, Baltimore Metro Subway."

## Intent

Airspace's object-like live wallpaper, with trains instead of planes. Keep Airspace's
architecture, look and settings: desktop-level click-through windows, layered rendering, power
policy, Aluminum/Night/Dynamic palettes, info corner, menu-bar match. Change only what trains
need.

## What differs from Airspace

| Airspace | Trainspace | Why |
|---|---|---|
| One feed (adsb.lol → adsb.fi fallback) | One source per system, each on its own interval, with fallback to the timetable | Six agencies, three formats, very different update rates |
| Straight-line dead reckoning | Snap to track, advance along the track | Trains follow curves and stop at stations |
| Airports and runways on the map | Every line's track and stations, colored by line | The network *is* the map |
| Color by airline (4 slots) | Color by line: official Metrorail colors plus one hue per other system | Riders know the Red Line is red; the systems mostly don't overlap in space |
| Plane icons by airframe | Car icons: mainline longer than metro and light rail; hollow when from the timetable | Live and estimated positions should be distinguishable |
| Zoom 5–150 mi | Zoom 2–60 mi, plus place presets | A metro region, not a sky |

## Data sources (verified 2026-11-08)

| System | Live | Key | Static (track, stations, timetable) |
|---|---|---|---|
| Metrorail | `api.wmata.com/gtfs/rail-gtfsrt-vehiclepositions.pb` | WMATA (free) | Mobility Database mirror mdb-1847 (WMATA's own copy needs a key) |
| MARC | `mdotmta-gtfs-rt.s3.amazonaws.com/MARC+RT/marc-vp.pb` | none | feeds.mta.maryland.gov/gtfs/marc |
| VRE | `gtfs.vre.org/containercdngtfsupload/VehiclePositionFeed` (≤ 1/min) | none | gtfs.vre.org/…/google_transit.zip |
| Amtrak | `maps.amtrak.com/services/MapDataService/trains/getTrainsData` (encrypted) | none | content.amtrak.com/content/gtfs/GTFS.zip, cropped to the region |
| Light RailLink | Swiftly `mta-maryland-light-rail` | Swiftly (free, via MTA) | feeds.mta.maryland.gov/gtfs/light-rail |
| Metro SubwayLink | Swiftly `mta-maryland-metro` | Swiftly (free, via MTA) | feeds.mta.maryland.gov/gtfs/metro |

Amtraker (api-v3.amtraker.com) was down (503) during the build, so Trainspace decrypts
Amtrak's map feed directly: public key = `arr[Σ ZoomLevel]` from RoutesList(.v).json,
salt = `s[len(s[0])]`, IV = `v[len(v[0])]`; PBKDF2-SHA1 ×1000 → AES-128-CBC; the last 88
base64 characters carry the per-response private key. It falls back to the long-published
constants if the key files can't be fetched.

## Decisions

- **No key, still alive.** Timetable estimates for keyless systems mean the wallpaper is full
  on first launch. They're drawn hollow, and the legend says so.
- **Bundled data.** `rail.bin` (~250 KB) and `geodata.bin` (~60 KB) are built by Tools/ from
  GTFS and Natural Earth. An expired timetable reuses the same weekday from its last weeks.
- **Keys in the keychain**, not in UserDefaults.
- **Station tiers:** 0 = hub or terminal (named out to 30 mi), 1 = transfer between lines (10 mi),
  2 = other (4.5 mi; dot hidden past 16 mi). Names avoid the info corner and each other.
- **First run** previews Washington and asks for location only when "Use My Location" is clicked.

## Testing

- 57 Swift Testing tests in TrainspaceCore: GTFS-RT decoding (captured MARC fixture), Amtrak
  decryption (fixture encrypted with openssl the same way Amtrak does), key derivation, the
  bundled network, schedule interpolation, calendars, past-midnight trips and expired-timetable
  fallback, track snapping and along-track motion, tracker easing, staleness and trails,
  settings, projection, label layout and power policy.
- Headless snapshots of every style and appearance, and an offscreen Settings render.

## Addition: station view and agency signage (2026-11-08)

Request: use each line's own fonts and signage, and let the wallpaper zoom in on one station
with its timetable. Union Station and Penn Station should get an old-school departures board;
other stops should match the signs in their stations.

- **`ViewMode.station`** plus `stationKey` and `stationZoomMiles`. The map centers the station in
  the open part of the screen, beside the boards. The info corner is replaced by the station panel.
- **rail.bin v2** adds the station for every timetabled stop, Amtrak station codes, and a GTFS
  `stop_id` → station table, for matching live trip updates.
- **Amtrak GTFS filtering:** Amtrak's GTFS includes MARC, VIA and Thruway buses under other
  agencies. Only `agency_id 51` with `route_type 2` counts as Amtrak (it had been double-counting
  MARC trips).
- **`DepartureBoard`** (core, tested) returns the next departures per station and system. Live
  corrections come from GTFS-RT `TripUpdate` (MARC and VRE without a key; WMATA and Swiftly with
  one) and from Amtrak's per-station `estdep`/`postdep`, already in the map feed it polls.
- **Boards:**

  | Where | Board |
  |---|---|
  | WAS, BAL | split-flap, 10 rows: TIME · TRAIN · NO. · DESTINATION · REMARKS |
  | Metrorail | orange LED: LN · CAR · DEST · MIN, with ARR/BRD and WMATA's abbreviations. CAR is shown as "-" because no feed gives car counts |
  | MARC/VRE/Amtrak platforms | amber LED: TRAIN · TO · DEPART · status |
  | Light Rail / Subway | red LED: destination · minutes |

- **Type:** Helvetica (WMATA's signage face, available on macOS) for Metrorail. Helvetica Neue
  for MDOT MTA and VRE. Avenir Next for Amtrak (Frutiger isn't on macOS). Condensed Helvetica on
  the flaps. The LED glyphs are an original 5×8 dot-matrix table rendered as dots. Signs use
  official line colors; no logos.
- **Known gaps:** track numbers aren't in any feed, so the boards have no TRACK column. Without a
  WMATA key, Metrorail times are from the timetable.

## Regions (added 2026-11-09)

Four regions, each a bundled pair `Resources/rail-<id>.bin` + `geodata-<id>.bin`
(`dcbal`, `nyc`, `phl`, `bos`), built by `Tools/build_rail.py <src> <out> <region>` and
`Tools/build_geodata.py <src> <out> <region>`. Only the chosen region's network is loaded.

- **Systems** are data (`TransitSystem` in `Systems.swift`): a stable raw id stored in the network
  files and settings, plus name, operator, kind (rapid transit, light rail, commuter, intercity),
  label prefix and system colour. `Region` lists each region's systems, presets, hubs, default
  station and bounds; a place inside another region's bounds switches to it.
- **Colours** come from each line's GTFS `route_color`/`route_text_color` (rail.bin v3 stores colour,
  text colour and map colour). `Palette.lineColor` lifts colours for Night and deepens them for
  Aluminum, keeping DC's hand-tuned pairs.
- **Stations** are clustered per system by name within 400 m (station complexes), and merged across
  systems within 350 m into one marker; keys get `#2`, `#3` suffixes where one system repeats a
  name (New York's "86 St"). The marker takes the sign of the system riders see first: metro, then
  commuter rail, Amtrak, light rail.
- **Live positions without GPS:** NYCT's feeds have trip updates but no positions.
  `PredictionFeedSource` matches each trip to the timetable (origin time, route and direction from
  the trip id), shifts it by the delay at its next predicted stop, and places it along the shape.
  Lines a live feed leaves out are filled from the timetable.
- **Signs and boards:** `StationSigns.style` holds each railway's sign (font, field, lead device,
  marks); `BoardStyle.countdown` covers the new metros' platform signs.
