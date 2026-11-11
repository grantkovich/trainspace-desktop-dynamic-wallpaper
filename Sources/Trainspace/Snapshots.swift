import AppKit
import MapKit
import SwiftUI
import TrainspaceCore

/// `Trainspace --snapshots <dir> [--time 2026-11-10T08:30] [--benchmark]`
/// Renders each map style × appearance into PNGs, for reviewing the look without installing the
/// wallpaper. Uses the keyless live feeds (Amtrak, MARC, VRE) plus the timetable for the rest;
/// with `--time`, everything comes from the timetable at that moment (Eastern time).
@MainActor
enum Snapshots {
    static func run(outputDirectory: String, arguments: [String]) {
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        renderGlyphSpecimen(dir: dir)
        let regions = value(after: "--region", in: arguments).map { [Region.with(id: $0)] } ?? Region.all
        for region in regions { run(region: region, dir: dir, arguments: arguments) }
    }

    static func load(_ region: Region) -> (GeoData?, RailNetwork?) {
        (AppModel.resourceURL(region.geoFile).flatMap { try? GeoData.load(from: $0) },
         AppModel.resourceURL(region.railFile).flatMap { try? RailNetwork.load(from: $0) })
    }

    static func run(region: Region, dir: URL, arguments: [String]) {
        let size = CGSize(width: 1512, height: 982)
        let (geo, rail) = load(region)
        let time = value(after: "--time", in: arguments).flatMap(parseEastern)
        let date = time ?? Date()
        let (live, departureData) = time == nil ? fetchKeylessLive(rail: rail) : ([], LiveDepartureData())
        print("\(region.name): geodata \(geo != nil ? "loaded" : "missing"), rail \(rail != nil ? "loaded" : "missing"), live trains: \(live.count)")

        let p = region.presets
        let variants: [(String, PlacePreset, (inout WallpaperSettings) -> Void)]
        if region == .dcBaltimore {
            let presets = Dictionary(uniqueKeysWithValues: p.map { ($0.name, $0) })
            let dc = presets["Washington"]!, baltimore = presets["Baltimore"]!, wide = presets["DC–Baltimore"]!, network = presets["Whole Network"]!
            variants = [
                ("dc-night", dc, { $0.appearance = .dark }),
                ("dc-night-lights", dc, { $0.appearance = .dark; $0.glyph = .stationLights }),
                ("dc-aluminum-lights", dc, { $0.appearance = .light; $0.glyph = .stationLights }),
                ("baltimore-night-lights", baltimore, { $0.appearance = .dark; $0.glyph = .stationLights }),
                ("dc-aluminum", dc, { $0.appearance = .light }),
                ("dc-night-zoom2", dc, { $0.appearance = .dark; $0.zoomMiles = 2.5 }),
                ("baltimore-night", baltimore, { $0.appearance = .dark }),
                ("baltimore-aluminum-system", baltimore, { $0.appearance = .light; $0.colorMode = .system; $0.infoCorner = .topRight }),
                ("region-night", wide, { $0.appearance = .dark }),
                ("network-night", network, { $0.appearance = .dark; $0.labelMode = .off }),
                ("dc-night-dots-mono", dc, { $0.appearance = .dark; $0.glyph = .light; $0.colorMode = .monochrome }),
                ("dc-field-night", dc, { $0.appearance = .dark; $0.mapStyle = .pureField }),
                ("region-field-aluminum-arrows", wide, { $0.appearance = .light; $0.mapStyle = .pureField; $0.glyph = .arrow }),
            ]
        } else {
            let id = region.id
            variants = [
                ("\(id)-night", p[0], { $0.appearance = .dark }),
                ("\(id)-aluminum", p[0], { $0.appearance = .light }),
                ("\(id)-close-night", p[1], { $0.appearance = .dark }),
                ("\(id)-close-aluminum-lights", p[1], { $0.appearance = .light; $0.glyph = .stationLights }),
                ("\(id)-night-lights", p[0], { $0.appearance = .dark; $0.glyph = .stationLights }),
                ("\(id)-aluminum-system", p[0], { $0.appearance = .light; $0.colorMode = .system }),
                ("\(id)-network-night", p[p.count - 1], { $0.appearance = .dark; $0.labelMode = .off }),
            ]
        }
        if let rail { renderSignSpecimen(region: region, rail: rail, dir: dir) }
        renderStations(region: region, rail: rail, geo: geo, live: live, departureData: departureData, date: date, size: size, dir: dir)
        if arguments.contains("--stations-only") { return }
        if arguments.contains("--benchmark") {
            benchmark(region: region, preset: p[0], rail: rail, geo: geo, live: live, date: date, size: size)
            return
        }
        if region == .dcBaltimore { renderAppleMap(preset: p[0], rail: rail, geo: geo, live: live, date: date, size: size, dir: dir) }
        for (file, preset, configure) in variants {
            var s = WallpaperSettings()
            s.region = region.id
            s.hasCompletedOnboarding = true
            s.zoomMiles = preset.zoomMiles
            configure(&s)
            let model = staged(s, preset: preset, rail: rail, geo: geo, live: live, date: date, size: size)
            let view = TrainspaceView(model: model, size: size, insets: EdgeInsets(top: 33, leading: 0, bottom: 70, trailing: 0))
                .environment(\.renderSynchronously, true)
            write(view, to: dir.appendingPathComponent(file + ".png"))
        }
    }

