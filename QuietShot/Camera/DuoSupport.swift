import AVFoundation
import AVKit
import UIKit

/// iPhone Duo(폴더블) 전용 API를 한곳에 모음.
/// 바깥/안쪽 화면 개별 전면 카메라와 AVCaptureDeviceDirectionCoordinator는 iOS 27.1 SDK(Xcode 27.1+)에만 있으므로
/// 그보다 오래된 Xcode에서도 빌드되도록 컴파일 단계에서 분리합니다. (런타임은 #available로 다시 확인)
enum DuoSupport {

    /// iPhone Duo 개별 전면 카메라 타입 (해당 SDK/OS가 아니면 빈 배열)
    static var frontCameraTypes: [AVCaptureDevice.DeviceType] {
        #if DUO_SDK_AVAILABLE
        if #available(iOS 27.1, *) {
            return [.builtInOuterUltraWideCamera, .builtInInnerUltraWideCamera]
        }
        #endif
        return []
    }

    static func isDuoFrontCamera(_ type: AVCaptureDevice.DeviceType) -> Bool {
        frontCameraTypes.contains(type)
    }

    static func label(for type: AVCaptureDevice.DeviceType) -> String? {
        #if DUO_SDK_AVAILABLE
        if #available(iOS 27.1, *) {
            if type == .builtInOuterUltraWideCamera { return "전면 · 바깥 화면" }
            if type == .builtInInnerUltraWideCamera { return "전면 · 안쪽 화면" }
        }
        #endif
        return nil
    }

    /// 화면이 접히거나 펼쳐질 때 사용자 쪽을 향한 카메라 ID 목록을 알려 주는 코디네이터.
    /// iPhone Duo가 아니면 nil. 반환값을 보관해야 계속 동작합니다. (메인 스레드에서 호출)
    static func makeDirectionCoordinator(view: UIView, onChange: @escaping ([String]) -> Void) -> AnyObject? {
        #if DUO_SDK_AVAILABLE
        if #available(iOS 27.1, *) {
            let types = frontCameraTypes
            let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .front).devices
            guard !cameras.isEmpty else { return nil }
            return AVCaptureDeviceDirectionCoordinator(view: view, deviceTypes: types) { (directions: AVCaptureDeviceDirectionMap) in
                onChange(directions.forwardFacingDeviceDescriptors.map { $0.uniqueID })
            }
        }
        #endif
        return nil
    }
}

// TEMP PROBE (removed before merge)
#if canImport(UIKit.UIHinge)
#warning("PROBE canImport(UIKit.UIHinge)")
#endif
#if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
#warning("PROBE canImport(AVKit.AVCaptureDeviceDirectionCoordinator)")
#endif
#if compiler(>=6.3)
#warning("PROBE compiler>=6.3")
#endif
#if compiler(>=6.4)
#warning("PROBE compiler>=6.4")
#endif
#if compiler(>=6.5)
#warning("PROBE compiler>=6.5")
#endif
#if compiler(>=7.0)
#warning("PROBE compiler>=7.0")
#endif
