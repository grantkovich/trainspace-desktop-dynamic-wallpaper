import Foundation

/// Anything that can list one system's trains right now.
public protocol TrainSource: Sendable {
    var system: TransitSystem { get }
    /// Shown in Settings ("wmata.com", "maps.amtrak.com"…).
    var name: String { get }
    /// The feed itself updates no faster than this, so polling faster only costs bandwidth.
    var minimumInterval: TimeInterval { get }
    func trains() async throws -> [TrainReport]
}

public enum SourceError: Error, Equatable {
    case http(Int)
    case unauthorized
}

let userAgent = "Trainspace/1.0 (macOS live wallpaper)"

extension URLSession {
    /// No cookies or cache: every poll should hit the network.
    public static let trainspace: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func fetch(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw [401, 403].contains(http.statusCode) ? SourceError.unauthorized : SourceError.http(http.statusCode)
        }
        return data
    }
}

/// A GTFS-Realtime vehicle-positions feed.
public struct GTFSRealtimeSource: TrainSource {
    public let system: TransitSystem
    public let name: String
    public let minimumInterval: TimeInterval
    let url: URL
    let headers: [String: String]
    let network: RailNetwork?
    let session: URLSession
    /// The feed also carries other systems or buses (MBTA, SEPTA): keep only this system's routes.
    let sharedFeed: Bool

    public init(system: TransitSystem, name: String, url: URL, headers: [String: String] = [:], minimumInterval: TimeInterval,
                network: RailNetwork?, sharedFeed: Bool = false, session: URLSession = .trainspace) {
        self.system = system
        self.name = name
        self.url = url
        self.headers = headers
        self.minimumInterval = minimumInterval
        self.network = network
        self.sharedFeed = sharedFeed
        self.session = session
    }

    public func trains() async throws -> [TrainReport] {
        let data = try await session.fetch(url, headers: headers)
        let feed = try GTFSRealtime.decode(data)
        return Self.reports(feed, system: system, network: network, receivedAt: Date().timeIntervalSince1970,
                            sharedFeed: sharedFeed)
    }

    public static func reports(_ feed: GTFSRealtime.Feed, system: TransitSystem, network: RailNetwork?,
                               receivedAt: TimeInterval, sharedFeed: Bool = false) -> [TrainReport] {
        feed.vehicles.compactMap { v in
            let numberFromTrip = trainNumber(fromTripID: v.tripID, system: system)
            let trip = network?.trip(system: system, tripID: v.tripID, trainNumber: numberFromTrip)
            let line = network?.line(system: system, routeID: v.routeID) ?? trip?.line
            if sharedFeed, line == nil { return nil }
            var number = trip.map(\.trainNumber).flatMap { $0.isEmpty ? nil : $0 } ?? numberFromTrip
            if number == nil, system == .metrorail { number = v.vehicleLabel }
            // Feeds stamp positions with the device clock; trust it only when it's plausible.
            var fix = v.timestamp ?? feed.timestamp ?? receivedAt
            if fix > receivedAt + 5 || fix < receivedAt - 900 { fix = receivedAt }
            let status: TrainStatus? = switch v.currentStatus {
            case 0: .arriving
            case 1: .stopped
            case 2: .moving
            default: nil
            }
            return TrainReport(id: "\(system.rawValue):\(v.vehicleID ?? v.entityID)", system: system, line: line,
                               trainNumber: number, headsign: Headsign.clean(trip?.headsign), position:
                                Coordinate(latitude: v.latitude, longitude: v.longitude),
                               bearingDeg: v.bearing, speedMph: v.speed.map { $0 / Motion.metersPerSecondPerMph },
                               status: status, direction: v.directionID ?? trip.map { Int($0.direction) },
                               fixTime: min(fix, receivedAt))
        }
    }

