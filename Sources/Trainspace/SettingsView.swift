import ServiceManagement
import SwiftUI
import TrainspaceCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case location, station, appearance, map, trains, liveData, infoCorner, desktop

    var id: Self { self }

    var title: String {
        switch self {
        case .location: "Location"
        case .station: "Station View"
        case .appearance: "Appearance"
        case .map: "Map"
        case .trains: "Trains"
        case .liveData: "Live Data"
        case .infoCorner: "Info Corner"
        case .desktop: "Desktop & Power"
        }
    }

    var symbol: String {
        switch self {
        case .location: "location.fill"
        case .station: "signpost.right.fill"
        case .appearance: "circle.lefthalf.filled"
        case .map: "map.fill"
        case .trains: "tram.fill"
        case .liveData: "antenna.radiowaves.left.and.right"
        case .infoCorner: "text.alignleft"
        case .desktop: "menubar.dock.rectangle"
        }
    }

    var tint: Color {
        switch self {
        case .location: .blue
        case .station: .brown
        case .appearance: .indigo
        case .map: .green
        case .trains: .red
        case .liveData: .orange
        case .infoCorner: .teal
        case .desktop: .gray
        }
    }
}

/// System Settings–style window: sections in a sidebar; a live preview above each section's controls.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var section: SettingsSection

    init(model: AppModel, initialSection: SettingsSection = .location) {
        self.model = model
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label {
                    Text(s.title)
                } icon: {
                    SectionIcon(symbol: s.symbol, tint: s.tint)
                }
                .tag(s)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsPreview(model: model)
                    Group {
                        switch section {
                        case .location: LocationSettings(model: model)
                        case .station: StationViewSettings(model: model)
                        case .appearance: AppearanceSettings(model: model)
                        case .map: MapSettings(model: model)
                        case .trains: TrainSettings(model: model)
                        case .liveData: LiveDataSettings(model: model)
                        case .infoCorner: InfoSettings(model: model)
                        case .desktop: DesktopSettings(model: model)
                        }
                    }
                }
                .padding(24)
                .toggleStyle(TrailingSwitch())
            }
            .navigationTitle(section.title)
        }
        .frame(width: 820, height: 720)
    }
}

struct SectionIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The wallpaper itself, live, at the main display's aspect ratio.
struct SettingsPreview: View {
    let model: AppModel
    private let width: CGFloat = 548

    var body: some View {
        let screen = model.primaryScreenSize
        let height = (width * screen.height / max(1, screen.width)).rounded()
        TrainspaceView(model: model, size: CGSize(width: width * 2, height: height * 2), insets: EdgeInsets())
            .scaleEffect(0.5, anchor: .topLeading)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Live wallpaper preview")
    }
}

/// A titled group of rows, styled like a grouped Form section.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// System Settings–style toggle: label on the left, small switch on the right.
struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 16)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// One label/control row inside a `SettingsGroup`.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            control.labelsHidden().fixedSize()
        }
    }
}

// MARK: - Visual pickers

/// A selectable card with an illustration and caption, like macOS's Appearance picker.
struct ChoiceCard<Illustration: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var illustration: Illustration

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                illustration
                    .frame(width: 112, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1)
                    )
                Text(title)
                    .font(.callout)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CardRow<T: Hashable, Card: View>: View {
    let options: [T]
    @ViewBuilder var card: (T) -> Card

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(options, id: \.self) { card($0) }
        }
    }
}

