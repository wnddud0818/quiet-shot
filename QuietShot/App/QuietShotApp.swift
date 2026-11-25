import AVKit
import SwiftUI
import UIKit

@MainActor
final class CameraOrientationDelegate: NSObject, UIApplicationDelegate {
    private static let masks = NSMapTable<UIWindowScene, NSNumber>.weakToStrongObjects()

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if let scene = window?.windowScene, let mask = Self.masks.object(forKey: scene) {
            return UIInterfaceOrientationMask(rawValue: mask.uintValue)
        }
        return .allButUpsideDown
    }

    static func setOrientationLock(_ orientation: UIInterfaceOrientation?, in window: UIWindow) {
        guard let scene = window.windowScene else { return }
        let mask = orientation.map { UIInterfaceOrientationMask(rawValue: 1 << $0.rawValue) }
        guard masks.object(forKey: scene)?.uintValue != mask?.rawValue else { return }
        if let mask {
            masks.setObject(NSNumber(value: mask.rawValue), forKey: scene)
        } else {
            masks.removeObject(forKey: scene)
        }
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask ?? .allButUpsideDown))
    }
}

@main
struct QuietShotApp: App {
    @UIApplicationDelegateAdaptor(CameraOrientationDelegate.self) private var orientationDelegate

    init() {
        // AirPods 카메라 제어(줄기 클릭)로 촬영할 때 시스템 셔터 소리를 내지 않음
        if #available(iOS 26.0, *) {
            AVCaptureEventInteraction.defaultCaptureSoundDisabled = true
        }
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
