import CoreGraphics
import Foundation
import Testing
@testable import TrainspaceCore

@Suite struct CoordinateParserTests {
    @Test(arguments: [
        ("41.97, -87.90", 41.97, -87.90),
        ("41.97 -87.90", 41.97, -87.90),
        ("41.97N 87.90W", 41.97, -87.90),
        ("N41.97 W87.90", 41.97, -87.90),
        ("33.9425° S, 151.1750° E", -33.9425, 151.175),
        ("41°58'12\"N 87°54'W", 41.97, -87.90),
        ("87.90W 41.97N", 41.97, -87.90),
        ("  51.47,-0.4543 ", 51.47, -0.4543),
    ])
    func parses(_ input: String, _ lat: Double, _ lon: Double) throws {
        let c = try #require(CoordinateParser.parse(input))
        #expect(abs(c.latitude - lat) < 1e-4)
        #expect(abs(c.longitude - lon) < 1e-4)
    }

    @Test(arguments: ["60601", "Chicago, IL", "", "91, 10", "10, 200", "41.9 N 87.9 N", "1 2 3"])
    func rejects(_ input: String) {
        #expect(CoordinateParser.parse(input) == nil)
    }
}

@Suite struct SolarTests {
    let chicago = Coordinate(latitude: 41.88, longitude: -87.63)

    private func utc(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    @Test func summerSolsticeNoonIsHigh() {
        // Solar noon in Chicago on the June solstice is ~17:50 UTC; elevation ≈ 90 − 41.88 + 23.44 = 71.56°
        let e = Solar.elevation(at: utc("2026-06-21T17:50:00Z"), coordinate: chicago)
        #expect(abs(e - 71.5) < 0.5)
    }

    @Test func midnightIsBelowHorizon() {
        #expect(Solar.elevation(at: utc("2026-06-21T05:50:00Z"), coordinate: chicago) < -20)
    }

    @Test func daylightFactorBlendsAcrossTwilight() {
        #expect(Solar.daylight(elevation: -10) == 0)
        #expect(Solar.daylight(elevation: 10) == 1)
        let mid = Solar.daylight(elevation: -1.5)
        #expect(mid > 0.3 && mid < 0.7)
    }
}

@Suite struct LabelLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let size = CGSize(width: 60, height: 12)

    @Test func prefersRightSlot() {
        let placed = LabelLayout.layout([LabelRequest(id: "a", anchor: CGPoint(x: 500, y: 500), size: size, priority: 0)],
                                        obstacles: [], bounds: bounds, previous: [:])
        #expect(placed.first?.slot == .right)
        #expect(placed.first?.rect.minX ?? 0 > 500)
    }

    @Test func avoidsOverlapByMovingOrDropping() {
        let reqs = [
            LabelRequest(id: "a", anchor: CGPoint(x: 500, y: 500), size: size, priority: 0),
            LabelRequest(id: "b", anchor: CGPoint(x: 505, y: 500), size: size, priority: 1),
            LabelRequest(id: "c", anchor: CGPoint(x: 502, y: 502), size: size, priority: 2),
        ]
        let placed = LabelLayout.layout(reqs, obstacles: [], bounds: bounds, previous: [:])
        for i in placed.indices {
            for j in placed.indices where j > i {
                #expect(!placed[i].rect.intersects(placed[j].rect))
            }
        }
        #expect(placed.first?.id == "a")   // highest priority always wins its slot
    }

    @Test func respectsEdgesAndObstacles() {
        let nearRightEdge = LabelRequest(id: "a", anchor: CGPoint(x: 990, y: 500), size: size, priority: 0)
        #expect(LabelLayout.layout([nearRightEdge], obstacles: [], bounds: bounds, previous: [:]).first?.slot == .left)

        let blocked = LabelLayout.layout([LabelRequest(id: "a", anchor: CGPoint(x: 500, y: 500), size: size, priority: 0)],
                                         obstacles: [CGRect(x: 0, y: 0, width: 1000, height: 1000)], bounds: bounds, previous: [:])
        #expect(blocked.isEmpty)
    }

