import SwiftUI

/// 센서 기준 초점 위치. 미리보기 크기와 방향이 바뀌어도 유지한다.
struct FocusMark: Equatable {
    var devicePoint: CGPoint
    var locked: Bool
    var id: Int
}

/// 초점 사각형 + 노출 슬라이더(해 아이콘).
/// 초점 표시가 떠 있을 때 화면을 위아래로 끌면 노출(EV)이 바뀝니다.
struct FocusOverlay: View {
    let point: CGPoint
    let locked: Bool
    let exposureBias: Float
    let dimmed: Bool
    let showSlider: Bool
    let containerSize: CGSize

    @State private var scale: CGFloat = 1.35

    private let boxSize: CGFloat = 74
    private let sliderHeight: CGFloat = 120

    var body: some View {
        // 화면 오른쪽 끝 근처면 슬라이더를 왼쪽에 표시
        let sliderOnLeft = point.x + boxSize / 2 + 30 > containerSize.width
        let sliderX: CGFloat = sliderOnLeft ? -(boxSize / 2 + 18) : (boxSize / 2 + 18)
        let sunY = CGFloat(-exposureBias / 2) * (sliderHeight / 2)

        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: boxSize, height: boxSize)
                .overlay(alignment: .top) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .offset(y: -12)
                    }
                }
                .scaleEffect(scale)

            // 노출 슬라이더
            ZStack {
                if showSlider || abs(exposureBias) > 0.01 {
                    Capsule()
                        .fill(Theme.accent.opacity(0.6))
                        .frame(width: 1.5, height: sliderHeight)
                        .transition(.opacity)
                }
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .offset(y: sunY)
            }
            .offset(x: sliderX)
        }
        .opacity(dimmed ? 0.45 : 1)
        .position(point)
        .animation(.easeOut(duration: 0.2), value: dimmed)
        .animation(.easeOut(duration: 0.15), value: showSlider)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                scale = 1
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
