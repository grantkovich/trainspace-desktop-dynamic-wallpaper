import Foundation

/// NOAA solar position (accurate to well under a degree, plenty for picking a palette).
public enum Solar {
    /// Sun elevation above the horizon in degrees.
    public static func elevation(at date: Date, coordinate: Coordinate) -> Double {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525

        let l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m.radians) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin((2 * m).radians) * (0.019993 - 0.000101 * t)
            + sin((3 * m).radians) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let appLong = trueLong - 0.00569 - 0.00478 * sin(omega.radians)
        let meanObliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(omega.radians)
        let decl = asin(sin(obliq.radians) * sin(appLong.radians))

        let y = pow(tan((obliq / 2).radians), 2)
        let eqTime = 4 * (y * sin(2 * l0.radians) - 2 * e * sin(m.radians)
            + 4 * e * y * sin(m.radians) * cos(2 * l0.radians)
            - 0.5 * y * y * sin(4 * l0.radians) - 1.25 * e * e * sin(2 * m.radians)).degrees

        let minutesUTC = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        var trueSolar = (minutesUTC + eqTime + 4 * coordinate.longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolar < 0 { trueSolar += 1440 }
        let hourAngle = trueSolar / 4 < 0 ? trueSolar / 4 + 180 : trueSolar / 4 - 180

        let lat = coordinate.latitude.radians
        let cosZenith = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle.radians)
        return 90 - acos(min(1, max(-1, cosZenith))).degrees
    }

    /// 0 at night, 1 in daylight; eased across civil twilight (−6°) to just after sunrise (+3°).
    public static func daylight(elevation: Double) -> Double {
        let t = min(1, max(0, (elevation + 6) / 9))
        return t * t * (3 - 2 * t)
    }
}
