import SwiftUI
import TrainspaceCore

/// The quiet typographic block in one corner: place, time, count, the line key and the nearest train.
struct InfoCorner: View {
    let model: AppModel
    let palette: Palette
    let size: CGSize
    let insets: EdgeInsets

    static let margin: CGFloat = 52
    static let width: CGFloat = 420

    /// Approximate area the block occupies, so map labels can stay out of it.
    static func footprint(corner: Corner, size: CGSize, insets: EdgeInsets, legendRows: Int = 0) -> CGRect {
        let h: CGFloat = 230 + (legendRows > 0 ? CGFloat(legendRows) * 21 + 44 : 0)
        let x = corner == .topLeft || corner == .bottomLeft ? insets.leading + margin - 12 : size.width - insets.trailing - margin - width + 12
        let y = corner == .topLeft || corner == .topRight ? insets.top + margin - 12 : size.height - insets.bottom - margin - h + 12
        return CGRect(x: x, y: y, width: width, height: h)
    }

    private var corner: Corner { model.settings.infoCorner }
    private var isTop: Bool { corner == .topLeft || corner == .topRight }
    private var isLeading: Bool { corner == .topLeft || corner == .bottomLeft }
    private var hAlign: HorizontalAlignment { isLeading ? .leading : .trailing }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = model.clockOverride ?? timeline.date
            VStack(alignment: hAlign, spacing: 18) {
                if isTop {
                    placeBlock(now: now)
                    nearestBlock
                    legendBlock
                } else {
                    legendBlock
                    nearestBlock
                    placeBlock(now: now)
                }
            }
            .multilineTextAlignment(isLeading ? .leading : .trailing)
            .frame(width: Self.width, alignment: isLeading ? .leading : .trailing)
            .background {
                // Apple's map has its own labels; give the text a soft plate on that style only.
                if model.settings.mapStyle == .appleMap && model.center != nil {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(palette.land.color.opacity(0.88))
                        .padding(-30)
                        .blur(radius: 22)
                }
            }
            .padding(EdgeInsets(top: insets.top + Self.margin, leading: insets.leading + Self.margin,
                                bottom: insets.bottom + Self.margin, trailing: insets.trailing + Self.margin))
            .frame(width: size.width, height: size.height,
                   alignment: Alignment(horizontal: hAlign, vertical: isTop ? .top : .bottom))
        }
        .allowsHitTesting(false)
    }

    // MARK: Place

    @ViewBuilder
    private func placeBlock(now: Date) -> some View {
        VStack(alignment: hAlign, spacing: 8) {
            Text(model.placeName.uppercased())
                .font(Typeface.display(34))
                .tracking(5)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(palette.textPrimary.color)
            Text(metaLine(now: now))
                .font(Typeface.mono(11, .medium))
                .tracking(1.2)
                .foregroundStyle(palette.textSecondary.color)
            if let status = statusLine(now: now) {
                Text(status)
                    .font(Typeface.mono(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(palette.warning.color)
            }
        }
    }

    private func metaLine(now: Date) -> String {
        var parts: [String] = []
        if model.settings.infoShowCoordinates, let c = model.center { parts.append(Format.coordinate(c)) }
        if model.settings.infoShowClock { parts.append(now.formatted(date: .omitted, time: .shortened).uppercased()) }
        if model.settings.infoShowCount, model.center != nil {
            parts.append(model.trainsInView == 1 ? "1 TRAIN" : "\(model.trainsInView) TRAINS")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func statusLine(now: Date) -> String? {
        if model.center == nil {
            if model.locationMessage != nil { return "LOCATION UNAVAILABLE · OPEN TRAINSPACE SETTINGS" }
            return model.settings.hasCompletedOnboarding ? "LOCATING…" : "CHOOSE A LOCATION FROM THE MENU BAR"
        }
        if model.isOutsideRegion { return "OUTSIDE THE DC–BALTIMORE RAIL NETWORK" }
        if model.paused { return "PAUSED" }
        if model.isStale { return "NO SIGNAL · SHOWING TIMETABLE · UPDATED \(Format.ago(model.lastSuccess, now: now))" }
        return nil
    }

    // MARK: Legend

    static func legendRows(_ model: AppModel) -> Int {
        guard model.settings.infoEnabled, model.settings.infoShowLegend, model.settings.colorMode != .monochrome else { return 0 }
        let n = model.legend.entries.count
        return n == 0 ? 0 : n + (model.legend.entries.contains { $0.scheduled } ? 1 : 0)
    }

    @ViewBuilder
    private var legendBlock: some View {
        if Self.legendRows(model) > 0 {
            let entries = model.legend.entries
            VStack(alignment: hAlign, spacing: 5) {
                Text(model.settings.colorMode == .line ? "LINES IN VIEW" : "SYSTEMS IN VIEW")
                    .font(Typeface.caption(9.5))
                    .tracking(2.4)
                    .foregroundStyle(palette.textTertiary.color)
                    .padding(.bottom, 3)
                ForEach(entries) { entry in
                    legendRow(name: entry.name, count: entry.count, color: palette.lineColor(entry.color), hollow: entry.scheduled)
                }
                if entries.contains(where: \.scheduled) {
                    HStack(spacing: 10) {
                        TrainMark(color: palette.textTertiary, outline: palette.land, hollow: true)
                            .frame(width: 16, height: 16)
                        Text("Hollow: timetable estimate")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.textTertiary.color)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 230)
                }
            }
            .frame(maxWidth: .infinity, alignment: isLeading ? .leading : .trailing)
        }
    }

    private func legendRow(name: String, count: Int, color: RGBA, hollow: Bool) -> some View {
        HStack(spacing: 10) {
            TrainMark(color: color, outline: palette.land, hollow: hollow)
                .frame(width: 16, height: 16)
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.textPrimary.color)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(count)")
                .font(Typeface.mono(11, .medium))
                .foregroundStyle(palette.textSecondary.color)
        }
        .frame(width: 230)
    }

    // MARK: Nearest

    @ViewBuilder
    private var nearestBlock: some View {
        if model.settings.infoShowNearest, let center = model.center, let id = model.nearestID,
           let t = model.tracker.trains[id] {
            let r = t.latest
            let miles = Geo.distanceNM(r.position, center) / Geo.nmPerMile
            VStack(alignment: hAlign, spacing: 5) {
                Text("NEAREST")
                    .font(Typeface.caption(9.5))
                    .tracking(2.4)
                    .foregroundStyle(palette.textTertiary.color)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if !isLeading { Spacer(minLength: 0) }
                    Text(nearestTitle(r))
                        .font(Typeface.mono(22, .semibold))
                        .tracking(1.5)
                        .foregroundStyle(palette.textPrimary.color)
                        .lineLimit(1)
                    TrainMark(color: model.color(for: r, palette: palette), outline: palette.land, hollow: r.isScheduled)
                        .frame(width: 18, height: 18)
                    if isLeading { Spacer(minLength: 0) }
                }
                if let line = routeLine(r) {
                    Text(line)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1)
                }
                Text(statsLine(r, miles: miles))
                    .font(Typeface.mono(10.5, .medium))
                    .tracking(1)
                    .foregroundStyle(palette.textSecondary.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: isLeading ? .leading : .trailing)
        }
    }

    /// "MARC 677", "RD 104", "LIGHT RAIL".
    private func nearestTitle(_ r: TrainReport) -> String {
        let label = model.label(r)
        if r.system == .metrorail, let n = r.trainNumber, !n.isEmpty, !r.isScheduled { return "\(label) \(n)" }
        if r.system == .lightRail || r.system == .subway { return r.system == .lightRail ? "LIGHT RAIL" : "METRO SUBWAY" }
        return label
    }

    private func routeLine(_ r: TrainReport) -> String? {
        let lineName = model.line(of: r)?.name ?? r.system.name
        if let dest = r.headsign { return "\(lineName)  →  \(dest.capitalized(with: Locale(identifier: "en_US")))" }
        return lineName
    }

    private func statsLine(_ r: TrainReport, miles: Double) -> String {
        var parts: [String] = [r.isScheduled ? "TIMETABLE" : "LIVE"]
        switch r.status {
        case .stopped: parts.append("AT STATION")
        case .arriving: parts.append("ARRIVING")
        default: if let s = Format.speed(r.speedMph) { parts.append(s) }
        }
        parts.append(Format.distance(miles: miles))
        return parts.joined(separator: "  ·  ")
    }
}

/// A small train mark for legends and the info corner, matching the map's glyph.
struct TrainMark: View {
    let color: RGBA
    let outline: RGBA
    var hollow = false

    var body: some View {
        Canvas { ctx, size in
            let path = Glyphs.metro
            let box = path.boundingBoxOfPath
            let s = min(size.width, size.height) / max(box.width, box.height) * 0.95
            let t = CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(rotationAngle: .pi / 4))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
            let shape = Path(path).applying(t)
            ctx.stroke(shape, with: .color(outline.color), lineWidth: 2)
            if hollow {
                ctx.fill(shape, with: .color(outline.color))
                ctx.stroke(shape, with: .color(color.color), lineWidth: 1.3)
            } else {
                ctx.fill(shape, with: .color(color.color))
            }
        }
    }
}
