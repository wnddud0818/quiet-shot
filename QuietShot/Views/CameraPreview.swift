import AVFoundation
import SwiftUI
import UIKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass를 지정했으므로 항상 성공
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// AVCaptureVideoPreviewLayer를 SwiftUI에 표시. 탭(초점)과 핀치(줌)는 UIKit 제스처로 처리.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayerReady: (AVCaptureVideoPreviewLayer) -> Void
    let onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    let onPinch: (_ state: UIGestureRecognizer.State, _ scale: CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pinch)

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

        init(parent: CameraPreview) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = recognizer.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            parent.onTap(point, devicePoint)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            parent.onPinch(recognizer.state, recognizer.scale)
        }
    }
}