    /// Stations to render in station view, per region: hubs, and each kind of platform sign.
    static func stationPicks(_ region: Region) -> [(String, String, (inout WallpaperSettings) -> Void)] {
        switch region.id {
        case "nyc": [
            ("station-nyc-grand-central-night", "Grand Central-42 St", { $0.appearance = .dark }),
            ("station-nyc-penn-aluminum", "Penn Station", { $0.appearance = .light; $0.infoCorner = .topRight }),
            ("station-nyc-times-sq-night", "Times Sq-42 St", { $0.appearance = .dark; $0.stationZoomMiles = 0.8 }),
            ("station-nyc-hoboken-night", "Hoboken", { $0.appearance = .dark }),
            ("station-nyc-stamford-aluminum", "Stamford", { $0.appearance = .light }),
            ("station-nyc-st-george-night", "St George", { $0.appearance = .dark; $0.stationZoomMiles = 2 }),
        ]
        case "phl": [
            ("station-phl-30th-night", "30th Street Station", { $0.appearance = .dark }),
            ("station-phl-city-hall-aluminum", "15th St/City Hall", { $0.appearance = .light }),
            ("station-phl-lindenwold-night", "Lindenwold", { $0.appearance = .dark; $0.stationZoomMiles = 2 }),
            ("station-phl-69th-night", "69th Street", { $0.appearance = .dark }),
        ]
        case "bos": [
            ("station-bos-south-night", "South Station", { $0.appearance = .dark }),
            ("station-bos-park-aluminum", "Park Street", { $0.appearance = .light }),
            ("station-bos-kenmore-night", "Kenmore", { $0.appearance = .dark }),
            ("station-bos-back-bay-night", "Back Bay", { $0.appearance = .dark }),
        ]
        default: [
            ("station-union-night", "Union Station", { $0.appearance = .dark }),
            ("station-penn-aluminum", "Penn Station", { $0.appearance = .light; $0.infoCorner = .topRight }),
            ("station-metro-center-night", "Metro Center", { $0.appearance = .dark }),
            ("station-north-avenue-night", "North Avenue", { $0.appearance = .dark }),
            ("station-charles-center-aluminum", "Charles Center", { $0.appearance = .light }),
            ("station-odenton-night", "Odenton", { $0.appearance = .dark; $0.stationZoomMiles = 2 }),
            ("station-alexandria-apple", "King St-Old Town", { $0.appearance = .dark; $0.mapStyle = .pureField }),
        ]
        }
    }

