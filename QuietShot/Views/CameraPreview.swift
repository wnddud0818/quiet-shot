import AVFoundation
import AVKit
import SwiftUI
import UIKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass를 지정했으므로 항상 성공
        layer as! AVCaptureVideoPreviewLayer
    }

    /// 인터페이스 방향 변화 (iPhone Duo 안쪽 화면처럼 앱 화면이 가로로 돌아가는 경우 대응)
    var onInterfaceOrientationChange: ((UIInterfaceOrientation) -> Void)?
    private var lastOrientation: UIInterfaceOrientation = .unknown

    override func layoutSubviews() {
        super.layoutSubviews()
        reportInterfaceOrientation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportInterfaceOrientation()
    }

    private func reportInterfaceOrientation() {
        guard let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
              orientation != lastOrientation else { return }
        lastOrientation = orientation
        onInterfaceOrientationChange?(orientation)
    }
}

/// 볼륨 버튼 / 카메라 제어 버튼 / AirPods 셔터 이벤트 단계
enum HardwareShutterPhase {
    case began
    case ended
    case cancelled
}

/// AVCaptureVideoPreviewLayer + 카메라 제스처.
/// - 탭: 초점/노출, 길게 누르기: AE/AF 잠금, 두 손가락 핀치: 줌, 한 손가락 위아래 드래그: 노출 또는 빠른 설정
/// - 볼륨 버튼·카메라 제어 버튼: 셔터 (iOS 17.2+)
/// - iPhone Duo: 사용자 쪽을 향한 전면 카메라 추적 (iOS 27.1+)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayerReady: (AVCaptureVideoPreviewLayer) -> Void
    let onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    let onLongPress: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    let onPinch: (_ state: UIGestureRecognizer.State, _ scale: CGFloat) -> Void
    let onPan: (_ state: UIGestureRecognizer.State, _ translation: CGSize) -> Void
    let onHardwareShutter: (HardwareShutterPhase) -> Void
    let onForwardFacingCamerasChange: ([String]) -> Void
    let onInterfaceOrientationChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        // 선택한 비율의 프레임을 꽉 채움 = 저장되는 중앙 크롭 영역과 동일
        view.previewLayer.videoGravity = .resizeAspectFill

        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        tap.require(toFail: longPress)
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        [tap, longPress, pinch, pan].forEach(view.addGestureRecognizer)

        view.onInterfaceOrientationChange = { [weak coordinator] orientation in
            coordinator?.parent.onInterfaceOrientationChange(orientation)
        }
        coordinator.installHardwareShutter(on: view)
        coordinator.installDirectionCoordinator(on: view)

        onLayerReady(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CameraPreview
        private var eventInteraction: UIInteraction?
        private var directionCoordinator: AnyObject?

        init(parent: CameraPreview) {
            self.parent = parent
        }

        // MARK: 제스처

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onTap(point, view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view as? PreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onLongPress(point, view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            parent.onPinch(recognizer.state, recognizer.scale)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            parent.onPan(recognizer.state, CGSize(width: translation.x, height: translation.y))
        }

        // MARK: 하드웨어 셔터 (볼륨 버튼, 카메라 제어 버튼, AirPods)

        func installHardwareShutter(on view: UIView) {
            guard #available(iOS 17.2, *) else { return }
            let interaction = AVCaptureEventInteraction { [weak self] event in
                let phase: HardwareShutterPhase
                switch event.phase {
                case .began: phase = .began
                case .ended: phase = .ended
                default: phase = .cancelled
                }
                self?.parent.onHardwareShutter(phase)
            }
            view.addInteraction(interaction)
            eventInteraction = interaction
        }

        // MARK: iPhone Duo — 어느 전면 카메라가 사용자를 향하는지

        func installDirectionCoordinator(on view: UIView) {
            // iPhone Duo가 아니거나 iOS 27.1 SDK가 아니면 nil
            directionCoordinator = DuoSupport.makeDirectionCoordinator(view: view) { [weak self] ids in
                self?.parent.onForwardFacingCamerasChange(ids)
            }
        }
    }
}