    /// Commuter rail trip ids carry the train number: "Train677Sunday" (MARC), "305-Regular" (VRE),
    /// "AIR428_20261019_SID189798" (SEPTA), "1244" (Metro-North's vehicles).
    static func trainNumber(fromTripID id: String?, system: TransitSystem) -> String? {
        guard let id, [.marc, .vre, .septaRail, .metroNorth].contains(system) else { return nil }
        if system == .metroNorth { return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil }
        let digits = id.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}

/// Sources that bring trip updates along with positions, so boards needn't fetch them again.
public protocol TripUpdateProviding: Sendable {
    var latestTripUpdates: [TripUpdate] { get async }
}

/// GTFS-Realtime feeds that report many trains without a position: New York City Transit's (whose
/// trains have no GPS underground, so the feeds give only arrival predictions) and Metro-North's.
/// Trains with a position are placed there; the rest are placed along their timetabled trip,
/// shifted by how late the predictions say they're running. Several feeds can make one system
/// (NYCT splits the subway across eight).
public actor PredictionFeedSource: TrainSource, TripUpdateProviding {
    public nonisolated let system: TransitSystem
    public nonisolated let name: String
    public nonisolated let minimumInterval: TimeInterval
    let urls: [URL]
    let network: RailNetwork
    let estimator: ScheduleEstimator
    let session: URLSession
    public private(set) var latestTripUpdates: [TripUpdate] = []

    public init(system: TransitSystem, name: String, urls: [URL], minimumInterval: TimeInterval, network: RailNetwork,
                estimator: ScheduleEstimator, session: URLSession = .trainspace) {
        self.system = system
        self.name = name
        self.urls = urls
        self.minimumInterval = minimumInterval
        self.network = network
        self.estimator = estimator
        self.session = session
    }

    public func trains() async throws -> [TrainReport] {
        let session = self.session
        var feeds: [GTFSRealtime.Feed] = []
        var lastError: Error?
        await withTaskGroup(of: Result<GTFSRealtime.Feed, Error>.self) { group in
            for url in urls {
                group.addTask {
                    do { return .success(try GTFSRealtime.decode(try await session.fetch(url))) } catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case .success(let f): feeds.append(f)
                case .failure(let e): lastError = e
                }
            }
        }
        // Some of the subway's feeds may fail on their own; only a total failure counts.
        if feeds.isEmpty, let lastError { throw lastError }
        var merged = GTFSRealtime.Feed(timestamp: feeds.compactMap(\.timestamp).max(), vehicles: [])
        for f in feeds {
            merged.vehicles += f.vehicles
            merged.unplaced += f.unplaced
            merged.tripUpdates += f.tripUpdates
        }
        latestTripUpdates = merged.tripUpdates
        return Self.reports(merged, system: system, network: network, estimator: estimator, now: Date())
    }

    public static func reports(_ feed: GTFSRealtime.Feed, system: TransitSystem, network: RailNetwork,
                               estimator: ScheduleEstimator, now: Date) -> [TrainReport] {
        let t = now.timeIntervalSince1970
        var out = GTFSRealtimeSource.reports(feed, system: system, network: network, receivedAt: t)
        var placed = Set(feed.vehicles.compactMap { $0.tripID.map { RailNetwork.tripKey(system: system, tripID: $0) } })
        var updates: [String: TripUpdate] = [:]
        for u in feed.tripUpdates {
            if let id = u.tripID { updates[RailNetwork.tripKey(system: system, tripID: id)] = u }
        }
        // Trips the feed knows about: unplaced vehicles first (they carry train numbers), then any
        // trip update without a vehicle.
        var pending: [(id: String, update: TripUpdate?, number: String?)] = []
        for v in feed.unplaced {
            guard let id = v.tripID else { continue }
            let key = RailNetwork.tripKey(system: system, tripID: id)
            guard placed.insert(key).inserted else { continue }
            pending.append((id, updates[key], GTFSRealtimeSource.trainNumber(fromTripID: id, system: system)))
        }
        for (key, u) in updates where placed.insert(key).inserted {
            pending.append((u.tripID ?? key, u, nil))
        }
        for p in pending {
            if p.update?.canceled == true { continue }
            if let r = estimate(id: p.id, update: p.update, number: p.number, system: system, network: network,
                                estimator: estimator, now: now) {
                out.append(r)
            }
        }
        return out
    }

    /// Where a trip is, from its timetable shifted by its predicted delay.
    static func estimate(id: String, update: TripUpdate?, number: String?, system: TransitSystem, network: RailNetwork,
                         estimator: ScheduleEstimator, now: Date) -> TrainReport? {
        let cal = estimator.calendar
        let today = cal.startOfDay(for: now)
        var day = today
        if let s = update?.startDate, let n = Int(s), let d = ScheduleEstimator.date(n, cal) { day = d }
        let candidates = network.tripIndices(system: system, tripID: id, trainNumber: number)
        guard !candidates.isEmpty else { return nil }
        // The timetable variant running that day; any variant if the day's is unknown.
        let active = estimator.activeServices(system: system, on: day)
        var options = candidates.filter { active.contains(network.trips[$0].service) }
        if options.isEmpty, update?.startDate == nil, let yesterday = cal.date(byAdding: .day, value: -1, to: today) {
            // A train number without a date may be yesterday's, still running after midnight.
            let y = estimator.activeServices(system: system, on: yesterday)
            options = candidates.filter { y.contains(network.trips[$0].service) }
            if !options.isEmpty { day = yesterday }
        }
        if options.isEmpty { options = candidates }
        let nowSeconds = now.timeIntervalSince(day)

        // Delay: the first prediction for a stop this trip calls at.
        func delay(for trip: ScheduledTrip) -> Double? {
            guard let u = update else { return nil }
            for s in u.stops {
                guard let st = network.station(system: system, stopID: s.stopID),
                      let stop = trip.stops.first(where: { $0.station == Int32(st) }) else { continue }
                if let at = s.arrivalTime ?? s.departureTime {
                    return at - day.timeIntervalSince1970 - Double(s.arrivalTime != nil ? stop.arrival : stop.departure)
                }
                if let d = s.arrivalDelay ?? s.departureDelay { return Double(d) }
            }
            return u.delay.map(Double.init)
        }
        // Of several variants, the one whose times best fit right now.
        let scored = options.map { i -> (Int, Double, Double) in
            let trip = network.trips[i]
            let d = delay(for: trip) ?? 0
            let at = nowSeconds - d
            let miss = at < Double(trip.start) ? Double(trip.start) - at : at > Double(trip.end) ? at - Double(trip.end) : 0
            return (i, d, miss)
        }
        guard let best = scored.min(by: { $0.2 < $1.2 }), best.2 < 3600 else { return nil }
        let trip = network.trips[best.0]
        let seconds = Int32(min(max(nowSeconds - best.1, Double(trip.start)), Double(trip.end)))
        guard var r = estimator.report(trip, at: seconds, now: now.timeIntervalSince1970, system: system,
                                       dayKey: ScheduleEstimator.yyyymmdd(day, cal)) else { return nil }
        r.id = "\(system.rawValue):\(RailNetwork.tripKey(system: system, tripID: id))"
        // Placed from live predictions it's live; a train the feed lists but says nothing about is an estimate.
        r.isScheduled = update == nil || update?.stops.isEmpty == true
        if let number, r.trainNumber == nil { r.trainNumber = number }
        return r
    }
}

/// Amtrak's map feed, decrypted. Caches the key material and refreshes it if decryption fails.
public actor AmtrakSource: TrainSource {
    public nonisolated let system = TransitSystem.amtrak
    public nonisolated let name = "maps.amtrak.com"
    /// The map refreshes positions every few minutes, and each response is ~0.8 MB compressed.
    public nonisolated let minimumInterval: TimeInterval = 120
    let bounds: GeoBounds
    let network: RailNetwork?
    let session: URLSession
    private var keys: AmtrakFeed.KeyMaterial?
    /// Times at every Amtrak station in the network, from the latest response.
    public private(set) var stationTimes: [AmtrakFeed.StationTime] = []

    public init(bounds: GeoBounds, network: RailNetwork?, session: URLSession = .trainspace) {
        self.bounds = bounds
        self.network = network
        self.session = session
    }

    public func trains() async throws -> [TrainReport] {
        let payload = try await session.fetch(AmtrakFeed.trainsURL)
        let material = await keyMaterial(refresh: false)
        let json: Data
        do {
            json = try AmtrakFeed.decrypt(payload, keys: material)
        } catch {
            // The map may have rotated its keys.
            json = try AmtrakFeed.decrypt(payload, keys: await keyMaterial(refresh: true))
        }
        let codes = Set((network?.stations ?? []).map(\.code).filter { !$0.isEmpty })
        if !codes.isEmpty { stationTimes = (try? AmtrakFeed.stationTimes(geoJSON: json, codes: codes)) ?? stationTimes }
        return try AmtrakFeed.trains(geoJSON: json, in: bounds, network: network, receivedAt: Date().timeIntervalSince1970)
    }

    private func keyMaterial(refresh: Bool) async -> AmtrakFeed.KeyMaterial {
        if !refresh, let keys { return keys }
        if let routes = try? await session.fetch(AmtrakFeed.routesURL),
           let k = try? await session.fetch(AmtrakFeed.keysURL),
           let material = try? AmtrakFeed.keyMaterial(routesList: routes, keys: k) {
            keys = material
            return material
        }
        return keys ?? .fallback
    }
}

/// Where each system's live positions come from.
public enum LiveFeeds {
    /// Systems whose live feed needs a (free) key from the agency or its data vendor.
    public enum KeyKind: String, Sendable, CaseIterable {
        /// developer.wmata.com
        case wmata
        /// Swiftly, which serves MDOT MTA's Light Rail and Metro Subway feeds.
        case swiftly
    }

