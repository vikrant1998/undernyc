@preconcurrency import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var smoothedTrueHeading: Double?
    @Published private(set) var error: String?

    private let manager = CLLocationManager()
    private var requestedTemporaryPrecision = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
        manager.headingFilter = 1
        manager.headingOrientation = .portrait
    }

    var isLocationReady: Bool {
        guard manager.accuracyAuthorization == .fullAccuracy,
              let location, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 100
        else { return false }
        return true
    }

    var needsPreciseLocation: Bool {
        manager.accuracyAuthorization == .reducedAccuracy
    }

    var isReady: Bool {
        guard isLocationReady,
              let heading, heading.trueHeading >= 0,
              heading.headingAccuracy >= 0,
              heading.headingAccuracy
                <= HeadingEstimator.preciseStandardDeviationDegrees
        else { return false }
        return true
    }

    func start() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        guard authorization == .authorizedWhenInUse
                || authorization == .authorizedAlways else {
            error = "Precise outdoor placement requires location access."
            return
        }
        manager.startUpdatingLocation()
        requestTemporaryPrecisionIfNeeded()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            error = nil
            manager.startUpdatingLocation()
            requestTemporaryPrecisionIfNeeded()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        } else if authorization == .denied || authorization == .restricted {
            error = "Camera-relative trains require location and compass access."
        }
    }

    private func requestTemporaryPrecisionIfNeeded() {
        guard manager.accuracyAuthorization == .reducedAccuracy,
              !requestedTemporaryPrecision else { return }
        requestedTemporaryPrecision = true
        manager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: "PreciseSubwayAR"
        ) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let newest = locations.last, newest.timestamp.timeIntervalSinceNow > -10 else {
            return
        }
        Task { @MainActor in self.location = newest }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        Task { @MainActor in
            self.heading = newHeading
            let measurement = newHeading.trueHeading >= 0
                ? newHeading.trueHeading
                : newHeading.magneticHeading
            if let previous = self.smoothedTrueHeading {
                let delta = GeoCoordinateConverter.signedHeadingDeltaDegrees(
                    from: previous, to: measurement
                )
                let updated = (previous + delta * 0.22)
                    .truncatingRemainder(dividingBy: 360)
                self.smoothedTrueHeading = updated >= 0 ? updated : updated + 360
            } else {
                self.smoothedTrueHeading = measurement
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.error = error.localizedDescription }
    }
}
