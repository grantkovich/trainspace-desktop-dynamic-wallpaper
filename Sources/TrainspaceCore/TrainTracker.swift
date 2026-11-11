import Foundation

public enum Motion {
    /// Cubic ease-out on 0…1, clamped.
    public static func easeOut(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return 1 - pow(1 - x, 3)
    }

    static let metersPerSecondPerMph = 0.44704
}

/// A past position, kept for drawing trails.
public struct TrailFix: Hashable, Sendable {
    public var position: Coordinate
    public var time: TimeInterval
}

public struct TrackedTrain: Sendable {
    public var latest: TrainReport
    /// Oldest first.
    public var trail: [TrailFix]
    public var firstSeen: TimeInterval
    /// Local time this train last appeared in any response.
    public var lastSeen: TimeInterval
    /// Local time the latest *new* position arrived (drives the pulse).
    public var lastFixArrival: TimeInterval
    /// Where the latest fix sits on the track, if it's near one.
    var hit: TrackIndex.Hit?
    /// Speed (m/s) and direction used for motion: reported, or estimated from the last two fixes.
    var speed: Double = 0
    var heading: Double?
    /// How long past its fix this train may be projected forward.
    var extrapolationLimit: TimeInterval
    /// How long it may go unreported before fading: a few of its source's update intervals.
    var staleAfter: TimeInterval?
    /// Offset (degrees) from the projected position that eases out to zero.
    var correctionLat: Double = 0
    var correctionLon: Double = 0
    var correctionStart: TimeInterval = 0
}

/// What the renderer needs for one train at one instant.
public struct DisplayTrain: Sendable, Identifiable {
    public var id: String { report.id }
    public var report: TrainReport
    public var position: Coordinate
    /// Direction of travel, along the track when on one.
    public var heading: Double?
    public var trail: [TrailFix]
    /// 0…1, combines fade-in and stale fade-out.
    public var opacity: Double
    /// 1 right after a fresh fix, decaying to 0.
    public var pulse: Double
}

/// Merges successive batches of reports into smoothly moving, fading trains that stay on the track.
public struct TrainTracker: Sendable {
    public var trailDuration: TimeInterval
    public var staleAfter: TimeInterval
    public var fadeDuration: TimeInterval
    public var fadeInDuration: TimeInterval = 0.8
    public var easeDuration: TimeInterval = 1.6
    public var pulseDuration: TimeInterval = 1.6
    /// Snap fixes to the nearest track within this distance.
    public var snapMeters: Double = 250
    public var track: TrackIndex?

    public private(set) var trains: [String: TrackedTrain] = [:]

    public init(trailDuration: TimeInterval = 60, staleAfter: TimeInterval = 150, fadeDuration: TimeInterval = 10,
                track: TrackIndex? = nil) {
        self.trailDuration = trailDuration
        self.staleAfter = staleAfter
        self.fadeDuration = fadeDuration
        self.track = track
    }

    /// - Parameter extrapolation: how far ahead of a fix trains may be projected. Roughly the
    ///   source's update interval: long enough to bridge the gap, short enough not to sail
    ///   through a station the train has stopped at.
    /// - Parameter staleAfter: overrides the tracker's default for these trains.
    public mutating func ingest(_ reports: [TrainReport], at now: TimeInterval, extrapolation: TimeInterval,
                                staleAfter: TimeInterval? = nil) {
        for r in reports {
            guard var existing = trains[r.id] else {
                var t = TrackedTrain(latest: r, trail: [TrailFix(position: r.position, time: r.fixTime)],
                                     firstSeen: now, lastSeen: now, lastFixArrival: now,
                                     extrapolationLimit: extrapolation, staleAfter: staleAfter)
                setMotion(&t, previous: nil)
                trains[r.id] = t
                continue
            }
            existing.lastSeen = now
            existing.staleAfter = staleAfter
            if r.fixTime <= existing.latest.fixTime + 0.05 {
                // Same position re-served; keep metadata fresh.
                existing.latest.headsign = r.headsign ?? existing.latest.headsign
                existing.latest.trainNumber = r.trainNumber ?? existing.latest.trainNumber
                existing.latest.line = r.line ?? existing.latest.line
                trains[r.id] = existing
                continue
            }
            let shown = displayed(existing, at: now)
            let previous = existing.latest
            existing.latest = r
            existing.extrapolationLimit = extrapolation
            existing.lastFixArrival = now
            existing.trail.append(TrailFix(position: shown.position, time: now))
            setMotion(&existing, previous: previous)
            let target = projected(existing, at: now)
            existing.correctionLat = shown.position.latitude - target.position.latitude
            existing.correctionLon = shown.position.longitude - target.position.longitude
            // A big jump (a train re-matched to another vehicle, a GPS glitch) shouldn't glide across the map.
            if Geo.distanceNM(shown.position, target.position) > 1.5 {
                existing.correctionLat = 0
                existing.correctionLon = 0
                existing.trail = [TrailFix(position: target.position, time: now)]
            }
            existing.correctionStart = now
            trimTrail(&existing, now: now)
            trains[r.id] = existing
        }
    }

