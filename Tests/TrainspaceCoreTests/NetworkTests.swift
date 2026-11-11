import Foundation
import Testing
@testable import TrainspaceCore

private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Resources").standardizedFileURL

@Suite struct RailNetworkTests {
    nonisolated(unsafe) private static var cached: RailNetwork?
    static func network() throws -> RailNetwork {
        if let cached { return cached }
        let n = try RailNetwork.load(from: resources.appendingPathComponent("rail-dcbal.bin"))
        cached = n
        return n
    }

    @Test func hasEverySystemAndMetroLine() throws {
        let n = try Self.network()
        #expect(Set(n.lines.map(\.system)) == Set(Region.dcBaltimore.systems))
        for id in ["metrorail.red", "metrorail.orange", "metrorail.blue", "metrorail.green", "metrorail.yellow",
                   "metrorail.silver", "marc.penn", "marc.camden", "marc.brunswick", "vre.fredericksburg", "vre.manassas",
                   "amtrak", "lightrail", "subway"] {
            #expect(n.line(id: id) != nil, "missing \(id)")
        }
        #expect(n.line(system: .metrorail, routeID: "RED").map { n.lines[$0].color } == 0xC80F2D)
        // MARC's own orange is for its signs; the map draws it in its own hue, apart from the Orange Line.
        let penn = try #require(n.line(id: "marc.penn").map { n.lines[$0] })
        #expect(penn.color == 0xFF8000 && penn.mapColor != penn.color)
    }

    @Test func stationsAreWhereTheyShouldBe() throws {
        let n = try Self.network()
        let union = try #require(n.stations.first { $0.name == "Union Station" })
        #expect(Geo.distanceNM(union.position, Coordinate(latitude: 38.8977, longitude: -77.0063)) < 0.3)
        #expect(union.rank == 0)
        #expect(n.stations.contains { $0.name == "Penn Station" })
        #expect(n.stations.contains { $0.name == "Hunt Valley" && $0.system == .lightRail })
    }

    @Test func shapesStayInTheRegion() throws {
        let n = try Self.network()
        #expect(n.coverage.contains(Coordinate(latitude: 38.9, longitude: -77.03)))
        #expect(n.coverage.contains(Coordinate(latitude: 39.29, longitude: -76.61)))
        #expect(!n.coverage.contains(Coordinate(latitude: 41.88, longitude: -87.63)))
        for s in n.shapes { #expect(s.points.count >= 2) }
    }

    @Test func tripsHaveMonotonicTimesAndDistances() throws {
        let n = try Self.network()
        #expect(n.trips.count > 10_000)
        for t in n.trips.prefix(2_000) {
            for (a, b) in zip(t.stops, t.stops.dropFirst()) {
                #expect(a.departure <= b.arrival)
                #expect(a.distance <= b.distance)
            }
            #expect(Double(t.stops.last!.distance) <= n.shapes[t.shape].length + 1)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try RailNetwork.decode(Data("nope".utf8)) }
        #expect(throws: (any Error).self) { try GeoData.decode(Data("TSRL\u{1}".utf8)) }
    }

    @Test func baseMapLoads() throws {
        let geo = try GeoData.load(from: resources.appendingPathComponent("geodata-dcbal.bin"))
        let dc = GeoBounds(minLat: 38.8, maxLat: 39.0, minLon: -77.2, maxLon: -76.9)
        #expect(geo.features(.land, in: dc).isEmpty == false)
        #expect(geo.features(.rivers, in: dc).isEmpty == false)   // the Potomac
    }
}

// MARK: - Synthetic network

/// A line running due north from (38.9, -77.0) for ~2.2 km, then due east for ~1.7 km.
func lNetwork() -> RailNetwork {
    let pts: [GeoPoint] = [GeoPoint(38.90, -77.00), GeoPoint(38.92, -77.00), GeoPoint(38.92, -76.98)]
    let line = RailLine(id: "metrorail.red", system: .metrorail, name: "Red Line", shortName: "RD", color: 0xC80F2D, routeIDs: ["RED"])
    let shape = RailShape(line: 0, points: pts)
    let len = Float(shape.length)
    let corner = shape.distances[1]
    let weekdays = ServiceCalendar(system: .metrorail, weekdays: 0b0011111, start: 20260101, end: 20261231, added: [], removed: [20261126])
    let stops = [StopTime(arrival: 8 * 3600, departure: 8 * 3600, distance: 0),
                 StopTime(arrival: 8 * 3600 + 100, departure: 8 * 3600 + 130, distance: corner),
                 StopTime(arrival: 8 * 3600 + 230, departure: 8 * 3600 + 230, distance: len)]
    let trip = ScheduledTrip(line: 0, service: 0, shape: 0, tripID: "t1", headsign: "GLENMONT", trainNumber: "101",
                             direction: 0, stops: stops)
    let late = ScheduledTrip(line: 0, service: 0, shape: 0, tripID: "t2", headsign: "Glenmont", trainNumber: "",
                             direction: 0, stops: stops.map { StopTime(arrival: $0.arrival + 16 * 3600, departure: $0.departure + 16 * 3600, distance: $0.distance) })
    return RailNetwork(lines: [line], shapes: [shape],
                       stations: [Station(system: .metrorail, name: "A", position: Coordinate(latitude: 38.9, longitude: -77), rank: 0)],
                       services: [weekdays], trips: [trip, late])
}

private func eastern(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: s)!
}

@Suite struct ScheduleTests {
    let estimator = ScheduleEstimator(network: lNetwork())

