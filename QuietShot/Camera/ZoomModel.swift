import AVFoundation

/// 줌 버튼 하나 (예: 0.5 / 1× / 2 / 5)
struct ZoomPreset: Identifiable, Equatable {
    /// AVCaptureDevice.videoZoomFactor 값
    let factor: CGFloat
    /// 화면에 보이는 배율 (광각 1× 기준)
    let display: CGFloat

    var id: CGFloat { display }
    var label: String { ZoomPreset.format(display) }

    /// 0.5 → "0.5", 1 → "1", 2.34 → "2.3"
    static func format(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f", Double(rounded))
        }
        return String(format: "%.1f", Double(rounded))
    }
}

/// 카메라별 줌 구성. 후면은 멀티 렌즈 가상 카메라로 렌즈 경계 없이 매끄럽게 줌하고,
/// 전면은 "넓게(0.8×, 센서 전체)"와 "표준(1×)" 두 단계를 제공합니다.
struct ZoomConfiguration: Equatable {
    let presets: [ZoomPreset]
    /// 표시 배율 = videoZoomFactor × displayMultiplier
    let displayMultiplier: CGFloat
    let minFactor: CGFloat
    let maxFactor: CGFloat
    /// 카메라를 켰을 때의 기본 배율(후면 1×, 전면 표준 1×)
    let defaultFactor: CGFloat

    static let single = ZoomConfiguration(presets: [], displayMultiplier: 1, minFactor: 1, maxFactor: 1, defaultFactor: 1)

    func display(for factor: CGFloat) -> CGFloat { factor * displayMultiplier }
    func factor(forDisplay display: CGFloat) -> CGFloat {
        min(max(display / displayMultiplier, minFactor), maxFactor)
    }

    /// 전면: 센서 전체 화각을 0.8×, 그 1.25배 크롭을 표준 1×로 표시
    static let frontWideDisplay: CGFloat = 0.8

    static func make(for device: AVCaptureDevice) -> ZoomConfiguration {
        device.position == .front ? front(device) : back(device)
    }

    // MARK: - 후면

    private static func back(_ device: AVCaptureDevice) -> ZoomConfiguration {
        let constituents = device.constituentDevices
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }

        // 각 구성 렌즈가 시작되는 줌 값 (가상 카메라). 물리 카메라 하나면 [1]
        var starts: [CGFloat] = [1]
        var types: [AVCaptureDevice.DeviceType] = [device.deviceType]
        if !constituents.isEmpty, constituents.count == switchOvers.count + 1 {
            starts = [1] + switchOvers
            types = constituents.map(\.deviceType)
        }
        let wideIndex = types.firstIndex(of: .builtInWideAngleCamera) ?? 0

        var multiplier = 1 / starts[wideIndex]
        if #available(iOS 18.0, *) {
            let systemMultiplier = device.displayVideoZoomFactorMultiplier
            if systemMultiplier > 0 { multiplier = systemMultiplier }
        }

        var presets = zip(starts, types).map { factor, _ in
            ZoomPreset(factor: factor, display: roundedDisplay(factor * multiplier))
        }

        // 48MP 메인 카메라는 2× 광학 품질 크롭을 버튼으로 제공 (같은 배율의 망원이 없을 때)
        let wideDevice = constituents.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? (device.deviceType == .builtInWideAngleCamera ? device : nil)
        if let wideDevice, hasHighResolutionSensor(wideDevice),
           !presets.contains(where: { abs($0.display - 2) < 0.15 }) {
            presets.append(ZoomPreset(factor: 2 / multiplier, display: 2))
        }
        presets.sort { $0.display < $1.display }

        let longestLens = presets.map(\.display).max() ?? 1
        let maxDisplay = max(10, longestLens * 5)          // 예: 5× 망원 → 25×, 3× → 15×
        let maxFactor = min(device.maxAvailableVideoZoomFactor, maxDisplay / multiplier)
        let minFactor = max(device.minAvailableVideoZoomFactor, 1)
        return ZoomConfiguration(
            presets: presets.filter { $0.factor >= minFactor - 0.001 && $0.factor <= maxFactor + 0.001 },
            displayMultiplier: multiplier,
            minFactor: minFactor,
            maxFactor: maxFactor,
            defaultFactor: min(max(starts[wideIndex], minFactor), maxFactor)
        )
    }

    // MARK: - 전면

    private static func front(_ device: AVCaptureDevice) -> ZoomConfiguration {
        let multiplier = frontWideDisplay
        let minFactor = max(device.minAvailableVideoZoomFactor, 1)
        let maxFactor = min(device.maxAvailableVideoZoomFactor, 3 / multiplier)   // 최대 3×
        let standard = min(max(1 / multiplier, minFactor), maxFactor)
        var presets = [ZoomPreset(factor: minFactor, display: roundedDisplay(minFactor * multiplier))]
        if standard > minFactor + 0.05 {
            presets.append(ZoomPreset(factor: standard, display: 1))
        }
        return ZoomConfiguration(
            presets: presets,
            displayMultiplier: multiplier,
            minFactor: minFactor,
            maxFactor: maxFactor,
            defaultFactor: standard
        )
    }

    // MARK: - Helpers

    private static func roundedDisplay(_ value: CGFloat) -> CGFloat {
        (value * 10).rounded() / 10
    }

    private static func hasHighResolutionSensor(_ device: AVCaptureDevice) -> Bool {
        device.formats.contains { format in
            format.supportedMaxPhotoDimensions.contains { $0.width >= 8000 }
        }
    }
}
