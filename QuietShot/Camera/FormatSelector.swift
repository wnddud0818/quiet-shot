import AVFoundation

/// 기기가 제공하는 포맷 중 "가장 큰 해상도"를 고르는 로직.
/// 기종마다 포맷 목록이 다르므로 하드코딩하지 않고 런타임에 전수 조사합니다.
enum FormatSelector {

    static func area(_ dimensions: CMVideoDimensions) -> Int64 {
        Int64(dimensions.width) * Int64(dimensions.height)
    }

    static func videoDimensions(of format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    /// 사진 파이프라인에서 요청 가능한 최대 사진 해상도 (예: 48MP = 8064×6048)
    static func maxPhotoDimensions(of format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { area($0) < area($1) }
    }

    /// 사진용 고해상도 포맷 중에는 동영상 파일과 프레임 미리보기를 함께 제공하지 못하는 것도 있다.
    static func movieFormats(for device: AVCaptureDevice) -> [MovieQuality: AVCaptureDevice.Format] {
        let outputs = [ObjectIdentifier(AVCaptureMovieFileOutput.self), ObjectIdentifier(AVCaptureVideoDataOutput.self)]
        var result: [MovieQuality: AVCaptureDevice.Format] = [:]
        for format in device.formats {
            let size = videoDimensions(of: format)
            guard let resolution = MovieQuality.Resolution(width: size.width, height: size.height) else { continue }
            guard !format.unsupportedCaptureOutputClasses.contains(where: { outputs.contains(ObjectIdentifier($0)) }) else { continue }
            for quality in MovieQuality.allCases where quality.resolution == resolution {
                let duration = CMTime(value: 1, timescale: quality.fps)
                guard format.videoSupportedFrameRateRanges.contains(where: {
                    CMTimeCompare($0.minFrameDuration, duration) <= 0 && CMTimeCompare(duration, $0.maxFrameDuration) <= 0
                }) else { continue }
                // 프리셋이 선택한 포맷이 해당 조합을 지원하면 같은 렌즈 화각과 색 처리를 유지한다.
                if result[quality] == nil || format === device.activeFormat { result[quality] = format }
            }
        }
        return result
    }

    /// session.beginConfiguration 및 device.lockForConfiguration 안에서 호출한다.
    static func applyMovieQuality(_ quality: MovieQuality, format: AVCaptureDevice.Format, to device: AVCaptureDevice) {
        device.activeFormat = format
        if #available(iOS 18.0, *), device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
        let duration = CMTime(value: 1, timescale: quality.fps)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    static func activeMovieQuality(of device: AVCaptureDevice, among supported: [MovieQuality]) -> MovieQuality? {
        let size = videoDimensions(of: device.activeFormat)
        let resolution = MovieQuality.Resolution(width: size.width, height: size.height)
        return supported.first { quality in
            let duration = CMTime(value: 1, timescale: quality.fps)
            return resolution == quality.resolution
                && CMTimeCompare(device.activeVideoMinFrameDuration, duration) == 0
                && CMTimeCompare(device.activeVideoMaxFrameDuration, duration) == 0
        }
    }

    /// 프레임 캡처용: 비디오 스트림 해상도가 가장 큰 포맷.
    /// (대부분의 최신 iPhone에서 4032×3024 = 12MP, 4:3 풀 센서 영역)
    static func bestFrameFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                return false
            }
            // 비디오 데이터 출력을 지원하지 않는 포맷(일부 특수 포맷) 제외
            let unsupported = format.unsupportedCaptureOutputClasses.contains {
                ObjectIdentifier($0) == ObjectIdentifier(AVCaptureVideoDataOutput.self)
            }
            return !unsupported
        }
        return candidates.max { frameScore($0) < frameScore($1) }
    }

    /// 해상도 > 풀레인지 > 광색역(P3) > 프레임레이트 순으로 우선
    private static func frameScore(_ format: AVCaptureDevice.Format) -> (Int64, Int, Int, Double) {
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let fullRange = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
        let wideColor = format.supportedColorSpaces.contains(.P3_D65) ? 1 : 0
        let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return (area(videoDimensions(of: format)), fullRange, wideColor, maxFPS)
    }
}
