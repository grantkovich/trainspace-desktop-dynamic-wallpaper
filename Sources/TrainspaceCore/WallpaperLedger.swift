import Foundation

/// Remembers each display's own desktop picture while the app shows stills of the map, so it
/// can be put back. Pure bookkeeping: the app makes the NSWorkspace calls.
///
/// Displays are keyed by their UUID, which survives reboots and reconnects (a
/// `CGDirectDisplayID` doesn't). Originals are kept after a restore on purpose: macOS sets a
/// desktop picture per Space, and a Space that still shows a map is only fixed the next time
/// it's on screen.
public struct WallpaperLedger: Codable, Equatable, Sendable {
    /// Display UUID → path of that display's own picture: the last one seen that wasn't ours.
    public private(set) var originals: [String: String] = [:]
    /// Displays showing one of our stills with no original we could put back.
    public private(set) var stuck: Set<String> = []

    public init() {}

    /// Our stills live in `…/<App>/Wallpapers/display-*.jpg`. Matching on the path (not the
    /// container) also catches stills left by a build with an older bundle ID.
    public static func isOurs(_ path: String, appName: String) -> Bool {
        path.contains("/\(appName)/Wallpapers/display-")
    }

    /// Call with what a display shows just before our still goes on. Records it unless it's ours.
    public mutating func observe(display: String, current: String?, appName: String) {
        guard let current, !Self.isOurs(current, appName: appName) else { return }
        originals[display] = current
        stuck.remove(display)
    }

    public enum Restore: Equatable, Sendable {
        /// The display already shows a picture that isn't ours.
        case nothingToDo
        /// Put this picture back.
        case restore(String)
        /// It shows our still and there's no record of the user's own picture.
        case unknown
    }

    public func restoreAction(display: String, current: String?, appName: String) -> Restore {
        guard let current, Self.isOurs(current, appName: appName) else { return .nothingToDo }
        if let original = originals[display] { return .restore(original) }
        return .unknown
    }

    public mutating func restored(display: String) { stuck.remove(display) }
    public mutating func failed(display: String) { stuck.insert(display) }

    /// The user picked a picture by hand for these displays.
    public mutating func chose(_ path: String, for displays: [String]) {
        for d in displays {
            originals[d] = path
            stuck.remove(d)
        }
    }

    public var needsManualRestore: Bool { !stuck.isEmpty }
}
