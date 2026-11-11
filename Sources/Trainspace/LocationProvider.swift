import TrainspaceCore
import CoreLocation
import MapKit

/// Wraps Core Location for "use my location". Kilometre accuracy is plenty and cheap.
@MainActor
final class LocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onUpdate: ((Coordinate) -> Void)?
    var onFailure: ((String) -> Void)?

    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1_000
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func start() {
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onFailure?("Location access is off for Trainspace. Turn it on in System Settings › Privacy & Security › Location Services, or choose a place instead.")
        default:
            manager.startUpdatingLocation()
            if let last = manager.location { onUpdate?(Coordinate(last.coordinate)) }
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard running else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted:
            onFailure?("Location access is off for Trainspace. Turn it on in System Settings › Privacy & Security › Location Services, or choose a place instead.")
        default: manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running, let last = locations.last else { return }
        onUpdate?(Coordinate(last.coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard running else { return }
        if (error as? CLError)?.code == .locationUnknown { return }   // transient; keep waiting
        onFailure?("Couldn’t determine your location (\(error.localizedDescription)). You can choose a place instead.")
    }
}

extension Coordinate {
    init(_ c: CLLocationCoordinate2D) { self.init(latitude: c.latitude, longitude: c.longitude) }
    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum Geocoding {
    struct Place { var coordinate: Coordinate; var name: String? }

    enum Failure: Error { case notFound }

    /// Zip code or place name → coordinate.
    static func search(_ query: String) async throws -> Place {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw Failure.notFound }
        let c = item.placemark.coordinate
        let name = item.placemark.locality ?? item.name
        return Place(coordinate: Coordinate(latitude: c.latitude, longitude: c.longitude), name: name)
    }

    /// Coordinate → short place name ("Washington"), or nil.
    static func placeName(for c: Coordinate) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(c.clLocation)
        guard let p = placemarks?.first else { return nil }
        return p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.ocean ?? p.inlandWater
    }
}
