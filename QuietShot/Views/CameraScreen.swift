import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var camera = CameraController()
    @StateObject private var orientation = DeviceOrientationMonitor()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKey.showGrid) private var showGrid = false
    @AppStorage(SettingsKey.hapticOnCapture) private var hapticOnCapture = false
    @AppStorage(SettingsKey.saveLocation) private var saveLocation = true
    @AppStorage(SettingsKey.aspectRatio) private var aspectRatio: AspectRatioOption = .fourThree

    @State private var showSettings = false
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var pinchStartZoom: CGFloat?
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .statusBarHidden()
        .onAppear {
            camera.start()
            orientation.start()
            updateLocationUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.start()
            } else {
                camera.stopBurst()
            }
            updateLocationUpdates()
        }
        .onChange(of: camera.status) { _, _ in
            updateLocationUpdates()
        }
        .onChange(of: saveLocation) { _, _ in
            updateLocationUpdates()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
                .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch camera.status {
        case .idle:
            ProgressView()
                .tint(.white)
        case .unauthorized:
            PermissionView()
        case .unavailable(let message):
            UnavailableView(message: message)
        case .running:
            cameraUI
        }
    }

    private var iconAngle: Angle {
        .degrees(orientation.iconRotation)
    }

    // MARK: - Layout

    private var cameraUI: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .frame(height: 52)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 4)
            zoomBar
                .frame(height: 48)
            bottomBar
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .animation(.easeInOut(duration: 0.25), value: orientation.iconRotation)
        .overlay(alignment: .top) { toastView }
    }

    private var topBar: some View {
        HStack {
            if camera.torchAvailable {
                CircleIconButton(
                    systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    tint: camera.torchOn ? .yellow : .white
                ) {
                    camera.toggleTorch()
                }
                .rotationEffect(iconAngle)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }

            aspectRatioMenu

            Spacer()

            Button {
                showSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.slash.fill")
                    Text(camera.megapixelText(for: aspectRatio))
                        .monospacedDigit()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("무음 촬영, \(camera.resolutionText(for: aspectRatio))")

            Spacer()

            Color.clear.frame(width: 52, height: 1)   // 왼쪽 비율 버튼과 균형

            CircleIconButton(systemName: "gearshape.fill") {
                showSettings = true
            }
            .rotationEffect(iconAngle)
        }
    }

    /// 촬영 비율 선택 메뉴 (4:3 / 3:2 / 16:9 / 1:1)
    private var aspectRatioMenu: some View {
        Menu {
            Picker("촬영 비율", selection: $aspectRatio) {
                ForEach(AspectRatioOption.allCases) { option in
                    Text("\(option.title)  ·  \(camera.megapixelText(for: option))").tag(option)
                }
            }
        } label: {
            Text(aspectRatio.title)
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 32)
                .padding(.horizontal, 4)
                .background(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1.2))
        }
        .rotationEffect(iconAngle)
        .accessibilityLabel("촬영 비율 \(aspectRatio.title)")
    }

    private var preview: some View {
        CameraPreview(
            session: camera.session,
            onLayerReady: { layer in
                camera.attach(previewLayer: layer)
            },
            onTap: { layerPoint, devicePoint in
                camera.focus(at: devicePoint)
                focusPoint = layerPoint
                focusToken += 1
            },
            onPinch: { state, scale in
                switch state {
                case .began:
                    pinchStartZoom = camera.zoomFactor
                case .changed:
                    camera.setZoom((pinchStartZoom ?? camera.zoomFactor) * scale)
                default:
                    pinchStartZoom = nil
                }
            }
        )
        .aspectRatio(aspectRatio.portraitAspect, contentMode: .fit)
        .animation(.easeInOut(duration: 0.2), value: aspectRatio)
        .overlay {
            if showGrid {
                GridOverlay().allowsHitTesting(false)
            }
        }
        .overlay {
            if let focusPoint {
                FocusSquare()
                    .id(focusToken)
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            Color.black
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
        .onChange(of: camera.captureTick) { _, _ in
            // 무음이므로 화면 깜빡임으로 촬영 피드백
            flashOpacity = 0.75
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.2)) {
                    flashOpacity = 0
                }
            }
        }
    }

    @ViewBuilder
    private var zoomBar: some View {
        if camera.position == .back && camera.lenses.count > 1 {
            HStack(spacing: 8) {
                ForEach(camera.lenses) { lens in
                    lensButton(lens)
                }
            }
            .padding(5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        } else if camera.zoomFactor > 1.01 {
            zoomLabel(LensOption.format(camera.displayZoom) + "×", selected: true)
                .onTapGesture { camera.setZoom(1) }
        } else {
            Color.clear
        }
    }

    private func lensButton(_ lens: LensOption) -> some View {
        let selected = lens.id == camera.activeLensID
        let title = selected ? LensOption.format(camera.displayZoom) + "×" : lens.label
        return Button {
            camera.selectLens(lens)
        } label: {
            zoomLabel(title, selected: selected)
        }
        .buttonStyle(.plain)
        .rotationEffect(iconAngle)
        .accessibilityLabel("\(lens.label)배 렌즈")
    }

    private func zoomLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: selected ? 13 : 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? Color.yellow : Color.white)
            .frame(width: selected ? 42 : 34, height: selected ? 42 : 34)
            .background(Circle().fill(Color.black.opacity(0.6)))
    }

    private var bottomBar: some View {
        HStack {
            thumbnailButton
                .rotationEffect(iconAngle)

            Spacer()

            ShutterButton(
                isBursting: camera.isBursting,
                burstCount: camera.burstCount,
                onTap: {
                    feedback()
                    camera.capture()
                },
                onBurstStart: {
                    feedback()
                    camera.startBurst()
                },
                onBurstEnd: {
                    camera.stopBurst()
                }
            )

            Spacer()

            CircleIconButton(systemName: "arrow.triangle.2.circlepath.camera", size: 54) {
                camera.switchCamera()
            }
            .rotationEffect(iconAngle)
            .accessibilityLabel("전면/후면 전환")
        }
    }

    private var thumbnailButton: some View {
        Button {
            // 사진 앱 열기
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.12))
                if let thumbnail = camera.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("사진 앱 열기")
    }

    @ViewBuilder
    private var toastView: some View {
        if let text = camera.toast {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(.top, 60)
                .padding(.horizontal, 24)
                .transition(.opacity)
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    camera.toast = nil
                }
        }
    }

    /// GPS는 카메라가 화면에 떠 있고 위치 기록이 켜져 있을 때만 갱신 (카메라 권한 요청 뒤에 위치 권한 요청)
    private func updateLocationUpdates() {
        LocationProvider.shared.setEnabled(saveLocation && camera.status == .running && scenePhase == .active)
    }

    private func feedback() {
        if hapticOnCapture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
