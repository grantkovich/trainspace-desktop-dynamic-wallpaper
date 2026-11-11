import AppKit
import IOKit.ps

/// Feeds power-related facts into the model; `PowerPolicy` decides what to do with them.
@MainActor
final class PowerMonitor {
    private weak var model: AppModel?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let nc = NotificationCenter.default

        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (AppModel) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let m = self?.model { body(m) }
                }
            })
        }

        on(ws, NSWorkspace.screensDidSleepNotification) { $0.powerInputs.displaysAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.powerInputs.displaysAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.powerInputs.screenLocked = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.powerInputs.screenLocked = false }
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.powerInputs.screenLocked = true }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.powerInputs.screenLocked = false }
        on(nc, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] _ in self?.sample() }

        sample()
        // Power source changes have no cheap notification without a run-loop source; a slow timer is fine.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func sample() {
        guard let model else { return }
        model.powerInputs.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        model.powerInputs.onBattery = Self.onBattery()
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
