import SwiftUI

/// 화면 위쪽에 항상 표시되는 빠른 설정 줄.
/// 항목을 누르면 그 자리에서 선택지가 펼쳐집니다.
struct QuickControls: View {
    @ObservedObject var camera: CameraController
    @Binding var aspectRatio: AspectRatioOption
    @Binding var captureTimer: CaptureTimer
    @Binding var showGrid: Bool
    @Binding var saveFormat: SaveFormat
    let iconAngle: Angle
    /// iPhone Duo 커버(바깥) 화면 미리보기. 펼쳐서 시스템이 표시할 수 있을 때만 값이 있다 (nil → 버튼 숨김)
    var outerPreview: Binding<Bool>? = nil
    let onOpenSettings: () -> Void

    private enum Expanded { case ratio, timer }
    @State private var expanded: Expanded?

    private struct Option: Identifiable {
        let id: String
        let detail: String?
        let selected: Bool
        let select: () -> Void
    }

    var body: some View {
        Group {
            switch expanded {
            case .ratio:
                optionRow(ratioOptions)
            case .timer:
                optionRow(timerOptions)
            case nil:
                mainRow
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.glass))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
    }

    private var ratioOptions: [Option] {
        AspectRatioOption.allCases.map { option in
            Option(id: option.title, detail: camera.megapixelText(for: option), selected: option == aspectRatio) {
                aspectRatio = option
            }
        }
    }

    private var timerOptions: [Option] {
        CaptureTimer.allCases.map { option in
            Option(id: option.title, detail: nil, selected: option == captureTimer) {
                captureTimer = option
            }
        }
    }

    private var mainRow: some View {
        optionStrip {
            if let outerPreview {
                // 기본은 꺼짐. 펼친 상태에서 이 버튼을 눌러야 커버 화면에 미리보기가 켜진다.
                item(icon: "rectangle.on.rectangle", caption: "커버 화면", active: outerPreview.wrappedValue) {
                    let enabled = !outerPreview.wrappedValue
                    outerPreview.wrappedValue = enabled
                    camera.toast = enabled ? "커버 화면 미리보기 켬" : "커버 화면 미리보기 끔"
                }
                .accessibilityLabel("커버 화면 미리보기")
                .accessibilityValue(outerPreview.wrappedValue ? "켬" : "끔")
            }
            if camera.captureMode == .video {
                MovieOptions(camera: camera, compact: true, iconAngle: iconAngle)
            } else {
                item(icon: "aspectratio", caption: aspectRatio.title, active: aspectRatio != .fourThree) {
                    expanded = .ratio
                }
                item(icon: "timer", caption: captureTimer.title, active: captureTimer != .off) {
                    expanded = .timer
                }
            }
            item(icon: "grid", caption: "격자", active: showGrid) {
                showGrid.toggle()
            }
            if camera.captureMode == .photo {
                item(icon: "photo", caption: saveFormat == .heic ? "HEIC" : "JPEG", active: false) {
                    saveFormat = saveFormat == .heic ? .jpeg : .heic
                }
            }
            item(icon: "gearshape", caption: "설정", active: false, action: onOpenSettings)
        }
    }

    private func item(icon: String, caption: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(caption)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Theme.accent : Color.white)
            .rotationEffect(iconAngle)
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func optionStrip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let row = HStack(spacing: 4, content: content)
        return ViewThatFits(in: .horizontal) {
            row.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) { row }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(_ options: [Option]) -> some View {
        optionStrip {
            Button {
                expanded = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(iconAngle)
                    .frame(width: 30, height: 44)
            }
            .accessibilityLabel("뒤로")
            ForEach(options) { option in
                Button {
                    Haptics.selection()
                    option.select()
                    expanded = nil
                } label: {
                    VStack(spacing: 2) {
                        Text(option.id)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        if let detail = option.detail {
                            Text(detail)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(option.selected ? Color.black : Color.white)
                    .rotationEffect(iconAngle)
                    .frame(minWidth: 50, minHeight: 40)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(option.selected ? Theme.accent : Theme.chip))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}