    public static func keyKind(for system: TransitSystem) -> KeyKind? {
        switch system {
        case .metrorail: .wmata
        case .lightRail, .subway: .swiftly
        default: nil
        }
    }

    /// MTA's open feeds (api.mta.info, no key since 2024).
    static func mta(_ path: String) -> URL {
        URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/" + path)!
    }

    /// The subway's eight feeds, by group of routes.
    static let nyctFeeds = ["nyct%2Fgtfs", "nyct%2Fgtfs-ace", "nyct%2Fgtfs-bdfm", "nyct%2Fgtfs-g", "nyct%2Fgtfs-jz",
                            "nyct%2Fgtfs-nqrw", "nyct%2Fgtfs-l"].map(mta)
    static let mbtaVehicles = URL(string: "https://cdn.mbta.com/realtime/VehiclePositions.pb")!
    static let mbtaTripUpdates = URL(string: "https://cdn.mbta.com/realtime/TripUpdates.pb")!
    static let septaRail = "https://www3.septa.org/gtfsrt/septarail-pa-us/"
    static let septaMetro = "https://www3.septa.org/gtfsrt/septa-pa-us/"

    /// Systems with no open live feed: their trains always come from the timetable.
    /// (NJ TRANSIT's needs a developer account with daily-expiring tokens; PATH publishes only
    /// station arrival times; PATCO publishes nothing live.)
    public static let timetableOnly: Set<TransitSystem> = [.njtRail, .njtLightRail, .path, .patco]

