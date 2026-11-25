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
    static func makeDirectionCoordinator(view: UIView, onChange: @escaping ([String], Bool?) -> Void) -> AnyObject? {
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
        if #available(iOS 27.1, *) {
            let types = frontCameraTypes
            let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .front).devices
            guard !cameras.isEmpty else { return nil }
            let outerID = cameras.first { $0.deviceType == .builtInOuterUltraWideCamera }?.uniqueID
            let innerID = cameras.first { $0.deviceType == .builtInInnerUltraWideCamera }?.uniqueID
            return AVCaptureDeviceDirectionCoordinator(view: view, deviceTypes: types) { (directions: AVCaptureDeviceDirectionMap) in
                let ids = directions.forwardFacingDeviceDescriptors.map { $0.uniqueID }
                // 앱을 이미 접거나 펼친 상태에서 켜면 최초 힌지 업데이트 전에도 화면을 식별한다.
                let outer = outerID.map { ids.contains($0) } ?? false
                let inner = innerID.map { ids.contains($0) } ?? false
                onChange(ids, outer == inner ? nil : outer)
            }
        }
        #endif
        return nil
    }
}

