import CoreGraphics
import CoreText
import Foundation

/// How one railway letters its station signs, shrunk to sit beside the station on the map.
public struct SignStyle: Sendable, Hashable {
    /// PostScript name of the lettering.
    public var font: String
    /// The sign's field: one colour, or a brushed-metal sweep between two.
    public var field: UInt32
    public var fieldEnd: UInt32?
    public var text: UInt32
    public var lead: Lead
    public var marks: Marks
    /// The colour of the one disc a whole system shows (`Marks.perSystem`); nil = its first line's.
    public var systemMark: UInt32?

    /// What sits at the leading end of the sign, before the name.
    public enum Lead: Sendable, Hashable {
        case none
        /// Amtrak's sweeping curve.
        case curve(UInt32)
        /// MDOT MTA's slash.
        case slash(UInt32)
        /// A vertical agency-colour stripe (VRE, PATCO, MTA commuter rail in its line colour).
        case stripe(UInt32?)
        /// Two thin stripes (NJ TRANSIT).
        case stripes(UInt32, UInt32)
        /// A line-colour band along the bottom edge instead (MBTA).
        case band
        /// A thin white rule along the top (New York City Transit).
        case topRule
    }

    /// What follows the name: which services stop here.
    public enum Marks: Sendable, Hashable {
        /// A plain disc per line, or per lettered line a disc with its letter (Metrorail, NYCT).
        case perLine
        /// A rounded badge per line with its route code (SEPTA Metro's L1, B1, T1).
        case badges
        /// One disc per railway (commuter and intercity rail).
        case perSystem
    }
}

/// Station names drawn as small station signs, following each railway's published standards
/// where they exist. Measurement lives here (Core Text is thread-safe) so label placement can
/// run off the main thread.
///
/// Sources (fonts and colours read from each agency's own website stylesheets, Nov 2026, and its
/// published signage standards where there are any):
/// - WMATA (wmata.com): Helvetica Now, falling back to Helvetica Neue; brand brown #3A2C26; rail
///   discs as on its station pages (letters weight 750, white on R/B/G, black on O/Y/S). Signs:
///   white Helvetica Medium on Metro Brown (Signage Standards Manual, 2008).
/// - MDOT MTA (mta.maryland.gov): Roboto; red #A5272D with a gold #FFCA40 slash, as in the header.
/// - VRE (vre.org): Montserrat; navy #002B40, logo red #E0393E.
/// - Amtrak (amtrak.com): Open Sans; brand blue #00537E. Platform signs are a Silver field with the
///   blue curve and the city and state (Graphic Signage Standards Manual, 2018).
/// - MTA New York City Transit (mta.info: Helvetica): white Helvetica on black with a white rule
///   along the top and a route bullet per service (NYCTA Graphics Standards Manual, 1970, and its
///   successors). Bullets in each route's GTFS colour; black letters on the yellow N Q R W.
/// - MTA Long Island Rail Road and Metro-North (mta.info: Helvetica; MTA blue #0F61A9, dark #002D72):
///   white Helvetica on MTA dark blue with the branch colour at the leading edge. Metro-North's
///   service disc is in its red (#EE0034, its GTFS colour for the New Haven Line) to tell it from LIRR's.
/// - NJ TRANSIT (njtransit.com: Public Sans; navy #1A2B57, blues #004F99 #0474C8).
/// - PATH (panynj.gov: Helvetica; PATH blue #0047BB) with a disc per route in its map colour.
/// - SEPTA (septa.org: Roboto; navy #103270, blue #1F4FA3, ink #1A1818). SEPTA Metro's wayfinding
///   (2025) letters each line with a coloured route code: L1 blue, B1 orange, T1 green, G1 yellow,
///   D1 pink, M1 purple, from SEPTA's GTFS.
/// - PATCO (ridepatco.org: Verdana bold; red #D11241, grey #404040).
/// - MBTA (mbta.com: Helvetica Neue bold; ink #1C1E23): Helvetica Neue on dark with a band in the
///   line's colour (MBTA Sign Standards); Green Line branches carry their letter.
/// Roboto, Montserrat, Open Sans and Public Sans are bundled (open licences, see Resources/Fonts).
public enum StationSigns {
    public static func style(_ system: TransitSystem) -> SignStyle {
        styles[system.rawValue] ?? styles[0]!
    }

