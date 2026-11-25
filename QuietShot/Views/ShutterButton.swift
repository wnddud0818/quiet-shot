import SwiftUI

/// 탭: 촬영 (타이머가 켜져 있으면 카운트다운) / 길게 누르기: 손을 뗄 때까지 연속 촬영
struct ShutterButton: View {
    let isBursting: Bool
    let burstCount: Int
    let isCountingDown: Bool
    let onTap: () -> Void
    let onBurstStart: () -> Void
    let onBurstEnd: () -> Void

    @State private var isPressed = false
    @State private var burstActive = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            if isCountingDown {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 30, height: 30)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .fill(isBursting ? Theme.accent : Color.white)
                    .frame(width: 64, height: 64)
                    .scaleEffect(isPressed ? 0.86 : 1)
                    .transition(.scale.combined(with: .opacity))
            }
            if isBursting {
                Text("\(burstCount)")
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.black)
                    .contentTransition(.numericText())
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCountingDown)
        .animation(.easeOut(duration: 0.1), value: burstCount)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    guard !isCountingDown else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        burstActive = true
                        onBurstStart()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    holdTask?.cancel()
                    holdTask = nil
                    if burstActive {
                        burstActive = false
                        onBurstEnd()
                    } else {
                        onTap()
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(isCountingDown ? "타이머 취소" : "셔터")
        .accessibilityHint("탭하면 촬영, 길게 누르면 연속 촬영")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .onDisappear {
            holdTask?.cancel()
            if burstActive { onBurstEnd() }
        }
    }
}