    /// Removes trains that have fully faded out, trims trails, and records where each moving
    /// train has been every few seconds, so trails follow the track between fixes.
    public mutating func prune(at now: TimeInterval, trailSpacing: TimeInterval = 3) {
        for (id, var t) in trains {
            if now - t.lastSeen >= (t.staleAfter ?? staleAfter) + fadeDuration {
                trains[id] = nil
                continue
            }
            var changed = false
            if t.speed > 0.5, let last = t.trail.last, now - last.time >= trailSpacing {
                t.trail.append(TrailFix(position: displayed(t, at: now).position, time: now))
                changed = true
            }
            let before = t.trail.count
            trimTrail(&t, now: now)
            if changed || t.trail.count != before { trains[id] = t }
        }
    }

    public mutating func removeAll() { trains.removeAll() }

    public mutating func removeAll(where predicate: (TrainReport) -> Bool) {
        trains = trains.filter { !predicate($0.value.latest) }
    }

    /// Ends a source's trains gracefully: they fade out instead of vanishing.
    public mutating func expire(where predicate: (TrainReport) -> Bool, at now: TimeInterval) {
        for (id, var t) in trains where predicate(t.latest) {
            t.lastSeen = min(t.lastSeen, now - (t.staleAfter ?? staleAfter))
            trains[id] = t
        }
    }

    public func snapshot(at now: TimeInterval) -> [DisplayTrain] {
        trains.values.map { displayed($0, at: now) }
    }

    func displayed(_ t: TrackedTrain, at now: TimeInterval) -> DisplayTrain {
        let fadeIn = min(1, max(0, (now - t.firstSeen) / fadeInDuration))
        let staleFor = now - t.lastSeen - (t.staleAfter ?? staleAfter)
        let fadeOut = staleFor <= 0 ? 1 : max(0, 1 - staleFor / fadeDuration)
        let sincePulse = now - t.lastFixArrival
        let pulse = t.trail.count > 1 && sincePulse < pulseDuration ? 1 - sincePulse / pulseDuration : 0
        var (position, heading) = projected(t, at: now)
        let remaining = 1 - Motion.easeOut((now - t.correctionStart) / easeDuration)
        if remaining > 0 {
            position = Coordinate(latitude: position.latitude + t.correctionLat * remaining,
                                  longitude: position.longitude + t.correctionLon * remaining)
        }
        return DisplayTrain(report: t.latest, position: position, heading: heading, trail: t.trail,
                            opacity: min(fadeIn, fadeOut), pulse: max(0, pulse))
    }

    /// The latest fix carried forward along the track (or in a straight line off it).
    func projected(_ t: TrackedTrain, at now: TimeInterval) -> (position: Coordinate, heading: Double?) {
        let dt = min(max(0, now - t.latest.fixTime), t.extrapolationLimit)
        let meters = t.speed * dt
        guard let heading = t.heading else { return (t.hit?.coordinate ?? t.latest.position, nil) }
        if let hit = t.hit, let track {
            let moved = track.advance(from: hit, bearing: heading, meters: meters)
            return (moved.0, moved.bearing)
        }
        guard meters > 0 else { return (t.latest.position, heading) }
        return (Geo.offset(t.latest.position, distanceNM: meters / Geo.metersPerNM, bearingDeg: heading), heading)
    }

    private func setMotion(_ t: inout TrackedTrain, previous: TrainReport?) {
        let r = t.latest
        var speed = r.speedMph.map { $0 * Motion.metersPerSecondPerMph }
        var heading = r.bearingDeg
        if let p = previous {
            let dt = r.fixTime - p.fixTime
            let meters = Geo.distanceNM(p.position, r.position) * Geo.metersPerNM
            if dt >= 3, dt <= 600 {
                if speed == nil { speed = meters / dt }
                if heading == nil, meters > 15 { heading = Geo.bearing(p.position, r.position) }
            }
        }
        if r.status == .stopped { speed = 0 }
        t.speed = max(0, min(speed ?? 0, 100))   // 100 m/s ≈ 224 mph: anything faster is noise
        t.heading = heading ?? t.heading
        t.hit = track?.nearest(r.position, system: r.system, line: r.line, bearing: heading, maxMeters: snapMeters)
            ?? track?.nearest(r.position, system: r.system, bearing: heading, maxMeters: snapMeters)
    }

    private func trimTrail(_ t: inout TrackedTrain, now: TimeInterval) {
        let cutoff = now - trailDuration
        if let firstKept = t.trail.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            t.trail.removeFirst(firstKept)
        } else if t.trail.count > 1, t.trail.last!.time < cutoff {
            t.trail = [t.trail.last!]
        }
    }
}
