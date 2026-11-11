import SwiftUI
import TrainspaceCore

/// The kinds of departure sign a station can have, after the real ones on its platforms.
enum BoardStyle: Hashable {
    /// The great hall: a split-flap board (Union Station, Penn Station, Grand Central, 30th Street,
    /// South Station).
    case splitFlap
    /// Metrorail's platform signs: LN CAR DEST MIN in orange LEDs.
    case metrorail
    /// MDOT MTA's Light RailLink and Metro SubwayLink signs.
    case mta(TransitSystem)
    /// Commuter-rail platform signs (MARC, VRE, LIRR, Metro-North, NJ TRANSIT, SEPTA, MBTA, Amtrak).
    case commuter
    /// A metro platform's countdown sign: route mark, destination, minutes (NYCT, PATH, SEPTA Metro,
    /// PATCO, MBTA, NJ TRANSIT light rail).
    case countdown(TransitSystem)

    /// Platform signs count down to the next train; boards list the timetable.
    var countsDown: Bool {
        switch self {
        case .splitFlap, .commuter: false
        case .metrorail, .mta, .countdown: true
        }
    }
}

struct BoardSpec: Hashable, Identifiable {
    var id: String { "\(style)" }
    var style: BoardStyle
    var systems: Set<TransitSystem>
    var rows: Int
    var caption: String
}

struct StationBoardContent: Equatable, Identifiable {
    var id: String { spec.id }
    var spec: BoardSpec
    var departures: [Departure]
}

enum StationBoards {
    /// Hubs with a great hall get the split-flap board (`Region.hubCodes`, `Region.hubNames`);
    /// everywhere else gets platform signs.
    static func isHub(_ s: Station) -> Bool {
        Region.all.contains { $0.hubCodes.contains(s.code) || $0.hubNames.contains(s.name) }
    }

    static func specs(station: Int, network: RailNetwork, enabled: Set<TransitSystem>) -> [BoardSpec] {
        guard let s = network.stations[safe: station] else { return [] }
        let systems = network.systems(at: station).intersection(enabled)
        var out: [BoardSpec] = []
        let mainline = systems.filter(\.isMainline)
        if !mainline.isEmpty {
            if isHub(s) {
                out.append(BoardSpec(style: .splitFlap, systems: mainline, rows: 10, caption: "Departures"))
            } else {
                out.append(BoardSpec(style: .commuter, systems: mainline, rows: 4,
                                     caption: mainline.sorted().map(\.name).joined(separator: " · ")))
            }
        }
        for system in systems.sorted() where !system.isMainline {
            switch system {
            case .metrorail:
                out.append(BoardSpec(style: .metrorail, systems: [.metrorail], rows: 4, caption: "Metrorail"))
            case .lightRail, .subway:
                out.append(BoardSpec(style: .mta(system), systems: [system], rows: 3, caption: system.name))
            default:
                out.append(BoardSpec(style: .countdown(system), systems: [system], rows: system == .nycSubway ? 5 : 4,
                                     caption: system.name))
            }
        }
        return out
    }
}

/// How each metro's countdown sign looks: its LED colour, and how it marks the route.
struct CountdownLook {
    enum Mark { case none, bullet, dot, badge }
    var led: RGBA
    var mark: Mark
    /// "ARR"/"BRD" (MBTA, like Metrorail) or "min" counts all the way down (NYCT).
    var arrBrd: Bool
    var header: String

    static func of(_ system: TransitSystem) -> CountdownLook {
        switch system {
        // NYCT's platform countdown clocks: route bullet, destination, minutes, in red-orange LEDs.
        case .nycSubway, .statenIsland: CountdownLook(led: RGBA(hex: 0xFF5F1A), mark: .bullet, arrBrd: false, header: "")
        // PATH's platform signs: a dot in the route's map colour, then the destination.
        case .path: CountdownLook(led: RGBA(hex: 0xFFB000), mark: .dot, arrBrd: false, header: "TRAIN TO")
        // SEPTA Metro's new wayfinding gives every line a coloured route code.
        case .septaMetro: CountdownLook(led: RGBA(hex: 0xFFAE1F), mark: .badge, arrBrd: false, header: "")
        case .patco: CountdownLook(led: RGBA(hex: 0xFF3B26), mark: .none, arrBrd: false, header: "NEXT TRAIN TO")
        // MBTA's platform signs count down, then ARR and BRD.
        case .mbtaSubway: CountdownLook(led: RGBA(hex: 0xFFB21A), mark: .bullet, arrBrd: true, header: "")
        default: CountdownLook(led: RGBA(hex: 0xFFAE1F), mark: .none, arrBrd: false, header: "NEXT TRAIN TO")
        }
    }
}

