import TrainspaceCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var wallpaper: WallpaperController?
    private var power: PowerMonitor?
    private var systemWallpaper: SystemWallpaperSync?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.systemIsDark = NSApp.effectiveAppearance.isDark
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            MainActor.assumeIsolated { self?.model.systemIsDark = app.effectiveAppearance.isDark }
        }
        power = PowerMonitor(model: model)
        wallpaper = WallpaperController(model: model)
        wallpaper?.show()
        systemWallpaper = SystemWallpaperSync(model: model)
        if !model.settings.hasCompletedOnboarding {
            WindowRouter.shared.open(.welcome)
        }
    }
}

extension AppDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        systemWallpaper?.restoreOriginals()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Opens SwiftUI windows from anywhere (the menu panel, the app delegate).
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    enum Target: String { case settings, welcome }
    var openWindow: ((Target) -> Void)?
    private var pending: Target?

    func open(_ target: Target) {
        NSApp.activate(ignoringOtherApps: true)
        if let openWindow { openWindow(target) } else { pending = target }
    }

    func register(_ open: @escaping (Target) -> Void) {
        openWindow = open
        if let p = pending { pending = nil; open(p) }
    }
}

struct TrainspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Trainspace Settings", id: WindowRouter.Target.settings.rawValue) {
            SettingsView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Welcome to Trainspace", id: WindowRouter.Target.welcome.rawValue) {
            WelcomeView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.paused ? "tram.circle" : "tram.circle.fill")
            .onAppear {
                WindowRouter.shared.register { target in openWindow(id: target.rawValue) }
            }
    }
}
