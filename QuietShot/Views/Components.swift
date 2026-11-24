import SwiftUI
import UIKit

struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 40
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
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

/// 탭한 위치에 나타나는 초점 표시
struct FocusSquare: View {
    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    scale = 1
                }
                withAnimation(.easeOut(duration: 0.4).delay(1.2)) {
                    opacity = 0
                }
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