// MARK: - Signage colours and type

/// Each agency's own colours and lettering, for signs and labels: the typefaces their websites
/// use (Helvetica, Roboto, Montserrat, Open Sans; the last three bundled).
enum Signage {
    static let metroOrange = RGBA(hex: 0xFF7417)      // Metrorail platform LEDs
    static let commuterAmber = RGBA(hex: 0xFFAE1F)    // MARC / VRE platform signs
    static let mtaRed = RGBA(hex: 0xFF3D22)           // Light RailLink and SubwayLink LEDs
    static let bronze = RGBA(hex: 0x2E2621)           // Metrorail pylons and station-name bands
    static let navy = RGBA(hex: 0x14202C)

    /// Official line colours (not the map palette, which is tuned for the map surface).
    static func official(_ line: RailLine) -> RGBA { SignRenderer.lineColor(line) }

    /// Each agency's typeface (see `StationSigns`), regular or bold weight.
    static func fontName(_ system: TransitSystem, bold: Bool = true) -> String {
        let pairs: [String: (bold: String, regular: String)] = [
            "HelveticaNeue-Medium": ("HelveticaNeue-Bold", "HelveticaNeue-Medium"),
            "HelveticaNeue-Bold": ("HelveticaNeue-Bold", "HelveticaNeue-Medium"),
            "Helvetica-Bold": ("Helvetica-Bold", "Helvetica"),
            "OpenSans-Bold": ("OpenSans-Bold", "OpenSans-SemiBold"),
            "Roboto-Bold": ("Roboto-Bold", "Roboto-Medium"),
            "MontserratThin-SemiBold": ("MontserratThin-Bold", "MontserratThin-SemiBold"),
            "PublicSans-Bold": ("PublicSans-Bold", "PublicSans-SemiBold"),
            "Verdana-Bold": ("Verdana-Bold", "Verdana"),
        ]
        let name = StationSigns.fontName(system)
        guard let p = pairs[name] else { return name }
        return bold ? p.bold : p.regular
    }

    static func font(_ system: TransitSystem, size: CGFloat, bold: Bool = true) -> Font {
        .custom(fontName(system, bold: bold), size: size)
    }

    /// Metrorail's platform signs abbreviate destinations to fit; these are the familiar forms.
    static func metroDestination(_ name: String) -> String {
        let table: [String: String] = [
            "Shady Grove": "Shady Grv", "Grosvenor": "Grsvnor", "Silver Spring": "Silvr Spg",
            "New Carrollton": "NewCrltn", "Downtown Largo": "Largo", "Franconia-Springfield": "Frnconia",
            "Huntington": "Hntingtn", "Mt Vernon Sq": "Mt Vern Sq", "Branch Av": "Brnch Av", "Branch Ave": "Brnch Av",
            "Fort Totten": "Ft Totten", "Wiehle-Reston East": "Wiehle", "West Falls Church": "W Falls Ch",
            "Stadium-Armory": "Stadium", "NoMa-Gallaudet U": "NoMa", "Potomac Yard": "Potomac Yd",
            "Ballston-MU": "Ballston", "Navy Yard-Ballpark": "Navy Yard", "Columbia Heights": "Columbia Hts",
        ]
        return table[name] ?? String(name.prefix(11))
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "h:mm"
        return f.string(from: d)
    }
}

// MARK: - Panel

/// Station view's foreground: the station's name sign and its departure boards.
struct StationPanel: View {
    let model: AppModel
    let palette: Palette
    let now: Date
    @State private var flaps = FlapMemory()

    static let gap: CGFloat = 16

    /// Natural (unscaled) size, so the map and labels can keep clear before anything renders.
    @MainActor static func naturalSize(_ model: AppModel) -> CGSize {
        let boards = model.stationBoards
        var w: CGFloat = 420, h: CGFloat = signHeight + 30
        for b in boards {
            let s = boardSize(b.spec)
            w = max(w, s.width)
            h += s.height + (b.spec.style == .splitFlap ? 0 : 22) + gap
        }
        return CGSize(width: w, height: h)
    }