    static let styles: [Int: SignStyle] = [
        TransitSystem.metrorail.rawValue: SignStyle(font: "HelveticaNeue-Medium", field: 0x3A2C26, text: 0xFFFFFF,
                                                    lead: .none, marks: .perLine),
        TransitSystem.amtrak.rawValue: SignStyle(font: "OpenSans-Bold", field: 0xE6E7E8, fieldEnd: 0xB3B5B7, text: 0x00537E,
                                                 lead: .curve(0x00537E), marks: .perSystem, systemMark: 0x00537E),
        TransitSystem.marc.rawValue: mdotMTA(mark: 0xFF8000),
        TransitSystem.lightRail.rawValue: mdotMTA(mark: nil),
        TransitSystem.subway.rawValue: mdotMTA(mark: nil),
        TransitSystem.vre.rawValue: SignStyle(font: "MontserratThin-SemiBold", field: 0x002B40, text: 0xFFFFFF,
                                              lead: .stripe(0xE0393E), marks: .perSystem),
        TransitSystem.nycSubway.rawValue: SignStyle(font: "HelveticaNeue-Medium", field: 0x000000, text: 0xFFFFFF,
                                                    lead: .topRule, marks: .perLine),
        TransitSystem.statenIsland.rawValue: SignStyle(font: "HelveticaNeue-Medium", field: 0x000000, text: 0xFFFFFF,
                                                       lead: .topRule, marks: .perLine),
        TransitSystem.lirr.rawValue: SignStyle(font: "HelveticaNeue-Medium", field: 0x002D72, text: 0xFFFFFF,
                                               lead: .stripe(nil), marks: .perSystem, systemMark: 0x0F61A9),
        TransitSystem.metroNorth.rawValue: SignStyle(font: "HelveticaNeue-Medium", field: 0x002D72, text: 0xFFFFFF,
                                                     lead: .stripe(nil), marks: .perSystem, systemMark: 0xEE0034),
        TransitSystem.njtRail.rawValue: SignStyle(font: "PublicSans-Bold", field: 0x1A2B57, text: 0xFFFFFF,
                                                  lead: .stripes(0x0474C8, 0x004F99), marks: .perSystem, systemMark: 0x0474C8),
        TransitSystem.njtLightRail.rawValue: SignStyle(font: "PublicSans-Bold", field: 0x1A2B57, text: 0xFFFFFF,
                                                       lead: .stripes(0x0474C8, 0x004F99), marks: .perLine),
        TransitSystem.path.rawValue: SignStyle(font: "Helvetica-Bold", field: 0x0047BB, text: 0xFFFFFF,
                                               lead: .none, marks: .perLine),
        TransitSystem.septaRail.rawValue: SignStyle(font: "Roboto-Bold", field: 0x103270, text: 0xFFFFFF,
                                                    lead: .stripe(0x1F4FA3), marks: .perSystem, systemMark: 0x4F758B),
        TransitSystem.septaMetro.rawValue: SignStyle(font: "Roboto-Bold", field: 0x1A1818, text: 0xFFFFFF,
                                                     lead: .none, marks: .badges),
        TransitSystem.patco.rawValue: SignStyle(font: "Verdana-Bold", field: 0x404040, text: 0xFFFFFF,
                                                lead: .stripe(0xD11241), marks: .perSystem, systemMark: 0xD11241),
        TransitSystem.mbtaSubway.rawValue: SignStyle(font: "HelveticaNeue-Bold", field: 0x1C1E23, text: 0xFFFFFF,
                                                     lead: .band, marks: .perLine),
        TransitSystem.mbtaCommuter.rawValue: SignStyle(font: "HelveticaNeue-Bold", field: 0x1C1E23, text: 0xFFFFFF,
                                                       lead: .band, marks: .perSystem, systemMark: 0x80276C),
    ]

    static func mdotMTA(mark: UInt32?) -> SignStyle {
        SignStyle(font: "Roboto-Bold", field: 0xA5272D, text: 0xFFFFFF, lead: .slash(0xFFCA40), marks: .perSystem,
                  systemMark: mark)
    }

    /// Each railway's lettering. The bundled faces are registered at launch; if they aren't (in
    /// tests), Core Text substitutes a close system font and measurements stay sensible.
    public static func fontName(_ system: TransitSystem) -> String { style(system).font }

