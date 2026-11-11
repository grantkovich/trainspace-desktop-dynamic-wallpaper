import CommonCrypto
import Foundation

/// Amtrak's Track-a-Train map feed. There's no official public API; the map's own feed is
/// AES-encrypted with key material it publishes alongside (the same approach community
/// trackers such as Amtraker use).
///
/// The payload is base64. Its last 88 characters encrypt a per-response private key with the
/// published public key; the rest is the GeoJSON, encrypted with that private key. Keys are
/// stretched with PBKDF2-SHA1 (1,000 rounds, 128 bits) and used for AES-128-CBC.
public enum AmtrakFeed {
    public struct KeyMaterial: Hashable, Sendable {
        public var publicKey: String
        public var salt: [UInt8]
        public var iv: [UInt8]

        public init(publicKey: String, salt: [UInt8], iv: [UInt8]) {
            self.publicKey = publicKey
            self.salt = salt
            self.iv = iv
        }

        /// The values the map has published for a long time; used if fetching them fails.
        public static let fallback = KeyMaterial(publicKey: "69af143c-e8cf-47f8-bf09-fc1f61e5cc33",
                                                 salt: hexBytes("9a3686ac")!, iv: hexBytes("c6eb2f7f5c4740c1a2f708fefd947d39")!)
    }

    public enum Failure: Error, Equatable { case badKeyMaterial, decryptionFailed, badPayload }

    static let privateKeySegment = 88
    public static let trainsURL = URL(string: "https://maps.amtrak.com/services/MapDataService/trains/getTrainsData")!
    public static let routesURL = URL(string: "https://maps.amtrak.com/rttl/js/RoutesList.json")!
    public static let keysURL = URL(string: "https://maps.amtrak.com/rttl/js/RoutesList.v.json")!

    /// Key material as the map derives it: the public key is `arr[sum of every route's ZoomLevel]`,
    /// the salt is `s[length of s[0]]` and the IV is `v[length of v[0]]`.
    public static func keyMaterial(routesList: Data, keys: Data) throws -> KeyMaterial {
        guard let routes = try JSONSerialization.jsonObject(with: routesList) as? [[String: Any]],
              let k = try JSONSerialization.jsonObject(with: keys) as? [String: Any],
              let arr = k["arr"] as? [String], let s = k["s"] as? [String], let v = k["v"] as? [String],
              let s0 = s.first, let v0 = v.first else { throw Failure.badKeyMaterial }
        let zoom = routes.reduce(0) { $0 + (($1["ZoomLevel"] as? NSNumber)?.intValue ?? 0) }
        guard arr.indices.contains(zoom), s.indices.contains(s0.count), v.indices.contains(v0.count),
              let salt = hexBytes(s[s0.count]), let iv = hexBytes(v[v0.count]) else { throw Failure.badKeyMaterial }
        return KeyMaterial(publicKey: arr[zoom], salt: salt, iv: iv)
    }

    /// Decrypts a getTrainsData response to its GeoJSON bytes.
    public static func decrypt(_ payload: Data, keys: KeyMaterial) throws -> Data {
        guard let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count > privateKeySegment else { throw Failure.badPayload }
        let split = text.index(text.endIndex, offsetBy: -privateKeySegment)
        guard let keyCipher = Data(base64Encoded: String(text[split...])),
              let bodyCipher = Data(base64Encoded: String(text[..<split])) else { throw Failure.badPayload }
        let keyPlain = try aes(keyCipher, password: keys.publicKey, keys: keys)
        guard let privateKey = String(data: keyPlain, encoding: .utf8)?.split(separator: "|").first.map(String.init),
              !privateKey.isEmpty else { throw Failure.decryptionFailed }
        return try aes(bodyCipher, password: privateKey, keys: keys)
    }

