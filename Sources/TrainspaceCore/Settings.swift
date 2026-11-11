import Foundation

public enum MapStyle: String, Codable, CaseIterable, Sendable { case schematic, appleMap, pureField }
public enum AppearanceMode: String, Codable, CaseIterable, Sendable { case light, dark, dynamic }
public enum DynamicSource: String, Codable, CaseIterable, Sendable { case system, sun }
public enum LabelMode: String, Codable, CaseIterable, Sendable { case off, train, trainDestination }
public enum ColorMode: String, Codable, CaseIterable, Sendable { case line, system, monochrome }
/// Raw values are persisted. `stationLights` draws stations as LED pills that light up where trains are.
public enum GlyphStyle: String, Codable, CaseIterable, Sendable { case train, light, arrow, stationLights }
public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
public enum DisplayTarget: String, Codable, CaseIterable, Sendable { case all, mainOnly }
/// The whole network around a place, or one station with its departure boards.
public enum ViewMode: String, Codable, CaseIterable, Sendable { case network, station }

public enum LocationSetting: Codable, Hashable, Sendable {
    /// Follow Core Location.
    case system
    /// A typed search (zip, city) and the place it resolved to.
    case search(query: String, resolved: Coordinate?, name: String?)
    /// Typed coordinates, or a preset.
    case coordinates(Coordinate, name: String?)
}

/// Starting points for the map, offered on first run and in Settings.
public struct PlacePreset: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var center: Coordinate
    public var zoomMiles: Double

    public init(name: String, center: Coordinate, zoomMiles: Double) {
        self.name = name
        self.center = center
        self.zoomMiles = zoomMiles
    }

    /// DC–Baltimore's (each region has its own: `Region.presets`).
    public static var all: [PlacePreset] { Region.dcBaltimore.presets }
}

