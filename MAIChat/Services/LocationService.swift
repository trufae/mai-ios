import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published var lastLocationText = ""

  private let manager = CLLocationManager()
  private var continuation: CheckedContinuation<CLLocation?, Never>?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
  }

  func currentLocationText() async -> String {
    guard let location = await requestLocation() else {
      return "Location unavailable"
    }
    let text = String(
      format: "Latitude %.4f, longitude %.4f", location.coordinate.latitude,
      location.coordinate.longitude)
    lastLocationText = text
    return text
  }

  private func requestLocation() async -> CLLocation? {
    let status = manager.authorizationStatus
    if status == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }
    guard
      status == .authorizedWhenInUse || status == .authorizedAlways
        || manager.authorizationStatus == .authorizedWhenInUse
    else {
      return nil
    }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      manager.requestLocation()
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    Task { @MainActor in
      continuation?.resume(returning: locations.last)
      continuation = nil
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      continuation?.resume(returning: nil)
      continuation = nil
    }
  }
}
