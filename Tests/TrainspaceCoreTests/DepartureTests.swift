import Foundation
import Testing
@testable import TrainspaceCore

private func eastern(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// Three stations on a north–south line; one weekday trip A → B → C at 08:00.
private func threeStops() -> RailNetwork {
    let pts: [GeoPoint] = [GeoPoint(38.90, -77.00), GeoPoint(38.92, -77.00), GeoPoint(38.94, -77.00)]
    let line = RailLine(id: "marc.penn", system: .marc, name: "MARC Penn Line", shortName: "PENN", color: 0xFF8000, routeIDs: ["11705"])
    let shape = RailShape(line: 0, points: pts)
    let stations = ["Union Station", "Middle", "Penn Station"].enumerated().map { i, name in
        Station(system: .marc, name: name, position: Coordinate(pts[i]), rank: 0)
    }
    let weekdays = ServiceCalendar(system: .marc, weekdays: 0b0011111, start: 20260101, end: 20261231, added: [], removed: [])
    let stops = [StopTime(arrival: 28_800, departure: 28_800, distance: 0, station: 0),
                 StopTime(arrival: 28_900, departure: 28_930, distance: shape.distances[1], station: 1),
                 StopTime(arrival: 29_030, departure: 29_030, distance: shape.distances[2], station: 2)]
    let trip = ScheduledTrip(line: 0, service: 0, shape: 0, tripID: "Train401", headsign: "BALTIMORE", trainNumber: "401",
                             direction: 0, stops: stops)
    return RailNetwork(lines: [line], shapes: [shape], stations: stations, services: [weekdays], trips: [trip],
                       stopStations: [.marc: ["S0": 0, "S1": 1, "S2": 2]])
}

@Suite struct TripUpdateTests {
    @Test func decodesMARCTripUpdates() throws {
        let feed = try GTFSRealtime.decode(try fixture("marc-tu.pb"))
        #expect(feed.tripUpdates.count >= 2)
        let u = try #require(feed.tripUpdates.first)
        #expect(u.tripID?.hasPrefix("Train") == true)
        #expect(u.routeID == "11705")
        #expect(u.stops.count > 3)
        #expect(u.stops.allSatisfy { $0.stopID != nil })
        #expect(u.stops.contains { $0.departureDelay != nil || $0.arrivalDelay != nil })
        // Negative int32 delays (early running) decode as negative numbers, not huge positives.
        let delays = feed.tripUpdates.flatMap(\.stops).compactMap { $0.departureDelay ?? $0.arrivalDelay }
        #expect(delays.allSatisfy { abs($0) < 6 * 3600 })
    }

    @Test func liveFeedStopsMatchBundledStations() throws {
        let network = try RailNetworkTests.network()
        let feed = try GTFSRealtime.decode(try fixture("marc-tu.pb"))
        let ids = feed.tripUpdates.flatMap(\.stops).compactMap(\.stopID)
        let matched = ids.filter { network.station(system: .marc, stopID: $0) != nil }
        #expect(Double(matched.count) >= Double(ids.count) * 0.9)
    }
}

@Suite struct DepartureBoardTests {
    let board = DepartureBoard(network: threeStops())
    let wednesday0759 = eastern("2026-11-04T12:59:00Z")   // 07:59 EST

    @Test func listsUpcomingDeparturesButNotTerminatingTrains() throws {
        let fromMiddle = board.departures(at: 1, systems: [.marc], after: wednesday0759, limit: 5)
        let d = try #require(fromMiddle.first)
        #expect(fromMiddle.count == 1)
        #expect(d.trainNumber == "401")
        #expect(d.destination == "BALTIMORE")
        #expect(d.status == .scheduled)
        #expect(d.scheduled == eastern("2026-11-04T13:02:10Z"))
        // Penn Station is the last stop: nothing departs from there.
        #expect(board.departures(at: 2, systems: [.marc], after: wednesday0759, limit: 5).isEmpty)
        // Other systems' boards don't show it.
        #expect(board.departures(at: 1, systems: [.metrorail], after: wednesday0759, limit: 5).isEmpty)
    }

    @Test func dropsTrainsThatHaveLeft() {
        #expect(board.departures(at: 0, systems: [.marc], after: eastern("2026-11-04T13:01:00Z"), limit: 5).isEmpty)
    }

    @Test func delaysCarryForwardFromEarlierStops() throws {
        var u = TripUpdate(tripID: "Train401Wednesday", routeID: "11705")
        u.stops = [.init(stopID: "S0", departureDelay: 240)]
        let d = try #require(board.departures(at: 1, systems: [.marc], after: wednesday0759, limit: 5,
                                              live: LiveDepartureData(tripUpdates: [.marc: [u]])).first)
        #expect(d.status == .late(minutes: 4))
        #expect(d.expected == d.scheduled.addingTimeInterval(240))
    }

    @Test func absoluteTimesAtTheStationWin() throws {
        var u = TripUpdate(tripID: "Train401")
        u.stops = [.init(stopID: "S0", departureDelay: 600),
                   .init(stopID: "S1", departureTime: eastern("2026-11-04T13:03:10Z").timeIntervalSince1970)]
        let d = try #require(board.departures(at: 1, systems: [.marc], after: wednesday0759, limit: 5,
                                              live: LiveDepartureData(tripUpdates: [.marc: [u]])).first)
        #expect(d.status == .onTime)   // one minute late rounds to on time
    }

    @Test func cancellations() throws {
        var u = TripUpdate(tripID: "Train401")
        u.canceled = true
        let d = try #require(board.departures(at: 0, systems: [.marc], after: wednesday0759, limit: 5,
                                              live: LiveDepartureData(tripUpdates: [.marc: [u]])).first)
        #expect(d.status == .cancelled)
    }

    @Test func realUnionStationBoard() throws {
        let network = try RailNetworkTests.network()
        let board = DepartureBoard(network: network)
        let union = try #require(network.stations.firstIndex { $0.name == "Union Station" })
        #expect(network.systems(at: union).isSuperset(of: [.metrorail, .marc, .vre, .amtrak]))
        let rush = eastern("2026-11-10T21:30:00Z")   // Tuesday 16:30 EST
        let mainline = board.departures(at: union, systems: [.marc, .vre, .amtrak], after: rush, limit: 12)
        #expect(mainline.count == 12)
        #expect(Set(mainline.map(\.system)) == [.marc, .vre, .amtrak])
        #expect(zip(mainline, mainline.dropFirst()).allSatisfy { $0.scheduled <= $1.scheduled })
        #expect(mainline.allSatisfy { $0.scheduled >= rush.addingTimeInterval(-30) })
        // Amtrak trips are cropped to the region, but destinations are the real ones, not the crop edge.
        #expect(mainline.contains { $0.system == .amtrak && $0.destination == "New York" })
        let metro = board.departures(at: union, systems: [.metrorail], after: rush, limit: 6)
        #expect(metro.count == 6)
        #expect(Set(metro.map(\.destination)).isSubset(of: ["Shady Grove", "Glenmont", "Grosvenor", "Silver Spring", "Twinbrook", "Rockville"]))
    }

    @Test func amtrakStationTimesSetRemarks() throws {
        let json = Data(#"""
        {"features":[{"properties":{"TrainNum":"20","Station3":"{\"code\":\"WAS\",\"tz\":\"E\",\"schdep\":\"11/08/2026 14:12:00\",\"estdep\":\"11/08/2026 14:17:00\",\"estdepcmnt\":\"05 MI LATE\"}","Station4":"{\"code\":\"BAL\",\"tz\":\"E\",\"schdep\":\"11/08/2026 14:52:00\",\"postdep\":\"11/08/2026 14:53:00\",\"postcmnt\":\"1 MI LATE\"}"}}]}
        """#.utf8)
        let times = try AmtrakFeed.stationTimes(geoJSON: json, codes: ["WAS", "BAL"])
        let was = try #require(times.first { $0.code == "WAS" })
        #expect(was.trainNumber == "20")
        #expect(was.estimatedDeparture == eastern("2026-11-08T19:17:00Z"))
        #expect(was.comment == "05 MI LATE")
        #expect(times.first { $0.code == "BAL" }?.departed == eastern("2026-11-08T19:53:00Z"))
        #expect(try AmtrakFeed.stationTimes(geoJSON: json, codes: ["NYP"]).isEmpty)
    }
}