    /// The grid must place exactly what the obvious all-pairs version places.
    @Test(arguments: [1, 2, 3, 4, 5])
    func gridMatchesBruteForce(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let reqs = (0..<400).map { i in
            LabelRequest(id: "a\(i)", anchor: CGPoint(x: .random(in: 0...1000, using: &rng), y: .random(in: 0...1000, using: &rng)),
                         size: CGSize(width: .random(in: 30...90, using: &rng), height: 12),
                         priority: .random(in: 0...1000, using: &rng))
        }
        let obstacles = [CGRect(x: 0, y: 700, width: 420, height: 300), CGRect(x: 488, y: 488, width: 24, height: 24)]
        let previous = Dictionary(uniqueKeysWithValues: reqs.prefix(100).map { ($0.id, LabelSlot.allCases[Int($0.priority) % 4]) })
        let grid = LabelLayout.layout(reqs, obstacles: obstacles, bounds: bounds, previous: previous, glyphRadius: 5)
        let brute = bruteForce(reqs, obstacles: obstacles, previous: previous, glyphRadius: 5)
        #expect(grid == brute)
        #expect(grid.count > 50)
    }

    private func bruteForce(_ requests: [LabelRequest], obstacles: [CGRect], previous: [String: LabelSlot],
                            glyphRadius: CGFloat) -> [PlacedLabel] {
        let glyphs = requests.map { (id: $0.id, rect: CGRect(x: $0.anchor.x - glyphRadius, y: $0.anchor.y - glyphRadius,
                                                             width: glyphRadius * 2, height: glyphRadius * 2)) }
        var placed: [PlacedLabel] = []
        for req in requests.sorted(by: { $0.priority < $1.priority }) {
            var order = LabelSlot.allCases
            if let prev = previous[req.id], let i = order.firstIndex(of: prev) { order.remove(at: i); order.insert(prev, at: 0) }
            for slot in order {
                let r = req.rect(slot)
                guard bounds.contains(r), !obstacles.contains(where: { $0.intersects(r) }),
                      !placed.contains(where: { $0.rect.intersects(r) }),
                      !glyphs.contains(where: { $0.id != req.id && $0.rect.intersects(r) }) else { continue }
                placed.append(PlacedLabel(id: req.id, rect: r, slot: slot))
                break
            }
        }
        return placed
    }

    @Test func keepsPreviousSlotWhenFree() {
        let req = LabelRequest(id: "a", anchor: CGPoint(x: 500, y: 500), size: size, priority: 0)
        #expect(LabelLayout.layout([req], obstacles: [], bounds: bounds, previous: ["a": .below]).first?.slot == .below)
    }
}

@Suite struct PowerPolicyTests {
    let settings = PowerSettings(pollInterval: 5, fpsCap: 30, batterySaver: true)

    @Test func normal() {
        #expect(PowerPolicy.mode(PowerInputs(), settings) == PowerMode(kind: .normal, pollInterval: 5, fps: 30))
    }

    @Test func battery() {
        let m = PowerPolicy.mode(PowerInputs(onBattery: true), settings)
        #expect(m == PowerMode(kind: .battery, pollInterval: 15, fps: 15))
        var noSaver = settings
        noSaver.batterySaver = false
        #expect(PowerPolicy.mode(PowerInputs(onBattery: true), noSaver).kind == .normal)
        #expect(PowerPolicy.mode(PowerInputs(lowPowerMode: true), noSaver).kind == .battery)
    }

    @Test func batteryRespectsSlowerUserInterval() {
        var slow = settings
        slow.pollInterval = 30
        slow.fpsCap = 10
        #expect(PowerPolicy.mode(PowerInputs(onBattery: true), slow) == PowerMode(kind: .battery, pollInterval: 30, fps: 10))
    }

    @Test func occludedStopsDrawingButKeepsSlowPoll() {
        #expect(PowerPolicy.mode(PowerInputs(allOccluded: true), settings) == PowerMode(kind: .occluded, pollInterval: 60, fps: 0))
    }

