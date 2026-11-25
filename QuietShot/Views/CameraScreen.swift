import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    var body: some View {
        GeometryReader { geometry in
            CameraContent(size: geometry.size, regions: DuoRegions.read(geometry),
                          safeInsets: geometry.safeAreaInsets)
        }
    }
}

private struct CameraContent: View {
    let size: CGSize
    let regions: DuoRegions
    let safeInsets: EdgeInsets
    @StateObject private var camera = CameraController()
    @StateObject private var orientation = DeviceOrientationMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @AppStorage(SettingsKey.showGrid) private var showGrid = false
    @AppStorage(SettingsKey.saveLocation) private var saveLocation = true
    @AppStorage(SettingsKey.aspectRatio) private var aspectRatio: AspectRatioOption = .fourThree
    @AppStorage(SettingsKey.captureTimer) private var captureTimer: CaptureTimer = .off
    @AppStorage(SettingsKey.saveFormat) private var saveFormat: SaveFormat = .heic

    @State private var showSettings = false
    @State private var drawerOpen = false

    @State private var focus: FocusMark?
    @State private var focusDimmed = false
    @State private var focusTask: Task<Void, Never>?
    @State private var exposureDragStart: Float?
    @State private var pinchStartFactor: CGFloat?

    @State private var flashOpacity: Double = 0
    @State private var flipButtonAngle: Double = 0
    @State private var thumbnailScale: CGFloat = 1
    @State private var countdownTask: Task<Void, Never>?
    @State private var hardwareHoldTask: Task<Void, Never>?
    @State private var hardwareBurst = false
    @State private var hardwarePressMode: CameraController.CaptureMode?
    @State private var interfaceOrientation: UIInterfaceOrientation = .unknown

    // iPhone Duo
    @State private var hingeReading: Bool?
    @State private var controlAnchor: DuoControlSpace.Anchor?
    @State private var outerCameraFacesView: Bool?
    @State private var showDuoSettings = false
    @State private var outerPreviewEnabled = true
    @State private var outerPreviewAvailable = false

    init(size: CGSize, regions: DuoRegions, safeInsets: EdgeInsets) {
        self.size = size
        self.regions = regions
        self.safeInsets = safeInsets
    }

    /// 셀프 타이머 남은 초 (바깥 화면과 공유)
    private var countdown: Int? { camera.countdown }

