import AVFoundation
import CoreImage
import CoreLocation
import UIKit

/// 무음 카메라의 핵심: 세션 구성, 최대 해상도 포맷 선택, 무음 캡처.
///
/// 캡처 엔진은 두 가지이며 **어느 쪽이든 셔터음이 나지 않습니다.**
///
/// - `videoFrame` (기본, 모든 지역): 카메라 비디오 스트림(AVCaptureVideoDataOutput)의 프레임을
///   그대로 사진으로 저장합니다. 사진 촬영 API(AVCapturePhotoOutput)를 아예 세션에 넣지 않으므로
///   시스템 셔터음이 원천적으로 발생하지 않습니다. 한국·일본 판매 모델처럼 셔터음이 강제되는
///   기기에서도 무음이며, 기기가 스트림으로 제공하는 최대 해상도(대부분 4032×3024 = 12MP)로 저장합니다.
///
/// - `photoPipeline` (iOS 18+, 셔터음 억제가 허용된 기기에서만 자동 사용): 정식 사진 파이프라인에
///   `isShutterSoundSuppressionEnabled`를 적용해 센서 최대 해상도(예: 48MP)로 무음 촬영합니다.
///   억제가 허용되지 않는 기기에서는 이 엔진이 절대 선택되지 않습니다.
final class CameraController: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        case unauthorized
        case unavailable(String)
    }

    enum Engine: Equatable {
        case photoPipeline
        case videoFrame

        var title: String {
            switch self {
            case .photoPipeline: return "사진 파이프라인 + 셔터음 억제"
            case .videoFrame: return "비디오 프레임 캡처"
            }
        }
    }

    enum CaptureMode: Hashable { case photo, video }

    enum RecordingState: Equatable {
        case idle, starting, recording(Date), finishing
    }

    // MARK: - UI 상태 (메인 스레드에서만 변경)

    @Published private(set) var status: Status = .idle
    @Published private(set) var engine: Engine = .videoFrame
    @Published private(set) var captureMode: CaptureMode = .photo
    @Published private(set) var isChangingMode = false
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var recordsAudio = false
    @Published private(set) var movieQuality: MovieQuality?
    @Published private(set) var supportedMovieQualities: [MovieQuality] = []

    var canEditMovieSettings: Bool {
        captureMode == .video && status == .running && recordingState == .idle && !isChangingMode && !isSwitchingCamera
    }
    var microphonePermissionDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }
    @Published private(set) var outputDimensions = CMVideoDimensions(width: 0, height: 0)
    var position: AVCaptureDevice.Position { previewSource?.device.position ?? .back }
    @Published private(set) var zoom: ZoomConfiguration = .single
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var isFocusLocked = false
    @Published private(set) var isSwitchingCamera = false
    /// Camera Control(카메라 제어 버튼) 슬라이더가 전체 화면 오버레이로 떠 있는 동안 true
    @Published private(set) var isSystemControlFullscreen = false
    /// 예) "후면", "전면", "전면 · 바깥 화면" (iPhone Duo)
    @Published private(set) var cameraLabel = ""
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var captureTick = 0
    @Published private(set) var isBursting = false
    @Published private(set) var burstCount = 0
    @Published private(set) var shutterSuppressionSupported = false
    @Published var toast: String?
    /// 셀프 타이머 남은 초 (본 화면과 iPhone Duo 바깥 화면이 함께 표시)
    @Published var countdown: Int?
    struct PreviewSource: Identifiable {
        let device: AVCaptureDevice
        let connection: AVCaptureConnection
        let connectionAngle: CGFloat
        var id: ObjectIdentifier { ObjectIdentifier(connection) }
    }
    @Published private(set) var previewSource: PreviewSource?
    /// 본 화면의 초점 표시와 진단 정보에 사용하는 미리보기 회전각.
    @Published private(set) var mainPreviewRotationAngle: CGFloat?
    /// 미리보기로 들어오는 프레임 크기
    @Published private(set) var previewFrameSize = CGSize.zero
    /// 설정 > 진단 정보 (기기에서 문제를 추적할 때 사용)
    @Published private(set) var diagnostics: [String] = []

    /// 광각 기준 표시 배율 (예: 0.5×, 1×, 2.3×, 5×)
    var displayZoom: CGFloat { zoom.display(for: zoomFactor) }

    /// 기기를 가로로 들고 있는지 (정사각형 센서 프레임을 가로/세로 중 어느 쪽으로 자를지 결정)
    var deviceIsLandscape = false

    /// 선택한 촬영 비율로 크롭한 뒤 실제 저장되는 크기
    func savedDimensions(for aspect: AspectRatioOption) -> (width: Int, height: Int) {
        aspect.croppedSize(width: Int(outputDimensions.width), height: Int(outputDimensions.height))
    }

    func megapixelText(for aspect: AspectRatioOption) -> String {
        let size = savedDimensions(for: aspect)
        guard size.width > 0, size.height > 0 else { return "—" }
        return "\(Int((Double(size.width) * Double(size.height) / 1_000_000).rounded(.down)))MP"
    }

    func resolutionText(for aspect: AspectRatioOption) -> String {
        let size = savedDimensions(for: aspect)
        guard size.width > 0 else { return "—" }
        return "\(megapixelText(for: aspect)) · \(size.width)×\(size.height)"
    }

    // MARK: - 세션 (sessionQueue 전용)

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "quietshot.session")
    private let videoQueue = DispatchQueue(label: "quietshot.video", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "quietshot.processing", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var microphoneInput: AVCaptureDeviceInput?
    private var movieFormats: [MovieQuality: AVCaptureDevice.Format] = [:]
    private var activeMode: CaptureMode = .photo
    // sessionQueue owns a take until AVFoundation finishes writing its file.
    private struct MovieTake {
        let url: URL
        let date: Date
        let location: CLLocation?
        var didStart = false
        var stopRequested = false
    }
    private var movieTake: MovieTake?
    private var videoInput: AVCaptureDeviceInput?
    private var activeEngine: Engine = .videoFrame
    private var isConfigured = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var zoomOnQueue: ZoomConfiguration = .single
    private var deviceObservations: [NSKeyValueObservation] = []
    /// iPhone Duo: 지금 앱이 떠 있는 화면 쪽(사용자 쪽)을 향한 카메라들 (DirectionCoordinator 제공)
    private var forwardFacingCameraIDs: [String] = []
    private var controlsDelegateInstalled = false
    private var interfaceIsLandscapeOnQueue = false
    /// videoQueue 전용: 마지막으로 받은 프레임 크기, 지금 엔진, 카메라 전환 후 첫 프레임 대기
    private var lastFrameSize = CGSize.zero
    private var frameEngineOnVideoQueue = true
    private var awaitingFirstFrame = false
    private var activeVideoConnection: AVCaptureConnection?

    /// 미리보기 렌더러들 (본 화면 + iPhone Duo 바깥 화면). 프레임마다 그대로 보냄
    private let rendererLock = NSLock()
    private var previewRenderers: [ObjectIdentifier: (AVSampleBufferVideoRenderer, AVCaptureConnection)] = [:]

    // MARK: - 메인 스레드 전용

    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var burstTimer: Timer?
    private var movieBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - 캡처 파이프라인 (락으로 보호)

    private struct FrameRequest {
        let connection: AVCaptureConnection
        let rotationAngle: CGFloat
        let mirrored: Bool
        let format: SaveFormat
        let colorSpace: CGColorSpace
        let wideColor: Bool
        let position: AVCaptureDevice.Position
        let location: CLLocation?
        let heading: CLHeading?
        let aspect: AspectRatioOption
        let preferLandscape: Bool
    }

    private let frameLock = NSLock()
    private var pendingFrameRequests: [FrameRequest] = []

    private let slotLock = NSLock()
    private var inFlightCaptures = 0

    private let processorLock = NSLock()
    private var photoProcessors: [Int64: PhotoCaptureProcessor] = [:]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Lifecycle

    override init() {
        super.init()
        // Center Stage 자동 프레이밍이 줌을 임의로 바꾸지 않도록 앱이 직접 제어
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async {
                    if self.isConfigured && !self.session.isRunning {
                        self.session.startRunning()
                    }
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
                self?.stopRecording()
            }
        )
        notificationTokens.append(
            center.addObserver(forName: .AVCaptureDeviceSubjectAreaDidChange, object: nil, queue: nil) { [weak self] _ in
                self?.unlockFocus()
            }
        )
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 권한 확인 → 세션 구성 → 실행. 여러 번 호출해도 안전합니다.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureIfNeededAndRun()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.sessionQueue.async {
                        if granted {
                            self.configureIfNeededAndRun()
                        } else {
                            self.publish { $0.status = .unauthorized }
                        }
                    }
                }
            default:
                self.publish { $0.status = .unauthorized }
            }
        }
    }

    /// 설정 변경(엔진 강제 등) 후 현재 카메라로 재구성
    func reconfigure() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, let device = self.videoInput?.device else { return }
            self.configureSession(with: device)
        }
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, status == .running, !isChangingMode, !isSwitchingCamera,
              recordingState == .idle else { return }
        stopBurst()
        isChangingMode = true
        let configure = {
            self.sessionQueue.async {
                defer { self.publish { $0.isChangingMode = false } }
                guard let device = self.videoInput?.device else { return }
                let previousMode = self.activeMode
                if !self.configureSession(with: device, mode: mode),
                   self.configureSession(with: device, mode: previousMode) {
                    self.publish {
                        $0.status = .running
                        $0.toast = "촬영 모드를 전환하지 못했습니다."
                    }
                }
            }
        }
        requestMicrophoneIfNeeded(mode == .video && Self.prefersMicrophone, then: configure)
    }

    private static var prefersMicrophone: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.movieMicrophone) as? Bool ?? true
    }

    private func requestMicrophoneIfNeeded(_ enabled: Bool, then work: @escaping () -> Void) {
        if enabled, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in work() }
        } else {
            work()
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        guard canEditMovieSettings else { return }
        isChangingMode = true
        requestMicrophoneIfNeeded(enabled) {
            self.sessionQueue.async {
                defer { self.publish { $0.isChangingMode = false } }
                guard self.activeMode == .video, self.movieTake == nil else { return }
                UserDefaults.standard.set(enabled, forKey: SettingsKey.movieMicrophone)
                let hasAudio = self.refreshMovieMicrophone()
                if enabled && !hasAudio {
                    self.publish {
                        $0.toast = $0.microphonePermissionDenied ? "설정에서 마이크 접근을 허용해 주세요." : "마이크를 사용할 수 없습니다."
                    }
                }
            }
        }
    }

    /// sessionQueue의 구성 트랜잭션 안에서만 입력을 바꾼다. 끄면 MOV에 오디오 트랙이 생기지 않는다.
    private func configureMicrophoneInput(enabled: Bool) {
        if enabled {
            guard microphoneInput == nil, let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) else { return }
            session.addInput(input)
            microphoneInput = input
        } else if let input = microphoneInput {
            session.removeInput(input)
            microphoneInput = nil
        }
    }

    @discardableResult
    private func refreshMovieMicrophone() -> Bool {
        let enabled = Self.prefersMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if enabled != (microphoneInput != nil) {
            session.beginConfiguration()
            configureMicrophoneInput(enabled: enabled)
            session.commitConfiguration()
        }
        let hasAudio = movieOutput.connection(with: .audio)?.isEnabled == true
        publish { $0.recordsAudio = hasAudio }
        return hasAudio
    }

    func setMovieQuality(_ quality: MovieQuality) {
        guard canEditMovieSettings, supportedMovieQualities.contains(quality),
              let source = previewSource else { return }
        if movieQuality == quality {
            UserDefaults.standard.set(quality.rawValue, forKey: SettingsKey.movieQuality)
            return
        }
        isChangingMode = true
        sessionQueue.async {
            defer { self.publish { $0.isChangingMode = false } }
            guard self.activeMode == .video, self.movieTake == nil,
                  self.videoOutput.connection(with: .video) === source.connection,
                  let format = self.movieFormats[quality], let device = self.videoInput?.device else { return }

            self.session.beginConfiguration()
            do {
                try device.lockForConfiguration()
                let previousZoom = device.videoZoomFactor
                FormatSelector.applyMovieQuality(quality, format: format, to: device)
                device.videoZoomFactor = min(max(previousZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.unlockForConfiguration()
            } catch {
                self.session.commitConfiguration()
                self.publish { $0.toast = "동영상 화질을 변경하지 못했습니다." }
                return
            }
            self.configureVideoPixelFormat()
            self.configureSystemControls(for: device)
            self.session.commitConfiguration()
            let zoom = ZoomConfiguration.make(for: device)
            self.zoomOnQueue = zoom
            let zoomFactor = device.videoZoomFactor
            let active = FormatSelector.activeMovieQuality(of: device, among: Array(self.movieFormats.keys))
            let diagnostics = Self.diagnostics(for: device, captureMethod: "동영상 녹화", connectionAngle: source.connectionAngle)
            if active == quality { UserDefaults.standard.set(quality.rawValue, forKey: SettingsKey.movieQuality) }
            self.publish {
                $0.movieQuality = active
                $0.zoom = zoom
                $0.zoomFactor = zoomFactor
                $0.diagnostics = diagnostics
                if active != quality { $0.toast = "선택한 동영상 화질을 적용하지 못했습니다." }
            }
        }
    }

    // MARK: - 프레임 미리보기 렌더러

    func reportMainPreviewRotation(_ angle: CGFloat, for source: PreviewSource) {
        publish { controller in
            guard controller.previewSource?.id == source.id, controller.mainPreviewRotationAngle != angle else { return }
            controller.mainPreviewRotationAngle = angle
        }
    }

    func addPreviewRenderer(_ renderer: AVSampleBufferVideoRenderer, for connection: AVCaptureConnection) {
        rendererLock.lock()
        previewRenderers[ObjectIdentifier(renderer)] = (renderer, connection)
        rendererLock.unlock()
    }

    func removePreviewRenderer(_ renderer: AVSampleBufferVideoRenderer) {
        rendererLock.lock()
        previewRenderers[ObjectIdentifier(renderer)] = nil
        rendererLock.unlock()
    }

    /// 미리보기 렌더러들에 프레임 전달 (videoQueue)
    private func sendToPreviews(_ sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        rendererLock.lock()
        let renderers = Array(previewRenderers.values)
        rendererLock.unlock()
        guard !renderers.isEmpty else { return }
        CameraController.markDisplayImmediately(sampleBuffer)
        for (renderer, source) in renderers where source === connection {
            if renderer.status == .failed { renderer.flush() }
            guard renderer.isReadyForMoreMediaData else { continue }
            renderer.enqueue(sampleBuffer)
        }
    }

    /// 실시간 미리보기: 타임스탬프를 기다리지 않고 바로 표시
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    // MARK: - Session configuration

    private func configureIfNeededAndRun() {
        if !isConfigured {
            guard let device = CameraController.backDevice() ?? resolveFrontDevice() else {
                publish { $0.status = .unavailable("사용 가능한 카메라가 없습니다.\n시뮬레이터가 아닌 실제 iPhone에서 실행해 주세요.") }
                return
            }
            guard configureSession(with: device) else { return }
        } else if activeMode == .video, movieTake == nil {
            refreshMovieMicrophone()
        }
        if !session.isRunning {
            session.startRunning()
            if let device = videoInput?.device {
                applyDynamicAspectRatio(to: device)
            }
        }
        publish { $0.status = .running }
        PhotoLibrarySaver.requestAuthorizationIfNeeded()
    }

    @discardableResult
    private func configureSession(with device: AVCaptureDevice, mode requestedMode: CaptureMode? = nil) -> Bool {
        guard movieTake == nil else { return false }
        let mode = requestedMode ?? activeMode
        let forceFrameEngine = UserDefaults.standard.bool(forKey: SettingsKey.forceFrameEngine)
        dropPendingFrameRequests()

        isConfigured = false
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        microphoneInput = nil
        session.outputs.forEach { session.removeOutput($0) }

        // .photo 프리셋은 24MP/48MP 사진을 지원하는 유일한 프리셋
        if mode == .photo, session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            publish { $0.status = .unavailable("카메라 입력을 구성할 수 없습니다.") }
            return false
        }
        session.addInput(input)
        videoInput = input

        if mode == .video {
            let presets: [AVCaptureSession.Preset] = [.hd1920x1080, .high, .medium]
            if let preset = presets.first(where: { session.canSetSessionPreset($0) }) {
                session.sessionPreset = preset
            }
            configureMicrophoneInput(enabled: Self.prefersMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        }

        // 1) 엔진 결정: 셔터음 억제가 "허용된" 기기에서만 사진 파이프라인 사용
        var selectedEngine: Engine = .videoFrame
        var suppressionSupported = false
        if mode == .photo, session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            if #available(iOS 18.0, *) {
                suppressionSupported = photoOutput.isShutterSoundSuppressionSupported
            }
            if suppressionSupported && !forceFrameEngine {
                selectedEngine = .photoPipeline
            } else {
                // 셔터음이 날 수 있는 출력은 세션에서 완전히 제거
                session.removeOutput(photoOutput)
            }
        }

        // 비디오 데이터 출력: 두 엔진 모두 미리보기의 원본, 프레임 엔진에서는 사진의 원본
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            publish { $0.status = .unavailable("비디오 출력을 구성할 수 없습니다.") }
            return false
        }
        session.addOutput(videoOutput)
        if mode == .video {
            guard session.canAddOutput(movieOutput) else {
                session.commitConfiguration()
                let restored = configureSession(with: device, mode: .photo)
                publish { $0.toast = "이 카메라에서 동영상 출력을 구성할 수 없습니다." }
                return restored
            }
            session.addOutput(movieOutput)
        }
        session.automaticallyConfiguresCaptureDeviceForWideColor = selectedEngine == .photoPipeline
        movieFormats = mode == .video ? FormatSelector.movieFormats(for: device) : [:]
        let qualities = MovieQuality.allCases.filter { movieFormats[$0] != nil }
        let preferred = MovieQuality.preferred
        let selectedQuality = MovieQuality.bestMatch(in: qualities, resolution: preferred.resolution, fps: preferred.fps)

        // 2) 기기 설정 (프레임 엔진은 스트림 해상도가 가장 큰 포맷을 직접 지정)
        do {
            try device.lockForConfiguration()
            if let selectedQuality, let format = movieFormats[selectedQuality] {
                FormatSelector.applyMovieQuality(selectedQuality, format: format, to: device)
            }
            if mode == .photo, selectedEngine == .videoFrame, let format = FormatSelector.bestFrameFormat(for: device) {
                device.activeFormat = format
            }
            if mode == .photo, selectedEngine == .videoFrame, device.activeFormat.supportedColorSpaces.contains(.P3_D65) {
                device.activeColorSpace = .P3_D65
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
        } catch {
            // 잠금 실패 시 세션 기본 포맷으로 동작
        }

        // 카메라 제어 버튼(iPhone 16 이상)에 시스템 줌/노출 슬라이더 연결
        configureSystemControls(for: device)

        // 3) 비디오 출력 설정 (사진 출력은 프리셋이 확정된 뒤 아래에서 설정)
        do {
            configureVideoPixelFormat()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off   // 안정화 크롭 없이 전체 화각
                }
            }
        }

        session.commitConfiguration()

        activeEngine = selectedEngine
        activeMode = mode

        if selectedEngine == .photoPipeline {
            // .photo 프리셋이 적용된 activeFormat 기준으로 최대 사진 해상도(예: 48MP) 지정
            session.beginConfiguration()
            if let maxDimensions = FormatSelector.maxPhotoDimensions(of: device.activeFormat) {
                photoOutput.maxPhotoDimensions = maxDimensions
            }
            photoOutput.maxPhotoQualityPrioritization = .quality
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
            // 세로로 장착된 정사각형 전면 센서(iPhone 17/Duo): RotationCoordinator 각도를 쓰므로 보정은 끔
            if #available(iOS 26.0, *), photoOutput.isCameraSensorOrientationCompensationSupported {
                photoOutput.isCameraSensorOrientationCompensationEnabled = false
            }
            session.commitConfiguration()
            preparePhotoPipeline()
        }

        let dimensions: CMVideoDimensions = selectedEngine == .photoPipeline
            ? photoOutput.maxPhotoDimensions
            : FormatSelector.videoDimensions(of: device.activeFormat)

        // 줌: 후면은 1×(광각), 전면은 마지막으로 고른 넓게/표준
        let zoomConfig = ZoomConfiguration.make(for: device)
        zoomOnQueue = zoomConfig
        var initialZoom = zoomConfig.defaultFactor
        if device.position == .front, UserDefaults.standard.bool(forKey: SettingsKey.frontWideFraming) {
            initialZoom = zoomConfig.minFactor
        }
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = min(max(initialZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        }
        observe(device)
        applyDynamicAspectRatio(to: device)
        let isFrameEngine = selectedEngine == .videoFrame
        guard let connection = videoOutput.connection(with: .video) else {
            publish { $0.status = .unavailable("미리보기 연결을 구성할 수 없습니다.") }
            return false
        }
        let connectionAngle = connection.videoRotationAngle
        isConfigured = true
        let source = PreviewSource(device: device, connection: connection, connectionAngle: connectionAngle)
        let captureMethod = mode == .video ? "동영상 녹화" : selectedEngine.title
        let diagnostics = CameraController.diagnostics(for: device, captureMethod: captureMethod, connectionAngle: connectionAngle)
        // 새 카메라 프레임이 오지 않는 경우를 대비해 전환 가림막은 잠시 후 자동 해제
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.previewSource?.connection === connection { self?.isSwitchingCamera = false }
        }

        let torchAvailable = device.hasTorch && device.isTorchAvailable
        let label = CameraController.label(for: device)
        let zoomNow = device.videoZoomFactor
        let biasNow = device.exposureTargetBias
        let hasAudio = mode == .video && movieOutput.connection(with: .audio)?.isEnabled == true
        let activeQuality = FormatSelector.activeMovieQuality(of: device, among: qualities)

        publish { controller in
            controller.captureMode = mode
            controller.recordsAudio = hasAudio
            controller.supportedMovieQualities = qualities
            controller.movieQuality = activeQuality
            controller.engine = selectedEngine
            controller.shutterSuppressionSupported = suppressionSupported
            controller.outputDimensions = dimensions
            controller.captureRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            controller.mainPreviewRotationAngle = nil
            controller.previewFrameSize = .zero
            controller.previewSource = source
            controller.zoom = zoomConfig
            controller.zoomFactor = zoomNow
            controller.exposureBias = biasNow
            controller.isFocusLocked = false
            controller.torchAvailable = torchAvailable
            controller.torchOn = false
            controller.cameraLabel = label
            controller.diagnostics = diagnostics
        }
        videoQueue.async {
            self.activeVideoConnection = connection
            self.lastFrameSize = .zero
            self.frameEngineOnVideoQueue = isFrameEngine
            self.awaitingFirstFrame = true
        }
        return true
    }

    private func configureVideoPixelFormat() {
        let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        videoOutput.videoSettings = videoOutput.availableVideoPixelFormatTypes.contains(fullRange)
            ? [kCVPixelBufferPixelFormatTypeKey as String: fullRange] : [:]
    }

    /// 첫 촬영 지연을 줄이기 위해 최대 해상도 촬영 리소스를 미리 준비
    private func preparePhotoPipeline() {
        let (settings, _) = makePhotoSettings(format: CaptureOptions.current().saveFormat, fast: false)
        photoOutput.setPreparedPhotoSettingsArray([settings], completionHandler: nil)
    }

    /// - Returns: 촬영 설정과 실제로 저장될 파일 형식(HEVC 미지원 시 JPEG)
    private func makePhotoSettings(format: SaveFormat, fast: Bool) -> (AVCapturePhotoSettings, SaveFormat) {
        let useHEVC = format == .heic && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = fast ? .speed : .quality
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        return (settings, useHEVC ? .heic : .jpeg)
    }

    // MARK: - Devices

    /// 후면: 멀티 렌즈 가상 카메라(렌즈 경계 없이 매끄러운 줌) → 없으면 광각
    static func backDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// 전면 카메라 후보 (우선순위 순)
    /// - iPhone Duo: 바깥/안쪽 화면 개별 카메라 (가상 전면 카메라는 1080p 제한이라 사용하지 않음)
    /// - iPhone 17 이후: 정사각형 센서 Center Stage 카메라 (.builtInUltraWideCamera)
    /// - 그 외: 기존 전면 광각 카메라
    static func frontCandidates() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = DuoSupport.frontCameraTypes + [.builtInUltraWideCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .front).devices
        let duo = devices.filter { DuoSupport.isDuoFrontCamera($0.deviceType) }
        if !duo.isEmpty { return duo }
        return types.compactMap { type in devices.first(where: { $0.deviceType == type }) }
    }

    /// 사용자 쪽을 향한 전면 카메라 (iPhone Duo는 접힘/펼침에 따라 바깥/안쪽 화면 카메라)
    private func resolveFrontDevice() -> AVCaptureDevice? {
        let candidates = CameraController.frontCandidates()
        if let facing = candidates.first(where: { forwardFacingCameraIDs.contains($0.uniqueID) }) {
            return facing
        }
        return candidates.first
    }

    static func label(for device: AVCaptureDevice) -> String {
        guard device.position == .front else { return "후면" }
        return DuoSupport.label(for: device.deviceType) ?? "전면"
    }

    /// iPhone Duo: 화면이 접히거나 펼쳐져 사용자를 향한 카메라가 바뀌면 호출 (메인 스레드)
    func updateForwardFacingCameras(_ ids: [String]) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.forwardFacingCameraIDs = ids
            self.updateFrontCameraIfNeeded()
        }
    }

    private func updateFrontCameraIfNeeded() {
        guard isConfigured, let current = videoInput?.device, current.position == .front,
              let facing = CameraController.frontCandidates().first(where: { forwardFacingCameraIDs.contains($0.uniqueID) }),
              facing.uniqueID != current.uniqueID else { return }
        if movieTake != nil {
            // 접힘으로 전면 카메라가 바뀌면 파일을 먼저 닫고 완료 콜백에서 전환한다.
            publish { $0.stopRecording() }
            return
        }
        publish { $0.isSwitchingCamera = true }
        configureSession(with: facing)
    }

    func switchCamera() {
        guard recordingState == .idle, !isChangingMode else { return }
        stopBurst()
        isSwitchingCamera = true
        sessionQueue.async { [weak self] in
            guard let self, let current = self.videoInput?.device else { return }
            let next = current.position == .front ? CameraController.backDevice() : self.resolveFrontDevice()
            guard let next else {
                self.publish { $0.isSwitchingCamera = false }
                return
            }
            self.configureSession(with: next)
        }
    }

    /// 정사각형 센서(iPhone 17·Duo 전면 Center Stage 카메라): 화면 방향과 같은 비율로 출력
    /// (세로 화면 3:4, 가로 화면 4:3). Apple 예제처럼 구성이 끝난 뒤 별도의 잠금 블록에서 설정합니다.
    private func applyDynamicAspectRatio(to device: AVCaptureDevice) {
        guard #available(iOS 26.0, *), activeMode == .photo else { return }
        let supported = device.activeFormat.supportedDynamicAspectRatios
        guard !supported.isEmpty else { return }
        let landscape = interfaceIsLandscapeOnQueue
        if landscape, supported.contains(.ratio4x3), device.dynamicAspectRatio != .ratio4x3 {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.setDynamicAspectRatio(.ratio4x3, completionHandler: nil)
            device.unlockForConfiguration()
        } else if !landscape, supported.contains(.ratio3x4), device.dynamicAspectRatio != .ratio3x4 {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.setDynamicAspectRatio(.ratio3x4, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    /// 앱 화면이 가로인지 (iPhone Duo 안쪽 화면 등). 정사각형 센서의 출력 비율에 반영 (메인 스레드)
    func setInterfaceLandscape(_ landscape: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.interfaceIsLandscapeOnQueue != landscape else { return }
            self.interfaceIsLandscapeOnQueue = landscape
            if let device = self.videoInput?.device {
                self.applyDynamicAspectRatio(to: device)
            }
        }
    }

    /// 줌 배율·노출 보정 변화를 UI에 반영 (버튼, 다이얼, 핀치, 카메라 제어 버튼 등 모든 경로)
    private func observe(_ device: AVCaptureDevice) {
        deviceObservations = [
            device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
                let factor = device.videoZoomFactor
                self?.publish { $0.zoomFactor = factor }
            },
            device.observe(\.exposureTargetBias, options: [.new]) { [weak self] device, _ in
                let bias = device.exposureTargetBias
                self?.publish { $0.exposureBias = bias }
            },
        ]
    }

    private func configureSystemControls(for device: AVCaptureDevice) {
        guard #available(iOS 18.0, *), session.supportsControls else { return }
        if !controlsDelegateInstalled {
            session.setControlsDelegate(self, queue: sessionQueue)
            controlsDelegateInstalled = true
        }
        session.controls.forEach { session.removeControl($0) }
        var controls: [AVCaptureControl] = []
        // 줌이 안 되는 카메라(예: 화면 아래 카메라)에 슬라이더를 만들면 예외가 나므로 확인 후 추가
        if device.maxAvailableVideoZoomFactor > device.minAvailableVideoZoomFactor + 0.01 {
            controls.append(AVCaptureSystemZoomSlider(device: device))
        }
        if device.maxExposureTargetBias > device.minExposureTargetBias {
            controls.append(AVCaptureSystemExposureBiasSlider(device: device))
        }
        for control in controls where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    // MARK: - Zoom / Focus / Exposure / Torch

    /// videoZoomFactor 기준. animated면 렌즈 전환처럼 부드럽게 램프
    func setZoom(factor: CGFloat, animated: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let config = self.zoomOnQueue
            let clamped = min(max(factor, config.minFactor), config.maxFactor)
            guard (try? device.lockForConfiguration()) != nil else { return }
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 6)
            } else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        }
    }

    /// 화면 표시 배율 기준 (예: 2.5×)
    func setZoom(display: CGFloat, animated: Bool = false) {
        setZoom(factor: zoom.factor(forDisplay: display), animated: animated)
    }

    func selectZoomPreset(_ preset: ZoomPreset) {
        if position == .front {
            UserDefaults.standard.set(preset.factor <= zoom.minFactor + 0.01, forKey: SettingsKey.frontWideFraming)
        }
        setZoom(factor: preset.factor, animated: true)
    }

    /// 탭: 해당 지점에 초점/노출 (장면이 바뀌면 자동 해제)
    /// 길게 누르기(lock): AE/AF 잠금 (다시 탭할 때까지 유지)
    func focus(at devicePoint: CGPoint, lock: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.isSubjectAreaChangeMonitoringEnabled = !lock
            device.unlockForConfiguration()
            self.publish { $0.isFocusLocked = lock }
        }
    }

    /// 노출 보정(EV). iPhone 기본 카메라처럼 ±2EV 범위
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device else { return }
            let lower = max(device.minExposureTargetBias, -2)
            let upper = min(device.maxExposureTargetBias, 2)
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(min(max(bias, lower), upper), completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    /// 중앙 연속 AF/AE로 복귀 (AE/AF 잠금 해제)
    func unlockFocus() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let center = CGPoint(x: 0.5, y: 0.5)
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = center
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = center
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
            self.publish { $0.isFocusLocked = false }
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.videoInput?.device,
                  device.hasTorch, device.isTorchAvailable else { return }
            let turnOn = device.torchMode != .on
            let mode: AVCaptureDevice.TorchMode = turnOn ? .on : .off
            guard device.isTorchModeSupported(mode) else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = mode
                device.unlockForConfiguration()
            } catch {
                return
            }
            self.publish { $0.torchOn = turnOn }
        }
    }

    // MARK: - Capture (메인 스레드에서 호출)

    func capture() {
        capture(isBurst: false)
    }

    /// 길게 누르는 동안 연속 촬영
    func startBurst() {
        guard burstTimer == nil, status == .running, captureMode == .photo, !isChangingMode else { return }
        burstCount = 0
        isBursting = true
        let interval: TimeInterval = engine == .photoPipeline ? 0.2 : 0.1
        capture(isBurst: true)
        burstTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.capture(isBurst: true)
        }
    }

    func stopBurst() {
        burstTimer?.invalidate()
        burstTimer = nil
        isBursting = false
    }

    private func capture(isBurst: Bool) {
        guard status == .running, captureMode == .photo, !isChangingMode, !isSwitchingCamera, let source = previewSource,
              let captureRotationCoordinator else { return }
        // 처리 대기 중인 촬영이 너무 많으면(메모리 보호) 연사 프레임은 건너뜀
        guard reserveSlot(limit: isBurst ? 3 : 8) else { return }

        let angle = captureRotationCoordinator.videoRotationAngleForHorizonLevelCapture
        let options = CaptureOptions.current()
        let place = options.saveLocation ? LocationProvider.shared.snapshot() : .empty
        let landscape = deviceIsLandscape
        if isBurst { burstCount += 1 }
        captureTick += 1

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.videoInput?.device,
                  self.videoOutput.connection(with: .video) === source.connection else {
                self.releaseSlot()
                return
            }
            let mirrored = options.mirrorFrontCamera && device.position == .front

            switch self.activeEngine {
            case .photoPipeline:
                self.capturePhotoSilently(angle: angle, mirrored: mirrored, format: options.saveFormat,
                                          fast: isBurst, place: place, position: device.position,
                                          aspect: options.aspectRatio)
            case .videoFrame:
                let wideColor = device.activeColorSpace == .P3_D65
                let colorSpaceName = wideColor ? CGColorSpace.displayP3 : CGColorSpace.sRGB
                let colorSpace = CGColorSpace(name: colorSpaceName) ?? CGColorSpaceCreateDeviceRGB()
                let request = FrameRequest(connection: source.connection, rotationAngle: angle, mirrored: mirrored, format: options.saveFormat,
                                           colorSpace: colorSpace, wideColor: wideColor, position: device.position,
                                           location: place.location, heading: place.heading,
                                           aspect: options.aspectRatio, preferLandscape: landscape)
                self.frameLock.lock()
                self.pendingFrameRequests.append(request)
                self.frameLock.unlock()
            }
        }
    }

    /// 사진 파이프라인 촬영 (sessionQueue). 셔터음 억제가 불가능하면 절대 촬영하지 않음.
    private func capturePhotoSilently(angle: CGFloat,
                                      mirrored: Bool,
                                      format: SaveFormat,
                                      fast: Bool,
                                      place: LocationProvider.Snapshot,
                                      position: AVCaptureDevice.Position,
                                      aspect: AspectRatioOption) {
        guard #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported else {
            // 안전장치: 억제가 불가능해졌다면 프레임 엔진으로 전환하고 이번 촬영은 취소
            releaseSlot()
            if let device = videoInput?.device {
                configureSession(with: device)
            }
            return
        }

        let (settings, savedFormat) = makePhotoSettings(format: format, fast: fast)
        guard settings.isShutterSoundSuppressionEnabled else {
            releaseSlot()
            return
        }

        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirrored != mirrored {
                    connection.isVideoMirrored = mirrored
                }
            }
        }

        let uniqueID = settings.uniqueID
        let captureDate = Date()
        let location = place.location
        let gps = location.map {
            MetadataBuilder.gpsDictionary(location: $0, heading: place.heading, position: position)
        }
        let processor = PhotoCaptureProcessor(uniqueID: uniqueID, gps: gps) { [weak self] data, error in
            self?.handleCapturedPhoto(uniqueID: uniqueID, data: data, error: error, format: savedFormat,
                                      aspect: aspect, location: location, date: captureDate)
        }
        processorLock.lock()
        photoProcessors[uniqueID] = processor
        processorLock.unlock()

        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    private func handleCapturedPhoto(uniqueID: Int64,
                                     data: Data?,
                                     error: Error?,
                                     format: SaveFormat,
                                     aspect: AspectRatioOption,
                                     location: CLLocation?,
                                     date: Date) {
        processorLock.lock()
        photoProcessors[uniqueID] = nil
        processorLock.unlock()

        guard let data, error == nil else {
            releaseSlot()
            publish { $0.toast = "촬영에 실패했습니다." }
            return
        }
        processingQueue.async { [weak self] in
            // 4:3 이외의 비율은 중앙 크롭 후 메타데이터를 유지한 채 다시 인코딩 (4:3은 Apple 원본 그대로)
            var output = data
            var outputFormat = format
            if let cropped = ImageEncoder.cropped(data, to: aspect, preferred: format) {
                output = cropped.data
                outputFormat = cropped.format
            }
            let thumbnail = ImageEncoder.thumbnail(from: output)
            self?.saveToLibrary(output, format: outputFormat, thumbnail: thumbnail, location: location, date: date)
        }
    }

    private func saveToLibrary(_ data: Data,
                               format: SaveFormat,
                               thumbnail: UIImage?,
                               location: CLLocation?,
                               date: Date) {
        PhotoLibrarySaver.save(data, format: format, location: location, creationDate: date) { [weak self] error in
            guard let self else { return }
            self.releaseSlot()
            self.publish { controller in
                if let error {
                    controller.toast = error.localizedDescription
                } else if let thumbnail {
                    controller.thumbnail = thumbnail
                }
            }
        }
    }

    // MARK: - Slot / Helpers

    private func reserveSlot(limit: Int) -> Bool {
        slotLock.lock()
        defer { slotLock.unlock() }
        guard inFlightCaptures < limit else { return false }
        inFlightCaptures += 1
        return true
    }

    private func releaseSlot() {
        slotLock.lock()
        inFlightCaptures = max(0, inFlightCaptures - 1)
        slotLock.unlock()
    }

    private func dropPendingFrameRequests() {
        frameLock.lock()
        let dropped = pendingFrameRequests.count
        pendingFrameRequests.removeAll()
        frameLock.unlock()
        for _ in 0..<dropped {
            releaseSlot()
        }
    }

    private func publish(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async {
            update(self)
        }
    }

    private static func diagnostics(for device: AVCaptureDevice, captureMethod: String, connectionAngle: CGFloat) -> [String] {
        let format = FormatSelector.videoDimensions(of: device.activeFormat)
        var lines = [
            "기기: \(DeviceInfo.modelIdentifier) · iOS \(DeviceInfo.systemVersion)",
            "카메라: \(device.localizedName) (\(device.deviceType.rawValue))",
            "엔진: \(captureMethod)",
            "포맷: \(format.width)×\(format.height)",
            "출력 회전: \(Int(connectionAngle))°",
        ]
        if #available(iOS 26.0, *) {
            let supported = device.activeFormat.supportedDynamicAspectRatios.map { $0.rawValue }
            if !supported.isEmpty {
                lines.append("동적 비율: \(device.dynamicAspectRatio?.rawValue ?? "-") / 지원 \(supported.joined(separator: ", "))")
            }
        }
        return lines
    }

    static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }

    /// 시계방향 회전각 → EXIF 방향
    static func orientation(forClockwiseAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int((normalizedAngle(angle) / 90).rounded()) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }
}

