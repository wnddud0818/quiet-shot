import AVFoundation
import SwiftUI
import UIKit

/// 카메라 프레임(AVCaptureVideoDataOutput)을 직접 그리는 미리보기.
///
/// AVCaptureVideoPreviewLayer 대신 사용하는 이유
/// - 정사각형 센서(iPhone 17·Duo 전면)에서 화면 비율이 바뀌어도 실제 프레임 크기로 그려 찌그러지지 않음
/// - 저장되는 프레임과 똑같은 영상이 보임 (미리보기 = 결과물)
/// - 같은 프레임을 여러 화면(iPhone Duo 바깥 화면)에 동시에 보낼 수 있음 (세션에 미리보기 레이어를 더 붙이지 않음)
final class FramePreviewView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let camera: CameraController
    private let source: CameraController.PreviewSource
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// 들어오는 버퍼에 추가로 적용할 시계방향 회전(도). 0/90/180/270
    private var rotationAngle: CGFloat = 0 {
        didSet { if oldValue != rotationAngle { setNeedsLayout() } }
    }
    /// 화면에서 좌우 반전 (전면 카메라 셀카 미리보기)
    private let mirrored: Bool
    /// 들어오는 버퍼 크기 (탭 위치 → 초점 좌표 변환용)
    var bufferSize: CGSize = .zero
    var onRotationChange: ((CGFloat) -> Void)?

    init(camera: CameraController, source: CameraController.PreviewSource, mirrored: Bool) {
        self.camera = camera
        self.source = source
        self.mirrored = mirrored
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let quarters = FramePreviewMath.quarterTurns(rotationAngle)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = quarters % 2 == 1 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        displayLayer.bounds = CGRect(origin: .zero, size: size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeRotation(CGFloat(quarters) * .pi / 2, 0, 0, 1)
        if mirrored {
            transform = CATransform3DConcat(transform, CATransform3DMakeScale(-1, 1, 1))
        }
        displayLayer.transform = transform
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let renderer = displayLayer.sampleBufferRenderer
        camera.removePreviewRenderer(renderer)
        rotationObservation?.invalidate()
        rotationCoordinator = nil
        guard window != nil else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: source.device, previewLayer: displayLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] current, _ in
            guard let self, self.rotationCoordinator === current else { return }
            self.rotationAngle = current.videoRotationAngleForHorizonLevelPreview - self.source.connectionAngle
            self.onRotationChange?(current.videoRotationAngleForHorizonLevelPreview)
        }
        layoutIfNeeded()
        camera.addPreviewRenderer(renderer, for: source.connection)
    }

    /// 화면 좌표 → 초점/노출 관심 지점 (센서 기준 0~1)
    func devicePoint(for point: CGPoint) -> CGPoint {
        guard let transform = FramePreviewMath.deviceToViewTransform(
            viewSize: bounds.size,
            bufferSize: bufferSize,
            rotationQuarters: FramePreviewMath.quarterTurns(rotationAngle),
            mirrored: mirrored,
            connectionQuarters: FramePreviewMath.quarterTurns(source.connectionAngle)
        ) else { return CGPoint(x: 0.5, y: 0.5) }
        let sensor = point.applying(transform.inverted())
        return CGPoint(x: min(max(sensor.x, 0), 1), y: min(max(sensor.y, 0), 1))
    }
}

/// 카메라 컨트롤러에 프레임 렌더러를 등록·해제하는 미리보기 (iPhone Duo 바깥 화면용)
struct OuterFramePreview: UIViewRepresentable {
    let camera: CameraController
    let source: CameraController.PreviewSource

    func makeUIView(context: Context) -> FramePreviewView {
        FramePreviewView(camera: camera, source: source, mirrored: source.device.position == .back)
    }

    func updateUIView(_ uiView: FramePreviewView, context: Context) {}
}
