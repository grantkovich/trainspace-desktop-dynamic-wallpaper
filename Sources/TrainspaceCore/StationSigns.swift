import CoreGraphics
import CoreText
import Foundation

/// The look of a station-name sign. Every railway gets the same Trainspace style; only the line
/// colours (from each agency's GTFS) differ.
public struct SignStyle: Sendable, Hashable {
    /// PostScript name of the lettering.
    public var font: String
    public var field: UInt32
    public var text: UInt32
    public var marks: Marks

    /// What follows the name: which services stop here.
    public enum Marks: Sendable, Hashable {
        /// A plain dot per line (metro and light rail).
        case perLine
        /// One dot per railway (commuter and intercity rail).
        case perSystem
    }
}

/// Station names drawn as small signs beside the station, in one Trainspace style for every
/// railway: white lettering on a dark plate, a stripe in the line's colour at the leading edge,
/// and a plain dot per service in its line colour. No agency's sign design, typeface, route
/// symbols or logos are copied. Measurement lives here (Core Text is thread-safe) so label
/// placement can run off the main thread.
public enum StationSigns {
    /// Avenir Next ships with macOS and isn't any of these railways' typeface.
    public static let font = "AvenirNext-DemiBold"
    public static let field: UInt32 = 0x24272C
    public static let text: UInt32 = 0xFFFFFF

    public static func style(_ system: TransitSystem) -> SignStyle {
        SignStyle(font: font, field: field, text: text, marks: system.isMainline ? .perSystem : .perLine)
    }

    public static func fontName(_ system: TransitSystem) -> String { style(system).font }

    /// What the sign says. Amtrak signs give the city and state ("Wilmington, DE").
    public static func displayName(station: Int, rail: RailNetwork) -> String {
        let s = rail.stations[station]
        if s.system == .amtrak, let state = amtrakStates[s.code], !s.name.hasSuffix(", \(state)") { return "\(s.name), \(state)" }
        return s.name
    }

    static let amtrakStates: [String: String] = [
        "WAS": "DC", "BAL": "MD", "BWI": "MD", "NCR": "MD", "RKV": "MD", "ABE": "MD", "ALX": "VA", "WDB": "VA",
        "QAN": "VA", "FBG": "VA", "MSS": "VA", "BCV": "VA", "CLP": "VA", "CVS": "VA", "WIL": "DE", "NRK": "DE",
        "HFY": "WV", "MRB": "WV",
        "NYP": "NY", "NRO": "NY", "YNY": "NY", "CRT": "NY", "POU": "NY", "RHI": "NY", "HUD": "NY",
        "NWK": "NJ", "EWR": "NJ", "MET": "NJ", "NBK": "NJ", "PJC": "NJ", "TRE": "NJ",
        "STM": "CT", "BRP": "CT", "NHV": "CT", "STS": "CT", "BER": "CT", "HFD": "CT", "MDN": "CT", "MYS": "CT",
        "NLC": "CT", "OSB": "CT", "WFD": "CT", "WND": "CT", "WNL": "CT", "SPG": "MA",
        "PHL": "PA", "PHN": "PA", "CWH": "PA", "ARD": "PA", "PAO": "PA", "EXT": "PA", "DOW": "PA", "COT": "PA",
        "BOS": "MA", "BBY": "MA", "BON": "MA", "RTE": "MA", "WOB": "MA", "HHL": "MA", "FRA": "MA", "WOR": "MA",
        "PVD": "RI", "KIN": "RI", "WLY": "RI",
    ]

    /// Sign text size for a zoom (radius in miles): larger close in, smaller over the whole region.
    public static func fontSize(zoomMiles: Double) -> Double {
        zoomMiles <= 3 ? 11 : zoomMiles <= 8 ? 10 : zoomMiles <= 20 ? 9 : 8
    }

    public struct Metrics: Sendable {
        public var fontSize: CGFloat
        public var height: CGFloat { fontSize * 1.75 }
        public var padding: CGFloat { fontSize * 0.55 }
        /// The line-colour stripe at the leading edge.
        public var stripe: CGFloat { fontSize * 0.32 }
        public var dot: CGFloat { fontSize * 0.62 }
        public var dotSpacing: CGFloat { fontSize * 0.24 }
        public var textToDots: CGFloat { fontSize * 0.5 }
        public var cornerRadius: CGFloat { fontSize * 0.22 }
        public init(fontSize: CGFloat) { self.fontSize = fontSize }
    }

    /// Lines to mark on a sign: a dot per line colour on metro and light rail, one per railway on
    /// commuter and intercity rail (MARC's three lines share a dot).
    public static func marks(station: Int, rail: RailNetwork) -> [Int] {
        var seen = Set<String>()
        let lines = (rail.linesAtStation[safe: station] ?? []).filter { l in
            let line = rail.lines[l]
            let perLine = style(line.system).marks != .perSystem
            // Lines whose dots would look identical (same system and colour) are one mark.
            let key = perLine ? "\(line.system.rawValue):\(line.color)" : "\(line.system.rawValue)"
            return seen.insert(key).inserted
        }
        return lines.sorted { a, b in
            let sa = rail.lines[a].system, sb = rail.lines[b].system
            let own = rail.stations[station].system
            if (sa == own) != (sb == own) { return sa == own }
            return sa != sb ? sa < sb : a > b
        }
    }

    /// The colour of a line's dot on a sign: its GTFS colour.
    public static func markColor(_ line: RailLine) -> UInt32 { line.color }

    public static func marksWidth(_ marks: [Int], rail: RailNetwork, _ m: Metrics) -> CGFloat {
        guard !marks.isEmpty else { return 0 }
        let lines = marks.map { rail.lines[$0] }
        return m.textToDots + CGFloat(lines.count) * m.dot + CGFloat(marks.count - 1) * m.dotSpacing
    }

    public static func textWidth(_ text: String, system: TransitSystem, fontSize: CGFloat) -> CGFloat {
        textWidth(text, font: fontName(system), fontSize: fontSize)
    }

    static func textWidth(_ text: String, font name: String, fontSize: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Width before the text: the line-colour stripe.
    public static func lead(_ system: TransitSystem, _ m: Metrics) -> CGFloat { m.stripe }

    public static func size(name: String, system: TransitSystem, marks: [Int], rail: RailNetwork, fontSize: CGFloat) -> CGSize {
        let m = Metrics(fontSize: fontSize)
        let w = m.padding * 2 + textWidth(name, system: system, fontSize: fontSize) + lead(system, m) + marksWidth(marks, rail: rail, m)
        return CGSize(width: ceil(w), height: ceil(m.height))
    }
}
