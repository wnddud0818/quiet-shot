import SwiftUI

@main
struct QuietShotApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
