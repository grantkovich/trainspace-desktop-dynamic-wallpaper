import AppKit
import os
import TrainspaceCore

/// Cheap counters logged every 30 s:
/// `log stream --level info --predicate 'subsystem == "com.grantkovich.trainspace"'`
@MainActor
enum Diagnostics {
    static let log = Logger(subsystem: "com.grantkovich.trainspace", category: "render")
    static var framesDrawn = 0
    static var trainsDrawn = 0

    static func report(model: AppModel) {
        let feeds = TransitSystem.allCases.compactMap { s in
            model.feeds[s].map { "\(s.name)=\($0.mode.rawValue):\($0.trainCount)" }
        }.joined(separator: ",")
        log.info("""
            mode=\(model.powerMode.kind.rawValue, privacy: .public) fps=\(model.powerMode.fps) \
            occluded=\(model.powerInputs.allOccluded) frames=\(framesDrawn) lastTrains=\(trainsDrawn) \
            tracked=\(model.tracker.trains.count) feeds=\(feeds, privacy: .public)
            """)
        framesDrawn = 0
    }

    /// Plain text for a bug report: versions, displays and feed state. Never the location or keys.
    static func summary(model: AppModel) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let screens = NSScreen.screens.map { s in
            "\(Int(s.frame.width))×\(Int(s.frame.height))@\(Int(s.backingScaleFactor))x"
        }.joined(separator: ", ")
        var lines = [
            "Trainspace \(version) (\(build)) on macOS \(os), \(machineArchitecture)",
            "Displays: \(screens)",
            "Power: \(model.powerMode.kind.rawValue), \(model.powerMode.fps) fps, desktop covered: \(model.powerInputs.allOccluded)",
            "Region: \(model.settings.region), map: \(model.settings.mapStyle.rawValue), view: \(model.settings.viewMode.rawValue), system wallpaper sync: \(model.settings.syncSystemWallpaper)",
            "Trains tracked: \(model.tracker.trains.count)",
        ]
        for system in TransitSystem.allCases {
            guard let f = model.feeds[system] else { continue }
            var line = "  \(system.name): \(f.mode.rawValue), \(f.trainCount) trains"
            if let name = f.sourceName { line += " from \(name)" }
            if let error = f.error { line += ", error: \(error)" }
            lines.append(line)
        }
        if model.wallpaperNeedsManualRestore { lines.append("Wallpaper: couldn't restore automatically") }
        return lines.joined(separator: "\n")
    }

    static func copySummary(model: AppModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(model: model), forType: .string)
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }
}
