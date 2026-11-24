import AVFoundation
import AVKit
import UIKit

/// iPhone Duo(폴더블) 전용 API를 한곳에 모음.
/// 바깥/안쪽 화면 개별 전면 카메라와 AVCaptureDeviceDirectionCoordinator는 iOS 27.1 SDK(Xcode 27.1+)에만 있으므로
/// `canImport(AVKit.AVCaptureDeviceDirectionCoordinator)`로 SDK를 확인해 그보다 오래된 Xcode에서도 빌드되게 합니다.
/// (실행 시에는 #available(iOS 27.1, *)로 다시 확인)
enum DuoSupport {

    /// iPhone Duo 개별 전면 카메라 타입 (해당 SDK/OS가 아니면 빈 배열)
    static var frontCameraTypes: [AVCaptureDevice.DeviceType] {
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
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
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
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
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
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

