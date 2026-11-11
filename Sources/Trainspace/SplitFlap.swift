import SwiftUI
import TrainspaceCore

/// Remembers what each flap shows, so a change rolls through the flaps like a mechanical board.
@MainActor
final class FlapMemory {
    struct Cell {
        var from: Character
        var to: Character
        var start: TimeInterval
    }
    private var cells: [Int: Cell] = [:]
    private(set) var lastChange: TimeInterval = 0

    /// The flaps on a real board, in the order they turn.
    static let sequence: [Character] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.-/&'+")
    static let stepDuration = 0.045

    func isAnimating(at now: TimeInterval) -> Bool { now - lastChange < 2.2 }

    /// What cell `id` shows at `now` when it should read `target`: the character, and how far
    /// through the current flip it is (0 = settled).
    func show(_ id: Int, target raw: Character, at now: TimeInterval) -> (Character, Double) {
        let target = Self.flappable(raw)
        guard var cell = cells[id] else {
            cells[id] = Cell(from: target, to: target, start: 0)
            return (target, 0)
        }
        if cell.to != target {
            let current = Self.current(cell, at: now).0
            cell = Cell(from: current, to: target, start: now)
            cells[id] = cell
            lastChange = now
        }
        return Self.current(cell, at: now)
    }

    private static func current(_ cell: Cell, at now: TimeInterval) -> (Character, Double) {
        guard let a = sequence.firstIndex(of: cell.from), let b = sequence.firstIndex(of: cell.to), a != b else { return (cell.to, 0) }
        let steps = (b - a + sequence.count) % sequence.count
        let elapsed = max(0, now - cell.start) / stepDuration
        guard elapsed < Double(steps) else { return (cell.to, 0) }
        let k = Int(elapsed)
        return (sequence[(a + k) % sequence.count], elapsed - Double(k))
    }

    static func flappable(_ c: Character) -> Character {
        let u = Character(c.uppercased())
        return sequence.contains(u) ? u : " "
    }
}

/// A Solari-style split-flap departures board.
struct SplitFlapBoard: View {
    struct Field {
        var text: String
        var width: Int
        var alignRight = false
        var color: RGBA? = nil
        /// Remark flaps can be printed in colour, like a red CANCELLED.
        var flapColor: RGBA? = nil
    }

    let title: String
    let headers: [(String, Int)]
    let rows: [[Field]]
    let memory: FlapMemory
    let now: Date

    static let cell = CGSize(width: 14, height: 23)
    static let cellGap: CGFloat = 2
    static let fieldGap: CGFloat = 9
    static let rowGap: CGFloat = 5
    static let headerHeight: CGFloat = 64
    static let padding: CGFloat = 16

    static func size(widths: [Int], rows: Int) -> CGSize {
        let cols = widths.reduce(0, +)
        let w = CGFloat(cols) * (cell.width + cellGap) + CGFloat(max(0, widths.count - 1)) * fieldGap + padding * 2
        let h = headerHeight + CGFloat(rows) * (cell.height + rowGap) + padding
        return CGSize(width: w, height: h)
    }

    static let ink = RGBA(hex: 0xF3EFE4)

    var body: some View {
        let widths = headers.map(\.1)
        let size = Self.size(widths: widths, rows: rows.count)
        let animating = memory.isAnimating(at: now.timeIntervalSince1970)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
            Canvas { ctx, size in
                let t = max(now, timeline.date).timeIntervalSince1970
                draw(in: &ctx, size: size, widths: widths, t: t)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, widths: [Int], t: TimeInterval) {
        let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
        ctx.fill(frame, with: .linearGradient(Gradient(colors: [RGBA(hex: 0x141414).color, RGBA(hex: 0x070707).color]),
                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(frame, with: .color(RGBA(hex: 0x2A2A2A).color), lineWidth: 1.5)

        // Title strip and column headings, painted on the housing like the board's own lettering.
        let p = Self.padding
        ctx.draw(Text(title).font(.custom("Helvetica-Bold", size: 15)).tracking(3).foregroundColor(Self.ink.color),
                 at: CGPoint(x: p, y: p + 6), anchor: .leading)
        var x = p
        for (i, (heading, w)) in headers.enumerated() {
            ctx.draw(Text(heading).font(.custom("Helvetica", size: 9.5)).tracking(1.6).foregroundColor(RGBA(hex: 0xA8A398).color),
                     at: CGPoint(x: x, y: Self.headerHeight - 12), anchor: .leading)
            x += CGFloat(w) * (Self.cell.width + Self.cellGap) + (i < headers.count - 1 ? Self.fieldGap : 0)
        }

        let font = Font.custom("HelveticaNeue-CondensedBold", size: 19)
        var resolved: [String: GraphicsContext.ResolvedText] = [:]
        let resolver = ctx
        func glyph(_ c: Character, _ color: RGBA) -> GraphicsContext.ResolvedText {
            let key = "\(c)|\(color.r)\(color.g)\(color.b)"
            if let r = resolved[key] { return r }
            let r = resolver.resolve(Text(String(c)).font(font).foregroundColor(color.color))
            resolved[key] = r
            return r
        }

        for (r, fields) in rows.enumerated() {
            var cx = p
            let y = Self.headerHeight + CGFloat(r) * (Self.cell.height + Self.rowGap)
            var cellID = r * 1000
            for f in fields {
                var text = Array(f.text.uppercased().prefix(f.width))
                if f.alignRight { text = Array(repeating: " ", count: f.width - text.count) + text }
                else { text += Array(repeating: " ", count: f.width - text.count) }
                for c in text {
                    let (shown, phase) = MainActor.assumeIsolated { memory.show(cellID, target: c, at: t) }
                    drawFlap(shown, phase: phase, at: CGPoint(x: cx, y: y), ink: f.color ?? Self.ink, flap: f.flapColor,
                             glyph: glyph, in: &ctx)
                    cx += Self.cell.width + Self.cellGap
                    cellID += 1
                }
                cx += Self.fieldGap
            }
        }
    }

    private func drawFlap(_ c: Character, phase: Double, at o: CGPoint, ink: RGBA, flap: RGBA?,
                          glyph: (Character, RGBA) -> GraphicsContext.ResolvedText, in ctx: inout GraphicsContext) {
        let rect = CGRect(origin: o, size: Self.cell)
        let base = flap ?? RGBA(hex: 0x1D1D1D)
        let shape = Path(roundedRect: rect, cornerRadius: 2)
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [RGBA.mix(base, .init(1, 1, 1), 0.06).color,
                                                                RGBA.mix(base, .init(0, 0, 0), 0.25).color]),
                                              startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        if c != " " {
            ctx.draw(glyph(c, ink), at: CGPoint(x: rect.midX, y: rect.midY + 0.5), anchor: .center)
        }
        // The hinge: a dark split across the middle of every flap.
        var split = Path()
        split.move(to: CGPoint(x: rect.minX, y: rect.midY))
        split.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        ctx.stroke(split, with: .color(.black.opacity(0.85)), lineWidth: 1.1)
        // Mid-flip: the falling top flap darkens as it turns past horizontal.
        if phase > 0 {
            let h = rect.height / 2 * CGFloat(1 - phase)
            let falling = CGRect(x: rect.minX, y: rect.midY - h, width: rect.width, height: h)
            ctx.fill(Path(falling), with: .color(.black.opacity(0.35 + 0.4 * phase)))
        }
    }
}
