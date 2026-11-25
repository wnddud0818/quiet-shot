import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// UserDefaults(@AppStorage) 키
enum SettingsKey {
    static let saveFormat = "saveFormat"
    static let mirrorFrontCamera = "mirrorFrontCamera"
    static let showGrid = "showGrid"
    static let hapticOnCapture = "hapticOnCapture"
    /// 줌 다이얼 눈금 햅틱 (기본 켜짐, 촬영 햅틱과 별도)
    static let zoomDialHaptics = "zoomDialHaptics"
    static let forceFrameEngine = "forceFrameEngine"
    static let saveLocation = "saveLocation"
    static let aspectRatio = "aspectRatio"
    static let captureTimer = "captureTimer"
    static let movieQuality = "movieQuality"
    static let movieMicrophone = "movieMicrophone"
    /// 전면 카메라를 "넓게(0.8×)"로 쓸지 (false면 표준 1×)
    static let frontWideFraming = "frontWideFraming"
}

enum MovieQuality: String, CaseIterable {
    case hd30, hd60, uhd30, uhd60

    enum Resolution: String, CaseIterable {
        case hd = "1080p"
        case uhd = "4K"

        init?(width: Int32, height: Int32) {
            switch (max(width, height), min(width, height)) {
            case (1920, 1080): self = .hd
            case (3840, 2160): self = .uhd
            default: return nil
            }
        }
    }

    var resolution: Resolution { self == .hd30 || self == .hd60 ? .hd : .uhd }
    var fps: Int32 { self == .hd30 || self == .uhd30 ? 30 : 60 }

    static var preferred: Self {
        UserDefaults.standard.string(forKey: SettingsKey.movieQuality).flatMap(Self.init(rawValue:)) ?? .hd30
    }

    /// 렌즈를 바꿀 때는 선호 해상도를 우선하고, 지원 기기로 돌아오면 원래 조합을 복원한다.
    static func bestMatch(in available: [Self], resolution: Resolution, fps: Int32) -> Self? {
        let sameResolution = available.filter { $0.resolution == resolution }
        return sameResolution.first { $0.fps == fps } ?? sameResolution.first
            ?? available.first { $0.fps == fps } ?? available.first
    }
}

/// 셀프 타이머 (소리 없이 화면 카운트다운만)
enum CaptureTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case three = 3
    case ten = 10

    var id: Int { rawValue }
    var title: String { self == .off ? "끔" : "\(rawValue)초" }
    var next: CaptureTimer {
        switch self {
        case .off: return .three
        case .three: return .ten
        case .ten: return .off
        }
    }
}

/// 촬영 비율. iPhone 기본 카메라처럼 센서 전체(4:3) 이미지의 중앙을 잘라 만듭니다.
enum AspectRatioOption: String, CaseIterable, Identifiable {
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"
    case square = "1:1"

    var id: String { rawValue }
    var title: String { rawValue }

    /// 긴 변 ÷ 짧은 변
    var longToShort: Double {
        switch self {
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .square: return 1
        }
    }

    /// 세로 화면 미리보기의 가로 ÷ 세로
    var portraitAspect: CGFloat { CGFloat(1 / longToShort) }

    /// width×height 이미지를 이 비율로 중앙 크롭했을 때의 크기 (짝수 픽셀)
    /// - squarePrefersLandscape: 정사각형 센서 이미지일 때 가로(true)/세로(false) 중 어느 방향으로 자를지
    func croppedSize(width: Int, height: Int, squarePrefersLandscape: Bool = false) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        if width == height, self != .square {
            let side = width
            var short = Int((Double(side) / longToShort).rounded())
            short -= short % 2
            return squarePrefersLandscape ? (side, short) : (short, side)
        }
        let longSide = max(width, height)
        let shortSide = min(width, height)
        let current = Double(longSide) / Double(shortSide)
        var newLong = longSide
        var newShort = shortSide
        if current > longToShort + 0.001 {
            newLong = Int((Double(shortSide) * longToShort).rounded())       // 긴 변을 자름 (예: 1:1)
        } else if current < longToShort - 0.001 {
            newShort = Int((Double(longSide) / longToShort).rounded())       // 짧은 변을 자름 (예: 16:9)
        } else {
            return (width, height)
        }
        newLong -= newLong % 2
        newShort -= newShort % 2
        return width >= height ? (newLong, newShort) : (newShort, newLong)
    }

    /// rect 안에서 이 비율로 중앙 크롭한 영역
    func centeredCropRect(in rect: CGRect, squarePrefersLandscape: Bool = false) -> CGRect {
        let size = croppedSize(width: Int(rect.width.rounded()), height: Int(rect.height.rounded()),
                               squarePrefersLandscape: squarePrefersLandscape)
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        return CGRect(
            x: rect.minX + ((rect.width - width) / 2).rounded(.down),
            y: rect.minY + ((rect.height - height) / 2).rounded(.down),
            width: width,
            height: height
        )
    }
}

enum SaveFormat: String, CaseIterable, Identifiable {
    case heic
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heic: return "HEIC (고효율)"
        case .jpeg: return "JPEG (호환성 우선)"
        }
    }

    var utType: UTType {
        switch self {
        case .heic: return .heic
        case .jpeg: return .jpeg
        }
    }
}

/// 셔터를 누른 순간의 설정 스냅샷 (어느 스레드에서든 읽기 안전)
struct CaptureOptions {
    let saveFormat: SaveFormat
    let mirrorFrontCamera: Bool
    /// 기본값 true (설정에서 끌 수 있음)
    let saveLocation: Bool
    let aspectRatio: AspectRatioOption

    static func current() -> CaptureOptions {
        let defaults = UserDefaults.standard
        let format = SaveFormat(rawValue: defaults.string(forKey: SettingsKey.saveFormat) ?? "") ?? .heic
        return CaptureOptions(
            saveFormat: format,
            mirrorFrontCamera: defaults.bool(forKey: SettingsKey.mirrorFrontCamera),
            saveLocation: defaults.object(forKey: SettingsKey.saveLocation) as? Bool ?? true,
            aspectRatio: AspectRatioOption(rawValue: defaults.string(forKey: SettingsKey.aspectRatio) ?? "") ?? .fourThree
        )
    }
}
