import SwiftUI
import TrainspaceCore

/// Draws a station-name sign per its railway's standards (see `StationSigns` for sources).
/// One renderer for the small signs on the map and the large one heading station view.
enum SignRenderer {
    /// A line's own colour, as the agency prints it (route bullets, discs, board badges).
    static func lineColor(_ line: RailLine) -> RGBA { RGBA(hex: line.color) }

    /// The letter colour on a line's disc or badge: the agency's own (GTFS route_text_color).
    static func lineInk(_ line: RailLine) -> RGBA { RGBA(hex: line.textColor) }

    // MARK: Drawing

    /// - Parameters:
    ///   - rect: the sign, sized by `StationSigns.size`.
    ///   - marks: line indices to show after the name (`StationSigns.marks`).
    static func draw(name: String, system: TransitSystem, marks: [Int], rail: RailNetwork, fontSize: CGFloat,
                     in rect: CGRect, shadow: Double, ctx: inout GraphicsContext) {
        let m = StationSigns.Metrics(fontSize: fontSize)
        let style = StationSigns.style(system)
        let shape = Path(roundedRect: rect, cornerRadius: m.cornerRadius)
        if shadow > 0 { ctx.fill(shape.offsetBy(dx: 0, dy: max(0.8, fontSize * 0.08)), with: .color(.black.opacity(shadow))) }

        var c = ctx
        c.clip(to: shape)
        if let end = style.fieldEnd {
            // Brushed metal: light, darker, light.
            let a = RGBA(hex: style.field).color, b = RGBA(hex: end).color
            c.fill(shape, with: .linearGradient(Gradient(colors: [a, b, a]), startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        } else {
            c.fill(shape, with: .color(RGBA(hex: style.field).color))
        }
        let firstLine = rail.lines.first { $0.system == system }
        switch style.lead {
        case .none:
            break
        case .curve(let color):
            var curve = Path()
            curve.move(to: CGPoint(x: rect.minX, y: rect.minY))
            curve.addLine(to: CGPoint(x: rect.minX + m.curve * 0.55, y: rect.minY))
            curve.addQuadCurve(to: CGPoint(x: rect.minX + m.curve * 0.95, y: rect.maxY),
                               control: CGPoint(x: rect.minX + m.curve * 1.05, y: rect.minY + rect.height * 0.2))
            curve.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            curve.closeSubpath()
            c.fill(curve, with: .color(RGBA(hex: color).color))
        case .slash(let color):
            var slash = Path()
            slash.move(to: CGPoint(x: rect.minX, y: rect.minY))
            slash.addLine(to: CGPoint(x: rect.minX + m.slash * 0.75, y: rect.minY))
            slash.addLine(to: CGPoint(x: rect.minX + m.slash * 0.35, y: rect.maxY))
            slash.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            slash.closeSubpath()
            c.fill(slash, with: .color(RGBA(hex: color).color))
        case .stripe(let color):
            // No fixed colour: the colour of the line serving the station (LIRR and Metro-North branches).
            let line = marks.first.map { rail.lines[$0] }.flatMap { $0.system == system ? $0 : nil } ?? firstLine
            let hex = color ?? line?.color ?? style.text
            c.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: m.stripe, height: rect.height)), with: .color(RGBA(hex: hex).color))
        case .stripes(let a, let b):
            let w = m.stripe * 0.6
            c.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)), with: .color(RGBA(hex: a).color))
            c.fill(Path(CGRect(x: rect.minX + w * 1.6, y: rect.minY, width: w * 0.8, height: rect.height)),
                   with: .color(RGBA(hex: b).color))
        case .band:
            // MBTA: the station's line colours side by side along the bottom.
            let own = marks.map { rail.lines[$0] }.filter { $0.system == system }
            var colors: [UInt32] = []
            for l in own where !colors.contains(StationSigns.markColor(l)) { colors.append(StationSigns.markColor(l)) }
            if colors.isEmpty { colors = [firstLine.map(StationSigns.markColor) ?? style.text] }
            let w = rect.width / CGFloat(colors.count)
            for (i, hex) in colors.enumerated() {
                c.fill(Path(CGRect(x: rect.minX + CGFloat(i) * w, y: rect.maxY - m.band, width: w + 0.5, height: m.band)),
                       with: .color(RGBA(hex: hex).color))
            }
        case .topRule:
            c.fill(Path(CGRect(x: rect.minX, y: rect.minY + m.rule * 1.2, width: rect.width, height: m.rule)),
                   with: .color(.white.opacity(0.92)))
        }
        let light = style.fieldEnd != nil
        ctx.stroke(shape, with: .color(.black.opacity(light ? 0.25 : 0.4)), lineWidth: 0.6)

        let x = rect.minX + m.padding + StationSigns.lead(system, m)
        let font = Font.custom(StationSigns.fontName(system), size: fontSize)
        let textY = style.lead == .band ? rect.midY - m.band * 0.35 : style.lead == .topRule ? rect.midY + m.rule * 0.6 : rect.midY
        ctx.draw(Text(name).font(font).foregroundColor(RGBA(hex: style.text).color), at: CGPoint(x: x, y: textY), anchor: .leading)
        let textWidth = StationSigns.textWidth(name, system: system, fontSize: fontSize)

        var dx = x + textWidth + m.textToDots
        for l in marks {
            let line = rail.lines[l]
            let w = StationSigns.markWidth(line, m)
            drawMark(line, in: CGRect(x: dx, y: textY - m.dot / 2, width: w, height: m.dot), ctx: &ctx)
            dx += w + m.dotSpacing
        }
    }

    /// One line's mark: a disc (lettered when the line has a letter and there's room for it) or,
    /// for SEPTA Metro, a rounded badge with the route code.
    static func drawMark(_ line: RailLine, in r: CGRect, ctx: inout GraphicsContext) {
        let lineStyle = StationSigns.style(line.system)
        let color = RGBA(hex: StationSigns.markColor(line))
        let shape = lineStyle.marks == .badges ? Path(roundedRect: r, cornerRadius: r.height * 0.28) : Path(ellipseIn: r)
        ctx.fill(shape, with: .color(color.color))
        if lineStyle.marks == .perSystem, color.luminance < 0.08 || color.luminance > 0.85 {
            ctx.stroke(shape, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
        }
        guard let text = StationSigns.markText(line), r.height >= 7 else { return }
        // Letters as on each agency's discs: about 70% of the disc (wmata.com's 20 px discs carry 14 px letters).
        let size = r.height * (text.count > 1 && lineStyle.marks != .badges ? 0.52 : 0.7)
        ctx.draw(Text(text).font(.custom(StationSigns.discLetterFont, size: size)).foregroundColor(lineInk(line).color),
                 at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
    }
}

/// A station's sign at any size, as a view (station view's header).
struct AgencySign: View {
    let station: Int
    let rail: RailNetwork
    let fontSize: CGFloat

    var body: some View {
        let s = rail.stations[station]
        let name = StationSigns.displayName(station: station, rail: rail)
        let marks = StationSigns.marks(station: station, rail: rail)
        let size = StationSigns.size(name: name, system: s.system, marks: marks, rail: rail, fontSize: fontSize)
        Canvas { ctx, size in
            SignRenderer.draw(name: name, system: s.system, marks: marks, rail: rail, fontSize: fontSize,
                              in: CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: size.width, height: size.height - 4)),
                              shadow: 0.35, ctx: &ctx)
        }
        .frame(width: size.width, height: size.height + 4)
    }
}