/// Mini illustration: a few trains on a stretch of track, drawn with real palette tokens.
struct MiniScene: View {
    let palette: Palette
    var style: MapStyle = .schematic
    var glyph: GlyphStyle = .train
    var colors: [RGBA]? = nil
    var hollow = false

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            switch style {
            case .schematic:
                ctx.fill(Path(rect), with: .color(palette.water.color))
                var land = Path()
                land.move(to: CGPoint(x: 0, y: 0))
                land.addLine(to: CGPoint(x: size.width * 0.62, y: 0))
                land.addCurve(to: CGPoint(x: size.width * 0.55, y: size.height),
                              control1: CGPoint(x: size.width * 0.5, y: size.height * 0.35),
                              control2: CGPoint(x: size.width * 0.7, y: size.height * 0.6))
                land.addLine(to: CGPoint(x: 0, y: size.height))
                land.closeSubpath()
                ctx.fill(land, with: .color(palette.land.color))
            case .appleMap:
                ctx.fill(Path(rect), with: .color(palette.land.color))
                var streets = Path()
                for i in stride(from: 8.0, to: size.width, by: 14) {
                    streets.move(to: CGPoint(x: i, y: 0)); streets.addLine(to: CGPoint(x: i - 6, y: size.height))
                }
                for j in stride(from: 10.0, to: size.height, by: 12) {
                    streets.move(to: CGPoint(x: 0, y: j)); streets.addLine(to: CGPoint(x: size.width, y: j + 3))
                }
                ctx.stroke(streets, with: .color(palette.road.color), lineWidth: 0.8)
                ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.65, y: -10, width: 70, height: 50)), with: .color(palette.water.color))
            case .pureField:
                ctx.fill(Path(rect), with: .color(palette.land.color))
                var dots = Path()
                for x in stride(from: 6.0, to: size.width, by: 10) {
                    for y in stride(from: 6.0, to: size.height, by: 10) {
                        dots.addEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
                    }
                }
                ctx.fill(dots, with: .color(palette.dotGrid.color))
            }
            // Three lines crossing the card, each with a train on it.
            let lines: [(CGPoint, CGPoint, Double)] = [
                (CGPoint(x: 0, y: size.height * 0.3), CGPoint(x: size.width, y: size.height * 0.42), 0.4),
                (CGPoint(x: size.width * 0.3, y: 0), CGPoint(x: size.width * 0.75, y: size.height), 0.7),
                (CGPoint(x: 0, y: size.height * 0.85), CGPoint(x: size.width, y: size.height * 0.62), 0.25),
            ]
            let defaults = [palette.lineColor(0xC80F2D), palette.lineColor(0x009CDE), palette.lineColor(0x8A3FC4)]
            for (i, (a, b, f)) in lines.enumerated() {
                let color = colors.map { $0[i % $0.count] } ?? defaults[i]
                var track = Path()
                track.move(to: a)
                track.addLine(to: b)
                ctx.stroke(track, with: .color(color.with(alpha: palette.trackOpacity).color), lineWidth: 2)
                let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                let heading = atan2(b.x - a.x, a.y - b.y) * 180 / .pi
                MiniScene.drawGlyph(glyph, at: p, heading: heading, color: color, palette: palette, hollow: hollow, in: &ctx)
            }
        }
    }

    static func drawGlyph(_ glyph: GlyphStyle, at p: CGPoint, heading: Double, color: RGBA, palette: Palette, hollow: Bool = false,
                          in ctx: inout GraphicsContext) {
        let t = CGAffineTransform(rotationAngle: heading * .pi / 180).concatenating(CGAffineTransform(translationX: p.x, y: p.y))
        switch glyph {
        case .train:
            let shape = Path(Glyphs.metro).applying(t)
            ctx.stroke(shape, with: .color(palette.land.color), lineWidth: 2)
            if hollow {
                ctx.fill(shape, with: .color(palette.land.color))
                ctx.stroke(shape, with: .color(color.color), lineWidth: 1.3)
            } else {
                ctx.fill(shape, with: .color(color.color))
            }
        case .light:
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                     with: .radialGradient(Gradient(colors: [color.with(alpha: 0.4).color, color.with(alpha: 0).color]),
                                           center: p, startRadius: 0, endRadius: 8))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)), with: .color(color.color))
        case .arrow:
            ctx.fill(Path(Glyphs.arrow).applying(t), with: .color(color.color))
        case .stationLights:
            // A station pill across the track with its LED pair, one lit.
            let rot = StationPill.rotation(trackBearing: heading)
            let pill = StationPill.path(at: p, groups: 1, rotation: rot, scale: 1.25)
            ctx.fill(pill, with: .color(palette.land.color))
            ctx.stroke(pill, with: .color(palette.station.color), lineWidth: 1)
            for side in 0..<2 {
                let c = StationPill.ledCenter(at: p, groups: 1, rotation: rot, group: 0, side: side, scale: 1.25)
                let r = StationPill.led / 2 * 1.25
                if side == 0 {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 3, y: c.y - r * 3, width: r * 6, height: r * 6)),
                             with: .radialGradient(Gradient(colors: [color.with(alpha: 0.45).color, color.with(alpha: 0).color]),
                                                   center: c, startRadius: 0, endRadius: r * 3))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color((side == 0 ? color : StationPill.unlit(palette)).color))
            }
        }
    }
}

