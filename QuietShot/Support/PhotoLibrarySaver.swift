import CoreLocation
import Foundation
import Photos

/// 사진 보관함 저장 ("사진 추가 전용" 권한만 사용)
enum PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            "사진 보관함 접근 권한이 없습니다. 설정 > QuietShot > 사진에서 '사진 추가만'을 허용해 주세요."
        }
    }

    static func requestAuthorizationIfNeeded() {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
    }

    /// - Parameters:
    ///   - location: 사진 앱의 지도/장소 정보에도 반영 (파일 EXIF GPS와 별개로 에셋에 기록)
    ///   - creationDate: 사진 앱의 촬영 일시
    static func save(_ data: Data,
                     format: SaveFormat,
                     location: CLLocation?,
                     creationDate: Date,
                     completion: @escaping (Error?) -> Void) {
        let perform = {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = format.utType.identifier
                request.addResource(with: .photo, data: data, options: options)
                request.creationDate = creationDate
                if let location {
                    request.location = location
                }
            }, completionHandler: { _, error in
                completion(error)
            })
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            perform()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    perform()
                } else {
                    completion(SaveError.notAuthorized)
                }
            }
        default:
            completion(SaveError.notAuthorized)
        }
    }
}
