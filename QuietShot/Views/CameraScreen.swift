import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    var body: some View {
        GeometryReader { geometry in
            CameraContent(size: geometry.size, regions: DuoRegions.read(geometry),
                          trailingSafeAreaInset: geometry.safeAreaInsets.trailing)
        }
    }
}

private struct CameraContent: View {
    let size: CGSize
    let regions: DuoRegions
    let trailingSafeAreaInset: CGFloat
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
    @State private var outerCameraFacesView: Bool?
    @State private var showDuoSettings = false
    @State private var outerPreviewEnabled = true
    @State private var outerPreviewAvailable = false

    init(size: CGSize, regions: DuoRegions, trailingSafeAreaInset: CGFloat) {
        self.size = size
        self.regions = regions
        self.trailingSafeAreaInset = trailingSafeAreaInset
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

    @ViewBuilder
    private var runningContent: some View {
        let fold = regions.fold
        let previewLandscape: Bool = {
            guard !duoClosed, let fold else { return landscape }
            return fold.width >= fold.height ? size.width > fold.minY : fold.minX > size.height
        }()

        ZStack {
            if !duoClosed, let fold {
                foldedLayout(fold: fold, size: size)
            } else if duoClosed || innerDisplay {
                duoLayout
            } else if landscape {
                landscapeLayout
                    .padding(regions.occlusionInsets(in: size))
            } else {
                portraitLayout
                    .padding(regions.occlusionInsets(in: size))
            }
        }
        .accessibilityHidden(showDuoSettings)
        .overlay(alignment: .trailing) {
            duoSettingsPanel(regions: regions, size: size)
        }
        .modifier(OuterDisplayAccessory(camera: camera, isEnabled: $outerPreviewEnabled, isAvailable: $outerPreviewAvailable))
        .onAppear { camera.setInterfaceLandscape(previewLandscape) }
        .onChange(of: previewLandscape) { _, value in camera.setInterfaceLandscape(value) }
    }

    private var duoLayout: some View {
        let railWidth: CGFloat = 96
        let insets = regions.occlusionInsets(in: size)
        return ZStack {
            GeometryReader { viewport in
                let padding = landscape ? FramePreviewMath.trailingPadding(
                    viewport: viewport.size, aspect: previewAspect(landscape: true),
                    railWidth: railWidth, safeAreaInset: trailingSafeAreaInset + insets.trailing
                ) : 0
                previewArea(landscape: landscape, separateControls: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, padding)
            }
            .ignoresSafeArea(.container, edges: .horizontal)

            DuoCaptureControls(
                landscape: landscape, railWidth: railWidth,
                tools: duoTools, lenses: zoomControl, modes: modeSelector,
                shutter: shutter, gallery: galleryControl, flip: flipControl
            )
            .padding(insets)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    .frame(height: landscape ? 96 : 184)
                    .allowsHitTesting(false)
            }
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 68)
                    .allowsHitTesting(false)
            }
            .opacity(camera.isSystemControlFullscreen ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
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
    private func duoSettingsPanel(regions: DuoRegions, size: CGSize) -> some View {
        if showDuoSettings {
            let fold = regions.fold
            let verticalFold = fold.map { $0.width < $0.height } ?? false
            let width = verticalFold ? size.width - (fold?.maxX ?? 0) : size.width * 0.9
            let top = verticalFold ? 0 : fold?.maxY ?? 0
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.45)
                    .onTapGesture { showDuoSettings = false }
                SettingsView(camera: camera, onDone: { showDuoSettings = false })
                    .padding(regions.occlusionInsets(in: size))
                    .frame(width: min(360, width))
                    .padding(.top, top)
            }
            .accessibilityAddTraits(.isModal)
        }
    }

    private func openSettings() {
        cancelHardwareHold()
        drawerOpen = false
        if hingeClosed != nil { showDuoSettings = true } else { showSettings = true }
    }

    /// 접는 선을 넘지 않도록 미리보기와 셔터에 각각 독립된 영역을 준다.
    @ViewBuilder
    private func foldedLayout(fold: CGRect, size: CGSize) -> some View {
        if fold.width >= fold.height {
            let preview = CGRect(x: 0, y: 0, width: size.width, height: fold.minY)
            let controls = CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY)
            VStack(spacing: 0) {
                foldedPreview(in: preview)
                Color.clear.frame(height: fold.height)
                foldedControls(in: controls, landscape: false)
            }
        } else {
            let preview = CGRect(x: 0, y: 0, width: fold.minX, height: size.height)
            let controls = CGRect(x: fold.maxX, y: 0, width: size.width - fold.maxX, height: size.height)
            HStack(spacing: 0) {
                foldedPreview(in: preview)
                Color.clear.frame(width: fold.width)
                foldedControls(in: controls, landscape: true)
            }
        }
    }

    private func foldedPreview(in pane: CGRect) -> some View {
        let insets = regions.occlusionInsets(in: pane)
        return previewArea(landscape: pane.width > pane.height, separateControls: true)
            .frame(width: pane.width, height: pane.height)
            .overlay(alignment: .top) {
                duoTools
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(insets)
                    .opacity(camera.isSystemControlFullscreen ? 0 : 1)
            }
            .overlay(alignment: .bottom) {
                zoomControl
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .padding(insets)
            }
            .clipped()
    }

    private func foldedControls(in pane: CGRect, landscape: Bool) -> some View {
        let insets = regions.occlusionInsets(in: pane)
        // 좁은 책 모드에서는 모드 선택과 셔터가 겹치지 않게 하단 바를 쓴다.
        let sideRail = landscape && pane.width - insets.leading - insets.trailing >= 250
        return DuoCaptureControls(
            landscape: sideRail, railWidth: 96,
            tools: EmptyView(), lenses: EmptyView(), modes: modeSelector,
            shutter: shutter, gallery: galleryControl, flip: flipControl
        )
        .padding(insets)
        .frame(width: pane.width, height: pane.height)
        .clipped()
        .opacity(camera.isSystemControlFullscreen ? 0 : 1)
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

    private var iconAngle: Angle {
        // Duo의 조작부는 현재 창과 함께 회전한다. 기울기 센서는 촬영 방향에 계속 사용한다.
        if duoClosed || innerDisplay { return .zero }
        var angle = orientation.iconRotation - Self.angle(for: interfaceOrientation)
        if angle > 180 { angle -= 360 }
        if angle <= -180 { angle += 360 }
        return .degrees(angle)
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
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { drawerOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                if camera.captureMode == .video {
                    Image(systemName: "video.fill")
                    Text("동영상")
                } else {
                    Image(systemName: "speaker.slash.fill")
                    Text(camera.megapixelText(for: aspectRatio)).monospacedDigit()
                }
                if camera.captureMode == .photo, captureTimer != .off {
                    Image(systemName: "timer")
                    Text("\(captureTimer.rawValue)")
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(drawerOpen ? 180 : 0))
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
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
                .rotationEffect(iconAngle)
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
            case .starting: Text("녹화 준비 중")
            case .recording(let start):
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(start, style: .timer).fixedSize()
                    .accessibilityLabel("녹화 시간")
            case .finishing: Text("저장 중")
            case .idle: EmptyView()
            }
            if !camera.recordsAudio {
                Label("소리 없음", systemImage: "mic.slash.fill")
            }
        }
        .font(.caption.bold().monospacedDigit())
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
