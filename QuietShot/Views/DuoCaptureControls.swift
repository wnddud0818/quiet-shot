import SwiftUI

/// 촬영 비율에 따라 크기가 변하는 미리보기와 별도로, 현재 화면의 가장자리에 조작부를 배치한다.
///
/// `safeArea`는 이 영역의 가장자리에서 버튼이 피해야 하는 거리(세로 막대·홈 인디케이터·카메라 구멍)다.
/// 세로 배치에서는 아래쪽 촬영 줄과 빠른 옵션이 화면 가운데에 오도록 좌우 여백을 다르게 쓴다.
/// - 도구 줄(손전등·배지): 안전 영역 안쪽
/// - 빠른 옵션: 좌우 같은 여백으로 화면 가운데
/// - 배율·모드·셔터 줄: 화면 전체 폭 (위아래 여백만 적용)
struct DuoCaptureControls<Tools: View, Options: View, Lenses: View, Modes: View, Shutter: View, Gallery: View, Flip: View>: View {
    let landscape: Bool
    let railWidth: CGFloat
    var safeArea = EdgeInsets()
    let tools: Tools
    let options: Options
    let lenses: Lenses
    let modes: Modes
    let shutter: Shutter
    let gallery: Gallery
    let flip: Flip

    var body: some View {
        if landscape {
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    tools
                    options
                    Spacer(minLength: 0)
                    lenses
                    modes
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ZStack {
                    shutter
                    VStack {
                        flip
                        Spacer(minLength: 0)
                        gallery
                    }
                }
                .frame(width: railWidth)
            }
            .padding(.vertical, 10)
            .padding(safeArea)
        } else {
            // 빠른 옵션은 양쪽 가장자리에서 max(12, 안전 여백)만큼 떨어져 화면 가운데에 놓인다.
            let centered = max(0, max(safeArea.leading, safeArea.trailing) - 12)
            VStack(spacing: 4) {
                tools
                    .padding(.leading, safeArea.leading)
                    .padding(.trailing, safeArea.trailing)
                options
                    .padding(.horizontal, centered)
                Spacer(minLength: 0)
                lenses
                modes
                HStack {
                    gallery
                    Spacer(minLength: 0)
                    shutter
                    Spacer(minLength: 0)
                    flip
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10 + safeArea.top)
            .padding(.bottom, 10 + safeArea.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