    /// The live source for `system`, or nil when it needs a key that hasn't been set (or has none).
    public static func source(for system: TransitSystem, keys: [KeyKind: String], network: RailNetwork?,
                              estimator: ScheduleEstimator? = nil, region: GeoBounds) -> (any TrainSource)? {
        func key(_ kind: KeyKind) -> String? {
            guard let k = keys[kind]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
            return k
        }
        func predictions(_ name: String, _ urls: [URL], _ interval: TimeInterval) -> (any TrainSource)? {
            guard let network, let estimator else { return nil }
            return PredictionFeedSource(system: system, name: name, urls: urls, minimumInterval: interval, network: network,
                                        estimator: estimator)
        }
        switch system {
        case .metrorail:
            guard let k = key(.wmata) else { return nil }
            return GTFSRealtimeSource(system: .metrorail, name: "api.wmata.com",
                                      url: URL(string: "https://api.wmata.com/gtfs/rail-gtfsrt-vehiclepositions.pb")!,
                                      headers: ["api_key": k], minimumInterval: 10, network: network)
        case .marc:
            return GTFSRealtimeSource(system: .marc, name: "MDOT MTA",
                                      url: URL(string: "https://mdotmta-gtfs-rt.s3.amazonaws.com/MARC+RT/marc-vp.pb")!,
                                      minimumInterval: 15, network: network)
        case .vre:
            // VRE asks that the feed be read no more than once a minute.
            return GTFSRealtimeSource(system: .vre, name: "vre.org",
                                      url: URL(string: "https://gtfs.vre.org/containercdngtfsupload/VehiclePositionFeed")!,
                                      minimumInterval: 60, network: network)
        case .amtrak:
            return AmtrakSource(bounds: region, network: network)
        case .lightRail:
            guard let k = key(.swiftly) else { return nil }
            return GTFSRealtimeSource(system: .lightRail, name: "Swiftly",
                                      url: URL(string: "https://api.goswift.ly/real-time/mta-maryland-light-rail/gtfs-rt-vehicle-positions")!,
                                      headers: ["Authorization": k], minimumInterval: 15, network: network)
        case .subway:
            guard let k = key(.swiftly) else { return nil }
            return GTFSRealtimeSource(system: .subway, name: "Swiftly",
                                      url: URL(string: "https://api.goswift.ly/real-time/mta-maryland-metro/gtfs-rt-vehicle-positions")!,
                                      headers: ["Authorization": k], minimumInterval: 15, network: network)
        case .nycSubway:
            return predictions("api.mta.info", nyctFeeds, 30)
        case .statenIsland:
            return predictions("api.mta.info", [mta("nyct%2Fgtfs-si")], 30)
        case .lirr:
            return predictions("api.mta.info", [mta("lirr%2Fgtfs-lirr")], 30)
        case .metroNorth:
            return predictions("api.mta.info", [mta("mnr%2Fgtfs-mnr")], 30)
        case .septaRail:
            return GTFSRealtimeSource(system: system, name: "septa.org", url: URL(string: septaRail + "Vehicle/rtVehiclePosition.pb")!,
                                      minimumInterval: 30, network: network)
        case .septaMetro:
            return GTFSRealtimeSource(system: system, name: "septa.org", url: URL(string: septaMetro + "Vehicle/rtVehiclePosition.pb")!,
                                      minimumInterval: 30, network: network, sharedFeed: true)
        case .mbtaSubway, .mbtaCommuter:
            return GTFSRealtimeSource(system: system, name: "mbta.com", url: mbtaVehicles, minimumInterval: 15, network: network,
                                      sharedFeed: true)
        default:
            return nil
        }
    }
}

/// A GTFS-Realtime trip-updates feed: delays and cancellations, for departure boards.
public struct TripUpdateSource: Sendable {
    public let system: TransitSystem
    public let minimumInterval: TimeInterval
    let url: URL
    let headers: [String: String]
    let session: URLSession

