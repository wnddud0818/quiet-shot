import SwiftUI

/// 설정 폼과 카메라의 빠른 옵션이 같은 선택지와 실제 적용 값을 표시한다.
struct MovieOptions: View {
    @ObservedObject var camera: CameraController
    var compact = false
    var iconAngle: Angle = .zero

    var body: some View {
        let supported = camera.supportedMovieQualities
        let active = camera.movieQuality
        let resolutions = MovieQuality.Resolution.allCases.filter { resolution in
            supported.contains { $0.resolution == resolution }
        }
        let rates = supported.filter { $0.resolution == active?.resolution }.map(\.fps)
        Group {
            menu("해상도", icon: "rectangle.dashed", values: resolutions,
                 current: active?.resolution, text: { $0.rawValue }) { resolution in
                if let quality = MovieQuality.bestMatch(in: supported, resolution: resolution, fps: active?.fps ?? 30) {
                    camera.setMovieQuality(quality)
                }
            }
            menu("프레임률", icon: "speedometer", values: rates,
                 current: active?.fps, text: { "\($0) fps" }) { fps in
                if let quality = supported.first(where: { $0.resolution == active?.resolution && $0.fps == fps }) {
                    camera.setMovieQuality(quality)
                }
            }
            if compact {
                Button { camera.setMicrophoneEnabled(!camera.recordsAudio) } label: {
                    tile(camera.recordsAudio ? "마이크 켬" : "마이크 끔",
                         icon: camera.recordsAudio ? "mic.fill" : "mic.slash.fill")
                }
                .buttonStyle(PressableStyle())
            } else {
                Toggle("마이크", isOn: Binding(get: { camera.recordsAudio }, set: camera.setMicrophoneEnabled))
            }
        }
        .disabled(!camera.canEditMovieSettings)
    }

    private func menu<Value: Hashable>(_ title: String, icon: String, values: [Value],
                                       current: Value?, text: @escaping (Value) -> String,
                                       select: @escaping (Value) -> Void) -> some View {
        let value = current.map(text) ?? "자동"
        return Menu {
            ForEach(values, id: \.self) { option in
                Button { select(option) } label: {
                    if option == current {
                        Label(text(option), systemImage: "checkmark")
                    } else {
                        Text(text(option))
                    }
                }
            }
        } label: {
            if compact {
                tile(value, icon: icon)
            } else {
                LabeledContent(title, value: value)
            }
        }
        .disabled(values.isEmpty)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func tile(_ caption: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(caption).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .rotationEffect(iconAngle)
        .frame(width: 52, height: 48)
        .contentShape(Rectangle())
    }
}
