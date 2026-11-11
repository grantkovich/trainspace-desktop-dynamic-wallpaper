import AppKit
import MapKit
import SwiftUI
import TrainspaceCore

/// Keeps the *system* wallpaper in step with the map.
///
/// The menu bar, Mission Control and Show Desktop are tinted from the system wallpaper, not
/// from the windows behind them, so without this the menu bar shows the old picture above the
/// live map. We render the static base map (no trains or text) for each display and set it
/// as that display's desktop picture, remembering the user's own picture so it can be put back.
@MainActor
final class SystemWallpaperSync {
    private let model: AppModel
    private var timer: Timer?
    private var renderedKey: [CGDirectDisplayID: String] = [:]
    private var rendering = false
    private let originalsKey = "trainspace.originalWallpapers"

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Trainspace/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 2
        tick()
    }

    func tick() {
        guard model.settings.syncSystemWallpaper else {
            if !renderedKey.isEmpty || hasSavedOriginals { restoreOriginals() }
            return
        }
        guard !rendering, let center = model.mapCenter, model.rail != nil, model.geo != nil || model.settings.mapStyle != .schematic else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let key = cacheKey(center: center, screen: screen)
            if renderedKey[id] == key { continue }
            rendering = true
            Task {
                defer { self.rendering = false }
                guard let url = await self.render(screen: screen, id: id, center: center) else { return }
                self.apply(url, to: screen, id: id)
                self.renderedKey[id] = key
            }
            return   // one screen per tick keeps the main thread responsive
        }
    }

    /// Puts back each display's own picture. Called on quit and when the option is turned off.
    func restoreOriginals() {
        let originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let path = originals[String(id)] else { continue }
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        }
        UserDefaults.standard.removeObject(forKey: originalsKey)
        renderedKey.removeAll()
    }

    private var hasSavedOriginals: Bool { UserDefaults.standard.dictionary(forKey: originalsKey) != nil }

    // MARK: Rendering

    private func cacheKey(center: Coordinate, screen: NSScreen) -> String {
        let s = model.settings
        let p = model.palette()
        // Quantise the palette so a sun-driven fade re-renders a handful of times, not every minute.
        let tone = Int((p.land.r * 20).rounded())
        return [String(format: "%.3f,%.3f", center.latitude, center.longitude), "\(model.mapRadiusNM)", s.mapStyle.rawValue,
                s.viewMode.rawValue, s.infoCorner.rawValue, "\(model.stationBoards.count)",
                "\(s.showRangeRings)\(s.showDotGrid)\(s.showRoads)\(s.showTrack)\(s.showStations)\(s.showStationNames)\(s.tintAppleMap)",
                s.systems.map(\.rawValue).sorted().description, s.colorMode.rawValue, "\(tone)",
                "\(screen.frame.size)", "\(screen.backingScaleFactor)"].joined(separator: "|")
    }

    private func render(screen: NSScreen, id: CGDirectDisplayID, center: Coordinate) async -> URL? {
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let palette = model.palette()
        guard let projection = model.projection(size: size, insets: screen.wallpaperInsets) else { return nil }

        var mapImage: NSImage?
        if model.settings.mapStyle == .appleMap {
            mapImage = await MapSnapshot.image(projection: projection, dark: palette.isDark)
            if mapImage == nil { return nil }
        }
        let content = WallpaperStill(model: model, size: size, insets: screen.wallpaperInsets, palette: palette,
                                     projection: projection, appleMap: mapImage)
            .environment(\.renderSynchronously, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.93]) else { return nil }

        // Alternate file names: macOS caches desktop pictures by URL.
        let previous = NSWorkspace.shared.desktopImageURL(for: screen)
        var url = directory.appendingPathComponent("display-\(id)-a.jpg")
        if previous == url { url = directory.appendingPathComponent("display-\(id)-b.jpg") }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    private func apply(_ url: URL, to screen: NSScreen, id: CGDirectDisplayID) {
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        if let current = NSWorkspace.shared.desktopImageURL(for: screen),
           !current.path.hasPrefix(directory.path) {
            // The user's own picture (or one they picked since we last set ours): remember it.
            originals[String(id)] = current.path
            UserDefaults.standard.set(originals, forKey: originalsKey)
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        } catch {
            Diagnostics.log.error("setDesktopImageURL failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The static part of the wallpaper as a still image.
private struct WallpaperStill: View {
    let model: AppModel
    let size: CGSize
    let insets: EdgeInsets
    let palette: Palette
    let projection: Projection
    let appleMap: NSImage?

    var body: some View {
        ZStack {
            if let appleMap {
                Image(nsImage: appleMap).resizable().saturation(AppleMapLayer.saturation)
                if model.settings.tintAppleMap { palette.water.color.opacity(palette.isDark ? 0.42 : 0.32) }
                let network = NetworkOptions(model: model, palette: palette, size: size, insets: insets)
                let focus = model.selectedStation.flatMap { model.rail?.stations[safe: $0]?.position }
                SchematicLayer(geo: nil, rail: model.rail, projection: projection, palette: palette, options: network.options,
                               drawBaseMap: false, dotGrid: false, trackColor: network.trackColor,
                               rings: RingsLayer(projection: projection, palette: palette, settings: model.settings, focus: focus))
            } else {
                BaseStack(model: model, size: size, insets: insets, shared: SharedObstacles())
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// MapKit can't be rendered by ImageRenderer; MKMapSnapshotter renders the same map rect.
enum MapSnapshot {
    static func image(projection: Projection, dark: Bool) async -> NSImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = projection.mapRect
        options.size = projection.size
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return try? await MKMapSnapshotter(options: options).start().image
    }
}
