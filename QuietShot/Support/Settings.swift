import Foundation
import UniformTypeIdentifiers

/// UserDefaults(@AppStorage) 키
enum SettingsKey {
    static let saveFormat = "saveFormat"
    static let mirrorFrontCamera = "mirrorFrontCamera"
    static let showGrid = "showGrid"
    static let hapticOnCapture = "hapticOnCapture"
    static let forceFrameEngine = "forceFrameEngine"
    static let saveLocation = "saveLocation"
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

    static func current() -> CaptureOptions {
        let defaults = UserDefaults.standard
        let format = SaveFormat(rawValue: defaults.string(forKey: SettingsKey.saveFormat) ?? "") ?? .heic
        return CaptureOptions(
            saveFormat: format,
            mirrorFrontCamera: defaults.bool(forKey: SettingsKey.mirrorFrontCamera),
            saveLocation: defaults.object(forKey: SettingsKey.saveLocation) as? Bool ?? true
        )
    }
}
