import SwiftUI

/// 탭: 1장 촬영 / 길게 누르기: 손을 뗄 때까지 연속 촬영
struct ShutterButton: View {
    let isBursting: Bool
    let burstCount: Int
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
            Circle()
                .fill(isBursting ? Color.yellow : Color.white)
                .frame(width: 64, height: 64)
                .scaleEffect(isPressed ? 0.86 : 1)
                .animation(.easeOut(duration: 0.12), value: isPressed)
            if isBursting {
                Text("\(burstCount)")
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black)
            }
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
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
        .accessibilityLabel("셔터")
        .accessibilityHint("탭하면 촬영, 길게 누르면 연속 촬영")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}
