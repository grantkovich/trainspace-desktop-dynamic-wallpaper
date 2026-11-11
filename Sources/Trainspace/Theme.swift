import SwiftUI
import TrainspaceCore

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum Typeface {
    /// Train labels on the map.
    static let labelSize: CGFloat = 9.5
    static let labelTracking: CGFloat = 0.7
    static var label: Font { .system(size: labelSize, weight: .medium, design: .monospaced) }
    /// Station names on the map. Metrics must match `SchematicGeometry.stationLabelWidth`.
    static func station(major: Bool) -> Font { .system(size: major ? 9 : 8, weight: .semibold).width(.expanded) }

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .medium).width(.expanded) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func caption(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
}

enum Format {
    static func coordinate(_ c: Coordinate) -> String {
        String(format: "%.2f°%@  %.2f°%@", abs(c.latitude), c.latitude >= 0 ? "N" : "S",
               abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }

    static func speed(_ mph: Double?) -> String? {
        guard let mph, mph.isFinite else { return nil }
        return "\(Int(mph.rounded())) MPH"
    }

    static func distance(miles: Double) -> String {
        miles < 10 ? String(format: "%.1f MI", miles) : String(format: "%.0f MI", miles)
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "NEVER" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "\(s) SEC AGO" }
        if s < 3600 { return "\(s / 60) MIN AGO" }
        return "\(s / 3600) HR AGO"
    }

    static func ringLabel(_ miles: Double) -> String {
        miles == miles.rounded() ? "\(Int(miles)) MI" : String(format: "%.1f MI", miles)
    }
}
