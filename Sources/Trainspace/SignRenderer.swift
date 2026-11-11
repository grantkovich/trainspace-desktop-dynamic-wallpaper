import SwiftUI
import TrainspaceCore

/// Draws a station-name sign in Trainspace's own style (see `StationSigns`). One renderer for
/// the small signs on the map and the large one heading station view.
enum SignRenderer {
    /// A line's own colour, from its agency's GTFS (dots and board marks).
    static func lineColor(_ line: RailLine) -> RGBA { RGBA(hex: line.color) }

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
        c.fill(shape, with: .color(RGBA(hex: style.field).color))
        // The leading stripe takes the colour of the station's own line.
        let own = marks.map { rail.lines[$0] }.first { $0.system == system } ?? rail.lines.first { $0.system == system }
        let stripe = own.map(StationSigns.markColor) ?? style.text
        c.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: m.stripe, height: rect.height)), with: .color(RGBA(hex: stripe).color))
        ctx.stroke(shape, with: .color(.black.opacity(0.4)), lineWidth: 0.6)

        let x = rect.minX + m.padding + StationSigns.lead(system, m)
        let font = Font.custom(StationSigns.fontName(system), size: fontSize)
        ctx.draw(Text(name).font(font).foregroundColor(RGBA(hex: style.text).color), at: CGPoint(x: x, y: rect.midY), anchor: .leading)
        let textWidth = StationSigns.textWidth(name, system: system, fontSize: fontSize)

        var dx = x + textWidth + m.textToDots
        for l in marks {
            drawMark(rail.lines[l], in: CGRect(x: dx, y: rect.midY - m.dot / 2, width: m.dot, height: m.dot), ctx: &ctx)
            dx += m.dot + m.dotSpacing
        }
    }

    /// One line's mark: a plain dot in its colour, outlined when the colour would vanish on the plate.
    static func drawMark(_ line: RailLine, in r: CGRect, ctx: inout GraphicsContext) {
        let color = RGBA(hex: StationSigns.markColor(line))
        let shape = Path(ellipseIn: r)
        ctx.fill(shape, with: .color(color.color))
        if color.luminance < 0.08 || color.luminance > 0.85 {
            ctx.stroke(shape, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
        }
    }
}

/// A station's sign at any size, as a view (station view's header).
struct StationSign: View {
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
