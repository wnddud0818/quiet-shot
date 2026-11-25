import SwiftUI

/// 버튼 배치와 접는 선은 기기의 세로 정방향을 기준으로 하고, 카메라 영상은 창 좌표를 사용한다.
struct DuoControlSpace {
    enum Posture: Equatable { case closed, open, folded }
    struct Anchor: Equatable {
        let posture: Posture
        let referenceDegrees: Double
        let margins: EdgeInsets
    }

    let anchor: Anchor
    let sceneSize: CGSize
    let size: CGSize
    let sceneDegrees: Double
    let fixedToScene: CGAffineTransform
    let viewfinder: CGRect
    /// 버튼이 들어가는 안전 영역 (세로 막대·홈 인디케이터 제외)
    let controls: CGRect
    /// 조작부 배경과 하단 촬영 줄이 쓰는 영역. 접는 선 반대쪽의 화면 가장자리까지 넓힌다.
    let controlsBleed: CGRect
    let split: Bool
    let sideRail: Bool

    func labelDegrees(for deviceDegrees: Double) -> Double {
        Self.relativeAngle(deviceDegrees, to: anchor.referenceDegrees)
    }

    private static func relativeAngle(_ value: Double, to reference: Double) -> Double {
        let delta = value - reference
        if delta > 180 { return delta - 360 }
        if delta <= -180 { return delta + 360 }
        return delta
    }

    init(sceneSize: CGSize, safeBounds: CGRect, sceneDegrees: Double, posture: Posture,
         sceneFold: CGRect?, previous: Anchor?) {
        self.sceneSize = sceneSize
        let retained = previous?.posture == posture ? previous : nil
        // 탁상·책 모드는 반접힘에 진입한 방향을 기준으로 미리보기 쪽을 선택한다.
        let reference = retained?.referenceDegrees ?? (posture == .folded ? sceneDegrees : 0)
        let relative = Self.relativeAngle(sceneDegrees, to: reference)
        self.sceneDegrees = relative
        switch relative {
        case 90:  // 홈 인디케이터가 오른쪽에 있는 창
            fixedToScene = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: sceneSize.height)
        case -90:
            fixedToScene = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: sceneSize.width, ty: 0)
        case 180:
            fixedToScene = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: sceneSize.width, ty: sceneSize.height)
        default:
            fixedToScene = .identity
        }
        let inverse = fixedToScene.inverted()
        size = CGRect(origin: .zero, size: sceneSize).applying(inverse).size
        let safe = safeBounds.applying(inverse)
        // 홈 인디케이터가 다른 가장자리로 옮겨가도 같은 자세의 버튼은 움직이지 않는다.
        // 기준 방향으로 돌아오면 현재 안전 영역으로 다시 맞춘다.
        let current = EdgeInsets(top: safe.minY, leading: safe.minX,
                                 bottom: size.height - safe.maxY, trailing: size.width - safe.maxX)
        let margins = relative != 0 ? (retained?.margins ?? current) : current
        anchor = Anchor(posture: posture, referenceDegrees: reference, margins: margins)
        let bounds = CGRect(x: margins.leading, y: margins.top,
                            width: max(0, size.width - margins.leading - margins.trailing),
                            height: max(0, size.height - margins.top - margins.bottom))
        if posture == .folded, let fold = sceneFold?.applying(inverse).intersection(bounds), !fold.isNull {
            split = true
            let horizontal = fold.width >= fold.height
            if horizontal {
                viewfinder = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fold.minY - bounds.minY)
                controls = CGRect(x: bounds.minX, y: fold.maxY, width: bounds.width, height: bounds.maxY - fold.maxY)
                controlsBleed = CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY)
            } else {
                viewfinder = CGRect(x: bounds.minX, y: bounds.minY, width: fold.minX - bounds.minX, height: bounds.height)
                controls = CGRect(x: fold.maxX, y: bounds.minY, width: bounds.maxX - fold.maxX, height: bounds.height)
                controlsBleed = CGRect(x: fold.maxX, y: 0, width: size.width - fold.maxX, height: size.height)
            }
            sideRail = !horizontal && controls.width >= 250
        } else {
            split = false
            viewfinder = bounds
            controls = bounds
            controlsBleed = CGRect(origin: .zero, size: size)
            sideRail = posture != .closed && bounds.width >= 250
        }
    }
}

/// 같은 변환이 SwiftUI 그리기와 버튼의 터치 영역에 적용된다.
struct DuoControlPlacement: ViewModifier {
    let space: DuoControlSpace

    func body(content: Content) -> some View {
        content
            .frame(width: space.size.width, height: space.size.height)
            .rotationEffect(.degrees(-space.sceneDegrees))
            .position(x: space.sceneSize.width / 2, y: space.sceneSize.height / 2)
    }
}