    static let signHeight: CGFloat = 30 * 1.75 + 4

    static func boardSize(_ spec: BoardSpec) -> CGSize {
        switch spec.style {
        case .splitFlap: SplitFlapBoard.size(widths: splitFlapWidths, rows: spec.rows)
        case .metrorail: LEDSign.size(columns: 22, rows: spec.rows + 1, pitch: 3.0)
        case .mta: LEDSign.size(columns: 24, rows: spec.rows + 1, pitch: 2.8)
        case .commuter: LEDSign.size(columns: 37, rows: spec.rows + 1, pitch: 2.6)
        case .countdown(let system):
            LEDSign.size(columns: 26, rows: spec.rows + (CountdownLook.of(system).header.isEmpty ? 0 : 1), pitch: 2.8)
        }
    }

    static let splitFlapWidths = [5, 6, 4, 16, 10]

    /// Sizes the panel to the display: up to ~60% of its height on big screens, shrunk to fit on
    /// small ones, and never wider than ~55% of the display.
    @MainActor static func scale(_ model: AppModel, size: CGSize, insets: EdgeInsets) -> CGFloat {
        let natural = naturalSize(model)
        let availH = size.height - insets.top - insets.bottom - InfoCorner.margin * 2
        let fit = min(availH / max(1, natural.height), size.width * 0.55 / max(1, natural.width))
        let comfortable = max(1, min(1.6, size.height * 0.6 / max(1, natural.height)))
        return max(0.4, min(fit, comfortable))
    }

    @MainActor static func footprint(_ model: AppModel, size: CGSize, insets: EdgeInsets) -> CGRect {
        let k = scale(model, size: size, insets: insets)
        let n = naturalSize(model)
        let w = n.width * k, h = n.height * k
        let corner = model.settings.infoCorner
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let x = left ? insets.leading + InfoCorner.margin : size.width - insets.trailing - InfoCorner.margin - w
        let y = top ? insets.top + InfoCorner.margin : size.height - insets.bottom - InfoCorner.margin - h
        return CGRect(x: x, y: y, width: w, height: h).insetBy(dx: -12, dy: -12)
    }

    var body: some View {
        if let station = model.selectedStation, let rail = model.rail, rail.stations.indices.contains(station) {
            VStack(alignment: .leading, spacing: Self.gap) {
                AgencySign(station: station, rail: rail, fontSize: 30)
                ForEach(model.stationBoards) { board in
                    VStack(alignment: .leading, spacing: 6) {
                        // The split-flap board letters its own title.
                        if board.spec.style != .splitFlap { caption(board) }
                        boardView(board, rail: rail)
                    }
                }
                footer
            }
            .fixedSize()
        }
    }

    private func caption(_ board: StationBoardContent) -> some View {
        Text(board.spec.caption.uppercased())
            .font(Typeface.caption(9.5))
            .tracking(2.4)
            .foregroundStyle(palette.textSecondary.color)
            .frame(height: 16)
    }

