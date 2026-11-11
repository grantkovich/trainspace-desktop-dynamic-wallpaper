import Foundation
import Testing
@testable import TrainspaceCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct GTFSRealtimeTests {
    @Test func decodesMARCVehiclePositions() throws {
        let feed = try GTFSRealtime.decode(try fixture("marc-vp.pb"))
        #expect(feed.timestamp != nil)
        let v = try #require(feed.vehicles.first)
        #expect(feed.vehicles.count == 1)
        #expect(v.tripID == "Train677Sunday")
        #expect(v.routeID == "11705")
        #expect(v.vehicleID == "000023")
        // Somewhere on the Penn Line between Washington and Perryville.
        #expect((38.8...39.7).contains(v.latitude))
        #expect((-77.1 ... -76.0).contains(v.longitude))
    }

    @Test func mapsVehiclesToLinesAndTrainNumbers() throws {
        let network = try RailNetworkTests.network()
        let feed = try GTFSRealtime.decode(try fixture("marc-vp.pb"))
        let r = try #require(GTFSRealtimeSource.reports(feed, system: .marc, network: network, receivedAt: Date().timeIntervalSince1970).first)
        #expect(r.trainNumber == "677")
        #expect(network.lines[try #require(r.line)].id == "marc.penn")
        #expect(r.label(network: network) == "MARC 677")
        #expect(r.isScheduled == false)
    }

    @Test func trainNumbersFromTripIDs() {
        #expect(GTFSRealtimeSource.trainNumber(fromTripID: "Train677Sunday", system: .marc) == "677")
        #expect(GTFSRealtimeSource.trainNumber(fromTripID: "305-Regular", system: .vre) == "305")
        #expect(GTFSRealtimeSource.trainNumber(fromTripID: "11968412_20762", system: .metrorail) == nil)
        #expect(GTFSRealtimeSource.trainNumber(fromTripID: nil, system: .marc) == nil)
    }

    @Test func skipsUnknownFieldsAndRejectsTruncation() throws {
        // Field 15 (varint) and field 16 (length-delimited) before an entity with no vehicle.
        let bytes: [UInt8] = [0x78, 0x05, 0x82, 0x01, 0x02, 0xAA, 0xBB, 0x12, 0x03, 0x0A, 0x01, 0x41]
        let feed = try GTFSRealtime.decode(Data(bytes))
        #expect(feed.vehicles.isEmpty)
        #expect(throws: ProtobufError.self) { try GTFSRealtime.decode(Data([0x12, 0x09, 0x0A])) }
    }
}

@Suite struct AmtrakTests {
    @Test func decryptsAndFiltersToRegion() throws {
        let json = try AmtrakFeed.decrypt(try fixture("amtrak-trains.txt"), keys: .fallback)
        let region = GeoBounds(minLat: 37.8, maxLat: 40.2, minLon: -78.8, maxLon: -75.4)
        let trains = try AmtrakFeed.trains(geoJSON: json, in: region, network: nil, receivedAt: Date().timeIntervalSince1970)
        // Predeparture and out-of-region trains are dropped.
        #expect(trains.compactMap(\.trainNumber).sorted() == ["164", "2201"])
        let regional = try #require(trains.first { $0.trainNumber == "164" })
        #expect(regional.headsign == "Boston")
        #expect(regional.bearingDeg == 135)
        #expect(abs((regional.speedMph ?? 0) - 23.5) < 0.1)
        #expect(regional.id == "amtrak:164-11/8/2026")
        #expect(regional.label(network: nil) == "AMTK 164")
    }

    @Test func wrongKeyFails() throws {
        var keys = AmtrakFeed.KeyMaterial.fallback
        keys.publicKey = "not-the-key"
        #expect(throws: (any Error).self) { try AmtrakFeed.decrypt(try fixture("amtrak-trains.txt"), keys: keys) }
    }

    @Test func derivesKeyMaterialLikeTheMap() throws {
        let routes = Data(#"[{"ZoomLevel": 1}, {"ZoomLevel": 1}, {"Name": "no zoom"}]"#.utf8)
        let keys = Data(#"{"arr": ["a", "b", "picked"], "s": ["xy", "00", "0a0b"], "v": ["12", "zz", "ff01"]}"#.utf8)
        let m = try AmtrakFeed.keyMaterial(routesList: routes, keys: keys)
        #expect(m.publicKey == "picked")
        #expect(m.salt == [0x0A, 0x0B])
        #expect(m.iv == [0xFF, 0x01])
    }

    @Test func compassPoints() {
        #expect(AmtrakFeed.compass("N") == 0)
        #expect(AmtrakFeed.compass("sw") == 225)
        #expect(AmtrakFeed.compass("?") == nil)
    }
}
