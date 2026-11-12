import Foundation

/// Station view's "the station nearest me": which station to show for where the user is.
public enum NearestStation {
    /// Farther than this from every counted station, there's no "nearest station" to show.
    public static let maxDistanceNM = 5 * Geo.nmPerMile
    /// Another station must be this much closer than the current one before the boards switch
    /// (about 150 m), so standing between two stations doesn't make them flip back and forth.
    public static let switchMarginNM = 0.08

    /// The closest station served by any of `systems` within `maxDistanceNM`, keeping `current`
    /// unless another is closer by `switchMarginNM`. A shared station (Union Station: Metrorail,
    /// MARC, VRE, Amtrak) counts if any of its systems does.
    public static func pick(in network: RailNetwork, near position: Coordinate, systems: Set<TransitSystem>,
                            current: Int?) -> Int? {
        guard !systems.isEmpty else { return nil }
        var best: (index: Int, distance: Double)?
        var currentDistance: Double?
        for i in network.stations.indices where !network.systems(at: i).isDisjoint(with: systems) {
            let d = Geo.distanceNM(position, network.stations[i].position)
            if i == current { currentDistance = d }
            if d <= maxDistanceNM, d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        guard let best else { return nil }
        if let current, let held = currentDistance, held <= maxDistanceNM, held - best.distance < switchMarginNM {
            return current
        }
        return best.index
    }
}
