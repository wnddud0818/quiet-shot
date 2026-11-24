import AVFoundation
import CoreLocation
import Foundation
import ImageIO

/// 프레임 캡처 시점의 카메라 상태. 프레임 첨부 EXIF에 값이 없을 때 보충하는 데 사용.
struct FrameCaptureContext {
    let date: Date
    let position: AVCaptureDevice.Position
    let exposureSeconds: Double?
    let iso: Float?
    let aperture: Float?
    let exposureBias: Float?
    let zoomFactor: CGFloat
    let horizontalFieldOfView: Float
    let whiteBalanceLocked: Bool
    let exposureLocked: Bool
    let wideColor: Bool
    let location: CLLocation?
    let heading: CLHeading?

    init(device: AVCaptureDevice?,
         fallbackPosition: AVCaptureDevice.Position,
         date: Date,
         wideColor: Bool,
         location: CLLocation?,
         heading: CLHeading?) {
        self.date = date
        self.wideColor = wideColor
        self.location = location
        self.heading = heading
        position = device?.position ?? fallbackPosition

        if let device {
            let seconds = CMTimeGetSeconds(device.exposureDuration)
            exposureSeconds = seconds.isFinite && seconds > 0 ? seconds : nil
            iso = device.iso > 0 ? device.iso : nil
            aperture = device.lensAperture > 0 ? device.lensAperture : nil
            exposureBias = device.exposureTargetBias
            zoomFactor = device.videoZoomFactor
            horizontalFieldOfView = device.activeFormat.videoFieldOfView
            whiteBalanceLocked = device.whiteBalanceMode == .locked
            exposureLocked = device.exposureMode == .locked || device.exposureMode == .custom
        } else {
            exposureSeconds = nil
            iso = nil
            aperture = nil
            exposureBias = nil
            zoomFactor = 1
            horizontalFieldOfView = 0
            whiteBalanceLocked = false
            exposureLocked = false
        }
    }
}

/// EXIF / TIFF / GPS / MakerApple 메타데이터 구성
enum MetadataBuilder {

    // MARK: - 프레임 첨부 메타데이터

    /// 샘플 버퍼에 첨부된 모든 이미지 메타데이터 딕셔너리({Exif}, {MakerApple}, {TIFF} …)를 수집
    static func metadataAttachments(of sampleBuffer: CMSampleBuffer) -> [String: Any] {
        var result: [String: Any] = [:]
        for mode in [kCMAttachmentMode_ShouldNotPropagate, kCMAttachmentMode_ShouldPropagate] {
            guard let attachments = CMCopyDictionaryOfAttachments(
                allocator: kCFAllocatorDefault,
                target: sampleBuffer,
                attachmentMode: mode
            ) as? [String: Any] else { continue }
            for (key, value) in attachments where key.hasPrefix("{") && value is [String: Any] {
                result[key] = value
            }
        }
        return result
    }

