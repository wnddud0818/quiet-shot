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

    // MARK: - UI 상태 (메인 스레드에서만 변경)

    @Published private(set) var status: Status = .idle
    @Published private(set) var engine: Engine = .videoFrame
    @Published private(set) var outputDimensions = CMVideoDimensions(width: 0, height: 0)
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var lenses: [LensOption] = []
    @Published private(set) var activeLensID: String?
    @Published private(set) var lensMultiplier: CGFloat = 1
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var captureTick = 0
    @Published private(set) var isBursting = false
    @Published private(set) var burstCount = 0
    @Published private(set) var shutterSuppressionSupported = false
    @Published var toast: String?

    /// 광각 기준 표시 배율 (예: 0.5×, 1×, 2.3×, 5×)
    var displayZoom: CGFloat { lensMultiplier * zoomFactor }

    var megapixelText: String {
        let width = Double(outputDimensions.width)
        let height = Double(outputDimensions.height)
        guard width > 0, height > 0 else { return "—" }
        return "\(Int((width * height / 1_000_000).rounded(.down)))MP"
    }

    var resolutionText: String {
        guard outputDimensions.width > 0 else { return "—" }
        return "\(megapixelText) · \(outputDimensions.width)×\(outputDimensions.height)"
    }

    // MARK: - 세션 (sessionQueue 전용)

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "quietshot.session")
    private let videoQueue = DispatchQueue(label: "quietshot.video", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "quietshot.processing", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var activeEngine: Engine = .videoFrame
    private var isConfigured = false
    private var cachedBackLenses: [LensOption]?
    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - 메인 스레드 전용

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var pendingCoordinatorDevice: AVCaptureDevice?
    private var burstTimer: Timer?

    // MARK: - 캡처 파이프라인 (락으로 보호)

    private struct FrameRequest {
        let rotationAngle: CGFloat
        let mirrored: Bool
        let format: SaveFormat
        let colorSpace: CGColorSpace
        let wideColor: Bool
        let position: AVCaptureDevice.Position
        let location: CLLocation?
        let heading: CLHeading?
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
            center.addObserver(forName: .AVCaptureDeviceSubjectAreaDidChange, object: nil, queue: nil) { [weak self] _ in
                self?.resetFocusToContinuous()
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

    // MARK: - Preview / 회전

    /// CameraPreview가 만들어질 때 호출 (메인 스레드)
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        if let device = pendingCoordinatorDevice {
            pendingCoordinatorDevice = nil
            setupRotationCoordinator(for: device)
        }
    }

    /// RotationCoordinator: 회전 잠금과 무관하게 중력 기준으로 사진이 수평이 되도록 각도를 제공 (메인 스레드)
    private func setupRotationCoordinator(for device: AVCaptureDevice) {
        guard let previewLayer else {
            pendingCoordinatorDevice = device
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Session configuration

    private func configureIfNeededAndRun() {
        if !isConfigured {
            guard let device = CameraController.defaultBackDevice() ?? CameraController.frontDevice() else {
                publish { $0.status = .unavailable("사용 가능한 카메라가 없습니다.\n시뮬레이터가 아닌 실제 iPhone에서 실행해 주세요.") }
                return
            }
            guard configureSession(with: device) else { return }
        }
        if !session.isRunning {
            session.startRunning()
        }
        publish { $0.status = .running }
        PhotoLibrarySaver.requestAuthorizationIfNeeded()
    }

    @discardableResult
    private func configureSession(with device: AVCaptureDevice) -> Bool {
        let forceFrameEngine = UserDefaults.standard.bool(forKey: SettingsKey.forceFrameEngine)
        dropPendingFrameRequests()

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // .photo 프리셋은 24MP/48MP 사진을 지원하는 유일한 프리셋
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            publish { $0.status = .unavailable("카메라 입력을 구성할 수 없습니다.") }
            return false
        }
        session.addInput(input)
        videoInput = input

        // 1) 엔진 결정: 셔터음 억제가 "허용된" 기기에서만 사진 파이프라인 사용
        var selectedEngine: Engine = .videoFrame
        var suppressionSupported = false
        if session.canAddOutput(photoOutput) {
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

        if selectedEngine == .videoFrame {
            guard session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                publish { $0.status = .unavailable("비디오 출력을 구성할 수 없습니다.") }
                return false
            }
            session.addOutput(videoOutput)
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
        } else {
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
        }

        // 2) 기기 설정 (프레임 엔진은 스트림 해상도가 가장 큰 포맷을 직접 지정)
        do {
            try device.lockForConfiguration()
            if selectedEngine == .videoFrame, let format = FormatSelector.bestFrameFormat(for: device) {
                device.activeFormat = format
            }
            if selectedEngine == .videoFrame, device.activeFormat.supportedColorSpaces.contains(.P3_D65) {
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
            device.videoZoomFactor = 1
            device.unlockForConfiguration()
        } catch {
            // 잠금 실패 시 세션 기본 포맷으로 동작
        }

        // 3) 출력 설정 (프레임 엔진. 사진 엔진은 프리셋이 확정된 뒤 아래에서 설정)
        if selectedEngine == .videoFrame {
            let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoOutput.availableVideoPixelFormatTypes.contains(fullRange) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: fullRange]
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if let connection = videoOutput.connection(with: .video) {
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

        isConfigured = true
        activeEngine = selectedEngine

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
            session.commitConfiguration()
            preparePhotoPipeline()
        }

        let dimensions: CMVideoDimensions = selectedEngine == .photoPipeline
            ? photoOutput.maxPhotoDimensions
            : FormatSelector.videoDimensions(of: device.activeFormat)

        var lenses: [LensOption] = []
        if device.position == .back {
            if cachedBackLenses == nil {
                cachedBackLenses = LensOption.discoverBackLenses()
            }
            lenses = cachedBackLenses ?? []
        }
        let multiplier = lenses.first(where: { $0.id == device.uniqueID })?.multiplier ?? 1
        let torchAvailable = device.hasTorch && device.isTorchAvailable

        publish { controller in
            controller.engine = selectedEngine
            controller.shutterSuppressionSupported = suppressionSupported
            controller.outputDimensions = dimensions
            controller.position = device.position
            controller.lenses = lenses
            controller.activeLensID = device.uniqueID
            controller.lensMultiplier = multiplier
            controller.zoomFactor = 1
            controller.torchAvailable = torchAvailable
            controller.torchOn = false
            controller.setupRotationCoordinator(for: device)
        }
        return true
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

    static func defaultBackDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static func frontDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    func selectLens(_ lens: LensOption) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.videoInput?.device.uniqueID == lens.id {
                self.setZoomOnQueue(1)
                return
            }
            guard let device = AVCaptureDevice(uniqueID: lens.id) else { return }
            self.configureSession(with: device)
        }
    }

    func switchCamera() {
        stopBurst()
        sessionQueue.async { [weak self] in
            guard let self, let current = self.videoInput?.device else { return }
            let next = current.position == .front
                ? CameraController.defaultBackDevice()
                : CameraController.frontDevice()
            guard let next else { return }
            self.configureSession(with: next)
        }
    }

    // MARK: - Zoom / Focus / Torch

    /// 현재 렌즈 기준 배율 (1 = 렌즈 기본 화각)
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            self?.setZoomOnQueue(factor)
        }
    }

    private func setZoomOnQueue(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let upper = min(device.maxAvailableVideoZoomFactor, 10)
        let clamped = max(device.minAvailableVideoZoomFactor, min(factor, upper))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            return
        }
        publish { $0.zoomFactor = clamped }
    }

    /// devicePoint: AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:) 결과
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// 장면이 바뀌면 중앙 연속 AF/AE로 복귀
    private func resetFocusToContinuous() {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device else { return }
            let center = CGPoint(x: 0.5, y: 0.5)
            do {
                try device.lockForConfiguration()
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
            } catch {}
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
        guard burstTimer == nil, status == .running else { return }
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
        guard status == .running else { return }
        // 처리 대기 중인 촬영이 너무 많으면(메모리 보호) 연사 프레임은 건너뜀
        guard reserveSlot(limit: isBurst ? 3 : 8) else { return }

        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let options = CaptureOptions.current()
        let place = options.saveLocation ? LocationProvider.shared.snapshot() : .empty
        if isBurst { burstCount += 1 }
        captureTick += 1

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.videoInput?.device else {
                self.releaseSlot()
                return
            }
            let mirrored = options.mirrorFrontCamera && device.position == .front

            switch self.activeEngine {
            case .photoPipeline:
                self.capturePhotoSilently(angle: angle, mirrored: mirrored, format: options.saveFormat,
                                          fast: isBurst, place: place, position: device.position)
            case .videoFrame:
                let wideColor = device.activeColorSpace == .P3_D65
                let colorSpaceName = wideColor ? CGColorSpace.displayP3 : CGColorSpace.sRGB
                let colorSpace = CGColorSpace(name: colorSpaceName) ?? CGColorSpaceCreateDeviceRGB()
                let request = FrameRequest(rotationAngle: angle, mirrored: mirrored, format: options.saveFormat,
                                           colorSpace: colorSpace, wideColor: wideColor, position: device.position,
                                           location: place.location, heading: place.heading)
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
                                      position: AVCaptureDevice.Position) {
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
                                      location: location, date: captureDate)
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
            let thumbnail = ImageEncoder.thumbnail(from: data)
            self?.saveToLibrary(data, format: format, thumbnail: thumbnail, location: location, date: date)
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

// MARK: - 비디오 프레임 캡처 (무음 엔진)

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameLock.lock()
        let request = pendingFrameRequests.isEmpty ? nil : pendingFrameRequests.removeFirst()
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
