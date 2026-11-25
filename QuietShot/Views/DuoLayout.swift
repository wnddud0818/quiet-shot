import AVFoundation
import SwiftUI
import UIKit

// iPhone Duo(폴더블) 전용 화면 구성 요소.
// 접는 선·안쪽 화면 카메라 구멍·바깥 화면 액세서리 API는 iOS 27.1 SDK(Xcode 27.1+)에만 있으므로
// DuoSupport.swift와 같은 조건으로 컴파일하고, 실행 시에도 #available(iOS 27.1, *)로 확인합니다.

/// nil은 힌지가 없는 기기, true는 닫힌 바깥 화면이다.
struct DuoHingeObserver: ViewModifier {
    @Binding var isClosed: Bool?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                let closed = context.hinge.map { $0.status == .closed }
                if isClosed != closed { isClosed = closed }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 접는 선(division)과 안쪽 화면 카메라(occlusion) 위치
struct DuoRegions: Equatable {
    /// 반쯤 접혔을 때의 접는 선 영역 (평평하게 펴져 있으면 nil)
    var fold: CGRect?
    /// 평평하게 펼쳐서 비활성인 접는 선도 안쪽 화면을 식별하는 데 사용한다.
    var hasDivision = false
    /// 켜져 있는 화면 아래 카메라 영역 (UI를 피해서 배치)
    var occlusions: [CGRect] = []

    static let none = DuoRegions(fold: nil, occlusions: [])

    static func read(_ proxy: GeometryProxy) -> DuoRegions {
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
        if #available(iOS 27.1, *) {
            let divisions = proxy.reservedRegions(kind: .division, options: .includeInactive)
            let fold = divisions.first(where: { $0.isActive }).flatMap { division in
                foldFrame(division.frame, in: proxy.size)
            }
            let occlusions = proxy.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map { $0.frame }
            return DuoRegions(fold: fold, hasDivision: !divisions.isEmpty, occlusions: occlusions)
        }
        #endif
        return .none
    }

    /// 두께가 0이어도 양쪽에 공간이 있으면 유효한 접는 선이다.
    static func foldFrame(_ region: CGRect, in size: CGSize) -> CGRect? {
        let frame = region.intersection(CGRect(origin: .zero, size: size))
        guard !frame.isNull else { return nil }
        let splitsView = frame.width >= frame.height
            ? frame.width > 0 && frame.minY > 0 && frame.maxY < size.height
            : frame.minX > 0 && frame.maxX < size.width
        return splitsView ? frame : nil
    }

    /// 카메라 구멍과 겹치지 않도록 화면 가장자리에서 띄울 여백
    func occlusionInsets(in size: CGSize) -> EdgeInsets {
        var insets = EdgeInsets()
        for frame in occlusions where !frame.isEmpty {
            if frame.midY < size.height * 0.3 {
                insets.top = max(insets.top, frame.maxY + 6)
            } else if frame.midY > size.height * 0.7 {
                insets.bottom = max(insets.bottom, size.height - frame.minY + 6)
            } else if frame.midX < size.width * 0.3 {
                insets.leading = max(insets.leading, frame.maxX + 6)
            } else if frame.midX > size.width * 0.7 {
                insets.trailing = max(insets.trailing, size.width - frame.minX + 6)
            }
        }
        return insets
    }

    /// 세로 조작 열과 실제로 겹치는 구멍만 위나 아래로 피한다.
    func railInsets(in rail: CGRect) -> EdgeInsets {
        var insets = EdgeInsets()
        for region in occlusions {
            let overlap = region.intersection(rail)
            guard !overlap.isEmpty else { continue }
            if overlap.midY < rail.midY {
                insets.top = max(insets.top, overlap.maxY - rail.minY + 6)
            } else {
                insets.bottom = max(insets.bottom, rail.maxY - overlap.minY + 6)
            }
        }
        return insets
    }
}

/// 펼쳐서 촬영할 때 바깥 화면에 실시간 미리보기 (찍히는 사람이 자기 모습을 볼 수 있게)
struct OuterDisplayAccessory: ViewModifier {
    @ObservedObject var camera: CameraController
    @Binding var isEnabled: Bool
    @Binding var isAvailable: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(AVKit.AVCaptureDeviceDirectionCoordinator)
        if #available(iOS 27.1, *) {
            content.sceneAccessory {
                CameraCaptureAccessory(isEnabled: $isEnabled) {
                    OuterDisplayPreview(camera: camera)
                }
                .onAvailabilityChange { available in
                    isAvailable = available
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 바깥 화면에 보이는 내용: 미리보기(후면 카메라는 거울처럼 좌우 반전) + 카운트다운 + 촬영 깜빡임
struct OuterDisplayPreview: View {
    @ObservedObject var camera: CameraController
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // 세션에 미리보기 레이어를 더 붙이지 않고, 본 화면과 같은 프레임을 그대로 받아 그림
            // (후면 카메라는 찍히는 사람이 거울처럼 볼 수 있게 좌우 반전)
            if let source = camera.previewSource {
                OuterFramePreview(camera: camera, source: source)
                    .id(source.id)
                    .transition(.identity)
                    .ignoresSafeArea()
            }
            if let countdown = camera.countdown {
                Text("\(countdown)")
                    .font(.system(size: 160, weight: .thin, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 14)
            }
            Color.white.opacity(flashOpacity).ignoresSafeArea()
            VStack {
                Spacer()
                Label(camera.isRecording ? "녹화 중" : "QuietShot",
                      systemImage: camera.isRecording ? "record.circle.fill" : (camera.captureMode == .video ? "video.fill" : "speaker.slash.fill"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(camera.isRecording ? Color.red : Color.black.opacity(0.5)))
                    .padding(.bottom, 18)
            }
        }
        .onChange(of: camera.captureTick) { _, _ in
            flashOpacity = 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.25)) { flashOpacity = 0 }
            }
        }
    }
}
