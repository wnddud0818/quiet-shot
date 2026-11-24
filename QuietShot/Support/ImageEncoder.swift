import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 프레임 캡처 결과(CGImage)를 HEIC/JPEG로 인코딩. 메타데이터는 MetadataBuilder가 만든 것을 그대로 기록.
enum ImageEncoder {

    struct Encoded {
        let data: Data
        let format: SaveFormat
    }

    static func encode(_ image: CGImage,
                       preferred: SaveFormat,
                       metadata: [String: Any]) -> Encoded? {
        if preferred == .heic,
           let data = encode(image, type: .heic, quality: 0.92, metadata: metadata) {
            return Encoded(data: data, format: .heic)
        }
        // HEIC 인코더를 쓸 수 없으면 JPEG로 대체
        if let data = encode(image, type: .jpeg, quality: 0.95, metadata: metadata) {
            return Encoded(data: data, format: .jpeg)
        }
        return nil
    }

    private static func encode(_ image: CGImage,
                               type: UTType,
                               quality: CGFloat,
                               metadata: [String: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        properties[kCGImageDestinationEmbedThumbnail as String] = true

        // 색 공간(Display P3/sRGB) ICC 프로파일은 CGImage에서 자동으로 기록됨
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
}