    @Test func suspendedStatesStopEverything() {
        for inputs in [PowerInputs(screenLocked: true), PowerInputs(displaysAsleep: true), PowerInputs(paused: true),
                       PowerInputs(onBattery: true, allOccluded: true, screenLocked: true)] {
            #expect(PowerPolicy.mode(inputs, settings) == PowerMode(kind: .suspended, pollInterval: nil, fps: 0))
        }
    }
}

@Suite struct ProjectionTests {
    let projection = Projection(center: Coordinate(latitude: 41.97, longitude: -87.90),
                                size: CGSize(width: 1600, height: 1000), radiusNM: 30)

    @Test func centerMapsToMiddle() {
        let p = projection.point(projection.center)
        #expect(abs(p.x - 800) < 1e-6)
        #expect(abs(p.y - 500) < 1e-6)
    }

    @Test func radiusMapsToShortHalfAxis() {
        let north = Geo.offset(projection.center, distanceNM: 30, bearingDeg: 0)
        let p = projection.point(north)
        #expect(abs(p.y - 0) < 5)        // top edge; Mercator stretches ~0.5% over 30 nm of latitude
        let east = Geo.offset(projection.center, distanceNM: 30, bearingDeg: 90)
        #expect(abs(projection.point(east).x - 1300) < 2)
    }

    @Test func roundTrip() {
        let c = Coordinate(latitude: 42.1, longitude: -88.2)
        let back = projection.coordinate(projection.point(c))
        #expect(abs(back.latitude - c.latitude) < 1e-9)
        #expect(abs(back.longitude - c.longitude) < 1e-9)
    }

