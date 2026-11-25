import CoreGraphics

/// 미리보기 회전·반전·화면 채우기 계산 (순수 함수)
enum FramePreviewMath {

    static func quarterTurns(_ angle: CGFloat) -> Int {
        var normalized = angle.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return Int((normalized / 90).rounded()) % 4
    }

    /// 센서의 정규화된 좌표를 미리보기 좌표로 옮긴다. 탭은 같은 변환의 역행렬을 사용한다.
    static func deviceToViewTransform(viewSize: CGSize,
                                      bufferSize: CGSize,
                                      rotationQuarters: Int,
                                      mirrored: Bool,
                                      connectionQuarters: Int) -> CGAffineTransform? {
        guard viewSize.width > 0, viewSize.height > 0, bufferSize.width > 0, bufferSize.height > 0 else {
            return nil
        }
        let layerSize = rotationQuarters % 2 == 1
            ? CGSize(width: viewSize.height, height: viewSize.width)
            : viewSize
        let scale = max(layerSize.width / bufferSize.width, layerSize.height / bufferSize.height)
        return CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(connectionQuarters) * .pi / 2))
            .concatenating(CGAffineTransform(scaleX: bufferSize.width * scale, y: bufferSize.height * scale))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotationQuarters) * .pi / 2))
            .concatenating(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
            .concatenating(CGAffineTransform(translationX: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// 전체 화면을 채우는 미리보기에서 안전 영역 안쪽의 셔터 열에 양보할 수 있는 폭.
    static func trailingPadding(viewport: CGSize, aspect: CGFloat,
                                railWidth: CGFloat, safeAreaInset: CGFloat) -> CGFloat {
        let spareWidth = max(0, viewport.width - viewport.height * aspect)
        return min(railWidth + safeAreaInset, spareWidth)
    }
}