// MARK: - 동영상 녹화

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func startRecording() {
        guard captureMode == .video, recordingState == .idle, status == .running,
              !isChangingMode, !isSwitchingCamera, let source = previewSource,
              let angle = captureRotationCoordinator?.videoRotationAngleForHorizonLevelCapture else { return }
        guard PhotoLibrarySaver.canRequestOrSave else {
            toast = PhotoLibrarySaver.SaveError.notAuthorized.localizedDescription
            return
        }
        recordingState = .starting
        movieBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save movie") { [weak self] in
            self?.stopRecording()
            self?.endMovieBackgroundTask()
        }
        let options = CaptureOptions.current()
        let location = options.saveLocation ? LocationProvider.shared.snapshot().location : nil
        sessionQueue.async {
            guard self.activeMode == .video, self.movieTake == nil,
                  self.session.isRunning, !self.session.isInterrupted,
                  self.videoOutput.connection(with: .video) === source.connection,
                  let connection = self.movieOutput.connection(with: .video), connection.isActive else {
                self.finishMovie(message: "카메라가 준비되면 다시 녹화해 주세요.")
                return
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = options.mirrorFrontCamera && source.device.position == .front
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            self.movieTake = MovieTake(url: url, date: Date(), location: location)
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard recordingState == .starting || isRecording else { return }
        recordingState = .finishing
        sessionQueue.async {
            self.movieTake?.stopRequested = true
            if self.movieTake?.didStart == true, self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async {
            guard let take = self.movieTake, take.url == fileURL else { return }
            self.movieTake?.didStart = true
            if take.stopRequested {
                if output.isRecording { output.stopRecording() }
            } else {
                self.publish { controller in
                    if controller.recordingState == .starting { controller.recordingState = .recording(take.date) }
                }
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async {
            guard let take = self.movieTake, take.url == outputFileURL else { return }
            self.movieTake = nil
            self.publish { $0.recordingState = .finishing }
            self.updateFrontCameraIfNeeded()
            if let error = error as NSError?, error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                try? FileManager.default.removeItem(at: take.url)
                self.finishMovie(message: "녹화 실패 · \(error.localizedDescription)")
                return
            }
            self.processingQueue.async {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 160, height: 160)
                let frame = try? generator.copyCGImage(at: .zero, actualTime: nil)
                PhotoLibrarySaver.saveMovie(at: take.url, location: take.location, creationDate: take.date) { error in
                    try? FileManager.default.removeItem(at: take.url)
                    self.finishMovie(message: error?.localizedDescription ?? "동영상을 저장했습니다.",
                                     thumbnail: error == nil ? frame.map { UIImage(cgImage: $0) } : nil)
                }
            }
        }
    }

    private func finishMovie(message: String, thumbnail: UIImage? = nil) {
        publish { controller in
            controller.endMovieBackgroundTask()
            controller.recordingState = .idle
            controller.toast = message
            if let thumbnail { controller.thumbnail = thumbnail }
        }
    }

    private func endMovieBackgroundTask() {
        if movieBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(movieBackgroundTask)
            movieBackgroundTask = .invalid
        }
    }
}