    @Test func visibleBoundsContainCorners() {
        let b = projection.visibleBounds
        let corner = projection.coordinate(CGPoint(x: 0, y: 0))
        #expect(b.contains(corner))
        #expect(b.contains(projection.center))
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct SettingsTests {
    @Test func roundTrips() throws {
        var s = WallpaperSettings()
        s.mapStyle = .appleMap
        s.zoomMiles = 30
        s.labelMode = .train
        s.systems = [.marc, .amtrak]
        s.location = .coordinates(Coordinate(latitude: 1, longitude: 2), name: "Somewhere")
        let back = try JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func missingOrInvalidKeysFallBackToDefaults() throws {
        let partial = Data(#"{"zoomMiles": 12, "mapStyle": "pureField", "bogus": true, "labelMode": "nonsense", "systems": [1, 99]}"#.utf8)
        let s = try JSONDecoder().decode(WallpaperSettings.self, from: partial)
        #expect(s.zoomMiles == 12)
        #expect(s.mapStyle == .pureField)
        #expect(s.labelMode == WallpaperSettings().labelMode)
        #expect(s.appearance == WallpaperSettings().appearance)
        // Settings from before New York, Philadelphia and Boston keep their DC choices and get the new systems.
        #expect(s.systems.intersection(Region.dcBaltimore.systems) == [.marc])
        #expect(s.systems.isSuperset(of: Region.newYork.systems.filter { $0 != .amtrak }))
        let current = Data(#"{"schemaVersion": 2, "systems": [1, 6], "region": "nyc"}"#.utf8)
        let c = try JSONDecoder().decode(WallpaperSettings.self, from: current)
        #expect(c.systems == [.marc, .nycSubway])
        #expect(c.region == "nyc")
        let none = try JSONDecoder().decode(WallpaperSettings.self, from: Data("{}".utf8))
        #expect(none.systems == Set(TransitSystem.allCases))
    }

    @Test func stationViewSettingsRoundTripAndDefault() throws {
        var s = WallpaperSettings()
        #expect(s.viewMode == .network)
        s.viewMode = .station
        s.stationKey = "1:Penn Station"
        s.stationZoomMiles = 50
        #expect(s.stationZoomMiles == WallpaperSettings.stationZoomRange.upperBound)
        let back = try JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        // Settings saved before station view existed still load.
        let old = try JSONDecoder().decode(WallpaperSettings.self, from: Data(#"{"zoomMiles": 12}"#.utf8))
        #expect(old.viewMode == .network && old.stationKey == WallpaperSettings().stationKey)
    }

    @Test func defaultStationExists() throws {
        let rail = try RailNetworkTests.network()
        #expect(rail.station(key: WallpaperSettings().stationKey).map { rail.stations[$0].name } == "Union Station")
    }

    @Test func zoomIsClamped() {
        var s = WallpaperSettings()
        s.zoomMiles = 1_000
        #expect(s.zoomMiles == WallpaperSettings.zoomRange.upperBound)
        s.zoomMiles = 0
        #expect(s.zoomMiles == WallpaperSettings.zoomRange.lowerBound)
    }
}

@Suite struct PaletteTests {
    @Test func dcKeepsItsTunedColors() {
        #expect(Palette.night.lineColor(0xC80F2D) == RGBA(hex: 0xE8505B))
        #expect(Palette.aluminum.lineColor(0xC80F2D) == RGBA(hex: 0xC8102E))
    }

    @Test func metroRedIsRed() {
        for p in [Palette.night, .aluminum] {
            let red = p.lineColor(0xC80F2D)
            #expect(red.r > red.g * 2 && red.r > red.b * 2)
        }
    }

    @Test func agencyColorsAreTunedForEachSurface() {
        // Navy (MTA LIRR's Port Jefferson blue) lifts on the dark surface; NYCT's yellow deepens on the light one.
        let navy: UInt32 = 0x0039A6, yellow: UInt32 = 0xFCCC0A
        #expect(Palette.night.lineColor(navy).hsl.2 >= 0.57)
        #expect(Palette.aluminum.lineColor(yellow).luminance < RGBA(hex: yellow).luminance - 0.1)
        // Hue survives.
        #expect(abs(Palette.night.lineColor(navy).hsl.0 - RGBA(hex: navy).hsl.0) < 0.01)
    }

    @Test func hslRoundTrips() {
        for hex: UInt32 in [0xC80F2D, 0x00843D, 0x80276C, 0xFFD100, 0x7C858C] {
            let c = RGBA(hex: hex), (h, s, l) = c.hsl
            let back = RGBA(hue: h, saturation: s, lightness: l)
            #expect(abs(back.r - c.r) < 0.002 && abs(back.g - c.g) < 0.002 && abs(back.b - c.b) < 0.002)
        }
    }

    @Test func mixEndpoints() {
        #expect(Palette.mix(.night, .aluminum, 0) == .night)
        #expect(Palette.mix(.night, .aluminum, 1) == .aluminum)
    }
}

@Suite struct SchematicTests {
    @Test func buildsDowntownWithTrackAndStations() throws {
        let rail = try RailNetworkTests.network()
        let p = Projection(center: Coordinate(latitude: 38.8990, longitude: -77.0230), size: CGSize(width: 1512, height: 982),
                           radiusNM: 4 * Geo.nmPerMile)
        let paths = SchematicGeometry.build(nil, rail: rail, projection: p)
        let lines = Set(paths.track.map { rail.lines[$0.line].id })
        #expect(lines.isSuperset(of: ["metrorail.red", "metrorail.blue", "marc.penn", "vre.fredericksburg", "amtrak"]))
        #expect(rail.lines[paths.track.last!.line].system == .metrorail)   // Metrorail drawn on top
        #expect(paths.stations.count > 20)
        #expect(paths.stationLabels.contains { $0.name == "Metro Center" })
        for (i, a) in paths.stationLabels.enumerated() {
            for b in paths.stationLabels[(i + 1)...] { #expect(!a.rect.intersects(b.rect)) }
        }
    }

    @Test func hidesDisabledSystems() throws {
        let rail = try RailNetworkTests.network()
        let p = Projection(center: Coordinate(latitude: 38.8990, longitude: -77.0230), size: CGSize(width: 1000, height: 800), radiusNM: 8)
        let paths = SchematicGeometry.build(nil, rail: rail, projection: p, options: .init(systems: [.marc]))
        #expect(paths.track.allSatisfy { rail.lines[$0.line].system == .marc })
    }

    @Test func ringRadiiAreNice() {
        #expect(RangeRings.radii(forZoomMiles: 8) == [1, 2.5, 5])
        #expect(RangeRings.radii(forZoomMiles: 60).last == 50)
    }
}