// MARK: - Location

struct LocationSettings: View {
    @Bindable var model: AppModel
    @State private var query = ""

    private var usesSystem: Bool {
        if case .system = model.settings.location { return true }
        return false
    }

    var body: some View {
        SettingsGroup(title: "Region", footer: "Each region has its own track, stations and timetables. Choosing a place in another region switches to it.") {
            RegionPicker(model: model).pickerStyle(.segmented).labelsHidden()
        }
        SettingsGroup(title: "Center the map on") {
            HStack(spacing: 8) {
                ForEach(model.region.presets) { preset in
                    Button(preset.name) { model.choose(preset) }
                }
            }
            Divider()
            Picker("Source", selection: Binding(
                get: { usesSystem },
                set: { system in
                    if system { model.useSystemLocation() } else if !query.isEmpty { model.setPlace(query: query) }
                })) {
                Text("My current location").tag(true)
                Text("A place I choose").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                TextField("Zip code, neighborhood, or coordinates", text: $query,
                          prompt: Text(model.region.searchHint))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.setPlace(query: query) }
                Button("Set") { model.setPlace(query: query) }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            HStack {
                Text("Now showing")
                Spacer()
                if model.isResolvingLocation {
                    ProgressView().controlSize(.small)
                } else if let c = model.center {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.placeName)
                        Text(Format.coordinate(c)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
            }
            if let message = model.locationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if model.isOutsideRegion {
                Label("This place is outside the DC–Baltimore rail network.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            switch model.settings.location {
            case let .search(q, _, _): query = q
            case let .coordinates(c, _): query = String(format: "%.4f, %.4f", c.latitude, c.longitude)
            case .system: break
            }
        }

        SettingsGroup(footer: "Shown in the info corner. Leave empty to use the place name.") {
            SettingsRow(title: "Display name") {
                TextField("Display name", text: $model.settings.displayName, prompt: Text(model.placeName))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsGroup(title: "Appearance") {
            CardRow(options: AppearanceMode.allCases) { mode in
                ChoiceCard(title: title(mode), selected: model.settings.appearance == mode) {
                    model.settings.appearance = mode
                } illustration: {
                    switch mode {
                    case .light: MiniScene(palette: .aluminum)
                    case .dark: MiniScene(palette: .night)
                    case .dynamic:
                        HStack(spacing: 0) {
                            MiniScene(palette: .aluminum).frame(width: 56).clipped()
                            MiniScene(palette: .night).frame(width: 56).clipped()
                        }
                    }
                }
            }
            if model.settings.appearance == .dynamic {
                Divider()
                SettingsRow(title: "Dynamic follows") {
                    Picker("Dynamic follows", selection: $model.settings.dynamicSource) {
                        Text("The sun at this location").tag(DynamicSource.sun)
                        Text("macOS appearance").tag(DynamicSource.system)
                    }
                }
            }
        }
        if model.settings.appearance == .dynamic && model.settings.dynamicSource == .sun {
            Text("Fades between Aluminum and Night through dusk and dawn, using civil twilight at your location.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ m: AppearanceMode) -> String {
        switch m {
        case .light: "Aluminum"
        case .dark: "Night"
        case .dynamic: "Dynamic"
        }
    }
}

// MARK: - Map

struct MapSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        let palette = model.palette()
        SettingsGroup(title: "Style") {
            CardRow(options: MapStyle.allCases) { style in
                ChoiceCard(title: title(style), selected: model.settings.mapStyle == style) {
                    model.settings.mapStyle = style
                } illustration: {
                    MiniScene(palette: palette, style: style)
                }
            }
        }

        SettingsGroup(title: "Zoom", footer: "Distance from the center to the nearest screen edge.") {
            HStack(spacing: 12) {
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $model.settings.zoomMiles, in: WallpaperSettings.zoomRange)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Text("\(Int(model.settings.zoomMiles)) mi")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }

        SettingsGroup(title: "Details") {
            Toggle("Track", isOn: $model.settings.showTrack)
            Toggle("Stations", isOn: $model.settings.showStations)
            Toggle("Station names", isOn: $model.settings.showStationNames)
                .disabled(!model.settings.showStations)
            Toggle("Every station's name on its own sign, in its railway's style", isOn: $model.settings.stationSigns)
                .disabled(!model.settings.showStations || !model.settings.showStationNames)
            if model.settings.mapStyle == .schematic {
                Toggle("Major roads", isOn: $model.settings.showRoads)
            }
            Toggle("Range rings", isOn: $model.settings.showRangeRings)
            Toggle("Dot grid", isOn: $model.settings.showDotGrid)
            if model.settings.mapStyle == .appleMap {
                Toggle("Tint Apple Map to match the palette", isOn: $model.settings.tintAppleMap)
            }
        }
    }

    private func title(_ s: MapStyle) -> String {
        switch s {
        case .schematic: "Schematic"
        case .appleMap: "Apple Map"
        case .pureField: "Pure Field"
        }
    }
}

// MARK: - Trains

struct TrainSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        let palette = model.palette()
        SettingsGroup(title: "Systems") {
            ForEach(model.region.systems, id: \.self) { system in
                Toggle(isOn: Binding(
                    get: { model.settings.systems.contains(system) },
                    set: { on in
                        if on { model.settings.systems.insert(system) } else { model.settings.systems.remove(system) }
                    })) {
                    HStack(spacing: 10) {
                        TrainMark(color: palette.lineColor(system.info.color), outline: palette.land)
                            .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(system.name)
                            Text(system.operatorName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FeedBadge(status: model.feeds[system])
                    }
                }
            }
        }

        SettingsGroup(title: "Icon") {
            CardRow(options: GlyphStyle.allCases) { glyph in
                ChoiceCard(title: title(glyph), selected: model.settings.glyph == glyph) {
                    model.settings.glyph = glyph
                } illustration: {
                    MiniScene(palette: palette, style: .pureField, glyph: glyph)
                }
            }
        }

        SettingsGroup(title: "Color", footer: footer) {
            CardRow(options: ColorMode.allCases) { mode in
                ChoiceCard(title: title(mode), selected: model.settings.colorMode == mode) {
                    model.settings.colorMode = mode
                } illustration: {
                    MiniScene(palette: palette, style: .pureField, glyph: model.settings.glyph, colors: sample(mode, palette))
                }
            }
        }

        SettingsGroup(title: "Labels & trails") {
            SettingsRow(title: "Labels") {
                Picker("Labels", selection: $model.settings.labelMode) {
                    Text("Off").tag(LabelMode.off)
                    Text("Line or train number").tag(LabelMode.train)
                    Text("Train + destination").tag(LabelMode.trainDestination)
                }
            }
            SettingsRow(title: "Trails") {
                Picker("Trails", selection: $model.settings.trailMinutes) {
                    Text("Off").tag(0.0)
                    Text("1 minute").tag(1.0)
                    Text("3 minutes").tag(3.0)
                    Text("10 minutes").tag(10.0)
                }
            }
            Toggle("Pulse on each live update", isOn: $model.settings.pulse)
            HStack {
                Text("Brightness")
                Slider(value: $model.settings.brightness, in: 0.3...1)
            }
        }

        SettingsGroup(footer: "Systems without a working live feed show where their trains should be according to the timetable, drawn hollow.") {
            Toggle("Show timetable estimates", isOn: $model.settings.showScheduled)
        }
    }

    private var footer: String {
        switch model.settings.colorMode {
        case .line: "Metrorail lines in their own colors; MARC, VRE, Amtrak, Light RailLink and Metro SubwayLink each in one color. The info corner shows the key."
        case .system: "One color per system."
        case .monochrome: "Every train in one color."
        }
    }

    private func sample(_ mode: ColorMode, _ p: Palette) -> [RGBA] {
        switch mode {
        case .line: [p.lineColor(0xC80F2D), p.lineColor(0xED8B00), p.lineColor(0x00B140)]
        case .system: [p.lineColor(0x009CDE), p.lineColor(0x8A3FC4), p.lineColor(0x2A2B2E)]
        case .monochrome: [p.monochrome]
        }
    }

    private func title(_ g: GlyphStyle) -> String {
        switch g {
        case .train: "Train"
        case .light: "Point of Light"
        case .arrow: "Arrow"
        case .stationLights: "Station Lights"
        }
    }

    private func title(_ m: ColorMode) -> String {
        switch m {
        case .line: "By Line"
        case .system: "By System"
        case .monochrome: "Monochrome"
        }
    }
}

/// "Live", "Timetable", "Needs key", "Off".
struct FeedBadge: View {
    let status: FeedStatus?

    var body: some View {
        let (text, color): (String, Color) = switch status?.mode {
        case .live: ("Live", .green)
        case .off: ("Off", .secondary)
        default: status?.needsKey == true ? ("Timetable · needs key", .orange) : ("Timetable", .orange)
        }
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Live data

struct LiveDataSettings: View {
    @Bindable var model: AppModel
    @State private var wmata = ""
    @State private var swiftly = ""

    var body: some View {
        SettingsGroup(title: "Feeds", footer: feedsFooter) {
            ForEach(model.region.systems, id: \.self) { system in
                let status = model.feeds[system]
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(system.name)
                        Text(detail(status)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    FeedBadge(status: status)
                }
            }
        }

        if model.region == .dcBaltimore { dcKeys }
    }

    private var feedsFooter: String {
        switch model.region.id {
        case "nyc": "MTA’s subway, LIRR and Metro-North feeds need no key; subway trains are placed from arrival predictions, since the feeds give no positions underground. NJ TRANSIT and PATH run on the timetable: NJ TRANSIT’s feed needs a developer account, and PATH publishes only station arrival times."
        case "phl": "SEPTA’s feeds need no key. PATCO and NJ TRANSIT run on the timetable: PATCO publishes nothing live, and NJ TRANSIT’s feed needs a developer account."
        case "bos": "MBTA’s feeds need no key."
        default: "Amtrak, MARC and VRE need no key. Without a key, Metrorail, Light RailLink and Metro SubwayLink run on the timetable."
        }
    }

    @ViewBuilder private var dcKeys: some View {
        SettingsGroup(title: "Metrorail",
                      footer: "A free key from WMATA’s developer site (Products › Default Tier). Stored in your keychain.") {
            KeyField(title: "WMATA API key", text: $wmata) { model.setAPIKey(wmata, for: .wmata) }
            Link("Get a key at developer.wmata.com", destination: URL(string: "https://developer.wmata.com/")!)
                .font(.callout)
        }

        SettingsGroup(title: "Light RailLink and Metro SubwayLink",
                      footer: "MDOT MTA publishes these through Swiftly. Request a free key from MTA’s developer page. Stored in your keychain.") {
            KeyField(title: "Swiftly API key", text: $swiftly) { model.setAPIKey(swiftly, for: .swiftly) }
            Link("MTA developer resources", destination: URL(string: "https://www.mta.maryland.gov/developer-resources")!)
                .font(.callout)
        }
        .onAppear {
            wmata = model.apiKeys[.wmata] ?? ""
            swiftly = model.apiKeys[.swiftly] ?? ""
        }
    }

    private func detail(_ s: FeedStatus?) -> String {
        guard let s else { return "—" }
        var parts: [String] = []
        if let name = s.sourceName { parts.append(name) } else if s.needsKey { parts.append("No key") }
        if s.mode != .off { parts.append(s.trainCount == 1 ? "1 train" : "\(s.trainCount) trains") }
        if let e = s.error { parts.append(e) } else if let last = s.lastSuccess, s.mode == .live {
            parts.append("updated \(last.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }
}

struct KeyField: View {
    let title: String
    @Binding var text: String
    let commit: () -> Void

    var body: some View {
        HStack {
            SecureField(title, text: $text, prompt: Text("Paste key"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Button("Save", action: commit)
        }
    }
}

// MARK: - Info corner

struct InfoSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsGroup {
            Toggle("Show the info corner", isOn: $model.settings.infoEnabled)
        }
        if model.settings.infoEnabled {
            SettingsGroup(title: "Position") {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        cornerButton(.topLeft, "arrow.up.left")
                        cornerButton(.topRight, "arrow.up.right")
                    }
                    GridRow {
                        cornerButton(.bottomLeft, "arrow.down.left")
                        cornerButton(.bottomRight, "arrow.down.right")
                    }
                }
            }
            SettingsGroup(title: "Show") {
                Toggle("Coordinates", isOn: $model.settings.infoShowCoordinates)
                Toggle("Clock", isOn: $model.settings.infoShowClock)
                Toggle("Train count", isOn: $model.settings.infoShowCount)
                Toggle("Nearest train", isOn: $model.settings.infoShowNearest)
                Toggle("Line key", isOn: $model.settings.infoShowLegend)
                    .disabled(model.settings.colorMode == .monochrome)
            }
        }
    }

    private func cornerButton(_ corner: Corner, _ symbol: String) -> some View {
        let selected = model.settings.infoCorner == corner
        return Button {
            model.settings.infoCorner = corner
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 120, height: 44)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(corner.rawValue)
    }
}

// MARK: - Desktop & power

struct DesktopSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsGroup(title: "Desktop",
                      footer: "macOS tints the menu bar, Mission Control and Show Desktop from the system wallpaper. Matching it to the map keeps those see-through. Your own wallpaper comes back when Trainspace quits or this is turned off.") {
            Toggle("Match the menu bar and system wallpaper", isOn: $model.settings.syncSystemWallpaper)
            SettingsRow(title: "Displays") {
                Picker("Displays", selection: $model.settings.displays) {
                    Text("All displays").tag(DisplayTarget.all)
                    Text("Main display only").tag(DisplayTarget.mainOnly)
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
        }

        SettingsGroup(title: "Updates",
                      footer: "Each feed is read no faster than it updates: VRE once a minute, Amtrak every two minutes.") {
            SettingsRow(title: "Refresh every") {
                Picker("Refresh every", selection: $model.settings.pollInterval) {
                    ForEach(WallpaperSettings.pollChoices, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
            }
            SettingsRow(title: "Frame rate") {
                Picker("Frame rate", selection: $model.settings.fpsCap) {
                    Text("15 fps").tag(15.0)
                    Text("20 fps").tag(20.0)
                    Text("30 fps").tag(30.0)
                    Text("60 fps").tag(60.0)
                }
            }
            Toggle("Battery saver: slower updates on battery", isOn: $model.settings.batterySaver)
        }

        SettingsGroup(title: "Data",
                      footer: "Live positions: WMATA, MDOT MTA (MARC; Light RailLink and Metro SubwayLink via Swiftly), VRE, and Amtrak’s Track-a-Train map. Track, stations and timetables: each agency’s GTFS. Base map: Natural Earth (public domain).") {
            SettingsRow(title: "Last update") {
                Text(model.lastSuccess.map { $0.formatted(date: .omitted, time: .standard) } ?? "—").foregroundStyle(.secondary)
            }
        }
    }
}