/// Everything the user can change. Decoding is tolerant: unknown or invalid values fall back
/// to defaults, so adding settings never wipes someone's configuration.
public struct WallpaperSettings: Codable, Hashable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 2...60
    public static let trailChoices: [Double] = [0, 1, 3, 10]
    public static let pollChoices: [Double] = [10, 15, 30, 60]
    public static let stationZoomRange: ClosedRange<Double> = 0.4...6

    /// `Region.id` of the metro area on the wallpaper.
    public var region: String = Region.dcBaltimore.id
    public var location: LocationSetting = .system
    /// Overrides the place name shown in the info corner.
    public var displayName: String = ""

    public var mapStyle: MapStyle = .schematic
    /// Radius from the centre to the nearer screen edge, in statute miles.
    public var zoomMiles: Double = 8 { didSet { zoomMiles = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoomMiles)) } }
    public var showTrack = true
    public var showStations = true
    public var showStationNames = true
    public var showRoads = true
    public var showRangeRings = false
    public var showDotGrid = true
    /// Wash the Apple map with the palette so it sits back like the other styles.
    public var tintAppleMap = true

    /// Systems shown on the map (track and trains).
    public var systems: Set<TransitSystem> = Set(TransitSystem.allCases)
    /// Show timetable positions for systems without a working live feed.
    public var showScheduled = true

    public var labelMode: LabelMode = .trainDestination
    public var colorMode: ColorMode = .line
    public var trailMinutes: Double = 1
    public var glyph: GlyphStyle = .train
    public var pulse = true
    public var brightness: Double = 0.9

    public var appearance: AppearanceMode = .dynamic
    public var dynamicSource: DynamicSource = .sun

    public var infoEnabled = true
    public var infoCorner: Corner = .bottomLeft
    public var infoShowClock = true
    public var infoShowCoordinates = true
    public var infoShowCount = true
    public var infoShowNearest = true
    /// Key of line or system colours (not shown in monochrome).
    public var infoShowLegend = true

    public var pollInterval: Double = 10
    public var batterySaver = true
    public var fpsCap: Double = 20
    public var displays: DisplayTarget = .all
    /// Also set the system wallpaper to a still of the map, so the menu bar (which tints from
    /// the system wallpaper, not from windows) and Mission Control match.
    public var syncSystemWallpaper = true

    public var viewMode: ViewMode = .network
    /// `Station.key` of the station shown in station view.
    public var stationKey: String = "0:Union Station"
    public var stationZoomMiles: Double = 1.2 {
        didSet { stationZoomMiles = min(Self.stationZoomRange.upperBound, max(Self.stationZoomRange.lowerBound, stationZoomMiles)) }
    }
    /// Name every station with a small sign beside it.
    public var stationSigns = true
    /// Live Amtrak positions from the feed behind Amtrak's Track-a-Train map. Amtrak has no
    /// official public API, so this is off unless the user turns it on; without it Amtrak
    /// runs on its published timetable.
    public var liveAmtrak = false

    public var hasCompletedOnboarding = false

    /// Bumped when a default changes in a way existing users should get too.
    /// 2: New York, Philadelphia and Boston systems (switched on for everyone).
    public static let currentSchema = 2
    public var schemaVersion = WallpaperSettings.currentSchema

    public init() {}

    public var radiusNM: Double { zoomMiles * Geo.nmPerMile }

    public var powerSettings: PowerSettings {
        PowerSettings(pollInterval: pollInterval, fpsCap: fpsCap, batterySaver: batterySaver)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case region, location, displayName, mapStyle, zoomMiles, showTrack, showStations, showStationNames, showRoads,
             showRangeRings, showDotGrid, tintAppleMap, systems, showScheduled, labelMode, colorMode, trailMinutes, glyph,
             pulse, brightness, appearance, dynamicSource, infoEnabled, infoCorner, infoShowClock, infoShowCoordinates,
             infoShowCount, infoShowNearest, infoShowLegend, pollInterval, batterySaver, fpsCap, displays,
             syncSystemWallpaper, viewMode, stationKey, stationZoomMiles, stationSigns, liveAmtrak, hasCompletedOnboarding,
             schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = WallpaperSettings()
        region = v(.region, d.region)
        location = v(.location, d.location)
        displayName = v(.displayName, d.displayName)
        mapStyle = v(.mapStyle, d.mapStyle)
        zoomMiles = v(.zoomMiles, d.zoomMiles)
        showTrack = v(.showTrack, d.showTrack)
        showStations = v(.showStations, d.showStations)
        showStationNames = v(.showStationNames, d.showStationNames)
        showRoads = v(.showRoads, d.showRoads)
        showRangeRings = v(.showRangeRings, d.showRangeRings)
        showDotGrid = v(.showDotGrid, d.showDotGrid)
        tintAppleMap = v(.tintAppleMap, d.tintAppleMap)
        // Unknown system ids (from a newer version) are dropped rather than failing the whole set.
        systems = Set(v(.systems, [Int]?.none)?.compactMap(TransitSystem.init(rawValue:)) ?? Array(d.systems))
        showScheduled = v(.showScheduled, d.showScheduled)
        labelMode = v(.labelMode, d.labelMode)
        colorMode = v(.colorMode, d.colorMode)
        trailMinutes = v(.trailMinutes, d.trailMinutes)
        glyph = v(.glyph, d.glyph)
        pulse = v(.pulse, d.pulse)
        brightness = v(.brightness, d.brightness)
        appearance = v(.appearance, d.appearance)
        dynamicSource = v(.dynamicSource, d.dynamicSource)
        infoEnabled = v(.infoEnabled, d.infoEnabled)
        infoCorner = v(.infoCorner, d.infoCorner)
        infoShowClock = v(.infoShowClock, d.infoShowClock)
        infoShowCoordinates = v(.infoShowCoordinates, d.infoShowCoordinates)
        infoShowCount = v(.infoShowCount, d.infoShowCount)
        infoShowNearest = v(.infoShowNearest, d.infoShowNearest)
        infoShowLegend = v(.infoShowLegend, d.infoShowLegend)
        pollInterval = v(.pollInterval, d.pollInterval)
        batterySaver = v(.batterySaver, d.batterySaver)
        fpsCap = v(.fpsCap, d.fpsCap)
        displays = v(.displays, d.displays)
        syncSystemWallpaper = v(.syncSystemWallpaper, d.syncSystemWallpaper)
        viewMode = v(.viewMode, d.viewMode)
        stationKey = v(.stationKey, d.stationKey)
        stationZoomMiles = v(.stationZoomMiles, d.stationZoomMiles)
        stationSigns = v(.stationSigns, d.stationSigns)
        liveAmtrak = v(.liveAmtrak, d.liveAmtrak)
        hasCompletedOnboarding = v(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        schemaVersion = v(.schemaVersion, 1)
        if schemaVersion < 2 {
            // Settings from before the new regions list only DC–Baltimore's systems.
            systems.formUnion(TransitSystem.allCases.filter { !Region.dcBaltimore.systems.contains($0) })
        }
        schemaVersion = Self.currentSchema
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(region, forKey: .region)
        try c.encode(location, forKey: .location)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(mapStyle, forKey: .mapStyle)
        try c.encode(zoomMiles, forKey: .zoomMiles)
        try c.encode(showTrack, forKey: .showTrack)
        try c.encode(showStations, forKey: .showStations)
        try c.encode(showStationNames, forKey: .showStationNames)
        try c.encode(showRoads, forKey: .showRoads)
        try c.encode(showRangeRings, forKey: .showRangeRings)
        try c.encode(showDotGrid, forKey: .showDotGrid)
        try c.encode(tintAppleMap, forKey: .tintAppleMap)
        try c.encode(systems.map(\.rawValue).sorted(), forKey: .systems)
        try c.encode(showScheduled, forKey: .showScheduled)
        try c.encode(labelMode, forKey: .labelMode)
        try c.encode(colorMode, forKey: .colorMode)
        try c.encode(trailMinutes, forKey: .trailMinutes)
        try c.encode(glyph, forKey: .glyph)
        try c.encode(pulse, forKey: .pulse)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(dynamicSource, forKey: .dynamicSource)
        try c.encode(infoEnabled, forKey: .infoEnabled)
        try c.encode(infoCorner, forKey: .infoCorner)
        try c.encode(infoShowClock, forKey: .infoShowClock)
        try c.encode(infoShowCoordinates, forKey: .infoShowCoordinates)
        try c.encode(infoShowCount, forKey: .infoShowCount)
        try c.encode(infoShowNearest, forKey: .infoShowNearest)
        try c.encode(infoShowLegend, forKey: .infoShowLegend)
        try c.encode(pollInterval, forKey: .pollInterval)
        try c.encode(batterySaver, forKey: .batterySaver)
        try c.encode(fpsCap, forKey: .fpsCap)
        try c.encode(displays, forKey: .displays)
        try c.encode(syncSystemWallpaper, forKey: .syncSystemWallpaper)
        try c.encode(viewMode, forKey: .viewMode)
        try c.encode(stationKey, forKey: .stationKey)
        try c.encode(stationZoomMiles, forKey: .stationZoomMiles)
        try c.encode(stationSigns, forKey: .stationSigns)
        try c.encode(liveAmtrak, forKey: .liveAmtrak)

        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}
