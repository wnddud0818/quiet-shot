import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// 볼륨 버튼 / 카메라 제어 버튼 / AirPods 셔터 이벤트 단계
enum HardwareShutterPhase {
    case began
    case ended
    case cancelled
}

/// 본 화면 카메라 미리보기 (프레임을 직접 그리는 FramePreviewView) + 카메라 제스처.
/// - 탭: 초점/노출, 길게 누르기: AE/AF 잠금, 두 손가락 핀치: 줌, 한 손가락 위아래 드래그: 노출
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    let source: CameraController.PreviewSource
    let bufferSize: CGSize
    let onTap: (_ devicePoint: CGPoint) -> Void
    let onLongPress: (_ devicePoint: CGPoint) -> Void
    let onPinch: (_ state: UIGestureRecognizer.State, _ scale: CGFloat) -> Void
    let onPan: (_ state: UIGestureRecognizer.State, _ translation: CGSize) -> Void

    func makeUIView(context: Context) -> FramePreviewView {
        let view = FramePreviewView(camera: camera, source: source, mirrored: source.device.position == .front)
        view.onRotationChange = { camera.reportMainPreviewRotation($0, for: source) }
        let coordinator = context.coordinator

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        tap.require(toFail: longPress)
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        [tap, longPress, pinch, pan].forEach(view.addGestureRecognizer)

        view.bufferSize = bufferSize
        return view
    }

    func updateUIView(_ uiView: FramePreviewView, context: Context) {
        context.coordinator.parent = self
        uiView.bufferSize = bufferSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CameraPreview

        init(parent: CameraPreview) {
            self.parent = parent
        }

        // MARK: 제스처

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? FramePreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onTap(view.devicePoint(for: point))
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view as? FramePreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onLongPress(view.devicePoint(for: point))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            parent.onPinch(recognizer.state, recognizer.scale)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            parent.onPan(recognizer.state, CGSize(width: translation.x, height: translation.y))
        }
    }
}

/// 미리보기가 교체되어도 같은 뷰에서 창 방향과 하드웨어 셔터 입력을 추적한다.
struct CameraWindowObserver: UIViewRepresentable {
    let shutterEnabled: Bool
    let onHardwareShutter: (HardwareShutterPhase) -> Void
    let onForwardFacingCamerasChange: ([String], Bool?) -> Void
    let onInterfaceOrientationChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak view] event in
                switch event.phase {
                case .began: view?.onHardwareShutter?(.began)
                case .ended: view?.onHardwareShutter?(.ended)
                default: view?.onHardwareShutter?(.cancelled)
                }
            }
            view.addInteraction(interaction)
            view.shutterInteraction = interaction
        }
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onHardwareShutter = onHardwareShutter
        if #available(iOS 17.2, *), let interaction = view.shutterInteraction as? AVCaptureEventInteraction,
           interaction.isEnabled != shutterEnabled {
            interaction.isEnabled = shutterEnabled
        }
        view.onForwardFacingCamerasChange = onForwardFacingCamerasChange
        view.onInterfaceOrientationChange = onInterfaceOrientationChange
    }

    final class ObserverView: UIView {
        weak var shutterInteraction: UIInteraction?
        var onHardwareShutter: ((HardwareShutterPhase) -> Void)?
        var onForwardFacingCamerasChange: (([String], Bool?) -> Void)?
        var onInterfaceOrientationChange: ((UIInterfaceOrientation) -> Void)?
        private var directionCoordinator: AnyObject?
        private var geometryObservation: NSKeyValueObservation?
        private var lastOrientation: UIInterfaceOrientation = .unknown

        override func didMoveToWindow() {
            super.didMoveToWindow()
            geometryObservation?.invalidate()
            directionCoordinator = nil
            lastOrientation = .unknown
            guard let scene = window?.windowScene else { return }
            directionCoordinator = DuoSupport.makeDirectionCoordinator(view: self) { [weak self, weak scene] ids, outer in
                guard let self, let scene, self.window?.windowScene === scene else { return }
                self.onForwardFacingCamerasChange?(ids, outer)
            }
            geometryObservation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
                DispatchQueue.main.async {
                    guard let self, self.window?.windowScene === scene else { return }
                    let orientation = scene.effectiveGeometry.interfaceOrientation
                    guard orientation != .unknown, orientation != self.lastOrientation else { return }
                    self.lastOrientation = orientation
                    self.onInterfaceOrientationChange?(orientation)
                }
            }
        }
    }
}

/// 화면을 세로로 고정해도 iPhone Duo 안쪽 화면은 기기 방향을 따라 창을 돌린다.
/// 이때 시스템 회전 애니메이션을 끄고 바뀐 방향을 같은 순간에 알려, 버튼을 기기에 고정하는
/// 반대 회전(DuoControlPlacement)과 함께 화면이 돌아가는 모션 없이 바로 전환한다.
/// 접거나 펼 때의 크기 변화(회전 없음)는 시스템 애니메이션을 그대로 둔다.
struct RotationTransitionGuard: UIViewControllerRepresentable {
    let onInterfaceOrientationChange: (UIInterfaceOrientation) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onInterfaceOrientationChange = onInterfaceOrientationChange
    }

    final class Controller: UIViewController {
        var onInterfaceOrientationChange: ((UIInterfaceOrientation) -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            guard !coordinator.targetTransform.isIdentity else { return }
            let animationsWereEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            coordinator.animate(alongsideTransition: { [weak self] _ in
                guard let orientation = self?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation,
                      orientation != .unknown else { return }
                self?.onInterfaceOrientationChange?(orientation)
            }, completion: { _ in
                UIView.setAnimationsEnabled(animationsWereEnabled)
            })
        }
    }
}
