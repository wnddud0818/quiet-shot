import CoreMotion
import Foundation

/// 화면 회전 잠금과 무관하게 실제 기기 방향을 감지해 아이콘을 회전시키기 위한 모니터.
/// (사진 자체의 회전은 AVCaptureDevice.RotationCoordinator가 담당)
final class DeviceOrientationMonitor: ObservableObject {
    /// SwiftUI rotationEffect에 넣을 각도(도, 시계방향 +)
    @Published private(set) var iconRotation: Double = 0

    private let motion = CMMotionManager()

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.acceleration else { return }
            let x = gravity.x
            let y = gravity.y
            let threshold = 0.3   // 대각선 근처에서 흔들리지 않도록 히스테리시스
            var next: Double?
            if abs(y) > abs(x) + threshold {
                next = y < 0 ? 0 : 180          // 세로 / 거꾸로
            } else if abs(x) > abs(y) + threshold {
                next = x < 0 ? 90 : -90         // 홈 방향 오른쪽 / 왼쪽 가로
            }
            if let next, next != self.iconRotation {
                self.iconRotation = next
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
