import SwiftUI
import UIKit

/// QuietShot 고유 스타일 (기본 카메라의 노란색 대신 민트 포인트)
enum Theme {
    static let accent = Color(red: 0.38, green: 0.91, blue: 0.72)
    static let chip = Color.white.opacity(0.14)
    static let glass = Color.black.opacity(0.55)
}

/// 햅틱 (설정에서 켰을 때만. 조용한 곳에서 진동음이 들릴 수 있어 기본은 꺼짐)
enum Haptics {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.hapticOnCapture)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 40
    var tint: Color = .white
    var background: Color = Theme.chip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// 누를 때 살짝 작아지는 버튼 스타일
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 3분할 격자
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for index in 1...2 {
                    let x = width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                    let y = height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
            Text("카메라 접근 권한이 필요합니다")
                .font(.headline)
            Text("설정 > QuietShot에서 카메라 접근을 허용해 주세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(32)
        .foregroundStyle(.white)
    }
}

struct UnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .foregroundStyle(.white)
    }
}