    @ViewBuilder
    private func boardView(_ board: StationBoardContent, rail: RailNetwork) -> some View {
        let deps = board.departures
        switch board.spec.style {
        case .splitFlap:
            SplitFlapBoard(title: "\(model.placeName.uppercased())  ·  DEPARTURES  ·  \(Signage.time(now))",
                           headers: zip(["TIME", "TRAIN", "NO.", "DESTINATION", "REMARKS"], Self.splitFlapWidths).map { ($0, $1) },
                           rows: (0..<board.spec.rows).map { i in deps[safe: i].map { splitFlapRow($0) } ?? blankRow },
                           memory: flaps, now: now)
        case .metrorail:
            let rows: [[LEDSign.Field]] = [[.init(text: "LN", width: 3), .init(text: "CAR", width: 4), .init(text: "DEST", width: 11),
                                           .init(text: "MIN", width: 4, alignRight: true)]]
                + (0..<board.spec.rows).map { i in
                    guard let d = deps[safe: i] else { return [] }
                    return [.init(text: rail.lines[d.line].shortName, width: 3), .init(text: "-", width: 4),
                            .init(text: Signage.metroDestination(d.destination), width: 11),
                            .init(text: metroMinutes(d), width: 4, alignRight: true)]
                }
            LEDSign(rows: rows, color: Signage.metroOrange, pitch: 3.0)
        case .mta(let system):
            let rows: [[LEDSign.Field]] = [[.init(text: system == .lightRail ? "LIGHT RAIL TO" : "SUBWAY TO", width: 18),
                                           .init(text: "MIN", width: 6, alignRight: true)]]
                + (0..<board.spec.rows).map { i in
                    guard let d = deps[safe: i] else { return [] }
                    return [.init(text: d.destination.uppercased(), width: 18), .init(text: mtaMinutes(d), width: 6, alignRight: true)]
                }
            LEDSign(rows: rows, color: Signage.mtaRed, pitch: 2.8)
        case .commuter:
            let rows: [[LEDSign.Field]] = [[.init(text: "TRAIN", width: 10), .init(text: "TO", width: 16),
                                           .init(text: "DEPART", width: 6, alignRight: true), .init(text: "", width: 1),
                                           .init(text: "", width: 4)]]
                + (0..<board.spec.rows).map { i in
                    guard let d = deps[safe: i] else { return [] }
                    let (remark, color) = shortRemark(d)
                    return [.init(text: "\(d.system.labelPrefix ?? "") \(d.trainNumber)", width: 10),
                            .init(text: d.destination.uppercased(), width: 16),
                            .init(text: Signage.time(d.scheduled), width: 6, alignRight: true), .init(text: "", width: 1),
                            .init(text: remark, width: 4, color: color)]
                }
            LEDSign(rows: rows, color: Signage.commuterAmber, pitch: 2.6)
        case .countdown(let system):
            let look = CountdownLook.of(system)
            let header: [[LEDSign.Field]] = look.header.isEmpty ? [] : [[.init(text: look.header, width: 20),
                                                                         .init(text: "MIN", width: 6, alignRight: true)]]
            let markWidth = look.mark == .none ? 0 : look.mark == .badge ? 3 : 2
            let destWidth = 26 - 6 - (markWidth > 0 ? markWidth + 1 : 0)
            let rows: [[LEDSign.Field]] = header + (0..<board.spec.rows).map { i in
                guard let d = deps[safe: i] else { return [] }
                let line = rail.lines[d.line]
                var mark = LEDSign.Field(text: "", width: markWidth)
                switch look.mark {
                case .none: break
                case .dot: mark.badge = .init(color: SignRenderer.lineColor(line), round: true)
                case .bullet, .badge:
                    // The route's own mark: its letter on its colour, as on the station signs.
                    if let text = StationSigns.markText(line) {
                        mark.text = text
                        mark.color = SignRenderer.lineInk(line)
                        mark.badge = .init(color: SignRenderer.lineColor(line), round: look.mark == .bullet)
                    } else {
                        mark.badge = .init(color: SignRenderer.lineColor(line), round: true)
                    }
                }
                return (markWidth > 0 ? [mark, .init(text: "", width: 1)] : [])
                    + [.init(text: countdownDestination(d, width: destWidth), width: destWidth),
                       .init(text: countdownMinutes(d, look), width: 6, alignRight: true)]
            }
            LEDSign(rows: rows, color: look.led, pitch: 2.8, minColumns: 26)
        }
    }

    /// Long names lose what follows the hyphen, as NYCT's clocks do ("Crown Hts", not "Crown Hts-Utica A").
    private func countdownDestination(_ d: Departure, width: Int) -> String {
        let name = d.destination
        guard name.count > width, let dash = name.firstIndex(of: "-"), name.distance(from: name.startIndex, to: dash) >= 4 else {
            return name
        }
        return String(name[..<dash])
    }

    private func countdownMinutes(_ d: Departure, _ look: CountdownLook) -> String {
        if d.status == .cancelled { return "---" }
        let m = minutesAway(d)
        if look.arrBrd {
            if m < 0.5 { return "BRD" }
            if m < 1.5 { return "ARR" }
        } else if m < 0.5 {
            return "0 min"
        }
        return "\(Int(m.rounded(.down))) min"
    }