    /// 프레임 캡처 사진의 전체 메타데이터.
    /// 카메라가 프레임에 붙여 준 값을 그대로 쓰고, 빠진 항목만 촬영 시점의 카메라 상태로 채웁니다.
    static func frameMetadata(attachments: [String: Any],
                              width: Int,
                              height: Int,
                              context: FrameCaptureContext) -> [String: Any] {
        var metadata = attachments
        var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

        let date = context.date
        let timestamp = exifDateFormatter.string(from: date)
        let subsec = subsecFormatter.string(from: date)
        let offset = offsetString(for: date)
        let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
        let modelName = DeviceInfo.modelName(fromLensModel: lensModel)

        // --- 실제 저장 이미지 기준 값 (항상 덮어씀)
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        exif[kCGImagePropertyExifDateTimeOriginal as String] = timestamp
        exif[kCGImagePropertyExifDateTimeDigitized as String] = timestamp
        exif[kCGImagePropertyExifSubsecTimeOriginal as String] = subsec
        exif[kCGImagePropertyExifSubsecTimeDigitized as String] = subsec
        exif[kCGImagePropertyExifOffsetTime as String] = offset
        exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset
        exif[kCGImagePropertyExifOffsetTimeDigitized as String] = offset
        // Display P3는 iPhone 카메라와 동일하게 Uncalibrated(65535) + ICC 프로파일로 표기
        exif[kCGImagePropertyExifColorSpace as String] = context.wideColor ? 65535 : 1

        // --- 프레임에 없을 때만 보충
        setIfMissing(&exif, kCGImagePropertyExifExposureTime, context.exposureSeconds)
        setIfMissing(&exif, kCGImagePropertyExifShutterSpeedValue, context.exposureSeconds.map { -log2($0) })
        setIfMissing(&exif, kCGImagePropertyExifFNumber, context.aperture.map { Double($0) })
        setIfMissing(&exif, kCGImagePropertyExifApertureValue, context.aperture.map { 2 * log2(Double($0)) })
        setIfMissing(&exif, kCGImagePropertyExifISOSpeedRatings, context.iso.map { [Int($0.rounded())] })
        setIfMissing(&exif, kCGImagePropertyExifExposureBiasValue, context.exposureBias.map { Double($0) })
        setIfMissing(&exif, kCGImagePropertyExifFocalLenIn35mmFilm, focalLength35mm(context: context, width: width, height: height))
        if context.zoomFactor > 1.001 {
            setIfMissing(&exif, kCGImagePropertyExifDigitalZoomRatio, Double(context.zoomFactor))
        }
        setIfMissing(&exif, kCGImagePropertyExifExposureProgram, 2)                // 일반 프로그램
        setIfMissing(&exif, kCGImagePropertyExifExposureMode, context.exposureLocked ? 1 : 0)
        setIfMissing(&exif, kCGImagePropertyExifWhiteBalance, context.whiteBalanceLocked ? 1 : 0)
        setIfMissing(&exif, kCGImagePropertyExifMeteringMode, 5)                   // 패턴(평가) 측광
        setIfMissing(&exif, kCGImagePropertyExifFlash, 16)                         // 플래시 꺼짐, 발광 안 함
        setIfMissing(&exif, kCGImagePropertyExifSensingMethod, 2)                  // 단판 컬러 센서
        setIfMissing(&exif, kCGImagePropertyExifSceneType, 1)                      // 직접 촬영
        setIfMissing(&exif, kCGImagePropertyExifSceneCaptureType, 0)               // 표준
        setIfMissing(&exif, kCGImagePropertyExifLensMake, "Apple")
        setIfMissing(&exif, kCGImagePropertyExifLensModel,
                     "\(modelName) \(context.position == .front ? "front" : "back") camera")

        // --- TIFF
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFDateTime as String] = timestamp
        setIfMissing(&tiff, kCGImagePropertyTIFFMake, "Apple")
        setIfMissing(&tiff, kCGImagePropertyTIFFModel, modelName)
        setIfMissing(&tiff, kCGImagePropertyTIFFSoftware, DeviceInfo.systemVersion)
        setIfMissing(&tiff, kCGImagePropertyTIFFHostComputer, modelName)
        setIfMissing(&tiff, kCGImagePropertyTIFFXResolution, 72)
        setIfMissing(&tiff, kCGImagePropertyTIFFYResolution, 72)
        setIfMissing(&tiff, kCGImagePropertyTIFFResolutionUnit, 2)

        metadata[kCGImagePropertyExifDictionary as String] = exif
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        metadata[kCGImagePropertyOrientation as String] = 1
        metadata[kCGImagePropertyDPIWidth as String] = 72
        metadata[kCGImagePropertyDPIHeight as String] = 72