    private var hingeClosed: Bool? { hingeReading ?? outerCameraFacesView }
    private var duoClosed: Bool { hingeClosed == true }
    private var innerDisplay: Bool {
        hingeClosed == false || regions.hasDivision || outerPreviewAvailable
            || (horizontalSizeClass == .regular && verticalSizeClass == .regular)
    }
    private var landscape: Bool { size.width > size.height }
    private var hardwareShutterEnabled: Bool {
        scenePhase == .active && camera.status == .running && camera.previewSource != nil
            && !showSettings && !showDuoSettings && !camera.isChangingMode && !camera.isSwitchingCamera
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.status {
            case .idle:
                ProgressView().tint(.white)
            case .unauthorized:
                PermissionView()
            case .unavailable(let message):
                UnavailableView(message: message)
            case .running:
                runningContent
            }
        }
        .overlay(alignment: .top) { toastView }
        .background {
            CameraWindowObserver(
                shutterEnabled: hardwareShutterEnabled,
                onHardwareShutter: handleHardwareShutter,
                onForwardFacingCamerasChange: { ids, outer in
                    outerCameraFacesView = outer
                    camera.updateForwardFacingCameras(ids)
                },
                onInterfaceOrientationChange: { interfaceOrientation = $0 }
            )
        }
        .modifier(DuoHingeObserver(isClosed: $hingeReading))
        .onChange(of: hingeClosed) {
            drawerOpen = false
            showSettings = false
            showDuoSettings = false
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
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
                cancelCountdown()
                cancelHardwareHold()
                if phase == .background { camera.stopRecording() }
            }
            updateLocationUpdates()
        }
        .onChange(of: camera.status) { _, _ in updateLocationUpdates() }
        .onChange(of: hardwareShutterEnabled) { _, enabled in
            if !enabled { cancelHardwareHold() }
        }
        .onChange(of: camera.previewSource?.id) {
            cancelHardwareHold()
            focusTask?.cancel()
            focus = nil
        }
        .onDisappear { cancelHardwareHold() }
        .onChange(of: saveLocation) { _, _ in updateLocationUpdates() }
        .onChange(of: orientation.iconRotation) { _, rotation in
            camera.deviceIsLandscape = abs(rotation) == 90
        }
        .onChange(of: camera.isFocusLocked) { _, locked in
            if !locked, focus?.locked == true { focus = nil }
        }
        .onChange(of: camera.thumbnail) { _, _ in popThumbnail() }
        .onChange(of: camera.cameraLabel) { _, label in
            if label.contains("화면") { camera.toast = label }   // iPhone Duo 전면 카메라 전환 안내
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - 레이아웃

    /// 세로: 상단 바 / 미리보기 / 하단 셔터 바
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .frame(height: 52)
            previewArea(landscape: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomControls(vertical: false)
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
    }

    /// 가로(iPhone Duo 안쪽 화면 등): 왼쪽 도구 / 미리보기 / 오른쪽 셔터 열
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                torchButton
                Spacer()
                statusPill(vertical: true)
                Spacer()
                CircleIconButton(systemName: "gearshape.fill", action: openSettings)
                    .rotationEffect(iconAngle)
            }
            .padding(.vertical, 20)
            .frame(width: 76)
            previewArea(landscape: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomControls(vertical: true)
                .padding(.vertical, 24)
                .frame(width: 120)
        }
    }

    // MARK: - iPhone Duo 레이아웃

    private var usesFixedControls: Bool {
        hingeClosed != nil || regions.hasDivision || outerPreviewAvailable
    }

    private var sceneAngle: Double { Self.angle(for: interfaceOrientation) }

    private var safeBounds: CGRect {
        CGRect(origin: CGPoint(x: safeInsets.leading, y: safeInsets.top), size: size)
    }

    private var sceneSize: CGSize {
        CGSize(width: size.width + safeInsets.leading + safeInsets.trailing,
               height: size.height + safeInsets.top + safeInsets.bottom)
    }

    private var controlSpace: DuoControlSpace {
        let fixed = usesFixedControls
        let posture: DuoControlSpace.Posture
        if fixed {
            posture = duoClosed ? .closed : (regions.divisionActive ? .folded : .open)
        } else {
            posture = landscape ? .open : .closed
        }
        return DuoControlSpace(sceneSize: sceneSize, safeBounds: safeBounds, sceneDegrees: fixed ? sceneAngle : 0,
                               posture: posture,
                               sceneFold: regions.fold?.offsetBy(dx: safeBounds.minX, dy: safeBounds.minY),
                               previous: fixed ? controlAnchor : nil)
    }

    private var runningContent: some View {
        let space = controlSpace
        let previewPane = space.viewfinder.applying(space.fixedToScene)
        let previewLandscape = previewPane.width > previewPane.height
        return ZStack {
            if usesFixedControls || innerDisplay {
                duoLayout(space: space, previewLandscape: previewLandscape)
                    .position(x: sceneSize.width / 2 - safeBounds.minX, y: sceneSize.height / 2 - safeBounds.minY)
                    .frame(width: size.width, height: size.height)
            } else if landscape {
                landscapeLayout
                    .padding(regions.occlusionInsets(in: size))
            } else {
                portraitLayout
                    .padding(regions.occlusionInsets(in: size))
            }
        }
        .accessibilityHidden(showDuoSettings)
        .overlay(alignment: .trailing) { duoSettingsPanel(space: space) }
        .modifier(OuterDisplayAccessory(camera: camera, isEnabled: $outerPreviewEnabled, isAvailable: $outerPreviewAvailable))
        .onAppear { camera.setInterfaceLandscape(previewLandscape) }
        .onChange(of: previewLandscape) { _, value in camera.setInterfaceLandscape(value) }
        .onChange(of: usesFixedControls && interfaceOrientation != .unknown ? space.anchor : nil, initial: true) {
            _, anchor in controlAnchor = anchor
        }
    }

    private func duoLayout(space: DuoControlSpace, previewLandscape: Bool) -> some View {
        let railWidth: CGFloat = 96
        let inverse = space.fixedToScene.inverted()
        var fixedRegions = regions
        fixedRegions.occlusions = regions.occlusions.map {
            $0.offsetBy(dx: safeBounds.minX, dy: safeBounds.minY).applying(inverse)
        }
        let controls = space.controls
        let viewfinder = space.viewfinder
        let insets = fixedRegions.occlusionInsets(in: controls)
        var image = viewfinder
        if !space.split {
            image = CGRect(origin: .zero, size: space.size)
            if space.sideRail {
                let aspect = previewAspect(landscape: previewLandscape)
                let fixedAspect = abs(space.sceneDegrees) == 90 ? 1 / aspect : aspect
                image.size.width -= FramePreviewMath.trailingPadding(
                    viewport: image.size, aspect: fixedAspect, railWidth: railWidth,
                    safeAreaInset: image.maxX - controls.maxX + insets.trailing
                )
            }
        }
        let sceneImage = image.applying(space.fixedToScene)
        return ZStack(alignment: .topLeading) {
            // UIView의 레이어와 탭 좌표는 시스템 창과 같은 방향으로 둔다.
            previewArea(landscape: previewLandscape, separateControls: true)
                .frame(width: sceneImage.width, height: sceneImage.height)
                .position(x: sceneImage.midX, y: sceneImage.midY)

            ZStack(alignment: .topLeading) {
                if space.split {
                    Color.clear
                        .frame(width: viewfinder.width, height: viewfinder.height)
                        .allowsHitTesting(false)
                        .overlay(alignment: .top) {
                            duoTools.padding(.horizontal, 12).padding(.top, 8)
                                .padding(fixedRegions.occlusionInsets(in: viewfinder))
                        }
                        .overlay(alignment: .bottom) {
                            zoomControl.padding(8).padding(fixedRegions.occlusionInsets(in: viewfinder))
                        }
                        .clipped()
                        .position(x: viewfinder.midX, y: viewfinder.midY)
                }
                DuoCaptureControls(
                    landscape: space.sideRail, railWidth: railWidth,
                    tools: Group { if !space.split { duoTools } },
                    lenses: Group { if !space.split { zoomControl } }, modes: modeSelector,
                    shutter: shutter, gallery: galleryControl, flip: flipControl
                )
                .padding(insets)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        .frame(height: space.sideRail ? 96 : 184).allowsHitTesting(false)
                }
                .background(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 68).allowsHitTesting(false)
                }
                .frame(width: controls.width, height: controls.height)
                .clipped()
                .position(x: controls.midX, y: controls.midY)
            }
            .modifier(DuoControlPlacement(space: space))
            .opacity(camera.isSystemControlFullscreen ? 0 : 1)
        }
        .frame(width: sceneSize.width, height: sceneSize.height)
    }

    private var duoTools: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                torchButton
                Spacer(minLength: 0)
                captureStatus
                Spacer(minLength: 0)
                statusPill(vertical: false)
            }
            if drawerOpen { quickControls }
        }
    }

    @ViewBuilder
    private func duoSettingsPanel(space: DuoControlSpace) -> some View {
        if showDuoSettings {
            let pane = space.controls.applying(space.fixedToScene)
                .offsetBy(dx: -safeBounds.minX, dy: -safeBounds.minY)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.45)
                    .onTapGesture { showDuoSettings = false }
                SettingsView(camera: camera, onDone: { showDuoSettings = false })
                    .padding(regions.occlusionInsets(in: pane))
                    .frame(width: min(360, pane.width), height: pane.height)
                    .position(x: pane.maxX - min(360, pane.width) / 2, y: pane.midY)
            }
            .accessibilityAddTraits(.isModal)
        }
    }

    private func openSettings() {
        cancelHardwareHold()
        drawerOpen = false
        if usesFixedControls { showDuoSettings = true } else { showSettings = true }
    }

    private var quickControls: some View {
        QuickControls(
            camera: camera,
            aspectRatio: $aspectRatio,
            captureTimer: $captureTimer,
            showGrid: $showGrid,
            saveFormat: $saveFormat,
            iconAngle: iconAngle,
            outerPreview: outerPreviewAvailable ? $outerPreviewEnabled : nil,
            onOpenSettings: openSettings
        )
        .id(camera.captureMode)
    }

    /// 미리보기 안의 표시와 고정된 버튼은 서로 다른 좌표계에서 그린다.
    private var previewIconAngle: Angle { .degrees(orientation.iconRotation - sceneAngle) }
    private var iconAngle: Angle {
        if usesFixedControls {
            return .degrees(controlSpace.labelDegrees(for: orientation.iconRotation))
        }
        return innerDisplay ? .zero : previewIconAngle
    }

    // MARK: - 상단

    private var topBar: some View {
        HStack {
            torchButton
            Spacer()
            statusPill(vertical: false)
            Spacer()
            CircleIconButton(systemName: "gearshape.fill", action: openSettings)
                .rotationEffect(iconAngle)
                .accessibilityLabel("설정")
        }
        .opacity(camera.isSystemControlFullscreen ? 0 : 1)
    }

    @ViewBuilder
    private var torchButton: some View {
        if camera.torchAvailable {
            CircleIconButton(
                systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                size: duoClosed ? 44 : 40,
                tint: camera.torchOn ? .black : .white,
                background: camera.torchOn ? Theme.accent : Theme.chip
            ) {
                Haptics.selection()
                camera.toggleTorch()
            }
            .rotationEffect(iconAngle)
            .accessibilityLabel(camera.torchOn ? "손전등 끄기" : "손전등 켜기")
        } else {
            Color.clear.frame(width: 40, height: 40)
        }
    }

    /// 무음 표시 + 해상도 + 빠른 설정 열기
    private func statusPill(vertical: Bool) -> some View {
        let glyphAngle = usesFixedControls ? iconAngle : .zero
        return Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { drawerOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                if camera.captureMode == .video {
                    Image(systemName: "video.fill")
                        .rotationEffect(glyphAngle)
                    Text("동영상")
                        .rotationEffect(glyphAngle)
                } else {
                    Image(systemName: "speaker.slash.fill")
                        .rotationEffect(glyphAngle)
                    Text(camera.megapixelText(for: aspectRatio)).monospacedDigit().rotationEffect(glyphAngle)
                }
                if camera.captureMode == .photo, captureTimer != .off {
                    Image(systemName: "timer")
                        .rotationEffect(glyphAngle)
                    Text("\(captureTimer.rawValue)")
                        .monospacedDigit()
                        .rotationEffect(glyphAngle)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(glyphAngle.degrees + (drawerOpen ? 180 : 0)))
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(minHeight: usesFixedControls ? 32 : nil)
            .foregroundStyle(drawerOpen ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(drawerOpen ? Theme.accent : Theme.chip))
            .fixedSize()
            .rotationEffect(vertical ? .degrees(-90) : .zero)
            .frame(width: vertical ? 40 : nil, height: vertical ? 180 : nil)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(camera.captureMode == .video ? "동영상 빠른 설정" : "무음 촬영, \(camera.resolutionText(for: aspectRatio)). 빠른 설정")
    }

    // MARK: - 미리보기

    private func previewAspect(landscape: Bool) -> CGFloat {
        let frame = camera.previewFrameSize
        let movieAspect = frame.width > 0 && frame.height > 0 ? min(frame.width, frame.height) / max(frame.width, frame.height) : 9.0 / 16.0
        let portraitAspect = camera.captureMode == .video ? movieAspect : aspectRatio.portraitAspect
        return landscape ? 1 / portraitAspect : portraitAspect
    }

    private func previewArea(landscape: Bool, separateControls: Bool = false) -> some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let source = camera.previewSource {
                    CameraPreview(
                        camera: camera,
                        source: source,
                        bufferSize: camera.previewFrameSize,
                        onTap: handleTap,
                        onLongPress: handleLongPress,
                        onPinch: handlePinch,
                        onPan: handlePan
                    )
                    .id(source.id)
                    .transition(.identity)
                }
            }
            .overlay {
                if showGrid { GridOverlay().allowsHitTesting(false) }
            }
            .overlay {
                if let focus, let point = focusViewPoint(focus, in: proxy.size) {
                    FocusOverlay(
                        point: point,
                        locked: focus.locked,
                        iconAngle: usesFixedControls ? previewIconAngle : .zero,
                        exposureBias: camera.exposureBias,
                        dimmed: focusDimmed,
                        showSlider: exposureDragStart != nil,
                        containerSize: proxy.size
                    )
                    .id(focus.id)
                }
            }
            .overlay {
                // 카메라 전환 중 흐림
                if camera.isSwitchingCamera {
                    Rectangle().fill(.ultraThinMaterial).transition(.opacity)
                }
            }
            .overlay {
                // 무음이므로 화면 깜빡임으로 촬영 피드백
                Color.black.opacity(flashOpacity).allowsHitTesting(false)
            }
            .overlay { countdownView }
            .overlay(alignment: .top) {
                if !separateControls { topOverlay }
            }
            .overlay(alignment: .bottom) {
                if !separateControls {
                    zoomControl.padding(.horizontal, 24).padding(.bottom, 12)
                }
            }
        }
        .aspectRatio(previewAspect(landscape: landscape), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: landscape ? 18 : 0, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: aspectRatio)
        .animation(.easeInOut(duration: 0.2), value: camera.isSwitchingCamera)
        .onChange(of: camera.captureTick) { _, _ in flashCapture() }
    }

    private var topOverlay: some View {
        VStack(spacing: 8) {
            captureStatus
            if drawerOpen {
                quickControls
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: drawerOpen)
    }

    private var captureStatus: some View {
        VStack(spacing: 4) {
            if camera.captureMode == .video && (camera.recordingState != .idle || !camera.recordsAudio) {
                recordingBadge
            }
            if camera.isFocusLocked {
                Text("AE/AF 잠금")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accent))
                    .rotationEffect(usesFixedControls ? iconAngle : .zero)
                    .frame(minHeight: usesFixedControls ? 54 : nil)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: camera.isFocusLocked)
    }

    @ViewBuilder
    private var zoomControl: some View {
        if !camera.isSystemControlFullscreen && countdown == nil {
            ZoomControl(
                configuration: camera.zoom,
                displayZoom: camera.displayZoom,
                iconAngle: iconAngle,
                showsFixedZoom: duoClosed || innerDisplay || regions.fold != nil,
                onSelect: { camera.selectZoomPreset($0) },
                onContinuousZoom: { camera.setZoom(display: $0) }
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var countdownView: some View {
        if let countdown {
            Text("\(countdown)")
                .font(.system(size: 120, weight: .thin, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 12)
                .rotationEffect(usesFixedControls ? previewIconAngle : iconAngle)
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeOut(duration: 0.25), value: countdown)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 하단

    @ViewBuilder
    private var recordingBadge: some View {
        HStack(spacing: 6) {
            switch camera.recordingState {
            case .starting: Text("녹화 준비 중").rotationEffect(usesFixedControls ? iconAngle : .zero)
            case .recording(let start):
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(start, style: .timer).fixedSize()
                    .rotationEffect(usesFixedControls ? iconAngle : .zero)
                    .accessibilityLabel("녹화 시간")
            case .finishing: Text("저장 중").rotationEffect(usesFixedControls ? iconAngle : .zero)
            case .idle: EmptyView()
            }
            if !camera.recordsAudio {
                Label("소리 없음", systemImage: "mic.slash.fill")
                    .rotationEffect(usesFixedControls ? iconAngle : .zero)
            }
        }
        .font(.caption.bold().monospacedDigit())
        .frame(minHeight: usesFixedControls ? 60 : nil)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.glass))
    }

    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.photo, label: "사진")
            modeButton(.video, label: "동영상")
        }
        .background(Capsule().fill(Theme.chip))
        .disabled(camera.recordingState != .idle || camera.isChangingMode || camera.isSwitchingCamera || camera.isBursting || countdown != nil)
    }

    private func modeButton(_ mode: CameraController.CaptureMode, label: String) -> some View {
        let selected = camera.captureMode == mode
        return Button {
            cancelHardwareHold()
            camera.setCaptureMode(mode)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .fixedSize()
                .rotationEffect(iconAngle)
                .frame(width: 46, height: 44)
                .foregroundStyle(selected ? Color.black : .white)
                .background(Capsule().fill(selected ? Theme.accent : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var shutter: some View {
        if camera.captureMode == .video {
            Button(action: shutterTapped) {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4)
                    if camera.recordingState == .idle {
                        Circle().fill(.red).padding(7)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                    }
                }
                .frame(width: 78, height: 78)
            }
            .buttonStyle(PressableStyle())
            .disabled(camera.recordingState == .finishing || camera.isChangingMode || camera.isSwitchingCamera)
            .accessibilityLabel(camera.recordingState == .idle ? "녹화 시작" : "녹화 정지")
        } else {
            ShutterButton(
                isBursting: camera.isBursting,
                burstCount: camera.burstCount,
                iconAngle: usesFixedControls ? iconAngle : .zero,
                isCountingDown: countdown != nil,
                onTap: shutterTapped,
                onBurstStart: {
                    Haptics.impact()
                    camera.startBurst()
                },
                onBurstEnd: { camera.stopBurst() }
            )
            .disabled(camera.isChangingMode)
        }
    }

    private var galleryControl: some View { thumbnailButton.rotationEffect(iconAngle) }

    private var flipControl: some View {
        CircleIconButton(systemName: "arrow.triangle.2.circlepath", size: 52, action: flipCamera)
            .rotationEffect(.degrees(flipButtonAngle))
            .rotationEffect(iconAngle)
            .accessibilityLabel("전면/후면 전환")
            .disabled(camera.recordingState != .idle || camera.isChangingMode)
    }

    private func bottomControls(vertical: Bool) -> some View {
        Group {
            if vertical {
                VStack {
                    flipControl
                    Spacer(minLength: 0)
                    modeSelector
                    shutter
                    Spacer(minLength: 0)
                    galleryControl
                }
            } else {
                VStack(spacing: 8) {
                    modeSelector
                    HStack {
                        galleryControl
                        Spacer()
                        shutter
                        Spacer()
                        flipControl
                    }
                }
            }
        }
        .opacity(camera.isSystemControlFullscreen ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: camera.isSystemControlFullscreen)
    }

    private var thumbnailButton: some View {
        Button {
            // 사진 앱 열기
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.chip)
                if let thumbnail = camera.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            )
            .scaleEffect(thumbnailScale)
        }
        .buttonStyle(PressableStyle())
        .disabled(camera.recordingState != .idle)
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
                .padding(.top, 64)
                .padding(.horizontal, 24)
                .transition(.opacity)
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    camera.toast = nil
                }
        }
    }

    // MARK: - 제스처 처리

    private func focusViewPoint(_ mark: FocusMark, in size: CGSize) -> CGPoint? {
        guard let source = camera.previewSource, let angle = camera.mainPreviewRotationAngle,
              let transform = FramePreviewMath.deviceToViewTransform(
                viewSize: size, bufferSize: camera.previewFrameSize,
                rotationQuarters: FramePreviewMath.quarterTurns(angle - source.connectionAngle),
                mirrored: source.device.position == .front,
                connectionQuarters: FramePreviewMath.quarterTurns(source.connectionAngle)
              ) else { return nil }
        return mark.devicePoint.applying(transform)
    }

    private func handleTap(_ devicePoint: CGPoint) {
        if drawerOpen {
            withAnimation { drawerOpen = false }
            return
        }
        camera.focus(at: devicePoint, lock: false)
        showFocus(at: devicePoint, locked: false)
    }

    private func handleLongPress(_ devicePoint: CGPoint) {
        Haptics.impact(.medium)
        camera.focus(at: devicePoint, lock: true)
        showFocus(at: devicePoint, locked: true)
    }

    private func handlePinch(_ state: UIGestureRecognizer.State, _ scale: CGFloat) {
        switch state {
        case .began:
            pinchStartFactor = camera.zoomFactor
        case .changed:
            camera.setZoom(factor: (pinchStartFactor ?? camera.zoomFactor) * scale)
        default:
            pinchStartFactor = nil
        }
    }

    /// 초점 표시가 있으면 위아래 드래그 = 노출 보정, 없으면 위로 = 빠른 설정 열기 / 아래로 = 닫기
    private func handlePan(_ state: UIGestureRecognizer.State, _ translation: CGSize) {
        switch state {
        case .began:
            exposureDragStart = focus != nil ? camera.exposureBias : nil
            if exposureDragStart != nil {
                focusTask?.cancel()
                focusDimmed = false
            }
        case .changed:
            if let start = exposureDragStart {
                camera.setExposureBias(start - Float(translation.height / 110))
            }
        default:
            if exposureDragStart == nil, abs(translation.height) > abs(translation.width) {
                if translation.height < -40 {
                    withAnimation { drawerOpen = true }
                } else if translation.height > 40 {
                    withAnimation { drawerOpen = false }
                }
            }
            if exposureDragStart != nil {
                exposureDragStart = nil
                scheduleFocusFade()
            }
        }
    }

    private func showFocus(at devicePoint: CGPoint, locked: Bool) {
        focusDimmed = false
        focus = FocusMark(devicePoint: devicePoint, locked: locked, id: (focus?.id ?? 0) + 1)
        scheduleFocusFade()
    }

    /// 잠시 후 초점 표시를 흐리게(잠금) 또는 숨김(일반)
    private func scheduleFocusFade() {
        focusTask?.cancel()
        let id = focus?.id
        focusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled, focus?.id == id else { return }
            if focus?.locked == true {
                focusDimmed = true
            } else {
                withAnimation(.easeOut(duration: 0.3)) { focus = nil }
            }
        }
    }

    // MARK: - 셔터 / 타이머 / 하드웨어 버튼

    private func shutterTapped() {
        guard !camera.isChangingMode, !camera.isSwitchingCamera else { return }
        if camera.captureMode == .video {
            if camera.recordingState == .idle { camera.startRecording() } else { camera.stopRecording() }
            return
        }
        if countdownTask != nil {
            cancelCountdown()
            return
        }
        if captureTimer == .off {
            Haptics.impact()
            camera.capture()
        } else {
            startCountdown(seconds: captureTimer.rawValue)
        }
    }

    private func startCountdown(seconds: Int) {
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                camera.countdown = remaining
                Haptics.selection()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            camera.countdown = nil
            countdownTask = nil
            Haptics.impact()
            camera.capture()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        camera.countdown = nil
    }

    /// 볼륨 버튼 / 카메라 제어 버튼: 누르고 떼면 촬영, 길게 누르면 연속 촬영
    private func handleHardwareShutter(_ phase: HardwareShutterPhase) {
        guard hardwareShutterEnabled else {
            cancelHardwareHold()
            return
        }
        switch phase {
        case .began:
            cancelHardwareHold()
            hardwarePressMode = camera.captureMode
            guard camera.captureMode == .photo else { return }
            hardwareHoldTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, countdown == nil else { return }
                hardwareBurst = true
                Haptics.impact()
                camera.startBurst()
            }
        case .ended:
            let takeShot = hardwarePressMode == camera.captureMode && !hardwareBurst
            cancelHardwareHold()
            if takeShot { shutterTapped() }
        case .cancelled:
            cancelHardwareHold()
        }
    }

    private func cancelHardwareHold() {
        hardwarePressMode = nil
        hardwareHoldTask?.cancel()
        hardwareHoldTask = nil
        if hardwareBurst { camera.stopBurst() }
        hardwareBurst = false
    }

    // MARK: - 애니메이션

    private func flashCapture() {
        flashOpacity = 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.22)) { flashOpacity = 0 }
        }
    }

    private func popThumbnail() {
        thumbnailScale = 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { thumbnailScale = 1 }
        }
    }

    /// 전환 애니메이션은 버튼에만 적용해 회전 코디네이터의 기준 레이어를 고정한다.
    private func flipCamera() {
        guard !camera.isSwitchingCamera else { return }
        Haptics.selection()
        cancelCountdown()
        focus = nil
        withAnimation(.easeInOut(duration: 0.25)) { flipButtonAngle += 180 }
        camera.switchCamera()
    }

    // MARK: - Helpers

    /// GPS는 카메라가 화면에 떠 있고 위치 기록이 켜져 있을 때만 갱신 (카메라 권한 요청 뒤에 위치 권한 요청)
    private func updateLocationUpdates() {
        LocationProvider.shared.setEnabled(saveLocation && camera.status == .running && scenePhase == .active)
    }

    /// 인터페이스 방향을 기기 회전각(DeviceOrientationMonitor와 같은 기준)으로 변환
    static func angle(for orientation: UIInterfaceOrientation) -> Double {
        switch orientation {
        case .landscapeRight: return 90
        case .landscapeLeft: return -90
        case .portraitUpsideDown: return 180
        default: return 0
        }
    }
}
