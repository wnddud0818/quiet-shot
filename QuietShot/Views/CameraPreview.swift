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
/// - 탭: 초점/노출, 길게 누르기: AE/AF 잠금, 두 손가락 핀치: 줌, 한 손가락 위아래 드래그: 노출 또는 빠른 설정
/// - 볼륨 버튼·카메라 제어 버튼: 셔터 (iOS 17.2+)
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    let source: CameraController.PreviewSource
    let bufferSize: CGSize
    let onTap: (_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    let onLongPress: (_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    let onPinch: (_ state: UIGestureRecognizer.State, _ scale: CGFloat) -> Void
    let onPan: (_ state: UIGestureRecognizer.State, _ translation: CGSize) -> Void
    let onHardwareShutter: (HardwareShutterPhase) -> Void

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

        coordinator.installHardwareShutter(on: view)
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
        private var eventInteraction: UIInteraction?

        init(parent: CameraPreview) {
            self.parent = parent
        }

        // MARK: 제스처

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? FramePreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onTap(point, view.devicePoint(for: point))
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view as? FramePreviewView else { return }
            let point = recognizer.location(in: view)
            parent.onLongPress(point, view.devicePoint(for: point))
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
    }
}

/// 접힘이나 카메라 전환으로 미리보기가 교체되어도 본 화면을 기준으로 방향을 추적한다.
struct CameraWindowObserver: UIViewRepresentable {
    let lockedOrientation: UIInterfaceOrientation?
    let onForwardFacingCamerasChange: ([String], Bool?) -> Void
    let onInterfaceOrientationChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.lockedOrientation = lockedOrientation
        view.onForwardFacingCamerasChange = onForwardFacingCamerasChange
        view.onInterfaceOrientationChange = onInterfaceOrientationChange
    }

    final class ObserverView: UIView {
        var lockedOrientation: UIInterfaceOrientation? {
            didSet {
                if let window { CameraOrientationDelegate.setOrientationLock(lockedOrientation, in: window) }
            }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if let window, window !== newWindow { CameraOrientationDelegate.setOrientationLock(nil, in: window) }
            super.willMove(toWindow: newWindow)
        }
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
            guard let window, let scene = window.windowScene else { return }
            CameraOrientationDelegate.setOrientationLock(lockedOrientation, in: window)
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
