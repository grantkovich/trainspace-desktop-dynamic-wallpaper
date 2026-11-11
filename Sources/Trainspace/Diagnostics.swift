import Foundation
import os
import TrainspaceCore

/// Cheap counters logged every 30 s:
/// `log stream --level info --predicate 'subsystem == "com.trainspace.wallpaper"'`
@MainActor
enum Diagnostics {
    static let log = Logger(subsystem: "com.trainspace.wallpaper", category: "render")
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
}