    /// Station view: the hubs' split-flap boards and each kind of platform sign.
    static func renderStations(region: Region, rail: RailNetwork?, geo: GeoData?, live: [TrainReport],
                               departureData: LiveDepartureData, date: Date, size: CGSize, dir: URL) {
        guard let rail else { return }
        for (file, name, configure) in stationPicks(region) {
            guard let station = rail.stations.first(where: { $0.name == name }) else { print("no station \(name)"); continue }
            var s = WallpaperSettings()
            s.region = region.id
            s.hasCompletedOnboarding = true
            s.viewMode = .station
            s.stationKey = station.key
            configure(&s)
            let model = staged(s, preset: PlacePreset(name: name, center: station.position, zoomMiles: 2), rail: rail, geo: geo,
                               live: live, date: date, size: size)
            model.stageDepartureData(departureData)
            if ProcessInfo.processInfo.environment["TRAINSPACE_DEBUG_BOARDS"] != nil {
                for b in model.stationBoards {
                    for d in b.departures.prefix(5) {
                        print("  \(b.spec.caption) \(d.destination) sched \(d.scheduled) exp \(d.expected) \(d.status)")
                    }
                }
            }
            let view = TrainspaceView(model: model, size: size, insets: EdgeInsets(top: 33, leading: 0, bottom: 70, trailing: 0))
                .environment(\.renderSynchronously, true)
            write(view, to: dir.appendingPathComponent(file + ".png"))
        }
    }

    static func staged(_ s: WallpaperSettings, preset: PlacePreset, rail: RailNetwork?, geo: GeoData?, live: [TrainReport],
                       date: Date, size: CGSize) -> AppModel {
        let model = AppModel(settings: s, startServices: false)
        model.primaryScreenSize = size
        model.stage(center: preset.center, name: preset.name, rail: rail, geo: geo, live: live, at: date)
        return model
    }

