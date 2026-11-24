import AVFoundation

/// 후면 물리 렌즈(초광각/광각/망원). 렌즈마다 별도의 물리 카메라를 사용해야
/// 각 렌즈의 최대 해상도 포맷을 그대로 쓸 수 있습니다.
struct LensOption: Identifiable, Equatable {
    /// AVCaptureDevice.uniqueID
    let id: String
    /// 광각(1×) 대비 배율. 예) 0.5, 1, 2, 3, 5
    let multiplier: CGFloat

    var label: String { LensOption.format(multiplier) }

    static func format(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f", Double(rounded))
        }
        return String(format: "%.1f", Double(rounded))
    }

    static func discoverBackLenses() -> [LensOption] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices

        // 1) 가상(멀티) 카메라의 렌즈 전환 배율로 정확한 렌즈 배율 계산
        var multipliers: [AVCaptureDevice.DeviceType: CGFloat] = [.builtInWideAngleCamera: 1]
        let virtualTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        for type in virtualTypes {
            guard let virtual = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            let constituents = virtual.constituentDevices
            let switchOvers = virtual.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
            guard constituents.count == switchOvers.count + 1,
                  let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) else {
                continue
            }
            let starts = [CGFloat(1)] + switchOvers
            for (index, constituent) in constituents.enumerated() where multipliers[constituent.deviceType] == nil {
                multipliers[constituent.deviceType] = starts[index] / starts[wideIndex]
            }
        }

        // 2) 실패 시 화각(FOV) 비율로 근사
        let wideFOV = devices
            .first(where: { $0.deviceType == .builtInWideAngleCamera })
            .map { CGFloat($0.activeFormat.videoFieldOfView) }

        return devices.map { device -> LensOption in
            var multiplier = multipliers[device.deviceType]
            let fov = CGFloat(device.activeFormat.videoFieldOfView)
            if multiplier == nil, let wideFOV, fov > 0 {
                let ratio = tan(wideFOV * .pi / 360) / tan(fov * .pi / 360)
                multiplier = (ratio * 2).rounded() / 2
            }
            return LensOption(id: device.uniqueID, multiplier: multiplier ?? 1)
        }
        .sorted { $0.multiplier < $1.multiplier }
    }
}
