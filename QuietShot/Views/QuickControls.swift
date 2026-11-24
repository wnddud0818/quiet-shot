import SwiftUI

/// 상단 배지를 누르거나 미리보기를 위로 쓸어 올리면 나타나는 빠른 설정 줄.
/// 항목을 누르면 그 자리에서 선택지가 펼쳐집니다.
struct QuickControls: View {
    @Binding var aspectRatio: AspectRatioOption
    @Binding var captureTimer: CaptureTimer
    @Binding var showGrid: Bool
    @Binding var saveFormat: SaveFormat
    let megapixelText: (AspectRatioOption) -> String
    let iconAngle: Angle
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
        .background(Capsule().fill(Theme.glass))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
    }

    private var ratioOptions: [Option] {
        AspectRatioOption.allCases.map { option in
            Option(id: option.title, detail: megapixelText(option), selected: option == aspectRatio) {
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
        HStack(spacing: 4) {
            item(icon: "aspectratio", caption: aspectRatio.title, active: aspectRatio != .fourThree) {
                expanded = .ratio
            }
            item(icon: "timer", caption: captureTimer.title, active: captureTimer != .off) {
                expanded = .timer
            }
            item(icon: "grid", caption: "격자", active: showGrid) {
                showGrid.toggle()
            }
            item(icon: "photo", caption: saveFormat == .heic ? "HEIC" : "JPEG", active: false) {
                saveFormat = saveFormat == .heic ? .jpeg : .heic
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
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
            .rotationEffect(iconAngle)
        }
        .buttonStyle(PressableStyle())
    }

    private func optionRow(_ options: [Option]) -> some View {
        HStack(spacing: 6) {
            Button {
                expanded = nil
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
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
                    .frame(minWidth: 50, minHeight: 40)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(option.selected ? Theme.accent : Theme.chip))
                    .rotationEffect(iconAngle)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}
