import Foundation
import Testing
@testable import TrainspaceCore

@Suite struct NearestStationTests {
    let rail: RailNetwork
    init() throws { rail = try RailNetworkTests.network() }

    func station(_ name: String, _ system: TransitSystem) throws -> Int {
        try #require(rail.stations.indices.first { rail.stations[$0].name == name && rail.systems(at: $0).contains(system) })
    }

    func pos(_ i: Int) -> Coordinate { rail.stations[i].position }

    @Test func picksTheClosestStation() throws {
        let metroCenter = try station("Metro Center", .metrorail)
        let nearby = Geo.offset(pos(metroCenter), distanceNM: 0.05, bearingDeg: 90)
        #expect(NearestStation.pick(in: rail, near: nearby, systems: Set(TransitSystem.allCases), current: nil) == metroCenter)
    }

    /// Only the systems the user checked count; a shared station counts for each of its systems.
    @Test func onlyCheckedSystemsCount() throws {
        let union = try station("Union Station", .marc)
        #expect(NearestStation.pick(in: rail, near: pos(union), systems: [.marc], current: nil) == union)
        let odenton = try station("Odenton", .marc)
        #expect(NearestStation.pick(in: rail, near: pos(odenton), systems: [.marc], current: nil) == odenton)
        // No Metrorail station within 5 miles of Odenton.
        #expect(NearestStation.pick(in: rail, near: pos(odenton), systems: [.metrorail], current: nil) == nil)
        #expect(NearestStation.pick(in: rail, near: pos(odenton), systems: [], current: nil) == nil)
    }

    /// Standing about halfway between two stations mustn't make the boards flip back and forth.
    @Test func keepsTheCurrentStationUntilAnotherIsClearlyCloser() throws {
        let metroCenter = try station("Metro Center", .metrorail)
        let galleryPlace = try station("Gallery Place", .metrorail)
        let a = pos(metroCenter), b = pos(galleryPlace)
        let gap = Geo.distanceNM(a, b)
        // A little past halfway toward Gallery Place: closer to it, but not by the margin.
        func along(_ f: Double) -> Coordinate { Geo.offset(a, distanceNM: gap * f, bearingDeg: Geo.bearing(a, b)) }
        let justPast = along(0.5 + NearestStation.switchMarginNM / gap / 4)
        let all = Set(TransitSystem.allCases)
        #expect(NearestStation.pick(in: rail, near: justPast, systems: all, current: metroCenter) == metroCenter)
        #expect(NearestStation.pick(in: rail, near: justPast, systems: all, current: nil) == galleryPlace)
        // Well past halfway it switches.
        let wellPast = along(0.9)
        #expect(NearestStation.pick(in: rail, near: wellPast, systems: all, current: metroCenter) == galleryPlace)
    }

    @Test func dropsTheCurrentStationWhenItsSystemIsUnchecked() throws {
        let union = try station("Union Station", .marc)
        let odenton = try station("Odenton", .marc)
        // Current is Union Station, but only Metrorail counts now and we're at Odenton: nothing nearby.
        #expect(NearestStation.pick(in: rail, near: pos(odenton), systems: [.metrorail], current: union) == nil)
    }

    @Test func nothingWithinFiveMilesMeansNoStation() {
        let chesapeakeBay = Coordinate(latitude: 38.98, longitude: -76.35)
        #expect(NearestStation.pick(in: rail, near: chesapeakeBay, systems: Set(TransitSystem.allCases), current: nil) == nil)
        #expect(abs(NearestStation.maxDistanceNM - 5 * Geo.nmPerMile) < 0.001)
    }

    @Test func choiceAndExclusionsSurviveASaveAndLoad() throws {
        var s = WallpaperSettings()
        #expect(s.stationChoice == .fixed)
        #expect(s.nearestExcluded.isEmpty)
        s.stationChoice = .nearest
        s.nearestExcluded = [.amtrak, .vre]
        let back = try JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(s))
        #expect(back.stationChoice == .nearest)
        #expect(back.nearestExcluded == [.amtrak, .vre])
        #expect(back.nearestSystems(in: .dcBaltimore) == [.metrorail, .marc, .lightRail, .subway])
    }
}
