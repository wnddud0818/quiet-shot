import AVKit
import SwiftUI

@main
struct QuietShotApp: App {
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