    public init(system: TransitSystem, url: URL, headers: [String: String] = [:], minimumInterval: TimeInterval,
                session: URLSession = .trainspace) {
        self.system = system
        self.url = url
        self.headers = headers
        self.minimumInterval = minimumInterval
        self.session = session
    }

    public func updates() async throws -> [TripUpdate] {
        try GTFSRealtime.decode(try await session.fetch(url, headers: headers)).tripUpdates
    }
}

extension LiveFeeds {
    /// Where each system publishes delays. Amtrak's come with its positions (`AmtrakSource.stationTimes`).
    public static func tripUpdates(for system: TransitSystem, keys: [KeyKind: String]) -> TripUpdateSource? {
        func key(_ kind: KeyKind) -> String? {
            guard let k = keys[kind]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
            return k
        }
        switch system {
        case .metrorail:
            guard let k = key(.wmata) else { return nil }
            return TripUpdateSource(system: system, url: URL(string: "https://api.wmata.com/gtfs/rail-gtfsrt-tripupdates.pb")!,
                                    headers: ["api_key": k], minimumInterval: 15)
        case .marc:
            return TripUpdateSource(system: system, url: URL(string: "https://mdotmta-gtfs-rt.s3.amazonaws.com/MARC+RT/marc-tu.pb")!,
                                    minimumInterval: 30)
        case .vre:
            return TripUpdateSource(system: system, url: URL(string: "https://gtfs.vre.org/containercdngtfsupload/TripUpdateFeed")!,
                                    minimumInterval: 60)
        case .lightRail:
            guard let k = key(.swiftly) else { return nil }
            return TripUpdateSource(system: system,
                                    url: URL(string: "https://api.goswift.ly/real-time/mta-maryland-light-rail/gtfs-rt-trip-updates")!,
                                    headers: ["Authorization": k], minimumInterval: 30)
        case .subway:
            guard let k = key(.swiftly) else { return nil }
            return TripUpdateSource(system: system,
                                    url: URL(string: "https://api.goswift.ly/real-time/mta-maryland-metro/gtfs-rt-trip-updates")!,
                                    headers: ["Authorization": k], minimumInterval: 30)
        case .septaRail:
            return TripUpdateSource(system: system, url: URL(string: septaRail + "Trip/rtTripUpdates.pb")!, minimumInterval: 30)
        case .septaMetro:
            return TripUpdateSource(system: system, url: URL(string: septaMetro + "Trip/rtTripUpdates.pb")!, minimumInterval: 30)
        case .mbtaSubway, .mbtaCommuter:
            return TripUpdateSource(system: system, url: mbtaTripUpdates, minimumInterval: 20)
        default:
            // Amtrak's come with its positions (`AmtrakSource.stationTimes`); MTA's with theirs (`PredictionFeedSource`).
            return nil
        }
    }
}
