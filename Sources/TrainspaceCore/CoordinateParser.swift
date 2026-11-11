import Foundation

/// Parses typed coordinates: decimal ("41.97, -87.90"), hemisphere-suffixed or -prefixed
/// ("41.97N 87.90W", "N41.97 W87.90") and DMS ("41°58'12\"N 87°54'W"). Anything else is nil,
/// which the caller treats as a place search (zip code, city…).
public enum CoordinateParser {
    private static let number = #"(-?\d+(?:\.\d+)?)\s*[°º]?\s*(?:(\d+(?:\.\d+)?)\s*['′]\s*)?(?:(\d+(?:\.\d+)?)\s*(?:["″]|'')\s*)?"#
    /// "N41.97 W87.90": hemisphere before each number.
    private static let prefixed = try! NSRegularExpression(pattern: #"([NSEW])\s*"# + number + "()", options: [.caseInsensitive])
    /// "41.97N 87.90W", "41.97, -87.90": optional hemisphere after each number.
    private static let suffixed = try! NSRegularExpression(pattern: "()" + number + #"([NSEW])?"#, options: [.caseInsensitive])

    public static func parse(_ input: String) -> Coordinate? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let regex = text.first.map { "NSEWnsew".contains($0) } == true ? prefixed : suffixed
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { $0.range.length > 0 }
        guard matches.count == 2 else { return nil }

        // Nothing but separators may sit outside the two components.
        var leftover = text
        for m in matches.reversed() { leftover = (leftover as NSString).replacingCharacters(in: m.range, with: " ") }
        guard leftover.allSatisfy({ $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "/" }) else { return nil }

        guard var a = value(matches[0], in: ns), var b = value(matches[1], in: ns) else { return nil }
        // Order: explicit hemispheres win; otherwise latitude first.
        if a.axis == .lon || b.axis == .lat { swap(&a, &b) }
        guard a.axis != .lon, b.axis != .lat else { return nil }
        let c = Coordinate(latitude: a.value, longitude: b.value)
        guard (-90...90).contains(c.latitude), (-180...180).contains(c.longitude) else { return nil }
        return c
    }

    private enum Axis { case lat, lon, unknown }

    private static func value(_ m: NSTextCheckingResult, in s: NSString) -> (value: Double, axis: Axis)? {
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound || r.length == 0 ? nil : s.substring(with: r)
        }
        guard let degText = group(2), let deg = Double(degText) else { return nil }
        let minutes = group(3).flatMap(Double.init) ?? 0
        let seconds = group(4).flatMap(Double.init) ?? 0
        guard minutes < 60, seconds < 60 else { return nil }
        let hemis = [group(1), group(5)].compactMap { $0?.uppercased() }
        guard hemis.count <= 1 else { return nil }
        var v = abs(deg) + minutes / 60 + seconds / 3600
        if deg < 0 { v = -v }
        var axis = Axis.unknown
        if let h = hemis.first {
            guard deg >= 0 else { return nil }
            axis = (h == "N" || h == "S") ? .lat : .lon
            if h == "S" || h == "W" { v = -v }
        }
        return (v, axis)
    }
}