    static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("failed: \(url.lastPathComponent)"); return
        }
        try? png.write(to: url)
        print("wrote \(url.path)")
    }

    /// One station sign per railway, large and at map size.
    static func renderSignSpecimen(region: Region, rail: RailNetwork, dir: URL) {
        let names = switch region.id {
        case "nyc": ["Times Sq-42 St", "Penn Station", "Grand Central-42 St", "Christopher Street", "Stamford",
                     "Hicksville", "Secaucus Junction", "Exchange Place", "St George", "New London"]
        case "phl": ["30th Street Station", "15th St/City Hall", "Jefferson Station", "69th Street", "Lindenwold",
                     "Cooper Street/Rutgers", "Norristown", "Coatesville"]
        case "bos": ["South Station", "Park Street", "Kenmore", "Back Bay", "North Station", "Mattapan", "Worcester"]
        default: ["Metro Center", "Union Station", "Wilmington", "Penn Station", "Riverdale", "North Avenue",
                  "Johns Hopkins", "Burke Centre"]
        }
        let stations = names.compactMap { n in rail.stations.firstIndex { $0.name == n } }
        let view = HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(stations, id: \.self) { StationSign(station: $0, rail: rail, fontSize: 26) }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(stations, id: \.self) { StationSign(station: $0, rail: rail, fontSize: 10) }
            }
        }
        .padding(30)
        .background(Palette.aluminum.land.color)
        write(view, to: dir.appendingPathComponent(region == .dcBaltimore ? "signs.png" : "signs-\(region.id).png"))
    }

    /// Every system's car, large and at actual size, live and hollow, on both palettes.
    static func renderGlyphSpecimen(dir: URL) {
        let systems = TransitSystem.allCases
        let view = VStack(spacing: 0) {
            ForEach([Palette.night, Palette.aluminum], id: \.isDark) { palette in
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.land.color))
                    for (i, system) in systems.enumerated() {
                        let color = palette.lineColor(system.info.color)
                        for (scale, y, hollow) in [(4.0, 80.0, false), (1.0, 165.0, false), (1.0, 200.0, true)] {
                            var t = CGAffineTransform(scaleX: scale, y: scale)
                                .concatenating(CGAffineTransform(rotationAngle: scale == 1 ? .pi / 4 : 0))
                                .concatenating(CGAffineTransform(translationX: 70 + Double(i) * 130, y: y))
                            let shape = Path(Glyphs.body(for: system).copy(using: &t)!)
                            ctx.stroke(shape, with: .color(palette.land.color), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
                            if hollow {
                                ctx.fill(shape, with: .color(palette.land.color))
                                ctx.stroke(shape, with: .color(color.color), lineWidth: 1.4)
                            } else {
                                ctx.fill(shape, with: .color(color.color))
                            }
                        }
                    }
                }
                .frame(width: 820, height: 230)
            }
        }
        write(view, to: dir.appendingPathComponent("glyphs.png"))
    }

    /// Apple Map can't go through ImageRenderer, so snapshot the same MKMapRect with
    /// MKMapSnapshotter and composite our layers over it.
    static func renderAppleMap(preset: PlacePreset, rail: RailNetwork?, geo: GeoData?, live: [TrainReport], date: Date,
                               size: CGSize, dir: URL) {
        for dark in [true, false] {
            var s = WallpaperSettings()
            s.mapStyle = .appleMap
            s.appearance = dark ? .dark : .light
            s.zoomMiles = 3
            let model = staged(s, preset: preset, rail: rail, geo: geo, live: live, date: date, size: size)
            let projection = Projection(center: preset.center, size: size, radiusNM: s.radiusNM)
            let options = MKMapSnapshotter.Options()
            options.mapRect = projection.mapRect
            options.size = size
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = config
            options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

            final class Box: @unchecked Sendable { var image: NSImage? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            MKMapSnapshotter(options: options).start(with: .global()) { snap, error in
                box.image = snap?.image
                if let error { print("snapshotter: \(error)") }
                done.signal()
            }
            done.wait()
            guard let base = box.image else { continue }
            let palette = model.palette(at: date)
            let insets = EdgeInsets(top: 33, leading: 0, bottom: 70, trailing: 0)
            let network = NetworkOptions(model: model, palette: palette, size: size, insets: insets)
            let shared = SharedObstacles()
            let view = ZStack(alignment: .topLeading) {
                Image(nsImage: base).resizable().saturation(AppleMapLayer.saturation).frame(width: size.width, height: size.height)
                palette.water.color.opacity(palette.isDark ? 0.42 : 0.32)
                SchematicLayer(geo: nil, rail: rail, projection: projection, palette: palette, options: network.options,
                               drawBaseMap: false, dotGrid: false, trackColor: network.trackColor, shared: shared,
                               rings: RingsLayer(projection: projection, palette: palette, settings: s))
                TrafficStack(model: model, size: size, insets: insets, shared: shared)
                InfoStack(model: model, size: size, insets: insets)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.renderSynchronously, true)
            write(view, to: dir.appendingPathComponent(dark ? "apple-night.png" : "apple-aluminum.png"))
        }
    }

    /// Times one frame of the animated layer (trains, trails, labels) rendered offscreen.
    /// ImageRenderer rasterizes on the CPU, so this is an upper bound on per-frame cost.
    static func benchmark(region: Region, preset: PlacePreset, rail: RailNetwork?, geo: GeoData?, live: [TrainReport], date: Date, size: CGSize) {
        for (name, labels, trails) in [("full", LabelMode.trainDestination, 1.0), ("no labels", .off, 1), ("no labels/trails", .off, 0)] {
            var s = WallpaperSettings()
            s.region = region.id
            s.labelMode = labels
            s.trailMinutes = trails
            s.zoomMiles = 12
            let model = staged(s, preset: preset, rail: rail, geo: geo, live: live, date: date, size: size)
            let view = TrafficStack(model: model, size: size, insets: EdgeInsets(), shared: SharedObstacles())
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            _ = renderer.cgImage
            let n = 20
            let start = Date()
            for _ in 0..<n {
                renderer.content = TrafficStack(model: model, size: size, insets: EdgeInsets(), shared: SharedObstacles())
                _ = renderer.cgImage
            }
            let ms = Date().timeIntervalSince(start) / Double(n) * 1000
            print(String(format: "%@: %.1f ms/frame (%d trains drawn)", name, ms, Diagnostics.trainsDrawn))
        }
        // Tracker cost: one snapshot of every train, with track following.
        var base = WallpaperSettings()
        base.region = region.id
        let model = staged(base, preset: preset, rail: rail, geo: geo, live: live, date: date, size: size)
        let start = Date()
        for _ in 0..<100 { _ = model.tracker.snapshot(at: Date().timeIntervalSince1970) }
        print(String(format: "tracker snapshot: %.2f ms (%d trains)", Date().timeIntervalSince(start) * 10, model.tracker.trains.count))
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// "2026-11-10T08:30" in Eastern time.
    private static func parseEastern(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Every feed that needs no key: positions, plus delays for the departure boards.
    private static func fetchKeylessLive(rail: RailNetwork?) -> ([TrainReport], LiveDepartureData) {
        final class Box: @unchecked Sendable { var value: [TrainReport] = []; var data = LiveDepartureData() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        guard let rail else { return ([], LiveDepartureData()) }
        let estimator = ScheduleEstimator(network: rail)
        let sources = rail.systems.compactMap {
            LiveFeeds.source(for: $0, keys: [:], network: rail, estimator: estimator, region: rail.coverage)
        }
        let systems = rail.systems
        Task.detached {
            for source in sources {
                do {
                    let trains = try await source.trains()
                    print("\(source.system.name) (\(source.name)): \(trains.count) trains")
                    box.value += trains
                    if let amtrak = source as? AmtrakSource { box.data.amtrak = await amtrak.stationTimes }
                    if let p = source as? any TripUpdateProviding { box.data.tripUpdates[source.system] = await p.latestTripUpdates }
                } catch {
                    print("\(source.system.name) (\(source.name)): \(error)")
                }
            }
            for system in systems {
                guard let tu = LiveFeeds.tripUpdates(for: system, keys: [:]) else { continue }
                box.data.tripUpdates[system] = (try? await tu.updates()) ?? []
                print("\(system.name) trip updates: \(box.data.tripUpdates[system]?.count ?? 0)")
            }
            done.signal()
        }
        done.wait()
        print("amtrak station times: \(box.data.amtrak.count)")
        return (box.value, box.data)
    }
}

/// `Trainspace --icon <dir.iconset>`: renders the app icon at every size `iconutil` wants.
@MainActor
enum IconRenderer {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let renderer = ImageRenderer(content: AppIcon().frame(width: 1024, height: 1024))
            renderer.scale = CGFloat(points * scale) / 1024
            guard let tiff = renderer.nsImage?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try? png.write(to: dir.appendingPathComponent(name))
        }
        print("wrote \(dir.path)")
    }
}

/// Night field, dot grid, three lines crossing at a station, and three lit trains.
struct AppIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let p = Palette.night
            let inset: CGFloat = 100
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let shape = Path(roundedRect: rect, cornerRadius: 185, style: .continuous)
            ctx.fill(shape, with: .linearGradient(Gradient(colors: [RGBA(hex: 0x17191C).color, RGBA(hex: 0x0A0B0D).color]),
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            ctx.clip(to: shape)
            var dots = Path()
            for x in stride(from: rect.minX + 30, to: rect.maxX, by: 52) {
                for y in stride(from: rect.minY + 30, to: rect.maxY, by: 52) {
                    dots.addEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                }
            }
            ctx.fill(dots, with: .color(p.dotGrid.with(alpha: 0.8).color))
            let hub = CGPoint(x: rect.midX + 10, y: rect.midY + 20)
            // (start, end, colour, train position 0…1)
            let lines: [(CGPoint, CGPoint, RGBA, Double)] = [
                (CGPoint(x: rect.minX, y: rect.minY + 250), CGPoint(x: rect.maxX, y: rect.maxY - 170), p.lineColor(0xC80F2D), 0.25),
                (CGPoint(x: rect.minX + 230, y: rect.maxY), CGPoint(x: rect.maxX - 120, y: rect.minY), p.lineColor(0x009CDE), 0.72),
                (CGPoint(x: rect.minX, y: rect.maxY - 260), CGPoint(x: rect.maxX, y: rect.minY + 330), p.lineColor(0x8A3FC4), 0.82),
            ]
            for (a, b, color, _) in lines {
                var track = Path()
                track.move(to: a)
                track.addLine(to: b)
                ctx.stroke(track, with: .color(color.with(alpha: 0.38).color), style: StrokeStyle(lineWidth: 22, lineCap: .round))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: hub.x - 34, y: hub.y - 34, width: 68, height: 68)), with: .color(p.land.color))
            ctx.stroke(Path(ellipseIn: CGRect(x: hub.x - 34, y: hub.y - 34, width: 68, height: 68)), with: .color(p.station.color), lineWidth: 12)
            for (a, b, color, f) in lines {
                let at = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                let angle = atan2(b.x - a.x, a.y - b.y)
                ctx.fill(Path(ellipseIn: CGRect(x: at.x - 110, y: at.y - 110, width: 220, height: 220)),
                         with: .radialGradient(Gradient(colors: [color.with(alpha: 0.5).color, color.with(alpha: 0).color]),
                                               center: at, startRadius: 0, endRadius: 110))
                let t = CGAffineTransform(scaleX: 11, y: 11).concatenating(CGAffineTransform(rotationAngle: angle))
                    .concatenating(CGAffineTransform(translationX: at.x, y: at.y))
                let car = Path(Glyphs.metro).applying(t)
                ctx.stroke(car, with: .color(p.land.color), lineWidth: 18)
                ctx.fill(car, with: .color(color.color))
                let nose = CGPoint(x: 0, y: Glyphs.noseOffset(for: .metrorail)).applying(t)
                ctx.fill(Path(ellipseIn: CGRect(x: nose.x - 13, y: nose.y - 13, width: 26, height: 26)), with: .color(.white.opacity(0.9)))
            }
        }
    }
}