    /// Letters inside line discs and badges: bold (WMATA's discs use weight 750, NYCT's bullets
    /// Helvetica Bold).
    public static let discLetterFont = "HelveticaNeue-Bold"

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
        /// The agency colour stripe on signs that have one.
        public var stripe: CGFloat { fontSize * 0.38 }
        /// Amtrak's blue curve at the leading end of the sign.
        public var curve: CGFloat { fontSize * 1.9 }
        /// MDOT MTA's gold slash at the leading end of the sign.
        public var slash: CGFloat { fontSize * 0.9 }
        /// MBTA's line-colour band and NYCT's white rule.
        public var band: CGFloat { fontSize * 0.28 }
        public var rule: CGFloat { max(0.8, fontSize * 0.09) }
        public var dot: CGFloat { fontSize * 0.62 }
        public var dotSpacing: CGFloat { fontSize * 0.24 }
        public var textToDots: CGFloat { fontSize * 0.5 }
        public var cornerRadius: CGFloat { fontSize * 0.22 }
        public init(fontSize: CGFloat) { self.fontSize = fontSize }
    }

    /// Lines to mark on a sign: one per line where the railway marks lines (Metrorail, NYCT,
    /// SEPTA Metro, MBTA subway, PATH), one per railway otherwise (MARC's three lines share a disc).
    /// Lines of another system stopping here follow the station's own system's style of mark.
    public static func marks(station: Int, rail: RailNetwork) -> [Int] {
        var seen = Set<String>()
        let lines = (rail.linesAtStation[safe: station] ?? []).filter { l in
            let line = rail.lines[l]
            let perLine = style(line.system).marks != .perSystem
            // Lines whose marks would look identical (LIRR's branches, MBTA's two Red Line branches) are one mark.
            let key = perLine ? "\(line.system.rawValue):\(markText(line) ?? line.id):\(line.color)" : "\(line.system.rawValue)"
            return seen.insert(key).inserted
        }
        return lines.sorted { a, b in
            let sa = rail.lines[a].system, sb = rail.lines[b].system
            let own = rail.stations[station].system
            if (sa == own) != (sb == own) { return sa == own }
            return sa != sb ? sa < sb : a > b
        }
    }

    /// The letter or route code a line's mark carries, if it has one.
    public static func markText(_ line: RailLine) -> String? {
        switch line.system {
        case .metrorail: line.name.first.map { String($0) }
        case .nycSubway: line.shortName
        case .septaMetro: line.shortName
        case .mbtaSubway: line.shortName.count == 1 ? line.shortName : nil   // Green Line B, C, D, E
        default: nil
        }
    }

    /// The colour of a line's mark on a sign.
    public static func markColor(_ line: RailLine) -> UInt32 {
        let s = style(line.system)
        return s.marks == .perSystem ? s.systemMark ?? line.color : line.color
    }

    public static func markWidth(_ line: RailLine, _ m: Metrics) -> CGFloat {
        guard style(line.system).marks == .badges, let t = markText(line) else { return m.dot }
        return textWidth(t, font: discLetterFont, fontSize: m.dot * 0.78) + m.dot * 0.55
    }

    public static func marksWidth(_ marks: [Int], rail: RailNetwork, _ m: Metrics) -> CGFloat {
        guard !marks.isEmpty else { return 0 }
        let lines = marks.map { rail.lines[$0] }
        return m.textToDots + lines.reduce(0) { $0 + markWidth($1, m) } + CGFloat(marks.count - 1) * m.dotSpacing
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

    /// Width before the text: Amtrak's curve, MTA's slash, a stripe, or nothing.
    public static func lead(_ system: TransitSystem, _ m: Metrics) -> CGFloat {
        switch style(system).lead {
        case .none, .band, .topRule: 0
        case .curve: m.curve
        case .slash: m.slash
        case .stripe: m.stripe
        case .stripes: m.stripe * 1.7
        }
    }

    public static func size(name: String, system: TransitSystem, marks: [Int], rail: RailNetwork, fontSize: CGFloat) -> CGSize {
        let m = Metrics(fontSize: fontSize)
        let w = m.padding * 2 + textWidth(name, system: system, fontSize: fontSize) + lead(system, m) + marksWidth(marks, rail: rail, m)
        return CGSize(width: ceil(w), height: ceil(m.height))
    }
}