    @Test func interpolatesBetweenStops() throws {
        // Wednesday 2026-11-04, 08:00:50 Eastern (EST, UTC−5): halfway up the first leg.
        let trains = estimator.trains(at: eastern("2026-11-04T13:00:50Z"), systems: [.metrorail])
        let t = try #require(trains.first)
        #expect(trains.count == 1)
        #expect(abs(t.position.latitude - 38.91) < 0.0005)
        #expect(abs(t.position.longitude + 77.0) < 0.0001)
        #expect(abs((t.bearingDeg ?? -1) - 0) < 1)
        #expect(t.status == .moving)
        #expect(t.isScheduled)
        #expect(t.headsign == "GLENMONT")
        #expect(t.trainNumber == "101")
        // ~2.2 km in 100 s ≈ 49 mph
        #expect(abs((t.speedMph ?? 0) - 49.7) < 2)
    }

    @Test func dwellsAtStations() throws {
        let t = try #require(estimator.trains(at: eastern("2026-11-04T13:01:55Z"), systems: [.metrorail]).first)
        #expect(t.status == .stopped)
        #expect(t.speedMph == 0)
        #expect(abs(t.position.latitude - 38.92) < 0.0002)
    }

    @Test func respectsCalendar() {
        // Saturday: no weekday service. Thanksgiving: removed. Other systems: none.
        #expect(estimator.trains(at: eastern("2026-11-07T13:00:50Z"), systems: [.metrorail]).isEmpty)
        #expect(estimator.trains(at: eastern("2026-11-26T13:00:50Z"), systems: [.metrorail]).isEmpty)
        #expect(estimator.trains(at: eastern("2026-11-04T13:00:50Z"), systems: [.marc]).isEmpty)
    }

    @Test func tripsPastMidnightRunOnTheServiceDay() throws {
        // Trip t2 leaves at 24:00 of Wednesday's service day, i.e. 00:00:50 Thursday.
        let trains = estimator.trains(at: eastern("2026-11-05T05:00:50Z"), systems: [.metrorail])
        #expect(trains.count == 1)
        #expect(trains.first?.id.hasSuffix("t2") == true)
        #expect(trains.first?.id.contains("20261104") == true)
    }

    @Test func expiredTimetableFallsBackToSameWeekday() {
        // A Wednesday in 2027, after the service's end date.
        #expect(estimator.trains(at: eastern("2027-03-03T13:00:50Z"), systems: [.metrorail]).count == 1)
        // …but still not on a Saturday.
        #expect(estimator.trains(at: eastern("2027-03-06T13:00:50Z"), systems: [.metrorail]).isEmpty)
    }