/// `Trainspace --render-settings <dir>`: draws the real Settings window (AppKit controls and all)
/// offscreen for every section, for reviewing the UI without screen-recording access.
@MainActor
enum SettingsRender {
    static func run(outputDirectory: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WallpaperSettings()
        s.hasCompletedOnboarding = true
        s.zoomMiles = 6
        let (geo, rail) = Snapshots.load(.dcBaltimore)
        let model = AppModel(settings: s, startServices: false)
        model.primaryScreenSize = CGSize(width: 1512, height: 982)
        model.stage(center: PlacePreset.all[0].center, name: "Washington", rail: rail, geo: geo, live: [], at: Date())

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for section in SettingsSection.allCases {
                let host = NSHostingView(rootView: SettingsView(model: model, initialSection: section)
                    .environment(\.renderSynchronously, true))
                let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 820, height: 720),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // let SwiftUI settle
                let view = window.contentView!.superview ?? host
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "\(section.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                window.close()
            }
            // Both welcome steps, as on first run.
            for step in WelcomeView.Step.allCases {
                let host = NSHostingView(rootView: WelcomeView(model: model, initialStep: step)
                    .environment(\.renderSynchronously, true))
                let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 616, height: 720),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setContentSize(host.fittingSize)
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let view = window.contentView!.superview ?? host
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "welcome-\(step.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                window.close()
            }
        }
        print("wrote \(dir.path)")
    }
}
