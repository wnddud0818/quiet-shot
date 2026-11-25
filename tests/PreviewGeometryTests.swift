import CoreGraphics

@main
enum PreviewGeometryTests {
    static func main() {
        let sensor = CGPoint(x: 0.8, y: 0.25)
        let buffer = CGSize(width: 400, height: 300)
        let portrait = CGSize(width: 300, height: 400)
        let landscape = CGSize(width: 400, height: 300)
        checkProjection(sensor, CGPoint(x: 225, y: 320), portrait, buffer, rotation: 1)
        checkProjection(sensor, CGPoint(x: 320, y: 75), landscape, buffer, rotation: 0)
        checkProjection(sensor, CGPoint(x: 75, y: 320), portrait, buffer, rotation: 1, mirrored: true)
        checkProjection(sensor, CGPoint(x: 80, y: 75), landscape, buffer, rotation: 0, mirrored: true)
        // 같은 영상이 이미 커넥션에서 90도 회전해서 들어오는 경우.
        checkProjection(sensor, CGPoint(x: 225, y: 320), portrait, portrait, rotation: 0, connection: 1)
        checkProjection(sensor, CGPoint(x: 320, y: 75), landscape, portrait, rotation: 3, connection: 1)
        checkProjection(sensor, CGPoint(x: 80, y: 225), landscape, buffer, rotation: 2)
        // 정사각형 미리보기에서는 좌우 각 50pt가 잘린다.
        checkProjection(sensor, CGPoint(x: 270, y: 75), CGSize(width: 300, height: 300), buffer, rotation: 0)

        let wide = CGSize(width: 800, height: 360)
        for viewport in [wide, portrait, landscape] {
            for aspect: CGFloat in [1, 4.0 / 3, 16.0 / 9, 3.0 / 4, 9.0 / 16] {
                for inset: CGFloat in [0, 20, 50] {
                    let padding = FramePreviewMath.trailingPadding(viewport: viewport, aspect: aspect,
                                                                  railWidth: 96, safeAreaInset: inset)
                    let imageWidth = min(viewport.width, viewport.height * aspect)
                    precondition(viewport.width - padding >= imageWidth - 0.0001)
                    let imageRight = (viewport.width - padding + imageWidth) / 2
                    let railLeft = viewport.width - inset - 96
                    let overlap = max(0, imageRight - railLeft)
                    precondition(abs(overlap - max(0, imageWidth - railLeft)) < 0.0001)
                }
            }
        }
        print("Preview geometry checks passed")
    }

    static func checkProjection(_ sensor: CGPoint, _ expected: CGPoint, _ view: CGSize,
                                _ buffer: CGSize, rotation: Int, connection: Int = 0, mirrored: Bool = false) {
        guard let transform = FramePreviewMath.deviceToViewTransform(viewSize: view, bufferSize: buffer,
                                                                     rotationQuarters: rotation, mirrored: mirrored,
                                                                     connectionQuarters: connection) else {
            preconditionFailure("Missing transform for a nonempty preview")
        }
        let drawn = sensor.applying(transform)
        let tapped = expected.applying(transform.inverted())
        precondition(abs(drawn.x - expected.x) < 0.0001 && abs(drawn.y - expected.y) < 0.0001)
        precondition(abs(tapped.x - sensor.x) < 0.0001 && abs(tapped.y - sensor.y) < 0.0001)
    }
}