    @Test func realTimetableHasMetroOnAWeekdayMorning() throws {
        let real = ScheduleEstimator(network: try RailNetworkTests.network())
        let date = eastern("2026-11-10T13:30:00Z")   // Tuesday 08:30 EST
        let metro = real.trains(at: date, systems: [.metrorail])
        #expect(metro.count > 40)
        #expect(Set(metro.compactMap(\.line)).count == 6)
        #expect(real.trains(at: date, systems: [.marc]).count > 3)
        #expect(real.trains(at: date, systems: [.vre]).count >= 1)
        #expect(real.trains(at: date, systems: [.lightRail]).count > 3)
        #expect(real.trains(at: date, systems: [.subway]).count > 3)
    }
}

@Suite struct TrackIndexTests {
    let network = lNetwork()
    var index: TrackIndex { TrackIndex(network: network) }

    @Test func snapsToNearestTrack() throws {
        let hit = try #require(index.nearest(Coordinate(latitude: 38.91, longitude: -77.0005)))
        #expect(abs(hit.coordinate.longitude + 77.0) < 1e-6)
        #expect(hit.distanceMeters < 50)
        #expect(abs(hit.trackBearing) < 1)
        #expect(index.nearest(Coordinate(latitude: 38.91, longitude: -76.95)) == nil)   // > 300 m away
        #expect(index.nearest(Coordinate(latitude: 38.91, longitude: -77.0005), system: .marc) == nil)
    }

    @Test func advancesAroundCorners() throws {
        let start = try #require(index.nearest(Coordinate(latitude: 38.919, longitude: -77.0)))
        // ~111 m to the corner, then east.
        let (p, heading) = index.advance(from: start, bearing: 0, meters: 611)
        #expect(abs(p.latitude - 38.92) < 1e-4)
        #expect(p.longitude > -77.0 + 0.005)
        #expect(abs(heading - 90) < 1)
        // Heading south goes the other way along the same track.
        let (back, backHeading) = index.advance(from: start, bearing: 180, meters: 1_000)
        #expect(back.latitude < 38.919)
        #expect(abs(backHeading - 180) < 1)
        // Stops at the end of the line.
        let (end, _) = index.advance(from: start, bearing: 0, meters: 1e6)
        #expect(abs(end.longitude + 76.98) < 1e-5)
    }
}

@Suite struct TrackerTests {
    private func report(_ id: String = "a", lat: Double, lon: Double = -77.0, speed: Double? = nil, bearing: Double? = nil,
                        t: TimeInterval) -> TrainReport {
        TrainReport(id: id, system: .metrorail, line: 0, position: Coordinate(latitude: lat, longitude: lon),
                    bearingDeg: bearing, speedMph: speed, fixTime: t)
    }

    @Test func newTrainFadesIn() {
        var tracker = TrainTracker(track: TrackIndex(network: lNetwork()))
        tracker.ingest([report(lat: 38.905, t: 100)], at: 100, extrapolation: 30)
        #expect(tracker.snapshot(at: 100).first?.opacity == 0)
        #expect(tracker.snapshot(at: 101).first?.opacity == 1)
    }

    @Test func estimatesVelocityAndFollowsTheTrack() throws {
        var tracker = TrainTracker(track: TrackIndex(network: lNetwork()))
        tracker.ingest([report(lat: 38.910, t: 0)], at: 0, extrapolation: 60)
        tracker.ingest([report(lat: 38.915, t: 30)], at: 30, extrapolation: 60)   // ~555 m in 30 s, northbound
        // 40 s after the second fix the straight-line projection would overshoot the corner;
        // on the track it turns east instead.
        let d = try #require(tracker.snapshot(at: 70).first)
        #expect(abs(d.position.latitude - 38.92) < 2e-4)
        #expect(d.position.longitude > -77.0)
        #expect(abs((d.heading ?? 0) - 90) < 1)
    }

    @Test func extrapolationIsCapped() throws {
        var tracker = TrainTracker(track: TrackIndex(network: lNetwork()))
        tracker.ingest([report(lat: 38.905, speed: 22.37, bearing: 0, t: 0)], at: 0, extrapolation: 10)   // 10 m/s
        let at10 = try #require(tracker.snapshot(at: 10).first).position
        let at100 = try #require(tracker.snapshot(at: 100).first).position
        #expect(at10 == at100)
        #expect(abs(Geo.distanceNM(at10, Coordinate(latitude: 38.905, longitude: -77)) * Geo.metersPerNM - 100) < 3)
    }