    private var blankRow: [SplitFlapBoard.Field] {
        Self.splitFlapWidths.map { SplitFlapBoard.Field(text: "", width: $0) }
    }

    private func splitFlapRow(_ d: Departure) -> [SplitFlapBoard.Field] {
        let carrier = d.system == .amtrak ? "AMTRAK" : d.system.labelPrefix ?? d.system.name
        var remark = SplitFlapBoard.Field(text: "", width: 10)
        switch d.status {
        case .scheduled: break
        case .onTime: remark.text = "ON TIME"
        case .early: remark.text = "ON TIME"
        case .late(let m):
            remark.text = m >= 60 ? "LATE \(m / 60)H\(String(format: "%02d", m % 60))" : "LATE \(m) MIN"
            remark.color = RGBA(hex: 0xFFC233)
        case .cancelled: remark.text = "CANCELLED"; remark.flapColor = RGBA(hex: 0x8E1B16)
        }
        return [.init(text: Signage.time(d.scheduled), width: 5, alignRight: true), .init(text: carrier, width: 6),
                .init(text: d.trainNumber, width: 4), .init(text: d.destination, width: 16), remark]
    }

    private func minutesAway(_ d: Departure) -> Double { d.expected.timeIntervalSince(now) / 60 }

    /// Metrorail signs count down in minutes, then show ARR as the train pulls in and BRD while it boards.
    private func metroMinutes(_ d: Departure) -> String {
        if d.status == .cancelled { return "---" }
        let m = minutesAway(d)
        if m < 0.5 { return "BRD" }
        if m < 1.5 { return "ARR" }
        return "\(Int(m.rounded(.down)))"
    }

    private func mtaMinutes(_ d: Departure) -> String {
        if d.status == .cancelled { return "CANCEL" }
        let m = minutesAway(d)
        return m < 1 ? "DUE" : "\(Int(m.rounded(.down))) MIN"
    }

    private func shortRemark(_ d: Departure) -> (String, RGBA?) {
        switch d.status {
        case .scheduled: ("", nil)
        case .onTime, .early: ("OK", nil)
        case .late(let m): ("+\(m)", RGBA(hex: 0xFF5A2A))
        case .cancelled: ("CNCL", RGBA(hex: 0xFF3B30))
        }
    }

    private var footer: some View {
        let live = model.stationBoards.flatMap(\.departures).contains(where: \.isLive)
        let timetableOnly = model.stationBoards.flatMap(\.spec.systems).filter { model.feeds[$0]?.mode != .live }
        var parts = [now.formatted(date: .abbreviated, time: .shortened).uppercased()]
        if live { parts.append("LIVE TIMES WHERE SHOWN") }
        if !timetableOnly.isEmpty {
            parts.append("TIMETABLE: " + Set(timetableOnly).sorted().map { $0.name.uppercased() }.joined(separator: ", "))
        }
        return Text(parts.joined(separator: "  ·  "))
            .font(Typeface.mono(10, .medium))
            .tracking(1)
            .foregroundStyle(palette.textTertiary.color)
    }
}

// MARK: - Model glue

extension AppModel {
    /// The map's projection for one display. In station view the map centres the station in the
    /// open part of the screen, beside the boards.
    func projection(size: CGSize, insets: EdgeInsets) -> Projection? {
        guard let center = mapCenter else { return nil }
        let base = Projection(center: center, size: size, radiusNM: mapRadiusNM)
        guard selectedStation != nil else { return base }
        let panel = StationPanel.footprint(self, size: size, insets: insets)
        let left = settings.infoCorner == .topLeft || settings.infoCorner == .bottomLeft
        let openMid = left ? (panel.maxX + size.width) / 2 : panel.minX / 2
        let shifted = base.coordinate(CGPoint(x: size.width - openMid, y: size.height / 2))
        return Projection(center: shifted, size: size, radiusNM: mapRadiusNM)
    }

    /// Where the panel or info corner sits, for keeping labels clear.
    func overlayRect(size: CGSize, insets: EdgeInsets) -> CGRect? {
        if selectedStation != nil { return StationPanel.footprint(self, size: size, insets: insets) }
        guard settings.infoEnabled else { return nil }
        return InfoCorner.footprint(corner: settings.infoCorner, size: size, insets: insets, legendRows: InfoCorner.legendRows(self))
    }
}
