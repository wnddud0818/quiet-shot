import CoreLocation
import Foundation

/// 촬영 위치(GPS)·방향을 EXIF에 기록하기 위한 위치 공급자.
/// 반드시 메인 스레드에서 처음 접근(CameraScreen.onAppear)해야 델리게이트 콜백이 메인 런루프로 옵니다.
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    static let shared = LocationProvider()

    struct Snapshot {
        let location: CLLocation?
        let heading: CLHeading?

        static let empty = Snapshot(location: nil, heading: nil)
    }

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var latestLocation: CLLocation?
    private var latestHeading: CLHeading?
    private var isEnabled = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
    }

    /// 위치 권한이 거부/제한된 상태인지 (메인 스레드)
    var isAuthorizationDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// 카메라가 화면에 떠 있는 동안만 위치를 갱신 (메인 스레드)
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                beginUpdates()
            default:
                break
            }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
        }
    }

    /// 촬영 순간의 위치/방향 (어느 스레드에서든 호출 가능)
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        // 10분 이상 지난 위치는 기록하지 않음
        guard let location = latestLocation, abs(location.timestamp.timeIntervalSinceNow) < 600 else {
            return Snapshot(location: nil, heading: nil)
        }
        return Snapshot(location: location, heading: latestHeading)
    }

    private func beginUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isEnabled else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        lock.lock()
        latestLocation = location
        lock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        lock.lock()
        latestHeading = newHeading
        lock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 일시적인 실패는 무시 (다음 갱신을 기다림)
    }
}
