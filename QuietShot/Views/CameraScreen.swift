import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
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
    @State private var interfaceAngle: Double = 0

    // iPhone Duo
    @State private var outerPreviewEnabled = true
    @State private var outerPreviewAvailable = false

    /// 셀프 타이머 남은 초 (바깥 화면과 공유)
    private var countdown: Int? { camera.countdown }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
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
                    runningContent(geometry: geometry, landscape: landscape)
                }
            }
            .overlay(alignment: .top) { toastView }
        }
        .background {
            CameraWindowObserver(
                onForwardFacingCamerasChange: camera.updateForwardFacingCameras,
                onInterfaceOrientationChange: { interfaceAngle = Self.angle(for: $0) }
            )
            .allowsHitTesting(false)
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
            }
            updateLocationUpdates()
        }
        .onChange(of: camera.status) { _, _ in updateLocationUpdates() }
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
                CircleIconButton(systemName: "gearshape.fill") { showSettings = true }
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
    private func runningContent(geometry: GeometryProxy, landscape: Bool) -> some View {
        let size = geometry.size
        let regions = DuoRegions.read(geometry)
        let fold = regions.fold
        let innerDisplay = regions.hasDivision || outerPreviewAvailable
            || (horizontalSizeClass == .regular && verticalSizeClass == .regular)
        let persistentControls = fold != nil || innerDisplay
        let previewLandscape: Bool = {
            guard let fold else { return landscape }
            return fold.width >= fold.height ? size.width > fold.minY : fold.minX > size.height
        }()

        ZStack {
            if let fold {
                foldedLayout(fold: fold, size: size)
            } else if innerDisplay {
                innerDisplayLayout(landscape: landscape)
                    .padding(regions.occlusionInsets(in: size))
            } else if landscape {
                landscapeLayout
                    .padding(regions.occlusionInsets(in: size))
            } else {
                portraitLayout
                    .padding(regions.occlusionInsets(in: size))
            }
        }
        .modifier(OuterDisplayAccessory(camera: camera, isEnabled: $outerPreviewEnabled, isAvailable: $outerPreviewAvailable))
        .onAppear { camera.setInterfaceLandscape(previewLandscape) }
        .onChange(of: previewLandscape) { _, value in camera.setInterfaceLandscape(value) }
        .onChange(of: persistentControls, initial: true) { _, persistent in
            if persistent { drawerOpen = false }
        }
    }

    /// 반쯤 접힘(탁상·책 모드): 접는 선을 기준으로 한쪽은 미리보기, 다른 쪽은 조작부. 접는 선 위에는 아무것도 두지 않음
    @ViewBuilder
    private func foldedLayout(fold: CGRect, size: CGSize) -> some View {
        if fold.width >= fold.height {
            // 가로 접는 선(탁상 모드): 위 = 미리보기, 아래 = 조작부
            VStack(spacing: 0) {
                previewArea(landscape: size.width > fold.minY, persistentControls: true)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(fold.minY, 0))
                Color.clear.frame(height: fold.height)
                foldControls(horizontalFold: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(size.height - fold.maxY, 0))
            }
        } else {
            // 세로 접는 선(책 모드): 왼쪽 = 미리보기, 오른쪽 = 조작부
            HStack(spacing: 0) {
                previewArea(landscape: fold.minX > size.height, persistentControls: true)
                    .padding(.leading, 8)
                    .frame(maxHeight: .infinity)
                    .frame(width: max(fold.minX, 0))
                Color.clear.frame(width: fold.width)
                foldControls(horizontalFold: false)
                    .frame(maxHeight: .infinity)
                    .frame(width: max(size.width - fold.maxX, 0))
            }
        }
    }

    /// 접은 화면 아래쪽(또는 오른쪽) 조작부: 큰 셔터, 썸네일·전환, 항상 펼쳐진 빠른 설정
    private func foldControls(horizontalFold: Bool) -> some View {
        VStack(spacing: 14) {
            HStack {
                torchButton
                Spacer()
                Label(horizontalFold ? "탁상 모드" : "책 모드", systemImage: horizontalFold ? "laptopcomputer" : "book")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Spacer()
                statusPill(vertical: false, persistentControls: true)
            }
            Spacer(minLength: 0)
            bottomControls(vertical: false)
                .scaleEffect(1.12)
                .padding(.horizontal, 20)
            Spacer(minLength: 0)
            quickControls(vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// 펼친 안쪽 화면: 큰 미리보기 + 항상 보이는 빠른 설정 패널
    @ViewBuilder
    private func innerDisplayLayout(landscape: Bool) -> some View {
        if landscape {
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    torchButton
                    Spacer(minLength: 0)
                    quickControls(vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 20)
                .frame(width: 92)
                previewArea(landscape: true, persistentControls: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 14) {
                    statusPill(vertical: false, persistentControls: true)
                        .scaleEffect(0.9)
                    bottomControls(vertical: true)
                        .scaleEffect(1.1)
                }
                .padding(.vertical, 24)
                .frame(width: 150)
            }
        } else {
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    torchButton
                    Spacer()
                    quickControls(vertical: false)
                    Spacer()
                    statusPill(vertical: false, persistentControls: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                previewArea(landscape: false, persistentControls: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomControls(vertical: false)
                    .scaleEffect(1.1)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 18)
            }
        }
    }

    private func quickControls(vertical: Bool) -> some View {
        QuickControls(
            aspectRatio: $aspectRatio,
            captureTimer: $captureTimer,
            showGrid: $showGrid,
            saveFormat: $saveFormat,
            megapixelText: { camera.megapixelText(for: $0) },
            iconAngle: iconAngle,
            outerPreview: outerPreviewAvailable ? $outerPreviewEnabled : nil,
            vertical: vertical,
            onOpenSettings: { showSettings = true }
        )
    }

    private var iconAngle: Angle {
        var angle = orientation.iconRotation - interfaceAngle
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
            CircleIconButton(systemName: "gearshape.fill") { showSettings = true }
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
    private func statusPill(vertical: Bool, persistentControls: Bool = false) -> some View {
        Button {
            guard !persistentControls else { return }
            Haptics.selection()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { drawerOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.slash.fill")
                Text(camera.megapixelText(for: aspectRatio))
                    .monospacedDigit()
                if captureTimer != .off {
                    Image(systemName: "timer")
                    Text("\(captureTimer.rawValue)")
                        .monospacedDigit()
                }
                if !persistentControls {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(drawerOpen ? 180 : 0))
                }
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
        .accessibilityLabel("무음 촬영, \(camera.resolutionText(for: aspectRatio)). 빠른 설정")
    }

    // MARK: - 미리보기

    private func previewArea(landscape: Bool, persistentControls: Bool = false) -> some View {
        let ratio = landscape ? 1 / aspectRatio.portraitAspect : aspectRatio.portraitAspect
        return GeometryReader { proxy in
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
                        onPan: { handlePan($0, $1, persistentControls: persistentControls) },
                        onHardwareShutter: handleHardwareShutter
                    )
                    .id(source.id)
                    .transition(.identity)
                }
            }
            .overlay {
                if showGrid { GridOverlay().allowsHitTesting(false) }
            }
            .overlay {
                if let focus {
                    FocusOverlay(
                        mark: focus,
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
            .overlay(alignment: .top) { topOverlay(persistentControls: persistentControls) }
            .overlay(alignment: .bottom) { zoomOverlay }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: landscape ? 18 : 0, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: aspectRatio)
        .animation(.easeInOut(duration: 0.2), value: camera.isSwitchingCamera)
        .onChange(of: camera.captureTick) { _, _ in flashCapture() }
    }

    private func topOverlay(persistentControls: Bool) -> some View {
        VStack(spacing: 8) {
            if drawerOpen && !persistentControls {
                quickControls(vertical: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
        .padding(.top, 10)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: drawerOpen)
        .animation(.easeOut(duration: 0.2), value: camera.isFocusLocked)
    }

    @ViewBuilder
    private var zoomOverlay: some View {
        if !camera.isSystemControlFullscreen && countdown == nil {
            ZoomControl(
                configuration: camera.zoom,
                displayZoom: camera.displayZoom,
                iconAngle: iconAngle,
                onSelect: { camera.selectZoomPreset($0) },
                onContinuousZoom: { camera.setZoom(display: $0) }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
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
    private func bottomControls(vertical: Bool) -> some View {
        let thumbnail = thumbnailButton
            .rotationEffect(iconAngle)
        let shutter = ShutterButton(
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
        let flip = CircleIconButton(systemName: "arrow.triangle.2.circlepath", size: 52, action: flipCamera)
            .rotationEffect(.degrees(flipButtonAngle))
            .rotationEffect(iconAngle)
            .accessibilityLabel("전면/후면 전환")

        Group {
            if vertical {
                VStack {
                    flip
                    Spacer()
                    shutter
                    Spacer()
                    thumbnail
                }
            } else {
                HStack {
                    thumbnail
                    Spacer()
                    shutter
                    Spacer()
                    flip
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

    private func handleTap(_ layerPoint: CGPoint, _ devicePoint: CGPoint) {
        if drawerOpen {
            withAnimation { drawerOpen = false }
            return
        }
        camera.focus(at: devicePoint, lock: false)
        showFocus(at: layerPoint, locked: false)
    }

    private func handleLongPress(_ layerPoint: CGPoint, _ devicePoint: CGPoint) {
        Haptics.impact(.medium)
        camera.focus(at: devicePoint, lock: true)
        showFocus(at: layerPoint, locked: true)
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
    private func handlePan(_ state: UIGestureRecognizer.State, _ translation: CGSize, persistentControls: Bool) {
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
            if exposureDragStart == nil, !persistentControls, abs(translation.height) > abs(translation.width) {
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

    private func showFocus(at point: CGPoint, locked: Bool) {
        focusDimmed = false
        focus = FocusMark(point: point, locked: locked, id: (focus?.id ?? 0) + 1)
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
        guard !showSettings else { return }
        switch phase {
        case .began:
            hardwareHoldTask?.cancel()
            hardwareHoldTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, countdown == nil else { return }
                hardwareBurst = true
                Haptics.impact()
                camera.startBurst()
            }
        case .ended:
            hardwareHoldTask?.cancel()
            hardwareHoldTask = nil
            if hardwareBurst {
                hardwareBurst = false
                camera.stopBurst()
            } else {
                shutterTapped()
            }
        case .cancelled:
            hardwareHoldTask?.cancel()
            hardwareHoldTask = nil
            if hardwareBurst {
                hardwareBurst = false
                camera.stopBurst()
            }
        }
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