        // --- GPS
        if let location = context.location {
            metadata[kCGImagePropertyGPSDictionary as String] = gpsDictionary(
                location: location, heading: context.heading, position: context.position
            )
        }
        return metadata
    }

    // MARK: - GPS

    static func gpsDictionary(location: CLLocation,
                              heading: CLHeading?,
                              position: AVCaptureDevice.Position) -> [String: Any] {
        var gps: [String: Any] = [:]
        let coordinate = location.coordinate
        gps[kCGImagePropertyGPSLatitude as String] = abs(coordinate.latitude)
        gps[kCGImagePropertyGPSLatitudeRef as String] = coordinate.latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude as String] = abs(coordinate.longitude)
        gps[kCGImagePropertyGPSLongitudeRef as String] = coordinate.longitude >= 0 ? "E" : "W"
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude < 0 ? 1 : 0
        }
        if location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
        }
        if location.speed >= 0 {
            gps[kCGImagePropertyGPSSpeed as String] = location.speed * 3.6
            gps[kCGImagePropertyGPSSpeedRef as String] = "K"
        }
        if let heading {
            let isTrue = heading.trueHeading >= 0
            var direction = isTrue ? heading.trueHeading : heading.magneticHeading
            if position == .front {
                // 전면 카메라는 화면 쪽을 향하므로 반대 방향
                direction = (direction + 180).truncatingRemainder(dividingBy: 360)
            }
            let reference = isTrue ? "T" : "M"
            gps[kCGImagePropertyGPSImgDirection as String] = direction
            gps[kCGImagePropertyGPSImgDirectionRef as String] = reference
            gps[kCGImagePropertyGPSDestBearing as String] = direction
            gps[kCGImagePropertyGPSDestBearingRef as String] = reference
        }
        gps[kCGImagePropertyGPSDateStamp as String] = gpsDateFormatter.string(from: location.timestamp)
        gps[kCGImagePropertyGPSTimeStamp as String] = gpsTimeFormatter.string(from: location.timestamp)
        return gps
    }

    // MARK: - Helpers

    private static func setIfMissing(_ dictionary: inout [String: Any], _ key: CFString, _ value: Any?) {
        let key = key as String
        guard dictionary[key] == nil, let value else { return }
        dictionary[key] = value
    }

    /// 화각으로 35mm 환산 초점거리 계산 (대각선 43.27mm 기준, 디지털 줌 반영)
    private static func focalLength35mm(context: FrameCaptureContext, width: Int, height: Int) -> Int? {
        let fov = Double(context.horizontalFieldOfView)
        guard fov > 0, width > 0, height > 0 else { return nil }
        let longSide = Double(max(width, height))
        let shortSide = Double(min(width, height))
        let diagonalFactor = (1 + pow(shortSide / longSide, 2)).squareRoot()
        let focal = 43.27 / (2 * tan(fov * .pi / 360) * diagonalFactor) * Double(context.zoomFactor)
        return Int(focal.rounded())
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let subsecFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "SSS"
        return formatter
    }()

    private static let gpsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let gpsTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter
    }()

    private static func offsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let total = abs(seconds)
        return String(format: "%@%02d:%02d", sign, total / 3600, (total % 3600) / 60)
    }
}

enum DeviceInfo {
    /// 예) "iPhone16,1"
    static let modelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
    }()

    /// iPhone 기본 카메라와 같은 형식의 iOS 버전 문자열 (예: "27.2", "27.2.1")
    static let systemVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion > 0 {
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion)"
    }()

    /// 기종명. 1순위: 카메라가 준 LensModel("iPhone 15 Pro back camera 6.765mm f/1.78"),
    /// 2순위: 식별자 표, 3순위: 식별자 그대로.
    static func modelName(fromLensModel lensModel: String?) -> String {
        if let lensModel {
            for marker in [" back ", " front "] {
                if let range = lensModel.range(of: marker) {
                    return String(lensModel[..<range.lowerBound])
                }
            }
        }
        return knownModels[modelIdentifier] ?? modelIdentifier
    }

    private static let knownModels: [String: String] = [
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
    ]
}
