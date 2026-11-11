import AppKit
import Observation
import TrainspaceCore

/// Key of colours in view, for the info corner.
struct Legend: Equatable {
    struct Entry: Equatable, Identifiable {
        var id: String { name }
        var name: String
        /// Map colour (`RailLine.mapColor` or `SystemInfo.color`), tuned by the palette when drawn.
        var color: UInt32
        var count: Int
        /// Where it sorts: the network's line order.
        var order: Int
        /// Every train in this entry is a timetable estimate.
        var scheduled: Bool
    }
    var entries: [Entry] = []
}

/// Where a system's trains are coming from right now.
struct FeedStatus: Equatable {
    enum Mode: String {
        /// Positions reported by the trains.
        case live
        /// Estimated from the timetable (no key, or the live feed is failing).
        case scheduled
        /// Hidden in Settings.
        case off
    }
    var mode: Mode = .scheduled
    var sourceName: String?
    var lastSuccess: Date?
    var error: String?
    var needsKey = false
    var trainCount = 0
}

/// Single source of truth: settings, resolved location, the rail network, live trains and power state.
@MainActor @Observable
final class AppModel {
    static let defaultsKey = "trainspace.settings.v1"

    var settings: WallpaperSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            settingsChanged(from: oldValue)
        }
    }

    // MARK: Location
    private(set) var center: Coordinate?
    private(set) var resolvedPlaceName: String?
    private(set) var locationMessage: String?
    private(set) var isResolvingLocation = false

    // MARK: Network & trains
    private(set) var rail: RailNetwork?
    private(set) var geo: GeoData?
    @ObservationIgnored var tracker = TrainTracker()
    @ObservationIgnored private(set) var estimator: ScheduleEstimator?
    private(set) var feeds: [TransitSystem: FeedStatus] = [:]
    private(set) var trainsInView = 0
    /// Id of the train nearest the map centre.
    private(set) var nearestID: String?
    private(set) var legend = Legend()
    /// Bumps whenever new positions arrive, so lightweight views can refresh.
    private(set) var dataGeneration = 0

    /// WMATA and Swiftly keys, kept in the keychain.
    private(set) var apiKeys: [LiveFeeds.KeyKind: String] = [:]

    // MARK: Station view
    /// The boards for the station on screen, refreshed every few seconds.
    private(set) var stationBoards: [StationBoardContent] = []
    @ObservationIgnored private(set) var departureBoard: DepartureBoard?
    @ObservationIgnored private var tripUpdates: [TransitSystem: [TripUpdate]] = [:]
    @ObservationIgnored private var tripUpdateState: [TransitSystem: PollState] = [:]
    @ObservationIgnored private var amtrakTimes: [AmtrakFeed.StationTime] = []
    @ObservationIgnored private var nextBoardRefresh = Date.distantPast
    /// Stations as LED pills, for the Station Lights style.
    private(set) var stationLights: StationLights?

    // MARK: Power & appearance
    var powerInputs = PowerInputs() {
        didSet {
            guard powerInputs != oldValue else { return }
            let wasSuspended = powerMode.pollInterval == nil
            updatePowerMode()
            if wasSuspended && powerMode.pollInterval != nil { refreshSoon() }
        }
    }
    private(set) var powerMode = PowerMode(kind: .normal, pollInterval: 10, fps: 20)
    var systemIsDark = false
    var paused: Bool {
        get { powerInputs.paused }
        set { powerInputs.paused = newValue }
    }

    @ObservationIgnored let location = LocationProvider()
    @ObservationIgnored private var sources: [TransitSystem: any TrainSource] = [:]
    @ObservationIgnored private var feedState: [TransitSystem: PollState] = [:]
    /// Lines each live feed reported trains on last time; its other lines come from the timetable
    /// (SEPTA's feed carries the trolleys but not the L and B).
    @ObservationIgnored private var liveLines: [TransitSystem: Set<Int>] = [:]
    @ObservationIgnored private var nextSchedule = Date.distantPast
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Wallpaper size in points, set by the window controller; decides what's "in view".
    @ObservationIgnored var primaryScreenSize = CGSize(width: 1728, height: 1117)
    /// Snapshots set this to render the timetable at a chosen moment.
    @ObservationIgnored var clockOverride: Date?

    private struct PollState {
        var nextFetch = Date.distantPast
        var failures = 0
        var inFlight = false
        /// The key was refused: don't retry until it changes.
        var rejected = false
    }

    /// A failing live feed hands over to the timetable after this many misses in a row.
    static let failuresBeforeTimetable = 3

    init(settings: WallpaperSettings? = nil, startServices: Bool = true) {
        self.settings = settings ?? Self.loadSettings()
        tracker.trailDuration = max(10, self.settings.trailMinutes * 60)
        updatePowerMode()
        guard startServices else { return }
        apiKeys = KeyStore.load()
        loadData()
        location.onUpdate = { [weak self] coord in self?.systemLocationUpdated(coord) }
        location.onFailure = { [weak self] message in
            self?.locationMessage = message
            self?.isResolvingLocation = false
        }
        // A place chosen in Settings counts even if the welcome window was closed early.
        if self.settings.hasCompletedOnboarding || self.settings.location != .system { applyLocation() }
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    // MARK: Derived

    var now: Date { clockOverride ?? Date() }

    /// The metro area on the wallpaper.
    var region: Region { Region.with(id: settings.region) }

    /// The station shown in station view (nil in network view).
    var selectedStation: Int? {
        guard settings.viewMode == .station else { return nil }
        return rail?.station(key: settings.stationKey)
    }

    /// What the map is centred on: the station in station view, otherwise the chosen place.
    var mapCenter: Coordinate? {
        if let i = selectedStation, let s = rail?.stations[safe: i] { return s.position }
        return center
    }

    var mapRadiusNM: Double {
        selectedStation != nil ? settings.stationZoomMiles * Geo.nmPerMile : settings.radiusNM
    }

    var placeName: String {
        if let i = selectedStation, let s = rail?.stations[safe: i] { return s.name }
        let override = settings.displayName.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        if let n = resolvedPlaceName, !n.isEmpty { return n }
        if let c = center { return Format.coordinate(c) }
        return "Locating"
    }

    /// The map is somewhere the network doesn't reach.
    var isOutsideRegion: Bool {
        guard let center = mapCenter, let rail else { return false }
        let view = Projection(center: center, size: primaryScreenSize, radiusNM: mapRadiusNM).visibleBounds
        return !view.intersects(rail.coverage)
    }

    /// Every enabled live feed has gone quiet.
    var isStale: Bool {
        let live = feeds.filter { settings.systems.contains($0.key) && $0.value.sourceName != nil && !$0.value.needsKey }
        guard !live.isEmpty, powerMode.pollInterval != nil else { return false }
        return live.values.allSatisfy { $0.mode == .scheduled && $0.error != nil }
    }

    var lastSuccess: Date? { feeds.values.compactMap(\.lastSuccess).max() }

    func palette(at date: Date = Date()) -> Palette {
        let daylight = mapCenter.map { Solar.daylight(elevation: Solar.elevation(at: date, coordinate: $0)) } ?? (systemIsDark ? 0 : 1)
        return Palette.resolve(settings.appearance, source: settings.dynamicSource, systemIsDark: systemIsDark, daylight: daylight)
    }

    func line(of r: TrainReport) -> RailLine? {
        r.line.flatMap { rail?.lines[safe: $0] }
    }

    /// The map colour of a train, per the colour mode (nil in monochrome).
    func colorKey(for r: TrainReport) -> UInt32? {
        switch settings.colorMode {
        case .line: line(of: r)?.mapColor ?? r.system.info.color
        case .system: r.system.info.color
        case .monochrome: nil
        }
    }

    func color(for r: TrainReport, palette: Palette) -> RGBA {
        colorKey(for: r).map(palette.lineColor) ?? palette.monochrome
    }

    /// Track colour for a line, matching its trains.
    func trackColor(line: RailLine, palette: Palette) -> RGBA {
        switch settings.colorMode {
        case .line: palette.lineColor(line.mapColor)
        case .system: palette.lineColor(line.system.info.color)
        case .monochrome: palette.monochrome
        }
    }

    func isVisible(_ r: TrainReport) -> Bool { settings.systems.contains(r.system) }

    func label(_ r: TrainReport) -> String { r.label(network: rail) }

    // MARK: Actions

    func refreshSoon() {
        let soon = Date().addingTimeInterval(0.3)
        for s in TransitSystem.allCases { feedState[s, default: PollState()].nextFetch = min(feedState[s]?.nextFetch ?? soon, soon) }
        nextSchedule = .distantPast
    }

    func completeOnboarding(with location: LocationSetting) {
        settings.location = location
        settings.hasCompletedOnboarding = true
        applyLocation()
    }

    /// Fills the welcome preview. Before anything is chosen it shows Washington rather than asking
    /// for location access; that's asked only when someone picks "Use My Location".
    func beginPreview() {
        guard center == nil else { return }
        if case .system = settings.location, !settings.hasCompletedOnboarding {
            choose(region.presets[0])
        } else {
            applyLocation()
        }
    }

    /// Selects Core Location, re-requesting even if it was already selected (e.g. after a denial).
    func useSystemLocation() {
        if case .system = settings.location { applyLocation() } else { settings.location = .system }
    }

    /// Accepts coordinates or a place search (zip, city…).
    func setPlace(query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let c = CoordinateParser.parse(q) {
            settings.location = .coordinates(c, name: nil)
        } else {
            settings.location = .search(query: q, resolved: nil, name: nil)
        }
    }

    func choose(_ preset: PlacePreset) {
        settings.viewMode = .network
        settings.zoomMiles = preset.zoomMiles
        settings.location = .coordinates(preset.center, name: preset.name)
    }

    /// Switches the wallpaper to another metro area, at its first place.
    func choose(region r: Region) {
        guard r.id != settings.region else { return }
        settings.region = r.id
        choose(r.presets[0])
    }

    /// Switches to station view on `station`.
    func show(station: Station) {
        settings.stationKey = station.key
        settings.viewMode = .station
    }

    func setAPIKey(_ key: String, for kind: LiveFeeds.KeyKind) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKeys[kind] ?? "" != trimmed else { return }
        KeyStore.save(trimmed, for: kind)
        apiKeys[kind] = trimmed.isEmpty ? nil : trimmed
        rebuildSources()
    }

    /// Fills the model with a fixed scene for headless snapshots.
    func stage(center: Coordinate, name: String, rail: RailNetwork?, geo: GeoData?, live: [TrainReport], at date: Date) {
        self.center = center
        self.resolvedPlaceName = name
        self.geo = geo
        if let rail { install(rail) }
        clockOverride = date
        tracker.removeAll()
        let liveSystems = Set(live.map(\.system))
        var lines: [TransitSystem: Set<Int>] = [:]
        for r in live where !r.isScheduled { if let l = r.line { lines[r.system, default: []].insert(l) } }
        liveLines = lines
        // Run the timetable for a while so trains have trails, then add the live trains.
        let t = date.timeIntervalSince1970
        for dt in stride(from: tracker.trailDuration, through: 0, by: -2) {
            let at = Date(timeIntervalSince1970: t - dt)
            if let estimator {
                let scheduled = estimator.trains(at: at, systems: settings.systems).filter { r in
                    !liveSystems.contains(r.system) || r.line.map { lines[r.system]?.contains($0) == false } ?? false
                }
                tracker.ingest(scheduled, at: t - dt, extrapolation: 4)
            }
            tracker.prune(at: t - dt)
        }
        tracker.ingest(live.map { var r = $0; r.fixTime = t - 1; return r }, at: t - 5, extrapolation: 30)
        for s in region.systems {
            feeds[s] = FeedStatus(mode: liveSystems.contains(s) ? .live : .scheduled, lastSuccess: date)
        }
        updateDerived()
        refreshBoards()
    }

    // MARK: Settings side effects

    private func settingsChanged(from old: WallpaperSettings) {
        if old.region != settings.region { regionChanged() }
        if old.location != settings.location { applyLocation() }
        if old.pollInterval != settings.pollInterval || old.fpsCap != settings.fpsCap || old.batterySaver != settings.batterySaver {
            updatePowerMode()
        }
        if old.systems != settings.systems || old.showScheduled != settings.showScheduled {
            if !settings.showScheduled { tracker.removeAll { $0.isScheduled } }
            tracker.removeAll { !self.settings.systems.contains($0.system) }
            refreshSoon()
        }
        if old.colorMode != settings.colorMode || old.zoomMiles != settings.zoomMiles || old.viewMode != settings.viewMode
            || old.stationKey != settings.stationKey || old.stationZoomMiles != settings.stationZoomMiles {
            updateDerived()
        }
        if old.viewMode != settings.viewMode || old.stationKey != settings.stationKey || old.systems != settings.systems {
            refreshBoards()
        }
        tracker.trailDuration = max(10, settings.trailMinutes * 60)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func loadSettings() -> WallpaperSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(WallpaperSettings.self, from: data) else { return WallpaperSettings() }
        return s
    }

    private func updatePowerMode() {
        powerMode = PowerPolicy.mode(powerInputs, settings.powerSettings)
    }

    // MARK: Location

    private func applyLocation() {
        resolveTask?.cancel()
        locationMessage = nil
        switch settings.location {
        case .system:
            isResolvingLocation = center == nil
            location.start()
        case let .coordinates(c, name):
            location.stop()
            setCenter(c, name: name)
            if name == nil { reverseGeocode(c) }
        case let .search(query, resolved, name):
            location.stop()
            if let resolved {
                setCenter(resolved, name: name)
            } else {
                isResolvingLocation = true
                resolveTask = Task { [weak self] in
                    do {
                        let place = try await Geocoding.search(query)
                        guard let self, !Task.isCancelled else { return }
                        self.isResolvingLocation = false
                        self.settings.location = .search(query: query, resolved: place.coordinate, name: place.name)
                    } catch {
                        guard let self, !Task.isCancelled else { return }
                        self.isResolvingLocation = false
                        self.locationMessage = "Couldn’t find “\(query)”. Try a zip code, a station, a neighborhood, or coordinates like 38.90, -77.04."
                    }
                }
            }
        }
    }

    private func systemLocationUpdated(_ c: Coordinate) {
        guard case .system = settings.location else { return }
        isResolvingLocation = false
        locationMessage = nil
        // Ignore jitter; only move the map for real changes (> ~1 km).
        if let current = center, Geo.distanceNM(current, c) < 0.5 { return }
        setCenter(c, name: nil)
        reverseGeocode(c)
    }

    private func setCenter(_ c: Coordinate, name: String?) {
        // A place in another metro area brings its network along.
        if let other = Region.containing(c), other.id != settings.region { settings.region = other.id }
        center = c
        resolvedPlaceName = name
        isResolvingLocation = false
        // Trains are the same wherever the map is; only what's "in view" changes.
        updateDerived()
        refreshSoon()
    }

    private func reverseGeocode(_ c: Coordinate) {
        Task { [weak self] in
            let name = await Geocoding.placeName(for: c)
            guard let self, self.center == c else { return }
            self.resolvedPlaceName = name
        }
    }

    // MARK: Data

    private func loadData() {
        let region = self.region
        let geoURL = Self.resourceURL(region.geoFile), railURL = Self.resourceURL(region.railFile)
        loadTask?.cancel()
        loadTask = Task.detached(priority: .utility) {
            let geo = geoURL.flatMap { try? GeoData.load(from: $0) }
            let rail = railURL.flatMap { try? RailNetwork.load(from: $0) }
            let index = rail.map(TrackIndex.init)
            let estimator = rail.map { ScheduleEstimator(network: $0) }
            let board = rail.map { DepartureBoard(network: $0, estimator: estimator) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.settings.region == region.id else { return }
                self.geo = geo
                if let rail { self.install(rail, index: index, estimator: estimator, board: board) }
            }
        }
    }

    /// Another metro area: its network replaces this one's, and station view starts at its hub.
    private func regionChanged() {
        tracker.removeAll()
        sources = [:]
        liveLines = [:]
        tripUpdates = [:]
        amtrakTimes = []
        stationBoards = []
        legend = Legend()
        // A station from the old region gives way to the new one's hub (install() checks it exists).
        if !region.systems.contains(where: { settings.stationKey.hasPrefix("\($0.rawValue):") }) {
            settings.stationKey = region.defaultStation
        }
        rail = nil
        stationLights = nil
        loadData()
    }

    private func install(_ rail: RailNetwork, index: TrackIndex? = nil, estimator: ScheduleEstimator? = nil,
                         board: DepartureBoard? = nil) {
        self.rail = rail
        tracker.removeAll()
        tracker.track = index ?? TrackIndex(network: rail)
        self.estimator = estimator ?? ScheduleEstimator(network: rail)
        departureBoard = board ?? DepartureBoard(network: rail, estimator: self.estimator)
        if rail.station(key: settings.stationKey) == nil { settings.stationKey = region.defaultStation }
        stationLights = StationLights(network: rail)
        rebuildSources()
        refreshBoards()
    }

    private func rebuildSources() {
        let bounds = rail?.coverage ?? region.bounds
        var next: [TransitSystem: any TrainSource] = [:]
        for system in rail?.systems ?? [] {
            if let s = LiveFeeds.source(for: system, keys: apiKeys, network: rail, estimator: estimator, region: bounds) {
                next[system] = s
            }
        }
        // New keys get a fresh start (and a refused key another chance).
        for system in TransitSystem.allCases {
            feedState[system] = PollState()
            tripUpdateState[system] = PollState()
        }
        sources = next
        refreshFeedStatus()
        refreshSoon()
    }

    nonisolated static func resourceURL(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "bin") { return url }
        // `swift run` from the repo
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(name).bin")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    // MARK: Polling

    /// Each live feed is polled on its own clock (VRE once a minute, WMATA every 10 s…);
    /// systems without a working live feed are filled from the timetable every 2 s.
    private func runLoop() async {
        var lastReport = Date()
        while !Task.isCancelled {
            if Date().timeIntervalSince(lastReport) >= 30 {
                Diagnostics.report(model: self)
                lastReport = Date()
            }
            if let base = powerMode.pollInterval, let rail {
                for system in settings.systems.intersection(rail.systems).sorted() {
                    guard let source = sources[system], feedState[system]?.rejected != true,
                          feedState[system]?.inFlight != true, Date() >= feedState[system]?.nextFetch ?? .distantPast else { continue }
                    feedState[system, default: PollState()].inFlight = true
                    let interval = max(base, source.minimumInterval)
                    Task { await self.poll(source, interval: interval) }
                }
                if Date() >= nextSchedule {
                    runTimetable()
                    nextSchedule = Date().addingTimeInterval(powerMode.kind == .normal ? 2 : 5)
                }
                // Station view: delays for the systems on the boards, and a board refresh every few seconds.
                if let station = selectedStation {
                    for system in rail.systems(at: station).intersection(settings.systems).sorted() {
                        guard tripUpdateState[system]?.rejected != true, tripUpdateState[system]?.inFlight != true,
                              Date() >= tripUpdateState[system]?.nextFetch ?? .distantPast,
                              let source = LiveFeeds.tripUpdates(for: system, keys: apiKeys) else { continue }
                        tripUpdateState[system, default: PollState()].inFlight = true
                        let interval = max(base, source.minimumInterval)
                        Task { await self.pollTripUpdates(source, interval: interval) }
                    }
                    if Date() >= nextBoardRefresh { refreshBoards() }
                }
            }
            tracker.prune(at: Date().timeIntervalSince1970)
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func poll(_ source: any TrainSource, interval: TimeInterval) async {
        let system = source.system
        defer { feedState[system]?.inFlight = false }
        do {
            let trains = try await source.trains()
            guard sources[system]?.name == source.name else { return }   // key changed mid-flight
            let wasFailing = (feedState[system]?.failures ?? 0) >= Self.failuresBeforeTimetable || feeds[system]?.mode != .live
            feedState[system]?.failures = 0
            feedState[system]?.nextFetch = Date().addingTimeInterval(interval)
            if wasFailing { tracker.expire(where: { $0.system == system && $0.isScheduled }, at: Date().timeIntervalSince1970) }
            tracker.ingest(trains, at: Date().timeIntervalSince1970, extrapolation: min(150, interval * 1.1),
                           staleAfter: max(45, interval * 2.5))
            let lines = Set(trains.filter { !$0.isScheduled }.compactMap(\.line))
            if lines != liveLines[system] {
                liveLines[system] = lines
                tracker.expire(where: { $0.system == system && $0.isScheduled && $0.line.map(lines.contains) == true },
                               at: Date().timeIntervalSince1970)
            }
            feeds[system, default: FeedStatus()].lastSuccess = Date()
            feeds[system]?.error = nil
            dataGeneration &+= 1
            if let amtrak = source as? AmtrakSource {
                amtrakTimes = await amtrak.stationTimes
                if selectedStation != nil { refreshBoards() }
            }
            if let predictions = source as? any TripUpdateProviding {
                tripUpdates[system] = await predictions.latestTripUpdates
                if selectedStation != nil { refreshBoards() }
            }
        } catch {
            var state = feedState[system] ?? PollState()
            state.failures += 1
            if case SourceError.unauthorized = error { state.rejected = true }
            state.nextFetch = Date().addingTimeInterval(min(300, interval * pow(2, Double(min(state.failures, 5)))))
            feedState[system] = state
            feeds[system, default: FeedStatus()].error = Self.describe(error)
            if state.failures == Self.failuresBeforeTimetable || state.rejected {
                tracker.expire(where: { $0.system == system && !$0.isScheduled }, at: Date().timeIntervalSince1970)
            }
        }
        refreshFeedStatus()
        updateDerived()
    }

    private func pollTripUpdates(_ source: TripUpdateSource, interval: TimeInterval) async {
        let system = source.system
        defer { tripUpdateState[system]?.inFlight = false }
        do {
            tripUpdates[system] = try await source.updates()
            tripUpdateState[system]?.failures = 0
            tripUpdateState[system]?.nextFetch = Date().addingTimeInterval(interval)
            refreshBoards()
        } catch {
            var state = tripUpdateState[system] ?? PollState()
            state.failures += 1
            if case SourceError.unauthorized = error { state.rejected = true }
            state.nextFetch = Date().addingTimeInterval(min(300, interval * pow(2, Double(min(state.failures, 5)))))
            tripUpdateState[system] = state
            // Old delays are worse than none.
            if state.failures >= Self.failuresBeforeTimetable { tripUpdates[system] = nil }
        }
    }

    /// Snapshots: live delays fetched up front.
    func stageDepartureData(_ data: LiveDepartureData) {
        tripUpdates = data.tripUpdates
        amtrakTimes = data.amtrak
        refreshBoards()
    }

    /// Recomputes the departure boards for the station on screen.
    func refreshBoards() {
        nextBoardRefresh = Date().addingTimeInterval(10)
        guard let station = selectedStation, let rail, let departureBoard else {
            if !stationBoards.isEmpty { stationBoards = [] }
            return
        }
        let live = LiveDepartureData(tripUpdates: tripUpdates, amtrak: amtrakTimes)
        let boards = StationBoards.specs(station: station, network: rail, enabled: settings.systems).map { spec in
            StationBoardContent(spec: spec, departures: departureBoard.departures(at: station, systems: spec.systems, after: now,
                                                                                   limit: spec.rows, live: live,
                                                                                   byExpected: spec.style.countsDown))
        }
        if boards != stationBoards { stationBoards = boards }
    }

    private func runTimetable() {
        guard let estimator, let rail, settings.showScheduled else { return }
        let enabled = settings.systems.intersection(rail.systems)
        let systems = Set(enabled.filter { usesTimetable($0) })
        // Live systems whose feed leaves some lines out: those lines from the timetable.
        let partial = enabled.subtracting(systems).filter { s in liveLines[s].map { !$0.isEmpty } ?? false }
        guard !systems.isEmpty || !partial.isEmpty else { return }
        let trains = estimator.trains(at: now, systems: systems.union(partial)).filter { r in
            systems.contains(r.system) || r.line.map { liveLines[r.system]?.contains($0) == false } ?? false
        }
        tracker.ingest(trains, at: Date().timeIntervalSince1970, extrapolation: 6, staleAfter: 8)
        updateDerived()
    }

    /// No live source, or it has missed enough polls (or had its key refused) to stop trusting it.
    private func usesTimetable(_ system: TransitSystem) -> Bool {
        guard sources[system] != nil, let state = feedState[system] else { return true }
        return state.rejected || state.failures >= Self.failuresBeforeTimetable
    }

    private func refreshFeedStatus() {
        for system in TransitSystem.allCases where !region.systems.contains(system) { feeds[system] = nil }
        for system in region.systems {
            var f = feeds[system] ?? FeedStatus()
            f.sourceName = sources[system]?.name
            f.needsKey = sources[system] == nil && LiveFeeds.keyKind(for: system) != nil
            if !settings.systems.contains(system) {
                f.mode = .off
            } else {
                f.mode = usesTimetable(system) ? .scheduled : .live
            }
            if f.needsKey { f.error = nil }
            if feedState[system]?.rejected == true { f.error = "Key not accepted" }
            if feeds[system] != f { feeds[system] = f }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SourceError.unauthorized: "Key not accepted"
        case let SourceError.http(code): "HTTP \(code)"
        case let e as URLError: e.localizedDescription
        case is AmtrakFeed.Failure: "Couldn’t read the Amtrak feed"
        default: String(describing: error)
        }
    }

    /// Counts what's on screen, builds the legend, and finds the train nearest the centre.
    private func updateDerived() {
        let t = now.timeIntervalSince1970
        let visible = tracker.snapshot(at: t).filter { isVisible($0.report) && $0.opacity > 0 }
        var counts: [TransitSystem: Int] = [:]
        for d in visible { counts[d.report.system, default: 0] += 1 }
        for system in region.systems where feeds[system]?.trainCount != counts[system] ?? 0 {
            feeds[system, default: FeedStatus()].trainCount = counts[system] ?? 0
        }

        guard let center = mapCenter else { return }
        let bounds = Projection(center: center, size: primaryScreenSize, radiusNM: mapRadiusNM).visibleBounds
        let inView = visible.filter { bounds.contains($0.position) }
        if trainsInView != inView.count { trainsInView = inView.count }

        // One entry per colour in view: a line ("Red Line"), lines sharing a colour ("4 5 6", "MBTA
        // Commuter Rail"), or a system when colouring by system.
        var groups: [String: (color: UInt32, lines: Set<Int>, system: TransitSystem, count: Int, scheduled: Bool, order: Int)] = [:]
        for d in inView {
            let r = d.report
            let color: UInt32, key: String
            switch settings.colorMode {
            case .line:
                color = colorKey(for: r) ?? 0
                key = "\(r.system.rawValue):\(color)"
            case .system, .monochrome:
                color = r.system.info.color
                key = "\(r.system.rawValue)"
            }
            var g = groups[key] ?? (color, [], r.system, 0, true, Int.max)
            // Listed as on the signs: by system, trunk lines first (lines are stored in drawing order).
            if let l = r.line { g.lines.insert(l); g.order = min(g.order, r.system.rawValue << 16 | (0xFFFF - l)) }
            g.count += 1
            g.scheduled = g.scheduled && r.isScheduled
            groups[key] = g
        }
        let sorted = groups.values.map { g in
            Legend.Entry(name: legendName(lines: g.lines, system: g.system), color: g.color, count: g.count,
                         order: g.order == .max ? g.system.rawValue << 16 : g.order, scheduled: g.scheduled)
        }.sorted { $0.order < $1.order }
        let capped = Self.capLegend(sorted)
        if legend.entries != capped { legend = Legend(entries: capped) }

        let nearest = visible.min { Geo.distanceNM($0.position, center) < Geo.distanceNM($1.position, center) }
        if nearestID != nearest?.id { nearestID = nearest?.id }
    }

    /// New York can have forty colours in view: the busiest keep their rows, the rest share one.
    static let legendLimit = 12

    static func capLegend(_ entries: [Legend.Entry]) -> [Legend.Entry] {
        guard entries.count > legendLimit else { return entries }
        let keep = Set(entries.sorted { $0.count > $1.count }.prefix(legendLimit - 1).map(\.name))
        let rest = entries.filter { !keep.contains($0.name) }
        let other = Legend.Entry(name: "\(rest.count) more lines", color: 0x8E8B85, count: rest.reduce(0) { $0 + $1.count },
                                 order: .max, scheduled: rest.allSatisfy(\.scheduled))
        return entries.filter { keep.contains($0.name) } + [other]
    }

    private func legendName(lines: Set<Int>, system: TransitSystem) -> String {
        guard settings.colorMode == .line, let rail, !lines.isEmpty else { return system.name }
        let ls = lines.sorted().map { rail.lines[$0] }
        if ls.count == 1 { return system == .nycSubway ? "\(ls[0].shortName) train" : ls[0].name }
        // New York's routes go by their letters and numbers ("4 5 6"); others sharing a colour by their railway.
        if system == .nycSubway || system == .septaMetro {
            return Set(ls.map(\.shortName)).sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }.joined(separator: " ")
        }
        if system == .mbtaSubway, ls.allSatisfy({ $0.id.hasPrefix("mbta.Green") }) { return "Green Line" }
        return system.name
    }
}