    static func aes(_ cipher: Data, password: String, keys: KeyMaterial) throws -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let pw = Array(password.utf8)
        let status = pw.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 p.count, keys.salt, keys.salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                                 &key, key.count)
        }
        guard status == kCCSuccess else { throw Failure.decryptionFailed }
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let result = cipher.withUnsafeBytes { c in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, keys.iv, c.baseAddress, cipher.count, &out, out.count, &moved)
        }
        guard result == kCCSuccess else { throw Failure.decryptionFailed }
        return Data(out.prefix(moved))
    }

    /// Active trains inside `bounds` from decrypted GeoJSON.
    public static func trains(geoJSON: Data, in bounds: GeoBounds, network: RailNetwork?, receivedAt: TimeInterval) throws -> [TrainReport] {
        guard let root = try JSONSerialization.jsonObject(with: geoJSON) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw Failure.badPayload }
        let line = network?.line(id: "amtrak")
        return features.compactMap { f in
            guard let g = f["geometry"] as? [String: Any], let c = g["coordinates"] as? [NSNumber], c.count >= 2,
                  let p = f["properties"] as? [String: Any] else { return nil }
            let position = Coordinate(latitude: c[1].doubleValue, longitude: c[0].doubleValue)
            guard position.isValid, bounds.contains(position) else { return nil }
            let state = (p["TrainState"] as? String) ?? "Active"
            guard state == "Active" else { return nil }   // skip predeparture and completed trains
            let trainNumber = (p["TrainNum"] as? String) ?? (p["TrainNum"] as? NSNumber)?.stringValue
            let speed = number(p["Velocity"])
            let fix = timestamp(p["LastValTS"] as? String).map { min(receivedAt, $0) } ?? receivedAt
            // Train number + origin date is stable across refreshes; the record ID is not guaranteed to be.
            let origin = (p["OrigSchDep"] as? String)?.split(separator: " ").first.map(String.init) ?? ""
            guard let id = trainNumber.map({ "\($0)-\(origin)" }) ?? (p["ID"] as? NSNumber)?.stringValue else { return nil }
            return TrainReport(id: "amtrak:\(id)", system: .amtrak, line: line, trainNumber: trainNumber,
                               headsign: (p["DestCode"] as? String).map(stationName),
                               position: position, bearingDeg: compass(p["Heading"] as? String), speedMph: speed,
                               status: (speed ?? 1) < 1 ? .stopped : .moving, fixTime: max(fix, receivedAt - 900))
        }
    }

    /// One train's times at one station, from the `StationN` entries of each feature.
    public struct StationTime: Hashable, Sendable {
        public var trainNumber: String
        public var code: String
        public var scheduledDeparture: Date?
        /// Estimated departure, while the train hasn't left.
        public var estimatedDeparture: Date?
        /// Set once the train has left.
        public var departed: Date?
        /// Amtrak's own remark: "ON TIME", "05 MI LATE".
        public var comment: String?
    }

    /// Scheduled and estimated times at `codes` (e.g. WAS, BAL) for every train in the feed.
    public static func stationTimes(geoJSON: Data, codes: Set<String>) throws -> [StationTime] {
        guard let root = try JSONSerialization.jsonObject(with: geoJSON) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw Failure.badPayload }
        var out: [StationTime] = []
        for f in features {
            guard let p = f["properties"] as? [String: Any],
                  let number = (p["TrainNum"] as? String) ?? (p["TrainNum"] as? NSNumber)?.stringValue else { continue }
            for (key, value) in p where key.hasPrefix("Station") {
                guard let text = value as? String, text.hasPrefix("{\"code\":\""),
                      codes.contains(where: { text.hasPrefix("{\"code\":\"\($0)\"") }),
                      let data = text.data(using: .utf8),
                      let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let code = st["code"] as? String else { continue }
                let tz = st["tz"] as? String
                func date(_ k: String) -> Date? { stationDate(st[k] as? String, tz: tz) }
                let comment = (st["postcmnt"] as? String) ?? (st["estdepcmnt"] as? String) ?? (st["estarrcmnt"] as? String)
                out.append(StationTime(trainNumber: number, code: code, scheduledDeparture: date("schdep") ?? date("scharr"),
                                       estimatedDeparture: date("estdep") ?? date("estarr"), departed: date("postdep"),
                                       comment: comment?.trimmingCharacters(in: .whitespaces).nilIfEmpty))
            }
        }
        return out
    }

    /// "11/08/2026 14:17:00" in the station's time zone (E, C, M, P).
    static func stationDate(_ s: String?, tz: String?) -> Date? {
        guard let s else { return nil }
        let zone = switch tz {
        case "C": "America/Chicago"
        case "M": "America/Denver"
        case "P": "America/Los_Angeles"
        default: "America/New_York"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return f.date(from: s)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// "SE" → 135.
    static func compass(_ s: String?) -> Double? {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        guard let s = s?.uppercased(), let i = points.firstIndex(of: s) else { return nil }
        return Double(i) * 22.5
    }

    /// "11/8/2026 9:39:40 AM", in Eastern time for the trains we show.
    static func timestamp(_ s: String?) -> TimeInterval? {
        guard let s else { return nil }
        return timestampFormatter.date(from: s)?.timeIntervalSince1970
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f
    }()

    /// Station codes Amtrak trains in the region are usually bound for.
    static let stations: [String: String] = [
        "WAS": "Washington", "BAL": "Baltimore", "BWI": "BWI", "NYP": "New York", "BOS": "Boston", "PHL": "Philadelphia",
        "NPN": "Newport News", "NFK": "Norfolk", "RVR": "Richmond", "RVM": "Richmond", "LYH": "Lynchburg", "ROA": "Roanoke",
        "CVS": "Charlottesville", "NOL": "New Orleans", "CHI": "Chicago", "MIA": "Miami", "SAV": "Savannah", "LOR": "Lorton",
        "SFA": "Sanford", "RGH": "Raleigh", "CLT": "Charlotte", "SPG": "Springfield", "ALB": "Albany", "PGH": "Pittsburgh",
        "HAR": "Harrisburg", "STM": "St. Albans", "NHV": "New Haven", "WIL": "Wilmington", "TPA": "Tampa", "JAX": "Jacksonville",
        "ATL": "Atlanta", "SAB": "St. Albans", "ORL": "Orlando", "WPB": "West Palm Beach", "NCR": "New Carrollton",
    ]

    static func stationName(_ code: String) -> String { stations[code.uppercased()] ?? code.uppercased() }
}

func hexBytes(_ hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let b = UInt8(String(decoding: chars[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
