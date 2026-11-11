import Foundation

public struct PowerInputs: Hashable, Sendable {
    public var onBattery = false
    public var lowPowerMode = false
    /// Every wallpaper window is fully covered by other windows.
    public var allOccluded = false
    public var screenLocked = false
    public var displaysAsleep = false
    public var paused = false

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, allOccluded: Bool = false,
                screenLocked: Bool = false, displaysAsleep: Bool = false, paused: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.allOccluded = allOccluded
        self.screenLocked = screenLocked
        self.displaysAsleep = displaysAsleep
        self.paused = paused
    }
}

public struct PowerSettings: Hashable, Sendable {
    public var pollInterval: TimeInterval
    public var fpsCap: Double
    public var batterySaver: Bool

    public init(pollInterval: TimeInterval, fpsCap: Double, batterySaver: Bool) {
        self.pollInterval = pollInterval
        self.fpsCap = fpsCap
        self.batterySaver = batterySaver
    }
}

public struct PowerMode: Hashable, Sendable {
    public enum Kind: String, Sendable { case normal, battery, occluded, suspended }
    public var kind: Kind
    /// nil = don't fetch at all.
    public var pollInterval: TimeInterval?
    /// 0 = don't draw.
    public var fps: Double

    public init(kind: Kind, pollInterval: TimeInterval?, fps: Double) {
        self.kind = kind
        self.pollInterval = pollInterval
        self.fps = fps
    }
}

public enum PowerPolicy {
    public static func mode(_ i: PowerInputs, _ s: PowerSettings) -> PowerMode {
        if i.paused || i.screenLocked || i.displaysAsleep {
            return PowerMode(kind: .suspended, pollInterval: nil, fps: 0)
        }
        if i.allOccluded {
            return PowerMode(kind: .occluded, pollInterval: max(60, s.pollInterval), fps: 0)
        }
        if i.lowPowerMode || (i.onBattery && s.batterySaver) {
            return PowerMode(kind: .battery, pollInterval: max(15, s.pollInterval), fps: min(15, s.fpsCap))
        }
        return PowerMode(kind: .normal, pollInterval: s.pollInterval, fps: s.fpsCap)
    }
}
