# Trainspace

Every train in DC–Baltimore, New York, Philadelphia and Boston, live, as your macOS wallpaper.

Each region's railways are drawn as small lit cars moving along a quiet map of their own
track, in the spirit of the Design Rules Co. Metroboard:

| Region | Systems |
|---|---|
| DC–Baltimore | Metrorail, MARC, VRE, Amtrak, Light RailLink, Metro SubwayLink |
| New York | Subway, Staten Island Railway, LIRR, Metro-North, NJ TRANSIT rail and light rail (Hudson-Bergen, Newark), PATH, Amtrak |
| Philadelphia | SEPTA Regional Rail, SEPTA Metro (L, B, trolleys, D, G, M), PATCO, NJ TRANSIT (Atlantic City Line, RiverLINE), Amtrak |
| Boston | MBTA subway (Red, Orange, Blue, Green B–E, Mattapan), MBTA Commuter Rail, Amtrak |

Pick the region in the menu bar, Settings › Location or the welcome window; choosing a place
(or following your location) inside another region switches to it. Trainspace is Airspace's sibling: the same desktop-window engine,
appearance system and settings, with trains instead of planes. It sits behind your desktop
icons on every Space and display, never takes clicks, and idles when it's covered, locked, or
on battery.

## Features

- **Every system, one map per region:**
  - The real track of every line, from each agency's GTFS shapes.
  - Stations named by importance as you zoom in.
  - Trains snapped to the track; between updates they keep moving *along* it, around curves.
