import SwiftUI

/// 촬영 비율에 따라 크기가 변하는 미리보기와 별도로, 현재 화면의 가장자리에 조작부를 배치한다.
struct DuoCaptureControls<Tools: View, Lenses: View, Modes: View, Shutter: View, Gallery: View, Flip: View>: View {
    let landscape: Bool
    let railWidth: CGFloat
    let tools: Tools
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
        } else {
            VStack(spacing: 4) {
                tools
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
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
