import AVFoundation
import ImageIO

/// 사진 파이프라인(셔터음 억제) 촬영 1건의 델리게이트.
/// Apple 사진 파이프라인이 기록하는 전체 EXIF/TIFF/MakerApple에 GPS를 추가해 파일로 만듭니다.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    let uniqueID: Int64
    private let gps: [String: Any]?
    private let completion: (Data?, Error?) -> Void
    private var photoData: Data?
    private var processingError: Error?

    init(uniqueID: Int64, gps: [String: Any]?, completion: @escaping (Data?, Error?) -> Void) {
        self.uniqueID = uniqueID
        self.gps = gps
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            processingError = error
            return
        }
        photoData = photo.fileDataRepresentation(with: MetadataCustomizer(gps: gps))
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(photoData, error ?? processingError)
    }
}

/// 원본 메타데이터는 모두 유지하고 GPS만 추가
private final class MetadataCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    private let gps: [String: Any]?

    init(gps: [String: Any]?) {
        self.gps = gps
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let gps else { return nil }   // nil = 원본 그대로
        var metadata = photo.metadata
        if metadata[kCGImagePropertyGPSDictionary as String] == nil {
            metadata[kCGImagePropertyGPSDictionary as String] = gps
        }
        return metadata
    }
}
