import Foundation
import Testing
@testable import TrainspaceCore

@Suite struct StationLightsTests {
    private func setup() throws -> (StationLights, RailNetwork) {
        let rail = try RailNetworkTests.network()
        return (StationLights(network: rail), rail)
    }

    private func station(_ name: String, _ rail: RailNetwork) throws -> Int {
        try #require(rail.stations.firstIndex { $0.name == name })
    }

    @Test func pairsPerPlatformGroup() throws {
        let (lights, rail) = try setup()
        // Metro transfer stations: one pair for each set of lines sharing track.
        for name in ["Metro Center", "Gallery Place", "L'Enfant Plaza", "Fort Totten"] {
            let metro = lights.nodes[try station(name, rail)]?.groups.filter { rail.lines[$0[0]].system == .metrorail }
            #expect(metro?.count == 2, "\(name)")
        }
        #expect(lights.nodes[try station("Rosslyn", rail)]?.groups.count == 1)
        // VRE stops at L'Enfant too, so it gets its own pair beside Metrorail's two.
        #expect(lights.nodes[try station("L'Enfant Plaza", rail)]?.groups.count == 3)
        // Union Station: Red Line, then one pair each for MARC, VRE and Amtrak.
        let union = try #require(lights.nodes[try station("Union Station", rail)])
        #expect(union.groups.map { rail.lines[$0[0]].system } == [.metrorail, .marc, .vre, .amtrak])
        #expect(union.groups[1].count == 3)   // Penn, Camden and Brunswick share MARC's pair
    }

    @Test func trainsLightTheirStationOnTheirSide() throws {
        let (lights, rail) = try setup()
        let red = try #require(rail.line(id: "metrorail.red"))
        let mc = try station("Metro Center", rail)
        let at = rail.stations[mc].position
        let bearing = try #require(lights.nodes[mc]).trackBearing
        let train = TrainReport(id: "t", system: .metrorail, line: red, position: at, status: .stopped, fixTime: 0)
        let (one, phase) = try #require(lights.led(for: train, position: at, heading: bearing))
        let (other, _) = try #require(lights.led(for: train, position: at, heading: bearing + 180))
        #expect(one.station == mc && one.group == 0)
        #expect(one.side != other.side)
        #expect(phase == .atStation)
        // Between stations it blinks; far from its line it lights nothing.
        let between = Geo.offset(at, distanceNM: 0.3, bearingDeg: bearing)
        var moving = train
        moving.status = .moving
        #expect(lights.led(for: moving, position: between, heading: bearing)?.1 == .inTransit)
        #expect(lights.led(for: train, position: Coordinate(latitude: 39.6, longitude: -75.9), heading: nil) == nil)
    }
}

@Suite struct StationSignTests {
    @Test(arguments: [(6.0, 1.0), (12.0, 0.9), (24.0, 0.6)])
    func everyStationInViewGetsASign(zoom: Double, share: Double) throws {
        let rail = try RailNetworkTests.network()
        let p = Projection(center: Coordinate(latitude: 38.899, longitude: -77.023), size: CGSize(width: 1512, height: 982),
                           radiusNM: zoom * Geo.nmPerMile)
        let paths = SchematicGeometry.build(nil, rail: rail, projection: p, options: .init(stationSigns: true))
        let view = CGRect(x: 20, y: 20, width: 1472, height: 942)
        let inView = Set(paths.stations.filter { view.contains($0.point) }.map(\.station))
        let signed = Set(paths.stationLabels.map(\.station))
        print("zoom \(zoom): \(signed.intersection(inView).count) of \(inView.count) stations signed")
        #expect(Double(signed.intersection(inView).count) >= Double(inView.count) * share)
        for (i, a) in paths.stationLabels.enumerated() {
            for b in paths.stationLabels[(i + 1)...] { #expect(!a.rect.intersects(b.rect)) }
        }
    }

    @Test func amtrakSignsGiveCityAndState() throws {
        let rail = try RailNetworkTests.network()
        let wil = try #require(rail.stations.firstIndex { $0.name == "Wilmington" })
        #expect(StationSigns.displayName(station: wil, rail: rail) == "Wilmington, DE")
        // Shared stations use their main system's sign, which names the station as usual.
        let union = try #require(rail.stations.firstIndex { $0.name == "Union Station" })
        #expect(StationSigns.displayName(station: union, rail: rail) == "Union Station")
    }

    /// One Trainspace style for every railway: no agency's sign design, typeface or route symbols.
    @Test func everyRailwayGetsThePlainSign() {
        let m = StationSigns.Metrics(fontSize: 10)
        for system in TransitSystem.allCases {
            let style = StationSigns.style(system)
            #expect(style.font == StationSigns.font)
            #expect(style.field == StationSigns.field)
            #expect(StationSigns.lead(system, m) == m.stripe)
            #expect(style.marks == (system.isMainline ? .perSystem : .perLine))
        }
        #expect(StationSigns.font == "AvenirNext-DemiBold")
    }

    @Test func signsGrowWithTheirName() {
        let rail = lNetwork()
        let short = StationSigns.size(name: "Takoma", system: .metrorail, marks: [0], rail: rail, fontSize: 10)
        let long = StationSigns.size(name: "Takoma Park Station Extra", system: .metrorail, marks: [0], rail: rail, fontSize: 10)
        #expect(long.width > short.width + 40)
        // Same lettering everywhere, so the same name makes the same sign on any railway.
        #expect(StationSigns.size(name: "Takoma", system: .marc, marks: [0], rail: rail, fontSize: 10).width == short.width)
        #expect(StationSigns.size(name: "Takoma", system: .metrorail, marks: [], rail: rail, fontSize: 10).width < short.width)
    }
}
