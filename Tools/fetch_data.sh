#!/bin/sh
# Downloads the source data for Resources/geodata-*.bin and Resources/rail-*.bin into $1.
set -eu
DIR="${1:?usage: fetch_data.sh <download-dir>}"
mkdir -p "$DIR"

# Base map: Natural Earth 10m (public domain).
NE=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson
for f in ne_10m_land ne_10m_lakes ne_10m_lakes_north_america \
         ne_10m_rivers_lake_centerlines ne_10m_rivers_north_america \
         ne_10m_urban_areas ne_10m_roads ne_10m_admin_1_states_provinces_lines; do
  [ -s "$DIR/$f.geojson" ] || curl -fsSL -o "$DIR/$f.geojson" "$NE/$f.geojson"
done

# Rail networks and timetables: each agency's static GTFS.
get() { curl -fsSL -A "Trainspace/1.0" -o "$DIR/$1.zip" "$2"; }
# DC–Baltimore. WMATA's own static feed needs an API key; the Mobility Database mirrors it openly.
get wmata https://files.mobilitydatabase.org/mdb-1847/latest.zip
get marc https://feeds.mta.maryland.gov/gtfs/marc
get lightrail https://feeds.mta.maryland.gov/gtfs/light-rail
get subway https://feeds.mta.maryland.gov/gtfs/metro
get vre https://gtfs.vre.org/containercdngtfsupload/google_transit.zip
get amtrak https://content.amtrak.com/content/gtfs/GTFS.zip
# New York (the subway feed includes the Staten Island Railway).
get nyct-subway https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip
get lirr https://rrgtfsfeeds.s3.amazonaws.com/gtfslirr.zip
get mnr https://rrgtfsfeeds.s3.amazonaws.com/gtfsmnr.zip
get path https://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip
# NJ TRANSIT's own feed needs a developer login; the Mobility Database mirrors rail + light rail.
get njt-rail https://files.mobilitydatabase.org/mdb-509/latest.zip
# Philadelphia (SEPTA publishes rail and bus/trolley/metro as two zips inside one).
get septa https://github.com/septadev/GTFS/releases/latest/download/gtfs_public.zip
get patco https://files.mobilitydatabase.org/mdb-3035/latest.zip
# Boston.
get mbta https://cdn.mbta.com/MBTA_GTFS.zip
