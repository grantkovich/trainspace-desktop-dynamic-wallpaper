import Foundation

/// Where trains should be right now according to the bundled timetables. Used for systems
/// without a live feed (no API key yet, or the feed is down); drawn hollow so they read as estimates.
public struct ScheduleEstimator: Sendable {
    public let network: RailNetwork
    let calendar: Calendar
    /// Trip indices per system, sorted by start time.
    private let tripsBySystem: [TransitSystem: [Int]]
    /// Latest date any service of each system is defined for.
    private let lastDate: [TransitSystem: Int]

    public init(network: RailNetwork, timeZone: TimeZone = TimeZone(identifier: "America/New_York")!) {
        self.network = network
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
        var by: [TransitSystem: [Int]] = [:]
        for (i, t) in network.trips.enumerated() { by[network.lines[t.line].system, default: []].append(i) }
        tripsBySystem = by.mapValues { $0.sorted { network.trips[$0].start < network.trips[$1].start } }
        var last: [TransitSystem: Int] = [:]
        for s in network.services { last[s.system] = max(last[s.system] ?? 0, s.lastDate) }
        lastDate = last
    }

    /// Estimated positions of every scheduled train of `systems` at `date`.
    public func trains(at date: Date, systems: Set<TransitSystem>) -> [TrainReport] {
        let now = date.timeIntervalSince1970
        let today = calendar.startOfDay(for: date)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return [] }
        let secondsToday = Int32(date.timeIntervalSince(today))
        var out: [TrainReport] = []
        for system in systems.sorted() {
            guard let trips = tripsBySystem[system] else { continue }
            // Today's service, and yesterday's trips still running after midnight (times past 24:00).
            for (day, seconds) in [(today, secondsToday), (yesterday, secondsToday + 86_400)] {
                let active = activeServices(system: system, on: day)
                guard !active.isEmpty else { continue }
                let key = Self.yyyymmdd(day, calendar)
                for i in trips {
                    let trip = network.trips[i]
                    if trip.start > seconds { break }   // sorted by start
                    guard seconds <= trip.end, active.contains(trip.service),
                          let r = report(trip, at: seconds, now: now, system: system, dayKey: key) else { continue }
                    out.append(r)
                }
            }
        }
        return out
    }

    func report(_ trip: ScheduledTrip, at seconds: Int32, now: TimeInterval, system: TransitSystem, dayKey: Int) -> TrainReport? {
        let stops = trip.stops
        guard stops.count >= 2 else { return nil }
        var distance: Double, speed: Double
        var status: TrainStatus = .moving
        // Last stop whose arrival has passed.
        guard let k = stops.lastIndex(where: { $0.arrival <= seconds }) else { return nil }
        let s = stops[k]
        if seconds < s.departure || k == stops.count - 1 {
            distance = Double(s.distance)
            speed = 0
            status = .stopped
        } else {
            let next = stops[k + 1]
            let span = Double(next.arrival - s.departure)
            let frac = span > 0 ? Double(seconds - s.departure) / span : 1
            distance = Double(s.distance) + Double(next.distance - s.distance) * frac
            speed = span > 0 ? Double(next.distance - s.distance) / span : 0
            if span - Double(seconds - s.departure) < 30 { status = .arriving }
        }
        let shape = network.shapes[trip.shape]
        let (position, bearing) = shape.point(atDistance: distance)
        return TrainReport(id: "sched:\(system.rawValue):\(dayKey):\(trip.tripID)", system: system, line: trip.line,
                           trainNumber: trip.trainNumber.isEmpty ? nil : trip.trainNumber,
                           headsign: Headsign.clean(trip.headsign), position: position, bearingDeg: bearing,
                           speedMph: speed / Motion.metersPerSecondPerMph, status: status, isScheduled: true,
                           direction: Int(trip.direction), fixTime: now)
    }

    /// Services running on `day`. When the bundled timetable has run out (it's refreshed with each
    /// release), the same weekday from the timetable's last weeks stands in: rail schedules change slowly.
    func activeServices(system: TransitSystem, on day: Date) -> Set<Int> {
        let direct = services(system: system, on: day)
        if !direct.isEmpty { return direct }
        guard let last = lastDate[system], last > 0, Self.yyyymmdd(day, calendar) > last,
              let lastDay = Self.date(last, calendar) else { return direct }
        let weekday = Self.weekdayIndex(day, calendar)
        let offset = (Self.weekdayIndex(lastDay, calendar) - weekday + 7) % 7
        guard var probe = calendar.date(byAdding: .day, value: -offset, to: lastDay) else { return direct }
        for _ in 0..<8 {
            let found = services(system: system, on: probe)
            if !found.isEmpty { return found }
            guard let earlier = calendar.date(byAdding: .day, value: -7, to: probe) else { break }
            probe = earlier
        }
        return direct
    }

    private func services(system: TransitSystem, on day: Date) -> Set<Int> {
        let key = Self.yyyymmdd(day, calendar)
        let weekday = Self.weekdayIndex(day, calendar)
        var out = Set<Int>()
        for (i, s) in network.services.enumerated() where s.system == system && s.runs(on: key, weekday: weekday) {
            out.insert(i)
        }
        return out
    }

    /// 0 = Monday … 6 = Sunday, matching GTFS calendar order.
    static func weekdayIndex(_ day: Date, _ cal: Calendar) -> Int {
        (cal.component(.weekday, from: day) + 5) % 7
    }

    static func yyyymmdd(_ day: Date, _ cal: Calendar) -> Int {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    static func date(_ yyyymmdd: Int, _ cal: Calendar) -> Date? {
        cal.date(from: DateComponents(year: yyyymmdd / 10_000, month: yyyymmdd / 100 % 100, day: yyyymmdd % 100))
    }
}
