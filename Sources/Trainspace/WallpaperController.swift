import TrainspaceCore
import AppKit
import SwiftUI

/// Borderless, click-through windows pinned to the desktop layer on every Space.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .black
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WallpaperController {
    private let model: AppModel
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var displaysSetting: DisplayTarget
    private var occlusionTimer: Timer?

    init(model: AppModel) {
        self.model = model
        self.displaysSetting = model.settings.displays
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observeSettings()
        occlusionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOcclusion() }
        }
        occlusionTimer?.tolerance = 1
    }

    func show() { rebuild() }

    private func observeSettings() {
        withObservationTracking { _ = model.settings.displays } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.settings.displays != self.displaysSetting {
                    self.displaysSetting = self.model.settings.displays
                    self.rebuild()
                }
                self.observeSettings()
            }
        }
    }

    private func targetScreens() -> [NSScreen] {
        switch model.settings.displays {
        case .all: NSScreen.screens
        case .mainOnly: Array(NSScreen.screens.prefix(1))   // screens[0] holds the menu bar
        }
    }

    func rebuild() {
        let screens = targetScreens()
        let ids = Set(screens.compactMap(\.displayID))
        for (id, window) in windows where !ids.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let window = windows[id] ?? WallpaperWindow(screen: screen)
            window.setFrame(screen.frame, display: true)
            window.contentView = makeContent(size: screen.frame.size, insets: screen.wallpaperInsets)
            window.orderFront(nil)
            windows[id] = window
        }
        model.primaryScreenSize = screens.first?.frame.size ?? model.primaryScreenSize
        updateOcclusion()
    }

    /// Three stacked hosting views, each with its own layer: the animated train layer is
    /// composited over the static map by Core Animation instead of repainting it every frame.
    private func makeContent(size: CGSize, insets: EdgeInsets) -> NSView {
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        let shared = SharedObstacles()
        let layers: [NSView] = [
            NSHostingView(rootView: BaseStack(model: model, size: size, insets: insets, shared: shared)),
            NSHostingView(rootView: TrafficStack(model: model, size: size, insets: insets, shared: shared)),
            NSHostingView(rootView: InfoStack(model: model, size: size, insets: insets)),
        ]
        for view in layers {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            container.addSubview(view)
        }
        return container
    }

    /// `NSWindow.occlusionState` reports desktop-level windows as hidden even when they're
    /// visible (Finder's icon layer sits above them), so instead check whether a normal app
    /// window covers each wallpaper screen. Window bounds don't need screen-recording access.
    private func updateOcclusion() {
        guard !windows.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { model.powerInputs.allOccluded = false; return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let covers: [CGRect] = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.95,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let allCovered = windows.values.allSatisfy { window in
            // Cocoa (bottom-left origin) → Quartz window coordinates (top-left origin).
            let f = window.frame
            let screenRect = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
            // Menu bar and Dock gaps are fine: a window covering 97% of the screen hides the wallpaper.
            return covers.contains { $0.intersection(screenRect).area >= screenRect.area * 0.97 }
        }
        if model.powerInputs.allOccluded != allCovered { model.powerInputs.allOccluded = allCovered }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Space taken by the menu bar and Dock, so overlays avoid them.
    var wallpaperInsets: EdgeInsets {
        EdgeInsets(top: frame.maxY - visibleFrame.maxY, leading: visibleFrame.minX - frame.minX,
                   bottom: visibleFrame.minY - frame.minY, trailing: frame.maxX - visibleFrame.maxX)
    }
}
