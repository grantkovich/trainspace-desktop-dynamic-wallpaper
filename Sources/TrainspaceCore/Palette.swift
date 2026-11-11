import Foundation

public struct RGBA: Hashable, Sendable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    public func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    public static func mix(_ x: RGBA, _ y: RGBA, _ t: Double) -> RGBA {
        RGBA(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t, x.a + (y.a - x.a) * t)
    }

    /// Hue (0…1), saturation, lightness.
    public var hsl: (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx > mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    public init(hue h: Double, saturation s: Double, lightness l: Double, alpha: Double = 1) {
        guard s > 0 else { self.init(l, l, l, alpha); return }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        self.init(f(h + 1 / 3), f(h), f(h - 1 / 3), alpha)
    }

    /// Relative luminance (sRGB, roughly): for picking text that reads on a colour.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// Colour tokens for one appearance. Night and Aluminum are the two poles; Dynamic mixes them.
public struct Palette: Hashable, Sendable {
    public var water, land, urban, dotGrid, river, road, stateLine: RGBA
    public var station, stationLabel, ring, ringLabel, crosshair: RGBA
    public var textPrimary, textSecondary, textTertiary: RGBA
    public var monochrome: RGBA
    /// 0 on dark surfaces … 1 on light ones: how `lineColor` tunes agency colours.
    public var lightness: Double
    /// How strongly the network's track is drawn under the trains (0…1).
    public var trackOpacity: Double
    /// Status text ("NO SIGNAL").
    public var warning: RGBA
    /// 0 (light surfaces, glow reads as a soft halo) … 1 (dark, full bloom).
    public var glow: Double
    public var isDark: Bool

    /// A line's map colour for this surface. Agency colours are made for white paper: on the dark
    /// palette they're lifted until they read against the night, on the light one deep enough to
    /// read against aluminium. DC's colours keep the versions tuned by hand for the first release.
    public func lineColor(_ hex: UInt32) -> RGBA {
        if let (dark, light) = Self.tuned[hex] { return RGBA.mix(RGBA(hex: dark), RGBA(hex: light), lightness) }
        let base = RGBA(hex: hex)
        return RGBA.mix(Self.tune(base, dark: true), Self.tune(base, dark: false), lightness)
    }

    /// Hand-tuned (night, aluminium) pairs, keyed by map colour.
    static let tuned: [UInt32: (UInt32, UInt32)] = [
        0xC80F2D: (0xE8505B, 0xC8102E), 0xED8B00: (0xF0901E, 0xD86F00), 0x009CDE: (0x3A9BEA, 0x0077C8),
        0x00B140: (0x2BB673, 0x00873C), 0xFFD100: (0xF2D03B, 0xB88E00), 0x919D9D: (0xAEB6B8, 0x7A8487),
        0x8A3FC4: (0xB675E8, 0x8A3FC4), 0xD0337F: (0xF06AAE, 0xD0337F), 0x2A2B2E: (0xEDE9E1, 0x2A2B2E),
        0x007499: (0x34C6CF, 0x00838C), 0x008000: (0x61C454, 0x3E8E2F),
    ]

    /// Moves a colour's lightness (HSL) into the band that reads on each surface, keeping its hue.
    static func tune(_ c: RGBA, dark: Bool) -> RGBA {
        let h = c.hsl.0
        var (_, s, l) = c.hsl
        if dark {
            l = max(l, 0.58)
            if l > 0.86 { l = 0.86 }
            s = min(s, 0.85)
        } else {
            // Yellows and bright greens are far brighter than their HSL lightness says: cap by luminance.
            let lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            if lum > 0.45 { l *= 0.45 / lum }
            l = min(l, 0.5)
        }
        return RGBA(hue: h, saturation: s, lightness: l)
    }

    public static let night = Palette(
        water: RGBA(hex: 0x0B0C0E), land: RGBA(hex: 0x121316), urban: RGBA(hex: 0x17181B),
        dotGrid: RGBA(hex: 0x2A2C30), river: RGBA(hex: 0x1C2026), road: RGBA(hex: 0x1F2125),
        stateLine: RGBA(hex: 0x2B2D31), station: RGBA(hex: 0x8E8B85), stationLabel: RGBA(hex: 0x76736E),
        ring: RGBA(hex: 0x2C2E33), ringLabel: RGBA(hex: 0x56585C), crosshair: RGBA(hex: 0x8A8780),
        textPrimary: RGBA(hex: 0xECE8E1), textSecondary: RGBA(hex: 0x9A968F), textTertiary: RGBA(hex: 0x5E5C58),
        monochrome: RGBA(hex: 0xF4F1EA),
        lightness: 0,
        trackOpacity: 0.34, warning: RGBA(hex: 0xFF7A59), glow: 1, isDark: true)

    public static let aluminum = Palette(
        water: RGBA(hex: 0xDCDAD4), land: RGBA(hex: 0xECEAE5), urban: RGBA(hex: 0xE3E1DB),
        dotGrid: RGBA(hex: 0xCFCCC5), river: RGBA(hex: 0xCDCBC5), road: RGBA(hex: 0xDAD7D0),
        stateLine: RGBA(hex: 0xC9C6BF), station: RGBA(hex: 0x6E6B66), stationLabel: RGBA(hex: 0x86837D),
        ring: RGBA(hex: 0xCBC8C1), ringLabel: RGBA(hex: 0x9C9993), crosshair: RGBA(hex: 0x5D5B57),
        textPrimary: RGBA(hex: 0x1C1D1F), textSecondary: RGBA(hex: 0x6A6863), textTertiary: RGBA(hex: 0xA19E98),
        monochrome: RGBA(hex: 0x26272A),
        lightness: 1,
        trackOpacity: 0.42, warning: RGBA(hex: 0xE0502E), glow: 0.25, isDark: false)

    /// Linear blend between two palettes; `t` = 0 → a, 1 → b.
    public static func mix(_ a: Palette, _ b: Palette, _ t: Double) -> Palette {
        if t <= 0 { return a }
        if t >= 1 { return b }
        func m(_ k: KeyPath<Palette, RGBA>) -> RGBA { RGBA.mix(a[keyPath: k], b[keyPath: k], t) }
        return Palette(
            water: m(\.water), land: m(\.land), urban: m(\.urban), dotGrid: m(\.dotGrid), river: m(\.river),
            road: m(\.road), stateLine: m(\.stateLine), station: m(\.station), stationLabel: m(\.stationLabel),
            ring: m(\.ring), ringLabel: m(\.ringLabel), crosshair: m(\.crosshair),
            textPrimary: m(\.textPrimary), textSecondary: m(\.textSecondary), textTertiary: m(\.textTertiary),
            monochrome: m(\.monochrome),
            lightness: a.lightness + (b.lightness - a.lightness) * t,
            trackOpacity: a.trackOpacity + (b.trackOpacity - a.trackOpacity) * t,
            warning: m(\.warning),
            glow: a.glow + (b.glow - a.glow) * t, isDark: t < 0.5 ? a.isDark : b.isDark)
    }

    /// Resolves the palette for the user's appearance setting.
    /// - Parameters:
    ///   - systemIsDark: current macOS appearance.
    ///   - daylight: 0…1 from `Solar.daylight`, used when following the sun.
    public static func resolve(_ mode: AppearanceMode, source: DynamicSource, systemIsDark: Bool, daylight: Double) -> Palette {
        switch mode {
        case .light: return .aluminum
        case .dark: return .night
        case .dynamic:
            switch source {
            case .system: return systemIsDark ? .night : .aluminum
            case .sun: return mix(.night, .aluminum, daylight)
            }
        }
    }
}