- **Live where possible, timetable everywhere else:**
  - MARC, VRE, MTA (subway, Staten Island, LIRR, Metro-North), SEPTA and MBTA are live
    with no setup. Amtrak runs on its published timetable unless you turn on live Amtrak
    (Settings › Live Data), which reads Amtrak's Track-a-Train map feed and is unofficial. New York's subway feeds give arrival predictions but no positions (there's
    no GPS underground), so subway trains are placed along their timetabled trip, shifted by
    how late the predictions say they're running; Metro-North's trains without a position are
    placed the same way.
  - Metrorail, Light RailLink and Metro SubwayLink go live once you paste your own free API
    keys (the welcome window's second step, or Settings › Live Data). They're optional:
    without them those lines run on the timetable.
  - NJ TRANSIT (needs a developer account), PATH (publishes only station arrival times) and
    PATCO (publishes nothing live) run on the timetable. So do lines a live feed leaves out:
    SEPTA's feed carries its trolleys but not the L and B, which come from the timetable.
  - Until then, or whenever a feed fails, those trains are placed where the bundled timetable
    says they should be, drawn hollow.
- **Station view:** pick any station and the wallpaper becomes its departures, over a
  close-up map with the station centered beside the boards:
  - **Big stations** (Washington Union Station, Baltimore Penn Station, New York Penn Station,
    Grand Central, Philadelphia's 30th Street, Boston South Station): a split-flap departures
    board for the commuter and intercity trains. Flaps roll through the alphabet when a row
    changes. Remarks ("ON TIME", "LATE 12 MIN", "CANCELLED") come from each railway's trip
    updates.
  - **Commuter rail stations** (MARC, VRE, LIRR, Metro-North, NJ TRANSIT, SEPTA, MBTA, Amtrak):
    an amber LED board with train, destination, time and status.
  - **Metro and light rail stations:** an amber LED countdown: a dot in the line's color, the
    line's name ("RD", "A", "L1"), the destination and the minutes, down to `DUE`.
  - The station's name sign on top.
  - **The station nearest me** (Settings › Station View, or "Nearest to Me" in the station
    menu): follows your location and shows whichever station is closest, among the systems
    you check. It switches only when another station is clearly closer (about 150 m), and
    beyond 5 miles from any checked station shows the network map around you. Your location
    is only compared with the bundled station list.

  Departure times come from the bundled timetables; countdown signs order trains by their live
  estimate. Delays come from live data where there is any.
- **Station signs:** every station is named on a small sign in Trainspace's own style: white
  Avenir Next on a dark plate, a stripe in the line's color at the leading edge, and a plain
  dot for each line (one per railway on commuter and intercity rail). Amtrak stations give the
  city and state. Signs that can't sit beside their station move out onto a thin leader line.
  Turn this off in Settings › Map › Details.

  The signs and boards are deliberately generic: no agency's sign design, typeface, route
  bullets or logos are copied. Line colors come from each agency's GTFS. The LED boards are
  drawn dot by dot from an original 5×8 dot-matrix face.
- **Three map styles:**
  - **Schematic:** land, water, roads and the rail network from bundled data; works offline.
  - **Apple Map:** muted, desaturated MapKit with the network on top, aligned to the street.
  - **Pure field:** dots and track only.
- **Light, dark or dynamic appearance:**
  - **Aluminum** (light) and **Night** (dark).
  - **Dynamic** follows either the macOS appearance or the sun, fading through civil twilight.
- **Color by line** (default): every line in its agency's own color (from GTFS), lifted for the
  dark palette and deepened for the light one. DC keeps its hand-tuned hues; MARC and VRE are
  drawn apart from the Metrorail lines they share stations with, and Amtrak is neutral. You can
  also color by system or use one color for everything.
- **Train icons:** a car pointing the way it's heading, with a headlight at the front.
  Commuter and intercity trains are longer than metro cars. Points of light and arrows are
  also available.
- **Station Lights** (Settings › Trains › Icon): instead of moving trains, every station becomes
  a small pill of LED dots: a pair for each line group, one dot per direction. A train lights the
  dot at its station in its line's color: steady while it's at the platform, blinking while it's
  on the way in or out. Transfer stations get a pair per line group (Metro Center: Red, then
  Orange/Blue/Silver; Union Station: Red, MARC, VRE, Amtrak). It works with every map style,
  both appearances, and station view.
- **Labels and trails:** "RD SHADY GROVE", "MARC 677 UNION STATION", "AMTK 164 BOSTON",
  placed so they don't collide with each other or with station names. Trails fade over 1, 3
  or 10 minutes.
- **Places:** presets for each region (Washington, Baltimore; Manhattan, Midtown; Philadelphia,
  Center City; Boston, Downtown; and each whole network); system location;
  a zip code, neighborhood or station; or typed coordinates. Zoom from 2 to 60 miles.
- **Info corner:** place, time, trains in view, a key of the lines in view, and the nearest
  train with its line, destination, speed and distance.
- **Menu bar match, power awareness, launch at login:** as in Airspace.

## Build & run

You only need the Swift toolchain (the Command Line Tools are enough).

```sh
make run         # build, bundle into build/Trainspace.app (ad-hoc signed), launch
make install     # build and copy into /Applications
make test        # unit tests (Swift Testing)
make snapshots   # render every style/appearance into build/snapshots
swift run -c release Trainspace --snapshots build/snapshots --time 2026-11-10T08:30   # timetable at rush hour
swift run -c release Trainspace --render-settings build/settings                      # Settings window, every section
make data        # re-download GTFS + Natural Earth and rebuild Resources/*.bin
```

Switch between the network map and a station's boards from the menu bar (**View**) or
Settings › Station View. On first launch a welcome window previews Washington. Pick a place and click
**Set as Wallpaper**. After that, everything lives in the menu-bar item and **Settings…**.

### API keys (optional, free)

| System | Key | Where |
|---|---|---|
| Metrorail | WMATA API key | [developer.wmata.com](https://developer.wmata.com) (Products › Default Tier) |
| Light RailLink, Metro SubwayLink | Swiftly API key | [MTA developer resources](https://www.mta.maryland.gov/developer-resources) → request a Swiftly key |

Each person requests their own keys; Trainspace never ships or shares one. Keys are stored in
your login keychain and sent only to their own feed. Everything else that's live needs none.

### Distributing

Trainspace is free and ships without the paid Apple Developer Program. `make release` builds a
universal app (Apple Silicon and Intel) signed with a self-signed certificate, and writes a
zip, a DMG, `SHA256SUMS` and a one-line Terminal installer (`install.sh`). The steps and the
certificate are in [RELEASING.md](RELEASING.md). The app is sandboxed and asks only for
network access and location.

Because it isn't notarized, a DMG downloaded in a browser needs one approval in System
Settings › Privacy & Security › Open Anyway. The installer downloads with curl, so it doesn't:

```sh
curl -fsSL https://github.com/grantkovich/trainspace-desktop-dynamic-wallpaper/releases/latest/download/install.sh | sh
```

Run `make data` before a release so the bundled timetables are current. If a timetable runs
past its end date, Trainspace reuses the same weekday from its last weeks.

## How it works

```
Sources/TrainspaceCore   UI-free logic: GTFS-Realtime decoding, Amtrak feed decryption, the rail
                         network and timetable, schedule estimation, track snapping, tracker +
                         motion smoothing, projection, power policy, settings, palettes, geometry
Sources/Trainspace       AppKit/SwiftUI app: desktop windows, layers, menu bar, settings
Tools/                   data builders (GTFS + Natural Earth → Resources/rail-<region>.bin,
                         geodata-<region>.bin for dcbal, nyc, phl, bos)
```

- **Feeds:** each system polls on its own clock, never faster than the feed updates:
  - WMATA every 10 s.
  - MARC, Light Rail, Subway and MBTA every 15 s.
  - MTA (all eight subway feeds together, SIR, LIRR, Metro-North) and SEPTA every 30 s.
  - VRE once a minute, as VRE asks.
  - Amtrak every 2 minutes (each response is ~0.8 MB).

  After three failures in a row a system falls back to the timetable, and it keeps retrying
  with backoff. A rejected key stops retries until the key changes.
- **Amtrak:** there's no official API. The Track-a-Train map's feed is AES-encrypted with
  key material the map publishes. Trainspace derives the keys the same way the map does and
  decrypts with CommonCrypto (PBKDF2-SHA1 → AES-128-CBC), as community trackers such as
  Amtraker do.
- **Motion:** each fix is snapped to the nearest track of its line (a 500 m grid index over
  every shape). The train then advances along the track at its reported or estimated speed,
  for up to about one feed interval, so it doesn't sail through a station it has stopped at.
  When a new fix arrives, the train eases to it over 1.6 s.
- **Departure boards:** `DepartureBoard` indexes every timetabled call at every station.
  It lists the next departures for the systems on each board, then applies live data:
  - GTFS-Realtime trip updates matched by stop (a delay carries forward from the last
    reported stop).
  - Amtrak's per-station estimates (`estdep`, and `postdep` once a train has left).

  Trip updates are only fetched while a station is on screen.
- **Timetable:** `ScheduleEstimator` finds trips running now (including yesterday's trips past
  midnight), interpolates along each trip's shape between stop times, and holds trains at
  stations during dwell time.
- **Layers and power:** as in Airspace. The base map, animated trains and info corner are
  separate layers. The default is 20 fps; drawing stops when windows cover the desktop, and
  everything stops when the screen is locked or asleep.
- **Diagnostics:** every 30 s the app logs its render mode, frames and per-system feed state:
  `log stream --level info --predicate 'subsystem == "com.grantkovich.trainspace"'`.

## Data

- **Live:**
  - [WMATA GTFS-RT](https://developer.wmata.com).
  - MDOT MTA: MARC GTFS-RT, plus Light Rail and Metro via [Swiftly](https://www.goswift.ly).
  - [VRE GTFS-RT](https://www.vre.org).
  - Amtrak's [Track-a-Train](https://www.amtrak.com/track-your-train.html) map feed.
  - [MTA](https://api.mta.info) subway, Staten Island Railway, LIRR and Metro-North GTFS-RT.
  - [SEPTA](https://www3.septa.org/gtfsrt/) Regional Rail and bus/trolley GTFS-RT.
  - [MBTA](https://www.mbta.com/developers/gtfs-realtime) vehicle positions and trip updates.
- **Track, stations, timetables:** each agency's static GTFS (see `Tools/fetch_data.sh`). WMATA's,
  NJ TRANSIT's and PATCO's come from the [Mobility Database](https://mobilitydatabase.org) mirror,
  because the agencies' own copies need a login. Stations of different systems within 350 m share
  one marker (Penn Station: subway, LIRR, NJ TRANSIT, Amtrak), named for the metro station.
- **Base map:** [Natural Earth](https://www.naturalearthdata.com) 10m (public domain), clipped to each region.

Only API keys go to the feed providers. Your location isn't sent to any train feed; Apple receives it to look up place names and, with the Apple Map style, to load the map.

## License

MIT, see [LICENSE](LICENSE). The data keeps its own licenses (see the
Data section and the app's About panel).
