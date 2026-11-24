import AVFoundation

/// 사진 파이프라인(셔터음 억제) 촬영 1건의 델리게이트.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    let uniqueID: Int64
    private let completion: (Data?, Error?) -> Void
    private var photoData: Data?
    private var processingError: Error?

    init(uniqueID: Int64, completion: @escaping (Data?, Error?) -> Void) {
        self.uniqueID = uniqueID
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            processingError = error
            return
        }
        photoData = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(photoData, error ?? processingError)
    }
}