    @Test func staleTrainsFadeAndArePruned() {
        var tracker = TrainTracker(staleAfter: 60, fadeDuration: 10)
        tracker.ingest([report(lat: 38.9, t: 0)], at: 0, extrapolation: 10)
        #expect(tracker.snapshot(at: 65).first.map { $0.opacity < 1 && $0.opacity > 0 } == true)
        tracker.prune(at: 71)
        #expect(tracker.trains.isEmpty)
    }

    @Test func newFixEasesInsteadOfJumping() throws {
        var tracker = TrainTracker(track: TrackIndex(network: lNetwork()))
        tracker.ingest([report(lat: 38.905, speed: 0, t: 0)], at: 0, extrapolation: 10)
        tracker.ingest([report(lat: 38.906, speed: 0, t: 20)], at: 20, extrapolation: 10)
        let shown = try #require(tracker.snapshot(at: 20).first).position.latitude
        #expect(abs(shown - 38.905) < 1e-5)
        let later = try #require(tracker.snapshot(at: 25).first).position.latitude
        #expect(abs(later - 38.906) < 1e-5)
    }

    @Test func trailsFollowMovingTrains() {
        var tracker = TrainTracker(trailDuration: 60, track: TrackIndex(network: lNetwork()))
        tracker.ingest([report(lat: 38.905, speed: 22.37, bearing: 0, t: 0)], at: 0, extrapolation: 60)
        for t in stride(from: 1.0, through: 30, by: 1) { tracker.prune(at: t) }
        #expect((tracker.trains["a"]?.trail.count ?? 0) >= 10)
    }

    @Test func expireFadesASourceOut() {
        var tracker = TrainTracker(staleAfter: 60, fadeDuration: 10)
        tracker.ingest([report("sched:1", lat: 38.9, t: 0), report("live", lat: 38.91, t: 0)], at: 0, extrapolation: 10)
        tracker.expire(where: { $0.id.hasPrefix("sched:") }, at: 5)
        let shown = tracker.snapshot(at: 10)
        #expect(shown.first { $0.id == "sched:1" }!.opacity < 1)
        #expect(shown.first { $0.id == "live" }!.opacity == 1)
    }
}

// MARK: - New York, Philadelphia, Boston

@Suite struct RegionNetworkTests {
    // Tests run in parallel: one load per region, behind a lock.
    nonisolated(unsafe) private static var cache: [String: RailNetwork] = [:]
    private static let lock = NSLock()
    static func network(_ r: Region) throws -> RailNetwork {
        lock.lock()
        defer { lock.unlock() }
        if let n = cache[r.id] { return n }
        let n = try RailNetwork.load(from: resources.appendingPathComponent("\(r.railFile).bin"))
        cache[r.id] = n
        return n
    }

