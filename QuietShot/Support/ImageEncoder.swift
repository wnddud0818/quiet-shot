import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 프레임 캡처 결과(CGImage)를 HEIC/JPEG + EXIF 메타데이터로 인코딩
enum ImageEncoder {

    struct Encoded {
        let data: Data
        let format: SaveFormat
    }

    static func encode(_ image: CGImage,
                       preferred: SaveFormat,
                       exif: [String: Any],
                       date: Date = Date()) -> Encoded? {
        if preferred == .heic,
           let data = encode(image, type: .heic, quality: 0.92, exif: exif, date: date) {
            return Encoded(data: data, format: .heic)
        }
        // HEIC 인코더를 쓸 수 없으면 JPEG로 대체
        if let data = encode(image, type: .jpeg, quality: 0.95, exif: exif, date: date) {
            return Encoded(data: data, format: .jpeg)
        }
        return nil
    }

    private static func encode(_ image: CGImage,
                               type: UTType,
                               quality: CGFloat,
                               exif source: [String: Any],
                               date: Date) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        let timestamp = exifDateFormatter.string(from: date)
        let offset = offsetString(for: date)

        var exif = source
        exif[kCGImagePropertyExifPixelXDimension as String] = image.width
        exif[kCGImagePropertyExifPixelYDimension as String] = image.height
        exif[kCGImagePropertyExifDateTimeOriginal as String] = timestamp
        exif[kCGImagePropertyExifDateTimeDigitized as String] = timestamp
        exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset
        exif[kCGImagePropertyExifOffsetTimeDigitized as String] = offset

        let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: DeviceInfo.cameraModelName(fromLensModel: lensModel),
            kCGImagePropertyTIFFSoftware as String: "QuietShot",
            kCGImagePropertyTIFFDateTime as String: timestamp,
            kCGImagePropertyTIFFOrientation as String: 1,
        ]

        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 썸네일

    static func thumbnail(from image: CGImage, maxPixel: CGFloat = 240) -> UIImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxPixel / max(width, height))
        return UIImage(cgImage: image).preparingThumbnail(of: CGSize(width: width * scale, height: height * scale))
    }

    static func thumbnail(from data: Data, maxPixel: Int = 240) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Helpers

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
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

    /// EXIF LensModel("iPhone 15 Pro back camera 6.765mm f/1.78")에서 기종명을 추출
    static func cameraModelName(fromLensModel lensModel: String?) -> String {
        if let lensModel {
            for marker in [" back ", " front "] {
                if let range = lensModel.range(of: marker) {
                    return String(lensModel[..<range.lowerBound])
                }
            }
        }
        return modelIdentifier
    }
}