// MARK: - 비디오 프레임 캡처 (무음 엔진)

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard connection === activeVideoConnection else { return }
        sendToPreviews(sampleBuffer, from: connection)

        if awaitingFirstFrame {
            awaitingFirstFrame = false
            publish { controller in
                if controller.previewSource?.connection === connection { controller.isSwitchingCamera = false }
            }
        }

        // 실제로 들어오는 프레임 크기 (미리보기 좌표 변환, 프레임 엔진의 저장 해상도 표시)
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if size != lastFrameSize {
                lastFrameSize = size
                let isFrameEngine = frameEngineOnVideoQueue
                let dimensions = CMVideoDimensions(width: Int32(size.width), height: Int32(size.height))
                publish { controller in
                    guard controller.previewSource?.connection === connection else { return }
                    controller.previewFrameSize = size
                    if isFrameEngine { controller.outputDimensions = dimensions }
                }
            }
        }

        frameLock.lock()
        let request = pendingFrameRequests.first?.connection === connection ? pendingFrameRequests.removeFirst() : nil
        frameLock.unlock()

        guard let request else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            releaseSlot()
            return
        }

        // 프레임에 첨부된 모든 메타데이터({Exif}, {MakerApple} 등) + 이 순간의 카메라 상태(보충용)
        let attachments = MetadataBuilder.metadataAttachments(of: sampleBuffer)
        let device = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device
        let context = FrameCaptureContext(
            device: device,
            fallbackPosition: request.position,
            date: Date(),
            wideColor: request.wideColor,
            location: request.location,
            heading: request.heading
        )

        // 버퍼는 센서 기본 방향 그대로 → 촬영 시점의 수평 각도만큼 회전(커넥션이 이미 적용한 각도는 제외)
        let remaining = CameraController.normalizedAngle(request.rotationAngle - connection.videoRotationAngle)
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(CameraController.orientation(forClockwiseAngle: remaining))
        if request.mirrored {
            image = image.oriented(.upMirrored)
        }
        // 촬영 비율로 중앙 크롭 (미리보기와 동일한 영역)
        image = image.cropped(to: request.aspect.centeredCropRect(in: image.extent, squarePrefersLandscape: request.preferLandscape))

        // 버퍼를 오래 붙잡지 않도록 여기서 바로 렌더링 후 해제
        guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: request.colorSpace) else {
            releaseSlot()
            publish { $0.toast = "이미지를 처리하지 못했습니다." }
            return
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            let metadata = MetadataBuilder.frameMetadata(
                attachments: attachments,
                width: cgImage.width,
                height: cgImage.height,
                context: context
            )
            guard let encoded = ImageEncoder.encode(cgImage, preferred: request.format, metadata: metadata) else {
                self.releaseSlot()
                self.publish { $0.toast = "이미지를 저장하지 못했습니다." }
                return
            }
            let thumbnail = ImageEncoder.thumbnail(from: cgImage)
            self.saveToLibrary(encoded.data, format: encoded.format, thumbnail: thumbnail,
                               location: request.location, date: context.date)
        }
    }
}

// MARK: - 카메라 제어 버튼 (iOS 18+)

@available(iOS 18.0, *)
extension CameraController: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        publish { $0.isSystemControlFullscreen = true }
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        publish { $0.isSystemControlFullscreen = false }
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        publish { $0.isSystemControlFullscreen = false }
    }
}