    @Test(arguments: Region.all) func everyRegionHasItsSystems(_ region: Region) throws {
        let n = try Self.network(region)
        #expect(Set(n.systems) == Set(region.systems))
        #expect(n.station(key: region.defaultStation) != nil, "default station \(region.defaultStation)")
        for name in region.featured { #expect(n.stations.contains { $0.name == name }, "\(name)") }
        for p in region.presets { #expect(region.bounds.contains(p.center)) }
        #expect(Region.containing(region.presets[0].center) == region)
        let geo = try GeoData.load(from: resources.appendingPathComponent("\(region.geoFile).bin"))
        let around = GeoBounds(minLat: region.presets[0].center.latitude - 0.1, maxLat: region.presets[0].center.latitude + 0.1,
                               minLon: region.presets[0].center.longitude - 0.1, maxLon: region.presets[0].center.longitude + 0.1)
        #expect(!geo.features(.land, in: around).isEmpty)
    }

    @Test func newYorkHubsShareOneMarker() throws {
        let n = try Self.network(.newYork)
        let penn = try #require(n.stations.firstIndex { $0.code == "NYP" })
        #expect(n.stations[penn].name == "Penn Station")
        #expect(n.systems(at: penn).isSuperset(of: [.amtrak, .lirr, .njtRail, .nycSubway]))
        let gct = try #require(n.stations.firstIndex { $0.name == "Grand Central-42 St" })
        #expect(n.systems(at: gct).isSuperset(of: [.metroNorth, .nycSubway]))
        // Several stations share a name ("86 St"): keys keep them apart.
        let eightySixth = n.stations.filter { $0.name == "86 St" && $0.system == .nycSubway }
        #expect(eightySixth.count >= 4)
        #expect(Set(eightySixth.map(\.key)).count == eightySixth.count)
        // Route bullets in the MTA's colours.
        #expect(n.line(id: "nyct.A").map { n.lines[$0].color } == 0x0062CF)
    }

    @Test func philadelphiaAndBostonHubs() throws {
        let phl = try Self.network(.philadelphia)
        let thirtieth = try #require(phl.stations.firstIndex { $0.code == "PHL" })
        #expect(phl.stations[thirtieth].name == "30th Street Station")
        #expect(phl.systems(at: thirtieth).isSuperset(of: [.amtrak, .septaRail, .septaMetro]))
        let bos = try Self.network(.boston)
        let south = try #require(bos.stations.firstIndex { $0.code == "BOS" })
        #expect(bos.stations[south].name == "South Station")
        #expect(bos.systems(at: south).isSuperset(of: [.amtrak, .mbtaCommuter, .mbtaSubway]))
        #expect(bos.line(id: "mbta.Green-B") != nil)
    }

    @Test func subwayTripIDsMatchTheTimetable() throws {
        // Realtime ids are the timetable's tail, with path codes that may differ.
        #expect(RailNetwork.tripKey(system: .nycSubway, tripID: "AFA26GEN-1095-Weekday-00_067300_1..N15R") == "067300_1_N")
        #expect(RailNetwork.tripKey(system: .nycSubway, tripID: "067300_1..N03R") == "067300_1_N")
        #expect(RailNetwork.tripKey(system: .statenIsland, tripID: "075600_SI.S03X027") == "075600_SI_S")
        #expect(RailNetwork.tripKey(system: .lirr, tripID: "GO203_26_809") == "GO203_26_809")
        let n = try Self.network(.newYork)
        #expect(n.tripIndices(system: .nycSubway, tripID: "067300_1..N15R", trainNumber: nil).count >= 1)
    }

    @Test func subwayTrainsArePlacedFromPredictions() throws {
        let n = try Self.network(.newYork)
        let estimator = ScheduleEstimator(network: n)
        // A weekday 1 train, its timetable shifted by a two-minute delay at its next stop.
        let i = try #require(n.tripIndices(system: .nycSubway, tripID: "067300_1..N15R", trainNumber: nil).first {
            n.services[n.trips[$0].service].weekdays & 1 != 0
        })
        let trip = n.trips[i]
        let cal = estimator.calendar
        var monday = DateComponents(year: 2026, month: 11, day: 16)
        monday.timeZone = cal.timeZone
        let day = try #require(cal.date(from: monday))
        let k = trip.stops.count / 2
        let stop = trip.stops[k]
        let stopID = try #require(n.stopIDs(system: .nycSubway, station: Int(stop.station)).first)
        let now = day.addingTimeInterval(Double(stop.arrival) - 60)
        var u = TripUpdate()
        u.tripID = "067300_1..N15R"
        u.startDate = "20261116"
        u.stops = [.init(stopID: stopID, arrivalTime: day.timeIntervalSince1970 + Double(stop.arrival) + 120)]
        let feed = GTFSRealtime.Feed(timestamp: nil, vehicles: [], tripUpdates: [u])
        let reports = PredictionFeedSource.reports(feed, system: .nycSubway, network: n, estimator: estimator, now: now)
        let r = try #require(reports.first)
        #expect(!r.isScheduled)
        // Three minutes before it reaches stop k: between stops k-1 and k, or still at k-1.
        let before = n.stations[Int(trip.stops[k - 1].station)].position
        #expect(Geo.distanceNM(r.position, before) < Geo.distanceNM(before, n.stations[Int(stop.station)].position) + 0.05)
    }
}
