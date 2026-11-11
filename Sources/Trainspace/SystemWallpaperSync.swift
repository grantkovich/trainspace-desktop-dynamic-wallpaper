import AppKit
import UniformTypeIdentifiers
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
    private var spaceObserver: NSObjectProtocol?
    /// Display UUID → cache key of the still now showing, and the still's file.
    private var renderedKey: [String: String] = [:]
    private var stills: [String: URL] = [:]
    private var rendering = false
    private static let appName = "Trainspace"
    private static let ledgerKey = "trainspace.wallpaperLedger.v2"

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Trainspace/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var ledger: WallpaperLedger {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
                  let ledger = try? JSONDecoder().decode(WallpaperLedger.self, from: data) else { return WallpaperLedger() }
            return ledger
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.ledgerKey) }
            model.wallpaperNeedsManualRestore = newValue.needsManualRestore
        }
    }

    init(model: AppModel) {
        self.model = model
        model.wallpaperNeedsManualRestore = ledger.needsManualRestore
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 2
        // macOS keeps a desktop picture per Space; NSWorkspace only sees the current one.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
        tick()
    }

    func tick() {
        guard model.settings.syncSystemWallpaper else {
            restoreOriginals(retryStuck: false)
            return
        }
        guard !rendering, let center = model.mapCenter, model.rail != nil, model.geo != nil || model.settings.mapStyle != .schematic else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let display = screen.displayUUID ?? String(id)
            let key = cacheKey(center: center, screen: screen)
            if renderedKey[display] == key { continue }
            rendering = true
            Task {
                defer { self.rendering = false }
                guard let url = await self.render(screen: screen, id: id, center: center) else { return }
                self.apply(url, to: screen, display: display)
                self.renderedKey[display] = key
            }
            return   // one screen per tick keeps the main thread responsive
        }
    }

    /// A different Space is on screen: give it the current still too (so its menu bar
    /// matches), or, with the option off, put back its own picture if it still shows a map.
    private func spaceChanged() {
        guard model.settings.syncSystemWallpaper else {
            restoreOriginals()
            return
        }
        for screen in NSScreen.screens {
            guard let display = screen.displayUUID ?? screen.displayID.map({ String($0) }),
                  let still = stills[display],
                  NSWorkspace.shared.desktopImageURL(for: screen) != still else { continue }
            apply(still, to: screen, display: display)
        }
    }

    /// Puts back each display's own picture wherever it shows one of our stills. Called on
    /// quit, on Space changes and while the option is off. Cheap when there's nothing to do.
    /// The 5-second timer passes `retryStuck: false` so a failed restore isn't retried (and
    /// logged) every tick; quitting and Space changes try again.
    func restoreOriginals(retryStuck: Bool = true) {
        var ledger = self.ledger
        let before = ledger
        for screen in NSScreen.screens {
            guard let display = screen.displayUUID ?? screen.displayID.map({ String($0) }) else { continue }
            if !retryStuck && ledger.stuck.contains(display) { continue }
            let current = NSWorkspace.shared.desktopImageURL(for: screen)?.path
            switch ledger.restoreAction(display: display, current: current, appName: Self.appName) {
            case .nothingToDo:
                continue
            case .restore(let path):
                do {
                    try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
                    ledger.restored(display: display)
                } catch {
                    // Usually the sandbox: the picture is somewhere Trainspace can't read.
                    Diagnostics.log.error("Restoring the desktop picture failed: \(error.localizedDescription, privacy: .public)")
                    ledger.failed(display: display)
                }
            case .unknown:
                ledger.failed(display: display)
            }
        }
        if ledger != before { self.ledger = ledger }
        renderedKey.removeAll()
        stills.removeAll()
    }

    /// Asks the user to pick their picture, for displays where it couldn't be put back on its
    /// own. Picking it in an open panel also gives the sandbox permission to use the file.
    func restoreManually() {
        let panel = NSOpenPanel()
        panel.title = "Choose your desktop picture"
        panel.message = "Trainspace couldn't put your own wallpaper back by itself. Pick it here."
        panel.prompt = "Use as Wallpaper"
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var ledger = self.ledger
        var displays: [String] = []
        for screen in NSScreen.screens {
            guard let display = screen.displayUUID ?? screen.displayID.map({ String($0) }) else { continue }
            let current = NSWorkspace.shared.desktopImageURL(for: screen)?.path
            let showsOurs = current.map { WallpaperLedger.isOurs($0, appName: Self.appName) } ?? false
            guard showsOurs || ledger.stuck.contains(display) else { continue }
            if !model.settings.syncSystemWallpaper {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
            displays.append(display)
        }
        ledger.chose(url.path, for: displays)
        self.ledger = ledger
    }

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

    private func apply(_ url: URL, to screen: NSScreen, display: String) {
        var ledger = self.ledger
        ledger.observe(display: display, current: NSWorkspace.shared.desktopImageURL(for: screen)?.path, appName: Self.appName)
        self.ledger = ledger
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            stills[display] = url
        } catch {
            Diagnostics.log.error("setDesktopImageURL failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension NSScreen {
    /// Stable across reboots and reconnects, unlike the CGDirectDisplayID.
    var displayUUID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
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
